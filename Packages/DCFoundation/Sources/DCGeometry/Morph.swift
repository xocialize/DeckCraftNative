// DCGeometry — Morph between two outlines: one shape turns into another (a circle into a star). Port of
// deckcraft crates/geom/src/morph.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The approach is manim's: both outlines get the same number of contours and each contour pair the same
// number of cubic curves, then every control point moves in a straight line. On top of that, closed
// contours are turned and reversed so that their points travel as short a way as possible (a triangle
// does not twist on its way into a circle), and extra points go to the longest curves.

/// Rust's `morph` module.
public enum Morph {
    /// A contour as cubic curves: the start anchor, then three points per curve (handle, handle, anchor).
    public struct Contour: Sendable, Hashable {
        public var closed: Bool
        public var pts: [Point]

        public init(closed: Bool, pts: [Point]) {
            self.closed = closed
            self.pts = pts
        }

        public var curves: Int { Swift.max(pts.count - 1, 0) / 3 }
    }

    static func lineTo(_ p: inout [Point], _ to: Point) {
        guard let from = p.last else { return }
        p.append(contentsOf: [from.lerp(to, 1.0 / 3.0), from.lerp(to, 2.0 / 3.0), to])
    }

    static func close(_ c: inout Contour) {
        if let first = c.pts.first, let last = c.pts.last, first != last {
            lineTo(&c.pts, first)
        }
        c.closed = true
    }

    static func keep(_ c: Contour, _ out: inout [Contour]) {
        if c.curves > 0 && c.pts.allSatisfy(\.isFinite) { out.append(c) }
    }

    /// The contours of a path, every segment as a cubic curve. Contours without a curve or with
    /// non-finite points are left out.
    public static func contours(_ path: BezPath) -> [Contour] {
        var out: [Contour] = []
        var cur: Contour?
        var start = Point.zero
        func pen() -> Contour { cur ?? Contour(closed: false, pts: [start]) }
        for el in path.elements {
            switch el {
            case .moveTo(let p):
                if let c = cur { keep(c, &out) }
                start = p
                cur = Contour(closed: false, pts: [p])
            case .lineTo(let p):
                var c = pen()
                lineTo(&c.pts, p)
                cur = c
            case .quadTo(let q, let p):
                var c = pen()
                if let a = c.pts.last {
                    c.pts.append(contentsOf: [a.lerp(q, 2.0 / 3.0), p.lerp(q, 2.0 / 3.0), p])
                }
                cur = c
            case .curveTo(let a, let b, let p):
                var c = pen()
                c.pts.append(contentsOf: [a, b, p])
                cur = c
            case .closePath:
                if var c = cur {
                    cur = nil
                    if c.curves > 0 {
                        close(&c)
                        keep(c, &out)
                    }
                }
            }
        }
        if let c = cur { keep(c, &out) }
        return out
    }

    /// Contours back to a path.
    public static func toPath(_ cs: [Contour]) -> BezPath {
        var bp = BezPath()
        for c in cs {
            guard let s = c.pts.first else { continue }
            bp.moveTo(s)
            let body = c.pts.dropFirst()
            var i = body.startIndex
            while i + 2 < body.endIndex {
                bp.curveTo(body[i], body[i + 1], body[i + 2])
                i += 3
            }
            if c.closed { bp.closePath() }
        }
        return bp
    }

    // MARK: Alignment

    /// Rough curve length: mean of chord and control polygon.
    static func curveLength(_ c: ArraySlice<Point>) -> Double {
        guard c.count == 4 else { return 0.0 }
        let i = c.startIndex
        let (p0, p1, p2, p3) = (c[i], c[i + 1], c[i + 2], c[i + 3])
        return (p0.distance(p3) + p0.distance(p1) + p1.distance(p2) + p2.distance(p3)) / 2.0
    }

    /// Appends curve `c` (four points) split into `n` pieces of equal parameter length (de Casteljau),
    /// without its start anchor.
    static func splitCurve(_ c: ArraySlice<Point>, _ n: Int, _ out: inout [Point]) {
        guard c.count == 4 else { return }
        let i = c.startIndex
        var (p0, p1, p2) = (c[i], c[i + 1], c[i + 2])
        let p3 = c[i + 3]
        if n >= 2 {
            for j in (2 ... n).reversed() {
                let t = 1.0 / Double(j)
                let (ab, bc, cd) = (p0.lerp(p1, t), p1.lerp(p2, t), p2.lerp(p3, t))
                let (abc, bcd) = (ab.lerp(bc, t), bc.lerp(cd, t))
                let m = abc.lerp(bcd, t)
                out.append(contentsOf: [ab, abc, m])
                (p0, p1, p2) = (m, bcd, cd)
            }
        }
        out.append(contentsOf: [p1, p2, p3])
    }

