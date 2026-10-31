import Foundation

public enum ConfigError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let m) = self { return m }; return "config error" }
}

public enum PortRole: String, Comparable, Hashable {
    case `public` = "public"
    case `private` = "private"
    public static func < (a: PortRole, b: PortRole) -> Bool { a == .public && b == .private }
    public var label: String { self == .public ? "Public" : "Private" }
}

public enum ControlKind: String { case pad, cc, note }

/// One entry of hardware/touch-profile.json with a known raw ID.
public struct TouchControl {
    public let name: String
    public let kind: ControlKind
    public let channel: Int          // 0-based (the file is 1-based)
    public let id: Int
    public let port: PortRole
    public let led: Int?
}

public struct SpareButton {
    public let id: Int
    public let channel: Int          // 0-based
    public let port: PortRole
    public let led: Int?
    public let name: String?         // optional hand-edited name that matches a mappings.buttons entry
}

public struct PadColourConfig {
    public var enabled = false
    public var product = 0x37
    public var indexMap: [Int] = Array(0..<16)
}

public struct TouchProfile {
    public var controls: [TouchControl] = []
    public var spares: [SpareButton] = []
    public var bankLedPorts: [PortRole] = [.public]
    public var padColour = PadColourConfig()

    public init(json: [String: Any]) throws {
        guard let ctl = json["controls"] as? [String: Any] else { throw ConfigError.message("profile: no \"controls\" object") }
        for name in ctl.keys.sorted() {
            guard let c = ctl[name] as? [String: Any] else { continue }
            if (c["absent"] as? Bool) == true { continue }
            guard let kindS = c["kind"] as? String, let kind = ControlKind(rawValue: kindS),
                  let id = c["id"] as? Int, (0...127).contains(id) else { continue }   // id null -> not found yet
            let ch = ((c["channel"] as? Int) ?? 1) - 1
            let port = PortRole(rawValue: (c["port"] as? String) ?? "public") ?? .public
            let led = c["led"] as? Int
            controls.append(TouchControl(name: name, kind: kind, channel: max(0, min(15, ch)), id: id, port: port, led: led))
        }
        if let arr = json["spares"] as? [Any] {
            for s in arr {
                if let id = s as? Int {
                    spares.append(SpareButton(id: id, channel: 0, port: .public, led: nil, name: nil))
                } else if let d = s as? [String: Any], let id = d["id"] as? Int {
                    spares.append(SpareButton(
                        id: id, channel: max(0, ((d["channel"] as? Int) ?? 1) - 1),
                        port: PortRole(rawValue: (d["port"] as? String) ?? "public") ?? .public,
                        led: d["led"] as? Int, name: d["name"] as? String))
                }
            }
        }
        if let ports = json["bankLedPorts"] as? [String] {
            let p = ports.compactMap { PortRole(rawValue: $0) }
            if !p.isEmpty { bankLedPorts = p }
        }
        if let pc = json["padColour"] as? [String: Any] {
            padColour.enabled = (pc["enabled"] as? Bool) ?? false
            padColour.product = (pc["product"] as? Int) ?? 0x37
            if let m = pc["indexMap"] as? [Int], !m.isEmpty { padColour.indexMap = m }
        }
    }
}

/// One Sample control from the emulator's panel/controls.json.
public struct SampleControl {
    public let name: String
    public let id: Int
    public let press: String?
    public let release: String?
    public let set: String?
    public let turn: String?
    public let led: Int?
}

public struct ControlsTable {
    public private(set) var controls: [String: SampleControl] = [:]
    public private(set) var bankLeds: [Int: String] = [:]

    public init(json: [String: Any]) throws {
        guard let c = json["controls"] as? [String: Any] else { throw ConfigError.message("controls.json: no \"controls\"") }
        for (name, v) in c {
            guard let d = v as? [String: Any], let id = d["id"] as? Int else { continue }
            controls[name] = SampleControl(name: name, id: id, press: d["press"] as? String,
                                           release: d["release"] as? String, set: d["set"] as? String,
                                           turn: d["turn"] as? String, led: d["led"] as? Int)
        }
        if let b = json["bank_leds"] as? [String: String] {
            for (k, v) in b { if let i = Int(k) { bankLeds[i] = v } }
        }
    }

