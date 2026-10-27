// DCPPTX — shape trees: `p:sp`, `p:pic`, `p:grpSp`, `p:cxnSp`, `p:graphicFrame` (tables, charts, SmartArt,
// OLE and other objects) and `p:contentPart` (3-D models). Port of deckcraft crates/pptx/src/read/shapes.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

extension PPTXRead {
    /// File shape ids at or above this are reassigned.
    static let maxKeptId: UInt32 = 1 << 30
    static let maxTreeDepth = 32
    static let maxShapes = 20_000

    /// Shape id bookkeeping for one part.
    final class IdCtx {
        var used = Set<UInt32>()
        /// File id → model id.
        var map: [UInt32: ShapeId] = [:]
        /// Always allocate new ids (shapes pulled in from other parts).
        var fresh = false
        var count = 0

        init(fresh: Bool = false) {
            self.fresh = fresh
        }

        func assign(_ imp: Imp, _ fileId: UInt32?) -> ShapeId {
            if !fresh, let i = fileId, i >= 2, i < PPTXRead.maxKeptId, !used.contains(i) {
                used.insert(i)
                map[i] = ShapeId(i)
                return ShapeId(i)
            }
            let n = imp.alloc()
            used.insert(n)
            if let i = fileId, map[i] == nil { map[i] = ShapeId(n) }
            return ShapeId(n)
        }

        func lookup(_ fileId: UInt32) -> ShapeId? {
            map[fileId]
        }
    }

    /// Read the children of an `spTree` / `grpSp`.
    static func spTree(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ tree: XMLEl, _ depth: Int) -> [Shape] {
        var out: [Shape] = []
        if depth > maxTreeDepth {
            PPTXLog.warn("pptx: group nesting too deep in \(part.name)")
            return out
        }
        for e in tree.elements {
            if ctx.count >= maxShapes {
                PPTXLog.warn("pptx: too many shapes in \(part.name)")
                break
            }
            let s: Shape?
            switch e.local {
            case "sp": s = sp(imp, part, ctx, e)
            case "pic": s = pic(imp, part, ctx, e)
            case "grpSp": s = grp(imp, part, ctx, e, depth)
            case "cxnSp": s = cxn(imp, part, ctx, e)
            case "graphicFrame": s = frame(imp, part, ctx, e, depth)
            case "contentPart":
                s = contentPart(imp, part, ctx, e)
                if s == nil { PPTXLog.warn("pptx: content part in \(part.name) not imported") }
            case "AlternateContent": s = readModelAlternate(imp, part, ctx, e)
            default: s = nil
            }
            if let s {
                ctx.count += 1
                out.append(s)
            }
        }
        if depth == 0 { remapConnectors(&out, ctx, 0) }
        return out
    }

    /// ActiveX controls (`p:controls`): each control's picture (`p:pic`), the image PowerPoint shows
    /// for it, as a picture above the slide's shapes. Controls without one are left out.
    static func controls(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ controls: XMLEl) -> [Shape] {
        var out: [Shape] = []
        for c in controls.childrenNamed("control") {
            if ctx.count >= maxShapes { break }
            if let p = c.child("pic") {
                ctx.count += 1
                out.append(pic(imp, part, ctx, p))
            }
        }
        return out
    }

    static func remapConnectors(_ shapes: inout [Shape], _ ctx: IdCtx, _ depth: Int) {
        if depth > maxTreeDepth { return }
        for i in shapes.indices {
            switch shapes[i].kind {
            case .connector(let start, let end):
                func remap(_ e: Pair<ShapeId, UInt32>?) -> Pair<ShapeId, UInt32>? {
                    e.flatMap { p in ctx.lookup(p.a.rawValue).map { Pair($0, p.b) } }
                }
                shapes[i].kind = .connector(start: remap(start), end: remap(end))
            case .group:
                shapes[i].mutateChildren { remapConnectors(&$0, ctx, depth + 1) }
            default:
                break
            }
        }
    }

