// Port of deckcraft crates/pptx/tests/it/anchor.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Text anchoring of shapes without an `anchor` of their own: the model centres a shape's
// text, a file without one puts it at the top, whatever the theme's shape defaults say.
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationAnchorTests {
    /// Anchors of the shapes with text that aren't placeholders, text boxes or tables.
    private static func anchors(_ p: Presentation) -> [Anchor?] {
        p.slides.flatMap(\.shapes)
            .filter { s in
                if s.ph != nil || s.textBox { return false }
                if case .table = s.kind { return false }
                return true
            }
            .compactMap { $0.text.map(\.body.anchor) }
    }

    // Rust: it/anchor.rs::shapes_keep_their_middle_anchor_and_files_without_one_anchor_at_the_top
    // The sample deck is the engine's (`open_sample`), read from the oracle corpus without the engine.
    @Test(.enabled(if: IT.hasCorpus))
    func shapesKeepTheirMiddleAnchorAndFilesWithoutOneAnchorAtTheTop() throws {
        let p = try #require(try IT.sample())
        #expect(Self.anchors(p).contains(nil), "the sample has shapes with the model's default anchor")
        let bytes = try PPTX.export(p)

        // Written explicitly, so PowerPoint (which reads a missing anchor as top) centres them too.
        let back = try PPTX.import(bytes)
        #expect(Self.anchors(back) == Self.anchors(p), "the middle anchor survives (as the model's default)")

        // The same file without the anchors: their text sits at the top.
        let bare = try IT.rewriteXML(bytes) { n, x in n.hasPrefix("ppt/slides/slide") ? x.replace(#" anchor="ctr""#, "") : x }
        var a = Self.anchors(try PPTX.import(bare))
        #expect(a.allSatisfy { $0 == .top }, "\(a)")

        // Also when the theme's shape defaults centre new shapes, as Office's themes do: PowerPoint
        // for Mac draws `<a:bodyPr/>` at the top under such an `spDef` (synthetic probe exported as PDF).
        let themed = try IT.rewriteXML(bare) { n, x in
            n.hasPrefix("ppt/theme/")
                ? x.replace(
                    "<a:objectDefaults/>",
                    #"<a:objectDefaults><a:spDef><a:spPr/><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/></a:spDef></a:objectDefaults>"#
                )
                : x
        }
        a = Self.anchors(try PPTX.import(themed))
        #expect(a.allSatisfy { $0 == .top }, "\(a)")
    }
}
