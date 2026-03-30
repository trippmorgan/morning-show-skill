---
name: morning-show
description: Automated radio morning show production — research, script, render audio, and publish to playout system
version: 0.1.0
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
Push final audio files to the station playout system (PlayoutONE).

```
/show:publish                 # publish all hours for tomorrow
/show:publish --hour 6        # publish hour 2 only
/show:publish --force         # overwrite existing files in playout
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
| publish      | final hours              | files on playout server         |

Bracketed stages (`[approve]`, `[preview]`) are optional human checkpoints.

## Schedule

- **Days:** Monday through Friday
- **Hours:** 5 AM, 6 AM, 7 AM, 8 AM (Eastern)
- **Timezone:** America/New_York
- **Show length:** 4 hours per day

## Persona

The show is hosted by **Dr. Johnny Fever** — scripts and voice rendering use this persona configuration from `config.yaml`.
