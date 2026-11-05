// DCAppModel — a chart's elements: its title, legend, data labels and gridlines, as PowerPoint offers them in
// Chart Design › Add Chart Element and in the Format pane. deckcraft's engine sets them (`chart.options`), but
// its UI has no control for them, so these follow PowerPoint, not a deckcraft source. No AppKit: the inspector
// and the ribbon build their controls from these.
import CNCore
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
            .submenu(String(localized: "Gridlines", bundle: .module), gridlines(shape, chart)),
        ] + axisAndSeriesMenus(id, chart)
    }

    // MARK: - Axis titles, gridlines, error bars, trendlines, up/down bars (AB-T-0436)

    /// The text a new axis title starts with, as PowerPoint's placeholder reads.
    public static var defaultAxisTitle: String { String(localized: "Axis Title", bundle: .module, comment: "The text a new axis title starts with") }

    /// Whether the chart's horizontal axis is its value axis (a bar chart's), so "Primary Horizontal" means the
    /// value axis.
    static func valueAxisHorizontal(_ c: Chart) -> Bool { c.kind.horizontal }

    /// Gridlines on the value axis: major ones (deckcraft's switch) and minor ones, named by the axis's
    /// direction as PowerPoint names them.
    static func gridlines(_ shape: JSON, _ c: Chart) -> [CommandMenuEntry] {
        let v = valueAxisHorizontal(c)
        var out: [CommandMenuEntry] = [
            .item(String(localized: "None", bundle: .module, comment: "No gridlines on the chart"), "chart.options",
                  c.takesAxisSettings ? ["id": shape, "gridlines": false, "minorGridlines": false] : ["id": shape, "gridlines": false]),
            .item(v ? String(localized: "Primary Major Vertical", bundle: .module, comment: "Gridlines across a bar chart's value axis")
                    : String(localized: "Primary Major Horizontal", bundle: .module, comment: "Gridlines across the value axis"),
                  "chart.options", ["id": shape, "gridlines": true]),
        ]
        if c.takesAxisSettings {
            out.append(.item(v ? String(localized: "Primary Minor Vertical", bundle: .module, comment: "Minor gridlines across a bar chart's value axis")
                               : String(localized: "Primary Minor Horizontal", bundle: .module, comment: "Minor gridlines across the value axis"),
                             "chart.options", ["id": shape, "minorGridlines": true]))
        }
        return out
    }

    /// The trendlines Add Chart Element offers (PowerPoint's quick list), as `chart.options` trendlines.
    public static var trendlines: [(label: String, trendline: JSON)] {
        [
            (String(localized: "Linear", bundle: .module, comment: "A straight-line trendline"), ["type": "linear"]),
            (String(localized: "Exponential", bundle: .module, comment: "An exponential trendline"), ["type": "exp"]),
            (String(localized: "Linear Forecast", bundle: .module, comment: "A straight-line trendline continued two periods ahead"), ["type": "linear", "forward": 2]),
            (String(localized: "Moving Average", bundle: .module, comment: "A two-period moving-average trendline"), ["type": "movingAvg", "period": 2]),
        ]
    }

    /// The error bars Add Chart Element offers, as `chart.options` error bars.
    public static var errorBars: [(label: String, errorBars: JSON)] {
        [
            (String(localized: "Standard Error", bundle: .module, comment: "Error bars of the standard error"), ["type": "stdErr"]),
            (String(localized: "Percentage", bundle: .module, comment: "Error bars of 5 % of each value"), ["type": "percentage", "value": 5]),
            (String(localized: "Standard Deviation", bundle: .module, comment: "Error bars of one standard deviation"), ["type": "stdDev", "value": 1]),
        ]
    }

    // MARK: - The inspector's choices

    /// The trendlines the inspector's picker offers, (label, tag, `chart.options` trendline): Add Chart Element's
    /// four, then the other types the model has.
    public static var trendlineChoices: [(String, String, JSON)] {
        let tags = ["linear", "exp", "forecast", "movingAvg"]
        return zip(tags, trendlines).map { ($1.label, $0, $1.trendline) } + [
            (String(localized: "Logarithmic", bundle: .module, comment: "A logarithmic trendline"), "log", ["type": "log"]),
            (String(localized: "Polynomial", bundle: .module, comment: "A second-order polynomial trendline"), "poly", ["type": "poly", "order": 2]),
            (String(localized: "Power", bundle: .module, comment: "A power trendline"), "power", ["type": "power"]),
        ]
    }

    /// The inspector picker's tag for a series' first trendline; "" for none.
    public static func trendTag(_ s: Series) -> String {
        guard let t = s.trendlines.first else { return "" }
        if t.kind == .linear, (t.forward ?? 0) > 0 { return "forecast" }
        return t.kind.rawValue
    }

    /// Number formats the inspector offers for the value axis, (label, Excel code); "" follows the data's.
    public static var numberFormats: [(String, String)] {
        [
            (String(localized: "Follow Data", bundle: .module, comment: "An axis number format taken from the chart's data"), ""),
            (String(localized: "Number", bundle: .module, comment: "An axis number format: whole numbers"), "0"),
            (String(localized: "Number, 1 Decimal", bundle: .module, comment: "An axis number format: one decimal place"), "0.0"),
            (String(localized: "Thousands Separator", bundle: .module, comment: "An axis number format: #,##0"), "#,##0"),
            (String(localized: "Percentage", bundle: .module, comment: "An axis number format: 0%"), "0%"),
            (String(localized: "Currency", bundle: .module, comment: "An axis number format: $#,##0"), "$#,##0"),
            (String(localized: "Scientific", bundle: .module, comment: "An axis number format: 0.00E+00"), "0.00E+00"),
        ]
    }

    /// The value axis's own number format; "" when it follows the data (the reader gives the data's, often
    /// General).
    public static func ownFormat(_ c: Chart) -> String { c.yFormat.flatMap { $0 == "General" ? nil : $0 } ?? "" }

    /// Whether series `s` can take `trendline` as `chart.options` checks it: an exponential one needs
    /// every value above zero, a moving average more points than its period.
    public static func fits(_ trendline: JSON, _ c: Chart, _ s: Series) -> Bool {
        guard c.takesTrendline(s) else { return false }
        let vals = s.values.compactMap { $0 }
        switch trendline.get("type")?.asStr {
        case "exp": return !vals.isEmpty && vals.allSatisfy { $0 > 0 }
        case "movingAvg": return vals.count > Int(trendline.get("period")?.asU64 ?? 2)
        default: return vals.count >= 2
        }
    }

    /// A series' name for a menu: its own, else PowerPoint's "Series n".
    public static func seriesName(_ s: Series, _ i: Int) -> String {
        s.name.isEmpty ? String(localized: "Series \(i + 1)", bundle: .module, comment: "A chart series without a name") : s.name
    }

    static func axisAndSeriesMenus(_ id: ShapeId, _ c: Chart) -> [CommandMenuEntry] {
        let shape: JSON = .integer(id.rawValue)
        var out: [CommandMenuEntry] = []
        if c.takesAxisSettings {
            // "Primary Horizontal" is the category axis, or a bar chart's value axis.
            let (h, v) = valueAxisHorizontal(c) ? ("value", "category") : ("category", "value")
            func current(_ k: String) -> String? { k == "category" ? c.axisTitles.a : c.axisTitles.b }
            func add(_ k: String) -> JSON {
                let t: JSON = .string(current(k) ?? defaultAxisTitle)
                return ["id": shape, "axisTitles": k == "category" ? ["category": t] : ["value": t]]
            }
            out.append(.submenu(String(localized: "Axis Titles", bundle: .module, comment: "Add Chart Element › Axis Titles"), [
                .item(String(localized: "None", bundle: .module, comment: "No axis titles"), "chart.options", ["id": shape, "axisTitles": ["category": .null, "value": .null]]),
                .item(String(localized: "Primary Horizontal", bundle: .module, comment: "The chart's horizontal axis"), "chart.options", add(h)),
                .item(String(localized: "Primary Vertical", bundle: .module, comment: "The chart's vertical axis"), "chart.options", add(v)),
            ]))
        }
        if c.series.contains(where: c.takesErrorBars) {
            // On every series that can take them, as PowerPoint's quick choices do; one series in the inspector.
            out.append(.submenu(String(localized: "Error Bars", bundle: .module, comment: "Add Chart Element › Error Bars"),
                [.item(String(localized: "None", bundle: .module, comment: "No error bars"), "chart.options", ["id": shape, "errorBars": .null])]
                    + errorBars.map { .item($0.label, "chart.options", ["id": shape, "errorBars": $0.errorBars]) }))
        }
        if c.series.contains(where: c.takesTrendline) {
            // PowerPoint asks which series (O-23); here each trendline lists the series it fits.
            var items: [CommandMenuEntry] = [.item(String(localized: "None", bundle: .module, comment: "No trendlines"), "chart.options", ["id": shape, "trendline": .null])]
            for t in trendlines {
                let fit = c.series.indices.filter { fits(t.trendline, c, c.series[$0]) }
                let run = { (i: Int) -> CommandRef in CommandRef("chart.options", ["id": shape, "series": .integer(i), "trendline": t.trendline]) }
                if fit.count == 1, c.series.count == 1, let i = fit.first {
                    items.append(.item(t.label, run(i)))
                } else if !fit.isEmpty {
                    items.append(.submenu(t.label, fit.map { .item(seriesName(c.series[$0], $0), run($0)) }))
                }
            }
            out.append(.submenu(String(localized: "Trendline", bundle: .module, comment: "Add Chart Element › Trendline"), items))
        }
        if c.takesUpDownBars {
            out.append(.submenu(String(localized: "Up/Down Bars", bundle: .module, comment: "Add Chart Element › Up/Down Bars"), [
                .item(String(localized: "None", bundle: .module, comment: "No up/down bars"), "chart.options", ["id": shape, "upDownBars": false]),
                .item(String(localized: "Up/Down Bars", bundle: .module, comment: "Show the chart's up/down bars"), "chart.options", ["id": shape, "upDownBars": true]),
            ]))
        }
        return out
    }
}
