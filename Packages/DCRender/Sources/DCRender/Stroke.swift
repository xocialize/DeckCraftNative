// DCRender — outlines: line strokes (caps, joins, dashes, gradients, compound bands), arrowheads and the
// trims under them, picture borders drawn outside, fill opacity and a shadow's own transform. Port of
// deckcraft crates/render/src/lib.rs (`stroke`, `square_dash_ends`, `line_gradient`, `dash_with_caps`,
// `limit_dash_count`, `end_points`, `head_size`, `open_arrow_setback`, `head_trims`, `trim_ends`,
// `arrowheads`, `border_outside`, `outside_line`, `fill_opacity`, `shadow_local`; MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

/// Whether a shape's border is drawn outside its outline: a picture's is, unless the picture is drawn in
/// 3-D (a bevel seen through a 3-D scene), where PowerPoint centres it on the edge as on any shape.
public func borderOutside(_ isPic: Bool, _ effects: Effects?) -> Bool {
    guard isPic else { return false }
    guard let e = effects else { return true }
    return !(e.bevel != nil && (e.raw3d.map { $0.contains("scene3d") } ?? false))
}

/// The line that draws `line` (`lw` wide) outside a picture: twice as wide, so the half outside the
/// outline is the border, with dashes kept their length. Nil for compound lines, whose bands would not
/// survive the doubling (they stay centred on the outline).
public func outsideLine(_ line: Line, _ lw: Double) -> Line? {
    if let c = line.compound, c != .single { return nil }
    var out = line
    out.width = lw * 2.0
    if let d = line.dash {
        let p = d.pattern
        out.dash = .custom(pattern: Swift.stride(from: 0, to: p.count, by: 2).map {
            Pair((p.at($0) ?? 0.0) / 2.0, (p.at($0 + 1) ?? 0.0) / 2.0)
        })
    }
    return out
}

/// How opaque a fill is overall (nil when nothing is filled): a solid colour's alpha, a gradient's mean
/// stop alpha, otherwise opaque.
public func fillOpacity(_ rctx: Resolve.Ctx, _ fill: Fill?, _ ph: Rgba?) -> Double? {
    switch fill {
    case nil, .none_?:
        return nil
    case .solid(let c)?:
        return Double(rctx.color(c, ph).a) / 255.0
    case .gradient(let g)? where !g.stops.isEmpty:
        return g.stops.reduce(-0.0) { $0 + Double(rctx.color($1.color, ph).a) / 255.0 } / Double(g.stops.count)
    default:
        return 1.0
    }
}

/// A shadow's own scale and skew (`sx`, `sy`, `kx`, `ky`) in the shape's space, about the point of the
/// shape's box its alignment names (`algn`: `b` is the middle of the bottom edge, `tl` the top-left
/// corner…), as PowerPoint applies them: skewed, then scaled. A perspective shadow (`algn="b"`, `sy` 23%,
/// `kx` -20°) so lies flat along the shape's bottom edge, not around its middle.
public func shadowLocal(_ sh: Shadow, _ w: Double, _ h: Double) -> Affine {
    let (ax, ay): (Double, Double)
    switch sh.align {
    case "tl": (ax, ay) = (0.0, 0.0)
    case "t": (ax, ay) = (0.5, 0.0)
    case "tr": (ax, ay) = (1.0, 0.0)
    case "l": (ax, ay) = (0.0, 0.5)
    case "r": (ax, ay) = (1.0, 0.5)
    case "bl": (ax, ay) = (0.0, 1.0)
    case "b": (ax, ay) = (0.5, 1.0)
    case "br": (ax, ay) = (1.0, 1.0)
    default: (ax, ay) = (0.5, 0.5)
    }
    let a = Vec2(w * ax, h * ay)
    let (tx, ty) = (Darwin.tan(sh.kx.toRadians), Darwin.tan(sh.ky.toRadians))
    let k = Affine(sh.sx, sh.sy * ty, sh.sx * tx, sh.sy, 0.0, 0.0)
    if !k.isFinite { return .identity }
    return Affine.translate(a) * k * Affine.translate(Vec2(-a.x, -a.y))
}

