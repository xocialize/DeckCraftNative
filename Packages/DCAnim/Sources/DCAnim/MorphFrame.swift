// DCAnim — Morph: matching shapes between two slides, interpolating their boxes and building the frames.
// Port of deckcraft crates/anim/src/morph.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

private func textOf(_ s: Shape) -> String { s.text?.text ?? "" }

private func trimmedEqual(_ a: String, _ b: String) -> Bool { rustEqual(String(rustTrim(a)), String(rustTrim(b))) }

/// Pairs of (shape on `a`, shape on `b`) that Morph animates from one to the other: first by `!!name`
/// (forced match), then by exact name, then by the same kind and text, then by the same kind and preset
/// geometry if neither carries text. A text box with neither a name nor its text on the other slide stays
/// unpaired and fades in place, as in PowerPoint (#119). Each shape is used once; top-level shapes only
/// (groups move whole).
public func morphPairs(_ a: Slide, _ b: Slide) -> [(ShapeId, ShapeId)] {
    var pairs: [(ShapeId, ShapeId)] = []
    var usedA = [Bool](repeating: false, count: a.shapes.count)
    var usedB = [Bool](repeating: false, count: b.shapes.count)
    let passes: [(Shape, Shape) -> Bool] = [
        { x, y in x.name.bytesHavePrefix("!!") && rustEqual(x.name, y.name) },
        { x, y in !x.name.isEmpty && rustEqual(x.name, y.name) },
        { x, y in
            if x.kindName != y.kindName { return false }
            let tx = textOf(x)
            return !rustTrim(tx).isEmpty && rustEqual(tx, textOf(y))
        },
        { x, y in
            guard x.kindName == y.kindName, let nx = x.geom.presetName, let ny = y.geom.presetName, rustEqual(nx, ny) else { return false }
            return rustTrim(textOf(x)).isEmpty && rustTrim(textOf(y)).isEmpty
        },
    ]
    for pass in passes {
        for (i, sa) in a.shapes.enumerated() where !(usedA.at(i) ?? true) {
            guard let j = b.shapes.indices.first(where: { j in !(usedB.at(j) ?? true) && pass(sa, b.shapes[j]) }) else { continue }
            usedA[i] = true
            usedB[j] = true
            pairs.append((sa.id, b.shapes[j].id))
        }
    }
    return pairs
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    let v = a + (b - a) * t
    if v.isFinite { return v }
    return t < 0.5 ? a : b
}

/// Interpolate a box from `a` to `b` at `t` (0...1): position and size linearly, rotation along the
/// shortest way round; flips switch at the midpoint.
public func morphXfrm(_ a: Xfrm, _ b: Xfrm, _ t0: Double) -> Xfrm {
    let t = clampf(t0, 0.0, 1.0, 0.0)
    if t >= 1.0 { return b }
    if t <= 0.0 { return a }
    let ra = a.rot.isFinite ? a.rot : 0.0
    let rb = b.rot.isFinite ? b.rot : 0.0
    var d = (rb - ra).remEuclid(360.0)
    if d > 180.0 { d -= 360.0 }
    let rot = (ra + d * t).remEuclid(360.0)
    let late = t >= 0.5
    return Xfrm(
        x: lerp(a.x, b.x, t),
        y: lerp(a.y, b.y, t),
        w: lerp(a.w, b.w, t),
        h: lerp(a.h, b.h, t),
        rot: rot.isFinite ? rot : 0.0,
        flipH: late ? b.flipH : a.flipH,
        flipV: late ? b.flipV : a.flipV
    )
}

/// One frame of a Morph transition, ready for the renderer's `renderBlend`: the backdrops of the two slides
/// cross-fade by `mix`, the shapes are drawn in order on top.
public struct MorphFrame: Sendable {
    /// Shapes with fresh ids, each flagged `true` when it comes from the old slide (it resolves its
    /// placeholder, theme and style against that slide).
    public var shapes: [(Shape, Bool)] = []
    /// Opacity of the frame's shapes by id; shapes not listed are opaque.
    public var opacity: [(ShapeId, Double)] = []
    public var mix = 0.0
    /// With the Words or Characters option: pairs of frame shapes whose texts morph by words or characters
    /// instead of cross-fading (the renderer's `TextMorph`).
    public var text: [MorphText] = []
    /// Frame shapes whose outline turns from another geometry into their own (the renderer's `PathMorph`).
    public var paths: [MorphPath] = []

    public init() {}

    /// Opacity of shape `id` of the frame.
    public func opacityOf(_ id: ShapeId) -> Double { opacity.first { $0.0 == id }?.1 ?? 1.0 }
}

/// A frame shape whose outline morphs from `from` (the old shape's geometry) into its own.
public struct MorphPath: Sendable, Equatable {
    public var id: ShapeId
    public var from: Geom
    /// The boxes of the old and the new shape on their own slides.
    public var fromBox: Xfrm
    public var toBox: Xfrm

    public init(id: ShapeId, from: Geom, fromBox: Xfrm, toBox: Xfrm) {
        self.id = id
        self.from = from
        self.fromBox = fromBox
        self.toBox = toBox
    }
}

