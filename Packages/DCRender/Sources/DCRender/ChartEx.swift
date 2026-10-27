// DCRender — Office 2016 chart layouts the bar renderer can't draw: funnel, treemap, sunburst, region map
// tiles and the boxes of a box and whisker chart (waterfall bars are drawn by Chart.swift, histograms as the
// column chart of their bins). Port of deckcraft crates/render/src/chartex.rs (MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import Darwin

/// Office 2016 charts (chartex.rs).
public enum ChartEx {
    private typealias R = ChartRender

    /// Draw `c` inside `area` (the space left by the title and legend).
    public static func draw(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ textCol: Rgba) {
        guard let s = c.series.first else { return }
        if c.kind == .regionMap {
            regionTiles(ctx, rctx, c, m, area, base, textCol)
            return
        }
        let vals = s.values.map { ($0 ?? 0).rustMax(0) }
        if vals.allSatisfy({ $0 <= 0 }) { return }
        let valueLabel = { (v: Double) -> String in c.dataLabel(s, v) }
        let labels = c.seriesDataLabels(s) || c.kind == .funnel
        switch c.kind {
        case .funnel: funnel(ctx, rctx, c, m, area, base, textCol, vals, valueLabel)
        case .treemap where !c.categoryLevels.isEmpty: treeTreemap(ctx, rctx, c, m, area, base, labels ? valueLabel : nil)
        case .treemap: treemap(ctx, rctx, c, m, area, base, vals, labels ? valueLabel : nil)
        default:
            if !c.categoryLevels.isEmpty { treeSunburst(ctx, rctx, c, m, area, base) } else { sunburst(ctx, rctx, c, m, area, base, vals) }
        }
    }

    /// Bars centred on one axis, as wide as their value, widest first as given: category labels on the
    /// left, values inside.
    static func funnel(
        _ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ textCol: Rgba, _ vals: [Double],
        _ valueLabel: (Double) -> String
    ) {
        let n = Swift.max(vals.count, 1)
        let gutter = Double(c.categories.map(\.unicodeScalars.count).max() ?? 0) * base * 0.55 + base
        let plot = Rect(area.x0 + gutter.rustMin(area.width * 0.4), area.y0, area.x1, area.y1)
        let max = vals.reduce(0.0) { $0.rustMax($1) }.rustMax(1e-9)
        let band = plot.height / Double(n)
        let cx = plot.center.x
        for (i, v) in vals.enumerated() {
            let w = v / max * plot.width
            let y = plot.y0 + band * Double(i)
            let r = Rect(cx - w / 2, y + band * 0.05, cx + w / 2, y + band * 0.95)
            ctx.setTransform(m)
            ctx.setPaint(.color(R.seriesColor(rctx, c, 0), 1))
            ctx.fillRect(r)
            if let name = c.categories.at(i) {
                R.label(ctx, rctx, m, name, Rect(area.x0, y, plot.x0 - base * 0.4, y + band), base, .right, .middle, textCol, false)
            }
            R.label(ctx, rctx, m, valueLabel(v), Rect(cx - 60, y, cx + 60, y + band), base, .center, .middle, .white, false)
        }
    }

    /// Mix `a` towards `b` by `t` (0…1).
    static func mix(_ a: Rgba, _ b: Rgba, _ t: Double) -> Rgba {
        let t = t.clamped(0, 1)
        func f(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(rustCast: (Double(x) + (Double(y) - Double(x)) * t).rounded().clamped(0, 255)) }
        return .rgb(f(a.r, b.r), f(a.g, b.g), f(a.b, b.b))
    }

