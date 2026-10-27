// The oracle check for Wave 1: every `.deckcraft` the pinned Rust deckcraft-cli wrote opens here, and
// saving it again writes the same `presentation.json` bytes; and the Rust app opens what this port writes.
import DCCore
import DCFormat
import DCModel
import DCTestSupport
import DCZip
import Foundation
import Testing

private let corpus = Fixtures.oracleCorpus

/// Every deck in the corpus (`decks/*.deckcraft`, the `.from-pptx` re-reads included).
private func decks() throws -> [URL] {
    guard let dir = corpus?.appending(path: "decks") else { return [] }
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "deckcraft" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// The `presentation` member of a file's `presentation.json`, re-serialised as serde_json writes it.
/// The manifest's `generator` names the writing app, so it is left out of the comparison.
private func presentationJSON(_ file: [UInt8]) throws -> [UInt8] {
    let z = try ZipReader(file)
    let json = try z.read(named: "presentation.json", max: 1 << 30)
    let manifest = try JSONParser.parse(json)
    let p = try #require(manifest["presentation"])
    return JSONWriter(nonFiniteAsZero: true).bytes(p)
}

/// The deckcraft-cli the corpus was made with, when `Tools/oracle/oracle.sh build` has run.
private func oracleBinary() -> URL? {
    let path = ProcessInfo.processInfo.environment["CARGO_TARGET_DIR"].map { "\($0)/release/deckcraft-cli" }
        ?? "\(NSHomeDirectory())/Library/Caches/DeckCraftNative/cargo-target/release/deckcraft-cli"
    guard FileManager.default.isExecutableFile(atPath: path),
          let pin = UpstreamPin.current(),
          (try? String(contentsOfFile: path + ".pin", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == pin.deckcraftCommit
    else { return nil }
    return URL(filePath: path)
}

@Suite(.enabled(if: corpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
struct OracleRoundTripTests {
    @Test func everyCorpusDeckLoadsAndSavesTheSameJSON() throws {
        let files = try decks()
        #expect(files.count >= 8)
        for url in files {
            let bytes = try [UInt8](Data(contentsOf: url))
            #expect(DeckFormat.sniff(bytes), "\(url.lastPathComponent)")
            let (p, damaged) = try DeckFormat.loadChecked(bytes)
            #expect(damaged.isEmpty, "\(url.lastPathComponent): \(damaged)")
            let saved = try DeckFormat.save(p)
            let want = try presentationJSON(bytes)
            let got = try presentationJSON(saved)
            if got != want {
                let w = String(decoding: want, as: UTF8.self)
                let g = String(decoding: got, as: UTF8.self)
                let at = zip(w.utf8, g.utf8).prefix { $0 == $1 }.count
                let from = Swift.max(0, at - 120)
                Issue.record("""
                    \(url.lastPathComponent): presentation.json differs at byte \(at) of \(want.count)/\(got.count)
                    want …\(String(decoding: Array(w.utf8)[from ..< Swift.min(w.utf8.count, at + 120)], as: UTF8.self))
                    got  …\(String(decoding: Array(g.utf8)[from ..< Swift.min(g.utf8.count, at + 120)], as: UTF8.self))
                    """)
            }
        }
    }

    /// The JSON on disk is already serde_json's canonical output, so reading and re-writing the raw
    /// value gives the file's own bytes: the writer's check, independent of the model.
    @Test func theWriterReproducesTheOraclesBytes() throws {
        for url in try decks() {
            let z = try ZipReader(try [UInt8](Data(contentsOf: url)))
            let json = try z.read(named: "presentation.json", max: 1 << 30)
            #expect(JSONWriter().bytes(try JSONParser.parse(json)) == json, "\(url.lastPathComponent)")
        }
    }

    /// The Rust app reads what this port writes: `deckcraft-cli info` on our save of each deck says what
    /// it said about the original.
    @Test(.enabled(if: oracleBinary() != nil, "no oracle binary at the pin: run Tools/oracle/oracle.sh build"))
    func theRustAppOpensOurFiles() throws {
        let bin = try #require(oracleBinary())
        let tmp = FileManager.default.temporaryDirectory.appending(path: "dcformat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func info(_ file: URL) throws -> JSON {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["info", file.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try proc.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0, "\(file.lastPathComponent)")
            // `path` names the file asked about, so it is left out.
            guard case .object(var o) = try JSONParser.parse([UInt8](out)) else { return .null }
            o.remove("path")
            return .object(o)
        }
        for url in try decks() {
            let p = try DeckFormat.load(try [UInt8](Data(contentsOf: url)))
            let ours = tmp.appending(path: url.lastPathComponent)
            try Data(DeckFormat.save(p)).write(to: ours)
            #expect(try info(ours) == info(url), "\(url.lastPathComponent)")
        }
    }
}
