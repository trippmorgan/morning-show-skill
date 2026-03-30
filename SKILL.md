---
name: morning-show
description: Automated radio morning show production — research, script, render audio, and publish to playout system
version: 0.2.0
author: tripp
---

# Morning Show Production Skill

Produces a daily 4-hour radio morning show (Mon–Fri, 5–9 AM ET) through an automated pipeline: research trending topics, write hour-by-hour scripts, render voice segments via ElevenLabs, pull scheduled songs, assemble the final show, and publish to the station playout system.

## Commands

### `/show:full`
Run the complete pipeline end-to-end for a given date.

```
/show:full                    # produce tomorrow's show
/show:full 2026-04-01         # produce show for specific date
/show:full --hours 5,6        # produce only hours 1 and 2
```

### `/show:research`
Gather trending topics, news, weather, and date-relevant content for show material.

```
/show:research                # research for tomorrow's show
/show:research 2026-04-01     # research for specific date
```

### `/show:write`
Generate hour-by-hour show scripts from research output. Produces markdown script files (e.g., `HOUR1-MONDAY-2026-03-30.md`).

```
/show:write                   # write scripts for tomorrow
/show:write --hour 7          # write script for a single hour
/show:write --rewrite 6       # rewrite hour 2 script with new direction
```

### `/show:render`
Render voice segments from approved scripts using ElevenLabs TTS.

```
/show:render                  # render all segments for tomorrow
/show:render --hour 5         # render segments for hour 1 only
/show:render --segment intro  # render a specific segment
```

### `/show:produce`
Assemble rendered voice segments with songs, jingles, and transitions into final hour blocks. Normalizes audio to broadcast loudness standards.

```
/show:produce                 # produce all hours
/show:produce --hour 8        # produce hour 4 only
```

### `/show:preview`
Generate a low-bitrate preview and send via Telegram for approval before publishing.

```
/show:preview                 # preview all hours
/show:preview --hour 5        # preview hour 1 only
```

### `/show:publish`
Push final audio files to the station playout system (PlayoutONE) via the safe DPL/AutoImporter path.

```
/show:publish                 # publish all hours for tomorrow
/show:publish --hour 6        # publish hour 2 only
/show:publish --dry-run       # show what would happen without executing
/show:publish --rollback      # undo a previous publish
```

### `/show:status`
Show current production status for a date — which pipeline stages are complete, any errors or warnings.

```
/show:status                  # status for tomorrow's show
/show:status 2026-04-01       # status for specific date
```

### `/show:archive`
Archive completed show scripts, audio, and logs to long-term storage.

```
/show:archive                 # archive today's completed show
/show:archive 2026-03-28      # archive a specific date
```

## Pipeline

```
research → write → [approve] → render → pull songs → produce → [preview] → publish
```

| Stage        | Input                    | Output                          |
|--------------|--------------------------|---------------------------------|
| research     | date, trending APIs      | research notes (markdown)       |
| write        | research notes           | hour scripts (markdown)         |
| *approve*    | scripts                  | human approval / edit cycle     |
| render       | approved scripts         | voice segments (mp3)            |
| pull songs   | playlist/schedule        | song files from playout library |
| produce      | voice segments + songs   | final hour blocks (mp3)         |
| *preview*    | final hours              | compressed preview via Telegram |
| publish      | final hours              | files on playout server via DPL |

Bracketed stages (`[approve]`, `[preview]`) are optional human checkpoints.

## Schedule

- **Days:** Monday through Friday
- **Hours:** 5 AM, 6 AM, 7 AM, 8 AM (Eastern)
- **Timezone:** America/New_York
- **Show length:** 4 hours per day

## Persona

The show is hosted by **Dr. Johnny Fever** — scripts and voice rendering use this persona configuration from `config.yaml`.

---

## ⚠️ PUBLISH SAFETY — CRITICAL

*Updated 2026-03-30 after incident that caused 2+ hours of dead air.*

### The Safe Publish Path: DPL Files via AutoImporter

**NEVER use raw SQL INSERT/UPDATE on the Playlists table.** This has caused two station crashes (March 20 and March 30). The Playlists table is a LOG managed by PlayoutONE — not a queue you can write to directly.

The safe publish path:

```
1. Upload audio → F:\PlayoutONE\Audio\{UID}.mp3
2. Register in Audio table (SourceFile, TrimOut, Extro, Length)
3. Generate DPL files (14-column Music1 format)
4. Drop DPL files → F:\PlayoutONE\Import\Music Logs\
5. AutoImporter picks them up → creates Playlists entries automatically
```

### Timing Rules

| Rule | Detail |
|------|--------|
| **Publish 30+ minutes before target hour** | PlayoutONE loads playlists at the top of each hour. Entries must be in the DB before the boundary. |
| **Never modify current or past hours** | Modifying entries already in PlayoutONE's memory buffer crashes the engine. |
| **Ideal publish window** | Night before (8 PM–midnight) or 3+ hours before first show hour. |

### Audio Table Registration (MANDATORY)

Every morning show audio file MUST have a complete entry in the `Audio` table before it can play. Key fields:

