// DCRender — 3-D extrusion (`a:sp3d extrusionH`, `a:extrusionClr`) seen through a turned camera, drawn in
// 2-D: quads join the shape's outline on its front face to the same outline on its back face (the camera's
// view of the depth axis), and the face is drawn on top as usual. Port of deckcraft
// crates/render/src/extrude.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Each side (one quad per flattened outline edge) is lit for its own normal by the shape's light rig and
// material, and the sides are drawn farthest first. Without a turned camera an extrusion points at the
// viewer and nothing of it shows.
import DCColor
import DCCore
import DCGeometry
import DCModel

/// An extrusion: its depth in points and its own colour, if set. Its static functions are extrude.rs's
/// free functions (sides and contours).
public struct Extrude: Sendable, Equatable {
    public var depth: Double
    public var color: ColorRef?

    /// Outlines with more edges than this (after flattening) are not extruded.
    static let maxEdges = 4096

    public init(depth: Double, color: ColorRef?) {
        self.depth = depth
        self.color = color
    }

    /// The extrusion in 3-D XML kept from the file (`a:sp3d extrusionH="…"` with an `a:scene3d`).
    public static func fromRaw(_ raw: String) -> Extrude? {
        if !raw.contains("scene3d") { return nil }
        guard let i = raw.range(of: "sp3d ") else { return nil }
        let rest = raw[i.lowerBound...]
        guard let e = rest.firstIndex(of: ">"), let v = xmlAttr(rest[..<e], "extrusionH"), let n = rustParseF64(v) else { return nil }
        let depth = n / 12700
        guard depth.isFinite && depth > 0.01 else { return nil }
        return Extrude(depth: depth.rustMin(4000), color: colorIn(raw, "extrusionClr"))
    }

    /// The side colour before lighting: the extrusion colour, or the face's.
    public static func sideColor(_ rctx: Resolve.Ctx, _ ex: Extrude, _ face: Rgba?) -> Rgba {
        ex.color.map { rctx.color($0, face) } ?? face ?? .rgb(0x80, 0x80, 0x80)
    }

    /// The camera's view of the depth axis: where the back face sits relative to the front face, in the
    /// turned shape's space (the space `Camera.affine` maps into).
    public static func backOffset(_ c: Camera, _ depth: Double, _ w: Double, _ h: Double) -> Vec2 {
        let size = w.rustMax(h)
        return c.project3(0, 0, -depth, size) - c.project3(0, 0, 0, size)
    }

    /// Draws the sides of `outline` (shape space, `w` × `h`): one quad per edge between the front face and
    /// the back face, each lit by `lit` for its own normal as camera `cam` sees it, farthest first. `pre`
    /// maps the turned shape's space to the output and `turn` is the camera's turn.
    public static func draw(
        _ c: Canvas, _ outline: BezPath, _ w: Double, _ h: Double, _ cam: Camera, _ depth: Double, _ pre: Affine,
        _ turn: Affine, _ side: Rgba, _ lit: Lighting
    ) {
        let offset = backOffset(cam, depth, w, h)
        let px = (pre * offset.toPoint - pre * Point.zero).hypot
        if !px.isFinite || px < 0.25 { return }
        let polys = PathGradient.polygons(outline)
        var quads: [(Double, BezPath, Rgba)] = []
        for poly in polys where poly.count <= maxEdges {
            var area = 0.0
            for i in 1 ..< poly.count { area += poly[i - 1].x * poly[i].y - poly[i].x * poly[i - 1].y }
            area /= 2
            for i in 1 ..< poly.count {
                let (a, b) = (poly[i - 1], poly[i])
                let d = b - a
                let len = d.hypot
                if len < 1e-9 { continue }
                // Outward normal in the shape's plane (as in the bevel), turned by the camera.
                let n0 = Vec2(d.y, -d.x) / len
                let n = area > 0 ? n0 : -n0
                let vn = cam.rotate([n.x, n.y, 0])
                if vn[2] < -0.02 { continue }
                let mid = a.midpoint(b)
                let z = cam.rotate([mid.x - w / 2, mid.y - h / 2, -depth / 2])[2]
                let (fa, fb) = (turn * a, turn * b)
                var q = BezPath()
                q.moveTo(fa)
                q.lineTo(fb)
                q.lineTo(fb + offset)
                q.lineTo(fa + offset)
                q.closePath()
                quads.append((z, q, lit.shade(side, vn)))
            }
        }
        // Rust's `sort_by` with `total_cmp`: stable, NaN last.
        quads = quads.enumerated().sorted { l, r in
            let (a, b) = (l.element.0, r.element.0)
            if a.isNaN != b.isNaN { return !a.isNaN }
            if a != b && !a.isNaN { return a < b }
            return l.offset < r.offset
        }.map(\.element)
        for (_, q, col) in quads {
            c.setTransform(pre)
            c.setPaint(.color(col, 1))
            c.fillPath(q)
            // Close the hairline seams between neighbouring quads.
            strokeScaled(c, q, pre, StrokeStyle(0.6 / scaleOf(pre).rustMax(1e-6)))
        }
    }

