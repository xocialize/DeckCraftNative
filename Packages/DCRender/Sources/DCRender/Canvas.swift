// DCRender — the drawing surface deckcraft's renderer paints on: vello_cpu's `RenderContext` model (a
// current transform, paint, paint transform, fill rule and stroke; fills and strokes of kurbo paths;
// layers with a clip, a blend/compose mode, an opacity and a Gaussian blur) implemented on
// CoreGraphics, so the ported drawing code reads as the Rust does.
//
// Pixels are premultiplied RGBA8 in sRGB, rows top to bottom, as deckcraft's `Image`. Every layer
// that blends, composes, fades or blurs is its own offscreen bitmap, composited back through a
// CoreGraphics blend mode over the whole canvas (which gives Porter-Duff `SrcIn`/`DestIn`/`DestOut`
// exactly, as vello does); a layer that only clips uses the CoreGraphics clip.
import Accelerate
import CoreGraphics
import DCColor
import DCCore
import DCGeometry

/// A rendered image: premultiplied RGBA8, rows top to bottom (deckcraft-render `Image`).
public struct RenderImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int = 0, height: Int = 0, pixels: [UInt8] = []) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Straight (unpremultiplied) RGBA.
    public func toStraight() -> [UInt8] {
        var out = pixels
        var i = 0
        while i + 3 < out.count {
            let a = UInt32(out[i + 3])
            if a != 0 && a != 255 {
                for c in 0 ..< 3 { out[i + c] = UInt8(min(255, (UInt32(out[i + c]) * 255 + a / 2) / a)) }
            }
            i += 4
        }
        return out
    }

    /// One pixel as straight RGBA; nil outside the image.
    public func straight(_ x: Int, _ y: Int) -> [UInt8]? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        guard i + 3 < pixels.count else { return nil }
        let a = UInt32(pixels[i + 3])
        if a == 0 || a == 255 { return Array(pixels[i ..< i + 4]) }
        return (0 ..< 3).map { UInt8(min(255, (UInt32(pixels[i + $0]) * 255 + a / 2) / a)) } + [UInt8(a)]
    }

    /// The image as a `CGImage` (premultiplied, sRGB).
    public func cgImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Canvas.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// peniko's colour stop, with the extend modes deckcraft uses.
public struct ColorStop: Sendable, Equatable {
    public var offset: Double
    public var color: Rgba
    public var alpha: Double

    public init(_ offset: Double, _ color: Rgba, alpha: Double = 1) {
        self.offset = offset
        self.color = color
        self.alpha = alpha
    }
}

public enum Extend: Sendable, Equatable { case pad, `repeat`, reflect }

public enum ImageQuality: Sendable, Equatable { case low, medium, high }

public enum Paint: Sendable {
    /// A colour with an extra opacity (deckcraft's `color(c, alpha)`).
    case solid(Rgba, Double)
    case linear(start: Point, end: Point, stops: [ColorStop], extend: Extend)
    /// Two-point radial: the start circle to the end circle (peniko `new_two_point_radial`; `new_radial`
    /// is a zero start radius at the same centre).
    case radial(c0: Point, r0: Double, c1: Point, r1: Double, stops: [ColorStop], extend: Extend)
    /// An image in its own pixel space (mapped by the paint transform, then the transform).
    case image(CGImage, xExtend: Extend, yExtend: Extend, quality: ImageQuality, alpha: Double)

    public static func color(_ c: Rgba, _ alpha: Double = 1) -> Paint { .solid(c, alpha) }
}

public enum FillRule: Sendable { case nonZero, evenOdd }
public enum StrokeJoin: Sendable { case miter, round, bevel }
public enum StrokeCap: Sendable { case butt, round, square }

