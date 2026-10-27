// DCGeometry — kurbo pieces the renderer needs beyond what deckcraft-geom uses: arc length and its
// inverse (`ParamCurveArclen`, Gauss–Legendre quadrature, `solve_itp`), sub-segments, cubic subdivision,
// `solve_cubic`, quadratic nearest point, `Circle`, cusp regularisation, inflections, cubic offsetting
// (`offset::offset_cubic`), `Affine::svd` and `Ellipse`. Ported from kurbo 0.13.1 (MIT OR Apache-2.0,
// © the kurbo authors: common.rs, line.rs, quadbez.rs, cubicbez.rs, bezpath.rs, offset.rs, affine.rs,
// ellipse.rs, arc.rs), keeping its formulas and operand order.
import DCCore
import Darwin

// MARK: - Gauss–Legendre tables (kurbo common.rs)

let gaussLegendre8: [(Double, Double)] = [
    (0.3626837833783620, -0.1834346424956498), (0.3626837833783620, 0.1834346424956498),
    (0.3137066458778873, -0.5255324099163290), (0.3137066458778873, 0.5255324099163290),
    (0.2223810344533745, -0.7966664774136267), (0.2223810344533745, 0.7966664774136267),
    (0.1012285362903763, -0.9602898564975363), (0.1012285362903763, 0.9602898564975363),
]

let gaussLegendre8Half: [(Double, Double)] = [
    (0.3626837833783620, 0.1834346424956498), (0.3137066458778873, 0.5255324099163290),
    (0.2223810344533745, 0.7966664774136267), (0.1012285362903763, 0.9602898564975363),
]

let gaussLegendre16Half: [(Double, Double)] = [
    (0.1894506104550685, 0.0950125098376374), (0.1826034150449236, 0.2816035507792589),
    (0.1691565193950025, 0.4580167776572274), (0.1495959888165767, 0.6178762444026438),
    (0.1246289712555339, 0.7554044083550030), (0.0951585116824928, 0.8656312023878318),
    (0.0622535239386479, 0.9445750230732326), (0.0271524594117541, 0.9894009349916499),
]

let gaussLegendre24Half: [(Double, Double)] = [
    (0.1279381953467522, 0.0640568928626056), (0.1258374563468283, 0.1911188674736163),
    (0.1216704729278034, 0.3150426796961634), (0.1155056680537256, 0.4337935076260451),
    (0.1074442701159656, 0.5454214713888396), (0.0976186521041139, 0.6480936519369755),
    (0.0861901615319533, 0.7401241915785544), (0.0733464814110803, 0.8200019859739029),
    (0.0592985849154368, 0.8864155270044011), (0.0442774388174198, 0.9382745520027328),
    (0.0285313886289337, 0.9747285559713095), (0.0123412297999872, 0.9951872199970213),
]

// MARK: - Solvers (kurbo common.rs)

/// kurbo `solve_itp`: the ITP root finder, returning the midpoint of the final bracket.
public func solveITP(_ f: (Double) -> Double, _ a0: Double, _ b0: Double, _ epsilon: Double, _ n0: Int, _ k1: Double, _ ya0: Double, _ yb0: Double) -> Double {
    var a = a0, b = b0, ya = ya0, yb = yb0
    let n12 = asUsize(fmax(((b - a) / epsilon).log2Ceil - 1.0, 0.0))
    let nmax = n0 + n12
    // `(1u64 << nmax) as f64`; a shift past 63 bits is out of Rust's range too, so cap it.
    var scaledEpsilon = epsilon * (nmax < 64 ? Double(UInt64(1) << UInt64(nmax)) : Double.infinity)
    var guardCount = 0
    while b - a > 2.0 * epsilon {
        guardCount += 1
        if guardCount > 10_000 { break }
        let x12 = 0.5 * (a + b)
        let r = scaledEpsilon - 0.5 * (b - a)
        let xf = (yb * a - ya * b) / (yb - ya)
        let sigma = x12 - xf
        let delta = k1 * ((b - a) * (b - a))
        let xt = delta <= Swift.abs(x12 - xf) ? xf + delta.copysign(sigma) : x12
        let xitp = Swift.abs(xt - x12) <= r ? xt : x12 - r.copysign(sigma)
        let yitp = f(xitp)
        if yitp > 0.0 {
            b = xitp
            yb = yitp
        } else if yitp < 0.0 {
            a = xitp
            ya = yitp
        } else {
            a = xitp
            b = xitp
            break
        }
        scaledEpsilon *= 0.5
    }
    return 0.5 * (a + b)
}

