#!/usr/bin/env bash
# write-scripts.sh — Generate talk segment scripts via Claude Code CLI
#
# Part of the WPFQ Morning Show pipeline (step 3 of 8).
# Uses an LLM to write Johnny Fever-style talk segments for each hour,
# incorporating research data (weather, history, birthdays) and the
# day template (recurring features like Deep Cut Tuesday, Guitar God Spotlight).
#
# Segments are written as markdown with [SONG:Artist - Title] markers
# between talk blocks so downstream steps know where to interleave music.
#
# Output: scripts/hour-{N}.md per hour
#
# Called by: build-show.sh --step write
# Depends on: claude CLI (Anthropic)
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

# OUTPUT FORMAT
Output all four hours in a single response. Separate each hour with this exact delimiter on its own line:
===HOUR_BREAK===

Each hour script must follow this structure:
- Start with a YAML-style header: Hour number, time slot, energy level, title
- Use segment markers exactly like: ### SEGMENT 1: THE OPEN, ### SEGMENT 2: WEATHER, etc.
- Every spoken word should be written out as the DJ would say it (no placeholders, no bracketed instructions)
- Song blocks MUST use explicit machine-readable markers, one per line:
  [SONG: Artist - Title]
  Example:
  ### SONG BLOCK
  [SONG: Pearl Jam - Black]
  [SONG: Soundgarden - Black Hole Sun]
  [SONG: Alice in Chains - Down in a Hole]
- These markers are parsed by automation. Do NOT write "here is some music" without a [SONG:] marker
- Every song block needs 2-4 [SONG:] markers. Each hour needs 8-12 songs total
- Pick songs that actually exist — well-known tracks from established artists in the genre
- Promos and cross-promotions should be written out as spoken word

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
11. EVERY song block MUST contain [SONG: Artist - Title] markers — one per line, exactly that format
12. Each hour must have 8-12 [SONG:] markers total, distributed across 3-4 song blocks
13. Songs must be well-known tracks that would exist in a classic/alt/indie rock radio station library
14. After each talk segment that transitions to music, end with a natural segue AND the [SONG:] markers
PROMPT_EOF
)"

# --- Output prompt or call LLM ---
if [[ "$PROMPT_ONLY" == true ]]; then
  echo "$PROMPT"
  log "Prompt written to stdout (${#PROMPT} chars)"
  exit 0
fi

# Call claude CLI
mkdir -p "$OUTPUT_DIR"
log "Calling claude to generate scripts..."

RAW_OUTPUT=$(claude --permission-mode bypassPermissions --print "$PROMPT" 2>/dev/null)

if [[ -z "$RAW_OUTPUT" ]]; then
  err "claude returned empty output"
  exit 1
fi

# --- Split into hour files ---
log "Splitting output into hour files..."

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

echo "$RAW_OUTPUT" > "$TMPDIR_WORK/raw.md"

# Split on ===HOUR_BREAK===
awk -v outdir="$TMPDIR_WORK" '
  BEGIN { file = 1 }
  /^===HOUR_BREAK===$/ { file++; next }
  { print >> (outdir "/hour" file ".md") }
' "$TMPDIR_WORK/raw.md"

WRITTEN=0
for N in 1 2 3 4; do
  SRC="$TMPDIR_WORK/hour${N}.md"
  DEST="${OUTPUT_DIR%/}/HOUR${N}-${DAY_UPPER}-${SHOW_DATE}.md"

  if [[ -f "$SRC" ]] && [[ -s "$SRC" ]]; then
    # Trim leading blank lines
    sed '/./,$!d' "$SRC" > "$DEST"
    lines=$(wc -l < "$DEST")
    info "  HOUR${N}-${DAY_UPPER}-${SHOW_DATE}.md (${lines} lines)"
    WRITTEN=$((WRITTEN + 1))
  else
    warn "  Hour ${N}: no content generated"
  fi
done

if [[ $WRITTEN -eq 0 ]]; then
  err "No hour scripts were generated. Raw output saved to: $TMPDIR_WORK/raw.md"
  # Copy raw output to output dir for debugging
  cp "$TMPDIR_WORK/raw.md" "${OUTPUT_DIR%/}/RAW-OUTPUT.md"
  warn "Raw LLM output saved to: ${OUTPUT_DIR%/}/RAW-OUTPUT.md"
  exit 1
fi

echo "" >&2
log "Generated ${BOLD}${WRITTEN}${RESET} hour script(s) in ${CYAN}${OUTPUT_DIR}${RESET}"
