// DCEngineTests — helpers the engine tests share: JSON from text, the commands a test needs, and the
// `presentation` member of a saved deck, as the oracle tests compare it.
import DCCore
@testable import DCEngine
import DCFormat
import DCModel
import DCTestSupport
import DCZip
import Foundation
import Testing

/// `json!(…)` from JSON text (the tests write their parameters as deckcraft's do).
func j(_ text: String) -> JSON {
    (try? JSONParser.parse(text)) ?? .null
}

/// The commands of `ids` that no module registers yet (Wave 4 fills the modules in in parallel).
func unported(_ ids: [String]) -> [String] { ids.filter { findCommand($0) == nil } }

/// True when every command in `ids` is registered: a test that needs them runs only then.
func ported(_ ids: String...) -> Bool { unported(ids).isEmpty }

/// A session with one new presentation open (`Session::with_new`).
func session() -> Session { Session.withNew() }

extension Session {
    /// `s.execute(id, &json!(…)).unwrap()` for tests: the error is recorded as a test failure.
    @discardableResult
    func run(_ id: String, _ params: String = "{}", sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        do {
            return try execute(id, j(params))
        } catch {
            Issue.record("\(id) \(params): \(error)", sourceLocation: sourceLocation)
            return .null
        }
    }

    /// `s.execute(id, params).is_err()`.
    func fails(_ id: String, _ params: String = "{}") -> Bool {
        (try? execute(id, j(params))) == nil
    }

    /// The active document; a test failure (and a fresh one) when there is none.
    var st: DocState {
        if let d = activeDoc { return d }
        Issue.record("no active document")
        return DocState(Presentation.default, path: nil, title: "")
    }
}

/// The `presentation` member of a `.deckcraft` file's `presentation.json`, as serde_json writes it (the
/// manifest's `generator` names the writing app, so it is left out). Comment timestamps come from the
/// clock and are blanked.
func presentationJSON(_ file: [UInt8]) throws -> [UInt8] {
    let z = try ZipReader(file)
    let json = try z.read(named: "presentation.json", max: 1 << 30)
    let manifest = try JSONParser.parse(json)
    let p = try #require(manifest["presentation"])
    return JSONWriter(nonFiniteAsZero: true).bytes(blankCommentDates(p))
}

/// Comment and reply dates set to "" (`review.rs` stamps them with the clock).
func blankCommentDates(_ v: JSON) -> JSON {
    guard case .object(var o) = v, case .array(var slides)? = o["slides"] else { return v }
    func blank(_ c: JSON) -> JSON {
        guard case .object(var co) = c else { return c }
        if co["date"] != nil { co.set("date", .string("")) }
        if case .array(let replies)? = co["replies"] { co.set("replies", .array(replies.map(blank))) }
        return .object(co)
    }
    for i in slides.indices {
        guard case .object(var so) = slides[i], case .array(let comments)? = so["comments"] else { continue }
        so.set("comments", .array(comments.map(blank)))
        slides[i] = .object(so)
    }
    o.set("slides", .array(slides))
    return .object(o)
}

/// ISO timestamps (`2026-10-10T13:10:35Z`) in an answer line replaced, so clock-stamped answers compare.
func blankTimestamps(_ line: String) -> String {
    line.replacingOccurrences(of: #"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"#, with: "<time>", options: .regularExpression)
}

/// The first byte where two byte strings differ, with a little context, for failure messages.
func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> String {
    let n = min(a.count, b.count)
    var at = n
    for i in 0 ..< n where a[i] != b[i] {
        at = i
        break
    }
    let lo = max(at - 80, 0)
    let ctx = { (x: [UInt8]) in String(decoding: x[min(lo, x.count) ..< min(at + 80, x.count)], as: UTF8.self) }
    return "differs at byte \(at) of \(a.count)/\(b.count):\n  ours:   …\(ctx(a))…\n  oracle: …\(ctx(b))…"
}

/// A fresh scratch folder for a test.
func scratchDir(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dcengine-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ... .max))")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// True when every command in `ids` is registered.
func ported(_ ids: [String]) -> Bool { unported(ids).isEmpty }
