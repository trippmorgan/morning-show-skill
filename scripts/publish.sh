#!/usr/bin/env bash
# publish.sh — Upload finished show to PlayoutONE via DPL/AutoImporter
#
# Part of the WPFQ Morning Show pipeline (step 8 of 8, final).
#
# ⚠️ REWRITTEN 2026-03-30 after incident that caused 2+ hours dead air.
# Previous version used raw SQL UPDATE on the Playlists table, which:
#   - Crashed the playout engine (March 20)
#   - Left SourceFile blank (PlayoutONE couldn't find files)
#   - Left Extro=0 (instant-skip crash loop on 60-min files)
#   - Caused 2+ hours dead air (March 30)
#
# NEW STRATEGY: DPL file import via AutoImporter
#   1. Upload audio files to station
#   2. Register in Audio table with correct markers (SourceFile, TrimOut, Extro)
#   3. Generate proper 14-column DPL files matching Music1 format
#   4. Drop DPL files into F:\PlayoutONE\Import\Music Logs\
#   5. AutoImporter handles the rest (import → Playlists table → scheduling)
#
# Input:  audio/MORNING-SHOW-H{N}.mp3
# Output: Files on station + DPL files in import folder
#
# Called by: build-show.sh --step publish
# Depends on: ssh, scp, ffprobe
set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[+]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*" >&2; }
err()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
info()  { echo -e "${CYAN}[i]${RESET} $*" >&2; }
step()  { echo -e "${BOLD}${CYAN}==>${RESET} $*" >&2; }

usage() {
  cat <<'EOF'
Usage: publish.sh [OPTIONS]

Uploads morning show audio to PlayoutONE and schedules via DPL/AutoImporter.

Options:
  --date <YYYY-MM-DD>    Show date (required)
  --hours '5,6,7,8'      Comma-separated hours to publish (default: 5,6,7,8)
  --audio-dir <dir>      Directory containing MORNING-SHOW-H{N}.mp3 files (required)
  --config <yaml>        Config file path (default: ../config.yaml)
  --dry-run              Show all commands without executing
  --rollback             Undo a previous publish
  --force                Skip timing safety check (DANGEROUS)
  --help                 Show this help

Audio files:
  Expected naming: MORNING-SHOW-H5.mp3, MORNING-SHOW-H6.mp3, etc.
  Hour number in filename matches broadcast hour (H5 = 5 AM).

Publish method (DPL/AutoImporter):
  1. SCP audio files to station → F:\PlayoutONE\Audio\{UID}.mp3
  2. Register in Audio table with SourceFile, TrimOut, Extro
  3. Generate Music1-format DPL files (14 columns, tab-separated)
  4. Drop DPL files into F:\PlayoutONE\Import\Music Logs\
  5. AutoImporter picks them up automatically

Safety:
  - Must publish 30+ minutes before first target hour
  - Never modifies the Playlists table directly
  - Always sets TrimOut and Extro (prevents instant-skip crash)
  - Always sets SourceFile (prevents file-not-found)

Examples:
  publish.sh --date 2026-03-31 --audio-dir ./output/
  publish.sh --date 2026-03-31 --audio-dir ./output/ --dry-run
  publish.sh --date 2026-03-31 --rollback
EOF
  exit 0
}

# --- Config parsing (minimal yq-free) ---
cfg_val() {
  local key="$1" file="$2"
  grep -E "^\s+${key}:" "$file" | head -1 | sed "s/.*${key}:\s*//" | tr -d "'" | tr -d '"'
}

# --- Defaults ---
DATE=""
HOURS="5,6,7,8"
AUDIO_DIR=""
CONFIG=""
DRY_RUN=false
ROLLBACK=false
FORCE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config.yaml"

# --- Parse args ---
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)      DATE="$2"; shift 2 ;;
    --hours)     HOURS="$2"; shift 2 ;;
    --audio-dir) AUDIO_DIR="$2"; shift 2 ;;
    --config)    CONFIG="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --rollback)  ROLLBACK=true; shift ;;
    --force)     FORCE=true; shift ;;
    --help)      usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Resolve config ---
CONFIG="${CONFIG:-$DEFAULT_CONFIG}"
if [[ ! -f "$CONFIG" ]]; then
  err "Config not found: $CONFIG"
  exit 1
fi

