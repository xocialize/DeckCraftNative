// DCApp — Outline view: each slide's title and text as an editable outline, in the navigator's column.
// Port of `outline_pane`, `outline_slide` and `outline_estimate` (deckcraft `crates/ui-egui/src/sorter.rs`,
// MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). A title or text block that loses the
// keyboard with new text runs `text.set` on its shape (a tab per indent level, as `text.set` reads it);
// getting the keyboard goes to the slide. Tab indents and ⇧Tab outdents a line. Only the rows in view are
// laid out (NSTableView), each row taking its estimated height until it has been measured, so a
// 2,000-slide outline stays fast (`huge_deck_tests.rs`).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DesignScaffold

@MainActor
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let link: DocLink
    let table = NSTableView()
    let scroll = NSScrollView()
    private(set) var count = 0
    /// Measured row heights by slide.
    private var heights: [SlideId: CGFloat] = [:]
    private var entries: [Int: OutlineEntry] = [:]
    private var lastWidth: CGFloat = 0
    private var lastSlide: Int?

    static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// Where a slide's text starts (after the number and the slide mark).
    static let textInset = Tokens.Space.xl + Tokens.Space.l

    init(link: DocLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("outline"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Outline")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = scroll.contentSize.width
        if abs(w - lastWidth) > 0.5 {
            lastWidth = w
            heights.removeAll()
            // The rows on screen are measured again at the new width; the rest are estimated until shown.
            let rows = table.rows(in: table.visibleRect)
            if rows.length > 0 { remeasure(IndexSet(integersIn: rows.location ..< rows.location + rows.length)) }
            if count > 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< count)) }
        }
    }

    func refresh() {
        guard isViewLoaded, let st = link.state else { return }
        let n = st.doc.slides.count
        if n != count {
            count = n
            entries.removeAll()
            table.reloadData()
        } else {
            // Rows on screen follow the document unless one of their fields is being typed in.
            let rows = table.rows(in: table.visibleRect)
            var changed = IndexSet()
            for row in rows.location ..< rows.location + rows.length {
                let e = OutlineLogic.entry(st.doc, row)
                if e != entries[row], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineRowView, !cell.editing {
                    entries[row] = e
                    if let e { cell.configure(e, current: row == st.selection.slide) }
                    changed.insert(row)
                } else if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineRowView {
                    cell.setCurrent(row == st.selection.slide)
                }
            }
            if !changed.isEmpty { remeasure(changed) }
        }
        let cur = st.selection.slide
        if lastSlide != cur, cur < count { table.scrollRowToVisible(cur) }
        lastSlide = cur
    }

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let s = link.state?.doc.slides.at(row) else { return 1 }
        return heights[s.id] ?? CGFloat(OutlineLogic.estimate(s))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let st = link.state, let e = OutlineLogic.entry(st.doc, row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: OutlineRowView.id, owner: nil) as? OutlineRowView) ?? OutlineRowView()
        cell.identifier = OutlineRowView.id
        cell.controller = self
        entries[row] = e
        cell.configure(e, current: row == st.selection.slide)
        let h = cell.measure(width: max(1, scroll.contentSize.width))
        if heights[e.slide] != h {
            heights[e.slide] = h
            // Measured after the table asked for the height: tell it, once the current layout pass is done.
            let r = row
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, r < self.count else { return }
                    self.table.noteHeightOfRows(withIndexesChanged: [r])
                }
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func remeasure(_ rows: IndexSet) {
        guard let st = link.state else { return }
        for row in rows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineRowView, let s = st.doc.slides.at(row) else { continue }
            heights[s.id] = cell.measure(width: max(1, scroll.contentSize.width))
        }
        table.noteHeightOfRows(withIndexesChanged: rows)
    }

    /// A row's text changed size while typing.
    func rowResized(_ cell: OutlineRowView) {
        let row = table.row(for: cell)
        guard row >= 0, let s = link.state?.doc.slides.at(row) else { return }
        let h = cell.measure(width: max(1, scroll.contentSize.width))
        if heights[s.id] != h {
            heights[s.id] = h
            table.noteHeightOfRows(withIndexesChanged: [row])
        }
    }

    // MARK: Editing

    /// A field of slide `index` got the keyboard: that slide becomes the current one.
    func focus(_ index: Int) {
        if link.state?.selection.slide != index { link.run("slide.go", ["index": .integer(index)]) }
    }

    /// A field ended with `text`: `text.set` on its shape when it changed.
    func commit(_ index: Int, shape: ShapeId?, old: String, text: String) {
        guard text != old, let shape else { return }
        link.run("text.set", ["id": .integer(shape.rawValue), "text": .string(text)])
    }
}

/// One slide in the outline: number, slide mark, the title field and a text view per text block.
@MainActor
final class OutlineRowView: NSTableCellView, NSTextFieldDelegate, NSTextViewDelegate {
    static let id = NSUserInterfaceItemIdentifier("outlineRow")
    weak var controller: OutlineViewController?
    let number = NSTextField(labelWithString: "")
    let mark = NSView()
    let title = NSTextField(string: "")
    private var bodies: [OutlineTextView] = []
    private var entry: OutlineEntry?
    override var isFlipped: Bool { true }

