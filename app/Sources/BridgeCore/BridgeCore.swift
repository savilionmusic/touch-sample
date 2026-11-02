import Foundation

/// The bridge's brain: pure logic with no CoreMIDI, no network and no clock. Inputs are Touch packets,
/// Sample events and timer callbacks; outputs are `[Effect]`. Delays are returned as `Effect.after` and timer
/// effects come back through `handle(timer:)`, so everything is deterministic and testable.
///
/// Not thread-safe: the host calls it from one serial queue.
public final class BridgeCore {
    public let config: BridgeConfig
    public let lightsEnabled: Bool
    /// Human-readable notes from setup (spares assigned, entries skipped). The host may print them.
    public private(set) var setupNotes: [String] = []

    private let profile: TouchProfile
    private let mapping: Mapping
    private let controls: ControlsTable

    // Static lookups
    private var padIndexByNote: [Int: Int] = [:]        // Touch pad note -> pad index 0..15
    private var noteNames: [Int: String] = [:]          // channel<<8 | note -> control name
    private var ccNames: [Int: String] = [:]            // channel<<8 | cc -> control name
    private var actions: [String: MappingEntry] = [:]   // buttons + wheel + assigned spares
    private var ledOf: [String: Int] = [:]              // Touch control name -> Touch LED id
    private var bankLedIds: [Int] = []                  // Sample bank LEDs A..H (57...64)

    // Run-time state
    private var parsers: [PortRole: MidiStreamParser] = [.public: MidiStreamParser(), .private: MidiStreamParser()]
    private var connected = false
    private var fullLevel = false
    private var qlinkAlternate = false
    private var touchShift = false                      // SHIFT is held on the Touch
    private var sampleShift = false                     // what the Sample believes
    private var buttonDown: [String: Set<PortRole>] = [:]
    private var held: [Held] = []
    private var heldPads: [Int: UInt8] = [:]            // Touch pad note -> note sent to the Sample
    private var qTouched = [Bool](repeating: false, count: 4)
    private var knobValue = [Int](repeating: 0, count: 4)
    private var loggedUnknown = Set<Int>()
    private var sampleLeds: [Int: Int] = [:]
    private var samplePads: [Int: [Int]] = [:]
    private var sentLeds: [LedKey: Int] = [:]
    private var sentPads: [Int: [Int]] = [:]
    private var walk: Walk?
    private var walkSeq = 0
    private var lastStatus = ""

    private struct Held {
        var name: String
        var release: [[UInt8]]
        var combo: Bool        // started with a bridge-owned Shift combination (SHIFT was released to the Sample)
        var sends: Bool        // `send` kind: re-press SHIFT when this releases (bank walks restore on finish)
    }
    private struct LedKey: Hashable, Comparable {
        let port: PortRole
        let id: Int
        static func < (a: LedKey, b: LedKey) -> Bool { a.port != b.port ? a.port < b.port : a.id < b.id }
    }
    private enum Phase { case idle, pressed, waiting }
    private struct Walk {
        var target: Int
        var seq: Int
        var presses = 0
        var phase = Phase.idle
        var bankAtPress: Int?
        var advance = false
    }

    // MARK: setup

