// DCEngineTests — the Session: documents, undo and redo, the history's limits, failed commands, the
// journal, preferences and document ids.
// Ports Session tests of deckcraft crates/engine/src/tests.rs, guard.rs and recovery.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCModel
import Foundation
import Testing

@Suite("Session")
struct SessionTests {
    @Test func newPresentationAndSlides() {
        let s = session()
        #expect(s.st.doc.slides.count == 1)
        s.run("slide.new")
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.st.doc.slides.count == 3)
        #expect(s.st.selection.slide == 2)
        s.run("slide.duplicate")
        #expect(s.st.doc.slides.count == 4)
        s.run("slide.move", #"{"from": 3, "to": 0}"#)
        s.run("slide.delete", #"{"index": 0}"#)
        #expect(s.st.doc.slides.count == 3)
        s.run("edit.undo")
        #expect(s.st.doc.slides.count == 4)
        s.run("edit.redo")
        #expect(s.st.doc.slides.count == 3)
    }

    @Test func undoAndRedoRestoreTheDocumentAndTheSelection() {
        let s = session()
        let first = s.st.docRef
        s.run("slide.new")
        let afterNew = s.st.docRef
        #expect(s.st.selection.slide == 1)
        #expect(s.st.history.undo.map(\.label) == ["New Slide"])
        let r = s.run("edit.undo")
        #expect(r == ["label": "New Slide"])
        #expect(s.st.docRef === first, "undo restores the very presentation from before")
        #expect(s.st.selection.slide == 0)
        #expect(s.st.history.redo.count == 1)
        s.run("edit.redo")
        #expect(s.st.docRef === afterNew)
        #expect(s.st.selection.slide == 1)
        // A new edit clears what could be redone.
        s.run("edit.undo")
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.st.history.redo.isEmpty)
        #expect(s.fails("edit.redo"))
    }

