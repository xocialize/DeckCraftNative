// DCRender — 3-D bevels (`a:sp3d/a:bevelT` seen through a `a:scene3d`), approximated in 2-D: the shape's
// face and a band inside its outline as wide as the bevel are lit as surfaces, the band's normal tilting out
// towards the outline by the bevel profile's slope. Port of deckcraft crates/render/src/bevel.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Fitted by deckcraft to PowerPoint's export of bevel presets on a solid-filled shape with the default
// three-point light rig and matte material (Light.swift), within about 15 grey levels RMS across the band.
import DCColor
import DCCore
import DCGeometry

/// A top bevel: its width and height in points and its preset.
public struct Bevel: Sendable, Equatable {
    public var w: Double
    public var h: Double
    public var preset: String
    /// The light rig and material that light it.
    public var lighting: Lighting

    /// Longest side of the rasterised lighting, in pixels.
    static let maxSide = 512.0

    public init(w: Double, h: Double, preset: String, lighting: Lighting) {
        self.w = w
        self.h = h
        self.preset = preset
        self.lighting = lighting
    }

    /// The top bevel of 3-D XML kept from the file (`scene3d` + `sp3d`), when it has both a scene (without
    /// one PowerPoint draws the shape flat) and a `bevelT`.
    public static func fromRaw(_ raw: String) -> Bevel? {
        if !raw.contains("scene3d") || !raw.contains("sp3d") { return nil }
        // A 3-D shape without a bevel still has its face lit: a bevel of no width.
        guard let i = raw.range(of: "bevelT") else {
            return Bevel(w: 0, h: 0, preset: "circle", lighting: .fromRaw(raw))
        }
        let rest = raw[i.lowerBound...]
        guard let e = rest.firstIndex(of: ">") else { return nil }
        let tag = rest[..<e]
        func emu(_ n: String) -> Double? { xmlAttr(tag, n).flatMap(rustParseF64).map { $0 / 12700.0 } }
        let w = (emu("w") ?? 6).clamped(0, 2000)
        let h = (emu("h") ?? 6).clamped(0, 2000)
        guard w > 0 else { return nil }
        return Bevel(w: w, h: h, preset: xmlAttr(tag, "prst") ?? "circle", lighting: .fromRaw(raw))
    }

    /// The bevel surface's rise per unit inwards (in units of h / w) at `u` (0 at the outline, 1 at the
    /// inner edge of the band), by preset.
    static func slope(_ preset: String, _ u: Double) -> Double {
        let u = u.clamped(1e-3, 1)
        switch preset {
        case "angle": return 1
        // A quarter circle, steep at the outline and flat where it meets the face; the default, and used
        // for the presets not modelled.
        default:
            let v = 1 - u
            return v / (1 - v * v).rustMax(1e-6).squareRoot()
        }
    }

    /// The distance to the nearest edge of a polygon set and that edge's outward normal (edges oriented by
    /// each polygon's signed area).
    static func nearestEdge(_ polys: [[Point]], _ areas: [Double], _ p: Point) -> (Double, Vec2)? {
        var best: (Double, Vec2)?
        for (poly, area) in zip(polys, areas) where poly.count >= 2 {
            for k in 1 ..< poly.count {
                let (a, b) = (poly[k - 1], poly[k])
                let e = b - a
                let l2 = e.hypot2
                if l2 < 1e-12 { continue }
                let t = ((p - a).dot(e) / l2).clamped(0, 1)
                let d = (p - (a + e * t)).hypot
                if best.map({ d < $0.0 }) ?? true {
                    // Outward normal: for a polygon of positive (clockwise on screen, y down) area the outside
                    // is to the left of each edge's direction.
                    let n = Vec2(e.y, -e.x) / l2.squareRoot()
                    best = (d, area > 0 ? n : -n)
                }
            }
        }
        return best
    }

