// DCGeometry — kurbo's paths: `PathEl`, `BezPath`, the segment types, elliptical arcs to cubics,
// flattening, signed area and exact bounding boxes. Ported from kurbo 0.13.1 (bezpath.rs, arc.rs,
// line.rs, quadbez.rs, cubicbez.rs, common.rs, param_curve.rs; MIT OR Apache-2.0, © the kurbo
// authors) with its formulas and operand order unchanged, so outlines match deckcraft's bit for bit.
import DCCore
import Darwin

// MARK: - Path elements

public enum PathEl: Sendable, Hashable {
    case moveTo(Point)
    case lineTo(Point)
    case quadTo(Point, Point)
    case curveTo(Point, Point, Point)
    case closePath

    /// The element's end point; nil for `closePath`.
    public var endPoint: Point? {
        switch self {
        case .moveTo(let p), .lineTo(let p), .quadTo(_, let p), .curveTo(_, _, let p): p
        case .closePath: nil
        }
    }

    public var isFinite: Bool {
        switch self {
        case .moveTo(let p), .lineTo(let p): p.isFinite
        case .quadTo(let a, let b): a.isFinite && b.isFinite
        case .curveTo(let a, let b, let c): a.isFinite && b.isFinite && c.isFinite
        case .closePath: true
        }
    }

    public static func * (m: Affine, el: PathEl) -> PathEl {
        switch el {
        case .moveTo(let p): .moveTo(m * p)
        case .lineTo(let p): .lineTo(m * p)
        case .quadTo(let a, let b): .quadTo(m * a, m * b)
        case .curveTo(let a, let b, let c): .curveTo(m * a, m * b, m * c)
        case .closePath: .closePath
        }
    }
}

/// A Bézier path: a list of elements, as kurbo keeps it.
public struct BezPath: Sendable, Hashable {
    public private(set) var elements: [PathEl]

    public init(_ elements: [PathEl] = []) {
        self.elements = elements
    }

    public mutating func push(_ el: PathEl) { elements.append(el) }
    public mutating func moveTo(_ p: Point) { elements.append(.moveTo(p)) }
    public mutating func lineTo(_ p: Point) { elements.append(.lineTo(p)) }
    public mutating func quadTo(_ p1: Point, _ p2: Point) { elements.append(.quadTo(p1, p2)) }
    public mutating func curveTo(_ p1: Point, _ p2: Point, _ p3: Point) { elements.append(.curveTo(p1, p2, p3)) }
    public mutating func closePath() { elements.append(.closePath) }

    public mutating func extend(_ els: some Sequence<PathEl>) { elements.append(contentsOf: els) }

    public mutating func applyAffine(_ m: Affine) {
        elements = elements.map { m * $0 }
    }

    /// Whether the path draws nothing: only moves and closes.
    public var isEmpty: Bool {
        elements.allSatisfy { if case .moveTo = $0 { true } else if case .closePath = $0 { true } else { false } }
    }

    public var isFinite: Bool { elements.allSatisfy(\.isFinite) }

    /// The path's segments, a close drawing a line back to the start when it isn't there already.
    public var segments: [PathSeg] { kurboSegments(elements) }

    /// Signed area (positive for clockwise in a y-down space).
    /// Rust sums floats from -0.0, so an empty path has area -0.0.
    public var area: Double { segments.reduce(-0.0) { $0 + $1.signedArea } }

    /// The exact bounding box of the curves (not their control points); `Rect.zero` for no segments.
    public var boundingBox: Rect {
        var bbox: Rect?
        for seg in segments {
            let bb = seg.boundingBox
            bbox = bbox.map { $0.union(bb) } ?? bb
        }
        return bbox ?? .zero
    }
}

