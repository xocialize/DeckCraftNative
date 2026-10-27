// DCEngine — the `text` command module: in-place text editing (entering and leaving text, typing,
// deleting, caret movement and selection), AutoCorrect, the input method's composition, and Replace
// Fonts. Also the helpers the formatting commands share (`formatRun`, `formatPara`, `formatBody`).
// Port of deckcraft crates/engine/src/cmd/text.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender
import DCText

public enum TextCommands {
    public static func specs() -> [CommandSpec] {
        [
            .query("font.used", "Fonts in Presentation", [], nil, "{} → [family] (theme fonts resolved)", Cmd.hasDoc, fontsUsed),
            .cmd(
                "font.replace",
                "Replace Fonts",
                ["Home", "Editing", "Replace"],
                nil,
                "{from, to} — every explicit use of family `from`, theme fonts included → {replaced}",
                Cmd.hasDoc,
                replaceFont
            ),
            .noundo("text.edit", "Edit Text", [], "Enter", "{id?, at?: [paragraph, char], end?: bool, cell?: [row, col], notes?: bool}", Cmd.hasSlide, edit),
            .noundo("text.exit", "Stop Editing Text", [], nil, "{}", Cmd.hasDoc, exit),
            .noundo(
                "text.autocorrect",
                "AutoCorrect Options",
                ["Tools"],
                nil,
                "{on?, twoInitials?, sentenceCaps?, days?, capsLock?, fractions?, ordinals?, lists?: bool, add?: [from, to], remove?: from} → the options and the replacement list",
                Cmd.always,
                autocorrectOptions
            ),
            .cmd("text.insert", "Type Text", [], nil, #"{text} (\n = new paragraph, \u000b = line break)"#, Cmd.hasText, insert),
            // The input method's composition: shown in place, an undo step only once committed.
            CommandSpec(
                id: "text.compose",
                label: "Compose Text",
                menu: [],
                shortcut: nil,
                params: "{text, active?: [start, end]} — an input method's composition (preedit) at the insertion point; empty text cancels it",
                enabled: Cmd.hasText,
                run: compose,
                journal: false,
                undoable: false
            ),
            .noundo(
                "text.commit",
                "Commit Composition",
                [],
                nil,
                "{text} — the input method's result replaces its composition, as one undo step",
                Cmd.hasText,
                commit
            ),
            .cmd(
                "text.delete",
                "Delete Text",
                [],
                "Backspace",
                "{dir?: backward|forward|wordBackward|wordForward} — the word directions are Ctrl+Backspace/Delete: they work from the start of a selection without deleting it",
                Cmd.hasText,
                delete
            ),
            // An input method asks for text around the caret to be removed. `undoable: false` is deliberate:
            // the handler pushes its own history entry from a snapshot taken before the composition is
            // replaced, so the generic post-run undo hook must not add a duplicate.
            CommandSpec(
                id: "text.deleteSurrounding",
                label: "Delete Surrounding Text",
                menu: [],
                shortcut: nil,
                params: "{before, after, bytes?: bool}",
                enabled: Cmd.hasText,
                run: deleteSurroundingCmd,
                journal: false,
                undoable: false
            ),
            .noundo(
                "text.move",
                "Move Insertion Point",
                [],
                nil,
                "{to: left|right|up|down|wordLeft|wordRight|lineStart|lineEnd|paraStart|paraEnd|paraUp|paraDown|start|end, extend?: bool} — left/right are on screen: in a right-to-left paragraph left goes forward",
                Cmd.hasText,
                moveCaret
            ),
            .noundo("text.select", "Select Text", [], nil, "{anchor: [p, c], caret: [p, c]}", Cmd.hasText, select),
            .noundo("text.selectAll", "Select All Text", [], nil, "{}", Cmd.hasText, selectAll),
            .noundo("text.selectWord", "Select Word", [], nil, "{at?: [p, c]}", Cmd.hasText, selectWord),
            .noundo("text.selectParagraph", "Select Paragraph", [], nil, "{at?: [p, c]}", Cmd.hasText, selectPara),
            .cmd(
                "text.set",
                "Set Text",
                [],
                nil,
                "{id?, text, cell?: [r, c]} — replaces the whole text, keeping the first run's formatting",
                Cmd.hasSlide,
                set
            ),
            .query("text.get", "Get Text", [], nil, "{id?} → {text, paragraphs}", Cmd.hasSlide, get),
        ]
    }
}

// MARK: - Called by the core (cmd/edit.rs, cmd/slide.rs, cmd/mod.rs). Keep these signatures.

extension TextCommands {
    /// The text body a text selection edits (`body_of`). Ported by the core.
    public static func bodyOf(_ st: DocState, _ t: TextSel) -> TextBody? {
        if t.notes { return st.currentSlide?.notes }
        guard let sh = st.shape(t.shape) else { return nil }
        if let cell = t.cell, case .table(let tb) = sh.kind { return tb.cell(cell.para, cell.char)?.text }
        return sh.text
    }

    /// The resolution context of the edited tree (`ctx_for`). Ported by the core.
    static func ctxFor(_ doc: Presentation, _ sel: Selection) -> Resolve.Ctx? {
        switch sel.target {
        case .slides: doc.slides.at(sel.slide).flatMap { Resolve.Ctx.forSlide(doc, $0) }
        case .master(let m): doc.masters.at(m).map { Resolve.Ctx.forMaster(doc, $0) }
        case .handout, .notesMaster: pageMaster(doc, sel.target).map { Resolve.Ctx.forMaster(doc, $0) }
        case .layout(let m, let l): doc.masters.at(m).flatMap { ma in ma.layouts.at(l).map { Resolve.Ctx.forLayout(doc, ma, $0) } }
        }
    }

    /// Turn leading tabs of a paragraph into its outline level (capped at 8) and strip them. Returns
    /// whether any tab was found (`apply_leading_tabs`). Ported by the core.
    @discardableResult
    static func applyLeadingTabs(_ para: inout Paragraph) -> Bool {
        let tabs = para.runs.first.map { $0.text.unicodeScalars.prefix { $0 == "\t" }.count } ?? 0
        if tabs == 0 { return false }
        para.runs[0].text = String(String.UnicodeScalarView(para.runs[0].text.unicodeScalars.drop { $0 == "\t" }))
        para.level = UInt8(min(tabs, 8))
        return true
    }

    /// Paste a formatted body at the text selection (`paste_body`).
    static func pasteBody(_ s: Session, _ src: TextBody) throws -> JSON {
        let inherited = inheritedAlignsForEdit(s)
        let pos = try editText(s) { body, t -> TextPos in
            let (a, b) = t.ordered
            let at = TextEdit.delete(&body, a.tuple, b.tuple)
            let c = TextEdit.insertBody(&body, at, src)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
            promoteRange(&body, at.0, c.0, inherited)
            return c
        }
        return ["caret": [.integer(pos.0), .integer(pos.1)]]
    }

    /// Type `text` at the text selection (`insert_text`).
    static func insertText(_ s: Session, _ text: String, _ props: RunProps?) throws -> JSON {
        let inherited = inheritedAlignsForEdit(s)
        let text: String = try {
            let st = try s.doc()
            guard let t = st.selection.text else { return text }
            let body = bodyOf(st, t) ?? TextBody()
            return typed(s, body, t.ordered.0.tuple, text)
        }()
        _ = try editText(s) { body, t -> TextPos in
            let (a, b) = t.ordered
            let at = TextEdit.delete(&body, a.tuple, b.tuple)
            let props = props ?? (a != b ? TextEdit.propsAt(body, at) : unlinkedAtLinkEnd(body, at))
            let c = TextEdit.insert(&body, at, text, props)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
            promoteRange(&body, at.0, c.0, inherited)
            return c
        }
        try autocorrect(s, text.charCount == 1)
        // AutoCorrect can move the caret: a replaced word, or a list lead it removed.
        let pos = try s.doc().selection.text?.caret ?? TextPoint(0, 0)
        return ["caret": [.integer(pos.para), .integer(pos.char)]]
    }

    /// Delete in direction `dir` (`forward`, `backward`, `wordForward`, `wordBackward`) at the text
    /// selection (`delete_dir`).
    static func deleteDir(_ s: Session, _ dir: String) throws -> JSON {
        if dir == "backward", try undoAutoList(s) { return Cmd.ok() }
        try editText(s) { body, t in
            let (a, b) = t.ordered
            let at: TextPos
            if dir == "wordBackward" || dir == "wordForward" {
                // Ctrl+Backspace/Delete work from the start of a selection and leave the rest of it.
                at = TextEdit.deleteWord(&body, a.tuple, dir == "wordForward")
            } else if a != b {
                at = TextEdit.delete(&body, a.tuple, b.tuple)
            } else {
                let other: TextPos
                if dir == "forward" {
                    other = TextEdit.charMove(body, a.tuple, true)
                } else {
                    // Backspace at the start of an indented/bulleted paragraph outdents first.
                    if a.char == 0, body.paragraphs.indices.contains(a.para), body.paragraphs[a.para].level > 0 {
                        body.paragraphs[a.para].level -= 1
                        t.anchor = a
                        t.caret = a
                        return
                    }
                    other = TextEdit.charMove(body, a.tuple, false)
                }
                at = TextEdit.delete(&body, a.tuple, other)
            }
            t.anchor = TextPoint(at.0, at.1)
            t.caret = TextPoint(at.0, at.1)
        }
        return Cmd.ok()
    }
}

// MARK: - Cross-module helpers (format, insert)

extension TextCommands {
    /// Run `f` on the text body a text selection edits (`body_mut`): the slide's notes, a table cell, or a
    /// shape's text (created when the shape has none). nil when that body doesn't exist.
    static func withBody<R>(_ doc: inout Presentation, _ sel: Selection, _ t: TextSel, _ f: (inout TextBody) throws -> R) rethrows -> R? {
        if t.notes {
            guard doc.slides.indices.contains(sel.slide) else { return nil }
            return try f(&doc.slides[sel.slide].notes)
        }
        let r: R?? = try mutateShapes(&doc, sel) { shapes -> R? in
            let found: R?? = try withShape(&shapes, t.shape) { sh -> R? in
                if let cell = t.cell {
                    guard case .table(var tb) = sh.kind else { return nil }
                    let out = try tb.mutateCell(cell.para, cell.char) { try f(&$0.text) }
                    sh.kind = .table(tb)
                    return out
                }
                var body = sh.text ?? TextBody()
                let out = try f(&body)
                sh.text = body
                return out
            }
            return found ?? nil
        }
        return r ?? nil
    }