# --- Read config values ---
HOST=$(cfg_val host "$CONFIG")
AUDIO_PATH=$(cfg_val audio_path "$CONFIG")
TEMP_PATH=$(cfg_val temp_path "$CONFIG")
DB=$(cfg_val db "$CONFIG")
SQL_SERVER=$(cfg_val sql_server "$CONFIG")
SQL_USER=$(cfg_val sql_user "$CONFIG")
SQL_PASS=$(cfg_val sql_pass "$CONFIG")
DPL_IMPORT=$(cfg_val dpl_import_path "$CONFIG")
EXTRO_OFFSET=$(cfg_val extro_offset_ms "$CONFIG")

# Defaults
SQL_SERVER="${SQL_SERVER:-localhost\\p1sqlexpress}"
SQL_USER="${SQL_USER:-REDACTED_USER}"
SQL_PASS="${SQL_PASS:-PlayoutONE.}"
DPL_IMPORT="${DPL_IMPORT:-F:\\PlayoutONE\\Import\\Music Logs}"
EXTRO_OFFSET="${EXTRO_OFFSET:-5000}"

if [[ -z "$HOST" || -z "$AUDIO_PATH" || -z "$DB" ]]; then
  err "Config missing required station values (host, audio_path, db)"
  exit 1
fi

# --- Validate ---
if [[ -z "$DATE" ]]; then
  err "--date is required"
  exit 1
fi

if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  err "Invalid date format: $DATE (expected YYYY-MM-DD)"
  exit 1
fi

DATE_COMPACT="${DATE//-/}"  # YYYYMMDD

IFS=',' read -ra HOUR_LIST <<< "$HOURS"
for h in "${HOUR_LIST[@]}"; do
  if ! [[ "$h" =~ ^[0-9]+$ ]] || (( h < 0 || h > 23 )); then
    err "Invalid hour: $h"
    exit 1
  fi
done

# --- Dry-run wrapper ---
run() {
  if [[ "$DRY_RUN" == true ]]; then
    info "${YELLOW}[dry-run]${RESET} $*"
    return 0
  fi
  eval "$@"
}

run_ssh() {
  if [[ "$DRY_RUN" == true ]]; then
    info "${YELLOW}[dry-run]${RESET} ssh $HOST $*"
    return 0
  fi
  ssh "$HOST" "$@"
}

# --- SQL helper (uses PowerShell Invoke-Sqlcmd for proper QUOTED_IDENTIFIER) ---
run_sql() {
  local query="$1"
  local full_query="SET QUOTED_IDENTIFIER ON; ${query}"
  if [[ "$DRY_RUN" == true ]]; then
    info "${YELLOW}[dry-run SQL]${RESET} $query"
    return 0
  fi
  ssh "$HOST" "powershell -Command \"Invoke-Sqlcmd -ServerInstance '${SQL_SERVER}' -Database '${DB}' -Username '${SQL_USER}' -Password '${SQL_PASS}' -Query '${full_query}'\""
}

# ============================================================
# ROLLBACK MODE
# ============================================================
if [[ "$ROLLBACK" == true ]]; then
  step "Rollback for $DATE hours=${HOURS}"

  for h in "${HOUR_LIST[@]}"; do
    hh=$(printf '%02d' "$h")
    dpl_name="${DATE_COMPACT}${hh}.dpl"

    # Remove DPL from import folder (if not yet imported)
    log "Removing DPL: ${dpl_name}"
    run_ssh "powershell -Command \"Remove-Item -Path '${DPL_IMPORT}\\${dpl_name}' -ErrorAction SilentlyContinue\""

    # Remove from Imported folder
    run_ssh "powershell -Command \"Remove-Item -Path '${DPL_IMPORT}\\Imported\\${dpl_name}' -ErrorAction SilentlyContinue\""

    # Soft-delete our entries from Playlists (AutoImporter-created ones)
    local uid="9000${h}"
    run_sql "UPDATE Playlists SET Deleted=1 WHERE UID='${uid}' AND GIndex LIKE '${DATE_COMPACT}${hh}%'"
  done

  log "Rollback complete. Run Music1 to regenerate normal playlists."
  info "ssh $HOST \"schtasks /run /tn RunMusic1\""
  exit 0
fi

# ============================================================
# PUBLISH MODE
# ============================================================