/// Two frame shapes whose texts morph by words or characters.
public struct MorphText: Sendable, Equatable {
    /// Frame shape ids: from the old slide, from the new slide.
    public var old: ShapeId
    public var new: ShapeId
    /// The boxes of the two shapes on their own slides.
    public var from: Xfrm
    public var to: Xfrm
    public var chars: Bool

    public init(old: ShapeId, new: ShapeId, from: Xfrm, to: Xfrm, chars: Bool) {
        self.old = old
        self.new = new
        self.from = from
        self.to = to
        self.chars = chars
    }
}

private func mixColor(_ a: Rgba, _ b: Rgba, _ t: Double) -> Rgba {
    func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(rustCast: clampf(lerp(Double(x), Double(y), t), 0.0, 255.0, 0.0).rounded()) }
    return Rgba(r: m(a.r, b.r), g: m(a.g, b.g), b: m(a.b, b.b), a: m(a.a, b.a))
}

private func solidColor(_ ctx: Resolve.Ctx?, _ s: Shape) -> Rgba? {
    guard let ctx else { return nil }
    let (fill, ph) = Resolve.fill(ctx, s)
    if case .solid(let color)? = fill { return ctx.color(color, ph) }
    return nil
}

private func boxOf(_ ctx: Resolve.Ctx?, _ s: Shape) -> Xfrm? {
    if let c = ctx { return Resolve.xfrm(c, s) }
    return s.xfrm
}

/// The content of a shape apart from what Morph interpolates (identity, box and fill).
private func content(_ s: Shape) -> Shape {
    var c = s
    c.id = ShapeId(0)
    c.name = ""
    c.xfrm = nil
    c.fill = nil
    return c
}

/// Whether two shapes differ in their geometry only, and it is drawn as an outline (shapes, pictures,
/// connectors), so the outline can morph.
private func reshaped(_ a: Shape, _ b: Shape) -> Bool {
    func outlined(_ s: Shape) -> Bool {
        switch s.kind {
        case .shape, .picture, .connector: true
        default: false
        }
    }
    guard a.geom != b.geom, outlined(a), outlined(b) else { return false }
    var ca = content(a), cb = content(b)
    ca.geom = .default
    cb.geom = .default
    return ca == cb
}

/// The content of a shape apart from what Morph interpolates, with a picture's crop left out.
private func uncropped(_ s: Shape) -> Shape {
    var c = content(s)
    if case .picture(var fill) = c.kind {
        fill.crop = [0.0, 0.0, 0.0, 0.0]
        c.kind = .picture(fill: fill)
    }
    return c
}

private func cropOf(_ s: Shape) -> [Double] {
    if case .picture(let fill) = s.kind { return fill.crop }
    return [0.0, 0.0, 0.0, 0.0]
}

/// Whether two pictures differ in their crop only (apart from box and fill), so the crop can morph.
private func recropped(_ a: Shape, _ b: Shape) -> Bool {
    guard case .picture = a.kind else { return false }
    return cropOf(a) != cropOf(b) && uncropped(a) == uncropped(b)
}

/// The crop (left, top, right, bottom) of a picture morphing from box `xa` cropped by `ca` to box `xb`
/// cropped by `cb`, when its box is `x` at progress `t`: the whole image moves and scales linearly between
/// where it lies on either slide, and the crop is what of it `x` shows. Falls back to blending the crops
/// when a crop leaves nothing visible.
public func morphCrop(_ ca0: [Double], _ xa: Xfrm, _ cb0: [Double], _ xb: Xfrm, _ x: Xfrm, _ t: Double) -> [Double] {
    func four(_ c: [Double]) -> [Double] { (0 ..< 4).map { c.at($0) ?? 0.0 } }
    let (ca, cb) = (four(ca0), four(cb0))
    // Along one axis: (box start, box size, crop before, crop after) → the crops at `t`.
    func axis(
        _ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double), _ cur: (Double, Double)
    ) -> (Double, Double) {
        let (pa, sa, la, ha) = a
        let (pb, sb, lb, hb) = b
        let (p, s) = cur
        let (va, vb) = (1.0 - la - ha, 1.0 - lb - hb)
        if va <= 1e-6 || vb <= 1e-6 { return (lerp(la, lb, t), lerp(ha, hb, t)) }
        // The whole image: its extent and start on either slide.
        let (ea, eb) = (sa / va, sb / vb)
        let e = lerp(ea, eb, t)
        if !e.isFinite || Swift.abs(e) <= 1e-9 { return (lerp(la, lb, t), lerp(ha, hb, t)) }
        let o = lerp(pa - la * ea, pb - lb * eb, t)
        let lo = (p - o) / e
        return (lo, 1.0 - lo - s / e)
    }
    let (l, r) = axis((xa.x, xa.w, ca[0], ca[2]), (xb.x, xb.w, cb[0], cb[2]), (x.x, x.w))
    let (tp, bt) = axis((xa.y, xa.h, ca[1], ca[3]), (xb.y, xb.h, cb[1], cb[3]), (x.y, x.h))
    let c = [l, tp, r, bt]
    return c.allSatisfy(\.isFinite) ? c : cb
}

