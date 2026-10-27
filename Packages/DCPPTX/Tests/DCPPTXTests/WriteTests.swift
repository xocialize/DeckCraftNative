// The tests of deckcraft crates/pptx/src/write/dml.rs, shapes.rs and chart.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCModel
@testable import DCPPTX
import Testing

/// `str::matches(needle).count()`: non-overlapping occurrences.
private func occurrences(_ hay: String, _ needle: String) -> Int {
    let h = Array(hay.utf8), n = Array(needle.utf8)
    guard !n.isEmpty, h.count >= n.count else { return 0 }
    var i = 0, count = 0
    while i + n.count <= h.count {
        if h[i ..< i + n.count].elementsEqual(n) {
            count += 1
            i += n.count
        } else {
            i += 1
        }
    }
    return count
}

private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

@Suite struct WriteDMLTests {
    @Test func unknownPresetAndSystemNamesSaveAsBlackAndWindowText() {
        func write(_ base: ColorBase) -> String {
            var w = W.frag()
            PPTXWrite.DML.color(&w, ColorRef(base: base, mods: []))
            return w.s
        }
        #expect(write(.preset(name: "notAColor")) == #"<a:prstClr val="black"/>"#)
        #expect(write(.preset(name: "darkBlue")) == #"<a:prstClr val="darkBlue"/>"#)
        let last = Rgba.rgb(0x12, 0x34, 0x56)
        #expect(write(.system(name: "notAColor", last: last)) == #"<a:sysClr val="windowText" lastClr="123456"/>"#)
        #expect(write(.system(name: "3dLight", last: last)) == #"<a:sysClr val="3dLight" lastClr="123456"/>"#)
    }
}

@Suite struct WriteShapesTests {
    /// PowerPoint asks to repair a `star5` whose guide list lacks `hf`/`vf` (found black-box).
    @Test func presetGuidesAreComplete() {
        var w = W.frag()
        PPTXWrite.Shapes.geometry(&w, .preset(name: "star5", adj: [20000.0]))
        #expect(
            w.s
                == #"<a:prstGeom prst="star5"><a:avLst><a:gd name="adj" fmla="val 20000"/><a:gd name="hf" fmla="val 105146"/><a:gd name="vf" fmla="val 110557"/></a:avLst></a:prstGeom>"#
        )
        w = W.frag()
        PPTXWrite.Shapes.geometry(&w, .preset(name: "rightArrow", adj: [10000.0]))
        #expect(w.s.contains(#"name="adj1" fmla="val 10000""#) && w.s.contains(#"name="adj2" fmla="val 50000""#), "\(w.s)")
        w = W.frag()
        PPTXWrite.Shapes.geometry(&w, .preset(name: "textBox", adj: []))
        #expect(w.s == #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>"#)
    }
}

@Suite struct WriteChartRegionMapTests {
    /// A region map part as PowerPoint writes it (our own numbers; the cached geography is a
    /// stand-in blob).
    static let map = #"<cx:chartSpace xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex"><cx:chartData><cx:data id="0"><cx:strDim type="cat"><cx:f>Sheet1!$A$2:$A$4</cx:f><cx:lvl ptCount="3"><cx:pt idx="0">Minsk</cx:pt><cx:pt idx="1">Brest</cx:pt><cx:pt idx="2">Gomel</cx:pt></cx:lvl></cx:strDim><cx:numDim type="colorVal"><cx:f>Sheet1!$B$2:$B$4</cx:f><cx:lvl ptCount="3" formatCode="General"><cx:pt idx="0">12</cx:pt><cx:pt idx="1">5</cx:pt><cx:pt idx="2">8</cx:pt></cx:lvl></cx:numDim></cx:data></cx:chartData><cx:chart><cx:title pos="t" align="ctr" overlay="0"/><cx:plotArea><cx:plotAreaRegion><cx:series layoutId="regionMap" uniqueId="{00000000-0000-4000-8000-000000000001}"><cx:tx><cx:txData><cx:f>Sheet1!$B$1</cx:f><cx:v>Sales</cx:v></cx:txData></cx:tx><cx:dataId val="0"/><cx:layoutPr><cx:geography cultureLanguage="en-US" cultureRegion="BY" attribution="Powered by Bing"><cx:geoCache provider="{E9337A44-BEBE-4D9F-B70C-5C5E7DAFC167}"><cx:binary>ZGVja2NyYWZ0LXRlc3Q=</cx:binary></cx:geoCache></cx:geography></cx:layoutPr></cx:series></cx:plotAreaRegion></cx:plotArea><cx:legend pos="r" align="min" overlay="0"/></cx:chart></cx:chartSpace>"#

