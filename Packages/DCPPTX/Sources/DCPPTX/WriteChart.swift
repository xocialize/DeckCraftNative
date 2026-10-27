// DCPPTX — chart parts: a `c:chartSpace` with cached categories and values. An unchanged chart also
// keeps the embedded workbook and the other parts it points at. Port of deckcraft
// crates/pptx/src/write/chart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCModel

extension PPTXWrite {
    /// The Office 2016 chart namespace.
    static let nsCX = "http://schemas.microsoft.com/office/drawing/2014/chartex"

    /// `write::chart::chart_xml`: the chart part XML, and whether it is the original part (so its
    /// relationships still apply).
    static func chartXML(_ c: Chart) -> (xml: [UInt8], preserved: Bool) {
        Charts.chartXML(c)
    }

    /// The `write::chart` module.
    enum Charts {
        /// Column letter for a 0-based index (A, B, … Z, AA…).
        static func col(_ i: Int) -> String {
            var n = i &+ 1
            var s: [UInt8] = []
            while n > 0 && s.count < 4 {
                let r = (n - 1) % 26
                s.insert(UInt8(ascii: "A") + UInt8(r), at: 0)
                n = (n - 1) / 26
            }
            return String(decoding: s, as: UTF8.self)
        }

        static func fmtNum(_ v: Double) -> String {
            v == v.rounded(.towardZero) && Swift.abs(v) < 1e15 ? String(Int64(rustCast: v)) : v.rustDisplay
        }

        static func simpleFill(_ w: inout W, _ f: Fill) {
            switch f {
            case .none_: w.empty0("a:noFill")
            case .solid(let color): DML.solid(&w, color)
            case .pattern(let p):
                w.open("a:pattFill", A.new().a("prst", p.preset.isEmpty ? "pct5" : p.preset))
                w.open0("a:fgClr")
                DML.color(&w, p.fg)
                w.close("a:fgClr")
                w.open0("a:bgClr")
                DML.color(&w, p.bg)
                w.close("a:bgClr")
                w.close("a:pattFill")
            case .gradient(let g):
                if let s = g.stops.first {
                    DML.solid(&w, s.color)
                }
            case .picture, .group, .background:
                break
            }
        }

        static func spPr(_ w: inout W, _ fill: Fill?, _ line: Line?) {
            if fill == nil && line == nil {
                return
            }
            w.open0("c:spPr")
            if let f = fill {
                simpleFill(&w, f)
            }
            if let l = line {
                w.open("a:ln", A.new().o("w", l.width.map(DML.emuPos)))
                if let f = l.fill {
                    simpleFill(&w, f)
                }
                w.close("a:ln")
            }
            w.close("c:spPr")
        }

        /// `a:defRPr` carrying the chart's text colour, where PowerPoint keeps it: the paragraph
        /// defaults of a title's rich text and of every `c:txPr`.
        static func defRPr(_ w: inout W, _ color: ColorRef?) {
            if let c = color {
                w.open0("a:defRPr")
                DML.solid(&w, c)
                w.close("a:defRPr")
            } else {
                w.empty0("a:defRPr")
            }
        }

        /// `c:txPr` with the chart's text colour (`Chart::text_color`) as the default run properties, on
        /// the axes, the legend, the data labels and the chart itself, as PowerPoint writes it. Nothing
        /// without a colour: the theme's default then applies on reading.
        static func txPr(_ w: inout W, _ c: Chart) {
            guard let color = c.textColor else { return }
            w.open0("c:txPr")
            w.empty0("a:bodyPr")
            w.empty0("a:lstStyle")
            w.open0("a:p")
            w.open0("a:pPr")
            defRPr(&w, color)
            w.close("a:pPr")
            w.empty("a:endParaRPr", A.new().a("lang", "en-US"))
            w.close("a:p")
            w.close("c:txPr")
        }

        static func rich(_ w: inout W, _ text: String, _ color: ColorRef?) {
            w.open0("c:tx")
            w.open0("c:rich")
            w.empty0("a:bodyPr")
            w.empty0("a:lstStyle")
            for line in splitScalars(text, ["\n"]) {
                w.open0("a:p")
                if color != nil {
                    w.open0("a:pPr")
                    defRPr(&w, color)
                    w.close("a:pPr")
                }
                w.open0("a:r")
                if let c = color {
                    w.open("a:rPr", A.new().a("lang", "en-US"))
                    DML.solid(&w, c)
                    w.close("a:rPr")
                }
                w.elt("a:t", line)
                w.close("a:r")
                w.close("a:p")
            }
            w.close("c:rich")
            w.close("c:tx")
        }

        /// A title (the chart's or an axis's) in the chart's text colour.
        static func title(_ w: inout W, _ text: String, _ c: Chart) {
            w.open0("c:title")
            rich(&w, text, c.textColor)
            w.val("c:overlay", 0)
            w.close("c:title")
        }

