"""Show Builder Configuration"""
import os

# ── Paths ──────────────────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONTENT_LIBRARY = os.path.join(BASE_DIR, "..", "content-library")
CONTENT_MANIFEST = os.path.join(CONTENT_LIBRARY, "content-manifest.json")
OUTPUT_DIR = os.path.join(BASE_DIR, "output")
CACHE_DIR = os.path.join(BASE_DIR, "cache")
VOICE_SAMPLES_DIR = os.path.join(BASE_DIR, "..", "voice-samples", "01-kjm-clone")

# ── Station SQL ────────────────────────────────────────────────────────────────
STATION_SQL = {
    "server": "100.106.53.28",
    "port": 1433,
    "database": "PlayoutONE_Standard",
    "user": "REDACTED_USER",
    "password": "PlayoutONE.",
}

# ── Station SMB (for file push) ───────────────────────────────────────────────
STATION_SMB = {
    "host": "100.106.53.28",
    "share": "PlayoutONE",
    "username": "P1User",
    "password": "",  # May need configuring
    "production_path": "Production",
}

# ── Audio Processing ──────────────────────────────────────────────────────────
AUDIO = {
    "sample_rate": 44100,
    "channels": 2,
    "bitrate": "192k",
    "target_lufs": -16,
    "true_peak": -1.5,
    "lra": 11,
    "crossfade_default_sec": 2.0,
    "duck_db": -12,
    "format": "mp3",
}

# ── ElevenLabs TTS ────────────────────────────────────────────────────────────
ELEVENLABS = {
    "api_key": os.environ.get("ELEVENLABS_API_KEY", ""),
    "voice_id": os.environ.get("ELEVENLABS_VOICE_ID", ""),  # KJM clone ID once created
    "model": "eleven_multilingual_v2",
    "stability": 0.5,
    "similarity_boost": 0.75,
}

# ── LLM (for show planning) ──────────────────────────────────────────────────
LLM = {
    "ollama_url": "http://localhost:11434",
    "default_model": "gpt-oss:20b",
    "fallback_model": "qwen3:30b-a3b",
}

# ── Genre Category Mapping (PlayoutONE category IDs) ─────────────────────────
GENRE_CATEGORIES = {
    "80s": [37, 94],
    "90s": [38, 100],
    "70s": [36],
    "60s": [35],
    "grunge": [38, 100],  # Subset of 90s
    "reggae": [57],
    "underground": [93],
    "hive": [88],
    "neon": [80],
    "todd": [125],
    "mrj": [109],
    "miami": [70, 75, 76, 77, 78, 79],
    "2000s": [97],
    "2010s": [98],
    "2020s": [99],
    "country": [102],
    "mixed": [44, 38, 37, 36, 43, 93],
}

# ── Cooldown Rules ────────────────────────────────────────────────────────────
COOLDOWN = {
    "song_hours": 24,        # No song repeat within 24h
    "artist_hours": 4,       # No same artist within 4h
    "comedy_clip_hours": 72, # No comedy clip repeat within 72h
    "break_type_min": 2,     # Min 2 breaks between same type
}

# ── Melt binary (vidpy workaround) ───────────────────────────────────────────
MELT_BINARY = "/usr/bin/melt"

# Ensure output/cache dirs exist
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(CACHE_DIR, exist_ok=True)
