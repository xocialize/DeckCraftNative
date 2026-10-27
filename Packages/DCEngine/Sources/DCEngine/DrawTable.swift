// DCEngine — Draw Table: the pencil splits cells along the line you draw, the table eraser merges the two
// cells on either side of the border you click. Pure operations on a `Table` in its own coordinates (points
// from its top-left corner).
//
// Both work on the table's anchors (each visible cell with its row and column span), edit that list, then
// lay the grid back out, so merges anywhere in the table survive.
// Port of deckcraft crates/engine/src/drawtable.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum DrawTable {
    /// A line closer than this to an existing grid line reuses it rather than adding a sliver.
    static let snap = 4.0
    /// Cap on the grid so a runaway pencil can't build an enormous table.
    static let maxGrid = 200

    struct Anchor {
        var r: Int
        var c: Int
        var rs: Int
        var cs: Int
        var cell: Cell
    }

    static func anchors(_ t: Table) -> [Anchor] {
        var v: [Anchor] = []
        for (r, row) in t.rows.enumerated() {
            for (c, cell) in row.cells.enumerated() where !cell.isCovered {
                let rs = max(min(Int(max(cell.rowSpan, 1)), max(t.rows.count - r, 0)), 1)
                let cs = max(min(Int(max(cell.gridSpan, 1)), max(t.cols.count - c, 0)), 1)
                v.append(Anchor(r: r, c: c, rs: rs, cs: cs, cell: cell))
            }
        }
        return v
    }

    /// Lay `anchors` out into `t`'s grid (its rows and columns already sized).
    static func rebuild(_ t: inout Table, _ anchors: [Anchor]) {
        let (nr, nc) = (t.rows.count, t.cols.count)
        for i in t.rows.indices { t.rows[i].cells = (0 ..< nc).map { _ in Cell("") } }
        for a in anchors {
            for r in a.r ..< max(min(a.r + a.rs, nr), a.r) {
                for c in a.c ..< max(min(a.c + a.cs, nc), a.c) {
                    t.mutateCell(r, c) { x in
                        x.hMerge = c > a.c
                        x.vMerge = r > a.r
                    }
                }
            }
            t.mutateCell(a.r, a.c) { x in
                var cell = a.cell
                cell.gridSpan = UInt32(clamping: a.cs)
                cell.rowSpan = UInt32(clamping: a.rs)
                cell.hMerge = false
                cell.vMerge = false
                x = cell
            }
        }
        t.normalize()
    }

    /// Swap rows and columns, so the vertical case reuses the horizontal one.
    static func transpose(_ t: inout Table) {
        let heights = t.rows.map(\.height)
        var a = anchors(t)
        for i in a.indices {
            (a[i].r, a[i].c) = (a[i].c, a[i].r)
            (a[i].rs, a[i].cs) = (a[i].cs, a[i].rs)
            let b = a[i].cell.borders
            if b.count == 4 { a[i].cell.borders = [b[2], b[3], b[0], b[1]] }
        }
        let widths = t.cols
        t.cols = heights
        t.rows = widths.map { Row(height: $0, cells: []) }
        rebuild(&t, a)
    }

    static func edges(_ sizes: [Double]) -> [Double] {
        var e = [0.0]
        var acc = 0.0
        for s in sizes {
            acc += s
            e.append(acc)
        }
        return e
    }

    /// Draw a line from `a` to `b` (table points). Mostly-horizontal lines split rows, mostly-vertical
    /// ones split columns; only the cells the line crosses are divided. Returns whether anything changed
    /// (`draw_line`).
    @discardableResult
    public static func drawLine(_ t: inout Table, _ a: (Double, Double), _ b: (Double, Double)) -> Bool {
        if ![a.0, a.1, b.0, b.1].allSatisfy(\.isFinite) || t.rows.isEmpty || t.cols.isEmpty { return false }
        if abs(b.0 - a.0) >= abs(b.1 - a.1) {
            return splitRows(&t, (a.1 + b.1) / 2.0, a.0.rustMin(b.0), a.0.rustMax(b.0))
        }
        transpose(&t)
        let changed = splitRows(&t, (a.0 + b.0) / 2.0, a.1.rustMin(b.1), a.1.rustMax(b.1))
        transpose(&t)
        return changed
    }

    /// A horizontal line at `y` from `x0` to `x1`.
    static func splitRows(_ t: inout Table, _ y: Double, _ x0: Double, _ x1: Double) -> Bool {
        let ys = edges(t.rows.map(\.height))
        let xs = edges(t.cols)
        let total = ys.last ?? 0.0
        if y <= snap || y >= total - snap || x1 - x0 < snap { return false }
        var a = anchors(t)
        // Boundary index b: an existing grid line near y, or a new one splitting row k.
        let b: Int
        if let found = ys.firstIndex(where: { abs($0 - y) <= snap }) {
            b = found
        } else {
            if t.rows.count >= maxGrid { return false }
            guard let k = (0 ..< max(ys.count - 1, 0)).first(where: { ys[$0] < y && y < ys[$0 + 1] }) else { return false }
            let top = ys[k]
            let (h0, h1) = (y - top, ys[k + 1] - y)
            if t.rows.indices.contains(k) { t.rows[k].height = h0 }
            t.rows.insert(Row(height: h1, cells: []), at: min(k + 1, t.rows.count))
            for i in a.indices {
                if a[i].r > k {
                    a[i].r += 1
                } else if a[i].r + a[i].rs > k {
                    a[i].rs += 1
                }
            }
            b = k + 1
        }
        var changed = false
        var out: [Anchor] = []
        out.reserveCapacity(a.count + 4)
        for x in a {
            let (l, r) = (xs.at(x.c) ?? 0.0, xs.at(x.c + x.cs) ?? 0.0)
            // The line divides a cell it crosses for more than half of the cell's width.
            let overlap = (r.rustMin(x1) - l.rustMax(x0)).rustMax(0.0)
            if x.r < b && b < x.r + x.rs && overlap * 2.0 > r - l {
                var belowCell = x.cell
                belowCell.text = TextBody()
                let below = Anchor(r: b, c: x.c, rs: x.r + x.rs - b, cs: x.cs, cell: belowCell)
                var above = x
                above.rs = b - x.r
                out.append(above)
                out.append(below)
                changed = true
            } else {
                out.append(x)
            }
        }
        rebuild(&t, out)
        return changed
    }

    /// Erase the border nearest `p` (within `tol` points): the two cells it separates merge, when together
    /// they make a rectangle. Returns whether a border was erased (`erase_at`).
    @discardableResult
    public static func eraseAt(_ t: inout Table, _ p: (Double, Double), _ tol: Double) -> Bool {
        if !(p.0.isFinite && p.1.isFinite) { return false }
        let ys = edges(t.rows.map(\.height))
        let xs = edges(t.cols)
        var a = anchors(t)
        func rect(_ x: Anchor) -> (Double, Double, Double, Double) {
            (xs.at(x.c) ?? 0, ys.at(x.r) ?? 0, xs.at(x.c + x.cs) ?? 0, ys.at(x.r + x.rs) ?? 0)
        }
        var best: (Double, Int, Int)?
        for (i, u) in a.enumerated() {
            for (j, v) in a.enumerated() {
                let (ul, ut, ur, ub) = rect(u)
                // v directly right of u with the same rows, or directly below with the same columns.
                let d: Double
                if v.c == u.c + u.cs && v.r == u.r && v.rs == u.rs && p.1 > ut && p.1 < ub {
                    d = abs(p.0 - ur)
                } else if v.r == u.r + u.rs && v.c == u.c && v.cs == u.cs && p.0 > ul && p.0 < ur {
                    d = abs(p.1 - ub)
                } else {
                    continue
                }
                if d <= tol && (best.map { d < $0.0 } ?? true) { best = (d, i, j) }
            }
        }
        guard let (_, i, j) = best else { return false }
        let v = a[j]
        if v.r == a[i].r {
            a[i].cs += v.cs
        } else {
            a[i].rs += v.rs
        }
        let more = v.cell.text.paragraphs
        if !v.cell.text.isEmpty {
            if a[i].cell.text.isEmpty {
                a[i].cell.text.paragraphs = more
            } else {
                a[i].cell.text.paragraphs.append(contentsOf: more)
            }
        }
        a.remove(at: j)
        rebuild(&t, a)
        return true
    }
}
