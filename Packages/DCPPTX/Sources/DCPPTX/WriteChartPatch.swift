// DCPPTX — an edited chart that keeps its original part. `chart.options` (title, legend, data labels,
// gridlines) is written into the kept `c:chartSpace` instead of regenerating it, so what the model doesn't
// hold survives the edit: the workbook link, the style and colour parts, label positions, fills, 3-D, the
// extension lists. The port's own (AB-T-0433): deckcraft regenerates the part on any change. The patch is
// used only when reading it back gives the model; anything else goes to the generator, as before.
import CNCore
import DCModel

extension PPTXWrite.Charts {
    /// The kept part with the model's title, legend, data labels and gridlines written into it, or nil.
    static func patchedXML(_ c: Chart) -> [UInt8]? {
        guard let raw = c.raw, !PPTXWrite.utf8Contains(raw, PPTXWrite.nsCX), let doc = try? parseXML(raw) else { return nil }
        var root = doc.root
        // Inserted elements are written with the writer's prefixes, so the part must use them.
        guard bytesEqual(root.name, "c:chartSpace"), declares(root, "xmlns:c", OPC.nsC), declares(root, "xmlns:a", OPC.nsA),
              let was = reread(root) else { return nil }
        var me = c
        me.raw = nil
        me.kept = ChartKept()
        me = labelsNormalized(me)
        var axisless = false
        guard root.edit("chart", { ch in
            if !PPTXRead.optEqual(was.title, me.title) { patchTitle(&ch, me.title, me) }
            if !PPTXRead.optEqual(was.legend, me.legend) { patchLegend(&ch, me.legend) }
            ch.edit("plotArea") { pa in
                if was.dataLabels != me.dataLabels || was.series.map(\.dataLabels) != me.series.map(\.dataLabels) {
                    patchLabels(&pa, me.dataLabels)
                }
                axisless = primaryValueAxis(pa) == nil
                if was.gridlines != me.gridlines { patchGridlines(&pa, me.gridlines) }
            }
        }), let now = reread(root) else { return nil }
        // What the reader derives from an element the edit removed has nowhere left to stay: the title's
        // size, and the chart's text size and colour where it took them from the legend. Gridlines need a
        // value axis (a pie has none). PowerPoint's own text elements keep their formatting either way.
        if me.title == nil { me.titleSize = now.titleSize }
        if me.legend == nil && was.legend != nil {
            me.textSize = now.textSize
            me.textColor = now.textColor
        }
        if axisless { me.gridlines = now.gridlines }
        guard now == me else { return nil }
        // Without the parts those elements point at, PowerPoint repairs the file.
        dropUnkeptRefs(&root, c)
        var w = W.new()
        w.raw(root.toXML())
        return w.finish()
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

fileprivate extension XMLEl {
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
