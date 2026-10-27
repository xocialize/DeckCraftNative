// DCEngineTests — editor soak (engine/src/soak_tests.rs): long random command sequences over a big deck, with
// invariants checked after every step: no trap, a valid document, an in-range selection, a bounded undo stack,
// undo then redo restoring the exact document, and periodic save/reopen in both formats.
//
// Seeded and deterministic. A failure gives the seed and the last commands so it replays.
// `DECKCRAFT_SOAK_STEPS=50000 swift test --filter SoakTests` runs a long soak (with `DECKCRAFT_SOAK_SEED`).
import DCCore
@testable import DCEngine
import DCModel
import Foundation
import Testing

/// Commands that touch the file system, other windows or real time; the soak drives the rest.
private func skipped(_ id: String) -> Bool {
    ["file.close", "file.open", "file.save", "file.saveAs", "file.export", "file.saveTemplate", "file.openBytes", "file.new"].contains(id)
        || id.hasPrefix("window.")
        || id.hasPrefix("show.")
        || id.hasPrefix("media.")
}

/// xorshift64*: tiny, deterministic, no dependency.
private struct Rng {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    mutating func below(_ n: Int) -> Int { n == 0 ? 0 : Int(next() % UInt64(n)) }

    mutating func f(_ lo: Double, _ hi: Double) -> Double {
        lo + Double(next() >> 11) / Double(UInt64(1) << 53) * (hi - lo)
    }

    mutating func pick<T>(_ v: [T]) -> T? { v.at(below(v.count)) }
}

private func shapeIds(_ s: Session) -> [UInt64] {
    s.activeDoc.map { $0.shapes.map { UInt64($0.id.rawValue) } } ?? []
}

/// Plausible parameters built from the live document, plus the odd hostile value.
private func params(_ r: inout Rng, _ s: Session) -> String {
    let ids = shapeIds(s)
    let id = r.pick(ids) ?? 1
    let slides = s.activeDoc?.doc.slides.count ?? 1
    let index = r.below(slides + 2)
    switch r.below(10) {
    case 0: return "{}"
    case 1: return #"{"ids":[\#(id)]}"#
    case 2: return #"{"id":\#(id),"text":"Soak ✓ שלום 漢字","name":"S"}"#
    case 3: return #"{"index":\#(index),"to":\#(r.below(slides + 1))}"#
    case 4: return #"{"preset":"rect","rect":[\#(r.f(0, 600)),\#(r.f(0, 400)),\#(r.f(1, 300)),\#(r.f(1, 200))]}"#
    case 5: return ##"{"ids":[\##(id)],"color":"#3366CC","size":\##(r.f(1, 96)),"value":\##(r.f(-10, 10))}"##
    case 6: return #"{"ids":[\#(ids.prefix(3).map(String.init).joined(separator: ","))]}"#
    case 7: return #"{"effect":"fade","start":"afterPrevious","duration":\#(r.below(5000)),"delay":\#(r.below(2000))}"#
    case 8: return #"{"layout":"titleAndContent","title":"T","body":"B"}"#
    default: return #"{"index":\#(UInt64.max),"ids":[\#(UInt64.max)],"id":-1,"size":1e308,"rect":[\#(Double.greatestFiniteMagnitude),0,-1,0]}"#
    }
}

private struct SoakFailure: Error, CustomStringConvertible {
    var description: String
}

/// The invariants after every step; the failure names the seed, the step and the last commands.
private func check(_ s: Session, _ seed: UInt64, _ step: Int, _ log: [String]) throws(SoakFailure) {
    let ctx = "seed \(seed) step \(step); last commands:\n\(log.joined(separator: "\n"))"
    guard let d = s.activeDoc else { throw SoakFailure(description: "no active document; \(ctx)") }
    let problems = d.doc.validate()
    guard problems.isEmpty else { throw SoakFailure(description: "\(problems); \(ctx)") }
    guard d.selection.slide < Swift.max(d.doc.slides.count, 1) else {
        throw SoakFailure(description: "selection slide \(d.selection.slide) of \(d.doc.slides.count); \(ctx)")
    }
    guard d.history.undo.count <= Swift.max(d.history.limit, 1) else {
        throw SoakFailure(description: "undo stack \(d.history.undo.count) over limit; \(ctx)")
    }
}

