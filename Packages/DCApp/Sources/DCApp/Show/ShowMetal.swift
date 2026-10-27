// DCApp — the slide show's GPU compositor (PLAN.md §5.1): every slide is rendered once by DCRender into an
// `MTLTexture`; a transition frame is DCAnim's `transitionFrame` layers drawn as `layerMesh` triangles,
// premultiplied and blended source-over on black, with DCRender's CPU `compositeTransition` coverage, sampling and
// arithmetic (`ShowExact`; deckcraft's egui meshes in `show.rs` `quad_mesh`). Video frames, the shapes above a playing video and
// solid fills are quads through the same pipeline. The shaders are compiled from source at first use, so the
// package needs no Metal resource step.
import DCAnim
import DCCore
import DCMedia
import DCRender
import Metal
import QuartzCore
import simd

/// One textured or solid draw: triangles in output pixels.
struct ShowDraw {
    var texture: MTLTexture?
    /// x, y (pixels), u, v, then premultiplied r, g, b, a, per vertex; or, for an `exact` draw, `ShowExact`'s
    /// 24-word vertices.
    var vertices: [Float] = []
    var indices: [UInt32] = []
    /// Drawn by the exact pipeline (`show_exact_*`): coverage, sampling and opacity as the CPU compositor has them.
    var exact = false

    /// A quad over `rect` (pixels) showing `uv` of the texture, faded by `alpha`.
    static func quad(_ texture: MTLTexture?, _ rect: CGRect, uv: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), color: SIMD4<Float> = SIMD4(1, 1, 1, 1)) -> ShowDraw {
        let (x0, y0, x1, y1) = (Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY))
        let (u0, v0, u1, v1) = (Float(uv.minX), Float(uv.minY), Float(uv.maxX), Float(uv.maxY))
        let c = color
        return ShowDraw(texture: texture, vertices: [
            x0, y0, u0, v0, c.x, c.y, c.z, c.w,
            x1, y0, u1, v0, c.x, c.y, c.z, c.w,
            x1, y1, u1, v1, c.x, c.y, c.z, c.w,
            x0, y1, u0, v1, c.x, c.y, c.z, c.w,
        ], indices: [0, 1, 2, 0, 2, 3])
    }

    /// A transition layer over `rect` (`quad_mesh`): `layerMesh`'s triangles, each drawn by the exact pipeline
    /// over its bounding box, with per-vertex opacity; a solid `color` when there is no texture.
    static func layer(_ texture: MTLTexture?, _ rect: CGRect, _ l: Layer, solid color: SIMD3<Float> = SIMD3(1, 1, 1)) -> ShowDraw {
        let (verts, tris) = layerMesh(l)
        var d = ShowDraw(texture: texture, exact: true)
        let tint = texture == nil ? SIMD4(color.x, color.y, color.z, 1) : SIMD4<Float>(1, 1, 1, 1)
        for t in tris {
            guard let a = verts.at(Int(t.x)), let b = verts.at(Int(t.y)), let c = verts.at(Int(t.z)) else { continue }
            ShowExact.append(&d, rect, (a, b, c), tint)
        }
        return d
    }
}

/// The exact pipeline's triangles: DCRender's CPU compositor (`fillTriangle`) on the GPU. The GPU's own
/// rasteriser samples pixel centres with vertices snapped to its sub-pixel grid and breaks ties with the
/// top-left rule; the CPU samples a hair past each centre in double precision. Transitions put many edges
/// exactly through rows, columns or diagonals of centres (Checkerboard's and Glitter's tiles, Crush's 45° folds),
/// and there the two disagree: one-pixel lines of the wrong slide or of black along every tile, which
/// SSIMULACRA2 punishes hard. So each triangle is drawn as its bounding box, a pixel wider, and the fragment
/// shader decides coverage the CPU's way: edge functions of the vertices in fixed point (1/16384 px) evaluated
/// exactly in 64-bit integers at the pixel centre, the CPU's nudge (+1.17e-6, +2.31e-6) breaking a tie; the
/// barycentric texture coordinate and opacity; and the CPU's bilinear sampling.
enum ShowExact {
    /// Fixed-point steps per pixel.
    static let k = 16384.0
    /// Words per vertex (the shader's `ExactVertex`).
    static let words = 24

