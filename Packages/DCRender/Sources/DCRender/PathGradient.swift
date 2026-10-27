// DCRender — path gradients (`a:path`) that follow a rectangle or the shape's own outline, which no
// canvas gradient draws: they're rasterised into a small image of the bounds and painted with it. Port of
// deckcraft crates/render/src/pathgrad.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Measured on PowerPoint's export (black to grey to white from the centre):
// - `rect`: the colour position is the larger of the horizontal and vertical distances from the focus,
//   each as a share of the distance to that side's edge (X-shaped contours);
// - `shape`: contours are the outline scaled about the focus (an ellipse gives ellipses, a triangle
//   triangles): the share of the way from the focus to the outline along the same ray.
//
// `circle` stays a radial gradient (see `PaintFill.gradient`).
import DCColor
import DCCore
import DCGeometry

public enum PathGradient {
    /// Longest side of the rasterised gradient, in pixels (bilinear sampling smooths the rest).
    static let maxSide = 384.0

    /// Most pixel × outline-edge tests one `shape` gradient may cost; a denser outline is simplified to
    /// fit (each pixel tests every edge).
    static let maxEdgeWork: UInt64 = 64_000_000

    /// Fewest edges a simplified polygon keeps, so a coarse outline still has a shape.
    static let minPolyEdges = 8

    /// Colour position (0 at the focus, 1 at the edge) of `p` for path `kind` in `bounds` with the focus
    /// rect `focus` (fractions inset from left, top, right, bottom), `outline` being the shape's
    /// flattened polygon(s) for `shape`.
    public static func position(_ kind: String, _ bounds: Rect, _ focus: [Double], _ outline: [[Point]], _ p: Point) -> Double {
        func fc(_ i: Int) -> Double { (focus.at(i) ?? 0).clamped(0.0, 1.0) }
        var f = Rect(
            bounds.x0 + bounds.width * fc(0), bounds.y0 + bounds.height * fc(1),
            bounds.x1 - bounds.width * fc(2), bounds.y1 - bounds.height * fc(3)
        )
        if !(f.x0 <= f.x1 && f.y0 <= f.y1) {
            let c = f.center
            f = Rect(c.x, c.y, c.x, c.y)
        }
        if rustEqual(kind, "shape") && !outline.isEmpty {
            // A focus rectangle (not a point) is the first colour throughout, as PowerPoint draws it;
            // outside, the colour runs from the rectangle's edge to the outline along the ray from its
            // centre.
            if f.width > 1e-9 && f.height > 1e-9 {
                if f.contains(p) { return 0.0 }
                let c = f.center
                let toOutline = shapePosition(outline, c, p)
                let d = (p - c).hypot
                if toOutline <= 0.0 || d <= 0.0 { return 1.0 }
                // Where the ray leaves the focus rectangle, as a share of the way to `p`.
                let v = p - c
                let kx = Swift.abs(v.x) > 1e-12 ? (f.width / 2.0) / Swift.abs(v.x) : Double.infinity
                let ky = Swift.abs(v.y) > 1e-12 ? (f.height / 2.0) / Swift.abs(v.y) : Double.infinity
                let rectShare = kx.rustMin(ky).rustMin(1.0)
                // p is `toOutline` of the way to the outline; the rectangle edge `rectShare` of the way
                // to p.
                let outlineShare = 1.0 / toOutline
                return ((1.0 - rectShare) / (outlineShare - rectShare).rustMax(1e-9)).clamped(0.0, 1.0)
            }
            return shapePosition(outline, f.center, p)
        }
        // Distance outside the focus rect along each axis, over the room to that side's edge.
        func axis(_ v: Double, _ lo: Double, _ hi: Double, _ edgeLo: Double, _ edgeHi: Double) -> Double {
            if v < lo { return (lo - v) / (lo - edgeLo).rustMax(1e-9) }
            if v > hi { return (v - hi) / (edgeHi - hi).rustMax(1e-9) }
            return 0.0
        }
        return axis(p.x, f.x0, f.x1, bounds.x0, bounds.x1).rustMax(axis(p.y, f.y0, f.y1, bounds.y0, bounds.y1)).clamped(0.0, 1.0)
    }

