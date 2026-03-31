---
name: morning-show
description: Automated radio morning show production — research, script, render audio, and publish to playout system
version: 0.4.0
author: tripp
updated: 2026-03-30
updated: 2026-03-30
---

# Morning Show Production Skill

Produces a daily 4-hour radio morning show (Mon–Fri, 5–9 AM ET) through an automated pipeline: research trending topics, write hour-by-hour scripts, render voice segments via ElevenLabs, pull scheduled songs, assemble the final show, and publish to the station playout system via PlayoutONE's AutoImporter.

> **⚠️ CRITICAL — Read Before Publishing**
> The publish pipeline uses the AutoImporter flow. Never directly INSERT or UPDATE the Playlists table. See [Publishing Rules](#publishing-rules) below.

---

## Commands

### `/show:full`
Run the complete pipeline end-to-end for a given date.

```
/show:full                    # produce tomorrow's show
/show:full 2026-04-07         # produce show for specific date
/show:full --hours 5,6        # produce only hours 1 and 2
```

### `/show:research`
Gather trending topics, news, weather, and date-relevant content for show material.

```
/show:research                # research for tomorrow's show
/show:research 2026-04-07     # research for specific date
```

### `/show:write`
Generate hour-by-hour show scripts from research output.

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
Assemble rendered voice segments with songs into final hour blocks. Normalizes to broadcast loudness (-16 LUFS).

```
/show:produce                 # produce all hours
/show:produce --hour 8        # produce hour 4 only
```

### `/show:preview`
Generate a 128kbps preview and send via Telegram for approval before publishing.

```
/show:preview                 # preview all hours
/show:preview --hour 5        # preview hour 1 only
```

### `/show:publish`
Push final audio files to the station playout system via AutoImporter.

```
/show:publish                 # publish all hours for tomorrow
/show:publish --hour 6        # publish hour 2 only
/show:publish --dry-run       # validate without executing
```

### `/show:status`
Show current production status — which pipeline stages are complete, any errors or warnings.

```
/show:status                  # status for tomorrow's show
/show:status 2026-04-07       # status for specific date
```

### `/show:verify`
Query PlayoutONE to confirm show rows are correctly installed in the Playlists table.

```
/show:verify                  # verify tomorrow's show
/show:verify 2026-04-07       # verify specific date
```

### `/show:archive`
Archive completed show scripts, audio, and logs.

```
/show:archive                 # archive today's completed show
/show:archive 2026-03-30      # archive a specific date
```

---

## Pipeline

```
research → write → [approve] → render → pull songs → produce → [preview] → publish → verify
```

| Stage | Input | Output | Script |
|---|---|---|---|
| research | date, APIs | research notes (markdown) | `research-date.sh` |
| write | research notes | hour scripts (markdown) | `write-scripts.sh` |
| *approve* | scripts | human approval / edits | — |
| render | approved scripts | voice segments (mp3) | `render-voice.sh` |
| pull songs | playlist/schedule | song files from station library | `pull-songs.sh` |
| produce | voice segments + songs | final hour blocks (mp3) | `produce-hour.sh` |
| *preview* | final hours | Telegram preview | `preview.sh` |
| publish | final hours | registered in Audio table, DPL dropped to AutoImporter | `publish.sh` |
| verify | — | confirmation Playlists rows exist | `publish.sh` (built-in) |

Bracketed stages (`[approve]`, `[preview]`) are optional human checkpoints.

---

## Schedule

- **Days:** Monday through Friday
- **Hours:** 5 AM, 6 AM, 7 AM, 8 AM (Eastern)
- **Timezone:** America/New_York
- **Show length:** 4 hours per day
- **Publish deadline:** No later than 30 minutes before first air hour (4:30 AM latest)
- **Recommended:** Publish Saturday or Sunday evening before the Monday show

---

## Publishing Rules

> These rules were established after the 2026-03-30 broadcast failure. Follow them exactly.

### ✅ Correct Flow (AutoImporter)
1. Copy audio to `F:\PlayoutONE\Audio\` as UID-named files (e.g. `90005.mp3`)
2. Register UID in `Audio` table with **correct TrimOut and Extro markers**
3. Generate a `.dpl` file per hour (14-column Music1 format)
4. Drop DPL files into `F:\PlayoutONE\Import\Music Logs\` — AutoImporter handles the rest
5. Wait 15 seconds, then verify Playlists rows exist

### ❌ Never Do This
- **Never INSERT or UPDATE the Playlists table directly** — it is a log, not a queue
- **Never leave Extro=0** in the Audio table — causes instant-skip and PlayoutONE crash
- **Never leave SourceFile blank** in Playlists rows — file won't play
- **Never drop DPL files to `C:\PlayoutONE\data\playlists\`** — that path is ignored by AutoImporter
- **Never publish less than 30 minutes before air** — AutoImporter needs time to process
- **Never publish before Music1 and playlist scheduler have finished** — they will overwrite your entries

### ⚡ Timing: Who Overwrites What
| System | When | Effect |
|--------|------|--------|
| Music1 | Runs periodically, generates 24 DPLs | Overwrites ALL hours if imported after our DPL |
| Playlist scheduler | Hourly cron | Replaces entries for upcoming hours with genre rotation |
| AutoImporter | Continuous, watches import folder | First-import-wins — won't overwrite existing entries |

**Solution:** Publish AFTER all automated systems have run. Ideal window: 30-60 min before first show hour (e.g., 4:00-4:30 AM for a 5 AM show). The DELETE+clear+DPL sequence ensures our entries win.

### UID Assignment
| Show Hour | Air Time | UID |
|---|---|---|
| Hour 1 | 5 AM | 90005 |
| Hour 2 | 6 AM | 90006 |
| Hour 3 | 7 AM | 90007 |
| Hour 4 | 8 AM | 90008 |

### Audio Marker Requirements
Every Audio table row for show content must have:
```
TrimIn  = 0
TrimOut = [actual_length_ms]
Extro   = [actual_length_ms] - 3000   (3-second crossfade buffer)
Intro   = 0
```
`publish.sh` handles this automatically. If registering manually, do not skip this step.

### File Size
Keep individual show blocks to **≤15 minutes per file**. Larger files risk PlayoutONE buffering failures. Split 60-minute hours into four 15-minute segments if needed. The publish script supports multiple segments per hour.

---

## Persona

The show is hosted by **Dr. Johnny Fever** — grumpy Gen X radio veteran, deep music knowledge, dry sarcasm, genuine warmth underneath. Full persona reference in `references/dr-johnny-fever.md`.

---

## File Structure

```
skills/morning-show/
├── SKILL.md                        # This file
├── config.yaml                     # Voice, station, audio settings
├── scripts/
│   ├── build-show.sh               # Master orchestrator
│   ├── research-date.sh            # Fetch news, weather, music history
│   ├── write-scripts.sh            # LLM script generation
│   ├── render-voice.sh             # ElevenLabs TTS rendering
│   ├── pull-songs.sh               # Download songs from station
│   ├── produce-hour.sh             # Assemble + normalize hour blocks
│   ├── preview.sh                  # Compress + send Telegram preview
│   └── publish.sh                  # Upload, register, drop DPL, verify
├── templates/
│   ├── monday.md                   # Day-specific show template
│   ├── tuesday.md
│   ├── wednesday.md
│   ├── thursday.md
│   ├── friday.md
│   └── segments/
│       ├── open.md
│       ├── weather.md
│       ├── music-history.md
│       ├── rant.md
│       ├── quick-hits.md
│       ├── promos.md
│       └── close.md
└── references/
    ├── dr-johnny-fever.md          # Persona reference
    ├── playoutone-schema.md        # DB schema + mutation rules
    ├── production-notes.md         # Technical lessons learned
    └── energy-arcs.md              # Hour-by-hour energy mapping
```

---

## Planning Files

After reading this SKILL.md, always read the `.planning/` files before executing any task:

1. **`.planning/SPEC.md`** — Full technical specification, acceptance criteria, data flow, external dependencies, edge cases
2. **`.planning/PLAN.md`** — Wave-by-wave build plan, exact task definitions with accept criteria and test cases
3. **`.planning/STATE.md`** — Current build state, completed tasks, decisions log, test results, next steps
4. **`.planning/TRACES.md`** — Execution traces, failures, review issues

These files are the ground truth for what exists, what's pending, and how to build it correctly.

---

## Quick Start — Next Show

```bash
# 1. Produce and publish next Monday's show (run Sunday evening)
./scripts/build-show.sh --date 2026-04-06

# 2. Publish only (if audio already produced)
./scripts/publish.sh \
  --date 2026-04-06 \
  --audio-dir ./shows/2026-04-06/ \
  --config config.yaml

# 3. Verify installation
./scripts/publish.sh --date 2026-04-06 --dry-run

# 4. Check station confirmed the schedule
ssh p1-wpfq-srvs "sqlcmd -S localhost -d PlayoutONE_Standard -E -Q \
  \"SELECT Name,UID,Title,SourceFile,MissingAudio FROM Playlists \
   WHERE Name LIKE '20260406%' AND UID LIKE '9000%'\""
```

---

## Incident History

| Date | Incident | Resolution | Reference |
|---|---|---|---|
| 2026-03-30 | Morning show failed to air — 2h 15min dead air | publish.sh rewritten to use AutoImporter flow | `docs/INCIDENT-2026-03-30-MORNING-SHOW.md` |

---

## Changelog

### v0.4.0 — 2026-03-30 (merged Jarvis Prime + Pretoria)
- **Canonical source unified** — merged SuperServer battle-tested publish.sh with Pretoria's v0.3.0 structure
- Added verified playback test results (full 60-min file confirmed playing on air)
- Added DELETE+clear+DPL publish sequence (verified working in production)
- Added playlist scheduler overwrite warning — publish must be the LAST automated step
- Confirmed: AutoImporter sets Playlists.SourceFile to DPL path (normal, same as Music1)
- Confirmed: PlayoutONE resolves files via Audio.Filename + configured audio directory
- Added Music1 + playlist scheduler timing documentation
- Extro offset standardized to 3000ms
- Wednesday April 1 show scripts produced by Pretoria (4 hours, pending approval)

### v0.3.0 — 2026-03-30 (post-testing)
- **publish.sh v3** — adds DELETE+clear sequence before DPL drop (AutoImporter first-import-wins)
- Added Music1 timing guard — waits for Music1 to finish before dropping DPLs
- Added disk filename verification step — catches Audio.Filename mismatch before it causes silent skip
- MissingAudio flag now checked in verification step
- Confirmed: AutoImporter does NOT set TrimOut/Extro — must be set in Audio table manually

### v0.2.0 — 2026-03-30
- **publish.sh completely rewritten** — now uses AutoImporter DPL flow instead of direct SQL
- Added `TrimOut`/`Extro` audio marker requirements to publish flow
- UID scheme changed: hours use UIDs 90005–90008 (matching air hour)
- DPL drop path corrected: `F:\PlayoutONE\Import\Music Logs\` (not `C:\` path)
- Added `/show:verify` command
- Added Publishing Rules section with hard constraints from incident
- File size limit documented (≤15 min per segment)
- Publish deadline documented (30 min before air)

### v0.1.0 — 2026-03-29
- Initial skill scaffold — pipeline structure, Dr. Johnny Fever persona, config, templates
