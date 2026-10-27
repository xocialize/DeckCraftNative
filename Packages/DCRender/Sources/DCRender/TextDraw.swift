// DCRender — drawing laid-out text: glyph outlines filled with each run's colour or gradient, fake bold and
// italic, outlines, decorations, shadows and glows, and WordArt warps. Port of deckcraft
// crates/render/src/lib.rs (`draw_text`, `draw_layout_with`, `glyph`, `text_effect`, `draw_glyph_with`,
// `fill_deco`, `line_at`, `line_bounds`) and warp.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Glyphs are drawn as their outlines (CoreText's, in font units, turned y-down), as deckcraft fills its
// skrifa outlines: unhinted, so text matches at every scale. Colour glyphs (emoji) are drawn by CoreText.
import CoreGraphics
import CoreText
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText
import Foundation

/// Glyph outlines in font units, y down, by (face id, glyph id).
private final class GlyphCache: @unchecked Sendable {
    private var paths: [UInt64: BezPath] = [:]
    private let lock = NSLock()

    func path(_ face: FontFace, _ gid: UInt32) -> BezPath {
        let key = UInt64(face.id) << 32 | UInt64(gid)
        lock.lock()
        defer { lock.unlock() }
        if let p = paths[key] { return p }
        var p = BezPath()
        if let g = CGGlyph(exactly: gid), let cg = CTFontCreatePathForGlyph(face.emFont, g, nil) {
            p = bezPath(cg, flip: true)
        }
        if paths.count > 200_000 { paths.removeAll() }
        paths[key] = p
        return p
    }
}

private let glyphCache = GlyphCache()

/// The outline of glyph `gid` in font units, y down.
public func glyphPath(_ face: FontFace, _ gid: UInt32) -> BezPath { glyphCache.path(face, gid) }

/// A CoreGraphics path as a kurbo-style path (y negated when `flip`).
func bezPath(_ cg: CGPath, flip: Bool) -> BezPath {
    var p = BezPath()
    let s: Double = flip ? -1 : 1
    cg.applyWithBlock { el in
        let pts = el.pointee.points
        func pt(_ i: Int) -> Point { Point(Double(pts[i].x), s * Double(pts[i].y)) }
        switch el.pointee.type {
        case .moveToPoint: p.moveTo(pt(0))
        case .addLineToPoint: p.lineTo(pt(0))
        case .addQuadCurveToPoint: p.quadTo(pt(0), pt(1))
        case .addCurveToPoint: p.curveTo(pt(0), pt(1), pt(2))
        case .closeSubpath: p.closePath()
        @unknown default: break
        }
    }
    return p
}

/// Draw a text body into shape space `m` within the text rect.
public func drawText(_ c: Canvas, _ rctx: Resolve.Ctx, _ s: Shape, _ body: TextBody, _ tr: Rect, _ m: Affine, _ fields: any TextFields, _ prompt: Rgba?) {
    let l = TextLayoutEngine.layout(rctx, s, body, TextOpts(rect: tr, fields: fields, promptColor: prompt, noShrink: false))
    drawLayout(c, l, tr, m)
}

/// Add transient list markers to an editor layout, using the document's own bullet glyphs.
func previewEmptyBullets(_ l: inout TextLayout) {
    for var run in l.emptyBullets {
        run.color = .rgb(0xB3, 0xB3, 0xB3)
        run.alpha = 1
        l.runs.append(run)
    }
    l.emptyBullets = []
}

private let italicSkew = Affine(1, 0, -0.2, 1, 0, 0)

/// Draw a laid-out text block, with per-paragraph animation states.
public func drawLayout(_ c: Canvas, _ l: TextLayout, _ tr: Rect, _ m0: Affine, paras: [(Int, ParaState)] = []) {
    func para(_ i: Int) -> ParaState { paras.first { $0.0 == i }?.1 ?? ParaState() }
    let m = textTransform(m0, tr, l.rotation)
    func deco(_ d: Deco) {
        let ps = para(d.para)
        if !ps.visible || ps.opacity <= 0.001 { return }
        c.setTransform(m * Affine.translate(ps.offset))
        c.setPaint(.solid(d.color, ps.opacity))
        fillDeco(c, d)
    }
    for d in l.decos where d.behind { deco(d) }
    // Text shadows, then glows, under all the text.
    for pass in [TextEffect.shadow, .glow] {
        for run in l.runs {
            let ps = para(run.para)
            if ps.visible && ps.opacity > 0.001 { textEffect(c, run, pass, m * Affine.translate(ps.offset), ps.opacity) }
        }
    }
    for run in l.runs {
        if (run.alpha <= 0 || run.color.a == 0) && run.outline == nil { continue }
        let ps = para(run.para)
        if !ps.visible || ps.opacity <= 0.001 { continue }
        let rm = m * Affine.translate(ps.offset)
        // A gradient fill starts over on every line and spans that line's text, as in PowerPoint.
        var grads: [(Int, Paint)] = []
        for g in run.glyphs {
            let at = rm * glyphPlace(run, g.gid, g.x, g.y)
            guard let gr = run.gradient, !gr.stops.isEmpty else {
                drawGlyph(c, run, g.gid, at, ps.opacity)
                continue
            }
            let li = lineAt(l, run.para, g.y)
            if !grads.contains(where: { $0.0 == li }) {
                let scheme = ColorScheme(name: "", colors: Array(repeating: .black, count: 12))
                let stops = gr.stops.map { ($0.pos, $0.color.resolve(scheme, nil)) }
                let bounds = l.lines.at(li).flatMap(lineBounds) ?? tr
                grads.append((li, PaintFill.gradient(gr.shape, stops, bounds, run.alpha * ps.opacity)))
            }
            let fill = grads.first { $0.0 == li }.map { ($0.1, Affine.translate(Vec2(-g.x, -g.y))) }
            drawGlyph(c, run, g.gid, at, ps.opacity, fill: fill)
        }
    }
    for d in l.decos where !d.behind { deco(d) }
}

