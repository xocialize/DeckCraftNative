// The port's own: the chart types the reader knows are written back (AB-T-0434). deckcraft wrote a surface chart
// as an area chart, a 100 % line as a stacked one, 3-D and of-pie charts flat, and every combo series on one axis.
import CNCore
import DCModel
@testable import DCPPTX
import Testing

@Suite struct WriteChartTypesTests {
    private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    /// Written from the model (nothing kept), and read back.
    private func regenerated(_ c: Chart) throws -> (xml: String, back: Chart) {
        var c = c
        c.raw = nil
        let (out, preserved) = PPTXWrite.chartXML(c)
        #expect(!preserved)
        return (text(out), try #require(PPTXRead.readChartXML(out)))
    }

    /// A chart read back is saved again unchanged: what the first save wrote is all the second one writes.
    /// (The first read fills in what the generator wrote, such as the caches' number formats.)
    private func stable(_ back: Chart) throws -> Bool {
        var again = try regenerated(back).back
        var b = back
        (again.raw, b.raw, again.kept, b.kept) = (nil, nil, ChartKept(), ChartKept())
        return PPTXWrite.Charts.labelsNormalized(again) == PPTXWrite.Charts.labelsNormalized(b)
    }

    private func count(_ xml: String, _ s: String) -> Int { xml.components(separatedBy: s).count - 1 }

    @Test func percentLinesAndAreasStayPercent() throws {
        for kind in [ChartType.percentLine, .percentArea] {
            let c = Chart.sample(kind)
            let (xml, back) = try regenerated(c)
            #expect(xml.contains(#"<c:grouping val="percentStacked"/>"#), "\(kind)")
            #expect(xml.contains(#"formatCode="0%""#), "\(kind): the value axis reads in percent")
            #expect(try back.kind == kind && stable(back), "\(kind)")
            let r = c.valueRange()
            #expect(r.0 == 0 && r.1 == 1)
        }
    }

    @Test func aSurfaceIsWrittenAsASurfaceNotAnArea() throws {
        var c = Chart.sample(.surface)
        let (xml, back) = try regenerated(c)
        #expect(xml.contains("<c:surfaceChart>") && !xml.contains("<c:areaChart>"))
        // A contour: PowerPoint's top-down view, a depth axis, and nothing a surface group can't hold.
        #expect(xml.contains(#"<c:view3D><c:rotX val="90"/><c:rotY val="0"/><c:rAngAx val="0"/><c:perspective val="0"/></c:view3D>"#))
        #expect(xml.contains("<c:serAx>") && count(xml, "<c:axId ") == 6)
        #expect(!xml.contains("<c:varyColors") && !xml.contains("<c:dLbls>"))
        #expect(try back.kind == .surface && back.threeD == nil && !back.wireframe && stable(back))

        c.wireframe = true
        c.threeD = Chart3D(rotX: 15, rotY: 20, perspective: 30)
        let (xml3, back3) = try regenerated(c)
        #expect(xml3.contains("<c:surface3DChart>") && xml3.contains(#"<c:wireframe val="1"/>"#))
        #expect(xml3.contains(#"<c:view3D><c:rotX val="15"/><c:rotY val="20"/><c:perspective val="30"/></c:view3D>"#))
        #expect(try back3.wireframe && back3.threeD?.rotY == 20 && stable(back3))
    }

    @Test func threeDGroupsKeepTheirViewAndDepth() throws {
        var col = Chart.sample(.column)
        col.threeD = Chart3D(rotX: 15, rotY: 20, rAngAx: false, gapDepth: 150, shape: "box")
        let (xml, back) = try regenerated(col)
        #expect(xml.contains("<c:bar3DChart>") && xml.contains(#"<c:grouping val="clustered"/>"#))
        #expect(xml.contains(#"<c:gapDepth val="150"/><c:shape val="box"/>"#) && !xml.contains("<c:overlap"))
        // PowerPoint's 3-D Clustered Column: a third axis id of 0, no depth axis.
        #expect(xml.contains(#"<c:axId val="0"/>"#) && !xml.contains("<c:serAx>"))
        #expect(try back.threeD == col.threeD && stable(back))

        // 3-D Column: the series stand one behind another on a depth axis.
        col.threeD?.depthAxis = true
        let (xmlD, backD) = try regenerated(col)
        #expect(xmlD.contains(#"<c:grouping val="standard"/>"#) && xmlD.contains("<c:serAx>"))
        #expect(try backD.threeD?.depthAxis == true && stable(backD))

        var line = Chart.sample(.line)
        line.threeD = Chart3D(rotX: 15, rotY: 20, perspective: 30)
        let (xmlL, backL) = try regenerated(line)
        // A 3-D line always has its depth axis and no group marker (`CT_Line3DChart`).
        #expect(xmlL.contains("<c:line3DChart>") && xmlL.contains("<c:serAx>") && !xmlL.contains(#"<c:marker val="1"/>"#))
        #expect(backL.threeD?.depthAxis == true)
        line.threeD?.depthAxis = true
        #expect(try stable(backL))

        for (kind, tag) in [(ChartType.stackedArea, "<c:area3DChart>"), (.percentBar, "<c:bar3DChart>"), (.pie, "<c:pie3DChart>")] {
            var c = Chart.sample(kind)
            c.threeD = Chart3D(rotX: 30, rotY: 0)
            let (x, b) = try regenerated(c)
            #expect(x.contains(tag) && x.contains("<c:view3D>"), "\(kind)")
            #expect(try b.kind == kind && stable(b), "\(kind)")
            if kind == .pie { #expect(!x.contains("<c:firstSliceAng"), "CT_Pie3DChart has no first slice angle") }
        }
    }

    @Test func ofPieKeepsItsSecondPlot() throws {
        var c = Chart.sample(.pie)
        c.categories = ["A", "B", "C", "D", "E"]
        c.series[0].values = [5, 4, 3, 2, 1]
        c.ofPie = OfPie(bar: true, splitType: "pos", splitPos: 2, secondSize: 75, seriesLines: true)
        let (xml, back) = try regenerated(c)
        #expect(xml.contains("<c:ofPieChart><c:ofPieType val=\"bar\"/>"))
        #expect(xml.contains(#"<c:splitType val="pos"/><c:splitPos val="2"/><c:secondPieSize val="75"/><c:serLines/>"#))
        #expect(try back.ofPie == c.ofPie && back.kind == .pie && stable(back))

        c.ofPie = OfPie(splitType: "cust", custom: [1, 3])
        let (xml2, back2) = try regenerated(c)
        #expect(xml2.contains(#"<c:ofPieType val="pie"/>"#))
        #expect(xml2.contains(#"<c:custSplit><c:secondPiePt val="1"/><c:secondPiePt val="3"/></c:custSplit>"#))
        #expect(back2.ofPie == c.ofPie)
        // Out-of-schema values stay in range.
        c.ofPie = OfPie(splitType: "bogus", secondSize: 9000)
        let (xml3, back3) = try regenerated(c)
        #expect(!xml3.contains("bogus") && xml3.contains(#"<c:secondPieSize val="200"/>"#))
        #expect(back3.ofPie?.secondSize == 200)
    }

    @Test func aComboKeepsItsSecondaryAxis() throws {
        var c = Chart.sample(.combo)
        c.series[2].secondaryAxis = true
        (c.y2Min, c.y2Max, c.y2Major, c.y2Format) = (0, 6, 1, "0.0")
        let (xml, back) = try regenerated(c)
        #expect(count(xml, "<c:valAx>") == 2 && count(xml, "<c:catAx>") == 2)
        #expect(xml.contains(#"<c:axPos val="r"/>"#) && xml.contains(#"<c:crosses val="max"/>"#))
        #expect(back.series.map(\.secondaryAxis) == [false, false, true])
        #expect(back.y2Max == 6 && back.y2Major == 1 && back.y2Format == "0.0")
        #expect(try stable(back))

        // Two groups of one type on the two axes stay two groups.
        c.series[1].secondaryAxis = true
        let (xml2, back2) = try regenerated(c)
        #expect(count(xml2, "<c:barChart>") == 2 && count(xml2, "<c:valAx>") == 2)
        #expect(back2.series.map(\.secondaryAxis) == [false, true, true])

        // Every series on the secondary axis: they share the primary one, as deckcraft writes them.
        for i in c.series.indices { c.series[i].secondaryAxis = true }
        let (xml3, back3) = try regenerated(c)
        #expect(count(xml3, "<c:valAx>") == 1 && back3.series.allSatisfy { !$0.secondaryAxis })

        // Without a secondary series the part is deckcraft's.
        let plain = Chart.sample(.combo)
        let (xml4, _) = try regenerated(plain)
        #expect(count(xml4, "<c:valAx>") == 1 && !xml4.contains("50003") && !xml4.contains("50004"))
    }

    /// PowerPoint's own parts, cut down to their plot (O-37), are read with what an edit must write back.
    @Test func powerPointsPlotGroupsAreRead() throws {
        func part(_ chart: String, _ plot: String) -> [UInt8] {
            Array((#"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:autoTitleDeleted val="1"/>"#
                + chart + "<c:plotArea><c:layout/>" + plot + "</c:plotArea></c:chart></c:chartSpace>").utf8)
        }
        let ser = #"<c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:v>S</c:v></c:tx><c:cat><c:strLit><c:ptCount val="2"/><c:pt idx="0"><c:v>a</c:v></c:pt><c:pt idx="1"><c:v>b</c:v></c:pt></c:strLit></c:cat><c:val><c:numLit><c:ptCount val="2"/><c:pt idx="0"><c:v>1</c:v></c:pt><c:pt idx="1"><c:v>2</c:v></c:pt></c:numLit></c:val></c:ser>"#
        let axes = #"<c:catAx><c:axId val="1"/><c:scaling/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx><c:valAx><c:axId val="2"/><c:scaling/><c:axPos val="l"/><c:crossAx val="1"/></c:valAx>"#

        let col3d = try #require(PPTXRead.readChartXML(part(
            #"<c:view3D><c:rotX val="15"/><c:rotY val="20"/><c:rAngAx val="0"/></c:view3D>"#,
            #"<c:bar3DChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>"# + ser
                + #"<c:gapWidth val="219"/><c:shape val="box"/><c:axId val="1"/><c:axId val="2"/><c:axId val="0"/></c:bar3DChart>"# + axes
        )))
        #expect(col3d.kind == .column && col3d.threeD == Chart3D(rotX: 15, rotY: 20, rAngAx: false, shape: "box"))
        #expect(try regenerated(col3d).xml.contains("<c:bar3DChart>"))

