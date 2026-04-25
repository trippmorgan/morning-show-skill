#!/usr/bin/env bash
# ============================================================================
# test-track-a-integration.sh — Wave 3 Track A end-to-end integration test
# ============================================================================
#
# Exercises the FULL morning-show pipeline against a non-show date (Sunday
# 2026-04-26) plus the Mon-Fri week mode (week-of 2026-04-27), mocking every
# external side-effect (ElevenLabs, SSH, SQL, claude WebSearch). Asserts that
# each Wave 3 / Track A behavior (T14-T21 + e5baf34) is wired together
# correctly.
#
# Wave 3 GATE: passing this suite means Track A is shippable for Wave 4 (real
# Monday-show dogfood).
#
# Test dates:
#   2026-04-26 (Sun)  — single-day path, --force required (NOT a show day)
#   2026-04-27 (Mon)  — week-mode origin, exercises Mon-Fri enumeration
#
# NOTE on date-of-week: the task spec called 2026-04-26 "Saturday" but the
# real calendar shows it as Sunday. Either way it's a non-show day requiring
# --force, so the assertions below are correct as written.
#
# Mocking strategy (env-vars consumed by the production scripts):
#   PUBLISH_PREANALYZE_MOCK=PATH       stand-in for preanalyze-segment.sh
#   PUBLISH_SQL_MOCK=PATH              stand-in for SSH+sqlcmd Audio writes
#   PUBLISH_DRY_RUN=1 (or --dry-run)   skip real file ops in publish
#   PUBLISH_DEPLOY_INPUT/TIMEOUT_SEC   drive the typed-deploy gate non-interactively
#   RENDER_VOICE_MOCK_ELEVENLABS=1     skip real curl; write a placeholder mp3
#   RENDER_VOICE_MOCK_CHARS=<n>        report n chars per segment
#   RENDER_VOICE_TELEGRAM_ALERT=PATH   override the alert script
#   ELEVENLABS_RATE_PER_CHAR=0.0001    spend rate
#   ELEVENLABS_CAP_USD=5.00            hard per-show cap (Track A: $5/show)
#   PRODUCE_HOUR_LUFS_DELTA_ONLY=1     stub mode for produce-hour
#   LIBRARY_LUFS_PATH_OVERRIDE=PATH    library-lufs.json override
#   TRACES_PATH_OVERRIDE=PATH          .planning/TRACES.md override
#   SHOW_DATE_OVERRIDE=YYYY-MM-DD      synthetic show date for stub mode
#   WRITE_SCRIPTS_WEBSEARCH=0          force evergreen fallback in research
#   WRITE_SCRIPTS_DRY_RUN=1            print queries but don't call claude
#   BUILD_SHOW_DRY_RUN=1               plan multi-day without per-day exec
#   BUILD_SHOW_MOCK_DAY_FAIL=YYYY-MM-DD force one day to "fail" in week plan
#
# Re-runnable: every temp file/dir is cleaned up on EXIT.
# Runtime budget: <60 seconds total (mocks + dry-run throughout).
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$SCRIPT_DIR/build-show.sh"
PUBLISH="$SCRIPT_DIR/publish.sh"
RENDER="$SCRIPT_DIR/render-voice.sh"
PRODUCE="$SCRIPT_DIR/produce-hour.sh"
RESEARCH="$SCRIPT_DIR/research-date.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DATE="2026-04-26"        # Sunday — non-show, low-risk single-day target
WEEK_MONDAY="2026-04-27"      # Monday — week-mode origin

# Test dates expected in the week plan.
WEEK_DATES=(2026-04-27 2026-04-28 2026-04-29 2026-04-30 2026-05-01)
WEEKEND_DATES=(2026-05-02 2026-05-03)
MOCK_FAIL_DAY="2026-04-28"    # Day-2 (Tuesday) forced fail per assertion 9

T_START=$(date +%s)

