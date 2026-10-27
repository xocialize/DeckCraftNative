// DCEngine — the `format` command module: Home ▸ Font and Paragraph and the Format menu (character,
// paragraph and text box formatting), the ruler and tab stops, and the Format Painter.
// Port of deckcraft crates/engine/src/cmd/format.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText

public enum FormatCommands {
    public static func specs() -> [CommandSpec] {
        [
            .noundo("font.add", "Add Font", [], nil, "{data: base64 TTF/OTF/TTC} → {faces} added for this session", Cmd.always, fontAdd),
            .noundo("font.rescan", "Rescan Installed Fonts", ["Home", "Font"], nil, "{} → {faces, families} (fonts installed since start-up)", Cmd.always, fontRescan),
            .cmd("format.bold", "Bold", ["Home", "Font"], "Cmd+B", "{on?: bool}", Cmd.hasTextOrShapes, bold),
            .cmd("format.italic", "Italic", ["Home", "Font"], "Cmd+I", "{on?: bool}", Cmd.hasTextOrShapes, italic),
            .cmd("format.underline", "Underline", ["Home", "Font"], "Cmd+U", "{on?: bool, style?: sng|dbl|heavy|dotted|dash|wavy}", Cmd.hasTextOrShapes, underline),
            .cmd("format.strikethrough", "Strikethrough", ["Home", "Font"], "Cmd+Shift+X", "{on?: bool, double?: bool}", Cmd.hasTextOrShapes, strike),
            .cmd("format.superscript", "Superscript", ["Home", "Font"], "Cmd+Shift+=", "{on?: bool}", Cmd.hasTextOrShapes, superscript),
            .cmd("format.subscript", "Subscript", ["Home", "Font"], "Cmd+=", "{on?: bool}", Cmd.hasTextOrShapes, subscriptCmd),
            .cmd("format.font", "Font", ["Home", "Font"], nil, "{family}", Cmd.hasTextOrShapes, font),
            .cmd("format.size", "Font Size", ["Home", "Font"], nil, "{size: pt}", Cmd.hasTextOrShapes, size),
            .cmd("format.grow", "Increase Font Size", ["Home", "Font"], "Cmd+Shift+.", "{}", Cmd.hasTextOrShapes) { s, _ in try growShrink(s, true) },
            .cmd("format.shrink", "Decrease Font Size", ["Home", "Font"], "Cmd+Shift+,", "{}", Cmd.hasTextOrShapes) { s, _ in try growShrink(s, false) },
            .cmd("format.color", "Font Color", ["Home", "Font"], nil, "{color: #RRGGBB|accent1..6|tx1…|{scheme, lumMod…}}", Cmd.hasTextOrShapes, color),
            .cmd(
                "format.textTransparency",
                "Text Transparency",
                ["Shape Format", "WordArt Styles"],
                nil,
                "{value: 0..1} — 0 opaque, 1 invisible; keeps the text's colour (inherited colours included)",
                Cmd.hasTextOrShapes,
                textTransparency
            ),
            .cmd(
                "format.language",
                "Language",
                ["Review", "Language"],
                nil,
                "{lang?, noProof?: bool} (proofing language of the selected text, and Do Not Check Spelling)",
                Cmd.hasTextOrShapes,
                language
            ),
            .cmd(
                "format.languageAll",
                "Language for All Text",
                ["Review", "Language"],
                nil,
                "{lang?, noProof?: bool} (proofing language of every text in the presentation: slides, tables, notes, masters and layouts, and the default for new text; one undo step)",
                Cmd.hasDoc,
                languageAll
            ),
            .cmd("format.highlight", "Text Highlight Color", ["Home", "Font"], nil, "{color? (absent = none)}", Cmd.hasTextOrShapes, highlight),
            .cmd(
                "format.case",
                "Change Case",
                ["Home", "Font"],
                "Shift+F3",
                "{mode?: cycle|sentence|lower|upper|title|toggle} — cycle (Shift+F3, the default) goes lowercase → Capitalize Each Word → UPPERCASE; a caret in a word changes that word",
                Cmd.hasTextOrShapes,
                changeCase
            ),
            .cmd("format.caps", "Caps", [], nil, "{caps: none|small|all}", Cmd.hasTextOrShapes, caps),
            .cmd(
                "format.spacing",
                "Character Spacing",
                ["Home", "Font"],
                nil,
                "{pt} (veryTight -3, tight -1.5, normal 0, loose 3, veryLoose 6)",
                Cmd.hasTextOrShapes,
                spacing
            ),
            .cmd("format.clear", "Clear All Formatting", ["Home", "Font"], "Cmd+Space", "{}", Cmd.hasTextOrShapes, clear),
            .cmd(
                "format.fontDialog",
                "Font…",
                ["Home", "Font"],
                "Cmd+T",
                "{family?, size?: pt, bold?: bool, italic?: bool, underline?: none|sng|dbl|heavy|dotted|dash|wavy, color?, strike?: none|sng|dbl, baseline?: none|super|sub|<fraction>, caps?: none|small|all, spacing?: pt} — with none of these, opens the Font dialog",
                Cmd.hasTextOrShapes,
                fontDialog
            ),
            .cmd("format.textShadow", "Text Shadow", ["Home", "Font"], nil, "{on?: bool}", Cmd.hasTextOrShapes, textShadow),
            .cmd(
                "format.textOutline",
                "Text Outline",
                ["Shape Format", "WordArt Styles"],
                nil,
                "{color?, width?: pt} (no color = none)",
                Cmd.hasTextOrShapes,
                textOutline
            ),
            .cmd(
                "format.textWarp",
                "Text Transform",
                ["Shape Format", "WordArt Styles"],
                nil,
                "{preset: a prstTxWarp name or none, adj?: [finite raw guide values, at most 8]} — none clears the transform; omitted adj uses the preset's defaults",
                Cmd.hasTextOrShapes,
                textWarp
            ),
            .cmd(
                "format.align",
                "Align",
                ["Home", "Paragraph"],
                nil,
                "{align: left|center|right|justify|justifyLow|distributed}",
                Cmd.hasTextOrShapes,
                align
            ),
            .cmd(
                "format.rtl",
                "Right-to-Left Text Direction",
                ["Home", "Paragraph"],
                nil,
                "{on?: bool} (off = left-to-right; switching mirrors left/right alignment)",
                Cmd.hasTextOrShapes,
                rtl
            ),
            .cmd("format.alignLeft", "Align Left", ["Home", "Paragraph"], "Cmd+L", "{}", Cmd.hasTextOrShapes) { s, _ in try alignTo(s, .left) },
            .cmd("format.alignCenter", "Center", ["Home", "Paragraph"], "Cmd+E", "{}", Cmd.hasTextOrShapes) { s, _ in try alignTo(s, .center) },
            .cmd("format.alignRight", "Align Right", ["Home", "Paragraph"], "Cmd+R", "{}", Cmd.hasTextOrShapes) { s, _ in try alignTo(s, .right) },
            .cmd("format.justify", "Justify", ["Home", "Paragraph"], "Cmd+J", "{}", Cmd.hasTextOrShapes) { s, _ in try alignTo(s, .justify) },
            .cmd(
                "format.bullets",
                "Bullets",
                ["Home", "Paragraph"],
                nil,
                "{on?: bool, char?: •|○|■|□|◆|➢|✓|–, color?, size?: % of text}",
                Cmd.hasTextOrShapes,
                bullets
            ),
            .cmd(
                "format.numbering",
                "Numbering",
                ["Home", "Paragraph"],
                nil,
                "{on?: bool, scheme?: arabicPeriod|arabicParenR|romanUcPeriod|romanLcPeriod|alphaUcPeriod|alphaLcParenR|alphaLcPeriod, start?: n, color?, size?: % of text}",
                Cmd.hasTextOrShapes,
                numbering
            ),
            .cmd("format.indent", "Increase List Level", ["Home", "Paragraph"], "Tab", "{}", Cmd.hasTextOrShapes) { s, _ in try level(s, 1) },
            .cmd("format.outdent", "Decrease List Level", ["Home", "Paragraph"], "Shift+Tab", "{}", Cmd.hasTextOrShapes) { s, _ in try level(s, -1) },
            .cmd(
                "format.lineSpacing",
                "Line Spacing",
                ["Home", "Paragraph"],
                nil,
                "{lines?: 1.0|1.5|2.0…, pt?: exactly}",
                Cmd.hasTextOrShapes,
                lineSpacing
            ),
            .cmd(
                "format.paragraph",
                "Paragraph…",
                ["Format"],
                nil,
                "{align?, indentLeft?: pt, indentFirst?: pt (negative = hanging), spaceBefore?: pt, spaceAfter?: pt, lineSpacing?: lines}",
                Cmd.hasTextOrShapes,
                paragraph
            ),
            .query(
                "format.ruler",
                "Ruler",
                [],
                nil,
                "{} → {x, y, width, rotated, marginLeft, indent, tabs: [{pos, align}], defaultTab} for the paragraph with the caret (x, y: the text area's top-left in slide pt)",
                Cmd.hasText,
                ruler
            ),
            .cmd(
                "format.paragraphDialog",
                "Paragraph…",
                ["Home", "Paragraph"],
                nil,
                "{align?: left|center|right|justify|justLow|distributed, indentLeft?: pt, indentRight?: pt, special?: none|first|hanging, specialBy?: pt, indentFirst?: pt, spaceBefore?: pt, spaceAfter?: pt, spaceBeforeKind?: pts|pct, spaceAfterKind?: pts|pct, lineSpacing?: lines, lineSpacingPt?: pt} — with none of these, opens the Paragraph dialog",
                Cmd.hasTextOrShapes,
                paragraphDialog
            ),
            .cmd(
                "format.tabs",
                "Tabs…",
                ["Home", "Paragraph"],
                nil,
                "{set?: [{pos, align?}] (replaces all), add?: {pos, align?: l|ctr|r|dec}, move?: {from, to}, remove?: pos, clear?: bool, defaultTab?: pt} on the selected paragraphs; with none of them, opens the Tabs dialog (pos in pt from the text area's left)",
                Cmd.hasTextOrShapes,
                tabs
            ),
            .cmd("format.anchor", "Align Text", ["Home", "Paragraph"], nil, "{anchor: top|middle|bottom}", Cmd.hasTextOrShapes, anchor),
            .cmd(
                "format.direction",
                "Text Direction",
                ["Home", "Paragraph"],
                nil,
                "{dir: horizontal|rotate90|rotate270|stacked}",
                Cmd.hasTextOrShapes,
                direction
            ),
            .cmd(
                "format.columns",
                "Columns",
                ["Home", "Paragraph"],
                nil,
                "{count?: 1-16, spacing?: pt between columns}; a key left out keeps the shape's value, and with neither the Columns dialog opens",
                Cmd.hasTextOrShapes,
                columns
            ),
            .cmd("format.autofit", "Autofit", ["Format Shape", "Text Box"], nil, "{mode: none|shrink|resize}", Cmd.hasTextOrShapes, autofit),
            .cmd("format.wrap", "Wrap Text in Shape", ["Format Shape", "Text Box"], nil, "{on: bool}", Cmd.hasTextOrShapes, wrap),
            .cmd(
                "format.margins",
                "Text Box Margins",
                ["Format Shape", "Text Box"],
                nil,
                "{left?: pt, top?: pt, right?: pt, bottom?: pt}",
                Cmd.hasTextOrShapes,
                margins
            ),
            .noundo("format.painter", "Format Painter", ["Home", "Clipboard"], "Cmd+Shift+C", "{sticky?: bool}", Cmd.hasTextOrShapes, painterPick),
            .cmd("format.painterApply", "Paste Formatting", [], "Cmd+Shift+V", "{ids?}", Cmd.hasTextOrShapes, painterApply),
            .query("format.state", "Formatting State", [], nil, "{} → the effective formatting at the selection (font, size, bold, …)", Cmd.hasDoc, state),
        ]
    }
}

