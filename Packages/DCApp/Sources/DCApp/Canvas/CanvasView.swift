// DCApp — the editing canvas: the document view of the canvas's scroll view. It draws the current slide
// (or master, layout, handout or notes master) through DCRender, takes the pointer, keys and text input for
// the engine, and holds the overlays (selection, handles, guides, caret) in a layer of their own so a
// selection change never redraws the slide. Behaviour from deckcraft `crates/ui-egui/src/canvas.rs` (`show`,
// `pointer`, `context_menu`), `eyedropper.rs` and the input parts of `lib.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
//
// Drawing (measured on the sample deck, debug build): recording a slide (`recordSlide`) costs about what
// rasterising it does (10–130 ms), and replaying the recording into CoreGraphics costs about 1 ms. So the
// canvas records each slide once and replays it at whatever zoom and scroll, sharp at every zoom. A slide
// whose recording needs raster layers (a blur, a blend onto the backdrop: one sample slide took 4.7 s to
// replay) is rasterised once per zoom instead, as are masters and layouts (DCRender has no recorder for
// them).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import UniformTypeIdentifiers

@MainActor
final class CanvasView: NSView {
    weak var document: PresentationDocument?
    let overlay = CanvasOverlayView()
    /// The system's insertion point while text is edited (blinking, dictation's glyph).
    let caret = NSTextInsertionIndicator(frame: .zero)
    let squiggles = CanvasSquiggles()
    /// Where the slide is: set by `relayout`.
    private(set) var layoutInfo: CanvasLayout?
    /// The Eyedropper, while it waits for a click.
    var eyedropper: CanvasEyedropper?
    /// Where the pointer is over the canvas (for the Eyedropper's loupe).
    var pointerAt: CGPoint?
    /// Called after every relayout (the rulers and the Show area's overlay follow the slide).
    var onLayout: (() -> Void)?

    private var twisting = false
    private var wheelCarry = CanvasMetrics.WheelCarry()
    private var flickDone = false
    private var flickSum = (0.0, 0.0)
    private var lastFlick = Date.distantPast
    /// The viewport point a zoom keeps still (pinch, ⌘-scroll); nil for the middle of the view.
    private var zoomAnchor: CGPoint?
    private var eyedropperMonitor: Any?
    private var tracking: NSTrackingArea?
    private var picture: Picture?
    /// How many times the slide's picture was made (recorded or rasterised): an unchanged slide isn't again.
    private(set) var pictureCount = 0

    var model: AppModel? { AppController.shared?.model }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click on the canvas of a window in the background acts at once, as in drawing apps.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        caret.isHidden = true
        caret.displayMode = .automatic
        addSubview(caret)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: State

    /// This canvas's presentation, when it is the session's active one: only then does input go to it.
    var activeState: DocState? {
        guard let st = document?.state, let s = model?.session, s.activeDoc?.uid == st.uid else { return nil }
        return st
    }

    /// Make this canvas's presentation the active one (a click in a window that isn't key yet).
    func activate() {
        guard let uid = document?.uid else { return }
        AppController.shared?.activate(uid: uid)
    }

    // MARK: Layout

    /// Fit the document view to the viewport and zoom, keeping the zoom's anchor point still (#106).
    func relayout() {
        guard let scroll = enclosingScrollView, let st = document?.state, let model, let (viewport, scrolled, ins) = viewportInfo() else { return }
        let clip = scroll.contentView
        let old = layoutInfo
        var shown = viewport
        var new = CanvasLayout.make(slide: pageSize(st), viewport: shown, zoom: model.ui.zoom)
        // The document's new size can bring the scroll bars in or take them away. Legacy scroll bars (macOS shows
        // them while a mouse is attached) take room from the viewport, so lay out again for the room that is
        // left; twice at most, as their showing can flip back once.
        for _ in 0 ..< 2 {
            layoutInfo = new
            if frame.size != new.documentSize { setFrameSize(new.documentSize) }
            // Auto-hiding scroll bars are shown or hidden here, then tiling gives the clip view what is left.
            scroll.reflectScrolledClipView(clip)
            scroll.tile()
            guard let now = viewportInfo()?.size, now != shown else { break }
            shown = now
            new = CanvasLayout.make(slide: pageSize(st), viewport: shown, zoom: model.ui.zoom)
        }
        layoutInfo = new
        if frame.size != new.documentSize { setFrameSize(new.documentSize) }
        if let old, abs(old.scale - new.scale) > 1e-9 {
            // What was at the pointer stays under it; what was in the middle of the view goes to the middle of the
            // view as it is now, which scroll bars that came in have made smaller.
            let shownNow = viewportInfo()?.size ?? shown
            let anchor = zoomAnchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            let target = zoomAnchor ?? CGPoint(x: shownNow.width / 2, y: shownNow.height / 2)
            let o = new.anchoredScroll(from: old, scroll: scrolled, anchor: anchor, target: target, viewport: shownNow)
            clip.scroll(to: CGPoint(x: o.x - ins.left, y: o.y - ins.top))
            scroll.reflectScrolledClipView(clip)
        }
        zoomAnchor = nil
        if model.canvasScale != new.scale { model.canvasScale = new.scale }
        if old != new {
            needsDisplay = true
            overlay.needsDisplay = true
        }
        onLayout?()
    }

