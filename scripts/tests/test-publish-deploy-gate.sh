#!/usr/bin/env bash
# Tests for publish.sh — Wave 3 Task 21
#
# These tests exercise the 3rd approval gate: the typed-deploy phrase that
# must be entered (case-sensitive, exact match) BEFORE publish.sh drops the
# DPL into F:\PlayoutONE\Import\Music Logs\.
#
# Phrase format: `yes deploy <YYYY-MM-DD>` where the date matches --date.
#
# Tests:
#   1. Correct phrase                    -> publish proceeds past the gate
#   2. Wrong date (3 tries)              -> publish fails with descriptive error
#   3. Case mismatch (3 tries)           -> publish fails on case sensitivity
#   4. Idle timeout                      -> publish auto-aborts
#   5. --auto-approve flag               -> gate bypassed entirely
#   6. Regression guard                  -> Task 14/15 preanalyze tests still pass
#
# Strategy:
#   - PUBLISH_DEPLOY_INPUT  env var injects phrase (newline-separated for retries).
#   - PUBLISH_DEPLOY_TIMEOUT_SEC override shrinks the 10-min wait to seconds.
#   - PUBLISH_PREANALYZE_MOCK + PUBLISH_SQL_MOCK make Steps 2.5/3 cheap.
#   - --dry-run prevents Steps 4-7 from doing real work, but the gate still runs.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/publish.sh"

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

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
TMPDIR_T21="$(mktemp -d -t pub-gate-XXXXXX)"
trap 'rm -rf "$TMPDIR_T21"' EXIT

AUDIO_DIR="$TMPDIR_T21/audio"
mkdir -p "$AUDIO_DIR"

make_audio() {
    local hour="$1"
    local f="$AUDIO_DIR/MORNING-SHOW-H${hour}.mp3"
    if [[ ! -f "$f" ]]; then
        ffmpeg -hide_banner -loglevel error -y -f lavfi \
            -i "sine=frequency=440:duration=10" -ar 44100 -ac 2 "$f" 2>/dev/null
    fi
    [[ -f "$f" ]] || { echo "FATAL: ffmpeg failed for $f" >&2; exit 2; }
}

make_audio 5

CONFIG="$TMPDIR_T21/config.yaml"
cat > "$CONFIG" <<EOF
playoutone:
  host: 'fake-host'
  audio_path: 'F:\PlayoutONE\Audio'
  temp_path: 'C:\temp'
  db: 'PlayoutONE_Standard'
EOF

export MUTATION_LOG_DIR="$TMPDIR_T21/mutations"
mkdir -p "$MUTATION_LOG_DIR"

