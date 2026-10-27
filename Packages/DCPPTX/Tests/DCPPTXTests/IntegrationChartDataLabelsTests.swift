// The tests of deckcraft crates/pptx/tests/chart_data_labels.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors). Series-level data labels: `c:dLbls/c:showVal` on a series overrides the
// chart-wide setting, and a bare `<c:showVal/>` (no `val` attribute) means true, as the schema's default
// (#868).
import DCCore
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

/// A one-slide deck (a blank-layout slide) whose `chart` sits in a shape named "Bars".
private func labelsDeck(_ chart: Chart) -> Presentation {
    var p = newPresentation(nil)
    p.slides.removeAll()
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    var slide = newSlide(&p, layout) ?? Slide.default
    var shape = Shape.default
    shape.id = ShapeId(p.allocId() ?? 0)
    shape.name = "Bars"
    shape.xfrm = Xfrm(40, 40, 400, 300)
    shape.kind = .chart(chart)
    slide.shapes.append(shape)
    p.slides.append(slide)
    return p
}

/// A one-slide deck whose bar chart shows no labels anywhere.
private func barChartPPTX() throws -> [UInt8] {
    var chart = Chart.sample(.column)
    chart.dataLabels = false
    for i in chart.series.indices { chart.series[i].dataLabels = nil }
    return try PPTX.export(labelsDeck(chart))
}

/// A one-slide deck with a combo chart: a bar group and a line group.
private func comboChartPPTX() throws -> [UInt8] {
    var chart = Chart.sample(.combo)
    chart.series = Array(chart.series.prefix(2))
    if chart.series.count > 1 { chart.series[1].kind = .line }
    return try PPTX.export(labelsDeck(chart))
}

/// Rewrite the chart part's XML through `f` and re-import the deck.
private func reimport(_ bytes: [UInt8], _ f: (String) -> String) throws -> Presentation {
    let patched = try IT.zip(IT.entries(bytes).map { e in
        guard e.name.hasPrefix("ppt/charts/chart"), e.name.hasSuffix(".xml"), !e.name.has("_rels") else { return e }
        return (e.name, Array(f(String(decoding: e.data, as: UTF8.self)).utf8))
    })
    return try PPTX.import(patched)
}

private func chartOf(_ p: Presentation) -> Chart? {
    for sh in p.slides.first?.shapes ?? [] {
        if case .chart(let c) = sh.kind { return c }
    }
    return nil
}

