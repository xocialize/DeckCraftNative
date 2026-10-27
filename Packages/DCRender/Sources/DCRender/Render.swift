// DCRender — slide rendering: backgrounds, master and layout graphics, shapes (fills, outlines, arrowheads,
// effects, pictures, media, ink, groups, tables, charts) and text, onto a `Canvas`. Port of deckcraft
// crates/render/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Not yet here (Wave 4, with DCAnim): Morph frames (`render_blend`, path and text morphs) and transitions.
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText
import Foundation

/// Animation state of one shape during a slide show or preview.
public struct ShapeState: Sendable {
    public var visible = true
    public var opacity = 1.0
    /// Applied in slide space around the shape's centre: translation (pt), scale, rotation (deg).
    public var offset = Vec2.zero
    public var scale = (1.0, 1.0)
    public var rotate = 0.0
    /// Reveal clip in shape-local unit space (0...1): l, t, r, b.
    public var clip: [Double]?
    /// Colour override for emphasis effects (fill).
    public var tint: Rgba?
    /// Per-paragraph states of by-paragraph text builds (paragraph index, state).
    public var paras: [(Int, ParaState)] = []

    public init() {}
}

/// Animation state of one paragraph, relative to its shape.
public struct ParaState: Sendable {
    public var visible = true
    public var opacity = 1.0
    /// Translation in shape-local points.
    public var offset = Vec2.zero

    public init() {}
}

public struct RenderOpts {
    /// Pixels per point.
    public var scale = 1.0
    /// Editor view: placeholder prompts and dashed placeholder outlines.
    public var edit = false
    /// Draw shapes marked hidden (Selection pane).
    public var showHidden = false
    /// Per-shape animation state.
    public var state: ((ShapeId) -> ShapeState)?
    /// Don't draw these shapes (being edited in place, drawn by the UI).
    public var skip: [ShapeId] = []
    /// Hide the text of this shape (the UI draws it while editing).
    public var skipText: ShapeId?
    /// Text being edited: its empty list paragraphs show grey markers.
    public var editingText: ShapeId?
    /// Animated GIF pictures and how far into their play they are (seconds).
    public var gifTimes: [(ShapeId, Double)] = []
    /// Translate the slide within the output (pixels) and output size override.
    public var offset = (0.0, 0.0)
    public var size: (Int, Int)?
    /// A colour drawn under everything (output larger than the slide).
    public var clear: Rgba?
    /// Show this text in every date field instead of the date.
    public var dateText: String?
    /// The local date and time date fields show (nil: the system clock).
    public var now: DateTime?
    /// Leave the slide background out (PNG export with a transparent background).
    public var transparentBackground = false
    /// Record the drawing (`DisplayList`) instead of rasterising it: vector PDF and printing. `scale`
    /// still sets the output's units, and so the resolution of anything drawn as a raster.
    public var record = false

    public init(scale: Double = 1.0) {
        self.scale = scale
    }
}

/// Field values for one slide: its number, the footer text and the date.
struct SlideFields: TextFields {
    var num: UInt32
    var date: String?
    var footer: String
    var now: DateTime?

    init(_ num: UInt32, _ footer: String, _ opts: RenderOpts) {
        self.num = num
        date = opts.dateText
        self.footer = footer
        now = opts.now ?? DateTime.nowLocal()
    }

    func field(_ kind: String) -> String? { field(kind, lang: nil) }

    func field(_ kind: String, lang: String?) -> String? {
        if kind == "slidenum" { return String(num) }
        if DateFields.isDateField(kind) {
            // An automatic date: today's, in the format of its type.
            if let d = date { return d }
            guard let now else { return nil }
            return DateFields.fieldText(kind, lang, now)
        }
        if kind == "footer" { return footer }
        return nil
    }
}

/// Which part of a slide `renderSlidePart` draws.
public enum SlidePart: Sendable {
    /// The background fill with the master and layout graphics.
    case backdrop
    /// The slide's own shapes over transparency.
    case content
}

private func outputSize(_ pres: Presentation, _ opts: RenderOpts) -> (Int, Int) {
    let (w, h) = opts.size ?? (
        Int(rustCast: (pres.slideSize.width * opts.scale).rounded().rustMax(1)),
        Int(rustCast: (pres.slideSize.height * opts.scale).rounded().rustMax(1))
    )
    return (min(max(w, 1), maxRenderSide), min(max(h, 1), maxRenderSide))
}

/// Render slide `index` at `opts.scale` pixels per point.
public func renderSlide(_ pres: Presentation, _ index: Int, _ opts: RenderOpts) -> RenderImage {
    renderSlideDrawn(pres, index, opts).image
}

/// `renderSlide`, also returning how far the drawing reached, in slide space (at least the slide).
public func renderSlideDrawn(_ pres: Presentation, _ index: Int, _ opts: RenderOpts) -> (image: RenderImage, extent: Rect) {
    let page = Rect(0, 0, pres.slideSize.width, pres.slideSize.height)
    guard let slide = pres.slides.at(index) else { return (RenderImage(), page) }
    let r = Renderer()
    let img = r.slide(pres, slide, index, opts)
    let k = opts.scale
    func toSlide(_ d: Rect) -> Rect {
        Rect((d.x0 - opts.offset.0) / k, (d.y0 - opts.offset.1) / k, (d.x1 - opts.offset.0) / k, (d.y1 - opts.offset.1) / k)
    }
    if let d = r.drawn, k.isFinite, k > 0, toSlide(d).isFinite { return (img, page.union(toSlide(d))) }
    return (img, page)
}

/// Render one part of slide `index` (transitions that move the contents over the backgrounds).
public func renderSlidePart(_ pres: Presentation, _ index: Int, _ part: SlidePart, _ opts: RenderOpts) -> RenderImage {
    guard let slide = pres.slides.at(index) else { return RenderImage() }
    return Renderer().slidePart(pres, slide, index, part, opts)
}

/// Slide `index` (or one part of it) recorded rather than rasterised, at `opts.scale` units per point:
/// what the PDF export draws as vector paths.
public func recordSlide(_ pres: Presentation, _ index: Int, _ part: SlidePart?, _ opts: RenderOpts) -> DisplayList? {
    guard let slide = pres.slides.at(index) else { return nil }
    var o = opts
    o.record = true
    let r = Renderer()
    let c = part.map { r.drawSlidePart(pres, slide, index, $0, o) } ?? r.drawSlide(pres, slide, index, o)
    return c?.recording()
}

