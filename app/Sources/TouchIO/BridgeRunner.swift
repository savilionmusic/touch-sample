import Foundation
import BridgeCore

public enum BridgeError: Error, CustomStringConvertible {
    case ownerConflict([String])
    case lockHeld(String)
    case config(String)
    case midi(String)
    public var description: String {
        switch self {
        case .ownerConflict(let c):
            return "refusing to start: another app owns the MPC Touch (" + c.joined(separator: ", ") + "). Quit it first."
        case .lockHeld(let m): return "refusing to start: \(m)"
        case .config(let m): return "configuration error: \(m)"
        case .midi(let m): return m
        }
    }
    /// Exit code the CLIs use: 2 = refused because the Touch is owned elsewhere.
    public var exitCode: Int32 {
        switch self { case .ownerConflict, .lockHeld: return 2; default: return 1 }
    }
}

public struct BridgeOptions {
    public var serverURL = "ws://127.0.0.1:8765/bridge"
    public var profilePath: String?
    public var mappingPath: String?
    public var controlsPath: String?
    public var rootPath: String?
    public var verbose = false
    public var lights = true
    public init() {}
}

/// Wires TouchIO (CoreMIDI, paced output, WebSocket) to BridgeCore. An AppKit app can embed it:
/// create it, call `start()` on the main thread (main run loop running), `stop()` on quit.
public final class BridgeRunner {
    public struct State: Equatable {
        public var touchConnected = false
        public var socketConnected = false
    }

    public let options: BridgeOptions
    public var log: (String) -> Void = { print($0); fflush(stdout) }
    public var onStateChange: ((State) -> Void)?
    public private(set) var state = State()

    private let q = DispatchQueue(label: "touchsample.bridge", qos: .userInteractive)
    private var core: BridgeCore!
    private var ports: TouchPorts!
    private var output: PacedOutput!
    private var socket: BridgeSocket!
    private var lock: BridgeLock?
    private var statsTimer: DispatchSourceTimer?
    private var latenciesMs: [Double] = []
    private var currentInputNs: UInt64 = 0
    private var started = false

    public init(options: BridgeOptions = BridgeOptions()) { self.options = options }

    public func start() throws {
        guard !started else { return }
        let paths: RepoPaths
        let config: BridgeConfig
        do {
            paths = try RepoPaths.resolve(root: options.rootPath, profile: options.profilePath,
                                          mapping: options.mappingPath, controls: options.controlsPath)
            config = try BridgeConfig.load(paths)
        } catch { throw BridgeError.config("\(error)") }
        guard let url = URL(string: options.serverURL) else { throw BridgeError.config("bad server URL \(options.serverURL)") }

        // Hard rule 4, before any MIDI port is opened.
        let conflicts = OwnerCheck.check()
        if !conflicts.isEmpty { throw BridgeError.ownerConflict(conflicts) }
        do { lock = try BridgeLock.acquire() } catch { throw BridgeError.lockHeld("\(error)") }

        for w in config.warnings { log("warning: \(w)") }
        core = BridgeCore(config: config, lights: options.lights)
        for n in core.setupNotes { log("note: \(n)") }

        ports = TouchPorts()
        output = PacedOutput(send: { [weak self] role, bytes in self?.ports.send(role, bytes) ?? -6 },
                             startup: { [weak self] in self?.ports.startup() ?? -6 })
        output.onError = { [weak self] m in self?.log("output: \(m)") }
        socket = BridgeSocket(url: url, queue: q)
        socket.onLog = { [weak self] m in self?.log(m) }
        socket.onOpen = { [weak self] in
            guard let self = self else { return }
            self.state.socketConnected = true
            self.notify()
            self.run(self.core.statusEffects(), origin: 0)
        }
        socket.onClose = { [weak self] in self?.state.socketConnected = false; self?.notify() }
        socket.onText = { [weak self] text in self?.receive(text) }

        ports.onPacket = { [weak self] role, bytes, ns in
            self?.q.async { self?.touchPacket(role, bytes, ns) }
        }
        ports.onSetupChanged = { [weak self] in self?.q.async { self?.rescan() } }
        let n: Int
        do { n = try ports.open(output: options.lights) } catch {
            lock?.release(); lock = nil
            throw BridgeError.midi("\(error)")
        }
        started = true
        q.sync {
            run(core.start(), origin: 0)
            log(n > 0 ? "MPC Touch MIDI connected (\(n) input port(s))" : "MPC Touch not found; waiting for it to appear")
            if n > 0 { touchUp() }
        }
        socket.start()
        if options.verbose { startStats() }
    }

    /// Releases everything held on the Sample, lights off, pads black, then closes.
    public func stop() {
        guard started else { return }
        started = false
        statsTimer?.cancel()
        q.sync { run(core.stop(), origin: 0) }
        _ = output.flush(timeout: 3)
        Thread.sleep(forTimeInterval: 0.2)   // let pending WebSocket sends (releases) go out
        socket.stop()
        ports.close()
        lock?.release()
        lock = nil
    }

    // MARK: events

    private func touchUp() {
        state.touchConnected = true
        notify()
        run(core.touchConnected(), origin: 0)
    }

    private func rescan() {
        guard started else { return }
        let r = ports.rescan()
        guard r.changed else { return }
        if r.count > 0 {
            log("MPC Touch MIDI (re)connected (\(r.count) input port(s))")
            touchUp()
        } else {
            log("MPC Touch MIDI disconnected")
            state.touchConnected = false
            notify()
            run(core.touchDisconnected(), origin: 0)
        }
    }