/// Where glyph `gid` of `run` with its pen at (`x`, `y`) is drawn, in text space: there, turned a
/// quarter turn back about its em box's centre when it stands upright in vertical text.
func glyphPlace(_ run: GlyphRun, _ gid: UInt32, _ x: Double, _ y: Double) -> Affine {
    let at = Affine.translate(Vec2(x, y))
    if let (cx, cy) = run.uprightCentre(gid, x, y) {
        return Affine.translate(Vec2(cx, cy)) * Affine.rotate(-Double.pi / 2) * Affine.translate(Vec2(-cx, -cy)) * at
    }
    return at
}

/// Fill an underline, strikethrough or highlight with the current paint and transform: its box, its
/// dashes, or its zigzag stroked.
func fillDeco(_ c: Canvas, _ d: Deco) {
    if let (pts, w) = d.wave() {
        var path = BezPath()
        for (i, p) in pts.enumerated() {
            if i == 0 { path.moveTo(p) } else { path.lineTo(p) }
        }
        c.setStroke(StrokeStyle(w.rustMax(0.01)))
        c.strokePath(path)
        return
    }
    for r in d.pieces() { c.fillRect(r) }
}

/// The line of paragraph `para` holding a glyph on baseline `y` (the nearest baseline).
func lineAt(_ l: TextLayout, _ para: Int, _ y: Double) -> Int {
    if let pl = l.paraLines.at(para) {
        if pl.count == 0 { return 0 }
        let end = min(pl.first + pl.count, l.lines.count)
        if pl.first < end {
            var best = pl.first
            var bd = Double.infinity
            for i in pl.first ..< end {
                let d = Swift.abs(l.lines[i].baseline - y)
                if d < bd {
                    bd = d
                    best = i
                }
            }
            return best
        }
    }
    var best = 0
    var bd = Double.infinity
    for (i, li) in l.lines.enumerated() where li.para == para {
        let d = Swift.abs(li.baseline - y)
        if d < bd {
            bd = d
            best = i
        }
    }
    return best
}

/// The box a line's text covers: its top and bottom, its first and last caret.
func lineBounds(_ li: LineInfo) -> Rect? {
    let x0 = li.caretX.reduce(Double.infinity) { $0.rustMin($1) }
    let x1 = li.caretX.reduce(-Double.infinity) { $0.rustMax($1) }
    let r = Rect(x0, li.top, x1, li.bottom)
    return r.isFinite && r.width > 0 && r.height > 0 ? r : nil
}

private enum TextEffect { case shadow, glow }

/// Draw `run`'s shadow or glow (if it has one) under its glyphs, placed by `m`.
private func textEffect(_ c: Canvas, _ run: GlyphRun, _ which: TextEffect, _ m: Affine, _ opacity: Double) {
    guard let fx = run.effects else { return }
    let k = run.size / run.face.upem.rustMax(1)
    let skew = run.fakeItalic ? italicSkew : .identity
    let px = scaleOf(m)
    let col: Rgba, sigma: Double, offset: Vec2, grow: Double
    switch which {
    case .shadow:
        guard let s = fx.shadow else { return }
        (col, sigma, offset, grow) = (s.color, s.blur * 0.5 * px, Vec2(s.dx, s.dy), 0)
    case .glow:
        // Measured on PowerPoint's export: a text glow of radius r is solid to about a third of r past the
        // glyph's edge and fades out by about two thirds of r.
        guard let g = fx.glow else { return }
        (col, sigma, offset, grow) = (g.color, g.radius * 0.15 * px, .zero, g.radius * 0.68)
    }
    let alpha = Double(col.a) / 255 * opacity
    if alpha <= 0 { return }
    c.setTransform(.identity)
    c.pushLayer(opacity: alpha, blur: blurSigma(sigma))
    c.setPaint(.solid(col.withAlpha(255), 1))
    for g in run.glyphs {
        let path = glyphPath(run.face, g.gid)
        if path.isEmpty { continue }
        // The offset is in slide space: a shadow falls the same way whatever the text's rotation.
        let at = Affine.translate(offset * px) * (m * glyphPlace(run, g.gid, g.x, g.y)) * skew * Affine.scale(k)
        c.setTransform(at)
        c.fillPath(path)
        if grow > 0 {
            c.setStroke(StrokeStyle(grow / k.rustMax(1e-9)).withJoin(.round))
            c.strokePath(path)
        }
    }
    c.popLayer()
}

