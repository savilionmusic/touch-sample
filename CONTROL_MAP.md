# Control map: MPC Touch ↔ MPC Sample (emulated)

Sources, 2026-10-30:
- **Touch** = PaperCut (`~/Documents/Codex/PaperCut`): `app/Sources/MPCApp/Instrument.swift` (`TouchControlMap`,
  `MIDIInput.consume`), `app/Sources/MPCRealtime/ControllerSetup.c`, `outputs/mpc-app-plan/CONTROL_MAP.md`,
  `outputs/mpc-touch-research/RESEARCH.md`, `docs/handoffs/GPT_CONTEXT.md` "Hardware facts".
  Pad colours: PaperCut commit `fb4885e` (branch `fix/bugs-batch-2`, copy `~/Documents/Codex/PaperCut-bf2`),
  `app/Sources/MPCApp/PadLights.swift`, hardware-tested on Sav's Touch 2026-10-30. Read-only reference, never edited.
- **Sample** = `virtual-mpc-sample/panel/controls.json` and `docs/PANEL.md` (protocol verified on hardware 2026-10-22).

Status: **verified** = measured on Sav's Touch (PaperCut). **candidate** = from the MPC Live/X map or a code
comment, not yet measured on this Touch. **proposed** = a choice for Sav to confirm. All IDs are decimal unless
written `0x..`. Channel 1 unless stated.

## The Touch's buttons

