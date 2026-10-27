// Port of deckcraft crates/pptx/tests/it/trigger_steps.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Synthetic interactive sequences must keep one step per click across a save.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationTriggerStepsTests {
    private static func deck() -> Presentation {
        var p = newPresentation(nil)
        let shapes = ["Button", "Other button", "Content"].map { name in
            var s = Shape.default
            s.id = ShapeId(p.allocId() ?? 0)
            s.name = name
            s.xfrm = Xfrm(40.0, 40.0, 200.0, 100.0)
            s.text = TextBody.fromText("First\nSecond\nThird")
            return s
        }
        p.slides[0].shapes = shapes
        return p
    }

    private static func slideXML(_ p: Presentation) throws -> String {
        IT.text(try PPTX.export(p), "ppt/slides/slide1.xml")
    }

    private struct Step: Equatable {
        var start: AnimStart
        var delayMs: UInt32
    }

    // Rust: it/trigger_steps.rs::triggered_click_steps_survive_import_edit_save_reopen
    @Test func triggeredClickStepsSurviveImportEditSaveReopen() throws {
        var p = Self.deck()
        let ids = p.slides[0].shapes.map(\.id)
        let starts: [AnimStart] = [.onClick, .withPrevious, .afterPrevious, .onClick, .withPrevious, .onClick]
        for (i, start) in starts.enumerated() {
            var a = Animation.default
            a.shape = ids[2]
            a.trigger = ids[0]
            a.start = start
            a.effect = "appear"
            a.delayMs = UInt32(i) * 100
            p.slides[0].animations.append(a)
        }
        // An independent button and the main sequence must not borrow this button's steps.
        for trigger in [ids[1], nil] as [ShapeId?] {
            for start in [AnimStart.onClick, .afterPrevious, .onClick] {
                var a = Animation.default
                a.shape = ids[2]
                a.trigger = trigger
                a.start = start
                p.slides[0].animations.append(a)
            }
        }
        var q = try IT.round(p)
        for pass in 0 ..< 2 {
            for trigger in [ids[0], ids[1], nil] as [ShapeId?] {
                func state(_ deck: Presentation) -> [Step] {
                    deck.slides[0].animations.filter { $0.trigger == trigger }.map { Step(start: $0.start, delayMs: $0.delayMs) }
                }
                #expect(state(q) == state(p), "trigger \(String(describing: trigger)), pass \(pass)")
            }
            #expect(q.slides[0].animations.count == p.slides[0].animations.count)
            try #require(q.slides[0].shapes.count > 2)
            q.slides[0].shapes[2].name = "Edited content"
            q = try IT.round(q)
        }
        let xml = try Self.slideXML(p)
        #expect(xml.count(of: "nodeType=\"interactiveSeq\"") == 2)
        #expect(xml.count(of: "nodeType=\"clickEffect\"") == 7)
        // The first step in each interactive sequence begins at zero; subsequent steps wait.
        #expect(xml.count(of: "delay=\"indefinite\"") == 5)
    }

    // Rust: it/trigger_steps.rs::triggered_paragraph_build_keeps_a_click_for_each_paragraph
    @Test func triggeredParagraphBuildKeepsAClickForEachParagraph() throws {
        var p = Self.deck()
        let ids = p.slides[0].shapes.map(\.id)
        var a = Animation.default
        a.shape = ids[2]
        a.trigger = ids[0]
        a.textBuild = .byParagraph
        a.start = .onClick
        p.slides[0].animations = [a]
        for q in [p, try IT.round(p)] {
            let xml = try Self.slideXML(q)
            #expect(xml.count(of: "nodeType=\"clickEffect\"") == 3)
            #expect(xml.count(of: "delay=\"indefinite\"") == 2)
            let back = try IT.round(q)
            try #require(back.slides[0].animations.count == 1)
            #expect(back.slides[0].animations[0].textBuild == .byParagraph)
            #expect(back.slides[0].animations[0].trigger == ids[0])
        }
    }
}