    /// Edit the active text body and selection; refits auto-sizing text boxes afterwards (`edit_text`).
    @discardableResult
    static func editText<T>(_ s: Session, _ f: (inout TextBody, inout TextSel) throws -> T) throws -> T {
        guard let t0 = try s.doc().selection.text else { throw Cmd.bad("text", Cmd.noTextPoint) }
        let r = try s.edit { doc, sel -> T in
            var t = t0
            let out: T?
            do {
                out = try withBody(&doc, sel, t) { body -> T in
                    let r = try f(&body, &t)
                    // The saved shrink-on-overflow scale was for the old text: fit the new text afresh. A
                    // body whose file carried no `fontScale` keeps none (100 %) here; `fitShrinkScale`
                    // fills in the computed scale when the new text overflows (#724).
                    if case .shrink(let fontScale, _)? = body.body.autofit {
                        body.body.autofit = .shrink(fontScale: fontScale == nil ? nil : 1.0, lineReduction: 0)
                    }
                    return r
                }
            }
            guard let out else { throw Cmd.bad("text", "the text being edited is gone") }
            sel.text = t
            return out
        }
        if !t0.notes && t0.cell == nil {
            try fitTextBox(s, t0.shape)
        }
        return r
    }

    /// Refit a shape after its text changed: remember the shrink-on-overflow scale the layout computes
    /// (#724), then grow or shrink an auto-sizing text box (Resize shape to fit text) to its text
    /// (`fit_text_box`).
    public static func fitTextBox(_ s: Session, _ id: ShapeId) throws {
        try fitShrinkScale(s, id)
        let st = try s.doc()
        guard let sh = st.shape(id), let body = sh.text else { return }
        let doc = st.doc
        let sel = st.selection
        guard let ctx = ctxFor(doc, sel) else { return }
        let bp = Resolve.body(ctx, sh)
        if bp.autofit != .shape { return }
        let x = Cmd.xfrmOf(doc, sel, sh)
        var geo = shapeGeometry(sh, x.w, x.h)
        var nx = x
        if bp.wrap == false {
            nx.w = TextLayoutEngine.fitWidth(ctx, sh, body, geo.textRect, NoFields()).rustMax(20.0)
        }
        geo = shapeGeometry(sh, nx.w, nx.h)
        let need = TextLayoutEngine.fitHeight(ctx, sh, body, geo.textRect, NoFields())
        let extra = (nx.h - geo.textRect.height).rustMax(0.0)
        nx.h = (need + extra).rustMax(8.0)
        if abs(nx.h - x.h) < 0.01 && abs(nx.w - x.w) < 0.01 && sh.xfrm != nil { return }
        // Change the box in place without an extra undo step (it is part of the edit).
        var d = st.doc
        mutateShapes(&d, st.selection) { list in
            withShape(&list, id) { $0.xfrm = nx }
        }
        st.docRef = DocRef(d)
        st.revision += 1
    }

    /// Store the shrink-on-overflow scale the layout computes for `id`, so a save keeps `fontScale` and
    /// `lnSpcReduction` in step with what is drawn (#724). A body with no meaningful saved scale is fitted
    /// afresh; a scale the file saved is left as it is (`fit_shrink_scale`).
    private static func fitShrinkScale(_ s: Session, _ id: ShapeId) throws {
        let st = try s.doc()
        guard let sh = st.shape(id), let body = sh.text else { return }
        guard case .shrink(let fontScale, let lineReduction)? = body.body.autofit else { return }
        if !(fontScale == nil || (fontScale == 1.0 && lineReduction == 0.0)) { return }
        let doc = st.doc
        let sel = st.selection
        guard let ctx = ctxFor(doc, sel) else { return }
        let x = Cmd.xfrmOf(doc, sel, sh)
        let tr = shapeGeometry(sh, x.w, x.h).textRect
        // Lay out as if the scale had just been reset, so the fit is computed even for nil.
        var probe = body
        probe.body.autofit = .shrink(fontScale: 1.0, lineReduction: 0.0)
        let l = TextLayoutEngine.layout(ctx, sh, probe, TextOpts(rect: tr, fields: NoFields(), promptColor: nil, noShrink: false))
        if l.fontScale >= 1.0 && l.lineReduction <= 0.0 { return }
        var d = st.doc
        let stored: Bool = mutateShapes(&d, st.selection) { list -> Bool in
            withShape(&list, id) { target -> Bool in
                guard case .shrink? = target.text?.body.autofit else { return false }
                target.text?.body.autofit = .shrink(fontScale: l.fontScale, lineReduction: l.lineReduction)
                return true
            } ?? false
        } ?? false
        if stored {
            st.docRef = DocRef(d)
            st.revision += 1
        }
    }

    /// Insert a field (slide number, date…) at the text selection (`insert_field`).
    @discardableResult
    public static func insertField(_ s: Session, _ field: String, _ text: String) throws -> JSON {
        let text = text.isEmpty ? "#" : text
        try editText(s) { body, t in
            let (a, b) = t.ordered
            let at = TextEdit.delete(&body, a.tuple, b.tuple)
            let props = TextEdit.propsAt(body, at)
            let src = TextBody(paragraphs: [Paragraph(runs: [Run(text: text, props: props, kind: .field(field: field))])])
            let c = TextEdit.insertBody(&body, at, src)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
        }
        return Cmd.ok()
    }

    /// Apply run formatting to the text selection (or, when not editing, to all text of the selected
    /// shapes). A caret without a range formats the word it's in (PowerPoint behaviour) (`format_run`).
    @discardableResult
    public static func formatRun(_ s: Session, _ f: (inout RunProps) -> Void) throws -> JSON {
        let st = try s.doc()
        if let t = st.selection.text {
            let (a, b) = formatRange(st, t)
            try editText(s) { body, _ in TextEdit.format(&body, a, b, f) }
            return Cmd.ok()
        }
        let ids = st.selection.shapes
        if ids.isEmpty { throw Cmd.bad("format", Cmd.selectTextOrShape) }
        let cells = st.selection.cells
        _ = try Cmd.editShapes(s, ["ids": ids.toJSON()], "format") { sh in
            let id = sh.id
            if case .table(var t) = sh.kind {
                // Only the selected cells, when a range of them is selected.
                let range = TableCommands.selectedRange(cells, id, t)
                for r in t.rows.indices {
                    for c in t.rows[r].cells.indices where TableCommands.inRange(range, r, c) {
                        TextEdit.formatAll(&t.rows[r].cells[c].text, f)
                    }
                }
                sh.kind = .table(t)
            } else {
                var body = sh.text ?? TextBody()
                TextEdit.formatAll(&body, f)
                sh.text = body
            }
        }
        for id in ids { try fitTextBox(s, id) }
        return Cmd.ok()
    }

    /// What `formatRun` formats while editing: the selection, or for a bare caret the word it's in
    /// (without its trailing space). Empty when the caret is at a word boundary (`format_range`).
    public static func formatRange(_ st: DocState, _ t: TextSel) -> (TextPos, TextPos) {
        let body = bodyOf(st, t) ?? TextBody()
        var (a, b) = (t.ordered.0.tuple, t.ordered.1.tuple)
        if a == b {
            let (wa, wb) = TextEdit.wordAt(body, a)
            if wa.1 < a.1 && a.1 < wb.1 {
                a = wa
                b = wb
                // Don't include the trailing space.
                let line = Array((body.paragraphs.at(b.0)?.text ?? "").unicodeScalars)
                while b.1 > a.1, line.at(b.1 - 1) == " " { b.1 -= 1 }
            }
        }
        return (a, b)
    }

    /// Link the text being edited: the selection or the word at the caret, as `formatRun` would. With
    /// nothing to link, `display` is inserted at the caret as linked text (`link_text`).
    @discardableResult
    public static func linkText(_ s: Session, _ link: Hyperlink, _ display: String) throws -> JSON {
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("insert.hyperlink", "not editing text") }
        let (a, b) = formatRange(st, t)
        if a != b { return try formatRun(s) { $0.link = link } }
        if display.isEmpty { throw Cmd.bad("insert.hyperlink", "nothing to link: select text or give `text`") }
        let pos = try editText(s) { body, t -> TextPos in
            var props = TextEdit.propsAt(body, a)
            props.link = link
            let c = TextEdit.insert(&body, a, display, props)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
            return c
        }
        return ["caret": [.integer(pos.0), .integer(pos.1)]]
    }

