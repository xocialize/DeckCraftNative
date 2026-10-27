// DCEngine — serde_json's `Value` as the engine uses it, on DCCore's `JSON`.
//
// deckcraft's commands take and answer `serde_json::Value`s. Its maps are `BTreeMap`s (no
// `preserve_order`), so every answer the CLI prints has its keys sorted, and `to_value` turns an `f32` into
// an `f64` and a non-finite float into `null`. `canonical` applies those rules to a `JSON` the engine
// built, and `JSON.display` is `format!("{}", value)`. Port of serde_json 1.0.154's `Value` accessors
// (MIT OR Apache-2.0); deckcraft (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore

// MARK: - Literals, so `json!({...})` reads as a Swift literal

extension JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
}

extension JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON: ExpressibleByDictionaryLiteral {
    /// A map literal: a later duplicate key replaces the earlier value, as `BTreeMap::insert` does.
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o = JSONObject()
        for (k, v) in elements { o.set(k, v) }
        self = .object(o)
    }
}

// MARK: - Building values

extension JSON {
    /// `json!(v)` for any serialisable value (`serde_json::to_value`).
    public static func of(_ v: some JSONEncodable) -> JSON { v.toJSON() }

    /// `json!(x)` for an `f64`: `null` when it isn't finite, as `Value::from(f64)` gives.
    public static func num(_ v: Double) -> JSON { v.isFinite ? .double(v) : .null }

    /// `json!(n)` for an integer.
    public static func int<T: BinaryInteger>(_ v: T) -> JSON { .integer(v) }

    /// `json!(s)` for a string.
    public static func str(_ s: some StringProtocol) -> JSON { .string(String(s)) }

    /// `json!(opt)`: the value, or `null`.
    public static func opt(_ v: (some JSONEncodable)?) -> JSON { v?.toJSON() ?? .null }

    /// An empty object (`json!({})`).
    public static var emptyObject: JSON { .object(JSONObject()) }

    /// Insert or replace `key` (`value[key] = v`, `Map::insert`). A non-object becomes an object first,
    /// as serde_json's `IndexMut` does for `null` (and panics for anything else; here it is replaced).
    public mutating func set(_ key: String, _ v: JSON) {
        var o: JSONObject
        if case .object(let existing) = self { o = existing } else { o = JSONObject() }
        o.set(key, v)
        self = .object(o)
    }
}

// MARK: - serde_json's accessors

extension JSON {
    /// `Value::get(key)`: an object's member, nil for anything else.
    public func get(_ key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// `Value::get(index)`: an array's element, nil for anything else.
    public func at(_ i: Int) -> JSON? {
        if case .array(let a) = self, i >= 0, i < a.count { return a[i] }
        return nil
    }

    /// `as_f64`: any number.
    public var asF64: Double? {
        switch self {
        case .uint(let v): Double(v)
        case .int(let v): Double(v)
        case .double(let v): v
        case .float(let v): Double(v)
        default: nil
        }
    }

    /// `as_u64`: a non-negative integer (not a float, even a whole one).
    public var asU64: UInt64? {
        switch self {
        case .uint(let v): v
        case .int(let v): v >= 0 ? UInt64(v) : nil
        default: nil
        }
    }

    /// `as_i64`: an integer that fits `i64`.
    public var asI64: Int64? {
        switch self {
        case .uint(let v): v <= UInt64(Int64.max) ? Int64(v) : nil
        case .int(let v): v
        default: nil
        }
    }

    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var asStr: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var asArray: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var asObject: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isObject: Bool { asObject != nil }
    public var isArray: Bool { asArray != nil }
    public var isString: Bool { asStr != nil }

    public var isNumber: Bool {
        switch self {
        case .uint, .int, .double, .float: true
        default: false
        }
    }

    /// `as_u64` as a `usize`. Rust's 64-bit `usize` holds every `u64`; Swift's `Int` stops at 2^63 − 1,
    /// so a larger value becomes `Int.max`, an index past anything a deck holds, as it is in Rust.
    public var asUsize: Int? { asU64.map { Int(exactly: $0) ?? Int.max } }

    /// `as_u64` narrowed to `u32` (`u32::try_from`).
    public var asU32: UInt32? { asU64.flatMap { UInt32(exactly: $0) } }
}

// MARK: - serde_json's map order and number rules

extension JSON {
    /// The value as a serde_json `Value` holds it: object keys sorted (byte order, the last of a
    /// duplicate kept), `f32` widened to `f64`, and non-finite floats `null`.
    public var canonical: JSON {
        switch self {
        case .double(let v): return v.isFinite ? self : .null
        case .float(let v): return v.isFinite ? .double(Double(v)) : .null
        case .array(let a): return .array(a.map(\.canonical))
        case .object(let o):
            var last: [String: Int] = [:]
            for (i, e) in o.entries.enumerated() { last[e.key] = i }
            let kept = o.entries.enumerated().filter { last[$0.element.key] == $0.offset }.map(\.element)
            let sorted = kept.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
            return .object(JSONObject(sorted.map { JSONObject.Entry(key: $0.key, value: $0.value.canonical) }))
        default: return self
        }
    }

    /// `format!("{}", value)` / `value.to_string()`: compact JSON with serde_json's map order.
    public var display: String { JSONWriter().string(canonical) }

    /// `==` on serde_json `Value`s: maps compare without regard to key order.
    public func valueEquals(_ other: JSON) -> Bool { canonical == other.canonical }
}
