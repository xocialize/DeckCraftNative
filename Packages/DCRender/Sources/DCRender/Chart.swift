// DCRender — charts: title, plot area with axes and gridlines, series marks, legend. Port of deckcraft
// crates/render/src/chart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Number formatting (axis and data labels) is DCModel's (`Chart.axisLabel`, `Chart.dataLabel`, NumFmt),
// so labels read as deckcraft's do.
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText
import Darwin

/// Charts (chart.rs).
public enum ChartRender {
    static let slots: [SchemeSlot] = [.accent1, .accent2, .accent3, .accent4, .accent5, .accent6]

    /// Colour of series/point `i`: accents, then darker and lighter rounds.
    public static func seriesColor(_ ctx: Resolve.Ctx, _ c: Chart, _ i: Int) -> Rgba {
        let slot = slots.at(i % 6) ?? .accent1
        let mono = c.palette.utf8.starts(with: "monochrome".utf8)
        let base = ctx.color(.scheme(mono ? .accent1 : slot), nil)
        let round = mono ? i : i / 6
        switch round {
        case 0: return base
        case 1: return applyTransforms(base, [.shade(60000)])
        case 2: return applyTransforms(base, [.tint(60000)])
        default: return applyTransforms(base, [.lumMod(100000 - (Int32(truncatingIfNeeded: round) % 5) * 12000)])
        }
    }

    /// A series' one colour (lines, areas, markers): its solid fill, a pattern's foreground, else the
    /// palette's.
    static func seriesFill(_ ctx: Resolve.Ctx, _ c: Chart, _ i: Int, _ s: Series?) -> Rgba {
        switch s?.fill {
        case .solid(let cc)?: ctx.color(cc, nil)
        case .pattern(let p)?: ctx.color(p.fg, nil)
        default: seriesColor(ctx, c, i)
        }
    }

    /// How a bar, or its legend key, is painted.
    enum BarPaint: Equatable {
        case color(Rgba)
        /// A preset pattern: name, foreground, background.
        case pattern(String, Rgba, Rgba)
        /// `a:noFill`: only the outline, if any, shows.
        case nothing
    }

    /// The paint of fill `f` as a bar or legend key draws it; the palette's `fallback` when the file gives
    /// none (or one a bar can't show).
    static func paintOf(_ ctx: Resolve.Ctx, _ f: Fill?, _ fallback: Rgba) -> BarPaint {
        switch f {
        case .solid(let cc)?: .color(ctx.color(cc, nil))
        case .pattern(let p)?: .pattern(p.preset, ctx.color(p.fg, nil), ctx.color(p.bg, nil))
        case .none_?: .nothing
        default: .color(fallback)
        }
    }

    /// Fill `r` (in the space `m` maps to the output) with `p`.
    static func fillWith(_ c: Canvas, _ p: BarPaint, _ r: Rect, _ m: Affine) {
        switch p {
        case .color(let col):
            c.setTransform(m)
            c.setPaint(.color(col, 1))
            c.fillRect(r)
        case .pattern(let name, let fg, let bg):
            Pattern.fill(c, name, fg, bg, 1, rectPath(r), m)
        case .nothing:
            break
        }
    }

    /// A bar series' outline (`c:spPr/a:ln`) where the file gives it a solid colour: colour and width.
    static func barOutline(_ ctx: Resolve.Ctx, _ s: Series) -> (Rgba, Double)? {
        guard let l = s.line, case .solid(let cc)? = l.fill else { return nil }
        return (ctx.color(cc, nil), (l.width ?? 0.75).clamped(0, 20))
    }

    /// Paint of one bar: a `<c:dPt>` fill wins, and a single-series chart that varies colours by point uses
    /// one accent per point (not waterfalls, which are never read from a `<c:barChart>`). Pattern fills draw
    /// as patterns and `a:noFill` leaves the bar empty, as in PowerPoint.
    static func barPaint(_ ctx: Resolve.Ctx, _ c: Chart, _ si: Int, _ pi: Int, _ s: Series) -> BarPaint {
        if let pf = s.pointFills.first(where: { $0.a == pi }) {
            return paintOf(ctx, pf.b, seriesFill(ctx, c, si, s))
        }
        if c.varyColors && c.series.count == 1 && s.fill == nil && c.kind != .waterfall {
            return .color(seriesColor(ctx, c, pi))
        }
        return paintOf(ctx, s.fill, seriesColor(ctx, c, si))
    }

    static func polyline(_ pts: [Point]) -> BezPath {
        var p = BezPath()
        for (k, q) in pts.enumerated() {
            if k == 0 { p.moveTo(q) } else { p.lineTo(q) }
        }
        return p
    }

    /// A smoothed line (`c:smooth`) through `pts`: a Catmull-Rom spline as cubic Béziers, the curve
    /// PowerPoint draws, passing through every point.
    static func smoothPath(_ pts: [Point]) -> BezPath {
        var p = BezPath()
        guard let first = pts.first else { return p }
        p.moveTo(first)
        for k in 0 ..< pts.count - 1 {
            let p0 = pts[Swift.max(k - 1, 0)]
            let (p1, p2) = (pts[k], pts[k + 1])
            let p3 = pts[Swift.min(k + 2, pts.count - 1)]
            let c1 = p1 + (p2 - p0) / 6
            let c2 = p2 - (p3 - p1) / 6
            p.curveTo(c1, c2, p2)
        }
        return p
    }

    /// A line series' colour: its line's own (where PowerPoint keeps it), else its fill's, else the palette's.
    static func seriesLine(_ ctx: Resolve.Ctx, _ c: Chart, _ i: Int, _ s: Series) -> Rgba {
        if case .solid(let cc)? = s.line?.fill { return ctx.color(cc, nil) }
        return seriesFill(ctx, c, i, s)
    }