// MARK: - Cross-module helpers (insert)

extension FormatCommands {
    /// Paint picked-up formatting onto a shape: its fill, line, effects and style when the painter took a
    /// shape's look, and its runs' formatting (`apply_painted`).
    public static func applyPainted(_ sh: inout Shape, _ p: Painted) {
        if p.fill != nil || p.style != nil {
            sh.fill = p.fill
            sh.line = p.line
            sh.effects = p.effects
            sh.style = p.style
        }
        if let r = p.run, var t = sh.text {
            TextEdit.formatAll(&t) { $0 = r }
            sh.text = t
        }
    }
}

// MARK: - The formatting at the selection

extension FormatCommands {
    private static func onParam(_ p: JSON, _ current: Bool?) -> Bool {
        Cmd.boolParam(p, "on") ?? !(current ?? false)
    }

    /// The effective run props at the selection (first selected run) (`current_run`).
    static func currentRun(_ s: Session) -> RunProps {
        guard let st = s.activeDoc else { return RunProps() }
        let ctx = TextCommands.ctxFor(st.doc, st.selection)
        let shape: Shape
        let para: Paragraph
        let run: RunProps
        if let t = st.selection.text {
            guard let body = TextCommands.bodyOf(st, t) else { return RunProps() }
            let a = t.ordered.0
            run = t.isRange ? TextEdit.propsAt(body, (a.para, a.char &+ 1)) : TextEdit.propsAt(body, a.tuple)
            para = body.paragraphs.at(a.para) ?? Paragraph()
            shape = st.shape(t.shape) ?? Shape.default
        } else {
            guard let sh = st.selectedShapes.first else { return RunProps() }
            para = sh.text?.paragraphs.first ?? Paragraph()
            run = para.runs.first?.props ?? RunProps()
            shape = sh
        }
        return ctx.map { Resolve.run($0, shape, para, run) } ?? run
    }

    /// The effective paragraph props at the caret (`current_para`).
    static func currentPara(_ s: Session) -> ParaProps {
        guard let st = s.activeDoc else { return ParaProps() }
        let ctx = TextCommands.ctxFor(st.doc, st.selection)
        let shape: Shape
        let para: Paragraph
        if let t = st.selection.text {
            para = TextCommands.bodyOf(st, t)?.paragraphs.at(t.caret.para) ?? Paragraph()
            shape = st.shape(t.shape) ?? Shape.default
        } else {
            guard let sh = st.selectedShapes.first else { return ParaProps() }
            para = sh.text?.paragraphs.first ?? Paragraph()
            shape = sh
        }
        return ctx.map { Resolve.para($0, shape, para) } ?? para.props
    }
}

// MARK: - Font

extension FormatCommands {
    @Sendable static func bold(_ s: Session, _ p: JSON) throws -> JSON {
        let v = onParam(p, currentRun(s).bold)
        return try TextCommands.formatRun(s) { $0.bold = v }
    }

    @Sendable static func italic(_ s: Session, _ p: JSON) throws -> JSON {
        let v = onParam(p, currentRun(s).italic)
        return try TextCommands.formatRun(s) { $0.italic = v }
    }

    @Sendable static func underline(_ s: Session, _ p: JSON) throws -> JSON {
        let cur = currentRun(s).underline.map { $0 != "none" } ?? false
        let v = onParam(p, cur)
        let style = Cmd.strParam(p, "style") ?? "sng"
        return try TextCommands.formatRun(s) { $0.underline = v ? style : "none" }
    }

    @Sendable static func strike(_ s: Session, _ p: JSON) throws -> JSON {
        let cur = currentRun(s).strike.map { $0 != .none_ } ?? false
        let v = onParam(p, cur)
        let d = Cmd.boolOr(p, "double", false)
        return try TextCommands.formatRun(s) { $0.strike = !v ? .none_ : d ? .double : .single }
    }

