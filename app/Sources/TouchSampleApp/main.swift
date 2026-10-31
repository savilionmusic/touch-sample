import AppKit
import WebKit
import TouchIO

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let root = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().deletingLastPathComponent().path
    let url = URL(string: "http://127.0.0.1:8765/touch")!
    var window: NSWindow!
    var displayWindow: NSWindow?
    var status: NSTextField!
    var chrome: NSButton!
    var bridge: BridgeRunner?
    var chromeProcess: Process?
    var generation = 0
    var starting = false
    var stopping = false
    var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit Touch Sample", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Touch Sample"; window.center(); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        status = NSTextField(labelWithString: "Stopped"); stack.addArrangedSubview(status)
        chrome = NSButton(checkboxWithTitle: "Use Chrome for the Touch screen", target: self, action: #selector(saveSetting)); chrome.state = UserDefaults.standard.bool(forKey: "chrome") ? .on : .off; stack.addArrangedSubview(chrome)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        buttons.addArrangedSubview(NSButton(title: "Start", target: self, action: #selector(start)))
        buttons.addArrangedSubview(NSButton(title: "Stop", target: self, action: #selector(stopButton)))
        buttons.addArrangedSubview(NSButton(title: "Sound Settings…", target: self, action: #selector(soundSettings)))
        stack.addArrangedSubview(buttons); window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let conflicts = OwnerCheck.check(); if !conflicts.isEmpty { status.stringValue = "Quit first: " + conflicts.joined(separator: ", ") }
    }
    @objc func saveSetting() { UserDefaults.standard.set(chrome.state == .on, forKey: "chrome") }
    @objc func soundSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
    func screen() -> NSScreen? { NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("MPC Touch") } ?? NSScreen.screens.first { $0 != NSScreen.screens.first && Int($0.frame.width) == 1280 && Int($0.frame.height) == 800 } }
    func fail(_ message: String) { starting = false; status.stringValue = message }
    @objc func start() {
        guard !starting && !stopping && bridge == nil else { return }
        let conflicts = OwnerCheck.check(); guard conflicts.isEmpty else { fail("Quit first: " + conflicts.joined(separator: ", ")); return }
        guard screen() != nil else { fail("MPC Touch display not found."); return }
        starting = true; generation += 1; let token = generation; status.stringValue = "Waiting for the MPC Sample…"
        // Check the port before opening Terminal. URL readiness is checked independently below.
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nc"); p.arguments = ["-z", "-w", "1", "127.0.0.1", "8765"]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { DispatchQueue.main.async { self.fail("Cannot check server: \(error)") }; return }
            if p.terminationStatus != 0 {
                let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-a", "Terminal", self.root + "/scripts/run-lab.command"]
                do { try open.run(); open.waitUntilExit(); if open.terminationStatus != 0 { throw NSError(domain: "Terminal", code: Int(open.terminationStatus)) } } catch { DispatchQueue.main.async { self.fail("Cannot open Terminal: \(error)") }; return }
            }
            self.waitForPage(token, deadline: Date().addingTimeInterval(180))
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
        runner.onStateChange = { [weak self] state in DispatchQueue.main.async { self?.status.stringValue = "Bridge: \(state.socketConnected ? "connected" : "offline") · Touch: \(state.touchConnected ? "connected" : "waiting")" } }
        do { try runner.start(); bridge = runner } catch { fail("Bridge: \(error)"); return }
        starting = false
        if chrome.state == .on {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { fail("Google Chrome not found. Stop, then choose WKWebView."); return }
            let process = Process(); process.executableURL = appURL.appendingPathComponent("Contents/MacOS/Google Chrome")
            process.arguments = ["--user-data-dir=\(NSTemporaryDirectory())touchsample-chrome-\(ProcessInfo.processInfo.processIdentifier)", "--app=\(url.absoluteString)", "--window-position=\(Int(screen.frame.minX)),\(Int(NSScreen.screens[0].frame.maxY - screen.frame.maxY))", "--window-size=\(Int(screen.frame.width)),\(Int(screen.frame.height))"]
            do { try process.run(); chromeProcess = process } catch { status.stringValue = "Chrome: \(error)" }

        } else {
            let config = WKWebViewConfiguration(); config.mediaTypesRequiringUserActionForPlayback = []
            let view = WKWebView(frame: screen.frame, configuration: config); view.load(URLRequest(url: url))
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen); w.contentView = view; w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1); w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]; w.hidesOnDeactivate = false; w.isReleasedWhenClosed = false; w.setFrame(screen.frame, display: true); w.makeKeyAndOrderFront(nil); displayWindow = w
        }
    }
    @objc func stopButton() { stop() }
    func stop() {
        guard !stopping else { return }; generation += 1; starting = false; stopping = true
        bridge?.stop(); bridge = nil; if let p = chromeProcess, p.isRunning { p.terminate() }; chromeProcess = nil; displayWindow?.close(); displayWindow = nil; status.stringValue = "Saving and stopping…"
        let root = self.root
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", "lab.py", "stop"]; p.currentDirectoryURL = URL(fileURLWithPath: root + "/vendor/virtual-mpc-sample"); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            var message = "Stopped"
            do { try p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { message = "Stop failed; check Terminal and save manually." } } catch { message = "Stop failed: \(error)" }
            DispatchQueue.main.async { self.stopping = false; self.status.stringValue = message; if self.terminationPending { self.terminationPending = false; NSApp.reply(toApplicationShouldTerminate: message == "Stopped") } }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { terminationPending = true; if !stopping { stop() }; return .terminateLater }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}
let app = NSApplication.shared
let delegate = App(); app.delegate = delegate; app.run()
