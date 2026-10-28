// DCApp — the start window's area: the `StartScreenModel` and its window, the recent list from
// NSDocumentController (shared with File › Open Recent, which this area adds), the launch rule, and the control
// channel's `ui.inspect` keys (`home`, `backstage`, `startScreen`), `ui.startScreen` and
// `ui.screenshot {window: "start"}`. deckcraft's start screen is File › Home with nothing open
// (`crates/ui-egui/src/backstage.rs`, `app.rs`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Docs/plans/Ribbon-and-StartScreen.md §7, milestone S1.
import AppKit
import DCAppModel
import DCAutomation
import DCCore

@MainActor
enum StartFeature {
    static var model: StartScreenModel?
    static var window: StartWindowController?
    static var recentMenu: StartRecentMenu?
    static let art = StartArt()
    /// How many presentations were open after the last command: one more means one opened or was created.
    static var documentCount = 0
    private static var observers: [any NSObjectProtocol] = []

    static func install(_ app: AppController) {
        let m = StartScreenModel(model: app.model)
        m.recentSource = { recentPaths() }
        m.forgetRecent = { forget($0) }
        m.openFile = { path in
            NSDocumentController.shared.openDocument(withContentsOf: URL(filePath: path), display: true) { _, _, error in
                if let error { app.model.status = error.localizedDescription }
            }
        }
        m.didChange = { sync() }
        model = m
        DialogsFeature.controller?.startScreen = m

        // `ui.inspect`: deckcraft's `home` and `backstage` are live, and `startScreen` adds the window's state.
        app.inspect("home") { .bool(m.isOpen) }
        app.inspect("backstage") { m.isOpen ? .string(m.page.rawValue) : .null }
        app.inspect("startScreen") {
            m.refreshRecents()
            var o = m.inspect().asObject ?? JSONObject()
            o.set("shown", .bool(window?.window?.isVisible ?? false))
            o.set("openRecent", .array(recentMenuItems().map { ["path": .string($0.path), "title": .string($0.title), "enabled": .bool($0.enabled)] }))
            return .object(o)
        }
        app.control(["ui.startScreen"]) { p in
            switch m.control(p) {
            case .success(let v): return .done(["ok": true, "result": v])
            case .failure(let e): return .done(["ok": false, "error": .string(e.message)])
            }
        }
        // `ui.screenshot {window: "start"}`: the start window, through the Automation area's capture; any other
        // window goes to the handler before this one (the show's, else the document window).
        let previous = app.controlHandlers["ui.screenshot"]
        app.control(["ui.screenshot"]) { p in
            guard p["window"]?.asStr == "start" else { return previous?(p) ?? .screenshot(path: p["path"]?.asStr) }
            guard m.isOpen, let w = window?.window else { return .done(["ok": false, "error": "the start window is not open"]) }
            AutomationFeature.nextCapture = w
            return .screenshot(path: p["path"]?.asStr)
        }

        observers.append(NotificationCenter.default.addObserver(forName: .deckCraftModelChanged, object: app, queue: .main) { _ in
            MainActor.assumeIsolated { modelChanged(app) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { installRecentMenu() }
        })
    }

    /// After every command: a presentation that opened or was created closes the start window.
    static func modelChanged(_ app: AppController) {
        // Only the controller whose model this is (tests make several).
        guard model?.model === app.model else { return }
        let n = app.model.session.documents.count
        if n > documentCount, let m = model {
            m.presentationOpened()
            m.refreshRecents()
        }
        documentCount = n
    }

    /// The window follows the model.
    static func sync() {
        guard let m = model else { return }
        if let wc = window, wc.model !== m {
            // A new app controller (tests make several): the old window draws the old model.
            wc.window?.orderOut(nil)
            window = nil
        }
        if m.isOpen {
            let wc = window ?? StartWindowController(model: m, art: art)
            window = wc
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        } else if let w = window?.window, w.isVisible {
            w.orderOut(nil)
        }
    }

    /// At launch with nothing to open (`AppDelegate.applicationShouldOpenUntitledFile`): the start window, unless
    /// Settings has it off. Answers whether AppKit should make an untitled presentation instead.
    static func atLaunch(files: Int, sample: Bool) -> Bool {
        guard let app = AppController.shared else { return files == 0 && !sample }
        switch StartCatalog.atLaunch(files: files, sample: sample, documents: app.model.session.documents.count, showStartScreen: app.model.ui.showStartScreen) {
        case .nothing: return false
        case .untitled: return true
        case .startWindow:
            model?.show()
            return false
        }
    }

    // MARK: Recent presentations (NSDocumentController's list)

    static func recentPaths() -> [String] {
        NSDocumentController.shared.recentDocumentURLs.filter(\.isFileURL).map { $0.path(percentEncoded: false) }
    }

    /// NSDocumentController can only clear the whole list: clear it and note the others again, oldest first.
    static func forget(_ path: String) {
        let dc = NSDocumentController.shared
        let keep = dc.recentDocumentURLs.filter { $0.path(percentEncoded: false) != path }
        dc.clearRecentDocuments(nil)
        for u in keep.reversed() { dc.noteNewRecentDocumentURL(u) }
    }

    /// File › Open Recent, after Open…: the start window's recent list, then Clear Menu.
    static func installRecentMenu() {
        guard recentMenu == nil, let file = NSApp.mainMenu?.items.first(where: { $0.title == L10n.menuTitle("File") })?.submenu else { return }
        let target = StartRecentMenu()
        recentMenu = target
        let item = NSMenuItem(title: String(localized: "Open Recent", bundle: .module, comment: "File menu: the recent presentations"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: item.title)
        sub.delegate = target
        item.submenu = sub
        let at = file.items.firstIndex { ($0.representedObject as? String) == "app.openDialog" }.map { $0 + 1 } ?? file.items.count
        file.insertItem(item, at: at)
        target.fill(sub)
    }

    /// What File › Open Recent lists (Clear Menu left out), for `ui.inspect`.
    static func recentMenuItems() -> [(path: String, title: String, enabled: Bool)] {
        guard let target = recentMenu else { return [] }
        let menu = NSMenu()
        target.fill(menu)
        return menu.items.compactMap { item in (item.representedObject as? String).map { ($0, item.title, item.action != nil) } }
    }
}

/// File › Open Recent: filled from the same rows as the start window's recent list each time it opens. A
/// missing file is listed, disabled, as "(missing)".
@MainActor
final class StartRecentMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = StartFeature.model else { return }
        model.refreshRecents()
        let rows = model.allRecents
        for r in rows {
            let title = r.missing ? String(localized: "\(r.name) (missing)", bundle: .module, comment: "File › Open Recent: a file that can't be found") : r.name
            let item = NSMenuItem(title: title, action: r.missing ? nil : #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r.path
            item.toolTip = r.path
            item.isEnabled = !r.missing
            menu.addItem(item)
        }
        if !rows.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: String(localized: "Clear Menu", bundle: .module, comment: "File › Open Recent: empties the list"), action: rows.isEmpty ? nil : #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        StartFeature.model?.activate("recent:\(path)")
    }

    @objc func clear(_ sender: Any?) {
        StartFeature.model?.clearRecents()
    }
}
