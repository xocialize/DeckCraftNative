// Ported from deckcraft crates/render/src/chart.rs (its in-file tests) and the chart tests of tests.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The pixel tests render a slide
// holding the chart, as the Rust ones do; tolerances are the Rust ones unless noted.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import DCText
import Darwin
import Testing

// MARK: Helpers shared by the chart, table and 3-D tests

/// The default deck with `shapes` on its first slide.
func deckOf(_ shapes: [Shape]) -> Presentation {
    var p = Presentation.default
    p.slides[0].shapes = shapes
    return p
}

/// A shape `id` in frame `x` of kind `kind`.
func shapeOf(_ id: UInt32, _ x: Xfrm, _ kind: ShapeKind = .shape) -> Shape {
    var s = Shape.default
    s.id = ShapeId(id)
    s.xfrm = x
    s.kind = kind
    return s
}

/// Slide 0 of `p` at `scale` pixels per point.
func renderDeck(_ p: Presentation, _ scale: Double = 1) -> RenderImage { renderSlide(p, 0, RenderOpts(scale: scale)) }

/// deckcraft's `Image::pixel`: straight RGBA, transparent black outside the image.
func pixelAt(_ img: RenderImage, _ x: Int, _ y: Int) -> [UInt8] { img.straight(x, y) ?? [0, 0, 0, 0] }

/// Whether `p` is within `tol` of `c` on every colour channel (tests_wild.rs `close`).
func nearRGB(_ p: [UInt8], _ c: Rgba, _ tol: Int) -> Bool {
    abs(Int(p[0]) - Int(c.r)) <= tol && abs(Int(p[1]) - Int(c.g)) <= tol && abs(Int(p[2]) - Int(c.b)) <= tol
}

/// Byte values of `a` and `b` more than 64 apart (tests.rs `differing`).
func differingValues(_ a: RenderImage, _ b: RenderImage) -> Int {
    zip(a.pixels, b.pixels).filter { abs(Int($0) - Int($1)) > 64 }.count
}

/// The straight pixels of `img`, four bytes each.
func straightPixels(_ img: RenderImage) -> [[UInt8]] {
    let s = img.toStraight()
    return Swift.stride(from: 0, to: s.count - 3, by: 4).map { Array(s[$0 ..< $0 + 4]) }
}

/// A slide-sized chart, rendered.
func renderChart(_ c: Chart, _ id: UInt32 = 620, _ frame: Xfrm = Xfrm(0, 0, 960, 540)) -> RenderImage {
    renderDeck(deckOf([shapeOf(id, frame, .chart(c))]))
}

let solidRed = Rgba.rgb(255, 0, 0)

@Suite struct ChartTests {
    // MARK: chart.rs

    static let area = Rect(0, 0, 400, 300)

    @Test func tinyDataGetsSeveralTicks() {
        let sc = axisScale(1e-13, 5e-13, nil, nil, nil, 8, true)
        #expect(ChartRender.axisTicks(sc).count >= 3, "\(sc)")
    }

    @Test func scatterXIsAValueScaleOverAllSeries() {
        var c = Chart.sample(.scatter)
        c.series[0].xValues = [0.5, 7.2, nil]
        #expect(ChartRender.valueXScale(c, 8).map { [$0.0, $0.1, $0.2] } == [0, 8, 1])
        #expect(ChartRender.valueXScale(Chart.sample(.column), 8) == nil)
    }

    @Test func rightLegendIsACentredColumnAndNarrowsThePlot() {
        let (o, plot) = ChartRender.legendLayout("r", (60, 100), Self.area, 10, false)
        #expect(o.x == 340 && o.y == 100)
        #expect(plot.x0 == 0 && plot.x1 == 335 && plot.y0 == 0 && plot.y1 == 300)
    }

    @Test func leftTopAndCornerPositions() {
        var (o, plot) = ChartRender.legendLayout("l", (60, 100), Self.area, 10, false)
        #expect([o.x, o.y, plot.x0, plot.x1] == [0, 100, 65, 400])
        (o, plot) = ChartRender.legendLayout("t", (100, 14), Self.area, 10, false)
        #expect([o.x, o.y, plot.y0, plot.y1] == [150, 0, 19, 300])
        (o, plot) = ChartRender.legendLayout("tr", (60, 100), Self.area, 10, false)
        #expect([o.x, o.y, plot.x1] == [340, 0, 335])
    }

