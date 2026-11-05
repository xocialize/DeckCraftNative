// The port's own (AB-T-0435): the embedded workbook behind a chart whose data the writer wrote, as PowerPoint
// gives every chart one. deckcraft writes none, and PowerPoint's Edit Data then rebuilds a sheet from the chart's
// caches. Two ways:
//
// - a chart written from the model (new, or regenerated after an edit) gets a fresh one-sheet workbook holding
//   what its ranges (`c:f`) and caches say, linked by `c:externalData` (`c:autoUpdate` 0);
// - a chart whose data the writer put into its kept part (`chart.data`, `WriteChartPatch.swift`), or regenerated
//   from an imported one, has its original workbook updated in place when the original's ranges were the
//   generator's layout (PowerPoint's own): the chart's cells are set, cells it no longer reads are cleared, the
//   sheet's table follows the data, and Excel recalculates on open. Everything else in the workbook (other
//   sheets, formulas, formatting) stays. Where that can't be done safely (another layout, a formula over a range
//   of the cells, a table that can't follow), a fresh workbook replaces it, with a warning.
//
// Write-only and bounded: the original is read within size limits and anything unexpected falls back.
import CNCore
import CNZip
import DCModel

extension PPTXWrite.Charts {
    static let rtPackage = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package"
    static let ctWorkbook = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    static let nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    /// The sheet the generator's ranges name.
    static let sheetName = "Sheet1"
    /// The children of `c:ser` that hold a range.
    static let dataRoles = ["tx", "cat", "val", "xVal", "yVal", "bubbleSize"]
    /// Cells a chart's ranges may cover: past it the chart gets no workbook.
    static let maxCells = 1 << 20

