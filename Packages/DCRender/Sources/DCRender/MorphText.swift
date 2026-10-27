// DCRender — Morph by words or characters: the words (or characters) two texts share travel from their place
// in the old text to their place in the new one, growing or shrinking to the new size; the rest of the old
// text fades out and the rest of the new one fades in, both riding the moving box. Port of deckcraft
// crates/render/src/morph_text.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText

/// The texts of two frame shapes (see `renderBlend`) morphed by words or characters.
public struct TextMorph: Sendable, Equatable {
    /// The frame shape from the old slide and the one from the new slide.
    public var old: ShapeId
    public var new: ShapeId
    /// Their boxes on their own slides: where the shared words start and end.
    public var from: Xfrm
    public var to: Xfrm
    /// Characters instead of words.
    public var chars: Bool
    /// Progress, 0...1 (already eased).
    public var t: Double

    public init(old: ShapeId, new: ShapeId, from: Xfrm, to: Xfrm, chars: Bool, t: Double) {
        self.old = old
        self.new = new
        self.from = from
        self.to = to
        self.chars = chars
        self.t = t
    }
}

enum MorphTextDraw {
    /// A word or character: its text, its glyphs (run, glyph) and the origin of its first glyph.
    struct Token {
        var key: String
        var glyphs: [(Int, Int)]
        var origin: Point
        var run: Int
    }

    /// Words (or characters) of a layout in reading order, plus glyphs that belong to none (bullets).
    static func tokens(_ l: TextLayout, _ chars: Bool) -> ([Token], [(Int, Int)]) {
        var cells: [(para: Int, ci: Int, ch: Unicode.Scalar, ri: Int, gi: Int)] = []
        var loose: [(Int, Int)] = []
        for (ri, run) in l.runs.enumerated() {
            for gi in run.glyphs.indices {
                if let cell = run.cells.at(gi) {
                    cells.append((run.para, cell.index, cell.char, ri, gi))
                } else {
                    loose.append((ri, gi))
                }
            }
        }
        cells = cells.enumerated().sorted { x, y in
            let (a, b) = (x.element, y.element)
            if a.para != b.para { return a.para < b.para }
            if a.ci != b.ci { return a.ci < b.ci }
            if a.ri != b.ri { return a.ri < b.ri }
            if a.gi != b.gi { return a.gi < b.gi }
            return x.offset < y.offset
        }.map(\.element)
        var out: [Token] = []
        var last: (Int, Int)?
        for c in cells {
            if c.ch.properties.isWhitespace {
                last = nil
                continue
            }
            let sameChar = last.map { $0 == (c.para, c.ci) } ?? false
            let nextChar = last.map { $0.0 == c.para && $0.1 + 1 == c.ci } ?? false
            let extend = sameChar || (!chars && nextChar)
            if extend, !out.isEmpty {
                if !sameChar { out[out.count - 1].key.unicodeScalars.append(c.ch) }
                out[out.count - 1].glyphs.append((c.ri, c.gi))
            } else {
                let origin = l.runs.at(c.ri)?.glyphs.at(c.gi).map { Point($0.x, $0.y) } ?? Point.zero
                var key = ""
                key.unicodeScalars.append(c.ch)
                out.append(Token(key: key, glyphs: [(c.ri, c.gi)], origin: origin, run: c.ri))
            }
            last = (c.para, c.ci)
        }
        return (out, loose)
    }

    /// For each token of `b`, the token of `a` with the same text, in reading order, each used once.
    static func matches(_ a: [Token], _ b: [Token]) -> [Int?] {
        var used = [Bool](repeating: false, count: a.count)
        return b.map { tb in
            guard let i = a.indices.first(where: { !(used.at($0) ?? true) && rustEqual(a[$0].key, tb.key) }) else { return nil }
            used[i] = true
            return i
        }
    }

    static func layout(_ ctx: Resolve.Ctx, _ s: Shape, _ x: Xfrm, _ fields: any TextFields) -> TextLayout? {
        guard let body = s.text, !body.isEmpty else { return nil }
        let rect = shapeGeometry(s, x.w, x.h).textRect
        return TextLayoutEngine.layout(ctx, s, body, TextOpts(rect: rect, fields: fields, promptColor: nil, noShrink: false))
    }

    static func glyphAt(_ l: TextLayout, _ g: (Int, Int)) -> (GlyphRun, UInt32, Point)? {
        guard let run = l.runs.at(g.0), let gl = run.glyphs.at(g.1) else { return nil }
        return (run, gl.gid, Point(gl.x, gl.y))
    }

