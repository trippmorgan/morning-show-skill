#!/usr/bin/env bash
# Tests for publish.sh — Wave 3 Task 15
#
# These tests exercise the pre-analysis + Audio-table marker write path that
# replaces blind trust in AutoImporter (the silent-skip class of failure
# from the March 30 incident).
#
# Strategy:
#   - Run publish.sh with --dry-run so it never actually SCPs/SSHes/sqlcmds.
#   - Inject behavior via env vars:
#       PUBLISH_PREANALYZE_MOCK=<path>   stand-in for preanalyze-segment.sh
#       PUBLISH_SQL_MOCK=<path>          stand-in for SQL UPDATE/SELECT calls
#   - Capture publish.sh stdout/stderr and assert on planned SQL + behavior.
#
# Tests:
#   1. dry-run prints planned SQL UPDATE without executing
#   2. mock preanalyze sane values → SQL UPDATEs are well-formed
#   3. mock preanalyze extro_ms=0 → publish aborts with descriptive error
#   4. mock verification SELECT returns mismatched value → publish aborts
#   5. mock preanalyze script not found → publish aborts (no silent skip)

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
TMPDIR_T15="$(mktemp -d -t pub-pre-XXXXXX)"
trap 'rm -rf "$TMPDIR_T15"' EXIT

AUDIO_DIR="$TMPDIR_T15/audio"
mkdir -p "$AUDIO_DIR"

# Create dummy audio files. publish.sh uses ffprobe on them in step 1; we
# pre-render a 10s sine so the duration probe succeeds.
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
make_audio 6
make_audio 7
make_audio 8

# Dummy config.yaml — publish.sh's cfg_val just greps "key:" lines.
CONFIG="$TMPDIR_T15/config.yaml"
cat > "$CONFIG" <<EOF
playoutone:
  host: 'fake-host'
  audio_path: 'F:\PlayoutONE\Audio'
  temp_path: 'C:\temp'
  db: 'PlayoutONE_Standard'
EOF

# Mutation log dir override so we don't pollute production logs.
export MUTATION_LOG_DIR="$TMPDIR_T15/mutations"
mkdir -p "$MUTATION_LOG_DIR"