/// Render a layout (Slide Master view thumbnail and canvas).
public func renderLayout(_ pres: Presentation, _ master: Int, _ layout: Int?, _ opts: RenderOpts) -> RenderImage {
    Renderer().layout(pres, master, layout, opts)
}

/// The transform a 3-D camera applies to shape `s` of size `w` x `h` (the affine map that fits it
/// best), as drawn; nil for no camera, and for groups, tables and charts.
public func cameraTurn(_ rctx: Resolve.Ctx, _ s: Shape, _ w: Double, _ h: Double) -> Affine? {
    switch s.kind {
    case .group, .table, .chart: return nil
    default: break
    }
    guard let raw = Resolve.effects(rctx, s).effects?.raw3d, let cam = Camera.fromRaw(raw) else { return nil }
    return Camera.affine(cam, w, h)
}

/// Where text laid out in text rect `tr` is drawn, for a shape drawn with `m`: `m`, without mirroring,
/// then the layout's `rotation` about the rect's centre. Flips mirror a shape's geometry, never its
/// text: a flipH shape's text stays readable and a flipV shape's text is turned 180°, as in PowerPoint.
public func textTransform(_ m: Affine, _ tr: Rect, _ rotation: Double) -> Affine {
    let c = tr.center.toVec2
    var t = m
    let cf = c.x.isFinite && c.y.isFinite
    if m.determinant < 0, cf {
        t = t * Affine.translate(c) * Affine.scaleNonUniform(-1, 1) * Affine.translate(-c)
    }
    if rotation != 0, rotation.isFinite, cf {
        t = t * Affine.translate(c) * Affine.rotate(rotation.toRadians) * Affine.translate(-c)
    }
    return t
}

/// The WordArt warp of `s`'s text over its text rectangle `tr`, if it has one deckcraft draws.
public func textWarp(_ rctx: Resolve.Ctx, _ s: Shape, _ tr: Rect) -> Warp? {
    let bp = Resolve.body(rctx, s)
    guard let name = bp.warp else { return nil }
    return Warp.make(name, bp.warpAdj, tr)
}

/// One frame being drawn: the presentation, the options and the slide's field values.
struct Frame {
    var pres: Presentation
    var opts: RenderOpts
    var fields: SlideFields
}

final class Renderer {
    /// The background of the slide being drawn, its placeholder colour and the slide's view transform:
    /// shapes filled with the background (`useBgFill`) show it through.
    var bg: (fill: Fill, ph: Rgba?, view: Affine)?
    /// What the frame has painted so far, in output pixels.
    var drawn: Rect?
    /// The transform a top-level shape is drawn under; a group's children draw under it combined with
    /// the group's child-coordinate mapping, which must not scale lines.
    var view = Affine.identity
    /// The fill of the group being drawn, with the transform and box it is laid out in.
    var groupFill: (fill: Fill, m: Affine, box: Rect)?
    /// Whether an outer-shadow silhouette pass for an ancestor group is being drawn.
    var inShadowPass = false
    /// Shape visits, bounded so nested groups can't amplify work without end.
    var renderWork = 0
    /// Visits spent on outer-shadow silhouette passes, kept apart.
    var shadowWork = 0

    func canvas(_ pres: Presentation, _ opts: RenderOpts) -> (Canvas?, Affine) {
        let (w, h) = outputSize(pres, opts)
        let c = opts.record ? Canvas(recordingWidth: w, height: h) : Canvas(width: w, height: h)
        if let col = opts.clear, let c {
            c.setPaint(.solid(col, 1))
            c.fillRect(Rect(0, 0, Double(w), Double(h)))
        }
        return (c, Affine.translate(Vec2(opts.offset.0, opts.offset.1)) * Affine.scale(opts.scale))
    }

    /// Note that `r` (local space, placed by `m`) was drawn.
    func track(_ m: Affine, _ r: Rect) {
        let b = m.transformRectBBox(r)
        if b.isFinite { drawn = drawn.map { $0.union(b) } ?? b }
    }

    func fields(_ pres: Presentation, _ index: Int, _ opts: RenderOpts) -> SlideFields {
        SlideFields(pres.slideNumber(index), pres.headerFooter.footerText, opts)
    }

    /// Background plus the master and layout graphics the slide shows.
    func backdrop(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ slide: Slide, _ view: Affine) {
        background(c, f, rctx, slide, view)
        let (showLayout, showMaster) = Resolve.showMasterShapes(slide, rctx.layout)
        if showMaster {
            let mctx = Resolve.Ctx.forMaster(f.pres, rctx.master)
            for s in rctx.master.shapes where s.ph == nil { shape(c, f, mctx, s, view, 0) }
        }
        if showLayout, let l = rctx.layout {
            let lctx = Resolve.Ctx.forLayout(f.pres, rctx.master, l)
            for s in l.shapes where s.ph == nil { shape(c, f, lctx, s, view, 0) }
        }
    }

    func reset() {
        renderWork = 0
        shadowWork = 0
        inShadowPass = false
    }

    func slide(_ pres: Presentation, _ slide: Slide, _ index: Int, _ opts: RenderOpts) -> RenderImage {
        drawSlide(pres, slide, index, opts)?.finish() ?? RenderImage()
    }

    func drawSlide(_ pres: Presentation, _ slide: Slide, _ index: Int, _ opts: RenderOpts) -> Canvas? {
        reset()
        let (cv, view) = canvas(pres, opts)
        guard let c = cv else { return nil }
        let f = Frame(pres: pres, opts: opts, fields: fields(pres, index, opts))
        if let rctx = Resolve.Ctx.forSlide(pres, slide) {
            backdrop(c, f, rctx, slide, view)
            for s in slide.shapes { shape(c, f, rctx, s, view, 0) }
        }
        return c
    }

    func slidePart(_ pres: Presentation, _ slide: Slide, _ index: Int, _ part: SlidePart, _ opts: RenderOpts) -> RenderImage {
        drawSlidePart(pres, slide, index, part, opts)?.finish() ?? RenderImage()
    }

