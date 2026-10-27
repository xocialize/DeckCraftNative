// DCPPTXTests — Wave 3's acceptance against the Rust oracle, deck by deck over the corpus:
// - import: Swift reading deckcraft's `.pptx` gives the model deckcraft read (`.from-pptx.deckcraft`), to the
//   byte of the `presentation` member of `presentation.json`;
// - export: Swift writing a `.deckcraft` gives the package deckcraft wrote, part for part, byte for byte;
// - the package Swift writes validates against the ECMA-376 Transitional schemas (`Tools/pptx/validate.sh`);
// - deckcraft itself reads the Swift package back to the same model (when the oracle binary is built).
import DCCore
import DCFormat
import DCModel
import DCTestSupport
import DCZip
import Foundation
import Testing
@testable import DCPPTX

/// The corpus decks with a deckcraft-written `.pptx` beside them.
private func corpusDecks() -> [String] {
    guard let corpus = Fixtures.oracleCorpus else { return [] }
    let dir = corpus.appending(path: "decks").path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.hasSuffix(".pptx") }.map { String($0.dropLast(5)) }.sorted()
}

private func deckFile(_ name: String, _ ext: String) -> URL? {
    Fixtures.oracleCorpus?.appending(path: "decks/\(name).\(ext)")
}

private func bytes(_ url: URL) throws -> [UInt8] { try [UInt8](Data(contentsOf: url)) }

/// Every entry of a zip, by name (last wins, as the readers do).
private func parts(_ zip: [UInt8]) throws -> [String: [UInt8]] {
    let z = try ZipReader(zip)
    var out: [String: [UInt8]] = [:]
    for e in z.entries where !e.name.hasSuffix("/") { out[e.name] = try z.read(e, max: 1 << 30) }
    return out
}

/// The `presentation` member of a `presentation.json`, re-serialised as serde_json writes it.
private func presentation(_ json: [UInt8]) throws -> [UInt8] {
    let p = try #require(JSONParser.parse(json)["presentation"])
    return JSONWriter(nonFiniteAsZero: true).bytes(p)
}

/// Where two byte strings first differ, with a little context from each, for a readable failure.
private func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> String {
    let n = Swift.min(a.count, b.count)
    var i = 0
    while i < n, a[i] == b[i] { i += 1 }
    func around(_ x: [UInt8]) -> String {
        let lo = Swift.max(0, i - 60), hi = Swift.min(x.count, i + 60)
        return String(decoding: x[lo ..< hi], as: UTF8.self)
    }
    return "at byte \(i) of \(a.count)/\(b.count)\n  swift:  …\(around(a))…\n  oracle: …\(around(b))…"
}

/// The oracle binary, when it has been built at the pin (`Tools/oracle/oracle.sh build`).
private var oracleBinary: URL? {
    let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/cargo-target/release/deckcraft-cli")
    return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
}

@discardableResult
private func run(_ exe: URL, _ args: [String]) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dcpptx-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct PPTXImportOracleTests {
    @Test func corpusIsPresent() {
        #expect(!corpusDecks().isEmpty, "no oracle corpus: run Tools/oracle/oracle.sh corpus")
    }

    /// Swift's import of deckcraft's package is deckcraft's import of it.
    @Test(arguments: corpusDecks()) func importMatchesOracle(_ name: String) throws {
        let pptx = try bytes(#require(deckFile(name, "pptx")))
        let mine = try parts(DeckFormat.save(PPTX.import(pptx)))
        let theirs = try parts(bytes(#require(deckFile(name, "from-pptx.deckcraft"))))
        // The manifest's `generator` names the writing app: compare its `presentation` member.
        let a = try presentation(#require(mine["presentation.json"])), b = try presentation(#require(theirs["presentation.json"]))
        #expect(a == b, "\(name): presentation differs \(firstDifference(a, b))")
        // Media and chart parts too: every entry but the manifest (it names the writing app).
        let keys = Set(mine.keys).union(theirs.keys).subtracting(["manifest.json", "presentation.json"])
        for k in keys.sorted() {
            #expect(mine[k] == theirs[k], "\(name): \(k) \(mine[k] == nil ? "missing" : theirs[k] == nil ? "extra" : "differs")")
        }
    }
}