/// Stroke `path` with `line`. A gradient line is laid out over `extent` (the untrimmed outline the line
/// belongs to; `path` itself when nil).
public func strokeLine(
    _ c: Canvas, _ rctx: Resolve.Ctx, _ line: Line, _ ph: Rgba?, _ path: BezPath, _ extent: BezPath?, _ m: Affine,
    _ lw: Double, _ alpha: Double
) {
    let cap: StrokeCap
    switch line.cap ?? .flat {
    case .flat: cap = .butt
    case .round: cap = .round
    case .square: cap = .square
    }
    let join: StrokeJoin
    switch line.join ?? .round {
    case .round: join = .round
    case .bevel: join = .bevel
    case .miter: join = .miter
    }
    // Hairlines stay visible at any zoom.
    let minW = 0.5 / scaleOf(m).rustMax(1e-6)
    let sw = lw.rustMax(minW)
    // PowerPoint's default miter limit is 8 widths (`a:miter lim="800000"`).
    var sk = StrokeStyle(sw).withCaps(cap).withJoin(join).withMiterLimit(8.0)
    // Square caps on a dashed line square off only the line's own two ends (where a dash is drawn):
    // each dash itself ends flat, as PowerPoint draws them.
    var squareEnds: BezPath?
    if let d = line.dash {
        var pat = d.pattern.map { $0 * lw.rustMax(0.75) }
        pat = dashWithCaps(pat, cap, sw)
        pat = limitDashCount(path, pat)
        if !pat.isEmpty && pat.allSatisfy({ $0 > 0.0 }) {
            if cap == .square {
                sk = sk.withCaps(.butt)
                squareEnds = squareDashEnds(path, pat, sw)
            }
            sk = sk.withDashes(0.0, pat)
        }
    }
    c.setTransform(m)
    switch line.fill {
    case .solid(let col)?:
        c.setPaint(.solid(rctx.color(col, ph), alpha))
    case .gradient(let g)? where !g.stops.isEmpty:
        c.setPaint(lineGradient(rctx, g, ph, extent ?? path, lw, alpha))
    default:
        c.setPaint(.solid(.black, alpha))
    }
    // Compound lines: each band stroked along the path moved to its place across the width.
    let compound = line.compound ?? .single
    if compound != .single && lw * scaleOf(m) >= 1.5 {
        let tolerance = 0.1 / scaleOf(m).rustMax(1e-6)
        for (a, b) in CompoundLine.bands(compound) {
            let d = (-0.5 + (a + b) / 2.0) * lw
            var band = sk
            band.width = (b - a) * lw
            c.setStroke(band)
            c.strokePath(CompoundLine.offset(path, d, tolerance))
        }
        return
    }
    c.setStroke(sk)
    c.strokePath(path)
    if let ends = squareEnds { c.fillPath(ends) }
}

/// The path's sub-paths as segments, each with whether it is closed (a `ClosePath` adds no segment).
private func subpathSegments(_ path: BezPath) -> [(segs: [PathSeg], closed: Bool)] {
    var subs: [(segs: [PathSeg], closed: Bool)] = []
    var last = Point.zero, first = Point.zero
    for el in path.elements {
        let seg: PathSeg
        switch el {
        case .moveTo(let p):
            subs.append(([], false))
            last = p
            first = p
            continue
        case .closePath:
            if !subs.isEmpty { subs[subs.count - 1].closed = true }
            last = first
            continue
        case .lineTo(let p): seg = .line(LineSeg(last, p))
        case .quadTo(let a, let p): seg = .quad(QuadBez(last, a, p))
        case .curveTo(let a, let b, let p): seg = .cubic(CubicBez(last, a, b, p))
        }
        last = seg.end
        if subs.isEmpty { subs.append(([], false)) }
        subs[subs.count - 1].segs.append(seg)
    }
    return subs
}

