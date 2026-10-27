// Ported from deckcraft crates/model/src/table.rs tests (MIT OR Apache-2.0).
import DCModel
import Testing

/// Every cell is owned by exactly one anchor (itself or a span over it), and no span leaves the grid.
private func expectTopology(_ t: Table, sourceLocation: SourceLocation = #_sourceLocation) {
    let (nr, nc) = (t.nRows, t.nCols)
    var owner = Array(repeating: Array(repeating: 0, count: nc), count: nr)
    for (r, row) in t.rows.enumerated() {
        #expect(row.cells.count == nc, sourceLocation: sourceLocation)
        for (c, cell) in row.cells.enumerated() {
            if cell.isCovered {
                #expect(cell.gridSpan == 1 && cell.rowSpan == 1, "covered (\(r),\(c)) has spans", sourceLocation: sourceLocation)
                continue
            }
            let (rs, gs) = (Int(cell.rowSpan), Int(cell.gridSpan))
            #expect(r + rs <= nr && c + gs <= nc, "span at (\(r),\(c)) leaves the grid", sourceLocation: sourceLocation)
            for rr in r ..< Swift.min(r + rs, nr) {
                for cc in c ..< Swift.min(c + gs, nc) { owner[rr][cc] += 1 }
            }
        }
    }
    for (r, o) in owner.enumerated() {
        for (c, n) in o.enumerated() {
            #expect(n == 1, "cell (\(r),\(c)) owned \(n) times", sourceLocation: sourceLocation)
        }
    }
}

private func merged() -> Table {
    // 4x4 with a 2x2 merge at (1,1) holding "M".
    var t = Table(rows: 4, cols: 4, width: 400.0, rowHeight: 30.0)
    t.mutateCell(1, 1) { $0.text = .fromText("M") }
    do {
        let ok = t.merge(1, 1, 2, 2)
        #expect(ok)
    }
    expectTopology(t)
    return t
}

private func anchorText(_ t: Table, _ r: Int, _ c: Int) -> String {
    t.cell(r, c)?.text.text ?? "<no cell>"
}

@Suite struct TableTests {
    @Test func mergingOverAnExistingMergeTakesItIn() throws {
        var t = Table(rows: 3, cols: 3, width: 300.0, rowHeight: 30.0)
        t.mutateCell(1, 2) { $0.text = .fromText("X") }
        do {
            let ok = t.merge(1, 1, 1, 2)
            #expect(ok)
        }
        do {
            let ok = t.merge(0, 0, 1, 1)
            #expect(ok)
        }
        expectTopology(t)
        let a = try #require(t.cell(0, 0))
        #expect(a.rowSpan == 2 && a.gridSpan == 3)
        #expect(anchorText(t, 0, 0) == "X")
    }

    @Test func rowAndColumnEditsKeepMergesConsistent() {
        for at in 0 ... 4 {
            var t = merged()
            t.insertRow(at)
            expectTopology(t)
            var u = merged()
            u.insertCol(at)
            expectTopology(u)
        }
        for at in 0 ..< 4 {
            var t = merged()
            do {
                let ok = t.deleteRow(at)
                #expect(ok)
            }
            expectTopology(t)
            var u = merged()
            do {
                let ok = u.deleteCol(at)
                #expect(ok)
            }
            expectTopology(u)
        }
    }

    @Test func insertingInsideAMergeGrowsIt() throws {
        var t = merged()
        t.insertRow(2)
        let a = try #require(t.cell(1, 1))
        #expect(a.rowSpan == 3 && a.gridSpan == 2)
        let c22 = try #require(t.cell(2, 2))
        #expect(c22.hMerge && c22.vMerge)
        t.insertCol(0)
        #expect(t.cell(1, 2)?.gridSpan == 2)
        #expect(anchorText(t, 1, 2) == "M")
        expectTopology(t)
    }

    @Test func deletingTheAnchorRowOrColumnKeepsTheText() throws {
        var t = merged()
        do {
            let ok = t.deleteRow(1)
            #expect(ok)
        }
        var a = try #require(t.cell(1, 1))
        #expect(!a.isCovered)
        #expect(a.rowSpan == 1 && a.gridSpan == 2)
        #expect(anchorText(t, 1, 1) == "M")
        do {
            let ok = t.deleteCol(1)
            #expect(ok)
        }
        a = try #require(t.cell(1, 1))
        #expect(!a.isCovered)
        #expect(a.rowSpan == 1 && a.gridSpan == 1)
        #expect(anchorText(t, 1, 1) == "M")
        expectTopology(t)
    }

    @Test func deletingTheOnlyRowOrColumnOfAMergeRemovesIt() {
        // A 1x3 merge across a row: deleting that row leaves no merge behind.
        var t = Table(rows: 3, cols: 3, width: 300.0, rowHeight: 30.0)
        do {
            let ok = t.merge(1, 0, 1, 2)
            #expect(ok)
        }
        do {
            let ok = t.deleteRow(1)
            #expect(ok)
        }
        #expect((0 ..< t.nRows).allSatisfy { r in (0 ..< t.nCols).allSatisfy { c in t.cell(r, c).map { !$0.isCovered && $0.gridSpan <= 1 } ?? false } })
        expectTopology(t)
        // A 3x1 merge down a column: deleting that column leaves no merge behind.
        var u = Table(rows: 3, cols: 3, width: 300.0, rowHeight: 30.0)
        do {
            let ok = u.merge(0, 1, 2, 1)
            #expect(ok)
        }
        do {
            let ok = u.deleteCol(1)
            #expect(ok)
        }
        #expect((0 ..< u.nRows).allSatisfy { r in (0 ..< u.nCols).allSatisfy { c in u.cell(r, c).map { !$0.isCovered && $0.rowSpan <= 1 } ?? false } })
        expectTopology(u)
    }

    @Test func insertDeleteMergeSplit() {
        var t = Table(rows: 3, cols: 3, width: 300.0, rowHeight: 30.0)
        #expect(t.nRows == 3 && t.nCols == 3)
        t.insertRow(1)
        t.insertCol(3)
        #expect(t.nRows == 4 && t.nCols == 4)
        do {
            let ok = t.deleteRow(0) && t.deleteCol(0)
            #expect(ok)
        }
        #expect(t.nRows == 3 && t.nCols == 3)
        do {
            let ok = t.merge(0, 0, 1, 1)
            #expect(ok)
        }
        #expect(t.cell(0, 0).map { [$0.gridSpan, $0.rowSpan] } == [2, 2])
        #expect(t.cell(1, 1)?.isCovered == true)
        do {
            let ok = t.split(0, 0)
            #expect(ok)
        }
        #expect(t.cell(1, 1)?.isCovered != true)
        do {
            let ok = !t.merge(5, 5, 6, 6)
            #expect(ok)
        }
        do {
            let ok = !t.deleteRow(99)
            #expect(ok)
        }
        var one = Table(rows: 1, cols: 1, width: 10.0, rowHeight: 10.0)
        do {
            let ok = !one.deleteRow(0) && !one.deleteCol(0)
            #expect(ok)
        }
        #expect(tableStyles().count > 30)
    }

    @Test func splitIgnoresSpansPastTheTable() {
        var t = Table(rows: 2, cols: 2, width: 100.0, rowHeight: 10.0)
        t.mutateCell(0, 0) { c in
            c.gridSpan = .max
            c.rowSpan = .max
        }
        do {
            let ok = t.split(0, 0)
            #expect(ok)
        }
        #expect(t.cell(0, 0).map { [$0.gridSpan, $0.rowSpan] } == [1, 1])
    }
}
