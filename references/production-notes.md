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
