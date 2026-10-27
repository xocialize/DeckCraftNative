// DCAnim — geometry for transition effects: easing, 3-D cards, opacity fields, polygons. Port of deckcraft
// crates/anim/src/transition_geom.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import Darwin

// MARK: easing

/// Smoothstep ease in-out (PowerPoint's fades).
@inline(__always) func ss(_ x: Double) -> Double { smooth(x) }

/// Quadratic ease in-out: velocity ramps up for the first half and down for the second (PowerPoint's moves:
/// Push, Cover, Uncover, Pan…).
@inline(__always) func q2(_ x: Double) -> Double { ease(x, 0.5, 0.5, 0.0) }

/// Power ease in-out of degree `n` (2: quadratic, 3: cubic, 4: quartic).
func powInOut(_ x0: Double, _ n: Double) -> Double {
    let x = x0.clamped(0.0, 1.0)
    return x < 0.5 ? 0.5 * Darwin.pow(2.0 * x, n) : 1.0 - 0.5 * Darwin.pow(2.0 - 2.0 * x, n)
}

/// Quadratic ease-in.
func ein(_ x0: Double) -> Double {
    let x = x0.clamped(0.0, 1.0)
    return x * x
}

/// Quadratic ease-out.
func eout(_ x0: Double) -> Double {
    let x = 1.0 - x0.clamped(0.0, 1.0)
    return 1.0 - x * x
}

/// Progress through the window [a, b] of t, clamped to 0...1.
func win(_ t: Double, _ a: Double, _ b: Double) -> Double {
    if b <= a { return t >= b ? 1.0 : 0.0 }
    return ((t - a) / (b - a)).clamped(0.0, 1.0)
}

// MARK: randomness

func hash64(_ x0: UInt64) -> UInt64 {
    var x = x0 &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    return x ^ (x >> 31)
}

/// Deterministic pseudo-random value in [0, 1).
func rnd(_ i: UInt64) -> Double {
    Double(hash64(i) >> 11) / Double(UInt64(1) << 53)
}

// MARK: 2-D

func offset(_ r: R, _ dx: Double, _ dy: Double) -> R {
    R(r[0] + dx, r[1] + dy, r[2] + dx, r[3] + dy)
}

