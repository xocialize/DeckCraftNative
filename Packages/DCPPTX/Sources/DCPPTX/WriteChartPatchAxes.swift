// DCPPTX — the rest of `chart.options` written into a kept chart part
// (`WriteChartPatch.swift`): axis titles, minor gridlines, the value axis's scale and number format, reversed
// categories, gap width and overlap, up/down bars, and each series' trendlines and error bars. The port's own
// (AB-T-0436): deckcraft has no command for them, and regenerates the part on any edit.
//
// | Setting | Elements it writes into the kept part |
// |---|---|
// | `axisTitles.category` | the category axis's `c:title` (text only; its formatting stays) |
// | `axisTitles.value` | the primary value axis's `c:title` |
// | `minorGridlines` | the primary value axis's `c:minorGridlines` |
// | `axisMin`, `axisMax`, `logBase` | the primary value axis's `c:scaling` `c:min`, `c:max`, `c:logBase` |
// | `majorUnit` | the primary value axis's `c:majorUnit` |
// | `numberFormat` | the primary value axis's `c:numFmt` (`sourceLinked="1"` when following the data) |
// | `reverseCategories` | the category axis's `c:scaling/c:orientation` |
// | `gapWidth`, `overlap` | every bar group's (and an of-pie group's) `c:gapWidth`, every flat bar group's `c:overlap` |
// | `upDownBars` | every line and stock group's `c:upDownBars` |
// | `chart.options` series trendline | the series' `c:trendline`s (the first one's line formatting stays) |
// | `chart.options` series errorBars | the series' value `c:errBars` (its line formatting stays) |
import CNCore
import DCModel

extension PPTXWrite.Charts {
    /// Everything this file owns, written into `pa` where `was` and `me` differ.
    static func patchAxesAndSeries(_ pa: inout XMLEl, _ was: Chart, _ me: Chart) {
        let valId = primaryValueAxis(pa)
        let catId = categoryAxis(pa)
        if let id = catId {
            let titleChanged = !PPTXRead.optEqual(was.axisTitles.a, me.axisTitles.a)
            if titleChanged || was.catReversed != me.catReversed {
                editAxis(&pa, id) { a in
                    if titleChanged { patchAxisTitle(&a, me.axisTitles.a, me, vertical: false) }
                    if was.catReversed != me.catReversed { setOrientation(&a, me.catReversed) }
                }
            }
        }
        if let id = valId {
            editAxis(&pa, id) { a in
                if !PPTXRead.optEqual(was.axisTitles.b, me.axisTitles.b) { patchAxisTitle(&a, me.axisTitles.b, me, vertical: PPTXRead.isVertical(a)) }
                if was.minorGridlines != me.minorGridlines {
                    a.remove("minorGridlines")
                    if me.minorGridlines { a.insert(el("c:minorGridlines"), after: ["axId", "scaling", "delete", "axPos", "majorGridlines"]) }
                }
                if was.yMin != me.yMin || was.yMax != me.yMax || was.yLogBase != me.yLogBase { patchScaling(&a, me) }
                if was.yMajor != me.yMajor {
                    a.remove("majorUnit")
                    if let u = me.yMajor { a.insert(el("c:majorUnit", fmtNum(u)), after: axisShared + ["crossBetween"]) }
                }
                if !PPTXRead.optEqual(was.yFormat, me.yFormat) { patchNumFmt(&a, me.yFormat) }
            }
        }
        if was.gapWidth != me.gapWidth || was.overlap != me.overlap { patchGapOverlap(&pa, was, me) }
        if was.upDownBars != me.upDownBars { patchUpDownBars(&pa, me.upDownBars) }
        if zip(was.series, me.series).contains(where: { $0.trendlines != $1.trendlines || $0.errorBars != $1.errorBars }) {
            patchSeriesExtras(&pa, was, me)
        }
    }

    /// The reader's category axis (`chartWithin`): the first `c:catAx`, else `c:dateAx`, else the first
    /// horizontal value axis (a scatter chart's x axis).
    static func categoryAxis(_ pa: XMLEl) -> String? {
        let a = pa.child("catAx") ?? pa.child("dateAx") ?? pa.childrenNamed("valAx").first { !PPTXRead.isVertical($0) }
        return a?.childVal("axId")
    }

