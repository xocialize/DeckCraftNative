// DCPPTX — PPTX export: `Presentation` → package. Port of deckcraft crates/pptx/src/write/mod.rs and
// the `export` / `export_as` entry points of lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

extension PPTX {
    /// Write a `.pptx` package.
    public static func export(_ p: Presentation) throws(PPTXError) -> [UInt8] {
        try onLargeStack { () throws(PPTXError) in try PPTXWrite.export(p, PPTXWrite.ctPres) }
    }

    /// Write a package for `ext`: `potx` (template) and `ppsx` (slide show) differ from `pptx` only in
    /// the main part's content type.
    public static func exportAs(_ p: Presentation, _ ext: String) throws(PPTXError) -> [UInt8] {
        let ct = if bytesEqual(ext, "potx") {
            PPTXWrite.ctTemplate
        } else if bytesEqual(ext, "ppsx") {
            PPTXWrite.ctShow
        } else {
            PPTXWrite.ctPres
        }
        return try onLargeStack { () throws(PPTXError) in try PPTXWrite.export(p, ct) }
    }
}

/// The `write` module.
enum PPTXWrite {
    static let ctPres = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
    static let ctTemplate = "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml"
    static let ctShow = "application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml"
    static let ctSlide = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"
    static let ctLayout = "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"
    static let ctMaster = "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"
    static let ctNotesMaster = "application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"
    static let ctHandoutMaster = "application/vnd.openxmlformats-officedocument.presentationml.handoutMaster+xml"
    static let ctNotes = "application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"
    static let ctTheme = "application/vnd.openxmlformats-officedocument.theme+xml"
    static let ctPresProps = "application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"
    static let ctViewProps = "application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"
    static let ctTableStyles = "application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"
    static let ctTags = "application/vnd.openxmlformats-officedocument.presentationml.tags+xml"
    static let ctChart = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    static let ctChartex = "application/vnd.ms-office.chartex+xml"
    static let rtChartex = "http://schemas.microsoft.com/office/2014/relationships/chartEx"
    static let ctComments = "application/vnd.openxmlformats-officedocument.presentationml.comments+xml"
    static let ctAuthors = "application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"
    /// Modern threaded comments (read by PowerPoint 2021+ and DeckCraft; the flattened legacy
    /// part next to it serves older readers).
    static let ctCommentsModern = "application/vnd.ms-powerpoint.comments+xml"
    static let ctAuthorsModern = "application/vnd.ms-powerpoint.authors+xml"
    static let rtCommentsModern = "http://schemas.microsoft.com/office/2018/10/relationships/comments"
    static let rtAuthorsModern = "http://schemas.microsoft.com/office/2018/10/relationships/authors"
    static let ctCore = "application/vnd.openxmlformats-package.core-properties+xml"
    static let ctApp = "application/vnd.openxmlformats-officedocument.extended-properties+xml"

    /// Export state.
    final class Exp {
        let p: Presentation
        var pkg = PackageOut()
        var mediaParts: [MediaId: String] = [:]
        var nImage: UInt32 = 0
        var nMedia: UInt32 = 0
        var nChart: UInt32 = 0
        var nDiagram: UInt32 = 0
        var nTags: UInt32 = 0
        var nChartex: UInt32 = 0
        /// Parts kept from an unchanged chart (`ppt/…/keptN.ext`).
        var nKept: UInt32 = 0
        var slideParts: [SlideId: String] = [:]
        var tableStyles: [String] = []
        var placeholder: String?

        init(_ p: Presentation) {
            self.p = p
        }

        func mediaPart(_ id: MediaId) -> String? {
            if let p = mediaParts[id] {
                return p
            }
            guard let m = p.media(id) else { return nil }
            if m.data.isEmpty {
                return nil
            }
            let ext = extFor(m.contentType, m.name, m.data)
            let ct = m.contentType.isEmpty || !m.contentType.unicodeScalars.contains("/") ? mimeFor("x." + ext) : m.contentType
            let name: String
            if hasBytePrefix(ct, "image/") {
                nImage &+= 1
                name = "ppt/media/image\(nImage).\(ext)"
            } else {
                nMedia &+= 1
                name = "ppt/media/media\(nMedia).\(ext)"
            }
            pkg.binary(name, ct, m.data)
            mediaParts[id] = name
            return name
        }

        /// A relationship from `o` to a media item (embedded part, or external link).
        func mediaRel(_ o: Out, _ id: MediaId, _ kind: String) -> String? {
            guard let m = p.media(id) else { return nil }
            if m.data.isEmpty {
                guard let link = m.link else { return nil }
                return o.rels.add(kind, link, true)
            }
            guard let part = mediaPart(id) else { return nil }
            return o.rels.add(kind, OPC.relative(o.name, part), false)
        }

        func mediaRelNew(_ o: Out, _ id: MediaId, _ kind: String) -> String? {
            guard let m = p.media(id) else { return nil }
            if m.data.isEmpty {
                return nil
            }
            guard let part = mediaPart(id) else { return nil }
            return o.rels.add(kind, OPC.relative(o.name, part), false)
        }

        /// A tiny transparent PNG for pictures whose image is missing.
        func placeholderRel(_ o: Out) -> String {
            let part: String
            if let p = placeholder {
                part = p
            } else {
                nImage &+= 1
                let name = "ppt/media/image\(nImage).png"
                pkg.binary(name, "image/png", PNG.transparent1x1())
                placeholder = name
                part = name
            }
            return o.rels.add("image", OPC.relative(o.name, part), false)
        }

        /// The number of the next SmartArt graphic's parts.
        func nextDiagram() -> UInt32 {
            nDiagram &+= 1
            return nDiagram
        }

        /// A new `ppt/tags/tagN.xml` part holding `tags`, related from `o`.
        func tagsRel(_ o: Out, _ tags: [Pair<String, String>]) -> String {
            nTags &+= 1
            let name = "ppt/tags/tag\(nTags).xml"
            var w = W.new()
            rootOpen(&w, "p:tagLst", A.new())
            for t in tags.prefix(10_000) {
                w.empty("p:tag", A.new().a("name", t.a).a("val", t.b))
            }
            w.close("p:tagLst")
            pkg.xmlPart(name, ctTags, w.finish())
            return o.rels.addNew("tags", OPC.relative(o.name, name), false)
        }

        /// An Office 2016 chart's `chartEx` part, its kept or new style parts, and its relationship id.
        func chartexRel(_ o: Out, _ c: Chart) -> String? {
            guard let (xml, preserved) = Charts.chartexPart(c) else { return nil }
            nChartex &+= 1
            let name = "ppt/charts/chartEx\(nChartex).xml"
            pkg.xmlPart(name, ctChartex, xml)
            var rels = RelsOut()
            if preserved {
                rels = Charts.writeKept(&pkg, name, c, &nKept)
            } else if !c.kept.parts.isEmpty {
                PPTXLog.warn("pptx: chart data changed; the embedded workbook was not written back")
            }
            // Without its style parts PowerPoint refuses the slide (a divergence from deckcraft).
            ChartexStyle.add(&pkg, name, nChartex, &rels)
            return o.rels.addNew(rtChartex, OPC.relative(o.name, name), false)
        }

