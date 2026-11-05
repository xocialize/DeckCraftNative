// The port's own (AB-T-0438): data label positions and contents are read, written by the generator, and edited in
// a kept chart part. deckcraft reads and writes `c:showVal` alone, and a PowerPoint chart's `c:dLblPos` was lost on
// the first edit that regenerated the part.
import CNCore
import DCModel
@testable import DCPPTX
import Testing

@Suite struct WriteChartLabelsTests {
    private func regenerated(_ c: Chart) throws -> (xml: String, back: Chart) {
        var c = c
        c.raw = nil
        let (out, preserved) = PPTXWrite.chartXML(c)
        #expect(!preserved)
        return (String(decoding: out, as: UTF8.self), try #require(PPTXRead.readChartXML(out)))
    }

    private func labelled(_ kind: ChartType, _ o: LabelOptions?) -> Chart {
        var c = Chart.sample(kind)
        c.dataLabels = true
        c.labelOptions = o
        return c
    }

    @Test func defaultLabelsAreWrittenAsDeckcraftWritesThem() throws {
        let (xml, back) = try regenerated(labelled(.column, nil))
        #expect(xml.contains("<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"))
        #expect(back.labelOptions == nil && back.dataLabels)
    }

    @Test func positionAndContentsRoundTrip() throws {
        let o = LabelOptions(position: "inBase", seriesName: true, categoryName: true, hideValue: true, legendKey: true, leaderLines: true, separator: "; ")
        let (xml, back) = try regenerated(labelled(.column, o))
        #expect(xml.contains(#"<c:dLblPos val="inBase"/><c:showLegendKey val="1"/><c:showVal val="0"/><c:showCatName val="1"/><c:showSerName val="1"/><c:showPercent val="0"/><c:showBubbleSize val="0"/><c:separator>; </c:separator><c:showLeaderLines val="1"/></c:dLbls>"#))
        #expect(back.labelOptions == o && back.dataLabels && back.series.allSatisfy { $0.labelOptions == nil })
        // A callout: its box and its c15 shape.
        let callout = LabelOptions(categoryName: true, callout: true)
        let (cx, cb) = try regenerated(labelled(.column, callout))
        #expect(cx.contains(#"<c15:spPr><a:prstGeom prst="wedgeRectCallout"><a:avLst/></a:prstGeom></c15:spPr>"#))
        #expect(cb.labelOptions == callout)
    }

    @Test func aPositionTheGroupDoesNotTakeIsNotWritten() throws {
        // Outside End on stacked columns would make PowerPoint repair the file.
        let (xml, back) = try regenerated(labelled(.stackedColumn, LabelOptions(position: "outEnd", seriesName: true)))
        #expect(!xml.contains("dLblPos") && back.labelOptions == LabelOptions(seriesName: true))
        let (pie, pieBack) = try regenerated(labelled(.pie, LabelOptions(position: "bestFit", hideValue: true, percent: true)))
        #expect(pie.contains(#"<c:dLblPos val="bestFit"/>"#) && pieBack.labelOptions?.percent == true)
        let (dn, _) = try regenerated(labelled(.doughnut, LabelOptions(position: "ctr")))
        #expect(!dn.contains("dLblPos"), "a doughnut takes no position")
    }

    @Test func labelsShowingANameWithoutTheValueStillShow() throws {
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:pieChart><c:ser><c:idx val="0"/><c:order val="0"/><c:dLbls><c:dLblPos val="outEnd"/><c:showLegendKey val="0"/><c:showVal val="0"/><c:showCatName val="1"/><c:showSerName val="0"/><c:showPercent val="1"/></c:dLbls><c:val><c:numRef><c:numCache><c:ptCount val="1"/><c:pt idx="0"><c:v>3</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:pieChart></c:plotArea></c:chart></c:chartSpace>"#
        let c = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        let s = try #require(c.series.first)
        #expect(c.seriesDataLabels(s), "deckcraft read these as off (showVal 0)")
        #expect(c.labelOptions(s) == LabelOptions(position: "outEnd", categoryName: true, hideValue: true, percent: true))
    }

    @Test func aKeptPartIsEditedInPlace() throws {
        // A part with label formatting the model doesn't hold: an edit of the position keeps it.
        var c = labelled(.column, LabelOptions(position: "outEnd"))
        c.raw = nil
        let (first, _) = PPTXWrite.chartXML(c)
        var kept = try #require(PPTXRead.readChartXML(first))
        let formatted = String(decoding: first, as: UTF8.self).replacingOccurrences(of: "<c:dLbls><c:dLblPos", with: "<c:dLbls><c:numFmt formatCode=\"0.0\" sourceLinked=\"0\"/><c:dLblPos")
        kept.raw = formatted
        kept = try #require(PPTXRead.readChartXML(Array(formatted.utf8))).with { $0.raw = formatted }
        kept.labelOptions = LabelOptions(position: "ctr", seriesName: true, separator: " / ", callout: true)
        let (out, preserved) = PPTXWrite.chartXML(kept)
        let xml = String(decoding: out, as: UTF8.self)
        #expect(preserved, "patched, not regenerated")
        #expect(xml.contains(#"<c:numFmt formatCode="0.0" sourceLinked="0"/><c:dLblPos val="ctr"/>"#))
        #expect(xml.contains("<c:separator> / </c:separator>") && xml.contains("wedgeRectCallout"))
        #expect(try #require(PPTXRead.readChartXML(out)).labelOptions == kept.labelOptions)
    }
}

private extension Chart {
    func with(_ f: (inout Chart) -> Void) -> Chart {
        var c = self
        f(&c)
        return c
    }
}
