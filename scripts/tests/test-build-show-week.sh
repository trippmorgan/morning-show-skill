#!/usr/bin/env bash
# Tests for build-show.sh week mode — Wave 3 Task 19
# Multi-day mode with per-day cap and continue-on-failure.
#
# Tests:
#   1. Dry-run week starting Monday → prints 5 day commands without executing;
#      reports Mon-Fri dates correctly.
#   2. Input date is Tuesday → aborts with "must be a Monday" error.
#   3. Dry-run with mocked cap-hit on day 2 → shows day 2 aborted, days 3-5 still planned.
#   4. Single-day path (regression guard) — calling without `week` keeps the
#      single-day code path discoverable (script accepts the date and validates it).
#
# Mocking strategy (env-var injection consumed by build-show.sh):
#   BUILD_SHOW_DRY_RUN=1                 Don't actually run per-day pipelines;
#                                        record the planned commands on stdout.
#   BUILD_SHOW_MOCK_DAY_FAIL=YYYY-MM-DD  Force the per-day run for that date to
#                                        return non-zero (simulates cap exceeded).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$SCRIPT_DIR/build-show.sh"

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

# Sanity ----------------------------------------------------------------------
if [[ ! -x "$BUILD" ]]; then
    echo "$(red 'FATAL'): $BUILD is not executable" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# Test 1: dry-run week starting on a Monday
# -----------------------------------------------------------------------------
echo "Test 1: BUILD_SHOW_DRY_RUN=1 build-show.sh week 2026-04-27 (Monday)"
OUT_1=$(mktemp /tmp/test-week-1-XXXXXX.out)
ERR_1=$(mktemp /tmp/test-week-1-XXXXXX.err)
set +e
BUILD_SHOW_DRY_RUN=1 "$BUILD" week 2026-04-27 >"$OUT_1" 2>"$ERR_1"
RC1=$?
set -e

if (( RC1 != 0 )); then
    fail "Test 1: should exit 0 in dry-run" "rc=$RC1, err=$(tail -10 "$ERR_1")"
else
    # Each of Mon-Fri should appear exactly once in the planned commands.
    EXPECTED_DATES=(2026-04-27 2026-04-28 2026-04-29 2026-04-30 2026-05-01)
    MISSING=""
    for d in "${EXPECTED_DATES[@]}"; do
        if ! grep -q "$d" "$OUT_1" "$ERR_1"; then
            MISSING+="$d "
        fi
    done
    # Also: ensure Saturday/Sunday do NOT appear in planned dates
    UNEXPECTED=""
    for d in 2026-05-02 2026-05-03; do
        if grep -q "$d" "$OUT_1" "$ERR_1"; then
            UNEXPECTED+="$d "
        fi
    done
    if [[ -n "$MISSING" ]]; then
        fail "Test 1: missing planned dates" "missing: $MISSING"
    elif [[ -n "$UNEXPECTED" ]]; then
        fail "Test 1: weekend dates present in plan" "unexpected: $UNEXPECTED"
    else
        pass "Test 1: dry-run plans Mon-Fri (5 days, no weekend)"
    fi
fi

# -----------------------------------------------------------------------------
# Test 2: input date is Tuesday → must reject
# -----------------------------------------------------------------------------
echo "Test 2: input is a Tuesday → must abort with 'must be a Monday'"
OUT_2=$(mktemp /tmp/test-week-2-XXXXXX.out)
ERR_2=$(mktemp /tmp/test-week-2-XXXXXX.err)
set +e
BUILD_SHOW_DRY_RUN=1 "$BUILD" week 2026-04-28 >"$OUT_2" 2>"$ERR_2"
RC2=$?
set -e

if (( RC2 == 0 )); then
    fail "Test 2: should exit non-zero on non-Monday" "rc=0"
elif ! grep -qi "must be a monday" "$ERR_2" "$OUT_2"; then
    fail "Test 2: error message should say 'must be a Monday'" \
         "stderr=$(tail -5 "$ERR_2")"
else
    pass "Test 2: non-Monday rejected with descriptive error"
fi