        static func strCache(_ w: inout W, _ f: String, _ vals: [String]) {
            w.open0("c:strRef")
            w.elt("c:f", f)
            w.open0("c:strCache")
            w.val("c:ptCount", vals.count)
            for (i, v) in vals.enumerated() {
                w.open("c:pt", A.new().a("idx", i))
                w.elt("c:v", v)
                w.close("c:pt")
            }
            w.close("c:strCache")
            w.close("c:strRef")
        }

        static func numCache(_ w: inout W, _ f: String, _ vals: [Double?]) {
            w.open0("c:numRef")
            w.elt("c:f", f)
            w.open0("c:numCache")
            w.elt("c:formatCode", "General")
            w.val("c:ptCount", vals.count)
            for (i, v) in vals.enumerated() {
                if let v, v.isFinite {
                    w.open("c:pt", A.new().a("idx", i))
                    w.elt("c:v", fmtNum(v))
                    w.close("c:pt")
                }
            }
            w.close("c:numCache")
            w.close("c:numRef")
        }

        /// Numbers written into the chart itself (`c:numLit`), with no worksheet range behind them.
        static func numLit(_ w: inout W, _ vals: [Double?]) {
            w.open0("c:numLit")
            w.val("c:ptCount", vals.count)
            for (i, v) in vals.enumerated() {
                if let v, v.isFinite {
                    w.open("c:pt", A.new().a("idx", i))
                    w.elt("c:v", fmtNum(v))
                    w.close("c:pt")
                }
            }
            w.close("c:numLit")
        }

        enum Group {
            case bar, line, area, pie, doughnut, scatter, radar, bubble, stock
        }

        static func groupOf(_ k: ChartType) -> Group {
            switch k {
            case .line, .lineMarkers, .stackedLine: .line
            case .stock: .stock
            case .area, .stackedArea, .surface: .area
            case .pie: .pie
            case .doughnut, .sunburst: .doughnut
            case .scatter: .scatter
            case .bubble: .bubble
            case .radar, .filledRadar: .radar
            default: .bar
            }
        }

        static func series(_ w: inout W, _ c: Chart, _ s: Series, _ i: Int, _ kind: ChartType, _ g: Group) {
            w.open0("c:ser")
            w.val("c:idx", i)
            w.val("c:order", i)
            w.open0("c:tx")
            strCache(&w, "Sheet1!$\(col(i + 1))$1", [s.name])
            w.close("c:tx")
            if g == .stock && s.line == nil {
                // A stock chart's series are points joined by the high-low lines, not lines of their own.
                w.open0("c:spPr")
                w.open("a:ln", A.new().a("w", 19050))
                w.empty0("a:noFill")
                w.close("a:ln")
                w.close("c:spPr")
            } else {
                spPr(&w, s.fill, s.line)
            }
            if g == .stock {
                // High-low-close: the close is a dash on the high-low line; with up/down bars (or a set
                // marker) the series keep their own.
                let close = !c.upDownBars && i + 1 == c.series.count && c.series.count == 3
                let sym = s.marker.flatMap { !$0.isEmpty && isASCIIAlnum($0) ? $0 : nil } ?? (close ? "dash" : "none")
                w.open0("c:marker")
                w.val("c:symbol", sym)
                if !bytesEqual(sym, "none") {
                    w.val("c:size", 7)
                }
                w.close("c:marker")
            }
            if g == .bar {
                w.val("c:invertIfNegative", 0)
            }
            if g == .line || g == .scatter || g == .radar {
                let sym: String?
                if let m = s.marker, !m.isEmpty {
                    sym = m
                } else if kind == .lineMarkers || kind == .scatter {
                    sym = nil
                } else {
                    sym = "none"
                }
                if let sym, isASCIIAlnum(sym) {
                    w.open0("c:marker")
                    w.val("c:symbol", sym)
                    w.close("c:marker")
                }
            }
            if g == .pie || g == .doughnut || g == .bar {
                for pf in s.pointFills.prefix(1000) {
                    w.open0("c:dPt")
                    w.val("c:idx", pf.a)
                    if g == .bar {
                        w.val("c:invertIfNegative", 0)
                    }
                    if g != .bar {
                        w.val("c:bubble3D", 0)
                    }
                    spPr(&w, pf.b, nil)
                    w.close("c:dPt")
                }
            }
            if let d = s.dataLabels {
                dataLabels(&w, c, d)
            }
            // After labels, before the category and value caches (ECMA-376 series content order).
            if g == .bar || g == .line || g == .area || g == .scatter {
                for t in s.trendlines.prefix(16) {
                    trendline(&w, t)
                }
            }
            let n = Swift.max(c.categories.count, s.values.count)
            let last = n + 1
            if let e = s.errorBars {
                func word(_ v: String, _ ok: [String], _ d: String) -> String { ok.first { bytesEqual($0, v) } ?? d }
                w.open0("c:errBars")
                if g == .scatter || g == .bubble {
                    w.val("c:errDir", "y")
                }
                w.val("c:errBarType", word(e.barType, ["both", "plus", "minus"], "both"))
                let vt = word(e.valType, ["fixedVal", "percentage", "stdDev", "stdErr", "cust"], "fixedVal")
                w.val("c:errValType", vt)
                w.val("c:noEndCap", e.endCap ? 0 : 1)
                if vt == "cust" {
                    w.open0("c:plus")
                    numLit(&w, e.plus)
                    w.close("c:plus")
                    w.open0("c:minus")
                    numLit(&w, e.minus)
                    w.close("c:minus")
                } else if e.value.isFinite {
                    w.val("c:val", fmtNum(e.value))
                }
                w.close("c:errBars")
            }
            if g == .scatter || g == .bubble {
                let xs: [Double?] = s.xValues.isEmpty ? (0 ..< s.values.count).map { Optional(Double($0 + 1)) } : s.xValues
                w.open0("c:xVal")
                numCache(&w, "Sheet1!$A$2:$A$\(last)", xs)
                w.close("c:xVal")
                w.open0("c:yVal")
                numCache(&w, "Sheet1!$\(col(i + 1))$2:$\(col(i + 1))$\(last)", s.values)
                w.close("c:yVal")
                if g == .bubble {
                    let sizes: [Double?] = s.sizes.isEmpty ? s.values.map { _ in Optional(1.0) } : s.sizes
                    w.open0("c:bubbleSize")
                    numCache(&w, "Sheet1!$\(col(i + 2))$2:$\(col(i + 2))$\(last)", sizes)
                    w.close("c:bubbleSize")
                    w.val("c:bubble3D", 0)
                } else {
                    w.val("c:smooth", s.smooth ? 1 : 0)
                }
            } else {
                w.open0("c:cat")
                strCache(&w, "Sheet1!$A$2:$A$\(last)", c.categories)
                w.close("c:cat")
                w.open0("c:val")
                numCache(&w, "Sheet1!$\(col(i + 1))$2:$\(col(i + 1))$\(last)", s.values)
                w.close("c:val")
                if g == .line {
                    w.val("c:smooth", s.smooth ? 1 : 0)
                }
            }
            w.close("c:ser")
        }

