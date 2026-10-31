// DCApp — speaker notes: the notes pane under the slide and the Notes Page view. Ports of `notes_pane`
// (deckcraft `crates/ui-egui/src/status.rs`), `notes_page` (`sorter.rs`) and the drawing of `notes.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The notes are an NSTextView showing
// their formatting (bold, italic, underline, strikethrough, sizes, indents, bullets and numbers); typing
// edits a formatted draft (`NotesDraft`), saved with `slide.notes {body, index}` when the field loses the
// keyboard or another slide is shown, to the slide it was written on. Spelling is the text view's own
// (continuous checking, suggestions in its menu), in place of deckcraft's notes squiggles.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import DCText
import DesignScaffold

/// Colours of the printed page (Notes Page view): the page is paper whatever the appearance, as a slide
/// is, so its colours are the document's, not the interface's.
enum PaperColors {
    static let paper = NSColor.white
    static let ink = NSColor(white: 0.12, alpha: 1)
    static let rule = NSColor(white: 0.5, alpha: 1)
}

/// Notes as formatted text for the editor (`notes::galley`): `base` points for 12 pt text.
enum NotesText {
    static func attributed(_ body: TextBody, base: CGFloat, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bullets = NotesLogic.bullets(body)
        let k = Double(base) / 12
        for (n, p) in body.paragraphs.enumerated() {
            let (first, rest) = NotesLogic.indents(p)
            let style = NSMutableParagraphStyle()
            let margin = CGFloat(NotesLogic.px(rest, k))
            var firstX = CGFloat(NotesLogic.px(first, k))
            if let b = bullets.at(n) ?? nil {
                // The text starts at the margin, after the bullet if it's wider than the hanging indent.
                firstX = max(margin, firstX + base * (0.4 + 0.6 * CGFloat(b.count)))
            }
            style.firstLineHeadIndent = firstX
            style.headIndent = margin
            let start = out.length
            for r in p.runs where !r.content.isEmpty {
                out.append(NSAttributedString(string: r.content, attributes: attributes(r.props, base, color, style)))
            }
            if out.length == start {
                // An empty paragraph keeps its paragraph style for the caret.
                out.append(NSAttributedString(string: "", attributes: attributes(p.endProps, base, color, style)))
            }
            if n + 1 < body.paragraphs.count {
                out.append(NSAttributedString(string: "\n", attributes: attributes(p.endProps, base, color, style)))
            }
        }
        return out
    }

    static func attributes(_ props: RunProps, _ base: CGFloat, _ color: NSColor, _ style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(NotesLogic.runSize(props, base: Double(base)))
        var font = NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if props.bold == true { traits.insert(.boldFontMask) }
        if props.italic == true { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if let u = props.underline, u != "none" { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if props.strike == .single || props.strike == .double { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }
}

/// The notes editor: draws each paragraph's bullet or number in its hanging indent and a placeholder when
/// empty. TextKit 1, so the bullets can be placed from the layout manager.
@MainActor
final class NotesTextView: NSTextView {
    var placeholder = String(localized: "Click to add notes", bundle: .module, comment: "Placeholder of the empty notes pane")
    var placeholderColor = NSColor.placeholderTextColor
    var bullets: [String?] = []
    var bulletFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var bulletColor = NSColor.labelColor
    /// Where each paragraph's first line starts (points), for its bullet.
    var bulletX: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, window?.firstResponder !== self {
            NSAttributedString(string: placeholder, attributes: [.font: font ?? bulletFont, .foregroundColor: placeholderColor])
                .draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y))
        }
        drawBullets()
    }

