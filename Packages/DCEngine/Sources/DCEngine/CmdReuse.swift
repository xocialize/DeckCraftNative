// DCEngine — the `reuse` command module: Home ▸ New Slide ▸ Reuse Slides, slides from another presentation.
//
// The slides take the destination's look by default (each one moves to the destination layout with the same
// name, else the same kind); with `keepFormatting` the source master and its layouts come along. Pictures,
// media and sounds are copied under fresh ids, and shape ids are renumbered with animations, triggers and
// connector ends following them. Links to another reused slide follow its copy.
// Port of deckcraft crates/engine/src/cmd/reuse.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum ReuseCommands {
    public static func specs() -> [CommandSpec] {
        [
            .query(
                "slide.reuseList",
                "List Slides to Reuse",
                [],
                nil,
                "{path | data: base64, name?} → {name, slides: [{index, title, hidden}]}: the slides of another presentation, for choosing which ones `slide.reuse` brings in",
                Cmd.hasDoc,
                reuseList
            ),
            .cmd(
                "slide.reuse",
                "Reuse Slides…",
                ["Home", "Slides", "New Slide"],
                nil,
                "{path? | data: base64, name?, slides?: [index] (0-based, default all), keepFormatting?: bool (default false: use the destination theme), at?: index (default after the current slide)}",
                Cmd.hasDoc,
                reuse
            ),
        ]
    }

    @Sendable static func reuseList(_ s: Session, _ p: JSON) throws -> JSON {
        let (name, bytes) = try InsertCommands.mediaBytes(p, "slide.reuseList")
        let src = try FileCommands.openPresentation(name, bytes)
        let slides: [JSON] = src.slides.enumerated().map { index, sl in
            ["index": .integer(index), "title": .string(sl.title), "hidden": .bool(sl.hidden)]
        }
        return ["name": .string(name), "slides": .array(slides)]
    }

    /// Point a media id at its copy in the destination (`map`: source → destination).
    static func remap(_ map: [MediaId: MediaId]) -> MediaRefs.VisitMut.F {
        { id in if let to = map[id] { id = to } }
    }

    static func shapeIds(_ shapes: [Shape]) -> [ShapeId] {
        var v: [ShapeId] = []
        walk(shapes) { sh, _ in v.append(sh.id) }
        return v
    }

    /// Point connector ends at the renumbered shapes.
    static func remapConnectors(_ shapes: inout [Shape], _ map: [ShapeId: ShapeId], _ depth: Int) {
        if depth > 64 { return }
        for i in shapes.indices {
            if case .connector(let start, let end) = shapes[i].kind {
                let a = start.map { Pair(map[$0.a] ?? $0.a, $0.b) }
                let b = end.map { Pair(map[$0.a] ?? $0.a, $0.b) }
                shapes[i].kind = .connector(start: a, end: b)
            }
            if shapes[i].isGroup {
                shapes[i].mutateChildren { remapConnectors(&$0, map, depth + 1) }
            }
        }
    }

    /// Point a link to a reused slide at its copy (`map`: source → destination).
    static func relink(_ h: inout Hyperlink?, _ map: [SlideId: SlideId]) {
        guard var link = h else { return }
        if case .slide(let slide) = link.action { link.action = .slide(slide: map[slide] ?? slide) }
        if let z = link.zoomReturn { link.zoomReturn = map[z] ?? z }
        h = link
    }

    static func relinkRun(_ r: inout RunProps, _ map: [SlideId: SlideId]) {
        relink(&r.link, map)
        relink(&r.hover, map)
    }

    static func relinkText(_ t: inout TextBody, _ map: [SlideId: SlideId]) {
        for i in t.listStyle.levels.indices {
            if var lv = t.listStyle.levels[i] {
                relinkRun(&lv.run, map)
                t.listStyle.levels[i] = lv
            }
        }
        for pi in t.paragraphs.indices {
            relinkRun(&t.paragraphs[pi].defProps, map)
            relinkRun(&t.paragraphs[pi].endProps, map)
            for ri in t.paragraphs[pi].runs.indices { relinkRun(&t.paragraphs[pi].runs[ri].props, map) }
        }
    }

    /// Point the slide links under `shapes` (click and hover actions, text links) at the copies.
    static func relinkShapes(_ shapes: inout [Shape], _ map: [SlideId: SlideId], _ depth: Int) {
        if depth > 64 { return }
        for i in shapes.indices {
            relink(&shapes[i].click, map)
            relink(&shapes[i].hover, map)
            if var t = shapes[i].text {
                relinkText(&t, map)
                shapes[i].text = t
            }
            if case .table(var t) = shapes[i].kind {
                for r in t.rows.indices {
                    for c in t.rows[r].cells.indices { relinkText(&t.rows[r].cells[c].text, map) }
                }
                shapes[i].kind = .table(t)
            }
            if shapes[i].isGroup {
                shapes[i].mutateChildren { relinkShapes(&$0, map, depth + 1) }
            }
        }
    }

    /// Fresh shape ids for `shapes`, and the old → new map.
    @discardableResult
    static func renumber(_ cmd: String, _ doc: inout Presentation, _ shapes: inout [Shape]) throws -> [ShapeId: ShapeId] {
        let old = shapeIds(shapes)
        try EditCommands.reid(cmd, &doc, &shapes)
        var map: [ShapeId: ShapeId] = [:]
        for (o, n) in zip(old, shapeIds(shapes)) { map[o] = n }
        remapConnectors(&shapes, map, 0)
        return map
    }

    /// The destination layout a reused slide moves to: same name, else same kind, else the first.
    static func matchingLayout(_ doc: Presentation, _ name: String, _ kind: LayoutType) -> LayoutId {
        let all = doc.masters.flatMap(\.layouts)
        if !name.isEmpty, let l = all.first(where: { InsertCommands.eqIgnoreASCIICase($0.name, name) }) { return l.id }
        if let l = all.first(where: { $0.kind == kind }) { return l.id }
        return all.first?.id ?? .default
    }

    @Sendable static func reuse(_ s: Session, _ p: JSON) throws -> JSON {
        let (name, bytes) = try InsertCommands.mediaBytes(p, "slide.reuse")
        let src = try FileCommands.openPresentation(name, bytes)
        let n = src.slides.count
        var picked: [Int] = []
        switch p.get("slides") {
        case .array(let a)?:
            for x in a {
                guard let i = x.asU64.flatMap({ Int(exactly: $0) }), i < n else {
                    throw Cmd.bad("slide.reuse", "\(name) has \(n) slides; \(x.display) isn't one of them (indices count from 0)")
                }
                if !picked.contains(i) { picked.append(i) }
            }
        case .string(let t)? where !rustTrim(t).isEmpty:
            picked = try FileCommands.parseSlideRange(t, n)
        default:
            picked = Array(0 ..< n)
        }
        if picked.isEmpty { throw Cmd.bad("slide.reuse", "\(name) has no slides to reuse") }
        let keep = Cmd.boolOr(p, "keepFormatting", false)
        let atParam = Cmd.usizeParam(p, "at")
        return try s.edit { doc, sel in
            let at = min(atParam ?? (sel.slide + 1), doc.slides.count)
            // Media: what the slides use is copied under fresh ids.
            var mediaMap: [MediaId: MediaId] = [:]
            // Keep Source Formatting: bring each source master used, once, with fresh ids.
            var layoutMap: [LayoutId: LayoutId] = [:]
            if keep {
                var mastersDone: [MasterId] = []
                for i in picked {
                    guard let sl = src.slides.at(i), let (m, _) = src.masterFor(sl) else { continue }
                    if mastersDone.contains(m.id) { continue }
                    mastersDone.append(m.id)
                    let copy = try importMaster("slide.reuse", &doc, src, m, &mediaMap, &layoutMap)
                    doc.masters.append(copy)
                }
            }
            var copies: [Slide] = []
            // Source slide → its copy, so links between reused slides follow (forward ones too).
            var slideMap: [SlideId: SlideId] = [:]
            for i in picked {
                guard let from = src.slides.at(i) else { continue }
                try copyMedia("slide.reuse", &doc, src, MediaRefs.slideMedia(from), &mediaMap)
                var sl = from
                MediaRefs.VisitMut.slide(&sl, remap(mediaMap))
                guard let sid = doc.allocId() else { throw Cmd.bad("slide.reuse", Cmd.noIdSpace) }
                sl.id = SlideId(sid)
                let map = try renumber("slide.reuse", &doc, &sl.shapes)
                for k in sl.animations.indices {
                    sl.animations[k].shape = map[sl.animations[k].shape] ?? sl.animations[k].shape
                    sl.animations[k].trigger = sl.animations[k].trigger.map { map[$0] ?? $0 }
                }
                if let l = layoutMap[sl.layout] {
                    sl.layout = l
                } else {
                    let (lname, kind) = src.layout(from.layout).map { ($0.layout.name, $0.layout.kind) } ?? ("", LayoutType.default)
                    sl.layout = matchingLayout(doc, lname, kind)
                }
                slideMap[from.id] = sl.id
                copies.append(sl)
            }
            var newIds: [SlideId] = []
            for (k, var sl) in copies.enumerated() {
                relinkShapes(&sl.shapes, slideMap, 0)
                relinkText(&sl.notes, slideMap)
                newIds.append(sl.id)
                doc.slides.insert(sl, at: min(at + k, doc.slides.count))
            }
            sel.slide = min(max(at + newIds.count - 1, 0), max(doc.slides.count - 1, 0))
            sel.slides = newIds
            sel.shapes.removeAll()
            sel.text = nil
            return [
                "slides": .integer(newIds.count), "ids": newIds.toJSON(), "from": .string(name), "keepFormatting": .bool(keep),
            ]
        }
    }

    /// A copy of `src`'s master `m` ready to join `doc`: its media copied in, fresh master, layout and shape
    /// ids. `layouts` gains each source layout id → its copy's (`import_master`).
    public static func importMaster(
        _ cmd: String, _ doc: inout Presentation, _ src: Presentation, _ m: Master,
        _ mediaMap: inout [MediaId: MediaId], _ layouts: inout [LayoutId: LayoutId]
    ) throws -> Master {
        var used: [MediaId] = []
        MediaRefs.Visit.master(m) { used.append($0) }
        try copyMedia(cmd, &doc, src, used, &mediaMap)
        var m = m
        MediaRefs.VisitMut.master(&m, remap(mediaMap))
        guard let mid = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
        m.id = MasterId(mid)
        try renumber(cmd, &doc, &m.shapes)
        for i in m.layouts.indices {
            guard let lid = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
            let new = LayoutId(lid)
            layouts[m.layouts[i].id] = new
            m.layouts[i].id = new
            try renumber(cmd, &doc, &m.layouts[i].shapes)
        }
        return m
    }

    /// Copy the source media `used` into `doc` under fresh ids, once each (identical bytes already in `doc`
    /// are shared; a linked item keeps its link).
    static func copyMedia(_ cmd: String, _ doc: inout Presentation, _ src: Presentation, _ used: [MediaId], _ map: inout [MediaId: MediaId]) throws {
        for id in used {
            if map[id] != nil { continue }
            guard let m = src.media(id) else { continue }
            let new: MediaId
            if m.link != nil {
                var item = m
                guard let raw = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                item.id = MediaId(raw)
                new = item.id
                doc.media.append(item)
            } else {
                guard let added = doc.addMedia(m.name, m.contentType, m.data) else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                new = added
            }
            map[id] = new
        }
    }
}
