// DCModel — charts: an embedded data grid plus type and element options, the value axes' scales and
// labels, and the Office 2016 chart types' derived views (histogram bins, box statistics, category
// trees). Port of deckcraft crates/model/src/chart.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCColor
import DCCore
import Foundation

extension ChartType {
    public static let office2016: [ChartType] = [.waterfall, .funnel, .histogram, .pareto, .boxWhisker, .treemap, .sunburst]

    public var isChartex: Bool { ChartType.office2016.contains(self) || self == .regionMap }

    public static let main: [ChartType] = [
        .column, .bar, .line, .area, .pie, .doughnut, .scatter, .radar, .waterfall, .funnel, .histogram, .treemap,
    ]

    public var label: String {
        switch self {
        case .column: "Clustered Column"
        case .stackedColumn: "Stacked Column"
        case .percentColumn: "100% Stacked Column"
        case .bar: "Clustered Bar"
        case .stackedBar: "Stacked Bar"
        case .percentBar: "100% Stacked Bar"
        case .line: "Line"
        case .lineMarkers: "Line with Markers"
        case .stackedLine: "Stacked Line"
        case .area: "Area"
        case .stackedArea: "Stacked Area"
        case .pie: "Pie"
        case .doughnut: "Doughnut"
        case .scatter: "Scatter"
        case .bubble: "Bubble"
        case .radar: "Radar"
        case .filledRadar: "Filled Radar"
        case .stock: "Stock"
        case .surface: "Surface"
        case .histogram: "Histogram"
        case .pareto: "Pareto"
        case .boxWhisker: "Box and Whisker"
        case .waterfall: "Waterfall"
        case .funnel: "Funnel"
        case .treemap: "Treemap"
        case .sunburst: "Sunburst"
        case .regionMap: "Map"
        case .combo: "Combo"
        }
    }

    public var isBarLike: Bool {
        [.column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .histogram, .pareto, .waterfall].contains(self)
    }

    public var horizontal: Bool { [.bar, .stackedBar, .percentBar, .funnel].contains(self) }

    public var stacked: Bool {
        [.stackedColumn, .stackedBar, .stackedLine, .stackedArea, .percentColumn, .percentBar].contains(self)
    }

    public var percent: Bool { self == .percentColumn || self == .percentBar }
}

extension TrendlineType {
    /// The OOXML name, which is also the serialised name.
    public var xml: String { rawValue }

    public static func fromXML(_ s: String) -> TrendlineType? { TrendlineType(rawValue: s) }
}

extension Trendline {
    public static var `default`: Trendline {
        Trendline(kind: .linear, name: nil, order: nil, period: nil, forward: nil, backward: nil, intercept: nil, dispEq: false, dispRSqr: false)
    }
}

extension ErrorBars {
    public static var `default`: ErrorBars {
        ErrorBars(barType: "both", valType: "fixedVal", value: 1.0, plus: [], minus: [], endCap: true)
    }

    public func range(_ values: [Double?], _ i: Int, _ v: Double) -> (Double, Double)? {
        rangeIn(SeriesStats.of(values), i, v)
    }

    public func rangeIn(_ stats: SeriesStats, _ i: Int, _ v: Double) -> (Double, Double)? {
        let (n, mean, sd) = (stats.n, stats.mean, stats.sd)
        let centre: Double
        let minus: Double
        let plus: Double
        switch valType {
        case "percentage":
            (centre, minus, plus) = (v, Swift.abs(v * value / 100.0), Swift.abs(v * value / 100.0))
        case "stdDev":
            (centre, minus, plus) = (mean, sd * value, sd * value)
        case "stdErr":
            (centre, minus, plus) = (v, sd / n.rustMax(1.0).squareRoot(), sd / n.rustMax(1.0).squareRoot())
        case "cust":
            (centre, minus, plus) = (v, (self.minus.at(i) ?? nil) ?? 0.0, (self.plus.at(i) ?? nil) ?? 0.0)
        default:
            (centre, minus, plus) = (v, value, value)
        }
        let lo: Double
        let hi: Double
        switch barType {
        case "plus": (lo, hi) = (centre, centre + plus)
        case "minus": (lo, hi) = (centre - minus, centre)
        default: (lo, hi) = (centre - minus, centre + plus)
        }
        return lo.isFinite && hi.isFinite ? (lo, hi) : nil
    }
}

/// Count, mean and sample standard deviation of a series' finite values (error bars use them).
public struct SeriesStats: Sendable, Equatable {
    public var n: Double = 0
    public var mean: Double = 0
    public var sd: Double = 0

