// DCRender — slide transition frames without a GPU: the layers of DCAnim's `transitionFrame` composited on
// the CPU from two rendered slide images, and Morph frames (`renderBlend`). The slide show draws the same
// layers with Metal meshes; this is the headless twin used by the CLI, comparisons and tests. Port of
// deckcraft crates/render/src/transition.rs and `render_blend` from crates/render/src/lib.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
@_exported import struct DCAnim.Layer
@_exported import enum DCAnim.Source
@_exported import func DCAnim.transitionFrame
@_exported import func DCAnim.transitionLayers
@_exported import func DCAnim.usesSlideParts
import DCAnim
import DCCore
import DCGeometry
import DCModel

/// The two slides of a transition rendered as background and content, for the transitions that move
/// contents over the backgrounds (`usesSlideParts`). nil parts of the old slide (the show's first slide) are
/// black and nothing.
public struct SlideParts: Sendable {
    public var oldBack: RenderImage?
    public var oldContent: RenderImage?
    public var newBack: RenderImage
    public var newContent: RenderImage

    public init(oldBack: RenderImage? = nil, oldContent: RenderImage? = nil, newBack: RenderImage = RenderImage(), newContent: RenderImage = RenderImage()) {
        self.oldBack = oldBack
        self.oldContent = oldContent
        self.newBack = newBack
        self.newContent = newContent
    }

    /// Render the parts of slides `old` and `new`.
    public static func render(_ pres: Presentation, _ old: Int?, _ new: Int, _ opts: RenderOpts) -> SlideParts {
        SlideParts(
            oldBack: old.map { renderSlidePart(pres, $0, .backdrop, opts) },
            oldContent: old.map { renderSlidePart(pres, $0, .content, opts) },
            newBack: renderSlidePart(pres, new, .backdrop, opts),
            newContent: renderSlidePart(pres, new, .content, opts)
        )
    }
}

/// Composite transition `layers` over black into an image the size of `new`. `old` is the outgoing slide
/// (nil: black, as when the show starts); `parts` the slides' backgrounds and contents (without them, a
/// background draws its whole slide and content draws nothing).
public func compositeTransition(_ old: RenderImage?, _ new: RenderImage, _ parts: SlideParts?, _ layers: [Layer]) -> RenderImage {
    let (w, h) = (Swift.max(new.width, 0), Swift.max(new.height, 0))
    let (n, overflow) = w.multipliedReportingOverflow(by: h)
    guard !overflow, n <= maxRenderSide * maxRenderSide else { return RenderImage() }
    var out = RenderImage(width: w, height: h, pixels: [UInt8](repeating: 0, count: n * 4))
    for i in 0 ..< n { out.pixels[i * 4 + 3] = 255 }
    let black = Tex.solid(0, 0, 0)
    for l in layers {
        var src = l.source
        if src.isPart && parts == nil {
            guard let s = src.whole else { continue }
            src = s
        }
        let tex: Tex
        switch (src, parts) {
        case (.old, _): tex = old.map { Tex.image($0) } ?? black
        case (.new, _): tex = .image(new)
        case (.black, _): tex = black
        case (.white, _): tex = .solid(255, 255, 255)
        case (.oldBack, let p?): tex = p.oldBack.map { Tex.image($0) } ?? black
        case (.newBack, let p?): tex = .image(p.newBack)
        case (.oldContent, let p?):
            guard let i = p.oldContent else { continue }
            tex = .image(i)
        case (.newContent, let p?): tex = .image(p.newContent)
        case (_, nil): continue
        }
        drawLayer(&out, l, tex)
    }
    return out
}

