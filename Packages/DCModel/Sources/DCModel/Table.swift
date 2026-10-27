// DCModel — tables (graphic frames with `a:tbl`): cells, merges, row and column edits, file-defined
// table styles. Port of deckcraft crates/model/src/table.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCColor
import DCCore

/// `a + b` saturating at `Int.max`, as Rust's `usize::saturating_add`.
private func satAdd(_ a: Int, _ b: Int) -> Int {
    let (v, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : v
}

extension Cell {
    public init(_ text: String) {
        self.init(text: .fromText(text), gridSpan: 1, rowSpan: 1)
    }

    public var isCovered: Bool { hMerge || vMerge }
}

extension Table {
    public static var `default`: Table {
        Table(
            cols: [], rows: [], style: "medium2-accent1", firstRow: true, firstCol: false, lastRow: false,
            lastCol: false, bandRow: true, bandCol: false, background: nil
        )
    }

    /// A `rows`×`cols` table of empty cells (each clamped to 1…1000) filling `width`.
    public init(rows: Int, cols: Int, width: Double, rowHeight: Double) {
        let rows = Swift.min(Swift.max(rows, 1), 1000)
        let cols = Swift.min(Swift.max(cols, 1), 1000)
        let cw = cols > 0 ? width / Double(cols) : width
        self = .default
        self.cols = Array(repeating: cw, count: cols)
        self.rows = (0 ..< rows).map { _ in Row(height: rowHeight, cells: (0 ..< cols).map { _ in Cell("") }) }
    }

    public var nRows: Int { rows.count }
    public var nCols: Int { cols.count }

    public func cell(_ r: Int, _ c: Int) -> Cell? {
        rows.at(r)?.cells.at(c)
    }

    /// deckcraft's `cell_mut`: runs `body` on cell (r, c) in place; nil when there's none.
    @discardableResult
    public mutating func mutateCell<R>(_ r: Int, _ c: Int, _ body: (inout Cell) throws -> R) rethrows -> R? {
        guard rows.indices.contains(r), rows[r].cells.indices.contains(c) else { return nil }
        return try body(&rows[r].cells[c])
    }

    public var width: Double { rsSum(cols) }
    public var height: Double { rsSum(rows.map(\.height)) }

    /// Insert an empty row before `at`. A merge the new row falls inside grows to cover it.
    public mutating func insertRow(_ at: Int) {
        let at = Swift.min(Swift.max(at, 0), rows.count)
        let merges = self.merges()
        let h = rows.at(Swift.max(at - 1, 0))?.height ?? 30.0
        rows.insert(Row(height: h, cells: (0 ..< cols.count).map { _ in Cell("") }), at: at)
        setMerges(merges.map { $0.insertRow(at) })
    }

    /// Insert an empty column before `at`. A merge the new column falls inside grows to cover it.
    public mutating func insertCol(_ at: Int) {
        let at = Swift.min(Swift.max(at, 0), cols.count)
        let merges = self.merges()
        let w = cols.at(Swift.max(at - 1, 0)) ?? 80.0
        cols.insert(w, at: at)
        for r in rows.indices {
            let i = Swift.min(at, rows[r].cells.count)
            rows[r].cells.insert(Cell(""), at: i)
        }
        setMerges(merges.map { $0.insertCol(at) })
    }

    /// Delete row `at`. Merges through it shrink; a merge anchored on it moves its anchor (and text) to
    /// the next row it covers.
    @discardableResult
    public mutating func deleteRow(_ at: Int) -> Bool {
        if rows.count <= 1 || at < 0 || at >= rows.count { return false }
        let merges = self.merges()
        for m in merges where m.r == at && m.rs > 1 {
            moveAnchor((m.r, m.c), (m.r + 1, m.c))
        }
        rows.remove(at: at)
        setMerges(merges.compactMap { $0.deleteRow(at) })
        return true
    }

    /// Delete column `at`. Merges through it shrink; a merge anchored on it moves its anchor (and text)
    /// to the next column it covers.
    @discardableResult
    public mutating func deleteCol(_ at: Int) -> Bool {
        if cols.count <= 1 || at < 0 || at >= cols.count { return false }
        let merges = self.merges()
        for m in merges where m.c == at && m.gs > 1 {
            moveAnchor((m.r, m.c), (m.r, m.c + 1))
        }
        cols.remove(at: at)
        for r in rows.indices where at < rows[r].cells.count {
            rows[r].cells.remove(at: at)
        }
        setMerges(merges.compactMap { $0.deleteCol(at) })
        return true
    }

    /// The merged areas: every uncovered cell spanning more than one cell, clipped to the grid.
    private func merges() -> [TableMerge] {
        let (nr, nc) = (rows.count, cols.count)
        var out: [TableMerge] = []
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.cells.prefix(nc).enumerated() where !cell.isCovered {
                let rs = Swift.min(Int(Swift.max(cell.rowSpan, 1)), nr - r)
                let gs = Swift.min(Int(Swift.max(cell.gridSpan, 1)), nc - c)
                if rs > 1 || gs > 1 { out.append(TableMerge(r: r, c: c, rs: rs, gs: gs)) }
            }
        }
        return out
    }

    /// Rebuild every cell's spans and merge flags from `merges`.
    private mutating func setMerges(_ merges: [TableMerge]) {
        for r in rows.indices {
            for c in rows[r].cells.indices {
                rows[r].cells[c].gridSpan = 1
                rows[r].cells[c].rowSpan = 1
                rows[r].cells[c].hMerge = false
                rows[r].cells[c].vMerge = false
            }
        }
        for m in merges where m.rs > 1 || m.gs > 1 {
            for r in m.r ..< satAdd(m.r, m.rs) {
                if r >= rows.count { break }
                for c in m.c ..< satAdd(m.c, m.gs) {
                    if c >= cols.count && c >= (rows.at(r)?.cells.count ?? 0) { break }
                    mutateCell(r, c) { cell in
                        cell.hMerge = c > m.c
                        cell.vMerge = r > m.r
                    }
                }
            }
            mutateCell(m.r, m.c) { cell in
                cell.gridSpan = UInt32(clamping: m.gs)
                cell.rowSpan = UInt32(clamping: m.rs)
            }
        }
    }

    /// Swap the anchor cell's contents into the cell that takes over as anchor.
    private mutating func moveAnchor(_ from: (Int, Int), _ to: (Int, Int)) {
        guard let a = cell(from.0, from.1), let b = cell(to.0, to.1) else { return }
        mutateCell(to.0, to.1) { $0 = a }
        mutateCell(from.0, from.1) { $0 = b }
    }

    /// Merge the rectangle (r0,c0)–(r1,c1) inclusive into its top-left cell.
    @discardableResult
    public mutating func merge(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> Bool {
        var (r0, r1) = (Swift.min(r0, r1), Swift.max(r0, r1))
        var (c0, c1) = (Swift.min(c0, c1), Swift.max(c0, c1))
        if r0 < 0 || c0 < 0 || r1 >= rows.count || c1 >= cols.count || (r0 == r1 && c0 == c1) { return false }
        // Grow the rectangle until no existing merge sticks out of it.
        while true {
            let before = (r0, c0, r1, c1)
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.cells.prefix(cols.count).enumerated() where !cell.isCovered {
                    let ar1 = Swift.min(satAdd(r, Int(Swift.max(cell.rowSpan, 1)) - 1), rows.count - 1)
                    let ac1 = Swift.min(satAdd(c, Int(Swift.max(cell.gridSpan, 1)) - 1), cols.count - 1)
                    if r <= r1 && ar1 >= r0 && c <= c1 && ac1 >= c0 {
                        r0 = Swift.min(r0, r)
                        c0 = Swift.min(c0, c)
                        r1 = Swift.max(r1, ar1)
                        c1 = Swift.max(c1, ac1)
                    }
                }
            }
            if (r0, c0, r1, c1) == before { break }
        }
        var text: [Paragraph] = []
        for r in r0 ... r1 {
            for c in c0 ... c1 {
                mutateCell(r, c) { cell in
                    if !cell.text.isEmpty {
                        text += cell.text.paragraphs
                        cell.text.paragraphs = []
                    }
                    cell.hMerge = c > c0
                    cell.vMerge = r > r0
                    cell.gridSpan = 1
                    cell.rowSpan = 1
                }
            }
        }
        mutateCell(r0, c0) { cell in
            cell.gridSpan = UInt32(clamping: c1 - c0 + 1)
            cell.rowSpan = UInt32(clamping: r1 - r0 + 1)
            cell.hMerge = false
            cell.vMerge = false
            if !text.isEmpty { cell.text.paragraphs = text }
        }
        return true
    }

    /// Undo a merge at (r, c).
    @discardableResult
    public mutating func split(_ r: Int, _ c: Int) -> Bool {
        guard let cell = cell(r, c) else { return false }
        let (gs, rs) = (Int(Swift.max(cell.gridSpan, 1)), Int(Swift.max(cell.rowSpan, 1)))
        if gs == 1 && rs == 1 { return false }
        // Spans come from the file and may reach past the table; only walk the cells that exist.
        let rEnd = Swift.min(satAdd(r, rs), rows.count)
        let cEnd = Swift.min(satAdd(c, gs), cols.count)
        if r < rEnd && c < cEnd {
            for rr in r ..< rEnd {
                for cc in c ..< cEnd {
                    mutateCell(rr, cc) { x in
                        x.hMerge = false
                        x.vMerge = false
                        x.gridSpan = 1
                        x.rowSpan = 1
                    }
                }
            }
        }
        return true
    }

    /// Make every row have exactly `cols.count` cells (repair after loading).
    public mutating func normalize() {
        let n = cols.count
        for r in rows.indices {
            if rows[r].cells.count > n {
                rows[r].cells.removeLast(rows[r].cells.count - n)
            } else if rows[r].cells.count < n {
                rows[r].cells += (rows[r].cells.count ..< n).map { _ in Cell("") }
            }
            for c in rows[r].cells.indices {
                rows[r].cells[c].gridSpan = Swift.max(rows[r].cells[c].gridSpan, 1)
                rows[r].cells[c].rowSpan = Swift.max(rows[r].cells[c].rowSpan, 1)
            }
        }
    }
}

