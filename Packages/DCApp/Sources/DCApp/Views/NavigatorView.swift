// DCApp — the slide navigator (Normal view's thumbnail column). Port of deckcraft
// `crates/ui-egui/src/thumbs.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors):
// numbered thumbnails sized to the column, grouped by section (fold, rename, the section menu), the
// selection synced with the engine (⇧ and ⌘ clicks → `slide.selectRange` / `slide.selectSlides`), hidden
// and animated marks, drag to reorder (`slide.move`), the slide menu, a double-click that starts the show,
// and the masters and layouts in Slide Master view. An NSTableView lays out only the rows in view, and
// thumbnails come from `Thumbnails` (drawn off the main thread), so a 1,000-slide deck stays responsive.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DCRender
import DesignScaffold

extension NSPasteboard.PasteboardType {
    /// A slide dragged inside a window (its index), and a section bar (its index).
    static let deckCraftSlideRow = NSPasteboard.PasteboardType("ai.storyteller.deckcraft.slide-row")
    static let deckCraftSectionRow = NSPasteboard.PasteboardType("ai.storyteller.deckcraft.section-row")
}

/// Sections folded shut, shared by the navigator and the Slide Sorter (`sorter::State::collapsed`).
@MainActor
enum SectionFolds {
    static var folded: Set<FoldKey> = []

    static func isFolded(_ uid: UInt64, _ first: UInt32?) -> Bool {
        first.map { folded.contains(FoldKey(uid: uid, firstSlide: $0)) } ?? false
    }

    /// Fold or unfold a section by its first slide; an empty section has nothing to fold.
    static func toggle(_ uid: UInt64, _ first: UInt32?, model: AppModel) {
        guard let first else { return }
        let k = FoldKey(uid: uid, firstSlide: first)
        if folded.contains(k) { folded.remove(k) } else { folded.insert(k) }
        model.changed()
    }
}

/// One row of the navigator.
enum NavItem: Equatable {
    case section(index: Int, name: String, count: Int, folded: Bool, first: UInt32?)
    case slide(Int)
    case master(Int)
    case layout(Int, Int)
}

/// The thumbnail column's geometry, shared with its rows.
enum NavigatorMetrics {
    /// The slide number's column.
    static let gutter = Tokens.Space.xl + Tokens.Space.xs
    /// Space above and below each thumbnail.
    static let pad = Tokens.Space.s
    static let sectionHeight = Tokens.Layout.controlHeight + Tokens.Space.xs
    /// A layout's thumbnail is indented under its master.
    static let layoutIndent = Tokens.Space.l
}