[[ -x "$PUBLISH" ]] || { echo "$(red 'FATAL'): $PUBLISH missing or not exec" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Mocks (preanalyze + SQL match) — same pattern as Task 15 tests.
# ---------------------------------------------------------------------------
MOCK_PRE="$TMPDIR_T21/preanalyze-sane.sh"
cat > "$MOCK_PRE" <<'MOCK'
#!/usr/bin/env bash
printf '{"length_ms": 600000, "trim_out_ms": 600000, "extro_ms": 595000}\n'
exit 0
MOCK
chmod +x "$MOCK_PRE"

MOCK_SQL="$TMPDIR_T21/sql-match.sh"
cat > "$MOCK_SQL" <<'MOCK'
#!/usr/bin/env bash
KIND="$1"; UID_ARG="$2"
LOG="${PUBLISH_SQL_LOG:-/dev/null}"
if [[ "$KIND" == "update" ]]; then
    echo "UPDATE uid=$UID_ARG length=$3 trim_out=$4 extro=$5" >> "$LOG"
    exit 0
elif [[ "$KIND" == "select" ]]; then
    echo "SELECT uid=$UID_ARG" >> "$LOG"
    echo "${PUBLISH_SQL_RETURN_TRIMOUT:-600000}	${PUBLISH_SQL_RETURN_EXTRO:-595000}"
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_SQL"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
unset_publish_env() {
    unset PUBLISH_PREANALYZE_MOCK PUBLISH_SQL_MOCK PUBLISH_SQL_LOG \
          PUBLISH_SQL_RETURN_TRIMOUT PUBLISH_SQL_RETURN_EXTRO \
          PUBLISH_DEPLOY_INPUT PUBLISH_DEPLOY_TIMEOUT_SEC || true
}

# Run publish in dry-run mode for date 2026-04-27. Combines stdout+stderr.
run_publish_for_date() {
    local d="$1"; shift
    "$PUBLISH" --date "$d" --hours '5' --audio-dir "$AUDIO_DIR" \
        --config "$CONFIG" --skip-music1-wait --dry-run "$@" 2>&1
    return $?
}

GATE_MARKER='Drop DPL files'   # Step 6 banner (file-drop legacy)
SQL_GATE_MARKER='sql-direct'    # Step 4-7 [sql-direct] banner (Wave 3.5 default)
ABORT_MARKER='deploy gate'      # Substring used in our gate-abort messages

# ---------------------------------------------------------------------------
# Test 1: Correct phrase -> publish proceeds past the gate
# ---------------------------------------------------------------------------
echo "Test 1: correct phrase 'yes deploy 2026-04-27' -> proceeds past gate"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_SQL"
export PUBLISH_DEPLOY_INPUT="yes deploy 2026-04-27"
out="$(run_publish_for_date 2026-04-27)"; rc=$?

if (( rc != 0 )); then
    fail "Test 1: publish should succeed with correct phrase" "rc=$rc; out:\n$out"
elif ! echo "$out" | grep -qiE "$GATE_MARKER|Generate.*DPL|Drop.*DPL|$SQL_GATE_MARKER"; then
    fail "Test 1: publish must reach post-gate steps after correct phrase" "out:\n$out"
elif echo "$out" | grep -qiE "$ABORT_MARKER.*abort|gate.*abort"; then
    fail "Test 1: publish must NOT abort the gate when phrase is correct" "out:\n$out"
else
    pass "Test 1: publish proceeded past gate with correct phrase"
fi

# ---------------------------------------------------------------------------
# Test 2: Wrong date (3 tries) -> fails after retry exhaustion
# ---------------------------------------------------------------------------
echo "Test 2: wrong date 'yes deploy 2026-04-28' (x3) -> fails after retries"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_SQL"
# Three identical wrong attempts: gate should re-prompt twice then abort.
export PUBLISH_DEPLOY_INPUT=$'yes deploy 2026-04-28\nyes deploy 2026-04-28\nyes deploy 2026-04-28'
out="$(run_publish_for_date 2026-04-27)"; rc=$?

if (( rc == 0 )); then
    fail "Test 2: publish must abort after 3 wrong-date attempts" "rc=0; out:\n$out"
elif ! echo "$out" | grep -qiE "yes deploy 2026-04-27"; then
    fail "Test 2: error must echo the EXACT required phrase" "out:\n$out"
elif ! echo "$out" | grep -qiE "$ABORT_MARKER|aborting|max.*attempt|3 attempts"; then
    fail "Test 2: error must indicate gate aborted after retries" "out:\n$out"
else
    pass "Test 2: publish aborted after 3 wrong-date attempts (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 3: Case mismatch (x3) -> fails on case sensitivity
# ---------------------------------------------------------------------------
echo "Test 3: case mismatch 'Yes deploy 2026-04-27' (x3) -> fails"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_SQL"
export PUBLISH_DEPLOY_INPUT=$'Yes deploy 2026-04-27\nYes deploy 2026-04-27\nYes deploy 2026-04-27'
out="$(run_publish_for_date 2026-04-27)"; rc=$?

if (( rc == 0 )); then
    fail "Test 3: publish must abort on case mismatch" "rc=0; out:\n$out"
elif ! echo "$out" | grep -qE "yes deploy 2026-04-27"; then
    fail "Test 3: error must echo the EXACT lowercase required phrase" "out:\n$out"
elif ! echo "$out" | grep -qiE "$ABORT_MARKER|aborting|mismatch|case"; then
    fail "Test 3: error must indicate gate aborted" "out:\n$out"
else
    pass "Test 3: publish aborted on case-sensitive mismatch (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 4: Idle timeout (PUBLISH_DEPLOY_TIMEOUT_SEC=2) -> auto-abort
# ---------------------------------------------------------------------------
echo "Test 4: idle timeout (2s, no input) -> auto-abort"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_SQL"
export PUBLISH_DEPLOY_TIMEOUT_SEC=2
# No PUBLISH_DEPLOY_INPUT: send empty stdin so read times out.
t0=$(date +%s)
out="$("$PUBLISH" --date 2026-04-27 --hours '5' --audio-dir "$AUDIO_DIR" \
    --config "$CONFIG" --skip-music1-wait --dry-run </dev/null 2>&1)"; rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))

if (( rc == 0 )); then
    fail "Test 4: publish must abort on timeout" "rc=0; out:\n$out"
elif (( elapsed > 30 )); then
    fail "Test 4: timeout took too long (${elapsed}s) — override likely ignored" "out:\n$out"
elif ! echo "$out" | grep -qiE "timeout|timed out|idle"; then
    fail "Test 4: error must mention timeout" "out:\n$out"
else
    pass "Test 4: publish auto-aborted on idle timeout (${elapsed}s, rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 5: --auto-approve bypasses the gate entirely
# ---------------------------------------------------------------------------
echo "Test 5: --auto-approve bypasses gate"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_SQL"
# No PUBLISH_DEPLOY_INPUT, no timeout override — if the gate runs, it will
# either prompt forever or abort. With --auto-approve it should breeze through.
out="$(run_publish_for_date 2026-04-27 --auto-approve)"; rc=$?

if (( rc != 0 )); then
    fail "Test 5: --auto-approve must succeed (gate skipped)" "rc=$rc; out:\n$out"
elif ! echo "$out" | grep -qiE "auto-approve|bypass|skipped"; then
    fail "Test 5: must announce gate bypass under --auto-approve" "out:\n$out"
elif echo "$out" | grep -qiE "type.*phrase|required phrase|deploy gate.*abort"; then
    fail "Test 5: --auto-approve must NOT prompt or abort the gate" "out:\n$out"
else
    pass "Test 5: --auto-approve bypassed the gate"
fi

# ---------------------------------------------------------------------------
# Test 6: Regression guard — Task 14/15 preanalysis test suite still passes
# ---------------------------------------------------------------------------
echo "Test 6: regression — test-publish-preanalysis.sh still green"
REGRESSION="$SCRIPT_DIR/tests/test-publish-preanalysis.sh"
if [[ ! -x "$REGRESSION" ]]; then
    fail "Test 6: regression suite missing at $REGRESSION"
else
    if "$REGRESSION" >"$TMPDIR_T21/regression.out" 2>&1; then
        pass "Test 6: test-publish-preanalysis.sh PASSED post-edit"
    else
        fail "Test 6: regression suite FAILED — gate broke Task 14/15" \
             "tail of regression.out:\n$(tail -40 "$TMPDIR_T21/regression.out")"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
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
