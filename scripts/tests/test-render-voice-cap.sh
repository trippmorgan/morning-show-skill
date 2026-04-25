#!/usr/bin/env bash
# Tests for render-voice.sh — Wave 3 Task 18
# $5/show ElevenLabs spend cap with persisted ledger.
#
# Tests:
#   1. 5 segments at $0.50 each → completes; ledger total=$2.50; status=completed
#   2. 7 segments at $0.85 each (=$5.95) → aborts at segment 6; status=aborted_cap_exceeded
#   3. cap exceeded → Telegram alert script invoked (mock the actual send)
#   4. ledger persists after abort (forensic audit retrievable)
#
# Mocking strategy (env-var injection):
#   RENDER_VOICE_MOCK_ELEVENLABS=1   - skip real curl; write a fake mp3 file
#   RENDER_VOICE_MOCK_CHARS=<n>      - report this many "characters" per segment
#   RENDER_VOICE_TELEGRAM_ALERT=<f>  - override path to telegram alert script
#   ELEVENLABS_RATE_PER_CHAR=<f>     - per-char cost
#   ELEVENLABS_CAP_USD=<f>           - hard cap

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$SCRIPT_DIR/render-voice.sh"

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

# JSON helpers (use python3 — already a dependency of render-voice.sh)
json_get() {
    local file="$1" key="$2"
    python3 -c "import json,sys;print(json.load(open('$file')).get('$key',''))"
}

json_segments_len() {
    local file="$1"
    python3 -c "import json,sys;print(len(json.load(open('$file')).get('segments',[])))"
}

# Sanity check
if [[ ! -x "$RENDER" ]]; then
    echo "$(red 'FATAL'): $RENDER is not executable or does not exist" >&2
    exit 2
fi

# Common test rig --------------------------------------------------------------
make_segments_dir() {
    # $1 = number of segments, $2 = chars per segment
    local n="$1" chars="$2"
    local dir
    dir="$(mktemp -d /tmp/render-voice-test-XXXXXX)"
    local body
    body="$(python3 -c "print('x' * $chars)")"
    for i in $(seq 1 "$n"); do
        # zero-padded id so glob ordering is stable
        local idx
        idx=$(printf '%02d' "$i")
        echo "$body" > "${dir}/h5-segment-${idx}.txt"
    done
    echo "$dir"
}

make_telegram_mock() {
    # Creates a mock script that records its invocations to a log file.
    local log="$1"
    local mock
    mock="$(mktemp /tmp/render-voice-mock-telegram-XXXXXX.sh)"
    cat > "$mock" <<EOF
#!/usr/bin/env bash
echo "MOCK_TELEGRAM_CALLED: \$*" >> "$log"
exit 0
EOF
    chmod +x "$mock"
    echo "$mock"
}

# Test 1: 5 segments × $0.50 = $2.50, completes ---------------------------------
echo "Test 1: 5 segments at \$0.50 each → completes (total \$2.50)"
SHOW_DATE_1="2099-01-01"
SHOW_DIR_1="$SCRIPT_DIR/../shows/${SHOW_DATE_1}"
LEDGER_1="${SHOW_DIR_1}/elevenlabs-ledger.json"
rm -rf "$SHOW_DIR_1"
SEG_DIR_1="$(make_segments_dir 5 5000)"   # 5000 chars * 0.0001 = $0.50
TG_LOG_1="$(mktemp /tmp/tg-log-1-XXXXXX.log)"
TG_MOCK_1="$(make_telegram_mock "$TG_LOG_1")"

set +e
RENDER_VOICE_MOCK_ELEVENLABS=1 \
RENDER_VOICE_MOCK_CHARS=5000 \
RENDER_VOICE_TELEGRAM_ALERT="$TG_MOCK_1" \
ELEVENLABS_RATE_PER_CHAR=0.0001 \
ELEVENLABS_CAP_USD=5.00 \
"$RENDER" --batch-dir "$SEG_DIR_1" --show-date "$SHOW_DATE_1" >/tmp/test1.out 2>/tmp/test1.err
RC1=$?
set -e

if (( RC1 != 0 )); then
    fail "Test 1: exit 0" "rc=$RC1, stderr=$(tail -5 /tmp/test1.err)"
elif [[ ! -f "$LEDGER_1" ]]; then
    fail "Test 1: ledger created at $LEDGER_1" "missing"
else
    STATUS_1=$(json_get "$LEDGER_1" status)
    TOTAL_1=$(json_get "$LEDGER_1" total_cost_usd)
    SEGS_1=$(json_segments_len "$LEDGER_1")
    # compare floats with python
    OK_TOTAL=$(python3 -c "print('yes' if abs(float('$TOTAL_1') - 2.50) < 1e-6 else 'no')")
    if [[ "$STATUS_1" != "completed" ]]; then
        fail "Test 1: status=completed" "got '$STATUS_1'"
    elif [[ "$OK_TOTAL" != "yes" ]]; then
        fail "Test 1: total_cost_usd=2.50" "got '$TOTAL_1'"
    elif [[ "$SEGS_1" != "5" ]]; then
        fail "Test 1: 5 segments logged" "got $SEGS_1"
    elif [[ -s "$TG_LOG_1" ]]; then
        fail "Test 1: no Telegram alert sent (under cap)" "log: $(cat "$TG_LOG_1")"
    else
        pass "Test 1: 5 segs total=\$$TOTAL_1 status=$STATUS_1"
    fi