    public init(n: Double = 0, mean: Double = 0, sd: Double = 0) {
        self.n = n
        self.mean = mean
        self.sd = sd
    }

    public static func of(_ values: [Double?]) -> SeriesStats {
        let vals = values.compactMap { $0 }.filter(\.isFinite)
        let n = Double(vals.count)
        let mean = rsSum(vals) / n.rustMax(1.0)
        let sd = n > 1.0 ? (rsSum(vals.map { ($0 - mean) * ($0 - mean) }) / (n - 1.0)).squareRoot() : 0.0
        return SeriesStats(n: n, mean: mean, sd: sd)
    }
}

extension ChartKept {
    public var isEmpty: Bool { rels.isEmpty && parts.isEmpty }
}

extension Chart {
    public static var `default`: Chart {
        Chart(
            kind: .column, title: "Chart Title", categories: [], series: [], legend: "b", legendOverlay: false,
            textSize: nil, titleSize: nil, dataLabels: false, gridlines: true, minorGridlines: false,
            axisTitles: Pair(nil, nil), style: 2, palette: "colorful1", plotFill: nil, chartFill: nil, textColor: nil,
            holeSize: 0.5, gapWidth: 2.19, overlap: -0.27, varyColors: false, yMin: nil, yMax: nil, yMajor: nil,
            yLogBase: nil, yFormat: nil, yHidden: false, catReversed: false, y2Min: nil, y2Max: nil, y2Major: nil,
            y2Format: nil, y2Hidden: false, lang: nil, subtotals: [], categoryLevels: [], inclusiveQuartiles: false,
            upDownBars: false, binCount: nil, binSize: nil, raw: nil, kept: ChartKept()
        )
    }

    private static func sampleTreemapSunburst(_ kind: ChartType) -> Chart {
        var c = Chart.default
        c.kind = kind
        c.categories = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug"]
        c.categoryLevels = [["Q1", "Q1", "Q1", "Q2", "Q2", "Q2", "Q3", "Q3"]]
        c.varyColors = true
        let v = [4.2, 2.8, 3.6, 4.7, 2.6, 4.1, 1.9, 3.0]
        c.series.append(Series(name: "Series 1", values: v.map { $0 }))
        return c
    }

    private static func sampleObservationChart(_ kind: ChartType) -> Chart {
        let obs = [12.0, 15.0, 17.0, 18.0, 21.0, 22.0, 22.0, 24.0, 25.0, 27.0, 28.0, 31.0, 33.0, 36.0, 41.0, 48.0]
        let nSeries = kind == .boxWhisker ? 2 : 1
        var c = Chart.default
        c.kind = kind
        c.categories = kind == .boxWhisker ? obs.indices.map { $0 % 2 == 0 ? "Group A" : "Group B" } : []
        c.gridlines = true
        c.legend = kind == .boxWhisker ? "b" : nil
        for s in 0 ..< nSeries {
            c.series.append(Series(name: "Series \(s + 1)", values: obs.map { $0 + Double(s) * 6.0 }))
        }
        return c
    }

    private static func sampleStock() -> Chart {
        var c = Chart.default
        c.kind = .stock
        c.categories = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let hlc: [(String, [Double])] = [
            ("High", [55.0, 57.0, 57.0, 58.0, 58.0]), ("Low", [11.0, 12.0, 13.0, 11.0, 25.0]),
            ("Close", [25.0, 38.0, 50.0, 35.0, 43.0]),
        ]
        for (name, v) in hlc {
            c.series.append(Series(name: name, values: v.map { $0 }))
        }
        return c
    }

    /// The sample data a new chart starts with (deckcraft's own numbers).
    public static func sample(_ kind: ChartType) -> Chart {
        if kind == .treemap || kind == .sunburst { return sampleTreemapSunburst(kind) }
        if [.histogram, .pareto, .boxWhisker].contains(kind) { return sampleObservationChart(kind) }
        if kind == .stock { return sampleStock() }
        let cats = ["Q1", "Q2", "Q3", "Q4"]
        let data: [[Double]] = [[4.2, 2.6, 2.1], [2.8, 4.1, 2.4], [3.6, 1.9, 3.3], [4.7, 3.0, 5.1]]
        var c = Chart.default
        c.kind = kind
        c.categories = cats
        let nSeries = [.pie, .doughnut, .funnel, .waterfall, .treemap].contains(kind) ? 1 : 3
        for s in 0 ..< nSeries {
            c.series.append(Series(
                name: "Series \(s + 1)",
                values: data.map { $0.at(s) },
                xValues: kind == .scatter ? (1 ... 4).map { Double($0) } : []
            ))
        }
        c.varyColors = nSeries == 1
        if kind == .combo {
            // Columns with the last series as a line, as PowerPoint's combo starts.
            for i in c.series.indices {
                c.series[i].kind = i + 1 == nSeries ? .line : .column
            }
        }
        return c
    }

