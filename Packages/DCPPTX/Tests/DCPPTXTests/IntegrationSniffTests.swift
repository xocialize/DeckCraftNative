// Port of deckcraft crates/pptx/tests/it/sniff.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). `sniff` must recognise a package wherever the writer put `[Content_Types].xml`: recent
// PowerPoint builds store it as the last zip entry, well past the first few kilobytes.
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationSniffTests {
    private static func samplePPTX() throws -> [UInt8] {
        try PPTX.export(try #require(try IT.sample()))
    }

    /// Re-pack `bytes` with `[Content_Types].xml` moved to the end and a padding part in front, so the
    /// content-types name first appears far beyond any fixed-size prefix.
    private static func contentTypesLast(_ bytes: [UInt8]) throws -> [UInt8] {
        let src = try IT.entries(bytes)
        var files: [(name: String, data: [UInt8], stored: Bool)] = [("ppt/media/padding.bin", [UInt8](repeating: 0, count: 64 * 1024), true)]
        for e in src where e.name != "[Content_Types].xml" { files.append((e.name, e.data, false)) }
        for e in src where e.name == "[Content_Types].xml" { files.append((e.name, e.data, false)) }
        return try IT.zip(files)
    }

    // Rust: it/sniff.rs::sniff_accepts_content_types_anywhere_in_the_archive
    @Test(.enabled(if: IT.hasCorpus)) func sniffAcceptsContentTypesAnywhereInTheArchive() throws {
        let bytes = try Self.samplePPTX()
        #expect(PPTX.sniff(bytes))

        let moved = try Self.contentTypesLast(bytes)
        #expect(!Array(moved.prefix(min(4096, moved.count))).windows(19).contains(Array("[Content_Types].xml".utf8)), "test setup: name must not be in the prefix")
        #expect(PPTX.sniff(moved))
        let p = try PPTX.import(moved)
        #expect(!p.slides.isEmpty)
    }

    // Rust: it/sniff.rs::sniff_rejects_non_packages
    @Test func sniffRejectsNonPackages() throws {
        #expect(!PPTX.sniff([]))
        #expect(!PPTX.sniff(Array("PK".utf8)))
        #expect(!PPTX.sniff(Array("%PDF-1.7 [Content_Types].xml".utf8)))

        let plainZip = try IT.zip([(name: "hello.txt", data: Array("not an office package".utf8))])
        #expect(!PPTX.sniff(plainZip))
    }
}

private extension Array where Element == UInt8 {
    /// `<[u8]>::windows(n)`.
    func windows(_ n: Int) -> [[UInt8]] {
        guard n > 0, count >= n else { return [] }
        return (0 ... count - n).map { Array(self[$0 ..< $0 + n]) }
    }
}
