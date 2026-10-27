// DCPPTX — shape trees: autoshapes, pictures, groups, connectors, tables, charts, media, ink, 3-D
// models and kept objects. Port of deckcraft crates/pptx/src/write/shapes.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

extension PPTXWrite {
    /// The `write::shapes` module.
    enum Shapes {
        /// cNvPr ids for one part.
        struct IdMap {
            var map: [ShapeId: UInt32]
            var next: UInt32

            static func build(_ shapes: [Shape]) -> IdMap {
                var map: [ShapeId: UInt32] = [:]
                var used = Set<UInt32>()
                var max: UInt32 = 1
                walk(shapes) { s, _ in
                    if s.id.rawValue >= 2 && s.id.rawValue < UInt32(Int32.max) {
                        max = Swift.max(max, s.id.rawValue)
                    }
                }
                var next = max
                walk(shapes) { s, _ in
                    let id: UInt32
                    if s.id.rawValue >= 2 && s.id.rawValue < UInt32(Int32.max) && !used.contains(s.id.rawValue) {
                        id = s.id.rawValue
                    } else {
                        next = satAdd(next, 1)
                        id = next
                    }
                    used.insert(id)
                    if map[s.id] == nil {
                        map[s.id] = id
                    }
                }
                return IdMap(map: map, next: next)
            }

            func get(_ id: ShapeId) -> UInt32? {
                map[id]
            }

            mutating func fresh() -> UInt32 {
                next = satAdd(next, 1)
                return next
            }
        }

        final class Ctx {
            var ids: IdMap
            /// The shape id written for the shape currently being written (duplicate model ids get fresh ones).
            var written: Set<UInt32> = []

            init(ids: IdMap) {
                self.ids = ids
            }

            func idFor(_ s: Shape) -> UInt32 {
                let id = ids.get(s.id) ?? 0
                if id >= 2 && written.insert(id).inserted {
                    return id
                }
                let f = ids.fresh()
                written.insert(f)
                return f
            }
        }

        static func presetName(_ name: String) -> String {
            bytesEqual(name, "textBox") || name.isEmpty || !isASCIIAlnum(name) ? "rect" : name
        }

        /// Non-adjust shape guides some presets carry in their `avLst` (ECMA-376 default values).
        static func extraGuides(_ name: String) -> [(String, Int64)] {
            switch name {
            case "star5", "pentagon": [("hf", 105_146), ("vf", 110_557)]
            case "star7", "heptagon": [("hf", 102_572), ("vf", 105_210)]
            case "star6": [("hf", 115_470)]
            case "star10": [("hf", 105_146)]
            case "hexagon": [("vf", 115_470)]
            case "decagon": [("vf", 105_146)]
            default: []
            }
        }

        static func geometry(_ w: inout W, _ g: Geom) {
            switch g {
            case .preset(let name0, let adj):
                let name = presetName(name0)
                w.open("a:prstGeom", A.new().a("prst", name))
                if adj.isEmpty {
                    w.empty0("a:avLst")
                } else {
                    // PowerPoint wants the complete guide list once any is given.
                    let defaults = Preset.info(name)?.defaults ?? []
                    var vals = Array(adj.prefix(16))
                    while vals.count < defaults.count {
                        vals.append(defaults.at(vals.count) ?? 0.0)
                    }
                    w.open0("a:avLst")
                    // A lone guide is `adj`, except in these presets, which name it `adj1` (as PowerPoint
                    // writes them); PowerPoint won't open a file that renames it (#214).
                    let adj1 = ["bentConnector3", "curvedConnector3", "frame", "mathPlus", "mathMinus", "mathMultiply"].contains { bytesEqual($0, name) }
                    let single = !adj1 && (defaults.isEmpty ? vals.count == 1 : defaults.count == 1)
                    for (i, v) in vals.enumerated() {
                        let n = single && i == 0 ? "adj" : "adj\(i + 1)"
                        let v = v.isFinite ? Int64(rustCast: v.rounded().clamped(-2.0e9, 2.0e9)) : 0
                        w.empty("a:gd", A.new().a("name", n).a("fmla", "val \(v)"))
                    }
                    for (n, v) in extraGuides(name) {
                        w.empty("a:gd", A.new().a("name", n).a("fmla", "val \(v)"))
                    }
                    w.close("a:avLst")
                }
                w.close("a:prstGeom")
            case .custom(let paths):
                if paths.isEmpty {
                    w.open("a:prstGeom", A.new().a("prst", "rect"))
                    w.empty0("a:avLst")
                    w.close("a:prstGeom")
                } else {
                    CustGeom.writeCustGeom(&w, paths)
                }
            }
        }