    private func touchPacket(_ role: PortRole, _ bytes: [UInt8], _ ns: UInt64) {
        guard started else { return }
        if options.verbose { log("in  \(role.label) \(hexString(bytes))") }
        run(core.handle(touch: TouchMessage(role: role, bytes: bytes)), origin: ns)
    }

    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return }
        switch t {
        case "hello":
            var leds = [Int: Int](), pads = [Int: [Int]]()
            for (k, v) in (obj["leds"] as? [String: Any]) ?? [:] { if let i = Int(k), let n = v as? Int { leds[i] = n } }
            for (k, v) in (obj["pads"] as? [String: Any]) ?? [:] { if let i = Int(k), let a = v as? [Int] { pads[i] = a } }
            run(core.handle(sample: .hello(leds: leds, pads: pads, vm: (obj["vm"] as? Bool) ?? false)), origin: 0)
        case "led":
            if let id = obj["id"] as? Int, let v = obj["v"] as? Int { run(core.handle(sample: .led(id: id, v: v)), origin: 0) }
        case "pad":
            if let i = obj["i"] as? Int, let rgb = obj["rgb"] as? [Int] { run(core.handle(sample: .pad(i: i, rgb: rgb)), origin: 0) }
        case "vm":
            run(core.handle(sample: .vm(connected: (obj["connected"] as? Bool) ?? false)), origin: 0)
        default: break
        }
    }

    // MARK: effect execution (always on q)

    private func run(_ effects: [Effect], origin: UInt64) {
        for e in effects { exec(e, origin: origin) }
    }

    private func exec(_ e: Effect, origin: UInt64) {
        switch e {
        case .toSample(let bytes):
            socket.send("{\"t\":\"send\",\"hex\":\"\(hexString(bytes))\"}")
            if origin != 0 {
                latenciesMs.append(Double(TouchPorts.nowNs() &- origin) / 1_000_000)
            }
            if options.verbose { log("out Sample \(hexString(bytes))") }
        case .toTouch(let role, let bytes):
            output.enqueue(role, bytes)
        case .touchStartup:
            output.enqueueStartup()
        case .ui(let dict):
            if let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) { socket.send(s) }
        case .log(let s):
            log(s)
        case .after(let ms, let inner):
            q.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.exec(inner, origin: 0) }
        case .batch(let list):
            run(list, origin: origin)
        case .timer(let t):
            run(core.handle(timer: t), origin: 0)
        }
    }

    private func notify() { let s = state; onStateChange?(s) }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self = self, !self.latenciesMs.isEmpty else { return }
            let sorted = self.latenciesMs.sorted()
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            let ps = self.output.snapshot
            self.log(String(format: "latency Touch packet -> WebSocket send: n=%d p50=%.2f ms p95=%.2f ms max=%.2f ms | Touch output sent=%d coalesced=%d errors=%d",
                            sorted.count, pct(0.5), pct(0.95), sorted.last!, ps.sent, ps.coalesced, ps.errors))
            self.latenciesMs.removeAll()
        }
        t.resume()
        statsTimer = t
    }
}

/// `touch-bridge --learn`: input only. Prints the raw message of each Touch press so Sav can add it to the profile.
public final class TouchLearn {
    private let q = DispatchQueue(label: "touchsample.learn")
    private let ports = TouchPorts()
    private var parsers: [PortRole: MidiStreamParser] = [.public: MidiStreamParser(), .private: MidiStreamParser()]
    private var lock: BridgeLock?
    private let onlyName: String?
    private let names: [String: String]     // "ch<<8|note" -> control name, from the profile (hint only)
    public var log: (String) -> Void = { print($0); fflush(stdout) }
    /// Called after the first press when a name was given.
    public var onDone: (() -> Void)?

    public init(profilePath: String?, rootPath: String?, name: String?) {
        onlyName = name
        var n = [String: String]()
        if let p = try? RepoPaths.resolve(root: rootPath, profile: profilePath),
           let data = FileManager.default.contents(atPath: p.profile),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prof = try? TouchProfile(json: j) {
            for ctl in prof.controls where ctl.kind == .note { n["\(ctl.channel)-\(ctl.id)"] = ctl.name }
        }
        names = n
    }

    public func start() throws {
        let conflicts = OwnerCheck.check()
        if !conflicts.isEmpty { throw BridgeError.ownerConflict(conflicts) }
        do { lock = try BridgeLock.acquire() } catch { throw BridgeError.lockHeld("\(error)") }
        ports.onPacket = { [weak self] role, bytes, _ in self?.q.async { self?.packet(role, bytes) } }
        ports.onSetupChanged = { [weak self] in self?.q.async { _ = self?.ports.rescan() } }
        let n: Int
        do { n = try ports.open(output: false) } catch { throw BridgeError.midi("\(error)") }   // input only
        log(n > 0 ? "learn: listening on \(n) MPC Touch input port(s), no output opened. Press buttons on the Touch; Ctrl-C to stop."
                  : "learn: MPC Touch not found yet; waiting for it to appear")
        if let name = onlyName { log("learn: press \"\(name)\" now") }
    }

    public func stop() { ports.close(); lock?.release(); lock = nil }

    private func packet(_ role: PortRole, _ bytes: [UInt8]) {
        var p = parsers[role] ?? MidiStreamParser()
        let msgs = p.feed(bytes)
        parsers[role] = p
        for m in msgs where m.kind == 0x90 && m.d2 > 0 {      // presses only
            let hint = names["\(m.channel)-\(m.d1)"].map { "  (profile: \($0))" } ?? ""
            log("\(role.label) \(hexString(m.bytes))  note-on ch\(m.channel + 1) note \(m.d1) (0x\(String(format: "%02X", m.d1)))\(hint)")
            if let name = onlyName {
                log("  profile snippet: \"\(name)\": {\"kind\": \"note\", \"channel\": \(m.channel + 1), \"id\": \(m.d1), \"port\": \"\(role.rawValue)\"}")
                onDone?()
                return
            }
        }
    }
}