func center(_ r: R) -> P {
    P((r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0)
}

func scaleRect(_ r: R, _ s: Double) -> R { scaleRectAbout(r, s, center(r)) }

func scaleRectAbout(_ r: R, _ s: Double, _ c: P) -> R {
    R(c[0] + (r[0] - c[0]) * s, c[1] + (r[1] - c[1]) * s, c[0] + (r[2] - c[0]) * s, c[1] + (r[3] - c[1]) * s)
}

/// The whole source moved by (dx, dy).
func moved(_ source: Source, _ dx: Double, _ dy: Double, _ alpha: Double) -> Layer {
    Layer.rect(source, fullRect, offset(fullRect, dx, dy), alpha)
}

/// The whole source scaled by `s` about (cx, cy) and moved.
func scaled(_ source: Source, _ s: Double, _ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double, _ alpha: Double) -> Layer {
    Layer.rect(source, fullRect, offset(scaleRectAbout(fullRect, s, P(cx, cy)), dx, dy), alpha)
}

/// The sine and cosine of `x` as deckcraft's release build computes them wherever it needs both of one value
/// (`f64::sin_cos`, or `sin` and `cos` side by side): LLVM fuses the two calls into one `__sincos_stret`, whose
/// results differ from separate `sin` and `cos` in the last bit for about one value in 700.
@inline(__always)
func sinCos(_ x: Double) -> (Double, Double) {
    let r = __sincos_stret(x)
    return (r.__sinval, r.__cosval)
}

/// Rust's `f64::sin_cos` of an angle in degrees, as `deg.to_radians().sin_cos()`.
@inline(__always)
func sinCosDeg(_ deg: Double) -> (Double, Double) { sinCos(deg.toRadians) }

/// Rotate a point about a pivot by `deg` (clockwise on screen), in a slide `a` wide per unit of height, so
/// angles and shapes stay true.
func rot(_ p: P, _ c: P, _ deg: Double, _ a: Double) -> P {
    let (s, co) = sinCosDeg(deg)
    let (x, y) = ((p[0] - c[0]) * a, p[1] - c[1])
    return P(c[0] + (x * co - y * s) / a, c[1] + x * s + y * co)
}

func rotQuad(_ q: Quad, _ c: P, _ deg: Double, _ a: Double) -> Quad {
    Quad(rot(q[0], c, deg, a), rot(q[1], c, deg, a), rot(q[2], c, deg, a), rot(q[3], c, deg, a))
}

/// Motion direction of an option: l, r, u, d and diagonals.
func dir(_ opt: String, _ fallback: (Double, Double)) -> (Double, Double) {
    var d = (0.0, 0.0)
    if opt.bytesContain("l") { d.0 = -1.0 }
    if opt.bytesContain("r") { d.0 = 1.0 }
    if opt.bytesContain("u") { d.1 = -1.0 }
    if opt.bytesContain("d") { d.1 = 1.0 }
    return d == (0.0, 0.0) ? fallback : d
}

/// A rectangle with a soft border `f` wide (slide units) fading out to nothing: the rectangle at full
/// opacity, four edge ramps and four corner ramps. `src` maps onto `dst`; the border samples the texture's
/// edge.
func softRect(_ source: Source, _ src: R, _ dst: R, _ f: Double, _ alpha: Double) -> [Layer] {
    var v = [Layer.rect(source, src, dst, alpha)]
    if f <= 1e-6 { return v }
    let (l, t, r, b) = (dst[0], dst[1], dst[2], dst[3])
    let (fx, fy) = (f, f * 16.0 / 9.0)
    func uvAt(_ x: Double, _ y: Double) -> P {
        let u = r > l ? src[0] + (x.clamped(l, r) - l) / (r - l) * (src[2] - src[0]) : src[0]
        let w = b > t ? src[1] + (y.clamped(t, b) - t) / (b - t) * (src[3] - src[1]) : src[1]
        return P(u, w)
    }
    func q(_ pts: Quad, _ fade: SIMD4<Double>) {
        let uv = pts.map { uvAt($0[0], $0[1]) }
        let xs = uv.corners.map { $0[0] }
        let ys = uv.corners.map { $0[1] }
        func mn(_ a: [Double]) -> Double { a.reduce(Double.infinity) { $0.rustMin($1) } }
        func mx(_ a: [Double]) -> Double { a.reduce(-Double.infinity) { $0.rustMax($1) } }
        v.append(Layer(source: source, src: R(mn(xs), mn(ys), mx(xs), mx(ys)), quad: pts, uv: uv, alpha: alpha, fade: fade))
    }
    q(Quad(P(l, t - fy), P(r, t - fy), P(r, t), P(l, t)), SIMD4(0.0, 0.0, 1.0, 1.0))
    q(Quad(P(l, b), P(r, b), P(r, b + fy), P(l, b + fy)), SIMD4(1.0, 1.0, 0.0, 0.0))
    q(Quad(P(l - fx, t), P(l, t), P(l, b), P(l - fx, b)), SIMD4(0.0, 1.0, 1.0, 0.0))
    q(Quad(P(r, t), P(r + fx, t), P(r + fx, b), P(r, b)), SIMD4(1.0, 0.0, 0.0, 1.0))
    q(Quad(P(l - fx, t - fy), P(l, t - fy), P(l, t), P(l - fx, t)), SIMD4(0.0, 0.0, 1.0, 0.0))
    q(Quad(P(r, t - fy), P(r + fx, t - fy), P(r + fx, t), P(r, t)), SIMD4(0.0, 0.0, 0.0, 1.0))
    q(Quad(P(r, b), P(r + fx, b), P(r + fx, b + fy), P(r, b + fy)), SIMD4(1.0, 0.0, 0.0, 0.0))
    q(Quad(P(l - fx, b), P(l, b), P(l, b + fy), P(l - fx, b + fy)), SIMD4(0.0, 1.0, 0.0, 0.0))
    return v
}

// MARK: opacity fields

/// The source shown in place through an opacity field `f(x, y)` (0...1) sampled on an `n` × `m` grid: each
/// cell is a quad with its corners' opacities. Cells with nothing to show are left out and runs of fully
/// opaque cells merge, so most frames stay small.
func field(_ source: Source, _ n0: Int, _ m0: Int, _ f: (Double, Double) -> Double) -> [Layer] {
    let n = Swift.min(Swift.max(n0, 1), 256), m = Swift.min(Swift.max(m0, 1), 256)
    var vals = [Double](repeating: 0.0, count: (n + 1) * (m + 1))
    for j in 0 ... m {
        for i in 0 ... n {
            let v = f(Double(i) / Double(n), Double(j) / Double(m))
            vals[j * (n + 1) + i] = v.isFinite ? v.clamped(0.0, 1.0) : 0.0
        }
    }
    func at(_ i: Int, _ j: Int) -> Double { vals.at(j * (n + 1) + i) ?? 0.0 }
    var out: [Layer] = []
    for j in 0 ..< m {
        let (y0, y1) = (Double(j) / Double(m), Double(j + 1) / Double(m))
        var run: Int?
        for i in 0 ... n {
            let full = i < n && at(i, j) >= 1.0 && at(i + 1, j) >= 1.0 && at(i, j + 1) >= 1.0 && at(i + 1, j + 1) >= 1.0
            if full {
                if run == nil { run = i }
                continue
            }
            if let s = run {
                run = nil
                out.append(Layer.inplace(source, R(Double(s) / Double(n), y0, Double(i) / Double(n), y1), 1.0))
            }
            if i == n { break }
            let c = SIMD4(at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1))
            if c[0] <= 0.0 && c[1] <= 0.0 && c[2] <= 0.0 && c[3] <= 0.0 { continue }
            out.append(Layer.inplace(source, R(Double(i) / Double(n), y0, Double(i + 1) / Double(n), y1), 1.0).faded(c))
        }
    }
    return out
}