    @Test func queriesAndSelectionChangesMakeNoUndoStep() {
        let s = session()
        s.run("slide.new")
        let n = s.st.history.undo.count
        s.run("document.inspect")
        s.run("slide.inspect")
        s.run("file.info")
        s.run("slide.go", #"{"index": 0}"#)
        s.run("edit.selectAll")
        s.run("edit.deselect")
        #expect(s.st.history.undo.count == n)
    }

    @Test func aSavedDocumentIsCleanUntilItChanges() throws {
        let s = session()
        #expect(!s.st.isDirty)
        s.run("slide.new")
        #expect(s.st.isDirty)
        let dir = scratchDir("dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        s.run("file.saveAs", "{\"path\": \"\(dir.appending(path: "d.deckcraft").path)\"}")
        #expect(!s.st.isDirty)
        s.run("slide.new")
        #expect(s.st.isDirty)
        s.run("edit.undo")
        #expect(!s.st.isDirty, "undo back to the saved presentation is clean again")
        s.run("file.revert")
        #expect(!s.st.isDirty && s.st.history.undo.isEmpty)
    }

    @Test func theUndoLimitDropsTheOldestSteps() {
        let s = session()
        s.st.history.limit = 3
        for _ in 0 ..< 5 { s.run("slide.new") }
        #expect(s.st.history.undo.count == 3)
        for _ in 0 ..< 3 { s.run("edit.undo") }
        #expect(s.st.doc.slides.count == 3, "the two oldest steps are gone")
        #expect(s.fails("edit.undo"))
    }

    @Test(.enabled(if: ported("design.slideSize")))
    func undoHistoryIsCappedByMemoryAsWellAsSteps() {
        let s = session()
        for _ in 0 ..< 40 { s.run("slide.new") }
        let oneCopy = undoCost(s.st.doc, Presentation.default)
        #expect(oneCopy > 0)
        s.st.history = History(limit: 500, byteLimit: oneCopy * 10)
        for i in 0 ..< 30 {
            // Resizing the slides rescales every shape on every slide: a new copy of each.
            s.run("design.slideSize", "{\"w\": \(i % 2 == 0 ? 720 : 960), \"h\": 540}")
        }
        let n = s.st.history.undo.count
        // Rust keeps 5–11 steps. Here a slide whose shapes all inherit their boxes (the new slides' empty
        // placeholders) is unchanged by the rescale and counts as shared (see Divergences, undo memory
        // accounting), so each step costs a little less and up to 13 fit.
        #expect((5 ... 13).contains(n), "\(n) deck-wide steps kept")
        s.run("edit.undo")
        let t = session()
        t.st.history.byteLimit = oneCopy * 10
        for _ in 0 ..< 120 { t.run("slide.new") }
        #expect(t.st.history.undo.count == 120)
    }

    @Test func undoCostCountsWhatTheNewerDocumentDoesNotShare() {
        let s = session()
        for _ in 0 ..< 10 { s.run("slide.new") }
        let before = s.st.doc
        s.run("slide.notes", #"{"text": "changed", "index": 3}"#)
        let after = s.st.doc
        // One slide changed: far less than a copy of every slide.
        let one = undoCost(before, after)
        let all = undoCost(before, Presentation.default)
        #expect(one > 0 && one < all / 4, "\(one) of \(all)")
        #expect(undoCost(after, after) == 64 * after.slides.count)
    }

    @Test func aByteBudgetDropsOldStepsButKeepsTheNewest() {
        let s = session()
        s.st.history.byteLimit = 1
        for _ in 0 ..< 5 { s.run("slide.new") }
        #expect(s.st.history.undo.count == 1, "the newest step always stays")
        #expect(s.st.history.costs.count <= s.st.history.undo.count + 16)
    }

    @Test(.enabled(if: ported("shape.insert", "shape.connect")))
    func aCommandThatFailsAfterEditingLeavesTheDocumentAlone() throws {
        let s = Session()
        s.run("file.new")
        let a = s.run("shape.insert", #"{"preset": "rect", "rect": [36, 36, 100, 100]}"#).get("id") ?? .null
        let b = s.run("shape.insert", #"{"preset": "rect", "rect": [236, 36, 100, 100]}"#).get("id") ?? .null
        let before = s.st.docRef
        let undoLen = s.st.history.undo.count
        // `shape.connect` inserts the requested preset first, then rejects it because it is not a line.
        #expect(throws: EngineError.self) { try s.execute("shape.connect", ["from": a, "to": b, "preset": "rect"]) }
        #expect(s.st.docRef === before, "the stray shape is gone")
        #expect(s.st.history.undo.count == undoLen)
    }

    @Test(.enabled(if: ported("shape.insert", "picture.change")))
    func aFailedPictureChangeAddsNoMedia() {
        let s = Session()
        s.run("file.new")
        s.run("shape.insert", #"{"preset": "rect", "rect": [36, 36, 100, 100]}"#)
        let before = s.st.docRef
        // `picture.change` stores the image first, then finds no shape with this id.
        #expect(s.fails("picture.change", "{\"ids\": [9999], \"name\": \"a.png\", \"data\": \"\(Cmd.base64Encode(Array("not a picture".utf8)))\"}"))
        #expect(s.st.docRef === before, "the stored image is gone")
    }

    /// A failing command keeps the document and the remembered point type (Rust: `guard.rs`, where a
    /// panic is caught; Swift has none to catch, so the same rollback is checked on an error).
    @Test func aFailedCommandKeepsTheRememberedPointType() {
        let s = session()
        let kept = VertexKind(ShapeId(1), 0, 0, "straight")
        s.tool.vertexKind = kept
        #expect(s.fails("slide.go", #"{"index": 99}"#))
        #expect(s.tool.vertexKind == kept)
    }

    @Test func aFailedOuterCommandPutsTheSelectionBack() {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        let sel = s.st.selection
        let doc = s.st.docRef
        #expect(s.fails("slide.move", #"{"from": 7, "to": 0}"#))
        #expect(s.st.selection == sel && s.st.docRef === doc)
    }

    @Test func anExhaustedIdSpaceRefusesGrowth() {
        let s = session()
        s.run("slide.new")
        var p = s.st.doc
        p.nextId = UInt32.max
        s.st.docRef = DocRef(p)
        let before = s.st.doc
        #expect(s.fails("slide.new"), "a new slide is refused")
        #expect(s.fails("slide.duplicate"))
        if let title = s.st.currentSlide?.shapes.first?.id {
            s.st.selection.shapes = [title]
            #expect(s.fails("edit.duplicate"))
        }
        for id in ["shape.insert", "insert.smartArt", "insert.textBox"] where ported(id) {
            #expect(s.fails(id, #"{"preset": "rect", "rect": [10, 10, 100, 50], "kind": "blockList", "items": ["Plan"], "text": "Hi"}"#), "\(id)")
        }
        let after = s.st.doc
        #expect(after.slides.count == before.slides.count)
        var ids: [UInt32] = []
        walk(after.slides[0].shapes) { sh, _ in ids.append(sh.id.rawValue) }
        ids.append(after.slides[0].id.rawValue)
        ids.append(after.nextId)
        #expect(Set(ids).count == ids.count, "no id repeats")
    }

    @Test(.enabled(if: ported("shape.insert")))
    func invalidIdsArrayNeverFallsBackToTheSelection() {
        let s = session()
        let a = s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 100, 100]}"#).get("id")?.asU64 ?? 0
        for ids in ["[-1]", "[1.5]", "[4294967296]", "[-1, \(a)]"] {
            do {
                _ = try s.execute("edit.delete", j("{\"ids\": \(ids)}"))
                Issue.record("invalid ids \(ids) were accepted")
            } catch let e {
                if case .badParams = e {} else { Issue.record("invalid ids \(ids) gave \(e)") }
            }
            #expect(s.st.shape(ShapeId(UInt32(a))) != nil, "shape deleted for \(ids)")
        }
    }

    @Test func invalidIdsAreRefusedBeforeTheSelectionIsUsed() {
        let s = session()
        let title = s.st.currentSlide?.shapes.first?.id ?? .default
        s.st.selection.shapes = [title]
        for ids in ["[-1]", "[1.5]", "[4294967296]"] {
            #expect(throws: EngineError.self) { try s.execute("edit.delete", j("{\"ids\": \(ids)}")) }
        }
        #expect(throws: EngineError.self) { try s.execute("edit.duplicate", j(#"{"id": -1}"#)) }
        #expect(s.st.shape(title) != nil)
    }

    @Test func documentsUidsAreUniqueBeyondThisProcess() {
        let a = DocState(Presentation.default, path: nil, title: "a")
        let b = DocState(Presentation.default, path: nil, title: "b")
        #expect(a.uid != b.uid)
        #expect(a.uid >= 1 << 24 && a.uid <= Recovery.uidMask)
    }

    @Test func windowsCycleAndCloseKeepAnActiveDocument() {
        let s = Session()
        s.run("file.new")
        s.run("file.new")
        s.run("file.new")
        #expect(s.activeIndex == 2)
        #expect(s.st.title == "Presentation3")
        s.run("window.next")
        #expect(s.activeIndex == 0)
        s.run("window.next", #"{"index": 9}"#)
        #expect(s.activeIndex == 2)
        s.run("file.close")
        #expect(s.activeIndex == 1 && s.documents.count == 2)
        s.run("file.close")
        s.run("file.close")
        #expect(s.activeIndex == nil)
        #expect(s.fails("file.info"))
        #expect(s.fails("file.close"))
    }

    @Test func changingTheActiveDocumentForgetsThePointType() {
        let s = Session()
        s.run("file.new")
        s.run("file.new")
        s.tool.vertexKind = VertexKind(ShapeId(1), 0, 0, "corner")
        s.setActive(1)
        #expect(s.tool.vertexKind != nil, "the same document keeps it")
        s.setActive(0)
        #expect(s.tool.vertexKind == nil)
    }

    @Test func theSelectionIsClampedToWhatExists() throws {
        let s = session()
        try s.select { _, sel in
            sel.slide = 99
            sel.shapes = [ShapeId(424_242)]
            sel.slides = [SlideId(424_242)]
            sel.target = .layout(master: 0, layout: 999)
            sel.text = TextSel(shape: ShapeId(424_242))
        }
        let sel = s.st.selection
        #expect(sel.slide == 0 && sel.shapes.isEmpty && sel.slides.isEmpty && sel.text == nil && sel.target == .slides)
        try s.select { _, sel in sel.target = .handout }
        #expect(s.st.selection.target == (s.st.doc.handoutMaster == nil ? .slides : .handout))
        try s.select { _, sel in sel.target = .master(master: 0) }
        #expect(s.st.selection.target == .master(master: 0))
        #expect(s.st.shapes.map(\.id) == (s.st.doc.masters.first?.shapes.map(\.id) ?? []))
    }

    @Test func prefsAreSanitized() throws {
        var p = Prefs()
        p.gridSpacing = 0
        p.duplicateOffset = .infinity
        p.undoLimit = 1 << 40
        p.recoveryMinutes = -3
        p.author = String(repeating: "é", count: 300)
        let q = p.sanitized()
        #expect(q.gridSpacing == 6 && q.duplicateOffset == 12 && q.undoLimit == maxUndoLimit && q.recoveryMinutes == 0.1)
        #expect(q.author.unicodeScalars.count == 256)
        // `prefs.json` round trip, missing fields taking their defaults.
        let back = try Prefs(fromJSON: q.toJSON())
        #expect(back == q)
        let partial = try Prefs(fromJSON: j(#"{"gridSpacing": 3, "units": "centimeters"}"#))
        #expect(partial.gridSpacing == 3 && partial.units == .centimeters && partial.author == "Presenter")
    }

    @Test func stagedLoadsKeepOnlyTheLatestFew() {
        let s = Session()
        var tokens: [UInt64] = []
        for i in 0 ..< 6 {
            tokens.append(s.stageLoaded(LoadedFile(path: "/x\(i)", doc: .default, native: true, damaged: Damage())))
        }
        #expect(s.takeLoaded(tokens[0]) == nil, "older ones are dropped")
        #expect(s.takeLoaded(tokens[5])?.path == "/x5")
        #expect(s.takeLoaded(tokens[5]) == nil, "a token is used up")
    }

    @Test func editsRerouteGluedConnectorsAndBumpTheRevision() throws {
        let s = session()
        let rev = s.st.revision
        try s.edit { _, _ in }
        #expect(s.st.revision == rev + 1)
        try s.select { _, _ in }
        #expect(s.st.revision == rev + 2)
    }

    @Test func compositionsSettleIntoOneUndoStep() throws {
        let s = session()
        let before = s.st.docRef
        // A composition as `text.compose` would leave it: the text changed, the old document kept.
        s.st.composition = Composition(start: TextPoint(0, 0), len: 2, active: nil, props: nil, before: before, beforeSelection: s.st.selection)
        var p = s.st.doc
        p.props.title = "composed"
        s.st.docRef = DocRef(p)
        // Any other command settles it first.
        s.run("slide.new")
        #expect(s.st.composition == nil)
        #expect(s.compositionSettles == 1)
        #expect(s.st.history.undo.map(\.label) == ["Type Text", "New Slide"])
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(s.st.docRef === before)
    }
}
