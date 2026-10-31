import Foundation

/// Order-preserving JSON, so `touch-capture` can merge into hardware/touch-profile.json without reshuffling keys.
/// Serialises like Python's `json.dumps(indent=1)` (the existing file's style): one-space indent, multi-line
/// arrays, `"key": value`, no trailing newline.
public indirect enum JSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public enum ParseError: Error, CustomStringConvertible {
        case syntax(String, Int)
        public var description: String {
            switch self { case .syntax(let m, let at): return "JSON syntax error at byte \(at): \(m)" }
        }
    }

    // MARK: accessors

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first(where: { $0.0 == key })?.1
        }
        set {
            guard case .object(var pairs) = self else { return }
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { pairs[i].1 = v } else { pairs.remove(at: i) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
            self = .object(pairs)
        }
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectPairs: [(String, JSONValue)]? { if case .object(let p) = self { return p }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: parse

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.bytes.count { throw ParseError.syntax("trailing characters", p.i) }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        func fail(_ m: String) -> ParseError { .syntax(m, i) }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }
        mutating func literal(_ s: String) throws {
            for b in s.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw fail("bad literal") }
                i += 1
            }
        }
        mutating func number() throws -> JSONValue {
            let start = i
            var isDouble = false
            while i < bytes.count {
                let c = bytes[i]
                if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { i += 1 }
                else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { isDouble = true; i += 1 }
                else { break }
            }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8) else { throw fail("bad number") }
            if !isDouble, let n = Int(s) { return .int(n) }
            if let d = Double(s) { return .double(d) }
            throw fail("bad number")
        }
        mutating func string() throws -> String {
            i += 1  // opening quote
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard i + 4 < bytes.count,
                              let hex = String(bytes: bytes[(i + 1)...(i + 4)], encoding: .utf8),
                              var code = UInt32(hex, radix: 16) else { throw fail("bad \\u escape") }
                        i += 4
                        // surrogate pair
                        if code >= 0xD800, code < 0xDC00, i + 6 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"),
                           bytes[i + 2] == UInt8(ascii: "u"),
                           let h2 = String(bytes: bytes[(i + 3)...(i + 6)], encoding: .utf8),
                           let lo = UInt32(h2, radix: 16), lo >= 0xDC00, lo < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                            i += 6
                        }
                        out.append(contentsOf: Array(String(Character(UnicodeScalar(code) ?? "?")).utf8))
                    default: out.append(e)
                    }
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
            }
            throw fail("unterminated string")
        }
        mutating func array() throws -> JSONValue {
            i += 1
            var items = [JSONValue]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }
        mutating func object() throws -> JSONValue {
            i += 1
            var pairs = [(String, JSONValue)]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let k = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
                i += 1
                skipWS()
                pairs.append((k, try value()))
                skipWS()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw fail("expected , or }")
            }
        }
    }

    // MARK: serialise

    public func serialized(indent: Int = 1) -> String {
        var out = ""
        write(&out, level: 0, indent: indent)
        return out
    }

    private static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            case "\r": o += "\\r"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    private func write(_ out: inout String, level: Int, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case .string(let s): out += JSONValue.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, v) in a.enumerated() {
                out += String(repeating: " ", count: (level + 1) * indent)
                v.write(&out, level: level + 1, indent: indent)
                out += n + 1 < a.count ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: level * indent) + "]"
        case .object(let p):
            if p.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, kv) in p.enumerated() {
                out += String(repeating: " ", count: (level + 1) * indent) + JSONValue.quote(kv.0) + ": "
                kv.1.write(&out, level: level + 1, indent: indent)
                out += n + 1 < p.count ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: level * indent) + "}"
        }
    }
}
