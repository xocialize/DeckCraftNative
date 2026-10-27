// DCApp — the slide show, the presenter view on the second display, Reading View, animation preview, and media
// playback (`show.rs`, `media.rs`, `textures.rs`, `apps/deckcraft/src/audio.rs`, `display.rs`). Registers the
// show's UI commands (`show.start`, `show.end`, `view.reading`, `animation.preview`), the engine's `startShow`
// and `media` requests, the control channel's `show.*` methods and `ui.key` while a show runs, and the `showing`
// and `animPreview` keys of `ui.inspect`. `audio.rs` (cpal) is DCMedia's `AudioEngineOutput`; `display.rs` and
// `graphics.rs` choose X11/Wayland and Direct3D, which have no counterpart on the Mac.
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import DCMedia
import DCModel

@MainActor
enum ShowFeature {
    /// The app's show and media (one per app).
    private(set) static var coordinator: ShowCoordinator?
    private(set) static var windows: ShowWindows?
    private static var preview: AnimPreviewOverlay?
    private static var mediaTimer: Timer?

    static func install(_ app: AppController) {
        let coord = ShowCoordinator(model: app.model, media: MediaHost(AudioEngineOutput()))
        coordinator = coord
        let previewOverlay = AnimPreviewOverlay(coord: coord)
        preview = previewOverlay
        if let metal = ShowMetal.shared {
            let w = ShowWindows(coord: coord, metal: metal)
            windows = w
            coord.onShowStarted = { s in w.open(s) }
            coord.onShowEnded = { w.close() }
        }
        coord.onPreviewChanged = { previewOverlay.sync() }

        for id in ["show.start", "show.end", "view.reading", "animation.preview"] {
            app.handle([id]) { p in
                if p["windowed"]?.asBool == true { windows?.windowedNext = true }
                if id != "show.end" && id != "animation.preview" && ShowMetal.shared == nil { return .failure("the slide show needs a Metal device") }
                return coord.command(id, p) ?? .failure("unknown show command")
            }
        }
        app.onRequest { r in
            let took = coord.request(r)
            if took { ensureMediaClock() }
            return took
        }
        app.interceptKeys { key in interceptKey(key) }
        app.inspect("showing") { coord.showingValue(windows?.showView?.bounds ?? .zero) }
        app.inspect("animPreview") { coord.animPreviewValue }
        app.control(["show.start"]) { p in
            if p["windowed"]?.asBool == true { windows?.windowedNext = true }
            // `show.start` reads `reading` itself and checks `from` (control.rs): `view.reading` would ignore both.
            return wrap(app.model.run("show.start", p))
        }
        app.control(["show.end"]) { _ in
            // deckcraft queues an Escape; here the show ends at once.
            wrap(app.model.run("show.end"))
        }
        app.control(["show.key"]) { p in
            guard let k = p["key"]?.asStr else { return err("missing `key`") }
            return interceptKey(k) ?? err("no slide show is running")
        }
        app.control(["show.state"]) { _ in ok(coord.showingValue(windows?.showView?.bounds ?? .zero)) }
        app.control(["show.next"]) { _ in navigate(true) }
        app.control(["show.previous"]) { _ in navigate(false) }
        app.control(["show.goto"]) { p in
            guard coord.show != nil else { return err("no slide show is running") }
            guard let i = p["index"]?.asU64.flatMap({ Int(exactly: $0) }), let n = coord.showState?.doc.slides.count, i < n else {
                return err("`index` is not a slide")
            }
            coord.goto(i, now: ShowCoordinator.now())
            windows?.showView?.handle(ShowOutcome())
            return ok(coord.showingValue(windows?.showView?.bounds ?? .zero))
        }
        app.control(["show.display"]) { p in
            if let name = p["display"]?.asStr { ShowWindows.displayPreference = name }
            return ok([
                "display": .string(ShowWindows.displayPreference),
                "displays": .array(ShowWindows.screens().map { ["name": .string($0.name), "main": .bool($0.main)] }),
            ])
        }
        app.control(["ui.screenshot"]) { p in screenshot(p) }
    }

    private static func ok(_ v: JSON) -> ControlOutcome { .done(["ok": true, "result": v]) }
    private static func err(_ e: String) -> ControlOutcome { .done(["ok": false, "error": .string(e)]) }
    private static func wrap(_ r: Result<JSON, CommandError>) -> ControlOutcome {
        switch r {
        case .success(let v): ok(v)
        case .failure(let e): err(e.message)
        }
    }

    /// `ui.key` while a show runs goes to the show (`control.rs`: queued as a key event for the show); Esc stops
    /// the canvas animation preview.
    static func interceptKey(_ key: String) -> ControlOutcome? {
        guard let coord = coordinator else { return nil }
        if coord.animPreview != nil && coord.show == nil && ["escape", "esc"].contains(key.lowercased()) {
            coord.stopAnimPreview()
            return ok(["preview": false])
        }
        guard let s = coord.show, !s.ended || ShowKey(name: key) != .other else { return nil }
        let k = ShowKey(name: key)
        if k == .other { return nil }
        let (_, keep) = coord.key(k, ShowMods(), presenter: false, now: ShowCoordinator.now())
        if !keep { coord.endShow() } else { windows?.showView?.handle(ShowOutcome()) }
        windows?.presenter?.refresh()
        return ok(["show": true])
    }

    private static func navigate(_ forward: Bool) -> ControlOutcome {
        guard let coord = coordinator, coord.show != nil else { return err("no slide show is running") }
        if !coord.navigate(forward, now: ShowCoordinator.now()) { coord.endShow() } else { windows?.showView?.handle(ShowOutcome()) }
        return ok(coord.showingValue(windows?.showView?.bounds ?? .zero))
    }

    /// Keep the media clock running while anything plays outside a show (the editor's media and
    /// `Session.mediaStatus`); the show's own frames tick it while one runs.
    static func ensureMediaClock() {
        guard mediaTimer == nil else { return }
        let t = Timer(timeInterval: 0.015, repeats: true) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let coord = coordinator else { return }
                if coord.show != nil { return }
                if !coord.tickMedia(ShowCoordinator.now()) && !coord.media.anyActive {
                    mediaTimer?.invalidate()
                    mediaTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        mediaTimer = t
    }

    /// `ui.screenshot` while a show runs: the show window as it is on screen (or presenter view with
    /// `{"window": "presenter"}`), written to `path` or answered inline; otherwise the document window, as the
    /// Automation host takes it.
    static func screenshot(_ p: JSON) -> ControlOutcome {
        guard coordinator?.show != nil, let w = windows else { return .screenshot(path: p["path"]?.asStr) }
        let image: CGImage?
        if p["window"]?.asStr == "presenter" {
            guard let pw = w.presenterWindow, let v = pw.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                return err("presenter view is not open")
            }
            v.cacheDisplay(in: v.bounds, to: rep)
            image = rep.cgImage
        } else {
            image = w.showView?.snapshot()
        }
        guard let img = image, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            return err("the show could not be captured")
        }
        if let path = p["path"]?.asStr {
            do { try png.write(to: URL(filePath: path)) } catch { return err("could not write \(path): \(error.localizedDescription)") }
            return ok(["path": .string(path), "width": .integer(img.width), "height": .integer(img.height)])
        }
        return ok(["png": .string(Cmd.base64Encode([UInt8](png))), "width": .integer(img.width), "height": .integer(img.height)])
    }
}
