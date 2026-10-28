// DCApp — the control server's host: `ui.inspect`, `ui.screenshot`, synthetic input, `app.open`/`save`/`quit`
// (`crates/ui-egui/src/control.rs`, `capture.rs`, `apps/deckcraft/src/control_server.rs`).
//
// `--control PORT` starts DCAutomation's `ControlServer` on 127.0.0.1. Its connection threads queue each
// request and wake the main thread, which takes it (`take`: a request whose sender gave up never runs late),
// answers it with `Control.handle` over `AppControlHost`, and replies. A screenshot waits for the window to
// settle, then captures it.
import AppKit
import DCAutomation
import DCCore
import DCEngine
import DCRender
import os
import ScreenCaptureKit

@MainActor
enum AutomationFeature {
    static let log = Logger(subsystem: "com.xocialize.deckcraftnative", category: "control")
    static var server: ControlServer?
    static var host: AppControlHost?

    static func install(_ app: AppController) {}

    /// Start the server on `port` (`control_server::start`). A port in use is logged, as deckcraft logs it,
    /// and the app runs without one.
    static func start(port: UInt16) {
        guard let app = AppController.shared else { return }
        host = AppControlHost(session: app.model.session)
        do {
            server = try ControlServer(port: port, wake: {
                DispatchQueue.main.async { MainActor.assumeIsolated { drain() } }
            })
            log.info("control server listening on 127.0.0.1:\(port)")
        } catch {
            log.error("control server failed to bind 127.0.0.1:\(port): \(error.description)")
        }
    }

    /// Answer every queued request, in order.
    static func drain() {
        guard let server, let host else { return }
        while let req = server.tryReceive() {
            guard req.take() else { continue }
            switch Control.handle(host, req.method, req.params) {
            case .done(let v): req.reply.send(v)
            case .screenshot(let path): screenshot(path) { req.reply.send($0) }
            }
            // `ui.key`, `ui.text` and `ui.pointer` reach the session without `AppModel.run`: views redraw here.
            AppController.shared?.model.changed()
        }
    }

    // MARK: Screenshots (`capture.rs`, `save_screenshot`)

    /// How long a ScreenCaptureKit capture may take before the offscreen drawing answers instead.
    static let captureWait: TimeInterval = 3

    /// Sends the first reply only.
    @MainActor final class ReplyOnce {
        private var reply: (@MainActor (JSON) -> Void)?
        init(_ reply: @escaping @MainActor (JSON) -> Void) { self.reply = reply }
        func send(_ v: JSON) {
            guard let r = reply else { return }
            reply = nil
            r(v)
        }
    }

    /// The window must have been unchanged this long before capture (`SETTLE`).
    static let settle: Duration = .milliseconds(120)
    /// Bytes for one captured image (`MAX_IMAGE_BYTES`).
    static let maxImageBytes = 128 << 20

    /// The window the next `ui.screenshot` captures in place of the document window (the start window's
    /// `{window: "start"}`); taken by that capture.
    static var nextCapture: NSWindow?

    /// Capture the document window after it settles and answer as `save_screenshot` does: a path reply
    /// writes the PNG and carries no base64; an inline reply carries the PNG base64-encoded.
    static func screenshot(_ path: String?, reply: @escaping @MainActor (JSON) -> Void) {
        let target = nextCapture
        nextCapture = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated {
                guard let window = target ?? AppControlHost.keyDocumentWindow() else {
                    reply(["ok": false, "error": "no window to capture"])
                    return
                }
                // The window as the screen shows it (sidebar and inspector materials included) when the app
                // may record the screen; else the views drawn offscreen, which leaves materials blank.
                guard CGPreflightScreenCaptureAccess() else {
                    reply(capture(window, path))
                    return
                }
                let id = CGWindowID(window.windowNumber)
                // ScreenCaptureKit can wait indefinitely (a binary the system hasn't cleared for capture yet):
                // after `captureWait` the reply falls back to the offscreen drawing, and a late image is dropped.
                let once = ReplyOnce(reply)
                Task { @MainActor in
                    let image = await screenImage(id)
                    once.send(image.map { encode(NSBitmapImageRep(cgImage: $0), path) } ?? capture(window, path))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + captureWait) {
                    MainActor.assumeIsolated { once.send(capture(window, path)) }
                }
            }
        }
    }

    /// The window's pixels through ScreenCaptureKit, at its backing scale; nil on any failure.
    static func screenImage(_ id: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func capture(_ window: NSWindow, _ path: String?) -> JSON {
        guard let frame = window.contentView?.superview ?? window.contentView else {
            return ["ok": false, "error": "no window to capture"]
        }
        frame.layoutSubtreeIfNeeded()
        let bounds = frame.bounds
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else {
            return ["ok": false, "error": "the screenshot has no usable image size"]
        }
        frame.cacheDisplay(in: bounds, to: rep)
        return encode(rep, path)
    }

    /// `save_screenshot`: the PNG written to `path`, or inline.
    static func encode(_ rep: NSBitmapImageRep, _ path: String?) -> JSON {
        if rep.pixelsWide * rep.pixelsHigh * 4 > maxImageBytes {
            return ["ok": false, "error": "the screenshot would exceed 128 MiB; use ui.render"]
        }
        guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else {
            return ["ok": false, "error": "the screenshot could not be encoded"]
        }
        let w = JSON.integer(rep.pixelsWide), h = JSON.integer(rep.pixelsHigh)
        guard let path else {
            return ["ok": true, "result": ["width": w, "height": h, "png": .string(Cmd.base64Encode([UInt8](png)))]]
        }
        do {
            try Data(png).write(to: URL(filePath: path))
            return ["ok": true, "result": ["path": .string(path), "width": w, "height": h]]
        } catch {
            return ["ok": false, "error": .string(error.localizedDescription)]
        }
    }
}
