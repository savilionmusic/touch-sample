import Foundation
import AppKit
import Darwin
import BridgeCore

public struct RunningProcess {
    public var bundleID: String?
    public var name: String
    public init(bundleID: String?, name: String) { self.bundleID = bundleID; self.name = name }
}

/// Hard rule 4: only one app owns the Touch. Checked before any MIDI port is opened.
public enum OwnerCheck {
    /// PaperCut, Koala Link, Koala, Akai MPC / MPCHeadless.
    public static let bundleIDs = ["com.savilion.mpctouch.instrument", "com.savilion.koala-touch",
                                   "com.elf-audio.koala-mac", "com.akaipro.mpc"]
    public static let executableNames = ["MPC Touch", "KoalaTouch", "koala", "MPC", "MPCHeadless"]
    // mpc_touchd / mpc_watch (the touch driver) read the touch panel, not MIDI: expected, never a conflict.

    /// Pure: which of `running` would own the Touch? Returns one readable line per conflict.
    public static func conflicts(in running: [RunningProcess]) -> [String] {
        var out = [String]()
        for p in running {
            if let b = p.bundleID, bundleIDs.contains(b) {
                out.append("\(p.name) (\(b))")
            } else if executableNames.contains(p.name) {
                out.append("\(p.name) (process)")
            }
        }
        return Array(Set(out)).sorted()
    }

    public static func liveProcesses() -> [RunningProcess] {
        var result = [RunningProcess]()
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            result.append(RunningProcess(bundleID: app.bundleIdentifier,
                                         name: app.executableURL?.lastPathComponent ?? app.localizedName ?? ""))
        }
        // Plain processes (no bundle) too, by executable name.
        let count = proc_listallpids(nil, 0)
        if count > 0 {
            var pids = [pid_t](repeating: 0, count: Int(count) + 32)
            let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var buf = [CChar](repeating: 0, count: 4096)
            for pid in pids.prefix(Int(got)) where pid > 0 && pid != me {
                let n = proc_pidpath(pid, &buf, UInt32(buf.count))
                if n > 0 {
                    let path = String(cString: buf)
                    result.append(RunningProcess(bundleID: nil, name: (path as NSString).lastPathComponent))
                }
            }
        }
        return result
    }

    /// Conflicts among the processes running right now (empty = free to start).
    public static func check() -> [String] { conflicts(in: liveProcesses()) }
}

public enum LockError: Error, CustomStringConvertible {
    case held(String)
    case io(String)
    public var description: String {
        switch self {
        case .held(let p): return "another Touch Sample bridge or app is already running (lock \(p))"
        case .io(let m): return m
        }
    }
}

/// Exclusive flock on ~/Library/Application Support/Touch Sample/bridge.lock so two bridges (CLI + app) never
/// run together. Released when the object goes away or the process exits.
public final class BridgeLock {
    private var fd: Int32
    public let path: String

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Touch Sample/bridge.lock"
    }

    public static func acquire(path: String? = nil) throws -> BridgeLock {
        let p = path ?? defaultPath
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(p, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { throw LockError.io("cannot open lock file \(p): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw LockError.held(p)
        }
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return BridgeLock(fd: fd, path: p)
    }

    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }

    public func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }
    deinit { release() }
}
