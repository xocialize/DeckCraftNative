// DCGeometry — rectangles with smoothed ("squircle") corners, as design tools offer next to the corner
// radius (#286). Port of deckcraft crates/geom/src/squircle.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
//
// A plain rounded corner joins the straight edge with a sudden change of curvature; a smoothed corner
// starts curving earlier, along a cubic Bézier, and keeps a shorter circular arc in the middle, so the
// outline flows into the edge. For a corner of radius `r` and smoothing `s` (0 = circular, 1 = no arc
// left), the corner takes `p = (1 + s) · r` of each edge. The arc keeps `90° · (1 − s)` around the
// corner's diagonal and each side of it is a cubic whose handles lie on the edge, so the curve is tangent
// to the edge where it starts and to the arc where it meets it. When `p` would exceed half the shorter
// side, the smoothing is reduced first, then the radius. The construction is deckcraft's own derivation
// from these constraints.
import Darwin

public enum Squircle {
    /// The outline of a `w` x `h` rectangle with corners of radius `radius` smoothed by `smoothing`
    /// (0...1), as path data in the rectangle's own coordinates (`M`, `L`, `C`, `Z`; y down).
    public static func pathD(_ wIn: Double, _ hIn: Double, _ radius: Double, _ smoothing: Double) -> String {
        let w = wIn.isFinite ? fmax(wIn, 0.0) : 0.0
        let h = hIn.isFinite ? fmax(hIn, 0.0) : 0.0
        let half = fmin(w, h) / 2.0
        let r = radius.isFinite ? radius.clamp(0.0, half) : 0.0
        var s = smoothing.isFinite ? smoothing.clamp(0.0, 1.0) : 0.0
        if r <= 0.0 {
            let (ws, hs) = (rustDisplay(w), rustDisplay(h))
            return "M 0 0 L \(ws) 0 L \(ws) \(hs) L 0 \(hs) Z"
        }
        s = fmax(fmin(s, half / r - 1.0), 0.0)
        let c = corner(r, s)
        // The top-right corner in local terms: `u` runs back along the top edge from the corner, `v` down
        // the right edge. Each corner maps (u, v) to the rectangle by symmetry.
        let corners: [(Double, Double) -> (Double, Double)] = [
            { u, v in (w - u, v) }, // top right: from the top edge to the right edge
            { u, v in (w - v, h - u) }, // bottom right: from the right edge to the bottom edge
            { u, v in (u, h - v) }, // bottom left: from the bottom edge to the left edge
            { u, v in (v, u) }, // top left: from the left edge to the top edge
        ]
        func pt(_ f: (Double, Double) -> (Double, Double), _ uv: (Double, Double)) -> String {
            let (x, y) = f(uv.0, uv.1)
            return "\(rustDisplay(round(x))) \(rustDisplay(round(y)))"
        }
        var d = ""
        for (i, f) in corners.enumerated() {
            let segs = c.segments
            d += i == 0 ? "M \(pt(f, segs[0]))" : " L \(pt(f, segs[0]))"
            for k in 0 ..< 3 {
                let b = 1 + k * 3
                d += " C \(pt(f, segs[b])) \(pt(f, segs[b + 1])) \(pt(f, segs[b + 2]))"
            }
        }
        d += " Z"
        return d
    }

    static func round(_ v: Double) -> Double {
        (v * 1000.0).rounded() / 1000.0 + 0.0
    }

    /// One corner in (u, v) terms: distance back along the incoming edge, distance along the outgoing.
    struct Corner {
        var p: Double
        var a: Double
        var b: Double
        var c: Double
        var d: Double
        var r: Double
        var arc: Double

        /// Ten points: the start on the incoming edge, then three cubics (control, control, end): edge →
        /// arc start, the arc, arc end → outgoing edge.
        var segments: [(Double, Double)] {
            // Edge curve into the arc: handles on the edge, ending where the arc starts.
            let e0 = (p, 0.0)
            let e1 = (p - a, 0.0)
            let e2 = (p - a - b, 0.0)
            // The arc around the centre (r, r) in (u, v), symmetric about the corner's diagonal. Angles
            // from +u towards +v: the corner itself is at 5π/4 from the centre; the arc runs from the
            // incoming edge's side (larger angle) to the outgoing edge's side.
            let start = Double.pi / 4.0 * 5.0 + arc / 2.0
            let end = start - arc
            func at(_ t: Double) -> (Double, Double) { (r + r * sinCos(t).cos, r + r * sinCos(t).sin) }
            let k = 4.0 / 3.0 * Darwin.tan(arc / 4.0) * r
            let a0 = at(start)
            let a3 = at(end)
            // Tangent of the arc travelled towards smaller angles: (sin t, −cos t).
            let a1 = (a0.0 + k * sinCos(start).sin, a0.1 - k * sinCos(start).cos)
            let a2 = (a3.0 - k * sinCos(end).sin, a3.1 + k * sinCos(end).cos)
            // Mirror of the edge curve onto the outgoing edge (swap u and v), reversed.
            let o1 = (e2.1, e2.0)
            let o2 = (e1.1, e1.0)
            let o3 = (e0.1, e0.0)
            return [e0, e1, e2, a0, a1, a2, a3, o1, o2, o3]
        }
    }

    static func corner(_ r: Double, _ s: Double) -> Corner {
        let p = (1.0 + s) * r
        let arc = Double.pi / 2.0 * (1.0 - s)
        // The arc's chord, and where the edge curve meets the arc.
        let arcChord = Darwin.sin(arc / 2.0) * r * 1.414_213_562_373_095_048_801_688_724_209_698_079 // SQRT_2
        let alpha = (Double.pi / 2.0 - arc) / 2.0
        let p3p4 = r * Darwin.tan(alpha / 2.0)
        let beta = Double.pi / 4.0 * s
        let c = p3p4 * Darwin.cos(beta)
        let d = c * Darwin.tan(beta)
        let b = fmax((p - arcChord - c - d) / 3.0, 0.0)
        let a = 2.0 * b
        return Corner(p: p, a: a, b: b, c: c, d: d, r: r, arc: arc)
    }
}

/// Rust's `Display` for `f64` (`format!("{}", v)`): the shortest digits that read back, written without
/// an exponent, integers without a fraction (`168`, `0.5`, `-0`, `1000000000000000000000`).
func rustDisplay(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    let sign = v.sign == .minus ? "-" : ""
    // Swift's description gives the same shortest digits; re-lay them out without an exponent.
    let desc = v.magnitude.description
    var mantissa = Substring(desc)
    var exponent = 0
    if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = desc[..<e]
        exponent = Int(desc[desc.index(after: e)...]) ?? 0
    }
    var digits: [Character] = []
    var afterPoint = 0
    var seenPoint = false
    for c in mantissa {
        if c == "." {
            seenPoint = true
        } else if c.isASCII, c.isNumber {
            digits.append(c)
            if seenPoint { afterPoint += 1 }
        }
    }
    var k = exponent - afterPoint // value = digits × 10^k
    while let f = digits.first, f == "0", digits.count > 1 { digits.removeFirst() }
    while let l = digits.last, l == "0", digits.count > 1 {
        digits.removeLast()
        k += 1
    }
    if digits == ["0"] { return sign + "0" }
    if k >= 0 { return sign + String(digits) + String(repeating: "0", count: k) }
    let point = digits.count + k
    if point > 0 {
        return sign + String(digits[..<point]) + "." + String(digits[point...])
    }
    return sign + "0." + String(repeating: "0", count: -point) + String(digits)
}
