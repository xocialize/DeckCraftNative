// DCApp — View › New Window: one more window on the same presentation. Port of deckcraft
// `crates/ui-egui/src/doc_window.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
// The window shows that presentation live, on its own slide, without moving the editor's selection; it
// doesn't edit. `{on: false}` closes it, `{slide}` and `{delta}` move only it; closing the presentation
// closes it, and closing it leaves the presentation open.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DCRender
import DesignScaffold

@MainActor
final class DocViewerWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    private(set) var state: DocWindowState
    let titleLabel = NSTextField(labelWithString: "")
    let counter = NSTextField(labelWithString: "")
    let previous = NSButton(title: "Previous", target: nil, action: nil)
    let next = NSButton(title: "Next", target: nil, action: nil)
    let slideView = SlideImageView()
    var onClose: (() -> Void)?

    init(model: AppModel, state: DocWindowState) {
        self.model = model
        self.state = state
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        counter.textColor = .secondaryLabelColor
        previous.target = self
        previous.action = #selector(goPrevious)
        next.target = self
        next.action = #selector(goNext)
        let bar = NSStackView(views: [titleLabel, counter, NSView(), previous, next])
        bar.orientation = .horizontal
        bar.spacing = Tokens.Space.l
        bar.edgeInsets = NSEdgeInsets(top: Tokens.Space.s, left: Tokens.Space.m, bottom: Tokens.Space.s, right: Tokens.Space.m)
        let root = NSView()
        for v in [bar, slideView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            slideView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            slideView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            slideView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            slideView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        window.center()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var docState: DocState? { model.session.documents.first { $0.uid == state.uid } }

    /// Move to `s` (the command's answer gave it).
    func update(_ s: DocWindowState) {
        state = s
        refresh()
    }

    /// Follow the presentation; close when it is gone or has no slides.
    func refresh() {
        guard let st = docState, !st.doc.slides.isEmpty else {
            close()
            return
        }
        let n = st.doc.slides.count
        state.slide = min(state.slide, n - 1)
        let title = DocWindowLogic.title(st.displayTitle)
        window?.title = title
        titleLabel.stringValue = title
        counter.stringValue = "Slide \(state.slide + 1) of \(n)"
        previous.isEnabled = state.slide > 0
        next.isEnabled = state.slide + 1 < n
        slideView.show(st.doc, state.slide)
    }

    @objc private func goPrevious() { model.run("view.newWindow", ["delta": -1]) }
    @objc private func goNext() { model.run("view.newWindow", ["delta": 1]) }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// A slide drawn to fit the view (the extra window's, and the show's look without its machinery).
@MainActor
final class SlideImageView: NSView {
    private var cache: (slide: Slide, master: Master?, pixels: CGSize, image: CGImage)?
    private var doc: Presentation?
    private var index = 0
    override var isFlipped: Bool { true }

    func show(_ doc: Presentation, _ index: Int) {
        self.doc = doc
        self.index = index
        needsDisplay = true
    }

    /// The slide's box in the view.
    func slideRect() -> CGRect? {
        guard let doc else { return nil }
        let avail = bounds.insetBy(dx: Tokens.Space.l, dy: Tokens.Space.l)
        guard avail.width > 1, avail.height > 1 else { return nil }
        let aspect = CGFloat(slideAspect(doc))
        var w = avail.width, h = w * aspect
        if h > avail.height {
            h = avail.height
            w = h / aspect
        }
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let doc, let slide = doc.slides.at(index), let r = slideRect(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
        let master = doc.masterFor(slide)?.master
        let image: CGImage
        if let c = cache, c.slide == slide, c.master == master, c.pixels == pixels {
            image = c.image
        } else {
            var o = RenderOpts(scale: Double(pixels.width) / max(1, doc.slideSize.width))
            o.edit = true
            guard let img = renderSlide(doc, index, o).cgImage() else { return }
            cache = (slide, master, pixels, img)
            image = img
        }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}