    /// Apply paragraph changes to the paragraphs touched by the selection (or all paragraphs of the
    /// selected shapes) (`format_para`).
    @discardableResult
    public static func formatPara(_ s: Session, _ f: (inout Paragraph) -> Void) throws -> JSON {
        let st = try s.doc()
        if let t = st.selection.text {
            let (a, b) = t.ordered
            try editText(s) { body, _ in
                if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
                let last = max(body.paragraphs.count - 1, 0)
                if a.para <= min(b.para, last) {
                    for pi in a.para ... min(b.para, last) where body.paragraphs.indices.contains(pi) {
                        f(&body.paragraphs[pi])
                    }
                }
            }
            return Cmd.ok()
        }
        let ids = st.selection.shapes
        if ids.isEmpty { throw Cmd.bad("format", Cmd.selectTextOrShape) }
        let cells = st.selection.cells
        _ = try Cmd.editShapes(s, ["ids": ids.toJSON()], "format") { sh in
            let id = sh.id
            if case .table(var t) = sh.kind {
                let range = TableCommands.selectedRange(cells, id, t)
                for r in t.rows.indices {
                    for c in t.rows[r].cells.indices where TableCommands.inRange(range, r, c) {
                        for k in t.rows[r].cells[c].text.paragraphs.indices { f(&t.rows[r].cells[c].text.paragraphs[k]) }
                    }
                }
                sh.kind = .table(t)
            } else {
                var body = sh.text ?? TextBody()
                if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
                for k in body.paragraphs.indices { f(&body.paragraphs[k]) }
                sh.text = body
            }
        }
        for id in ids { try fitTextBox(s, id) }
        return Cmd.ok()
    }

    /// Apply body (text box) changes to the edited or selected shapes (`format_body`).
    @discardableResult
    public static func formatBody(_ s: Session, _ f: (inout BodyProps) -> Void) throws -> JSON {
        let st = try s.doc()
        let ids: [ShapeId]
        if let t = st.selection.text, !t.notes {
            ids = [t.shape]
        } else {
            ids = st.selection.shapes
        }
        if ids.isEmpty { throw Cmd.bad("format", "select a shape") }
        _ = try Cmd.editShapes(s, ["ids": ids.toJSON()], "format") { sh in
            var body = sh.text ?? TextBody()
            f(&body.body)
            sh.text = body
        }
        for id in ids { try fitTextBox(s, id) }
        return Cmd.ok()
    }
}

// MARK: - The input method's surrounding text

/// Bounded committed text around an IME selection, in logical (not visual) order and with UTF-8 byte
/// offsets. The current composition (pre-edit) is removed from both the text and the offsets.
public struct ImeSurrounding: Sendable, Equatable {
    public var text: String
    public var cursor: Int
    public var anchor: Int
}

extension TextCommands {
    /// Maximum number of UTF-8 bytes in an outgoing IME surrounding-text query.
    public static let imeSurroundingMaxBytes = 4000

    /// How a soft line break reads in the IME view: a newline, like a paragraph break.
    private static func imeChar(_ ch: Unicode.Scalar) -> Unicode.Scalar { ch == "\u{0B}" ? "\n" : ch }

    /// Committed characters of one paragraph (the pre-edit skipped), as `(char index, character)`.
    private static func committedChars(_ p: Paragraph, _ comp: (Int, Int)?) -> [(Int, Unicode.Scalar)] {
        var out: [(Int, Unicode.Scalar)] = []
        var i = 0
        for r in p.runs {
            for ch in r.content.unicodeScalars {
                if !(comp.map { i >= $0.0 && i < $0.1 } ?? false) { out.append((i, imeChar(ch))) }
                i += 1
            }
        }
        return out
    }

    /// The composition's `(paragraph, start, end)` character range, when it is inside the body.
    private static func compositionRange(_ body: TextBody, _ c: Composition?) -> (Int, Int, Int)? {
        guard let c, let para = body.paragraphs.at(c.start.para) else { return nil }
        let n = para.charLen
        let start = min(c.start.char, n)
        let (sum, o) = start.addingReportingOverflow(c.len)
        let end = min(o ? Int.max : sum, n)
        return start < end ? (c.start.para, start, end) : nil
    }

    private static func compIn(_ comp: (Int, Int, Int)?, _ pi: Int) -> (Int, Int)? {
        guard let comp, comp.0 == pi else { return nil }
        return (comp.1, comp.2)
    }

    /// Clip a model position to the body. An empty body only has position `(0, 0)`.
    private static func modelPos(_ body: TextBody, _ pos: TextPoint) -> TextPos? {
        if body.paragraphs.isEmpty { return pos == TextPoint(0, 0) ? (0, 0) : nil }
        return body.paragraphs.at(pos.para).map { (pos.para, min(pos.char, $0.charLen)) }
    }

    private static func fits(_ bytes: Bool, _ limit: Int, _ used: Int, _ chars: Int, _ n: Int) -> Bool {
        if bytes {
            let (v, o) = used.addingReportingOverflow(n)
            return !o && v <= limit
        }
        return chars < limit
    }

    /// Walk forward from `from` over at most `limit` committed characters (or UTF-8 bytes of whole
    /// characters), stopping at the end of the body: the position reached and the characters and bytes
    /// consumed.
    private static func walkForward(_ body: TextBody, _ comp: (Int, Int, Int)?, _ from: TextPos, _ limit: Int, _ bytes: Bool) -> (TextPos, Int, Int) {
        var (pi, at) = from
        var chars = 0
        var used = 0
        while let para = body.paragraphs.at(pi) {
            for (i, ch) in committedChars(para, compIn(comp, pi)) where i >= at {
                let n = UTF8.width(ch)
                if !fits(bytes, limit, used, chars, n) { return ((pi, i), chars, used) }
                used += n
                chars += 1
                at = i + 1
            }
            if pi + 1 >= body.paragraphs.count { break }
            // The paragraph separator between this paragraph and the next.
            if !fits(bytes, limit, used, chars, 1) { return ((pi, at), chars, used) }
            used += 1
            chars += 1
            pi += 1
            at = 0
        }
        return ((pi, at), chars, used)
    }

    /// Walk backward from `from` over at most `limit` committed characters (or UTF-8 bytes of whole
    /// characters).
    private static func walkBackward(_ body: TextBody, _ comp: (Int, Int, Int)?, _ from: TextPos, _ limit: Int, _ bytes: Bool) -> (TextPos, Int, Int) {
        var (pi, at) = from
        var chars = 0
        var used = 0
        while true {
            guard let para = body.paragraphs.at(pi) else { return ((pi, at), chars, used) }
            var boundary = min(at, para.charLen)
            for (i, ch) in committedChars(para, compIn(comp, pi)).reversed() where i < boundary {
                let n = UTF8.width(ch)
                if !fits(bytes, limit, used, chars, n) { return ((pi, boundary), chars, used) }
                used += n
                chars += 1
                boundary = i
            }
            if pi == 0 { return ((0, 0), chars, used) }
            if !fits(bytes, limit, used, chars, 1) { return ((pi, 0), chars, used) }
            used += 1
            chars += 1
            pi -= 1
            at = Int.max
        }
    }

    /// The committed logical text between two model positions (excluding `end`); nil when it is longer
    /// than `cap` bytes.
    private static func logicalBetween(_ body: TextBody, _ comp: (Int, Int, Int)?, _ start: TextPos, _ end: TextPos, _ cap: Int) -> String? {
        let (a, b) = start <= end ? (start, end) : (end, start)
        var out = String.UnicodeScalarView()
        var len = 0
        if a.0 > b.0 { return "" }
        for pi in a.0 ... b.0 {
            guard let para = body.paragraphs.at(pi) else { return String(out) }
            let from = pi == a.0 ? a.1 : 0
            let to = pi == b.0 ? b.1 : Int.max
            for (i, ch) in committedChars(para, compIn(comp, pi)) where i >= from && i < to {
                out.append(ch)
                len += UTF8.width(ch)
                if len > cap { return nil }
            }
            if pi < b.0 {
                out.append("\n")
                len += 1
                if len > cap { return nil }
            }
        }
        return String(out)
    }

    /// Committed surrounding text for the text being edited (`ime_surrounding`). nil when the body or
    /// selection is invalid, or when the selection alone is wider than `imeSurroundingMaxBytes`.
    public static func imeSurrounding(_ st: DocState, _ t: TextSel) -> ImeSurrounding? {
        guard let body = bodyOf(st, t) else { return nil }
        let comp = compositionRange(body, st.composition)
        guard let caret = modelPos(body, t.caret), let anchor = modelPos(body, t.anchor) else { return nil }
        let (start, end) = caret <= anchor ? (caret, anchor) : (anchor, caret)
        let maxBytes = imeSurroundingMaxBytes
        guard let selected = logicalBetween(body, comp, start, end, maxBytes) else { return nil }
        let selectionLen = selected.utf8.count
        let budget = max(maxBytes - selectionLen, 0)
        let (_, _, beforeAvailable) = walkBackward(body, comp, start, budget, true)
        let (_, _, afterAvailable) = walkForward(body, comp, end, budget, true)
        var before = min(budget / 2, beforeAvailable)
        var after = min(budget - before, afterAvailable)
        before = min(budget - after, beforeAvailable)
        after = min(budget - before, afterAvailable)
        let (windowStart, _, _) = walkBackward(body, comp, start, before, true)
        let (windowEnd, _, _) = walkForward(body, comp, end, after, true)
        guard let beforeText = logicalBetween(body, comp, windowStart, start, budget),
              let afterText = logicalBetween(body, comp, end, windowEnd, budget) else { return nil }
        let beforeLen = beforeText.utf8.count
        let text = beforeText + selected + afterText
        if text.utf8.count > maxBytes { return nil }
        let (cursor, anch) = caret >= anchor ? (beforeLen + selectionLen, beforeLen) : (beforeLen, beforeLen + selectionLen)
        return ImeSurrounding(text: text, cursor: cursor, anchor: anch)
    }
}

