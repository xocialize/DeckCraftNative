// DCPPTX — an edited chart that keeps its original part. `chart.options` (title, legend, data labels,
// gridlines) and `chart.data` (categories, series names and values) are written into the kept
// `c:chartSpace` instead of regenerating it, so what the model doesn't hold survives the edit: the style and
// colour parts, label positions, fills, 3-D, the extension lists, and the workbook (updated with the new
// data by `WriteChartWorkbook.swift`, AB-T-0435). The port's own (AB-T-0433): deckcraft regenerates the part on any change. The patch is used
// only when reading it back gives the model; anything else goes to the generator, as before.
//
// Which command owns which element of the kept part:
//
// | Command | Elements it writes into the kept part |
// |---|---|
// | `chart.options` title | `c:title` (text only; its formatting stays), `c:autoTitleDeleted` |
// | `chart.options` legend | `c:legend`, `c:legendPos` |
// | `chart.options` dataLabels | `c:showVal` in every plot group's and series' `c:dLbls` |
// | `chart.options` gridlines | the primary value axis's `c:majorGridlines` |
// | `chart.data` | every series' `c:tx`, `c:cat`, `c:val` (`c:xVal`, `c:yVal`, `c:bubbleSize`): caches and `c:f`; series added or removed; `c:externalData` and the workbook taken out here, then linked again to the original workbook with the new cells, or to a new one (`WriteChartWorkbook.swift`) |
// | `chart.options` axis titles, minor gridlines, axis scale and format, reversed categories, gap and overlap, up/down bars, a series' trendline and error bars | `WriteChartPatchAxes.swift` (AB-T-0436) |
// | anything else (`chart.type`, palette, text colour, bins, subtotals, quartiles) | none: the part is regenerated |
import CNCore
import DCModel

extension PPTXWrite.Charts {
    /// The kept part with the model's title, legend, data labels, gridlines and data written into it, and
    /// whether the data changed (the workbook link then goes here: `chartRel` links the updated or new workbook,
    /// `WriteChartWorkbook.swift`); or nil.
    static func patchedXML(_ c: Chart) -> (xml: [UInt8], data: Bool)? {
        guard let raw = c.raw, !PPTXWrite.utf8Contains(raw, PPTXWrite.nsCX), let doc = try? parseXML(raw) else { return nil }
        var root = doc.root
        // Inserted elements are written with the writer's prefixes, so the part must use them.
        guard bytesEqual(root.name, "c:chartSpace"), declares(root, "xmlns:c", OPC.nsC), declares(root, "xmlns:a", OPC.nsA),
              let was = reread(root) else { return nil }
        var me = c
        me.raw = nil
        me.kept = ChartKept()
        me = labelsNormalized(me)
        let data = dataChanged(was, me)
        var axisless = false
        var barless = false
        var patched = true
        guard root.edit("chart", { ch in
            if !PPTXRead.optEqual(was.title, me.title) { patchTitle(&ch, me.title, me) }
            if !PPTXRead.optEqual(was.legend, me.legend) { patchLegend(&ch, me.legend) }
            ch.edit("plotArea") { pa in
                if data { patched = patchData(&pa, me) }
                // Series that both have: `chart.data` keeps each one's own labels, `chart.options` clears them.
                if was.dataLabels != me.dataLabels || zip(was.series, me.series).contains(where: { $0.dataLabels != $1.dataLabels }) {
                    patchLabels(&pa, me.dataLabels)
                }
                axisless = primaryValueAxis(pa) == nil
                barless = !pa.elements.contains { $0.is("lineChart") || $0.is("stockChart") }
                if was.gridlines != me.gridlines { patchGridlines(&pa, me.gridlines) }
                // Axis titles and scale, gap and overlap, up/down bars, trendlines, error bars (AB-T-0436).
                patchAxesAndSeries(&pa, was, me)
            }
        }), patched, let now = reread(root) else { return nil }
        // What the reader derives from an element the edit removed has nowhere left to stay: the title's
        // size, and the chart's text size and colour where it took them from the legend. Gridlines need a
        // value axis (a pie has none). PowerPoint's own text elements keep their formatting either way.
        if me.title == nil { me.titleSize = now.titleSize }
        if me.legend == nil && was.legend != nil {
            me.textSize = now.textSize
            me.textColor = now.textColor
        }
        if axisless { me.gridlines = now.gridlines }
        // Up/down bars need a line or stock group: `chart.options` takes them on any chart, as deckcraft's does,
        // and the generator writes them for those groups only (AB-T-0436).
        if barless { me.upDownBars = now.upDownBars }
        // An axis that follows the data's number format shows the data's (`chartWithin`).
        if me.yFormat == nil && was.yFormat != nil { me.yFormat = now.yFormat }
        // A scatter or bubble chart's categories are its x values: the generator doesn't write them either.
        if data && (me.kind == .scatter || me.kind == .bubble) { me.categories = now.categories }
        // A bubble without a size is written at size 1, as the generator writes it.
        if data && me.kind == .bubble {
            for (i, s) in zip(me.series.indices, now.series) where me.series[i].sizes.isEmpty && s.sizes.allSatisfy({ $0 == 1.0 }) {
                me.series[i].sizes = s.sizes
            }
        }
        if data && me.kind == .combo {
            // A combo chart's series without a type of its own is a clustered column (`Chart.seriesKind`).
            for i in me.series.indices where me.series[i].kind == nil { me.series[i].kind = .column }
            // The secondary axis's settings are read only while a series is plotted on it.
            if !me.series.contains(where: \.secondaryAxis) {
                (me.y2Min, me.y2Max, me.y2Major, me.y2Format, me.y2Hidden) = (now.y2Min, now.y2Max, now.y2Major, now.y2Format, now.y2Hidden)
            }
        }
        guard now == me else { return nil }
        // Without the parts those elements point at, PowerPoint repairs the file.
        var kept = c
        if data { kept.kept = withoutWorkbook(c.kept) }
        dropUnkeptRefs(&root, kept)
        var w = W.new()
        w.raw(root.toXML())
        return (w.finish(), data)
    }

