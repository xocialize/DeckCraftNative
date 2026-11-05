// The port's own: a chart drawn part by part for a chart build (`ChartRender.drawParts`, AB-T-0443).
import DCColor
import DCGeometry
import DCModel
@testable import DCRender
import Testing

private func hidden() -> ParaState {
    var s = ParaState()
    s.visible = false
    return s
}

/// Pixels of `img` within `tol` of `c`.
private func count(_ img: RenderImage, _ c: Rgba, _ tol: Int = 6) -> Int {
    straightPixels(img).filter { $0[3] > 200 && nearRGB($0, c, tol) }.count
}

@Suite struct ChartBuildRenderTests {
    let p = deckOf([shapeOf(620, Xfrm(0, 0, 960, 540), .chart(Chart.sample(.column)))])

    func render(_ parts: [(ChartElement, ParaState)]) -> RenderImage {
        var st = ShapeState()
        st.chartParts = parts
        return renderSlide(p, 0, renderOpts(1) { $0.state = { _ in st } })
    }

    /// No part states draw exactly what the chart draws without them.
    @Test func withoutPartsTheChartIsUnchanged() {
        #expect(render([]).pixels == renderDeck(p).pixels)
        // Every part shown is the same picture too.
        let all = chartBuildSteps(Chart.sample(.column), .bySeries, background: true).map { ($0, ParaState()) }
        #expect(render(all).pixels == renderDeck(p).pixels)
    }

    /// The legend's keys belong to the background, so a hidden series leaves only its key.
    var legendKeyPixels: Int {
        count(render((0 ..< 3).map { (ChartElement(step: .series, series: UInt32($0)), hidden()) }), accent(p, .accent2))
    }

    @Test func aHiddenSeriesIsNotDrawnAndTheOthersAre() {
        let a1 = accent(p, .accent1)
        let a2 = accent(p, .accent2)
        let full = renderDeck(p)
        let img = render([(ChartElement(step: .series, series: 1), hidden())])
        let key = legendKeyPixels
        #expect(key > 20 && key < 400, "the legend key: \(key)")
        #expect(count(full, a2) > 5000 && count(img, a2) == key, "series 2's bars: \(count(full, a2)) → \(count(img, a2))")
        #expect(count(img, a1) == count(full, a1), "series 1 is drawn as before")
        // With the background hidden too, nothing of series 2 is left.
        #expect(count(render([(ChartElement(step: .series, series: 1), hidden()), (ChartElement(step: .background), hidden())]), a2) == 0)
    }

    @Test func aHiddenBackgroundTakesTheGridlinesAndLegend() {
        // The gridlines (antialiased to e2e2e2) and the labels' text colour.
        let grid = Rgba.rgb(0xE2, 0xE2, 0xE2)
        let text = Rgba.rgb(0x59, 0x59, 0x59)
        let full = renderDeck(p)
        let img = render([(ChartElement(step: .background), hidden())])
        #expect(count(full, grid, 1) > 1000 && count(img, grid, 1) < count(full, grid, 1) / 10, "\(count(full, grid, 1)) → \(count(img, grid, 1))")
        #expect(count(full, text, 1) > 300 && count(img, text, 1) == 0)
        #expect(count(img, accent(p, .accent1)) > 500, "the bars still show")
    }

    @Test func aHiddenCategoryTakesOneBarOfEachSeries() {
        let a1 = accent(p, .accent1)
        let full = count(renderDeck(p), a1)
        let img = count(render([(ChartElement(step: .category, category: 0), hidden())]), a1)
        #expect(img > 0 && img < full)
    }

    /// A part halfway through a fade is drawn at that opacity, moved by its offset.
    @Test func aPartsOpacityAndOffsetApply() {
        var half = ParaState()
        half.opacity = 0.5
        let a1 = accent(p, .accent1)
        let img = render([(ChartElement(step: .series, series: 0), half)])
        #expect(count(img, a1) == count(render([(ChartElement(step: .series, series: 0), hidden())]), a1), "only the legend key is full strength")
        var moved = ParaState()
        moved.offset = Vec2(0, 1000)
        let gone = render([(ChartElement(step: .series, series: 0), moved), (ChartElement(step: .background), hidden())])
        #expect(count(gone, a1) == 0, "moved off the slide")
    }

    /// Charts drawn by their own code animate as one object: part states change nothing.
    @Test func kindsWithoutPartsDrawWhole() {
        let r = deckOf([shapeOf(620, Xfrm(0, 0, 960, 540), .chart(Chart.sample(.radar)))])
        var st = ShapeState()
        st.chartParts = [(ChartElement(step: .series, series: 0), hidden())]
        #expect(renderSlide(r, 0, renderOpts(1) { $0.state = { _ in st } }).pixels == renderDeck(r).pixels)
    }

    @Test func pieSlicesAreCategories() {
        let pie = deckOf([shapeOf(620, Xfrm(0, 0, 960, 540), .chart(Chart.sample(.pie)))])
        var st = ShapeState()
        st.chartParts = [(ChartElement(step: .category, category: 1), hidden()), (ChartElement(step: .background), hidden())]
        let img = renderSlide(pie, 0, renderOpts(1) { $0.state = { _ in st } })
        let a2 = accent(pie, .accent2)
        #expect(count(renderDeck(pie), a2) > 500 && count(img, a2) == 0)
        #expect(count(img, accent(pie, .accent1)) > 500)
    }
}