    func drawSlidePart(_ pres: Presentation, _ slide: Slide, _ index: Int, _ part: SlidePart, _ opts: RenderOpts) -> Canvas? {
        reset()
        let (cv, view) = canvas(pres, opts)
        guard let c = cv else { return nil }
        let f = Frame(pres: pres, opts: opts, fields: fields(pres, index, opts))
        if let rctx = Resolve.Ctx.forSlide(pres, slide) {
            switch part {
            case .backdrop:
                backdrop(c, f, rctx, slide, view)
            case .content:
                // Shapes filled with the background (`useBgFill`) still show it.
                let (fill, ph) = Resolve.background(rctx, slide)
                bg = (fill, ph, view)
                for s in slide.shapes { shape(c, f, rctx, s, view, 0) }
            }
        }
        return c
    }

    func layout(_ pres: Presentation, _ mi: Int, _ li: Int?, _ opts: RenderOpts) -> RenderImage {
        reset()
        let (w, h) = outputSize(pres, opts)
        guard let c = Canvas(width: w, height: h) else { return RenderImage() }
        let view = Affine.translate(Vec2(opts.offset.0, opts.offset.1)) * Affine.scale(opts.scale)
        let f = Frame(pres: pres, opts: opts, fields: SlideFields(1, "", opts))
        if let m = pres.masters.at(mi) {
            if let li, let l = m.layouts.at(li) {
                let lc = Resolve.Ctx.forLayout(pres, m, l)
                background(c, f, lc, nil, view)
                if l.showMasterShapes {
                    let mc = Resolve.Ctx.forMaster(pres, m)
                    for s in m.shapes where s.ph == nil { shape(c, f, mc, s, view, 0) }
                }
                for s in l.shapes { shape(c, f, lc, s, view, 0) }
            } else {
                let mc = Resolve.Ctx.forMaster(pres, m)
                background(c, f, mc, nil, view)
                for s in m.shapes { shape(c, f, mc, s, view, 0) }
            }
        }
        return c.finish()
    }

    func background(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ slide: Slide?, _ view: Affine) {
        let (fill, ph) = Resolve.background(rctx, slide)
        if f.opts.transparentBackground {
            bg = (fill, ph, view)
            return
        }
        let r = Rect(0, 0, f.pres.slideSize.width, f.pres.slideSize.height)
        c.setTransform(view)
        let path = rectPath(r)
        // PowerPoint lays every background over white: a picture stretched into part of the slide, or a
        // see-through colour, leaves white around and under it.
        c.setPaint(.solid(.white, 1))
        c.fillPath(path)
        PaintFill.fillPath(c, rctx, fill, ph, path, r, view, .norm, 1.0, f.pres)
        bg = (fill, ph, view)
    }

    func shape(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ s: Shape, _ parent: Affine, _ depth: Int) {
        if depth == 0 {
            let outer = view
            view = parent
            shapeAt(c, f, rctx, s, parent, depth)
            view = outer
        } else {
            shapeAt(c, f, rctx, s, parent, depth)
        }
    }

    /// How lines are drawn for a shape under `m` at `depth`: the transform to stroke under and the one
    /// that takes the shape's outline into it. Inside a group they are the slide-level view and the rest
    /// of the chain, so the group's child-coordinate scale moves and sizes the outline but never the
    /// line width; outside a group, `m` itself and no change to the outline.
    func lineSpace(_ m: Affine, _ depth: Int) -> (base: Affine, rel: Affine) {
        let v = view
        if depth > 0, Swift.abs(v.determinant) > 1e-12, v.isFinite { return (v, v.inverse * m) }
        return (m, .identity)
    }

    /// Shape-space units per point (1 outside a group).
    func perPoint(_ m: Affine, _ depth: Int) -> Double {
        let k = scaleOf(lineSpace(m, depth).rel)
        return k.isFinite && k > 1e-12 ? 1 / k : 1
    }

    /// The size and transform a shape's text is set in: inside a group whose child coordinates scale
    /// the shape, the shape's size in slide points and `m` with that scale taken out.
    func textSpace(_ m: Affine, _ depth: Int, _ w: Double, _ h: Double) -> (w: Double, h: Double, m: Affine) {
        let rel = lineSpace(m, depth).rel
        let (a, b, cc, d, _, _) = rel.coeffs
        let sx = Darwin.hypot(a, b), sy = Darwin.hypot(cc, d)
        func ok(_ k: Double) -> Bool { k.isFinite && k > 1e-9 }
        if depth == 0 || !ok(sx) || !ok(sy) || (Swift.abs(sx - 1) < 1e-9 && Swift.abs(sy - 1) < 1e-9) { return (w, h, m) }
        let tw = w * sx, th = h * sy
        if !tw.isFinite || !th.isFinite { return (w, h, m) }
        return (tw, th, m * Affine.scaleNonUniform(1 / sx, 1 / sy))
    }

    /// A shape's geometry in its own `w` × `h` space, built at its size on the slide (#1083).
    func scaledGeometry(_ s: Shape, _ m: Affine, _ depth: Int, _ w: Double, _ h: Double) -> Preset.Geometry {
        let (tw, th, _) = textSpace(m, depth, w, h)
        if tw == w && th == h { return shapeGeometry(s, w, h) }
        var geo = shapeGeometry(s, tw, th)
        func k(_ a: Double, _ b: Double) -> Double { Swift.abs(b) > 1e-12 ? a / b : 1 }
        let back = Affine.scaleNonUniform(k(w, tw), k(h, th))
        for i in geo.paths.indices { geo.paths[i].path.applyAffine(back) }
        geo.textRect = back.transformRectBBox(geo.textRect)
        geo.sites = geo.sites.map { back * $0 }
        return geo
    }

