#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[voice]${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}[warn]${RESET} $*" >&2; }
err()  { echo -e "${RED}[error]${RESET} $*" >&2; }
ok()   { echo -e "${GREEN}[done]${RESET} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Render text files to MP3 via ElevenLabs TTS.

Options:
  --input  <file>    Input text file
  --output <file>    Output MP3 path
  --batch-dir <dir>  Render all .txt files in directory to .mp3
  --config <path>    Config YAML (default: ../config.yaml)
  --show-date <YYYY-MM-DD>  Show date used for ledger path (default: today)
  --dry-run          Print what would be rendered without API calls
  --help             Show this help

Environment:
  ELEVENLABS_API_KEY        API key (or set in ~/.env)
  ELEVENLABS_RATE_PER_CHAR  Cost per character (default 0.0001 USD)
  ELEVENLABS_CAP_USD        Hard per-show spend cap (default 5.00 USD)

Mocking (test-only):
  RENDER_VOICE_MOCK_ELEVENLABS=1   Skip real curl; write fake mp3
  RENDER_VOICE_MOCK_CHARS=<n>      Report n characters per segment
  RENDER_VOICE_TELEGRAM_ALERT=<f>  Override path to telegram alert script

Examples:
  $(basename "$0") --input seg01.txt --output seg01.mp3
  $(basename "$0") --batch-dir ./segments/
  $(basename "$0") --batch-dir ./segments/ --dry-run
EOF
  exit 0
}

# --- Defaults ---
INPUT=""
OUTPUT=""
BATCH_DIR=""
CONFIG=""
DRY_RUN=false
SHOW_DATE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config.yaml"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)     INPUT="$2";      shift 2 ;;
    --output)    OUTPUT="$2";     shift 2 ;;
    --batch-dir) BATCH_DIR="$2";  shift 2 ;;
    --config)    CONFIG="$2";     shift 2 ;;
    --show-date) SHOW_DATE="$2";  shift 2 ;;
    --dry-run)   DRY_RUN=true;    shift ;;
    --help|-h)   usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

# --- Validate args ---
if [[ -z "$INPUT" && -z "$BATCH_DIR" ]]; then
  err "Must specify --input <file> or --batch-dir <dir>"
  exit 1
fi
if [[ -n "$INPUT" && -z "$OUTPUT" ]]; then
  err "--output is required when using --input"
  exit 1
fi

# --- Load config ---
CONFIG="${CONFIG:-$DEFAULT_CONFIG}"
if [[ ! -f "$CONFIG" ]]; then
  err "Config not found: $CONFIG"
  exit 1
fi

