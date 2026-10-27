// DCEngine — the `table` command module: the Table Design and Table Layout tabs, Draw Table, and the
// selected cell range (copy, delete and Shift+arrow over cells).
// Port of deckcraft crates/engine/src/cmd/table.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum TableCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("table.insertRowAbove", "Insert Above", ["Table Layout", "Rows & Columns"], nil, "{row?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "rowAbove", "table.insertRowAbove")
            },
            .cmd("table.insertRowBelow", "Insert Below", ["Table Layout", "Rows & Columns"], nil, "{row?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "rowBelow", "table.insertRowBelow")
            },
            .cmd("table.insertColumnLeft", "Insert Left", ["Table Layout", "Rows & Columns"], nil, "{col?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "colLeft", "table.insertColumnLeft")
            },
            .cmd("table.insertColumnRight", "Insert Right", ["Table Layout", "Rows & Columns"], nil, "{col?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "colRight", "table.insertColumnRight")
            },
            .cmd("table.deleteRow", "Delete Rows", ["Table Layout", "Rows & Columns"], nil, "{row?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "delRow", "table.deleteRow")
            },
            .cmd("table.deleteColumn", "Delete Columns", ["Table Layout", "Rows & Columns"], nil, "{col?, id?}", Cmd.hasSelection) { s, p in
                try rowsCols(s, p, "delCol", "table.deleteColumn")
            },
            .cmd("table.merge", "Merge Cells", ["Table Layout", "Merge"], nil, "{from: [r, c], to: [r, c], id?}", Cmd.hasSelection, merge),
            .cmd(
                "table.split",
                "Split Cells",
                ["Table Layout", "Merge"],
                nil,
                "{cell?: [r, c] (else the edited cell), id?} | {row?: index, col?: index, id?}",
                Cmd.hasSelection,
                split
            ),
            .cmd(
                "table.style",
                "Table Styles",
                ["Table Design", "Table Styles"],
                nil,
                "{style: medium2-accent1|light1-accent2|dark1-tx1|grid|none…, id?}",
                Cmd.hasSelection,
                style
            ),
            .cmd(
                "table.options",
                "Table Style Options",
                ["Table Design", "Table Style Options"],
                nil,
                "{headerRow?: bool, totalRow?: bool, bandedRows?: bool, firstColumn?: bool, lastColumn?: bool, bandedColumns?: bool, id?}",
                Cmd.hasSelection,
                options
            ),
            .cmd(
                "table.cellFill",
                "Shading",
                ["Table Design", "Table Styles"],
                nil,
                "{color? | none?, cells?: [[r,c],…] (default: selected cells or all), id?}",
                Cmd.hasSelection,
                cellFill
            ),
            .cmd(
                "table.borders",
                "Borders",
                ["Table Design", "Draw Borders"],
                nil,
                "{which: all|outside|inside|insideH|insideV|top|bottom|left|right|diagDown|diagUp|none, color?, width?: pt, dash?: solid|dash|dot…, cells?: [[r,c],…] (default: selected cells or all), id?}",
                Cmd.hasSelection,
                borders
            ),
            .cmd(
                "table.cellMargins",
                "Cell Margins",
                ["Table Layout", "Alignment"],
                nil,
                "{preset?: normal|none|narrow|wide, left?, right?, top?, bottom?: pt, cells?, id?}",
                Cmd.hasSelection,
                cellMargins
            ),
            .cmd(
                "table.cellAlign",
                "Align Cell Text",
                ["Table Layout", "Alignment"],
                nil,
                "{anchor: top|middle|bottom, cells?, id?}",
                Cmd.hasSelection,
                cellAlign
            ),
            .cmd("table.distributeRows", "Distribute Rows", ["Table Layout", "Cell Size"], nil, "{id?}", Cmd.hasSelection) { s, p in try distribute(s, p, true) },
            .cmd("table.distributeColumns", "Distribute Columns", ["Table Layout", "Cell Size"], nil, "{id?}", Cmd.hasSelection) { s, p in
                try distribute(s, p, false)
            },
            .cmd(
                "table.columnWidth",
                "Width",
                ["Table Layout", "Cell Size"],
                nil,
                "{col, width: pt, keepTotal?: bool (the next column absorbs the change), id?}",
                Cmd.hasSelection,
                columnWidth
            ),
            .cmd("table.rowHeight", "Height", ["Table Layout", "Cell Size"], nil, "{row, height: pt, id?}", Cmd.hasSelection, rowHeight),
            .cmd(
                "table.drawLine",
                "Draw Table",
                ["Table Design", "Draw Borders"],
                nil,
                "{from: [x, y], to: [x, y] slide pt, id?: table (default: the one under `from`)} splits the cells the line crosses",
                Cmd.hasSlide,
                drawLine
            ),
            .cmd(
                "table.eraseLine",
                "Table Eraser",
                ["Table Design", "Draw Borders"],
                nil,
                "{at: [x, y] slide pt, id?, tol?: pt (default 6)} merges the two cells on either side of the nearest border",
                Cmd.hasSlide,
                eraseLine
            ),
            .noundo("table.selectCells", "Select Cells", [], nil, "{from: [r,c], to: [r,c], id?}", Cmd.hasSelection, selectCells),
        ]
    }

    /// Narrowest a column gets when its border is dragged (points).
    public static let minColumnWidth = 12.0
}