extension Double {
    /// `self.log2().ceil()`.
    fileprivate var log2Ceil: Double { Darwin.log2(self).rounded(.up) }
}

/// kurbo `solve_cubic`: real roots of c0 + c1·x + c2·x² + c3·x³ (fused multiply-adds as kurbo's `mul_add`).
func solveCubic(_ c0In: Double, _ c1In: Double, _ c2In: Double, _ c3: Double) -> [Double] {
    let c3Recip = 1.0 / c3
    let oneThird = 1.0 / 3.0
    let scaledC2 = c2In * (oneThird * c3Recip)
    let scaledC1 = c1In * (oneThird * c3Recip)
    let scaledC0 = c0In * c3Recip
    if !(scaledC0.isFinite && scaledC1.isFinite && scaledC2.isFinite) {
        return solveQuadratic(c0In, c1In, c2In)
    }
    let (c0, c1, c2) = (scaledC0, scaledC1, scaledC2)
    let d0 = c1.addingProduct(-c2, c2)
    let d1 = c0.addingProduct(-c1, c2)
    let d2 = c2 * c0 - c1 * c1
    let d = 4.0 * d0 * d2 - d1 * d1
    let de = d1.addingProduct(-2.0 * c2, d0)
    if d < 0.0 {
        let sq = (-0.25 * d).squareRoot()
        let r = -0.5 * de
        let t1 = Darwin.cbrt(r + sq) + Darwin.cbrt(r - sq)
        return [t1 - c2]
    } else if d == 0.0 {
        let t1 = (-d0).squareRoot().copysign(de)
        return [t1 - c2, -2.0 * t1 - c2]
    }
    let th = Darwin.atan2(d.squareRoot(), -de) * oneThird
    let (thSin, thCos) = sinCos(th)
    let r0 = thCos
    let ss3 = thSin * Double(3.0).squareRoot()
    let r1 = 0.5 * (-thCos + ss3)
    let r2 = 0.5 * (-thCos - ss3)
    let t = 2.0 * (-d0).squareRoot()
    return [(-c2).addingProduct(t, r0), (-c2).addingProduct(t, r1), (-c2).addingProduct(t, r2)]
}

// MARK: - Vec2 extras

extension Vec2 {
    /// kurbo `Vec2::rotate_scale`: complex multiplication.
    public func rotateScale(_ rhs: Vec2) -> Vec2 { Vec2(x * rhs.x - y * rhs.y, x * rhs.y + y * rhs.x) }
    public var lengthSquared: Double { hypot2 }
}

// MARK: - Sub-segments, subdivision, raise

extension LineSeg {
    public func subsegment(_ t0: Double, _ t1: Double) -> LineSeg { LineSeg(eval(t0), eval(t1)) }
    public var start: Point { p0 }
    public var end: Point { p1 }
}

extension QuadBez {
    public func subsegment(_ t0: Double, _ t1: Double) -> QuadBez {
        let p0 = eval(t0)
        let p2 = eval(t1)
        let p1 = p0 + (p1 - self.p0).lerp(self.p2 - self.p1, t0) * (t1 - t0)
        return QuadBez(p0, p1, p2)
    }

    /// kurbo `QuadBez::raise`: the same curve as a cubic.
    public func raise() -> CubicBez {
        CubicBez(p0, p0 + (2.0 / 3.0) * (p1 - p0), p2 + (2.0 / 3.0) * (p1 - p2), p2)
    }

    /// kurbo `ParamCurveDeriv` for a quadratic: a line through the scaled control differences.
    var derivLine: LineSeg { LineSeg((2.0 * (p1 - p0)).toPoint, (2.0 * (p2 - p1)).toPoint) }

    /// kurbo `ParamCurveNearest::nearest` (analytic, by cubic root finding): (t, squared distance).
    func nearest(_ p: Point) -> (t: Double, distanceSquared: Double) {
        var rBest: Double?
        var tBest = 0.0
        func evalT(_ t: Double, _ q: Point) {
            let r = (q - p).hypot2
            if rBest.map({ r < $0 }) ?? true {
                rBest = r
                tBest = t
            }
        }
        let d0 = p1 - p0
        let d1 = p0.toVec2 + p2.toVec2 - 2.0 * p1.toVec2
        let d = p0 - p
        let c0 = d.dot(d0)
        let c1 = 2.0 * d0.hypot2 + d.dot(d1)
        let c2 = 3.0 * d1.dot(d0)
        let c3 = d1.hypot2
        let roots = solveCubic(c0, c1, c2, c3)
        var needEnds = roots.isEmpty
        for t in roots {
            if !(0.0 ... 1.0).contains(t) {
                needEnds = true
            } else {
                evalT(t, eval(t))
            }
        }
        if needEnds {
            evalT(0.0, p0)
            evalT(1.0, p2)
        }
        return (tBest, rBest ?? 0)
    }
}

