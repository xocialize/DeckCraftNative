// DCRender — a recorded drawing: what a recording `Canvas` was asked to draw, replayed as vector paths
// into a CoreGraphics context (PDF, print) or onto a raster canvas at any scale. deckcraft has no such
// thing (its PDF is a raster with invisible text over it, its issue #14); this is what lets the Swift
// PDF keep shapes and text as vectors.
//
// PDF can't say everything vello can: a layer that blurs, or one composed with a Porter-Duff mode other
// than source-over, has no PDF equivalent. Such a layer is drawn as a raster image instead, at the
// resolution asked for: on its own when it only needs its own content (blur, or a compose mode inside
// it), or with everything below it when it composes onto the backdrop.
import CoreGraphics
import DCCore
import DCGeometry

public struct DisplayList: Sendable {
    public var width: Int
    public var height: Int
    var ops: [Op]

    struct Fill: @unchecked Sendable {
        /// User space, under `transform`.
        var area: CGPath
        var transform: Affine
        var paint: Paint
        var paintTransform: Affine
        var evenOdd: Bool
    }

    /// `pushLayer`'s arguments and the transform and fill rule current when it was pushed.
    struct Layer: Sendable {
        var clip: BezPath?
        var transform: Affine
        var fillRule: FillRule
        var blend: BlendMode?
        var opacity: Double?
        var blur: Double?

        var compose: Compose { blend?.compose ?? .srcOver }
        var mix: Mix { blend?.mix ?? .normal }
    }

    indirect enum Op: Sendable {
        case fill(Fill)
        case layer(Layer, [Op])
    }

    final class Recorder {
        var ops: [Op] = []
        var stack: [(Layer, [Op])] = []

        func add(_ op: Op) {
            if stack.isEmpty { ops.append(op) } else { stack[stack.count - 1].1.append(op) }
        }

        func push(_ l: Layer) { stack.append((l, [])) }

        func pop() {
            guard let (l, kids) = stack.popLast() else { return }
            add(.layer(l, kids))
        }
    }

    public var isEmpty: Bool { ops.isEmpty }

    /// Whether anything is drawn as a raster image when the list goes to a vector context.
    public var hasRaster: Bool { ops.contains { Self.kind($0) != .vector } }

    /// How an op can go to PDF: as vector paths, as a raster of its own content, or only as a raster
    /// together with the backdrop it composes onto.
    enum Kind { case vector, isolated, backdrop }

    static func kind(_ op: Op) -> Kind {
        guard case .layer(let l, let kids) = op else { return .vector }
        if l.compose != .srcOver { return .backdrop }
        let k = kids.map(kind)
        if (l.blur ?? 0) > 0 || k.contains(.backdrop) { return .isolated }
        return k.contains(.isolated) ? .isolated : .vector
    }

    // MARK: Raster

    /// Replays the list onto `canvas` with `view` before every transform (canvas units → its pixels).
    public func replay(into canvas: Canvas, view: Affine = .identity) {
        Self.replay(ops, into: canvas, view: view)
    }

    static func replay(_ ops: [Op], into c: Canvas, view: Affine) {
        for op in ops {
            switch op {
            case .fill(let f):
                c.setTransform(view * f.transform)
                c.setPaint(f.paint)
                c.setPaintTransform(f.paintTransform)
                c.fillArea(f.area, evenOdd: f.evenOdd)
            case .layer(let l, let kids):
                c.setTransform(view * l.transform)
                c.setFillRule(l.fillRule)
                c.pushLayer(clip: l.clip, blend: l.blend, opacity: l.opacity, blur: l.blur)
                replay(kids, into: c, view: view)
                c.popLayer()
            }
        }
    }