    /// Draws bevel `bv`'s lit face and band over a shape filled with `fill` (a solid colour, or nil for
    /// any other fill, which gets the band's highlights and shading as light and dark veils) inside `path`
    /// (shape space, laid out in `bounds`), `m` mapping it to the output.
    public static func draw(_ c: Canvas, _ bv: Bevel, _ fill: Rgba?, _ path: BezPath, _ bounds: Rect, _ m: Affine, _ alpha: Double) {
        let (w, h, preset, lit) = (bv.w, bv.h, bv.preset, bv.lighting)
        if bounds.width <= 0 || bounds.height <= 0 || !bounds.isFinite { return }
        // No bevel: only the face, one lit colour.
        if w <= 0 {
            if let fill {
                c.setTransform(m)
                c.setPaint(.color(lit.shade(fill, [0, 0, 1]), alpha))
                c.fillPath(path)
            }
            return
        }
        var k = scaleOf(m)
        if !(k.isFinite && k > 0) { k = 1 }
        let longest = bounds.width.rustMax(bounds.height) * k
        let s = (Bevel.maxSide / longest).rustMin(1) * k
        let pw = Int(min(max(UInt32(rustCast: (bounds.width * s).rounded(.up)), 1), 2048))
        let ph = Int(min(max(UInt32(rustCast: (bounds.height * s).rounded(.up)), 1), 2048))
        let polys = PathGradient.polygons(path)
        if polys.isEmpty { return }
        let areas = polys.map { p -> Double in
            var sum = 0.0
            for i in 1 ..< p.count { sum += p[i - 1].x * p[i].y - p[i].x * p[i - 1].y }
            return sum / 2
        }
        let face = lit.factor([0, 0, 1])
        let ratio = w > 0 ? h / w : 0
        let a = alpha.clamped(0, 1)
        var data = [UInt8](repeating: 0, count: pw * ph * 4)
        for j in 0 ..< ph {
            for i in 0 ..< pw {
                let fx: Double = (Double(i) + 0.5) / Double(pw) * bounds.width
                let fy: Double = (Double(j) + 0.5) / Double(ph) * bounds.height
                let p = Point(bounds.x0 + fx, bounds.y0 + fy)
                var n: [Double] = [0, 0, 1]
                if let (d, e) = Bevel.nearestEdge(polys, areas, p), d < w {
                    let z = Bevel.slope(preset, d / w) * ratio
                    let v = [e.x * z, e.y * z, 1.0]
                    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
                    n = [v[0] / len, v[1] / len, v[2] / len]
                }
                let f = lit.factor(n)
                let o = (j * pw + i) * 4
                if let fill {
                    let lc = lit.shade(fill, n)
                    let ca = Double(fill.a) * a / 255
                    func pm(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Double(v) * ca).rounded().clamped(0, 255)) }
                    data[o] = pm(lc.r)
                    data[o + 1] = pm(lc.g)
                    data[o + 2] = pm(lc.b)
                    data[o + 3] = UInt8(rustCast: (ca * 255).rounded())
                } else {
                    // A veil: white where the band is lighter than the face, black where darker.
                    let d = ((f - face) * 1.5).clamped(-1, 1)
                    let va = UInt8(rustCast: (Swift.abs(d) * a * 255).rounded().clamped(0, 255))
                    let v: UInt8 = d > 0 ? va : 0
                    data[o] = v
                    data[o + 1] = v
                    data[o + 2] = v
                    data[o + 3] = va
                }
            }
        }
        guard let img = RenderImage(width: pw, height: ph, pixels: data).cgImage() else { return }
        c.setTransform(m)
        c.setPaint(.image(img, xExtend: .pad, yExtend: .pad, quality: .medium, alpha: 1))
        c.setPaintTransform(Affine.translate(bounds.origin.toVec2) * Affine.scaleNonUniform(bounds.width / Double(pw), bounds.height / Double(ph)))
        c.fillPath(path)
        c.resetPaintTransform()
    }
}