    static func declares(_ e: XMLEl, _ key: String, _ ns: String) -> Bool {
        e.attrs.contains { bytesEqual($0.key, key) && bytesEqual($0.value, ns) }
    }

    /// The model the reader makes of `root`, labels normalized.
    static func reread(_ root: XMLEl) -> Chart? {
        var r = root
        PPTXRead.resolveMC(&r, 0)
        return PPTXRead.chartFromEl(r).map(labelsNormalized)
    }

    /// A series' data labels equal to the chart's say nothing (`Chart` resolves `s.dataLabels ?? dataLabels`):
    /// the reader gives `false` where the group turns them off, and `chart.options` clears the series' own.
    static func labelsNormalized(_ c: Chart) -> Chart {
        var c = c
        for i in c.series.indices where c.series[i].dataLabels == c.dataLabels {
            c.series[i].dataLabels = nil
        }
        return c
    }

    static func el(_ name: String, _ val: String? = nil, _ children: [XMLEl] = []) -> XMLEl {
        XMLEl(name: name, attrs: val.map { [("val", $0)] } ?? [], children: children.map { .el($0) })
    }

    // MARK: - Title

    /// `c:chart`'s children in schema order (CT_Chart).
    static let chartOrder = ["title", "autoTitleDeleted", "pivotFmts", "view3D", "floor", "sideWall", "backWall", "plotArea", "legend"]

    static func patchTitle(_ ch: inout XMLEl, _ title: String?, _ c: Chart) {
        guard let title else {
            ch.remove("title")
            if !ch.edit("autoTitleDeleted", { $0.setAttr("val", "1") }) {
                ch.insert(el("c:autoTitleDeleted", "1"), after: [])
            }
            return
        }
        let lines = PPTXWrite.splitScalars(title, ["\n"])
        if !ch.edit("title", { t in setTitleText(&t, lines, c) }) {
            var w = W.new()
            Self.title(&w, title, c)
            guard let fresh = try? parseXML(w.finish()).root else { return }
            ch.insert(fresh, after: [])
        }
        _ = ch.edit("autoTitleDeleted") { $0.setAttr("val", "0") }
    }

