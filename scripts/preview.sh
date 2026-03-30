#!/usr/bin/env bash
# preview.sh — Compress morning show hour blocks to 128kbps for Telegram preview
#
# Part of the WPFQ Morning Show pipeline (step 7 of 8).
# Takes full-quality hour MP3s (192kbps, ~50-70MB each) and compresses
# them to 128kbps review copies under 50MB (Telegram file size limit).
#
# Input:  MORNING-SHOW-H{N}.mp3 or FULL-HOUR{N}-COMPLETE.mp3
# Output: {BASENAME}-REVIEW.mp3 in same directory
#
# The script auto-detects hour numbers from filenames (H5=5AM, H6=6AM, etc.)
# so it works with any hour numbering scheme, not just H1-H4.
#
# Usage:
#   preview.sh --audio-dir shows/2026-03-31/audio/          # dry run
#   preview.sh --audio-dir shows/2026-03-31/audio/ --send    # send via Telegram
#
# Called by: build-show.sh --step preview
# Depends on: ffmpeg, ffprobe, openclaw CLI (for --send)
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

for SRC in "${AUDIO_DIR%/}"/MORNING-SHOW-H*.mp3 "${AUDIO_DIR%/}"/FULL-HOUR*-COMPLETE.mp3; do
  [[ -f "$SRC" ]] || continue
  BASENAME="$(basename "$SRC" .mp3)"
  # Extract hour number from filename
  N=$(echo "$BASENAME" | grep -oP '\d+' | tail -1)

  OUTPUT="${AUDIO_DIR%/}/${BASENAME}-REVIEW.mp3"
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
    warn "  ${BASENAME}-REVIEW.mp3: ${mins}:$(printf '%02d' "$secs") — ${CYAN}${size_mb}MB${RESET} ${RED}(exceeds 50MB Telegram limit!)${RESET}"
  else
    info "  ${BASENAME}-REVIEW.mp3: ${mins}:$(printf '%02d' "$secs") — ${CYAN}${size_mb}MB${RESET}"
  fi
done

if [[ $FOUND -eq 0 ]]; then
  err "No hour files found in $AUDIO_DIR"
  err "Expected: MORNING-SHOW-H*.mp3 or FULL-HOUR*-COMPLETE.mp3"
  exit 1
fi

total_mb=$(awk "BEGIN {printf \"%.1f\", $TOTAL_SIZE / 1048576}")
echo "" >&2
log "Compressed ${BOLD}${FOUND}${RESET} hour(s) — total preview size: ${CYAN}${total_mb}MB${RESET}"

# --- Send via openclaw message tool ---
echo "" >&2
for REVIEW in "${AUDIO_DIR%/}"/*-REVIEW.mp3; do
  [[ -f "$REVIEW" ]] || continue
  RNAME="$(basename "$REVIEW")"

  CMD="openclaw message --to 8048875001 --file \"${REVIEW}\" --caption \"${RNAME} preview\""

  if [[ "$SEND" == true ]]; then
    log "Sending ${RNAME}..."
    eval "$CMD"
  else
    info "Would run: ${CYAN}${CMD}${RESET}"
  fi
done

if [[ "$SEND" == false ]]; then
  echo "" >&2
  info "Use ${BOLD}--send${RESET} to actually send previews via Telegram"
fi