fi

# Test 2: 7 segments × $0.85 = $5.95, aborts at segment 6 -----------------------
echo "Test 2: 7 segments at \$0.85 each → aborts at segment 6"
SHOW_DATE_2="2099-01-02"
SHOW_DIR_2="$SCRIPT_DIR/../shows/${SHOW_DATE_2}"
LEDGER_2="${SHOW_DIR_2}/elevenlabs-ledger.json"
rm -rf "$SHOW_DIR_2"
SEG_DIR_2="$(make_segments_dir 7 8500)"   # 8500 * 0.0001 = $0.85
TG_LOG_2="$(mktemp /tmp/tg-log-2-XXXXXX.log)"
TG_MOCK_2="$(make_telegram_mock "$TG_LOG_2")"

set +e
RENDER_VOICE_MOCK_ELEVENLABS=1 \
RENDER_VOICE_MOCK_CHARS=8500 \
RENDER_VOICE_TELEGRAM_ALERT="$TG_MOCK_2" \
ELEVENLABS_RATE_PER_CHAR=0.0001 \
ELEVENLABS_CAP_USD=5.00 \
"$RENDER" --batch-dir "$SEG_DIR_2" --show-date "$SHOW_DATE_2" >/tmp/test2.out 2>/tmp/test2.err
RC2=$?
set -e

if (( RC2 == 0 )); then
    fail "Test 2: must exit non-zero on cap exceeded" "rc=0"
elif [[ ! -f "$LEDGER_2" ]]; then
    fail "Test 2: ledger created at $LEDGER_2" "missing"
else
    STATUS_2=$(json_get "$LEDGER_2" status)
    SEGS_2=$(json_segments_len "$LEDGER_2")
    TOTAL_2=$(json_get "$LEDGER_2" total_cost_usd)
    # Cap is 5.00; each segment is 0.85.
    # After 5 segments: total = 4.25. Adding a 6th would push to 5.10 > 5.00 → abort BEFORE the 6th call.
    # So ledger should contain exactly 5 segments and total 4.25.
    OK_TOTAL=$(python3 -c "print('yes' if abs(float('$TOTAL_2') - 4.25) < 1e-6 else 'no')")
    if [[ "$STATUS_2" != "aborted_cap_exceeded" ]]; then
        fail "Test 2: status=aborted_cap_exceeded" "got '$STATUS_2'"
    elif [[ "$SEGS_2" != "5" ]]; then
        fail "Test 2: 5 segments logged before abort (6th would breach cap)" "got $SEGS_2"
    elif [[ "$OK_TOTAL" != "yes" ]]; then
        fail "Test 2: total_cost_usd=4.25" "got '$TOTAL_2'"
    else
        pass "Test 2: aborted with 5 segs (total=\$$TOTAL_2) status=$STATUS_2 rc=$RC2"
    fi
fi

# Test 3: cap exceeded → Telegram alert script invoked --------------------------
echo "Test 3: cap exceeded → Telegram alert mock invoked"
if [[ -s "$TG_LOG_2" ]]; then
    pass "Test 3: Telegram mock invoked: $(head -1 "$TG_LOG_2" | cut -c1-80)..."
else
    fail "Test 3: Telegram mock should have been invoked" "log empty: $TG_LOG_2"
fi

# Test 4: ledger persists after abort (forensic audit) --------------------------
echo "Test 4: ledger persists after abort"
if [[ -f "$LEDGER_2" ]]; then
    # Re-read it, confirm key fields persist and are valid JSON.
    if python3 -c "import json; d=json.load(open('$LEDGER_2')); assert 'segments' in d and 'total_cost_usd' in d and 'status' in d and 'rate_per_char' in d and 'cap_usd' in d and 'show_date' in d" 2>/tmp/test4.err; then
        pass "Test 4: ledger persisted with all required fields"
    else
        fail "Test 4: ledger missing required fields" "$(cat /tmp/test4.err)"
    fi
else
    fail "Test 4: ledger file missing after abort" "$LEDGER_2"
fi

# Cleanup ----------------------------------------------------------------------
rm -rf "$SHOW_DIR_1" "$SHOW_DIR_2" "$SEG_DIR_1" "$SEG_DIR_2"
rm -f "$TG_LOG_1" "$TG_LOG_2" "$TG_MOCK_1" "$TG_MOCK_2"
rm -f /tmp/test1.out /tmp/test1.err /tmp/test2.out /tmp/test2.err /tmp/test4.err

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