    /// The title's text, keeping the first paragraph's and run's formatting for every line.
    static func setTitleText(_ t: inout XMLEl, _ lines: [String], _ c: Chart) {
        var template: (pPr: XMLEl?, rPr: XMLEl?, end: XMLEl?) = (nil, nil, nil)
        var kept: [XMLNode] = []
        if let rich = t.child("tx")?.child("rich") {
            if let p = rich.child("p") {
                template = (p.child("pPr"), p.child("r")?.child("rPr"), p.child("endParaRPr"))
            }
            kept = rich.children.filter { if case .el(let e) = $0 { return !e.is("p") } else { return false } }
        } else {
            kept = [.el(el("a:bodyPr")), .el(el("a:lstStyle"))]
        }
        let paras: [XMLNode] = lines.map { line in
            var p = XMLEl(name: "a:p")
            if let pPr = template.pPr { p.children.append(.el(pPr)) }
            var r = XMLEl(name: "a:r")
            if let rPr = template.rPr { r.children.append(.el(rPr)) }
            r.children.append(.el(XMLEl(name: "a:t", children: [.text(line)])))
            p.children.append(.el(r))
            if let end = template.end { p.children.append(.el(end)) }
            return .el(p)
        }
        let tx = el("c:tx", nil, [XMLEl(name: "c:rich", children: kept + paras)])
        t.remove("tx")
        // `c:tx` comes first in a title (CT_Title).
        t.children.insert(.el(tx), at: 0)
    }

    // MARK: - Legend

    static func patchLegend(_ ch: inout XMLEl, _ pos: String?) {
        guard let pos else {
            ch.remove("legend")
            return
        }
        if !ch.edit("legend", { l in
            if !l.edit("legendPos", { $0.setAttr("val", pos) }) { l.insert(el("c:legendPos", pos), after: []) }
        }) {
            ch.insert(el("c:legend", nil, [el("c:legendPos", pos), el("c:overlay", "0")]), after: chartOrder)
        }
    }

    // MARK: - Data labels

    /// The label switches in a `c:dLbls`, in schema order (Group_DLbls).
    static let labelOrder = ["dLbl", "numFmt", "spPr", "txPr", "dLblPos", "showLegendKey", "showVal"]

    static func freshLabels(_ on: Bool) -> XMLEl {
        el("c:dLbls", nil, [el("c:showLegendKey", "0"), el("c:showVal", on ? "1" : "0"), el("c:showCatName", "0"),
                            el("c:showSerName", "0"), el("c:showPercent", "0"), el("c:showBubbleSize", "0")])
    }

    /// Every plot group's labels on or off, and the series follow it (`chart.options` clears their own).
    /// Label formatting and positions stay.
    static func patchLabels(_ pa: inout XMLEl, _ on: Bool) {
        let flag = on ? "1" : "0"
        func setShow(_ d: inout XMLEl) {
            if !d.edit("showVal", { $0.setAttr("val", flag) }) { d.insert(el("c:showVal", flag), after: labelOrder) }
        }
        func deleted(_ d: XMLEl) -> Bool { d.child("delete")?.bool("val") ?? (d.child("delete") != nil) }
        pa.elementsMut { g in
            guard hasByteSuffix(g.local, "Chart") else { return }
            g.elementsMut { s in
                guard s.is("ser"), let d = s.child("dLbls") else { return }
                if deleted(d) {
                    s.remove("dLbls")
                } else if d.child("showVal") != nil {
                    _ = s.edit("dLbls", setShow)
                }
            }
            if let d = g.child("dLbls"), !deleted(d) {
                _ = g.edit("dLbls", setShow)
            } else if on {
                g.remove("dLbls")
                g.insert(freshLabels(true), after: ["ser"])
            }
        }
    }

    // MARK: - Gridlines

    /// The reader's primary value axis (`chartWithin`): the first one a plot group uses that isn't placed as
    /// a secondary axis, else the first one used, else the first vertical one, else the last.
    static func primaryValueAxis(_ pa: XMLEl) -> String? {
        let axes = Array(pa.childrenNamed("valAx"))
        func vertical(_ a: XMLEl) -> Bool { PPTXRead.isVertical(a) }
        func byId(_ id: String) -> XMLEl? { axes.first { PPTXRead.optEqual($0.childVal("axId"), id) } }
        let used: [String] = pa.elements.filter { hasByteSuffix($0.local, "Chart") }.compactMap { g in
            let ids = g.childrenNamed("axId").compactMap { $0.attr("val") }.compactMap { id in byId(id).map { (id, vertical($0)) } }
            return (ids.first { $0.1 } ?? ids.first)?.0
        }
        func secondaryPlaced(_ a: XMLEl) -> Bool {
            let p = a.childVal("axPos")
            return PPTXRead.attrIs(a.childVal("crosses"), "max") || PPTXRead.attrIs(p, "r") || PPTXRead.attrIs(p, "t")
        }
        let primary = used.first { id in byId(id).map { !secondaryPlaced($0) } ?? false } ?? used.first
        let axis = primary.flatMap(byId) ?? axes.first(where: vertical) ?? axes.last
        return axis?.childVal("axId")
    }