        func chartRel(_ o: Out, _ c: Chart) -> String {
            nChart &+= 1
            let name = "ppt/charts/chart\(nChart).xml"
            let (xml, preserved) = Charts.chartXML(c)
            pkg.xmlPart(name, ctChart, xml)
            if preserved {
                Charts.writeKept(&pkg, name, c, &nKept)
            } else if !c.kept.parts.isEmpty {
                PPTXLog.warn("pptx: chart data changed; the embedded workbook was not written back")
            }
            return o.rels.addNew("chart", OPC.relative(o.name, name), false)
        }
    }

    /// A part being written: its name and relationships.
    final class Out {
        let name: String
        var rels = RelsOut()

        init(_ name: String) {
            self.name = name
        }
    }

    static func extFor(_ contentType: String, _ name: String, _ data: [UInt8]) -> String {
        let byCT = switch contentType {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpeg"
        case "image/gif": "gif"
        case "image/bmp": "bmp"
        case "image/tiff": "tiff"
        case "image/svg+xml": "svg"
        case "image/x-emf", "image/emf": "emf"
        case "image/x-wmf", "image/wmf": "wmf"
        case "image/webp": "webp"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-ms-wmv": "wmv"
        case "video/x-msvideo": "avi"
        case "video/webm": "webm"
        case "audio/mpeg": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/x-ms-wma": "wma"
        case "audio/ogg": "ogg"
        case "audio/flac": "flac"
        case "model/gltf-binary": "glb"
        default: ""
        }
        if !byCT.isEmpty && contentType.utf8.allSatisfy({ $0 < 0x80 }) {
            return byCT
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return "jpeg"
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "gif"
        }
        let e = rsplitOnce(name, ".").map { rustASCIILowercase($0.1) } ?? ""
        return !e.isEmpty && e.utf8.count <= 5 && isASCIIAlnum(e) ? e : "bin"
    }

    /// `p:custDataLst` pointing at a tags part, when there are tags.
    static func custData(_ w: inout W, _ x: Exp, _ o: Out, _ tags: [Pair<String, String>]) {
        if tags.isEmpty {
            return
        }
        let id = x.tagsRel(o, tags)
        w.open0("p:custDataLst")
        w.empty("p:tags", A.new().a("r:id", id))
        w.close("p:custDataLst")
    }

