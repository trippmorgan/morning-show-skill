#!/usr/bin/env bash
# measure-library-lufs.sh — Wave 3 Task 16
#
# Sample N random Type=16 song UIDs from the PlayoutONE Audio table, download
# each via SCP, measure integrated LUFS with `ffmpeg ebur128`, compute median +
# percentiles, and cache the result to JSON for delta tracking.
#
# Per Phase 0 Q2.2=c: production normalization stays at -16 LUFS for v1; this
# script just measures the library distribution as a reference.
#
# Environment overrides (mostly for tests):
#   MEASURE_LUFS_DRY_RUN=1     Print SQL + sample count, exit without executing.
#   MEASURE_LUFS_MOCK=<csv>    Skip SQL/SCP/ffmpeg; use these LUFS values.
#                              e.g. "-14.0,-15.5,-13.2,-16.1,-14.8"
#   MEASURE_LUFS_MOCK_EMPTY=1  Force the "0 samples" error path (with empty MOCK).
#   MEASURE_LUFS_OUTPUT=<path> Override JSON output location.
#   MEASURE_LUFS_SAMPLE_COUNT=<n>  Override sample count (default 50).
#
# Cron: monthly at 03:00 on the 1st (see CRON_LINE printed at end).

set -euo pipefail

# --- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MORNING_SHOW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_OUTPUT="$MORNING_SHOW_DIR/references/library-lufs.json"
OUTPUT_PATH="${MEASURE_LUFS_OUTPUT:-$DEFAULT_OUTPUT}"
SAMPLE_COUNT="${MEASURE_LUFS_SAMPLE_COUNT:-50}"

# --- Logging ---------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()   { echo -e "${CYAN}[measure-library-lufs]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[measure-library-lufs]${RESET} $*" >&2; }
error() { echo -e "${RED}[measure-library-lufs]${RESET} $*" >&2; }
ok()    { echo -e "${GREEN}[measure-library-lufs]${RESET} $*" >&2; }

# --- SQL query (PLAYBOOK pattern) ------------------------------------------
SQL_QUERY="SELECT TOP ${SAMPLE_COUNT} UID, Filename FROM Audio WHERE Type=16 AND Filename IS NOT NULL ORDER BY NEWID()"

# --- SSH routing -----------------------------------------------------------
SSH_PROXY="super"
SSH_HOST="p1-wpfq-srvs"
REMOTE_AUDIO_DIR='F:\\PlayoutONE\\Audio'

# --- Dry run ---------------------------------------------------------------
if [[ "${MEASURE_LUFS_DRY_RUN:-0}" == "1" ]]; then
    log "DRY RUN — no SQL, no downloads, no ffmpeg."
    log "SQL query that would be executed against PlayoutONE_Standard:"
    echo "$SQL_QUERY" >&2
    log "sample_count=${SAMPLE_COUNT}"
    log "output_path=${OUTPUT_PATH}"
    exit 0
fi

# --- Sample collection -----------------------------------------------------
# Each sample is "uid|lufs" on its own line.
SAMPLES_FILE="$(mktemp /tmp/lufs-samples-XXXX.txt)"
TMPDIR_AUDIO="$(mktemp -d /tmp/lufs-audio-XXXX)"
cleanup() {
    rm -f "$SAMPLES_FILE"
    rm -rf "$TMPDIR_AUDIO"
}
trap cleanup EXIT

if [[ -n "${MEASURE_LUFS_MOCK:-}" ]]; then
    log "MOCK mode — using provided LUFS values, skipping SQL/SCP/ffmpeg."
    IFS=',' read -ra MOCK_VALS <<<"$MEASURE_LUFS_MOCK"
    idx=1000
    for v in "${MOCK_VALS[@]}"; do
        v="$(echo "$v" | xargs)"
        [[ -z "$v" ]] && continue
        printf '%d|%s\n' "$idx" "$v" >>"$SAMPLES_FILE"
        idx=$((idx + 1))
    done
elif [[ "${MEASURE_LUFS_MOCK_EMPTY:-0}" == "1" ]]; then
    log "MOCK_EMPTY mode — forcing zero-samples path."
    : >"$SAMPLES_FILE"