    /// PowerPoint's Lock (right-click > Lock, the Selection pane padlock) writes a full set of locking
    /// attributes; it reads an object as locked only when the whole set for its kind is there, so a
    /// lone `noMove` or `noResize` (other tools' partial locks) isn't Lock.
    static func isLocked(_ l: XMLEl) -> Bool {
        let set: [String]
        switch l.local {
        case "grpSpLocks": set = ["noGrp", "noUngrp", "noRot", "noMove", "noResize"]
        case "graphicFrameLocks": set = ["noGrp", "noDrilldown", "noMove", "noResize"]
        default: set = ["noGrp", "noRot", "noMove", "noResize", "noEditPoints", "noAdjustHandles", "noChangeArrowheads", "noChangeShapeType"]
        }
        return set.allSatisfy { l.bool($0) == true }
    }

    /// Common non-visual properties (`p:nvSpPr`, `p:nvPicPr`…).
    static func base(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ nv: XMLEl?) -> Shape {
        let c = nv?.child("cNvPr")
        var s = Shape.default
        s.id = ctx.assign(imp, c?.u32("id"))
        if let c {
            s.name = c.attr("name") ?? ""
            s.descr = c.attr("descr") ?? ""
            s.title = c.attr("title") ?? ""
            s.hidden = c.bool("hidden") ?? false
            s.click = c.child("hlinkClick").flatMap { hyperlink(imp, part, $0) }
            s.hover = c.child("hlinkHover").flatMap { hyperlink(imp, part, $0) }
            s.decorative = c.find("decorative").flatMap { $0.bool("val") } ?? false
        }
        if let nv {
            for e in nv.elements {
                switch e.local {
                case "cNvSpPr":
                    s.textBox = e.bool("txBox") ?? false
                    s.locked = e.child("spLocks").map(isLocked) ?? false
                case "cNvPicPr", "cNvGrpSpPr", "cNvCxnSpPr", "cNvGraphicFramePr":
                    s.locked = e.elements.first { hasByteSuffix($0.local, "Locks") }.map(isLocked) ?? false
                case "nvPr":
                    if let ph = e.child("ph") {
                        s.ph = Placeholder(
                            kind: ph.attr("type").map(PhType.fromXML) ?? .obj,
                            idx: ph.u32("idx") ?? 0,
                            vertical: attrIs(ph.attr("orient"), "vert"),
                            size: ph.attr("sz"),
                            hasCustomPrompt: ph.bool("hasCustomPrompt") ?? false
                        )
                    }
                    s.tags = tags(imp, part, e)
                default:
                    break
                }
            }
        }
        return s
    }

    static func presetGeom(_ pg: XMLEl) -> Geom {
        let name = pg.attr("prst") ?? "rect"
        var adj = Preset.info(name)?.defaults ?? []
        var any = false
        if let av = pg.child("avLst") {
            for gd in av.childrenNamed("gd").prefix(16) {
                guard let idx = adjIndex(gd.attr("name") ?? "", 16) else { continue }
                guard let v = adjValue(gd) else { continue }
                if adj.count <= idx { adj.append(contentsOf: Array(repeating: 0.0, count: idx + 1 - adj.count)) }
                if idx < adj.count {
                    adj[idx] = v
                    any = true
                }
            }
        }
        if !any { adj.removeAll() }
        return .preset(name: name, adj: adj)
    }

    /// A placeholder whose `spPr` names no geometry takes its layout's (or master's) placeholder's:
    /// marked here with an empty custom geometry, filled in once the layouts are read
    /// (`inheritPlaceholderGeometry`).
    static func markInheritedGeometry(_ s: inout Shape, _ pr: XMLEl?) {
        if s.ph != nil, pr.map({ $0.child("prstGeom") == nil && $0.child("custGeom") == nil }) ?? true {
            s.geom = .custom(paths: [])
        }
    }