    /// Whether a field of this row is being typed in.
    var editing: Bool {
        let r = window?.firstResponder
        return (r is NSText && (r as? NSView)?.isDescendant(of: self) == true) || bodies.contains { $0 === r }
    }

    init() {
        super.init(frame: .zero)
        number.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        number.textColor = .secondaryLabelColor
        number.alignment = .right
        mark.wantsLayer = true
        mark.layer?.borderWidth = Tokens.Layout.hairline
        mark.layer?.cornerRadius = 1
        title.font = OutlineViewController.titleFont
        title.isBordered = false
        title.drawsBackground = false
        title.focusRingType = .none
        title.placeholderString = "Slide title"
        title.lineBreakMode = .byWordWrapping
        title.cell?.wraps = true
        title.delegate = self
        title.setAccessibilityLabel("Slide title")
        for v in [number, mark, title] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCurrent(_ current: Bool) {
        mark.layer?.borderColor = (current ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
    }

    func configure(_ e: OutlineEntry, current: Bool) {
        entry = e
        number.stringValue = "\(e.index + 1)"
        setCurrent(current)
        if title.currentEditor() == nil { title.stringValue = e.title }
        title.isEditable = e.titleShape != nil
        while bodies.count < e.bodies.count {
            let tv = OutlineTextView(usingTextLayoutManager: false)
            tv.font = OutlineViewController.bodyFont
            tv.isRichText = false
            tv.allowsUndo = true
            tv.drawsBackground = false
            tv.isContinuousSpellCheckingEnabled = true
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
            tv.delegate = self
            tv.setAccessibilityLabel("Slide text")
            bodies.append(tv)
            addSubview(tv)
        }
        while bodies.count > e.bodies.count { bodies.removeLast().removeFromSuperview() }
        for (tv, b) in zip(bodies, e.bodies) where window?.firstResponder !== tv {
            if tv.string != b.text { tv.string = b.text }
            tv.defaultParagraphStyle = Self.bodyStyle
            tv.textStorage?.addAttribute(.paragraphStyle, value: Self.bodyStyle, range: NSRange(location: 0, length: (tv.string as NSString).length))
        }
        needsLayout = true
    }

    /// Body text: tabs indent by a fixed step.
    static let bodyStyle: NSParagraphStyle = {
        let s = NSMutableParagraphStyle()
        s.tabStops = (1 ... 9).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * Tokens.Space.xl) }
        s.defaultTabInterval = Tokens.Space.xl
        return s
    }()

    /// The height of `text` in `font` wrapped to `width`.
    static func textHeight(_ text: String, _ font: NSFont, _ width: CGFloat, _ style: NSParagraphStyle? = nil) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let style { attrs[.paragraphStyle] = style }
        let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attrs)
        let r = s.boundingRect(with: NSSize(width: max(1, width), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height)
    }

    /// The row's height at `width`, laying its fields out.
    @discardableResult
    func measure(width: CGFloat) -> CGFloat {
        let inset = OutlineViewController.textInset
        let w = max(Tokens.Space.xl, width - inset - Tokens.Space.m)
        var y = Tokens.Space.xs
        number.frame = CGRect(x: 0, y: y + 1, width: Tokens.Space.l + Tokens.Space.xs, height: Tokens.Space.l)
        mark.frame = CGRect(x: Tokens.Space.xl - Tokens.Space.xs / 2, y: y + Tokens.Space.xs, width: Tokens.Space.m + 2, height: Tokens.Space.s + 2)
        // The title field's cell adds a little padding around its text.
        let th = Self.textHeight(title.stringValue, OutlineViewController.titleFont, w - Tokens.Space.xs) + Tokens.Space.xs
        title.frame = CGRect(x: inset - 2, y: y, width: w + 2, height: th)
        y += th + Tokens.Space.xs
        for tv in bodies {
            let h = max(Tokens.Space.l, Self.textHeight(tv.string, OutlineViewController.bodyFont, w, Self.bodyStyle))
            tv.frame = CGRect(x: inset, y: y, width: w, height: h)
            y += h + Tokens.Space.xs
        }
        return y + Tokens.Space.xs
    }

    override func layout() {
        super.layout()
        measure(width: bounds.width)
    }

    // MARK: Editing

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let e = entry { controller?.focus(e.index) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let e = entry else { return }
        controller?.commit(e.index, shape: e.titleShape, old: e.title, text: title.stringValue)
    }

    func textDidBeginEditing(_ notification: Notification) {
        if let e = entry { controller?.focus(e.index) }
    }

    func textDidChange(_ notification: Notification) {
        controller?.rowResized(self)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let e = entry, let tv = notification.object as? OutlineTextView, let i = bodies.firstIndex(where: { $0 === tv }), let b = e.bodies.at(i) else { return }
        controller?.commit(e.index, shape: b.shape, old: b.text, text: tv.string)
    }
}

/// A text block in the outline: ⇧Tab takes a tab (a level) off the start of the line.
@MainActor
final class OutlineTextView: NSTextView {
    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let line = ns.lineRange(for: selectedRange())
        guard line.length > 0, ns.character(at: line.location) == 0x09 else { return }
        let r = NSRange(location: line.location, length: 1)
        if shouldChangeText(in: r, replacementString: "") {
            replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }
}