extension CubicBez {
    /// kurbo `CubicBez::subdivide`: the halves, by de Casteljau.
    public func subdivide() -> (CubicBez, CubicBez) {
        let pm = eval(0.5)
        return (
            CubicBez(p0, p0.midpoint(p1), ((p0.toVec2 + p1.toVec2 * 2.0 + p2.toVec2) * 0.25).toPoint, pm),
            CubicBez(pm, ((p1.toVec2 + p2.toVec2 * 2.0 + p3.toVec2) * 0.25).toPoint, p2.midpoint(p3), p3)
        )
    }

    /// kurbo `CubicBez::inflections`: parameters in 0…1 where the curvature changes sign.
    public var inflections: [Double] {
        let a = p1 - p0
        let b = (p2 - p1) - a
        let c = (p3 - p0) - 3.0 * (p2 - p1)
        return solveQuadratic(a.cross(b), a.cross(c), b.cross(c)).filter { $0 >= 0.0 && $0 <= 1.0 }
    }

    private enum CuspType { case loop, doubleInflection }

    private func detectCusp(_ dimension: Double) -> CuspType? {
        let d01 = p1 - p0, d02 = p2 - p0, d03 = p3 - p0, d12 = p2 - p1, d23 = p3 - p2
        let det012 = d01.cross(d02)
        let det123 = d12.cross(d23)
        let det013 = d01.cross(d03)
        let det023 = d02.cross(d03)
        guard det012 * det123 > 0.0 && det012 * det013 < 0.0 && det012 * det023 < 0.0 else { return nil }
        let q = deriv
        let nearest = q.nearest(Point(0, 0))
        let d = q.eval(nearest.t)
        let d2 = q.derivLine.eval(nearest.t)
        let cross = d.toVec2.cross(d2.toVec2)
        let ds = nearest.distanceSquared
        let lhs = ds * ds * ds
        let rhs = (cross * dimension) * (cross * dimension)
        guard lhs <= rhs else { return nil }
        let a = 3.0 * det012 + det023 - 2.0 * det013
        let b = -3.0 * det012 + det013
        let c = det012
        return b * b - 4.0 * a * c > 0.0 ? .doubleInflection : .loop
    }

    /// kurbo `CubicBez::regularize_cusp`: nudges control points away from a near-zero derivative.
    func regularizeCusp(_ dimension: Double) -> CubicBez {
        var c = self
        if let cusp = detectCusp(dimension) {
            let d01 = c.p1 - c.p0
            let d01h = d01.hypot
            let d23 = c.p3 - c.p2
            let d23h = d23.hypot
            switch cusp {
            case .loop:
                c.p1 += (dimension / d01h) * d01
                c.p2 = c.p2 - (dimension / d23h) * d23
            case .doubleInflection:
                if d01h > 2.0 * dimension { c.p1 = c.p1 - (dimension / d01h) * d01 }
                if d23h > 2.0 * dimension { c.p2 += (dimension / d23h) * d23 }
            }
        }
        return c
    }
}

extension PathSeg {
    public func subsegment(_ t0: Double, _ t1: Double) -> PathSeg {
        switch self {
        case .line(let l): .line(l.subsegment(t0, t1))
        case .quad(let q): .quad(q.subsegment(t0, t1))
        case .cubic(let c): .cubic(c.subsegment(t0, t1))
        }
    }

    /// kurbo `PathSeg::tangents`: the start and end tangents (falling back to further control points).
    public var tangents: (Vec2, Vec2) {
        let eps = 1e-12
        switch self {
        case .line(let l):
            let d = l.p1 - l.p0
            return (d, d)
        case .quad(let q):
            let d01 = q.p1 - q.p0
            let d0 = d01.hypot2 > eps ? d01 : q.p2 - q.p0
            let d12 = q.p2 - q.p1
            let d1 = d12.hypot2 > eps ? d12 : q.p2 - q.p0
            return (d0, d1)
        case .cubic(let c):
            let d01 = c.p1 - c.p0
            let d0: Vec2
            if d01.hypot2 > eps {
                d0 = d01
            } else {
                let d02 = c.p2 - c.p0
                d0 = d02.hypot2 > eps ? d02 : c.p3 - c.p0
            }
            let d23 = c.p3 - c.p2
            let d1: Vec2
            if d23.hypot2 > eps {
                d1 = d23
            } else {
                let d13 = c.p3 - c.p1
                d1 = d13.hypot2 > eps ? d13 : c.p3 - c.p0
            }
            return (d0, d1)
        }
    }
}

