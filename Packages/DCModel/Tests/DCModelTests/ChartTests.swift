// Ported from deckcraft crates/model/src/chart.rs tests and chartex_tests (MIT OR Apache-2.0).
import DCModel
import Testing

private func column(_ values: [Double]) -> Chart {
    var c = Chart.default
    c.categories = values.indices.map { "C\($0)" }
    c.series = [Series(name: "Sales", values: values.map { $0 })]
    return c
}

/// The primary axis of a chart with room for ten intervals.
private func scale(_ c: Chart) -> (Double, Double, Double) {
    c.axisScale(false, 10) ?? (0, 0, 0)
}

private func obs(_ v: [Double]) -> Chart {
    var c = Chart.default
    c.kind = .histogram
    c.series = [Series(values: v.map { $0 })]
    return c
}

@Suite struct ChartTests {
    @Test func tinyDataKeepsItsOwnScale() {
        var (min, max, step) = axisScale(1e-13, 5e-13, nil, nil, nil, 8, true)
        #expect(min == 0.0 && max >= 5e-13 && max < 1e-11, "\(min) \(max) \(step)")
        #expect(step > 0.0 && step < 1e-11)
        (min, max, step) = niceScale(1e-13, 5e-13)
        #expect(min <= 1e-13 && max >= 5e-13 && max < 1e-11 && step < 1e-11, "\(min) \(max) \(step)")
        #expect(axisScale(0.0, 0.0, nil, nil, nil, 8, true).1 == 1.0)
    }

    @Test func subnormalDataGivesAFiniteScale() {
        var (min, max, step) = axisScale(0.0, 5e-324, nil, nil, nil, 8, true)
        #expect(min.isFinite && max.isFinite && step.isFinite, "\(min) \(max) \(step)")
        #expect(step > 0.0 && max >= min, "\(min) \(max) \(step)")
        (min, max, step) = niceScale(0.0, Double(bitPattern: 1))
        #expect(min.isFinite && max.isFinite && step > 0.0 && step.isFinite && max > min, "\(min) \(max) \(step)")
    }

    @Test func logAxesRunOverWholePowers() throws {
        var c = Chart.sample(.line)
        c.series = Array(c.series.prefix(1))
        c.series[0].values = [1.0, 10.0, 1000.0, 50000.0]
        #expect(c.logAxisScale(8) == nil)
        c.yLogBase = 10.0
        let a = try #require(c.logAxisScale(8))
        #expect(a == (0.0, 5.0, 1.0))
        let b = try #require(c.logAxisScale(2))
        #expect(b == (0.0, 6.0, 3.0))
    }

    /// #868: a series' own label setting wins; an unset series takes the chart-wide one.
    @Test func seriesDataLabelsOverrideTheChartWideSetting() {
        var c = Chart.sample(.column)
        c.dataLabels = false
        var s = c.series[0]
        #expect(!c.seriesDataLabels(s), "unset series follows the chart")
        s.dataLabels = true
        #expect(c.seriesDataLabels(s), "a series that asks for labels gets them")
        c.dataLabels = true
        s.dataLabels = false
        #expect(!c.seriesDataLabels(s), "an explicit series false hides them anyway")
    }

    @Test func errorBarRanges() throws {
        let vals: [Double?] = [3.0, 5.0, 2.0, 4.0]
        var e = ErrorBars.default
        #expect(try #require(e.range(vals, 0, 3.0)) == (2.0, 4.0))
        e.valType = "percentage"
        e.value = 20.0
        #expect(try #require(e.range(vals, 1, 5.0)) == (4.0, 6.0))
        e.barType = "plus"
        #expect(try #require(e.range(vals, 1, 5.0)) == (5.0, 6.0))
        e = ErrorBars.default
        e.valType = "cust"
        e.plus = [0.5]
        e.minus = [1.5]
        #expect(try #require(e.range(vals, 0, 3.0)) == (1.5, 3.5))
        e = ErrorBars.default
        e.valType = "stdDev"
        let (lo, hi) = try #require(e.range(vals, 0, 3.0))
        #expect(abs(lo + hi - 7.0) < 1e-9 && abs(hi - lo - 2.0 * 1.2909944487358056) < 1e-9)
    }

