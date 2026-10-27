// DCApp — the audience's slide show view: Metal draws the slide and its transitions every display frame
// (`NSView.displayLink`), a Core Graphics layer above it draws the ink, the laser, See All Slides, the media bars
// and the labels, and SwiftUI draws the toolbar and Reading View's bar. Keys, clicks, the wheel and the pointer go
// to the show's controller. Port of the input and overlay drawing of `ui` in deckcraft
// `crates/ui-egui/src/show.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCCore
import DCMedia
import DCModel
import DesignScaffold
import MetalKit
import SwiftUI

/// What the toolbar and Reading View's bar show (SwiftUI reads it).
@MainActor @Observable
final class ShowChromeModel {
    var toolbarVisible = false
    var pen = false
    var laser = false
    var blank: ShowBlank?
    var grid = false
    var zoomLabel = "Zoom"
    var slideText = ""
}

/// The MTKView under the overlay: it never takes the pointer (the show view does).
final class ShowMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class ShowView: NSView, MTKViewDelegate {
    let coord: ShowCoordinator
    let stage: ShowStage
    let mtk: ShowMTKView
    let overlay: ShowOverlayView
    let chrome = ShowChromeModel()
    private var toolbarHost: NSHostingView<ShowToolbar>?
    private var readingHost: NSHostingView<ShowReadingBar>?
    private var link: CADisplayLink?
    private var fallback: Timer?
    private(set) var lastTick = 0.0
    private var lastDraw = 0.0
    private var needsFrame = true
    private var animating = false
    /// Scrolls since the last frame, summed as egui sums a frame's wheel events: (dx, dy) points, zoom lines.
    private var scrollFlick = (0.0, 0.0)
    private var scrollZoom: Double?
    private var scrollAt: CGPoint = .zero
    /// The pointer in view coordinates (nil outside).
    private(set) var pointer: CGPoint?
    private var downAt: CGPoint?
    private var cursorShown: NSCursor?
    /// Called once per tick after the show advanced (presenter view refreshes from it).
    var onTick: (@MainActor () -> Void)?

    init(coord: ShowCoordinator, metal: ShowMetal) {
        self.coord = coord
        stage = ShowStage(coord: coord, metal: metal)
        mtk = ShowMTKView(frame: .zero, device: metal.device)
        overlay = ShowOverlayView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.framebufferOnly = true
        mtk.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtk.delegate = self
        mtk.autoresizingMask = [.width, .height]
        addSubview(mtk)
        overlay.show = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        let toolbar = NSHostingView(rootView: ShowToolbar(chrome: chrome, act: { [weak self] in self?.toolbarAction($0) }))
        toolbarHost = toolbar
        addSubview(toolbar)
        let reading = NSHostingView(rootView: ShowReadingBar(chrome: chrome, act: { [weak self] in self?.toolbarAction($0) }))
        readingHost = reading
        addSubview(reading)
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        mtk.frame = bounds
        overlay.frame = bounds
        let reading = coord.show?.reading ?? false
        readingHost?.isHidden = !reading
        readingHost?.frame = CGRect(x: 0, y: bounds.height - ShowGeometry.readingBarHeight, width: bounds.width, height: ShowGeometry.readingBarHeight)
        toolbarHost?.frame = ShowGeometry.toolBarRect(bounds)
        needsFrame = true
    }