        static func cNvPr(_ w: inout W, _ x: Exp, _ o: Out, _ id: UInt32, _ s: Shape) {
            let a = A.new()
                .a("id", id)
                .a("name", s.name.isEmpty ? "Shape \(id)" : s.name)
                .o("descr", s.descr.isEmpty ? nil : s.descr)
                .t("hidden", s.hidden)
                .o("title", s.title.isEmpty ? nil : s.title)
            if s.click == nil && s.hover == nil && !s.decorative {
                w.empty("p:cNvPr", a)
                return
            }
            w.open("p:cNvPr", a)
            if let h = s.click {
                DML.hyperlink(&w, x, o, "a:hlinkClick", h)
            }
            if let h = s.hover {
                DML.hyperlink(&w, x, o, "a:hlinkHover", h)
            }
            if s.decorative {
                w.open0("a:extLst")
                w.open("a:ext", A.new().a("uri", "{C183D7F6-B498-43B3-948B-1728B52AA6E4}"))
                w.empty("adec:decorative", A.new().a("xmlns:adec", "http://schemas.microsoft.com/office/drawing/2017/decorative").a("val", "1"))
                w.close("a:ext")
                w.close("a:extLst")
            }
            w.close("p:cNvPr")
        }

        static func nvPr(_ w: inout W, _ x: Exp, _ o: Out, _ s: Shape) {
            if s.ph == nil && s.tags.isEmpty {
                w.empty0("p:nvPr")
                return
            }
            w.open0("p:nvPr")
            if let ph = s.ph {
                let ty: String? = ph.kind == .obj ? nil : ph.kind.xml
                let sz = ph.size.flatMap { z in ["full", "half", "quarter"].contains { bytesEqual($0, z) } ? z : nil }
                w.empty(
                    "p:ph",
                    A.new()
                        .o("type", ty)
                        .o("orient", ph.vertical ? "vert" : nil)
                        .o("sz", sz)
                        .o("idx", ph.idx != 0 ? ph.idx : nil)
                        .t("hasCustomPrompt", ph.hasCustomPrompt)
                )
            }
            PPTXWrite.custData(&w, x, o, s.tags)
            w.close("p:nvPr")
        }

        /// Locking attributes. Lock writes the full set PowerPoint writes for the element's kind (and
        /// reads back as locked): see `read::shapes::is_locked`.
        static func locks(_ w: inout W, _ tag: String, _ s: Shape, _ extra: A) {
            var a = extra.t("noGrp", s.ph != nil || s.locked)
            if tag == "a:grpSpLocks" {
                a = a.t("noUngrp", s.locked).t("noRot", s.locked).t("noMove", s.locked).t("noResize", s.locked)
            } else {
                a = a
                    .t("noRot", s.locked)
                    .t("noMove", s.locked)
                    .t("noResize", s.locked)
                    .t("noEditPoints", s.locked)
                    .t("noAdjustHandles", s.locked)
                    .t("noChangeArrowheads", s.locked)
                    .t("noChangeShapeType", s.locked)
                if tag == "a:picLocks" {
                    a = a.t("noCrop", s.locked)
                }
            }
            if a.v.isEmpty {
                return
            }
            w.empty(tag, a)
        }

        static func style(_ w: inout W, _ st: ShapeStyle) {
            styleTag(&w, st, "p:style")
        }

        static func styleTag(_ w: inout W, _ st: ShapeStyle, _ tag: String) {
            w.open0(tag)
            for (t, r) in [("a:lnRef", st.lineRef), ("a:fillRef", st.fillRef), ("a:effectRef", st.effectRef)] {
                w.open(t, A.new().a("idx", r.a))
                DML.color(&w, r.b)
                w.close(t)
            }
            let idx = ["major", "minor", "none"].contains { bytesEqual($0, st.fontRef.a) } ? st.fontRef.a : "minor"
            if let c = st.fontRef.b {
                w.open("a:fontRef", A.new().a("idx", idx))
                DML.color(&w, c)
                w.close("a:fontRef")
            } else {
                w.empty("a:fontRef", A.new().a("idx", idx))
            }
            w.close(tag)
        }

        /// `p:spPr` contents (also used for pictures and connectors).
        static func spPr(_ w: inout W, _ x: Exp, _ o: Out, _ s: Shape, _ geom: Bool) {
            spPrTag(&w, x, o, s, geom, "p:spPr")
        }

        static func spPrTag(_ w: inout W, _ x: Exp, _ o: Out, _ s: Shape, _ geom: Bool, _ tag: String) {
            w.open0(tag)
            if let xf = s.xfrm {
                DML.xfrm(&w, "a:xfrm", xf, nil)
            }
            var plainRect = false
            if case .preset(let name, let adj) = s.geom, bytesEqual(name, "rect"), adj.isEmpty {
                plainRect = true
            }
            if geom && (s.xfrm != nil || s.ph == nil || !plainRect) {
                geometry(&w, s.geom)
            }
            if let f = s.fill {
                DML.fill(&w, x, o, f)
            }
            if let l = s.line {
                DML.line(&w, x, o, "a:ln", l)
            }
            if let fx = s.effects {
                DML.effects(&w, fx)
                if let raw = fx.raw3d {
                    w.raw(raw)
                } else if let xml = fx.bevel.flatMap(DML.bevelSp3d) {
                    w.raw(xml)
                }
            }
            w.close(tag)
        }

        /// Write the children of a shape tree.
        static func shapes(_ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ list: [Shape], _ depth: Int) {
            if depth > 32 {
                return
            }
            for s in list {
                shape(&w, x, o, cx, s, depth)
            }
        }

