// DCEngineTests — the text group's `text-native-*` engine scripts: commands a native framework answers
// (spelling through the Mac's spell checker, Rescan Installed Fonts through CoreText's catalog). Engine
// Scripts leaves them out; here each runs twice:
//
// - under deckcraft's own checker alone (`HunspellSpelling`: the Hunspell dictionaries installed, else
//   its list of common misspellings), where every answer is the oracle's but the font catalog's;
// - under the default checker (Hunspell, then `NSSpellChecker`), where the answers a native framework
//   gives are compared by structure: the same kind of answer, the same repeated words, and every word
//   deckcraft flags flagged too (the system checker may find more, and suggests its own corrections).
//
// The final deck is the oracle's in both runs: spelling changes name their words.
import DCCore
@testable import DCEngine
import DCModel
import DCTestSupport
import Foundation
import Testing

private let nativeScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/engine-scripts")).filter { $0.name.hasPrefix("text-native-") }
private let vectors = Fixtures.root.appending(path: "engine")

/// Commands whose answers come from a native framework: compared by structure.
private let nativeAnswers: Set<String> = ["review.spelling", "review.dictionary", "font.rescan"]

/// Run `script` as `deckcraft-cli run` does: its answer lines and the saved deck's presentation.
private func runNative(_ script: CommandScript) throws -> (lines: [String], presentation: [UInt8]) {
    let s = Session()
    if let input = script.input {
        let deck = try #require(Fixtures.oracleCorpus).appending(path: "decks/\(input)").path
        _ = try s.execute("file.open", ["path": .string(deck)])
    } else {
        _ = try s.execute("file.new", .emptyObject)
    }
    var lines: [String] = []
    for (id, params) in script.commands {
        let r = try s.execute(id, try JSONParser.parse(params))
        lines.append("\(id) → \(r.display)")
    }
    let out = scratchDir("native").appending(path: "\(script.name).deckcraft")
    defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
    _ = try s.execute("file.saveAs", ["path": .string(out.path)])
    return (lines, try presentationJSON([UInt8](Data(contentsOf: out))))
}

/// An answer line split into its command and parsed answer.
private func answer(_ line: String) -> (String, JSON?) {
    guard let r = line.range(of: " → ") else { return (line, nil) }
    return (String(line[..<r.lowerBound]), try? JSONParser.parse(String(line[r.upperBound...])))
}

/// The answer's shape: an object's keys with their values' shapes, an array, or a scalar's kind.
private func shape(_ v: JSON?) -> String {
    switch v {
    case nil: "missing"
    case .null?: "null"
    case .bool?: "bool"
    case .string?: "string"
    case .array?: "array"
    case .object(let o)?: "{" + o.entries.map { "\($0.key): \(shape($0.value))" }.sorted().joined(separator: ", ") + "}"
    default: "number"
    }
}

/// A spelling answer's words as `(where, word, repeated)`.
private func words(_ v: JSON?) -> [String] {
    (v?.asArray ?? []).map { w in
        let at = ["slide", "shape", "row", "col", "notes", "para", "start", "end"].map { w.get($0)?.display ?? "-" }.joined(separator: ",")
        return "\(at) \(w.get("word")?.display ?? "") \(w.get("repeated")?.asBool == true ? "repeated" : "")"
    }
}

/// Compare `got` with the oracle's `want` line: exactly, or by structure for a native answer.
private func compare(_ script: String, _ i: Int, _ got: String, _ want: String, native: Bool) {
    let (gid, g) = answer(blankTimestamps(got))
    let (wid, w) = answer(blankTimestamps(want))
    #expect(gid == wid, "\(script) line \(i + 1): \(gid) where the oracle ran \(wid)")
    guard native && nativeAnswers.contains(gid) else {
        if got != want { Issue.record("\(script) line \(i + 1):\n  ours:   \(got)\n  oracle: \(want)") }
        return
    }
    if gid == "review.spelling" {
        let (ours, theirs) = (words(g), words(w))
        // The same repeated words; every word deckcraft flags is flagged by the system checker too.
        #expect(ours.filter { $0.hasSuffix("repeated") } == theirs.filter { $0.hasSuffix("repeated") }, "\(script) line \(i + 1): repeated words")
        for t in theirs where !ours.contains(t) { Issue.record("\(script) line \(i + 1): the system checker missed \(t)") }
        let allowed: Set<String> = ["slide", "shape", "row", "col", "notes", "para", "start", "end", "word", "lang", "suggestions", "repeated", "deleteFrom"]
        for v in g?.asArray ?? [] {
            let keys = Set(v.asObject?.entries.map(\.key) ?? [])
            #expect(keys.isSubset(of: allowed), "\(script) line \(i + 1): \(keys)")
        }
    } else {
        #expect(shape(g) == shape(w), "\(script) line \(i + 1): \(got) is not shaped like the oracle's \(want)")
    }
}

@Suite("Text native scripts", .enabled(if: FileManager.default.fileExists(atPath: vectors.path) && Fixtures.oracleCorpus != nil, "no engine vectors or corpus"))
struct TextNativeScriptTests {
    @Test("Every text-native script is found")
    func scriptsExist() {
        #expect(!nativeScripts.isEmpty, "no text-native-* scripts in Tools/oracle/engine-scripts")
    }

    private func expected(_ script: CommandScript) throws -> ([String], [UInt8]) {
        let text = try String(contentsOf: vectors.appending(path: "\(script.name).results.txt"), encoding: .utf8)
        let deck = try [UInt8](Data(contentsOf: vectors.appending(path: "\(script.name).deckcraft")))
        return (text.components(separatedBy: "\n").filter { !$0.isEmpty }, try presentationJSON(deck))
    }

    @Test("Under deckcraft's own checker the answers are the oracle's", arguments: nativeScripts)
    func deckcraftsChecker(_ script: CommandScript) throws {
        let missing = unported(script.needs)
        if !missing.isEmpty { try Test.cancel("waits for unported commands: \(missing.joined(separator: ", "))") }
        let (want, wantDeck) = try expected(script)
        let (lines, deck) = try Spell.$checker.withValue(HunspellSpelling()) { try runNative(script) }
        #expect(lines.count == want.count)
        for (i, (g, w)) in zip(lines, want).enumerated() {
            // Only the font catalog differs: CoreText's, not deckcraft's own scan.
            compare(script.name, i, g, w, native: answer(g).0 == "font.rescan")
        }
        #expect(deck == wantDeck, "\(script.name): presentation \(firstDifference(deck, wantDeck))")
    }

    @Test("Under the system checker the answers have the oracle's shape", arguments: nativeScripts)
    func systemChecker(_ script: CommandScript) throws {
        let missing = unported(script.needs)
        if !missing.isEmpty { try Test.cancel("waits for unported commands: \(missing.joined(separator: ", "))") }
        let (want, wantDeck) = try expected(script)
        let (lines, deck) = try Spell.$checker.withValue(Spell.defaultChecker) { try runNative(script) }
        #expect(lines.count == want.count)
        for (i, (g, w)) in zip(lines, want).enumerated() { compare(script.name, i, g, w, native: true) }
        #expect(deck == wantDeck, "\(script.name): presentation \(firstDifference(deck, wantDeck))")
    }
}
