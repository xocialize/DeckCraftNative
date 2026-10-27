// DCColor — sRGB colours, theme colour slots and DrawingML-style colour transforms (tint, shade,
// luminance modulation/offset, alpha…), so theme-relative colours resolve the way presentation files
// expect. Port of deckcraft crates/color/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
import Darwin

/// An sRGB colour with straight alpha, components 0–255.
public struct Rgba: Sendable, Hashable, JSONCodable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public static let black = Rgba.rgb(0, 0, 0)
    public static let white = Rgba.rgb(255, 255, 255)
    public static let transparent = Rgba(r: 0, g: 0, b: 0, a: 0)
    public static let `default` = black

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Rgba { Rgba(r: r, g: g, b: b, a: 255) }
    public static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Rgba { Rgba(r: r, g: g, b: b, a: a) }

    /// `RRGGBB` or `#RRGGBB` (also `RRGGBBAA`, and `RGB`).
    public static func fromHex(_ text: String) -> Rgba? {
        var s = Substring(rustTrim(text))
        if s.first == "#" { s = s.dropFirst() }
        let bytes = Array(s.utf8)
        guard bytes.allSatisfy(isHexDigit) else { return nil }
        func nibble(_ i: Int) -> UInt8? {
            guard let b = bytes.at(i) else { return nil }
            switch b {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): return b - UInt8(ascii: "0")
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        func byte(_ i: Int) -> UInt8? {
            guard let hi = nibble(i), let lo = nibble(i + 1) else { return nil }
            return hi << 4 | lo
        }
        switch bytes.count {
        case 6:
            guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
            return .rgb(r, g, b)
        case 8:
            guard let r = byte(0), let g = byte(2), let b = byte(4), let a = byte(6) else { return nil }
            return .rgba(r, g, b, a)
        case 3:
            guard let r = nibble(0), let g = nibble(1), let b = nibble(2) else { return nil }
            return .rgb(r * 17, g * 17, b * 17)
        default:
            return nil
        }
    }

    /// `RRGGBB` uppercase (no alpha).
    public var hex: String {
        let digits = Array("0123456789ABCDEF")
        return String([r, g, b].flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] })
    }

    public func withAlpha(_ a: UInt8) -> Rgba { Rgba(r: r, g: g, b: b, a: a) }

    public var toF32: [Float] {
        [Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, Float(a) / 255.0]
    }

    public static func fromF64(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Rgba {
        func c(_ v: Double) -> UInt8 { v.isFinite ? UInt8(rustCast: (v.clamped(0.0, 1.0) * 255.0).rounded()) : 0 }
        return Rgba(r: c(r), g: c(g), b: c(b), a: c(a))
    }

    /// Relative luminance (WCAG), 0–1.
    public var luminance: Double {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255.0
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two colours (1–21).
    public func contrast(_ other: Rgba) -> Double {
        let (a, b) = (luminance, other.luminance)
        let (hi, lo) = a > b ? (a, b) : (b, a)
        return (hi + 0.05) / (lo + 0.05)
    }

    public var toHSL: (h: Double, s: Double, l: Double) {
        let r = Double(self.r) / 255.0
        let g = Double(self.g) / 255.0
        let b = Double(self.b) / 255.0
        let mx = r.rustMax(g).rustMax(b)
        let mn = r.rustMin(g).rustMin(b)
        let l = (mx + mn) / 2.0
        if Swift.abs(mx - mn) < 1e-12 { return (0.0, 0.0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn)
        let h: Double
        if Swift.abs(mx - r) < 1e-12 {
            h = (g - b) / d + (g < b ? 6.0 : 0.0)
        } else if Swift.abs(mx - g) < 1e-12 {
            h = (b - r) / d + 2.0
        } else {
            h = (r - g) / d + 4.0
        }
        return (h * 60.0, s, l)
    }

    public static func fromHSL(_ h: Double, _ s: Double, _ l: Double, _ a: UInt8) -> Rgba {
        let h = (h.rem(360.0) + 360.0).rem(360.0) / 360.0
        let s = s.clamped(0.0, 1.0)
        let l = l.clamped(0.0, 1.0)
        if s == 0.0 { return fromF64(l, l, l, Double(a) / 255.0) }
        let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        let p = 2.0 * l - q
        func f(_ t: Double) -> Double {
            let t = t < 0.0 ? t + 1.0 : (t > 1.0 ? t - 1.0 : t)
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }
        return fromF64(f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0), Double(a) / 255.0)
    }

    /// Linear interpolation (straight alpha).
    public func lerp(_ o: Rgba, _ t: Double) -> Rgba {
        let t = t.isFinite ? t.clamped(0.0, 1.0) : 0.0
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(rustCast: (Double(a) + (Double(b) - Double(a)) * t).rounded().clamped(0.0, 255.0))
        }
        return Rgba(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b), a: m(a, o.a))
    }

    // serde: a plain struct, every field required.
    public func toJSON() -> JSON {
        .object(JSONObject(["r": r.toJSON(), "g": g.toJSON(), "b": b.toJSON(), "a": a.toJSON()]))
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Rgba")
        self.init(r: try f.required("r"), g: try f.required("g"), b: try f.required("b"), a: try f.required("a"))
    }
}