/// The frame of slide `index`'s transition at progress `t` (0...1): the previous slide (black for the first)
/// going out, slide `index` coming in, at `opts`' scale and size. Morph frames are rendered shape by shape like
/// the show does.
public func renderTransition(_ pres: Presentation, _ index: Int, _ t: Double, _ opts: RenderOpts) -> RenderImage {
    guard let slide = pres.slides.at(index) else { return RenderImage() }
    let (kind, option) = slide.transition.map { ($0.kind, $0.option) } ?? ("none", "")
    let prev: Int? = index > 0 && pres.slides.at(index - 1) != nil ? index - 1 : nil
    if kind == "morph", let from = prev, let a = pres.slides.at(from) {
        let tt = t.isFinite ? t.clamped(0.0, 1.0) : 0.0
        if tt < 1.0 {
            let m = morphFrame(pres, a, slide, tt) { _ in false }
            var o = opts
            o.state = { id in
                var st = ShapeState()
                st.opacity = m.opacityOf(id)
                return st
            }
            let text = m.text.map { TextMorph(old: $0.old, new: $0.new, from: $0.from, to: $0.to, chars: $0.chars, t: m.mix) }
            let paths = m.paths.map { PathMorph(id: $0.id, from: $0.from, fromBox: $0.fromBox, toBox: $0.toBox, t: m.mix) }
            return renderBlend(pres, from, index, m.mix, m.shapes, text, paths, o)
        }
    }
    let new = renderSlide(pres, index, opts)
    let old = prev.map { renderSlide(pres, $0, opts) }
    let parts = usesSlideParts(kind, option) ? SlideParts.render(pres, prev, index, opts) : nil
    let aspect = pres.slideSize.width / pres.slideSize.height.rustMax(1.0)
    return compositeTransition(old, new, parts, transitionFrame(kind, option, t, aspect))
}

// MARK: Morph frames (`render_blend`)

/// Render a frame between slides `old` and `new` (indices into `pres.slides`), e.g. of Morph: the backdrop
/// (background, master and layout graphics) of `old` cross-fading into that of `new` by `mix` (0...1), then
/// `shapes` in order, each resolved against the slide it comes from (`true`: `old`). Pairs of shapes in
/// `text` draw their boxes as usual but their texts morph by words or characters (`TextMorph`), on top of the
/// later shape of the pair. Shapes listed in `paths` draw an outline morphing from another geometry into
/// their own (`PathMorph`). `opts.state` applies to `shapes` only.
public func renderBlend(
    _ pres: Presentation, _ old: Int, _ new: Int, _ mix: Double, _ shapes: [(Shape, Bool)], _ text: [TextMorph], _ paths: [PathMorph],
    _ opts: RenderOpts
) -> RenderImage {
    guard let a = pres.slides.at(old), let b = pres.slides.at(new) else { return RenderImage() }
    return Renderer().blend(pres, (a, old), (b, new), mix, shapes, text, paths, opts)
}

extension Renderer {
    func blend(
        _ pres: Presentation, _ old: (Slide, Int), _ new: (Slide, Int), _ mix0: Double, _ shapes: [(Shape, Bool)], _ text: [TextMorph],
        _ paths: [PathMorph], _ opts: RenderOpts
    ) -> RenderImage {
        let mix = mix0.isFinite ? mix0.clamped(0.0, 1.0) : 1.0
        reset()
        let (cv, view) = canvas(pres, opts)
        guard let c = cv else { return RenderImage() }
        guard let co = Resolve.Ctx.forSlide(pres, old.0), let cn = Resolve.Ctx.forSlide(pres, new.0) else { return c.finish() }
        // Backdrop graphics never take shape states: their ids may clash with the frame's shapes.
        var bopts = opts
        bopts.state = nil
        if mix < 1.0 {
            backdrop(c, Frame(pres: pres, opts: bopts, fields: fields(pres, old.1, opts)), co, old.0, view)
        }
        if mix > 0.0 {
            let f = Frame(pres: pres, opts: bopts, fields: fields(pres, new.1, opts))
            let layered = mix < 1.0
            if layered { c.pushLayer(opacity: Double(Float(mix))) }
            backdrop(c, f, cn, new.0, view)
            if layered { c.popLayer() }
        }
        let fo = Frame(pres: pres, opts: opts, fields: fields(pres, old.1, opts))
        let fnew = Frame(pres: pres, opts: opts, fields: fields(pres, new.1, opts))
        var drawnIds: [ShapeId] = []
        // Set only now: the backdrop's ids may clash with the frame's.
        self.paths = paths
        for (s, fromOld) in shapes {
            let (f, rc) = fromOld ? (fo, co) : (fnew, cn)
            guard let tm = text.first(where: { $0.old == s.id || $0.new == s.id }) else {
                shape(c, f, rc, s, view, 0)
                continue
            }
            var bare = s
            bare.text = nil
            shape(c, f, rc, bare, view, 0)
            drawnIds.append(s.id)
            if !(drawnIds.contains(tm.old) && drawnIds.contains(tm.new)) { continue }
            func find(_ id: ShapeId) -> Shape? { shapes.first { $0.0.id == id }?.0 }
            if let a = find(tm.old), let b = find(tm.new) {
                let now = b.xfrm ?? Resolve.xfrm(cn, b)
                MorphTextDraw.draw(c, (co, a, fo.fields), (cn, b, fnew.fields), tm, now, view)
            }
        }
        self.paths = []
        morphs.sweep()
        return c.finish()
    }
}

