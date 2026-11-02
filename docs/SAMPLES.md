# Loading Sav's samples

The host SD-card folder is:

```text
/Users/savmacbook/Documents/Codex/TouchSample/vendor/virtual-mpc-sample/sdcard/
```

Confirmed against `scripts/run-lab.command` (changes into the pinned vendor folder) and
`vendor/virtual-mpc-sample/lab.py` (`SDCARD`, `sdcard_image`, and `qemu_cmd`). QEMU attaches
`out/run/sdcard.img` via `sdhci-pci`/`sd-card`; the guest mounts its partition at
`/media/MPC SAMPLE`. The host folder is copied into an image, not shared live.

## Formats and browsing

Akai documents WAV, MP3, AIF/AIFF, SND, S1S, S3S, FLAC and OGG imports, with
16/24-bit audio at 44.1, 48 or 96 kHz. WAV PCM at 16/24-bit and 44.1/48 kHz is
the conservative choice for this setup. Sav Kit's 24 kHz files need conversion.

Press SAMPLE SELECT, then B2 (the second SCREEN button) to select External. The browser
defaults to `MPC-Sample/Samples`; turn the encoder to select a folder and press it to open.
B1 goes back. Other folders on the card can also be browsed; a special kit format is
not required for loose samples.

Sources checked 2026-11-02:

- [Akai technical specifications](https://www.akaipro.com/guides/mpc-sample/technical_specifications.htm)
- [Akai sample loading guide](https://www.akaipro.com/guides/mpc-sample/loading_and_saving_samples.htm)
- Pinned emulator `docs/PANEL.md`, SD card section, and `lab.py` implementation.

## Importing and switching cards

The pinned builder makes a roughly 500 MB FAT16 card. The two supplied collections
exceed that, especially after converting 24 kHz files. The helper splits them into
cards limited to 440 MiB of audio, preserving their folder structure. It leaves
compatible WAVs intact and converts other audio to PCM 16-bit/44.1 kHz without
normalization. It preserves mono/stereo and refuses multichannel downmixing. Original
Dropbox files are never changed. WDT and other non-audio sidecars are skipped.

From `/Users/savmacbook/Documents/Codex/TouchSample`:

```sh
python3 scripts/import-samples.py "/Users/savmacbook/Dropbox/DRUMS 2018/Sav Kit" "/Users/savmacbook/Dropbox/Compositions"
python3 scripts/import-samples.py --activate card-01
```

Preparation writes `out/sample-cards/card-01`, `card-02`, etc., and a local
`manifest.json` listing every source, destination, conversion and skipped file.
It refuses to overwrite an existing prepared library. Non-WAV extensions are retained
before `.wav` (for example `Name.mp3.wav`) to preserve alternate versions.

Activation copies a prepared card to the mounted host folder. It preserves the previous
host folder as `out/sdcard-backup-<timestamp>`. It does not eject a running card or modify
the existing card image. To switch, run the activation command with another card number,
then refresh the virtual card as described below. All samples, cards, manifests and
backups stay git-ignored. Only the helper and documentation belong in git.

### Prepared library (2026-11-02)

All 5,053 audio files were imported: 4,997 converted and 56 copied unchanged.
The 86 skipped entries were non-audio sidecars/metadata. Cards 01–04 contain
Sav Kit (1,217 / 1,242 / 2,049 / 469 files); cards 05–07 contain Compositions
(38 / 24 / 14 files). Folder paths remain within each collection. Card 01 is
the initial active host folder.

Every output WAV header was checked for the expected PCM format, mono/stereo and
44.1/48 kHz rate. All seven card folders successfully built with QEMU's vvfat FAT16
builder. No emulator/controller playback test was performed.

## Refreshing the card

No emulator restart is required. After adding files or activating another card, use the
SD slot on the stock browser panel at `http://127.0.0.1:8765/`: eject if inserted, then
insert. This rebuilds the card from the host folder.

**Save anything created on the guest SD card elsewhere before reinserting:** the
previous image is replaced. The image survives a normal restart, so restarting alone
does not refresh newly added host files. On a first launch with no existing image,
the launcher creates one from the nonempty host folder.

If the emulator is stopped, start it from Terminal.app using the existing
`scripts/run-lab.command` workflow. Do not start it from an agent shell.
