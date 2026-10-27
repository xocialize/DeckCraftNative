// DCApp — the canvas area's wiring: `ui.inspect`'s `canvasRect`, `slideRect` and `canvas`, and the hooks
// other areas use — the Eyedropper for the colour menus and Set Transparent Color (deckcraft
// `eyedropper.rs`), and the overlay slot over the slide for the Show area's animation preview.
// (Behaviour: deckcraft `crates/ui-egui/src/canvas.rs`, `eyedropper.rs`, `control.rs`' `inspect`; MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors.)
import AppKit
import DCAppModel
import DCCore
import DCEngine

@MainActor
enum CanvasFeature {
    /// Every canvas in a window (weakly).
    private static var canvases: [WeakCanvas] = []

    private struct WeakCanvas {
        weak var controller: CanvasViewController?
    }

    static func install(_ app: AppController) {
        // Window content coordinates (y down), `[left, top, width, height]`, as deckcraft's `inspect` gives them.
        app.inspect("canvasRect") {
            guard let c = current, let w = c.view.window else { return .null }
            return rect(c.scroll.convert(c.scroll.bounds, to: nil), w)
        }
        app.inspect("slideRect") {
            guard let c = current, let w = c.view.window, let r = c.canvas.layoutInfo?.slideRect else { return .null }
            return rect(c.canvas.convert(r, to: nil), w)
        }
        app.inspect("canvas") {
            guard let c = current else { return .null }
            let l = c.canvas.layoutInfo
            return [
                "scale": .num(l?.scale ?? 1), "fit": .num(l?.fit ?? 1),
                "scroll": [.num(c.scroll.contentView.bounds.minX), .num(c.scroll.contentView.bounds.minY)],
                "eyedropper": .bool(c.canvas.eyedropper != nil), "editingText": .bool(c.canvas.activeState?.selection.text != nil),
                "firstResponder": .bool(c.view.window?.firstResponder === c.canvas),
                "composing": .bool(c.canvas.hasMarkedText()),
            ]
        }
        // The context menu a right click opened: its items, and `choose` runs one (by title, submenus included).
        app.control(["ui.canvas.menu"]) { p in
            guard let c = current, let menu = c.canvas.lastMenu else { return .done(["ok": false, "error": "no context menu has been opened"]) }
            func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
            if let title = p["choose"]?.asStr {
                guard let item = items(menu).compactMap({ $0 as? CanvasMenu.ActionItem }).first(where: { $0.title == title }), item.isEnabled else {
                    return .done(["ok": false, "error": .string("no enabled item `\(title)`")])
                }
                item.performCanvasAction(nil)
                c.canvas.lastMenu = nil
                return .done(["ok": true, "result": .string(title)])
            }
            let list = items(menu).filter { !$0.isSeparatorItem }.map { i -> JSON in
                ["title": .string(i.title), "enabled": .bool(i.isEnabled), "checked": .bool(i.state == .on), "submenu": .bool(i.submenu != nil)]
            }
            return .done(["ok": true, "result": .array(list)])
        }
        // Programmatic Eyedropper and Set Transparent Color starts (control channel, scripts).
        app.control(["ui.eyedropper"]) { p in
            guard let c = current else { return .done(["ok": false, "error": "no canvas"]) }
            if p["cancel"]?.asBool == true {
                c.canvas.endEyedropper()
            } else if p["transparent"]?.asBool == true {
                c.canvas.beginEyedropper(.transparentColor)
            } else {
                c.canvas.beginEyedropper(.color { hex in AppController.shared?.model.status = "Eyedropper: #\(hex)" })
            }
            return .done(["ok": true, "result": .bool(c.canvas.eyedropper != nil)])
        }
    }

    /// A canvas came to be.
    static func register(_ c: CanvasViewController) {
        canvases.removeAll { $0.controller == nil }
        canvases.append(WeakCanvas(controller: c))
    }

    /// The canvas of the key document window, else of the active presentation's window.
    static var current: CanvasViewController? {
        let live = canvases.compactMap(\.controller)
        if let key = NSApp.keyWindow, let c = live.first(where: { $0.view.window === key }) { return c }
        let uid = AppController.shared?.model.session.activeDoc?.uid
        return live.first { $0.document?.uid == uid && $0.view.window != nil } ?? live.first { $0.view.window != nil }
    }

    /// The canvas showing `window`'s presentation.
    static func canvas(in window: NSWindow?) -> CanvasViewController? {
        canvases.compactMap(\.controller).first { $0.view.window === window }
    }

    private static func rect(_ r: CGRect, _ w: NSWindow) -> JSON {
        let h = w.contentView?.bounds.height ?? w.frame.height
        return [.num(r.minX), .num(h - r.maxY), .num(r.width), .num(r.height)]
    }

    // MARK: Hooks for other areas

    /// Start the Eyedropper on the current canvas: the next click on the slide hands the colour under it
    /// (`RRGGBB`) to `deliver` (a colour menu applies it its own way). Esc, a right click or a click off the
    /// canvas cancels. False when no canvas could start it (the status bar says why).
    @discardableResult
    static func eyedropper(_ deliver: @escaping @MainActor (String) -> Void) -> Bool {
        guard let c = current else { return false }
        c.canvas.beginEyedropper(.color(deliver))
        return c.canvas.eyedropper != nil
    }

    /// Picture Format › Color › Set Transparent Color: the next click on the selected picture makes the
    /// colour under it transparent.
    @discardableResult
    static func setTransparentColor() -> Bool {
        guard let c = current else { return false }
        c.canvas.beginEyedropper(.transparentColor)
        return c.canvas.eyedropper != nil
    }

    /// The overlay slot over `window`'s canvas for the animation preview: a view that never takes the
    /// pointer, the slide's rect in it (y down) and points per slide point. Show it while the preview plays
    /// and hide it after; `canvasLayoutChanged` says when the slide moved.
    static func previewOverlay(in window: NSWindow?) -> (view: NSView, slideRect: CGRect, scale: Double)? {
        guard let c = canvas(in: window), let r = c.slideRectInOverlay else { return nil }
        return (c.showOverlay, r, c.scale)
    }
}
