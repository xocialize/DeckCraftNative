// DCPPTX — PPTX import: package → `Presentation`. Port of deckcraft crates/pptx/src/read/mod.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The reader is lenient: unknown parts are skipped, malformed parts are logged (`PPTXLog.warn`) and
// ignored, and every size and depth is bounded. Rust's `read::` module becomes the caseless enum
// `PPTXRead`; `Imp` (import state shared by every part) is a class, as Rust passes it `&mut` everywhere.
// Maps that Rust keys by `String` are keyed by `ByteKey` here, so part names compare byte for byte.
import DCColor
import DCCore
import DCGeometry
import DCModel

extension PPTX {
    /// Read a `.pptx` / `.potx` / `.ppsx` package.
    public static func `import`(_ bytes: [UInt8]) throws(PPTXError) -> Presentation {
        try onLargeStack { () throws(PPTXError) in try PPTXRead.importChecked(bytes).0 }
    }

    /// `import`, plus the part names of slides the file lists but that couldn't be read and were left
    /// out.
    public static func importChecked(_ bytes: [UInt8]) throws(PPTXError) -> (Presentation, [String]) {
        try onLargeStack { () throws(PPTXError) in try PPTXRead.importChecked(bytes) }
    }

    /// Read the theme of a `.thmx` file, or of a `.pptx` / `.potx`'s first master, with its media.
    public static func importTheme(_ bytes: [UInt8]) throws(PPTXError) -> (Theme, [MediaItem]) {
        try PPTXRead.importTheme(bytes)
    }
}

/// The `read` module.
enum PPTXRead {
    // MARK: - Import state

    /// Import state shared by all parts (`Imp`).
    final class Imp {
        let pkg: Package
        var media: [MediaItem] = []
        var mediaByPart: [ByteKey: MediaId] = [:]
        var next: UInt32 = 0
        var slideByPart: [ByteKey: SlideId] = [:]
        var customShowNames: [ByteKey: String] = [:]
        /// GUIDs (upper case) of the table styles the file defines.
        var tableStyleIds: [String] = []
        /// Per legacy VML drawing part: shape id → preview picture part (see `vmlPreview`).
        var vmlPreviews: [ByteKey: [ByteKey: String]] = [:]
        /// Aggregate byte count of retained chart sidecars across the presentation.
        var keptSidecarBytes = 0
        /// Cached kept sidecars by normalized chart part name.
        var keptCharts: [ByteKey: ChartKept] = [:]

        init(pkg: Package, next: UInt32 = 0) {
            self.pkg = pkg
            self.next = next
        }

        func alloc() -> UInt32 {
            next = PPTXRead.satAdd(next, 1)
            return next
        }

        /// Media item for an internal part, read once.
        func mediaFor(_ part: String) -> MediaId? {
            let key = ByteKey(OPC.norm(part))
            if let m = mediaByPart[key] { return m }
            guard let data = pkg.get(part) else { return nil }
            let name = OPC.fileOf(pkg.originalName(part) ?? part)
            let contentType = pkg.contentType(part).flatMap { $0.isEmpty ? nil : $0 } ?? mimeFor(name)
            let id = MediaId(alloc())
            media.append(MediaItem(id: id, name: name, contentType: contentType, data: data, link: nil))
            mediaByPart[key] = id
            return id
        }

        /// Media item for an external link.
        func mediaLink(_ url: String) -> MediaId {
            if let m = media.first(where: { $0.link.map { bytesEqual($0, url) } ?? false }) { return m.id }
            let id = MediaId(alloc())
            let name: String
            if let slash = url.utf8.lastIndex(of: UInt8(ascii: "/")) {
                name = String(url[url.utf8.index(after: slash)...])
            } else {
                name = url
            }
            media.append(MediaItem(id: id, name: name, contentType: mimeFor(name), data: [], link: url))
            return id
        }
    }

    /// One part being read: its name, relationships and root namespace declarations.
    struct Part {
        var name: String
        var rels: Rels
        var ns: [(key: String, value: String)]
        /// Prefixes bound below the root only (on a wrapper such as `mc:Choice`), each to one namespace.
        var innerNs: [(key: String, value: String)]

        init(_ pkg: Package, _ name: String, _ doc: XMLDoc) {
            let ns = doc.nsDecls()
            self.name = name
            self.rels = pkg.rels(name)
            self.innerNs = PPTXRead.innerDecls(doc.root, ns)
            self.ns = ns
        }

        /// Serialize an element with the namespace declarations it needs from the part root.
        func keep(_ el: XMLEl) -> String {
            PPTXRead.keepXML(el, ns)
        }

        /// Like `keep`, also declaring prefixes that only an enclosing wrapper binds.
        func keepInner(_ el: XMLEl) -> String {
            PPTXRead.keepXML(el, ns + innerNs)
        }
    }

