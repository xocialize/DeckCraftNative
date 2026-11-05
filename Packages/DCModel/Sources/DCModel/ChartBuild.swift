// DCModel — chart builds: a chart animated one series, category or point at a time (PowerPoint's Effect
// Options › Sequence, `p:bldGraphic` with `a:bldChart`). DeckCraftNative's own (AB-T-0443): deckcraft animates
// a chart as one object. The reader, the writer and the timeline share the step list below, so a build reads
// back, saves and plays the same way.

/// Most steps one chart build animates separately (a large chart by element would otherwise be thousands of
/// effects); a build that would need more plays as one object.
public let maxChartBuildSteps = 1_000

extension ChartBuild {
    /// `a:bldChart bld`.
    public var fileValue: String {
        switch self {
        case .bySeries: "series"
        case .byCategory: "category"
        case .bySeriesElement: "seriesEl"
        case .byCategoryElement: "categoryEl"
        }
    }

    /// The build an `a:bldChart bld` names; nil for `allAtOnce` and anything unknown.
    public static func fromFile(_ s: String?) -> ChartBuild? {
        switch s {
        case "series"?: .bySeries
        case "category"?: .byCategory
        case "seriesEl"?: .bySeriesElement
        case "categoryEl"?: .byCategoryElement
        default: nil
        }
    }

    /// Effect Options › Sequence, as PowerPoint names it.
    public var label: String {
        switch self {
        case .bySeries: "By Series"
        case .byCategory: "By Category"
        case .bySeriesElement: "By Element in Series"
        case .byCategoryElement: "By Element in Category"
        }
    }

    /// The build whose steps are of this kind (a background step belongs to every build).
    public static func of(_ step: ChartStep) -> ChartBuild? {
        switch step {
        case .background: nil
        case .series: .bySeries
        case .category: .byCategory
        case .seriesPoint: .bySeriesElement
        case .categoryPoint: .byCategoryElement
        }
    }
}

extension ChartStep {
    /// `a:chart bldStep`.
    public var fileValue: String {
        switch self {
        case .background: "gridLegend"
        case .series: "series"
        case .category: "category"
        case .seriesPoint: "ptInSeries"
        case .categoryPoint: "ptInCategory"
        }
    }

    public static func fromFile(_ s: String?) -> ChartStep? {
        switch s {
        case "gridLegend"?: .background
        case "series"?: .series
        case "category"?: .category
        case "ptInSeries"?: .seriesPoint
        case "ptInCategory"?: .categoryPoint
        default: nil
        }
    }
}

extension ChartElement {
    /// `a:chart seriesIdx` and `categoryIdx` as PowerPoint writes them: -3 for both on the background step, -4 for
    /// the index a series or category step doesn't name.
    public var fileIndices: (Int64, Int64) {
        switch step {
        case .background: (-3, -3)
        case .series: (Int64(series), -4)
        case .category: (-4, Int64(category))
        case .seriesPoint, .categoryPoint: (Int64(series), Int64(category))
        }
    }

    /// The element an `a:chart` names; nil when its step is unknown or an index it needs is missing or negative.
    public static func fromFile(step: String?, series: Int64?, category: Int64?) -> ChartElement? {
        guard let st = ChartStep.fromFile(step) else { return nil }
        func idx(_ v: Int64?) -> UInt32? { v.flatMap { UInt32(exactly: $0) } }
        switch st {
        case .background:
            return ChartElement(step: st)
        case .series:
            return idx(series).map { ChartElement(step: st, series: $0) }
        case .category:
            return idx(category).map { ChartElement(step: st, category: $0) }
        case .seriesPoint, .categoryPoint:
            guard let s = idx(series), let c = idx(category) else { return nil }
            return ChartElement(step: st, series: s, category: c)
        }
    }

    /// Does this element animate point (`series`, `category`) of the data?
    public func covers(series s: Int, category c: Int) -> Bool {
        switch step {
        case .background: false
        case .series: Int(series) == s
        case .category: Int(category) == c
        case .seriesPoint, .categoryPoint: Int(series) == s && Int(category) == c
        }
    }
}

extension Chart {
    /// Points per series as a chart build counts them: the categories, or the longest series when it is longer.
    public var buildPointCount: Int {
        Swift.max(categories.count, series.map(\.values.count).max() ?? 0)
    }
}

/// The steps a chart build plays, in order: the background unless it is left out, then each series, category or
/// point (points series by series for a by-element-in-series build, category by category for the other). Empty
/// when the chart has no data or the build would need more than `maxChartBuildSteps`.
public func chartBuildSteps(_ chart: Chart, _ build: ChartBuild, background: Bool) -> [ChartElement] {
    let ns = chart.series.count
    let nc = chart.buildPointCount
    let data: Int
    switch build {
    case .bySeries: data = ns
    case .byCategory: data = nc
    case .bySeriesElement, .byCategoryElement:
        let (p, o) = ns.multipliedReportingOverflow(by: nc)
        data = o ? Int.max : p
    }
    if ns == 0 || nc == 0 || data >= maxChartBuildSteps { return [] }
    var out: [ChartElement] = background ? [ChartElement(step: .background)] : []
    out.reserveCapacity(data + 1)
    func u(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: i) }
    switch build {
    case .bySeries:
        for s in 0 ..< ns { out.append(ChartElement(step: .series, series: u(s))) }
    case .byCategory:
        for c in 0 ..< nc { out.append(ChartElement(step: .category, category: u(c))) }
    case .bySeriesElement:
        for s in 0 ..< ns { for c in 0 ..< nc { out.append(ChartElement(step: .seriesPoint, series: u(s), category: u(c))) } }
    case .byCategoryElement:
        for c in 0 ..< nc { for s in 0 ..< ns { out.append(ChartElement(step: .categoryPoint, series: u(s), category: u(c))) } }
    }
    return out
}

extension Chart {
    /// Does the port play this chart's builds part by part? Kinds the renderer draws by their own code (pie
    /// charts excepted: Office 2016 charts, radar, stock, box and whisker, histogram, Pareto, waterfall) play one
    /// as one object. A build read from a file is kept on any chart; this decides what the app offers.
    public var playsBuildByParts: Bool {
        switch kind {
        case .histogram, .pareto, .boxWhisker, .stock, .radar, .filledRadar, .funnel, .treemap, .sunburst, .regionMap, .waterfall: false
        default: true
        }
    }

    /// Can `animation.options` give an animation on this chart `build`? Only where it plays part by part and
    /// has steps: data, and no more than `maxChartBuildSteps` of them.
    public func takesBuild(_ build: ChartBuild) -> Bool {
        playsBuildByParts && !chartBuildSteps(self, build, background: false).isEmpty
    }
}
