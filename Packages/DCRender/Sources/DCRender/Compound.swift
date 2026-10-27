// DCRender — compound outlines (`a:ln/@cmpd`): double, thick-thin, thin-thick and triple lines. Port of
// deckcraft crates/render/src/compound.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// PowerPoint splits the line's width into bands across the path, measured from its left side (looking
// along the path) to its right, as these shares of the width (read from PowerPoint's export of 24 pt
// lines of each kind):
// - double: 1/3 line, 1/3 gap, 1/3 line;
// - thin-thick: 1/5 line, 1/5 gap, 3/5 line; thick-thin the mirror;
// - triple: 1/6 line, 1/6 gap, 1/3 line, 1/6 gap, 1/6 line.
//
// On a shape drawn clockwise (all presets) the left side is the outside.
import DCGeometry
import DCModel

public enum CompoundLine {
    /// The bands of `c` as (from, to) shares of the width, left side first.
    public static func bands(_ c: Compound) -> [(Double, Double)] {
        switch c {
        case .single: [(0.0, 1.0)]
        case .double: [(0.0, 1.0 / 3.0), (2.0 / 3.0, 1.0)]
        case .thinThick: [(0.0, 0.2), (0.4, 1.0)]
        case .thickThin: [(0.0, 0.6), (0.8, 1.0)]
        case .triple: [(0.0, 1.0 / 6.0), (2.0 / 6.0, 4.0 / 6.0), (5.0 / 6.0, 1.0)]
        }
    }

    /// Unit normal pointing to the right of travel (y down), or nil for a zero-length tangent.
    static func right(_ t: Vec2) -> Vec2? {
        let l = t.hypot
        return l > 1e-12 && l.isFinite ? Vec2(-t.y, t.x) / l : nil
    }

    /// `path` moved `d` to the right of travel (negative: to the left). Line corners meet at their miter
    /// point (bevelled when sharper than about 11°); curves are offset by kurbo; other joins are bridged
    /// by a straight line.
    public static func offset(_ path: BezPath, _ d: Double, _ tolerance: Double) -> BezPath {
        if Swift.abs(d) < 1e-9 { return path }
        var out: [PathEl] = []
        var segs: [PathSeg] = []
        func flush(_ closed: Bool) {
            let pieces: [(PathSeg, BezPath)] = segs.compactMap { s in offsetSeg(s, d, tolerance).map { (s, $0) } }
            let begin = out.count
            for (i, (seg, piece)) in pieces.enumerated() {
                guard case .moveTo(let p) = piece.elements.first else { continue }
                if let (prev, _) = i >= 1 ? pieces.at(i - 1) : nil {
                    join(&out, prev, seg, p, d)
                } else {
                    out.append(.moveTo(p))
                }
                out.append(contentsOf: piece.elements.dropFirst())
            }
            if closed, let (last, _) = pieces.last, let (first, piece) = pieces.first {
                if case .moveTo(let p) = piece.elements.first {
                    // Lines meeting at the start: both ends move to their miter point.
                    if let m = miter(last, first, d), isLine(last), isLine(first) {
                        setLast(&out, m)
                        if case .moveTo = out.at(begin) { out[begin] = .moveTo(m) }
                    } else {
                        out.append(.lineTo(p))
                    }
                }
                out.append(.closePath)
            }
            segs.removeAll()
        }
        var start = Point.zero
        var cur = Point.zero
        for el in path.elements {
            switch el {
            case .moveTo(let p):
                flush(false)
                start = p
                cur = p
            case .lineTo(let p):
                segs.append(.line(LineSeg(cur, p)))
                cur = p
            case .quadTo(let a, let b):
                segs.append(.quad(QuadBez(cur, a, b)))
                cur = b
            case .curveTo(let a, let b, let c):
                segs.append(.cubic(CubicBez(cur, a, b, c)))
                cur = c
            case .closePath:
                if (cur - start).hypot > 1e-9 { segs.append(.line(LineSeg(cur, start))) }
                flush(true)
                cur = start
            }
        }
        flush(false)
        return BezPath(out)
    }

