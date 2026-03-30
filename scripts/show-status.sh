#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWS_DIR="${SCRIPT_DIR}/../shows"

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: show-status.sh [--date YYYY-MM-DD]"
    echo ""
    echo "Show status of morning show builds."
    echo "Without --date: lists all shows with status."
    echo "With --date: detailed status of specific show."
    exit 0
fi

DATE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) DATE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$DATE" ]]; then
    echo -e "${CYAN}Morning Show Status${RESET}"
    echo "════════════════════════════════"
    if [[ ! -d "$SHOWS_DIR" ]]; then
        echo "No shows directory found."
        exit 0
    fi
    for dir in "$SHOWS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        d=$(basename "$dir")
        scripts=$(find "$dir/scripts" -name "HOUR*.md" 2>/dev/null | wc -l)
        segments=$(find "$dir/segments" -name "*.mp3" 2>/dev/null | wc -l)
        audio=$(find "$dir/audio" -name "MORNING-SHOW-*.mp3" 2>/dev/null | wc -l)
        if [[ $audio -gt 0 ]]; then
            status="${GREEN}PRODUCED${RESET}"
        elif [[ $segments -gt 0 ]]; then
            status="${YELLOW}RENDERED${RESET}"
        elif [[ $scripts -gt 0 ]]; then
            status="${YELLOW}SCRIPTED${RESET}"
        else
            status="${RED}EMPTY${RESET}"
        fi
        echo -e "  $d  $status  (scripts=$scripts segments=$segments audio=$audio)"
    done
else
    dir="$SHOWS_DIR/$DATE"
    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}No show found for $DATE${RESET}"
        exit 1
    fi
    echo -e "${CYAN}Show: $DATE${RESET}"
    echo "════════════════════════════════"
    [[ -f "$dir/research.json" ]] && echo -e "  Research:  ${GREEN}✅${RESET}" || echo -e "  Research:  ${RED}❌${RESET}"
    scripts=$(find "$dir/scripts" -name "HOUR*.md" 2>/dev/null | wc -l)
    echo -e "  Scripts:   $scripts hours"
    segments=$(find "$dir/segments" -name "*.mp3" 2>/dev/null | wc -l)
    echo -e "  Segments:  $segments rendered"
    audio=$(find "$dir/audio" -name "MORNING-SHOW-*.mp3" 2>/dev/null | wc -l)
    echo -e "  Audio:     $audio hour blocks"
    if [[ -f "$dir/manifest.json" ]]; then
        echo -e "  Manifest:  ${GREEN}✅${RESET}"
        cat "$dir/manifest.json"
    fi
fi
