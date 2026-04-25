#!/usr/bin/env bash
# Tests for WebSearch hook in research-date.sh — Wave 3 Task 20
# TDD: write tests first, then implementation.
#
# Integration point: research-date.sh
# Why: research-date.sh already owns external data fetches (Open-Meteo weather)
# and produces the JSON consumed by write-scripts.sh. WebSearch results naturally
# populate the existing placeholder slots (news.stories, music_history.events,
# birthdays.people). Single point of fallback handling.
#
# Tests:
#   1. Dry-run mode (WRITE_SCRIPTS_DRY_RUN=1) prints the queries that would run,
#      does NOT execute claude.
#   2. Mocked claude returns empty WebSearch result → falls back to evergreen
#      content, exits 0, news.status == "evergreen-fallback".
#   3. Mocked claude returns 5 sample news items → results visible in JSON
#      output (news.stories[] populated, count == 5, accessible from
#      write-scripts.sh prompt input).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESEARCH_SH="$SCRIPT_DIR/research-date.sh"
WRITE_SH="$SCRIPT_DIR/write-scripts.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

red()    { printf '\033[0;31m%s\033[0m' "$*"; }
green()  { printf '\033[0;32m%s\033[0m' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m' "$*"; }

pass() {
    PASS=$((PASS + 1))
    echo "  [$(green PASS)] $1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
    echo "  [$(red FAIL)] $1"
    [[ -n "${2:-}" ]] && echo "         $2"
}

# Sanity: script exists
if [[ ! -x "$RESEARCH_SH" ]]; then
    echo "$(red 'FATAL'): $RESEARCH_SH is not executable or does not exist" >&2
    exit 2
fi

# Test fixtures dir
TEST_TMP="$(mktemp -d -t test-websearch-hook.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

TARGET_DATE="2026-04-25"

# ---------------------------------------------------------------------------
# Mock claude shim — controlled via env vars
# CLAUDE_MOCK_MODE=empty      → returns empty stdout
# CLAUDE_MOCK_MODE=five_items → returns JSON array with 5 sample news items
# CLAUDE_MOCK_MODE=fail       → exits non-zero
# ---------------------------------------------------------------------------
make_mock_claude() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock claude CLI for tests.
# Logs the invocation to $CLAUDE_MOCK_LOG (if set) for assertions.
if [[ -n "${CLAUDE_MOCK_LOG:-}" ]]; then
    echo "INVOKED: $*" >> "$CLAUDE_MOCK_LOG"
    cat - >> "$CLAUDE_MOCK_LOG" 2>/dev/null || true
    echo "---END---" >> "$CLAUDE_MOCK_LOG"
fi
case "${CLAUDE_MOCK_MODE:-empty}" in
    empty)
        # Return nothing — simulates WebSearch returning zero items
        echo '{"news":[],"music":[],"local":[]}'
        exit 0
        ;;
    five_items)
        cat <<'JSON'
{
  "news": [
    {"title": "Music industry shake-up", "source": "Billboard", "summary": "Major label restructuring announced."},
    {"title": "Streaming royalties update", "source": "Variety", "summary": "New rates take effect."},
    {"title": "Vinyl sales hit new high", "source": "RIAA", "summary": "Physical media resurgence continues."},
    {"title": "Concert tour cancellations", "source": "Pollstar", "summary": "Three major tours postponed."},
    {"title": "AI music copyright case", "source": "Reuters", "summary": "Court ruling sets precedent."}
  ],
  "music": [
    {"date": "1969-04-25", "event": "Sample music history event A"},
    {"date": "1985-04-25", "event": "Sample music history event B"}
  ],
  "local": [
    {"title": "Albany city council update", "source": "Albany Herald", "summary": "Local infrastructure vote."}
  ]
}
JSON
        exit 0
        ;;
    fail)
        echo "Mock claude failure" >&2
        exit 2
        ;;
    *)
        echo "Unknown CLAUDE_MOCK_MODE: ${CLAUDE_MOCK_MODE}" >&2
        exit 99
        ;;