    /// A category label on two lines, split at its middle space or dash ("03.11.2025 - 09.11.2025").
    static func splitLabel(_ name: String) -> String {
        let chars = Array(name.unicodeScalars)
        let mid = chars.count / 2
        var best: Int?
        for (i, ch) in chars.enumerated() where ch.properties.isWhitespace {
            // `min_by_key` keeps the first of equal keys.
            if best.map({ Swift.abs(i - mid) < Swift.abs($0 - mid) }) ?? true { best = i }
        }
        guard let i = best, i > 0, i + 1 < chars.count else { return name }
        let a = String(String.UnicodeScalarView(chars[..<i]))
        let b = String(String.UnicodeScalarView(chars[i...]))
        return "\(trimEnd(a))\n\(trimStart(b))"
    }

    static func label(
        _ c: Canvas, _ rctx: Resolve.Ctx, _ m: Affine, _ text: String, _ r: Rect, _ size: Double, _ align: Align, _ anchor: Anchor,
        _ col: Rgba, _ bold: Bool
    ) {
        var body = TextBody.fromText(text)
        body.body.insetL = 0
        body.body.insetR = 0
        body.body.insetT = 0
        body.body.insetB = 0
        body.body.anchor = anchor
        body.body.wrap = false
        for pi in body.paragraphs.indices {
            body.paragraphs[pi].props.align = align
            body.paragraphs[pi].props.bullet = Bullet.none_
            body.paragraphs[pi].props.marginLeft = 0
            body.paragraphs[pi].props.indent = 0
            for ri in body.paragraphs[pi].runs.indices {
                body.paragraphs[pi].runs[ri].props.size = size
                body.paragraphs[pi].runs[ri].props.bold = bold
                body.paragraphs[pi].runs[ri].props.fill = .solid(.rgb(col))
            }
        }
        var tmp = Shape.default
        tmp.text = body
        drawText(c, rctx, tmp, body, r, m, NoFields(), nil)
    }

    static func fmtNum(_ v: Double) -> String {
        Swift.abs(v - v.rounded()) < 1e-9 ? String(Int64(rustCast: v.rounded())) : rustFixed(v, places: 1)
    }

    /// A scatter or bubble chart's value x axis (min, max, major unit): one scale over every series' x
    /// values, from zero when they're all positive. nil for other charts and when there are no x values.
    static func valueXScale(_ c: Chart, _ maxIntervals: Int) -> (Double, Double, Double)? {
        if c.series.isEmpty || !c.series.allSatisfy({ [.scatter, .bubble].contains(c.seriesKind($0)) }) { return nil }
        var range: (Double, Double)?
        for s in c.series {
            for v in s.xValues.compactMap({ $0 }) where v.isFinite {
                range = range.map { ($0.0.rustMin(v), $0.1.rustMax(v)) } ?? (v, v)
            }
        }
        guard let (lo, hi) = range else { return nil }
        return axisScale(lo.rustMin(0), hi, nil, nil, nil, maxIntervals, false)
    }

    /// Where the legend goes for `c:legendPos`, and the plot area left over. `size` is the legend block
    /// (width, height); the result is its top-left corner and the plot area. `r` (also the OOXML default
    /// and the fallback for unknown values) and `l` are vertical stacks centred on the area, `tr` is a
    /// vertical stack in the top-right corner, `t` and `b` are centred rows. An overlaid legend leaves the
    /// plot area as it was.
    static func legendLayout(_ pos: String, _ size: (Double, Double), _ area: Rect, _ base: Double, _ overlay: Bool) -> (Point, Rect) {
        let (lw, lh) = size
        let gap = base * 0.5
        let cx = (area.x0 + area.x1) / 2
        let cy = ((area.y0 + area.y1) / 2 - lh / 2).rustMax(area.y0)
        var plot = area
        let origin: Point
        switch pos {
        case "b":
            plot.y1 = area.y1 - lh - gap
            origin = Point(cx - lw / 2, area.y1 - lh)
        case "t":
            plot.y0 = area.y0 + lh + gap
            origin = Point(cx - lw / 2, area.y0)
        case "l":
            plot.x0 = area.x0 + lw + gap
            origin = Point(area.x0, cy)
        case "tr":
            plot.x1 = area.x1 - lw - gap
            origin = Point(area.x1 - lw, area.y0)
        default:
            plot.x1 = area.x1 - lw - gap
            origin = Point(area.x1 - lw, cy)
        }
        return (origin, overlay ? area : plot)
    }

    /// An axis span to divide by: the span itself when positive, else 1 (no absolute floor, so tiny data
    /// keeps its scale).
    public static func positiveSpan(_ s: Double) -> Double { s > 0 && s.isFinite ? s : 1 }

    /// The tick values of an axis (min, max, major step), one per step (at most 51).
    static func axisTicks(_ sc: (Double, Double, Double)) -> [Double] {
        let (lo, hi, st) = sc
        let n = st > 0 ? Swift.min(Swift.max(Int64(rustCast: ((hi - lo) / st).rounded()), 1), 50) : 1
        return (0 ... n).map { lo + Double($0) * st }
    }

    /// Draws chart `chart` (`w` × `h` in its own space, which `m` maps to the output).
    public static func draw(_ c: Canvas, _ rctx: Resolve.Ctx, _ chart: Chart, _ m: Affine, _ w: Double, _ h: Double) {
        switch chart.kind {
        // Histograms and Pareto charts are drawn as the column (and line) chart of their bins.
        case .histogram, .pareto: drawInner(c, rctx, chart.histogramView(), m, w, h, nil)
        case .boxWhisker:
            let (view, boxes) = ChartEx.boxView(chart)
            drawInner(c, rctx, view, m, w, h, boxes)
        default: drawInner(c, rctx, chart, m, w, h, nil)
        }
    }

    /// PowerPoint's default chart text colour: `tx1` with `lumMod` 65000 and `lumOff` 35000, which is
    /// 595959 on a light theme and a light grey on a dark one.
    public static func defaultTextColor() -> ColorRef {
        ColorRef.scheme(.tx1).with(.lumMod(65000)).with(.lumOff(35000))
    }

