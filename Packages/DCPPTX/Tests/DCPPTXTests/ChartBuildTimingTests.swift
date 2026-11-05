// The port's own: chart builds in `p:timing` (AB-T-0443). The XML shapes asserted here are PowerPoint's, measured on
// decks PowerPoint 16.114 saved on 2026-11-05 (By Series, By Category, By Element in Series and in Category, On Click
// and After Previous): each step is an effect whose target is `p:spTgt/p:graphicEl/a:chart`, all in one `grpId`
// with a `p:bldGraphic` naming the build.
import DCModel
import Foundation
import Testing
@testable import DCPPTX

private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

/// A one-slide deck holding the sample column chart (3 series, 4 categories) with `anims`.
private func chartDeck(_ anims: (ShapeId) -> [Animation]) throws -> Presentation {
    var p = newPresentation(nil)
    p.slides.removeAll()
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    var slide = try #require(newSlide(&p, layout), "slide")
    var shape = IT.shape(&p, "Chart", 40, 40, 600, 400)
    shape.kind = .chart(Chart.sample(.column))
    slide.shapes.append(shape)
    slide.animations = anims(shape.id)
    p.slides.append(slide)
    return p
}

private func build(_ id: ShapeId, _ b: ChartBuild?, _ start: AnimStart = .onClick, background: Bool = true) -> Animation {
    var a = Animation.default
    a.shape = id
    a.effect = "fly"
    a.option = "b"
    a.start = start
    a.chartBuild = b
    a.chartNoBackground = !background
    return a
}