@Suite struct IntegrationChartDataLabelsTests {
    /// `<c:showVal/>` on the first series: that series shows labels although the chart-wide
    /// setting is off; the other series stay quiet.
    // Rust: chart_data_labels.rs::bare_series_showval_shows_labels
    @Test func bareSeriesShowvalShowsLabels() throws {
        let p = try reimport(barChartPPTX()) { $0.replacen("<c:cat>", #"<c:dLbls><c:showVal/></c:dLbls><c:cat>"#, 1) }
        let c = try #require(chartOf(p), "no chart in the deck")
        try #require(!c.series.isEmpty)
        #expect(!c.dataLabels, "the chart-wide setting stays off")
        #expect(c.series[0].dataLabels == true, "a bare showVal means true")
        #expect(c.seriesDataLabels(c.series[0]), "the first series' labels show")
        for s in c.series.dropFirst() {
            #expect(s.dataLabels == nil, "other series keep the chart's setting")
            #expect(!c.seriesDataLabels(s), "and stay quiet")
        }
    }

    /// `val="0"` on the series hides its labels although the chart-wide setting is on.
    // Rust: chart_data_labels.rs::series_showval_false_hides_labels
    @Test func seriesShowvalFalseHidesLabels() throws {
        let p = try reimport(barChartPPTX()) { xml in
            xml.replacen("<c:cat>", #"<c:dLbls><c:showVal val="0"/></c:dLbls><c:cat>"#, 1)
                .replacen("<c:gapWidth", #"<c:dLbls><c:showVal/></c:dLbls><c:gapWidth"#, 1)
        }
        let c = try #require(chartOf(p), "no chart in the deck")
        try #require(c.series.count > 1)
        #expect(c.dataLabels, "the bare chart-wide showVal turns labels on")
        #expect(c.series[0].dataLabels == false, "the explicit series false is read")
        #expect(!c.seriesDataLabels(c.series[0]), "and hides that series' labels")
        #expect(c.seriesDataLabels(c.series[1]), "the next series takes the chart-wide on")
    }

    /// The series' label setting survives a save and load.
    // Rust: chart_data_labels.rs::series_label_settings_round_trip
    @Test func seriesLabelSettingsRoundTrip() throws {
        var chart = Chart.sample(.column)
        try #require(chart.series.count > 1)
        chart.dataLabels = true
        chart.series[0].dataLabels = false
        chart.series[1].dataLabels = true
        let bytes = try PPTX.export(labelsDeck(chart))
        let back = try PPTX.import(bytes)
        let c = try #require(chartOf(back), "no chart in the deck")
        try #require(c.series.count > 1)
        #expect(c.dataLabels)
        #expect(c.series[0].dataLabels == false, "the explicit off survives")
        #expect(c.series[1].dataLabels == true, "the explicit on survives")
        #expect(!c.seriesDataLabels(c.series[0]))
        #expect(c.seriesDataLabels(c.series[1]))
    }

    /// A combo chart's groups keep their own label setting: the group that asks for no labels
    /// keeps them off, even when the other group asks for them (#868).
    // Rust: chart_data_labels.rs::a_combo_chart_keeps_each_groups_own_label_setting
    @Test func aComboChartKeepsEachGroupsOwnLabelSetting() throws {
        let p = try reimport(comboChartPPTX()) { xml in
            // The bar group asks for no labels, the line group for labels.
            xml.replacen("<c:gapWidth", #"<c:dLbls><c:showVal val="0"/></c:dLbls><c:gapWidth"#, 1)
                .replacen("<c:marker val=\"1\"/>", #"<c:dLbls><c:showVal/></c:dLbls><c:marker val="1"/>"#, 1)
        }
        let c = try #require(chartOf(p), "no chart in the deck")
        try #require(c.series.count > 1)
        #expect(c.dataLabels, "the line group's ask turns the chart-wide setting on")
        #expect(c.series[0].dataLabels == false, "the bar group asks for no labels")
        #expect(!c.seriesDataLabels(c.series[0]), "so the bars stay quiet")
        #expect(c.seriesDataLabels(c.series[1]), "the line takes the chart-wide on")
    }

    /// Turning Data Labels on through `chart.options` shows the labels of series that the file
    /// switched off one by one.
    // Rust: chart_data_labels.rs::chart_options_data_labels_on_overrides_series_off
    // Built without the engine: `file.open` is the import of the saved file (read from memory here, not
    // through a temp file), and `chart.options {dataLabels: true}` sets `dataLabels` and clears every
    // series' own setting, as the engine's `chart_options` does.
    @Test func chartOptionsDataLabelsOnOverridesSeriesOff() throws {
        let p = try reimport(barChartPPTX()) { $0.replace("<c:cat>", #"<c:dLbls><c:showVal val="0"/></c:dLbls><c:cat>"#) }
        let pc = try #require(chartOf(p))
        #expect(pc.series.allSatisfy { !pc.seriesDataLabels($0) }, "every series starts quiet")
        var doc = try PPTX.import(PPTX.export(p))
        let dc = try #require(chartOf(doc))
        #expect(dc.series.allSatisfy { !dc.seriesDataLabels($0) })
        let j = try #require(doc.slides[0].shapes.firstIndex { if case .chart = $0.kind { return true }; return false }, "chart")
        if case .chart(var ch) = doc.slides[0].shapes[j].kind {
            ch.dataLabels = true
            // A series' own setting would otherwise keep overriding the chart-wide switch.
            for i in ch.series.indices { ch.series[i].dataLabels = nil }
            ch.raw = nil
            doc.slides[0].shapes[j].kind = .chart(ch)
        }
        let c = try #require(chartOf(doc))
        #expect(c.series.allSatisfy { c.seriesDataLabels($0) }, "every series shows its labels")
    }
}