    @Test func bottomLegendKeepsTheOldRowLayout() {
        let (o, plot) = ChartRender.legendLayout("b", (100, 14), Self.area, 10, false)
        #expect([o.x, o.y, plot.y1, plot.x1] == [150, 286, 281, 400])
    }

    @Test func overlayDoesNotShrinkThePlot() {
        let (o, plot) = ChartRender.legendLayout("r", (60, 100), Self.area, 10, true)
        #expect(plot == Self.area)
        #expect(o.x == 340)
    }

    @Test func clipKeepsThePartInsideThePlot() throws {
        let r = Rect(0, 0, 100, 50)
        var (a, b) = try #require(ChartRender.clipSeg(Point(-50, 25), Point(150, 25), r))
        #expect(abs(a.x - 0) < 1e-6 && abs(b.x - 100) < 1e-6)
        #expect(abs(a.y - 25) < 1e-6)
        #expect(ChartRender.clipSeg(Point(-10, -10), Point(-1, -1), r) == nil)
        (a, b) = try #require(ChartRender.clipSeg(Point(10, 10), Point(40, 20), r))
        #expect(abs(a.x - 10) < 1e-6 && abs(b.x - 40) < 1e-6)
    }

    @Test func captionKeepsClearOfALineIntoTheTopRight() {
        let plot = Rect(0, 0, 200, 100)
        let pts = [Point(20, 80), Point(180, 15)]
        let (x, y) = ChartRender.captionAt(plot, 60, 20, pts, 0)
        #expect(x > 100 && y > 40, "label on the line at \(x) \(y)")
    }

    @Test func forecastReservesAtMostThreeCategorySlots() {
        var c = Chart.sample(.line)
        var t = Trendline.default
        t.forward = 10
        t.backward = 0.5
        c.series[0].trendlines.append(t)
        #expect(ChartRender.forecastPad(c) == (0.5, 3))
        c.series[0].trendlines[0].kind = .movingAvg
        #expect(ChartRender.forecastPad(c) == (0, 0))
        c.kind = .scatter
        c.series[0].trendlines[0].kind = .linear
        #expect(ChartRender.forecastPad(c) == (0, 0))
    }

    // MARK: tests.rs

    @Test func effectsTablesChartsRender() {
        var sh = shapeOf(600, Xfrm(50, 50, 200, 100))
        sh.style = .accent(.accent1)
        sh.effects = Effects(
            outerShadow: Shadow(
                color: .rgb(.black), blur: 8, dist: 6, dir: 45, inner: false, sx: 1, sy: 1, kx: 0, ky: 0, align: "", rotateWithShape: false
            ),
            glow: Glow(color: .rgb(.rgb(255, 200, 0)), radius: 6),
            softEdge: 4
        )
        var t = Table(rows: 3, cols: 3, width: 300, rowHeight: 30)
        t.mutateCell(0, 0) { $0.text = .fromText("Head") }
        let tbl = shapeOf(601, Xfrm(300, 50, 300, 90), .table(t))
        let kinds: [ChartType] = [.column, .bar, .line, .pie, .doughnut, .area, .scatter, .stackedColumn]
        let charts = kinds.enumerated().map { i, k in shapeOf(700 + UInt32(i), Xfrm(Double(i) * 110, 300, 100, 100), .chart(.sample(k))) }
        let img = renderDeck(deckOf([sh, tbl] + charts))
        // Shadow darkens below-right of the shape (grey, past the glow), blurred by a third of its 8 pt blur
        // radius.
        let px = pixelAt(img, 255, 155)
        #expect(px[0] < 240 && px[0] == px[2], "\(px)")
    }

