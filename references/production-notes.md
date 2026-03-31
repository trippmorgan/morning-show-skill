# Production Notes

Learnings from the 2026-03-29 implementation session.

---

## File Transfer to Station

SCP files to `C:\temp` on the station, then use PowerShell to copy to the final location:

```bash
# Step 1: SCP to temp directory
scp file.mp3 p1-wpfq-srvs:'C:\temp\file.mp3'

# Step 2: PowerShell copy to PlayoutONE audio directory
ssh p1-wpfq-srvs 'powershell -Command "Copy-Item C:\temp\file.mp3 F:\PlayoutONE\Audio\file.mp3"'
```

Binary stdin pipe over SSH is unreliable — always use the two-step SCP + PowerShell copy approach.

---

## Audio Normalization

Normalize all generated audio to broadcast-ready levels with ffmpeg:

```bash
ffmpeg -i input.wav -af 'loudnorm=I=-16:TP=-1.5:LRA=11' -ar 44100 -ac 2 -b:a 192k output.mp3
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `I` | -16 LUFS | Integrated loudness target |
| `TP` | -1.5 dBTP | True peak limit |
| `LRA` | 11 LU | Loudness range |
| `-ar` | 44100 | Sample rate |
| `-ac` | 2 | Stereo |
| `-b:a` | 192k | Bitrate |

---

## ElevenLabs Voice Synthesis

- **Rate limiting:** 1-second sleep between API calls
- **Voice clone settings:**
  - Stability: 0.5
  - Similarity boost: 0.85
  - Style: 0.35

---

## Telegram Preview Delivery

- **File size limit:** 50MB max
- **Compression for previews:** Encode at 128kbps to stay under limit

```bash
ffmpeg -i preview.mp3 -b:a 128k preview-compressed.mp3
```

---

## Song Query & Download from Station

Query the PlayoutONE database and download audio files via SSH:

```bash
# Query songs
ssh p1-wpfq-srvs 'sqlcmd -S localhost -d PlayoutONE_Standard -E -Q "SELECT UID, Title, Artist, Filename FROM Audio WHERE ..."'

# Download a file from station
ssh p1-wpfq-srvs 'type "F:\PlayoutONE\Audio\filename.mp3"' > local-copy.mp3
```

---

## Critical Learnings — 2026-03-30 Incident

### The AutoImporter is the ONLY safe way to schedule
Never directly INSERT or UPDATE the Playlists table. PlayoutONE treats Playlists as an internal log — not a queue. The correct flow:

1. Register audio in `Audio` table (UID, TrimOut, Extro)
2. Generate a `.dpl` file
3. Drop into `F:\PlayoutONE\Import\Music Logs\` (NOT `C:\PlayoutONE\data\playlists\`)
4. AutoImporter processes it into Playlists automatically

### Extro=0 is fatal
If `Extro=0` in the Audio table, PlayoutONE considers the track 0ms long, instantly skips it, and can crash the engine. ALWAYS set:
- `TrimOut = actual_length_ms`
- `Extro = actual_length_ms - 3000` (3-second crossfade buffer)

### SourceFile must be set
PlayoutONE resolves audio by `SourceFile` in the Playlists row (not just UID). AutoImporter sets this correctly from the Audio table Filename — another reason to use AutoImporter.

### Large files cause load failures
60-minute MP3s can cause PlayoutONE to hang or crash during buffering. Break show blocks into ≤15-minute segments before registering.

### DPL drop path
- ✅ Correct: `F:\PlayoutONE\Import\Music Logs\`
- ❌ Wrong: `C:\PlayoutONE\data\playlists\` (ignored by AutoImporter)

### Publish timing
Must publish at least 30 minutes before first air hour. AutoImporter needs ~15 seconds to process.

---

## Three Rules for Content to Play (confirmed 2026-03-30)

All three must be true simultaneously. Miss any one and PlayoutONE silently skips.

### Rule 1: File on disk must match Audio.Filename exactly
```powershell
# If you register UID 90005 with Filename='90005.mp3'
# then F:\PlayoutONE\Audio\90005.mp3 must exist
# NOT MORNING-SHOW-H5.mp3, NOT 90005.wav — exactly 90005.mp3
```
Silent skip if mismatch — no error logged anywhere.

### Rule 2: TrimOut and Extro must be non-zero
```sql
-- Required after ANY Audio table insert/update
UPDATE Audio SET
    TrimIn  = 0,
    TrimOut = [length_ms],          -- must = actual duration
    Extro   = [length_ms] - 3000,   -- must = duration minus 3000ms
    Intro   = 0
WHERE UID = '[uid]';
```
AutoImporter does NOT set these. Zero values cause instant-skip + possible engine crash.

### Rule 3: DELETE before DROP (AutoImporter is first-import-wins)
```powershell
# 1. Delete existing Playlists rows
sqlcmd ... -Q "DELETE FROM Playlists WHERE Name='YYYYMMDDHH.dpl' AND Type=16"

# 2. Remove old DPL from both import and imported folders
Remove-Item "F:\PlayoutONE\Import\Music Logs\Imported\YYYYMMDDHH.dpl" -ErrorAction SilentlyContinue
Remove-Item "F:\PlayoutONE\Import\Music Logs\YYYYMMDDHH.dpl" -ErrorAction SilentlyContinue

# 3. NOW drop the new DPL
Copy-Item "C:\temp\YYYYMMDDHH.dpl" "F:\PlayoutONE\Import\Music Logs\YYYYMMDDHH.dpl"
```
If existing Playlists rows are present, AutoImporter will ignore the new DPL entirely.

## Music1 Timing Warning
Music1 runs at 3 AM daily and regenerates DPLs for all upcoming hours. If Music1 runs after you publish, it overwrites your custom entries. Always publish **after** Music1 completes. publish.sh v0.3.0 checks Music1 last activity automatically.
