// DCApp — the start window: a window of its own (not a document window) hosting `StartView`, with its search
// field in the toolbar. Esc closes it, ⌘F focuses the search, and closing it tells the model. It closes when a
// presentation opens or is created, and File › New from Template…, the QAT's Home button and `app.backstage`
// bring it back. Not a port: deckcraft's start screen is File › Home in the document window
// (Docs/plans/Ribbon-and-StartScreen.md §7).
import AppKit
import DCAppModel
import SwiftUI

@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate {
    let model: StartScreenModel
    let art: StartArt

    init(model: StartScreenModel, art: StartArt) {
        self.model = model
        self.art = art
        let window = StartWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Start", bundle: .module, comment: "The start window's title (new and recent presentations)")
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        let hosting = NSHostingController(rootView: StartView(model: model, art: art))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.center()
        window.setFrameAutosaveName("DeckCraftStartWindow")
        super.init(window: window)
        window.delegate = self
        window.model = model
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { model.windowClosed() }
}

/// Esc and ⌘F, which reach the window before the menu bar does.
final class StartWindow: NSWindow {
    weak var model: StartScreenModel?

    override func cancelOperation(_ sender: Any?) {
        model?.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            model?.focusSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