    /// A series' own chart type: its own in a combo chart (columns when it names none), else the
    /// chart's.
    public func seriesKind(_ s: Series) -> ChartType {
        if kind == .combo {
            if let k = s.kind, k != .combo { return k }
            return .column
        }
        return kind
    }

    /// Whether a series is plotted against the secondary value axis (combo charts only).
    public func onSecondary(_ s: Series) -> Bool {
        kind == .combo && s.secondaryAxis
    }

    /// The value range of one value axis: the primary axis (`yMin`/`yMax` apply), or a combo chart's
    /// secondary axis. A combo chart stacks only its stacked series. nil when no series uses that axis.
    public func axisRange(_ secondary: Bool) -> (Double, Double)? {
        if kind != .combo { return secondary ? nil : valueRange() }
        guard let (lo0, hi0) = plottedExtent(secondary) else { return nil }
        let (lo, hi) = (lo0.rustMin(0.0), hi0.rustMax(0.0))
        return secondary ? (lo, hi) : (yMin ?? lo, yMax ?? hi)
    }

    /// The smallest and largest value plotted against one value axis: plain values as they are,
    /// stacked series as running sums from zero, 100 % series as 0–1. (0, 0) without finite values;
    /// nil when no series uses the axis.
    private func plottedExtent(_ secondary: Bool) -> (Double, Double)? {
        if kind == .waterfall { return secondary ? nil : valueRange() }
        let ser = series.filter { onSecondary($0) == secondary }
        if ser.isEmpty { return !secondary && kind != .combo ? (0.0, 0.0) : nil }
        var ext = (Double.infinity, -Double.infinity)
        let hasStackedOrPercent = ser.contains { s in
            let k = seriesKind(s)
            return k.stacked || k.percent
        }
        let percent: Bool
        if hasStackedOrPercent {
            percent = foldStacked(ser, &ext)
        } else {
            for s in ser {
                for v in s.values.compactMap({ $0 }) where v.isFinite { widen(&ext, v) }
            }
            percent = false
        }
        if !percent { foldTrendlines(ser, &ext) }
        if percent {
            ext.0 = ext.0.rustMin(0.0)
            ext.1 = ext.1.rustMax(1.0)
        }
        let (lo, hi) = ext
        return lo <= hi ? (lo, hi) : (0.0, 0.0)
    }

    /// Widens `ext` by the points of the stacked and 100 % series in `ser`; returns whether a 100 %
    /// series is among them.
    private func foldStacked(_ ser: [Series], _ ext: inout (Double, Double)) -> Bool {
        var percent = false
        let n = ser.map(\.values.count).max() ?? 0
        let (product, overflow) = ser.count.multipliedReportingOverflow(by: n)
        let budget = Swift.min(overflow ? Int.max : product, 10_000_000)
        let nClamped = ser.isEmpty ? 0 : Swift.min(n, budget / ser.count)
        for i in 0 ..< nClamped {
            var p = 0.0
            var m = 0.0
            var stacked = false
            for s in ser {
                let k = seriesKind(s)
                guard let v = s.values.at(i) ?? nil, v.isFinite else { continue }
                if k.percent {
                    percent = true
                } else if k.stacked {
                    stacked = true
                    if v >= 0.0 { p += v } else { m += v }
                } else {
                    widen(&ext, v)
                }
            }
            if stacked {
                ext.1 = ext.1.rustMax(p)
                ext.0 = ext.0.rustMin(m)
            }
        }
        return percent
    }

    /// Widens `ext` by the trendlines of the series in `ser` that are not stacked.
    private func foldTrendlines(_ ser: [Series], _ ext: inout (Double, Double)) {
        for s in ser where !seriesKind(s).stacked {
            for y in s.trendlineYs(seriesIsScatter(seriesKind(s))) { widen(&ext, y) }
        }
    }

    /// A waterfall's bars as (from, to) on the value axis: each point floats from the running total, a
    /// total point stands on zero and sets it.
    public func waterfallBars() -> [(Double, Double)] {
        guard let s = series.first else { return [] }
        var run = 0.0
        return s.values.enumerated().map { i, v in
            let v = v ?? 0.0
            if subtotals.contains(i) {
                run = v
                return (0.0, v)
            }
            let from = run
            run += v
            return (from, run)
        }
    }

