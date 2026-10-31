# Hand-off: help build Touch Sample (for another coding assistant)

**Current continuation:** Phase 5 and hardware testing have progressed beyond this original brief. Read
[CLAUDE_AUDIO_HANDOFF.md](CLAUDE_AUDIO_HANDOFF.md) for the 2026-10-31 audio investigation, running trial, Git state,
and rollback instructions. The remainder of this file is the historical starting brief.

You are joining a project already in progress. Work in `~/Documents/Codex/TouchSample` on Sav's Mac (Apple Silicon,
macOS 15, Swift 6 Command Line Tools, Python 3.12, no Xcode).

## Read first (in this order)
1. `claude-project/PROJECT_INSTRUCTIONS.md`: hard rules. Obey them exactly (no firmware in git; never send MIDI SysEx
   0x5A; no SysEx/bursts to the Touch's Private port; only one app owns the Touch; never touch PaperCut, the touch
   driver `com.savilion.mpc-touchd`, AkaiTouchPanel.kext or DisplayLink).
2. `PLAN.md` (phases), `CONTROL_MAP.md` (controls and lights), `docs/DESIGN.md` (how each piece is built).

## Where things stand (2026-10-31)
- Phase 0: firmware 1.3.0.12 extracted (`scripts/extract-firmware.py`), QEMU installed, Docker = Colima. The emulator
  kernel build (`python3 lab.py build` in `vendor/virtual-mpc-sample`) may still be running: don't start another.
- Done and committed: `panel-ext/touch_server.py` + `panel-ext/touch.html` (Phase 3 hook + Phase 4 page),
  `hardware/touch-profile.json`, `mappings/default.json`, `scripts/run-lab.command`.
- In progress by Claude (don't edit these files): the Swift package in `app/` (TouchMIDI, BridgeCore, TouchIO with
  `BridgeRunner`, `touch-capture`, `touch-bridge`).

## Your job: Phase 5, the Mac app (see DESIGN.md "Phase 5")
Start only once `app/Package.swift` exists and `cd app && swift build -c release` succeeds.
1. `git checkout -b phase-5-app` from the current branch.
2. Add an executable target `TouchSampleApp` in `app/Sources/TouchSampleApp/` (AppKit + WKWebView) that embeds the
   bridge through `TouchIO.BridgeRunner`. Only change `Package.swift` to add that target.
3. `scripts/build-app.sh`: build release, assemble `dist/Touch Sample.app` (Info.plist, bundle id
   `com.savilion.touchsample`), ad-hoc sign our app only. Add `dist/` to `.gitignore`.
4. Behaviour: owner check; Start opens `scripts/run-lab.command` in Terminal.app if port 8765 is closed, waits for
   `http://127.0.0.1:8765/touch`, starts the bridge, shows a borderless full-screen WKWebView of `/touch` on the Touch
   display (name contains "MPC Touch", else a 1280x800 screen that isn't the main one) with
   `mediaTypesRequiringUserActionForPlayback = []`. Quit/Stop: stop bridge, run `python3 lab.py stop` (saves), close.
   Setting: "Use Chrome for the Touch screen" (`--app=http://127.0.0.1:8765/touch`).
5. `docs/MANUAL.md`: how Sav starts, plays, stops, edits `mappings/default.json`, and recovers a locked Touch
   (`~/Library/Application Support/MPC Touch Driver/mpc_replug`).

## Rules for you
- Do not run anything that talks to the MPC Touch (no `touch-capture`, no `touch-bridge` without `--self-test`, no
  launching the app with the Touch connected). Sav does hardware tests.
- Do not start the emulator; Sav starts it from Terminal.app.
- Small commits on your branch, never force-push, nothing pushed without Sav's OK.
- Report: what changed, files, tests you actually ran, what needs Sav's hands, branch, commits.

## Resume point (2026-10-31 03:42, Claude low on usage)
- Branches: `phase-0-emulator` (scripts, DESIGN.md) -> `phase-1-4-bridge-screen` (panel-ext, profile, mapping, spares). Not merged, not pushed.
- Kernel build ran in the background (`python3 lab.py build kernel bridge`); next: `python3 lab.py build images` (needs Colima running).
- Swift bridge in `app/` is built and committed (self-test 125/125). Not run on hardware yet.
- Unnamed Touch buttons 0x34 0x36 0x37 0x43 0x7A are profile spares -> CHOP, MUTE, LOOP, SAMPLE, SAMPLE SELECT until Sav names them.
- Then Phase 5 (this file's job list), then Sav's hardware test: run `scripts/run-lab.command` in Terminal.app, quit PaperCut/Koala, run `app/.build/release/touch-bridge`, open http://127.0.0.1:8765/touch on the Touch screen.
- 03:45 update: kernel, audio bridge and disk images all built (`lab.py build images` needed an empty
  `vendor/virtual-mpc-sample/overlay/lab-layer/root/.ssh/` folder: upstream git drops empty dirs). The emulator is
  ready to run: Sav opens `scripts/run-lab.command` in Terminal.app.
