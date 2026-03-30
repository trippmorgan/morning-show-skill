"""Break Factory — Generates DJ voice breaks, comedy clips, sports/culture drops."""
import json
import os
import random
import subprocess
import hashlib
from datetime import datetime
from config import CONTENT_LIBRARY, CONTENT_MANIFEST, CACHE_DIR, ELEVENLABS, LLM


def load_content_manifest() -> dict:
    """Load the content library manifest."""
    if os.path.exists(CONTENT_MANIFEST):
        with open(CONTENT_MANIFEST) as f:
            return json.load(f)
    return {"clips": []}


def get_clips_by_type(clip_type: str, era: str = "") -> list[dict]:
    """Get content clips by type, optionally filtered by era."""
    manifest = load_content_manifest()
    clips = [c for c in manifest.get("clips", []) if c.get("type") == clip_type]
    if era:
        era_clips = [c for c in clips if c.get("era", "") == era]
        if era_clips:
            return era_clips
    return clips


def generate_dj_script(
    prev_song: dict | None = None,
    next_song: dict | None = None,
    show_title: str = "",
    mood: str = "energetic",
) -> str:
    """Generate a DJ break script using local LLM."""
    context_parts = []
    if prev_song:
        context_parts.append(f'Just played: "{prev_song["title"]}" by {prev_song["artist"]}')
    if next_song:
        context_parts.append(f'Coming up: "{next_song["title"]}" by {next_song["artist"]}')
    if show_title:
        context_parts.append(f"Show: {show_title}")

    context = ". ".join(context_parts) if context_parts else "General station break"

    prompt = f"""Write a short radio DJ break script (2-3 sentences, ~10 seconds when spoken).
Station: Pretoria Fields (WPFQ). DJ persona: Kenny (KJM) — cool, laid-back, Gen X vibes.
Mood: {mood}. Context: {context}.
Rules: Keep it natural and conversational. No stiff announcer voice. Reference the songs naturally.
Output ONLY the script text, nothing else."""

    payload = json.dumps({
        "model": LLM["default_model"],
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0.8, "num_predict": 150},
    })

    try:
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", f"{LLM['ollama_url']}/api/chat",
             "-H", "Content-Type: application/json", "-d", payload],
            capture_output=True, text=True, timeout=30,
        )
        response = json.loads(result.stdout)
        script = response.get("message", {}).get("content", "").strip()
        # Clean up any markdown or quotes
        script = script.strip('"').strip("'").strip()
        return script
    except Exception as e:
        # Fallback generic scripts
        fallbacks = [
            f"You're locked into Pretoria Fields. {context}. Stay with us.",
            f"WPFQ, the Queen Bee. {context}. Don't touch that dial.",
            f"Pretoria Fields keeping it real. {context}.",
        ]
        return random.choice(fallbacks)


def generate_dj_audio(script: str) -> str | None:
    """Generate DJ break audio via ElevenLabs TTS. Returns path to cached MP3."""
    if not ELEVENLABS["api_key"] or not ELEVENLABS["voice_id"]:
        print("[BreakFactory] ElevenLabs not configured — skipping TTS")
        return None

    # Cache key based on script hash
    script_hash = hashlib.md5(script.encode()).hexdigest()[:12]
    cache_path = os.path.join(CACHE_DIR, f"dj-break-{script_hash}.mp3")

    if os.path.exists(cache_path):
        print(f"[BreakFactory] Cache hit: {cache_path}")
        return cache_path

    try:
        from elevenlabs import ElevenLabs

        client = ElevenLabs(api_key=ELEVENLABS["api_key"])
        audio = client.text_to_speech.convert(
            voice_id=ELEVENLABS["voice_id"],
            text=script,
            model_id=ELEVENLABS["model"],
        )

        with open(cache_path, "wb") as f:
            for chunk in audio:
                f.write(chunk)

        print(f"[BreakFactory] Generated DJ break: {cache_path}")
        return cache_path

    except Exception as e:
        print(f"[BreakFactory] ElevenLabs TTS failed: {e}")
        return None