    static func rootOpen(_ w: inout W, _ tag: String, _ extra: A) {
        var a = A.new().a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR).a("xmlns:p", OPC.nsP)
        a.v.append(contentsOf: extra.v)
        w.open(tag, a)
    }

    static func background(_ w: inout W, _ x: Exp, _ o: Out, _ bg: Background) {
        w.open0("p:bg")
        switch bg {
        case .fill(let fill):
            w.open0("p:bgPr")
            switch fill {
            case .background, .group: w.empty0("a:noFill")
            default: DML.fill(&w, x, o, fill)
            }
            w.empty0("a:effectLst")
            w.close("p:bgPr")
        case .ref(let idx0, let color):
            let idx = (1 ... 3).contains(idx0) || (1001 ... 1003).contains(idx0) ? idx0 : 1001
            w.open("p:bgRef", A.new().a("idx", idx))
            DML.color(&w, color)
            w.close("p:bgRef")
        }
        w.close("p:bg")
    }

    static func cSld(_ w: inout W, _ x: Exp, _ o: Out, _ name: String, _ bg: Background?, _ list: [Shape], _ tags: [Pair<String, String>]) -> Shapes.IdMap {
        w.open("p:cSld", A.new().o("name", name.isEmpty ? nil : name))
        if let bg {
            background(&w, x, o, bg)
        }
        w.open0("p:spTree")
        Shapes.treeHeader(&w)
        let cx = Shapes.Ctx(ids: Shapes.IdMap.build(list))
        Shapes.shapes(&w, x, o, cx, list, 0)
        w.close("p:spTree")
        custData(&w, x, o, tags)
        w.close("p:cSld")
        return cx.ids
    }

    static let clrKeys: [(String, String)] = [
        ("bg1", "lt1"),
        ("tx1", "dk1"),
        ("bg2", "lt2"),
        ("tx2", "dk2"),
        ("accent1", "accent1"),
        ("accent2", "accent2"),
        ("accent3", "accent3"),
        ("accent4", "accent4"),
        ("accent5", "accent5"),
        ("accent6", "accent6"),
        ("hlink", "hlink"),
        ("folHlink", "folHlink"),
    ]

    static func clrMap(_ w: inout W, _ map: [Pair<String, String>]) {
        w.empty("p:clrMap", clrMapAttrs(map))
    }

    /// `p:clrMapOvr`: the layout's or slide's own colour map, else `a:masterClrMapping`.
    static func clrMapOvr(_ w: inout W, _ map: [Pair<String, String>]?) {
        w.open0("p:clrMapOvr")
        if let m = map {
            w.empty("a:overrideClrMapping", clrMapAttrs(m))
        } else {
            w.empty0("a:masterClrMapping")
        }
        w.close("p:clrMapOvr")
    }

    /// The twelve colour map attributes, each a theme slot (the default for anything else).
    static func clrMapAttrs(_ map: [Pair<String, String>]) -> A {
        var a = A.new()
        for (k, d) in clrKeys {
            var v = d
            if let found = map.first(where: { bytesEqual($0.a, k) })?.b,
               SchemeSlot.theme.contains(where: { bytesEqual($0.xmlName, found) })
            {
                v = found
            }
            a = a.a(k, v)
        }
        return a
    }

    /// The well-formed `ext` elements of an extension list's children.
    static func extElements(_ raw: String?) -> [String] {
        guard let raw, !rustTrim(raw).isEmpty, let d = try? parseXML("<x>" + raw + "</x>") else { return [] }
        return d.root.elements.filter { $0.is("ext") && $0.hasAttr("uri") }.map { $0.toXML() }
    }

    static func extList(_ w: inout W, _ raw: String?) {
        // Only keep well-formed extension elements.
        let exts = extElements(raw)
        if exts.isEmpty {
            return
        }
        w.open0("p:extLst")
        for e in exts {
            w.raw(e)
        }
        w.close("p:extLst")
    }

    /// Strip an `<p:extLst>` wrapper (masters/layouts keep the whole element).
    static func extChildren(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let d = try? parseXML(raw) else { return nil }
        if d.root.is("extLst") {
            let ns = d.nsDecls()
            return d.root.elements.map { PPTXRead.keepXML($0, ns) }.joined()
        }
        return raw
    }

    /// The slide's extension list, plus the modern-comments anchor when the slide has a threaded
    /// comment part: the rel reference is how PowerPoint finds it.
    static func slideExtList(_ w: inout W, _ raw: String?, _ commentRel: String?) {
        var exts = extElements(raw)
        if let rid = commentRel {
            var e = W.frag()
            e.open("p:ext", A.new().a("uri", PPTX.commentsExtURI))
            e.empty("p188:commentRel", A.new().a("xmlns:p188", OPC.nsP188).a("r:id", rid))
            e.close("p:ext")
            exts.append(e.s)
        }
        if exts.isEmpty {
            return
        }
        w.open0("p:extLst")
        for e in exts {
            w.raw(e)
        }
        w.close("p:extLst")
    }

    static func notesMasterShapes(_ size: Size) -> [Shape] {
        let (w, h) = (size.width, size.height)
        func mk(_ id: UInt32, _ name: String, _ kind: PhType, _ idx: UInt32, _ x: Double, _ y: Double, _ ww: Double, _ hh: Double) -> Shape {
            var s = Shape.default
            s.id = ShapeId(id)
            s.name = name
            s.xfrm = Xfrm(x, y, ww, hh)
            s.ph = Placeholder(kind: kind, idx: idx, size: kind != .slideImage ? "quarter" : nil)
            s.text = kind != .slideImage ? TextBody() : nil
            return s
        }
        var img = mk(4, "Slide Image Placeholder 3", .slideImage, 2, w * 0.125, h * 0.125, w * 0.75, h * 0.375)
        img.fill = Fill.none_
        img.line = Line.solid(.rgb(.black), 1.0)
        var body = mk(5, "Notes Placeholder 4", .body, 3, w * 0.1, h * 0.53, w * 0.8, h * 0.36)
        body.text?.paragraphs = [Paragraph("Click to edit Master text styles")]
        return [
            mk(2, "Header Placeholder 1", .header, 0, 0.0, 0.0, w * 0.43, h * 0.05),
            mk(3, "Date Placeholder 2", .date, 1, w * 0.57, 0.0, w * 0.43, h * 0.05),
            img,
            body,
            mk(6, "Footer Placeholder 5", .footer, 4, 0.0, h * 0.95, w * 0.43, h * 0.05),
            mk(7, "Slide Number Placeholder 6", .slideNum, 5, w * 0.57, h * 0.95, w * 0.43, h * 0.05),
        ]
    }

    /// What the notes master should be on save. A master we read is written back, including its
    /// header, footer, date and slide-number text. A deck that has never had one gets the placeholders
    /// we generate.
    struct NotesMasterWrite {
        var shapes: [Shape]
        var background: Background?
        var colorMap: [Pair<String, String>]
        var style: ListStyle
        var theme: Theme?
    }

    static func notesMasterWrite(_ p: Presentation) -> NotesMasterWrite? {
        let nm = p.notesMaster
        let kept = nm.flatMap { $0.shapes.isEmpty ? nil : $0 }
        let hasNotes = p.slides.contains { !$0.notes.isEmpty }
        if !hasNotes && nm == nil {
            return nil
        }
        let defaultBg = Background.ref(idx: 1001, color: .scheme(.bg1))
        if let m = kept {
            return NotesMasterWrite(
                shapes: m.shapes,
                background: m.background ?? defaultBg,
                colorMap: m.colorMap,
                style: m.bodyStyle.isEmpty ? notesStyle() : m.bodyStyle,
                theme: m.theme
            )
        }
        // A master without placeholders of its own gets PowerPoint's defaults, keeping its
        // background and colour map.
        return NotesMasterWrite(
            shapes: notesMasterShapes(p.notesSize),
            background: nm?.background ?? defaultBg,
            colorMap: nm?.colorMap ?? [],
            style: notesStyle(),
            theme: nil
        )
    }

    static func notesStyle() -> ListStyle {
        var ls = ListStyle()
        for i in UInt8(0) ..< 9 {
            ls.set(
                i,
                LevelStyle(
                    para: ParaProps(align: .left, marginLeft: 36.0 * Double(i)),
                    run: RunProps(font: "+mn-lt", size: 12.0, fill: .solid(.scheme(.tx1)))
                )
            )
        }
        return ls
    }

    /// A plausible xsd:dateTime (`YYYY-MM-DD[THH:MM:SS(.frac)?(Z|±HH:MM)?]`): the ranges are
    /// checked, so a model value like `2025-13-45T99:99` falls back to the default instead of
    /// reaching a required `dt`/`created` attribute.
    static func validDate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        func n(_ lo: Int, _ hi: Int) -> UInt32? {
            byteSlice(s, lo, hi).flatMap { rustParseUnsigned($0, as: UInt32.self) }
        }
        guard n(0, 4) != nil, let mo = n(5, 7), let d = n(8, 10) else { return false }
        if b.at(4) != UInt8(ascii: "-") || b.at(7) != UInt8(ascii: "-") || !(1 ... 12).contains(mo) || !(1 ... 31).contains(d) {
            return false
        }
        switch b.at(10) {
        case nil:
            return true
        case UInt8(ascii: "T"):
            guard let h = n(11, 13), let mi = n(14, 16), let sec = n(17, 19) else { return false }
            return h <= 23 && mi <= 59 && sec <= 60 && b.at(13) == UInt8(ascii: ":") && b.at(16) == UInt8(ascii: ":")
        default:
            return false
        }
    }

    /// A copy of the presentation with every slide pointing at a layout that exists.
    static func sanitized(_ p: Presentation) -> Presentation {
        var need = p.masters.isEmpty || p.masters.contains { $0.layouts.isEmpty }
        need = need || p.slides.contains { p.layout($0.layout) == nil }
        if !need {
            return p
        }
        var q = p
        if q.masters.isEmpty {
            let (m, next) = buildMaster(q.slideSize, Theme.default, Swift.max(q.nextId, 1))
            q.nextId = next
            q.masters.append(m)
        }
        for i in q.masters.indices where q.masters[i].layouts.isEmpty {
            // An exhausted id space exports without the synthesized layout rather than with a
            // duplicated one (#407).
            let (raw, overflow) = Swift.max(q.nextId, 1).addingReportingOverflow(1)
            if overflow { continue }
            q.nextId = raw
            var l = Layout()
            l.id = LayoutId(raw)
            l.name = "Blank"
            l.kind = .blank
            l.showMasterShapes = true
            q.masters[i].layouts.append(l)
        }
        let first = q.masters.first?.layouts.first?.id ?? LayoutId.default
        let ok = q.masters.flatMap { $0.layouts.map(\.id) }
        for i in q.slides.indices where !ok.contains(q.slides[i].layout) {
            q.slides[i].layout = first
        }
        return q
    }

    static func export(_ p0: Presentation, _ mainCT: String) throws(PPTXError) -> [UInt8] {
        let p = sanitized(p0)
        let x = Exp(p)
        for (i, s) in p.slides.enumerated() {
            x.slideParts[s.id] = "ppt/slides/slide\(i + 1).xml"
        }
        let pres = Out("ppt/presentation.xml")

        // Masters, themes and layouts.
        var masterRids: [(UInt64, String)] = []
        var layoutParts: [LayoutId: String] = [:]
        var nLayout: UInt32 = 0
        var bigId: UInt64 = 2_147_483_648
        for (mi, m) in p.masters.enumerated() {
            let mname = "ppt/slideMasters/slideMaster\(mi + 1).xml"
            let tname = "ppt/theme/theme\(mi + 1).xml"
            let mo = Out(mname)
            var lrids: [String] = []
            for l in m.layouts {
                nLayout &+= 1
                let lname = "ppt/slideLayouts/slideLayout\(nLayout).xml"
                layoutParts[l.id] = lname
                let rid = mo.rels.add("slideLayout", OPC.relative(mname, lname), false)
                lrids.append(rid)
                let lo = Out(lname)
                _ = lo.rels.add("slideMaster", OPC.relative(lname, mname), false)
                let xml = layoutXML(x, lo, l)
                x.pkg.xmlPart(lname, ctLayout, xml)
                x.pkg.rels(lname, lo.rels)
            }
            _ = mo.rels.add("theme", OPC.relative(mname, tname), false)
            let to = Out(tname)
            let txml = Themes.themeXML(x, to, m.theme)
            x.pkg.xmlPart(tname, ctTheme, txml)
            x.pkg.rels(tname, to.rels)
            let masterId = bigId
            bigId &+= 1
            var layoutIds: [(UInt64, String)] = []
            for rid in lrids {
                layoutIds.append((bigId, rid))
                bigId &+= 1
            }
            let xml = masterXML(x, mo, m, layoutIds)
            x.pkg.xmlPart(mname, ctMaster, xml)
            x.pkg.rels(mname, mo.rels)
            masterRids.append((masterId, pres.rels.add("slideMaster", OPC.relative("ppt/presentation.xml", mname), false)))
        }

        // Notes master when a slide has notes, or the file already has one (its header and footer
        // live on the master, not on the notes slides).
        let notesMaster = "ppt/notesMasters/notesMaster1.xml"
        var notesMasterRid: String?
        if let nm = notesMasterWrite(p) {
            let tname = "ppt/theme/theme\(p.masters.count + 1).xml"
            let no = Out(notesMaster)
            _ = no.rels.add("theme", OPC.relative(notesMaster, tname), false)
            let theme = nm.theme ?? p.masters.first?.theme ?? Theme.default
            let to = Out(tname)
            let txml = Themes.themeXML(x, to, theme)
            x.pkg.xmlPart(tname, ctTheme, txml)
            x.pkg.rels(tname, to.rels)
            var w = W.new()
            rootOpen(&w, "p:notesMaster", A.new())
            _ = cSld(&w, x, no, "", nm.background, nm.shapes, [])
            clrMap(&w, nm.colorMap)
            DML.listStyle(&w, x, no, "p:notesStyle", nm.style)
            w.close("p:notesMaster")
            x.pkg.xmlPart(notesMaster, ctNotesMaster, w.finish())
            x.pkg.rels(notesMaster, no.rels)
            notesMasterRid = pres.rels.add("notesMaster", OPC.relative("ppt/presentation.xml", notesMaster), false)
        }

        // Handout master. Its header, footer, date and slide-number text live on this part; a deck
        // that has never had one does not gain an empty master on save.
        let handoutPath = "ppt/handoutMasters/handoutMaster1.xml"
        var handoutRid: String?
        if let hm = p.handoutMaster {
            let tindex = p.masters.count + 1 + (notesMasterRid != nil ? 1 : 0)
            let tname = "ppt/theme/theme\(tindex).xml"
            let ho = Out(handoutPath)
            _ = ho.rels.add("theme", OPC.relative(handoutPath, tname), false)
            let to = Out(tname)
            let txml = Themes.themeXML(x, to, hm.theme)
            x.pkg.xmlPart(tname, ctTheme, txml)
            x.pkg.rels(tname, to.rels)
            var w = W.new()
            rootOpen(&w, "p:handoutMaster", A.new())
            _ = cSld(&w, x, ho, hm.name, hm.background, hm.shapes, [])
            clrMap(&w, hm.colorMap)
            w.close("p:handoutMaster")
            x.pkg.xmlPart(handoutPath, ctHandoutMaster, w.finish())
            x.pkg.rels(handoutPath, ho.rels)
            handoutRid = pres.rels.add("handoutMaster", OPC.relative("ppt/presentation.xml", handoutPath), false)
        }

        // Comment authors.
        var authors = Authors()
        var nComments: UInt32 = 0

        // Slides.
        var slideRids: [String] = []
        for (i, s) in p.slides.enumerated() {
            let sname = "ppt/slides/slide\(i + 1).xml"
            let so = Out(sname)
            if let lp = layoutParts[s.layout] {
                _ = so.rels.add("slideLayout", OPC.relative(sname, lp), false)
            }
            if !s.notes.isEmpty {
                let nname = "ppt/notesSlides/notesSlide\(i + 1).xml"
                _ = so.rels.add("notesSlide", OPC.relative(sname, nname), false)
                let no = Out(nname)
                _ = no.rels.add("notesMaster", OPC.relative(nname, notesMaster), false)
                _ = no.rels.add("slide", OPC.relative(nname, sname), false)
                let xml = notesXML(x, no, s.notes)
                x.pkg.xmlPart(nname, ctNotes, xml)
                x.pkg.rels(nname, no.rels)
            }
            var commentRel: String?
            if !s.comments.isEmpty {
                nComments &+= 1
                let cname = "ppt/comments/comment\(nComments).xml"
                _ = so.rels.add("comments", OPC.relative(sname, cname), false)
                x.pkg.xmlPart(cname, ctComments, commentsXML(s.comments, &authors))
                // The modern threaded part next to the flattened legacy one (issue #70):
                // PowerPoint 2021+ and DeckCraft read replies and resolved state from it,
                // older readers keep the legacy part.
                let mname = "ppt/comments/modernComment\(nComments).xml"
                let rid = so.rels.add(rtCommentsModern, OPC.relative(sname, mname), false)
                x.pkg.xmlPart(mname, ctCommentsModern, modernCommentsXML(s.comments, cname, &authors))
                commentRel = rid
            }
            let xml = slideXML(x, so, s, commentRel)
            x.pkg.xmlPart(sname, ctSlide, xml)
            x.pkg.rels(sname, so.rels)
            slideRids.append(pres.rels.add("slide", OPC.relative("ppt/presentation.xml", sname), false))
        }
        if !authors.list.isEmpty {
            let name = "ppt/commentAuthors.xml"
            var w = W.new()
            rootOpen(&w, "p:cmAuthorLst", A.new())
            for (i, a) in authors.list.enumerated() {
                w.empty("p:cmAuthor", A.new().a("id", i).a("name", a.name).a("initials", a.initials).a("lastIdx", a.last).a("clrIdx", i % 8))
            }
            w.close("p:cmAuthorLst")
            x.pkg.xmlPart(name, ctAuthors, w.finish())
            _ = pres.rels.add("commentAuthors", "commentAuthors.xml", false)
            // The modern authors part the threaded comments' authorId GUIDs point at.
            var w2 = W.new()
            w2.open("p188:authorLst", A.new().a("xmlns:p188", OPC.nsP188))
            for a in authors.list {
                w2.empty("p188:author", A.new().a("id", authorGUID(a.name)).a("name", a.name).a("initials", a.initials).a("userId", "").a("providerId", "None"))
            }
            w2.close("p188:authorLst")
            x.pkg.xmlPart("ppt/authors.xml", ctAuthorsModern, w2.finish())
            _ = pres.rels.add(rtAuthorsModern, "authors.xml", false)
        }

        // Presentation-level parts.
        let theme1 = "theme/theme1.xml"
        _ = pres.rels.add("theme", theme1, false)
        _ = pres.rels.add("presProps", "presProps.xml", false)
        _ = pres.rels.add("viewProps", "viewProps.xml", false)
        _ = pres.rels.add("tableStyles", "tableStyles.xml", false)
        x.pkg.xmlPart("ppt/presProps.xml", ctPresProps, presPropsXML(p))
        x.pkg.xmlPart("ppt/viewProps.xml", ctViewProps, viewPropsXML(p))
        let ts = Tables.tableStylesXML(x.tableStyles, p.tableStyles)
        x.pkg.xmlPart("ppt/tableStyles.xml", ctTableStyles, ts)
        let pxml = presentationXML(x, pres, masterRids, notesMasterRid, handoutRid, slideRids)
        x.pkg.xmlPart("ppt/presentation.xml", mainCT, pxml)
        // Kept parts never replace a part the writer makes.
        let kept = p.keptParts.filter { k in
            let n = rustASCIILowercase(k.name)
            return !n.isEmpty
                && !utf8Contains(n, "..")
                && !hasBytePrefix(n, "ppt/")
                && !hasBytePrefix(n, "docprops/core")
                && !hasBytePrefix(n, "docprops/app")
                && !hasBytePrefix(n, "[content_types]")
                && !bytesEqual(n, "_rels/.rels")
        }
        for k in kept where !k.relType.isEmpty && !k.fromRoot {
            _ = pres.rels.addNew(k.relType, OPC.relative("ppt/presentation.xml", k.name), false)
        }
        x.pkg.rels("ppt/presentation.xml", pres.rels)
        for k in kept {
            if k.contentType.isEmpty {
                x.pkg.raw(k.name, Array(k.xml.utf8))
            } else {
                x.pkg.xmlPart(k.name, k.contentType, Array(k.xml.utf8))
            }
        }

        // Document properties and package relationships.
        x.pkg.xmlPart("docProps/core.xml", ctCore, coreXML(p))
        x.pkg.xmlPart("docProps/app.xml", ctApp, appXML(p))
        var root = RelsOut()
        _ = root.add("officeDocument", "ppt/presentation.xml", false)
        _ = root.add(OPC.rtCore, "docProps/core.xml", false)
        _ = root.add("extended-properties", "docProps/app.xml", false)
        for k in kept where !k.relType.isEmpty && k.fromRoot {
            _ = root.addNew(k.relType, k.name, false)
        }
        x.pkg.rels("", root)
        return try x.pkg.finish()
    }

    static func layoutXML(_ x: Exp, _ o: Out, _ l: Layout) -> [UInt8] {
        var w = W.new()
        rootOpen(
            &w,
            "p:sldLayout",
            A.new().o("showMasterSp", !l.showMasterShapes ? "0" : nil).a("type", l.kind.xml).t("preserve", l.preserve)
        )
        _ = cSld(&w, x, o, l.name, l.background, l.shapes, [])
        clrMapOvr(&w, l.colorMap)
        extList(&w, extChildren(l.rawExt))
        w.close("p:sldLayout")
        return w.finish()
    }

    static func masterXML(_ x: Exp, _ o: Out, _ m: Master, _ layouts: [(UInt64, String)]) -> [UInt8] {
        var w = W.new()
        rootOpen(&w, "p:sldMaster", A.new().t("preserve", m.preserve))
        _ = cSld(&w, x, o, m.name, m.background, m.shapes, [])
        clrMap(&w, m.colorMap)
        w.open0("p:sldLayoutIdLst")
        for (id, rid) in layouts {
            w.empty("p:sldLayoutId", A.new().a("id", id).a("r:id", rid))
        }
        w.close("p:sldLayoutIdLst")
        w.open0("p:txStyles")
        let (dt, db, dother) = masterStyles()
        func pick(_ s: ListStyle, _ d: ListStyle) -> ListStyle { s.isEmpty ? d : s }
        DML.listStyle(&w, x, o, "p:titleStyle", pick(m.titleStyle, dt))
        DML.listStyle(&w, x, o, "p:bodyStyle", pick(m.bodyStyle, db))
        DML.listStyle(&w, x, o, "p:otherStyle", pick(m.otherStyle, dother))
        w.close("p:txStyles")
        extList(&w, extChildren(m.rawExt))
        w.close("p:sldMaster")
        return w.finish()
    }

    static func slideXML(_ x: Exp, _ o: Out, _ s: Slide, _ commentRel: String?) -> [UInt8] {
        var w = W.new()
        rootOpen(&w, "p:sld", A.new().o("showMasterSp", !s.showMasterShapes ? "0" : nil).o("show", s.hidden ? "0" : nil))
        let ids = cSld(&w, x, o, s.name, s.background, s.shapes, s.tags)
        clrMapOvr(&w, s.colorMap)
        if let t = s.transition {
            Timing.transition(&w, x, o, t)
        }
        if !s.animations.isEmpty {
            Timing.timing(&w, x, s.animations, s.shapes, ids)
        }
        slideExtList(&w, s.rawExt, commentRel)
        w.close("p:sld")
        return w.finish()
    }

    static func notesXML(_ x: Exp, _ o: Out, _ notes: TextBody) -> [UInt8] {
        var w = W.new()
        rootOpen(&w, "p:notes", A.new())
        var img = Shape.default
        img.id = ShapeId(2)
        img.name = "Slide Image Placeholder 1"
        img.ph = Placeholder(kind: .slideImage)
        var tb = notes
        tb.body = BodyProps()
        var body = Shape.default
        body.id = ShapeId(3)
        body.name = "Notes Placeholder 2"
        body.ph = Placeholder(kind: .body, idx: 1)
        body.text = tb
        _ = cSld(&w, x, o, "", nil, [img, body], [])
        w.open0("p:clrMapOvr")
        w.empty0("a:masterClrMapping")
        w.close("p:clrMapOvr")
        w.close("p:notes")
        return w.finish()
    }

    /// The shared comment-author buckets: (name, initials, last index), and the name → slot map.
    struct Authors {
        var list: [(name: String, initials: String, last: UInt32)] = []
        var map: [ByteKey: Int] = [:]
    }

    static func commentsXML(_ list: [Comment], _ authors: inout Authors) -> [UInt8] {
        var w = W.new()
        rootOpen(&w, "p:cmLst", A.new())
        var flat: [Comment] = []
        for c in list.prefix(10_000) {
            flat.append(c)
            for r in c.replies.prefix(1000) {
                flat.append(r)
            }
        }
        for c in flat {
            let ai = authorSlot(c, &authors)
            var idx: UInt32 = 1
            if authors.list.indices.contains(ai) {
                authors.list[ai].last &+= 1
                idx = authors.list[ai].last
            }
            let dt = validDate(c.date) ? c.date : "2024-01-01T00:00:00.000"
            w.open("p:cm", A.new().a("authorId", ai).a("dt", dt).a("idx", idx))
            func pos(_ v: Double) -> Int64 { v.isFinite ? Int64(rustCast: (v * 8.0).rounded().clamped(0.0, 1.0e9)) : 0 }
            w.empty("p:pos", A.new().a("x", pos(c.x)).a("y", pos(c.y)))
            w.elt("p:text", c.text)
            w.close("p:cm")
        }
        w.close("p:cmLst")
        return w.finish()
    }

    /// The author's slot in the shared bucket list, adding them on first use. Legacy parts index the
    /// list by number, the modern authors part gives every slot a GUID.
    static func authorSlot(_ c: Comment, _ authors: inout Authors) -> Int {
        let author = c.author.isEmpty ? "Author" : c.author
        if let i = authors.map[ByteKey(author)] {
            return i
        }
        let ini: String
        if c.initials.isEmpty {
            var v = String.UnicodeScalarView()
            for ch in author.unicodeScalars where ch.properties.isAlphabetic {
                if v.count == 2 { break }
                v.append(ch)
            }
            ini = String(v)
        } else {
            ini = c.initials
        }
        let idx = authors.list.count
        authors.list.append((author, ini, 0))
        authors.map[ByteKey(author)] = idx
        return idx
    }

    /// The modern (p188) threaded-comment part: replies nest and the resolved state is kept, which
    /// the flattened legacy part cannot express (issue #70).
    static func modernCommentsXML(_ list: [Comment], _ part: String, _ authors: inout Authors) -> [UInt8] {
        var w = W.new()
        w.open("p188:cmLst", A.new().a("xmlns:p188", OPC.nsP188).a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR))
        for (ti, c) in list.prefix(10_000).enumerated() {
            modernComment(&w, c, part, ti, &authors, 0)
        }
        w.close("p188:cmLst")
        return w.finish()
    }

    static func modernComment(_ w: inout W, _ c: Comment, _ part: String, _ ti: Int, _ authors: inout Authors, _ depth: Int) {
        let ai = authorSlot(c, &authors)
        let author = authors.list.at(ai)?.name ?? ""
        let dt = validDate(c.date) ? c.date : "2024-01-01T00:00:00.000"
        var a = A.new().a("id", Tables.guid("deckcraft-comment:\(part):\(ti)")).a("authorId", authorGUID(author)).a("created", dt)
        if c.resolved {
            a = a.a("status", "resolved")
        }
        w.open("p188:cm", a)
        w.empty0("p188:unknownAnchor")
        func emu(_ v: Double) -> Int64 { v.isFinite ? Int64(rustCast: (v * 12_700.0).rounded().clamped(0.0, 1.0e9)) : 0 }
        w.empty("p188:pos", A.new().a("x", emu(c.x)).a("y", emu(c.y)))
        if depth < 4 && !c.replies.isEmpty {
            w.open0("p188:replyLst")
            for (ri, r) in c.replies.prefix(1000).enumerated() {
                let riAi = authorSlot(r, &authors)
                let rAuthor = authors.list.at(riAi)?.name ?? ""
                let rdt = validDate(r.date) ? r.date : "2024-01-01T00:00:00.000"
                var ra = A.new()
                    .a("id", Tables.guid("deckcraft-comment:\(part):\(ti):\(ri)"))
                    .a("authorId", authorGUID(rAuthor))
                    .a("created", rdt)
                if r.resolved {
                    ra = ra.a("status", "resolved")
                }
                w.open("p188:reply", ra)
                txBody(&w, r.text)
                w.close("p188:reply")
            }
            w.close("p188:replyLst")
        }
        txBody(&w, c.text)
        w.close("p188:cm")
    }

    /// An `a:txBody` with one paragraph per line, the shape the reader re-joins with `\n`.
    static func txBody(_ w: inout W, _ text: String) {
        w.open0("p188:txBody")
        w.empty0("a:bodyPr")
        for line in splitScalars(text, ["\n"]) {
            w.open0("a:p")
            w.open0("a:r")
            w.empty("a:rPr", A.new().a("lang", "en-US"))
            w.elt("a:t", line)
            w.close("a:r")
            w.close("a:p")
        }
        w.close("p188:txBody")
    }

    /// The modern author id for a name: the same GUID the authors part writes.
    static func authorGUID(_ name: String) -> String {
        Tables.guid("deckcraft-comment-author:\(name)")
    }

    /// Sections with every slide in exactly one section, in slide order.
    static func sectionSlides(_ p: Presentation) -> [(String, [Int])] {
        var out: [(String, [Int])] = p.sections.map { ($0.name, []) }
        if out.isEmpty {
            return out
        }
        var cur = 0
        for (i, s) in p.slides.enumerated() {
            if let k = p.sections.firstIndex(where: { $0.slides.contains(s.id) }), k >= cur {
                cur = k
            }
            if out.indices.contains(cur) {
                out[cur].1.append(i)
            }
        }
        return out
    }

    /// One embedded typeface, with the relationship id of each face that had bytes.
    struct WrittenFont {
        var typeface: String
        var panose: String?
        var pitchFamily: UInt8?
        var charset: UInt8?
        var regular: String?
        var bold: String?
        var italic: String?
        var boldItalic: String?

        var any: Bool { regular != nil || bold != nil || italic != nil || boldItalic != nil }
    }

    /// Font parts for `p:embeddedFontLst`. One part per distinct media item, named `ppt/fonts/fontN.fntdata`.
    static func writeEmbeddedFonts(_ x: Exp, _ o: Out) -> [WrittenFont] {
        struct Plan {
            var typeface: String
            var panose: String?
            var pitchFamily: UInt8?
            var charset: UInt8?
            var regular: MediaId?
            var bold: MediaId?
            var italic: MediaId?
            var boldItalic: MediaId?
        }
        var plans: [Plan] = []
        for font in x.p.embeddedFonts.prefix(64) {
            let typeface = rustTrim(font.typeface)
            if typeface.isEmpty {
                continue
            }
            plans.append(Plan(
                typeface: String(String.UnicodeScalarView(typeface.unicodeScalars.prefix(255))),
                panose: font.panose.flatMap { s in s.utf8.count == 20 && s.unicodeScalars.allSatisfy(isASCIIHexScalar) ? s : nil },
                pitchFamily: font.pitchFamily,
                charset: font.charset,
                regular: font.regular,
                bold: font.bold,
                italic: font.italic,
                boldItalic: font.boldItalic
            ))
        }
        var seenPart: [MediaId: String] = [:]
        var n: UInt32 = 0
        func rel(_ id: MediaId?) -> String? {
            guard let id else { return nil }
            if let rid = seenPart[id] {
                return rid
            }
            guard let m = x.p.media(id) else { return nil }
            if m.data.isEmpty || m.data.count > 32 * 1024 * 1024 {
                return nil
            }
            n = n == UInt32.max ? n : n + 1
            let name = "ppt/fonts/font\(n).fntdata"
            x.pkg.binary(name, "application/x-fontdata", m.data)
            let rid = o.rels.add("font", OPC.relative("ppt/presentation.xml", name), false)
            seenPart[id] = rid
            return rid
        }
        var seenFace: [String] = []
        var out: [WrittenFont] = []
        for font in plans {
            let regular = rel(font.regular)
            let bold = rel(font.bold)
            let italic = rel(font.italic)
            let boldItalic = rel(font.boldItalic)
            let written = WrittenFont(
                typeface: font.typeface, panose: font.panose, pitchFamily: font.pitchFamily, charset: font.charset,
                regular: regular, bold: bold, italic: italic, boldItalic: boldItalic
            )
            if written.any && !seenFace.contains(where: { bytesEqual($0, written.typeface) }) {
                seenFace.append(written.typeface)
                out.append(written)
            }
        }
        return out
    }

    static func presentationXML(_ x: Exp, _ o: Out, _ masters: [(UInt64, String)], _ notes: String?, _ handout: String?, _ slides: [String]) -> [UInt8] {
        let fonts = writeEmbeddedFonts(x, o)
        let p = x.p
        var w = W.new()
        let first: UInt32? = p.firstSlideNumber != 1 ? Swift.min(p.firstSlideNumber, 9999) : nil
        rootOpen(&w, "p:presentation", A.new().a("saveSubsetFonts", 1).t("embedTrueTypeFonts", !fonts.isEmpty).o("firstSlideNum", first))
        w.open0("p:sldMasterIdLst")
        for (id, rid) in masters {
            w.empty("p:sldMasterId", A.new().a("id", id).a("r:id", rid))
        }
        w.close("p:sldMasterIdLst")
        if let n = notes {
            w.open0("p:notesMasterIdLst")
            w.empty("p:notesMasterId", A.new().a("r:id", n))
            w.close("p:notesMasterIdLst")
        }
        if let h = handout {
            w.open0("p:handoutMasterIdLst")
            w.empty("p:handoutMasterId", A.new().a("r:id", h))
            w.close("p:handoutMasterIdLst")
        }
        if !slides.isEmpty {
            w.open0("p:sldIdLst")
            for (i, rid) in slides.enumerated() {
                w.empty("p:sldId", A.new().a("id", 256 + i).a("r:id", rid))
            }
            w.close("p:sldIdLst")
        }
        func clamp(_ v: Double) -> Int64 { Swift.min(Swift.max(DML.emu(v), 914_400), 51_206_400) }
        w.empty("p:sldSz", A.new().a("cx", clamp(p.slideSize.width)).a("cy", clamp(p.slideSize.height)))
        w.empty("p:notesSz", A.new().a("cx", Swift.max(DML.emuPos(p.notesSize.width), 1)).a("cy", Swift.max(DML.emuPos(p.notesSize.height), 1)))
        if !fonts.isEmpty {
            w.open0("p:embeddedFontLst")
            for f in fonts {
                w.open0("p:embeddedFont")
                w.empty(
                    "p:font",
                    A.new().a("typeface", f.typeface).o("panose", f.panose).o("pitchFamily", f.pitchFamily).o("charset", f.charset)
                )
                for (tag, rid) in [("p:regular", f.regular), ("p:bold", f.bold), ("p:italic", f.italic), ("p:boldItalic", f.boldItalic)] {
                    if let rid {
                        w.empty(tag, A.new().a("r:id", rid))
                    }
                }
                w.close("p:embeddedFont")
            }
            w.close("p:embeddedFontLst")
        }
        if !p.customShows.isEmpty {
            w.open0("p:custShowLst")
            for (i, cs) in p.customShows.enumerated() {
                w.open("p:custShow", A.new().a("name", cs.name).a("id", i))
                w.open0("p:sldLst")
                for sid in cs.slides {
                    if let part = x.slideParts[sid] {
                        let rid = o.rels.add("slide", OPC.relative("ppt/presentation.xml", part), false)
                        w.empty("p:sld", A.new().a("r:id", rid))
                    }
                }
                w.close("p:sldLst")
                w.close("p:custShow")
            }
            w.close("p:custShowLst")
        }
        custData(&w, x, o, p.tags)
        let dts = p.defaultTextStyle.isEmpty ? defaultTextStyle() : p.defaultTextStyle
        DML.listStyle(&w, x, o, "p:defaultTextStyle", dts)
        let sections = sectionSlides(p)
        let raw = p.rawExt.flatMap { rustTrim($0).isEmpty ? nil : $0 }
        if !sections.isEmpty || raw != nil {
            var inner = W.frag()
            if !sections.isEmpty {
                inner.open("p:ext", A.new().a("uri", PPTX.sectionExtURI))
                inner.open("p14:sectionLst", A.new().a("xmlns:p14", OPC.nsP14))
                for (i, (name, list)) in sections.enumerated() {
                    inner.open("p14:section", A.new().a("name", name).a("id", Tables.guid("section:\(i):\(name)")))
                    inner.open0("p14:sldIdLst")
                    for si in list {
                        inner.empty("p14:sldId", A.new().a("id", 256 + si))
                    }
                    inner.close("p14:sldIdLst")
                    inner.close("p14:section")
                }
                inner.close("p14:sectionLst")
                inner.close("p:ext")
            }
            if let r = raw {
                inner.raw(r)
            }
            extList(&w, inner.s)
        }
        w.close("p:presentation")
        return w.finish()
    }

    static func presPropsXML(_ p: Presentation) -> [UInt8] {
        let s = p.show
        var w = W.new()
        rootOpen(&w, "p:presentationPr", A.new())
        w.open(
            "p:showPr",
            A.new()
                .t("loop", s.loopUntilEsc)
                .a("showNarration", s.withoutNarration ? 0 : 1)
                .o("showAnimation", s.withoutAnimation ? "0" : nil)
                .o("useTimings", !s.useTimings ? "0" : nil)
        )
        switch s.showType {
        case "browsed": w.empty("p:browse", A.new())
        case "kiosk": w.empty("p:kiosk", A.new())
        default: w.empty0("p:present")
        }
        let custom = s.customShow.flatMap { n in p.customShows.firstIndex { bytesEqual($0.name, n) } }
        if let i = custom {
            w.empty("p:custShow", A.new().a("id", i))
        } else if let r = s.range {
            w.empty("p:sldRg", A.new().a("st", Swift.max(r.a, 1)).a("end", Swift.max(Swift.max(r.b, r.a), 1)))
        } else {
            w.empty0("p:sldAll")
        }
        w.open0("p:penClr")
        w.val("a:srgbClr", s.penColor.hex)
        w.close("p:penClr")
        w.close("p:showPr")
        w.close("p:presentationPr")
        return w.finish()
    }

    static func viewPropsXML(_ p: Presentation) -> [UInt8] {
        var w = W.new()
        rootOpen(&w, "p:viewPr", A.new())
        w.open0("p:normalViewPr")
        w.empty("p:restoredLeft", A.new().a("sz", 15620))
        w.empty("p:restoredTop", A.new().a("sz", 94660))
        w.close("p:normalViewPr")
        if !p.guides.isEmpty {
            // Drawing guides; `pos` is in eighths of a point (576 per inch).
            w.open0("p:slideViewPr")
            w.open0("p:cSldViewPr")
            w.open0("p:cViewPr")
            w.open0("p:scale")
            w.empty("a:sx", A.new().a("n", 100).a("d", 100))
            w.empty("a:sy", A.new().a("n", 100).a("d", 100))
            w.close("p:scale")
            w.empty("p:origin", A.new().a("x", 0).a("y", 0))
            w.close("p:cViewPr")
            w.open0("p:guideLst")
            for g in p.guides.prefix(1000) {
                let pos = Int64(rustCast: (g.pos * 8.0).rounded().clamped(-1.0e9, 1.0e9))
                let a = g.vertical ? A.new().a("pos", pos) : A.new().a("orient", "horz").a("pos", pos)
                w.empty("p:guide", a)
            }
            w.close("p:guideLst")
            w.close("p:cSldViewPr")
            w.close("p:slideViewPr")
        }
        w.empty("p:gridSpacing", A.new().a("cx", 76200).a("cy", 76200))
        w.close("p:viewPr")
        return w.finish()
    }

    static func coreXML(_ p: Presentation) -> [UInt8] {
        let pr = p.props
        var w = W.new()
        w.open(
            "cp:coreProperties",
            A.new()
                .a("xmlns:cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties")
                .a("xmlns:dc", "http://purl.org/dc/elements/1.1/")
                .a("xmlns:dcterms", "http://purl.org/dc/terms/")
                .a("xmlns:dcmitype", "http://purl.org/dc/dcmitype/")
                .a("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
        )
        for (tag, v) in [
            ("dc:title", pr.title),
            ("dc:subject", pr.subject),
            ("dc:creator", pr.author),
            ("cp:keywords", pr.keywords),
            ("dc:description", pr.comments),
            ("cp:category", pr.category),
            ("cp:lastModifiedBy", pr.lastModifiedBy),
        ] where !v.isEmpty {
            w.elt(tag, v)
        }
        if pr.revision > 0 {
            w.elt("cp:revision", String(pr.revision))
        }
        for (tag, v) in [("dcterms:created", pr.created), ("dcterms:modified", pr.modified)] where validDate(v) {
            w.open(tag, A.new().a("xsi:type", "dcterms:W3CDTF"))
            w.text(v)
            w.close(tag)
        }
        w.close("cp:coreProperties")
        return w.finish()
    }

    static func appXML(_ p: Presentation) -> [UInt8] {
        var w = W.new()
        w.open(
            "Properties",
            A.new()
                .a("xmlns", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")
                .a("xmlns:vt", "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes")
        )
        w.elt("Application", "DeckCraft")
        w.elt("Slides", String(p.slides.count))
        w.elt("Notes", String(p.slides.filter { !$0.notes.isEmpty }.count))
        w.elt("HiddenSlides", String(p.slides.filter(\.hidden).count))
        if !p.props.company.isEmpty {
            w.elt("Company", p.props.company)
        }
        w.close("Properties")
        return w.finish()
    }

    // MARK: - Rust string and number semantics the writer needs

    /// `s.chars().all(|c| c.is_ascii_alphanumeric())`.
    static func isASCIIAlnum(_ s: some StringProtocol) -> Bool {
        s.unicodeScalars.allSatisfy(isASCIIAlnumScalar)
    }

    static func isASCIIAlnumScalar(_ c: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(c) || ("A" ... "Z").contains(c) || ("a" ... "z").contains(c)
    }

    static func isASCIIHexScalar(_ c: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(c) || ("A" ... "F").contains(c) || ("a" ... "f").contains(c)
    }

    /// `str::split` on a set of characters: every piece, empty ones included.
    static func splitScalars(_ s: String, _ seps: Set<Unicode.Scalar>) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if seps.contains(c) {
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(c)
            }
        }
        out.append(String(cur))
        return out
    }

    /// `str::rsplit_once(sep)`.
    static func rsplitOnce(_ s: some StringProtocol, _ sep: Unicode.Scalar) -> (String, String)? {
        let v = s.unicodeScalars
        guard let i = v.lastIndex(of: sep) else { return nil }
        return (String(String.UnicodeScalarView(v[..<i])), String(String.UnicodeScalarView(v[v.index(after: i)...])))
    }

    /// `str::contains(&str)`, byte for byte.
    static func utf8Contains(_ hay: String, _ needle: String) -> Bool {
        let h = Array(hay.utf8), n = Array(needle.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        for i in 0 ... (h.count - n.count) where h[i] == n[0] {
            if h[i ..< i + n.count].elementsEqual(n) { return true }
        }
        return false
    }

    /// `str::get(lo..hi)`: the bytes `lo..<hi` when both ends are in range and on character boundaries.
    static func byteSlice(_ s: String, _ lo: Int, _ hi: Int) -> String? {
        let u = s.utf8
        guard lo <= hi, hi <= u.count else { return nil }
        let a = u.index(u.startIndex, offsetBy: lo), b = u.index(u.startIndex, offsetBy: hi)
        guard let sa = a.samePosition(in: s.unicodeScalars), let sb = b.samePosition(in: s.unicodeScalars) else { return nil }
        return String(s.unicodeScalars[sa ..< sb])
    }

    /// An element of a fixed four-element array (`[f64; 4]` in Rust), 0 when the model holds fewer.
    static func at4(_ v: [Double], _ i: Int) -> Double {
        v.at(i) ?? 0.0
    }

    /// `f64::rem_euclid`.
    static func remEuclid(_ v: Double, _ rhs: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: rhs)
        return r < 0.0 ? r + Swift.abs(rhs) : r
    }

    /// `u32::saturating_add`.
    static func satAdd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? UInt32.max : r
    }

    /// `u32::saturating_mul`.
    static func satMul(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        return o ? UInt32.max : r
    }
}