// MARK: - Arc length (kurbo ParamCurveArclen)

extension LineSeg {
    public func arclen(_ accuracy: Double) -> Double { (p1 - p0).hypot }
    public func invArclen(_ arclen: Double, _ accuracy: Double) -> Double { arclen / (p1 - p0).hypot }
}

extension QuadBez {
    public func arclen(_ accuracy: Double) -> Double {
        let d2 = p0.toVec2 - 2.0 * p1.toVec2 + p2.toVec2
        let a = d2.hypot2
        let d1 = p1 - p0
        let c = d1.hypot2
        if a < 5e-4 * c {
            // Nearly straight: Legendre–Gauss quadrature.
            let v0 = (-0.492943519233745 * p0.toVec2 + 0.430331482911935 * p1.toVec2 + 0.0626120363218102 * p2.toVec2).hypot
            let v1 = ((p2 - p0) * 0.4444444444444444).hypot
            let v2 = (-0.0626120363218102 * p0.toVec2 - 0.430331482911935 * p1.toVec2 + 0.492943519233745 * p2.toVec2).hypot
            return v0 + v1 + v2
        }
        let b = 2.0 * d2.dot(d1)
        let sabc = (a + b + c).squareRoot()
        let a2 = Darwin.pow(a, -0.5)
        let a32 = a2 * a2 * a2
        let c2 = 2.0 * c.squareRoot()
        let bac2 = b * a2 + c2
        let v0 = 0.25 * a2 * a2 * b * (2.0 * sabc - c2) + sabc
        if bac2 * a2 < 1e-13 { return v0 }
        return v0 + 0.25 * a32 * (4.0 * c * a - b * b) * Darwin.log(((2.0 * a + b) * a2 + 2.0 * sabc) / bac2)
    }

    public func invArclen(_ arclen: Double, _ accuracy: Double) -> Double {
        genericInvArclen(arclen, accuracy, total: self.arclen(accuracy)) { self.subsegment($0, $1).arclen($2) }
    }
}

private func arclenQuadratureCore(_ coeffs: [(Double, Double)], _ dm: Vec2, _ dm1: Vec2, _ dm2: Vec2) -> Double {
    var sum = 0.0
    for (wi, xi) in coeffs {
        let d = dm + dm2 * (xi * xi)
        let dpx = (d + dm1 * xi).hypot
        let dmx = (d - dm1 * xi).hypot
        sum += (Double(2.25).squareRoot() * wi) * (dpx + dmx)
    }
    return sum
}

private func arclenRec(_ c: CubicBez, _ accuracy: Double, _ depth: Int) -> Double {
    let d03 = c.p3 - c.p0
    let d01 = c.p1 - c.p0
    let d12 = c.p2 - c.p1
    let d23 = c.p3 - c.p2
    let lpLc = d01.hypot + d12.hypot + d23.hypot - d03.hypot
    let dd1 = d12 - d01
    let dd2 = d23 - d12
    let dm = 0.25 * (d01 + d23) + 0.5 * d12
    let dm1 = 0.5 * (dd2 + dd1)
    let dm2 = 0.25 * (dd2 - dd1)
    var est = 0.0
    for (wi, xi) in gaussLegendre8 {
        let dNorm2 = (dm + dm1 * xi + dm2 * (xi * xi)).hypot2
        let ddNorm2 = (dm1 + dm2 * (2.0 * xi)).hypot2
        est += wi * (ddNorm2 / dNorm2)
    }
    let est3 = est * est * est
    let gauss8Err = fmin(est3 * 2.5e-6, 3e-2) * lpLc
    if gauss8Err < accuracy { return arclenQuadratureCore(gaussLegendre8Half, dm, dm1, dm2) }
    let gauss16Err = fmin(est3 * est3 * 1.5e-11, 9e-3) * lpLc
    if gauss16Err < accuracy { return arclenQuadratureCore(gaussLegendre16Half, dm, dm1, dm2) }
    let gauss24Err = fmin(est3 * est3 * est3 * 3.5e-16, 3.5e-3) * lpLc
    if gauss24Err < accuracy || depth >= 20 { return arclenQuadratureCore(gaussLegendre24Half, dm, dm1, dm2) }
    let (c0, c1) = c.subdivide()
    return arclenRec(c0, accuracy * 0.5, depth + 1) + arclenRec(c1, accuracy * 0.5, depth + 1)
}

extension CubicBez {
    /// Arc length by adaptive subdivision with Legendre–Gauss quadrature (kurbo).
    public func arclen(_ accuracy: Double) -> Double { arclenRec(self, accuracy, 0) }

