// DCAppModelTests — editing text in place as the Mac's text system drives it: the UTF-16 document an
// `NSTextInputClient` sees, input methods' marked text and commits, typing on a selected shape, replacement
// ranges, and where the candidate window goes. Ported from deckcraft `crates/ui-egui/src/ime_tests.rs` and
// the keyboard tests of `lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors): the
// behaviour each checks, through AppKit's calls instead of egui's IME events. The tests of egui's own IME
// plumbing (reset fences, descriptors, tombstones, viewports) have no AppKit counterpart: the input context
// keeps that state itself (see PORT-NOTES).
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct CanvasTextInputTests {
    static let none = NSRange(location: NSNotFound, length: 0)

    /// A blank slide with a text box holding `text`, being edited with the caret at its end.
    static func editing(_ text: String) throws -> (AppModel, ShapeId) {
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        let r = try app.session.execute("insert.textBox", ["rect": [100, 100, 400, 100], "text": .string(text)])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        app.run("text.edit", ["id": id.toJSON(), "end": true])
        return (app, id)
    }

    static func text(_ app: AppModel, _ id: ShapeId) -> String {
        app.session.activeDoc?.shape(id)?.text?.text ?? ""
    }

    static func undoCount(_ app: AppModel) -> Int { app.session.activeDoc?.history.undo.count ?? 0 }

    /// The UTF-16 document: paragraphs joined by newlines, surrogate pairs counted as two, positions both ways.
    @Test func theDocumentCountsUTF16() {
        var body = TextBody()
        body.paragraphs = [Paragraph("a😀b"), Paragraph("\u{0B}é")]
        let d = CanvasTextDocument(body)
        #expect(d.string == "a😀b\n\né")
        #expect(d.length == 7)
        #expect(d.offset(TextPoint(0, 2)) == 3, "after the emoji's two units")
        #expect(d.offset(TextPoint(1, 0)) == 5)
        #expect(d.offset(TextPoint(1, 9)) == 7, "past the end clamps")
        #expect(d.offset(TextPoint(9, 0)) == 7)
        #expect(d.point(2) == TextPoint(0, 1), "inside a surrogate pair: the character's start")
        #expect(d.point(4) == TextPoint(0, 3), "a paragraph break belongs to the paragraph before it")
        #expect(d.point(5) == TextPoint(1, 0))
        #expect(d.point(-3) == TextPoint(0, 0) && d.point(99) == TextPoint(1, 2))
        #expect(d.substring(NSRange(location: 1, length: 2))?.0 == "😀")
        #expect(d.substring(NSRange(location: 5, length: 99))?.1 == NSRange(location: 5, length: 2))
        #expect(CanvasTextDocument.scalarCount("😀ab", utf16: 3) == 2)
        #expect(CanvasTextDocument(nil).string.isEmpty)
    }

    // ime_tests.rs: korean_composes_in_a_slide_text_box (#101)
    @Test func koreanComposesInASlideTextBox() throws {
        let (app, id) = try Self.editing("Title ")
        let undo = Self.undoCount(app)
        for pre in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"] {
            app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, pre, selected: NSRange(location: pre.utf16.count, length: 0), replacement: Self.none) }
            #expect(Self.text(app, id) == "Title " + pre, "each preedit replaces the last")
            let st = try #require(app.session.activeDoc)
            #expect(CanvasTextInput.markedRange(st) == NSRange(location: 6, length: pre.utf16.count))
            #expect(!TextCommands.compositionUnderlines(st).isEmpty, "the preedit is underlined")
            #expect(Self.undoCount(app) == undo, "a preedit is not an undo step")
        }
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "한글", replacement: Self.none) }
        #expect(Self.text(app, id) == "Title 한글")
        #expect(app.session.activeDoc?.composition == nil)
        #expect(Self.undoCount(app) == undo + 1, "the commit is one undo step")
        app.run("edit.undo")
        #expect(Self.text(app, id) == "Title ")
        // The candidate window goes at the insertion point.
        let st = try #require(app.session.activeDoc)
        let r = try #require(CanvasTextInput.firstRect(st, NSRange(location: 6, length: 0)))
        #expect(r.x0 >= 100 && r.x0 <= 500 && r.y0 >= 100 && r.y1 <= 200 && r.height > 0)
        #expect(CanvasTextInput.imeArea(st) != nil)
    }

    // ime_tests.rs: japanese_conversion_shows_the_active_part
    @Test func japaneseConversionShowsTheActivePart() throws {
        let (app, _) = try Self.editing("")
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "わたしは", selected: NSRange(location: 4, length: 0), replacement: Self.none) }
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "私は", selected: NSRange(location: 0, length: 1), replacement: Self.none) }
        let st = try #require(app.session.activeDoc)
        #expect(st.composition.map { $0.active?.0 == 0 && $0.active?.1 == 1 } == true, "the part being converted")
        #expect(TextCommands.compositionUnderlines(st).contains { $0.2 }, "drawn with a thicker line")
        // A key the application handles settles the composition the input method left open.
        app.key("Right", Mods())
        #expect(app.session.activeDoc?.composition == nil)
        #expect(app.session.activeDoc?.shape(st.selection.text?.shape ?? ShapeId(0))?.text?.text == "私は")
    }

    // ime_tests.rs: composing_on_a_selected_shape_starts_editing_it
    @Test func composingOnASelectedShapeStartsEditingIt() throws {
        let (app, id) = try Self.editing("Old")
        app.run("text.exit")
        app.run("edit.select", ["ids": [id.toJSON()]])
        #expect(app.session.activeDoc?.selection.text == nil)
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "ㄱ", selected: NSRange(location: 1, length: 0), replacement: Self.none) }
        #expect(app.session.activeDoc?.selection.text?.shape == id, "the first preedit starts editing")
        #expect(Self.text(app, id) == "ㄱ", "and replaces the shape's text, as typing does")
    }

    /// Typing on one selected shape replaces its text (PowerPoint's behaviour); with nothing or two
    /// selected it goes nowhere (deckcraft's `keyboard` Text arm).
    @Test func typingOnASelectedShapeReplacesItsText() throws {
        let (app, id) = try Self.editing("Old")
        app.run("text.exit")
        app.run("edit.select", ["ids": [id.toJSON()]])
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "N", replacement: Self.none) }
        #expect(Self.text(app, id) == "N")
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "ew", replacement: Self.none) }
        #expect(Self.text(app, id) == "New")
        app.run("text.exit")
        app.run("edit.deselect")
        let r = app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "x", replacement: Self.none) }
        #expect((try? r.get())?["handled"]?.asBool == false)
        #expect(Self.text(app, id) == "New")
    }

    // ime_tests.rs: no_op_commit_stays_other_and_empty_text_is_available, empty_commit_does_not_poison_a_commit_in_the_same_frame
    @Test func anEmptyCommitChangesNothing() throws {
        let (app, id) = try Self.editing("abc")
        let undo = Self.undoCount(app)
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "", replacement: Self.none) }
        #expect(Self.text(app, id) == "abc" && Self.undoCount(app) == undo)
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "d", replacement: Self.none) }
        #expect(Self.text(app, id) == "abcd")
        // An empty preedit cancels the composition.
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "x", selected: NSRange(location: 1, length: 0), replacement: Self.none) }
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "", selected: NSRange(location: 0, length: 0), replacement: Self.none) }
        #expect(Self.text(app, id) == "abcd")
        #expect(CanvasTextInput.markedRange(try #require(app.session.activeDoc)) == nil)
    }

    /// `unmarkText`: the input method ends its composition and the text stays (`Disabled`/`Enabled`).
    @Test func unmarkKeepsTheComposedText() throws {
        let (app, id) = try Self.editing("ab")
        app.input { s throws(EngineError) in try CanvasTextInput.setMarkedText(s, "é", selected: NSRange(location: 1, length: 0), replacement: Self.none) }
        CanvasTextInput.unmarkText(app.session)
        #expect(Self.text(app, id) == "abé" && app.session.activeDoc?.composition == nil)
    }

    /// A replacement range (reconversion, the accent menu, dictation's corrections) is replaced.
    @Test func aReplacementRangeIsReplaced() throws {
        let (app, id) = try Self.editing("hello world")
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "there", replacement: NSRange(location: 6, length: 5)) }
        #expect(Self.text(app, id) == "hello there")
        app.input { s throws(EngineError) in
            try CanvasTextInput.setMarkedText(s, "Hé", selected: NSRange(location: 2, length: 0), replacement: NSRange(location: 0, length: 1))
        }
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "Hé", replacement: Self.none) }
        #expect(Self.text(app, id) == "Héello there")
    }

    // ime_tests.rs: ime_output_is_logical_bounded_and_owner_stable (the selection the text system reads)
    @Test func theSelectedRangeFollowsTheCaretAndAReversedSelection() throws {
        let (app, _) = try Self.editing("ab\ncd")
        var st = try #require(app.session.activeDoc)
        #expect(CanvasTextInput.selectedRange(st) == NSRange(location: 5, length: 0))
        app.run("text.select", ["anchor": [1, 2], "caret": [0, 1]])
        st = try #require(app.session.activeDoc)
        #expect(CanvasTextInput.selectedRange(st) == NSRange(location: 1, length: 4), "a reversed selection is the same range")
        #expect(CanvasTextDocument(st)?.substring(NSRange(location: 1, length: 4))?.0 == "b\ncd")
        let quads = CanvasTextInput.selectionQuads(st, try #require(st.selection.text))
        #expect(quads.count == 2, "one per line")
        // The character under a point of the text.
        let first = try #require(CanvasTextInput.firstRect(st, NSRange(location: 0, length: 0)))
        #expect(CanvasTextInput.characterIndex(st, Point(first.x0 + 0.5, (first.y0 + first.y1) / 2)) == 0)
    }

    // lib.rs: ctrl_word_keys_edit_text (the Mac's: Option moves and deletes by word)
    @Test func optionWordKeysEditText() throws {
        let (app, id) = try Self.editing("one two three")
        app.key("Backspace", Mods(alt: true))
        #expect(Self.text(app, id) == "one two ")
        app.key("Left", Mods(alt: true))
        app.key("Left", Mods(alt: true))
        app.key("Delete", Mods(alt: true))
        #expect(Self.text(app, id) == "two ", "Option-Delete takes the word after the caret and its space")
    }

    // lib.rs: typing_goes_on_after_tab_in_a_text_box
    @Test func typingGoesOnAfterTabInATextBox() throws {
        let (app, id) = try Self.editing("a")
        app.session.prefs.autocorrect = false
        app.key("Tab", Mods())
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "b", replacement: Self.none) }
        #expect(Self.text(app, id) == "a\tb")
        app.key("Enter", Mods())
        app.input { s throws(EngineError) in try CanvasTextInput.insertText(s, "c", replacement: Self.none) }
        #expect(Self.text(app, id) == "a\tb\nc")
        app.key("Escape", Mods())
        #expect(app.session.activeDoc?.selection.text == nil, "Escape stops editing")
    }
}
