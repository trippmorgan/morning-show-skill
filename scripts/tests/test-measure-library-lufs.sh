#!/usr/bin/env bash
# Tests for measure-library-lufs.sh — Wave 3 Task 16
# TDD: write tests first, then implementation.
#
# Tests:
#   1. Dry-run mode (MEASURE_LUFS_DRY_RUN=1) prints SQL query + sample count
#      without executing real SQL or downloads.
#   2. With MEASURE_LUFS_MOCK supplying LUFS values, script computes correct
#      median, percentiles, std dev, and sample count, and writes JSON output.
#   3. Zero samples → exits non-zero with descriptive stderr.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/measure-library-lufs.sh"

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

# Use isolated output paths so tests don't clobber a real reference file
TEST_OUT_JSON="$(mktemp /tmp/test-lufs-out-XXXX.json)"
rm -f "$TEST_OUT_JSON"
TEST_LOG_DIR="$(mktemp -d /tmp/test-lufs-logs-XXXX)"

cleanup() {
    rm -f "$TEST_OUT_JSON"
    rm -rf "$TEST_LOG_DIR"
}
trap cleanup EXIT

echo
echo "Running tests against: $SCRIPT"
echo

# Test 1: dry-run -----------------------------------------------------------
echo "Test 1: MEASURE_LUFS_DRY_RUN=1 prints SQL + sample count, no execution"
OUT="$(MEASURE_LUFS_DRY_RUN=1 \
       MEASURE_LUFS_OUTPUT="$TEST_OUT_JSON" \
       MEASURE_LUFS_SAMPLE_COUNT=50 \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC != 0 )); then
    fail "Test 1: dry-run exit code 0" "got $RC, output: $OUT"
elif ! grep -q "SELECT TOP 50" <<<"$OUT"; then
    fail "Test 1: dry-run prints SQL query" "output: $OUT"
elif ! grep -q "Type=16" <<<"$OUT"; then
    fail "Test 1: dry-run SQL filters Type=16" "output: $OUT"
elif ! grep -q "ORDER BY NEWID" <<<"$OUT"; then
    fail "Test 1: dry-run SQL randomizes via NEWID()" "output: $OUT"
elif ! grep -qE "(sample[_ ]count|samples).*50|50.*samples?" <<<"$OUT"; then
    fail "Test 1: dry-run prints sample count" "output: $OUT"
elif [[ -f "$TEST_OUT_JSON" ]]; then
    fail "Test 1: dry-run must NOT write JSON output" "file exists at $TEST_OUT_JSON"
else
    pass "Test 1: dry-run printed SQL + sample count, no side effects"
fi
unset RC

# Test 2: mock LUFS values --------------------------------------------------
echo "Test 2: MEASURE_LUFS_MOCK values → correct median/percentiles/stddev"
# Sample set: -14.0, -15.5, -13.2, -16.1, -14.8
# Sorted:    -16.1, -15.5, -14.8, -14.0, -13.2
# Median (n=5): index 2 → -14.8
# P25 (linear, 5 vals): rank 0.25*4 = 1 → -15.5
# P75 (linear, 5 vals): rank 0.75*4 = 3 → -14.0
MOCK_VALS="-14.0,-15.5,-13.2,-16.1,-14.8"
OUT="$(MEASURE_LUFS_MOCK="$MOCK_VALS" \
       MEASURE_LUFS_OUTPUT="$TEST_OUT_JSON" \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC != 0 )); then
    fail "Test 2: mock run exit code 0" "rc=$RC, output: $OUT"
elif [[ ! -s "$TEST_OUT_JSON" ]]; then
    fail "Test 2: JSON output file written" "no file at $TEST_OUT_JSON"
else
    # Parse JSON
    MEDIAN=$(jq -r '.median_lufs' "$TEST_OUT_JSON" 2>/dev/null)
    P25=$(jq -r '.p25' "$TEST_OUT_JSON" 2>/dev/null)
    P75=$(jq -r '.p75' "$TEST_OUT_JSON" 2>/dev/null)
    STDDEV=$(jq -r '.stddev' "$TEST_OUT_JSON" 2>/dev/null)
    COUNT=$(jq -r '.sample_count' "$TEST_OUT_JSON" 2>/dev/null)
    MEASURED_AT=$(jq -r '.measured_at' "$TEST_OUT_JSON" 2>/dev/null)
    SAMPLES_LEN=$(jq -r '.samples | length' "$TEST_OUT_JSON" 2>/dev/null)

    # tolerance helpers (numeric ~0.01)
    near() {
        # near $a $b $tol  → returns 0 if |a-b| <= tol
        awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d=a-b; if (d<0) d=-d; exit (d<=t)?0:1 }'
    }

    if [[ "$COUNT" != "5" ]]; then
        fail "Test 2: sample_count == 5" "got $COUNT"
    elif [[ "$SAMPLES_LEN" != "5" ]]; then
        fail "Test 2: samples array length == 5" "got $SAMPLES_LEN"
    elif ! near "$MEDIAN" "-14.8" 0.01; then
        fail "Test 2: median_lufs == -14.8" "got $MEDIAN"
    elif ! near "$P25" "-15.5" 0.01; then
        fail "Test 2: p25 == -15.5" "got $P25"
    elif ! near "$P75" "-14.0" 0.01; then
        fail "Test 2: p75 == -14.0" "got $P75"
    elif ! near "$STDDEV" "1.03" 0.05; then
        # Population stddev of {-14.0,-15.5,-13.2,-16.1,-14.8}
        # mean = -14.72; sum of squared deviations = 5.348
        # pop variance = 5.348 / 5 = 1.0696; pop stddev = sqrt ≈ 1.034
        fail "Test 2: stddev ≈ 1.03 (population)" "got $STDDEV"
    elif [[ -z "$MEASURED_AT" || "$MEASURED_AT" == "null" ]]; then
        fail "Test 2: measured_at populated" "got '$MEASURED_AT'"
    else
        pass "Test 2: median=$MEDIAN p25=$P25 p75=$P75 stddev=$STDDEV count=$COUNT"
    fi
fi
unset RC
rm -f "$TEST_OUT_JSON"

# Test 3: zero samples ------------------------------------------------------
echo "Test 3: empty MEASURE_LUFS_MOCK → non-zero exit + descriptive stderr"
OUT="$(MEASURE_LUFS_MOCK="" \
       MEASURE_LUFS_MOCK_EMPTY=1 \
       MEASURE_LUFS_OUTPUT="$TEST_OUT_JSON" \
       "$SCRIPT" 2>&1)" || RC=$?
RC=${RC:-0}

if (( RC == 0 )); then
    fail "Test 3: must exit non-zero with zero samples" "rc=0, output: $OUT"
elif ! grep -qiE "(no samples|0 samples|zero samples|empty)" <<<"$OUT"; then
    fail "Test 3: must print descriptive stderr" "output: $OUT"
else
    pass "Test 3: zero samples rejected (rc=$RC)"
fi
unset RC

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
