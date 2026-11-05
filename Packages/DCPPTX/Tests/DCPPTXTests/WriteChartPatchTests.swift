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

    // MARK: - Axes, gap and overlap, up/down bars, trendlines, error bars (AB-T-0436)

    /// Each setting written into the kept part reads back as the model, and the data table and extension list
    /// the model doesn't hold stay.
    @Test func axisSettingsAreWrittenIntoThePart() throws {
        var c = try imported()
        c.axisTitles = Pair("Quarter", "Revenue")
        c.minorGridlines = true
        c.yMin = 0
        c.yMax = 120
        c.yMajor = 20
        c.yFormat = "#,##0"
        c.catReversed = true
        let (xml, back) = try written(c)
        #expect(same(back, c))
        #expect(xml.contains("<c:dTable>") && xml.contains(#"<c:ext uri="{KEEP}"/>"#))
        #expect(xml.contains(#"<c:max val="120"/><c:min val="0"/>"#) && xml.contains(#"<c:majorUnit val="20"/>"#))
        #expect(xml.contains(#"<c:orientation val="maxMin"/>"#) && xml.contains(###"<c:numFmt formatCode="#,##0" sourceLinked="0"/>"###))
        #expect(xml.contains(#"<a:bodyPr rot="-5400000" vert="horz"/>"#), "the vertical axis's title reads upwards")
        // Back to automatic, on a log scale; the titles go.
        var d = back
        d.raw = c.raw
        (d.yMin, d.yMax, d.yMajor, d.yFormat, d.yLogBase, d.axisTitles, d.minorGridlines, d.catReversed) = (nil, nil, nil, nil, 10, Pair(nil, nil), false, false)
        let (xml2, back2) = try written(d)
        // An axis that follows the data reads as the data's format, here PowerPoint's General.
        #expect(back2.yFormat == "General")
        d.yFormat = "General"
        #expect(same(back2, d))
        #expect(xml2.contains(#"<c:logBase val="10"/>"#) && !xml2.contains("<c:min ") && !xml2.contains("<c:majorUnit") && !xml2.contains("<c:minorGridlines"))
        #expect(xml2.contains("<c:dTable>"))
    }

    @Test func gapOverlapAndUpDownBarsAreWrittenIntoThePart() throws {
        var c = try imported()
        c.gapWidth = 0.6
        c.overlap = -0.25
        let (xml, back) = try written(c)
        #expect(same(back, c))
        #expect(xml.contains(#"<c:gapWidth val="60"/><c:overlap val="-25"/>"#) && xml.contains("<c:dTable>"))
        var l = try imported(.line)
        l.upDownBars = true
        let (xml2, back2) = try written(l)
        #expect(back2.upDownBars && same(back2, l))
        #expect(xml2.contains("<c:upDownBars><c:gapWidth val=\"150\"/><c:upBars/><c:downBars/></c:upDownBars><c:marker"))
        var off = back2
        off.upDownBars = false
        let (xml3, back3) = try written(off)
        #expect(!back3.upDownBars && !xml3.contains("upDownBars"))
        // A column chart has nowhere to put them: the part stays, without them.
        var col = try imported()
        col.upDownBars = true
        let (xml4, _) = try written(col)
        #expect(!xml4.contains("upDownBars") && xml4.contains("<c:dTable>"))
    }

    @Test func aSeriesTrendlineAndErrorBarsAreWrittenIntoThePart() throws {
        var c = try imported()
        // PowerPoint's line formatting on the trendline and error bars the edit replaces stays.
        let look = #"<c:spPr><a:ln w="12700"/></c:spPr>"#
        var xml0 = try #require(c.raw)
        xml0 = xml0.replacingOccurrences(of: "<c:cat>", with: #"<c:trendline>\#(look)<c:trendlineType val="exp"/></c:trendline><c:errBars><c:errBarType val="both"/><c:errValType val="fixedVal"/><c:noEndCap val="0"/><c:val val="1"/>\#(look)</c:errBars><c:cat>"#)
        c = try #require(PPTXRead.readChartXML(Array(xml0.utf8)))
        #expect(c.series.allSatisfy { $0.trendlines.first?.kind == .exp && $0.errorBars != nil })
        c.series[1].trendlines = [Trendline(kind: .movingAvg, period: 2, dispEq: false, dispRSqr: false)]
        c.series[0].errorBars = ErrorBars(barType: "plus", valType: "percentage", value: 5, plus: [], minus: [], endCap: true)
        c.series[2].trendlines = []
        c.series[2].errorBars = nil
        let (xml, back) = try written(c)
        #expect(same(back, c))
        // The equation and R² switches always written: PowerPoint reads a missing one as on.
        #expect(xml.contains(#"<c:trendline>\#(look)<c:trendlineType val="movingAvg"/><c:period val="2"/><c:dispRSqr val="0"/><c:dispEq val="0"/></c:trendline>"#))
        #expect(xml.contains(#"<c:errBars><c:errBarType val="plus"/><c:errValType val="percentage"/><c:noEndCap val="0"/><c:val val="5"/>\#(look)</c:errBars>"#))
        #expect(xml.contains("<c:dTable>"))
    }

    /// A line chart's up/down bars from the generator, read back (deckcraft has a stock chart's only).
    @Test func aNewLineChartKeepsItsUpDownBars() throws {
        var c = Chart.sample(.line)
        c.upDownBars = true
        let xml = text(PPTXWrite.chartXML(c).xml)
        #expect(xml.contains("<c:upDownBars>"))
        #expect(try #require(PPTXRead.readChartXML(Array(xml.utf8))).upDownBars)
        #expect(!text(PPTXWrite.chartXML(Chart.sample(.line)).xml).contains("upDownBars"))
    }

    /// A new chart's major unit is written (deckcraft writes the secondary axis's only).
    @Test func aNewChartKeepsItsMajorUnit() throws {
        var c = Chart.sample(.column)
        c.yMajor = 0.5
        let xml = text(PPTXWrite.chartXML(c).xml)
        #expect(xml.contains(#"<c:crossBetween val="between"/><c:majorUnit val="0.5"/></c:valAx>"#))
        #expect(try #require(PPTXRead.readChartXML(Array(xml.utf8))).yMajor == 0.5)
        #expect(!text(PPTXWrite.chartXML(Chart.sample(.column)).xml).contains("majorUnit"))
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
