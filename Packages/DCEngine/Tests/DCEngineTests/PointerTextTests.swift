// DCEngineTests — the pointer in text: clicks in flipped shapes land on the character drawn there, and the
// Format Painter applies when a drag, a double or a triple click selects a range, and only then. Ports
// `clicks_in_flipped_shapes_hit_the_text_where_it_is_drawn` of deckcraft crates/engine/src/tests.rs and the
// Format Painter pointer tests of crates/engine/src/tests_keys.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import Testing

@Suite("Pointer: text")
struct PointerTextTests {
    // tests.rs clicks_in_flipped_shapes_hit_the_text_where_it_is_drawn
    @Test func clicksInFlippedShapesHitTheTextWhereItIsDrawn() throws {
        // Flips don't mirror text, so a click lands on the character drawn under it.
        let s = session()
        let id = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 400, 100], "text": "Hello flipped world"}"#))
        func pos(_ x: Double, _ y: Double) -> Int {
            guard let sh = s.st.shape(id) else { return -1 }
            let p = Tools.textPos(s.st, sh, Point(x, y))
            return p.0 * 1000 + p.1
        }
        let xs = [240.0, 300.0, 360.0]
        let plain = xs.map { pos($0, 150) }
        #expect(plain[0] < plain[1] && plain[1] < plain[2], "\(plain)")
        s.run("shape.flip", #"{"axis": "horizontal"}"#)
        #expect(xs.map { pos($0, 150) } == plain)
        // flipV turns the text 180° about the box centre (300, 150).
        s.run("shape.flip", #"{"axis": "horizontal"}"#)
        s.run("shape.flip", #"{"axis": "vertical"}"#)
        #expect(xs.map { pos(600 - $0, 150) } == plain)
    }
}

/// The Format Painter pointer tests of tests_keys.rs, in the "Text keys" suite whose helpers they use.
extension TextKeysTests {
    /// Bold the first paragraph, select part of it and arm the Format Painter (tests_keys.rs `painter_armed`).
    private func painterArmed(_ sticky: Bool) -> Session {
        let (s, _) = editing("Hello\nworld", (0, 0))
        s.run("text.select", #"{"anchor": [0, 0], "caret": [0, 5]}"#)
        s.run("format.bold", #"{"on": true}"#)
        s.exec("format.painter", ["sticky": .bool(sticky)])
        return s
    }

    private func boldAt(_ s: Session, _ at: (Int, Int)) -> Bool {
        s.exec("text.select", ["anchor": [.integer(at.0), .integer(at.1)], "caret": [.integer(at.0), .integer(at.1 + 1)]])
        return s.run("format.state").get("bold") == true
    }

    /// `s.pointer(PointerEvent { kind, x, y, tol: 4, .. })` (tests_keys.rs `pointer`).
    private func point(_ s: Session, _ kind: PointerKind, _ x: Double, _ y: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        s.ptr(kind, x, y, tol: 4, sourceLocation: sourceLocation)
    }

    /// Three bulleted paragraphs "one", "two", "three" and the painter armed from bold plain text
    /// (tests_keys.rs `painter_over_bullets`).
    private func painterOverBullets() -> Session {
        let (s, _) = editing("one\ntwo\nthree\nplain", (0, 0))
        s.run("text.select", #"{"anchor": [3, 0], "caret": [3, 5]}"#)
        s.run("format.bold", #"{"on": true}"#)
        s.run("text.select", #"{"anchor": [0, 0], "caret": [2, 5]}"#)
        s.run("format.bullets", #"{"on": true}"#)
        s.run("text.select", #"{"anchor": [3, 0], "caret": [3, 5]}"#)
        s.run("format.painter")
        return s
    }

    private func bulleted(_ s: Session, _ para: Int) -> Bool {
        s.exec("text.select", ["anchor": [.integer(para), 0], "caret": [.integer(para), 0]])
        return s.run("format.state").get("bullets") == true
    }

    // tests_keys.rs format_painter_applies_to_a_dragged_text_selection
    @Test func formatPainterAppliesToADraggedTextSelection() throws {
        let s = painterArmed(false)
        #expect(!boldAt(s, (1, 0)))
        s.run("text.move", #"{"to": "start"}"#)
        // Drag across the second line's text.
        point(s, .down, 68, 90)
        point(s, .drag, 110, 90)
        point(s, .up, 110, 90)
        let t = try #require(s.st.selection.text)
        #expect(t.isRange, "the drag should select text")
        #expect(s.painter == nil, "the painter is used up")
        #expect(boldAt(s, (1, 0)))
    }

    // tests_keys.rs format_painter_applies_to_a_triple_clicked_paragraph
    @Test func formatPainterAppliesToATripleClickedParagraph() {
        let s = painterArmed(true)
        s.run("text.select", #"{"anchor": [1, 2], "caret": [1, 2]}"#)
        point(s, .tripleClick, 70, 90)
        #expect(s.painter != nil, "a sticky painter stays armed")
        #expect(boldAt(s, (1, 0)))
    }

    // tests_keys.rs format_painter_waits_for_a_range_on_a_plain_click
    @Test func formatPainterWaitsForARangeOnAPlainClick() {
        let s = painterArmed(false)
        point(s, .down, 68, 90)
        point(s, .up, 68, 90)
        #expect(s.painter != nil)
    }

    // tests_keys.rs format_painter_on_part_of_a_bulleted_line_keeps_its_bullet
    @Test func formatPainterOnPartOfABulletedLineKeepsItsBullet() {
        let s = painterArmed(false)
        s.run("text.select", #"{"anchor": [1, 0], "caret": [1, 5]}"#)
        s.run("format.bullets", #"{"on": true}"#)
        func isBulleted() -> Bool { s.run("format.state").get("bullets") == true }
        #expect(isBulleted())
        s.run("text.select", #"{"anchor": [0, 0], "caret": [0, 5]}"#)
        s.run("format.painter")
        point(s, .down, 68, 90)
        point(s, .drag, 100, 90)
        point(s, .up, 100, 90)
        #expect(s.painter == nil)
        #expect(boldAt(s, (1, 0)))
        #expect(isBulleted(), "the bullet stays")
    }

    // tests_keys.rs format_painter_triple_click_leaves_the_next_paragraph_alone
    @Test func formatPainterTripleClickLeavesTheNextParagraphAlone() {
        let s = painterOverBullets()
        s.run("text.select", #"{"anchor": [0, 1], "caret": [0, 1]}"#)
        point(s, .tripleClick, 70, 70)
        #expect(s.painter == nil)
        #expect([bulleted(s, 0), bulleted(s, 1), bulleted(s, 2)] == [false, true, true])
    }

    // tests_keys.rs format_painter_ignores_a_double_click_that_selects_nothing
    @Test func formatPainterIgnoresADoubleClickThatSelectsNothing() {
        let s = painterOverBullets()
        s.run("text.select", #"{"anchor": [0, 0], "caret": [1, 2]}"#)
        let before = sel(s)
        point(s, .doubleClick, 900, 520)
        #expect(sameSel(s, before.0, before.1))
        #expect(s.painter != nil, "a click that left the selection alone keeps the painter")
        #expect(bulleted(s, 0))
    }

    // tests_keys.rs format_painter_ignores_a_shift_press_that_leaves_the_selection
    @Test func formatPainterIgnoresAShiftPressThatLeavesTheSelection() {
        let s = painterArmed(false)
        // Find the caret position under the point, then select from the line start to it.
        point(s, .down, 110, 90)
        point(s, .up, 110, 90)
        let k = caret(s)
        #expect(k.1 > 0)
        s.exec("text.select", ["anchor": [.integer(k.0), 0], "caret": [.integer(k.0), .integer(k.1)]])
        // Shift-pressing at the caret keeps the range, so there is nothing new to paint.
        for kind in [PointerKind.down, .up] { s.ptr(kind, 110, 90, tol: 4, mods: Self.shift) }
        #expect(sameSel(s, (k.0, 0), k))
        #expect(s.painter != nil, "the painter stays armed")
        #expect(!boldAt(s, (1, 0)))
    }
}