    override func updateTrackingAreas() {
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    // MARK: Clock

    /// Start ticking at the display's refresh rate, with a slow timer behind it for when the display link
    /// stops (an occluded window): the show keeps playing (deckcraft's hidden logic).
    func startClock() {
        let l = displayLink(target: self, selector: #selector(displayTick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self, ShowCoordinator.now() - self.lastTick > 0.25 else { return }
                self.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fallback = t
    }

    func stopClock() {
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
    }

    @objc private func displayTick(_ l: CADisplayLink) { tick() }

    /// One frame: advance the show, carry out the wheel, draw what changed.
    func tick() {
        let now = ShowCoordinator.now()
        lastTick = now
        guard let s = coord.show else { return }
        if !coord.tick(now) {
            coord.endShow()
            return
        }
        if scrollZoom != nil || scrollFlick != (0, 0) {
            let out = coord.scroll(scrollAt, bounds, zoomLines: scrollZoom, flick: scrollFlick, now: now)
            scrollZoom = nil
            scrollFlick = (0, 0)
            if !handle(out) { return }
        }
        if coord.media.syncVideoFrames() { needsFrame = true }
        if animating || needsFrame || s.trans != nil || now - lastDraw > 0.25 {
            needsFrame = false
            lastDraw = now
            mtk.draw()
        }
        refreshChrome(now)
        overlay.refresh(now)
        updateCursor(now)
        onTick?()
    }

    /// Carry out an input's outcome; false when the show ended.
    @discardableResult
    func handle(_ out: ShowOutcome) -> Bool {
        needsFrame = true
        if let u = out.openURL, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        if !out.keep {
            coord.endShow()
            return false
        }
        return true
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { drawFrame() }
    }

    private func drawFrame() {
        let scale = Double(window?.backingScaleFactor ?? 2)
        let (draws, anim) = stage.draws(full: bounds, scale: scale, now: ShowCoordinator.now())
        animating = anim
        guard let metal = ShowMetal.shared, let rp = mtk.currentRenderPassDescriptor, let drawable = mtk.currentDrawable,
              let cb = metal.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        metal.encode(enc, draws, size: mtk.drawableSize, format: mtk.colorPixelFormat)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// The frame as it is on screen, Metal and overlay together (`ui.screenshot` of the show).
    func snapshot() -> CGImage? {
        let scale = Double(window?.backingScaleFactor ?? 2)
        let (w, h) = (Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()))
        guard let metal = ShowMetal.shared else { return nil }
        let (draws, _) = stage.draws(full: bounds, scale: scale, now: ShowCoordinator.now())
        guard let img = metal.renderOffscreen(draws, width: w, height: h), let base = img.cgImage() else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        overlay.drawContent(ctx, now: ShowCoordinator.now())
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Chrome

    private func refreshChrome(_ now: Double) {
        guard let s = coord.show, let doc = coord.showState?.doc else { return }
        let visible = !s.reading && !s.grid && (s.pointerAwake(now) || s.zoomArm)
        if chrome.toolbarVisible != visible { chrome.toolbarVisible = visible }
        toolbarHost?.isHidden = !visible
        if chrome.pen != s.pen { chrome.pen = s.pen }
        if chrome.laser != s.laser { chrome.laser = s.laser }
        if chrome.blank != s.blank { chrome.blank = s.blank }
        if chrome.grid != s.grid { chrome.grid = s.grid }
        if chrome.zoomLabel != s.zoomLabel { chrome.zoomLabel = s.zoomLabel }
        let text = "Slide \(s.state.slide + 1) of \(doc.slides.count)"
        if chrome.slideText != text { chrome.slideText = text }
        readingHost?.isHidden = !s.reading
    }

    /// The toolbar's and Reading View's buttons.
    func toolbarAction(_ a: ShowToolbarAction) {
        guard let s = coord.show else { return }
        let now = ShowCoordinator.now()
        switch a {
        case .previous: _ = coord.navigate(false, now: now)
        case .next:
            if !coord.navigate(true, now: now) {
                coord.endShow()
                return
            }
        case .pen: s.setPen(!s.pen)
        case .laser: s.setLaser(!s.laser)
        case .black: s.toggleBlank(.black)
        case .white: s.toggleBlank(.white)
        case .all: s.grid.toggle()
        case .zoom: s.zoomKey()
        case .end:
            coord.endShow()
            return
        }
        needsFrame = true
        overlay.needsDisplay = true
    }

    // MARK: Pointer

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) { moved(point(e)) }
    override func mouseEntered(with e: NSEvent) { moved(point(e)) }
    override func mouseExited(with e: NSEvent) {
        pointer = nil
        overlay.needsDisplay = true
    }

    private func moved(_ p: CGPoint) {
        let now = ShowCoordinator.now()
        pointer = p
        coord.show?.lastMove = now
        updateCursor(now)
        overlay.needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        downAt = p
        moved(p)
        guard let s = coord.show, s.pen, let doc = coord.showState?.doc else { return }
        s.strokes.append([])
        addInk(p, s, doc)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        moved(p)
        guard let s = coord.show, s.pen, let doc = coord.showState?.doc else { return }
        addInk(p, s, doc)
    }

    private func addInk(_ p: CGPoint, _ s: ShowController, _ doc: Presentation) {
        let srect = ShowGeometry.slideRect(bounds, reading: s.reading, doc)
        guard let (nx, ny) = ShowGeometry.normOnSlide(srect, s.zoomUV, p), !s.strokes.isEmpty else { return }
        s.strokes[s.strokes.count - 1].append(CGPoint(x: nx, y: ny))
    }

    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        defer { downAt = nil }
        guard let s = coord.show, !s.pen else { return }
        // A click, not the end of a drag.
        if let d = downAt, hypot(d.x - p.x, d.y - p.y) > 6 { return }
        handle(coord.click(p, bounds, ShowCoordinator.now()))
    }

    override func rightMouseDown(with e: NSEvent) {
        handle(coord.secondaryClick(ShowCoordinator.now()))
    }

    override func scrollWheel(with e: NSEvent) {
        let p = point(e)
        scrollAt = p
        coord.show?.lastMove = ShowCoordinator.now()
        let precise = e.hasPreciseScrollingDeltas
        let (dx, dy) = (Double(e.scrollingDeltaX), Double(e.scrollingDeltaY))
        let m = e.modifierFlags
        if m.contains(.command) || m.contains(.control) {
            // ⌘/Ctrl+wheel zooms around the pointer, as in PowerPoint (#1286); a pinch is not a show gesture.
            let along = Swift.abs(dx) > Swift.abs(dy) ? dx : dy
            let lines = precise ? along / 40 : along
            scrollZoom = (scrollZoom ?? 0) + (lines.isFinite ? lines : 0)
        } else {
            let k = precise ? 1.0 : 40.0
            scrollFlick = (scrollFlick.0 + dx * k, scrollFlick.1 + dy * k)
        }
    }

    // MARK: Cursor

    /// The pointer as the show wants it: a crosshair for the pen, zoom and grid; none for the laser and an idle
    /// pointer (#968: idle wins over a clickable shape); a hand over a link or trigger.
    private func updateCursor(_ now: Double) {
        guard coord.show != nil, let p = pointer, window?.isKeyWindow ?? false else { return }
        let c: NSCursor = switch coord.cursor(p, bounds, now) {
        case .crosshair: .crosshair
        case .hidden: ShowCursor.invisible
        case .pointingHand: .pointingHand
        case .arrow: .arrow
        }
        if c !== cursorShown || c === ShowCursor.invisible {
            c.set()
            cursorShown = c
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorShown ?? .arrow)
    }
}

enum ShowCursor {
    /// A cursor with nothing to see: the laser and an idle pointer.
    @MainActor static let invisible: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()
}

// MARK: - The overlay

/// Everything the show draws over the slide with Core Graphics, in deckcraft's order: GIF buttons and media bars,
/// a blank screen, the typed slide number, the ink, the laser, the zoom hint, the end screen, See All Slides and
/// the rehearsal clock. It never takes the pointer.
@MainActor
final class ShowOverlayView: NSView {
    weak var show: ShowView?
    private var signature = ""

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Redraw when what it shows changed.
    func refresh(_ now: Double) {
        guard let v = show, let s = v.coord.show else { return }
        var parts: [String] = [
            "\(s.state.slide).\(s.state.step).\(s.ended).\(s.grid).\(s.zoomArm).\(String(describing: s.blank)).\(s.goto)",
            "\(s.strokes.count).\(s.strokes.last?.count ?? 0).\(s.laser).\(s.pen).\(s.pointerAwake(now))",
        ]
        if s.rehearse { parts.append("\(Int((now - s.slideStart) * 10))") }
        if v.coord.showState?.doc.show.showMediaControls ?? false {
            for m in v.stage.mediaPlaces {
                let st = v.coord.media.status(m.id)
                parts.append("\(m.id.rawValue):\(String(describing: st?.state)):\(Int((st?.position ?? 0) * 4))")
            }
        }
        for m in v.stage.mediaPlaces where m.unplayable { parts.append("x\(m.id.rawValue)") }
        let sig = parts.joined(separator: "|")
        if sig != signature {
            signature = sig
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawContent(ctx, now: ShowCoordinator.now())
    }

    private func text(_ s: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color,
        ])
    }

