// DCPPTXTests — the style parts DeckCraftNative gives every `chartEx` part, where deckcraft writes none.
// Without a `chartStyle` and a `chartColorStyle` relationship PowerPoint for Mac (16.114) asks to repair
// the file and drops the slide's content; with empty ones it opens the slide but draws the series unfilled.
// Found with `Tools/pptx/powerpoint-check.sh` on 2026-10-27 (PORT-STATUS.md, decisions).
import DCModel
import Testing
@testable import DCPPTX

/// The parts the writer adds, byte for byte. Each literal is written one element per line for reading;
/// the part itself has no line breaks after the declaration.
enum ChartexStyleExpected {
    static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    static let style = declaration + #"""
<cs:chartStyle xmlns:cs="http://schemas.microsoft.com/office/drawing/2012/chartStyle" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" id="1">
<cs:axisTitle><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:defRPr sz="1330"/></cs:axisTitle>
<cs:categoryAxis><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:spPr><a:noFill/><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="15000"/><a:lumOff val="85000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr>
<cs:defRPr sz="1197"/></cs:categoryAxis>
<cs:chartArea><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:ln><a:noFill/></a:ln></cs:spPr>
<cs:defRPr sz="1330"/></cs:chartArea>
<cs:dataLabel><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="75000"/><a:lumOff val="25000"/></a:schemeClr></cs:fontRef>
<cs:defRPr sz="1197"/></cs:dataLabel>
<cs:dataLabelCallout><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="dk1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="lt1"/></a:solidFill><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="dk1"><a:lumMod val="25000"/><a:lumOff val="75000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr>
<cs:defRPr sz="1197"/></cs:dataLabelCallout>
<cs:dataPoint><cs:lnRef idx="0"/><cs:fillRef idx="1"><cs:styleClr val="auto"/></cs:fillRef>
<cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:round/></a:ln></cs:spPr></cs:dataPoint>
<cs:dataPoint3D><cs:lnRef idx="0"/><cs:fillRef idx="1"><cs:styleClr val="auto"/></cs:fillRef>
<cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></cs:spPr></cs:dataPoint3D>
<cs:dataPointLine><cs:lnRef idx="0"><cs:styleClr val="auto"/></cs:lnRef>
<cs:fillRef idx="1"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="28575" cap="flat"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:round/></a:ln></cs:spPr></cs:dataPointLine>
<cs:dataPointMarker><cs:lnRef idx="0"><cs:styleClr val="auto"/></cs:lnRef>
<cs:fillRef idx="1"><cs:styleClr val="auto"/></cs:fillRef>
<cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:round/></a:ln></cs:spPr></cs:dataPointMarker>
<cs:dataPointMarkerLayout symbol="circle" size="5"/>
<cs:dataPointWireframe><cs:lnRef idx="0"><cs:styleClr val="auto"/></cs:lnRef>
<cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:round/></a:ln></cs:spPr></cs:dataPointWireframe>
<cs:dataTable><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:spPr><a:noFill/><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="15000"/><a:lumOff val="85000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr>
<cs:defRPr sz="1197"/></cs:dataTable>
<cs:downBar><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="dk1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></a:solidFill><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:downBar>
<cs:dropLine><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="35000"/><a:lumOff val="65000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:dropLine>
<cs:errorBar><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:errorBar>
<cs:floor><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr></cs:floor>
<cs:gridlineMajor><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="15000"/><a:lumOff val="85000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:gridlineMajor>
<cs:gridlineMinor><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="5000"/><a:lumOff val="95000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:gridlineMinor>
<cs:hiLoLine><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="75000"/><a:lumOff val="25000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:hiLoLine>
<cs:leaderLine><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="35000"/><a:lumOff val="65000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:leaderLine>
<cs:legend><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:defRPr sz="1197"/></cs:legend>
<cs:plotArea><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr></cs:plotArea>
<cs:plotArea3D><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr></cs:plotArea3D>
<cs:seriesAxis><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr>
<cs:defRPr sz="1197"/></cs:seriesAxis>
<cs:seriesLine><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="35000"/><a:lumOff val="65000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:seriesLine>
<cs:title><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:defRPr sz="1862"/></cs:title>
<cs:trendline><cs:lnRef idx="0"><cs:styleClr val="auto"/></cs:lnRef>
<cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:ln w="19050" cap="rnd"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="sysDot"/><a:round/></a:ln></cs:spPr></cs:trendline>
<cs:trendlineLabel><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:defRPr sz="1197"/></cs:trendlineLabel>
<cs:upBar><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:solidFill><a:schemeClr val="lt1"/></a:solidFill><a:ln w="9525" cap="flat"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></a:solidFill><a:round/></a:ln></cs:spPr></cs:upBar>
<cs:valueAxis><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr>
<cs:defRPr sz="1197"/></cs:valueAxis>
<cs:wall><cs:lnRef idx="0"/><cs:fillRef idx="0"/><cs:effectRef idx="0"/><cs:fontRef idx="minor"><a:schemeClr val="tx1"/></cs:fontRef>
<cs:spPr><a:noFill/><a:ln><a:noFill/></a:ln></cs:spPr></cs:wall>
</cs:chartStyle>
"""#.split(separator: "\n").joined()

    static let colors = declaration + #"""
<cs:colorStyle xmlns:cs="http://schemas.microsoft.com/office/drawing/2012/chartStyle" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" meth="cycle" id="10">
<a:schemeClr val="accent1"/><a:schemeClr val="accent2"/><a:schemeClr val="accent3"/><a:schemeClr val="accent4"/><a:schemeClr val="accent5"/><a:schemeClr val="accent6"/>
<cs:variation/><cs:variation><a:lumMod val="60000"/></cs:variation><cs:variation><a:lumMod val="80000"/><a:lumOff val="20000"/></cs:variation><cs:variation><a:lumMod val="80000"/></cs:variation><cs:variation><a:lumMod val="60000"/><a:lumOff val="40000"/></cs:variation><cs:variation><a:lumMod val="50000"/></cs:variation>
</cs:colorStyle>
"""#.split(separator: "\n").joined()

    /// The new relationships part of `ppt/charts/chartExN.xml`.
    static func rels(_ n: Int) -> String {
        declaration + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.microsoft.com/office/2011/relationships/chartStyle" Target="style\#(n).xml"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.microsoft.com/office/2011/relationships/chartColorStyle" Target="colors\#(n).xml"/>"#
            + "</Relationships>"
    }

    /// The `[Content_Types].xml` overrides that follow `chartExN.xml`'s.
    static func overrides(_ n: Int) -> String {
        #"<Override PartName="/ppt/charts/style\#(n).xml" ContentType="application/vnd.ms-office.chartstyle+xml"/>"#
            + #"<Override PartName="/ppt/charts/colors\#(n).xml" ContentType="application/vnd.ms-office.chartcolorstyle+xml"/>"#
    }

    /// Every part the writer adds to a package beside its `chartEx` parts.
    static func isAdded(_ name: String) -> Bool {
        name.wholeMatch(of: /ppt\/charts\/(style|colors)\d+\.xml|ppt\/charts\/_rels\/chartEx\d+\.xml\.rels/) != nil
    }
}

private let rtStyle = "http://schemas.microsoft.com/office/2011/relationships/chartStyle"
private let rtColors = "http://schemas.microsoft.com/office/2011/relationships/chartColorStyle"

/// The cs:chartStyle entries, in the schema's order; each is required.
private let styleEntries = [
    "axisTitle", "categoryAxis", "chartArea", "dataLabel", "dataLabelCallout", "dataPoint", "dataPoint3D",
    "dataPointLine", "dataPointMarker", "dataPointMarkerLayout", "dataPointWireframe", "dataTable", "downBar",
    "dropLine", "errorBar", "floor", "gridlineMajor", "gridlineMinor", "hiLoLine", "leaderLine", "legend",
    "plotArea", "plotArea3D", "seriesAxis", "seriesLine", "title", "trendline", "trendlineLabel", "upBar",
    "valueAxis", "wall",
]

/// A one-slide deck holding one chart of `kind`.
private func chartDeck(_ kind: ChartType) throws -> Presentation {
    var p = newPresentation(nil)
    p.slides.removeAll()
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    var slide = try #require(newSlide(&p, layout), "slide")
    var shape = IT.shape(&p, "Chart", 40, 40, 400, 300)
    shape.kind = .chart(Chart.sample(kind))
    slide.shapes.append(shape)
    p.slides.append(slide)
    return p
}

/// The relationships of one part, parsed.
private func rels(_ pkg: [UInt8], _ part: String) -> [(id: String, ty: String, target: String)] {
    let path = OPC.relsPath(part)
    guard let bytes = IT.part(pkg, path) else { return [] }
    return OPC.relsFromBytes(bytes, part).items.map { ($0.id, $0.ty, $0.target) }
}

/// The chartEx part's style and colour style targets, after checking there is exactly one of each.
private func styleTargets(_ pkg: [UInt8], _ chartex: String) throws -> (style: String, colors: String) {
    let r = rels(pkg, chartex)
    let styles = r.filter { $0.ty == rtStyle }, colors = r.filter { $0.ty == rtColors }
    try #require(styles.count == 1 && colors.count == 1, "\(chartex): \(r)")
    #expect(Set(r.map(\.id)).count == r.count, "\(chartex): duplicate relationship ids \(r)")
    return (styles[0].target, colors[0].target)
}

@Suite struct ChartexStyleTests {
    /// Every Office 2016 kind gets a style part and a colour style part, related from its `chartEx` part
    /// and declared in the content types: the structure PowerPoint needs to open the slide.
    @Test(arguments: [ChartType.waterfall, .funnel, .treemap, .sunburst, .histogram, .pareto, .boxWhisker, .regionMap])
    func chartexGetsStyleParts(_ kind: ChartType) throws {
        let pkg = try PPTX.export(chartDeck(kind))
        let chartex = "ppt/charts/chartEx1.xml"
        try #require(IT.part(pkg, chartex) != nil, "\(kind): no chartEx part")
        let (style, colors) = try styleTargets(pkg, chartex)
        #expect(style == "ppt/charts/style1.xml" && colors == "ppt/charts/colors1.xml")
        #expect(IT.text(pkg, style) == ChartexStyleExpected.style)
        #expect(IT.text(pkg, colors) == ChartexStyleExpected.colors)
        #expect(IT.text(pkg, OPC.relsPath(chartex)) == ChartexStyleExpected.rels(1))
        let types = IT.text(pkg, "[Content_Types].xml")
        #expect(types.has(#"<Override PartName="/ppt/charts/chartEx1.xml" ContentType="application/vnd.ms-office.chartex+xml"/>"# + ChartexStyleExpected.overrides(1)))
    }

    /// The style part has every entry the schema requires, in its order, and the colour style at least one
    /// colour: PowerPoint repairs a file whose parts are empty.
    @Test func stylePartsFollowTheSchema() throws {
        let style = try parseXML(Array(ChartexStyleExpected.style.utf8)).root
        #expect(style.is("chartStyle"))
        let names = style.elements.map { String($0.local) }
        #expect(names == styleEntries)
        for e in style.elements where !e.is("dataPointMarkerLayout") {
            let refs = e.elements.prefix(4).map { String($0.local) }
            #expect(refs == ["lnRef", "fillRef", "effectRef", "fontRef"], "\(e.name)")
        }
        let colors = try parseXML(Array(ChartexStyleExpected.colors.utf8)).root
        #expect(colors.is("colorStyle") && colors.attr("meth") == "cycle")
        #expect(colors.elements.contains { $0.is("schemeClr") })
    }

    /// Plain charts keep deckcraft's package: no style parts.
    @Test func plainChartHasNoStyleParts() throws {
        let pkg = try PPTX.export(chartDeck(.column))
        #expect(rels(pkg, "ppt/charts/chart1.xml").isEmpty)
        #expect(IT.part(pkg, "ppt/charts/style1.xml") == nil)
    }

    /// An unchanged `chartEx` read back keeps the style parts it came with and gets no second pair.
    @Test func keptChartexKeepsItsStyle() throws {
        let once = try PPTX.export(chartDeck(.waterfall))
        let twice = try PPTX.export(PPTX.import(once))
        let (style, colors) = try styleTargets(twice, "ppt/charts/chartEx1.xml")
        #expect(style.hasPrefix("ppt/charts/kept") && colors.hasPrefix("ppt/charts/kept"), "\(style) \(colors)")
        #expect(IT.text(twice, style) == ChartexStyleExpected.style)
        #expect(IT.part(twice, "ppt/charts/style1.xml") == nil)
    }

    /// An unchanged `chartEx` from a file that had no style parts (deckcraft's own) gets them on export.
    @Test func keptChartexWithoutStyleGetsOne() throws {
        let entries = try IT.entries(PPTX.export(chartDeck(.funnel)))
        let bare = try IT.zip(entries.compactMap { e -> (name: String, data: [UInt8])? in
            if ChartexStyleExpected.isAdded(e.name) { return nil }
            if e.name == "[Content_Types].xml" {
                let t = String(decoding: e.data, as: UTF8.self).replace(ChartexStyleExpected.overrides(1), "")
                return (e.name, Array(t.utf8))
            }
            return e
        })
        try #require(rels(bare, "ppt/charts/chartEx1.xml").isEmpty)
        let pkg = try PPTX.export(PPTX.import(bare))
        let (style, colors) = try styleTargets(pkg, "ppt/charts/chartEx1.xml")
        #expect(IT.text(pkg, style) == ChartexStyleExpected.style)
        #expect(IT.text(pkg, colors) == ChartexStyleExpected.colors)
    }
}
