// DCPPTX — chart parts (`c:chartSpace`) → `Chart`. The original XML is kept in `Chart.raw`. Port of
// deckcraft crates/pptx/src/read/chart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCModel

extension PPTXRead {
    /// Fills of chart parts never reference images we keep; read colour and pattern fills only.
    static func simpleFill(_ sp: XMLEl?) -> Fill? {
        guard let sp else { return nil }
        for e in sp.elements {
            switch e.local {
            case "noFill": return Fill.none_
            case "solidFill": return color(e).map { .solid(color: $0) }
            case "gradFill": return .gradient(gradient(e))
            case "pattFill": return .pattern(pattern(e))
            default: break
            }
        }
        return nil
    }

    static func simpleLine(_ sp: XMLEl?) -> Line? {
        guard let ln = sp?.child("ln") else { return nil }
        var l = Line(width: pt(ln, "w"))
        l.fill = simpleFill(ln)
        return l
    }

    static func richText(_ t: XMLEl) -> String? {
        guard let tx = t.child("tx") else { return nil }
        if let r = tx.child("rich") {
            return r.childrenNamed("p").map(\.text).joined(separator: "\n")
        }
        return tx.find("v")?.text
    }

    /// Most category/value/size slots one chart may decode across all its series and caches, so
    /// sparse `ptCount`/`idx` declarations can't expand far beyond the XML they came from.
    static let maxChartPoints = 1_000_000

    /// Most slots one cache may hold.
    static let maxCachePoints = 100_000

    /// String values from `c:cat`/`c:tx` (str or num refs, caches or literals). Every slot returned
    /// is taken from `budget`; once it runs out the values are cut short.
    static func strings(_ e: XMLEl, _ budget: inout Int) -> [String] {
        let cap = Swift.min(maxCachePoints, budget)
        let out = stringsCapped(e, cap)
        budget = Swift.max(budget - out.count, 0)
        return out
    }

    static func stringsCapped(_ e: XMLEl, _ cap: Int) -> [String] {
        if let c = e.find("strCache") ?? e.find("numCache") ?? e.find("strLit") ?? e.find("numLit") {
            let n = Swift.min(Int(c.child("ptCount")?.u32("val") ?? 0), cap)
            var out = Array(repeating: "", count: n)
            for pt in c.childrenNamed("pt").prefix(maxCachePoints) {
                let i = Int(pt.u32("idx") ?? 0)
                if i >= cap { continue }
                let v = pt.child("v")?.text ?? ""
                if i >= out.count { out.append(contentsOf: Array(repeating: "", count: i + 1 - out.count)) }
                out[i] = v
            }
            return out
        }
        if let ml = e.find("multiLvlStrCache") {
            // Use the innermost level.
            if let l = ml.child("lvl") {
                return l.childrenNamed("pt").prefix(cap).map { $0.child("v")?.text ?? "" }
            }
        }
        if cap > 0, let v = e.child("v") {
            return [v.text]
        }
        return []
    }

    static func numbers(_ e: XMLEl, _ budget: inout Int) -> [Double?] {
        strings(e, &budget).map { s in rustParseF64(rustTrim(s)).flatMap { $0.isFinite ? $0 : nil } }
    }

    /// Parse a chart part. Returns nil for something that isn't a chart we can read.
    static func readChartXML(_ bytes: [UInt8]) -> Chart? {
        guard let doc = try? XML.parse(bytes) else { return nil }
        var root = doc.root
        resolveMC(&root, 0)
        if !root.is("chartSpace") { return nil }
        guard var c = chartFromEl(root) else { return nil }
        c.raw = String(decoding: bytes, as: UTF8.self)
        return c
    }

    /// `chart_from` (re-exported by `read::` as `chart_from_el`).
    static func chartFromEl(_ root: XMLEl) -> Chart? {
        chartWithin(root, maxChartPoints)
    }

    static func isVertical(_ a: XMLEl) -> Bool {
        let p = a.childVal("axPos")
        return attrIs(p, "l") || attrIs(p, "r")
    }