    public func invArclen(_ arclen: Double, _ accuracy: Double) -> Double {
        genericInvArclen(arclen, accuracy, total: self.arclen(accuracy)) { self.subsegment($0, $1).arclen($2) }
    }
}

extension PathSeg {
    public func arclen(_ accuracy: Double) -> Double {
        switch self {
        case .line(let l): l.arclen(accuracy)
        case .quad(let q): q.arclen(accuracy)
        case .cubic(let c): c.arclen(accuracy)
        }
    }

    public func invArclen(_ arclen: Double, _ accuracy: Double) -> Double {
        switch self {
        case .line(let l): l.invArclen(arclen, accuracy)
        case .quad(let q): q.invArclen(arclen, accuracy)
        case .cubic(let c): c.invArclen(arclen, accuracy)
        }
    }
}

/// kurbo's default `ParamCurveArclen::inv_arclen`: ITP on the arc length of sub-segments, measured
/// incrementally from the last point.
private func genericInvArclen(_ arclen: Double, _ accuracy: Double, total: Double, _ sub: (Double, Double, Double) -> Double) -> Double {
    if arclen <= 0.0 { return 0.0 }
    if arclen >= total { return 1.0 }
    var tLast = 0.0
    var arclenLast = 0.0
    let epsilon = accuracy / total
    let n = 1.0 - fmin(Darwin.log2(epsilon).rounded(.up), 0.0)
    let inner = accuracy / n
    let f: (Double) -> Double = { t in
        let (lo, hi, dir) = t > tLast ? (tLast, t, 1.0) : (t, tLast, -1.0)
        let arc = sub(lo, hi, inner)
        arclenLast += arc * dir
        tLast = t
        return arclenLast - arclen
    }
    return solveITP(f, 0.0, 1.0, epsilon, 1, 0.2, -arclen, total - arclen)
}

// MARK: - Affine SVD, Ellipse

extension Affine {
    /// kurbo `Affine::svd`: the singular values (larger first) and the rotation of the first axis.
    public var svd: (scale: Vec2, angle: Double) {
        let (a, b, c, d, _, _) = coeffs
        let a2 = a * a, b2 = b * b, c2 = c * c, d2 = d * d
        let ab = a * b, cd = c * d
        let angle = 0.5 * Darwin.atan2(2.0 * (ab + cd), a2 - b2 + c2 - d2)
        let s1 = ((a + d) * (a + d) + (b - c) * (b - c)).squareRoot()
        let s2 = ((a - d) * (a - d) + (b + c) * (b + c)).squareRoot()
        return (Vec2(0.5 * (s1 + s2), 0.5 * Swift.abs(s1 - s2)), angle)
    }
}

/// kurbo `Ellipse`: a unit circle under an affine map.
public struct Ellipse: Sendable, Hashable {
    public var inner: Affine

    public init(center: Point, radii: Vec2, xRotation: Double) {
        inner = Affine.translate(center.toVec2) * Affine.rotate(xRotation) * Affine.scaleNonUniform(Swift.abs(radii.x), Swift.abs(radii.y))
    }

    public var center: Point { inner.translation.toPoint }

    /// kurbo `Ellipse::path_elements`: a full-turn `Arc` with the SVD radii, not closed.
    public func path(_ tolerance: Double) -> BezPath {
        let (radii, rot) = inner.svd
        return Arc(center, radii, 0.0, 2.0 * Double.pi, rot).path(tolerance)
    }
}

extension Arc {
    /// kurbo `Arc::start`: the point at the start angle.
    public var start: Point {
        let (s, c) = sinCos(startAngle)
        let u = radii.x * c, v = radii.y * s
        let (rs, rc) = sinCos(xRotation)
        return center + Vec2(u * rc - v * rs, u * rs + v * rc)
    }

    /// kurbo `Arc::path_elements`: a move to the start, then the cubics; not closed.
    public func path(_ tolerance: Double) -> BezPath {
        var p = BezPath()
        p.moveTo(start)
        p.extend(appendElements(tolerance))
        return p
    }
}

// MARK: - Circle

/// kurbo `Circle`.
public struct Circle: Sendable, Hashable {
    public var center: Point
    public var radius: Double

    public init(_ center: Point, _ radius: Double) {
        self.center = center
        self.radius = radius
    }