// MARK: The CPU compositor

/// What a layer samples: an image (premultiplied RGBA8) or a solid opaque colour.
private struct Tex {
    var width = 0
    var height = 0
    var pixels: [UInt8] = []
    /// Straight RGB, opaque.
    var solid: (Float, Float, Float)?

    static func image(_ img: RenderImage) -> Tex { Tex(width: img.width, height: img.height, pixels: img.pixels, solid: nil) }

    static func solid(_ r: Float, _ g: Float, _ b: Float) -> Tex { Tex(solid: (r, g, b)) }
}

/// A texture's pixels while a triangle samples them.
private struct Sampler {
    let w: Int
    let h: Int
    let px: UnsafeBufferPointer<UInt8>
    let solid: (Float, Float, Float)?

    /// Premultiplied RGBA (0...255) at texture coordinate (u, v), bilinear, clamped to the edge.
    @inline(__always)
    func sample(_ u: Double, _ v: Double) -> (Float, Float, Float, Float) {
        if let c = solid { return (c.0, c.1, c.2, 255.0) }
        if w <= 0 || h <= 0 { return (0, 0, 0, 0) }
        let x = (u * Double(w) - 0.5).clamped(0.0, Double(w - 1))
        let y = (v * Double(h) - 0.5).clamped(0.0, Double(h - 1))
        // Rust's `floor() as usize`: x and y are clamped into the image, NaN goes to 0.
        let (x0, y0) = (x.isNaN ? 0 : Int(x.rounded(.down)), y.isNaN ? 0 : Int(y.rounded(.down)))
        let (x1, y1) = (Swift.min(x0 + 1, w - 1), Swift.min(y0 + 1, h - 1))
        let (fx, fy) = (Float(x - Double(x0)), Float(y - Double(y0)))
        let i00 = (y0 * w + x0) * 4, i10 = (y0 * w + x1) * 4, i01 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4
        // Every index is in the image (x and y are clamped into it); a short buffer reads as transparent.
        guard Swift.min(i00, i10, i01, i11) >= 0, Swift.max(i00, i10, i01, i11) + 3 < px.count else { return (0, 0, 0, 0) }
        @inline(__always) func mix(_ k: Int) -> Float {
            let (a, b, c, d) = (Float(px[i00 + k]), Float(px[i10 + k]), Float(px[i01 + k]), Float(px[i11 + k]))
            let top = a + (b - a) * fx
            let bot = c + (d - c) * fx
            return top + (bot - top) * fy
        }
        return (mix(0), mix(1), mix(2), mix(3))
    }
}

private func drawLayer(_ out: inout RenderImage, _ l: Layer, _ tex: Tex) {
    if !(l.alpha.isFinite && l.alpha > 0.0) { return }
    let (verts, tris) = layerMesh(l)
    let (w, h) = (Double(out.width), Double(out.height))
    let (ow, oh) = (out.width, out.height)
    tex.pixels.withUnsafeBufferPointer { px in
        let sampler = Sampler(w: tex.width, h: tex.height, px: px, solid: tex.solid)
        out.pixels.withUnsafeMutableBufferPointer { dst in
            for t in tris {
                guard let a = verts.at(Int(t[0])), let b = verts.at(Int(t[1])), let c = verts.at(Int(t[2])) else { continue }
                let p = (UnitPoint(a.pos[0] * w, a.pos[1] * h), UnitPoint(b.pos[0] * w, b.pos[1] * h), UnitPoint(c.pos[0] * w, c.pos[1] * h))
                func clamp(_ x: Double) -> Double { x.isFinite ? x.clamped(0.0, 1.0) : 0.0 }
                let al = (clamp(a.a), clamp(b.a), clamp(c.a))
                if al.0 <= 0.0 && al.1 <= 0.0 && al.2 <= 0.0 { continue }
                fillTriangle(dst, ow, oh, p, (a.uv, b.uv, c.uv), al, sampler)
            }
        }
    }
}

