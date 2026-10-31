# Touch Sample: build design (Phases 0–6)

Written 2026-10-31 (Claude Code, Opus) from `PLAN.md`, `CONTROL_MAP.md`, the emulator's `panel/server.py` and
PaperCut's CoreMIDI code. `PLAN.md` decides *what*; this file decides *how*, so the pieces built in parallel fit.
Hard rules from `claude-project/PROJECT_INSTRUCTIONS.md` apply to every line of code here.

## Repository layout

```
scripts/extract-firmware.sh     Phase 0: updater zip -> firmware/extracted/{part1,part2,parr} (runs az0x.py locally)
scripts/run-lab.command         Phase 0/5: our panel server, then `lab.py run`; opened in Terminal.app
panel-ext/touch_server.py       Phases 3–4: the stock panel server plus /touch, /bridge, /touchui (separate file)
panel-ext/touch.html            Phase 4: the 1280×800 page for the Touch's screen
app/                            SwiftPM package (Command Line Tools only, macOS 13+)
  Sources/TouchMIDI/            C: CoreMIDI find/connect/send for the MPC Touch (adapted from PaperCut, attributed)
  Sources/BridgeCore/           Swift, no I/O: profile + mapping loading, Touch->Sample and Sample->Touch logic
  Sources/touch-capture/        Phase 1 CLI: guided capture, LED test, writes hardware/touch-profile.json
  Sources/touch-bridge/         Phases 2–3 CLI: the bridge; `--self-test`
  Sources/TouchSampleApp/       Phase 5: Touch Sample.app (AppKit + WKWebView + the bridge)
mappings/default.json           Touch control name -> Sample action (Sav edits this; CONTROL_MAP.md defaults)
hardware/touch-profile.json     Touch control name -> raw ID, port, verified flag (Phase 1 fills it)
docs/MANUAL.md                  Phase 6: how Sav runs and tests it
```

Nothing under `vendor/` is edited. Our server imports the stock one.

## Processes at run time

```
Terminal.app: scripts/run-lab.command
   ├─ python3 panel-ext/touch_server.py   (port 8765; the stock server's code + our routes)
   └─ python3 vendor/virtual-mpc-sample/lab.py run   (sees 8765 taken, starts no panel of its own; QEMU)
touch-bridge (CLI, Phases 2–3) or Touch Sample.app (Phase 5, bridge in-process)
   ├─ CoreMIDI: MPC Touch Public + Private in; Public (and Private only for what PaperCut sends) out
   └─ WebSocket ws://127.0.0.1:8765/bridge
browser or WKWebView: http://127.0.0.1:8765/touch  (screen, sound, on-screen buttons; uses the stock /ws)
```

Only one page may play sound: QEMU's PCM chardev takes one client. Don't keep the stock panel page open while the
`/touch` page runs.

## panel-ext/touch_server.py

Starts exactly like `server.py`'s `__main__`, but:

- `sys.path` gets `vendor/virtual-mpc-sample/panel` and `vendor/virtual-mpc-sample`; `import server`.
- `class TouchPanel(server.Panel)` overrides `on_frame(f)`: call `super().on_frame(f)`, then, for a button-LED frame
  (`B0 id v`, channel 0) or a pad-colour frame (`F0 47 7F 5C 65 00 04 pad R G B F7`), push an event to every
  `/bridge` and `/touchui` listener at once (the stock `/ws` state push is ~10 Hz; this is immediate).
  It also overrides `attach(s)` to push `{"t":"vm","connected":bool}`.
- Handler: `Base = server.make_handler(...)`; `class H(Base)` overrides `do_GET` for `/touch` (serves
  `touch.html`), `/bridge` and `/touchui` (WebSockets, reuse `server.Ws`), else `super().do_GET()`.
- `--selftest`: runs `server.selftest()` and its own checks (event JSON for LED and pad frames, routes exist).
- `--port` as the stock server.

### `/bridge` WebSocket protocol (text frames, JSON, one object per frame)

Server -> client:

| Message | When |
|---|---|
| `{"t":"hello","leds":{"<id>":v,...},"pads":{"<i>":[r,g,b],...},"vm":bool}` | on connect: full state |
| `{"t":"led","id":n,"v":v}` | every app->panel `B0 id v` (channel 0), immediately, even if unchanged |
| `{"t":"pad","i":n,"rgb":[r,g,b]}` | every app->panel pad colour frame, immediately |
| `{"t":"vm","connected":bool}` | panel UART attach/detach |

