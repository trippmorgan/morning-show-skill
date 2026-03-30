# PLAN.md — Morning Show Skill

## Global Context
Building an OpenClaw skill that automates WPFQ's Mon–Fri morning show production. Pipeline: research → write scripts → render voice (ElevenLabs) → pull songs (PlayoutONE SQL) → produce hours (ffmpeg) → publish (SCP + SQL). Dr. Johnny Fever persona. 4 hours per show (5–9 AM). Approval gates at script and preview stages.

**Tech:** Bash scripts, ElevenLabs API, sqlcmd via SSH, ffmpeg, OpenClaw message tool
**Location:** `/home/tripp/.openclaw/workspace/skills/morning-show/`
**Persona doc:** `references/dr-johnny-fever.md` (exists at `PretoriaFields/personas/`)

---

## Wave 1: Foundation (no dependencies)
*Parallel — all independent*

### Task 1: SKILL.md + config.yaml
**Files:** `SKILL.md`, `config.yaml`
**Do:**
- Write SKILL.md with skill metadata, command reference (`/show:full`, `/show:research`, `/show:write`, `/show:render`, `/show:produce`, `/show:preview`, `/show:publish`, `/show:status`, `/show:archive`), workflow overview, and usage examples
- Write config.yaml with: voice settings (ID: ZnX1f6YZpySUHtk0RDLM, stability: 0.5, similarity: 0.85, style: 0.35, model: eleven_multilingual_v2), station creds (host: p1-wpfq-srvs, audio_path: F:\PlayoutONE\Audio, temp_path: C:\temp), audio specs (-16 LUFS, 44.1kHz, stereo, 192k), show hours (5-9), Telegram target (8048875001)
- Config should be YAML with clear sections: voice, station, audio, show, delivery
**Accept:** Valid YAML parses without error. SKILL.md has all 9 commands documented.

### Task 2: Reference docs
**Files:** `references/dr-johnny-fever.md`, `references/playoutone-schema.md`, `references/production-notes.md`, `references/energy-arcs.md`
**Do:**
- Copy existing persona doc from `PretoriaFields/personas/dr-johnny-fever.md`
- Write playoutone-schema.md: Audio table columns (UID, Title, Artist, Filename, Category), Playlists table columns (Name=YYYYMMDDHH.dpl, AirTime, Order, UID, Title, Artist, Chain, Length, Len, Type, SourceFile, GIndex=YYYYMMDDHH.NNNN), the 32 NOT NULL columns with defaults, UPDATE-vs-INSERT strategy, safety rules
- Write production-notes.md: SCP transfer method (SCP to C:\temp, PowerShell copy to F:\), binary stdin unreliable, ffmpeg loudnorm filter, ElevenLabs rate limiting (1s sleep), Telegram 50MB limit
- Write energy-arcs.md: Mon–Fri energy mapping per hour (H1=grumbly→warming, H2=warming, H3=peak, H4=cruising→close), day-specific flavors (Mon=dread, Tue=groove, Wed=hump day, Thu=almost there, Fri=celebration)
**Accept:** All 4 files exist and contain accurate technical details.

### Task 3: Day templates (Mon–Fri)
**Files:** `templates/monday.md`, `templates/tuesday.md`, `templates/wednesday.md`, `templates/thursday.md`, `templates/friday.md`
**Do:**
- Each template defines: show title, hours (4 for all days, Wed note about Grunge Wed at 5 PM), energy arc per hour, segment sequence per hour (open, weather, [songs], music-history, [songs], rant, [songs], quick-hits, [songs], promos, [songs], close), music genre guidance per day
- Monday template based on the actual 2026-03-30 show we just produced (reference)
- Each day should have a slightly different flavor while keeping the same structure
- Templates use `{{date}}`, `{{weather}}`, `{{music_history}}`, `{{news}}` placeholders
**Accept:** 5 template files, each with 4-hour structure and segment sequence.

### Task 4: Segment templates
**Files:** `templates/segments/open.md`, `templates/segments/weather.md`, `templates/segments/music-history.md`, `templates/segments/rant.md`, `templates/segments/quick-hits.md`, `templates/segments/promos.md`, `templates/segments/close.md`
**Do:**
- Each template has: persona instructions (reference dr-johnny-fever.md), tone/energy guidance, duration target (in seconds), content structure, example from the 2026-03-30 show, placeholder variables
- open.md: greeting, date, time, weather tease, energy-appropriate intro (~45s)
- weather.md: Albany GA forecast, sarcastic commentary (~25s)
- music-history.md: 2-3 "this day in music" facts with Fever commentary (~60s)
- rant.md: observational humor topic, build-peak-resolve structure (~60s)
- quick-hits.md: news, birthdays, sports, local (~50s)
- promos.md: Grunge Wednesday, Todd Fox Sunday, Brewery plug (~50s)
- close.md: hour sign-off or show sign-off, next-hour tease (~25s)
**Accept:** 7 segment templates with examples and placeholders.

