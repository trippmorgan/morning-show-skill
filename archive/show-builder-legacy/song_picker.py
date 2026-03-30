"""Song Picker — Queries station SQL for songs matching show criteria."""
import random
import pymssql
from config import STATION_SQL, GENRE_CATEGORIES, COOLDOWN


def get_connection():
    return pymssql.connect(
        server=STATION_SQL["server"],
        port=STATION_SQL["port"],
        user=STATION_SQL["user"],
        password=STATION_SQL["password"],
        database=STATION_SQL["database"],
    )


def query_station_sql(sql: str) -> list[dict]:
    conn = get_connection()
    try:
        cursor = conn.cursor(as_dict=True)
        cursor.execute(sql)
        return cursor.fetchall()
    finally:
        conn.close()


def get_songs_by_category(category_ids: list[int], limit: int = 100) -> list[dict]:
    cat_list = ",".join(str(c) for c in category_ids)
    sql = f"""
    SELECT TOP {limit}
        ID,
        UID,
        Title,
        Artist,
        Filename,
        Category,
        [Length],
        LastPlayed,
        Plays,
        LUFS
    FROM Audio WITH (NOLOCK)
    WHERE Category IN ({cat_list})
    ORDER BY NEWID()
    """
    rows = query_station_sql(sql)
    songs = []
    for row in rows:
        filename = str(row.get("Filename", "") or "").strip()
        length_ms = int(row.get("Length", 0) or 0)
        duration_sec = max(0, round(length_ms / 1000))
        if not filename or duration_sec < 60:
            continue
        songs.append({
            "id": int(row.get("ID", 0) or 0),
            "uid": str(row.get("UID", "") or ""),
            "title": str(row.get("Title", "Unknown") or "Unknown").strip(),
            "artist": str(row.get("Artist", "Unknown") or "Unknown").strip(),
            "duration": duration_sec,
            "category": int(row.get("Category", 0) or 0),
            "filename": filename,
            "file_path": f"C:/PlayoutONE/Production/{filename}",
            "last_played": str(row.get("LastPlayed", "") or ""),
            "plays": int(row.get("Plays", 0) or 0),
            "lufs": row.get("LUFS"),
        })
    return songs


def get_recent_plays(hours: int = 24) -> set[str]:
    sql = f"""
    SELECT DISTINCT UID
    FROM Log WITH (NOLOCK)
    WHERE EventTime > DATEADD(hour, -{hours}, GETDATE())
    """
    rows = query_station_sql(sql)
    return {str(row.get("UID", "") or "") for row in rows if row.get("UID") is not None}


def get_recent_artists(hours: int = 4) -> set[str]:
    sql = f"""
    SELECT DISTINCT a.Artist
    FROM Log l WITH (NOLOCK)
    JOIN Audio a WITH (NOLOCK) ON l.UID = a.UID
    WHERE l.EventTime > DATEADD(hour, -{hours}, GETDATE())
      AND a.Artist IS NOT NULL
    """
    rows = query_station_sql(sql)
    return {str(row.get("Artist", "") or "").strip().lower() for row in rows if str(row.get("Artist", "") or "").strip()}


def pick_songs(genre: str, duration_minutes: int, category_ids: list[int] | None = None, era: str | None = None) -> list[dict]:
    if category_ids is None:
        cats = GENRE_CATEGORIES.get(genre.lower(), [])
        if not cats and era:
            cats = GENRE_CATEGORIES.get(era.lower(), [])
        if not cats:
            raise ValueError(f"Unknown genre '{genre}' and no category_ids provided")
    else:
        cats = category_ids

    target_songs = max(10, duration_minutes // 4)
    candidates = get_songs_by_category(cats, limit=target_songs * 4)
    if not candidates:
        raise ValueError(f"No songs found for categories {cats}")

    recent_uids = get_recent_plays(COOLDOWN["song_hours"])
    recent_artists = get_recent_artists(COOLDOWN["artist_hours"])

    selected = []
    used_artists = set()
    total_duration = 0
    target_seconds = duration_minutes * 60

    random.shuffle(candidates)
    for song in candidates:
        if total_duration >= target_seconds:
            break
        artist_key = song["artist"].lower()
        if song["uid"] in recent_uids:
            continue
        if artist_key and artist_key in recent_artists:
            continue
        if artist_key and artist_key in used_artists:
            continue
        selected.append(song)
        if artist_key:
            used_artists.add(artist_key)
        total_duration += song["duration"]

    print(f"[SongPicker] Selected {len(selected)} songs, total {total_duration // 60}m {total_duration % 60}s (target: {duration_minutes}m) from {len(candidates)} candidates")
    return selected


if __name__ == "__main__":
    print("=== Testing Song Picker (90s, 30 min) ===")
    songs = pick_songs("90s", 30)
    for i, s in enumerate(songs, 1):
        dur = f"{s['duration'] // 60}:{s['duration'] % 60:02d}"
        print(f"  {i}. {s['artist']} — {s['title']} [{dur}] (cat {s['category']}, uid {s['uid']})")
