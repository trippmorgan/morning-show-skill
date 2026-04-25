#!/usr/bin/env bash
set -euo pipefail

# --- Colors (stderr only) ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[research]${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}[research]${RESET} $*" >&2; }
err()  { echo -e "${RED}[research]${RESET} $*" >&2; }
info() { echo -e "${CYAN}[research]${RESET} $*" >&2; }

# --- Help ---
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--date YYYY-MM-DD]

Research date-specific content for morning show script production.

Options:
  --date YYYY-MM-DD   Target date (default: tomorrow)
  --help              Show this help message

Output:
  JSON to stdout with sections: date, day_name, weather, music_history, birthdays, news
  Progress messages to stderr.

Weather data is fetched live from Open-Meteo API (Albany, GA).

WebSearch hook (Wave 3 Task 20, AD-10, Q4.3=b):
  When WRITE_SCRIPTS_WEBSEARCH=1 (default: enabled if claude CLI on PATH),
  this script invokes Claude with WebSearch tool use to populate news,
  music history, and Albany-local stories. Falls back to evergreen content
  (weather + music_hint only) if claude is unavailable, fails, or returns
  empty results — pipeline never aborts on WebSearch failure.

Env vars:
  WRITE_SCRIPTS_WEBSEARCH=1   Enable WebSearch (default: 1 if claude on PATH)
  WRITE_SCRIPTS_WEBSEARCH=0   Disable WebSearch (force evergreen fallback)
  WRITE_SCRIPTS_DRY_RUN=1     Print queries that would run, do not call claude
EOF
  exit 0
}

# --- Parse args ---
TARGET_DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      TARGET_DATE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      err "Unknown argument: $1"
      usage
      ;;
  esac
done

# Default to tomorrow
if [[ -z "$TARGET_DATE" ]]; then
  TARGET_DATE=$(date -d "+1 day" +%Y-%m-%d 2>/dev/null || date -v+1d +%Y-%m-%d)
fi

