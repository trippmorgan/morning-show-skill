#!/usr/bin/env bash
# Tests for publish.sh — Wave 3.5 sql-direct mode
#
# Exercises the new --publish-mode sql-direct path that mimics Music1's ODBC
# direct-INSERT into PlayoutONE_Standard.Playlists + ScheduledLogs (file-drop
# AutoImporter pipeline has been dormant since 2019; see
# .planning/MUSIC1-INVESTIGATION-2026-04-24.md).
#
# Tests:
#   1. Dry-run prints planned INSERT statements without executing
#   2. Mock SQL succeeds → publish completes + mutation log row written
#   3. Mock SQL fails on row 5 → publish executes ROLLBACK, no rows leak
#   4. Verification mismatch (mock returns wrong row count) → publish aborts
#   5. Blast-radius >50 → publish refuses (sanity guard)
#   6. Regression — test-publish-preanalysis.sh still passes
#
# Strategy: env-mock the Audio-table SQL (PUBLISH_SQL_MOCK) and the
# Playlists/ScheduledLogs SQL (PUBLISH_PLAYLISTS_SQL_MOCK). Pre-analyze is
# also mocked. Live-window is bypassed via PUBLISH_LIVE_WINDOW_OK=1.

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
TMPDIR_W35="$(mktemp -d -t pub-sqld-XXXXXX)"
trap 'rm -rf "$TMPDIR_W35"' EXIT

AUDIO_DIR="$TMPDIR_W35/audio"
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

# Make all 4 morning-show hours so the 4-hour assertion has data.
make_audio 5
make_audio 6
make_audio 7
make_audio 8

CONFIG="$TMPDIR_W35/config.yaml"
cat > "$CONFIG" <<EOF
playoutone:
  host: 'fake-host'
  audio_path: 'F:\PlayoutONE\Audio'
  temp_path: 'C:\temp'
  db: 'PlayoutONE_Standard'
EOF

export MUTATION_LOG_DIR="$TMPDIR_W35/mutations"
mkdir -p "$MUTATION_LOG_DIR"

[[ -x "$PUBLISH" ]] || { echo "$(red 'FATAL'): $PUBLISH missing or not exec" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Mocks
# ---------------------------------------------------------------------------

# Audio-table SQL mock (covers Step 3 marker writes).
MOCK_PRE="$TMPDIR_W35/preanalyze-sane.sh"
cat > "$MOCK_PRE" <<'MOCK'
#!/usr/bin/env bash
printf '{"length_ms": 600000, "trim_out_ms": 600000, "extro_ms": 595000}\n'
exit 0
MOCK
chmod +x "$MOCK_PRE"

MOCK_AUDIO_SQL="$TMPDIR_W35/audio-sql-match.sh"
cat > "$MOCK_AUDIO_SQL" <<'MOCK'
#!/usr/bin/env bash
KIND="$1"; UID_ARG="$2"
if [[ "$KIND" == "update" ]]; then
    exit 0
elif [[ "$KIND" == "select" ]]; then
    echo "${PUBLISH_SQL_RETURN_TRIMOUT:-600000}	${PUBLISH_SQL_RETURN_EXTRO:-595000}"
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_AUDIO_SQL"

# Playlists/ScheduledLogs SQL mock — happy path (Test 2).
make_mock_playlists_happy() {
    local p="$TMPDIR_W35/playlists-sql-happy.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
LOG="${PUBLISH_PLAYLISTS_LOG:-/dev/null}"
verb="$1"; shift
case "$verb" in
    begin)              echo "BEGIN" >> "$LOG"; exit 0 ;;
    commit)             echo "COMMIT" >> "$LOG"; exit 0 ;;
    rollback)           echo "ROLLBACK" >> "$LOG"; exit 0 ;;
    insert_playlists)
        echo "INSERT_PLAYLISTS gindex=$1 name=$2 airtime=$3 uid=$4 title=$5 artist=$6 length=$7 order=$8 guid=${9:-}" >> "$LOG"
        exit 0
        ;;
    insert_scheduledlogs)
        echo "INSERT_SCHEDULEDLOGS name=$1 realdate=$2 hours=$3" >> "$LOG"
        exit 0
        ;;
    count_for_range)
        echo "COUNT_FOR_RANGE lo=$1 hi=$2" >> "$LOG"
        # Always report 1 — perfect verification.
        echo "1"
        exit 0
        ;;
esac
echo "UNKNOWN_VERB $verb" >> "$LOG"
exit 1
MOCK
    chmod +x "$p"
    echo "$p"
}