    @Sendable static func superscript(_ s: Session, _ p: JSON) throws -> JSON {
        let v = onParam(p, (currentRun(s).baseline ?? 0) > 0)
        return try TextCommands.formatRun(s) { $0.baseline = v ? 0.3 : 0.0 }
    }

    @Sendable static func subscriptCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let v = onParam(p, (currentRun(s).baseline ?? 0) < 0)
        return try TextCommands.formatRun(s) { $0.baseline = v ? -0.25 : 0.0 }
    }

    @Sendable static func font(_ s: Session, _ p: JSON) throws -> JSON {
        guard let f = Cmd.strParam(p, "family") else { throw Cmd.bad("format.font", "missing `family`") }
        return try TextCommands.formatRun(s) { $0.font = f }
    }

    @Sendable static func size(_ s: Session, _ p: JSON) throws -> JSON {
        guard let v0 = Cmd.f64Param(p, "size") else { throw Cmd.bad("format.size", "missing `size`") }
        let v = v0.clamped(1.0, 4000.0)
        return try TextCommands.formatRun(s) { $0.size = v }
    }

    /// PowerPoint's font size list (grow and shrink step through it).
    public static let sizes: [Double] = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 44, 48, 54, 60, 66]

    static func step(_ cur: Double, _ up: Bool) -> Double {
        if up { return sizes.first { $0 > cur + 0.01 } ?? (cur + 8.0).rustMin(4000.0) }
        return sizes.reversed().first { $0 < cur - 0.01 } ?? (cur - 1.0).rustMax(1.0)
    }

    private static func growShrink(_ s: Session, _ up: Bool) throws -> JSON {
        // Each run steps from its own size, like PowerPoint.
        _ = try s.doc()
        let base = currentRun(s).size ?? 18.0
        return try TextCommands.formatRun(s) { r in r.size = step(r.size ?? base, up) }
    }

    @Sendable static func color(_ s: Session, _ p: JSON) throws -> JSON {
        guard let c = Cmd.colorParam(p, "color") else { throw Cmd.bad("format.color", "missing or invalid `color`") }
        // A selected chart has no runs: Font Color colours its text (title, axes, legend, labels).
        let st = try s.doc()
        if st.selection.text == nil {
            let charts = st.selection.shapes.filter { id in
                if case .chart? = st.shape(id)?.kind { return true }
                return false
            }
            let onlyCharts = charts.count == st.selection.shapes.count
            if !charts.isEmpty {
                _ = try Cmd.editShapes(s, ["ids": charts.toJSON()], "format.color") { sh in
                    if case .chart(var ch) = sh.kind {
                        ch.textColor = c
                        ch.raw = nil
                        sh.kind = .chart(ch)
                    }
                }
                if onlyCharts { return Cmd.ok() }
            }
        }
        return try TextCommands.formatRun(s) { $0.fill = Fill.solid(c) }
    }

    /// `a:alpha` for `transparency` (0–1) on `c`, replacing any alpha it had; fully opaque drops it.
    private static func withTransparency(_ c: inout ColorRef, _ transparency: Double) {
        c.mods.removeAll { if case .alpha = $0 { return true }; return false }
        if transparency > 0 { c.mods.append(.alpha(Int32(rustCast: ((1.0 - transparency) * 100_000.0).rounded()))) }
    }

    /// Text Fill › Transparency: the text keeps its colour and gets an alpha (`text_transparency`).
    @Sendable static func textTransparency(_ s: Session, _ p: JSON) throws -> JSON {
        guard let v0 = Cmd.f64Param(p, "value") else { throw Cmd.bad("format.textTransparency", "missing `value` (0–1)") }
        let v = v0.clamped(0.0, 1.0)
        let shown: Fill
        switch currentRun(s).fill {
        case .some(let f) where isSolidOrGradient(f): shown = f
        default: shown = Fill.solid(ColorRef.scheme(.tx1))
        }
        return try TextCommands.formatRun(s) { r in
            var f: Fill
            switch r.fill {
            case .some(let x) where isSolidOrGradient(x): f = x
            case .some(.none_): return
            default: f = shown
            }
            switch f {
            case .solid(var color):
                withTransparency(&color, v)
                f = .solid(color: color)
            case .gradient(var g):
                for i in g.stops.indices { withTransparency(&g.stops[i].color, v) }
                f = .gradient(g)
            default: break
            }
            r.fill = f
        }
    }

    private static func isSolidOrGradient(_ f: Fill) -> Bool {
        switch f {
        case .solid, .gradient: true
        default: false
        }
    }

    /// The `lang` and `noProof` params of the language commands, checked (`language_edit`).
    private static func languageEdit(_ id: String, _ p: JSON) throws -> (inout RunProps) -> Void {
        let lang = Cmd.strParam(p, "lang")
        let noProof = Cmd.boolParam(p, "noProof")
        if lang == nil && noProof == nil { throw Cmd.bad(id, "give `lang` or `noProof`") }
        if let l = lang, l.isEmpty || l.utf8.count > 35 || !l.unicodeScalars.allSatisfy({ ($0.isASCII && $0.properties.isAlphabetic) || ("0" ... "9").contains($0) || $0 == "-" }) {
            throw Cmd.bad(id, "`lang` is a language tag such as en-US")
        }
        return { r in
            if let l = lang { r.lang = l }
            if let n = noProof { r.noProof = n ? true : nil }
        }
    }

    @Sendable static func language(_ s: Session, _ p: JSON) throws -> JSON {
        let f = try languageEdit("format.language", p)
        return try TextCommands.formatRun(s, f)
    }

    /// Every run in the deck, and the text styles new text inherits from, in one language
    /// (`language_all`).
    @Sendable static func languageAll(_ s: Session, _ p: JSON) throws -> JSON {
        let f = try languageEdit("format.languageAll", p)
        // Runs, end marks and the body's own list style levels (never creating one).
        func body(_ t: inout TextBody) {
            TextEdit.formatAll(&t, f)
            for i in t.listStyle.levels.indices where t.listStyle.levels[i] != nil {
                if var lv = t.listStyle.levels[i] {
                    f(&lv.run)
                    t.listStyle.levels[i] = lv
                }
            }
        }
        // Every text body in `list`: shapes, table cells and groups (nested at most 64 deep).
        func shapes(_ list: inout [Shape], _ depth: Int) {
            if depth > 64 { return }
            for i in list.indices {
                if list[i].text != nil {
                    var t = list[i].text ?? TextBody()
                    body(&t)
                    list[i].text = t
                }
                if case .table(var t) = list[i].kind {
                    for r in t.rows.indices {
                        for c in t.rows[r].cells.indices { body(&t.rows[r].cells[c].text) }
                    }
                    list[i].kind = .table(t)
                } else if case .group = list[i].kind {
                    list[i].mutateChildren { shapes(&$0, depth + 1) }
                }
            }
        }
        // A master or presentation text style's levels: what new text inherits.
        func styles(_ l: inout ListStyle) {
            // Level 1 always, so a deck without a default text style gets one.
            if l.level(0) == nil { l.set(0, LevelStyle()) }
            for i in l.levels.indices {
                if var lv = l.levels[i] {
                    f(&lv.run)
                    l.levels[i] = lv
                }
            }
        }
        func master(_ m: inout Master) {
            shapes(&m.shapes, 0)
            for i in m.layouts.indices { shapes(&m.layouts[i].shapes, 0) }
            styles(&m.titleStyle)
            styles(&m.bodyStyle)
            styles(&m.otherStyle)
        }
        try s.edit { doc, _ in
            for i in doc.slides.indices {
                shapes(&doc.slides[i].shapes, 0)
                body(&doc.slides[i].notes)
            }
            for i in doc.masters.indices { master(&doc.masters[i]) }
            if var m = doc.notesMaster {
                master(&m)
                doc.notesMaster = m
            }
            if var m = doc.handoutMaster {
                master(&m)
                doc.handoutMaster = m
            }
            styles(&doc.defaultTextStyle)
        }
        return Cmd.ok()
    }

    @Sendable static func highlight(_ s: Session, _ p: JSON) throws -> JSON {
        let c = Cmd.colorParam(p, "color")
        return try TextCommands.formatRun(s) { $0.highlight = c }
    }

    @Sendable static func caps(_ s: Session, _ p: JSON) throws -> JSON {
        let c: Caps = switch Cmd.strParam(p, "caps") ?? "none" {
        case "small": .small
        case "all": .all
        default: .none_
        }
        return try TextCommands.formatRun(s) { $0.caps = c }
    }

    @Sendable static func spacing(_ s: Session, _ p: JSON) throws -> JSON {
        let v = (Cmd.f64Param(p, "pt") ?? 0.0).clamped(-100.0, 400.0)
        return try TextCommands.formatRun(s) { $0.spacing = v }
    }
}