private func isHexDigit(_ b: UInt8) -> Bool {
    (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b) || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(b)
        || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(b)
}

/// The twelve theme colour slots, plus the mapped aliases (`bg1`, `tx1`…) and `phClr` (the placeholder
/// colour a style matrix entry is applied with).
public enum SchemeSlot: String, JSONStringEnum, Sendable {
    case dk1, lt1, dk2, lt2
    case accent1, accent2, accent3, accent4, accent5, accent6
    case hlink, folHlink
    case bg1, tx1, bg2, tx2
    case phClr

    public static let theme: [SchemeSlot] = [
        .dk1, .lt1, .dk2, .lt2, .accent1, .accent2, .accent3, .accent4, .accent5, .accent6, .hlink, .folHlink,
    ]

    /// The OOXML name, which is also the serialised name.
    public var xmlName: String { rawValue }

    public static func fromXML(_ s: String) -> SchemeSlot? { SchemeSlot(rawValue: s) }

    public var label: String {
        switch self {
        case .dk1, .tx1: "Text/Background - Dark 1"
        case .lt1, .bg1: "Text/Background - Light 1"
        case .dk2, .tx2: "Text/Background - Dark 2"
        case .lt2, .bg2: "Text/Background - Light 2"
        case .accent1: "Accent 1"
        case .accent2: "Accent 2"
        case .accent3: "Accent 3"
        case .accent4: "Accent 4"
        case .accent5: "Accent 5"
        case .accent6: "Accent 6"
        case .hlink: "Hyperlink"
        case .folHlink: "Followed Hyperlink"
        case .phClr: "Placeholder colour"
        }
    }
}

/// A colour scheme: the twelve theme colours.
public struct ColorScheme: Sendable, Hashable, JSONCodable {
    public var name: String
    /// Always twelve, in `SchemeSlot.theme` order.
    public var colors: [Rgba]

    public init(name: String, colors: [Rgba]) {
        self.name = name
        self.colors = colors
    }

    public func get(_ slot: SchemeSlot) -> Rgba {
        let i: Int
        switch slot {
        case .dk1, .tx1: i = 0
        case .lt1, .bg1: i = 1
        case .dk2, .tx2: i = 2
        case .lt2, .bg2: i = 3
        case .accent1: i = 4
        case .accent2: i = 5
        case .accent3: i = 6
        case .accent4: i = 7
        case .accent5: i = 8
        case .accent6: i = 9
        case .hlink: i = 10
        case .folHlink: i = 11
        case .phClr: i = 4
        }
        return colors.at(i) ?? .black
    }

    public mutating func set(_ slot: SchemeSlot, _ c: Rgba) {
        if let i = SchemeSlot.theme.firstIndex(of: slot), colors.indices.contains(i) {
            colors[i] = c
        }
    }

    public func toJSON() -> JSON {
        .object(JSONObject(["name": name.toJSON(), "colors": colors.toJSON()]))
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "ColorScheme")
        name = try f.required("name")
        guard let c = f.object["colors"] else { throw .missingField("colors") }
        colors = try decodeFixedArray(c, count: 12)
    }
}

/// One colour transform, in file units (percentages ×1000, angles ×60000), applied in order.
public enum ColorTransform: Sendable, Hashable, JSONCodable {
    case tint(Int32)
    case shade(Int32)
    case lumMod(Int32)
    case lumOff(Int32)
    case satMod(Int32)
    case satOff(Int32)
    case hueMod(Int32)
    case hueOff(Int32)
    case alpha(Int32)
    case alphaMod(Int32)
    case alphaOff(Int32)
    case comp
    case inv
    case gray
    case redMod(Int32)
    case greenMod(Int32)
    case blueMod(Int32)