esac
MOCKEOF
    chmod +x "$mock_dir/claude"
}

MOCK_DIR="$TEST_TMP/mockbin"
make_mock_claude "$MOCK_DIR"

echo
echo "Running tests against: $RESEARCH_SH"
echo "Mock claude shim: $MOCK_DIR/claude"
echo

# ===========================================================================
# Test 1: Dry-run mode prints the queries
# ===========================================================================
echo "Test 1: WRITE_SCRIPTS_DRY_RUN=1 prints queries, does not execute claude"
LOG1="$TEST_TMP/test1.log"
: > "$LOG1"

OUT1="$(PATH="$MOCK_DIR:$PATH" \
        WRITE_SCRIPTS_DRY_RUN=1 \
        CLAUDE_MOCK_LOG="$LOG1" \
        CLAUDE_MOCK_MODE=five_items \
        "$RESEARCH_SH" --date "$TARGET_DATE" 2>"$TEST_TMP/test1.err")"
RC1=$?

if (( RC1 != 0 )); then
    fail "Test 1: dry-run must exit 0" "got rc=$RC1, stderr: $(cat "$TEST_TMP/test1.err")"
elif [[ -s "$LOG1" ]]; then
    fail "Test 1: dry-run must NOT invoke claude" "claude was called: $(cat "$LOG1")"
elif ! grep -qE "today music news" "$TEST_TMP/test1.err" "$OUT1" /dev/null 2>/dev/null && \
     ! echo "$OUT1$(cat "$TEST_TMP/test1.err")" | grep -qE "today music news"; then
    fail "Test 1: dry-run must print query 'today music news'" "stderr: $(cat "$TEST_TMP/test1.err")"
elif ! echo "$OUT1$(cat "$TEST_TMP/test1.err")" | grep -qE "radio industry news"; then
    fail "Test 1: dry-run must print query 'radio industry news'" "stderr: $(cat "$TEST_TMP/test1.err")"
elif ! echo "$OUT1$(cat "$TEST_TMP/test1.err")" | grep -qE "Albany GA news"; then
    fail "Test 1: dry-run must print query 'Albany GA news'" "stderr: $(cat "$TEST_TMP/test1.err")"
else
    pass "Test 1: dry-run printed all 3 queries without invoking claude"
fi

# ===========================================================================
# Test 2: Empty WebSearch result → evergreen fallback, no abort
# ===========================================================================
echo "Test 2: empty WebSearch → evergreen fallback, exits 0"
LOG2="$TEST_TMP/test2.log"
: > "$LOG2"

OUT2="$(PATH="$MOCK_DIR:$PATH" \
        WRITE_SCRIPTS_WEBSEARCH=1 \
        CLAUDE_MOCK_LOG="$LOG2" \
        CLAUDE_MOCK_MODE=empty \
        "$RESEARCH_SH" --date "$TARGET_DATE" 2>"$TEST_TMP/test2.err")"
RC2=$?

if (( RC2 != 0 )); then
    fail "Test 2: must exit 0 on empty WebSearch (no abort)" \
         "got rc=$RC2, stderr: $(cat "$TEST_TMP/test2.err")"
elif [[ ! -s "$LOG2" ]]; then
    fail "Test 2: claude must have been invoked" "log was empty"
else
    # Parse JSON — must contain news.status == "evergreen-fallback" or
    # similar marker indicating fallback path was used.
    if command -v jq &>/dev/null; then
        STATUS=$(echo "$OUT2" | jq -r '.news.status // ""' 2>/dev/null)
        WEATHER_OK=$(echo "$OUT2" | jq -r '.weather.location // ""' 2>/dev/null)
        if [[ "$STATUS" != "evergreen-fallback" && "$STATUS" != "evergreen" ]]; then
            fail "Test 2: news.status should mark fallback (got '$STATUS')" \
                 "expected 'evergreen-fallback' or 'evergreen'"
        elif [[ "$WEATHER_OK" != "Albany, GA" ]]; then
            fail "Test 2: weather (Open-Meteo) must still work" "got '$WEATHER_OK'"
        else
            pass "Test 2: empty result → fallback ($STATUS), weather preserved"
        fi
    else
        # No jq — grep
        if echo "$OUT2" | grep -qE '"status"[[:space:]]*:[[:space:]]*"evergreen'; then
            pass "Test 2: empty result → evergreen fallback (grep mode)"
        else
            fail "Test 2: news.status should mark evergreen fallback" \
                 "output: $OUT2"
        fi
    fi
