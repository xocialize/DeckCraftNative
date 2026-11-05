// DCApp — the chart inspector's Axes section: axis titles, minor gridlines, and the value axis's bounds, major
// unit, logarithmic scale and number format, plus reversed categories, as PowerPoint's Format Axis pane offers
// them. Each change is one `chart.options` step. The port's own (AB-T-0436): deckcraft's UI has none of these.
import CNCore
import DCAppModel
import DCEngine
import DCModel
import SwiftUI

struct ChartAxisSection: View {
    let ctl: InspectorController
    let id: ShapeId
    let chart: Chart

    var body: some View {
        let c = chart
        // "Horizontal" is the category axis, or a bar chart's value axis, as in PowerPoint.
        let valueHorizontal = c.kind.horizontal
        Section(String(localized: "Axes", bundle: .module, comment: "The chart inspector's section for its axes")) {
            axisTitle(String(localized: "Horizontal Axis Title", bundle: .module), key: valueHorizontal ? "value" : "category")
            axisTitle(String(localized: "Vertical Axis Title", bundle: .module), key: valueHorizontal ? "category" : "value")
            Toggle(String(localized: "Minor Gridlines", bundle: .module), isOn: Binding(get: { c.minorGridlines }, set: { run(["minorGridlines": .bool($0)]) }))
            OptionalNumberField(label: String(localized: "Minimum", bundle: .module, comment: "The value axis's lowest value"), value: c.yMin) { run(["axisMin": $0.map(JSON.double) ?? .null]) }
            OptionalNumberField(label: String(localized: "Maximum", bundle: .module, comment: "The value axis's highest value"), value: c.yMax) { run(["axisMax": $0.map(JSON.double) ?? .null]) }
            OptionalNumberField(label: String(localized: "Major Unit", bundle: .module, comment: "The step between the value axis's labels"), value: c.yMajor) { v in
                run(["majorUnit": v.flatMap { $0 > 0 ? JSON.double($0) : nil } ?? .null])
            }
            Toggle(String(localized: "Logarithmic Scale", bundle: .module), isOn: Binding(get: { c.yLogBase != nil }, set: { on in
                // A log axis starts above zero: a minimum at or below it goes back to automatic.
                var p: [(String, JSON)] = [("logBase", on ? .double(10) : .null)]
                if on, let lo = c.yMin, lo <= 0 { p.append(("axisMin", .null)) }
                run(p)
            }))
            if let base = c.yLogBase {
                NumberField(label: String(localized: "Base", bundle: .module, comment: "A logarithmic axis's base"), value: base, range: 2 ... 1000) { run(["logBase": .double($0)]) }
            }
            ChoicePicker(label: String(localized: "Number Format", bundle: .module), options: ChartElements.numberFormats, current: format) {
                run(["numberFormat": $0.isEmpty ? .null : .string($0)])
            }
            ChartTitleField(text: format, label: String(localized: "Format Code", bundle: .module, comment: "An Excel number format code typed by hand")) {
                run(["numberFormat": $0.isEmpty ? .null : .string($0)])
            }
            Toggle(String(localized: "Categories in Reverse Order", bundle: .module), isOn: Binding(get: { c.catReversed }, set: { run(["reverseCategories": .bool($0)]) }))
        }
    }

    /// The value axis's own number format; "" when it follows the data (the reader gives the data's, often
    /// General).
    private var format: String { ChartElements.ownFormat(chart) }

    /// A toggle for one axis's title and, while it has one, its text.
    @ViewBuilder private func axisTitle(_ label: String, key: String) -> some View {
        let text = key == "category" ? chart.axisTitles.a : chart.axisTitles.b
        Toggle(label, isOn: Binding(get: { text != nil }, set: { on in
            run(["axisTitles": key == "category" ? ["category": on ? .string(text ?? ChartElements.defaultAxisTitle) : .null]
                                                   : ["value": on ? .string(text ?? ChartElements.defaultAxisTitle) : .null]])
        }))
        if let text {
            // Labelled "Title" as the chart title's field is; the switch above names the axis.
            ChartTitleField(text: text) { t in
                let v: JSON = t.isEmpty ? .null : .string(t)
                run(["axisTitles": key == "category" ? ["category": v] : ["value": v]])
            }
        }
    }

    private func run(_ p: KeyValuePairs<String, JSON>) { run(p.map { ($0.key, $0.value) }) }

    /// One `chart.options` step on this chart.
    private func run(_ p: [(String, JSON)]) {
        let entries = [JSONObject.Entry(key: "id", value: .integer(id.rawValue))] + p.map { JSONObject.Entry(key: $0.0, value: $0.1) }
        _ = ctl.run("chart.options", .object(JSONObject(entries)))
    }
}