/// kurbo's `segments` iterator over raw elements.
func kurboSegments(_ elements: [PathEl]) -> [PathSeg] {
    var out: [PathSeg] = []
    var startLast: (start: Point, last: Point)?
    for el in elements {
        if startLast == nil {
            switch el {
            case .moveTo(let p), .lineTo(let p), .quadTo(_, let p), .curveTo(_, _, let p): startLast = (p, p)
            // kurbo panics here ("Can't start a segment on a ClosePath"); skip it instead.
            case .closePath: continue
            }
        }
        guard var (start, last) = startLast else { continue }
        switch el {
        case .moveTo(let p):
            start = p
            last = p
        case .lineTo(let p):
            out.append(.line(LineSeg(last, p)))
            last = p
        case .quadTo(let p1, let p2):
            out.append(.quad(QuadBez(last, p1, p2)))
            last = p2
        case .curveTo(let p1, let p2, let p3):
            out.append(.cubic(CubicBez(last, p1, p2, p3)))
            last = p3
        case .closePath:
            if last != start {
                out.append(.line(LineSeg(last, start)))
                last = start
            }
        }
        startLast = (start, last)
    }
    return out
}

// MARK: - Segments

/// kurbo's `Line` (renamed: the model declares a `Line`).
public struct LineSeg: Sendable, Hashable {
    public var p0: Point
    public var p1: Point

    public init(_ p0: Point, _ p1: Point) {
        self.p0 = p0
        self.p1 = p1
    }

    public func eval(_ t: Double) -> Point { p0.lerp(p1, t) }
    public var signedArea: Double { p0.toVec2.cross(p1.toVec2) * 0.5 }
}

public struct QuadBez: Sendable, Hashable {
    public var p0: Point
    public var p1: Point
    public var p2: Point

    public init(_ p0: Point, _ p1: Point, _ p2: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
    }

    public func eval(_ t: Double) -> Point {
        let mt = 1.0 - t
        return (p0.toVec2 * (mt * mt) + (p1.toVec2 * (mt * 2.0) + p2.toVec2 * t) * t).toPoint
    }

    public var signedArea: Double {
        (p0.x * (2.0 * p1.y + p2.y) + 2.0 * p1.x * (p2.y - p0.y) - p2.x * (p0.y + 2.0 * p1.y)) * (1.0 / 6.0)
    }

    public var extrema: [Double] {
        var result: [Double] = []
        let d0 = p1 - p0
        let d1 = p2 - p1
        let dd = d1 - d0
        if dd.x != 0 {
            let t = -d0.x / dd.x
            if t > 0 && t < 1 { result.append(t) }
        }
        if dd.y != 0 {
            let t = -d0.y / dd.y
            if t > 0 && t < 1 {
                result.append(t)
                if result.count == 2 && result[0] > t { result.swapAt(0, 1) }
            }
        }
        return result
    }

    struct FlattenParams {
        var a0: Double
        var a2: Double
        var u0: Double
        var uscale: Double
        var val: Double
    }

    func estimateSubdiv(_ sqrtTol: Double) -> FlattenParams {
        let d01 = p1 - p0
        let d12 = p2 - p1
        let dd = d01 - d12
        let cross = (p2 - p0).cross(dd)
        let x0 = d01.dot(dd) * (1.0 / cross)
        let x2 = d12.dot(dd) * (1.0 / cross)
        let scale = Swift.abs(cross / (dd.hypot * (x2 - x0)))
        let a0 = approxParabolaIntegral(x0)
        let a2 = approxParabolaIntegral(x2)
        let val: Double
        if scale.isFinite {
            let da = Swift.abs(a2 - a0)
            let sqrtScale = scale.squareRoot()
            if x0.signum == x2.signum {
                val = da * sqrtScale
            } else {
                let xmin = sqrtTol / sqrtScale
                val = sqrtTol * da / approxParabolaIntegral(xmin)
            }
        } else {
            val = 0.0
        }
        let u0 = approxParabolaInvIntegral(a0)
        let u2 = approxParabolaInvIntegral(a2)
        let uscale = 1.0 / (u2 - u0)
        return FlattenParams(a0: a0, a2: a2, u0: u0, uscale: uscale, val: val)
    }