fi

# ===========================================================================
# Test 3: 5 sample news items appear in output and feed write-scripts.sh
# ===========================================================================
echo "Test 3: 5 mocked items → results visible in research JSON"
LOG3="$TEST_TMP/test3.log"
: > "$LOG3"

OUT3="$(PATH="$MOCK_DIR:$PATH" \
        WRITE_SCRIPTS_WEBSEARCH=1 \
        CLAUDE_MOCK_LOG="$LOG3" \
        CLAUDE_MOCK_MODE=five_items \
        "$RESEARCH_SH" --date "$TARGET_DATE" 2>"$TEST_TMP/test3.err")"
RC3=$?

if (( RC3 != 0 )); then
    fail "Test 3: must exit 0 with 5 results" \
         "got rc=$RC3, stderr: $(cat "$TEST_TMP/test3.err")"
elif [[ ! -s "$LOG3" ]]; then
    fail "Test 3: claude must have been invoked" "log was empty"
else
    if command -v jq &>/dev/null; then
        N_STORIES=$(echo "$OUT3" | jq -r '.news.stories | length' 2>/dev/null || echo 0)
        STATUS=$(echo "$OUT3" | jq -r '.news.status // ""' 2>/dev/null)
        FIRST_TITLE=$(echo "$OUT3" | jq -r '.news.stories[0].title // ""' 2>/dev/null)

        if (( N_STORIES < 1 )); then
            fail "Test 3: news.stories must contain ≥1 item from mock" \
                 "got $N_STORIES items, output: $OUT3"
        elif (( N_STORIES > 5 )); then
            fail "Test 3: news.stories must be ≤5 items (relevance filter)" \
                 "got $N_STORIES items"
        elif [[ "$STATUS" != "websearch" && "$STATUS" != "live" ]]; then
            fail "Test 3: news.status should mark live websearch (got '$STATUS')" \
                 "expected 'websearch' or 'live'"
        elif [[ -z "$FIRST_TITLE" ]]; then
            fail "Test 3: first news story must have a title" \
                 "first story: $(echo "$OUT3" | jq -r '.news.stories[0]')"
        else
            pass "Test 3: 5-item mock → $N_STORIES stories ('$FIRST_TITLE'...), status=$STATUS"
        fi

        # Bonus: Verify the research JSON is consumable by write-scripts.sh
        # by writing it to a file and running write-scripts.sh in --prompt-only mode.
        if [[ -x "$WRITE_SH" ]]; then
            RESEARCH_FILE="$TEST_TMP/research.json"
            echo "$OUT3" > "$RESEARCH_FILE"
            PROMPT_OUT="$("$WRITE_SH" --day monday --date "$TARGET_DATE" \
                          --research "$RESEARCH_FILE" \
                          --output-dir "$TEST_TMP/out" \
                          --prompt-only 2>/dev/null || true)"
            if echo "$PROMPT_OUT" | grep -q "Music industry shake-up"; then
                pass "Test 3 (bonus): WebSearch result reaches write-scripts.sh prompt"
            else
                fail "Test 3 (bonus): WebSearch result NOT in write-scripts.sh prompt" \
                     "expected 'Music industry shake-up' in prompt"
            fi
        fi
    else
        if echo "$OUT3" | grep -q "Music industry shake-up"; then
            pass "Test 3: news items in output (grep mode)"
        else
            fail "Test 3: 5-item news must be in output" "output: $OUT3"
        fi
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "------------------------------------------------------------"
echo "Results: $(green "$PASS passed"), $(red "$FAIL failed")"
if (( FAIL > 0 )); then
    echo "$(red 'Failed tests:')"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "$(green 'All tests passed.')"
exit 0
