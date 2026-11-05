// The port's own: chart builds (`ChartBuild.swift`, AB-T-0443).
import CNCore
import Testing
@testable import DCModel

@Suite struct ChartBuildTests {
    /// The sample column chart: 3 series over 4 categories.
    let chart = Chart.sample(.column)

    @Test func stepsFollowPowerPointsOrder() {
        #expect(chart.series.count == 3 && chart.buildPointCount == 4)
        let bySeries = chartBuildSteps(chart, .bySeries, background: true)
        #expect(bySeries == [ChartElement(step: .background)] + (0 ..< 3).map { ChartElement(step: .series, series: UInt32($0)) })
        let byCategory = chartBuildSteps(chart, .byCategory, background: false)
        #expect(byCategory == (0 ..< 4).map { ChartElement(step: .category, category: UInt32($0)) })
        // Points series by series, or category by category (PowerPoint's order, measured 2026-11-05).
        let inSeries = chartBuildSteps(chart, .bySeriesElement, background: true).dropFirst().map { ($0.series, $0.category) }
        #expect(inSeries.prefix(5).map { [$0.0, $0.1] } == [[0, 0], [0, 1], [0, 2], [0, 3], [1, 0]])
        let inCategory = chartBuildSteps(chart, .byCategoryElement, background: true).dropFirst().map { ($0.series, $0.category) }
        #expect(inCategory.prefix(4).map { [$0.0, $0.1] } == [[0, 0], [1, 0], [2, 0], [0, 1]])
        #expect(inSeries.count == 12 && inCategory.count == 12)
        #expect(chartBuildSteps(chart, .bySeriesElement, background: true).allSatisfy { $0.step == .background || $0.step == .seriesPoint })
    }

    @Test func noDataOrTooManyStepsIsNoBuild() {
        #expect(chartBuildSteps(Chart.default, .bySeries, background: true).isEmpty)
        var big = Chart.sample(.column)
        big.categories = (0 ..< 400).map { "C\($0)" }
        #expect(chartBuildSteps(big, .byCategory, background: true).count == 401)
        #expect(chartBuildSteps(big, .bySeriesElement, background: true).isEmpty, "1,200 points is past the cap")
    }

    @Test func fileValuesRoundTrip() {
        for b in [ChartBuild.bySeries, .byCategory, .bySeriesElement, .byCategoryElement] {
            #expect(ChartBuild.fromFile(b.fileValue) == b)
        }
        #expect(ChartBuild.fromFile("allAtOnce") == nil && ChartBuild.fromFile(nil) == nil)
        for st in [ChartStep.background, .series, .category, .seriesPoint, .categoryPoint] {
            #expect(ChartStep.fromFile(st.fileValue) == st)
        }
        // PowerPoint's indices: -3 for the background, -4 where a step names no series or category.
        let cases: [(ChartElement, Int64, Int64)] = [
            (ChartElement(step: .background), -3, -3),
            (ChartElement(step: .series, series: 1), 1, -4),
            (ChartElement(step: .category, category: 2), -4, 2),
            (ChartElement(step: .seriesPoint, series: 1, category: 2), 1, 2),
            (ChartElement(step: .categoryPoint, series: 0, category: 3), 0, 3),
        ]
        for (e, s, c) in cases {
            #expect(e.fileIndices == (s, c))
            #expect(ChartElement.fromFile(step: e.step.fileValue, series: s, category: c) == e)
        }
        #expect(ChartElement.fromFile(step: "series", series: -4, category: -4) == nil)
        #expect(ChartElement.fromFile(step: "ptInSeries", series: 1, category: nil) == nil)
        #expect(ChartElement.fromFile(step: "bogus", series: 0, category: 0) == nil)
    }

    @Test func coversPointsOfItsStep() {
        #expect(ChartElement(step: .series, series: 1).covers(series: 1, category: 3))
        #expect(!ChartElement(step: .series, series: 1).covers(series: 0, category: 3))
        #expect(ChartElement(step: .category, category: 2).covers(series: 2, category: 2))
        #expect(ChartElement(step: .seriesPoint, series: 1, category: 2).covers(series: 1, category: 2))
        #expect(!ChartElement(step: .categoryPoint, series: 1, category: 2).covers(series: 2, category: 2))
        #expect(!ChartElement(step: .background).covers(series: 0, category: 0))
    }

    /// Unset, the new fields stay out of presentation.json, so an animation is written as deckcraft writes it.
    @Test func jsonLeavesUnsetFieldsOutAndKeepsSetOnes() throws {
        let plain = Animation.default.toJSON()
        let text = JSONWriter().string(plain)
        #expect(!text.contains("chart"), "\(text)")
        var a = Animation.default
        a.chartBuild = .byCategoryElement
        a.chartNoBackground = true
        a.chartElement = ChartElement(step: .categoryPoint, series: 2, category: 1)
        let back = try Animation(fromJSON: a.toJSON())
        #expect(back == a)
        #expect(try Animation(fromJSON: plain) == Animation.default)
    }
}
