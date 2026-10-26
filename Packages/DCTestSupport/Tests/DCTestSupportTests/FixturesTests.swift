import DCTestSupport
import Foundation
import Testing

@Suite struct UpstreamPinTests {
    @Test func readsThisCheckoutsPin() throws {
        let pin = try #require(UpstreamPin.current())
        #expect(pin.short.count == 8)
    }

    @Test func skipsCommentsAndBlankLines() throws {
        let pin = try UpstreamPin(envFile: """
            # comment

            DECKCRAFT_COMMIT=27009cd941b22cb0788cd5040f9fad91472230c7
            DECKCRAFT_DATE=2026-10-26
            CRAFT_FONTS_COMMIT=aced4137c022f1f587624d48e81ec77e1914a9cc
            """)
        #expect(pin.short == "27009cd9")
        #expect(pin.deckcraftDate == "2026-10-26")
    }

    @Test func refusesAMissingKeyOrAShortCommit() {
        #expect(throws: UpstreamPin.ParseError.missing("CRAFT_FONTS_COMMIT")) {
            try UpstreamPin(envFile: "DECKCRAFT_COMMIT=27009cd941b22cb0788cd5040f9fad91472230c7\nDECKCRAFT_DATE=x")
        }
        #expect(throws: UpstreamPin.ParseError.notACommit("DECKCRAFT_COMMIT")) {
            try UpstreamPin(envFile: "DECKCRAFT_COMMIT=27009cd9\nDECKCRAFT_DATE=x\nCRAFT_FONTS_COMMIT=aced413")
        }
    }
}

@Suite struct OracleCorpusTests {
    struct Manifest: Decodable {
        struct Commit: Decodable { var commit: String }
        var deckcraft: Commit
        var craftFonts: Commit
    }

    /// The corpus on disk was generated from the commits this checkout pins.
    @Test(.enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
    func corpusMatchesThePin() throws {
        let dir = try #require(Fixtures.oracleCorpus)
        let pin = try #require(UpstreamPin.current())
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appending(path: "manifest.json")))
        #expect(manifest.deckcraft.commit == pin.deckcraftCommit)
        #expect(manifest.craftFonts.commit == pin.craftFontsCommit)
    }

    /// Every file the corpus lists is present with the checksum it was written with.
    @Test(.enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
    func corpusListsEveryFile() throws {
        let dir = try #require(Fixtures.oracleCorpus)
        let sums = try String(contentsOf: dir.appending(path: "SHA256SUMS"), encoding: .utf8)
        let paths = sums.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "  ", maxSplits: 1).last }
        #expect(paths.count > 10)
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: String(path)).path), "\(path)")
        }
    }
}
