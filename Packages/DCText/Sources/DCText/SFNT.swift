// DCText — the OpenType table fields deckcraft reads through skrifa (head, hhea, OS/2, post, name),
// parsed from CoreText's copies of the tables so face metrics are skrifa's to the unit: the same
// ascent/descent choice (FreeType's: OS/2 typo with USE_TYPO_METRICS, else hhea, else typo, else win),
// weight, italic, underline and strikeout, and the `name` strings `english_or_first` picks.
import CoreText
import DCCore
import Foundation

/// Big-endian readers over a table's bytes; out of range reads are nil.
struct TableBytes {
    let b: [UInt8]

    init(_ data: CFData?) {
        b = data.map { [UInt8]($0 as Data) } ?? []
    }

    var isEmpty: Bool { b.isEmpty }

    func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }

    func i16(_ o: Int) -> Int16? { u16(o).map { Int16(bitPattern: $0) } }

    func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}

/// The metrics and names of one face, as deckcraft's `make_face` reads them.
struct FaceInfo {
    var family: String
    var style: String
    var legacy: (String, String)?
    var weight: Double
    var italic: Bool
    var upem: Double
    var ascent: Double
    /// Positive down.
    var descent: Double
    var capHeight: Double
    var xHeight: Double
    var lineSplit: Double
    var underline: (Double, Double)
    var strikeout: (Double, Double)
}

enum SFNT {
    static func tag(_ s: String) -> CTFontTableTag {
        s.utf8.reduce(0) { $0 << 8 | CTFontTableTag($1) }
    }

    static func table(_ font: CTFont, _ name: String) -> TableBytes {
        TableBytes(CTFontCopyTable(font, tag(name), []))
    }

