// DCRender — fills: solid, gradient, picture and pattern paints; the media glyph and placeholder icons.
// Port of deckcraft crates/render/src/paint.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import CoreGraphics
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

public enum PaintFill {
    /// Fill `path` (under `m`) with `fill`, laid out over `bounds`.
    public static func fillPath(
        _ c: Canvas, _ rctx: Resolve.Ctx, _ fill: Fill, _ ph: Rgba?, _ path: BezPath, _ bounds: Rect, _ m: Affine,
        _ mode: FillMode, _ alpha: Double, _ pres: Presentation
    ) {
        c.setTransform(m)
        switch fill {
        case .none_, .group, .background:
            break
        case .solid(let color):
            let col = shade(rctx.color(color, ph), mode)
            c.setPaint(.solid(col, alpha))
            c.fillPath(path)
        case .gradient(let g):
            if g.stops.isEmpty { return }
            // `rotWithShape="0"`: the gradient keeps to the slide's axes when the shape is rotated or
            // flipped, laid out over the box the shape covers on the slide.
            let k = m.coeffs
            let turned = Swift.abs(k.1) > 1e-9 || Swift.abs(k.2) > 1e-9 || k.0 < 0.0 || k.3 < 0.0
            var pathKind = false
            if case .path(let kind, _) = g.shape, rustEqual(kind, "rect") || rustEqual(kind, "shape") { pathKind = true }
            if !g.rotateWithShape && turned && !pathKind && Swift.abs(m.determinant) > 1e-12 {
                let onSlide = m.transformRectBBox(bounds)
                var upright = g
                upright.rotateWithShape = true
                fillPath(c, rctx, .gradient(upright), ph, transformed(path, m), onSlide, .identity, mode, alpha, pres)
                return
            }
            // A linear gradient spans its tile rectangle (the shape's box unless `tileRect` moves its
            // edges); a radial one ends on the circle around it, from a focus placed in the shape's own
            // box (PowerPoint's "from corner" presets centre the tile on the corner).
            let tile = tileBox(bounds, g.tile)
            var stops: [(Double, Rgba)] = g.stops.map { ($0.pos.clamped(0.0, 1.0), shade(rctx.color($0.color, ph), mode)) }
            stops = stableSorted(stops)
            // Rectangle and outline paths: rasterised (see `PathGradient`).
            if case .path(let kind, let focus) = g.shape, rustEqual(kind, "rect") || rustEqual(kind, "shape") {
                PathGradient.fill(c, kind, focus, Ramp.expand(stops), bounds, path, m, alpha)
                return
            }
            // PowerPoint's ramp between stops (linear light, S-shaped), see `Ramp`.
            let cs = colorStops(Ramp.expand(stops), alpha)
            switch g.shape {
            case .linear(let angle, _):
                c.setPaint(linear(angle, tile, cs))
            case .path(_, let focus):
                c.setPaint(circleGradient(focus, bounds, tile, cs))
            }
            c.fillPath(path)
        case .picture(let pf):
            // `rotWithShape="0"`: upright on the slide, stretched over the box the turned shape covers,
            // clipped to it.
            let k = m.coeffs
            let turned = Swift.abs(k.1) > 1e-9 || Swift.abs(k.2) > 1e-9 || k.0 < 0.0 || k.3 < 0.0
            if pf.upright && turned && Swift.abs(m.determinant) > 1e-12 {
                let onSlide = m.transformRectBBox(bounds)
                let onPath = transformed(path, m)
                c.setTransform(.identity)
                c.pushClipLayer(onPath)
                picture(c, pres, resolved(rctx, pf, ph), onSlide, .identity, nil)
                c.popLayer()
                return
            }
            c.pushClipLayer(path)
            picture(c, pres, resolved(rctx, pf, ph), bounds, m, nil)
            c.popLayer()
        case .pattern(let p):
            let fg = rctx.color(p.fg, ph)
            let bg = rctx.color(p.bg, ph)
            Pattern.fill(c, p.preset, fg, bg, alpha, path, m)
        }
    }