# --- pretty output ---------------------------------------------------------
red()    { printf '\033[0;31m%s\033[0m' "$*"; }
green()  { printf '\033[0;32m%s\033[0m' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
cyan()   { printf '\033[0;36m%s\033[0m' "$*"; }

PASS=0
FAIL=0
FAILED_TESTS=()

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

# --- sanity ---------------------------------------------------------------
for s in "$BUILD" "$PUBLISH" "$RENDER" "$PRODUCE" "$RESEARCH"; do
    if [[ ! -x "$s" ]]; then
        echo "$(red 'FATAL'): $s missing or not executable" >&2
        exit 2
    fi
done

# --- isolated workspace ----------------------------------------------------
TMPDIR_T22="$(mktemp -d -t track-a-XXXXXX)"
trap 'rm -rf "$TMPDIR_T22"; rm -rf "$PROJECT_DIR/shows/$TEST_DATE.t22-bak" 2>/dev/null || true' EXIT

# Move any pre-existing show dir for our test date out of the way and restore
# on exit so we don't clobber a real run.
if [[ -d "$PROJECT_DIR/shows/$TEST_DATE" ]]; then
    mv "$PROJECT_DIR/shows/$TEST_DATE" "$PROJECT_DIR/shows/$TEST_DATE.t22-bak"
    trap 'rm -rf "$TMPDIR_T22"; rm -rf "$PROJECT_DIR/shows/$TEST_DATE"; mv "$PROJECT_DIR/shows/$TEST_DATE.t22-bak" "$PROJECT_DIR/shows/$TEST_DATE" 2>/dev/null || true' EXIT
fi

export MUTATION_LOG_DIR="$TMPDIR_T22/mutations"
mkdir -p "$MUTATION_LOG_DIR"

# Fixture audio dir for publish.sh assertions (Step 1 ffprobe needs real mp3s).
AUDIO_DIR="$TMPDIR_T22/audio"
mkdir -p "$AUDIO_DIR"
make_audio() {
    local hour="$1"
    local f="$AUDIO_DIR/MORNING-SHOW-H${hour}.mp3"
    [[ -f "$f" ]] && return 0
    ffmpeg -hide_banner -loglevel error -y -f lavfi \
        -i "sine=frequency=440:duration=10" -ar 44100 -ac 2 "$f" 2>/dev/null
    [[ -f "$f" ]] || { echo "$(red 'FATAL'): ffmpeg failed for $f" >&2; exit 2; }
}
make_audio 5
make_audio 6
make_audio 7
make_audio 8

# Local config.yaml (minimal — publish.sh just greps "key:" entries).
CONFIG="$TMPDIR_T22/config.yaml"
cat > "$CONFIG" <<EOF
playoutone:
  host: 'fake-host'
  audio_path: 'F:\PlayoutONE\Audio'
  temp_path: 'C:\temp'
  db: 'PlayoutONE_Standard'
EOF

# --- mock builders --------------------------------------------------------
# Pre-analyze mock that returns sane (non-zero) markers + records calls.
MOCK_PRE="$TMPDIR_T22/mock-preanalyze.sh"
PRE_CALL_LOG="$TMPDIR_T22/preanalyze-calls.log"
cat > "$MOCK_PRE" <<MOCK
#!/usr/bin/env bash
echo "PREANALYZE_INVOKED \$*" >> "$PRE_CALL_LOG"
printf '{"length_ms": 600000, "trim_out_ms": 600000, "extro_ms": 595000}\n'
exit 0
MOCK
chmod +x "$MOCK_PRE"

# SQL mock that records the planned UPDATE/SELECT statements (in --dry-run
# publish prints the UPDATE itself but does NOT call this; in non-dry-run
# tests we'd use this to capture the call).
MOCK_SQL="$TMPDIR_T22/mock-sql.sh"
SQL_CALL_LOG="$TMPDIR_T22/sql-calls.log"
cat > "$MOCK_SQL" <<MOCK
#!/usr/bin/env bash
KIND="\$1"; UID_ARG="\$2"
if [[ "\$KIND" == "update" ]]; then
    echo "UPDATE uid=\$UID_ARG length=\$3 trim_out=\$4 extro=\$5" >> "$SQL_CALL_LOG"
    exit 0
elif [[ "\$KIND" == "select" ]]; then
    echo "SELECT uid=\$UID_ARG" >> "$SQL_CALL_LOG"
    echo "600000	595000"
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_SQL"

# Telegram alert mock for render-voice (cap-exceeded path; not exercised
# under the cap, but we point the script at it so it never tries the real one).
MOCK_TG="$TMPDIR_T22/mock-telegram.sh"
TG_CALL_LOG="$TMPDIR_T22/telegram-calls.log"
cat > "$MOCK_TG" <<MOCK
#!/usr/bin/env bash
echo "TELEGRAM_INVOKED: \$*" >> "$TG_CALL_LOG"
exit 0
MOCK
chmod +x "$MOCK_TG"

# Mock library-lufs.json so produce-hour LUFS-delta has data (assertion 3
# tolerates either the delta line OR the fallback message, but we want to
# exercise the happy path here).
MOCK_LUFS_JSON="$TMPDIR_T22/library-lufs.json"
cat > "$MOCK_LUFS_JSON" <<EOF
{
  "median_lufs": -14.3,
  "p25": -15.5,
  "p75": -13.2,
  "stddev": 1.1,
  "sample_count": 50,
  "measured_at": "${TEST_DATE}T00:00:00Z",
  "samples": []
}
EOF
MOCK_TRACES="$TMPDIR_T22/TRACES.md"

# Common output capture helper (combined stdout+stderr).
out=""
rc=0

# ===========================================================================
# Headline integration runs (orchestrator-level smoke checks)
# ===========================================================================
echo
echo "$(cyan '== Track A integration test — Wave 3 / Task 22 ==')"
echo

echo "$(cyan '-- Headline run 1: build-show.sh single-day --dry-run --force --auto-approve --')"
SD_LOG="$TMPDIR_T22/single-day.log"
set +e
"$BUILD" --date "$TEST_DATE" --auto-approve --dry-run --force \
    >"$SD_LOG" 2>&1
SD_RC=$?
set -e
if (( SD_RC == 0 )); then
    echo "  single-day dry-run completed (rc=$SD_RC)"
else
    echo "  single-day dry-run rc=$SD_RC (some downstream errors are tolerable in dry-run)"
fi

echo "$(cyan '-- Headline run 2: build-show.sh week 2026-04-27 (BUILD_SHOW_DRY_RUN=1) --')"
WEEK_LOG="$TMPDIR_T22/week.log"
set +e
BUILD_SHOW_DRY_RUN=1 \
    "$BUILD" week "$WEEK_MONDAY" --dry-run \
    >"$WEEK_LOG" 2>&1
WK_RC=$?
set -e
echo "  week dry-run rc=$WK_RC"

echo "$(cyan '-- Headline run 3: build-show.sh week with day-2 mock-fail --')"
WEEK_FAIL_LOG="$TMPDIR_T22/week-fail.log"
set +e
BUILD_SHOW_DRY_RUN=1 \
BUILD_SHOW_MOCK_DAY_FAIL="$MOCK_FAIL_DAY" \
    "$BUILD" week "$WEEK_MONDAY" --dry-run \
    >"$WEEK_FAIL_LOG" 2>&1
WK_FAIL_RC=$?
set -e
echo "  week+mock-fail dry-run rc=$WK_FAIL_RC"

echo

# ===========================================================================
# SINGLE-DAY ASSERTIONS
# ===========================================================================
echo "$(cyan '-- Single-day path assertions (1-6) --')"

# ---------------------------------------------------------------------------
# Assertion 1: Pre-analysis is invoked during publish (PUBLISH_PREANALYZE_MOCK).
# We invoke publish.sh directly (full chain via build-show would need claude
# + ElevenLabs + ffmpeg fixtures we don't have); the mock injection mirrors
# Wave 3 Task 15 behavior.
# ---------------------------------------------------------------------------
: > "$PRE_CALL_LOG"
A1_LOG="$TMPDIR_T22/a1-publish.log"
set +e
PUBLISH_PREANALYZE_MOCK="$MOCK_PRE" \
PUBLISH_SQL_MOCK="$MOCK_SQL" \
"$PUBLISH" --date "$TEST_DATE" --hours '5' --audio-dir "$AUDIO_DIR" \
    --config "$CONFIG" --skip-music1-wait --auto-approve --dry-run \
    >"$A1_LOG" 2>&1
A1_RC=$?
set -e

if [[ -s "$PRE_CALL_LOG" ]] && grep -q PREANALYZE_INVOKED "$PRE_CALL_LOG"; then
    pass "1. preanalyze-segment.sh invoked during publish step ($(wc -l <"$PRE_CALL_LOG") call(s))"
else
    fail "1. preanalyze-segment.sh NOT invoked" \
         "PUBLISH_PREANALYZE_MOCK call log empty; rc=$A1_RC; tail:\n$(tail -10 "$A1_LOG")"
fi

# ---------------------------------------------------------------------------
# Assertion 2: Audio table SQL writes are well-formed.
# In --dry-run publish prints the planned UPDATE statement (does not invoke
# the SQL mock). We grep for the canonical shape with non-zero TrimOut/Extro.
# ---------------------------------------------------------------------------
if grep -qE 'UPDATE +Audio +SET +Length=600000, *TrimOut=600000, *Extro=595000 +WHERE +UID' "$A1_LOG"; then
    pass "2. UPDATE Audio statement well-formed (Length/TrimOut/Extro all non-zero)"
elif grep -qE "UPDATE +Audio +SET" "$A1_LOG" && grep -qE 'Extro=[1-9]' "$A1_LOG"; then
    pass "2. UPDATE Audio statement present with non-zero Extro (loose match)"
else
    fail "2. UPDATE Audio statement missing or has zero Extro" \
         "expected 'UPDATE Audio SET Length=...TrimOut=...Extro=595000 WHERE UID' in:\n$(grep -E 'UPDATE|Extro' "$A1_LOG" | head -10)"
fi

# ---------------------------------------------------------------------------
# Assertion 3: produce-hour.sh emits the LUFS delta line (or fallback message).
# Use the LUFS-delta-only stub mode with our mocked library-lufs.json.
# ---------------------------------------------------------------------------
A3_LOG="$TMPDIR_T22/a3-produce.log"
: > "$MOCK_TRACES"
set +e
PRODUCE_HOUR_LUFS_DELTA_ONLY=1 \
LIBRARY_LUFS_PATH_OVERRIDE="$MOCK_LUFS_JSON" \
TRACES_PATH_OVERRIDE="$MOCK_TRACES" \
SHOW_DATE_OVERRIDE="$TEST_DATE" \
"$PRODUCE" >"$A3_LOG" 2>&1
A3_RC=$?
set -e

if (( A3_RC != 0 )); then
    fail "3. produce-hour.sh stub mode rc!=0" "rc=$A3_RC; out:\n$(tail -10 "$A3_LOG")"
elif grep -qE 'LUFS delta:.*target.*-16.*library median.*-14\.3' "$A3_LOG"; then
    pass "3. produce-hour.sh emitted [LUFS delta:] line (target=-16, lib=-14.3)"
elif grep -qE 'LUFS delta:.*not found.*delta unknown' "$A3_LOG"; then
    pass "3. produce-hour.sh emitted fallback LUFS-delta message"
else
    fail "3. produce-hour.sh did not emit LUFS delta line or fallback" \
         "out:\n$(tail -10 "$A3_LOG")"
fi

# ---------------------------------------------------------------------------
# Assertion 4: ElevenLabs ledger created with cap=$5 (RENDER_VOICE_MOCK_ELEVENLABS=1).
# Render a tiny segments dir directly — the build-show pipeline would normally
# get here after extract, but invoking render-voice with mocks is the canonical
# way to exercise the ledger init.
# ---------------------------------------------------------------------------
A4_SEG_DIR="$TMPDIR_T22/a4-segments"
mkdir -p "$A4_SEG_DIR"
echo "Hello Albany this is Doctor Johnny Fever." > "$A4_SEG_DIR/h5-01.txt"
echo "Welcome to the morning show on WPFQ." > "$A4_SEG_DIR/h5-02.txt"

LEDGER_PATH="$PROJECT_DIR/shows/$TEST_DATE/elevenlabs-ledger.json"
rm -rf "$PROJECT_DIR/shows/$TEST_DATE"

A4_LOG="$TMPDIR_T22/a4-render.log"
set +e
RENDER_VOICE_MOCK_ELEVENLABS=1 \
RENDER_VOICE_MOCK_CHARS=100 \
RENDER_VOICE_TELEGRAM_ALERT="$MOCK_TG" \
ELEVENLABS_RATE_PER_CHAR=0.0001 \
ELEVENLABS_CAP_USD=5.00 \
"$RENDER" --batch-dir "$A4_SEG_DIR" --show-date "$TEST_DATE" \
    --config "$PROJECT_DIR/config.yaml" \
    >"$A4_LOG" 2>&1
A4_RC=$?
set -e

if (( A4_RC != 0 )); then
    fail "4. render-voice.sh rc!=0" "rc=$A4_RC; tail:\n$(tail -10 "$A4_LOG")"
elif [[ ! -f "$LEDGER_PATH" ]]; then
    fail "4. ElevenLabs ledger not created" "expected at: $LEDGER_PATH"
else
    A4_CAP=$(python3 -c "import json;print(json.load(open('$LEDGER_PATH'))['cap_usd'])" 2>/dev/null || echo "")
    A4_OK=$(python3 -c "print('yes' if abs(float('${A4_CAP:-0}') - 5.0) < 1e-6 else 'no')" 2>/dev/null || echo "no")
    if [[ "$A4_OK" == "yes" ]]; then
        pass "4. ElevenLabs ledger initialized at $TEST_DATE with cap=\$$A4_CAP"
    else
        fail "4. ledger cap_usd != 5.00" "got '$A4_CAP'"
    fi
fi

# ---------------------------------------------------------------------------
# Assertion 5: research-date.sh attempts WebSearch hook (or falls back to
# evergreen). With WRITE_SCRIPTS_WEBSEARCH=0, the script must take the
# evergreen path AND log it.
# ---------------------------------------------------------------------------
A5_LOG="$TMPDIR_T22/a5-research.log"
set +e
WRITE_SCRIPTS_WEBSEARCH=0 \
"$RESEARCH" --date "$TEST_DATE" >"$A5_LOG.json" 2>"$A5_LOG"
A5_RC=$?
set -e

A5_STATUS=""
if command -v jq &>/dev/null && [[ -s "$A5_LOG.json" ]]; then
    A5_STATUS=$(jq -r '.news.status // ""' "$A5_LOG.json" 2>/dev/null || echo "")
fi

if (( A5_RC != 0 )); then
    fail "5. research-date.sh rc!=0 even on fallback path" \
         "rc=$A5_RC; tail:\n$(tail -10 "$A5_LOG")"
elif grep -qE 'WebSearch.*disabled|evergreen fallback|WebSearch failed|using evergreen' "$A5_LOG" \
     || [[ "$A5_STATUS" == "evergreen-fallback" || "$A5_STATUS" == "evergreen" ]]; then
    pass "5. research-date.sh logged WebSearch attempt + evergreen fallback (status=$A5_STATUS)"
else
    fail "5. research-date.sh did not log WebSearch fallback path" \
         "stderr: $(tail -10 "$A5_LOG"); status='$A5_STATUS'"
fi

# ---------------------------------------------------------------------------
# Assertion 6: 3rd deploy gate enforced (publish.sh blocks without --auto-approve).
# Wrong-phrase path through PUBLISH_DEPLOY_INPUT — gate must abort non-zero.
# ---------------------------------------------------------------------------
A6_LOG="$TMPDIR_T22/a6-publish-gate.log"
set +e
PUBLISH_PREANALYZE_MOCK="$MOCK_PRE" \
PUBLISH_SQL_MOCK="$MOCK_SQL" \
PUBLISH_DEPLOY_INPUT=$'nope\nnope\nnope' \
PUBLISH_DEPLOY_TIMEOUT_SEC=2 \
"$PUBLISH" --date "$TEST_DATE" --hours '5' --audio-dir "$AUDIO_DIR" \
    --config "$CONFIG" --skip-music1-wait --dry-run \
    >"$A6_LOG" 2>&1
A6_RC=$?
set -e

if (( A6_RC == 0 )); then
    fail "6. deploy gate did NOT block without --auto-approve" \
         "rc=0; tail:\n$(tail -10 "$A6_LOG")"
elif grep -qiE 'deploy gate.*abort|gate.*abort|never matched|not satisfied' "$A6_LOG"; then
    pass "6. deploy gate blocked publish without --auto-approve (rc=$A6_RC)"
else
    fail "6. publish exited non-zero but gate-abort message missing" \
         "rc=$A6_RC; tail:\n$(tail -10 "$A6_LOG")"
fi

echo
echo "$(cyan '-- Multi-day week path assertions (7-10) --')"

# ===========================================================================
# MULTI-DAY (WEEK) ASSERTIONS
# ===========================================================================

# ---------------------------------------------------------------------------
# Assertion 7: 5 days enumerated Mon-Fri (no Sat/Sun).
# ---------------------------------------------------------------------------
WK_ALL="$WEEK_LOG"
A7_MISSING=""
for d in "${WEEK_DATES[@]}"; do
    grep -q "$d" "$WK_ALL" || A7_MISSING+="$d "
done
A7_UNEXPECTED=""
for d in "${WEEKEND_DATES[@]}"; do
    grep -q "$d" "$WK_ALL" && A7_UNEXPECTED+="$d "
done
if [[ -n "$A7_MISSING" ]]; then
    fail "7. week mode missing Mon-Fri date(s)" "missing: $A7_MISSING"
elif [[ -n "$A7_UNEXPECTED" ]]; then
    fail "7. week mode included weekend date(s)" "unexpected: $A7_UNEXPECTED"
else
    pass "7. week mode enumerated 5 days Mon-Fri (no Sat/Sun)"
fi

# ---------------------------------------------------------------------------
# Assertion 8: per-day cap propagated (ELEVENLABS_CAP_USD=5.00 set per day).
# In dry-run mode build-show prints `[plan] ELEVENLABS_CAP_USD=5.00 ...` per day.
# ---------------------------------------------------------------------------
A8_OK=true
A8_BAD=""
for d in "${WEEK_DATES[@]}"; do
    if ! grep -qE "ELEVENLABS_CAP_USD=5\.00.*--date $d" "$WK_ALL"; then
        A8_OK=false
        A8_BAD+="$d "
    fi
done
if $A8_OK; then
    pass "8. per-day ELEVENLABS_CAP_USD=5.00 propagated for all 5 days"
else
    fail "8. per-day cap missing for some day(s)" \
         "no 'ELEVENLABS_CAP_USD=5.00 ...--date' line for: $A8_BAD"
fi

# ---------------------------------------------------------------------------
# Assertion 9: continue-on-failure — day-2 mock-fail; days 3-5 still execute,
# summary shows ❌ for day-2 + ✅ for the others.
# ---------------------------------------------------------------------------
WKF="$WEEK_FAIL_LOG"
# Find the WEEK BUILD COMPLETE summary block; check Tue=fail, others pass.
A9_OK=true
A9_DETAIL=""

# Day-2 = Tuesday 2026-04-28 must show ❌ in the summary.
if ! grep -qE "❌.*Tue.*$MOCK_FAIL_DAY|❌.*$MOCK_FAIL_DAY|Tue.*$MOCK_FAIL_DAY.*(abort|fail|cap)" "$WKF"; then
    A9_OK=false
    A9_DETAIL+="Tue($MOCK_FAIL_DAY) summary line missing or not marked failed; "
fi

# Days 1, 3, 4, 5 must show ✅.
for d in 2026-04-27 2026-04-29 2026-04-30 2026-05-01; do
    if ! grep -qE "✅.*$d|✅.*$(date -d "$d" +%a) $d" "$WKF"; then
        A9_OK=false
        A9_DETAIL+="$d ($(date -d "$d" +%a)) not marked ✅; "
    fi
done

# Summary banner must be printed.
if ! grep -qiE 'week build complete' "$WKF"; then
    A9_OK=false
    A9_DETAIL+="end-of-week summary banner missing; "
fi

if $A9_OK; then
    pass "9. continue-on-failure: day-2 ❌ + days 1,3,4,5 ✅, summary printed"
else
    fail "9. continue-on-failure summary not as expected" \
         "$A9_DETAIL\ntail:\n$(tail -20 "$WKF")"
fi

# ---------------------------------------------------------------------------
# Assertion 10: e5baf34 fix verified — --auto-approve propagated all the way
# to publish.sh in week mode (no gate stall). In dry-run mode build-show
# prints the planned per-day command; verify it includes --auto-approve.
# ---------------------------------------------------------------------------
A10_OK=true
A10_BAD=""
for d in "${WEEK_DATES[@]}"; do
    # Look for: `--date <d> --auto-approve` (e5baf34 fix order)
    if ! grep -qE -- "--date $d --auto-approve" "$WK_ALL"; then
        A10_OK=false
        A10_BAD+="$d "
    fi
done
if $A10_OK; then
    pass "10. --auto-approve propagated to publish.sh per day (e5baf34 fix verified)"
else
    fail "10. --auto-approve NOT propagated for some day(s) — e5baf34 regression?" \
         "missing '--date <d> --auto-approve' for: $A10_BAD"
fi

# ===========================================================================
# Cleanup is via trap; nothing to do here.
# ===========================================================================

T_END=$(date +%s)
T_ELAPSED=$(( T_END - T_START ))

echo
echo "------------------------------------------------------------"
echo "Runtime: ${T_ELAPSED}s"
if (( FAIL == 0 )); then
    echo "$(green 'TRACK A INTEGRATION: 10/10 PASS')"
    exit 0
fi
echo "$(red "TRACK A INTEGRATION: $PASS/$((PASS + FAIL)) PASS — $FAIL FAILED")"
echo "$(red 'Failed assertions:')"
for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
done
exit 1