    static func drawInner(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ w: Double, _ h: Double, _ boxes: ChartEx.Boxes?) {
        // Text without a colour of its own takes PowerPoint's default, the theme's text colour at lumMod
        // 65 % / lumOff 35 % (595959 on a light theme, light grey on a dark one), so a chart on a dark theme
        // is readable (a fixed grey used to vanish there).
        let textCol = rctx.color(c.textColor ?? defaultTextColor(), nil)
        let gridCol = Rgba.rgb(0xD9, 0xD9, 0xD9)
        if let f = c.chartFill {
            let all = Rect(0, 0, w, h)
            PaintFill.fillPath(ctx, rctx, f, nil, rectPath(all), all, m, .norm, 1, rctx.pres)
        }
        // The file's text sizes when it has them (PowerPoint draws chart text at them); otherwise a size that
        // suits the chart.
        let base = c.textSize ?? (h.rustMin(w) / 22).clamped(7, 18)
        let titleSize = c.titleSize ?? base * 1.4
        var area = Rect(w * 0.04, h * 0.04, w * 0.96, h * 0.96)
        if let t = c.title {
            label(ctx, rctx, m, t, Rect(0, area.y0, w, area.y0 + titleSize * 1.3), titleSize, .center, .top, textCol, false)
            area.y0 += titleSize * 1.7
        }
        let pie = c.kind == .pie || c.kind == .doughnut
        // Legend placed by `c:legendPos`.
        let waterfall = c.kind == .waterfall
        // Each legend entry: its name, its key's paint and the key's outline.
        let legendItems: [(String, BarPaint, (Rgba, Double)?)]
        if waterfall {
            legendItems = ["Increase", "Decrease", "Total"].enumerated().map { ($1, .color(seriesColor(rctx, c, $0)), nil) }
        } else if c.kind == .treemap || c.kind == .sunburst {
            // A hierarchy's legend names its top-level groups.
            legendItems = c.categoryTree().enumerated().map { ($1.name, .color(seriesColor(rctx, c, $0)), nil) }
        } else if c.kind == .funnel || c.kind == .regionMap {
            // A map draws its own colour scale.
            legendItems = []
        } else if pie {
            legendItems = c.categories.enumerated().map { ($1, .color(seriesColor(rctx, c, $0)), nil) }
        } else {
            legendItems = c.series.enumerated().map { i, s in
                let k = c.seriesKind(s)
                let line = !k.isBarLike && ![.area, .stackedArea, .filledRadar].contains(k)
                if line { return (s.name, .color(seriesLine(rctx, c, i, s)), nil) }
                if k.isBarLike {
                    let paint: BarPaint = c.varyColors && c.series.count == 1 && s.fill == nil
                        ? .color(seriesColor(rctx, c, i)) : paintOf(rctx, s.fill, seriesColor(rctx, c, i))
                    return (s.name, paint, barOutline(rctx, s))
                }
                return (s.name, .color(seriesFill(rctx, c, i, s)), nil)
            }
        }
        if let pos = c.legend, !legendItems.isEmpty {
            let vertical = ["l", "r", "tr"].contains(pos)
            let itemWs = legendItems.map { Double($0.0.unicodeScalars.count) * base * 0.55 + base * 1.6 }
            let size: (Double, Double) = vertical
                ? (itemWs.reduce(0.0) { $0.rustMax($1) }.rustMin(w * 0.4), Double(legendItems.count) * base * 1.5)
                : (itemWs.reduce(0, +).rustMin(w * 0.9), base * 1.4)
            let (origin, plotArea) = legendLayout(pos, size, area, base, c.legendOverlay)
            area = plotArea
            var (x, y) = (origin.x, origin.y)
            for (name, paint, outline) in legendItems {
                let key = Rect(x, y + base * 0.3, x + base * 0.7, y + base)
                fillWith(ctx, paint, key, m)
                if let (oc, ow) = outline, ow > 0 {
                    ctx.setTransform(m)
                    ctx.setPaint(.color(oc, 1))
                    ctx.setStroke(StrokeStyle(ow.rustMin(base * 0.2)))
                    ctx.strokePath(rectPath(key))
                }
                let tw = Double(name.unicodeScalars.count) * base * 0.55 + base
                label(ctx, rctx, m, name, Rect(x + base, y, x + base + tw, y + base * 1.3), base, .left, .middle, textCol, false)
                if vertical { y += base * 1.5 } else { x += tw + base * 0.6 }
            }
        }
        if pie {
            guard let s = c.series.first else { return }
            let vals = s.values.map { ($0 ?? 0).rustMax(0) }
            let total = vals.reduce(0, +)
            if total <= 0 { return }
            let r = (area.width.rustMin(area.height) / 2) * 0.95
            let cen = area.center
            var a0 = -Double.pi / 2
            for (i, v) in vals.enumerated() {
                let sweep = v / total * 2 * Double.pi
                var p = BezPath()
                p.moveTo(cen)
                p.lineTo(Point(cen.x + r * cos(a0), cen.y + r * sin(a0)))
                p.extend(Arc(cen, Vec2(r, r), a0, sweep, 0).appendElements(0.1))
                p.closePath()
                ctx.setTransform(m)
                var col = seriesColor(rctx, c, i)
                if let pf = s.pointFills.first(where: { $0.a == i }), case .solid(let cc) = pf.b { col = rctx.color(cc, nil) }
                ctx.setPaint(.color(col, 1))
                ctx.fillPath(p)
                ctx.setPaint(.color(.white, 1))
                ctx.setStroke(StrokeStyle(1))
                ctx.strokePath(p)
                if c.seriesDataLabels(s) {
                    let mid = a0 + sweep / 2
                    let lp = Point(cen.x + r * 0.65 * cos(mid), cen.y + r * 0.65 * sin(mid))
                    // On the slices themselves: white, unless the chart's text was given a colour.
                    label(
                        ctx, rctx, m, c.dataLabel(s, v), Rect(lp.x - 30, lp.y - 10, lp.x + 30, lp.y + 10), base, .center, .middle,
                        c.textColor != nil ? textCol : .white, false
                    )
                }
                a0 += sweep
            }
            if c.kind == .doughnut {
                ctx.setTransform(m)
                ctx.setPaint(.color(.white, 1))
                ctx.fillPath(circlePath(cen, r * c.holeSize.clamped(0.1, 0.9)))
            }
            return
        }
        if [.funnel, .treemap, .sunburst, .regionMap].contains(c.kind) {
            ChartEx.draw(ctx, rctx, c, m, area, base, textCol)
            return
        }
        if c.kind == .radar || c.kind == .filledRadar {
            Radar.draw(ctx, rctx, c, m, area, base, textCol)
            return
        }
        let combo = c.kind == .combo
        // Bars are drawn first and lines over them; a combo chart has both.
        let barKind = c.series.lazy.map { c.seriesKind($0) }.first { $0.isBarLike }
        let horiz = combo ? (barKind?.horizontal ?? false) : c.kind.horizontal
        // Axis titles: the left one turned to read upwards, the bottom one centred under the axis. On a
        // horizontal bar chart the category axis is the left one.
        let (leftTitle, bottomTitle) = horiz ? (c.axisTitles.a, c.axisTitles.b) : (c.axisTitles.b, c.axisTitles.a)
        let bandH = base * 1.6
        if let t = bottomTitle, !t.isEmpty {
            let r = Rect(area.x0, area.y1 - bandH, area.x1, area.y1)
            label(ctx, rctx, m, t, r, base, .center, .bottom, textCol, true)
            area.y1 -= bandH + base * 0.3
        }
        if let t = leftTitle, !t.isEmpty {
            let (cx, cy) = (area.x0 + bandH / 2, (area.y0 + area.y1) / 2)
            let turned = m * Affine.translate(Vec2(cx, cy)) * Affine.rotate(-Double.pi / 2)
            let half = area.height / 2
            label(ctx, rctx, turned, t, Rect(-half, -bandH / 2, half, bandH / 2), base, .center, .middle, textCol, true)
            area.x0 += bandH + base * 0.3
        }
        // As many major units as the value axis has room for labels (PowerPoint's automatic unit).
        let axisLen = horiz ? area.width - base * 4.5 : area.height - base * 1.8
        let maxIntervals = Int(rustCast: (axisLen / (horiz ? base * 6 : base * 1.9)).rounded(.down).clamped(2, 12))
        // A logarithmic axis is scaled in exponents of its base.
        let log: (Double, (Double, Double, Double))? = c.logAxisScale(maxIntervals).map { (c.yLogBase ?? 10, $0) }
        let (min, max, step) = log?.1 ?? c.axisScale(false, maxIntervals) ?? axisScale(0, 1, nil, nil, nil, maxIntervals, true)
        let toE = { (v: Double) -> Double in
            guard let (b, _) = log else { return v }
            return (Darwin.log(v.rustMax(Double.leastNormalMagnitude)) / Darwin.log(b)).rustMax(min - 1)
        }
        // A combo chart's secondary value axis, on the right (vertical value axes only).
        let second = horiz ? nil : c.axisScale(true, maxIntervals)
        // Label gutters as wide as the longest value label.
        let primaryTicks = axisTicks((min, max, step)).map { k in log.map { pow($0.0, k) } ?? k }
        let labelW = { (sec: Bool, sc: (Double, Double, Double)) -> Double in
            let vals = sec ? axisTicks(sc) : primaryTicks
            return Double(vals.map { c.axisLabel(sec, $0).unicodeScalars.count }.max() ?? 1) * base * 0.55 + base * 0.6
        }
        let gutter = horiz ? base * 4.5 : c.yHidden ? base * 0.5 : clampSoft(labelW(false, (min, max, step)), base * 1.5, area.width * 0.3)
        let gutterR = second.flatMap { c.y2Hidden ? nil : $0 }.map { clampSoft(labelW(true, $0), base * 1.5, area.width * 0.3) } ?? 0
        let plot = horiz
            ? Rect(area.x0 + gutter, area.y0, area.x1, area.y1 - base * 1.6)
            : Rect(area.x0 + gutter, area.y0, area.x1 - gutterR, area.y1 - base * 1.8)
        if let f = c.plotFill {
            PaintFill.fillPath(ctx, rctx, f, nil, rectPath(plot), plot, m, .norm, 1, rctx.pres)
        }
        let span = positiveSpan(max - min)
        // Values past the axis limits (fixed ones, or zero on an axis that starts above it) stop at the
        // plot's edge.
        let toV = { (v: Double) -> Double in
            let v = toE(v).rustMax(min).rustMin(max)
            return horiz ? plot.x0 + (v - min) / span * plot.width : plot.y1 - (v - min) / span * plot.height
        }
        // A series' value as a position on its own axis.
        let toAxis = { (sec: Bool, v: Double) -> Double in
            if sec, let (min2, max2, _) = second {
                return plot.y1 - (v.rustMax(min2).rustMin(max2) - min2) / positiveSpan(max2 - min2) * plot.height
            }
            return toV(v)
        }
        // Minor gridlines, under the major ones: five to a major unit.
        if c.minorGridlines {
            let minor = step / 5
            let n = minor > 0 ? Swift.min(Swift.max(Int64(rustCast: ((max - min) / minor).rounded()), 1), 500) : 1
            var g = BezPath()
            for k in 0 ... n where k % 5 != 0 {
                // On a logarithmic axis `min`, `max` and `step` are exponents of the base.
                let e = min + Double(k) * minor
                let pos = toV(log.map { pow($0.0, e) } ?? e)
                if horiz {
                    g.moveTo(Point(pos, plot.y0))
                    g.lineTo(Point(pos, plot.y1))
                } else {
                    g.moveTo(Point(plot.x0, pos))
                    g.lineTo(Point(plot.x1, pos))
                }
            }
            ctx.setTransform(m)
            ctx.setPaint(.color(.rgb(0xF2, 0xF2, 0xF2), 1))
            ctx.setStroke(StrokeStyle(0.75))
            ctx.strokePath(g)
        }
        // Gridlines and value labels.
        for v in primaryTicks {
            let pos = toV(v)
            let text = c.yHidden ? "" : c.axisLabel(false, v)
            var g = BezPath()
            if horiz {
                g.moveTo(Point(pos, plot.y0))
                g.lineTo(Point(pos, plot.y1))
                label(ctx, rctx, m, text, Rect(pos - 30, plot.y1 + 2, pos + 30, plot.y1 + base * 1.5), base, .center, .top, textCol, false)
            } else {
                g.moveTo(Point(plot.x0, pos))
                g.lineTo(Point(plot.x1, pos))
                label(ctx, rctx, m, text, Rect(area.x0, pos - base, plot.x0 - base * 0.4, pos + base), base, .right, .middle, textCol, false)
            }
            if c.gridlines {
                ctx.setTransform(m)
                ctx.setPaint(.color(gridCol, 1))
                ctx.setStroke(StrokeStyle(0.75))
                ctx.strokePath(g)
            }
        }
        // The secondary axis' labels, on the right, without gridlines of their own.
        if let sc = second, !c.y2Hidden {
            for v in axisTicks(sc) {
                let pos = toAxis(true, v)
                label(ctx, rctx, m, c.axisLabel(true, v), Rect(plot.x1 + base * 0.4, pos - base, area.x1, pos + base), base, .left, .middle, textCol, false)
            }
        }
        let ncat = Swift.max(Swift.max(c.categories.count, c.series.map(\.values.count).max() ?? 0), 1)
        // Forecast reserves empty category slots so the line can run past the data. Charts with no forecast
        // keep the old band.
        let (back, fwd) = forecastPad(c)
        let nspan = Double(ncat) + back + fwd
        let band = horiz ? plot.height / nspan : plot.width / nspan
        // Where category `i`'s band starts along its axis: left to right, or bottom to top on a horizontal
        // bar chart, unless the axis is reversed. The forecast's empty slots stay on their own side of the
        // data.
        let backwards = horiz != c.catReversed
        let slot = { (i: Int) -> Double in backwards ? Double(Swift.max(ncat - (i + 1), 0)) + fwd : Double(i) + back }
        // Scatter and bubble charts have a value x axis: one scale over every series' x values, with its own
        // tick labels in place of category names.
        let xscale = horiz ? nil : valueXScale(c, Int(rustCast: (plot.width / (base * 2.5)).rounded(.down).clamped(2, 12)))
        let toX = { (v: Double) -> Double? in xscale.map { plot.x0 + (v - $0.0) / positiveSpan($0.1 - $0.0) * plot.width } }
        if let sc = xscale {
            for v in axisTicks(sc) {
                let pos = plot.x0 + (v - sc.0) / positiveSpan(sc.1 - sc.0) * plot.width
                label(ctx, rctx, m, fmtNum(v), Rect(pos - 30, plot.y1 + 3, pos + 30, plot.y1 + base * 1.6), base, .center, .top, textCol, false)
            }
        }
        // Category labels: wrapped onto two lines when they don't fit their band (long date ranges).
        let wraps = !horiz && c.categories.contains { Double($0.unicodeScalars.count) * base * 0.5 > band }
        if xscale == nil {
            for (i, name) in c.categories.enumerated() {
                let mid = horiz ? plot.y0 + band * (slot(i) + 0.5) : plot.x0 + band * (slot(i) + 0.5)
                if horiz {
                    label(ctx, rctx, m, name, Rect(area.x0, mid - base, plot.x0 - base * 0.4, mid + base), base, .right, .middle, textCol, false)
                } else {
                    let text = wraps ? splitLabel(name) : name
                    let r = Rect(mid - band / 2, plot.y1 + 3, mid + band / 2, plot.y1 + base * (wraps ? 2.8 : 1.6))
                    label(ctx, rctx, m, text, r, base, .center, .top, textCol, false)
                }
            }
        }
        if let b = boxes {
            ChartEx.drawBoxes(ctx, rctx, c, b, m, plot, band, horiz, toV)
            return
        }
        let zero = log.map { toV(pow($0.0, min)) } ?? toV(clampSoft(0, min, max))
        // Error bars, drawn over every series: (position across the value axis, from, to, cap length, cap).
        var errMarks: [(Double, Double, Double, Double, Bool)] = []
        if let bk = barKind {
            let bars = c.series.enumerated().filter { c.seriesKind($0.element).isBarLike }
            let ns = Swift.max(bars.count, 1)
            // Gap width and overlap are fractions of one bar's width: a category's band holds its bars
            // (overlapping by `overlap` of a bar between neighbours) plus one gap.
            let gap = c.gapWidth.clamped(0, 5)
            let stacked = bk.stacked
            let ov = stacked ? 1 : c.overlap.clamped(-1, 1)
            let n = Double(ns)
            let bar = band / (n - (n - 1) * ov + gap)
            let step = bar * (1 - ov)
            let group = bar + step * (n - 1)
            // Error bars need each series' mean and spread: worked out once, not per point.
            let stats = bars.map { SeriesStats.of($0.element.values) }
            let wf = waterfall ? c.waterfallBars() : []
            for i in 0 ..< ncat {
                var posAcc = 0.0
                var negAcc = 0.0
                let total = bk.percent
                    ? bars.reduce(0.0) { $0 + Swift.abs(($1.element.values.at(i) ?? nil) ?? 0) }.rustMax(1e-9)
                    : 1.0
                for (bi, (si, s)) in bars.enumerated() {
                    let sec = c.onSecondary(s)
                    let v = ((s.values.at(i) ?? nil) ?? 0) / total
                    let start = band * slot(i) + (band - group) / 2 + (stacked ? 0 : step * Double(bi))
                    let (a, b): (Double, Double)
                    if waterfall {
                        (a, b) = wf.at(i) ?? (0, 0)
                    } else if stacked {
                        if v >= 0 {
                            (a, b) = (posAcc, posAcc + v)
                            posAcc += v
                        } else {
                            (a, b) = (negAcc + v, negAcc)
                            negAcc += v
                        }
                    } else {
                        (a, b) = (0.0.rustMin(v), 0.0.rustMax(v))
                    }
                    let r = (horiz
                        ? Rect(toV(a), plot.y0 + start, toV(b), plot.y0 + start + bar)
                        : Rect(plot.x0 + start, toAxis(sec, b), plot.x0 + start + bar, toAxis(sec, a))).abs
                    // A waterfall colours increases, decreases and totals, and joins each bar's end to the
                    // next bar's start.
                    let paint: BarPaint = waterfall
                        ? .color(seriesColor(rctx, c, c.subtotals.contains(i) ? 2 : b < a ? 1 : 0))
                        : barPaint(rctx, c, si, i, s)
                    fillWith(ctx, paint, r, m)
                    if !waterfall, let (oc, ow) = barOutline(rctx, s), ow > 0 {
                        ctx.setTransform(m)
                        ctx.setPaint(.color(oc, 1))
                        ctx.setStroke(StrokeStyle(ow))
                        ctx.strokePath(rectPath(r))
                    }
                    if waterfall && i + 1 < ncat && !horiz {
                        let y = toV(b)
                        var j = BezPath()
                        j.moveTo(Point(r.x1, y))
                        j.lineTo(Point(r.x1 + (band - bar), y))
                        ctx.setPaint(.color(.rgb(0xA6, 0xA6, 0xA6), 1))
                        ctx.setStroke(StrokeStyle(0.75))
                        ctx.strokePath(j)
                    }
                    if let e = s.errorBars {
                        let end = v >= 0 ? b : a
                        let mid = horiz ? r.center.y : r.center.x
                        if let st = stats.at(bi), let (lo, hi) = e.rangeIn(st, i, end) {
                            let (p0, p1) = horiz ? (toV(lo), toV(hi)) : (toAxis(sec, lo), toAxis(sec, hi))
                            errMarks.append((mid, p0, p1, bar.rustMin(base * 0.8) * 0.5, e.endCap))
                        }
                    }
                    if c.seriesDataLabels(s) {
                        let t = c.dataLabel(s, (s.values.at(i) ?? nil) ?? 0)
                        let lr = horiz ? Rect(r.x1 + 2, r.y0, r.x1 + 40, r.y1) : Rect(r.x0 - 10, r.y0 - base * 1.4, r.x1 + 10, r.y0)
                        label(ctx, rctx, m, t, lr, base * 0.9, horiz ? .left : .center, horiz ? .middle : .bottom, textCol, false)
                    }
                }
            }
        }
        // A stock chart's high-low lines and up/down bars (or close dashes) stand in for its series.
        if c.kind == .stock {
            for i in 0 ..< ncat {
                Radar.stockMarks(ctx, rctx, c, m, plot.x0 + band * (Double(i) + 0.5), band, i) { toAxis(false, $0) }
            }
        }
        // Lines, areas, scatter: the series that aren't bars.
        var acc = [Double](repeating: 0, count: ncat)
        for (si, s) in c.series.enumerated() {
            let kind = c.seriesKind(s)
            if kind.isBarLike || kind == .stock { continue }
            let sec = c.onSecondary(s)
            let stacked = kind.stacked
            let areaKind = [.area, .stackedArea, .filledRadar].contains(kind)
            let col = areaKind ? seriesFill(rctx, c, si, s) : seriesLine(rctx, c, si, s)
            let seriesStats = s.errorBars.map { _ in SeriesStats.of(s.values) }
            var pts: [Point] = []
            for i in 0 ..< ncat {
                guard let v0 = s.values.at(i) ?? nil else { continue }
                var v = v0
                if stacked {
                    let baseV = acc.at(i) ?? 0
                    if acc.indices.contains(i) { acc[i] += v0 }
                    v = baseV + v0
                }
                let x: Double
                switch kind {
                case .scatter, .bubble:
                    if let xv = s.xValues.at(i) ?? nil, let px = toX(xv) {
                        x = px
                    } else if s.xValues.allSatisfy({ $0 == nil }) {
                        // No x values at all: the points are numbered 1, 2, 3...
                        x = toX(Double(i) + 1) ?? plot.x0 + band * (slot(i) + 0.5)
                    } else {
                        continue
                    }
                default:
                    x = plot.x0 + band * (slot(i) + 0.5)
                }
                if let e = s.errorBars, let st = seriesStats, let (lo, hi) = e.rangeIn(st, i, v) {
                    errMarks.append((x, toAxis(sec, lo), toAxis(sec, hi), base * 0.4, e.endCap))
                }
                pts.append(Point(x, toAxis(sec, v)))
            }
            if pts.isEmpty { continue }
            let p = s.smooth && !areaKind && pts.count > 2 ? smoothPath(pts) : polyline(pts)
            ctx.setTransform(m)
            if areaKind {
                var a = p
                if let l = pts.last, let f = pts.first {
                    a.lineTo(Point(l.x, zero))
                    a.lineTo(Point(f.x, zero))
                    a.closePath()
                }
                ctx.setPaint(.color(col, 0.85))
                ctx.fillPath(a)
            } else if kind != .scatter {
                let lw = (s.line?.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 2.25).clamped(0.25, 20)
                ctx.setPaint(.color(col, 1))
                ctx.setStroke(StrokeStyle(lw).withJoin(.round).withCaps(.round))
                ctx.strokePath(p)
            }
            if [.lineMarkers, .scatter, .bubble].contains(kind) {
                ctx.setPaint(.color(col, 1))
                for q in pts { ctx.fillPath(circlePath(q, 3.5)) }
            }
        }
        // A category position (0-based, fractional) as a slot, the way `slot` places the bars.
        let slotAt = { (x: Double) -> Double in backwards ? Double(ncat) - 1 - x + fwd : x + back }
        drawTrendlines(ctx, rctx, c, m, plot, band, slotAt, xscale, ncat, horiz, base, textCol, toAxis)
        if !errMarks.isEmpty {
            var p = BezPath()
            for (mid, a, b, cap, endCap) in errMarks {
                // A horizontal bar chart's error bars run across, its value axis being horizontal.
                func pt(_ along: Double, _ across: Double) -> Point { horiz ? Point(along, across) : Point(across, along) }
                p.moveTo(pt(a, mid))
                p.lineTo(pt(b, mid))
                if endCap {
                    for e in [a, b] {
                        p.moveTo(pt(e, mid - cap))
                        p.lineTo(pt(e, mid + cap))
                    }
                }
            }
            ctx.setTransform(m)
            ctx.setPaint(.color(textCol, 1))
            ctx.setStroke(StrokeStyle(0.75))
            ctx.strokePath(p)
        }
        // Axis line.
        var ax = BezPath()
        if horiz {
            ax.moveTo(Point(zero, plot.y0))
            ax.lineTo(Point(zero, plot.y1))
        } else {
            ax.moveTo(Point(plot.x0, zero))
            ax.lineTo(Point(plot.x1, zero))
        }
        ctx.setTransform(m)
        ctx.setPaint(.color(.rgb(0xBF, 0xBF, 0xBF), 1))
        ctx.setStroke(StrokeStyle(0.75))
        ctx.strokePath(ax)
    }