Reviews count 22 backlit function buttons: MAIN and MENU under the screen; pad banks A–D, NOTE REPEAT, FULL LEVEL,
16 LEVEL and ERASE above the pads; REC, OVERDUB, STOP, PLAY, PLAY START; SHIFT, TAP TEMPO, the Q-LINK button. That
is 18; the Phase 1 capture finds the rest (PaperCut's notes expect UNDO, COPY, MINUS and PLUS) and their note numbers.

## Assignment rules (Sav, 2026-10-30: "make the best educated guess")

1. **Same label, same job.** Where the Touch and the Sample share a function, the button does that function.
2. **The bridge keeps a Touch button's meaning when it can.** FULL LEVEL and the four bank buttons work as labelled,
   done inside the bridge.
3. **Spare buttons get the Sample's most-used missing buttons**: MAIN/MENU become the Sample's mode and browse keys.
4. **Everything else is on the touch screen**, always visible: CHOP, MUTE, LOOP, PAD FX, SCREEN 1–3, PLUS, MINUS,
   FADER, MAIN VOLUME, banks E–H.
5. **Bridge-owned Shift combinations are few** (MAIN, MENU, bank A–D, Q4) because the Sample has Shift functions of its
   own. For those, the bridge sends SHIFT release to the Sample first, sends the target, then re-presses SHIFT if it
   is still held. Every other Shift combination passes straight through.
6. All of this lives in one editable file (`mappings/default.json`); these are defaults, not fixed.

## Touch → Sample (input)

| Touch control | Touch raw (port) | Status | → Sample | Notes |
|---|---|---|---|---|
| Pads 1–16 | Ch.10 notes 37 36 42 82 40 38 46 44 48 47 45 43 49 55 51 53, `99`/`89`, pressure `A9` (Public) | verified (pad 1; PaperCut ships all 16) | same notes, same frames | Identical numbering. Pressure `A9` untested on the Sample |
| Q-Link 1–3 | CC 16–18, absolute-like 0–127 (Public) | Q1 verified, Q2–3 candidate | K1–K3 = CC 16–18 | Pass-through |
| Q-Link 4 | CC 19 (Public) | candidate | **FADER = CC 20** (pad volume) | Must remap: CC 19 on the Sample is MAIN VOLUME |
| Shift + Q-Link 4 | | default | Temporarily use the opposite Q4 bank | Bank A: MAIN VOLUME = CC 19; bank B: FADER = CC 20. Q-Link bank LEDs show the active target |
| Q-Link touch 1–4 | notes 84–87 (`0x54–0x57`) | Q1 verified | not sent | The Sample has no knob touch. The `/touch` page shows that knob's name and value while touched |
| Q-LINK button | note 0 | verified | Cycle Q-Link bank A/B | Sav correction 2026-10-31: stays a bank button. A: Q4 FADER; B: Q4 MAIN VOLUME. Q1–Q3 remain K1–K3. Shift temporarily swaps Q4 to the other bank. KNOB FX remains on screen |
| Data wheel turn | CC 100: `01` = right, `7F` = left | verified | same | Pass-through |
| Data wheel push | note 111 (`0x6F`) | verified | same | Pass-through |
| SHIFT | note 49 (`0x31`) | verified | same | Pass-through (see rule 5) |
| PLAY | note 82 (`0x52`), arrives on Private | verified | PLAY = 82 | Dedupe Public/Private |
| STOP | note 81 (`0x51`), Private | verified | STOP = 81 | |
| PLAY START | note 83 (`0x53`), Private | verified | STOP then PLAY (macro) | Plays from the top. Verify in Phase 2 that the Sample's PLAY after STOP restarts; if not, find the Sample's own locate-to-start and use that |
| REC | note 73 (`0x49`), Private | verified | SAMPLE RECORD = 73 | Same ID |
| OVERDUB | note 80 (`0x50`)? | candidate (LED boot list only) | SEQ RECORD = 80 | Confirm in Phase 1 |
| TAP TEMPO | note 53 (`0x35`) | verified in code | TAP TEMPO = 53 | |
| NOTE REPEAT | note 11 (`0x0B`) | candidate | NOTE REPEAT = 11 | |
| ERASE | note 9 | candidate | ERASE = 9 | |
| 16 LEVEL | note 40 (`0x28`) | verified | 16 LEVELS = 40 | |
| FULL LEVEL | note 39 (`0x27`) | verified | not sent; bridge latches full velocity | While on, every pad hit goes out at velocity 127; the FULL LEVEL LED shows it (the Sample has no Full Level button) |
| Pad bank A–D | notes 35–38 (`0x23–0x26`) | verified | PAD BANK (35), pressed N times | The Sample cycles A→H with one button. Read the current bank from LEDs 57–64, then press until it matches. **Never pass 36 through** (36 = SAMPLE SELECT on the Sample) |
| Shift + pad bank A–D | | default | banks E–H the same way | |
| MAIN | Phase 1 | default | SAMPLE = 6 | The Sample's main mode |
| Shift + MAIN | | default | SEQ = 7 | |
| MENU | Phase 1 | default | SAMPLE SELECT = 36 | Browse samples |
| Shift + MENU | | default | PAD FX = 1 | |
| MINUS / PLUS (if found) | Phase 1 | default | MINUS = 55 / PLUS = 54 | |
| Any other spare buttons (UNDO, COPY, …) | Phase 1 | default | CHOP = 75, MUTE = 43, LOOP = 74, in that order | Also always on screen |

Everything not in this table is dropped and logged once ("unmapped Touch control").

## Sample controls with no Touch button (on-screen touch buttons, Phase 4)

SAMPLE 6, SEQ 7, PAD FX 1, KNOB FX 0, CHOP 75, MUTE 43, LOOP 74, SAMPLE SELECT 36, PLUS 54, MINUS 55,
SCREEN 1–3 = 12–14 (the buttons above the device's screen), FADER CC 20, MAIN VOLUME CC 19, PAD BANK E–H.
Buttons send `90 id 7F` on press and `80 id 00` on release.

Page-side chords (added 2026-10-31, `/touch` only, no mapping change; they send Sample frames straight from the page, like
the buttons above): **METRO** = SHIFT (49) down, TAP TEMPO (53) down, TAP TEMPO up, SHIFT up, 30 ms apart (metronome Off /
On / Record; `90 31 7F`, `90 35 7F`, `80 35 00`, `80 31 00`). **COUNT-IN** = the same with pad 4 (`99 52 7F`, `89 52 00`;
one-bar count-in). **SHIFT ?** sends nothing: it opens the cheat sheet of Shift combos. All three sit at the right end of the
SCREEN 1–3 row. Not verified on the Touch hardware.

## Sample → Touch (lights)

| Sample app sends | Meaning | → Touch | Status |
|---|---|---|---|
| `B0 id state` for a button | button LED: 0 off, 1 dim, ≥2 lit; bicolour = 3·A+B | `B0 id value` on **Public** for the mapped Touch button (same ID where shared: 49, 82, 81, 73, 80, 53, 40, 11, 9, 0) | Touch form verified for 0x27/0x28 and the boot set (0x31 0x34 0x43 0x7A 0x36 0x52 0x51 0x49 0x50 0x53 0x35); other IDs Phase 1 |
| `B0 57..64 state` | pad bank A–H | Touch bank LEDs CC 35–38 (`0x23–0x26`), value 3 lit / 0 off. E–H proposed: same LED at 1 (dim) | verified form (value 3) |
| `F0 47 7F 5C 65 00 04 pad R G B F7` | pad colour, 7-bit RGB. `pad` 0–15 = Sample pad 1–16 of the current bank; 16 is the Sample's extra LED and is dropped | `F0 47 7F 37 65 00 04 pad R G B F7` on **Public** (product `5C → 37`; `pad` unchanged, `indexMap` = identity), components clamped to 0–127 | **verified** by PaperCut `fb4885e` (branch `fix/bugs-batch-2`, `PadLights.swift`): hand-tested on Sav's Touch 2026-10-30, all 16 pads light, index 0 = pad 1. Pads of the 16 the Sample has not coloured are sent black. Sent on connect and on the 0.7 s / 1.5 s refreshes (all 16, one per 20 ms, 320 ms), afterwards only the pads that changed; the 8 s lit-only refresh sends none; all 16 go off when the bridge stops |
| `F0 47 7F 5C 42 00 00 F7` | start request; the panel server answers with MAIN VOLUME | not forwarded | the panel server already handles it |
| — (bridge state) | Q-Link bank LEDs CC 90–93 (`0x5A–0x5D`), value 2 lit | first LED = Q4 on FADER, second = Q4 on MAIN VOLUME | verified form |
| — (bridge state) | FULL LEVEL LED, note 39 (`0x27`) | 2 when the bridge's full velocity is on | verified |
| `B0 6 / 7 / 36 / 1` (SAMPLE, SEQ, SAMPLE SELECT, PAD FX) | mode LEDs | MAIN lit for SAMPLE, dim for SEQ; MENU lit for SAMPLE SELECT, dim for PAD FX | proposed; MAIN/MENU LED IDs from Phase 1 |

## Touch startup (owned by our bridge, copied from PaperCut's accepted init)

On Public, in this order, once: `F0 47 7F 37 62 00 01 65 F7` (unlock), `F0 47 00 37 64 00 01 01 F7` (gate),
`F0 47 00 37 64 00 03 00 01 01 F7` (backlight / display on). Then LED baseline. Nothing else, nothing on Private
except what PaperCut already sends. Never send `0x5A`.

Everything else the bridge may write to the Touch, all of it already used by PaperCut (the C layer refuses the rest):
- Public: `B0 id v` button LEDs; the pad-colour SysEx `F0 47 7F 37 65 00 04 <pad 0–15> R G B F7` (colours 0–127,
  verified by PaperCut `fb4885e`, `PadLights.swift`; one per pad, never in a burst: the Touch keeps only the first of
  a burst, so each leaves 20 ms after the last, per-pad updates still queued are coalesced, and only changed pads are
  sent). No other SysEx besides the three above, and never one with `0x5A`.
- Private: only `B0 23..26` and `B0 5A..5D`, no SysEx.

Pad numbering: the pad-colour index is the pad's slot in the pad note table (`37 36 42 82 40 38 46 44 48 47 45 43 49
55 51 53`, the Touch's PAD 1–16 and the Sample's PAD 1–16 alike; PaperCut `TouchControlMap.padNotes`, whose `PadLights`
index is the same slot, and "pad 1 bottom-left, as on the MPC"). So Sample pad i+1 → index i → the Touch pad that plays
that sound. The Sample's bank does not change the index: the 16 Touch pads always play the Sample's current bank and the
colour frame only carries pads 0–15. Only index 0 = pad 1 was looked at by hand in PaperCut; the order of the other 15
follows from the table and still needs Sav's eyes.