    /// The share of the way from `c` to the outline along the ray through `p` (1 when the ray meets no
    /// edge).
    static func shapePosition(_ outline: [[Point]], _ c: Point, _ p: Point) -> Double {
        let d = p - c
        if d.hypot < 1e-9 { return 0.0 }
        // The outline scaled about `c` by t reaches `p` first (smallest t) where the ray's farthest
        // crossing does: the only crossing for a focus inside a convex outline, and the one that still
        // works for a focus off the shape (a corner of an ellipse's box).
        var best = Double.infinity
        for poly in outline where poly.count >= 2 {
            for i in 0 ..< poly.count - 1 {
                let (a, b) = (poly[i], poly[i + 1])
                let e = b - a
                let den = d.cross(e)
                if Swift.abs(den) < 1e-12 { continue }
                let ac = a - c
                let s = ac.cross(e) / den
                let u = ac.cross(d) / den
                if s > 1e-9 && u >= -1e-9 && u <= 1.0 + 1e-9 {
                    best = best.isFinite ? best.rustMax(s) : s
                }
            }
        }
        return best.isFinite ? (1.0 / best).clamped(0.0, 1.0) : 1.0
    }

    /// The outline flattened into closed polygons.
    public static func polygons(_ path: BezPath) -> [[Point]] {
        var out: [[Point]] = []
        var cur: [Point] = []
        flatten(path.elements, 0.25) { el in
            switch el {
            case .moveTo(let p):
                if cur.count > 1 { out.append(cur) }
                cur = [p]
            case .lineTo(let p):
                cur.append(p)
            case .closePath:
                if let f = cur.first { cur.append(f) }
            default:
                break
            }
        }
        if cur.count > 1 { out.append(cur) }
        for i in out.indices {
            if let f = out[i].first, let l = out[i].last, (f - l).hypot > 1e-9 { out[i].append(f) }
        }
        return out.filter { $0.count > 2 && $0.count < 100_000 }
    }

    static func edges(_ o: [[Point]]) -> Int { o.reduce(0) { $0 + max($1.count - 1, 0) } }

    /// `outline` cut down to at most about `maxEdges` edges in total: first by dropping points closer
    /// than `tol` to the last kept one (detail finer than a raster pixel), then, if still too many, by
    /// keeping every k-th point. Each polygon stays closed. Returns it unchanged when it fits.
    static func simplify(_ outline: [[Point]], _ tol: Double, _ maxEdges: Int) -> [[Point]] {
        if edges(outline) <= maxEdges { return outline }
        let tol = tol.isFinite && tol > 0.0 ? tol : 0.0
        var out: [[Point]] = outline.map { poly in
            var kept: [Point] = []
            kept.reserveCapacity(poly.count)
            for p in poly where kept.last.map({ (p - $0).hypot >= tol }) ?? true { kept.append(p) }
            if let l = poly.last, let k = kept.last, k != l { kept.append(l) }
            return kept
        }.filter { $0.count > 2 }
        let total = edges(out)
        if total > maxEdges {
            let m = max(maxEdges, 1)
            let k = max((total + m - 1) / m, 2)
            for i in out.indices {
                let n = out[i].count
                if n <= minPolyEdges + 1 { continue }
                let kk = max(min(k, (n - 1) / minPolyEdges), 1)
                let last = out[i].last
                var kept = Swift.stride(from: 0, to: n, by: kk).map { out[i][$0] }
                if let l = last, let q = kept.last, q != l { kept.append(l) }
                out[i] = kept
            }
            // Polygons too small to thin stay whole; drop the smallest ones if they alone overflow.
            if edges(out) > maxEdges {
                // A stable sort, longest first (Rust's `sort_by_key` with `Reverse`).
                out = out.enumerated().sorted { a, b in
                    a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
                }.map(\.element)
                var sum = 0
                out = out.filter { p in
                    sum = sum.addingReportingOverflow(max(p.count - 1, 0)).partialValue
                    return sum <= maxEdges
                }
            }
        }
        return out
    }