    /// kurbo `Circle::path_elements`: four (or, for tight tolerances, more) cubics from the rightmost
    /// point, closed.
    public func path(_ tolerance: Double) -> BezPath {
        let scaledErr = Swift.abs(radius) / tolerance
        let n: Int
        let armLen: Double
        if scaledErr < 1.0 / 1.9608e-4 {
            (n, armLen) = (4, 0.551915024494)
        } else {
            // Capped: an absurd ratio would otherwise ask for billions of segments.
            n = min(asUsize(Darwin.pow(1.1163 * scaledErr, 1.0 / 6.0).rounded(.up)), 100_000)
            armLen = (4.0 / 3.0) * Darwin.tan(Double.pi / 2 / Double(n))
        }
        let deltaTh = 2.0 * Double.pi / Double(n)
        let (x, y, r, a) = (center.x, center.y, radius, armLen)
        var p = BezPath()
        p.moveTo(Point(x + r, y))
        if n >= 1 {
            for ix in 1 ... n {
                let th1 = deltaTh * Double(ix)
                let th0 = th1 - deltaTh
                let (s0, c0) = sinCos(th0)
                let (s1, c1) = ix == n ? (0.0, 1.0) : sinCos(th1)
                p.curveTo(Point(x + r * (c0 - a * s0), y + r * (s0 + a * c0)),
                          Point(x + r * (c1 + a * s1), y + r * (s1 - a * c1)),
                          Point(x + r * c1, y + r * s1))
            }
        }
        p.closePath()
        return p
    }
}

// MARK: - Cubic offset (kurbo offset.rs)

private let cuspEpsilon = 1e-12
private let nLSE = 8
private let blendWeight = 1e-3
private let maxOffsetDepth = 8

private func mkAWeights(_ rev: Bool) -> [Double] {
    var result = [Double](repeating: 0, count: nLSE)
    for i in 0 ..< nLSE {
        let t = Double(i + 1) / Double(nLSE + 1)
        let mt = 1.0 - t
        result[rev ? nLSE - 1 - i : i] = 3.0 * mt * t * mt
    }
    return result
}

private let aWeights = mkAWeights(false)
private let bWeights = mkAWeights(true)

private struct OffsetRec {
    var t0: Double, t1: Double, utan0: Vec2, utan1: Vec2, cusp0: Double, cusp1: Double, depth: Int
}

private struct ErrEval {
    var errSquared: Double
    var unorms: [Vec2]
    var errVecs: [Vec2]
}

private struct CubicOffset {
    let c: CubicBez
    let q: QuadBez
    let d: Double
    let c0: Double, c1: Double, c2: Double
    let tolerance: Double

    init(_ c: CubicBez, _ d: Double, _ tolerance: Double) {
        let q = c.deriv
        let d2 = 2.0 * d
        let p1xp0 = q.p1.toVec2.cross(q.p0.toVec2)
        let p2xp0 = q.p2.toVec2.cross(q.p0.toVec2)
        let p2xp1 = q.p2.toVec2.cross(q.p1.toVec2)
        self.c = c
        self.q = q
        self.d = d
        c0 = d2 * p1xp0
        c1 = d2 * (p2xp0 - 2.0 * p1xp0)
        c2 = d2 * (p2xp1 - p2xp0 + p1xp0)
        self.tolerance = tolerance
    }

    func cuspSign(_ t: Double) -> Double {
        let ds2 = q.eval(t).toVec2.hypot2
        return ((c2 * t + c1) * t + c0) / (ds2 * ds2.squareRoot()) + 1.0
    }

    func endpointCusp(_ tan: Point, _ y: Double) -> Double {
        let tanDist = fmax(tan.toVec2.hypot, 1e-12)
        let rsqrt = 1.0 / tanDist
        return y * (rsqrt * rsqrt * rsqrt) + 1.0
    }

    func offsetRec(_ rec: OffsetRec, _ result: inout BezPath) {
        if rec.cusp0 * rec.cusp1 < 0.0 {
            let a = rec.t0, b = rec.t1
            let s = rec.cusp1.signum
            let k1 = 0.2 / (b - a)
            let t = solveITP({ s * cuspSign($0) }, a, b, 1e-12, 1, k1, s * rec.cusp0, s * rec.cusp1)
            let utanT = q.eval(t).toVec2.normalize
            subdivide(rec, &result, t, utanT, cuspEpsilon.copysign(rec.cusp0), cuspEpsilon.copysign(rec.cusp1))
            return
        }
        var (a, b) = drawArc(rec)
        let dt = (rec.t1 - rec.t0) * (1.0 / Double(nLSE + 1))
        var ts = (0 ..< nLSE).map { rec.t0 + Double($0 + 1) * dt }
        var cApprox = apply(rec, a, b)
        var err = evalErr(rec, cApprox, &ts)
        for _ in 0 ..< 2 {
            if err.errSquared <= tolerance * tolerance { break }
            let (a2, b2) = refineLeastSquares(rec, a, b, err)
            let cApprox2 = apply(rec, a2, b2)
            let err2 = evalErr(rec, cApprox2, &ts)
            if err2.errSquared >= err.errSquared { break }
            err = err2
            (a, b) = (a2, b2)
            cApprox = cApprox2
        }
        if rec.depth < maxOffsetDepth && err.errSquared > tolerance * tolerance {
            let (t, utan) = findSubdivisionPoint(rec)
            let cusp = cuspSign(t)
            subdivide(rec, &result, t, utan, cusp, cusp)
        } else {
            result.curveTo(cApprox.p1, cApprox.p2, cApprox.p3)
        }
    }

