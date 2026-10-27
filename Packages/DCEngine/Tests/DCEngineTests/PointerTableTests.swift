// DCEngineTests — the pointer in tables: double clicks select the word in the cell drawn there, clicks move the
// caret between cells, presses outside the cells move the table, and border drags size columns and rows.
// Ports the table tests of deckcraft crates/engine/src/tests.rs that drive `Session::pointer` (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The table tests that also click or drag among
// the command tests (TableCommandTests) are whole there.
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCText
import Testing

/// A table at (100, 100): columns `cols` wide, rows 40 pt tall, cells holding `data` (tests.rs `table_at`).
private func tableAt(_ s: Session, _ cols: [Double], _ data: [[String]]) -> ShapeId {
    let w = cols.reduce(0, +)
    let r = s.exec("insert.table", [
        "rows": .integer(data.count), "cols": .integer(cols.count),
        "rect": [100.0, 100.0, .num(w), .num(40.0 * Double(data.count))],
        "data": .array(data.map { .array($0.map(JSON.string)) }),
    ])
    let id = shapeIdOf(r)
    for (c, cw) in cols.enumerated() { s.exec("table.columnWidth", ["id": id.toJSON(), "col": .integer(c), "width": .num(cw)]) }
    s.run("edit.deselect")
    return id
}

private func tableOf(_ s: Session, _ id: ShapeId) -> Table {
    if case .table(let t)? = s.st.shape(id)?.kind { return t }
    Issue.record("not a table: \(id)")
    return Table(rows: 1, cols: 1, width: 1, rowHeight: 1)
}

private func textSel(_ s: Session) -> TextSel? { s.activeDoc?.selection.text }

/// Slide point of the caret before character `ch` of paragraph `para` of text `t` (tests.rs `text_point`).
private func textPoint(_ st: DocState, _ t: TextSel, _ para: Int, _ ch: Int) throws -> Point {
    let (l, m) = try #require(TextCommands.textFrame(st, t))
    let c = try #require(l.caret(CaretPos(para: para, ch: ch)))
    return m * Point(c.x, (c.top + c.bottom) / 2.0)
}

