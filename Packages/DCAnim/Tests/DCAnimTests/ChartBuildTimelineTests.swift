// The port's own: chart builds in the timeline (AB-T-0443). A build plays one effect per step, each on the chart
// part it names, the background first.
import DCGeometry
import DCModel
import Testing
@testable import DCAnim

/// A slide with the sample column chart (3 series, 4 categories) as shape 7, animated by `a`.
private func chartSlide(_ set: (inout Animation) -> Void) -> Slide {
    var slide = Presentation.default.slides[0]
    var shape = Shape.default
    shape.id = ShapeId(7)
    shape.xfrm = Xfrm(100, 100, 600, 300)
    shape.kind = .chart(Chart.sample(.column))
    slide.shapes = [shape]
    var a = Animation.default
    a.shape = shape.id
    a.effect = "fade"
    a.durationMs = 500
    set(&a)
    slide.animations = [a]
    return slide
}

@Suite struct ChartBuildTimelineTests {
    @Test func aBySeriesBuildOnClickIsOneStepPerPart() {
        let tl = Timeline(chartSlide { $0.chartBuild = .bySeries }, 960, 540)
        #expect(tl.steps == 4, "background, then three series")
        #expect(tl.chartTargets(ShapeId(7)) == chartBuildSteps(Chart.sample(.column), .bySeries, background: true))
        let bg = ChartElement(step: .background)
        let s0 = ChartElement(step: .series, series: 0)
        let s1 = ChartElement(step: .series, series: 1)
        // Before any click nothing of the chart's parts shows; the chart itself has no effect of its own.
        #expect(tl.state(ShapeId(7), nil, 0, 0).visible)
        #expect(!tl.chartState(ShapeId(7), bg, 0, 0).visible && !tl.chartState(ShapeId(7), s0, 0, 0).visible)
        // Halfway into the first click the background is fading in; after it, series 1 is still hidden.
        let mid = tl.chartState(ShapeId(7), bg, 0, 0.25)
        #expect(mid.visible && mid.opacity > 0.3 && mid.opacity < 0.7)
        #expect(tl.chartState(ShapeId(7), bg, 1, 0).visible && !tl.chartState(ShapeId(7), s0, 1, 0).visible)
        #expect(tl.chartState(ShapeId(7), s0, 2, 0).visible && !tl.chartState(ShapeId(7), s1, 2, 0).visible)
        #expect(tl.chartState(ShapeId(7), s1, 4, 0).visible)
        #expect(tl.effects.allSatisfy { $0.paragraph == nil && $0.chart != nil })
    }

    @Test func anAfterPreviousBuildPlaysItsStepsOneAfterAnother() {
        let tl = Timeline(chartSlide { $0.chartBuild = .byCategory; $0.start = .afterPrevious; $0.chartNoBackground = true }, 960, 540)
        #expect(tl.steps == 1)
        #expect(tl.effects.map(\.start) == [0, 0.5, 1.0, 1.5])
        #expect(tl.stepDuration(0) == 2.0)
        let c2 = ChartElement(step: .category, category: 2)
        #expect(!tl.chartState(ShapeId(7), c2, 0, 0.9).visible && tl.chartState(ShapeId(7), c2, 0, 1.6).visible)
    }

    /// One effect read from a file names one part; the rest of the chart shows as usual.
    @Test func aSinglePartEffectAnimatesOnlyThatPart() {
        let part = ChartElement(step: .seriesPoint, series: 2, category: 1)
        let tl = Timeline(chartSlide { $0.chartElement = part }, 960, 540)
        #expect(tl.steps == 1 && tl.chartTargets(ShapeId(7)) == [part])
        #expect(!tl.chartState(ShapeId(7), part, 0, 0).visible && tl.chartState(ShapeId(7), part, 1, 0).visible)
        #expect(tl.state(ShapeId(7), nil, 0, 0).visible)
    }

    /// Without a build, a chart animates as one object, as in deckcraft.
    @Test func aChartWithoutABuildIsOneObject() {
        let tl = Timeline(chartSlide { _ in }, 960, 540)
        #expect(tl.steps == 1 && tl.chartTargets(ShapeId(7)).isEmpty)
        #expect(!tl.state(ShapeId(7), nil, 0, 0).visible)
    }
}
