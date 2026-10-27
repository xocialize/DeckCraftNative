// DCEngineTests — the shapes group's oracle checks beyond EngineScriptTests' byte comparison:
// - `shapes-native-*` scripts, whose outlines come from CoreGraphics' path booleans instead of i_overlay
//   (PORT-STATUS "Decisions recorded"), compared structurally: every answer and the deck as JSON, numbers
//   within a small tolerance, and each path's text by the area it encloses;
// - the pixels of the pictures Artistic Effects stores, against deckcraft's (the PNG streams differ);
// - the error messages of refused commands, which a script can't hold (the oracle stops at the first).
// deckcraft crates/engine (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCFormat
import DCModel
import DCRender
import DCTestSupport
import DCZip
import Foundation
import Testing

private let scripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/engine-scripts"))
private let vectors = Fixtures.root.appending(path: "engine")
private let haveVectors = FileManager.default.fileExists(atPath: vectors.path)

/// The shapes group's native scripts (EngineScriptTests skips `*-native-*`).
let shapesNativeScripts = scripts.filter { $0.name.hasPrefix("shapes-native-") }

/// Run `script` as `deckcraft-cli run --print --save` does: the answers, the saved file, and the refused
/// commands' errors (`id=json\tmessage`, as `oracle.sh engine-vectors` records them).
func runShapesScript(_ script: CommandScript) throws -> (answers: [JSON], lines: [String], saved: [UInt8], errors: [String]) {
    let s = Session()
    if let input = script.input {
        let deck = try #require(Fixtures.oracleCorpus).appending(path: "decks").appending(path: input)
        _ = try s.execute("file.open", ["path": .string(deck.path)])
    } else {
        _ = try s.execute("file.new", .emptyObject)
    }
    var answers: [JSON] = []
    var lines: [String] = []
    var errors: [String] = []
    for (i, (id, params)) in script.commands.enumerated() {
        if script.refused.contains(i) {
            do {
                let r = try s.execute(id, try JSONParser.parse(params))
                errors.append("\(id)=\(params)\tsucceeded: \(r.display)")
            } catch {
                errors.append("\(id)=\(params)\t\(error)")
            }
            continue
        }
        let r = try s.execute(id, try JSONParser.parse(params))
        answers.append(r)
        lines.append("\(id) → \(r.display)")
    }
    let out = scratchDir("shapes-script").appending(path: "\(script.name).deckcraft")
    defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
    _ = try s.execute("file.saveAs", ["path": .string(out.path)])
    return (answers, lines, try [UInt8](Data(contentsOf: out)), errors)
}

/// The area a path's text (`M`/`L`/`C`/`Q`/`Z`, as `CustomPath.d`) encloses, sub-paths netted by their
/// winding, curves flattened.
func pathArea(_ d: String) -> Double {
    var total = 0.0
    var ring: [(Double, Double)] = []
    func close() {
        if ring.count > 2 {
            var a = 0.0
            for i in ring.indices {
                let (p, q) = (ring[i], ring[(i + 1) % ring.count])
                a += p.0 * q.1 - q.0 * p.1
            }
            total += a / 2
        }
        ring = []
    }
    for seg in PointsCommands.parse(d) {
        switch seg {
        case .m(let p):
            close()
            ring.append((p.x, p.y))
        case .l(let p), .q(_, let p), .c(_, _, let p): ring.append((p.x, p.y))
        case .z: close()
        }
    }
    close()
    return Swift.abs(total)
}

/// What a structural comparison found: the differences, and the largest relative area difference of the
/// paths it compared by area.
struct StructuralDiff {
    var problems: [String] = []
    var areas: [(ours: Double, oracle: Double)] = []
    var worstArea: Double { areas.map { Swift.abs($0.ours - $0.oracle) / Swift.max($0.oracle, 1e-9) }.max() ?? 0 }
}

/// Compare `a` (ours) with `b` (the oracle's): same structure, numbers within `tol` (absolute, or relative
/// for large values), strings equal except a path's `d`, compared by enclosed area within `areaTol`.
func compareStructurally(_ a: JSON, _ b: JSON, _ path: String, _ diff: inout StructuralDiff, tol: Double = 0.02, areaTol: Double = 1e-3) {
    if diff.problems.count > 20 { return }
    switch (a.canonical, b.canonical) {
    case (.object(let x), .object(let y)):
        if x.keys != y.keys {
            diff.problems.append("\(path): keys \(x.keys) vs \(y.keys)")
            return
        }
        for k in x.keys {
            let (va, vb) = (x[k] ?? .null, y[k] ?? .null)
            if k == "d", case .string(let da) = va, case .string(let db) = vb, !rustEqual(da, db) {
                let (aa, ab) = (pathArea(da), pathArea(db))
                diff.areas.append((aa, ab))
                if Swift.abs(aa - ab) > areaTol * Swift.max(ab, 1) { diff.problems.append("\(path).d: area \(aa) vs \(ab)") }
                continue
            }
            compareStructurally(va, vb, "\(path).\(k)", &diff, tol: tol, areaTol: areaTol)
        }
    case (.array(let x), .array(let y)):
        if x.count != y.count {
            diff.problems.append("\(path): \(x.count) items vs \(y.count)")
            return
        }
        for (i, (va, vb)) in zip(x, y).enumerated() { compareStructurally(va, vb, "\(path)[\(i)]", &diff, tol: tol, areaTol: areaTol) }
    case let (x, y) where x.isNumber && y.isNumber:
        let (u, v) = (x.asF64 ?? .nan, y.asF64 ?? .nan)
        if !(Swift.abs(u - v) <= Swift.max(tol, 1e-6 * Swift.abs(v))) { diff.problems.append("\(path): \(u) vs \(v)") }
    case let (x, y):
        if x != y { diff.problems.append("\(path): \(x.display.prefix(80)) vs \(y.display.prefix(80))") }
    }
}

