#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[+]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*" >&2; }
err()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
info()  { echo -e "${CYAN}[i]${RESET} $*" >&2; }

# --- Paths (resolved relative to this script) ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR_SELF="$(dirname "$SCRIPT_PATH")"
MORNING_SHOW_ROOT="$(cd "$SCRIPT_DIR_SELF/.." && pwd)"

# --- LUFS delta logging (Wave 3 Task 17, Q2.2=c) ----------------------------
# We measure the music library's median LUFS for reference and log the delta
# from our hardcoded -16 LUFS production target. This is OBSERVATION ONLY —
# the production loudnorm filter below stays at I=-16 per Q2.2=c. The delta
# is reviewed periodically to decide whether to switch targets in v1.x.
log_lufs_delta() {
  local target_lufs="-16"
  local lufs_json="${LIBRARY_LUFS_PATH_OVERRIDE:-$MORNING_SHOW_ROOT/references/library-lufs.json}"
  local traces_path="${TRACES_PATH_OVERRIDE:-$MORNING_SHOW_ROOT/.planning/TRACES.md}"
  local show_date="${SHOW_DATE_OVERRIDE:-$(date -u +%Y-%m-%d)}"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Ensure the TRACES.md parent directory exists; create the file if missing.
  mkdir -p "$(dirname "$traces_path")"
  if [[ ! -f "$traces_path" ]]; then
    {
      echo "# Execution Traces: morning-show"
      echo
      echo "> Captured by Jarvis Development Methodology"
      echo
    } > "$traces_path"
  fi

  local console_line
  local trace_line

  if [[ ! -f "$lufs_json" ]]; then
    console_line="[LUFS delta: library-lufs.json not found, delta unknown — run measure-library-lufs.sh]"
    trace_line="| $timestamp | $show_date | LUFS delta | library-lufs.json not found, delta unknown |"
    warn "$console_line"
    echo "$trace_line" >> "$traces_path"
    return 0
  fi

  # Validate JSON + extract median_lufs. jq returns "null" for missing keys.
  local median_lufs=""
  if command -v jq &>/dev/null; then
    median_lufs="$(jq -r '.median_lufs // empty' "$lufs_json" 2>/dev/null || true)"
  fi

  if [[ -z "$median_lufs" || "$median_lufs" == "null" ]]; then
    console_line="[LUFS delta: library-lufs.json not found, delta unknown — malformed or missing median_lufs]"
    trace_line="| $timestamp | $show_date | LUFS delta | library-lufs.json not found, delta unknown (malformed) |"
    warn "$console_line"
    echo "$trace_line" >> "$traces_path"
    return 0
  fi

  # delta = target - library_median  (positive = target louder than library)
  local delta
  delta="$(awk -v t="$target_lufs" -v m="$median_lufs" 'BEGIN { printf "%+.1f", t - m }')"

  console_line="[LUFS delta: target ${target_lufs}, library median ${median_lufs}, delta ${delta} LU]"
  trace_line="| $timestamp | $show_date | LUFS delta | target=${target_lufs} library_median=${median_lufs} delta=${delta} LU |"

  info "$console_line"
  echo "$trace_line" >> "$traces_path"
  return 0
}

# Always log the LUFS delta at the start of an invocation so we have a trace
# for every show build (and for the stub mode below).
log_lufs_delta

# Stub mode: log delta + exit. Used by test harness so we don't need fixtures.
if [[ "${PRODUCE_HOUR_LUFS_DELTA_ONLY:-0}" == "1" ]]; then
  exit 0
fi

usage() {
  cat <<'EOF'
Usage: produce-hour.sh [OPTIONS]

Assembles a radio hour from talk segments and songs, normalizing audio levels.

Options:
  --talk-dir <dir>       Directory containing talk segment MP3s
  --songs-dir <dir>      Directory containing song MP3s
  --sequence <json>      JSON file defining playback order (see below)
  --interleave           Auto-alternate talk segments and songs (sorted order)
  --output <mp3_path>    Output MP3 file path (required)
  --preview              Also create a 128kbps preview version (*-preview.mp3)
  --help                 Show this help

Sequence JSON format:
  [
    {"type": "talk", "file": "01-open.mp3"},
    {"type": "song", "file": "cocaine.mp3"},
    {"type": "talk", "file": "02-weather.mp3"},
    ...
  ]

  "type" determines which directory the file is pulled from.

Interleave mode:
  Sorts talk and song files alphabetically, then alternates: talk, song, talk, song...
  If one list is longer, remaining files are appended at the end.

Audio normalization:
  All inputs are normalized to: 44100Hz, stereo, 192kbps, loudnorm (I=-16, TP=-1.5, LRA=11)

Examples:
  produce-hour.sh --talk-dir segments/ --songs-dir music/ --sequence hour1.json --output hour1.mp3
  produce-hour.sh --talk-dir segments/ --songs-dir music/ --interleave --output hour1.mp3 --preview
EOF
  exit 0
}

# --- Defaults ---
TALK_DIR=""
SONGS_DIR=""
SEQUENCE_FILE=""
INTERLEAVE=false
OUTPUT=""
PREVIEW=false

# --- Parse args ---
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --talk-dir)   TALK_DIR="$2"; shift 2 ;;
    --songs-dir)  SONGS_DIR="$2"; shift 2 ;;
    --sequence)   SEQUENCE_FILE="$2"; shift 2 ;;
    --interleave) INTERLEAVE=true; shift ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --preview)    PREVIEW=true; shift ;;
    --help)       usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$OUTPUT" ]]; then
  err "--output is required"
  exit 1