    public init(config: BridgeConfig, lights: Bool = true) {
        self.config = config
        self.profile = config.profile
        self.mapping = config.mapping
        self.controls = config.controls
        self.lightsEnabled = lights

        for c in profile.controls {
            let key = c.channel << 8 | c.id
            switch c.kind {
            case .pad:
                if let n = Int(c.name.dropFirst(4)), c.name.hasPrefix("PAD "), (1...16).contains(n) { padIndexByNote[c.id] = n - 1 }
            case .note:
                noteNames[key] = c.name
                if let l = c.led { ledOf[c.name] = l }
            case .cc:
                ccNames[key] = c.name
            }
        }
        for (n, e) in mapping.buttons { actions[n] = e }
        for (n, e) in mapping.wheel { actions[n] = e }

        // Spare buttons: profile "spares" without a mapping take mappings.spares.order in turn.
        var orderIndex = 0
        for (n, s) in profile.spares.sorted(by: { $0.id < $1.id }).enumerated() {
            let key = s.channel << 8 | s.id
            if let existing = noteNames[key] {
                setupNotes.append("spare note \(s.id) is already \(existing); ignored")
                continue
            }
            var name = "SPARE \(n + 1)"
            if let given = s.name, mapping.buttons[given] != nil {
                name = given
            } else {
                var assigned = false
                while orderIndex < mapping.spareOrder.count {
                    let target = mapping.spareOrder[orderIndex]
                    orderIndex += 1
                    if controls.controls[target] != nil {
                        actions[name] = MappingEntry(["send": target])
                        setupNotes.append("spare note \(s.id) -> \(target)")
                        assigned = true
                        break
                    }
                }
                if !assigned { setupNotes.append("spare note \(s.id) has no mapping left (spares.order exhausted)") }
            }
            noteNames[key] = name
            ledOf[name] = s.led ?? s.id     // a spare's LED id equals its note id
        }
        let ids = controls.bankLeds.keys.sorted()
        bankLedIds = ids.count == 8 ? ids : Array(57...64)
    }

    // MARK: public entry points

    /// Call once at the start. Reports the initial status.
    public func start() -> [Effect] { finish([]) }

    /// Re-sends the status object (e.g. when the WebSocket (re)connects).
    public func statusEffects() -> [Effect] { lastStatus = ""; return finish([]) }

    /// The Touch's MIDI ports appeared: startup SysEx, then every known LED and pad colour.
    public func touchConnected() -> [Effect] {
        parsers = [.public: MidiStreamParser(), .private: MidiStreamParser()]
        connected = true
        sentLeds = [:]
        sentPads = [:]
        var out = [Effect]()
        if lightsEnabled { out.append(.touchStartup) }
        return finish(out)
    }

    /// Sends the LED state (and pad colours, when enabled) again from scratch, as after a connect but without the
    /// startup SysEx. The Touch can drop writes made while it is still starting; PaperCut re-sends too. Same messages
    /// as the baseline (`B0 id v` on the ports in `bankLedPorts` for bank LEDs, Public otherwise). `litOnly` leaves
    /// out the LEDs that are off, which keeps the periodic refresh short, and leaves the pad colours alone: a full
    /// refresh re-sends all 16 pads (16 x 20 ms = 320 ms of output), which the periodic 8 s one must not do. PaperCut
    /// never re-sends pad colours on a timer either; it sends the pads that changed.
    public func refreshLights(litOnly: Bool = false) -> [Effect] {
        guard lightsEnabled, connected else { return [] }
        sentLeds = [:]
        if litOnly { for (key, v) in desiredLeds() where v == 0 { sentLeds[key] = 0 } }
        else { sentPads = [:] }
        return finish([])
    }

    /// The Touch went away: release everything held on the Sample; no output to the Touch.
    public func touchDisconnected() -> [Effect] {
        let out = releaseAll()
        connected = false
        sentLeds = [:]
        sentPads = [:]
        return finish(out)
    }

    /// Bridge stop: releases (SHIFT last), every lit LED back to 0, all 16 pads black.
    public func stop() -> [Effect] {
        var out = releaseAll()
        if lightsEnabled && connected {
            for key in sentLeds.keys.sorted() where sentLeds[key] != 0 {
                out.append(.toTouch(key.port, [0xB0, UInt8(key.id), 0]))
                sentLeds[key] = 0
            }
            if profile.padColour.enabled {
                // All 16 pads off, whatever we think they show (PaperCut's PadLights.allOff does the same), so no
                // colour is left lit on the Touch after the bridge has gone.
                for i in 0..<profile.padColour.indexMap.count {
                    if let s = padColourSysEx(i, [0, 0, 0]) { out.append(.toTouch(.public, s)) }
                    sentPads[i] = [0, 0, 0]
                }
            }
        }
        connected = false
        lastStatus = ""
        var status = [Effect]()
        status.append(.ui(statusObject()))
        return out + status
    }