    func determineSubdivT(_ params: FlattenParams, _ x: Double) -> Double {
        let a = params.a0 + (params.a2 - params.a0) * x
        let u = approxParabolaInvIntegral(a)
        return (u - params.u0) * params.uscale
    }
}

private func approxParabolaIntegral(_ x: Double) -> Double {
    let d = 0.67
    // `D.powi(4)` on a constant: LLVM constant-folds it with the host `pow`.
    let d4 = Darwin.pow(d, 4.0)
    return x / (1.0 - d + (d4 + 0.25 * x * x).squareRoot().squareRoot())
}

private func approxParabolaInvIntegral(_ x: Double) -> Double {
    let b = 0.39
    return x * (1.0 - b + (b * b + 0.25 * x * x).squareRoot())
}

public struct CubicBez: Sendable, Hashable {
    public var p0: Point
    public var p1: Point
    public var p2: Point
    public var p3: Point

    public init(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }

    public func eval(_ t: Double) -> Point {
        let mt = 1.0 - t
        let v = p0.toVec2 * (mt * mt * mt)
            + (p1.toVec2 * (mt * mt * 3.0) + (p2.toVec2 * (mt * 3.0) + p3.toVec2 * t) * t) * t
        return v.toPoint
    }

    /// The derivative, a quadratic in kurbo's form.
    var deriv: QuadBez {
        QuadBez((3.0 * (p1 - p0)).toPoint, (3.0 * (p2 - p1)).toPoint, (3.0 * (p3 - p2)).toPoint)
    }

    public func subsegment(_ t0: Double, _ t1: Double) -> CubicBez {
        let q0 = eval(t0)
        let q3 = eval(t1)
        let d = deriv
        let scale = (t1 - t0) * (1.0 / 3.0)
        let q1 = q0 + scale * d.eval(t0).toVec2
        let q2 = q3 - scale * d.eval(t1).toVec2
        return CubicBez(q0, q1, q2, q3)
    }

    public var signedArea: Double {
        (p0.x * (6.0 * p1.y + 3.0 * p2.y + p3.y)
            + 3.0 * (p1.x * (-2.0 * p0.y + p2.y + p3.y) - p2.x * (p0.y + p1.y - 2.0 * p3.y))
            - p3.x * (p0.y + 3.0 * p1.y + 6.0 * p2.y)) * (1.0 / 20.0)
    }

    public var extrema: [Double] {
        func oneCoord(_ result: inout [Double], _ d0: Double, _ d1: Double, _ d2: Double) {
            let a = d0 - 2.0 * d1 + d2
            let b = 2.0 * (d1 - d0)
            let c = d0
            for t in solveQuadratic(c, b, a) where t > 0 && t < 1 {
                result.append(t)
            }
        }
        var result: [Double] = []
        let d0 = p1 - p0
        let d1 = p2 - p1
        let d2 = p3 - p2
        oneCoord(&result, d0.x, d1.x, d2.x)
        oneCoord(&result, d0.y, d1.y, d2.y)
        // Stable, as Rust's `sort_by`; the roots are finite here.
        return result.enumerated().sorted { $0.element < $1.element || ($0.element == $1.element && $0.offset < $1.offset) }.map(\.element)
    }

    /// The cubic as `n` quadratics, evenly in t (kurbo `to_quads`).
    func toQuads(_ accuracy: Double) -> [QuadBez] {
        let maxHypot2 = 432.0 * accuracy * accuracy
        let p1x2 = 3.0 * p1.toVec2 - p0.toVec2
        let p2x2 = 3.0 * p2.toVec2 - p3.toVec2
        let err = (p2x2 - p1x2).hypot2
        let n = Swift.max(asUsize(Darwin.pow(err / maxHypot2, 1.0 / 6.0).rounded(.up)), 1)
        var out: [QuadBez] = []
        out.reserveCapacity(Swift.min(n, 1 << 16))
        for i in 0 ..< n {
            let t0 = Double(i) / Double(n)
            let t1 = Double(i + 1) / Double(n)
            let seg = subsegment(t0, t1)
            let a = 3.0 * seg.p1.toVec2 - seg.p0.toVec2
            let b = 3.0 * seg.p2.toVec2 - seg.p3.toVec2
            out.append(QuadBez(seg.p0, ((a + b) / 4.0).toPoint, seg.p3))
        }
        return out
    }
}

