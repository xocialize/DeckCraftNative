// DCApp — Slide Sorter: a grid of the slides by section. Port of `show`, `section_header` and
// `place_slides` in deckcraft `crates/ui-egui/src/sorter.rs` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): click selects (⇧ and ⌘ as in the navigator), double-click opens the slide in
// Normal view, drag reorders (`slide.move`); each section is a bar that folds, renames in place
// (double-click), has the section menu and drags as a whole (`section.move`); Add Section splits at the
// current slide; ⌘-scroll or a pinch zooms (`sorterZoom`). NSCollectionView makes only the cells in
// view, so a 1,000-slide deck draws a screenful of thumbnails.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DesignScaffold

/// The sorter's geometry.
enum SorterMetrics {
    /// A thumbnail's width at zoom 1 (`200.0 * zoom`).
    static let baseWidth: CGFloat = 200
    /// Room around a thumbnail in its cell: the sides and top, and the number line below.
    static let side = Tokens.Space.l + Tokens.Space.xs / 2
    static let top = Tokens.Space.s
    static let below = Tokens.Space.xl + Tokens.Space.xs
    static let headerHeight = Tokens.Layout.controlHeight + Tokens.Space.s
}

@MainActor
final class SorterViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    let link: DocLink
    let collection = SorterCollectionView()
    let layout = NSCollectionViewFlowLayout()
    let scroll = NSScrollView()
    let addSection = NSButton(title: String(localized: "Add Section", bundle: .module), target: nil, action: nil)
    /// The groups shown: a section (or none) and its slides; a folded section shows none.
    private(set) var groups: [(section: Int?, slides: [Int])] = []
    private var signature: [String] = []
    private var observers: [any NSObjectProtocol] = []
    /// The section being renamed.
    private(set) var renaming: Int?
    private var lastUid: UInt64 = 0

    init(link: DocLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 0, left: Tokens.Space.l, bottom: Tokens.Space.s, right: Tokens.Space.l)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(SorterItem.self, forItemWithIdentifier: SorterItem.id)
        collection.register(SorterHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SorterHeader.id)
        collection.registerForDraggedTypes([.deckCraftSlideRow, .deckCraftSectionRow])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.controller = self
        collection.setAccessibilityLabel(String(localized: "Slide Sorter", bundle: .module))
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        addSection.bezelStyle = .rounded
        addSection.controlSize = .regular
        addSection.target = self
        addSection.action = #selector(addSectionClicked)
        let bar = NSStackView(views: [addSection])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: Tokens.Space.m, left: Tokens.Space.xl, bottom: Tokens.Space.s, right: Tokens.Space.xl)
        let root = NSView()
        for v in [bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        observers.append(NotificationCenter.default.addObserver(forName: .deckCraftThumbnailReady, object: nil, queue: .main) { [weak self] note in
            let uid = note.userInfo?["uid"] as? UInt64
            MainActor.assumeIsolated {
                guard let self, uid == self.link.uid else { return }
                self.redrawVisible()
            }
        })
    }

    @objc private func addSectionClicked() {
        if let cur = link.state?.selection.slide { link.run("section.add", ["at": .integer(cur)]) }
    }

    // MARK: Refresh

    var zoom: CGFloat { CGFloat(min(max(link.model.ui.sorterZoom, StatusLogic.sorterZoomRange.lowerBound), StatusLogic.sorterZoomRange.upperBound)) }

    func thumbSize() -> CGSize {
        let w = (SorterMetrics.baseWidth * zoom).rounded()
        return CGSize(width: w, height: (w * CGFloat(link.state.map { slideAspect($0.doc) } ?? 0.5625)).rounded())
    }

    func refresh() {
        guard isViewLoaded, let st = link.state else { return }
        if st.uid != lastUid {
            // Another presentation drops a rename in progress (sorter_tests.rs).
            renaming = nil
            lastUid = st.uid
        }
        if let r = renaming, r >= st.doc.sections.count { renaming = nil }
        var g: [(Int?, [Int])] = []
        var sig: [String] = ["\(st.uid)", "\(thumbSize().width)", "\(renaming ?? -1)"]
        for (section, slides) in SorterLogic.groups(st.doc) {
            let sec = section.flatMap { st.doc.sections.at($0) }
            let folded = sec.map { SectionFolds.isFolded(st.uid, $0.slides.first?.rawValue) } ?? false
            g.append((section, folded ? [] : slides))
            sig.append("\(section ?? -1):\(sec?.name ?? ""):\(sec?.slides.count ?? 0):\(folded):\(slides.map { st.doc.slides.at($0)?.id.rawValue ?? 0 })")
        }
        if sig != signature {
            signature = sig
            groups = g
            layout.itemSize = cellSize()
            collection.reloadData()
        } else {
            redrawVisible()
        }
    }

    func cellSize() -> CGSize {
        let t = thumbSize()
        return CGSize(width: t.width + 2 * SorterMetrics.side, height: t.height + SorterMetrics.top + SorterMetrics.below)
    }

    func redrawVisible() {
        for ip in collection.indexPathsForVisibleItems() {
            if let item = collection.item(at: ip) as? SorterItem { configure(item, ip) }
        }
        for ip in collection.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
            if let h = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: ip) as? SorterHeader { configure(h, ip.section) }
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { groups.at(section)?.slides.count ?? 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SorterItem.id, for: indexPath)
        if let s = item as? SorterItem { configure(s, indexPath) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let v = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SorterHeader.id, for: indexPath)
        if let h = v as? SorterHeader { configure(h, indexPath.section) }
        return v
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        groups.at(section)?.section == nil ? .zero : NSSize(width: collectionView.bounds.width, height: SorterMetrics.headerHeight)
    }

    /// The slide index at an index path.
    func slide(at ip: IndexPath) -> Int? { groups.at(ip.section)?.slides.at(ip.item) }

    private func configure(_ item: SorterItem, _ ip: IndexPath) {
        guard let i = slide(at: ip), let st = link.state, let s = st.doc.slides.at(i) else { return }
        let size = thumbSize()
        let scale = view.window?.backingScaleFactor ?? 2
        let image = Thumbnails.shared.image(st.doc, uid: st.uid, index: i, width: Int((size.width * scale).rounded()), kind: .sorter)
        let transition = s.transition.flatMap { $0.kind == "none" ? nil : $0.kind }
        item.cell.configure(SorterCell.Content(
            number: "\(i + 1)", image: image, imageSize: size, selected: NavigatorLogic.isSelected(st, i), hidden: s.hidden,
            transition: transition, label: String(localized: "Slide \(i + 1)", bundle: .module)
        ))
    }

    private func configure(_ h: SorterHeader, _ group: Int) {
        guard let si = groups.at(group)?.section, let st = link.state, let sec = st.doc.sections.at(si) else {
            h.isHidden = true
            return
        }
        h.isHidden = false
        let first = sec.slides.first?.rawValue
        h.section = si
        h.controller = self
        h.name.delegate = self
        h.configure(name: sec.name, count: sec.slides.count, folded: SectionFolds.isFolded(st.uid, first), foldable: first != nil, renaming: renaming == si)
    }

    // MARK: Actions (the tests drive these too)

    func click(slide i: Int, shift: Bool, command: Bool) {
        guard let st = link.state, let (id, p) = NavigatorLogic.click(st.doc, index: i, shift: shift, command: command) else { return }
        link.run(id, p)
    }

    /// Double-click: the slide in Normal view.
    func open(slide i: Int) {
        link.run("slide.go", ["index": .integer(i)])
        link.run("view.normal")
    }

    func toggleFold(section si: Int) {
        guard let st = link.state, let sec = st.doc.sections.at(si) else { return }
        SectionFolds.toggle(st.uid, sec.slides.first?.rawValue, model: link.model)
    }

    func beginRename(_ si: Int) {
        renaming = si
        refresh()
        guard let g = groups.firstIndex(where: { $0.section == si }),
              let h = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: g)) as? SorterHeader
        else { return }
        h.beginEditing()
    }

    /// End a rename: `name` (nil = cancelled) becomes the section's name when it is new and not blank.
    func endRename(_ name: String?) {
        guard let si = renaming else { return }
        renaming = nil
        let trimmed = name.map { String(rustTrim($0)) } ?? ""
        if !trimmed.isEmpty, trimmed != link.state?.doc.sections.at(si)?.name {
            link.run("section.rename", ["index": .integer(si), "name": .string(trimmed)])
        } else {
            refresh()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            control.abortEditing()
            endRename(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard renaming != nil, let field = obj.object as? NSTextField else { return }
        endRename(field.stringValue)
    }

    func menu(slide i: Int) -> NSMenu { SlideMenus.slideMenu(link, i) }

    func menu(section si: Int) -> NSMenu {
        SlideMenus.sectionMenu(link, si, link.state?.doc.sections.at(si)?.name ?? "") { [weak self] in self?.beginRename(si) }
    }

    /// ⌘-scroll and pinch: the sorter's zoom.
    func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        let r = StatusLogic.sorterZoomRange
        link.model.ui.sorterZoom = min(max(link.model.ui.sorterZoom * Double(factor), r.lowerBound), r.upperBound)
        link.model.changed()
    }

    func key(_ e: NSEvent) -> Bool {
        guard let st = link.state else { return false }
        let n = st.doc.slides.count, cur = st.selection.slide
        let cols = max(1, Int((collection.bounds.width - 2 * Tokens.Space.l) / max(1, cellSize().width)))
        func go(_ i: Int) {
            guard i >= 0, i < n else { return }
            if e.modifierFlags.contains(.shift) { link.run("slide.selectRange", ["to": .integer(i), "add": true]) } else { link.run("slide.go", ["index": .integer(i)]) }
            if let ip = indexPath(of: i) { collection.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge) }
        }
        switch e.keyCode {
        case 124: go(cur + 1); return true
        case 123: go(cur - 1); return true
        case 125: go(min(cur + cols, n - 1)); return true
        case 126: go(max(cur - cols, 0)); return true
        case 51, 117: link.run("slide.delete"); return true
        case 36, 76: open(slide: cur); return true
        default: return false
        }
    }

    func indexPath(of slide: Int) -> IndexPath? {
        for (g, grp) in groups.enumerated() {
            if let k = grp.slides.firstIndex(of: slide) { return IndexPath(item: k, section: g) }
        }
        return nil
    }

    // MARK: Drops

    /// The slide gap a drop before `ip` lands in (0…count).
    func slideSlot(_ ip: IndexPath) -> Int {
        guard let grp = groups.at(ip.section) else { return link.state?.doc.slides.count ?? 0 }
        if let i = grp.slides.at(ip.item) { return i }
        if let last = grp.slides.last { return last + 1 }
        for later in groups.dropFirst(ip.section + 1) { if let f = later.slides.first { return f } }
        return link.state?.doc.slides.count ?? 0
    }

    /// The section gap (`drop_slot`) for a point in the collection view: before the first bar whose
    /// centre is below it.
    func sectionSlot(_ p: NSPoint) -> Int {
        var centers: [Double] = []
        for (g, grp) in groups.enumerated() where grp.section != nil {
            if let a = collection.collectionViewLayout?.layoutAttributesForSupplementaryView(ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: g)) {
                centers.append(Double(a.frame.midY))
            }
        }
        // The collection view is flipped: y grows downwards, as egui's does.
        return SorterLogic.dropSlot(centers, Double(p.y))
    }

    private func dragged(_ info: any NSDraggingInfo, _ type: NSPasteboard.PasteboardType) -> Int? {
        guard let s = info.draggingPasteboard.string(forType: type) else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, UInt64(parts[0]) == link.uid, let i = Int(parts[1]) else { return nil }
        return i
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo, proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if let from = dragged(info, .deckCraftSectionRow) {
            let p = collection.convert(info.draggingLocation, from: nil)
            return SorterLogic.moveDest(from, sectionSlot(p)) == nil ? [] : .move
        }
        guard let from = dragged(info, .deckCraftSlideRow) else { return [] }
        op.pointee = .before
        return SorterLogic.moveDest(from, slideSlot(ip.pointee as IndexPath)) == nil ? [] : .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo, indexPath ip: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        if let from = dragged(info, .deckCraftSectionRow) {
            let p = collection.convert(info.draggingLocation, from: nil)
            guard let to = SorterLogic.moveDest(from, sectionSlot(p)) else { return false }
            return (try? link.run("section.move", ["index": .integer(from), "to": .integer(to)]).get()) != nil
        }
        guard let from = dragged(info, .deckCraftSlideRow), let to = SorterLogic.moveDest(from, slideSlot(ip)) else { return false }
        return (try? link.run("slide.move", ["from": .integer(from), "to": .integer(to)]).get()) != nil
    }

    /// The pasteboard item that drags slide `i` or section `si`.
    func dragItem(slide i: Int?, section si: Int?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let i { item.setString("\(link.uid):\(i)", forType: .deckCraftSlideRow) }
        if let si { item.setString("\(link.uid):\(si)", forType: .deckCraftSectionRow) }
        return item
    }
}

