// DCEngineTests — the `text` command module: editing in place, AutoCorrect and AutoFormat, the input
// method, right-to-left text, hyperlinked text, the caret, Replace Fonts.
// Ports the in-file tests of deckcraft crates/engine/src/cmd/text.rs (rtl_promote_tests,
// ime_surrounding_tests, replace_font_tests, select_paragraph_tests) and the text tests of tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Not ported here:
// - tests.rs `cut_with_only_a_caret_changes_nothing`, `bold_copy_is_html_and_pages_html_pastes_bold`,
//   `new_slide_body_tabs_match_text_set`: ported by the core (EditTests, SlideTests).
// - tests.rs `click_into_placeholder_starts_editing`, `right_click_in_edited_text_keeps_the_text_selection`,
//   `dragging_the_frame_of_edited_text_moves_the_box`, `frame_of_rotated_edited_text_follows_the_rotation`,
//   `a_shape_in_front_of_edited_text_takes_the_click`: they drive `Session.pointer`, so they are in
//   PointerTests.swift.
// - tests.rs `header_footer_fixed_date_is_the_slides_own_text` (design.headerFooter, insert.dateTime) and
//   `smartart_text_pane_edits_regenerate_the_diagram` (insert.smartArt) belong to the design and insert
//   groups' commands.
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCText
import Foundation
import Testing

/// The first shape of the current slide (a new deck's title placeholder).
private func titleId(_ s: Session) -> UInt32 { s.st.currentSlide?.shapes.first?.id.rawValue ?? 0 }

/// The title's paragraphs joined by `\n` (tests.rs `title_text`).
private func titleText(_ s: Session) -> String {
    s.st.currentSlide?.shapes.first?.text.map { $0.paragraphs.map(\.text).joined(separator: "\n") } ?? ""
}

/// The title's first paragraph's runs: (text, linked) (tests.rs `title_runs`).
private func titleRuns(_ s: Session) -> [(String, Bool)] {
    (s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs ?? []).map { ($0.text, $0.props.link != nil) }
}