    static func offsetSeg(_ s: PathSeg, _ d: Double, _ tolerance: Double) -> BezPath? {
        // Far-off or non-finite geometry (hostile files) is left out rather than offset.
        func sane(_ p: Point) -> Bool { p.isFinite && Swift.abs(p.x) < 1e7 && Swift.abs(p.y) < 1e7 }
        let ok: Bool
        switch s {
        case .line(let l): ok = sane(l.p0) && sane(l.p1)
        case .quad(let q): ok = sane(q.p0) && sane(q.p1) && sane(q.p2)
        case .cubic(let c): ok = sane(c.p0) && sane(c.p1) && sane(c.p2) && sane(c.p3)
        }
        if !ok || !d.isFinite { return nil }
        switch s {
        case .line(let l):
            guard let n = right(l.p1 - l.p0) else { return nil }
            var p = BezPath()
            p.moveTo(l.p0 + n * d)
            p.lineTo(l.p1 + n * d)
            return p
        case .quad(let q):
            return offsetSeg(.cubic(q.raise()), d, tolerance)
        case .cubic(let c):
            // Nearly straight cubics (collinear control points) are offset as lines.
            let chord = c.p3 - c.p0
            func flat(_ p: Point) -> Bool { Swift.abs(chord.cross(p - c.p0)) <= 1e-9 * chord.hypot2.rustMax(1e-18) }
            if flat(c.p1) && flat(c.p2) { return offsetSeg(.line(LineSeg(c.p0, c.p3)), d, tolerance) }
            return offsetCubic(c, d, tolerance)
        }
    }

    /// The segment's tangent at its start and at its end (the first non-zero control vector).
    static func tangents(_ s: PathSeg) -> (Vec2, Vec2) {
        func first(_ v: [Vec2]) -> Vec2 { v.first { $0.hypot2 > 1e-18 } ?? .zero }
        switch s {
        case .line(let l): return (l.p1 - l.p0, l.p1 - l.p0)
        case .quad(let q): return (first([q.p1 - q.p0, q.p2 - q.p0]), first([q.p2 - q.p1, q.p2 - q.p0]))
        case .cubic(let c):
            return (first([c.p1 - c.p0, c.p2 - c.p0, c.p3 - c.p0]), first([c.p3 - c.p2, c.p3 - c.p1, c.p3 - c.p0]))
        }
    }

    static func isLine(_ s: PathSeg) -> Bool {
        if case .line = s { return true }
        return false
    }

    /// Move the path's last point to `p`.
    static func setLast(_ out: inout [PathEl], _ p: Point) {
        guard let e = out.last else { return }
        switch e {
        case .moveTo: out[out.count - 1] = .moveTo(p)
        case .lineTo: out[out.count - 1] = .lineTo(p)
        case .quadTo(let a, _): out[out.count - 1] = .quadTo(a, p)
        case .curveTo(let a, let b, _): out[out.count - 1] = .curveTo(a, b, p)
        case .closePath: break
        }
    }

    /// Where the offsets of `prev` and `next` meet at their shared corner (their miter point), or nil
    /// for a corner sharper than about 11 degrees or a degenerate tangent.
    static func miter(_ prev: PathSeg, _ next: PathSeg, _ d: Double) -> Point? {
        let (_, t0) = tangents(prev)
        let (t1, _) = tangents(next)
        guard let n0 = right(t0), let n1 = right(t1) else { return nil }
        let denom = 1.0 + n0.dot(n1)
        guard denom > 0.02 else { return nil }
        let m = prev.end + (n0 + n1) * (d / denom)
        return m.isFinite ? m : nil
    }

    /// Join the offset of `prev` (ending at `out`'s current point) to the offset of `next`, which starts
    /// at `p`: two lines meet at their miter point (both ends moved there, so an inner corner doesn't
    /// loop); anything else is bridged straight.
    static func join(_ out: inout [PathEl], _ prev: PathSeg, _ next: PathSeg, _ p: Point, _ d: Double) {
        if let m = miter(prev, next, d) {
            if isLine(prev) && isLine(next) {
                setLast(&out, m)
            } else {
                out.append(.lineTo(m))
                out.append(.lineTo(p))
            }
        } else {
            out.append(.lineTo(p))
        }
    }
}