else
    # --- Real path: query SQL, download via SCP, measure ----------------
    log "Querying ${SSH_PROXY} -> ${SSH_HOST} for ${SAMPLE_COUNT} random Type=16 UIDs..."
    SQL_LOCAL="$(mktemp /tmp/lufs-q-XXXX.sql)"
    printf '%s\n' "$SQL_QUERY" >"$SQL_LOCAL"

    # Pattern from pull-songs.sh: superhost -> station, sqlcmd reads file.
    if ! scp -q "$SQL_LOCAL" "${SSH_PROXY}:/tmp/lufs-q.sql"; then
        error "Failed to scp SQL to ${SSH_PROXY}"
        rm -f "$SQL_LOCAL"
        exit 2
    fi
    rm -f "$SQL_LOCAL"

    QUERY_RESULTS="$(ssh "$SSH_PROXY" 'scp -q /tmp/lufs-q.sql p1-wpfq-srvs:C:/temp/lufs-q.sql && ssh p1-wpfq-srvs "sqlcmd -S localhost -d PlayoutONE_Standard -E -W -h -1 -s \"|\" -i C:\temp\lufs-q.sql"' || true)"

    if [[ -z "$QUERY_RESULTS" ]]; then
        error "SQL returned no rows."
        : >"$SAMPLES_FILE"
    else
        # Each line: UID|Filename  (skip blanks, sqlcmd footer like "(N rows affected)")
        while IFS='|' read -r uid filename; do
            uid="$(echo "$uid" | xargs)"
            filename="$(echo "$filename" | xargs)"
            [[ -z "$uid" ]] && continue
            [[ "$uid" =~ ^[0-9]+$ ]] || continue

            # Strip extension if Filename includes one
            stem="${filename%.*}"
            [[ -z "$stem" ]] && stem="$uid"

            local_path=""
            for ext in mp3 wav; do
                remote_file="${REMOTE_AUDIO_DIR}\\${stem}.${ext}"
                lp="${TMPDIR_AUDIO}/${stem}.${ext}"
                if ssh "$SSH_PROXY" "ssh ${SSH_HOST} \"type '${remote_file}'\"" >"$lp" 2>/dev/null; then
                    if [[ -s "$lp" ]]; then
                        local_path="$lp"
                        break
                    fi
                    rm -f "$lp"
                fi
            done

            if [[ -z "$local_path" ]]; then
                warn "Skipping UID ${uid}: failed to download ${stem}.{mp3,wav}"
                continue
            fi

            # Integrated LUFS — last "I:" line in ebur128 verbose is the final integrated value
            lufs="$(ffmpeg -nostdin -i "$local_path" -af "ebur128=peak=true:framelog=verbose" -f null - 2>&1 \
                    | grep -E "I:" | tail -1 \
                    | grep -oE -- '-?[0-9]+\.[0-9]+' | head -1 || true)"

            rm -f "$local_path"

            if [[ -z "$lufs" ]]; then
                warn "Skipping UID ${uid}: ffmpeg produced no integrated LUFS value"
                continue
            fi

            printf '%d|%s\n' "$uid" "$lufs" >>"$SAMPLES_FILE"
            log "UID ${uid}: ${lufs} LUFS"
        done <<<"$QUERY_RESULTS"
    fi
fi

# --- Validate ---------------------------------------------------------------
COUNT=$(wc -l <"$SAMPLES_FILE" | tr -d ' ')
if (( COUNT == 0 )); then
    error "No samples collected (0 samples) — aborting."
    exit 1
fi

# --- Compute statistics -----------------------------------------------------
# Use python3 for solid percentile/stddev math + JSON emission.
PYTHON_BIN="$(command -v python3)"
if [[ -z "$PYTHON_BIN" ]]; then
    error "python3 not found — required for statistics."
    exit 2
fi

MEASURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

JSON="$("$PYTHON_BIN" - "$SAMPLES_FILE" "$MEASURED_AT" <<'PYEOF'
import json
import statistics
import sys

samples_file = sys.argv[1]
measured_at = sys.argv[2]

samples = []
with open(samples_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            uid_s, lufs_s = line.split("|", 1)
            uid = int(uid_s.strip())
            lufs = float(lufs_s.strip())
        except (ValueError, IndexError):
            continue
        samples.append({"uid": uid, "lufs": lufs})

if not samples:
    print("ERROR: no parseable samples", file=sys.stderr)
    sys.exit(1)

values = [s["lufs"] for s in samples]
median = statistics.median(values)
# Population stddev — describes the sample we measured, not an estimate of a
# wider population. With N=50 the difference is negligible; this matches the
# "measured library distribution" framing in the SPEC.
if len(values) > 1:
    stddev = statistics.pstdev(values)
else:
    stddev = 0.0

# Linear-interpolation percentiles (NumPy default, "linear" method).
def percentile(sorted_vals, p):
    n = len(sorted_vals)
    if n == 0:
        return None
    if n == 1:
        return sorted_vals[0]
    rank = (p / 100.0) * (n - 1)
    lo = int(rank)
    hi = min(lo + 1, n - 1)
    frac = rank - lo
    return sorted_vals[lo] + frac * (sorted_vals[hi] - sorted_vals[lo])

sv = sorted(values)
p25 = percentile(sv, 25)
p75 = percentile(sv, 75)

out = {
    "median_lufs": round(median, 2),
    "p25": round(p25, 2),
    "p75": round(p75, 2),
    "stddev": round(stddev, 2),
    "sample_count": len(samples),
    "measured_at": measured_at,
    "samples": samples,
}
print(json.dumps(out, indent=2))
PYEOF
)"

if [[ -z "$JSON" ]]; then
    error "Statistics computation failed."
    exit 2
fi

# --- Write output -----------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_PATH")"
printf '%s\n' "$JSON" >"$OUTPUT_PATH"
ok "Wrote ${OUTPUT_PATH} (${COUNT} samples)"

# --- Summary + cron line ----------------------------------------------------
SUMMARY="$(printf '%s' "$JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"median={d[\"median_lufs\"]} p25={d[\"p25\"]} p75={d[\"p75\"]} stddev={d[\"stddev\"]} n={d[\"sample_count\"]}")' 2>/dev/null || true)"
[[ -n "$SUMMARY" ]] && log "Distribution: $SUMMARY"

CRON_LINE='0 3 1 * * /home/tripp/.openclaw/workspace/PretoriaFields/morning-show/scripts/measure-library-lufs.sh >> /home/tripp/.openclaw/workspace/PretoriaFields/morning-show/logs/library-lufs.log 2>&1'

cat >&2 <<EOF

------------------------------------------------------------
Proposed cron line (Tripp adds manually with \`crontab -e\`):

${CRON_LINE}

------------------------------------------------------------
EOF

exit 0
