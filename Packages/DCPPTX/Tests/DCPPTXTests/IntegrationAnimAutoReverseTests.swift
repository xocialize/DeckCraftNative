// Port of deckcraft crates/pptx/tests/it/anim_auto_reverse.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). "Auto-reverse" is written by PowerPoint on the behaviour time nodes, not on the
// effect node.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationAnimAutoReverseTests {
    /// A deck animating one shape with `effect`, with `autoRev="1"` spliced onto the first `p:cTn` after
    /// `behaviour` in its slide XML, read back: each animation's `autoReverse`.
    private static func deckWith(_ effect: String, _ behaviour: String) throws -> [Bool] {
        var p = newPresentation(nil)
        let n = p.allocId()
        let id = ShapeId(try #require(n, "id"))
        var shape = Shape.default
        shape.id = id
        shape.name = "Box"
        shape.xfrm = Xfrm(10.0, 10.0, 200.0, 100.0)
        p.slides[0].shapes = [shape]
        var a = Animation.default
        a.shape = id
        a.class = .emphasis
        a.effect = effect
        a.durationMs = 1000
        p.slides[0].animations.append(a)
        let bytes = try IT.zip(IT.entries(PPTX.export(p)).map { e in
            guard e.name == "ppt/slides/slide1.xml" else { return e }
            let xml = String(decoding: e.data, as: UTF8.self)
            let at = try #require(xml.byteFind(behaviour), "behaviour written")
            let cb = try #require(xml.byteFind("<p:cTn ", from: at), "behaviour node")
            return (e.name, Array((xml.bytes(0, cb) + #"<p:cTn autoRev="1" "# + xml.bytes(cb + "<p:cTn ".utf8.count)).utf8))
        })
        let q = try PPTX.import(bytes)
        return q.slides[0].animations.map(\.autoReverse)
    }

    // Rust: it/anim_auto_reverse.rs::grow_shrink_reads_auto_reverse_from_its_behaviour_node
    @Test func growShrinkReadsAutoReverseFromItsBehaviourNode() throws {
        #expect(try Self.deckWith("growShrink", "<p:animScale>") == [true])
    }

    // Rust: it/anim_auto_reverse.rs::color_pulse_behaviour_auto_reverse_is_not_the_option
    @Test func colorPulseBehaviourAutoReverseIsNotTheOption() throws {
        #expect(try Self.deckWith("colorPulse", "<p:animClr ") == [false])
    }
}