/// The square caps of a dashed line drawn `width` wide with dash `pattern`: a half-width square past
/// the start of each open sub-path (every dash pattern starts with a dash) and past its end when the
/// pattern is in a dash there.
func squareDashEnds(_ path: BezPath, _ pattern: [Double], _ width: Double) -> BezPath {
    var out = BezPath()
    let period = pattern.reduce(-0.0, +)
    func cap(_ at: Point, _ dir: Vec2) {
        let n = Vec2(-dir.y, dir.x) * (width / 2.0)
        let back = dir * (width / 2.0)
        out.moveTo(at + n)
        out.lineTo(at + n + back)
        out.lineTo(at - n + back)
        out.lineTo(at - n)
        out.closePath()
    }
    func dir(_ seg: PathSeg, _ t0: Double, _ t1: Double) -> Vec2? {
        var d = seg.eval(t1) - seg.eval(t0)
        if !(d.hypot > 1e-9) { d = seg.end - seg.start }
        return d.hypot > 1e-9 ? d.normalize : nil
    }
    // Rust's walk keeps sub-paths that follow a move; the same split, empty ones dropped.
    for (segs, closed) in subpathSegments(path) where !closed && !segs.isEmpty {
        guard let first = segs.first, let end = segs.last else { continue }
        if let d = dir(first, 1e-3, 0.0) { cap(first.start, d) }
        let len = segs.reduce(-0.0) { $0 + $1.arclen(1e-3) }
        if !(period > 0.0 && len.isFinite) { continue }
        var pos = len.truncatingRemainder(dividingBy: period)
        // Ending exactly on a period boundary is the end of a gap.
        var on = pos > period * 1e-6
        for v in pattern {
            if pos <= v { break }
            pos -= v
            on = !on
        }
        if on, let d = dir(end, 1.0 - 1e-3, 1.0) { cap(end.end, d) }
    }
    return out
}

/// A gradient line's paint: laid out, as PowerPoint lays it, over the box the stroke covers (the path's
/// bounds grown by half the line width), so a horizontal line's vertical gradient runs across its width.
func lineGradient(_ rctx: Resolve.Ctx, _ g: Gradient, _ ph: Rgba?, _ path: BezPath, _ lw: Double, _ alpha: Double) -> Paint {
    let bounds = PaintFill.tileBox(path.boundingBox.inflate(lw / 2.0, lw / 2.0), g.tile)
    let stops: [(Double, Rgba)] = g.stops.map { ($0.pos, rctx.color($0.color, ph)) }
    return PaintFill.gradient(g.shape, stops, bounds, alpha)
}

/// A dash pattern (on, off, on, off… lengths) for a line drawn `width` wide with `cap`. As PowerPoint
/// draws them, round caps sit inside each dash's length rather than adding to it: a "round dot" (`sysDot`,
/// one width on and one off) is a row of separate circles, not a solid line. So each dash loses a width
/// (half at each end, where the caps go) and each gap gains it; a dash no longer than the width becomes
/// just its two caps. (Square-capped dashes end flat; see `squareDashEnds`.)
func dashWithCaps(_ pat: [Double], _ cap: StrokeCap, _ width: Double) -> [Double] {
    if cap != .round || pat.count % 2 != 0 || !(width.isFinite && width > 0.0) { return pat }
    return pat.enumerated().map { i, v in i % 2 == 0 ? (v - width).rustMax(width * 1e-3) : v + width }
}

/// The most dashes one stroke is cut into. Stroking expands every dash into its own outline, so a tiny
/// dash on a huge shape would otherwise need gigabytes. Past this count the pattern is scaled up evenly,
/// which looks the same: the dashes are far below a pixel by then.
let maxDashes = 20_000.0

func limitDashCount(_ path: BezPath, _ pat: [Double]) -> [Double] {
    let period = pat.reduce(-0.0, +)
    if !(period.isFinite && period > 0.0) { return pat }
    let len = path.segments.reduce(-0.0) { $0 + $1.arclen(1e-2) }
    let dashes = len / period
    if !len.isFinite { return [] }
    if dashes <= maxDashes { return pat }
    let k = dashes / maxDashes
    return pat.map { $0 * k }
}

