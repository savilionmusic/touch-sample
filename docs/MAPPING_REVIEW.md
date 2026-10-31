# Mapping review: MPC Sample functions vs the MPC Touch

Written 2026-10-31 (Claude, Opus) after reading the MPC Sample manual. Research and proposals only: no code, no
`mappings/default.json`, no `CONTROL_MAP.md`, no `vendor/` was changed, and nothing was sent to the Touch or the
emulator. Software reading only; **nothing here was tested on the Touch hardware**.

## Summary: the top gaps

1. **Metronome (your question).** It is reachable today, but only by a hidden combination: **hold SHIFT, then tap
   TAP TEMPO**. Each tap steps Off, On, Record (a pop-up on the Sample screen names the state; the lab's stock map
   confirms the pop-up). The Touch has no metronome button, and the gray text on the Touch's own Shift + TAP TEMPO
   is "sequence/master tempo", so nothing on the Touch points to it. Metronome volume is SHIFT + Q3 on the Sequence
   screen. **Proposal:** an always-visible on-screen METRO button (plus COUNT-IN, which is the same kind of hidden
   SHIFT + pad 4). This only adds.
2. **Several physical Touch buttons are not mapped by their printed label.** MAIN, MENU, UNDO, COPY, MINUS and PLUS have no raw ID
   yet (`hardware/touch-profile.json` has `id: null`; the Phase 1 guided capture has not been run). Five
   unnamed raw IDs are on file (0x34, 0x36, 0x37, 0x43, 0x7A) and are handed out in ID order as CHOP, MUTE, LOOP,
   SAMPLE, SAMPLE SELECT, whatever is printed on them. So an UNDO or COPY button can fire CHOP or MUTE today. Fix:
   run `touch-capture guided` (needs Sav's hands), then name them.
3. **REC does not record notes.** Touch REC (73) opens the Sample's *audio* sampler. On the Touch, REC arms
   *sequence* recording, which on the Sample is SEQ RECORD (today on OVERDUB).
4. **UNDO / REDO, COPY and CONTINUE are not on their own Touch buttons.** On the Sample they are only SHIFT + minus /
   plus, SHIFT + ERASE and SHIFT + PLAY. PLAY and PLAY START both start from the beginning, but the Touch prints
   PLAY as "from the pointer".
5. **28 of the 68 functions below are only SHIFT combinations with no label on the Touch** (count-in, half/double
   speed, time correct, resample, song, Step Edit, Flex Beat, Input Config, Save Sample, Project, Fader menu...).
   They work (the bridge holds SHIFT for the Sample), but nobody can see them. **Proposal:** an on-screen "Shift
   functions" sheet of one-tap buttons, and an optional pad legend that appears while SHIFT is held.
6. **Not reachable from the Touch at all:** AUDIO IN source and REC GAIN, SD card insert/eject, POWER (the app's
   Stop does this), and SEQ + SAMPLE held together (needs two touches).

**Counts:** 68 functions reviewed; 63 reachable today (28 of them only through hidden SHIFT combinations), 5 not
reachable. 29 additions, 6 moves needing approval, 6 waiting on the capture. Details under "Counts".

## Sources

- **Sample manual:** Akai Professional, *MPC Sample User Guide*, online edition, Manual Version 1.3.0 (RevA), which
  matches firmware 1.3.0.12: <https://www.akaipro.com/guides/mpc-sample/>. The PDF
  (<https://cdn.inmusicbrands.com/akai/sample/MPC%20Sample%20-%20User%20Guide%20-%20v1.0.pdf>, v1.0) could not be
  read as text, so the online edition is the source. It has no page numbers, so citations are chapter page plus
  item number. Codes: **F#n** = `features.htm` item n; **SQ** `sequence_mode`; **RS** `recording_sequences`; **ES**
  `editing_sequences`; **SE** `step_edit`; **SG** `song_mode`; **SM** `sample_mode`; **SR** `sample_record_mode`;
  **PP** `pad_play`; **IC** `input_configuration`; **LS** `loading_and_saving_samples`; **PR** `project`; **FD**
  `fader`; **MC** `midi_configuration`; **TC** `time_correct`; **CP** `compressor`; **FXP** `pad_fx`; **FB**
  `flex_beat`; **KFX** `knob_fx`. Where the guide is silent, **Lab** = the lab's own stock map
  (`vendor/virtual-mpc-sample/stock-map/build/notes_en.json`, observed on the stock app) and the printed Shift
  labels in `vendor/virtual-mpc-sample/panel/index.html`.
- **Touch printed labels:** Akai *MPC Touch User Manual*, Top Panel, items 1 to 23 (ManualsLib copy, pp. 15 to 17):
  <https://www.manualslib.com/manual/1237572/Akai-Mpc-Touch.html>. Cited as **T#n**.
- **Today's mapping:** `CONTROL_MAP.md`, `mappings/default.json`, `hardware/touch-profile.json`,
  `app/Sources/BridgeCore/BridgeCore.swift`, `docs/MANUAL.md`, `panel-ext/touch.html`.

## How the Touch reaches the Sample today (what matters for this review)

- **Plain buttons** send the mapped Sample button. **SHIFT** on the Touch is held to the Sample, so *any* other
  SHIFT + control (pads 1 to 16, Q1 to Q3, wheel, TAP TEMPO, PLAY, ERASE, REC, OVERDUB, 16 LEVEL, NOTE REPEAT,
  MINUS, PLUS) arrives at the Sample as its own SHIFT function. This is why the metronome etc. work.
- **Bridge-owned Shift combos** replace the Sample's: bank A to D (Shift = E to H), MAIN (Shift = SEQ), MENU
  (Shift = PAD FX), Q4 (Shift = swap FADER / MAIN VOLUME). The Sample's own SHIFT + SAMPLE (Input Config), SHIFT +
  SEQ (Step Edit), SHIFT + SAMPLE SELECT (Save Sample) and SHIFT + PAD FX (Flex Beat) are therefore not reached from
  those physical buttons.
- **On-screen** (`/touch`): SCREEN 1 to 3 (= B1 to B3), CHOP, MUTE, LOOP, PAD FX, MINUS, PLUS, banks E to H, SAMPLE,
  SEQ, SAMPLE SELECT, KNOB FX, FADER and MAIN VOLUME strips. There is **no** on-screen SHIFT, PLAY, STOP, record,
  TAP TEMPO, ERASE or NOTE REPEAT (those are physical). An on-screen tap while the physical Touch SHIFT is held
  should reach the Sample as SHIFT + that button, because both go to the same panel UART. That is how a few
  functions below are reached (**untested**).
- The direct-touch packet carries one x/y with no touch ID, so two on-screen touches at once are treated as not
  reachable.

## Touch buttons: printed label, what it does today, what it should do

"ID?" = the raw ID is not captured yet (`id: null`), so the mapping is inactive.

| Touch button (T#) | Raw ID, status | Does today | Sample function it matches | Proposal | Change |
|---|---|---|---|---|---|
| PLAY (T#18, "from the pointer") | 82, verified | Sample PLAY (from the beginning) | CONTINUE = SHIFT + PLAY (F#30) | PLAY = CONTINUE | MOVE |
| PLAY START (T#19) | 83, verified | STOP then PLAY | PLAY (from the beginning) | PLAY START = PLAY, drop the STOP | MOVE |
| STOP (T#20) | 81, verified | STOP | STOP, double press stops all (F#31) | keep | KEEP |
| REC (T#21, arms sequence recording) | 73, verified | SAMPLE RECORD (audio sampler) | SEQ RECORD (F#29, RS) | REC = SEQ RECORD; SHIFT + REC = SAMPLE RECORD | MOVE |
| OVERDUB (T#22) | 80, press not measured | SEQ RECORD | none (the Sample overdubs by itself after the first pass, RS) | keep on SEQ RECORD, so REC and OVERDUB both arm | KEEP |
| TAP TEMPO (T#23; Shift = seq/master tempo) | 53, verified | TAP TEMPO; SHIFT + it = METRO (hidden) | TAP TEMPO, SHIFT = METRO (F#18) | keep; add on-screen METRO | ADD |
| NOTE REPEAT (T#8; Shift = Latch) | 11, candidate | NOTE REPEAT; SHIFT = Triplet | same (F#15) | keep; follow the Sample's Shift (Triplet) | KEEP |
| FULL LEVEL (T#9; Shift = Half Level) | 39, verified | bridge holds velocity 127 | Full Level = SHIFT + pad 1 (F#19) | keep. Optional: SHIFT + FULL LEVEL = latch 64 as printed (today it just toggles Full Level again) | optional MOVE |
| 16 LEVEL (T#10) | 40, verified | 16 LEVELS; SHIFT = TYPE | same (F#27) | keep | KEEP |
| ERASE (T#11) | 9, candidate | ERASE | same (F#14) | keep | KEEP |
| Pad bank A to D (T#7; Shift = E to H) | 35 to 38, verified | bridge walks PAD BANK; SHIFT = E to H | PAD BANK steps A to H (F#16) | keep | KEEP |
| Q-LINK (T#5; Shift = previous column) | 0, verified | toggles Q4 FADER / MAIN VOLUME | none | keep (Sav's 2026-10-31 correction) | KEEP |
| Q1 to Q3 (T#4) | 16 to 18, Q1 verified | K1 to K3 | K1 to K3 (F#12) | keep | KEEP |
| Q4 (T#4) | 19, candidate | FADER, or MAIN VOLUME on bank B | FADER, MAIN VOLUME (F#4, F#13) | keep | KEEP |
| Data dial and push (T#3) | CC 100 / note 111, verified | DATA turn, DATA push | encoder (F#9) | keep | KEEP |
| SHIFT (T#12) | 49, verified | SHIFT | SHIFT (F#8) | keep | KEEP |
| MAIN/TRACK (T#14; Shift = Track view) | ID? | MAIN = SAMPLE, SHIFT = SEQ | SAMPLE (F#20), SEQ (F#21) | keep; capture the ID | CAPTURE |
| MENU/BROWSE (T#13; plain = Mode menu, Shift = Browser) | ID? | MENU = SAMPLE SELECT (browser), SHIFT = PAD FX | SAMPLE SELECT (F#17) | keep. Print-matching option: plain = PAD FX, Shift = SAMPLE SELECT. Not needed | CAPTURE |
| UNDO/REDO (T#15) | ID? | **mapped to CHOP** | SHIFT + minus / plus (F#10) | UNDO = SHIFT + MINUS; SHIFT + UNDO = SHIFT + PLUS (a "chord" action: hold SHIFT, tap the target) | MOVE |
| COPY/DELETE (T#16) | ID? | **mapped to MUTE** | SHIFT + ERASE (F#14) | COPY = SHIFT + ERASE (chord) | MOVE |
| minus, plus (T#17) | ID? | MINUS, PLUS | MINUS, PLUS (F#10) | keep; capture the IDs | CAPTURE |
| Display Brightness +/- (T#2) | unknown | not mapped | none | leave alone; may be two of the unnamed IDs below | CAPTURE |
| Five unnamed buttons | 0x34, 0x37, 0x43 seen in PaperCut's log; 0x36, 0x7A from its LED list | CHOP, LOOP, SAMPLE (0x34, 0x37, 0x43 in ID order), MUTE (0x36), SAMPLE SELECT (0x7A) | depends on the printed label | after the capture, give each its label's mapping and drop the spares list | CAPTURE |

The reason these rows say CAPTURE and not MOVE: with `id: null` the mapping does nothing today; the captured ID
decides which row above applies. The UNDO, COPY, REC and PLAY rows are MOVE because `CONTROL_MAP.md` lists them as
the accepted defaults.

## Function table

Status = best way Sav has today: **OK** a Touch control does it directly; **SCREEN** an on-screen button does it;
**HIDDEN** works only through an unlabelled SHIFT combination (or a SHIFT + on-screen tap); **NO** cannot be reached.
Change: **ADD** only adds a way in; **MOVE** changes something already in `CONTROL_MAP.md` and needs Sav's approval;
**CAPTURE** waits for the guided capture; **KEEP** no change.

### Transport and recording

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 1 | Play from the beginning (F#30) | PLAY and PLAY START both do it | OK | PLAY START | MOVE |
| 2 | Continue from the playhead (F#30, SHIFT + PLAY) | SHIFT + PLAY | HIDDEN | PLAY | MOVE |
| 3 | Stop; double press stops all audio (F#31) | STOP | OK | STOP | KEEP |
| 4 | Arm sequence recording; overdub follows by itself (F#29, RS) | OVERDUB only; REC opens the sampler | OK | REC (and OVERDUB) | MOVE |
| 5 | Record an audio sample (F#28, SR) | REC | OK | SHIFT + REC | MOVE |
| 6 | Recall the last 25 s of input (F#28, SHIFT + SAMPLE RECORD) | SHIFT + REC | HIDDEN | on-screen RECALL (needed once REC moves) | ADD |
| 7 | Recall the last loop's pad hits (F#29, RS) | SHIFT + OVERDUB | HIDDEN | on-screen RECALL SEQ | ADD |
| 8 | Erase a pad's events or a slice while recording (F#14, RS, PP) | hold ERASE, hit pad | OK | ERASE | KEEP |
| 9 | Erase automation, ERASE + K1 to K3 or FADER, B3 confirms (RS) | hold ERASE, turn Q1 to Q3 (Q4 on FADER); SCREEN 3 confirms | OK | ERASE | KEEP |

### Tempo, click, timing

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 10 | **Metronome Off / On / Record** (SQ, F#18, Lab) | **hold SHIFT, tap TAP TEMPO** | HIDDEN | on-screen METRO; keep SHIFT + TAP TEMPO | ADD |
| 11 | Metronome volume (SQ, SHIFT + K3) | SHIFT + Q3 on the Sequence screen | HIDDEN | name it on the Shift sheet and legend | ADD |
| 12 | Count-in, one bar (SQ, F#19, SHIFT + pad 4) | SHIFT + pad 4 | HIDDEN | on-screen COUNT-IN, next to METRO | ADD |
| 13 | Tap tempo (F#18, SQ) | TAP TEMPO | OK | TAP TEMPO | KEEP |
| 14 | Exact BPM window (SQ: hold B1 and turn the encoder) | hold on-screen SCREEN 1, turn the wheel | SCREEN | keep | KEEP |
| 15 | Sequence BPM or global BPM (SQ, B2) | on-screen SCREEN 2 | SCREEN | keep | KEEP |
| 16 | Record quantize on/off (SQ B3, ES SHIFT + pad 10) | on-screen SCREEN 3, or SHIFT + pad 10 | SCREEN | keep; list on the sheet | ADD |
| 17 | Q value, length, swing (SQ K2, K1, K3) | Q2, Q1, Q3 | OK | Q1 to Q3 | KEEP |
| 18 | Any length 1 to 128, time signature (SQ SHIFT + K1, SHIFT + K2) | SHIFT + Q1, SHIFT + Q2 | HIDDEN | name them on the sheet and legend | ADD |
| 19 | Time Correct menu (TC, SHIFT + pad 14; SHIFT + minus undoes it) | SHIFT + pad 14 | HIDDEN | Shift sheet | ADD |

### Sequences and song

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 20 | Half Seq, Double Seq (ES, SHIFT + pad 2, 3) | SHIFT + pad 2 or 3 | HIDDEN | Shift sheet | ADD |
| 21 | Half Speed, Double Speed (ES, SHIFT + pad 6, 7) | SHIFT + pad 6 or 7 | HIDDEN | Shift sheet | ADD |
| 22 | Resample a sequence to a pad (ES, SHIFT + pad 11) | SHIFT + pad 11 | HIDDEN | Shift sheet | ADD |
| 23 | Song mode (SG, SHIFT + pad 12) | SHIFT + pad 12 | HIDDEN | Shift sheet | ADD |
| 24 | Step Edit (SE, SHIFT + SEQ) | SHIFT held + on-screen SEQ (physical SHIFT + MAIN gives plain SEQ) | HIDDEN | Shift sheet | ADD |
| 25 | Sequence mode and queue a sequence (SQ, F#21) | on-screen SEQ; SHIFT + MAIN once MAIN is captured | SCREEN | MAIN, Shift | CAPTURE |
| 26 | Hold SEQ + SAMPLE: Sequence screen with Sample pads (SQ) | needs two touches at once, or a captured MAIN | NO | hold on-screen SEQ, press MAIN (after capture) | CAPTURE |
| 27 | Undo / Redo, incl. recorded events (F#10, RS) | SHIFT held + on-screen MINUS / PLUS; the UNDO button is not captured and would fire CHOP | HIDDEN | UNDO, SHIFT + UNDO | MOVE |
| 28 | Copy a sample or sequence (F#14, SHIFT + ERASE) | SHIFT + ERASE; the COPY button is not captured and would fire MUTE | HIDDEN | COPY | MOVE |

### Samples and pad modes

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 29 | Sample mode (F#20, SM) | on-screen SAMPLE; MAIN not captured; an unnamed button fires SAMPLE | SCREEN | MAIN | CAPTURE |
| 30 | Input Configuration (IC, SHIFT + SAMPLE) | SHIFT held + on-screen SAMPLE | HIDDEN | Shift sheet | ADD |
| 31 | Chop on/off (PP, F#24) | on-screen CHOP (an unnamed button also fires it) | SCREEN | keep | KEEP |
| 32 | Note On (PP, SHIFT + CHOP) | SHIFT held + on-screen CHOP | HIDDEN | Shift sheet | ADD |
| 33 | Loop; Reverse (PP, F#25; SHIFT + LOOP) | on-screen LOOP; Reverse via SHIFT + on-screen LOOP | SCREEN | Reverse on the sheet | ADD |
| 34 | Mute; Unmute all (PP, F#26; SHIFT + MUTE) | on-screen MUTE; Unmute via SHIFT + on-screen MUTE | SCREEN | Unmute all on the sheet | ADD |
| 35 | 16 Levels; Type (PP, F#27) | 16 LEVEL; SHIFT + 16 LEVEL | OK | keep | KEEP |
| 36 | Full Level (F#19, SHIFT + pad 1) | FULL LEVEL (bridge); SHIFT + pad 1 also works | OK | keep | KEEP |
| 37 | Note Repeat; rates 1/8, 1/16, 1/32 on B1 to B3; Triplet (F#15, Lab) | NOTE REPEAT; on-screen SCREEN 1 to 3; SHIFT for Triplet | OK | keep | KEEP |
| 38 | Pad banks A to H (F#16) | bank A to D, SHIFT = E to H; on-screen E to H | OK | keep | KEEP |
| 39 | Slices: Extract, Split, Merge (PP, SHIFT + B1 to B3) | SHIFT held + on-screen SCREEN 1 to 3 | HIDDEN | name them on the sheet | ADD |
| 40 | Loop Lock, Normalize (SM, SHIFT + B1, B2) | SHIFT held + on-screen SCREEN 1, 2 | HIDDEN | name them on the sheet | ADD |
| 41 | Trim Sample, Warp mode (F#19, SM, SHIFT + pad 13, 15) | SHIFT + pad 13 or 15 | HIDDEN | Shift sheet | ADD |
| 42 | Sample pages and values (SM: B1 to B3, K1 to K3, encoder push, minus/plus, SHIFT + K) | SCREEN 1 to 3; Q1 to Q3; wheel and push; on-screen MINUS / PLUS | SCREEN | keep | KEEP |
| 43 | Select a sample without playing it (SM: hold SAMPLE + pad) | hold on-screen SAMPLE, hit a pad | SCREEN | keep | KEEP |
| 44 | Sample Record settings: monitor, source, length, threshold (SR: B1, K1 to K3) | SCREEN 1, Q1 to Q3 | OK | keep | KEEP |

### Effects, browser, menus

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 45 | Pad FX (FXP, F#22) | on-screen PAD FX; SHIFT + MENU once MENU is captured | SCREEN | keep | CAPTURE |
| 46 | Flex Beat (FB, SHIFT + PAD FX) | SHIFT held + on-screen PAD FX | HIDDEN | Shift sheet | ADD |
| 47 | Knob FX; all pads (B2), bypass (B3) (KFX, F#23) | on-screen KNOB FX; SCREEN 2, 3 | SCREEN | keep | KEEP |
| 48 | FX Select (KFX, SHIFT + KNOB FX) | SHIFT held + on-screen KNOB FX | HIDDEN | Shift sheet | ADD |
| 49 | Compressor (CP, SHIFT + pad 5) | SHIFT + pad 5 | HIDDEN | Shift sheet | ADD |
| 50 | Sample browser (LS, F#17) | on-screen SAMPLE SELECT; MENU not captured | SCREEN | MENU | CAPTURE |
| 51 | Browser: back, internal/external drive, preview (LS: B1 to B3) | on-screen SCREEN 1 to 3, wheel | SCREEN | keep | KEEP |
| 52 | Save Sample, name entry (LS, SHIFT + SAMPLE SELECT) | SHIFT held + on-screen SAMPLE SELECT (physical SHIFT + MENU is PAD FX) | HIDDEN | Shift sheet | ADD |
| 53 | Project: load, save, new (PR, SHIFT + pad 16) | SHIFT + pad 16 | HIDDEN | Shift sheet | ADD |
| 54 | Fader menu: what the fader controls (FD, SHIFT + pad 9) | SHIFT + pad 9, then Q4 on FADER | HIDDEN | Shift sheet | ADD |
| 55 | MIDI Config, takeover modes, factory reset (MC, SHIFT + pad 8) | SHIFT + pad 8 | HIDDEN | Shift sheet | ADD |

### Knobs, fader, wheel, buttons

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 56 | K1 to K3 (F#12) | Q1 to Q3 | OK | Q1 to Q3 | KEEP |
| 57 | Second parameters, SHIFT + K1 to K3 (SM, KFX, CP) | SHIFT + Q1 to Q3 | HIDDEN | name them in the legend | ADD |
| 58 | Fader (F#13) | Q4 on bank A; on-screen strip | OK | Q4 | KEEP |
| 59 | Main volume (F#4) | Q4 on bank B, SHIFT + Q4; on-screen strip | OK | Q4 | KEEP |
| 60 | Encoder: turn, push, SHIFT + turn (move by Q), SHIFT + push (back) (F#9, SQ, SM) | data dial and push; SHIFT | OK | keep | KEEP |
| 61 | Minus / plus (F#10) | on-screen MINUS / PLUS; Touch buttons not captured | SCREEN | minus/plus buttons | CAPTURE |
| 62 | SHIFT (F#8) | SHIFT | OK | SHIFT | KEEP |
| 63 | Pads 1 to 16, velocity and poly aftertouch (F#19) | pads 1 to 16 (pad 1 verified; pressure untested) | OK | pads | KEEP |
| 64 | B1 to B3 function buttons (F#11) | on-screen SCREEN 1 to 3 only | SCREEN | keep | KEEP |

### Rear panel and the emulator (outside the Touch)

| # | Function (manual) | Today on the Touch | Status | Proposed Touch control | Change |
|---|---|---|---|---|---|
| 65 | AUDIO IN source and REC GAIN (F#3, F#4; `docs/PANEL.md`) | stock panel page only, not `/touch` | NO | ask Sav whether sampling from an input is wanted; if so, a small input selector on `/touch` | ADD (later) |
| 66 | SD card insert / eject (F#9; `docs/PANEL.md`) | stock panel page only; the card is inserted at start when `sdcard/` has files | NO | not needed unless cards are swapped while running | none |
| 67 | POWER, shut down (F#1; `docs/PANEL.md`) | stock panel page only; the app's Stop saves and shuts down | NO | none | none |
| 68 | MIDI IN/OUT, SYNC OUT, PHONES, USB (F#2, F#6 to F#8) | not Touch controls; SYNC OUT and USB audio are not emulated (`docs/PANEL.md`) | NO | none | none |

## Counts

Counts are for the 68 rows of the function table; a row groups one function with its close variants.

| Measure | Rows |
|---|---|
| Reachable today (OK 19 + SCREEN 16 + HIDDEN 28) | **63 of 68** |
| of those, reachable only by an unlabelled SHIFT combination (HIDDEN) | 28 |
| **Not reachable** (NO) | **5**: rows 26, 65, 66, 67, 68 |
| Proposed: ADD (nothing accepted is touched) | 29 |
| Proposed: MOVE (needs Sav's approval) | 6 (function rows 1, 2, 4, 5, 27, 28) |
| Proposed: CAPTURE (waits for the guided capture) | 6 |
| KEEP / nothing to do | 27 |

Of the 5 not reachable, only row 26 (SEQ + SAMPLE held together) is a Sample function Sav could miss, and a captured
MAIN button fixes it. Row 65 (audio input) is optional; rows 66 to 68 are rear-panel items the Touch was never meant
to carry. In the Touch-button table (23 rows): 5 MOVE (PLAY, PLAY START, REC, UNDO, COPY), 1 optional MOVE (FULL
LEVEL), 5 CAPTURE, 1 ADD (TAP TEMPO's on-screen METRO), 11 KEEP.

## Proposals, in order

**A. Adds only (no accepted mapping changes; safe to do first).** All are on the `/touch` page and in the docs, and send
only Sample frames. None sends anything new to the Touch.
1. **METRO and COUNT-IN buttons, always visible.** Each is a one-tap "chord" the page sends: SHIFT down, TAP TEMPO (or
   pad 4) down, release, SHIFT up, about 30 ms apart. Placement on the page is Sav's call because the right column
   is full (the faders could be shortened).
2. **A "Shift functions" sheet** behind one button: one-tap buttons for the HIDDEN rows (HALF / DOUBLE SEQ and SPEED,
   TIME CORRECT, RESAMPLE, SONG, STEP EDIT, INPUT CONFIG, NOTE ON, REVERSE, UNMUTE ALL, TRIM SAMPLE, WARP,
   COMPRESSOR, FLEX BEAT, FX SELECT, SAVE SAMPLE, PROJECT, FADER MENU, MIDI CONFIG, RECALL, UNDO, REDO, COPY,
   CONTINUE, TRIPLET), each labelled as the Sample prints it.
3. **A pad legend:** while the Touch SHIFT is held, the page shows the 16 pad functions over the Sample picture
   (pad 1 FULL LEVEL ... pad 16 PROJECT). Needs a `shift` flag in the bridge's status message to the page.
4. **Guard:** if the physical SHIFT is already held, the page skips its own SHIFT press and release, so it cannot
   drop the Sample's SHIFT under Sav's finger. This is why the status message needs the flag.
5. **A printed cheat sheet** in `docs/MANUAL.md`: the Touch's gray Shift labels against what Shift really does on
   the Sample (NOTE REPEAT latch vs Triplet; FULL LEVEL half vs full; TAP TEMPO seq/master vs METRO; MENU browser vs
   PAD FX; MAIN track vs SEQ).

**B. Needs Sav's approval (moves something in `CONTROL_MAP.md`).** Needs one small bridge addition: a "chord" action
that holds SHIFT while it taps a Sample button (the existing `macro` taps buttons one after another, never together).
1. REC = SEQ RECORD; SHIFT + REC = SAMPLE RECORD (audio). OVERDUB stays on SEQ RECORD. The REC and OVERDUB lights then
   both follow the Sample's SEQ RECORD light.
2. PLAY = CONTINUE (SHIFT + PLAY); PLAY START = Sample PLAY, without the STOP in front. Check in the lab that CONTINUE
   behaves when sequence recording is armed.
3. UNDO = SHIFT + MINUS; SHIFT + UNDO = SHIFT + PLUS.
4. COPY = SHIFT + ERASE.
5. Optional: SHIFT + FULL LEVEL latches velocity 64 (the Touch's "Half Level").

**C. Needs Sav's hands.**
1. Run `touch-capture guided` in Terminal.app (Phase 1) to get the IDs of MAIN, MENU, UNDO, COPY, MINUS, PLUS and
   Display Brightness +/-, and name the five unnamed buttons. Then retire the spares list, which is the cause of
   gap 2.
2. Check on the hardware: SHIFT + TAP TEMPO shows "Metronome On"; SHIFT held + an on-screen tap reaches the Sample
   (for example SHIFT + on-screen CHOP toggles Note On); NOTE REPEAT, ERASE and OVERDUB IDs are right (all three
   are still "candidate").

## Not changed here

No mapping or layout Sav has accepted was touched. Items marked MOVE stay as they are until Sav says yes.