        static func shape(_ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ s: Shape, _ depth: Int) {
            switch s.kind {
            case .shape:
                if let t = s.text, DML.hasMath(t) {
                    // Equations: OMML for readers that know it, plain text otherwise.
                    w.open("mc:AlternateContent", A.new().a("xmlns:mc", OPC.nsMC))
                    w.open("mc:Choice", A.new().a("xmlns:a14", OPC.nsA14).a("Requires", "a14"))
                    let id = cx.idFor(s)
                    sp(&w, x, o, id, s, true)
                    w.close("mc:Choice")
                    w.open0("mc:Fallback")
                    sp(&w, x, o, id, s, false)
                    w.close("mc:Fallback")
                    w.close("mc:AlternateContent")
                } else {
                    let id = cx.idFor(s)
                    sp(&w, x, o, id, s, false)
                }
            case .picture(let fill):
                let id = cx.idFor(s)
                w.open0("p:pic")
                w.open0("p:nvPicPr")
                cNvPr(&w, x, o, id, s)
                w.open0("p:cNvPicPr")
                locks(&w, "a:picLocks", s, A.new().a("noChangeAspect", "1"))
                w.close("p:cNvPicPr")
                nvPr(&w, x, o, s)
                w.close("p:nvPicPr")
                DML.blipFill(&w, x, o, "p:blipFill", fill)
                var s2 = s
                switch s2.fill {
                case .picture?, .background?, .group?: s2.fill = nil
                default: break
                }
                spPr(&w, x, o, s2, true)
                if let st = s.style {
                    style(&w, st)
                }
                w.close("p:pic")
            case .group(let children, let child) where s.diagram != nil && depth < 32:
                if let d = s.diagram {
                    diagram(&w, x, o, cx, s, d, children, child)
                }
            case .group(let children, let child):
                let id = cx.idFor(s)
                w.open0("p:grpSp")
                w.open0("p:nvGrpSpPr")
                cNvPr(&w, x, o, id, s)
                w.open0("p:cNvGrpSpPr")
                locks(&w, "a:grpSpLocks", s, A.new())
                w.close("p:cNvGrpSpPr")
                nvPr(&w, x, o, s)
                w.close("p:nvGrpSpPr")
                w.open0("p:grpSpPr")
                let xf = s.xfrm ?? child
                DML.xfrm(&w, "a:xfrm", xf, child)
                if let f = s.fill {
                    DML.fill(&w, x, o, f)
                }
                if let fx = s.effects {
                    DML.effects(&w, fx)
                }
                w.close("p:grpSpPr")
                shapes(&w, x, o, cx, children, depth + 1)
                w.close("p:grpSp")
            case .connector(let start, let end):
                let id = cx.idFor(s)
                w.open0("p:cxnSp")
                w.open0("p:nvCxnSpPr")
                cNvPr(&w, x, o, id, s)
                let st = start.flatMap { p in cx.ids.get(p.a).map { ($0, p.b) } }
                let en = end.flatMap { p in cx.ids.get(p.a).map { ($0, p.b) } }
                if st == nil && en == nil && !s.locked {
                    w.empty0("p:cNvCxnSpPr")
                } else {
                    w.open0("p:cNvCxnSpPr")
                    locks(&w, "a:cxnSpLocks", s, A.new())
                    if let (i, site) = st {
                        w.empty("a:stCxn", A.new().a("id", i).a("idx", site))
                    }
                    if let (i, site) = en {
                        w.empty("a:endCxn", A.new().a("id", i).a("idx", site))
                    }
                    w.close("p:cNvCxnSpPr")
                }
                nvPr(&w, x, o, s)
                w.close("p:nvCxnSpPr")
                var s2 = s
                if case .background? = s2.fill {
                    s2.fill = nil
                }
                if let n = s2.geom.presetName, bytesEqual(n, "rect") {
                    s2.geom = .preset("line")
                }
                spPr(&w, x, o, s2, true)
                if let st = s.style {
                    style(&w, st)
                }
                w.close("p:cxnSp")
            case .table(let t):
                let id = cx.idFor(s)
                frameOpen(&w, x, o, id, s)
                w.open("a:graphicData", A.new().a("uri", "http://schemas.openxmlformats.org/drawingml/2006/table"))
                table(&w, x, o, t)
                w.close("a:graphicData")
                frameClose(&w)
            case .chart(let c):
                let id = cx.idFor(s)
                // An unchanged Office 2016 chart goes back as itself, with a plain chart of the same
                // data for readers without `cx1`, as PowerPoint writes it.
                let ex = x.chartexRel(o, c)
                if let exid = ex {
                    w.open("mc:AlternateContent", A.new().a("xmlns:mc", "http://schemas.openxmlformats.org/markup-compatibility/2006"))
                    w.open("mc:Choice", A.new().a("xmlns:cx1", "http://schemas.microsoft.com/office/drawing/2015/9/8/chartex").a("Requires", "cx1"))
                    frameOpen(&w, x, o, id, s)
                    w.open("a:graphicData", A.new().a("uri", PPTXWrite.nsCX))
                    w.empty("cx:chart", A.new().a("xmlns:cx", PPTXWrite.nsCX).a("r:id", exid))
                    w.close("a:graphicData")
                    frameClose(&w)
                    w.close("mc:Choice")
                    w.open0("mc:Fallback")
                }
                var plain = c
                plain.raw = plain.raw.flatMap { utf8Contains($0, PPTXWrite.nsCX) ? nil : $0 }
                if ex != nil {
                    // The kept workbook belongs to the `chartEx` part; the fallback has none.
                    plain.kept = ChartKept()
                }
                let rid = x.chartRel(o, plain)
                frameOpen(&w, x, o, id, s)
                w.open("a:graphicData", A.new().a("uri", "http://schemas.openxmlformats.org/drawingml/2006/chart"))
                w.empty("c:chart", A.new().a("xmlns:c", OPC.nsC).a("r:id", rid))
                w.close("a:graphicData")
                frameClose(&w)
                if ex != nil {
                    w.close("mc:Fallback")
                    w.close("mc:AlternateContent")
                }
            case .media(let m):
                let id = cx.idFor(s)
                media(&w, x, o, id, s, m)
            case .model3d(let media, let poster):
                writeModel(&w, x, o, cx, s, media, poster)
            case .ink(let strokes):
                // Ink becomes a group of freeform lines.
                let id = cx.idFor(s)
                let xf = s.xfrm ?? Xfrm()
                w.open0("p:grpSp")
                w.open0("p:nvGrpSpPr")
                cNvPr(&w, x, o, id, s)
                w.empty0("p:cNvGrpSpPr")
                w.empty0("p:nvPr")
                w.close("p:nvGrpSpPr")
                w.open0("p:grpSpPr")
                DML.xfrm(&w, "a:xfrm", xf, xf)
                w.close("p:grpSpPr")
                for (i, st) in strokes.prefix(10_000).enumerated() {
                    guard let stroke = inkShape(st, i) else { continue }
                    let sid = cx.ids.fresh()
                    sp(&w, x, o, sid, stroke, false)
                }
                w.close("p:grpSp")
            case .opaque(let xml, let preview, let label, let parts):
                opaque(&w, x, o, cx, s, xml, preview, label, parts)
            }
        }

