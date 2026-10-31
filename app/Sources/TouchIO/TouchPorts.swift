import Foundation
import TouchMIDI
import BridgeCore

public struct TouchEndpoint {
    public let role: PortRole
    public let isSource: Bool
    public let isDestination: Bool
    public let device: String
    public let entity: String
    public let endpoint: String
}

public enum TouchPortError: Error, CustomStringConvertible {
    case coreMIDI(Int32)
    case alreadyOpen
    public var description: String {
        switch self {
        case .coreMIDI(let c): return "CoreMIDI could not be opened (\(TouchPorts.errorString(c)))"
        case .alreadyOpen: return "the MPC Touch MIDI ports are already open in this process"
        }
    }
}

/// Swift face of TouchMIDI. Create it (and call `open`) on the main thread with the main run loop running, so
/// CoreMIDI's setup-changed notifications arrive. There is one set of ports per process.
public final class TouchPorts {
    /// Called on a CoreMIDI thread: port role, raw packet bytes, packet time (monotonic ns, see `nowNs`).
    public var onPacket: ((PortRole, [UInt8], UInt64) -> Void)?
    /// Called on the thread that opened the ports. Follow it with `rescan()`.
    public var onSetupChanged: (() -> Void)?

    public init() {}

    /// Returns the number of connected input sources (0 when the Touch is absent: the client stays open).
    @discardableResult
    public func open(output: Bool) throws -> Int {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = touch_open({ role, bytes, len, ns, c in
            guard let c = c, let bytes = bytes, len > 0 else { return }
            let me = Unmanaged<TouchPorts>.fromOpaque(c).takeUnretainedValue()
            me.onPacket?(role == Int32(TOUCH_PORT_PRIVATE) ? .private : .public,
                         Array(UnsafeBufferPointer(start: bytes, count: Int(len))), ns)
        }, ctx, { c in
            guard let c = c else { return }
            Unmanaged<TouchPorts>.fromOpaque(c).takeUnretainedValue().onSetupChanged?()
        }, ctx, output ? 1 : 0)
        if rc == Int32(TOUCH_ERR_ARGS) { throw TouchPortError.alreadyOpen }
        if rc < 0 { throw TouchPortError.coreMIDI(rc) }
        return Int(rc)
    }

    public func rescan() -> (count: Int, changed: Bool) {
        var changed: Int32 = 0
        let n = touch_rescan(&changed)
        return (Int(n), changed != 0)
    }

    public var inputCount: Int { Int(touch_input_count()) }
    /// Bit 0: Public destination present; bit 1: Private destination present.
    public var outputMask: Int { Int(touch_output_mask()) }

    /// Validated by the C layer (no 0x5A SysEx, no SysEx to Private, Private CC allow-list). No pacing here.
    @discardableResult
    public func send(_ role: PortRole, _ bytes: [UInt8]) -> Int32 {
        bytes.withUnsafeBufferPointer { touch_send(role == .private ? Int32(TOUCH_PORT_PRIVATE) : Int32(TOUCH_PORT_PUBLIC), $0.baseAddress, Int32($0.count)) }
    }

    /// The three Public startup SysEx (blocks ~40 ms).
    public func startup() -> Int32 { touch_startup() }

    public func close() { touch_close() }

    // MARK: static helpers

    public static func list() -> [TouchEndpoint] {
        var rows = [touch_endpoint_info](repeating: touch_endpoint_info(), count: 32)
        let n = Int(touch_list_endpoints(&rows, 32))
        func str<T>(_ t: T) -> String {
            var t = t
            return withUnsafePointer(to: &t) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
        }
        return rows.prefix(n).map {
            TouchEndpoint(role: $0.role == Int32(TOUCH_PORT_PRIVATE) ? .private : .public,
                          isSource: $0.is_source != 0, isDestination: $0.is_destination != 0,
                          device: str($0.device), entity: str($0.entity), endpoint: str($0.endpoint))
        }
    }

    /// Pure check of the hard rules (no I/O): 0 = would be sent.
    public static func validate(_ role: PortRole, _ bytes: [UInt8]) -> Int32 {
        bytes.withUnsafeBufferPointer {
            touch_validate(role == .private ? Int32(TOUCH_PORT_PRIVATE) : Int32(TOUCH_PORT_PUBLIC), $0.baseAddress, Int32($0.count))
        }
    }

    public static func startupMessages() -> [[UInt8]] {
        (0..<Int(touch_startup_count())).compactMap { i in
            var buf = [UInt8](repeating: 0, count: 32)
            let n = touch_startup_message(Int32(i), &buf, 32)
            return n > 0 ? Array(buf.prefix(Int(n))) : nil
        }
    }

    public static func nowNs() -> UInt64 { touch_now_ns() }

    public static func errorString(_ code: Int32) -> String { String(cString: touch_error_string(code)) }
}