// MARK: - The Font dialog

extension FormatCommands {
    /// Character formatting applied together, so the Font dialog is one undo step.
    struct FontEdits {
        var family: String?
        var size: Double?
        var bold: Bool?
        var italic: Bool?
        var underline: String?
        var color: ColorRef?
        var strike: Strike?
        var baseline: Double?
        var caps: Caps?
        var spacing: Double?

        var isEmpty: Bool {
            family == nil && size == nil && bold == nil && italic == nil && underline == nil && color == nil && strike == nil
                && baseline == nil && caps == nil && spacing == nil
        }

        func write(_ r: inout RunProps) {
            if let f = family { r.font = f }
            if let v = size { r.size = v }
            if let v = bold { r.bold = v }
            if let v = italic { r.italic = v }
            if let u = underline { r.underline = u }
            if let c = color { r.fill = Fill.solid(c) }
            if let v = strike { r.strike = v }
            if let v = baseline { r.baseline = v }
            if let v = caps { r.caps = v }
            if let v = spacing { r.spacing = v }
        }
    }

    private static func fontBool(_ p: JSON, _ key: String) throws -> Bool? {
        guard let v = p.get(key) else { return nil }
        guard case .bool(let b) = v else { throw Cmd.bad("format.fontDialog", "`\(key)` must be a bool") }
        return b
    }

    private static func fontStr(_ p: JSON, _ key: String) throws -> String? {
        guard let v = p.get(key) else { return nil }
        guard case .string(let s) = v else { throw Cmd.bad("format.fontDialog", "`\(key)` must be a string") }
        return s
    }

    private static func finiteNumber(_ v: JSON) -> Double? {
        v.asF64.flatMap { $0.isFinite ? $0 : nil }
    }

    static func fontEdits(_ p: JSON) throws -> FontEdits {
        var e = FontEdits()
        if let s = try fontStr(p, "family") {
            let t = String(rustTrim(s))
            if t.isEmpty || t.charCount > 200 { throw Cmd.bad("format.fontDialog", "`family` must be 1–200 characters") }
            e.family = t
        }
        if let v = p.get("size") {
            guard let n = finiteNumber(v) else { throw Cmd.bad("format.fontDialog", "`size` must be a finite number") }
            e.size = n.clamped(1.0, 4000.0)
        }
        if let s = try fontStr(p, "underline") {
            if !["none", "sng", "dbl", "heavy", "dotted", "dash", "wavy"].contains(s) {
                throw Cmd.bad("format.fontDialog", "`underline` must be none, sng, dbl, heavy, dotted, dash or wavy")
            }
            e.underline = s
        }
        if p.get("color") != nil {
            guard let c = Cmd.colorParam(p, "color") else { throw Cmd.bad("format.fontDialog", "invalid `color`") }
            e.color = c
        }
        switch try fontStr(p, "strike") {
        case nil: break
        case "none": e.strike = .none_
        case "sng", "single": e.strike = .single
        case "dbl", "double": e.strike = .double
        default: throw Cmd.bad("format.fontDialog", "`strike` must be none, sng or dbl")
        }
        switch p.get("baseline") {
        case nil: break
        case .string(let s)?:
            switch s {
            case "none": e.baseline = 0.0
            case "super", "superscript": e.baseline = 0.3
            case "sub", "subscript": e.baseline = -0.25
            default: throw Cmd.bad("format.fontDialog", "`baseline` must be none, super, sub or a fraction")
            }
        case let v? where v.isNumber:
            guard let f = finiteNumber(v) else { throw Cmd.bad("format.fontDialog", "`baseline` must be finite") }
            e.baseline = f.clamped(-1.0, 1.0)
        default:
            throw Cmd.bad("format.fontDialog", "`baseline` must be none, super, sub or a fraction")
        }
        switch try fontStr(p, "caps") {
        case nil: break
        case "none": e.caps = .none_
        case "small": e.caps = .small
        case "all": e.caps = .all
        default: throw Cmd.bad("format.fontDialog", "`caps` must be none, small or all")
        }
        if let v = p.get("spacing") {
            guard let n = finiteNumber(v) else { throw Cmd.bad("format.fontDialog", "`spacing` must be a finite number") }
            e.spacing = n.clamped(-100.0, 400.0)
        }
        e.bold = try fontBool(p, "bold")
        e.italic = try fontBool(p, "italic")
        return e
    }

    /// A colour as a `format.fontDialog` / `format.color` parameter, including transforms
    /// (`color_command_value`).
    static func colorCommandValue(_ c: ColorRef) -> JSON {
        var o = JSONObject()
        for m in c.mods {
            if let v = m.value { o.set(m.xmlName, .integer(Int(v))) }
        }
        switch c.base {
        case .rgb(let rgb) where o.entries.isEmpty: return .string("#\(rgb.hex)")
        case .rgb(let rgb):
            o.set("rgb", .string("#\(rgb.hex)"))
            return .object(o)
        case .scheme(let slot):
            o.set("scheme", .string(slot.xmlName))
            return .object(o)
        case .preset(let name): return .string(name)
        case .system(_, let last): return .string("#\(last.hex)")
        }
    }

    private static func fontDialogParams(_ s: Session) -> JSON {
        let r = currentRun(s)
        let family = s.activeDoc.flatMap { st in TextCommands.ctxFor(st.doc, st.selection).map { Resolve.fontFamily($0, r) } } ?? ""
        let baseline = r.baseline ?? 0
        var v: JSON = [
            "family": .string(family),
            "size": .num(r.size ?? 18.0),
            "bold": .bool(r.bold ?? false),
            "italic": .bool(r.italic ?? false),
            "underline": .string(r.underline.flatMap { $0 != "none" ? $0 : nil } ?? "none"),
            "strike": .string(r.strike == .double ? "dbl" : r.strike == .single ? "sng" : "none"),
            "baseline": .string(baseline > 0 ? "super" : baseline < 0 ? "sub" : "none"),
            "caps": .string(r.caps == .small ? "small" : r.caps == .all ? "all" : "none"),
            "spacing": .num(r.spacing ?? 0.0),
        ]
        if case .solid(let color)? = r.fill { v.set("color", colorCommandValue(color)) }
        return v
    }

    @Sendable static func fontDialog(_ s: Session, _ p: JSON) throws -> JSON {
        let edits = try fontEdits(p)
        if edits.isEmpty {
            s.uiRequests.append(.dialog(id: "font", params: fontDialogParams(s)))
            return Cmd.ok()
        }
        return try TextCommands.formatRun(s) { edits.write(&$0) }
    }

    @Sendable static func clear(_ s: Session, _ p: JSON) throws -> JSON {
        try TextCommands.formatRun(s) { r in r = RunProps(link: r.link, lang: r.lang) }
    }