// MARK: - The drawn table (for the canvas)

/// A table as drawn on the slide: where it is, its drawn row heights and its visible cells.
public struct TableFrame: Sendable {
    /// Table-local (points from the table's top-left corner) → slide space, as the table is drawn.
    public var affine: Affine
    public var cols: [Double]
    /// Row heights as drawn: a stored height is a minimum, rows grow to fit their text.
    public var heights: [Double]
    /// Visible cells (merges honoured): (row, col, table-local rect).
    public var cells: [(Int, Int, Rect)]

    public var width: Double { cols.reduce(0) { $0 + $1.rustMax(0) } }
    public var height: Double { heights.reduce(0) { $0 + $1.rustMax(0) } }

    /// Table-local point for slide point `p`.
    public func local(_ p: Point) -> Point { affine.inverse * p }

    /// Table-local rect of visible cell (`r`, `c`).
    public func cellRect(_ r: Int, _ c: Int) -> Rect? { cells.first { $0.0 == r && $0.1 == c }?.2 }

    /// The visible cell at table-local point `p` (points outside the table go to the nearest cell).
    public func cellAt(_ p: Point) -> (Int, Int)? {
        let q = Point(p.x.clamped(0, width.rustMax(0)), p.y.clamped(0, height.rustMax(0)))
        func inside(_ r: Rect) -> Bool { q.x >= r.x0 && q.x <= r.x1 && q.y >= r.y0 && q.y <= r.y1 }
        // Edges are shared: prefer the cell the point is strictly inside.
        let hit = cells.first { q.x >= $0.2.x0 && q.x < $0.2.x1 && q.y >= $0.2.y0 && q.y < $0.2.y1 } ?? cells.reversed().first { inside($0.2) }
        return hit.map { ($0.0, $0.1) }
    }

    /// The draggable border within `tol` of table-local point `p`.
    public func borderAt(_ p: Point, _ tol: Double) -> Border? {
        let (w, h) = (width, height)
        if !(p.x >= -tol && p.y >= -tol && p.x <= w + tol && p.y <= h + tol) { return nil }
        let q = Point(p.x.clamped(0, w), p.y.clamped(0, h))
        var best: (Double, Border)?
        var x = 0.0
        for (i, cw) in cols.enumerated() {
            x += cw.rustMax(0)
            let d = abs(p.x - x)
            let shown = cells.contains { abs($0.2.x1 - x) < 1e-6 && q.y >= $0.2.y0 && q.y <= $0.2.y1 }
            if d <= tol && shown && (best.map { d < $0.0 } ?? true) { best = (d, .column(i)) }
        }
        var y = 0.0
        for (i, rh) in heights.enumerated() {
            y += rh.rustMax(0)
            let d = abs(p.y - y)
            let shown = cells.contains { abs($0.2.y1 - y) < 1e-6 && q.x >= $0.2.x0 && q.x <= $0.2.x1 }
            if d <= tol && shown && (best.map { d < $0.0 } ?? true) { best = (d, .row(i)) }
        }
        return best?.1
    }
}

