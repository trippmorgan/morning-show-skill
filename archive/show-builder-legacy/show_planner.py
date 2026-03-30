"""Show Planner — Parses natural language show requests into structured manifests."""
import json
import re
import subprocess
from dataclasses import dataclass, field, asdict
from config import LLM, GENRE_CATEGORIES


@dataclass
class BreakSchedule:
    interval_min: tuple[int, int] = (10, 15)
    types: dict[str, float] = field(default_factory=lambda: {
        "dj_voice": 0.4,
        "comedy": 0.3,
        "sports_culture": 0.2,
        "station_id": 0.1,
    })


@dataclass
class ShowManifest:
    title: str = ""
    duration_minutes: int = 60
    genre: str = "mixed"
    era: str = ""
    category_ids: list[int] = field(default_factory=list)
    break_schedule: BreakSchedule = field(default_factory=BreakSchedule)
    mood: str = "energetic"
    special_instructions: str = ""
    # Populated by song_picker and break_factory
    songs: list[dict] = field(default_factory=list)
    breaks: list[dict] = field(default_factory=list)
    timeline: list[dict] = field(default_factory=list)

    def to_dict(self):
        d = asdict(self)
        return d

    def to_json(self, indent=2):
        return json.dumps(self.to_dict(), indent=indent)


def parse_with_llm(prompt: str) -> ShowManifest:
    """Use local LLM to parse natural language into ShowManifest."""
    system_prompt = f"""You are a radio show planner. Parse the user's show request into JSON.
Available genres and their category IDs: {json.dumps(GENRE_CATEGORIES)}

Return ONLY valid JSON with these fields:
{{
    "title": "Show title based on the request",
    "duration_minutes": 60,
    "genre": "genre name",
    "era": "decade if specified (e.g. 90s)",
    "category_ids": [list of PlayoutONE category IDs],
    "break_interval_min": [min_minutes, max_minutes],
    "break_types": {{"dj_voice": 0.4, "comedy": 0.3, "sports_culture": 0.2, "station_id": 0.1}},
    "mood": "energetic/chill/building/mixed",
    "special_instructions": "any special requests verbatim"
}}

Adjust break_types weights based on what the user emphasizes.
If they mention comedy a lot, increase comedy weight.
If they mention sports, increase sports_culture weight."""

    payload = json.dumps({
        "model": LLM["default_model"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "format": "json",
        "options": {"temperature": 0.3, "num_predict": 500},
    })

    result = subprocess.run(
        ["curl", "-s", "-X", "POST", f"{LLM['ollama_url']}/api/chat",
         "-H", "Content-Type: application/json",
         "-d", payload],
        capture_output=True, text=True, timeout=60,
    )

    if result.returncode != 0:
        raise RuntimeError(f"LLM query failed: {result.stderr}")

    response = json.loads(result.stdout)
    content = response.get("message", {}).get("content", "{}")

    # Parse JSON from response
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        # Try to extract JSON from markdown code block
        match = re.search(r"```json?\s*(.*?)\s*```", content, re.DOTALL)
        if match:
            data = json.loads(match.group(1))
        else:
            raise ValueError(f"Could not parse LLM response as JSON: {content[:200]}")

    manifest = ShowManifest(
        title=data.get("title", "Untitled Show"),
        duration_minutes=data.get("duration_minutes", 60),
        genre=data.get("genre", "mixed"),
        era=data.get("era", ""),
        category_ids=data.get("category_ids", []),
        break_schedule=BreakSchedule(
            interval_min=tuple(data.get("break_interval_min", [10, 15])),
            types=data.get("break_types", {}),
        ),
        mood=data.get("mood", "energetic"),
        special_instructions=data.get("special_instructions", ""),
    )

    return manifest


def parse_simple(prompt: str) -> ShowManifest:
    """Simple regex-based parser (no LLM needed, faster for common patterns)."""
    prompt_lower = prompt.lower()

    # Duration
    duration = 60
    dur_match = re.search(r"(\d+)\s*(?:hour|hr|h)", prompt_lower)
    if dur_match:
        duration = int(dur_match.group(1)) * 60
    dur_match = re.search(r"(\d+)\s*(?:minute|min|m)\b", prompt_lower)
    if dur_match:
        duration = int(dur_match.group(1))

    # Genre
    genre = "mixed"
    for g in GENRE_CATEGORIES:
        if g in prompt_lower:
            genre = g
            break

    # Era
    era = ""
    era_match = re.search(r"(\d{2})s", prompt_lower)
    if era_match:
        era = era_match.group(0)

    # Break interval
    interval = (10, 15)
    int_match = re.search(r"every\s+(\d+)[-–](\d+)\s*min", prompt_lower)
    if int_match:
        interval = (int(int_match.group(1)), int(int_match.group(2)))

    # Break types — adjust weights based on mentions
    types = {"dj_voice": 0.3, "comedy": 0.2, "sports_culture": 0.2, "station_id": 0.1}
    if "comedy" in prompt_lower or "funny" in prompt_lower:
        types["comedy"] = 0.4
        types["dj_voice"] = 0.2
    if "sport" in prompt_lower:
        types["sports_culture"] = 0.35
        types["comedy"] = 0.15
    # Normalize
    total = sum(types.values())
    types = {k: round(v / total, 2) for k, v in types.items()}

    # Mood
    mood = "energetic"
    if any(w in prompt_lower for w in ["chill", "mellow", "relaxed", "smooth"]):
        mood = "chill"
    elif any(w in prompt_lower for w in ["build", "crescendo", "ramp"]):
        mood = "building"

    # Category IDs
    cats = GENRE_CATEGORIES.get(genre, [])
    if not cats and era:
        cats = GENRE_CATEGORIES.get(era, [])

    manifest = ShowManifest(
        title=f"{era + ' ' if era else ''}{genre.title()} Block".strip(),
        duration_minutes=duration,
        genre=genre,
        era=era,
        category_ids=cats,
        break_schedule=BreakSchedule(interval_min=interval, types=types),
        mood=mood,
        special_instructions=prompt,
    )

    return manifest


def plan_show(prompt: str, use_llm: bool = True) -> ShowManifest:
    """Plan a show from natural language. Falls back to simple parser if LLM fails."""
    if use_llm:
        try:
            return parse_with_llm(prompt)
        except Exception as e:
            print(f"[ShowPlanner] LLM parse failed ({e}), falling back to simple parser")

    return parse_simple(prompt)


if __name__ == "__main__":
    test = "Build me a 2 hour 90s grunge block with comedy every 10-15 minutes, splice in sports references from the 90s"
    print(f"Prompt: {test}\n")

    manifest = plan_show(test, use_llm=False)
    print("Simple parser result:")
    print(manifest.to_json())

    print("\nTrying LLM parser...")
    try:
        manifest = plan_show(test, use_llm=True)
        print("LLM parser result:")
        print(manifest.to_json())
    except Exception as e:
        print(f"LLM failed: {e}")
