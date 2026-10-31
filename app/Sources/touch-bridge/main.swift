import Foundation
import BridgeCore
import TouchIO

let usage = """
touch-bridge: plays the emulated MPC Sample from the MPC Touch.

usage:
  touch-bridge [--server ws://127.0.0.1:8765/bridge] [--profile FILE] [--mapping FILE] [--controls FILE]
               [--root DIR] [--verbose] [--no-lights]
  touch-bridge --self-test          scripted check of the bridge logic (no MIDI, no network)
  touch-bridge --learn [CONTROL]    input only: print the raw message of each Touch press
                                    (with a name: print the next press as a profile snippet and exit)
  touch-bridge --help

options:
  --server URL    panel server /bridge WebSocket (default ws://127.0.0.1:8765/bridge; reconnects every 1 s)
  --profile FILE  hardware/touch-profile.json   (default: the repo's, found via TOUCHSAMPLE_ROOT or the working directory)
  --mapping FILE  mappings/default.json
  --controls FILE vendor/virtual-mpc-sample/panel/controls.json
  --root DIR      repo root (same as the TOUCHSAMPLE_ROOT environment variable)
  --verbose       log every message and print latency stats (Touch packet -> WebSocket send, p50/p95) every 30 s
  --no-lights     input only: no startup SysEx, no LEDs, no pad colours; the output port is never opened

Quit PaperCut and Koala first: the bridge refuses to start (exit 2) while another app owns the Touch.
Run it from Terminal.app.
"""

var options = BridgeOptions()
var selfTest = false
var learn = false
var learnName: String?

var args = Array(CommandLine.arguments.dropFirst())
func value(for flag: String) -> String {
    guard !args.isEmpty else { fputs("touch-bridge: \(flag) needs a value\n", stderr); exit(64) }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--help", "-h": print(usage); exit(0)
    case "--self-test": selfTest = true
    case "--verbose", "-v": options.verbose = true
    case "--no-lights": options.lights = false
    case "--server": options.serverURL = value(for: a)
    case "--profile": options.profilePath = value(for: a)
    case "--mapping": options.mappingPath = value(for: a)
    case "--controls": options.controlsPath = value(for: a)
    case "--root": options.rootPath = value(for: a)
    case "--learn":
        learn = true
        if let n = args.first, !n.hasPrefix("-") { learnName = args.removeFirst() }
    default:
        fputs("touch-bridge: unknown option \(a)\n\n\(usage)\n", stderr)
        exit(64)
    }
}

if selfTest {
    exit(runSelfTest(options))
}

var signalSources: [DispatchSourceSignal] = []
func onSignals(_ handler: @escaping () -> Void) {
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

if learn {
    let l = TouchLearn(profilePath: options.profilePath, rootPath: options.rootPath, name: learnName)
    do { try l.start() } catch let e as BridgeError {
        fputs("touch-bridge: \(e)\n", stderr); exit(e.exitCode)
    } catch { fputs("touch-bridge: \(error)\n", stderr); exit(1) }
    l.onDone = { DispatchQueue.main.async { l.stop(); exit(0) } }
    onSignals { l.stop(); exit(0) }
    RunLoop.main.run()
}

let runner = BridgeRunner(options: options)
do { try runner.start() } catch let e as BridgeError {
    fputs("touch-bridge: \(e)\n", stderr)
    exit(e.exitCode)
} catch {
    fputs("touch-bridge: \(error)\n", stderr)
    exit(1)
}
print("touch-bridge running (\(options.serverURL)); Ctrl-C to stop")
fflush(stdout)
onSignals {
    print("stopping: releasing held controls, lights off")
    runner.stop()
    exit(0)
}
RunLoop.main.run()
