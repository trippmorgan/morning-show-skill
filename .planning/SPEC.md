# SPEC.md — Morning Show Production Skill

## Project Summary
An OpenClaw skill that automates the full production pipeline for WPFQ's Monday–Friday morning show with Dr. Johnny Fever — from date-specific research through script writing, voice rendering, music selection, audio production, and PlayoutONE scheduling. Replaces the 30+ manual steps performed on 2026-03-29 with a single command flow. Show runs 5 days a week (Mon–Fri), 5–9 AM ET.

## Goals
1. **One-command show production:** `/show:full monday` researches the date, writes scripts for all hours, renders voice via ElevenLabs, pulls songs from PlayoutONE library, produces normalized hour blocks, and publishes to the station schedule — with human approval gates at script and preview stages.
2. **Reusable daily templates:** Each day of the week can have its own energy arc, segment mix, and genre flavor.
3. **Dr. Johnny Fever persona consistency:** All scripts follow the persona doc — grumpy, sarcastic, music-encyclopedic, warm underneath, never breaks the AI fourth wall.
4. **Broadcast-ready audio:** All output normalized to -16 LUFS, 44.1kHz, stereo, 192kbps MP3.
5. **Safe station integration:** Follows all PlayoutONE rules (UPDATE future hours only, preserve Type=0/17/26 markers, never touch currently-playing).
6. **Multi-node deployment:** Skill lives on SuperServer (primary) and syncs to Pretoria node (station-adjacent).

## Non-Goals
- Live DJ interaction (this is pre-produced content)
- Music1 integration (we bypass Music1 entirely for show hours)
- Multiple DJ personas (Johnny Fever only for v1; other personas are future)
- Automated show scheduling without human approval (always needs blessing)

## Architecture

### Directory Structure
```
skills/morning-show/
├── SKILL.md                    # Skill definition + command reference
├── config.yaml                 # Voice IDs, API keys, station creds, defaults
├── templates/
│   ├── monday.md               # Monday template (4 hours, energy arc)
│   ├── tuesday.md              # Tuesday template
│   ├── wednesday.md            # Wednesday (shorter — Grunge Wed at 5 PM)
│   ├── thursday.md             # Thursday template
│   ├── friday.md               # Friday template
│   └── segments/
│       ├── open.md             # Show open template
│       ├── weather.md          # Weather segment template
│       ├── music-history.md    # "This day in music" template
│       ├── rant.md             # Rant segment template
│       ├── quick-hits.md       # News/birthdays/sports template
│       ├── promos.md           # Show promos + brewery plug
│       └── close.md            # Hour/show close template
├── scripts/
│   ├── build-show.sh           # Full pipeline orchestrator
│   ├── research-date.sh        # Web search: music history, weather, news
│   ├── write-scripts.sh        # LLM script generation with persona
│   ├── render-voice.sh         # ElevenLabs TTS rendering
│   ├── pull-songs.sh           # Query PlayoutONE DB + pull audio via SSH
│   ├── produce-hour.sh         # ffmpeg normalize + concat talk+music
│   ├── publish.sh              # Upload to station + SQL schedule update
│   └── preview.sh              # Compress + send to Telegram for review
├── references/
│   ├── dr-johnny-fever.md      # Full persona doc (existing)
│   ├── playoutone-schema.md    # SQL schema, GIndex format, rules
│   ├── production-notes.md     # Learnings from 3/29 production run
│   └── energy-arcs.md          # Hour-by-hour energy mapping
└── shows/                      # Archive of produced shows
    └── YYYY-MM-DD/
        ├── manifest.json       # Build metadata, timing, Φ score
        ├── scripts/            # Approved scripts
        └── audio/              # Final hour blocks (or symlinks)
```

### Data Flow
```
research-date.sh → JSON (music facts, weather, news, birthdays)
       ↓
write-scripts.sh → HOUR{1-4}-{DAY}.md (uses template + persona + research)
       ↓  [GATE: Human approves scripts]
render-voice.sh → segment MP3s (ElevenLabs, Johnny Fever voice)
       ↓
pull-songs.sh → song MP3s (from PlayoutONE Audio library via SSH)
       ↓
produce-hour.sh → FULL-HOUR{1-4}-COMPLETE.mp3 (normalized, talk+music)
       ↓  [GATE: Human previews audio]
publish.sh → uploads to station, updates Playlists SQL table
```