    /// The list rasterised over `region` (canvas units, after `view`) at `scale` pixels per unit.
    static func raster(_ ops: [Op], view: Affine, region: CGRect, scale: Double) -> CGImage? {
        let w = Int((region.width * scale).rounded(.up)), h = Int((region.height * scale).rounded(.up))
        guard w > 0, h > 0, w <= maxRenderSide, h <= maxRenderSide, let c = Canvas(width: w, height: h) else { return nil }
        replay(ops, into: c, view: Affine.scale(scale) * Affine.translate(Vec2(-region.minX, -region.minY)) * view)
        return c.finish().cgImage()
    }

    // MARK: Vector

    /// Draws the list into `ctx` (y down in its user space) with `view` before every transform. What PDF
    /// can't express is drawn as an image of `rasterScale` pixels per unit of `ctx`, inside `bounds` (the
    /// drawing's box in `ctx`: the slide box on the page).
    public func draw(in ctx: CGContext, view: Affine, bounds: CGRect, rasterScale: Double) {
        if ops.contains(where: { Self.kind($0) == .backdrop }) {
            // Something composes onto the page itself: one raster of everything.
            Self.drawRaster(ops, in: ctx, view: view, region: bounds, scale: rasterScale)
            return
        }
        Self.draw(ops, in: ctx, view: view, bounds: bounds, scale: rasterScale)
    }

    static func draw(_ ops: [Op], in ctx: CGContext, view: Affine, bounds: CGRect, scale: Double) {
        for op in ops {
            switch op {
            case .fill(let f):
                ctx.saveGState()
                ctx.concatenate(Canvas.cg(view * f.transform))
                Canvas.paintArea(ctx, f.area, evenOdd: f.evenOdd, f.paint, f.paintTransform)
                ctx.restoreGState()
            case .layer(let l, let kids):
                ctx.saveGState()
                if let clip = l.clip, clip.isFinite { clipTo(ctx, clip, view * l.transform, l.fillRule) }
                ctx.setAlpha((l.opacity ?? 1).clamped(0, 1))
                ctx.setBlendMode(BlendMode(l.mix, .srcOver).cg)
                if kind(op) == .vector {
                    // A transparency group: the layer's content composited as one, as vello does.
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    draw(kids, in: ctx, view: view, bounds: bounds, scale: scale)
                    ctx.endTransparencyLayer()
                } else {
                    // Its own raster, with its clip, blur and inner compose modes applied; the opacity
                    // and mix apply as it is drawn onto the page.
                    var region = bounds
                    if let clip = l.clip, clip.isFinite {
                        let r = Canvas.cgPath(clip).boundingBoxOfPath.applying(Canvas.cg(view * l.transform))
                        region = r.isNull ? .null : region.intersection(r)
                    }
                    if !region.isNull, !region.isEmpty {
                        var inner = l
                        inner.blend = nil
                        inner.opacity = nil
                        drawRaster([.layer(inner, kids)], in: ctx, view: view, region: region, scale: scale)
                    }
                }
                ctx.restoreGState()
            }
        }
    }

    static func clipTo(_ ctx: CGContext, _ clip: BezPath, _ m: Affine, _ rule: FillRule) {
        ctx.saveGState()
        ctx.concatenate(Canvas.cg(m))
        ctx.addPath(Canvas.cgPath(clip))
        ctx.restoreGState()
        ctx.clip(using: rule == .evenOdd ? .evenOdd : .winding)
    }

    /// Rasterises `ops` over `region` (pixel-aligned outward) and draws the image there.
    static func drawRaster(_ ops: [Op], in ctx: CGContext, view: Affine, region: CGRect, scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        // Snap the region to whole pixels so the image lands on the grid it was drawn on.
        let x0 = (region.minX * scale).rounded(.down) / scale, y0 = (region.minY * scale).rounded(.down) / scale
        let x1 = (region.maxX * scale).rounded(.up) / scale, y1 = (region.maxY * scale).rounded(.up) / scale
        let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard let img = raster(ops, view: view, region: r, scale: scale) else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: Double(img.width) / scale, height: Double(img.height) / scale))
        ctx.restoreGState()
    }
}