    /// Brings a contour to `n` curves. Unlike manim (which splits every curve equally often), the extra
    /// splits go to the longest pieces, so a long side gets more points than a short one.
    static func refine(_ c: Contour, _ n: Int) -> Contour {
        let have = c.curves
        if have >= n || have == 0 { return c }
        let curves: [ArraySlice<Point>] = (0 ..< have).compactMap { k in
            3 * k + 4 <= c.pts.count ? c.pts[(3 * k) ..< (3 * k + 4)] : nil
        }
        let len = curves.map { curveLength($0) + 1e-9 }
        var parts = Array(repeating: 1, count: curves.count)
        for _ in 0 ..< (n - have) {
            func share(_ k: Int) -> Double { (len.at(k) ?? 0.0) / Double(parts.at(k) ?? 1) }
            var best = 0
            if curves.count > 1 {
                for k in 1 ..< curves.count where share(k) > share(best) { best = k }
            }
            if parts.indices.contains(best) { parts[best] += 1 }
        }
        var out: [Point] = []
        out.reserveCapacity(1 + 3 * n)
        if let f = c.pts.first { out.append(f) }
        for (q, p) in zip(curves, parts) { splitCurve(q, p, &out) }
        return Contour(closed: c.closed, pts: out)
    }

    static let minCurves = 12
    static let maxCurves = 60
    /// Start points tried per closed contour; longer contours are sampled evenly.
    static let maxTries = 128

    static func divCeil(_ a: Int, _ b: Int) -> Int { a / b + (a % b > 0 ? 1 : 0) }

    /// How many curves a contour pair gets: a common multiple of both counts while that stays small
    /// (then a triangle meets a circle at matching places and the morph stays symmetric), and at least
    /// `minCurves` for a smooth middle.
    static func curvesFor(_ na: Int, _ nb: Int) -> Int {
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        let hi = Swift.max(Swift.max(na, nb), 1)
        var n: Int
        if na > 0 && nb > 0 {
            let (m, o) = (na / gcd(na, nb)).multipliedReportingOverflow(by: nb)
            n = o ? Int.max : m
        } else {
            n = hi
        }
        if n > maxCurves { n = hi }
        let (r, o) = n.multipliedReportingOverflow(by: Swift.max(divCeil(minCurves, n), 1))
        return o ? Int.max : r
    }

    /// Box around all points, handles included.
    static func bounds(_ pts: some Sequence<Point>) -> Rect? {
        var r: Rect?
        for p in pts { r = r.map { $0.unionPoint(p) } ?? Rect.fromPoints(p, p) }
        return r
    }

    static func center(_ pts: [Point]) -> Point { bounds(pts)?.center ?? .zero }

    /// The same contour, starting at anchor `s`, optionally run backwards.
    static func turn(_ pts: [Point], _ s: Int, _ back: Bool) -> [Point] {
        let q = back ? Array(pts.reversed()) : pts
        if s == 0 { return q }
        let body = Array(q.dropFirst())
        let cut = Swift.min(3 * s, body.count)
        var out: [Point] = []
        out.reserveCapacity(q.count)
        if cut >= 1, let p = body.at(cut - 1) { out.append(p) }
        out.append(contentsOf: body[cut...])
        out.append(contentsOf: body[..<cut])
        return out
    }

    /// One contour pair of equal curve count: `b` runs backwards if `back` is set, then the closed side
    /// (`b` if it is closed, else `a`) gets the start that lets the points travel least. Both sides are
    /// compared around their own centre, so where the shapes are does not matter.
    static func matchPair(_ a: Contour, _ b: Contour, _ back: Bool) -> (Contour, Contour, Double) {
        let bp = back ? turn(b.pts, 0, true) : b.pts
        let turnA = !b.closed && a.closed
        let (fixed, free) = turnA ? (bp, a.pts) : (a.pts, bp)
        let (fc, gc) = (center(fixed), center(free))
        let tries = (turnA || b.closed) ? Swift.max(free.count - 1, 0) / 3 : 1
        var best = free
        var bestCost = Double.infinity
        let stepBy = Swift.max(divCeil(tries, maxTries), 1)
        for s in stride(from: 0, to: Swift.max(tries, 1), by: stepBy) {
            let q = turn(free, s, false)
            var cost = 0.0
            for (p, f) in zip(q, fixed) {
                cost += ((p - gc) - (f - fc)).hypot2
                if cost >= bestCost { break }
            }
            if cost < bestCost {
                bestCost = cost
                best = q
            }
        }
        let (pa, pb) = turnA ? (best, bp) : (a.pts, best)
        return (Contour(closed: a.closed, pts: pa), Contour(closed: b.closed, pts: pb), bestCost)
    }