extension TableFrame {
    /// A border between table rows or columns that can be dragged (Rust's `TableBorder`; DCModel's
    /// `TableBorder` is a table style's border, so this one is nested).
    public enum Border: Sendable, Equatable {
        /// The right edge of this column (the last one is the table's right edge).
        case column(Int)
        /// The bottom edge of this row (the last one is the table's bottom edge).
        case row(Int)
    }
}

extension TableCommands {
    /// The drawn geometry of table shape `sh` on the edited slide (`table_frame`).
    public static func tableFrame(_ st: DocState, _ sh: Shape) -> TableFrame? {
        guard case .table(let t) = sh.kind else { return nil }
        // The table is drawn in its own box; rows that grow past it don't move it.
        let x = sh.xfrm ?? Cmd.xfrmOf(st.doc, st.selection, sh)
        let heights = Cmd.tableDrawnHeights(st.doc, st.selection, t)
        return TableFrame(affine: x.affine, cols: t.cols, heights: heights, cells: TableRender.cellRects(t, heights))
    }
}

// MARK: - Called by the core (cmd/edit.rs, keys.rs) and the text and format modules

extension TableCommands {
    /// The cell range from `a` to `b` in `t`, grown until every merged cell it touches lies inside it, as
    /// (the corner on `a`'s side, the corner on `b`'s side). Cells past the table's edge are clamped
    /// (`cell_block`).
    public static func cellBlock(_ t: Table, _ a: (Int, Int), _ b: (Int, Int)) -> ((Int, Int), (Int, Int)) {
        let (nr, nc) = (max(t.nRows, 1), max(t.nCols, 1))
        let a = (min(a.0, nr - 1), min(a.1, nc - 1))
        let b = (min(b.0, nr - 1), min(b.1, nc - 1))
        var (r0, r1, c0, c1) = (min(a.0, b.0), max(a.0, b.0), min(a.1, b.1), max(a.1, b.1))
        // Each pass takes in the merged cells that overlap the block; stop when one adds nothing.
        func end(_ at: Int, _ span: UInt32, _ n: Int) -> Int {
            let (v, o) = at.addingReportingOverflow(Int(max(span, 1) - 1))
            return min(o ? Int.max : v, n - 1)
        }
        for _ in 0 ..< (nr + nc) {
            var grown = false
            for (r, row) in t.rows.enumerated() {
                for (c, cell) in row.cells.enumerated() where !cell.isCovered {
                    let (er, ec) = (end(r, cell.rowSpan, nr), end(c, cell.gridSpan, nc))
                    let overlaps = r <= r1 && er >= r0 && c <= c1 && ec >= c0
                    if overlaps && (r < r0 || er > r1 || c < c0 || ec > c1) {
                        (r0, r1, c0, c1) = (min(r0, r), max(r1, er), min(c0, c), max(c1, ec))
                        grown = true
                    }
                }
            }
            if !grown { break }
        }
        func pick(_ lo: Int, _ hi: Int, _ first: Bool) -> Int { first ? lo : hi }
        let from = (pick(r0, r1, a.0 <= b.0), pick(c0, c1, a.1 <= b.1))
        let to = (pick(r0, r1, a.0 > b.0), pick(c0, c1, a.1 > b.1))
        return (from, to)
    }

    /// The selected cell range of table `id` (`t`), grown over merged cells, as its top-left and
    /// bottom-right cells. nil when no range of that table is selected (`selected_range`).
    public static func selectedRange(_ cells: CellRange?, _ id: ShapeId, _ t: Table) -> ((Int, Int), (Int, Int))? {
        guard let c = cells, c.table == id else { return nil }
        let (x, y) = cellBlock(t, c.from.tuple, c.to.tuple)
        return ((min(x.0, y.0), min(x.1, y.1)), (max(x.0, y.0), max(x.1, y.1)))
    }

    /// Whether cell (`r`, `c`) lies in `range` (from `selectedRange`); without a range every cell does
    /// (`in_range`).
    public static func inRange(_ range: ((Int, Int), (Int, Int))?, _ r: Int, _ c: Int) -> Bool {
        guard let ((r0, c0), (r1, c1)) = range else { return true }
        return r0 <= r && r <= r1 && c0 <= c && c <= c1
    }