@MainActor
final class NavigatorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let link: DocLink
    let table = NavigatorTable()
    let scroll = NSScrollView()
    private(set) var items: [NavItem] = []
    private var lastSlide: Int?
    private var lastWidth: CGFloat = 0
    private var observers: [any NSObjectProtocol] = []
    /// Layout thumbnails in Slide Master view, by (master, layout), with the master they were drawn from.
    private var layoutThumbs: [String: (master: Master, width: Int, image: CGImage)] = [:]
    /// The section bar being renamed.
    private var renaming: Int?

    init(link: DocLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("slide"))
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
        table.registerForDraggedTypes([.deckCraftSlideRow])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel(String(localized: "Slides", bundle: .module, comment: "Accessibility label of the slide navigator"))
        table.controller = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        view = scroll
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        observers.append(nc.addObserver(forName: .deckCraftThumbnailReady, object: nil, queue: .main) { [weak self] note in
            let uid = note.userInfo?["uid"] as? UInt64
            MainActor.assumeIsolated {
                guard let self, uid == self.link.uid else { return }
                self.redrawVisible()
            }
        })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = scroll.contentSize.width
        guard abs(w - lastWidth) > 0.5 else { return }
        lastWidth = w
        if !items.isEmpty { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< items.count)) }
        redrawVisible()
    }

    private func scrolled() {
        let y = Double(scroll.contentView.bounds.origin.y)
        if link.model.ui.thumbsScroll != y { link.model.ui.thumbsScroll = y }
    }

    // MARK: Refresh

    /// The rows for the document as it is now.
    func currentItems() -> [NavItem] {
        guard let st = link.state else { return [] }
        switch st.selection.target {
        case .handout, .notesMaster:
            // Handout and Notes Master views have one page and no thumbnails, as in PowerPoint.
            return []
        case .master, .layout:
            var out: [NavItem] = []
            for (mi, m) in st.doc.masters.enumerated() {
                out.append(.master(mi))
                for li in m.layouts.indices { out.append(.layout(mi, li)) }
            }
            return out
        case .slides:
            return NavigatorLogic.rows(st.doc, uid: st.uid, folded: SectionFolds.folded).map {
                switch $0 {
                case .section(let i, let name, let count, let folded, let first): .section(index: i, name: name, count: count, folded: folded, first: first)
                case .slide(let i): .slide(i)
                }
            }
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        let new = currentItems()
        if new != items {
            items = new
            renaming = nil
            table.reloadData()
        } else {
            redrawVisible()
        }
        // The current slide's thumbnail scrolls into view when the slide changes (#917), minimally, so the
        // user's own scrolling stands.
        if let st = link.state, st.selection.target == .slides {
            let cur = st.selection.slide
            if lastSlide != cur, let row = items.firstIndex(of: .slide(cur)) { table.scrollRowToVisible(row) }
            lastSlide = cur
        }
    }

    /// Re-configure the rows on screen (selection, a new thumbnail) without reloading the table.
    func redrawVisible() {
        guard isViewLoaded else { return }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location ..< rows.location + rows.length {
            guard let v = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            configure(v, row)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// The thumbnail's size in points for a row width.
    func thumbSize(_ item: NavItem) -> CGSize {
        let aspect = link.state.map { slideAspect($0.doc) } ?? 0.5625
        var w = max(40, scroll.contentSize.width - NavigatorMetrics.gutter - Tokens.Space.m)
        if case .layout = item { w = max(32, w - NavigatorMetrics.layoutIndent) }
        return CGSize(width: w.rounded(.down), height: (w * aspect).rounded())
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let item = items.at(row) else { return 1 }
        if case .section = item { return NavigatorMetrics.sectionHeight }
        return thumbSize(item).height + 2 * NavigatorMetrics.pad
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = items.at(row) else { return nil }
        let v: NSView
        if case .section = item {
            let cell = (tableView.makeView(withIdentifier: SectionBarCell.id, owner: nil) as? SectionBarCell) ?? SectionBarCell()
            cell.identifier = SectionBarCell.id
            cell.name.delegate = self
            v = cell
        } else {
            let cell = (tableView.makeView(withIdentifier: SlideThumbCell.id, owner: nil) as? SlideThumbCell) ?? SlideThumbCell()
            cell.identifier = SlideThumbCell.id
            v = cell
        }
        configure(v, row)
        return v
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func configure(_ v: NSView, _ row: Int) {
        guard let item = items.at(row), let st = link.state else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        switch item {
        case .section(let index, let name, let count, let folded, let first):
            guard let cell = v as? SectionBarCell else { return }
            cell.configure(name: name, count: count, folded: folded, foldable: first != nil, renaming: renaming == index)
            cell.onFold = { [weak self] in
                guard let self else { return }
                SectionFolds.toggle(self.link.uid, first, model: self.link.model)
            }
        case .slide(let i):
            guard let cell = v as? SlideThumbCell, let slide = st.doc.slides.at(i) else { return }
            let size = thumbSize(item)
            let image = Thumbnails.shared.image(st.doc, uid: st.uid, index: i, width: Int((size.width * scale).rounded()))
            cell.configure(SlideThumbCell.Content(
                number: "\(i + 1)", image: image, imageSize: size, inset: NavigatorMetrics.gutter, selected: NavigatorLogic.isSelected(st, i),
                hidden: slide.hidden, animated: NavigatorLogic.hasAnimation(slide), label: String(localized: "Slide \(i + 1)", bundle: .module)
            ))
        case .master(let mi), .layout(let mi, _):
            guard let cell = v as? SlideThumbCell else { return }
            var li: Int?
            if case .layout(_, let l) = item { li = l }
            let size = thumbSize(item)
            let selected = switch (st.selection.target, li) {
            case (.master(let m), nil): m == mi
            case (.layout(let m, let l), let x?): m == mi && l == x
            default: false
            }
            let master = st.doc.masters.at(mi)
            let name = li.flatMap { master?.layouts.at($0)?.name } ?? String(localized: "\(master?.name ?? "") Slide Master", bundle: .module, comment: "A slide master's thumbnail: the master's name, then Slide Master")
            cell.configure(SlideThumbCell.Content(
                number: li == nil ? "\(mi + 1)" : "", image: layoutImage(st.doc, mi, li, Int((size.width * scale).rounded())), imageSize: size,
                inset: NavigatorMetrics.gutter + (li == nil ? 0 : NavigatorMetrics.layoutIndent), selected: selected, hidden: false,
                animated: false, label: name
            ))
            cell.toolTip = name
        }
    }

    /// A master's or layout's thumbnail (Slide Master view), drawn off the main thread.
    private func layoutImage(_ doc: Presentation, _ mi: Int, _ li: Int?, _ width: Int) -> CGImage? {
        guard let master = doc.masters.at(mi) else { return nil }
        let key = "\(mi)-\(li.map(String.init) ?? "m")"
        if let t = layoutThumbs[key], t.master == master, t.width == width { return t.image }
        let stale = layoutThumbs[key]?.image
        let sw = doc.slideSize.width
        guard sw > 0, sw.isFinite else { return stale }
        Task.detached(priority: .userInitiated) { [weak self] in
            var o = RenderOpts(scale: Double(width) / sw)
            o.edit = true
            let drawn = DrawnImage(cg: renderLayout(doc, mi, li, o).cgImage())
            await self?.storeLayout(key, master, width, drawn)
        }
        return stale
    }

    private func storeLayout(_ key: String, _ master: Master, _ width: Int, _ drawn: DrawnImage) {
        guard let cg = drawn.cg else { return }
        if let t = layoutThumbs[key], t.master == master, t.width == width { return }
        layoutThumbs[key] = (master, width, cg)
        redrawVisible()
    }

    // MARK: Clicks and keys

    /// A click on a row: the slide's selection by modifiers (`thumbs.rs`), a master or layout in Slide
    /// Master view.
    func click(row: Int, shift: Bool, command: Bool) {
        guard let item = items.at(row), let st = link.state else { return }
        switch item {
        case .slide(let i):
            if let (id, p) = NavigatorLogic.click(st.doc, index: i, shift: shift, command: command) { link.run(id, p) }
        case .master(let mi):
            link.run("view.slideMaster", ["master": .integer(mi)])
        case .layout(let mi, let li):
            link.run("view.slideMaster", ["master": .integer(mi), "layout": .integer(li)])
        case .section:
            break
        }
    }

    /// A double-click: a slide plays the show from it; a section bar is renamed.
    func doubleClick(row: Int) {
        guard let item = items.at(row) else { return }
        switch item {
        case .slide(let i): link.run("show.start", ["from": .integer(i)])
        case .section(let index, _, _, _, _): beginRename(index)
        default: break
        }
    }

    /// Keys while the navigator has the keyboard: arrows move, Delete deletes the selected slides, Return
    /// adds a slide after the current one.
    /// Move to slide `i`; with Shift, extend the selection to it.
    private func go(_ i: Int, _ extend: Bool) {
        if extend { link.run("slide.selectRange", ["to": .integer(i), "add": true]) } else { link.run("slide.go", ["index": .integer(i)]) }
    }

    func key(_ e: NSEvent) -> Bool {
        guard let st = link.state, st.selection.target == .slides else { return false }
        let n = st.doc.slides.count
        let cur = st.selection.slide
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 125, 124: // down, right
            if cur + 1 < n { go(cur + 1, shift) }
            return true
        case 126, 123: // up, left
            if cur > 0 { go(cur - 1, shift) }
            return true
        case 115: link.run("slide.go", ["index": 0]); return true // home
        case 119: if n > 0 { link.run("slide.go", ["index": .integer(n - 1)]) }; return true // end
        case 51, 117: link.run("slide.delete"); return true // delete, forward delete
        case 36, 76: link.run("slide.new"); return true // return, enter
        default: return false
        }
    }

    // MARK: Menus

    func menu(row: Int) -> NSMenu? {
        guard let item = items.at(row) else { return nil }
        switch item {
        case .slide(let i): return SlideMenus.slideMenu(link, i)
        case .section(let index, let name, _, _, _): return SlideMenus.sectionMenu(link, index, name) { [weak self] in self?.beginRename(index) }
        default: return nil
        }
    }

    // MARK: Rename

    func beginRename(_ index: Int) {
        guard let row = items.firstIndex(where: { if case .section(let i, _, _, _, _) = $0 { return i == index } else { return false } }) else { return }
        renaming = index
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SectionBarCell else { return }
        configure(cell, row)
        cell.beginEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renaming = nil
            control.abortEditing()
            redrawVisible()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let index = renaming, let field = obj.object as? NSTextField else { return }
        renaming = nil
        let name = String(rustTrim(field.stringValue))
        let old = link.state?.doc.sections.at(index)?.name
        if !name.isEmpty, name != old {
            link.run("section.rename", ["index": .integer(index), "name": .string(name)])
        } else {
            redrawVisible()
        }
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .slide(let i)? = items.at(row), renaming == nil else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(link.uid):\(i)", forType: .deckCraftSlideRow)
        return item
    }

    /// The slide a drag started from, when it is one of this presentation's.
    private func draggedSlide(_ info: any NSDraggingInfo) -> Int? {
        guard let s = info.draggingPasteboard.string(forType: .deckCraftSlideRow) else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, UInt64(parts[0]) == link.uid, let i = Int(parts[1]) else { return nil }
        return i
    }

    /// The slide gap (0…count) above table row `row`.
    func slot(above row: Int) -> Int {
        for item in items.dropFirst(max(0, row)) {
            if case .slide(let i) = item { return i }
        }
        return link.state?.doc.slides.count ?? 0
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let from = draggedSlide(info) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return SorterLogic.moveDest(from, slot(above: row)) == nil ? [] : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = draggedSlide(info), let to = SorterLogic.moveDest(from, slot(above: row)) else { return false }
        return (try? link.run("slide.move", ["from": .integer(from), "to": .integer(to)]).get()) != nil
    }
}

/// The navigator's table: clicks select through the engine (the table's own selection is unused), the
/// context menu is the row's, and the arrow keys move between slides.
@MainActor
final class NavigatorTable: NSTableView {
    weak var controller: NavigatorViewController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let c = controller {
            if event.clickCount == 2 {
                c.doubleClick(row: row)
                return
            }
            let mods = event.modifierFlags
            c.click(row: row, shift: mods.contains(.shift), command: mods.contains(.command))
        }
        // The table's tracking starts a drag (reorder).
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? controller?.menu(row: row) : nil
    }

    override func keyDown(with event: NSEvent) {
        if controller?.key(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A slide's (or a layout's) row: the number, the thumbnail with its frame or selection ring, the
/// hidden-slide and animation marks. Drawn, not built from subviews, so rows are cheap.
@MainActor
final class SlideThumbCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("thumb")

    struct Content: Equatable {
        var number: String
        var image: CGImage?
        var imageSize: CGSize
        var inset: CGFloat
        var selected: Bool
        var hidden: Bool
        var animated: Bool
        var label: String
    }

    private var content: Content?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ c: Content) {
        guard c != content else { return }
        content = c
        setAccessibilityLabel(c.label)
        setAccessibilitySelected(c.selected)
        needsDisplay = true
    }

    /// The thumbnail's box in the cell.
    var imageRect: CGRect {
        guard let c = content else { return .zero }
        return CGRect(x: c.inset, y: NavigatorMetrics.pad, width: c.imageSize.width, height: c.imageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content else { return }
        let r = imageRect
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let numberColor: NSColor = c.selected ? .labelColor : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: numberColor,
            .strikethroughStyle: c.hidden ? NSUnderlineStyle.single.rawValue : 0,
        ]
        let num = NSAttributedString(string: c.number, attributes: attrs)
        let ns = num.size()
        num.draw(at: CGPoint(x: max(Tokens.Space.xs, r.minX - Tokens.Space.s - ns.width), y: r.minY))
        if c.animated, let star = NSImage(systemSymbolName: "sparkle", accessibilityDescription: String(localized: "Has animations or a transition", bundle: .module)) {
            let side = font.pointSize
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular).applying(.init(hierarchicalColor: .tertiaryLabelColor))
            let img = star.withSymbolConfiguration(config) ?? star
            img.draw(in: CGRect(x: max(Tokens.Space.xs, r.minX - Tokens.Space.s - side), y: r.minY + ns.height + Tokens.Space.xs, width: side, height: side))
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let image = c.image {
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAlpha(c.hidden ? 0.55 : 1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
        } else {
            NSColor.quaternaryLabelColor.setFill()
            r.fill()
        }
        if c.selected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: Tokens.Radius.control / 2, yRadius: Tokens.Radius.control / 2)
            ring.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            let frame = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            frame.lineWidth = Tokens.Layout.hairline
            frame.stroke()
        }
    }
}