```sql
SET QUOTED_IDENTIFIER ON;

-- Check if entry exists
SELECT UID, Title, Length, TrimOut, Extro, SourceFile 
FROM Audio WHERE UID = '{uid}';

-- Insert or update
MERGE Audio AS target
USING (VALUES ('{uid}')) AS source(UID)
ON target.UID = source.UID
WHEN MATCHED THEN UPDATE SET
    Title = '{title}',
    Artist = '{artist}',
    Filename = '{uid}.mp3',
    Length = {length_ms},
    TrimOut = {length_ms},
    Extro = {length_ms} - 5000,
    Type = 16,
    Category = 43,
    Chain = 1,
    AutoDJ = 1
WHEN NOT MATCHED THEN INSERT 
    (UID, Title, Artist, Filename, Length, TrimOut, Extro, Type, Category, Chain, AutoDJ)
    VALUES ('{uid}', '{title}', '{artist}', '{uid}.mp3', 
            {length_ms}, {length_ms}, {length_ms} - 5000, 16, 43, 1, 1);
```

**Critical fields that MUST be set:**

| Field | Value | Why |
|-------|-------|-----|
| `SourceFile` | `F:\PlayoutONE\Audio\{UID}.mp3` | Without this, PlayoutONE can't find the file |
| `TrimOut` | `= Length` | If 0, PlayoutONE thinks track is 0ms → instant skip → crash loop |
| `Extro` | `= Length - 5000` | If 0, same instant-skip crash. 5s before end allows crossfade |
| `Length` | actual duration in ms | Must match the audio file |
| `Type` | `16` | Song type |
| `Chain` | `1` | Auto-chain to next track |

### DPL File Format (14-Column Music1 Format)

DPL files MUST match the Music1 output format. PlayoutONE may reject or misparse simplified formats.

```
{UID}\tTRUE\t-1\t-1\t-2\t\tFALSE\t0\t-2\t\t\t\t\t\t{Title}|{Artist}
```

End each hour with a SOFTMARKER:
```
\tTRUE\t-1\t-1\t-2\tSOFTMARKER {HH}:59:59\t-2\t0\t-2\t\t\t\t\t\t
```

**Column map:**

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
| 14 | Display | `Title\|Artist` |

**DPL naming:** `YYYYMMDDHH.dpl` (e.g., `2026033105.dpl` for March 31 at 5 AM)

**Drop location:** `F:\PlayoutONE\Import\Music Logs\` (NOT `C:\PlayoutONE\data\playlists\`)

### File Segmentation

**Split hour-long files into 10-minute segments.** AutoImporter's audio analyzer fails on 60-minute files and sets Extro=0, causing instant-skip crash loops.

```bash
# Split a 40-minute hour block into 10-minute segments
ffmpeg -i MORNING-SHOW-H5.mp3 -f segment -segment_time 600 \
  -c copy -reset_timestamps 1 segment-%02d.mp3

# Rename to UIDs: 90101, 90102, 90103, 90104
# Each segment gets its own Audio table entry with correct markers
```

**UID scheme for segments:**
- `901{hour}{segment}` — e.g., `90151` = Hour 5, segment 1
- Or use a flat sequence: `90101`, `90102`, ... `90140` (10 segments × 4 hours)

### Absolute Rules

| ❌ NEVER | Why |
|----------|-----|
| Raw SQL INSERT/UPDATE on Playlists table | Bypasses AutoImporter, causes crashes |
| Mass-update Played/Done flags | Empties visual playlist → dead air |
| Modify entries for current/recent hours | State mismatch → engine crash |
| Delete Type 0/17/26 entries | START markers, station IDs, SOFTMARKERS are structural |
| Set Extro or TrimOut to 0 | Instant-skip crash loop on large files |
| Use `C:\PlayoutONE\data\playlists\` for imports | Wrong folder — AutoImporter watches F: drive |
| Rely on API commands (PLAY UID, LOAD PLAYLIST) | Return -255 on Standard Edition |
| Publish < 30 minutes before air time | Too late, entries won't load |

### Recovery

If the morning show fails to play:

```bash
# 1. Check Audio Engine
ssh p1-wpfq-srvs "powershell -Command \"Get-Process 'PlayoutONE Audio Engine Launcher' -EA SilentlyContinue\""

# 2. If dead, restart it
ssh p1-wpfq-srvs "schtasks /run /tn \"StartAudioEngine\""

# 3. If still silent after 15s, full restart
ssh p1-wpfq-srvs "taskkill /IM PlayoutONE.exe /F"
ssh p1-wpfq-srvs "taskkill /IM 'PlayoutONE Audio Engine Launcher.exe' /F"
sleep 5
ssh p1-wpfq-srvs "schtasks /run /tn \"StartP1Direct\""
sleep 30
ssh p1-wpfq-srvs "schtasks /run /tn \"StartAudioEngine\""

# 4. If playlist empty, regenerate with Music1
ssh p1-wpfq-srvs "schtasks /run /tn \"RunMusic1\""
# Wait 2-3 min for DPL generation
```

**DO NOT** try to fix by modifying the Playlists table directly. Run Music1 instead.

### Incident History

| Date | What Happened | Root Cause | Lesson |
|------|---------------|------------|--------|
| 2026-03-20 | Station crashed during Buffett playlist injection | Raw SQL UPDATE on active Playlists entries | Never modify in-memory entries |
| 2026-03-30 | Morning show didn't play, 2h dead air | Extro=0 crash loop + missing SourceFile + Jarvis mass-update of Played/Done | Use DPL import, set Audio markers, never mass-update flags |

See: `PretoriaFields/MORNING-SHOW-INCIDENT-2026-03-30.md` for full postmortem.