    @Test func comboChartDrawsColumnsAndALineOnItsOwnAxis() {
        // Columns in the hundreds of thousands, a green line in the thousands on the secondary axis: the line
        // must sit up in the plot, not flat along the bottom of the primary scale.
        var c = Chart.sample(.combo)
        c.title = nil
        c.legend = nil
        c.series = Array(c.series.prefix(2))
        c.categories = ["A", "B", "C"]
        c.series[0].kind = .column
        c.series[0].values = [200_000, 300_000, 250_000]
        c.series[1].kind = .line
        c.series[1].values = [7000, 7000, 7000]
        c.series[1].secondaryAxis = true
        c.series[1].line = .solid(.rgb(.rgb(0, 176, 80)), 3)
        let img = renderChart(c)
        func green(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            (y0 ..< y1).contains { y in
                let p = pixelAt(img, x, y)
                return p[1] > 120 && p[0] < 80 && p[2] < 140
            }
        }
        // The line is in the upper half (7 000 of an axis to 8 000), and columns fill the plot's bottom.
        #expect(green(480, 20, 270), "line not in the upper half")
        #expect(!green(480, 400, 500), "line along the bottom")
        let col = pixelAt(img, 480, 480)
        #expect(col[0] < 250 || col[1] < 250 || col[2] < 250, "no column: \(col)")
    }

    func trendChart(_ title: String, _ kind: ChartType, _ ys: [Double], _ trend: Trendline, _ yMax: Double) -> Chart {
        var c = Chart.sample(kind)
        c.title = title
        c.legend = nil
        c.categories = ["A", "B", "C", "D"]
        c.series = Array(c.series.prefix(1))
        c.series[0].name = "Data"
        c.series[0].values = ys
        c.yMin = 0
        c.yMax = yMax
        c.series[0].trendlines = [trend]
        return c
    }

    func trendLine(_ kind: TrendlineType) -> Trendline {
        var t = Trendline.default
        t.kind = kind
        t.dispEq = true
        t.dispRSqr = true
        return t
    }

    /// Six charts, one trendline type each. `draw` drops the trendlines when false.
    func trendGallery(_ draw: Bool) -> RenderImage {
        var poly = trendLine(.poly)
        poly.order = 2
        var ma = trendLine(.movingAvg)
        ma.period = 2
        var charts = [
            trendChart("Linear", .column, [3, 5, 7, 9], trendLine(.linear), 12),
            trendChart("Exponential", .lineMarkers, [1, 2, 4, 8], trendLine(.exp), 10),
            trendChart("Logarithmic", .lineMarkers, [Darwin.log(1.0), Darwin.log(2.0), Darwin.log(3.0), Darwin.log(4.0)], trendLine(.log), 2),
            trendChart("Polynomial", .lineMarkers, [1, 4, 9, 16], poly, 18),
            trendChart("Power", .lineMarkers, [2, 2 * 2.0.squareRoot(), 2 * 3.0.squareRoot(), 4], trendLine(.power), 6),
            trendChart("Moving average", .lineMarkers, [2, 8, 4, 10], ma, 12),
        ]
        if !draw {
            for i in charts.indices { charts[i].series[0].trendlines.removeAll() }
        }
        let shapes = charts.enumerated().map { i, c in
            shapeOf(800 + UInt32(i), Xfrm(12 + Double(i % 3) * 316, 12 + Double(i / 3) * 264, 304, 252), .chart(c))
        }
        return renderDeck(deckOf(shapes))
    }

    /// Pixels dark in `on` and at least 20 lighter in `off`.
    func addedInk(_ on: RenderImage, _ off: RenderImage) -> Int {
        zip(straightPixels(on), straightPixels(off)).filter { a, b in a[0] < 50 && a[1] < 50 && a[2] < 50 && Int(b[0]) - Int(a[0]) > 20 }.count
    }

    @Test func trendlinesDrawThroughThePointsWithALabel() {
        let on = trendGallery(true)
        let off = trendGallery(false)
        #expect(on.width == 960 && on.height == 540)
        let dark = addedInk(on, off)
        #expect(dark > 40, "dashed trendline ink \(dark)")
        // A scatter fit uses the real x values and still paints the dash.
        var scatter = trendChart("Scatter", .scatter, [2, 4, 6, 8], trendLine(.linear), 10)
        scatter.series[0].xValues = (1 ... 4).map { Double($0) }
        let with = renderChart(scatter, 810, Xfrm(0, 0, 480, 360))
        scatter.series[0].trendlines.removeAll()
        let without = renderChart(scatter, 810, Xfrm(0, 0, 480, 360))
        let scatterDark = addedInk(with, without)
        #expect(scatterDark > 20, "scatter trendline ink \(scatterDark)")
    }

