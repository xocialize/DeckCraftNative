// Port of deckcraft crates/pptx/tests/it/corpus_charts.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned corpus slice: combo charts (labels and trendlines), merged tables with diagonal borders, and text
// columns, autofit, vertical text and a WordArt warp.
//
// A combo series can sit on the secondary value axis (`secondary_axis`, `y2_*`). That axis is read from
// files; rebuilding a chart does not write it yet, so this test does not require it to survive.
import DCColor
import DCModel
import Testing
@testable import DCPPTX

private func byName(_ s: Slide, _ name: String) throws -> Shape {
    try #require(s.shapes.first { $0.name == name }, "no shape \(name)")
}

private func plain(_ t: TextBody) -> String {
    t.paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
}

private func trend(_ kind: TrendlineType) -> Trendline {
    var t = Trendline.default
    t.kind = kind
    return t
}

private func corpus() throws -> Presentation {
    var p = newPresentation(nil)
    p.props.title = "Chart and table corpus"
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    let made = newSlide(&p, layout)
    var s = try #require(made, "slide")

    var chart = Chart.default
    chart.kind = .combo
    chart.title = "Spend and clicks"
    chart.categories = ["W1", "W2", "W3", "W4"]
    chart.dataLabels = true
    chart.y2Max = 8000.0
    chart.y2Format = "0.0"
    var spend = Series(name: "Spend", values: [200.0, 310.0, 280.0, 360.0])
    spend.kind = .column
    var cubic = Trendline.default
    cubic.kind = .poly
    cubic.name = "Cubic"
    cubic.order = 3
    spend.trendlines = [cubic, trend(.exp)]
    var clicks = Series(name: "Clicks", values: [6000.0, 7400.0, 7100.0, 7900.0])
    clicks.kind = .lineMarkers
    clicks.secondaryAxis = true
    clicks.dataLabels = false
    var fit = Trendline.default
    fit.kind = .linear
    fit.name = "Fit & forecast"
    fit.forward = 1.0
    fit.backward = 0.5
    fit.intercept = 0.0
    fit.dispEq = true
    fit.dispRSqr = true
    var moving = Trendline.default
    moving.kind = .movingAvg
    moving.period = 2
    clicks.trendlines = [fit, trend(.log), trend(.power), moving]
    chart.series = [spend, clicks]
    var ch = IT.shape(&p, "Combo", 40.0, 40.0, 420.0, 260.0)
    ch.kind = .chart(chart)
    s.shapes.append(ch)

    var table = Table(rows: 3, cols: 3, width: 360.0, rowHeight: 28.0)
    table.mutateCell(0, 0) { $0.text = TextBody.fromText("Merged") }
    let merged = table.merge(0, 0, 1, 1)
    #expect(merged)
    table.mutateCell(0, 2) { cell in
        cell.text = TextBody.fromText("Diag")
        cell.diagDown = Line.solid(ColorRef.rgb(Rgba.rgb(180, 40, 40)), 1.5)
        cell.diagUp = Line.solid(ColorRef.rgb(Rgba.rgb(20, 90, 160)), 2.0)
    }
    var ts = IT.shape(&p, "Merged table", 40.0, 320.0, 360.0, 84.0)
    ts.kind = .table(table)
    s.shapes.append(ts)

    var columns = TextBody.fromText("Two columns\nof vertical text")
    columns.body.columns = 3
    columns.body.colSpacing = 18.0
    columns.body.autofit = .shrink(fontScale: 0.85, lineReduction: 0.2)
    columns.body.vert = .vertical270
    var col = IT.shape(&p, "Columns", 480.0, 40.0, 200.0, 160.0)
    col.text = columns
    s.shapes.append(col)

    var warp = TextBody.fromText("Arch")
    warp.body.warp = "textArchUp"
    warp.body.warpAdj = [5_000_000.0]
    warp.body.autofit = .shape
    var word = IT.shape(&p, "Warp", 480.0, 220.0, 200.0, 80.0)
    word.text = warp
    s.shapes.append(word)

    p.slides.append(s)
    return p
}

private func chartOf(_ s: Slide) throws -> Chart {
    guard case let .chart(c) = try byName(s, "Combo").kind else {
        Issue.record("not a chart")
        throw ChartsCorpusError.notAChart
    }
    return c
}

private enum ChartsCorpusError: Error { case notAChart, notATable }

@Suite struct IntegrationCorpusChartsTests {
    // Rust: it/corpus_charts.rs::chart_table_and_text_corpus_round_trips
    @Test func chartTableAndTextCorpusRoundTrips() throws {
        let p = try corpus()
        let q = try IT.round(p)
        let slide = try #require(q.slides.at(1))
        let srcSlide = try #require(p.slides.at(1))
        let src = try chartOf(srcSlide)
        let got = try chartOf(slide)
        #expect(got.kind == .combo)
        #expect(got.title == "Spend and clicks")
        #expect(got.categories == src.categories)
        #expect(got.dataLabels)
        #expect(got.series.count == 2)
        for (a, b) in zip(src.series, got.series) {
            #expect(a.name == b.name)
            #expect(a.values == b.values)
            #expect(a.kind == b.kind)
            #expect(a.dataLabels == b.dataLabels)
            #expect(a.trendlines == b.trendlines)
        }

        let twice = try IT.round(q)
        let twiceSlide = try #require(twice.slides.at(1))
        let again = try chartOf(twiceSlide)
        for (a, b) in zip(got.series, again.series) {
            #expect(a.trendlines == b.trendlines)
            #expect(a.dataLabels == b.dataLabels)
        }

        guard case let .table(t) = try byName(slide, "Merged table").kind else {
            Issue.record("not a table")
            return
        }
        let anchor = try #require(t.cell(0, 0), "anchor")
        #expect(anchor.gridSpan == 2 && anchor.rowSpan == 2)
        #expect(!anchor.hMerge && !anchor.vMerge)
        #expect(plain(anchor.text) == "Merged")
        #expect(t.cell(0, 1).map { $0.hMerge && !$0.vMerge } == true)
        #expect(t.cell(1, 0).map { !$0.hMerge && $0.vMerge } == true)
        #expect(t.cell(1, 1).map { $0.hMerge && $0.vMerge } == true)
        let diag = try #require(t.cell(0, 2), "diag")
        #expect(diag.diagDown == Line.solid(ColorRef.rgb(Rgba.rgb(180, 40, 40)), 1.5))
        #expect(diag.diagUp == Line.solid(ColorRef.rgb(Rgba.rgb(20, 90, 160)), 2.0))
        #expect(plain(diag.text) == "Diag")

        let cols = try #require(try byName(slide, "Columns").text, "columns")
        #expect(plain(cols) == "Two columns\nof vertical text")
        #expect(cols.body.columns == 3)
        #expect(cols.body.colSpacing == 18.0)
        #expect(cols.body.autofit == .shrink(fontScale: 0.85, lineReduction: 0.2))
        #expect(cols.body.vert == .vertical270)

        let warp = try #require(try byName(slide, "Warp").text, "warp")
        #expect(plain(warp) == "Arch")
        #expect(warp.body.warp == "textArchUp")
        #expect(warp.body.warpAdj == [5_000_000.0])
        #expect(warp.body.autofit == .shape)
    }
}