# Sanity: publish.sh exists.
[[ -x "$PUBLISH" ]] || { echo "$(red 'FATAL'): $PUBLISH missing or not exec" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Mock builders
# ---------------------------------------------------------------------------

# A preanalyze mock that returns sane markers for any input.
make_mock_preanalyze_sane() {
    local p="$TMPDIR_T15/preanalyze-sane.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
# Sane mock: 600s file, extro = length - 5000
printf '{"length_ms": 600000, "trim_out_ms": 600000, "extro_ms": 595000}\n'
exit 0
MOCK
    chmod +x "$p"
    echo "$p"
}

# A preanalyze mock that returns extro_ms=0 (the March 30 failure mode).
make_mock_preanalyze_zero_extro() {
    local p="$TMPDIR_T15/preanalyze-zero-extro.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
printf '{"length_ms": 600000, "trim_out_ms": 600000, "extro_ms": 0}\n'
exit 0
MOCK
    chmod +x "$p"
    echo "$p"
}

# A SQL mock that records every call and returns matching values from the
# planned UPDATE so verification passes.
make_mock_sql_match() {
    local p="$TMPDIR_T15/sql-match.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
# Args: <kind> <uid> [length] [trim_out] [extro]
# kind = update | select
KIND="$1"; UID_ARG="$2"
LOG="${PUBLISH_SQL_LOG:-/dev/null}"
if [[ "$KIND" == "update" ]]; then
    LEN="$3"; TRIM="$4"; EXTRO="$5"
    echo "UPDATE uid=$UID_ARG length=$LEN trim_out=$TRIM extro=$EXTRO" >> "$LOG"
    exit 0
elif [[ "$KIND" == "select" ]]; then
    # Echo back the values we were told to verify against.
    echo "SELECT uid=$UID_ARG" >> "$LOG"
    # Return what publish.sh expects: trim_out\textro on one line
    echo "${PUBLISH_SQL_RETURN_TRIMOUT:-600000}	${PUBLISH_SQL_RETURN_EXTRO:-595000}"
    exit 0
fi
exit 1
MOCK
    chmod +x "$p"
    echo "$p"
}

# A SQL mock that returns mismatched values on SELECT.
make_mock_sql_mismatch() {
    local p="$TMPDIR_T15/sql-mismatch.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
KIND="$1"; UID_ARG="$2"
LOG="${PUBLISH_SQL_LOG:-/dev/null}"
if [[ "$KIND" == "update" ]]; then
    echo "UPDATE uid=$UID_ARG length=$3 trim_out=$4 extro=$5" >> "$LOG"
    exit 0
elif [[ "$KIND" == "select" ]]; then
    echo "SELECT uid=$UID_ARG" >> "$LOG"
    # Pretend the DB stored zero — classic AutoImporter silent-skip mode.
    echo "0	0"
    exit 0
fi
exit 1
MOCK
    chmod +x "$p"
    echo "$p"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_publish() {
    # Return combined stdout+stderr; never let publish.sh kill the test runner.
    "$PUBLISH" --date 2026-04-06 --hours '5' --audio-dir "$AUDIO_DIR" \
        --config "$CONFIG" --skip-music1-wait --dry-run 2>&1
    return $?
}

# Important: env vars on the same line as `var=$(...)` apply ONLY to the
# command-substitution subshell's assignments, NOT to the inner command's
# environment, because `var=...` is itself an assignment (not a simple
# command). We must `export` first, then run the function. Each test resets
# these.
unset_publish_env() {
    unset PUBLISH_PREANALYZE_MOCK PUBLISH_SQL_MOCK PUBLISH_SQL_LOG \
          PUBLISH_SQL_RETURN_TRIMOUT PUBLISH_SQL_RETURN_EXTRO || true
}

# ---------------------------------------------------------------------------
# Test 1: dry-run prints planned SQL UPDATE without executing
# ---------------------------------------------------------------------------
echo "Test 1: dry-run prints planned UPDATE (Length/TrimOut/Extro) without executing"
SQL_LOG="$TMPDIR_T15/sql1.log"
: > "$SQL_LOG"
mock_pre="$(make_mock_preanalyze_sane)"
mock_sql="$(make_mock_sql_match)"

unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$mock_pre"
export PUBLISH_SQL_MOCK="$mock_sql"
export PUBLISH_SQL_LOG="$SQL_LOG"
out="$(run_publish)"; rc=$?

if (( rc != 0 )); then
    fail "Test 1: dry-run should succeed" "rc=$rc; out:\n$out"
elif ! echo "$out" | grep -qE 'UPDATE +Audio +SET'; then
    fail "Test 1: dry-run should print 'UPDATE Audio SET ...'" "out:\n$out"
elif ! echo "$out" | grep -qE 'Length=600000'; then
    fail "Test 1: dry-run should print Length=600000" "out:\n$out"
elif ! echo "$out" | grep -qE 'Extro=595000'; then
    fail "Test 1: dry-run should print Extro=595000" "out:\n$out"
elif [[ -s "$SQL_LOG" ]]; then
    fail "Test 1: dry-run must NOT execute the SQL mock" "log:\n$(cat "$SQL_LOG")"
else
    pass "Test 1: dry-run printed planned UPDATE without executing"
fi

# ---------------------------------------------------------------------------
# Test 2: mock preanalyze sane → planned SQL UPDATEs are well-formed
# ---------------------------------------------------------------------------
echo "Test 2: well-formed UPDATE statements with computed markers"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$mock_pre"
export PUBLISH_SQL_MOCK="$mock_sql"
export PUBLISH_SQL_LOG="$TMPDIR_T15/sql2.log"
out="$(run_publish)"; rc=$?

# Look for an UPDATE statement that names all three columns and the UID.
expected_uid="90005"
if (( rc != 0 )); then
    fail "Test 2: dry-run should succeed" "rc=$rc; out:\n$out"
elif ! echo "$out" | grep -qE "UPDATE +Audio +SET +Length=600000, *TrimOut=600000, *Extro=595000 +WHERE +UID='?${expected_uid}'?"; then
    fail "Test 2: SQL UPDATE not well-formed for UID ${expected_uid}" "out:\n$out"
else
    pass "Test 2: well-formed UPDATE for UID ${expected_uid}"
fi

# ---------------------------------------------------------------------------
# Test 3: mock preanalyze extro_ms=0 → publish aborts
# ---------------------------------------------------------------------------
echo "Test 3: extro_ms=0 from preanalyze must abort publish"
mock_pre_zero="$(make_mock_preanalyze_zero_extro)"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$mock_pre_zero"
export PUBLISH_SQL_MOCK="$mock_sql"
export PUBLISH_SQL_LOG="$TMPDIR_T15/sql3.log"
out="$(run_publish)"; rc=$?

if (( rc == 0 )); then
    fail "Test 3: publish must abort when extro_ms=0" "rc=0; out:\n$out"
elif ! echo "$out" | grep -qiE 'extro.*(0|zero)|never write Extro=0|march[ -]?30'; then
    fail "Test 3: abort message must mention Extro=0" "out:\n$out"
else
    pass "Test 3: publish aborted with descriptive error (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 4: mock verification SELECT returns mismatched value → abort
# ---------------------------------------------------------------------------
echo "Test 4: verification SELECT mismatch → abort"
mock_sql_mm="$(make_mock_sql_mismatch)"

# This test must actually execute (no --dry-run) so the verify path runs.
# We'll use a no-op SSH/SCP shim by overriding PATH.
SHIM_DIR="$TMPDIR_T15/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/ssh" <<'SHIM'
#!/usr/bin/env bash
# Pretend remote ops succeed; print 'ok' for the connectivity check.
case "$*" in
    *"echo ok"*) echo "ok"; exit 0 ;;
    *Test-Path*) echo "OK"; exit 0 ;;
    *) exit 0 ;;