// MARK: - Layout of the edited text (caret, hit testing, underlines)

extension TextCommands {
    /// Lay out the text being edited (for vertical caret movement and hit testing) (`layout_for`).
    public static func layoutFor(_ st: DocState, _ t: TextSel) -> TextLayout? { textFrame(st, t)?.0 }

    /// The text being edited as it is drawn: its layout, and the transform from layout space to the
    /// slide. nil for notes (`text_frame`).
    public static func textFrame(_ st: DocState, _ t: TextSel) -> (TextLayout, Affine)? {
        if t.notes { return nil }
        guard let sh = st.shape(t.shape), let ctx = ctxFor(st.doc, st.selection) else { return nil }
        if let cell = t.cell {
            guard let placed = cellOnSlide(st, t.shape, cell.para, cell.char) else { return nil }
            return (placed.layout, placed.toSlide)
        }
        guard let body = sh.text else { return nil }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let tr = shapeGeometry(sh, x.w, x.h).textRect
        let l = TextLayoutEngine.layout(ctx, sh, body, TextOpts(rect: tr, fields: NoFields(), promptColor: nil, noShrink: false))
        return (l, textTransform(x.affine, tr, l.rotation))
    }

    /// The text position under slide point `p` in the text being edited (`text_pos_at`).
    public static func textPosAt(_ st: DocState, _ t: TextSel, _ p: Point) -> TextPos {
        guard let (l, m) = textFrame(st, t) else { return (0, 0) }
        let h = l.hit(m.inverse * p)
        return (h.para, h.ch)
    }

    /// The insertion point on the slide: its line from top to bottom, in slide coordinates. nil for notes
    /// (`caret_line`).
    public static func caretLine(_ st: DocState, _ t: TextSel) -> (Point, Point)? {
        if t.notes { return nil }
        let aff: Affinity = t.atLineEnd ? .upstream : .downstream
        let pos = CaretPos(para: t.caret.para, ch: t.caret.char)
        if let cell = t.cell {
            guard let placed = cellOnSlide(st, t.shape, cell.para, cell.char), let c = placed.layout.caretDrawn(pos, aff) else { return nil }
            return (placed.toSlide * Point(c.x, c.top), placed.toSlide * Point(c.x, c.bottom))
        }
        guard let sh = st.shape(t.shape), let ctx = ctxFor(st.doc, st.selection) else { return nil }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let geo = shapeGeometry(sh, x.w, x.h)
        var body = sh.text ?? TextBody()
        if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
        let l = TextLayoutEngine.layout(ctx, sh, body, TextOpts(rect: geo.textRect, fields: NoFields(), promptColor: nil, noShrink: false))
        guard let c = l.caretDrawn(pos, aff) else { return nil }
        let m = textTransform(x.affine, geo.textRect, l.rotation)
        return (m * Point(c.x, c.top), m * Point(c.x, c.bottom))
    }

    /// The colour of text typed at the caret; nil when that text has no fill to take a colour from
    /// (`caret_color`).
    public static func caretColor(_ st: DocState, _ t: TextSel) -> Rgba? {
        if t.notes || t.cell != nil { return nil }
        guard let sh = st.shape(t.shape), let body = sh.text, let ctx = ctxFor(st.doc, st.selection) else { return nil }
        let para = body.paragraphs.at(t.caret.para) ?? Paragraph()
        let props = Resolve.run(ctx, sh, para, TextEdit.propsAt(body, t.caret.tuple))
        let c = Resolve.textColor(ctx, props)
        return c.a > 0 ? c : nil
    }

    /// Underlines (slide coordinates) under character ranges `(para, start, end)` of shape `id`'s text:
    /// where spelling squiggles go (`range_underlines`).
    public static func rangeUnderlines(_ st: DocState, _ id: ShapeId, _ ranges: [(Int, Int, Int)]) -> [(Point, Point)] {
        guard let sh = st.shape(id), let l = layoutFor(st, TextSel(shape: id)) else { return [] }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let tr = shapeGeometry(sh, x.w, x.h).textRect
        let m = textTransform(x.affine, tr, l.rotation)
        var out: [(Point, Point)] = []
        for (para, a, b) in ranges {
            for (x0, x1, y) in l.compositionUnderlines(CaretPos(para: para, ch: a), CaretPos(para: para, ch: b)) {
                out.append((m * Point(x0, y), m * Point(x1, y)))
            }
        }
        return out
    }

    /// Like `rangeUnderlines`, for the text of table `id`'s cell at `row`, `col` (`cell_range_underlines`).
    public static func cellRangeUnderlines(_ st: DocState, _ id: ShapeId, _ row: Int, _ col: Int, _ ranges: [(Int, Int, Int)]) -> [(Point, Point)] {
        guard let placed = cellOnSlide(st, id, row, col, padEmpty: false) else { return [] }
        var out: [(Point, Point)] = []
        for (para, a, b) in ranges {
            for (x0, x1, y) in placed.layout.compositionUnderlines(CaretPos(para: para, ch: a), CaretPos(para: para, ch: b)) {
                out.append((placed.toSlide * Point(x0, y), placed.toSlide * Point(x1, y)))
            }
        }
        return out
    }

    /// Underlines under an input method's composition, in slide coordinates: `(from, to, thick)` per line
    /// (`composition_underlines`).
    public static func compositionUnderlines(_ st: DocState) -> [(Point, Point, Bool)] {
        guard let c = st.composition, let t = st.selection.text, !t.notes else { return [] }
        if let cell = t.cell {
            guard let placed = cellOnSlide(st, t.shape, cell.para, cell.char) else { return [] }
            return underlineSegments(placed.layout, placed.toSlide, c)
        }
        guard let sh = st.shape(t.shape), let l = layoutFor(st, t) else { return [] }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let tr = shapeGeometry(sh, x.w, x.h).textRect
        return underlineSegments(l, textTransform(x.affine, tr, l.rotation), c)
    }

    private static func underlineSegments(_ layout: TextLayout, _ toSlide: Affine, _ c: Composition) -> [(Point, Point, Bool)] {
        func pos(_ ch: Int) -> CaretPos { CaretPos(para: c.start.para, ch: c.start.char &+ ch) }
        var out: [(Point, Point, Bool)] = []
        func add(_ a: Int, _ b: Int, _ thick: Bool) {
            for (x0, x1, y) in layout.compositionUnderlines(pos(a), pos(b)) {
                out.append((toSlide * Point(x0, y), toSlide * Point(x1, y), thick))
            }
        }
        add(0, c.len, false)
        if let (a, b) = c.active { add(a, min(b, c.len), true) }
        return out
    }

    /// A table cell's text laid out the way it is drawn, mapped into slide coordinates.
    private static func cellOnSlide(_ st: DocState, _ id: ShapeId, _ row: Int, _ col: Int, padEmpty: Bool = true) -> (layout: TextLayout, toSlide: Affine)? {
        guard let sh = st.shape(id), case .table(let tb) = sh.kind, let cell = tb.cell(row, col), let ctx = ctxFor(st.doc, st.selection) else { return nil }
        let heights = Cmd.tableDrawnHeights(st.doc, st.selection, tb)
        guard let rect = TableRender.cellRects(tb, heights).first(where: { $0.0 == row && $0.1 == col })?.2 else { return nil }
        var body = TableRender.cellBody(ctx, tb, row, col, cell)
        if padEmpty && body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
        let tmp = Shape.tableCell(body)
        let layout = TextLayoutEngine.layout(ctx, tmp, body, TextOpts(rect: rect, fields: NoFields(), promptColor: nil, noShrink: false))
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        return (layout, textTransform(x.affine, rect, layout.rotation))
    }
}

// MARK: - Commands

extension TextCommands {
    static func posParam(_ p: JSON, _ key: String) -> TextPoint? {
        guard let a = p.get(key)?.asArray, let x = a.at(0)?.asUsize, let y = a.at(1)?.asUsize else { return nil }
        return TextPoint(x, y)
    }