    @Test func niceScaleCovers() {
        var (a, b, s) = niceScale(0.0, 5.1)
        #expect(a <= 0.0 && b >= 5.1 && s > 0.0)
        (a, b, _) = niceScale(.nan, 3.0)
        #expect(a.isFinite && b.isFinite)
        (a, b, _) = niceScale(7.0, 7.0)
        #expect(b > a)
    }

    @Test func automaticAxisScalesLikePowerPoint() {
        // Weekly spend up to ~715 000 on a plot with room for 9 intervals: 0–800 000 by 100 000.
        #expect(axisScale(0.0, 715_000.0, nil, nil, nil, 9, true) == (0.0, 800_000.0, 100_000.0))
        // Clicks up to 6 600: 0–7 000 by 1 000.
        #expect(axisScale(0.0, 6_600.0, nil, nil, nil, 9, true) == (0.0, 7_000.0, 1_000.0))
        // Fewer intervals fit on a short axis.
        #expect(axisScale(0.0, 6_600.0, nil, nil, nil, 4, true) == (0.0, 8_000.0, 2_000.0))
        // Negative data gets room below; fixed bounds and unit are kept.
        let (min, max, _) = axisScale(-30.0, 100.0, nil, nil, nil, 8, true)
        #expect(min <= -30.0 && max >= 105.0)
        #expect(axisScale(0.0, 715_000.0, 100_000.0, 750_000.0, 50_000.0, 9, true) == (100_000.0, 750_000.0, 50_000.0))
        // 100 % stacked stays at 0–1 without headroom.
        #expect(axisScale(0.0, 1.0, nil, nil, nil, 5, false) == (0.0, 1.0, 0.2))
        // Nonsense never loops or divides by zero.
        for (lo, hi) in [(Double.nan, 1.0), (5.0, 5.0), (0.0, 0.0), (-1e300, 1e300)] {
            let (a, b, s) = axisScale(lo, hi, nil, nil, 0.0, 0, true)
            #expect(a.isFinite && b.isFinite && s > 0.0 && b > a, "\(lo) \(hi): \(a) \(b) \(s)")
        }
    }

    /// Office's documented automatic limits (#144), with room for ten intervals.
    @Test func automaticAxisMatchesOffice() {
        // #144: 42.1 / 18.7 / 6.3 → 0–45 in steps of 5, not 0–50 in steps of 10.
        #expect(scale(column([42.1, 18.7, 6.3])) == (0.0, 45.0, 5.0))
        // PowerPoint's default chart data (max 5): 0–6 in steps of 1.
        var c = column([4.3, 2.5, 3.5, 4.5])
        c.series.append(Series(values: [2.4, 4.4, 1.8, 2.8]))
        c.series.append(Series(values: [2.0, 2.0, 3.0, 5.0]))
        #expect(scale(c) == (0.0, 6.0, 1.0))
        // A maximum of 100 (or 10) gets 5 % headroom, which rounds up to the next major unit.
        #expect(scale(column([100.0, 40.0])) == (0.0, 120.0, 20.0))
        #expect(scale(column([10.0, 3.0])) == (0.0, 12.0, 2.0))
        // Peltier's example: 2.95 + 2.95/20 ≈ 3.1 rounds up to 3.5.
        #expect(scale(column([2.95, 0.0])) == (0.0, 3.5, 0.5))
    }