    @Test func regionMapsKeepTheirGeographyThroughSaveAndEdit() throws {
        let c = try #require(PPTXRead.readChartexXML(Array(Self.map.utf8)), "a region map is read")
        #expect(c.kind == .regionMap)
        #expect(c.categories == ["Minsk", "Brest", "Gomel"])
        #expect(c.series.first.map(\.values) == [12.0, 5.0, 8.0])
        // Unchanged: written back as read.
        let kept = text(PPTXWrite.Charts.chartexXML(c) ?? [])
        #expect(kept.contains("ZGVja2NyYWZ0LXRlc3Q=") && kept.contains("cultureRegion=\"BY\""), "\(kept)")
        // Edited: rebuilt from the model, with the geography carried over.
        var e = c
        if !e.series.isEmpty, e.series[0].values.count > 1 {
            e.series[0].values[1] = 20.0
        }
        let built = text(PPTXWrite.Charts.chartexXML(e) ?? [])
        #expect(built.contains("<cx:geoCache") && built.contains("ZGVja2NyYWZ0LXRlc3Q=") && built.contains("colorVal"), "\(built)")
        #expect(!built.contains("<cx:axis"), "\(built)")
        let back = try #require(PPTXRead.readChartexXML(Array(built.utf8)), "the rebuilt part reads")
        #expect(back.kind == .regionMap)
        #expect(back.series.first.flatMap { $0.values.count > 1 ? $0.values[1] : nil } == 20.0)
    }
}

@Suite struct WriteChartTests {
    /// The chart's text colour is written where PowerPoint keeps it (`c:txPr` on the axes, legend,
    /// data labels and chart, the title's run defaults) and read back as the same colour.
    @Test func chartTextColourRoundTrips() throws {
        var c = Chart.sample(.column)
        c.title = "Revenue"
        c.legend = "b"
        c.dataLabels = true
        c.axisTitles = Pair("Quarter", "EUR")
        let tinted = ColorRef.scheme(.accent2).with(.lumMod(75000))
        c.textColor = tinted
        let xml = text(PPTXWrite.chartXML(c).xml)
        // Axes (2), legend, data labels and the chart root; a title keeps it in its rich text.
        #expect(occurrences(xml, "<c:txPr>") >= 5, "\(xml)")
        #expect(xml.contains(#"<a:schemeClr val="accent2"><a:lumMod val="75000"/></a:schemeClr>"#), "\(xml)")
        #expect(xml.contains("<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr><a:solidFill>"), "\(xml)")
        let back = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        #expect(back.textColor == tinted)
        // An RGB colour and no colour at all round-trip too.
        c.textColor = .rgb(.rgb(255, 255, 255))
        let rgbXML = PPTXWrite.chartXML(c).xml
        let rgbBack = try #require(PPTXRead.readChartXML(rgbXML))
        #expect(rgbBack.textColor == c.textColor)
        c.textColor = nil
        let none = text(PPTXWrite.chartXML(c).xml)
        #expect(!none.contains("<c:txPr>"), "\(none)")
        let noneBack = try #require(PPTXRead.readChartXML(Array(none.utf8)))
        #expect(noneBack.textColor == nil)
    }

    /// An imported chart's `c:txPr` colour survives an edit that rebuilds the part from the model
    /// (the colour used to be read but never written, so a save after any edit lost it).
    @Test func importedTextColourSurvivesAnEditAndASave() throws {
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:val><c:numRef><c:numCache><c:ptCount val="1"/><c:pt idx="0"><c:v>1</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart><c:catAx><c:axId val="1"/><c:txPr><a:bodyPr/><a:p><a:pPr><a:defRPr><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></a:solidFill></a:defRPr></a:pPr></a:p></c:txPr><c:crossAx val="2"/></c:catAx><c:valAx><c:axId val="2"/><c:crossAx val="1"/></c:valAx></c:plotArea></c:chart></c:chartSpace>"#
        let c = try #require(PPTXRead.readChartXML(Array(xml.utf8)))
        let grey = ColorRef.scheme(.tx1).with(.lumMod(65000)).with(.lumOff(35000))
        #expect(c.textColor == grey)
        // Unchanged: the part is written back as read.
        #expect(PPTXWrite.chartXML(c).preserved)
        // Edited (a title; the editor drops `raw` on any edit): rebuilt with the colour.
        var e = c
        e.title = "Units"
        e.raw = nil
        let (out, kept) = PPTXWrite.chartXML(e)
        #expect(!kept)
        let back = try #require(PPTXRead.readChartXML(out))
        #expect(back.textColor == grey)
        #expect(back.title == "Units")
    }

    @Test func reversedCategoryAxisRoundTrips() throws {
        var c = Chart.sample(.bar)
        c.catReversed = true
        let xml = PPTXWrite.chartXML(c).xml
        #expect(text(xml).contains(#"<c:orientation val="maxMin"/>"#))
        let back = try #require(PPTXRead.readChartXML(xml))
        #expect(back.catReversed)
        c.catReversed = false
        let plain = try #require(PPTXRead.readChartXML(PPTXWrite.chartXML(c).xml))
        #expect(!plain.catReversed)
    }
}