/// Morph frame from slide `a` to slide `b` at progress `t` (0...1, eased here). Paired shapes (`morphPairs`)
/// move along `morphXfrm`; when they differ only in solid fill colour the colour blends, when pictures differ
/// only in crop the crop morphs (`morphCrop`), when only in geometry (and fill colour) the outline morphs
/// (`MorphFrame.paths`), otherwise the new shape fades in under the fading old one on the same moving box;
/// with the transition option `words` or `characters` their texts are listed in `MorphFrame.text` to morph
/// word by word or character by character. Unpaired shapes of `a` fade out, unpaired shapes of `b` fade in,
/// and shapes of `b` for which `hiddenB` is true (entrance animations, hidden media) stay out of the frame.
public func morphFrame(_ pres: Presentation, _ a: Slide, _ b: Slide, _ t: Double, _ hiddenB: (ShapeId) -> Bool) -> MorphFrame {
    let s = smooth(clampf(t, 0.0, 1.0, 0.0))
    let ca = Resolve.Ctx.forSlide(pres, a)
    let cb = Resolve.Ctx.forSlide(pres, b)
    let pairs = morphPairs(a, b).filter { !hiddenB($0.1) }
    var next: UInt32 = 1
    walk(a.shapes) { x, _ in next = Swift.max(next, x.id.rawValue == UInt32.max ? UInt32.max : x.id.rawValue + 1) }
    walk(b.shapes) { x, _ in next = Swift.max(next, x.id.rawValue == UInt32.max ? UInt32.max : x.id.rawValue + 1) }
    var f = MorphFrame()
    f.mix = s
    let by = b.transition?.option ?? ""
    let (byText, chars) = (by == "words" || by == "characters", by == "characters")
    func hasText(_ x: Shape) -> Bool {
        guard let t = x.text, !t.isEmpty else { return false }
        switch x.kind {
        case .group, .table: return false
        default: return true
        }
    }
    var text: [MorphText] = []
    var paths: [MorphPath] = []
    func push(_ sh0: Shape, _ old: Bool, _ op: Double) -> ShapeId {
        let id = ShapeId(next)
        var sh = sh0
        sh.id = id
        next = next == UInt32.max ? UInt32.max : next + 1
        if op < 1.0 { f.opacity.append((id, op)) }
        f.shapes.append((sh, old))
        return id
    }
    for sa in a.shapes where !pairs.contains(where: { $0.0 == sa.id }) {
        _ = push(sa, true, 1.0 - s)
    }
    for sb in b.shapes {
        let pairA = pairs.first { $0.1 == sb.id }.flatMap { p in a.shapes.first { $0.id == p.0 } }
        guard let sa = pairA else {
            if !hiddenB(sb.id) { _ = push(sb, false, s) }
            continue
        }
        let (xa, xb) = (boxOf(ca, sa), boxOf(cb, sb))
        let x: Xfrm? = if let xa, let xb { morphXfrm(xa, xb, s) } else { xb }
        let reshape = reshaped(sa, sb)
        let recrop = recropped(sa, sb)
        if reshape || recrop || content(sa) == content(sb) {
            var m = sb
            m.xfrm = x
            if recrop, case .picture(var fill) = m.kind {
                if let xa, let xb, let x {
                    fill.crop = morphCrop(cropOf(sa), xa, cropOf(sb), xb, x, s)
                } else {
                    let (c0, c1) = (cropOf(sa), cropOf(sb))
                    fill.crop = (0 ..< 4).map { lerp(c0.at($0) ?? 0.0, c1.at($0) ?? 0.0, s) }
                }
                m.kind = .picture(fill: fill)
            }
            if let fa = solidColor(ca, sa), let fb = solidColor(cb, sb), fa != fb {
                m.fill = Fill.solid(ColorRef.rgb(mixColor(fa, fb, s)))
            }
            let id = push(m, false, 1.0)
            if reshape, let fromBox = xa, let toBox = xb {
                paths.append(MorphPath(id: id, from: sa.geom, fromBox: fromBox, toBox: toBox))
            }
        } else {
            var nb = sb
            nb.xfrm = x
            var oa = sa
            oa.xfrm = x
            let new = push(nb, false, s)
            let old = push(oa, true, 1.0 - s)
            // The same text in shapes that differ otherwise (a title slide's centred title and a content
            // slide's title: other placeholder, size, alignment) moves and resizes word by word even with the
            // Objects option, as PowerPoint does, instead of cross-fading.
            let sameText = trimmedEqual(textOf(sa), textOf(sb))
            if byText || sameText, hasText(sa), hasText(sb), let from = boxOf(ca, sa), let to = boxOf(cb, sb) {
                text.append(MorphText(old: old, new: new, from: from, to: to, chars: chars))
            }
        }
    }
    f.text = text
    f.paths = paths
    return f
}