    private func drawCentered(_ a: NSAttributedString, _ center: CGPoint) {
        let sz = a.size()
        a.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }

    /// Draw the overlay into `ctx` (flipped, in view points); the window's own draw and the snapshot share it.
    func drawContent(_ ctx: CGContext, now: Double) {
        guard let v = show, let s = v.coord.show, let st = v.coord.showState else { return }
        let doc = st.doc
        let full = v.bounds
        let srect = ShowGeometry.slideRect(full, reading: s.reading, doc)
        let uv = s.zoomUV
        let awake = s.pointerAwake(now)
        if !s.ended && s.trans == nil {
            // A video whose codec this Mac can't decode: say so on its box rather than show nothing.
            for m in v.stage.mediaPlaces where m.unplayable && v.coord.media.status(m.id) != nil {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
                ctx.fill(m.rect)
                drawCentered(text("This video can't be played on this Mac", size: 13, color: .white), CGPoint(x: m.rect.midX, y: m.rect.midY))
            }
            // Play/pause on the GIF under the pointer, and the media bar (Slide Show ▸ Show Media Controls).
            if doc.show.showMediaControls && !s.zoomArm && s.zoom == nil {
                let k = srect.width / Swift.max(doc.slideSize.width, 1)
                if let p = v.pointer, !s.pen, !s.laser, awake {
                    for g in v.stage.gifs {
                        let r = ShowGeometry.onScreen(srect, k, g.rect)
                        if ShowGeometry.contains(r, p) { drawGifButton(ctx, ShowGeometry.gifButtonRect(r), paused: g.paused) }
                    }
                }
                if let p = v.pointer, awake, let (id, clip, bar) = v.coord.mediaBarTarget(p, full) {
                    drawMediaBar(ctx, bar, v.coord.media.status(id), clip)
                }
            }
        }
        if s.ended {
            drawCentered(text("End of slide show, click to exit.", size: 18, color: NSColor(white: 0.78, alpha: 1)), CGPoint(x: full.midX, y: full.minY + 40))
        }
        if let b = s.blank {
            ctx.setFillColor(b == .black ? NSColor.black.cgColor : NSColor.white.cgColor)
            ctx.fill(full)
        }
        if !s.goto.isEmpty {
            let label = "Go to slide \(s.goto)"
            let w = Swift.min(Swift.max(28 + Double(label.count) * 10, 160), Swift.max(full.width - 32, 160))
            let r = CGRect(x: full.minX + 16, y: full.maxY - 96, width: w, height: 36)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: Tokens.Radius.control, cornerHeight: Tokens.Radius.control, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.fillPath()
            drawCentered(text(label, size: 18, color: .white), CGPoint(x: r.midX, y: r.midY))
        }
        // Ink.
        let pen = NSColor(srgbRed: Double(doc.show.penColor.r) / 255, green: Double(doc.show.penColor.g) / 255, blue: Double(doc.show.penColor.b) / 255, alpha: 1)
        ctx.setStrokeColor(pen.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in s.strokes where stroke.count > 1 {
            let pts = stroke.map { ShowGeometry.slideToScreen(srect, uv, $0.x, $0.y) }
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        if s.laser, !s.ended, let p = v.pointer {
            let c = doc.show.laserColor
            let col = NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1)
            ctx.setFillColor(col.withAlphaComponent(70 / 255).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32))
            ctx.setFillColor(col.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11))
        }
        if s.zoomArm && !s.grid {
            drawCentered(text("Click the slide to zoom in. Esc cancels.", size: 16, color: .white), CGPoint(x: full.midX, y: full.minY + 36))
        }
        if s.grid && !s.ended { drawGrid(ctx, v, full, current: s.state.slide, doc) }
        if s.rehearse {
            let t = now - s.slideStart, total = now - s.showStart
            let r = CGRect(x: full.minX + 12, y: full.minY + 12, width: 220, height: 30)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: Tokens.Radius.control, cornerHeight: Tokens.Radius.control, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.63).cgColor)
            ctx.fillPath()
            let label = String(
                format: "Slide %02d:%04.1f   Total %02d:%02d", Int(Swift.max(t, 0) / 60), Swift.max(t, 0).truncatingRemainder(dividingBy: 60),
                Int(Swift.max(total, 0) / 60), Int(Swift.max(total, 0).truncatingRemainder(dividingBy: 60))
            )
            drawCentered(text(label, size: 13, color: .white), CGPoint(x: r.midX, y: r.midY))
        }
    }

    /// See All Slides (`paint_grid`).
    private func drawGrid(_ ctx: CGContext, _ v: ShowView, _ full: CGRect, current: Int, _ doc: Presentation) {
        let slides = ShowGeometry.gridIndices(doc.slides.count)
        let cells = ShowGeometry.seeAllCells(full, slides.count, ShowGeometry.slideAspect(doc))
        ctx.setFillColor(NSColor(white: 16 / 255, alpha: 1).cgColor)
        ctx.fill(full)
        drawCentered(text("All slides", size: 20, color: .white), CGPoint(x: full.midX, y: full.minY + 28))
        if doc.slides.count > ShowGeometry.gridCap {
            drawCentered(text("First \(ShowGeometry.gridCap) slides", size: 13, color: NSColor(white: 0.7, alpha: 1)), CGPoint(x: full.midX, y: full.minY + 50))
        }
        var budget = slides.count <= 12 ? 12 : 4
        var missing = false
        for (i, rect) in zip(slides, cells) {
            ctx.setFillColor(NSColor(white: 32 / 255, alpha: 1).cgColor)
            ctx.fill(rect)
            if let img = v.stage.thumb(i, budget: &budget) {
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            } else {
                missing = true
            }
            let cur = i == current
            ctx.setStrokeColor(cur ? NSColor.white.cgColor : NSColor(white: 70 / 255, alpha: 1).cgColor)
            ctx.setLineWidth(cur ? 3 : 1)
            ctx.stroke(rect.insetBy(dx: cur ? 1.5 : 0.5, dy: cur ? 1.5 : 0.5))
            let hidden = doc.slides.at(i)?.hidden ?? false
            drawCentered(
                text(hidden ? "\(i + 1)  Hidden" : "\(i + 1)", size: 13, color: cur ? .white : NSColor(white: 0.7, alpha: 1)),
                CGPoint(x: rect.midX, y: rect.maxY + 12)
            )
        }
        // Thumbnails still to render come on the next frames.
        if missing { DispatchQueue.main.async { [weak self] in self?.needsDisplay = true } }
    }

    private func drawGifButton(_ ctx: CGContext, _ b: CGRect, paused: Bool) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: b)
        drawPlayPause(ctx, b.insetBy(dx: b.width * 0.3, dy: b.height * 0.3), playing: !paused)
    }

    private func drawPlayPause(_ ctx: CGContext, _ r: CGRect, playing: Bool) {
        ctx.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
        if playing {
            let w = r.width * 0.3
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
            ctx.fill(CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height))
        } else {
            ctx.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY)])
            ctx.closePath()
            ctx.fillPath()
        }
    }

    /// PowerPoint-style media controls: play/pause, quarter-second nudges, the timeline and the time (`control_bar`).
    private func drawMediaBar(_ ctx: CGContext, _ rect: CGRect, _ status: VoiceStatus?, _ clip: MediaClip) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 32 / 255, alpha: 230 / 255).cgColor)
        ctx.fillPath()
        let parts = ShowGeometry.mediaBarParts(rect)
        let playing = status.map { $0.state == .playing || $0.state == .loading } ?? false
        let duration = status.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? Double(clip.durationMs) / 1000
        let pos = status?.position ?? Double(clip.trimStartMs) / 1000
        drawPlayPause(ctx, parts.play.insetBy(dx: 4, dy: 4), playing: playing)
        for (r, left) in [(parts.back, true), (parts.forward, false)] {
            let q = r.insetBy(dx: 6, dy: 6)
            let (a, b) = left ? (q.maxX, q.minX) : (q.minX, q.maxX)
            ctx.addLines(between: [CGPoint(x: a, y: q.minY + 2), CGPoint(x: b, y: q.midY), CGPoint(x: a, y: q.maxY - 2)])
            ctx.closePath()
            ctx.fillPath()
        }
        let label = text(MediaHost.clock(pos), size: 11, color: NSColor(white: 0.92, alpha: 1))
        let lsz = label.size()
        label.draw(at: CGPoint(x: rect.maxX - 6 - lsz.width, y: rect.midY - lsz.height / 2))
        if let track = parts.track {
            ctx.setFillColor(NSColor(white: 90 / 255, alpha: 1).cgColor)
            ctx.fill(track)
            let frac = duration > 0 ? Swift.min(Swift.max(pos / duration, 0), 1) : 0
            let done = CGRect(x: track.minX, y: track.minY, width: track.width * frac, height: track.height)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(done)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: done.maxX - 5, y: track.midY - 5, width: 10, height: 10))
        }
        if let err = status?.error {
            text("No sound: \(err)", size: 10, color: .systemRed).draw(at: CGPoint(x: rect.minX, y: rect.maxY + 3))
        }
    }
}

