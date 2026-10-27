// DCPPTX — the chart style and colour style parts of an Office 2016 chart (`chartEx`). DeckCraftNative's
// own, with no deckcraft counterpart: deckcraft writes a `chartEx` part with no style parts, and PowerPoint
// refuses the slide that holds it ("found a problem with content", then repairs it away). A `chartEx` part
// needs a `chartStyle` and a `chartColorStyle` relationship to parts that follow the cs: schema; it also takes
// its default formatting from them, so empty ones open but draw unfilled bars. Built from the cs:chartStyle
// and cs:colorStyle structure (MS-ODRAWXML) and DrawingML's style references.
import DCCore

extension PPTXWrite {
    static let nsCS = "http://schemas.microsoft.com/office/drawing/2012/chartStyle"
    static let ctChartStyle = "application/vnd.ms-office.chartstyle+xml"
    static let ctChartColorStyle = "application/vnd.ms-office.chartcolorstyle+xml"
    static let rtChartStyle = "http://schemas.microsoft.com/office/2011/relationships/chartStyle"
    static let rtChartColorStyle = "http://schemas.microsoft.com/office/2011/relationships/chartColorStyle"

    enum ChartexStyle {
        /// Give the `chartEx` part `chart` a style part and a colour style part when `rels` (its
        /// relationships so far) has none, as `ppt/charts/styleN.xml` and `colorsN.xml`. Writes the
        /// relationships part when it adds one.
        static func add(_ pkg: inout PackageOut, _ chart: String, _ n: UInt32, _ rels: inout RelsOut) {
            var added = false
            if !rels.items.contains(where: { bytesEqual($0.ty, rtChartStyle) }) {
                let name = "ppt/charts/style\(n).xml"
                pkg.xmlPart(name, ctChartStyle, styleXML())
                rels.items.append((freeId(rels), rtChartStyle, OPC.relative(chart, name), false))
                added = true
            }
            if !rels.items.contains(where: { bytesEqual($0.ty, rtChartColorStyle) }) {
                let name = "ppt/charts/colors\(n).xml"
                pkg.xmlPart(name, ctChartColorStyle, colorsXML())
                rels.items.append((freeId(rels), rtChartColorStyle, OPC.relative(chart, name), false))
                added = true
            }
            if added {
                pkg.rels(chart, rels)
            }
        }

        /// The first `rIdN` not taken; kept relationships keep their original ids.
        static func freeId(_ rels: RelsOut) -> String {
            var n = rels.items.count &+ 1
            while rels.items.contains(where: { bytesEqual($0.id, "rId\(n)") }) {
                n &+= 1
            }
            return "rId\(n)"
        }

        /// A theme colour with optional luminance modulation and offset (in 1/1000 %).
        static func clr(_ w: inout W, _ v: String, _ mod: Int? = nil, _ off: Int? = nil) {
            if mod == nil && off == nil {
                w.val("a:schemeClr", v)
                return
            }
            w.open("a:schemeClr", A.new().a("val", v))
            if let mod { w.val("a:lumMod", mod) }
            if let off { w.val("a:lumOff", off) }
            w.close("a:schemeClr")
        }

        /// `a:ln` of one solid colour.
        static func line(_ w: inout W, _ width: Int, _ color: (inout W) -> Void, dash: String? = nil) {
            w.open("a:ln", A.new().a("w", width).a("cap", dash == nil ? "flat" : "rnd"))
            w.open0("a:solidFill")
            color(&w)
            w.close("a:solidFill")
            if let dash { w.val("a:prstDash", dash) }
            w.empty0("a:round")
            w.close("a:ln")
        }

        static func noLine(_ w: inout W) {
            w.open0("a:ln")
            w.empty0("a:noFill")
            w.close("a:ln")
        }

        static func solid(_ w: inout W, _ color: (inout W) -> Void) {
            w.open0("a:solidFill")
            color(&w)
            w.close("a:solidFill")
        }

        /// The series colour a style reference takes from the colour style part.
        static func auto(_ w: inout W) { w.val("cs:styleClr", "auto") }
        static func placeholder(_ w: inout W) { clr(&w, "phClr") }
        static func text(_ w: inout W) { clr(&w, "tx1", 65000, 35000) }
        static func tx1(_ w: inout W) { clr(&w, "tx1") }
        static func tint(_ mod: Int, _ off: Int) -> (inout W) -> Void { { clr(&$0, "tx1", mod, off) } }

        /// Shape properties of one thin line.
        static func thin(_ color: @escaping (inout W) -> Void) -> (inout W) -> Void { { line(&$0, 9525, color) } }

        /// One `cs:StyleEntry`: line, fill and effect references (matrix index, optional colour), the
        /// font reference's colour, then shape properties and the default text size (1/100 pt).
        static func entry(
            _ w: inout W, _ name: String, line lnColor: ((inout W) -> Void)? = nil, fill: Int = 0,
            fillColor: ((inout W) -> Void)? = nil, font: (inout W) -> Void = text,
            sp: ((inout W) -> Void)? = nil, size: Int? = nil
        ) {
            w.open0("cs:\(name)")
            ref(&w, "cs:lnRef", 0, lnColor)
            ref(&w, "cs:fillRef", fill, fillColor)
            ref(&w, "cs:effectRef", 0, nil)
            w.open("cs:fontRef", A.new().a("idx", "minor"))
            font(&w)
            w.close("cs:fontRef")
            if let sp {
                w.open0("cs:spPr")
                sp(&w)
                w.close("cs:spPr")
            }
            if let size { w.empty("cs:defRPr", A.new().a("sz", size)) }
            w.close("cs:\(name)")
        }