    private func drawBullets() {
        guard let lm = layoutManager, let tc = textContainer, !bullets.isEmpty else { return }
        let ns = string as NSString
        var start = 0
        for (i, b) in bullets.enumerated() {
            guard start <= ns.length else { break }
            let lineEnd = ns.lineRange(for: NSRange(location: start, length: 0))
            if let b, start < ns.length || lm.numberOfGlyphs > 0 {
                let glyph = lm.glyphIndexForCharacter(at: min(start, max(0, ns.length - 1)))
                let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let x = textContainerOrigin.x + tc.lineFragmentPadding + (bulletX.at(i) ?? 0)
                let s = NSAttributedString(string: b, attributes: [.font: bulletFont, .foregroundColor: bulletColor])
                let y = textContainerOrigin.y + rect.minY + (used.height - s.size().height) / 2
                s.draw(at: NSPoint(x: x, y: y))
            }
            start = NSMaxRange(lineEnd)
            if lineEnd.length == 0 { break }
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

/// An editor of one slide's notes, following the engine while it isn't being typed in. Used by the
/// notes pane and the Notes Page view.
@MainActor
final class NotesEditor: NSObject, NSTextViewDelegate {
    let link: DocLink
    let textView: NotesTextView
    /// Pixels for 12 pt text.
    var base: CGFloat
    var color: NSColor
    /// The draft and the slide it belongs to (`notes_buf`).
    private(set) var draft = NotesDraft(.default)
    private(set) var target: (uid: UInt64, index: Int)?
    private var loading = false

    init(link: DocLink, base: CGFloat, color: NSColor) {
        self.link = link
        self.base = base
        self.color = color
        textView = NotesTextView(usingTextLayoutManager: false)
        super.init()
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: Tokens.Space.xs, height: Tokens.Space.xs)
        textView.setAccessibilityLabel(String(localized: "Notes", bundle: .module, comment: "Accessibility label of the speaker notes editor"))
    }

    var focused: Bool { textView.window?.firstResponder === textView }

    /// Follow the current slide: save an edited draft that belongs to another slide first, then show this
    /// slide's notes unless they are being typed.
    func refresh() {
        guard let st = link.state, st.selection.target == .slides else { return }
        let here = (st.uid, st.selection.slide)
        if draft.edited, let t = target, t != here || !focused {
            save()
        }
        let notes = st.currentSlide?.notes ?? .default
        if target.map({ $0 != here }) ?? true || (!focused && draft.body != notes) {
            load(notes)
            target = here
        }
    }

    /// Show `body` (not typed).
    func load(_ body: TextBody) {
        loading = true
        defer { loading = false }
        draft = NotesDraft(body)
        let text = NotesText.attributed(body, base: base, color: color)
        if textView.textStorage?.isEqual(to: text) != true { textView.textStorage?.setAttributedString(text) }
        textView.typingAttributes = NotesText.attributes(body.paragraphs.last?.endProps ?? RunProps(), base, color, NSParagraphStyle.default)
        textView.font = NSFont.systemFont(ofSize: base)
        decorate()
    }

    /// Draw the notes again at a new `base` (unless they are being typed).
    func rescale() {
        guard !focused else { return }
        let edited = draft.edited
        let body = draft.body
        load(body)
        draft.edited = edited
    }

    /// The bullets drawn in the hanging indents.
    private func decorate() {
        let body = draft.body
        textView.bullets = NotesLogic.bullets(body)
        textView.bulletX = body.paragraphs.map { CGFloat(NotesLogic.px(NotesLogic.indents($0).first, Double(base) / 12)) }
        textView.bulletFont = NSFont.systemFont(ofSize: base * 0.9)
        textView.bulletColor = color
        textView.needsDisplay = true
    }

    /// Save the draft to the slide it was written on (`slide.notes {body, index}`).
    func save() {
        guard draft.edited, let t = target else { return }
        draft.edited = false
        guard t.uid == link.uid else { return }
        link.run("slide.notes", ["body": draft.body.toJSON(), "index": .integer(t.index)])
    }

    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        draft.type(textView.string)
        // The bullets follow the typed paragraphs; the text keeps what the user typed until it is saved.
        textView.bullets = NotesLogic.bullets(draft.body)
        textView.needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        save()
    }
}

/// The notes pane under the slide (`notes_pane`).
@MainActor
final class NotesPaneController: NSViewController {
    let editor: NotesEditor
    let scroll = NSScrollView()

    init(link: DocLink) {
        editor = NotesEditor(link: link, base: NSFont.systemFontSize, color: .labelColor)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        scroll.documentView = editor.textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: Tokens.Space.xs, left: Tokens.Space.s, bottom: Tokens.Space.xs, right: Tokens.Space.s)
        scroll.automaticallyAdjustsContentInsets = false
        editor.textView.minSize = NSSize(width: 0, height: 0)
        editor.textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textView.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        view = scroll
    }

    func refresh() { editor.refresh() }
}

/// Notes Page view (`notes_page`): the page, with the slide and its notes where the notes master puts
/// them, the master's header and footer text, and the notes editable in place. Page Up and Page Down
/// change slides.
@MainActor
final class NotesPageViewController: NSViewController {
    let link: DocLink
    let page = NotesPageView()
    let editor: NotesEditor
    private var observer: (any NSObjectProtocol)?