    /// A value axis' scale — (min, max, major unit) — with at most `maxIntervals` intervals: the bounds
    /// and unit the chart fixes, else Office's automatic ones (`axisScale(_:_:_:_:_:_:_:)`). nil when no
    /// series uses the axis.
    public func axisScale(_ secondary: Bool, _ maxIntervals: Int) -> (Double, Double, Double)? {
        guard let (lo, hi) = plottedExtent(secondary) else { return nil }
        let (fmin, fmax, major) = secondary ? (y2Min, y2Max, y2Major) : (yMin, yMax, yMajor)
        let fullPercent = !secondary && kind.percent
        return DCModel.axisScale(lo, hi, fmin, fmax, major, maxIntervals, !fullPercent)
    }

    /// A logarithmic value axis' scale in exponents — (min, max, unit), so its labels are `base^min`,
    /// `base^(min+unit)`… — covering the positive values: whole powers, as PowerPoint and LibreOffice
    /// draw them. nil when the axis isn't logarithmic or nothing is positive.
    public func logAxisScale(_ maxIntervals: Int) -> (Double, Double, Double)? {
        guard let b = yLogBase, b.isFinite, b >= 2.0 else { return nil }
        var range: (Double, Double)?
        for s in series where !onSecondary(s) {
            for v in s.values.compactMap({ $0 }) where v.isFinite && v > 0.0 {
                range = range.map { ($0.0.rustMin(v), $0.1.rustMax(v)) } ?? (v, v)
            }
        }
        guard let (lo0, hi0) = range else { return nil }
        // Rust's `f64::log(self, base)`.
        func e(_ v: Double) -> Double { Foundation.log(v) / Foundation.log(b) }
        let lo = yMin.flatMap { $0 > 0.0 ? e($0) : nil } ?? e(lo0).rounded(.down)
        let hi = (yMax.flatMap { $0 > 0.0 ? e($0) : nil } ?? e(hi0).rounded(.up)).rustMax(lo + 1.0)
        let unit = ((hi - lo) / Double(Swift.max(maxIntervals, 1))).rounded(.up).rustMax(1.0)
        return (lo, lo + ((hi - lo) / unit).rounded(.up) * unit, unit)
    }

    /// A value axis label in the axis' number format and the chart's language.
    public func axisLabel(_ secondary: Bool, _ v: Double) -> String {
        let code = secondary ? y2Format : yFormat
        // A 100 % stacked chart's value axis counts in percent unless the file says otherwise.
        let fmt: String
        if (code == nil || code == "General") && !secondary && kind.percent {
            fmt = "0%"
        } else {
            fmt = code ?? "General"
        }
        return NumFmt.format(fmt, v, lang)
    }

    /// A data label of series `s`: its number format, else its axis', in the chart's language.
    public func dataLabel(_ s: Series, _ v: Double) -> String {
        let axis = onSecondary(s) ? y2Format : yFormat
        return NumFmt.format(s.numberFormat ?? axis ?? "General", v, lang)
    }

    /// Does series `s` show its data labels? The series' own `c:dLbls/c:showVal` wins — an explicit
    /// false hides them even when the chart-wide setting is on (#868).
    public func seriesDataLabels(_ s: Series) -> Bool {
        s.dataLabels ?? dataLabels
    }

    private func waterfallValueRange() -> (Double, Double) {
        var lo = 0.0
        var hi = 0.0
        for (a, b) in waterfallBars() {
            lo = lo.rustMin(a.rustMin(b))
            hi = hi.rustMax(a.rustMax(b))
        }
        return (lo, hi)
    }

    private func stackedValueRange(_ n: Int) -> (Double, Double) {
        var lo = 0.0
        var hi = 0.0
        for i in 0 ..< n {
            var p = 0.0
            var m = 0.0
            for s in series {
                let v = (s.values.at(i) ?? nil) ?? 0.0
                if v >= 0.0 { p += v } else { m += v }
            }
            hi = hi.rustMax(p)
            lo = lo.rustMin(m)
        }
        return (lo, hi)
    }

