// The port's own (AB-T-0437): a series' gradient fill is written as read (deckcraft wrote its first stop as a
// solid fill), and a bubble chart keeps its scale and what its sizes measure.
import CNCore
import DCColor
import DCModel
@testable import DCPPTX
import Testing

@Suite struct WriteChartFillsTests {
    private func regenerated(_ c: Chart) throws -> (xml: String, back: Chart) {
        var c = c
        c.raw = nil
        let (out, preserved) = PPTXWrite.chartXML(c)
        #expect(!preserved)
        return (String(decoding: out, as: UTF8.self), try #require(PPTXRead.readChartXML(out)))
    }

    @Test func aGradientSeriesFillIsWrittenAsRead() throws {
        var c = Chart.sample(.column)
        let g = Gradient(
            stops: [GradientStop(pos: 0, color: .scheme(.accent3)), GradientStop(pos: 1, color: .rgb(Rgba.rgb(0x20, 0x60, 0x40)))],
            shape: .linear(angle: 90, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0]
        )
        c.series[0].fill = .gradient(g)
        let (xml, back) = try regenerated(c)
        #expect(xml.contains(#"<a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="accent3"/></a:gs><a:gs pos="100000"><a:srgbClr val="206040"/></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>"#))
        #expect(back.series.first?.fill == .gradient(g), "read back as written")
        // A gradient without stops has nothing to write.
        c.series[0].fill = .gradient(Gradient(stops: [], shape: .linear(angle: 0, scaled: false), rotateWithShape: true, tile: []))
        #expect(try !regenerated(c).xml.contains("gradFill"))
    }

    @Test func aBubbleChartKeepsItsScaleAndSizeMeasure() throws {
        var c = Chart.sample(.bubble)
        var (xml, back) = try regenerated(c)
        #expect(!xml.contains("bubbleScale") && !xml.contains("sizeRepresents"), "unset: nothing written, as deckcraft writes")
        #expect(back.bubbleScale == nil && !back.bubbleSizeWidth)
        c.bubbleScale = 150
        c.bubbleSizeWidth = true
        (xml, back) = try regenerated(c)
        #expect(xml.contains(#"<c:bubbleScale val="150"/><c:sizeRepresents val="w"/><c:axId "#), "in the schema's order, before the axes")
        #expect(back.bubbleScale == 150 && back.bubbleSizeWidth)
        // Hostile values are kept within the schema's 0–300 %.
        c.bubbleScale = 1e9
        #expect(try regenerated(c).back.bubbleScale == 300)
        c.bubbleScale = .nan
        #expect(try !regenerated(c).xml.contains("bubbleScale"))
    }
}
