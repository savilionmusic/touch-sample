import Foundation
import BridgeCore
import TouchIO

// touch-capture: Phase 1 CLI, run by Sav in Terminal.app with PaperCut and Koala quit.
//   touch-capture --list      print the MPC Touch endpoints it would use (no output)
//   touch-capture guided      walk every control in hardware/touch-profile.json (input only, NO output port)
//   touch-capture leds        LED + pad-colour test (Public only, one message at a time, human-paced)

let usage = """
touch-capture: learn the MPC Touch's raw IDs and lights; writes hardware/touch-profile.json.

usage:
  touch-capture --list                 print the MPC Touch endpoints it would use (no output is opened)
  touch-capture guided                 walk every control in the profile; input only, opens NO output port
  touch-capture leds                   light each button one at a time and ask; then one pad-colour test
  touch-capture --help

options (with guided / leds):
  --profile FILE   profile to read and merge into (default: the repo's hardware/touch-profile.json)
  --root DIR       repo root (or set TOUCHSAMPLE_ROOT)

guided: for each control it asks you to press / turn / touch it. Enter skips a step, ? marks it "not on this
Touch". Buttons you press that are in no step are recorded as spares with their raw ID. The raw log goes to
captures/raw/<timestamp>.log (git-ignored); results are merged into the profile with verified: true,
key order unchanged.

Quit PaperCut and Koala first: this refuses to start (exit 2) while another app owns the Touch.
Run it from Terminal.app.
"""

// MARK: arguments

var args = Array(CommandLine.arguments.dropFirst())
var profileOverride: String?
var rootOverride: String?
var command: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--help", "-h", "help": print(usage); exit(0)
    case "--list", "list": command = "list"
    case "guided", "leds": command = a
    case "--profile": profileOverride = args.isEmpty ? nil : args.removeFirst()
    case "--root": rootOverride = args.isEmpty ? nil : args.removeFirst()
    default: fputs("touch-capture: unknown argument \(a)\n\n\(usage)\n", stderr); exit(64)
    }
}
guard let command = command else { print(usage); exit(64) }

func die(_ m: String, _ code: Int32 = 1) -> Never { fputs("touch-capture: \(m)\n", stderr); exit(code) }

if command == "list" {
    let eps = TouchPorts.list()
    if eps.isEmpty { print("No MPC Touch endpoints found.") }
    for e in eps {
        print("\(e.role.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(e.isSource ? "in " : "   ")\(e.isDestination ? "out" : "   ")  device \"\(e.device)\"  entity \"\(e.entity)\"  endpoint \"\(e.endpoint)\"")
    }
    exit(0)
}

// MARK: shared setup

let paths: RepoPaths
do { paths = try RepoPaths.resolve(root: rootOverride, profile: profileOverride) } catch { die("\(error)") }
guard let profileData = FileManager.default.contents(atPath: paths.profile) else { die("cannot read \(paths.profile)") }
var profile: JSONValue
do { profile = try JSONValue.parse(profileData) } catch { die("\(paths.profile): \(error)") }

let conflicts = OwnerCheck.check()
if !conflicts.isEmpty {
    die("refusing to start: another app owns the MPC Touch (" + conflicts.joined(separator: ", ") + "). Quit it first.", 2)
}
let lock: BridgeLock
do { lock = try BridgeLock.acquire() } catch { die("refusing to start: \(error)", 2) }
_ = lock

func saveProfile() {
    do {
        try (profile.serialized() as NSString).write(toFile: paths.profile, atomically: true, encoding: String.Encoding.utf8.rawValue)
        print("Saved \(paths.profile)")
    } catch { print("Could not write the profile: \(error)") }
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: " ")
    fflush(stdout)
    return (readLine() ?? "q").trimmingCharacters(in: .whitespaces)
}

// MARK: events from the Touch + stdin (guided)

enum Event {
    case midi(role: PortRole, m: RawMessage)
    case line(String)
}