public enum PathSeg: Sendable, Hashable {
    case line(LineSeg)
    case quad(QuadBez)
    case cubic(CubicBez)

    public var start: Point {
        switch self {
        case .line(let l): l.p0
        case .quad(let q): q.p0
        case .cubic(let c): c.p0
        }
    }

    public var end: Point {
        switch self {
        case .line(let l): l.p1
        case .quad(let q): q.p2
        case .cubic(let c): c.p3
        }
    }

    public func eval(_ t: Double) -> Point {
        switch self {
        case .line(let l): l.eval(t)
        case .quad(let q): q.eval(t)
        case .cubic(let c): c.eval(t)
        }
    }

    public var signedArea: Double {
        switch self {
        case .line(let l): l.signedArea
        case .quad(let q): q.signedArea
        case .cubic(let c): c.signedArea
        }
    }

    public var extrema: [Double] {
        switch self {
        case .line: []
        case .quad(let q): q.extrema
        case .cubic(let c): c.extrema
        }
    }

    /// kurbo `ParamCurveExtrema::bounding_box`.
    public var boundingBox: Rect {
        var bbox = Rect.fromPoints(start, end)
        for t in extrema { bbox = bbox.unionPoint(eval(t)) }
        return bbox
    }
}

/// kurbo `common::solve_quadratic`: real roots of c0 + c1·x + c2·x², sorted.
func solveQuadratic(_ c0: Double, _ c1: Double, _ c2: Double) -> [Double] {
    let sc0 = c0 * (1.0 / c2)
    let sc1 = c1 * (1.0 / c2)
    if !sc0.isFinite || !sc1.isFinite {
        let root = -c0 / c1
        if root.isFinite { return [root] }
        if c0 == 0 && c1 == 0 { return [0.0] }
        return []
    }
    let arg = sc1 * sc1 - 4.0 * sc0
    let root1: Double
    if !arg.isFinite {
        root1 = -sc1
    } else {
        if arg < 0 { return [] }
        if arg == 0 { return [-0.5 * sc1] }
        root1 = -0.5 * (sc1 + arg.squareRoot().copysign(sc1))
    }
    let root2 = sc0 / root1
    if root2.isFinite {
        return root2 > root1 ? [root1, root2] : [root2, root1]
    }
    return [root1]
}

// MARK: - Arcs

/// An elliptical arc (kurbo `Arc`).
public struct Arc: Sendable, Hashable {
    public var center: Point
    public var radii: Vec2
    public var startAngle: Double
    public var sweepAngle: Double
    public var xRotation: Double

    public init(_ center: Point, _ radii: Vec2, _ startAngle: Double, _ sweepAngle: Double, _ xRotation: Double) {
        self.center = center
        self.radii = radii
        self.startAngle = startAngle
        self.sweepAngle = sweepAngle
        self.xRotation = xRotation
    }

    /// The arc as cubic `curveTo` elements, without the initial move (kurbo `append_iter`).
    public func appendElements(_ tolerance: Double) -> [PathEl] {
        let sign = sweepAngle.signum
        let scaledErr = fmax(radii.x, radii.y) / tolerance
        let nErr = fmax(Darwin.pow(1.1163 * scaledErr, 1.0 / 6.0), 3.999_999)
        let nf = (nErr * Swift.abs(sweepAngle) * (1.0 / (2.0 * Double.pi))).rounded(.up)
        let angleStep = sweepAngle / nf
        let n = asUsize(nf)
        let armLen = (4.0 / 3.0) * Darwin.tan(Swift.abs(0.25 * angleStep)) * sign
        var angle0 = startAngle
        var p0 = sampleEllipse(radii, xRotation, angle0)
        var out: [PathEl] = []
        out.reserveCapacity(Swift.min(n, 1 << 16))
        for _ in 0 ..< n {
            let angle1 = angle0 + angleStep
            let p1 = p0 + armLen * sampleEllipse(radii, xRotation, angle0 + Double.pi / 2)
            let p3 = sampleEllipse(radii, xRotation, angle1)
            let p2 = p3 - armLen * sampleEllipse(radii, xRotation, angle1 + Double.pi / 2)
            angle0 = angle1
            p0 = p3
            out.append(.curveTo(center + p1, center + p2, center + p3))
        }
        return out
    }

