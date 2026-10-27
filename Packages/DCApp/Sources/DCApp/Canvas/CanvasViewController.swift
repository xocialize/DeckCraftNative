// DCApp — the canvas's place in the document window: a scroll view around the canvas (native scroll bars,
// elastic scrolling), the rulers along its top and left when View › Ruler is on, and a slot over the slide
// for the Show area's animation preview. Behaviour from deckcraft `crates/ui-egui/src/canvas.rs` (`show`:
// scrolling when zoomed, the rulers' strips) (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import AppKit
import DCAppModel
import DCEngine

@MainActor
final class CanvasViewController: NSViewController {
    weak var document: PresentationDocument?
    let canvas = CanvasView()
    let scroll = CanvasScrollView()
    let rulers = CanvasRulerView()
    /// A view over the canvas, sized to it, that never takes the pointer: the Show area draws the animation
    /// preview here (`showOverlay`); `slideRectInOverlay` and `scale` say where the slide is.
    let showOverlay = CanvasPassThroughView()

    init(document: PresentationDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        canvas.document = document
        rulers.canvas = canvas
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = CanvasContainerView()
        root.controller = self
        scroll.canvas = canvas
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CanvasStyle.surround
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.allowsMagnification = false
        root.addSubview(scroll)
        root.addSubview(rulers)
        showOverlay.isHidden = true
        root.addSubview(showOverlay)
        view = root
        canvas.onLayout = { [weak self] in self?.layoutChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        CanvasFeature.register(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.firstResponder === view.window { view.window?.makeFirstResponder(canvas) }
        refresh()
    }

    /// Lay the scroll view and rulers out: the rulers take 16-point strips when shown, below the toolbar
    /// (the window's content runs under it; the canvas scrolls under it, the rulers mustn't).
    func place() {
        let b = view.bounds
        let r = AppController.shared?.model.ui.ruler == true ? CanvasStyle.ruler : 0
        let top = r > 0 ? view.safeAreaInsets.top : 0
        let frame = CGRect(x: r, y: top + r, width: max(b.width - r, 0), height: max(b.height - r - top, 0))
        if scroll.frame != frame { scroll.frame = frame }
        rulers.frame = CGRect(x: 0, y: top, width: b.width, height: max(b.height - top, 0))
        rulers.isHidden = r == 0
        showOverlay.frame = scroll.frame
        canvas.relayout()
    }

    /// The session changed: relayout and redraw what changed.
    func refresh() {
        guard isViewLoaded else { return }
        place()
        canvas.refresh()
        rulers.needsDisplay = true
    }

    @objc private func scrolled() {
        rulers.needsDisplay = true
        layoutChanged()
    }

    private func layoutChanged() {
        rulers.needsDisplay = true
        NotificationCenter.default.post(name: .canvasLayoutChanged, object: self)
    }

    /// The slide's rect in `showOverlay`'s coordinates (y down), and points per slide point.
    var slideRectInOverlay: CGRect? {
        guard let r = canvas.layoutInfo?.slideRect else { return nil }
        let inRoot = canvas.convert(r, to: view)
        return showOverlay.convert(inRoot, from: view)
    }

    var scale: Double { canvas.layoutInfo?.scale ?? 1 }

    /// A slide colour as AppKit's.
    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

extension Notification.Name {
    /// Posted by a `CanvasViewController` when its slide moved (zoom, scroll, resize): overlays follow.
    static let canvasLayoutChanged = Notification.Name("DeckCraftCanvasLayoutChanged")
}

/// The canvas controller's root view: it lays its children out when resized.
@MainActor
final class CanvasContainerView: NSView {
    weak var controller: CanvasViewController?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        controller?.place()
    }
}

/// A flipped view that lets the pointer through.
@MainActor
final class CanvasPassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