    /// Where a contour without partner shrinks to (or grows from): the spot at the same place relative to
    /// the other outline's box, or its own centre without one.
    static func place(_ c: Contour, _ from: Rect?, _ to: Rect?) -> Point {
        let p = center(c.pts)
        guard let from, let to else { return p }
        let fx = from.width > 0.0 ? (p.x - from.x0) / from.width : 0.5
        let fy = from.height > 0.0 ? (p.y - from.y0) / from.height : 0.5
        return Point(to.x0 + to.width * fx, to.y0 + to.height * fy)
    }

    /// Two contour lists brought to the same number of contours and the same number of curves per contour
    /// pair. Contours pair up in order; one without partner meets a point (see `place`; `ba`/`bb` are the
    /// boxes of the whole outlines). Whether `b` runs backwards is decided once for all its contours:
    /// turning single ones around would change which areas a nonzero fill covers.
    public static func align(_ a: [Contour], _ b: [Contour], _ ba: Rect?, _ bb: Rect?) -> ([Contour], [Contour]) {
        var pairs: [(Contour, Contour, Bool)] = []
        for k in 0 ..< Swift.max(a.count, b.count) {
            let (ca, cb) = (a.at(k), b.at(k))
            let n = curvesFor(ca?.curves ?? 0, cb?.curves ?? 0)
            func point(_ c: Contour, _ from: Rect?, _ to: Rect?, _ closed: Bool) -> Contour {
                Contour(closed: closed, pts: Array(repeating: place(c, from, to), count: 1 + 3 * n))
            }
            switch (ca, cb) {
            case (let x?, let y?): pairs.append((refine(x, n), refine(y, n), false))
            case (let x?, nil): pairs.append((refine(x, n), point(x, ba, bb, x.closed), true))
            case (nil, let y?): pairs.append((point(y, bb, ba, y.closed), refine(y, n), true))
            case (nil, nil): break
            }
        }
        var best: ([Contour], [Contour], Double)?
        for back in [false, true] {
            var (xs, ys, cost): ([Contour], [Contour], Double) = ([], [], 0.0)
            for (x, y, isPoint) in pairs {
                if isPoint {
                    xs.append(x)
                    ys.append(back ? Contour(closed: y.closed, pts: turn(y.pts, 0, true)) : y)
                } else {
                    let (mx, my, c) = matchPair(x, y, back)
                    xs.append(mx)
                    ys.append(my)
                    cost += c
                }
            }
            if best.map({ cost < $0.2 }) ?? true { best = (xs, ys, cost) }
        }
        guard let best else { return ([], []) }
        return (best.0, best.1)
    }

    // MARK: Whole geometries

    struct Look: Sendable, Hashable {
        var fill: FillMode
        var stroke: Bool
        var evenOdd: Bool
    }

    struct Part: Sendable, Hashable {
        var a: Look?
        var b: Look?
        var ca: [Contour]
        var cb: [Contour]
    }

    /// How strongly a sub-path of a morphed geometry shows: its fill and its outline, 0..1.
    public struct Fade: Sendable, Hashable {
        public var fill: Double
        public var stroke: Double

        public init(fill: Double, stroke: Double) {
            self.fill = fill
            self.stroke = stroke
        }
    }

    static func look(_ s: Preset.SubPath) -> Look { Look(fill: s.fill, stroke: s.stroke, evenOdd: s.evenOdd) }

