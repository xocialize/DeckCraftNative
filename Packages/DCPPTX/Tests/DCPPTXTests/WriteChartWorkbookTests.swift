// The port's own: the embedded workbook behind a chart whose data the writer wrote (`WriteChartWorkbook.swift`,
// AB-T-0435).
import CNZip
import DCModel
import Testing
@testable import DCPPTX

private typealias C = PPTXWrite.Charts
private let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let rt = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

private func part(_ zip: [UInt8], _ name: String) throws -> [UInt8] {
    try ZipReader(zip).read(named: name, max: 1 << 24)
}

/// A sheet's cells as Excel shows them (inline, shared or plain), and its formulas.
private func sheet(_ book: [UInt8], _ name: String = "xl/worksheets/sheet1.xml") throws -> (values: [String: String], formulas: [String: String]) {
    let z = try ZipReader(book)
    let sst = (try? z.read(named: "xl/sharedStrings.xml", max: 1 << 24)).flatMap { try? parseXML($0).root }.map { $0.childrenNamed("si").map(\.text) } ?? []
    let ws = try parseXML(z.read(named: name, max: 1 << 24)).root
    var values: [String: String] = [:]
    var formulas: [String: String] = [:]
    for row in ws.child("sheetData").map({ Array($0.childrenNamed("row")) }) ?? [] {
        for c in row.childrenNamed("c") {
            guard let r = c.attr("r") else { continue }
            if let f = c.child("f") { formulas[r] = f.text }
            switch c.attr("t") ?? "" {
            case "inlineStr": values[r] = c.child("is")?.text
            case "s": values[r] = c.child("v").flatMap { Int($0.text) }.flatMap { $0 < sst.count ? sst[$0] : nil }
            default: values[r] = c.child("v")?.text
            }
        }
    }
    return (values, formulas)
}

/// Every range of the chart part reads, in the workbook, what its cache says.
private func consistent(_ xml: [UInt8], _ book: [UInt8]) throws {
    let cells = try sheet(book).values
    var root = try parseXML(xml).root
    var count = 0
    C.eachRef(&root) { r in
        guard let f = r.child("f")?.text, let range = C.parseRange(f) else {
            Issue.record("range \(r.toXML())")
            return
        }
        let pts = C.points(r)
        for row in range.rows {
            let name = C.Cell(row: row, col: range.col).name
            switch pts[row - range.rows.lowerBound] {
            case .number(let v)?: #expect(cells[name].flatMap(Double.init) == Double(v), "\(name) of \(f)")
            case .text(let v)?: #expect(cells[name] == v, "\(name) of \(f)")
            case nil: #expect(cells[name] == nil, "\(name) of \(f)")
            }
            count += 1
        }
    }
    #expect(count > 0)
}

/// The chart as the reader reads it, without what the writer keeps beside the model.
private func model(_ xml: [UInt8]) throws -> Chart {
    var c = try #require(PPTXRead.readChartXML(xml))
    (c.raw, c.kept) = (nil, ChartKept())
    return c
}

