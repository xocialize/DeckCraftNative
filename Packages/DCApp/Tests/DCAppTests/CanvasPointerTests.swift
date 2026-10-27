// DCAppTests — the canvas driven with the mouse through AppKit's own calls (`mouseDown`, `mouseDragged`,
// `mouseUp`) into `Session.pointer`: selecting, moving, the marquee, objects off the slide, table cells and
// borders, Draw Table, and the ruler's markers. Ported from deckcraft `crates/ui-egui/src/canvas.rs`,
// `lib.rs` (`off_slide_objects_…`, `the_canvas_renders_only_…`), `drawtable_tests.rs` and `ruler_tests.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite struct CanvasPointerTests {
    typealias Fixture = CanvasViewTests.Fixture

    static func mouse(_ f: Fixture, _ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: f.canvas.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    static func click(_ f: Fixture, _ x: Double, _ y: Double, clicks: Int = 1) {
        let p = f.at(x, y)
        for k in 1 ... clicks {
            if let e = mouse(f, .leftMouseDown, p, clicks: k) { f.canvas.mouseDown(with: e) }
            if let e = mouse(f, .leftMouseUp, p, clicks: k) { f.canvas.mouseUp(with: e) }
        }
    }

    static func drag(_ f: Fixture, _ a: (Double, Double), _ b: (Double, Double), steps: Int = 8) {
        if let e = mouse(f, .leftMouseDown, f.at(a.0, a.1)) { f.canvas.mouseDown(with: e) }
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            if let e = mouse(f, .leftMouseDragged, f.at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)) { f.canvas.mouseDragged(with: e) }
        }
        if let e = mouse(f, .leftMouseUp, f.at(b.0, b.1)) { f.canvas.mouseUp(with: e) }
    }

    static func ids(_ f: Fixture) -> [UInt32] { f.model.session.activeDoc?.selection.shapes.map(\.rawValue) ?? [] }

    /// A click selects, a drag moves (one undo step), a click on bare slide deselects.
    @Test func clickSelectsAndDragMoves() throws {
        let f = Fixture()
        f.model.session.prefs.snapToGrid = false
        f.model.run("edit.deselect")
        Self.click(f, 200, 150)
        #expect(Self.ids(f).count == 1, "the click selects the rectangle")
        let undo = f.model.session.activeDoc?.history.undo.count ?? 0
        Self.drag(f, (200, 150), (260, 190))
        let x = try #require(f.selected?.xfrm)
        #expect(abs(x.x - 160) < 1.5 && abs(x.y - 140) < 1.5, "\(x)")
        #expect(f.model.session.activeDoc?.history.undo.count == undo + 1, "the move is one undo step")
        Self.click(f, 700, 450)
        #expect(Self.ids(f).isEmpty)
    }

    // canvas.rs: a_fitted_slide_has_no_scroll_bars (a drag on bare slide is a marquee)
    @Test func aDragOnBareSlideIsAMarquee() throws {
        let f = Fixture()
        f.model.run("shape.insert", ["preset": "ellipse", "rect": [400, 100, 100, 100]])
        f.model.run("edit.deselect")
        var sawMarquee = false
        if let e = Self.mouse(f, .leftMouseDown, f.at(50, 50)) { f.canvas.mouseDown(with: e) }
        for i in 1 ... 8 {
            if let e = Self.mouse(f, .leftMouseDragged, f.at(50 + 70 * Double(i), 50 + 30 * Double(i))) { f.canvas.mouseDragged(with: e) }
            sawMarquee = sawMarquee || f.model.session.tool.marquee != nil
        }
        if let e = Self.mouse(f, .leftMouseUp, f.at(610, 290)) { f.canvas.mouseUp(with: e) }
        #expect(sawMarquee, "the drag selects on the canvas")
        #expect(Self.ids(f).count == 2, "both shapes are inside it")
        #expect(f.model.session.tool.marquee == nil)
    }

    // lib.rs: off_slide_objects_show_on_the_pasteboard_and_can_be_selected_and_moved,
    // the_canvas_renders_only_the_slide_when_nothing_is_off_it (an unchanged slide isn't drawn again)
    @Test func offSlideObjectsShowOnThePasteboardAndCanBeSelectedAndMoved() throws {
        let f = Fixture(zoom: 0.5)
        f.model.session.prefs.snapToGrid = false
        f.model.run("shape.insert", ["preset": "rect", "rect": [1000, 100, 120, 80]])
        f.model.run("shape.fill", ["color": "#00ff00"])
        f.model.run("edit.deselect")
        f.vc.refresh()
        // Drawn on the surround, beside the slide.
        let p = f.at(1060, 140)
        let rep = try #require(f.canvas.bitmapImageRepForCachingDisplay(in: f.canvas.bounds))
        f.canvas.cacheDisplay(in: f.canvas.bounds, to: rep)
        let k = Double(rep.pixelsWide) / f.canvas.bounds.width
        let c = try #require(rep.colorAt(x: Int(p.x * k), y: Int(p.y * k))?.usingColorSpace(.sRGB))
        #expect(c.greenComponent > 0.8 && c.greenComponent - c.redComponent > 0.3, "the off-slide shape is drawn: \(c)")
        Self.click(f, 1060, 140)
        #expect(f.selected?.xfrm?.x == 1000, "a click selects it")
        Self.drag(f, (1060, 140), (1100, 140))
        #expect(abs((f.selected?.xfrm?.x ?? 0) - 1040) < 1.5, "a drag moves it further off")
        // Idle refreshes don't make the picture again.
        f.canvas.display()
        let n = f.canvas.pictureCount
        f.vc.refresh()
        f.canvas.display()
        f.vc.refresh()
        #expect(f.canvas.pictureCount == n)
    }

    // canvas.rs: double_click_in_a_table_cell_shows_the_caret_there
    @Test func doubleClickInATableCellShowsTheCaretThere() throws {
        let f = Fixture()
        let r = try f.model.session.execute("insert.table", ["rows": 2, "cols": 2, "rect": [100, 100, 400, 80], "data": [["Hello world", "b"], ["c", ""]]])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        f.model.run("edit.deselect")
        f.vc.refresh()
        // The empty cell (1, 1) spans x 300..500, y 140..180.
        Self.click(f, 400, 160, clicks: 2)
        let st = try #require(f.model.session.activeDoc)
        let t = try #require(st.selection.text, "editing the cell")
        #expect(t.shape == id && t.cell == TextPoint(1, 1))
        #expect(CanvasTextInput.selectionQuads(st, t).isEmpty, "no range")
        let (top, bottom) = try #require(TextCommands.caretLine(st, t))
        for q in [top, bottom] { #expect(q.x > 300 && q.x < 500 && q.y >= 140 && q.y <= 180, "caret \(q) outside cell (1, 1)") }
        // A click in another cell moves the caret there.
        Self.click(f, 110, 120)
        let t2 = try #require(f.model.session.activeDoc?.selection.text)
        #expect(t2.cell == TextPoint(0, 0) && t2.caret == TextPoint(0, 0))
    }

    // canvas.rs: table_borders_resize_with_the_pointer
    @Test func tableBordersResizeWithThePointer() throws {
        let f = Fixture()
        let r = try f.model.session.execute("insert.table", ["rows": 2, "cols": 2, "rect": [100, 100, 400, 80], "data": [["Hello world", "b"], ["c", ""]]])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        f.model.run("edit.deselect")
        f.vc.refresh()
        if let e = Self.mouse(f, .mouseMoved, f.at(300, 120)) { f.canvas.mouseMoved(with: e) }
        #expect(CanvasCursor.of(f.model.session) == .resizeColumn, "the border shows a column cursor")
        Self.drag(f, (300, 120), (340, 120), steps: 4)
        guard case .table(let t)? = f.model.session.activeDoc?.shape(id)?.kind else {
            Issue.record("not a table")
            return
        }
        #expect(abs(t.cols[0] - 240) < 0.5 && abs(t.cols[1] - 160) < 0.5, "\(t.cols)")
    }

    // drawtable_tests.rs: draw_a_table_split_it_and_erase_the_border
    @Test func drawATableSplitItAndEraseTheBorder() throws {
        let f = Fixture()
        f.model.run("edit.selectAll")
        f.model.run("edit.delete")
        f.model.session.setTool(.shape(preset: Tools.drawTable))
        f.model.session.tool.sticky = true
        func table() -> (Table, Xfrm)? {
            f.model.session.activeDoc?.shapes.lazy.compactMap { s -> (Table, Xfrm)? in
                if case .table(let t) = s.kind, let x = s.xfrm { return (t, x) }
                return nil
            }.first
        }
        Self.drag(f, (200, 100), (600, 300), steps: 10)
        let (t, x) = try #require(table(), "the pencil drew a table")
        #expect(t.nRows == 1 && t.nCols == 1)
        #expect(abs(x.w - 400) < 3 && abs(x.h - 200) < 3, "\(x)")
        // Still the pencil: a border across, then one down the bottom half only.
        Self.drag(f, (205, 180), (610, 180), steps: 10)
        Self.drag(f, (350, 190), (350, 299), steps: 10)
        let (t2, _) = try #require(table())
        #expect(t2.nRows == 2 && t2.nCols == 2, "\(t2)")
        #expect(t2.cell(0, 0)?.gridSpan == 2, "the top row stays one cell")
        // The eraser on the vertical border merges the bottom cells again.
        f.model.session.setTool(.shape(preset: Tools.tableEraser))
        Self.click(f, 350, 250)
        #expect(table()?.0.cell(1, 0)?.gridSpan == 2)
        f.model.run("edit.undo")
        #expect(table()?.0.cell(1, 0)?.gridSpan == 1)
    }

    // ruler_tests.rs: drag_indents_add_move_and_remove_tabs_on_the_ruler
    @Test func dragIndentsAddMoveAndRemoveTabsOnTheRuler() throws {
        let f = Fixture()
        f.model.run("edit.selectAll")
        f.model.run("edit.delete")
        let r = try f.model.session.execute("insert.textBox", ["rect": [100, 150, 500, 40]])
        f.model.run("text.edit", ["id": .integer(Int(r["id"]?.asU64 ?? 0))])
        f.model.run("text.insert", ["text": "Name\tRole\tTeam"])
        f.model.run("view.ruler", ["on": true])
        f.vc.refresh()
        let rulers = f.vc.rulers
        func ruler() throws -> JSON { try f.model.session.execute("format.ruler", .emptyObject) }
        let x0 = try #require(try ruler()["x"]?.asF64)
        let k = try #require(f.canvas.layoutInfo?.scale)
        let slideLeft = f.canvas.convert(try #require(f.canvas.layoutInfo?.slideRect), to: rulers).minX
        func rx(_ q: Double) -> Double { slideLeft + (x0 + q) * k }
        func ev(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: rulers.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        func drag(_ a: (Double, Double), _ b: (Double, Double)) {
            if let e = ev(.leftMouseDown, a.0, a.1) { rulers.mouseDown(with: e) }
            for i in 1 ... 8 {
                let t = Double(i) / 8
                if let e = ev(.leftMouseDragged, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t) { rulers.mouseDragged(with: e) }
            }
            if let e = ev(.leftMouseUp, b.0, b.1) { rulers.mouseUp(with: e) }
        }
        // First-line indent triangle (top) to 36 pt.
        drag((rx(0), 3), (rx(36), 3))
        var v = try ruler()
        #expect(abs((v["indent"]?.asF64 ?? 0) - 36) <= 1, "\(v)")
        #expect(v["marginLeft"]?.asF64 == 0)
        // Hanging triangle (middle) to 18 pt: the first line stays at 36.
        drag((rx(0), 8), (rx(18), 8))
        v = try ruler()
        let (ml, ind) = (v["marginLeft"]?.asF64 ?? 0, v["indent"]?.asF64 ?? 0)
        #expect(abs(ml - 18) <= 1 && abs(ml + ind - 36) <= 1, "\(v)")
        // A click on the ruler: a left tab; drag it along; drag it off to remove it.
        if let e = ev(.leftMouseDown, rx(150), 12) { rulers.mouseDown(with: e) }
        if let e = ev(.leftMouseUp, rx(150), 12) { rulers.mouseUp(with: e) }
        v = try ruler()
        #expect(v["tabs"]?.asArray?.count == 1, "\(v)")
        let pos = v["tabs"]?.at(0)?["pos"]?.asF64 ?? 0
        #expect(abs(pos - 150) <= 1)
        drag((rx(pos), 12), (rx(220), 12))
        let moved = try ruler()["tabs"]?.at(0)?["pos"]?.asF64 ?? 0
        #expect(abs(moved - 220) <= 1, "\(moved)")
        #expect(f.model.session.activeDoc?.selection.text != nil, "still editing the text")
        drag((rx(moved), 12), (rx(moved), 80))
        #expect(try ruler()["tabs"]?.asArray?.isEmpty == true)
    }

    // ruler_tests.rs: the_tab_selector_picks_the_kind_of_stop_a_click_sets
    @Test func theTabSelectorPicksTheKindOfStopAClickSets() throws {
        let f = Fixture()
        let r = try f.model.session.execute("insert.textBox", ["rect": [100, 300, 500, 40]])
        f.model.run("text.edit", ["id": .integer(Int(r["id"]?.asU64 ?? 0))])
        f.model.run("text.insert", ["text": "Item\t9.50"])
        f.model.run("view.ruler", ["on": true])
        f.vc.refresh()
        let rulers = f.vc.rulers
        func click(_ x: Double, _ y: Double) {
            let at = rulers.convert(CGPoint(x: x, y: y), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if t == .leftMouseDown { rulers.mouseDown(with: e) } else { rulers.mouseUp(with: e) }
            }
        }
        // Three clicks on the selector: Center, Right, Decimal.
        for _ in 0 ..< 3 { click(8, 8) }
        #expect(rulers.kind == 3)
        let x0 = try f.model.session.execute("format.ruler", .emptyObject)["x"]?.asF64 ?? 0
        let k = f.canvas.layoutInfo?.scale ?? 1
        let left = f.canvas.convert(f.canvas.layoutInfo?.slideRect ?? .zero, to: rulers).minX
        click(left + (x0 + 120) * k, 12)
        let tabs = try f.model.session.execute("format.ruler", .emptyObject)["tabs"]
        #expect(tabs?.at(0)?["align"]?.asStr == "dec", "\(String(describing: tabs))")
    }
}