/// kurbo's `Stroke` as deckcraft builds it: `Stroke::new(width)` is round joins and caps, miter limit 4.
public struct StrokeStyle: Sendable, Equatable {
    public var width: Double
    public var join: StrokeJoin = .round
    public var miterLimit: Double = 4
    public var cap: StrokeCap = .round
    public var dashes: [Double] = []
    public var dashOffset: Double = 0

    public init(_ width: Double) {
        self.width = width
    }

    public func withJoin(_ j: StrokeJoin) -> StrokeStyle { var s = self; s.join = j; return s }
    public func withCaps(_ c: StrokeCap) -> StrokeStyle { var s = self; s.cap = c; return s }
    public func withMiterLimit(_ m: Double) -> StrokeStyle { var s = self; s.miterLimit = m; return s }
    public func withDashes(_ offset: Double, _ pattern: [Double]) -> StrokeStyle {
        var s = self
        s.dashOffset = offset
        s.dashes = pattern
        return s
    }
}

/// peniko's blend: a separable/non-separable mix and a Porter-Duff compose.
public enum Mix: Sendable { case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, hardLight, softLight, difference, exclusion, hue, saturation, color, luminosity }
public enum Compose: Sendable { case clear, copy, dest, srcOver, destOver, srcIn, destIn, srcOut, destOut, srcAtop, destAtop, xor, plus }

public struct BlendMode: Sendable, Equatable {
    public var mix: Mix
    public var compose: Compose

    public init(_ mix: Mix, _ compose: Compose) {
        self.mix = mix
        self.compose = compose
    }

    var cg: CGBlendMode {
        switch compose {
        case .clear: return .clear
        case .copy: return .copy
        case .dest: return .destinationOver // drawing nothing over the destination: approximated
        case .destOver: return .destinationOver
        case .srcIn: return .sourceIn
        case .destIn: return .destinationIn
        case .srcOut: return .sourceOut
        case .destOut: return .destinationOut
        case .srcAtop: return .sourceAtop
        case .destAtop: return .destinationAtop
        case .xor: return .xor
        case .plus: return .plusLighter
        case .srcOver: break
        }
        switch mix {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .hardLight: return .hardLight
        case .softLight: return .softLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
}

/// A premultiplied RGBA8 bitmap and the CoreGraphics context drawing into it, in canvas space (y down):
/// the bitmap covers the canvas pixels from (`x`, `y`), `width` × `height`.
final class Surface {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let data: UnsafeMutableRawPointer
    let ctx: CGContext

    init?(x: Int = 0, y: Int = 0, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.x = x
        self.y = y
        let bytes = width * height * 4
        data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        guard let c = CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: Canvas.srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            data.deallocate()
            return nil
        }
        ctx = c
        self.width = width
        self.height = height
        // y down, origin top left, as vello's pixmap; canvas coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = .medium
    }

    deinit { data.deallocate() }

    var bytes: UnsafeMutableBufferPointer<UInt8> {
        UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
    }

    /// The bitmap as an image, copied.
    func image() -> CGImage? { ctx.makeImage() }
}

public final class Canvas {
    static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public let width: Int
    public let height: Int
    private let base: Surface
    private enum Entry {
        /// A layer that couldn't be made (out of memory): drawing goes on below it.
        case none
        case layer(Surface, clip: BezPath?, clipTransform: Affine, fillRule: FillRule, blend: BlendMode, opacity: Double, blur: Double)
    }

    private var stack: [Entry] = []
    public private(set) var transform: Affine = .identity
    public private(set) var paintTransform: Affine = .identity
    public private(set) var paint: Paint = .solid(.black, 1)
    public var fillRule: FillRule = .nonZero
    public var stroke = StrokeStyle(1)

    /// Records instead of drawing (for vector output, `DisplayList`); nil on a raster canvas.
    let recorder: DisplayList.Recorder?

    public init?(width: Int, height: Int) {
        guard let s = Surface(width: width, height: height) else { return nil }
        base = s
        recorder = nil
        self.width = width
        self.height = height
    }