    public var xmlName: String {
        switch self {
        case .tint: "tint"
        case .shade: "shade"
        case .lumMod: "lumMod"
        case .lumOff: "lumOff"
        case .satMod: "satMod"
        case .satOff: "satOff"
        case .hueMod: "hueMod"
        case .hueOff: "hueOff"
        case .alpha: "alpha"
        case .alphaMod: "alphaMod"
        case .alphaOff: "alphaOff"
        case .comp: "comp"
        case .inv: "inv"
        case .gray: "gray"
        case .redMod: "redMod"
        case .greenMod: "greenMod"
        case .blueMod: "blueMod"
        }
    }

    public var value: Int32? {
        switch self {
        case .tint(let v), .shade(let v), .lumMod(let v), .lumOff(let v), .satMod(let v), .satOff(let v),
             .hueMod(let v), .hueOff(let v), .alpha(let v), .alphaMod(let v), .alphaOff(let v),
             .redMod(let v), .greenMod(let v), .blueMod(let v):
            v
        case .comp, .inv, .gray:
            nil
        }
    }

    public static func fromXML(_ name: String, _ val: Int32?) -> ColorTransform? {
        let v = val ?? 0
        switch name {
        case "tint": return .tint(v)
        case "shade": return .shade(v)
        case "lumMod": return .lumMod(v)
        case "lumOff": return .lumOff(v)
        case "satMod": return .satMod(v)
        case "satOff": return .satOff(v)
        case "hueMod": return .hueMod(v)
        case "hueOff": return .hueOff(v)
        case "alpha": return .alpha(v)
        case "alphaMod": return .alphaMod(v)
        case "alphaOff": return .alphaOff(v)
        case "comp": return .comp
        case "inv": return .inv
        case "gray": return .gray
        case "redMod": return .redMod(v)
        case "greenMod": return .greenMod(v)
        case "blueMod": return .blueMod(v)
        default: return nil
        }
    }

    // serde: `#[serde(rename_all = "camelCase", tag = "op", content = "val")]`.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("op", xmlName)
        if let v = value { o.put("val", v) }
        return .object(o)
    }

    private static let names = [
        "tint", "shade", "lumMod", "lumOff", "satMod", "satOff", "hueMod", "hueOff", "alpha", "alphaMod",
        "alphaOff", "comp", "inv", "gray", "redMod", "greenMod", "blueMod",
    ]

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "ColorTransform")
        let op = try f.tag("op")
        guard Self.names.contains(op) else { throw .unknownVariant(op, expected: Self.names) }
        let val: Int32?
        if ["comp", "inv", "gray"].contains(op) {
            val = nil
        } else {
            val = try f.required("val") as Int32
        }
        guard let t = ColorTransform.fromXML(op, val) else { throw .unknownVariant(op, expected: Self.names) }
        self = t
    }
}

/// Apply transforms to a base colour.
public func applyTransforms(_ base: Rgba, _ transforms: [ColorTransform]) -> Rgba {
    transforms.reduce(base) { applyOne($0, $1) }
}

private func pct(_ v: Int32) -> Double { Double(v) / 100_000.0 }

private func applyOne(_ c: Rgba, _ t: ColorTransform) -> Rgba {
    func u8(_ v: Double) -> UInt8 { UInt8(rustCast: v.rounded().clamped(0.0, 255.0)) }
    switch t {
    // tint: towards white by (1 - value); shade: towards black by (1 - value). Office applies these in
    // linear light, which keeps mid-tones from washing out.
    case .tint(let v):
        let k = pct(v).clamped(0.0, 1.0)
        return mapLinear(c) { $0 * k + (1.0 - k) }
    case .shade(let v):
        let k = pct(v).clamped(0.0, 1.0)
        return mapLinear(c) { $0 * k }
    case .lumMod(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h, s, l * pct(v), c.a)
    case .lumOff(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h, s, l + pct(v), c.a)
    case .satMod(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h, s * pct(v), l, c.a)
    case .satOff(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h, s + pct(v), l, c.a)
    case .hueMod(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h * pct(v), s, l, c.a)
    case .hueOff(let v):
        let (h, s, l) = c.toHSL
        return .fromHSL(h + Double(v) / 60_000.0, s, l, c.a)
    case .alpha(let v):
        return c.withAlpha(UInt8(rustCast: (pct(v).clamped(0.0, 1.0) * 255.0).rounded()))
    case .alphaMod(let v):
        return c.withAlpha(u8(Double(c.a) * pct(v)))
    case .alphaOff(let v):
        return c.withAlpha(u8(Double(c.a) + pct(v) * 255.0))
    case .comp:
        let (h, s, l) = c.toHSL
        return .fromHSL(h + 180.0, s, l, c.a)
    case .inv:
        return Rgba(r: 255 - c.r, g: 255 - c.g, b: 255 - c.b, a: c.a)
    case .gray:
        let y = u8(0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b))
        return Rgba(r: y, g: y, b: y, a: c.a)
    case .redMod(let v):
        return Rgba(r: u8(Double(c.r) * pct(v)), g: c.g, b: c.b, a: c.a)
    case .greenMod(let v):
        return Rgba(r: c.r, g: u8(Double(c.g) * pct(v)), b: c.b, a: c.a)
    case .blueMod(let v):
        return Rgba(r: c.r, g: c.g, b: u8(Double(c.b) * pct(v)), a: c.a)
    }
}