    /// `v` kept within `lo...hi` without a trap when `lo > hi` (a chart smaller than its label font) or a
    /// bound is NaN: the upper bound wins.
    static func clampSoft(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        let v = v < lo ? lo : v
        return v > hi ? hi : v
    }

    /// A corner of `plot` whose box stays clear of `pts` (the drawn trendline).
    static func captionAt(_ plot: Rect, _ boxW: Double, _ boxH: Double, _ pts: [Point], _ n: Int) -> (Double, Double) {
        let pad = 4.0
        let shift = Double(n) * (boxH + 2)
        let xRight = (plot.x1 - boxW - pad).rustMax(plot.x0 + pad)
        let yBottom = (plot.y1 - boxH - pad - shift).rustMax(plot.y0 + pad)
        let yTop = (plot.y0 + pad + shift).rustMin(yBottom)
        let corners = [(plot.x0 + pad, yTop), (xRight, yTop), (plot.x0 + pad, yBottom), (xRight, yBottom)]
        var best = corners[0]
        var bestD = -1.0
        for (x, y) in corners {
            var minD = Double.greatestFiniteMagnitude
            for p in pts {
                let dx = p.x < x ? x - p.x : p.x > x + boxW ? p.x - (x + boxW) : 0
                let dy = p.y < y ? y - p.y : p.y > y + boxH ? p.y - (y + boxH) : 0
                minD = minD.rustMin((dx * dx + dy * dy).squareRoot())
            }
            if pts.isEmpty { minD = 1 }
            if minD > bestD {
                bestD = minD
                best = (x, y)
            }
        }
        return best
    }

