// DCText — one loaded font face: deckcraft-fonts' `FontFace` (crates/fonts/src/fontdb.rs, MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) over a CoreText font. Metrics come from the font's tables
// as skrifa reads them (`SFNT.info`); glyph mapping, advances and ligature carets from CoreText at the em
// size, so every value is in font units.
import CoreText
import DCCore
import Foundation
import Synchronization

public final class FontFace: @unchecked Sendable, CustomStringConvertible {
    private static let nextID = Atomic<UInt32>(1)

    /// Unique id of this face within the process.
    public let id: UInt32
    /// Typographic family name (e.g. "Source Sans 3").
    public let family: String
    /// Typographic style name (e.g. "Semibold", "Italic"); a variable font's named instance.
    public let style: String
    /// The Windows (GDI) family and style (`name` IDs 1 and 2) when the family differs from the typographic one.
    public let legacy: (family: String, style: String)?
    /// usWeightClass-style weight (400 = regular).
    public let weight: Double
    public let italic: Bool
    public let unitsPerEm: Double
    /// Ascender in font units (positive up).
    public let ascent: Double
    /// Descender in font units (positive down).
    public let descent: Double
    public let capHeight: Double
    public let xHeight: Double
    /// Where the baseline sits in a line, as a share of its height from the top (OS/2 win metrics).
    public let lineSplit: Double
    /// Underline top edge below the baseline, and thickness, font units.
    public let underline: (position: Double, thickness: Double)
    /// Strikethrough top edge above the baseline, and thickness, font units.
    public let strikeout: (position: Double, thickness: Double)
    /// Variable fonts: the named instance's axis settings (tag, user value); empty for the default instance.
    public let coords: [(tag: String, value: Double)]
    /// Colour glyph tables present (COLR, CBDT, sbix, SVG).
    public let isColor: Bool
    /// From the bundled craft-fonts set (not an installed system font).
    public let bundled: Bool
    /// The font at its em size: glyph positions and advances in font units.
    public let emFont: CTFont
    private let charset: CFCharacterSet
    /// GDEF's mark glyphs, read on first use (nil inside: the face has no glyph classes).
    private let marks = Mutex<[ClosedRange<UInt32>]??>(nil)
    private let glyphCount: Int

    /// deckcraft's `upem`.
    public var upem: Double { unitsPerEm }

    init(font: CTFont, info: FaceInfo, style: String? = nil, coords: [(String, Double)] = [], bundled: Bool) {
        id = FontFace.nextID.add(1, ordering: .relaxed).oldValue
        family = info.family
        self.style = style ?? info.style
        legacy = coords.isEmpty ? info.legacy : nil
        let axis = { (tag: String) in coords.first { $0.0 == tag }?.1 }
        weight = axis("wght") ?? (coords.isEmpty ? info.weight : styleWeight(style ?? info.style))
        if let ital = axis("ital") {
            italic = ital >= 0.5
        } else if let slnt = axis("slnt") {
            italic = Swift.abs(slnt) > 0.1
        } else {
            italic = info.italic || styleItalic(style ?? info.style)
        }
        unitsPerEm = info.upem
        ascent = info.ascent
        descent = info.descent
        capHeight = info.capHeight
        xHeight = info.xHeight
        lineSplit = info.lineSplit
        underline = info.underline
        strikeout = info.strikeout
        self.coords = coords
        self.bundled = bundled
        emFont = CTFontCreateCopyWithAttributes(font, CGFloat(info.upem), nil, nil)
        charset = CTFontCopyCharacterSet(emFont)
        glyphCount = CTFontGetGlyphCount(emFont)
        isColor = SFNT.hasColorTables(emFont)
    }

    public var description: String { "FontFace(\(family) \(style))" }

    /// Is `gid` a mark (GDEF glyph class 3)? nil when the face has no glyph classes.
    func isMark(_ gid: UInt32) -> Bool? {
        let ranges = marks.withLock { m in
            if let m { return m }
            let r = SFNT.markRanges(emFont)
            m = .some(r)
            return r
        }
        guard let ranges else { return nil }
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < gid { lo = mid + 1 } else { hi = mid }
        }
        return ranges.at(lo)?.contains(gid) ?? false
    }

    /// The font at `size` points, for drawing.
    public func ctFont(size: Double) -> CTFont {
        CTFontCreateCopyWithAttributes(emFont, CGFloat(size), nil, nil)
    }

    /// Does the face map `c` to a glyph?
    public func covers(_ c: Unicode.Scalar) -> Bool {
        CFCharacterSetIsLongCharacterMember(charset, UTF32Char(c.value))
    }

    /// Glyph id for `c` (0 = .notdef).
    public func glyph(for c: Unicode.Scalar) -> UInt32 {
        var units = Array(String(c).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(emFont, &units, &glyphs, units.count) else { return 0 }
        return UInt32(glyphs.first ?? 0)
    }

    /// Advance width of glyph `gid` in font units (half an em for a glyph the font doesn't have).
    public func advance(_ gid: UInt32) -> Double {
        guard gid < glyphCount, let g = CGGlyph(exactly: gid) else { return unitsPerEm * 0.5 }
        var glyph = g
        var adv = CGSize.zero
        return Double(CTFontGetAdvancesForGlyphs(emFont, .horizontal, &glyph, &adv, 1))
    }

    /// The ligature's caret positions (GDEF), font units, ascending.
    public func ligatureCarets(_ gid: UInt32) -> [Double] {
        guard let g = CGGlyph(exactly: gid) else { return [] }
        var pos = [CGFloat](repeating: 0, count: 64)
        let n = CTFontGetLigatureCaretPositions(emFont, g, &pos, 64)
        return pos.prefix(Swift.max(0, Swift.min(n, 64))).map(Double.init).sorted()
    }

    /// (ascent, descent) in font units, both positive.
    public var verticalMetrics: (Double, Double) { (ascent, descent) }
}