    /// `spPr` → transform, geometry, fill, line, effects.
    static func spPr(_ imp: Imp, _ part: Part, _ s: inout Shape, _ pr: XMLEl) {
        if let x = pr.child("xfrm") { s.xfrm = xfrm(x).0 }
        if let pg = pr.child("prstGeom") {
            s.geom = presetGeom(pg)
        } else if let cg = pr.child("custGeom") {
            let (w, h) = s.xfrm.map { (Double(ptToEmu($0.w)), Double(ptToEmu($0.h))) } ?? (21600.0, 21600.0)
            let paths = CustGeom.readCustGeom(cg, w, h)
            if !paths.isEmpty { s.geom = .custom(paths: paths) }
        }
        s.fill = fillOf(imp, part, pr)
        if let ln = pr.child("ln") { s.line = line(imp, part, ln) }
        if let fx = pr.child("effectLst") { s.effects = effects(fx) }
        let raw = pr.elements.filter { $0.is("scene3d") || $0.is("sp3d") }.map { part.keep($0) }.joined()
        if !raw.isEmpty {
            var fx = s.effects ?? Effects()
            fx.bevel = pr.path(["sp3d", "bevelT"]).map { $0.attr("prst") ?? "circle" }
            fx.raw3d = raw
            s.effects = fx
        }
    }

    static func style(_ st: XMLEl) -> ShapeStyle {
        let accent1 = ColorRef.scheme(.accent1)
        func r(_ n: String) -> Pair<UInt32, ColorRef> {
            st.child(n).map { e in Pair(Swift.min(e.u32("idx") ?? 0, 1003), color(e) ?? accent1) } ?? Pair(0, accent1)
        }
        let font = st.child("fontRef")
        return ShapeStyle(
            lineRef: r("lnRef"), fillRef: r("fillRef"), effectRef: r("effectRef"),
            fontRef: Pair(font?.attr("idx") ?? "minor", font.flatMap(color))
        )
    }

    static func sp(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl) -> Shape {
        var s = base(imp, part, ctx, e.child("nvSpPr"))
        if let pr = e.child("spPr") { spPr(imp, part, &s, pr) }
        markInheritedGeometry(&s, e.child("spPr"))
        if e.bool("useBgFill") == true { s.fill = .background }
        s.style = e.child("style").map(style)
        s.text = e.child("txBody").map { textBody(imp, part, $0) }
        return s
    }

    static func ms(_ v: String?) -> UInt32 {
        guard let v, let f = rustParseF64(rustTrim(v)), f.isFinite else { return 0 }
        return UInt32(rustCast: f.clamped(0.0, Double(UInt32.max)))
    }

    static func findContentPart(_ el: XMLEl) -> XMLEl? {
        func rec(_ el: XMLEl, _ depth: Int) -> XMLEl? {
            if depth > 16 { return nil }
            if el.is("contentPart") { return el }
            for c in el.elements {
                if let f = rec(c, depth + 1) { return f }
            }
            return nil
        }
        return rec(el, 0)
    }

    /// `p:contentPart` whose relationship is a 3-D model. Other content parts (ink) are left out.
    static func contentPart(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl) -> Shape? {
        guard let id = e.attr("r:id"), !id.isEmpty, let rel = part.rels.get(id) else { return nil }
        if !isModel3d(rel) { return nil }
        guard let media = imp.mediaFor(rel.target) else {
            PPTXLog.warn("pptx: 3-D model part missing in \(part.name)")
            return nil
        }
        var s = base(imp, part, ctx, e.child("nvContentPartPr"))
        if let x = e.child("xfrm") { s.xfrm = xfrm(x).0 }
        s.kind = .model3d(media: media, poster: nil)
        return s
    }

    /// A 3-D model wrapped in `mc:AlternateContent`: the model choice, plus the fallback picture.
    /// If the model part is missing, the fallback picture is the shape.
    static func readModelAlternate(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl) -> Shape? {
        if let content = e.childrenNamed("Choice").lazy.compactMap(findContentPart).first,
           var s = contentPart(imp, part, ctx, content)
        {
            let poster = e.child("Fallback").flatMap { fb -> MediaId? in
                for b in fb.findAll("blip") {
                    if let m = mediaRef(imp, part, b) { return m }
                }
                return nil
            }
            if case .model3d(let media, _) = s.kind { s.kind = .model3d(media: media, poster: poster) }
            return s
        }
        return e.child("Fallback").flatMap { fb in fb.elements.first { $0.is("pic") }.map { pic(imp, part, ctx, $0) } }
    }