/// Rust's `v.round().clamp(0.0, 255.0) as u8` (NaN to 0), without the generic cast, which is slow
/// unoptimised.
@inline(__always)
private func byte(_ v: Float) -> UInt8 {
    let c = v.rounded().clamped(0.0, 255.0)
    return c.isNaN ? 0 : UInt8(c)
}

/// Rasterise one textured triangle: pixel centres inside it take the texture's colour at the barycentric
/// texture coordinate, at the interpolated opacity, blended source-over.
private func fillTriangle(
    _ out: UnsafeMutableBufferPointer<UInt8>, _ w: Int, _ h: Int, _ p: (UnitPoint, UnitPoint, UnitPoint), _ uv: (UnitPoint, UnitPoint, UnitPoint),
    _ al: (Double, Double, Double), _ tex: Sampler
) {
    // Scalars, not SIMD lanes, in the per-pixel loop (SIMD subscripts are slow unoptimised).
    let (x0, y0, x1, y1, x2, y2) = (p.0[0], p.0[1], p.1[0], p.1[1], p.2[0], p.2[1])
    let (u0, v0, u1, v1, u2, v2) = (uv.0[0], uv.0[1], uv.1[0], uv.1[1], uv.2[0], uv.2[1])
    let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if !area.isFinite || Swift.abs(area) < 1e-12 { return }
    let minx = Int(rustCast: x0.rustMin(x1).rustMin(x2).rounded(.down).rustMax(0.0))
    let maxx = Swift.min(Int(rustCast: x0.rustMax(x1).rustMax(x2).rounded(.up)), w)
    let miny = Int(rustCast: y0.rustMin(y1).rustMin(y2).rounded(.down).rustMax(0.0))
    let maxy = Swift.min(Int(rustCast: y0.rustMax(y1).rustMax(y2).rounded(.up)), h)
    if minx >= maxx || miny >= maxy { return }
    let count = out.count
    for y in miny ..< maxy {
        // Sample a hair off the pixel centre so a point on an edge shared by two triangles falls in exactly one
        // of them (no double-blended seams).
        let fy = Double(y) + 0.5 + 2.31e-6
        for x in minx ..< maxx {
            let fx = Double(x) + 0.5 + 1.17e-6
            // deckcraft's `edge(a, b, x, y) = (b.x - a.x)(y - a.y) - (b.y - a.y)(x - a.x)`.
            let w0 = ((x2 - x1) * (fy - y1) - (y2 - y1) * (fx - x1)) / area
            let w1 = ((x0 - x2) * (fy - y2) - (y0 - y2) * (fx - x2)) / area
            let w2 = ((x1 - x0) * (fy - y0) - (y1 - y0) * (fx - x0)) / area
            if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 { continue }
            let u = w0 * u0 + w1 * u1 + w2 * u2
            let v = w0 * v0 + w1 * v1 + w2 * v2
            let alpha = Float(w0 * al.0 + w1 * al.1 + w2 * al.2)
            if alpha <= 0.0 { continue }
            let s = tex.sample(u, v)
            let i = (y * w + x) * 4
            guard i >= 0, i + 3 < count else { continue }
            let sa = s.3 * alpha / 255.0
            let keep = 1.0 - sa
            out[i] = byte(s.0 * alpha + Float(out[i]) * keep)
            out[i + 1] = byte(s.1 * alpha + Float(out[i + 1]) * keep)
            out[i + 2] = byte(s.2 * alpha + Float(out[i + 2]) * keep)
            out[i + 3] = byte(s.3 * alpha + Float(out[i + 3]) * keep)
        }
    }
}