    @Test func chartAxisTitlesAreDrawn() {
        func draw(_ titles: (String?, String?)) -> RenderImage {
            var c = Chart.sample(.column)
            c.title = nil
            c.legend = nil
            c.axisTitles = Pair(titles.0, titles.1)
            return renderChart(c, 624)
        }
        func ink(_ img: RenderImage, _ r: (Int, Int, Int, Int)) -> Int {
            (r.0 ..< r.2).reduce(0) { n, x in n + (r.1 ..< r.3).filter { pixelAt(img, x, $0)[0] < 160 }.count }
        }
        let bare = draw((nil, nil))
        let titled = draw(("Month", "Revenue"))
        // A turned "Revenue" down the left edge, "Month" along the bottom.
        let left = (38, 150, 62, 390)
        let bottom = (380, 490, 580, 520)
        #expect(ink(titled, left) > ink(bare, left) + 30, "value axis title")
        #expect(ink(titled, bottom) > ink(bare, bottom) + 30, "category axis title")
    }

    @Test func columnSeriesDrawTheirPatternFillAndNoFillWithTheirOutline() throws {
        // Three column series, as PowerPoint draws them: a red-on-yellow pattern, no fill with a blue outline,
        // and no fill at all. None takes a palette colour; the legend keys match the bars.
        func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ColorRef { .rgb(.rgb(r, g, b)) }
        var c = Chart.sample(.column)
        c.title = nil
        c.series = Array(c.series.prefix(3))
        c.categories = ["A"]
        for i in c.series.indices { c.series[i].values = [10] }
        c.series[0].fill = .pattern(PatternFill(preset: "dkDnDiag", fg: rgb(255, 0, 0), bg: rgb(255, 255, 0)))
        c.series[1].fill = .none_
        var outline = Line.default
        outline.width = 3
        outline.fill = .solid(rgb(0, 0, 255))
        c.series[1].line = outline
        c.series[2].fill = .none_
        let img = renderChart(c, 625)
        let px = straightPixels(img)
        func count(_ f: ([UInt8]) -> Bool) -> Int { px.filter(f).count }
        // The 8×8 tile lands at 0.75 px per cell, so every pixel straddles cells. vello samples it bilinearly at
        // the pixel centre and leaves some pixels pure red; CoreGraphics area-averages when it minifies, so red
        // comes out orange-red (green up to about 112). Red is counted with that tolerance.
        let red = count { $0[0] > 220 && $0[1] < 120 && $0[2] < 40 }
        let yellow = count { $0[0] > 220 && $0[1] > 220 && $0[2] < 40 }
        let blue = count { $0[0] < 40 && $0[1] < 40 && $0[2] > 220 }
        #expect(red > 1000 && yellow > 1000, "the pattern's two colours: \(red) red, \(yellow) yellow")
        #expect(blue > 300, "the empty series' outline: \(blue)")
        // No palette colour: the theme's accents would show for any series drawn the old way.
        let p = deckOf([])
        let ctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        for i in 0 ..< 3 {
            let a = ChartRender.seriesColor(ctx, c, i)
            let n = count { abs(Int($0[0]) - Int(a.r)) < 6 && abs(Int($0[1]) - Int(a.g)) < 6 && abs(Int($0[2]) - Int(a.b)) < 6 }
            #expect(n < 50, "palette colour \(i) drawn on \(n) pixels")
        }
    }

