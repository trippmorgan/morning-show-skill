# PlayoutONE Database Schema Reference

*Updated 2026-03-30 after morning show incident*

Database: `PlayoutONE_Standard`  
Server: `localhost\p1sqlexpress`  
Auth: via environment variables `P1_SQL_USER` / `P1_SQL_PASS`

---

## Audio Table (18,108 rows — READ/WRITE)

The master media library. Every audio file must be registered here before it can play.

### Key Columns

| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| **UID** | nvarchar(13) | NOT NULL | Primary identifier — also the filename without extension |
| **Title** | nvarchar(255) | | Song/item title |
| **Artist** | nvarchar(255) | | Artist name |
| **Filename** | nvarchar(MAX) | | Audio filename (e.g., `90001.mp3`) |
| **Length** | int | | Duration in milliseconds |
| **TrimOut** | int | | ⚠️ Track end point (ms). **MUST = Length. If 0 → instant-skip crash loop** |
| **Extro** | int | | ⚠️ Crossfade start point (ms). **MUST = Length - 5000. If 0 → instant-skip** |
| **TrimIn** | int | | Start offset (ms), usually 0 |
| **Intro** | int | | Intro end point (where vocals start) |
| **HookIn** / **HookOut** | int | | Hook segment markers |
| **Type** | int | | 16=Song, 17=Production, 18=Commercial, 27=Voice |
| **Category** | int | | Category ID (43=Other, 46=Legal ID, etc.) |
| **Chain** | bit | | 1=auto-chain to next track |
| **AutoDJ** | bit | | 1=available for AutoDJ selection |
| **Deleted** | bit | | Soft delete flag |
| **LastPlayed** | datetime | | Last played timestamp |
| **Plays** | int | | Total play count |

**⚠️ CRITICAL — TrimOut and Extro markers:**
- `TrimOut = 0` → PlayoutONE thinks the track is 0ms long → instant skip
- `Extro = 0` → Same: engine fires end-of-track at 0ms → crash loop
- On 60-minute files, AutoImporter fails to analyze and sets both to 0
- **Always set manually:** `TrimOut = Length`, `Extro = Length - 5000`

### Registering New Audio

```sql
SET QUOTED_IDENTIFIER ON;

-- Register a morning show segment
INSERT INTO Audio (UID, Title, Artist, Filename, Length, TrimOut, Extro, 
                   TrimIn, Intro, HookIn, HookOut, Type, Category, Chain, AutoDJ)
VALUES ('90001', 'Monday Morning Show Hour 1', 'Dr Johnny Fever', '90001.mp3',
        3592000, 3592000, 3587000, 0, 0, 0, 0, 16, 43, 1, 1);
```

**42 NOT NULL columns** total — but most have defaults. The INSERT above covers the essential fields.

---

## Playlists Table (26,683 rows — ⚠️ DO NOT WRITE DIRECTLY)

**The Playlists table is a LOG, not a queue.** It records what has been scheduled and played. PlayoutONE manages this table internally via AutoImporter and the playout engine.

**NEVER use raw SQL INSERT/UPDATE on this table.** Use DPL files via AutoImporter instead. Raw SQL has caused two station crashes (March 20 and March 30, 2026).

### Key Columns

| Column | Type | Notes |
|--------|------|-------|
| **ID** | int PK | Auto-increment |
| **GIndex** | decimal UNIQUE | `YYYYMMDDHH.NNNN` — primary scheduling key |
| **Name** | nvarchar(50) | Source DPL filename (e.g., `2026033007.dpl`) |
| **Order** | real | Position within the hour |
| **UID** | varchar(10) | → Audio.UID |
| **Title** | nvarchar(600) | Track title |
| **Artist** | nvarchar(255) | Track artist |
| **Chain** | bit | 1=auto-chain, 0=stop |
| **Length** | float | Duration (ms) |
| **Type** | int | 0=START marker, 16=Song, 17=Production, 26=SOFTMARKER |
| **SourceFile** | varchar(255) | ⚠️ **Path to audio file — MUST be populated** |
| **Played** | bit | Has been played (managed by PlayoutONE) |
| **Done** | bit | Finished playing (managed by PlayoutONE) |
| **MissingAudio** | bit | Audio file not found on disk |
| **AgentUpdate** | bit | Set to 1 for agent-modified entries (audit flag) |
| **GptScript** | nvarchar(MAX) | AI-generated voice break scripts |
| **Deleted** | bit | Soft-delete flag |
| **ActualAirTime** | datetime | When it actually played |

### Type Values (PRESERVE non-16 types)

| Type | Meaning | Action |
|------|---------|--------|
| **0** | START PLAYLIST marker | ❌ NEVER modify or delete |
| **16** | Music/Song | ✅ Safe to replace via DPL import |
| **17** | Station ID / Liner / Production | ❌ NEVER modify or delete |
| **26** | SOFTMARKER (hour boundary) | ❌ NEVER modify or delete |