        static func modelRel(_ x: Exp, _ o: Out, _ media: MediaId) -> String? {
            guard let m = x.p.media(media), !m.data.isEmpty else { return nil }
            return x.mediaRel(o, media, OPC.rtModel3D)
        }

        static func writeModelPart(_ w: inout W, _ x: Exp, _ o: Out, _ id: UInt32, _ s: Shape, _ rid: String) {
            w.open("p:contentPart", A.new().a("r:id", rid))
            w.open0("p:nvContentPartPr")
            cNvPr(&w, x, o, id, s)
            w.empty0("p:cNvContentPartPr")
            w.empty0("p:nvPr")
            w.close("p:nvContentPartPr")
            if let xf = s.xfrm {
                DML.xfrm(&w, "p:xfrm", xf, nil)
            }
            w.close("p:contentPart")
        }

        static func writeModel(_ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ s: Shape, _ media: MediaId, _ poster: MediaId?) {
            guard let rid = modelRel(x, o, media) else {
                PPTXLog.warn("pptx: 3-D model '\(s.name)' has no embedded part")
                return
            }
            let id = cx.idFor(s)
            let poster = poster.flatMap { p in (x.p.media(p).map { !$0.data.isEmpty } ?? false) ? p : nil }
            guard let poster else {
                writeModelPart(&w, x, o, id, s, rid)
                return
            }
            // Older readers draw the fallback picture; readers that know `am3d` use the model.
            w.open("mc:AlternateContent", A.new().a("xmlns:mc", OPC.nsMC))
            w.open("mc:Choice", A.new().a("xmlns:am3d", "http://schemas.microsoft.com/office/drawing/2017/model3d").a("Requires", "am3d"))
            writeModelPart(&w, x, o, id, s, rid)
            w.close("mc:Choice")
            w.open0("mc:Fallback")
            var pic = Shape.default
            pic.id = ShapeId(0)
            pic.name = s.name
            pic.xfrm = s.xfrm
            pic.kind = .picture(fill: PictureFill(media: poster))
            let pid = cx.ids.fresh()
            shapeWithId(&w, x, o, cx, pic, pid)
            w.close("mc:Fallback")
            w.close("mc:AlternateContent")
        }

