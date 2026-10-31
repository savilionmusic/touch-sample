import Foundation
import BridgeCore
import TouchIO
import TouchMIDI

// `touch-bridge --self-test`: feeds BridgeCore scripted Touch / Sample messages on a virtual clock and checks
// the effects. No MIDI is opened and no network is used. (The pacing check uses a fake sender.)

private func h(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private struct Failure { let name: String; let detail: String }
private var passed = [String]()
private var failed = [Failure]()
private var violations = [String]()   // hard-rule violations seen in ANY effect of ANY scenario

private func ck(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { passed.append(name); print("PASS  \(name)") }
    else { failed.append(Failure(name: name, detail: detail())); print("FAIL  \(name)  \(detail())") }
}

private func hexList(_ l: [[UInt8]]) -> String { l.map { hexString($0) }.joined(separator: " | ") }

/// Audits every effect of every scenario for the hard rules.
private func audit(_ e: Effect, _ where_: String) {
    switch e {
    case .toSample(let b):
        if b.first == 0xF0, b.count > 4, b[4] == 0x5A { violations.append("\(where_): SysEx 0x5A to Sample") }
    case .toTouch(let role, let b):
        if b.first == 0xF0 {
            if b.count > 4, b[4] == 0x5A { violations.append("\(where_): SysEx 0x5A to Touch \(hexString(b))") }
            if role == .private { violations.append("\(where_): SysEx to Private \(hexString(b))") }
        }
        let rc = TouchPorts.validate(role, b)       // the C layer's own verdict
        if rc != 0 { violations.append("\(where_): TouchMIDI would refuse \(role.label) \(hexString(b)): \(TouchPorts.errorString(rc))") }
    case .after(_, let inner): audit(inner, where_)
    case .batch(let l): l.forEach { audit($0, where_) }
    default: break
    }
}

/// Virtual-clock host for BridgeCore.
private final class Sim {
    let core: BridgeCore
    let label: String
    var now = 0
    private var seq = 0
    private enum Item { case effect(Effect), call(() -> Void) }
    private var pending: [(t: Int, n: Int, item: Item)] = []
    var sample: [(t: Int, bytes: [UInt8])] = []
    var touch: [(role: PortRole, bytes: [UInt8], t: Int)] = []
    var uis: [[String: Any]] = []
    var logs: [String] = []
    var startups = 0
    // simulated Sample pad bank (LEDs 57...64)
    var bankFeedback = false
    var bank = 0
    var bankPresses = 0
    var bankReleases = 0

    init(_ label: String, _ core: BridgeCore) { self.label = label; self.core = core }

    func run(_ effects: [Effect]) {
        for e in effects { audit(e, label); exec(e) }
    }

    private func exec(_ e: Effect) {
        switch e {
        case .toSample(let b):
            sample.append((now, b))
            if b == [0x90, 0x23, 0x7F] {
                bankPresses += 1
                if bankFeedback {
                    later(10) { [unowned self] in
                        let old = self.bank
                        self.bank = (self.bank + 1) % 8
                        self.led(57 + old, 0)
                        self.led(57 + self.bank, 1)
                    }
                }
            }
            if b == [0x80, 0x23, 0x00] { bankReleases += 1 }
        case .toTouch(let r, let b): touch.append((r, b, now))
        case .touchStartup: startups += 1
        case .ui(let d): uis.append(d)
        case .log(let s): logs.append(s)
        case .after(let ms, let inner): schedule(now + ms, .effect(inner))
        case .batch(let l): l.forEach { exec($0) }
        case .timer(let t): run(core.handle(timer: t))
        }
    }

    private func schedule(_ t: Int, _ item: Item) { seq += 1; pending.append((t, seq, item)) }
    func later(_ ms: Int, _ f: @escaping () -> Void) { schedule(now + ms, .call(f)) }

    func advance(_ ms: Int) {
        let target = now + ms
        while true {
            let due = pending.enumerated().filter { $0.element.t <= target }
                .min { ($0.element.t, $0.element.n) < ($1.element.t, $1.element.n) }
            guard let d = due else { break }
            let it = pending.remove(at: d.offset)
            now = max(now, it.t)
            switch it.item {
            case .effect(let e): exec(e)
            case .call(let f): f()
            }
        }
        now = target
    }

    // inputs
    func feed(_ role: PortRole, _ hex: String) { run(core.handle(touch: TouchMessage(role: role, bytes: h(hex)))) }
    func pub(_ hex: String) { feed(.public, hex) }
    func led(_ id: Int, _ v: Int) { run(core.handle(sample: .led(id: id, v: v))) }
    func sampleEvent(_ e: SampleEvent) { run(core.handle(sample: e)) }
    func connect() { run(core.touchConnected()) }

    // inspection
    func mark() -> (Int, Int) { (sample.count, touch.count) }
    func sampleSince(_ m: (Int, Int)) -> [[UInt8]] { sample[m.0...].map { $0.bytes } }
    func touchSince(_ m: (Int, Int)) -> [(PortRole, [UInt8])] { touch[m.1...].map { ($0.role, $0.bytes) } }
    func lastTouch(led id: UInt8) -> [UInt8]? {
        touch.last(where: { $0.1.count == 3 && $0.1[0] == 0xB0 && $0.1[1] == id })?.1
    }
    func lastUI(kind: String) -> [String: Any]? { uis.last { ($0["kind"] as? String) == kind } }
}

private var sharedPaths: RepoPaths?
private var sharedJSON: (profile: [String: Any], mapping: [String: Any], controls: [String: Any])?

private func loadJSON(_ options: BridgeOptions) throws {
    let paths = try RepoPaths.resolve(root: options.rootPath, profile: options.profilePath,
                                      mapping: options.mappingPath, controls: options.controlsPath)
    sharedPaths = paths
    func dict(_ p: String) throws -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: p),
              let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ConfigError.message("cannot read \(p)") }
        return j
    }
    sharedJSON = (try dict(paths.profile), try dict(paths.mapping), try dict(paths.controls))
}

