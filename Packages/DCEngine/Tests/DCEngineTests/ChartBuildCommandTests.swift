// The port's own: `animation.options` sets a chart build (AB-T-0443's follow-up; DCEngine PORT-NOTES).
import CNCore
@testable import DCEngine
import DCModel
import Testing

@Suite struct ChartBuildCommandTests {
    /// A deck with an animated column chart (3 series, 4 categories); returns the session and the chart's id.
    private func animatedChart(_ type: String = "column") throws -> (Session, UInt64) {
        let s = session()
        let id = try #require(s.run("insert.chart", #"{"type": "\#(type)"}"#).get("id")?.asU64)
        s.run("animation.add", #"{"effect": "fly", "class": "entrance", "ids": [\#(id)]}"#)
        return (s, id)
    }

    private func anims(_ s: Session) -> [Animation] { s.st.currentSlide?.animations ?? [] }

    @Test func setsEachBuildAndBackOneObject() throws {
        let (s, id) = try animatedChart()
        for b in ["bySeries", "byCategory", "bySeriesElement", "byCategoryElement"] {
            s.run("animation.options", #"{"chartBuild": "\#(b)", "ids": [\#(id)]}"#)
            #expect(anims(s).count == 1 && anims(s).first?.chartBuild?.rawValue == b)
        }
        s.run("animation.options", #"{"chartBackground": false, "ids": [\#(id)]}"#)
        #expect(anims(s).first?.chartNoBackground == true)
        s.run("animation.options", #"{"chartBackground": true, "ids": [\#(id)]}"#)
        #expect(anims(s).first?.chartNoBackground == false)
        s.run("animation.options", #"{"chartBuild": "bySeries", "chartBackground": false, "ids": [\#(id)]}"#)
        #expect(anims(s).first?.chartBuild == .bySeries && anims(s).first?.chartNoBackground == true)
        // As One Object clears the build and its background setting.
        s.run("animation.options", #"{"chartBuild": "asOne", "ids": [\#(id)]}"#)
        #expect(anims(s).first?.chartBuild == nil && anims(s).first?.chartNoBackground == false)
        // With no build, the background setting has nothing to change.
        s.run("animation.options", #"{"chartBackground": false, "ids": [\#(id)]}"#)
        #expect(anims(s).first?.chartNoBackground == false)
    }

    @Test func undoRestoresTheBuild() throws {
        let (s, id) = try animatedChart()
        s.run("animation.options", #"{"chartBuild": "byCategory", "ids": [\#(id)]}"#)
        s.run("edit.undo")
        #expect(anims(s).first?.chartBuild == nil)
        s.run("edit.redo")
        #expect(anims(s).first?.chartBuild == .byCategory)
    }

    /// Other options in the same call apply as before, with or without a build.
    @Test func optionAndBuildTogether() throws {
        let (s, id) = try animatedChart()
        s.run("animation.options", #"{"option": "l", "chartBuild": "bySeries", "ids": [\#(id)]}"#)
        #expect(anims(s).first?.option == "l" && anims(s).first?.chartBuild == .bySeries)
    }

    /// PowerPoint offers no Sequence where the port can't play one: a shape that isn't a chart, a kind drawn as
    /// one object, a chart whose element build would pass the step cap.
    @Test func refusesABuildNoTargetCanTake() throws {
        let s = session()
        let rect = try #require(s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 100, 100]}"#).get("id")?.asU64)
        s.run("animation.add", #"{"effect": "fade", "class": "entrance", "ids": [\#(rect)]}"#)
        #expect(s.fails("animation.options", #"{"chartBuild": "bySeries", "ids": [\#(rect)]}"#))
        #expect(anims(s).first?.chartBuild == nil)
        // As One Object and the background setting are harmless on a shape that isn't a chart.
        s.run("animation.options", #"{"chartBuild": "asOne", "ids": [\#(rect)]}"#)
        s.run("animation.options", #"{"chartBackground": false, "ids": [\#(rect)]}"#)
        #expect(anims(s).first?.chartBuild == nil && anims(s).first?.chartNoBackground == false)

        let (r, radar) = try animatedChart("radar")
        #expect(r.fails("animation.options", #"{"chartBuild": "bySeries", "ids": [\#(radar)]}"#))

        let (b, big) = try animatedChart()
        try b.edit { doc, _ in
            doc.slides[0].mutateShape(ShapeId(UInt32(big))) { sh in
                if case .chart(var c) = sh.kind {
                    c.categories = (0 ..< 400).map { "C\($0)" }
                    sh.kind = .chart(c)
                }
            }
        }
        #expect(b.fails("animation.options", #"{"chartBuild": "bySeriesElement", "ids": [\#(big)]}"#))
        b.run("animation.options", #"{"chartBuild": "byCategory", "ids": [\#(big)]}"#)
        #expect(anims(b).first?.chartBuild == .byCategory)
        // An unknown build name changes nothing, as an unknown `textBuild` changes nothing in deckcraft.
        b.run("animation.options", #"{"chartBuild": "bogus", "ids": [\#(big)]}"#)
        #expect(anims(b).first?.chartBuild == .byCategory)
    }

    /// A file's build whose steps were kept apart (one has its own effect) becomes one build again when a
    /// Sequence is chosen, as PowerPoint rewrites the steps; the animations around it stay.
    @Test func joinsKeptApartStepsIntoOneBuild() throws {
        let (s, id) = try animatedChart()
        let rect = try #require(s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 100, 100]}"#).get("id")?.asU64)
        try s.edit { doc, _ in
            var anims = doc.slides[0].animations
            let one = try #require(anims.first)
            let steps = chartBuildSteps(Chart.sample(.column), .bySeries, background: true)
            anims = steps.map { e in
                var a = one
                a.chartElement = e
                return a
            }
            var other = one
            other.shape = ShapeId(UInt32(rect))
            doc.slides[0].animations = [other] + anims + [other]
        }
        #expect(anims(s).count == 6)
        // Targeting one step by index joins all four.
        s.run("animation.options", #"{"index": 2, "chartBuild": "byCategory"}"#)
        let a = anims(s)
        #expect(a.count == 3)
        #expect(a[1].chartBuild == .byCategory && a[1].chartElement == nil && a[1].shape == ShapeId(UInt32(id)))
        #expect(a[0].chartBuild == nil && a[2].chartBuild == nil)
        s.run("edit.undo")
        #expect(anims(s).count == 6)
        // As One Object joins them too, into a plain animation.
        s.run("animation.options", #"{"chartBuild": "asOne", "ids": [\#(id)]}"#)
        #expect(anims(s).count == 3 && anims(s)[1].chartElement == nil && anims(s)[1].chartBuild == nil)
    }
}