    func shapeAt(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ s: Shape, _ parent: Affine, _ depth: Int) {
        if depth > 32 || (s.hidden && !f.opts.showHidden) || f.opts.skip.contains(s.id) { return }
        if inShadowPass {
            shadowWork += 1
            if shadowWork > 100_000 { return }
        } else {
            renderWork += 1
            if renderWork > 100_000 { return }
        }
        let st = f.opts.state?(s.id) ?? ShapeState()
        if !st.visible || st.opacity <= 0.001 { return }
        let x = Resolve.xfrm(rctx, s)
        if !x.isFinite { return }
        var m = parent * x.affine
        if st.offset != .zero || st.scale != (1.0, 1.0) || st.rotate != 0 {
            let cv = Vec2(x.w / 2, x.h / 2)
            let around = Affine.translate(cv) * Affine.rotate(st.rotate.toRadians) * Affine.scaleNonUniform(st.scale.0, st.scale.1)
                * Affine.translate(-cv)
            m = parent * Affine.translate(st.offset) * x.affine * around
        }
        if let a = cameraTurn(rctx, s, x.w, x.h) { m = m * a }
        let layered = st.opacity < 0.999 || st.clip != nil
        if layered {
            c.setTransform(m)
            let clip = st.clip.map { k in rectPath(Rect((k.at(0) ?? 0) * x.w, (k.at(1) ?? 0) * x.h, (k.at(2) ?? 1) * x.w, (k.at(3) ?? 1) * x.h)) }
            c.pushLayer(clip: clip, opacity: st.opacity.clamped(0, 1))
        }
        switch s.kind {
        case .group(let children, let child):
            let ch = Rect(child.x, child.y, child.x + child.w, child.y + child.h)
            let gm = parent * groupChildAffine(x, ch)
            // A group's own fill (a group filled with its parent's passes that on).
            let own: (fill: Fill, m: Affine, box: Rect)?
            switch s.fill {
            case .group?, nil: own = groupFill
            case let fl?: own = (fl, m, Rect(0, 0, x.w, x.h))
            }
            let outer = groupFill
            groupFill = own
            // A group's outer shadow is cast by everything in it, as PowerPoint draws it: the children drawn
            // once more under the shadow's offset, scale and skew, recoloured to the shadow colour and
            // blurred, below the group.
            if !inShadowPass, let sh = s.effects?.outerShadow {
                let col = rctx.color(sh.color, nil)
                let k = scaleOf(m)
                let d = Vec2(Darwin.cos(sh.dir.toRadians), Darwin.sin(sh.dir.toRadians)) * sh.dist
                let local = shadowLocal(sh, x.w, x.h)
                let (ownT, pre) = sh.rotateWithShape ? (Affine.translate(d) * local, Affine.identity) : (local, Affine.translate(d * k))
                let det = m.determinant
                if det.isFinite, Swift.abs(det) > 1e-12 {
                    let shift = pre * m * ownT * m.inverse
                    c.setTransform(.identity)
                    c.pushLayer(opacity: Double(col.a) / 255, blur: blurSigma(sh.blur / 3 * k))
                    inShadowPass = true
                    for chs in children { shape(c, f, rctx, chs, shift * gm, depth + 1) }
                    inShadowPass = false
                    c.setTransform(.identity)
                    c.pushLayer(blend: BlendMode(.normal, .srcIn))
                    c.setPaint(.solid(col.withAlpha(255), 1))
                    let (w, h) = (f.opts.scale * f.pres.slideSize.width, f.opts.scale * f.pres.slideSize.height)
                    c.fillRect(Rect(-w, -h, 3 * w, 3 * h).inflate(1e4, 1e4))
                    c.popLayer()
                    c.popLayer()
                }
            }
            for chs in children { shape(c, f, rctx, chs, gm, depth + 1) }
            groupFill = outer
        case .table(let t):
            // Rows grow with their text: what the cells cover, borders included.
            let cells = TableRender.draw(c, f.pres, rctx, t, m, x.w, x.h, f.fields, f.opts.edit && f.opts.editingText == s.id)
            track(m, (cells ?? Rect(0, 0, x.w, x.h)).inflate(2, 2))
        case .chart(let ch):
            track(m, Rect(0, 0, x.w, x.h))
            ChartRender.draw(c, rctx, ch, m, x.w, x.h)
        case .ink(let strokes):
            drawInk(c, strokes, parent, depth)
        default:
            geometryShape(c, f, rctx, s, m, x.w, x.h, st, depth)
        }
        if layered { c.popLayer() }
    }

    private func drawInk(_ c: Canvas, _ strokes: [InkStroke], _ parent: Affine, _ depth: Int) {
        for sk in strokes {
            let legacy = inkPressureIsLegacy(sk.points)
            let pen = sk.width.isFinite ? Swift.abs(sk.width) : 0
            for p in sk.points {
                let w = inkSampleWidth(pen, p.c, legacy)
                track(parent, Rect(p.a, p.b, p.a, p.b).inflate(w, w))
            }
            let pts = sk.points.filter { $0.a.isFinite && $0.b.isFinite }
            if pts.count < 2 { continue }
            let (base, rel) = lineSpace(parent, depth)
            c.setTransform(base)
            c.setPaint(.solid(sk.color, sk.highlighter ? 0.4 : 1))
            // Uniform-width and highlighter strokes are one path: segments drawn one by one overlap at the
            // joins, which darkens see-through highlighter ink in beads.
            if legacy || sk.highlighter {
                var bp = BezPath()
                for (i, p) in pts.enumerated() {
                    if i == 0 { bp.moveTo(Point(p.a, p.b)) } else { bp.lineTo(Point(p.a, p.b)) }
                }
                bp.applyAffine(rel)
                c.setStroke(StrokeStyle(pen.rustMax(0.1)).withCaps(.round).withJoin(.round))
                c.strokePath(bp)
                continue
            }
            for i in 1 ..< pts.count {
                let p0 = pts[i - 1], p1 = pts[i]
                var bp = BezPath()
                bp.moveTo(Point(p0.a, p0.b))
                bp.lineTo(Point(p1.a, p1.b))
                bp.applyAffine(rel)
                let a = inkSampleWidth(pen, p0.c, legacy)
                let b = inkSampleWidth(pen, p1.c, legacy)
                c.setStroke(StrokeStyle(((a + b) * 0.5).rustMax(0.1)).withCaps(.round).withJoin(.round))
                c.strokePath(bp)
            }
        }
    }

