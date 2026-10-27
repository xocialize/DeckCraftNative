// DCAppTests — the Views area with real views, in-process: the navigator, the Slide Sorter and the Outline
// on large decks (deckcraft `huge_deck_tests.rs`), the sorter's sections (`sorter_tests.rs`), the notes
// pane's saving (`status.rs` notes_pane), New Window (`doc_window.rs`), printing and the pasteboard
// (`apps/deckcraft/src/pasteboard.rs`, `lib.rs`). Each test names its source, Rust names in camelCase.
import AppKit
import DCCore
import DCEngine
import DCModel
import DCRender
import Foundation
import Testing
@testable import DCApp
@testable import DCAppModel

@MainActor
@Suite(.serialized) struct ViewsWindowTests {
    /// A model on a presentation of `n` slides, and its link.
    func model(_ n: Int, sections: Bool = false) throws -> (AppModel, DocLink) {
        let s = Session.withNew()
        for _ in 1 ..< n { _ = try s.execute("slide.new", .object(JSONObject())) }
        if sections {
            _ = try s.execute("section.add", ["name": "Alpha", "at": 0])
            _ = try s.execute("section.add", ["name": "Beta", "at": 2])
        }
        _ = try s.execute("slide.go", ["index": 0])
        let m = AppModel(session: s)
        let uid = try #require(s.activeDoc?.uid)
        return (m, DocLink(model: m, uid: { uid }))
    }