# --- Validate audio dir ---
if [[ -z "$AUDIO_DIR" ]]; then
  err "--audio-dir is required (not needed for --rollback)"
  exit 1
fi

if [[ ! -d "$AUDIO_DIR" ]]; then
  err "Audio directory not found: $AUDIO_DIR"
  exit 1
fi

# --- Timing safety check ---
if [[ "$FORCE" != true ]]; then
  step "Timing safety check"
  first_hour="${HOUR_LIST[0]}"
  target_epoch=$(date -d "${DATE} ${first_hour}:00:00" +%s 2>/dev/null || date -d "${DATE}T$(printf '%02d' "$first_hour"):00:00" +%s)
  now_epoch=$(date +%s)
  diff_minutes=$(( (target_epoch - now_epoch) / 60 ))

  if (( diff_minutes < 0 )); then
    err "Target hour ${first_hour}:00 on ${DATE} is in the past!"
    err "Use --force to override (DANGEROUS)"
    exit 1
  fi

  if (( diff_minutes < 30 )); then
    err "Only ${diff_minutes} minutes until ${first_hour}:00 — too close!"
    err "Must publish at least 30 minutes before target hour."
    err "Use --force to override (DANGEROUS)"
    exit 1
  fi

  log "Safety check passed: ${diff_minutes} minutes until first target hour"
fi

# --- Check audio files and get durations ---
declare -A DURATIONS=()
for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${fname}"
  if [[ ! -f "$fpath" ]]; then
    err "Missing audio file: $fpath"
    exit 1
  fi
  dur_secs=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$fpath" 2>/dev/null)
  dur_ms=$(awk "BEGIN {printf \"%.0f\", ${dur_secs} * 1000}")
  DURATIONS[$h]="$dur_ms"
  info "  ${fname}: ${dur_ms}ms ($(awk "BEGIN {printf \"%.1f\", ${dur_secs}/60}")m)"
done

# ============================================================
# Step 1: Pre-flight
# ============================================================
step "Step 1/6: Pre-flight checks"

log "Testing SSH connectivity to ${HOST}..."
if [[ "$DRY_RUN" == false ]]; then
  if ! ssh -o ConnectTimeout=10 "$HOST" "echo ok" &>/dev/null; then
    err "Cannot connect to ${HOST} via SSH"
    exit 1
  fi
  log "SSH: connected"
fi

log "Checking PlayoutONE process..."
if [[ "$DRY_RUN" == false ]]; then
  po_check=$(ssh "$HOST" "powershell -Command \"Get-Process PlayoutONE -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id\"" 2>/dev/null || true)
  if [[ -z "$po_check" ]]; then
    warn "PlayoutONE process not detected — continuing anyway"
  else
    log "PlayoutONE running (PID: ${po_check})"
  fi
fi

log "Checking AutoImporter..."
if [[ "$DRY_RUN" == false ]]; then
  ai_check=$(ssh "$HOST" "powershell -Command \"Get-Process PlayoutONEAutoImporter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id\"" 2>/dev/null || true)
  if [[ -z "$ai_check" ]]; then
    warn "AutoImporter not running! DPL files won't be imported."
    warn "Start it: schtasks /run /tn StartAutoImport"
  else
    log "AutoImporter running (PID: ${ai_check})"
  fi
fi

# ============================================================
# Step 2: Upload audio files
# ============================================================
step "Step 2/6: Uploading audio files"

for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${fname}"
  uid="9000${h}"

  # Upload to temp
  log "Uploading ${fname} → ${HOST}:C:\\temp\\"
  run scp -q "'${fpath}' '${HOST}:C:/temp/${fname}'"

  # Copy to Audio folder with UID name
  log "Copying to ${AUDIO_PATH}\\${uid}.mp3"
  run_ssh "powershell -Command \"Copy-Item -Path 'C:\\temp\\${fname}' -Destination '${AUDIO_PATH}\\${uid}.mp3' -Force\""

  # Also keep the MORNING-SHOW name for reference
  run_ssh "powershell -Command \"Copy-Item -Path 'C:\\temp\\${fname}' -Destination '${AUDIO_PATH}\\${fname}' -Force\""
done

# ============================================================
# Step 3: Register in Audio table
# ============================================================
step "Step 3/6: Registering in Audio table"