    /// Fill the filled sub-paths of `geo` (a `w` × `h` shape placed by `m`) with `fl`: `useBgFill` shows
    /// the slide background through the shape and `grpFill` the group's fill.
    func fillGeometry(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ fl: Fill, _ fillPh: Rgba?, _ geo: Preset.Geometry, _ w: Double, _ h: Double, _ m: Affine) {
        for sp in geo.paths where sp.fill != .none {
            c.setTransform(m)
            c.setFillRule(sp.evenOdd ? .evenOdd : .nonZero)
            switch (fl, bg) {
            case (.background, let b?):
                // `useBgFill`: the slide's background, laid out on the slide, shows through the shape.
                let slide = Rect(0, 0, f.pres.slideSize.width, f.pres.slideSize.height)
                let path = transformed(sp.path, b.view.inverse * m)
                PaintFill.fillPath(c, rctx, b.fill, b.ph, path, slide, b.view, sp.fill, 1, f.pres)
            case (.group, _):
                // `grpFill`: the group's fill, laid out over the whole group.
                if let g = groupFill, Swift.abs(g.m.determinant) > 1e-12 {
                    let path = transformed(sp.path, g.m.inverse * m)
                    PaintFill.fillPath(c, rctx, g.fill, nil, path, g.box, g.m, sp.fill, 1, f.pres)
                }
            default:
                PaintFill.fillPath(c, rctx, fl, fillPh, sp.path, Rect(0, 0, w, h), m, sp.fill, 1, f.pres)
            }
            c.setFillRule(.nonZero)
        }
    }

    func geometryShape(_ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ s: Shape, _ m: Affine, _ w: Double, _ h: Double, _ st: ShapeState, _ depth: Int) {
        let geo = scaledGeometry(s, m, depth, w, h)
        var (fill, fillPh) = Resolve.fill(rctx, s)
        let (resolvedLine, linePh) = Resolve.line(rctx, s)
        let (effects, fxPh) = Resolve.effects(rctx, s)
        let reach = Extent.spill(resolvedLine, effects, w, h)
        track(m, Rect(0, 0, w, h).inflate(reach, reach))
        var isPic = false
        if case .picture = s.kind { isPic = true }
        var isMedia = false
        if case .media = s.kind { isMedia = true }
        let outline = geo.outline
        // Placeholders in the editor: dashed outline and prompt, nothing else when empty.
        let emptyPh = s.ph != nil && (s.text?.isEmpty ?? true) && !isPic && !isMedia
        if let t = st.tint { fill = .solid(.rgb(t)) }
        // Effects below the shape.
        if let e = effects {
            // A picture (or picture fill) casts its shadow from its pixels, not its frame.
            var content: PictureFill?
            if case .picture(let pf) = s.kind {
                content = PaintFill.resolved(rctx, pf, nil)
            } else if case .picture(let pf)? = fill {
                content = PaintFill.resolved(rctx, pf, nil)
            }
            // What casts the shadow: the fill as see-through as it is, and the outline.
            let fillAlpha = fillOpacity(rctx, fill, fillPh)
            var caster: Caster?
            if let lf = resolvedLine.fill, !lf.isNone {
                var a = 1.0
                if case .solid(let col) = lf { a = Double(rctx.color(col, linePh).a) / 255 }
                let (base, rel) = lineSpace(m, depth)
                let lw = (resolvedLine.width ?? 0.75).rustMax(0)
                let outside = borderOutside(isPic, effects) ? outsideLine(resolvedLine, lw) : nil
                caster = Caster(line: outside ?? resolvedLine, ph: linePh, alpha: a, base: base, rel: rel)
            }
            effectsBelow(c, rctx, e, fxPh, geo, fill, fillAlpha, caster, content, m, w, h)
        }
        let soft = effects?.softEdge.flatMap { $0 > 0 ? $0 : nil }
        if soft != nil {
            c.setTransform(.identity)
            c.pushLayer()
        }
        // Shape-space units per point for the 3-D sizes, measured without the camera's turn.
        let pt: Double = {
            let turn = effects?.raw3d.flatMap(Camera.fromRaw).flatMap { Camera.affine($0, w, h) }.flatMap { Swift.abs($0.determinant) > 1e-9 ? $0 : nil }
            return perPoint(turn.map { m * $0.inverse } ?? m, depth)
        }()
        // A 3-D extrusion under a turned camera: the sides, swept behind the face.
        if let raw = effects?.raw3d, let ex = Extrude.fromRaw(raw), let cam = Camera.fromRaw(raw), let turn = Camera.affine(cam, w, h),
           Swift.abs(turn.determinant) > 1e-9 {
            var face: Rgba?
            if case .solid(let col)? = fill { face = rctx.color(col, fillPh) }
            let pre = m * turn.inverse
            let lit = Lighting.fromRaw(raw)
            Extrude.draw(c, outline, w, h, cam, ex.depth * pt, pre, turn, Extrude.sideColor(rctx, ex, face), lit)
        }
        // A 3-D contour: a band around the outline, behind the face (and in front of any sides).
        if let raw = effects?.raw3d, let ct = Extrude.contourFromRaw(raw) {
            var face: Rgba?
            if case .solid(let col)? = fill { face = rctx.color(col, fillPh) }
            let col = ct.color.map { rctx.color($0, face) } ?? face ?? .rgb(0xFF, 0xFF, 0xFF)
            Extrude.drawContour(c, outline, m, ct.width * pt, col, Lighting.fromRaw(raw))
        }
        // Fill.
        switch s.kind {
        case .picture(let pf):
            // The picture's own fill shows behind its transparent pixels, as in PowerPoint.
            if let own = s.fill, !own.isNone, let fl = fill { fillGeometry(c, f, rctx, fl, fillPh, geo, w, h, m) }
            c.setTransform(m)
            c.pushClipLayer(outline)
            let t = f.opts.gifTimes.first { $0.0 == s.id }?.1
            PaintFill.picture(c, f.pres, PaintFill.resolved(rctx, pf, nil), Rect(0, 0, w, h), m, t)
            c.popLayer()
        case .opaque(_, let preview?, _, _):
            // An object deckcraft doesn't model: its preview picture, stretched over the frame.
            if let own = s.fill, !own.isNone, let fl = fill { fillGeometry(c, f, rctx, fl, fillPh, geo, w, h, m) }
            c.setTransform(m)
            PaintFill.picture(c, f.pres, PictureFill(media: preview), Rect(0, 0, w, h), m, nil)
        case .media(let mc):
            c.setTransform(m)
            let bounds = Rect(0, 0, w, h)
            if let p = mc.poster {
                c.pushClipLayer(outline)
                PaintFill.picture(c, f.pres, PictureFill(media: p, crop: mc.crop), bounds, m, nil)
                c.popLayer()
            } else if mc.video {
                c.setPaint(.solid(.rgb(20, 20, 24), 1))
                c.fillRect(bounds)
            }
            if !mc.video || mc.poster == nil { PaintFill.mediaGlyph(c, mc.video, bounds) }
        default:
            if let fl = fill, !(emptyPh && f.opts.edit && s.fill == nil && s.line == nil && s.style == nil) {
                fillGeometry(c, f, rctx, fl, fillPh, geo, w, h, m)
            }
        }
        // `a:fillOverlay`: a fill blended over the shape's fill, inside the filled outline, under the line.
        if let ov = effects?.fillOverlay, let fl = fill, !fl.isNone {
            let mix: Mix = switch ov.blend {
            case "mult": .multiply
            case "screen": .screen
            case "darken": .darken
            case "lighten": .lighten
            default: .normal
            }
            for sp in geo.paths where sp.fill != .none {
                c.setTransform(m)
                c.pushLayer(clip: sp.path, blend: BlendMode(mix, .srcOver))
                PaintFill.fillPath(c, rctx, ov.fill, fxPh, sp.path, Rect(0, 0, w, h), m, .norm, 1, f.pres)
                c.popLayer()
            }
        }
        // Some presets' outlines default to sharp corners (PowerPoint's own per-shape default).
        var line = resolvedLine
        if case .preset(let name, _) = s.geom, line.join == nil, Preset.mitredByDefault(name) { line.join = .miter }
        // A 3-D bevel: the face and a band inside the outline lit as surfaces.
        if let raw = effects?.raw3d, var bv = Bevel.fromRaw(raw) {
            bv.w *= pt
            bv.h *= pt
            var solid: Rgba?
            if case .solid(let col)? = fill { solid = rctx.color(col, fillPh) }
            let filled = isPic || (fill.map { !$0.isNone } ?? false)
            if filled {
                var area = BezPath()
                for sp in geo.paths where sp.fill != .none { area.extend(sp.path.elements) }
                if isPic || area.isEmpty { area = outline }
                Bevel.draw(c, bv, isPic ? nil : solid, area, Rect(0, 0, w, h), m, 1)
            }
        }
        // Outline.
        if let lf = line.fill, !lf.isNone {
            drawOutline(c, rctx, s, geo, line, linePh, effects, isPic, outline, m, w, h, depth)
        }
        if let r = soft {
            // Feather: the shape (fill and line) fades to nothing at its outline. Measured on PowerPoint's
            // export: the mask is the outline shrunk by 0.85 r, blurred by a third of r.
            c.setTransform(m)
            c.pushLayer(blend: BlendMode(.normal, .destIn), blur: blurSigma(r / 3 * scaleOf(m)))
            c.setPaint(.solid(.black, 1))
            c.fillPath(outline)
            c.pushBlendLayer(BlendMode(.normal, .destOut))
            c.setStroke(StrokeStyle(r * 1.7).withJoin(.round))
            c.strokePath(outline)
            c.popLayer()
            c.popLayer()
            c.popLayer()
        }
        // Inner shadow.
        if let sh = effects?.innerShadow {
            c.setTransform(m)
            c.pushClipLayer(outline)
            let col = rctx.color(sh.color, fxPh)
            let d = Vec2(Darwin.cos(sh.dir.toRadians), Darwin.sin(sh.dir.toRadians)) * sh.dist
            // As PowerPoint draws it: the shadow falls inside along the edges it points to, blurred by a
            // third of the blur radius.
            c.pushLayer(blur: blurSigma(sh.blur / 3 * scaleOf(m)))
            c.setPaint(.solid(col, 1))
            var ring = rectPath(Rect(0, 0, w, h).inflate(w.rustMax(h), w.rustMax(h)))
            ring.extend(transformed(outline, Affine.translate(-d)).elements)
            c.setFillRule(.evenOdd)
            c.fillPath(ring)
            c.setFillRule(.nonZero)
            c.popLayer()
            c.popLayer()
        }
        // Text (or the placeholder prompt in the editor).
        if let body = s.text, f.opts.skipText != s.id {
            drawShapeText(c, f, rctx, s, body, geo, m, w, h, st, depth)
        }
        if emptyPh && f.opts.edit {
            // Dashed placeholder outline.
            c.setTransform(m)
            let px = 1 / scaleOf(m).rustMax(1e-6)
            c.setPaint(.solid(.rgb(0xA6, 0xA6, 0xA6), 1))
            c.setStroke(StrokeStyle(px).withDashes(0, [3 * px, 2 * px]))
            c.strokePath(rectPath(Rect(0, 0, w, h)))
            if let k = s.phType, [.picture, .chart, .table, .media, .diagram].contains(k) {
                PaintFill.placeholderIcon(c, k, Rect(0, 0, w, h))
            }
        }
    }

