#!/usr/bin/env bash
# preanalyze-segment.sh — Wave 3 Task 14
#
# Pre-analyze an audio segment with ffprobe and emit safe playout markers as JSON.
# Used by publish.sh BEFORE the DPL hits the AutoImporter folder, because
# AutoImporter chokes on files >30 minutes and leaves Extro=0/TrimOut=0,
# which causes PlayoutONE to instant-skip in a crash loop (March 30 incident
# root cause #2).
#
# Usage:
#   preanalyze-segment.sh /path/to/audio.mp3
#
# Output (stdout, JSON):
#   {"length_ms": 599980, "trim_out_ms": 599980, "extro_ms": 594980}
#
# Exit codes:
#   0  success
#   1  file missing / ffprobe failed / file too short to be safe
#
# Markers:
#   length_ms   = duration_seconds * 1000  (integer)
#   trim_out_ms = length_ms                 (absolute end — no early trim)
#   extro_ms    = max(length_ms - 5000, 1000)
#                 (5-second crossfade safety; minimum 1000ms — refuses 0)

set -u

CROSSFADE_MS=5000
MIN_EXTRO_MS=1000

err() { echo "preanalyze-segment: $*" >&2; }

if [[ $# -lt 1 ]]; then
    err "usage: $(basename "$0") <audio-file-path>"
    exit 1
fi

FILE="$1"

if [[ ! -f "$FILE" ]]; then
    err "file not found: $FILE"
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    err "ffprobe not on PATH"
    exit 1
fi

# Get duration in seconds (float). ffprobe writes a single number to stdout.
DURATION_SEC="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)"

if [[ -z "$DURATION_SEC" ]]; then
    err "ffprobe returned empty duration for: $FILE"
    exit 1
fi

# Validate the duration string looks like a positive number
if ! [[ "$DURATION_SEC" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    err "ffprobe returned non-numeric duration ($DURATION_SEC) for: $FILE"
    exit 1
fi

# Convert seconds (float) to integer milliseconds without bc dependency.
# awk handles the float math + truncation portably.
LENGTH_MS="$(awk -v d="$DURATION_SEC" 'BEGIN { printf("%d", d * 1000) }')"

if [[ -z "$LENGTH_MS" || "$LENGTH_MS" -le 0 ]]; then
    err "computed length_ms is non-positive ($LENGTH_MS) for: $FILE"
    exit 1
fi

TRIM_OUT_MS="$LENGTH_MS"

# Compute the raw extro before clamping. If the raw value is <= 0 the file is
# shorter than (or equal to) the crossfade window — we cannot produce a safe
# extro marker and must refuse. Producing extro_ms == length_ms would give
# PlayoutONE a zero-length crossfade tail, the exact failure mode of the
# March 30 incident (Extro=0 silent-skip).
RAW_EXTRO=$(( LENGTH_MS - CROSSFADE_MS ))
if (( RAW_EXTRO <= 0 )); then
    err "file too short for safe markers (length=${LENGTH_MS}ms <= crossfade=${CROSSFADE_MS}ms): $FILE"
    exit 1
fi

EXTRO_MS="$RAW_EXTRO"
if (( EXTRO_MS < MIN_EXTRO_MS )); then
    EXTRO_MS="$MIN_EXTRO_MS"
fi

# Belt-and-braces sanity: extro must be positive and strictly less than length.
if (( EXTRO_MS <= 0 || EXTRO_MS >= LENGTH_MS )); then
    err "computed extro_ms (${EXTRO_MS}) out of range for length=${LENGTH_MS}: $FILE"
    exit 1
fi

printf '{"length_ms": %d, "trim_out_ms": %d, "extro_ms": %d}\n' \
    "$LENGTH_MS" "$TRIM_OUT_MS" "$EXTRO_MS"
