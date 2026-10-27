// DCEngineTests — the `table` command module and Draw Table: tests ported from deckcraft
// crates/engine/src/drawtable.rs and crates/engine/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Not ported (they drive the canvas through `Session::pointer` / `hit_test`, tools.rs, which no Wave 4
// module ports; see PORT-NOTES "Not ported"):
// - tests.rs `double_click_in_table_uses_grown_row_heights`, `double_click_in_a_cell_selects_the_word_clicked`,
//   `clicks_while_editing_a_cell_move_the_caret_between_cells`,
//   `pressing_a_table_outside_its_cells_with_a_range_selected_moves_the_table`,
//   `a_click_in_a_selected_table_enters_the_clicked_cell`, `dragging_column_borders_resizes_columns`,
//   `dragging_a_row_border_sets_the_row_height`, `dragging_a_border_while_editing_a_cell_keeps_editing`.
// Ported in part (their pointer steps left out, the rest kept; each says so):
// - `grown_table_frame_covers_its_drawn_rows` (not the hit test), `table_borders_are_hit_where_they_are_drawn`
//   and `rotated_tables_hit_the_cell_under_the_pointer` (through `TableFrame.borderAt` / `cellAt`, which the
//   pointer code calls), `dragging_across_cells_selects_a_range_of_cells` (the range made with
//   `table.selectCells` instead of a drag), `tables_with_a_file_defined_style_edit_and_resize` (not the clicks
//   and the border drag).
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCPPTX
import DCText
import Testing

/// `insert.table` with these values once the insert module registers it; until then the same table
/// (`Table::new(rows, cols, w, h / rows)` in `rect`, the cells holding `data`) added and selected directly.
private func insertTable(_ s: Session, _ rows: Int, _ cols: Int, _ rect: [Double], _ data: [[String]]? = nil) -> ShapeId {
    if ported("insert.table") {
        var p: JSON = ["rows": .integer(rows), "cols": .integer(cols), "rect": .array(rect.map { .double($0) })]
        if let data { p.set("data", .array(data.map { .array($0.map(JSON.string)) })) }
        return ShapeId(s.run("insert.table", p.display).get("id")?.asU32 ?? 0)
    }
    var t = Table(rows: rows, cols: cols, width: rect[2], rowHeight: rect[3] / Double(rows))
    for (r, row) in (data ?? []).enumerated() {
        for (c, text) in row.enumerated() { t.mutateCell(r, c) { $0.text = .fromText(text) } }
    }
    var id = ShapeId(0)
    do {
        try s.edit { doc, sel in
            id = ShapeId(doc.allocId() ?? 0)
            var sh = Shape.default
            sh.id = id
            sh.name = "Table \(id.rawValue)"
            sh.xfrm = Xfrm(rect[0], rect[1], rect[2], rect[3])
            sh.kind = .table(t)
            mutateShapes(&doc, sel) { $0.append(sh) }
            sel.shapes = [id]
            sel.text = nil
        }
    } catch {
        Issue.record("insertTable: \(error)")
    }
    return id
}

