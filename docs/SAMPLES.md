# Loading Sav’s samples

The host SD-card folder is:

```text
/Users/savmacbook/Documents/Codex/TouchSample/vendor/virtual-mpc-sample/sdcard/
```

Confirmed against `scripts/run-lab.command` and the pinned vendor `lab.py`’s
`SDCARD` definition. QEMU attaches `vendor/virtual-mpc-sample/out/run/sdcard.img`
through `sdhci-pci` and `sd-card`. The guest mounts partition `/dev/mmcblk1p1` at
`/media/MPC SAMPLE`. The host folder is copied into an image, not shared live.

## One larger card

Sav requested one card for the complete library on 2026-11-02. The local
`lab-ext/sample_card.py` extension builds a 4 GiB FAT32 image with an MBR partition,
labelled `MPC SAMPLE`. It leaves at least 256 MiB for filesystem overhead and saves.
It writes only project-local image files; it never mounts or formats a Mac disk.

The unchanged vendor builder has a roughly 500 MB FAT16 limit. Our Terminal launcher
runs `lab-ext/run-lab.py`, which installs the larger builder before running the stock
lab CLI. `panel-ext/touch_server.py` installs the same builder for virtual SD inserts.
The vendor submodule and Akai firmware remain unchanged. Running the vendor CLI directly
bypasses this extension; use the project launcher to start the emulator.

Dependencies are pinned in `lab-ext/sample-card-requirements.txt` and installed locally:

```sh
python3 -m pip install --target out/sample-tools -r lab-ext/sample-card-requirements.txt
```

Run commands from `/Users/savmacbook/Documents/Codex/TouchSample`.

## Formats and browsing

Akai documents WAV, MP3, AIF/AIFF, SND, S1S, S3S, FLAC and OGG imports, with
16/24-bit audio at 44.1, 48 or 96 kHz. WAV PCM at 16/24-bit and 44.1/48 kHz is
the conservative choice for this setup. Sav Kit’s 24 kHz files were converted.

Press SAMPLE SELECT, then B2 (the second SCREEN button) to select External. The
browser defaults to `MPC-Sample/Samples`: open `Sav Kit` or `Compositions`. Turn the
encoder to select a folder and press it to open. B1 goes back. Other card directories
can also be browsed; loose samples do not need a special kit format.

Sources checked 2026-11-02:

- [Akai technical specifications](https://www.akaipro.com/guides/mpc-sample/technical_specifications.htm)
- [Akai sample loading guide](https://www.akaipro.com/guides/mpc-sample/loading_and_saving_samples.htm)
- Pinned emulator `docs/PANEL.md` (SD card section) and `lab.py`.

## Importing

All 5,053 audio files from Dropbox’s `DRUMS 2018/Sav Kit` and `Compositions` were
prepared: 4,997 converted, 56 compatible WAVs copied unchanged, and 86 non-audio
sidecars/metadata entries skipped. Dropbox originals remain unchanged. Subfolders
are preserved; non-WAV extensions are retained before `.wav` to preserve alternate
versions (for example `Name.mp3.wav`). The helper preserves mono/stereo and refuses
multichannel downmixing. It does not normalize audio.

The complete library is active in `sdcard/MPC-Sample/Samples/`. The initial split
library and import manifest remain in ignored `out/sample-cards/` as a local backup.
To restore the full prepared collection to the host folder:

```sh
python3 scripts/import-samples.py --activate all
```

Activation preserves the previous host folder in `out/sdcard-backup-<timestamp>`.
It does not change a running guest’s card image. Preparation refuses to overwrite an
existing library. For a new library, preserve/rename `out/sample-cards/`, then run:

```sh
python3 scripts/import-samples.py /path/to/sample-folder
python3 scripts/import-samples.py --activate all
```

New imports prepare one collection under `out/sample-cards/all/`. The manifest records
source paths, conversions and skipped files. All samples, dependencies, images, manifests
and backups remain git-ignored. No firmware, factory content or personal samples go in git.

## Refreshing

No emulator restart is required. After adding files, use the SD slot on the stock
panel at `http://127.0.0.1:8765/`: eject if inserted, then insert. The project panel
rebuilds the full FAT32 card. Wait for copying to finish; progress appears in Terminal.

Save guest SD-card work elsewhere before reinserting: the previous image is replaced.
The image survives a normal restart, so restarting alone does not refresh newly added
host files. On the first launch with no image, the project launcher builds one from
the nonempty host folder. Failed builds preserve the previous image.

Start the emulator through Terminal.app with `scripts/run-lab.command`. Do not start
it from an agent shell. Stop normally through Touch Sample’s save/quit workflow.

## Validation (2026-11-02)

All 5,053 image files matched their host SHA-256 hashes. The extracted partition
passed macOS `fsck_msdos -n` without filesystem errors (about 1.4 GiB free).
Real-image tests cover MBR geometry, the volume label, nested Unicode filenames,
file contents, and preservation of the previous image after a failed copy. Run
`python3 scripts/test-sample-card.py`; the panel self-test also passed.

The emulator was started through Terminal.app. Guest verification confirmed
`/dev/mmcblk1p1` mounted read/write as vfat at `/media/MPC SAMPLE`, a 4.0G
filesystem with 2.6G used and 1.4G available. Both `Sav Kit` and `Compositions`
appeared under `MPC-Sample/Samples`, containing all 5,053 imported files.
The controller bridge was not started, and sample auditioning remains untested.
