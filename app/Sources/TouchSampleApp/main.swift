import AppKit
import WebKit
import TouchIO

// The same key-window behavior as PaperCut's InstrumentWindow. Taps must work
// immediately on a borderless display, including when the Mac control window is active.
final class TouchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class TouchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    // Emulator folder: next to dist/ when run from the repo, else the build-time path in Info.plist (TouchSampleRoot), else the default home.
    let resolvedRoot = App.resolveRoot(bundlePath: Bundle.main.bundlePath, plistRoot: Bundle.main.object(forInfoDictionaryKey: "TouchSampleRoot") as? String, home: NSHomeDirectory())
    var root: String { resolvedRoot.path }
    let url = URL(string: "http://127.0.0.1:8765/touch?audio=native")!
    var window: NSWindow!
    var displayWindow: NSWindow?
    var status: NSTextField!
    var screenStatus: NSTextField!
    var webView: WKWebView?
    let directTouch = DirectTouchReceiver()
    var screenObserver: NSObjectProtocol?
    var chrome: NSButton!
    var bridge: BridgeRunner?
    var nativeAudio: NativeAudio?
    var chromeProcess: Process?
    var terminalLauncher: Process?
    var generation = 0
    var starting = false
    var stopping = false
    var terminationPending = false

    static let rootMarker = "/vendor/virtual-mpc-sample/lab.py"
    static func resolveRoot(bundlePath: String, plistRoot: String?, home: String) -> (path: String, found: Bool) {
        let bundleRelative = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().deletingLastPathComponent().path
        let fallback = home + "/Documents/Codex/TouchSample"
        for candidate in [bundleRelative, plistRoot, fallback].compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate + rootMarker) { return (candidate, true) }
        return (fallback, false)
    }
    var rootMissingMessage: String { "Emulator folder not found. Expected " + (root as NSString).abbreviatingWithTildeInPath + App.rootMarker }
    static func selfTest() {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "touchsample-root-test-\(ProcessInfo.processInfo.processIdentifier)"
        defer { try? fm.removeItem(atPath: base) }
        func make(_ name: String) -> String {
            let dir = base + "/" + name
            try! fm.createDirectory(atPath: dir + "/vendor/virtual-mpc-sample", withIntermediateDirectories: true)
            fm.createFile(atPath: dir + rootMarker, contents: Data())
            return dir
        }
        let repo = make("repo"), plist = make("plist"), home = base + "/home"
        let installed = "/Applications/Touch Sample.app"
        let fallback = make("home/Documents/Codex/TouchSample")
        precondition(App.resolveRoot(bundlePath: repo + "/dist/Touch Sample.app", plistRoot: plist, home: home) == (repo, true))
        precondition(App.resolveRoot(bundlePath: installed, plistRoot: plist, home: home) == (plist, true))
        precondition(App.resolveRoot(bundlePath: installed, plistRoot: base + "/gone", home: home) == (fallback, true))
        precondition(App.resolveRoot(bundlePath: installed, plistRoot: nil, home: home) == (fallback, true))
        try! fm.removeItem(atPath: fallback + rootMarker)
        precondition(App.resolveRoot(bundlePath: installed, plistRoot: nil, home: home) == (fallback, false))
        print("Emulator folder resolution checks passed (bundle path, then Info.plist, then home default, else not found)")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit Touch Sample", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Touch Sample"; window.center(); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        status = NSTextField(labelWithString: "Stopped"); stack.addArrangedSubview(status)
        screenStatus = NSTextField(wrappingLabelWithString: "Touch screen: stopped"); screenStatus.preferredMaxLayoutWidth = 600; stack.addArrangedSubview(screenStatus)
        chrome = NSButton(checkboxWithTitle: "Use Chrome for the Touch screen", target: self, action: #selector(saveSetting)); chrome.state = UserDefaults.standard.bool(forKey: "chrome") ? .on : .off; stack.addArrangedSubview(chrome)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        buttons.addArrangedSubview(NSButton(title: "Start", target: self, action: #selector(start)))
        buttons.addArrangedSubview(NSButton(title: "Show Touch", target: self, action: #selector(showTouch)))
        buttons.addArrangedSubview(NSButton(title: "Stop", target: self, action: #selector(stopButton)))
        buttons.addArrangedSubview(NSButton(title: "Sound Settings…", target: self, action: #selector(soundSettings)))
        stack.addArrangedSubview(buttons); window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.positionTouch() }
        note("Displays: " + NSScreen.screens.map { "\($0.localizedName): \($0.frame)" }.joined(separator: "; "))
        let conflicts = OwnerCheck.check()
        if !resolvedRoot.found { fail(rootMissingMessage) }
        else if !conflicts.isEmpty { status.stringValue = "Quit first: " + conflicts.joined(separator: ", ") }
        else { DispatchQueue.main.async { self.start() } }
    }
    @objc func saveSetting() { UserDefaults.standard.set(chrome.state == .on, forKey: "chrome") }
    @objc func soundSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
    func screen() -> NSScreen? { NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("MPC Touch") } ?? NSScreen.screens.first { $0 != NSScreen.screens.first && Int($0.frame.width) == 1280 && Int($0.frame.height) == 800 } }
    func note(_ message: String) {
        guard resolvedRoot.found else { return }  // Don't create out/ in a folder that isn't the emulator's.
        let folder = URL(fileURLWithPath: root).appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: file) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("[\(Date())] \(message)\n".utf8)) }
    }
    func fail(_ message: String) { starting = false; status.stringValue = message; note(message) }
    func positionTouch() {
        guard let w = displayWindow else { return }
        guard let screen = screen() else { w.orderOut(nil); screenStatus.stringValue = "Touch display disconnected"; return }
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        screenStatus.stringValue = "Touch display: \(screen.localizedName) · \(Int(screen.frame.width))×\(Int(screen.frame.height))"
        note("Touch window: \(w.frame), visible=\(w.isVisible), screen=\(w.screen?.localizedName ?? "unknown")")
    }
    @objc func showTouch() {
        if displayWindow == nil { makeTouchWindow() }
        positionTouch(); displayWindow?.makeKeyAndOrderFront(nil)
    }
    func makeTouchWindow() {
        guard displayWindow == nil, let screen = screen() else { return }
        // Placement/level match PaperCut RuntimeDevices.swift and TouchScreen.swift.
        let w = TouchWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.title = "Touch Sample · Controller"
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        w.hidesOnDeactivate = false; w.isReleasedWhenClosed = false; w.backgroundColor = .black
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let label = NSTextField(wrappingLabelWithString: "TOUCH SAMPLE\nStarting controller and Sample…")
        label.textColor = .white; label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.frame = NSRect(x: 40, y: screen.frame.height / 2, width: screen.frame.width - 80, height: 100)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]; container.addSubview(label)
        w.contentView = container; displayWindow = w; positionTouch(); w.makeKeyAndOrderFront(nil)
    }
    func loadTouchPage() {
        makeTouchWindow()
        guard let w = displayWindow else { fail("Touch display unavailable"); return }
        let config = WKWebViewConfiguration(); config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "audioDiagnostics")
        let view = TouchWebView(frame: NSRect(origin: .zero, size: w.frame.size), configuration: config)
        view.autoresizingMask = [.width, .height]; view.navigationDelegate = self
        w.contentView = view; webView = view
        directTouch.log = { [weak self] in self?.note($0) }
        if !directTouch.start(view) { note("Direct touch port unavailable: another receiver is running") }
        view.load(URLRequest(url: url))
        positionTouch(); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(view)
        screenStatus.stringValue = "Touch screen: loading Sample panel…"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        screenStatus.stringValue = "Touch screen: Sample panel loaded · \(webView.bounds.size)"
        note(screenStatus.stringValue)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageFailed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { pageFailed(NSError(domain: "Touch Sample page process stopped", code: 1)) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "audioDiagnostics", let data = try? JSONSerialization.data(withJSONObject: message.body, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
        note("AUDIO " + text)
    }
    func pageFailed(_ error: Error) { screenStatus.stringValue = "Touch screen failed: \(error.localizedDescription)"; note(screenStatus.stringValue) }
    @objc func start() {
        guard !starting && !stopping && bridge == nil else { return }
        guard resolvedRoot.found else { fail(rootMissingMessage); return }
        let conflicts = OwnerCheck.check(); guard conflicts.isEmpty else { fail("Quit first: " + conflicts.joined(separator: ", ")); return }
        guard screen() != nil else { fail("MPC Touch display not found."); return }
        if chrome.state == .off { makeTouchWindow() }
        starting = true; generation += 1; let token = generation; status.stringValue = "Waiting for the MPC Sample…"
        // Check both the panel and emulator before opening Terminal.
        DispatchQueue.global().async {
            func portOpen(_ port: String) throws -> Bool {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                p.arguments = ["-z", "-w", "1", "127.0.0.1", port]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit(); return p.terminationStatus == 0
            }
            let running: Bool
            do { running = try portOpen("8765") && portOpen("5554") }
            catch { DispatchQueue.main.async { self.fail("Cannot check Sample: \(error)") }; return }
            // A surviving panel server is not proof that QEMU is running.
            DispatchQueue.main.async {
                guard token == self.generation, self.starting else { return }
                if !running {
                    // LaunchServices can stall. Never block the UI or panel-readiness check on it.
                    let launcher = Process(); launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    launcher.arguments = ["-a", "Terminal", self.root + "/scripts/run-lab.command"]
                    launcher.terminationHandler = { process in
                        if process.terminationStatus != 0 { DispatchQueue.main.async {
                            if token == self.generation, self.starting { self.fail("Terminal launch failed. See scripts/run-lab.command.") }
                        } }
                    }
                    self.terminalLauncher = launcher
                    DispatchQueue.global().async {
                        do { try launcher.run() }
                        catch { DispatchQueue.main.async { if token == self.generation { self.fail("Cannot open Terminal: \(error.localizedDescription)") } } }
                    }
                }
                self.waitForPage(token, deadline: Date().addingTimeInterval(180))
            }
        }
    }
    func waitForPage(_ token: Int, deadline: Date) {
        var request = URLRequest(url: url); request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                guard token == self.generation, self.starting else { return }
                if let response = response as? HTTPURLResponse, response.statusCode == 200 { self.startBridge(); return }
                guard Date() < deadline else { self.fail("Timed out waiting for /touch. Check Terminal."); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.waitForPage(token, deadline: deadline) }
            }
        }.resume()
    }
    func startBridge() {
        guard let screen = screen() else { fail("MPC Touch display not found."); return }
        var options = BridgeOptions(); options.rootPath = root
        let runner = BridgeRunner(options: options)
        runner.log = { [weak self] message in
            DispatchQueue.main.async {
                self?.note(message)
                if message.contains("failed") { self?.screenStatus.stringValue = "Controller output error: " + message }
            }
        }
        runner.onStateChange = { [weak self] state in DispatchQueue.main.async { self?.status.stringValue = "Bridge: \(state.socketConnected ? "connected" : "offline") · Touch: \(state.touchConnected ? "connected" : "waiting")" } }
        do { try runner.start(); bridge = runner } catch { fail("Bridge: \(error)"); return }
        if chrome.state == .off {
            let audio = NativeAudio()
            audio.log = { [weak self] text in DispatchQueue.main.async { self?.note(text) } }
            do { try audio.start(); nativeAudio = audio } catch { fail("Native audio failed: \(error.localizedDescription)"); return }
        }
        starting = false
        if chrome.state == .on {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { fail("Google Chrome not found. Stop, then choose WKWebView."); return }
            let process = Process(); process.executableURL = appURL.appendingPathComponent("Contents/MacOS/Google Chrome")
            process.arguments = ["--user-data-dir=\(NSTemporaryDirectory())touchsample-chrome-\(ProcessInfo.processInfo.processIdentifier)", "--app=http://127.0.0.1:8765/touch", "--window-position=\(Int(screen.frame.minX)),\(Int(NSScreen.screens[0].frame.maxY - screen.frame.maxY))", "--window-size=\(Int(screen.frame.width)),\(Int(screen.frame.height))"]
            // The saved "Use Chrome" choice skips WKWebView and native audio; say so instead of staying silent.
            do { try process.run(); chromeProcess = process; screenStatus.stringValue = "Touch screen: Chrome window (WKWebView and native audio are off; untick \"Use Chrome\", Stop, then Start)"; note(screenStatus.stringValue) } catch { fail("Chrome: \(error)") }
        } else {
            loadTouchPage()
        }
    }
    @objc func stopButton() { stop() }
    func stop() {
        guard !stopping else { return }; generation += 1; starting = false; stopping = true
        if let launcher = terminalLauncher, launcher.isRunning { launcher.terminate() }; terminalLauncher = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "audioDiagnostics")
        directTouch.stop()
        nativeAudio?.stop(); nativeAudio = nil
        bridge?.stop(); bridge = nil; if let p = chromeProcess, p.isRunning { p.terminate() }; chromeProcess = nil; displayWindow?.close(); displayWindow = nil; webView = nil; screenStatus.stringValue = "Touch screen: stopped"; status.stringValue = "Saving and stopping…"
        let root = self.root
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", "lab.py", "stop"]; p.currentDirectoryURL = URL(fileURLWithPath: root + "/vendor/virtual-mpc-sample"); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            var message = "Stopped"
            do {
                let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                check.arguments = ["-z", "-w", "1", "127.0.0.1", "5554"]
                check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
                try check.run(); check.waitUntilExit()
                if check.terminationStatus == 0 {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus != 0 { message = "Stop failed; check Terminal and save manually." }
                }
            } catch { message = "Stop failed: \(error)" }
            DispatchQueue.main.async { self.stopping = false; self.status.stringValue = message; if self.terminationPending { self.terminationPending = false; NSApp.reply(toApplicationShouldTerminate: message == "Stopped") } }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { terminationPending = true; if !stopping { stop() }; return .terminateLater }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}
if CommandLine.arguments.contains("--self-test") { DirectTouchReceiver.selfTest(); NativeAudio.selfTest(); App.selfTest(); exit(0) }
let app = NSApplication.shared
let delegate = App(); app.delegate = delegate; app.run()