    static func pic(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl) -> Shape {
        var s = base(imp, part, ctx, e.child("nvPicPr"))
        if let pr = e.child("spPr") { spPr(imp, part, &s, pr) }
        s.style = e.child("style").map(style)
        let pf = e.child("blipFill").flatMap { blipFill(imp, part, $0) }
        let nvpr = e.path(["nvPicPr", "nvPr"])
        let vf = nvpr?.child("videoFile")
        let af = nvpr?.child("audioFile")
        let p14 = nvpr?.child("extLst")?.find("media")
        if vf != nil || af != nil || p14 != nil {
            let media = p14.flatMap { mediaRef(imp, part, $0) } ?? (vf ?? af).flatMap { mediaRef(imp, part, $0) }
            if let media {
                var clip = MediaClip(
                    media: media, video: vf != nil || af == nil, poster: pf?.media, crop: pf?.crop ?? [0, 0, 0, 0], volume: 1.0
                )
                if let m = p14 {
                    if let t = m.child("trim") {
                        clip.trimStartMs = ms(t.attr("st"))
                        clip.trimEndMs = ms(t.attr("end"))
                    }
                    if let f = m.child("fade") {
                        clip.fadeInMs = ms(f.attr("in"))
                        clip.fadeOutMs = ms(f.attr("out"))
                    }
                    if let l = m.child("bmkLst") {
                        clip.bookmarks = l.childrenNamed("bmk").prefix(1000).map { b in Pair(b.attr("name") ?? "", ms(b.attr("time"))) }
                    }
                }
                s.kind = .media(clip)
                return s
            }
        }
        if let fill = pf {
            s.kind = .picture(fill: fill)
        } else {
            PPTXLog.warn("pptx: picture \(s.name) in \(part.name) has no readable image")
        }
        return s
    }

    static func grp(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl, _ depth: Int) -> Shape {
        var s = base(imp, part, ctx, e.child("nvGrpSpPr"))
        var child: Xfrm?
        if let pr = e.child("grpSpPr") {
            if let x = pr.child("xfrm") {
                let (xf, ch) = xfrm(x)
                s.xfrm = xf
                child = ch
            }
            s.fill = fillOf(imp, part, pr)
            if let fx = pr.child("effectLst") { s.effects = effects(fx) }
        }
        let children = spTree(imp, part, ctx, e, depth + 1)
        let ch = child ?? s.xfrm.map { Xfrm($0.x, $0.y, $0.w, $0.h) } ?? Xfrm()
        s.kind = .group(children: children, child: ch)
        return s
    }

    static func cxn(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl) -> Shape {
        let nv = e.child("nvCxnSpPr")
        var s = base(imp, part, ctx, nv)
        if let pr = e.child("spPr") { spPr(imp, part, &s, pr) }
        s.style = e.child("style").map(style)
        let c = nv?.child("cNvCxnSpPr")
        func end(_ n: String) -> Pair<ShapeId, UInt32>? {
            guard let x = c?.child(n), let id = x.u32("id") else { return nil }
            return Pair(ShapeId(id), x.u32("idx") ?? 0)
        }
        s.kind = .connector(start: end("stCxn"), end: end("endCxn"))
        return s
    }