---

## Wave 2: Core Scripts (depends on Wave 1 for config.yaml)

### Task 5: research-date.sh
**Files:** `scripts/research-date.sh`
**Do:**
- Takes `--date YYYY-MM-DD` argument (defaults to tomorrow)
- Fetches: music history (web search thisdayinmusic.com + songfacts.com), Albany GA weather (Open-Meteo API), trending news (web search), celebrity birthdays
- Outputs JSON to stdout: `{ "date": "...", "day": "Monday", "weather": {...}, "music_history": [...], "birthdays": [...], "news": [...] }`
- Bash, `set -euo pipefail`, ANSI colors, `--help` flag
- Uses `curl` for APIs, outputs clean JSON via `jq`
**Accept:** Script runs, produces valid JSON with all sections populated for a given date.
**Test:** Run for 2026-03-30, verify Clapton birthday appears in music_history.

### Task 6: render-voice.sh
**Files:** `scripts/render-voice.sh`
**Do:**
- Takes `--input <text_file_or_stdin>` `--output <mp3_path>` `--config <config.yaml>`
- Reads voice settings from config.yaml (voice_id, model, stability, similarity, style)
- Reads API key from `ELEVENLABS_API_KEY` env var or `~/.env`
- Calls ElevenLabs API via `curl` (or `sag` CLI if available)
- 1-second sleep between calls (rate limit)
- Batch mode: `--batch-dir <dir>` renders all .txt files in directory to .mp3
- `--dry-run` prints what would be rendered without calling API
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Renders a test phrase to MP3 in Johnny Fever's voice.
**Test:** Render "Testing one two three" and verify output is valid MP3.

### Task 7: pull-songs.sh
**Files:** `scripts/pull-songs.sh`
**Do:**
- Takes `--songs "Artist - Title, Artist - Title, ..."` or `--uids "355,3426,..."` `--output-dir <dir>`
- Queries PlayoutONE Audio table via `ssh p1-wpfq-srvs "sqlcmd -S localhost -d PlayoutONE_Standard -E ..."`
- For artist/title search: fuzzy match with LIKE queries
- Downloads audio via `ssh p1-wpfq-srvs "type \"F:\\PlayoutONE\\Audio\\{filename}\""` > local file
- Outputs JSON manifest of pulled songs: `[{ "uid": "355", "title": "Cocaine", "artist": "Eric Clapton", "file": "cocaine.mp3", "duration_ms": 213833 }]`
- Handles both .mp3 and .wav source files
- `--search "clapton"` mode: list matching songs without downloading
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Pulls at least 3 songs from station, outputs valid JSON manifest.
**Test:** Pull "Cocaine" by Eric Clapton (UID 355), verify MP3 is valid.

### Task 8: produce-hour.sh
**Files:** `scripts/produce-hour.sh`
**Do:**
- Takes `--talk-dir <dir>` `--songs-dir <dir>` `--sequence <json>` `--output <mp3_path>` `--config <config.yaml>`
- Sequence JSON: `[{"type":"talk","file":"01-open.mp3"},{"type":"song","file":"cocaine.mp3"},...]`
- Normalizes all inputs to audio specs from config (ffmpeg loudnorm)
- Concatenates in sequence order
- Outputs single MP3 file (full hour block)
- Reports duration, file size
- `--preview` flag: also outputs 128kbps preview version
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Takes talk segments + songs, produces a single normalized MP3.
**Test:** Concat 2 talk segments + 2 songs, verify output plays correctly.

---

## Wave 3: Integration Scripts (depends on Wave 2)