    /// Shift+arrow with a cell range selected: the cell the range was extended to moves by (`dr`, `dc`),
    /// on past a merged cell until the range changes. false when no cell range of the selected table is
    /// selected (`extend_selected_cells`).
    static func extendSelectedCells(_ s: Session, _ dr: Int, _ dc: Int) throws -> Bool {
        let st = try s.doc()
        guard let cells = st.selection.cells, st.selection.shapes == [cells.table] else { return false }
        guard case .table(let t)? = st.shape(cells.table)?.kind else { return false }
        let (nr, nc) = (t.nRows, t.nCols)
        let from = cells.from.tuple
        let old = cellBlock(t, from, cells.to.tuple)
        var end = cells.to.tuple
        func same(_ x: ((Int, Int), (Int, Int)), _ y: ((Int, Int), (Int, Int))) -> Bool { x.0 == y.0 && x.1 == y.1 }
        while same(cellBlock(t, from, end), old) {
            let (r, o1) = end.0.addingReportingOverflow(dr)
            let (c, o2) = end.1.addingReportingOverflow(dc)
            guard !o1, !o2, r >= 0, r < nr, c >= 0, c < nc else { break }
            end = (r, c)
        }
        let id = cells.table
        let newEnd = TextPoint(end.0, end.1)
        try s.select { _, sel in sel.cells = CellRange(id, cells.from, newEnd) }
        return true
    }

    /// The text of the selected range of cells, for Copy and Cut: a tab between the cells of a row and a
    /// line per row (a merged cell once, where it starts). nil without a cell range of the selected table
    /// (`selected_cells_text`).
    static func selectedCellsText(_ st: DocState) -> String? {
        guard let cells = st.selection.cells, st.selection.shapes == [cells.table] else { return nil }
        guard case .table(let t)? = st.shape(cells.table)?.kind else { return nil }
        guard let ((r0, c0), (r1, c1)) = selectedRange(cells, cells.table, t) else { return nil }
        let rows = (r0 ... r1).map { r in
            (c0 ... c1).compactMap { c in t.cell(r, c).flatMap { $0.isCovered ? nil : $0.text.text } }.joined(separator: "\t")
        }
        return rows.joined(separator: "\n")
    }

    /// Delete with a cell range selected: the text in those cells goes and the cells stay, each keeping
    /// its first paragraph's formatting (`clear_selected_cells`).
    static func clearSelectedCells(_ s: Session) throws -> JSON {
        guard let cells = try s.doc().selection.cells else { return Cmd.ok() }
        let id = cells.table
        return try withTable(s, ["id": id.toJSON()], "edit.delete") { t in
            let range = selectedRange(cells, id, t)
            for r in t.rows.indices {
                for c in t.rows[r].cells.indices where inRange(range, r, c) {
                    TextEdit.delete(&t.rows[r].cells[c].text, (0, 0), (Int.max, Int.max))
                }
            }
        }
    }
}

// MARK: - Commands

extension TableCommands {
    /// A `[r, c]` cell param: nil when absent, an error when present but not a valid cell (`cell_param`).
    static func cellParam(_ p: JSON, _ key: String, _ cmd: String) throws -> (Int, Int)? {
        guard let v = p.get(key), !v.isNull else { return nil }
        guard let r = v.asArray?.at(0)?.asU64.flatMap({ Int(exactly: $0) }), let c = v.asArray?.at(1)?.asU64.flatMap({ Int(exactly: $0) }) else {
            throw Cmd.bad(cmd, "`\(key)` is not a valid cell: \(v.display)")
        }
        return (r, c)
    }

    /// The table's row and column to act on: params, the edited cell, or the selected cells (`at`).
    private static func at(_ s: Session, _ p: JSON, _ cmd: String) throws -> (Int, Int) {
        let st = s.activeDoc
        let cell = st?.selection.text?.cell ?? st?.selection.cells?.from
        return (try Cmd.optUsizeParam(p, "row", cmd) ?? cell?.para ?? 0, try Cmd.optUsizeParam(p, "col", cmd) ?? cell?.char ?? 0)
    }

