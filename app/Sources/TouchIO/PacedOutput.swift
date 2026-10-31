import Foundation
import BridgeCore

/// Output pacing (hard rule 3). One serial queue per port, every message at least 20 ms after the previous one on
/// that port (PaperCut spaces every send by 20 ms, ControllerSetup.c send_bytes):
///  - Public: LED CCs, pad-colour SysEx, the startup SysEx.
///  - Private: only B0 23..26 / B0 5A..5D (the C layer enforces it), and never before the Public messages that were
///    queued ahead of it have gone out (PaperCut sends Public first, ControllerSetup.c).
/// Updates for the same LED / pad that are still queued get coalesced (the newest value replaces the old one), so a
/// queue never holds more than one message per LED however often the state is refreshed.
public final class PacedOutput {
    public typealias Sender = (PortRole, [UInt8]) -> Int32

    public struct Stats { public var sent = 0, coalesced = 0, errors = 0 }

    private let sender: Sender
    private let startupFn: () -> Int32
    private let publicQueue: PortQueue
    private let privateQueue: PortQueue
    private let lock = NSLock()
    private var stats = Stats()
    private var nextSeq = 0
    public var onError: ((String) -> Void)?

    public init(publicGapMs: Int = 20, padGapMs: Int = 20, privateGapMs: Int = 20,
                send: @escaping Sender, startup: @escaping () -> Int32) {
        self.sender = send
        self.startupFn = startup
        publicQueue = PortQueue(label: "touchsample.out.public")
        privateQueue = PortQueue(label: "touchsample.out.private")
        publicQueue.gapFor = { item in
            switch item.payload {
            case .startup: return 20
            case .message(let b): return b.first == 0xF0 ? padGapMs : publicGapMs
            }
        }
        privateQueue.gapFor = { _ in privateGapMs }
        let pub = publicQueue
        privateQueue.mayDeliver = { item in !pub.hasQueued(before: item.seq) }
        for (q, role) in [(publicQueue, PortRole.public), (privateQueue, PortRole.private)] {
            q.deliver = { [weak self] item in self?.deliver(role, item) }
            q.onCoalesce = { [weak self] in self?.bump { $0.coalesced += 1 } }
        }
    }

    private func bump(_ f: (inout Stats) -> Void) { lock.lock(); f(&stats); lock.unlock() }
    public var snapshot: Stats { lock.lock(); defer { lock.unlock() }; return stats }

    private func deliver(_ role: PortRole, _ item: PortQueue.Item) {
        let rc: Int32
        switch item.payload {
        case .startup: rc = startupFn()
        case .message(let b): rc = sender(role, b)
        }
        if rc == 0 { bump { $0.sent += 1 } }
        else {
            bump { $0.errors += 1 }
            let what: String
            if case .message(let b) = item.payload { what = hexString(b) } else { what = "startup" }
            onError?("send to \(role.label) failed (\(rc)): \(what)")
        }
    }

    /// Key used for coalescing: the same LED CC, or the same pad's colour.
    static func coalesceKey(_ bytes: [UInt8]) -> String? {
        if bytes.count == 3, bytes[0] == 0xB0 { return "cc\(bytes[1])" }
        if bytes.count >= 12, bytes[0] == 0xF0, bytes[4] == 0x65, bytes[6] == 0x04 { return "pad\(bytes[7])" }
        return nil
    }

    public func enqueue(_ role: PortRole, _ bytes: [UInt8]) {
        let item = PortQueue.Item(payload: .message(bytes), key: PacedOutput.coalesceKey(bytes), seq: takeSeq())
        (role == .public ? publicQueue : privateQueue).enqueue(item)
    }

    /// The three startup SysEx as one queue item on Public.
    public func enqueueStartup() {
        publicQueue.enqueue(PortQueue.Item(payload: .startup, key: "startup", seq: takeSeq()))
    }

    private func takeSeq() -> Int { lock.lock(); defer { lock.unlock() }; nextSeq += 1; return nextSeq }

    /// Waits until both queues are empty (or the timeout passes). Returns true if drained.
    @discardableResult
    public func flush(timeout: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if publicQueue.isIdle && privateQueue.isIdle { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return publicQueue.isIdle && privateQueue.isIdle
    }

    public func clear() { publicQueue.clear(); privateQueue.clear() }
}

final class PortQueue {
    enum Payload { case message([UInt8]), startup }
    struct Item { var payload: Payload; var key: String?; var seq: Int }

    private let queue: DispatchQueue
    private var items: [Item] = []
    private var lastSendNs: UInt64 = 0
    private var lastGapMs = 0
    private var scheduled = false
    private var busy = false
    var gapFor: (Item) -> Int = { _ in 20 }
    var deliver: (Item) -> Void = { _ in }
    var onCoalesce: () -> Void = {}
    /// Asked before an item is delivered; false = try again in a few ms (the Private queue waits for Public here).
    var mayDeliver: (Item) -> Bool = { _ in true }

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInteractive) }

    var isIdle: Bool { queue.sync { items.isEmpty && !scheduled && !busy } }
    func clear() { queue.sync { items.removeAll() } }
    /// True while an item enqueued before `seq` is still waiting to go out.
    func hasQueued(before seq: Int) -> Bool { queue.sync { items.contains { $0.seq < seq } } }

    func enqueue(_ item: Item) {
        queue.async {
            if let k = item.key, let i = self.items.firstIndex(where: { $0.key == k }) {
                self.items[i] = item
                self.onCoalesce()
            } else {
                self.items.append(item)
            }
            self.schedule()
        }
    }

    private func schedule() {
        guard !scheduled, let first = items.first else { return }
        let gapNs = UInt64(max(gapFor(first), lastGapMs)) * 1_000_000
        let earliest = lastSendNs == 0 ? 0 : lastSendNs + gapNs
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = earliest > now ? earliest - now : 0
        scheduled = true
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { self.pump(earliest: earliest) }
    }

    private func pump(earliest: UInt64) {
        scheduled = false
        guard !items.isEmpty else { return }
        if DispatchTime.now().uptimeNanoseconds < earliest { schedule(); return }
        if !mayDeliver(items[0]) {
            scheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.pump(earliest: earliest) }
            return
        }
        let item = items.removeFirst()
        busy = true
        deliver(item)
        busy = false
        lastSendNs = DispatchTime.now().uptimeNanoseconds
        lastGapMs = gapFor(item)
        schedule()
    }
}
