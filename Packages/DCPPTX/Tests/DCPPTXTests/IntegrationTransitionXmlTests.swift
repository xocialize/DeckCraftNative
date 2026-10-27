// Port of deckcraft crates/pptx/tests/it/transition_xml.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Transition XML as other applications write it, spliced into an exported deck
// and read back.
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationTransitionXmlTests {
    private static let p159 = "http://schemas.microsoft.com/office/powerpoint/2015/09/main"
    private static let p14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"

    /// Exports a one-slide deck, replaces the slide's `mc:AlternateContent` transition block with
    /// `xml` and returns the imported transition of that slide.
    private static func importWith(_ xml: String) throws -> Transition {
        var p = newPresentation(nil)
        var t = Transition.default
        t.kind = "fade"
        t.durationMs = 3000
        p.slides[0].transition = t
        var es = try IT.entries(PPTX.export(p))
        let si = try #require(es.firstIndex { $0.name == "ppt/slides/slide1.xml" }, "slide1")
        let s = String(decoding: es[si].data, as: UTF8.self)
        let tr = try #require(s.byteFind("<p:transition"), "transition")
        let a = try #require(s.byteRFind("<mc:AlternateContent", before: tr), "mc start")
        let end = "</mc:AlternateContent>"
        let b = try #require(s.byteFind(end, from: tr), "mc end") + end.utf8.count
        es[si].data = Array((s.bytes(0, a) + xml + s.bytes(b)).utf8)
        let q = try PPTX.import(IT.zip(es))
        return try #require(q.slides[0].transition, "transition")
    }

    private static func mc(_ choiceNS: String, _ req: String, _ choice: String, _ fallback: String) -> String {
        #"<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:\#(req)="\#(choiceNS)" Requires="\#(req)">\#(choice)</mc:Choice><mc:Fallback>\#(fallback)</mc:Fallback></mc:AlternateContent>"#
    }

    // Rust: it/transition_xml.rs::powerpoint_half_second_morph_without_spd
    /// PowerPoint 2021/2024 write a 0.5 s Morph with neither `spd` nor `p14:dur` (issue #117).
    @Test func powerpointHalfSecondMorphWithoutSpd() throws {
        let xml = Self.mc(Self.p159, "p159", #"<p:transition><p159:morph option="byObject"/></p:transition>"#, "<p:transition><p:fade/></p:transition>")
        let t = try Self.importWith(xml)
        #expect(t.kind == "morph" && t.durationMs == 500, "\(t.kind) \(t.durationMs)")
    }

    // Rust: it/transition_xml.rs::missing_spd_is_fast_for_a_plain_transition
    @Test func missingSpdIsFastForAPlainTransition() throws {
        let t = try Self.importWith("<p:transition><p:fade/></p:transition>")
        #expect(t.kind == "fade" && t.durationMs == 500, "\(t.kind) \(t.durationMs)")
    }

    // Rust: it/transition_xml.rs::spd_and_dur_still_apply
    @Test func spdAndDurStillApply() throws {
        var t = try Self.importWith(#"<p:transition spd="med"><p:fade/></p:transition>"#)
        #expect(t.durationMs == 750)
        let xml = Self.mc(
            Self.p159,
            "p159",
            #"<p:transition xmlns:p14="\#(Self.p14)" spd="slow" p14:dur="1250"><p159:morph option="byObject"/></p:transition>"#,
            #"<p:transition spd="slow"><p:fade/></p:transition>"#
        )
        t = try Self.importWith(xml)
        #expect(t.kind == "morph" && t.durationMs == 1250, "\(t.kind) \(t.durationMs)")
    }
}