        /// A SmartArt graphic: a graphic frame naming its data, layout, quick style and colour parts,
        /// with the group's shapes as the cached drawing PowerPoint shows until it lays the diagram out.
        static func diagram(_ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ s: Shape, _ d: Diagram, _ children: [Shape], _ child: Xfrm) {
            let id = cx.idFor(s)
            let n = x.nextDiagram()
            let frame = s.xfrm ?? child
            func name(_ kind: String) -> String { "ppt/diagrams/\(kind)\(n).xml" }
            // The drawing: the group's shapes in the frame's own coordinates.
            let dname = name("drawing")
            let dout = Out(dname)
            var dw = W.new()
            dw.open(
                "dsp:drawing",
                A.new().a("xmlns:dgm", Dgm.nsDGM).a("xmlns:dsp", Dgm.nsDSP).a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR)
            )
            dw.open0("dsp:spTree")
            dw.open0("dsp:nvGrpSpPr")
            dw.empty("dsp:cNvPr", A.new().a("id", 0).a("name", ""))
            dw.empty0("dsp:cNvGrpSpPr")
            dw.close("dsp:nvGrpSpPr")
            dw.empty0("dsp:grpSpPr")
            let (sx, sy) = (frame.w / child.w.rustMax(1e-6), frame.h / child.h.rustMax(1e-6))
            var k: UInt64 = 0
            var flat: [Shape] = []
            walk(children) { c, _ in
                if case .shape = c.kind {
                    flat.append(c)
                }
            }
            for var c in flat.prefix(10_000) {
                if let xf = c.xfrm {
                    var nx = xf
                    nx.x = (xf.x - child.x) * sx
                    nx.y = (xf.y - child.y) * sy
                    nx.w = xf.w * sx
                    nx.h = xf.h * sy
                    c.xfrm = nx
                }
                k += 1
                dw.open("dsp:sp", A.new().a("modelId", "{" + rustHex(s.id.rawValue, width: 8) + "-5D1A-4C0A-9E5B-" + rustHex(k, width: 12) + "}"))
                dw.open0("dsp:nvSpPr")
                dw.empty("dsp:cNvPr", A.new().a("id", 0).a("name", ""))
                dw.empty0("dsp:cNvSpPr")
                dw.close("dsp:nvSpPr")
                spPrTag(&dw, x, dout, c, true, "dsp:spPr")
                if let st = c.style {
                    styleTag(&dw, st, "dsp:style")
                }
                if let tb = c.text {
                    DML.textBody(&dw, x, dout, "dsp:txBody", tb, false)
                }
                dw.close("dsp:sp")
            }
            dw.close("dsp:spTree")
            dw.close("dsp:drawing")
            x.pkg.xmlPart(dname, Dgm.ctDrawing, dw.finish())
            x.pkg.rels(dname, dout.rels)
            func rel(_ o: Out, _ kind: String, _ part: String) -> String {
                o.rels.addNew(kind, OPC.relative(o.name, part), false)
            }
            let drawingRel = rel(o, Dgm.rtDrawing, dname)
            let data = name("data")
            // Node pictures: on the data model's presentation points, through the data part's rels.
            let mout = Out(data)
            var pics: [(Int, String)] = []
            for (k, node) in d.nodes.enumerated() {
                if let m = node.picture, let r = x.mediaRel(mout, m, "image") {
                    pics.append((k, r))
                }
            }
            x.pkg.xmlPart(data, Dgm.ctData, Dgm.dataXML(d, s.id.rawValue, drawingRel, pics))
            x.pkg.rels(data, mout.rels)
            let dm = rel(o, "diagramData", data)
            let layout = name("layout")
            let loXML = d.layoutXml.map { Array($0.utf8) } ?? Dgm.layoutXML(d.kind)
            x.pkg.xmlPart(layout, Dgm.ctLayout, loXML)
            let lo = rel(o, "diagramLayout", layout)
            let style = name("quickStyle")
            x.pkg.xmlPart(style, Dgm.ctStyle, d.styleXml.map { Array($0.utf8) } ?? Dgm.styleXML(d.style))
            let qs = rel(o, "diagramQuickStyle", style)
            let colors = name("colors")
            x.pkg.xmlPart(colors, Dgm.ctColors, d.colorsXml.map { Array($0.utf8) } ?? Dgm.colorsXML(d.colors))
            let cs = rel(o, "diagramColors", colors)
            var fs = s
            fs.xfrm = frame
            frameOpen(&w, x, o, id, fs)
            w.open("a:graphicData", A.new().a("uri", "http://schemas.openxmlformats.org/drawingml/2006/diagram"))
            w.empty("dgm:relIds", A.new().a("xmlns:dgm", Dgm.nsDGM).a("r:dm", dm).a("r:lo", lo).a("r:qs", qs).a("r:cs", cs))
            w.close("a:graphicData")
            frameClose(&w)
        }

        static func inkShape(_ st: InkStroke, _ i: Int) -> Shape? {
            let pts: [(Double, Double)] = st.points.filter { $0.a.isFinite && $0.b.isFinite }.map { ($0.a, $0.b) }
            let (x0, y0) = pts.reduce((Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)) { a, p in (a.0.rustMin(p.0), a.1.rustMin(p.1)) }
            let (x1, y1) = pts.reduce((-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)) { a, p in (a.0.rustMax(p.0), a.1.rustMax(p.1)) }
            if pts.count < 2 {
                return nil
            }
            let (w, h) = ((x1 - x0).rustMax(1.0), (y1 - y0).rustMax(1.0))
            // PPTX keeps one line width. A pressured stroke exports at its mean sample width;
            // a legacy flat `0.5` stroke stays at the pen width.
            let legacy = inkPressureIsLegacy(st.points)
            let width: Double
            if legacy {
                width = st.width
            } else {
                let n = Double(Swift.max(st.points.count, 1))
                width = st.points.map { inkSampleWidth(st.width, $0.c, false) }.reduce(-0.0, +) / n
            }
            var d = ""
            for (k, p) in pts.enumerated() {
                d += k == 0 ? "M " : "L "
                d += rustFixed(p.0 - x0, places: 2) + " " + rustFixed(p.1 - y0, places: 2) + " "
            }
            var c = ColorRef.rgb(st.color.withAlpha(255))
            if st.highlighter {
                c = c.with(.alpha(50_000))
            }
            var line = Line.solid(c, width.rustMax(0.25))
            line.cap = .round
            line.join = .round
            var s = Shape.default
            s.id = ShapeId(0)
            s.name = "Ink \(i + 1)"
            s.xfrm = Xfrm(x0, y0, w, h)
            s.geom = .custom(paths: [CustomPath(w: w, h: h, d: d, fill: FillMode.none, stroke: true)])
            s.fill = Fill.none_
            s.line = line
            return s
        }