    static func patchGridlines(_ pa: inout XMLEl, _ on: Bool) {
        guard let id = primaryValueAxis(pa) else { return }
        pa.elementsMut { a in
            guard a.is("valAx"), PPTXRead.optEqual(a.childVal("axId"), id) else { return }
            a.remove("majorGridlines")
            // CT_ValAx: axId, scaling, delete, axPos, then majorGridlines.
            if on { a.insert(el("c:majorGridlines"), after: ["axId", "scaling", "delete", "axPos"]) }
        }
    }
}

extension PPTXWrite.Charts {
    // MARK: - Data

    /// Whether `chart.data` changed anything: categories, levels, the series, their names or values.
    static func dataChanged(_ a: Chart, _ b: Chart) -> Bool {
        a.categories != b.categories || a.categoryLevels != b.categoryLevels || a.series.count != b.series.count
            || zip(a.series, b.series).contains { x, y in
                x.name != y.name || x.values != y.values || x.xValues != y.xValues || x.sizes != y.sizes
            }
    }

    /// The plot groups the reader reads (`chartWithin`), whose series make the model's, in file order.
    static let plotGroups = [
        "barChart", "bar3DChart", "lineChart", "line3DChart", "areaChart", "area3DChart", "pieChart", "pie3DChart",
        "ofPieChart", "doughnutChart", "scatterChart", "bubbleChart", "radarChart", "stockChart", "surfaceChart",
        "surface3DChart",
    ]

    /// A chart's kept parts without its workbook (embedded or linked): once the data is edited, its cells
    /// would contradict the chart, and PowerPoint's Edit Data would bring the old numbers back. The writer
    /// links the original updated with the new data, or a new workbook, instead (`WriteChartWorkbook.swift`).
    static func withoutWorkbook(_ k: ChartKept) -> ChartKept {
        func book(_ r: ChartRel) -> Bool { hasByteSuffix(r.relType, "/package") || hasByteSuffix(r.relType, "/oleObject") }
        var out = k
        out.rels = k.rels.filter { !book($0) }
        let still = Set(out.rels.map { ByteKey(OPC.norm($0.part)) })
        let gone = Set(k.rels.filter { book($0) && !$0.external }.map { ByteKey(OPC.norm($0.part)) }).subtracting(still)
        out.parts = k.parts.filter { !gone.contains(ByteKey(OPC.norm($0.name))) }
        return out
    }

