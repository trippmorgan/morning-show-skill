#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-show.sh — Master orchestrator for WPFQ 96.7 Morning Show production
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

log()    { echo -e "${GREEN}[build]${RESET} $*" >&2; }
warn()   { echo -e "${YELLOW}[build]${RESET} $*" >&2; }
err()    { echo -e "${RED}[build]${RESET} $*" >&2; }
info()   { echo -e "${CYAN}[build]${RESET} $*" >&2; }
banner() { echo -e "${BOLD}${CYAN}$*${RESET}" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: build-show.sh [OPTIONS]

Master orchestrator — chains research, writing, voice rendering, music pull,
production, preview, and publish into one pipeline.

Options:
  --day <name>        Day name (monday–friday). Default: auto-detect from date
  --date YYYY-MM-DD   Target date. Default: tomorrow
  --force             Allow Saturday/Sunday builds
  --auto-approve      Skip interactive approval gates
  --resume            Resume from last completed step (reads manifest.json)
  --step <name>       Run a single step: research, write, extract, render,
                      pull, produce, preview, publish
  --dry-run           Pass --dry-run to all sub-scripts
  --help              Show this help

Pipeline:
  1. research     Gather date-specific content (research-date.sh)
  2. write        Generate hour scripts (write-scripts.sh)
  3. extract      Pull talk segments from scripts → .txt files
  4. render       Render .txt segments to .mp3 (render-voice.sh)
  5. pull         Download songs from PlayoutONE (pull-songs.sh)
  6. produce      Assemble hours: talk + songs (produce-hour.sh)
  7. preview      Preview final audio (preview.sh)
  8. publish      Push to station playout (publish.sh)
EOF
  exit 0
}

# --- Defaults ---
DATE=""
DAY=""
FORCE=false
AUTO_APPROVE=false
RESUME=false
SINGLE_STEP=""
DRY_RUN=false
BUILD_START=$(date +%s)

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --day)        DAY="${2,,}"; shift 2 ;;
    --date)       DATE="$2"; shift 2 ;;
    --force)      FORCE=true; shift ;;
    --auto-approve) AUTO_APPROVE=true; shift ;;
    --resume)     RESUME=true; shift ;;
    --step)       SINGLE_STEP="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --help|-h)    usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

# --- Date defaults ---
if [[ -z "$DATE" ]]; then
  DATE=$(date -d "tomorrow" +%Y-%m-%d)
fi

# Validate date format
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  err "Invalid date format: $DATE (expected YYYY-MM-DD)"
  exit 1
fi

# --- Day name ---
if [[ -z "$DAY" ]]; then
  DAY=$(date -d "$DATE" +%A | tr '[:upper:]' '[:lower:]')
fi

# --- Reject weekends unless --force ---
if [[ "$DAY" == "saturday" || "$DAY" == "sunday" ]]; then
  if [[ "$FORCE" == false ]]; then
    err "No show on $DAY. Use --force to override."
    exit 1
  fi
  warn "Weekend build forced for $DAY."
fi

# --- Show directory ---
SHOW_DIR="$PROJECT_DIR/shows/$DATE"
SCRIPTS_DIR="$SHOW_DIR/scripts"
SEGMENTS_DIR="$SHOW_DIR/segments"
SONGS_DIR="$SHOW_DIR/songs"
AUDIO_DIR="$SHOW_DIR/audio"
MANIFEST="$SHOW_DIR/manifest.json"

mkdir -p "$SCRIPTS_DIR" "$SEGMENTS_DIR" "$SONGS_DIR" "$AUDIO_DIR"

# --- Dry-run flag passthrough ---
DRY_RUN_FLAG=""
if [[ "$DRY_RUN" == true ]]; then
  DRY_RUN_FLAG="--dry-run"
fi

# --- Step tracking ---
STEPS=(research write extract render pull produce preview publish)
COMPLETED_STEP=""

mark_step() {
  local step="$1"
  local tmp
  if [[ -f "$MANIFEST" ]]; then
    tmp=$(jq --arg s "$step" '.last_completed_step = $s' "$MANIFEST")
    echo "$tmp" > "$MANIFEST"
  fi
}

should_run() {
  local step="$1"

  # Single-step mode
  if [[ -n "$SINGLE_STEP" ]]; then
    [[ "$step" == "$SINGLE_STEP" ]] && return 0 || return 1
  fi

  # Resume mode — skip steps already done
  if [[ "$RESUME" == true && -n "$COMPLETED_STEP" ]]; then
    local past_completed=false
    for s in "${STEPS[@]}"; do
      if [[ "$past_completed" == true ]]; then
        # We're past the completed step — run from here
        return 0
      fi
      if [[ "$s" == "$COMPLETED_STEP" ]]; then
        past_completed=true
      fi
      if [[ "$s" == "$step" ]]; then
        info "Skipping $step (already completed)"
        return 1
      fi
    done
  fi

  return 0
}