    /// Rust's stable `sort_by(total_cmp)` on positions.
    static func stableSorted(_ stops: [(Double, Rgba)]) -> [(Double, Rgba)] {
        stops.enumerated().sorted { a, b in
            let (x, y) = (a.element.0, b.element.0)
            if x.isTotallyOrdered(belowOrEqualTo: y) && y.isTotallyOrdered(belowOrEqualTo: x) { return a.offset < b.offset }
            return x.isTotallyOrdered(belowOrEqualTo: y)
        }.map(\.element)
    }

    /// peniko colour stops: offsets as `f32`, colours faded by `alpha`.
    static func colorStops(_ stops: [(Double, Rgba)], _ alpha: Double) -> [ColorStop] {
        stops.map { ColorStop(Double(Float($0.0)), $0.1, alpha: alpha) }
    }

    /// A linear gradient at `angle` (degrees clockwise from left→right) spanning `box` along that
    /// direction.
    static func linear(_ angle: Double, _ box: Rect, _ stops: [ColorStop]) -> Paint {
        // Rust's `(a.cos(), a.sin())` compiles to one `sincos` call; the same here.
        let sc = __sincos_stret(angle.toRadians)
        let (dx, dy) = (sc.__cosval, sc.__sinval)
        let ce = box.center
        let half = (box.width * Swift.abs(dx) + box.height * Swift.abs(dy)) / 2.0
        return .linear(start: Point(ce.x - dx * half, ce.y - dy * half), end: Point(ce.x + dx * half, ce.y + dy * half), stops: stops, extend: .pad)
    }

    /// `pf` with its duotone colours resolved to plain RGB against the slide's colours and the
    /// placeholder colour `ph` (theme background pictures recolour with `phClr`), so the decoded-image
    /// cache can apply and key them without a colour scheme.
    public static func resolved(_ rctx: Resolve.Ctx, _ pf: PictureFill, _ ph: Rgba?) -> PictureFill {
        guard let pair = pf.adjust.duotone else { return pf }
        var out = pf
        out.adjust.duotone = Pair(ColorRef.rgb(rctx.color(pair.a, ph)), ColorRef.rgb(rctx.color(pair.b, ph)))
        return out
    }

    /// `bounds` with its edges moved in by `tile` (left, top, right, bottom insets as fractions of its
    /// size; negative moves them out), as `a:tileRect` and `a:fillRect` lay out a fill.
    public static func tileBox(_ bounds: Rect, _ tile: [Double]) -> Rect {
        if tile.allSatisfy({ $0 == 0.0 }) || tile.contains(where: { !$0.isFinite }) { return bounds }
        let (w, h) = (bounds.width, bounds.height)
        let (l, t, r, b) = (tile.at(0) ?? 0, tile.at(1) ?? 0, tile.at(2) ?? 0, tile.at(3) ?? 0)
        let x0 = bounds.x0 + l * w
        let x1 = bounds.x1 - r * w
        let y0 = bounds.y0 + t * h
        let y1 = bounds.y1 - b * h
        // An inverted tile (insets past each other) lays out nothing sensible: keep the box.
        if x1 - x0 <= 1e-9 || y1 - y0 <= 1e-9 { return bounds }
        return Rect(x0, y0, x1, y1)
    }

    /// The paint of a gradient of `shape` with `stops` (position, colour) spanning `bounds`, faded by
    /// `alpha`, ramping between stops as PowerPoint does (see `Ramp`).
    public static func gradient(_ shape: GradientShape, _ stops: [(Double, Rgba)], _ bounds: Rect, _ alpha: Double) -> Paint {
        let sorted = stableSorted(stops.map { ($0.0.clamped(0.0, 1.0), $0.1) })
        let cs = colorStops(Ramp.expand(sorted), alpha)
        switch shape {
        case .linear(let angle, _): return linear(angle, bounds, cs)
        case .path(_, let focus): return circleGradient(focus, bounds, bounds, cs)
        }
    }

