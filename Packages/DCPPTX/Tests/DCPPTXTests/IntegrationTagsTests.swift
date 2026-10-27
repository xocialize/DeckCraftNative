// Port of deckcraft crates/pptx/tests/it/tags.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Add-in tags (`p:custDataLst` → `ppt/tags/tagN.xml`) on the presentation, slides and shapes
// survive a save and reopen.
import DCCore
import DCModel
import DCZip
import Testing
@testable import DCPPTX

@Suite struct IntegrationTagsTests {
    private static func t(_ n: String, _ v: String) -> Pair<String, String> { Pair(n, v) }

    // Rust: it/tags.rs::tags_survive_round_trip
    @Test(.enabled(if: IT.hasCorpus)) func tagsSurviveRoundTrip() throws {
        var p = try #require(try IT.sample())
        p.tags = [Self.t("THINKCELLPRESENTATIONDONOTDELETE", "<xml & stuff>")]
        p.slides[0].tags = [Self.t("TIMING", "5"), Self.t("SECTION", "Intro")]
        let shapeId = p.slides[0].shapes[0].id
        p.slides[0].shapes[0].tags = [Self.t("THINKCELLSHAPEDONOTDELETE", "t!abc")]

        let bytes = try PPTX.export(p)
        let z = try ZipReader(bytes)
        let ct = String(decoding: try z.read(named: "[Content_Types].xml", max: .max), as: UTF8.self)
        #expect(ct.has("presentationml.tags+xml"))
        #expect(z.entries.filter { $0.name.hasPrefix("ppt/tags/") }.count == 3)

        let back = try PPTX.import(bytes)
        #expect(back.tags == p.tags)
        #expect(back.slides[0].tags == p.slides[0].tags)
        let first = back.slides[0].shapes[0]
        #expect(first.name == (p.slides[0].shapes.first { $0.id == shapeId }?.name ?? ""))
        #expect(first.tags == [Self.t("THINKCELLSHAPEDONOTDELETE", "t!abc")])
        #expect(back.slides.dropFirst().allSatisfy { $0.tags.isEmpty })
    }
}
