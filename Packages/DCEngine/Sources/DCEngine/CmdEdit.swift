// DCEngine — the Edit menu: undo/redo, clipboard, duplicate, delete, select all.
// Port of deckcraft crates/engine/src/cmd/edit.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum EditCommands {
    public static func specs() -> [CommandSpec] {
        [
            .noundo("edit.undo", "Undo", ["Edit"], "Cmd+Z", "{}", Cmd.canUndo, undo),
            .noundo("edit.redo", "Redo", ["Edit"], "Cmd+Y", "{}", Cmd.canRedo, redo),
            .cmd("edit.cut", "Cut", ["Home", "Clipboard"], "Cmd+X", "{scope?: slides} → {text, html?}", Cmd.hasDoc, cut),
            .noundo("edit.copy", "Copy", ["Home", "Clipboard"], "Cmd+C", "{scope?: slides} → {text, html?}", Cmd.hasDoc, copy),
            .cmd(
                "edit.paste",
                "Paste",
                ["Home", "Clipboard"],
                "Cmd+V",
                "{text?: plain text to paste, html?: rich text from another app, scope?: slides}",
                Cmd.hasDoc,
                paste
            ),
            .cmd(
                "edit.pasteSpecial",
                "Paste Special",
                ["Home", "Clipboard"],
                nil,
                "{as: destinationTheme|keepSource|picture|text} — Use Destination Theme, Keep Source Formatting, Picture (PNG), Keep Text Only",
                Cmd.hasDoc,
                pasteSpecial
            ),
            .cmd("edit.pasteText", "Paste and Match Formatting", ["Edit"], "Cmd+Shift+V", "{text?}", Cmd.hasDoc, pasteText),
            .cmd("edit.duplicate", "Duplicate", ["Edit"], "Cmd+D", "{ids?}", Cmd.hasSelection, duplicate),
            .cmd("edit.delete", "Delete", ["Edit"], "Delete", "{ids?, scope?: slides}", Cmd.hasDoc, delete),
            .noundo("edit.selectAll", "Select All", ["Edit"], "Cmd+A", "{scope?: slides}", Cmd.hasSlide, selectAll),
            .noundo("edit.deselect", "Deselect", [], "Escape", "{}", Cmd.hasDoc, deselect),
            .noundo("edit.select", "Select Objects", [], nil, "{ids: [id], add?: bool, toggle?: bool}", Cmd.hasSlide, select),
        ]
    }

    private static func restore(_ s: Session, _ redo: Bool) throws -> JSON {
        let vertexKind = s.tool.vertexKind
        let st = try s.docMut()
        let e: HistoryEntry
        if redo {
            guard let x = st.history.redo.popLast() else { return Cmd.ok() }
            e = x
            st.history.undo.append(HistoryEntry(label: e.label, doc: st.docRef, selection: st.selection, vertexKind: vertexKind))
        } else {
            guard let x = st.history.undo.popLast() else { return Cmd.ok() }
            e = x
            st.history.redo.append(HistoryEntry(label: e.label, doc: st.docRef, selection: st.selection, vertexKind: vertexKind))
        }
        st.docRef = e.doc
        st.selection = e.selection
        st.interaction = nil
        // A later shape can get an undone copy's id: Duplicate starts over with the usual offset.
        st.lastDuplicate = nil
        st.revision += 1
        // The point type Edit Points remembered with the restored document: handle drags follow it.
        s.tool.vertexKind = e.vertexKind
        return ["label": .string(e.label)]
    }

    @Sendable static func undo(_ s: Session, _ p: JSON) throws -> JSON { try restore(s, false) }
    @Sendable static func redo(_ s: Session, _ p: JSON) throws -> JSON { try restore(s, true) }

    private static func slidesScope(_ s: Session, _ p: JSON) -> Bool {
        if Cmd.strParam(p, "scope") == "slides" { return true }
        guard let d = s.activeDoc else { return false }
        return d.selection.shapes.isEmpty && d.selection.text == nil && !d.selection.slides.isEmpty
    }

    private static func copyInner(_ s: Session, _ p: JSON) throws -> String {
        let st = try s.doc()
        // Text selection.
        if let t = st.selection.text {
            if t.isRange {
                let body = TextCommands.bodyOf(st, t) ?? .default
                let (a, b) = t.ordered
                let plain = TextEdit.textRange(body, a.tuple, b.tuple)
                let sliced = TextEdit.slice(body, a.tuple, b.tuple)
                var c = Clipboard()
                c.text = sliced
                c.plain = plain
                s.clipboard = c
                return plain
            }
            return ""
        }
        let doc = st.doc
        if slidesScope(s, p) {
            let ids = st.selection.slides.isEmpty ? (st.currentSlide.map { [$0.id] } ?? []) : st.selection.slides
            let slides = ids.compactMap { doc.slide($0) }
            var mids: [MediaId] = []
            for sl in slides { mids += MediaRefs.slideMedia(sl) }
            var c = Clipboard()
            c.media = doc.media.filter { mids.contains($0.id) }
            c.plain = slides.map(\.title).joined(separator: "\n")
            c.slides = slides
            s.clipboard = c
            return c.plain
        }
        // Selected table cells copy as their text: a tab between cells and a paragraph per row.
        if p.get("id") == nil && p.get("ids") == nil, let plain = TableCommands.selectedCellsText(st) {
            var c = Clipboard()
            c.text = TextBody.fromText(plain)
            c.plain = plain
            s.clipboard = c
            return plain
        }
        let shapes: [Shape] = st.selection.shapes.compactMap { id in
            guard var sh = st.shape(id) else { return nil }
            if sh.xfrm == nil { sh.xfrm = Cmd.xfrmOf(doc, st.selection, sh) }
            return sh
        }
        let mids = MediaRefs.shapesMedia(shapes)
        var c = Clipboard()
        c.media = doc.media.filter { mids.contains($0.id) }
        c.plain = shapes.compactMap { $0.text?.text }.joined(separator: "\n")
        c.shapes = shapes
        if let sl = st.currentSlide, let (m, _) = doc.masterFor(sl) { c.sourceTheme = (m.scheme, m.theme.fonts) }
        s.clipboard = c
        return c.plain
    }

    private static func copyingCaret(_ s: Session) -> Bool {
        s.activeDoc?.selection.text.map { !$0.isRange } ?? false
    }

    @Sendable static func copy(_ s: Session, _ p: JSON) throws -> JSON {
        // A caret copies nothing; the previous clipboard must not leak into this answer.
        let caret = copyingCaret(s)
        let t = try copyInner(s, p)
        let html = caret ? "" : copiedHTML(s)
        return ["text": .string(t), "html": .string(html)]
    }

    /// HTML for what was just copied, when it is text (a selection, or the text on the copied shapes).
    private static func copiedHTML(_ s: Session) -> String {
        if let body = s.clipboard.text { return RichClip.bodyToHTML(body) }
        var paragraphs: [Paragraph] = []
        for sh in s.clipboard.shapes { if let t = sh.text { paragraphs += t.paragraphs } }
        if paragraphs.isEmpty { return "" }
        var body = TextBody.default
        body.paragraphs = paragraphs
        return RichClip.bodyToHTML(body)
    }

    @Sendable static func cut(_ s: Session, _ p: JSON) throws -> JSON {
        let caret = copyingCaret(s)
        let t = try copyInner(s, p)
        if caret {
            // Nothing is selected, so there is nothing to cut; `delete` would remove the next character.
            return ["text": .string(t), "html": ""]
        }
        let html = copiedHTML(s)
        _ = try delete(s, p)
        return ["text": .string(t), "html": .string(html)]
    }

    /// Give pasted shapes fresh ids (groups included) and return the old-to-new map. Connector ends
    /// attached to a shape that was copied too follow its copy; ends attached to a shape outside the
    /// copied set are detached (the connector keeps its geometry), so a copy never stays glued to the
    /// original or to an unrelated shape that happens to share an id in another deck.
    @discardableResult
    public static func reid(_ cmd: String, _ doc: inout Presentation, _ shapes: inout [Shape]) throws -> [ShapeId: ShapeId] {
        var map: [ShapeId: ShapeId] = [:]
        func rec(_ v: inout [Shape], _ depth: Int) throws {
            if depth > 64 { return }
            for i in v.indices {
                guard let raw = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                let id = ShapeId(raw)
                map[v[i].id] = id
                v[i].id = id
                if v[i].isGroup { try v[i].mutateChildren { try rec(&$0, depth + 1) } }
            }
        }
        try rec(&shapes, 0)
        walkMut(&shapes) { s in
            if case .connector(let start, let end) = s.kind {
                let a = start.flatMap { e in map[e.a].map { Pair($0, e.b) } }
                let b = end.flatMap { e in map[e.a].map { Pair($0, e.b) } }
                s.kind = .connector(start: a, end: b)
            }
        }
        return map
    }

    /// Point copied animations at the copies: targets and triggers in `map` follow it; an animation whose
    /// target wasn't copied is dropped, and a trigger that wasn't copied is cleared.
    public static func remapAnimations(_ anims: inout [Animation], _ map: [ShapeId: ShapeId]) {
        anims = anims.compactMap { a in
            guard let n = map[a.shape] else { return nil }
            var a = a
            a.shape = n
            a.trigger = a.trigger.flatMap { map[$0] }
            return a
        }
    }

    /// Rewrite a media id the clipboard used (`map`: clipboard id to destination id).
    private static func remapMedia(_ map: [MediaId: MediaId]) -> (inout MediaId) -> Void {
        { id in if let n = map[id] { id = n } }
    }

    /// Add the clipboard's media to `doc` and return the ids that changed: an id already used in `doc` by
    /// other bytes (another deck) gets a fresh id, and the pasted shapes must use it.
    private static func bringMedia(_ cmd: String, _ doc: inout Presentation, _ media: [MediaItem]) throws -> [MediaId: MediaId] {
        var map: [MediaId: MediaId] = [:]
        for m in media {
            if let x = doc.media(m.id) {
                if x.data == m.data { continue }
                guard let id = doc.addMedia(m.name, m.contentType, m.data) else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                map[m.id] = id
            } else {
                // Keeps the foreign id, so later ids must start past it.
                doc.media.append(m)
                doc.nextId = max(doc.nextId, m.id.rawValue)
            }
        }
        return map
    }

    @Sendable static func paste(_ s: Session, _ p: JSON) throws -> JSON {
        // External plain text (from the system clipboard) wins when given and differs from ours. HTML from
        // Pages or Keynote keeps bold, italic and underline when it says the same words.
        if let t = Cmd.strParam(p, "text"), !rustEqual(t, s.clipboard.plain) {
            if let html = Cmd.strParam(p, "html"), let body = RichClip.htmlToBody(html), RichClip.sameWords(body.text, t) {
                return try pasteExternalBody(s, body)
            }
            return try pastePlain(s, t)
        }
        let editing = try s.doc().selection.text != nil
        if editing {
            if let body = s.clipboard.text { return try TextCommands.pasteBody(s, body) }
            return try pastePlain(s, s.clipboard.plain)
        }
        let clip = s.clipboard
        if !clip.slides.isEmpty {
            let at = try s.doc().selection.slide + 1
            return try s.edit { doc, sel in
                let media = try bringMedia("edit.paste", &doc, clip.media)
                var newIds: [SlideId] = []
                for (k, src) in clip.slides.enumerated() {
                    var sl = src
                    guard let raw = doc.allocId() else { throw Cmd.bad("edit.paste", Cmd.noIdSpace) }
                    sl.id = SlideId(raw)
                    let map = try reid("edit.paste", &doc, &sl.shapes)
                    remapAnimations(&sl.animations, map)
                    MediaRefs.VisitMut.slide(&sl, remapMedia(media))
                    if doc.layout(sl.layout) == nil {
                        sl.layout = doc.masters.first?.layouts.first?.id ?? .default
                    }
                    newIds.append(sl.id)
                    let i = min(at + k, doc.slides.count)
                    doc.slides.insert(sl, at: i)
                }
                sel.slide = min(max(at + newIds.count - 1, 0), max(doc.slides.count - 1, 0))
                sel.slides = newIds
                sel.shapes.removeAll()
                return ["slides": .integer(newIds.count)]
            }
        }
        if !clip.shapes.isEmpty {
            s.clipboard.pastes &+= 1
            var off = s.prefs.duplicateOffset * Double(s.clipboard.pastes)
            // Pasting on another slide keeps the position; on the same slide it offsets.
            let sameSlide = s.activeDoc.map { d in clip.shapes.contains { d.shape($0.id) != nil } } ?? false
            if !sameSlide { off = 0 }
            let offset = off
            return try s.edit { doc, sel in
                let media = try bringMedia("edit.paste", &doc, clip.media)
                var shapes = clip.shapes
                try reid("edit.paste", &doc, &shapes)
                MediaRefs.VisitMut.shapes(&shapes, remapMedia(media))
                var taken = Cmd.currentNames(doc, sel)
                for i in shapes.indices {
                    // Only a name already on the slide is changed (two shapes with one name are what the
                    // issue is about); otherwise it stays, as Morph pairs shapes across slides by name.
                    let name = shapes[i].name
                    if taken.contains(name), let sp = name.utf8.lastIndex(of: UInt8(ascii: " ")) {
                        let base = String(decoding: name.utf8[..<sp], as: UTF8.self)
                        let n = name.utf8[name.utf8.index(after: sp)...]
                        if !n.isEmpty && n.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
                            shapes[i].name = InsertCommands.firstFreeName(base, taken)
                        }
                    }
                    taken.insert(shapes[i].name)
                    if var x = shapes[i].xfrm {
                        x.x += offset
                        x.y += offset
                        shapes[i].xfrm = x
                    }
                    // A pasted placeholder becomes a regular shape keeping its look.
                    if shapes[i].ph != nil && sel.target == .slides { shapes[i].ph = nil }
                }
                let ids = shapes.map(\.id)
                try withShapes(&doc, sel, missing: Cmd.bad("edit.paste", "no slide")) { $0 += shapes }
                sel.shapes = ids
                sel.text = nil
                return ["ids": ids.toJSON()]
            }
        }
        if !clip.plain.isEmpty { return try pastePlain(s, clip.plain) }
        return Cmd.ok()
    }

    private static func pasteExternalBody(_ s: Session, _ body: TextBody) throws -> JSON {
        if try s.doc().selection.text != nil { return try TextCommands.pasteBody(s, body) }
        let plain = body.text
        let size = try s.doc().doc.slideSize
        let rect: JSON = [.num(size.width * 0.25), .num(size.height * 0.4), .num(size.width * 0.5), 40.0]
        let made = try s.execute("insert.textBox", ["rect": rect, "text": .string(plain)])
        guard let raw = made.get("id")?.asU64, let id = UInt32(exactly: raw) else { throw Cmd.bad("edit.paste", "no text box") }
        return try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("edit.paste", "no slide")) { list in
                let found: Void? = withShape(&list, ShapeId(id)) { sh in
                    if var t = sh.text {
                        let (wrap, autofit) = (t.body.wrap, t.body.autofit)
                        t = body
                        t.body.wrap = wrap
                        t.body.autofit = autofit
                        sh.text = t
                    }
                }
                if found == nil { throw Cmd.bad("edit.paste", "no text box") }
            }
            sel.shapes = [ShapeId(id)]
            sel.text = nil
            return ["id": .integer(id)]
        }
    }

    private static func pastePlain(_ s: Session, _ text: String) throws -> JSON {
        if try s.doc().selection.text != nil { return try TextCommands.insertText(s, text, nil) }
        // No text box being edited: a new text box with the text.
        let size = try s.doc().doc.slideSize
        let rect: JSON = [.num(size.width * 0.25), .num(size.height * 0.4), .num(size.width * 0.5), 40.0]
        return try s.execute("insert.textBox", ["rect": rect, "text": .string(text)])
    }

    @Sendable static func pasteSpecial(_ s: Session, _ p: JSON) throws -> JSON {
        switch Cmd.strParam(p, "as") ?? "destinationTheme" {
        case "destinationTheme", "useDestinationTheme":
            return try paste(s, .emptyObject)
        case "text", "keepTextOnly":
            return try pasteText(s, .emptyObject)
        case "keepSource", "keepSourceFormatting":
            let saved = s.clipboard
            if let (scheme, fonts) = saved.sourceTheme { bakeTheme(&s.clipboard.shapes, scheme, fonts) }
            let r = Result(catching: { try paste(s, .emptyObject) })
            let pastes = s.clipboard.pastes
            s.clipboard = saved
            s.clipboard.pastes = pastes
            return try r.get()
        case "picture":
            return try pastePicture(s)
        case let other:
            throw Cmd.bad("edit.pasteSpecial", "unknown `as`: \(other) (destinationTheme, keepSource, picture, text)")
        }
    }

    /// Replace theme colours and theme fonts with the values they have in `scheme` / `fonts`, so the
    /// shapes keep their look under another theme.
    public static func bakeTheme(_ shapes: inout [Shape], _ scheme: ColorScheme, _ fonts: FontScheme) {
        func rec(_ v: inout JSON, _ depth: Int) {
            if depth > 256 { return }
            switch v {
            case .object(var o):
                if o["kind"]?.asStr == "scheme", let raw = o["slot"], let slot = try? SchemeSlot(fromJSON: raw), slot != .phClr {
                    v = ["kind": "rgb", "rgb": scheme.get(slot).toJSON()]
                    return
                }
                var entries = o.entries
                for i in entries.indices { rec(&entries[i].value, depth + 1) }
                o = JSONObject(entries)
                v = .object(o)
            case .array(var a):
                for i in a.indices { rec(&a[i], depth + 1) }
                v = .array(a)
            case .string(let t) where t.utf8.first == UInt8(ascii: "+"):
                let b = Array(t.utf8)
                guard b.count >= 3 else { return }
                let set: FontSet
                switch String(decoding: b[1 ..< 3], as: UTF8.self) {
                case "mj": set = fonts.major
                case "mn": set = fonts.minor
                default: return
                }
                let face: String
                switch String(decoding: b[3...], as: UTF8.self) {
                case "-lt": face = set.latin
                case "-ea": face = set.ea
                case "-cs": face = set.cs
                default: return
                }
                if !face.isEmpty { v = .string(face) }
            default:
                break
            }
        }
        for i in shapes.indices {
            var v = shapes[i].toJSON()
            rec(&v, 0)
            if let baked = try? Shape(fromJSON: v) { shapes[i] = baked }
        }
    }

    /// Paste Special › Picture: the copied shapes drawn into one PNG picture.
    private static func pastePicture(_ s: Session) throws -> JSON {
        var clip = s.clipboard
        if clip.shapes.isEmpty { throw Cmd.bad("edit.pasteSpecial", "copy shapes first to paste them as a picture") }
        if let (scheme, fonts) = clip.sourceTheme { bakeTheme(&clip.shapes, scheme, fonts) }
        let st = try s.doc()
        var doc = st.doc
        let media = try bringMedia("edit.pasteSpecial", &doc, clip.media)
        MediaRefs.VisitMut.shapes(&clip.shapes, remapMedia(media))
        guard var slide = st.currentSlide else { throw Cmd.bad("edit.pasteSpecial", "no slide") }
        let xs = clip.shapes.compactMap(\.xfrm)
        guard let b = ArrangeCommands.unionBounds(xs) else { throw Cmd.bad("edit.pasteSpecial", "nothing to draw") }
        let gx = Xfrm(b.x0, b.y0, b.width, b.height)
        let gid = ShapeId(UInt32.max - 1)
        var one: Shape
        if clip.shapes.count == 1 {
            one = clip.shapes[0]
            one.id = gid
        } else {
            one = Shape.default
            one.id = gid
            one.xfrm = gx
            one.kind = .group(children: clip.shapes, child: gx)
        }
        slide.shapes = [one]
        let scale = 2.0
        guard let img = renderShape(doc, slide, gid, scale) else { throw Cmd.bad("edit.pasteSpecial", "the shapes could not be drawn") }
        // renderShape draws the bounds plus an 8 pt margin (room for shadows and outlines).
        let (w, h) = (Double(img.width) / scale, Double(img.height) / scale)
        let sameSlide = clip.shapes.contains { st.shape($0.id) != nil }
        let off = sameSlide ? s.prefs.duplicateOffset : 0
        let png = ImageEncoding.png(img)
        return try s.execute("insert.picture", [
            "data": .string(Cmd.base64Encode(png)), "name": "Picture.png",
            "rect": [.num(b.x0 - 8 + off), .num(b.y0 - 8 + off), .num(w), .num(h)],
        ])
    }

    @Sendable static func pasteText(_ s: Session, _ p: JSON) throws -> JSON {
        let t = Cmd.strParam(p, "text") ?? s.clipboard.plain
        return try pastePlain(s, t)
    }

    @Sendable static func duplicate(_ s: Session, _ p: JSON) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        let off = s.prefs.duplicateOffset
        let last = try s.doc().lastDuplicate
        let (newIds, made): ([ShapeId], LastDuplicate) = try s.edit { doc, sel in
            let list = Cmd.currentShapes(doc, sel) ?? []
            var copies = list.filter { ids.contains($0.id) }
            let sources = copies.map(\.id)
            let boxes = copies.map { Cmd.xfrmOf(doc, sel, $0) }
            // Duplicating the copies of the last Duplicate again repeats how far they were moved since
            // (#966); anything else gets the usual offset.
            var d = (off, off)
            if let l = last, l.slide == sel.slide, l.target == sel.target, l.pairs.count == sources.count,
               l.pairs.allSatisfy({ sources.contains($0.1) }), let (src, cp) = l.pairs.first,
               let a = list.first(where: { $0.id == src }).map({ Cmd.xfrmOf(doc, sel, $0) }),
               let b = list.first(where: { $0.id == cp }).map({ Cmd.xfrmOf(doc, sel, $0) }) {
                let dd = (b.x - a.x, b.y - a.y)
                if dd.0.isFinite && dd.1.isFinite { d = dd }
            }
            try reid("edit.duplicate", &doc, &copies)
            for i in copies.indices {
                guard i < boxes.count else { break }
                var x = boxes[i]
                x.x += d.0
                x.y += d.1
                copies[i].xfrm = x
                if sel.target == .slides { copies[i].ph = nil }
                if !copies[i].name.isEmpty {
                    var base = copies[i].name
                    while base.hasSuffix(" copy") { base = String(base.dropLast(5)) }
                    copies[i].name = "\(base) copy"
                }
            }
            let newIds = copies.map(\.id)
            try withShapes(&doc, sel, missing: Cmd.bad("edit.duplicate", "no slide")) { $0 += copies }
            sel.shapes = newIds
            let made = LastDuplicate(slide: sel.slide, target: sel.target, pairs: Array(zip(sources, newIds)))
            return (newIds, made)
        }
        try s.docMut().lastDuplicate = made
        return ["ids": newIds.toJSON()]
    }

    @Sendable static func delete(_ s: Session, _ p: JSON) throws -> JSON {
        if try s.doc().selection.text != nil && Cmd.idsParam(p, "ids") == nil {
            return try TextCommands.deleteDir(s, "forward")
        }
        if slidesScope(s, p) && Cmd.idsParam(p, "ids") == nil {
            return try s.execute("slide.delete", .emptyObject)
        }
        // With table cells selected, Delete clears their text and keeps the table, as in PowerPoint.
        let sel0 = try s.doc().selection
        if Cmd.idsParam(p, "ids") == nil && p.get("id") == nil, let c = sel0.cells, sel0.shapes == [c.table] {
            return try TableCommands.clearSelectedCells(s)
        }
        let ids = try Cmd.targets(s, p)
        if ids.isEmpty { return Cmd.ok() }
        return try s.edit { doc, sel in
            let (n, gone) = try withShapes(&doc, sel, missing: Cmd.bad("edit.delete", "no slide")) { shapes -> (Int, [ShapeId]) in
                var before: [ShapeId] = []
                walk(shapes) { s, _ in before.append(s.id) }
                let n = removeShapes(&shapes, ids)
                // Everything that is gone: the given ids plus group descendants and emptied groups.
                var left = Set<ShapeId>()
                walk(shapes) { s, _ in left.insert(s.id) }
                return (n, ids + before.filter { !left.contains($0) })
            }
            // Animations of deleted shapes go too.
            if sel.target == .slides, sel.slide >= 0, sel.slide < doc.slides.count {
                doc.slides[sel.slide].animations.removeAll { gone.contains($0.shape) }
                // Effects triggered by a deleted shape fall back to the main sequence.
                for i in doc.slides[sel.slide].animations.indices {
                    if let t = doc.slides[sel.slide].animations[i].trigger, gone.contains(t) { doc.slides[sel.slide].animations[i].trigger = nil }
                }
            }
            sel.shapes.removeAll { ids.contains($0) }
            sel.text = nil
            return ["deleted": .integer(n)]
        }
    }

    /// Remove shapes by id anywhere in the tree; empty groups go too.
    @discardableResult
    public static func removeShapes(_ shapes: inout [Shape], _ ids: [ShapeId]) -> Int {
        let before = count(shapes)
        func rec(_ v: inout [Shape], _ depth: Int) {
            v.removeAll { ids.contains($0.id) }
            if depth > 64 { return }
            for i in v.indices { v[i].mutateChildren { rec(&$0, depth + 1) } }
            v.removeAll { $0.isGroup && $0.children.isEmpty }
        }
        rec(&shapes, 0)
        return max(before - count(shapes), 0)
    }

    private static func count(_ v: [Shape]) -> Int {
        var n = 0
        walk(v) { _, _ in n += 1 }
        return n
    }

    @Sendable static func selectAll(_ s: Session, _ p: JSON) throws -> JSON {
        switch p.get("scope") {
        case nil, .null?: break
        case .string(let v)? where v == "slides": return try selectAllSlides(s)
        default: throw Cmd.bad("edit.selectAll", "scope must be \"slides\"")
        }
        if try s.doc().selection.text != nil { return try s.execute("text.selectAll", .emptyObject) }
        try s.select { _, sel in sel.text = nil }
        let ids = try s.doc().shapes.filter { !$0.hidden && !$0.locked }.map(\.id)
        try s.select { _, sel in sel.shapes = ids }
        return ["ids": ids.toJSON()]
    }

    /// Thumbnail-pane / sorter select all: every slide, hidden ones included. The current slide stays
    /// where it is (the canvas must not jump), so this is not `slide.selectSlides`.
    private static func selectAllSlides(_ s: Session) throws -> JSON {
        if try s.doc().selection.target != .slides {
            throw Cmd.bad("edit.selectAll", "the slide list is not shown while editing a master")
        }
        let ids = try s.doc().doc.slides.map(\.id)
        try s.select { _, sel in
            sel.slides = ids
            sel.shapes.removeAll()
            sel.text = nil
            sel.cells = nil
        }
        return ["selected": ids.toJSON()]
    }

    @Sendable static func deselect(_ s: Session, _ p: JSON) throws -> JSON {
        s.painter = nil
        s.animPainter = nil
        try s.select { _, sel in
            if let t = sel.text {
                sel.text = nil
                // Esc while editing text selects the shape.
                if !t.notes { sel.shapes = [t.shape] }
            } else {
                sel.shapes.removeAll()
                sel.cells = nil
            }
        }
        return Cmd.ok()
    }

    @Sendable static func select(_ s: Session, _ p: JSON) throws -> JSON {
        let ids: [ShapeId]
        if let v = Cmd.idsParam(p, "ids") {
            ids = v
        } else {
            ids = try Cmd.idParam(p, "id", "edit.select").map { [$0] } ?? []
        }
        let add = Cmd.boolOr(p, "add", false)
        let toggle = Cmd.boolOr(p, "toggle", false)
        let valid = ids.filter { s.activeDoc?.shape($0) != nil }
        try s.select { _, sel in
            sel.text = nil
            sel.cells = nil
            if toggle {
                for i in valid {
                    if let k = sel.shapes.firstIndex(of: i) { sel.shapes.remove(at: k) } else { sel.shapes.append(i) }
                }
            } else if add {
                for i in valid where !sel.shapes.contains(i) { sel.shapes.append(i) }
            } else {
                sel.shapes = valid
            }
        }
        return try ["selected": s.doc().selection.shapes.toJSON()]
    }
}