def generate_culture_drop(era: str, date: datetime | None = None) -> dict:
    """Generate a sports/culture drop script for the given era."""
    date_str = (date or datetime.now()).strftime("%B %d")
    prompt = f"""Write a very short radio "on this day" drop (1-2 sentences, ~5 seconds spoken).
Era: {era}. Date context: {date_str}.
Topic: Pick a fun {era} sports moment, pop culture event, or music milestone.
Format: Just the script text. Keep it punchy and fun.
Example: "On this day in ninety-six, the Chicago Bulls clinched their seventy-second win. What a time to be alive."
Output ONLY the script text."""

    payload = json.dumps({
        "model": LLM["default_model"],
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0.9, "num_predict": 100},
    })

    try:
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", f"{LLM['ollama_url']}/api/chat",
             "-H", "Content-Type: application/json", "-d", payload],
            capture_output=True, text=True, timeout=30,
        )
        response = json.loads(result.stdout)
        script = response.get("message", {}).get("content", "").strip().strip('"').strip("'")
        return {"type": "culture_drop", "script": script, "era": era}
    except Exception as e:
        return {"type": "culture_drop", "script": f"This is WPFQ, Pretoria Fields.", "era": era}


def select_station_id() -> dict | None:
    """Select a random station ID from content library."""
    clips = get_clips_by_type("station-id")
    if clips:
        clip = random.choice(clips)
        filepath = os.path.join(CONTENT_LIBRARY, clip["file"])
        if os.path.exists(filepath):
            return {"type": "station_id", "file": filepath, "clip": clip}
    return None


def generate_breaks(
    manifest,
    songs: list[dict],
) -> list[dict]:
    """Generate all breaks for a show based on manifest and song list.

    Returns list of break dicts with position (index in song list where break goes AFTER).
    """
    breaks = []
    break_types = manifest.break_schedule.types
    interval = manifest.break_schedule.interval_min

    # Calculate break positions based on interval
    total_duration = sum(s.get("duration", 240) for s in songs)
    min_interval_sec = interval[0] * 60
    max_interval_sec = interval[1] * 60

    elapsed = 0
    next_break_at = random.randint(min_interval_sec, max_interval_sec)

    for i, song in enumerate(songs):
        elapsed += song.get("duration", 240)

        if elapsed >= next_break_at and i < len(songs) - 1:
            # Pick break type based on weights
            break_type = random.choices(
                list(break_types.keys()),
                weights=list(break_types.values()),
                k=1,
            )[0]

            brk = {"position": i, "type": break_type}

            if break_type == "dj_voice":
                prev_song = songs[i] if i < len(songs) else None
                next_song = songs[i + 1] if i + 1 < len(songs) else None
                script = generate_dj_script(
                    prev_song=prev_song,
                    next_song=next_song,
                    show_title=manifest.title,
                    mood=manifest.mood,
                )
                brk["script"] = script
                audio_path = generate_dj_audio(script)
                if audio_path:
                    brk["file"] = audio_path

            elif break_type == "comedy":
                clips = get_clips_by_type("comedy", era=manifest.era)
                if clips:
                    clip = random.choice(clips)
                    filepath = os.path.join(CONTENT_LIBRARY, clip["file"])
                    if os.path.exists(filepath):
                        brk["file"] = filepath
                        brk["clip"] = clip

            elif break_type == "sports_culture":
                drop = generate_culture_drop(manifest.era or "90s")
                brk["script"] = drop["script"]
                # TTS the drop if ElevenLabs is configured
                audio_path = generate_dj_audio(drop["script"])
                if audio_path:
                    brk["file"] = audio_path

            elif break_type == "station_id":
                sid = select_station_id()
                if sid:
                    brk["file"] = sid["file"]
                    brk["clip"] = sid["clip"]

            breaks.append(brk)
            next_break_at = elapsed + random.randint(min_interval_sec, max_interval_sec)

            print(f"[BreakFactory] Break after song {i + 1}: {break_type}"
                  f"{' — ' + brk.get('script', '')[:60] if 'script' in brk else ''}")

    print(f"[BreakFactory] Generated {len(breaks)} breaks for {len(songs)} songs")
    return breaks


if __name__ == "__main__":
    # Test DJ script generation
    print("=== Testing DJ Script Generation ===")
    script = generate_dj_script(
        prev_song={"title": "Smells Like Teen Spirit", "artist": "Nirvana"},
        next_song={"title": "Black Hole Sun", "artist": "Soundgarden"},
        show_title="90s Grunge Block",
        mood="energetic",
    )
    print(f"Script: {script}")

    print("\n=== Testing Culture Drop ===")
    drop = generate_culture_drop("90s")
    print(f"Drop: {drop['script']}")