/// Draw glyph `gid` of `run` with its origin (on the baseline) mapped by `at`, faded by `opacity`;
/// filled with `fill` (a gradient laid out in the text's space, and the map from the glyph's origin to
/// that space) instead of the run's colour when given.
func drawGlyph(_ c: Canvas, _ run: GlyphRun, _ gid: UInt32, _ at: Affine, _ opacity: Double, fill: (Paint, Affine)? = nil) {
    let alpha = run.alpha * opacity
    if (alpha <= 0 || run.color.a == 0) && run.outline == nil { return }
    let k = run.size / run.face.upem.rustMax(1)
    // Colour glyphs (emoji) paint their own colours; an outline still strokes the plain glyph below.
    if alpha > 0 && run.outline == nil && run.face.isColor {
        drawColorGlyph(c, run.face, gid, at, k, alpha, run.color)
        return
    }
    let path = glyphPath(run.face, gid)
    if path.isEmpty { return }
    let skew = run.fakeItalic ? italicSkew : .identity
    c.setTransform(at * skew * Affine.scale(k))
    if let (g, toText) = fill, alpha > 0 {
        c.setPaint(g)
        c.setPaintTransform((skew * Affine.scale(k)).inverse * toText)
        c.fillPath(path)
        c.resetPaintTransform()
    } else if alpha > 0 && run.color.a > 0 {
        c.setPaint(.solid(run.color, alpha))
        c.fillPath(path)
        if run.fakeBold {
            c.setStroke(StrokeStyle(run.face.upem * 0.025).withJoin(.round))
            c.strokePath(path)
        }
    }
    if let o = run.outline {
        c.setPaint(.solid(o.color, opacity))
        c.setStroke(StrokeStyle(o.width / k.rustMax(1e-9)).withJoin(.round))
        c.strokePath(path)
    }
}

/// A colour glyph drawn by CoreText at `at` (its origin on the baseline), `k` points per font unit; its
/// layers in the text colour (COLR palette index 0xFFFF) take `color`.
private func drawColorGlyph(_ c: Canvas, _ face: FontFace, _ gid: UInt32, _ at: Affine, _ k: Double, _ alpha: Double, _ color: Rgba) {
    guard let g = CGGlyph(exactly: gid) else { return }
    let ctx = c.current.ctx
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.concatenate(Canvas.cg(at * Affine.scale(k)))
    // CoreText draws y up from the baseline.
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAlpha(alpha.clamped(0, 1))
    ctx.setFillColor(Canvas.cgColor(color, 1))
    var glyph = g
    var pos = CGPoint.zero
    CTFontDrawGlyphs(face.emFont, &glyph, &pos, 1, ctx)
}

// MARK: - WordArt warps (warp.rs)

/// Drawing laid-out text through a WordArt warp: glyph outlines are placed in layout space, flattened, cut
/// into short segments and every point mapped through the warp, so straight glyph edges bend with the
/// guides. Underlines and highlights are warped the same way.
enum WarpText {
    static let maxPoints = 40_000

    static func lineOf(_ l: TextLayout, _ para: Int, _ y: Double) -> Int? {
        func best(_ range: some Sequence<Int>) -> Int? {
            var b: (Int, Double)?
            for i in range {
                let li = l.lines[i]
                let inside = y >= li.top - 0.01 && y <= li.bottom + 0.01
                let d = inside ? 0 : Swift.abs(li.baseline - y)
                if b.map({ d < $0.1 }) ?? true { b = (i, d) }
            }
            return b?.0
        }
        if let pl = l.paraLines.at(para) {
            if pl.count == 0 { return nil }
            let end = min(pl.first + pl.count, l.lines.count)
            if pl.first < end { return best(pl.first ..< end) }
        }
        return best(l.lines.indices.filter { l.lines[$0].para == para })
    }