cfg_get() {
  # Simple YAML value extraction via grep/sed (flat keys under sections)
  local key="$1"
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*\(.*\)/\1/p" "$CONFIG" | sed "s/['\"]//g" | head -1
}

VOICE_ID="$(cfg_get 'id')"
MODEL="$(cfg_get 'model')"
STABILITY="$(cfg_get 'stability')"
SIMILARITY_BOOST="$(cfg_get 'similarity_boost')"
STYLE="$(cfg_get 'style')"
FORMAT="$(cfg_get 'format' | head -1)"
RATE_LIMIT_SLEEP="$(cfg_get 'rate_limit_sleep')"

# Defaults if config values missing
VOICE_ID="${VOICE_ID:-ZnX1f6YZpySUHtk0RDLM}"
MODEL="${MODEL:-eleven_multilingual_v2}"
STABILITY="${STABILITY:-0.5}"
SIMILARITY_BOOST="${SIMILARITY_BOOST:-0.85}"
STYLE="${STYLE:-0.35}"
FORMAT="${FORMAT:-mp3_44100_128}"
RATE_LIMIT_SLEEP="${RATE_LIMIT_SLEEP:-1}"

# --- API key ---
if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
  ENV_FILE="${HOME}/.env"
  if [[ -f "$ENV_FILE" ]]; then
    ELEVENLABS_API_KEY="$(sed -n 's/^ELEVENLABS_API_KEY=\(.*\)/\1/p' "$ENV_FILE" | sed "s/['\"]//g" | head -1)"
    export ELEVENLABS_API_KEY
  fi
fi

if [[ -z "${ELEVENLABS_API_KEY:-}" && "$DRY_RUN" == false && "${RENDER_VOICE_MOCK_ELEVENLABS:-0}" != "1" ]]; then
  err "ELEVENLABS_API_KEY not set and not found in ~/.env"
  exit 1
fi

# --- Spend tracking + cap (Wave 3 Task 18 / AD-07) ---
ELEVENLABS_RATE_PER_CHAR="${ELEVENLABS_RATE_PER_CHAR:-0.0001}"
ELEVENLABS_CAP_USD="${ELEVENLABS_CAP_USD:-5.00}"
SHOW_DATE="${SHOW_DATE:-$(date +%Y-%m-%d)}"
SHOW_DIR="${SCRIPT_DIR}/../shows/${SHOW_DATE}"
LEDGER="${SHOW_DIR}/elevenlabs-ledger.json"
DEFAULT_TELEGRAM_ALERT="${SCRIPT_DIR}/../../scripts/send-telegram-alert.sh"
TELEGRAM_ALERT="${RENDER_VOICE_TELEGRAM_ALERT:-$DEFAULT_TELEGRAM_ALERT}"

ledger_init() {
  # Skip ledger entirely for dry-run; cap doesn't apply if no API call happens.
  [[ "$DRY_RUN" == true ]] && return 0
  mkdir -p "$SHOW_DIR"
  if [[ ! -f "$LEDGER" ]]; then
    python3 - "$LEDGER" "$SHOW_DATE" "$ELEVENLABS_RATE_PER_CHAR" "$ELEVENLABS_CAP_USD" <<'PYEOF'
import json, sys
path, show_date, rate, cap = sys.argv[1:5]
data = {
    "show_date": show_date,
    "rate_per_char": float(rate),
    "cap_usd": float(cap),
    "segments": [],
    "total_cost_usd": 0.0,
    "status": "in_progress",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
  fi
}

ledger_total() {
  [[ -f "$LEDGER" ]] || { echo "0"; return; }
  python3 -c "import json;print(json.load(open('$LEDGER'))['total_cost_usd'])"
}

ledger_set_status() {
  local status="$1"
  [[ -f "$LEDGER" ]] || return 0
  python3 - "$LEDGER" "$status" <<'PYEOF'
import json, sys
path, status = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["status"] = status
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

ledger_append_segment() {
  local seg_id="$1" chars="$2" cost="$3"
  python3 - "$LEDGER" "$seg_id" "$chars" "$cost" <<'PYEOF'
import json, sys, datetime
path, seg_id, chars, cost = sys.argv[1:5]
with open(path) as f:
    data = json.load(f)
data["segments"].append({
    "segment_id": seg_id,
    "chars": int(chars),
    "cost_usd": float(cost),
    "ts": datetime.datetime.utcnow().isoformat() + "Z",
})
data["total_cost_usd"] = round(sum(s["cost_usd"] for s in data["segments"]), 6)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# Returns 0 if (current_total + projected_cost) is <= cap, else 1.
cap_check() {
  local projected="$1"
  python3 - "$LEDGER" "$projected" "$ELEVENLABS_CAP_USD" <<'PYEOF'
import json, sys
path, projected, cap = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
with open(path) as f:
    data = json.load(f)
total = float(data.get("total_cost_usd", 0.0))
if total + projected > cap:
    sys.exit(1)
sys.exit(0)
PYEOF
}

abort_cap_exceeded() {
  local seg_id="$1" projected="$2"
  local current
  current="$(ledger_total)"
  ledger_set_status "aborted_cap_exceeded"
  err "ElevenLabs spend cap exceeded: would-be \$$(python3 -c "print(round($current + $projected, 4))") > cap \$${ELEVENLABS_CAP_USD} (segment ${seg_id})"
  err "Ledger persisted at: ${LEDGER}"
  local msg="ALERT: ElevenLabs cap exceeded for show ${SHOW_DATE}. Spent \$${current}, segment ${seg_id} (\$${projected}) would breach cap \$${ELEVENLABS_CAP_USD}. Ledger: ${LEDGER}"
  if [[ -x "$TELEGRAM_ALERT" ]]; then
    "$TELEGRAM_ALERT" "$msg" >&2 || warn "Telegram alert failed (non-fatal)"
  else
    warn "Telegram alert script not executable: $TELEGRAM_ALERT"
  fi
  exit 2
}

# --- Render function ---
# Returns 0 on render success, 2 on cap-abort (script will exit), 1 on other failure.
render_one() {
  local txt_file="$1"
  local mp3_file="$2"
  local segment_name
  segment_name="$(basename "$txt_file" .txt)"

  if [[ ! -f "$txt_file" ]]; then
    err "Input not found: $txt_file"
    return 1
  fi

  local text
  text="$(cat "$txt_file")"
  if [[ -z "$text" ]]; then
    warn "Skipping empty file: $txt_file"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "${YELLOW}[dry-run]${RESET} ${segment_name} → ${mp3_file}"
    return 0
  fi

  # Pre-flight cap check using projected character count.
  # In mock mode, RENDER_VOICE_MOCK_CHARS overrides; otherwise use file char count
  # as the pre-flight estimate (we'll reconcile with actual after the call).
  local projected_chars projected_cost
  if [[ -n "${RENDER_VOICE_MOCK_CHARS:-}" ]]; then
    projected_chars="${RENDER_VOICE_MOCK_CHARS}"
  else
    projected_chars="${#text}"
  fi
  projected_cost="$(python3 -c "print(round(${projected_chars} * ${ELEVENLABS_RATE_PER_CHAR}, 6))")"

  if ! cap_check "$projected_cost"; then
    abort_cap_exceeded "$segment_name" "$projected_cost"
    # abort_cap_exceeded exits; we should never get here.
    return 2
  fi

  log "Rendering ${GREEN}${segment_name}${RESET} → ${mp3_file} (~${projected_chars} chars, ~\$${projected_cost})"

  # Ensure output directory exists
  mkdir -p "$(dirname "$mp3_file")"

  local actual_chars="$projected_chars"

  if [[ "${RENDER_VOICE_MOCK_ELEVENLABS:-0}" == "1" ]]; then
    # Mock mode: write a tiny placeholder file; treat actual_chars = projected_chars
    printf 'MOCK_MP3' > "$mp3_file"
  elif command -v sag &>/dev/null; then
    # Use sag CLI
    sag speak \
      -f "$txt_file" \
      --voice-id "$VOICE_ID" \
      --model-id "$MODEL" \
      --format "$FORMAT" \
      -o "$mp3_file"
  else
    # Fallback: direct curl to ElevenLabs API
    local payload
    payload=$(cat <<ENDJSON
{
  "text": $(printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "model_id": "${MODEL}",
  "voice_settings": {
    "stability": ${STABILITY},
    "similarity_boost": ${SIMILARITY_BOOST},
    "style": ${STYLE}
  }
}
ENDJSON
)

    local http_code
    local hdr_file
    hdr_file="$(mktemp)"
    http_code=$(curl -s -w '%{http_code}' \
      -D "$hdr_file" \
      -o "$mp3_file" \
      -X POST \
      "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}" \
      -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload")

    if [[ "$http_code" -ne 200 ]]; then
      err "API returned HTTP ${http_code} for ${segment_name}"
      if [[ -f "$mp3_file" ]]; then
        cat "$mp3_file" >&2
        rm -f "$mp3_file"
      fi
      rm -f "$hdr_file"
      return 1
    fi

    # Try to extract real character count from response headers (ElevenLabs sets
    # `character-cost` or similar). Fall back to projected if header missing.
    local hdr_chars
    hdr_chars="$(grep -iE '^(character-cost|x-character-cost):' "$hdr_file" 2>/dev/null \
      | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
    if [[ -n "$hdr_chars" && "$hdr_chars" =~ ^[0-9]+$ ]]; then
      actual_chars="$hdr_chars"
    fi
    rm -f "$hdr_file"
  fi

  # Persist actual cost to ledger
  local actual_cost
  actual_cost="$(python3 -c "print(round(${actual_chars} * ${ELEVENLABS_RATE_PER_CHAR}, 6))")"
  ledger_append_segment "$segment_name" "$actual_chars" "$actual_cost"

  if [[ -f "$mp3_file" ]]; then
    local size
    size=$(stat -c%s "$mp3_file" 2>/dev/null || stat -f%z "$mp3_file" 2>/dev/null || echo "?")
    ok "${segment_name} — ${size} bytes (\$${actual_cost})"
  fi
}

# --- Main ---
ledger_init
rendered=0

if [[ -n "$INPUT" ]]; then
  render_one "$INPUT" "$OUTPUT"
  rendered=1
fi

if [[ -n "$BATCH_DIR" ]]; then
  if [[ ! -d "$BATCH_DIR" ]]; then
    err "Batch directory not found: $BATCH_DIR"
    exit 1
  fi

  shopt -s nullglob
  txt_files=("${BATCH_DIR}"/*.txt)
  shopt -u nullglob

  if [[ ${#txt_files[@]} -eq 0 ]]; then
    warn "No .txt files found in $BATCH_DIR"
    exit 0
  fi

  # Sort for deterministic order
  IFS=$'\n' txt_files=($(printf '%s\n' "${txt_files[@]}" | sort))
  unset IFS

  log "Found ${#txt_files[@]} text file(s) in ${BATCH_DIR}"

  for txt in "${txt_files[@]}"; do
    mp3="${txt%.txt}.mp3"
    render_one "$txt" "$mp3"
    rendered=$((rendered + 1))

    # Rate-limit sleep between renders (skip after last file)
    if [[ "$DRY_RUN" == false && "$rendered" -lt "${#txt_files[@]}" && "${RENDER_VOICE_MOCK_ELEVENLABS:-0}" != "1" ]]; then
      sleep "$RATE_LIMIT_SLEEP"
    fi
  done
fi

# Mark ledger complete on a clean run
if [[ "$DRY_RUN" == false ]]; then
  ledger_set_status "completed"
fi

log "Rendered ${GREEN}${rendered}${RESET} segment(s)"