    @Sendable static func edit(_ s: Session, _ p: JSON) throws -> JSON {
        if Cmd.boolOr(p, "notes", false) {
            let end = try s.doc().currentSlide.map { TextEdit.end($0.notes) } ?? (0, 0)
            try s.select { _, sel in
                sel.text = TextSel(anchor: TextPoint(end.0, end.1), caret: TextPoint(end.0, end.1), notes: true)
                sel.shapes.removeAll()
                sel.cells = nil
            }
            return Cmd.ok()
        }
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", "text.edit") {
            id = i
        } else {
            guard let first = try s.doc().selection.shapes.first else { throw Cmd.bad("text.edit", "select a shape with text") }
            id = first
        }
        let sh = try Cmd.shapeOf(s, id)
        let cell = posParam(p, "cell")
        let body: TextBody
        switch (sh.kind, cell) {
        case (.table(let t), .some(let c)):
            guard let x = t.cell(c.para, c.char) else { throw Cmd.bad("text.edit", "no such cell") }
            body = x.text
        case (.table, nil):
            throw Cmd.bad("text.edit", "say which `cell` of the table")
        case (.shape, _), (.connector, _):
            body = sh.text ?? TextBody()
        default:
            throw Cmd.bad("text.edit", "this object doesn't hold text")
        }
        let at = posParam(p, "at") ?? {
            let e = TextEdit.end(body)
            return TextPoint(e.0, e.1)
        }()
        // A shape without a text body gets one on first edit.
        if sh.text == nil && cell == nil {
            try s.edit { doc, sel in
                mutateShapes(&doc, sel) { list in
                    withShape(&list, id) { $0.text = TextBody() }
                }
            }
        }
        try s.select { _, sel in
            sel.shapes = [id]
            sel.text = TextSel(shape: id, anchor: at, caret: at, cell: cell, notes: false, lineEnd: nil)
            sel.cells = nil
        }
        return ["id": id.toJSON(), "at": at.toJSON()]
    }

    @Sendable static func exit(_ s: Session, _ p: JSON) throws -> JSON {
        try s.select { _, sel in
            if let t = sel.text {
                sel.text = nil
                if !t.notes { sel.shapes = [t.shape] }
            }
        }
        return Cmd.ok()
    }

    /// Smart quotes applied to typed text.
    private static func typed(_ s: Session, _ body: TextBody, _ at: TextPos, _ text: String) -> String {
        if !s.prefs.smartQuotes || text.charCount != 1 { return text }
        let prev: Unicode.Scalar? = at.1 > 0 ? body.paragraphs.at(at.0).flatMap { Array($0.text.unicodeScalars).at(at.1 - 1) } : nil
        let opening = prev.map { $0.properties.isWhitespace || "([{".unicodeScalars.contains($0) } ?? true
        switch text {
        case "\"": return opening ? "“" : "”"
        case "'": return opening ? "‘" : "’"
        default: return text
        }
    }

    /// Per outline level (0...8), whether shape `id` on the current slide already resolves an alignment
    /// for its paragraphs (`inherited_aligns`).
    private static func inheritedAligns(_ s: Session, _ id: ShapeId) -> [Bool] {
        var out = Array(repeating: false, count: 9)
        guard let st = s.activeDoc, let sh = st.shape(id), let ctx = ctxFor(st.doc, st.selection) else { return out }
        for lvl in 0 ..< 9 {
            out[lvl] = Resolve.para(ctx, sh, Paragraph(level: UInt8(lvl))).align != nil
        }
        return out
    }

    private static func inheritedAlignsForEdit(_ s: Session) -> [Bool] {
        if let t = s.activeDoc?.selection.text, !t.notes { return inheritedAligns(s, t.shape) }
        return Array(repeating: false, count: 9)
    }

    /// A paragraph with no direction of its own whose first strong character is right-to-left becomes
    /// right-to-left, and right-aligned when nothing sets its alignment (`promote_rtl_if_needed`).
    static func promoteRTLIfNeeded(_ para: inout Paragraph, _ inherited: [Bool]) {
        if para.props.rtl == nil && firstStrongIsRTL(para.text) {
            para.props.rtl = true
            let inheritsAlign = inherited.at(Int(para.level)) ?? false
            if para.props.align == nil && !inheritsAlign { para.props.align = .right }
        }
    }

    private static func promoteRange(_ body: inout TextBody, _ from: Int, _ to: Int, _ inherited: [Bool]) {
        let last = max(body.paragraphs.count - 1, 0)
        let hi = min(to, last)
        if from > hi { return }
        for pi in from ... hi where body.paragraphs.indices.contains(pi) {
            promoteRTLIfNeeded(&body.paragraphs[pi], inherited)
        }
    }

    /// Typing right after a hyperlink doesn't extend it: at the end of a linked run, the props to type
    /// with are the run's without the link. nil elsewhere (`unlinked_at_link_end`).
    private static func unlinkedAtLinkEnd(_ body: TextBody, _ at: TextPos) -> RunProps? {
        var props = TextEdit.propsAt(body, at)
        guard props.link != nil else { return nil }
        let len = body.paragraphs.at(at.0)?.text.charCount ?? 0
        if at.1 < len && TextEdit.propsAt(body, (at.0, at.1 + 1)).link == props.link { return nil }
        props.link = nil
        return props
    }

    /// Built-in AutoCorrect replacements (common slips and symbols).
    public static let autocorrect: [(String, String)] = [
        ("teh", "the"), ("adn", "and"), ("recieve", "receive"), ("recieved", "received"), ("seperate", "separate"),
        ("occured", "occurred"), ("occurence", "occurrence"), ("thier", "their"), ("wich", "which"), ("acheive", "achieve"),
        ("accross", "across"), ("adress", "address"), ("alot", "a lot"), ("appearence", "appearance"), ("arguement", "argument"),
        ("basicly", "basically"), ("beggining", "beginning"), ("beleive", "believe"), ("calender", "calendar"),
        ("commitee", "committee"), ("definately", "definitely"), ("dont", "don't"), ("doesnt", "doesn't"), ("didnt", "didn't"),
        ("isnt", "isn't"), ("embarass", "embarrass"), ("enviroment", "environment"), ("existance", "existence"),
        ("foward", "forward"), ("freind", "friend"), ("goverment", "government"), ("happend", "happened"), ("i", "I"),
        ("ive", "I've"), ("immediatly", "immediately"), ("independant", "independent"), ("knowlege", "knowledge"),
        ("libary", "library"), ("neccessary", "necessary"), ("necesary", "necessary"), ("noticable", "noticeable"),
        ("occassion", "occasion"), ("posession", "possession"), ("prefered", "preferred"), ("publically", "publicly"),
        ("realy", "really"), ("recomend", "recommend"), ("refered", "referred"), ("relevent", "relevant"),
        ("succesful", "successful"), ("tommorow", "tomorrow"), ("tomorow", "tomorrow"), ("truely", "truly"), ("untill", "until"),
        ("wierd", "weird"), ("youre", "you're"), ("(c)", "©"), ("(r)", "®"), ("(tm)", "™"), ("(e)", "€"), ("...", "…"),
        ("->", "→"), ("<-", "←"), ("=>", "⇒"), ("--", "–"),
    ]

    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static func eqIgnoreASCIICase(_ a: String, _ b: String) -> Bool {
        rustEqual(rustASCIILowercase(a), rustASCIILowercase(b))
    }

    /// The replacement for `word` from your entries, then the built-in list.
    private static func replacement(_ prefs: Prefs, _ word: String) -> String? {
        if let e = prefs.acEntries.first(where: { rustEqual($0.a, word) }) { return e.b }
        if let e = prefs.acEntries.first(where: { eqIgnoreASCIICase($0.a, word) }) { return e.b }
        guard let (k, to) = autocorrect.first(where: { eqIgnoreASCIICase($0.0, word) }) else { return nil }
        if prefs.acRemoved.contains(where: { eqIgnoreASCIICase($0, k) }) { return nil }
        // "i" only on its own, lower case.
        if k == "i" && !rustEqual(word, "i") { return nil }
        return word.unicodeScalars.first?.properties.isUppercase == true ? TextEdit.changeCase(to, "sentence") : to
    }

    /// What a just-typed `word` becomes (nil: unchanged). `sentenceStart`: nothing but spaces or a
    /// sentence's end before it in the paragraph. `typing`: one character was typed (`correct_word`).
    public static func correctWord(_ prefs: Prefs, _ word: String, _ sentenceStart: Bool, _ typing: Bool) -> String? {
        var out = replacement(prefs, word)
        if typing && out == nil {
            let chars = Array(word.unicodeScalars)
            let letters = chars.allSatisfy(rustIsAlphabetic)
            if prefs.acFractions {
                switch word {
                case "1/2": out = "½"
                case "1/4": out = "¼"
                case "3/4": out = "¾"
                default: out = nil
                }
            }
            if out == nil && letters && chars.count >= 3 {
                func upper(_ c: Unicode.Scalar) -> Bool { c.properties.isUppercase }
                let restLower = chars.dropFirst(2).allSatisfy(\.properties.isLowercase)
                let restUpper = chars.dropFirst(1).allSatisfy(upper)
                if prefs.acTwoInitials && upper(chars[0]) && upper(chars[1]) && restLower {
                    out = chars.enumerated().map { i, c in i == 1 ? c.properties.lowercaseMapping : String(c) }.joined()
                } else if prefs.acCapsLock && chars[0].properties.isLowercase && restUpper {
                    out = chars.enumerated().map { i, c in i == 0 ? c.properties.uppercaseMapping : c.properties.lowercaseMapping }.joined()
                }
            }
            if out == nil && prefs.acDays && days.contains(where: { rustEqual($0, word) }) {
                out = TextEdit.changeCase(word, "sentence")
            }
        }
        if typing && prefs.acSentenceCaps && sentenceStart {
            let w = out ?? word
            var cs = w.unicodeScalars.makeIterator()
            if let f = cs.next(), f.properties.isLowercase, w.unicodeScalars.allSatisfy(rustIsAlphabetic) {
                out = f.properties.uppercaseMapping + String(String.UnicodeScalarView(w.unicodeScalars.dropFirst()))
            }
        }
        if let o = out, rustEqual(o, word) { return nil }
        return out
    }

    private static let sentencePunct = ".,;:!?".unicodeScalars

    /// After a space or punctuation, correct the word just typed.
    private static func autocorrect(_ s: Session, _ typing: Bool) throws {
        if !s.prefs.autocorrect { return }
        let st = try s.doc()
        guard let t = st.selection.text, let body = bodyOf(st, t) else { return }
        let line = Array((body.paragraphs.at(t.caret.para)?.text ?? "").unicodeScalars)
        let end = t.caret.char
        guard end > 0, let last = line.at(end - 1), last.properties.isWhitespace || sentencePunct.contains(last) else { return }
        func str(_ v: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(v)) }
        if typing && s.prefs.acLists {
            // A lead such as `i.` or `a.` is kept as typed, so the space after it starts its list.
            let lead = end <= line.count ? str(line[..<end]) : ""
            if autoListStyle(lead) != nil { return }
            if try startAutoList(s, t, line, end) { return }
        }
        var wordEnd = end - 1
        var start = wordEnd
        while start > 0, let c = line.at(start - 1), !c.properties.isWhitespace { start -= 1 }
        // "word," and "word." also count: the punctuation was typed before the space.
        var word = start <= wordEnd && wordEnd <= line.count ? str(line[start ..< wordEnd]) : ""
        if replacement(s.prefs, word) == nil {
            let ws = Array(word.unicodeScalars)
            var k = ws.count
            while k > 0, sentencePunct.contains(ws[k - 1]) { k -= 1 }
            if k > 0 && k < ws.count && !word.hasSuffix("...") {
                wordEnd -= ws.count - k
                word = str(ws[..<k])
            }
        }
        let before = start <= line.count ? line[..<start].reversed().first { !$0.properties.isWhitespace } : nil
        let sentenceStart = before.map { ".!?".unicodeScalars.contains($0) } ?? true
        // "word..." becomes "word…", the word corrected too.
        let ellipsis = word.charCount > 3 && word.hasSuffix("...") && replacement(s.prefs, "...") != nil
        let rep: String?
        if ellipsis {
            let stem = String(String.UnicodeScalarView(Array(word.unicodeScalars).reversed().drop { $0 == "." }.reversed()))
            rep = "\(correctWord(s.prefs, stem, sentenceStart, typing) ?? stem)…"
        } else {
            rep = correctWord(s.prefs, word, sentenceStart, typing)
        }
        guard let rep else {
            if typing && s.prefs.acOrdinals && isOrdinal(word) { try superscriptSuffix(s, t, wordEnd) }
            return
        }
        let delta = rep.charCount - word.charCount
        var d = st.doc
        let sel = st.selection
        withBody(&d, sel, t) { b in
            TextEdit.delete(&b, (t.caret.para, start), (t.caret.para, wordEnd))
            TextEdit.insert(&b, (t.caret.para, start), rep, nil)
        }
        st.docRef = DocRef(d)
        let c = TextPoint(t.caret.para, max(end + delta, 0))
        if st.selection.text != nil {
            st.selection.text?.caret = c
            st.selection.text?.anchor = c
        }
        st.revision += 1
    }

    /// The list a paragraph that starts with `lead` and a space or tab becomes, as the command and
    /// parameters that make it (`auto_list_style`).
    private static func autoListStyle(_ lead: String) -> (String, JSON)? {
        func bullet(_ c: String) -> (String, JSON) { ("format.bullets", ["on": true, "char": .string(c)]) }
        func number(_ scheme: String) -> (String, JSON) { ("format.numbering", ["on": true, "scheme": .string(scheme)]) }
        switch Array(lead.unicodeScalars).map(String.init).joined() {
        case "*": return bullet("•")
        case "-", "–": return bullet("–")
        case "--", "—": return bullet("■")
        case ">": return bullet("➢")
        case "<>": return bullet("◆")
        case "1.": return number("arabicPeriod")
        case "1)": return number("arabicParenR")
        case "I.": return number("romanUcPeriod")
        case "i.": return number("romanLcPeriod")
        case "A.": return number("alphaUcPeriod")
        case "a.": return number("alphaLcPeriod")
        case "a)": return number("alphaLcParenR")
        default: return nil
        }
    }

    /// AutoFormat's automatic bulleted and numbered lists: when the caret's paragraph holds only a list
    /// lead before the space or tab just typed, the lead and the space are removed and the paragraph
    /// becomes a list paragraph in that style. false when nothing changed (`start_auto_list`).
    private static func startAutoList(_ s: Session, _ t: TextSel, _ line: [Unicode.Scalar], _ end: Int) throws -> Bool {
        guard !t.isRange, let c = line.at(end - 1), c == " " || c == "\t", end - 1 <= line.count, end <= line.count else { return false }
        let lead = String(String.UnicodeScalarView(line[..<(end - 1)]))
        guard let (id, params) = autoListStyle(lead) else { return false }
        let typedText = String(String.UnicodeScalarView(line[..<end]))
        let para = t.caret.para
        let props = try bodyOf(s.doc(), t)?.paragraphs.at(para)?.props ?? ParaProps()
        try editText(s) { body, tt in
            TextEdit.delete(&body, (para, 0), (para, end))
            tt.anchor = TextPoint(para, 0)
            tt.caret = TextPoint(para, 0)
        }
        _ = try s.execute(id, params)
        let st = try s.doc()
        if let sel = st.selection.text {
            st.autoList = AutoList(sel: sel, typed: typedText, props: props, revision: st.revision)
        }
        return true
    }

    /// Backspace right after AutoFormat started a list: the paragraph gets back the typed lead and space
    /// and the formatting it had. false when the last change was anything else (`undo_auto_list`).
    private static func undoAutoList(_ s: Session) throws -> Bool {
        let st = try s.doc()
        guard let a = st.autoList else { return false }
        st.autoList = nil
        if a.revision != st.revision || st.selection.text != a.sel { return false }
        try editText(s) { body, t in
            if body.paragraphs.indices.contains(a.sel.caret.para) { body.paragraphs[a.sel.caret.para].props = a.props }
            let c = TextEdit.insert(&body, a.sel.caret.tuple, a.typed, nil)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
        }
        return true
    }

    /// `word` is a number with the ordinal suffix it takes (1st, 22nd, 103rd, 11th) (`is_ordinal`).
    static func isOrdinal(_ word: String) -> Bool {
        let b = Array(word.utf8)
        var n = b.count
        while n > 0, b[n - 1] >= UInt8(ascii: "a") && b[n - 1] <= UInt8(ascii: "z") { n -= 1 }
        let d = b[..<n]
        let suffix = b[n...]
        if d.isEmpty || !d.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) || suffix.count != 2 { return false }
        let teen = d.count >= 2 && d[d.startIndex + d.count - 2] == UInt8(ascii: "1")
        let want: String
        if teen {
            want = "th"
        } else {
            switch d.last {
            case UInt8(ascii: "1"): want = "st"
            case UInt8(ascii: "2"): want = "nd"
            case UInt8(ascii: "3"): want = "rd"
            default: want = "th"
            }
        }
        return Array(suffix) == Array(want.utf8)
    }

    /// Superscript the two letters before `end` in the caret's paragraph (an ordinal's suffix).
    private static func superscriptSuffix(_ s: Session, _ t: TextSel, _ end: Int) throws {
        let (a, b) = ((t.caret.para, max(end - 2, 0)), (t.caret.para, end))
        let st = try s.doc()
        guard let body = bodyOf(st, t), (TextEdit.propsAt(body, b).baseline ?? 0) <= 0 else { return }
        var d = st.doc
        withBody(&d, st.selection, t) { body in TextEdit.format(&body, a, b) { $0.baseline = 0.3 } }
        st.docRef = DocRef(d)
        st.revision += 1
    }

    @Sendable static func autocorrectOptions(_ s: Session, _ p: JSON) throws -> JSON {
        func flag(_ key: String, _ slot: inout Bool) { if let v = p.get(key)?.asBool { slot = v } }
        flag("on", &s.prefs.autocorrect)
        flag("twoInitials", &s.prefs.acTwoInitials)
        flag("sentenceCaps", &s.prefs.acSentenceCaps)
        flag("days", &s.prefs.acDays)
        flag("capsLock", &s.prefs.acCapsLock)
        flag("fractions", &s.prefs.acFractions)
        flag("ordinals", &s.prefs.acOrdinals)
        flag("lists", &s.prefs.acLists)
        if case .array(let a)? = p.get("add") {
            guard let fromRaw = a.at(0)?.asStr, let to = a.at(1)?.asStr else { throw Cmd.bad("text.autocorrect", "`add` is [from, to]") }
            let from = String(rustTrim(fromRaw))
            if from.isEmpty || from.unicodeScalars.contains(where: \.properties.isWhitespace) || from.charCount > 64 || to.charCount > 255 {
                throw Cmd.bad("text.autocorrect", "`from` is one word (up to 64 characters), `to` up to 255")
            }
            s.prefs.acEntries.removeAll { rustEqual($0.a, from) }
            s.prefs.acRemoved.removeAll { eqIgnoreASCIICase($0, from) }
            if s.prefs.acEntries.count >= 2000 { throw Cmd.bad("text.autocorrect", "the list is full") }
            s.prefs.acEntries.append(Pair(from, to))
        }
        if let from = Cmd.strParam(p, "remove") {
            let had = s.prefs.acEntries.count
            s.prefs.acEntries.removeAll { rustEqual($0.a, from) }
            if had == s.prefs.acEntries.count && autocorrect.contains(where: { eqIgnoreASCIICase($0.0, from) })
                && !s.prefs.acRemoved.contains(where: { eqIgnoreASCIICase($0, from) }) {
                s.prefs.acRemoved.append(from)
            }
        }
        let pr = s.prefs
        var list: [JSON] = pr.acEntries.map { [.string($0.a), .string($0.b)] }
        for (k, v) in autocorrect where !pr.acRemoved.contains(where: { eqIgnoreASCIICase($0, k) }) && !pr.acEntries.contains(where: { eqIgnoreASCIICase($0.a, k) }) {
            list.append([.string(k), .string(v)])
        }
        return [
            "on": .bool(pr.autocorrect), "twoInitials": .bool(pr.acTwoInitials), "sentenceCaps": .bool(pr.acSentenceCaps),
            "days": .bool(pr.acDays), "capsLock": .bool(pr.acCapsLock), "fractions": .bool(pr.acFractions),
            "ordinals": .bool(pr.acOrdinals), "lists": .bool(pr.acLists), "entries": .array(list),
        ]
    }

    /// Text an input method sends: no paragraph or line breaks (Enter is a key of its own).
    private static func imeText(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.generalCategory != .control }))
    }

    /// Is the composition still where it was put (the paragraph holds all of it)?
    private static func compositionFits(_ st: DocState, _ c: Composition) -> Bool {
        guard let t = st.selection.text, let body = bodyOf(st, t), let p = body.paragraphs.at(c.start.para) else { return false }
        let (v, o) = c.start.char.addingReportingOverflow(c.len)
        return !o && v <= p.charLen
    }

    /// `text.compose`: put an input method's preedit at the insertion point (replacing the selection) or
    /// replace the composition with the new preedit. An empty preedit cancels.
    @Sendable static func compose(_ s: Session, _ p: JSON) throws -> JSON {
        guard let raw = Cmd.strParam(p, "text") else { throw Cmd.bad("text.compose", "missing `text`") }
        let text = imeText(raw)
        let n = text.charCount
        var active: (Int, Int)?
        if let a = p.get("active")?.asArray, let x = a.at(0)?.asUsize, let y = a.at(1)?.asUsize, x < y {
            active = (min(x, n), min(y, n))
        }
        var current = try s.doc().composition
        // A composition whose text was changed under it is kept as it is; a new one starts.
        if let c = current, try !compositionFits(s.doc(), c) {
            s.settleComposition()
            current = nil
        }
        switch current {
        case nil where text.isEmpty:
            return ["composing": false]
        case nil:
            let st = try s.doc()
            let (before, beforeSelection) = (st.docRef, st.selection)
            let (start, props) = try editText(s) { body, t -> (TextPos, RunProps?) in
                let (a, b) = t.ordered
                let at = TextEdit.delete(&body, a.tuple, b.tuple)
                let props = a != b ? TextEdit.propsAt(body, at) : unlinkedAtLinkEnd(body, at)
                let c = TextEdit.insert(&body, at, text, props)
                t.anchor = TextPoint(c.0, c.1)
                t.caret = TextPoint(c.0, c.1)
                return (at, props)
            }
            try s.doc().composition = Composition(start: TextPoint(start.0, start.1), len: n, active: active, props: props, before: before, beforeSelection: beforeSelection)
            return ["composing": true, "start": [.integer(start.0), .integer(start.1)], "len": .integer(n)]
        case .some(let c) where text.isEmpty:
            let st = try s.doc()
            st.docRef = c.before
            st.selection = c.beforeSelection
            st.composition = nil
            st.revision += 1
            return ["composing": false]
        case .some(var c):
            let (start, len, props) = (c.start, c.len, c.props)
            try editText(s) { body, t in
                TextEdit.delete(&body, start.tuple, (start.para, start.char &+ len))
                let e = TextEdit.insert(&body, start.tuple, text, props)
                t.anchor = TextPoint(e.0, e.1)
                t.caret = TextPoint(e.0, e.1)
            }
            c.len = n
            c.active = active
            try s.doc().composition = c
            return ["composing": true, "start": start.toJSON(), "len": .integer(n)]
        }
    }

    /// `text.commit`: the input method's result replaces the composition (or is typed at the insertion
    /// point when there is none) and the whole composition becomes one undo step.
    @Sendable static func commit(_ s: Session, _ p: JSON) throws -> JSON {
        guard let raw = Cmd.strParam(p, "text") else { throw Cmd.bad("text.commit", "missing `text`") }
        let text = imeText(raw)
        if try s.doc().composition != nil || !text.isEmpty {
            _ = try compose(s, ["text": .string(text)])
        }
        s.endComposition()
        let caret = try s.doc().selection.text?.caret ?? TextPoint(0, 0)
        return ["caret": caret.toJSON()]
    }

    @Sendable static func insert(_ s: Session, _ p: JSON) throws -> JSON {
        guard let text = Cmd.strParam(p, "text") else { throw Cmd.bad("text.insert", "missing `text`") }
        return try insertText(s, text, nil)
    }

    /// A `before`/`after` count from a control or input-method request: a value that doesn't fit is
    /// clamped, never truncated (`count_param`).
    static func countParam(_ p: JSON, _ name: String) -> Int {
        p.get(name)?.asU64.map { Int(exactly: $0) ?? Int.max } ?? 0
    }

    /// Delete at most the requested character or byte counts around the selection or pre-edit, keeping
    /// the selection's direction and the composition, and recording one undo step outside a composition.
    @Sendable static func deleteSurroundingCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let before = countParam(p, "before")
        let after = countParam(p, "after")
        let bytes = Cmd.boolOr(p, "bytes", false)
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("text.deleteSurrounding", "not editing text") }
        guard let body = bodyOf(st, t) else { throw Cmd.bad("text.deleteSurrounding", "the text being edited is gone") }
        let comp = compositionRange(body, st.composition)
        guard let a = modelPos(body, t.anchor), let b = modelPos(body, t.caret) else {
            throw Cmd.bad("text.deleteSurrounding", "the selection is not in the text")
        }
        let ordered = a <= b ? (a, b) : (b, a)
        let (start, end): (TextPos, TextPos) = comp.map { (($0.0, $0.1), ($0.0, $0.2)) } ?? ordered
        let (from, beforeChars, _) = walkBackward(body, comp, start, before, bytes)
        let (to, afterChars, _) = walkForward(body, comp, end, after, bytes)
        let deleted = beforeChars + afterChars
        if deleted == 0 { return ["deleted": 0] }
        let beforeDoc = st.docRef
        let beforeSel = st.selection
        let composing = st.composition != nil
        let vertexKind = s.tool.vertexKind
        try editText(s) { body, t in
            // Delete the after-range first, so the positions of the earlier range stay valid.
            if afterChars > 0 { TextEdit.delete(&body, end, to) }
            if beforeChars > 0 { TextEdit.delete(&body, from, start) }
            t.anchor = remapAfterDelete(t.anchor, start, from, beforeChars)
            t.caret = remapAfterDelete(t.caret, start, from, beforeChars)
            t.lineEnd = nil
        }
        if composing {
            let st = try s.doc()
            if var c = st.composition {
                if beforeChars == 0 {
                    c.start = TextPoint(start.0, start.1)
                } else if from.0 == start.0 {
                    c.start = TextPoint(start.0, max(start.1 - beforeChars, 0))
                } else {
                    c.start = TextPoint(from.0, from.1)
                }
                st.composition = c
            }
        } else {
            pushUndo(try s.doc(), HistoryEntry(label: "Delete Text", doc: beforeDoc, selection: beforeSel, vertexKind: vertexKind))
        }
        return ["deleted": .integer(deleted)]
    }

    /// Map a text position across the deletion of `beforeChars` characters that begins at `start` and
    /// reaches back to `from` (`remap_after_delete`).
    private static func remapAfterDelete(_ pos: TextPoint, _ start: TextPos, _ from: TextPos, _ beforeChars: Int) -> TextPoint {
        if beforeChars == 0 || pos.tuple < start { return pos }
        if from.0 == start.0 {
            return pos.para == start.0 ? TextPoint(pos.para, max(pos.char - beforeChars, 0)) : pos
        }
        // A hostile selection can sit far past the text: the arithmetic wraps (as Rust's release build does)
        // instead of trapping.
        return TextPoint(from.0 &+ (pos.para &- start.0), pos.para == start.0 ? from.1 &+ (pos.char &- start.1) : pos.char)
    }

    @Sendable static func delete(_ s: Session, _ p: JSON) throws -> JSON {
        try deleteDir(s, Cmd.strParam(p, "dir") ?? "backward")
    }

    /// Is paragraph `para` right-to-left (its lines run from the right)?
    private static func paraRTL(_ layout: TextLayout?, _ body: TextBody, _ para: Int) -> Bool {
        if let line = layout?.lines.first(where: { $0.para == para }) { return line.rtl }
        return body.paragraphs.at(para)?.props.rtl ?? false
    }

    @Sendable static func moveCaret(_ s: Session, _ p: JSON) throws -> JSON {
        var to = Cmd.strParam(p, "to") ?? "right"
        let extend = Cmd.boolOr(p, "extend", false)
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("text.move", "not editing text") }
        let body = bodyOf(st, t) ?? TextBody()
        let layout = layoutFor(st, t)
        func lp(_ c: TextPos) -> CaretPos { CaretPos(para: c.0, ch: c.1) }
        let caret = t.caret.tuple
        let aff: Affinity = t.atLineEnd ? .upstream : .downstream
        // Left and right are on screen: in a right-to-left paragraph left goes forward in the text.
        if paraRTL(layout, body, caret.0) {
            switch to {
            case "left": to = "right"
            case "right": to = "left"
            case "wordLeft": to = "wordRight"
            case "wordRight": to = "wordLeft"
            default: break
            }
        }
        func collapseTo(_ left: Bool) -> TextPos { left ? t.ordered.0.tuple : t.ordered.1.tuple }
        var upstream = false
        let new: TextPos
        switch to {
        case "left" where t.isRange && !extend: new = collapseTo(true)
        case "right" where t.isRange && !extend: new = collapseTo(false)
        case "left": new = TextEdit.charMove(body, caret, false)
        case "right": new = TextEdit.charMove(body, caret, true)
        // Ctrl+arrows with a selection go on from its start (left) or end (right).
        case "wordLeft": new = TextEdit.wordMove(body, extend ? caret : collapseTo(true), false)
        case "wordRight": new = TextEdit.wordMove(body, extend ? caret : collapseTo(false), true)
        case "paraStart": new = (caret.0, 0)
        case "paraEnd": new = (caret.0, body.paragraphs.at(caret.0)?.charLen ?? 0)
        case "paraUp": new = TextEdit.paraUp(body, caret)
        case "paraDown": new = TextEdit.paraDown(body, caret)
        case "start": new = (0, 0)
        case "end": new = TextEdit.end(body)
        case "up", "down", "lineStart", "lineEnd":
            if let l = layout {
                let x = l.caretDrawn(lp(caret), aff)?.x ?? 0.0
                let (r, a): (CaretPos, Affinity) = switch to {
                case "up": l.verticalAffine(lp(caret), aff, down: false, x)
                case "down": l.verticalAffine(lp(caret), aff, down: true, x)
                case "lineStart": (l.lineBounds(lp(caret), aff).0, .downstream)
                // End stays on its line: after a soft wrap the caret sits at the line's end.
                default: l.lineEndCaret(lp(caret), aff)
                }
                upstream = a == .upstream
                new = (r.para, r.ch)
            } else {
                switch to {
                case "up": new = (max(caret.0 - 1, 0), caret.1)
                case "down": new = (min(caret.0 == Int.max ? Int.max : caret.0 + 1, max(body.paragraphs.count - 1, 0)), caret.1)
                case "lineStart": new = (caret.0, 0)
                default: new = (caret.0, body.paragraphs.at(caret.0)?.charLen ?? 0)
                }
            }
        default:
            throw Cmd.bad("text.move", "unknown direction `\(to)`")
        }
        let clamped = TextPoint(min(new.0, max(body.paragraphs.count - 1, 0)), min(new.1, body.paragraphs.at(new.0)?.charLen ?? 0))
        let up = upstream
        try s.select { _, sel in
            if sel.text != nil {
                sel.text?.caret = clamped
                sel.text?.lineEnd = up ? clamped : nil
                if !extend { sel.text?.anchor = clamped }
            }
        }
        return ["caret": clamped.toJSON(), "lineEnd": .bool(upstream)]
    }

    @Sendable static func select(_ s: Session, _ p: JSON) throws -> JSON {
        guard let a = posParam(p, "anchor") else { throw Cmd.bad("text.select", "missing `anchor`") }
        let c = posParam(p, "caret") ?? a
        try s.select { _, sel in
            if sel.text != nil {
                sel.text?.anchor = a
                sel.text?.caret = c
            }
        }
        return Cmd.ok()
    }

    @Sendable static func selectAll(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("text.selectAll", "not editing text") }
        let end = bodyOf(st, t).map(TextEdit.end) ?? (0, 0)
        try s.select { _, sel in
            if sel.text != nil {
                sel.text?.anchor = TextPoint(0, 0)
                sel.text?.caret = TextPoint(end.0, end.1)
            }
        }
        return Cmd.ok()
    }

    @Sendable static func selectWord(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("text.selectWord", "not editing text") }
        let at = posParam(p, "at") ?? t.caret
        let body = bodyOf(st, t) ?? TextBody()
        let (a, b) = TextEdit.wordAt(body, at.tuple)
        try s.select { _, sel in
            if sel.text != nil {
                sel.text?.anchor = TextPoint(a.0, a.1)
                sel.text?.caret = TextPoint(b.0, b.1)
            }
        }
        return Cmd.ok()
    }

    @Sendable static func selectPara(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let t = st.selection.text else { throw Cmd.bad("text.selectParagraph", "not editing text") }
        var at = posParam(p, "at") ?? t.caret
        let body = bodyOf(st, t)
        // Clamp to the last paragraph so a huge index can neither overflow nor select past the body.
        at.para = min(at.para, max((body?.paragraphs.count ?? 1) - 1, 0))
        let n = body?.paragraphs.at(at.para)?.charLen ?? 0
        // The paragraph mark is part of the paragraph (PowerPoint's triple-click selects it too).
        let next = at.para == Int.max ? Int.max : at.para + 1
        let end = body.map { next < $0.paragraphs.count } == true ? TextPoint(next, 0) : TextPoint(at.para, n)
        let start = TextPoint(at.para, 0)
        try s.select { _, sel in
            if sel.text != nil {
                sel.text?.anchor = start
                sel.text?.caret = end
            }
        }
        return Cmd.ok()
    }

    @Sendable static func set(_ s: Session, _ p: JSON) throws -> JSON {
        guard let text = Cmd.strParam(p, "text") else { throw Cmd.bad("text.set", "missing `text`") }
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", "text.set") {
            id = i
        } else {
            guard let first = try s.doc().selection.shapes.first else { throw Cmd.bad("text.set", "missing `id` (or select a shape)") }
            id = first
        }
        let cell = posParam(p, "cell")
        let inherited = inheritedAligns(s, id)
        func fill(_ body: inout TextBody) {
            let keep = body.paragraphs.first?.runs.first?.props ?? RunProps()
            let levels = body.paragraphs.map { ($0.level, $0.props) }
            var nb = TextBody.fromText(text)
            for i in nb.paragraphs.indices {
                // Leading tabs set the outline level.
                if !applyLeadingTabs(&nb.paragraphs[i]), let (lv, pp) = levels.at(i) {
                    nb.paragraphs[i].level = lv
                    nb.paragraphs[i].props = pp
                }
                promoteRTLIfNeeded(&nb.paragraphs[i], inherited)
                for r in nb.paragraphs[i].runs.indices { nb.paragraphs[i].runs[r].props = keep }
            }
            body.paragraphs = nb.paragraphs
        }
        _ = try Cmd.editShapes(s, ["id": id.toJSON()], "text.set") { sh in
            switch (sh.kind, cell) {
            case (.table(var t), .some(let c)):
                let done: Bool? = t.mutateCell(c.para, c.char) { fill(&$0.text); return true }
                guard done != nil else { throw Cmd.bad("text.set", "no text here (tables need `cell`)") }
                sh.kind = .table(t)
            case (.table, nil):
                throw Cmd.bad("text.set", "no text here (tables need `cell`)")
            default:
                var body = sh.text ?? TextBody()
                fill(&body)
                sh.text = body
            }
        }
        try fitTextBox(s, id)
        return Cmd.ok()
    }

    @Sendable static func get(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", "text.get") {
            id = i
        } else if let t = st.selection.text {
            id = t.shape
        } else {
            guard let first = st.selection.shapes.first else { throw Cmd.bad("text.get", "missing `id`") }
            id = first
        }
        guard let sh = st.shape(id) else { throw Cmd.bad("text.get", "no such shape") }
        let t = sh.text ?? TextBody()
        return ["text": .string(t.text), "paragraphs": .array(t.paragraphs.map { ["level": .integer(Int($0.level)), "text": .string($0.text)] })]
    }

    /// Rust's byte-wise `String` order.
    static func rustLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    @Sendable static func fontsUsed(_ s: Session, _ p: JSON) throws -> JSON {
        let v = try EngineFonts.usedFonts(s.doc().doc)
        // `sort_by_key` is stable: equal keys keep their order.
        let sorted = v.enumerated().map { ($0.offset, $0.element, rustLowercase($0.element)) }.sorted { x, y in
            if rustEqual(x.2, y.2) { return x.0 < y.0 }
            return rustLess(x.2, y.2)
        }
        return .array(sorted.map { .string($0.1) })
    }

    @Sendable static func replaceFont(_ s: Session, _ p: JSON) throws -> JSON {
        guard let from = Cmd.strParam(p, "from").map({ String(rustTrim($0)) }), !from.isEmpty else { throw Cmd.bad("font.replace", "missing `from`") }
        guard let to = Cmd.strParam(p, "to").map({ String(rustTrim($0)) }), !to.isEmpty else { throw Cmd.bad("font.replace", "missing `to`") }
        if to.utf8.count > 256 || to.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw Cmd.bad("font.replace", "`to` is not a font name")
        }
        // Count on a copy first so a replace that finds nothing leaves no undo step.
        var probe = try s.doc().doc
        if EngineFonts.replaceFont(&probe, from, to) == 0 { return ["replaced": 0] }
        let n = try s.edit { doc, _ in EngineFonts.replaceFont(&doc, from, to) }
        let st = try s.doc()
        st.missingFonts = EngineFonts.missingFonts(st.doc)
        return ["replaced": .integer(n)]
    }
}