/// A merged area: anchor (r, c) spanning `rs` rows and `gs` columns.
private struct TableMerge: Equatable {
    var r: Int
    var c: Int
    var rs: Int
    var gs: Int

    func insertRow(_ at: Int) -> TableMerge {
        var m = self
        if at <= r {
            m.r = r + 1
        } else if at < r + rs {
            m.rs = rs + 1
        }
        return m
    }

    func insertCol(_ at: Int) -> TableMerge {
        var m = self
        if at <= c {
            m.c = c + 1
        } else if at < c + gs {
            m.gs = gs + 1
        }
        return m
    }

    func deleteRow(_ at: Int) -> TableMerge? {
        var m = self
        if at < r {
            m.r = r - 1
        } else if at < r + rs {
            m.rs = rs - 1
        }
        // A merge that lost its only row or column is gone, not a 0-span merge over its neighbours.
        return m.rs >= 1 && m.gs >= 1 && (m.rs > 1 || m.gs > 1) ? m : nil
    }

    func deleteCol(_ at: Int) -> TableMerge? {
        var m = self
        if at < c {
            m.c = c - 1
        } else if at < c + gs {
            m.gs = gs - 1
        }
        // A merge that lost its only row or column is gone, not a 0-span merge over its neighbours.
        return m.rs >= 1 && m.gs >= 1 && (m.rs > 1 || m.gs > 1) ? m : nil
    }
}

extension TableStyleDef {
    public func part(_ p: TablePart) -> TablePartStyle? {
        parts.first { $0.a == p }?.b
    }
}

extension TablePart {
    /// Every part, in the order they apply.
    public static var all: [TablePart] { allCases }

    /// The OOXML name, which is also the serialised name.
    public var xml: String { rawValue }

    public static func fromXML(_ s: String) -> TablePart? { TablePart(rawValue: s) }
}

/// Built-in table styles: (id, label). Styles are generated from the theme accents.
public func tableStyles() -> [(id: String, label: String)] {
    var v: [(id: String, label: String)] = [("none", "No Style, No Grid"), ("grid", "No Style, Table Grid")]
    for (kind, label) in [
        ("light1", "Light Style 1"), ("light2", "Light Style 2"), ("medium2", "Medium Style 2"),
        ("medium4", "Medium Style 4"), ("dark1", "Dark Style 1"),
    ] {
        v.append(("\(kind)-tx1", label))
        for a in 1 ... 6 {
            v.append(("\(kind)-accent\(a)", "\(label) - Accent \(a)"))
        }
    }
    return v
}