final class Inbox {
    private let lock = NSCondition()
    private var items: [Event] = []
    func push(_ e: Event) { lock.lock(); items.append(e); lock.signal(); lock.unlock() }
    func pop(timeout: TimeInterval) -> Event? {
        lock.lock(); defer { lock.unlock() }
        let end = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !lock.wait(until: end) { break }
        }
        return items.isEmpty ? nil : items.removeFirst()
    }
    /// Drops everything that arrived so far plus anything in the next `settle` seconds (a button's release...).
    func drain(settle: TimeInterval) {
        let end = Date().addingTimeInterval(settle)
        while let _ = pop(timeout: max(0.01, end.timeIntervalSinceNow)) { if Date() > end { break } }
    }
}

func hexs(_ m: RawMessage) -> String { hexString(m.bytes) }

// MARK: guided

func runGuided() {
    let inbox = Inbox()
    let ports = TouchPorts()
    let parseLock = NSLock()
    var parsers: [PortRole: MidiStreamParser] = [.public: MidiStreamParser(), .private: MidiStreamParser()]

    try? FileManager.default.createDirectory(atPath: paths.capturesDir, withIntermediateDirectories: true)
    let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
    let logPath = paths.capturesDir + "/" + stamp + ".log"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logFile = FileHandle(forWritingAtPath: logPath)
    func rawLog(_ s: String) { logFile?.write((s + "\n").data(using: .utf8)!) }

    ports.onPacket = { role, bytes, _ in
        parseLock.lock()
        var p = parsers[role] ?? MidiStreamParser()
        let msgs = p.feed(bytes)
        parsers[role] = p
        parseLock.unlock()
        for m in msgs { inbox.push(.midi(role: role, m: m)) }
    }
    let n: Int
    do { n = try ports.open(output: false) } catch { die("\(error)") }       // input only: no output port at all
    if n == 0 { die("no MPC Touch MIDI input found (is it plugged in and is PaperCut/Koala quit?)", 3) }
    print("Listening on \(n) MPC Touch input port(s). No output port is opened.")
    print("Raw log: \(logPath)\n")
    Thread.detachNewThread { while let l = readLine() { inbox.push(.line(l)) } }

    // known ids: channel-1 notes of every control in the profile
    var known = Set<Int>()
    func rebuildKnown() {
        known = []
        for (_, c) in profile["controls"]?.objectPairs ?? [] where c["kind"]?.stringValue == "note" {
            if let id = c["id"]?.intValue { known.insert(id) }
        }
    }
    rebuildKnown()
    var spares = [Int: String]()      // note id -> port
    var results = [String: String]()

    func note(_ role: PortRole, _ m: RawMessage) {
        rawLog(String(format: "%.3f %@ %@", Date().timeIntervalSince1970, role.label, hexs(m)))
    }
    func stray(_ role: PortRole, _ m: RawMessage) {
        if m.kind == 0x90, m.d2 > 0, m.channel == 0, !known.contains(Int(m.d1)), spares[Int(m.d1)] == nil {
            spares[Int(m.d1)] = role.rawValue
            print("   (extra button: note \(m.d1) / 0x\(String(format: "%02X", m.d1)) on \(role.label) recorded as a spare)")
        }
    }

    inbox.drain(settle: 0.2)
    let controls = profile["controls"]?.objectPairs ?? []
    print("Steps: Enter = skip, ? = not on this Touch, Ctrl-C = quit without saving.\n")
    for (idx, (name, c)) in controls.enumerated() {
        guard let kind = c["kind"]?.stringValue else { continue }
        let isTouch = name.hasSuffix(" TOUCH")
        let prompt: String
        switch kind {
        case "pad": prompt = "Hit \(name)"
        case "cc": prompt = name.hasPrefix("Q") ? "Turn \(name.replacingOccurrences(of: "Q", with: "Q-Link ")) all the way left, then right, then press Enter"
                                                  : "Turn the data wheel right, then left, then press Enter"
        default: prompt = isTouch ? "Touch \(name.replacingOccurrences(of: " TOUCH", with: "").replacingOccurrences(of: "Q", with: "Q-Link ")) (just touch the knob, don't turn it)" : "Press and release \(name)"
        }
        print("[\(idx + 1)/\(controls.count)] \(prompt)")
        inbox.drain(settle: 0.15)
        var captured: (id: Int, channel: Int, port: PortRole)?
        var lo = 127, hi = 0
        var cc = -1
        var otherPort: PortRole?
        var skipped = false, absent = false
        loop: while true {
            guard let ev = inbox.pop(timeout: 60) else { continue }
            switch ev {
            case .line(let l):
                let t = l.trimmingCharacters(in: .whitespaces)
                if t == "?" { absent = true; break loop }
                if kind == "cc" && cc >= 0 && t.isEmpty { break loop }
                if t.isEmpty { skipped = true; break loop }
            case .midi(let role, let m):
                note(role, m)
                switch kind {
                case "pad":
                    if m.kind == 0x90, m.d2 > 0, m.channel == 9, role == .public { captured = (Int(m.d1), 10, role); break loop }
                    stray(role, m)
                case "cc":
                    if m.kind == 0xB0, m.channel == 0, cc < 0 || Int(m.d1) == cc {
                        cc = Int(m.d1); lo = min(lo, Int(m.d2)); hi = max(hi, Int(m.d2))
                        captured = (cc, 1, role)
                    } else { stray(role, m) }
                default:
                    guard m.kind == 0x90, m.d2 > 0 else { continue }
                    if m.channel != 0 { continue }
                    // already another control's id?
                    var owner: String?
                    for (n2, c2) in controls where n2 != name && c2["kind"]?.stringValue == "note" && c2["id"]?.intValue == Int(m.d1) && results[n2] != nil { owner = n2 }
                    if let o = owner { print("   that was \(o) (note \(m.d1)); try \(name) again"); continue }
                    captured = (Int(m.d1), 1, role); break loop
                }
            }
        }
        if absent {
            profile["controls"]?[name]?["absent"] = .bool(true)
            profile["controls"]?[name]?["verified"] = .bool(false)
            results[name] = "absent"
            print("   marked not on this Touch")
        } else if skipped || captured == nil {
            print("   skipped")
        } else if let cap = captured {
            if kind == "note" {
                // collect the release and a possible duplicate on the other port for a moment
                let end = Date().addingTimeInterval(0.4)
                while let ev = inbox.pop(timeout: max(0.01, end.timeIntervalSinceNow)) {
                    if case .midi(let role, let m) = ev {
                        note(role, m)
                        if m.kind == 0x90, m.d2 > 0, Int(m.d1) == cap.id, role != cap.port { otherPort = role }
                    }
                    if Date() > end { break }
                }
            }
            profile["controls"]?[name]?["id"] = .int(cap.id)
            profile["controls"]?[name]?["channel"] = .int(cap.channel)
            profile["controls"]?[name]?["port"] = .string(cap.port.rawValue)
            profile["controls"]?[name]?["verified"] = .bool(true)
            profile["controls"]?[name]?["absent"] = nil
            if kind == "cc" {
                profile["controls"]?[name]?["min"] = .int(lo)
                profile["controls"]?[name]?["max"] = .int(hi)
            }
            if let o = otherPort { profile["controls"]?[name]?["alsoPort"] = .string(o.rawValue) }
            if kind == "note" { known.insert(cap.id) }
            results[name] = "id \(cap.id) on \(cap.port.label)"
            print("   got \(cap.id) (0x\(String(format: "%02X", cap.id))) on \(cap.port.label)" + (kind == "cc" ? " range \(lo)...\(hi)" : "") + (otherPort != nil ? " (also on \(otherPort!.label))" : ""))
        }
    }

    print("\nExtra buttons: press any buttons not in the list (UNDO, COPY, ...), one at a time. Enter when done.")
    inbox.drain(settle: 0.2)
    extra: while true {
        guard let ev = inbox.pop(timeout: 60) else { continue }
        switch ev {
        case .line: break extra
        case .midi(let role, let m): note(role, m); stray(role, m)
        }
    }
    // spares that turned out to match a named control are not spares
    rebuildKnown()
    var list = profile["spares"]?.arrayValue ?? []
    let existing = Set(list.compactMap { $0["id"]?.intValue })
    for (id, port) in spares.sorted(by: { $0.key < $1.key }) where !known.contains(id) && !existing.contains(id) {
        list.append(.object([("id", .int(id)), ("port", .string(port)), ("verified", .bool(true)),
                             ("source", .string("touch-capture guided")), ("name", .null)]))
    }
    list = list.map { s in
        var s = s
        if let id = s["id"]?.intValue, spares[id] != nil { s["verified"] = .bool(true) }
        return s
    }
    profile["spares"] = .array(list)
    ports.close()
    saveProfile()
    print("\nCaptured: \(results.count) controls, \(spares.count) new spare button(s). Raw log: \(logPath)")
}

