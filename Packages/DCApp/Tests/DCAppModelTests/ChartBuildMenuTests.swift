// DCAppModelTests — Animations › Effect Options › Sequence on a chart is a chart build (AB-T-0443's follow-up).
import CNCore
import DCEngine
import DCModel
import Testing
@testable import DCAppModel

@MainActor
@Suite struct ChartBuildMenuTests {
    /// An app with an animated chart of `type` selected.
    private func animatedChart(_ type: String = "column") throws -> AppModel {
        let model = AppModel(session: Session.withNew())
        let id = try #require(try model.run("insert.chart", ["type": .string(type)]).get().get("id"))
        _ = model.run("animation.add", ["effect": "fly", "class": "entrance", "ids": [id]])
        _ = model.run("edit.select", ["ids": [id]])
        return model
    }

    private func current(_ model: AppModel) throws -> Animation { try #require(RibbonModel.currentAnimation(model)) }

    @Test func effectOptionsListTheChartsBuilds() throws {
        let model = try animatedChart()
        let items = RibbonModelTests.items(RibbonMenus.entries("animations.effectOptions", model))
        let builds = items.compactMap { $0.params["chartBuild"]?.asStr }
        #expect(builds == ["asOne", "bySeries", "byCategory", "bySeriesElement", "byCategoryElement"])
        #expect(!items.contains { $0.params["textBuild"] != nil }, "a chart has no text build")
        // Picking one sets it, and As One Object takes it off.
        let ref = try #require(items.first { $0.params["chartBuild"] == "byCategory" })
        #expect(throws: Never.self) { try model.run(ref.id, ref.params).get() }
        #expect(try current(model).chartBuild == .byCategory)
        _ = model.run("animation.options", ["chartBuild": "asOne"])
        #expect(try current(model).chartBuild == nil)
    }

    /// A chart the port plays as one object offers only As One Object; a shape that isn't a chart keeps the text
    /// builds.
    @Test func otherShapesKeepTheirSequence() throws {
        let radar = try animatedChart("radar")
        let builds = RibbonModelTests.items(RibbonMenus.entries("animations.effectOptions", radar)).compactMap { $0.params["chartBuild"]?.asStr }
        #expect(builds == ["asOne"])

        let model = AppModel(session: Session.withNew())
        let id = try #require(try model.run("shape.insert", ["preset": "rect", "rect": [10, 10, 100, 100]]).get().get("id"))
        _ = model.run("animation.add", ["effect": "fly", "class": "entrance", "ids": [id]])
        _ = model.run("edit.select", ["ids": [id]])
        let items = RibbonModelTests.items(RibbonMenus.entries("animations.effectOptions", model))
        #expect(items.compactMap { $0.params["textBuild"]?.asStr } == ["asOne", "byParagraph"])
        #expect(!items.contains { $0.params["chartBuild"] != nil })
    }

    @Test func theInspectorsSequenceNamesTheBuild() throws {
        let model = try animatedChart()
        let slide = model.session.activeDoc?.currentSlide
        let a = try current(model)
        let chart = try #require(InspectorMotion.chart(a, slide))
        #expect(InspectorMotion.chartBuildRows(chart).map(\.1) == ["As One Object", "By Series", "By Category", "By Element in Series", "By Element in Category"])
        #expect(InspectorMotion.chartBuildId(a) == "asOne")
        var b = a
        b.chartBuild = .bySeriesElement
        #expect(InspectorMotion.chartBuildId(b) == "bySeriesElement")
        b.chartElement = ChartElement(step: .background)
        #expect(InspectorMotion.chartBuildId(b) == "steps")
    }
}