# Playlists mock — fails on the 3rd insert_playlists call (Test 3).
# (4-hour show plans 4 inserts; failing the 3rd lets us assert ROLLBACK fires
#  before all 4 succeed — analogous to "row 5 of N" in spec.)
make_mock_playlists_fail_on_third() {
    local p="$TMPDIR_W35/playlists-sql-fail-third.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
LOG="${PUBLISH_PLAYLISTS_LOG:-/dev/null}"
COUNTER_FILE="${PUBLISH_PLAYLISTS_COUNTER:-/tmp/__pcounter}"
verb="$1"; shift
case "$verb" in
    begin)              echo "BEGIN" >> "$LOG"; echo 0 > "$COUNTER_FILE"; exit 0 ;;
    commit)             echo "COMMIT" >> "$LOG"; exit 0 ;;
    rollback)           echo "ROLLBACK" >> "$LOG"; exit 0 ;;
    insert_playlists)
        n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$COUNTER_FILE"
        echo "INSERT_PLAYLISTS_ATTEMPT $n gindex=$1 uid=$4" >> "$LOG"
        if (( n == 3 )); then
            echo "INSERT_PLAYLISTS_FAILED $n" >> "$LOG"
            exit 1
        fi
        exit 0
        ;;
    insert_scheduledlogs)
        echo "INSERT_SCHEDULEDLOGS_SHOULD_NOT_RUN" >> "$LOG"
        exit 0
        ;;
    count_for_range)    echo "COUNT_FOR_RANGE lo=$1 hi=$2" >> "$LOG"; echo "1"; exit 0 ;;
esac
exit 1
MOCK
    chmod +x "$p"
    echo "$p"
}

# Playlists mock — verify returns wrong count (Test 4).
make_mock_playlists_verify_mismatch() {
    local p="$TMPDIR_W35/playlists-sql-verify-mismatch.sh"
    cat > "$p" <<'MOCK'
#!/usr/bin/env bash
LOG="${PUBLISH_PLAYLISTS_LOG:-/dev/null}"
verb="$1"; shift
case "$verb" in
    begin)              echo "BEGIN" >> "$LOG"; exit 0 ;;
    commit)             echo "COMMIT" >> "$LOG"; exit 0 ;;
    rollback)           echo "ROLLBACK" >> "$LOG"; exit 0 ;;
    insert_playlists)   echo "INSERT_PLAYLISTS gindex=$1 uid=$4" >> "$LOG"; exit 0 ;;
    insert_scheduledlogs) echo "INSERT_SCHEDULEDLOGS name=$1" >> "$LOG"; exit 0 ;;
    count_for_range)
        echo "COUNT_FOR_RANGE lo=$1 hi=$2" >> "$LOG"
        # Wrong count — should be 1, return 0.
        echo "0"
        exit 0
        ;;
esac
exit 1
MOCK
    chmod +x "$p"
    echo "$p"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
unset_publish_env() {
    unset PUBLISH_PREANALYZE_MOCK PUBLISH_SQL_MOCK PUBLISH_SQL_LOG \
          PUBLISH_SQL_RETURN_TRIMOUT PUBLISH_SQL_RETURN_EXTRO \
          PUBLISH_DEPLOY_INPUT PUBLISH_DEPLOY_TIMEOUT_SEC \
          PUBLISH_PLAYLISTS_SQL_MOCK PUBLISH_PLAYLISTS_LOG PUBLISH_PLAYLISTS_COUNTER \
          PUBLISH_LIVE_WINDOW_OK PUBLISH_BLAST_RADIUS_LIMIT || true
}

# Dry-run helper: 4-hour show, sql-direct mode.
run_publish_dry_4h() {
    "$PUBLISH" --date 2026-04-27 --hours '5,6,7,8' \
        --audio-dir "$AUDIO_DIR" --config "$CONFIG" \
        --publish-mode sql-direct --auto-approve --dry-run 2>&1
    return $?
}

# Real-run helper (with shimmed ssh/scp). All SQL goes through mocks.
SHIM_DIR="$TMPDIR_W35/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/ssh" <<'SHIM'
#!/usr/bin/env bash
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

run_publish_real_4h() {
    PATH="$SHIM_DIR:$PATH" "$PUBLISH" --date 2026-04-27 --hours '5,6,7,8' \
        --audio-dir "$AUDIO_DIR" --config "$CONFIG" \
        --publish-mode sql-direct --auto-approve 2>&1
    return $?
}

# ---------------------------------------------------------------------------
# Test 1: Dry-run prints planned INSERTs without executing
# ---------------------------------------------------------------------------
echo "Test 1: dry-run prints planned INSERT statements without executing"
PL_LOG="$TMPDIR_W35/t1-playlists.log"; : > "$PL_LOG"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_AUDIO_SQL"
export PUBLISH_PLAYLISTS_SQL_MOCK="$(make_mock_playlists_happy)"
export PUBLISH_PLAYLISTS_LOG="$PL_LOG"
export PUBLISH_LIVE_WINDOW_OK=1

out="$(run_publish_dry_4h)"; rc=$?