    /// The part of the scroll view the canvas shows (inside the insets the toolbar takes), how far it is
    /// scrolled, and the insets.
    func viewportInfo() -> (size: CGSize, scrolled: CGPoint, insets: NSEdgeInsets)? {
        guard let clip = enclosingScrollView?.contentView else { return nil }
        let ins = clip.contentInsets
        let size = CGSize(width: max(clip.bounds.width - ins.left - ins.right, 0), height: max(clip.bounds.height - ins.top - ins.bottom, 0))
        return (size, CGPoint(x: clip.bounds.minX + ins.left, y: clip.bounds.minY + ins.top), ins)
    }

    /// Redraw after a change in the session: the slide only when what it draws changed.
    func refresh() {
        relayout()
        if let st = document?.state, !pictureIsCurrent(st) { needsDisplay = true }
        overlay.needsDisplay = true
        updateCaret()
        syncInputContext()
    }

    /// Set while the text system is calling in (`insertText`, `setMarkedText`…).
    var inTextInput = false
    private var hadComposition = false

    /// Keep the input method in step with the engine: when the app settled a composition itself (a click, a
    /// key, a command) the input method drops its marked text too, and the candidate window follows the caret.
    private func syncInputContext() {
        let st = activeState
        let composing = st?.composition != nil
        if hadComposition && !composing && !inTextInput { inputContext?.discardMarkedText() }
        hadComposition = composing
        if st?.selection.text != nil && !inTextInput { inputContext?.invalidateCharacterCoordinates() }
    }

    /// The slide-to-view mapping.
    var xf: CanvasXf? { layoutInfo?.xf }

    /// The slide's box in this view's coordinates and view points per slide point (the skeleton's API, which
    /// the Show area's preview overlay reads).
    func slideFrame() -> (rect: CGRect, scale: Double)? {
        layoutInfo.map { ($0.slideRect, $0.scale) }
    }

    // MARK: Drawing the slide

    struct PictureKey: Equatable {
        var doc: DocRef
        var target: Target
        var slide: Int
        var editing: ShapeId?
        /// Pixels per slide point for a raster picture; nil for a recording.
        var raster: Double?

        static func == (a: PictureKey, b: PictureKey) -> Bool {
            a.doc === b.doc && a.target == b.target && a.slide == b.slide && a.editing == b.editing && a.raster == b.raster
        }
    }

    enum Content {
        case vector(DisplayList)
        /// An image covering `rect` (slide points).
        case raster(CGImage, Rect)
        case none
    }

    struct Picture {
        var key: PictureKey
        var content: Content
    }

    /// The text being typed into on the canvas (the renderer shows its empty list paragraphs' markers).
    private func typingInto(_ st: DocState) -> ShapeId? {
        st.selection.text.flatMap { $0.notes ? nil : $0.shape }
    }

    /// Whether the picture drawn now still shows `st` as it is.
    private func pictureIsCurrent(_ st: DocState) -> Bool {
        guard let k = picture?.key else { return false }
        return k.doc === st.docRef && k.target == st.selection.target && k.slide == st.selection.slide && k.editing == typingInto(st)
    }

    private var rasterScale: Double { (layoutInfo?.scale ?? 1) * (window?.backingScaleFactor ?? 2) }