for h in "${HOUR_LIST[@]}"; do
  uid="9000${h}"
  hour_num=$((h - 4))  # Hour 5=1, 6=2, 7=3, 8=4
  day_name=$(date -d "$DATE" +%A 2>/dev/null || date -jf "%Y-%m-%d" "$DATE" +%A)
  title="${day_name} Morning Show Hour ${hour_num}"
  dur_ms="${DURATIONS[$h]}"
  extro_ms=$((dur_ms - EXTRO_OFFSET))
  source_file="${AUDIO_PATH}\\${uid}.mp3"

  log "Registering UID ${uid}: ${title} (${dur_ms}ms)"

  # Use PowerShell script file to avoid escaping hell
  cat > /tmp/register-audio-${uid}.ps1 << PSEOF
\$q = @"
SET QUOTED_IDENTIFIER ON;
IF EXISTS (SELECT 1 FROM Audio WHERE UID = '${uid}')
BEGIN
    UPDATE Audio SET
        Title = '${title}',
        Artist = 'Dr Johnny Fever',
        Filename = '${uid}.mp3',
        Length = ${dur_ms},
        TrimOut = ${dur_ms},
        Extro = ${extro_ms},
        TrimIn = 0,
        Intro = 0,
        HookIn = 0,
        HookOut = 0,
        Type = 16,
        Category = 43,
        Chain = 1,
        AutoDJ = 1,
        Deleted = 0
    WHERE UID = '${uid}';
    PRINT 'UPDATED ${uid}';
END
ELSE
BEGIN
    INSERT INTO Audio (UID, Title, Artist, Filename, Length, TrimOut, Extro,
                       TrimIn, Intro, HookIn, HookOut, Type, Category, Chain, AutoDJ, Deleted)
    VALUES ('${uid}', '${title}', 'Dr Johnny Fever', '${uid}.mp3',
            ${dur_ms}, ${dur_ms}, ${extro_ms}, 0, 0, 0, 0, 16, 43, 1, 1, 0);
    PRINT 'INSERTED ${uid}';
END
"@
Invoke-Sqlcmd -ServerInstance '${SQL_SERVER}' -Database '${DB}' -Username '${SQL_USER}' -Password '${SQL_PASS}' -Query \$q
PSEOF

  if [[ "$DRY_RUN" == false ]]; then
    scp -q /tmp/register-audio-${uid}.ps1 "${HOST}:C:/temp/register-audio-${uid}.ps1"
    ssh "$HOST" "powershell -ExecutionPolicy Bypass -File C:\\temp\\register-audio-${uid}.ps1"
  else
    info "[dry-run] Would register UID ${uid} in Audio table"
    info "  Title: ${title}"
    info "  Length: ${dur_ms}ms, TrimOut: ${dur_ms}ms, Extro: ${extro_ms}ms"
  fi

  rm -f /tmp/register-audio-${uid}.ps1
done

# ============================================================
# Step 4: Remove existing DPLs for target hours
# ============================================================
step "Step 4/6: Clearing existing DPLs for target hours"

for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  dpl_name="${DATE_COMPACT}${hh}.dpl"

  log "Removing existing DPL: ${dpl_name}"
  run_ssh "powershell -Command \"Remove-Item -Path '${DPL_IMPORT}\\${dpl_name}' -ErrorAction SilentlyContinue\""
  run_ssh "powershell -Command \"Remove-Item -Path '${DPL_IMPORT}\\Imported\\${dpl_name}' -ErrorAction SilentlyContinue\""
done

# ============================================================
# Step 5: Generate and deploy DPL files
# ============================================================
step "Step 5/6: Generating DPL files (Music1 14-column format)"