    static func fixed(_ v: Double) -> Int32 {
        let f = (v * k).rounded()
        return f.isFinite ? Int32(f.clamped(-1_073_741_824, 1_073_741_823)) : 0
    }

    /// Append one triangle (unit positions in `rect`) as its bounding-box quad.
    static func append(_ d: inout ShowDraw, _ rect: CGRect, _ tri: (MeshVertex, MeshVertex, MeshVertex), _ tint: SIMD4<Float>) {
        let vs = [tri.0, tri.1, tri.2]
        let ps = vs.map { SIMD2(rect.minX + $0.pos[0] * rect.width, rect.minY + $0.pos[1] * rect.height) }
        guard ps.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let al = vs.map { Float($0.a.isFinite ? $0.a.clamped(0, 1) : 0) }
        if al.allSatisfy({ $0 <= 0 }) { return }
        let x0 = (ps.map(\.x).min() ?? 0) - 1, x1 = (ps.map(\.x).max() ?? 0) + 1
        let y0 = (ps.map(\.y).min() ?? 0) - 1, y1 = (ps.map(\.y).max() ?? 0) + 1
        var payload: [Float] = []
        for p in ps { payload += [Float(bitPattern: UInt32(bitPattern: fixed(p.x))), Float(bitPattern: UInt32(bitPattern: fixed(p.y)))] }
        for v in vs { payload += [Float(v.uv[0]), Float(v.uv[1])] }
        payload += [0, 0, al[0], al[1], al[2], 0, tint.x, tint.y, tint.z, tint.w]
        let base = UInt32(d.vertices.count / words)
        for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] { d.vertices += [Float(x), Float(y)] + payload }
        d.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }
}

/// The textures of one transition frame (`Source` → texture).
struct ShowTransitionTextures {
    var old: MTLTexture?
    var new: MTLTexture
    /// Old back, old content, new back, new content (`part_textures`); nil when the transition doesn't use them.
    var parts: [MTLTexture?]?
}

