"""Timeline Assembler — Builds and renders the final show audio."""
import os
import subprocess
import json
from config import AUDIO, OUTPUT_DIR


def get_duration(filepath: str) -> float:
    """Get audio file duration in seconds."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", filepath],
        capture_output=True, text=True, timeout=10,
    )
    return float(result.stdout.strip())


def normalize_audio(input_path: str, output_path: str) -> str:
    """Normalize audio to target LUFS using ffmpeg loudnorm."""
    cmd = [
        "ffmpeg", "-y", "-i", input_path,
        "-af", f"loudnorm=I={AUDIO['target_lufs']}:TP={AUDIO['true_peak']}:LRA={AUDIO['lra']}",
        "-ar", str(AUDIO["sample_rate"]),
        "-ac", str(AUDIO["channels"]),
        "-b:a", AUDIO["bitrate"],
        output_path,
    ]
    subprocess.run(cmd, capture_output=True, timeout=120)
    return output_path


def build_timeline(songs: list[dict], breaks: list[dict]) -> list[dict]:
    """Interleave songs and breaks into a timeline.

    Returns list of timeline entries: [{"type": "song"|"break", "file": path, ...}, ...]
    """
    timeline = []
    break_map = {b["position"]: b for b in breaks}

    for i, song in enumerate(songs):
        # Add song
        timeline.append({
            "type": "song",
            "file": song.get("file_path", song.get("filename", "")),
            "title": song.get("title", "Unknown"),
            "artist": song.get("artist", "Unknown"),
            "duration": song.get("duration", 0),
        })

        # Add break after this song if scheduled
        if i in break_map:
            brk = break_map[i]
            if brk.get("file") and os.path.exists(brk["file"]):
                timeline.append({
                    "type": "break",
                    "subtype": brk["type"],
                    "file": brk["file"],
                    "script": brk.get("script", ""),
                })

    return timeline


def assemble_show(
    timeline: list[dict],
    output_name: str,
    crossfade_sec: float | None = None,
) -> str:
    """Render timeline to final audio file using ffmpeg.

    Strategy: Normalize each segment, then crossfade-chain them together.
    """
    if crossfade_sec is None:
        crossfade_sec = AUDIO["crossfade_default_sec"]

    output_path = os.path.join(OUTPUT_DIR, f"{output_name}.mp3")
    temp_dir = os.path.join(OUTPUT_DIR, "temp")
    os.makedirs(temp_dir, exist_ok=True)

    # Step 1: Normalize all segments
    normalized_files = []
    for i, entry in enumerate(timeline):
        if not entry.get("file") or not os.path.exists(entry["file"]):
            print(f"[Assembler] WARNING: Missing file for {entry.get('title', entry.get('subtype', '?'))}, skipping")
            continue

        norm_path = os.path.join(temp_dir, f"seg_{i:03d}.mp3")

        # For songs, trim to duration if specified (station files may have silence)
        if entry["type"] == "song":
            dur = entry.get("duration", 0)
            fade_out = max(0, dur - 3) if dur > 10 else None
            af_filters = [
                f"loudnorm=I={AUDIO['target_lufs']}:TP={AUDIO['true_peak']}:LRA={AUDIO['lra']}",
            ]
            if fade_out:
                af_filters.append(f"afade=t=out:st={fade_out}:d=3")
            cmd = [
                "ffmpeg", "-y", "-i", entry["file"],
                "-af", ",".join(af_filters),
                "-ar", str(AUDIO["sample_rate"]),
                "-ac", str(AUDIO["channels"]),
                "-b:a", AUDIO["bitrate"],
                norm_path,
            ]
        else:
            # Breaks: normalize + add subtle fades
            cmd = [
                "ffmpeg", "-y", "-i", entry["file"],
                "-af", f"loudnorm=I={AUDIO['target_lufs']}:TP={AUDIO['true_peak']}:LRA={AUDIO['lra']},"
                       f"afade=t=in:d=0.3,afade=t=out:d=0.3",
                "-ar", str(AUDIO["sample_rate"]),
                "-ac", str(AUDIO["channels"]),
                "-b:a", AUDIO["bitrate"],
                norm_path,
            ]

        result = subprocess.run(cmd, capture_output=True, timeout=120)
        if result.returncode == 0 and os.path.exists(norm_path):
            normalized_files.append(norm_path)
            print(f"[Assembler] Normalized: {entry.get('title', entry.get('subtype', '?'))}")
        else:
            print(f"[Assembler] FAILED to normalize: {entry.get('file')}")
            print(f"  stderr: {result.stderr.decode()[:200]}")

    if len(normalized_files) < 2:
        # Not enough files to crossfade, just return the single file
        if normalized_files:
            os.rename(normalized_files[0], output_path)
            return output_path
        raise ValueError("No audio files to assemble")

    # Step 2: Chain crossfades using ffmpeg
    # ffmpeg acrossfade only works with 2 inputs at a time, so we chain them
    current = normalized_files[0]
    for i in range(1, len(normalized_files)):
        next_file = normalized_files[i]
        chain_out = os.path.join(temp_dir, f"chain_{i:03d}.mp3")

        # Determine crossfade duration — shorter for breaks
        xfade = crossfade_sec
        # Get durations to make sure crossfade isn't longer than either file
        try:
            dur_curr = get_duration(current)
            dur_next = get_duration(next_file)
            xfade = min(xfade, dur_curr * 0.4, dur_next * 0.4)
            xfade = max(0.5, xfade)  # Minimum 0.5s
        except Exception:
            xfade = min(1.0, crossfade_sec)

        cmd = [
            "ffmpeg", "-y", "-i", current, "-i", next_file,
            "-filter_complex",
            f"[0][1]acrossfade=d={xfade:.1f}:c1=tri:c2=tri[out]",
            "-map", "[out]",
            "-b:a", AUDIO["bitrate"],
            chain_out,
        ]

        result = subprocess.run(cmd, capture_output=True, timeout=120)
        if result.returncode == 0:
            current = chain_out
        else:
            # Crossfade failed — try simple concat instead
            print(f"[Assembler] Crossfade failed at segment {i}, using concat")
            concat_list = os.path.join(temp_dir, "concat.txt")
            with open(concat_list, "w") as f:
                f.write(f"file '{current}'\nfile '{next_file}'\n")
            cmd = [
                "ffmpeg", "-y", "-f", "concat", "-safe", "0",
                "-i", concat_list, "-b:a", AUDIO["bitrate"], chain_out,
            ]
            subprocess.run(cmd, capture_output=True, timeout=120)
            current = chain_out

    # Step 3: Move final output
    os.rename(current, output_path)

    # Clean up temp files
    for f in os.listdir(temp_dir):
        try:
            os.remove(os.path.join(temp_dir, f))
        except OSError:
            pass

    final_dur = get_duration(output_path)
    print(f"[Assembler] ✅ Show rendered: {output_path} ({final_dur / 60:.1f} minutes)")

    return output_path


def assemble_show_fast(
    timeline: list[dict],
    output_name: str,
) -> str:
    """Fast assembly — simple concat with short crossfades. For previews."""
    output_path = os.path.join(OUTPUT_DIR, f"{output_name}-preview.mp3")

    # Just take first 15s of each segment
    segments = []
    for entry in timeline[:6]:  # First 6 segments max for preview
        if entry.get("file") and os.path.exists(entry["file"]):
            segments.append(entry["file"])

    if not segments:
        raise ValueError("No files for preview")

    # Build ffmpeg filter chain for quick preview
    inputs = []
    filter_parts = []
    for i, seg in enumerate(segments):
        inputs.extend(["-i", seg])
        filter_parts.append(f"[{i}]atrim=0:15,afade=t=in:d=0.5,afade=t=out:st=13:d=2[s{i}]")

    # Concat
    concat_inputs = "".join(f"[s{i}]" for i in range(len(segments)))
    filter_parts.append(f"{concat_inputs}concat=n={len(segments)}:v=0:a=1[out]")

    cmd = ["ffmpeg", "-y"] + inputs + [
        "-filter_complex", ";".join(filter_parts),
        "-map", "[out]", "-b:a", AUDIO["bitrate"], output_path,
    ]

    subprocess.run(cmd, capture_output=True, timeout=60)
    return output_path


if __name__ == "__main__":
    # Test with existing test files
    test_timeline = [
        {"type": "song", "file": "/tmp/t1.mp3", "title": "Metallica", "artist": "Test", "duration": 30},
        {"type": "break", "subtype": "station_id", "file": "/tmp/tb1.mp3"},
        {"type": "song", "file": "/tmp/t3.mp3", "title": "Ellington", "artist": "Test", "duration": 30},
        {"type": "break", "subtype": "station_id", "file": "/tmp/tb2.mp3"},
        {"type": "song", "file": "/tmp/t5.mp3", "title": "Weckl", "artist": "Test", "duration": 30},
    ]

    # Quick trim test files first
    for entry in test_timeline:
        if entry["type"] == "song":
            trimmed = f"/tmp/trim_{os.path.basename(entry['file'])}"
            subprocess.run(
                ["ffmpeg", "-y", "-i", entry["file"], "-t", "30", trimmed],
                capture_output=True,
            )
            entry["file"] = trimmed

    output = assemble_show(test_timeline, "test-assembly")
    print(f"Output: {output}")