/// The sorter's collection view: clicks select through the engine, a drag past a few points starts a
/// reorder, and ⌘-scroll or a pinch zooms.
@MainActor
final class SorterCollectionView: NSCollectionView {
    weak var controller: SorterViewController?
    private var press: (point: NSPoint, slide: Int, ip: IndexPath)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        press = nil
        guard let c = controller, let ip = indexPathForItem(at: p), let i = c.slide(at: ip) else { return }
        if event.clickCount == 2 {
            c.open(slide: i)
            return
        }
        c.click(slide: i, shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command))
        press = (p, i, ip)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pr = press, let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - pr.point.x, p.y - pr.point.y) > 4 else { return }
        press = nil
        let dragItem = NSDraggingItem(pasteboardWriter: c.dragItem(slide: pr.slide, section: nil))
        if let v = item(at: pr.ip)?.view {
            let frame = v.frame
            dragItem.setDraggingFrame(frame, contents: v.bitmapImageRepForCachingDisplay(in: v.bounds).flatMap { rep -> NSImage? in
                v.cacheDisplay(in: v.bounds, to: rep)
                let img = NSImage(size: v.bounds.size)
                img.addRepresentation(rep)
                return img
            })
        }
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { press = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = controller, let ip = indexPathForItem(at: p), let i = c.slide(at: ip) else { return nil }
        return c.menu(slide: i)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.key(event) == true { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            controller?.zoom(by: 1 + event.scrollingDeltaY * 0.01)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) { controller?.zoom(by: 1 + event.magnification) }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// A sorter cell: the thumbnail with its frame or selection ring, the number under it and the slide's
/// transition.
@MainActor
final class SorterItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("sorterItem")
    let cell = SorterCell()
    override func loadView() { view = cell }
}

