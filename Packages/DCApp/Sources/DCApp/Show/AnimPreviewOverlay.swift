// DCApp — the canvas animation preview (Animations ▸ Preview, `animation.preview`): the current slide's effects
// played over the editor's slide, then the slide at rest again. deckcraft draws it in its canvas raster
// (`anim_preview_draw`); here it draws in the canvas's overlay slot (`CanvasFeature.previewOverlay`), laid
// exactly over the slide, which takes no clicks. Esc stops it, as on deckcraft's canvas.
import AppKit
import DCAppModel
import DCModel
import DCRender

@MainActor
final class AnimPreviewOverlay {
    let coord: ShowCoordinator
    private var view: AnimPreviewView?
    private var keyMonitor: Any?
    private var layoutObserver: (any NSObjectProtocol)?

    init(coord: ShowCoordinator) {
        self.coord = coord
    }

    /// Open or close the overlay to match the coordinator's preview.
    func sync() {
        if coord.animPreview != nil { open() } else { close() }
    }

    private func open() {
        guard view == nil, let slot = CanvasFeature.previewOverlay(in: Self.documentWindow()) else { return }
        let v = AnimPreviewView(overlay: self)
        slot.view.addSubview(v)
        slot.view.isHidden = false
        view = v
        place()
        v.start()
        layoutObserver = NotificationCenter.default.addObserver(forName: .canvasLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let self else { return e }
            self.coord.stopAnimPreview()
            return nil
        }
    }

    func close() {
        view?.stop()
        if let v = view {
            v.superview?.isHidden = true
            v.removeFromSuperview()
        }
        view = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = layoutObserver { NotificationCenter.default.removeObserver(o) }
        layoutObserver = nil
    }

    /// The key document window.
    static func documentWindow() -> NSWindow? {
        NSApp.keyWindow.flatMap { $0.windowController?.document is PresentationDocument ? $0 : nil }
            ?? NSApp.orderedWindows.first { $0.windowController?.document is PresentationDocument }
    }

    /// Lay the preview exactly over the canvas's slide, in the canvas's overlay slot (it scrolls and zooms
    /// with the slide and never takes the pointer).
    func place() {
        guard let v = view, let slot = CanvasFeature.previewOverlay(in: v.window ?? Self.documentWindow()) else { return }
        if v.frame != slot.slideRect { v.frame = slot.slideRect }
    }
}

@MainActor
final class AnimPreviewView: NSView {
    weak var overlay: AnimPreviewOverlay?
    private var link: CADisplayLink?

    init(overlay: AnimPreviewOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        frame()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) { frame() }

    /// One preview frame: the slide with every shape at its state on the play-everything clock.
    private func frame() {
        guard let o = overlay else { return }
        guard o.coord.tickAnimPreview(ShowCoordinator.now()), let p = o.coord.animPreview,
              let d = o.coord.model.session.documents.first(where: { $0.uid == p.uid }) else {
            o.coord.stopAnimPreview()
            return
        }
        o.place()
        let scale = Double(window?.backingScaleFactor ?? 2)
        let w = Swift.max(Int((bounds.width * scale).rounded()), 1), h = Swift.max(Int((bounds.height * scale).rounded()), 1)
        var opts = RenderOpts(scale: Double(w) / Swift.max(d.doc.slideSize.width, 1))
        opts.size = (w, h)
        opts.edit = true
        let tl = p.timeline, time = p.elapsed
        opts.state = { ShowCoordinator.previewState(tl, $0, time) }
        layer?.contents = renderSlide(d.doc, p.slide, opts).cgImage()
    }
}