// MARK: leds

func runLeds() {
    print("""
    This sends the three startup SysEx, then ONE LED message at a time (B0 <id> <value>) to the Touch's Public
    port, and asks what you see. Then one pad-colour test. Nothing is ever sent to Private.
    """)
    if ask("Continue? [y/N]").lowercased() != "y" { print("Nothing sent."); return }
    let ports = TouchPorts()
    do { _ = try ports.open(output: true) } catch { die("\(error)") }
    if ports.outputMask & 1 == 0 { die("the MPC Touch Public output is not available", 3) }
    let out = PacedOutput(send: { ports.send($0, $1) }, startup: { ports.startup() })
    out.onError = { print("   send problem: \($0)") }
    out.enqueueStartup()
    out.flush()
    Thread.sleep(forTimeInterval: 0.3)

    func send(_ b: [UInt8]) { out.enqueue(.public, b); out.flush() }

    var quit = false
    let controls = profile["controls"]?.objectPairs ?? []
    for (name, c) in controls {
        guard !quit, c["kind"]?.stringValue == "note", c["absent"]?.boolValue != true,
              !name.hasSuffix(" TOUCH"), name != "DATA PUSH", let id = c["id"]?.intValue else { continue }
        let ledId = c["led"]?.intValue ?? id
        let value: UInt8 = name.hasPrefix("BANK") ? 3 : 2
        send([0xB0, UInt8(ledId), value])
        let a = ask("Is \(name) (LED \(ledId)) lit? [y/n/q]").lowercased()
        send([0xB0, UInt8(ledId), 0])
        switch a {
        case "y":
            profile["controls"]?[name]?["led"] = .int(ledId)
            profile["controls"]?[name]?["ledVerified"] = .bool(true)
        case "n":
            profile["controls"]?[name]?["ledVerified"] = .bool(false)
        case "q": quit = true
        default: break
        }
    }
    // spares: LED id = note id
    var spareList = profile["spares"]?.arrayValue ?? []
    if !quit {
        for i in spareList.indices {
            guard let id = spareList[i]["id"]?.intValue else { continue }
            send([0xB0, UInt8(id), 2])
            let a = ask("Is spare button note \(id) (0x\(String(format: "%02X", id))) lit? [y/n/q]").lowercased()
            send([0xB0, UInt8(id), 0])
            if a == "q" { quit = true; break }
            if a == "y" { spareList[i]["ledVerified"] = .bool(true) }
            if a == "n" { spareList[i]["ledVerified"] = .bool(false) }
        }
        profile["spares"] = .array(spareList)
    }

    if !quit, ask("Pad-colour test (F0 47 7F 37 65 00 04 <pad> R G B F7, Public)? [y/N]").lowercased() == "y" {
        func colour(_ idx: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) { send([0xF0, 0x47, 0x7F, 0x37, 0x65, 0x00, 0x04, UInt8(idx), r, g, b, 0xF7]) }
        colour(0, 127, 0, 0)
        let a = Int(ask("Which pad lit red? (1-16, 0 = none)")) ?? 0
        colour(0, 0, 0, 0)
        var enabled = false
        var map = Array(0..<16)
        if (1...16).contains(a) {
            enabled = true
            map[a - 1] = 0
            if ask("Map the other 15 the same way, one index at a time? [y/N]").lowercased() == "y" {
                var used = [a - 1]
                for idx in 1..<16 {
                    colour(idx, 127, 0, 0)
                    let p = Int(ask("Index \(idx): which pad lit? (1-16, 0 = none)")) ?? 0
                    colour(idx, 0, 0, 0)
                    if (1...16).contains(p), !used.contains(p - 1) { map[p - 1] = idx; used.append(p - 1) }
                }
            }
        }
        profile["padColour"]?["enabled"] = .bool(enabled)
        profile["padColour"]?["verified"] = .bool(enabled)
        profile["padColour"]?["indexMap"] = .array(map.map { .int($0) })
    }
    // leave the lights off
    out.flush()
    out.clear()
    ports.close()
    saveProfile()
}

switch command {
case "guided": runGuided()
case "leds": runLeds()
default: break
}