    func subdivide(_ rec: OffsetRec, _ result: inout BezPath, _ t: Double, _ utanT: Vec2, _ cuspMinus: Double, _ cuspPlus: Double) {
        offsetRec(OffsetRec(t0: rec.t0, t1: t, utan0: rec.utan0, utan1: utanT, cusp0: rec.cusp0, cusp1: cuspMinus, depth: rec.depth + 1), &result)
        offsetRec(OffsetRec(t0: t, t1: rec.t1, utan0: utanT, utan1: rec.utan1, cusp0: cuspPlus, cusp1: rec.cusp1, depth: rec.depth + 1), &result)
    }

    func apply(_ rec: OffsetRec, _ a: Double, _ b: Double) -> CubicBez {
        let s = (1.0 / 3.0) * (rec.t1 - rec.t0)
        let p0 = c.eval(rec.t0) + d * rec.utan0.turn90
        let l0 = s * q.eval(rec.t0).toVec2.length + a * d
        var p1 = p0
        if l0 * rec.cusp0 > 0.0 { p1 += l0 * rec.utan0 }
        let p3 = c.eval(rec.t1) + d * rec.utan1.turn90
        var p2 = p3
        let l1 = s * q.eval(rec.t1).toVec2.length - b * d
        if l1 * rec.cusp1 > 0.0 { p2 = p2 - l1 * rec.utan1 }
        return CubicBez(p0, p1, p2, p3)
    }

    func drawArc(_ rec: OffsetRec) -> (Double, Double) {
        let th = Darwin.atan2(rec.utan1.cross(rec.utan0), rec.utan1.dot(rec.utan0))
        let a = (2.0 / 3.0) / (1.0 + Darwin.cos(0.5 * th)) * 2.0 * Darwin.sin(0.5 * th)
        return (a, -a)
    }

    func evalErr(_ rec: OffsetRec, _ cApprox: CubicBez, _ ts: inout [Double]) -> ErrEval {
        let qa = cApprox.deriv
        var errSquared = 0.0
        var unorms = [Vec2](repeating: .zero, count: nLSE)
        var errVecs = [Vec2](repeating: .zero, count: nLSE)
        for i in 0 ..< nLSE {
            let ta = Double(i + 1) * (1.0 / Double(nLSE + 1))
            var t = ts[i]
            let p = c.eval(t)
            let pa = cApprox.eval(ta)
            let tana = qa.eval(ta).toVec2
            t += tana.dot(pa - p) / tana.dot(q.eval(t).toVec2)
            t = fmin(fmax(t, rec.t0), rec.t1)
            ts[i] = t
            let cusp = rec.cusp0.signum
            let unorm = cusp * tana.normalize.turn90
            unorms[i] = unorm
            let pNew = c.eval(t) + d * unorm
            let errVec = pa - pNew
            errVecs[i] = errVec
            var distErrSquared = errVec.lengthSquared
            if !distErrSquared.isFinite { distErrSquared = 1e12 }
            errSquared = fmax(distErrSquared, errSquared)
        }
        return ErrEval(errSquared: errSquared, unorms: unorms, errVecs: errVecs)
    }

    func refineLeastSquares(_ rec: OffsetRec, _ a: Double, _ b: Double, _ err: ErrEval) -> (Double, Double) {
        var aa = 0.0, ab = 0.0, ac = 0.0, bb = 0.0, bc = 0.0
        for i in 0 ..< nLSE {
            let n = err.unorms[i]
            let errVec = err.errVecs[i]
            let cN = errVec.dot(n)
            let cT = errVec.cross(n)
            let aN = aWeights[i] * rec.utan0.dot(n)
            let aT = aWeights[i] * rec.utan0.cross(n)
            let bN = bWeights[i] * rec.utan1.dot(n)
            let bT = bWeights[i] * rec.utan1.cross(n)
            aa += aN * aN + blendWeight * (aT * aT)
            ab += aN * bN + blendWeight * aT * bT
            ac += aN * cN + blendWeight * aT * cT
            bb += bN * bN + blendWeight * (bT * bT)
            bc += bN * cN + blendWeight * bT * cT
        }
        let idet = 1.0 / (d * (aa * bb - ab * ab))
        let deltaA = idet * (ac * bb - ab * bc)
        let deltaB = idet * (aa * bc - ac * ab)
        return (a - deltaA, b - deltaB)
    }

