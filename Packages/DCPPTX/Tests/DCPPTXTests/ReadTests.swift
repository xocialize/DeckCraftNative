// The in-file tests of deckcraft crates/pptx/src/read/ (dml.rs and chart.rs; the other read/ modules have
// none). MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
//
// Two chart tests write a chart with the writer's `PPTXWrite.chartXML` (`write::chart::chart_xml`) and read
// it back.
import DCColor
import DCModel
@testable import DCPPTX
import Testing

@Suite struct ReadDMLTests {
    @Test func colorsAndTransforms() throws {
        var d = try parseXML(#"<a:solidFill xmlns:a="x"><a:schemeClr val="accent2"><a:lumMod val="75000"/><a:alpha val="50000"/></a:schemeClr></a:solidFill>"#)
        let c = try #require(PPTXRead.color(d.root))
        #expect(c.base == .scheme(slot: .accent2))
        #expect(c.mods == [.lumMod(75000), .alpha(50000)])
        d = try parseXML(#"<x><a:sysClr val="window" lastClr="FFFFFF"/></x>"#)
        let sys = try #require(PPTXRead.color(d.root))
        guard case .system(_, let last) = sys.base else {
            Issue.record("not a system colour")
            return
        }
        #expect(last == .white)
        d = try parseXML(#"<x><a:scrgbClr r="100000" g="0" b="0"/></x>"#)
        #expect(try #require(PPTXRead.color(d.root)).base == .rgb(rgb: .rgb(255, 0, 0)))
    }

    @Test func bodyProps() throws {
        var d = try parseXML(#"<a:bodyPr lIns="91440" anchor="ctr" wrap="none" vert="vert270" numCol="2"><a:normAutofit fontScale="62500" lnSpcReduction="20000"/></a:bodyPr>"#)
        let b = PPTXRead.bodyPr(d.root)
        #expect(b.insetL == 7.2)
        #expect(b.anchor == .middle)
        #expect(b.wrap == false)
        #expect(b.vert == .vertical270)
        #expect(b.columns == 2)
        #expect(b.autofit == .shrink(fontScale: 0.625, lineReduction: 0.2))
        #expect(b.spaceFirstLast == nil)
        // A bare `<a:normAutofit/>` keeps no scale: the schema default 100 % is drawn as it is,
        // not the same as a saved 100 % (`fontScale="100000"`) (#724).
        d = try parseXML("<a:bodyPr><a:normAutofit/></a:bodyPr>")
        #expect(PPTXRead.bodyPr(d.root).autofit == .shrink(fontScale: nil, lineReduction: 0.0))
        d = try parseXML(#"<a:bodyPr><a:normAutofit fontScale="100000"/></a:bodyPr>"#)
        #expect(PPTXRead.bodyPr(d.root).autofit == .shrink(fontScale: 1.0, lineReduction: 0.0))
        d = try parseXML(#"<a:bodyPr spcFirstLastPara="1"/>"#)
        #expect(PPTXRead.bodyPr(d.root).spaceFirstLast == true)
        // mongolianVert is its own direction (PowerPoint runs its lines left to right) and is
        // written back as it was read.
        d = try parseXML(#"<a:bodyPr vert="mongolianVert"/>"#)
        let m = PPTXRead.bodyPr(d.root)
        #expect(m.vert == .mongolianVertical)
        #expect(m.vert?.xml == "mongolianVert")
        d = try parseXML(#"<a:bodyPr vert="wordArtVertRtl"/>"#)
        #expect(PPTXRead.bodyPr(d.root).vert?.xml == "wordArtVertRtl")
    }
}

@Suite struct ReadChartTests {
    static let nsC = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"

    static func read(_ xml: String) throws -> Chart {
        try #require(PPTXRead.readChartXML(Array(xml.utf8)))
    }

    @Test func sparseCachesShareOneChartWideBudget() throws {
        // Every series declares 100000 points but writes one: without a chart-wide budget each
        // would expand to the full count.
        func ser(_ n: Int) -> String {
            #"<c:ser><c:idx val="\#(n)"/><c:val><c:numRef><c:numCache><c:ptCount val="100000"/><c:pt idx="0"><c:v>\#(n)</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser>"#
        }
        let sers = (0 ..< 5).map(ser).joined()
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/>\#(sers)</c:barChart></c:plotArea></c:chart></c:chartSpace>"#
        let doc = try parseXML(xml)
        let c = try #require(PPTXRead.chartWithin(doc.root, 250_000))
        let total = c.series.map(\.values.count).reduce(0, +)
        #expect(total <= 250_000, "\(total)")
        #expect(c.series.count == 5)
        #expect(c.series[0].values.count == 100_000)
        #expect(c.series[0].values[0] == 0.0)
        #expect(c.series[4].values.isEmpty, "the budget ran out before the last series")
        // A small chart is untouched by the default budget.
        let all = try #require(PPTXRead.chartFromEl(doc.root))
        #expect(all.series.allSatisfy { $0.values.count == 100_000 })
    }

    @Test
    func minorGridlinesAreReadAndWrittenBack() throws {
        var c = Chart.sample(.line)
        c.minorGridlines = true
        let back = try #require(PPTXRead.readChartXML(PPTXWrite.chartXML(c).0))
        #expect(back.gridlines && back.minorGridlines)
        c.minorGridlines = false
        #expect(try #require(PPTXRead.readChartXML(PPTXWrite.chartXML(c).0)).minorGridlines == false)
    }

    @Test
    func seriesPatternFillsAreReadAndWrittenBack() throws {
        // A pattern-filled series and an empty one with an outline, as PowerPoint writes them.
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:spPr><a:pattFill prst="openDmnd"><a:fgClr><a:schemeClr val="accent4"/></a:fgClr><a:bgClr><a:schemeClr val="bg1"/></a:bgClr></a:pattFill></c:spPr><c:val><c:numLit><c:ptCount val="1"/><c:pt idx="0"><c:v>5</c:v></c:pt></c:numLit></c:val></c:ser><c:ser><c:idx val="1"/><c:spPr><a:noFill/><a:ln w="19050"><a:solidFill><a:schemeClr val="accent4"/></a:solidFill></a:ln></c:spPr><c:val><c:numLit><c:ptCount val="1"/><c:pt idx="0"><c:v>3</c:v></c:pt></c:numLit></c:val></c:ser></c:barChart></c:plotArea></c:chart></c:chartSpace>"#
        let c = try Self.read(xml)
        let accent4 = ColorRef.scheme(.accent4)
        let pattern = PatternFill(preset: "openDmnd", fg: accent4, bg: .scheme(.bg1))
        #expect(c.series[0].fill == .pattern(pattern))
        #expect(c.series[1].fill == Fill.none_)
        #expect(c.series[1].line?.fill == .solid(accent4))
        // Written out from the model (an edited chart), the pattern survives.
        var edited = c
        edited.raw = nil
        edited.title = "Edited"
        let back = try #require(PPTXRead.readChartXML(PPTXWrite.chartXML(edited).0))
        #expect(back.series[0].fill == .pattern(pattern))
        #expect(back.series[1].fill == Fill.none_)
    }

    @Test func logBaseIsRead() throws {
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:lineChart><c:axId val="1"/><c:axId val="2"/></c:lineChart><c:catAx><c:axId val="1"/></c:catAx><c:valAx><c:axId val="2"/><c:scaling><c:logBase val="10"/><c:orientation val="minMax"/></c:scaling></c:valAx></c:plotArea></c:chart></c:chartSpace>"#
        #expect(try Self.read(xml).yLogBase == 10.0)
    }

    @Test func errorBarsAreRead() throws {
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:errBars><c:errBarType val="plus"/><c:errValType val="percentage"/><c:noEndCap val="1"/><c:val val="20"/></c:errBars><c:val><c:numLit><c:ptCount val="1"/><c:pt idx="0"><c:v>5</c:v></c:pt></c:numLit></c:val></c:ser></c:barChart></c:plotArea></c:chart></c:chartSpace>"#
        let e = try #require(try Self.read(xml).series[0].errorBars)
        #expect(e.barType == "plus")
        #expect(e.valType == "percentage")
        #expect(e.value == 20.0)
        #expect(e.endCap == false)
    }

    @Test func legendPositionAndOverlayAreRead() throws {
        let legend = #"<c:legend><c:legendPos val="r"/><c:overlay val="1"/></c:legend>"#
        var c = try Self.read(#"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/></c:barChart></c:plotArea>\#(legend)</c:chart></c:chartSpace>"#)
        #expect(c.legend == "r")
        #expect(c.legendOverlay)
        c = try Self.read(#"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/></c:barChart></c:plotArea><c:legend/></c:chart></c:chartSpace>"#)
        #expect(c.legend == "r")
        #expect(!c.legendOverlay)
    }

    @Test func comboChartWithASecondaryAxis() throws {
        // Columns on axes 1/2, a line on axes 3/4 whose value axis is on the right.
        let xml = """
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:lang val="ru-RU"/><c:chart><c:plotArea>
        <c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:ser><c:idx val="0"/><c:tx><c:v>Spend</c:v></c:tx><c:cat><c:strLit><c:ptCount val="2"/><c:pt idx="0"><c:v>W1</c:v></c:pt><c:pt idx="1"><c:v>W2</c:v></c:pt></c:strLit></c:cat><c:val><c:numLit><c:ptCount val="2"/><c:pt idx="0"><c:v>200000</c:v></c:pt><c:pt idx="1"><c:v>310000</c:v></c:pt></c:numLit></c:val></c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart>
        <c:lineChart><c:grouping val="standard"/><c:ser><c:idx val="1"/><c:tx><c:v>Clicks</c:v></c:tx><c:spPr><a:ln w="28575"><a:solidFill><a:srgbClr val="00B050"/></a:solidFill></a:ln></c:spPr><c:val><c:numLit><c:ptCount val="2"/><c:pt idx="0"><c:v>6000</c:v></c:pt><c:pt idx="1"><c:v>7400</c:v></c:pt></c:numLit></c:val></c:ser><c:marker val="1"/><c:axId val="3"/><c:axId val="4"/></c:lineChart>
        <c:catAx><c:axId val="1"/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx><c:valAx><c:axId val="2"/><c:axPos val="l"/><c:numFmt formatCode="#,##0" sourceLinked="1"/><c:crossAx val="1"/><c:majorUnit val="100000"/></c:valAx>
        <c:valAx><c:axId val="4"/><c:scaling><c:max val="8000"/></c:scaling><c:axPos val="r"/><c:numFmt formatCode="0.0" sourceLinked="0"/><c:crossAx val="3"/></c:valAx><c:catAx><c:axId val="3"/><c:delete val="1"/><c:axPos val="b"/><c:crossAx val="4"/></c:catAx>
        </c:plotArea></c:chart></c:chartSpace>
        """
        let c = try Self.read(xml)
        #expect(c.kind == .combo)
        #expect(c.series.count == 2)
        #expect(!c.series[0].secondaryAxis)
        #expect(c.series[1].secondaryAxis)
        #expect(c.series[1].kind == .lineMarkers)
        #expect(c.series[1].line?.width.map { Swift.abs($0 - 2.25) < 0.01 } == true)
        // Each value axis' number format, bounds and unit; the chart's language.
        #expect(c.yFormat == "#,##0")
        #expect(c.yMajor == 100000.0)
        #expect(c.y2Max == 8000.0)
        #expect(c.y2Format == "0.0")
        #expect(c.lang == "ru-RU")
        // Group order doesn't decide: columns on the right-hand axis are the secondary series even
        // when their group comes first, and the line on the left is primary.
        let swapped = xml
            .replacingOccurrences(
                of: ##"<c:axPos val="l"/><c:numFmt formatCode="#,##0""##,
                with: ##"<c:axPos val="r"/><c:crosses val="max"/><c:numFmt formatCode="#,##0""##
            )
            .replacingOccurrences(of: #"<c:axPos val="r"/><c:numFmt formatCode="0.0""#, with: #"<c:axPos val="l"/><c:numFmt formatCode="0.0""#)
        let c2 = try Self.read(swapped)
        #expect(c2.series[0].secondaryAxis && !c2.series[1].secondaryAxis)
        #expect(c2.yFormat == "0.0")
        #expect(c2.y2Format == "#,##0")
        // A chart of one type on one axis has no secondary series.
        let single = xml.replacingOccurrences(
            of: #"<c:axId val="3"/><c:axId val="4"/></c:lineChart>"#, with: #"<c:axId val="1"/><c:axId val="2"/></c:lineChart>"#
        )
        #expect(try Self.read(single).series.allSatisfy { !$0.secondaryAxis })
    }

    @Test func linkedAxisFormatsComeFromTheData() throws {
        // No c:numFmt on the value axis, or a source-linked one: the series' own format.
        func xml(_ axFmt: String) -> String {
            #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:val><c:numRef><c:numCache><c:formatCode>#,##0</c:formatCode><c:ptCount val="1"/><c:pt idx="0"><c:v>1200</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart><c:catAx><c:axId val="1"/></c:catAx><c:valAx><c:axId val="2"/>\#(axFmt)<c:axPos val="l"/></c:valAx></c:plotArea></c:chart></c:chartSpace>"#
        }
        func fmt(_ x: String) throws -> String? { try Self.read(xml(x)).yFormat }
        #expect(try fmt("") == "#,##0")
        #expect(try fmt(#"<c:numFmt formatCode="General" sourceLinked="1"/>"#) == "#,##0")
        #expect(try fmt(#"<c:numFmt formatCode="0.0" sourceLinked="0"/>"#) == "0.0")
    }

    @Test func textColourIsReadFromTheAxes() throws {
        // LibreOffice's templates set light axis text for dark slides on the axes' c:txPr.
        let xml = #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:idx val="0"/><c:val><c:numRef><c:numCache><c:ptCount val="1"/><c:pt idx="0"><c:v>1</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart><c:catAx><c:axId val="1"/><c:txPr><a:bodyPr/><a:p><a:pPr><a:defRPr sz="1000"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:defRPr></a:pPr></a:p></c:txPr></c:catAx><c:valAx><c:axId val="2"/></c:valAx></c:plotArea></c:chart></c:chartSpace>"#
        let c = try Self.read(xml)
        #expect(c.textColor == .rgb(.rgb(255, 255, 255)))
        #expect(!c.catReversed)
        let rev = try Self.read(xml.replacingOccurrences(
            of: #"<c:catAx><c:axId val="1"/>"#,
            with: #"<c:catAx><c:axId val="1"/><c:scaling><c:orientation val="maxMin"/></c:scaling>"#
        ))
        #expect(rev.catReversed, "maxMin reverses the category axis")
        // No c:gapWidth / c:overlap: the schema's 150 % and 0 %.
        #expect(c.gapWidth == 1.5)
        #expect(c.overlap == 0.0)
    }

    @Test func textSizesAreReadFromTheFile() throws {
        // PowerPoint's new charts set the axes' and legend's text to 11.97 pt and the title's to
        // 18.62 pt; a chart that only sets its overall text size uses it everywhere.
        let ns = #"xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        func tx(_ sz: Int) -> String { #"<c:txPr><a:bodyPr/><a:p><a:pPr><a:defRPr sz="\#(sz)"/></a:pPr></a:p></c:txPr>"# }
        var c = try Self.read(#"<c:chartSpace \#(ns)><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:p><a:pPr><a:defRPr sz="1862"/></a:pPr><a:r><a:t>T</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:barDir val="col"/><c:axId val="1"/><c:axId val="2"/></c:barChart><c:catAx><c:axId val="1"/>\#(tx(1197))</c:catAx><c:valAx><c:axId val="2"/>\#(tx(1197))</c:valAx></c:plotArea></c:chart></c:chartSpace>"#)
        #expect(c.textSize == 11.97)
        #expect(c.titleSize == 18.62)
        c = try Self.read(#"<c:chartSpace \#(ns)><c:chart><c:plotArea><c:barChart><c:barDir val="col"/></c:barChart></c:plotArea></c:chart>\#(tx(1400))</c:chartSpace>"#)
        #expect(c.textSize == 14.0)
        #expect(c.titleSize == nil)
        c = try Self.read(#"<c:chartSpace \#(ns)><c:chart><c:plotArea><c:barChart><c:barDir val="col"/></c:barChart></c:plotArea></c:chart></c:chartSpace>"#)
        #expect(c.textSize == nil, "no sizes: the renderer picks one")
    }

    @Test func trendlinesAreRead() throws {
        let xml = """
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart><c:plotArea><c:lineChart><c:grouping val="standard"/><c:ser><c:idx val="0"/><c:tx><c:v>Spend</c:v></c:tx>
        <c:trendline><c:name>Fit &amp; forecast</c:name><c:trendlineType val="linear"/><c:forward val="1"/><c:backward val="0.5"/><c:intercept val="0"/><c:dispRSqr val="1"/><c:dispEq val="1"/></c:trendline>
        <c:trendline><c:trendlineType val="poly"/><c:order val="9"/></c:trendline>
        <c:trendline><c:trendlineType val="movingAvg"/><c:period val="3"/></c:trendline>
        <c:trendline><c:trendlineType val="notAType"/></c:trendline>
        <c:val><c:numLit><c:ptCount val="1"/><c:pt idx="0"><c:v>1</c:v></c:pt></c:numLit></c:val></c:ser></c:lineChart></c:plotArea></c:chart></c:chartSpace>
        """
        let t = try Self.read(xml).series[0].trendlines
        try #require(t.count == 3)
        #expect(t[0].name == "Fit & forecast")
        #expect(t[0].kind == .linear)
        #expect(t[0].forward == 1.0 && t[0].backward == 0.5 && t[0].intercept == 0.0)
        #expect(t[0].dispEq && t[0].dispRSqr)
        #expect(t[1].kind == .poly && t[1].order == 6)
        #expect(t[2].kind == .movingAvg && t[2].period == 3)
    }

    static func chart(_ autoDeleted: String, _ title: String, _ series: Int) throws -> Chart {
        let val = #"<c:val><c:numLit><c:ptCount val="1"/><c:pt idx="0"><c:v>1</c:v></c:pt></c:numLit></c:val>"#
        let ser = (0 ..< series).map { i in #"<c:ser><c:idx val="\#(i)"/><c:tx><c:v>S\#(i)</c:v></c:tx>\#(val)</c:ser>"# }.joined()
        let plot = #"<c:plotArea><c:barChart><c:barDir val="col"/>\#(ser)</c:barChart></c:plotArea>"#
        return try read(#"<c:chartSpace xmlns:c="\#(nsC)" xmlns:a="\#(nsA)"><c:chart>\#(title)\#(autoDeleted)\#(plot)</c:chart></c:chartSpace>"#)
    }

    @Test func singleSeriesGetsAutomaticTitle() throws {
        #expect(try Self.chart(#"<c:autoTitleDeleted val="0"/>"#, "", 1).title == "S0")
    }

    @Test func noAutomaticTitleWhenDeletedOrMultiSeries() throws {
        #expect(try Self.chart(#"<c:autoTitleDeleted val="1"/>"#, "", 1).title == nil)
        #expect(try Self.chart("", "", 1).title == nil)
        #expect(try Self.chart(#"<c:autoTitleDeleted val="0"/>"#, "", 2).title == nil)
    }

    @Test func explicitTitleWins() throws {
        let t = "<c:title><c:tx><c:rich><a:p><a:r><a:t>Mine</a:t></a:r></a:p></c:rich></c:tx></c:title>"
        #expect(try Self.chart(#"<c:autoTitleDeleted val="0"/>"#, t, 1).title == "Mine")
    }

    static func varyXML(_ vary: String) -> String {
        let ser = #"<c:ser><c:idx val="0"/><c:order val="0"/></c:ser>"#
        let bar = #"<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>\#(vary)\#(ser)</c:barChart>"#
        return #"<c:chartSpace xmlns:c="\#(nsC)"><c:chart><c:plotArea>\#(bar)</c:plotArea></c:chart></c:chartSpace>"#
    }

    @Test func missingVaryColorsMeansVaryByPoint() {
        #expect(PPTXRead.readChartXML(Array(Self.varyXML("").utf8))?.varyColors == true)
    }

    @Test func explicitVaryColorsIsRespected() {
        #expect(PPTXRead.readChartXML(Array(Self.varyXML(#"<c:varyColors val="0"/>"#).utf8))?.varyColors == false)
        #expect(PPTXRead.readChartXML(Array(Self.varyXML(#"<c:varyColors val="1"/>"#).utf8))?.varyColors == true)
    }
}