    static func refOffset(_ run: GlyphRun) -> Double {
        let f = run.face
        let k = run.size / f.upem.rustMax(1)
        return ((0.375 * (f.ascent + f.descent) - f.descent) * k).clamped(-run.size, run.size)
    }

    static func warpPath(_ path: BezPath, _ tol: Double, _ seg: Double, _ f: (Point) -> Point) -> BezPath {
        var out = BezPath()
        var last: Point?
        var start: Point?
        var budget = maxPoints
        func segment(_ a: Point, _ b: Point) {
            let n0 = ((b - a).hypot / seg).rounded(.up)
            let n = n0.isFinite ? min(max(Int(rustCast: n0), 1), 512) : 1
            for i in 1 ... n {
                if budget == 0 { return }
                budget -= 1
                out.lineTo(f(a.lerp(b, Double(i) / Double(n))))
            }
        }
        flatten(path.elements, tol) { el in
            switch el {
            case .moveTo(let p):
                if let a = last, let s = start, (a - s).hypot > 1e-9 { segment(a, s) }
                out.moveTo(f(p))
                last = p
                start = p
            case .lineTo(let p):
                if let a = last { segment(a, p) }
                last = p
            case .closePath:
                if let a = last, let s = start { segment(a, s) }
                out.closePath()
                last = start
            default:
                break
            }
        }
        return out
    }

    static func draw(_ c: Canvas, _ l: TextLayout, _ tr: Rect, _ m0: Affine, _ paras: [(Int, ParaState)], _ warp: Warp) {
        func para(_ i: Int) -> ParaState { paras.first { $0.0 == i }?.1 ?? ParaState() }
        let m = textTransform(m0, tr, l.rotation)
        let n = l.lines.count
        var ink = [Rect?](repeating: nil, count: n)
        var off = [Double?](repeating: nil, count: n)
        var items: [(run: GlyphRun, path: BezPath, line: Int, state: ParaState)] = []
        for run in l.runs {
            let k = run.size / run.face.upem.rustMax(1)
            let skew = run.fakeItalic ? italicSkew : .identity
            for g in run.glyphs {
                guard let li = lineOf(l, run.para, g.y) else { continue }
                if li < n { off[li] = off[li].map { $0.rustMax(refOffset(run)) } ?? refOffset(run) }
                let outline = glyphPath(run.face, g.gid)
                if outline.isEmpty { continue }
                let path = transformed(outline, Affine.translate(Vec2(g.x, g.y)) * skew * Affine.scale(k))
                let b = path.boundingBox
                if !(b.x0.isFinite && b.y0.isFinite && b.x1.isFinite && b.y1.isFinite) { continue }
                if li < n { ink[li] = ink[li].map { $0.union(b) } ?? b }
                items.append((run, path, li, para(run.para)))
            }
        }
        let lines = l.lines.enumerated().map { i, li in
            Warp.Line(ink: ink[i], extent: (li.extent.left, li.extent.right), refY: li.baseline - (off[i] ?? 0.18 * (li.bottom - li.top)))
        }
        let mapper = warp.mapper(lines, l.inner)
        let px = scaleOf(m).rustMax(1e-6) * mapper.zoom
        let tol = (0.1 / px).clamped(1e-4, 2)
        let seg = (2 / px).clamped(1e-3, 50)
        func deco(_ d: Deco) {
            let ps = para(d.para)
            if !ps.visible || ps.opacity <= 0.001 { return }
            guard let li = lineOf(l, d.para, (d.rect.y0 + d.rect.y1) / 2) else { return }
            c.setTransform(m * Affine.translate(ps.offset))
            c.setPaint(.solid(d.color, ps.opacity))
            for r in d.pieces() { c.fillPath(warpPath(rectPath(r), tol, seg) { mapper.map(li, $0) }) }
        }
        for d in l.decos where d.behind { deco(d) }
        for it in items {
            let ps = it.state
            if !ps.visible || ps.opacity <= 0.001 { continue }
            let alpha = it.run.alpha * ps.opacity
            if (alpha <= 0 || it.run.color.a == 0) && it.run.outline == nil { continue }
            let path = warpPath(it.path, tol, seg) { mapper.map(it.line, $0) }
            c.setTransform(m * Affine.translate(ps.offset))
            if alpha > 0 && it.run.color.a > 0 {
                c.setPaint(.solid(it.run.color, alpha))
                c.fillPath(path)
                if it.run.fakeBold {
                    c.setStroke(StrokeStyle(it.run.size * 0.025).withJoin(.round))
                    c.strokePath(path)
                }
            }
            if let o = it.run.outline {
                c.setPaint(.solid(o.color, ps.opacity))
                c.setStroke(StrokeStyle(o.width.rustMax(0)).withJoin(.round))
                c.strokePath(path)
            }
        }
        for d in l.decos where !d.behind { deco(d) }
        c.setFillRule(.nonZero)
    }
}