@MainActor
final class SorterCell: NSView {
    struct Content: Equatable {
        var number: String
        var image: CGImage?
        var imageSize: CGSize
        var selected: Bool
        var hidden: Bool
        var transition: String?
        var label: String
    }

    private(set) var content: Content?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
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

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = CGRect(x: SorterMetrics.side, y: SorterMetrics.top, width: c.imageSize.width, height: c.imageSize.height)
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
            let frame = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            frame.lineWidth = Tokens.Layout.hairline
            NSColor.separatorColor.setStroke()
            frame.stroke()
        }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let y = r.maxY + Tokens.Space.xs
        NSAttributedString(string: c.number, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: c.hidden ? NSUnderlineStyle.single.rawValue : 0,
        ]).draw(at: CGPoint(x: r.minX, y: y))
        if let t = c.transition {
            let s = NSAttributedString(string: "★ \(t)", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            s.draw(at: CGPoint(x: r.maxX - s.size().width, y: y))
        }
    }
}

/// A section's bar in the sorter: fold chevron, name (double-click renames), count, the section menu;
/// dragging it moves the whole section.
@MainActor
final class SorterHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("sorterHeader")
    weak var controller: SorterViewController?
    var section = 0
    let chevron = NSButton()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    private var downAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.control
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(fold)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        for v in [chevron, name, count] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.Space.l),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Tokens.Space.xl),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: Tokens.Space.s),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: Tokens.Layout.sidebarWidth / 2),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Tokens.Space.s),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.Space.xl),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() { layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor }

    func configure(name text: String, count n: Int, folded: Bool, foldable: Bool, renaming: Bool) {
        if !(renaming && name.currentEditor() != nil) {
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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    func beginEditing() {
        name.isEditable = true
        name.isBezeled = true
        name.drawsBackground = true
        window?.makeFirstResponder(name)
        name.currentEditor()?.selectAll(nil)
    }

    @objc private func fold() { controller?.toggleFold(section: section) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            downAt = nil
            controller?.beginRename(section)
            return
        }
        downAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - d.x, p.y - d.y) > 4 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: c.dragItem(slide: nil, section: section))
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        item.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [item], event: event, source: c.collection)
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(section: section) }
}