    public func handle(touch msg: TouchMessage) -> [Effect] {
        var out = [Effect]()
        var parser = parsers[msg.role] ?? MidiStreamParser()
        let messages = parser.feed(msg.bytes)
        parsers[msg.role] = parser
        for m in messages { dispatch(msg.role, m, &out) }
        return finish(out)
    }

    public func handle(sample ev: SampleEvent) -> [Effect] {
        var out = [Effect]()
        var bankTouched = false
        switch ev {
        case .led(let id, let v):
            sampleLeds[id] = v
            if bankLedIds.contains(id) { bankTouched = true }
        case .pad(let i, let rgb):
            if rgb.count >= 3 { samplePads[i] = rgb.prefix(3).map { max(0, min(127, $0)) } }
        case .hello(let leds, let pads, _):
            sampleLeds = leds
            samplePads = pads.filter { $0.value.count >= 3 }.mapValues { $0.prefix(3).map { max(0, min(127, $0)) } }
            bankTouched = true
        case .vm(let connected):
            out.append(.log("Sample panel UART \(connected ? "attached" : "detached")"))
        }
        if bankTouched { walkEvaluate(&out) }
        return finish(out)
    }

    public func handle(timer: CoreTimer) -> [Effect] {
        var out = [Effect]()
        switch timer {
        case .walkStart(let s):
            if let w = walk, w.seq == s, w.phase == .idle { walkStep(&out) }
        case .walkRelease(let s):
            // Always release PAD BANK, even if the walk was cancelled meanwhile.
            if let r = controls.release("PAD BANK") { out.append(.toSample(r)) }
            if var w = walk, w.seq == s, w.phase == .pressed {
                w.phase = .waiting
                let advance = w.advance
                walk = w
                if advance { walkStep(&out) }
            }
        case .walkTimeout(let s):
            if let w = walk, w.seq == s, w.phase == .waiting { walkStep(&out) }
        }
        return finish(out)
    }

    // MARK: message dispatch (Touch -> Sample)

    private func dispatch(_ role: PortRole, _ m: RawMessage, _ out: inout [Effect]) {
        let kind = m.kind
        let d1 = Int(m.d1), d2 = Int(m.d2)
        switch kind {
        case 0x80, 0x90:
            let on = kind == 0x90 && d2 > 0
            if m.channel == 9 {
                guard role == .public, let idx = padIndexByNote[d1] else {
                    if on { logUnknown(role, m, "not a pad note on this port", &out) }
                    return
                }
                if on { padOn(note: d1, idx: idx, velocity: d2, &out) } else { padOff(note: d1, &out) }
                return
            }
            guard let name = noteNames[m.channel << 8 | d1] else {
                if on { logUnknown(role, m, "unknown Touch control", &out) }
                return
            }
            var set = buttonDown[name] ?? []
            let was = !set.isEmpty
            if on { set.insert(role) } else { set.remove(role) }
            buttonDown[name] = set.isEmpty ? nil : set
            let isDown = !set.isEmpty
            if was != isDown { edge(name, down: isDown, role: role, m, &out) }
        case 0xA0:
            guard m.channel == 9, role == .public, padIndexByNote[d1] != nil else {
                logUnknown(role, m, "unknown Touch message", &out)
                return
            }
            let note = heldPads[d1].map(Int.init) ?? padSampleNote(forTouchNote: d1)
            out.append(.toSample([0xA9, UInt8(note), UInt8(d2)]))
        case 0xB0:
            guard let name = ccNames[m.channel << 8 | d1] else {
                logUnknown(role, m, "unknown Touch control", &out)
                return
            }
            if let q = qIndex(name) {
                knob(q, name, value: d2, role, m, &out)
            } else if let entry = actions[name] ?? mapping.wheel[name], let send = entry.send,
                      let f = controls.turn(send, value: d2) {
                out.append(.toSample(f))
            } else {
                logUnknown(role, m, "unmapped Touch control \(name)", &out)
            }
        default:
            logUnknown(role, m, "unknown Touch message", &out)
        }
    }