    @Test func columnPointsTakeTheirOwnFillAndSmoothLinesCurve() throws {
        // One column series where only the middle point is given a red c:dPt fill.
        var c = Chart.sample(.column)
        c.title = nil
        c.legend = nil
        c.series = Array(c.series.prefix(1))
        c.categories = ["A", "B", "C"]
        c.series[0].values = [10, 10, 10]
        c.series[0].pointFills = [Pair(1, .solid(.rgb(solidRed)))]
        var img = renderChart(c, 621)
        func isRed(_ p: [UInt8]) -> Bool { Array(p.prefix(3)) == [255, 0, 0] }
        func red(_ x: Int) -> Bool { (300 ..< 500).contains { isRed(pixelAt(img, x, $0)) } }
        #expect(red(480), "the middle column takes its point's fill")
        #expect(!red(200) && !red(760), "the others keep the series colour")

        // Two series, gap 150 %, no overlap: each bar is a band / 3.5 wide (PowerPoint's and LibreOffice's
        // geometry), not band / 2.5 split in two.
        c = Chart.sample(.column)
        c.title = nil
        c.legend = nil
        c.series = Array(c.series.prefix(2))
        c.categories = ["A"]
        c.series[0].values = [10]
        c.series[1].values = [10]
        c.series[0].fill = .solid(.rgb(solidRed))
        (c.gapWidth, c.overlap) = (1.5, 0)
        img = renderChart(c, 622)
        let lowest = try #require((0 ..< 540).reversed().first { y in (0 ..< 960).contains { isRed(pixelAt(img, $0, y)) } })
        let y = lowest - 5
        let reds = Double((0 ..< 960).filter { isRed(pixelAt(img, $0, y)) }.count)
        // The plot is ~850 px wide with one category: a bar is ~240 px (it was ~170 when the band was split
        // as 1 + gap and then shared between the series).
        #expect((200.0 ..< 280.0).contains(reds), "bar \(reds) px")

        // A smoothed line through a peak overshoots no point but leaves the straight chord.
        let p = ChartRender.smoothPath([Point(0, 0), Point(10, 10), Point(20, 0)])
        #expect(p.elements.count == 3, "a cubic per segment")
        guard case .cubic(let first)? = p.segments.first else {
            Issue.record("no cubic")
            return
        }
        let mid = first.eval(0.5)
        #expect(mid.y > mid.x, "the first half bows towards the peak instead of following the chord: \(mid)")
    }

    @Test func horizontalBarsListTheFirstCategoryAtTheBottomUnlessReversed() {
        func draw(_ reversed: Bool) -> Int {
            var c = Chart.sample(.bar)
            c.title = nil
            c.legend = nil
            c.series = Array(c.series.prefix(1))
            c.categories = ["A", "B", "C"]
            c.series[0].values = [10, 10, 10]
            c.series[0].pointFills = [Pair(0, .solid(.rgb(solidRed)))]
            c.catReversed = reversed
            let img = renderChart(c, 623)
            let rows = (0 ..< 540).filter { y in (0 ..< 960).contains { Array(pixelAt(img, $0, y).prefix(3)) == [255, 0, 0] } }
            guard let f = rows.first, let l = rows.last else { return -1 }
            return (f + l) / 2
        }
        #expect(draw(false) > 360, "first category at the bottom: \(draw(false))")
        let r = draw(true)
        #expect(r >= 0 && r < 180, "reversed: first category at the top: \(r)")
    }

    @Test func tinyChartDoesNotBlankTheSlide() {
        // A chart a few points wide used to panic in `f64::clamp` (gutter min above max), and the panic guard
        // then blanked the whole slide.
        var red = shapeOf(800, Xfrm(100, 100, 200, 100))
        red.style = .accent(.accent1)
        var shapes = [red]
        for (i, k) in [ChartType.column, .bar, .line, .combo, .scatter].enumerated() {
            shapes.append(shapeOf(801 + UInt32(i), Xfrm(500 + Double(i) * 5, 300, 0.9, 0.9), .chart(.sample(k))))
        }
        let img = renderDeck(deckOf(shapes))
        #expect(pixelAt(img, 200, 150) != [255, 255, 255, 255], "the other shape must still draw")
        #expect(ChartRender.clampSoft(5, 10.5, 0.276) == 0.276)
    }

    @Test func chartsInDegenerateFramesDrawWithoutTrapping() throws {
        // A chart frame squashed to no width (cx="0" in a generated file) made the value labels' gutter clamp
        // panic (its upper bound, a share of the width, fell below its lower bound). Every chart type and
        // legend position must survive any frame size.
        let p = Presentation.default
        let rctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        let kinds: [ChartType] = [
            .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .line, .lineMarkers, .stackedLine, .area,
            .stackedArea, .pie, .doughnut, .scatter, .bubble, .radar, .filledRadar, .stock, .surface, .histogram, .pareto,
            .boxWhisker, .waterfall, .funnel, .treemap, .sunburst, .combo,
        ]
        let c = try #require(Canvas(width: 64, height: 64))
        for k in kinds {
            for (w, h) in [(0.0, 403.0), (403, 0), (0, 0), (2, 400), (400, 2), (12, 12)] {
                for legend in [nil, "b", "t", "r", "l", "tr"] {
                    var ch = Chart.sample(k)
                    ch.legend = legend
                    ChartRender.draw(c, rctx, ch, .identity, w, h)
                }
            }
        }
        _ = c.finish()
    }

