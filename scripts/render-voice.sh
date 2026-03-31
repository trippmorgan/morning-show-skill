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
  --dry-run          Print what would be rendered without API calls
  --help             Show this help

Environment:
  ELEVENLABS_API_KEY   API key (or set in ~/.env)

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config.yaml"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT="$2";     shift 2 ;;
    --output)   OUTPUT="$2";    shift 2 ;;
    --batch-dir) BATCH_DIR="$2"; shift 2 ;;
    --config)   CONFIG="$2";    shift 2 ;;
    --dry-run)  DRY_RUN=true;   shift ;;
    --help|-h)  usage ;;
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

if [[ -z "${ELEVENLABS_API_KEY:-}" && "$DRY_RUN" == false ]]; then
  err "ELEVENLABS_API_KEY not set and not found in ~/.env"
  exit 1
fi

# --- Render function ---
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

  log "Rendering ${GREEN}${segment_name}${RESET} → ${mp3_file}"

  # Ensure output directory exists
  mkdir -p "$(dirname "$mp3_file")"

  if command -v sag &>/dev/null; then
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
    http_code=$(curl -s -w '%{http_code}' \
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
      return 1
    fi
  fi

  if [[ -f "$mp3_file" ]]; then
    local size
    size=$(stat -c%s "$mp3_file" 2>/dev/null || stat -f%z "$mp3_file" 2>/dev/null || echo "?")
    ok "${segment_name} — ${size} bytes"
  fi
}

# --- Main ---
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

  log "Found ${#txt_files[@]} text file(s) in ${BATCH_DIR}"

  for txt in "${txt_files[@]}"; do
    mp3="${txt%.txt}.mp3"
    render_one "$txt" "$mp3"
    rendered=$((rendered + 1))

    # Rate-limit sleep between renders (skip after last file)
    if [[ "$DRY_RUN" == false && "$rendered" -lt "${#txt_files[@]}" ]]; then
      sleep "$RATE_LIMIT_SLEEP"
    fi
  done
fi

log "Rendered ${GREEN}${rendered}${RESET} segment(s)"