    private func drawOutline(
        _ c: Canvas, _ rctx: Resolve.Ctx, _ s: Shape, _ geo: Preset.Geometry, _ resolvedLine: Line, _ linePh: Rgba?, _ effects: Effects?,
        _ isPic: Bool, _ outline: BezPath, _ m: Affine, _ w: Double, _ h: Double, _ depth: Int
    ) {
        var line = resolvedLine
        let lw0 = (line.width ?? 0.75).rustMax(0)
        let (base, rel) = lineSpace(m, depth)
        // Arrowheads go on lines, arcs and open freeforms (filled or not), never on closed outlines or on
        // presets like brackets.
        var custom = false
        if case .custom = s.geom { custom = true }
        let openCustom = custom && (geo.paths.first { $0.stroke }.map { p in !p.path.elements.contains { $0 == .closePath } } ?? false)
        let ends = s.isLine || geo.isOpen || openCustom
        let trims = ends ? headTrims(line, lw0) : (0.0, 0.0)
        let hasHeads = ends && [line.head, line.tail].contains { $0.map { $0.kind != "none" } ?? false }
        // A see-through line and its arrowheads are one shape in PowerPoint: drawn opaque into a layer that
        // is then faded, so they don't darken where they meet.
        var seeThrough: Rgba?
        if hasHeads, case .solid(let col)? = line.fill {
            let rc = rctx.color(col, linePh)
            if rc.a < 255 { seeThrough = rc }
        }
        if let st = seeThrough {
            c.setTransform(.identity)
            c.pushLayer(opacity: Double(st.a) / 255)
            line.fill = .solid(.rgb(st.withAlpha(255)))
        }
        // A picture's border lies outside the picture, as PowerPoint draws it: stroked twice as wide,
        // outside the outline only.
        let outside = borderOutside(isPic, effects) ? outsideLine(line, lw0) : nil
        var lw = lw0
        if let o = outside {
            var clip = rectPath(Rect(0, 0, w, h).inflate(w + h + lw0 * 8, w + h + lw0 * 8))
            clip.extend(outline.elements)
            c.setTransform(m)
            c.setFillRule(.evenOdd)
            c.pushClipLayer(clip)
            c.setFillRule(.nonZero)
            line = o
            lw = lw0 * 2
        }
        let firstStroked = geo.paths.firstIndex { $0.stroke }
        for (i, sp) in geo.paths.enumerated() where sp.stroke {
            var path = rel == .identity ? sp.path : transformed(sp.path, rel)
            // The line stops inside its arrowheads, so a wide line doesn't poke out of them.
            let whole = path
            if i == firstStroked, trims != (0.0, 0.0) { path = trimEnds(path, trims.0, trims.1) }
            strokeLine(c, rctx, line, linePh, path, whole, base, lw, 1)
        }
        if ends { arrowheads(c, rctx, line, linePh, geo, rel, base, lw) }
        if outside != nil { c.popLayer() }
        if seeThrough != nil { c.popLayer() }
    }