    /// A canvas that draws nothing and records every fill and layer, for `recording()`: the same
    /// drawing replayed as vector paths (PDF) or onto a raster canvas at any scale.
    public init?(recordingWidth width: Int, height: Int) {
        guard width > 0, height > 0, let s = Surface(width: 1, height: 1) else { return nil }
        base = s
        recorder = DisplayList.Recorder()
        self.width = width
        self.height = height
    }

    /// What a recording canvas recorded (open layers are closed first); empty on a raster canvas.
    public func recording() -> DisplayList {
        guard let r = recorder else { return DisplayList(width: width, height: height, ops: []) }
        while !r.stack.isEmpty { r.pop() }
        return DisplayList(width: width, height: height, ops: r.ops)
    }

    var current: Surface {
        for e in stack.reversed() {
            if case .layer(let s, _, _, _, _, _, _) = e { return s }
        }
        return base
    }

    public func setTransform(_ m: Affine) { transform = m }
    public func setPaint(_ p: Paint) { paint = p }
    public func setPaintTransform(_ m: Affine) { paintTransform = m }
    public func resetPaintTransform() { paintTransform = .identity }
    public func setStroke(_ s: StrokeStyle) { stroke = s }
    public func setFillRule(_ r: FillRule) { fillRule = r }

    // MARK: Drawing

    public func fillRect(_ r: Rect) {
        var p = BezPath()
        p.moveTo(Point(r.x0, r.y0))
        p.lineTo(Point(r.x1, r.y0))
        p.lineTo(Point(r.x1, r.y1))
        p.lineTo(Point(r.x0, r.y1))
        p.closePath()
        fillPath(p)
    }

    public func fillPath(_ path: BezPath) {
        guard path.isFinite, !path.isEmpty else { return }
        fillArea(Self.cgPath(path), evenOdd: fillRule == .evenOdd)
    }

    /// Fills a CoreGraphics path (user space) with the current paint, transform and paint transform.
    func fillArea(_ area: CGPath, evenOdd: Bool) {
        if let r = recorder {
            r.add(.fill(DisplayList.Fill(area: area, transform: transform, paint: paint, paintTransform: paintTransform, evenOdd: evenOdd)))
            return
        }
        let ctx = current.ctx
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(Self.cg(transform))
        Self.paintArea(ctx, area, evenOdd: evenOdd, paint, paintTransform, raster: true)
    }

    public func strokePath(_ path: BezPath) {
        guard path.isFinite, !path.isEmpty, stroke.width.isFinite, stroke.width > 0 else { return }
        // The outline is computed in user space (as kurbo strokes before the transform), but flattened
        // finely enough for the device: user space is scaled up by the transform's larger scale first
        // and back down after, so a stroke in a group's child space scaled 100× keeps smooth curves.
        let (sx, sy) = Self.scales(transform)
        let k = Swift.max(sx, sy).isFinite ? Swift.max(1, Swift.min(Swift.max(sx, sy), 1e4)) : 1
        var up = CGAffineTransform(scaleX: k, y: k)
        guard let cg = Self.cgPath(path).copy(using: &up) else { return }
        let dashes = stroke.dashes.filter { $0.isFinite && $0 >= 0 }.map { $0 * k }
        let outlined = cg.copy(
            strokingWithWidth: stroke.width * k,
            lineCap: stroke.cap == .round ? .round : stroke.cap == .square ? .square : .butt,
            lineJoin: stroke.join == .round ? .round : stroke.join == .bevel ? .bevel : .miter,
            miterLimit: stroke.miterLimit
        )
        let shape: CGPath
        if !dashes.isEmpty, dashes.contains(where: { $0 > 0 }) {
            let dashed = cg.copy(dashingWithPhase: stroke.dashOffset * k, lengths: dashes.map { CGFloat($0) })
            shape = dashed.copy(
                strokingWithWidth: stroke.width * k,
                lineCap: stroke.cap == .round ? .round : stroke.cap == .square ? .square : .butt,
                lineJoin: stroke.join == .round ? .round : stroke.join == .bevel ? .bevel : .miter,
                miterLimit: stroke.miterLimit
            )
        } else {
            shape = outlined
        }
        var down = CGAffineTransform(scaleX: 1 / k, y: 1 / k)
        fillArea(k == 1 ? shape : (shape.copy(using: &down) ?? shape), evenOdd: false)
    }