    /// A 256-entry colour ramp for the sorted, already expanded `stops` (linear in sRGB between them).
    public static func ramp(_ stops: [(Double, Rgba)]) -> [Rgba] {
        (0 ..< 256).map { i -> Rgba in
            let t = Double(i) / 255.0
            let after = stops.firstIndex { $0.0 >= t }
            if after == nil || after == 0 {
                return stops.at(after ?? max(stops.count - 1, 0))?.1 ?? .black
            }
            let j = after ?? 0
            guard let a = stops.at(j - 1), let b = stops.at(j) else { return .black }
            let k = b.0 - a.0 > 1e-12 ? (t - a.0) / (b.0 - a.0) : 1.0
            return a.1.lerp(b.1, k)
        }
    }

    /// Fill `path` with a `rect` or `shape` path gradient of `stops` (sorted and expanded, see
    /// `Ramp.expand`) over `bounds`, faded by `alpha`; `m` maps the path to the output.
    public static func fill(_ c: Canvas, _ kind: String, _ focus: [Double], _ stops: [(Double, Rgba)], _ bounds: Rect, _ path: BezPath, _ m: Affine, _ alpha: Double) {
        if bounds.width <= 0.0 || bounds.height <= 0.0 || !bounds.isFinite || stops.isEmpty { return }
        var k = scaleOf(m)
        if !(k.isFinite && k > 0.0) { k = 1.0 }
        let longest = bounds.width.rustMax(bounds.height) * k
        let s = (maxSide / longest).rustMin(1.0) * k
        let pw = Int(min(max(UInt32(rustCast: (bounds.width * s).rounded(.up)), 1), 4096))
        let ph = Int(min(max(UInt32(rustCast: (bounds.height * s).rounded(.up)), 1), 4096))
        var outline: [[Point]] = []
        if rustEqual(kind, "shape") {
            let pixels = max(UInt64(pw) * UInt64(ph), 1)
            let maxEdges = max(Int(clamping: maxEdgeWork / pixels), minPolyEdges)
            let pixel = (bounds.width / Double(pw)).rustMin(bounds.height / Double(ph))
            outline = simplify(polygons(path), pixel, maxEdges)
        }
        let lut = ramp(stops)
        let a = alpha.clamped(0.0, 1.0)
        var data = [UInt8](repeating: 0, count: pw * ph * 4)
        for j in 0 ..< ph {
            for i in 0 ..< pw {
                let p = Point(bounds.x0 + (Double(i) + 0.5) / Double(pw) * bounds.width,
                              bounds.y0 + (Double(j) + 0.5) / Double(ph) * bounds.height)
                let t = position(kind, bounds, focus, outline, p)
                let col = lut.at(Int(rustCast: (t * 255.0).rounded().clamped(0.0, 255.0))) ?? .black
                let ca = (Double(col.a) * a).rounded().clamped(0.0, 255.0)
                func mul(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Double(v) * ca / 255.0).rounded().clamped(0.0, 255.0)) }
                let o = (j * pw + i) * 4
                data[o] = mul(col.r)
                data[o + 1] = mul(col.g)
                data[o + 2] = mul(col.b)
                data[o + 3] = UInt8(rustCast: ca)
            }
        }
        guard let image = RenderImage(width: pw, height: ph, pixels: data).cgImage() else { return }
        c.setTransform(m)
        c.setPaint(.image(image, xExtend: .pad, yExtend: .pad, quality: .medium, alpha: 1.0))
        c.setPaintTransform(Affine.translate(bounds.origin.toVec2) * Affine.scaleNonUniform(bounds.width / Double(pw), bounds.height / Double(ph)))
        c.fillPath(path)
        c.resetPaintTransform()
    }
}
