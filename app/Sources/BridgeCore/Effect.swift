import Foundation

/// A raw packet from one MPC Touch port.
public struct TouchMessage {
    public var role: PortRole
    public var bytes: [UInt8]
    public init(role: PortRole, bytes: [UInt8]) { self.role = role; self.bytes = bytes }
}

/// What the emulator's panel server tells us (ws /bridge, server -> client).
public enum SampleEvent {
    case led(id: Int, v: Int)
    case pad(i: Int, rgb: [Int])
    case hello(leds: [Int: Int], pads: [Int: [Int]], vm: Bool)
    case vm(connected: Bool)
}

/// Timers the core asks its host to deliver back through `BridgeCore.handle(timer:)`.
public enum CoreTimer: Equatable {
    case walkStart(Int)
    case walkRelease(Int)
    case walkTimeout(Int)
}

/// What the core wants done. The host (BridgeRunner, or the self-test's virtual clock) executes these in order;
/// `after` delays are relative to the moment the effect list is executed.
public indirect enum Effect {
    case toSample([UInt8])
    case toTouch(PortRole, [UInt8])
    case touchStartup                    // the three Public startup SysEx (TouchMIDI owns the bytes)
    case ui([String: Any])               // a /bridge {"t":"ui",...} object
    case log(String)
    case after(Int, Effect)              // milliseconds
    case batch([Effect])
    case timer(CoreTimer)

    public var summary: String {
        switch self {
        case .toSample(let b): return "toSample \(hexString(b))"
        case .toTouch(let r, let b): return "toTouch \(r.label) \(hexString(b))"
        case .touchStartup: return "touchStartup"
        case .ui(let d): return "ui \(d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: ","))"
        case .log(let s): return "log \(s)"
        case .after(let ms, let e): return "after \(ms)ms [\(e.summary)]"
        case .batch(let es): return "batch [\(es.map { $0.summary }.joined(separator: "; "))]"
        case .timer(let t): return "timer \(t)"
        }
    }
}

public func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