    @Test func automaticAxisMinimum() {
        // Below 5/6 of the maximum the axis starts at zero; at or above it, a unit below
        // min − (max − min)/20.
        #expect(scale(column([59.0, 49.0])).0 == 0.0)
        #expect(scale(column([59.0, 50.0])) == (48.0, 60.0, 2.0))
        #expect(scale(column([85.0, 92.0, 97.0])) == (84.0, 98.0, 2.0))
        // All-negative data mirrors it: the axis ends at zero, or near the data.
        #expect(scale(column([-42.1, -18.7, -6.3])) == (-45.0, 0.0, 5.0))
        #expect(scale(column([-59.0, -49.0])).1 == 0.0)
        #expect(scale(column([-59.0, -50.0])) == (-60.0, -48.0, 2.0))
        // Mixed signs get headroom at both ends.
        #expect(scale(column([42.1, -18.7])) == (-30.0, 50.0, 10.0))
        // Stacked bars build up from zero, so their axis keeps it.
        var s = column([85.0, 92.0])
        s.kind = .stackedColumn
        #expect(scale(s).0 == 0.0)
        // A combo chart's secondary axis follows the same rule.
        var c = Chart.sample(.combo)
        c.series = Array(c.series.prefix(2))
        c.series[0].values = [200_000.0, 310_000.0]
        c.series[1].kind = .line
        c.series[1].values = [7_000.0, 7_400.0]
        c.series[1].secondaryAxis = true
        #expect(c.axisScale(false, 10).map { $0 == (0.0, 350_000.0, 50_000.0) } == true)
        #expect(c.axisScale(true, 10).map { $0 == (6_950.0, 7_450.0, 50.0) } == true)
    }

    @Test func fixedAxisLimitsAreKept() {
        var c = column([42.1, 18.7, 6.3])
        c.yMax = 50.0
        #expect(scale(c) == (0.0, 50.0, 5.0))
        c.yMin = 10.0
        c.yMax = nil
        #expect(scale(c) == (10.0, 45.0, 5.0))
        // A fixed limit beyond the data: the automatic end gives way to it.
        var d = column([85.0, 92.0, 97.0])
        d.yMax = 50.0
        #expect(scale(d) == (0.0, 50.0, 5.0))
        var e = column([-50.0, -48.0])
        e.yMin = -10.0
        #expect(scale(e) == (-10.0, 0.0, 1.0))
    }

    @Test func percentAxisIsZeroToOne() {
        var p = column([42.1, 18.7, 6.3])
        p.kind = .percentColumn
        #expect(scale(p) == (0.0, 1.0, 0.1))
        #expect(p.axisScale(false, 5).map { $0 == (0.0, 1.0, 0.2) } == true)
    }

    @Test func degenerateAxesAreFinite() {
        let pairs: [(Double, Double)] = [
            (0.0, 0.0), (7.0, 7.0), (-7.0, -7.0), (.nan, 3.0), (.infinity, 1.0),
            (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude), (0.0, 1e-320),
        ]
        for (a, b) in pairs {
            let (min, max, step) = scale(column([a, b]))
            #expect(min.isFinite && max > min && step > 0.0, "\(a) \(b): \(min) \(max) \(step)")
        }
        let (min, max, _) = scale(column([7.0, 7.0]))
        #expect(min == 0.0 && max > 7.0)
        #expect(scale(column([])) == (0.0, 1.0, 0.1))
        let fixed: [(Double?, Double?)] = [(5.0, 5.0), (5.0, 1.0), (.nan, .infinity), (-1e300, nil)]
        for (fmin, fmax) in fixed {
            let (a, b, s) = axisScale(0.0, 1.0, fmin, fmax, nil, 10, true)
            #expect(a.isFinite && b.isFinite && b > a && s > 0.0, "\(String(describing: fmin)) \(String(describing: fmax)): \(a) \(b) \(s)")
        }
    }

    @Test func generalLabelsKeepEveryDigitTheDataHas() {
        // #324: labels were rounded to one decimal ("100000.0" for 99999.99).
        for kind in [ChartType.column, .pie, .doughnut, .line, .scatter] {
            let c = Chart.sample(kind)
            let s = c.series[0]
            for (v, want) in [(1220.82, "1220.82"), (99999.99, "99999.99"), (1500.05, "1500.05"), (1500.0, "1500"), (1234.567, "1234.567"), (999.99, "999.99")] {
                #expect(c.dataLabel(s, v) == want, "\(kind)")
            }
        }
        // Small ranges keep distinct value-axis ticks (0.123 used to give 0, 0.0, 0.1, 0.1…).
        let c = Chart.sample(.column)
        let ticks = (0 ... 5).map { c.axisLabel(false, Double($0) * 0.025) }
        #expect(ticks == ["0", "0.025", "0.05", "0.075", "0.1", "0.125"])
    }

