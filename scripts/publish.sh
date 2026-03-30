#!/usr/bin/env bash
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

Uploads morning show audio to PlayoutONE and schedules it in the playout database.

Options:
  --date <YYYY-MM-DD>    Show date (required)
  --hours '5,6,7,8'      Comma-separated hours to publish (default: 5,6,7,8)
  --audio-dir <dir>      Directory containing MORNING-SHOW-H{N}.mp3 files (required)
  --config <yaml>        Config file path (default: ../config.yaml)
  --dry-run              Show all commands without executing
  --rollback             Undo a previous publish (restore deleted rows, remove show rows)
  --help                 Show this help

Audio files:
  Expected naming: MORNING-SHOW-H1.mp3, MORNING-SHOW-H2.mp3, etc.
  One file per hour specified in --hours.

Steps performed:
  1. Pre-flight: verify SSH connectivity and PlayoutONE process
  2. Upload: scp audio files to station temp directory
  3. Copy: move files from temp to PlayoutONE Audio directory
  4. Schedule: UPDATE one Type=16 row per hour, DELETE remaining music rows
  5. Verify: confirm scheduled rows match expected SourceFile values

Examples:
  publish.sh --date 2026-03-30 --audio-dir ./output/ --config config.yaml
  publish.sh --date 2026-03-30 --audio-dir ./output/ --dry-run
  publish.sh --date 2026-03-30 --rollback
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

# --- Build playlist Name values ---
declare -a PLAYLIST_NAMES=()
for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  PLAYLIST_NAMES+=("${DATE_COMPACT}${hh}.dpl")
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

# ============================================================
# ROLLBACK MODE
# ============================================================
if [[ "$ROLLBACK" == true ]]; then
  step "Rollback for $DATE hours=${HOURS}"

  # Build IN-clause for playlist names
  in_clause=""
  for name in "${PLAYLIST_NAMES[@]}"; do
    [[ -n "$in_clause" ]] && in_clause+=","
    in_clause+="'${name}'"
  done

  ROLLBACK_SQL="SET QUOTED_IDENTIFIER ON;
-- Restore rows we soft-deleted
UPDATE Playlists SET Deleted = 0
WHERE Name IN (${in_clause}) AND Type = 16 AND Deleted = 1;

-- Remove our injected morning show rows (UID starts with 9000)
DELETE FROM Playlists
WHERE Name IN (${in_clause}) AND UID LIKE '9000%' AND Type = 16;
"

  info "Rollback SQL:"
  echo "$ROLLBACK_SQL" >&2

  log "Writing rollback SQL to remote..."
  ROLLBACK_REMOTE="${TEMP_PATH}\\rollback.sql"
  run_ssh "powershell -Command \"Set-Content -Path '${ROLLBACK_REMOTE}' -Value '$(echo "$ROLLBACK_SQL" | tr '\n' '`' | sed 's/`/\r\n/g')'\""

  log "Executing rollback..."
  run_ssh "sqlcmd -S localhost -d ${DB} -E -i '${ROLLBACK_REMOTE}'"

  log "Rollback complete"
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

# Check all hour files exist and get durations
declare -A DURATIONS=()
for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${fname}"
  if [[ ! -f "$fpath" ]]; then
    err "Missing audio file: $fpath"
    exit 1
  fi
  # Get duration in milliseconds via ffprobe
  dur_secs=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$fpath" 2>/dev/null)
  dur_ms=$(awk "BEGIN {printf \"%.0f\", ${dur_secs} * 1000}")
  DURATIONS[$h]="$dur_ms"
  info "  ${fname}: ${dur_ms}ms ($(awk "BEGIN {printf \"%.1f\", ${dur_secs}/60}")m)"
done

# ============================================================
# Step 1: Pre-flight
# ============================================================
step "Step 1/5: Pre-flight checks"

log "Testing SSH connectivity to ${HOST}..."
if [[ "$DRY_RUN" == false ]]; then
  if ! ssh -o ConnectTimeout=10 "$HOST" "echo ok" &>/dev/null; then
    err "Cannot connect to ${HOST} via SSH"
    exit 1
  fi
  log "SSH: connected"
else
  info "${YELLOW}[dry-run]${RESET} ssh ${HOST} echo ok"
fi

log "Checking PlayoutONE process..."
if [[ "$DRY_RUN" == false ]]; then
  po_check=$(ssh "$HOST" "powershell -Command \"Get-Process PlayoutONE -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id\"" 2>/dev/null || true)
  if [[ -z "$po_check" ]]; then
    warn "PlayoutONE process not detected — continuing anyway"
  else
    log "PlayoutONE running (PID: ${po_check})"
  fi
else
  info "${YELLOW}[dry-run]${RESET} ssh ${HOST} powershell Get-Process PlayoutONE"
fi

# ============================================================
# Step 2: Upload audio files
# ============================================================
step "Step 2/5: Uploading audio files"