    /// Prefixes declared below the root but not on it, skipping any bound to different namespaces.
    static func innerDecls(_ root: XMLEl, _ ns: [(key: String, value: String)]) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        var outMap: [ByteKey: String] = [:]
        var clash = Set<ByteKey>()
        func rec(_ e: XMLEl, _ depth: Int) {
            if depth > XML.maxDepth { return }
            for (k, v) in e.attrs where hasBytePrefix(k, "xmlns:") {
                if let existing = outMap[ByteKey(k)] {
                    if !bytesEqual(existing, v) { clash.insert(ByteKey(k)) }
                } else if out.count < 1000 {
                    outMap[ByteKey(k)] = v
                    out.append((k, v))
                }
            }
            for c in e.elements { rec(c, depth + 1) }
        }
        let rootNs = Set(ns.map { ByteKey($0.key) })
        for c in root.elements { rec(c, 1) }
        return out.filter { !clash.contains(ByteKey($0.key)) && !rootNs.contains(ByteKey($0.key)) }
    }

    /// Serialize `el`, declaring every prefix it uses that the source root declared.
    static func keepXML(_ el: XMLEl, _ ns: [(key: String, value: String)]) -> String {
        var used = Set<ByteKey>()
        func rec(_ e: XMLEl, _ depth: Int) {
            if depth > XML.maxDepth { return }
            if let p = splitOnce(e.name, ":") { used.insert(ByteKey(String(p.0))) }
            for (k, _) in e.attrs {
                if let p = splitOnce(k, ":"), !bytesEqual(p.0, "xmlns"), !bytesEqual(p.0, "xml") {
                    used.insert(ByteKey(String(p.0)))
                }
            }
            for c in e.elements { rec(c, depth + 1) }
        }
        rec(el, 0)
        var el = el
        for (k, v) in ns {
            let p = stripBytePrefix(k, "xmlns:").map(String.init) ?? ""
            if !p.isEmpty && used.contains(ByteKey(p)) && !el.attrs.contains(where: { bytesEqual($0.key, k) }) {
                el.attrs.append((k, v))
            }
        }
        return el.toXML()
    }

    // MARK: - Markup compatibility

    /// Namespace prefixes whose `mc:Choice` content we understand.
    static let supportedMC = ["p14", "p15", "p159", "a14", "a16", "p1510", "a15", "c14", "p188", "cx1"]

    /// Office 2016 charts sit in a `cx1` choice; take it only for a layout DeckCraft reads (the
    /// fallback is a picture or "this chart isn't available" text). The part is checked later, when
    /// the frame is read, so here only the namespace counts.
    static func chartexReadable(_ ch: XMLEl) -> Bool {
        ch.findAll("graphicData").contains { g in g.attr("uri").map { hasByteSuffix($0, "/chartex") } ?? false }
    }

    /// A relationship to an embedded 3-D model (`.glb`).
    static func isModel3d(_ rel: Rel) -> Bool {
        !rel.external && (bytesEqual(rel.kind, "model3d") || hasByteSuffix(rustASCIILowercase(rel.target), ".glb"))
    }

    static func choiceHasModel3d(_ el: XMLEl, _ rels: Rels) -> Bool {
        func rec(_ el: XMLEl, _ depth: Int) -> Bool {
            if depth > 16 { return false }
            if el.is("contentPart"), let id = el.attr("r:id"), !id.isEmpty, let r = rels.get(id), isModel3d(r) {
                return true
            }
            return el.elements.contains { rec($0, depth + 1) }
        }
        return rec(el, 0)
    }

    /// Replace every `mc:AlternateContent` by the children of the branch we can read best.
    /// A 3-D model choice is left in place (even when its `Requires` prefix is not one we otherwise
    /// understand) so the shape reader can keep the model and its fallback picture. Ink content parts
    /// still fall through to the fallback picture.
    static func resolveMC(_ el: inout XMLEl, _ depth: Int) {
        resolveMCRels(&el, depth, nil)
    }

    static func resolveMCRels(_ el: inout XMLEl, _ depth: Int, _ rels: Rels?) {
        if depth > XML.maxDepth { return }
        let hasAC = el.children.contains { if case .el(let e) = $0 { return e.is("AlternateContent") }; return false }
        if hasAC {
            var out: [XMLNode] = []
            out.reserveCapacity(el.children.count)
            let children = el.children
            el.children = []
            for c in children {
                guard case .el(let ac) = c, ac.is("AlternateContent") else {
                    out.append(c)
                    continue
                }
                if let rels, ac.childrenNamed("Choice").contains(where: { choiceHasModel3d($0, rels) }) {
                    out.append(.el(ac))
                    continue
                }
                let choice = ac.childrenNamed("Choice").first { ch in
                    let req = ch.attr("Requires") ?? ""
                    let reqOK = splitWhitespace(req).allSatisfy { r in supportedMC.contains { bytesEqual($0, r) } }
                    // Ink content parts are not modelled; prefer their fallback picture.
                    let modelled = !ch.elements.contains { $0.is("contentPart") } && (!bytesContains(req, "cx1") || chartexReadable(ch))
                    return reqOK && modelled
                }
                guard let b = choice ?? ac.child("Fallback") else { continue }
                for case .el(var e) in b.children {
                    // Carry namespace declarations from the branch onto its content.
                    for (k, v) in b.attrs + ac.attrs where hasBytePrefix(k, "xmlns") && !e.attrs.contains(where: { bytesEqual($0.key, k) }) {
                        e.attrs.append((k, v))
                    }
                    out.append(.el(e))
                }
            }
            el.children = out
        }
        el.elementsMut { c in resolveMCRels(&c, depth + 1, rels) }
    }

    static func load(_ pkg: Package, _ name: String) -> XMLDoc? {
        guard var d = pkg.xml(name) else { return nil }
        let rels = pkg.rels(name)
        resolveMCRels(&d.root, 0, rels)
        return d
    }

    static func maxCNvPr(_ el: XMLEl, _ m: inout UInt32) {
        for c in el.findAll("cNvPr") {
            if let id = c.u32("id"), id < maxKeptId { m = Swift.max(m, id) }
        }
    }

    // MARK: - Tags and kept parts

    /// Add-in tags named by `holder`'s `p:custDataLst`: the name/value pairs of each tags part.
    static func tags(_ imp: Imp, _ part: Part, _ holder: XMLEl) -> [Pair<String, String>] {
        guard let list = holder.child("custDataLst") else { return [] }
        var out: [Pair<String, String>] = []
        for t in list.childrenNamed("tags").prefix(100) {
            guard let id = t.attr("r:id"), let r = part.rels.get(id), let doc = imp.pkg.xml(r.target) else { continue }
            for tag in doc.root.childrenNamed("tag").prefix(10_000) {
                if let name = tag.attr("name") { out.append(Pair(name, tag.attr("val") ?? "")) }
            }
        }
        return out
    }

    /// Relationship types whose parts are kept verbatim, and whether they hang off the package root.
    static let keptRels: [(String, Bool)] = [
        ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml", false),
        ("http://schemas.microsoft.com/office/2020/02/relationships/classificationlabels", true),
        ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties", true),
    ]

    /// A part we may keep: outside `ppt/` and the properties the writer makes itself.
    static func keepable(_ name: String) -> Bool {
        let n = rustASCIILowercase(name)
        return !n.isEmpty
            && !bytesContains(n, "..")
            && !hasBytePrefix(n, "ppt/")
            && !bytesEqual(n, "docprops/core.xml")
            && !bytesEqual(n, "docprops/app.xml")
            && !hasBytePrefix(n, "[content_types]")
    }

    /// Custom XML data, sensitivity labels and custom properties, with the parts they relate to
    /// (`itemProps`) and their relationships parts, as written.
    static func keptParts(_ pkg: Package, _ presPath: String) -> [KeptPart] {
        var out: [KeptPart] = []
        func text(_ name: String) -> String? {
            pkg.get(name).flatMap { String(validating: $0, as: UTF8.self) }
        }
        for (holder, fromRoot) in [("", true), (presPath, false)] {
            guard let doc = pkg.xml(OPC.relsPath(holder)) else { continue }
            let base = OPC.dirOf(holder)
            for r in doc.root.childrenNamed("Relationship") {
                guard let ty = r.attr("Type"), let target = r.attr("Target") else { continue }
                if r.attr("TargetMode").map({ eqIgnoreASCIICase($0, "external") }) ?? false
                    || !keptRels.contains(where: { bytesEqual($0.0, ty) && $0.1 == fromRoot })
                {
                    continue
                }
                let name = OPC.resolve(base, target)
                if !keepable(name) || out.contains(where: { eqIgnoreASCIICase($0.name, name) }) || out.count >= 400 { continue }
                guard let xml = text(name) else { continue }
                out.append(KeptPart(name: name, contentType: pkg.contentType(name) ?? "", xml: xml, relType: ty, fromRoot: fromRoot))
                // The part's own relationships (customXml item → itemProps) and their targets.
                let rp = OPC.relsPath(name)
                if let relsXML = text(rp) {
                    for sub in pkg.rels(name).items where !sub.external && keepable(sub.target) {
                        if let x = text(sub.target), !out.contains(where: { eqIgnoreASCIICase($0.name, sub.target) }) {
                            out.append(KeptPart(name: sub.target, contentType: pkg.contentType(sub.target) ?? "", xml: x))
                        }
                    }
                    out.append(KeptPart(name: rp, xml: relsXML))
                }
            }
        }
        return out
    }

    // MARK: - Entry points

    static func newImp(_ pkg: Package, next: UInt32) -> Imp {
        Imp(pkg: pkg, next: next)
    }

    /// The theme of a `.thmx` theme file (its `officeDocument` is a theme part), or of the first
    /// master of a `.pptx` / `.potx`, with the media its format scheme uses (ids from 1).
    static func importTheme(_ bytes: [UInt8]) throws(PPTXError) -> (Theme, [MediaItem]) {
        let pkg = try Package.open(bytes)
        let target = pkg.rels("").firstOf("officeDocument")?.target
        let themePath: String
        if let t = target, pkg.xml(t).map({ $0.root.is("theme") }) ?? false {
            themePath = t
        } else {
            // A presentation: its first master's theme.
            let pres = target ?? "ppt/presentation.xml"
            guard let presDoc = load(pkg, pres) else { throw .notPptx("neither a theme nor a presentation") }
            let presPart = Part(pkg, pres, presDoc)
            let first = presDoc.root.child("sldMasterIdLst").flatMap { l in l.childrenNamed("sldMasterId").first { _ in true } }
            let master = first.flatMap { m in presPart.rels.target(m.attr("r:id") ?? "") }
                ?? presPart.rels.allOf("slideMaster").first?.target
            guard let master else { throw .notPptx("the presentation has no slide master") }
            guard let theme = pkg.rels(master).firstOf("theme")?.target else { throw .notPptx("the slide master has no theme") }
            themePath = theme
        }
        guard let doc = load(pkg, themePath) else { throw .notPptx("missing or unreadable \(themePath)") }
        if !doc.root.is("theme") { throw .notPptx("\(themePath) is not a theme part") }
        let imp = Imp(pkg: pkg)
        let part = Part(pkg, themePath, doc)
        let theme = readTheme(imp, part, doc.root)
        return (theme, imp.media)
    }

    /// `import`, plus the parts of the slide list the file names but that couldn't be read (a
    /// missing or truncated slide): those slides are left out, so a caller can say so (#203).
    static func importChecked(_ bytes: [UInt8]) throws(PPTXError) -> (Presentation, [String]) {
        var lostSlides: [String] = []
        let pkg = try Package.open(bytes)
        let rootRels = pkg.rels("")
        let presPath = rootRels.firstOf("officeDocument")?.target ?? "ppt/presentation.xml"
        guard let presDoc = load(pkg, presPath) else { throw .notPptx("missing or unreadable \(presPath)") }
        let presEl = presDoc.root
        if !presEl.is("presentation") { throw .notPptx("\(presPath) is not a presentation part") }
        let presPart = Part(pkg, presPath, presDoc)

        // Masters, layouts and slides to read.
        var masterPaths: [String] = presEl.child("sldMasterIdLst").map { l in
            l.childrenNamed("sldMasterId").compactMap { presPart.rels.target($0.attr("r:id") ?? "") }
        } ?? []
        if masterPaths.isEmpty { masterPaths = presPart.rels.allOf("slideMaster").map(\.target) }
        var slideEntries: [(UInt32, String)] = presEl.child("sldIdLst").map { l in
            l.childrenNamed("sldId").prefix(10_000).compactMap { s in
                guard let t = presPart.rels.target(s.attr("r:id") ?? "") else { return nil }
                return (s.u32("id") ?? 0, t)
            }
        } ?? []

        var docs: [ByteKey: XMLDoc] = [:]
        var maxId: UInt32 = 0
        var seenMasters = Set<ByteKey>()
        masterPaths = masterPaths.filter { seenMasters.insert(ByteKey(OPC.norm($0))).inserted }

        var allParts = masterPaths
        var seenLayouts = Set<ByteKey>()
        for m in masterPaths {
            for r in pkg.rels(m).allOf("slideLayout") where seenLayouts.insert(ByteKey(OPC.norm(r.target))).inserted {
                allParts.append(r.target)
            }
        }
        var seenSlides = Set<ByteKey>()
        slideEntries = slideEntries.filter { seenSlides.insert(ByteKey(OPC.norm($0.1))).inserted }
        allParts.append(contentsOf: slideEntries.map(\.1))
        for p in allParts {
            let key = ByteKey(OPC.norm(p))
            if docs[key] != nil { continue }
            if let d = load(pkg, p) {
                maxCNvPr(d.root, &maxId)
                docs[key] = d
            }
        }

        let imp = Imp(pkg: pkg, next: Swift.max(maxId, 1))
        // Slide ids first so hyperlinks anywhere can point at slides.
        var slideIds: [(UInt32, String, SlideId)] = []
        for (fileId, path) in slideEntries {
            if docs[ByteKey(OPC.norm(path))] == nil {
                PPTXLog.warn("pptx: slide \(path) is missing or unreadable; skipped")
                lostSlides.append(path)
                continue
            }
            let id = SlideId(imp.alloc())
            imp.slideByPart[ByteKey(OPC.norm(path))] = id
            slideIds.append((fileId, path, id))
        }
        if let l = presEl.child("custShowLst") {
            for cs in l.childrenNamed("custShow") {
                if let id = cs.attr("id"), let name = cs.attr("name") { imp.customShowNames[ByteKey(id)] = name }
            }
        }

        var p = blankPresentation(wideSlideSize, .default, false)
        p.masters.removeAll()
        p.media.removeAll()
        p.defaultTextStyle = .default

        if let sz = presEl.child("sldSz") {
            let w = sz.i64("cx").map(emuToPt) ?? 960.0
            let h = sz.i64("cy").map(emuToPt) ?? 540.0
            p.slideSize = Size(saneLen(w, 960.0), saneLen(h, 540.0))
        }
        if let sz = presEl.child("notesSz") {
            let w = sz.i64("cx").map(emuToPt) ?? 540.0
            let h = sz.i64("cy").map(emuToPt) ?? 720.0
            p.notesSize = Size(saneLen(w, 540.0), saneLen(h, 720.0))
        }
        p.firstSlideNumber = Swift.min(presEl.u32("firstSlideNum") ?? 1, 9999)
        if let dts = presEl.child("defaultTextStyle") {
            p.defaultTextStyle = listStyle(imp, presPart, dts)
        }
        if let r = presPart.rels.firstOf("tableStyles"), let d = load(pkg, r.target) {
            let part = Part(pkg, r.target, d)
            p.tableStyles = tableStyles(imp, part, d.root)
            imp.tableStyleIds = p.tableStyles.map(\.id)
        }

        // Masters and layouts.
        var layoutByPart: [ByteKey: LayoutId] = [:]
        for mp in masterPaths {
            guard let doc = docs[ByteKey(OPC.norm(mp))] else {
                PPTXLog.warn("pptx: master \(mp) missing; skipped")
                continue
            }
            let master = readMaster(imp, mp, doc, docs, &layoutByPart)
            p.masters.append(master)
        }
        if p.masters.isEmpty {
            PPTXLog.warn("pptx: no readable slide master; using a default one")
            let (m, _) = buildMaster(p.slideSize, .default, imp.next)
            imp.next = satAdd(imp.next, 200)
            p.masters.append(m)
        }
        let fallbackLayout = p.masters.first?.layouts.first?.id ?? LayoutId(0)

        // Slides.
        var fileSlideIds: [UInt32: SlideId] = [:]
        var notesByTarget: [ByteKey: TextBody] = [:]
        for (fileId, path, id) in slideIds {
            guard let doc = docs[ByteKey(OPC.norm(path))] else { continue }
            let part = Part(pkg, path, doc)
            let layout = part.rels.firstOf("slideLayout").flatMap { layoutByPart[ByteKey(OPC.norm($0.target))] } ?? fallbackLayout
            var slide = readSlide(imp, part, doc, id, layout)
            // Notes.
            if let n = part.rels.firstOf("notesSlide") {
                let nKey = ByteKey(OPC.norm(n.target))
                if let cached = notesByTarget[nKey] {
                    slide.notes = cached
                } else if let nd = load(pkg, n.target) {
                    let np = Part(pkg, n.target, nd)
                    let notes = readNotes(imp, np, nd.root)
                    notesByTarget[nKey] = notes
                    slide.notes = notes
                }
            }
            // Comments. A modern part and the legacy part can describe the same threads (PowerPoint
            // writes both): the modern one wins, its flattened legacy copy is skipped.
            var parts: [(XMLDoc, Bool)] = []
            for c in part.rels.allOf("comments") {
                if let cd = pkg.xml(c.target) {
                    // The content type names the modern part; a package that types it only through a
                    // Default entry instead of an Override is still modern when its root is p188.
                    let modern = (pkg.contentType(c.target).map { bytesEqual($0, PPTXWrite.ctCommentsModern) } ?? false)
                        || bytesEqual(cd.root.prefix, "p188")
                    parts.append((cd, modern))
                }
            }
            let hasModern = parts.contains { $0.1 }
            for (cd, modern) in parts {
                if hasModern && !modern { continue }
                slide.comments.append(contentsOf: readComments(pkg, presPart, cd.root, modern))
            }
            fileSlideIds[fileId] = id
            p.slides.append(slide)
        }

        // Sections.
        if let ext = presEl.child("extLst") {
            if let sl = ext.find("sectionLst") {
                for s in sl.childrenNamed("section").prefix(10_000) {
                    let slides = s.child("sldIdLst").map { l in
                        l.childrenNamed("sldId").compactMap { x in x.u32("id").flatMap { fileSlideIds[$0] } }
                    } ?? []
                    p.sections.append(Section(name: s.attr("name") ?? "", slides: slides))
                }
            }
            let kept = ext.childrenNamed("ext")
                .filter { e in !(e.attr("uri").map { bytesEqual($0, PPTX.sectionExtURI) } ?? false) && !hasRelRefs(e) }
                .map { presPart.keep($0) }
                .joined()
            if !kept.isEmpty { p.rawExt = kept }
        }
        p.tags = tags(imp, presPart, presEl)
        // Custom shows.
        if let l = presEl.child("custShowLst") {
            for cs in l.childrenNamed("custShow") {
                let slides = cs.child("sldLst").map { l in
                    l.childrenNamed("sld")
                        .compactMap { presPart.rels.target($0.attr("r:id") ?? "") }
                        .compactMap { imp.slideByPart[ByteKey(OPC.norm($0))] }
                } ?? []
                p.customShows.append(CustomShow(name: cs.attr("name") ?? "", slides: slides))
            }
        }
        // Drawing guides (eighths of a point).
        if let r = presPart.rels.firstOf("viewProps"), let d = pkg.xml(r.target),
           let lst = d.root.find("slideViewPr")?.find("guideLst")
        {
            p.guides = Array(lst.childrenNamed("guide").lazy.compactMap { g -> DrawGuide? in
                let pos = (g.attr("pos").flatMap { rustParseF64($0) } ?? 0.0) / 8.0
                guard pos.isFinite else { return nil }
                return DrawGuide(vertical: !(g.attr("orient").map { bytesEqual($0, "horz") } ?? false), pos: pos)
            }.prefix(1000))
        }
        // Show settings.
        if let r = presPart.rels.firstOf("presProps"), let d = pkg.xml(r.target), let sp = d.root.child("showPr") {
            p.show = readShow(sp, imp.customShowNames)
        }
        // Notes master.
        if let r = presPart.rels.firstOf("notesMaster"), let d = load(pkg, r.target) {
            let part = Part(pkg, r.target, d)
            let ctx = IdCtx()
            var m = Master.default
            m.id = MasterId(imp.alloc())
            m.name = "Notes Master"
            if let t = part.rels.firstOf("theme"), let td = pkg.xml(t.target) {
                let tp = Part(pkg, t.target, td)
                m.theme = readTheme(imp, tp, td.root)
            }
            if let csld = d.root.child("cSld") {
                m.background = background(imp, part, csld)
                if let tree = csld.child("spTree") { m.shapes = spTree(imp, part, ctx, tree, 0) }
            }
            if let cm = d.root.child("clrMap") { m.colorMap = colorMap(cm) }
            // Notes text styles are the body's list style; slide masters use title/body/other instead.
            if let ns = d.root.child("notesStyle") { m.bodyStyle = listStyle(imp, part, ns) }
            p.notesMaster = m
        }
        // Handout master (header, footer, date and slide number for printed handouts).
        if let r = presPart.rels.firstOf("handoutMaster"), let d = load(pkg, r.target) {
            let part = Part(pkg, r.target, d)
            let ctx = IdCtx()
            var m = Master.default
            m.id = MasterId(imp.alloc())
            m.name = "Handout Master"
            if let t = part.rels.firstOf("theme"), let td = pkg.xml(t.target) {
                let tp = Part(pkg, t.target, td)
                m.theme = readTheme(imp, tp, td.root)
            } else if let first = p.masters.first {
                m.theme = first.theme
            }
            if let csld = d.root.child("cSld") {
                if let n = csld.attr("name"), !n.isEmpty { m.name = n }
                m.background = background(imp, part, csld)
                if let tree = csld.child("spTree") { m.shapes = spTree(imp, part, ctx, tree, 0) }
            }
            if let cm = d.root.child("clrMap") { m.colorMap = colorMap(cm) }
            p.handoutMaster = m
        }
        // Document properties.
        if let r = rootRels.firstOf("core-properties"), let d = pkg.xml(r.target) {
            readCore(d.root, &p.props)
        }
        if let r = rootRels.firstOf("extended-properties"), let d = pkg.xml(r.target) {
            p.props.company = d.root.child("Company")?.text ?? ""
        }

        p.keptParts = keptParts(pkg, presPath)

        inheritPlaceholderGeometry(&p)
        defaultTextAnchor(&p)
        p.headerFooter = headerFooter(p)
        p.embeddedFonts = readEmbeddedFonts(imp, presPart, presEl)
        p.media = imp.media
        imp.media = []
        p.nextId = imp.next
        p.fixNextId()
        return (p, lostSlides)
    }

    // MARK: - Embedded fonts

    /// Embedded font faces in one file. Past this, further typefaces are dropped.
    static let maxEmbeddedFonts = 64
    /// One font part. A larger part is skipped; the rest of the file is still read.
    static let maxFontBytes = 32 * 1024 * 1024

    /// `p:embeddedFontLst`: each typeface and the font parts its four face slots point at.
    static func readEmbeddedFonts(_ imp: Imp, _ pres: Part, _ root: XMLEl) -> [EmbeddedFont] {
        guard let list = root.child("embeddedFontLst") else { return [] }
        var out: [EmbeddedFont] = []
        for e in list.childrenNamed("embeddedFont").prefix(maxEmbeddedFonts) {
            guard let font = e.child("font") else { continue }
            guard let raw = font.attr("typeface") else { continue }
            let trimmed = rustTrim(raw)
            if trimmed.isEmpty { continue }
            let typeface = takeChars(trimmed, 255)
            func slot(_ name: String) -> MediaId? {
                guard let id = e.child(name)?.attr("r:id"), let part = pres.rels.target(id), let data = imp.pkg.get(part) else { return nil }
                if data.isEmpty || data.count > maxFontBytes {
                    PPTXLog.warn("pptx: embedded font \(part) skipped (\(data.count) bytes)")
                    return nil
                }
                return imp.mediaFor(part)
            }
            let regular = slot("regular")
            let bold = slot("bold")
            let italic = slot("italic")
            let boldItalic = slot("boldItalic")
            if regular == nil && bold == nil && italic == nil && boldItalic == nil { continue }
            out.append(EmbeddedFont(
                typeface: typeface, panose: panoseAttr(font), pitchFamily: byteAttr(font, "pitchFamily"),
                charset: byteAttr(font, "charset"), regular: regular, bold: bold, italic: italic, boldItalic: boldItalic
            ))
        }
        return out
    }

    static func byteAttr(_ el: XMLEl, _ name: String) -> UInt8? {
        el.u32(name).flatMap { UInt8(exactly: $0) }
    }

    /// `panose` is 20 hex digits (ST_Panose). Anything else is dropped.
    static func panoseAttr(_ el: XMLEl) -> String? {
        guard let raw = el.attr("panose") else { return nil }
        let v = rustTrim(raw)
        guard v.utf8.count == 20, v.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isASCIIHexDigit }) else { return nil }
        return String(v)
    }

    static func saneLen(_ v: Double, _ dflt: Double) -> Double {
        v.isFinite && (1.0 ... 20_000.0).contains(v) ? v : dflt
    }

    // MARK: - Relationship references

    /// Does the element (or a descendant) reference a relationship?
    static func hasRelRefs(_ el: XMLEl) -> Bool {
        !relRefs(el).isEmpty
    }

    /// Is this attribute a relationship id (`r:id`, `r:embed`, `r:dm`…)?
    static func isRelAttr(_ k: String, _ v: String) -> Bool {
        guard !hasBytePrefix(k, "xmlns"), let colon = k.utf8.lastIndex(of: UInt8(ascii: ":")) else { return false }
        let last = k[k.utf8.index(after: colon)...]
        return ["id", "embed", "link", "dm", "lo", "qs", "cs", "pict", "href"].contains { bytesEqual($0, last) } && !v.isEmpty
    }

    /// Every relationship id `el` and its descendants use, sorted and without repeats.
    static func relRefs(_ el: XMLEl) -> [String] {
        var out: [String] = []
        func rec(_ e: XMLEl, _ depth: Int) {
            if depth > XML.maxDepth { return }
            for (k, v) in e.attrs where isRelAttr(k, v) { out.append(v) }
            for c in e.elements { rec(c, depth + 1) }
        }
        rec(el, 0)
        out.sort { bytesLess($0, $1) }
        var deduped: [String] = []
        for s in out where !(deduped.last.map { bytesEqual($0, s) } ?? false) { deduped.append(s) }
        return deduped
    }

    static func colorMap(_ cm: XMLEl) -> [Pair<String, String>] {
        cm.attrs.filter { !hasBytePrefix($0.key, "xmlns") }.map { Pair($0.key, $0.value) }
    }

    // MARK: - Post-processing

    /// A shape's text without an anchor of its own sits at the top, as the standard has it and as
    /// PowerPoint draws it. The theme's shape defaults (`a:objectDefaults/a:spDef/a:bodyPr`, centred in
    /// Office's themes) are for shapes inserted later, not for the file's own shapes: PowerPoint for
    /// Mac draws `<a:bodyPr/>` at the top under an `spDef` with `anchor="ctr"`. The model's own default
    /// for shapes is the middle, so a top or bottom anchor is made explicit here and a middle one left
    /// unset (placeholders and text boxes keep inheriting).
    static func defaultTextAnchor(_ p: inout Presentation) {
        func fix(_ shapes: inout [Shape]) {
            walkShapesMut(&shapes) { s in
                if case .table = s.kind { return }
                guard s.ph == nil, !s.textBox, var t = s.text else { return }
                // Middle is the model's own default for shapes, so it is kept as unset.
                let got = t.body.anchor ?? .top
                t.body.anchor = got != .middle ? got : nil
                s.text = t
            }
        }
        for mi in p.masters.indices {
            fix(&p.masters[mi].shapes)
            for li in p.masters[mi].layouts.indices { fix(&p.masters[mi].layouts[li].shapes) }
        }
        for si in p.slides.indices { fix(&p.slides[si].shapes) }
    }

    static func isUnsetGeom(_ g: Geom) -> Bool {
        if case .custom(let paths) = g { return paths.isEmpty }
        return false
    }

    /// Placeholders read without a geometry (an empty custom geometry, see `sp`) take the geometry of
    /// the layout or master placeholder they inherit from, as PowerPoint draws them: a layout's picture
    /// placeholder cut into a shape keeps that shape on the slide. Anything left is a rectangle.
    static func inheritPlaceholderGeometry(_ p: inout Presentation) {
        let unset = isUnsetGeom
        func defaultUnset(_ shapes: inout [Shape]) {
            walkShapesMut(&shapes) { s in if unset(s.geom) { s.geom = .default } }
        }
        // Masters first, then layouts (from their masters), then slides (from layouts and masters).
        for mi in p.masters.indices { defaultUnset(&p.masters[mi].shapes) }
        var layoutGeoms: [(LayoutId, Int, Geom)] = []
        for m in p.masters {
            for l in m.layouts {
                let ctx = Resolve.Ctx.forLayout(p, m, l)
                for (i, s) in l.shapes.enumerated() where unset(s.geom) {
                    let (_, mp) = Resolve.parents(ctx, s)
                    let g = mp.map(\.geom).flatMap { unset($0) ? nil : $0 } ?? .default
                    layoutGeoms.append((l.id, i, g))
                }
            }
        }
        for mi in p.masters.indices {
            for li in p.masters[mi].layouts.indices {
                let id = p.masters[mi].layouts[li].id
                for (lid, i, g) in layoutGeoms where lid == id {
                    if i < p.masters[mi].layouts[li].shapes.count { p.masters[mi].layouts[li].shapes[i].geom = g }
                }
            }
        }
        var slideGeoms: [(Int, Int, Geom)] = []
        for (si, sl) in p.slides.enumerated() {
            guard let ctx = Resolve.Ctx.forSlide(p, sl) else { continue }
            for (i, s) in sl.shapes.enumerated() where unset(s.geom) {
                let (lp, mp) = Resolve.parents(ctx, s)
                let g = lp.map(\.geom).flatMap { unset($0) ? nil : $0 } ?? mp.map(\.geom).flatMap { unset($0) ? nil : $0 }
                slideGeoms.append((si, i, g ?? .default))
            }
        }
        for (si, i, g) in slideGeoms {
            if si < p.slides.count, i < p.slides[si].shapes.count { p.slides[si].shapes[i].geom = g }
        }
        // Placeholders inside groups (rare) and anything still unset: rectangles.
        for si in p.slides.indices { defaultUnset(&p.slides[si].shapes) }
        for mi in p.masters.indices {
            for li in p.masters[mi].layouts.indices { defaultUnset(&p.masters[mi].layouts[li].shapes) }
        }
    }

    /// Every shape, groups included.
    static func walkShapesMut(_ shapes: inout [Shape], _ f: (inout Shape) -> Void) {
        for i in shapes.indices {
            f(&shapes[i])
            shapes[i].mutateChildren { walkShapesMut(&$0, f) }
        }
    }

    // MARK: - Table styles, backgrounds

    /// `a:tblStyleLst`: the table styles the file defines.
    static func tableStyles(_ imp: Imp, _ part: Part, _ root: XMLEl) -> [TableStyleDef] {
        let accent1 = ColorRef.scheme(.accent1)
        return root.childrenNamed("tblStyle").prefix(256).compactMap { st -> TableStyleDef? in
            guard let sid = st.attr("styleId") else { return nil }
            var def = TableStyleDef(id: asciiUppercase(sid), name: st.attr("styleName") ?? "", raw: part.keep(st))
            if let bg = st.child("tblBg") {
                var ps = TablePartStyle()
                if let f = bg.elements.first(where: { hasByteSuffix($0.local, "Fill") }) {
                    ps.fill = fillEl(imp, part, f)
                }
                if let fr = bg.child("fillRef") {
                    ps.fillRef = Pair(fr.u32("idx") ?? 0, color(fr) ?? accent1)
                }
                def.background = ps
            }
            for el in st.elements {
                guard let kind = TablePart.fromXML(String(el.local)) else { continue }
                var ps = TablePartStyle()
                if let tx = el.child("tcTxStyle") {
                    ps.textColor = color(tx)
                    ps.bold = tx.attr("b").map { bytesEqual($0, "on") }
                    ps.italic = tx.attr("i").map { bytesEqual($0, "on") }
                }
                if let tc = el.child("tcStyle") {
                    if let f = tc.child("fill")?.elements.first(where: { _ in true }) {
                        ps.fill = fillEl(imp, part, f)
                    }
                    if let fr = tc.child("fillRef") {
                        ps.fillRef = Pair(fr.u32("idx") ?? 0, color(fr) ?? accent1)
                    }
                    if let bd = tc.child("tcBdr") {
                        for (i, side) in ["left", "right", "top", "bottom", "insideH", "insideV"].enumerated() {
                            guard let b = bd.child(side) else { continue }
                            let border: TableBorder?
                            if let ln = b.child("ln") {
                                border = .line(line: line(imp, part, ln))
                            } else {
                                border = b.child("lnRef").map { r in .ref(idx: r.u32("idx") ?? 0, color: color(r) ?? accent1) }
                            }
                            if i < ps.borders.count { ps.borders[i] = border }
                        }
                    }
                }
                def.parts.append(Pair(kind, ps))
            }
            return def
        }
    }

    static func background(_ imp: Imp, _ part: Part, _ csld: XMLEl) -> Background? {
        guard let bg = csld.child("bg") else { return nil }
        if let pr = bg.child("bgPr") {
            return .fill(fill: fillOf(imp, part, pr) ?? .none_)
        }
        guard let r = bg.child("bgRef") else { return nil }
        return .ref(idx: r.u32("idx") ?? 1001, color: color(r) ?? .scheme(.bg1))
    }

    // MARK: - Masters, layouts, slides

    static func readMaster(_ imp: Imp, _ path: String, _ doc: XMLDoc, _ docs: [ByteKey: XMLDoc], _ layoutByPart: inout [ByteKey: LayoutId]) -> Master {
        let pkg = imp.pkg
        let part = Part(pkg, path, doc)
        let root = doc.root
        var m = Master.default
        m.id = MasterId(0)
        m.preserve = root.bool("preserve") ?? false
        if let t = part.rels.firstOf("theme"), let td = pkg.xml(t.target) {
            let tp = Part(pkg, t.target, td)
            m.theme = readTheme(imp, tp, td.root)
        }
        m.id = MasterId(imp.alloc())
        if let cm = root.child("clrMap") { m.colorMap = colorMap(cm) }
        if let csld = root.child("cSld") {
            m.name = csld.attr("name") ?? ""
            m.background = background(imp, part, csld)
            if let tree = csld.child("spTree") {
                let ctx = IdCtx()
                m.shapes = spTree(imp, part, ctx, tree, 0)
            }
        }
        if m.name.isEmpty { m.name = m.theme.name }
        if let ts = root.child("txStyles") {
            if let s = ts.child("titleStyle") { m.titleStyle = listStyle(imp, part, s) }
            if let s = ts.child("bodyStyle") { m.bodyStyle = listStyle(imp, part, s) }
            if let s = ts.child("otherStyle") { m.otherStyle = listStyle(imp, part, s) }
        }
        // Layouts in list order, then any other related layouts.
        var lpaths: [String] = root.child("sldLayoutIdLst").map { l in
            l.childrenNamed("sldLayoutId").compactMap { part.rels.target($0.attr("r:id") ?? "") }
        } ?? []
        for r in part.rels.allOf("slideLayout") where !lpaths.contains(where: { bytesEqual(OPC.norm($0), OPC.norm(r.target)) }) {
            lpaths.append(r.target)
        }
        for lp in lpaths.prefix(1000) {
            let key = ByteKey(OPC.norm(lp))
            if layoutByPart[key] != nil { continue }
            guard let ld = docs[key] else { continue }
            let lpart = Part(pkg, lp, ld)
            let l = readLayout(imp, lpart, ld)
            layoutByPart[key] = l.id
            m.layouts.append(l)
        }
        if m.layouts.isEmpty {
            // A master must have a layout for slides to use.
            imp.next = satAdd(imp.next, 1)
            m.layouts.append(Layout(id: LayoutId(imp.next), name: "Blank", kind: .blank, showMasterShapes: true))
        }
        if let ext = root.child("extLst"), !hasRelRefs(ext) {
            m.rawExt = ext.elements.map { part.keep($0) }.joined()
        }
        return m
    }

    static func readLayout(_ imp: Imp, _ part: Part, _ doc: XMLDoc) -> Layout {
        let root = doc.root
        var l = Layout(
            id: LayoutId(imp.alloc()), kind: LayoutType.fromXML(root.attr("type") ?? "cust"),
            showMasterShapes: root.bool("showMasterSp") ?? true, preserve: root.bool("preserve") ?? false
        )
        if let csld = root.child("cSld") {
            l.name = csld.attr("name") ?? ""
            l.background = background(imp, part, csld)
            if let tree = csld.child("spTree") {
                let ctx = IdCtx()
                l.shapes = spTree(imp, part, ctx, tree, 0)
            }
        }
        l.colorMap = colorMapOverride(root)
        if let ext = root.child("extLst"), !hasRelRefs(ext) {
            l.rawExt = ext.elements.map { part.keep($0) }.joined()
        }
        return l
    }

    /// A layout's or slide's `clrMapOvr/overrideClrMapping` (nil for `masterClrMapping` or none).
    static func colorMapOverride(_ root: XMLEl) -> [Pair<String, String>]? {
        root.child("clrMapOvr")?.child("overrideClrMapping").map(colorMap)
    }

    static func readSlide(_ imp: Imp, _ part: Part, _ doc: XMLDoc, _ id: SlideId, _ layout: LayoutId) -> Slide {
        let root = doc.root
        var s = Slide.default
        s.id = id
        s.layout = layout
        s.hidden = root.bool("show") == false
        s.showMasterShapes = root.bool("showMasterSp") ?? true
        s.colorMap = colorMapOverride(root)
        let ctx = IdCtx()
        if let csld = root.child("cSld") {
            s.name = csld.attr("name") ?? ""
            s.tags = tags(imp, part, csld)
            s.background = background(imp, part, csld)
            if let tree = csld.child("spTree") {
                s.shapes = spTree(imp, part, ctx, tree, 0)
            }
            if let c = csld.child("controls") {
                let pics = controls(imp, part, ctx, c)
                s.shapes.append(contentsOf: pics)
            }
        }
        if let t = root.child("transition") {
            s.transition = transition(imp, part, t)
        }
        if let t = root.child("timing") {
            s.animations = animations(ctx, t, s.shapes)
        }
        if let ext = root.child("extLst"), !hasRelRefs(ext) {
            s.rawExt = ext.elements.map { part.keep($0) }.joined()
        }
        return s
    }

    static func readNotes(_ imp: Imp, _ part: Part, _ root: XMLEl) -> TextBody {
        guard let tree = root.path(["cSld", "spTree"]) else { return .default }
        for sp in tree.childrenNamed("sp") {
            let ph = sp.path(["nvSpPr", "nvPr", "ph"])
            let isBody = ph.map { ph in
                let ty = ph.attr("type")
                return (ty == nil || bytesEqual(ty ?? "", "body")) && !(ty.map { bytesEqual($0, "sldImg") } ?? false)
            } ?? false
            if isBody, let tx = sp.child("txBody") {
                var t = textBody(imp, part, tx)
                // Notes keep only content: drop body formatting from the notes master placeholder.
                t.listStyle = .default
                if t.isEmpty { return .default }
                return t
            }
        }
        return .default
    }

    static func readComments(_ pkg: Package, _ pres: Part, _ root: XMLEl, _ modern: Bool) -> [Comment] {
        // Authors: legacy commentAuthors.xml (numeric ids) and modern authors.xml (GUIDs).
        var authors: [ByteKey: (String, String)] = [:]
        for kind in ["commentAuthors", "authors"] {
            if let r = pres.rels.firstOf(kind), let d = pkg.xml(r.target) {
                for a in d.root.elements {
                    if let id = a.attr("id") { authors[ByteKey(id)] = (a.attr("name") ?? "", a.attr("initials") ?? "") }
                }
            }
        }
        // Legacy positions are 1/8 pt; the modern part's p188:pos is an a:CT_Point2D in EMU.
        let scale = modern ? 12_700.0 : 8.0
        func one(_ e: XMLEl, _ depth: Int) -> Comment {
            let (author, initials) = e.attr("authorId").flatMap { authors[ByteKey($0)] } ?? ("", "")
            let text: String
            if let t = e.child("text") {
                text = t.text
            } else if let tb = e.child("txBody") {
                text = tb.childrenNamed("p").map(\.text).joined(separator: "\n")
            } else {
                text = ""
            }
            let pos = e.child("pos")
            let replies = depth < 4 ? (e.child("replyLst").map { l in l.childrenNamed("reply").prefix(1000).map { one($0, depth + 1) } } ?? []) : []
            return Comment(
                author: author, initials: initials, text: text, date: e.attr("dt") ?? e.attr("created") ?? "",
                x: (pos?.f64("x") ?? 0.0) / scale, y: (pos?.f64("y") ?? 0.0) / scale,
                resolved: e.attr("status").map { bytesEqual($0, "resolved") } ?? false, replies: replies, shape: nil
            )
        }
        return root.childrenNamed("cm").prefix(10_000).map { one($0, 0) }
    }

    static func readShow(_ sp: XMLEl, _ shows: [ByteKey: String]) -> ShowSettings {
        var s = ShowSettings.default
        s.loopUntilEsc = sp.bool("loop") ?? false
        s.withoutNarration = sp.bool("showNarration") == false
        s.withoutAnimation = sp.bool("showAnimation") == false
        s.useTimings = sp.bool("useTimings") ?? true
        if sp.child("browse") != nil {
            s.showType = "browsed"
        } else if sp.child("kiosk") != nil {
            s.showType = "kiosk"
        }
        if let r = sp.child("sldRg") {
            s.range = Pair(Swift.max(r.u32("st") ?? 1, 1), Swift.max(r.u32("end") ?? 1, 1))
        }
        if let c = sp.child("custShow") {
            let id = c.attr("id") ?? ""
            s.customShow = shows[ByteKey(id)] ?? id
        }
        if let c = sp.child("penClr").flatMap(color), case .rgb(let rgb) = c.base {
            s.penColor = rgb
        }
        return s
    }

    static func readCore(_ root: XMLEl, _ p: inout Properties) {
        for e in root.elements {
            let t = e.text
            switch e.local {
            case "title": p.title = t
            case "subject": p.subject = t
            case "creator": p.author = t
            case "keywords": p.keywords = t
            case "description": p.comments = t
            case "category": p.category = t
            case "lastModifiedBy": p.lastModifiedBy = t
            case "revision": p.revision = rustParseUnsigned(rustTrim(t), as: UInt32.self) ?? 0
            case "created": p.created = t
            case "modified": p.modified = t
            default: break
            }
        }
    }

    /// Which footer placeholders the slides show.
    static func headerFooter(_ p: Presentation) -> HeaderFooter {
        var hf = HeaderFooter()
        for s in p.slides {
            for sh in s.shapes {
                switch sh.phType {
                case .slideNum?:
                    hf.slideNumber = true
                case .date?:
                    hf.date = true
                    if let t = sh.text,
                       !t.paragraphs.contains(where: { $0.runs.contains { if case .field = $0.kind { return true }; return false } }),
                       hf.dateText.isEmpty
                    {
                        hf.dateText = t.text
                    }
                case .footer?:
                    hf.footer = true
                    if hf.footerText.isEmpty, let t = sh.text { hf.footerText = t.text }
                default:
                    break
                }
            }
        }
        return hf
    }
}

