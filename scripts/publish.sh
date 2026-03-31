#!/usr/bin/env bash
# publish.sh — Morning Show Publisher for PlayoutONE Standard
#
# Version: 0.3.0 — 2026-03-30
#
# Flow (v3 — correct AutoImporter sequencing):
#   1. Pre-flight checks
#   2. Upload audio files to station C:\temp\
#   3. Copy to F:\PlayoutONE\Audio\ as UID-named files (MUST match Audio.Filename exactly)
#   4. Register in Audio table with correct markers (TrimOut, Extro — AutoImporter does NOT set these)
#   5. DELETE existing Playlists entries for target hours (AutoImporter won't overwrite — first import wins)
#   6. REMOVE any existing DPL from the Imported/ folder for target hours
#   7. Generate DPL files (14-column Music1 format)
#   8. Drop DPL files into F:\PlayoutONE\Import\Music Logs\
#   9. Wait for AutoImporter (~15 seconds)
#  10. Verify Playlists table has show rows with correct SourceFile
#
# CRITICAL RULES (2026-03-30 incident learnings):
#   - Audio.Filename MUST exactly match the file on disk — PlayoutONE silently skips if not found
#   - AutoImporter does NOT set TrimOut/Extro — must be set manually in Audio table BEFORE DPL drop
#   - AutoImporter first-import-wins — DELETE Playlists entries + remove old DPL before dropping new one
#   - Music1 can overwrite custom DPLs — our DPL must be dropped AFTER Music1 finishes its run
#   - Drop path: F:\PlayoutONE\Import\Music Logs\ (NOT C:\PlayoutONE\data\playlists\)
#   - Publish at least 30 min before target hour
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

CONFIG="${CONFIG:-$DEFAULT_CONFIG}"
[[ ! -f "$CONFIG" ]] && { err "Config not found: $CONFIG"; exit 1; }

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
# Step 3: Register in Audio table with correct markers
# ============================================================
step "3/7  Register in Audio table (TrimOut, Extro — AutoImporter does NOT set these)"

for h in "${HOUR_LIST[@]}"; do
  uid="9000${h}"
  uid_fname="${uid}.mp3"
  dur_ms="${DUR_MS[$h]}"
  extro=$(( dur_ms - 3000 ))
  title="Morning Show Hour ${h}"

  AUDIO_SQL="SET QUOTED_IDENTIFIER ON;
IF EXISTS (SELECT 1 FROM Audio WHERE UID='${uid}')
BEGIN
  UPDATE Audio SET
    Title='${title}', Artist='Dr Johnny Fever',
    Filename='${uid_fname}',
    Length=${dur_ms}, TrimIn=0, TrimOut=${dur_ms}, Extro=${extro}, Intro=0,
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
    0, ${dur_ms}, ${extro}, 0,
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

  log "Registering UID ${uid}: Filename=${uid_fname} TrimOut=${dur_ms} Extro=${extro}"
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

  # 14-column DPL format (tab-delimited)
  # UID | Chain | Extro | OrigExtro | Fade | Command | Oversweep | ReconID | Split | ISCI | Notes | Airtime | MergePoint | Envelope
  printf '%s\t-1\t-1\t-1\t-2\t\t-2\t0\t-2\t\t\t\t\t\n' "$uid" > "$dpl_local"

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