    /// A worksheet cell: 1-based row, 0-based column.
    struct Cell: Hashable, Comparable {
        var row: Int
        var col: Int
        static func < (a: Cell, b: Cell) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }
        var name: String { PPTXWrite.Charts.col(col) + String(row) }
    }

    enum CellValue: Equatable {
        case number(String)
        case text(String)
    }

    /// What a chart's ranges say of each cell they cover: its value, or nil where the cache has no point.
    typealias Claims = [Cell: CellValue?]

    /// Where a chart's ranges put its data: the cells, and whether a range had to move (`rangeClaims`).
    struct Layout {
        var claims: Claims
        var moved: Bool
        /// The bottom-right cell the ranges reach.
        var end: Cell {
            Cell(row: claims.keys.map(\.row).max() ?? 1, col: claims.keys.map(\.col).max() ?? 0)
        }
    }

    // MARK: - Ranges

    /// `Sheet1!$B$2:$B$5` or `Sheet1!$B$1`: the generator's ranges, one column of `Sheet1`.
    static func parseRange(_ f: String) -> (col: Int, rows: ClosedRange<Int>)? {
        let t = rustTrim(f)
        let prefix = sheetName + "!"
        guard hasBytePrefix(t, prefix) else { return nil }
        let ends = t.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard ends.count == 1 || ends.count == 2 else { return nil }
        let cells = ends.compactMap(absoluteCell)
        guard cells.count == ends.count, let a = cells.first, let b = cells.last, a.col == b.col, a.row <= b.row else { return nil }
        return (a.col, a.row ... b.row)
    }

    /// `$B$2`.
    static func absoluteCell(_ s: Substring) -> Cell? {
        let parts = s.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, let col = columnIndex(parts[1]),
              let row = rustParseUnsigned(parts[2], as: UInt32.self), row >= 1, row <= 1_048_576 else { return nil }
        return Cell(row: Int(row), col: col)
    }

    /// `B12`, as a sheet's `r` attribute names a cell.
    static func cellName(_ s: String) -> Cell? {
        let u = Array(s.utf8)
        var i = 0
        while i < u.count, isASCIIAlpha(u[i]) { i += 1 }
        guard i > 0, i < u.count, let col = columnIndex(Substring(String(decoding: u[0 ..< i], as: UTF8.self))),
              let row = rustParseUnsigned(String(decoding: u[i...], as: UTF8.self), as: UInt32.self), row >= 1, row <= 1_048_576
        else { return nil }
        return Cell(row: Int(row), col: col)
    }

    /// `A1:D5` (or one cell), as a table's or a formula's `ref`: its top-left and bottom-right cells.
    static func areaRef(_ s: String) -> (lo: Cell, hi: Cell)? {
        let ends = s.split(separator: ":", omittingEmptySubsequences: false)
        guard ends.count == 1 || ends.count == 2, let a = ends.first.flatMap({ cellName(String($0)) }),
              let b = ends.last.flatMap({ cellName(String($0)) }) else { return nil }
        return (Cell(row: Swift.min(a.row, b.row), col: Swift.min(a.col, b.col)), Cell(row: Swift.max(a.row, b.row), col: Swift.max(a.col, b.col)))
    }

    /// `B` → 1; at most `XFD` (16 383).
    static func columnIndex(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.utf8.count <= 3 else { return nil }
        var n = 0
        for b in s.utf8 {
            guard isASCIIAlpha(b) else { return nil }
            n = n * 26 + Int((b | 0x20) - UInt8(ascii: "a")) + 1
        }
        return n <= 16384 ? n - 1 : nil
    }

    static func isASCIIAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= UInt8(ascii: "a") && (b | 0x20) <= UInt8(ascii: "z") }

    static func rangeText(_ col: Int, _ rows: ClosedRange<Int>) -> String {
        let c = PPTXWrite.Charts.col(col)
        return rows.count == 1 ? "\(sheetName)!$\(c)$\(rows.lowerBound)" : "\(sheetName)!$\(c)$\(rows.lowerBound):$\(c)$\(rows.upperBound)"
    }

    /// Calls `body` on every series range (`c:strRef`, `c:numRef`) of a chart part, in document order.
    static func eachRef(_ root: inout XMLEl, _ body: (inout XMLEl) -> Void) {
        root.elementsMut { ch in
            guard ch.is("chart") else { return }
            ch.elementsMut { pa in
                guard pa.is("plotArea") else { return }
                pa.elementsMut { g in
                    guard plotGroups.contains(where: { g.is($0) }) else { return }
                    g.elementsMut { s in
                        guard s.is("ser") else { return }
                        s.elementsMut { d in
                            guard dataRoles.contains(where: { d.is($0) }) else { return }
                            d.elementsMut { r in
                                if r.is("strRef") || r.is("numRef") { body(&r) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The series ranges' formulas, in document order.
    static func refs(_ root: XMLEl) -> [String] {
        var e = root
        var out: [String] = []
        eachRef(&e) { out.append(String(rustTrim($0.child("f")?.text ?? ""))) }
        return out
    }

    /// The points of a range's cache, by index.
    static func points(_ ref: XMLEl) -> [Int: CellValue] {
        var out: [Int: CellValue] = [:]
        let num = ref.is("numRef")
        guard let cache = ref.child(num ? "numCache" : "strCache") else { return out }
        for pt in cache.childrenNamed("pt") {
            guard let i = pt.attr("idx").flatMap({ rustParseUnsigned($0, as: UInt32.self) }), let v = pt.child("v")?.text else { continue }
            let t = rustTrim(v)
            if num, let d = Double(t), d.isFinite {
                out[Int(i)] = .number(String(t))
            } else {
                out[Int(i)] = .text(v)
            }
        }
        return out
    }

    /// What a chart's ranges say of the cells, in document order. A range covering cells an earlier one holds
    /// with other contents moves to a free column (deckcraft's layout gives every scatter series' x values
    /// column A, and a bubble series' sizes the next series' y column), its `c:f` rewritten. Nil when a range
    /// isn't one of the generator's, or there are too many cells.
    static func rangeClaims(_ root: inout XMLEl) -> Layout? {
        var ranges: [(col: Int, rows: ClosedRange<Int>)] = []
        var ok = true
        eachRef(&root) { r in
            if let f = r.child("f")?.text, let range = parseRange(f) {
                ranges.append(range)
            } else {
                ok = false
            }
        }
        guard ok, ranges.reduce(0, { $0 &+ $1.rows.count }) <= maxCells else { return nil }
        var free = (ranges.map(\.col).max() ?? 0) + 1
        var out = Layout(claims: [:], moved: false)
        var i = 0
        eachRef(&root) { r in
            guard i < ranges.count else { return }
            var (col, rows) = ranges[i]
            i += 1
            let pts = points(r)
            let clash = rows.contains { row in
                if let prior = out.claims[Cell(row: row, col: col)] { return prior != pts[row - rows.lowerBound] }
                return false
            }
            if clash, free < 16384 {
                col = free
                free += 1
                out.moved = true
                r.edit("f") { $0.children = [.text(rangeText(col, rows))] }
            }
            for row in rows {
                out.claims[Cell(row: row, col: col)] = .some(pts[row - rows.lowerBound])
            }
        }
        return out
    }

    // MARK: - The chart part

    /// The chart part linked to a workbook by `relId`, and where its data goes; nil when its ranges aren't the
    /// generator's.
    static func linked(_ xml: [UInt8], _ relId: String) -> (xml: [UInt8], layout: Layout)? {
        guard let doc = try? parseXML(xml), bytesEqual(doc.root.name, "c:chartSpace") else { return nil }
        var root = doc.root
        // By exact key: `attr` matches local names and skips namespace declarations.
        if let r = root.attrs.first(where: { bytesEqual($0.key, "xmlns:r") }) {
            guard bytesEqual(r.value, OPC.nsR) else { return nil }
        } else {
            root.attrs.append(("xmlns:r", OPC.nsR))
        }
        guard let layout = rangeClaims(&root) else { return nil }
        root.remove("externalData")
        let link = XMLEl(name: "c:externalData", attrs: [("r:id", relId)], children: [.el(el("c:autoUpdate", "0"))])
        // CT_ChartSpace: the elements before `c:externalData`.
        root.insert(link, after: ["date1904", "lang", "roundedCorners", "AlternateContent", "style", "clrMapOvr", "pivotSource",
                                  "protection", "chart", "spPr", "txPr"])
        var w = W.new()
        w.raw(root.toXML())
        return (w.finish(), layout)
    }

    /// A chart part written from the model, linked to a fresh workbook holding its data.
    static func freshBook(_ xml: [UInt8], _ relId: String) -> (xml: [UInt8], book: [UInt8])? {
        guard let l = linked(xml, relId), let book = newWorkbook(l.layout.claims) else { return nil }
        return (l.xml, book)
    }

    /// A chart part whose data the writer wrote (`chartPart`'s `fresh`), linked to a workbook: the original's
    /// updated in place when it can be, else a new one. Warns about what was lost.
    static func book(_ xml: [UInt8], _ c: Chart, _ relId: String) -> (xml: [UInt8], book: [UInt8])? {
        guard let l = linked(xml, relId) else {
            PPTXLog.warn("pptx: the chart's ranges aren't the writer's own; no embedded workbook written")
            return nil
        }
        switch originalBook(c) {
        case .none:
            break
        case .some(let original):
            if let o = original, !l.layout.moved, let updated = updatedWorkbook(o.bytes, l.layout, o.layout) {
                return (l.xml, updated)
            }
            PPTXLog.warn("pptx: the chart's embedded workbook couldn't be updated; a new one holds the chart's data")
        }
        guard let book = newWorkbook(l.layout.claims) else { return nil }
        return (l.xml, book)
    }

    /// The chart's original embedded workbook: nil when it had none; `.some(nil)` when it can't be updated in
    /// place (not a workbook package, or ranges in another layout than the generator's); else its bytes and
    /// where its ranges put the data.
    static func originalBook(_ c: Chart) -> (bytes: [UInt8], layout: Layout)?? {
        let books = c.kept.rels.filter { !$0.external && (hasByteSuffix($0.relType, "/package") || hasByteSuffix($0.relType, "/oleObject")) }
        guard let rel = books.first else { return nil }
        guard books.count == 1, hasByteSuffix(rel.relType, "/package"),
              let part = c.kept.parts.first(where: { bytesEqual(OPC.norm($0.name), OPC.norm(rel.part)) }),
              let raw = c.raw, let doc = try? parseXML(raw), let was = reread(doc.root) else { return .some(nil) }
        var root = doc.root
        guard let layout = rangeClaims(&root), !layout.moved else { return .some(nil) }
        // The ranges must be the ones the generator writes for the chart as read: then the new ones replace them.
        var me = was
        me.raw = nil
        me.kept = ChartKept()
        guard let gen = try? parseXML(chartPart(me).xml), refs(doc.root) == refs(gen.root) else { return .some(nil) }
        return .some((part.bytes, layout))
    }

    // MARK: - A new workbook

    /// A one-sheet workbook holding the cells: `Sheet1`, inline strings, no table.
    static func newWorkbook(_ claims: Claims) -> [UInt8]? {
        var pkg = PackageOut()
        pkg.rels("", RelsOut(items: [("rId1", OPC.rtBase + "officeDocument", "xl/workbook.xml", false)]))
        var wb = W.new()
        wb.open("workbook", A.new().a("xmlns", nsMain).a("xmlns:r", OPC.nsR))
        wb.open0("sheets")
        wb.empty("sheet", A.new().a("name", sheetName).a("sheetId", 1).a("r:id", "rId1"))
        wb.close("sheets")
        wb.close("workbook")
        pkg.xmlPart("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml", wb.finish())
        pkg.rels("xl/workbook.xml", RelsOut(items: [
            ("rId1", OPC.rtBase + "worksheet", "worksheets/sheet1.xml", false),
            ("rId2", OPC.rtBase + "styles", "styles.xml", false),
        ]))
        var ws = W.new()
        ws.open("worksheet", A.new().a("xmlns", nsMain).a("xmlns:r", OPC.nsR))
        let filled = claims.compactMapValues { $0 }
        if !filled.isEmpty {
            let end = Cell(row: filled.keys.map(\.row).max() ?? 1, col: filled.keys.map(\.col).max() ?? 0)
            ws.empty("dimension", A.new().a("ref", end == Cell(row: 1, col: 0) ? "A1" : "A1:" + end.name))
        }
        ws.open0("sheetData")
        let byRow = Dictionary(grouping: filled.keys, by: \.row)
        for row in byRow.keys.sorted() {
            ws.open("row", A.new().a("r", row))
            for cell in (byRow[row] ?? []).sorted() {
                switch filled[cell] {
                case .number(let s)?:
                    ws.open("c", A.new().a("r", cell.name))
                    ws.elt("v", s)
                    ws.close("c")
                case .text(let s)?:
                    ws.open("c", A.new().a("r", cell.name).a("t", "inlineStr"))
                    ws.open0("is")
                    ws.open("t", A.new().a("xml:space", "preserve"))
                    ws.text(s)
                    ws.close("t")
                    ws.close("is")
                    ws.close("c")
                case nil:
                    break
                }
            }
            ws.close("row")
        }
        ws.close("sheetData")
        ws.close("worksheet")
        pkg.xmlPart("xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml", ws.finish())
        var st = W.new()
        st.raw(#"<styleSheet xmlns="\#(nsMain)"><fonts count="1"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#)
        pkg.xmlPart("xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml", st.finish())
        return try? pkg.finish()
    }

    // MARK: - Updating the original

    /// Size limits for reading the original workbook.
    static let maxBookEntries = 4096
    static let maxBookPart = 64 * 1024 * 1024
    static let maxBookTotal = 256 * 1024 * 1024

    static func xmlBytes(_ e: XMLEl) -> [UInt8] {
        var w = W.new()
        w.raw(e.toXML())
        return w.finish()
    }

    /// `original` with the chart's cells set (`now`), the cells only `was` covered cleared, the sheet's tables
    /// following the data, no calculation chain, and a full recalculation on load. Nil when it can't be done
    /// safely: then the caller writes a new workbook.
    static func updatedWorkbook(_ original: [UInt8], _ now: Layout, _ was: Layout) -> [UInt8]? {
        guard let zip = try? ZipReader(original), zip.entries.count <= maxBookEntries else { return nil }
        var files: [(name: String, data: [UInt8], compress: Bool)] = []
        var total = 0
        for e in zip.entries where !hasByteSuffix(e.name, "/") {
            guard let d = try? zip.read(e, max: maxBookPart) else { return nil }
            total += d.count
            guard total <= maxBookTotal else { return nil }
            files.append((e.name, d, e.method != 0))
        }
        func index(_ part: String) -> Int? {
            let n = OPC.norm(part)
            return files.firstIndex { bytesEqual(OPC.norm($0.name), n) }
        }
        func rels(_ part: String) -> Rels {
            index(OPC.relsPath(part)).map { OPC.relsFromBytes(files[$0].data, part) } ?? Rels()
        }
        // The workbook and its `Sheet1`.
        guard let bookRel = rels("").items.first(where: { bytesEqual($0.kind, "officeDocument") && !$0.external }),
              let bi = index(bookRel.target), var book = try? parseXML(files[bi].data).root,
              let sheetId = book.child("sheets")?.childrenNamed("sheet").first(where: { $0.attr("name").map { bytesEqual($0, sheetName) } ?? false })?.attr("r:id")
        else { return nil }
        let bookRels = rels(bookRel.target)
        guard let sheetRel = bookRels.items.first(where: { bytesEqual($0.id, sheetId) && !$0.external }),
              let si = index(sheetRel.target), let parsed = try? parseXML(files[si].data).root,
              let sheet = updatedSheet(parsed, now.claims, was.claims) else { return nil }
        files[si].data = xmlBytes(sheet)
        // A table over the data follows it: its range and its columns' names.
        let reach = Cell(row: Swift.max(now.end.row, was.end.row), col: Swift.max(now.end.col, was.end.col))
        var headers: [Int: String] = [:]
        for (cell, v) in now.claims where cell.row == 1 {
            switch v {
            case .number(let s)?, .text(let s)?: headers[cell.col] = s
            case nil: break
            }
        }
        for t in rels(sheetRel.target).items where bytesEqual(t.kind, "table") && !t.external {
            guard let ti = index(t.target), let table = try? parseXML(files[ti].data).root,
                  let area = table.attr("ref").flatMap(areaRef) else { return nil }
            if area.lo.row > reach.row || area.lo.col > reach.col || area.hi.row < 1 { continue }
            guard let next = updatedTable(table, now.end, headers) else { return nil }
            files[ti].data = xmlBytes(next)
        }
        // The calculation chain may name a formula the update removed: Excel rebuilds it.
        var dropped: [String] = []
        for r in bookRels.items where bytesEqual(r.kind, "calcChain") && !r.external {
            if let ci = index(r.target) {
                dropped.append(OPC.norm(files[ci].name))
                files.remove(at: ci)
            }
        }
        if !dropped.isEmpty {
            guard let ri = index(OPC.relsPath(bookRel.target)), var relsDoc = try? parseXML(files[ri].data).root else { return nil }
            relsDoc.children.removeAll { n in
                if case .el(let e) = n, let ty = e.attr("Type") { return hasByteSuffix(ty, "/calcChain") }
                return false
            }
            files[ri].data = xmlBytes(relsDoc)
            if let ci = index("[Content_Types].xml"), var types = try? parseXML(files[ci].data).root {
                types.children.removeAll { n in
                    if case .el(let e) = n, e.is("Override"), let p = e.attr("PartName") { return dropped.contains(OPC.norm(p)) }
                    return false
                }
                files[ci].data = xmlBytes(types)
            }
        }
        // Formulas elsewhere that read the cells recalculate when Excel opens the workbook.
        if !book.edit("calcPr", { $0.setAttr("fullCalcOnLoad", "1") }) {
            let pfx = book.prefix.isEmpty ? "" : book.prefix + ":"
            book.insert(XMLEl(name: pfx + "calcPr", attrs: [("fullCalcOnLoad", "1")]),
                        after: ["fileVersion", "fileSharing", "workbookPr", "AlternateContent", "revisionPtr", "absPath", "workbookProtection",
                                "bookViews", "sheets", "functionGroups", "externalReferences", "definedNames"])
        }
        files[bi].data = xmlBytes(book)
        var zw = ZipWriter()
        do {
            for f in files { try zw.add(f.name, f.data, compress: f.compress) }
            return try zw.finish()
        } catch {
            return nil
        }
    }

    /// The sheet with the cells of `now` set and those only `was` covered cleared (a cleared cell keeps its
    /// style). Nil when a row or cell has no address, or a shared or array formula's range holds one of them.
    static func updatedSheet(_ sheet: XMLEl, _ now: Claims, _ was: Claims) -> XMLEl? {
        var sheet = sheet
        let pfx = sheet.prefix.isEmpty ? "" : sheet.prefix + ":"
        var touched = Set(now.keys)
        for k in was.keys where now[k] == nil { touched.insert(k) }
        var ok = true
        let found = sheet.edit("sheetData") { data in
            var rows: [Int: XMLEl] = [:]
            for case .el(let row) in data.children where row.is("row") {
                guard let r = row.attr("r").flatMap({ rustParseUnsigned($0, as: UInt32.self) }), r >= 1, rows[Int(r)] == nil else {
                    ok = false
                    return
                }
                rows[Int(r)] = row
            }
            // A formula over a range (shared, array, data table) can't lose a cell of it.
            for row in rows.values {
                for case .el(let c) in row.children where c.is("c") {
                    guard let f = c.child("f") else { continue }
                    let ty = f.attr("t") ?? ""
                    guard bytesEqual(ty, "array") || bytesEqual(ty, "dataTable") || (bytesEqual(ty, "shared") && f.hasAttr("ref")) else { continue }
                    guard let area = f.attr("ref").flatMap(areaRef),
                          !touched.contains(where: { $0.row >= area.lo.row && $0.row <= area.hi.row && $0.col >= area.lo.col && $0.col <= area.hi.col })
                    else {
                        ok = false
                        return
                    }
                }
            }
            for cell in touched.sorted() {
                let value = now[cell] ?? nil
                var row = rows[cell.row] ?? XMLEl(name: pfx + "row", attrs: [("r", String(cell.row))])
                // Where the cell is, or where it goes: before the first cell to its right, or anything not a cell.
                var at: Int?
                var insertAt = row.children.count
                for (i, n) in row.children.enumerated() {
                    guard case .el(let c) = n else { continue }
                    guard c.is("c") else {
                        insertAt = i
                        break
                    }
                    guard let here = c.attr("r").flatMap(cellName) else {
                        ok = false
                        return
                    }
                    if here.col == cell.col {
                        at = i
                        break
                    }
                    if here.col > cell.col {
                        insertAt = i
                        break
                    }
                }
                // Nothing to clear.
                if value == nil && at == nil { continue }
                var c = XMLEl(name: pfx + "c", attrs: [("r", cell.name)])
                if let at, case .el(let old) = row.children[at] {
                    c.attrs = old.attrs.filter { a in bytesEqual(a.key, "r") || bytesEqual(a.key, "s") }
                }
                switch value {
                case .number(let s)?:
                    c.children = [.el(XMLEl(name: pfx + "v", children: [.text(s)]))]
                case .text(let s)?:
                    c.attrs.append(("t", "inlineStr"))
                    let t = XMLEl(name: pfx + "t", attrs: [("xml:space", "preserve")], children: [.text(s)])
                    c.children = [.el(XMLEl(name: pfx + "is", children: [.el(t)]))]
                case nil:
                    break
                }
                if let at {
                    row.children[at] = .el(c)
                } else {
                    row.children.insert(.el(c), at: insertAt)
                }
                row.attrs.removeAll { bytesEqual($0.key, "spans") }
                rows[cell.row] = row
            }
            guard ok else { return }
            let others = data.children.filter { n in
                if case .el(let e) = n { return !e.is("row") }
                return false
            }
            data.children = rows.keys.sorted().compactMap { rows[$0].map { XMLNode.el($0) } } + others
        }
        guard found || touched.isEmpty, ok else { return nil }
        // The used range grows to hold the data.
        let end = Cell(row: now.keys.map(\.row).max() ?? 1, col: now.keys.map(\.col).max() ?? 0)
        sheet.edit("dimension") { d in
            let area = d.attr("ref").flatMap(areaRef) ?? (Cell(row: 1, col: 0), end)
            let lo = Cell(row: Swift.min(area.lo.row, 1), col: Swift.min(area.lo.col, 0))
            let hi = Cell(row: Swift.max(area.hi.row, end.row), col: Swift.max(area.hi.col, end.col))
            d.setAttr("ref", lo == hi ? lo.name : lo.name + ":" + hi.name)
        }
        return sheet
    }

    /// A table over the chart's data, resized to end at `end`, its columns named from the header row (`headers`,
    /// else the names they had). Nil when it doesn't start at A1 with a header row, has a totals row or a
    /// calculated column, or a name would be empty, repeated or hold a control character.
    static func updatedTable(_ table: XMLEl, _ end: Cell, _ headers: [Int: String]) -> XMLEl? {
        guard let area = table.attr("ref").flatMap(areaRef), area.lo == Cell(row: 1, col: 0), end.row >= 2,
              !bytesEqual(table.attr("headerRowCount") ?? "1", "0"), bytesEqual(table.attr("totalsRowCount") ?? "0", "0")
        else { return nil }
        var table = table
        let pfx = table.prefix.isEmpty ? "" : table.prefix + ":"
        let ref = "A1:" + end.name
        table.setAttr("ref", ref)
        var ok = true
        let found = table.edit("tableColumns") { cols in
            var list: [XMLEl] = []
            for case .el(let c) in cols.children where c.is("tableColumn") { list.append(c) }
            if list.contains(where: { $0.child("calculatedColumnFormula") != nil || $0.hasAttr("totalsRowFunction") }) {
                ok = false
                return
            }
            var maxId = list.compactMap { $0.attr("id").flatMap { rustParseUnsigned($0, as: UInt32.self) } }.max() ?? 0
            var names = Set<String>()
            var out: [XMLEl] = []
            for j in 0 ... end.col {
                var c: XMLEl
                if j < list.count {
                    c = list[j]
                } else {
                    maxId &+= 1
                    c = XMLEl(name: pfx + "tableColumn", attrs: [("id", String(maxId))])
                }
                guard let name = headers[j] ?? c.attr("name"), !name.isEmpty,
                      !name.unicodeScalars.contains(where: { $0.value < 0x20 }),
                      names.insert(rustASCIILowercase(name)).inserted else {
                    ok = false
                    return
                }
                c.setAttr("name", name)
                out.append(c)
            }
            cols.children = out.map { .el($0) }
            cols.setAttr("count", String(out.count))
        }
        guard found, ok else { return nil }
        table.edit("autoFilter") { $0.setAttr("ref", ref) }
        return table
    }

    /// A relationship id no kept relationship uses.
    static func freeRelId(_ used: Set<String>) -> String {
        var n = 1
        while used.contains("rId\(n)") { n += 1 }
        return "rId\(n)"
    }
}