/// A workbook as PowerPoint makes one for `c`: shared strings, a table over the data, a calculation chain, a
/// formula beside the data reading it, and a second sheet.
private func powerPointBook(_ c: Chart, arrayFormula: Bool = false) throws -> [UInt8] {
    var strings: [String] = [" "]
    func s(_ t: String) -> Int {
        if let i = strings.firstIndex(of: t) { return i }
        strings.append(t)
        return strings.count - 1
    }
    let last = c.categories.count + 1
    var rows = #"<row r="1" spans="1:4"><c r="A1" s="1" t="s"><v>0</v></c>"#
    for (i, x) in c.series.enumerated() { rows += #"<c r="\#(C.col(i + 1))1" s="1" t="s"><v>\#(s(x.name))</v></c>"# }
    rows += "</row>"
    for (j, cat) in c.categories.enumerated() {
        let r = j + 2
        rows += #"<row r="\#(r)" spans="1:7"><c r="A\#(r)" s="1" t="s"><v>\#(s(cat))</v></c>"#
        for (i, x) in c.series.enumerated() {
            let f = arrayFormula && i == 0 && j < 2 ? (j == 0 ? #"<f t="array" ref="B2:B3">{1;2}</f>"# : "") : ""
            rows += #"<c r="\#(C.col(i + 1))\#(r)" s="1">\#(f)<v>\#(x.values[j].map { "\($0)" } ?? "")</v></c>"#
        }
        rows += #"<c r="G\#(r)"><f>SUM(B\#(r):D\#(r))</f><v>0</v></c></row>"#
    }
    let end = C.col(c.series.count) + "\(last)"
    let columns = ([" "] + c.series.map(\.name)).enumerated().map { #"<tableColumn id="\#($0.offset + 1)" name="\#($0.element)"/>"# }.joined()
    let entries: [(name: String, data: String)] = [
        ("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/><Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/></Types>"#),
        ("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#),
        ("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="\#(ns)" xmlns:r="\#(rt)"><workbookPr/><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/></sheets><calcPr calcId="181029"/></workbook>"#),
        ("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\#(rt)/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="\#(rt)/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId4" Type="\#(rt)/calcChain" Target="calcChain.xml"/></Relationships>"#),
        ("xl/worksheets/sheet1.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\#(ns)" xmlns:r="\#(rt)"><dimension ref="A1:G\#(last)"/><sheetData>\#(rows)</sheetData><tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>"#),
        ("xl/worksheets/_rels/sheet1.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/table" Target="../tables/table1.xml"/></Relationships>"#),
        ("xl/worksheets/sheet2.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\#(ns)"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>keep me</t></is></c></row></sheetData></worksheet>"#),
        ("xl/tables/table1.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><table xmlns="\#(ns)" id="1" name="Table1" displayName="Table1" ref="A1:\#(end)" totalsRowShown="0"><tableColumns count="\#(c.series.count + 1)">\#(columns)</tableColumns><tableStyleInfo showRowStripes="1"/></table>"#),
        ("xl/sharedStrings.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="\#(ns)">\#(strings.map { #"<si><t xml:space="preserve">\#($0)</t></si>"# }.joined())</sst>"#),
        ("xl/calcChain.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><calcChain xmlns="\#(ns)"><c r="G2" i="1"/></calcChain>"#),
    ]
    return try IT.zip(entries.map { (name: $0.name, data: Array($0.data.utf8)) })
}

/// `c` as read from a part PowerPoint wrote: its XML kept, linked to `book`.
private func imported(_ c: Chart, _ book: [UInt8], relType: String = "\(rt)/package") throws -> Chart {
    let xml = text(PPTXWrite.chartXML(c).xml).replacingOccurrences(of: "</c:chartSpace>", with: #"<c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>"#)
    var back = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
    back.kept = ChartKept(
        rels: [ChartRel(id: "rId1", relType: relType, target: "../embeddings/Book1.xlsx", part: "ppt/embeddings/Book1.xlsx", external: false)],
        parts: [ChartPart(name: "ppt/embeddings/Book1.xlsx", contentType: C.ctWorkbook, bytes: book)]
    )
    return back
}

/// Write `c` as `chartRel` does: the part, and the workbook linked to it.
private func written(_ c: Chart) throws -> (xml: [UInt8], book: [UInt8]) {
    let p = C.chartPart(c)
    #expect(p.fresh)
    let id = C.freeRelId(Set((p.kept?.rels ?? []).map(\.id)))
    return try #require(C.book(p.xml, c, id))
}

@Suite struct WriteChartWorkbookTests {
    @Test func aNewChartGetsAWorkbookOfItsData() throws {
        let c = Chart.sample(.column)
        let plain = PPTXWrite.chartXML(c).xml
        let (xml, book) = try #require(C.freshBook(plain, "rId1"))
        let s = text(xml)
        #expect(s.contains(#"<c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>"#), "\(s)")
        #expect(s.components(separatedBy: "xmlns:r=").count == 2, "one declaration: \(s.prefix(400))")
        #expect(try model(xml) == model(plain))
        try consistent(xml, book)
        let cells = try sheet(book).values
        #expect(cells["B1"] == "Series 1" && cells["A2"] == "Q1" && cells["D5"].flatMap(Double.init) == 5.1, "\(cells)")
        #expect(try text(part(book, "xl/workbook.xml")).contains(#"<sheet name="Sheet1" sheetId="1" r:id="rId1"/>"#))
    }

    /// Every type the writer draws as a plain chart gets a workbook that agrees with its ranges.
    @Test(arguments: [ChartType.column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .line, .lineMarkers, .stackedLine,
                      .area, .stackedArea, .pie, .doughnut, .scatter, .bubble, .radar, .filledRadar, .stock, .surface, .combo])
    func everyTypeHasAConsistentWorkbook(_ kind: ChartType) throws {
        let c = Chart.sample(kind)
        let plain = PPTXWrite.chartXML(c).xml
        let (xml, book) = try #require(C.freshBook(plain, "rId1"))
        #expect(try model(xml) == model(plain))
        try consistent(xml, book)
    }

    /// deckcraft gives every scatter series' x values column A, and a bubble series' sizes the next series'
    /// y column: a range that would contradict another moves to a column of its own.
    @Test func rangesThatWouldClashMove() throws {
        var c = Chart.sample(.scatter)
        c.series[1].xValues = [10, 20, 30, 40]
        let (xml, book) = try #require(C.freshBook(PPTXWrite.chartXML(c).xml, "rId1"))
        try consistent(xml, book)
        #expect(try model(xml).series.map(\.xValues) == c.series.map(\.xValues))
        #expect(C.refs(try parseXML(xml).root).contains("Sheet1!$E$2:$E$5"))

        var b = Chart.sample(.bubble)
        for i in b.series.indices { b.series[i].sizes = b.series[i].values.map { $0.map { $0 * 10 } } }
        let (bx, bb) = try #require(C.freshBook(PPTXWrite.chartXML(b).xml, "rId1"))
        try consistent(bx, bb)
        #expect(try model(bx).series.map(\.sizes) == b.series.map(\.sizes))
    }

    @Test func chartDataUpdatesThePowerPointWorkbookInPlace() throws {
        let base = Chart.sample(.column)
        let original = try powerPointBook(base)
        var c = try imported(base, original)
        c.series[0].values[0] = 42
        c.series[2].name = "Renamed"
        c.series.append(Series(name: "Added", values: [1, 2, 3, 4]))
        let (xml, book) = try written(c)
        try consistent(xml, book)
        let (cells, formulas) = try sheet(book)
        #expect(cells["B2"] == "42" && cells["D1"] == "Renamed" && cells["E1"] == "Added" && cells["E5"] == "4", "\(cells)")
        // What the chart doesn't read stays: the formula beside the data, the other sheet.
        #expect(formulas["G2"] == "SUM(B2:D2)" && formulas.count == 4)
        #expect(try part(book, "xl/worksheets/sheet2.xml") == part(original, "xl/worksheets/sheet2.xml"))
        // The table follows the data and Excel recalculates; the calculation chain goes.
        let table = try text(part(book, "xl/tables/table1.xml"))
        #expect(table.contains(#"ref="A1:E5""#) && table.contains(#"<tableColumns count="5">"#), "\(table)")
        #expect(table.contains(#"name="Renamed""#) && table.contains(#"<tableColumn id="5" name="Added"/>"#), "\(table)")
        #expect(try text(part(book, "xl/workbook.xml")).contains(#"<calcPr calcId="181029" fullCalcOnLoad="1"/>"#))
        #expect((try? part(book, "xl/calcChain.xml")) == nil)
        #expect(try !text(part(book, "xl/_rels/workbook.xml.rels")).contains("calcChain"))
        #expect(try !text(part(book, "[Content_Types].xml")).contains("calcChain"))

        // Fewer series and categories: the cells the chart no longer reads are cleared, keeping their style.
        var d = try imported(base, original)
        d.categories.removeLast()
        d.series.removeLast()
        for i in d.series.indices { d.series[i].values.removeLast() }
        let (xml2, book2) = try written(d)
        try consistent(xml2, book2)
        let cells2 = try sheet(book2).values
        #expect(cells2["D1"] == nil && cells2["A5"] == nil && cells2["B5"] == nil && cells2["G5"] != nil, "\(cells2)")
        let ws = try text(part(book2, "xl/worksheets/sheet1.xml"))
        #expect(ws.contains(#"<c r="D2" s="1"/>"#), "\(ws)")
        #expect(try text(part(book2, "xl/tables/table1.xml")).contains(#"ref="A1:C4""#))
    }

    /// Where the original can't be updated safely, a new workbook holds the chart's data.
    @Test func otherwiseANewWorkbookReplacesTheOriginal() throws {
        let base = Chart.sample(.column)
        // A formula over a range of the cells.
        var a = try imported(base, powerPointBook(base, arrayFormula: true))
        a.series[0].values[0] = 42
        // Ranges in another layout than the generator's.
        var b = try imported(base, powerPointBook(base))
        b.raw = try #require(b.raw).replacingOccurrences(of: "Sheet1!$B$2:$B$5", with: "Sheet1!$B$3:$B$6")
        b.series[0].values[0] = 42
        // An embedded OLE object rather than a workbook package; and bytes that aren't a zip.
        var o = try imported(base, powerPointBook(base), relType: "\(rt)/oleObject")
        o.series[0].values[0] = 42
        var j = try imported(base, Array("not a workbook".utf8))
        j.series[0].values[0] = 42
        for c in [a, b, o, j] {
            let (xml, book) = try written(c)
            try consistent(xml, book)
            #expect((try? part(book, "xl/worksheets/sheet2.xml")) == nil, "a new workbook")
            #expect(try sheet(book).values["B2"] == "42")
        }
    }

    /// A deck round trip: a new chart is exported with its workbook, which an untouched save keeps and a data
    /// edit updates.
    @Test func aDeckKeepsAndUpdatesItsChartWorkbook() throws {
        var p = newPresentation(nil)
        p.slides.removeAll()
        var slide = try #require(newSlide(&p, layoutOfKind(p, .blank) ?? LayoutId.default))
        var shape = IT.shape(&p, "Chart", 40, 40, 400, 300)
        shape.kind = .chart(Chart.sample(.line))
        slide.shapes.append(shape)
        p.slides.append(slide)
        let first = try IT.entries(PPTX.export(p))
        let book = try #require(first.first { $0.name == "ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx" }?.data)
        let types = try text(#require(first.first { $0.name == "[Content_Types].xml" }?.data))
        #expect(types.contains(#"<Override PartName="/ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx" ContentType="\#(C.ctWorkbook)"/>"#))
        let rels = try text(#require(first.first { $0.name == "ppt/charts/_rels/chart1.xml.rels" }?.data))
        #expect(rels.contains(#"Id="rId1" Type="\#(rt)/package" Target="../embeddings/Microsoft_Excel_Worksheet1.xlsx""#), "\(rels)")

        var again = try PPTX.import(IT.zip(first))
        let second = try IT.entries(PPTX.export(again))
        #expect(second.first { $0.name == "ppt/embeddings/kept1.xlsx" }?.data == book, "kept untouched")

        let at = try #require(again.slides[0].shapes.firstIndex { $0.name == "Chart" })
        guard case var .chart(c) = again.slides[0].shapes[at].kind else {
            Issue.record("chart")
            return
        }
        c.series[1].values[2] = 77
        again.slides[0].shapes[at].kind = .chart(c)
        let third = try IT.entries(PPTX.export(again))
        let updated = try #require(third.first { $0.name == "ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx" }?.data)
        let xml = try #require(third.first { $0.name == "ppt/charts/chart1.xml" }?.data)
        try consistent(xml, updated)
        #expect(try sheet(updated).values["C4"] == "77")
        #expect(!third.contains { $0.name.hasPrefix("ppt/embeddings/kept") }, "the old workbook isn't written beside the new one")
    }
}