    /// `name` table strings: (nameID, platformID, languageID, text) in table order.
    static func names(_ font: CTFont) -> [(id: UInt16, platform: UInt16, lang: UInt16, text: String)] {
        let t = table(font, "name")
        guard let count = t.u16(2), let strOff = t.u16(4) else { return [] }
        var out: [(UInt16, UInt16, UInt16, String)] = []
        for i in 0 ..< Int(count) {
            let r = 6 + i * 12
            guard let platform = t.u16(r), let encoding = t.u16(r + 2), let lang = t.u16(r + 4), let id = t.u16(r + 6),
                  let len = t.u16(r + 8), let off = t.u16(r + 10) else { break }
            let start = Int(strOff) + Int(off)
            guard start >= 0, start + Int(len) <= t.b.count else { continue }
            let bytes = Array(t.b[start ..< start + Int(len)])
            let text: String?
            switch platform {
            case 0, 3:
                var units: [UInt16] = []
                var k = 0
                while k + 1 < bytes.count {
                    units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1]))
                    k += 2
                }
                text = String(utf16CodeUnits: units, count: units.count)
            case 1 where encoding == 0:
                text = String(bytes: bytes, encoding: .macOSRoman)
            default:
                text = nil
            }
            if let text { out.append((id, platform, lang, text)) }
        }
        return out
    }

    /// skrifa's language tag for a name record (only what `english_or_first` distinguishes).
    private static func language(_ platform: UInt16, _ lang: UInt16) -> String? {
        switch (platform, lang) {
        case (3, 0x0409): "en-US"
        case (3, let l) where l & 0x3FF == 0x09: "en"
        case (1, 0): "en"
        case (0, _): nil
        default: "other"
        }
    }

    /// skrifa's `english_or_first`: en-US at once, else "en", else a string with no language, else the
    /// first; the first id of `ids` that yields a non-empty string.
    static func name(_ records: [(id: UInt16, platform: UInt16, lang: UInt16, text: String)], _ ids: [UInt16]) -> String? {
        for id in ids {
            var best: (rank: Int, text: String)?
            for (i, r) in records.filter({ $0.id == id }).enumerated() {
                let rank: Int
                switch (i, language(r.platform, r.lang)) {
                case (_, "en-US"?): rank = 3
                case (_, "en"?): rank = 2
                case (_, nil): rank = 1
                case (0, _): rank = 0
                default: continue
                }
                if best.map({ rank > $0.rank }) ?? true { best = (rank, r.text) }
                if rank == 3 { break }
            }
            if let t = best?.text, !t.isEmpty { return t }
        }
        return nil
    }

    static func info(_ font: CTFont) -> FaceInfo {
        let recs = names(font)
        let family = name(recs, [16, 1]) ?? (CTFontCopyFamilyName(font) as String)
        let style = name(recs, [17, 2]) ?? "Regular"
        var legacy: (String, String)?
        if let lf = name(recs, [1]), rustASCIILowercaseKey(lf) != rustASCIILowercaseKey(family) {
            legacy = (lf, name(recs, [2]) ?? "Regular")
        }
        let head = table(font, "head")
        let hhea = table(font, "hhea")
        let os2 = table(font, "OS/2")
        let post = table(font, "post")
        let upem = Double(Swift.max(head.u16(18) ?? 0, 1))
        var ascent = 0.0
        var descent = 0.0
        var usedTypo = false
        let fsSelection = os2.u16(62) ?? 0
        if !os2.isEmpty, fsSelection & (1 << 7) != 0 {
            ascent = Double(os2.i16(68) ?? 0)
            descent = Double(os2.i16(70) ?? 0)
            usedTypo = true
        }
        if !usedTypo {
            if !hhea.isEmpty {
                ascent = Double(hhea.i16(4) ?? 0)
                descent = Double(hhea.i16(6) ?? 0)
            }
            if ascent == 0 && descent == 0 && !os2.isEmpty {
                let ta = os2.i16(68) ?? 0
                let td = os2.i16(70) ?? 0
                if ta != 0 || td != 0 {
                    ascent = Double(ta)
                    descent = Double(td)
                } else {
                    ascent = Double(os2.u16(74) ?? 0)
                    descent = -Double(os2.u16(76) ?? 0)
                }
            }
        }
        let version = os2.u16(0) ?? 0
        let cap: Double? = !os2.isEmpty && version >= 2 ? os2.i16(88).map(Double.init) : nil
        let xh: Double? = !os2.isEmpty && version >= 2 ? os2.i16(86).map(Double.init) : nil
        // Weight and italic from OS/2 (else head's macStyle), as skrifa's attributes.
        var weight = 400.0
        var italic = false
        if !os2.isEmpty {
            weight = Double(os2.u16(4) ?? 400)
            italic = fsSelection & 1 != 0 || fsSelection & (1 << 9) != 0
        } else if !head.isEmpty {
            italic = (head.u16(44) ?? 0) & 2 != 0
        }
        // line_split: usWinAscent over usWinAscent + usWinDescent (else ascent over ascent + descent).
        let desc = -descent
        var a = ascent
        var d = desc
        if !os2.isEmpty, let wa = os2.u16(74), wa > 0 {
            a = Double(wa)
            d = Double(os2.u16(76) ?? 0)
        }
        let total = a + d
        let split: Double
        if !total.isFinite || total <= 0 || a < 0 || d < 0 {
            split = 0.8
        } else if total > upem * 1.5 {
            split = 0.81
        } else {
            split = (a / total).clamped(0.5, 1.0)
        }
        // Underline (post) and strikeout (OS/2): position of the top edge and thickness.
        var underline = (upem * 0.1, upem * 0.05)
        if !post.isEmpty, let off = post.i16(8), let th = post.i16(10) {
            let (o, t) = (Double(off), Double(th))
            if t > 0, t < upem * 0.3, Swift.abs(o) < upem * 0.5 { underline = (-o, t) }
        }
        var strikeout = (upem * 0.26, upem * 0.05)
        if !os2.isEmpty, let sz = os2.i16(26), let pos = os2.i16(28) {
            let (t, o) = (Double(sz), Double(pos))
            if t > 0, t < upem * 0.3, o > 0, o < upem { strikeout = (o, t) }
        }
        return FaceInfo(
            family: family, style: style, legacy: legacy, weight: weight, italic: italic || styleItalic(style), upem: upem,
            ascent: ascent, descent: desc, capHeight: (cap ?? 0) > 0 ? (cap ?? 0) : ascent * 0.72,
            xHeight: (xh ?? 0) > 0 ? (xh ?? 0) : ascent * 0.5, lineSplit: split, underline: underline, strikeout: strikeout
        )
    }

    /// Glyph ranges GDEF classes as marks (class 3), sorted; nil when the face has no glyph classes.
    static func markRanges(_ font: CTFont) -> [ClosedRange<UInt32>]? {
        let t = table(font, "GDEF")
        guard let off = t.u16(4), off != 0 else { return nil }
        let at = Int(off)
        var out: [ClosedRange<UInt32>] = []
        switch t.u16(at) {
        case 1?:
            guard let first = t.u16(at + 2), let count = t.u16(at + 4) else { return nil }
            var run: UInt32?
            for i in 0 ..< Int(count) {
                let gid = UInt32(first) + UInt32(i)
                if t.u16(at + 6 + 2 * i) == 3 {
                    if run == nil { run = gid }
                } else if let r = run {
                    out.append(r ... gid - 1)
                    run = nil
                }
            }
            if let r = run { out.append(r ... UInt32(first) + UInt32(count) - 1) }
        case 2?:
            guard let count = t.u16(at + 2) else { return nil }
            for i in 0 ..< Int(count) {
                let r = at + 4 + 6 * i
                guard let a = t.u16(r), let b = t.u16(r + 2), let c = t.u16(r + 4) else { break }
                if c == 3 && a <= b { out.append(UInt32(a) ... UInt32(b)) }
            }
            out.sort { $0.lowerBound < $1.lowerBound }
        default:
            return nil
        }
        return out
    }

    /// The face's table tags. CoreText's array holds the tags themselves (no callbacks), not objects, so it
    /// is read raw rather than bridged.
    static func tableTags(_ font: CTFont) -> Set<CTFontTableTag> {
        guard let arr = CTFontCopyAvailableTables(font, []) else { return [] }
        var out = Set<CTFontTableTag>()
        for i in 0 ..< CFArrayGetCount(arr) {
            let raw = UInt(bitPattern: CFArrayGetValueAtIndex(arr, i))
            out.insert(CTFontTableTag(truncatingIfNeeded: raw))
        }
        return out
    }

    /// Does the face carry colour glyph tables (COLR, CBDT, sbix, SVG)?
    static func hasColorTables(_ font: CTFont) -> Bool {
        !tableTags(font).isDisjoint(with: ["COLR", "CBDT", "sbix", "SVG "].map(tag))
    }

    /// Does the face have outlines a renderer can draw (glyf, CFF, CFF2, VARC)?
    static func hasOutlines(_ font: CTFont) -> Bool {
        !tableTags(font).isDisjoint(with: ["glyf", "CFF ", "CFF2", "VARC"].map(tag))
    }
}

/// Lower case for family-name comparisons (Rust's `eq_ignore_ascii_case`).
func rustASCIILowercaseKey(_ s: String) -> String { rustASCIILowercase(s) }

/// The weight a style name implies (deckcraft `style_weight`).
func styleWeight(_ style: String) -> Double {
    let s = normStyle(style)
    let table: [(String, Double)] = [
        ("extralight", 200), ("ultralight", 200), ("semibold", 600), ("demibold", 600), ("extrabold", 800), ("ultrabold", 800),
        ("hairline", 100), ("thin", 100), ("light", 300), ("medium", 500), ("bold", 700), ("black", 900), ("heavy", 900),
    ]
    return table.first { s.contains($0.0) }?.1 ?? 400
}

/// Is a style name italic (deckcraft `style_italic`)?
func styleItalic(_ style: String) -> Bool {
    let s = normStyle(style)
    return s.contains("italic") || s.contains("oblique") || s == "it"
}

/// Letters and digits only, lower case (deckcraft `norm`).
func normStyle(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        .flatMap { $0.properties.lowercaseMapping.unicodeScalars }))
}