    /// Fills `area` (user space, already under the transform) with `paint`, mapped by `paintTransform`.
    /// `raster`: drawing into a bitmap, where a strongly magnified picture is enlarged exactly first
    /// (`Upscale`).
    static func paintArea(_ ctx: CGContext, _ area: CGPath, evenOdd: Bool, _ paint: Paint, _ paintTransform: Affine, raster: Bool = false) {
        switch paint {
        case .solid(let c, let alpha):
            ctx.setFillColor(Self.cgColor(c, alpha))
            ctx.addPath(area)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        case .linear(let s, let e, let stops, let extend):
            ctx.addPath(area)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            ctx.concatenate(Self.cg(paintTransform))
            drawLinear(ctx, s, e, stops, extend, bounds: area.boundingBoxOfPath, paintTransform)
        case .radial(let c0, let r0, let c1, let r1, let stops, _):
            ctx.addPath(area)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            ctx.concatenate(Self.cg(paintTransform))
            guard let fn = Self.gradientFunction(stops) else { return }
            if let sh = CGShading(
                radialSpace: Self.srgb, start: CGPoint(x: c0.x, y: c0.y), startRadius: max(0, r0),
                end: CGPoint(x: c1.x, y: c1.y), endRadius: max(0, r1), function: fn, extendStart: true, extendEnd: true
            ) {
                ctx.drawShading(sh)
            }
        case .image(let img, let xe, let ye, let quality, let alpha):
            ctx.addPath(area)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            ctx.concatenate(Self.cg(paintTransform))
            ctx.setAlpha(alpha.clamped(0, 1))
            ctx.interpolationQuality = quality == .low ? .none : quality == .medium ? .medium : .high
            drawImage(ctx, img, xe, ye, magnify: raster && quality != .low)
        }
    }

    private static func drawImage(_ ctx: CGContext, _ img: CGImage, _ xe: Extend, _ ye: Extend, magnify: Bool = false) {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        if xe == .pad && ye == .pad {
            let drawn = magnify ? Upscale.factor(img, ctx.ctm).flatMap { Upscale.bilinear(img, $0) } ?? img : img
            ctx.saveGState()
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(drawn, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            return
        }
        // Repeat (and reflect, as a mirrored 2×2 tile): tile from the image origin across the clip.
        var tile = img
        var tw = w, th = h
        if xe == .reflect || ye == .reflect, let mirrored = Self.mirroredTile(img, x: xe == .reflect, y: ye == .reflect) {
            tile = mirrored
            tw = CGFloat(mirrored.width)
            th = CGFloat(mirrored.height)
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: th)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tw, height: th), byTiling: true)
        ctx.restoreGState()
    }

    private static func mirroredTile(_ img: CGImage, x: Bool, y: Bool) -> CGImage? {
        let w = img.width, h = img.height
        let tw = x ? 2 * w : w, th = y ? 2 * h : h
        guard let s = Surface(width: tw, height: th) else { return nil }
        let c = s.ctx
        for (fx, fy) in [(false, false), (true, false), (false, true), (true, true)] where (!fx || x) && (!fy || y) {
            c.saveGState()
            let ox = CGFloat(fx ? w : 0), oy = CGFloat(fy ? h : 0)
            c.translateBy(x: ox + (fx ? CGFloat(w) : 0), y: oy + (fy ? 0 : CGFloat(h)))
            c.scaleBy(x: fx ? -1 : 1, y: fy ? 1 : -1)
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            c.restoreGState()
        }
        return s.image()
    }