private func toLin(_ v: UInt8) -> Double {
    let v = Double(v) / 255.0
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func fromLin(_ v: Double) -> Double {
    let v = v.clamped(0.0, 1.0)
    return v <= 0.003_130_8 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
}

private func mapLinear(_ c: Rgba, _ f: (Double) -> Double) -> Rgba {
    .fromF64(fromLin(f(toLin(c.r))), fromLin(f(toLin(c.g))), fromLin(f(toLin(c.b))), Double(c.a) / 255.0)
}

/// The colour-picker grid shown under each theme colour: lighter 80/60/40%, darker 25/50% (for dark
/// colours: lighter 90/75/50/25/10%; for light ones: darker 5–50%).
public func themeVariants(_ c: Rgba) -> [(transforms: [ColorTransform], label: String)] {
    let l = c.toHSL.l
    if l < 0.2 {
        return [
            ([.lumMod(10000), .lumOff(90000)], "Lighter 90%"),
            ([.lumMod(25000), .lumOff(75000)], "Lighter 75%"),
            ([.lumMod(50000), .lumOff(50000)], "Lighter 50%"),
            ([.lumMod(75000), .lumOff(25000)], "Lighter 25%"),
            ([.lumMod(90000), .lumOff(10000)], "Lighter 10%"),
        ]
    } else if l > 0.8 {
        return [
            ([.lumMod(95000)], "Darker 5%"),
            ([.lumMod(85000)], "Darker 15%"),
            ([.lumMod(75000)], "Darker 25%"),
            ([.lumMod(65000)], "Darker 35%"),
            ([.lumMod(50000)], "Darker 50%"),
        ]
    } else {
        return [
            ([.lumMod(20000), .lumOff(80000)], "Lighter 80%"),
            ([.lumMod(40000), .lumOff(60000)], "Lighter 60%"),
            ([.lumMod(60000), .lumOff(40000)], "Lighter 40%"),
            ([.lumMod(75000)], "Darker 25%"),
            ([.lumMod(50000)], "Darker 50%"),
        ]
    }
}

/// Standard colours row of the colour picker.
public let standardColors: [(color: Rgba, name: String)] = [
    (.rgb(0xC0, 0x00, 0x00), "Dark Red"),
    (.rgb(0xFF, 0x00, 0x00), "Red"),
    (.rgb(0xFF, 0xC0, 0x00), "Orange"),
    (.rgb(0xFF, 0xFF, 0x00), "Yellow"),
    (.rgb(0x92, 0xD0, 0x50), "Light Green"),
    (.rgb(0x00, 0xB0, 0x50), "Green"),
    (.rgb(0x00, 0xB0, 0xF0), "Light Blue"),
    (.rgb(0x00, 0x70, 0xC0), "Blue"),
    (.rgb(0x00, 0x20, 0x60), "Dark Blue"),
    (.rgb(0x70, 0x30, 0xA0), "Purple"),
]

/// A few CSS-like preset colour names (`prstClr`).
public func presetColor(_ name: String) -> Rgba? {
    switch name {
    case "black": .rgb(0, 0, 0)
    case "white": .rgb(255, 255, 255)
    case "red": .rgb(255, 0, 0)
    case "green": .rgb(0, 128, 0)
    case "lime": .rgb(0, 255, 0)
    case "blue": .rgb(0, 0, 255)
    case "yellow": .rgb(255, 255, 0)
    case "cyan", "aqua": .rgb(0, 255, 255)
    case "magenta", "fuchsia": .rgb(255, 0, 255)
    case "gray", "grey": .rgb(128, 128, 128)
    case "silver": .rgb(192, 192, 192)
    case "maroon": .rgb(128, 0, 0)
    case "navy": .rgb(0, 0, 128)
    case "olive": .rgb(128, 128, 0)
    case "purple": .rgb(128, 0, 128)
    case "teal": .rgb(0, 128, 128)
    case "orange": .rgb(255, 165, 0)
    case "pink": .rgb(255, 192, 203)
    case "brown": .rgb(165, 42, 42)
    case "gold": .rgb(255, 215, 0)
    case "ltGray", "lightGray": .rgb(211, 211, 211)
    case "dkGray", "darkGray": .rgb(169, 169, 169)
    default: nil
    }
}

/// Every preset colour name a file may write (`ST_PresetColorVal`, with the later editions' aliases).
public let presetColorNames: [String] = [
    "aliceBlue", "antiqueWhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black", "blanchedAlmond",
    "blue", "blueViolet", "brown", "burlyWood", "cadetBlue", "chartreuse", "chocolate", "coral",
    "cornflowerBlue", "cornsilk", "crimson", "cyan", "darkBlue", "darkCyan", "darkGoldenrod", "darkGray",
    "darkGrey", "darkGreen", "darkKhaki", "darkMagenta", "darkOliveGreen", "darkOrange", "darkOrchid",
    "darkRed", "darkSalmon", "darkSeaGreen", "darkSlateBlue", "darkSlateGray", "darkSlateGrey",
    "darkTurquoise", "darkViolet", "dkBlue", "dkCyan", "dkGoldenrod", "dkGray", "dkGrey", "dkGreen",
    "dkKhaki", "dkMagenta", "dkOliveGreen", "dkOrange", "dkOrchid", "dkRed", "dkSalmon", "dkSeaGreen",
    "dkSlateBlue", "dkSlateGray", "dkSlateGrey", "dkTurquoise", "dkViolet", "deepPink", "deepSkyBlue",
    "dimGray", "dimGrey", "dodgerBlue", "firebrick", "floralWhite", "forestGreen", "fuchsia", "gainsboro",
    "ghostWhite", "gold", "goldenrod", "gray", "grey", "green", "greenYellow", "honeydew", "hotPink",
    "indianRed", "indigo", "ivory", "khaki", "lavender", "lavenderBlush", "lawnGreen", "lemonChiffon",
    "lightBlue", "lightCoral", "lightCyan", "lightGoldenrodYellow", "lightGray", "lightGrey", "lightGreen",
    "lightPink", "lightSalmon", "lightSeaGreen", "lightSkyBlue", "lightSlateGray", "lightSlateGrey",
    "lightSteelBlue", "lightYellow", "ltBlue", "ltCoral", "ltCyan", "ltGoldenrodYellow", "ltGray", "ltGrey",
    "ltGreen", "ltPink", "ltSalmon", "ltSeaGreen", "ltSkyBlue", "ltSlateGray", "ltSlateGrey", "ltSteelBlue",
    "ltYellow", "lime", "limeGreen", "linen", "magenta", "maroon", "medAquamarine", "medBlue", "medOrchid",
    "medPurple", "medSeaGreen", "medSlateBlue", "medSpringGreen", "medTurquoise", "medVioletRed",
    "mediumAquamarine", "mediumBlue", "mediumOrchid", "mediumPurple", "mediumSeaGreen", "mediumSlateBlue",
    "mediumSpringGreen", "mediumTurquoise", "mediumVioletRed", "midnightBlue", "mintCream", "mistyRose",
    "moccasin", "navajoWhite", "navy", "oldLace", "olive", "oliveDrab", "orange", "orangeRed", "orchid",
    "paleGoldenrod", "paleGreen", "paleTurquoise", "paleVioletRed", "papayaWhip", "peachPuff", "peru", "pink",
    "plum", "powderBlue", "purple", "red", "rosyBrown", "royalBlue", "saddleBrown", "salmon", "sandyBrown",
    "seaGreen", "seaShell", "sienna", "silver", "skyBlue", "slateBlue", "slateGray", "slateGrey", "snow",
    "springGreen", "steelBlue", "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white",
    "whiteSmoke", "yellow", "yellowGreen",
]

/// Every system colour name a file may write (`ST_SystemColorVal`).
public let systemColorNames: [String] = [
    "scrollBar", "background", "activeCaption", "inactiveCaption", "menu", "window", "windowFrame", "menuText",
    "windowText", "captionText", "activeBorder", "inactiveBorder", "appWorkspace", "highlight", "highlightText",
    "btnFace", "btnShadow", "grayText", "btnText", "inactiveCaptionText", "btnHighlight", "3dDkShadow",
    "3dLight", "infoText", "infoBk", "hotLight", "gradientActiveCaption", "gradientInactiveCaption",
    "menuHighlight", "menuBar",
]

/// Whether `name` is a preset colour name a file may write.
public func isPresetColorName(_ name: String) -> Bool { presetColorNames.contains(name) }

/// Whether `name` is a system colour name a file may write.
public func isSystemColorName(_ name: String) -> Bool { systemColorNames.contains(name) }