        static func trendNum(_ v: Double?) -> Double? {
            v.flatMap { $0.isFinite && Swift.abs($0) <= 1.0e12 ? $0 : nil }
        }

        static func trendName(_ s: String) -> String? {
            var kept = String.UnicodeScalarView()
            for c in s.unicodeScalars where kept.count < 255 {
                if c == "\t" || c == "\n" || c == "\r" || (c >= " " && c != "\u{FFFE}" && c != "\u{FFFF}") {
                    kept.append(c)
                }
            }
            let cleaned = rustTrim(String(kept))
            return cleaned.isEmpty ? nil : String(cleaned)
        }

        static func trendline(_ w: inout W, _ t: Trendline) {
            w.open0("c:trendline")
            if let name = t.name.flatMap(trendName) {
                w.elt("c:name", name)
            }
            w.val("c:trendlineType", t.kind.xml)
            if t.kind == .poly, let o = t.order {
                w.val("c:order", Swift.min(Swift.max(o, 2), 6))
            }
            if t.kind == .movingAvg, let p = t.period {
                w.val("c:period", Swift.min(Swift.max(p, 2), 255))
            }
            if let v = trendNum(t.forward) {
                w.val("c:forward", fmtNum(v))
            }
            if let v = trendNum(t.backward) {
                w.val("c:backward", fmtNum(v))
            }
            if let v = trendNum(t.intercept) {
                w.val("c:intercept", fmtNum(v))
            }
            if t.dispRSqr {
                w.val("c:dispRSqr", 1)
            }
            if t.dispEq {
                w.val("c:dispEq", 1)
            }
            w.close("c:trendline")
        }

        static func dataLabels(_ w: inout W, _ c: Chart, _ show: Bool) {
            w.open0("c:dLbls")
            txPr(&w, c)
            for (n, v) in [
                ("c:showLegendKey", false),
                ("c:showVal", show),
                ("c:showCatName", false),
                ("c:showSerName", false),
                ("c:showPercent", false),
                ("c:showBubbleSize", false),
            ] {
                w.val(n, v ? 1 : 0)
            }
            w.close("c:dLbls")
        }

        static let axCat: UInt32 = 50_001
        static let axVal: UInt32 = 50_002