private func caretPoint(_ s: Session, _ para: Int, _ ch: Int) throws -> Point {
    try textPoint(s.st, try #require(textSel(s)), para, ch)
}

@Suite("Pointer: tables")
struct PointerTableTests {
    // tests.rs double_click_in_table_uses_grown_row_heights
    @Test func doubleClickInTableUsesGrownRowHeights() {
        // Rows stored 4 pt tall are drawn tall enough for their text, so 6 pt down is still row 0.
        let s = session()
        let r = s.run("insert.table", #"{"rows": 3, "cols": 2, "rect": [100.0, 100.0, 400.0, 120.0], "data": [["a", "b"], ["c", "d"], ["e", "f"]]}"#)
        let id = r.get("id") ?? .null
        for row in 0 ..< 3 { s.exec("table.rowHeight", ["id": id, "row": .integer(row), "height": 4.0]) }
        s.ptr(.doubleClick, 120, 106)
        #expect(s.st.selection.text?.cell == TextPoint(0, 0))
    }

    // tests.rs double_click_in_a_cell_selects_the_word_clicked
    @Test func doubleClickInACellSelectsTheWordClicked() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["Hello world", "b"], ["c", "d"]])
        // Where "world" is drawn.
        s.exec("text.edit", ["id": id.toJSON(), "cell": [0, 0]])
        let p = try caretPoint(s, 0, 8)
        s.run("text.exit")
        s.run("edit.deselect")
        // As the UI sends it: press, release, press, double-click (on release), then the release.
        s.ptr(.down, p.x, p.y)
        s.ptr(.up, p.x, p.y)
        #expect(textSel(s) == nil, "a click on an unselected table selects it")
        s.ptr(.down, p.x, p.y)
        s.ptr(.doubleClick, p.x, p.y)
        s.ptr(.up, p.x, p.y)
        let t = try #require(textSel(s))
        #expect(t.cell == TextPoint(0, 0) && sameRange(orderedOf(t), ((0, 6), (0, 11))), "the word under the double-click")
        // The control channel sends the double-click alone.
        s.run("text.exit")
        s.run("edit.deselect")
        s.ptr(.doubleClick, p.x, p.y)
        #expect(sameRange(orderedOf(textSel(s)), ((0, 6), (0, 11))))
    }

    // tests.rs clicks_while_editing_a_cell_move_the_caret_between_cells
    @Test func clicksWhileEditingACellMoveTheCaretBetweenCells() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["Hello world", "Second cell"], ["c", "d"]])
        s.exec("text.edit", ["id": id.toJSON(), "cell": [0, 1], "at": [0, 0]])
        let p6 = try caretPoint(s, 0, 6)
        let p11 = try caretPoint(s, 0, 11)
        s.exec("text.edit", ["id": id.toJSON(), "cell": [1, 0]])
        // A click in another cell of the table moves the caret there, at the click.
        s.ptr(.down, p6.x, p6.y)
        var t = try #require(textSel(s))
        #expect(t.shape == id && t.cell == TextPoint(0, 1) && t.caret == TextPoint(0, 6) && t.anchor == TextPoint(0, 6))
        // Dragging selects within that cell, even past its edge.
        s.ptr(.drag, p11.x, p11.y)
        s.ptr(.drag, 600, p11.y)
        s.ptr(.up, 600, p11.y)
        t = try #require(textSel(s))
        #expect(t.cell == TextPoint(0, 1) && sameRange(orderedOf(t), ((0, 6), (0, 11))))
        // Shift+click in another cell starts a new caret there instead of extending across cells.
        s.ptr(.down, 150, 165, mods: Mods(shift: true))
        s.ptr(.up, 150, 165)
        t = try #require(textSel(s))
        #expect(t.cell == TextPoint(1, 0) && !t.isRange)
        // Typing goes into the clicked cell.
        s.run("text.insert", #"{"text": "X"}"#)
        #expect(tableOf(s, id).cell(1, 0)?.text.text == "cX")
        // A click outside the table stops editing.
        s.clickAt(50, 400)
        #expect(textSel(s) == nil)
    }

    // tests.rs pressing_a_table_outside_its_cells_with_a_range_selected_moves_the_table
    @Test func pressingATableOutsideItsCellsWithARangeSelectedMovesTheTable() throws {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        s.exec("text.edit", ["id": id.toJSON(), "cell": [0, 0]])
        s.ptr(.down, 150, 120)
        s.ptr(.drag, 250, 160)
        s.ptr(.up, 250, 160)
        #expect(s.st.selection.cells == CellRange(id, TextPoint(0, 0), TextPoint(1, 1)))
        // Just left of the table's edge, where a press still hits the table but no cell.
        s.ptr(.down, 98, 120)
        #expect(s.st.selection.cells == nil, "the range ends")
        s.ptr(.drag, 148, 170)
        s.ptr(.up, 148, 170)
        #expect(s.st.selection.text == nil)
        #expect(s.st.selection.shapes == [id])
        let x = try #require(s.st.shape(id)?.xfrm)
        #expect(abs(x.x - 150) < 10 && abs(x.y - 150) < 10, "the table moves: \(x)")
        // A click (no drag) there keeps the table selected and puts no caret in the nearest cell.
        s.clickAt(x.x - 2, x.y + 20)
        #expect(s.st.selection.shapes == [id] && s.st.selection.text == nil)
    }

    // tests.rs a_click_in_a_selected_table_enters_the_clicked_cell
    @Test func aClickInASelectedTableEntersTheClickedCell() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["a", "b"], ["c", "Hello world"]])
        s.clickAt(350, 160)
        #expect(s.st.selection.shapes == [id] && textSel(s) == nil, "the first click selects the table")
        let p = try textPoint(s.st, TextSel(shape: id, cell: TextPoint(1, 1)), 0, 6)
        s.clickAt(p.x, p.y)
        let t = try #require(textSel(s))
        #expect(t.cell == TextPoint(1, 1) && t.caret == TextPoint(0, 6), "caret at the click")
        // Dragging a selected table still moves it.
        s.run("text.exit")
        s.ptr(.down, 150, 120)
        s.ptr(.drag, 170, 130)
        s.ptr(.up, 170, 130)
        #expect(textSel(s) == nil)
        #expect(s.st.shape(id)?.xfrm?.x != 100)
    }

    // tests.rs dragging_column_borders_resizes_columns
    @Test func draggingColumnBordersResizesColumns() {
        let s = session()
        let id = tableAt(s, [100, 100, 100], [["a", "b", "c"], ["d", "e", "f"]])
        let undoDepth = s.st.history.undo.count
        // An inner border: the two columns share the change, the table keeps its width.
        s.ptr(.down, 200, 125)
        s.ptr(.drag, 215, 125)
        s.ptr(.drag, 230, 128)
        s.ptr(.up, 230, 128)
        #expect(tableOf(s, id).cols == [130, 70, 100])
        #expect(s.st.shape(id)?.xfrm?.w == 300)
        #expect(s.st.history.undo.count == undoDepth + 1, "one undo step per drag")
        // Columns don't collapse.
        s.ptr(.down, 230, 125)
        s.ptr(.drag, 500, 125)
        s.ptr(.up, 500, 125)
        #expect(tableOf(s, id).cols == [200 - TableCommands.minColumnWidth, TableCommands.minColumnWidth, 100])
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(tableOf(s, id).cols == [100, 100, 100])
        // The right edge: the last column and the table get wider.
        s.ptr(.down, 400, 120)
        s.ptr(.drag, 450, 120)
        s.ptr(.up, 450, 120)
        #expect(tableOf(s, id).cols == [100, 100, 150])
        #expect(s.st.shape(id)?.xfrm?.w == 350)
        // A click on a border without dragging changes nothing.
        let before = s.st.docRef
        s.clickAt(200, 125)
        #expect(before === s.st.docRef)
    }

    // tests.rs dragging_a_row_border_sets_the_row_height
    @Test func draggingARowBorderSetsTheRowHeight() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["a", "b"], ["c", "d"]])
        func drawn() -> [Double] { Tools.tableRows(s.st, tableOf(s, id)) }
        s.ptr(.down, 150, 140)
        s.ptr(.drag, 150, 170)
        s.ptr(.up, 150, 170)
        #expect(drawn() == [70, 40])
        let st = s.st
        #expect(Cmd.xfrmOf(st.doc, st.selection, try #require(st.shape(id))).h == 110, "the table grows")
        // Rows still fit their text: dragging the border up stops at the text.
        s.ptr(.down, 150, 170)
        s.ptr(.drag, 150, 60)
        s.ptr(.up, 150, 60)
        let h = drawn()[0]
        #expect(h > 10 && h < 40, "row 0 shrinks to its text: \(h)")
        // The bottom edge sizes the last row.
        let bottom = 100 + drawn().reduce(0, +)
        s.ptr(.down, 150, bottom)
        s.ptr(.drag, 150, bottom + 20)
        s.ptr(.up, 150, bottom + 20)
        #expect(drawn().at(1) == 60)
    }

    // tests.rs dragging_a_border_while_editing_a_cell_keeps_editing
    @Test func draggingABorderWhileEditingACellKeepsEditing() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"]])
        s.exec("text.edit", ["id": id.toJSON(), "cell": [0, 1]])
        s.ptr(.down, 200, 120)
        s.ptr(.drag, 180, 120)
        s.ptr(.up, 180, 120)
        #expect(tableOf(s, id).cols == [80, 120])
        #expect(textSel(s)?.cell == TextPoint(0, 1))
    }

    /// Draw Table: the pencil draws a one-cell table on the slide and splits cells inside one; the eraser
    /// merges the cells on either side of a border; the pencil stays on (tools.rs `down` › `TABLE_ERASER`,
    /// `drag` and `up` › `Create`).
    @Test func drawTablePencilAndEraser() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.setTool(.shape(preset: Tools.drawTable))
        s.ptr(.down, 100, 100)
        s.ptr(.drag, 300, 200)
        let r = s.ptr(.up, 300, 200)
        let id = shapeIdOf(r)
        #expect(tableOf(s, id).rows.count == 1 && tableOf(s, id).cols == [200])
        #expect(s.tool.kind == .shape(preset: Tools.drawTable), "the pencil stays on")
        // Inside the table a drag draws a straight border, down the middle.
        s.ptr(.down, 200, 105)
        s.ptr(.drag, 203, 195)
        #expect(s.tool.preview == Xfrm(200, 105, 0, 90))
        s.ptr(.up, 203, 195)
        #expect(tableOf(s, id).cols.count == 2)
        // A press too small for a table draws nothing.
        let n = s.st.shapes.count
        s.ptr(.down, 400, 300)
        s.ptr(.up, 402, 302)
        #expect(s.st.shapes.count == n)
        // The eraser on the new border merges the two cells back.
        s.setTool(.shape(preset: Tools.tableEraser))
        s.ptr(.down, 200, 150)
        let t = tableOf(s, id)
        #expect(t.rows[0].cells[0].gridSpan == 2, "\(t.rows[0].cells)")
        // Away from any border, the eraser does nothing.
        s.ptr(.down, 600, 400)
    }
}
