#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWS_DIR="${SCRIPT_DIR}/../shows"

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: archive.sh --date YYYY-MM-DD [--keep-audio] [--dry-run]"
    echo ""
    echo "Archive a completed show. Removes rendered audio (mp3s) but keeps"
    echo "scripts, research, and text segments for reference."
    echo ""
    echo "Options:"
    echo "  --date YYYY-MM-DD   Show date to archive"
    echo "  --keep-audio        Keep audio files (just mark as archived)"
    echo "  --dry-run           Show what would be archived without doing it"
    echo "  --help              Show this help"
    exit 0
fi

DATE=""; KEEP_AUDIO=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) DATE="$2"; shift 2 ;;
        --keep-audio) KEEP_AUDIO=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

[[ -z "$DATE" ]] && { echo -e "${RED}--date required${RESET}"; exit 1; }

dir="$SHOWS_DIR/$DATE"
[[ -d "$dir" ]] || { echo -e "${RED}No show found for $DATE${RESET}"; exit 1; }

echo -e "${CYAN}Archiving show: $DATE${RESET}"

if [[ "$KEEP_AUDIO" == false ]]; then
    mp3s=$(find "$dir" -name "*.mp3" | wc -l)
    mp3_size=$(find "$dir" -name "*.mp3" -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)
    echo -e "  Removing $mp3s mp3 files (${mp3_size:-0})"
    if [[ "$DRY_RUN" == false ]]; then
        find "$dir" -name "*.mp3" -delete
    fi
fi

# Write archive marker
if [[ "$DRY_RUN" == false ]]; then
    echo "{\"archived\": \"$(date -Iseconds)\", \"date\": \"$DATE\", \"keep_audio\": $KEEP_AUDIO}" > "$dir/ARCHIVED.json"
    echo -e "${GREEN}✅ Archived $DATE${RESET}"
else
    echo -e "${YELLOW}[dry-run] Would archive $DATE${RESET}"
fi
