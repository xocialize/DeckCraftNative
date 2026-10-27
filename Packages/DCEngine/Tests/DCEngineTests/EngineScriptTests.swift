// DCEngineTests — engine oracle parity: every command script runs through `Session.execute` from the same
// start as the pinned deckcraft-cli's `run`, and gives the same answers and the same deck.
//
// - `Tools/oracle/engine-scripts/<name>.cmds`, run by `oracle.sh engine-vectors` with `run --print --save`:
//   each answer is compared with `<name>.results.txt` as the CLI prints it (`{id} → {compact JSON}`, keys
//   sorted), and the final deck's `presentation` member with `<name>.deckcraft`.
// - `Tools/oracle/scripts/<name>.cmds`, the corpus scripts (`run --cmd … --save`): the final deck is
//   compared with the corpus's `decks/<name>.deckcraft`.
// - The sample deck (`run --sample --save`): the corpus's `decks/sample.deckcraft`.
//
// A script that uses a command no module registers yet is skipped, naming the commands it waits for.
import DCCore
@testable import DCEngine
import DCFormat
import DCModel
import DCTestSupport
import Foundation
import Testing

/// A command script: an optional corpus deck it starts from, and `id` / `id=json` lines.
struct CommandScript: Sendable, CustomStringConvertible {
    var name: String
    var input: String?
    var commands: [(String, String)]
    /// Commands the oracle refuses (`!id=json` lines, error cases): indices into `commands`. The oracle runs
    /// each with the commands before it and records its error in `<name>.errors.txt`; the main run leaves
    /// them out.
    var refused: Set<Int> = []

    var description: String { name }

    init(name: String, text: String) {
        self.name = name
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let first = lines.first, first.hasPrefix("# in: ") { input = String(first.dropFirst("# in: ".count)) }
        commands = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { raw in
            let line = raw.hasPrefix("!") ? String(raw.dropFirst()) : raw
            guard let eq = line.firstIndex(of: "=") else { return (line, "{}") }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }
        refused = Set(lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.enumerated().filter { $0.element.hasPrefix("!") }.map(\.offset))
    }

    /// Every command the run needs, the opening and saving ones included.
    var needs: [String] { [input == nil ? "file.new" : "file.open", "file.saveAs"] + commands.map(\.0) }

    static func load(_ dir: URL) -> [CommandScript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "cmds" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return CommandScript(name: url.deletingPathExtension().lastPathComponent, text: text)
        }
    }
}

/// `<group>-native-*` scripts diverge on purpose (a native framework answers): their group's own tests
/// compare them structurally, so they are left out here.
private let engineScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/engine-scripts")).filter { !$0.name.contains("-native-") }
private let corpusScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/scripts"))
private let engineVectors = Fixtures.root.appending(path: "engine")

/// Run `script` as `deckcraft-cli run` does; returns the printed answer lines, the saved file's bytes and
/// the refused commands' errors (`id\tmessage`, as `oracle.sh engine-vectors` records them).
private func run(_ script: CommandScript, deckDir: URL?) throws -> (lines: [String], saved: [UInt8], errors: [String]) {
    let s = Session()
    if let input = script.input {
        let path = try #require(deckDir).appending(path: input).path
        _ = try s.execute("file.open", ["path": .string(path)])
    } else {
        _ = try s.execute("file.new", .emptyObject)
    }
    var lines: [String] = []
    var errors: [String] = []
    for (i, (id, params)) in script.commands.enumerated() {
        let p: JSON
        do { p = try JSONParser.parse(params) } catch { throw EngineError.other("\(id): bad JSON: \(error)") }
        if script.refused.contains(i) {
            do {
                let r = try s.execute(id, p)
                errors.append("\(id)=\(params)\tsucceeded: \(r.display)")
            } catch {
                errors.append("\(id)=\(params)\t\(error)")
            }
            continue
        }
        do {
            let r = try s.execute(id, p)
            lines.append("\(id) → \(r.display)")
        } catch {
            throw EngineError.other("\(script.name): `\(id)` failed: \(error)")
        }
    }
    let out = scratchDir("script").appending(path: "\(script.name).deckcraft")
    defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
    _ = try s.execute("file.saveAs", ["path": .string(out.path)])
    return (lines, try [UInt8](Data(contentsOf: out)), errors)
}

