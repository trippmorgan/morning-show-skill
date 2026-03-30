#!/usr/bin/env bash
set -euo pipefail

# pull-songs.sh — Query and download songs from PlayoutONE via SSH
# Outputs JSON manifest to stdout; progress/status to stderr.

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()   { echo -e "${CYAN}[pull-songs]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[pull-songs]${RESET} $*" >&2; }
error() { echo -e "${RED}[pull-songs]${RESET} $*" >&2; }
ok()    { echo -e "${GREEN}[pull-songs]${RESET} $*" >&2; }

SSH_HOST="p1-wpfq-srvs"
DB="PlayoutONE_Standard"
REMOTE_AUDIO_DIR='F:\\PlayoutONE\\Audio'
REMOTE_QUERY_FILE='C:\\temp\\query.sql'

usage() {
  cat >&2 <<'EOF'
Usage:
  pull-songs.sh --uids '355,3426,1744' --output-dir <dir>
      Download songs by PlayoutONE UID. Outputs JSON manifest to stdout.

  pull-songs.sh --search 'clapton'
      Search for songs by artist or title. Lists matches to stderr (no download).

  pull-songs.sh --songs 'Eric Clapton - Cocaine, Pearl Jam - Black' --output-dir <dir>
      Search by "Artist - Title" pairs, download best matches. Outputs JSON manifest.

  pull-songs.sh --from-scripts <dir> --output-dir <dir>
      Parse [SONG: Artist - Title] markers from script .md files in <dir>.
      Extracts all unique songs and downloads them.

Options:
  --uids <csv>         Comma-separated PlayoutONE UIDs
  --search <term>      Search artist/title (list only, no download)
  --songs <csv>        Comma-separated "Artist - Title" pairs
  --from-scripts <dir> Parse [SONG:] markers from .md files in directory
  --output-dir <dir>   Local directory for downloaded files
  --help               Show this help
EOF
  exit 0
}

# --- arg parsing ---
MODE=""
UIDS=""
SEARCH_TERM=""
SONGS=""
SCRIPTS_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)      usage ;;
    --uids)         MODE="uids";    UIDS="$2";         shift 2 ;;
    --search)       MODE="search";  SEARCH_TERM="$2";  shift 2 ;;
    --songs)        MODE="songs";   SONGS="$2";        shift 2 ;;
    --from-scripts) MODE="scripts"; SCRIPTS_DIR="$2";  shift 2 ;;
    --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