# --- Resume: read last completed step ---
if [[ "$RESUME" == true && -f "$MANIFEST" ]]; then
  COMPLETED_STEP=$(jq -r '.last_completed_step // empty' "$MANIFEST" 2>/dev/null || true)
  if [[ -n "$COMPLETED_STEP" ]]; then
    info "Resuming after step: $COMPLETED_STEP"
  else
    warn "No completed step found in manifest — starting from beginning."
  fi
fi

# --- Helper: approval gate ---
gate() {
  local prompt="$1"
  if [[ "$AUTO_APPROVE" == true ]]; then
    info "Auto-approved: $prompt"
    return 0
  fi
  echo -en "${BOLD}${YELLOW}$prompt [y/N] ${RESET}" >&2
  read -r answer < /dev/tty
  if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
    err "Aborted by user."
    exit 1
  fi
}

# --- Helper: extract talk segments from hour script markdown ---
extract_segments_from_script() {
  local script_file="$1"
  local hour_label="$2"
  local out_dir="$3"
  local seg_num=0

  # Extract text between [TALK] and [/TALK] markers, or lines starting with > (blockquote)
  # Also handle segments marked with **Talk:** or similar patterns
  # Strategy: look for blockquote lines (the talk text in script templates)
  local in_talk=false
  local current_text=""
  local segment_name=""

  while IFS= read -r line; do
    # Check for [TALK] / [/TALK] markers
    if [[ "$line" =~ ^\[TALK\](.*)$ || "$line" =~ ^\*\*Talk:\*\* || "$line" =~ ^">"[[:space:]] ]]; then
      if [[ "$line" =~ ^\[TALK\] ]]; then
        in_talk=true
        continue
      fi
      # Blockquote style — single-line talk segment
      local text="${line#> }"
      text="${text#\*\*Talk:\*\* }"
      if [[ -n "$text" ]]; then
        seg_num=$((seg_num + 1))
        printf -v segment_name "%s-%02d" "$hour_label" "$seg_num"
        echo "$text" > "$out_dir/${segment_name}.txt"
      fi
      continue
    fi

    if [[ "$in_talk" == true ]]; then
      if [[ "$line" =~ ^\[/TALK\] ]]; then
        in_talk=false
        if [[ -n "$current_text" ]]; then
          seg_num=$((seg_num + 1))
          printf -v segment_name "%s-%02d" "$hour_label" "$seg_num"
          echo "$current_text" > "$out_dir/${segment_name}.txt"
          current_text=""
        fi
      else
        current_text+="$line"$'\n'
      fi
    fi
  done < "$script_file"

  echo "$seg_num"
}

# --- Helper: extract song list from hour script ---
extract_songs_from_script() {
  local script_file="$1"
  # Primary format: [SONG: Artist - Title]
  grep -oP '(?<=\[SONG: )[^\]]+' "$script_file" 2>/dev/null || true
  # Fallback: [SONG] Artist - Title
  grep -oP '(?<=\[SONG\]\s?).*$' "$script_file" 2>/dev/null || true
}

# ============================================================================
# PIPELINE
# ============================================================================

banner "
╔═══════════════════════════════════════════════════════════════╗
║        Morning Show Builder — WPFQ 96.7                      ║
║        Pretoria Fields Radio, Albany GA                       ║
╚═══════════════════════════════════════════════════════════════╝"

info "Date:  $DATE ($DAY)"
info "Show:  $SHOW_DIR"
[[ "$DRY_RUN" == true ]] && warn "DRY-RUN mode — no real actions will be taken."
echo "" >&2

# ── Step 1: Research ──────────────────────────────────────────────────────
if should_run research; then
  log "Step 1/8 — Researching date: $DATE"
  "$SCRIPT_DIR/research-date.sh" --date "$DATE" $DRY_RUN_FLAG > "$SHOW_DIR/research.json"
  log "Research saved to $SHOW_DIR/research.json"
  mark_step research
fi

# ── Step 2: Write scripts ────────────────────────────────────────────────
if should_run write; then
  log "Step 2/8 — Writing hour scripts"
  "$SCRIPT_DIR/write-scripts.sh" \
    --day "$DAY" \
    --date "$DATE" \
    --research "$SHOW_DIR/research.json" \
    --output-dir "$SCRIPTS_DIR" \
    $DRY_RUN_FLAG
  log "Scripts written to $SCRIPTS_DIR/"
  mark_step write
fi

# ── GATE 1: Script approval ─────────────────────────────────────────────
if should_run extract; then
  echo "" >&2
  banner "── Script Summary ──"
  for f in "$SCRIPTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    info "  $(basename "$f")"
    # Show first heading and segment count
    head -5 "$f" | grep -E '^#' | head -1 | sed 's/^/    /' >&2 || true
  done
  echo "" >&2
  gate "Approve scripts?"
fi