    init(link: DocLink) {
        self.link = link
        editor = NotesEditor(link: link, base: NSFont.systemFontSize, color: PaperColors.ink)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        page.controller = self
        // The notes fill the notes master's body box.
        editor.textView.isVerticallyResizable = false
        editor.textView.placeholder = String(localized: "Click to add text", bundle: .module, comment: "Placeholder of the empty notes on the Notes Page")
        editor.textView.placeholderColor = PaperColors.rule
        editor.textView.autoresizingMask = []
        page.addSubview(editor.textView)
        view = page
        observer = NotificationCenter.default.addObserver(forName: .deckCraftThumbnailReady, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.page.needsDisplay = true }
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        page.layoutPage()
        editor.refresh()
        page.needsDisplay = true
    }
}

@MainActor
final class NotesPageView: NSView {
    weak var controller: NotesPageViewController?
    /// Letter, in points (as the PDF notes pages are laid out).
    static let paper = (612.0, 792.0)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The page's box in the view and points per paper point.
    var pageFrame: (rect: CGRect, k: CGFloat) {
        let margin = Tokens.Space.xl
        let h = max(1, bounds.height - 2 * margin)
        let w = h * CGFloat(Self.paper.0 / Self.paper.1)
        let fit = min(1, max(1, bounds.width - 2 * margin) / w)
        let (pw, ph) = (w * fit, h * fit)
        let r = CGRect(x: (bounds.width - pw) / 2, y: (bounds.height - ph) / 2, width: pw, height: ph)
        return (r, pw / CGFloat(Self.paper.0))
    }

    private func toView(_ r: Rect, _ page: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: page.minX + CGFloat(r.x0) * k, y: page.minY + CGFloat(r.y0) * k, width: CGFloat(r.width) * k, height: CGFloat(r.height) * k)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPage()
    }

    /// Place the notes editor in the notes box.
    func layoutPage() {
        guard let c = controller, let st = c.link.state else { return }
        let (page, k) = pageFrame
        let (_, notes) = PDF.notesFrames(st.doc, Self.paper)
        let r = toView(notes, page, k)
        let tv = c.editor.textView
        if abs(c.editor.base - 12 * k) > 0.01 {
            // The notes' size follows the page's.
            c.editor.base = 12 * k
            c.editor.rescale()
        }
        if tv.frame != r {
            tv.frame = r
            tv.textContainer?.containerSize = NSSize(width: r.width, height: .greatestFiniteMagnitude)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let c = controller, let st = c.link.state else { return }
        let (page, k) = pageFrame
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = Tokens.Space.s
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        PaperColors.paper.setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()
        let idx = st.selection.slide
        let (slideBox, _) = PDF.notesFrames(st.doc, Self.paper)
        let sr = toView(slideBox, page, k).integral
        let scale = window?.backingScaleFactor ?? 2
        if let img = Thumbnails.shared.image(st.doc, uid: st.uid, index: idx, width: Int(sr.width * scale), kind: .page), let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: sr.minX, y: sr.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: sr.size))
            ctx.restoreGState()
        }
        PaperColors.rule.setStroke()
        let frame = NSBezierPath(rect: sr.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = Tokens.Layout.hairline
        frame.stroke()
        // The notes master's header, date, footer and page number.
        if let m = st.doc.notesMaster {
            for t in PDF.masterTexts(st.doc, m, Self.paper, idx + 1) {
                let r = toView(t.rect, page, k)
                // Only an installed font is looked up by name: asking AppKit for one macOS downloads on demand blocks.
                let named = FontDB.isInstalled(t.style.family) ? NSFont(name: t.style.family, size: CGFloat(t.style.size) * k) : nil
                var font = named ?? NSFont.systemFont(ofSize: max(4, CGFloat(t.style.size) * k))
                var traits: NSFontTraitMask = []
                if t.style.bold { traits.insert(.boldFontMask) }
                if t.style.italic { traits.insert(.italicFontMask) }
                if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
                let color = NSColor(srgbRed: CGFloat(t.style.color.r) / 255, green: CGFloat(t.style.color.g) / 255, blue: CGFloat(t.style.color.b) / 255, alpha: CGFloat(t.style.color.a) / 255)
                let style = NSMutableParagraphStyle()
                style.alignment = t.right ? .right : .left
                NSAttributedString(string: t.text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]).draw(in: r)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 121: controller?.link.run("slide.next") // page down
        case 116: controller?.link.run("slide.previous") // page up
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}
