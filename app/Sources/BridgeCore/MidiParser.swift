import Foundation

/// One decoded channel message. `d2` is 0 for the one-data-byte kinds (program change, channel pressure).
public struct RawMessage: Equatable {
    public var status: UInt8
    public var d1: UInt8
    public var d2: UInt8
    public init(status: UInt8, d1: UInt8, d2: UInt8) { self.status = status; self.d1 = d1; self.d2 = d2 }
    public var kind: UInt8 { status & 0xF0 }
    public var channel: Int { Int(status & 0x0F) }
    public var bytes: [UInt8] {
        (kind == 0xC0 || kind == 0xD0) ? [status, d1] : [status, d1, d2]
    }
}

/// Running-status parser with SysEx skipping; realtime bytes ignored. One instance per input port.
/// Adapted from PaperCut app/Sources/MPCApp/Instrument.swift, MIDIInput.consume(_:from:receivedAt:).
public struct MidiStreamParser {
    private var running: UInt8 = 0
    private var data: [UInt8] = []
    private var inSysEx = false

    public init() {}

    public mutating func reset() { running = 0; data.removeAll(); inSysEx = false }

    public mutating func feed(_ bytes: [UInt8]) -> [RawMessage] {
        var out = [RawMessage]()
        for byte in bytes {
            if byte >= 0xF8 { continue }                       // realtime
            if byte == 0xF0 { inSysEx = true; running = 0; data.removeAll(keepingCapacity: true); continue }
            if byte == 0xF7 { inSysEx = false; running = 0; data.removeAll(keepingCapacity: true); continue }
            if inSysEx { continue }
            if byte & 0x80 != 0 {
                // F1..F6 (system common) carry data we never use: drop them and their data.
                running = byte >= 0xF0 ? 0 : byte
                data.removeAll(keepingCapacity: true)
                continue
            }
            guard running != 0 else { continue }
            data.append(byte)
            let kind = running & 0xF0
            let need = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
            guard data.count >= need else { continue }
            out.append(RawMessage(status: running, d1: data[0], d2: need == 2 ? data[1] : 0))
            data.removeAll(keepingCapacity: true)
        }
        return out
    }
}