        static func axes(_ w: inout W, _ c: Chart, _ g: Group) {
            let horizontal = c.kind.horizontal && g == .bar
            let (catPos, valPos) = horizontal ? ("l", "b") : ("b", "l")
            if g == .scatter || g == .bubble {
                w.open0("c:valAx")
                w.val("c:axId", axCat)
                w.open0("c:scaling")
                w.val("c:orientation", "minMax")
                w.close("c:scaling")
                w.val("c:delete", 0)
                w.val("c:axPos", "b")
                if let t = c.axisTitles.a {
                    title(&w, t, c)
                }
                w.empty("c:numFmt", A.new().a("formatCode", "General").a("sourceLinked", 1))
                w.val("c:majorTickMark", "out")
                w.val("c:minorTickMark", "none")
                w.val("c:tickLblPos", "nextTo")
                txPr(&w, c)
                w.val("c:crossAx", axVal)
                w.val("c:crosses", "autoZero")
                w.val("c:crossBetween", "midCat")
                w.close("c:valAx")
            } else {
                w.open0("c:catAx")
                w.val("c:axId", axCat)
                w.open0("c:scaling")
                w.val("c:orientation", c.catReversed ? "maxMin" : "minMax")
                w.close("c:scaling")
                w.val("c:delete", 0)
                w.val("c:axPos", catPos)
                if let t = c.axisTitles.a {
                    title(&w, t, c)
                }
                w.empty("c:numFmt", A.new().a("formatCode", "General").a("sourceLinked", 1))
                w.val("c:majorTickMark", "none")
                w.val("c:minorTickMark", "none")
                w.val("c:tickLblPos", "nextTo")
                txPr(&w, c)
                w.val("c:crossAx", axVal)
                w.val("c:crosses", "autoZero")
                w.val("c:auto", 1)
                w.val("c:lblAlgn", "ctr")
                w.val("c:lblOffset", 100)
                w.val("c:noMultiLvlLbl", 0)
                w.close("c:catAx")
            }
            w.open0("c:valAx")
            w.val("c:axId", axVal)
            w.open0("c:scaling")
            if let b = c.yLogBase {
                w.val("c:logBase", fmtNum(b))
            }
            w.val("c:orientation", "minMax")
            if let m = c.yMax, m.isFinite {
                w.val("c:max", fmtNum(m))
            }
            if let m = c.yMin, m.isFinite {
                w.val("c:min", fmtNum(m))
            }
            w.close("c:scaling")
            w.val("c:delete", 0)
            w.val("c:axPos", valPos)
            if c.gridlines {
                w.empty0("c:majorGridlines")
            }
            if c.minorGridlines {
                w.empty0("c:minorGridlines")
            }
            if let t = c.axisTitles.b {
                title(&w, t, c)
            }
            if let f = c.yFormat, !f.isEmpty {
                w.empty("c:numFmt", A.new().a("formatCode", f).a("sourceLinked", 0))
            } else {
                w.empty("c:numFmt", A.new().a("formatCode", c.kind.percent ? "0%" : "General").a("sourceLinked", 1))
            }
            w.val("c:majorTickMark", "none")
            w.val("c:minorTickMark", "none")
            w.val("c:tickLblPos", "nextTo")
            txPr(&w, c)
            w.val("c:crossAx", axCat)
            w.val("c:crosses", "autoZero")
            w.val("c:crossBetween", g == .area || g == .scatter ? "midCat" : "between")
            w.close("c:valAx")
        }

