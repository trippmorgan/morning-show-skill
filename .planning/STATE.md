# Project State: morning-show

> Last updated: 2026-03-30

## Current Phase
**Phase:** execute/wave3-complete — ready for Wave 4 (tests + deploy)
**Started:** 2026-03-29
**Updated:** 2026-03-30 (post-incident)

## Progress

| Wave | Task | Status | Notes |
|------|------|--------|-------|
| 1 | SKILL.md + config.yaml | ✅ Complete | v0.2.0 — rewritten post-incident |
| 1 | Reference docs | ✅ Complete | production-notes.md updated with incident learnings |
| 1 | Day templates (Mon–Fri) | ✅ Complete | |
| 1 | Segment templates | ✅ Complete | |
| 2 | research-date.sh | ✅ Complete | Fetches weather from Open-Meteo, outputs JSON — tested 2026-03-30 |
| 2 | render-voice.sh | ✅ Complete | ElevenLabs TTS via curl or sag CLI, batch mode, dry-run — tested 2026-03-30 |
| 2 | pull-songs.sh | ✅ Complete | Search + UID + artist-title modes, proxies via super → station — tested 2026-03-30 |
| 2 | produce-hour.sh | ✅ Complete | ffmpeg normalize + concat — requires ffmpeg on run host (use station's C:\PlayoutONE\Modules\ffmpeg.exe) |
| 3 | **publish.sh** | ✅ Complete | v0.3.0 — AutoImporter flow, DELETE+drop sequence, verified working |
| 3 | preview.sh | ✅ Complete | ffmpeg compress to 128kbps, Telegram send support |
| 3 | write-scripts.sh | ✅ Complete | Per-hour Claude calls (fixed split issue), real scripts generated 2026-03-30 |
| 3 | build-show.sh | ✅ Complete | Full pipeline orchestrator with gates, --resume, --step |
| 4 | Tests | 🔲 Pending | |
| 4 | Deploy | 🔲 Pending | |

## Completed Phases
- **spec** (2026-03-29): Initial design and planning complete
- **execute/wave1** (2026-03-29): Foundation files complete
- **execute/wave3/publish** (2026-03-30): publish.sh rewritten post-incident

## Blockers
- None currently

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-29 | Use SQL UPDATE to schedule show in Playlists | Seemed simpler than AutoImporter |
| 2026-03-30 | **REVERSED: Use AutoImporter DPL flow** | Direct Playlists manipulation caused 2h15m dead air — Playlists is a log not a queue |
| 2026-03-30 | UIDs changed from 9000{1-4} to 9000{hour} | Clearer mapping: UID 90005 = 5 AM hour, 90006 = 6 AM, etc. |
| 2026-03-30 | Max segment size: ≤15 minutes | 60-minute files caused PlayoutONE buffering failures and crash loop |
| 2026-03-30 | Publish deadline: 30 min before air | AutoImporter processing time + safety margin |
| 2026-03-30 | Added /show:verify command | Post-publish verification was missing — caused silent failures |
| 2026-03-30 (test) | Must DELETE Playlists rows + remove old DPL before dropping new DPL | AutoImporter is first-import-wins — won't overwrite existing entries |
| 2026-03-30 (test) | Audio.Filename must exactly match filename on disk | PlayoutONE silently skips if Filename mismatch — no error |
| 2026-03-30 (test) | AutoImporter does NOT set TrimOut/Extro | Must be set in Audio table before DPL drop — AutoImporter reads at import time |
| 2026-03-30 (test) | Must publish AFTER Music1 finishes its run | Music1 overwrites Playlists entries when it imports — ours must be last |

## Known Issues
- research-date.sh needs web search access (Brave API) for music history/news — currently placeholder
- Silence detection not enabled on station — slow to detect dead air
- Playlist scheduler (hourly cron) can overwrite published show entries if publish is too early
- sag CLI (ElevenLabs) not available as pip package — use curl fallback in render-voice.sh

## Test Results (2026-03-30) — COMPLETE

### Round 1 (Hours 10-11)
| Test | Hour | UID | Content | Result | Root Cause |
|------|------|-----|---------|--------|------------|
| A | 10 AM | 90001 | Full hour | ❌ Instant-skip | Audio.Filename='90001.mp3' but file was 'MORNING-SHOW-H1.mp3' |
| B | 11 AM | 99901 | 10-min segment | ❌ Overwritten | Music1 regenerated DPLs for all 24 hours, replaced our entry |

### Round 2 (Hours 12-13)
| Test | Hour | UID | Content | Result | Root Cause |
|------|------|-----|---------|--------|------------|
| A v2 | 12 PM | 90001 | Full hour | ❌ Skipped | AutoImporter first-import-wins — won't overwrite existing entries |
| B v2 | 1 PM | 99901 | 10-min segment | ❌ Skipped | Same — Music1 DPLs already imported for those hours |

### Round 3 (Hours 14-15) — DELETE+Clear+DPL Sequence
| Test | Hour | UID | Content | Result | Notes |
|------|------|-----|---------|--------|-------|
| A v3 | 2 PM | 90001 | Full hour (60 min) | ✅ **PLAYED FULL FILE** | Tracked 35:38→55:51/59:52, AutoFill resumed after |
| B v3 | 3 PM | 99901 | 10-min segment | ❌ Overwritten | Playlist scheduler replaced entry before 3 PM |

### Verified Publish Sequence (Working)
1. DELETE existing Playlists entries for target hour
2. Remove old DPL from Imported/ folder
3. Drop custom DPL into import folder
4. AutoImporter picks it up and creates new entries ✅
5. **Must be the LAST step** — both Music1 and playlist scheduler can overwrite

### Key Findings
1. **Audio.Filename must match file on disk exactly** — silent skip if not (no error)
2. **AutoImporter does NOT analyze audio** — TrimOut/Extro must always be set manually in Audio table
3. **AutoImporter first-import-wins** — won't overwrite existing entries for an hour
4. **AutoImporter sets Playlists.SourceFile to DPL path** — normal behavior, same as Music1
5. **Music1 and playlist scheduler both overwrite custom DPLs** — publish must be last
6. **Full 60-min files play correctly** when markers are set right
7. **Audio table has no "Chain" column** — only Playlists does (INSERT must omit it)

## Next Steps
1. Watch 3 PM and 5 PM test results (10-min segment format)
2. Produce next Monday's show (2026-04-06) and publish Sunday evening
3. Build Wave 2 scripts (research, render, produce) to automate production
4. Build Wave 3 remainder (write-scripts.sh, build-show.sh)