    static func frame(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ e: XMLEl, _ depth: Int) -> Shape {
        var s = base(imp, part, ctx, e.child("nvGraphicFramePr"))
        if let x = e.child("xfrm") { s.xfrm = xfrm(x).0 }
        let gd = e.path(["graphic", "graphicData"])
        let uri = gd?.attr("uri") ?? ""
        if let gd {
            if let tbl = gd.child("tbl") {
                s.kind = .table(table(imp, part, tbl))
                return s
            }
            if let c = gd.child("chart"), let rel = part.rels.get(c.attr("r:id") ?? ""),
               let bytes = imp.pkg.xmlBytes(rel.target),
               var chart = hasByteSuffix(uri, "/chartex") ? readChartexXML(bytes) : readChartXML(bytes)
            {
                chart.kept = captureKept(imp, rel.target)
                s.kind = .chart(chart)
                return s
            }
            if hasByteSuffix(uri, "/diagram"), let g = smartart(imp, part, gd, s, depth) {
                return g
            }
        }
        // Something we don't model: keep its XML and show a preview picture when it has one.
        var preview: MediaId?
        for b in e.findAll("blip") {
            if let m = mediaRef(imp, part, b) {
                preview = m
                break
            }
        }
        let ole = gd?.find("oleObj")
        if preview == nil, let spid = ole?.attr("spid") {
            preview = vmlPreview(imp, part, spid)
        }
        // An embedded object's fallback picture (`p:oleObj/p:pic`) can carry a fill and an outline,
        // which PowerPoint draws behind and around the preview (old equation objects on coloured
        // boxes). The frame's own position stays.
        if let pr = ole?.find("pic")?.child("spPr") {
            if s.fill == nil { s.fill = fillOf(imp, part, pr) }
            if s.line == nil { s.line = pr.child("ln").map { line(imp, part, $0) } }
        }
        let label: String
        if let o = ole {
            label = o.attr("progId") ?? o.attr("name") ?? "Object"
        } else if hasByteSuffix(uri, "/diagram") {
            label = "SmartArt"
        } else if bytesContains(uri, "chart") {
            label = "Chart"
        } else if let slash = uri.utf8.lastIndex(of: UInt8(ascii: "/")) {
            label = String(uri[uri.utf8.index(after: slash)...])
        } else {
            label = uri
        }
        // Keep the parts it points to so a save writes it back whole (#203). A part with relationships
        // of its own, or an external link, can't be carried: the save then falls back to the preview.
        var parts: [Triple<String, String, MediaId>] = []
        for id in relRefs(e) {
            guard let rel = part.rels.get(id), !rel.external, imp.pkg.rels(rel.target).items.isEmpty else {
                parts = []
                break
            }
            let media = bytesEqual(rel.kind, "diagramData") ? diagramData(imp, rel.target) : imp.mediaFor(rel.target)
            guard let media else {
                parts = []
                break
            }
            parts.append(Triple(id, rel.ty, media))
        }
        s.kind = .opaque(xml: part.keep(e), preview: preview, label: label, parts: parts)
        return s
    }

    /// The preview picture of an old-style embedded object (`p:oleObj spid` with no `p:pic`): the
    /// `v:imagedata` of the legacy VML drawing shape with that id, as PowerPoint 2007 wrote them.
    static func vmlPreview(_ imp: Imp, _ part: Part, _ spid: String) -> MediaId? {
        for rel in part.rels.items where bytesEqual(rel.kind, "vmlDrawing") && !rel.external {
            let key = ByteKey(OPC.norm(rel.target))
            if imp.vmlPreviews[key] == nil {
                imp.vmlPreviews[key] = vmlIndex(imp.pkg, rel.target)
            }
            guard let target = imp.vmlPreviews[key]?[ByteKey(spid)] else { continue }
            return imp.mediaFor(target)
        }
        return nil
    }

    /// Every shape id in a VML drawing with a picture, mapped to that picture's part: parsed once per
    /// drawing however many objects look it up.
    static func vmlIndex(_ pkg: Package, _ vml: String) -> [ByteKey: String] {
        var out: [ByteKey: String] = [:]
        guard let doc = pkg.xml(vml) else { return out }
        let rels = pkg.rels(vml)
        for s in doc.root.findAll("shape") {
            guard let id = s.attr("id") else { continue }
            if out[ByteKey(id)] != nil { continue } // the first shape with an id wins, as the old lookup did
            guard let img = s.find("imagedata") else { continue }
            guard let rid = img.attr("o:relid") ?? img.attr("r:id") else { continue }
            if let r = rels.get(rid), !r.external { out[ByteKey(id)] = r.target }
        }
        return out
    }

    /// A diagram's data part, without the link to its cached drawing: that link is a slide
    /// relationship id, which a save renumbers. Only diagrams whose drawing is missing or empty get
    /// here, and those are drawn from their data.
    static func diagramData(_ imp: Imp, _ target: String) -> MediaId? {
        let normTarget = ByteKey(OPC.norm(target))
        if let id = imp.mediaByPart[normTarget] { return id }
        func strip(_ e: inout XMLEl, _ depth: Int) {
            if depth > XML.maxDepth { return }
            e.children.removeAll { n in
                if case .el(let c) = n { return c.is("ext") && c.find("dataModelExt") != nil }
                return false
            }
            e.elementsMut { strip(&$0, depth + 1) }
        }
        guard var doc = imp.pkg.xml(target) else { return nil }
        strip(&doc.root, 0)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + doc.root.toXML()
        let id = MediaId(imp.alloc())
        guard let contentType = imp.pkg.contentType(target) else { return nil }
        imp.media.append(MediaItem(id: id, name: OPC.fileOf(target), contentType: contentType, data: Array(xml.utf8), link: nil))
        imp.mediaByPart[normTarget] = id
        return id
    }

