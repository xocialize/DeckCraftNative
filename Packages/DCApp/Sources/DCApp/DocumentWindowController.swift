// DCApp — one presentation's window (PLAN.md "Decided", amended 2026-10-27: a Keynote-like layout by default, the
// ribbon an optional one): the slide navigator (or the outline) in the sidebar, the editing area, and the inspector,
// in a split view with a toolbar whose items run registry commands (the Inspector area's `ToolbarCatalog`). In the
// ribbon layout the Ribbon area adds the ribbon under the toolbar and swaps the toolbar (`RibbonFeature`). The editing
// area shows the view `UiState.view` asks for — Normal (the canvas over the notes pane), Outline (the
// outline in the sidebar), Slide Sorter, Notes Page — over the status bar. The window's layout follows
// deckcraft's `SlideApp::ui_inner` (`crates/ui-egui/src/lib.rs`, MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors); Reading View is the Show area's.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DesignScaffold
import SwiftUI

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let split = NSSplitViewController()
    let link: DocLink
    let canvas: CanvasViewController
    let navigator: NavigatorViewController
    let outline: OutlineViewController
    let sidebar: SidebarController
    let editor: EditorAreaController
    let inspector: NSHostingController<InspectorView>
    let sidebarItem: NSSplitViewItem
    private var observer: (any NSObjectProtocol)?
    weak var presentation: PresentationDocument?
    /// The sidebar's state before a view without it (Slide Sorter, Notes Page, the page masters) collapsed it.
    private var sidebarBefore: Bool?
    private var placedSidebar = false
    private var settingSidebar = false
    private var shownMode: SidebarMode?
    private var resizeObserver: (any NSObjectProtocol)?
    /// The ribbon and the toolbar it replaced, while the window is in the ribbon layout (`RibbonFeature`).
    var ribbon: RibbonAttachment?

    init(document: PresentationDocument) {
        presentation = document
        let link = DocLink(document: document)
        self.link = link
        canvas = CanvasViewController(document: document)
        navigator = NavigatorViewController(link: link)
        outline = OutlineViewController(link: link)
        sidebar = SidebarController()
        editor = EditorAreaController(link: link, canvas: canvas)
        inspector = NSHostingController(rootView: InspectorView(document: DocumentRef(document)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: Tokens.Layout.minWindowWidth, height: Tokens.Layout.minWindowHeight)
        // The saved frame is a preference: scripted runs (`DECKCRAFT_NO_PREFS`) start from the default size.
        if !AppDelegate.noPrefs { window.setFrameAutosaveName("DeckCraftDocument") }
        window.setContentSize(NSSize(width: max(window.frame.width, window.minSize.width), height: max(window.frame.height, window.minSize.height)))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        super.init(window: window)
        window.delegate = self

        // deckcraft's thumbnail pane is 150–420 points wide.
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let content = NSSplitViewItem(viewController: editor)
        // The editing area keeps what's left of the narrowest window beside the inspector and the outline.
        content.minimumThickness = Tokens.Layout.minWindowWidth - Tokens.Layout.inspectorWidth - Self.outlineWidth
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = Tokens.Layout.inspectorWidth * 0.75
        inspectorItem.maximumThickness = Tokens.Layout.inspectorMaxWidth
        split.splitViewItems = [sidebarItem, content, inspectorItem]
        window.contentViewController = split
        sidebar.show(navigator)

        let toolbar = NSToolbar(identifier: "DeckCraftDocument")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        observer = NotificationCenter.default.addObserver(forName: .deckCraftModelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarResized() }
        }
        refresh()
        RibbonFeature.apply(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the sidebar shows for the view and the selection's target.
    enum SidebarMode: Equatable { case navigator, outline, none }

    var sidebarMode: SidebarMode {
        let target = link.state?.selection.target ?? .slides
        if target.isPageMaster { return .none }
        switch link.model.ui.view {
        case .sorter, .notesPage: return .none
        case .outline: return target == .slides ? .outline : .navigator
        case .normal, .reading: return .navigator
        }
    }

    func refresh() {
        guard link.state != nil else { return }
        let mode = sidebarMode
        switch mode {
        case .navigator: sidebar.show(navigator)
        case .outline: sidebar.show(outline)
        case .none: break
        }
        // Before the window is on screen the split view would undo a collapse; it is applied when the
        // window becomes key.
        if mode == .none, window?.isVisible == true {
            if sidebarBefore == nil {
                sidebarBefore = sidebarItem.isCollapsed
                sidebarItem.isCollapsed = true
            }
        } else if let before = sidebarBefore {
            sidebarItem.isCollapsed = before
            sidebarBefore = nil
        }
        if !placedSidebar, let w = window, w.contentView?.bounds.width ?? 0 > 0 {
            placedSidebar = true
            setSidebarWidth(CGFloat(link.model.ui.thumbsWidth))
        }
        if mode != shownMode {
            // The outline wants room for its text (deckcraft's outline pane is 360 points); the navigator
            // goes back to its own width.
            if mode == .outline, !sidebarItem.isCollapsed, sidebar.view.frame.width < Self.outlineWidth {
                setSidebarWidth(Self.outlineWidth)
            } else if mode == .navigator, shownMode != nil, !sidebarItem.isCollapsed {
                setSidebarWidth(CGFloat(link.model.ui.thumbsWidth))
            }
            shownMode = mode
        }
        if !sidebarItem.isCollapsed {
            if mode == .outline { outline.refresh() } else { navigator.refresh() }
        }
        editor.refresh()
    }

    /// The outline's width in the sidebar.
    static let outlineWidth: CGFloat = 360

    private func setSidebarWidth(_ w: CGFloat) {
        settingSidebar = true
        split.splitView.setPosition(min(max(w, sidebarItem.minimumThickness), sidebarItem.maximumThickness), ofDividerAt: 0)
        settingSidebar = false
    }

    /// The navigator's width is remembered (`thumbsWidth`) when the user drags the divider.
    private func sidebarResized() {
        guard !settingSidebar, shownMode == .navigator, !sidebarItem.isCollapsed, NSEvent.pressedMouseButtons != 0 else { return }
        link.model.ui.thumbsWidth = Double(sidebar.view.frame.width)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let uid = presentation?.uid { AppController.shared?.activate(uid: uid) }
        refresh()
    }

    // MARK: Toolbar (the items are the Inspector area's `ToolbarCatalog`)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ToolbarCatalog.defaultItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ToolbarCatalog.allowedItems }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        ToolbarCatalog.item(id, document: presentation)
    }
}