/// Opacity of a soft edge at position `p` when the edge's middle is at `c` and it ramps over `w`.
func edge(_ c: Double, _ p: Double, _ w: Double) -> Double {
    if w <= 1e-9 { return p <= c ? 1.0 : 0.0 }
    return ((c - p) / w + 0.5).clamped(0.0, 1.0)
}

/// Point on the unit square's boundary seen from its centre at angle `ang` (radians, clockwise from 12
/// o'clock, measured on a slide `a` wide per unit of height).
func boundary(_ ang: Double, _ a: Double) -> P {
    let (s, c) = sinCos(ang)
    let (dx, dy) = (s / a, -c)
    let m = (Swift.abs(dx) / 0.5).rustMax(Swift.abs(dy) / 0.5).rustMax(1e-9)
    return P(0.5 + dx / m, 0.5 + dy / m)
}

/// The source shown in place through an angular opacity field `f(angle)` (radians clockwise from 12
/// o'clock, 0...2π): a fan of thin wedges from the centre.
func fan(_ source: Source, _ a: Double, _ steps: Int, _ f: (Double) -> Double) -> [Layer] {
    let n = Swift.min(Swift.max(steps, 8), 720)
    var angles: [Double] = (0 ... n).map { 2.0 * Double.pi * Double($0) / Double(n) }
    // The square's corners, so wedges reach them.
    for c in [P(1.0, 0.0), P(1.0, 1.0), P(0.0, 1.0), P(0.0, 0.0)] {
        let ang = Darwin.atan2((c[0] - 0.5) * a, -(c[1] - 0.5))
        angles.append(ang.remEuclid(2.0 * Double.pi))
    }
    angles = angles.stableSorted { $0.totalLess($1) }
    var dedup: [Double] = []
    for x in angles {
        if let last = dedup.last, Swift.abs(x - last) < 1e-9 { continue }
        dedup.append(x)
    }
    var out: [Layer] = []
    let c = P(0.5, 0.5)
    for k in 0 ..< Swift.max(dedup.count - 1, 0) {
        let (x, y) = (dedup[k], dedup[k + 1])
        let (fx, fy) = (f(x).clamped(0.0, 1.0), f(y).clamped(0.0, 1.0))
        if fx <= 0.0 && fy <= 0.0 { continue }
        let (bx, by) = (boundary(x, a), boundary(y, a))
        out.append(Layer.triUV(source, (c, bx, by), (c, bx, by), ((fx + fy) / 2.0, fx, fy), 1.0))
    }
    return out
}

// MARK: polygons

/// Keep the part of a convex polygon where `n · p <= d`.
func clipPoly(_ poly: [P], _ n: P, _ d: Double) -> [P] {
    var out: [P] = []
    out.reserveCapacity(poly.count + 2)
    func side(_ p: P) -> Double { n[0] * p[0] + n[1] * p[1] - d }
    for (i, p) in poly.enumerated() {
        let q = poly.at((i + 1) % poly.count) ?? p
        let (sp, sq) = (side(p), side(q))
        if sp <= 0.0 { out.append(p) }
        if (sp < 0.0 && sq > 0.0) || (sp > 0.0 && sq < 0.0) {
            let k = sp / (sp - sq)
            out.append(P(p[0] + (q[0] - p[0]) * k, p[1] + (q[1] - p[1]) * k))
        }
    }
    return out
}

/// A convex polygon as triangles: vertices drawn at `map(p)` with texture coordinate `p`.
func polyLayers(_ source: Source, _ poly: [P], _ alpha: Double, _ map: (P) -> P) -> [Layer] {
    guard let first = poly.first, poly.count >= 3 else { return [] }
    return (1 ..< poly.count - 1).map { k in
        let (b, c) = (poly[k], poly[k + 1])
        return Layer.triUV(source, (map(first), map(b), map(c)), (first, b, c), (1.0, 1.0, 1.0), alpha)
    }
}

func rectPoly(_ r: R) -> [P] { corners(r).corners }

// MARK: 3-D