    /// SmartArt: read the pre-drawn shapes of its drawing part as a group.
    static func smartart(_ imp: Imp, _ part: Part, _ gd: XMLEl, _ frame: Shape, _ depth: Int) -> Shape? {
        if depth > 8 { return nil }
        guard let relIds = gd.child("relIds"),
              let dm = part.rels.get(relIds.attr("r:dm") ?? ""),
              let data = imp.pkg.xml(dm.target),
              let drawingRel = data.root.find("dataModelExt")?.attr("relId").flatMap({ part.rels.get($0) })?.target,
              var d = imp.pkg.xml(drawingRel)
        else { return nil }
        resolveMC(&d.root, 0)
        let dpart = Part(imp.pkg, drawingRel, d)
        guard let tree = d.root.child("spTree") else { return nil }
        let sub = IdCtx(fresh: true)
        var children = spTree(imp, dpart, sub, tree, depth + 1)
        if children.isEmpty { return nil }
        children = smartartTextRects(imp, sub, tree, children, depth + 1)
        var g = frame
        let x = frame.xfrm ?? Xfrm()
        g.kind = .group(children: children, child: Xfrm(0.0, 0.0, x.w, x.h))
        g.diagram = diagramOutline(imp, part, relIds, data.root)
        // Node pictures, from the blips of the data model's presentation points.
        if var dg = g.diagram {
            let rels = imp.pkg.rels(dm.target)
            for (k, rid) in Dgm.nodePictures(data.root) {
                guard let r = rels.get(rid), !r.external else { continue }
                let media = imp.mediaFor(r.target)
                if k >= 0, k < dg.nodes.count { dg.nodes[k].picture = media }
            }
            g.diagram = dg
        }
        return g
    }

    /// A SmartArt drawing shape (`dsp:sp`) keeps its text rectangle in `dsp:txXfrm`, apart from the
    /// shape's own box: the text of a narrow shape turned by 90° is often laid out across it. Put each
    /// shape's text on that rectangle. `shapes` are what `spTree` read from `tree`, in order.
    static func smartartTextRects(_ imp: Imp, _ ctx: IdCtx, _ tree: XMLEl, _ shapes: [Shape], _ depth: Int) -> [Shape] {
        if depth > maxTreeDepth { return shapes }
        var out: [Shape] = []
        out.reserveCapacity(shapes.count)
        var it = shapes.makeIterator()
        // The same elements `spTree` turns into shapes.
        let kinds = ["sp", "pic", "grpSp", "cxnSp", "graphicFrame"]
        for e in tree.elements where kinds.contains(where: { bytesEqual($0, e.local) }) {
            guard var s = it.next() else { break }
            var textBox: Shape?
            switch (e.local, s.kind) {
            case ("grpSp", .group):
                s.mutateChildren { kids in kids = smartartTextRects(imp, ctx, e, kids, depth + 1) }
            case ("sp", .shape):
                if let t = e.child("txXfrm") {
                    textBox = textOnRect(imp, ctx, &s, xfrm(t).0)
                }
            default:
                break
            }
            out.append(s)
            if let textBox { out.append(textBox) }
        }
        while let s = it.next() { out.append(s) }
        return out
    }