# Validate date format
if ! [[ "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  err "Invalid date format: $TARGET_DATE (expected YYYY-MM-DD)"
  exit 1
fi

# Extract components
YEAR="${TARGET_DATE:0:4}"
MONTH="${TARGET_DATE:5:2}"
DAY="${TARGET_DATE:8:2}"
# Strip leading zeros for display/URLs
MONTH_NUM=$((10#$MONTH))
DAY_NUM=$((10#$DAY))

# Day name
DAY_NAME=$(date -d "$TARGET_DATE" +%A 2>/dev/null || date -j -f "%Y-%m-%d" "$TARGET_DATE" +%A)

log "Researching: ${CYAN}$DAY_NAME, $TARGET_DATE${RESET}"

# --- Weather: Open-Meteo API (Albany, GA) ---
ALBANY_LAT=31.58
ALBANY_LON=-84.16

info "Fetching weather from Open-Meteo..."

WEATHER_JSON=""
WEATHER_ERROR=""

WEATHER_RAW=$(curl -sf --max-time 10 \
  "https://api.open-meteo.com/v1/forecast?latitude=${ALBANY_LAT}&longitude=${ALBANY_LON}&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code&temperature_unit=fahrenheit&timezone=America%2FNew_York&start_date=${TARGET_DATE}&end_date=${TARGET_DATE}" \
  2>/dev/null) || WEATHER_ERROR="Failed to fetch weather data"

if [[ -z "$WEATHER_ERROR" && -n "$WEATHER_RAW" ]]; then
  # Try jq first, fallback to manual parsing
  if command -v jq &>/dev/null; then
    HIGH_F=$(echo "$WEATHER_RAW" | jq -r '.daily.temperature_2m_max[0] // empty')
    LOW_F=$(echo "$WEATHER_RAW" | jq -r '.daily.temperature_2m_min[0] // empty')
    PRECIP_PROB=$(echo "$WEATHER_RAW" | jq -r '.daily.precipitation_probability_max[0] // empty')
    WEATHER_CODE=$(echo "$WEATHER_RAW" | jq -r '.daily.weather_code[0] // empty')
  else
    # Fallback: grep-based extraction (fragile but functional)
    HIGH_F=$(echo "$WEATHER_RAW" | grep -o '"temperature_2m_max":\[[^]]*\]' | grep -o '\[.*\]' | tr -d '[]')
    LOW_F=$(echo "$WEATHER_RAW" | grep -o '"temperature_2m_min":\[[^]]*\]' | grep -o '\[.*\]' | tr -d '[]')
    PRECIP_PROB=$(echo "$WEATHER_RAW" | grep -o '"precipitation_probability_max":\[[^]]*\]' | grep -o '\[.*\]' | tr -d '[]')
    WEATHER_CODE=$(echo "$WEATHER_RAW" | grep -o '"weather_code":\[[^]]*\]' | grep -o '\[.*\]' | tr -d '[]')
  fi

  # Decode WMO weather code to description
  decode_weather_code() {
    local code="$1"
    case "$code" in
      0)  echo "Clear sky" ;;
      1)  echo "Mainly clear" ;;
      2)  echo "Partly cloudy" ;;
      3)  echo "Overcast" ;;
      45) echo "Foggy" ;;
      48) echo "Depositing rime fog" ;;
      51) echo "Light drizzle" ;;
      53) echo "Moderate drizzle" ;;
      55) echo "Dense drizzle" ;;
      61) echo "Slight rain" ;;
      63) echo "Moderate rain" ;;
      65) echo "Heavy rain" ;;
      66) echo "Light freezing rain" ;;
      67) echo "Heavy freezing rain" ;;
      71) echo "Slight snow" ;;
      73) echo "Moderate snow" ;;
      75) echo "Heavy snow" ;;
      77) echo "Snow grains" ;;
      80) echo "Slight rain showers" ;;
      81) echo "Moderate rain showers" ;;
      82) echo "Violent rain showers" ;;
      85) echo "Slight snow showers" ;;
      86) echo "Heavy snow showers" ;;
      95) echo "Thunderstorm" ;;
      96) echo "Thunderstorm with slight hail" ;;
      99) echo "Thunderstorm with heavy hail" ;;
      *)  echo "Unknown (code $code)" ;;
    esac
  }

  WEATHER_DESC=$(decode_weather_code "${WEATHER_CODE:-0}")

  log "Weather: ${HIGH_F}°F high / ${LOW_F}°F low, ${PRECIP_PROB}% precip — ${WEATHER_DESC}"
else
  warn "Weather fetch failed: ${WEATHER_ERROR:-empty response}"
  HIGH_F=""
  LOW_F=""
  PRECIP_PROB=""
  WEATHER_CODE=""
  WEATHER_DESC="unavailable"
fi

# --- Music history hint (always available, used by evergreen fallback) ---
MUSIC_HINT="thisdayinmusic.com and songfacts.com/calendar for ${MONTH_NUM}/${DAY_NUM}"

# --- WebSearch hook (Wave 3 Task 20, AD-10) ---
# Invokes Claude CLI with WebSearch tool use enabled. Three queries, ≤5 items
# each, deduped, results injected into the news/music/birthdays sections of
# the JSON output. Failure (timeout, empty, non-zero exit, no claude on PATH)
# falls back to evergreen content — pipeline never aborts.
#
# Mocking: tests set CLAUDE_MOCK_MODE on a stubbed `claude` binary on PATH.

# Three queries per spec
MONTH_DAY=$(date -d "$TARGET_DATE" +%m-%d 2>/dev/null || date -j -f "%Y-%m-%d" "$TARGET_DATE" +%m-%d)
QUERY_MUSIC="today music news"
QUERY_RADIO="today ${TARGET_DATE} radio industry news"
QUERY_LOCAL="today Albany GA news ${MONTH_DAY}"

# Default: enable WebSearch if claude is on PATH; user can force-disable.
WEBSEARCH_ENABLED="${WRITE_SCRIPTS_WEBSEARCH:-}"
if [[ -z "$WEBSEARCH_ENABLED" ]]; then
  if command -v claude &>/dev/null; then
    WEBSEARCH_ENABLED=1
  else
    WEBSEARCH_ENABLED=0
  fi
fi