    private func drawShapeText(
        _ c: Canvas, _ f: Frame, _ rctx: Resolve.Ctx, _ s: Shape, _ body0: TextBody, _ geo0: Preset.Geometry, _ m0: Affine, _ w: Double,
        _ h: Double, _ st: ShapeState, _ depth: Int
    ) {
        // Text in a group is set at the shape's size on the slide, in points.
        let (tw, th, m) = textSpace(m0, depth, w, h)
        let geo = tw == w && th == h ? geo0 : shapeGeometry(s, tw, th)
        let tr = geo.textRect
        let editing = f.opts.edit && f.opts.editingText == s.id
        if !body0.isEmpty || editing {
            // Imported placeholders can have no paragraph until the first keystroke.
            var body = body0
            if editing && body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
            var l = TextLayoutEngine.layout(rctx, s, body, TextOpts(rect: tr, fields: f.fields, promptColor: nil, noShrink: false))
            if editing { previewEmptyBullets(&l) }
            let tm = textTransform(m, tr, l.rotation)
            for b in l.lines.compactMap(lineBounds) {
                // Glyphs reach a little past their carets and line box (italics, swashes).
                let pad = b.height * 0.3
                track(tm, b.inflate(pad, pad))
            }
            if let wp = textWarp(rctx, s, tr), l.rotation == 0 {
                WarpText.draw(c, l, tr, m, st.paras, wp)
            } else {
                drawLayout(c, l, tr, m, paras: st.paras)
            }
        } else if f.opts.edit && s.ph != nil {
            let kind = s.phType ?? .body
            let prompt = promptBody(rctx, s, kind)
            if !prompt.isEmpty { drawText(c, rctx, s, prompt, tr, m, f.fields, .rgb(0x59, 0x59, 0x59)) }
        }
    }

    func effectsBelow(
        _ c: Canvas, _ rctx: Resolve.Ctx, _ e: Effects, _ ph: Rgba?, _ geo: Preset.Geometry, _ fill: Fill?, _ fillAlpha: Double?,
        _ outline: Caster?, _ content: PictureFill?, _ m: Affine, _ w: Double, _ h: Double
    ) {
        let silhouette: BezPath = {
            var p = BezPath()
            for sp in geo.paths where sp.fill != .none || fill == nil { p.extend(sp.path.elements) }
            return p.isEmpty ? geo.outline : p
        }()
        let k = scaleOf(m)
        if let sh = e.outerShadow {
            let col = rctx.color(sh.color, ph)
            let d = Vec2(Darwin.cos(sh.dir.toRadians), Darwin.sin(sh.dir.toRadians)) * sh.dist
            let local = shadowLocal(sh, w, h)
            // Shadow offset is in slide space (doesn't rotate with the shape unless asked).
            let (own, pre) = sh.rotateWithShape ? (Affine.translate(d) * local, Affine.identity) : (local, Affine.translate(d * k))
            let sm = pre * m * own
            c.setTransform(.identity)
            // Blurred by a third of the blur radius, as PowerPoint's export shows.
            c.pushLayer(opacity: Double(col.a) / 255, blur: blurSigma(sh.blur / 3 * k))
            c.setTransform(sm)
            if let pf = content {
                // The shadow is the picture's own coverage, recoloured to the shadow colour.
                c.pushClipLayer(silhouette)
                PaintFill.picture(c, rctx.pres, pf, Rect(0, 0, w, h), sm, nil)
                c.setTransform(sm)
                c.pushLayer(blend: BlendMode(.normal, .srcIn))
                c.setPaint(.solid(col.withAlpha(255), 1))
                c.fillRect(Rect(0, 0, w, h).inflate(1, 1))
                c.popLayer()
                c.popLayer()
            } else if let a = fillAlpha {
                // The filled part, as see-through as its fill (none for an outline-only shape) …
                var filled = BezPath()
                for sp in geo.paths where sp.fill != .none { filled.extend(sp.path.elements) }
                c.setPaint(.solid(col.withAlpha(255), a))
                c.fillPath(filled)
            }
            // … and the outline (a picture's border too).
            if let o = outline {
                var cast = o.line
                cast.fill = .solid(.rgb(col.withAlpha(255)))
                let lw = (o.line.width ?? 0.75).rustMax(0)
                for sp in geo.paths where sp.stroke {
                    strokeLine(c, rctx, cast, o.ph, transformed(sp.path, o.rel * own), nil, pre * o.base, lw, o.alpha)
                }
            }
            c.popLayer()
        }
        // A shape with no fill and no line (a text box) draws nothing to glow around.
        let glows = fillAlpha != nil || content != nil || outline != nil
        if let g = e.glow, glows {
            let col = rctx.color(g.color, ph)
            c.setTransform(.identity)
            // Measured on PowerPoint's export: a glow of radius r is half strength about half of r out from
            // the outline and gone by r.
            c.pushLayer(opacity: Double(col.a) / 255, blur: blurSigma(g.radius * 0.17 * k))
            c.setTransform(m)
            c.setPaint(.solid(col.withAlpha(255), 1))
            c.setStroke(StrokeStyle(g.radius.rustMax(0) * 0.95).withJoin(.round))
            c.strokePath(silhouette)
            // A shape without a fill (an outline, a frame) glows along its line only (#225).
            if fillAlpha != nil || content != nil { c.fillPath(silhouette) }
            c.popLayer()
        }
        if let rf = e.reflection {
            // Mirror below the shape, fading out.
            let mm = m * Affine.translate(Vec2(0, 2 * h + rf.dist)) * Affine.scaleNonUniform(1, -1)
            c.setTransform(.identity)
            c.pushLayer(opacity: rf.startAlpha.clamped(0, 1) * 0.6, blur: blurSigma(rf.blur * 0.5 * k))
            c.setTransform(mm)
            if let pf = content {
                c.pushClipLayer(silhouette)
                PaintFill.picture(c, rctx.pres, pf, Rect(0, 0, w, h), mm, nil)
                c.popLayer()
            } else if let fl = fill {
                PaintFill.fillPath(c, rctx, fl, ph, silhouette, Rect(0, 0, w, h), mm, .norm, 1, rctx.pres)
            }
            c.setTransform(mm)
            // Fade mask.
            c.pushLayer(blend: BlendMode(.normal, .destIn))
            c.setPaint(.linear(
                start: Point(0, h), end: Point(0, h * (1 - rf.endPos.clamped(0.01, 1))),
                stops: [ColorStop(0, .black), ColorStop(1, .rgba(0, 0, 0, 0))], extend: .pad
            ))
            c.fillRect(Rect(0, 0, w, h).inflate(4, 4))
            c.popLayer()
            c.popLayer()
        }
    }
}