    /// A `circle` path gradient over `bounds` with focus rectangle `focus` (`fillToRect` insets, as
    /// fractions). As PowerPoint draws it: the first stop is a point at the focus (the middle of the
    /// focus rectangle) and the last is the circle around the whole box (its centre, half its diagonal),
    /// with circles in between moving from one to the other. With a tile rectangle (`tile`, otherwise
    /// `bounds` itself) the end circle is the one around the tile, while the focus stays placed in
    /// `bounds`.
    public static func circleGradient(_ focus: [Double], _ bounds: Rect, _ tile: Rect, _ stops: [ColorStop]) -> Paint {
        let (f0, f1, f2, f3) = (focus.at(0) ?? 0, focus.at(1) ?? 0, focus.at(2) ?? 0, focus.at(3) ?? 0)
        let fx = bounds.x0 + bounds.width * (f0 + (1.0 - f2)) / 2.0
        let fy = bounds.y0 + bounds.height * (f1 + (1.0 - f3)) / 2.0
        let ce = tile.center
        let r = (Darwin.hypot(tile.width, tile.height) / 2.0).rustMax(1e-6)
        // peniko keeps radii as `f32`.
        let rf = Double(Float(r))
        var f = Point(fx, fy)
        if !(f.isFinite && ce.isFinite && r.isFinite) {
            return .radial(c0: ce, r0: 0, c1: ce, r1: rf, stops: stops, extend: .pad)
        }
        // A focus on or outside the end circle has no circle through it: keep it just inside.
        let d = f - ce
        if d.hypot > r * 0.999 { f = ce + d * (r * 0.999 / d.hypot) }
        return .radial(c0: f, r0: 0, c1: ce, r1: rf, stops: stops, extend: .pad)
    }

    /// Draw a picture fill into `bounds` (shape-local) honouring crop and stretch/tile modes; an
    /// animated GIF shows its frame at `gifTime` seconds.
    public static func picture(_ c: Canvas, _ pres: Presentation, _ pf: PictureFill, _ bounds: Rect, _ m: Affine, _ gifTime: Double?) {
        guard let item = pres.media(pf.media) else {
            missing(c, bounds)
            return
        }
        let pxScale = scaleOf(m)
        let dest: Rect
        switch pf.mode {
        case .stretch(let fillRect):
            let (l, t, r, b) = (fillRect.at(0) ?? 0, fillRect.at(1) ?? 0, fillRect.at(2) ?? 0, fillRect.at(3) ?? 0)
            let inner = Rect(bounds.x0 + l * bounds.width, bounds.y0 + t * bounds.height,
                             bounds.x1 - r * bounds.width, bounds.y1 - b * bounds.height)
            dest = cropDest(inner, pf.crop)
        case .tile:
            dest = bounds
        }
        // Decode for the whole image's size on screen, not the box's: a cropped picture shows only part
        // of it, magnified.
        let want = (Swift.abs(dest.width).rustMax(Swift.abs(dest.height)) * pxScale).rustMax(1.0)
        let frame = gifTime.flatMap { Images.gifImage(item.data, pf.adjust, $0) }
        guard let pm = frame ?? Images.decodeFor(item.data, want, pf.adjust) else {
            missing(c, bounds)
            return
        }
        let (iw, ih) = (Double(pm.width), Double(pm.height))
        if iw < 1.0 || ih < 1.0 { return }
        let alpha = (pf.alpha ?? 1.0).clamped(0.0, 1.0)
        if case .tile(let tx, let ty, let sx, let sy, let flip, let align) = pf.mode {
            // The tile's size: the picture's own size (96 dpi) scaled. A scale of zero or less draws
            // nothing, as in PowerPoint.
            if !(sx > 0.0 && sy > 0.0 && sx.isFinite && sy.isFinite) { return }
            let (nw, nh) = Images.naturalSize(item.data) ?? (iw, ih)
            // PowerPoint draws the tile at a whole number of output pixels.
            let k = pxScale.rustMax(1e-9)
            func snap(_ v: Double) -> Double { (v * k).rounded().rustMax(1.0) / k }
            let (tileW, tileH) = (snap(nw * 0.75 * sx), snap(nh * 0.75 * sy))
            if !(tileW > 1e-6 && tileH > 1e-6 && tileW.isFinite && tileH.isFinite) { return }
            let o = tileOrigin(bounds, align, (tileW, tileH), (tx, ty))
            // Every other tile is mirrored across the flip axes: a reflected repeat.
            let fx = rustEqual(flip, "x") || rustEqual(flip, "xy")
            let fy = rustEqual(flip, "y") || rustEqual(flip, "xy")
            c.setTransform(m)
            if alpha < 0.999 { c.pushLayer(opacity: alpha) }
            c.setPaint(.image(pm, xExtend: fx ? .reflect : .repeat, yExtend: fy ? .reflect : .repeat, quality: .high, alpha: 1.0))
            c.setPaintTransform(Affine.translate(o.toVec2) * Affine.scaleNonUniform(tileW / iw, tileH / ih))
            c.fillRect(bounds)
            c.resetPaintTransform()
            if alpha < 0.999 { c.popLayer() }
            return
        }
        drawImage(c, pm, iw, ih, dest, m, alpha)
    }