/// A point in the 3-D scene: x right and y down in slide heights (the slide spans x ∈ [−a/2, a/2],
/// y ∈ [−½, ½] at z = 0), z away from the viewer.
struct V3: Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    func add(_ o: V3) -> V3 { v3(x + o.x, y + o.y, z + o.z) }
    func sub(_ o: V3) -> V3 { v3(x - o.x, y - o.y, z - o.z) }

    /// Rotate about the vertical axis through `c` (degrees; positive turns the right side away).
    func yaw(_ c: V3, _ deg: Double) -> V3 {
        let (s, co) = sinCosDeg(deg)
        let p = sub(c)
        return v3(p.x * co - p.z * s, p.y, p.x * s + p.z * co).add(c)
    }

    /// Rotate about the horizontal axis through `c` (degrees; positive turns the top away).
    func pitch(_ c: V3, _ deg: Double) -> V3 {
        let (s, co) = sinCosDeg(deg)
        let p = sub(c)
        return v3(p.x, p.y * co + p.z * s, -p.y * s + p.z * co).add(c)
    }

    /// Rotate in the screen plane about `c` (degrees, clockwise).
    func roll(_ c: V3, _ deg: Double) -> V3 {
        let (s, co) = sinCosDeg(deg)
        let p = sub(c)
        return v3(p.x * co - p.y * s, p.x * s + p.y * co, p.z).add(c)
    }
}

@inline(__always) func v3(_ x: Double, _ y: Double, _ z: Double) -> V3 { V3(x: x, y: y, z: z) }

/// Four 3-D corners: tl, tr, br, bl.
struct Corners3: Sendable {
    var c0: V3
    var c1: V3
    var c2: V3
    var c3: V3

    init(_ c0: V3, _ c1: V3, _ c2: V3, _ c3: V3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    subscript(_ i: Int) -> V3 {
        switch i {
        case 0: c0
        case 1: c1
        case 2: c2
        default: c3
        }
    }

    func map(_ f: (V3) -> V3) -> Corners3 { Corners3(f(c0), f(c1), f(c2), f(c3)) }

    var all: [V3] { [c0, c1, c2, c3] }
}

/// A perspective camera looking at the slide plane from `d` slide heights away.
struct Cam: Sendable {
    var a: Double
    var d: Double

    func p(_ v: V3) -> P {
        let k = d / (d + v.z).rustMax(d * 0.02)
        return P(v.x * k / a + 0.5, v.y * k + 0.5)
    }

    /// The 3-D corners (tl, tr, br, bl) of the unit-space rectangle `r` lying on the slide plane.
    func rect(_ r: R) -> Corners3 {
        let q = corners(r)
        func f(_ p: P) -> V3 { v3((p[0] - 0.5) * a, p[1] - 0.5, 0.0) }
        return Corners3(f(q[0]), f(q[1]), f(q[2]), f(q[3]))
    }

    /// The unit-space point of a 3-D point on the slide plane.
    func unit(_ x: Double, _ y: Double) -> V3 { v3((x - 0.5) * a, y - 0.5, 0.0) }

    func quad(_ c: Corners3) -> Quad { Quad(p(c[0]), p(c[1]), p(c[2]), p(c[3])) }
}

/// Signed area of a quad (positive: front side facing the viewer).
func area(_ q: Quad) -> Double {
    var s = 0.0
    for i in 0 ..< 4 {
        let (a, b) = (q[i], q[(i + 1) % 4])
        s += a[0] * b[1] - b[0] * a[1]
    }
    return s / 2.0
}

/// A card: `src` of the source mapped onto 3-D corners, if it faces the viewer; `shade` (0...1) darkens it.
/// Seen from behind it is left out unless `back` is set (then drawn mirrored).
func card(_ cam: Cam, _ source: Source, _ src: R, _ c: Corners3, _ alpha: Double, _ shade: Double, _ back: Bool) -> [Layer] {
    let q = cam.quad(c)
    if !q.corners.allSatisfy({ $0[0].isFinite && $0[1].isFinite }) { return [] }
    let front = area(q) > 0.0
    if !front && !back { return [] }
    let l = Layer.quad(source, src, q, alpha)
    var v = [l]
    if shade > 0.001 { v.append(l.shade(shade)) }
    return v
}

/// How much a card facing along `n` (unit normal toward the viewer is (0, 0, −1)) is darkened by the light
/// behind the viewer: 0 facing straight on.
func facingShade(_ c: Corners3, _ k: Double) -> Double {
    let u = c[1].sub(c[0])
    let w = c[3].sub(c[0])
    let n = v3(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
    let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
    if len < 1e-12 { return 0.0 }
    let cos = Swift.abs(n.z / len)
    return (k * (1.0 - cos)).clamped(0.0, 1.0)
}