/// A section's bar: fold chevron, name (renamed in place) and slide count.
@MainActor
final class SectionBarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("section")
    let chevron = NSButton()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    var onFold: (() -> Void)?
    private var folded = false
    private var label = ""

    init() {
        super.init(frame: .zero)
        chevron.isBordered = false
        chevron.bezelStyle = .accessoryBarAction
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(fold)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.cell?.usesSingleLineMode = true
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        for v in [chevron, name, count] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.Space.xs),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Tokens.Space.l + Tokens.Space.xs),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: Tokens.Space.xs),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Tokens.Space.s),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.Space.m),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(name text: String, count n: Int, folded: Bool, foldable: Bool, renaming: Bool) {
        self.folded = folded
        label = text
        if !renaming || !name.isEditable {
            name.stringValue = text
            name.isEditable = renaming
            name.isBezeled = renaming
            name.drawsBackground = renaming
        }
        count.stringValue = "(\(n))"
        chevron.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.isEnabled = foldable
        chevron.setAccessibilityLabel(folded ? String(localized: "Expand \(text)", bundle: .module, comment: "Unfolds the section named") : String(localized: "Collapse \(text)", bundle: .module, comment: "Folds the section named"))
        setAccessibilityLabel(text)
    }

    func beginEditing() {
        name.isEditable = true
        name.isBezeled = true
        name.drawsBackground = true
        window?.makeFirstResponder(name)
        name.currentEditor()?.selectAll(nil)
    }

    @objc private func fold() { onFold?() }
}