    /// Where the first tile of a tiled picture fill goes in `bounds`: its corner, edge middle or centre
    /// named by `align` (`tl`, `t`, `tr`, `l`, `ctr`, `r`, `bl`, `b`, `br`) on the same point of the box,
    /// then moved by the offset (points).
    public static func tileOrigin(_ bounds: Rect, _ align: String, _ tile: (Double, Double), _ offset: (Double, Double)) -> Point {
        let (ax, ay): (Double, Double)
        switch align {
        case "t": (ax, ay) = (0.5, 0.0)
        case "tr": (ax, ay) = (1.0, 0.0)
        case "l": (ax, ay) = (0.0, 0.5)
        case "ctr": (ax, ay) = (0.5, 0.5)
        case "r": (ax, ay) = (1.0, 0.5)
        case "bl": (ax, ay) = (0.0, 1.0)
        case "b": (ax, ay) = (0.5, 1.0)
        case "br": (ax, ay) = (1.0, 1.0)
        default: (ax, ay) = (0.0, 0.0)
        }
        let ox = offset.0.isFinite ? offset.0 : 0.0
        let oy = offset.1.isFinite ? offset.1 : 0.0
        return Point(bounds.x0 + ax * (bounds.width - tile.0) + ox, bounds.y0 + ay * (bounds.height - tile.1) + oy)
    }

    /// Draws `image` (`iw` × `ih` pixels) stretched over `dest` under `m`, faded by `alpha`.
    public static func drawImage(_ c: Canvas, _ image: CGImage, _ iw: Double, _ ih: Double, _ dest: Rect, _ m: Affine, _ alpha: Double) {
        let t = m * Affine.translate(dest.origin.toVec2) * Affine.scaleNonUniform(dest.width / iw, dest.height / ih)
        c.setTransform(t)
        if alpha < 0.999 { c.pushLayer(opacity: alpha) }
        c.setPaint(.image(image, xExtend: .pad, yExtend: .pad, quality: .high, alpha: 1.0))
        c.fillRect(Rect(0.0, 0.0, iw, ih))
        if alpha < 0.999 { c.popLayer() }
    }

    /// A grey box with a cross where a picture can't be shown.
    public static func missing(_ c: Canvas, _ b: Rect) {
        c.setPaint(.solid(.rgba(230, 230, 230, 255), 1))
        c.fillRect(b)
        c.setPaint(.solid(.rgba(160, 160, 160, 255), 1))
        c.setStroke(StrokeStyle(1.0))
        var p = BezPath()
        p.moveTo(Point(b.x0, b.y0))
        p.lineTo(Point(b.x1, b.y1))
        p.moveTo(Point(b.x1, b.y0))
        p.lineTo(Point(b.x0, b.y1))
        c.strokePath(p)
    }