    private static func drawLinear(_ ctx: CGContext, _ s: Point, _ e: Point, _ stops: [ColorStop], _ extend: Extend, bounds: CGRect, _ paintTransform: Affine) {
        guard let fn = Self.gradientFunction(stops, extend: extend) else { return }
        var a = s, b = e
        var domain: (Double, Double) = (0, 1)
        if extend != .pad {
            // Repeating: stretch the axis over the projection of the area so the function sees every t.
            let d = e - s
            let len2 = d.hypot2
            if len2 > 1e-18 {
                let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                               CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                    .map { CGPoint(x: $0.x, y: $0.y).applying(Self.cg(paintTransform).inverted()) }
                let ts = corners.map { (Point(Double($0.x), Double($0.y)) - s).dot(d) / len2 }
                let lo = (ts.min() ?? 0).rounded(.down), hi = (ts.max() ?? 1).rounded(.up)
                domain = (lo, max(hi, lo + 1))
                a = s + d * domain.0
                b = s + d * domain.1
            }
        }
        if let sh = CGShading(
            axialSpace: Self.srgb, start: CGPoint(x: a.x, y: a.y), end: CGPoint(x: b.x, y: b.y),
            function: extend == .pad ? fn : (Self.gradientFunction(stops, extend: extend, domain: domain) ?? fn),
            extendStart: true, extendEnd: true
        ) {
            ctx.drawShading(sh)
        }
    }

    // MARK: Layers

    /// vello's `push_layer`: what is drawn until the matching `popLayer` is clipped to `clip` (under the
    /// current transform), blurred by `blur` (standard deviation, scaled by the transform as vello does),
    /// faded by `opacity` and composited with `blend` onto what is below. Every layer is its own bitmap,
    /// as in vello, so a compose mode inside one (`DestIn`, `DestOut`) only reaches that layer's content;
    /// a clipped layer without blur only covers its clip's bounds.
    public func pushLayer(clip: BezPath? = nil, blend: BlendMode? = nil, opacity: Double? = nil, blur: Double? = nil) {
        if let r = recorder {
            r.push(DisplayList.Layer(clip: clip, transform: transform, fillRule: fillRule, blend: blend, opacity: opacity, blur: blur))
            return
        }
        let mode = blend ?? BlendMode(.normal, .srcOver)
        let sigma = blur.map { b -> Double in
            let (sx, sy) = Self.scales(transform)
            return (b * (sx + sy) / 2).clamped(0, 500)
        } ?? 0
        var box = (x: 0, y: 0, w: width, h: height)
        if let clip, clip.isFinite, sigma == 0, mode.compose == .srcOver {
            let r = Self.cgPath(clip).boundingBoxOfPath.applying(Self.cg(transform))
            if r.isNull || !r.origin.x.isFinite {
                box = (0, 0, 1, 1)
            } else {
                let x0 = max(0, Int(r.minX.rounded(.down)) - 1), y0 = max(0, Int(r.minY.rounded(.down)) - 1)
                let x1 = min(width, Int(r.maxX.rounded(.up)) + 1), y1 = min(height, Int(r.maxY.rounded(.up)) + 1)
                box = x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : (0, 0, 1, 1)
            }
        }
        guard let s = Surface(x: box.x, y: box.y, width: box.w, height: box.h) else {
            stack.append(.none)
            return
        }
        stack.append(.layer(s, clip: clip, clipTransform: transform, fillRule: fillRule, blend: mode, opacity: (opacity ?? 1).clamped(0, 1), blur: sigma))
    }

    public func pushClipLayer(_ clip: BezPath) { pushLayer(clip: clip) }
    public func pushBlendLayer(_ blend: BlendMode) { pushLayer(blend: blend) }