/// A shape's outline as it casts a shadow: its line, that line's placeholder colour and opacity, and the
/// space it is stroked in (see `Renderer.lineSpace`).
struct Caster {
    var line: Line
    var ph: Rgba?
    var alpha: Double
    var base: Affine
    var rel: Affine
}

/// The prompt shown in an empty placeholder, formatted like its content would be.
func promptBody(_ rctx: Resolve.Ctx, _ s: Shape, _ kind: PhType) -> TextBody {
    // Layout/master prompt text when the layout supplies a custom one.
    let (lp, _) = Resolve.parents(rctx, s)
    if let l = lp, l.ph?.hasCustomPrompt == true, let t = l.text, !t.isEmpty { return t }
    if rctx.owner == .layout || rctx.owner == .master { return TextBody() }
    let txt = kind.prompt
    if txt.isEmpty || kind.isFooterKind { return TextBody() }
    var t = TextBody.fromText(txt)
    if [.picture, .chart, .table, .media, .diagram, .clipArt].contains(kind) {
        t.body.anchor = .bottom
        if !t.paragraphs.isEmpty {
            t.paragraphs[0].props.align = .center
            t.paragraphs[0].props.bullet = .none_
            t.paragraphs[0].props.marginLeft = 0
            t.paragraphs[0].props.indent = 0
            for i in t.paragraphs[0].runs.indices { t.paragraphs[0].runs[i].props.size = 14 }
        }
    }
    return t
}

/// Render `ids` together onto a transparent canvas, in their slide positions (copy as a picture).
public func renderShapes(_ pres: Presentation, _ slide: Slide, _ ids: [ShapeId], _ scale: Double) -> RenderImage? {
    guard !ids.isEmpty, scale.isFinite, scale > 0, let rctx = Resolve.Ctx.forSlide(pres, slide) else { return nil }
    var items: [Shape] = []
    var bounds: Rect?
    for id in ids.prefix(256) {
        guard let s = slide.shape(id) else { continue }
        let b = Resolve.xfrm(rctx, s).bounds
        if !b.width.isFinite || !b.height.isFinite || b.width < 0 || b.height < 0 { continue }
        bounds = bounds.map { $0.union(b) } ?? b
        items.append(s)
    }
    guard let b0 = bounds else { return nil }
    let b = b0.inflate(8, 8)
    guard b.width > 0, b.height > 0, b.width.isFinite, b.height.isFinite else { return nil }
    let fit = (2048 / b.width.rustMax(b.height)).rustMin(scale)
    guard fit.isFinite, fit > 0 else { return nil }
    let w = Int(rustCast: (b.width * fit).rounded(.up).clamped(1, 2048))
    let h = Int(rustCast: (b.height * fit).rounded(.up).clamped(1, 2048))
    guard let c = Canvas(width: w, height: h) else { return nil }
    let opts = RenderOpts(scale: fit)
    let f = Frame(pres: pres, opts: opts, fields: SlideFields(1, "", opts))
    let view = Affine.scale(fit) * Affine.translate(-b.origin.toVec2)
    let r = Renderer()
    for s in items { r.shape(c, f, rctx, s, view, 0) }
    return c.finish()
}

/// Render one shape alone onto a transparent canvas (drag previews, copy as picture).
public func renderShape(_ pres: Presentation, _ slide: Slide, _ id: ShapeId, _ scale: Double) -> RenderImage? {
    guard let rctx = Resolve.Ctx.forSlide(pres, slide), let s = slide.shape(id) else { return nil }
    let b = Resolve.xfrm(rctx, s).bounds.inflate(8, 8)
    let w = Int(rustCast: (b.width * scale).rounded(.up).clamped(1, Double(maxRenderSide)))
    let h = Int(rustCast: (b.height * scale).rounded(.up).clamped(1, Double(maxRenderSide)))
    guard let c = Canvas(width: w, height: h) else { return nil }
    let opts = RenderOpts(scale: scale)
    let f = Frame(pres: pres, opts: opts, fields: SlideFields(1, "", opts))
    Renderer().shape(c, f, rctx, s, Affine.scale(scale) * Affine.translate(-b.origin.toVec2), 0)
    return c.finish()
}