    @Test func aForecastGrowsTheValueAxis() {
        var c = Chart.sample(.line)
        c.series = Array(c.series.prefix(1))
        c.series[0].values = [3.0, 5.0, 7.0, 9.0]
        let before = c.valueRange().1
        var t = Trendline.default
        t.forward = 1.0
        c.series[0].trendlines.append(t)
        let after = c.valueRange().1
        #expect(after > before && after >= 11.0 - 1e-6, "\(before) \(after)")
    }

    @Test func axisLabelsUseTheFormatAndLanguage() {
        var c = Chart.sample(.column)
        c.yFormat = #"_-* #\ ##0\ "₽"_-;\-* #\ ##0\ "₽"_-;_-* "-"??\ "₽"_-;_-@_-"#
        c.lang = "ru-RU"
        #expect(c.axisLabel(false, 800_000.0) == "800\u{a0}000 ₽")
        #expect(c.axisLabel(false, 0.0) == "- ₽")
        // No format: General.
        #expect(c.axisLabel(true, 2.5) == "2,5")
        c.lang = nil
        #expect(c.axisLabel(true, 2.5) == "2.5")
        // Data labels: the series' format, else the axis'.
        c.lang = "ru-RU"
        c.series[0].numberFormat = #"#,##0\ "₽""#
        #expect(c.dataLabel(c.series[0], 516_600_000.0) == "516\u{a0}600\u{a0}000 ₽")
        #expect(c.dataLabel(c.series[1], 0.0) == "- ₽")
    }

    @Test func fullPercentAxesCountInPercent() {
        var c = Chart.sample(.percentColumn)
        #expect(c.axisLabel(false, 0.5) == "50%")
        c.yFormat = "0.0%"
        #expect(c.axisLabel(false, 0.5) == "50.0%")
        #expect(Chart.sample(.column).axisLabel(false, 0.5) == "0.5")
    }

    @Test func comboAxisRanges() {
        // Spend in columns on the primary axis, clicks as a line on the secondary one.
        var c = Chart.sample(.combo)
        c.series = Array(c.series.prefix(2))
        c.series[0].kind = .column
        c.series[0].values = [200_000.0, 310_000.0]
        c.series[1].kind = .line
        c.series[1].values = [6_000.0, 7_400.0]
        c.series[1].secondaryAxis = true
        #expect(c.axisRange(false).map { $0 == (0.0, 310_000.0) } == true)
        #expect(c.axisRange(true).map { $0 == (0.0, 7_400.0) } == true)
        #expect(c.seriesKind(c.series[1]) == .line)
        // Without a secondary series there is no secondary axis; a non-combo chart never has one.
        c.series[1].secondaryAxis = false
        #expect(c.axisRange(true) == nil)
        let col = Chart.sample(.column)
        #expect(col.axisRange(false).map { $0 == col.valueRange() } == true)
        #expect(col.axisRange(true) == nil)
        #expect(!col.onSecondary(col.series[0]))
    }

    @Test func sampleRanges() {
        let c = Chart.sample(.stackedColumn)
        #expect(c.valueRange().1 > 10.0)
        #expect(Chart.sample(.pie).series.count == 1)
    }
}