/// A table at (100, 100): columns `cols` wide, rows 40 pt tall, cells holding `data` (tests.rs `table_at`).
private func tableAt(_ s: Session, _ cols: [Double], _ data: [[String]]) -> ShapeId {
    let id = insertTable(s, data.count, cols.count, [100, 100, cols.reduce(0, +), 40.0 * Double(data.count)], data)
    for (c, w) in cols.enumerated() { s.run("table.columnWidth", "{\"id\": \(id.rawValue), \"col\": \(c), \"width\": \(w)}") }
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
private func textPoint(_ st: DocState, _ t: TextSel, _ para: Int, _ ch: Int) -> Point? {
    guard let (l, m) = TextCommands.textFrame(st, t), let c = l.caret(CaretPos(para: para, ch: ch)) else { return nil }
    return m * Point(c.x, (c.top + c.bottom) / 2.0)
}

private func caretPoint(_ s: Session, _ para: Int, _ ch: Int) -> Point? {
    guard let t = textSel(s) else { return nil }
    return textPoint(s.st, t, para, ch)
}

private func cells(_ s: Session) -> CellRange? { s.activeDoc?.selection.cells }

// MARK: - drawtable.rs

@Suite("Draw Table")
struct DrawTableTests {
    /// drawtable.rs tests `grid`.
    private func grid(_ t: Table) -> String {
        t.rows.map { r in r.cells.map { c in c.isCovered ? "." : (c.gridSpan > 1 || c.rowSpan > 1 ? "M" : "o") }.joined() }.joined(separator: "/")
    }

    /// drawtable.rs `pencil_splits_only_the_cells_it_crosses`.
    @Test func pencilSplitsOnlyTheCellsItCrosses() {
        var t = Table(rows: 1, cols: 1, width: 300, rowHeight: 100)
        #expect(DrawTable.drawLine(&t, (0, 40), (300, 40)), "full-width line adds a row")
        #expect(grid(t) == "o/o" && t.rows[0].height == 40 && t.rows[1].height == 60)
        #expect(DrawTable.drawLine(&t, (120, 40), (120, 100)), "a vertical line in the bottom row only")
        #expect(grid(t) == "M./oo")
        #expect(t.cols == [120, 180])
        #expect(DrawTable.drawLine(&t, (120, 0), (120, 40)), "on the existing grid line: splits the merged top cell")
        #expect(grid(t) == "oo/oo")
        #expect(!DrawTable.drawLine(&t, (0, 1), (300, 1)), "on the outer border")
        #expect(!DrawTable.drawLine(&t, (.nan, 1), (300, 1)))
        #expect(t.width == 300)
        #expect(t.height == 100)
    }

    /// drawtable.rs `eraser_merges_neighbours_and_keeps_text`.
    @Test func eraserMergesNeighboursAndKeepsText() {
        var t = Table(rows: 2, cols: 2, width: 200, rowHeight: 50)
        t.rows[0].cells[0].text = Cell("A").text
        t.rows[0].cells[1].text = Cell("B").text
        #expect(DrawTable.eraseAt(&t, (100, 25), 5), "the vertical border in row 0")
        #expect(grid(t) == "M./oo")
        #expect(t.cell(0, 0)?.text.paragraphs.count == 2)
        #expect(!DrawTable.eraseAt(&t, (50, 75), 5), "nowhere near a border")
        var u = Table(rows: 2, cols: 2, width: 200, rowHeight: 50)
        _ = u.merge(0, 0, 0, 1)
        #expect(!DrawTable.eraseAt(&u, (50, 50), 3), "the merged top cell and one bottom cell aren't a rectangle")
        #expect(DrawTable.eraseAt(&u, (100, 75), 3))
        #expect(DrawTable.eraseAt(&u, (50, 50), 3))
        #expect(grid(u) == "M./..")
    }

    /// drawtable.rs `grid_is_capped`.
    @Test func gridIsCapped() {
        var t = Table(rows: 1, cols: 1, width: 300, rowHeight: 4000)
        var n = 0
        for i in 1 ..< 400 where DrawTable.drawLine(&t, (0, Double(i) * 9.9), (300, Double(i) * 9.9)) { n += 1 }
        #expect(t.rows.count <= DrawTable.maxGrid && n > 100, "\(t.rows.count) rows")
    }
}

// MARK: - tests.rs

@Suite("Table commands")
struct TableCommandTests {
    /// tests.rs `grown_table_frame_covers_its_drawn_rows` (without its hit test: `hit_test` is tools.rs).
    @Test func grownTableFrameCoversItsDrawnRows() throws {
        let s = session()
        let id = insertTable(s, 3, 2, [100, 100, 400, 120], [["a", "b"], ["c", "d"], ["e", "f"]])
        for row in 0 ..< 3 { s.run("table.rowHeight", "{\"id\": \(id.rawValue), \"row\": \(row), \"height\": 4.0}") }
        let st = s.st
        let sh = try #require(st.shape(id))
        let t = tableOf(s, id)
        let drawn = Cmd.tableDrawnHeights(st.doc, st.selection, t).reduce(0, +)
        #expect(drawn > 12, "rows should grow: \(drawn)")
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        #expect(abs(x.h - drawn) < 1e-6, "frame \(x.h) vs drawn \(drawn)")
    }

    /// tests.rs `cell_text_is_laid_out_where_the_cell_draws_it`.
    @Test func cellTextIsLaidOutWhereTheCellDrawsIt() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["Hello world", "b"], ["c", ""]])
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [0, 1], \"at\": [0, 0]}")
        let c = try #require(caretPoint(s, 0, 0))
        #expect(c.x > 300 && c.x < 320 && c.y > 100 && c.y < 140, "caret of cell (0, 1) at \(c)")
        // An empty cell still has a caret.
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [1, 1]}")
        let e = try #require(caretPoint(s, 0, 0))
        #expect(e.x > 300 && e.y > 140 && e.y < 180, "caret of empty cell (1, 1) at \(e)")
        // Hit testing: the start and the end of "Hello world".
        let t = TextSel(shape: id, cell: TextPoint(0, 0))
        #expect(TextCommands.textPosAt(s.st, t, Point(101, 115)) == (0, 0))
        #expect(TextCommands.textPosAt(s.st, t, Point(295, 115)) == (0, 11))
    }

    /// tests.rs `editing_a_cell_ends_the_selected_cell_range`.
    @Test func editingACellEndsTheSelectedCellRange() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [0, 0], \"to\": [0, 1]}")
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [1, 1]}")
        #expect(cells(s) == nil)
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [0, 0], \"to\": [0, 1]}")
        s.run("text.edit", #"{"notes": true}"#)
        s.run("text.exit")
        #expect(cells(s) == nil)
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [1, 1]}")
        s.run("text.exit")
        s.run("edit.delete")
        #expect(s.st.shape(id) == nil, "the table is deleted")
    }

    /// tests.rs `dragging_across_cells_selects_a_range_of_cells`, with the range made by `table.selectCells`
    /// where the Rust test drags the pointer (tools.rs); the keys, formatting, Delete and Cut are as there.
    @Test func draggingAcrossCellsSelectsARangeOfCells() {
        let s = session()
        let id = tableAt(s, [100, 100, 100], [["a", "b", "c"], ["d", "e", "f"], ["g", "h", "i"]])
        func range(_ a: (Int, Int), _ b: (Int, Int)) -> CellRange { CellRange(id, TextPoint(a.0, a.1), TextPoint(b.0, b.1)) }
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [0, 0], \"to\": [2, 1]}")
        #expect(cells(s) == range((0, 0), (2, 1)))
        #expect(s.st.selection.shapes == [id] && textSel(s) == nil)
        // Shift+arrow moves the range's far corner.
        let shift = Mods(shift: true)
        _ = try? s.key("ArrowRight", shift)
        #expect(cells(s) == range((0, 0), (2, 2)))
        _ = try? s.key("ArrowUp", shift)
        #expect(cells(s) == range((0, 0), (1, 2)))
        let x = s.st.shape(id)?.xfrm
        #expect(x?.x == 100 && x?.y == 100, "Shift+arrow doesn't move the table")
        // Formatting applies to the selected cells only.
        s.run("format.bold")
        s.run("format.alignCenter")
        var t = tableOf(s, id)
        func bold(_ t: Table, _ r: Int, _ c: Int) -> Bool { t.cell(r, c)?.text.paragraphs.first?.runs.first?.props.bold == true }
        #expect(bold(t, 0, 0) && bold(t, 1, 2) && !bold(t, 2, 0) && !bold(t, 2, 2))
        func centered(_ r: Int, _ c: Int) -> Bool { t.cell(r, c)?.text.paragraphs.first?.props.align != nil }
        #expect(centered(1, 1) && !centered(2, 1))
        // Delete clears their text and keeps the table and the other cells.
        _ = try? s.key("Delete", Mods())
        t = tableOf(s, id)
        let texts = (0 ..< 3).flatMap { r in (0 ..< 3).map { c in t.cell(r, c)?.text.text ?? "?" } }
        #expect(texts == ["", "", "", "", "", "", "g", "h", "i"])
        s.run("edit.undo")
        #expect(tableOf(s, id).cell(0, 0)?.text.text == "a")
        // Cut puts the cells' text on the clipboard, a tab between cells and a line per row, and clears them.
        let r = s.run("edit.cut")
        #expect(r.get("text") == "a\tb\tc\nd\te\tf")
        #expect(s.clipboard.shapes.isEmpty)
        #expect(s.clipboard.text?.paragraphs.count == 2)
        #expect(tableOf(s, id).cell(1, 1)?.text.text == "")
        #expect(tableOf(s, id).cell(2, 1)?.text.text == "h")
        s.run("edit.undo")
        // A range that reaches into a merged cell takes all of it.
        s.run("table.merge", "{\"id\": \(id.rawValue), \"from\": [0, 1], \"to\": [0, 2]}")
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [1, 0], \"to\": [0, 1]}")
        #expect(cells(s) == range((1, 0), (0, 1)))
        func selected() -> ((Int, Int), (Int, Int))? { TableCommands.selectedRange(cells(s), id, tableOf(s, id)) }
        #expect(selected().map { $0.0 == (0, 0) && $0.1 == (1, 2) } == true)
        // Shift+arrow keeps the cell the range started from.
        _ = try? s.key("ArrowDown", shift)
        #expect(selected().map { $0.0 == (1, 0) && $0.1 == (1, 1) } == true)
        // Cut of a cell a merge covers takes the whole merged cell, and clears what it copied.
        let merged = tableOf(s, id).cell(0, 1)?.text.text ?? ""
        #expect(!merged.isEmpty)
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [0, 2], \"to\": [0, 2]}")
        #expect(s.run("edit.cut").get("text")?.asStr == merged)
        #expect(tableOf(s, id).cell(0, 1)?.text.text == "")
        // Delete naming a shape deletes that shape, cells selected or not.
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [1, 1], \"to\": [2, 2]}")
        s.run("edit.delete", "{\"id\": \(id.rawValue)}")
        #expect(s.st.shape(id) == nil)
        // A span past the table's edge (from a file) stops at the edge.
        var big = Table(rows: 3, cols: 3, width: 300, rowHeight: 40)
        big.rows[0].cells[0].rowSpan = .max
        big.rows[0].cells[0].gridSpan = .max
        let b = TableCommands.cellBlock(big, (1, 1), (2, 2))
        #expect(b.0 == (0, 0) && b.1 == (2, 2))
    }

    /// Shift+arrow without a cell range of the selected table isn't a cell command: it nudges the selection
    /// as before (keys.rs; `extend_selected_cells` answers false).
    @Test func shiftArrowWithoutACellRangeDoesNotExtendCells() throws {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        s.run("edit.select", "{\"ids\": [\(id.rawValue)]}")
        #expect(try !TableCommands.extendSelectedCells(s, 0, 1))
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [1, 1], \"to\": [1, 1]}")
        // At the table's edge the range stays.
        #expect(try TableCommands.extendSelectedCells(s, 1, 1))
        #expect(cells(s) == CellRange(id, TextPoint(1, 1), TextPoint(1, 1)))
        #expect(try TableCommands.extendSelectedCells(s, -1, -1))
        #expect(cells(s) == CellRange(id, TextPoint(1, 1), TextPoint(0, 0)))
        #expect(TableCommands.selectedCellsText(s.st) == "a\tb\nc\td")
    }

    /// tests.rs `caret_moves_by_line_in_a_wrapped_cell`.
    @Test func caretMovesByLineInAWrappedCell() throws {
        let s = session()
        let id = tableAt(s, [90, 200], [["one two three four five six seven", "b"]])
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [0, 0], \"at\": [0, 0]}")
        s.run("text.move", #"{"to": "down"}"#)
        let down = try #require(textSel(s)).caret
        #expect(down.para == 0 && down.char > 0, "down goes to the next line of the paragraph: \(down)")
        s.run("text.move", #"{"to": "lineEnd"}"#)
        let end = try #require(textSel(s)).caret
        #expect(end.char > down.char && end.char < 33, "end of the second line: \(end)")
        s.run("text.move", #"{"to": "up"}"#)
        #expect((textSel(s)?.caret.char ?? .max) < down.char)
    }

    /// tests.rs `table_borders_are_hit_where_they_are_drawn`, through `TableFrame.borderAt`, which the
    /// pointer's hit test calls (the hover and the plain-shape hits are tools.rs).
    @Test func tableBordersAreHitWhereTheyAreDrawn() throws {
        let s = session()
        let id = tableAt(s, [100, 100, 100], [["a", "b", "c"], ["d", "e", "f"]])
        func hit(_ x: Double, _ y: Double) throws -> TableFrame.Border? {
            let st = s.st
            let sh = try #require(st.shape(id))
            let f = try #require(TableCommands.tableFrame(st, sh))
            return f.borderAt(f.local(Point(x, y)), 3)
        }
        #expect(try hit(201, 125) == .column(0))
        #expect(try hit(400, 125) == .column(2), "the right edge")
        #expect(try hit(150, 139) == .row(0))
        #expect(try hit(150, 181) == .row(1), "the bottom edge")
        #expect(try hit(150, 125) == nil)
        // A border inside a merged cell isn't there.
        s.run("table.merge", "{\"id\": \(id.rawValue), \"from\": [0, 0], \"to\": [0, 1]}")
        #expect(try hit(200, 120) == nil)
        #expect(try hit(200, 160) == .column(0))
    }

    /// tests.rs `column_width_can_keep_the_table_width`.
    @Test func columnWidthCanKeepTheTableWidth() {
        let s = session()
        let id = tableAt(s, [100, 100, 100], [["a", "b", "c"]])
        s.run("table.columnWidth", "{\"id\": \(id.rawValue), \"col\": 1, \"width\": 150.0, \"keepTotal\": true}")
        #expect(tableOf(s, id).cols == [100, 150, 50])
        s.run("table.columnWidth", "{\"id\": \(id.rawValue), \"col\": 1, \"width\": 1000.0, \"keepTotal\": true}")
        #expect(tableOf(s, id).cols == [100, 200 - TableCommands.minColumnWidth, TableCommands.minColumnWidth])
        // The last column has no neighbour: the table changes width.
        s.run("table.columnWidth", "{\"id\": \(id.rawValue), \"col\": 2, \"width\": 80.0, \"keepTotal\": true}")
        #expect(s.st.shape(id)?.xfrm?.w == 100 + (200 - TableCommands.minColumnWidth) + 80)
    }

    /// tests.rs `rotated_tables_hit_the_cell_under_the_pointer`, through `TableFrame.cellAt` (the double
    /// click is tools.rs).
    @Test(.enabled(if: ported("shape.rotate"))) func rotatedTablesHitTheCellUnderThePointer() throws {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        s.run("shape.rotate", "{\"ids\": [\(id.rawValue)], \"deg\": 90}")
        let st = s.st
        let sh = try #require(st.shape(id))
        let f = try #require(TableCommands.tableFrame(st, sh))
        let p = f.affine * Point(150, 60)
        #expect(f.cellAt(f.local(p)).map { $0 == (1, 1) } == true)
    }

    /// tests.rs `tab_moves_between_cells_skipping_merged_ones`.
    @Test func tabMovesBetweenCellsSkippingMergedOnes() throws {
        let s = session()
        let id = tableAt(s, [100, 100, 100], [["a", "b", "c"], ["d", "e", "f"]])
        s.run("table.merge", "{\"id\": \(id.rawValue), \"from\": [0, 0], \"to\": [0, 1]}")
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [0, 0]}")
        let shift = Mods(shift: true)
        _ = try s.key("Tab", Mods())
        #expect(textSel(s)?.cell == TextPoint(0, 2), "the cell under the merge is skipped")
        _ = try s.key("Tab", shift)
        #expect(textSel(s)?.cell == TextPoint(0, 0))
        _ = try s.key("Tab", shift)
        #expect(textSel(s)?.cell == TextPoint(0, 0), "Shift+Tab in the first cell stays")
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [1, 2]}")
        _ = try s.key("Tab", Mods())
        #expect(textSel(s)?.cell == TextPoint(2, 0) && tableOf(s, id).nRows == 3, "Tab in the last cell adds a row")
    }

    /// tests.rs `cell_fill_walks_only_the_cells_a_huge_selection_covers`.
    @Test func cellFillWalksOnlyTheCellsAHugeSelectionCovers() {
        let s = session()
        let id = insertTable(s, 2, 2, [100, 100, 200, 40])
        s.run("table.selectCells", "{\"id\": \(id.rawValue), \"from\": [1, 1], \"to\": [1000000000, 1000000000]}")
        s.run("table.cellFill", #"{"none": true}"#)
        let t = tableOf(s, id)
        let fills = [(0, 0), (0, 1), (1, 0), (1, 1)].map { t.cell($0.0, $0.1)?.fill != nil }
        #expect(fills == [false, false, false, true])
    }

    /// tests.rs `table_borders_margins_and_cell_alignment`.
    @Test func tableBordersMarginsAndCellAlignment() throws {
        let s = session()
        let id = insertTable(s, 3, 3, [100, 100, 300, 120]).rawValue
        // Outside borders round the top-left 2×2 block; neighbours get the facing side too.
        let block = "[[0, 0], [0, 1], [1, 0], [1, 1]]"
        s.run("table.borders", "{\"id\": \(id), \"which\": \"outside\", \"cells\": \(block), \"color\": \"#FF0000\", \"width\": 2.0, \"dash\": \"dash\"}")
        var t = tableOf(s, ShapeId(id))
        func w(_ r: Int, _ c: Int, _ side: Int) -> Double? { t.rows[r].cells[c].borders[side]?.width }
        #expect(w(0, 0, 0) == 2.0)
        #expect(w(0, 0, 2) == 2.0)
        #expect(w(0, 0, 1) == nil, "inside edge untouched")
        #expect(w(1, 1, 1) == 2.0)
        #expect(w(1, 2, 0) == 2.0, "neighbour's facing side")
        #expect(w(2, 1, 2) == 2.0, "neighbour below")
        #expect(t.rows[0].cells[0].borders[0]?.dash == .preset(name: "dash"))
        // Inside horizontal only for the block.
        s.run("table.borders", "{\"id\": \(id), \"which\": \"insideH\", \"cells\": \(block)}")
        t = tableOf(s, ShapeId(id))
        #expect(t.rows[0].cells[0].borders[3] != nil && t.rows[1].cells[0].borders[2] != nil)
        #expect(t.rows[0].cells[0].borders[1] == nil)
        // Diagonal and none.
        s.run("table.borders", "{\"id\": \(id), \"which\": \"diagDown\", \"cells\": [[2, 2]]}")
        #expect(tableOf(s, ShapeId(id)).rows[2].cells[2].diagDown != nil)
        s.run("table.borders", "{\"id\": \(id), \"which\": \"none\"}")
        t = tableOf(s, ShapeId(id))
        #expect(t.rows.flatMap(\.cells).allSatisfy { c in c.diagDown == nil && c.borders.allSatisfy { $0?.fill == Fill.none_ } })
        #expect(s.fails("table.borders", "{\"id\": \(id), \"which\": \"sideways\"}"))
        // Margins and vertical alignment.
        s.run("table.cellMargins", "{\"id\": \(id), \"preset\": \"wide\", \"cells\": [[0, 0]]}")
        s.run("table.cellMargins", "{\"id\": \(id), \"preset\": \"none\", \"left\": 5.0, \"cells\": [[0, 1]]}")
        s.run("table.cellAlign", "{\"id\": \(id), \"anchor\": \"middle\"}")
        t = tableOf(s, ShapeId(id))
        #expect(t.rows[0].cells[0].margins == [14.4, 14.4, 14.4, 14.4])
        #expect(t.rows[0].cells[1].margins == [5.0, 0.0, 0.0, 0.0])
        #expect(t.rows.flatMap(\.cells).allSatisfy { $0.anchor == .middle })
        // Survives PPTX.
        let back = try PPTX.importChecked(PPTX.export(s.st.doc)).0
        let bt = try #require(back.slides.flatMap(\.shapes).lazy.compactMap { sh -> Table? in
            if case .table(let t) = sh.kind { return t }
            return nil
        }.first)
        #expect(bt.rows[0].cells[0].margins == [14.4, 14.4, 14.4, 14.4])
        #expect(bt.rows[1].cells[1].anchor == .middle)
        // One undo step each.
        s.run("edit.undo")
        #expect(tableOf(s, ShapeId(id)).rows[0].cells[0].anchor == nil)
    }

    /// tests.rs `table_insert_below_or_right_of_a_huge_index_appends_at_the_end`.
    @Test func tableInsertBelowOrRightOfAHugeIndexAppendsAtTheEnd() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        s.run("table.insertRowBelow", "{\"id\": \(id.rawValue), \"row\": \(UInt64.max)}")
        var t = tableOf(s, id)
        #expect(t.nRows == 3)
        #expect(t.cell(0, 0)?.text.text == "a", "the original rows keep their place")
        s.run("table.insertColumnRight", "{\"id\": \(id.rawValue), \"col\": \(UInt64.max)}")
        t = tableOf(s, id)
        #expect(t.nCols == 3)
        #expect(t.cell(0, 1)?.text.text == "b", "the original columns keep their place")
    }

    /// tests.rs `table_row_col_commands_reject_an_invalid_index`.
    @Test func tableRowColCommandsRejectAnInvalidIndex() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"], ["e", "f"]])
        for (cmd, key) in [("table.deleteRow", "row"), ("table.deleteColumn", "col"), ("table.insertRowAbove", "row"), ("table.insertColumnLeft", "col"), ("table.split", "row")] {
            for bad in ["-1", "1.5", "\"1\""] {
                #expect(s.fails(cmd, "{\"id\": \(id.rawValue), \"\(key)\": \(bad)}"), "\(cmd) \(key)=\(bad) should be rejected")
                let t = tableOf(s, id)
                #expect(t.nRows == 3 && t.nCols == 2, "\(cmd) \(key)=\(bad) must leave the table unchanged")
            }
        }
    }

    /// tests.rs `table_cell_commands_reject_an_invalid_cell_and_name_the_registered_command`.
    @Test func tableCellCommandsRejectAnInvalidCellAndNameTheRegisteredCommand() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"], ["e", "f"]]).rawValue
        s.run("table.selectCells", "{\"id\": \(id), \"from\": [0, 0], \"to\": [1, 1]}")
        for (cmd, params) in [
            ("table.split", "{\"id\": \(id), \"cell\": [-1, 0]}"),
            ("table.merge", "{\"id\": \(id), \"from\": [-1, 0], \"to\": [1, 1]}"),
            ("table.merge", "{\"id\": \(id), \"from\": [0, 0], \"to\": \"x\"}"),
            ("table.rowHeight", "{\"id\": \(id), \"row\": -1, \"height\": 50.0}"),
            ("table.rowHeight", "{\"id\": \(id), \"row\": 1.5, \"height\": 50.0}"),
            ("table.columnWidth", "{\"id\": \(id), \"col\": -1, \"width\": 50.0}"),
            ("table.columnWidth", "{\"id\": \(id), \"col\": \"1\", \"width\": 50.0, \"keepTotal\": true}"),
        ] {
            let before = tableOf(s, ShapeId(id))
            #expect(s.fails(cmd, params), "\(cmd) \(params) should be rejected")
            let t = tableOf(s, ShapeId(id))
            #expect(t.nRows == 3 && t.nCols == 2, "\(cmd) \(params) must leave the table unchanged")
            #expect(t.rows.map(\.height) == before.rows.map(\.height), "\(cmd) \(params) must not change row heights")
            #expect(t.cols == before.cols, "\(cmd) \(params) must not change column widths")
        }
        do {
            _ = try s.execute("table.deleteRow", j("{\"id\": \(id), \"row\": -1}"))
            Issue.record("table.deleteRow with row -1 succeeded")
        } catch {
            #expect("\(error)".contains("table.deleteRow"), "error should name the registered command: \(error)")
        }
        do {
            _ = try s.execute("table.insertColumnLeft", j("{\"id\": \(id), \"col\": -1}"))
            Issue.record("table.insertColumnLeft with col -1 succeeded")
        } catch {
            #expect("\(error)".contains("table.insertColumnLeft"), "error should name the registered command: \(error)")
        }
    }

    /// tests.rs `table_column_width_of_a_huge_column_is_ignored`.
    @Test func tableColumnWidthOfAHugeColumnIsIgnored() {
        let s = session()
        let id = tableAt(s, [100, 100], [["a", "b"], ["c", "d"]])
        for keepTotal in [true, false] {
            s.run("table.columnWidth", "{\"id\": \(id.rawValue), \"col\": \(UInt64.max), \"width\": 50.0, \"keepTotal\": \(keepTotal)}")
            #expect(tableOf(s, id).cols == [100, 100], "no column changes")
        }
    }

    /// tests.rs `tables_with_a_file_defined_style_edit_and_resize`, up to its clicks and border drag (tools.rs):
    /// the header is laid out in the file style's weight.
    @Test func tablesWithAFileDefinedStyleEditAndResize() throws {
        let s = session()
        let id = tableAt(s, [200, 200], [["Hello world", "b"], ["c", "d"]])
        let regular = FontDB.shared.face("BIZ UDPGothic", "Regular")
        let bold = FontDB.shared.face("BIZ UDPGothic", "Bold")
        let metricPair = regular.family == "BIZ UDPGothic" && bold.family == "BIZ UDPGothic" && regular.style == "Regular" && bold.style == "Bold"
            && regular.weight < bold.weight
        if metricPair {
            let st = s.st
            var d = st.doc
            withShape(&d.slides[0].shapes, id) { sh in
                guard case .table(var t) = sh.kind else { return }
                for c in t.rows[0].cells.indices {
                    for p in t.rows[0].cells[c].text.paragraphs.indices {
                        for r in t.rows[0].cells[c].text.paragraphs[p].runs.indices {
                            t.rows[0].cells[c].text.paragraphs[p].runs[r].props.font = "BIZ UDPGothic"
                            t.rows[0].cells[c].text.paragraphs[p].runs[r].props.bold = nil
                        }
                    }
                }
                sh.kind = .table(t)
            }
            st.docRef = DocRef(d)
        }
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [0, 0]}")
        let builtIn = try #require(caretPoint(s, 0, 8))
        s.run("text.exit")
        // The table's style, defined by the file: a plain (not bold) header, a filled body, a background.
        let style = tableOf(s, id).style
        let st = s.st
        var d = st.doc
        func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Fill { .solid(ColorRef.rgb(Rgba.rgb(r, g, b))) }
        var whole = TablePartStyle()
        whole.fill = solid(230, 240, 250)
        var first = TablePartStyle()
        first.fill = solid(40, 60, 90)
        first.bold = false
        var background = TablePartStyle()
        background.fill = solid(200, 200, 200)
        d.tableStyles.append(TableStyleDef(id: style, name: "File style", parts: [Pair(.wholeTbl, whole), Pair(.firstRow, first)], background: background, raw: ""))
        st.docRef = DocRef(d)
        s.run("edit.deselect")
        s.run("text.edit", "{\"id\": \(id.rawValue), \"cell\": [0, 0]}")
        let p = try #require(caretPoint(s, 0, 8))
        if metricPair {
            #expect(abs(p.x - builtIn.x) > 0.5, "the header is laid out in the file style's (regular) weight: \(p) vs \(builtIn)")
        }
        s.run("text.exit")
    }
}
