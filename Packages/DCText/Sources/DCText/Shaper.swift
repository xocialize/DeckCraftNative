// DCText — OpenType shaping through CoreText, in place of deckcraft-fonts' HarfRust `shape_range` and
// `shape` (crates/fonts/src/shape.rs and lib.rs, MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The output is what HarfRust gives deckcraft's layout: glyphs in visual order, each with
// its cluster (the index of the character that starts it) and advance and offsets in font units.
//
// An item is shaped in one face at its em size and one direction, forced with the typesetter's embedding
// level so CoreText neither reorders nor substitutes the direction deckcraft resolved. Unlike HarfRust,
// CoreText takes no context outside the item: joining across an item boundary (a style change inside an
// Arabic word) is not seen.
import CoreText
import Foundation

/// One shaped glyph, in font units (y up, as the shaper gives it).
public struct ShapedGlyph: Sendable, Equatable {
    public var gid: UInt32
    /// Index of the character (Unicode scalar, where deckcraft gives a byte offset) that starts this
    /// glyph's cluster.
    public var cluster: Int
    public var xAdvance: Double
    public var xOffset: Double
    public var yOffset: Double

    public init(gid: UInt32, cluster: Int, xAdvance: Double, xOffset: Double, yOffset: Double) {
        self.gid = gid
        self.cluster = cluster
        self.xAdvance = xAdvance
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

public enum Shaper {
    /// deckcraft-fonts `shape(face, text, &[], |c| c)`: `text` in `face` with the default features (kerning
    /// and ligatures on), each direction run shaped on its own, glyphs in logical order. Clusters are
    /// scalar indices into `text`.
    public static func shape(_ face: FontFace, _ text: String) -> [ShapedGlyph] {
        shapeLogical(face, Array(text.unicodeScalars))
    }

    /// Shape `scalars` in `face`: right to left when `rtl`, with pair kerning when `kern`, standard and
    /// contextual ligatures unless `ligatures` is false, in language `lang`.
    public static func shape(_ face: FontFace, _ scalars: [Unicode.Scalar], rtl: Bool, kern: Bool, ligatures: Bool, lang: String?, script: ScriptTag? = nil) -> [ShapedGlyph] {
        guard !scalars.isEmpty else { return [] }
        var text = String.UnicodeScalarView()
        // UTF-16 offset → scalar index.
        var scalarOfUTF16: [Int] = []
        for (i, c) in scalars.enumerated() {
            text.append(c)
            for _ in 0 ..< c.utf16.count { scalarOfUTF16.append(i) }
        }
        var attrs: [CFString: Any] = [
            kCTFontAttributeName: face.emFont,
            kCTLigatureAttributeName: NSNumber(value: ligatures ? 1 : 0),
        ]
        if !kern { attrs[kCTKernAttributeName] = NSNumber(value: 0.0) }
        if let lang, !lang.isEmpty { attrs[kCTLanguageAttributeName] = lang as CFString }
        let attr = CFAttributedStringCreate(nil, String(text) as CFString, attrs as CFDictionary)
        guard let attr else { return [] }
        let options = [kCTTypesetterOptionForcedEmbeddingLevel: NSNumber(value: rtl ? 1 : 0)] as CFDictionary
        let ts = CTTypesetterCreateWithAttributedStringAndOptions(attr, options)
        guard let ts else { return [] }
        let line = CTTypesetterCreateLine(ts, CFRange(location: 0, length: 0))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        // Every drawn glyph in visual order with its pen position on the line.
        var placed: [(gid: UInt32, cluster: Int, x: Double, y: Double, advance: Double)] = []
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(run, all, &glyphs)
            CTRunGetPositions(run, all, &positions)
            CTRunGetAdvances(run, all, &advances)
            CTRunGetStringIndices(run, all, &indices)
            // CoreText marks glyphs it deleted (absorbed into a ligature) with 0xFFFF.
            for k in 0 ..< n where glyphs[k] != 0xFFFF {
                placed.append((UInt32(glyphs[k]), scalarOfUTF16.at(indices[k]) ?? 0, Double(positions[k].x), Double(positions[k].y), Double(advances[k].width)))
            }
        }
        // HarfRust's positions: a mark has no advance and is offset from the pen (GDEF's marks, as HarfRust's
        // default, Arabic, Hebrew and Thai shapers zero them; only zero-width ones in the scripts whose
        // shapers keep mark advances, and in faces without glyph classes); any other glyph advances to where the next one that isn't
        // a mark stands, so GPOS kerning and cursive attachment land in advances as HarfRust puts them. The
        // last spacing glyph advances by its own advance, and positions are relative to the first spacing
        // glyph (CoreText hangs a right-to-left line's trailing space left of the origin).
        let zeroMarks = !keepsMarkAdvances(script ?? scalars.lazy.compactMap(Script.of).first)
        func mark(_ k: Int) -> Bool {
            let gdef = face.isMark(placed[k].gid)
            return zeroMarks ? (gdef ?? (placed[k].advance == 0)) : placed[k].advance == 0 && gdef != false
        }
        var nextSpacing = [Int?](repeating: nil, count: placed.count + 1)
        for k in placed.indices.reversed() { nextSpacing[k] = mark(k) ? nextSpacing[k + 1] : k }
        var pen: Double?
        var out: [ShapedGlyph] = []
        out.reserveCapacity(placed.count)
        for k in placed.indices {
            let g = placed[k]
            if mark(k) {
                let p = pen ?? (nextSpacing[k + 1].map { placed[$0].x } ?? g.x)
                out.append(ShapedGlyph(gid: g.gid, cluster: g.cluster, xAdvance: 0, xOffset: g.x - p, yOffset: g.y))
            } else {
                let adv = nextSpacing[k + 1].map { placed[$0].x - g.x } ?? g.advance
                out.append(ShapedGlyph(gid: g.gid, cluster: g.cluster, xAdvance: adv, xOffset: 0, yOffset: g.y))
                pen = g.x + adv
            }
        }
        return out
    }

    /// Scripts whose HarfRust shapers (Indic, Khmer, Myanmar, the Universal Shaping Engine, Hangul) keep
    /// mark advances rather than zeroing GDEF marks.
    static func keepsMarkAdvances(_ script: ScriptTag?) -> Bool {
        guard let script else { return false }
        return ["Deva", "Beng", "Guru", "Gujr", "Orya", "Taml", "Telu", "Knda", "Mlym", "Sinh", "Khmr", "Mymr", "Tibt", "Hang"].contains(script)
    }

    /// deckcraft-fonts `shape`: `text` in `face` with the shaper's default features, each direction run
    /// shaped on its own, glyphs back in logical order (clusters ascending).
    public static func shapeLogical(_ face: FontFace, _ scalars: [Unicode.Scalar]) -> [ShapedGlyph] {
        var out: [ShapedGlyph] = []
        for (range, rtl) in directionRuns(scalars) {
            var g = shape(face, Array(scalars[range]), rtl: rtl, kern: true, ligatures: true, lang: nil)
            for i in g.indices { g[i].cluster += range.lowerBound }
            if rtl {
                // Visual → logical, stable so each cluster keeps the shaper's order.
                g = g.enumerated().sorted { $0.element.cluster != $1.element.cluster ? $0.element.cluster < $1.element.cluster : $0.offset < $1.offset }
                    .map(\.element)
            }
            out += g
        }
        return out
    }

    /// Maximal runs of one direction (neutrals join the run they're in).
    private static func directionRuns(_ s: [Unicode.Scalar]) -> [(Range<Int>, Bool)] {
        var runs: [(Range<Int>, Bool)] = []
        var cur: Bool?
        var start = 0
        for (i, c) in s.enumerated() {
            let strong: Bool? = isRTLChar(c) ? true : (bidiClass(c) == .L ? false : nil)
            switch (cur, strong) {
            case (nil, let d?): cur = d
            case (let a?, let d?) where a != d:
                runs.append((start ..< i, a))
                start = i
                cur = d
            default: break
            }
        }
        runs.append((start ..< s.count, cur ?? false))
        return runs
    }
}