    /// A window of `size` showing `vc`.
    func window(_ vc: NSViewController, _ size: NSSize = NSSize(width: 1400, height: 900)) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = vc
        w.setContentSize(size)
        w.layoutIfNeeded()
        return w
    }

    /// Run the main loop until the thumbnails are drawn.
    func settle() async {
        for _ in 0 ..< 400 {
            try? await Task.sleep(for: .milliseconds(10))
            if !Thumbnails.shared.busy { break }
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: Navigator

    /// The skeleton's rows were taller than their thumbnails: a row is its thumbnail plus the padding, and
    /// the thumbnail is as wide as the column allows.
    @Test func navigatorRowsFitTheirThumbnails() throws {
        let (_, link) = try model(3)
        let nav = NavigatorViewController(link: link)
        let w = window(nav, NSSize(width: 236, height: 700))
        defer { w.close() }
        nav.refresh()
        #expect(nav.table.numberOfRows == 3)
        let thumb = nav.thumbSize(.slide(0))
        #expect(thumb.width <= nav.scroll.contentSize.width - NavigatorMetrics.gutter)
        #expect(abs(thumb.height / thumb.width - 0.5625) < 0.01)
        #expect(nav.table.rect(ofRow: 0).height == thumb.height + 2 * NavigatorMetrics.pad)
    }

    // thumbs.rs: the navigator's clicks run the engine's selection; Return adds a slide; drag → slide.move
    @Test func navigatorClicksSelectThroughTheEngine() throws {
        let (m, link) = try model(4)
        let nav = NavigatorViewController(link: link)
        let w = window(nav, NSSize(width: 236, height: 700))
        defer { w.close() }
        nav.refresh()
        nav.click(row: 1, shift: false, command: false)
        nav.click(row: 3, shift: true, command: false)
        let st = try #require(link.state)
        #expect(st.selection.slide == 3)
        #expect(st.selection.slides.compactMap { st.doc.slideIndex($0) }.sorted() == [1, 2, 3])
        #expect(nav.slot(above: 2) == 2)
        #expect(nav.slot(above: 99) == 4)
        _ = m
    }

    // thumbs.rs: sections show as bars; folding hides their slides
    @Test func navigatorShowsSectionsAndFolds() throws {
        let (m, link) = try model(4, sections: true)
        let nav = NavigatorViewController(link: link)
        let w = window(nav, NSSize(width: 236, height: 700))
        defer { w.close() }
        nav.refresh()
        #expect(nav.items.count == 6)
        guard case .section(_, "Beta", 2, false, let first)? = nav.items.at(3) else {
            Issue.record("Beta's bar is the fourth row: \(nav.items)")
            return
        }
        SectionFolds.toggle(link.uid, first, model: m)
        nav.refresh()
        #expect(nav.items.count == 4, "Beta's slides are folded away")
        SectionFolds.toggle(link.uid, first, model: m)
        nav.refresh()
        #expect(nav.items.count == 6)
    }

    // thumbs.rs: navigating_slides_keeps_the_current_thumbnail_visible (#917)
    @Test func navigatingSlidesKeepsTheCurrentThumbnailVisible() throws {
        let (m, link) = try model(31)
        let nav = NavigatorViewController(link: link)
        let w = window(nav, NSSize(width: 236, height: 700))
        defer { w.close() }
        nav.refresh()
        #expect(link.model.ui.thumbsScroll == 0, "the pane starts at the top")
        // Jump to the last slide: the pane follows and reveals it.
        m.run("slide.go", ["index": 30])
        nav.refresh()
        let jumped = nav.scroll.contentView.bounds.origin.y
        #expect(jumped > 100, "the pane scrolled to the last slide, offset \(jumped)")
        #expect(nav.table.rows(in: nav.table.visibleRect).contains(30))
        #expect(link.model.ui.thumbsScroll == Double(jumped), "the offset is reported (ui.inspect thumbsScroll)")
        // One slide up was already on screen after that scroll: the pane holds still.
        m.run("slide.go", ["index": 29])
        nav.refresh()
        #expect(abs(nav.scroll.contentView.bounds.origin.y - jumped) < 1, "no re-scroll for a visible slide")
    }

    // huge_deck_tests.rs: the_thumbnail_pane_of_a_huge_deck_renders_only_the_slides_in_view,
    // a_settled_thumbnail_pane_renders_nothing_more
    @Test func theThumbnailPaneOfAHugeDeckRendersOnlyTheSlidesInView() async throws {
        let (_, link) = try model(1000)
        let nav = NavigatorViewController(link: link)
        let w = window(nav, NSSize(width: 236, height: 900))
        defer { w.close() }
        nav.refresh()
        nav.redrawVisible()
        await settle()
        nav.redrawVisible()
        await settle()
        let (held, rendered) = (Thumbnails.shared.count(link.uid), Thumbnails.shared.renders(link.uid))
        #expect(held > 3 && held < 60, "\(held) thumbnails held")
        #expect(rendered >= UInt64(held) && rendered < UInt64(held) * 2, "\(rendered) renders for \(held) thumbnails")
        // More refreshes of the same view: not one more render.
        for _ in 0 ..< 5 { nav.refresh() }
        await settle()
        #expect(Thumbnails.shared.renders(link.uid) == rendered, "a settled pane renders nothing more")
        // Scrolled far down: the slides now in view are drawn, and only those.
        nav.table.scrollRowToVisible(800)
        nav.redrawVisible()
        await settle()
        let after = Thumbnails.shared.renders(link.uid)
        #expect(after > rendered && after < 100, "\(after) renders after one scroll of a 1,000-slide deck (was \(rendered))")
    }

    // MARK: Slide Sorter

    // huge_deck_tests.rs: the_sorter_of_a_huge_deck_renders_only_the_slides_in_view, a_settled_sorter_renders_nothing_more
    @Test func theSorterOfAHugeDeckRendersOnlyTheSlidesInView() async throws {
        let (_, link) = try model(800)
        let sorter = SorterViewController(link: link)
        let w = window(sorter)
        defer { w.close() }
        sorter.refresh()
        sorter.collection.layoutSubtreeIfNeeded()
        sorter.redrawVisible()
        await settle()
        let (held, rendered) = (Thumbnails.shared.count(link.uid), Thumbnails.shared.renders(link.uid))
        #expect(held > 3 && held < 80, "\(held) thumbnails held")
        #expect(rendered >= UInt64(held) && rendered < UInt64(held) * 2)
        sorter.refresh()
        await settle()
        #expect(Thumbnails.shared.renders(link.uid) == rendered, "a settled sorter renders nothing more")
    }

    // sorter_tests.rs: collapse_hides_that_sections_slides_and_expand_brings_them_back
    @Test func sorterCollapseHidesThatSectionsSlides() throws {
        let (_, link) = try model(4, sections: true)
        let sorter = SorterViewController(link: link)
        let w = window(sorter)
        defer { w.close() }
        sorter.refresh()
        #expect(sorter.groups.map(\.slides) == [[0, 1], [2, 3]])
        sorter.toggleFold(section: 1)
        sorter.refresh()
        #expect(sorter.groups.map(\.slides) == [[0, 1], []])
        #expect(sorter.collection.numberOfItems(inSection: 1) == 0)
        sorter.toggleFold(section: 1)
        sorter.refresh()
        #expect(sorter.groups.map(\.slides) == [[0, 1], [2, 3]])
    }

    // sorter_tests.rs: double_click_renames_and_switching_documents_drops_the_draft
    @Test func renamingAndSwitchingDocumentsDropsTheDraft() throws {
        let (m, link) = try model(4, sections: true)
        let sorter = SorterViewController(link: link)
        let w = window(sorter)
        defer { w.close() }
        sorter.refresh()
        sorter.beginRename(1)
        #expect(sorter.renaming == 1)
        sorter.endRename("Gamma")
        #expect(link.state?.doc.sections.map(\.name) == ["Alpha", "Gamma"])
        #expect(sorter.renaming == nil)
        sorter.beginRename(1)
        sorter.endRename(nil)
        #expect(link.state?.doc.sections.map(\.name) == ["Alpha", "Gamma"], "Escape keeps the name")
        sorter.beginRename(1)
        sorter.endRename("   ")
        #expect(link.state?.doc.sections.map(\.name) == ["Alpha", "Gamma"], "a blank name is ignored")
        // Another presentation becomes the sorter's: the draft goes.
        sorter.beginRename(1)
        let other = DocLink(model: m) { m.session.documents.last?.uid ?? 0 }
        _ = m.run("file.new")
        let switched = SorterViewController(link: other)
        let w2 = window(switched)
        defer { w2.close() }
        switched.refresh()
        #expect(switched.renaming == nil)
        sorter.refresh()
        #expect(link.state?.doc.sections.map(\.name) == ["Alpha", "Gamma"])
    }

    // sorter_tests.rs: dragging_a_section_moves_it_and_keeps_it_collapsed — the drop slots
    @Test func sorterDropSlots() throws {
        let (_, link) = try model(4, sections: true)
        let sorter = SorterViewController(link: link)
        let w = window(sorter)
        defer { w.close() }
        sorter.refresh()
        sorter.collection.layoutSubtreeIfNeeded()
        #expect(sorter.slideSlot(IndexPath(item: 0, section: 1)) == 2)
        #expect(sorter.slideSlot(IndexPath(item: 2, section: 1)) == 4, "after the last slide of the last section")
        #expect(sorter.sectionSlot(NSPoint(x: 10, y: -10)) == 0, "above every bar")
        #expect(sorter.sectionSlot(NSPoint(x: 10, y: 100_000)) == 2, "below every bar")
    }

    // MARK: Outline

    // huge_deck_tests.rs: the_outline_of_a_huge_deck_lays_out_only_what_is_in_view
    @Test func theOutlineOfAHugeDeckLaysOutOnlyWhatIsInView() throws {
        let (m, link) = try model(2000)
        let outline = OutlineViewController(link: link)
        let w = window(outline, NSSize(width: 360, height: 900))
        defer { w.close() }
        m.run("view.outline")
        outline.refresh()
        outline.table.layoutSubtreeIfNeeded()
        let shown = outline.table.rows(in: outline.table.visibleRect).length
        #expect(shown > 5 && shown < 200, "\(shown) rows laid out")
        // The current slide is shown, wherever it is.
        m.run("slide.go", ["index": 1500])
        outline.refresh()
        outline.table.layoutSubtreeIfNeeded()
        let visible = outline.table.rows(in: outline.table.visibleRect)
        #expect(visible.contains(1500))
        #expect(visible.length < 200)
        #expect(link.state?.selection.slide == 1500)
    }

    // sorter.rs outline_slide: a title typed in the outline runs text.set on the title placeholder
    @Test func outlineEditsSetTheText() throws {
        let s = Session()
        try Sample.openSample(s)
        let m = AppModel(session: s)
        let uid = try #require(s.activeDoc?.uid)
        let link = DocLink(model: m) { uid }
        let outline = OutlineViewController(link: link)
        let w = window(outline, NSSize(width: 360, height: 900))
        defer { w.close() }
        outline.refresh()
        let st = try #require(link.state)
        let e = try #require(OutlineLogic.entry(st.doc, 0))
        outline.commit(0, shape: e.titleShape, old: e.title, text: "Southern Lights")
        #expect(link.state?.doc.slides.first?.title == "Southern Lights")
        outline.focus(2)
        #expect(link.state?.selection.slide == 2)
    }

    // MARK: Notes

    // status.rs notes_pane: an edited draft is saved to the slide it was written on when another slide shows
    @Test func notesAreSavedToTheSlideTheyWereWrittenOn() throws {
        let (m, link) = try model(3)
        let pane = NotesPaneController(link: link)
        let w = window(pane, NSSize(width: 600, height: 120))
        defer { w.close() }
        pane.refresh()
        pane.editor.textView.string = "Remember the demo"
        pane.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(pane.editor.draft.edited)
        m.run("slide.go", ["index": 2])
        pane.refresh()
        #expect(link.state?.doc.slides.first?.notes.text == "Remember the demo")
        #expect(link.state?.doc.slides.at(2)?.notes.text == "")
        #expect(pane.editor.textView.string == "", "the pane shows slide 3's notes")
    }

    // notes.rs: notes_show_bold_runs_indents_and_wrap_under_the_text — the editor's attributes
    @Test func notesShowBoldRunsAndIndents() {
        var bold = RunProps()
        bold.bold = true
        var props = ParaProps()
        props.marginLeft = 22.5
        props.indent = -22.5
        props.bullet = .char(char: "•")
        let body = TextBody(paragraphs: [
            Paragraph(runs: [Run(text: "Heading", props: bold, kind: .text)]),
            Paragraph(level: 1, props: props, runs: [Run(text: "A point", props: RunProps(), kind: .text)]),
        ])
        let a = NotesText.attributed(body, base: 12, color: .labelColor)
        #expect(a.string == body.text)
        let font = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let at = (a.string as NSString).range(of: "A point").location
        let style = a.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == 22.5)
        #expect((style?.firstLineHeadIndent ?? 0) >= 22.5, "the text clears the hanging bullet")
    }

    // MARK: New Window (doc_window.rs)

    @Test func newWindowShowsItsOwnSlide() throws {
        let (m, _) = try model(3)
        defer { ViewsFeature.docWindow?.close() }
        let a = try ViewsFeature.newWindow(m, .object(JSONObject())).get()
        #expect(a["open"] == .bool(true))
        let w = try #require(ViewsFeature.docWindow)
        #expect(w.window?.title.hasSuffix(":2") == true)
        _ = try ViewsFeature.newWindow(m, ["delta": 1]).get()
        #expect(w.state.slide == 1)
        #expect(m.session.activeDoc?.selection.slide == 0, "the editor's slide stays")
        #expect(w.counter.stringValue == "Slide 2 of 3")
        _ = try ViewsFeature.newWindow(m, ["on": false]).get()
        #expect(ViewsFeature.docWindow == nil)
    }

    // MARK: Printing (gap #6)

    @Test func printsEveryLayoutToAPDF() throws {
        _ = NSApplication.shared
        // A small deck: PDF export of the sample takes seconds in a debug build.
        let (m, _) = try model(5)
        m.run("slide.hide", ["index": 1])
        m.run("slide.notes", ["text": "Speaker notes"])
        let count = 5
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func pages(_ p: JSON) -> Int? {
            let path = dir.appending(path: "\(UUID().uuidString).pdf").path
            var q = p
            q.setKey("path", .string(path))
            switch Printer.command(m, q, window: nil) {
            case .failure(let e):
                Issue.record("\(p): \(e)")
                return nil
            case .success(let a):
                #expect(a["printed"] == .bool(true), "\(a)")
                return CGPDFDocument(URL(filePath: path) as CFURL)?.numberOfPages
            }
        }
        #expect(pages(["layout": "slides"]) == count - 1, "hidden slides are left out")
        #expect(pages(["layout": "slides", "includeHidden": true]) == count)
        #expect(pages(["layout": "notes"]) == count - 1)
        #expect(pages(["layout": "handouts", "perPage": 2]) == (count - 1 + 1) / 2)
        #expect(pages(["layout": "handouts", "perPage": 9, "grayscale": true, "frame": false]) == 1)
        #expect(pages(["layout": "outline"]) == 1)
        #expect(throws: CommandError.self) { try Printer.command(m, ["layout": "handouts", "perPage": 5], window: nil).get() }
        #expect(throws: CommandError.self) { try Printer.command(AppModel(session: Session()), .object(JSONObject()), window: nil).get() }
    }

    @Test func printSettingsMapToTheExportOptions() throws {
        let s = Session()
        try Sample.openSample(s)
        let d = try #require(s.activeDoc).doc
        let settings = try PrintSettings(params: ["layout": "handouts", "perPage": 3, "slides": "1-2", "paper": "a4"])
        #expect(settings.layout == .handouts(perPage: 3))
        let o = try settings.pdfOptions(d, paper: (600, 800))
        #expect(o.layout == .handouts(perPage: 3))
        #expect(o.slides == [0, 1])
        #expect(o.paper.0 == 595.28, "the asked-for paper wins over the printer's")
        #expect(!o.textLayer)
        let lines = PrintLogic.outline(d, [0, 1])
        #expect(lines.first == OutlineLine(number: 1, level: 0, text: "Northern Lights", isTitle: true))
        #expect(lines.contains { $0.number == 2 })
    }

    // MARK: Soak (ui_soak_tests.rs)

    /// ui_soak_tests.rs' generator: xorshift, as the Rust test seeds it.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }

        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    // ui_soak_tests.rs: ui_soak — seeded random actions over every Views view (switching views, clicks
    // with and without ⇧/⌘, slides and sections added, moved, hidden and removed, folds, notes typed,
    // undo and redo), with the views' invariants checked after each: no crash, every view lists the
    // presentation as it is.
    @Test func viewsSoak() throws {
        let s = Session()
        try Sample.openSample(s)
        let m = AppModel(session: s)
        let uid = try #require(s.activeDoc?.uid)
        let link = DocLink(model: m) { uid }
        let nav = NavigatorViewController(link: link)
        let sorter = SorterViewController(link: link)
        let outline = OutlineViewController(link: link)
        let pane = NotesPaneController(link: link)
        let windows = [window(nav, NSSize(width: 236, height: 800)), window(sorter), window(outline, NSSize(width: 360, height: 800)), window(pane, NSSize(width: 600, height: 120))]
        defer { windows.forEach { $0.close() } }
        var rng = Rng(state: 0x5EED_DECC_4AF7)
        let views = ["view.normal", "view.outline", "view.sorter", "view.notesPage"]
        for step in 0 ..< 400 {
            let n = link.state?.doc.slides.count ?? 0
            let sections = link.state?.doc.sections.count ?? 0
            switch rng.below(12) {
            case 0: m.run(views[rng.below(views.count)])
            case 1: nav.click(row: rng.below(nav.items.count + 2), shift: rng.below(3) == 0, command: rng.below(3) == 0)
            case 2: sorter.click(slide: rng.below(n + 2), shift: rng.below(3) == 0, command: rng.below(3) == 0)
            case 3: m.run(["slide.new", "slide.duplicate", "slide.delete"][rng.below(3)])
            case 4: m.run("section.add", ["at": .integer(rng.below(max(1, n)))])
            case 5: m.run("section.remove", ["index": .integer(rng.below(sections + 1))])
            case 6:
                if let sec = link.state?.doc.sections.at(rng.below(max(1, sections))) {
                    SectionFolds.toggle(uid, sec.slides.first?.rawValue, model: m)
                }
            case 7:
                if let to = SorterLogic.moveDest(rng.below(max(1, n)), rng.below(n + 1)) {
                    m.run("slide.move", ["from": .integer(rng.below(max(1, n))), "to": .integer(min(to, max(0, n - 1)))])
                }
            case 8: m.run(rng.below(2) == 0 ? "edit.undo" : "edit.redo")
            case 9:
                pane.editor.textView.string = "Note \(step)"
                pane.editor.textDidChange(Notification(name: NSText.didChangeNotification))
            case 10: m.run("slide.hide", ["index": .integer(rng.below(max(1, n)))])
            default: m.run("section.move", ["index": .integer(rng.below(max(1, sections))), "to": .integer(rng.below(max(1, sections)))])
            }
            nav.refresh()
            sorter.refresh()
            outline.refresh()
            pane.refresh()
            let st = try #require(link.state)
            let rows = NavigatorLogic.rows(st.doc, uid: uid, folded: SectionFolds.folded)
            #expect(nav.items.count == rows.count, "step \(step): the navigator lists every row")
            #expect(outline.count == st.doc.slides.count, "step \(step): the outline lists every slide")
            let shown = sorter.groups.reduce(0) { $0 + $1.slides.count }
            #expect(shown == rows.compactMap(\.slideIndex).count, "step \(step): the sorter shows the slides the navigator does")
            #expect(st.selection.slide < max(1, st.doc.slides.count))
        }
        #expect(s.journal.count < 10_000)
    }

    // MARK: Pasteboard (pasteboard.rs, lib.rs)

    func board() -> PasteboardBridge { PasteboardBridge(board: NSPasteboard(name: NSPasteboard.Name("dc-views-test-\(UUID().uuidString)"))) }

    // lib.rs: copy_and_cut_commands_reach_the_system_clipboard, a_textless_shape_copies_as_the_objects_marker,
    // the context-menu paste of the copied rectangle (#182)
    @Test func aCopiedShapeIsTheMarkerAPictureAndPastesBack() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, _) = try model(1)
        m.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 120]])
        let before = m.session.activeDoc?.currentSlide?.shapes.count ?? 0
        _ = try pb.copy(m, cut: false, slides: false).get()
        #expect(pb.board.string(forType: .string) == PasteboardLogic.objectsMarker)
        #expect(pb.board.data(forType: .png) != nil, "other apps get a picture")
        let pdf = try #require(pb.board.data(forType: .pdf))
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        #expect(CGPDFDocument(provider)?.numberOfPages == 1)
        #expect(pb.owned)
        _ = try pb.paste(m, slides: false).get()
        #expect(m.session.activeDoc?.currentSlide?.shapes.count == before + 1, "a copy of the rectangle, not a text box holding the marker")
    }

    // lib.rs: copy_and_cut_commands_reach_the_system_clipboard — Copy from the control channel or a script
    @Test func copyFromAnywhereReachesThePasteboard() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, _) = try model(1)
        m.run("shape.insert", ["preset": "rect", "rect": [80, 120, 400, 100], "text": "Aurora"])
        m.run("edit.copy")
        pb.flushPending(m)
        #expect(pb.board.string(forType: .string) == "Aurora")
        #expect(m.pendingCopy == nil)
    }

    // pasteboard.rs: html_and_a_picture_round_trip_on_macos; lib.rs: rich text from another app keeps its bold
    @Test func textAndHtmlFromAnotherAppPasteAsText() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, _) = try model(1)
        pb.board.clearContents()
        pb.board.setString("<p><b>Hi</b> there</p>", forType: .html)
        pb.board.setString("Hi there", forType: .string)
        #expect(!pb.owned)
        _ = try pb.paste(m, slides: false).get()
        let shape = try #require(m.session.activeDoc?.currentSlide?.shapes.last)
        #expect(shape.text?.text == "Hi there")
        #expect(shape.text?.paragraphs.first?.runs.first?.props.bold == true)
    }

    // lib.rs: ctrl_v_with_only_an_image_inserts_a_picture (#53), paste_image_event_inserts_one_picture
    @Test func aPictureFromAnotherAppIsInserted() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, _) = try model(1)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        pb.board.clearContents()
        pb.board.setData(rep.tiffRepresentation, forType: .tiff)
        let before = m.session.activeDoc?.currentSlide?.shapes.count ?? 0
        _ = try pb.paste(m, slides: false).get()
        #expect(m.session.activeDoc?.currentSlide?.shapes.count == before + 1, "one picture")
        if case .picture? = m.session.activeDoc?.currentSlide?.shapes.last?.kind {} else {
            Issue.record("the pasted shape is a picture")
        }
    }

    // lib.rs: a slide copy pastes as slides through the session
    @Test func slidesCopyAndPasteThroughTheSession() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, _) = try model(2)
        _ = try pb.copy(m, cut: false, slides: true).get()
        _ = try pb.paste(m, slides: true).get()
        #expect(m.session.activeDoc?.doc.slides.count == 3)
    }

    // The Edit menu reaches a text view with the keyboard instead of the slide.
    @Test func theEditMenuReachesTheFocusedTextView() throws {
        #expect(PasteboardBridge.textAction("edit.paste") == #selector(NSText.paste(_:)))
        #expect(PasteboardBridge.textAction("edit.selectAll") == #selector(NSText.selectAll(_:)))
        #expect(PasteboardBridge.textAction("edit.undo") == nil)
    }
}
