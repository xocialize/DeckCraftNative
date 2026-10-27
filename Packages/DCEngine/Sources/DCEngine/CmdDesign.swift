// DCEngine — the `design` command module: the Design tab and masters (themes, colours, fonts, effects,
// backgrounds, slide size, header & footer, Slide Master, Handout Master and Notes Master views).
// Port of deckcraft crates/engine/src/cmd/design.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCPPTX
import DCText

public enum DesignCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("design.theme", "Themes", ["Design", "Themes"], nil, "{name} (see design.themes)", Cmd.hasDoc, theme),
            .cmd(
                "design.browseTheme",
                "Browse for Themes…",
                ["Design", "Themes"],
                nil,
                "{path} | {name, data: base64} — apply a .pptx or .potx's slide master and layouts (slides move to the matching layouts), or a .thmx's theme",
                Cmd.hasDoc,
                browseTheme
            ),
            .query("design.themes", "Theme Gallery", [], nil, "{} → themes, colour schemes, font schemes and effect schemes", Cmd.always, themes),
            .cmd(
                "design.colors",
                "Colors",
                ["Design", "Variants"],
                nil,
                "{} opens Create New Theme Colors | {name} | {colors: {dk1|lt1|dk2|lt2|accent1..6|hlink|folHlink: #RRGGBB}}",
                Cmd.hasDoc,
                colors
            ),
            .cmd("design.variant", "Variants", ["Design", "Variants"], nil, "{index: 0..3} (see design.variants)", Cmd.hasDoc, variant),
            .query("design.variants", "Variant Gallery", [], nil, "{} → the current theme's four colour variants and which is applied", Cmd.hasDoc, variants),
            .cmd("design.fonts", "Fonts", ["Design", "Variants"], nil, "{} opens Create New Theme Fonts | {name} | {major, minor}", Cmd.hasDoc, fonts),
            .cmd("design.effects", "Effects", ["Design", "Variants"], nil, "{name} (see design.themes)", Cmd.hasDoc, effects),
            .cmd(
                "design.background",
                "Format Background",
                ["Design", "Customize"],
                nil,
                "{color? | gradient? | picture?: base64 | pattern? | style?: 1..12 | reset?, all?: bool, index?, transparency?: 0..1, pictureProps?: {tile?, offsetX?, offsetY?: pt, scaleX?, scaleY?: 0.01..10, align?, mirror?, stretch?: [l,t,r,b], rotateWithShape?}, copy?: bool}",
                Cmd.hasSlide,
                background
            ),
            .cmd("design.hideBackgroundGraphics", "Hide Background Graphics", ["Format Background"], nil, "{hide?: bool}", Cmd.hasSlide, hideBgGraphics),
            .cmd(
                "design.slideSize",
                "Slide Size",
                ["Design", "Customize"],
                nil,
                "{preset: widescreen|standard|…, orientation?: portrait|landscape, scale?: maximize|ensureFit|none} | {w: pt, h: pt, orientation?: portrait|landscape, scale?: maximize|ensureFit|none}",
                Cmd.hasDoc,
                slideSize
            ),
            .cmd(
                "design.headerFooter",
                "Header and Footer…",
                ["Insert", "Text"],
                nil,
                "{date?: bool, dateText?: fixed text, slideNumber?: bool, footer?: bool, footerText?, hideOnTitle?: bool, all?: bool (default true)}",
                Cmd.hasDoc,
                headerFooter
            ),
            .noundo("view.slideMaster", "Slide Master", ["View", "Master Views"], nil, "{master?: index, layout?: index}", Cmd.hasDoc, masterView),
            .cmd(
                "view.handoutMaster",
                "Handout Master",
                ["View", "Master Views"],
                nil,
                "{} (creates the handout master with header, date, footer and page number if the deck has none)",
                Cmd.hasDoc,
                handoutView
            ),
            .cmd(
                "handout.placeholders",
                "Handout Placeholders",
                ["Handout Master", "Placeholders"],
                nil,
                "{header?: bool, date?: bool, footer?: bool, pageNumber?: bool} (show or hide each)",
                inHandout,
                handoutPlaceholders
            ),
            .cmd(
                "view.notesMaster",
                "Notes Master",
                ["View", "Master Views"],
                nil,
                "{} (creates the notes master with header, date, slide image, notes body, footer and page number if the deck has none)",
                Cmd.hasDoc,
                notesView
            ),
            .cmd(
                "notes.placeholders",
                "Notes Placeholders",
                ["Notes Master", "Placeholders"],
                nil,
                "{header?, date?, slideImage?, body?, footer?, pageNumber?: bool} (show or hide each)",
                inNotesMaster,
                notesPlaceholders
            ),
            .noundo("view.closeMaster", "Close Master View", ["Slide Master", "Close"], nil, "{}", Cmd.hasDoc, closeMaster),
            .cmd("master.insertLayout", "Insert Layout", ["Slide Master", "Edit Master"], nil, "{name?}", Cmd.hasDoc, insertLayout),
            .cmd("master.renameLayout", "Rename Layout", ["Slide Master", "Edit Master"], nil, "{name, master?, layout?}", Cmd.hasDoc, renameLayout),
            .cmd("master.deleteLayout", "Delete Layout", ["Slide Master", "Edit Master"], nil, "{master?, layout?}", Cmd.hasDoc, deleteLayout),
            .cmd(
                "master.insertPlaceholder",
                "Insert Placeholder",
                ["Slide Master", "Master Layout"],
                nil,
                "{kind: content|text|picture|chart|table|media, rect?: [x,y,w,h]}",
                Cmd.hasDoc,
                insertPlaceholder
            ),
            .cmd("master.preserve", "Preserve", ["Slide Master", "Edit Master"], nil, "{preserve?: bool}", Cmd.hasDoc, preserve),
            .cmd(
                "master.placeholders",
                "Layout Placeholders",
                ["Slide Master", "Edit Master"],
                nil,
                "{title?: bool, footers?: bool}",
                Cmd.hasDoc,
                placeholders
            ),
        ]
    }

    static func eqIgnoreCase(_ a: String, _ b: String) -> Bool { EngineFonts.eqIgnoreASCIICase(a, b) }

    // MARK: Themes

    @Sendable static func theme(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("design.theme", "missing `name`") }
        guard let t = builtinThemes().first(where: { eqIgnoreCase($0.name, name) }) else { throw Cmd.bad("design.theme", "no theme `\(name)`") }
        try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.theme", "no master") }
            doc.masters[mi].theme = t
            doc.masters[mi].name = t.name
            doc.masters[mi].colorMap = []
        }
        return ["theme": .string(name)]
    }

    @Sendable static func browseTheme(_ s: Session, _ p: JSON) throws -> JSON {
        let bytes: [UInt8]
        if let data = Cmd.strParam(p, "data") {
            guard let b = Cmd.base64Decode(data) else { throw Cmd.bad("design.browseTheme", "invalid base64 `data`") }
            bytes = b
        } else {
            guard let path = Cmd.strParam(p, "path") else { throw Cmd.bad("design.browseTheme", "give `path` or `data`") }
            bytes = try IO.readFile(path)
        }
        if !PPTX.sniff(bytes) { throw Cmd.bad("design.browseTheme", "not a theme or PowerPoint file") }
        // A presentation or template brings its slide master and layouts, as in PowerPoint; a .thmx (its main
        // part is a theme, not a presentation) brings the theme alone.
        if let src = try? FileCommands.openPresentation("theme.pptx", bytes), let first = src.masters.first, !first.layouts.isEmpty {
            return try applyMaster(s, src)
        }
        let theme: Theme
        let media: [MediaItem]
        do {
            (theme, media) = try PPTX.importTheme(bytes)
        } catch {
            throw Cmd.bad("design.browseTheme", "\(error)")
        }
        let name = theme.name
        try s.edit { doc, sel in
            // The theme's pictures (format-scheme blip fills) get ids of this deck.
            var map: [UInt32: UInt32] = [:]
            for m in media {
                guard let id = doc.addMedia(m.name, m.contentType, m.data) else { throw Cmd.bad("design.browseTheme", Cmd.noIdSpace) }
                map[m.id.rawValue] = id.rawValue
            }
            let th = map.isEmpty ? theme : try remapMediaIds(theme, map)
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.browseTheme", "no master") }
            doc.masters[mi].theme = th
            doc.masters[mi].colorMap = []
        }
        return ["theme": .string(name)]
    }

    /// Design › Browse for Themes… with a `.pptx` / `.potx`: its first master and layouts replace the master
    /// the current slide uses (a preserved master stays beside it), stretched to this deck's slide size. Each
    /// slide on it moves to the new layout with the same name, else the same kind, keeping its content as
    /// Layout does.
    static func applyMaster(_ s: Session, _ src: Presentation) throws -> JSON {
        guard let from = src.masters.first else { throw Cmd.bad("design.browseTheme", "no master") }
        let themeName = from.theme.name
        return try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard let old = doc.masters.at(mi) else { throw Cmd.bad("design.browseTheme", "no master") }
            var media: [MediaId: MediaId] = [:]
            var layouts: [LayoutId: LayoutId] = [:]
            var m = try ReuseCommands.importMaster("design.browseTheme", &doc, src, from, &media, &layouts)
            let (sx, sy) = (doc.slideSize.width / src.slideSize.width.rustMax(1.0), doc.slideSize.height / src.slideSize.height.rustMax(1.0))
            if abs(sx - 1.0) > 1e-9 || abs(sy - 1.0) > 1e-9 {
                scaleShapes(&m.shapes, sx, sy, 1.0, 0.0, 0.0)
                for l in m.layouts.indices { scaleShapes(&m.layouts[l].shapes, sx, sy, 1.0, 0.0, 0.0) }
            }
            let moves: [(Int, LayoutId)] = doc.slides.enumerated().compactMap { i, sl in
                old.layout(sl.layout).flatMap { matchingLayout(m, $0) }.map { (i, $0) }
            }
            let count = m.layouts.count
            if old.preserve {
                doc.masters.insert(m, at: mi)
            } else if doc.masters.indices.contains(mi) {
                doc.masters[mi] = m
            }
            for (i, l) in moves { try SlideCommands.applyLayout(&doc, i, l) }
            if case .layout(let master, _) = sel.target { sel.target = .master(master: master) }
            sel.shapes.removeAll()
            sel.text = nil
            return ["theme": .string(themeName), "layouts": .integer(count), "slides": .integer(moves.count)]
        }
    }

    /// The layout of `m` a slide on `from` moves to: same name, else same kind (not for custom layouts), else
    /// Title and Content, else the first.
    static func matchingLayout(_ m: Master, _ from: Layout) -> LayoutId? {
        let ls = m.layouts
        let found = ls.first { !from.name.isEmpty && eqIgnoreCase(String(rustTrim($0.name)), String(rustTrim(from.name))) }
            ?? ls.first { from.kind != .custom && $0.kind == from.kind }
            ?? ls.first { $0.kind == .titleAndContent }
            ?? ls.first
        return found?.id
    }

    /// `theme` with every `media` id field rewritten through `map` (format-scheme picture fills).
    static func remapMediaIds(_ theme: Theme, _ map: [UInt32: UInt32]) throws -> Theme {
        func rec(_ v: JSON, _ depth: Int) -> JSON {
            if depth > 64 { return v }
            switch v {
            case .object(let o):
                var out = JSONObject()
                for e in o.entries {
                    if e.key == "media", let n = e.value.asU32, let new = map[n] {
                        out.append(e.key, .integer(new))
                    } else {
                        out.append(e.key, rec(e.value, depth + 1))
                    }
                }
                return .object(out)
            case .array(let a):
                return .array(a.map { rec($0, depth + 1) })
            default:
                return v
            }
        }
        do {
            return try Theme(fromJSON: rec(theme.toJSON(), 0))
        } catch {
            throw Cmd.bad("design.browseTheme", "\(error)")
        }
    }

    static func masterIndex(_ doc: Presentation, _ sel: Selection) -> Int {
        switch sel.target {
        case .master(let master), .layout(let master, _): return master
        case .slides, .handout, .notesMaster:
            return doc.slides.at(sel.slide).flatMap { s in doc.masters.firstIndex { $0.layout(s.layout) != nil } } ?? 0
        }
    }

    static func hexList(_ c: [Rgba]) -> JSON { .array(c.map { .string("#\($0.hex)") }) }

    @Sendable static func themes(_ s: Session, _ p: JSON) throws -> JSON {
        [
            "themes": .array(builtinThemes().map { t in
                ["name": .string(t.name), "major": .string(t.fonts.major.latin), "minor": .string(t.fonts.minor.latin), "colors": hexList(t.colors.colors)]
            }),
            "colorSchemes": .array(builtinColorSchemes().map { .string($0.name) }),
            "fontSchemes": .array(builtinFontSchemes().map { f in ["name": .string(f.name), "major": .string(f.major.latin), "minor": .string(f.minor.latin)] }),
            "effectSchemes": .array(builtinFormatSchemes().map { .string($0.name) }),
        ]
    }

    // MARK: Colours

    @Sendable static func colors(_ s: Session, _ p: JSON) throws -> JSON {
        let nameV = p.get("name")
        let colorsV = p.get("colors")
        if nameV == nil && colorsV == nil {
            let sc = try currentColors(s)
            s.uiRequests.append(.dialog(id: "themeColors", params: schemeDialogParams(sc)))
            return Cmd.ok()
        }
        var given: String?
        switch nameV {
        case .none: given = nil
        case .some(.string(let n)):
            let t = String(rustTrim(n))
            if t.isEmpty { throw Cmd.bad("design.colors", "name is empty") }
            given = t
        case .some: throw Cmd.bad("design.colors", "`name` must be a string")
        }
        let slots = try parseColorSlots(colorsV)
        let current = try currentColors(s)
        let next = try nextScheme(current, given, slots)
        if next == current { return Cmd.ok() }
        try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.colors", "no master") }
            doc.masters[mi].theme.colors = next
        }
        return Cmd.ok()
    }

    @Sendable static func variant(_ s: Session, _ p: JSON) throws -> JSON {
        guard let index = p.get("index")?.asUsize else { throw Cmd.bad("design.variant", "missing `index` (0..3)") }
        try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.variant", "no master") }
            let v = themeVariants(doc.masters[mi].theme)
            guard let c = v.at(index) else { throw Cmd.bad("design.variant", "no variant \(index); 0..\(max(v.count - 1, 0))") }
            doc.masters[mi].theme.colors = c
        }
        return ["variant": .integer(index)]
    }

    @Sendable static func variants(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let mi = masterIndex(st.doc, st.selection)
        let th = st.doc.masters.at(mi)?.theme ?? .default
        let v = themeVariants(th)
        let current = v.firstIndex { $0.colors == th.colors.colors }
        return [
            "theme": .string(th.name),
            "current": current.map { .integer($0) } ?? .null,
            "variants": .array(v.map { c in ["name": .string(c.name), "colors": hexList(c.colors)] }),
        ]
    }

    static func currentColors(_ s: Session) throws -> ColorScheme {
        let st = try s.doc()
        let mi = masterIndex(st.doc, st.selection)
        guard let m = st.doc.masters.at(mi) else { throw Cmd.bad("design.colors", "no master") }
        return m.theme.colors
    }

    static func schemeDialogParams(_ sc: ColorScheme) -> JSON {
        var colors = JSONObject()
        for slot in SchemeSlot.theme { colors.set(slot.xmlName, .string("#\(sc.get(slot).hex)")) }
        return ["name": .string(sc.name), "colors": .object(colors)]
    }

    /// nil when the key is absent. Present values must be the twelve stored slots; aliases such as `bg1` are
    /// rejected because `ColorScheme.set` ignores them.
    static func parseColorSlots(_ colorsV: JSON?) throws -> [(SchemeSlot, Rgba)]? {
        guard let v = colorsV else { return nil }
        guard case .object(let map)? = Optional(v.canonical) else { throw Cmd.bad("design.colors", "`colors` must be an object") }
        if map.entries.isEmpty { throw Cmd.bad("design.colors", "`colors` is empty") }
        var slots: [(SchemeSlot, Rgba)] = []
        // serde_json's map iterates its keys sorted (`canonical`).
        for e in map.entries {
            let k = e.key
            guard let slot = SchemeSlot.fromXML(k) else { throw Cmd.bad("design.colors", "unknown colour `\(k)`") }
            if !SchemeSlot.theme.contains(slot) { throw Cmd.bad("design.colors", "`\(k)` is not a theme colour") }
            guard let rgb = e.value.asStr.flatMap(Rgba.fromHex) else { throw Cmd.bad("design.colors", "`\(k)` needs a colour like #RRGGBB") }
            slots.append((slot, rgb))
        }
        return slots
    }

    /// A builtin `name` is applied first, then `colors` overlays those slots. The stored scheme name is the
    /// given name, or `Custom` when only colours are sent. An unknown name without colours is an error.
    static func nextScheme(_ current: ColorScheme, _ given: String?, _ slots: [(SchemeSlot, Rgba)]?) throws -> ColorScheme {
        var next = current
        if let name = given {
            if let builtin = builtinColorSchemes().first(where: { eqIgnoreCase($0.name, name) }) {
                next = builtin
            } else if slots == nil {
                throw Cmd.bad("design.colors", "no colour scheme `\(name)`")
            }
            next.name = name
        }
        if let changes = slots {
            for (slot, rgb) in changes { next.set(slot, rgb) }
            if given == nil { next.name = "Custom" }
        }
        return next
    }

    // MARK: Fonts and effects

    @Sendable static func fonts(_ s: Session, _ p: JSON) throws -> JSON {
        let nameV = p.get("name")
        let majorV = p.get("major")
        let minorV = p.get("minor")
        if nameV == nil && majorV == nil && minorV == nil {
            let scheme = try currentFonts(s)
            s.uiRequests.append(.dialog(id: "themeFonts", params: ["name": .string(scheme.name), "major": .string(scheme.major.latin), "minor": .string(scheme.minor.latin)]))
            return Cmd.ok()
        }
        var given: String?
        switch nameV {
        case .none: given = nil
        case .some(.string(let n)):
            let t = String(rustTrim(n))
            if t.isEmpty { throw Cmd.bad("design.fonts", "name is empty") }
            given = t
        case .some: throw Cmd.bad("design.fonts", "`name` must be a string")
        }
        let major = try faceParam("major", majorV)
        let minor = try faceParam("minor", minorV)
        let current = try currentFonts(s)
        let next = try nextFontScheme(current, given, major, minor)
        if next == current { return Cmd.ok() }
        try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.fonts", "no master") }
            doc.masters[mi].theme.fonts = next
        }
        return Cmd.ok()
    }

    static func currentFonts(_ s: Session) throws -> FontScheme {
        let st = try s.doc()
        let mi = masterIndex(st.doc, st.selection)
        guard let m = st.doc.masters.at(mi) else { throw Cmd.bad("design.fonts", "no master") }
        return m.theme.fonts
    }

    /// nil when the key is absent. A present face must be a non-blank string.
    static func faceParam(_ key: String, _ v: JSON?) throws -> String? {
        switch v {
        case .none: return nil
        case .some(.string(let s)):
            let t = String(rustTrim(s))
            if t.isEmpty { throw Cmd.bad("design.fonts", "`\(key)` is empty") }
            return t
        case .some: throw Cmd.bad("design.fonts", "`\(key)` must be a string")
        }
    }

    /// A builtin `name` is applied first, then `major` / `minor` replace only the latin faces (East Asian,
    /// complex-script and per-script slots stay). The stored name is the given string when faces are overlaid
    /// or the name is not a builtin; a name-only builtin keeps its own name. Faces without a name are a custom
    /// scheme: an omitted `minor` copies `major`.
    static func nextFontScheme(_ current: FontScheme, _ given: String?, _ major: String?, _ minor: String?) throws -> FontScheme {
        var next = current
        if let name = given {
            var replaced = false
            if let builtin = builtinFontSchemes().first(where: { eqIgnoreCase($0.name, name) }) {
                next = builtin
                replaced = true
            }
            if !replaced && major == nil && minor == nil { throw Cmd.bad("design.fonts", "no font scheme `\(name)`") }
            if major != nil || minor != nil || !replaced { next.name = name }
        }
        if given == nil {
            if let face = major {
                next.major.latin = face
                if minor == nil { next.minor.latin = face }
            }
            if let face = minor { next.minor.latin = face }
            next.name = "Custom"
        } else {
            if let face = major { next.major.latin = face }
            if let face = minor { next.minor.latin = face }
        }
        return next
    }

    @Sendable static func effects(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("design.effects", "missing `name`") }
        guard let scheme = builtinFormatSchemes().first(where: { eqIgnoreCase($0.name, name) }) else {
            throw Cmd.bad("design.effects", "no effect scheme `\(name)`")
        }
        let stored = scheme.name
        let st = try s.doc()
        let mi = masterIndex(st.doc, st.selection)
        if st.doc.masters.at(mi)?.theme.format == scheme { return ["name": .string(stored)] }
        try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("design.effects", "no master") }
            doc.masters[mi].theme.format = scheme
        }
        return ["name": .string(stored)]
    }

    // MARK: Backgrounds

    enum BgOp {
        case set(Background?)
        case adjust
    }

    @Sendable static func background(_ s: Session, _ p: JSON) throws -> JSON {
        if Cmd.boolOr(p, "copy", false) { return try copySlideBackground(s) }
        let props: JSON? = p.get("pictureProps").flatMap { $0.isObject ? $0 : nil }
        let transparency = Cmd.f64Param(p, "transparency")
        let reset = Cmd.boolOr(p, "reset", false)
        let color = Cmd.colorParam(p, "color")
        let style = Cmd.usizeParam(p, "style")
        let op: BgOp
        if reset {
            op = .set(nil)
        } else if var c = color {
            if let t = transparency { setSolidTransparency(&c, t) }
            op = .set(.fill(fill: .solid(c)))
        } else if let i = style {
            // Background styles: 3 theme bg fills × 4 colours (bg1, bg2, tx1, tx2).
            let slots: [SchemeSlot] = [.bg1, .bg2, .tx2, .tx1]
            let k = min(max(i, 1), 12) - 1
            op = .set(.ref(idx: 1001 + UInt32(k / 4), color: .scheme(slots.at(k % 4) ?? .bg1)))
        } else if let g = p.get("gradient") {
            guard var gr = ShapeCommands.gradientParam(g) else { throw Cmd.bad("design.background", "gradient needs two or more `stops`") }
            gr.rotateWithShape = false
            op = .set(.fill(fill: .gradient(gr)))
        } else if let pt = p.get("pattern") {
            op = .set(.fill(fill: .pattern(PatternFill(
                preset: pt.get("preset")?.asStr ?? "pct50",
                fg: pt.get("fg").flatMap(Cmd.colorValue) ?? .scheme(.accent1),
                bg: pt.get("bg").flatMap(Cmd.colorValue) ?? .scheme(.bg1)
            ))))
        } else if p.get("picture") != nil {
            let (name, bytes) = try InsertCommands.mediaBytes(Cmd.withParam(p, "data", p.get("picture") ?? .null), "design.background")
            let ct = InsertCommands.contentType(name, bytes)
            let media: MediaId = try s.edit { doc, _ in
                guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("design.background", Cmd.noIdSpace) }
                return m
            }
            var pf = PictureFill(media: media)
            if let pp = props { applyPictureProps(&pf, pp) }
            if let t = transparency { setPictureTransparency(&pf, t) }
            op = .set(.fill(fill: .picture(pf)))
        } else if props != nil || transparency != nil {
            op = .adjust
        } else {
            throw Cmd.bad(
                "design.background",
                "give `color`, `gradient`, `pattern`, `picture`, `style`, `reset`, `pictureProps`, `transparency` or `copy`"
            )
        }
        let all = Cmd.boolOr(p, "all", false)
        let index = Cmd.usizeParam(p, "index")
        switch op {
        case .adjust:
            let st = try s.doc()
            let current = backgroundOf(st.doc, st.selection, index)
            var picture = false
            var solid = false
            if case .fill(.picture)? = current { picture = true }
            if case .fill(.solid)? = current { solid = true }
            if props != nil && !picture { throw Cmd.bad("design.background", "picture options need a picture background") }
            if transparency != nil && !picture && !solid { throw Cmd.bad("design.background", "transparency needs a solid or picture background") }
            var next = current
            if var bg = next {
                adjustBackground(&bg, props, transparency)
                next = bg
            }
            if next == current { return Cmd.ok() }
            try s.edit { doc, sel in writeBackground(&doc, sel, index, false, next) }
            return Cmd.ok()
        case .set(let bg):
            let st = try s.doc()
            if backgroundsAlready(st.doc, st.selection, index, all, bg) { return Cmd.ok() }
            try s.edit { doc, sel in writeBackground(&doc, sel, index, all, bg) }
            return Cmd.ok()
        }
    }

    static func backgroundOf(_ doc: Presentation, _ sel: Selection, _ index: Int?) -> Background? {
        switch sel.target {
        case .master(let master): return doc.masters.at(master)?.background
        case .layout(let master, let layout): return doc.masters.at(master)?.layouts.at(layout)?.background
        case .handout, .notesMaster: return pageMaster(doc, sel.target)?.background
        case .slides: return doc.slides.at(index ?? sel.slide)?.background
        }
    }

    /// The masters the slides use, in order (a slide on no master's layout counts as the first's).
    static func usedMasterIndices(_ doc: Presentation) -> [Int] {
        let fallback: Int? = doc.masters.isEmpty ? nil : 0
        let used = doc.slides.compactMap { sl in doc.masters.firstIndex { $0.layout(sl.layout) != nil } ?? fallback }
        return Array(Set(used)).sorted()
    }

    static func backgroundsAlready(_ doc: Presentation, _ sel: Selection, _ index: Int?, _ all: Bool, _ bg: Background?) -> Bool {
        switch sel.target {
        case .master(let master): return doc.masters.at(master).map { $0.background == bg } ?? false
        case .layout(let master, let layout): return doc.masters.at(master)?.layouts.at(layout).map { $0.background == bg } ?? false
        case .handout, .notesMaster: return pageMaster(doc, sel.target).map { $0.background == bg } ?? false
        case .slides:
            let list = all ? Array(doc.slides.indices) : [index ?? sel.slide]
            let slidesMatch = !list.isEmpty && list.allSatisfy { i in doc.slides.at(i).map { $0.background == bg } ?? false }
            if all && bg != nil {
                let masters = usedMasterIndices(doc)
                let mastersMatch = !masters.isEmpty && masters.allSatisfy { i in doc.masters.at(i).map { $0.background == bg } ?? false }
                let layoutsMatch = !masters.isEmpty && masters.allSatisfy { i in doc.masters.at(i).map { $0.layouts.allSatisfy { $0.background == nil } } ?? false }
                return slidesMatch && mastersMatch && layoutsMatch
            }
            return slidesMatch
        }
    }

    static func writeBackground(_ doc: inout Presentation, _ sel: Selection, _ index: Int?, _ all: Bool, _ bg: Background?) {
        switch sel.target {
        case .master(let master):
            if doc.masters.indices.contains(master) { doc.masters[master].background = bg }
        case .layout(let master, let layout):
            if doc.masters.indices.contains(master), doc.masters[master].layouts.indices.contains(layout) {
                doc.masters[master].layouts[layout].background = bg
            }
        case .handout, .notesMaster:
            mutatePageMaster(&doc, sel.target) { $0.background = bg }
        case .slides:
            if all && bg != nil {
                for i in usedMasterIndices(doc) where doc.masters.indices.contains(i) {
                    doc.masters[i].background = bg
                    for l in doc.masters[i].layouts.indices { doc.masters[i].layouts[l].background = nil }
                }
            }
            let list = all ? Array(doc.slides.indices) : [index ?? sel.slide]
            for i in list where doc.slides.indices.contains(i) { doc.slides[i].background = bg }
        }
    }

    static func copySlideBackground(_ s: Session) throws -> JSON {
        let st = try s.doc()
        guard case .slides = st.selection.target else { throw Cmd.bad("design.background", "copy applies to slides") }
        let bg = st.doc.slides.at(st.selection.slide)?.background
        let slidesMatch = st.doc.slides.allSatisfy { $0.background == bg }
        var mastersMatch = true
        if bg != nil {
            let masters = usedMasterIndices(st.doc)
            mastersMatch = !masters.isEmpty && masters.allSatisfy { i in st.doc.masters.at(i).map { $0.background == bg } ?? false }
        }
        if slidesMatch && mastersMatch { return Cmd.ok() }
        try s.edit { doc, sel in writeBackground(&doc, sel, nil, true, bg) }
        return Cmd.ok()
    }

    static func adjustBackground(_ bg: inout Background, _ props: JSON?, _ transparency: Double?) {
        switch bg {
        case .fill(.picture(var pf)):
            if let pp = props { applyPictureProps(&pf, pp) }
            if let t = transparency { setPictureTransparency(&pf, t) }
            bg = .fill(fill: .picture(pf))
        case .fill(.solid(var color)):
            if let t = transparency { setSolidTransparency(&color, t) }
            bg = .fill(fill: .solid(color: color))
        default:
            break
        }
    }

    static func setPictureTransparency(_ pf: inout PictureFill, _ t: Double) {
        let a = 1.0 - t.clamped(0.0, 1.0)
        pf.alpha = a < 1.0 ? a : nil
    }

    static func setSolidTransparency(_ color: inout ColorRef, _ t: Double) {
        color.mods.removeAll { if case .alpha = $0 { return true } else { return false } }
        let t = t.clamped(0.0, 1.0)
        if t > 0.0 { color.mods.append(.alpha(Int32(rustCast: ((1.0 - t) * 100_000.0).rounded()))) }
    }

    /// Picture-fill options for Format Background (tile, offsets, scale, alignment, mirror, stretch).
    static func applyPictureProps(_ pf: inout PictureFill, _ pp: JSON) {
        func f(_ k: String) -> Double? { pp.get(k)?.asF64.flatMap { $0.isFinite ? $0 : nil } }
        if let up = pp.get("rotateWithShape")?.asBool { pf.upright = !up }
        var isTile = false
        if case .tile = pf.mode { isTile = true }
        switch pp.get("tile")?.asBool {
        case true? where !isTile:
            pf.mode = .tile(tx: 0.0, ty: 0.0, sx: 1.0, sy: 1.0, flip: "none", align: "tl")
        case false? where isTile:
            pf.mode = .default
        default:
            break
        }
        switch pf.mode {
        case .tile(var tx, var ty, var sx, var sy, var flip, var align):
            if let v = f("offsetX") { tx = v.clamped(-4000.0, 4000.0) }
            if let v = f("offsetY") { ty = v.clamped(-4000.0, 4000.0) }
            if let v = f("scaleX") { sx = v.clamped(0.01, 10.0) }
            if let v = f("scaleY") { sy = v.clamped(0.01, 10.0) }
            if let m = pp.get("mirror")?.asStr, ["none", "x", "y", "xy"].contains(m) { flip = m }
            if let a = pp.get("align")?.asStr, ["tl", "t", "tr", "l", "ctr", "r", "bl", "b", "br"].contains(a) { align = a }
            pf.mode = .tile(tx: tx, ty: ty, sx: sx, sy: sy, flip: flip, align: align)
        case .stretch(var fillRect):
            if let arr = pp.get("stretch")?.asArray {
                for (slot, v) in zip(fillRect.indices, arr) {
                    if let x = v.asF64, x.isFinite { fillRect[slot] = x.clamped(-10.0, 0.99) }
                }
            }
            pf.mode = .stretch(fillRect: fillRect)
        }
    }

    @Sendable static func hideBgGraphics(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, sel in
            if doc.slides.indices.contains(sel.slide) {
                doc.slides[sel.slide].showMasterShapes = !(Cmd.boolParam(p, "hide") ?? doc.slides[sel.slide].showMasterShapes)
            }
        }
        return Cmd.ok()
    }

    // MARK: Slide size

    static func scaleShapes(_ shapes: inout [Shape], _ sx: Double, _ sy: Double, _ k: Double, _ ox: Double, _ oy: Double) {
        for i in shapes.indices {
            if var x = shapes[i].xfrm {
                x.x = x.x * sx + ox
                x.y = x.y * sy + oy
                x.w *= sx
                x.h *= sy
                shapes[i].xfrm = x
            }
            if var t = shapes[i].text {
                TextEdit.formatAll(&t) { r in
                    if let sz = r.size { r.size = (sz * k).rustMax(1.0) }
                }
                shapes[i].text = t
            }
        }
    }

    @Sendable static func slideSize(_ s: Session, _ p: JSON) throws -> JSON {
        var size: Size
        if let pre = Cmd.strParam(p, "preset") {
            // `starts_with(k) || contains(k)`, on bytes.
            let k = Array(rustASCIILowercase(pre).utf8)
            func contains(_ l: [UInt8]) -> Bool {
                if k.isEmpty { return true }
                if l.count < k.count { return false }
                return (0 ... l.count - k.count).contains { l[$0 ..< $0 + k.count].elementsEqual(k) }
            }
            let found = slideSizes.first { e in
                let l = Array(rustASCIILowercase(e.label).utf8)
                return l.starts(with: k) || contains(l)
            }
            guard let f = found else { throw Cmd.bad("design.slideSize", "unknown preset `\(pre)`") }
            size = Size(f.width, f.height)
        } else {
            guard let w = Cmd.f64Param(p, "w") else { throw Cmd.bad("design.slideSize", "missing `w`") }
            guard let h = Cmd.f64Param(p, "h") else { throw Cmd.bad("design.slideSize", "missing `h`") }
            size = Size(w.clamped(72.0, 4032.0), h.clamped(72.0, 4032.0))
        }
        switch Cmd.strParam(p, "orientation") {
        case "portrait"? where size.width > size.height: size = Size(size.height, size.width)
        case "landscape"? where size.height > size.width: size = Size(size.height, size.width)
        case "portrait"?, "landscape"?, nil: break
        case let o?: throw Cmd.bad("design.slideSize", "unknown orientation `\(o)`")
        }
        let mode = Cmd.strParam(p, "scale") ?? "ensureFit"
        let newSize = size
        try s.edit { doc, _ in
            let old = doc.slideSize
            let (rx, ry) = (newSize.width / old.width.rustMax(1.0), newSize.height / old.height.rustMax(1.0))
            let (sx, sy, k, ox, oy): (Double, Double, Double, Double, Double)
            switch mode {
            case "none":
                (sx, sy, k, ox, oy) = (1.0, 1.0, 1.0, 0.0, 0.0)
            case "maximize":
                let kk = rx.rustMax(ry)
                (sx, sy, k, ox, oy) = (kk, kk, kk, (newSize.width - old.width * kk) / 2.0, (newSize.height - old.height * kk) / 2.0)
            default:
                let kk = rx.rustMin(ry)
                (sx, sy, k, ox, oy) = (kk, kk, kk, (newSize.width - old.width * kk) / 2.0, (newSize.height - old.height * kk) / 2.0)
            }
            // Masters and layouts stretch to the new size; slides scale by mode.
            let (msx, msy) = (newSize.width / old.width.rustMax(1.0), newSize.height / old.height.rustMax(1.0))
            for m in doc.masters.indices {
                scaleShapes(&doc.masters[m].shapes, msx, msy, 1.0, 0.0, 0.0)
                for l in doc.masters[m].layouts.indices { scaleShapes(&doc.masters[m].layouts[l].shapes, msx, msy, 1.0, 0.0, 0.0) }
            }
            for i in doc.slides.indices { scaleShapes(&doc.slides[i].shapes, sx, sy, k, ox, oy) }
            doc.slideSize = newSize
        }
        return ["w": .num(size.width), "h": .num(size.height)]
    }

    // MARK: Header and footer

    static func slideNumberParagraph() -> Paragraph {
        Paragraph(runs: [Run(text: "‹#›", props: RunProps(), kind: .field(field: "slidenum"))])
    }

    @Sendable static func headerFooter(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, sel in
            if let v = Cmd.boolParam(p, "date") { doc.headerFooter.date = v }
            if let v = Cmd.strParam(p, "dateText") { doc.headerFooter.dateText = v }
            if let v = Cmd.strParam(p, "dateFormat") {
                // Refused rather than ignored: a format that renders nothing would leave the placeholder showing
                // its saved text for ever.
                if !DateFields.dateKinds.contains(v) { throw Cmd.bad("design.headerFooter", "dateFormat: one of datetime1…datetime13") }
                doc.headerFooter.dateFormat = v
            }
            if let v = Cmd.boolParam(p, "slideNumber") { doc.headerFooter.slideNumber = v }
            if let v = Cmd.boolParam(p, "footer") { doc.headerFooter.footer = v }
            if let v = Cmd.strParam(p, "footerText") {
                doc.headerFooter.footerText = v
                doc.headerFooter.footer = doc.headerFooter.footer || !v.isEmpty
            }
            if let v = Cmd.boolParam(p, "hideOnTitle") { doc.headerFooter.hideOnTitle = v }
            let hf = doc.headerFooter
            let dateGiven = Cmd.strParam(p, "dateText") != nil
            let formatGiven = Cmd.strParam(p, "dateFormat") != nil
            let all = Cmd.boolOr(p, "all", true)
            let list = all ? Array(doc.slides.indices) : [sel.slide]
            for i in list {
                guard let layout = doc.slides.at(i)?.layout else { continue }
                let lay = doc.layout(layout)?.layout
                let isTitle = lay?.kind == .title
                func want(_ k: PhType) -> Bool {
                    if hf.hideOnTitle && isTitle { return false }
                    switch k {
                    case .date: return hf.date
                    case .slideNum: return hf.slideNumber
                    case .footer: return hf.footer
                    default: return false
                    }
                }
                var newIds: [ShapeId] = []
                for _ in 0 ..< 3 {
                    guard let raw = doc.allocId() else { throw Cmd.bad("design.headerFooter", Cmd.noIdSpace) }
                    newIds.append(ShapeId(raw))
                }
                guard doc.slides.indices.contains(i) else { continue }
                var sl = doc.slides[i]
                for (n, k) in [PhType.date, .footer, .slideNum].enumerated() {
                    let has = sl.shapes.firstIndex { $0.phType == k }
                    switch (has, want(k)) {
                    case (let pos?, false):
                        sl.shapes.remove(at: pos)
                    case (nil, true):
                        guard let lp = lay?.shapes.first(where: { $0.phType == k }) else { continue }
                        let body: TextBody
                        switch k {
                        case .slideNum:
                            body = TextBody(paragraphs: [slideNumberParagraph()])
                        case .date where hf.dateText.isEmpty:
                            body = TextBody(paragraphs: [Paragraph(runs: [Run(text: dateNow(hf.dateFormat), props: RunProps(), kind: .field(field: dateKind(hf.dateFormat)))])])
                        case .date:
                            body = TextBody.fromText(hf.dateText)
                        default:
                            body = TextBody.fromText(hf.footerText)
                        }
                        var shape = Shape.default
                        shape.id = newIds.at(n) ?? .default
                        shape.name = lp.name
                        shape.ph = lp.ph
                        shape.text = body
                        sl.shapes.append(shape)
                    case (let pos?, true) where k == .footer:
                        sl.shapes[pos].text = TextBody.fromText(hf.footerText)
                    case (let pos?, true) where k == .date && (dateGiven || formatGiven):
                        setDate(&sl.shapes[pos], hf.dateText, hf.dateFormat)
                    default:
                        break
                    }
                }
                doc.slides[i] = sl
            }
        }
        return Cmd.ok()
    }

    /// The date field type `format` names, `datetime1` when it is empty or unknown.
    static func dateKind(_ format: String) -> String {
        DateFields.dateKinds.contains(format) ? format : "datetime1"
    }

    /// The saved text of a date field of `format`, as it shows now.
    static func dateNow(_ format: String) -> String {
        let kind = dateKind(format)
        return DateTime.nowLocal().flatMap { DateFields.fieldText(kind, nil, $0) } ?? today()
    }

    /// Point a slide's date placeholder at a fixed date (its own plain text) or, for an empty `fixed`, at an
    /// automatic date field (one it already has keeps its format).
    static func setDate(_ sh: inout Shape, _ fixed: String, _ format: String) {
        let runs = sh.text?.paragraphs.flatMap(\.runs) ?? []
        let fieldNow: String? = runs.lazy.compactMap { r -> String? in
            if case .field(let f) = r.kind, DateFields.isDateField(f) { return f }
            return nil
        }.first
        let hasField = fieldNow != nil
        let props = runs.first?.props ?? RunProps()
        let want = dateKind(format)
        let text: String
        let kind: RunKind
        if fixed.isEmpty {
            if fieldNow == want { return }
            if hasField && format.isEmpty { return }
            (text, kind) = (dateNow(format), .field(field: want))
        } else {
            if !hasField, let t = sh.text, t.text == fixed { return }
            (text, kind) = (fixed, .text)
        }
        let para = Paragraph(runs: [Run(text: text, props: props, kind: kind)])
        var body = sh.text ?? TextBody()
        body.paragraphs = [para]
        sh.text = body
    }

    /// Today's local date as a `datetime1` field shows it (M/D/YYYY): the saved text of a new date field.
    public static func today() -> String { dateFieldText("datetime1") }

    /// What date field `kind` shows now (empty if unknown or there is no clock).
    public static func dateFieldText(_ kind: String) -> String {
        DateTime.nowLocal().flatMap { DateFields.fieldText(kind, nil, $0) } ?? ""
    }

    /// `design::civil`: the proleptic Gregorian date `(year, month, day)` of day `z` counted from 1970-01-01,
    /// exact for every `Int64`. The calendar repeats every 400 years (146,097 days): the day within its cycle
    /// is converted and the whole cycles go back into the year, as deckcraft does around chrono's range.
    public static func civil(_ z: Int64) -> (year: Int64, month: UInt32, day: UInt32) {
        let cycleDays: Int64 = 146_097
        var cycles = z / cycleDays
        var rest = z % cycleDays
        if rest < 0 { rest += cycleDays; cycles -= 1 }  // div_euclid / rem_euclid
        // Howard Hinnant's civil_from_days on 0..<146_097 days after 1970-01-01 (no overflow possible).
        let shifted = rest + 719_468  // days since 0000-03-01
        let era = shifted / cycleDays
        let doe = shifted - era * cycleDays
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        let (carry, over) = cycles.multipliedReportingOverflow(by: 400)
        let (y, over2) = year.addingReportingOverflow(carry)
        let total = (over || over2) ? (cycles < 0 ? Int64.min : Int64.max) : y
        return (total, UInt32(truncatingIfNeeded: month), UInt32(truncatingIfNeeded: day))
    }

    // MARK: Master views

    @Sendable static func masterView(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let mi = Cmd.usizeParam(p, "master") ?? masterIndex(st.doc, st.selection)
        // A master thumbnail sends `{master}` and means the master itself. `{master, layout}` selects that
        // layout. With neither key, follow the current slide's layout.
        let layout: Int?
        if p.get("master") != nil && p.get("layout") == nil {
            layout = nil
        } else {
            layout = Cmd.usizeParam(p, "layout") ?? st.currentSlide.flatMap { sl in st.doc.masters.at(mi)?.layouts.firstIndex { $0.id == sl.layout } }
        }
        let target: Target = layout.map { .layout(master: mi, layout: $0) } ?? .master(master: mi)
        try s.select { _, sel in
            sel.target = target
            sel.shapes.removeAll()
            sel.text = nil
        }
        return target.toJSON()
    }

    @Sendable static func inHandout(_ s: Session) -> String? {
        s.activeDoc?.selection.target == .handout ? nil : "open View ▸ Handout Master first"
    }

    /// The four handout-master placeholders PowerPoint offers, in a page of `size`.
    public static func handoutPlaceholder(_ kind: PhType, _ size: Size, _ id: ShapeId) -> Shape {
        let (w, h) = (size.width, size.height)
        let (name, idx, x, y): (String, UInt32, Double, Double) = switch kind {
        case .header: ("Header Placeholder", 0, 0.0, 0.0)
        case .date: ("Date Placeholder", 1, w * 0.57, 0.0)
        case .footer: ("Footer Placeholder", 2, 0.0, h * 0.95)
        default: ("Slide Number Placeholder", 3, w * 0.57, h * 0.95)
        }
        var text = TextBody()
        if !text.paragraphs.isEmpty, kind == .date || kind == .slideNum {
            text.paragraphs[0].props.align = .right
        }
        var sh = Shape.default
        sh.id = id
        sh.name = "\(name) \(idx + 1)"
        sh.xfrm = Xfrm(x, y, w * 0.43, h * 0.05)
        sh.ph = Placeholder(kind: kind, idx: idx, size: "quarter")
        sh.text = text
        return sh
    }

    static let handoutKinds: [(String, PhType)] = [("header", .header), ("date", .date), ("footer", .footer), ("pageNumber", .slideNum)]

    @Sendable static func handoutView(_ s: Session, _ p: JSON) throws -> JSON {
        let created = try s.doc().doc.handoutMaster == nil
        if created {
            try s.edit { doc, _ in
                var m = Master.default
                m.name = "Handout Master"
                m.theme = doc.masters.first?.theme ?? .default
                m.colorMap = doc.masters.first?.colorMap ?? []
                let size = doc.notesSize
                for (_, k) in handoutKinds {
                    guard let raw = doc.allocId() else { throw Cmd.bad("view.handoutMaster", Cmd.noIdSpace) }
                    m.shapes.append(handoutPlaceholder(k, size, ShapeId(raw)))
                }
                doc.handoutMaster = m
            }
        }
        try s.select { _, sel in
            sel.target = .handout
            sel.shapes.removeAll()
            sel.text = nil
        }
        return ["created": .bool(created)]
    }

    @Sendable static func handoutPlaceholders(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, _ in
            let size = doc.notesSize
            var ids: [ShapeId?] = []
            for (key, _) in handoutKinds {
                if p.get(key)?.asBool != nil {
                    guard let raw = doc.allocId() else { throw Cmd.bad("handout.placeholders", Cmd.noIdSpace) }
                    ids.append(ShapeId(raw))
                } else {
                    ids.append(nil)
                }
            }
            guard var m = doc.handoutMaster else { throw Cmd.bad("handout.placeholders", "no handout master") }
            for ((key, kind), id) in zip(handoutKinds, ids) {
                guard let on = p.get(key)?.asBool, let id else { continue }
                let has = m.shapes.contains { $0.phType == kind }
                if on && !has {
                    m.shapes.append(handoutPlaceholder(kind, size, id))
                } else if !on {
                    m.shapes.removeAll { $0.phType == kind }
                }
            }
            doc.handoutMaster = m
        }
        let m = try s.doc().doc.handoutMaster
        func shown(_ k: PhType) -> Bool { m?.shapes.contains { $0.phType == k } ?? false }
        return ["header": .bool(shown(.header)), "date": .bool(shown(.date)), "footer": .bool(shown(.footer)), "pageNumber": .bool(shown(.slideNum))]
    }

    @Sendable static func inNotesMaster(_ s: Session) -> String? {
        s.activeDoc?.selection.target == .notesMaster ? nil : "open View ▸ Notes Master first"
    }

    static let notesKinds: [(String, PhType)] = [
        ("header", .header), ("date", .date), ("slideImage", .slideImage), ("body", .body), ("footer", .footer), ("pageNumber", .slideNum),
    ]

    /// A notes-master placeholder in a page of `size`, laid out as PowerPoint's default notes master.
    public static func notesPlaceholder(_ kind: PhType, _ size: Size, _ id: ShapeId) -> Shape {
        let (w, h) = (size.width, size.height)
        switch kind {
        case .slideImage:
            var sh = Shape.default
            sh.id = id
            sh.name = "Slide Image Placeholder 3"
            sh.xfrm = Xfrm(w * 0.125, h * 0.125, w * 0.75, h * 0.375)
            sh.ph = Placeholder(kind: kind, idx: 2)
            sh.fill = .none_
            sh.line = Line.solid(.rgb(.black), 1.0)
            return sh
        case .body:
            var sh = Shape.default
            sh.id = id
            sh.name = "Notes Placeholder 4"
            sh.xfrm = Xfrm(w * 0.1, h * 0.53, w * 0.8, h * 0.36)
            sh.ph = Placeholder(kind: kind, idx: 3, size: "quarter")
            sh.text = TextBody(paragraphs: [Paragraph("Click to edit Master text styles")])
            return sh
        default:
            var sh = handoutPlaceholder(kind, size, id)
            sh.ph?.idx = switch kind {
            case .header: 0
            case .date: 1
            case .footer: 4
            default: 5
            }
            return sh
        }
    }

    @Sendable static func notesView(_ s: Session, _ p: JSON) throws -> JSON {
        let created = try s.doc().doc.notesMaster.map { $0.shapes.isEmpty } ?? true
        if created {
            try s.edit { doc, _ in
                var m: Master
                if let existing = doc.notesMaster {
                    m = existing
                } else {
                    m = Master.default
                    m.name = "Notes Master"
                    m.theme = doc.masters.first?.theme ?? .default
                    m.colorMap = doc.masters.first?.colorMap ?? []
                }
                let size = doc.notesSize
                for (_, k) in notesKinds {
                    guard let raw = doc.allocId() else { throw Cmd.bad("view.notesMaster", Cmd.noIdSpace) }
                    m.shapes.append(notesPlaceholder(k, size, ShapeId(raw)))
                }
                doc.notesMaster = m
            }
        }
        try s.select { _, sel in
            sel.target = .notesMaster
            sel.shapes.removeAll()
            sel.text = nil
        }
        return ["created": .bool(created)]
    }

    @Sendable static func notesPlaceholders(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, _ in
            let size = doc.notesSize
            var ids: [ShapeId] = []
            for _ in notesKinds {
                guard let raw = doc.allocId() else { throw Cmd.bad("notes.placeholders", Cmd.noIdSpace) }
                ids.append(ShapeId(raw))
            }
            guard var m = doc.notesMaster else { throw Cmd.bad("notes.placeholders", "no notes master") }
            for ((key, kind), id) in zip(notesKinds, ids) {
                guard let on = p.get(key)?.asBool else { continue }
                let has = m.shapes.contains { $0.phType == kind }
                if on && !has {
                    m.shapes.append(notesPlaceholder(kind, size, id))
                } else if !on {
                    m.shapes.removeAll { $0.phType == kind }
                }
            }
            doc.notesMaster = m
        }
        let m = try s.doc().doc.notesMaster
        var out = JSONObject()
        for (key, kind) in notesKinds {
            out.set(key, .bool(m?.shapes.contains { $0.phType == kind } ?? false))
        }
        return .object(out)
    }

    @Sendable static func closeMaster(_ s: Session, _ p: JSON) throws -> JSON {
        try s.select { _, sel in
            sel.target = .slides
            sel.shapes.removeAll()
            sel.text = nil
        }
        return Cmd.ok()
    }

    // MARK: Slide Master editing

    @Sendable static func insertLayout(_ s: Session, _ p: JSON) throws -> JSON {
        let name = Cmd.strParam(p, "name") ?? "Custom Layout"
        return try s.edit { doc, sel in
            let mi = masterIndex(doc, sel)
            guard let rawId = doc.allocId() else { throw Cmd.bad("master.insertLayout", Cmd.noIdSpace) }
            let id = LayoutId(rawId)
            guard let rawTid = doc.allocId() else { throw Cmd.bad("master.insertLayout", Cmd.noIdSpace) }
            let tid = ShapeId(rawTid)
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("master.insertLayout", "no master") }
            let title = doc.masters[mi].shapes.first { $0.phType == .title }.map { t -> Shape in
                var t = t
                t.id = tid
                t.text = TextBody()
                return t
            }
            let at: Int = if case .layout(_, let layout) = sel.target { layout + 1 } else { doc.masters[mi].layouts.count }
            let layout = Layout(
                id: id, name: name, kind: .custom, shapes: title.map { [$0] } ?? [], background: nil, showMasterShapes: true,
                preserve: true, colorMap: nil, rawExt: nil
            )
            doc.masters[mi].layouts.insert(layout, at: min(at, doc.masters[mi].layouts.count))
            sel.target = .layout(master: mi, layout: min(at, max(doc.masters[mi].layouts.count - 1, 0)))
            return ["id": id.toJSON()]
        }
    }

    static func layoutTarget(_ s: Session, _ p: JSON, _ cmd: String) throws -> (Int, Int) {
        let st = try s.doc()
        let (m, l): (Int, Int) = if case .layout(let master, let layout) = st.selection.target {
            (master, layout)
        } else {
            (masterIndex(st.doc, st.selection), 0)
        }
        return (try Cmd.optUsizeParam(p, "master", cmd) ?? m, try Cmd.optUsizeParam(p, "layout", cmd) ?? l)
    }

    @Sendable static func renameLayout(_ s: Session, _ p: JSON) throws -> JSON {
        let (mi, li) = try layoutTarget(s, p, "master.renameLayout")
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("master.renameLayout", "missing `name`") }
        try s.edit { doc, _ in
            guard doc.masters.indices.contains(mi), doc.masters[mi].layouts.indices.contains(li) else {
                throw Cmd.bad("master.renameLayout", "no such layout")
            }
            doc.masters[mi].layouts[li].name = name
        }
        return Cmd.ok()
    }

    @Sendable static func deleteLayout(_ s: Session, _ p: JSON) throws -> JSON {
        let (mi, li) = try layoutTarget(s, p, "master.deleteLayout")
        try s.edit { doc, sel in
            guard let id = doc.masters.at(mi)?.layouts.at(li)?.id else { throw Cmd.bad("master.deleteLayout", "no such layout") }
            if doc.slides.contains(where: { $0.layout == id }) { throw Cmd.bad("master.deleteLayout", "slides use this layout") }
            guard doc.masters.indices.contains(mi) else { throw Cmd.bad("master.deleteLayout", "no master") }
            if doc.masters[mi].layouts.count <= 1 { throw Cmd.bad("master.deleteLayout", "a master needs at least one layout") }
            doc.masters[mi].layouts.remove(at: li)
            sel.target = .layout(master: mi, layout: min(li, max(doc.masters[mi].layouts.count - 1, 0)))
        }
        return Cmd.ok()
    }

    @Sendable static func insertPlaceholder(_ s: Session, _ p: JSON) throws -> JSON {
        let kind: PhType = switch Cmd.strParam(p, "kind") ?? "content" {
        case "text": .body
        case "picture": .picture
        case "chart": .chart
        case "table": .table
        case "media": .media
        default: .obj
        }
        guard case .layout = try s.doc().selection.target else {
            throw Cmd.bad("master.insertPlaceholder", "select a layout in Slide Master view")
        }
        let st = try s.doc()
        let size = st.doc.slideSize
        let rect = Cmd.rectParam(p, "rect") ?? Xfrm(size.width * 0.25, size.height * 0.3, size.width * 0.5, size.height * 0.4)
        let maxIdx = st.shapes.compactMap { $0.ph?.idx }.max() ?? 0
        let idx = maxIdx &+ 1
        var shape = Shape.default
        shape.xfrm = rect
        shape.ph = Placeholder(kind: kind, idx: idx)
        shape.text = TextBody()
        let id = try InsertCommands.addShape(s, "master.insertPlaceholder", shape, true)
        return ["id": id.toJSON()]
    }

    @Sendable static func preserve(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let onMaster: Bool
        let mi: Int
        let li: Int
        let current: Bool
        switch st.selection.target {
        case .master(let master):
            guard let on = st.doc.masters.at(master)?.preserve else { throw Cmd.bad("master.preserve", "no such master") }
            (onMaster, mi, li, current) = (true, master, 0, on)
        case .layout(let master, let layout):
            guard let on = st.doc.masters.at(master)?.layouts.at(layout)?.preserve else { throw Cmd.bad("master.preserve", "no such layout") }
            (onMaster, mi, li, current) = (false, master, layout, on)
        case .slides, .handout, .notesMaster:
            throw Cmd.bad("master.preserve", "open Slide Master view")
        }
        let next = Cmd.boolParam(p, "preserve") ?? !current
        if next == current { return ["preserve": .bool(next)] }
        try s.edit { doc, _ in
            if onMaster {
                guard doc.masters.indices.contains(mi) else { throw Cmd.bad("master.preserve", "no such master") }
                doc.masters[mi].preserve = next
            } else {
                guard doc.masters.indices.contains(mi), doc.masters[mi].layouts.indices.contains(li) else {
                    throw Cmd.bad("master.preserve", "no such layout")
                }
                doc.masters[mi].layouts[li].preserve = next
            }
        }
        return ["preserve": .bool(next)]
    }

    static func isTitlePh(_ sh: Shape) -> Bool { sh.phType?.isTitle ?? false }
    static func isFooterPh(_ sh: Shape) -> Bool { sh.phType?.isFooterKind ?? false }

    @Sendable static func placeholders(_ s: Session, _ p: JSON) throws -> JSON {
        let title = Cmd.boolParam(p, "title")
        let footers = Cmd.boolParam(p, "footers")
        if title == nil && footers == nil { throw Cmd.bad("master.placeholders", "give title or footers") }
        let st = try s.doc()
        if case .slides = st.selection.target { throw Cmd.bad("master.placeholders", "open Slide Master view") }
        let hasTitle = st.shapes.contains(where: isTitlePh)
        let hasFooters = st.shapes.contains(where: isFooterPh)
        let titleChanges = title.map { $0 != hasTitle } ?? false
        let footerChanges = footers.map { $0 != hasFooters } ?? false
        if !titleChanges && !footerChanges { return ["title": .bool(hasTitle), "footers": .bool(hasFooters)] }
        var add: [PhType] = []
        if title == true && !hasTitle { add.append(.title) }
        if footers == true && !hasFooters { add.append(contentsOf: [.date, .footer, .slideNum]) }
        let size = st.doc.slideSize
        try s.edit { doc, sel in
            var ids: [ShapeId] = []
            for _ in add {
                guard let raw = doc.allocId() else { throw Cmd.bad("master.placeholders", Cmd.noIdSpace) }
                ids.append(ShapeId(raw))
            }
            let prototypes: [Shape]
            switch sel.target {
            case .master(let master), .layout(let master, _): prototypes = doc.masters.at(master)?.shapes ?? []
            case .slides: prototypes = []
            case .handout, .notesMaster: throw Cmd.bad("master.placeholders", "open Slide Master view")
            }
            try withShapes(&doc, sel, missing: Cmd.bad("master.placeholders", "open Slide Master view")) { shapes in
                if title == false { shapes.removeAll(where: isTitlePh) }
                if footers == false { shapes.removeAll(where: isFooterPh) }
                for (kind, id) in zip(add, ids) {
                    let idx = freePhIdx(shapes, preferredPhIdx(kind))
                    let proto = prototypes.first { sh in kind == .title ? isTitlePh(sh) : sh.phType == kind }
                    let shape = proto.map { retargetPlaceholder($0, id, idx) } ?? synthesizedPlaceholder(kind, id, idx, size)
                    shapes.append(shape)
                }
            }
        }
        let after = try s.doc()
        return ["title": .bool(after.shapes.contains(where: isTitlePh)), "footers": .bool(after.shapes.contains(where: isFooterPh))]
    }

    static func preferredPhIdx(_ kind: PhType) -> UInt32 {
        switch kind {
        case .title, .ctrTitle: 0
        case .date: 10
        case .footer: 11
        case .slideNum: 12
        default: 1
        }
    }

    static func freePhIdx(_ shapes: [Shape], _ preferred: UInt32) -> UInt32 {
        func taken(_ idx: UInt32) -> Bool { shapes.contains { $0.ph?.idx == idx } }
        if !taken(preferred) { return preferred }
        let m = shapes.compactMap { $0.ph?.idx }.max() ?? 0
        return m == .max ? .max : m + 1
    }

    /// A copy of a master placeholder, with a new id and index. Prompt text is cleared; a slide number keeps
    /// its `‹#›` field.
    static func retargetPlaceholder(_ src: Shape, _ id: ShapeId, _ idx: UInt32) -> Shape {
        var sh = src
        sh.id = id
        sh.ph?.idx = idx
        if sh.phType == .slideNum {
            let paras = [slideNumberParagraph()]
            if sh.text != nil {
                sh.text?.paragraphs = paras
            } else {
                sh.text = TextBody(paragraphs: paras)
            }
        } else if sh.text != nil {
            sh.text?.paragraphs.removeAll()
        }
        return sh
    }

    static func synthesizedPlaceholder(_ kind: PhType, _ id: ShapeId, _ idx: UInt32, _ size: Size) -> Shape {
        let (name, text): (String, TextBody) = switch kind {
        case .date: ("Date Placeholder", TextBody())
        case .footer: ("Footer Placeholder", TextBody())
        case .slideNum: ("Slide Number Placeholder", TextBody(paragraphs: [slideNumberParagraph()]))
        default: ("Title", TextBody())
        }
        var sh = Shape.default
        sh.id = id
        sh.name = name
        sh.xfrm = placeholderRect(kind, size)
        sh.ph = Placeholder(kind: kind, idx: idx)
        sh.text = text
        return sh
    }

    /// Standard placeholder boxes at 960×540, scaled to the slide size.
    static func placeholderRect(_ kind: PhType, _ size: Size) -> Xfrm {
        let sx = size.width / 960.0
        let sy = size.height / 540.0
        let (x, y, w, h): (Double, Double, Double, Double) = switch kind {
        case .date: (60.0, 500.0, 216.0, 28.0)
        case .footer: (318.0, 500.0, 324.0, 28.0)
        case .slideNum: (684.0, 500.0, 216.0, 28.0)
        default: (60.0, 29.0, 840.0, 104.0)
        }
        return Xfrm(x * sx, y * sy, w * sx, h * sy)
    }
}