    /// Calls `f` with each cubic's control points and end (kurbo `to_cubic_beziers`).
    public func toCubicBeziers(_ tolerance: Double, _ f: (Point, Point, Point) -> Void) {
        for el in appendElements(tolerance) {
            guard case .curveTo(let a, let b, let c) = el else { break }
            f(a, b, c)
        }
    }
}

private func sampleEllipse(_ radii: Vec2, _ xRotation: Double, _ angle: Double) -> Vec2 {
    let u = radii.x * sinCos(angle).cos
    let v = radii.y * sinCos(angle).sin
    return rotatePt(Vec2(u, v), xRotation)
}

private func rotatePt(_ pt: Vec2, _ angle: Double) -> Vec2 {
    let s = sinCos(angle).sin
    let c = sinCos(angle).cos
    return Vec2(pt.x * c - pt.y * s, pt.x * s + pt.y * c)
}

// MARK: - Flattening

private let toQuadTol = 0.1

/// kurbo `flatten`: the path as move/line/close elements within `tolerance`.
public func flatten(_ elements: [PathEl], _ tolerance: Double, _ callback: (PathEl) -> Void) {
    let sqrtTol = tolerance.squareRoot()
    var lastPt: Point?
    for el in elements {
        switch el {
        case .moveTo(let p):
            lastPt = p
            callback(.moveTo(p))
        case .lineTo(let p):
            lastPt = p
            callback(.lineTo(p))
        case .quadTo(let p1, let p2):
            if let p0 = lastPt {
                let q = QuadBez(p0, p1, p2)
                let params = q.estimateSubdiv(sqrtTol)
                let n = Swift.max(asUsize((0.5 * params.val / sqrtTol).rounded(.up)), 1)
                let step = 1.0 / Double(n)
                if n > 1 {
                    for i in 1 ..< n {
                        let u = Double(i) * step
                        let t = q.determineSubdivT(params, u)
                        callback(.lineTo(q.eval(t)))
                    }
                }
                callback(.lineTo(p2))
            }
            lastPt = p2
        case .curveTo(let p1, let p2, let p3):
            if let p0 = lastPt {
                let c = CubicBez(p0, p1, p2, p3)
                let quads = c.toQuads(tolerance * toQuadTol)
                let sqrtRemainTol = sqrtTol * (1.0 - toQuadTol).squareRoot()
                var sum = 0.0
                var buf: [(QuadBez, QuadBez.FlattenParams)] = []
                buf.reserveCapacity(quads.count)
                for q in quads {
                    let params = q.estimateSubdiv(sqrtRemainTol)
                    sum += params.val
                    buf.append((q, params))
                }
                let n = Swift.max(asUsize((0.5 * sum / sqrtRemainTol).rounded(.up)), 1)
                let step = sum / Double(n)
                var i = 1
                var valSum = 0.0
                outer: for (q, params) in buf {
                    var target = Double(i) * step
                    let recipVal = 1.0 / params.val
                    while target < valSum + params.val {
                        let u = (target - valSum) * recipVal
                        let t = q.determineSubdivT(params, u)
                        callback(.lineTo(q.eval(t)))
                        i += 1
                        if i == n + 1 { break }
                        target = Double(i) * step
                    }
                    valSum += params.val
                    if i == n + 1 { continue outer }
                }
                callback(.lineTo(p3))
            }
            lastPt = p3
        case .closePath:
            lastPt = nil
            callback(.closePath)
        }
    }
}