        static func plotGroup(_ w: inout W, _ c: Chart, _ kind: ChartType, _ list: [(Int, Series)]) {
            let g = groupOf(kind)
            let grouping = kind.percent ? "percentStacked" : kind.stacked ? "stacked" : g == .bar ? "clustered" : "standard"
            let vary = c.varyColors ? 1 : 0
            let tag = switch g {
            case .bar: "c:barChart"
            case .line: "c:lineChart"
            case .area: "c:areaChart"
            case .pie: "c:pieChart"
            case .doughnut: "c:doughnutChart"
            case .scatter: "c:scatterChart"
            case .radar: "c:radarChart"
            case .bubble: "c:bubbleChart"
            case .stock: "c:stockChart"
            }
            w.open0(tag)
            switch g {
            case .bar:
                w.val("c:barDir", kind.horizontal ? "bar" : "col")
                w.val("c:grouping", grouping)
            case .line, .area: w.val("c:grouping", grouping)
            case .scatter: w.val("c:scatterStyle", "lineMarker")
            case .radar: w.val("c:radarStyle", kind == .filledRadar ? "filled" : "marker")
            default: break
            }
            // `c:stockChart` has no `c:varyColors`.
            if g != .stock {
                w.val("c:varyColors", vary)
            }
            for (i, s) in list {
                series(&w, c, s, i, kind, g)
            }
            if c.dataLabels {
                dataLabels(&w, c, true)
            }
            switch g {
            case .bar:
                w.val("c:gapWidth", Int64(rustCast: (c.gapWidth.clamped(0.0, 5.0) * 100.0).rounded()))
                let ov = kind.stacked ? 100 : Int64(rustCast: (c.overlap.clamped(-1.0, 1.0) * 100.0).rounded())
                if ov != 0 {
                    w.val("c:overlap", ov)
                }
            case .line: w.val("c:marker", 1)
            case .stock:
                w.open0("c:hiLowLines")
                w.open0("c:spPr")
                w.open("a:ln", A.new().a("w", 9525))
                w.open0("a:solidFill")
                w.empty("a:schemeClr", A.new().a("val", "tx1"))
                w.close("a:solidFill")
                w.close("a:ln")
                w.close("c:spPr")
                w.close("c:hiLowLines")
                if c.upDownBars {
                    w.open0("c:upDownBars")
                    w.val("c:gapWidth", 150)
                    w.empty0("c:upBars")
                    w.empty0("c:downBars")
                    w.close("c:upDownBars")
                }
            case .pie: w.val("c:firstSliceAng", 0)
            case .doughnut:
                w.val("c:firstSliceAng", 0)
                w.val("c:holeSize", Int64(rustCast: (c.holeSize.clamped(0.1, 0.9) * 100.0).rounded()))
            default: break
            }
            if g != .pie && g != .doughnut {
                w.val("c:axId", axCat)
                w.val("c:axId", axVal)
            }
            w.close(tag)
        }

        /// The `chartEx` part of an Office 2016 chart (waterfall, funnel…): the kept part when the chart
        /// is unchanged since it was read, else one written from the model. `nil` for other chart types.
        static func chartexXML(_ c: Chart) -> [UInt8]? {
            chartexPart(c).map(\.0)
        }

        /// `chartexXML`, and whether it is the original part (so its kept relationships still apply).
        static func chartexPart(_ c: Chart) -> ([UInt8], Bool)? {
            if let x = keptChartex(c) { return (x, true) }
            return c.kind.isChartex ? (buildChartex(c), false) : nil
        }

        static func keptChartex(_ c: Chart) -> [UInt8]? {
            guard let raw = c.raw, let doc = try? parseXML(raw) else { return nil }
            var root = doc.root
            PPTXRead.resolveMC(&root, 0)
            guard var back = PPTXRead.chartexFrom(root) else { return nil }
            back.raw = c.raw
            // The sidecar is not modelled chart state.
            back.kept = c.kept
            if back != c {
                return nil
            }
            var keep = doc.root
            // The workbook link stays only when its part is written back.
            dropUnkeptRefs(&keep, c)
            var w = W.new()
            w.raw(keep.toXML())
            return w.finish()
        }

        /// The chart part XML, and whether it is the original part (so its relationships still apply).
        static func chartXML(_ c: Chart) -> (xml: [UInt8], preserved: Bool) {
            // Reuse the kept part when the chart is unchanged since it was read.
            if let raw = c.raw, !utf8Contains(raw, PPTXWrite.nsCX), let doc = try? parseXML(raw), doc.root.is("chartSpace") {
                var root = doc.root
                PPTXRead.resolveMC(&root, 0)
                if let back = PPTXRead.chartFromEl(root) {
                    var me = c
                    me.raw = nil
                    // The sidecar is not modelled chart state. Comparing it would throw away an unchanged chart.
                    me.kept = ChartKept()
                    if back == me {
                        var keep = doc.root
                        // Without the parts those elements point at, PowerPoint repairs the file.
                        dropUnkeptRefs(&keep, c)
                        var w = W.new()
                        w.raw(keep.toXML())
                        return (w.finish(), true)
                    }
                }
            }
            var w = W.new()
            w.open("c:chartSpace", A.new().a("xmlns:c", OPC.nsC).a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR))
            w.val("c:date1904", 0)
            w.val("c:roundedCorners", 0)
            w.val("c:style", Swift.min(Swift.max(c.style, 1), 48))
            w.open0("c:chart")
            if let t = c.title {
                title(&w, t, c)
                w.val("c:autoTitleDeleted", 0)
            } else {
                w.val("c:autoTitleDeleted", 1)
            }
            w.open0("c:plotArea")
            w.empty0("c:layout")
            let indexed: [(Int, Series)] = Array(c.series.enumerated().map { ($0.offset, $0.element) })
            let main: ChartType = c.kind == .combo ? (c.series.first?.kind ?? .column) : c.kind
            if c.kind == .combo {
                // One plot group per series type, sharing the axes.
                func plotKind(_ s: Series) -> ChartType {
                    let k = s.kind ?? main
                    switch groupOf(k) {
                    case .pie, .doughnut, .scatter, .bubble: return .column
                    default: return k
                    }
                }
                var kinds: [ChartType] = []
                for s in c.series {
                    let k = plotKind(s)
                    if !kinds.contains(k) {
                        kinds.append(k)
                    }
                }
                for k in kinds {
                    let list = indexed.filter { plotKind($0.1) == k }
                    plotGroup(&w, c, k, list)
                }
                axes(&w, c, .bar)
            } else {
                let plain: [ChartType] = [
                    .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .line, .lineMarkers, .stackedLine,
                    .area, .stackedArea, .pie, .doughnut, .scatter, .bubble, .radar, .filledRadar, .stock,
                ]
                if !plain.contains(c.kind) {
                    PPTXLog.warn("pptx: \(c.kind.label) chart written as a column chart")
                }
                plotGroup(&w, c, main, indexed)
                let g = groupOf(main)
                if g != .pie && g != .doughnut {
                    axes(&w, c, g)
                }
            }
            if let f = c.plotFill {
                spPr(&w, f, nil)
            }
            w.close("c:plotArea")
            if let pos = c.legend {
                let p = ["b", "t", "l", "r", "tr"].contains { bytesEqual($0, pos) } ? pos : "r"
                w.open0("c:legend")
                w.val("c:legendPos", p)
                w.val("c:overlay", c.legendOverlay ? 1 : 0)
                txPr(&w, c)
                w.close("c:legend")
            }
            w.val("c:plotVisOnly", 1)
            w.val("c:dispBlanksAs", "gap")
            w.close("c:chart")
            if let f = c.chartFill {
                spPr(&w, f, nil)
            }
            txPr(&w, c)
            w.close("c:chartSpace")
            return (w.finish(), false)
        }

