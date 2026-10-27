// DCApp — the show's windows: the audience's full-screen window on the chosen display (or a window, for Reading
// View, "Browsed by an individual" and the windowed test mode) and presenter view on another display. Keys reach
// the show before any control in its windows (deckcraft's `keyboard`, which consumes them first). deckcraft opens
// presenter view as a second egui viewport on the same monitor (its gap #9); here it goes to the other display
// with `NSScreen`, and with one display the show plays alone, as in PowerPoint.
import AppKit
import DCAppModel
import DCModel
import SwiftUI

/// A window the show owns: it can become key without a title bar and sends keys to the show first.
final class ShowWindow: NSWindow {
    var onKey: (@MainActor (NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let f = onKey, f(event) { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ShowWindows {
    let coord: ShowCoordinator
    let metal: ShowMetal
    private(set) var audience: ShowWindow?
    private(set) var showView: ShowView?
    private(set) var presenterWindow: ShowWindow?
    private(set) var presenter: PresenterModel?
    private var savedOptions: NSApplication.PresentationOptions?
    private var previousKey: NSWindow?
    /// The windowed test mode (`DECKCRAFT_SHOW_WINDOWED=1`, or `show.start {windowed: true}`).
    var windowedNext = false
    static let displayDefaultsKey = "DeckCraftShowDisplay"

    init(coord: ShowCoordinator, metal: ShowMetal) {
        self.coord = coord
        self.metal = metal
    }

    static var envWindowed: Bool { ProcessInfo.processInfo.environment["DECKCRAFT_SHOW_WINDOWED"] == "1" }

    /// The display preference (Set Up Show's monitor): a display name, `automatic` or `primary`.
    static var displayPreference: String {
        get { UserDefaults.standard.string(forKey: displayDefaultsKey) ?? ShowDisplays.automatic }
        set { UserDefaults.standard.set(newValue, forKey: displayDefaultsKey) }
    }

    static func screens() -> [ShowScreen] {
        NSScreen.screens.enumerated().map { ShowScreen(name: $0.element.localizedName, main: $0.offset == 0) }
    }

    // MARK: Open and close

    /// Open the windows of show `s`.
    func open(_ s: ShowController) {
        close()
        previousKey = NSApp.keyWindow
        let doc = coord.showState?.doc
        let windowed = windowedNext || Self.envWindowed || !showFillsScreen(reading: s.reading, showType: doc?.show.showType ?? "speaker")
        windowedNext = false
        let screens = NSScreen.screens
        let (a, p) = ShowDisplays.choose(Self.screens(), preference: Self.displayPreference, presenterView: s.presenter)
        let screen = a.flatMap { screens.at($0) } ?? NSScreen.main
        let view = ShowView(coord: coord, metal: metal)
        let w: ShowWindow
        if windowed {
            // A 16:9 window of about 1280 × 720 in the middle of the document window's display.
            let area = previousKey?.screen?.visibleFrame ?? screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let size = CGSize(width: Swift.min(1280, area.width * 0.9), height: Swift.min(720 + (s.reading ? ShowGeometry.readingBarHeight : 0), area.height * 0.9))
            let base = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            w = ShowWindow(contentRect: base, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.setContentSize(size)
            w.setFrameOrigin(base.origin)
            w.title = s.reading ? "Reading View" : "Slide Show"
        } else {
            let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            w = ShowWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.setFrame(frame, display: false)
            w.level = .mainMenu + 1
            w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            if screen == screens.first {
                savedOptions = NSApp.presentationOptions
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            }
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = view
        w.onKey = { [weak self] e in self?.key(e, presenter: false) ?? false }
        w.delegate = closeWatcher
        audience = w
        showView = view
        // Presenter view on another display; with one display, only in the windowed test mode.
        if s.presenter && !s.reading && (p != nil || windowed) {
            openPresenter(p.flatMap { screens.at($0) }, windowed: windowed || p == nil)
        }
        view.onTick = { [weak self] in self?.presenter?.refresh() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.startClock()
        view.tick()
    }

    private func openPresenter(_ screen: NSScreen?, windowed: Bool) {
        let model = PresenterModel(coord: coord, windows: self)
        let host = NSHostingView(rootView: PresenterView(model: model))
        let frame: CGRect
        let w: ShowWindow
        if !windowed, let sc = screen {
            frame = sc.visibleFrame
            w = ShowWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: sc)
        } else {
            let base = (audience?.frame ?? CGRect(x: 80, y: 80, width: 1100, height: 700)).offsetBy(dx: 40, dy: -40)
            frame = CGRect(x: base.minX, y: base.minY, width: 1100, height: 700)
            w = ShowWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        }
        w.setFrame(frame, display: false)
        w.title = "Presenter View — DeckCraft"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.onKey = { [weak self] e in self?.key(e, presenter: true) ?? false }
        w.delegate = closeWatcher
        presenterWindow = w
        presenter = model
        model.refresh()
        w.orderFront(nil)
    }

    /// Close the show's windows and give the document window back its keyboard.
    func close() {
        showView?.stopClock()
        if let o = savedOptions {
            NSApp.presentationOptions = o
            savedOptions = nil
        }
        for w in [audience, presenterWindow].compactMap({ $0 }) {
            w.delegate = nil
            w.onKey = nil
            w.orderOut(nil)
            w.contentView = nil
        }
        audience = nil
        showView = nil
        presenterWindow = nil
        presenter = nil
        NSCursor.arrow.set()
        if let w = previousKey, w.isVisible { w.makeKeyAndOrderFront(nil) }
        previousKey = nil
    }

    /// Closing a show window: the audience's ends the show; presenter view's closes only itself (and its grid,
    /// which would otherwise hold auto-advance for the rest of the show).
    private lazy var closeWatcher = CloseWatcher { [weak self] w in
        guard let self else { return }
        if w === self.presenterWindow {
            self.coord.show?.presenter = false
            self.coord.show?.presenterGrid = false
            self.presenterWindow = nil
            self.presenter = nil
        } else if w === self.audience {
            self.coord.endShow()
        }
    }

    // MARK: Keys

    /// A key in one of the show's windows (`keyboard`): true when the show took it.
    func key(_ e: NSEvent, presenter: Bool) -> Bool {
        let k = Self.showKey(e)
        if k == .other { return false }
        let f = e.modifierFlags
        let m = ShowMods(command: f.contains(.command), ctrl: f.contains(.control), alt: f.contains(.option), shift: f.contains(.shift))
        let now = ShowCoordinator.now()
        let (handled, keep) = coord.key(k, m, presenter: presenter, now: now)
        if !keep {
            coord.endShow()
            return true
        }
        if handled {
            showView?.handle(ShowOutcome())
            showView?.overlay.needsDisplay = true
            self.presenter?.refresh()
        }
        return handled
    }

    /// The show's name for a key event.
    static func showKey(_ e: NSEvent) -> ShowKey {
        switch e.keyCode {
        case 53: return .escape
        case 124: return .arrowRight
        case 125: return .arrowDown
        case 123: return .arrowLeft
        case 126: return .arrowUp
        case 121: return .pageDown
        case 116: return .pageUp
        case 115: return .home
        case 119: return .end
        case 36, 76: return .enter
        case 51: return .backspace
        case 49: return .space
        default: break
        }
        guard let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return .other }
        let k = ShowKey(name: c)
        return k
    }
}

/// Window close notifications for the show's windows.
@MainActor
final class CloseWatcher: NSObject, NSWindowDelegate {
    let onClose: @MainActor (NSWindow) -> Void
    init(_ onClose: @escaping @MainActor (NSWindow) -> Void) { self.onClose = onClose }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        onClose(w)
    }
}