    func findSubdivisionPoint(_ rec: OffsetRec) -> (Double, Vec2) {
        let t = 0.5 * (rec.t0 + rec.t1)
        let qT = q.eval(t).toVec2
        let x0 = Swift.abs(rec.utan0.cross(qT))
        let x1 = Swift.abs(rec.utan1.cross(qT))
        if x0 > 0.1 * x1 && x1 > 0.1 * x0 { return (t, qT.normalize) }
        let chord = c.eval(rec.t1) - c.eval(rec.t0)
        if chord.cross(rec.utan0) * chord.cross(rec.utan1) < 0.0 {
            let tan = rec.utan0 + rec.utan1
            if let s = subdivideForTangent(rec.utan0, rec.t0, rec.t1, tan, false) { return s }
        }
        var tangents: [Vec2] = [rec.utan0]
        var ts: [Double] = [rec.t0]
        for ti in c.inflections where ti > rec.t0 && ti < rec.t1 {
            tangents.append(q.eval(ti).toVec2)
            ts.append(ti)
        }
        tangents.append(rec.utan1)
        ts.append(rec.t1)
        var arcAngles: [Double] = []
        var sum = 0.0
        for i in 0 ..< tangents.count - 1 {
            let th = Darwin.atan2(tangents[i].cross(tangents[i + 1]), tangents[i].dot(tangents[i + 1]))
            sum += Swift.abs(th)
            arcAngles.append(th)
        }
        var target = sum * 0.5
        var i = 0
        while i < arcAngles.count - 1 && Swift.abs(arcAngles[i]) < target {
            target -= Swift.abs(arcAngles[i])
            i += 1
        }
        let rotation = Vec2.fromAngle(target.copysign(arcAngles.at(i) ?? 0))
        let base = tangents[i]
        let tan = base.rotateScale(rotation)
        let utan0 = i == 0 ? rec.utan0 : base.normalize
        return subdivideForTangent(utan0, ts[i], ts.at(i + 1) ?? rec.t1, tan, true) ?? (t, qT.normalize)
    }

    func subdivideForTangent(_ utan0: Vec2, _ t0: Double, _ t1: Double, _ tan: Vec2, _ force: Bool) -> (Double, Vec2)? {
        var t = 0.0
        var nSoln = 0
        let z0 = tan.cross(q.p0.toVec2)
        let z1 = tan.cross(q.p1.toVec2)
        let z2 = tan.cross(q.p2.toVec2)
        for root in solveQuadratic(z0, 2.0 * (z1 - z0), (z2 - z1) - (z1 - z0)) where root >= t0 && root <= t1 {
            t = root
            nSoln += 1
        }
        if nSoln != 1 {
            if !force { return nil }
            t = q.eval(t0).toVec2.lengthSquared > q.eval(t1).toVec2.lengthSquared ? t1 : t0
        }
        let qv = q.eval(t).toVec2
        let utan: Vec2
        if nSoln == 1 && qv.lengthSquared >= 1e-12 {
            utan = qv.normalize
        } else if tan.lengthSquared >= 1e-12 {
            utan = tan.normalize
        } else {
            utan = utan0.turn90
        }
        return (t, utan)
    }
}

/// kurbo `offset::offset_cubic`: an approximation of `c` moved `d` along its normal, appended to a fresh
/// path that starts with a `moveTo`.
public func offsetCubic(_ c: CubicBez, _ d: Double, _ tolerance: Double) -> BezPath {
    var result = BezPath()
    let cReg = c.regularizeCusp(tolerance * 0.25)
    let co = CubicOffset(cReg, d, tolerance)
    let (tan0, tan1) = PathSeg.cubic(c).tangents
    let utan0 = tan0.normalize
    let utan1 = tan1.normalize
    let cusp0 = co.endpointCusp(co.q.p0, co.c0)
    let cusp1 = co.endpointCusp(co.q.p2, co.c0 + co.c1 + co.c2)
    result.moveTo(c.p0 + d * utan0.turn90)
    co.offsetRec(OffsetRec(t0: 0, t1: 1, utan0: utan0, utan1: utan1, cusp0: cusp0, cusp1: cusp1, depth: 0), &result)
    return result
}
