// DCGeometry — kurbo's winding numbers: `Shape::winding` for a `BezPath` (the sum over its segments) and
// `PathSeg::winding`, which splits a segment where it turns in y and casts a ray to the left from the point.
// Ported from kurbo 0.13.1 (bezpath.rs, quadbez.rs, cubicbez.rs; MIT OR Apache-2.0, © the kurbo authors)
// with its formulas and operand order unchanged; deckcraft's pointer hit tests fill shapes by it.

extension BezPath {
    /// kurbo `Shape::winding` (`BezPath`): the non-zero winding number of `p`. Open sub-paths aren't closed,
    /// as in kurbo.
    public func winding(_ p: Point) -> Int {
        kurboSegments(elements).reduce(0) { $0 + $1.winding(p) }
    }
}

extension PathSeg {
    /// kurbo `PathSeg::winding`: the winding contribution of this segment, from its y-monotonic pieces.
    public func winding(_ p: Point) -> Int {
        var t0 = 0.0
        var sum = 0
        for t in extrema {
            sum += subsegment(t0, t).windingInner(p)
            t0 = t
        }
        return sum + subsegment(t0, 1.0).windingInner(p)
    }

    /// kurbo `PathSeg::winding_inner`: for a segment monotonic in y, 1 or −1 when it crosses the ray pointing
    /// left from `p` (decreasing or increasing in y), else 0. It holds the end with the smaller y and not the
    /// one with the larger y, so consecutive segments count a crossing at a joint once.
    func windingInner(_ p: Point) -> Int {
        let start = self.start
        let end = self.end
        let sign: Int
        if end.y > start.y {
            if p.y < start.y || p.y >= end.y { return 0 }
            sign = -1
        } else if end.y < start.y {
            if p.y < end.y || p.y >= start.y { return 0 }
            sign = 1
        } else {
            return 0
        }
        switch self {
        case .line:
            if p.x < fmin(start.x, end.x) { return 0 }
            if p.x >= fmax(start.x, end.x) { return sign }
            // line equation ax + by = c
            let a = end.y - start.y
            let b = start.x - end.x
            let c = a * start.x + b * start.y
            return (a * p.x + b * p.y - c) * Double(sign) <= 0.0 ? sign : 0
        case .quad(let q):
            let p1 = q.p1
            if p.x < fmin(fmin(start.x, end.x), p1.x) { return 0 }
            if p.x >= fmax(fmax(start.x, end.x), p1.x) { return sign }
            let t = q.solveMonotonicForY(p.y)
            let x = q.eval(t).x
            return p.x >= x ? sign : 0
        case .cubic(let c):
            let p1 = c.p1
            let p2 = c.p2
            if p.x < fmin(fmin(fmin(start.x, end.x), p1.x), p2.x) { return 0 }
            if p.x >= fmax(fmax(fmax(start.x, end.x), p1.x), p2.x) { return sign }
            let t = c.solveMonotonicForY(p.y)
            let x = c.eval(t).x
            return p.x >= x ? sign : 0
        }
    }
}

extension QuadBez {
    /// kurbo `QuadBez::solve_monotonic_for_y`: the `t` where this y-monotonic curve is at height `y`; the
    /// nearer end when rounding leaves no root in 0...1.
    func solveMonotonicForY(_ y: Double) -> Double {
        let start = p0
        let end = p2
        let a = end.y - 2.0 * p1.y + start.y
        let b = 2.0 * (p1.y - start.y)
        let c = start.y - y
        for t in solveQuadratic(c, b, a) where t >= 0.0 && t <= 1.0 {
            return t
        }
        return Swift.abs(start.y - y) <= Swift.abs(end.y - y) ? 0.0 : 1.0
    }
}

extension CubicBez {
    /// kurbo `CubicBez::solve_monotonic_for_y` (as `QuadBez`'s, for a cubic).
    func solveMonotonicForY(_ y: Double) -> Double {
        let start = p0
        let end = p3
        let a = end.y - 3.0 * p2.y + 3.0 * p1.y - start.y
        let b = 3.0 * (p2.y - 2.0 * p1.y + start.y)
        let c = 3.0 * (p1.y - start.y)
        let d = start.y - y
        for t in solveCubic(d, c, b, a) where t >= 0.0 && t <= 1.0 {
            return t
        }
        return Swift.abs(start.y - y) <= Swift.abs(end.y - y) ? 0.0 : 1.0
    }
}
