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
Music history, birthdays, and news are placeholders for LLM web search.
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

# --- Music history placeholder ---
info "Music history: placeholder (LLM will research via web search)"
MUSIC_HINT="thisdayinmusic.com and songfacts.com/calendar for ${MONTH_NUM}/${DAY_NUM}"

# --- Birthdays placeholder ---
info "Birthdays: placeholder (LLM will research via web search)"

# --- News placeholder ---
info "News: placeholder (LLM will research via web search)"

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
        status: "placeholder",
        hint: $music_hint,
        events: []
      },
      birthdays: {
        status: "placeholder",
        hint: "Search for notable birthdays on this date",
        people: []
      },
      news: {
        status: "placeholder",
        hint: "Search for current news headlines relevant to morning show audience",
        stories: []
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
    "status": "placeholder",
    "hint": "$MUSIC_HINT",
    "events": []
  },
  "birthdays": {
    "status": "placeholder",
    "hint": "Search for notable birthdays on this date",
    "people": []
  },
  "news": {
    "status": "placeholder",
    "hint": "Search for current news headlines relevant to morning show audience",
    "stories": []
  }
}
ENDJSON
fi

log "Done! JSON written to stdout."