### Task 9: publish.sh
**Files:** `scripts/publish.sh`
**Do:**
- Takes `--date YYYY-MM-DD` `--hours 5,6,7,8` `--audio-dir <dir>` `--config <config.yaml>`
- Pre-flight: SSH to station, verify connectivity and PlayoutONE processes running
- Upload: SCP hour blocks to `C:\temp\MORNING-SHOW-H{N}.mp3`, then PowerShell copy to `F:\PlayoutONE\Audio\`
- Schedule: UPDATE one existing Playlists row per hour (repurpose), DELETE remaining rows for those hours
- Uses `SET QUOTED_IDENTIFIER ON` for all SQL
- Verify: query back the scheduled entries, confirm 4 rows with correct SourceFile
- `--dry-run`: show what would be done without executing
- `--rollback`: restore deleted entries (un-delete) and remove show entries
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Publishes show to station, verifies schedule shows 4 Dr. Johnny Fever entries.
**Test:** Dry-run for 2026-03-31, verify SQL output looks correct.

### Task 10: preview.sh
**Files:** `scripts/preview.sh`
**Do:**
- Takes `--audio-dir <dir>` `--config <config.yaml>`
- Compresses each hour to 128kbps for Telegram (under 50MB)
- Sends via OpenClaw message tool (or logs the command for manual send)
- Shows duration, file size for each hour
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Compresses hour blocks to under 50MB each.

### Task 11: write-scripts.sh
**Files:** `scripts/write-scripts.sh`
**Do:**
- Takes `--day monday` `--date YYYY-MM-DD` `--research <json_file>` `--config <config.yaml>` `--output-dir <dir>`
- Loads day template + segment templates
- Fills in research data (music history, weather, news, birthdays)
- Uses LLM (via `claude --print` or OpenClaw session) to generate scripts in Johnny Fever voice
- Outputs: `HOUR{1-4}-{DAY}-{DATE}.md` files
- Each script has segment markers for render-voice.sh to parse
- `--dry-run`: show template + research without LLM call
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Generates 4 hour scripts that follow persona and contain date-specific content.

### Task 12: build-show.sh (master orchestrator)
**Files:** `scripts/build-show.sh`
**Do:**
- Takes `--day monday` `--date YYYY-MM-DD` (defaults to tomorrow + its day name)
- Rejects weekends unless `--force`
- Calls pipeline in order: research-date.sh → write-scripts.sh → [PAUSE for approval] → render-voice.sh → pull-songs.sh → produce-hour.sh → [PAUSE for preview] → publish.sh
- Approval gates: prints scripts summary, waits for user input (or `--auto-approve` for testing)
- Creates show archive in `shows/YYYY-MM-DD/`
- Logs timing and status to manifest.json
- `--resume` flag: restart from last completed step
- `--step <name>` flag: run just one step
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Full pipeline produces and publishes a show with 2 approval pauses.

---

## Wave 4: Polish + Deploy

### Task 13: Tests + validation
**Files:** `tests/test-config.sh`, `tests/test-research.sh`, `tests/test-render.sh`, `tests/test-pipeline.sh`
**Do:**
- test-config.sh: validates config.yaml schema
- test-research.sh: runs research-date.sh for known date, checks JSON structure
- test-render.sh: dry-run of render-voice.sh
- test-pipeline.sh: end-to-end dry-run of build-show.sh
- All tests use assert functions, exit 0/1
**Accept:** All tests pass.

### Task 14: Sync + deploy
**Files:** `scripts/sync-to-pretoria.sh`
**Do:**
- rsync skill directory to Pretoria node (djjarvis)
- Verify config.yaml is correct on target
- Test SSH connectivity to station from Pretoria
- Bash, `set -euo pipefail`, ANSI colors, `--help`
**Accept:** Skill runs identically on SuperServer and Pretoria node.

---

## Dependency DAG
```
Wave 1 (parallel): T1, T2, T3, T4
Wave 2 (parallel, needs W1): T5, T6, T7, T8
Wave 3 (parallel, needs W2): T9, T10, T11, T12
Wave 4 (sequential, needs W3): T13 → T14
```

## Model Selection
| Task | Model | Rationale |
|------|-------|-----------|
| T1-T4 (docs/templates) | Sonnet | Pattern matching, structured writing |
| T5-T8 (core scripts) | Sonnet | Code generation, moderate complexity |
| T9-T12 (integration) | Sonnet | Code gen with system integration |
| T13-T14 (tests/deploy) | Sonnet | Mechanical |

## Estimated Effort
- Wave 1: ~15 min (4 parallel tasks)
- Wave 2: ~20 min (4 parallel tasks, more complex)
- Wave 3: ~25 min (4 tasks, integration complexity)
- Wave 4: ~10 min (2 sequential tasks)
- **Total: ~70 min** (vs ~4 hours doing it manually)