// MARK: - Toolbar and Reading View's bar

enum ShowToolbarAction {
    case previous, next, pen, laser, black, white, all, zoom, end
}

/// The show's on-screen controls, bottom left, while the pointer moves.
struct ShowToolbar: View {
    let chrome: ShowChromeModel
    let act: (ShowToolbarAction) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            button("chevron.left", "Previous", .previous)
            button("chevron.right", "Next", .next)
            button("pencil.tip", chrome.pen ? "Pen on" : "Pen", .pen, on: chrome.pen)
            button("smallcircle.filled.circle", chrome.laser ? "Laser on" : "Laser", .laser, on: chrome.laser)
            button("rectangle.fill", "Black", .black, on: chrome.blank == .black)
            button("rectangle", "White", .white, on: chrome.blank == .white)
            button("square.grid.3x3", "All", .all, on: chrome.grid)
            button("plus.magnifyingglass", chrome.zoomLabel, .zoom, on: chrome.zoomLabel != "Zoom")
            button("xmark.circle", "End", .end)
        }
        .padding(.horizontal, Tokens.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Capsule().fill(.black.opacity(0.55)))
        .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, _ label: String, _ a: ShowToolbarAction, on: Bool = false) -> some View {
        Button { act(a) } label: {
            Image(systemName: symbol)
                .foregroundStyle(on ? Tokens.Color.accent : Tokens.Color.label)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .focusable(false)
    }
}

/// Reading View's bar: the slide number, Previous, Next and Close.
struct ShowReadingBar: View {
    let chrome: ShowChromeModel
    let act: (ShowToolbarAction) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Text(chrome.slideText).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            Spacer()
            Button { act(.previous) } label: { Image(systemName: "chevron.left") }.help("Previous").focusable(false)
            Button { act(.next) } label: { Image(systemName: "chevron.right") }.help("Next").focusable(false)
            Button("Close") { act(.end) }.focusable(false)
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }
}
