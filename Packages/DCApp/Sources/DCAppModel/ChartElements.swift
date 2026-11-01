// DCAppModel — a chart's elements: its title, legend, data labels and gridlines, as PowerPoint offers them in
// Chart Design › Add Chart Element and in the Format pane. deckcraft's engine sets them (`chart.options`), but
// its UI has no control for them, so these follow PowerPoint, not a deckcraft source. No AppKit: the inspector
// and the ribbon build their controls from these.
import DCCore
import DCEngine
import DCModel
import Foundation

public enum ChartElements {
    /// The legend's places, as `chart.options {legend}` codes; nil hides the legend.
    public static var legends: [(label: String, code: String?)] {
        [
            (String(localized: "None", bundle: .module, comment: "No legend on the chart"), nil),
            (String(localized: "Right", bundle: .module, comment: "Where a chart's legend is"), "r"),
            (String(localized: "Top", bundle: .module, comment: "Where a chart's legend is"), "t"),
            (String(localized: "Left", bundle: .module, comment: "Where a chart's legend is"), "l"),
            (String(localized: "Bottom", bundle: .module, comment: "Where a chart's legend is"), "b"),
        ]
    }

    /// The text a chart's title starts with when it is turned on, as PowerPoint's placeholder reads.
    public static var defaultTitle: String { String(localized: "Chart Title", bundle: .module, comment: "The text a new chart title starts with") }

    /// The selected chart: the first selected shape, when it is one.
    public static func selected(_ doc: DocState?) -> (ShapeId, Chart)? {
        guard let d = doc, let id = d.selection.shapes.first, let sh = d.shape(id), case .chart(let c) = sh.kind else { return nil }
        return (id, c)
    }

    /// Chart Design › Add Chart Element (`chart.options`) for the chart `id`.
    public static func menu(_ id: ShapeId, _ chart: Chart) -> [CommandMenuEntry] {
        let shape: JSON = .integer(id.rawValue)
        return [
            .submenu(String(localized: "Chart Title", bundle: .module, comment: "Add Chart Element › Chart Title"), [
                .item(String(localized: "None", bundle: .module, comment: "No chart title"), "chart.options", ["id": shape, "title": .null]),
                .item(String(localized: "Above Chart", bundle: .module, comment: "Where the chart title is"), "chart.options", ["id": shape, "title": .string(chart.title ?? defaultTitle)]),
            ]),
            .submenu(String(localized: "Legend", bundle: .module), legends.map { l in
                .item(l.label, "chart.options", ["id": shape, "legend": l.code.map(JSON.string) ?? .null])
            }),
            .submenu(String(localized: "Data Labels", bundle: .module), [
                .item(String(localized: "None", bundle: .module, comment: "No data labels on the chart"), "chart.options", ["id": shape, "dataLabels": false]),
                .item(String(localized: "Show", bundle: .module, comment: "Show the chart's data labels"), "chart.options", ["id": shape, "dataLabels": true]),
            ]),
            .submenu(String(localized: "Gridlines", bundle: .module), [
                .item(String(localized: "None", bundle: .module, comment: "No gridlines on the chart"), "chart.options", ["id": shape, "gridlines": false]),
                .item(String(localized: "Major Gridlines", bundle: .module), "chart.options", ["id": shape, "gridlines": true]),
            ]),
        ]
    }
}
