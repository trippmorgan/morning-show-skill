#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[write]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[write]${RESET} $*" >&2; }
err()   { echo -e "${RED}[write]${RESET} $*" >&2; }
info()  { echo -e "${CYAN}[write]${RESET} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$SKILL_DIR/templates"
SEGMENTS_DIR="$TEMPLATES_DIR/segments"
REFERENCES_DIR="$SKILL_DIR/references"

# --- Help ---
usage() {
  cat >&2 <<'EOF'
Usage: write-scripts.sh --day <day> --date <YYYY-MM-DD> --research <json> --output-dir <dir> [OPTIONS]

Generate morning show scripts from templates and research data.

Required:
  --day <day>           Day of week (monday, tuesday, etc.)
  --date <YYYY-MM-DD>   Show date
  --research <json>     Research JSON file (from research-date.sh)
  --output-dir <dir>    Directory for output script files

Options:
  --prompt-only         Output the LLM prompt to stdout without calling claude
  --dry-run             Show loaded templates and research, no LLM call
  --help                Show this help message

Output:
  HOUR{1-4}-{DAY}-{DATE}.md files in output-dir
  Each file contains segment markers: ### SEGMENT 1: THE OPEN, ### SEGMENT 2: WEATHER, etc.

Examples:
  write-scripts.sh --day monday --date 2026-03-30 --research research.json --output-dir ./scripts
  write-scripts.sh --day monday --date 2026-03-30 --research research.json --output-dir ./scripts --prompt-only > prompt.txt
  write-scripts.sh --day monday --date 2026-03-30 --research research.json --output-dir ./scripts --dry-run
EOF
  exit 0
}

# --- Parse args ---
DAY=""
SHOW_DATE=""
RESEARCH_FILE=""
OUTPUT_DIR=""
PROMPT_ONLY=false
DRY_RUN=false

[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --day)        DAY="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --date)       SHOW_DATE="$2"; shift 2 ;;
    --research)   RESEARCH_FILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --prompt-only) PROMPT_ONLY=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --help|-h)    usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$DAY" || -z "$SHOW_DATE" || -z "$RESEARCH_FILE" || -z "$OUTPUT_DIR" ]]; then
  err "Missing required arguments. Use --help for usage."
  exit 1
fi