private func slideXML(_ bytes: [UInt8]) throws -> String {
    try text(#require(IT.entries(bytes).first { $0.0 == "ppt/slides/slide1.xml" }?.1))
}

/// Every match of `pattern` in `s`.
private func all(_ s: String, _ pattern: String) -> [String] {
    s.matches(of: try! Regex(pattern)).map { String(s[$0.range]) }
}

@Suite struct ChartBuildTimingTests {
    @Test func aBySeriesBuildWritesOneEffectPerStepAndReadsBackAsOne() throws {
        let p = try chartDeck { [build($0, .bySeries)] }
        let bytes = try PPTX.export(p)
        let xml = try slideXML(bytes)
        let targets = all(xml, #"<a:chart [^>]*/>"#)
        // Each effect names its part in each of its behaviours; the distinct steps, in order:
        var steps: [String] = []
        for t in targets where steps.last != t { steps.append(t) }
        #expect(steps == [
            #"<a:chart seriesIdx="-3" categoryIdx="-3" bldStep="gridLegend"/>"#,
            #"<a:chart seriesIdx="0" categoryIdx="-4" bldStep="series"/>"#,
            #"<a:chart seriesIdx="1" categoryIdx="-4" bldStep="series"/>"#,
            #"<a:chart seriesIdx="2" categoryIdx="-4" bldStep="series"/>"#,
        ])
        #expect(all(xml, #"nodeType="clickEffect""#).count == 4)
        #expect(all(xml, #"grpId="0""#).count == 4 + 1, "every step and the bldGraphic share grpId 0")
        #expect(xml.contains(#"<p:bldGraphic spid=""#) && xml.contains(#"<p:bldSub><a:bldChart bld="series"/></p:bldSub></p:bldGraphic>"#))
        let back = try PPTX.import(bytes)
        let anims = try #require(back.slides.first).animations
        #expect(anims.count == 1)
        #expect(anims.first?.chartBuild == .bySeries && anims.first?.chartElement == nil && anims.first?.chartNoBackground == false)
        #expect(anims.first?.effect == "fly" && anims.first?.start == .onClick)
    }

    @Test func everyBuildRoundTrips() throws {
        for b in [ChartBuild.bySeries, .byCategory, .bySeriesElement, .byCategoryElement] {
            for start in [AnimStart.onClick, .afterPrevious, .withPrevious] {
                for background in [true, false] {
                    let p = try chartDeck { [build($0, b, start, background: background)] }
                    let bytes = try PPTX.export(p)
                    let a = try #require(PPTX.import(bytes).slides.first?.animations)
                    let label = "\(b) \(start) background \(background)"
                    #expect(a.count == 1, "\(label): \(a.count) animations")
                    #expect(a.first?.chartBuild == b && a.first?.start == start && a.first?.chartNoBackground == !background, "\(label)")
                    let xml = try slideXML(bytes)
                    #expect(xml.contains(#"bld="\#(b.fileValue)""#), "\(label)")
                    #expect(xml.contains(#"animBg="0""#) == !background, "\(label)")
                    #expect(xml.contains(#"bldStep="gridLegend""#) == background, "\(label)")
                }
            }
        }
    }

    /// A non-click build's later steps follow one another (PowerPoint's After Previous chain).
    @Test func laterStepsOfAnAfterPreviousBuildAreAfterEffects() throws {
        let p = try chartDeck { [build($0, .byCategory, .afterPrevious)] }
        let xml = try slideXML(PPTX.export(p))
        #expect(all(xml, #"nodeType="afterEffect""#).count == 5)
        #expect(all(xml, #"nodeType="clickEffect""#).isEmpty)
    }

    /// Steps that don't play as a build of the first (one has its own effect) stay separate animations, each
    /// naming its part, and are written back in one group under their build.
    @Test func stepsThatDifferStaySeparateAndKeepTheirParts() throws {
        let p = try chartDeck { [build($0, .bySeries)] }
        var xml = try slideXML(PPTX.export(p))
        // The third step (series 1) becomes a Wipe from the left, as an edit in PowerPoint would make it.
        let marker = #"<a:chart seriesIdx="1" categoryIdx="-4" bldStep="series"/>"#
        let i = try #require(xml.range(of: marker))
        let at = try #require(xml[..<i.lowerBound].range(of: #"presetID="2""#, options: .backwards))
        xml.replaceSubrange(at, with: #"presetID="22""#)
        let edited = xml
        let bytes = try IT.rewriteXML(PPTX.export(p)) { name, x in name == "ppt/slides/slide1.xml" ? edited : x }
        let a = try #require(PPTX.import(bytes).slides.first?.animations)
        #expect(a.count == 4, "\(a.map(\.effect))")
        #expect(a.map(\.chartElement) == chartBuildSteps(Chart.sample(.column), .bySeries, background: true).map { Optional($0) })
        #expect(a.allSatisfy { $0.chartBuild == nil })
        #expect(a.map(\.effect) == ["fly", "fly", "wipe", "fly"])
        // Written again: the same parts, one group, one bldGraphic.
        var q = p
        q.slides[0].animations = a
        let again = try slideXML(PPTX.export(q))
        var steps: [String] = []
        for t in all(again, #"<a:chart [^>]*/>"#) where steps.last != t { steps.append(t) }
        #expect(steps.count == 4 && steps.dropFirst().first == #"<a:chart seriesIdx="0" categoryIdx="-4" bldStep="series"/>"#)
        #expect(all(again, #"<p:bldGraphic "#).count == 1 && again.contains(#"<a:bldChart bld="series"/>"#))
        let b = try #require(PPTX.import(PPTX.export(q)).slides.first?.animations)
        #expect(b == a)
    }

    /// A chart animated as one object writes and reads as it always did: no part targets, no bldGraphic.
    @Test func aChartAsOneObjectIsUnchanged() throws {
        let p = try chartDeck { [build($0, nil)] }
        let xml = try slideXML(PPTX.export(p))
        #expect(!xml.contains("graphicEl") && !xml.contains("bldGraphic"))
        let a = try #require(PPTX.import(PPTX.export(p)).slides.first?.animations)
        #expect(a.count == 1 && a.first?.chartBuild == nil && a.first?.chartElement == nil)
    }

    /// CHARTBUILD_DECK=<file.pptx> writes a deck with one slide per build (each kind, On Click; By Category After
    /// Previous; By Series without its background) for opening in PowerPoint (`Tools/pptx/powerpoint-check.sh`).
    @Test func writesADeckOfEveryBuildForPowerPoint() throws {
        guard let path = ProcessInfo.processInfo.environment["CHARTBUILD_DECK"] else { return }
        var p = try chartDeck { [build($0, .bySeries)] }
        let one = p.slides[0]
        let cases: [(ChartBuild, AnimStart, Bool)] = [
            (.byCategory, .onClick, true), (.bySeriesElement, .onClick, true), (.byCategoryElement, .onClick, true),
            (.byCategory, .afterPrevious, true), (.bySeries, .onClick, false),
        ]
        for (b, start, bg) in cases {
            var s = one
            s.id = SlideId(UInt32(p.slides.count + 100))
            s.animations = [build(s.shapes[0].id, b, start, background: bg)]
            p.slides.append(s)
        }
        try Data(PPTX.export(p)).write(to: URL(fileURLWithPath: path))
    }

    /// A build on a shape that isn't a chart is written as one object.
    @Test func aBuildOnAShapeThatIsNotAChartIsOneObject() throws {
        var p = try chartDeck { [build($0, .bySeries)] }
        p.slides[0].shapes[0].kind = .shape
        let xml = try slideXML(PPTX.export(p))
        #expect(!xml.contains("graphicEl") && !xml.contains("bldGraphic"))
    }
}