    static func editAxis(_ pa: inout XMLEl, _ id: String, _ body: (inout XMLEl) -> Void) {
        var done = false
        pa.elementsMut { a in
            guard !done, a.is("catAx") || a.is("valAx") || a.is("dateAx"), PPTXRead.optEqual(a.childVal("axId"), id) else { return }
            body(&a)
            done = true
        }
    }

    /// The children every axis starts with (EG_AxShared), in schema order, up to the crossing.
    static let axisShared = [
        "axId", "scaling", "delete", "axPos", "majorGridlines", "minorGridlines", "title", "numFmt", "majorTickMark",
        "minorTickMark", "tickLblPos", "spPr", "txPr", "crossAx", "crosses", "crossesAt",
    ]

    static func patchAxisTitle(_ a: inout XMLEl, _ text: String?, _ c: Chart, vertical: Bool) {
        guard let text else {
            a.remove("title")
            return
        }
        let lines = PPTXWrite.splitScalars(text, ["\n"])
        if !a.edit("title", { t in setTitleText(&t, lines, c) }) {
            var w = W.new()
            title(&w, text, c)
            guard var fresh = try? parseXML(w.finish()).root else { return }
            // A vertical axis's title reads bottom to top, as PowerPoint writes it.
            if vertical {
                _ = fresh.edit("tx") { tx in _ = tx.edit("rich") { r in _ = r.edit("bodyPr") { b in
                    b.setAttr("rot", "-5400000")
                    b.setAttr("vert", "horz")
                } } }
            }
            a.insert(fresh, after: ["axId", "scaling", "delete", "axPos", "majorGridlines", "minorGridlines"])
        }
    }

    static func setOrientation(_ a: inout XMLEl, _ reversed: Bool) {
        let v = reversed ? "maxMin" : "minMax"
        if !a.edit("scaling", { sc in
            if !sc.edit("orientation", { $0.setAttr("val", v) }) { sc.insert(el("c:orientation", v), after: ["logBase"]) }
        }) {
            a.insert(el("c:scaling", nil, [el("c:orientation", v)]), after: ["axId"])
        }
    }

    /// `c:scaling`'s log base, maximum and minimum (CT_Scaling: logBase, orientation, max, min); the
    /// orientation stays.
    static func patchScaling(_ a: inout XMLEl, _ me: Chart) {
        if a.child("scaling") == nil { a.insert(el("c:scaling", nil, [el("c:orientation", "minMax")]), after: ["axId"]) }
        _ = a.edit("scaling") { sc in
            for k in ["logBase", "max", "min"] { sc.remove(k) }
            if let b = me.yLogBase { sc.insert(el("c:logBase", fmtNum(b)), after: []) }
            if let m = me.yMax { sc.insert(el("c:max", fmtNum(m)), after: ["logBase", "orientation"]) }
            if let m = me.yMin { sc.insert(el("c:min", fmtNum(m)), after: ["logBase", "orientation", "max"]) }
        }
    }

    /// The axis's own number format, or `sourceLinked` to follow the data's.
    static func patchNumFmt(_ a: inout XMLEl, _ format: String?) {
        let attrs: [(String, String)] = format.map { [("formatCode", $0), ("sourceLinked", "0")] } ?? [("formatCode", "General"), ("sourceLinked", "1")]
        if !a.edit("numFmt", { n in for (k, v) in attrs { n.setAttr(k, v) } }) {
            a.insert(XMLEl(name: "c:numFmt", attrs: attrs), after: ["axId", "scaling", "delete", "axPos", "majorGridlines", "minorGridlines", "title"])
        }
    }

    // MARK: - Plot groups

    /// A bar group's children before its gap width (CT_BarChart, CT_Bar3DChart, CT_OfPieChart).
    static let beforeGap = ["barDir", "grouping", "ofPieType", "varyColors", "ser", "dLbls"]

