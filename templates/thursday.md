# Thursday Morning Show Template

**Station:** WPFQ 96.7 — Pretoria Fields Radio, Albany GA
**DJ:** Dr. Johnny Fever / Pretoria
**Show:** Almost Friday
**Date:** {{date}} — {{day_name}}
**Hours:** 5:00 AM – 9:00 AM

---

## Day Vibe

Thursday is Friday's opening act. The anticipation is real — you can taste the weekend. Energy is up, the mood is lighter, people are making plans. Lean into the "almost there" feeling. The vibe is upbeat, a little restless, forward-looking. We're not celebrating yet, but the countdown is on.

## Genre Guidance

Upbeat rock, new wave, indie rock. The Killers, Talking Heads, The Cars, Blondie, Franz Ferdinand, Arctic Monkeys, The Strokes, Pixies, Weezer, INXS, Depeche Mode. Angular, energetic, rhythmic. Music that moves but thinks. Save the full party mode for Friday.

## Cross-Promotions

- **Grunge Wednesday** recap — "Hope you caught Tripp last night"
- **Throwback Country Sunday** with Todd Fox, 4:30–8 PM on WPFQ 96.7
- **Pretoria Fields Brewery** — Thursday night is basically the weekend, right?

---

## Hour 1 (5:00–6:00 AM) — "The Countdown Begins"

**Energy:** Grumbly but with an undercurrent of anticipation. One more day after this.

| Time | Segment | Notes |
|------|---------|-------|
| 5:00 | **Open** | "{{day_name}}, {{date}}. One day stands between you and the weekend. One. WPFQ 96.7, Pretoria Fields Radio. Let's do this." |
| 5:04 | **Weather** | {{weather_desc}}. High of {{weather_high}}, low of {{weather_low}}. Frame it in terms of weekend preview — "looking ahead to the weekend..." |
| 5:06 | **Song block** | 3 songs — new wave / indie rock. Energetic but not overwhelming at 5 AM. |
| 5:20 | **Music History** | {{music_history}} — today in music history. |
| 5:24 | **Song block** | 3 songs — building the upbeat tension. |
| 5:38 | **Rant** | Thursday rant. The cruelty of Thursday — so close yet so far. Or: ranking the days of the week. Anticipation-fueled energy. |
| 5:42 | **Song block** | 3 songs. |
| 5:52 | **News / Quick Hits** | {{news}} — headlines. Mention weekend forecast if available. |
| 5:55 | **Song block** | 2 songs. |
| 5:58 | **Promos** | Throwback Country Sunday with Todd Fox. Pretoria Fields Brewery for the weekend. |
| 5:59 | **Song** | 1 song to close the hour. |

---

## Hour 2 (6:00–7:00 AM) — "Building Momentum"

**Energy:** Warming up fast. Thursday mornings have a natural lean-forward energy.

| Time | Segment | Notes |
|------|---------|-------|
| 6:00 | **Open** | "Six o'clock, Thursday on the Fields. Momentum is building. WPFQ 96.7." Weather update. Grunge Wednesday recap — "hope you caught Tripp last night." |
| 6:03 | **Song block** | 2 songs — uptempo indie/new wave. |
| 6:12 | **Feature: "Weekend Radar"** | What's happening this weekend in Albany and SW Georgia. Local events, shows, brewery happenings, things worth knowing about. Community-forward. |
| 6:18 | **Song block** | 3 songs — angular, rhythmic, fun. |
| 6:30 | **Rant** | Energized rant. Pop culture, music hot takes, or Thursday-specific observations. The mood is up. |
| 6:34 | **Song block** | 2 songs. |
| 6:42 | **Quick Hits** | {{birthdays}} — birthdays, strange news, one-liners. |
| 6:46 | **Song block** | 2 songs. |
| 6:54 | **Close** | Tease H3. Promo Pretoria Fields Brewery. |

---

## Hour 3 (7:00–8:00 AM) — "Friday Eve"

**Energy:** Peak. Full Thursday energy. The anticipation is electric. This is the hour where people start making weekend plans in their heads.

| Time | Segment | Notes |
|------|---------|-------|
| 7:00 | **Open** | "Seven AM, Friday Eve. WPFQ 96.7, Pretoria Fields Radio. One more day." Weather. |
| 7:03 | **Song block** | 2 songs — peak energy new wave/indie. The kind of songs that make you drive faster. |
| 7:12 | **Feature: "New Music Thursday"** | Spotlight a new release or upcoming album. New singles drop on Fridays so Thursday is preview day. What's worth your ears this week? |
| 7:18 | **Song block** | 3 songs — keep the energy rolling. |
| 7:30 | **Rant** | Peak rant. Animated, maybe a little reckless. Hot takes welcome. The almost-Friday confidence is real. |
| 7:34 | **Song block** | 3 songs. |
| 7:46 | **Quick Hits** | News, local events, weekend preview continued. |
| 7:50 | **Song block** | 2 songs. |
| 7:56 | **Close** | "One more day. You're so close. Throwback Country Sunday with Todd Fox this weekend, 4:30 to 8." |

---

## Hour 4 (8:00–9:00 AM) — "The Final Push"

**Energy:** Winding down from peak but staying warm. Sending people into their last full workday with fuel in the tank.

| Time | Segment | Notes |
|------|---------|-------|
| 8:00 | **Open** | "Last hour, Thursday morning. Let's finish strong. WPFQ 96.7." Weather: {{weather_high}}/{{weather_low}}. |
| 8:03 | **Song block** | 2 songs — still upbeat, slightly mellower. |
| 8:12 | **Feature: "Throwback Minute"** | Quick throwback — a song or moment from this week in a past decade. Keep it tight, one story, one track. |
| 8:17 | **Song block** | 2 songs. |
| 8:25 | **Rant** | Final rant. Forward-looking. What are you doing this weekend? Keep it real, keep it brief. |
| 8:28 | **Song block** | 3 songs — landing pattern. |
| 8:42 | **Quick Hits** | Final headlines, weekend weather outlook. |
| 8:45 | **Song block** | 2 songs. |
| 8:54 | **Close** | "Thursday — done. Tomorrow's Friday and we're gonna celebrate it. Throwback Country Sunday with Todd Fox, 4:30 to 8. Hit up Pretoria Fields Brewery this weekend — you've earned it. I'm Dr. Johnny Fever. WPFQ 96.7, Pretoria Fields Radio. See you tomorrow for the big one." |
| 8:56 | **Song** | 1 closer — something that says "tomorrow is gonna be good." |

---

## CRITICAL: Song Markers

Every song block in the schedule MUST be written as explicit `[SONG: Artist - Title]` markers.
These are machine-parsed. The pipeline will fail without them.

Example:
```
### SEGMENT 2: SONG BLOCK
[SONG: Pearl Jam - Black]
[SONG: Soundgarden - Black Hole Sun]
[SONG: Alice in Chains - Down in a Hole]
```

Songs MUST exist in the PlayoutONE database. Stick to well-known tracks from the genre guidance.
Each hour needs 8-12 songs total, distributed across 3-4 song blocks.