    private func logUnknown(_ role: PortRole, _ m: RawMessage, _ why: String, _ out: inout [Effect]) {
        let key = Int(m.status) << 8 | Int(m.d1)
        if loggedUnknown.insert(key).inserted {
            out.append(.log("dropped (\(why)): \(role.label) \(hexString(m.bytes)); logged once per status/data1"))
        }
    }

    private func padSampleNote(forTouchNote note: Int) -> Int {
        if mapping.padsPassThrough { return note }
        if let idx = padIndexByNote[note], let c = controls.controls["PAD \(idx + 1)"] { return c.id }
        return note
    }

    private func padOn(note: Int, idx: Int, velocity: Int, _ out: inout [Effect]) {
        let sent = padSampleNote(forTouchNote: note)
        let vel = fullLevel ? 127 : velocity
        heldPads[note] = UInt8(sent)
        out.append(.toSample([0x99, UInt8(sent), UInt8(vel)]))
    }

    private func padOff(note: Int, _ out: inout [Effect]) {
        // The release uses the note the press was sent with, whatever FULL LEVEL is doing now.
        guard let sent = heldPads.removeValue(forKey: note) else { return }
        out.append(.toSample([0x89, sent, 0]))
    }

    // MARK: knobs

    private func qIndex(_ name: String) -> Int? {
        guard name.count == 2, name.hasPrefix("Q"), let n = Int(name.dropFirst()), (1...4).contains(n) else { return nil }
        return n - 1
    }
    private func qTouchIndex(_ name: String) -> Int? {
        guard name.hasSuffix(" TOUCH") else { return nil }
        return qIndex(String(name.dropLast(6)))
    }

    /// The Sample control a Q-Link currently drives (Q4: FADER, or MAIN VOLUME while SHIFT is held).
    private func knobTarget(_ q: Int) -> String? {
        guard let e = mapping.knobs["Q\(q + 1)"] else { return nil }
        if (q == 3 ? qlinkAlternate != touchShift : touchShift), let s = e.shift?.send { return s }
        return e.send
    }

    private func knob(_ q: Int, _ name: String, value: Int, _ role: PortRole, _ m: RawMessage, _ out: inout [Effect]) {
        guard let target = knobTarget(q), let f = controls.set(target, value: value) else {
            logUnknown(role, m, "unmapped Touch control \(name)", &out)
            return
        }
        knobValue[q] = value
        out.append(.toSample(f))
        out.append(.ui(["t": "ui", "kind": "knob", "name": target, "q": name, "value": value, "touched": qTouched[q]]))
    }

    // MARK: buttons

    private func edge(_ name: String, down: Bool, role: PortRole, _ m: RawMessage, _ out: inout [Effect]) {
        if let q = qTouchIndex(name) {
            qTouched[q] = down
            let target = knobTarget(q) ?? "Q\(q + 1)"
            out.append(.ui(["t": "ui", "kind": "knob", "name": target, "q": "Q\(q + 1)", "value": knobValue[q], "touched": down]))
            return
        }
        guard let entry = actions[name] else {
            if down { logUnknown(role, m, "unmapped Touch control \(name)", &out) }
            return
        }
        if name == "SHIFT" { shiftEdge(down, entry, &out); return }
        down ? press(name, entry, &out) : release(name, &out)
    }