    @Sendable static func textShadow(_ s: Session, _ p: JSON) throws -> JSON {
        let v = onParam(p, currentRun(s).shadow != nil)
        let sh = Shadow(
            color: ColorRef.rgb(Rgba.black).with(.alpha(43000)), blur: 3.0, dist: 2.0, dir: 45.0, inner: false, sx: 1.0, sy: 1.0, kx: 0.0,
            ky: 0.0, align: "", rotateWithShape: false
        )
        return try TextCommands.formatRun(s) { $0.shadow = v ? sh : nil }
    }

    @Sendable static func textOutline(_ s: Session, _ p: JSON) throws -> JSON {
        let c = Cmd.colorParam(p, "color")
        let w = Cmd.f64Or(p, "width", 0.75)
        return try TextCommands.formatRun(s) { $0.outline = c.map { Line.solid($0, w) } }
    }

    @Sendable static func textWarp(_ s: Session, _ p: JSON) throws -> JSON {
        guard let preset = Cmd.strParam(p, "preset") else { throw Cmd.bad("format.textWarp", "missing `preset`") }
        let clear = preset == "none" || preset == "textNoShape"
        if !clear && !Warp.isSupported(preset) { throw Cmd.bad("format.textWarp", "unknown text transform `\(preset)`") }
        var adj: [Double] = []
        switch p.get("adj") {
        case nil: break
        case .array(let arr)?:
            if arr.count > 8 { throw Cmd.bad("format.textWarp", "at most 8 adjust values") }
            for a in arr {
                guard let n = finiteNumber(a) else { throw Cmd.bad("format.textWarp", "adjust values must be finite numbers") }
                adj.append(n.clamped(-2.0e9, 2.0e9))
            }
        default:
            throw Cmd.bad("format.textWarp", "`adj` must be an array of numbers")
        }
        let stored: String? = clear ? nil : preset
        return try TextCommands.formatBody(s) { b in
            b.warp = stored
            b.warpAdj = adj
        }
    }

    @Sendable static func changeCase(_ s: Session, _ p: JSON) throws -> JSON {
        let mode = Cmd.strParam(p, "mode") ?? "cycle"
        let st = try s.doc()
        if let t = st.selection.text {
            var (a, b) = (t.ordered.0.tuple, t.ordered.1.tuple)
            let body = TextCommands.bodyOf(st, t) ?? TextBody()
            let collapsed = a == b
            if collapsed {
                // Shift+F3 with a bare caret changes the word it is in and puts the caret at its start.
                let (wa, wb) = TextEdit.wordAt(body, a)
                let isWord = TextEdit.textRange(body, wa, wb).unicodeScalars.contains(where: rustIsAlphanumeric)
                if !(isWord && wa.1 <= a.1 && a.1 < wb.1) { return Cmd.ok() }
                (a, b) = (wa, wb)
            }
            let m = mode == "cycle" ? TextEdit.nextCase(TextEdit.textRange(body, a, b)) : mode
            let (ca, cb) = (a, b)
            try TextCommands.editText(s) { body, t in
                let last = max(body.paragraphs.count - 1, 0)
                let hi = min(cb.0, last)
                if ca.0 <= hi {
                    for pi in ca.0 ... hi where body.paragraphs.indices.contains(pi) {
                        let n = body.paragraphs[pi].charLen
                        let from = pi == ca.0 ? ca.1 : 0
                        let to = pi == cb.0 ? cb.1 : n
                        var pos = 0
                        var pieces: [(Int, Int, Int)] = []
                        for (ri, r) in body.paragraphs[pi].runs.enumerated() {
                            // Breaks and fields are read for context (a break ends a word) but not rewritten.
                            let len = r.charLen
                            let rs = max(from, pos) - pos
                            let re = max(min(to, pos + len) - pos, 0)
                            if re > rs { pieces.append((ri, rs, re)) }
                            pos += len
                        }
                        let runs = body.paragraphs[pi].runs
                        let mids: [String] = pieces.map { ri, rs, re in
                            guard let r = runs.at(ri) else { return "" }
                            return String(String.UnicodeScalarView(r.content.unicodeScalars.dropFirst(rs).prefix(re - rs)))
                        }
                        let changed = TextEdit.changeCaseParts(mids, m)
                        for ((ri, rs, re), new) in zip(pieces, changed) {
                            guard body.paragraphs[pi].runs.indices.contains(ri), body.paragraphs[pi].runs[ri].kind == .text else { continue }
                            let sc = body.paragraphs[pi].runs[ri].text.unicodeScalars
                            let pre = String(String.UnicodeScalarView(sc.prefix(rs)))
                            let post = String(String.UnicodeScalarView(sc.dropFirst(re)))
                            body.paragraphs[pi].runs[ri].text = pre + new + post
                        }
                    }
                }
                if collapsed {
                    t.anchor = TextPoint(ca.0, ca.1)
                    t.caret = TextPoint(ca.0, ca.1)
                }
            }
            return Cmd.ok()
        }
        let m: String
        if mode == "cycle" {
            let all = st.selection.shapes.compactMap { st.shape($0)?.text?.text }.joined(separator: "\n")
            m = TextEdit.nextCase(all)
        } else {
            m = mode
        }
        return try Cmd.editShapes(s, .emptyObject, "format.case") { sh in
            guard var t = sh.text else { return }
            for i in t.paragraphs.indices {
                // Breaks and fields are read for context (a break ends a word) but not rewritten.
                let texts = t.paragraphs[i].runs.map(\.content)
                let changed = TextEdit.changeCaseParts(texts, m)
                for (k, new) in changed.enumerated() where t.paragraphs[i].runs.indices.contains(k) && t.paragraphs[i].runs[k].kind == .text {
                    t.paragraphs[i].runs[k].text = new
                }
            }
            sh.text = t
        }
    }
}

// MARK: - Paragraph

extension FormatCommands {
    private static func alignTo(_ s: Session, _ a: Align) throws -> JSON {
        try TextCommands.formatPara(s) { $0.props.align = a }
    }

    @Sendable static func align(_ s: Session, _ p: JSON) throws -> JSON {
        let a: Align = switch Cmd.strParam(p, "align") ?? "left" {
        case "center", "centre", "ctr": .center
        case "right", "r": .right
        case "justify", "just": .justify
        case "justifyLow", "justLow": .justLow
        case "distributed", "dist": .distributed
        default: .left
        }
        return try alignTo(s, a)
    }

    /// Paragraph reading direction. Switching it mirrors left and right alignment, so text that sat at
    /// the start edge stays there.
    @Sendable static func rtl(_ s: Session, _ p: JSON) throws -> JSON {
        let on = onParam(p, currentPara(s).rtl)
        return try TextCommands.formatPara(s) { para in
            if (para.props.rtl ?? false) != on {
                switch para.props.align {
                case nil, .left?: para.props.align = .right
                case .right?: para.props.align = .left
                default: break
                }
            }
            para.props.rtl = on
        }
    }

    @Sendable static func bullets(_ s: Session, _ p: JSON) throws -> JSON {
        let cur: Bool = if case .char? = currentPara(s).bullet { true } else { false }
        let on = onParam(p, cur)
        let ch = Cmd.strParam(p, "char") ?? "•"
        let col = Cmd.colorParam(p, "color")
        let size = Cmd.f64Param(p, "size").map { ($0 / 100.0).clamped(0.25, 4.0) }
        let explicitChar = p.get("char") != nil
        return try TextCommands.formatPara(s) { para in
            if on {
                para.props.bullet = .char(char: ch)
                para.props.bulletFont = explicitChar ? "Arial" : para.props.bulletFont
                if col != nil { para.props.bulletColor = col }
                if size != nil { para.props.bulletSize = size }
                if (para.props.indent.map { $0 >= 0 } ?? true) && (para.props.marginLeft.map { $0 == 0 } ?? true) {
                    para.props.marginLeft = 18.0 + 36.0 * Double(para.level)
                    para.props.indent = -18.0
                }
            } else {
                para.props.bullet = .none_
                para.props.indent = 0.0
                para.props.marginLeft = 36.0 * Double(para.level)
            }
        }
    }