        static func sp(_ w: inout W, _ x: Exp, _ o: Out, _ id: UInt32, _ s: Shape, _ math: Bool) {
            let bgFill = if case .background? = s.fill { true } else { false }
            w.open("p:sp", A.new().t("useBgFill", bgFill))
            w.open0("p:nvSpPr")
            cNvPr(&w, x, o, id, s)
            var cnv = A.new()
            if s.textBox {
                cnv = cnv.a("txBox", "1")
            }
            let lock = s.ph != nil || s.locked
            if lock {
                w.open("p:cNvSpPr", cnv)
                locks(&w, "a:spLocks", s, A.new())
                w.close("p:cNvSpPr")
            } else {
                w.empty("p:cNvSpPr", cnv)
            }
            nvPr(&w, x, o, s)
            w.close("p:nvSpPr")
            var sref = s
            if bgFill {
                sref.fill = nil
            }
            spPr(&w, x, o, sref, true)
            if let st = s.style {
                style(&w, st)
            }
            if let tb = s.text {
                // A shape's text without its own anchor sits in the middle in the model; a file without
                // one would put it at the top, so say so.
                if s.ph == nil && !s.textBox && tb.body.anchor == nil {
                    var tb = tb
                    tb.body.anchor = .middle
                    DML.textBody(&w, x, o, "p:txBody", tb, math)
                } else {
                    DML.textBody(&w, x, o, "p:txBody", tb, math)
                }
            }
            w.close("p:sp")
        }

        static func frameOpen(_ w: inout W, _ x: Exp, _ o: Out, _ id: UInt32, _ s: Shape) {
            w.open0("p:graphicFrame")
            w.open0("p:nvGraphicFramePr")
            cNvPr(&w, x, o, id, s)
            w.open0("p:cNvGraphicFramePr")
            w.empty("a:graphicFrameLocks", A.new().a("noGrp", "1").t("noDrilldown", s.locked).t("noMove", s.locked).t("noResize", s.locked))
            w.close("p:cNvGraphicFramePr")
            nvPr(&w, x, o, s)
            w.close("p:nvGraphicFramePr")
            var xf0 = s.xfrm ?? Xfrm()
            xf0.rot = 0.0
            xf0.flipH = false
            xf0.flipV = false
            DML.xfrm(&w, "p:xfrm", xf0, nil)
            w.open0("a:graphic")
        }

        static func frameClose(_ w: inout W) {
            w.close("a:graphic")
            w.close("p:graphicFrame")
        }

        static func table(_ w: inout W, _ x: Exp, _ o: Out, _ t0: Table) {
            var t = t0
            t.normalize()
            w.open0("a:tbl")
            let (guid, _) = Tables.guidForStyle(t.style)
            if !x.tableStyles.contains(where: { bytesEqual($0, t.style) }) {
                x.tableStyles.append(t.style)
            }
            w.open(
                "a:tblPr",
                A.new()
                    .t("firstRow", t.firstRow)
                    .t("firstCol", t.firstCol)
                    .t("lastRow", t.lastRow)
                    .t("lastCol", t.lastCol)
                    .t("bandRow", t.bandRow)
                    .t("bandCol", t.bandCol)
            )
            if let f = t.background {
                DML.fill(&w, x, o, f)
            }
            w.elt("a:tableStyleId", guid)
            w.close("a:tblPr")
            w.open0("a:tblGrid")
            for c in t.cols {
                w.empty("a:gridCol", A.new().a("w", DML.emuPos(c)))
            }
            w.close("a:tblGrid")
            for row in t.rows {
                w.open("a:tr", A.new().a("h", DML.emuPos(row.height)))
                for c in row.cells {
                    w.open(
                        "a:tc",
                        A.new()
                            .o("gridSpan", c.gridSpan > 1 ? c.gridSpan : nil)
                            .o("rowSpan", c.rowSpan > 1 ? c.rowSpan : nil)
                            .t("hMerge", c.hMerge)
                            .t("vMerge", c.vMerge)
                    )
                    DML.textBody(&w, x, o, "a:txBody", c.text, false)
                    var a = A.new()
                    if let m = c.margins {
                        a = a.a("marL", DML.emu(at4(m, 0))).a("marR", DML.emu(at4(m, 1))).a("marT", DML.emu(at4(m, 2))).a("marB", DML.emu(at4(m, 3)))
                    }
                    a = a.o("vert", c.vertical.map(\.xml)).o(
                        "anchor",
                        c.anchor.map { an -> String in
                            switch an {
                            case .justified, .distributed: "t"
                            default: an.xml
                            }
                        }
                    )
                    w.open("a:tcPr", a)
                    let borders: [(String, Line?)] = [
                        ("a:lnL", c.borders.at(0) ?? nil),
                        ("a:lnR", c.borders.at(1) ?? nil),
                        ("a:lnT", c.borders.at(2) ?? nil),
                        ("a:lnB", c.borders.at(3) ?? nil),
                        ("a:lnTlToBr", c.diagDown),
                        ("a:lnBlToTr", c.diagUp),
                    ]
                    for (tag, l) in borders {
                        if let l {
                            DML.line(&w, x, o, tag, l)
                        }
                    }
                    if let f = c.fill {
                        if case .background = f {} else { DML.fill(&w, x, o, f) }
                    }
                    w.close("a:tcPr")
                    w.close("a:tc")
                }
                w.close("a:tr")
            }
            w.close("a:tbl")
        }