fi

if [[ -z "$TALK_DIR" || -z "$SONGS_DIR" ]]; then
  err "--talk-dir and --songs-dir are required"
  exit 1
fi

if [[ ! -d "$TALK_DIR" ]]; then
  err "Talk directory not found: $TALK_DIR"
  exit 1
fi

if [[ ! -d "$SONGS_DIR" ]]; then
  err "Songs directory not found: $SONGS_DIR"
  exit 1
fi

if [[ -z "$SEQUENCE_FILE" ]] && [[ "$INTERLEAVE" == false ]]; then
  err "Must specify either --sequence <json> or --interleave"
  exit 1
fi

if [[ -n "$SEQUENCE_FILE" ]] && [[ ! -f "$SEQUENCE_FILE" ]]; then
  err "Sequence file not found: $SEQUENCE_FILE"
  exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
  err "ffmpeg is required but not found"
  exit 1
fi

if [[ -n "$SEQUENCE_FILE" ]] && ! command -v jq &>/dev/null; then
  err "jq is required for --sequence mode but not found"
  exit 1
fi

# --- Temp dir with cleanup trap ---
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# --- Build file list ---
declare -a FILE_LIST=()

if [[ -n "$SEQUENCE_FILE" ]]; then
  log "Reading sequence from: $SEQUENCE_FILE"
  count=$(jq length "$SEQUENCE_FILE")
  for ((i = 0; i < count; i++)); do
    ftype=$(jq -r ".[$i].type" "$SEQUENCE_FILE")
    fname=$(jq -r ".[$i].file" "$SEQUENCE_FILE")
    if [[ "$ftype" == "talk" ]]; then
      fpath="${TALK_DIR%/}/$fname"
    elif [[ "$ftype" == "song" ]]; then
      fpath="${SONGS_DIR%/}/$fname"
    else
      err "Unknown type '$ftype' at index $i"
      exit 1
    fi
    if [[ ! -f "$fpath" ]]; then
      err "File not found: $fpath"
      exit 1
    fi
    FILE_LIST+=("$fpath")
  done
else
  log "Interleave mode: alternating talk segments and songs"
  mapfile -t talks < <(find "$TALK_DIR" -maxdepth 1 -name '*.mp3' -type f | sort)
  mapfile -t songs < <(find "$SONGS_DIR" -maxdepth 1 -name '*.mp3' -type f | sort)

  if [[ ${#talks[@]} -eq 0 ]]; then
    err "No MP3 files found in talk dir: $TALK_DIR"
    exit 1
  fi
  if [[ ${#songs[@]} -eq 0 ]]; then
    err "No MP3 files found in songs dir: $SONGS_DIR"
    exit 1
  fi

  info "Found ${#talks[@]} talk segments, ${#songs[@]} songs"

  max=$(( ${#talks[@]} > ${#songs[@]} ? ${#talks[@]} : ${#songs[@]} ))
  for ((i = 0; i < max; i++)); do
    if [[ $i -lt ${#talks[@]} ]]; then
      FILE_LIST+=("${talks[$i]}")
    fi
    if [[ $i -lt ${#songs[@]} ]]; then
      FILE_LIST+=("${songs[$i]}")
    fi
  done
fi

info "Total files to process: ${#FILE_LIST[@]}"

# --- Normalize all inputs ---
log "Normalizing audio files..."
CONCAT_LIST="$TMPDIR_WORK/concat.txt"
> "$CONCAT_LIST"

for idx in "${!FILE_LIST[@]}"; do
  src="${FILE_LIST[$idx]}"
  normalized="$TMPDIR_WORK/$(printf '%04d' "$idx").mp3"
  basename_src="$(basename "$src")"
  info "  [$((idx + 1))/${#FILE_LIST[@]}] $basename_src"

  ffmpeg -y -i "$src" \
    -ar 44100 -ac 2 -b:a 192k \
    -af 'loudnorm=I=-16:TP=-1.5:LRA=11' \
    "$normalized" 2>/dev/null

  echo "file '$normalized'" >> "$CONCAT_LIST"
done

# --- Concatenate ---
log "Concatenating ${#FILE_LIST[@]} files..."
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
  -c:a libmp3lame -b:a 192k \
  "$OUTPUT" 2>/dev/null

# --- Preview ---
if [[ "$PREVIEW" == true ]]; then
  PREVIEW_PATH="${OUTPUT%.mp3}-preview.mp3"
  log "Creating preview: $PREVIEW_PATH"
  ffmpeg -y -i "$OUTPUT" \
    -b:a 128k \
    "$PREVIEW_PATH" 2>/dev/null
fi

# --- Report ---
duration_secs=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
duration_int="${duration_secs%.*}"
mins=$((duration_int / 60))
secs=$((duration_int % 60))
filesize=$(du -h "$OUTPUT" | cut -f1)

echo "" >&2
log "Done!"
info "  Output:   $OUTPUT"
info "  Duration: ${mins}:$(printf '%02d' "$secs")"
info "  Size:     $filesize"

if [[ "$PREVIEW" == true ]]; then
  preview_size=$(du -h "$PREVIEW_PATH" | cut -f1)
  info "  Preview:  $PREVIEW_PATH ($preview_size)"
fi
