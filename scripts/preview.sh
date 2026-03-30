#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[preview]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[preview]${RESET} $*" >&2; }
err()   { echo -e "${RED}[preview]${RESET} $*" >&2; }
info()  { echo -e "${CYAN}[preview]${RESET} $*" >&2; }

# --- Help ---
usage() {
  cat >&2 <<'EOF'
Usage: preview.sh --audio-dir <dir> [--send] [--help]

Compress morning show hour files to 128kbps for Telegram preview.

Options:
  --audio-dir <dir>   Directory containing hour MP3s
  --send              Actually send via openclaw message tool (default: print command only)
  --help              Show this help message

Input files (searched in order):
  FULL-HOUR{1-4}-COMPLETE.mp3
  MORNING-SHOW-H{1-4}.mp3

Output:
  HOUR{N}-REVIEW.mp3 in the same directory, 128kbps

Examples:
  preview.sh --audio-dir /path/to/show/2026-03-30/
  preview.sh --audio-dir ./output --send
EOF
  exit 0
}

# --- Parse args ---
AUDIO_DIR=""
SEND=false

[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio-dir) AUDIO_DIR="$2"; shift 2 ;;
    --send)      SEND=true; shift ;;
    --help|-h)   usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$AUDIO_DIR" ]]; then
  err "--audio-dir is required"
  exit 1
fi

if [[ ! -d "$AUDIO_DIR" ]]; then
  err "Directory not found: $AUDIO_DIR"
  exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
  err "ffmpeg is required but not found"
  exit 1
fi

if ! command -v ffprobe &>/dev/null; then
  err "ffprobe is required but not found"
  exit 1
fi

# --- Find and compress hours ---
FOUND=0
TOTAL_SIZE=0

for N in 1 2 3 4; do
  SRC=""
  # Try naming conventions in order
  for pattern in "FULL-HOUR${N}-COMPLETE.mp3" "MORNING-SHOW-H${N}.mp3"; do
    candidate="${AUDIO_DIR%/}/${pattern}"
    if [[ -f "$candidate" ]]; then
      SRC="$candidate"
      break
    fi
  done

  if [[ -z "$SRC" ]]; then
    warn "Hour ${N}: no source file found, skipping"
    continue
  fi

  OUTPUT="${AUDIO_DIR%/}/HOUR${N}-REVIEW.mp3"
  FOUND=$((FOUND + 1))

  log "Hour ${N}: compressing ${BOLD}$(basename "$SRC")${RESET} -> HOUR${N}-REVIEW.mp3"

  ffmpeg -y -i "$SRC" \
    -b:a 128k -ar 44100 -ac 2 \
    "$OUTPUT" 2>/dev/null

  # Report duration and size
  duration_secs=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
  duration_int="${duration_secs%.*}"
  mins=$((duration_int / 60))
  secs=$((duration_int % 60))
  size_bytes=$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")
  size_mb=$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1048576}")
  TOTAL_SIZE=$((TOTAL_SIZE + size_bytes))

  if (( size_bytes > 52428800 )); then
    warn "  HOUR${N}-REVIEW.mp3: ${mins}:$(printf '%02d' "$secs") — ${CYAN}${size_mb}MB${RESET} ${RED}(exceeds 50MB Telegram limit!)${RESET}"
  else
    info "  HOUR${N}-REVIEW.mp3: ${mins}:$(printf '%02d' "$secs") — ${CYAN}${size_mb}MB${RESET}"
  fi
done

if [[ $FOUND -eq 0 ]]; then
  err "No hour files found in $AUDIO_DIR"
  err "Expected: FULL-HOUR{1-4}-COMPLETE.mp3 or MORNING-SHOW-H{1-4}.mp3"
  exit 1
fi

total_mb=$(awk "BEGIN {printf \"%.1f\", $TOTAL_SIZE / 1048576}")
echo "" >&2
log "Compressed ${BOLD}${FOUND}${RESET} hour(s) — total preview size: ${CYAN}${total_mb}MB${RESET}"

# --- Send via openclaw message tool ---
echo "" >&2
for N in 1 2 3 4; do
  REVIEW="${AUDIO_DIR%/}/HOUR${N}-REVIEW.mp3"
  [[ -f "$REVIEW" ]] || continue

  CMD="openclaw message --to 8048875001 --file \"${REVIEW}\" --caption \"Hour ${N} preview\""

  if [[ "$SEND" == true ]]; then
    log "Sending Hour ${N} preview..."
    eval "$CMD"
  else
    info "Would run: ${CYAN}${CMD}${RESET}"
  fi
done

if [[ "$SEND" == false ]]; then
  echo "" >&2
  info "Use ${BOLD}--send${RESET} to actually send previews via Telegram"
fi