    /// The layers a pair of looks is drawn with at `t`, bottom first. A fill or an outline only one side
    /// has fades out (or in). When both fill, the side with the even-odd rule lies opaque underneath and
    /// the other fades over it, so a donut's hole fills smoothly; with the same rule both cover the same
    /// area, so this is a plain cross-fade (shading of 3-D faces).
    static func layers(_ la: Look?, _ lb: Look?, _ t: Double) -> [(Look, Fade)] {
        let a: Look, b: Look
        switch (la, lb) {
        case (let x?, let y?) where x != y:
            (a, b) = (x, y)
        case (let x?, _), (nil, let x?):
            return [(x, Fade(fill: 1.0, stroke: 1.0))]
        case (nil, nil):
            return []
        }
        func side(_ onA: Bool, _ onB: Bool) -> Double {
            switch (onA, onB) {
            case (true, true): 1.0
            case (true, false): 1.0 - t
            case (false, true): t
            case (false, false): 0.0
            }
        }
        let (stroke, line) = (a.stroke || b.stroke, side(a.stroke, b.stroke))
        let (fa, fb) = (a.fill != .none, b.fill != .none)
        if fa && fb {
            let (under, over, alpha) = (a.evenOdd || !b.evenOdd) ? (a, b, t) : (b, a, 1.0 - t)
            var u = under
            u.stroke = stroke
            var o = over
            o.stroke = false
            return [(u, Fade(fill: 1.0, stroke: line)), (o, Fade(fill: alpha, stroke: 0.0))]
        }
        var filled = fa ? a : b
        filled.stroke = stroke
        return [(filled, Fade(fill: side(fa, fb), stroke: line))]
    }
}

/// Two shape geometries brought to the same structure once, then blended per frame with `at`. Sub-paths
/// pair up in order; one without partner grows out of (or shrinks into) a point. When a pair differs in
/// fill mode, outline or fill rule, the two looks cross-fade (see `Morph.Fade`).
public struct GeometryMorph: Sendable, Hashable {
    var parts: [Morph.Part]
    var text: (Rect, Rect)

    /// `a` and `b` each in their own shape-local space.
    public init(_ a: Preset.Geometry, _ b: Preset.Geometry) {
        let ca = a.paths.map { Morph.contours($0.path) }
        let cb = b.paths.map { Morph.contours($0.path) }
        let ba = Morph.bounds(ca.joined().flatMap(\.pts))
        let bb = Morph.bounds(cb.joined().flatMap(\.pts))
        var parts: [Morph.Part] = []
        for k in 0 ..< Swift.max(a.paths.count, b.paths.count) {
            let (pa, pb) = Morph.align(ca.at(k) ?? [], cb.at(k) ?? [], ba, bb)
            parts.append(Morph.Part(a: a.paths.at(k).map(Morph.look), b: b.paths.at(k).map(Morph.look), ca: pa, cb: pb))
        }
        self.parts = parts
        text = (a.textRect, b.textRect)
    }

    /// The geometry at `t` (0..1), with a fade for each of its sub-paths. The points of `a` are first
    /// scaled by `sa` and those of `b` by `sb`, to bring both into the current box.
    public func at(_ tIn: Double, _ sa: Vec2, _ sb: Vec2) -> (Preset.Geometry, [Morph.Fade]) {
        let t = tIn.isFinite ? tIn.clamp(0.0, 1.0) : 0.0
        func scale(_ p: Point, _ s: Vec2) -> Point { Point(p.x * s.x, p.y * s.y) }
        var paths: [Preset.SubPath] = []
        var fades: [Morph.Fade] = []
        for part in parts {
            let cs: [Morph.Contour] = zip(part.ca, part.cb).map { x, y in
                Morph.Contour(closed: x.closed && y.closed, pts: zip(x.pts, y.pts).map { scale($0, sa).lerp(scale($1, sb), t) })
            }
            let path = Morph.toPath(cs)
            for (lk, fade) in Morph.layers(part.a, part.b, t) {
                paths.append(Preset.SubPath(path: path, fill: lk.fill, stroke: lk.stroke, evenOdd: lk.evenOdd))
                fades.append(fade)
            }
        }
        func r(_ r: Rect, _ s: Vec2) -> Rect { Rect(r.x0 * s.x, r.y0 * s.y, r.x1 * s.x, r.y1 * s.y) }
        let (ta, tb) = (r(text.0, sa), r(text.1, sb))
        let textRect = Rect.fromPoints(ta.origin.lerp(tb.origin, t), Point(ta.x1, ta.y1).lerp(Point(tb.x1, tb.y1), t))
        return (Preset.Geometry(paths: paths, textRect: textRect, handles: [], sites: []), fades)
    }

    public static func == (a: GeometryMorph, b: GeometryMorph) -> Bool {
        a.parts == b.parts && a.text.0 == b.text.0 && a.text.1 == b.text.1
    }

    public func hash(into h: inout Hasher) {
        h.combine(parts)
        h.combine(text.0)
        h.combine(text.1)
    }
}