private func skipUnported(_ needs: [String]) throws {
    let missing = Array(Set(unported(needs))).sorted()
    if !missing.isEmpty {
        print("skipped: waits for unported commands: \(missing.joined(separator: ", "))")
        try Test.cancel("waits for unported commands: \(missing.joined(separator: ", "))")
    }
}

@Suite("Engine scripts")
struct EngineScriptTests {
    @Test("Every engine script is found")
    func scriptsExist() {
        #expect(!engineScripts.isEmpty, "no engine scripts in Tools/oracle/engine-scripts")
    }

    @Test("Engine scripts give the oracle's answers and deck", .enabled(if: FileManager.default.fileExists(atPath: engineVectors.path), "no engine vectors: run Tools/oracle/oracle.sh engine-vectors"), arguments: engineScripts)
    func engineScript(_ script: CommandScript) throws {
        try skipUnported(script.needs)
        let results = engineVectors.appending(path: "\(script.name).results.txt")
        guard let expected = try? String(contentsOf: results, encoding: .utf8) else {
            try Test.cancel("no oracle answers for \(script.name): run Tools/oracle/oracle.sh engine-vectors \(script.name)")
        }
        let want = expected.components(separatedBy: "\n").filter { !$0.isEmpty }.map(blankTimestamps)
        let deckDir = Fixtures.oracleCorpus?.appending(path: "decks")
        let (lines, saved, errors) = try run(script, deckDir: deckDir)
        let got = lines.map(blankTimestamps)
        #expect(got.count == want.count, "\(script.name): \(got.count) answers, the oracle printed \(want.count)")
        for (i, (g, w)) in zip(got, want).enumerated() where g != w {
            Issue.record("\(script.name) line \(i + 1):\n  ours:   \(g)\n  oracle: \(w)")
        }
        // Refused commands: the same error as the oracle's (the refusal leaves the document as it was).
        let wantErrors = (try? String(contentsOf: engineVectors.appending(path: "\(script.name).errors.txt"), encoding: .utf8))
            .map { $0.components(separatedBy: "\n").filter { !$0.isEmpty } } ?? []
        #expect(errors.count == wantErrors.count, "\(script.name): \(errors.count) refusals, the oracle recorded \(wantErrors.count)")
        for (i, (g, w)) in zip(errors, wantErrors).enumerated() where g != w {
            Issue.record("\(script.name) refusal \(i + 1):\n  ours:   \(g)\n  oracle: \(w)")
        }
        let oracleDeck = try [UInt8](Data(contentsOf: engineVectors.appending(path: "\(script.name).deckcraft")))
        let a = try presentationJSON(saved)
        let b = try presentationJSON(oracleDeck)
        #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
        print("engine script \(script.name): \(got.count) answers and \(a.count) bytes of presentation compared")
    }

    @Test("Corpus scripts make the corpus decks", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"), arguments: corpusScripts)
    func corpusScript(_ script: CommandScript) throws {
        try skipUnported(script.needs)
        let corpus = try #require(Fixtures.oracleCorpus)
        let (_, saved, _) = try run(script, deckDir: corpus.appending(path: "decks"))
        let oracleDeck = try [UInt8](Data(contentsOf: corpus.appending(path: "decks/\(script.name).deckcraft")))
        let a = try presentationJSON(saved)
        let b = try presentationJSON(oracleDeck)
        #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
    }

    @Test("The sample deck is the corpus's sample.deckcraft", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
    func sampleDeck() throws {
        try skipUnported(Sample.commands + ["file.saveAs"])
        let corpus = try #require(Fixtures.oracleCorpus)
        let s = Session()
        try Sample.openSample(s)
        let out = scratchDir("sample").appending(path: "sample.deckcraft")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        _ = try s.execute("file.saveAs", ["path": .string(out.path)])
        let a = try presentationJSON([UInt8](Data(contentsOf: out)))
        let b = try presentationJSON([UInt8](Data(contentsOf: corpus.appending(path: "decks/sample.deckcraft"))))
        #expect(a == b, "sample: presentation \(firstDifference(a, b))")
    }
}