    /// Expands a template like "90 {id} 7F" / "99 {id} {value}" into bytes.
    public static func frame(_ template: String, id: Int, value: Int = 0) -> [UInt8]? {
        var out = [UInt8]()
        for tok in template.split(separator: " ") {
            switch tok {
            case "{id}": out.append(UInt8(truncatingIfNeeded: id & 0x7F))
            case "{value}": out.append(UInt8(truncatingIfNeeded: value & 0x7F))
            default:
                guard let b = UInt8(tok, radix: 16) else { return nil }
                out.append(b)
            }
        }
        return out.isEmpty ? nil : out
    }
    public func press(_ n: String) -> [UInt8]? {
        guard let c = controls[n], let t = c.press else { return nil }
        return ControlsTable.frame(t, id: c.id, value: 127)
    }
    public func release(_ n: String) -> [UInt8]? {
        guard let c = controls[n], let t = c.release else { return nil }
        return ControlsTable.frame(t, id: c.id, value: 0)
    }
    public func set(_ n: String, value: Int) -> [UInt8]? {
        guard let c = controls[n], let t = c.set else { return nil }
        return ControlsTable.frame(t, id: c.id, value: value)
    }
    public func turn(_ n: String, value: Int) -> [UInt8]? {
        guard let c = controls[n], let t = c.turn else { return nil }
        return ControlsTable.frame(t, id: c.id, value: value)
    }
}

/// An entry of mappings/default.json (a button, knob or wheel control), possibly with a Shift variant.
public final class MappingEntry {
    public var send: String?
    public var macro: [String]?
    public var bridge: String?
    public var bank: Int?
    public var shift: MappingEntry?

    init(_ d: [String: Any]) {
        send = d["send"] as? String
        macro = d["macro"] as? [String]
        bridge = d["bridge"] as? String
        bank = d["bank"] as? Int
        if let s = d["shift"] as? [String: Any] { shift = MappingEntry(s) }
    }
    /// Every Sample control name this entry (and its shift variant) refers to.
    var referencedControls: [String] {
        var r = [String]()
        if let s = send { r.append(s) }
        if let m = macro { r += m }
        if let sh = shift { r += sh.referencedControls }
        return r
    }
}

public struct Mapping {
    public var padsPassThrough = true
    public var knobs: [String: MappingEntry] = [:]
    public var wheel: [String: MappingEntry] = [:]
    public var buttons: [String: MappingEntry] = [:]
    public var spareOrder: [String] = []
    public var modeLeds: [String: (lit: String, dim: String)] = [:]
    public var qlinkBankLeds: [String: Int] = [:]
    public var litAtoD = 3
    public var dimEtoH = 1

    public init(json: [String: Any]) throws {
        if let p = json["pads"] as? [String: Any] { padsPassThrough = (p["passThrough"] as? Bool) ?? true }
        func entries(_ key: String) -> [String: MappingEntry] {
            var r = [String: MappingEntry]()
            for (k, v) in (json[key] as? [String: Any]) ?? [:] where !k.hasPrefix("_") {
                if let d = v as? [String: Any] { r[k] = MappingEntry(d) }
            }
            return r
        }
        knobs = entries("knobs"); wheel = entries("wheel"); buttons = entries("buttons")
        if let sp = json["spares"] as? [String: Any], let o = sp["order"] as? [String] { spareOrder = o }
        if let l = json["lights"] as? [String: Any] {
            if let m = l["modeLeds"] as? [String: Any] {
                for (k, v) in m {
                    if let d = v as? [String: Any], let lit = d["lit"] as? String, let dim = d["dim"] as? String {
                        modeLeds[k] = (lit, dim)
                    }
                }
            }
            if let q = l["qlinkBankLeds"] as? [String: Int] { qlinkBankLeds = q }
            if let b = l["bankLeds"] as? [String: Any] {
                litAtoD = (b["litAtoD"] as? Int) ?? 3
                dimEtoH = (b["dimEtoH"] as? Int) ?? 1
            }
        }
    }
}