# ── Step 3: Extract talk segments ────────────────────────────────────────
if should_run extract; then
  log "Step 3/8 — Extracting talk segments"
  total_segments=0
  for f in "$SCRIPTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" .md)
    hour_label=$(echo "$base" | tr '[:upper:]' '[:lower:]')
    count=$(extract_segments_from_script "$f" "$hour_label" "$SEGMENTS_DIR")
    info "  $base → $count segments"
    total_segments=$((total_segments + count))
  done
  log "Extracted $total_segments segments to $SEGMENTS_DIR/"
  mark_step extract
fi

# ── Step 4: Render voice ─────────────────────────────────────────────────
if should_run render; then
  log "Step 4/8 — Rendering voice segments"
  txt_count=$(find "$SEGMENTS_DIR" -name '*.txt' | wc -l)
  info "  $txt_count text files to render"
  "$SCRIPT_DIR/render-voice.sh" \
    --batch-dir "$SEGMENTS_DIR" \
    --config "$PROJECT_DIR/config.yaml" \
    $DRY_RUN_FLAG
  log "Voice rendering complete"
  mark_step render
fi

# ── Step 5: Pull songs ───────────────────────────────────────────────────
if should_run pull; then
  log "Step 5/8 — Pulling songs from PlayoutONE"
  # Use --from-scripts to parse [SONG: Artist - Title] markers
  "$SCRIPT_DIR/pull-songs.sh" \
    --from-scripts "$SCRIPTS_DIR" \
    --output-dir "$SONGS_DIR" \
    $DRY_RUN_FLAG \
    > "$SHOW_DIR/songs-manifest.json" || {
    warn "Song pull failed or no [SONG:] markers found"
  }
  mark_step pull
fi

# ── Step 6: Produce hours ────────────────────────────────────────────────
if should_run produce; then
  log "Step 6/8 — Producing hour blocks"
  for f in "$SCRIPTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" .md)
    hour_label=$(echo "$base" | tr '[:upper:]' '[:lower:]')
    output_mp3="$AUDIO_DIR/${hour_label}.mp3"

    info "  Producing $base → $(basename "$output_mp3")"
    "$SCRIPT_DIR/produce-hour.sh" \
      --talk-dir "$SEGMENTS_DIR" \
      --songs-dir "$SONGS_DIR" \
      --interleave \
      --output "$output_mp3" \
      --preview \
      $DRY_RUN_FLAG
  done
  log "All hours produced in $AUDIO_DIR/"
  mark_step produce
fi

# ── Step 7: Preview ──────────────────────────────────────────────────────
if should_run preview; then
  log "Step 7/8 — Preview"
  "$SCRIPT_DIR/preview.sh" \
    --audio-dir "$AUDIO_DIR" \
    $DRY_RUN_FLAG

  gate "Publish to station?"
  mark_step preview
fi

# ── Step 8: Publish ──────────────────────────────────────────────────────
if should_run publish; then
  log "Step 8/8 — Publishing to station"
  "$SCRIPT_DIR/publish.sh" \
    --date "$DATE" \
    --audio-dir "$AUDIO_DIR" \
    $DRY_RUN_FLAG
  log "Published!"
  mark_step publish
fi

# ============================================================================
# Manifest
# ============================================================================
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

segments_count=$(find "$SEGMENTS_DIR" -name '*.txt' 2>/dev/null | wc -l)
songs_count=$(find "$SONGS_DIR" -name '*.mp3' 2>/dev/null | wc -l)

# Total duration of produced audio (seconds)
total_duration=0
for mp3 in "$AUDIO_DIR"/*.mp3; do
  [[ -f "$mp3" ]] || continue
  [[ "$mp3" == *-preview.mp3 ]] && continue
  dur=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$mp3" 2>/dev/null || echo 0)
  total_duration=$(awk "BEGIN {printf \"%.1f\", $total_duration + $dur}")
done

# Hour list
hours_json=$(printf '%s\n' "$AUDIO_DIR"/*.mp3 | grep -v preview | while read -r f; do
  [[ -f "$f" ]] && basename "$f" .mp3
done | jq -R . | jq -s .)

cat > "$MANIFEST" <<MANIFEST_EOF
{
  "date": "$DATE",
  "day": "$DAY",
  "hours": $hours_json,
  "segments_count": $segments_count,
  "songs_count": $songs_count,
  "total_duration_secs": $total_duration,
  "build_time_secs": $BUILD_TIME,
  "last_completed_step": "publish",
  "status": "complete",
  "built_at": "$(date -Iseconds)"
}
MANIFEST_EOF

echo "" >&2
banner "╔═══════════════════════════════════════════════════════════════╗"
banner "║  BUILD COMPLETE                                              ║"
banner "╚═══════════════════════════════════════════════════════════════╝"
info "Date:       $DATE ($DAY)"
info "Segments:   $segments_count"
info "Songs:      $songs_count"
info "Duration:   ${total_duration}s"
info "Build time: ${BUILD_TIME}s"
info "Manifest:   $MANIFEST"
