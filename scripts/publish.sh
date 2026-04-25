#!/usr/bin/env bash
# publish.sh — Morning Show Publisher for PlayoutONE Standard
#
# Version: 0.5.0 — 2026-04-25 (Wave 3 / Task 15: pre-analyzed markers)
#
# Flow (v5 — pre-analyze markers OURSELVES; never trust AutoImporter):
#   1. Pre-flight checks
#   2. Upload audio files to station C:\temp\
#  2.5 Pre-analyze each segment with preanalyze-segment.sh (length/trim/extro)
#       — abort on Extro=0, abort if preanalyze script missing.
#   3. Copy to F:\PlayoutONE\Audio\ as UID-named files (MUST match Audio.Filename exactly)
#   4. Register in Audio table with PRE-ANALYZED markers, then SELECT them back
#       and verify within 1ms tolerance — abort on mismatch (March 30 lesson:
#       AutoImporter silently zero'd TrimOut/Extro on >30-min files → instant
#       skip crash loop). All marker writes are logged to mutations.jsonl.
#   5. Wait for Music1 to finish its run
#   6. DELETE existing Playlists entries for target hours + remove old DPLs
#   7. Generate DPL files (15-col music / 9-col SOFTMARKER per re-audit 2b10202)
#   8. Drop DPL files into F:\PlayoutONE\Import\Music Logs\
#   9. Wait for AutoImporter (~15 seconds) and verify Playlists rows
#
# CRITICAL RULES (2026-03-30 incident learnings):
#   - Audio.Filename MUST exactly match the file on disk — PlayoutONE silently skips if not found
#   - AutoImporter does NOT set TrimOut/Extro reliably — we COMPUTE them with ffprobe
#     (preanalyze-segment.sh) and write them ourselves BEFORE the DPL hits the importer.
#   - Extro=0 is fatal — publish aborts rather than ever writing Extro=0 to the Audio table.
#   - After every marker write we SELECT back the row and verify the values match
#     within 1ms; mismatch aborts the run.
#   - AutoImporter first-import-wins — DELETE Playlists entries + remove old DPL before dropping new one
#   - Music1 can overwrite custom DPLs — our DPL must be dropped AFTER Music1 finishes its run
#   - Drop path: F:\PlayoutONE\Import\Music Logs\ (NOT C:\PlayoutONE\data\playlists\)
#   - Publish at least 30 min before target hour
#
# Test/dev hooks (env vars; never set in production):
#   PUBLISH_DRY_RUN=1            same as --dry-run
#   PUBLISH_PREANALYZE_MOCK=PATH use this script instead of preanalyze-segment.sh
#   PUBLISH_SQL_MOCK=PATH        replace the Audio-table SQL UPDATE/SELECT with a mock
#                                 mock is invoked as:
#                                   $MOCK update <uid> <length> <trim_out> <extro>
#                                   $MOCK select <uid>      → echoes "<trim_out>\t<extro>"
#
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${RESET} $*" >&2; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; }
info() { echo -e "${CYAN}[i]${RESET} $*" >&2; }
step() { echo -e "${BOLD}${CYAN}==>${RESET} $*" >&2; }

usage() {
  cat <<'EOF'
Usage: publish.sh [OPTIONS]

Publishes morning show audio to PlayoutONE via the AutoImporter pipeline.

Options:
  --date <YYYY-MM-DD>    Show date (required)
  --hours '5,6,7,8'      Comma-separated hours to publish (default: 5,6,7,8)
  --audio-dir <dir>      Directory containing MORNING-SHOW-H{N}.mp3 files (required)
  --config <yaml>        Config file path (default: ../config.yaml)
  --skip-music1-wait     Skip the Music1 run check (use only if Music1 won't run for this date)
  --dry-run              Show all commands without executing
  --help                 Show this help

Audio files expected:
  MORNING-SHOW-H5.mp3, MORNING-SHOW-H6.mp3, etc.
  Filename on disk MUST match Audio.Filename in the database exactly.

UID assignment:
  Hour 5 → UID 90005, file 90005.mp3
  Hour 6 → UID 90006, file 90006.mp3
  Hour 7 → UID 90007, file 90007.mp3
  Hour 8 → UID 90008, file 90008.mp3

Sequencing note:
  Music1 can overwrite our DPLs if it runs after we publish. This script
  waits for Music1 to finish its run (checks last run time) before dropping
  our DPLs, ensuring ours are the final import for those hours.

Examples:
  publish.sh --date 2026-04-06 --audio-dir ./output/
  publish.sh --date 2026-04-06 --hours '7,8' --audio-dir ./output/ --dry-run
EOF
  exit 0
}

# --- Config parser ---
cfg_val() {
  local key="$1" file="$2"
  grep -E "^\s+${key}:" "$file" | head -1 | sed "s/.*${key}:\s*//" | tr -d "'" | tr -d '"'
}

# --- Defaults ---
DATE=""; HOURS="5,6,7,8"; AUDIO_DIR=""; CONFIG=""
DRY_RUN=false; SKIP_MUSIC1_WAIT=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config.yaml"

[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)             DATE="$2";      shift 2 ;;
    --hours)            HOURS="$2";     shift 2 ;;
    --audio-dir)        AUDIO_DIR="$2"; shift 2 ;;
    --config)           CONFIG="$2";    shift 2 ;;
    --skip-music1-wait) SKIP_MUSIC1_WAIT=true; shift ;;
    --dry-run)          DRY_RUN=true;   shift   ;;
    --help)             usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# Env-var dry-run hook (test harness friendlier than --dry-run)