for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  uid="9000${h}"
  hour_num=$((h - 4))
  day_name=$(date -d "$DATE" +%A 2>/dev/null || date -jf "%Y-%m-%d" "$DATE" +%A)
  title="${day_name} Morning Show Hour ${hour_num}"
  dpl_name="${DATE_COMPACT}${hh}.dpl"
  dpl_local="/tmp/${dpl_name}"

  # Generate Music1-format DPL (14 columns, tab-separated)
  printf "%s\tTRUE\t-1\t-1\t-2\t\tFALSE\t0\t-2\t\t\t\t\t\t%s|Dr Johnny Fever\n" \
    "${uid}" "${title}" > "${dpl_local}"
  printf "\tTRUE\t-1\t-1\t-2\tSOFTMARKER %s:59:59\t-2\t0\t-2\t\t\t\t\t\t\n" \
    "${hh}" >> "${dpl_local}"

  log "Generated ${dpl_name}:"
  cat "${dpl_local}" | sed 's/\t/ | /g' >&2

  # Upload to import folder
  log "Deploying ${dpl_name} → ${DPL_IMPORT}\\"
  run scp -q "'${dpl_local}' '${HOST}:C:/temp/${dpl_name}'"
  # Use PowerShell to copy to the import folder (SCP to UNC paths can fail)
  run_ssh "powershell -Command \"Copy-Item -Path 'C:\\temp\\${dpl_name}' -Destination '${DPL_IMPORT}\\${dpl_name}' -Force\""

  rm -f "${dpl_local}"
done

# ============================================================
# Step 6: Verify
# ============================================================
step "Step 6/6: Verifying"

if [[ "$DRY_RUN" == false ]]; then
  # Wait a moment for AutoImporter to pick up the files
  log "Waiting 10s for AutoImporter..."
  sleep 10

  # Check Audio table entries
  log "Checking Audio table markers..."
  for h in "${HOUR_LIST[@]}"; do
    uid="9000${h}"
    result=$(run_sql "SELECT UID, Title, Length, TrimOut, Extro FROM Audio WHERE UID='${uid}'" 2>/dev/null || true)
    echo "$result" >&2

    # Verify TrimOut and Extro are NOT 0
    if echo "$result" | grep -q "TrimOut.*: 0$"; then
      err "⚠️ UID ${uid} has TrimOut=0! This will cause an instant-skip crash!"
    fi
    if echo "$result" | grep -q "Extro.*: 0$"; then
      err "⚠️ UID ${uid} has Extro=0! This will cause an instant-skip crash!"
    fi
  done

  # Check if DPLs were imported
  log "Checking DPL import status..."
  for h in "${HOUR_LIST[@]}"; do
    hh=$(printf '%02d' "$h")
    dpl_name="${DATE_COMPACT}${hh}.dpl"
    
    # Check if still in import folder (not yet imported)
    pending=$(ssh "$HOST" "powershell -Command \"Test-Path '${DPL_IMPORT}\\${dpl_name}'\"" 2>/dev/null || true)
    imported=$(ssh "$HOST" "powershell -Command \"Test-Path '${DPL_IMPORT}\\Imported\\${dpl_name}'\"" 2>/dev/null || true)

    if [[ "$imported" == *"True"* ]]; then
      log "  ${dpl_name}: ✅ Imported"
    elif [[ "$pending" == *"True"* ]]; then
      warn "  ${dpl_name}: ⏳ Pending import (AutoImporter will pick it up)"
    else
      err "  ${dpl_name}: ❌ Not found! Check AutoImporter."
    fi
  done

  # Check Playlists table for our entries
  log "Checking Playlists table..."
  for h in "${HOUR_LIST[@]}"; do
    hh=$(printf '%02d' "$h")
    uid="9000${h}"
    result=$(run_sql "SELECT TOP 1 GIndex, UID, Title, SourceFile, MissingAudio FROM Playlists WHERE GIndex LIKE '${DATE_COMPACT}${hh}%' AND UID='${uid}'" 2>/dev/null || true)
    
    if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
      log "  Hour ${h}: ✅ Entry found in Playlists"
      echo "$result" >&2
      
      # Check MissingAudio
      if echo "$result" | grep -q "MissingAudio.*True"; then
        err "  ⚠️ MissingAudio=True for UID ${uid}! Audio file not found on disk."
      fi
    else
      warn "  Hour ${h}: ⏳ Not yet in Playlists (AutoImporter may still be processing)"
    fi
  done
else
  info "[dry-run] Would verify Audio table markers, DPL import status, and Playlists entries"
fi

echo "" >&2
log "Publish complete for ${DATE} (hours: ${HOURS})"
log "Method: DPL/AutoImporter (safe path)"
info "Monitor at show time: ssh $HOST \"powershell -Command \\\"(New-Object System.Net.WebClient).DownloadString('http://127.0.0.1:81/?c=GET CURRENT PLAYER NOW_PLAYING')\\\"\""