        static func ref(_ w: inout W, _ tag: String, _ idx: Int, _ color: ((inout W) -> Void)?) {
            guard let color else {
                w.empty(tag, A.new().a("idx", idx))
                return
            }
            w.open(tag, A.new().a("idx", idx))
            color(&w)
            w.close(tag)
        }

        /// The chart style: series filled and lined in the colour style's colours, light gridlines and axis
        /// lines, grey text, no chart or plot area border. Its entries are the schema's, in its order.
        static func styleXML() -> [UInt8] {
            var w = W.new()
            w.open("cs:chartStyle", A.new().a("xmlns:cs", PPTXWrite.nsCS).a("xmlns:a", OPC.nsA).a("id", 1))
            let light = tint(15000, 85000)
            let none: (inout W) -> Void = { w in
                w.empty0("a:noFill")
                noLine(&w)
            }
            entry(&w, "axisTitle", size: 1330)
            entry(&w, "categoryAxis", sp: { w in
                w.empty0("a:noFill")
                line(&w, 9525, light)
            }, size: 1197)
            entry(&w, "chartArea", font: tx1, sp: { w in
                solid(&w) { clr(&$0, "bg1") }
                noLine(&w)
            }, size: 1330)
            entry(&w, "dataLabel", font: tint(75000, 25000), size: 1197)
            entry(&w, "dataLabelCallout", font: { clr(&$0, "dk1", 65000, 35000) }, sp: { w in
                solid(&w) { clr(&$0, "lt1") }
                line(&w, 9525) { clr(&$0, "dk1", 25000, 75000) }
            }, size: 1197)
            entry(&w, "dataPoint", fill: 1, fillColor: auto, font: tx1, sp: { w in
                solid(&w, placeholder)
                line(&w, 9525) { clr(&$0, "bg1") }
            })
            entry(&w, "dataPoint3D", fill: 1, fillColor: auto, font: tx1, sp: { w in solid(&w, placeholder) })
            entry(&w, "dataPointLine", line: auto, fill: 1, font: tx1, sp: { w in line(&w, 28575, placeholder) })
            entry(&w, "dataPointMarker", line: auto, fill: 1, fillColor: auto, font: tx1, sp: { w in
                solid(&w, placeholder)
                line(&w, 9525, placeholder)
            })
            w.empty("cs:dataPointMarkerLayout", A.new().a("symbol", "circle").a("size", 5))
            entry(&w, "dataPointWireframe", line: auto, font: tx1, sp: thin(placeholder))
            entry(&w, "dataTable", sp: { w in
                w.empty0("a:noFill")
                line(&w, 9525, light)
            }, size: 1197)
            entry(&w, "downBar", font: tx1, sp: { w in
                solid(&w) { clr(&$0, "dk1", 65000, 35000) }
                line(&w, 9525, text)
            })
            entry(&w, "dropLine", font: tx1, sp: thin(tint(35000, 65000)))
            entry(&w, "errorBar", font: tx1, sp: thin(text))
            entry(&w, "floor", font: tx1, sp: none)
            entry(&w, "gridlineMajor", font: tx1, sp: thin(light))
            entry(&w, "gridlineMinor", font: tx1, sp: thin(tint(5000, 95000)))
            entry(&w, "hiLoLine", font: tx1, sp: thin(tint(75000, 25000)))
            entry(&w, "leaderLine", font: tx1, sp: thin(tint(35000, 65000)))
            entry(&w, "legend", size: 1197)
            entry(&w, "plotArea", font: tx1, sp: none)
            entry(&w, "plotArea3D", font: tx1, sp: none)
            entry(&w, "seriesAxis", sp: none, size: 1197)
            entry(&w, "seriesLine", font: tx1, sp: thin(tint(35000, 65000)))
            entry(&w, "title", size: 1862)
            entry(&w, "trendline", line: auto, font: tx1, sp: { w in line(&w, 19050, placeholder, dash: "sysDot") })
            entry(&w, "trendlineLabel", size: 1197)
            entry(&w, "upBar", font: tx1, sp: { w in
                solid(&w) { clr(&$0, "lt1") }
                line(&w, 9525, text)
            })
            entry(&w, "valueAxis", sp: none, size: 1197)
            entry(&w, "wall", font: tx1, sp: none)
            w.close("cs:chartStyle")
            return w.finish()
        }

        /// The colour style: the theme's six accents in turn, then the same six darker or lighter.
        static func colorsXML() -> [UInt8] {
            var w = W.new()
            w.open(
                "cs:colorStyle",
                A.new().a("xmlns:cs", PPTXWrite.nsCS).a("xmlns:a", OPC.nsA).a("meth", "cycle").a("id", 10))
            for i in 1...6 {
                w.val("a:schemeClr", "accent\(i)")
            }
            let variations: [(Int, Int?)] = [(60000, nil), (80000, 20000), (80000, nil), (60000, 40000), (50000, nil)]
            w.empty0("cs:variation")
            for (mod, off) in variations {
                w.open0("cs:variation")
                w.val("a:lumMod", mod)
                if let off { w.val("a:lumOff", off) }
                w.close("cs:variation")
            }
            w.close("cs:colorStyle")
            return w.finish()
        }
    }
}