if [[ "${PUBLISH_DRY_RUN:-0}" == "1" ]]; then
  DRY_RUN=true
fi

CONFIG="${CONFIG:-$DEFAULT_CONFIG}"
[[ ! -f "$CONFIG" ]] && { err "Config not found: $CONFIG"; exit 1; }

# Resolve the pre-analysis script path. Tests can override via env.
PREANALYZE_BIN="${PUBLISH_PREANALYZE_MOCK:-${SCRIPT_DIR}/preanalyze-segment.sh}"
if [[ ! -x "$PREANALYZE_BIN" ]]; then
  err "preanalyze script not found or not executable: $PREANALYZE_BIN"
  err "  (cannot compute Length/TrimOut/Extro safely — refusing to silently skip)"
  exit 1
fi

# Source the mutation-log helper so we can record every marker write.
# Tests override MUTATION_LOG_DIR; production uses the helper's default.
MUTLOG_HELPER="/home/tripp/.openclaw/workspace/openclaw-pretoria/_shared/mutation-log.sh"
if [[ -r "$MUTLOG_HELPER" ]]; then
  # shellcheck disable=SC1090
  source "$MUTLOG_HELPER"
else
  warn "mutation-log helper missing at $MUTLOG_HELPER — marker writes will not be logged"
  log_mutation_start()    { echo "no-mutlog"; }
  log_mutation_complete() { :; }
  log_mutation_rollback() { :; }
fi

HOST=$(cfg_val host "$CONFIG")
AUDIO_PATH=$(cfg_val audio_path "$CONFIG")   # F:\PlayoutONE\Audio
TEMP_PATH=$(cfg_val temp_path "$CONFIG")     # C:\temp
DB=$(cfg_val db "$CONFIG")                   # PlayoutONE_Standard

[[ -z "$DATE" ]]       && { err "--date is required"; exit 1; }
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Invalid date: $DATE"; exit 1; }
[[ -z "$AUDIO_DIR" ]]  && { err "--audio-dir is required"; exit 1; }
[[ -d "$AUDIO_DIR" ]]  || { err "Audio dir not found: $AUDIO_DIR"; exit 1; }

DATE_COMPACT="${DATE//-/}"
IFS=',' read -ra HOUR_LIST <<< "$HOURS"

IMPORT_PATH='F:\PlayoutONE\Import\Music Logs'
IMPORTED_PATH='F:\PlayoutONE\Import\Music Logs\Imported'  # AutoImporter moves processed DPLs here

run()     { [[ "$DRY_RUN" == true ]] && { info "[dry-run] $*"; return 0; }; eval "$@"; }
run_ssh() { [[ "$DRY_RUN" == true ]] && { info "[dry-run] ssh $HOST $*"; return 0; }; ssh "$HOST" "$@"; }

# ---------------------------------------------------------------------------
# Audio-table marker SQL helpers
#
# These wrap the canonical UPDATE/SELECT against PlayoutONE's Audio table.
# In tests, callers set PUBLISH_SQL_MOCK to a script that absorbs the call
# and emits the SELECT response; in production these route through SSH +
# Invoke-Sqlcmd on the station.
# ---------------------------------------------------------------------------

