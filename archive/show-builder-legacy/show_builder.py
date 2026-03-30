#!/usr/bin/env python3
"""
WPFQ Show Builder — Main entry point.

Usage:
    python show_builder.py "Build me a 2 hour 90s grunge block with comedy every 10-15 min"
    python show_builder.py --dry-run "1 hour 80s mix"
    python show_builder.py --preview "30 min jazz chill"
"""
import argparse
import json
import os
import sys
from datetime import datetime

from config import OUTPUT_DIR
from show_planner import plan_show
from song_picker import pick_songs
from break_factory import generate_breaks
from timeline_assembler import build_timeline, assemble_show, assemble_show_fast


def build_show(
    prompt: str,
    dry_run: bool = False,
    preview: bool = False,
    use_llm: bool = True,
    output_name: str | None = None,
) -> dict:
    """Build a complete show from a natural language prompt.

    Args:
        prompt: Natural language show description
        dry_run: If True, plan and pick songs but don't render audio
        preview: If True, render a short preview (~90s) instead of full show
        use_llm: If True, use LLM for show planning (slower but smarter)
        output_name: Custom output filename (without extension)

    Returns:
        Show result dict with manifest, timeline, and output path
    """
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    if not output_name:
        output_name = f"show-{timestamp}"

    print("=" * 70)
    print(f"🎙️  WPFQ Show Builder")
    print(f"📝 Prompt: {prompt}")
    print(f"🕐 Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 70)

    # Step 1: Plan the show
    print("\n📋 Step 1: Planning show...")
    manifest = plan_show(prompt, use_llm=use_llm)
    print(f"  Title: {manifest.title}")
    print(f"  Duration: {manifest.duration_minutes} min")
    print(f"  Genre: {manifest.genre} | Era: {manifest.era}")
    print(f"  Categories: {manifest.category_ids}")
    print(f"  Break interval: {manifest.break_schedule.interval_min} min")
    print(f"  Break types: {manifest.break_schedule.types}")
    print(f"  Mood: {manifest.mood}")

    # Step 2: Pick songs
    print("\n🎵 Step 2: Picking songs...")
    # Calculate music duration (total minus estimated break time)
    num_breaks = manifest.duration_minutes // ((manifest.break_schedule.interval_min[0] + manifest.break_schedule.interval_min[1]) // 2)
    break_time_est = num_breaks * 0.5  # ~30s average per break
    music_minutes = max(10, manifest.duration_minutes - break_time_est)

    songs = pick_songs(
        genre=manifest.genre,
        duration_minutes=int(music_minutes),
        category_ids=manifest.category_ids if manifest.category_ids else None,
        era=manifest.era,
    )

    if not songs:
        print("❌ No songs found! Check genre/category mapping.")
        return {"error": "No songs found", "manifest": manifest.to_dict()}

    for i, s in enumerate(songs, 1):
        dur = f"{s['duration'] // 60}:{s['duration'] % 60:02d}"
        print(f"  {i:2d}. {s['artist']} — {s['title']} [{dur}]")

    manifest.songs = songs

    # Step 3: Generate breaks
    print("\n🎤 Step 3: Generating breaks...")
    breaks = generate_breaks(manifest, songs)
    manifest.breaks = breaks

    # Step 4: Build timeline
    print("\n📐 Step 4: Building timeline...")
    timeline = build_timeline(songs, breaks)
    manifest.timeline = timeline

    print(f"  Timeline: {len(timeline)} segments "
          f"({sum(1 for t in timeline if t['type'] == 'song')} songs, "
          f"{sum(1 for t in timeline if t['type'] == 'break')} breaks)")

    if dry_run:
        print("\n🏁 DRY RUN — Skipping audio rendering")
        # Save manifest
        manifest_path = os.path.join(OUTPUT_DIR, f"{output_name}-manifest.json")
        with open(manifest_path, "w") as f:
            json.dump(manifest.to_dict(), f, indent=2, default=str)
        print(f"  Manifest saved: {manifest_path}")
        return {
            "status": "dry_run",
            "manifest": manifest.to_dict(),
            "manifest_path": manifest_path,
        }

    # Step 5: Assemble audio
    if preview:
        print("\n🔊 Step 5: Rendering preview (~90s)...")
        output_path = assemble_show_fast(timeline, output_name)
    else:
        print("\n🔊 Step 5: Rendering full show...")
        output_path = assemble_show(timeline, output_name)

    # Save manifest alongside audio
    manifest_path = os.path.join(OUTPUT_DIR, f"{output_name}-manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest.to_dict(), f, indent=2, default=str)

    print("\n" + "=" * 70)
    print(f"✅ Show complete!")
    print(f"  Audio: {output_path}")
    print(f"  Manifest: {manifest_path}")
    print(f"  Finished: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 70)

    return {
        "status": "complete",
        "output_path": output_path,
        "manifest_path": manifest_path,
        "manifest": manifest.to_dict(),
    }


def main():
    parser = argparse.ArgumentParser(description="WPFQ Show Builder")
    parser.add_argument("prompt", nargs="?", help="Natural language show description")
    parser.add_argument("--dry-run", action="store_true", help="Plan only, don't render audio")
    parser.add_argument("--preview", action="store_true", help="Render short preview (~90s)")
    parser.add_argument("--no-llm", action="store_true", help="Use simple parser instead of LLM")
    parser.add_argument("--output", "-o", help="Output filename (without extension)")

    args = parser.parse_args()

    if not args.prompt:
        # Interactive mode
        print("🎙️  WPFQ Show Builder — Interactive Mode")
        print("Describe the show you want to build:")
        args.prompt = input("> ").strip()
        if not args.prompt:
            print("No prompt provided. Exiting.")
            sys.exit(1)

    result = build_show(
        prompt=args.prompt,
        dry_run=args.dry_run,
        preview=args.preview,
        use_llm=not args.no_llm,
        output_name=args.output,
    )

    if result.get("error"):
        sys.exit(1)


if __name__ == "__main__":
    main()
