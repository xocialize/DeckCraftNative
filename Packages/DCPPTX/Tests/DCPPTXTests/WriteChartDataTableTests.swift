// The port's own (AB-T-0439): a chart's data table (`c:dTable`) is read, written by the generator and edited in a
// kept part. deckcraft doesn't model it, so a PowerPoint chart's table was lost on the first regenerating edit.
import CNCore
import DCModel
@testable import DCPPTX
import Testing

@Suite struct WriteChartDataTableTests {
    private func regenerated(_ c: Chart) throws -> (xml: String, back: Chart) {
        var c = c
        c.raw = nil
        let (out, preserved) = PPTXWrite.chartXML(c)
        #expect(!preserved)
        return (String(decoding: out, as: UTF8.self), try #require(PPTXRead.readChartXML(out)))
    }

    @Test func aDataTableRoundTripsAfterTheAxes() throws {
        var c = Chart.sample(.column)
        #expect(try !regenerated(c).xml.contains("dTable"), "none unless set, as deckcraft writes")
        c.dataTable = DataTable(keys: false, horizontal: true, vertical: false, outline: true)
        let (xml, back) = try regenerated(c)
        #expect(xml.contains(#"</c:valAx><c:dTable><c:showHorzBorder val="1"/><c:showVertBorder val="0"/><c:showOutline val="1"/><c:showKeys val="0"/></c:dTable></c:plotArea>"#))
        #expect(back.dataTable == c.dataTable)
    }

    @Test func aKeptPartGainsLosesAndChangesItsTable() throws {
        var c = Chart.sample(.line)
        c.raw = nil
        let first = String(decoding: PPTXWrite.chartXML(c).0, as: UTF8.self)
        // A plot fill the generator wouldn't write keeps the part honest: the edit must patch, not regenerate.
        let raw = first.replacingOccurrences(of: "</c:plotArea>", with: "<c:spPr><a:noFill/></c:spPr></c:plotArea>")
        var kept = try #require(PPTXRead.readChartXML(Array(raw.utf8)))
        kept.raw = raw
        kept.dataTable = .default
        let (added, p1) = PPTXWrite.chartXML(kept)
        let addedXML = String(decoding: added, as: UTF8.self)
        #expect(p1 && addedXML.contains(#"</c:valAx><c:dTable><c:showHorzBorder val="1"/><c:showVertBorder val="1"/><c:showOutline val="1"/><c:showKeys val="1"/></c:dTable><c:spPr>"#))
        // Its formatting stays when a switch changes.
        let styled = addedXML.replacingOccurrences(of: #"<c:showKeys val="1"/></c:dTable>"#, with: #"<c:showKeys val="1"/><c:spPr><a:noFill/></c:spPr></c:dTable>"#)
        kept = try #require(PPTXRead.readChartXML(Array(styled.utf8)))
        kept.raw = styled
        kept.dataTable?.keys = false
        let (changed, p2) = PPTXWrite.chartXML(kept)
        #expect(p2 && String(decoding: changed, as: UTF8.self).contains(#"<c:showKeys val="0"/><c:spPr><a:noFill/></c:spPr></c:dTable>"#))
        kept.dataTable = nil
        let (removed, p3) = PPTXWrite.chartXML(kept)
        #expect(p3 && !String(decoding: removed, as: UTF8.self).contains("dTable"))
    }

    @Test func missingSwitchesAreOff() throws {
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:order val="0"/><c:val><c:numRef><c:numCache><c:ptCount val="1"/><c:pt idx="0"><c:v>3</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart><c:dTable><c:showKeys val="1"/></c:dTable></c:plotArea></c:chart></c:chartSpace>"#
        let c = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        #expect(c.dataTable == DataTable(keys: true, horizontal: false, vertical: false, outline: false))
    }
}