# Dry-run: print what we'd do, no LLM call, no further fetches.
if [[ "${WRITE_SCRIPTS_DRY_RUN:-0}" == "1" ]]; then
  info "DRY RUN — would invoke claude --allowed-tools WebSearch with 3 queries:"
  info "  Q1: $QUERY_MUSIC"
  info "  Q2: $QUERY_RADIO"
  info "  Q3: $QUERY_LOCAL"
  info "  (filter ≤5 items per query, dedupe, inject as JSON into research output)"
  # Emit minimal JSON so consumers don't choke on dry-run output.
  WEBSEARCH_STATUS="dry-run"
  NEWS_STORIES_JSON="[]"
  MUSIC_EVENTS_JSON="[]"
  BIRTHDAYS_JSON="[]"
elif [[ "$WEBSEARCH_ENABLED" == "1" ]]; then
  info "Invoking claude WebSearch (3 queries: music / radio-industry / Albany-local)..."

  WEBSEARCH_PROMPT=$(cat <<WSEOF
You have the WebSearch tool. Run THREE web searches and return STRICT JSON only.

Searches to run:
1. "${QUERY_MUSIC}"
2. "${QUERY_RADIO}"
3. "${QUERY_LOCAL}"

After running all three searches:
- Filter to the ≤5 MOST RELEVANT items per category (music news, radio industry, Albany local).
- Dedupe across categories (no duplicates by title or URL).
- Skip anything older than 7 days from ${TARGET_DATE}.
- Skip ads, listicles ("top 10..."), and political opinion.

Also identify 1-3 notable music history events for ${MONTH_NUM}/${DAY_NUM} (any year)
and 1-3 notable birthdays on this calendar day.

Return ONLY this JSON shape (no prose, no markdown fences):
{
  "news": [
    {"title": "...", "source": "...", "summary": "...", "url": "..."}
  ],
  "music": [
    {"date": "YYYY-MM-DD", "event": "..."}
  ],
  "birthdays": [
    {"name": "...", "year": 1234, "note": "..."}
  ],
  "local": [
    {"title": "...", "source": "...", "summary": "...", "url": "..."}
  ]
}
WSEOF
)

  WEBSEARCH_RAW=""
  WEBSEARCH_RC=0
  WEBSEARCH_RAW=$(echo "$WEBSEARCH_PROMPT" | timeout 90 claude \
    --permission-mode bypassPermissions \
    --allowed-tools WebSearch \
    --print 2>/dev/null) || WEBSEARCH_RC=$?

  WEBSEARCH_STATUS="websearch"
  NEWS_STORIES_JSON="[]"
  MUSIC_EVENTS_JSON="[]"
  BIRTHDAYS_JSON="[]"

  # Validate: non-empty + parseable JSON + at least one news/local/music item
  if [[ $WEBSEARCH_RC -ne 0 || -z "$WEBSEARCH_RAW" ]]; then
    warn "WebSearch failed (rc=$WEBSEARCH_RC, empty=$([[ -z "$WEBSEARCH_RAW" ]] && echo yes || echo no)) — using evergreen fallback"
    WEBSEARCH_STATUS="evergreen-fallback"
  else
    # Strip any code fences claude might emit despite instructions
    CLEAN_RAW=$(echo "$WEBSEARCH_RAW" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
    if command -v jq &>/dev/null; then
      if echo "$CLEAN_RAW" | jq -e . >/dev/null 2>&1; then
        # Merge news + local into news.stories (dedupe by title), cap at 5 total
        # so the morning-show prompt stays focused on the most relevant items.
        NEWS_STORIES_JSON=$(echo "$CLEAN_RAW" | jq -c '
          ((.news // []) + (.local // []))
          | unique_by(.title // "")
          | .[0:5]
        ' 2>/dev/null || echo "[]")
        MUSIC_EVENTS_JSON=$(echo "$CLEAN_RAW" | jq -c '(.music // [])[0:5]' 2>/dev/null || echo "[]")
        BIRTHDAYS_JSON=$(echo "$CLEAN_RAW" | jq -c '(.birthdays // [])[0:5]' 2>/dev/null || echo "[]")

        N_STORIES=$(echo "$NEWS_STORIES_JSON" | jq 'length' 2>/dev/null || echo 0)
        if (( N_STORIES == 0 )); then
          warn "WebSearch returned 0 news items — using evergreen fallback"
          WEBSEARCH_STATUS="evergreen-fallback"
        else
          log "WebSearch: ${N_STORIES} news, $(echo "$MUSIC_EVENTS_JSON" | jq 'length') music, $(echo "$BIRTHDAYS_JSON" | jq 'length') birthdays"
        fi
      else
        warn "WebSearch returned non-JSON output — using evergreen fallback"
        WEBSEARCH_STATUS="evergreen-fallback"
      fi
    else
      # No jq — best-effort: if output mentions 'title', accept as raw passthrough
      if echo "$CLEAN_RAW" | grep -q '"title"'; then
        NEWS_STORIES_JSON="$CLEAN_RAW"
      else
        warn "No jq available and output not parseable — using evergreen fallback"
        WEBSEARCH_STATUS="evergreen-fallback"
      fi
    fi
  fi
else
  info "WebSearch disabled (WRITE_SCRIPTS_WEBSEARCH=0 or claude not on PATH) — evergreen fallback"
  WEBSEARCH_STATUS="evergreen-fallback"
  NEWS_STORIES_JSON="[]"
  MUSIC_EVENTS_JSON="[]"
  BIRTHDAYS_JSON="[]"
fi

# --- Build JSON output ---
log "Building JSON output..."

if command -v jq &>/dev/null; then
  jq -n \
    --arg date "$TARGET_DATE" \
    --arg day_name "$DAY_NAME" \
    --arg year "$YEAR" \
    --arg month "$MONTH_NUM" \
    --arg day "$DAY_NUM" \
    --arg high "${HIGH_F:-null}" \
    --arg low "${LOW_F:-null}" \
    --arg precip "${PRECIP_PROB:-null}" \
    --arg wcode "${WEATHER_CODE:-null}" \
    --arg wdesc "$WEATHER_DESC" \
    --arg music_hint "$MUSIC_HINT" \
    --arg ws_status "$WEBSEARCH_STATUS" \
    --argjson news_stories "$NEWS_STORIES_JSON" \
    --argjson music_events "$MUSIC_EVENTS_JSON" \
    --argjson birthdays "$BIRTHDAYS_JSON" \
    '{
      date: $date,
      day_name: $day_name,
      year: ($year | tonumber),
      month: ($month | tonumber),
      day: ($day | tonumber),
      weather: {
        location: "Albany, GA",
        high_f: (if $high == "null" then null else ($high | tonumber) end),
        low_f: (if $low == "null" then null else ($low | tonumber) end),
        precipitation_probability: (if $precip == "null" then null else ($precip | tonumber) end),
        weather_code: (if $wcode == "null" then null else ($wcode | tonumber) end),
        description: $wdesc
      },
      music_history: {
        status: $ws_status,
        hint: $music_hint,
        events: $music_events
      },
      birthdays: {
        status: $ws_status,
        hint: "Search for notable birthdays on this date",
        people: $birthdays
      },
      news: {
        status: $ws_status,
        hint: "Current news headlines relevant to morning show audience",
        stories: $news_stories
      }
    }'
else
  # Fallback: manual JSON via printf
  warn "jq not found, using printf fallback"
  cat <<ENDJSON
{
  "date": "$TARGET_DATE",
  "day_name": "$DAY_NAME",
  "year": $YEAR,
  "month": $MONTH_NUM,
  "day": $DAY_NUM,
  "weather": {
    "location": "Albany, GA",
    "high_f": ${HIGH_F:-null},
    "low_f": ${LOW_F:-null},
    "precipitation_probability": ${PRECIP_PROB:-null},
    "weather_code": ${WEATHER_CODE:-null},
    "description": "$WEATHER_DESC"
  },
  "music_history": {
    "status": "$WEBSEARCH_STATUS",
    "hint": "$MUSIC_HINT",
    "events": $MUSIC_EVENTS_JSON
  },
  "birthdays": {
    "status": "$WEBSEARCH_STATUS",
    "hint": "Search for notable birthdays on this date",
    "people": $BIRTHDAYS_JSON
  },
  "news": {
    "status": "$WEBSEARCH_STATUS",
    "hint": "Current news headlines relevant to morning show audience",
    "stories": $NEWS_STORIES_JSON
  }
}
ENDJSON
fi

log "Done! JSON written to stdout."
