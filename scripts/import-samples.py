#!/usr/bin/env python3
"""Prepare personal audio for one 4 GiB card without modifying source files.

Requires ffmpeg/ffprobe for conversion. Card libraries and reports live in ignored out/.
Preparing never changes the mounted folder; activate explicitly after preparing.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / "vendor/virtual-mpc-sample"
LIBRARY = ROOT / "out/sample-cards"
LIMIT = (4 << 30) - (256 << 20)
AUDIO = {".wav", ".aif", ".aiff", ".mp3", ".flac", ".ogg", ".snd"}


def wav_path(relative):
    return relative if relative.suffix.lower() == ".wav" else Path(str(relative) + ".wav")


def prepare(source, staging):
    src, relative = source
    target = staging / wav_path(relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    compatible = False
    if src.suffix.lower() == ".wav":
        try:
            with wave.open(str(src)) as wav:
                compatible = (wav.getcomptype() == "NONE" and wav.getsampwidth() in (2, 3)
                              and wav.getframerate() in (44100, 48000)
                              and wav.getnchannels() in (1, 2))
        except (wave.Error, EOFError):
            pass
    if compatible:
        shutil.copy2(src, target)
    else:
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                                "-show_entries", "stream=channels", "-of", "json", str(src)],
                               check=True, capture_output=True, text=True)
        channels = json.loads(probe.stdout)["streams"][0]["channels"]
        if channels not in (1, 2):
            raise ValueError(f"Refusing to downmix {channels} channels: {src}")
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-n", "-i", str(src),
                        "-map", "0:a:0", "-map_metadata", "-1", "-ar", "44100",
                        "-c:a", "pcm_s16le", str(target)], check=True, capture_output=True)
    return {"source": str(src), "path": str(target.relative_to(staging)),
            "bytes": target.stat().st_size, "converted": not compatible}


def build(sources):
    if LIBRARY.exists():
        raise ValueError(f"Library already exists: {LIBRARY}; preserve or rename it before rebuilding")
    files, skipped, seen = [], [], set()
    for directory in sources:
        directory = directory.expanduser().resolve(strict=True)
        if not directory.is_dir():
            raise ValueError(f"Not a folder: {directory}")
        for src in sorted(directory.rglob("*")):
            if not src.is_file():
                continue
            if src.is_symlink() or src.suffix.lower() not in AUDIO or src.name.startswith("."):
                skipped.append(str(src))
                continue
            relative = Path(directory.name) / src.relative_to(directory)
            key = str(wav_path(relative)).casefold()
            if key in seen:
                raise ValueError(f"Output filename collision: {relative}")
            seen.add(key)
            files.append((src, relative))
    if not files:
        raise ValueError("No audio files found")
    LIBRARY.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sample-import-", dir=LIBRARY.parent) as temp:
        staging = Path(temp) / "audio"
        staging.mkdir()
        with ThreadPoolExecutor(max_workers=4) as pool:
            records = []
            for i, record in enumerate(pool.map(lambda item: prepare(item, staging), files), 1):
                records.append(record)
                if i % 500 == 0:
                    print(f"Prepared {i}/{len(files)}", flush=True)
        cards = Path(temp) / "cards"
        cards.mkdir()
        size = 0
        for record in records:
            if size + record["bytes"] > LIMIT:
                raise ValueError("Collection exceeds the 4 GiB card's safe capacity")
            card = "all"
            relative = Path("MPC-Sample/Samples") / record["path"]
            target = cards / card / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(staging / record["path"], target)
            record.update(card=card, card_path=str(relative))
            size += record["bytes"]
        (cards / "manifest.json").write_text(json.dumps({"files": records, "skipped": skipped}, indent=2))
        cards.rename(LIBRARY)
    print(f"Prepared {len(records)} files on one card in {LIBRARY}")


def activate(card):
    if Path(card).name != card or (card != "all" and not card.startswith("card-")):
        raise ValueError("Use all (or a legacy card name such as card-01)")
    source = LIBRARY / card
    combine = card == "all" and not source.is_dir() and (LIBRARY / "manifest.json").exists()
    if not source.is_dir() and not combine:
        raise ValueError(f"No prepared card: {source}")
    destination = LAB / "sdcard"
    # Stage before replacing; preserve the previous host folder, including user additions.
    with tempfile.TemporaryDirectory(prefix="activate-", dir=LIBRARY.parent) as temp:
        staged = Path(temp) / "sdcard"
        if combine:
            # Reuse already converted files from the original split-card import.
            staged.mkdir()
            manifest = json.loads((LIBRARY / "manifest.json").read_text())
            for row in manifest["files"]:
                relative = Path(row["card_path"])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError(f"Invalid manifest path: {relative}")
                target = staged / relative
                if target.exists():
                    raise ValueError(f"Output collision: {relative}")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(LIBRARY / row["card"] / relative, target)
        else:
            shutil.copytree(source, staged)
        if destination.exists():
            backup = LIBRARY.parent / f"sdcard-backup-{time.time_ns()}"
            destination.rename(backup)
            print(f"Previous host folder preserved: {backup}")
        staged.rename(destination)
    print(f"Active host folder: {destination} ({card})")
    print("Save any guest SD-card work elsewhere first. Eject/reinsert the virtual SD slot to refresh.")
    print("Restart alone reuses the existing image. This command does not change the running card image.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="*", type=Path)
    parser.add_argument("--activate", metavar="CARD")
    args = parser.parse_args()
    if args.activate and args.sources:
        parser.error("Prepare sources or activate a card in separate commands")
    if args.activate:
        activate(args.activate)
    elif args.sources:
        build(args.sources)
    else:
        parser.error("Supply source folders or --activate card-01")


if __name__ == "__main__":
    main()
