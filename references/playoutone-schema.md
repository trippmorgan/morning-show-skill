# PlayoutONE Database Schema Reference

Database: `PlayoutONE_Standard` (SQL Server, accessed via `sqlcmd -S localhost -d PlayoutONE_Standard -E`)

---

## Audio Table

The main audio library. Stores metadata for every audio file in the system.

### Key Columns

| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| **UID** | nvarchar | NOT NULL | Primary identifier for audio items |
| **Title** | nvarchar | | Song/item title |
| **Artist** | nvarchar | | Artist name |
| **Filename** | nvarchar | | Path to audio file on disk |
| **Category** | nvarchar | | Content category |

- **42 NOT NULL columns** total — inserting new rows requires populating all of them.

---

## Playlists Table

Holds the scheduled playout for each hour. Each row is one scheduled item.

### Key Columns

| Column | Type | Notes |
|--------|------|-------|
| **GIndex** | PK | Format: `YYYYMMDDHH.NNNN` (e.g., `2026033007.0003`) |
| **Name** | nvarchar | Playlist name, format: `YYYYMMDDHH.dpl` |
| **AirTime** | time | Scheduled air time |
| **Order** | float | Sort order within the hour |
| **UID** | nvarchar | References Audio.UID |
| **Title** | nvarchar | Song/item title |
| **Artist** | nvarchar | Artist name |
| **Chain** | int | 1 = chained (auto-play next), 0 = stop |
| **Length** | float | Duration in milliseconds |
| **Len** | float | Duration in milliseconds (duplicate) |
| **Type** | int | Item type (see below) |
| **SourceFile** | nvarchar | Path to audio file |

- **32 NOT NULL columns** total.

### Type Values

| Type | Meaning | Action |
|------|---------|--------|
| **0** | Marker | PRESERVE — do not modify or delete |
| **16** | Music | Safe to repurpose/delete |
| **17** | Station ID | PRESERVE — do not modify or delete |
| **26** | Ad/Commercial | PRESERVE — do not modify or delete |

---

## Mutation Strategy

### UPDATE (repurpose) over INSERT

Because both tables have many NOT NULL columns (42 for Audio, 32 for Playlists), **UPDATE existing rows** rather than INSERT new ones. This avoids needing to supply values for every required column.

### Workflow for Replacing an Hour's Music

1. Identify existing Type=16 (music) rows for the target hour
2. **UPDATE** one row per new song — set UID, Title, Artist, SourceFile, Length, Len, etc.
3. **DELETE** remaining unused Type=16 rows after repurposing what you need
4. Leave Type=0, Type=17, and Type=26 rows untouched

### Required Column Values When Updating

```sql
SET QUOTED_IDENTIFIER ON;

UPDATE Playlists SET
    UID = @uid,
    Title = @title,
    Artist = @artist,
    SourceFile = @sourcefile,
    Length = @length_ms,
    Len = @length_ms,
    Chain = 1,
    Type = 16,
    Deleted = 0,
    Status = 0
WHERE GIndex = @gindex;
```

---

## Safety Rules

1. **Only modify FUTURE hours** — never touch the currently-playing or past hours
2. **Always `SET QUOTED_IDENTIFIER ON`** before any query
3. **Preserve protected types** — never modify or delete Type=0 (markers), Type=17 (station IDs), or Type=26 (ads)
4. **Always set** `Chain=1`, `Type=16`, `Deleted=0`, `Status=0` on updated music rows
5. **Validate before executing** — confirm the target hour is in the future before running any UPDATE/DELETE
