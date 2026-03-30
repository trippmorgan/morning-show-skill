# Project State: morning-show

> Last updated: 2026-03-29 22:17

## Current Phase
<!-- Phases: spec | plan | execute | review | verify | ship | improve -->
**Phase:** review
**Started:** 2026-03-29

## Progress
| Wave | Task | Status | Retries | Notes |
|------|------|--------|---------|-------|
| 1 | SKILL.md + config.yaml | ✅ done | 0 | 118 lines + valid YAML |
| 1 | Reference docs (4) | ✅ done | 0 | persona, schema, production-notes, energy-arcs |
| 1 | Day templates (5) | ✅ done | 0 | Mon-Fri, 98 lines each |
| 1 | Segment templates (7) | ✅ done | 0 | open, weather, music-history, rant, quick-hits, promos, close |
| 2 | research-date.sh | ✅ done | 0 | Open-Meteo API, smoke tested ✅ |
| 2 | render-voice.sh | ✅ done | 0 | sag CLI + curl fallback |
| 2 | pull-songs.sh | ✅ done | 0 | SQL query + SSH download |
| 2 | produce-hour.sh | ✅ done | 0 | ffmpeg normalize + concat |
| 3 | publish.sh | ✅ done | 0 | SCP + SQL + rollback, dry-run verified ✅ |
| 3 | preview.sh + write-scripts.sh | ✅ done | 0 | Two scripts in one task |
| 3 | build-show.sh | ✅ done | 0 | 8-step orchestrator with gates |

## Completed Phases
| Phase | Date | Φ Score | Notes |
|-------|------|---------|-------|
| spec | 2026-03-29 | pending | Mon-Fri approved by Tripp |
| plan | 2026-03-29 | pending | 3 waves, 12 tasks |
| execute | 2026-03-29 | pending | 4 waves (inc. smoke test), 0 retries |

## Blockers
- None

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-29 | Mon-Fri not just Mon | Tripp requested daily show |
| 2026-03-29 | publish.sh uses H{hour} naming (H5=5AM) | Matches PlayoutONE schedule hours |
| 2026-03-29 | .gitignore excludes mp3s from repo | Avoid bloating GitHub with audio |
| 2026-03-29 | write-scripts.sh calls Claude CLI | LLM generates show scripts from templates + research |
