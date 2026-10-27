// DCAppModelTests — the Views area's window-free logic: the navigator's and sorter's rows, clicks and drops,
// sections, New Window's state, the status bar's texts, the outline, the thumbnail cache, the notes draft
// and the pasteboard's routing. Ported from deckcraft `crates/ui-egui` (`sorter_tests.rs`, `doc_window.rs`,
// `notes.rs`, `status.rs`, `lib.rs`); each test names its source, Rust names in camelCase.
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct ViewsModelTests {
    /// A presentation of `n` slides (`sorter_tests.rs`' harness), optionally with sections Alpha (slides
    /// 1–2) and Beta (3–4).
    func session(_ n: Int = 4, sections: Bool = false) throws -> Session {
        let s = Session.withNew()
        for _ in 1 ..< n { _ = try s.execute("slide.new", .object(JSONObject())) }
        if sections {
            _ = try s.execute("section.add", ["name": "Alpha", "at": 0])
            _ = try s.execute("section.add", ["name": "Beta", "at": 2])
        }
        return s
    }

    func doc(_ s: Session) throws -> DocState { try #require(s.activeDoc) }

    func selected(_ s: Session) throws -> [Int] {
        let st = try doc(s)
        return st.selection.slides.compactMap { st.doc.slideIndex($0) }.sorted()
    }

    // MARK: Sorter (sorter_tests.rs)

    // sorter_tests.rs: drop_slot_and_move_dest
    @Test func dropSlotAndMoveDest() {
        #expect(SorterLogic.dropSlot([10, 40, 70], 0) == 0)
        #expect(SorterLogic.dropSlot([10, 40, 70], 20) == 1)
        #expect(SorterLogic.dropSlot([10, 40, 70], 100) == 3)
        #expect(SorterLogic.moveDest(1, 1) == nil)
        #expect(SorterLogic.moveDest(1, 2) == nil)
        #expect(SorterLogic.moveDest(1, 0) == 0)
        #expect(SorterLogic.moveDest(0, 2) == 1)
    }

    // sorter.rs: groups — sections in order, then the slides in none.
    @Test func groupsFollowTheSections() throws {
        let plain = try doc(try session(3)).doc
        #expect(SorterLogic.groups(plain).map(\.slides) == [[0, 1, 2]])
        #expect(SorterLogic.groups(plain).map(\.section) == [nil])
        let s = try session(4, sections: true)
        let g = SorterLogic.groups(try doc(s).doc)
        #expect(g.map(\.section) == [0, 1])
        #expect(g.map(\.slides) == [[0, 1], [2, 3]])
    }

    // sorter_tests.rs: add_section_splits_at_the_current_slide
    @Test func addSectionSplitsAtTheCurrentSlide() throws {
        let s = try session(4)
        #expect(try doc(s).doc.sections.isEmpty)
        // The Add Section button: `section.add` at the current slide (the last one, slide.new selects it).
        _ = try s.execute("section.add", ["at": .integer(try doc(s).selection.slide)])
        let d = try doc(s).doc
        #expect(d.sections.map(\.name) == ["Default Section", "Untitled Section"])
        #expect(d.sections.map(\.slides.count) == [3, 1])
        let rows = NavigatorLogic.rows(d, uid: try doc(s).uid, folded: [])
        #expect(rows.filter { $0.slideIndex != nil }.count == 4, "every slide is listed")
    }

    // sorter_tests.rs: collapse_hides_that_sections_slides_and_expand_brings_them_back
    @Test func collapseHidesThatSectionsSlidesAndExpandBringsThemBack() throws {
        let s = try session(4, sections: true)
        let st = try doc(s)
        let beta = try #require(st.doc.sections.at(1)?.slides.first)
        var folded: Set<FoldKey> = [FoldKey(uid: st.uid, firstSlide: beta.rawValue)]
        let rows = NavigatorLogic.rows(st.doc, uid: st.uid, folded: folded)
        #expect(rows.compactMap(\.slideIndex) == [0, 1])
        #expect(rows.contains(.section(index: 1, name: "Beta", count: 2, folded: true, first: beta.rawValue)))
        folded.removeAll()
        #expect(NavigatorLogic.rows(st.doc, uid: st.uid, folded: folded).compactMap(\.slideIndex) == [0, 1, 2, 3])
        // Another document's fold doesn't apply.
        let other: Set<FoldKey> = [FoldKey(uid: st.uid &+ 1, firstSlide: beta.rawValue)]
        #expect(NavigatorLogic.rows(st.doc, uid: st.uid, folded: other).compactMap(\.slideIndex) == [0, 1, 2, 3])
    }

    // sorter_tests.rs: dragging_a_section_moves_it_and_keeps_it_collapsed
    @Test func draggingASectionMovesItAndKeepsItCollapsed() throws {
        let s = try session(4, sections: true)
        let st = try doc(s)
        let before = st.doc.sections.map(\.slides)
        let beta = try #require(before[1].first)
        let folded: Set<FoldKey> = [FoldKey(uid: st.uid, firstSlide: beta.rawValue)]
        // Beta's bar dropped above Alpha's: the gap before the first bar.
        let to = try #require(SorterLogic.moveDest(1, SorterLogic.dropSlot([16, 140], 4)))
        _ = try s.execute("section.move", ["index": 1, "to": .integer(to)])
        let d = try doc(s).doc
        #expect(d.sections.map(\.name) == ["Beta", "Alpha"])
        #expect(d.sections.map(\.slides) == [before[1], before[0]])
        #expect(d.slides.map(\.id) == d.sections.flatMap(\.slides), "slides follow the section order")
        // The fold is keyed by the section's first slide, so Beta stays folded after the move.
        let rows = NavigatorLogic.rows(d, uid: st.uid, folded: folded)
        #expect(rows.first == .section(index: 0, name: "Beta", count: 2, folded: true, first: beta.rawValue))
        #expect(rows.compactMap(\.slideIndex) == [2, 3])
    }

    // sorter_tests.rs: ctrl_a_selects_every_slide (⌘A with the slide list focused runs Select All on the slides)
    @Test func ctrlASelectsEverySlide() throws {
        let s = try session(4)
        _ = try s.execute("edit.selectAll", ["scope": "slides"])
        #expect(try selected(s).count == 4)
    }

    // sorter_tests.rs: shift_and_ctrl_shift_clicks_select_ranges (and thumbs.rs' clicks)
    @Test func shiftAndCtrlShiftClicksSelectRanges() throws {
        let s = try session(4)
        func click(_ n: Int, shift: Bool = false, command: Bool = false) throws {
            let (id, p) = try #require(NavigatorLogic.click(try doc(s).doc, index: n - 1, shift: shift, command: command))
            _ = try s.execute(id, p)
        }
        // Click slide 2, Shift+click slide 4: slides 2–4, slide 4 current.
        try click(2)
        try click(4, shift: true)
        #expect(try selected(s) == [1, 2, 3])
        #expect(try doc(s).selection.slide == 3)
        // A second Shift+click extends from slide 2 again, not from slide 4.
        try click(1, shift: true)
        #expect(try selected(s) == [0, 1])
        // Click 1, Ctrl+click 3, Ctrl+Shift+click 4: the range joins what is selected.
        try click(1)
        try click(3, command: true)
        try click(4, shift: true, command: true)
        #expect(try selected(s) == [0, 2, 3])
        #expect(NavigatorLogic.isSelected(try doc(s), 2))
        #expect(!NavigatorLogic.isSelected(try doc(s), 1))
        #expect(NavigatorLogic.click(try doc(s).doc, index: 9, shift: false, command: false) == nil, "no slide 10")
    }

    // thumbs.rs: the drag's insertion slot → slide.move
    @Test func draggingASlideMovesIt() throws {
        let s = try session(4)
        let ids = try doc(s).doc.slides.map(\.id)
        // Slide 1 dropped in the gap after slide 3.
        let to = try #require(SorterLogic.moveDest(0, 3))
        _ = try s.execute("slide.move", ["from": 0, "to": .integer(to)])
        #expect(try doc(s).doc.slides.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
        #expect(SorterLogic.moveDest(2, 3) == nil, "the gap just after a slide leaves it in place")
    }

    // MARK: New Window (doc_window.rs)

    // doc_window.rs: the_window_title_marks_the_second_window
    @Test func theWindowTitleMarksTheSecondWindow() {
        #expect(DocWindowLogic.title("Quarterly review") == "Quarterly review:2")
    }

    // doc_window.rs: shifting_stops_at_the_ends
    @Test func shiftingStopsAtTheEnds() {
        #expect(DocWindowLogic.shift(0, -1, 3) == 0)
        #expect(DocWindowLogic.shift(1, 1, 3) == 2)
        #expect(DocWindowLogic.shift(2, 5, 3) == 2)
        #expect(DocWindowLogic.shift(0, 1, 0) == 0)
        #expect(DocWindowLogic.shift(1, .max, 3) == 2)
        #expect(DocWindowLogic.shift(1, .min, 3) == 0)
    }

    // doc_window.rs: command — opens on the editor's slide, moves only itself, closes.
    @Test func newWindowCommand() throws {
        let s = try session(3)
        _ = try s.execute("slide.go", ["index": 1])
        let st = try doc(s)
        let (opened, answer) = try DocWindowLogic.command(.object(JSONObject()), current: nil, active: st).get()
        #expect(opened == DocWindowState(uid: st.uid, slide: 1))
        #expect(answer["open"] == .bool(true) && answer["window"]?.asU64 == 2 && answer["slides"]?.asU64 == 3)
        let (moved, _) = try DocWindowLogic.command(["delta": 5], current: opened, active: st).get()
        #expect(moved?.slide == 2)
        #expect(st.selection.slide == 1, "the editor's selection doesn't move")
        let (jumped, _) = try DocWindowLogic.command(["slide": 99], current: moved, active: st).get()
        #expect(jumped?.slide == 2, "a slide past the end is the last")
        let (closed, a) = try DocWindowLogic.command(["on": false], current: jumped, active: st).get()
        #expect(closed == nil && a["open"] == .bool(false))
        #expect(throws: CommandError.self) { try DocWindowLogic.command(.object(JSONObject()), current: nil, active: nil).get() }
    }

    // MARK: Status bar (status.rs)

    @Test func statusTexts() throws {
        let s = try session(3)
        _ = try s.execute("slide.go", ["index": 1])
        #expect(StatusLogic.slideText(try doc(s)) == "Slide 2 of 3")
        _ = try s.execute("view.slideMaster", ["master": 0])
        #expect(StatusLogic.slideText(try doc(s)) == "Slide Master")
        _ = try s.execute("view.closeMaster", .object(JSONObject()))
        #expect(StatusLogic.slideText(try doc(s)) == "Slide 2 of 3")
        #expect(StatusLogic.languageName("en-US", locale: Locale(identifier: "en_US")) == "English (United States)")
    }

    // status.rs: a_long_language_name_leaves_the_notes_button_clickable — the language the status bar shows
    @Test func selectedLanguageFollowsTheSelection() throws {
        let s = Session.withNew()
        #expect(StatusLogic.selectedLanguage(s.activeDoc).lang == "en-US")
        _ = try s.execute("shape.insert", ["preset": "rect", "rect": [80, 120, 400, 100], "text": "hello"])
        _ = try s.execute("format.language", ["lang": "en-US-x-a-very-long-private-use-tag"])
        let (lang, noProof) = StatusLogic.selectedLanguage(s.activeDoc)
        #expect(lang == "en-US-x-a-very-long-private-use-tag")
        #expect(!noProof)
        #expect(StatusLogic.selectedLanguage(nil) == ("en-US", false))
    }

    // status.rs: status_bar_controls_have_names — the slider's range is 10–400 % on a log scale.
    @Test func zoomSliderIsLogarithmicFrom10To400Percent() {
        #expect(StatusLogic.percent(StatusLogic.sliderRange.lowerBound) == 10)
        #expect(StatusLogic.percent(StatusLogic.sliderRange.upperBound) == 400)
        #expect(StatusLogic.percent(StatusLogic.sliderValue(1)) == 100)
        #expect(StatusLogic.percent(StatusLogic.sliderValue(0.5)) == 50)
        #expect(StatusLogic.sliderValue(.nan) == 0)
        #expect(StatusLogic.percent(.infinity) == 100)
        #expect(StatusLogic.sliderValue(50) == StatusLogic.sliderRange.upperBound)
    }

    // MARK: Outline (sorter.rs outline_slide / outline_estimate)

    @Test func outlineEntriesReadTitlesAndLevels() throws {
        let s = Session()
        try Sample.openSample(s)
        let d = try doc(s).doc
        let first = try #require(OutlineLogic.entry(d, 0))
        #expect(first.title == "Northern Lights")
        #expect(first.titleShape != nil)
        let lists = (0 ..< d.slides.count).compactMap { OutlineLogic.entry(d, $0) }.flatMap(\.bodies).map(\.text)
        #expect(lists.contains { $0.hasPrefix("Bring\n\tTripod") }, "a level-1 paragraph reads with a tab")
        #expect(OutlineLogic.entry(d, 999) == nil)
        let slide = try #require(d.slides.first)
        #expect(OutlineLogic.estimate(slide) >= 30)
    }

    // sorter.rs: outline text set back through text.set keeps the levels
    @Test func outlineTextRoundTripsThroughTextSet() throws {
        let s = Session()
        try Sample.openSample(s)
        let d = try doc(s).doc
        let found = (0 ..< d.slides.count).lazy.compactMap { i in OutlineLogic.entry(d, i)?.bodies.first { $0.text.contains("\t") }.map { (i, $0) } }.first
        let (i, block) = try #require(found)
        _ = try s.execute("slide.go", ["index": .integer(i)])
        let edited = block.text + "\n\tA new point"
        _ = try s.execute("text.set", ["id": .integer(block.shape.rawValue), "text": .string(edited)])
        let after = try #require(OutlineLogic.entry(try doc(s).doc, i)?.bodies.first { $0.shape == block.shape })
        #expect(after.text == edited)
    }

    // MARK: Thumbnails (textures.rs thumb, huge_deck_tests.rs)

    @Test func thumbnailCacheIsKeyedBySlideValueAndBounded() throws {
        let s = try session(3)
        let d = try doc(s).doc
        let cache = ThumbCache<String>(limit: 4, evict: 2)
        let master = d.masters.first
        let slide = d.slides[0]
        #expect(cache.lookup(slide, master: master, width: 100).image == nil)
        cache.store("a", slide: slide, master: master, width: 100)
        #expect(cache.lookup(slide, master: master, width: 100) == ("a", true))
        #expect(cache.lookup(slide, master: master, width: 200) == ("a", false), "another size: stale until redrawn")
        var edited = slide
        edited.hidden = true
        #expect(cache.lookup(edited, master: master, width: 100) == ("a", false), "an edited slide: stale")
        var m2 = master
        m2?.name = "Changed"
        #expect(cache.lookup(slide, master: m2, width: 100).fresh == false, "an edited master: stale")
        #expect(cache.renders == 1 && cache.count == 1)
        // Past the limit the least recently used go.
        for i in 0 ..< 5 {
            var x = slide
            x.id = SlideId(UInt32(1000 + i))
            cache.store("\(i)", slide: x, master: master, width: 100)
        }
        #expect(cache.count <= 4)
        #expect(cache.renders == 6)
    }

    // MARK: Notes (notes.rs)

    /// notes.rs' `notes()`: a bold heading, a plain line, Wingdings square bullets with a hanging indent,
    /// numbered points, an explicit buNone, plain lines; Slovak text.
    func notes() -> TextBody {
        func props(_ b: Bullet) -> ParaProps {
            var p = ParaProps()
            p.marginLeft = 22.5
            p.indent = -22.5
            p.bullet = b
            p.bulletFont = "Wingdings"
            return p
        }
        func para(_ runs: [Run], level: UInt8 = 0, props: ParaProps = ParaProps()) -> Paragraph {
            var p = Paragraph()
            p.level = level
            p.props = props
            p.runs = runs
            return p
        }
        var bold = RunProps()
        bold.bold = true
        let square = Bullet.char(char: "§")
        let num = Bullet.autoNum(scheme: "arabicPeriod", startAt: 1)
        var body = TextBody()
        body.paragraphs = [
            para([Run(text: "Metodický prehľad", props: bold, kind: .text)]),
            para([Run(text: "Žiaci pracujú vo dvojiciach.", props: RunProps(), kind: .text)]),
            para([Run(text: "Cieľ: ", props: bold, kind: .text), Run(text: "vysvetliť cyklus", props: RunProps(), kind: .text)], level: 1, props: props(square)),
            para([Run(text: "Dlhý bod, ktorý sa zalomí na viac riadkov, lebo je naozaj veľmi dlhý a pokračuje ďalej.", props: RunProps(), kind: .text)], level: 1, props: props(square)),
            para([Run(text: "Jeden", props: RunProps(), kind: .text)], level: 1, props: props(num)),
            para([Run(text: "Dva", props: RunProps(), kind: .text)], level: 1, props: props(num)),
            para([Run(text: "Bez odrážky", props: RunProps(), kind: .text)], level: 1, props: props(.none_)),
            para([Run(text: "Pomôcky: počítač", props: RunProps(), kind: .text)]),
        ]
        return body
    }

    // notes.rs: bullets_follow_the_paragraphs
    @Test func bulletsFollowTheParagraphs() {
        #expect(NotesLogic.bullets(notes()) == [nil, nil, "▪", "▪", "1.", "2.", nil, nil])
    }

    // notes.rs: notes_show_bold_runs_indents_and_wrap_under_the_text — the indents (the drawing is AppKit's)
    @Test func notesIndentsHangTheBullets() {
        let b = notes()
        #expect(NotesLogic.indents(b.paragraphs[0]) == (0, 0), "plain paragraphs aren't indented")
        #expect(NotesLogic.indents(b.paragraphs[2]) == (0, 22.5), "bulleted text at the 22.5 pt margin, the bullet hanging to 0")
        var lvl = Paragraph()
        lvl.level = 2
        #expect(NotesLogic.indents(lvl) == (72, 72), "a level without a margin: 36 pt per level")
    }

    // notes.rs: typing_keeps_the_formatting_around_it
    @Test func typingKeepsTheFormattingAroundIt() throws {
        var d = NotesDraft(notes())
        // Typing into the bold heading continues it in bold.
        d.type(d.text.replacingOccurrences(of: "prehľad", with: "prehľad hodiny"))
        #expect(d.edited)
        #expect(d.body.paragraphs[0].runs.count == 1)
        #expect(d.body.paragraphs[0].runs[0].props.bold == true)
        // Enter at the end of a bulleted point starts another one with the same bullet and indent.
        d.type(d.body.text.replacingOccurrences(of: "cyklus", with: "cyklus\nnový bod"))
        let new = d.body.paragraphs[3]
        #expect(new.text == "nový bod")
        #expect(new.level == 1 && new.props == notes().paragraphs[2].props)
        #expect(d.body.paragraphs[2].runs[0].props.bold == true, "the bold label stays bold")
        #expect(NotesLogic.typed(notes(), "Metodický prehľad") != nil)
        // Hostile sizes and indents stay bounded.
        #expect(NotesLogic.px(.nan, 1) == 0)
        #expect(NotesLogic.px(1e9, 1) == 400)
        var big = RunProps()
        big.size = .infinity
        #expect(NotesLogic.runSize(big, base: 12) == 12)
        big.size = 1000
        #expect(NotesLogic.runSize(big, base: 12) == 24)
    }

    // MARK: Pasteboard (lib.rs)

    // lib.rs: a_textless_shape_copies_as_the_objects_marker; the marker pastes the session's copy
    @Test func aTextlessShapeCopiesAsTheObjectsMarker() {
        #expect(PasteboardLogic.systemText("") == PasteboardLogic.objectsMarker)
        #expect(PasteboardLogic.systemText("hello") == "hello")
        #expect(PasteboardLogic.action(owned: false, text: PasteboardLogic.objectsMarker, html: nil, hasImage: false) == .session)
    }

    // lib.rs: the paste routing — own copy, picture only without text, text with its HTML
    @Test func pasteRouting() {
        #expect(PasteboardLogic.action(owned: true, text: "x", html: nil, hasImage: true) == .session)
        #expect(PasteboardLogic.action(owned: false, text: nil, html: nil, hasImage: true) == .picture)
        #expect(PasteboardLogic.action(owned: false, text: "Hi", html: "<b>Hi</b>", hasImage: true) == .text("Hi", html: "<b>Hi</b>"))
        #expect(PasteboardLogic.action(owned: false, text: "Hi", html: "", hasImage: false) == .text("Hi", html: nil))
        #expect(PasteboardLogic.pasteParams(.picture, slides: false) == nil)
        #expect(PasteboardLogic.pasteParams(.session, slides: true) == ["scope": "slides"])
        #expect(PasteboardLogic.pasteParams(.text("a", html: "<i>a</i>"), slides: false) == ["text": "a", "html": "<i>a</i>"])
    }

    // lib.rs: color_image_png's bounds (MAX_PASTE_IMAGE_PIXELS)
    @Test func pastedImagesAreBounded() {
        #expect(PasteboardLogic.imageProblem(width: 1, height: 1) == nil)
        #expect(PasteboardLogic.imageProblem(width: 0, height: 10) != nil)
        #expect(PasteboardLogic.imageProblem(width: 5000, height: 5000) != nil)
        #expect(PasteboardLogic.imageProblem(width: .max, height: 2) != nil)
    }
}