// MARK: - Rust string and integer helpers

extension PPTXRead {

    /// `u32::saturating_add`.
    static func satAdd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (v, o) = a.addingReportingOverflow(b)
        return o ? .max : v
    }

    /// Byte-wise `<`, as Rust orders `String`s.
    static func bytesLess(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// `str::contains(&str)`, byte for byte.
    static func bytesContains(_ s: some StringProtocol, _ needle: some StringProtocol) -> Bool {
        let h = Array(s.utf8), n = Array(needle.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        for i in 0 ... (h.count - n.count) where h[i] == n[0] {
            var j = 1
            while j < n.count, h[i + j] == n[j] { j += 1 }
            if j == n.count { return true }
        }
        return false
    }

    /// `str::split_once(':')`-style split at the first `sep` byte.
    static func splitOnce(_ s: String, _ sep: Character) -> (Substring, Substring)? {
        guard let b = sep.asciiValue, let i = s.utf8.firstIndex(of: b) else { return nil }
        return (s[..<i], s[s.utf8.index(after: i)...])
    }

    /// `str::to_ascii_uppercase`.
    static func asciiUppercase(_ s: some StringProtocol) -> String {
        String(decoding: s.utf8.map { (0x61 ... 0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
    }

    /// `s.chars().take(n).collect::<String>()`.
    static func takeChars(_ s: some StringProtocol, _ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(v)
    }

    /// `str::strip_prefix`, byte for byte.
    static func stripBytePrefix(_ s: some StringProtocol, _ prefix: String) -> Substring? {
        guard hasBytePrefix(s, prefix) else { return nil }
        let sub = Substring(s)
        return sub[sub.utf8.index(sub.utf8.startIndex, offsetBy: prefix.utf8.count)...]
    }

    /// `str::split(b)` for an ASCII byte `b`: every piece, empty ones included.
    static func splitByte(_ s: Substring, _ b: UInt8) -> [Substring] {
        var out: [Substring] = []
        var start = s.startIndex
        var i = s.utf8.startIndex
        while i < s.utf8.endIndex {
            if s.utf8[i] == b {
                out.append(s[start ..< i])
                start = s.utf8.index(after: i)
            }
            i = s.utf8.index(after: i)
        }
        out.append(s[start...])
        return out
    }

    /// `str::strip_suffix`, byte for byte.
    static func stripByteSuffix(_ s: some StringProtocol, _ suffix: String) -> Substring? {
        guard hasByteSuffix(s, suffix) else { return nil }
        let sub = Substring(s)
        return sub[..<sub.utf8.index(sub.utf8.endIndex, offsetBy: -suffix.utf8.count)]
    }

    /// `Option<&str> == Some(lit)`, byte for byte.
    static func attrIs(_ v: String?, _ lit: String) -> Bool {
        v.map { bytesEqual($0, lit) } ?? false
    }

    /// `f64::rem_euclid`.
    static func remEuclid(_ a: Double, _ b: Double) -> Double {
        let r = a.rem(b)
        return r < 0 ? r + Swift.abs(b) : r
    }

    /// `f64::total_cmp(a, b) == Less`.
    static func totalLess(_ a: Double, _ b: Double) -> Bool {
        func key(_ x: Double) -> Int64 {
            let bits = Int64(bitPattern: x.bitPattern)
            return bits ^ Int64(bitPattern: UInt64(bitPattern: bits >> 63) >> 1)
        }
        return key(a) < key(b)
    }
}
