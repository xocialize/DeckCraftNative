// DCPPTX — chart parts: a `c:chartSpace` with cached categories and values. An unchanged chart also
// keeps the embedded workbook and the other parts it points at. Port of deckcraft
// crates/pptx/src/write/chart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import CNCore
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
                // Written as read: stops, direction, path and tile (the port's own, AB-T-0437; deckcraft writes
                // the first stop as a solid fill). Without stops there is nothing to write.
                if !g.stops.isEmpty {
                    DML.gradient(&w, g)
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
            case bar, line, area, pie, doughnut, scatter, radar, bubble, stock, surface
        }

        static func groupOf(_ k: ChartType) -> Group {
            switch k {
            case .line, .lineMarkers, .stackedLine, .percentLine: .line
            case .stock: .stock
            case .area, .stackedArea, .percentArea: .area
            // deckcraft writes a surface chart as an area chart (the port's own, AB-T-0434).
            case .surface: .surface
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
            // A series' own labels: its switch, or position and contents of its own (AB-T-0438).
            if g != .surface, s.dataLabels != nil || s.labelOptions != nil {
                dataLabels(&w, c, c.seriesDataLabels(s), c.labelOptions(s), kind)
            }
            // After labels, before the category and value caches (ECMA-376 series content order).
            if g == .bar || g == .line || g == .area || g == .scatter {
                for t in s.trendlines.prefix(16) {
                    trendline(&w, t)
                }
            }
            let n = Swift.max(c.categories.count, s.values.count)
            let last = n + 1
            if let e = s.errorBars, g != .surface {
                errorBars(&w, e, g == .scatter || g == .bubble)
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

        /// A series' value error bars (`c:errBars`); a scatter or bubble chart's say they are y bars.
        static func errorBars(_ w: inout W, _ e: ErrorBars, _ scatterLike: Bool) {
            func word(_ v: String, _ ok: [String], _ d: String) -> String { ok.first { bytesEqual($0, v) } ?? d }
            w.open0("c:errBars")
            if scatterLike {
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
            // Both always, as PowerPoint writes them: it reads a missing one as on, so a trendline without them
            // showed its equation and R² there (the port's own, AB-T-0436; deckcraft writes them only when on).
            w.val("c:dispRSqr", t.dispRSqr ? 1 : 0)
            w.val("c:dispEq", t.dispEq ? 1 : 0)
            w.close("c:trendline")
        }

        /// A `c:dLbls`: on or off, with the position (where series of `kind` take it) and contents of `o` (the
        /// port's own, AB-T-0438; deckcraft writes the value switch alone). Defaults write what deckcraft writes.
        static func dataLabels(_ w: inout W, _ c: Chart, _ show: Bool, _ o: LabelOptions, _ kind: ChartType) {
            w.open0("c:dLbls")
            if show && o.callout {
                // PowerPoint's Data Callout: a white box with a grey outline, its callout shape in `c15:spPr`.
                w.open0("c:spPr")
                DML.solid(&w, .scheme(.bg1))
                w.open0("a:ln")
                DML.solid(&w, .rgb(.rgb(0xA6, 0xA6, 0xA6)))
                w.close("a:ln")
                w.close("c:spPr")
            }
            txPr(&w, c)
            if show, let p = o.position(for: kind, threeD: c.threeD != nil) {
                w.val("c:dLblPos", p)
            }
            for (n, v) in [
                ("c:showLegendKey", show && o.legendKey),
                ("c:showVal", show && !o.hideValue),
                ("c:showCatName", show && o.categoryName),
                ("c:showSerName", show && o.seriesName),
                ("c:showPercent", show && o.percent),
                ("c:showBubbleSize", false),
            ] {
                w.val(n, v ? 1 : 0)
            }
            if show, let sep = o.separator {
                w.open0("c:separator")
                w.text(sep)
                w.close("c:separator")
            }
            if show && o.leaderLines {
                w.val("c:showLeaderLines", 1)
            }
            if show && o.callout {
                w.open0("c:extLst")
                w.open("c:ext", A.new().a("uri", "{CE6537A1-D6FC-4f65-9D91-7224C49458BB}").a("xmlns:c15", c15NS))
                w.open0("c15:spPr")
                w.open("a:prstGeom", A.new().a("prst", "wedgeRectCallout"))
                w.empty0("a:avLst")
                w.close("a:prstGeom")
                w.close("c15:spPr")
                w.close("c:ext")
                w.close("c:extLst")
            }
            w.close("c:dLbls")
        }

        /// Office 2013's chart extensions ([MS-ODRAWXML]).
        static let c15NS = "http://schemas.microsoft.com/office/drawing/2012/chart"

        static let axCat: UInt32 = 50_001
        static let axVal: UInt32 = 50_002
        /// A combo chart's secondary category and value axes, and a 3-D chart's depth (series) axis: the
        /// port's own (AB-T-0434). deckcraft puts every series on the primary pair.
        static let axCat2: UInt32 = 50_003
        static let axVal2: UInt32 = 50_004
        static let axSer: UInt32 = 50_005

        /// The 3-D settings the chart is written with: a 3-D group's view (`c:bar3DChart`…). A combo is
        /// written flat, and an of-pie chart has no 3-D form. The port's own (AB-T-0434).
        static func threeD(_ c: Chart, _ g: Group) -> Chart3D? {
            guard c.kind != .combo, let t = c.threeD else { return nil }
            switch g {
            case .bar, .line, .area, .surface: return t
            case .pie: return c.ofPie == nil ? t : nil
            default: return nil
            }
        }

        /// Whether the group stands its series on a depth axis (`c:serAx`): a 3-D line or surface chart
        /// always does, as does a contour (PowerPoint writes one); 3-D columns and areas when the chart says so.
        static func depthAxis(_ c: Chart, _ g: Group) -> Bool {
            if g == .surface { return true }
            guard let t = threeD(c, g) else { return false }
            return g == .line || ((g == .bar || g == .area) && t.depthAxis)
        }

        /// `c:view3D` (ECMA-376 §21.2.2.228): the chart's own, or PowerPoint's top-down view for a contour.
        static func view3D(_ w: inout W, _ c: Chart, _ g: Group) {
            if let t = threeD(c, g) {
                w.open0("c:view3D")
                if let v = t.rotX { w.val("c:rotX", Swift.min(Swift.max(v, -90), 90)) }
                if let v = t.hPercent { w.val("c:hPercent", Swift.min(Swift.max(v, 5), 500)) }
                if let v = t.rotY { w.val("c:rotY", Swift.min(v, 360)) }
                if let v = t.depthPercent { w.val("c:depthPercent", Swift.min(Swift.max(v, 20), 2000)) }
                if let v = t.rAngAx { w.val("c:rAngAx", v ? 1 : 0) }
                if let v = t.perspective { w.val("c:perspective", Swift.min(v, 240)) }
                w.close("c:view3D")
            } else if g == .surface {
                w.open0("c:view3D")
                w.val("c:rotX", 90)
                w.val("c:rotY", 0)
                w.val("c:rAngAx", 0)
                w.val("c:perspective", 0)
                w.close("c:view3D")
            }
        }

        /// A combo chart's secondary value axis on the right, and the hidden category axis it crosses, as
        /// PowerPoint writes them for a series on the secondary axis. The port's own (AB-T-0434).
        static func secondaryAxes(_ w: inout W, _ c: Chart) {
            w.open0("c:valAx")
            w.val("c:axId", axVal2)
            w.open0("c:scaling")
            w.val("c:orientation", "minMax")
            if let m = c.y2Max, m.isFinite {
                w.val("c:max", fmtNum(m))
            }
            if let m = c.y2Min, m.isFinite {
                w.val("c:min", fmtNum(m))
            }
            w.close("c:scaling")
            w.val("c:delete", c.y2Hidden ? 1 : 0)
            w.val("c:axPos", "r")
            if let f = c.y2Format, !f.isEmpty {
                w.empty("c:numFmt", A.new().a("formatCode", f).a("sourceLinked", 0))
            } else {
                w.empty("c:numFmt", A.new().a("formatCode", "General").a("sourceLinked", 1))
            }
            w.val("c:majorTickMark", "out")
            w.val("c:minorTickMark", "none")
            w.val("c:tickLblPos", "nextTo")
            txPr(&w, c)
            w.val("c:crossAx", axCat2)
            w.val("c:crosses", "max")
            w.val("c:crossBetween", "between")
            if let u = c.y2Major, u.isFinite, u > 0 {
                w.val("c:majorUnit", fmtNum(u))
            }
            w.close("c:valAx")
            w.open0("c:catAx")
            w.val("c:axId", axCat2)
            w.open0("c:scaling")
            w.val("c:orientation", c.catReversed ? "maxMin" : "minMax")
            w.close("c:scaling")
            w.val("c:delete", 1)
            w.val("c:axPos", "b")
            w.empty("c:numFmt", A.new().a("formatCode", "General").a("sourceLinked", 1))
            w.val("c:majorTickMark", "out")
            w.val("c:minorTickMark", "none")
            w.val("c:tickLblPos", "nextTo")
            w.val("c:crossAx", axVal2)
            w.val("c:crosses", "autoZero")
            w.val("c:auto", 1)
            w.val("c:lblAlgn", "ctr")
            w.val("c:lblOffset", 100)
            w.val("c:noMultiLvlLbl", 0)
            w.close("c:catAx")
        }

        /// A 3-D chart's depth axis (`c:serAx`), as PowerPoint writes it.
        static func seriesAxis(_ w: inout W, _ c: Chart) {
            w.open0("c:serAx")
            w.val("c:axId", axSer)
            w.open0("c:scaling")
            w.val("c:orientation", "minMax")
            w.close("c:scaling")
            w.val("c:delete", 0)
            w.val("c:axPos", "b")
            w.val("c:majorTickMark", "out")
            w.val("c:minorTickMark", "none")
            w.val("c:tickLblPos", "nextTo")
            txPr(&w, c)
            w.val("c:crossAx", axVal)
            w.val("c:crosses", "autoZero")
            w.close("c:serAx")
        }

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
            w.val("c:crossBetween", g == .area || g == .scatter || g == .surface ? "midCat" : "between")
            // The major unit the model holds: the port's own (AB-T-0436); deckcraft writes the secondary axis's only.
            if let u = c.yMajor, u.isFinite, u > 0 {
                w.val("c:majorUnit", fmtNum(u))
            }
            w.close("c:valAx")
            if depthAxis(c, g) {
                seriesAxis(&w, c)
            }
        }

        static func plotGroup(_ w: inout W, _ c: Chart, _ kind: ChartType, _ list: [(Int, Series)], secondary: Bool = false) {
            let g = groupOf(kind)
            let three = threeD(c, g)
            // 3-D Column and 3-D Area stand their series one behind another: grouping "standard".
            let standard3D = three != nil && depthAxis(c, g) && !kind.stacked
            let grouping = kind.percent ? "percentStacked" : kind.stacked ? "stacked" : g == .bar && !standard3D ? "clustered" : "standard"
            let vary = c.varyColors ? 1 : 0
            let ofPie = g == .pie ? c.ofPie : nil
            let tag = switch g {
            case .bar: three != nil ? "c:bar3DChart" : "c:barChart"
            case .line: three != nil ? "c:line3DChart" : "c:lineChart"
            case .area: three != nil ? "c:area3DChart" : "c:areaChart"
            case .pie: ofPie != nil ? "c:ofPieChart" : three != nil ? "c:pie3DChart" : "c:pieChart"
            case .doughnut: "c:doughnutChart"
            case .scatter: "c:scatterChart"
            case .radar: "c:radarChart"
            case .bubble: "c:bubbleChart"
            case .stock: "c:stockChart"
            case .surface: three != nil ? "c:surface3DChart" : "c:surfaceChart"
            }
            w.open0(tag)
            switch g {
            case .bar:
                w.val("c:barDir", kind.horizontal ? "bar" : "col")
                w.val("c:grouping", grouping)
            case .line, .area: w.val("c:grouping", grouping)
            case .scatter: w.val("c:scatterStyle", "lineMarker")
            case .radar: w.val("c:radarStyle", kind == .filledRadar ? "filled" : "marker")
            case .pie where ofPie != nil: w.val("c:ofPieType", ofPie?.bar == true ? "bar" : "pie")
            case .surface: w.val("c:wireframe", c.wireframe ? 1 : 0)
            default: break
            }
            // `c:stockChart` and the surface charts have no `c:varyColors`.
            if g != .stock && g != .surface {
                w.val("c:varyColors", vary)
            }
            for (i, s) in list {
                series(&w, c, s, i, kind, g)
            }
            if c.dataLabels && g != .surface {
                dataLabels(&w, c, true, c.labelOptions ?? LabelOptions(), kind)
            }
            func gapDepth(_ w: inout W, _ t: Chart3D) {
                if let v = t.gapDepth { w.val("c:gapDepth", Swift.min(v, 500)) }
            }
            switch g {
            case .bar:
                w.val("c:gapWidth", Int64(rustCast: (c.gapWidth.clamped(0.0, 5.0) * 100.0).rounded()))
                if let t = three {
                    // `CT_Bar3DChart` has no overlap.
                    gapDepth(&w, t)
                    if let sh = t.shape.flatMap({ v in PPTXRead.shapes3D.first { bytesEqual($0, v) } }) {
                        w.val("c:shape", sh)
                    }
                } else {
                    let ov = kind.stacked ? 100 : Int64(rustCast: (c.overlap.clamped(-1.0, 1.0) * 100.0).rounded())
                    if ov != 0 {
                        w.val("c:overlap", ov)
                    }
                }
            case .line, .area:
                if let t = three {
                    gapDepth(&w, t)
                } else if g == .line {
                    // A line chart's up/down bars, between its first and last series: the port's own (AB-T-0436);
                    // deckcraft writes them for stock charts only.
                    if c.upDownBars && c.series.count >= 2 {
                        w.open0("c:upDownBars")
                        w.val("c:gapWidth", 150)
                        w.empty0("c:upBars")
                        w.empty0("c:downBars")
                        w.close("c:upDownBars")
                    }
                    w.val("c:marker", 1)
                }
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
            case .pie:
                if let o = ofPie {
                    w.val("c:gapWidth", Int64(rustCast: (c.gapWidth.clamped(0.0, 5.0) * 100.0).rounded()))
                    if let t = o.splitType.flatMap({ v in PPTXRead.splitTypes.first { bytesEqual($0, v) } }) {
                        w.val("c:splitType", t)
                    }
                    if let v = o.splitPos, v.isFinite {
                        w.val("c:splitPos", fmtNum(v))
                    }
                    if !o.custom.isEmpty {
                        w.open0("c:custSplit")
                        for i in o.custom.prefix(1000) {
                            w.val("c:secondPiePt", i)
                        }
                        w.close("c:custSplit")
                    }
                    if let v = o.secondSize {
                        w.val("c:secondPieSize", Swift.min(Swift.max(v, 5), 200))
                    }
                    if o.seriesLines {
                        w.empty0("c:serLines")
                    }
                } else if three == nil {
                    // `CT_Pie3DChart` has no first slice angle.
                    w.val("c:firstSliceAng", 0)
                }
            case .doughnut:
                w.val("c:firstSliceAng", 0)
                w.val("c:holeSize", Int64(rustCast: (c.holeSize.clamped(0.1, 0.9) * 100.0).rounded()))
            case .bubble:
                // The bubbles' scale and what a size measures, as read (the port's own, AB-T-0437); unset, the
                // schema's defaults (100 %, area) and nothing written, as deckcraft writes.
                if let v = c.bubbleScale, v.isFinite {
                    w.val("c:bubbleScale", Int64(rustCast: v.clamped(0.0, 300.0).rounded()))
                }
                if c.bubbleSizeWidth {
                    w.val("c:sizeRepresents", "w")
                }
            default: break
            }
            if g != .pie && g != .doughnut {
                w.val("c:axId", secondary ? axCat2 : axCat)
                w.val("c:axId", secondary ? axVal2 : axVal)
                if depthAxis(c, g) {
                    w.val("c:axId", axSer)
                } else if three != nil && (g == .bar || g == .area) {
                    // PowerPoint's third id for a 3-D group without a depth axis.
                    w.val("c:axId", 0)
                }
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
            let p = chartPart(c)
            return (p.xml, p.kept != nil)
        }

        /// The chart part XML, and the kept parts to write with it: nil for a generated part, the chart's own
        /// for an unchanged or patched one, without the workbook when its data was edited. `fresh`: the data
        /// was written from the model (generated, or patched by `chart.data`), so it needs a workbook of its own
        /// (`WriteChartWorkbook.swift`).
        static func chartPart(_ c: Chart) -> (xml: [UInt8], kept: ChartKept?, fresh: Bool) {
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
                        return (w.finish(), c.kept, false)
                    }
                }
                // Edited by `chart.options` or `chart.data`: the kept part with the edit written into it (the
                // port's own).
                if let patched = patchedXML(c) {
                    return (patched.xml, patched.data ? withoutWorkbook(c.kept) : c.kept, patched.data)
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
            if c.kind != .combo {
                view3D(&w, c, groupOf(c.kind))
            }
            w.open0("c:plotArea")
            w.empty0("c:layout")
            let indexed: [(Int, Series)] = Array(c.series.enumerated().map { ($0.offset, $0.element) })
            let main: ChartType = c.kind == .combo ? (c.series.first?.kind ?? .column) : c.kind
            if c.kind == .combo {
                // One plot group per series type and value axis. deckcraft shares one pair of axes; a series on
                // the secondary axis gets PowerPoint's second pair (the port's own, AB-T-0434). When every series
                // is on the secondary axis, they are all on the primary one.
                func plotKind(_ s: Series) -> ChartType {
                    let k = s.kind ?? main
                    switch groupOf(k) {
                    case .pie, .doughnut, .scatter, .bubble, .surface: return .column
                    default: return k
                    }
                }
                let twoAxes = c.series.contains(where: \.secondaryAxis) && c.series.contains { !$0.secondaryAxis }
                func onSecondary(_ s: Series) -> Bool { twoAxes && s.secondaryAxis }
                var groups: [(ChartType, Bool)] = []
                for s in c.series {
                    let key = (plotKind(s), onSecondary(s))
                    if !groups.contains(where: { $0 == key }) {
                        groups.append(key)
                    }
                }
                for (k, sec) in groups {
                    let list = indexed.filter { plotKind($0.1) == k && onSecondary($0.1) == sec }
                    plotGroup(&w, c, k, list, secondary: sec)
                }
                axes(&w, c, .bar)
                if twoAxes {
                    secondaryAxes(&w, c)
                }
            } else {
                let plain: [ChartType] = [
                    .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .line, .lineMarkers, .stackedLine,
                    .percentLine, .area, .stackedArea, .percentArea, .pie, .doughnut, .scatter, .bubble, .radar, .filledRadar,
                    .stock, .surface,
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
            return (w.finish(), nil, true)
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