Client -> server:

| Message | Effect |
|---|---|
| `{"t":"send","hex":"99 25 7F"}` | `panel.send(bytes)` then `burst.poke()` (fast screen refresh after input) |
| `{"t":"ui", ...any...}` | relayed unchanged to every `/touchui` listener (knob touch overlay, bridge status) |

### `/touchui` WebSocket

Server -> page only: the same `led`/`pad`/`vm` events, plus relayed `ui` objects from the bridge. The bridge sends:
`{"t":"ui","kind":"knob","name":"K2","value":64,"touched":true}` while a Q-Link is touched or turned (touched false on
release), and `{"t":"ui","kind":"bridge","touch":"connected"|"offline","fullLevel":bool,"q4":"FADER"|"MAIN VOLUME"}`
on any change.

## Swift package `app/`

`swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. No external dependencies. WebSocket client:
`URLSessionWebSocketTask`. Tests are self-test executables (`touch-bridge --self-test`), because Command Line Tools
may lack XCTest (PaperCut works the same way).

### TouchMIDI (C)

Adapted from PaperCut `app/Sources/MPCRealtime/ControllerSetup.c` and `outputs/mpc-touch-research/midi_capture.c`,
with a header comment naming the source files. Device match: device name contains "MPC Touch", not offline; entity
"Public" / "Private" (also `kMIDIPropertyPrivate`); skip the "MIDI Port" entity. Both global source list and entity
traversal (PaperCut's method). Functions: list endpoints, connect inputs with a callback carrying the port role,
`touch_send(role, bytes, len)`, `touch_startup()` = exactly the three Public SysEx in `CONTROL_MAP.md`
"Touch startup", nothing else. **No function can send 0x5A**: `touch_send` rejects any SysEx whose byte 4 is 0x5A
and any SysEx to Private.

### Output pacing (hard rule 3)

One serial output queue per port. Public: at least 3 ms between messages; Private: at least 20 ms, and only the
bank-indicator CCs `B0 23..26` / `B0 5A..5D` that PaperCut already sends there. Pad-colour SysEx: Public only,
at least 5 ms apart. Only changes are sent; a full refresh only after (re)connect. The queue coalesces: if a value
for the same LED/pad is queued and not sent yet, replace it.

### Owner check (hard rule 4)

Before opening any MIDI port, refuse to start (exit 2, clear message) if any of these run:
bundle IDs `com.savilion.mpctouch.instrument` (Paper Cut), `com.savilion.koala-touch` (Koala Link),
`com.elf-audio.koala-mac` (Koala), `com.akaipro.mpc` (Akai MPC / MPCHeadless); executables named `MPC Touch`,
`KoalaTouch`, `koala`, `MPC`. Also take an exclusive `flock` on
`~/Library/Application Support/Touch Sample/bridge.lock` so two bridges (CLI + app) never run together.
`mpc_touchd` and `mpc_watch` (the touch driver) are expected and fine: they read the touch panel, not MIDI.

### BridgeCore (pure Swift, unit-checkable)

Inputs: `TouchMessage(role: .public|.private, bytes)`, `SampleEvent` (`led(id,v)`, `pad(i,rgb)`, `hello`),
time. Outputs: `[Effect]` = `.toSample([UInt8])`, `.toTouch(role, [UInt8])`, `.ui([String:Any])`, `.log(String)`,
`.after(ms, Effect)` for paced macros.

Loads `hardware/touch-profile.json` (raw IDs) and `mappings/default.json` (meaning) plus the emulator's
`panel/controls.json` (Sample control name -> frames). Unknown or unmapped Touch messages are dropped and logged once
per (status, data1) (hard rule 5).

Rules (from `CONTROL_MAP.md`):

- Parse with running status and SysEx skipping, per port (PaperCut's `consume`). Ignore realtime bytes.
- Dedupe buttons arriving on both ports: a button is down if down on any port; act on transitions only.
- Pads (Ch.10 `99`/`89`/`A9`, Public): same note to the Sample; velocity 127 while FULL LEVEL is on. Remember the
  note+channel each pad was pressed with; the release goes out with that. Pressure `A9` passes through.
- On Touch disconnect or bridge stop: send releases for every held pad and button, SHIFT last.
- Knobs: Q1–Q3 CC 16–18 pass through; Q4 -> FADER (CC 20), or MAIN VOLUME (CC 19) while SHIFT is held. Q-Link touch
  notes 84–87 never reach the Sample; they emit `ui` knob events.
- Data wheel CC 100 and push note 111: pass through.
- Buttons: `send` -> the Sample control's press frame on press, release frame on release.
  `macro` (PLAY START = STOP then PLAY) -> press/release of each, 30 ms apart, on press only.
- Bridge-owned Shift combinations (mapping entries under `"shift"`): if SHIFT is held, send SHIFT release to the
  Sample, then the target's press (and its release on button release), then SHIFT press again if still held.
- FULL LEVEL: toggles on press; LED 0x27 = 2 on / 0 off.
- Pad banks: target A–D, E–H with SHIFT. Current bank = the Sample bank LED (57–64) that is > 0. Press PAD BANK
  (`90 23 7F` / `80 23 00`) once, wait for the bank LED to change (or 250 ms), repeat until it matches, at most 8
  presses. Never pass Touch note 36 through as a button (it is SAMPLE SELECT on the Sample). A new target cancels a
  running walk.

Lights (Sample -> Touch):

- Button LED `id v` -> each Touch control whose mapping sends that Sample control; Touch LED id from the profile
  (`led` field). Value: 0 -> 0, 1 -> 1, >=2 -> 2.
- Bank LEDs 57–64 -> Touch bank LEDs CC 35–38 (A–D: 3 when lit; E–H: same LED at 1). Public, and Private too when the
  profile's `bankLedPorts` lists it (PaperCut sends both).
- Q-Link bank LEDs CC 90–93: 90 = 2 while Q4 drives FADER, 91 = 2 while it drives MAIN VOLUME.
- MAIN/MENU (proposed): MAIN lit (2) when SAMPLE's LED >= 2, dim (1) when SEQ's is; MENU lit for SAMPLE SELECT, dim for
  PAD FX. Only if the profile has their LED ids.
- Pad colour -> `F0 47 7F 37 65 00 04 <indexMap[pad]> R G B F7` on Public, if `padColour.enabled` in the profile.
- After (re)connect: startup SysEx, then every known Touch LED to its current value (paced), then pad colours.
- On stop: every LED we lit back to 0, pads black (paced).

### touch-capture (Phase 1 CLI, run by Sav in Terminal.app)

- `touch-capture guided`: owner check; input only, no output port opened. Walks a labelled list (every name in the
  profile): "Press and release MAIN" / "Turn Q-Link 2 all the way left, then right" / "Touch Q-Link 3". Records the
  first matching message per step (button: channel-1 note-on; knob: CC and its min/max; pad: Ch.10 note), with port.
  Enter skips a step; `?` marks it "not on this Touch". Any other button pressed during the walk is recorded as a
  spare with its raw ID. Writes the raw log to `captures/raw/<timestamp>.log` (git-ignored) and merges results into
  `hardware/touch-profile.json` with `verified: true`.
- `touch-capture leds`: owner check; sends the startup SysEx, then for each control with an `id`, `B0 id 2`,
  asks "Is <name> lit? [y/n/q]", then `B0 id 0`. Public only, one message at a time, human-paced. Then one pad colour
  test: pad index 0 red on Public; asks which pad lit (1–16, or 0 = none). If one lit, asks whether to map the other
  15 the same way (one index at a time, Sav types the pad number). Writes `led`/`ledVerified` and `padColour`.
- `touch-capture --list`: prints the MPC Touch endpoints it would use. No output.

### touch-bridge (Phases 2–3 CLI)

`touch-bridge [--server ws://127.0.0.1:8765/bridge] [--profile ...] [--mapping ...] [--verbose] [--no-lights]`
`touch-bridge --self-test` (no MIDI, no network: feeds BridgeCore scripted messages and checks the effects; also
checks that no effect anywhere carries 0x5A SysEx or Private SysEx). Logs latency: Touch packet host time ->
WebSocket send, p50/p95 every 30 s with `--verbose`.

## panel-ext/touch.html (Phase 4)

1280×800, black, no scrolling, `user-select: none`, cursor hidden (touch screen).

- Left: the Sample screen canvas 320×240 drawn at 960×720 (`image-rendering: pixelated`), at x 0, y 0.
- Under it (y 720–800): SCREEN 1, 2, 3 as three wide buttons (the buttons above the device's screen).
- Right column (x 960–1280): touch buttons CHOP, MUTE, LOOP, PAD FX, PLUS, MINUS, PAD BANK E F G H, SAMPLE, SEQ,
  SAMPLE SELECT, KNOB FX; a vertical FADER strip and a MAIN VOLUME strip (drag sets CC 20 / CC 19 absolute).
  Big targets (at least 60 px). Each lights from the LED state like the stock page (lit/dim classes).
- Buttons: pointerdown -> `{"t":"control","name":..,"action":"press"}` on the stock `/ws`; pointerup / pointercancel /
  pointerleave -> release. So MUTE works while held. Bank E–H buttons walk PAD BANK themselves from the bank LED state
  (same algorithm as BridgeCore), so the page works without the bridge.
- Screen frames, state and sound: the stock `/ws` and the stock audio worklet/worker code, copied from
  `vendor/virtual-mpc-sample/panel/index.html` (MIT, attribution comment). Sound starts on first touch if the
  AudioContext is suspended; a small badge says "tap for sound" until then.
- `/touchui`: knob overlay (name + value bar over the screen's bottom while a Q-Link is touched), bridge status dot,
  FULL LEVEL and Q4 target shown in a status line.
- Optional `?sink=<deviceId>` uses `AudioContext.setSinkId` when the browser has it (Phase 5 sound-output setting).

## Phase 5: Touch Sample.app

SwiftPM executable `TouchSampleApp` + `scripts/build-app.sh` that assembles `Touch Sample.app` (Info.plist, bundle id
`com.savilion.touchsample`, ad-hoc codesign of *our* app only) into `dist/` (git-ignored).

- On launch: owner check; small Mac window with status (lab, panel server, bridge, Touch MIDI, Touch display) and
  Start / Stop buttons, sound output picker, "Open on Touch screen".
- Start: if port 8765 is not open, `open -a Terminal scripts/run-lab.command` (Terminal.app, so QEMU isn't
  throttled), wait for `/touch` to answer, start the bridge in-process, and show a borderless full-screen window with a
  WKWebView of `http://127.0.0.1:8765/touch` on the Touch's display (name contains "MPC Touch", else a 1280×800 screen
  that isn't the main one; PaperCut `RuntimeDevices.mpcScreen`). WKWebView config:
  `mediaTypesRequiringUserActionForPlayback = []`.
- Quit / Stop: stop the bridge (releases, LEDs off), then `python3 lab.py stop` (saves the project), close the window.
- If WKWebView's audio is bad, setting "Use Chrome for the Touch screen" opens
  `Google Chrome --app=http://127.0.0.1:8765/touch` placed on the Touch display instead.

## Phase 6

`mappings/default.json` is the remap file (Shift-scoped entries already). `touch-bridge --learn <TouchControl>`
prints the raw message of the next press so Sav can add it. Latency report (`--verbose`). Reconnect after unplug
(CoreMIDI setup-changed notification -> reconnect -> startup + full LED refresh; WebSocket auto-reconnect every 1 s).
`docs/MANUAL.md`.

### Touch integration correction (Sav's test, 2026-10-31)

The installed `mpc_touchd` supports PaperCut's mouseless CFMessagePort protocol, `com.savilion.papercut.touch`. Touch Sample registers a local receiver only after BridgeRunner's owner check. Each 24-byte packet contains Int32 type (1 press, 2 drag, 3 release), Int32 click count, and Double x/y in global top-left display points. The app converts to the Touch window's top-left viewport and delivers pointer events to the page, retaining the pressed target through release. It does not read USB, modify the driver, or move the Mac pointer. Stop releases the receiver. The name is retained for compatibility with the installed driver, not as an app identity.

The page starts its AudioContext/worklet/PCM worker when its panel WebSocket opens; taps are a retry path. Native WebKit permits autoplay. The right-hand controls and SCREEN 1–3 softkeys are touch controls; the emulated Sample LCD is an image of the firmware display, which has no native touch protocol.
