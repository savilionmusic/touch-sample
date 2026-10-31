# Touch Sample: the MPC Sample on the Mac, played from the MPC Touch

Plan written 2026-10-30 (Claude Code, Opus) for Sav (Savilion). It is the brief for a new Claude project.
Read it with `CONTROL_MAP.md` (every control and light, Touch ↔ Sample) and
`claude-project/PROJECT_INSTRUCTIONS.md` (the rules the project's agents follow).

## Goal

Run the real Akai MPC Sample software (stock firmware 1.3.0.12, emulated) on this Mac and play it entirely from the
**MPC Touch**: pads, Q-Links, data wheel, buttons, the button and pad lights, and the Touch's 1280×800 screen showing
the MPC Sample's screen with touch buttons for the controls the Touch doesn't physically have.

## Which repository, and why

| Repo | What it is | Verdict |
|---|---|---|
| [orrpunk-art/virtual-mpc-sample](https://github.com/orrpunk-art/virtual-mpc-sample) | Stock MPC Sample firmware, unmodified, in QEMU. Browser panel, sound, SD card, USB MIDI. MIT licence, active (pushed 2026-10-29), only tested on Apple Silicon macOS | **Base. Use this.** |
| [gospodindilly-ops/mpc-sample-lab](https://github.com/gospodindilly-ops/mpc-sample-lab) | Hardware research: full control-surface protocol, its own Sample-Mode firmware, and `tools/az0x.py`, which unpacks the `Update.img` firmware container | **Helper.** Its `az0x.py` fills the emulator's missing firmware-extractor step. No licence: run it locally, never copy its code into our repo |
| [WorldLinkStudio/mpcsample](https://github.com/WorldLinkStudio/mpcsample) | Electron kit maker / pad player, exports `.xpj` | Not the device. Possibly useful later for building kits for the SD card |
| [tarikcampos/MPC-Sample-Toolkit](https://github.com/tarikcampos/MPC-Sample-Toolkit) | Python `.xpj` project tools (MIT) | Optional later |

**Why the emulator fits so well:** the MPC Sample's panel microcontroller speaks almost the same MIDI as the
MPC Touch. Checked against PaperCut's verified Touch map:

- The 16 pad notes are **identical**, in the same order (`37 36 42 82 40 38 46 44 48 47 45 43 49 55 51 53`, Ch.10
  `99`/`89`).
- Knobs: Touch Q-Links send CC 16–19, Sample K1–K3 are CC 16–18. Data wheel CC 100 (`01`/`7F`) and push note 111:
  identical.
- SHIFT 49, PLAY 82, STOP 81, REC 73, TAP 53, 16 LEVELS 40 have the same note numbers on both.
- Button LEDs use the same `B0 id value` form (0 off, 1 dim, 2+ lit).
- Pad colour SysEx is the same shape; only the product byte differs (Sample `5C`, Touch `37`).

So the bridge is mostly an allow-list of pass-throughs plus a few remaps. It is **not** a blind pass-through: some
Touch IDs mean something else on the Sample (Touch pad-bank B = note 36 = Sample SAMPLE SELECT; Touch Q4 = CC 19 =
Sample MAIN VOLUME). See `CONTROL_MAP.md`.

## Architecture

```
MPC Touch (USB)                                       Mac
 ├─ MIDI Public/Private ──CoreMIDI──► Touch Sample app (Swift + PaperCut's C init code)
 │                                      ├─ bridge: Touch events → Sample frames ──WebSocket /ws {"t":"send"}──┐
 │   ◄── button LEDs, pad RGB ─────────┤  ◄── LED / pad-colour state (JSON, /ws) ─────────────────────────────┤
 ├─ DisplayLink screen 1280×800 ◄──────┤  WKWebView, full screen on the Touch display: /touch page            │
 └─ touch panel → mpc_touchd → mouse ──┘  (Sample screen ×3 + touch buttons; sound plays in this page)       │
                                                                                                             ▼
                                         virtual-mpc-sample panel server (Python, :8765) ── UART :5551 ──► QEMU VM
                                                                                                  (stock MPC Sample app)
```

Key facts this design rests on (all from the emulator's docs and `panel/server.py`):

- The panel server is the only client of the VM's control-surface UART (TCP 5551). We don't replace it; we feed it.
  Its `/ws` WebSocket already accepts raw frames (`{"t":"send","hex":"99 25 64"}`) and pushes state (button LEDs,
  pad colours, bank) about 10 times a second. **Phase 2 needs no change to the emulator.**
- Sound plays in the browser page that holds `/ws`. Whichever page is open on the Touch screen plays the audio.
- The Touch's screen is an ordinary macOS display (DisplayLink), and PaperCut's installed touch driver
  (`com.savilion.mpc-touchd`) turns touches into mouse clicks. A full-screen window on that display gets taps for free.

## Phases

Each phase ends with something Sav can try. Software checks are not hardware checks: every phase report lists what
ran automatically, what was tried by hand, and what still needs Sav's hands.

### Phase 0: emulator running on its own (no Touch yet)

1. Create the project folder `~/Documents/Codex/TouchSample` and add it to `~/Documents/Codex/PROJECTS.md`.
   Clone `virtual-mpc-sample` into `vendor/virtual-mpc-sample` (git submodule, pinned commit) and
   `mpc-sample-lab` into `vendor/mpc-sample-lab` (read-only, git-ignored or submodule).
2. `brew install qemu` (Docker and Python 3.12 are already installed).
3. Sav downloads Akai's Mac updater, "MPC SAMPLE - Firmware Update v1.3 (MAC)", from
   https://www.akaipro.com/downloads-and-support/downloads/?product=MPC%20Sample (direct file:
   `MPC Sample 1.3.0 Updater.app.zip`, 172 MB, dated 2026-04-08). Keep it in `firmware/` (git-ignored). Don't run the
   updater: there is no MPC Sample to update. Unzip it and find the update image inside the app bundle
   (`find "MPC Sample 1.3.0 Updater.app" -iname "*.img"`). Check it is 1.3.0.12 by its SHA-256 against
   `mpc-sample-lab/backup-manifest/update-img.SHA256SUMS` and the emulator's `inputs.sha256`. Unpack it with
   `mpc-sample-lab/tools/az0x.py`, pick out `part1`, `part2`, `parr`, put them in
   `vendor/virtual-mpc-sample/firmware/extracted/` and let `lab.py build` check them. If the image isn't 1.3.0.12,
   stop and tell Sav (the "older versions" link on the same page, or the emulator's guide for other versions, are the
   ways forward). Firmware never goes into git.
4. `python3 lab.py build` (about 15 min the first time), then `python3 lab.py run` **from Terminal.app, not from the
   Claude app's terminal pane** (measured: QEMU gets throttled there and the audio clicks).
5. **Done when:** http://127.0.0.1:8765/ shows the stock app, keyboard pads make sound, `lab.py stop` saves and exits.

Sav has no MPC Sample, so there is no factory library (it can only be copied off a device). Sav's own samples go in
`sdcard/` next to `lab.py`; clicking the SD slot (or `lab.py run` at start) builds a card from it. Limits: about
500 MB per card (FAT16), and the card is a copy, so anything the app saves to it is lost on the next insert. Projects
saved to the internal storage (`/data`) survive restarts. Phase 5 adds a "samples folder" setting and a warning when
it passes 500 MB.

### Phase 1: Touch hardware gate (one bounded capture)

PaperCut verified pads, Q-Link 1, bank selectors, Shift, Play/Stop/Rec/Play Start, jog, FULL LEVEL and 16 LEVEL LEDs.
Still unverified on this Touch: Q2–Q4 ranges, every other button's note, the full LED list, pad RGB numbering, and
which port accepts pad RGB.

1. Quit PaperCut and Koala first. Only one app may own the Touch.
2. Reuse PaperCut's `outputs/mpc-touch-research/midi_capture.c` and the accepted init in
   `app/Sources/MPCRealtime/ControllerSetup.c` (copy into our repo, keep attribution to PaperCut).
3. Guided capture: Sav presses every button and turns every knob in a labelled order. Save the raw log.
4. One small LED test: each candidate button LED at 0/1/2, and one pad colour
   `F0 47 7F 37 65 00 04 <pad> <R> <G> <B> F7` on Public only.
5. **Done when:** `hardware/touch-profile.json` lists every Touch control with its raw ID, port and verified flag, and
   the open rows in `CONTROL_MAP.md` are filled in.

### Phase 2: bridge, input only

A small Swift command-line tool first (later folded into the app):

- CoreMIDI entity traversal for Public and Private (PaperCut's method). Dedupe a button that arrives on both.
- Map with the allow-list in `CONTROL_MAP.md`; drop everything else and log it once.
- Send frames over the panel server's `/ws`. Keep one WebSocket open; never an HTTP POST per pad hit.
- Pad-bank buttons: the Sample has one cycling PAD BANK button. Read the current bank from the app's bank LEDs
  (CC 57–64) and press PAD BANK the right number of times to reach the target bank.
- Release safety: a held pad's release goes out with the note it was pressed with. On disconnect, send releases for
  everything held.
- **Done when:** with the browser panel open on the Mac, Sav plays the emulated MPC Sample from the Touch's pads,
  knobs, wheel and transport. Measure Touch-to-screen latency (the emulator alone is 40–110 ms).

### Phase 3: lights

- Read LED and pad-colour state from `/ws` and send to the Touch: button LEDs by ID map, bank LEDs to the Touch's
  A–D LEDs (CC 0x23–0x26), pad RGB with product byte `5C → 37` and the pad index map from Phase 1.
- Send only changes; full refresh after reconnect; never a continuous SysEx flood.
- If 10 Hz state is too slow for pad flashes, add a small opt-in hook to the panel server that pushes app→panel
  frames as they arrive. Keep it in its own file so upstream updates stay easy; offer it upstream as a PR.
- **Done when:** the Touch's pad colours and button lights match the virtual panel.

### Phase 4: the Touch screen

- A new page `/touch` (1280×800), served next to the stock panel page and kept in its own file:
  - the MPC Sample's 320×240 screen at 3× (960×720), sharp pixels;
  - the three SCREEN buttons as a strip under the screen (they are the buttons above the screen on the device);
  - a right-hand column of touch buttons: CHOP, MUTE, LOOP, PAD FX, PLUS, MINUS, PAD BANK E–H, a FADER strip and
    MAIN VOLUME, plus SAMPLE, SEQ, SAMPLE SELECT and KNOB FX (also on hardware, shown here so every Sample control is
    on screen). MUTE must work while held (press MUTE on screen, hit pads);
  - each button lights from the same LED state as the hardware.
- Touch arrives as mouse clicks from the installed touch driver. Don't change that driver.
- **Done when:** the Touch screen shows the Sample's screen and every Sample control can be reached from the Touch
  (hardware or on-screen).

### Phase 5: one Mac app

- `Touch Sample.app` (Swift, AppKit, SwiftPM, Command Line Tools like PaperCut): a WKWebView full screen on the Touch
  display (found by its 1280×800 size and name, never a hard-coded display ID), the bridge from Phase 2–3, and
  start/stop of the lab (`lab.py run` / `lab.py stop`, launched so QEMU isn't throttled).
- Clean shutdown always goes through `lab.py stop` so the MPC Sample saves its project.
- Check early whether WKWebView's AudioWorklet latency matches Chrome's. If not, the fallback is Chrome
  `--app=http://127.0.0.1:8765/touch` on the Touch display.
- Sound output: Mac default output, or the Touch's own audio interface; make it a setting.
- **Done when:** one double-click starts everything and one quit saves and stops everything.

### Phase 6: polish

Remap/Learn file (scoped by Shift), latency report, reconnect after unplug, a self-test mode like PaperCut's
`--self-test`, a short manual.

## Risks and open questions

| Risk | Plan |
|---|---|
| Firmware unpacking is manual and only 1.3.0.12 is supported | Pin that version; document the `az0x.py` step; script it in our repo |
| Audio clicks under emulation (6–11 restarts a minute when idle per the emulator's docs) | Run from Terminal.app; keep the 23 ms buffer; measure before "fixing" |
| Two apps fighting over the Touch (PaperCut, Koala, us) | The app checks and refuses to start the bridge while another owner is running |
| Pad RGB format/numbering on the Touch not proven on this Mac | Phase 1 tests it once, Public port only |
| WKWebView audio latency | Measure in Phase 5; Chrome app-window fallback |
| Upstream emulator changes | Pin the submodule; keep our additions in separate files |

**Decisions (Sav, 2026-10-30):**
1. No physical MPC Sample: no factory library; Sav loads their own samples.
2. The project lives in `~/Documents/Codex/TouchSample` (with Sav's other projects). Ask before creating a GitHub repo.
3. Touch buttons the Sample doesn't have: use the best educated guess. The defaults and their reasons are in
   `CONTROL_MAP.md`; they stay editable, and Sav changes them after playing.
4. PaperCut (and Koala) and the bridge never run at the same time.

## Licences and hardware safety

- No Akai firmware, extracted partitions, factory content or keys in git, ever. Personal use only.
- `virtual-mpc-sample` is MIT: forking and changing it is fine with the notice kept. `mpc-sample-lab` has no licence:
  use its tools locally, don't copy its code.
- Hardware rules inherited from PaperCut (they protect the working Touch setup): don't touch `AkaiTouchPanel.kext`,
  DisplayLink or any firmware; don't change or re-sign the touch driver `com.savilion.mpc-touchd`; never run a second
  raw touch reader; never send undocumented commands (e.g. Akai `0x5A`); no bursts to the Private port (a burst
  locked the controller on 2026-09-27). If the controller locks up (USB present, MIDI silent), run
  `~/Library/Application Support/MPC Touch Driver/mpc_replug`.
