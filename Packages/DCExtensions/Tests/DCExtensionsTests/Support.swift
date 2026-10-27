// DCExtensionsTests — the corpus decks and the damaged files the extension tests read.
import DCCore
import DCEngine
import DCTestSupport
import DCZip
import Foundation
import Testing

enum Corpus {
    /// `oracle/<pin>/decks`, or nil without the fixtures (tests that need it skip).
    static var decks: URL? { Fixtures.oracleCorpus?.appending(path: "decks", directoryHint: .isDirectory) }

    /// Every `.deckcraft` and `.pptx` deck in the corpus.
    static func files() -> [URL] {
        guard let dir = decks, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".deckcraft") || $0.hasSuffix(".pptx") }.sorted().map { dir.appending(path: $0) }
    }

    /// The deck's slide titles as the oracle recorded them (`<name>.info.json`, written for `<name>.deckcraft`).
    static func titles(_ name: String) -> [String]? {
        guard let dir = decks, let data = try? Data(contentsOf: dir.appending(path: "\(name).info.json")),
              let json = try? JSONParser.parse([UInt8](data)), let slides = json.get("slides")?.asArray else { return nil }
        return slides.map { $0.get("title")?.asStr ?? "" }
    }

    /// The deck's name without `.from-pptx` and the extension.
    static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".from-pptx", with: "")
    }
}

/// A scratch folder for one test, removed when it goes.
final class Scratch {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "dcext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Files no extension can read, each named as a presentation would be.
    func damaged() throws -> [URL] {
        var out: [URL] = []
        out.append(try write("empty.pptx", []))
        out.append(try write("noise.pptx", (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }))
        out.append(try write("text.deckcraft", Array("not a presentation\n".utf8)))
        out.append(try write("pk.pptx", [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 64)))
        var z = ZipWriter()
        try z.add("hello.txt", Array("a zip, but no presentation".utf8))
        out.append(try write("zip.potx", try z.finish()))
        if let review = Corpus.decks?.appending(path: "review.pptx"), let bytes = try? [UInt8](Data(contentsOf: review)) {
            out.append(try write("truncated.ppsx", Array(bytes.prefix(bytes.count / 2))))
            // The directory survives, its parts don't.
            out.append(try write("zeroed.pptx", bytes.enumerated().map { $0.offset < bytes.count - 2048 && $0.offset > 64 ? 0 : $0.element }))
        }
        if let deck = Corpus.decks?.appending(path: "review.deckcraft"), let bytes = try? [UInt8](Data(contentsOf: deck)) {
            out.append(try write("truncated.deckcraft", Array(bytes.prefix(bytes.count / 3))))
        }
        out.append(dir.appending(path: "missing.pptx"))
        let folder = dir.appending(path: "folder.pptx", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        out.append(folder)
        return out
    }
}
