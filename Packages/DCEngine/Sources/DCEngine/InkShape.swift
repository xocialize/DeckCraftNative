// DCEngine — Draw › Ink to Shape: recognise a hand-drawn stroke as a line, rectangle, ellipse or triangle.
// Port of deckcraft crates/engine/src/inkshape.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Pure geometry so it is unit-tested with synthetic strokes. A stroke is closed when its ends meet; a
// closed stroke is classified by how much of its bounding box it covers (rectangle ≈ 1, ellipse ≈ π/4,
// triangle ≈ ½) and, for ellipses, by how evenly it keeps its distance from the centre.
import DCCore
import Foundation

public enum InkShape {
    /// What a stroke was recognised as, in its bounding box `(x, y, w, h)`.
    public enum Recognized: Sendable, Equatable {
        /// From `(x0, y0)` to `(x1, y1)`.
        case line(x0: Double, y0: Double, x1: Double, y1: Double)
        case rect(x: Double, y: Double, w: Double, h: Double)
        case ellipse(x: Double, y: Double, w: Double, h: Double)
        /// Apex at the top (`flipV` false) or at the bottom.
        case triangle(x: Double, y: Double, w: Double, h: Double, flipV: Bool)
    }

    /// Strokes smaller than this (points) stay ink.
    static let minSize = 6.0
    static let maxPoints = 100_000

    public static func recognize(_ points: [(Double, Double)]) -> Recognized? {
        let pts = Array(points.lazy.filter { $0.0.isFinite && $0.1.isFinite }.prefix(maxPoints))
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        var (x0, y0, x1, y1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for (x, y) in pts {
            x0 = x0.rustMin(x)
            y0 = y0.rustMin(y)
            x1 = x1.rustMax(x)
            y1 = y1.rustMax(y)
        }
        let (w, h) = (x1 - x0, y1 - y0)
        let size = w.rustMax(h)
        if !size.isFinite || size < minSize { return nil }
        var length = 0.0
        for i in 1 ..< pts.count { length += Foundation.hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1) }
        let gap = Foundation.hypot(last.0 - first.0, last.1 - first.1)
        if length <= 0 { return nil }
        // Open stroke: a line if nearly straight, otherwise not a shape.
        if gap > 0.25 * size {
            return gap / length > 0.92 ? .line(x0: first.0, y0: first.1, x1: last.0, y1: last.1) : nil
        }
        // Closed but flat: a line drawn back and forth isn't a shape.
        if w.rustMin(h) < 0.15 * size { return nil }
        // Covered area (shoelace, the gap closed) over the bounding box.
        var a2 = 0.0
        for k in 0 ..< pts.count {
            let (p, q) = (pts[k], pts[(k + 1) % pts.count])
            a2 += p.0 * q.1 - q.0 * p.1
        }
        let cover = (Swift.abs(a2) / 2.0) / (w * h)
        // Ellipse fit: distance from the centre in box-normalised units should stay near 1.
        let (cx, cy) = (x0 + w / 2.0, y0 + h / 2.0)
        var spreadSum = 0.0
        for (x, y) in pts { spreadSum += Swift.abs(Foundation.hypot((x - cx) / (w / 2.0), (y - cy) / (h / 2.0)) - 1.0) }
        let spread = spreadSum / Double(pts.count)
        if cover > 0.86 {
            return .rect(x: x0, y: y0, w: w, h: h)
        } else if cover > 0.66 && spread < 0.12 {
            return .ellipse(x: x0, y: y0, w: w, h: h)
        } else if cover >= 0.35 && cover < 0.66 {
            // Apex: the side of the box with fewer points near it is where the triangle narrows.
            let nearTop = pts.filter { $0.1 < y0 + h * 0.15 }.count
            let nearBottom = pts.filter { $0.1 > y1 - h * 0.15 }.count
            return .triangle(x: x0, y: y0, w: w, h: h, flipV: nearBottom < nearTop)
        }
        return nil
    }
}