if ! [[ "$SHOW_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  err "Invalid date format: $SHOW_DATE (expected YYYY-MM-DD)"
  exit 1
fi

DAY_TEMPLATE="$TEMPLATES_DIR/${DAY}.md"
if [[ ! -f "$DAY_TEMPLATE" ]]; then
  err "Day template not found: $DAY_TEMPLATE"
  err "Available: $(ls "$TEMPLATES_DIR"/*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ' ')"
  exit 1
fi

if [[ ! -f "$RESEARCH_FILE" ]]; then
  err "Research file not found: $RESEARCH_FILE"
  exit 1
fi

PERSONA_FILE="$REFERENCES_DIR/dr-johnny-fever.md"
if [[ ! -f "$PERSONA_FILE" ]]; then
  err "Persona file not found: $PERSONA_FILE"
  exit 1
fi

# --- Load templates ---
log "Loading templates..."

DAY_UPPER="$(echo "$DAY" | tr '[:lower:]' '[:upper:]')"

info "  Day template: ${DAY}.md"
DAY_CONTENT="$(cat "$DAY_TEMPLATE")"

info "  Persona: dr-johnny-fever.md"
PERSONA_CONTENT="$(cat "$PERSONA_FILE")"

# Load all segment templates
SEGMENTS_CONTENT=""
for seg_file in "$SEGMENTS_DIR"/*.md; do
  seg_name="$(basename "$seg_file" .md)"
  info "  Segment: ${seg_name}.md"
  SEGMENTS_CONTENT+="
--- SEGMENT TEMPLATE: ${seg_name} ---
$(cat "$seg_file")
"
done

# Load research data
info "  Research: $(basename "$RESEARCH_FILE")"
RESEARCH_CONTENT="$(cat "$RESEARCH_FILE")"

# Extract key research fields for display
if command -v jq &>/dev/null; then
  R_DATE=$(jq -r '.date // "unknown"' "$RESEARCH_FILE")
  R_DAY=$(jq -r '.day_name // "unknown"' "$RESEARCH_FILE")
  R_HIGH=$(jq -r '.weather.high_f // "?"' "$RESEARCH_FILE")
  R_LOW=$(jq -r '.weather.low_f // "?"' "$RESEARCH_FILE")
  R_DESC=$(jq -r '.weather.description // "?"' "$RESEARCH_FILE")
  info "  Research date: ${CYAN}${R_DAY}, ${R_DATE}${RESET}"
  info "  Weather: ${R_HIGH}°F / ${R_LOW}°F — ${R_DESC}"
fi

# --- Dry run ---
if [[ "$DRY_RUN" == true ]]; then
  echo "" >&2
  log "=== DRY RUN ==="
  info "Day template: ${DAY}.md ($(wc -l < "$DAY_TEMPLATE") lines)"
  info "Persona: dr-johnny-fever.md ($(wc -l < "$PERSONA_FILE") lines)"
  info "Segments: $(ls "$SEGMENTS_DIR"/*.md | wc -l) templates"
  info "Research: $(basename "$RESEARCH_FILE")"
  echo "" >&2
  info "Would generate:"
  for N in 1 2 3 4; do
    info "  HOUR${N}-${DAY_UPPER}-${SHOW_DATE}.md"
  done
  echo "" >&2
  info "Prompt would include: persona + day template + segment templates + research JSON"
  info "Use --prompt-only to see the full prompt."
  exit 0
fi

# --- Build prompt ---
log "Building LLM prompt..."

PROMPT="$(cat <<PROMPT_EOF
You are a radio script writer for WPFQ 96.7, Pretoria Fields Radio in Albany, GA.

# YOUR TASK
Write four complete hour-by-hour morning show scripts for ${R_DAY:-$DAY}, ${SHOW_DATE}.
Output exactly 4 files worth of content, clearly separated. Each hour script must be a complete, ready-to-read radio script.

# OUTPUT FORMAT — FOLLOW EXACTLY
You must output exactly 4 complete radio scripts, one per hour.
Each script must contain the full spoken-word text for every segment.

Separate hours with EXACTLY this line (nothing else on the line):
===HOUR_BREAK===

Do NOT write summaries, outlines, or descriptions. Write the ACTUAL WORDS the DJ says.

Each hour script structure:
---
## HOUR {N} — {TIME SLOT} — {TITLE}
**Energy:** {energy level}

### SEGMENT: THE OPEN
[Write every word Dr. Johnny Fever says — ~45 seconds of spoken dialogue]

### SONG BLOCK
[3 songs — list artist and title]

### SEGMENT: MUSIC HISTORY (or WEATHER or RANT or QUICK HITS depending on hour structure)
[Write every word — ~60 seconds for history/rant, ~25 seconds for weather]

### SONG BLOCK
[more songs]

[...continue through all segments per the day template...]

### CLOSE
[Write every word — ~25 seconds]
---

The scripts are for voice synthesis. Every word must be written out. No placeholders.

# PERSONA
${PERSONA_CONTENT}

# DAY TEMPLATE (${DAY})
${DAY_CONTENT}

# SEGMENT TEMPLATES
These define the structure, tone, and duration targets for each segment type:
${SEGMENTS_CONTENT}

# RESEARCH DATA
Live data for this show date. Use this for weather, music history, birthdays, news, and any date-specific content.
\`\`\`json
${RESEARCH_CONTENT}
\`\`\`

# CRITICAL RULES
1. Write EVERY spoken word out fully — no placeholders like {{weather_high}}, no "[insert topic]", no stage directions in brackets
2. Fill in all weather data from the research JSON above
3. Music history, birthdays, and news marked as "placeholder" in research — use your knowledge to fill these in with REAL facts for this date
4. Follow the energy arc: Hour 1 = grumbly/low, Hour 2 = warming up, Hour 3 = peak energy, Hour 4 = winding down/warm
5. Each spoken segment should be natural, conversational radio — written for the voice, not the page
6. Station ID (WPFQ 96.7, Pretoria Fields Radio, Albany Georgia) must appear in every hour open and close
7. Cross-promote other shows as specified in the day template
8. Keep rants to ~60 seconds of spoken word, opens to ~45 seconds, weather to ~25 seconds, closes to ~25 seconds
9. "Booker out" is ONLY used in the Hour 4 show close — never before
10. NEVER break the fourth wall about being AI. Dr. Johnny Fever IS the DJ. Period.
PROMPT_EOF
)"

# --- Output prompt or call LLM ---
if [[ "$PROMPT_ONLY" == true ]]; then
  echo "$PROMPT"
  log "Prompt written to stdout (${#PROMPT} chars)"
  exit 0
fi

# Call claude CLI once per hour (more reliable than single large call)
mkdir -p "$OUTPUT_DIR"
WRITTEN=0

# Hour time slots and energy levels
declare -A HOUR_TIME=( [1]="5:00-6:00 AM" [2]="6:00-7:00 AM" [3]="7:00-8:00 AM" [4]="8:00-9:00 AM" )
declare -A HOUR_ENERGY=( [1]="Low and grumbly — barely awake, maximum sarcasm" [2]="Warming up — coffee kicking in, sharper takes" [3]="PEAK — drive time, on fire, best bits" [4]="Cruising — settled, warm, winding down" )

for N in 1 2 3 4; do
  log "Generating Hour ${N}/4..."
  DEST="${OUTPUT_DIR%/}/HOUR${N}-${DAY_UPPER}-${SHOW_DATE}.md"

  HOUR_PROMPT="$(cat <<HOUREOF
${PROMPT}

# IMPORTANT — WRITE HOUR ${N} ONLY
You are writing HOUR ${N} of 4 (${HOUR_TIME[$N]}).
Energy level: ${HOUR_ENERGY[$N]}

Output ONLY the script for Hour ${N}. Do not write summaries, do not write all 4 hours.
Write the complete spoken-word script for Hour ${N} only.
Start immediately with the script content — no preamble.
HOUREOF
)"

  HOUR_OUTPUT=$(echo "$HOUR_PROMPT" | claude --permission-mode bypassPermissions --print 2>/dev/null || true)

  if [[ -z "$HOUR_OUTPUT" ]]; then
    warn "Hour ${N}: claude returned empty output"
    continue
  fi

  echo "$HOUR_OUTPUT" > "$DEST"
  lines=$(wc -l < "$DEST")
  info "  HOUR${N}-${DAY_UPPER}-${SHOW_DATE}.md (${lines} lines)"
  WRITTEN=$((WRITTEN + 1))
done

if [[ $WRITTEN -eq 0 ]]; then
  err "No hour scripts were generated."
  exit 1
fi

echo "" >&2
log "Generated ${BOLD}${WRITTEN}${RESET} hour script(s) in ${CYAN}${OUTPUT_DIR}${RESET}"
