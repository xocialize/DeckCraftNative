// dccliTests — the pointer through `dccli mcp`, reply for reply and deck for deck against deckcraft-cli's: each
// `Tools/oracle/pointer-sessions/<name>.jsonl` (JSON-RPC lines: a presentation, pointer events of every tool
// and drag kind, snapping on and off, modifiers, then a save) is run as the oracle ran it for
// `$DECKCRAFT_FIXTURES/pointer/` (`Tools/oracle/oracle.sh pointer-vectors`).
import DCCore
import DCTestSupport
import Foundation
import Testing

/// A pointer session: its JSON-RPC lines, `@OUT@` standing for the deck it saves.
struct PointerSession: Sendable, CustomStringConvertible {
    var name: String
    var text: String
    var description: String { name }

    static let folder = Fixtures.repositoryRoot.appending(path: "Tools/oracle/pointer-sessions")
    static let vectors = Fixtures.root.appending(path: "pointer")

    static let all: [PointerSession] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return PointerSession(name: url.deletingPathExtension().lastPathComponent, text: text)
        }
    }()

    static var haveVectors: Bool { FileManager.default.fileExists(atPath: vectors.appending(path: "SHA256SUMS").path) }
}

@Suite("Pointer sessions through dccli mcp", .enabled(if: Binaries.haveDccli, "dccli isn't built"))
struct PointerParityTests {
    /// A saved deck's size is DCZip's deflate, not deckcraft's (the presentation inside is compared on its own).
    static func masked(_ line: String) -> String {
        line.replacingOccurrences(of: #"\\"bytes\\": \d+"#, with: "<bytes>", options: .regularExpression)
    }

    @Test("Every reply and the saved deck are the oracle's", .enabled(if: PointerSession.haveVectors, "no pointer vectors"),
          arguments: PointerSession.all)
    func sessionMatchesTheOracle(_ session: PointerSession) throws {
        let dir = scratch("pointer-\(session.name)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = dir.appending(path: "\(session.name).deckcraft")
        let input = Data(session.text.replacingOccurrences(of: "@OUT@", with: deck.path).utf8)
        let r = try dccli(["mcp"], input: input)
        #expect(r.code == 0 && r.stderr.isEmpty, "\(r.stderr)")
        let ours = r.stdout.replacingOccurrences(of: deck.path, with: "@OUT@").components(separatedBy: "\n").filter { !$0.isEmpty }
        let want = try String(contentsOf: PointerSession.vectors.appending(path: "\(session.name).replies.txt"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(ours.count == want.count, "\(ours.count) replies, the oracle's \(want.count)")
        var shown = 0
        for (i, (x, y)) in zip(ours.map(Self.masked), want.map(Self.masked)).enumerated() where x != y {
            shown += 1
            if shown <= 5 { Issue.record("reply \(i + 1):\n  ours:   \(x.prefix(800))\n  oracle: \(y.prefix(800))") }
        }
        #expect(shown == 0, "\(shown) replies differ")
        let (a, b) = (try presentationJSON(readBytes(deck)), try presentationJSON(readBytes(PointerSession.vectors.appending(path: "\(session.name).deckcraft"))))
        #expect(a == b, "\(session.name) deck: \(firstDifference(a, b))")
    }

    @Test("The sessions cover every pointer kind, tool and modifier")
    func sessionsCoverThePointer() {
        let text = PointerSession.all.map(\.text).joined(separator: "\n")
        #expect(PointerSession.all.count >= 7)
        for kind in ["down", "drag", "up", "move", "doubleclick", "tripleclick", "contextclick"] {
            #expect(text.contains("\"kind\":\"\(kind)\""), "\(kind)")
        }
        for tool in ["select", "textBox", "pen", "highlighter", "eraser", "freeform", "curve", "scribble", "drawTable", "tableEraser"] {
            #expect(text.contains("\"\(tool)\""), "\(tool)")
        }
        for m in ["shift", "alt", "cmd"] { #expect(text.contains("\"\(m)\":true"), "\(m)") }
        #expect(text.contains("\"pressure\""))
        #expect(text.contains("\"save_presentation\""))
    }
}