    private func shiftEdge(_ down: Bool, _ entry: MappingEntry, _ out: inout [Effect]) {
        guard let send = entry.send else { return }
        if down {
            touchShift = true
            // While a bank walk runs, SHIFT is held back from the Sample; the walk restores it when it ends.
            if walk == nil, !sampleShift, let f = controls.press(send) {
                out.append(.toSample(f))
                sampleShift = true
            }
        } else {
            touchShift = false
            if sampleShift, let f = controls.release(send) {
                out.append(.toSample(f))
            }
            sampleShift = false
        }
    }

    private func suppressSampleShift(_ out: inout [Effect]) {
        if sampleShift, let f = controls.release(shiftControl) { out.append(.toSample(f)) }
        sampleShift = false
    }
    private var shiftControl: String { actions["SHIFT"]?.send ?? "SHIFT" }

    private func restoreSampleShiftIfNeeded(_ out: inout [Effect]) {
        guard touchShift, !sampleShift, walk == nil, !held.contains(where: { $0.combo && $0.sends }),
              let f = controls.press(shiftControl) else { return }
        out.append(.toSample(f))
        sampleShift = true
    }

    private func press(_ name: String, _ entry: MappingEntry, _ out: inout [Effect]) {
        var chosen = entry
        var combo = false
        if touchShift, let s = entry.shift { chosen = s; combo = true }
        if combo { suppressSampleShift(&out) }

        if let target = chosen.send {
            guard let p = controls.press(target) else {
                out.append(.log("mapping \(name): no press frame for \"\(target)\""))
                return
            }
            out.append(.toSample(p))
            held.append(Held(name: name, release: controls.release(target).map { [$0] } ?? [], combo: combo, sends: true))
        } else if let macro = chosen.macro {
            var t = 0
            for c in macro {
                guard let p = controls.press(c), let r = controls.release(c) else { continue }
                out.append(t == 0 ? .toSample(p) : .after(t, .toSample(p)))
                out.append(.after(t + 30, .toSample(r)))
                t += 60
            }
            // Macros fire on press only; nothing to do on release.
        } else if chosen.bridge == "qlinkBank" {
            qlinkAlternate.toggle()
        } else if chosen.bridge == "fullLevel" {
            fullLevel.toggle()
        } else if chosen.bridge == "bank", let bank = chosen.bank {
            held.append(Held(name: name, release: [], combo: combo, sends: false))
            startWalk(target: bank, &out)
        } else {
            out.append(.log("mapping \(name): entry has no usable action"))
        }
    }

    private func release(_ name: String, _ out: inout [Effect]) {
        guard let i = held.firstIndex(where: { $0.name == name }) else { return }
        let h = held.remove(at: i)
        for r in h.release { out.append(.toSample(r)) }
        if h.combo && h.sends { restoreSampleShiftIfNeeded(&out) }
    }

    /// Everything the Sample might think is down gets a release; SHIFT last.
    private func releaseAll() -> [Effect] {
        var out = [Effect]()
        for note in heldPads.keys.sorted() { out.append(.toSample([0x89, heldPads[note]!, 0])) }
        for h in held { for r in h.release { out.append(.toSample(r)) } }
        if let w = walk, w.phase == .pressed, let r = controls.release("PAD BANK") { out.append(.toSample(r)) }
        if sampleShift, let f = controls.release(shiftControl) { out.append(.toSample(f)) }
        heldPads = [:]
        held = []
        buttonDown = [:]
        walk = nil
        touchShift = false
        sampleShift = false
        for q in 0..<4 where qTouched[q] {
            qTouched[q] = false
            out.append(.ui(["t": "ui", "kind": "knob", "name": knobTarget(q) ?? "Q\(q + 1)", "q": "Q\(q + 1)",
                            "value": knobValue[q], "touched": false]))
        }
        return out
    }

    // MARK: pad bank walk

    private func currentBank() -> Int? {
        for (i, id) in bankLedIds.enumerated() where (sampleLeds[id] ?? 0) > 0 { return i }
        return nil
    }