/// The slide and section context menus (`thumbs::slide_menu` and the section bar's menu).
@MainActor
enum SlideMenus {
    static func slideMenu(_ link: DocLink, _ i: Int) -> NSMenu {
        // A right-click on a slide that isn't selected selects it first.
        if let st = link.state, !NavigatorLogic.isSelected(st, i) { link.run("slide.go", ["index": .integer(i)]) }
        let m = NSMenu()
        m.add(String(localized: "Cut", bundle: .module)) { PasteboardBridge.shared.copy(link, cut: true, slides: true) }
        m.add(String(localized: "Copy", bundle: .module)) { PasteboardBridge.shared.copy(link, cut: false, slides: true) }
        m.add(String(localized: "Paste", bundle: .module)) { PasteboardBridge.shared.paste(link, slides: true) }
        m.addItem(.separator())
        m.add(String(localized: "New Slide", bundle: .module)) { link.run("slide.new") }
        m.add(String(localized: "Duplicate Slide", bundle: .module)) { link.run("slide.duplicate") }
        m.add(String(localized: "Delete Slide", bundle: .module)) { link.run("slide.delete") }
        m.addItem(.separator())
        m.add(String(localized: "Add Section", bundle: .module)) { link.run("section.add", ["at": .integer(i)]) }
        let layouts = NSMenu()
        for l in link.state?.doc.masters.first?.layouts ?? [] {
            layouts.add(l.name) { link.run("slide.layout", ["layout": .integer(l.id.rawValue)]) }
        }
        let layoutItem = NSMenuItem(title: String(localized: "Layout", bundle: .module, comment: "Submenu of slide layouts"), action: nil, keyEquivalent: "")
        layoutItem.submenu = layouts
        m.addItem(layoutItem)
        m.add(String(localized: "Reset Slide", bundle: .module)) { link.run("slide.reset") }
        m.add(String(localized: "Format Background…", bundle: .module)) { link.run("view.pane", ["pane": "background"]) }
        let hidden = link.state?.doc.slides.at(i)?.hidden ?? false
        m.add(hidden ? String(localized: "Show Slide", bundle: .module) : String(localized: "Hide Slide", bundle: .module)) { link.run("slide.hide", ["index": .integer(i)]) }
        return m
    }