/// The sidebar: the navigator or the outline.
@MainActor
final class SidebarController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ vc: NSViewController) {
        guard current !== vc else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        current = vc
    }
}

/// The editing area: the canvas over the notes pane (Normal and Outline), the Slide Sorter or Notes Page,
/// with the status bar under them.
@MainActor
final class EditorAreaController: NSViewController, NSSplitViewDelegate {
    let link: DocLink
    let canvas: CanvasViewController
    let notes: NotesPaneController
    let canvasNotes = NSSplitView()
    private(set) lazy var sorter = SorterViewController(link: link)
    private(set) lazy var notesPage = NotesPageViewController(link: link)
    let content = NSView()
    private var status: NSHostingView<StatusBarView>?
    private(set) var shown: ViewMode?
    private var placingNotes = false
    private var placedNotes = false

    /// The notes pane's height range (`notes_pane`: 36–400 points).
    static let notesRange: ClosedRange<CGFloat> = 36 ... 400

    init(link: DocLink, canvas: CanvasViewController) {
        self.link = link
        self.canvas = canvas
        notes = NotesPaneController(link: link)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        canvasNotes.isVertical = false
        canvasNotes.dividerStyle = .thin
        canvasNotes.delegate = self
        addChild(canvas)
        addChild(notes)
        canvasNotes.addArrangedSubview(canvas.view)
        canvasNotes.addArrangedSubview(notes.view)
        canvasNotes.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        canvasNotes.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        let bar = NSHostingView(rootView: StatusBarView(link: link, spelling: SpellingState()))
        status = bar
        // The status bar never holds the editing area wide: what doesn't fit is clipped.
        bar.sizingOptions = [.intrinsicContentSize]
        bar.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let line = NSBox()
        line.boxType = .separator
        for v in [content, line, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: content.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: line.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Tokens.Layout.controlHeight + Tokens.Space.xs),
        ])
        view = root
    }

    /// The view in the editing area for `UiState.view`.
    static func area(_ v: ViewMode) -> ViewMode {
        switch v {
        case .sorter: .sorter
        case .notesPage: .notesPage
        case .normal, .outline, .reading: .normal
        }
    }

    private func install(_ v: NSView) {
        for s in content.subviews where s !== v { s.removeFromSuperview() }
        guard v.superview !== content else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    func refresh() {
        guard isViewLoaded else { return }
        let model = link.model
        let area = Self.area(model.ui.view)
        if area != shown {
            // The notes being typed are saved before the pane goes away.
            if shown == .normal { notes.editor.save() }
            if shown == .notesPage { notesPage.editor.save() }
            shown = area
            switch area {
            case .sorter:
                if !children.contains(sorter) { addChild(sorter) }
                install(sorter.view)
            case .notesPage:
                if !children.contains(notesPage) { addChild(notesPage) }
                install(notesPage.view)
            default:
                install(canvasNotes)
            }
        }
        switch area {
        case .sorter: sorter.refresh()
        case .notesPage: notesPage.refresh()
        default:
            canvas.refresh()
            let showNotes = model.ui.notes && link.state?.selection.target == .slides
            if notes.view.isHidden == showNotes {
                notes.view.isHidden = !showNotes
                canvasNotes.adjustSubviews()
                placedNotes = false
            }
            if showNotes {
                notes.refresh()
                placeNotes()
            }
        }
    }

    /// The notes pane at its remembered height.
    private func placeNotes() {
        guard !placedNotes, canvasNotes.bounds.height > 0 else { return }
        placedNotes = true
        let h = min(max(CGFloat(link.model.ui.notesHeight), Self.notesRange.lowerBound), Self.notesRange.upperBound)
        placingNotes = true
        canvasNotes.setPosition(max(0, canvasNotes.bounds.height - h - canvasNotes.dividerThickness), ofDividerAt: 0)
        placingNotes = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if shown == .normal, !notes.view.isHidden { placeNotes() }
    }

    // MARK: Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, splitView.bounds.height - Self.notesRange.upperBound - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - Self.notesRange.lowerBound - splitView.dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !placingNotes, placedNotes, !notes.view.isHidden, NSEvent.pressedMouseButtons != 0 else { return }
        link.model.ui.notesHeight = Double(notes.view.frame.height)
    }
}

/// A weak, observable handle on a document for SwiftUI views.
@MainActor @Observable
final class DocumentRef {
    weak var document: PresentationDocument?
    init(_ d: PresentationDocument) { document = d }
}