    /// Lay out the text of `s` on `t`, a text rectangle in the same space as the shape's box, turned by
    /// the shape's rotation plus its own. When that is the shape's text area shrunk by some margin, the
    /// shape keeps its text with wider insets. Otherwise (a rectangle reaching outside the shape, or
    /// turned against it) the text moves to a new frameless text shape over `s`, which is returned:
    /// both export as plain DrawingML that any reader lays out the same way.
    static func textOnRect(_ imp: Imp, _ ctx: IdCtx, _ s: inout Shape, _ t: Xfrm) -> Shape? {
        let eps = 0.01
        guard let x = s.xfrm else { return nil }
        if !x.isFinite || !t.isFinite || t.w <= eps || t.h <= eps { return nil }
        guard var body = s.text, !body.isEmpty else { return nil }
        func turn(_ a: Double) -> Double { remEuclid(a, 360.0) }
        func upright(_ a: Double) -> Bool { turn(a + eps) < 2.0 * eps }
        let bp = body.body
        if !x.flipH, !x.flipV, upright(t.rot), bp.rot.map(upright) ?? true, bp.vert.map({ $0 == .horizontal }) ?? true, bp.upright != true {
            // Same orientation as the shape: express the rectangle as insets from the shape's text area.
            let c = x.affine.inverse * t.center
            let l = c.x - t.w / 2.0, top = c.y - t.h / 2.0
            let r = l + t.w, b = top + t.h
            let area = textArea(s.geom, x.w, x.h)
            let extra = [l - area.x0, top - area.y0, area.x1 - r, area.y1 - b]
            if extra.allSatisfy({ $0.isFinite && $0 >= -eps }) {
                let ex = extra.map { $0.rustMax(0.0) }
                body.body.insetL = (bp.insetL ?? 7.2) + ex[0]
                body.body.insetT = (bp.insetT ?? 3.6) + ex[1]
                body.body.insetR = (bp.insetR ?? 7.2) + ex[2]
                body.body.insetB = (bp.insetB ?? 3.6) + ex[3]
                s.text = body
                return nil
            }
        }
        if ctx.count >= maxShapes { return nil }
        ctx.count += 1
        let text = s.text
        s.text = nil
        // No fill, outline or effects; the style keeps only the text colour and font.
        let st = s.style.map { st -> ShapeStyle in
            var st = st
            st.fillRef.a = 0
            st.lineRef.a = 0
            st.effectRef.a = 0
            return st
        }
        var out = Shape.default
        out.id = ctx.assign(imp, nil)
        out.name = s.name
        out.xfrm = Xfrm(x: t.x, y: t.y, w: t.w, h: t.h, rot: turn(x.rot + t.rot), flipH: false, flipV: false)
        out.fill = Fill.none_
        out.line = Line(fill: Fill.none_)
        out.style = st
        out.text = text
        out.click = s.click
        out.hover = s.hover
        return out
    }

    /// Where a shape's geometry puts its text, in shape-local points (as the renderer computes it).
    static func textArea(_ geom: Geom, _ w: Double, _ h: Double) -> Rect {
        let full = Rect(0.0, 0.0, w, h)
        switch geom {
        case .preset(let name, let adj):
            return (Preset.build(name, w, h, adj) ?? Preset.build("rect", w, h, [])).map(\.textRect) ?? full
        case .custom:
            return full
        }
    }

    /// The outline of a SmartArt graphic (for the Text Pane), with its layout, quick style and colour
    /// parts kept to be written back.
    static func diagramOutline(_ imp: Imp, _ part: Part, _ relIds: XMLEl, _ data: XMLEl) -> Diagram? {
        let nodes = Dgm.outline(data)
        if nodes.isEmpty { return nil }
        func raw(_ attr: String) -> String? {
            guard let a = relIds.attr(attr), let rel = part.rels.get(a), let bytes = imp.pkg.get(rel.target) else { return nil }
            guard bytes.count <= 4 << 20 else { return nil }
            return String(validating: bytes, as: UTF8.self)
        }
        let layoutXML = raw("r:lo")
        var layoutId = "", cat = ""
        if let x = layoutXML, let d = try? XML.parse(Array(x.utf8)) {
            cat = d.root.child("catLst")?.child("cat")?.attr("type") ?? ""
            layoutId = d.root.attr("uniqueId") ?? ""
        }
        let docPt = data.path(["ptLst"])?.childrenNamed("pt").first { attrIs($0.attr("type"), "doc") }
        let pr = docPt?.child("prSet")
        let loType = pr?.attr("loTypeId") ?? ""
        let id = layoutId.isEmpty ? loType : layoutId
        let style = Dgm.styleFor(pr?.attr("qsTypeId") ?? "")
        let colors = Dgm.colorsFor(pr?.attr("csTypeId") ?? "")
        return Diagram(
            kind: Dgm.kindFor(id, cat), nodes: nodes, style: style, colors: colors, imported: true, layoutId: id,
            layoutXml: layoutXML, styleXml: raw("r:qs"), colorsXml: raw("r:cs")
        )
    }