    static func sameLook(_ a: GlyphRun, _ b: GlyphRun) -> Bool {
        let outline: Bool = switch (a.outline, b.outline) {
        case (nil, nil): true
        case let (x?, y?): x.color == y.color && x.width == y.width
        default: false
        }
        return a.face.id == b.face.id && a.size == b.size && a.color == b.color && a.alpha == b.alpha && outline
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Draw the morphing text of `a` (old slide, `ca`) and `b` (new slide, `cb`); `now` is the box both frame
    /// shapes share at this moment, `view` the slide-to-pixels transform.
    static func draw(
        _ c: Canvas, _ old: (Resolve.Ctx, Shape, any TextFields), _ new: (Resolve.Ctx, Shape, any TextFields), _ m: TextMorph, _ now: Xfrm,
        _ view: Affine
    ) {
        let (ca, a, fa) = old
        let (cb, b, fb) = new
        let t = m.t.isFinite ? m.t.clamped(0.0, 1.0) : 1.0
        let la0 = layout(ca, a, m.from, fa)
        let lb0 = layout(cb, b, m.to, fb)
        let mt = view * now.affine
        // Rotated (vertical) text: no per-word travel, the two texts cross-fade on the moving box.
        let rotated = (la0.map { $0.rotation != 0.0 } ?? false) || (lb0.map { $0.rotation != 0.0 } ?? false)
        guard !rotated, let la = la0, let lb = lb0 else {
            for (l, s, alpha, x) in [(la0, a, 1.0 - t, m.from), (lb0, b, t, m.to)] {
                if let l, alpha > 0.001 {
                    c.pushLayer(opacity: alpha)
                    drawLayout(c, l, shapeGeometry(s, x.w, x.h).textRect, mt)
                    c.popLayer()
                }
            }
            return
        }
        let (ta, looseA) = tokens(la, m.chars)
        let (tb, looseB) = tokens(lb, m.chars)
        let pairs = matches(ta, tb)
        // Flipped boxes keep their text readable, as when drawn (see `textTransform`).
        let (tra, trb) = (shapeGeometry(a, m.from.w, m.from.h).textRect, shapeGeometry(b, m.to.w, m.to.h).textRect)
        let (ma, mb) = (textTransform(view * m.from.affine, tra, 0.0), textTransform(view * m.to.affine, trb, 0.0))
        let (mta, mtb) = (textTransform(mt, tra, 0.0), textTransform(mt, trb, 0.0))
        let co = mta.coeffs
        let linear = Affine(co.0, co.1, co.2, co.3, 0.0, 0.0)
        var movedA = [Bool](repeating: false, count: ta.count)
        // Shared tokens travel.
        for (j, i0) in pairs.enumerated() {
            guard let i = i0, let tokB = tb.at(j), let tokA = ta.at(i) else { continue }
            if movedA.indices.contains(i) { movedA[i] = true }
            guard let ra = la.runs.at(tokA.run), let rb = lb.runs.at(tokB.run) else { continue }
            let p = (ma * tokA.origin).lerp(mb * tokB.origin, t)
            let ratio = ra.size > 0.0 && rb.size > 0.0 ? rb.size / ra.size : 1.0
            let same = sameLook(ra, rb)
            let alphaA = same ? 1.0 : 1.0 - t
            let sa = lerp(1.0, ratio, t)
            for g in tokA.glyphs {
                if let (run, gid, pos) = glyphAt(la, g) {
                    let at = Affine.translate(p.toVec2) * linear * Affine.scale(sa) * Affine.translate(pos - tokA.origin)
                    drawGlyph(c, run, gid, at, alphaA)
                }
            }
            if !same {
                let sb = lerp(1.0 / ratio, 1.0, t)
                for g in tokB.glyphs {
                    if let (run, gid, pos) = glyphAt(lb, g) {
                        let at = Affine.translate(p.toVec2) * linear * Affine.scale(sb) * Affine.translate(pos - tokB.origin)
                        drawGlyph(c, run, gid, at, t)
                    }
                }
            }
        }
        // The rest fades while following the shared tokens: they define a scale and shift from the old text to
        // the new one (F(p) = s·p + c, in pixels), so a line grows, shrinks and rearranges as one. With nothing
        // shared it rides the moving box.
        var shared: [(Point, Point, Double)] = []
        for (j, i0) in pairs.enumerated() {
            guard let i = i0, let tokA = ta.at(i), let tokB = tb.at(j), let ra = la.runs.at(tokA.run), let rb = lb.runs.at(tokB.run) else {
                continue
            }
            let ratio = ra.size > 0.0 && rb.size > 0.0 ? rb.size / ra.size : 1.0
            shared.append((ma * tokA.origin, mb * tokB.origin, ratio))
        }
        let n = Double(shared.count)
        let s = shared.reduce(-0.0) { $0 + $1.2 } / n
        let cv = shared.reduce(Vec2.zero) { acc, x in acc + (x.1.toVec2 - x.0.toVec2 * s) } / n
        let placeA: Affine, placeB: Affine
        if !shared.isEmpty, s.isFinite, s > 0.0, cv.x.isFinite, cv.y.isFinite {
            // Old text: p ↦ lerp(p, F(p), t). New text: q ↦ lerp(F⁻¹(q), q, t).
            let fa = Affine.translate(cv * t) * Affine.scale(lerp(1.0, s, t))
            let fb = Affine.translate(-cv * ((1.0 - t) / s)) * Affine.scale((1.0 - t) / s + t)
            (placeA, placeB) = (fa * ma, fb * mb)
        } else {
            (placeA, placeB) = (mta, mtb)
        }
        var restA: [(Int, Int)] = []
        for (i, tok) in ta.enumerated() where !(movedA.at(i) ?? false) { restA.append(contentsOf: tok.glyphs) }
        for g in restA + looseA {
            if let (run, gid, pos) = glyphAt(la, g) { drawGlyph(c, run, gid, placeA * Affine.translate(pos.toVec2), 1.0 - t) }
        }
        var restB: [(Int, Int)] = []
        for (j, tok) in tb.enumerated() where (pairs.at(j) ?? nil) == nil { restB.append(contentsOf: tok.glyphs) }
        for g in restB + looseB {
            if let (run, gid, pos) = glyphAt(lb, g) { drawGlyph(c, run, gid, placeB * Affine.translate(pos.toVec2), t) }
        }
        // Underlines, strikethroughs and highlights fade with their text.
        for (l, alpha, place) in [(la, 1.0 - t, placeA), (lb, t, placeB)] {
            for d in l.decos {
                c.setTransform(place)
                c.setPaint(.solid(d.color, alpha))
                fillDeco(c, d)
            }
        }
    }

    /// The token texts of a layout (tests).
    static func tokenKeys(_ l: TextLayout, _ chars: Bool) -> [String] { tokens(l, chars).0.map(\.key) }
}