    static func patchGapOverlap(_ pa: inout XMLEl, _ was: Chart, _ me: Chart) {
        let gap = "\(Int64(rustCast: (me.gapWidth.clamped(0.0, 5.0) * 100.0).rounded()))"
        let ov = "\(Int64(rustCast: (me.overlap.clamped(-1.0, 1.0) * 100.0).rounded()))"
        pa.elementsMut { g in
            let bars = g.is("barChart") || g.is("bar3DChart")
            guard bars || g.is("ofPieChart") else { return }
            if was.gapWidth != me.gapWidth || g.child("gapWidth") == nil && bars {
                if !g.edit("gapWidth", { $0.setAttr("val", gap) }) { g.insert(el("c:gapWidth", gap), after: beforeGap) }
            }
            // Stacked bars overlap fully, whatever the setting (the generator writes 100).
            let stacked = g.childVal("grouping").map { bytesEqual($0, "stacked") || bytesEqual($0, "percentStacked") } ?? false
            if g.is("barChart"), was.overlap != me.overlap, !stacked {
                if !g.edit("overlap", { $0.setAttr("val", ov) }) { g.insert(el("c:overlap", ov), after: beforeGap + ["gapWidth"]) }
            }
        }
    }

    /// Up/down bars between a line or stock group's first and last series (CT_LineChart, CT_StockChart:
    /// …, dLbls, dropLines, hiLowLines, upDownBars, marker, smooth, axId).
    static func patchUpDownBars(_ pa: inout XMLEl, _ on: Bool) {
        pa.elementsMut { g in
            guard g.is("lineChart") || g.is("stockChart") else { return }
            g.remove("upDownBars")
            if on {
                let bars = el("c:upDownBars", nil, [el("c:gapWidth", "150"), el("c:upBars"), el("c:downBars")])
                g.insert(bars, after: ["grouping", "varyColors", "ser", "dLbls", "dropLines", "hiLowLines"])
            }
        }
    }

    // MARK: - Series

    /// A series' children before its trendlines and error bars (CT_BarSer, CT_LineSer, CT_AreaSer,
    /// CT_ScatterSer, CT_BubbleSer).
    static let beforeTrendline = ["idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "marker", "dPt", "dLbls"]

    /// Each series' trendlines and value error bars, position by position as the reader takes them.
    static func patchSeriesExtras(_ pa: inout XMLEl, _ was: Chart, _ me: Chart) {
        let groups = { (g: XMLEl) in plotGroups.contains { g.is($0) } }
        var i = 0
        pa.elementsMut { g in
            guard groups(g) else { return }
            let scatterLike = g.is("scatterChart") || g.is("bubbleChart")
            g.elementsMut { s in
                guard s.is("ser") else { return }
                defer { i += 1 }
                guard i < me.series.count, i < was.series.count else { return }
                if was.series[i].trendlines != me.series[i].trendlines { setTrendlines(&s, me.series[i].trendlines) }
                if was.series[i].errorBars != me.series[i].errorBars { setErrorBars(&s, me.series[i].errorBars, scatterLike) }
            }
        }
    }

    static func setTrendlines(_ s: inout XMLEl, _ ts: [Trendline]) {
        // The first one's line keeps its look.
        let look = s.child("trendline")?.child("spPr")
        s.remove("trendline")
        var at = s.children.lastIndex { n in if case .el(let x) = n { beforeTrendline.contains { x.is($0) } } else { false } }.map { $0 + 1 } ?? 0
        for (n, t) in ts.prefix(16).enumerated() {
            var w = W.new()
            trendline(&w, t)
            guard var e = try? parseXML(w.finish()).root else { continue }
            // CT_Trendline: name, spPr, trendlineType…
            if n == 0, let look { e.insert(look, after: ["name"]) }
            s.children.insert(.el(e), at: at)
            at += 1
        }
    }

    static func setErrorBars(_ s: inout XMLEl, _ e: ErrorBars?, _ scatterLike: Bool) {
        // The value bars: a scatter chart's y bars, any other chart's only ones (`chartWithin`).
        func isValueBars(_ b: XMLEl) -> Bool {
            b.childVal("errDir").map { d in bytesEqual(d, "y") || !scatterLike } ?? true
        }
        var look: XMLEl?
        if let i = s.children.firstIndex(where: { if case .el(let x) = $0 { x.is("errBars") && isValueBars(x) } else { false } }),
           case .el(let old) = s.children[i] {
            look = old.child("spPr")
            s.children.remove(at: i)
        }
        guard let e else { return }
        var w = W.new()
        errorBars(&w, e, scatterLike)
        guard var fresh = try? parseXML(w.finish()).root else { return }
        // CT_ErrBars: …, plus, minus, val, spPr.
        if let look { fresh.children.append(.el(look)) }
        s.insert(fresh, after: beforeTrendline + ["trendline", "errBars"])
    }
}