    /// The model's series written into the plot groups' `c:ser`s, position by position: extra ones removed,
    /// new ones copied from the last series without its formatting. Every range is the generator's: the
    /// workbook is written to that layout (`WriteChartWorkbook.swift`). False when there is no series to start from.
    static func patchData(_ pa: inout XMLEl, _ me: Chart) -> Bool {
        let groups = { (g: XMLEl) in plotGroups.contains { g.is($0) } }
        // New series follow the last one, in its group: the reader takes series in file order. In a combo
        // chart that group must be clustered columns, what a series without a type of its own is.
        func columns(_ e: XMLEl) -> Bool {
            e.is("barChart") && !PPTXRead.attrIs(e.childVal("barDir"), "bar")
                && (e.childVal("grouping").map { bytesEqual($0, "clustered") } ?? true)
        }
        var template: XMLEl?
        var lastGroup = -1
        var lastColumns = false
        var nextIdx = 0
        var g = 0
        var tooMany = false
        var total = 0
        for e in pa.elements where groups(e) {
            let sers = Array(e.childrenNamed("ser"))
            if sers.count > 1000 { tooMany = true }
            total += sers.count
            if let s = sers.last {
                template = s
                lastGroup = g
                lastColumns = columns(e)
            }
            for s in sers { nextIdx = Swift.max(nextIdx, Int(s.child("idx")?.u32("val") ?? 0) + 1) }
            g += 1
        }
        let adding = me.series.count > total
        guard !tooMany, !adding || (template != nil && (me.kind != .combo || lastColumns)) else { return false }
        var i = 0
        g = 0
        pa.elementsMut { e in
            guard groups(e) else { return }
            var out: [XMLNode] = []
            var lastSer = -1
            for n in e.children {
                guard case .el(var s) = n, s.is("ser") else {
                    out.append(n)
                    continue
                }
                if i < me.series.count {
                    setSeriesData(&s, i, me)
                    out.append(.el(s))
                    lastSer = out.count - 1
                    i += 1
                }
            }
            if g == lastGroup, let template {
                var fresh: [XMLNode] = []
                while i < me.series.count {
                    var s = cloneSeries(template, nextIdx)
                    nextIdx += 1
                    setSeriesData(&s, i, me)
                    // The model's new series has no number format of its own.
                    for k in ["val", "yVal"] {
                        _ = s.edit(k) { v in _ = v.edit("numRef") { r in _ = r.edit("numCache") { $0.remove("formatCode") } } }
                    }
                    fresh.append(.el(s))
                    i += 1
                }
                out.insert(contentsOf: fresh, at: lastSer + 1)
            }
            e.children = out
            g += 1
        }
        return i == me.series.count
    }

    /// A new series from `t`: its kind of data and nothing of its look (fill, points, labels, trendlines,
    /// error bars, its extension list with PowerPoint's unique id).
    static func cloneSeries(_ t: XMLEl, _ idx: Int) -> XMLEl {
        var s = XMLEl(name: t.name, attrs: t.attrs)
        let data = ["tx", "cat", "val", "xVal", "yVal", "bubbleSize", "invertIfNegative", "bubble3D", "shape"]
        for case .el(let e) in t.children {
            if e.is("idx") || e.is("order") {
                s.children.append(.el(el(e.name, "\(idx)")))
            } else if e.is("marker") {
                // A line chart without markers says so on every series.
                if PPTXRead.attrIs(e.child("symbol")?.attr("val"), "none") { s.children.append(.el(e)) }
            } else if e.is("smooth") {
                s.children.append(.el(el(e.name, "0")))
            } else if data.contains(where: { e.is($0) }) {
                s.children.append(.el(e))
            }
        }
        return s
    }