        /// The relationship ids of an unchanged chart that `writeKept` writes back: external ones, and
        /// internal ones whose part was kept.
        static func keptRelIds(_ c: Chart) -> Set<ByteKey> {
            let parts = Set(c.kept.parts.filter { keptPayload($0.name) }.map { ByteKey(OPC.norm($0.name)) })
            return Set(c.kept.rels.filter { $0.external || parts.contains(ByteKey(OPC.norm($0.part))) }.map { ByteKey($0.id) })
        }

        /// A kept part that is written as a part of its own (rels parts are rewritten instead).
        static func keptPayload(_ name: String) -> Bool {
            !hasByteSuffix(rustASCIILowercase(name), ".rels") && OPC.sidecarPart(name)
        }

        /// Drop `c:externalData` / `c:userShapes` (and the `cx:` ones) that point at a relationship that
        /// is not written back: without the part PowerPoint repairs the file.
        static func dropUnkeptRefs(_ root: inout XMLEl, _ c: Chart) {
            let ids = keptRelIds(c)
            func rec(_ e: inout XMLEl, _ depth: Int) {
                if depth > XML.maxDepth {
                    return
                }
                e.children.removeAll { n in
                    if case .el(let x) = n, x.is("externalData") || x.is("userShapes") {
                        return !(x.attr("r:id").map { ids.contains(ByteKey($0)) } ?? false)
                    }
                    return false
                }
                e.elementsMut { ch in rec(&ch, depth + 1) }
            }
            rec(&root, 0)
        }

        /// A fresh name for a kept part: `ppt/<folder>/keptN.<ext>`. The writer generates no `kept…`
        /// names and `n` is unique within the package, so a kept part never lands on (or duplicates) a
        /// part the writer makes, whatever the source file called it.
        static func keptName(_ original: String, _ n: UInt32) -> String {
            let norm = OPC.norm(original)
            let segs = norm.split(separator: "/", omittingEmptySubsequences: false)
            let area0 = segs.count > 1 ? String(segs[1]) : "embeddings"
            let area = ["embeddings", "charts", "drawings", "media"].contains { bytesEqual($0, area0) } ? area0 : "embeddings"
            let file = OPC.fileOf(norm)
            var ext = "bin"
            if let (_, e) = rsplitOnce(file, "."), !e.isEmpty, e.utf8.count <= 8, isASCIIAlnum(e) {
                ext = e
            }
            return "ppt/\(area)/kept\(n).\(ext)"
        }