    static func optEqual(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let x?, let y?): bytesEqual(x, y)
        default: false
        }
    }

    /// `chart_from` decoding at most `budget` data slots in all.
    static func chartWithin(_ root: XMLEl, _ budget: Int) -> Chart? {
        var budget = budget
        guard let ch = root.child("chart"), let pa = ch.child("plotArea") else { return nil }
        var c = Chart.default
        c.categories = []
        c.series = []
        c.title = nil
        c.legend = nil
        c.gridlines = false
        c.style = root.childVal("style").flatMap { rustParseUnsigned($0, as: UInt32.self) } ?? 2
        if let t = ch.child("title") {
            c.title = richText(t) ?? "Chart Title"
        }
        if ch.child("autoTitleDeleted")?.bool("val") == true { c.title = nil }
        c.legend = ch.child("legend").map { $0.childVal("legendPos") ?? "r" }
        c.legendOverlay = ch.child("legend")?.child("overlay")?.bool("val") ?? false
        c.chartFill = simpleFill(root.child("spPr"))
        c.plotFill = simpleFill(pa.child("spPr"))

        var kinds: [ChartType] = []
        // The value axis the first plot group uses is the primary one; a group on another value axis
        // (a combo chart's line on the right) is on the secondary axis.
        var valMap: [ByteKey: Bool] = [:]
        for a in pa.childrenNamed("valAx") {
            if let id = a.childVal("axId") { valMap[ByteKey(id)] = isVertical(a) }
        }
        // A group's value axis: its vertical one when it has two (scatter), else its one.
        func groupValAxis(_ g: XMLEl) -> String? {
            let ids: [(String, Bool)] = g.childrenNamed("axId").compactMap { $0.attr("val") }.compactMap { id in
                valMap[ByteKey(id)].map { (id, $0) }
            }
            return (ids.first { $0.1 } ?? ids.first)?.0
        }
        // The primary value axis is the one on the left (bottom for bar charts); the secondary one
        // sits on the right or top, or crosses the category axis at its maximum.
        func secondaryPlaced(_ a: XMLEl) -> Bool {
            let p = a.childVal("axPos")
            return attrIs(a.childVal("crosses"), "max") || attrIs(p, "r") || attrIs(p, "t")
        }
        var valAxesById: [ByteKey: XMLEl] = [:]
        for a in pa.childrenNamed("valAx") {
            if let id = a.childVal("axId") { valAxesById[ByteKey(id)] = a }
        }
        let used: [String] = pa.elements.filter { hasByteSuffix($0.local, "Chart") }.compactMap(groupValAxis)
        let primaryVal: String? = used.first { id in valAxesById[ByteKey(id)].map { !secondaryPlaced($0) } ?? false } ?? used.first
        for g in pa.elements {
            let name = g.local
            if !hasByteSuffix(name, "Chart") { continue }
            let grouping = g.childVal("grouping") ?? "clustered"
            let kind: ChartType
            switch name {
            case "barChart", "bar3DChart":
                let bar = attrIs(g.childVal("barDir"), "bar")
                switch (bar, grouping) {
                case (false, "stacked"): kind = .stackedColumn
                case (false, "percentStacked"): kind = .percentColumn
                case (false, _): kind = .column
                case (true, "stacked"): kind = .stackedBar
                case (true, "percentStacked"): kind = .percentBar
                case (true, _): kind = .bar
                }
            case "lineChart", "line3DChart":
                let markers = (g.childVal("marker").map { bytesEqual($0, "1") || bytesEqual($0, "true") } ?? false)
                    && g.childrenNamed("ser").allSatisfy { s in !attrIs(s.path(["marker", "symbol"])?.attr("val"), "none") }
                switch grouping {
                case "stacked", "percentStacked": kind = .stackedLine
                case _ where markers: kind = .lineMarkers
                default: kind = .line
                }
            case "areaChart", "area3DChart":
                kind = grouping == "stacked" || grouping == "percentStacked" ? .stackedArea : .area
            case "pieChart", "pie3DChart", "ofPieChart": kind = .pie
            case "doughnutChart": kind = .doughnut
            case "scatterChart": kind = .scatter
            case "bubbleChart": kind = .bubble
            case "radarChart":
                kind = attrIs(g.childVal("radarStyle"), "filled") ? .filledRadar : .radar
            case "stockChart":
                c.upDownBars = g.child("upDownBars") != nil
                kind = .stock
            case "surfaceChart", "surface3DChart": kind = .surface
            default: continue
            }
            // A missing <c:varyColors> means "vary by point" (the schema default is true), as PowerPoint draws it.
            c.varyColors = g.childVal("varyColors").map { bytesEqual($0, "1") || bytesEqual($0, "true") } ?? true
            // A bar group without c:gapWidth / c:overlap takes the schema's defaults (150 %, 0 %),
            // not the 219 % / -27 % PowerPoint writes into its new charts.
            let barGroup = g.is("barChart") || g.is("bar3DChart")
            if let v = g.childVal("gapWidth").flatMap({ rustParseF64($0) }) {
                c.gapWidth = (v / 100.0).clamped(0.0, 5.0)
            } else if barGroup {
                c.gapWidth = 1.5
            }
            if let v = g.childVal("overlap").flatMap({ rustParseF64($0) }) {
                c.overlap = (v / 100.0).clamped(-1.0, 1.0)
            } else if barGroup {
                c.overlap = 0.0
            }
            if let v = g.childVal("holeSize").flatMap({ rustParseF64($0) }) {
                c.holeSize = (v / 100.0).clamped(0.0, 0.9)
            }
            // `<c:showVal/>` without a val attribute means true, as in the schema's default.
            // The setting belongs to this plot group: a group that asks for no labels keeps them
            // off, even when another group of a combo chart asks for them (#868).
            let groupLabels = g.path(["dLbls", "showVal"]).map { $0.bool("val") ?? true }
            if groupLabels == true { c.dataLabels = true }
            kinds.append(kind)
            let valAxis = groupValAxis(g)
            let secondary = valAxis != nil && !optEqual(valAxis, primaryVal)
            let scatterLike = kind == .scatter || kind == .bubble
            for s in g.childrenNamed("ser").prefix(1000) {
                var ser = Series()
                ser.name = s.child("tx").map { strings($0, &budget) }.flatMap(\.first) ?? ""
                ser.fill = simpleFill(s.child("spPr"))
                ser.line = simpleLine(s.child("spPr"))
                ser.smooth = s.child("smooth")?.bool("val") ?? false
                ser.marker = s.path(["marker", "symbol"])?.attr("val").flatMap { bytesEqual($0, "none") ? nil : $0 }
                ser.kind = kind
                ser.secondaryAxis = secondary
                // `<c:showVal/>` without a val attribute means true, as in the schema's default.
                if let d = s.child("dLbls")?.child("showVal").map({ $0.bool("val") ?? true }) {
                    ser.dataLabels = d
                } else if groupLabels == false {
                    // The group asks for no labels and the series does not say otherwise.
                    ser.dataLabels = false
                }
                for t in s.childrenNamed("trendline").prefix(16) {
                    if let t = trendline(t) { ser.trendlines.append(t) }
                }
                // Data labels' number format: the series' labels', the group's, else the source data's.
                func labelFmt(_ d: XMLEl?) -> String? {
                    guard let n = d?.child("numFmt"), !attrIs(n.attr("sourceLinked"), "1") else { return nil }
                    return n.attr("formatCode")
                }
                let source = (s.child("val") ?? s.child("yVal"))?.find("numCache")?.child("formatCode")?.text
                ser.numberFormat = (labelFmt(s.child("dLbls")) ?? labelFmt(g.child("dLbls")) ?? source).flatMap { $0.isEmpty ? nil : $0 }
                for dp in s.childrenNamed("dPt") {
                    if let i = dp.child("idx")?.u32("val"), let f = simpleFill(dp.child("spPr")) {
                        ser.pointFills.append(Pair(Int(i), f))
                    }
                }
                if let cat = s.child("cat") ?? s.child("xVal") {
                    let cats = strings(cat, &budget)
                    if scatterLike {
                        ser.xValues = cats.map { rustParseF64(rustTrim($0)) }
                    }
                    if c.categories.isEmpty { c.categories = cats }
                }
                if let v = s.child("val") ?? s.child("yVal") {
                    ser.values = numbers(v, &budget)
                }
                // Error bars on the values: a scatter chart's y bars, any other chart's only ones.
                if let e = s.childrenNamed("errBars").first(where: { e in
                    e.childVal("errDir").map { d in bytesEqual(d, "y") || !scatterLike } ?? true
                }) {
                    let d = ErrorBars.default
                    let barType = e.childVal("errBarType") ?? "both"
                    let valType = e.childVal("errValType") ?? "fixedVal"
                    let value = e.childVal("val").flatMap { rustParseF64($0) }.flatMap { $0.isFinite ? $0 : nil } ?? d.value
                    let plus = e.child("plus").map { numbers($0, &budget) } ?? []
                    let minus = e.child("minus").map { numbers($0, &budget) } ?? []
                    let endCap = e.child("noEndCap")?.bool("val") != true
                    ser.errorBars = ErrorBars(barType: barType, valType: valType, value: value, plus: plus, minus: minus, endCap: endCap)
                }
                if let b = s.child("bubbleSize") {
                    ser.sizes = numbers(b, &budget)
                }
                c.series.append(ser)
            }
        }
        // `autoTitleDeleted val="0"` without `c:title`: PowerPoint and LibreOffice draw the series name as the title of a single-series chart.
        if ch.child("title") == nil && ch.child("autoTitleDeleted")?.bool("val") == false && c.series.count == 1 {
            c.title = c.series.first.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let first = kinds.first else { return nil }
        c.kind = kinds.contains { $0 != first } ? .combo : first
        if c.kind != .combo {
            for i in c.series.indices {
                c.series[i].kind = nil
                c.series[i].secondaryAxis = false
            }
        }
        // Axes.
        c.lang = root.childVal("lang")
        let valAxes = Array(pa.childrenNamed("valAx"))
        func byId(_ id: String?) -> XMLEl? {
            guard let id else { return nil }
            return valAxes.first { attrIs($0.childVal("axId"), id) }
        }
        let valAx = byId(primaryVal) ?? valAxes.first(where: isVertical) ?? valAxes.last
        func num(_ a: XMLEl, _ k: String) -> Double? {
            a.childVal(k).flatMap { rustParseF64($0) }.flatMap { $0.isFinite ? $0 : nil }
        }
        // An axis' number format: its own unless linked to the source (`sourceLinked="1"`, or no
        // c:numFmt at all), in which case the data's format of the first series plotted on it.
        func sourceFormat(_ ax: XMLEl) -> String? {
            let id = ax.childVal("axId")
            for g in pa.elements where g.childrenNamed("axId").contains(where: { optEqual($0.attr("val"), id) }) {
                for s in g.childrenNamed("ser") {
                    if let f = (s.child("val") ?? s.child("yVal"))?.find("numCache")?.child("formatCode")?.text {
                        return !f.isEmpty && !bytesEqual(f, "General") ? f : nil
                    }
                }
            }
            return nil
        }
        func formatCode(_ a: XMLEl) -> String? {
            let n = a.child("numFmt")
            if let n, !attrIs(n.attr("sourceLinked"), "1") { return n.attr("formatCode") }
            return sourceFormat(a) ?? n?.attr("formatCode")
        }
        func deleted(_ a: XMLEl) -> Bool {
            a.child("delete")?.bool("val") == true
        }
        if c.kind == .combo && c.series.contains(where: \.secondaryAxis) {
            let primaryId = valAx?.childVal("axId")
            // The other vertical value axis is the secondary one.
            if let a = valAxes.first(where: { !optEqual($0.childVal("axId"), primaryId) && isVertical($0) }) {
                let sc = a.child("scaling")
                c.y2Min = sc.flatMap { num($0, "min") }
                c.y2Max = sc.flatMap { num($0, "max") }
                c.y2Major = num(a, "majorUnit")
                c.y2Format = formatCode(a)
                c.y2Hidden = deleted(a)
            }
        }
        let catAx = pa.child("catAx") ?? pa.child("dateAx") ?? valAxes.first { !isVertical($0) }
        if let v = valAx {
            c.gridlines = v.child("majorGridlines") != nil
            c.minorGridlines = v.child("minorGridlines") != nil
            let sc = v.child("scaling")
            c.yMin = sc?.childVal("min").flatMap { rustParseF64($0) }.flatMap { $0.isFinite ? $0 : nil }
            c.yMax = sc?.childVal("max").flatMap { rustParseF64($0) }.flatMap { $0.isFinite ? $0 : nil }
            c.axisTitles.b = v.child("title").map { richText($0) ?? "Axis Title" }
            c.yMajor = num(v, "majorUnit")
            c.yLogBase = sc?.childVal("logBase").flatMap { rustParseF64($0) }.flatMap { $0.isFinite && $0 >= 2.0 ? $0 : nil }
            c.yFormat = formatCode(v)
            c.yHidden = deleted(v)
        }
        if let a = catAx {
            c.catReversed = attrIs(a.child("scaling")?.childVal("orientation"), "maxMin")
            c.axisTitles.a = a.child("title").map { richText($0) ?? "Axis Title" }
        }
        // Text sizes as the file sets them (PowerPoint draws chart text at these sizes, not scaled to
        // the chart): the axes' and legend's, else the whole chart's; the title's own.
        let chartSize = textSize(root.child("txPr"))
        let legend = ch.child("legend")
        c.textSize = [valAx, catAx, legend].compactMap { $0 }.lazy.compactMap { textSize($0.child("txPr")) }.first ?? chartSize
        // Text colour likewise: the axes' and legend's, else the whole chart's.
        c.textColor = [valAx, catAx, legend, root].compactMap { $0 }.lazy.compactMap { textColor($0.child("txPr")) }.first
        c.titleSize = ch.child("title").flatMap { t in textSize(t.child("tx")?.child("rich")) ?? textSize(t.child("txPr")) }
        return c
    }

    static func trendNum(_ e: XMLEl, _ k: String) -> Double? {
        e.childVal(k).flatMap { rustParseF64($0) }.flatMap { $0.isFinite && Swift.abs($0) <= 1.0e12 ? $0 : nil }
    }

    static func trendName(_ s: String) -> String? {
        var v = String.UnicodeScalarView()
        var n = 0
        for c in s.unicodeScalars where n < 255 {
            if c == "\t" || c == "\n" || c == "\r" || (c >= " " && c != "\u{FFFE}" && c != "\u{FFFF}") {
                v.append(c)
                n += 1
            }
        }
        let cleaned = rustTrim(String(v))
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    /// One `c:trendline`. Unknown types are skipped.
    static func trendline(_ e: XMLEl) -> Trendline? {
        guard let ty = e.childVal("trendlineType"), let kind = TrendlineType.fromXML(ty) else { return nil }
        return Trendline(
            kind: kind,
            name: e.child("name").map(\.text).flatMap(trendName),
            order: kind == .poly ? e.child("order")?.u32("val").map { Swift.min(Swift.max($0, 2), 6) } : nil,
            period: kind == .movingAvg ? e.child("period")?.u32("val").map { Swift.min(Swift.max($0, 2), 255) } : nil,
            forward: trendNum(e, "forward"),
            backward: trendNum(e, "backward"),
            intercept: trendNum(e, "intercept"),
            dispEq: e.child("dispEq")?.bool("val") ?? false,
            dispRSqr: e.child("dispRSqr")?.bool("val") ?? false
        )
    }

    /// The colour of the first `a:defRPr` or `a:rPr` with a solid fill under `e`.
    static func textColor(_ e: XMLEl?) -> ColorRef? {
        func rec(_ e: XMLEl, _ depth: Int) -> ColorRef? {
            if depth > 8 { return nil }
            for c in e.elements {
                if c.is("defRPr") || c.is("rPr"), case .solid(let color)? = simpleFill(c) {
                    return color
                }
                if let v = rec(c, depth + 1) { return v }
            }
            return nil
        }
        guard let e else { return nil }
        return rec(e, 0)
    }

    static let maxKeptParts = 256
    static let maxKeptDepth = 8
    static let maxKeptTotalBytes = 32 * 1024 * 1024

    /// Relationships and parts a chart points at, so a later save can write them back.
    static func captureKept(_ imp: Imp, _ chartPart: String) -> ChartKept {
        let key = ByteKey(OPC.norm(chartPart))
        if let cached = imp.keptCharts[key] { return cached }

        var kept = ChartKept()
        // The chart document itself is rewritten; don't store a second copy of it.
        var seen: [ByteKey: Bool] = [key: true]
        for r in imp.pkg.rels(chartPart).items {
            if !safeRel(r.id, r.ty, r.targetRaw) {
                PPTXLog.warn("pptx: skipping chart relationship \(r.id)")
                continue
            }
            if r.external {
                kept.rels.append(ChartRel(id: r.id, relType: r.ty, target: r.targetRaw, part: "", external: true))
                continue
            }
            if copyPart(imp.pkg, r.target, &kept.parts, &seen, &imp.keptSidecarBytes, 0) {
                kept.rels.append(ChartRel(id: r.id, relType: r.ty, target: r.targetRaw, part: r.target, external: false))
            }
        }
        imp.keptCharts[key] = kept
        return kept
    }

    static func safeRel(_ id: String, _ ty: String, _ target: String) -> Bool {
        [id, ty, target].allSatisfy { s in
            !s.isEmpty && s.utf8.count <= 4096
                && !s.unicodeScalars.contains { c in
                    c.properties.generalCategory == .control || c == "<" || c == ">" || c == "\"" || c == "'"
                }
        }
    }

    /// `true` when `part` is stored (now or from an earlier relationship).
    static func copyPart(
        _ pkg: Package, _ part: String, _ out: inout [ChartPart], _ seen: inout [ByteKey: Bool], _ retainedBytes: inout Int, _ depth: Int
    ) -> Bool {
        if depth > maxKeptDepth || out.count >= maxKeptParts {
            PPTXLog.warn("pptx: chart part closure stopped at \(part)")
            return false
        }
        let key = ByteKey(OPC.norm(part))
        if let ok = seen[key] { return ok }
        if !OPC.sidecarPart(part) {
            PPTXLog.warn("pptx: chart relationship target \(part) is not kept")
            seen[key] = false
            return false
        }
        guard let bytes = pkg.get(part) else {
            PPTXLog.warn("pptx: chart relationship target \(part) is missing")
            seen[key] = false
            return false
        }
        let name = String(OPC.trimLeadingSlashes(pkg.originalName(part) ?? part))
        if !OPC.sidecarPart(name) {
            PPTXLog.warn("pptx: chart part name \(name) is not kept")
            seen[key] = false
            return false
        }
        let contentType = pkg.contentType(part) ?? ""
        let storedBytes: [UInt8]
        if retainedBytes + bytes.count <= maxKeptTotalBytes {
            retainedBytes += bytes.count
            storedBytes = bytes
        } else {
            PPTXLog.warn("pptx: chart sidecar retained byte budget exceeded for \(part)")
            storedBytes = []
        }
        out.append(ChartPart(name: name, contentType: contentType, bytes: storedBytes, nativeEntry: nil))
        seen[key] = true
        let relsName = OPC.relsPath(part)
        let relsKey = ByteKey(OPC.norm(relsName))
        if OPC.sidecarPart(relsName), seen[relsKey] == nil, let relsBytes = pkg.get(relsName) {
            seen[relsKey] = true
            let name = String(OPC.trimLeadingSlashes(pkg.originalName(relsName) ?? relsName))
            let storedRels: [UInt8]
            if retainedBytes + relsBytes.count <= maxKeptTotalBytes {
                retainedBytes += relsBytes.count
                storedRels = relsBytes
            } else {
                storedRels = []
            }
            out.append(ChartPart(
                name: name, contentType: "application/vnd.openxmlformats-package.relationships+xml", bytes: storedRels, nativeEntry: nil
            ))
            let targets = pkg.rels(part).items.filter { !$0.external }.map(\.target)
            for target in targets {
                _ = copyPart(pkg, target, &out, &seen, &retainedBytes, depth + 1)
            }
        }
        return true
    }

    /// The size in points of the first `a:defRPr` or `a:rPr` with one under `e` (`sz` in hundredths).
    static func textSize(_ e: XMLEl?) -> Double? {
        func rec(_ e: XMLEl, _ depth: Int) -> Double? {
            if depth > 8 { return nil }
            for c in e.elements {
                if c.is("defRPr") || c.is("rPr"),
                   let v = c.attr("sz").flatMap({ rustParseF64($0) }), v.isFinite, v > 0.0
                {
                    return (v / 100.0).clamped(1.0, 400.0)
                }
                if let v = rec(c, depth + 1) { return v }
            }
            return nil
        }
        guard let e else { return nil }
        return rec(e, 0)
    }
}