    static func table(_ imp: Imp, _ part: Part, _ tbl: XMLEl) -> Table {
        // A table naming no style is drawn by PowerPoint with thin dark grid lines ("No Style, Table
        // Grid"), not without lines.
        var t = Table.default
        t.style = "grid"
        t.firstRow = false
        t.bandRow = false
        if let pr = tbl.child("tblPr") {
            t.background = pr.elements.first { hasByteSuffix($0.local, "Fill") && !bytesEqual($0.local, "noFill") }
                .flatMap { fillEl(imp, part, $0) }
            t.firstRow = pr.bool("firstRow") ?? false
            t.firstCol = pr.bool("firstCol") ?? false
            t.lastRow = pr.bool("lastRow") ?? false
            t.lastCol = pr.bool("lastCol") ?? false
            t.bandRow = pr.bool("bandRow") ?? false
            t.bandCol = pr.bool("bandCol") ?? false
            if let id = pr.child("tableStyleId")?.text {
                // A style the file defines is drawn from its definition (by its GUID).
                // DeckCraft's own styles (written with GUIDs derived from their ids) map back to them.
                let trimmed = String(rustTrim(id))
                let up = asciiUppercase(trimmed)
                t.style = imp.tableStyleIds.contains(where: { bytesEqual($0, up) }) && !Tables.isOwnGUID(up)
                    ? up : Tables.styleFromGUID(trimmed)
            }
        }
        t.cols = tbl.child("tblGrid").map { g in
            g.childrenNamed("gridCol").prefix(1000).map { (pt($0, "w") ?? 72.0).clamped(0.0, 20_000.0) }
        } ?? []
        for tr in tbl.childrenNamed("tr").prefix(1000) {
            var row = Row(height: (pt(tr, "h") ?? 0.0).clamped(0.0, 20_000.0), cells: [])
            for tc in tr.childrenNamed("tc").prefix(1000) {
                row.cells.append(cell(imp, part, tc))
            }
            t.rows.append(row)
        }
        if t.cols.isEmpty {
            let n = t.rows.map(\.cells.count).max() ?? 0
            t.cols = Array(repeating: 72.0, count: n)
        }
        t.normalize()
        return t
    }

    static func cell(_ imp: Imp, _ part: Part, _ tc: XMLEl) -> Cell {
        var c = Cell(
            gridSpan: Swift.min(Swift.max(tc.u32("gridSpan") ?? 1, 1), 1000),
            rowSpan: Swift.min(Swift.max(tc.u32("rowSpan") ?? 1, 1), 1000),
            hMerge: tc.bool("hMerge") ?? false,
            vMerge: tc.bool("vMerge") ?? false
        )
        if let tx = tc.child("txBody") { c.text = textBody(imp, part, tx) }
        if let pr = tc.child("tcPr") {
            if ["marL", "marR", "marT", "marB"].contains(where: { pr.hasAttr($0) }) {
                c.margins = [pt(pr, "marL") ?? 7.2, pt(pr, "marR") ?? 7.2, pt(pr, "marT") ?? 3.6, pt(pr, "marB") ?? 3.6]
            }
            c.anchor = pr.attr("anchor").flatMap(Anchor.fromXML)
            c.vertical = pr.attr("vert").flatMap(TextDir.fromXML)
            for (i, n) in ["lnL", "lnR", "lnT", "lnB"].enumerated() {
                if let ln = pr.child(n), i < c.borders.count { c.borders[i] = line(imp, part, ln) }
            }
            c.diagDown = pr.child("lnTlToBr").map { line(imp, part, $0) }
            c.diagUp = pr.child("lnBlToTr").map { line(imp, part, $0) }
            c.fill = fillOf(imp, part, pr)
        }
        return c
    }
}