/// The decoded pixels of every picture in a saved deck, by media id.
func savedDeckPictures(_ file: [UInt8]) throws -> [UInt32: StraightImage] {
    let z = try ZipReader(file)
    let manifest = try JSONParser.parse(try z.read(named: "presentation.json", max: 1 << 30))
    var out: [UInt32: StraightImage] = [:]
    for m in manifest["presentation"]?.get("media")?.asArray ?? [] {
        guard let id = m.get("id")?.asU32, m.get("contentType")?.asStr?.hasPrefix("image/") == true,
              let bytes = try? z.read(named: "media/\(id)", max: 1 << 28), let img = Images.decode(bytes) else { continue }
        out[id] = img
    }
    return out
}

@Suite("Shapes: native scripts, stored pixels and refusals")
struct ShapesScriptTests {
    @Test("Native shapes scripts match the oracle by structure and area", .enabled(if: haveVectors, "no engine vectors"), arguments: shapesNativeScripts)
    func nativeScript(_ script: CommandScript) throws {
        let missing = unported(script.needs)
        if !missing.isEmpty { try Test.cancel("waits for unported commands: \(missing.joined(separator: ", "))") }
        guard let text = try? String(contentsOf: vectors.appending(path: "\(script.name).results.txt"), encoding: .utf8) else {
            try Test.cancel("no oracle answers for \(script.name): run Tools/oracle/oracle.sh engine-vectors \(script.name)")
        }
        let want = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let (answers, lines, saved, errors) = try runShapesScript(script)
        let wantErrors = (try? String(contentsOf: vectors.appending(path: "\(script.name).errors.txt"), encoding: .utf8))
            .map { $0.components(separatedBy: "\n").filter { !$0.isEmpty } } ?? []
        #expect(errors == wantErrors, "\(script.name): refusals \(errors) vs the oracle's \(wantErrors)")
        #expect(lines.count == want.count, "\(script.name): \(lines.count) answers, the oracle printed \(want.count)")
        var diff = StructuralDiff()
        for (i, (ours, line)) in zip(answers, want).enumerated() {
            guard let arrow = line.range(of: " → ") else { continue }
            let theirs = try JSONParser.parse(String(line[arrow.upperBound...]))
            compareStructurally(ours, theirs, "\(script.name) answer \(i + 1)", &diff)
        }
        let oracleDeck = try [UInt8](Data(contentsOf: vectors.appending(path: "\(script.name).deckcraft")))
        compareStructurally(try JSONParser.parse(presentationJSON(saved)), try JSONParser.parse(presentationJSON(oracleDeck)), "\(script.name) deck", &diff)
        for p in diff.problems { Issue.record("\(p)") }
        let worst = diff.worstArea
        print("native script \(script.name): \(diff.areas.count) outlines compared by area, worst relative difference \(worst)")
        #expect(worst <= 1e-3)
    }

    @Test("Artistic effects store deckcraft's pixels", .enabled(if: haveVectors && Fixtures.oracleCorpus != nil, "no engine vectors"))
    func artisticPixels() throws {
        guard let script = scripts.first(where: { $0.name == "shapes-artistic" }) else { try Test.cancel("no shapes-artistic script") }
        let missing = unported(script.needs)
        if !missing.isEmpty { try Test.cancel("waits for unported commands: \(missing.joined(separator: ", "))") }
        let (_, _, saved, _) = try runShapesScript(script)
        let ours = try savedDeckPictures(saved)
        let theirs = try savedDeckPictures(try [UInt8](Data(contentsOf: vectors.appending(path: "shapes-artistic.deckcraft"))))
        #expect(ours.count == theirs.count && ours.count >= 16, "\(ours.count) pictures, the oracle saved \(theirs.count)")
        var compared = 0
        for (id, t) in theirs.sorted(by: { $0.key < $1.key }) {
            guard let o = ours[id] else {
                Issue.record("no picture \(id)")
                continue
            }
            #expect(o.width == t.width && o.height == t.height, "picture \(id): \(o.width)×\(o.height), the oracle's \(t.width)×\(t.height)")
            if o.pixels != t.pixels {
                let differing = zip(o.pixels, t.pixels).filter { $0 != $1 }.count
                let worst = zip(o.pixels, t.pixels).map { Swift.abs(Int($0) - Int($1)) }.max() ?? 0
                Issue.record("picture \(id): \(differing) of \(t.pixels.count) channel values differ, by at most \(worst)")
            }
            compared += 1
        }
        print("artistic effects: \(compared) pictures compared pixel for pixel")
    }
}