public struct BridgeConfig {
    public let profile: TouchProfile
    public let mapping: Mapping
    public let controls: ControlsTable
    /// Non-fatal problems (a mapping that names a Sample control controls.json does not have, ...).
    public let warnings: [String]

    public init(profileJSON: [String: Any], mappingJSON: [String: Any], controlsJSON: [String: Any]) throws {
        let prof = try TouchProfile(json: profileJSON)
        let map = try Mapping(json: mappingJSON)
        let ctl = try ControlsTable(json: controlsJSON)
        var w = [String]()
        func check(_ owner: String, _ e: MappingEntry) {
            for c in e.referencedControls where ctl.controls[c] == nil {
                w.append("mapping \(owner): Sample control \"\(c)\" is not in controls.json (entry ignored)")
            }
        }
        for (n, e) in map.knobs { check(n, e) }
        for (n, e) in map.wheel { check(n, e) }
        for (n, e) in map.buttons { check(n, e) }
        for c in map.spareOrder where ctl.controls[c] == nil {
            w.append("mapping spares.order: Sample control \"\(c)\" is not in controls.json")
        }
        profile = prof
        mapping = map
        controls = ctl
        warnings = w.sorted()
    }

    public static func load(_ paths: RepoPaths) throws -> BridgeConfig {
        func dict(_ path: String) throws -> [String: Any] {
            guard let data = FileManager.default.contents(atPath: path) else { throw ConfigError.message("cannot read \(path)") }
            guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigError.message("\(path): not a JSON object")
            }
            return d
        }
        return try BridgeConfig(profileJSON: dict(paths.profile), mappingJSON: dict(paths.mapping),
                                controlsJSON: dict(paths.controls))
    }
}

/// Where the repo's profile / mapping / controls files are. Flags win, then TOUCHSAMPLE_ROOT, then the
/// working directory and the executable's location (walking up until `hardware/touch-profile.json` exists).
public struct RepoPaths {
    public var root: String?
    public var profile: String
    public var mapping: String
    public var controls: String
    public var capturesDir: String

    public static func resolve(root: String? = nil, profile: String? = nil, mapping: String? = nil,
                               controls: String? = nil, executablePath: String? = nil) throws -> RepoPaths {
        let fm = FileManager.default
        var foundRoot: String?
        func isRoot(_ p: String) -> Bool { fm.fileExists(atPath: p + "/hardware/touch-profile.json") }
        func walkUp(_ start: String) -> String? {
            var url = URL(fileURLWithPath: start).standardizedFileURL
            for _ in 0..<12 {
                if isRoot(url.path) { return url.path }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
            return nil
        }
        if let r = root ?? ProcessInfo.processInfo.environment["TOUCHSAMPLE_ROOT"], !r.isEmpty {
            let p = (r as NSString).expandingTildeInPath
            foundRoot = isRoot(p) ? p : nil
        }
        if foundRoot == nil { foundRoot = walkUp(fm.currentDirectoryPath) }
        if foundRoot == nil, let e = executablePath ?? CommandLine.arguments.first {
            foundRoot = walkUp((e as NSString).deletingLastPathComponent)
        }
        func pick(_ explicit: String?, _ rel: String, _ what: String) throws -> String {
            if let e = explicit { return (e as NSString).expandingTildeInPath }
            guard let r = foundRoot else {
                throw ConfigError.message("cannot find the repo (no hardware/touch-profile.json above here); set TOUCHSAMPLE_ROOT or pass --\(what)")
            }
            return r + "/" + rel
        }
        return RepoPaths(
            root: foundRoot,
            profile: try pick(profile, "hardware/touch-profile.json", "profile"),
            mapping: try pick(mapping, "mappings/default.json", "mapping"),
            controls: try pick(controls, "vendor/virtual-mpc-sample/panel/controls.json", "controls"),
            capturesDir: (foundRoot ?? fm.currentDirectoryPath) + "/captures/raw")
    }
}