esac
SHIM
cat > "$SHIM_DIR/scp" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$SHIM_DIR/ssh" "$SHIM_DIR/scp"

run_publish_no_dry() {
    PATH="$SHIM_DIR:$PATH" "$PUBLISH" --date 2026-04-06 --hours '5' \
        --audio-dir "$AUDIO_DIR" --config "$CONFIG" --skip-music1-wait 2>&1
}

unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$mock_pre"
export PUBLISH_SQL_MOCK="$mock_sql_mm"
export PUBLISH_SQL_LOG="$TMPDIR_T15/sql4.log"
out="$(run_publish_no_dry)"; rc=$?

if (( rc == 0 )); then
    fail "Test 4: publish must abort on verify mismatch" "rc=0; out:\n$out"
elif ! echo "$out" | grep -qiE 'mismatch|verif.*fail|verification'; then
    fail "Test 4: abort message must mention verification mismatch" "out:\n$out"
else
    pass "Test 4: publish aborted on verify mismatch (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 5: missing preanalyze → abort with descriptive error
# ---------------------------------------------------------------------------
echo "Test 5: missing preanalyze script → abort (no silent skip)"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$TMPDIR_T15/does-not-exist-$$.sh"
export PUBLISH_SQL_MOCK="$mock_sql"
export PUBLISH_SQL_LOG="$TMPDIR_T15/sql5.log"
out="$(run_publish)"; rc=$?

if (( rc == 0 )); then
    fail "Test 5: must abort when preanalyze missing" "rc=0; out:\n$out"
elif ! echo "$out" | grep -qiE 'preanalyze.*not found|preanalyze.*missing|cannot find preanalyze'; then
    fail "Test 5: abort message must mention preanalyze missing" "out:\n$out"
else
    pass "Test 5: missing preanalyze caused descriptive abort (rc=$rc)"
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
