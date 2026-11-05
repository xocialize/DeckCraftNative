// DCApp — the chart inspector's Series Options section: gap width and overlap (`chart.options`), up/down bars,
// and one series' trendline and error bars (`chart.options` with `series`), picked from a series list as PowerPoint asks
// which series (O-20, O-23). Each change is one command step. The port's own (AB-T-0436).
import CNCore
import DCAppModel
import DCEngine
import DCModel
import SwiftUI

struct ChartSeriesSection: View {
    let ctl: InspectorController
    let id: ShapeId
    let chart: Chart
    @State private var picked = 0

    var body: some View {
        let c = chart
        let gap = c.takesGapWidth
        let index = Swift.min(picked, Swift.max(c.series.count - 1, 0))
        let series = c.series.indices.contains(index) ? c.series[index] : nil
        let trend = series.map(c.takesTrendline) ?? false
        let bars = series.map(c.takesErrorBars) ?? false
        if gap || c.takesUpDownBars || c.series.contains(where: c.takesTrendline) || c.series.contains(where: c.takesErrorBars) {
            Section(String(localized: "Series Options", bundle: .module, comment: "The chart inspector's section for its series")) {
                if gap {
                    CommitSlider(label: String(localized: "Gap Width", bundle: .module), value: c.gapWidth * 100, range: 0 ... 500, suffix: "%") {
                        options("gapWidth", .double($0.rounded()))
                    }
                }
                if c.takesOverlap {
                    CommitSlider(label: String(localized: "Series Overlap", bundle: .module), value: c.overlap * 100, range: -100 ... 100, suffix: "%") {
                        options("overlap", .double($0.rounded()))
                    }
                }
                if c.takesUpDownBars {
                    Toggle(String(localized: "Up/Down Bars", bundle: .module), isOn: Binding(get: { c.upDownBars }, set: { options("upDownBars", .bool($0)) }))
                }
                if let series, trend || bars {
                    Picker(String(localized: "Series", bundle: .module, comment: "Which chart series the trendline and error bars belong to"), selection: $picked) {
                        ForEach(c.series.indices, id: \.self) { Text(ChartElements.seriesName(c.series[$0], $0)).tag($0) }
                    }
                    if trend {
                        let fitting = ChartElements.trendlineChoices.filter { ChartElements.fits($0.2, c, series) }
                        ChoicePicker(label: String(localized: "Trendline", bundle: .module),
                                     options: [(String(localized: "None", bundle: .module, comment: "No trendline"), "")] + fitting.map { ($0.0, $0.1) },
                                     current: ChartElements.trendTag(series)) { tag in
                            seriesOptions(index, "trendline", ChartElements.trendlineChoices.first { $0.1 == tag }?.2 ?? .null)
                        }
                    }
                    if bars {
                        ChoicePicker(label: String(localized: "Error Bars", bundle: .module),
                                     options: [(String(localized: "None", bundle: .module, comment: "No error bars"), "")]
                                        + ChartElements.errorBars.map { ($0.label, $0.errorBars.get("type")?.asStr ?? "") },
                                     current: series.errorBars?.valType ?? "") { tag in
                            seriesOptions(index, "errorBars", ChartElements.errorBars.first { $0.errorBars.get("type")?.asStr == tag }?.errorBars ?? .null)
                        }
                    }
                }
            }
        }
    }

    private func options(_ key: String, _ value: JSON) {
        ctl.run("chart.options", .object(JSONObject([JSONObject.Entry(key: "id", value: .integer(id.rawValue)), JSONObject.Entry(key: key, value: value)])))
    }

    private func seriesOptions(_ series: Int, _ key: String, _ value: JSON) {
        ctl.run("chart.options", .object(JSONObject([
            JSONObject.Entry(key: "id", value: .integer(id.rawValue)), JSONObject.Entry(key: "series", value: .integer(series)),
            JSONObject.Entry(key: key, value: value),
        ])))
    }
}
