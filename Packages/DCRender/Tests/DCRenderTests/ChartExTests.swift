// Ported from deckcraft crates/render/src/chartex.rs (its in-file tests) and the Office 2016 chart tests of
// tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Tolerances are the Rust
// ones.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import Testing

@Suite struct ChartExTests {
    // MARK: chartex.rs

    @Test func squarifyTilesTheAreaInProportion() {
        let vals: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let r = Rect(0, 0, 600, 400)
        let tiles = ChartEx.squarify(vals, r)
        let total = vals.reduce(0, +)
        for (t, v) in zip(tiles, vals) {
            #expect(abs(t.area - v / total * r.area) < 1e-6, "\(t) for \(v)")
            #expect(t.x0 >= -1e-9 && t.y0 >= -1e-9 && t.x1 <= 600 + 1e-6 && t.y1 <= 400 + 1e-6, "\(t)")
            // Squarified: no sliver tiles.
            let aspect = Swift.max(t.width, t.height) / Swift.min(t.width, t.height)
            #expect(aspect < 4, "\(t)")
        }
        for (i, a) in tiles.enumerated() {
            for b in tiles[(i + 1)...] {
                #expect(a.intersect(b).area < 1e-6, "\(a) overlaps \(b)")
            }
        }
        #expect(ChartEx.squarify([0, 0], r).allSatisfy { $0.area == 0 })
    }

    @Test func waterfallBarsFloatAndTotalsStand() {
        var c = Chart.default
        c.kind = .waterfall
        c.subtotals = [3]
        c.series = [Series(values: [100, 40, -25, 115])]
        let bars = c.waterfallBars()
        #expect(bars.map { [$0.0, $0.1] } == [[0, 100], [100, 140], [140, 115], [0, 115]])
        #expect(c.valueRange() == (0, 140))
    }

    @Test func squarifyHandlesSkewedAndExhaustedRect() {
        let vals = [1e12, 1e-6, 1e-6, 1e-6]
        let tiles = ChartEx.squarify(vals, Rect(0, 0, 100, 100))
        #expect(tiles.count == vals.count)
        #expect(tiles[0].area > 0)
    }

    // MARK: tests.rs

    @Test func office2016ChartsDrawTheirOwnLayouts() {
        func chart(_ kind: ChartType, _ vals: [Double], _ subtotals: [Int]) -> RenderImage {
            var c = Chart.default
            c.kind = kind
            c.title = nil
            c.legend = nil
            c.gridlines = false
            c.subtotals = subtotals
            c.categories = vals.indices.map { "C\($0)" }
            c.series = [Series(values: vals)]
            return renderChart(c, 621)
        }
        func ink(_ img: RenderImage, _ x: Int, _ y: Int) -> Bool {
            let p = pixelAt(img, x, y)
            return p[0] < 235 || p[1] < 235 || p[2] < 235
        }
        // Waterfall: the decrease floats (nothing under it near the axis), the total stands on it.
        let img = chart(.waterfall, [100, 40, -25, 115], [3])
        let plotBottom = (300 ..< 530).reversed().first { ink(img, 120, $0) } ?? 500
        func band(_ i: Double) -> Int { Int(80 + (900 - 80) * (i + 0.5) / 4) }
        #expect(!ink(img, band(2), plotBottom - 20), "the decrease bar reaches the axis")
        #expect(ink(img, band(3), plotBottom - 20), "the total bar doesn't stand on the axis")
        #expect(ink(img, band(1), 100), "the increase bar is missing")
        // Funnel, treemap and sunburst fill the middle of the chart.
        for kind in [ChartType.funnel, .treemap, .sunburst] {
            let img = chart(kind, [50, 30, 20], [])
            var covered = 0
            for y in Swift.stride(from: 0, to: 540, by: 10) {
                for x in Swift.stride(from: 0, to: 960, by: 10) where ink(img, x, y) { covered += 1 }
            }
            #expect(covered > 1000, "\(kind): \(covered) samples inked")
        }
    }

    /// Histograms draw touching columns of their bins, Pareto charts add the cumulative line, and box and
    /// whisker charts draw a box per group and series.
    @Test func histogramParetoAndBoxChartsDraw() {
        func inked(_ img: RenderImage) -> Int {
            var n = 0
            for y in Swift.stride(from: 0, to: 540, by: 6) {
                for x in Swift.stride(from: 0, to: 960, by: 6) {
                    let p = pixelAt(img, x, y)
                    if p[0] < 200 || p[1] < 200 || p[2] < 200 { n += 1 }
                }
            }
            return n
        }
        var empty = Chart.sample(.histogram)
        empty.series[0].values.removeAll()
        let blank = inked(renderChart(empty, 622))
        for kind in [ChartType.histogram, .pareto, .boxWhisker] {
            let n = inked(renderChart(.sample(kind), 622))
            #expect(n > blank + 400, "\(kind): \(n) inked samples (blank \(blank))")
        }
    }

    /// The distinct colours (to 1/16) sampled every `step` pixels inside the chart, white left out.
    func colours(_ img: RenderImage, _ step: Int) -> Int {
        var seen = Set<[UInt8]>()
        for y in Swift.stride(from: 60, to: 520, by: step) {
            for x in Swift.stride(from: 40, to: 920, by: step) {
                let p = pixelAt(img, x, y)
                let c = [p[0] / 16, p[1] / 16, p[2] / 16]
                if c != [15, 15, 15] { seen.insert(c) }
            }
        }
        return seen.count
    }

    /// Multi-level treemaps and sunbursts draw their groups: the treemap's group banners and the sunburst's
    /// inner ring of groups, coloured by top-level group.
    @Test func multilevelTreemapAndSunburstDrawTheirGroups() {
        for kind in [ChartType.treemap, .sunburst] {
            let img = renderChart(.sample(kind), 623)
            // Distinct colours: one hue per top-level group plus lighter children.
            let n = colours(img, 8)
            #expect(n >= 6, "\(kind): \(n) colours")
        }
    }

    /// A region map without drawable geography falls back to coloured tiles on the value scale.
    @Test func regionMapDrawsTilesOnItsColourScale() {
        let names = ["Brest", "Vitebsk", "Gomel", "Grodno", "Minsk", "Mogilev", "Minsk City"]
        let vals: [Double] = [3.1, 2.2, 2.9, 4.8, 6.0, 1.4, 9.5]
        var c = Chart.default
        c.kind = .regionMap
        c.title = "Sales by region"
        c.categories = names
        c.series = [Series(name: "Sales", values: vals)]
        c.dataLabels = true
        let n = colours(renderChart(c, 624), 6)
        #expect(n >= 5, "\(n) colours")
    }
}