    /// The contour in 3-D XML kept from the file, if it has one.
    public static func contourFromRaw(_ raw: String) -> Contour? {
        guard let i = raw.range(of: "sp3d ") else { return nil }
        let rest = raw[i.lowerBound...]
        guard let e = rest.firstIndex(of: ">"), let v = xmlAttr(rest[..<e], "contourW"), let n = rustParseF64(v) else { return nil }
        let width = n / 12700
        guard width.isFinite && width > 0.01 else { return nil }
        return Contour(width: width.rustMin(2000), color: colorIn(raw, "contourClr"))
    }

    /// Draws a contour `width` around `outline` (shape space, mapped by `m`), lit as a surface facing the
    /// viewer.
    public static func drawContour(_ c: Canvas, _ outline: BezPath, _ m: Affine, _ width: Double, _ color: Rgba, _ lit: Lighting) {
        c.setPaint(.color(lit.shade(color, [0, 0, 1]), 1))
        strokeScaled(c, outline, m, StrokeStyle(2 * width).withJoin(.round))
    }

    /// Strokes `path` with `style` under `m` as kurbo would, with the outline worked out at the output's
    /// scale: CoreGraphics flattens a stroke's joins and curves in user space, too coarsely when `m` blows a
    /// small shape space up (a group's child space a hundredth of a point per unit), where vello strokes the
    /// transformed path.
    static func strokeScaled(_ c: Canvas, _ path: BezPath, _ m: Affine, _ style: StrokeStyle) {
        var k = scaleOf(m)
        if !(k.isFinite && k > 1e-9) { k = 1 }
        var s = style
        s.width *= k
        c.setTransform(m * Affine.scale(1 / k))
        c.setStroke(s)
        c.strokePath(transformed(path, Affine.scale(k)))
    }
}

/// A 3-D contour: a band of `width` points around the shape's outline (`a:sp3d contourW`, `a:contourClr`),
/// drawn behind the face so only its outer half shows past the outline.
public struct Contour: Sendable, Equatable {
    public var width: Double
    public var color: ColorRef?

    public init(width: Double, color: ColorRef?) {
        self.width = width
        self.color = color
    }
}

/// The colour in the first `<a:{name}>` element of `raw` (an `srgbClr` or a `schemeClr`).
func colorIn(_ raw: String, _ name: String) -> ColorRef? {
    guard let j = raw.range(of: "\(name)>") else { return nil }
    let body0 = raw[j.lowerBound...]
    let end = body0.range(of: "/a:\(name)")?.lowerBound ?? body0.range(of: "/\(name)")?.lowerBound ?? body0.endIndex
    let body = body0[..<end]
    if let k = body.range(of: "srgbClr ") {
        guard let v = xmlAttr(body[k.lowerBound...], "val"), let n = UInt32(v, radix: 16), !v.hasPrefix("-") else { return nil }
        return .rgb(.rgb(UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)))
    }
    if let k = body.range(of: "schemeClr ") {
        guard let v = xmlAttr(body[k.lowerBound...], "val") else { return nil }
        return SchemeSlot.fromXML(v).map(ColorRef.scheme)
    }
    return nil
}