    /// Value range across series (stacked sums for stacked types).
    public func valueRange() -> (Double, Double) {
        if kind == .waterfall { return waterfallValueRange() }
        let n = Swift.max(categories.count, series.map(\.values.count).max() ?? 0)
        var lo: Double
        var hi: Double
        if kind.stacked {
            (lo, hi) = stackedValueRange(n)
        } else {
            var l = 0.0
            var h = 0.0
            for s in series {
                for v in s.values.compactMap({ $0 }) where v.isFinite {
                    h = h.rustMax(v)
                    l = l.rustMin(v)
                }
            }
            (lo, hi) = (l, h)
        }
        if kind.percent { return (0.0, 1.0) }
        if !kind.stacked {
            for s in series {
                for y in s.trendlineYs(seriesIsScatter(seriesKind(s))) {
                    hi = hi.rustMax(y)
                    lo = lo.rustMin(y)
                }
            }
        }
        return (yMin ?? lo, yMax ?? hi)
    }
}

/// The data range [lo, hi] an axis covers, clamped to ±1e100; (0, 1) without finite values.
private func axisDataRange(_ lo: Double, _ hi: Double) -> (Double, Double) {
    if lo.isFinite && hi.isFinite {
        return (lo.rustMin(hi).clamped(-1e100, 1e100), lo.rustMax(hi).clamped(-1e100, 1e100))
    }
    return (0.0, 1.0)
}

/// Office's automatic (min, max) of the data range [lo, hi]. "How chart axis limits are determined", as
/// Jon Peltier summarises it: 5 % of the data range past the data, and zero when the values don't sit
/// within the top sixth of their largest magnitude. A single value is measured from zero.
private func autoLimits(_ lo: Double, _ hi: Double, _ headroom: Bool) -> (Double, Double) {
    let flat = hi - lo <= 1e-12 * Swift.abs(lo).rustMax(Swift.abs(hi))
    let pad = !headroom ? 0.0 : (flat ? Swift.abs(hi) / 20.0 : (hi - lo) / 20.0)
    let autoLo = lo >= 0.0 && (flat || lo < hi * 5.0 / 6.0) ? 0.0 : lo - pad
    let autoHi = hi <= 0.0 && (flat || hi > lo * 5.0 / 6.0) ? 0.0 : hi + pad
    return (autoLo, autoHi)
}

/// The ends of a span too small to show: with one fixed limit on the far side of the data, the
/// automatic end gives way; otherwise the span is one `unit` wide.
private func flatSpanEnds(_ fmin: Double?, _ fmax: Double?, _ lo: Double, _ hi: Double, _ unit: Double) -> (Double, Double) {
    switch (fmin, fmax) {
    case (nil, .some):
        return (hi > 0.0 ? 0.0 : hi - Swift.abs(hi).rustMax(unit), hi)
    case (.some, nil) where lo < 0.0:
        return (lo, 0.0)
    default:
        return (lo, lo + unit)
    }
}

/// The major step: `major` when it gives at most 1000 intervals, else the smallest 1-2-5 step that fits
/// `n` intervals over [lo, hi].
private func axisStep(_ major: Double?, _ lo: Double, _ hi: Double, _ n: Double, _ unit: Double) -> Double {
    if let m = major, m > 0.0, (hi - lo) / m <= 1000.0 { return m }
    var step = pow(10.0, log10((hi - lo) / n).rounded(.down))
    // Subnormal spans underflow to a zero (or non-finite) step: fall back to the unit.
    if !(step > 0.0 && step.isFinite) { step = unit }
    var k = 0
    // 1, 2, 5, 10, 20… × the magnitude until the intervals fit.
    while ((hi / step).rounded(.up) - (lo / step).rounded(.down)) > n && k < 30 {
        step *= k % 3 == 1 ? 2.5 : 2.0
        k += 1
    }
    return step
}