    static func padUnits(_ v: Double?) -> Double {
        v.flatMap { $0.isFinite && $0 > 0 ? $0.rustMin(3) : nil } ?? 0
    }

    /// Empty category slots reserved for a trendline forecast, capped so the data still fills the plot.
    static func forecastPad(_ c: Chart) -> (Double, Double) {
        if c.kind == .scatter || c.kind == .bubble { return (0, 0) }
        var back = 0.0
        var fwd = 0.0
        for s in c.series {
            let k = c.seriesKind(s)
            if k == .scatter || k == .bubble { continue }
            for t in s.trendlines.prefix(8) where t.kind != .movingAvg {
                back = back.rustMax(padUnits(t.backward))
                fwd = fwd.rustMax(padUnits(t.forward))
            }
        }
        return (back, fwd)
    }

    static let trendInk: [Rgba] = [.rgb(0x22, 0x22, 0x22), .rgb(0xB0, 0x30, 0x30), .rgb(0x1A, 0x5C, 0x7A), .rgb(0xA0, 0x68, 0x00)]

    static func mapXY(
        _ plot: Rect, _ band: Double, _ slot: (Double) -> Double, _ horiz: Bool, _ scatter: Bool, _ sx0: Double, _ sx1: Double,
        _ sec: Bool, _ x: Double, _ y: Double, _ toAxis: (Bool, Double) -> Double
    ) -> Point? {
        if !x.isFinite || !y.isFinite { return nil }
        let value = toAxis(sec, y)
        if !value.isFinite { return nil }
        let along: Double
        if scatter && sx1 > sx0 {
            along = plot.x0 + (x - sx0) / (sx1 - sx0) * plot.width
        } else {
            let origin = horiz ? plot.y0 : plot.x0
            along = origin + band * (slot(x - 1) + 0.5)
        }
        if !along.isFinite { return nil }
        return horiz && !scatter ? Point(value, along) : Point(along, value)
    }