/// The first point and the next distinct one, and the last point and the one before it, of `path`'s
/// points (control points included).
func endPoints(_ path: BezPath) -> ((Point, Point), (Point, Point))? {
    var pts: [Point] = []
    for e in path.elements {
        switch e {
        case .moveTo(let p), .lineTo(let p): pts.append(p)
        case .quadTo(let a, let b): pts += [a, b]
        case .curveTo(let a, let b, let c): pts += [a, b, c]
        case .closePath: break
        }
    }
    guard pts.count >= 2, let first = pts.first, let last = pts.last,
          let second0 = pts.at(1), let prev0 = pts.at(pts.count - 2) else { return nil }
    let second = pts.dropFirst().first { ($0 - first).hypot > 1e-6 } ?? second0
    let prev = pts.reversed().dropFirst().first { ($0 - last).hypot > 1e-6 } ?? prev0
    return ((first, second), (last, prev))
}

/// An arrowhead's width and length for a line `lw` wide. PowerPoint sizes them in multiples of the line
/// width (small 2, medium 3, large 5), but never smaller than for a 2 pt line.
func headSize(_ e: LineEnd, _ lw: Double) -> (Double, Double) {
    func sz(_ s: String) -> Double {
        switch s {
        case "sm": 2.0
        case "lg": 5.0
        default: 3.0
        }
    }
    let k = lw.rustMax(2.0)
    return (sz(e.w) * k, sz(e.len) * k)
}

/// How far back from the tip an open arrowhead's legs (`lw` wide) meet along their centre lines:
/// PowerPoint puts the outside of the point, not the legs' centre lines, on the line's end.
func openArrowSetback(_ wl: Double, _ ll: Double, _ lw: Double) -> Double {
    let half = Darwin.atan2(wl / 2.0, ll)
    return Darwin.sin(half) > 1e-6 ? (lw / 2.0 / Darwin.sin(half)).rustMin(ll) : 0.0
}

/// How much of a `lw`-wide line to leave off at its start and end, under its arrowheads: up to a
/// triangle's base, into a stealth arrow's notch far enough for its barbs to cover the line's corners,
/// and to where an open arrow's legs meet. Ovals and diamonds sit on the end itself.
public func headTrims(_ line: Line, _ lw: Double) -> (Double, Double) {
    // A square cap reaches half a width past the line's end: leave that off too.
    let cap = line.cap == .square ? lw / 2.0 : 0.0
    func trim(_ e: LineEnd?) -> Double {
        guard let e else { return 0.0 }
        let (wl, ll) = headSize(e, lw)
        switch e.kind {
        case "triangle": return ll + cap
        case "stealth": return (ll * (0.6 + 0.4 * lw / wl.rustMax(1e-9))).rustMin(ll) + cap
        case "arrow": return openArrowSetback(wl, ll, lw.rustMax(0.75)) + cap
        default: return 0.0
        }
    }
    return (trim(line.head), trim(line.tail))
}

/// `path` with `start` left off the beginning of its first sub-path and `end` off the end of its last
/// (by arc length), where those are open. A sub-path shorter than its trims disappears.
public func trimEnds(_ path: BezPath, _ start: Double, _ end: Double) -> BezPath {
    let acc = 1e-3
    var subs = subpathSegments(path)
    if let firstSub = subs.first, !firstSub.closed, start > 0.0 {
        var segs = firstSub.segs
        var left = start
        var dropCount = 0
        for (i, seg) in segs.enumerated() {
            let l = seg.arclen(acc)
            if l > left {
                let partial = seg.subsegment(seg.invArclen(left, acc), 1.0)
                segs.removeFirst(i)
                segs[0] = partial
                dropCount = 0
                break
            }
            left -= l
            dropCount = i + 1
        }
        if dropCount > 0 { segs.removeFirst(min(dropCount, segs.count)) }
        subs[0].segs = segs
    }
    if let lastSub = subs.last, !lastSub.closed, end > 0.0 {
        var segs = lastSub.segs
        var left = end
        while let seg = segs.last {
            let l = seg.arclen(acc)
            if l > left {
                segs[segs.count - 1] = seg.subsegment(0.0, seg.invArclen(l - left, acc))
                break
            }
            left -= l
            segs.removeLast()
        }
        subs[subs.count - 1].segs = segs
    }
    var out = BezPath()
    for (segs, closed) in subs {
        guard let s0 = segs.first else { continue }
        out.moveTo(s0.start)
        for seg in segs {
            switch seg {
            case .line(let l): out.lineTo(l.p1)
            case .quad(let q): out.quadTo(q.p1, q.p2)
            case .cubic(let c): out.curveTo(c.p1, c.p2, c.p3)
            }
        }
        if closed { out.closePath() }
    }
    return out
}

