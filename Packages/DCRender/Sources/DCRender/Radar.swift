// DCRender — radar charts: one spoke per category, the value axis running up the first spoke, a polygon of
// gridlines per major unit and each series a closed polygon (filled for a filled radar); and a stock chart's
// marks. Port of deckcraft crates/render/src/radar.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import Darwin

/// Radar and stock charts (radar.rs).
public enum Radar {
    private typealias R = ChartRender

    /// The point at `frac` of the radius along spoke `i` of `n` (the first spoke points up).
    static func spoke(_ cen: Point, _ r: Double, _ i: Int, _ n: Int, _ frac: Double) -> Point {
        let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(Swift.max(n, 1))
        return Point(cen.x + r * frac * cos(a), cen.y + r * frac * sin(a))
    }

    public static func draw(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ textCol: Rgba) {
        let n = Swift.max(c.categories.count, c.series.map(\.values.count).max() ?? 0)
        // Fewer than three spokes make no polygon; PowerPoint draws a line, we draw nothing.
        if n < 3 { return }
        let gridCol = Rgba.rgb(0xD9, 0xD9, 0xD9)
        // Room for the category labels around the outside.
        let r = (area.width.rustMin(area.height) / 2 - base * 1.9).rustMax(base)
        let cen = area.center
        let (min, max, step) = c.axisScale(false, 5) ?? (0, 1, 0.2)
        let span = R.positiveSpan(max - min)
        let ticks = step > 0 ? Swift.min(Swift.max(Int64(rustCast: ((max - min) / step).rounded()), 1), 20) : 1
        ctx.setTransform(m)
        ctx.setStroke(StrokeStyle(0.75))
        ctx.setPaint(.color(gridCol, 1))
        if c.gridlines {
            for k in 1 ... ticks {
                let frac = Double(k) / Double(ticks)
                var p = BezPath()
                for i in 0 ..< n {
                    let q = spoke(cen, r, i, n, frac)
                    if i == 0 { p.moveTo(q) } else { p.lineTo(q) }
                }
                p.closePath()
                ctx.strokePath(p)
            }
        }
        for i in 0 ..< n {
            var p = BezPath()
            p.moveTo(cen)
            p.lineTo(spoke(cen, r, i, n, 1))
            ctx.setTransform(m)
            ctx.setPaint(.color(gridCol, 1))
            ctx.strokePath(p)
            if let name = c.categories.at(i) {
                let q = spoke(cen, r + base * 1.3, i, n, 1)
                let w = Double(name.unicodeScalars.count) * base * 0.55 + base
                let align: Align = Swift.abs(q.x - cen.x) < base ? .center : q.x > cen.x ? .left : .right
                let x0 = switch align {
                case .left: q.x - base * 0.3
                case .right: q.x - w + base * 0.3
                default: q.x - w / 2
                }
                R.label(ctx, rctx, m, name, Rect(x0, q.y - base * 0.7, x0 + w, q.y + base * 0.7), base, align, .middle, textCol, false)
            }
        }
        // Value labels up the first spoke.
        if !c.yHidden {
            for k in 0 ... ticks {
                let v = min + step * Double(k)
                let q = spoke(cen, r, 0, n, Double(k) / Double(ticks))
                let t = c.axisLabel(false, v)
                let w = Double(t.unicodeScalars.count) * base * 0.55 + base * 0.4
                let lr = Rect(q.x - w - base * 0.3, q.y - base * 0.6, q.x - base * 0.3, q.y + base * 0.6)
                R.label(ctx, rctx, m, t, lr, base * 0.9, .right, .middle, textCol, false)
            }
        }
        let filled = c.kind == .filledRadar
        for (si, s) in c.series.enumerated() {
            let pts = (0 ..< n).map { i -> Point in
                let v = (s.values.at(i) ?? nil) ?? min
                return spoke(cen, r, i, n, ((v - min) / span).clamped(0, 1.2))
            }
            var p = BezPath()
            for (i, q) in pts.enumerated() {
                if i == 0 { p.moveTo(q) } else { p.lineTo(q) }
            }
            p.closePath()
            ctx.setTransform(m)
            if filled {
                ctx.setPaint(.color(R.seriesFill(rctx, c, si, s), 0.75))
                ctx.fillPath(p)
            } else {
                let col = R.seriesLine(rctx, c, si, s)
                let lw = (s.line?.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 2.25).clamped(0.25, 20)
                ctx.setPaint(.color(col, 1))
                ctx.setStroke(StrokeStyle(lw).withJoin(.round))
                ctx.strokePath(p)
                if s.marker != nil {
                    for q in pts { ctx.fillPath(circlePath(q, 3.5)) }
                }
            }
            if c.seriesDataLabels(s) {
                for (i, q) in pts.enumerated() {
                    guard let v = s.values.at(i) ?? nil else { continue }
                    let t = c.dataLabel(s, v)
                    R.label(ctx, rctx, m, t, Rect(q.x - 40, q.y - base * 1.4, q.x + 40, q.y - base * 0.2), base * 0.9, .center, .bottom, textCol, false)
                }
            }
        }
    }

    /// A stock chart's marks at one category: the high-low line, then the up/down bar between the first
    /// (open) and last (close) series, else a dash at the close.
    public static func stockMarks(
        _ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ x: Double, _ band: Double, _ i: Int, _ toY: (Double) -> Double
    ) {
        let vals = c.series.compactMap { $0.values.at(i) ?? nil }
        if vals.count < 2 { return }
        let hi = vals.reduce(-Double.greatestFiniteMagnitude) { $0.rustMax($1) }
        let lo = vals.reduce(Double.greatestFiniteMagnitude) { $0.rustMin($1) }
        let ink = Rgba.rgb(0x40, 0x40, 0x40)
        ctx.setTransform(m)
        ctx.setPaint(.color(ink, 1))
        ctx.setStroke(StrokeStyle(1))
        var p = BezPath()
        p.moveTo(Point(x, toY(hi)))
        p.lineTo(Point(x, toY(lo)))
        ctx.strokePath(p)
        let open = c.series.first.flatMap { $0.values.at(i) ?? nil }
        let close = c.series.last.flatMap { $0.values.at(i) ?? nil }
        if c.upDownBars && c.series.count >= 4 {
            guard let o = open, let cl = close else { return }
            let w = band * 0.4
            let (y0, y1) = (toY(o.rustMax(cl)), toY(o.rustMin(cl)))
            let r = Rect(x - w / 2, y0, x + w / 2, y1.rustMax(y0 + 1))
            // PowerPoint's default: white when the price rose, dark when it fell.
            ctx.setPaint(.color(cl >= o ? .white : ink, 1))
            ctx.fillRect(r)
            ctx.setPaint(.color(ink, 1))
            ctx.strokePath(rectPath(r))
            return
        }
        if let cl = close {
            let col = c.series.last.map { R.seriesLine(rctx, c, c.series.count - 1, $0) } ?? ink
            let y = toY(cl)
            var d = BezPath()
            d.moveTo(Point(x - band * 0.12, y))
            d.lineTo(Point(x + band * 0.12, y))
            ctx.setPaint(.color(col, 1))
            ctx.setStroke(StrokeStyle(2.5))
            ctx.strokePath(d)
        }
    }
}
