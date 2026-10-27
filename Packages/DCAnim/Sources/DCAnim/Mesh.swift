// DCAnim — triangle meshes for transition layers. Port of deckcraft crates/anim/src/mesh.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A `Layer` is a textured quad. Drawn as two triangles, a trapezoid (a slide seen in perspective) bends its
// texture along the diagonal, because GPUs and simple rasterisers interpolate texture coordinates linearly
// in screen space. `layerMesh` splits such quads into a grid whose vertices follow the projective map from
// the source rectangle to the quad, so the picture looks like a flat card turned in 3-D. Rectangles and
// parallelograms stay two triangles, wedges one: the per-frame cost stays a handful of vertices per layer.
import DCCore

/// One mesh vertex: position in slide-unit space (0...1, y down), texture coordinate (0...1) and opacity
/// (the layer's alpha times its corner fade, interpolated).
public struct MeshVertex: Sendable, Equatable {
    public var pos: UnitPoint
    public var uv: UnitPoint
    public var a: Double

    public init(pos: UnitPoint, uv: UnitPoint, a: Double) {
        self.pos = pos
        self.uv = uv
        self.a = a
    }
}

/// Grid cells per side for quads that need a projective subdivision.
let meshGrid = 8

/// The triangles of a layer: vertices and index triples into them.
public func layerMesh(_ l: Layer) -> (vertices: [MeshVertex], triangles: [SIMD3<UInt32>]) {
    let q = l.quad
    let uv = l.uv
    let fa = SIMD4(l.fade[0] * l.alpha, l.fade[1] * l.alpha, l.fade[2] * l.alpha, l.fade[3] * l.alpha)
    // A wedge (triangle): the 4th corner repeats the 3rd.
    if q[3] == q[2] && uv[3] == uv[2] {
        let v = (0 ..< 3).map { k in MeshVertex(pos: q[k], uv: uv[k], a: fa[k]) }
        return (v, [SIMD3(0, 1, 2)])
    }
    // Parallelogram: opposite edges equal.
    let e1 = (q[1][0] - q[0][0], q[1][1] - q[0][1])
    let e2 = (q[2][0] - q[3][0], q[2][1] - q[3][1])
    let affine = Swift.abs(e1.0 - e2.0) < 1e-9 && Swift.abs(e1.1 - e2.1) < 1e-9
    guard !affine, let h = squareToQuad(q) else {
        let v = (0 ..< 4).map { k in MeshVertex(pos: q[k], uv: uv[k], a: fa[k]) }
        return (v, [SIMD3(0, 1, 2), SIMD3(0, 2, 3)])
    }
    // Small quads (tiles, shards) bend their texture too little to matter: fewer cells.
    var span = 0.0
    for p in q.corners {
        for r in q.corners { span = span.rustMax(Swift.abs(p[0] - r[0]).rustMax(Swift.abs(p[1] - r[1]))) }
    }
    let n = Swift.min(Swift.max(Int(rustCast: (span * 2.0 * Double(meshGrid)).rounded(.up)), 1), meshGrid)
    var v: [MeshVertex] = []
    v.reserveCapacity((n + 1) * (n + 1))
    for j in 0 ... n {
        let b = Double(j) / Double(n)
        for i in 0 ... n {
            let a = Double(i) / Double(n)
            // Texture: bilinear in (a, b) over the four uv corners (exact for rectangles).
            let top = lerp2(uv[0], uv[1], a)
            let bot = lerp2(uv[3], uv[2], a)
            let t = lerp2(top, bot, b)
            let at = fa[0] + (fa[1] - fa[0]) * a
            let ab = fa[3] + (fa[2] - fa[3]) * a
            v.append(MeshVertex(pos: apply(h, a, b), uv: t, a: at + (ab - at) * b))
        }
    }
    var tris: [SIMD3<UInt32>] = []
    tris.reserveCapacity(n * n * 2)
    let w = UInt32(n + 1)
    for j in 0 ..< UInt32(n) {
        for i in 0 ..< UInt32(n) {
            let p = j * w + i
            tris.append(SIMD3(p, p + 1, p + w + 1))
            tris.append(SIMD3(p, p + w + 1, p + w))
        }
    }
    return (v, tris)
}

private func lerp2(_ a: UnitPoint, _ b: UnitPoint, _ t: Double) -> UnitPoint {
    UnitPoint(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
}

/// Projective map taking the unit square's corners (0,0), (1,0), (1,1), (0,1) to `q`'s tl, tr, br, bl
/// (Heckbert's square-to-quad). nil when the quad is degenerate.
private func squareToQuad(_ q: Quad) -> [Double]? {
    let (x0, y0, x1, y1) = (q[0][0], q[0][1], q[1][0], q[1][1])
    let (x2, y2, x3, y3) = (q[2][0], q[2][1], q[3][0], q[3][1])
    let sx = x0 - x1 + x2 - x3
    let sy = y0 - y1 + y2 - y3
    let (dx1, dx2, dy1, dy2) = (x1 - x2, x3 - x2, y1 - y2, y3 - y2)
    let den = dx1 * dy2 - dx2 * dy1
    if !den.isFinite || Swift.abs(den) < 1e-12 { return nil }
    let g = (sx * dy2 - dx2 * sy) / den
    let h = (dx1 * sy - sx * dy1) / den
    let m = [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h]
    return m.allSatisfy(\.isFinite) ? m : nil
}

private func apply(_ m: [Double], _ u: Double, _ v: Double) -> UnitPoint {
    guard m.count == 8 else { return UnitPoint(0, 0) }
    var w = m[6] * u + m[7] * v + 1.0
    if Swift.abs(w) < 1e-9 { w = (1e-9 as Double).withSign(of: w) }
    return UnitPoint((m[0] * u + m[1] * v + m[2]) / w, (m[3] * u + m[4] * v + m[5]) / w)
}

extension Double {
    /// Rust's `copysign`.
    fileprivate func withSign(of s: Double) -> Double {
        Double(sign: s.sign, exponentBitPattern: exponentBitPattern, significandBitPattern: significandBitPattern)
    }
}