    @Test func singleSeriesColumnChartVariesColoursByPoint() {
        func render(_ vary: Bool) -> [UInt8] {
            var c = Chart.sample(.column)
            c.series = Array(c.series.prefix(1))
            c.varyColors = vary
            return renderChart(c, 800, Xfrm(50, 50, 400, 300)).pixels
        }
        #expect(render(true) != render(false))
    }

    /// A chart that has no text colour of its own takes PowerPoint's default, the theme's text colour at 65 %
    /// plus 35 %: light on Nocturne's dark slides, 595959 grey on Harbor's light ones.
    @Test func chartTextFollowsTheThemeWhenItHasNoColourOfItsOwn() throws {
        func draw(_ theme: String, _ title: String?) throws -> RenderImage {
            var c = Chart.sample(.column)
            c.title = title
            c.legend = nil
            c.dataLabels = false
            var p = deckOf([shapeOf(630, Xfrm(0, 0, 960, 540), .chart(c))])
            p.masters[0].theme = try #require(builtinThemes().first { $0.name == theme })
            return renderDeck(p)
        }
        func lum(_ px: [UInt8]) -> Int { (Int(px[0]) * 299 + Int(px[1]) * 587 + Int(px[2]) * 114) / 1000 }
        // Pixels in the title band that pass `f`.
        func count(_ img: RenderImage, _ f: (Int) -> Bool) -> Int {
            (200 ..< 760).reduce(0) { n, x in n + (4 ..< 70).filter { f(lum(pixelAt(img, x, $0))) }.count }
        }
        let (darkBare, darkTitled) = (try draw("Nocturne", nil), try draw("Nocturne", "Quarterly revenue"))
        #expect(lum(pixelAt(darkBare, 5, 5)) < 60, "Nocturne's slide is dark: \(pixelAt(darkBare, 5, 5))")
        let lightInk = count(darkTitled) { $0 > 200 } - count(darkBare) { $0 > 200 }
        #expect(lightInk > 100, "the title is light on a dark theme (light pixels added: \(lightInk))")
        let (lightBare, lightTitled) = (try draw("Harbor", nil), try draw("Harbor", "Quarterly revenue"))
        #expect(lum(pixelAt(lightBare, 5, 5)) > 200, "Harbor's slide is light: \(pixelAt(lightBare, 5, 5))")
        // 595959 has luminance 89: dark, but not black.
        let darkInk = count(lightTitled) { $0 < 120 } - count(lightBare) { $0 < 120 }
        #expect(darkInk > 100, "the title is dark on a light theme (dark pixels added: \(darkInk))")
        let blackInk = count(lightTitled) { $0 < 40 } - count(lightBare) { $0 < 40 }
        #expect(blackInk < 20, "the title is PowerPoint's 595959 grey, not black (black pixels added: \(blackInk))")
    }

    /// Pie data labels sit on the slices in white; a colour given to the chart's text colours them too, as it
    /// does the title and legend.
    @Test func pieDataLabelsTakeTheChartTextColourWhenItHasOne() {
        func draw(_ colour: ColorRef?) -> RenderImage {
            var c = Chart.sample(.pie)
            c.title = nil
            c.legend = nil
            c.dataLabels = true
            c.textColor = colour
            return renderChart(c, 632, Xfrm(0, 0, 400, 400))
        }
        func count(_ img: RenderImage, _ f: ([UInt8]) -> Bool) -> Int {
            (0 ..< 400).reduce(0) { n, x in n + (0 ..< 400).filter { f(pixelAt(img, x, $0)) }.count }
        }
        let red = { (p: [UInt8]) in p[0] > 200 && p[1] < 60 && p[2] < 60 }
        let white = { (p: [UInt8]) in p[0] > 245 && p[1] > 245 && p[2] > 245 }
        let (plain, coloured) = (draw(nil), draw(.rgb(solidRed)))
        #expect(count(plain, red) == 0, "no red without a text colour")
        #expect(count(coloured, red) > 30, "the labels take the chart's red: \(count(coloured, red)) red pixels")
        #expect(count(plain, white) > count(coloured, white), "the labels were white before")
    }
}
