# Touch Sample: project instructions

Paste this into the Claude project's custom instructions. Add `PLAN.md` and `CONTROL_MAP.md` as project knowledge.

**What this is.** Touch Sample runs the stock Akai MPC Sample firmware (1.3.0.12) in QEMU on Sav's Apple Silicon Mac
using `orrpunk-art/virtual-mpc-sample`, and makes the Akai MPC Touch its controller: pads, Q-Links, wheel, buttons,
lights, and the Touch's 1280×800 screen. `PLAN.md` is the plan and `CONTROL_MAP.md` the control and light map. Follow
them; don't re-plan accepted decisions. The user is Sav (Savilion).

**Decided.** Sav has no MPC Sample: no factory library, Sav's own samples go in the emulator's `sdcard/` folder.
Firmware comes from Akai's Mac updater (`PLAN.md` Phase 0). Button defaults are in `CONTROL_MAP.md` (editable).
PaperCut/Koala and the bridge never run at the same time.

**Where the code lives.** `~/Documents/Codex/TouchSample` (Claude Code in the desktop app's Code tab works there).
Emulator in `vendor/virtual-mpc-sample` (pinned submodule); our additions to it stay in separate files. MPC Touch
knowledge comes from PaperCut (`~/Documents/Codex/PaperCut`): read it, copy what we need with attribution, never edit
PaperCut from this project.

**How we work.**
- Opus for research, planning and review; Sonnet for implementation. Research and plan before building, then check
  your own work.
- One phase at a time from `PLAN.md`. Each phase ends with something Sav can try.
- Reports list: what changed, files, automated tests run, manual tests done, what still needs Sav's hands, branch,
  commits, pushed or not. Never claim a test passed unless it ran. Software checks are not hardware checks.
- Git: branch per job, small commits, never force-push or rewrite history without asking.
- Start the emulator from Terminal.app, not from the Claude app's terminal pane (QEMU is throttled there and the audio
  clicks).

**Hard rules.**
1. No Akai firmware, extracted partitions, factory content, keys or credentials in git. Personal use only.
2. Preserve the working MPC Touch setup. Don't touch `AkaiTouchPanel.kext`, DisplayLink or any firmware. Don't change,
   rebuild or re-sign the touch driver `com.savilion.mpc-touchd`; never run a second raw touch reader.
3. Only send Touch commands that PaperCut has already used (see `CONTROL_MAP.md` "Touch startup"). Never send Akai
   `0x5A`. No bursts to the Private port. Lock-up (USB present, MIDI silent): run
   `~/Library/Application Support/MPC Touch Driver/mpc_replug`.
4. Only one app owns the Touch: quit PaperCut and Koala before the bridge runs, and have the bridge refuse to start
   if another owner is running.
5. The bridge is an allow-list. Unknown Touch messages are dropped and logged once, never passed through.
6. Don't change control mappings or layouts that Sav has accepted unless Sav asks. Propose instead.
7. `mpc-sample-lab` has no licence: run its tools locally, don't copy its code into our repo.