    /// The speaker / film glyph on audio and video objects without a poster.
    public static func mediaGlyph(_ c: Canvas, _ video: Bool, _ b: Rect) {
        let s = b.width.rustMin(b.height)
        let ce = b.center
        if video {
            let r = s * 0.18
            c.setPaint(.solid(.rgba(255, 255, 255, 220), 1))
            c.fillPath(Circle(ce, r * 1.4).path(0.1))
            var tri = BezPath()
            tri.moveTo(Point(ce.x - r * 0.45, ce.y - r * 0.7))
            tri.lineTo(Point(ce.x + r * 0.75, ce.y))
            tri.lineTo(Point(ce.x - r * 0.45, ce.y + r * 0.7))
            tri.closePath()
            c.setPaint(.solid(.rgba(30, 30, 30, 255), 1))
            c.fillPath(tri)
            return
        }
        let k = s / 48.0
        var p = BezPath()
        p.moveTo(Point(ce.x - 14.0 * k, ce.y - 6.0 * k))
        p.lineTo(Point(ce.x - 6.0 * k, ce.y - 6.0 * k))
        p.lineTo(Point(ce.x + 4.0 * k, ce.y - 15.0 * k))
        p.lineTo(Point(ce.x + 4.0 * k, ce.y + 15.0 * k))
        p.lineTo(Point(ce.x - 6.0 * k, ce.y + 6.0 * k))
        p.lineTo(Point(ce.x - 14.0 * k, ce.y + 6.0 * k))
        p.closePath()
        c.setPaint(.solid(.rgba(0x2E, 0x6F, 0xD8, 255), 1))
        c.fillPath(p)
        var w = BezPath()
        for r in [9.0, 15.0] {
            w.extend(Arc(Point(ce.x + 4.0 * k, ce.y), Vec2(r * k, r * k), -0.8, 1.6, 0.0).path(0.1).elements)
        }
        c.setStroke(StrokeStyle(2.5 * k).withCaps(.round))
        c.strokePath(w)
    }

    /// A content-type icon drawn in empty picture/chart/table placeholders.
    public static func placeholderIcon(_ c: Canvas, _ kind: PhType, _ b: Rect) {
        let s = (b.width.rustMin(b.height) * 0.18).clamped(10.0, 48.0)
        let ce = Point(b.center.x, b.center.y - s * 0.3)
        let r = Rect(ce.x - s / 2.0, ce.y - s / 2.0, ce.x + s / 2.0, ce.y + s / 2.0)
        c.setPaint(.solid(.rgba(0x8C, 0x8C, 0x8C, 255), 1))
        c.setStroke(StrokeStyle(s * 0.06).withJoin(.round))
        switch kind {
        case .chart:
            for (i, h) in [0.45, 0.8, 0.6].enumerated() {
                let x = r.x0 + s * (0.1 + 0.3 * Double(i))
                c.fillRect(Rect(x, r.y1 - s * h, x + s * 0.2, r.y1))
            }
        case .table:
            c.strokePath(rectPath(r))
            var p = BezPath()
            for k in 1 ..< 3 {
                let x = r.x0 + s * Double(k) / 3.0
                let y = r.y0 + s * Double(k) / 3.0
                p.moveTo(Point(x, r.y0))
                p.lineTo(Point(x, r.y1))
                p.moveTo(Point(r.x0, y))
                p.lineTo(Point(r.x1, y))
            }
            c.strokePath(p)
        default:
            c.strokePath(rectPath(r))
            var mtn = BezPath()
            mtn.moveTo(Point(r.x0, r.y1))
            mtn.lineTo(Point(r.x0 + s * 0.35, r.y0 + s * 0.45))
            mtn.lineTo(Point(r.x0 + s * 0.6, r.y0 + s * 0.7))
            mtn.lineTo(Point(r.x0 + s * 0.75, r.y0 + s * 0.55))
            mtn.lineTo(Point(r.x1, r.y1))
            mtn.closePath()
            c.fillPath(mtn)
            c.fillPath(Circle(Point(r.x0 + s * 0.72, r.y0 + s * 0.25), s * 0.1).path(0.1))
        }
    }
}