        static func media(_ w: inout W, _ x: Exp, _ o: Out, _ id: UInt32, _ s: Shape, _ m: MediaClip) {
            let kind = m.video ? "video" : "audio"
            let link = x.mediaRel(o, m.media, kind)
            let embed = x.mediaRelNew(o, m.media, OPC.rtMedia)
            w.open0("p:pic")
            w.open0("p:nvPicPr")
            var s2 = s
            if s2.click == nil {
                s2.click = Hyperlink(action: .playMedia, tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
            }
            cNvPr(&w, x, o, id, s2)
            w.open0("p:cNvPicPr")
            w.empty("a:picLocks", A.new().a("noChangeAspect", "1"))
            w.close("p:cNvPicPr")
            w.open0("p:nvPr")
            let tag = m.video ? "a:videoFile" : "a:audioFile"
            if let l = link {
                w.empty(tag, A.new().a("r:link", l))
            }
            if let e = embed {
                w.open0("p:extLst")
                w.open("p:ext", A.new().a("uri", "{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}"))
                w.open("p14:media", A.new().a("xmlns:p14", OPC.nsP14).a("r:embed", e))
                if m.trimStartMs > 0 || m.trimEndMs > 0 {
                    w.empty(
                        "p14:trim",
                        A.new().o("st", m.trimStartMs > 0 ? m.trimStartMs : nil).o("end", m.trimEndMs > 0 ? m.trimEndMs : nil)
                    )
                }
                if m.fadeInMs > 0 || m.fadeOutMs > 0 {
                    w.empty("p14:fade", A.new().o("in", m.fadeInMs > 0 ? m.fadeInMs : nil).o("out", m.fadeOutMs > 0 ? m.fadeOutMs : nil))
                }
                if !m.bookmarks.isEmpty {
                    w.open0("p14:bmkLst")
                    for b in m.bookmarks.prefix(1000) {
                        w.empty("p14:bmk", A.new().a("name", b.a).a("time", b.b))
                    }
                    w.close("p14:bmkLst")
                }
                w.close("p14:media")
                w.close("p:ext")
                w.close("p:extLst")
            }
            w.close("p:nvPr")
            w.close("p:nvPicPr")
            let poster = PictureFill(media: m.poster ?? MediaId.default, crop: m.crop)
            DML.blipFill(&w, x, o, "p:blipFill", poster)
            var s3 = s
            s3.fill = nil
            spPr(&w, x, o, s3, true)
            w.close("p:pic")
        }

        static func opaque(
            _ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ s: Shape, _ xml: String, _ preview: MediaId?, _ label: String,
            _ parts: [Triple<String, String, MediaId>]
        ) {
            // Kept XML is written back as it was when every part it references was kept too, with those
            // parts re-added under this slide's relationship ids.
            if let doc = try? parseXML(xml), ["graphicFrame", "sp", "grpSp", "cxnSp"].contains(where: { bytesEqual($0, doc.root.local) }) {
                var partMap: [ByteKey: (String, MediaId)] = [:]
                for p in parts where partMap[ByteKey(p.a)] == nil {
                    partMap[ByteKey(p.a)] = (p.b, p.c)
                }
                var ids: [ByteKey: String]? = [:]
                for r in PPTXRead.relRefs(doc.root) {
                    guard let (kind, m) = partMap[ByteKey(r)], let new = x.mediaRel(o, m, kind) else {
                        ids = nil
                        break
                    }
                    ids?[ByteKey(r)] = new
                }
                if let ids {
                    var root = doc.root
                    setRelIds(&root, ids, 0)
                    oleFallback(&root, x, o, preview)
                    let id = cx.idFor(s)
                    setCNvPrId(&root, id)
                    w.raw(root.toXML())
                    return
                }
            }
            PPTXLog.warn("pptx: object '\(label)' written as its preview picture")
            let id = cx.idFor(s)
            var p = s
            if p.name.isEmpty {
                p.name = label
            }
            if let m = preview, x.p.media(m) != nil {
                p.kind = .picture(fill: PictureFill(media: m))
                p.ph = nil
                shapeWithId(&w, x, o, cx, p, id)
            } else {
                p.kind = .shape
                p.ph = nil
                p.geom = .preset("rect")
                p.fill = Fill.none_
                p.text = nil
                sp(&w, x, o, id, p, false)
            }
        }

        static func shapeWithId(_ w: inout W, _ x: Exp, _ o: Out, _ cx: Ctx, _ s: Shape, _ id: UInt32) {
            // Pictures only: reuse the given id.
            if case .picture(let fill) = s.kind {
                w.open0("p:pic")
                w.open0("p:nvPicPr")
                cNvPr(&w, x, o, id, s)
                w.open0("p:cNvPicPr")
                w.empty("a:picLocks", A.new().a("noChangeAspect", "1"))
                w.close("p:cNvPicPr")
                w.empty0("p:nvPr")
                w.close("p:nvPicPr")
                DML.blipFill(&w, x, o, "p:blipFill", fill)
                // As for any picture, a colour or pattern fill shows behind the image (an object's preview
                // keeps its fallback picture's fill).
                var s2 = s
                switch s2.fill {
                case .picture?, .background?, .group?: s2.fill = nil
                default: break
                }
                spPr(&w, x, o, s2, true)
                w.close("p:pic")
            } else {
                shape(&w, x, o, cx, s, 0)
            }
        }

        /// The index of the first element child named `local`.
        private static func firstElementIndex(_ e: XMLEl, _ local: String) -> Int? {
            e.children.firstIndex { if case .el(let c) = $0 { c.is(local) } else { false } }
        }

        /// A legacy OLE object finds its preview in the slide's VML drawing through `spid`, and PowerPoint
        /// won't open the slide without it. We don't write that drawing, so write PowerPoint's own
        /// fallback form instead: no `spid`, and the preview as a `p:pic`.
        static func oleFallback(_ root: inout XMLEl, _ x: Exp, _ o: Out, _ preview: MediaId?) {
            let xfrm: (String, String, String, String)? = root.child("xfrm").map { t in
                func at(_ e: String, _ a: String) -> String { t.child(e)?.attr(a) ?? "0" }
                return (at("off", "x"), at("off", "y"), at("ext", "cx"), at("ext", "cy"))
            }
            guard let gi = firstElementIndex(root, "graphic"), case .el(var g) = root.children[gi],
                  let di = firstElementIndex(g, "graphicData"), case .el(var d) = g.children[di],
                  let oi = firstElementIndex(d, "oleObj"), case .el(var ole) = d.children[oi]
            else {
                return
            }
            if ole.child("pic") != nil || ole.attr("spid") == nil {
                return
            }
            ole.attrs.removeAll { bytesEqual($0.key, "spid") }
            let rel = preview.flatMap { x.mediaRel(o, $0, "image") } ?? x.placeholderRel(o)
            let (ox, oy, cx, cy) = xfrm ?? ("", "", "", "")
            let pic = "<p:pic><p:nvPicPr><p:cNvPr id=\"0\" name=\"\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rel)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(ox)\" y=\"\(oy)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            if let pd = try? parseXML(pic) {
                ole.children.append(.el(pd.root))
            }
            d.children[oi] = .el(ole)
            g.children[di] = .el(d)
            root.children[gi] = .el(g)
        }