        /// Write an unchanged chart's own relationships and the parts they reach. Each kept part is
        /// written under a fresh name (`keptName`) and the relationships between kept parts are
        /// rewritten to those names; a relationship to anything that was not kept is dropped.
        /// `nKept` numbers kept parts across the package.
        /// Returns the chart's relationships as written.
        @discardableResult
        static func writeKept(_ pkg: inout PackageOut, _ chartName: String, _ c: Chart, _ nKept: inout UInt32) -> RelsOut {
            if c.kept.rels.isEmpty {
                return RelsOut()
            }
            // Original part name (normalized) → the name written.
            var names: [ByteKey: String] = [:]
            for p in c.kept.parts where keptPayload(p.name) {
                let key = ByteKey(OPC.norm(p.name))
                if names[key] != nil {
                    continue
                }
                nKept = nKept &+ 1
                let new = keptName(p.name, nKept)
                let ct = !p.contentType.isEmpty ? p.contentType : mimeFor(p.name)
                // An override per part: a kept part never sets the package-wide default for its extension.
                pkg.xmlPart(new, ct, p.bytes)
                names[key] = new
            }
            var rels = RelsOut()
            for r in c.kept.rels {
                if r.external {
                    rels.items.append((r.id, r.relType, r.target, true))
                } else if let new = names[ByteKey(OPC.norm(r.part))] {
                    rels.items.append((r.id, r.relType, OPC.relative(chartName, new), false))
                } else {
                    PPTXLog.warn("pptx: chart relationship \(r.id) has no kept part; dropped")
                }
            }
            pkg.rels(chartName, rels)
            var partsByNorm: [ByteKey: ChartPart] = [:]
            for p in c.kept.parts where partsByNorm[ByteKey(OPC.norm(p.name))] == nil {
                partsByNorm[ByteKey(OPC.norm(p.name))] = p
            }
            var seenPayloads = Set<ByteKey>()
            // The kept parts' own relationships, pointed at the new names.
            for p in c.kept.parts where keptPayload(p.name) {
                let normName = ByteKey(OPC.norm(p.name))
                if !seenPayloads.insert(normName).inserted {
                    continue
                }
                guard let newSource = names[normName] else { continue }
                let rp = ByteKey(OPC.norm(OPC.relsPath(p.name)))
                guard let relsPart = partsByNorm[rp] else { continue }
                var out = RelsOut()
                for r in OPC.relsFromBytes(relsPart.bytes, p.name).items {
                    if r.external {
                        out.items.append((r.id, r.ty, r.targetRaw, true))
                    } else if let new = names[ByteKey(OPC.norm(r.target))] {
                        out.items.append((r.id, r.ty, OPC.relative(newSource, new), false))
                    } else {
                        PPTXLog.warn("pptx: relationship \(r.id) of kept chart part \(p.name) has no kept target; dropped")
                    }
                }
                pkg.rels(newSource, out)
            }
            return rels
        }

        /// A `cx:tx` holding plain text.
        static func cxText(_ w: inout W, _ t: String) {
            w.open0("cx:tx")
            w.open0("cx:txData")
            w.open0("cx:v")
            w.text(t)
            w.close("cx:v")
            w.close("cx:txData")
            w.close("cx:tx")
        }

        /// A `cx:lvl` of points.
        static func cxLevel(_ w: inout W, _ pts: [String], _ format: String?) {
            var a = A.new().a("ptCount", pts.count)
            if let f = format {
                a = a.a("formatCode", f)
            }
            w.open("cx:lvl", a)
            for (i, p) in pts.enumerated() {
                w.open("cx:pt", A.new().a("idx", i))
                w.text(p)
                w.close("cx:pt")
            }
            w.close("cx:lvl")
        }

        /// The `cx:layoutPr` of the region map series in a kept `chartEx` part.
        static func keptRegionLayout(_ raw: String) -> String? {
            guard let doc = try? parseXML(raw) else { return nil }
            var root = doc.root
            PPTXRead.resolveMC(&root, 0)
            guard let region = root.child("chart")?.child("plotArea")?.child("plotAreaRegion"),
                  let s = region.childrenNamed("series").first(where: { $0.attr("layoutId").map { bytesEqual($0, "regionMap") } ?? false }),
                  let lp = s.child("layoutPr")
            else { return nil }
            // Written under our `cx` prefix; a part that bound chartex to another prefix is not copied.
            return hasBytePrefix(lp.name, "cx:") ? lp.toXML() : nil
        }