private func same(_ a: [(String, Bool)], _ b: [(String, Bool)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

private func idOf(_ r: JSON) -> UInt64 { r.get("id")?.asU64 ?? 0 }

// MARK: - cmd/text.rs

@Suite("Text: RTL promotion")
struct TextRTLPromoteTests {
    private func para(_ text: String) -> Paragraph { Paragraph(runs: [Run(text)]) }

    // cmd/text.rs rtl_promote_tests
    @Test func rightAlignsOnlyWhenNoAlignmentIsSetOrInherited() {
        var p = para("مرحبا")
        TextCommands.promoteRTLIfNeeded(&p, Array(repeating: false, count: 9))
        #expect(p.props.rtl == true && p.props.align == .right)
        p = para("مرحبا")
        TextCommands.promoteRTLIfNeeded(&p, Array(repeating: true, count: 9))
        #expect(p.props.rtl == true && p.props.align == nil)
        p = para("Hello مرحبا")
        TextCommands.promoteRTLIfNeeded(&p, Array(repeating: false, count: 9))
        #expect(p.props.rtl == nil && p.props.align == nil)
    }
}

@Suite("Text: IME surrounding text", .enabled(if: ported("shape.insert")))
struct TextIMESurroundingTests {
    /// Insert and enter a rectangle containing `aé😀b`.
    private func edit(_ s: Session) -> UInt64 {
        let id = idOf(s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 240, 60], "text": "aé😀b"}"#))
        s.run("text.edit", "{\"id\": \(id)}")
        return id
    }

    private func text(_ s: Session, _ id: UInt64) -> String {
        s.st.shape(ShapeId(UInt32(id)))?.text?.text ?? ""
    }

    private func select(_ s: Session, _ anchor: Int, _ caret: Int) {
        s.run("text.select", "{\"anchor\": [0, \(anchor)], \"caret\": [0, \(caret)]}")
    }

    private func surrounding(_ s: Session) throws -> ImeSurrounding {
        let st = s.st
        let t = try #require(st.selection.text)
        return try #require(TextCommands.imeSurrounding(st, t))
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func selectedTextSurvivesTheRequestedCharactersOrBytesAroundIt() throws {
        let s = session()
        let id = edit(s)
        select(s, 3, 1)
        _ = try s.deleteSurrounding(1, 1, false)
        #expect(text(s, id) == "é😀", "a and b go; the selected run stays")
        let t = try #require(s.st.selection.text)
        #expect(t.anchor == TextPoint(0, 2) && t.caret == TextPoint(0, 0), "both endpoints shift and stay reversed")
        s.run("edit.undo")
        #expect(text(s, id) == "aé😀b")
        select(s, 1, 3)
        _ = try s.deleteSurrounding(1, 1, true)
        #expect(text(s, id) == "é😀", "byte counts around the selection delete a and b too")
        s.run("edit.undo")
        #expect(text(s, id) == "aé😀b")
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func byteCountsRoundInwardToWholeCharacters() throws {
        let s = session()
        let id = edit(s)
        select(s, 2, 2)
        _ = try s.deleteSurrounding(1, 0, true)
        #expect(text(s, id) == "aé😀b", "one byte inside é is not the whole scalar")
        _ = try s.deleteSurrounding(2, 0, true)
        #expect(text(s, id) == "a😀b", "two bytes reach é's start, so the whole é goes")
        s.run("edit.undo")
        #expect(text(s, id) == "aé😀b")
        select(s, 2, 2)
        _ = try s.deleteSurrounding(0, 1, true)
        #expect(text(s, id) == "aé😀b", "one byte into the emoji is not the whole scalar")
        _ = try s.deleteSurrounding(0, 4, true)
        #expect(text(s, id) == "aéb", "four bytes contain the whole emoji")
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func surroundingTextIsCommittedLogicalAndBounded() throws {
        let s = session()
        let id = edit(s)
        var q = try surrounding(s)
        #expect(q.text == "aé😀b" && q.cursor == 8 && q.anchor == 8)
        s.run("text.select", #"{"anchor": [0, 3], "caret": [0, 1]}"#)
        q = try surrounding(s)
        #expect(q.cursor == 1 && q.anchor == 7, "reversed selection keeps caret before anchor")
        #expect(q.text == "aé😀b")
        s.run("text.set", "{\"id\": \(id), \"text\": \"ab\"}")
        s.run("text.move", #"{"to": "end"}"#)
        _ = try s.composeText("日本", nil)
        q = try surrounding(s)
        #expect(q.text == "ab" && q.cursor == 2 && q.anchor == 2, "pre-edit is not committed text")
        s.run("text.set", "{\"id\": \(id), \"text\": \"\"}")
        q = try surrounding(s)
        #expect(q.text == "" && q.cursor == 0 && q.anchor == 0, "empty body is available")
        let long = String(repeating: "a", count: TextCommands.imeSurroundingMaxBytes + 1500)
        s.run("text.set", JSON.object(JSONObject(["id": .integer(Int(id)), "text": .string(long)])).display)
        s.run("text.move", #"{"to": "end"}"#)
        q = try surrounding(s)
        #expect(q.text.utf8.count <= TextCommands.imeSurroundingMaxBytes, "\(q.text.utf8.count)")
        #expect(q.cursor == q.text.utf8.count, "caret stays at the end of the bounded window")
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func paragraphMarksAreDeletableLogicalText() throws {
        let s = session()
        let id = edit(s)
        s.run("text.set", "{\"id\": \(id), \"text\": \"ab\\ncd\"}")
        s.run("text.select", #"{"anchor": [1, 0], "caret": [1, 0]}"#)
        let q = try surrounding(s)
        #expect(q.text == "ab\ncd" && q.cursor == 3 && q.anchor == 3)
        _ = try s.deleteSurrounding(1, 0, true)
        #expect(text(s, id) == "abcd", "the mark goes and the paragraphs merge")
        #expect(s.st.selection.text?.caret == TextPoint(0, 2), "the caret stays where the merged text continues")
        s.run("edit.undo")
        #expect(text(s, id) == "ab\ncd")
        s.run("text.select", #"{"anchor": [1, 0], "caret": [1, 0]}"#)
        _ = try s.deleteSurrounding(1, 0, false)
        #expect(text(s, id) == "abcd")
        s.run("edit.undo")
        s.run("text.select", #"{"anchor": [0, 2], "caret": [0, 2]}"#)
        _ = try s.deleteSurrounding(0, 1, false)
        #expect(text(s, id) == "abcd")
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func softLineBreaksReadAsNewlines() throws {
        let s = session()
        let id = edit(s)
        s.run("text.autocorrect", #"{"on": false}"#)
        s.run("text.set", "{\"id\": \(id), \"text\": \"ab\"}")
        s.run("text.select", #"{"anchor": [0, 1], "caret": [0, 1]}"#)
        s.run("text.insert", #"{"text": "\u000b"}"#)
        #expect(text(s, id) == "a\u{0B}b", "a line break inside one paragraph")
        let q = try surrounding(s)
        #expect(q.text == "a\nb" && q.cursor == 2 && q.anchor == 2)
        _ = try s.deleteSurrounding(1, 0, true)
        #expect(text(s, id) == "ab")
        s.run("edit.undo")
        #expect(text(s, id) == "a\u{0B}b")
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func outOfRangeCountsClampInsteadOfTruncating() throws {
        let s = session()
        let id = edit(s)
        select(s, 1, 1)
        _ = try s.deleteSurrounding(Int.max, 0, false)
        #expect(text(s, id) == "é😀b", "everything before the caret goes, no trap")
        #expect(TextCommands.countParam(j(#"{"before": 4294967296}"#), "before") == 4_294_967_296)
        #expect(TextCommands.countParam(j(#"{"before": 18446744073709551615}"#), "before") == Int.max, "clamped, not wrapped")
        #expect(TextCommands.countParam(j("{}"), "before") == 0)
    }

    // cmd/text.rs ime_surrounding_tests
    @Test func aNonComposingImeDeletionIsOneUndoStep() throws {
        let s = session()
        let id = edit(s)
        let undo = s.st.history.undo.count
        select(s, 3, 3)
        _ = try s.deleteSurrounding(1, 0, false)
        #expect(text(s, id) == "aéb")
        #expect(s.st.history.undo.count == undo + 1, "one history entry, not two")
        s.run("edit.undo")
        #expect(text(s, id) == "aé😀b")
    }
}

@Suite("Text: Replace Fonts")
struct TextReplaceFontTests {
    private func fonts(_ s: Session) -> [String] { (s.run("font.used").asArray ?? []).compactMap(\.asStr) }

    // cmd/text.rs replace_font_tests
    @Test(.enabled(if: ported("insert.textBox"))) func replacesRunsTablesNotesAndThemeAndUndoes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "T", "body": "B"}"#)
        let theme = try #require(s.st.doc.masters.first?.theme.fonts.minor.latin)
        s.run("insert.textBox", #"{"rect": [10, 10, 200, 50], "text": "Hello"}"#)
        s.run("text.exit")
        s.run("format.font", #"{"family": "Comic Neue"}"#)
        #expect(fonts(s).contains("Comic Neue"), "\(fonts(s))")
        let r = s.run("font.replace", #"{"from": "comic neue", "to": "Lato"}"#)
        #expect((r.get("replaced")?.asU64 ?? 0) >= 1, "\(r.display)")
        let used = fonts(s)
        #expect(!used.contains("Comic Neue") && used.contains("Lato"), "\(used)")
        // The theme's body font is replaced too, so placeholders follow.
        s.run("font.replace", JSON.object(JSONObject(["from": .string(theme), "to": "Lato"])).display)
        #expect(s.st.doc.masters.first?.theme.fonts.minor.latin == "Lato")
        #expect(s.st.doc.validate().isEmpty)
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(fonts(s).contains("Comic Neue"))
    }

    // cmd/text.rs replace_font_tests
    @Test func nothingToReplaceIsNoUndoStepAndBadNamesFail() {
        let s = session()
        let undo = s.st.history.undo.count
        #expect(s.run("font.replace", #"{"from": "Nope Sans", "to": "Inter"}"#).get("replaced") == 0)
        #expect(s.run("font.replace", #"{"from": "+mn-lt", "to": "Inter"}"#).get("replaced") == 0)
        #expect(s.st.history.undo.count == undo)
        #expect(s.fails("font.replace", #"{"from": "", "to": "Inter"}"#))
        #expect(s.fails("font.replace", #"{"from": "Inter", "to": "a\nb"}"#))
        #expect(s.fails("font.replace", #"{"from": "Inter"}"#))
    }
}

@Suite("Text: Select Paragraph", .enabled(if: ported("insert.textBox")))
struct TextSelectParagraphTests {
    // cmd/text.rs select_paragraph_tests
    @Test func selectParagraphHugeAt() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "T", "body": "B"}"#)
        s.run("insert.textBox", #"{"rect": [10, 10, 200, 50], "text": "hello"}"#)
        s.run("text.edit")
        #expect(!s.fails("text.selectParagraph", #"{"at": [18446744073709551615, 0]}"#))
        let t = try #require(s.st.selection.text)
        // Clamped to the last (only) paragraph, never past the end of the body.
        #expect(t.anchor == TextPoint(0, 0) && t.caret == TextPoint(0, 5))
    }
}

// MARK: - tests.rs

@Suite("Text editing")
struct TextEditingTests {
    // tests.rs text_editing_flow
    @Test func textEditingFlow() {
        let s = session()
        let title = titleId(s)
        s.run("text.edit", "{\"id\": \(title)}")
        s.run("text.insert", #"{"text": "Hello world"}"#)
        s.run("text.move", #"{"to": "wordLeft", "extend": true}"#)
        s.run("format.italic")
        s.run("text.move", #"{"to": "end"}"#)
        s.run("text.delete", #"{"dir": "backward"}"#)
        s.run("text.insert", #"{"text": "D\nSecond"}"#)
        #expect(s.run("text.get", "{\"id\": \(title)}").get("text") == "Hello worlD\nSecond")
        s.run("text.exit")
        #expect(s.st.selection.text == nil)
        #expect(s.st.selection.shapes.count == 1)
    }

    // tests.rs text_set_crlf_makes_clean_paragraphs
    @Test(.enabled(if: ported("insert.textBox"))) func textSetCrlfMakesCleanParagraphs() {
        let s = session()
        let id = idOf(s.run("insert.textBox", #"{"text": "x"}"#))
        s.run("text.set", "{\"id\": \(id), \"text\": \"one\\r\\ntwo\"}")
        let t = s.run("text.get", "{\"id\": \(id)}")
        #expect(t.get("paragraphs")?.at(0)?.get("text") == "one")
        #expect(t.get("paragraphs")?.at(1)?.get("text") == "two")
        #expect(t.get("text") == "one\ntwo")
        // A lone CR (old Mac line ends) is a paragraph break too.
        s.run("text.set", "{\"id\": \(id), \"text\": \"a\\rb\"}")
        #expect(s.run("text.get", "{\"id\": \(id)}").get("text") == "a\nb")
    }

    // tests.rs editing_text_refits_a_saved_shrink
    @Test func editingTextRefitsASavedShrink() throws {
        let s = session()
        let title = ShapeId(titleId(s))
        s.run("text.edit", "{\"id\": \(title.rawValue)}")
        s.run("text.insert", #"{"text": "Hi"}"#)
        // As if opened from a file PowerPoint saved shrunk.
        try s.edit { doc, sel in
            mutateShapes(&doc, sel) { shapes in
                withShape(&shapes, title) { $0.text?.body.autofit = .shrink(fontScale: 0.5, lineReduction: 0.2) }
            }
        }
        s.run("text.insert", #"{"text": "!"}"#)
        let sh = try #require(s.st.shape(title))
        #expect(sh.text?.body.autofit == .shrink(fontScale: 1.0, lineReduction: 0.0))
    }

    // tests.rs editing_shrink_text_stores_the_layout_scale (the saved PPTX's `fontScale` is checked
    // through DCPPTX's export, as deckcraft checks its own)
    @Test(.enabled(if: ported("shape.insert"))) func editingShrinkTextStoresTheLayoutScale() throws {
        let s = session()
        let id = ShapeId(UInt32(idOf(s.run("shape.insert", #"{"preset": "rect", "rect": [80.0, 80.0, 200.0, 40.0]}"#))))
        s.run("format.autofit", #"{"mode": "shrink"}"#)
        let text = (0 ..< 12).map { "Line \($0)" }.joined(separator: "\n")
        s.run("text.set", JSON.object(JSONObject(["id": .integer(Int(id.rawValue)), "text": .string(text)])).display)
        func scale() -> Double?? {
            guard case .shrink(let fs, _)? = s.st.shape(id)?.text?.body.autofit else { return .none }
            return .some(fs)
        }
        let stored = try #require(scale())
        #expect(stored.map { $0 < 1.0 } == true, "the computed fit is stored: \(String(describing: stored))")
        s.run("edit.undo")
        let undone = try #require(scale())
        #expect(undone == 1.0, "undo restores the scale the edit started from")
        s.run("edit.redo")
        let redone = try #require(scale())
        #expect(redone.map { $0 < 1.0 } == true, "redo brings the stored fit back")
    }

    // tests.rs smart_quotes_and_autocorrect
    @Test func smartQuotesAndAutocorrect() {
        let s = session()
        let title = titleId(s)
        s.run("text.edit", "{\"id\": \(title)}")
        for c in ["\"", "h", "i", "\"", " ", "t", "e", "h", " "] {
            s.run("text.insert", JSON.object(JSONObject(["text": .string(c)])).display)
        }
        #expect(s.run("text.get", "{\"id\": \(title)}").get("text") == "“hi” the ")
    }

    // tests.rs right_to_left_paragraphs
    @Test func rightToLeftParagraphs() {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        // Explicitly left-to-right first, so typing Arabic doesn't already turn it right-to-left (#169).
        s.run("format.rtl", #"{"on": false}"#)
        s.run("text.insert", #"{"text": "سنة 2024 (Retrait) فقط"}"#)
        s.run("format.rtl")
        func para() -> ParaProps { s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.props ?? ParaProps() }
        #expect(para().rtl == true)
        // Left (the default) becomes right: the text stays at its start edge.
        #expect(para().align == .right)
        s.run("format.align", #"{"align": "justifyLow"}"#)
        #expect(para().align == .justLow)
        // Toggling back keeps a justified alignment.
        s.run("format.rtl")
        #expect(para().rtl == false)
        #expect(para().align == .justLow)
        s.run("format.rtl", #"{"on": true}"#)
        s.run("format.alignLeft")
        s.run("format.rtl", #"{"on": false}"#)
        #expect(para().align == .right)
        s.run("edit.undo")
        #expect(para().rtl == true)
    }

    // tests.rs typing_kurdish_or_arabic_auto_detects_rtl_and_advances_caret_smoothly
    @Test func typingKurdishOrArabicAutoDetectsRtlAndAdvancesCaretSmoothly() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        var firstX: Double?
        var lastX = 0.0
        for ch in ["م", "ن", " ", "ن", "ا", "و", "م", " ", "ه", "ێ", "ڤ", "ا", "ر", "ه"] {
            s.run("text.insert", JSON.object(JSONObject(["text": .string(ch)])).display)
            let st = s.st
            let t = try #require(st.selection.text)
            let l = try #require(TextCommands.layoutFor(st, t))
            let cx = try #require(l.caret(CaretPos(para: t.caret.para, ch: t.caret.char))).x
            if firstX == nil { firstX = cx }
            lastX = cx
            // The title is centred: the caret must not jump back to the left margin.
            #expect(cx > 100.0, "caret should not jump to left margin: \(cx)")
        }
        #expect(lastX < (firstX ?? 0), "caret should advance leftwards: last=\(lastX) first=\(String(describing: firstX))")
        let para = s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.props
        #expect(para?.rtl == true, "auto-detected as RTL")
        #expect(para?.align == nil, "the title keeps the alignment it inherits")
        // A text box inherits the deck's default (left) alignment, which it keeps too.
        guard ported("insert.textBox") else { return }
        _ = try? s.execute("text.exit", .emptyObject)
        let id = idOf(s.run("insert.textBox", #"{"rect": [10, 10, 300, 100], "text": ""}"#))
        s.run("text.edit", "{\"id\": \(id)}")
        s.run("text.insert", #"{"text": "مرحبا"}"#)
        let p2 = s.st.shape(ShapeId(UInt32(id)))?.text?.paragraphs.first?.props
        #expect(p2?.rtl == true)
        #expect(p2?.align == nil, "the text box keeps the alignment it inherits")
    }

    // tests.rs explicit_ltr_override_is_preserved_when_typing_rtl
    @Test func explicitLtrOverrideIsPreservedWhenTypingRtl() {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("format.rtl", #"{"on": false}"#)
        s.run("text.insert", #"{"text": "مرحبا"}"#)
        #expect(s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.props.rtl == false, "user explicit LTR is preserved")
    }

    // tests.rs the_caret_takes_the_colour_of_the_text
    @Test(.enabled(if: ported("design.theme"))) func theCaretTakesTheColourOfTheText() throws {
        func caret(_ theme: String) throws -> Rgba {
            let s = session()
            s.run("design.theme", JSON.object(JSONObject(["name": .string(theme)])).display)
            s.run("text.edit", "{\"id\": \(titleId(s))}")
            let t0 = try #require(s.st.selection.text)
            let empty = try #require(TextCommands.caretColor(s.st, t0))
            s.run("text.insert", #"{"text": "Typed"}"#)
            let t1 = try #require(s.st.selection.text)
            #expect(TextCommands.caretColor(s.st, t1) == empty)
            return empty
        }
        // Dark text on the light theme, light text on the dark one.
        let (light, dark) = (try caret("DeckCraft"), try caret("Nocturne"))
        #expect(light.r < 0x60 && light.g < 0x60 && light.b < 0x60, "\(light)")
        #expect(dark.r > 0xC0 && dark.g > 0xC0 && dark.b > 0xC0, "\(dark)")
        // Text set to red gets a red caret.
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "Red"}"#)
        s.run("text.selectAll")
        s.run("format.color", ##"{"color": "#FF0000"}"##)
        s.run("text.move", #"{"to": "end"}"#)
        let t2 = try #require(s.st.selection.text)
        let red = try #require(TextCommands.caretColor(s.st, t2))
        #expect(red.r == 0xFF && red.g == 0 && red.b == 0)
    }

    // tests.rs paragraph_commands_clamp_a_hostile_text_selection
    @Test func paragraphCommandsClampAHostileTextSelection() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.select", #"{"anchor": [0, 0], "caret": [18446744073709551615, 0]}"#)
        s.run("text.selectParagraph", #"{"at": [18446744073709551615, 0]}"#)
        s.run("format.alignCenter")
        s.run("format.case", #"{"mode": "upper"}"#)
        s.run("text.insert", #"{"text": "A"}"#)
        let t = try #require(s.st.selection.text)
        #expect(t.caret.para < 1000, "the caret stayed inside the body: \(t)")
    }

    // tests.rs paragraph_commands_clamp_a_direct_hostile_text_selection
    @Test func paragraphCommandsClampADirectHostileTextSelection() throws {
        let s = session()
        let title = titleId(s)
        s.run("text.edit", "{\"id\": \(title)}")
        s.run("text.select", #"{"anchor": [0, 0], "caret": [18446744073709551615, 0]}"#)
        s.run("format.alignCenter")
        s.run("format.case", #"{"mode": "upper"}"#)
        let body = try #require(s.st.shape(ShapeId(title))?.text)
        #expect(body.paragraphs.first?.props.align == .center)
    }
}

@Suite("Text: AutoCorrect and AutoFormat")
struct TextAutoCorrectTests {
    /// Clear the title and type `text` one character at a time; the title's text.
    private func typed(_ s: Session, _ title: UInt32, _ text: String) -> String {
        s.run("text.edit", "{\"id\": \(title)}")
        _ = try? s.execute("text.selectAll", .emptyObject)
        _ = try? s.execute("text.delete", ["dir": "backward"])
        for c in text.unicodeScalars { s.run("text.insert", JSON.object(JSONObject(["text": .string(String(c))])).display) }
        return s.run("text.get", "{\"id\": \(title)}").get("text")?.asStr ?? ""
    }

    // tests.rs autocorrect_options_as_you_type
    @Test func autocorrectOptionsAsYouType() throws {
        let s = session()
        let title = titleId(s)
        #expect(typed(s, title, "hello world. see you monday, i think. ") == "Hello world. See you Monday, I think. ")
        #expect(typed(s, title, "THe tHIS 1/2 recieved... ") == "The This ½ received… ")
        // `text.insert` reports the caret after the correction.
        #expect(typed(s, title, "(c)") == "(c)")
        #expect(s.run("text.insert", #"{"text": " "}"#).get("caret") == [0, 2])
        #expect(s.run("text.get", "{\"id\": \(title)}").get("text") == "© ")
        // Options turn rules off.
        s.run("text.autocorrect", #"{"sentenceCaps": false, "days": false}"#)
        #expect(typed(s, title, "hello monday ") == "hello monday ")
        // Your own entries, and deleting a built-in one.
        s.run("text.autocorrect", #"{"add": ["dc", "DeckCraft"], "remove": "teh"}"#)
        #expect(typed(s, title, "dc teh ") == "DeckCraft teh ")
        let entries = try #require(s.run("text.autocorrect").get("entries")?.asArray)
        #expect(entries.contains { $0.at(0) == "dc" })
        #expect(!entries.contains { $0.at(0) == "teh" })
        #expect(s.fails("text.autocorrect", #"{"add": ["two words", "x"]}"#))
        // Off entirely.
        s.run("text.autocorrect", #"{"on": false}"#)
        #expect(typed(s, title, "dc adn ") == "dc adn ")
        // Pasting a whole string applies only the replacement list, not the case rules.
        s.run("text.autocorrect", #"{"on": true, "sentenceCaps": true}"#)
        s.run("text.edit", "{\"id\": \(title)}")
        _ = try? s.execute("text.selectAll", .emptyObject)
        s.run("text.insert", #"{"text": "monday notes "}"#)
        #expect(s.run("text.get", "{\"id\": \(title)}").get("text") == "monday notes ")
    }

    // tests.rs autocorrect_superscripts_ordinals_as_you_type
    @Test func autocorrectSuperscriptsOrdinalsAsYouType() {
        let s = session()
        let title = titleId(s)
        // The typed text with each superscript run in ^(…).
        func sup(_ text: String) -> String {
            _ = typed(s, title, text)
            let runs = s.st.currentSlide?.shapes.first { $0.id.rawValue == title }?.text?.paragraphs.first?.runs ?? []
            return runs.map { ($0.props.baseline ?? 0) > 0 ? "^(\($0.text))" : $0.text }.joined()
        }
        #expect(sup("1st, 22nd and 103rd. 4th 11th x") == "1^(st), 22^(nd) and 103^(rd). 4^(th) 11^(th) x")
        // Not a word, a number without a suffix it takes, or a suffix not yet followed by a space.
        #expect(sup("first x1st 1th 2st 21st") == "First x1st 1th 2st 21st")
        #expect(s.run("text.autocorrect").get("ordinals") == true)
        s.run("text.autocorrect", #"{"ordinals": false}"#)
        #expect(sup("2nd ") == "2nd ")
        // AutoCorrect off turns it off too.
        s.run("text.autocorrect", #"{"ordinals": true, "on": false}"#)
        #expect(sup("2nd ") == "2nd ")
    }

    // tests.rs autoformat_starts_bulleted_and_numbered_lists_as_you_type
    @Test func autoformatStartsBulletedAndNumberedListsAsYouType() {
        let s = session()
        let title = titleId(s)
        func para() -> (String, Bullet?) {
            let p = s.st.currentSlide?.shapes.first { $0.id.rawValue == title }?.text?.paragraphs.first ?? Paragraph()
            return (p.text, p.props.bullet)
        }
        // Clear the title (and its paragraph formatting) and type `text` one character at a time.
        func list(_ text: String) -> (String, Bullet?) {
            s.run("text.edit", "{\"id\": \(title)}")
            _ = try? s.execute("text.selectAll", .emptyObject)
            _ = try? s.execute("text.delete", ["dir": "backward"])
            s.run("format.bullets", #"{"on": false}"#)
            for c in text.unicodeScalars { s.run("text.insert", JSON.object(JSONObject(["text": .string(String(c))])).display) }
            return para()
        }
        func ch(_ c: String) -> Bullet? { .char(char: c) }
        func num(_ scheme: String) -> Bullet? { .autoNum(scheme: scheme, startAt: 1) }
        for (text, bullet) in [
            ("* x", ch("•")), ("- x", ch("–")), ("– x", ch("–")), ("-- x", ch("■")), ("— x", ch("■")), ("> x", ch("➢")),
            ("<> x", ch("◆")), ("*\tx", ch("•")), ("1. x", num("arabicPeriod")), ("1) x", num("arabicParenR")),
            ("I. x", num("romanUcPeriod")), ("i. x", num("romanLcPeriod")), ("A. x", num("alphaUcPeriod")),
            ("a. x", num("alphaLcPeriod")), ("a) x", num("alphaLcParenR")),
        ] {
            let got = list(text)
            #expect(got.0 == "x" && got.1 == bullet, "\(text)")
        }
        // Only a lead at the start of the paragraph, and only before a space or tab.
        let none: Bullet? = Bullet.none_
        for text in ["9 * x", "*, x", "2. x", "b) x"] {
            let got = list(text)
            #expect(got.0 == text && got.1 == none, "\(text)")
        }
        // The space that starts the list reports the caret at the start of the emptied paragraph.
        #expect(list("*") == ("*", none))
        #expect(s.run("text.insert", #"{"text": " "}"#).get("caret") == [0, 0])
        #expect(para() == ("", ch("•")))
        // Backspace right after puts the lead and the space back, with the paragraph as it was.
        s.run("text.delete", #"{"dir": "backward"}"#)
        #expect(para() == ("* ", none))
        s.run("text.insert", #"{"text": "x"}"#)
        #expect(para() == ("* x", none))
        // After anything else Backspace deletes as usual.
        #expect(list("1. xy") == ("xy", num("arabicPeriod")))
        s.run("text.delete", #"{"dir": "backward"}"#)
        #expect(para() == ("x", num("arabicPeriod")))
        // The AutoCorrect option turns it off.
        #expect(s.run("text.autocorrect").get("lists") == true)
        s.run("text.autocorrect", #"{"lists": false}"#)
        #expect(list("* x") == ("* x", none))
    }
}

@Suite("Text: input method")
struct TextIMETests {
    // tests.rs ime_composition_replaces_its_preedit_and_commits_as_one_undo_step
    @Test func imeCompositionReplacesItsPreeditAndCommitsAsOneUndoStep() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "A "}"#)
        let undo0 = s.st.history.undo.count
        for pre in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"] {
            _ = try s.composeText(pre, nil)
            #expect(titleText(s) == "A \(pre)", "the preedit is shown in place")
            let c = try #require(s.st.composition)
            #expect(c.start == TextPoint(0, 2) && c.len == pre.unicodeScalars.count)
            #expect(s.st.selection.text?.caret == TextPoint(0, 2 + pre.unicodeScalars.count), "caret after the preedit")
            #expect(s.st.history.undo.count == undo0, "no undo step while composing")
        }
        _ = try s.commitText("한글")
        #expect(titleText(s) == "A 한글")
        #expect(s.st.composition == nil)
        #expect(s.st.history.undo.count == undo0 + 1, "one undo step for the composition")
        #expect(s.st.history.undo.last?.label == "Type Text")
        s.run("edit.undo")
        #expect(titleText(s) == "A ")
        s.run("edit.redo")
        #expect(titleText(s) == "A 한글")
        // Windows' Korean IME commits a syllable when the next begins: an empty preedit, the commit, then a
        // new preedit.
        _ = try s.composeText("ㄴ", nil)
        _ = try s.composeText("", nil)
        _ = try s.commitText("ㄴ")
        _ = try s.composeText("ㅁ", nil)
        #expect(titleText(s) == "A 한글ㄴㅁ")
        _ = try s.commitText("마")
        #expect(titleText(s) == "A 한글ㄴ마")
        s.run("edit.undo")
        #expect(titleText(s) == "A 한글ㄴ")
    }

    // tests.rs ime_cancel_restores_the_text_and_selection
    @Test func imeCancelRestoresTheTextAndSelection() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "Hello world"}"#)
        s.run("text.select", #"{"anchor": [0, 6], "caret": [0, 11]}"#)
        let undo0 = s.st.history.undo.count
        let rev = s.st.revision
        _ = try s.composeText("せかい", (0, 3))
        #expect(titleText(s) == "Hello せかい", "the preedit replaces the selection")
        #expect(s.st.composition?.active.map { $0 == (0, 3) } == true)
        _ = try s.composeText("世界", (0, 9))
        #expect(s.st.composition?.active.map { $0 == (0, 2) } == true, "clamped to the preedit")
        _ = try s.composeText("", nil)
        #expect(titleText(s) == "Hello world")
        let t = try #require(s.st.selection.text)
        #expect(t.anchor == TextPoint(0, 6) && t.caret == TextPoint(0, 11), "the selection is back")
        #expect(s.st.history.undo.count == undo0)
        #expect(s.st.revision > rev, "redrawn")
        // A commit of nothing without a composition is nothing.
        _ = try s.commitText("")
        #expect(s.st.history.undo.count == undo0)
        // A commit without a preedit (some input methods send only the result) is one step.
        _ = try s.commitText("世界")
        #expect(titleText(s) == "Hello 世界")
        #expect(s.st.history.undo.count == undo0 + 1)
    }

    // tests.rs ime_composition_is_kept_by_a_key_a_click_or_another_command
    @Test func imeCompositionIsKeptByAKeyAClickOrAnotherCommand() throws {
        let s = session()
        let title = titleId(s)
        s.run("text.edit", "{\"id\": \(title)}")
        let undo0 = s.st.history.undo.count
        _ = try s.composeText("안", nil)
        _ = try s.key("Right", Mods())
        #expect(s.st.composition == nil)
        #expect(titleText(s) == "안")
        #expect(s.st.history.undo.count == undo0 + 1)
        _ = try s.composeText("녕", nil)
        s.ptr(.move, 5, 5, tol: 4)
        #expect(s.st.composition != nil, "hovering keeps composing")
        s.ptr(.down, 5, 5, tol: 4)
        #expect(s.st.composition == nil, "a click settles it")
        #expect(titleText(s) == "안녕")
        s.run("text.edit", "{\"id\": \(title)}")
        _ = try s.composeText("하", nil)
        s.run("text.get", "{\"id\": \(title)}")
        #expect(s.st.composition != nil, "a query doesn't")
        s.run("text.insert", #"{"text": "!"}"#)
        #expect(titleText(s) == "안녕하!")
        s.run("edit.undo")
        #expect(titleText(s) == "안녕하")
        s.run("edit.undo")
        #expect(titleText(s) == "안녕")
        // Text changed under the composition (here behind its back): a new one starts, no trap.
        _ = try s.composeText("ㄱ", nil)
        s.st.composition?.len = 99
        _ = try s.composeText("가", nil)
        #expect(titleText(s).hasSuffix("가"))
        // Control characters (an Enter sent as text) never split the paragraph.
        _ = try s.commitText("가\n\r\u{0B}")
        #expect(s.st.currentSlide?.shapes.first?.text?.paragraphs.count == 1)
    }

    // tests.rs ime_on_a_selected_shape_replaces_its_text
    @Test(.enabled(if: ported("shape.insert"))) func imeOnASelectedShapeReplacesItsText() throws {
        let s = session()
        let id = idOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100], "text": "Old"}"#))
        try s.select { _, sel in
            sel.text = nil
            sel.shapes = [ShapeId(UInt32(id))]
        }
        #expect(try s.composeText("", nil).get("handled") == false, "an empty preedit doesn't start editing")
        _ = try s.composeText("新", nil)
        _ = try s.commitText("新しい")
        #expect(s.run("text.get", "{\"id\": \(id)}").get("text") == "新しい")
        try s.select { _, sel in
            sel.text = nil
            sel.shapes.removeAll()
        }
        #expect(try s.composeText("x", nil).get("handled") == false)
        #expect(try s.commitText("x").get("handled") == false)
    }

    // tests.rs ime_composition_underlines_follow_the_text
    @Test func imeCompositionUnderlinesFollowTheText() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        #expect(TextCommands.compositionUnderlines(s.st).isEmpty)
        _ = try s.composeText("にほんご", (2, 4))
        let u = TextCommands.compositionUnderlines(s.st)
        let thin = u.filter { !$0.2 }
        let thick = u.filter(\.2)
        #expect(thin.count == 1 && thick.count == 1, "\(u)")
        let sh = try #require(s.st.currentSlide?.shapes.first)
        let x = Cmd.xfrmOf(s.st.doc, s.st.selection, sh)
        for (a, b, _) in u {
            #expect(b.x > a.x && abs(a.y - b.y) < 1e-9, "a horizontal line: \(a) \(b)")
            #expect(a.x >= x.x - 1.0 && b.x <= x.x + x.w + 1.0 && a.y > x.y && a.y < x.y + x.h, "inside the title box")
        }
        let tk = try #require(thick.first)
        let tn = try #require(thin.first)
        #expect(tk.0.x > tn.0.x && abs(tk.1.x - tn.1.x) < 1e-6, "the converted part is the end")
        _ = try s.commitText("日本語")
        #expect(TextCommands.compositionUnderlines(s.st).isEmpty)
    }

    // tests.rs ime_composition_in_a_table_cell_is_underlined
    @Test(.enabled(if: ported("insert.table"))) func imeCompositionInATableCellIsUnderlined() throws {
        let s = session()
        let id = idOf(s.run("insert.table", #"{"rows": 2, "cols": 2, "rect": [80.0, 90.0, 400.0, 120.0]}"#))
        s.run("text.edit", "{\"id\": \(id), \"cell\": [0, 0]}")
        #expect(TextCommands.compositionUnderlines(s.st).isEmpty)
        let t0 = try #require(s.st.selection.text)
        #expect(TextCommands.caretLine(s.st, t0) != nil, "the caret is in the cell")
        _ = try s.composeText("にほんご", (2, 4))
        let u = TextCommands.compositionUnderlines(s.st)
        let thin = u.filter { !$0.2 }
        let thick = u.filter(\.2)
        #expect(thin.count == 1 && thick.count == 1, "\(u)")
        let sh = try #require(s.st.shape(ShapeId(UInt32(id))))
        let x = Cmd.xfrmOf(s.st.doc, s.st.selection, sh)
        guard case .table(let tb) = sh.kind else { Issue.record("not a table"); return }
        let col = try #require(tb.cols.first)
        let row = try #require(Cmd.tableDrawnHeights(s.st.doc, s.st.selection, tb).first)
        for (a, b, _) in u {
            #expect(b.x > a.x && abs(a.y - b.y) < 1e-6, "a horizontal line: \(a) \(b)")
            #expect(a.x >= x.x - 1.0 && b.x <= x.x + col + 1.0, "inside the first column")
            #expect(a.y > x.y && a.y < x.y + row + 1.0, "inside the first row")
        }
        let tk = try #require(thick.first)
        let tn = try #require(thin.first)
        #expect(tk.0.x > tn.0.x && abs(tk.1.x - tn.1.x) < 1e-6, "the converted part is the end")
        let t1 = try #require(s.st.selection.text)
        let (top, bot) = try #require(TextCommands.caretLine(s.st, t1))
        #expect(top.x >= x.x && top.x <= x.x + col && top.y >= x.y && bot.y <= x.y + row + 1.0, "caret in the cell")
        _ = try s.commitText("日本語")
        #expect(TextCommands.compositionUnderlines(s.st).isEmpty)
        guard case .table(let t2)? = s.st.shape(ShapeId(UInt32(id)))?.kind else { Issue.record("not a table"); return }
        #expect(t2.cell(0, 0)?.text.text == "日本語")
    }
}

@Suite("Text: hyperlinks", .enabled(if: ported("insert.hyperlink")))
struct TextHyperlinkTests {
    // tests.rs hyperlink_with_a_bare_caret_inserts_the_address
    @Test func hyperlinkWithABareCaretInsertsTheAddress() {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "See "}"#)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        s.run("text.insert", #"{"text": " now"}"#)
        #expect(
            same(titleRuns(s), [("See ", false), ("https://example.org", true), (" now", false)]),
            "the address is inserted as a link, and typing after it doesn't extend it: \(titleRuns(s))"
        )
    }

    // tests.rs hyperlink_display_text_and_targets
    @Test func hyperlinkDisplayTextAndTargets() {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("insert.hyperlink", #"{"url": "mailto:a@b.org"}"#)
        #expect(same(titleRuns(s), [("a@b.org", true)]), "email links show the address without mailto:")
        s.run("text.insert", #"{"text": " "}"#)
        s.run("insert.hyperlink", #"{"slide": 0, "text": "start"}"#)
        #expect(same(titleRuns(s), [("a@b.org", true), (" ", false), ("start", true)]))
    }

    // tests.rs hyperlink_on_a_word_or_shape_links_it
    @Test func hyperlinkOnAWordOrShapeLinksIt() {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "Hello world"}"#)
        s.run("text.move", #"{"to": "left"}"#)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        #expect(same(titleRuns(s), [("Hello ", false), ("world", true)]), "a caret inside a word links the word")
        s.run("text.exit")
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        #expect(s.st.currentSlide?.shapes.first?.click != nil, "a selected shape gets the link as its click action")
    }

    // tests.rs hyperlink_can_keep_highlight_click
    @Test func hyperlinkCanKeepHighlightClick() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.exit")
        s.run("insert.hyperlink", #"{"url": "https://example.org", "tooltip": "tip", "highlightClick": true}"#)
        var click = try #require(s.st.currentSlide?.shapes.first?.click)
        #expect(click.tooltip == "tip")
        #expect(click.highlightClick)
        #expect(click.action == .url(url: "https://example.org"))
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        click = try #require(s.st.currentSlide?.shapes.first?.click)
        #expect(!click.highlightClick, "omitting the flag still stores false")
    }

    // tests.rs inserted_hyperlinks_look_like_links
    @Test func insertedHyperlinksLookLikeLinks() throws {
        let s = session()
        s.run("text.edit", "{\"id\": \(titleId(s))}")
        s.run("text.insert", #"{"text": "Read the docs"}"#)
        s.run("text.move", #"{"to": "wordLeft", "extend": true}"#)
        #expect(s.run("format.state").get("underline") == false)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        // Underlined (and hlink-coloured) without touching the run's own props.
        #expect(s.run("format.state").get("underline") == true)
        let body = try #require(s.st.currentSlide?.shapes.first?.text)
        let run = try #require(body.paragraphs.first?.runs.first { $0.props.link != nil })
        #expect(run.props.fill == nil && run.props.underline == nil, "\(run)")
        // Underline off is the run's own u="none", as in PowerPoint.
        s.run("format.underline")
        #expect(s.run("format.state").get("underline") == false)
    }
}

@Suite("Fonts")
struct TextFontTests {
    // tests.rs font_add_refuses_non_fonts_and_rescan_reports_the_catalog
    @Test func fontAddRefusesNonFontsAndRescanReportsTheCatalog() {
        let s = session()
        let notFont = Cmd.base64Encode(Array("definitely not a font file".utf8))
        #expect(s.fails("font.add", JSON.object(JSONObject(["data": .string(notFont)])).display))
        #expect(s.fails("font.add"))
        let r = s.run("font.rescan")
        #expect((r.get("families")?.asU64 ?? 0) >= 1, "\(r.display)")
    }
}

/// tests_keys.rs's test that needs the edited text's layout (`text::layout_for`), which the core left to
/// the text group.
@Suite("Text keys: lines", .enabled(if: ported("insert.textBox")))
struct TextKeysLayoutTests {
    // tests_keys.rs
    @Test func homeEndAndCtrlHomeEnd() throws {
        let t = "First paragraph that is long enough to wrap across several lines in this narrow box.\nSecond"
        let s = Session.withNew()
        s.macKeys = false
        s.prefs.autocorrect = false
        s.prefs.smartQuotes = false
        s.run("insert.textBox", #"{"rect": [60, 60, 160, 300], "text": "x"}"#)
        let id = s.st.selection.shapes.first?.rawValue ?? 0
        s.run("text.set", JSON.object(JSONObject(["id": .integer(id), "text": .string(t)])).display)
        s.run("text.edit", "{\"id\": \(id), \"at\": [0, 0]}")
        func sel() -> ((Int, Int), (Int, Int)) {
            let t = s.st.selection.text ?? TextSel()
            return ((t.anchor.para, t.anchor.char), (t.caret.para, t.caret.char))
        }
        func caret() -> (Int, Int) { sel().1 }
        func isSel(_ a: (Int, Int), _ c: (Int, Int)) -> Bool { sel().0 == a && sel().1 == c }
        func press(_ key: String, _ mods: Mods, sourceLocation: SourceLocation = #_sourceLocation) {
            let r = (try? s.key(key, mods)) ?? .null
            #expect(r.get("handled") == true, "\(key) \(mods) not handled", sourceLocation: sourceLocation)
        }
        let ts = try #require(s.st.selection.text)
        let layout = try #require(TextCommands.layoutFor(s.st, ts))
        let lines = layout.lines.filter { $0.para == 0 }.map { ($0.start, $0.end) }
        try #require(lines.count >= 3, "\(lines)")
        let (l1, l2) = (lines[1], lines[2])
        // End goes past a wrapped line's trailing space, to where the next line starts, as in PowerPoint,
        // and the caret stays drawn on the line it ended.
        let next = lines[2].0
        s.run("text.edit", "{\"at\": [0, \(l1.0 + 2)]}")
        press("Home", Mods())
        #expect(caret() == (0, l1.0))
        press("End", Mods())
        #expect(caret() == (0, next))
        #expect(s.st.selection.text?.atLineEnd == true)
        func drawn() -> Double? {
            guard let ts = s.st.selection.text, let l = TextCommands.layoutFor(s.st, ts) else { return nil }
            return l.caretDrawn(CaretPos(para: ts.caret.para, ch: ts.caret.char), ts.atLineEnd ? .upstream : .downstream)?.top
        }
        let line1Top = layout.lines.filter { $0.para == 0 }[1].top
        #expect(drawn() == line1Top)
        // End again stays on the line; Home goes back to its start, not the next line's.
        press("End", Mods())
        #expect(caret() == (0, next))
        press("Home", Mods(shift: true))
        #expect(isSel((0, next), (0, l1.0)))
        press("End", Mods(shift: true))
        #expect(isSel((0, next), (0, next)))
        #expect(drawn() == line1Top)
        // Down from a line's end lands on the next line, not two lines down.
        press("Down", Mods())
        let c = caret()
        #expect(c.1 > l2.0 && c.1 <= l2.1, "\(c) not on line \(l2)")
        // The caret is drawn at the end of the line it belongs to.
        s.run("text.move", #"{"to": "lineEnd"}"#)
        #expect(s.st.selection.text?.atLineEnd == true)
        // Ctrl+Home / Ctrl+End, with Shift extending.
        press("End", Mods(cmd: true))
        #expect(caret() == (1, 6))
        press("Home", Mods(shift: true, cmd: true))
        #expect(isSel((1, 6), (0, 0)))
        press("Home", Mods(cmd: true))
        press("End", Mods(shift: true, cmd: true))
        #expect(isSel((0, 0), (1, 6)))
        // A caret placed anywhere else is drawn at the start of its line again.
        s.run("text.select", "{\"anchor\": [0, \(next)], \"caret\": [0, \(next)]}")
        #expect(s.st.selection.text?.atLineEnd == false)
        #expect((drawn() ?? 0) > line1Top)
    }
}

@Suite("Text: hostile positions")
struct TextHostilePositionTests {
    /// Regression (crash fix): Delete Surrounding Text maps the caret across the deletion; a caret far past
    /// the end of its paragraph, with the deletion reaching back into the paragraph before, used to
    /// overflow that arithmetic and trap.
    @Test func deleteSurroundingWithAHugeCaretDoesNotTrap() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "abc\nd"}"#)
        let id = try #require(s.st.currentSlide?.shapes.first?.id.rawValue)
        s.run("text.edit", "{\"id\": \(id)}")
        s.run("text.select", #"{"anchor": [1, 0], "caret": [1, 18446744073709551615]}"#)
        let r = s.run("text.deleteSurrounding", #"{"before": 2, "after": 0}"#)
        #expect(r.get("deleted") == 2)
        #expect(s.st.currentSlide?.shapes.first?.text?.text == "abd")
    }
}