/// The repo's profile with the Phase-1 gaps filled in (MAIN, MENU, MINUS, PLUS, UNDO, COPY, one spare), so
/// every rule can be exercised. Note ids 21...26 are unused by the shipped profile.
private func testConfig(padColour: Bool = true, passThroughPads: Bool = true) throws -> BridgeConfig {
    var prof = sharedJSON!.profile
    var ctl = prof["controls"] as! [String: Any]
    for (name, id) in [("MAIN", 21), ("MENU", 22), ("MINUS", 23), ("PLUS", 24), ("UNDO", 25), ("COPY", 26)] {
        var c = ctl[name] as! [String: Any]
        c["id"] = id
        c["led"] = id
        ctl[name] = c
    }
    prof["controls"] = ctl
    var pc = prof["padColour"] as! [String: Any]
    pc["enabled"] = padColour
    prof["padColour"] = pc
    var map = sharedJSON!.mapping
    var pads = (map["pads"] as? [String: Any]) ?? [:]
    pads["passThrough"] = passThroughPads
    map["pads"] = pads
    return try BridgeConfig(profileJSON: prof, mappingJSON: map, controlsJSON: sharedJSON!.controls)
}

/// A connected bridge whose Sample shows bank A.
private func fresh(_ label: String, padColour: Bool = true, bankFeedback: Bool = false) throws -> Sim {
    let sim = Sim(label, BridgeCore(config: try testConfig(padColour: padColour)))
    sim.run(sim.core.start())
    sim.sampleEvent(.hello(leds: [57: 1], pads: [:], vm: true))
    sim.connect()
    sim.bankFeedback = bankFeedback
    return sim
}

// MARK: - the checks

private func checkConfig() throws {
    let shipped = try BridgeConfig(profileJSON: sharedJSON!.profile, mappingJSON: sharedJSON!.mapping,
                                   controlsJSON: sharedJSON!.controls)
    ck("config: shipped profile, mapping and controls.json load", true)
    ck("config: every mapping entry names a real Sample control", shipped.warnings.isEmpty, shipped.warnings.joined(separator: "; "))
    let pads = shipped.profile.controls.filter { $0.kind == .pad }
    ck("config: 16 pads on Ch.10", pads.count == 16 && pads.allSatisfy { $0.channel == 9 })
    let core = BridgeCore(config: try testConfig())
    ck("config: spares get mappings.spares.order in ascending id order (52 CHOP, 54 MUTE, 55 LOOP, 67 SAMPLE, 122 SAMPLE SELECT)", ["note 52 -> CHOP", "note 54 -> MUTE", "note 55 -> LOOP", "note 67 -> SAMPLE", "note 122 -> SAMPLE SELECT"].allSatisfy { n in core.setupNotes.contains { $0.contains(n) } }, core.setupNotes.joined(separator: "; "))
}