    public func popLayer() {
        if let r = recorder {
            r.pop()
            return
        }
        guard let e = stack.popLast() else { return }
        guard case .layer(let s, let clip, let clipTransform, let rule, let blend, let opacity, let sigma) = e else { return }
        if sigma > 0 { Self.gaussianBlur(s, sigma) }
        guard let img = s.image() else { return }
        let ctx = current.ctx
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let clip, clip.isFinite {
            ctx.saveGState()
            ctx.concatenate(Self.cg(clipTransform))
            ctx.addPath(Self.cgPath(clip))
            ctx.restoreGState()
            ctx.clip(using: rule == .evenOdd ? .evenOdd : .winding)
        }
        ctx.setAlpha(opacity)
        ctx.setBlendMode(blend.cg)
        ctx.interpolationQuality = .none
        if blend.compose == .srcOver || blend.compose == .destOver || blend.compose == .xor || blend.compose == .plus
            || blend.compose == .destOut || blend.compose == .srcAtop {
            // Compose modes that leave the backdrop alone where the layer is empty: only its box.
            draw(img, at: s, in: ctx)
        } else {
            // `SrcIn`, `DestIn`, `Copy`…: where the layer is empty the backdrop changes too, so the layer
            // covers the whole canvas (transparent outside its own bitmap).
            guard let full = Surface(width: width, height: height) else { return }
            draw(img, at: s, in: full.ctx)
            if let fi = full.image() { draw(fi, at: full, in: ctx) }
        }
    }

    /// Draws a surface's image at its place in canvas space (y down) into `ctx`.
    private func draw(_ img: CGImage, at s: Surface, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(s.x), y: CGFloat(s.y + s.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
        ctx.restoreGState()
    }

    /// The finished image (open layers are closed first).
    public func finish() -> RenderImage {
        while !stack.isEmpty { popLayer() }
        return RenderImage(width: width, height: height, pixels: Array(base.bytes))
    }

    // MARK: Helpers

    static func cg(_ m: Affine) -> CGAffineTransform {
        let (a, b, c, d, e, f) = m.coeffs
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    }

    static func cgPath(_ p: BezPath) -> CGPath {
        let path = CGMutablePath()
        var open = false
        for el in p.elements {
            switch el {
            case .moveTo(let q):
                path.move(to: CGPoint(x: q.x, y: q.y))
                open = true
            case .lineTo(let q):
                if !open { path.move(to: CGPoint(x: q.x, y: q.y)); open = true } else { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
            case .quadTo(let a, let b):
                if open { path.addQuadCurve(to: CGPoint(x: b.x, y: b.y), control: CGPoint(x: a.x, y: a.y)) }
            case .curveTo(let a, let b, let c):
                if open { path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y)) }
            case .closePath:
                if open { path.closeSubpath() }
            }
        }
        return path
    }