/// The (min, max, major unit) of an axis over the data range [lo, hi]: `fmin`/`fmax`/`major` where the
/// chart fixes them; otherwise Office's automatic limits, rounded out to the smallest 1-2-5 unit giving
/// at most `maxIntervals` intervals:
///
/// - **Maximum:** `hi + (hi − lo)/20` (with `headroom`), rounded up to the unit.
/// - **Minimum:** zero when every value is ≥ 0 and `lo` is below 5/6 of `hi`; otherwise
///   `lo − (hi − lo)/20`, rounded down to the unit, so values bunched high get an axis that starts
///   near them.
/// - All-negative values mirror this: the axis ends at zero when `hi` is above 5/6 of `lo`. Mixed signs
///   get headroom at both ends.
public func axisScale(
    _ lo: Double, _ hi: Double, _ fmin: Double?, _ fmax: Double?, _ major: Double?, _ maxIntervals: Int, _ headroom: Bool
) -> (Double, Double, Double) {
    // Values past ±1e100 aren't axis values; clamping keeps the arithmetic finite.
    func fin(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0.clamped(-1e100, 1e100) : nil } }
    let (fmin, fmax) = (fin(fmin), fin(fmax))
    let (dlo, dhi) = axisDataRange(lo, hi)
    let (autoLo, autoHi) = autoLimits(dlo, dhi, headroom)
    var (lo, hi) = (fmin ?? autoLo, fmax ?? autoHi)
    let mag = Swift.abs(lo).rustMax(Swift.abs(hi))
    // Relative to the data's magnitude, so tiny values don't count as flat; all-zero falls back to 1.
    let unit = mag == 0.0 ? 1.0 : mag
    if hi - lo <= 1e-12 * mag {
        (lo, hi) = flatSpanEnds(fmin, fmax, lo, hi, unit)
    }
    let n = Double(Swift.min(Swift.max(maxIntervals, 1), 50))
    let step = axisStep(fin(major), lo, hi, n, unit)
    let min = fmin ?? ((lo / step + 1e-9).rounded(.down) * step)
    let max = (fmax ?? ((hi / step - 1e-9).rounded(.up) * step)).rustMax(min + step)
    return (min, max, step)
}

/// "Nice" axis scale: (min, max, major step) covering [lo, hi].
public func niceScale(_ lo: Double, _ hi: Double) -> (Double, Double, Double) {
    let (lo, hi) = lo.isFinite && hi.isFinite ? (lo.rustMin(hi), lo.rustMax(hi)) : (0.0, 1.0)
    let dataMag = Swift.abs(lo).rustMax(Swift.abs(hi))
    var span = hi - lo <= 1e-12 * dataMag ? dataMag : hi - lo
    if span == 0.0 { span = 1.0 }
    let raw = span / 5.0
    let mag = pow(10.0, log10(raw).rounded(.down))
    let norm = raw / mag
    let factor: Double
    if norm <= 1.0 {
        factor = 1.0
    } else if norm <= 2.0 {
        factor = 2.0
    } else if norm <= 2.5 {
        factor = 2.5
    } else if norm <= 5.0 {
        factor = 5.0
    } else {
        factor = 10.0
    }
    var step = factor * mag
    // Subnormal spans underflow to a zero or NaN step: use the span itself.
    if !(step > 0.0 && step.isFinite) { step = span }
    let min = (lo / step).rounded(.down) * step
    var max = (hi / step).rounded(.up) * step
    if Swift.abs(max - min) <= 1e-12 * dataMag { max = min + step }
    return (min, max, step)
}

// MARK: - Office 2016 chart types

/// One histogram bin: `[lo, hi]` (the first bin is closed on both sides, later ones open on the left,
/// as Excel bins) and how many observations fall in it.
public struct Bin: Sendable, Equatable {
    public var lo: Double
    public var hi: Double
    public var count: Int

    public init(lo: Double, hi: Double, count: Int) {
        self.lo = lo
        self.hi = hi
        self.count = count
    }
}

/// Bins a histogram has at most (a hostile bin size cannot make millions).
public let maxBins = 1000

/// A box and whisker summary of one group: quartiles by Excel's exclusive method, whiskers at the
/// furthest points within 1.5 IQR of the box, and the points beyond them.
public struct BoxStats: Sendable, Equatable {
    public var low: Double
    public var q1: Double
    public var median: Double
    public var q3: Double
    public var high: Double
    public var mean: Double
    public var outliers: [Double]
}

extension Chart {
    /// The first series' finite observations.
    private func observations() -> [Double] {
        series.first.map { $0.values.compactMap { $0 }.filter(\.isFinite) } ?? []
    }