for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  fpath="${AUDIO_DIR%/}/${fname}"
  remote_temp="${TEMP_PATH}\\${fname}"
  log "Uploading ${fname} -> ${HOST}:${remote_temp}"
  run scp -q "'${fpath}' '${HOST}:C:/temp/${fname}'"
done

# ============================================================
# Step 3: Copy to PlayoutONE Audio directory
# ============================================================
step "Step 3/5: Copying to PlayoutONE Audio directory"

for h in "${HOUR_LIST[@]}"; do
  fname="MORNING-SHOW-H${h}.mp3"
  src="${TEMP_PATH}\\${fname}"
  dst="${AUDIO_PATH}\\${fname}"
  log "Copying ${fname} -> ${dst}"
  run_ssh "powershell -Command \"Copy-Item -Path '${src}' -Destination '${dst}' -Force\""
done

# ============================================================
# Step 4: Generate and execute schedule SQL
# ============================================================
step "Step 4/5: Scheduling in PlayoutONE database"

SQL="SET QUOTED_IDENTIFIER ON;
"

hour_num=0
for h in "${HOUR_LIST[@]}"; do
  hh=$(printf '%02d' "$h")
  playlist_name="${DATE_COMPACT}${hh}.dpl"
  fname="MORNING-SHOW-H${h}.mp3"
  dur_ms="${DURATIONS[$h]}"
  hour_num=$((hour_num + 1))
  uid="9000${h}"

  SQL+="
-- Hour ${h}: update one Type=16 row, delete the rest
-- Find one GIndex to repurpose
DECLARE @gindex_h${h} NVARCHAR(50);
SELECT TOP 1 @gindex_h${h} = GIndex
FROM Playlists
WHERE Name = '${playlist_name}' AND Type = 16
ORDER BY [Order] ASC;

IF @gindex_h${h} IS NOT NULL
BEGIN
    -- Repurpose this row for our show hour
    UPDATE Playlists SET
        AirTime = '${hh}:00:00',
        [Order] = 1.0,
        UID = '${uid}',
        Title = 'Morning Show Hour ${hour_num}',
        Artist = 'Dr Johnny Fever',
        Chain = 1,
        Length = ${dur_ms},
        Len = ${dur_ms},
        Type = 16,
        SourceFile = '${fname}',
        Deleted = 0,
        Status = 0
    WHERE GIndex = @gindex_h${h};

    -- Soft-delete remaining Type=16 rows for this hour
    DELETE FROM Playlists
    WHERE Name = '${playlist_name}'
      AND Type = 16
      AND GIndex != @gindex_h${h};
END
ELSE
BEGIN
    PRINT 'WARNING: No Type=16 rows found for ${playlist_name}';
END
"
done

info "Generated SQL:"
echo "$SQL" >&2

log "Writing schedule SQL to remote..."
# Write SQL file via PowerShell to handle encoding
SQL_ESCAPED=$(echo "$SQL" | sed "s/'/\\\\'/g")
run_ssh "powershell -Command \"Set-Content -Path '${TEMP_PATH}\\schedule.sql' -Encoding UTF8 -Value '${SQL_ESCAPED}'\""

log "Executing SQL via sqlcmd..."
run_ssh "sqlcmd -S localhost -d ${DB} -E -i '${TEMP_PATH}\\schedule.sql'"

# ============================================================
# Step 5: Verify
# ============================================================
step "Step 5/5: Verifying schedule"

VERIFY_SQL="SET QUOTED_IDENTIFIER ON;
SELECT Name, UID, Title, SourceFile, Length
FROM Playlists
WHERE Name IN ("
first=true
for name in "${PLAYLIST_NAMES[@]}"; do
  [[ "$first" == true ]] && first=false || VERIFY_SQL+=","
  VERIFY_SQL+="'${name}'"
done
VERIFY_SQL+=") AND Type = 16 AND Deleted = 0
ORDER BY Name, [Order];
"

if [[ "$DRY_RUN" == false ]]; then
  log "Querying scheduled rows..."
  result=$(ssh "$HOST" "sqlcmd -S localhost -d ${DB} -E -h -1 -Q \"${VERIFY_SQL}\"" 2>/dev/null || true)
  echo "$result" >&2

  # Count rows with our SourceFile pattern
  match_count=$(echo "$result" | grep -c "MORNING-SHOW-H" || true)
  expected=${#HOUR_LIST[@]}

  if (( match_count == expected )); then
    log "Verified: ${match_count}/${expected} hours scheduled correctly"
  else
    warn "Expected ${expected} rows but found ${match_count} — check manually"
  fi
else
  info "${YELLOW}[dry-run]${RESET} Verify SQL:"
  echo "$VERIFY_SQL" >&2
fi

echo "" >&2
log "Publish complete for ${DATE} (hours: ${HOURS})"
