# Touch Sample

Run stock Akai MPC Sample firmware 1.3.0.12 in QEMU, controlled by an MPC Touch.
The native Mac app provides the controller bridge, lights, touchscreen controls and
audio. The emulator is the pinned
[virtual-mpc-sample](https://github.com/orrpunk-art/virtual-mpc-sample) submodule.

This repository contains no Akai firmware, factory library or personal samples.
Provide your own firmware locally. The installed MPC Touch driver, kext and
DisplayLink are external prerequisites; this project does not modify them.

## Start here

- [Manual](docs/MANUAL.md): build, launch, save/quit and controller operation.
- [Personal samples](docs/SAMPLES.md): formats, import, the 4 GiB SD card and refresh.
- [Project instructions](claude-project/PROJECT_INSTRUCTIONS.md): hardware boundaries.
- [Control map](CONTROL_MAP.md): hardware and on-screen control assignments.
- [Design](docs/DESIGN.md): app and bridge architecture.
- [Audio investigation](docs/AUDIO_DIAGNOSIS.md): known audio limitations and trials.

Keep the project at `~/Documents/Codex/TouchSample`. Initialize the pinned submodule
with `git submodule update --init --recursive`. Follow the existing manual and
emulator instructions to prepare your own firmware and build the emulator images.

Install the project-local SD-card dependencies from this folder:

```sh
python3 -m pip install --target out/sample-tools -r lab-ext/sample-card-requirements.txt
```

Build the native app using `bash scripts/build-app.sh`, then open
`dist/Touch Sample.app`. The app launches the emulator through Terminal.app.
For the emulator alone, open `scripts/run-lab.command` in Terminal.app.
Only one controller application may own the Touch. Quit the other controller
applications yourself before starting Touch Sample. Stop/quit normally to save.

## Samples

Drop compatible audio into:

```text
vendor/virtual-mpc-sample/sdcard/MPC-Sample/Samples/
```

For conversion and importing a folder, see [SAMPLES.md](docs/SAMPLES.md).
The host extension builds one 4 GiB FAT32 card without changing the vendor checkout.
After changing host files, eject and reinsert the virtual SD card through the stock
panel. This replaces the guest card image, so save guest SD-card work elsewhere first.
A restart reuses the existing image and does not refresh host additions.

In the firmware, open **SAMPLE SELECT**, press **SCREEN 2 / B2** to choose
**External**, and browse with the encoder. Files copied to the card do not
automatically populate pads. The embedded firmware LCD is a display image;
use hardware controls and the surrounding on-screen buttons to operate it.

## Fixes verified on 2026-11-02

- Personal sample importing preserves compatible WAVs and converts other supported
  audio to PCM 16-bit/44.1 kHz. Original files stay unchanged and audio stays ignored.
- One larger FAT32 card replaces the stock builder's roughly 500 MB limit. Boot and
  virtual SD insertion use the same extension. The guest mounted the full library;
  file hashes and a native filesystem check passed.
- Pad-bank selection obtains missing startup feedback before moving to the requested
  bank. A–D and Shift for E–H keep their existing assignments. Sav confirmed the banks work.
- The app accepts both legacy 24-byte and current 32-byte touch-driver packets.
  The driver itself stays unchanged. Packet and page interaction tests passed.
  Reopen the rebuilt app to load a new receiver version.

The native app was rebuilt and its signature verified. Audio quality and latency
remain subject to the limitations documented in the audio investigation.

## Hardware-free checks

```sh
cd app
swift build -c release --product touch-bridge
.build/release/touch-bridge --self-test
cd ..
python3 scripts/test-sample-card.py
python3 panel-ext/touch_server.py --selftest
node scripts/test-direct-touch.cjs
"dist/Touch Sample.app/Contents/MacOS/TouchSampleApp" --self-test
```

The bridge suite passed 172 checks after the bank fix. The app self-test checks
touch packet formats and coordinates, native PCM handling and project-folder
resolution without opening hardware. Physical playing and listening remain manual.