    /// The slide's picture, made when what it draws changed.
    private func currentPicture(_ st: DocState) -> Picture {
        var key = PictureKey(doc: st.docRef, target: st.selection.target, slide: st.selection.slide, editing: typingInto(st), raster: nil)
        if let p = picture, p.key.doc === key.doc, p.key.target == key.target, p.key.slide == key.slide, p.key.editing == key.editing {
            if p.key.raster == nil || p.key.raster == rasterScale { return p }
        }
        pictureCount += 1
        var opts = RenderOpts(scale: 1)
        opts.edit = true
        opts.editingText = key.editing
        if st.selection.target == .slides {
            if let list = recordSlide(st.doc, st.selection.slide, nil, opts), !list.hasRaster {
                let p = Picture(key: key, content: .vector(list))
                picture = p
                return p
            }
        }
        key.raster = rasterScale
        let p = Picture(key: key, content: raster(st, scale: rasterScale, editing: key.editing))
        picture = p
        return p
    }

    /// The page rasterised at `scale` pixels per point over everything it draws (off-slide objects too),
    /// within the renderer's size limit.
    private func raster(_ st: DocState, scale: Double, editing: ShapeId?) -> Content {
        let doc = st.doc
        let extent: Rect
        switch st.selection.target {
        case .slides: extent = Extent.slideExtent(doc, st.selection.slide)
        case .master(let m): extent = Extent.layoutExtent(doc, m, nil)
        case .layout(let m, let l): extent = Extent.layoutExtent(doc, m, l)
        case .handout, .notesMaster: extent = Rect(0, 0, pageSize(st).width, pageSize(st).height)
        }
        guard extent.isFinite, extent.width > 0, extent.height > 0 else { return .none }
        let side = Double(maxRenderSide)
        let k = min(scale, side / extent.width, side / extent.height).rustMax(0.01)
        var opts = RenderOpts(scale: k)
        opts.edit = true
        opts.editingText = editing
        opts.offset = (-extent.x0 * k, -extent.y0 * k)
        opts.size = (Int(rustCast: (extent.width * k).rounded(.up)), Int(rustCast: (extent.height * k).rounded(.up)))
        let image: RenderImage
        switch st.selection.target {
        case .slides: image = renderSlide(doc, st.selection.slide, opts)
        case .master(let m): image = renderLayout(doc, m, nil, opts)
        case .layout(let m, let l): image = renderLayout(doc, m, l, opts)
        case .handout, .notesMaster:
            guard let page = masterPage(doc, st.selection.target) else { return .none }
            image = renderLayout(page, 0, nil, opts)
        }
        guard let cg = image.cgImage() else { return .none }
        return .raster(cg, extent)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let st = document?.state, let l = layoutInfo, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if st.doc.slides.isEmpty && st.selection.target == .slides { return }
        let slide = l.slideRect
        // The slide's shadow on the surround.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: CanvasStyle.shadowOffset), blur: CanvasStyle.shadowBlur, color: CanvasStyle.shadow.cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(slide)
        ctx.restoreGState()
        let pic = currentPicture(st)
        ctx.saveGState()
        ctx.translateBy(x: slide.minX, y: slide.minY)
        ctx.scaleBy(x: l.scale, y: l.scale)
        switch pic.content {
        case .vector(let list):
            let page = pageSize(st)
            list.draw(in: ctx, view: .identity, bounds: CGRect(x: 0, y: 0, width: page.width, height: page.height), rasterScale: rasterScale)
        case .raster(let img, let r):
            // The view is flipped; a CGImage draws bottom-up.
            ctx.translateBy(x: r.x0, y: r.y1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        case .none:
            break
        }
        ctx.restoreGState()
        pagePreviews(ctx, st, l)
        if model?.ui.grayscale == true {
            // View › Grayscale: the slide's saturation taken out.
            ctx.saveGState()
            ctx.setBlendMode(.saturation)
            ctx.setFillColor(NSColor.gray.cgColor)
            ctx.fill(bounds)
            ctx.restoreGState()
        }
    }

    /// The master pages' previews (`show`): the current slide in the Notes Master's slide-image placeholder,
    /// and where the slides go on a printed handout.
    private func pagePreviews(_ ctx: CGContext, _ st: DocState, _ l: CanvasLayout) {
        let doc = st.doc
        let xf = l.xf
        switch st.selection.target {
        case .notesMaster:
            guard let f = doc.notesMaster?.shapes.first(where: { $0.phType == .slideImage })?.xfrm, f.w > 1, f.h > 1,
                  !doc.slides.isEmpty else { return }
            let i = min(st.selection.slide, doc.slides.count - 1)
            let aspect = doc.slideSize.width / max(doc.slideSize.height, 1)
            let (w, h) = f.w / f.h > aspect ? (f.h * aspect, f.h) : (f.w, f.w / aspect)
            let r = Rect(f.x + (f.w - w) / 2, f.y + (f.h - h) / 2, f.x + (f.w + w) / 2, f.y + (f.h + h) / 2)
            let k = l.scale * (window?.backingScaleFactor ?? 2) * w / max(doc.slideSize.width, 1)
            guard k.isFinite, k > 0, let img = renderSlide(doc, i, RenderOpts(scale: k)).cgImage() else { return }
            let v = xf.toView(r)
            ctx.saveGState()
            ctx.translateBy(x: v.minX, y: v.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: v.size))
            ctx.restoreGState()
        case .handout:
            let (n, sz) = (doc.notesSize, doc.slideSize)
            let per = UInt8(clamping: model?.ui.handoutPerPage ?? 6)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.gray.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            for b in PDF.handoutBoxes(per, (n.width, n.height), sz.width / max(sz.height, 1)) { ctx.stroke(xf.toView(b)) }
            ctx.restoreGState()
        default:
            break
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Caret

    /// Put the system's insertion point on the caret line, in the colour of the text typed there (a black
    /// caret is lost on a dark slide). A slanted line (rotated text) is drawn by the overlay instead.
    func updateCaret() {
        guard let st = activeState, let t = st.selection.text, !t.notes, !t.isRange, let xf,
              window?.firstResponder === self, let (top, bottom) = TextCommands.caretLine(st, t) else {
            caret.isHidden = true
            return
        }
        let a = xf.toView(top), b = xf.toView(bottom)
        guard abs(a.x - b.x) < 0.5 else {
            caret.isHidden = true
            return
        }
        caret.color = TextCommands.caretColor(st, t).map { CanvasViewController.color($0.r, $0.g, $0.b, $0.a) } ?? CanvasStyle.caret
        caret.frame = CGRect(x: a.x - 1, y: min(a.y, b.y), width: 2, height: max(abs(b.y - a.y), 1))
        caret.isHidden = false
    }

    /// Whether the overlay draws the caret itself (a rotated caret line).
    var overlayDrawsCaret: Bool { caret.isHidden }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateCaret()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        caret.isHidden = true
        return ok
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func mods(_ e: NSEvent) -> Mods {
        let f = e.modifierFlags
        return CanvasKeys.mods(shift: f.contains(.shift), option: f.contains(.option), command: f.contains(.command), control: f.contains(.control))
    }

    /// A pointer event at `e` for the engine, in slide points.
    private func event(_ kind: PointerKind, _ e: NSEvent) -> PointerEvent? {
        guard let xf else { return nil }
        let p = xf.toSlide(convert(e.locationInWindow, from: nil))
        var ev = PointerEvent()
        ev.kind = kind
        ev.x = p.x
        ev.y = p.y
        ev.mods = mods(e)
        ev.tol = CanvasInput.tolerance(xf.scale)
        if e.type != .mouseMoved, e.subtype == .tabletPoint, e.pressure.isFinite { ev.pressure = min(max(e.pressure, 0), 1) }
        return ev
    }

    /// Send a press, drag or release to the active tool, and redraw.
    private func send(_ kind: PointerKind, _ e: NSEvent) {
        guard let model, activeState != nil, let ev = event(kind, e) else { return }
        model.input { s throws(EngineError) in try CanvasInput.pointer(s, ev) }
        updateCursor()
    }

    /// A hover: only the overlay and the cursor change, so the rest of the window isn't refreshed.
    private func hover(_ e: NSEvent) {
        pointerAt = convert(e.locationInWindow, from: nil)
        if eyedropper != nil {
            overlay.needsDisplay = true
            updateCursor()
            return
        }
        guard let s = model?.session, activeState != nil, !s.tool.dragging, let ev = event(.move, e) else { return }
        let before = (s.tool.hover, s.tool.guideHover, s.tool.sites, s.tool.glue, s.tool.pathPreview)
        _ = try? CanvasInput.pointer(s, ev)
        let after = (s.tool.hover, s.tool.guideHover, s.tool.sites, s.tool.glue, s.tool.pathPreview)
        if before.0 != after.0 || before.1 != after.1 || before.2 != after.2 || before.3 != after.3 || before.4 != after.4 {
            overlay.needsDisplay = true
        }
        updateCursor()
    }

    override func mouseMoved(with e: NSEvent) { hover(e) }

    override func mouseExited(with e: NSEvent) {
        pointerAt = nil
        if eyedropper != nil { overlay.needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func mouseDown(with e: NSEvent) {
        // Control-click is the Mac's right click.
        if e.modifierFlags.contains(.control) && eyedropper == nil {
            rightMouseDown(with: e)
            return
        }
        window?.makeFirstResponder(self)
        activate()
        guard let st = activeState, let model else { return }
        if eyedropper != nil {
            eyedropperClick(e)
            return
        }
        if st.doc.slides.isEmpty && st.selection.target == .slides {
            model.run("slide.new", ["layout": "title"])
            return
        }
        let kind: PointerKind = e.clickCount >= 3 ? .tripleClick : e.clickCount == 2 ? .doubleClick : .down
        send(kind, e)
    }

    override func mouseDragged(with e: NSEvent) {
        pointerAt = convert(e.locationInWindow, from: nil)
        guard eyedropper == nil else { return }
        send(.drag, e)
        autoscroll(with: e)
    }

    override func mouseUp(with e: NSEvent) {
        guard eyedropper == nil, model?.session.tool.dragging == true else { return }
        send(.up, e)
    }

    /// The context menu last opened, for the control channel (`ui.canvas.menu`).
    var lastMenu: NSMenu?

    override func rightMouseDown(with e: NSEvent) {
        guard let menu = menu(for: e) else { return }
        lastMenu = menu
        // A click the control channel made (it has no event number) mustn't open a menu: its tracking would hold
        // the main thread, and the channel with it. The menu waits in `lastMenu` for `ui.canvas.menu`.
        if e.eventNumber == 0 { return }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        if eyedropper != nil {
            endEyedropper()
            return nil
        }
        window?.makeFirstResponder(self)
        activate()
        guard let model, activeState != nil, let xf else { return nil }
        let s = model.session
        // Select what's under the pointer before the menu opens.
        if !s.tool.dragging { send(.contextClick, e) }
        guard let st = activeState else { return nil }
        let p = xf.toSlide(convert(e.locationInWindow, from: nil))
        squiggles.menuWord = squiggles.wordAt(st, p, CanvasInput.tolerance(xf.scale))
        // Right-clicking a vertex in Edit Points picks it for the point menu.
        if case .vertex(_, let path, let index)? = s.tool.hover { s.tool.editVertex = (path, index) }
        let entries = CanvasContextMenu.entries(s, word: squiggles.menuWord, guidesOn: model.ui.guides)
        return CanvasMenu.build(entries, model: model, squiggles: squiggles)
    }

    // MARK: Cursor

    func updateCursor() {
        guard let model else { return }
        if eyedropper != nil {
            let onSlide = pointerAt.map { layoutInfo?.slideRect.contains($0) ?? false } ?? false
            (onSlide ? NSCursor.crosshair : NSCursor.operationNotAllowed).set()
            return
        }
        if activeState == nil { return }
        Self.cursor(CanvasCursor.of(model.session)).set()
    }

    static func cursor(_ c: CanvasCursor) -> NSCursor {
        switch c {
        case .arrow: .arrow
        case .copy: .dragCopy
        case .crosshair: .crosshair
        case .iBeam: .iBeam
        case .move: .arrow
        case .rotate: .crosshair
        case .pointingHand: .pointingHand
        case .resizeColumn: .columnResize
        case .resizeRow: .rowResize
        case .resizeLeftRight: .columnResize(directions: .all)
        case .resizeUpDown: .rowResize(directions: .all)
        case .resize(let axis):
            switch axis {
            case .horizontal: .frameResize(position: .right, directions: .all)
            case .vertical: .frameResize(position: .top, directions: .all)
            case .nwse: .frameResize(position: .topLeft, directions: .all)
            case .nesw: .frameResize(position: .topRight, directions: .all)
            }
        }
    }

    // MARK: Zoom, scrolling and gestures

    /// Pinch to zoom about the pointer.
    override func magnify(with e: NSEvent) {
        guard let model, let l = layoutInfo else { return }
        let m = e.magnification.isFinite ? e.magnification : 0
        let z = (model.ui.zoom ?? l.scale) * (1 + m)
        zoom(to: z, at: e)
    }

    /// A two-finger double tap: fit, or 100 %.
    override func smartMagnify(with e: NSEvent) {
        guard let model else { return }
        if model.ui.zoom == nil {
            zoom(to: 1, at: e)
        } else {
            setAnchor(e)
            model.run("view.fit")
        }
    }

    /// A two-finger twist turns the selected shapes; the whole twist is one undo step.
    override func rotate(with e: NSEvent) {
        guard let model, activeState != nil else { return }
        let ended = e.phase == .ended || e.phase == .cancelled
        CanvasInput.twist(model, degrees: -Double(e.rotation), ended: ended, twisting: &twisting)
    }

    private func setAnchor(_ e: NSEvent) {
        guard let clip = enclosingScrollView?.contentView, let (_, scrolled, _) = viewportInfo() else { return }
        let p = clip.convert(e.locationInWindow, from: nil)
        zoomAnchor = CGPoint(x: p.x - scrolled.x, y: p.y - scrolled.y)
    }

    private func zoom(to z: Double, at e: NSEvent) {
        guard let model, z.isFinite else { return }
        setAnchor(e)
        model.ui.zoom = min(max(z, UiState.zoomRange.lowerBound), UiState.zoomRange.upperBound)
        model.changed()
    }

    /// The scroll wheel: ⌘ or Control zooms about the pointer; a zoomed slide scrolls; a fitted one turns the
    /// page, a notch per slide from a wheel and one slide per flick from a trackpad. Returns true when taken.
    func wheel(_ e: NSEvent) -> Bool {
        guard let model, let st = document?.state, let l = layoutInfo, let (viewport, _, _) = viewportInfo() else { return false }
        let f = e.modifierFlags
        if f.contains(.command) || f.contains(.control) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 100 : e.scrollingDeltaY / 10
            guard dy.isFinite, dy != 0 else { return true }
            zoom(to: (model.ui.zoom ?? l.scale) * exp(dy), at: e)
            return true
        }
        let over = l.overflow(viewport)
        if over.width > 0 || over.height > 0 { return false }
        guard st.selection.target == .slides, !model.session.tool.dragging, model.session.tool.marquee == nil else { return true }
        if !e.hasPreciseScrollingDeltas {
            wheelCarry.use(st.uid)
            let w = CanvasMetrics.Wheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, cmdOrCtrl: false, shift: f.contains(.shift))
            if let target = CanvasMetrics.wheelSlideTarget([w], st.selection.slide, st.doc.slides.count, &wheelCarry.carry),
               target != st.selection.slide {
                activate()
                model.run("slide.go", ["index": .integer(target)])
            }
            return true
        }
        // A trackpad: one page per gesture, momentum ignored, and a second flick waits.
        if e.phase == .began || e.phase == .mayBegin {
            flickDone = false
            flickSum = (0, 0)
        }
        guard e.momentumPhase == [], !flickDone else { return true }
        flickSum.0 += e.scrollingDeltaX
        flickSum.1 += e.scrollingDeltaY
        if let next = CanvasMetrics.pageFlick(flickSum.0, flickSum.1), Date().timeIntervalSince(lastFlick) > CanvasMetrics.flickCooldown {
            flickDone = true
            lastFlick = Date()
            activate()
            model.run(next ? "slide.next" : "slide.previous")
        }
        return true
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        guard let model else { return }
        if eyedropper != nil {
            if e.keyCode == 53 { endEyedropper() }
            return
        }
        guard let st = activeState else {
            super.keyDown(with: e)
            return
        }
        // An input method composing takes every key until it commits.
        if st.composition != nil || hasMarkedText() {
            interpretKeyEvents([e])
            return
        }
        let f = e.modifierFlags
        let chars = e.charactersIgnoringModifiers ?? ""
        let m = mods(e)
        if let sc = chars.unicodeScalars.first, let name = CanvasKeys.name(sc) {
            // The show and the animation preview take their keys first.
            for intercept in AppController.shared?.keyInterceptors ?? [] where intercept(name) != nil { return }
            model.key(name, m)
            return
        }
        let editing = st.selection.text != nil
        // Control alone in text keeps the Mac's text keys (⌃A, ⌃E, ⌃K…); otherwise ⌘ and ⌃ are shortcuts.
        if f.contains(.command) || (f.contains(.control) && !editing) {
            let r = model.key(chars.lowercased(), m)
            if case .success(let v) = r, v["handled"]?.asBool == true { return }
            super.keyDown(with: e)
            return
        }
        interpretKeyEvents([e])
    }

    // MARK: Eyedropper

    /// Start the Eyedropper: the next click on the slide takes the colour under it.
    func beginEyedropper(_ pick: CanvasEyedropper.Pick) {
        guard let model else { return }
        activate()
        switch CanvasEyedropper.begin(model.session, pick) {
        case .success(let e):
            eyedropper = e
            model.status = e.prompt
            window?.makeFirstResponder(self)
            eyedropperMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
                let number = ev.windowNumber, at = ev.locationInWindow
                MainActor.assumeIsolated { self?.clickSeen(windowNumber: number, at: at) }
                return ev
            }
        case .failure(let err):
            model.status = err.message
        }
        model.changed()
    }

    /// A click anywhere but the canvas cancels the Eyedropper.
    private func clickSeen(windowNumber: Int, at: CGPoint) {
        guard eyedropper != nil else { return }
        let inside = windowNumber == window?.windowNumber && visibleRect.contains(convert(at, from: nil))
        if !inside { endEyedropper() }
    }

    func endEyedropper() {
        eyedropper = nil
        if let m = eyedropperMonitor { NSEvent.removeMonitor(m) }
        eyedropperMonitor = nil
        overlay.needsDisplay = true
        updateCursor()
        model?.changed()
    }

    private func eyedropperClick(_ e: NSEvent) {
        guard let picker = eyedropper, let l = layoutInfo, let model else { return }
        let at = convert(e.locationInWindow, from: nil)
        let taken = picker
        endEyedropper()
        guard l.slideRect.contains(at) else { return }
        taken.click(model, l.xf.toSlide(at))
    }

    // MARK: Drag and drop (pictures, sound, video, outlines, presentations)

    private func droppedURLs(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty || model == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let model else { return false }
        activate()
        var any = false
        for url in droppedURLs(sender) {
            let name = url.lastPathComponent
            if CanvasDrop.isPresentation(name) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                any = true
                continue
            }
            // A header is enough to tell the kind; the engine reads the file itself by path.
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 64) } ?? Data()
            switch CanvasDrop.infer(name, [UInt8](head)) {
            case .insert(let cmd)?:
                model.run(cmd, ["path": .string(url.path)])
                any = true
            case .outline?:
                guard let text = Self.outlineText(url) else {
                    model.status = String(localized: "\(name): the outline couldn't be read", bundle: .module, comment: "Status after a drop: the file's name, then the problem")
                    continue
                }
                model.run("slide.fromOutline", ["text": .string(text), "markdown": .bool(name.lowercased().hasSuffix(".md"))])
                any = true
            case .open?:
                any = true
            case nil:
                model.status = String(localized: "\(name): DeckCraftNative can't open this kind of file", bundle: .module, comment: "Status after a drop: the file's name, then the problem")
            }
        }
        return any
    }

    /// The text of a dropped outline (an RTF file through the system's reader).
    static func outlineText(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "rtf" {
            return (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
        }
        guard let d = try? Data(contentsOf: url), d.count <= 16 << 20 else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The canvas's scroll view: it hands the wheel to the canvas first (zoom, page turns).
@MainActor
final class CanvasScrollView: NSScrollView {
    weak var canvas: CanvasView?

    override func scrollWheel(with e: NSEvent) {
        if canvas?.wheel(e) == true { return }
        super.scrollWheel(with: e)
    }
}