/// The heads and tails of `line` on the first stroked path of `geo` (`rel` maps it to the space the
/// heads are sized and drawn in; `m` maps that to the output).
public func arrowheads(_ c: Canvas, _ rctx: Resolve.Ctx, _ line: Line, _ ph: Rgba?, _ geo: Preset.Geometry, _ rel: Affine, _ m: Affine, _ lw: Double) {
    guard let sp = geo.paths.first(where: { $0.stroke }), let ((a0, a20), (b0, b20)) = endPoints(sp.path) else { return }
    // The outline's ends in the space the arrowheads are sized and drawn in.
    let (a, a2, b, b2) = (rel * a0, rel * a20, rel * b0, rel * b20)
    var col = Rgba.black
    if case .solid(let cr)? = line.fill { col = rctx.color(cr, ph) }
    // A gradient line's heads take the gradient where they are.
    var grad: Paint?
    if case .gradient(let g)? = line.fill, !g.stops.isEmpty {
        grad = lineGradient(rctx, g, ph, transformed(sp.path, rel), lw, 1.0)
    }
    func setPaint() { c.setPaint(grad ?? .solid(col, 1.0)) }
    for (end, tip, from) in [(line.head, a, a2), (line.tail, b, b2)] {
        guard let e = end, !rustEqual(e.kind, "none") else { continue }
        let (wl, ll) = headSize(e, lw)
        let dir = (tip - from).normalize
        if !dir.x.isFinite { continue }
        let n = Vec2(-dir.y, dir.x)
        let base = tip - dir * ll
        var p = BezPath()
        switch e.kind {
        case "oval":
            p = Ellipse(center: tip, radii: Vec2(ll / 2.0, wl / 2.0), xRotation: Darwin.atan2(dir.y, dir.x)).path(0.05)
        case "diamond":
            p.moveTo(tip + dir * ll / 2.0)
            p.lineTo(tip + n * wl / 2.0)
            p.lineTo(tip - dir * ll / 2.0)
            p.lineTo(tip - n * wl / 2.0)
            p.closePath()
        case "stealth":
            p.moveTo(tip)
            p.lineTo(base + n * wl / 2.0)
            p.lineTo(tip - dir * ll * 0.6)
            p.lineTo(base - n * wl / 2.0)
            p.closePath()
        case "arrow":
            // Legs the line's width with round ends, meeting in a sharp point whose outside is on the
            // line's end.
            let leg = lw.rustMax(0.75)
            let back = dir * openArrowSetback(wl, ll, leg)
            var o = BezPath()
            o.moveTo(base + n * wl / 2.0 - back)
            o.lineTo(tip - back)
            o.lineTo(base - n * wl / 2.0 - back)
            c.setTransform(m)
            setPaint()
            c.setStroke(StrokeStyle(leg).withJoin(.miter).withMiterLimit(100.0).withCaps(.round))
            c.strokePath(o)
            continue
        default:
            p.moveTo(tip)
            p.lineTo(base + n * wl / 2.0)
            p.lineTo(base - n * wl / 2.0)
            p.closePath()
        }
        c.setTransform(m)
        setPaint()
        c.fillPath(p)
    }
}