    /// Run `f` on the table named by `id`, the edited cell's table, the selected cells' table or the
    /// selected shape, then keep its box and the edited cell in step (`with_table`).
    @discardableResult
    static func withTable(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Table) throws -> Void) throws -> JSON {
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", cmd) {
            id = i
        } else {
            let st = try s.doc()
            let edited = st.selection.text.flatMap { $0.cell != nil ? $0.shape : nil }
            guard let found = edited ?? st.selection.cells?.table ?? st.selection.shapes.first else { throw Cmd.bad(cmd, "select a table") }
            id = found
        }
        let r = try Cmd.editShapes(s, ["id": id.toJSON()], cmd) { sh in
            guard case .table(var t) = sh.kind else { throw Cmd.bad(cmd, "not a table") }
            try f(&t)
            t.normalize()
            let (w, h) = (t.width, t.height)
            sh.kind = .table(t)
            if sh.xfrm != nil {
                sh.xfrm?.w = w
                sh.xfrm?.h = h
            }
        }
        // The edited cell may have moved out of range.
        try s.select { doc, sel in
            let dims: (Int, Int)? = Cmd.currentShapes(doc, sel).flatMap { findShape($0, id) }.flatMap { x in
                if case .table(let t) = x.kind { return (t.nRows, t.nCols) }
                return nil
            }
            if let (nr, nc) = dims, let cell = sel.text?.cell, cell.para >= nr || cell.char >= nc {
                sel.text?.cell = TextPoint(min(cell.para, max(nr - 1, 0)), min(cell.char, max(nc - 1, 0)))
                sel.text?.anchor = TextPoint(0, 0)
                sel.text?.caret = TextPoint(0, 0)
            }
        }
        return r
    }

    private static func rowsCols(_ s: Session, _ p: JSON, _ op: String, _ name: String) throws -> JSON {
        let (r, c) = try at(s, p, name)
        func plusOne(_ v: Int) -> Int { v == Int.max ? v : v + 1 }
        return try withTable(s, p, name) { t in
            switch op {
            case "rowAbove": t.insertRow(r)
            case "rowBelow": t.insertRow(plusOne(r))
            case "colLeft": t.insertCol(c)
            case "colRight": t.insertCol(plusOne(c))
            case "delRow":
                if !t.deleteRow(r) { throw Cmd.bad(name, "can't delete the last row") }
            default:
                if !t.deleteCol(c) { throw Cmd.bad(name, "can't delete the last column") }
            }
        }
    }

    @Sendable static func merge(_ s: Session, _ p: JSON) throws -> JSON {
        let sel = try s.doc().selection.cells
        guard let from = try cellParam(p, "from", "table.merge") ?? sel?.from.tuple else { throw Cmd.bad("table.merge", "missing `from`") }
        guard let to = try cellParam(p, "to", "table.merge") ?? sel?.to.tuple else { throw Cmd.bad("table.merge", "missing `to`") }
        return try withTable(s, p, "table.merge") { t in
            if !t.merge(from.0, from.1, to.0, to.1) { throw Cmd.bad("table.merge", "can't merge those cells") }
        }
    }

    @Sendable static func split(_ s: Session, _ p: JSON) throws -> JSON {
        let cell = try cellParam(p, "cell", "table.split") ?? at(s, p, "table.split")
        return try withTable(s, p, "table.split") { t in
            if !t.split(cell.0, cell.1) { throw Cmd.bad("table.split", "that cell isn't merged") }
        }
    }

    @Sendable static func style(_ s: Session, _ p: JSON) throws -> JSON {
        guard let st = Cmd.strParam(p, "style") else { throw Cmd.bad("table.style", "missing `style`") }
        return try withTable(s, p, "table.style") { $0.style = st }
    }

    @Sendable static func options(_ s: Session, _ p: JSON) throws -> JSON {
        try withTable(s, p, "table.options") { t in
            if let v = Cmd.boolParam(p, "headerRow") { t.firstRow = v }
            if let v = Cmd.boolParam(p, "totalRow") { t.lastRow = v }
            if let v = Cmd.boolParam(p, "bandedRows") { t.bandRow = v }
            if let v = Cmd.boolParam(p, "firstColumn") { t.firstCol = v }
            if let v = Cmd.boolParam(p, "lastColumn") { t.lastCol = v }
            if let v = Cmd.boolParam(p, "bandedColumns") { t.bandCol = v }
        }
    }

    /// The cells a command acts on: `cells`, else the selected cell range, else the cell holding the
    /// caret, else every cell (`target_cells`).
    private static func targetCells(_ s: Session, _ p: JSON) throws -> (Table) -> [(Int, Int)] {
        let cells: [(Int, Int)]? = p.get("cells")?.asArray.map { a in
            a.prefix(100_000).compactMap { c -> (Int, Int)? in
                guard let r = c.at(0)?.asUsize, let k = c.at(1)?.asUsize else { return nil }
                return (r, k)
            }
        }
        let st = try s.doc()
        // A selected range grows over the merged cells it touches; with only a caret, the caret's cell is used.
        let sel: ((Int, Int), (Int, Int), Bool)? = st.selection.cells.map { ($0.from.tuple, $0.to.tuple, true) }
            ?? st.selection.text?.cell.map { ($0.tuple, $0.tuple, false) }
        return { t in
            if let cells { return cells }
            if let (a0, b0, range) = sel {
                let (a, b) = range ? cellBlock(t, a0, b0) : (a0, b0)
                // The selection can name cells outside the table; only walk the ones that exist.
                let (r1, c1) = (min(max(a.0, b.0), max(t.nRows - 1, 0)), min(max(a.1, b.1), max(t.nCols - 1, 0)))
                let (rs, cs) = (min(a.0, b.0), min(a.1, b.1))
                if rs > r1 || cs > c1 { return [] }
                return (rs ... r1).flatMap { r in (cs ... c1).map { (r, $0) } }
            }
            return (0 ..< t.nRows).flatMap { r in (0 ..< t.nCols).map { (r, $0) } }
        }
    }

    @Sendable static func cellFill(_ s: Session, _ p: JSON) throws -> JSON {
        let fill: Fill? = Cmd.boolOr(p, "none", false) ? Fill.none_ : Cmd.colorParam(p, "color").map(Fill.solid)
        let targets = try targetCells(s, p)
        return try withTable(s, p, "table.cellFill") { t in
            for (r, c) in targets(t) { t.mutateCell(r, c) { $0.fill = fill } }
        }
    }

    private static let left = 0
    private static let right = 1
    private static let top = 2
    private static let bottom = 3

    @Sendable static func borders(_ s: Session, _ p: JSON) throws -> JSON {
        let which = Cmd.strParam(p, "which") ?? "all"
        let all = ["all", "outside", "inside", "insideH", "insideV", "top", "bottom", "left", "right", "diagDown", "diagUp", "none"]
        if !all.contains(which) {
            throw Cmd.bad("table.borders", "unknown `which` \(rustDebug(which)); one of \(all.joined(separator: ", "))")
        }
        let color = Cmd.colorParam(p, "color") ?? ColorRef.rgb(Rgba.rgb(0, 0, 0))
        let width = (Cmd.f64Param(p, "width") ?? 1.0).clamped(0.0, 100.0)
        var line = Line.solid(color, width)
        if let d = Cmd.strParam(p, "dash"), d != "solid" {
            if !Dash.presets.contains(d) {
                throw Cmd.bad("table.borders", "unknown dash \(rustDebug(d)); one of \(Dash.presets.joined(separator: ", "))")
            }
            line.dash = .preset(name: d)
        }
        // "none" clears to no line, so the table style's own lines don't show through either.
        let ln = which == "none" ? Line.none() : line
        let targets = try targetCells(s, p)
        return try withTable(s, p, "table.borders") { t in
            let list = targets(t)
            guard let r0 = list.map(\.0).min(), let r1 = list.map(\.0).max(), let c0 = list.map(\.1).min(), let c1 = list.map(\.1).max() else { return }
            let (rows, cols) = (t.nRows, t.nCols)
            // Set one side of a cell and the facing side of its neighbour, as PowerPoint does.
            func set(_ r: Int, _ c: Int, _ side: Int) {
                t.mutateCell(r, c) { cell in
                    if cell.borders.indices.contains(side) { cell.borders[side] = ln }
                }
                let n: (Int, Int, Int)? = switch side {
                case left: c > 0 ? (r, c - 1, right) : nil
                case right: c + 1 < cols ? (r, c + 1, left) : nil
                case top: r > 0 ? (r - 1, c, bottom) : nil
                default: r + 1 < rows ? (r + 1, c, top) : nil
                }
                if let (nr, nc, ns) = n {
                    t.mutateCell(nr, nc) { cell in
                        if cell.borders.indices.contains(ns) { cell.borders[ns] = ln }
                    }
                }
            }
            for (r, c) in list {
                if r < r0 || r > r1 || c < c0 || c > c1 { continue }
                let outer = [c == c0, c == c1, r == r0, r == r1]
                for side in [left, right, top, bottom] {
                    let horizontal = side == top || side == bottom
                    let on: Bool = switch which {
                    case "all", "none": true
                    case "outside": outer[side]
                    case "inside": !outer[side]
                    case "insideH": horizontal && !outer[side]
                    case "insideV": !horizontal && !outer[side]
                    case "top": side == top && outer[side]
                    case "bottom": side == bottom && outer[side]
                    case "left": side == left && outer[side]
                    case "right": side == right && outer[side]
                    default: false
                    }
                    if on { set(r, c, side) }
                }
                t.mutateCell(r, c) { cell in
                    switch which {
                    case "diagDown": cell.diagDown = ln
                    case "diagUp": cell.diagUp = ln
                    case "none":
                        cell.diagDown = nil
                        cell.diagUp = nil
                    default: break
                    }
                }
            }
        }
    }

    @Sendable static func cellMargins(_ s: Session, _ p: JSON) throws -> JSON {
        // PowerPoint's presets (left/right, top/bottom).
        let base: [Double]
        switch Cmd.strParam(p, "preset") {
        case "none": base = [0, 0, 0, 0]
        case "narrow": base = [3.6, 3.6, 3.6, 3.6]
        case "wide": base = [14.4, 14.4, 14.4, 14.4]
        case "normal", nil: base = [7.2, 7.2, 3.6, 3.6]
        case .some(let o): throw Cmd.bad("table.cellMargins", "unknown preset \(rustDebug(o)); one of normal, none, narrow, wide")
        }
        func side(_ k: String, _ i: Int) -> Double { Cmd.f64Param(p, k).map { $0.clamped(0.0, 400.0) } ?? base[i] }
        let m = [side("left", 0), side("right", 1), side("top", 2), side("bottom", 3)]
        let targets = try targetCells(s, p)
        return try withTable(s, p, "table.cellMargins") { t in
            for (r, c) in targets(t) { t.mutateCell(r, c) { $0.margins = m } }
        }
    }

    @Sendable static func cellAlign(_ s: Session, _ p: JSON) throws -> JSON {
        let a: Anchor
        switch Cmd.strParam(p, "anchor") ?? "top" {
        case "middle", "center", "ctr": a = .middle
        case "bottom", "b": a = .bottom
        case "top", "t": a = .top
        case let o: throw Cmd.bad("table.cellAlign", "unknown anchor \(rustDebug(o)); one of top, middle, bottom")
        }
        let targets = try targetCells(s, p)
        return try withTable(s, p, "table.cellAlign") { t in
            for (r, c) in targets(t) { t.mutateCell(r, c) { $0.anchor = a } }
        }
    }

    private static func distribute(_ s: Session, _ p: JSON, _ rows: Bool) throws -> JSON {
        try withTable(s, p, "table.distribute") { t in
            if rows {
                let h = t.height / Double(max(t.nRows, 1))
                for i in t.rows.indices { t.rows[i].height = h }
            } else {
                let w = t.width / Double(max(t.nCols, 1))
                for i in t.cols.indices { t.cols[i] = w }
            }
        }
    }

    @Sendable static func columnWidth(_ s: Session, _ p: JSON) throws -> JSON {
        let (_, c) = try at(s, p, "table.columnWidth")
        guard let w0 = Cmd.f64Param(p, "width") else { throw Cmd.bad("table.columnWidth", "missing `width`") }
        let w = w0.clamped(4.0, 4000.0)
        let keepTotal = Cmd.boolOr(p, "keepTotal", false)
        let next = c == Int.max ? Int.max : c + 1
        return try withTable(s, p, "table.columnWidth") { t in
            // Keeping the table's width, the column to the right gives or takes the difference (dragging an
            // inner border). The last column has none: the table gets wider or narrower.
            var pair: Double?
            if let a = t.cols.at(c), let b = t.cols.at(next) {
                let v = a.rustMax(0) + b.rustMax(0)
                pair = v.isFinite ? v : nil
            }
            if let pair, keepTotal {
                let lo = minColumnWidth.rustMin(pair / 2.0)
                let w = w.rustMax(lo).rustMin(pair - lo)
                if t.cols.indices.contains(c) { t.cols[c] = w }
                if t.cols.indices.contains(next) { t.cols[next] = pair - w }
            } else if t.cols.indices.contains(c) {
                t.cols[c] = w
            }
        }
    }

    @Sendable static func rowHeight(_ s: Session, _ p: JSON) throws -> JSON {
        let (r, _) = try at(s, p, "table.rowHeight")
        guard let h0 = Cmd.f64Param(p, "height") else { throw Cmd.bad("table.rowHeight", "missing `height`") }
        let h = h0.clamped(4.0, 4000.0)
        return try withTable(s, p, "table.rowHeight") { t in
            if t.rows.indices.contains(r) { t.rows[r].height = h }
        }
    }

    @Sendable static func selectCells(_ s: Session, _ p: JSON) throws -> JSON {
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", "table.selectCells") {
            id = i
        } else {
            guard let first = try s.doc().selection.shapes.first else { throw Cmd.bad("table.selectCells", "select a table") }
            id = first
        }
        let from = try cellParam(p, "from", "table.selectCells") ?? (0, 0)
        let to = try cellParam(p, "to", "table.selectCells") ?? from
        try s.select { _, sel in
            sel.cells = CellRange(id, TextPoint(from.0, from.1), TextPoint(to.0, to.1))
            sel.shapes = [id]
            sel.text = nil
        }
        return Cmd.ok()
    }

    private static func pointParam(_ p: JSON, _ key: String) -> (Double, Double)? {
        guard let a = p.get(key), let x = a.at(0)?.asF64, let y = a.at(1)?.asF64, x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    /// The table under slide point `at` (frontmost), or the one named by `id`, with its origin
    /// (`table_at`).
    static func tableAt(_ s: Session, _ p: JSON, _ at: (Double, Double)) -> (ShapeId, (Double, Double))? {
        guard let st = s.activeDoc else { return nil }
        // A malformed id names no table (never the one under the pointer instead).
        let want: ShapeId?
        do { want = try Cmd.idParam(p, "id", "table.draw") } catch { return nil }
        for sh in st.shapes.reversed() {
            guard let x = sh.xfrm, case .table(let t) = sh.kind else { continue }
            let inside = at.0 >= x.x && at.1 >= x.y && at.0 <= x.x + t.width && at.1 <= x.y + t.height
            if want.map({ $0 == sh.id }) ?? inside { return (sh.id, (x.x, x.y)) }
        }
        return nil
    }

    @Sendable static func drawLine(_ s: Session, _ p: JSON) throws -> JSON {
        guard let from = pointParam(p, "from") else { throw Cmd.bad("table.drawLine", "missing `from`") }
        guard let to = pointParam(p, "to") else { throw Cmd.bad("table.drawLine", "missing `to`") }
        guard let (id, o) = tableAt(s, p, from) else { throw Cmd.bad("table.drawLine", "no table there") }
        let (a, b) = ((from.0 - o.0, from.1 - o.1), (to.0 - o.0, to.1 - o.1))
        return try withTable(s, ["id": id.toJSON()], "table.drawLine") { t in
            if !DrawTable.drawLine(&t, a, b) { throw Cmd.bad("table.drawLine", "the line doesn't divide any cell") }
        }
    }

    @Sendable static func eraseLine(_ s: Session, _ p: JSON) throws -> JSON {
        guard let at = pointParam(p, "at") else { throw Cmd.bad("table.eraseLine", "missing `at`") }
        let tol = (p.get("tol")?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? 6.0).clamped(0.5, 50.0)
        guard let (id, o) = tableAt(s, p, at) else { throw Cmd.bad("table.eraseLine", "no table there") }
        let q = (at.0 - o.0, at.1 - o.1)
        return try withTable(s, ["id": id.toJSON()], "table.eraseLine") { t in
            if !DrawTable.eraseAt(&t, q, tol) { throw Cmd.bad("table.eraseLine", "no border to erase there") }
        }
    }
}

/// Rust's `{:?}` of a string: quoted, with `"`, `\` and control characters escaped as Rust escapes them.
fileprivate func rustDebug(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\0": out += "\\0"
        default:
            if c.properties.generalCategory == .control {
                out += "\\u{\(String(c.value, radix: 16))}"
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    return out + "\""
}