# Spec: at least 4 INSERT INTO Playlists (one per hour). Even though task spec
# says "16+", that count assumes multi-segment hours; our morning show emits
# 1 segment per hour (1 UID per hour, see existing publish.sh + investigation
# doc). Assert >=4 INSERT lines + 1 ScheduledLogs line.
__plcount=$(echo "$out" | grep -cE "INSERT INTO Playlists")
__slcount=$(echo "$out" | grep -cE "INSERT INTO ScheduledLogs|IF NOT EXISTS .*ScheduledLogs")

if (( rc != 0 )); then
    fail "Test 1: dry-run should succeed" "rc=$rc; out:\n$out"
elif (( __plcount < 4 )); then
    fail "Test 1: dry-run should print >=4 INSERT INTO Playlists lines" \
         "got $__plcount; out:\n$(echo "$out" | grep -E 'INSERT|GIndex' | head -20)"
elif (( __slcount < 1 )); then
    fail "Test 1: dry-run should print 1 ScheduledLogs INSERT" \
         "got $__slcount; out:\n$(echo "$out" | tail -20)"
elif [[ -s "$PL_LOG" ]]; then
    fail "Test 1: dry-run must NOT execute the playlists SQL mock" \
         "log:\n$(cat "$PL_LOG")"
else
    pass "Test 1: dry-run printed ${__plcount} Playlists INSERTs + ${__slcount} ScheduledLogs INSERT, no SQL executed"
fi

# ---------------------------------------------------------------------------
# Test 2: Mock SQL succeeds → publish completes + mutation log row written
# ---------------------------------------------------------------------------
echo "Test 2: happy path → publish completes + mutation log entries created"
PL_LOG="$TMPDIR_W35/t2-playlists.log"; : > "$PL_LOG"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_AUDIO_SQL"
export PUBLISH_PLAYLISTS_SQL_MOCK="$(make_mock_playlists_happy)"
export PUBLISH_PLAYLISTS_LOG="$PL_LOG"
export PUBLISH_LIVE_WINDOW_OK=1
export MUTATION_LOG_DIR="$TMPDIR_W35/mutations-t2"
mkdir -p "$MUTATION_LOG_DIR"

out="$(run_publish_real_4h)"; rc=$?

# Find today's mutation log file (UTC date stamp).
__ml_file=$(ls -1 "$MUTATION_LOG_DIR"/mutations-*.jsonl 2>/dev/null | head -1)
__ml_count=0
if [[ -n "$__ml_file" && -f "$__ml_file" ]]; then
    __ml_count=$(grep -cE '"target":"Playlists:GIndex=' "$__ml_file" 2>/dev/null || echo 0)
fi

if (( rc != 0 )); then
    fail "Test 2: publish should succeed" "rc=$rc; tail:\n$(echo "$out" | tail -30)"
elif ! grep -qE '^BEGIN' "$PL_LOG"; then
    fail "Test 2: BEGIN TRAN never issued" "log:\n$(cat "$PL_LOG")"
elif ! grep -qE '^COMMIT' "$PL_LOG"; then
    fail "Test 2: COMMIT TRAN never issued" "log:\n$(cat "$PL_LOG")"
elif ! grep -qE '^INSERT_PLAYLISTS ' "$PL_LOG"; then
    fail "Test 2: INSERT_PLAYLISTS not invoked" "log:\n$(cat "$PL_LOG")"
elif ! grep -qE '^INSERT_SCHEDULEDLOGS ' "$PL_LOG"; then
    fail "Test 2: INSERT_SCHEDULEDLOGS not invoked" "log:\n$(cat "$PL_LOG")"
elif (( __ml_count < 4 )); then
    fail "Test 2: expected >=4 Playlists mutation rows, found $__ml_count" \
         "log:\n$(cat "$__ml_file" 2>/dev/null | head -10)"
else
    pass "Test 2: publish committed (${__ml_count} Playlists mutation rows logged)"
fi

# ---------------------------------------------------------------------------
# Test 3: Mock SQL fails on row 3 → ROLLBACK fires, no leakage
# ---------------------------------------------------------------------------
echo "Test 3: SQL fails mid-transaction → ROLLBACK + abort"
PL_LOG="$TMPDIR_W35/t3-playlists.log"; : > "$PL_LOG"
PCNT="$TMPDIR_W35/t3-counter"; rm -f "$PCNT"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_AUDIO_SQL"
export PUBLISH_PLAYLISTS_SQL_MOCK="$(make_mock_playlists_fail_on_third)"
export PUBLISH_PLAYLISTS_LOG="$PL_LOG"
export PUBLISH_PLAYLISTS_COUNTER="$PCNT"
export PUBLISH_LIVE_WINDOW_OK=1
export MUTATION_LOG_DIR="$TMPDIR_W35/mutations-t3"
mkdir -p "$MUTATION_LOG_DIR"