    static func cgColor(_ c: Rgba, _ alpha: Double) -> CGColor {
        // deckcraft's `color(c, alpha)`: the alpha byte scaled and rounded.
        let a = UInt8(rustCast: (Double(c.a) * alpha.clamped(0, 1)).rounded().clamped(0, 255))
        return CGColor(colorSpace: srgb, components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(a) / 255])
            ?? CGColor(gray: 0, alpha: 1)
    }

    /// The average of the transform's singular values on each axis (vello's `extract_scales`).
    static func scales(_ m: Affine) -> (Double, Double) {
        let (a, b, c, d, _, _) = m.coeffs
        return ((a * a + b * b).squareRoot(), (c * c + d * d).squareRoot())
    }

    /// A gradient as a CoreGraphics function of t: stops interpolated in premultiplied sRGB (peniko's
    /// default), padded beyond the ends, or repeated/reflected over `domain`.
    static func gradientFunction(_ stops: [ColorStop], extend: Extend = .pad, domain: (Double, Double) = (0, 1)) -> CGFunction? {
        let sorted = stops.filter { $0.offset.isFinite }.sorted { $0.offset < $1.offset }
        guard !sorted.isEmpty else { return nil }
        final class Box { let stops: [ColorStop]; let extend: Extend; init(_ s: [ColorStop], _ e: Extend) { stops = s; extend = e } }
        let box = Unmanaged.passRetained(Box(sorted, extend))
        var callbacks = CGFunctionCallbacks(version: 0, evaluate: { info, input, output in
            guard let info else { return }
            let b = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            var t = Double(input[0])
            switch b.extend {
            case .pad: t = t.clamped(0, 1)
            case .repeat: t = t - t.rounded(.down)
            case .reflect:
                let m = (t.truncatingRemainder(dividingBy: 2) + 2).truncatingRemainder(dividingBy: 2)
                t = m > 1 ? 2 - m : m
            }
            let s = b.stops
            func pm(_ g: ColorStop) -> (Double, Double, Double, Double) {
                let a = Double(g.color.a) / 255 * g.alpha.clamped(0, 1)
                return (Double(g.color.r) / 255 * a, Double(g.color.g) / 255 * a, Double(g.color.b) / 255 * a, a)
            }
            var c = pm(s[0])
            if t >= s[s.count - 1].offset {
                c = pm(s[s.count - 1])
            } else if t > s[0].offset {
                for i in 1 ..< s.count where t <= s[i].offset {
                    let a = pm(s[i - 1]), z = pm(s[i])
                    let span = s[i].offset - s[i - 1].offset
                    let u = span > 0 ? (t - s[i - 1].offset) / span : 1
                    c = (a.0 + (z.0 - a.0) * u, a.1 + (z.1 - a.1) * u, a.2 + (z.2 - a.2) * u, a.3 + (z.3 - a.3) * u)
                    break
                }
            }
            let a = c.3
            output[0] = CGFloat(a > 0 ? c.0 / a : 0)
            output[1] = CGFloat(a > 0 ? c.1 / a : 0)
            output[2] = CGFloat(a > 0 ? c.2 / a : 0)
            output[3] = CGFloat(a)
        }, releaseInfo: { info in
            if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
        })
        let d: [CGFloat] = [CGFloat(domain.0), CGFloat(domain.1)]
        let range: [CGFloat] = [0, 1, 0, 1, 0, 1, 0, 1]
        return CGFunction(info: box.toOpaque(), domainDimension: 1, domain: d, rangeDimension: 4, range: range, callbacks: &callbacks)
    }

    /// Gaussian blur of a premultiplied surface in place (edges transparent), separable, in float.
    static func gaussianBlur(_ s: Surface, _ sigma: Double) {
        guard sigma > 0.01 else { return }
        let radius = Int((3 * sigma).rounded(.up))
        let size = 2 * radius + 1
        var kernel = (0 ..< size).map { i -> Float in
            let x = Double(i - radius)
            return Float(exp(-(x * x) / (2 * sigma * sigma)))
        }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        let w = s.width, h = s.height
        let px = s.bytes
        var plane = [Float](repeating: 0, count: w * h)
        var tmp = [Float](repeating: 0, count: w * h)
        for ch in 0 ..< 4 {
            for i in 0 ..< w * h { plane[i] = Float(px[i * 4 + ch]) }
            plane.withUnsafeMutableBufferPointer { p in
                tmp.withUnsafeMutableBufferPointer { t in
                    var src = vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var dst = vImage_Buffer(data: t.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    _ = vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, 1, UInt32(size), 0, vImage_Flags(kvImageBackgroundColorFill))
                    _ = vImageConvolve_PlanarF(&dst, &src, nil, 0, 0, kernel, UInt32(size), 1, 0, vImage_Flags(kvImageBackgroundColorFill))
                }
            }
            for i in 0 ..< w * h { px[i * 4 + ch] = UInt8(rustCast: Double(plane[i]).rounded().clamped(0, 255)) }
        }
    }
}