### How AutoImporter Creates Playlists Entries

1. DPL file dropped in `F:\PlayoutONE\Import\Music Logs\`
2. AutoImporter parses the tab-separated file
3. Creates one Playlists row per line:
   - Sets `GIndex = YYYYMMDDHH.NNNN`
   - Sets `Name = YYYYMMDDHH.dpl`
   - Sets `SourceFile` from the Audio table lookup
   - Creates a `Type=0` START PLAYLIST marker as the first entry
   - Creates a `Type=26` SOFTMARKER from the DPL command field
4. Moves the DPL file to `\Imported\` subfolder
5. PlayoutONE loads these entries at the top of each hour

---

## Settings Table (191 rows — WRITE WITH CAUTION)

Key-value configuration store.

### Critical Settings

| Key | Value | Meaning |
|-----|-------|---------|
| `TotalAutomation` | `-1` (TRUE) | Station never stops, always auto-fills |
| `AutoFillThreshold` | `30` | Add songs when <30s of music remains |
| `AutoFillItems` | `0` | Add unlimited items as needed |
| `ScheduleWithClockGrid` | `1` | Use internal schedule grid |
| `AutoOnPlay` | `1` ✅ | Start playlist 10s after startup |
| `LastPlaylistLoadedCheck` | `1` ✅ | Auto-load next playlist when items low |
| `AutoImporterMachine` | `P1-WPFQ-SRVS` | AutoImporter runs on this machine |

### AutoFill Behavior

AutoFill pulls songs from the **Audio table** (Type=16, not deleted, matching category rules). It does NOT read from the Playlists table. Modifying unplayed Playlists entries does not affect what AutoFill selects.

---

## Key Paths

| Path | Purpose | Notes |
|------|---------|-------|
| `F:\PlayoutONE\Audio\` | Audio file storage | Files named `{UID}.mp3` |
| `F:\PlayoutONE\Import\Music Logs\` | ✅ DPL import folder | AutoImporter watches this |
| `F:\PlayoutONE\Import\Music Logs\Imported\` | Processed DPLs | Moved here after import |
| `C:\PlayoutONE\data\playlists\` | Local cache | ❌ NOT the import folder |
| `C:\PlayoutONE\Modules\` | Executables | PlayoutONE.exe, ffmpeg.exe |

---

## DPL File Format (Music1 14-Column)

Tab-separated, one track per line. End each hour with a SOFTMARKER.

```
{UID}\tTRUE\t-1\t-1\t-2\t\tFALSE\t0\t-2\t\t\t\t\t\t{Title}|{Artist}
\tTRUE\t-1\t-1\t-2\tSOFTMARKER {HH}:59:59\t-2\t0\t-2\t\t\t\t\t\t
```

| Col | Field | Value |
|-----|-------|-------|
| 1 | UID | Cart number (empty for SOFTMARKER) |
| 2 | Chain | `TRUE` |
| 3 | Extro | `-1` (use Audio table value) |
| 4 | Original Extro | `-1` |
| 5 | Fade | `-2` (use media finder setting) |
| 6 | Command | empty or `SOFTMARKER HH:59:59` |
| 7 | Oversweep | `FALSE` or `-2` |
| 8 | Recon ID | `0` |
| 9 | Unknown | `-2` |
| 10–13 | *(empty)* | |
| 14 | Display | `Title|Artist` |

**Filename:** `YYYYMMDDHH.dpl` (e.g., `2026033105.dpl` for March 31, 5 AM)

---

## Safety Rules

1. **NEVER raw SQL INSERT/UPDATE on Playlists** — use DPL import via AutoImporter
2. **NEVER mass-update Played/Done flags** — empties visual playlist → dead air
3. **NEVER modify entries for current or recent hours** — crashes the engine
4. **NEVER set TrimOut or Extro to 0** — causes instant-skip crash loop
5. **ALWAYS set SourceFile** in Audio table — PlayoutONE can't find files without it
6. **ALWAYS use `F:\PlayoutONE\Import\Music Logs\`** for DPL import (not C: drive)
7. **ALWAYS `SET QUOTED_IDENTIFIER ON`** before any SQL query
8. **ALWAYS preserve Type 0/17/26 entries** — structural markers

---

## Incident History

| Date | Failure | Root Cause |
|------|---------|------------|
| 2026-03-20 | Station crash during playlist injection | Raw SQL UPDATE on active Playlists entries |
| 2026-03-30 | 2+ hours dead air, morning show didn't play | Extro=0 crash loop + missing SourceFile + mass Played/Done update |

See: `PretoriaFields/MORNING-SHOW-INCIDENT-2026-03-30.md`