        let contour = try #require(PPTXRead.readChartXML(part(
            #"<c:view3D><c:rotX val="90"/><c:rotY val="0"/><c:rAngAx val="0"/><c:perspective val="0"/></c:view3D>"#,
            #"<c:surfaceChart><c:wireframe val="0"/>"# + ser + #"<c:axId val="1"/><c:axId val="2"/><c:axId val="3"/></c:surfaceChart>"# + axes
                + #"<c:serAx><c:axId val="3"/><c:scaling/><c:axPos val="b"/><c:crossAx val="2"/></c:serAx>"#
        )))
        #expect(contour.kind == .surface && contour.threeD == nil && !contour.wireframe)
        #expect(try regenerated(contour).xml.contains("<c:surfaceChart>"))

        let ofPie = try #require(PPTXRead.readChartXML(part("",
            #"<c:ofPieChart><c:ofPieType val="bar"/><c:varyColors val="1"/>"# + ser
                + #"<c:gapWidth val="219"/><c:secondPieSize val="75%"/><c:serLines><c:spPr/></c:serLines></c:ofPieChart>"#
        )))
        #expect(ofPie.kind == .pie && ofPie.ofPie == OfPie(bar: true, secondSize: 75, seriesLines: true))
        #expect(try regenerated(ofPie).xml.contains("<c:ofPieChart>"))

        let pct = try #require(PPTXRead.readChartXML(part("",
            #"<c:lineChart><c:grouping val="percentStacked"/>"# + ser + #"<c:marker val="1"/><c:axId val="1"/><c:axId val="2"/></c:lineChart>"# + axes
        )))
        #expect(pct.kind == .percentLine)

        // 3-D settings outside a 3-D group, or on a combo, are not the chart's.
        let flat = try #require(PPTXRead.readChartXML(part(#"<c:view3D><c:rotX val="15"/></c:view3D>"#,
            #"<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>"# + ser + #"<c:axId val="1"/><c:axId val="2"/></c:barChart>"# + axes
        )))
        #expect(flat.threeD == nil)
    }

    @Test func threeDValuesFromAFileAreBounded() throws {
        var c = Chart.sample(.column)
        c.threeD = Chart3D(rotX: -400, hPercent: 1, rotY: 9999, depthPercent: 1, perspective: 9999, gapDepth: 9999, shape: "<evil/>")
        let (xml, back) = try regenerated(c)
        #expect(xml.contains(#"<c:rotX val="-90"/><c:hPercent val="5"/><c:rotY val="360"/><c:depthPercent val="20"/><c:perspective val="240"/>"#))
        #expect(xml.contains(#"<c:gapDepth val="500"/>"#) && !xml.contains("evil") && !xml.contains("<c:shape"))
        #expect(back.threeD?.rotX == -90 && back.threeD?.shape == nil)
    }

    @Test func newFieldsAreLeftOutOfTheDeckWhenUnset() throws {
        let json = Chart.sample(.column).toJSON()
        guard case .object(let o) = json else { Issue.record("not an object"); return }
        let keys = Set(o.entries.map(\.key))
        #expect(!keys.contains("threeD") && !keys.contains("wireframe") && !keys.contains("ofPie"))
        var c = Chart.sample(.pie)
        c.threeD = Chart3D(rotX: 30, depthAxis: true)
        c.ofPie = OfPie(bar: true, custom: [2])
        c.wireframe = true
        let back = try Chart(fromJSON: c.toJSON())
        #expect(back == c)
    }
}