    /// A region map without its geography: the boundaries PowerPoint caches come from an online map service
    /// in an undocumented format and DeckCraft ships no map data, so each region is a tile in a grid,
    /// coloured on the map's value scale, with the scale below and a note saying the map itself is not drawn.
    static func regionTiles(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ textCol: Rgba) {
        guard let s = c.series.first else { return }
        let regions: [(String, Double?)] = c.categories.enumerated().map { ($1, s.values.at($0) ?? nil) }.filter { !$0.0.isEmpty }
        let noteH = base * 1.4
        let scaleH = base * 2.6
        let grid = Rect(area.x0, area.y0, area.x1, (area.y1 - noteH - scaleH).rustMax(area.y0))
        let hi = R.seriesColor(rctx, c, 0)
        let lo = mix(hi, .white, 0.85)
        var (min, max) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for case let (_, v?) in regions {
            min = min.rustMin(v)
            max = max.rustMax(v)
        }
        let span = max > min ? max - min : 1
        let n = regions.count
        if n > 0 && grid.area > 0 {
            // Columns so that tiles come out about twice as wide as tall.
            let aspect = grid.width / grid.height.rustMax(1)
            let cols = Swift.min(Swift.max(Int(rustCast: (Double(n) * aspect / 2).squareRoot().rounded(.up)), 1), n)
            let rows = Swift.max((n + cols - 1) / cols, 1)
            let (tw, th) = (grid.width / Double(cols), grid.height / Double(rows))
            for (i, (name, v)) in regions.enumerated() {
                let (col, row) = (Double(i % cols), Double(i / cols))
                let t = Rect(grid.x0 + tw * col, grid.y0 + th * row, grid.x0 + tw * (col + 1), grid.y0 + th * (row + 1)).inset(-1.5)
                let fill = v.map { mix(lo, hi, ($0 - min) / span) } ?? .rgb(0xD9, 0xD9, 0xD9)
                ctx.setTransform(m)
                ctx.setPaint(.color(fill, 1))
                ctx.fillRect(t)
                let dark = v.map { ($0 - min) / span > 0.55 } ?? false
                var text = name
                if c.seriesDataLabels(s), let v { text = "\(text)\n\(c.dataLabel(s, v))" }
                let inner = t.inset(-base * 0.25)
                if inner.width > base && inner.height > base * 0.8 {
                    R.label(ctx, rctx, m, text, inner, base * 0.9, .center, .middle, dark ? .white : textCol, false)
                }
            }
        }
        // The colour scale: a gradient bar from the lowest to the highest value.
        if min <= max {
            let barW = (area.width * 0.5).rustMin(base * 24)
            let y = grid.y1 + base * 0.6
            let bar = Rect(area.center.x - barW / 2, y, area.center.x + barW / 2, y + base * 0.8)
            let steps = 48
            for k in 0 ..< steps {
                let x0 = bar.x0 + bar.width * Double(k) / Double(steps)
                let x1 = bar.x0 + bar.width * Double(k + 1) / Double(steps) + 0.5
                ctx.setTransform(m)
                ctx.setPaint(.color(mix(lo, hi, Double(k) / Double(steps - 1)), 1))
                ctx.fillRect(Rect(x0, bar.y0, x1.rustMin(bar.x1), bar.y1))
            }
            let ly = Rect(bar.x0 - base * 8, bar.y0 - base * 0.2, bar.x0 - base * 0.4, bar.y1 + base * 0.2)
            R.label(ctx, rctx, m, c.dataLabel(s, min), ly, base, .right, .middle, textCol, false)
            let ry = Rect(bar.x1 + base * 0.4, bar.y0 - base * 0.2, bar.x1 + base * 8, bar.y1 + base * 0.2)
            R.label(ctx, rctx, m, c.dataLabel(s, max), ry, base, .left, .middle, textCol, false)
        }
        let note = Rect(area.x0, area.y1 - noteH, area.x1, area.y1)
        R.label(ctx, rctx, m, "Map preview unavailable: regions shown as tiles", note, base * 0.85, .center, .middle, mix(textCol, .white, 0.4), false)
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): rows of tiles laid along the short side, each row kept
    /// while it improves the worst aspect ratio.
    public static func squarify(_ vals: [Double], _ r: Rect) -> [Rect] {
        let total = vals.reduce(0, +)
        var out = [Rect](repeating: .zero, count: vals.count)
        if total <= 0 || r.area <= 0 { return out }
        let scale = r.area / total
        // Rust's stable `sort_by(total_cmp)`, largest first.
        let order = vals.indices.filter { vals[$0] > 0 }.enumerated().sorted { a, b in
            let (x, y) = (vals[a.element], vals[b.element])
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        var free = r
        var i = 0
        while i < order.count {
            let short = free.width.rustMin(free.height)
            if !short.isFinite || short <= 1e-9 { break }
            let s2 = short * short
            let a0 = vals[order[i]] * scale
            var (curSum, curMax, curMin) = (a0, a0, a0)
            var curWorst = ((s2 * curMax) / (curSum * curSum)).rustMax((curSum * curSum) / (s2 * curMin))
            var end = i + 1
            while end < order.count {
                let nextA = vals[order[end]] * scale
                let candSum = curSum + nextA
                let candMax = curMax.rustMax(nextA)
                let candMin = curMin.rustMin(nextA)
                let candWorst = ((s2 * candMax) / (candSum * candSum)).rustMax((candSum * candSum) / (s2 * candMin))
                if candWorst.isFinite && candWorst <= curWorst {
                    (curSum, curMax, curMin, curWorst) = (candSum, candMax, candMin, candWorst)
                    end += 1
                } else {
                    break
                }
            }
            let thick = curSum / short
            if !thick.isFinite || thick <= 0 { break }
            var at = 0.0
            for k in order[i ..< end] {
                let len = vals[k] * scale / thick
                out[k] = free.width >= free.height
                    ? Rect(free.x0, free.y0 + at, free.x0 + thick, free.y0 + at + len)
                    : Rect(free.x0 + at, free.y0, free.x0 + at + len, free.y0 + thick)
                at += len
            }
            free = free.width >= free.height
                ? Rect(free.x0 + thick, free.y0, free.x1, free.y1)
                : Rect(free.x0, free.y0 + thick, free.x1, free.y1)
            i = end
        }
        return out
    }

    static func treemap(
        _ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ vals: [Double],
        _ valueLabel: ((Double) -> String)?
    ) {
        for (i, t) in squarify(vals, area).enumerated() where t.area > 0 {
            ctx.setTransform(m)
            ctx.setPaint(.color(R.seriesColor(rctx, c, i), 1))
            ctx.fillRect(t)
            ctx.setPaint(.color(.white, 1))
            ctx.setStroke(StrokeStyle(1.5))
            ctx.strokePath(rectPath(t))
            var text = c.categories.at(i) ?? ""
            if let f = valueLabel, let v = vals.at(i) { text = "\(text)\n\(f(v))" }
            let inner = t.inset(-base * 0.3)
            if inner.width > base && inner.height > base {
                R.label(ctx, rctx, m, text, inner, base, .left, .top, .white, false)
            }
        }
    }

    /// A closed ring segment from angle `a` sweeping `sweep`, between radii `ri` and `ro`.
    static func ringSegment(_ cen: Point, _ ri: Double, _ ro: Double, _ a: Double, _ sweep: Double) -> BezPath {
        var p = BezPath()
        p.moveTo(Point(cen.x + ri * cos(a), cen.y + ri * sin(a)))
        p.lineTo(Point(cen.x + ro * cos(a), cen.y + ro * sin(a)))
        p.extend(Arc(cen, Vec2(ro, ro), a, sweep, 0).appendElements(0.1))
        let a1 = a + sweep
        p.lineTo(Point(cen.x + ri * cos(a1), cen.y + ri * sin(a1)))
        p.extend(Arc(cen, Vec2(ri, ri), a1, -sweep, 0).appendElements(0.1))
        p.closePath()
        return p
    }

    /// One ring of the innermost level, with the centre left open.
    static func sunburst(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ vals: [Double]) {
        let total = vals.reduce(0, +)
        let r = area.width.rustMin(area.height) / 2 * 0.95
        let hole = r * 0.35
        let cen = area.center
        var a0 = -Double.pi / 2
        for (i, v) in vals.enumerated() {
            let sweep = v / total * 2 * Double.pi
            if sweep <= 0 { continue }
            let p = ringSegment(cen, hole, r, a0, sweep)
            ctx.setTransform(m)
            ctx.setPaint(.color(R.seriesColor(rctx, c, i), 1))
            ctx.fillPath(p)
            ctx.setPaint(.color(.white, 1))
            ctx.setStroke(StrokeStyle(1.5))
            ctx.strokePath(p)
            if let name = c.categories.at(i), sweep > 0.25 {
                let mid = a0 + sweep / 2
                let rr = (r + hole) / 2
                let lp = Point(cen.x + rr * cos(mid), cen.y + rr * sin(mid))
                R.label(ctx, rctx, m, name, Rect(lp.x - 50, lp.y - base, lp.x + 50, lp.y + base), base, .center, .middle, .white, false)
            }
            a0 += sweep
        }
    }

    /// `col` mixed toward white by `k` (0…0.8): deeper hierarchy levels are lighter.
    static func lighten(_ col: Rgba, _ k: Double) -> Rgba {
        let k = k.clamped(0, 0.8)
        func f(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Double(v) + (255 - Double(v)) * k).rounded()) }
        return .rgb(f(col.r), f(col.g), f(col.b))
    }

    /// A multi-level treemap: top-level groups squarified by their totals, each with its label in a banner
    /// along the top, and their children squarified inside, down to the leaves. A group and everything in it
    /// take the group's colour.
    static func treeTreemap(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double, _ valueLabel: ((Double) -> String)?) {
        func place(_ nodes: [TreeNode], _ r: Rect, _ col: (Int) -> Rgba, _ depth: Int) {
            let vals = nodes.map(\.value)
            for (i, (n, t)) in zip(nodes, squarify(vals, r)).enumerated() where t.area > 0 {
                let fill = col(i)
                if n.children.isEmpty {
                    ctx.setTransform(m)
                    ctx.setPaint(.color(fill, 1))
                    ctx.fillRect(t)
                    ctx.setPaint(.color(.white, 1))
                    ctx.setStroke(StrokeStyle(1))
                    ctx.strokePath(rectPath(t))
                    var text = n.name
                    if let f = valueLabel { text = "\(text)\n\(f(n.value))" }
                    let inner = t.inset(-base * 0.3)
                    if inner.width > base && inner.height > base {
                        R.label(ctx, rctx, m, text, inner, base * 0.9, .left, .top, .white, false)
                    }
                    continue
                }
                // A group: its banner, then its children below it.
                let banner = (base * 1.5).rustMin(t.height * 0.3)
                ctx.setTransform(m)
                ctx.setPaint(.color(fill, 1))
                ctx.fillRect(t)
                if t.width > base * 2 && banner > base * 0.8 {
                    let head = Rect(t.x0 + base * 0.3, t.y0, t.x1 - base * 0.3, t.y0 + banner)
                    R.label(ctx, rctx, m, n.name, head, base, .left, .middle, .white, true)
                }
                let inner = Rect(t.x0 + 1, t.y0 + banner, t.x1 - 1, t.y1 - 1)
                let k = lighten(fill, 0.12 * Double(depth + 1))
                place(n.children, inner, { _ in k }, depth + 1)
                ctx.setTransform(m)
                ctx.setPaint(.color(.white, 1))
                ctx.setStroke(StrokeStyle(2))
                ctx.strokePath(rectPath(t))
            }
        }
        place(c.categoryTree(), area, { R.seriesColor(rctx, c, $0) }, 0)
    }

    /// A multi-level sunburst: the top level as the inner ring, each deeper level in the next ring out
    /// within its parent's angle, coloured by top-level group and lighter further out.
    static func treeSunburst(_ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ m: Affine, _ area: Rect, _ base: Double) {
        let tree = c.categoryTree()
        func depth(_ n: [TreeNode]) -> Int { n.map { 1 + depth($0.children) }.max() ?? 0 }
        let levels = Swift.max(depth(tree), 1)
        let total = tree.reduce(0.0) { $0 + $1.value }
        if total <= 0 { return }
        let r = area.width.rustMin(area.height) / 2 * 0.95
        let hole = r * 0.2
        let ring = (r - hole) / Double(levels)
        let cen = area.center
        func ringOf(_ nodes: [TreeNode], _ a0: Double, _ span: Double, _ d: Int, _ col: (Int) -> Rgba) {
            let sum = nodes.reduce(0.0) { $0 + $1.value }
            if sum <= 0 { return }
            let (ri, ro) = (hole + ring * Double(d), hole + ring * Double(d + 1))
            var a = a0
            for (i, n) in nodes.enumerated() {
                let sweep = n.value / sum * span
                if sweep <= 0 { continue }
                let fill = col(i)
                let p = ringSegment(cen, ri, ro, a, sweep)
                ctx.setTransform(m)
                ctx.setPaint(.color(fill, 1))
                ctx.fillPath(p)
                ctx.setPaint(.color(.white, 1))
                ctx.setStroke(StrokeStyle(1.5))
                ctx.strokePath(p)
                // Labels where the segment has room for them.
                let mid = a + sweep / 2
                let rr = (ri + ro) / 2
                if sweep * rr > base * 2.5 && !n.name.isEmpty {
                    let lp = Point(cen.x + rr * cos(mid), cen.y + rr * sin(mid))
                    let half = (ring * 0.48).rustMax(base)
                    R.label(ctx, rctx, m, n.name, Rect(lp.x - half, lp.y - base, lp.x + half, lp.y + base), base * 0.9, .center, .middle, .white, false)
                }
                if !n.children.isEmpty {
                    let k = lighten(fill, 0.15)
                    ringOf(n.children, a, sweep, d + 1) { _ in k }
                }
                a += sweep
            }
        }
        ringOf(tree, -Double.pi / 2, 2 * Double.pi, 0) { R.seriesColor(rctx, c, $0) }
    }

    /// A box chart's summaries: per series, per group.
    public struct Boxes: Sendable, Equatable {
        public var stats: [[BoxStats?]]
    }

    /// A box and whisker chart as the frame the bar renderer draws (value axis, gridlines, one category per
    /// group, legend by series), and the boxes to draw in it. The frame's values are each group's extremes,
    /// so the value axis covers every whisker and outlier.
    public static func boxView(_ c: Chart) -> (Chart, Boxes) {
        let (groups, stats) = c.boxGroups()
        var v = c
        v.kind = .column
        v.categories = groups
        v.raw = nil
        func ext(_ b: BoxStats, _ hi: Bool) -> Double {
            hi ? b.outliers.reduce(b.high) { $0.rustMax($1) } : b.outliers.reduce(b.low) { $0.rustMin($1) }
        }
        let lowest = stats.joined().compactMap { $0 }.map { ext($0, false) }.reduce(Double.infinity) { $0.rustMin($1) }
        for (si, st) in zip(v.series.indices, stats) {
            v.series[si].values = st.map { $0.map { ext($0, true) } }
        }
        if lowest.isFinite && lowest < 0 && v.yMin == nil {
            // The frame's values are the highs; below zero the axis must reach the lowest point too.
            let mag = pow(10, Darwin.log10(Swift.abs(lowest)).rounded(.down))
            v.yMin = (lowest / mag).rounded(.down) * mag
        }
        return (v, Boxes(stats: stats))
    }

    /// Boxes from the first to the third quartile with the median line and a mean marker, whiskers to the
    /// furthest points within 1.5 IQR, and outliers as dots; series side by side in each group's band.
    static func drawBoxes(
        _ ctx: Canvas, _ rctx: Resolve.Ctx, _ c: Chart, _ b: Boxes, _ m: Affine, _ plot: Rect, _ band: Double, _ horiz: Bool,
        _ toV: (Double) -> Double
    ) {
        let ns = Swift.max(b.stats.count, 1)
        let group = band / (1 + c.gapWidth.clamped(0, 5))
        let w = group / Double(ns)
        let line = Rgba.rgb(0x40, 0x40, 0x40)
        for (si, per) in b.stats.enumerated() {
            let fill = R.seriesColor(rctx, c, si)
            for (gi, st) in per.enumerated() {
                guard let st else { continue }
                let c0 = (horiz ? plot.y0 : plot.x0) + band * Double(gi) + (band - group) / 2 + w * Double(si)
                let (a, z) = (c0 + w * 0.1, c0 + w * 0.9)
                let mid = (a + z) / 2
                // Along the category axis `a…z`, along the value axis `toV`.
                func rect(_ p: Double, _ q: Double, _ u: Double, _ v: Double) -> Rect {
                    horiz ? Rect(u.rustMin(v), p, u.rustMax(v), q) : Rect(p, u.rustMin(v), q, u.rustMax(v))
                }
                func pt(_ along: Double, _ val: Double) -> Point { horiz ? Point(val, along) : Point(along, val) }
                ctx.setTransform(m)
                ctx.setPaint(.color(fill, 1))
                let bx = rect(a, z, toV(st.q1), toV(st.q3))
                ctx.fillRect(bx)
                var p = BezPath()
                // Whiskers with caps, and the median.
                for (from, to) in [(st.q3, st.high), (st.q1, st.low)] {
                    p.moveTo(pt(mid, toV(from)))
                    p.lineTo(pt(mid, toV(to)))
                    p.moveTo(pt(mid - w * 0.2, toV(to)))
                    p.lineTo(pt(mid + w * 0.2, toV(to)))
                }
                p.moveTo(pt(a, toV(st.median)))
                p.lineTo(pt(z, toV(st.median)))
                ctx.setPaint(.color(line, 1))
                ctx.setStroke(StrokeStyle(1.25))
                ctx.strokePath(p)
                ctx.strokePath(rectPath(bx))
                // The mean as an x.
                let (mx, r) = (pt(mid, toV(st.mean)), (w * 0.08).clamped(1.5, 5))
                var x = BezPath()
                x.moveTo(Point(mx.x - r, mx.y - r))
                x.lineTo(Point(mx.x + r, mx.y + r))
                x.moveTo(Point(mx.x - r, mx.y + r))
                x.lineTo(Point(mx.x + r, mx.y - r))
                ctx.strokePath(x)
                for o in st.outliers {
                    let q = pt(mid, toV(o))
                    ctx.setPaint(.color(fill, 1))
                    ctx.fillPath(circlePath(q, r))
                    ctx.setPaint(.color(line, 1))
                    ctx.strokePath(circlePath(q, r))
                }
            }
        }
    }
}