/// `soak(seed, steps)`: the edits made, or the first broken invariant.
private func soak(_ seed: UInt64, _ steps: Int) throws -> Int {
    let s = Session()
    try Sample.openSample(s)
    // A big deck: the sample several times over.
    for _ in 0 ..< 3 {
        let n = s.activeDoc?.doc.slides.count ?? 0
        for i in 0 ..< n { _ = try? s.execute("slide.duplicate", j(#"{"index":\#(i)}"#)) }
    }
    let specs = commandSpecs()
    let ids = specs.map(\.id).filter { !skipped($0) }
    let undoable = Set(specs.filter(\.undoable).map(\.id))
    var r = Rng(state: seed | 1)
    var log: [String] = []
    var edits = 0
    for step in 0 ..< steps {
        let id = r.pick(ids) ?? "edit.undo"
        let p = params(&r, s)
        log.append("\(id) \(p)")
        if log.count > 20 { log.removeFirst() }
        let before = s.activeDoc?.doc
        let ok: Bool
        do {
            _ = try s.execute(id, j(p))
            ok = true
        } catch EngineError.internalError(let cmd, let msg) {
            throw SoakFailure(description: "command failed unexpectedly: \(cmd): \(msg); seed \(seed) step \(step); \(id) \(p)")
        } catch {
            ok = false
        }
        try check(s, seed, step, log)
        // Undo then redo of a real edit gets the same document back.
        let after = s.activeDoc?.doc
        if before != after { edits += 1 }
        if ok, undoable.contains(id), before != after, r.below(4) == 0 {
            do { _ = try s.execute("edit.undo", j("{}")) } catch {
                throw SoakFailure(description: "undo failed: \(error); seed \(seed) step \(step) \(id) \(p)")
            }
            guard s.activeDoc?.doc == before else { throw SoakFailure(description: "undo didn't restore; seed \(seed) step \(step) \(id) \(p)") }
            do { _ = try s.execute("edit.redo", j("{}")) } catch {
                throw SoakFailure(description: "redo failed: \(error); seed \(seed) step \(step) \(id) \(p)")
            }
            guard s.activeDoc?.doc == after else { throw SoakFailure(description: "redo didn't reapply; seed \(seed) step \(step) \(id) \(p)") }
        }
        // Keep the deck from vanishing or exploding.
        let n = s.activeDoc?.doc.slides.count ?? 0
        if n == 0 || s.documents.count != 1 {
            throw SoakFailure(description: "documents \(s.documents.count) slides \(n); seed \(seed) step \(step); \(log)")
        }
        if step % 100 == 99 {
            for format in ["deckcraft", "pptx"] {
                let data: JSON
                do { data = try s.execute("file.saveBytes", j(#"{"format":"\#(format)"}"#)) } catch {
                    throw SoakFailure(description: "save \(format): \(error); seed \(seed) step \(step)")
                }
                let b64 = data["data"]?.asStr ?? ""
                let open: JSON = .object(JSONObject(["name": .string("soak.\(format)"), "data": .string(b64)]))
                do { _ = try s.execute("file.openBytes", open) } catch {
                    throw SoakFailure(description: "reopen \(format): \(error); seed \(seed) step \(step); \(log)")
                }
                let back = s.activeDoc?.doc
                guard back?.slides.count == n else { throw SoakFailure(description: "\(format) reopen slide count; seed \(seed) step \(step)") }
                guard back?.validate().isEmpty == true else { throw SoakFailure(description: "\(format) reopen invalid; seed \(seed) step \(step)") }
                s.closeDocument(s.documents.count - 1)
                s.setActive(0)
            }
        }
    }
    // The soak must really edit, not just bounce off disabled commands.
    guard edits * 10 >= steps else { throw SoakFailure(description: "only \(edits) of \(steps) steps changed the document; seed \(seed)") }
    return edits
}

private func steps(_ fallback: Int) -> Int {
    ProcessInfo.processInfo.environment["DECKCRAFT_SOAK_STEPS"].flatMap { Int($0) } ?? fallback
}

@Suite("Soak")
struct SoakTests {
    // soak_tests.rs: soak_random_edits_keep_the_document_valid
    @Test(arguments: [1, 0xDEC0_C2AF, 42, 7_777_777] as [UInt64])
    func soakRandomEditsKeepTheDocumentValid(_ seed: UInt64) throws {
        let n = steps(400)
        let edits = try onMainSizedStack { try soak(seed, n) }
        print("soak seed \(seed): \(edits) of \(n) steps edited")
    }

    // soak_tests.rs: soak_long (ignored in Rust; runs when DECKCRAFT_SOAK_STEPS is set)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DECKCRAFT_SOAK_STEPS"] != nil))
    func soakLong() throws {
        let seed = ProcessInfo.processInfo.environment["DECKCRAFT_SOAK_SEED"].flatMap { UInt64($0) } ?? 0x5EED
        let n = steps(20_000)
        let edits = try onMainSizedStack { try soak(seed, n) }
        print("soak seed \(seed): \(edits) of \(n) steps edited")
    }

    // soak_tests.rs: undo_stack_stays_bounded_and_drains
    @Test func undoStackStaysBoundedAndDrains() {
        let s = session()
        let limit = s.st.history.limit
        for i in 0 ..< limit + 50 {
            s.run("shape.insert", #"{"preset": "rect", "rect": [\#(i % 500), 10, 20, 20]}"#)
        }
        #expect(s.st.history.undo.count == limit)
        var undone = 0
        while (try? s.execute("edit.undo", j("{}"))) != nil {
            undone += 1
            if undone > limit {
                Issue.record("undo ran past the stack")
                break
            }
        }
        #expect(undone == limit)
        #expect(s.st.doc.validate().isEmpty)
    }
}