# -----------------------------------------------------------------------------
# Test 3: dry-run with mocked failure on Wednesday — Thu/Fri still planned
# -----------------------------------------------------------------------------
echo "Test 3: dry-run with cap-hit on 2026-04-29 (Wed) → Thu/Fri continue"
OUT_3=$(mktemp /tmp/test-week-3-XXXXXX.out)
ERR_3=$(mktemp /tmp/test-week-3-XXXXXX.err)
set +e
BUILD_SHOW_DRY_RUN=1 \
BUILD_SHOW_MOCK_DAY_FAIL=2026-04-29 \
"$BUILD" week 2026-04-27 >"$OUT_3" 2>"$ERR_3"
RC3=$?
set -e

# rc may be non-zero if we treat partial failure as warning; the contract
# is the SUMMARY shows correct outcomes — not the exit code.
ALL=$(cat "$OUT_3" "$ERR_3")

# Wed should appear as failed/aborted in the summary.
if ! echo "$ALL" | grep -E "2026-04-29.*(abort|fail|cap)" -i >/dev/null; then
    fail "Test 3: Wed (2026-04-29) should be marked as aborted/failed in summary" \
         "summary missing"
# Thu and Fri must still appear as planned/built.
elif ! echo "$ALL" | grep -q "2026-04-30"; then
    fail "Test 3: Thu (2026-04-30) should still be planned after Wed failure" \
         "Thu missing"
elif ! echo "$ALL" | grep -q "2026-05-01"; then
    fail "Test 3: Fri (2026-05-01) should still be planned after Wed failure" \
         "Fri missing"
elif ! echo "$ALL" | grep -qi "week build complete"; then
    fail "Test 3: end-of-week summary should be printed" "summary header missing"
else
    pass "Test 3: continue-on-failure preserves Thu+Fri, summary printed"
fi

# -----------------------------------------------------------------------------
# Test 4: single-day path regression — non-week invocations must NOT take the
# week code path.  We verify two things:
#   (a) `--help` still works (rc=0, prints "Usage:")
#   (b) a single-day dry-run still emits the existing single-day banner
#       ("Date: <date> (<day>)") and does NOT emit the week summary header.
# -----------------------------------------------------------------------------
echo "Test 4: single-day path regression (no 'week' subcommand)"
OUT_4A=$(mktemp /tmp/test-week-4a-XXXXXX.out)
ERR_4A=$(mktemp /tmp/test-week-4a-XXXXXX.err)
set +e
"$BUILD" --help >"$OUT_4A" 2>"$ERR_4A"
RC4A=$?
set -e

OUT_4B=$(mktemp /tmp/test-week-4b-XXXXXX.out)
ERR_4B=$(mktemp /tmp/test-week-4b-XXXXXX.err)
set +e
"$BUILD" --date 2026-04-27 --dry-run --auto-approve --step research \
    >"$OUT_4B" 2>"$ERR_4B"
# rc may be non-zero due to pre-existing manifest-write behavior on empty
# show dirs — that's the EXISTING behavior we are guarding against changing.
set -e

if (( RC4A != 0 )); then
    fail "Test 4a: --help should exit 0 (regression)" \
         "rc=$RC4A, err=$(tail -5 "$ERR_4A")"
elif ! grep -qi "usage:" "$OUT_4A" "$ERR_4A"; then
    fail "Test 4a: --help should print Usage:" "missing"
elif grep -qi "week build complete" "$ERR_4B" "$OUT_4B"; then
    fail "Test 4b: single-day path must NOT trigger the week summary" \
         "week summary appeared"
elif ! grep -qE "Date:[[:space:]]*2026-04-27" "$ERR_4B" "$OUT_4B"; then
    fail "Test 4b: single-day banner should still show 'Date: 2026-04-27'" \
         "missing"
else
    pass "Test 4: single-day path unchanged (regression guard)"
fi
rm -f "$OUT_4A" "$ERR_4A" "$OUT_4B" "$ERR_4B"

# Cleanup ---------------------------------------------------------------------
rm -f "$OUT_1" "$ERR_1" "$OUT_2" "$ERR_2" "$OUT_3" "$ERR_3"

# Summary ---------------------------------------------------------------------
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