    /// The part of segment `a`–`b` that lies inside `r`.
    static func clipSeg(_ a: Point, _ b: Point, _ r: Rect) -> (Point, Point)? {
        var (t0, t1) = (0.0, 1.0)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let p = [-dx, dx, -dy, dy]
        let q = [a.x - r.x0, r.x1 - a.x, a.y - r.y0, r.y1 - a.y]
        for i in 0 ..< 4 {
            let (pi, qi) = (p[i], q[i])
            if Swift.abs(pi) < 1e-12 {
                if qi < 0 { return nil }
            } else {
                let t = qi / pi
                if pi < 0 {
                    if t > t1 { return nil } else if t > t0 { t0 = t }
                } else if t < t0 {
                    return nil
                } else if t < t1 {
                    t1 = t
                }
            }
        }
        return (Point(a.x + t0 * dx, a.y + t0 * dy), Point(a.x + t1 * dx, a.y + t1 * dy))
    }

    static func drawTrendlines(
        _ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ plot: Rect, _ band: Double, _ slot: (Double) -> Double,
        _ xscale: (Double, Double, Double)?, _ ncat: Int, _ horiz: Bool, _ base: Double, _ textCol: Rgba, _ toAxis: (Bool, Double) -> Double
    ) {
        var labelN = 0
        for s in c.series where !s.trendlines.isEmpty {
            let kind = c.seriesKind(s)
            let scatter = kind == .scatter || kind == .bubble
            let sec = c.onSecondary(s)
            var xs: [Double] = []
            var ys: [Double] = []
            for i in 0 ..< ncat {
                guard let y = s.values.at(i) ?? nil, y.isFinite else { continue }
                let x: Double
                if scatter {
                    guard let xv = s.xValues.at(i) ?? nil, xv.isFinite else { continue }
                    x = xv
                } else {
                    x = Double(i + 1)
                }
                xs.append(x)
                ys.append(y)
            }
            // The same x extent the scatter marks use, so the fit sits on the points: the chart's value x
            // axis where it has one, else the series' own x values.
            var (sx0, sx1) = (0.0, 0.0)
            if scatter, let (lo, hi, _) = xscale {
                (sx0, sx1) = (lo, hi)
            } else if scatter {
                var lo = Double.greatestFiniteMagnitude
                var hi = -Double.greatestFiniteMagnitude
                for v in s.xValues.compactMap({ $0 }) where v.isFinite {
                    lo = lo.rustMin(v)
                    hi = hi.rustMax(v)
                }
                (sx0, sx1) = (lo, hi)
            }
            for (ti, t) in s.trendlines.prefix(8).enumerated() {
                guard let fit = t.fit(xs, ys) else { continue }
                let (x0, x1) = fit.span(t.forward, t.backward)
                let samples = fit.samples(x0, x1)
                var path = BezPath()
                var prev: Point?
                var inkPts: [Point] = []
                var any = false
                for k in samples.indices.dropLast() {
                    let (w0, w1) = (samples[k], samples[k + 1])
                    guard let a = mapXY(plot, band, slot, horiz, scatter, sx0, sx1, sec, w0.x, w0.y, toAxis),
                          let b = mapXY(plot, band, slot, horiz, scatter, sx0, sx1, sec, w1.x, w1.y, toAxis)
                    else {
                        prev = nil
                        continue
                    }
                    guard let (ca, cb) = clipSeg(a, b, plot) else {
                        prev = nil
                        continue
                    }
                    let cont = prev.map { Swift.abs($0.x - ca.x) < 0.6 && Swift.abs($0.y - ca.y) < 0.6 } ?? false
                    if cont {
                        path.lineTo(cb)
                    } else {
                        path.moveTo(ca)
                        path.lineTo(cb)
                    }
                    prev = cb
                    if inkPts.count < 64 {
                        inkPts.append(ca)
                        inkPts.append(cb)
                    }
                    any = true
                }
                if !any { continue }
                ctx.setTransform(m)
                let ink = trendInk.at(ti % trendInk.count) ?? .rgb(0x22, 0x22, 0x22)
                ctx.setPaint(.color(ink, 1))
                ctx.setStroke(StrokeStyle(1.6).withDashes(0, [6, 3.5]).withCaps(.round))
                ctx.strokePath(path)
                let caption = t.caption(fit)
                if caption.isEmpty { continue }
                let lines = caption.unicodeScalars.filter { $0 == "\n" }.count + 1
                let boxH = base * 1.3 * Double(lines) + 2
                let widest = Double(rustLines(caption).map(\.unicodeScalars.count).max() ?? 1)
                let boxW = clampSoft(widest * base * 0.62, 48, plot.width * 0.72)
                let (x, y) = captionAt(plot, boxW, boxH, inkPts, labelN)
                ctx.setTransform(m)
                ctx.setPaint(.color(.white, 1))
                ctx.fillRect(Rect(x, y, x + boxW, y + boxH))
                label(ctx, rctx, m, caption, Rect(x, y, x + boxW, y + boxH), (base * 0.9).clamped(8, 13), .left, .top, textCol, false)
                labelN += 1
            }
        }
    }
}