private func checkPads() throws {
    let s = try fresh("pads")
    var m = s.mark()
    s.pub("99 25 64")
    ck("pad press passes note and velocity", s.sampleSince(m) == [h("99 25 64")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("89 25 00")
    ck("pad release", s.sampleSince(m) == [h("89 25 00")], hexList(s.sampleSince(m)))

    // FULL LEVEL: toggle on, velocity forced to 127, toggle off while the pad is still held
    m = s.mark()
    s.pub("90 27 7F")
    s.pub("80 27 00")
    ck("FULL LEVEL press sends nothing to the Sample", s.sampleSince(m).isEmpty, hexList(s.sampleSince(m)))
    ck("FULL LEVEL lights its LED (Public B0 27 02)", s.touchSince(m).contains { $0.0 == .public && $0.1 == h("B0 27 02") })
    ck("FULL LEVEL status event says fullLevel=true", (s.lastUI(kind: "bridge")?["fullLevel"] as? Bool) == true)
    m = s.mark()
    s.pub("99 25 28")
    ck("pad with FULL LEVEL on goes out at velocity 127", s.sampleSince(m) == [h("99 25 7F")], hexList(s.sampleSince(m)))
    s.pub("90 27 7F")     // toggle off while the pad is down
    s.pub("80 27 00")
    m = s.mark()
    s.pub("89 25 00")
    ck("release after FULL LEVEL was toggled off still releases the pressed note", s.sampleSince(m) == [h("89 25 00")], hexList(s.sampleSince(m)))
    ck("FULL LEVEL off turns its LED off (B0 27 00)", s.touch.contains { $0.bytes == h("B0 27 00") })
    // pad off-note stays quiet; note-on velocity 0 releases
    s.pub("99 26 50")
    m = s.mark()
    s.pub("99 26 00")
    ck("note-on velocity 0 releases the pad", s.sampleSince(m) == [h("89 26 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("89 28 00")
    ck("stray pad release (nothing pressed) is not forwarded", s.sampleSince(m).isEmpty)
    // pressure
    m = s.mark()
    s.pub("99 25 50")
    s.pub("A9 25 32")
    ck("pad pressure A9 passes through", s.sampleSince(m) == [h("99 25 50"), h("A9 25 32")], hexList(s.sampleSince(m)))
    s.pub("89 25 00")
    // running status + SysEx skipping in the parser
    m = s.mark()
    s.run(s.core.handle(touch: TouchMessage(role: .public, bytes: h("99 25 64 25 00"))))
    ck("running status: second message (note-on vel 0) is a release", s.sampleSince(m) == [h("99 25 64"), h("89 25 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.run(s.core.handle(touch: TouchMessage(role: .public, bytes: h("F0 47 7F F7 99 26 70 F8 26 00"))))
    ck("SysEx is skipped and realtime bytes ignored", s.sampleSince(m) == [h("99 26 70"), h("89 26 00")], hexList(s.sampleSince(m)))
    // pads on Private are not pads
    m = s.mark()
    s.feed(.private, "99 25 64")
    ck("a pad note on the Private port is dropped", s.sampleSince(m).isEmpty)
}

private func checkKnobs() throws {
    let s = try fresh("knobs")
    var m = s.mark()
    s.pub("B0 10 05"); s.pub("B0 11 06"); s.pub("B0 12 07")
    ck("Q1-Q3 pass through as K1-K3 (CC 16-18)", s.sampleSince(m) == [h("B0 10 05"), h("B0 11 06"), h("B0 12 07")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("B0 13 40")
    ck("Q4 drives FADER (CC 20)", s.sampleSince(m) == [h("B0 14 40")], hexList(s.sampleSince(m)))
    ck("Q-Link bank LED 90 lit while Q4 is FADER", s.touch.contains { $0.0 == .public && $0.1 == h("B0 5A 02") })
    m = s.mark()
    s.pub("90 31 7F")
    ck("SHIFT passes through to the Sample", s.sampleSince(m) == [h("90 31 7F")], hexList(s.sampleSince(m)))
    ck("holding SHIFT moves the Q-Link bank LED to 91 (Public and Private)",
       s.touchSince(m).contains { $0.0 == .public && $0.1 == h("B0 5B 02") } && s.touchSince(m).contains { $0.0 == .private && $0.1 == h("B0 5B 02") }
        && s.touchSince(m).contains { $0.0 == .public && $0.1 == h("B0 5A 00") })
    ck("status event reports Q4 = MAIN VOLUME", (s.lastUI(kind: "bridge")?["q4"] as? String) == "MAIN VOLUME")
    m = s.mark()
    s.pub("B0 13 22")
    ck("Shift + Q4 drives MAIN VOLUME (CC 19)", s.sampleSince(m) == [h("B0 13 22")], hexList(s.sampleSince(m)))
    s.pub("80 31 00")
    m = s.mark()
    s.pub("B0 13 23")
    ck("after SHIFT release Q4 is FADER again", s.sampleSince(m) == [h("B0 14 23")], hexList(s.sampleSince(m)))
    ck("status event reports Q4 = FADER again", (s.lastUI(kind: "bridge")?["q4"] as? String) == "FADER")

    // Q-Link touch -> ui, never to the Sample
    m = s.mark()
    let u0 = s.uis.count
    s.pub("90 55 7F")       // Q2 TOUCH
    s.pub("B0 11 40")
    s.pub("80 55 00")
    ck("Q-Link touch notes never reach the Sample (only the CC does)", s.sampleSince(m) == [h("B0 11 40")], hexList(s.sampleSince(m)))
    let knobUI = s.uis[u0...].filter { ($0["kind"] as? String) == "knob" }
    ck("Q-Link touch/turn emit ui knob events: touched, value, release",
       knobUI.count == 3 && (knobUI[0]["touched"] as? Bool) == true && (knobUI[0]["name"] as? String) == "K2"
        && (knobUI[1]["value"] as? Int) == 0x40 && (knobUI[1]["touched"] as? Bool) == true && (knobUI[2]["touched"] as? Bool) == false,
       "\(knobUI)")
    // Q4 touch names its current target
    s.pub("90 56 7F")       // Q3
    s.pub("90 57 7F")       // Q4
    ck("Q4 touch event names the control it drives (FADER)", (s.lastUI(kind: "knob")?["name"] as? String) == "FADER")
}

private func checkWheelAndButtons() throws {
    let s = try fresh("buttons")
    var m = s.mark()
    s.pub("B0 64 01"); s.pub("B0 64 7F")
    ck("data wheel CC 100 passes through (01 right, 7F left)", s.sampleSince(m) == [h("B0 64 01"), h("B0 64 7F")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("90 6F 7F"); s.pub("80 6F 00")
    ck("data wheel push (note 111) passes through", s.sampleSince(m) == [h("90 6F 7F"), h("80 6F 00")], hexList(s.sampleSince(m)))

    // PLAY dedupe: Public + Private
    m = s.mark()
    s.pub("90 52 7F")
    s.feed(.private, "90 52 7F")
    ck("PLAY on Public and Private is one press", s.sampleSince(m) == [h("90 52 7F")], hexList(s.sampleSince(m)))
    s.pub("80 52 00")
    ck("PLAY release on one port while the other is still down sends nothing", s.sampleSince(m).count == 1)
    s.feed(.private, "80 52 00")
    ck("PLAY release after both ports are up is one release", s.sampleSince(m) == [h("90 52 7F"), h("80 52 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.feed(.private, "90 51 7F"); s.feed(.private, "80 51 00")
    ck("STOP (Private) -> STOP", s.sampleSince(m) == [h("90 51 7F"), h("80 51 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.feed(.private, "90 49 7F"); s.feed(.private, "80 49 00")
    ck("REC -> SAMPLE RECORD (note 73)", s.sampleSince(m) == [h("90 49 7F"), h("80 49 00")], hexList(s.sampleSince(m)))

    // PLAY START macro: STOP then PLAY, 30 ms apart
    m = s.mark()
    let t0 = s.now
    s.feed(.private, "90 53 7F")
    s.advance(120)
    s.feed(.private, "80 53 00")
    s.advance(50)
    let macro = s.sample[m.0...].map { ($0.t - t0, $0.bytes) }
    ck("PLAY START macro = STOP press/release then PLAY press/release, 30 ms apart, on press only",
       macro.count == 4 && macro[0] == (0, h("90 51 7F")) && macro[1] == (30, h("80 51 00"))
        && macro[2] == (60, h("90 52 7F")) && macro[3] == (90, h("80 52 00")),
       "\(macro.map { "\($0.0)ms \(hexString($0.1))" })")

    // MAIN / MENU
    m = s.mark()
    s.pub("90 15 7F"); s.pub("80 15 00")
    ck("MAIN -> SAMPLE (note 6)", s.sampleSince(m) == [h("90 06 7F"), h("80 06 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("90 16 7F"); s.pub("80 16 00")
    ck("MENU -> SAMPLE SELECT (note 36 as the Sample's own button)", s.sampleSince(m) == [h("90 24 7F"), h("80 24 00")], hexList(s.sampleSince(m)))

    // Shift combo: MAIN
    m = s.mark()
    s.pub("90 31 7F")
    s.pub("90 15 7F")
    ck("SHIFT + MAIN: SHIFT is released to the Sample, then SEQ is pressed",
       s.sampleSince(m) == [h("90 31 7F"), h("80 31 00"), h("90 07 7F")], hexList(s.sampleSince(m)))
    var m2 = s.mark()
    s.pub("80 15 00")
    ck("releasing MAIN releases SEQ and re-presses SHIFT because it is still held",
       s.sampleSince(m2) == [h("80 07 00"), h("90 31 7F")], hexList(s.sampleSince(m2)))
    m2 = s.mark()
    s.pub("80 31 00")
    ck("then releasing SHIFT releases it on the Sample", s.sampleSince(m2) == [h("80 31 00")], hexList(s.sampleSince(m2)))

    // SHIFT released before MAIN
    m = s.mark()
    s.pub("90 31 7F"); s.pub("90 15 7F"); s.pub("80 31 00")
    ck("SHIFT released first during a combo: nothing extra for SHIFT",
       s.sampleSince(m) == [h("90 31 7F"), h("80 31 00"), h("90 07 7F")], hexList(s.sampleSince(m)))
    m2 = s.mark()
    s.pub("80 15 00")
    ck("...and releasing MAIN then only releases SEQ", s.sampleSince(m2) == [h("80 07 00")], hexList(s.sampleSince(m2)))

    // Shift + MENU -> PAD FX; a non-bridge shift combo (TAP TEMPO) passes straight through
    m = s.mark()
    s.pub("90 31 7F"); s.pub("90 16 7F"); s.pub("80 16 00"); s.pub("80 31 00")
    ck("SHIFT + MENU -> PAD FX with the same SHIFT handling",
       s.sampleSince(m) == [h("90 31 7F"), h("80 31 00"), h("90 01 7F"), h("80 01 00"), h("90 31 7F"), h("80 31 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("90 31 7F"); s.pub("90 35 7F"); s.pub("80 35 00"); s.pub("80 31 00")
    ck("other Shift combinations (SHIFT + TAP TEMPO) pass straight through",
       s.sampleSince(m) == [h("90 31 7F"), h("90 35 7F"), h("80 35 00"), h("80 31 00")], hexList(s.sampleSince(m)))

    // spare + UNDO/COPY/MINUS/PLUS
    m = s.mark()
    s.pub("90 34 7F"); s.pub("80 34 00"); s.pub("90 43 7F"); s.pub("80 43 00"); s.pub("90 7A 7F"); s.pub("80 7A 00")
    ck("spare buttons: 0x34 -> CHOP (75), 0x43 -> SAMPLE (6), 0x7A -> SAMPLE SELECT (36)",
       s.sampleSince(m) == [h("90 4B 7F"), h("80 4B 00"), h("90 06 7F"), h("80 06 00"), h("90 24 7F"), h("80 24 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.led(75, 2)
    ck("spare LED id = its note id (Sample CHOP LED -> Touch B0 34 02)", s.touch.last?.1 == h("B0 34 02"), "\(s.touchSince(m).map { hexString($0.1) })")
    m = s.mark()
    s.pub("90 19 7F"); s.pub("80 19 00"); s.pub("90 17 7F"); s.pub("80 17 00")
    ck("UNDO -> CHOP (75), MINUS -> MINUS (55)", s.sampleSince(m) == [h("90 4B 7F"), h("80 4B 00"), h("90 37 7F"), h("80 37 00")], hexList(s.sampleSince(m)))
    m = s.mark()
    s.pub("90 00 7F"); s.pub("80 00 00")
    ck("Q-LINK button (note 0) -> KNOB FX (note 0)", s.sampleSince(m) == [h("90 00 7F"), h("80 00 00")], hexList(s.sampleSince(m)))
}

private func checkBanks() throws {
    // A -> C with simulated LED feedback
    let s = try fresh("bank A->C", bankFeedback: true)
    var m = s.mark()
    s.pub("90 25 7F")       // BANK C
    s.advance(300)
    s.pub("80 25 00")
    let presses = s.sampleSince(m).filter { $0 == h("90 23 7F") }.count
    ck("bank walk A->C presses PAD BANK exactly twice", presses == 2 && s.bank == 2, "presses=\(presses) bank=\(s.bank)")
    ck("every PAD BANK press was released", s.bankPresses == s.bankReleases, "\(s.bankPresses) vs \(s.bankReleases)")
    ck("bank walk touched no Sample note-36 button", !s.sample.contains { ($0.bytes[0] == 0x90 || $0.bytes[0] == 0x80) && $0.bytes[1] == 0x24 })
    let cPub = s.touch.contains { $0.0 == .public && $0.1 == h("B0 25 03") }
    let cPriv = s.touch.contains { $0.0 == .private && $0.1 == h("B0 25 03") }
    ck("bank LEDs follow: C lit (3) on Public and Private, A off", cPub && cPriv && s.lastTouch(led: 0x23) == h("B0 23 00"))
    m = s.mark()
    s.pub("90 25 7F"); s.advance(300); s.pub("80 25 00")
    ck("pressing the current bank again presses nothing", s.sampleSince(m).isEmpty, hexList(s.sampleSince(m)))

    // Shift + bank -> E-H: C -> F, then F -> E (7 presses), SHIFT handled around the walk
    m = s.mark()
    s.pub("90 31 7F")
    s.pub("90 24 7F")       // BANK B + SHIFT -> bank F
    s.advance(500)
    s.pub("80 24 00")
    var seq = s.sampleSince(m)
    let firstBank = seq.firstIndex(of: h("90 23 7F"))
    let lastBank = seq.lastIndex(of: h("80 23 00"))
    ck("SHIFT + BANK B walks C->F with 3 presses", s.bank == 5 && seq.filter { $0 == h("90 23 7F") }.count == 3, "bank=\(s.bank) \(hexList(seq))")
    ck("SHIFT is released to the Sample before the first PAD BANK press and re-pressed after the last",
       seq.first == h("90 31 7F") && seq[1] == h("80 31 00") && firstBank == 2 && lastBank != nil && seq.last == h("90 31 7F") && lastBank! < seq.count - 1,
       hexList(seq))
    ck("E-H on the Touch: bank F shows as dim (1) on the B LED", s.lastTouch(led: 0x24) == h("B0 24 01"))
    m = s.mark()
    s.pub("90 23 7F")       // BANK A + SHIFT -> bank E (shift still held)
    s.advance(800)
    s.pub("80 23 00")
    seq = s.sampleSince(m)
    ck("SHIFT + BANK A walks F->E (7 presses, within the 8 limit)", s.bank == 4 && seq.filter { $0 == h("90 23 7F") }.count == 7, "bank=\(s.bank) presses=\(seq.filter { $0 == h("90 23 7F") }.count)")
    s.pub("80 31 00")
    ck("SHIFT release afterwards releases SHIFT once", s.sample.last?.bytes == h("80 31 00"))

    // no feedback -> max 8 presses
    let g = try fresh("bank no feedback", bankFeedback: false)
    g.pub("90 25 7F")
    g.advance(3000)
    g.pub("80 25 00")
    ck("bank walk with a silent Sample gives up after 8 presses and logs it",
       g.bankPresses == 8 && g.bankReleases == 8 && g.logs.contains { $0.contains("gave up after 8") }, "presses=\(g.bankPresses) logs=\(g.logs)")

    // a new target cancels the running walk
    let c = try fresh("bank cancel", bankFeedback: true)
    c.pub("90 26 7F")       // BANK D (3 presses)
    c.advance(15)
    c.pub("90 24 7F")       // BANK B while D still held
    c.advance(800)
    c.pub("80 26 00"); c.pub("80 24 00")
    c.advance(100)
    ck("a new bank target cancels the running walk and ends on the new bank", c.bank == 1 && c.bankPresses == c.bankReleases, "bank=\(c.bank) p=\(c.bankPresses) r=\(c.bankReleases)")
}

private func checkUnknown() throws {
    let s = try fresh("unknown")
    var m = s.mark()
    let l0 = s.logs.count
    s.pub("90 7C 7F")
    s.pub("80 7C 00")
    s.pub("90 7C 7F")
    ck("unknown Touch message is dropped, not passed through", s.sampleSince(m).isEmpty)
    ck("unknown Touch message is logged exactly once", s.logs.count - l0 == 1 && s.logs.last!.contains("90 7C 7F"), "\(s.logs)")
    s.pub("90 7D 7F")
    ck("a different unknown message is logged separately", s.logs.count - l0 == 2)
    m = s.mark()
    s.pub("E0 00 40")
    s.pub("C0 05")
    ck("pitch bend / program change are dropped", s.sampleSince(m).isEmpty)
    // Touch note 36 is BANK B, never the Sample's SAMPLE SELECT
    m = s.mark()
    s.pub("90 24 7F"); s.pub("80 24 00")
    ck("Touch note 36 never reaches the Sample as a button", !s.sampleSince(m).contains { $0.count == 3 && ($0[0] == 0x90 || $0[0] == 0x80) && $0[1] == 0x24 })
}

private func checkLights() throws {
    let s = try fresh("lights")
    var m = s.mark()
    s.led(82, 2)
    ck("Sample PLAY LED -> Touch PLAY LED (Public B0 52 02)", s.touchSince(m).map { $0.1 } == [h("B0 52 02")] && s.touchSince(m).first?.0 == .public, "\(s.touchSince(m).map { hexString($0.1) })")
    m = s.mark()
    s.led(82, 2)
    ck("an unchanged LED is not sent again", s.touchSince(m).isEmpty)
    s.led(82, 3)
    ck("values >= 2 map to 2 (no change from 2)", s.touchSince(m).isEmpty)
    s.led(81, 1)
    ck("value 1 stays 1 (STOP dim)", s.touch.last?.1 == h("B0 51 01"))
    s.led(82, 0)
    ck("LED off", s.touch.last?.1 == h("B0 52 00"))
    s.led(49, 2)
    ck("SHIFT LED mirrors (same id 49)", s.touch.last?.1 == h("B0 31 02"))
    // modes
    m = s.mark()
    s.led(7, 1)
    ck("SEQ lit -> MAIN dim (1)", s.lastTouch(led: 0x15) == h("B0 15 01"), "\(s.touchSince(m).map { hexString($0.1) })")
    s.led(6, 2)
    ck("SAMPLE lit -> MAIN lit (2)", s.lastTouch(led: 0x15) == h("B0 15 02"))
    s.led(1, 1)
    ck("PAD FX -> MENU dim (1)", s.lastTouch(led: 0x16) == h("B0 16 01"))
    s.led(36, 2)
    ck("SAMPLE SELECT -> MENU lit (2)", s.lastTouch(led: 0x16) == h("B0 16 02"))
    // bank LEDs (A-D = 3, E-H = same LED at 1), Public + Private
    m = s.mark()
    s.led(57, 0); s.led(61, 1)
    let bankMsgs = s.touchSince(m).filter { $0.1.count == 3 && $0.1[1] == 0x23 }
    ck("bank E lights the A LED at 1 (dim) on both ports", bankMsgs.contains { $0.0 == .public && $0.1 == h("B0 23 01") } && bankMsgs.contains { $0.0 == .private && $0.1 == h("B0 23 01") }, "\(bankMsgs.map { hexString($0.1) })")
    s.led(61, 0); s.led(60, 1)
    ck("bank D lights LED 38 at 3", s.touch.contains { $0.0 == .public && $0.1 == h("B0 26 03") })
    // pad colour
    m = s.mark()
    s.sampleEvent(.pad(i: 0, rgb: [127, 0, 64]))
    ck("pad colour -> Touch SysEx with product byte 0x37 (Public)",
       s.touchSince(m).count == 1 && s.touchSince(m)[0].0 == .public && s.touchSince(m)[0].1 == h("F0 47 7F 37 65 00 04 00 7F 00 40 F7"),
       "\(s.touchSince(m).map { hexString($0.1) })")
    m = s.mark()
    s.sampleEvent(.pad(i: 0, rgb: [127, 0, 64]))
    ck("unchanged pad colour is not sent again", s.touchSince(m).isEmpty)
    let off = try fresh("lights padColour disabled", padColour: false)
    let om = off.mark()
    off.sampleEvent(.pad(i: 3, rgb: [1, 2, 3]))
    ck("pad colours are not sent while padColour.enabled is false", off.touchSince(om).isEmpty)

    // startup + full refresh on (re)connect
    let r = Sim("refresh", BridgeCore(config: try testConfig()))
    r.run(r.core.start())
    r.sampleEvent(.hello(leds: [57: 1, 82: 2, 6: 2], pads: [0: [10, 20, 30], 5: [1, 2, 3]], vm: true))
    ck("nothing is sent to the Touch before it is connected", r.touch.isEmpty && r.startups == 0)
    let eff = r.core.touchConnected()
    r.run(eff)
    var firstIsStartup = false
    if case .touchStartup = eff.first! { firstIsStartup = true }
    ck("(re)connect: startup first", firstIsStartup && r.startups == 1)
    ck("refresh: current LEDs (PLAY lit, MAIN lit, bank A=3 on both ports, Q-Link bank 90 lit)",
       r.touch.contains { $0.0 == .public && $0.1 == h("B0 52 02") } && r.touch.contains { $0.0 == .public && $0.1 == h("B0 15 02") }
        && r.touch.contains { $0.0 == .public && $0.1 == h("B0 23 03") } && r.touch.contains { $0.0 == .private && $0.1 == h("B0 23 03") }
        && r.touch.contains { $0.0 == .private && $0.1 == h("B0 5A 02") })
    ck("refresh: known-off LEDs are written as 0 too (FULL LEVEL B0 27 00)", r.touch.contains { $0.1 == h("B0 27 00") })
    ck("refresh: pad colours follow the LEDs",
       r.touch.contains { $0.1 == h("F0 47 7F 37 65 00 04 00 0A 14 1E F7") } && r.touch.contains { $0.1 == h("F0 47 7F 37 65 00 04 05 01 02 03 F7") })
    let lastLed = r.touch.lastIndex { $0.1.first == 0xB0 }!
    let firstPad = r.touch.firstIndex { $0.1.first == 0xF0 }!
    ck("refresh order: LEDs before pad colours", lastLed < firstPad)
    let started = TouchPorts.startupMessages()
    ck("TouchMIDI startup is exactly the three Public SysEx from CONTROL_MAP.md",
       started == [h("F0 47 7F 37 62 00 01 65 F7"), h("F0 47 00 37 64 00 01 01 F7"), h("F0 47 00 37 64 00 03 00 01 01 F7")],
       started.map { hexString($0) }.joined(separator: " | "))
    // everything the Private port got is an allowed bank-indicator CC
    ck("Private only ever got B0 23..26 / B0 5A..5D",
       r.touch.filter { $0.0 == .private }.allSatisfy { $0.1.count == 3 && $0.1[0] == 0xB0 && ((0x23...0x26).contains($0.1[1]) || (0x5A...0x5D).contains($0.1[1])) })
    // reconnect refreshes again
    r.run(r.core.touchDisconnected())
    let before = r.touch.count
    r.run(r.core.touchConnected())
    ck("reconnect after unplug re-sends startup and the full LED set", r.startups == 2 && r.touch.count - before >= 20, "\(r.touch.count - before)")
    // --no-lights
    let nl = Sim("no-lights", BridgeCore(config: try testConfig(), lights: false))
    nl.run(nl.core.start()); nl.connect(); nl.led(82, 2)
    ck("--no-lights: no startup, no LED output at all", nl.touch.isEmpty && nl.startups == 0)
}

private func checkDisconnectAndStop() throws {
    let s = try fresh("disconnect")
    s.pub("99 25 64")
    s.pub("99 26 20")
    s.pub("90 52 7F")
    s.pub("90 31 7F")
    let m = s.mark()
    let tm = s.touch.count
    s.run(s.core.touchDisconnected())
    ck("Touch disconnect: releases for every held pad and button, SHIFT last",
       s.sampleSince(m) == [h("89 25 00"), h("89 26 00"), h("80 52 00"), h("80 31 00")], hexList(s.sampleSince(m)))
    ck("Touch disconnect sends nothing to the Touch", s.touch.count == tm)
    ck("status reports the Touch offline", (s.lastUI(kind: "bridge")?["touch"] as? String) == "offline")
    // after disconnect, a late release must not produce anything
    let m2 = s.mark()
    s.pub("89 25 00")
    ck("late release after disconnect sends nothing", s.sampleSince(m2).isEmpty)

    // stop: releases, lit LEDs off, pads black
    let t = try fresh("stop")
    t.led(82, 2); t.led(6, 2); t.led(49, 2)
    t.sampleEvent(.pad(i: 1, rgb: [5, 6, 7]))
    t.pub("99 25 64"); t.pub("90 31 7F")
    let sm = t.mark()
    let eff = t.core.stop()
    t.run(eff)
    ck("stop: releases held pad and SHIFT (SHIFT last)", t.sampleSince(sm) == [h("89 25 00"), h("80 31 00")], hexList(t.sampleSince(sm)))
    let tt = t.touchSince(sm)
    ck("stop: lit LEDs go back to 0 (PLAY, MAIN, SHIFT, bank A, the lit Q-Link bank LED 91 while SHIFT was held)",
       tt.contains { $0.1 == h("B0 52 00") } && tt.contains { $0.1 == h("B0 15 00") } && tt.contains { $0.1 == h("B0 31 00") }
        && tt.contains { $0.0 == .private && $0.1 == h("B0 23 00") } && tt.contains { $0.0 == .private && $0.1 == h("B0 5B 00") })
    ck("stop: pad colours back to black", tt.contains { $0.1 == h("F0 47 7F 37 65 00 04 01 00 00 00 F7") })
    ck("stop: only lit LEDs are touched (FULL LEVEL stays untouched)", !tt.contains { $0.1 == h("B0 27 00") })
}

private func checkHardRuleLayer() throws {
    let sysex5A = h("F0 47 00 37 5A 00 01 F7")
    ck("TouchMIDI refuses SysEx with byte 4 = 0x5A (Public)", TouchPorts.validate(.public, sysex5A) == Int32(TOUCH_ERR_SYSEX_5A))
    ck("TouchMIDI refuses SysEx 0x5A (Private) with the 0x5A reason", TouchPorts.validate(.private, sysex5A) == Int32(TOUCH_ERR_SYSEX_5A))
    ck("TouchMIDI refuses any SysEx to Private", TouchPorts.validate(.private, h("F0 47 7F 37 65 00 04 00 01 02 03 F7")) == Int32(TOUCH_ERR_PRIVATE_SYSEX))
    ck("TouchMIDI accepts the pad-colour SysEx on Public", TouchPorts.validate(.public, h("F0 47 7F 37 65 00 04 00 01 02 03 F7")) == 0)
    ck("Private allows B0 23..26 and B0 5A..5D",
       [0x23, 0x26, 0x5A, 0x5D].allSatisfy { TouchPorts.validate(.private, [0xB0, UInt8($0), 3]) == 0 })
    ck("Private refuses other CCs, notes and PLAY LED", TouchPorts.validate(.private, h("B0 52 02")) != 0 && TouchPorts.validate(.private, h("90 23 7F")) != 0 && TouchPorts.validate(.private, h("B0 27 02")) != 0)
    ck("the three startup SysEx pass validation on Public", TouchPorts.startupMessages().allSatisfy { TouchPorts.validate(.public, $0) == 0 })
    ck("touch_send refuses 0x5A before anything else, even with no port open",
       TouchPorts.init().send(.public, sysex5A) == Int32(TOUCH_ERR_SYSEX_5A))
    ck("touch_send with no port open sends nothing (not-open error)", TouchPorts.init().send(.public, h("B0 52 02")) == Int32(TOUCH_ERR_NOT_OPEN))
}

private func checkPacing() {
    final class Rec { var items: [(role: PortRole, bytes: [UInt8], ns: UInt64)] = []; let l = NSLock()
        func add(_ r: PortRole, _ b: [UInt8]) { l.lock(); items.append((r, b, DispatchTime.now().uptimeNanoseconds)); l.unlock() } }
    let rec = Rec()
    let out = PacedOutput(send: { rec.add($0, $1); return 0 }, startup: { 0 })
    for id in 0..<12 { out.enqueue(.public, [0xB0, UInt8(id), 2]) }
    out.enqueue(.public, h("F0 47 7F 37 65 00 04 00 01 02 03 F7"))
    out.enqueue(.public, h("F0 47 7F 37 65 00 04 01 01 02 03 F7"))
    for id in 0x23...0x26 { out.enqueue(.private, [0xB0, UInt8(id), 3]) }
    ck("paced output drains", out.flush(timeout: 3))
    func gaps(_ role: PortRole) -> [Double] {
        let ns = rec.items.filter { $0.role == role }.map { $0.ns }
        return zip(ns.dropFirst(), ns).map { Double($0 - $1) / 1e6 }
    }
    let pg = gaps(.public), vg = gaps(.private)
    ck("Public messages are >= 3 ms apart", (pg.min() ?? 99) >= 2.9, "min \(pg.min() ?? 0) ms")
    ck("Private messages are >= 20 ms apart", (vg.min() ?? 99) >= 19.5 && vg.count == 3, "min \(vg.min() ?? 0) ms")
    let pad = rec.items.filter { $0.role == .public && $0.bytes.first == 0xF0 }.map { $0.ns }
    ck("pad-colour SysEx are >= 5 ms apart", pad.count == 2 && Double(pad[1] - pad[0]) / 1e6 >= 4.9)

    // coalescing: many updates of the same LED while the queue is busy collapse to the newest value
    let rec2 = Rec()
    let out2 = PacedOutput(send: { rec2.add($0, $1); return 0 }, startup: { 0 })
    out2.enqueue(.public, [0xB0, 1, 1])             // goes out first
    for v in 0..<30 { out2.enqueue(.public, [0xB0, 5, UInt8(v % 3)]) }
    out2.enqueue(.public, [0xB0, 5, 2])
    out2.enqueue(.public, h("F0 47 7F 37 65 00 04 03 01 01 01 F7"))
    out2.enqueue(.public, h("F0 47 7F 37 65 00 04 03 09 09 09 F7"))
    _ = out2.flush(timeout: 3)
    let sent5 = rec2.items.filter { $0.bytes.count == 3 && $0.bytes[1] == 5 }
    ck("queued updates for the same LED are coalesced (newest wins)", sent5.count < 31 && sent5.last?.bytes == h("B0 05 02") && out2.snapshot.coalesced > 0,
       "sent \(sent5.count), coalesced \(out2.snapshot.coalesced)")
    let padSent = rec2.items.filter { $0.bytes.first == 0xF0 }
    ck("queued colour updates for the same pad are coalesced", padSent.count == 1 && padSent[0].bytes == h("F0 47 7F 37 65 00 04 03 09 09 09 F7"))
}

private func checkOwnerCheck() {
    ck("owner check: PaperCut bundle id is a conflict", !OwnerCheck.conflicts(in: [RunningProcess(bundleID: "com.savilion.mpctouch.instrument", name: "Paper Cut")]).isEmpty)
    ck("owner check: Koala Link / Koala / Akai MPC bundle ids are conflicts",
       ["com.savilion.koala-touch", "com.elf-audio.koala-mac", "com.akaipro.mpc"].allSatisfy { !OwnerCheck.conflicts(in: [RunningProcess(bundleID: $0, name: "x")]).isEmpty })
    ck("owner check: executables MPC Touch / KoalaTouch / koala / MPC are conflicts",
       ["MPC Touch", "KoalaTouch", "koala", "MPC"].allSatisfy { !OwnerCheck.conflicts(in: [RunningProcess(bundleID: nil, name: $0)]).isEmpty })
    ck("owner check: the touch driver (mpc_touchd, mpc_watch) and unrelated apps are fine",
       OwnerCheck.conflicts(in: [RunningProcess(bundleID: nil, name: "mpc_touchd"), RunningProcess(bundleID: nil, name: "mpc_watch"),
                                 RunningProcess(bundleID: "com.apple.finder", name: "Finder")]).isEmpty)
    let path = NSTemporaryDirectory() + "touchsample-selftest-\(getpid()).lock"
    defer { try? FileManager.default.removeItem(atPath: path) }
    if let a = try? BridgeLock.acquire(path: path) {
        var second = false
        do { _ = try BridgeLock.acquire(path: path) } catch { second = true }
        ck("flock: a second bridge cannot take the lock", second)
        a.release()
        ck("flock: the lock can be taken again after release", (try? BridgeLock.acquire(path: path)) != nil)
    } else {
        ck("flock: acquire works", false, "could not create \(path)")
    }
}

private func checkJSONRoundTrip() throws {
    guard let p = sharedPaths, let data = FileManager.default.contents(atPath: p.profile),
          let text = String(data: data, encoding: .utf8) else { ck("profile JSON round trip", false, "cannot read profile"); return }
    var v = try JSONValue.parse(data)
    ck("ordered JSON: profile re-serialises byte-for-byte (key order and indent 1 stable)", v.serialized() == text.trimmingCharacters(in: .newlines))
    v["controls"]?["PAD 1"]?["verified"] = .bool(false)
    ck("ordered JSON: object subscripts keep key order when editing", v["controls"]?["PAD 1"]?.objectPairs?.map { $0.0 } == ["kind", "channel", "id", "port", "verified", "note"])
}

func runSelfTest(_ options: BridgeOptions) -> Int32 {
    print("touch-bridge --self-test (BridgeCore on a virtual clock; no MIDI, no network)\n")
    do {
        try loadJSON(options)
        try checkConfig()
        try checkPads()
        try checkKnobs()
        try checkWheelAndButtons()
        try checkBanks()
        try checkUnknown()
        try checkLights()
        try checkDisconnectAndStop()
        try checkHardRuleLayer()
        checkPacing()
        checkOwnerCheck()
        try checkJSONRoundTrip()
    } catch {
        print("FAIL  self-test aborted: \(error)")
        return 1
    }
    ck("hard rules: no effect in any scenario was a 0x5A SysEx, a SysEx to Private, or refused by TouchMIDI",
       violations.isEmpty, violations.prefix(5).joined(separator: "; "))
    print("\n\(passed.count) passed, \(failed.count) failed")
    if !failed.isEmpty {
        print("\nFAILED:")
        for f in failed { print("  - \(f.name)\n      \(f.detail)") }
        return 1
    }
    return 0
}
