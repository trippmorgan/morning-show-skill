#!/usr/bin/env bash
# Tests for produce-hour.sh LUFS-delta logging — Wave 3 Task 17
#
# Per Q2.2=c: produce-hour.sh measures the library median LUFS (from
# references/library-lufs.json) and logs the delta from our hardcoded
# normalization target (-16 LUFS). It does NOT change the production
# normalization filter — that stays at loudnorm=I=-16:TP=-1.5:LRA=11.
#
# This test exercises the LUFS-delta-only stub mode of produce-hour.sh
# (PRODUCE_HOUR_LUFS_DELTA_ONLY=1) so we don't need talk/song fixtures
# or ffmpeg. It also verifies the loudnorm filter is unchanged in the
# script source as a regression guard.
#
# Tests:
#   1. Mock library-lufs.json (median=-14.3) → delta = -16 - (-14.3) = -1.7 LU,
#      logged to stdout/stderr AND appended to .planning/TRACES.md.
#   2. Missing library-lufs.json → fallback message, no abort.
#   3. Malformed library-lufs.json → fallback message, no abort.
#   4. Regression guard: loudnorm=I=-16:TP=-1.5:LRA=11 still present in script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/produce-hour.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Sanity ---------------------------------------------------------------------
if [[ ! -x "$SCRIPT" ]]; then
    echo "$(red 'FATAL'): $SCRIPT is not executable or does not exist" >&2
    exit 2
fi

# Isolated paths so we don't clobber the real reference / TRACES file.
TEST_TMP="$(mktemp -d /tmp/test-produce-hour-lufs-XXXX)"
TEST_LUFS_JSON="$TEST_TMP/library-lufs.json"
TEST_TRACES="$TEST_TMP/TRACES.md"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo
echo "Running tests against: $SCRIPT"
echo

# Test 1: valid mock library-lufs.json --------------------------------------
echo "Test 1: valid library-lufs.json (median=-14.3) → delta = -1.7 LU"
cat > "$TEST_LUFS_JSON" <<'EOF'
{
  "median_lufs": -14.3,
  "p25": -15.5,
  "p75": -13.2,
  "stddev": 1.1,
  "sample_count": 50,
  "measured_at": "2026-04-25T00:00:00Z",
  "samples": []
}
EOF
: > "$TEST_TRACES"

OUT="$(PRODUCE_HOUR_LUFS_DELTA_ONLY=1 \
       LIBRARY_LUFS_PATH_OVERRIDE="$TEST_LUFS_JSON" \
       TRACES_PATH_OVERRIDE="$TEST_TRACES" \
       SHOW_DATE_OVERRIDE="2026-04-25" \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC != 0 )); then
    fail "Test 1: stub mode exits 0" "rc=$RC, output: $OUT"
elif ! grep -qE 'LUFS delta:.*target.*-16.*library median.*-14\.3.*delta.*\+?-?1\.7' <<<"$OUT"; then
    fail "Test 1: console line shows target/median/delta" "output: $OUT"
elif [[ ! -s "$TEST_TRACES" ]]; then
    fail "Test 1: TRACES.md appended" "file empty: $TEST_TRACES"
elif ! grep -q "2026-04-25" "$TEST_TRACES"; then
    fail "Test 1: TRACES.md contains show date 2026-04-25" "contents: $(cat "$TEST_TRACES")"
elif ! grep -qE 'delta.*-?1\.7' "$TEST_TRACES"; then
    fail "Test 1: TRACES.md contains delta value" "contents: $(cat "$TEST_TRACES")"
elif ! grep -qE '\-14\.3' "$TEST_TRACES"; then
    fail "Test 1: TRACES.md contains library median -14.3" "contents: $(cat "$TEST_TRACES")"
else
    pass "Test 1: delta -1.7 logged to stdout + TRACES.md"
fi
unset RC

# Test 2: missing library-lufs.json -----------------------------------------
echo "Test 2: missing library-lufs.json → fallback message, no abort"
rm -f "$TEST_LUFS_JSON"
: > "$TEST_TRACES"

OUT="$(PRODUCE_HOUR_LUFS_DELTA_ONLY=1 \
       LIBRARY_LUFS_PATH_OVERRIDE="$TEST_LUFS_JSON" \
       TRACES_PATH_OVERRIDE="$TEST_TRACES" \
       SHOW_DATE_OVERRIDE="2026-04-25" \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC != 0 )); then
    fail "Test 2: must NOT abort when JSON missing" "rc=$RC, output: $OUT"
elif ! grep -qiE 'library-lufs\.json not found.*delta unknown' <<<"$OUT"; then
    fail "Test 2: stderr/stdout shows fallback message" "output: $OUT"
elif ! grep -qiE 'library-lufs\.json not found.*delta unknown' "$TEST_TRACES"; then
    fail "Test 2: TRACES.md records fallback message" "contents: $(cat "$TEST_TRACES")"
else
    pass "Test 2: missing JSON handled gracefully"
fi
unset RC

# Test 3: malformed library-lufs.json ---------------------------------------
echo "Test 3: malformed library-lufs.json → fallback message, no abort"
echo "this is not json {{{" > "$TEST_LUFS_JSON"
: > "$TEST_TRACES"

OUT="$(PRODUCE_HOUR_LUFS_DELTA_ONLY=1 \
       LIBRARY_LUFS_PATH_OVERRIDE="$TEST_LUFS_JSON" \
       TRACES_PATH_OVERRIDE="$TEST_TRACES" \
       SHOW_DATE_OVERRIDE="2026-04-25" \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC != 0 )); then
    fail "Test 3: must NOT abort on malformed JSON" "rc=$RC, output: $OUT"
elif ! grep -qiE '(library-lufs\.json not found|delta unknown|malformed|invalid)' <<<"$OUT"; then
    fail "Test 3: stderr/stdout shows fallback message" "output: $OUT"
elif ! grep -qiE '(library-lufs\.json not found|delta unknown|malformed|invalid)' "$TEST_TRACES"; then
    fail "Test 3: TRACES.md records fallback message" "contents: $(cat "$TEST_TRACES")"
else
    pass "Test 3: malformed JSON handled gracefully"
fi
unset RC

# Test 4: regression guard — loudnorm filter unchanged ----------------------
echo "Test 4: loudnorm=I=-16:TP=-1.5:LRA=11 unchanged in produce-hour.sh"
if grep -q 'loudnorm=I=-16:TP=-1.5:LRA=11' "$SCRIPT"; then
    pass "Test 4: production normalization filter unchanged"
else
    fail "Test 4: loudnorm filter modified or missing" \
         "expected literal: loudnorm=I=-16:TP=-1.5:LRA=11"
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
