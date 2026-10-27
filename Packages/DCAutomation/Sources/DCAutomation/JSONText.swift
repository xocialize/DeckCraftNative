// DCAutomation — serde_json's text forms of a `Value` that automation prints: `to_string` (DCEngine's
// `JSON.display`) and `to_string_pretty` (serde_json 1.0.154's `PrettyFormatter`, MIT OR Apache-2.0: two
// spaces, `": "`, `[]` and `{}` for empty containers), both over the value as a serde_json `Value` holds it
// (keys sorted, `f32` widened).
import DCCore
import DCEngine

extension JSON {
    /// `serde_json::to_string_pretty(&value)`.
    public var pretty: String {
        var out: [UInt8] = []
        out.reserveCapacity(1024)
        JSONPretty.write(canonical, indent: 0, into: &out)
        return String(decoding: out, as: UTF8.self)
    }
}

enum JSONPretty {
    static func write(_ v: JSON, indent: Int, into out: inout [UInt8]) {
        switch v {
        case .array(let items):
            if items.isEmpty {
                out.append(contentsOf: "[]".utf8)
                return
            }
            out.append(contentsOf: "[\n".utf8)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(contentsOf: ",\n".utf8) }
                pad(indent + 1, &out)
                write(item, indent: indent + 1, into: &out)
            }
            out.append(UInt8(ascii: "\n"))
            pad(indent, &out)
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            if o.isEmpty {
                out.append(contentsOf: "{}".utf8)
                return
            }
            out.append(contentsOf: "{\n".utf8)
            for (i, e) in o.entries.enumerated() {
                if i > 0 { out.append(contentsOf: ",\n".utf8) }
                pad(indent + 1, &out)
                out.append(contentsOf: JSONWriter().bytes(.string(e.key)))
                out.append(contentsOf: ": ".utf8)
                write(e.value, indent: indent + 1, into: &out)
            }
            out.append(UInt8(ascii: "\n"))
            pad(indent, &out)
            out.append(UInt8(ascii: "}"))
        default:
            out.append(contentsOf: JSONWriter().bytes(v))
        }
    }

    private static func pad(_ n: Int, _ out: inout [UInt8]) {
        for _ in 0 ..< n { out.append(contentsOf: [0x20, 0x20]) }
    }
}
