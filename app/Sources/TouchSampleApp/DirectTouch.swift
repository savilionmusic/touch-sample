import AppKit
import WebKit

/// Receiver for the installed mpc_touchd's existing mouseless protocol. Adapted
/// from PaperCut-bf2 TouchScreen.swift / DirectTouches (2026-10-31). No USB reader,
/// driver changes, global event posting, or cursor movement.
final class DirectTouchReceiver {
    struct Packet {
        let type: Int32
        let x: Double
        let y: Double
        init?(_ data: Data) {
            guard data.count == 24 else { return nil }
            type = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
            x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
            y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Double.self) }
            guard (1...3).contains(type), x.isFinite, y.isFinite else { return nil }
        }
        func point(primaryTop: Double, frame: NSRect) -> NSPoint {
            NSPoint(x: x - frame.minX, y: frame.maxY - (primaryTop - y))
        }
    }
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    weak var webView: WKWebView?
    var log: (String) -> Void = { _ in }
    private var touches = 0

    func start(_ view: WKWebView) -> Bool {
        webView = view
        guard port == nil else { return true }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // The installed driver knows this protocol name. Ownership is exclusive;
        // BridgeRunner's owner check/lock has already run before this is created.
        guard let port = CFMessagePortCreateLocal(nil, "com.savilion.papercut.touch" as CFString, { _, _, data, info in
            guard let data, let info else { return nil }
            Unmanaged<DirectTouchReceiver>.fromOpaque(info).takeUnretainedValue().receive(data as Data)
            return nil
        }, &context, nil), let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return false }
        self.port = port; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        log("Direct touch receiver listening (installed driver protocol)")
        return true
    }
    func stop() {
        webView?.evaluateJavaScript("window.touchSampleDirect?.(3, 0, 0)", completionHandler: nil)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        port = nil; source = nil; webView = nil
    }
    private func receive(_ data: Data) {
        guard let packet = Packet(data), let webView, let window = webView.window,
              window.isVisible, let primary = NSScreen.screens.first else { return }
        let point = packet.point(primaryTop: primary.frame.maxY, frame: window.frame)
        if packet.type == 1 {
            touches += 1
            log("Direct touch \(touches) at \(Int(point.x)),\(Int(point.y))")
        }
        // Coordinates are DOM viewport points (top-left); the page retains the
        // originally pressed target through drags and releases, including MUTE.
        webView.evaluateJavaScript("window.touchSampleDirect?.(\(packet.type), \(point.x), \(point.y))") { [weak self] _, error in
            if let error { self?.log("Direct touch dispatch failed: \(error.localizedDescription)") }
        }
    }
    static func selfTest() {
        func data(_ type: Int32, _ x: Double, _ y: Double) -> Data {
            var d = Data(); var t = type; var clicks: Int32 = 1; var x = x; var y = y
            for part in [withUnsafeBytes(of: &t) { Data($0) }, withUnsafeBytes(of: &clicks) { Data($0) }, withUnsafeBytes(of: &x) { Data($0) }, withUnsafeBytes(of: &y) { Data($0) }] { d.append(part) }
            return d
        }
        let frame = NSRect(x: 2287, y: -1880, width: 1280, height: 800)
        precondition(Packet(Data(repeating: 0, count: 23)) == nil)
        precondition(Packet(data(4, 0, 0)) == nil)
        precondition(Packet(data(1, .nan, 0)) == nil)
        for type: Int32 in [1, 2, 3] {
            precondition(Packet(data(type, 2287, 2160))!.point(primaryTop: 1080, frame: frame) == .zero)
            precondition(Packet(data(type, 3567, 2960))!.point(primaryTop: 1080, frame: frame) == NSPoint(x: 1280, y: 800))
        }
        print("Direct touch packet and multi-display coordinate checks passed (no hardware or message port opened)")
    }
}