        /// Writes an Office 2016 chart from the model, as PowerPoint lays the part out: one `cx:data`
        /// per series (categories and values), then the plot area with each series' layout, the axes
        /// the layout uses, the title and the legend.
        static func buildChartex(_ c: Chart) -> [UInt8] {
            var w = W.new()
            w.open("cx:chartSpace", A.new().a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR).a("xmlns:cx", PPTXWrite.nsCX))
            w.open0("cx:chartData")
            for (i, s) in c.series.enumerated() {
                w.open("cx:data", A.new().a("id", i))
                if !c.categories.isEmpty {
                    w.open("cx:strDim", A.new().a("type", "cat"))
                    cxLevel(&w, c.categories, nil)
                    for lv in c.categoryLevels {
                        cxLevel(&w, lv, nil)
                    }
                    w.close("cx:strDim")
                }
                let ty = switch c.kind {
                case .treemap, .sunburst: "size"
                case .regionMap: "colorVal"
                default: "val"
                }
                w.open("cx:numDim", A.new().a("type", ty))
                let vals = s.values.map { $0.map(fmtNum) ?? "" }
                cxLevel(&w, vals, s.numberFormat ?? "General")
                w.close("cx:numDim")
                w.close("cx:data")
            }
            w.close("cx:chartData")
            w.open0("cx:chart")
            if let t = c.title {
                w.open("cx:title", A.new().a("pos", "t").a("align", "ctr").a("overlay", "0"))
                cxText(&w, t)
                w.close("cx:title")
            }
            w.open0("cx:plotArea")
            w.open0("cx:plotAreaRegion")
            let layout = switch c.kind {
            case .waterfall: "waterfall"
            case .funnel: "funnel"
            case .treemap: "treemap"
            case .sunburst: "sunburst"
            case .boxWhisker: "boxWhisker"
            case .regionMap: "regionMap"
            default: "clusteredColumn"
            }
            let one = c.kind != .boxWhisker
            for (i, s) in c.series.enumerated().prefix(one ? 1 : Int.max) {
                w.open("cx:series", A.new().a("layoutId", layout).a("uniqueId", "{DC00000\(i)-0000-4000-8000-000000000000}"))
                cxText(&w, s.name)
                if c.seriesDataLabels(s) {
                    w.open("cx:dataLabels", A.new().a("pos", c.kind == .funnel ? "ctr" : "outEnd"))
                    w.empty("cx:visibility", A.new().a("seriesName", "0").a("categoryName", "0").a("value", "1"))
                    w.close("cx:dataLabels")
                }
                w.empty("cx:dataId", A.new().a("val", i))
                switch c.kind {
                case .waterfall where !c.subtotals.isEmpty:
                    w.open0("cx:layoutPr")
                    w.open0("cx:subtotals")
                    for t in c.subtotals {
                        w.empty("cx:idx", A.new().a("val", t))
                    }
                    w.close("cx:subtotals")
                    w.close("cx:layoutPr")
                case .histogram, .pareto:
                    w.open0("cx:layoutPr")
                    w.open("cx:binning", A.new().a("intervalClosed", "r"))
                    if let size = c.binSize {
                        w.empty("cx:binSize", A.new().a("val", fmtNum(size)))
                    } else if let n = c.binCount {
                        w.empty("cx:binCount", A.new().a("val", n))
                    }
                    w.close("cx:binning")
                    w.close("cx:layoutPr")
                case .boxWhisker:
                    w.open0("cx:layoutPr")
                    w.empty("cx:visibility", A.new().a("meanLine", "0").a("meanMarker", "1").a("nonoutliers", "0").a("outliers", "1"))
                    w.empty("cx:statistics", A.new().a("quartileMethod", c.inclusiveQuartiles ? "inclusive" : "exclusive"))
                    w.close("cx:layoutPr")
                case .regionMap:
                    // The map's geography (projection, region level and the cached boundaries
                    // PowerPoint downloaded) is not modelled: carry it over from the part we read.
                    if let lp = c.raw.flatMap(keptRegionLayout) {
                        w.raw(lp)
                    }
                default:
                    break
                }
                w.close("cx:series")
            }
            if c.kind == .pareto {
                w.open("cx:series", A.new().a("layoutId", "paretoLine").a("ownerIdx", "0").a("uniqueId", "{DC0000FF-0000-4000-8000-000000000000}"))
                w.empty("cx:axisId", A.new().a("val", "2"))
                w.close("cx:series")
            }
            w.close("cx:plotAreaRegion")
            if c.kind != .treemap && c.kind != .sunburst && c.kind != .regionMap {
                w.open("cx:axis", A.new().a("id", "0"))
                w.empty("cx:catScaling", A.new().a("gapWidth", c.kind == .histogram || c.kind == .pareto ? "0" : "0.5"))
                w.empty0("cx:tickLabels")
                w.close("cx:axis")
                if c.kind != .funnel {
                    w.open("cx:axis", A.new().a("id", "1"))
                    w.empty0("cx:valScaling")
                    if c.gridlines {
                        w.empty0("cx:majorGridlines")
                    }
                    w.empty0("cx:tickLabels")
                    w.close("cx:axis")
                }
                if c.kind == .pareto {
                    w.open("cx:axis", A.new().a("id", "2"))
                    w.empty("cx:valScaling", A.new().a("max", "1").a("min", "0"))
                    w.empty0("cx:units")
                    w.empty0("cx:tickLabels")
                    w.close("cx:axis")
                }
            }
            w.close("cx:plotArea")
            if let pos = c.legend {
                w.empty("cx:legend", A.new().a("pos", pos).a("align", "ctr").a("overlay", "0"))
            }
            w.close("cx:chart")
            w.close("cx:chartSpace")
            return w.finish()
        }
    }
}
