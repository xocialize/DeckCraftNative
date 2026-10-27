// DCEngine — slides: new, duplicate, delete, move, layout, reset, hide, notes, sections, navigation.
// Port of deckcraft crates/engine/src/cmd/slide.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCFormat
import DCModel

public enum SlideCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "slide.new",
                "New Slide",
                ["Home", "Slides"],
                "Cmd+Shift+N",
                "{layout?: layout name or kind (title, titleAndContent, sectionHeader, twoContent, comparison, titleOnly, blank, contentWithCaption, pictureWithCaption), at?: index, title?: text, body?: text}",
                Cmd.hasDoc,
                new
            ),
            .cmd("slide.duplicate", "Duplicate Slide", ["Insert"], nil, "{index?}", Cmd.hasSlide, duplicate),
            .cmd("slide.delete", "Delete Slide", ["Edit"], nil, "{index?, ids?: [slide id]}", Cmd.hasSlide, delete),
            .cmd("slide.move", "Move Slide", [], nil, "{from?: index, to: index}", Cmd.hasSlide, moveSlide),
            .noundo("slide.go", "Go to Slide", [], nil, "{index} | {id}", Cmd.hasSlide, go),
            .noundo("slide.next", "Next Slide", [], "PageDown", "{}", Cmd.hasSlide, next),
            .noundo("slide.previous", "Previous Slide", [], "PageUp", "{}", Cmd.hasSlide, prev),
            .noundo("slide.first", "First Slide", [], "Home", "{}", Cmd.hasSlide, first),
            .noundo("slide.last", "Last Slide", [], "End", "{}", Cmd.hasSlide, last),
            .noundo("slide.selectRange", "Select Slide Range", [], nil, "{to: index, from?: index (default the current slide), add?: bool (keep the slides already selected)}", Cmd.hasSlide, selectRange),
            .noundo("slide.selectSlides", "Select Slides", [], nil, "{ids?: [slide id], indices?: [index], add?: bool}", Cmd.hasSlide, selectSlides),
            .cmd("slide.hide", "Hide Slide", ["Slide Show", "Set Up"], nil, "{index?, hidden?: bool}", Cmd.hasSlide, hide),
            .cmd("slide.layout", "Layout", ["Home", "Slides"], nil, "{layout: name or kind, index?}", Cmd.hasSlide, setLayout),
            .cmd("slide.reset", "Reset", ["Home", "Slides"], nil, "{index?}", Cmd.hasSlide, reset),
            .cmd(
                "slide.notes",
                "Notes",
                ["View"],
                nil,
                "{text | body: formatted notes (as in slide.inspect's notesBody), index?} (text as typed: untouched notes keep their formatting)",
                Cmd.hasSlide,
                notes
            ),
            .cmd("slide.rename", "Rename Slide", [], nil, "{name, index?}", Cmd.hasSlide, rename),
            .cmd("section.add", "Add Section", ["Home", "Slides", "Section"], nil, "{name?, at?: slide index}", Cmd.hasSlide, sectionAdd),
            .cmd("section.rename", "Rename Section", ["Home", "Slides", "Section"], nil, "{index, name}", Cmd.hasSlide, sectionRename),
            .cmd(
                "section.remove",
                "Remove Section",
                ["Home", "Slides", "Section"],
                nil,
                "{index, slides?: bool (also delete its slides)}",
                Cmd.hasSlide,
                sectionRemove
            ),
            .cmd("section.removeAll", "Remove All Sections", ["Home", "Slides", "Section"], nil, "{}", Cmd.hasSlide, sectionRemoveAll),
            .cmd("section.move", "Move Section", [], nil, "{index, to}", Cmd.hasSlide, sectionMove),
            .cmd(
                "slide.fromOutline",
                "Slides from Outline…",
                ["Insert", "Slides From"],
                nil,
                "{text, markdown?: bool (headings are slides, list items bullets)}",
                Cmd.hasDoc,
                fromOutline
            ),
        ]
    }

    /// Resolve a layout by id, name or kind keyword.
    public static func findLayout(_ doc: Presentation, _ key: JSON, _ master: Int) -> LayoutId? {
        if let n = key.asU64 {
            guard let raw = UInt32(exactly: n) else { return nil }
            let id = LayoutId(raw)
            if doc.layout(id) != nil { return id }
        }
        guard let s = key.asStr else { return nil }
        guard let m = doc.masters.at(master) ?? doc.masters.first else { return nil }
        func norm(_ x: String) -> String {
            rustASCIILowercase(String(String.UnicodeScalarView(x.unicodeScalars.filter { $0.properties.isAlphabetic || [.decimalNumber, .letterNumber, .otherNumber].contains($0.properties.generalCategory) })))
        }
        let k = norm(s)
        let kind: LayoutType? = switch k {
        case "title", "titleslide": .title
        case "titleandcontent", "content", "obj": .titleAndContent
        case "sectionheader", "section": .sectionHeader
        case "twocontent", "two": .twoContent
        case "comparison": .comparison
        case "titleonly": .titleOnly
        case "blank": .blank
        case "contentwithcaption": .contentWithCaption
        case "picturewithcaption", "picture": .pictureWithCaption
        case "titleandverticaltext": .titleAndVerticalText
        case "verticaltitleandtext": .verticalTitleAndText
        default: nil
        }
        if let l = m.layouts.first(where: { Array(norm($0.name).utf8) == Array(k.utf8) }) { return l.id }
        if let kd = kind, let l = m.layouts.first(where: { $0.kind == kd }) { return l.id }
        return nil
    }

    static func currentMaster(_ doc: Presentation, _ sel: Selection) -> Int {
        guard let s = doc.slides.at(sel.slide) else { return 0 }
        return doc.masters.firstIndex { $0.layout(s.layout) != nil } ?? 0
    }

    @Sendable static func new(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, sel in
            let master = currentMaster(doc, sel)
            let layout: LayoutId
            if let k = p.get("layout") {
                guard let l = findLayout(doc, k, master) else { throw Cmd.bad("slide.new", "no layout \(k.display)") }
                layout = l
            } else {
                // PowerPoint picks Title and Content after a title slide, else the current layout.
                let cur = doc.slides.at(sel.slide)?.layout
                let isTitle = cur.flatMap { doc.layout($0) }.map { $0.layout.kind == .title } ?? false
                if let c = cur, !isTitle {
                    layout = c
                } else {
                    layout = layoutOfKind(doc, .titleAndContent) ?? cur ?? .default
                }
            }
            guard var slide = newSlide(&doc, layout) else { throw Cmd.bad("slide.new", Cmd.noIdSpace) }
            if let t = Cmd.strParam(p, "title"), let i = slide.shapes.firstIndex(where: { $0.phType?.isTitle == true }) {
                slide.shapes[i].text = TextBody.fromText(t)
            }
            if let b = Cmd.strParam(p, "body"), let i = bodyPlaceholder(slide.shapes) {
                var body = TextBody.fromText(b)
                // Leading tabs set the outline level, as in text.set.
                for k in body.paragraphs.indices { TextCommands.applyLeadingTabs(&body.paragraphs[k]) }
                slide.shapes[i].text = body
            }
            let at = min(Cmd.usizeParam(p, "at") ?? (doc.slides.isEmpty ? 0 : sel.slide + 1), doc.slides.count)
            let id = slide.id
            // Inherit the section of the slide before.
            let section = at > 0 ? doc.slides.at(at - 1).flatMap { doc.sectionOf($0.id) } : nil
            doc.slides.insert(slide, at: at)
            if let si = section, si < doc.sections.count {
                let prevId = at > 0 ? doc.slides.at(at - 1)?.id : nil
                let pos = prevId.flatMap { pid in doc.sections[si].slides.firstIndex(of: pid) }.map { $0 + 1 } ?? doc.sections[si].slides.count
                doc.sections[si].slides.insert(id, at: min(pos, doc.sections[si].slides.count))
            } else if !doc.sections.isEmpty {
                doc.sections[0].slides.insert(id, at: 0)
            }
            sel.slide = at
            sel.slides = [id]
            sel.shapes.removeAll()
            sel.text = nil
            sel.target = .slides
            return ["index": .integer(at), "id": id.toJSON()]
        }
    }

    /// The placeholder a new slide's `body` goes into: the layout's main content placeholder. Prefers
    /// `idx="1"` (the content slot PowerPoint fills), then a full-size text placeholder over a
    /// `half`/`quarter` one, then a text placeholder over a picture/chart/table one; ties keep shape order.
    static func bodyPlaceholder(_ shapes: [Shape]) -> Int? {
        func rank(_ sh: Shape) -> (Bool, Bool, Bool)? {
            guard let ph = sh.ph, !ph.kind.isTitle else { return nil }
            let text = ph.kind == .body || ph.kind == .obj || ph.kind == .subTitle
            let small = ph.size == "half" || ph.size == "quarter"
            return (ph.idx != 1, small, !text)
        }
        func less(_ a: (Bool, Bool, Bool), _ b: (Bool, Bool, Bool)) -> Bool {
            if a.0 != b.0 { return !a.0 }
            if a.1 != b.1 { return !a.1 }
            if a.2 != b.2 { return !a.2 }
            return false
        }
        var best: ((Bool, Bool, Bool), Int)?
        for (i, sh) in shapes.enumerated() {
            guard let r = rank(sh) else { continue }
            if let b = best {
                if less(r, b.0) { best = (r, i) }
            } else {
                best = (r, i)
            }
        }
        return best?.1
    }

    static func indexOf(_ s: Session, _ p: JSON) throws -> Int {
        let st = try s.doc()
        let i = try Cmd.optUsizeParam(p, "index", "slide") ?? st.selection.slide
        if i >= st.doc.slides.count { throw Cmd.bad("slide", "no slide \(i)") }
        return i
    }

    @Sendable static func duplicate(_ s: Session, _ p: JSON) throws -> JSON {
        let indices: [Int]
        if let i = try Cmd.optUsizeParam(p, "index", "slide.duplicate") {
            indices = [i]
        } else {
            let st = try s.doc()
            var v = st.selection.slides.compactMap { st.doc.slideIndex($0) }
            if v.isEmpty { v.append(st.selection.slide) }
            indices = v.sorted()
        }
        return try s.edit { doc, sel in
            let last = indices.last ?? 0
            var newIds: [SlideId] = []
            for (k, i) in indices.enumerated() {
                guard var copy = doc.slides.at(i) else { continue }
                guard let raw = doc.allocId() else { throw Cmd.bad("slide.duplicate", Cmd.noIdSpace) }
                copy.id = SlideId(raw)
                // Animations follow the new shape ids, triggers included.
                let map = try EditCommands.reid("slide.duplicate", &doc, &copy.shapes)
                EditCommands.remapAnimations(&copy.animations, map)
                let section = doc.sectionOf(doc.slides.at(i)?.id ?? .default)
                let at = min(last + 1 + k, doc.slides.count)
                newIds.append(copy.id)
                let nid = copy.id
                doc.slides.insert(copy, at: at)
                if let si = section, si < doc.sections.count {
                    doc.sections[si].slides.append(nid)
                    // Keep the section list in document order so the copy sits next to its source.
                    sortByOrder(&doc.sections[si].slides, doc.slides.map(\.id))
                }
            }
            sel.slide = min(last + newIds.count, max(doc.slides.count - 1, 0))
            sel.slides = newIds
            sel.shapes.removeAll()
            sel.text = nil
            return ["ids": newIds.toJSON()]
        }
    }

    /// `sort_by_key(position in order, else usize::MAX)`: a stable sort.
    static func sortByOrder(_ ids: inout [SlideId], _ order: [SlideId]) {
        var pos: [SlideId: Int] = [:]
        for (i, o) in order.enumerated() where pos[o] == nil { pos[o] = i }
        ids = ids.enumerated().sorted { a, b in
            let ka = pos[a.element] ?? Int.max
            let kb = pos[b.element] ?? Int.max
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
    }

    @Sendable static func delete(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let ids: [SlideId]
        if let a = p.get("ids")?.asArray {
            ids = a.compactMap(\.asU32).map(SlideId.init)
        } else if let i = try Cmd.optUsizeParam(p, "index", "slide.delete") {
            ids = st.doc.slides.at(i).map { [$0.id] } ?? []
        } else if !st.selection.slides.isEmpty {
            ids = st.selection.slides
        } else {
            ids = st.currentSlide.map { [$0.id] } ?? []
        }
        if ids.isEmpty { throw Cmd.bad("slide.delete", "no such slide") }
        return try s.edit { doc, sel in
            let first = ids.compactMap { doc.slideIndex($0) }.min() ?? 0
            doc.slides.removeAll { ids.contains($0.id) }
            for i in doc.sections.indices { doc.sections[i].slides.removeAll { ids.contains($0) } }
            sel.slide = min(first, max(doc.slides.count - 1, 0))
            sel.slides = doc.slides.at(sel.slide).map { [$0.id] } ?? []
            sel.shapes.removeAll()
            sel.text = nil
            return ["deleted": .integer(ids.count), "remaining": .integer(doc.slides.count)]
        }
    }

    @Sendable static func moveSlide(_ s: Session, _ p: JSON) throws -> JSON {
        let from = try Cmd.optUsizeParam(p, "from", "slide.move") ?? s.doc().selection.slide
        guard let to0 = Cmd.usizeParam(p, "to") else { throw Cmd.bad("slide.move", "missing `to`") }
        return try s.edit { doc, sel in
            if from >= doc.slides.count { throw Cmd.bad("slide.move", "no slide \(from)") }
            let sl = doc.slides.remove(at: from)
            let to = min(to0, doc.slides.count)
            let id = sl.id
            doc.slides.insert(sl, at: to)
            // Keep sections consistent with order: move the id into the section of its new neighbour.
            if !doc.sections.isEmpty {
                for i in doc.sections.indices { doc.sections[i].slides.removeAll { $0 == id } }
                let neighbour = to > 0 ? doc.slides.at(to - 1)?.id : nil
                let si = neighbour.flatMap { doc.sectionOf($0) } ?? 0
                if si < doc.sections.count {
                    doc.sections[si].slides.append(id)
                    sortByOrder(&doc.sections[si].slides, doc.slides.map(\.id))
                }
            }
            sel.slide = to
            sel.slides = [id]
            return ["index": .integer(to)]
        }
    }

    private static func goTo(_ s: Session, _ i: Int) throws -> JSON {
        try s.select { doc, sel in
            let n = doc.slides.count
            sel.slide = min(i, max(n - 1, 0))
            sel.slides = doc.slides.at(sel.slide).map { [$0.id] } ?? []
            sel.shapes.removeAll()
            sel.text = nil
            sel.cells = nil
            sel.rangeAnchor = nil
            sel.target = .slides
        }
        return try ["index": .integer(s.doc().selection.slide)]
    }

    @Sendable static func go(_ s: Session, _ p: JSON) throws -> JSON {
        let i: Int
        if let idx = Cmd.usizeParam(p, "index") {
            i = idx
        } else if let id = p.get("id")?.asU64 {
            guard let raw = UInt32(exactly: id) else { throw Cmd.bad("slide.go", "no such slide") }
            guard let idx = try s.doc().doc.slideIndex(SlideId(raw)) else { throw Cmd.bad("slide.go", "no such slide") }
            i = idx
        } else {
            throw Cmd.bad("slide.go", "missing `index`")
        }
        if try i >= s.doc().doc.slides.count { throw Cmd.bad("slide.go", "no slide \(i)") }
        return try goTo(s, i)
    }

    @Sendable static func next(_ s: Session, _ p: JSON) throws -> JSON { try goTo(s, s.doc().selection.slide + 1) }
    @Sendable static func prev(_ s: Session, _ p: JSON) throws -> JSON { try goTo(s, max(s.doc().selection.slide - 1, 0)) }
    @Sendable static func first(_ s: Session, _ p: JSON) throws -> JSON { try goTo(s, 0) }
    @Sendable static func last(_ s: Session, _ p: JSON) throws -> JSON { try goTo(s, max(s.doc().doc.slides.count - 1, 0)) }

    @Sendable static func selectSlides(_ s: Session, _ p: JSON) throws -> JSON {
        let add = Cmd.boolOr(p, "add", false)
        let st = try s.doc()
        var ids: [SlideId] = p.get("ids")?.asArray.map { $0.compactMap(\.asU32).map(SlideId.init) } ?? []
        if let a = p.get("indices")?.asArray {
            ids += a.compactMap(\.asU64).compactMap { i in Int(exactly: i).flatMap { st.doc.slides.at($0) }?.id }
        }
        let chosen = ids
        try s.select { doc, sel in
            if add {
                for i in chosen where !sel.slides.contains(i) { sel.slides.append(i) }
            } else {
                sel.slides = chosen
            }
            if let last = chosen.last.flatMap({ doc.slideIndex($0) }) { sel.slide = last }
            sel.shapes.removeAll()
            sel.text = nil
            sel.rangeAnchor = nil
        }
        return try ["selected": s.doc().selection.slides.toJSON()]
    }

    /// Shift-click in the slide list: select every slide from `from` to `to`. Without `from` the range
    /// starts at the anchor of the previous Shift-click (so a second Shift-click extends from the same
    /// slide, as in PowerPoint), else at the current slide. With `add` the slides already selected stay
    /// selected (Ctrl+Shift-click).
    @Sendable static func selectRange(_ s: Session, _ p: JSON) throws -> JSON {
        guard let to = Cmd.usizeParam(p, "to") else { throw Cmd.bad("slide.selectRange", "missing `to`") }
        let given = try Cmd.optUsizeParam(p, "from", "slide.selectRange")
        let add = Cmd.boolOr(p, "add", false)
        let st = try s.doc()
        let sel0 = st.selection
        let current = st.doc.slides.at(sel0.slide)?.id
        let anchor = sel0.rangeAnchor.flatMap { $0.1 == current ? st.doc.slideIndex($0.0) : nil }
        let from = given ?? anchor ?? sel0.slide
        let count = st.doc.slides.count
        if to >= count || from >= count { throw Cmd.bad("slide.selectRange", "no such slide") }
        let (a, b) = (min(from, to), max(from, to))
        try s.select { doc, sel in
            let range = doc.slides[a ... b].map(\.id)
            if add {
                for id in range where !sel.slides.contains(id) { sel.slides.append(id) }
            } else {
                sel.slides = range
            }
            sel.slide = to
            if let fa = doc.slides.at(from), let tb = doc.slides.at(to) { sel.rangeAnchor = (fa.id, tb.id) } else { sel.rangeAnchor = nil }
            sel.shapes.removeAll()
            sel.text = nil
            sel.cells = nil
            sel.target = .slides
        }
        return try ["selected": s.doc().selection.slides.toJSON()]
    }

    /// The slide indices a command acts on: `index`, else the selected slides, else the current one.
    private static func targetIndices(_ s: Session, _ p: JSON, _ cmd: String) throws -> [Int] {
        if let i = try Cmd.optUsizeParam(p, "index", cmd) { return [i] }
        let st = try s.doc()
        let v = st.selection.slides.compactMap { st.doc.slideIndex($0) }
        return v.isEmpty ? [st.selection.slide] : v
    }

    @Sendable static func hide(_ s: Session, _ p: JSON) throws -> JSON {
        let targets = try targetIndices(s, p, "slide.hide")
        return try s.edit { doc, _ in
            let allHidden = targets.allSatisfy { doc.slides.at($0)?.hidden ?? false }
            let value = Cmd.boolParam(p, "hidden") ?? !allHidden
            for i in targets where i < doc.slides.count { doc.slides[i].hidden = value }
            return ["hidden": .bool(value)]
        }
    }

    /// Re-map a slide's placeholders onto a new layout (content kept, matched by type/index).
    public static func applyLayout(_ doc: inout Presentation, _ index: Int, _ layout: LayoutId) throws {
        guard let layShapes = doc.layout(layout)?.layout.shapes else { throw Cmd.bad("slide.layout", "no such layout") }
        var fresh: [(ShapeId, Shape)] = []
        for ls in layShapes where ls.ph.map({ !$0.kind.isFooterKind }) ?? false {
            guard let raw = doc.allocId() else { throw Cmd.bad("slide.layout", Cmd.noIdSpace) }
            fresh.append((ShapeId(raw), ls))
        }
        guard index >= 0, index < doc.slides.count else { throw Cmd.bad("slide.layout", "no slide") }
        var old = doc.slides[index].shapes
        doc.slides[index].shapes = []
        var out: [Shape] = []
        for (id, ls) in fresh {
            guard let lph = ls.ph else { continue }
            // Find matching old placeholder: same idx, else same title-ness/compatible type.
            let k = old.firstIndex { o in o.ph.map { $0.kind == lph.kind && ($0.idx == lph.idx || lph.kind.isTitle) } ?? false }
                ?? old.firstIndex { o in o.ph.map { $0.kind.isTitle == lph.kind.isTitle && !$0.kind.isFooterKind } ?? false }
            if let k {
                var o = old.remove(at: k)
                o.ph?.kind = lph.kind
                o.ph?.idx = lph.idx
                o.xfrm = nil
                out.append(o)
            } else {
                var sh = Shape.default
                sh.id = id
                sh.name = ls.name
                sh.ph = lph
                sh.text = .default
                out.append(sh)
            }
        }
        // Leftover placeholders with content stay as they were (positioned); empty ones go.
        for o in old {
            var emptyPh = false
            if o.ph != nil, o.text.map(\.isEmpty) ?? true, case .shape = o.kind { emptyPh = true }
            if !emptyPh { out.append(o) }
        }
        doc.slides[index].shapes = out
        doc.slides[index].layout = layout
    }

    @Sendable static func setLayout(_ s: Session, _ p: JSON) throws -> JSON {
        guard let key = p.get("layout") else { throw Cmd.bad("slide.layout", "missing `layout`") }
        let targets = try targetIndices(s, p, "slide.layout")
        return try s.edit { doc, sel in
            let master = currentMaster(doc, sel)
            guard let layout = findLayout(doc, key, master) else { throw Cmd.bad("slide.layout", "no layout \(key.display)") }
            for i in targets { try applyLayout(&doc, i, layout) }
            sel.shapes.removeAll()
            sel.text = nil
            return ["layout": layout.toJSON()]
        }
    }

    @Sendable static func reset(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try indexOf(s, p)
        try s.edit { doc, sel in
            let layout = doc.slides.at(i)?.layout ?? .default
            try applyLayout(&doc, i, layout)
            if i < doc.slides.count {
                doc.slides[i].background = nil
                for k in doc.slides[i].shapes.indices where doc.slides[i].shapes[k].ph != nil {
                    var sh = doc.slides[i].shapes[k]
                    sh.xfrm = nil
                    sh.fill = nil
                    sh.line = nil
                    sh.effects = nil
                    sh.geom = .default
                    if var t = sh.text {
                        t.body = .default
                        t.listStyle = .default
                        for q in t.paragraphs.indices {
                            t.paragraphs[q].props = .default
                            for r in t.paragraphs[q].runs.indices { t.paragraphs[q].runs[r].props = .default }
                        }
                        sh.text = t
                    }
                    doc.slides[i].shapes[k] = sh
                }
            }
            sel.shapes.removeAll()
        }
        return Cmd.ok()
    }

    @Sendable static func notes(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try indexOf(s, p)
        // Formatted notes as a whole (the notes editors), or text: then only what was retyped changes, so
        // bold, levels and bullets around it survive.
        var body: TextBody?
        if let b = p.get("body") {
            do { body = try TextBody(fromJSON: b) } catch { throw Cmd.bad("slide.notes", "invalid `body`: \(error.description)") }
        }
        let text = Cmd.strParam(p, "text") ?? ""
        let given = body
        try s.edit { doc, _ in
            guard i < doc.slides.count else { return }
            if let b = given {
                doc.slides[i].notes = b
            } else {
                TextEdit.replaceText(&doc.slides[i].notes, text)
            }
        }
        return Cmd.ok()
    }

    @Sendable static func rename(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try indexOf(s, p)
        let name = Cmd.strParam(p, "name") ?? ""
        try s.edit { doc, _ in if i < doc.slides.count { doc.slides[i].name = name } }
        return Cmd.ok()
    }

    @Sendable static func sectionAdd(_ s: Session, _ p: JSON) throws -> JSON {
        let at0 = try Cmd.optUsizeParam(p, "at", "section.add") ?? s.doc().selection.slide
        let name = Cmd.strParam(p, "name") ?? "Untitled Section"
        return try s.edit { doc, _ in
            let at = min(at0, max(doc.slides.count - 1, 0))
            let ids = doc.slides.map(\.id)
            if doc.sections.isEmpty {
                // The slides before `at` go into a "Default Section".
                if at > 0 { doc.sections.append(Section(name: "Default Section", slides: at <= ids.count ? Array(ids[..<at]) : [])) }
                doc.sections.append(Section(name: name, slides: at <= ids.count ? Array(ids[at...]) : []))
            } else {
                guard let start = ids.at(at) else { throw Cmd.bad("section.add", "no slide") }
                let si = doc.sectionOf(start) ?? 0
                guard si < doc.sections.count else { throw Cmd.bad("section.add", "no section") }
                let k = doc.sections[si].slides.firstIndex(of: start) ?? doc.sections[si].slides.count
                let tail = Array(doc.sections[si].slides[k...])
                doc.sections[si].slides.removeSubrange(k...)
                doc.sections.insert(Section(name: name, slides: tail), at: si + 1)
                doc.sections.removeAll { $0.slides.isEmpty && $0.name == "Default Section" }
            }
            return ["sections": .integer(doc.sections.count)]
        }
    }

    @Sendable static func sectionRename(_ s: Session, _ p: JSON) throws -> JSON {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad("section.rename", "missing `index`") }
        let name = Cmd.strParam(p, "name") ?? ""
        try s.edit { doc, _ in
            guard i < doc.sections.count else { throw Cmd.bad("section.rename", "no such section") }
            doc.sections[i].name = name
        }
        return Cmd.ok()
    }

    @Sendable static func sectionRemove(_ s: Session, _ p: JSON) throws -> JSON {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad("section.remove", "missing `index`") }
        let withSlides = Cmd.boolOr(p, "slides", false)
        try s.edit { doc, sel in
            if i >= doc.sections.count { throw Cmd.bad("section.remove", "no such section") }
            let sec = doc.sections.remove(at: i)
            if withSlides {
                doc.slides.removeAll { sec.slides.contains($0.id) }
                sel.slide = min(sel.slide, max(doc.slides.count - 1, 0))
            } else if i > 0, i - 1 < doc.sections.count {
                doc.sections[i - 1].slides += sec.slides
            } else if !doc.sections.isEmpty {
                doc.sections[0].slides = sec.slides + doc.sections[0].slides
            }
        }
        return Cmd.ok()
    }

    @Sendable static func sectionRemoveAll(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, _ in doc.sections.removeAll() }
        return Cmd.ok()
    }

    @Sendable static func sectionMove(_ s: Session, _ p: JSON) throws -> JSON {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad("section.move", "missing `index`") }
        guard let to0 = Cmd.usizeParam(p, "to") else { throw Cmd.bad("section.move", "missing `to`") }
        try s.edit { doc, _ in
            if i >= doc.sections.count { throw Cmd.bad("section.move", "no such section") }
            let sec = doc.sections.remove(at: i)
            let to = min(to0, doc.sections.count)
            doc.sections.insert(sec, at: to)
            // Reorder slides to follow sections.
            let order = doc.sections.flatMap(\.slides)
            var pos: [SlideId: Int] = [:]
            for (k, o) in order.enumerated() where pos[o] == nil { pos[o] = k }
            doc.slides = doc.slides.enumerated().sorted { a, b in
                let ka = pos[a.element.id] ?? Int.max
                let kb = pos[b.element.id] ?? Int.max
                return ka == kb ? a.offset < b.offset : ka < kb
            }.map(\.element)
        }
        return Cmd.ok()
    }

    @Sendable static func fromOutline(_ s: Session, _ p: JSON) throws -> JSON {
        let text = Cmd.strParam(p, "text") ?? ""
        let markdown = Cmd.boolParam(p, "markdown") ?? false
        return try s.edit { doc, sel in
            let before = doc.slides.count
            let n = markdown ? DeckFormat.markdownToSlides(&doc, text) : DeckFormat.outlineToSlides(&doc, text)
            // Both append; move them after the current slide.
            let at = min(sel.slide + 1, before)
            let new = Array(doc.slides[min(before, doc.slides.count)...])
            doc.slides.removeSubrange(min(before, doc.slides.count)...)
            doc.slides.insert(contentsOf: new, at: min(at, doc.slides.count))
            // Join the section of the slide before, as slide.new does.
            let ids = doc.slides.dropFirst(at).prefix(n).map(\.id)
            let prev = at > 0 ? doc.slides.at(at - 1)?.id : nil
            let section = prev.flatMap { doc.sectionOf($0) }
            if let si = section, si < doc.sections.count {
                let pos0 = prev.flatMap { pid in doc.sections[si].slides.firstIndex(of: pid) }.map { $0 + 1 } ?? doc.sections[si].slides.count
                let pos = min(pos0, doc.sections[si].slides.count)
                doc.sections[si].slides.insert(contentsOf: ids, at: pos)
            } else if !doc.sections.isEmpty {
                doc.sections[0].slides.insert(contentsOf: ids, at: 0)
            }
            return ["slides": .integer(n)]
        }
    }
}
