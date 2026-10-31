// DCEngineTests — the Session: documents, undo and redo, the history's limits, failed commands, the
// journal, preferences and document ids.
// Ports Session tests of deckcraft crates/engine/src/tests.rs, guard.rs and recovery.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
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

    // tests.rs invalid_slide_index_never_falls_back_to_the_selection_in_export_commands
    @Test func invalidSlideIndexNeverFallsBackToTheSelectionInExportCommands() {
        let s = session()
        let dir = scratchDir("badslide")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "a.png").path
        for slide in ["-1", "1.5", "\"two\""] {
            func refused(_ id: String, _ params: String) {
                do {
                    _ = try s.execute(id, j(params))
                    Issue.record("\(id) slide \(slide) was accepted")
                } catch let e {
                    if case .badParams = e {} else { Issue.record("\(id) slide \(slide) gave \(e)") }
                }
            }
            refused("file.export", "{\"path\": \"\(path)\", \"slide\": \(slide), \"scale\": 0.1}")
            #expect(!FileManager.default.fileExists(atPath: path), "export wrote a file for \(slide)")
            refused("file.render", "{\"slide\": \(slide), \"scale\": 0.1}")
            refused("slide.colorAt", "{\"slide\": \(slide), \"x\": 1, \"y\": 1, \"scale\": 0.1}")
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

// MARK: - Pin move a3fbf029: tests.rs, inspect.rs

@Suite("Pin a3fbf029: commands")
struct PinA3fbf029Tests {
    /// In Slide Master / layout view the insert commands edit the master or layout; their answers say so with
    /// `editing`, and on slides carry no such key.
    // tests.rs insert_answers_carry_editing_in_master_and_layout_view
    @Test func insertAnswersCarryEditingInMasterAndLayoutView() {
        let s = session()
        let ins = #"{"preset": "rect", "rect": [10.0, 10.0, 100.0, 100.0]}"#
        s.run("view.slideMaster", #"{"layout": 0}"#)
        var r = s.run("shape.insert", ins)
        #expect(r.get("editing")?.get("kind") == "layout", "\(r.display)")
        #expect(r.get("editing")?.get("name")?.isString == true, "\(r.display)")
        r = s.run("insert.textBox", #"{"rect": [10.0, 10.0, 100.0, 50.0], "text": "x"}"#)
        #expect(r.get("editing")?.get("kind") == "layout", "\(r.display)")
        s.run("view.slideMaster", #"{"master": 0}"#)
        r = s.run("shape.insert", ins)
        #expect(r.get("editing")?.get("kind") == "master", "\(r.display)")
        s.run("view.closeMaster")
        r = s.run("shape.insert", ins)
        #expect(r.get("editing") == nil, "\(r.display)")
    }

    // tests.rs highlight_with_an_invalid_colour_is_rejected_and_keeps_the_highlight
    @Test func highlightWithAnInvalidColourIsRejectedAndKeepsTheHighlight() {
        let s = session()
        let title = s.st.currentSlide?.shapes.first?.id ?? .default
        s.run("text.edit", "{\"id\": \(title)}")
        s.run("text.insert", #"{"text": "ARCH"}"#)
        s.run("text.selectAll")
        s.run("format.highlight", #"{"color": "yellow"}"#)
        func hasHighlight() -> Bool { s.st.shape(title)?.text?.paragraphs.flatMap(\.runs).contains { $0.props.highlight != nil } ?? false }
        #expect(hasHighlight())
        do {
            _ = try s.execute("format.highlight", j(#"{"color": "notacolour"}"#))
            Issue.record("an invalid colour was accepted")
        } catch let e {
            if case .badParams = e {} else { Issue.record("\(e)") }
        }
        #expect(hasHighlight(), "an invalid colour must not clear the highlight")
        s.run("format.highlight")
        #expect(!hasHighlight(), "an absent colour clears the highlight")
    }

    private func titleOf(_ shapes: [Shape]) -> ShapeId? { shapes.first { $0.ph?.kind.isTitle ?? false }?.id }

    // tests.rs master_layout_placeholder_format_inherits
    @Test func masterLayoutPlaceholderFormatInherits() throws {
        let s = Session()
        try Sample.openSample(s)
        let existing = try #require(titleOf(s.st.doc.slides[0].shapes))
        s.run("view.slideMaster", #"{"master": 0, "layout": 0}"#)
        let layoutTitle = try #require(titleOf(s.st.doc.masters[0].layouts[0].shapes))
        s.run("edit.select", "{\"ids\": [\(layoutTitle)]}")
        s.run("format.font", #"{"family": "Montserrat"}"#)
        s.run("format.align", #"{"align": "right"}"#)
        var st = s.run("format.state")
        #expect(st.get("fontRef") == "Montserrat", "layout placeholder: \(st.display)")
        s.run("view.closeMaster")
        s.run("slide.new", #"{"layout": "title"}"#)
        let slide = s.st.selection.slide
        let fresh = try #require(titleOf(s.st.doc.slides[slide].shapes))
        for (index, id) in [(slide, fresh), (0, existing)] {
            s.run("slide.go", "{\"index\": \(index)}")
            s.run("edit.select", "{\"ids\": [\(id)]}")
            st = s.run("format.state")
            #expect(st.get("fontRef") == "Montserrat", "slide placeholder \(id): \(st.display)")
            #expect(st.get("align") == "r", "slide placeholder \(id): \(st.display)")
        }
    }

    // tests.rs master_body_placeholder_format_keeps_per_level_formatting
    @Test func masterBodyPlaceholderFormatKeepsPerLevelFormatting() throws {
        let s = Session()
        try Sample.openSample(s)
        s.run("view.slideMaster", #"{"master": 0}"#)
        let bodyIdx = try #require(s.st.doc.masters[0].shapes.firstIndex { $0.ph?.kind == .body })
        let id = s.st.doc.masters[0].shapes[bodyIdx].id
        try s.edit { doc, _ in
            var body = TextBody.fromText("Alpha\nBeta")
            body.paragraphs[1].level = 1
            for (l, size) in [(UInt8(0), 32.0), (1, 28.0)] {
                var lvl = LevelStyle()
                lvl.run.size = size
                body.listStyle.set(l, lvl)
            }
            doc.masters[0].shapes[bodyIdx].text = body
        }
        func level(_ l: UInt8) -> LevelStyle { s.st.doc.masters[0].shapes[bodyIdx].text?.listStyle.level(l) ?? LevelStyle() }
        // Bolding the level-2 paragraph reaches level 2 only.
        s.st.selection.shapes = [id]
        s.st.selection.text = TextSel(shape: id, anchor: TextPoint(1, 0), caret: TextPoint(1, 4), cell: nil, notes: false, lineEnd: nil)
        s.run("format.bold", #"{"on": true}"#)
        #expect(level(1).run.bold == true)
        for l: UInt8 in [0, 2, 3, 8] { #expect(level(l).run.bold == nil, "level \(l + 1)") }
        // Grow and shrink step each level from its own size.
        s.st.selection.text = nil
        // The text itself: a run's explicit size, else its level's effective size.
        func shown() -> [Double?] {
            let st = s.st
            guard let ctx = TextCommands.ctxFor(st.doc, st.selection) else { return [] }
            let sh = st.doc.masters[0].shapes[bodyIdx]
            return (sh.text?.paragraphs ?? []).map { p in p.runs.first?.props.size ?? Resolve.levelStyle(ctx, sh, p.level).run.size }
        }
        s.run("format.grow")
        #expect([level(0).run.size, level(1).run.size] == [36.0, 32.0])
        #expect(shown() == [36.0, 32.0])
        s.run("format.shrink")
        s.run("format.shrink")
        #expect([level(0).run.size, level(1).run.size] == [28.0, 24.0])
        #expect(shown() == [28.0, 24.0])
    }

    private func link(_ action: Action) -> Hyperlink {
        Hyperlink(action: action, tooltip: "", highlightClick: false, stopSound: false)
    }

    // inspect.rs tests::slide_actions_lists_group_shape_and_text_actions
    @Test func slideActionsListsGroupShapeAndTextActions() throws {
        let s = Session.withNew()
        var child = Shape.default
        child.id = ShapeId(12)
        child.name = "Child"
        child.click = link(.nextSlide)
        child.hover = link(.url(url: "https://example.com/hover"))
        var runProps = RunProps()
        runProps.link = link(.slide(slide: SlideId(7)))
        var paragraph = Paragraph("linked")
        paragraph.runs = [Run.with("linked", runProps)]
        var body = TextBody.default
        body.paragraphs = [paragraph]
        child.text = body
        var group = Shape.default
        group.id = ShapeId(11)
        group.name = "Group"
        group.kind = .group(children: [child], child: Xfrm())
        let slide = s.st.selection.slide
        try s.edit { doc, _ in doc.slides[slide].shapes = [group] }

        var v = s.run("slide.actions")
        let actions = v.get("actions")?.asArray ?? []
        #expect(actions.count == 3, "\(v.display)")
        guard actions.count == 3 else { return }
        #expect(actions[0].get("event") == "click")
        #expect(actions[0].get("type") == "nextSlide")
        #expect(actions[0].get("owner")?.get("path")?.at(0)?.get("name") == "Group")
        #expect(actions[0].get("owner")?.get("path")?.at(1)?.get("id")?.asU64 == 12)
        #expect(actions[1].get("event") == "hover")
        #expect(actions[1].get("target") == "https://example.com/hover")
        #expect(actions[2].get("event") == "textLink")
        #expect(actions[2].get("owner")?.get("runIndex")?.asU64 == 0)
        #expect(actions[2].get("target")?.asU64 == 7)

        var cellProps = RunProps()
        cellProps.hover = link(.url(url: "https://example.com/cell"))
        var table = Table(rows: 1, cols: 1, width: 100, rowHeight: 40)
        table.rows[0].cells[0].text.paragraphs = [Paragraph(runs: [Run.with("cell link", cellProps)])]
        var tableShape = Shape.default
        tableShape.id = ShapeId(13)
        tableShape.name = "Table"
        tableShape.kind = .table(table)
        try s.edit { doc, _ in doc.slides[slide].shapes.append(tableShape) }
        v = s.run("slide.actions")
        let tableAction = try #require(v.get("actions")?.asArray?.last)
        #expect(tableAction.get("event") == "textHover")
        #expect(tableAction.get("owner")?.get("tableRowIndex")?.asU64 == 0)
        #expect(tableAction.get("owner")?.get("tableCellIndex")?.asU64 == 0)
        #expect(tableAction.get("target") == "https://example.com/cell")
    }

    // inspect.rs tests::slide_actions_returns_empty_array_for_slide_without_actions
    @Test func slideActionsReturnsEmptyArrayForSlideWithoutActions() {
        let s = Session.withNew()
        #expect(s.run("slide.actions").get("actions") == [])
    }

    // inspect.rs tests::slide_actions_refuses_a_bad_index_instead_of_using_the_selection
    @Test func slideActionsRefusesABadIndexInsteadOfUsingTheSelection() {
        let s = Session.withNew()
        for index in ["-1", "\"0\"", "1.5"] { #expect(s.fails("slide.actions", "{\"index\": \(index)}"), "\(index)") }
    }

    private func textShape(_ id: UInt32, _ name: String, _ paragraphs: [Paragraph]) -> Shape {
        var sh = Shape.default
        sh.id = ShapeId(id)
        sh.name = name
        var body = TextBody.default
        body.paragraphs = paragraphs
        sh.text = body
        return sh
    }

    private func run(_ text: String, _ color: Rgba) -> Run {
        var p = RunProps()
        p.fill = .solid(.rgb(color))
        return Run.with(text, p)
    }

    // review.rs accessibility_contrast_tests::contrast_checks_mixed_runs_later_paragraphs_and_group_descendants_once
    @Test func contrastChecksMixedRunsLaterParagraphsAndGroupDescendantsOnce() throws {
        let s = Session.withNew()
        let (black, white) = (Rgba.rgb(0, 0, 0), Rgba.rgb(255, 255, 255))
        let child = textShape(5, "nested text", [Paragraph(runs: [run("hidden", white)])])
        var nested = Shape.default
        nested.id = ShapeId(7)
        nested.name = "nested group"
        nested.descr = "nested group of text"
        nested.kind = .group(children: [child], child: Xfrm())
        var group = Shape.default
        group.id = ShapeId(4)
        group.name = "group"
        group.descr = "group of text"
        group.kind = .group(children: [nested], child: Xfrm())
        var brk = run("\n", white)
        brk.kind = .break
        try s.edit { doc, _ in
            doc.slides[0].shapes = [
                textShape(2, "mixed", [Paragraph(runs: [run("visible", black), run("hidden", white)])]),
                textShape(3, "later paragraph", [Paragraph(runs: [run("visible", black)]), Paragraph(runs: [run("hidden", white)])]),
                group,
                textShape(6, "black control", [Paragraph(runs: [run("visible", black)])]),
                textShape(8, "invisible white runs", [Paragraph(runs: [run("visible", black), brk, run("  ", white), run("visible", black)])]),
            ]
        }
        let issues = s.run("review.accessibility")
        let contrasts = (issues.asArray ?? []).filter { $0.get("issue")?.asStr?.hasPrefix("Hard-to-read text contrast") == true }
        #expect(contrasts.count == 3, "\(issues.display)")
        for id: UInt64 in [2, 3, 5] { #expect(contrasts.contains { $0.get("shape")?.asU64 == id }, "missing shape \(id): \(issues.display)") }
        #expect(!contrasts.contains { $0.get("shape")?.asU64 == 6 }, "black control warned: \(issues.display)")
        #expect(!contrasts.contains { $0.get("shape")?.asU64 == 8 }, "white break or spaces warned: \(issues.display)")
    }
}