    @Sendable static func numbering(_ s: Session, _ p: JSON) throws -> JSON {
        let cur: Bool = if case .autoNum? = currentPara(s).bullet { true } else { false }
        let on = onParam(p, cur)
        let scheme = Cmd.strParam(p, "scheme") ?? "arabicPeriod"
        let start = p.get("start")?.asU64.map { UInt32(min(max($0, 1), 32767)) } ?? 1
        let col = Cmd.colorParam(p, "color")
        let size = Cmd.f64Param(p, "size").map { ($0 / 100.0).clamped(0.25, 4.0) }
        return try TextCommands.formatPara(s) { para in
            if on {
                para.props.bullet = .autoNum(scheme: scheme, startAt: start)
                if col != nil { para.props.bulletColor = col }
                if size != nil { para.props.bulletSize = size }
                para.props.marginLeft = 27.0 + 36.0 * Double(para.level)
                para.props.indent = -27.0
            } else {
                para.props.bullet = .none_
                para.props.indent = 0.0
                para.props.marginLeft = 36.0 * Double(para.level)
            }
        }
    }

    private static func level(_ s: Session, _ d: Int) throws -> JSON {
        try TextCommands.formatPara(s) { p in
            let l = UInt8(min(max(Int(p.level) + d, 0), 8))
            // Explicit indents shift with the level.
            if l != p.level {
                if let m = p.props.marginLeft { p.props.marginLeft = (m + 36.0 * Double(d)).rustMax(0.0) }
                p.level = l
            }
        }
    }

    @Sendable static func lineSpacing(_ s: Session, _ p: JSON) throws -> JSON {
        let sp: Spacing = if let pt = Cmd.f64Param(p, "pt") { .pts(pt.clamped(0.0, 1584.0)) } else { .pct(Cmd.f64Or(p, "lines", 1.0).clamped(0.0, 9.99)) }
        return try TextCommands.formatPara(s) { $0.props.lineSpacing = sp }
    }

    @Sendable static func paragraph(_ s: Session, _ p: JSON) throws -> JSON {
        let a: Align? = Cmd.strParam(p, "align").map { a in
            switch a {
            case "center": .center
            case "right": .right
            case "justify": .justify
            case "distributed": .distributed
            default: .left
            }
        }
        let ml = Cmd.f64Param(p, "indentLeft")
        let ind = Cmd.f64Param(p, "indentFirst")
        let sb = Cmd.f64Param(p, "spaceBefore")
        let sa = Cmd.f64Param(p, "spaceAfter")
        let ls = Cmd.f64Param(p, "lineSpacing")
        let lsp = Cmd.f64Param(p, "lineSpacingPt")
        return try TextCommands.formatPara(s) { para in
            if a != nil { para.props.align = a }
            if ml != nil { para.props.marginLeft = ml.map { $0.rustMax(0.0) } }
            if ind != nil { para.props.indent = ind }
            if let v = sb { para.props.spaceBefore = .pts(v.rustMax(0.0)) }
            if let v = sa { para.props.spaceAfter = .pts(v.rustMax(0.0)) }
            if let v = ls { para.props.lineSpacing = .pct(v.clamped(0.0, 9.99)) }
            if let v = lsp { para.props.lineSpacing = .pts(v.rustMax(0.0)) }
        }
    }

    private static let paraDialogKeys = ["align", "indentLeft", "indentRight", "indentFirst", "special", "specialBy", "spaceBefore", "spaceAfter", "lineSpacing", "lineSpacingPt"]

    private static func finiteKey(_ p: JSON, _ cmd: String, _ key: String) throws -> Double? {
        guard let v = p.get(key) else { return nil }
        guard let n = finiteNumber(v) else { throw Cmd.bad(cmd, "`\(key)` must be a finite number") }
        return n
    }

    private static func clampPt(_ v: Double) -> Double { v.clamped(0.0, 1584.0) }

    private static func parseAlign(_ cmd: String, _ s: String) throws -> Align {
        switch s {
        case "left", "l": .left
        case "center", "ctr": .center
        case "right", "r": .right
        case "justify", "just": .justify
        case "justLow": .justLow
        case "distributed", "dist": .distributed
        default: throw Cmd.bad(cmd, "`align` must be left, center, right, justify, justLow or distributed")
        }
    }

    private static func alignName(_ a: Align) -> String {
        switch a {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        case .justify: "justify"
        case .justLow: "justLow"
        case .distributed: "distributed"
        }
    }

    private static func spacingParts(_ s: Spacing?) -> (String, Double) {
        switch s {
        case .pct(let v)?: ("pct", v)
        case .pts(let v)?: ("pts", v)
        case nil: ("pts", 0.0)
        }
    }

    private static func tabsJSON(_ tabs: [TabStop]?) -> JSON {
        .array((tabs ?? []).map { ["pos": .num($0.pos), "align": .string($0.align)] })
    }

    private static func paragraphDialogParams(_ s: Session) -> JSON {
        let pp = currentPara(s)
        let indent = pp.indent ?? 0
        let (special, by): (String, Double) = indent > 0.05 ? ("first", indent) : indent < -0.05 ? ("hanging", -indent) : ("none", 0.0)
        let (lineKind, lineValue): (String, Double) = switch pp.lineSpacing {
        case .pts(let v)?: ("exactly", v)
        case .pct(let v)?: ("multiple", v)
        case nil: ("multiple", 1.0)
        }
        let (beforeKind, before) = spacingParts(pp.spaceBefore)
        let (afterKind, after) = spacingParts(pp.spaceAfter)
        return [
            "align": .string(alignName(pp.align ?? .left)),
            "indentLeft": .num(pp.marginLeft ?? 0),
            "indentRight": .num(pp.marginRight ?? 0),
            "special": .string(special),
            "specialBy": .num(by),
            "spaceBefore": .num(before),
            "spaceBeforeKind": .string(beforeKind),
            "spaceAfter": .num(after),
            "spaceAfterKind": .string(afterKind),
            "lineKind": .string(lineKind),
            "lineValue": .num(lineValue),
            "tabs": tabsJSON(pp.tabs),
            "defaultTab": .num(pp.defaultTab ?? 72.0),
        ]
    }

    private static func writeSpacing(_ kind: String?, _ value: Double) -> Spacing {
        kind == "pct" ? .pct(value.clamped(0.0, 10.0)) : .pts(clampPt(value))
    }

    @Sendable static func paragraphDialog(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "format.paragraphDialog"
        if !paraDialogKeys.contains(where: { p.get($0) != nil }) {
            s.uiRequests.append(.dialog(id: "paragraph", params: paragraphDialogParams(s)))
            return Cmd.ok()
        }
        let align: Align?
        switch p.get("align") {
        case nil: align = nil
        case .string(let a)?: align = try parseAlign(cmd, a)
        default: throw Cmd.bad(cmd, "`align` must be a string")
        }
        let indentLeft = try finiteKey(p, cmd, "indentLeft").map(clampPt)
        let indentRight = try finiteKey(p, cmd, "indentRight").map(clampPt)
        let specialBy = try finiteKey(p, cmd, "specialBy").map { clampPt($0.rustMax(0.0)) }
        let indent: Double?
        switch p.get("special") {
        case nil:
            indent = try finiteKey(p, cmd, "indentFirst").map { $0.clamped(-1584.0, 1584.0) }
        case .string(let kind)?:
            let by = specialBy ?? 0.0
            switch kind {
            case "none": indent = 0.0
            case "first", "firstLine": indent = by
            case "hanging", "hang": indent = -by
            default: throw Cmd.bad(cmd, "`special` must be none, first or hanging")
            }
        default:
            throw Cmd.bad(cmd, "`special` must be none, first or hanging")
        }
        let spaceBefore = try finiteKey(p, cmd, "spaceBefore")
        let spaceAfter = try finiteKey(p, cmd, "spaceAfter")
        let beforeKind = Cmd.strParam(p, "spaceBeforeKind")
        let afterKind = Cmd.strParam(p, "spaceAfterKind")
        for kind in [beforeKind, afterKind].compactMap({ $0 }) where kind != "pts" && kind != "pct" {
            throw Cmd.bad(cmd, "spacing kind must be pts or pct")
        }
        let lineMult = try finiteKey(p, cmd, "lineSpacing").map { $0.clamped(0.0, 9.99) }
        let linePt = try finiteKey(p, cmd, "lineSpacingPt").map(clampPt)
        return try TextCommands.formatPara(s) { para in
            if align != nil { para.props.align = align }
            if indentLeft != nil { para.props.marginLeft = indentLeft }
            if indentRight != nil { para.props.marginRight = indentRight }
            if indent != nil { para.props.indent = indent }
            if let v = spaceBefore { para.props.spaceBefore = writeSpacing(beforeKind, v) }
            if let v = spaceAfter { para.props.spaceAfter = writeSpacing(afterKind, v) }
            if let v = lineMult { para.props.lineSpacing = .pct(v) }
            if let v = linePt { para.props.lineSpacing = .pts(v) }
        }
    }