# --- from-scripts: parse [SONG: Artist - Title] markers ---
if [[ "$MODE" == "scripts" ]]; then
  if [[ -z "$SCRIPTS_DIR" || ! -d "$SCRIPTS_DIR" ]]; then
    error "Scripts directory not found: $SCRIPTS_DIR"
    exit 1
  fi
  log "Parsing [SONG:] markers from $SCRIPTS_DIR/*.md"
  PARSED_SONGS=$(grep -roh '\[SONG: [^]]*\]' "$SCRIPTS_DIR"/*.md 2>/dev/null \
    | sed 's/\[SONG: //; s/\]//' \
    | sort -u \
    | paste -sd ',' -)
  if [[ -z "$PARSED_SONGS" ]]; then
    error "No [SONG: Artist - Title] markers found in scripts"
    exit 1
  fi
  count=$(echo "$PARSED_SONGS" | tr ',' '\n' | wc -l)
  log "Found $count unique songs"
  echo "$PARSED_SONGS" | tr ',' '\n' >&2
  # Switch to songs mode with the parsed list
  MODE="songs"
  SONGS="$PARSED_SONGS"
fi

if [[ -z "$MODE" ]]; then
  error "One of --uids, --search, --songs, or --from-scripts is required."
  usage
fi

if [[ "$MODE" != "search" && -z "$OUTPUT_DIR" ]]; then
  error "--output-dir is required for download modes."
  exit 1
fi

# --- helpers ---
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; echo "$s"; }

# Run a SQL query on the remote PlayoutONE server.
# Writes SQL to a temp file on the Windows box to avoid shell-escaping issues.
run_sql() {
  local sql="$1"
  echo "$sql" > "/tmp/query_$$.sql"
  scp -q "/tmp/query_$$.sql" "$SSH_HOST:C:/temp/query.sql"
  ssh "$SSH_HOST" "sqlcmd -S localhost -d $DB -E -W -h -1 -s \"|\" -i C:\\temp\\query.sql"
  rm -f "/tmp/query_$$.sql"
}

# Get duration in ms via ffprobe (returns empty string if unavailable)
get_duration_ms() {
  local file="$1"
  if command -v ffprobe &>/dev/null; then
    local dur
    dur=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || true)
    if [[ -n "$dur" ]]; then
      # Convert seconds (float) to milliseconds (int)
      awk "BEGIN { printf \"%d\", ${dur} * 1000 }"
      return
    fi
  fi
  echo ""
}

# Download a file from the remote PlayoutONE Audio directory.
# Tries .mp3 first, then .wav.
download_file() {
  local basename="$1"  # filename without extension from DB
  local dest_dir="$2"
  local local_path=""

  # Strip any extension the DB might already include
  local stem="${basename%.*}"

  for ext in mp3 wav; do
    local remote_file="${REMOTE_AUDIO_DIR}\\${stem}.${ext}"
    local local_file="${dest_dir}/${stem}.${ext}"
    log "Trying ${stem}.${ext} ..."
    if ssh "$SSH_HOST" "type \"${remote_file}\"" > "$local_file" 2>/dev/null; then
      if [[ -s "$local_file" ]]; then
        ok "Downloaded ${stem}.${ext}"
        local_path="$local_file"
        break
      else
        rm -f "$local_file"
      fi
    else
      rm -f "$local_file"
    fi
  done

  echo "$local_path"
}

# --- search mode ---
do_search() {
  local term="$1"
  log "Searching for: ${term}"
  local sql="SELECT UID, Title, Artist, Filename FROM Audio WHERE Artist LIKE ''%${term}%'' OR Title LIKE ''%${term}%''"
  local results
  results=$(run_sql "$sql") || { error "SQL query failed"; exit 1; }

  if [[ -z "$results" ]]; then
    warn "No results found for '${term}'"
    return
  fi

  # Print table header to stderr
  printf "${CYAN}%-8s %-30s %-30s %-40s${RESET}\n" "UID" "ARTIST" "TITLE" "FILENAME" >&2
  printf '%.0s-' {1..110} >&2
  echo >&2

  while IFS='|' read -r uid title artist filename; do
    # Trim whitespace
    uid=$(trim "$uid")
    title=$(trim "$title")
    artist=$(trim "$artist")
    filename=$(trim "$filename")
    [[ -z "$uid" ]] && continue
    printf "%-8s %-30s %-30s %-40s\n" "$uid" "$artist" "$title" "$filename" >&2
  done <<< "$results"
}

# --- uid download mode ---
do_uids() {
  local uid_csv="$1"
  local dest="$2"
  mkdir -p "$dest"

  IFS=',' read -ra uid_arr <<< "$uid_csv"
  local uid_list=""
  for u in "${uid_arr[@]}"; do
    u=$(trim "$u")
    [[ -n "$uid_list" ]] && uid_list="${uid_list},"
    uid_list="${uid_list}${u}"
  done

  log "Querying UIDs: ${uid_list}"
  local sql="SELECT UID, Title, Artist, Filename FROM Audio WHERE UID IN (${uid_list})"
  local results
  results=$(run_sql "$sql") || { error "SQL query failed"; exit 1; }

  if [[ -z "$results" ]]; then
    error "No songs found for UIDs: ${uid_list}"
    exit 1
  fi

  local manifest="["
  local first=true

  while IFS='|' read -r uid title artist filename; do
    uid=$(trim "$uid")
    title=$(trim "$title")
    artist=$(trim "$artist")
    filename=$(trim "$filename")
    [[ -z "$uid" ]] && continue

    log "Downloading UID ${uid}: ${artist} - ${title}"
    local local_path
    local_path=$(download_file "$filename" "$dest")

    if [[ -z "$local_path" ]]; then
      warn "Failed to download UID ${uid}: ${filename}"
      continue
    fi

    local duration_ms
    duration_ms=$(get_duration_ms "$local_path")

    $first || manifest="${manifest},"
    first=false

    # Escape JSON strings (handle quotes in titles/artists)
    local j_title="${title//\"/\\\"}"
    local j_artist="${artist//\"/\\\"}"
    local j_filename="${filename//\"/\\\"}"
    local j_local="${local_path//\"/\\\"}"

    manifest="${manifest}{\"uid\":${uid},\"title\":\"${j_title}\",\"artist\":\"${j_artist}\",\"filename\":\"${j_filename}\",\"local_path\":\"${j_local}\",\"duration_ms\":${duration_ms:-null}}"
  done <<< "$results"

  manifest="${manifest}]"
  echo "$manifest"
}

# --- songs (artist - title) mode ---
do_songs() {
  local songs_csv="$1"
  local dest="$2"
  mkdir -p "$dest"

  local manifest="["
  local first=true

  IFS=',' read -ra song_arr <<< "$songs_csv"
  for entry in "${song_arr[@]}"; do
    entry=$(trim "$entry")
    # Split on " - "
    local artist="${entry%% - *}"
    local title="${entry#* - }"
    artist=$(trim "$artist")
    title=$(trim "$title")

    if [[ -z "$artist" || -z "$title" ]]; then
      warn "Skipping malformed entry: '${entry}'"
      continue
    fi

    local artist_esc="${artist//\'/\'\'}"
    local title_esc="${title//\'/\'\'}"

    log "Searching: ${artist} - ${title}"
    local sql="SET NOCOUNT ON; SELECT TOP 1 UID, Title, Artist, Filename FROM Audio WHERE Artist LIKE '%${artist_esc}%' AND Title LIKE '%${title_esc}%'"
    local result
    result=$(run_sql "$sql" | grep "|" | head -1 || true)

    if [[ -z "$result" ]]; then
      warn "No match for: ${artist} - ${title}"
      continue
    fi

    local uid title_db artist_db filename
    IFS='|' read -r uid title_db artist_db filename <<< "$result"
    
    # Strip whitespace without xargs (avoids quote errors)
    uid="${uid#"${uid%%[![:space:]]*}"}"; uid="${uid%"${uid##*[![:space:]]}"}"
    title_db="${title_db#"${title_db%%[![:space:]]*}"}"; title_db="${title_db%"${title_db##*[![:space:]]}"}"
    artist_db="${artist_db#"${artist_db%%[![:space:]]*}"}"; artist_db="${artist_db%"${artist_db##*[![:space:]]}"}"
    filename="${filename#"${filename%%[![:space:]]*}"}"; filename="${filename%"${filename##*[![:space:]]}"}"

    ok "Found UID ${uid}: ${artist_db} - ${title_db}"
    local local_path
    local_path=$(download_file "$filename" "$dest")

    if [[ -z "$local_path" ]]; then
      warn "Failed to download: ${artist_db} - ${title_db}"
      continue
    fi

    local duration_ms
    duration_ms=$(get_duration_ms "$local_path")

    $first || manifest="${manifest},"
    first=false

    local j_title="${title_db//\"/\\\"}"
    local j_artist="${artist_db//\"/\\\"}"
    local j_filename="${filename//\"/\\\"}"
    local j_local="${local_path//\"/\\\"}"

    manifest="${manifest}{\"uid\":${uid},\"title\":\"${j_title}\",\"artist\":\"${j_artist}\",\"filename\":\"${j_filename}\",\"local_path\":\"${j_local}\",\"duration_ms\":${duration_ms:-null}}"
  done

  manifest="${manifest}]"
  echo "$manifest"
}

# --- main dispatch ---
case "$MODE" in
  search) do_search "$SEARCH_TERM" ;;
  uids)   do_uids "$UIDS" "$OUTPUT_DIR" ;;
  songs)  do_songs "$SONGS" "$OUTPUT_DIR" ;;
esac