/// kurbo's `Circle::path_elements` (closed): four arcs for a small circle, more past the tolerance.
func circlePath(_ c: Point, _ radius: Double, _ tolerance: Double = 0.1) -> BezPath {
    let r = radius
    let scaledErr = Swift.abs(r) / tolerance
    let n: Int
    let arm: Double
    if scaledErr < 1 / 1.9608e-4 {
        (n, arm) = (4, 0.551915024494)
    } else {
        n = Int(rustCast: pow(1.1163 * scaledErr, 1.0 / 6).rounded(.up))
        arm = 4.0 / 3 * tan(Double.pi / 2 / Double(n))
    }
    var p = BezPath()
    if n <= 0 { return p }
    let dth = 2 * Double.pi / Double(n)
    p.moveTo(Point(c.x + r, c.y))
    for ix in 1 ... n {
        let th1 = dth * Double(ix)
        let th0 = th1 - dth
        let (s0, c0) = (sin(th0), cos(th0))
        let (s1, c1) = ix == n ? (0.0, 1.0) : (sin(th1), cos(th1))
        p.curveTo(
            Point(c.x + r * (c0 - arm * s0), c.y + r * (s0 + arm * c0)),
            Point(c.x + r * (c1 + arm * s1), c.y + r * (s1 - arm * c1)),
            Point(c.x + r * c1, c.y + r * s1)
        )
    }
    p.closePath()
    return p
}

/// Rust's `str::lines`: split at `\n`, a `\r` before it dropped, no empty last line after a final `\n`.
func rustLines(_ s: String) -> [String] {
    var out = s.split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
        l.hasSuffix("\r") ? String(l.dropLast()) : String(l)
    }
    if s.hasSuffix("\n") { out.removeLast() }
    return out
}

/// Rust's `trim_end` / `trim_start`: Unicode White_Space.
private func trimEnd(_ s: String) -> String {
    var v = Array(s.unicodeScalars)
    while let l = v.last, l.properties.isWhitespace { v.removeLast() }
    return String(String.UnicodeScalarView(v))
}

private func trimStart(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.drop { $0.properties.isWhitespace }))
}