    private static func tabAlign(_ s: String) -> String? {
        switch s {
        case "l", "left": "l"
        case "ctr", "center": "ctr"
        case "r", "right": "r"
        case "dec", "decimal": "dec"
        default: nil
        }
    }

    private static func tabsParams(_ s: Session) -> JSON {
        let pp = currentPara(s)
        return ["tabs": tabsJSON(pp.tabs), "defaultTab": .num(pp.defaultTab ?? 72.0)]
    }

    @Sendable static func anchor(_ s: Session, _ p: JSON) throws -> JSON {
        let a: Anchor = switch Cmd.strParam(p, "anchor") ?? "top" {
        case "middle", "center", "ctr": .middle
        case "bottom", "b": .bottom
        default: .top
        }
        return try TextCommands.formatBody(s) { $0.anchor = a }
    }

    @Sendable static func direction(_ s: Session, _ p: JSON) throws -> JSON {
        let d: TextDir = switch Cmd.strParam(p, "dir") ?? "horizontal" {
        case "rotate90", "vert": .vertical
        case "rotate270", "vert270": .vertical270
        case "stacked": .stacked
        default: .horizontal
        }
        return try TextCommands.formatBody(s) { $0.vert = d }
    }

    /// The edited or first selected shape's columns as drawn: the count and the spacing in points.
    private static func currentColumns(_ s: Session) -> (UInt32, Double) {
        guard let st = s.activeDoc else { return (1, 0) }
        let id: ShapeId? = if let t = st.selection.text, !t.notes { t.shape } else { st.selection.shapes.first }
        guard let sh = id.flatMap({ st.shape($0) }) else { return (1, 0) }
        let body = TextCommands.ctxFor(st.doc, st.selection).map { Resolve.body($0, sh) } ?? sh.text?.body ?? BodyProps()
        return (min(max(body.columns ?? 1, 1), 16), (body.colSpacing ?? 0).rustMax(0))
    }

    @Sendable static func columns(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "format.columns"
        var count: UInt32?
        if let v = p.get("count") {
            guard let n = v.asF64, n.truncatingRemainder(dividingBy: 1) == 0, n >= 1, n <= 16 else {
                throw Cmd.bad(cmd, "`count` must be a whole number from 1 to 16")
            }
            count = UInt32(rustCast: n)
        }
        let spacing = try finiteKey(p, cmd, "spacing").map(clampPt)
        if count == nil && spacing == nil {
            let (c, sp) = currentColumns(s)
            s.uiRequests.append(.dialog(id: "columns", params: ["count": .integer(Int(c)), "spacing": .num(sp)]))
            return Cmd.ok()
        }
        return try TextCommands.formatBody(s) { b in
            if let n = count { b.columns = n }
            if let sp = spacing { b.colSpacing = sp }
        }
    }

    @Sendable static func autofit(_ s: Session, _ p: JSON) throws -> JSON {
        let m: AutoFit = switch Cmd.strParam(p, "mode") ?? "none" {
        case "shrink": .shrink(fontScale: 1.0, lineReduction: 0.0)
        case "resize", "shape": .shape
        default: .none_
        }
        return try TextCommands.formatBody(s) { $0.autofit = m }
    }

    @Sendable static func wrap(_ s: Session, _ p: JSON) throws -> JSON {
        let on = Cmd.boolOr(p, "on", true)
        return try TextCommands.formatBody(s) { $0.wrap = on }
    }

    @Sendable static func margins(_ s: Session, _ p: JSON) throws -> JSON {
        let (l, t, r, b) = (Cmd.f64Param(p, "left"), Cmd.f64Param(p, "top"), Cmd.f64Param(p, "right"), Cmd.f64Param(p, "bottom"))
        return try TextCommands.formatBody(s) { bp in
            if l != nil { bp.insetL = l.map { $0.rustMax(0.0) } }
            if t != nil { bp.insetT = t.map { $0.rustMax(0.0) } }
            if r != nil { bp.insetR = r.map { $0.rustMax(0.0) } }
            if b != nil { bp.insetB = b.map { $0.rustMax(0.0) } }
        }
    }
}

// MARK: - The Format Painter, the state, fonts, the ruler and tabs

extension FormatCommands {
    @Sendable static func painterPick(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        var painted = Painted()
        if let t = st.selection.text {
            if let b = TextCommands.bodyOf(st, t) {
                let a = t.ordered.0
                painted.run = TextEdit.propsAt(b, (a.para, a.char &+ 1))
                painted.para = b.paragraphs.at(a.para)?.props
            }
        } else if let sh = st.selectedShapes.first {
            painted.fill = sh.fill
            painted.line = sh.line
            painted.effects = sh.effects
            painted.style = sh.style
            painted.run = sh.text?.paragraphs.first?.runs.first?.props
        }
        s.painter = (painted, Cmd.boolOr(p, "sticky", false))
        return ["armed": true]
    }

    /// The paragraphs the text selection covers whole: it starts at or before their start and reaches
    /// their end (`covered_paragraphs`).
    private static func coveredParagraphs(_ s: Session) -> [Int] {
        guard let st = s.activeDoc, let t = st.selection.text, let body = TextCommands.bodyOf(st, t) else { return [] }
        let (a, b) = t.ordered
        // A hostile selection can point past the body: walk only the paragraphs it has.
        let hi = min(b.para, max(body.paragraphs.count - 1, 0))
        if a.para > hi { return [] }
        return (a.para ... hi).filter { pi in
            guard let para = body.paragraphs.at(pi) else { return false }
            let starts = pi > a.para || a.char == 0
            let ends: Bool = if pi < b.para { true } else if b.para > a.para && b.char == 0 { false } else { b.char >= para.charLen }
            return starts && ends
        }
    }

    @Sendable static func painterApply(_ s: Session, _ p: JSON) throws -> JSON {
        guard let (painted, sticky) = s.painter else { throw Cmd.bad("format.painterApply", "pick formatting with the Format Painter first") }
        if !sticky { s.painter = nil }
        if try s.doc().selection.text?.isRange == true && Cmd.idsParam(p, "ids") == nil {
            if let r = painted.run { try TextCommands.formatRun(s) { $0 = r } }
            // Paragraph formatting goes only onto paragraphs the selection covers whole.
            let covered = coveredParagraphs(s)
            if let pp = painted.para, !covered.isEmpty {
                try TextCommands.editText(s) { body, _ in
                    for pi in covered where body.paragraphs.indices.contains(pi) { body.paragraphs[pi].props = pp }
                }
            }
            return Cmd.ok()
        }
        return try Cmd.editShapes(s, p, "format.painterApply") { applyPainted(&$0, painted) }
    }