    private func startWalk(target: Int, _ out: inout [Effect]) {
        guard (0...7).contains(target) else { return }
        suppressSampleShift(&out)
        let oldPressed = walk?.phase == .pressed
        walkSeq += 1
        walk = Walk(target: target, seq: walkSeq)
        if oldPressed {
            // The previous walk's PAD BANK release is still pending; start after it.
            out.append(.after(35, .timer(.walkStart(walkSeq))))
        } else {
            walkStep(&out)
        }
    }

    private func walkStep(_ out: inout [Effect]) {
        guard var w = walk else { return }
        let cur = currentBank()
        // A fresh firmware boot may not emit bank LEDs until PAD BANK is pressed.
        // Probe once, then use real feedback to reach the requested bank. Never
        // assume A, since this bridge can attach to an already-running project.
        if cur == nil && w.presses > 0 {
            out.append(.log("bank walk: no bank feedback after initial PAD BANK press; stopping"))
            finishWalk(&out)
            return
        }
        if cur == nil {
            out.append(.log("bank walk: requesting initial bank feedback with one PAD BANK press"))
        }
        if cur == w.target { finishWalk(&out); return }
        if w.presses >= 8 {
            out.append(.log("bank walk: gave up after 8 PAD BANK presses (wanted bank \(w.target), Sample shows \(cur.map(String.init) ?? "unknown"))"))
            finishWalk(&out)
            return
        }
        guard let p = controls.press("PAD BANK") else {
            out.append(.log("bank walk: controls.json has no PAD BANK"))
            finishWalk(&out)
            return
        }
        w.presses += 1
        walkSeq += 1
        w.seq = walkSeq
        w.phase = .pressed
        w.bankAtPress = cur
        w.advance = false
        walk = w
        out.append(.toSample(p))
        out.append(.after(30, .timer(.walkRelease(w.seq))))
        out.append(.after(250, .timer(.walkTimeout(w.seq))))
    }

    private func finishWalk(_ out: inout [Effect]) {
        walk = nil
        restoreSampleShiftIfNeeded(&out)
    }

    /// A Sample bank LED changed: continue the walk when the bank really moved.
    private func walkEvaluate(_ out: inout [Effect]) {
        guard var w = walk, w.phase != .idle, let cur = currentBank(), cur != w.bankAtPress else { return }
        switch w.phase {
        case .pressed:
            w.advance = true       // the release is still due; step right after it
            walk = w
        case .waiting:
            walkStep(&out)
        case .idle:
            break
        }
    }

    // MARK: status

    private func statusObject() -> [String: Any] {
        ["t": "ui", "kind": "bridge", "touch": connected ? "connected" : "offline",
         "fullLevel": fullLevel, "q4": knobTarget(3) ?? "FADER"]
    }

    private func finish(_ effects: [Effect]) -> [Effect] {
        var out = effects
        out += syncLights()
        let s = statusObject()
        let key = "\(s["touch"]!)|\(s["fullLevel"]!)|\(s["q4"]!)"
        if key != lastStatus {
            lastStatus = key
            out.append(.ui(s))
        }
        return out
    }

    // MARK: lights (Sample -> Touch)

    private static func norm(_ v: Int?) -> Int { guard let v = v, v > 0 else { return 0 }; return v == 1 ? 1 : 2 }