@MainActor
final class ShowMetal {
    static let shared: ShowMetal? = ShowMetal()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [MTLPixelFormat.RawValue: MTLRenderPipelineState] = [:]
    private var exactPipelines: [MTLPixelFormat.RawValue: MTLRenderPipelineState] = [:]
    let sampler: MTLSamplerState
    /// 1×1 white: what solid draws sample.
    let white: MTLTexture

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; float4 color; };
    vertex VOut show_vertex(const device float *v [[buffer(0)]], constant float2 &size [[buffer(1)]], uint vid [[vertex_id]]) {
        const device float *p = v + vid * 8;
        VOut o;
        o.pos = float4(p[0] / size.x * 2.0 - 1.0, 1.0 - p[1] / size.y * 2.0, 0.0, 1.0);
        o.uv = float2(p[2], p[3]);
        o.color = float4(p[4], p[5], p[6], p[7]);
        return o;
    }
    fragment float4 show_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv) * in.color;
    }

    // The exact pipeline (ShowExact): DCRender's `fillTriangle` per pixel.
    struct ExactVertex { float2 pos; int2 p0; int2 p1; int2 p2; float2 uv0; float2 uv1; float2 uv2; float4 a; float4 tint; };
    struct EOut {
        float4 pos [[position]];
        int2 p0 [[flat]]; int2 p1 [[flat]]; int2 p2 [[flat]];
        float2 uv0 [[flat]]; float2 uv1 [[flat]]; float2 uv2 [[flat]];
        float4 a [[flat]]; float4 tint [[flat]];
    };
    vertex EOut show_exact_vertex(const device ExactVertex *v [[buffer(0)]], constant float2 &size [[buffer(1)]], uint vid [[vertex_id]]) {
        ExactVertex e = v[vid];
        EOut o;
        o.pos = float4(e.pos.x / size.x * 2.0 - 1.0, 1.0 - e.pos.y / size.y * 2.0, 0.0, 1.0);
        o.p0 = e.p0; o.p1 = e.p1; o.p2 = e.p2;
        o.uv0 = e.uv0; o.uv1 = e.uv1; o.uv2 = e.uv2;
        o.a = e.a; o.tint = e.tint;
        return o;
    }
    // The CPU's edge function at the pixel centre `c` (fixed point), its nudged sample breaking a tie.
    static float exact_edge(long2 a, long2 b, long2 c) {
        long e = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (e != 0) { return float(e); }
        return float(b.x - a.x) * 2.31e-6 - float(b.y - a.y) * 1.17e-6;
    }
    static float4 exact_texel(texture2d<float> tex, int x, int y) {
        return tex.read(uint2(uint(x), uint(y))) * 255.0;
    }
    fragment float4 show_exact_fragment(EOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        const long K = 16384;
        long2 c = long2(long(floor(in.pos.x)) * K + K / 2, long(floor(in.pos.y)) * K + K / 2);
        long2 p0 = long2(in.p0), p1 = long2(in.p1), p2 = long2(in.p2);
        long area = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y);
        if (area == 0) { discard_fragment(); }
        float e0 = exact_edge(p1, p2, c), e1 = exact_edge(p2, p0, c), e2 = exact_edge(p0, p1, c);
        float sa = area > 0 ? 1.0 : -1.0;
        if (e0 * sa < 0.0 || e1 * sa < 0.0 || e2 * sa < 0.0) { discard_fragment(); }
        float fa = float(area);
        float w0 = e0 / fa, w1 = e1 / fa, w2 = e2 / fa;
        float alpha = w0 * in.a.x + w1 * in.a.y + w2 * in.a.z;
        if (alpha <= 0.0) { discard_fragment(); }
        float2 uv = w0 * in.uv0 + w1 * in.uv1 + w2 * in.uv2;
        // The CPU's bilinear sampling: texel centres at half pixels, clamped to the edge.
        int w = int(tex.get_width()), h = int(tex.get_height());
        float x = clamp(uv.x * float(w) - 0.5, 0.0, float(w - 1));
        float y = clamp(uv.y * float(h) - 0.5, 0.0, float(h - 1));
        if (isnan(x)) { x = 0.0; }
        if (isnan(y)) { y = 0.0; }
        int x0 = int(floor(x)), y0 = int(floor(y));
        int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
        float fx = x - float(x0), fy = y - float(y0);
        float4 top = mix(exact_texel(tex, x0, y0), exact_texel(tex, x1, y0), fx);
        float4 bot = mix(exact_texel(tex, x0, y1), exact_texel(tex, x1, y1), fx);
        float4 s = mix(top, bot, fy) * float4(in.tint.xyz, 1.0);
        return s * alpha / 255.0;
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let white = device.makeTexture(descriptor: td) else { return nil }
        let px: [UInt8] = [255, 255, 255, 255]
        px.withUnsafeBytes { raw in
            if let base = raw.baseAddress { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 4) }
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.sampler = sampler
        self.white = white
    }

    /// The pipeline drawing into `format`: premultiplied source-over; `exact`, the CPU compositor's triangles.
    func pipeline(_ format: MTLPixelFormat, exact: Bool = false) -> MTLRenderPipelineState? {
        if let p = (exact ? exactPipelines : pipelines)[format.rawValue] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: exact ? "show_exact_vertex" : "show_vertex")
        d.fragmentFunction = library.makeFunction(name: exact ? "show_exact_fragment" : "show_fragment")
        let a = d.colorAttachments[0]
        a?.pixelFormat = format
        a?.isBlendingEnabled = true
        a?.rgbBlendOperation = .add
        a?.alphaBlendOperation = .add
        a?.sourceRGBBlendFactor = .one
        a?.sourceAlphaBlendFactor = .one
        a?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        if exact { exactPipelines[format.rawValue] = p } else { pipelines[format.rawValue] = p }
        return p
    }

    // MARK: Textures

    /// A texture of premultiplied RGBA8 pixels (DCRender's output); nil for an empty or oversized image.
    func texture(_ img: RenderImage, reuse: MTLTexture? = nil) -> MTLTexture? {
        texture(width: img.width, height: img.height, pixels: img.pixels, reuse: reuse)
    }

    /// A texture of a decoded video frame (straight RGBA, opaque).
    func texture(_ f: Frame, reuse: MTLTexture? = nil) -> MTLTexture? {
        texture(width: Int(f.width), height: Int(f.height), pixels: f.rgba, reuse: reuse)
    }

    func texture(width w: Int, height h: Int, pixels: [UInt8], reuse: MTLTexture?) -> MTLTexture? {
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let (n, o) = w.multipliedReportingOverflow(by: h * 4)
        guard !o, pixels.count >= n else { return nil }
        let tex: MTLTexture
        if let r = reuse, r.width == w, r.height == h, r.pixelFormat == .rgba8Unorm {
            tex = r
        } else {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            td.usage = .shaderRead
            td.storageMode = .shared
            guard let t = device.makeTexture(descriptor: td) else { return nil }
            tex = t
        }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: w * 4)
        }
        return tex
    }

    // MARK: Drawing

    /// Encode `draws` into a pass over a target of `size` pixels.
    func encode(_ enc: MTLRenderCommandEncoder, _ draws: [ShowDraw], size: CGSize, format: MTLPixelFormat) {
        guard let p = pipeline(format), let pe = pipeline(format, exact: true) else { return }
        enc.setRenderPipelineState(p)
        var current = false
        enc.setFragmentSamplerState(sampler, index: 0)
        var vp = SIMD2<Float>(Float(Swift.max(size.width, 1)), Float(Swift.max(size.height, 1)))
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for d in draws where !d.indices.isEmpty {
            let vbytes = d.vertices.count * MemoryLayout<Float>.stride
            let ibytes = d.indices.count * MemoryLayout<UInt32>.stride
            guard vbytes > 0,
                  let vb = d.vertices.withUnsafeBytes({ r in r.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: vbytes, options: .storageModeShared) } }),
                  let ib = d.indices.withUnsafeBytes({ r in r.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: ibytes, options: .storageModeShared) } })
            else { continue }
            if d.exact != current {
                enc.setRenderPipelineState(d.exact ? pe : p)
                current = d.exact
            }
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentTexture(d.texture ?? white, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indices.count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        }
    }

    /// The draws of transition `kind`/`option` at progress `t` over `rect` (the slide on screen, in pixels): the
    /// layer sources resolved as `show.rs` does (a missing old slide is black, a missing part falls back to its
    /// whole slide or is left out).
    static func transitionDraws(_ kind: String, _ option: String, _ t: Double, aspect: Double, rect: CGRect, _ tex: ShowTransitionTextures) -> [ShowDraw] {
        var out: [ShowDraw] = []
        let part: (Int) -> MTLTexture? = { tex.parts?.at($0) ?? nil }
        for l in transitionFrame(kind, option, t, aspect) {
            if !(l.alpha.isFinite && l.alpha > 0) { continue }
            let black = SIMD3<Float>(0, 0, 0), white = SIMD3<Float>(1, 1, 1)
            func oldOrBlack(_ t: MTLTexture?) -> ShowDraw { t.map { ShowDraw.layer($0, rect, l) } ?? ShowDraw.layer(nil, rect, l, solid: black) }
            switch l.source {
            case .old: out.append(oldOrBlack(tex.old))
            case .new: out.append(.layer(tex.new, rect, l))
            case .black: out.append(.layer(nil, rect, l, solid: black))
            case .white: out.append(.layer(nil, rect, l, solid: white))
            case .oldBack: out.append(oldOrBlack(part(0) ?? tex.old))
            case .newBack: out.append(.layer(part(2) ?? tex.new, rect, l))
            case .oldContent: if let p = part(1) { out.append(.layer(p, rect, l)) }
            case .newContent: if let p = part(3) { out.append(.layer(p, rect, l)) }
            }
        }
        return out
    }

    /// Render `draws` over black into a new RGBA8 image of `width`×`height` (tests and `ui.screenshot`).
    func renderOffscreen(_ draws: [ShowDraw], width: Int, height: Int, clear: SIMD4<Double> = SIMD4(0, 0, 0, 1)) -> RenderImage? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        encode(enc, draws, size: CGSize(width: width, height: height), format: .rgba8Unorm)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            target.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return RenderImage(width: width, height: height, pixels: px)
    }
}
