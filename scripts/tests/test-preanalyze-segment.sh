#!/usr/bin/env bash
# Tests for preanalyze-segment.sh — Wave 3 Task 14
# TDD: write tests first, then implementation.
#
# Tests:
#   1. 10-min sine sample → markers within ±100ms of expected
#   2. 1-second file → exits non-zero with descriptive stderr
#   3. nonexistent file → exits non-zero
#   4. 60-min sine sample → markers correct (5000ms crossfade gap from end)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREANALYZE="$SCRIPT_DIR/preanalyze-segment.sh"

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

# Helpers --------------------------------------------------------------------
require_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "  Generating $f ..."
        # generate via ffmpeg sine wave; -ar 44100 standard rate
        local dur="$2"
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=${dur}" \
            -ar 44100 -ac 2 "$f" 2>/dev/null
        if [[ ! -f "$f" ]]; then
            echo "  $(red 'ffmpeg failed to generate fixture'): $f" >&2
            exit 2
        fi
    fi
}

extract_int() {
    # extract a numeric value for a given key from a tiny JSON blob
    local json="$1" key="$2"
    echo "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" \
        | grep -oE '[0-9]+$' | head -1
}

within_tolerance() {
    local actual="$1" expected="$2" tol="$3"
    local diff=$(( actual - expected ))
    diff=${diff#-}  # abs
    (( diff <= tol ))
}

# Fixtures -------------------------------------------------------------------
FIX_10MIN="/tmp/test-preanalyze-10min.mp3"
FIX_60MIN="/tmp/test-preanalyze-60min.mp3"
FIX_1SEC="/tmp/test-preanalyze-1sec.mp3"
FIX_MISSING="/tmp/test-preanalyze-does-not-exist-$$.mp3"

echo "Generating test fixtures (this may take a moment for the 60-min file)..."
require_file "$FIX_10MIN" 600
require_file "$FIX_1SEC" 1
require_file "$FIX_60MIN" 3600
rm -f "$FIX_MISSING"

# Sanity check: script exists and is executable
if [[ ! -x "$PREANALYZE" ]]; then
    echo "$(red 'FATAL'): $PREANALYZE is not executable or does not exist" >&2
    exit 2
fi

echo
echo "Running tests against: $PREANALYZE"
echo

# Test 1: 10-min file -------------------------------------------------------
echo "Test 1: 10-min sample → markers within ±100ms of expected"
OUT="$("$PREANALYZE" "$FIX_10MIN" 2>/tmp/test1.err)"
RC=$?
EXPECTED_LEN=600000   # 10 min in ms
EXPECTED_EXTRO=595000 # length - 5000

if (( RC != 0 )); then
    fail "Test 1: exit code 0" "got $RC, stderr: $(cat /tmp/test1.err)"
else
    LEN=$(extract_int "$OUT" length_ms)
    TRIM=$(extract_int "$OUT" trim_out_ms)
    EXTRO=$(extract_int "$OUT" extro_ms)

    if [[ -z "$LEN" || -z "$TRIM" || -z "$EXTRO" ]]; then
        fail "Test 1: parse JSON output" "got: $OUT"
    elif ! within_tolerance "$LEN" "$EXPECTED_LEN" 100; then
        fail "Test 1: length_ms within ±100ms of $EXPECTED_LEN" "got $LEN"
    elif [[ "$TRIM" != "$LEN" ]]; then
        fail "Test 1: trim_out_ms == length_ms" "trim=$TRIM length=$LEN"
    elif ! within_tolerance "$EXTRO" "$EXPECTED_EXTRO" 100; then
        fail "Test 1: extro_ms within ±100ms of $EXPECTED_EXTRO" "got $EXTRO"
    else
        pass "Test 1: 10-min markers length=$LEN trim=$TRIM extro=$EXTRO"
    fi
fi

# Test 2: 1-sec file --------------------------------------------------------
echo "Test 2: 1-sec file → non-zero exit + descriptive stderr"
OUT="$("$PREANALYZE" "$FIX_1SEC" 2>/tmp/test2.err)"
RC=$?
ERR_TEXT="$(cat /tmp/test2.err)"

if (( RC == 0 )); then
    fail "Test 2: must exit non-zero on too-short file" "rc=0, stdout: $OUT"
elif [[ -z "$ERR_TEXT" ]]; then
    fail "Test 2: must print descriptive stderr" "stderr was empty"
else
    pass "Test 2: 1-sec rejected (rc=$RC, stderr=\"$ERR_TEXT\")"
fi

# Test 3: nonexistent file --------------------------------------------------
echo "Test 3: nonexistent file → non-zero exit"
OUT="$("$PREANALYZE" "$FIX_MISSING" 2>/tmp/test3.err)"
RC=$?
ERR_TEXT="$(cat /tmp/test3.err)"

if (( RC == 0 )); then
    fail "Test 3: must exit non-zero on missing file" "rc=0, stdout: $OUT"
elif [[ -z "$ERR_TEXT" ]]; then
    fail "Test 3: must print descriptive stderr" "stderr was empty"
else
    pass "Test 3: missing file rejected (rc=$RC, stderr=\"$ERR_TEXT\")"
fi

# Test 4: 60-min file -------------------------------------------------------
echo "Test 4: 60-min sample → 5000ms crossfade gap"
OUT="$("$PREANALYZE" "$FIX_60MIN" 2>/tmp/test4.err)"
RC=$?
EXPECTED_LEN=3600000
EXPECTED_EXTRO=3595000

if (( RC != 0 )); then
    fail "Test 4: exit code 0" "got $RC, stderr: $(cat /tmp/test4.err)"
else
    LEN=$(extract_int "$OUT" length_ms)
    TRIM=$(extract_int "$OUT" trim_out_ms)
    EXTRO=$(extract_int "$OUT" extro_ms)

    if [[ -z "$LEN" || -z "$TRIM" || -z "$EXTRO" ]]; then
        fail "Test 4: parse JSON output" "got: $OUT"
    elif ! within_tolerance "$LEN" "$EXPECTED_LEN" 100; then
        fail "Test 4: length_ms within ±100ms of $EXPECTED_LEN" "got $LEN"
    elif [[ "$TRIM" != "$LEN" ]]; then
        fail "Test 4: trim_out_ms == length_ms" "trim=$TRIM length=$LEN"
    elif ! within_tolerance "$EXTRO" "$EXPECTED_EXTRO" 100; then
        fail "Test 4: extro_ms within ±100ms of $EXPECTED_EXTRO" "got $EXTRO"
    elif (( LEN - EXTRO < 4900 || LEN - EXTRO > 5100 )); then
        fail "Test 4: gap between length and extro should be ~5000ms" "got $((LEN - EXTRO))ms"
    else
        pass "Test 4: 60-min markers length=$LEN trim=$TRIM extro=$EXTRO gap=$((LEN - EXTRO))ms"
    fi
fi

# Summary --------------------------------------------------------------------
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