@Suite struct ChartexTests {
    @Test func histogramBinsByCountSizeAndScott() {
        var c = obs([1.0, 2.0, 2.0, 3.0, 4.0, 5.0, 9.0])
        c.binCount = 4
        let b = c.histogramBins()
        #expect(b.count == 4)
        #expect(b.first.map { $0.lo == 1.0 && $0.hi == 3.0 } == true)
        // (lo, hi] bins with the minimum in the first: 1, 2, 2, 3 | 4, 5 | - | 9.
        #expect(b.map(\.count) == [4, 2, 0, 1])
        c.binCount = nil
        c.binSize = 5.0
        #expect(c.histogramBins().map(\.count) == [6, 1])
        c.binSize = nil
        let auto = c.histogramBins()
        #expect(!auto.isEmpty && auto.reduce(0) { $0 + $1.count } == 7)
        // A tiny bin size is capped; one value gives one bin.
        c.binSize = 1e-12
        #expect(c.histogramBins().count <= maxBins)
        #expect(obs([3.0]).histogramBins() == [Bin(lo: 3.0, hi: 4.0, count: 1)])
        #expect(obs([]).histogramBins().isEmpty)
    }

    @Test func histogramFixedBinCountIsExactDespiteFloatRounding() {
        var c = obs([0.0, 1.0, 2.1])
        c.binCount = 7
        #expect(c.histogramBins().count == 7)
    }

    @Test func paretoViewSortsBinsAndAddsTheCumulativeLine() {
        var c = obs([1.0, 5.0, 5.0, 5.0, 9.0, 9.0])
        c.kind = .pareto
        c.binCount = 3
        let v = c.histogramView()
        #expect(v.kind == .combo)
        #expect(v.series[0].values == [3.0, 2.0, 1.0])
        let cum = v.series[1]
        #expect(cum.secondaryAxis && cum.kind == .line)
        #expect(cum.values.last == .some(1.0))
        #expect(v.categories[0] == "(3.67, 6.33]")
    }

    @Test func boxStatsUseExclusiveQuartilesAndFenceOutliers() throws {
        let b = try #require(boxStats([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 100.0]))
        // QUARTILE.EXC on 8 points: positions 2.25, 4.5, 6.75.
        #expect(b.q1 == 2.25 && b.median == 4.5 && b.q3 == 6.75)
        #expect(b.outliers == [100.0])
        #expect(b.low == 1.0 && b.high == 7.0)
        #expect(boxStats([]) == nil)
        let one = try #require(boxStats([5.0]))
        #expect([one.low, one.q1, one.median, one.q3, one.high] == [5.0, 5.0, 5.0, 5.0, 5.0])
    }

    @Test func inclusiveQuartilesFollowQuartileInc() throws {
        let b = try #require(boxStats([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 100.0], inclusive: true))
        // QUARTILE.INC on 8 points: positions 1.75, 3.5, 5.25 (0-based).
        #expect(b.q1 == 2.75 && b.median == 4.5 && b.q3 == 6.25)
    }

    @Test func categoryTreeGroupsRunsAndFillsBlankParents() throws {
        var c = Chart.sample(.treemap)
        var t = c.categoryTree()
        #expect(t.map(\.name) == ["Q1", "Q2", "Q3"])
        #expect(t[0].children.count == 3)
        #expect(t[0].children[1].leaf == 1)
        #expect(abs(t[0].value - (4.2 + 2.8 + 3.6)) < 1e-9)
        // Blank parents continue the label above; two outer levels nest.
        c.categoryLevels = [
            ["a", "", "b", "", "c", "", "", ""],
            ["H1", "", "", "", "H2", "", "", ""],
        ]
        t = c.categoryTree()
        #expect(t.count == 2)
        #expect(t[0].children.map(\.name) == ["a", "b"])
        #expect(t[1].children[0].children.count == 4)
        // No levels: every category is a leaf.
        c.categoryLevels = []
        #expect(c.categoryTree().allSatisfy { $0.leaf != nil })
    }

    @Test func boxGroupsFollowCategoryLabels() {
        let c = Chart.sample(.boxWhisker)
        let (groups, stats) = c.boxGroups()
        #expect(groups == ["Group A", "Group B"])
        #expect(stats.count == 2)
        #expect(stats.allSatisfy { $0.count == 2 && $0.allSatisfy { $0 != nil } })
    }
}