    /// The histogram's bins over the first series: by `binSize`, else `binCount`, else Scott's rule
    /// (3.49·σ·n^(-1/3)). Empty without observations.
    public func histogramBins() -> [Bin] {
        let v = rsStableSorted(observations(), by: rsTotalLess)
        guard let lo = v.first, let hi = v.last else { return [] }
        let span = hi - lo
        let n = Double(v.count)
        let validSize = binSize.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil }
        let validCount = binCount.flatMap { $0 > 0 ? $0 : nil }
        var width: Double
        if let w = validSize {
            width = w
        } else if let k = validCount {
            width = span / Double(k)
        } else {
            let mean = rsSum(v) / n
            let sd = (rsSum(v.map { ($0 - mean) * ($0 - mean) }) / (n - 1.0).rustMax(1.0)).squareRoot()
            width = 3.49 * sd / cbrt(n)
        }
        let fixed = validSize == nil ? validCount : nil
        let count: Int
        if span <= 0.0 || !width.isFinite || width <= 0.0 {
            count = 1
        } else if let k = fixed {
            count = Swift.min(Swift.max(Int(k), 1), maxBins)
        } else {
            count = Swift.min(Swift.max(Int(rustCast: (span / width).rounded(.up)), 1), maxBins)
        }
        if count == 1 && (span <= 0.0 || !width.isFinite || width <= 0.0) {
            width = span.rustMax(1.0)
        } else {
            width = width.rustMax(span / Double(maxBins))
        }
        var bins = (0 ..< count).map { i in Bin(lo: lo + width * Double(i), hi: lo + width * Double(i + 1), count: 0) }
        for x in v {
            // (lo, hi] bins, the first one also holding the minimum.
            let raw = Int(rustCast: ((x - lo) / width).rounded(.up))
            let i = Swift.min(Swift.max(raw - 1, 0), count - 1)
            if bins.indices.contains(i) { bins[i].count += 1 }
        }
        return bins
    }

    /// A histogram (or Pareto) as the chart that draws it: a column chart of the bin counts with
    /// touching columns, labelled by bin range. A Pareto sorts the bins by count and adds the cumulative
    /// percentage as a line on a 0–100 % secondary axis.
    public func histogramView() -> Chart {
        var bins = histogramBins()
        let pareto = kind == .pareto
        if pareto { bins = rsStableSorted(bins) { $0.count > $1.count } }
        func fmt(_ v: Double) -> String {
            let r = (v * 100.0).rounded() / 100.0
            if Swift.abs(r - r.rounded()) < 1e-9 { return String(Int64(rustCast: r.rounded())) }
            return rsDisplay(r)
        }
        let firstLo = bins.reduce(Double.infinity) { $0.rustMin($1.lo) }
        var v = self
        v.kind = pareto ? .combo : .column
        v.categories = bins.map { b in
            b.lo <= firstLo ? "[\(fmt(b.lo)), \(fmt(b.hi))]" : "(\(fmt(b.lo)), \(fmt(b.hi))]"
        }
        v.series = []
        v.gapWidth = 0.0
        v.raw = nil
        v.subtotals = []
        var s = series.first ?? Series()
        s.name = series.first?.name ?? ""
        s.values = bins.map { Double($0.count) }
        s.kind = pareto ? .column : nil
        s.numberFormat = nil
        v.series.append(s)
        if pareto {
            let total = Double(Swift.max(bins.reduce(0) { $0 + $1.count }, 1))
            var run = 0.0
            v.series.append(Series(
                name: "Cumulative %",
                values: bins.map { b in
                    run += Double(b.count)
                    return run / total
                },
                kind: .line,
                secondaryAxis: true
            ))
            v.y2Min = 0.0
            v.y2Max = 1.0
            v.y2Major = 0.2
            v.y2Format = "0%"
        }
        v.varyColors = false
        return v
    }

    /// The box chart's groups (distinct category labels in order of appearance; one unnamed group
    /// without categories) and, per series, each group's summary (nil when it has no points).
    public func boxGroups() -> (groups: [String], stats: [[BoxStats?]]) {
        var groups: [String] = []
        for c in categories where !groups.contains(c) { groups.append(c) }
        if groups.isEmpty { groups.append("") }
        let stats = series.map { s in
            groups.map { g in
                let pts = s.values.enumerated().filter { i, _ in
                    categories.at(i).map { $0 == g } ?? (g.isEmpty || categories.isEmpty)
                }.compactMap(\.element).filter(\.isFinite)
                return boxStats(pts, inclusive: inclusiveQuartiles)
            }
        }
        return (groups, stats)
    }
}

/// Widens the (min, max) extent `ext` to include `v`.
private func widen(_ ext: inout (Double, Double), _ v: Double) {
    ext.0 = ext.0.rustMin(v)
    ext.1 = ext.1.rustMax(v)
}

/// Excel's QUARTILE.EXC position `p·(n+1)` (1-based) on sorted data, clamped to the ends.
private func quantileExc(_ v: [Double], _ p: Double) -> Double {
    let n = v.count
    let pos = (p * (Double(n) + 1.0)).clamped(1.0, Double(n))
    let i = Int(rustCast: pos.rounded(.down))
    let frac = pos - Double(i)
    let a = v.at(Swift.min(Swift.max(i - 1, 0), n - 1)) ?? 0
    let b = v.at(Swift.min(i, n - 1)) ?? 0
    return a + (b - a) * frac
}