    @Sendable static func state(_ s: Session, _ p: JSON) throws -> JSON {
        let r = currentRun(s)
        let pp = currentPara(s)
        let st = try s.doc()
        let family = TextCommands.ctxFor(st.doc, st.selection).map { Resolve.fontFamily($0, r) } ?? ""
        let bullets: Bool = if case .char? = pp.bullet { true } else { false }
        let numbering: Bool = if case .autoNum? = pp.bullet { true } else { false }
        return [
            "font": .string(family),
            "fontRef": .opt(r.font),
            "size": r.size.map { JSON.num($0) } ?? .null,
            "bold": .bool(r.bold ?? false),
            "italic": .bool(r.italic ?? false),
            "underline": .bool(r.underline.map { $0 != "none" } ?? false),
            "strike": .bool(r.strike.map { $0 != .none_ } ?? false),
            "superscript": .bool((r.baseline ?? 0) > 0),
            "subscript": .bool((r.baseline ?? 0) < 0),
            "align": .opt(pp.align?.xml),
            "bullets": .bool(bullets),
            "numbering": .bool(numbering),
            "lang": .opt(r.lang),
            "lineSpacing": pp.lineSpacing?.toJSON() ?? .null,
            "painter": .bool(s.painter != nil),
        ]
    }

    /// Add a font from its bytes for this session (it then shows in the font menu and draws).
    @Sendable static func fontAdd(_ s: Session, _ p: JSON) throws -> JSON {
        guard let data = Cmd.strParam(p, "data").flatMap(Cmd.base64Decode) else { throw Cmd.bad("font.add", "missing or invalid base64 `data`") }
        if data.count > 64 << 20 { throw Cmd.bad("font.add", "font file larger than 64 MB") }
        let faces = FontDB.shared.addFont(data)
        if faces == 0 { throw Cmd.bad("font.add", "not a font DeckCraft can read (or already added)") }
        return ["faces": .integer(faces)]
    }

    /// Catalog the installed fonts again. CoreText catalogs installed fonts as they come and go, so there
    /// is nothing to load: `faces` is 0 and `families` counts what CoreText and the session know.
    @Sendable static func fontRescan(_ s: Session, _ p: JSON) throws -> JSON {
        ["faces": 0, "families": .integer(FontDB.shared.families().count)]
    }

    /// What the horizontal ruler shows while editing text: the paragraph's indents and tab stops, and
    /// where its text area sits on the slide.
    @Sendable static func ruler(_ s: Session, _ p: JSON) throws -> JSON {
        let props = currentPara(s)
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("format.ruler", "not editing text") }
        var (x, y, w, rotated) = (0.0, 0.0, 0.0, true)
        if !t.notes, let sh = st.shape(t.shape) {
            let ctx = TextCommands.ctxFor(st.doc, st.selection)
            let xf = ctx.map { Resolve.xfrm($0, sh) } ?? sh.xfrm ?? Xfrm()
            let body = ctx.map { Resolve.body($0, sh) } ?? sh.text?.body ?? BodyProps()
            let (l, r, tp) = (body.insetL ?? 7.2, body.insetR ?? 7.2, body.insetT ?? 3.6)
            (x, y, w) = (xf.x + l, xf.y + tp, (xf.w - l - r).rustMax(0.0))
            rotated = xf.rot != 0 || (body.vert.map { $0 != .horizontal } ?? false)
        }
        return [
            "x": .num(x), "y": .num(y), "width": .num(w), "rotated": .bool(rotated),
            "marginLeft": .num(props.marginLeft ?? 0), "indent": .num(props.indent ?? 0),
            "tabs": tabsJSON(props.tabs), "defaultTab": .num(props.defaultTab ?? 72.0),
        ]
    }

    private static let maxTabs = 32

    /// Rust's `f64::total_cmp` as a less-than.
    private static func totalLess(_ a: Double, _ b: Double) -> Bool {
        func key(_ v: Double) -> Int64 {
            let bits = Int64(bitPattern: v.bitPattern)
            return bits ^ Int64(bitPattern: UInt64(bitPattern: bits >> 63) >> 1)
        }
        return key(a) < key(b)
    }

    @Sendable static func tabs(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "format.tabs"
        func fin(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0.clamped(0.0, 4000.0) : nil } }
        func alignOf(_ v: JSON) -> String {
            switch v.get("align")?.asStr ?? "l" {
            case "ctr", "center": "ctr"
            case "r", "right": "r"
            case "dec", "decimal": "dec"
            default: "l"
            }
        }
        let add: (Double, String)? = p.get("add").flatMap { a in fin(a.get("pos")?.asF64).map { ($0, alignOf(a)) } }
        let mv: (Double, Double)? = p.get("move").flatMap { m in
            guard let f = fin(m.get("from")?.asF64), let t = fin(m.get("to")?.asF64) else { return nil }
            return (f, t)
        }
        let remove = fin(p.get("remove")?.asF64)
        // `set` replaces every stop: entries without a usable position are dropped, an unknown alignment or a
        // non-object entry is an error; stops within 0.05 pt collapse (the last wins).
        var set: [TabStop]?
        switch p.get("set") {
        case nil: set = nil
        case .array(let items)?:
            if items.count > 64 { throw Cmd.bad(cmd, "`set` has more than 64 tab stops") }
            var out: [TabStop] = []
            for (i, item) in items.enumerated() {
                guard let obj = item.asObject else { throw Cmd.bad(cmd, "tab stop \(i) must be an object") }
                guard let pos = obj["pos"]?.asF64.flatMap({ $0.isFinite ? clampPt($0) : nil }) else { continue }
                let align: String
                if let a = obj["align"]?.asStr {
                    guard let x = tabAlign(a) else { throw Cmd.bad(cmd, "tab stop \(i) align must be l, ctr, r or dec") }
                    align = x
                } else {
                    align = "l"
                }
                if let k = out.firstIndex(where: { abs($0.pos - pos) < 0.05 }) {
                    out[k] = TabStop(pos: pos, align: align)
                } else {
                    out.append(TabStop(pos: pos, align: align))
                }
            }
            set = out
        default:
            throw Cmd.bad(cmd, "`set` must be an array")
        }
        let clear = Cmd.boolOr(p, "clear", false)
        let defaultTab = try finiteKey(p, cmd, "defaultTab").map { $0.clamped(1.0, 1584.0) }
        let editsStops = set != nil || add != nil || mv != nil || remove != nil || clear
        if !editsStops && defaultTab == nil {
            // No fields: open the Tabs dialog on the caret's paragraph.
            s.uiRequests.append(.dialog(id: "tabs", params: tabsParams(s)))
            return Cmd.ok()
        }
        // The stops as the caret's paragraph shows them (inherited ones included).
        let base = currentPara(s).tabs ?? []
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }
        var stops = clear ? [] : (set ?? base)
        if let at = remove { stops.removeAll { near($0.pos, at) } }
        if let (from, to) = mv, let k = stops.firstIndex(where: { near($0.pos, from) }) { stops[k].pos = to }
        if let (pos, align) = add {
            stops.removeAll { near($0.pos, pos) }
            stops.append(TabStop(pos: pos, align: align))
        }
        // A stable sort, as Rust's `sort_by`.
        stops = stops.enumerated().sorted { x, y in
            if totalLess(x.element.pos, y.element.pos) { return true }
            if totalLess(y.element.pos, x.element.pos) { return false }
            return x.offset < y.offset
        }.map(\.element)
        var deduped: [TabStop] = []
        for t in stops where !(deduped.last.map { near(t.pos, $0.pos) } ?? false) { deduped.append(t) }
        let final = Array(deduped.prefix(maxTabs))
        return try TextCommands.formatPara(s) { para in
            if editsStops { para.props.tabs = final }
            if let d = defaultTab { para.props.defaultTab = d }
        }
    }
}