        static func setRelIds(_ e: inout XMLEl, _ ids: [ByteKey: String], _ depth: Int) {
            if depth > XML.maxDepth {
                return
            }
            for i in e.attrs.indices {
                let (k, v) = e.attrs[i]
                if PPTXRead.isRelAttr(k, v), let new = ids[ByteKey(v)] {
                    e.attrs[i].value = new
                }
            }
            e.elementsMut { c in setRelIds(&c, ids, depth + 1) }
        }

        static func setCNvPrId(_ el: inout XMLEl, _ id: UInt32) {
            func rec(_ e: inout XMLEl, _ depth: Int) -> Bool {
                if depth > 8 {
                    return false
                }
                if e.is("cNvPr") {
                    e.setAttr("id", String(id))
                    return true
                }
                for i in e.children.indices {
                    guard case .el(var c) = e.children[i] else { continue }
                    let done = rec(&c, depth + 1)
                    e.children[i] = .el(c)
                    if done { return true }
                }
                return false
            }
            _ = rec(&el, 0)
        }

        /// The fixed group header every shape tree starts with.
        static func treeHeader(_ w: inout W) {
            w.open0("p:nvGrpSpPr")
            w.empty("p:cNvPr", A.new().a("id", 1).a("name", ""))
            w.empty0("p:cNvGrpSpPr")
            w.empty0("p:nvPr")
            w.close("p:nvGrpSpPr")
            w.open0("p:grpSpPr")
            w.open0("a:xfrm")
            w.empty("a:off", A.new().a("x", 0).a("y", 0))
            w.empty("a:ext", A.new().a("cx", 0).a("cy", 0))
            w.empty("a:chOff", A.new().a("x", 0).a("y", 0))
            w.empty("a:chExt", A.new().a("cx", 0).a("cy", 0))
            w.close("a:xfrm")
            w.close("p:grpSpPr")
        }
    }
}