/// Excel's QUARTILE.INC position `p·(n-1)` (0-based) on sorted data.
private func quantileInc(_ v: [Double], _ p: Double) -> Double {
    let n = v.count
    let pos = (p * (Double(n) - 1.0)).clamped(0.0, Double(n - 1))
    let i = Int(rustCast: pos.rounded(.down))
    let a = v.at(Swift.min(i, n - 1)) ?? 0
    let b = v.at(Swift.min(i + 1, n - 1)) ?? 0
    return a + (b - a) * (pos - Double(i))
}

/// The summary of one group's points, with exclusive quartiles.
public func boxStats(_ pts: [Double]) -> BoxStats? {
    boxStats(pts, inclusive: false)
}

/// The summary of one group's points; `inclusive` picks QUARTILE.INC over QUARTILE.EXC.
public func boxStats(_ pts: [Double], inclusive: Bool) -> BoxStats? {
    if pts.isEmpty { return nil }
    let pts = rsStableSorted(pts, by: rsTotalLess)
    func q(_ p: Double) -> Double { inclusive ? quantileInc(pts, p) : quantileExc(pts, p) }
    let (q1, median, q3) = (q(0.25), q(0.5), q(0.75))
    let iqr = q3 - q1
    let (loFence, hiFence) = (q1 - 1.5 * iqr, q3 + 1.5 * iqr)
    let inside = pts.filter { $0 >= loFence && $0 <= hiFence }
    let low = (inside.first ?? q1).rustMin(q1)
    let high = (inside.last ?? q3).rustMax(q3)
    let mean = rsSum(pts) / Double(pts.count)
    let outliers = pts.filter { $0 < loFence || $0 > hiFence }
    return BoxStats(low: low, q1: q1, median: median, q3: q3, high: high, mean: mean, outliers: outliers)
}

/// A node of a treemap or sunburst hierarchy: its label, the total of the leaves under it, and its
/// children (none for a leaf, which names its category index).
public struct TreeNode: Sendable, Equatable {
    public var name: String
    public var value: Double
    public var leaf: Int?
    public var children: [TreeNode]
}

/// Levels of hierarchy a chart may have (a hostile file cannot nest deeper).
public let maxChartLevels = 16

extension Chart {
    /// The first series as a hierarchy: top-level nodes, each holding the consecutive categories that
    /// share its label, down to the leaves. Without outer levels every category is a top-level leaf.
    /// Negative and missing values count as zero.
    public func categoryTree() -> [TreeNode] {
        guard let s = series.first else { return [] }
        let n = Swift.max(categories.count, s.values.count)
        let levels = Array(categoryLevels.prefix(maxChartLevels))
        // Each leaf's path from the top level down, blanks filled from the row above.
        var last = Array(repeating: "", count: levels.count)
        let paths: [[String]] = (0 ..< n).map { i in
            var path: [String] = []
            path.reserveCapacity(levels.count + 1)
            for (d, lv) in levels.enumerated().reversed() {
                let l = lv.at(i).map { String(rustTrim($0)) } ?? ""
                if !l.isEmpty {
                    last[d] = l
                    // A new outer label starts fresh inner groups.
                    for inner in 0 ..< d { last[inner] = "" }
                }
                path.append(last[d])
            }
            path.append(categories.at(i) ?? "")
            return path
        }
        func value(_ i: Int) -> Double {
            guard let v = s.values.at(i) ?? nil, v.isFinite else { return 0.0.rustMax(0.0) }
            return v.rustMax(0.0)
        }
        func build(_ rows: [(Int, ArraySlice<String>)]) -> [TreeNode] {
            var out: [TreeNode] = []
            var i = 0
            while i < rows.count {
                let (idx, path) = rows[i]
                guard path.count > 1, let head = path.first else {
                    out.append(TreeNode(name: path.first ?? "", value: value(idx), leaf: idx, children: []))
                    i += 1
                    continue
                }
                var j = i
                while j < rows.count && rows[j].1.count > 1 && rows[j].1.first == head { j += 1 }
                let sub = rows[i ..< j].map { ($0.0, $0.1.dropFirst()) }
                let children = build(sub)
                out.append(TreeNode(name: head, value: rsSum(children.map(\.value)), leaf: nil, children: children))
                i = j
            }
            return out
        }
        return build(paths.enumerated().map { ($0.offset, $0.element[...]) })
    }
}