out="$(run_publish_real_4h)"; rc=$?

if (( rc == 0 )); then
    fail "Test 3: publish must abort on mid-tran failure" "rc=0; tail:\n$(echo "$out" | tail -20)"
elif ! grep -qE '^BEGIN' "$PL_LOG"; then
    fail "Test 3: BEGIN TRAN must run before failure" "log:\n$(cat "$PL_LOG")"
elif ! grep -qE '^ROLLBACK' "$PL_LOG"; then
    fail "Test 3: ROLLBACK must be issued after failure" "log:\n$(cat "$PL_LOG")"
elif grep -qE '^COMMIT' "$PL_LOG"; then
    fail "Test 3: COMMIT must NOT run after failure" "log:\n$(cat "$PL_LOG")"
elif grep -qE 'INSERT_SCHEDULEDLOGS_SHOULD_NOT_RUN' "$PL_LOG"; then
    fail "Test 3: ScheduledLogs INSERT must be skipped after Playlists failure" \
         "log:\n$(cat "$PL_LOG")"
else
    pass "Test 3: publish aborted with ROLLBACK after row-3 failure (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 4: Verification mismatch → publish aborts with descriptive error
# ---------------------------------------------------------------------------
echo "Test 4: verification SELECT COUNT(*) mismatch → publish aborts"
PL_LOG="$TMPDIR_W35/t4-playlists.log"; : > "$PL_LOG"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_AUDIO_SQL"
export PUBLISH_PLAYLISTS_SQL_MOCK="$(make_mock_playlists_verify_mismatch)"
export PUBLISH_PLAYLISTS_LOG="$PL_LOG"
export PUBLISH_LIVE_WINDOW_OK=1
export MUTATION_LOG_DIR="$TMPDIR_W35/mutations-t4"
mkdir -p "$MUTATION_LOG_DIR"

out="$(run_publish_real_4h)"; rc=$?

if (( rc == 0 )); then
    fail "Test 4: publish must abort on verify mismatch" "rc=0; tail:\n$(echo "$out" | tail -20)"
elif ! echo "$out" | grep -qiE 'verif.*mismatch|mismatch.*verif|verification fail|drift'; then
    fail "Test 4: abort message must mention verification mismatch" \
         "out tail:\n$(echo "$out" | tail -20)"
else
    pass "Test 4: publish aborted on verification mismatch (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 5: Blast radius >50 → publish refuses
# ---------------------------------------------------------------------------
echo "Test 5: blast-radius > limit → publish refuses"
PL_LOG="$TMPDIR_W35/t5-playlists.log"; : > "$PL_LOG"
unset_publish_env
export PUBLISH_PREANALYZE_MOCK="$MOCK_PRE"
export PUBLISH_SQL_MOCK="$MOCK_AUDIO_SQL"
export PUBLISH_PLAYLISTS_SQL_MOCK="$(make_mock_playlists_happy)"
export PUBLISH_PLAYLISTS_LOG="$PL_LOG"
export PUBLISH_LIVE_WINDOW_OK=1
# Set the limit to 2 — a 4-hour show plans 5 rows (4 + 1 SL), so this trips.
export PUBLISH_BLAST_RADIUS_LIMIT=2

out="$(run_publish_real_4h)"; rc=$?

if (( rc == 0 )); then
    fail "Test 5: publish must refuse when blast-radius > limit" \
         "rc=0; tail:\n$(echo "$out" | tail -20)"
elif ! echo "$out" | grep -qiE 'blast.radius.*refuse|blast.radius.*limit|sanity guard|scope explosion|> limit'; then
    fail "Test 5: refusal message must mention blast-radius / limit" \
         "out tail:\n$(echo "$out" | tail -20)"
elif grep -qE '^BEGIN' "$PL_LOG"; then
    fail "Test 5: BEGIN TRAN must NOT run when blast-radius refuses" \
         "log:\n$(cat "$PL_LOG")"
else
    pass "Test 5: publish refused due to blast-radius (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 6: Regression — existing pre-analysis test suite still passes
# ---------------------------------------------------------------------------
echo "Test 6: regression — test-publish-preanalysis.sh still green"
REGRESSION="$SCRIPT_DIR/tests/test-publish-preanalysis.sh"
if [[ ! -x "$REGRESSION" ]]; then
    fail "Test 6: regression suite missing at $REGRESSION"
else
    if "$REGRESSION" >"$TMPDIR_W35/regression.out" 2>&1; then
        pass "Test 6: test-publish-preanalysis.sh PASSED post-edit"
    else
        fail "Test 6: regression suite FAILED — sql-direct broke pre-analysis tests" \
             "tail:\n$(tail -40 "$TMPDIR_W35/regression.out")"
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