### External Dependencies
| System | Connection | Credentials |
|--------|-----------|-------------|
| ElevenLabs API | HTTPS | API key in `~/.env` on Voldemort (or config.yaml) |
| PlayoutONE SQL | `sqlcmd -E` via SSH to p1-wpfq-srvs | Windows integrated auth |
| PlayoutONE Audio | SCP to `C:\temp` → copy to `F:\PlayoutONE\Audio\` | SSH key auth |
| Weather API | Open-Meteo (no key) | Albany, GA coords |
| Music History | Brave web search | thisdayinmusic.com, songfacts.com |
| Telegram | OpenClaw message tool | For preview delivery |

### Voice Configuration
| Parameter | Value | Notes |
|-----------|-------|-------|
| Voice ID | ZnX1f6YZpySUHtk0RDLM | Dr. Johnny Fever clone |
| Model | eleven_multilingual_v2 | Best quality |
| Stability | 0.5 | Slight variation = natural |
| Similarity Boost | 0.85 | High fidelity to clone |
| Style | 0.35 | Some expressiveness |
| Format | mp3_44100_128 | Station-compatible |

### Audio Production Standards
| Parameter | Value |
|-----------|-------|
| Sample Rate | 44,100 Hz |
| Channels | Stereo |
| Bitrate | 192 kbps (production), 128 kbps (preview) |
| Loudness | -16 LUFS integrated |
| True Peak | -1.5 dBTP |
| ffmpeg filter | `loudnorm=I=-16:TP=-1.5:LRA=11` |

### PlayoutONE Integration Rules (CRITICAL)
1. Only UPDATE/INSERT entries for FUTURE hours (never current or recently-loaded)
2. Preserve Type=0 (markers), Type=17 (station IDs), Type=26 (ads)
3. GIndex format: `YYYYMMDDHH.NNNN` (date-hour + 4-digit sequence)
4. Name format: `YYYYMMDDHH.dpl`
5. Repurpose existing rows via UPDATE (INSERT requires 32+ NOT NULL columns)
6. SourceFile column points to filename in `F:\PlayoutONE\Audio\`
7. Set Chain=1, Type=16, Deleted=0, Status=0 for show blocks

## Commands
| Command | Action |
|---------|--------|
| `/show:full <day>` | Full pipeline with approval gates |
| `/show:research <date>` | Research only — music history, weather, news |
| `/show:write <day>` | Write scripts using template + research |
| `/show:render` | ElevenLabs TTS all segments |
| `/show:produce` | Pull songs + build hour blocks |
| `/show:preview` | Compress + send to Telegram |
| `/show:publish` | Upload + schedule in PlayoutONE |
| `/show:status` | Show current production state |
| `/show:archive` | Archive current show to `shows/` directory |

## Constraints
- All scripts: bash, `set -euo pipefail`, ANSI colors, `--help` flag
- ElevenLabs rate limit: ~1 req/sec (1-second sleep between renders)
- Max Telegram file: 50 MB (compress previews to 128kbps)
- Binary transfer to Windows: use SCP to `C:\temp`, then PowerShell copy (stdin pipe unreliable)
- Show hours: 5 AM – 9 AM ET (4 hours, configurable)
- Each hour block: 35-60 minutes of content (remaining time filled by PlayoutONE AutoFill)

## Edge Cases
- **Station offline:** publish.sh checks station connectivity before SQL updates
- **ElevenLabs quota exhausted:** Fallback to OpenClaw built-in TTS (different voice, flag for human review)
- **Song not in library:** Script should suggest alternatives from same artist/era, or skip with placeholder
- **Duplicate show date:** Warn if show already exists for target date, require `--force`
- **Weekend shows:** No morning show on Sat/Sun (regular rotation). Skill should reject weekend dates unless `--force`

## Acceptance Criteria
1. `/show:full monday` produces a complete 4-hour show with < 5 manual interventions (2 approval gates + date confirmation)
2. All audio passes broadcast standards (-16 LUFS ±1, no clipping)
3. Scripts follow Dr. Johnny Fever persona consistently
4. Show is correctly scheduled in PlayoutONE SQL for the target date
5. Archive captures full build metadata (timing, segments, songs, Φ score)
6. Skill deploys identically on SuperServer and Pretoria node