    /// Series `i`'s name, categories (or x values) and values, with the generator's ranges.
    static func setSeriesData(_ s: inout XMLEl, _ i: Int, _ me: Chart) {
        let ser = me.series[i]
        let last = Swift.max(me.categories.count, ser.values.count) + 1
        let column = col(i + 1)
        let values = "Sheet1!$\(column)$2:$\(column)$\(last)"
        if !s.edit("tx", { setStrings(&$0, "Sheet1!$\(column)$1", [ser.name]) }) {
            var tx = el("c:tx")
            setStrings(&tx, "Sheet1!$\(column)$1", [ser.name])
            s.insert(tx, after: ["idx", "order"])
        }
        let scatterLike = s.child("xVal") != nil || s.child("yVal") != nil
        if scatterLike {
            // Without x values the points are numbered 1, 2, 3…, in PowerPoint as in the model.
            if ser.xValues.isEmpty {
                s.remove("xVal")
            } else {
                setData(&s, "xVal", "Sheet1!$A$2:$A$\(last)", ser.xValues, after: ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "trendline", "errBars"])
            }
            setData(&s, "yVal", values, ser.values, after: ["xVal"])
            if s.child("bubbleSize") != nil {
                let c2 = col(i + 2)
                let sizes: [Double?] = ser.sizes.isEmpty ? ser.values.map { _ in Optional(1.0) } : ser.sizes
                setData(&s, "bubbleSize", "Sheet1!$\(c2)$2:$\(c2)$\(last)", sizes, after: ["yVal"])
            }
        } else {
            let cats = "Sheet1!$A$2:$A$\(last)"
            if !s.edit("cat", { cat in
                if PPTXRead.stringsCapped(cat, PPTXRead.maxCachePoints) == me.categories {
                    setRange(&cat, cats)
                } else {
                    var w = W.new()
                    strCache(&w, cats, me.categories)
                    if let r = try? parseXML(w.finish()).root { cat.children = [.el(r)] }
                }
            }) {
                var cat = el("c:cat")
                var w = W.new()
                strCache(&w, cats, me.categories)
                if let r = try? parseXML(w.finish()).root { cat.children = [.el(r)] }
                s.insert(cat, after: ["idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "marker", "explosion", "dPt", "dLbls", "trendline", "errBars"])
            }
            setData(&s, "val", values, ser.values, after: ["cat"])
        }
    }

    /// A one-string `c:tx`: the cached name in a `c:strRef`, or a literal `c:v`.
    static func setStrings(_ tx: inout XMLEl, _ f: String, _ vals: [String]) {
        if PPTXRead.stringsCapped(tx, PPTXRead.maxCachePoints) == vals, tx.child("strRef") != nil || tx.child("v") != nil {
            _ = tx.edit("strRef") { setRange(&$0, f) }
            return
        }
        if vals.count == 1, tx.child("v") != nil, tx.child("strRef") == nil {
            _ = tx.edit("v") { $0.children = [.text(vals[0])] }
            return
        }
        var w = W.new()
        strCache(&w, f, vals)
        if let r = try? parseXML(w.finish()).root { tx.children = [.el(r)] }
    }

    /// Numbers in `s`'s `name` element: the cache rewritten (keeping its number format) or, when it already
    /// holds them, only the range.
    static func setData(_ s: inout XMLEl, _ name: String, _ f: String, _ vals: [Double?], after: [String]) {
        func fresh(_ format: String?) -> XMLEl? {
            var w = W.new()
            numCache(&w, f, vals)
            guard var r = try? parseXML(w.finish()).root else { return nil }
            _ = r.edit("numCache") { c in
                if let format { _ = c.edit("formatCode") { $0.children = [.text(format)] } } else { c.remove("formatCode") }
            }
            return r
        }
        if !s.edit(name, { d in
            var budget = PPTXRead.maxCachePoints
            if PPTXRead.numbers(d, &budget) == vals {
                setRange(&d, f)
            } else if d.child("numLit") != nil {
                var w = W.new()
                numLit(&w, vals)
                if let r = try? parseXML(w.finish()).root { d.children = [.el(r)] }
            } else {
                let format = d.child("numRef")?.child("numCache")?.child("formatCode").map(\.text)
                if let r = fresh(format ?? "General") { d.children = [.el(r)] }
            }
        }) {
            if let r = fresh("General") { s.insert(el("c:\(name)", nil, [r]), after: after) }
        }
    }

    /// The `c:f` of a `c:strRef` or `c:numRef` inside `d` (or `d` itself); a multi-level one keeps its own.
    static func setRange(_ d: inout XMLEl, _ f: String) {
        if d.is("strRef") || d.is("numRef") {
            if !d.edit("f", { $0.children = [.text(f)] }) { d.insert(el("c:f"), after: []) ; _ = d.edit("f") { $0.children = [.text(f)] } }
            return
        }
        for k in ["strRef", "numRef"] { _ = d.edit(k) { setRange(&$0, f) } }
    }
}

extension XMLEl {
    /// Calls `body` on the first child element named `local`, in place; false when there is none.
    @discardableResult
    mutating func edit(_ local: String, _ body: (inout XMLEl) -> Void) -> Bool {
        guard let i = children.firstIndex(where: { if case .el(let e) = $0 { e.is(local) } else { false } }),
              case .el(var e) = children[i] else { return false }
        children[i] = .text("") // drop the second reference so `e` mutates in place
        body(&e)
        children[i] = .el(e)
        return true
    }

    mutating func remove(_ local: String) {
        children.removeAll { if case .el(let e) = $0 { e.is(local) } else { false } }
    }

    /// Inserts `e` after the last child named one of `after` (the elements that come before it), else first.
    mutating func insert(_ e: XMLEl, after: [String]) {
        let i = children.lastIndex { n in if case .el(let x) = n { after.contains { x.is($0) } } else { false } }
        children.insert(.el(e), at: i.map { $0 + 1 } ?? 0)
    }
}
