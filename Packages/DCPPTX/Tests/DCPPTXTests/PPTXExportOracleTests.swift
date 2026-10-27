// DCPPTXTests — Wave 3's acceptance against the Rust oracle, deck by deck over the corpus:
// - import: Swift reading deckcraft's `.pptx` gives the model deckcraft read (`.from-pptx.deckcraft`), to the
//   byte of `presentation.json`;
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

@Suite struct PPTXExportOracleTests {
    /// Swift's export of the deck is deckcraft's export of it, part for part.
    @Test(arguments: corpusDecks()) func exportMatchesOracle(_ name: String) throws {
        let deck = try DeckFormat.load(bytes(#require(deckFile(name, "deckcraft"))))
        let mine = try parts(PPTX.export(deck))
        let theirs = try parts(bytes(#require(deckFile(name, "pptx"))))
        #expect(Set(mine.keys) == Set(theirs.keys), "\(name): parts \(Set(mine.keys).symmetricDifference(theirs.keys).sorted())")
        for k in Set(mine.keys).intersection(theirs.keys).sorted() {
            let a = mine[k] ?? [], b = theirs[k] ?? []
            #expect(a == b, "\(name): \(k) differs \(firstDifference(a, b))")
        }
    }

    /// What Swift writes validates against ECMA-376 Transitional (markup compatibility applied, Office
    /// extension parts skipped), as deckcraft's own packages do.
    @Test(arguments: corpusDecks()) func exportValidates(_ name: String) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else { return }
        let deck = try DeckFormat.load(bytes(#require(deckFile(name, "deckcraft"))))
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "\(name).pptx")
        try Data(PPTX.export(deck)).write(to: file)
        let script = Fixtures.repositoryRoot.appending(path: "Tools/pptx/validate.sh")
        let (status, output) = try run(URL(filePath: "/bin/zsh"), [script.path, file.path])
        #expect(status == 0, "\(name):\n\(output.split(separator: "\n").filter { !$0.contains("skipped") }.joined(separator: "\n"))")
    }

    /// deckcraft reads the package Swift writes to the model it reads from its own.
    @Test(arguments: corpusDecks()) func oracleReadsSwiftPackage(_ name: String) throws {
        guard let bin = oracleBinary else { return }
        let deck = try DeckFormat.load(bytes(#require(deckFile(name, "deckcraft"))))
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pptx = dir.appending(path: "\(name).pptx"), back = dir.appending(path: "\(name).deckcraft")
        try Data(PPTX.export(deck)).write(to: pptx)
        let (status, output) = try run(bin, ["convert", pptx.path, back.path])
        try #require(status == 0, "\(name): deckcraft-cli convert failed: \(output)")
        let a = try #require(parts(bytes(back))["presentation.json"])
        let fromPPTX = try #require(deckFile(name, "from-pptx.deckcraft"))
        let b = try #require(parts(bytes(fromPPTX))["presentation.json"])
        #expect(a == b, "\(name): deckcraft reads the Swift package differently \(firstDifference(a, b))")
    }
}
