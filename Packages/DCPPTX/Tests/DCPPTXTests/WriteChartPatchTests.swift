// The port's own: `chart.options` edits written into a kept chart part (`WriteChartPatch.swift`, AB-T-0433).
import CNCore
import DCModel
@testable import DCPPTX
import Testing

@Suite struct WriteChartPatchTests {
    private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    /// A part as PowerPoint writes one: formatted title text, a series' label position, a data table and an
    /// extension list, none of which the model holds.
    private func imported(_ kind: ChartType = .column) throws -> Chart {
        var xml = text(PPTXWrite.chartXML(Chart.sample(kind)).xml)
        xml = xml.replacingOccurrences(of: "<a:r><a:t>Chart Title</a:t>", with: #"<a:r><a:rPr lang="en-US" b="1"/><a:t>Chart Title</a:t>"#)
        xml = xml.replacingOccurrences(of: "</c:plotArea>", with: #"<c:dTable><c:showHorzBorder val="1"/></c:dTable></c:plotArea>"#)
        xml = xml.replacingOccurrences(of: "</c:chartSpace>", with: #"<c:extLst><c:ext uri="{KEEP}"/></c:extLst></c:chartSpace>"#)
        let c = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        #expect(PPTXWrite.chartXML(c).preserved, "untouched: written back as read")
        return c
    }

    private func written(_ c: Chart) throws -> (xml: String, back: Chart) {
        let (out, preserved) = PPTXWrite.chartXML(c)
        #expect(preserved, "patched, not regenerated")
        return (text(out), try #require(PPTXRead.readChartXML(out)))
    }

    private func same(_ a: Chart, _ b: Chart) -> Bool {
        var x = a, y = b
        (x.raw, y.raw, x.kept, y.kept) = (nil, nil, ChartKept(), ChartKept())
        return PPTXWrite.Charts.labelsNormalized(x) == PPTXWrite.Charts.labelsNormalized(y)
    }

    @Test func aTitleEditKeepsWhatTheModelDoesntHold() throws {
        var c = try imported()
        c.title = "Revenue\nby quarter"
        let (xml, back) = try written(c)
        #expect(back.title == "Revenue\nby quarter")
        #expect(same(back, c))
        #expect(xml.contains("<c:dTable>") && xml.contains(#"<c:ext uri="{KEEP}"/>"#))
        // Each line keeps the original run's formatting.
        #expect(xml.components(separatedBy: #"<a:rPr lang="en-US" b="1"/>"#).count == 3, "\(xml)")
    }

    @Test func legendLabelsAndGridlinesAreWrittenIntoThePart() throws {
        var c = try imported()
        c.legend = "t"
        c.dataLabels = true
        for i in c.series.indices { c.series[i].dataLabels = nil }
        c.gridlines = !c.gridlines
        let (xml, back) = try written(c)
        #expect(back.legend == "t" && back.dataLabels && back.gridlines == c.gridlines)
        #expect(same(back, c))
        #expect(xml.contains("<c:dTable>"))
        c.legend = nil
        c.dataLabels = false
        let (xml2, back2) = try written(c)
        #expect(back2.legend == nil && !back2.dataLabels)
        #expect(!xml2.contains("<c:legend>") && xml2.contains("<c:dTable>"))
    }

    @Test func aTitleIsRemovedAndAddedAgain() throws {
        var c = try imported()
        c.title = nil
        let (xml, back) = try written(c)
        #expect(back.title == nil && xml.contains(#"<c:autoTitleDeleted val="1"/>"#))
        // A part saved without a title gets a new one.
        var again = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        again.title = "Added"
        let (xml2, back2) = try written(again)
        #expect(back2.title == "Added" && xml2.contains(#"<c:autoTitleDeleted val="0"/>"#) && xml2.contains("<c:dTable>"))
    }

    @Test func aPieKeepsItsPartWithoutAxes() throws {
        var c = try imported(.pie)
        c.gridlines = true
        c.legend = nil
        _ = try written(c)
    }

    /// Anything else still regenerates the part, as before.
    @Test func otherEditsRegenerate() throws {
        var d = try imported()
        d.kind = .line
        #expect(!PPTXWrite.chartXML(d).preserved)
        var e = try imported()
        e.palette = "colorful3"
        #expect(!PPTXWrite.chartXML(e).preserved)
    }

    // MARK: - chart.data

    static let book = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package"
    static let style = "http://schemas.microsoft.com/office/2011/relationships/chartStyle"

    /// `imported`, linked to an embedded workbook and a style part as PowerPoint's charts are.
    private func withWorkbook(_ kind: ChartType = .column) throws -> Chart {
        var xml = try #require(imported(kind).raw)
        xml = xml.replacingOccurrences(of: "<c:extLst>", with: #"<c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData><c:extLst>"#)
        var c = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        c.kept = ChartKept(
            rels: [ChartRel(id: "rId1", relType: Self.book, target: "../embeddings/Book1.xlsx", part: "ppt/embeddings/Book1.xlsx", external: false),
                   ChartRel(id: "rId2", relType: Self.style, target: "style1.xml", part: "ppt/charts/style1.xml", external: false)],
            parts: [ChartPart(name: "ppt/embeddings/Book1.xlsx", contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", bytes: [1, 2, 3]),
                    ChartPart(name: "ppt/charts/style1.xml", contentType: "application/vnd.ms-office.chartstyle+xml", bytes: Array("<cs:chartStyle/>".utf8))]
        )
        return c
    }

    private func patched(_ c: Chart) throws -> (xml: String, back: Chart, kept: ChartKept) {
        let p = PPTXWrite.Charts.chartPart(c)
        let (out, kept) = (p.xml, p.kept)
        let k = try #require(kept, "patched, not regenerated")
        return (text(out), try #require(PPTXRead.readChartXML(out)), k)
    }

    @Test func newValuesGoIntoThePartAndTheWorkbookGoes() throws {
        var c = try withWorkbook()
        c.series[1].values = [9, 8, 7, 6]
        c.series[0].name = "Revenue"
        let (xml, back, kept) = try patched(c)
        #expect(same(back, c))
        #expect(xml.contains("<c:dTable>") && xml.contains(#"<c:ext uri="{KEEP}"/>"#))
        // The workbook would contradict the chart: it and its link go, the style part stays.
        #expect(!xml.contains("externalData"))
        #expect(kept.rels.map(\.id) == ["rId2"] && kept.parts.map(\.name) == ["ppt/charts/style1.xml"])
        // The ranges are the generator's.
        #expect(xml.contains("<c:f>Sheet1!$C$2:$C$5</c:f>"), "\(xml)")
    }

    @Test func anOptionsEditKeepsTheWorkbook() throws {
        var c = try withWorkbook()
        c.title = "Kept"
        let (xml, _, kept) = try patched(c)
        #expect(xml.contains("externalData") && kept.rels.count == 2)
    }

    @Test func seriesAndCategoriesAreAddedAndRemoved() throws {
        var c = try withWorkbook()
        c.categories = ["A", "B", "C", "D", "E"]
        for i in c.series.indices { c.series[i].values.append(1) }
        c.series.append(Series(name: "Added", values: [1, 2, 3, 4, 5]))
        let (xml, back, _) = try patched(c)
        #expect(same(back, c), "\(xml)")
        #expect(back.series.last?.fill == nil, "a new series takes nothing of its neighbour's look")
        // Every series keeps a distinct idx.
        let idx = xml.components(separatedBy: "<c:idx val=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
        #expect(Set(idx).count == idx.count && idx.count == 4, "\(idx)")
        // As `chart.data` removes series: each place keeps its look and takes the data given for it.
        let kept = [c.series[2], c.series[3]]
        c.series.removeLast(2)
        for i in c.series.indices {
            c.series[i].name = kept[i].name
            c.series[i].values = kept[i].values
        }
        let (_, back2, _) = try patched(c)
        #expect(back2.series.map(\.name) == ["Series 3", "Added"])
    }

    @Test func aScatterSeriesWithoutXValuesHasNone() throws {
        var c = try withWorkbook(.scatter)
        c.series.append(Series(name: "Added", values: [1, 2, 3, 4]))
        let (xml, back, _) = try patched(c)
        #expect(back.series.last?.xValues == [])
        #expect(xml.components(separatedBy: "<c:xVal>").count == 4, "the three series read keep theirs")
    }

    /// A combo chart whose last group isn't clustered columns can't take a new series where the reader
    /// would find it in order: the part is regenerated.
    @Test func aComboEndingInLinesRegeneratesForANewSeries() throws {
        var c = try withWorkbook(.combo)
        c.series[0].values[0] = 7
        _ = try patched(c)
        c.series.append(Series(name: "Added", values: [1, 2, 3, 4]))
        #expect(PPTXWrite.Charts.chartPart(c).kept == nil)
    }
}
