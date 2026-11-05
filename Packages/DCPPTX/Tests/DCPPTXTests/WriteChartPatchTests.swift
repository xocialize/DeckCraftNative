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
        var c = try imported()
        c.series[0].values[0] = 99
        #expect(!PPTXWrite.chartXML(c).preserved)
        var d = try imported()
        d.kind = .line
        #expect(!PPTXWrite.chartXML(d).preserved)
    }
}