    static func sectionMenu(_ link: DocLink, _ index: Int, _ name: String, rename: @escaping @MainActor () -> Void) -> NSMenu {
        let m = NSMenu()
        m.add(String(localized: "Rename Section", bundle: .module)) { rename() }
        m.add(String(localized: "Add Section", bundle: .module)) {
            if let at = link.state?.selection.slide { link.run("section.add", ["at": .integer(at)]) }
        }
        m.add(String(localized: "Remove Section", bundle: .module)) { link.run("section.remove", ["index": .integer(index)]) }
        m.add(String(localized: "Remove Section & Slides", bundle: .module)) { link.run("section.remove", ["index": .integer(index), "slides": true]) }
        m.addItem(.separator())
        m.add(String(localized: "Move Section Up", bundle: .module)) { link.run("section.move", ["index": .integer(index), "to": .integer(max(0, index - 1))]) }
        m.add(String(localized: "Move Section Down", bundle: .module)) { link.run("section.move", ["index": .integer(index), "to": .integer(index + 1)]) }
        return m
    }
}

/// The target of a menu item that runs a closure; the item keeps it alive as its represented object.
@MainActor
final class MenuAction: NSObject {
    private let block: @MainActor () -> Void
    init(_ block: @escaping @MainActor () -> Void) { self.block = block }
    @objc func fire(_ sender: Any?) { block() }
}

extension NSMenu {
    /// Add an item that runs `block`.
    @MainActor @discardableResult
    func add(_ title: String, _ block: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(block)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        addItem(item)
        return item
    }
}