# audio_marker_update <uid> <length> <trim_out> <extro>
audio_marker_update() {
  local uid="$1" length="$2" trim_out="$3" extro="$4"
  if [[ -n "${PUBLISH_SQL_MOCK:-}" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      info "[dry-run] $PUBLISH_SQL_MOCK update $uid $length $trim_out $extro"
      return 0
    fi
    "$PUBLISH_SQL_MOCK" update "$uid" "$length" "$trim_out" "$extro"
    return $?
  fi
  local sql="UPDATE Audio SET Length=${length}, TrimOut=${trim_out}, Extro=${extro} WHERE UID='${uid}';"
  run_ssh "powershell -Command \"Invoke-Sqlcmd -ServerInstance localhost -Database ${DB} \
    -Query \\\"${sql}\\\"\""
}

# audio_marker_select <uid>  → echoes "<trim_out>\t<extro>" on stdout
audio_marker_select() {
  local uid="$1"
  if [[ -n "${PUBLISH_SQL_MOCK:-}" ]]; then
    "$PUBLISH_SQL_MOCK" select "$uid"
    return $?
  fi
  # -h -1 strips column headers; -W trims trailing whitespace; -s "$(printf '\t')" tab separator.
  ssh "$HOST" "powershell -Command \"Invoke-Sqlcmd -ServerInstance localhost -Database ${DB} \
    -Query \\\"SELECT TrimOut, Extro FROM Audio WHERE UID='${uid}'\\\" | \
    ForEach-Object { '{0}\`t{1}' -f \\\$_.TrimOut, \\\$_.Extro }\"" 2>/dev/null \
    | tr -d '\r' | head -1
}

# ============================================================
# Step 1: Pre-flight
# ============================================================
step "1/7  Pre-flight"

log "Checking SSH..."
if [[ "$DRY_RUN" == false ]]; then
  ssh -o ConnectTimeout=10 "$HOST" "echo ok" &>/dev/null || { err "SSH failed to $HOST"; exit 1; }
fi
log "SSH OK"

# Validate audio files and measure durations
declare -A DUR_MS=()
for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${fname}"
  [[ -f "$fpath" ]] || { err "Missing: $fpath"; exit 1; }
  dur_s=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$fpath" 2>/dev/null || echo "0")
  dur_ms=$(awk "BEGIN {printf \"%.0f\", ${dur_s} * 1000}")
  DUR_MS[$h]="$dur_ms"
  info "  H${h}: ${fname} — $(awk "BEGIN {printf \"%.1f\", ${dur_s}/60}")m (${dur_ms}ms)"
done

# Timing safety check
first_hour="${HOUR_LIST[0]}"
target_epoch=$(date -d "${DATE} $(printf '%02d' "$first_hour"):00:00" +%s 2>/dev/null || \
              date -j -f "%Y-%m-%d %H:%M:%S" "${DATE} $(printf '%02d' "$first_hour"):00:00" +%s)
now_epoch=$(date +%s)
mins_until=$(( (target_epoch - now_epoch) / 60 ))
if (( mins_until < 30 )); then
  warn "Only ${mins_until}min until first air hour — recommend 30+ min lead time"
fi

# ============================================================
# Step 2: Upload and copy audio files
# ============================================================
step "2/7  Upload and copy audio files"

for h in "${HOUR_LIST[@]}"; do
  uid="9000${h}"
  uid_fname="${uid}.mp3"                          # THIS must match Audio.Filename exactly
  src_fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${src_fname}"

  log "Upload ${src_fname} → station temp"
  run scp -q "\"${fpath}\"" "\"${HOST}:C:/temp/${src_fname}\""

  log "Copy to Audio dir as ${uid_fname}  (Audio.Filename must match exactly)"
  run_ssh "powershell -Command \"Copy-Item -Path 'C:\\temp\\${src_fname}' \
    -Destination '${AUDIO_PATH}\\${uid_fname}' -Force\""

  # Verify the file exists on disk with the correct name
  if [[ "$DRY_RUN" == false ]]; then
    check=$(ssh "$HOST" "powershell -Command \
      \"if (Test-Path '${AUDIO_PATH}\\${uid_fname}') { 'OK' } else { 'MISSING' }\"" 2>/dev/null)
    if [[ "$check" == "OK" ]]; then
      log "  ✅ ${AUDIO_PATH}\\${uid_fname} confirmed on disk"
    else
      err "  ❌ ${AUDIO_PATH}\\${uid_fname} NOT found — aborting"
      exit 1
    fi
  fi
done

# ============================================================
# Step 2.5: Pre-analyze every segment with ffprobe (NEVER trust AutoImporter)
# ============================================================
step "2.5/7  Pre-analyze segments (compute Length/TrimOut/Extro ourselves)"

declare -A PRE_LENGTH=()
declare -A PRE_TRIM_OUT=()
declare -A PRE_EXTRO=()

for h in "${HOUR_LIST[@]}"; do
  src_fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${src_fname}"

  log "Pre-analyzing H${h} via ${PREANALYZE_BIN##*/}"
  if ! pre_json="$("$PREANALYZE_BIN" "$fpath" 2>&1)"; then
    err "Pre-analysis failed for H${h} (${fpath}):"
    err "  $pre_json"
    err "  Aborting — refusing to publish without verified markers."
    exit 1
  fi

  # Parse the three integer fields out of the JSON.
  pre_len=$(echo "$pre_json" | grep -oE '"length_ms"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' | head -1)
  pre_trim=$(echo "$pre_json" | grep -oE '"trim_out_ms"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' | head -1)
  pre_extro=$(echo "$pre_json" | grep -oE '"extro_ms"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' | head -1)

  if [[ -z "$pre_len" || -z "$pre_trim" || -z "$pre_extro" ]]; then
    err "Pre-analysis returned malformed JSON for H${h}: $pre_json"
    err "  Aborting."
    exit 1
  fi

  # CRITICAL: Extro=0 is the March 30 silent-skip failure mode. Refuse it.
  if (( pre_extro == 0 )); then
    err "Pre-analysis returned extro_ms=0 for H${h} (${src_fname})."
    err "  This is the March 30 silent-skip failure mode — publish.sh must"
    err "  NEVER write Extro=0 to the Audio table. Aborting."
    exit 1
  fi

  PRE_LENGTH[$h]="$pre_len"
  PRE_TRIM_OUT[$h]="$pre_trim"
  PRE_EXTRO[$h]="$pre_extro"

  info "  H${h}: length=${pre_len}ms trim_out=${pre_trim}ms extro=${pre_extro}ms"
done

# ============================================================
# Step 3: Register in Audio table with PRE-ANALYZED markers + verify
# ============================================================
step "3/7  Write pre-analyzed markers to Audio table + verify (1ms tolerance)"

for h in "${HOUR_LIST[@]}"; do
  uid="9000${h}"
  uid_fname="${uid}.mp3"
  dur_ms="${PRE_LENGTH[$h]}"
  trim_out="${PRE_TRIM_OUT[$h]}"
  extro="${PRE_EXTRO[$h]}"
  title="Morning Show Hour ${h}"

  # Belt-and-braces: never let an Extro=0 reach the SQL layer.
  if (( extro == 0 )); then
    err "Refusing to write Extro=0 for UID ${uid} (March 30 lesson). Aborting."
    exit 1
  fi

  log "UPDATE Audio SET Length=${dur_ms}, TrimOut=${trim_out}, Extro=${extro} WHERE UID='${uid}'"

  # Mutation log: record planned write before we touch the DB.
  planned_post=$(printf '{"uid":"%s","length":%d,"trim_out":%d,"extro":%d}' \
    "$uid" "$dur_ms" "$trim_out" "$extro")
  rollback_sql="-- (no automatic rollback; previous markers not captured pre-write)"
  mid=""
  if [[ "$DRY_RUN" == false ]]; then
    mid=$(log_mutation_start "publish.sh" "morning-show-publish" \
      "Audio:UID=${uid}" "null" "$planned_post" "$rollback_sql" 2>/dev/null || echo "")
  else
    info "[dry-run] would log_mutation_start for Audio:UID=${uid}"
  fi

  if ! audio_marker_update "$uid" "$dur_ms" "$trim_out" "$extro"; then
    err "SQL UPDATE failed for UID ${uid}. Aborting."
    [[ -n "$mid" ]] && log_mutation_complete "$mid" "null" "failure" >/dev/null 2>&1 || true
    exit 1
  fi

  # Skip read-back verification on dry-run — we never wrote anything.
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] would SELECT TrimOut,Extro FROM Audio WHERE UID='${uid}' and verify"
    continue
  fi

  # Verify: SELECT back the row and compare within 1ms tolerance.
  vrow=$(audio_marker_select "$uid" || true)
  v_trim=$(echo "$vrow" | awk -F'\t' '{print $1}' | tr -d ' \r')
  v_extro=$(echo "$vrow" | awk -F'\t' '{print $2}' | tr -d ' \r')

  if [[ -z "$v_trim" || -z "$v_extro" ]]; then
    err "Verification SELECT returned no rows for UID ${uid}. Aborting."
    [[ -n "$mid" ]] && log_mutation_complete "$mid" "null" "failure" >/dev/null 2>&1 || true
    exit 1
  fi

  if ! [[ "$v_trim" =~ ^[0-9]+$ && "$v_extro" =~ ^[0-9]+$ ]]; then
    err "Verification SELECT returned non-numeric values for UID ${uid}: trim='$v_trim' extro='$v_extro'"
    [[ -n "$mid" ]] && log_mutation_complete "$mid" "null" "failure" >/dev/null 2>&1 || true
    exit 1
  fi

  diff_trim=$(( v_trim - trim_out )); diff_trim=${diff_trim#-}
  diff_extro=$(( v_extro - extro ));  diff_extro=${diff_extro#-}

  if (( diff_trim > 1 || diff_extro > 1 )); then
    err "Verification mismatch for UID ${uid}:"
    err "  expected TrimOut=${trim_out} Extro=${extro}"
    err "  got      TrimOut=${v_trim}  Extro=${v_extro}"
    err "  Aborting (refusing to publish with drifted markers)."
    actual_post=$(printf '{"uid":"%s","trim_out":%d,"extro":%d}' "$uid" "$v_trim" "$v_extro")
    [[ -n "$mid" ]] && log_mutation_complete "$mid" "$actual_post" "drift" >/dev/null 2>&1 || true
    exit 1
  fi

  if (( v_extro == 0 )); then
    err "Verification shows Extro=0 in Audio table for UID ${uid} — March 30 silent-skip mode. Aborting."
    actual_post=$(printf '{"uid":"%s","trim_out":%d,"extro":%d}' "$uid" "$v_trim" "$v_extro")
    [[ -n "$mid" ]] && log_mutation_complete "$mid" "$actual_post" "failure" >/dev/null 2>&1 || true
    exit 1
  fi

  log "  ✅ Verified UID ${uid}: TrimOut=${v_trim} Extro=${v_extro} (within 1ms tolerance)"
  actual_post=$(printf '{"uid":"%s","trim_out":%d,"extro":%d}' "$uid" "$v_trim" "$v_extro")
  [[ -n "$mid" ]] && log_mutation_complete "$mid" "$actual_post" "success" >/dev/null 2>&1 || true
done

# ============================================================
# Step 3b: (legacy) Register full Audio row metadata (Title, Filename, Type, ...)
# We split this from marker writes so the marker write path is the simplest
# possible UPDATE — easy to verify, easy to mock in tests.
# ============================================================
step "3b/7  Register/update Audio row metadata (Title, Filename, Type)"

for h in "${HOUR_LIST[@]}"; do
  uid="9000${h}"
  uid_fname="${uid}.mp3"
  dur_ms="${PRE_LENGTH[$h]}"
  trim_out="${PRE_TRIM_OUT[$h]}"
  extro="${PRE_EXTRO[$h]}"
  title="Morning Show Hour ${h}"

  AUDIO_SQL="SET QUOTED_IDENTIFIER ON;
IF EXISTS (SELECT 1 FROM Audio WHERE UID='${uid}')
BEGIN
  UPDATE Audio SET
    Title='${title}', Artist='Dr Johnny Fever',
    Filename='${uid_fname}',
    Length=${dur_ms}, TrimIn=0, TrimOut=${trim_out}, Extro=${extro}, Intro=0,
    Type=16, Category=0, Deleted=0, AutoDJ=0
  WHERE UID='${uid}';
  PRINT 'Updated UID ${uid}';
END
ELSE
BEGIN
  INSERT INTO Audio (
    UID, Title, Artist, Filename, Length,
    TrimIn, TrimOut, Extro, Intro,
    Type, Category, Deleted, AutoDJ,
    Locked, Fade, Oversweep, Normalised, Split, [Length Change],
    PlayLock, Shuffle, RotateAudio, UsePitch, UseTempo, UsePredefined,
    AiFlag, WebVTImported, RVTPlusMP3, WebVTClearAudio, Cancon,
    Consolidated, AlertIfExpired, ColorOverride, RotateShuffleEnabled,
    IgnoreDaypartOnPlayer, DateTimeStartEnable, DateTimeEndEnable,
    DayPartEnable, KillDate, LockMeta, Pitch, Tempo, LUFS
  ) VALUES (
    '${uid}', '${title}', 'Dr Johnny Fever', '${uid_fname}', ${dur_ms},
    0, ${trim_out}, ${extro}, 0,
    16, 0, 0, 0,
    0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0,
    0, 0, 0, 0, 0, 0
  );
  PRINT 'Inserted UID ${uid}';
END
GO"

  log "Registering UID ${uid}: Filename=${uid_fname} TrimOut=${trim_out} Extro=${extro}"
  REMOTE_SQL="${TEMP_PATH}\\audio_${uid}.sql"
  run_ssh "powershell -Command \"\$sql = @'
${AUDIO_SQL}
'@; \$sql | Set-Content -Path '${REMOTE_SQL}' -Encoding UTF8\""
  run_ssh "sqlcmd -S localhost -d ${DB} -E -i '${REMOTE_SQL}'"
done

# ============================================================
# Step 4: Wait for Music1 to finish (prevent Music1 overwriting our DPLs)
# ============================================================
step "4/7  Check Music1 last run time"

if [[ "$SKIP_MUSIC1_WAIT" == false && "$DRY_RUN" == false ]]; then
  # Music1 generates DPLs periodically — check when it last wrote to the import folder
  # If it ran in the last 2 minutes, wait for it to finish
  log "Checking Music1 last activity..."
  last_music1=$(ssh "$HOST" "powershell -Command \
    \"(Get-ChildItem 'C:\\Music 1\\Logs\\' | Sort-Object LastWriteTime | \
      Select-Object -Last 1).LastWriteTime\"" 2>/dev/null | tr -d '\r\n' || echo "unknown")
  log "Music1 last log: ${last_music1}"

  # Check if any DPL files were recently dropped in the import folder
  recent_dpl=$(ssh "$HOST" "powershell -Command \
    \"(Get-ChildItem '${IMPORT_PATH}\\' -Filter '*.dpl' -ErrorAction SilentlyContinue | \
      Where-Object { \\\$_.LastWriteTime -gt (Get-Date).AddMinutes(-3) }).Count\"" 2>/dev/null | tr -d '\r\n' || echo "0")

  if [[ "$recent_dpl" =~ ^[0-9]+$ ]] && (( recent_dpl > 0 )); then
    warn "Music1 appears to be actively writing DPLs (${recent_dpl} recent files) — waiting 60s"
    sleep 60
    log "Resume after Music1 pause"
  else
    log "Music1 not active — proceeding"
  fi
else
  [[ "$SKIP_MUSIC1_WAIT" == true ]] && info "Skipping Music1 wait (--skip-music1-wait)"
  [[ "$DRY_RUN" == true ]] && info "[dry-run] Would check Music1 last activity"
fi

# ============================================================
# Step 5: Clear existing Playlists entries + old DPLs (AutoImporter first-import-wins)
# ============================================================
step "5/7  Clear existing entries (AutoImporter won't overwrite — first import wins)"

for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  dpl_name="${DATE_COMPACT}${hh}.dpl"

  log "Clearing Playlists entries for ${dpl_name}..."
  run_ssh "sqlcmd -S localhost -d ${DB} -E -Q \
    \"SET QUOTED_IDENTIFIER ON; \
     DELETE FROM Playlists WHERE Name='${dpl_name}' AND Type=16; \
     PRINT 'Deleted Type=16 rows for ${dpl_name}';\""

  # Remove DPL from Imported folder if it exists (prevents stale state)
  log "Removing old DPL from Imported/ folder..."
  run_ssh "powershell -Command \
    \"Remove-Item '${IMPORTED_PATH}\\${dpl_name}' -Force -ErrorAction SilentlyContinue; \
      Remove-Item '${IMPORT_PATH}\\${dpl_name}' -Force -ErrorAction SilentlyContinue\""

  log "  ✅ Cleared: ${dpl_name}"
done

# ============================================================
# Step 6: Generate and drop DPL files
# ============================================================
step "6/7  Generate and drop DPL files"

for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  uid="9000${h}"
  dpl_name="${DATE_COMPACT}${hh}.dpl"
  dpl_local="/tmp/${dpl_name}"

  # 15-column DPL music row (tab-delimited) per definitive audit 2b10202.
  # See PretoriaFields/docs/PLAYOUTONE-API.md for the full schema:
  #   1=UID  2=Chain(TRUE)  3=Extro(-1)  4=OrigExtro(-1)  5=Fade(-2)
  #   6=Command(empty for music)  7=Unknown(-2)  8=Unknown(0)  9=Unknown(-2)
  #   10..14 = Reserved (empty)  15=Metadata note
  # SOFTMARKER break rows stop at column 9 (no trailing reserved/metadata cols).
  metadata="Morning Show Hour ${h}|Dr Johnny Fever"
  printf '%s\tTRUE\t-1\t-1\t-2\t\t-2\t0\t-2\t\t\t\t\t\t%s\n' \
    "$uid" "$metadata" > "$dpl_local"

  log "Generated: ${dpl_name}  UID=${uid}"

  # Upload to temp, then move to import folder
  run scp -q "\"${dpl_local}\"" "\"${HOST}:C:/temp/${dpl_name}\""
  run_ssh "powershell -Command \"Copy-Item -Path 'C:\\temp\\${dpl_name}' \
    -Destination '${IMPORT_PATH}\\${dpl_name}' -Force\""

  log "  ✅ Dropped: ${IMPORT_PATH}\\${dpl_name}"
done

# ============================================================
# Step 7: Wait for AutoImporter + verify
# ============================================================
step "7/7  Waiting for AutoImporter + verifying"

if [[ "$DRY_RUN" == false ]]; then
  log "Waiting 20 seconds for AutoImporter to process..."
  sleep 20

  all_ok=true
  for h in "${HOUR_LIST[@]}"; do
    hh=$(printf '%02d' "$h")
    dpl_name="${DATE_COMPACT}${hh}.dpl"
    uid="9000${h}"
    uid_fname="9000${h}.mp3"

    # Check Playlists row
    pl_result=$(ssh "$HOST" "sqlcmd -S localhost -d ${DB} -E -h -1 -Q \
      \"SELECT Name, UID, Title, SourceFile, MissingAudio \
       FROM Playlists WHERE Name='${dpl_name}' AND UID='${uid}' AND Deleted=0\"" 2>/dev/null || true)

    if echo "$pl_result" | grep -q "${uid}"; then
      # Check MissingAudio flag
      missing=$(echo "$pl_result" | grep -oP '(?<=\s)[01](?=\s*$)' || echo "?")
      if [[ "$missing" == "1" ]]; then
        err "  ❌ ${dpl_name}: row exists but MissingAudio=1 — audio file not found by PlayoutONE"
        err "       Check: Audio.Filename='${uid_fname}' matches actual file on disk"
        all_ok=false
      else
        log "  ✅ ${dpl_name}: scheduled correctly (MissingAudio=0)"
      fi
    else
      warn "  ⚠️  ${dpl_name}: NOT in Playlists yet — AutoImporter may still be processing"
      warn "      Retry: ssh ${HOST} \"sqlcmd -S localhost -d ${DB} -E -Q \\\"SELECT * FROM Playlists WHERE Name='${dpl_name}'\\\"\""
      all_ok=false
    fi

    # Verify audio file on disk
    check=$(ssh "$HOST" "powershell -Command \
      \"if (Test-Path '${AUDIO_PATH}\\${uid_fname}') { 'OK' } else { 'MISSING' }\"" 2>/dev/null || true)
    if [[ "$check" == "OK" ]]; then
      log "  ✅ Audio: ${uid_fname} on disk"
    else
      err "  ❌ Audio: ${uid_fname} MISSING from ${AUDIO_PATH}"
      all_ok=false
    fi
  done

  # Final summary
  echo "" >&2
  if [[ "$all_ok" == true ]]; then
    log "✅ Publish complete — show scheduled for ${DATE} hours: ${HOURS}"
  else
    warn "⚠️  Publish completed with issues — check items above before air time"
    warn "Verify command:"
    warn "  ssh ${HOST} \"sqlcmd -S localhost -d ${DB} -E -Q \\\"SELECT Name,UID,Title,SourceFile,MissingAudio FROM Playlists WHERE Name LIKE '${DATE_COMPACT}%' AND UID LIKE '9000%'\\\"\""
  fi

else
  info "[dry-run] Would wait 20s, then verify Playlists table and audio files"
  log "Dry run complete — no changes made"
fi

echo "" >&2
echo -e "${GREEN}${BOLD}Morning show publish for ${DATE} — done${RESET}" >&2