    private func desiredLeds() -> [LedKey: Int] {
        var want = [LedKey: Int]()
        for (_, l) in ledOf { want[LedKey(port: .public, id: l)] = 0 }

        let modeNames = Set(mapping.modeLeds.keys)
        for (name, entry) in actions where !modeNames.contains(name) {
            guard let led = ledOf[name], let s = entry.send, let sl = controls.controls[s]?.led else { continue }
            let key = LedKey(port: .public, id: led)
            want[key] = max(want[key] ?? 0, BridgeCore.norm(sampleLeds[sl]))
        }
        for (name, m) in mapping.modeLeds {
            guard let led = ledOf[name] else { continue }
            let lit = controls.controls[m.lit]?.led.map { BridgeCore.norm(sampleLeds[$0]) } ?? 0
            let dim = controls.controls[m.dim]?.led.map { (sampleLeds[$0] ?? 0) > 0 ? 1 : 0 } ?? 0
            want[LedKey(port: .public, id: led)] = max(lit, dim)
        }
        for (name, e) in actions where e.bridge == "fullLevel" {
            if let led = ledOf[name] { want[LedKey(port: .public, id: led)] = fullLevel ? 2 : 0 }
        }
        func bankLit(_ k: Int) -> Bool { k < bankLedIds.count && (sampleLeds[bankLedIds[k]] ?? 0) > 0 }
        for (name, e) in actions where e.bridge == "bank" {
            guard let b = e.bank, b < 4, let led = ledOf[name] else { continue }
            let v = bankLit(b) ? mapping.litAtoD : (bankLit(b + 4) ? mapping.dimEtoH : 0)
            for p in profile.bankLedPorts { want[LedKey(port: p, id: led)] = v }
        }
        if let base = mapping.qlinkBankLeds.values.min(), base + 3 <= 127 {
            let q4 = knobTarget(3)
            for i in 0..<4 {
                let on = mapping.qlinkBankLeds.contains { $0.value == base + i && $0.key == q4 }
                for p in profile.bankLedPorts { want[LedKey(port: p, id: base + i)] = on ? 2 : 0 }
            }
        }
        return want
    }

    /// `F0 47 7F <product> 65 00 04 <pad 0-15> R G B F7` (Public only), the form PaperCut's PadLights sends
    /// (product 0x37; colours 0-127, clamped). `pad` is the Sample's pad index 0-15; `padColour.indexMap` turns it
    /// into the Touch's pad index (identity: see CONTROL_MAP.md). Anything outside 0-15, such as the Sample's "extra
    /// LED" index 16, produces nothing.
    private func padColourSysEx(_ pad: Int, _ rgb: [Int]) -> [UInt8]? {
        let map = profile.padColour.indexMap
        guard pad >= 0, pad < map.count, (0...15).contains(map[pad]), rgb.count >= 3 else { return nil }
        func b(_ v: Int) -> UInt8 { UInt8(max(0, min(127, v))) }
        return [0xF0, 0x47, 0x7F, b(profile.padColour.product), 0x65, 0x00, 0x04, UInt8(map[pad]), b(rgb[0]), b(rgb[1]), b(rgb[2]), 0xF7]
    }

    /// What the 16 Touch pads should show: the Sample's colour for pad i, or black when it has not reported one
    /// (PaperCut's first `show` sends all 16, off ones included, which also wipes any colour a previous owner left).
    private func desiredPads() -> [Int: [Int]] {
        var want = [Int: [Int]]()
        for i in 0..<profile.padColour.indexMap.count { want[i] = samplePads[i] ?? [0, 0, 0] }
        return want
    }

    private func syncLights() -> [Effect] {
        guard lightsEnabled, connected else { return [] }
        var out = [Effect]()
        let want = desiredLeds()
        for key in want.keys.sorted() where sentLeds[key] != want[key] {
            out.append(.toTouch(key.port, [0xB0, UInt8(key.id), UInt8(want[key]!)]))
            sentLeds[key] = want[key]
        }
        if profile.padColour.enabled {
            // Only the pads whose colour changed since the last send (all 16 after a connect or a full refresh).
            let pads = desiredPads()
            for i in pads.keys.sorted() where sentPads[i] != pads[i] {
                if let s = padColourSysEx(i, pads[i]!) {
                    out.append(.toTouch(.public, s))
                    sentPads[i] = pads[i]
                }
            }
        }
        return out
    }
}
