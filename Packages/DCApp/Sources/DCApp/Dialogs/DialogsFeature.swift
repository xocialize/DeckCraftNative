// DCApp — the dialogs, sheets and panels: deckcraft's 41 dialogs, the File backstage as native sheets and
// windows, Settings, the command palette, Find and Replace, toasts, the file panels the engine asks for, and
// the `ui.dialog.*` control methods (`dialogs.rs`, `backstage.rs`, `settings.rs`, `menus.rs`' palette,
// `toast.rs`, the dialog arms of `lib.rs` and `control.rs`; MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). The logic is `DialogController` in DCAppModel; this file wires it into the app.
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine

@MainActor
enum DialogsFeature {
    static var controller: DialogController?
    static var presenter: DialogPresenter?
    static var menuTarget: DialogsMenuTarget?
    private static var observers: [any NSObjectProtocol] = []

    static func install(_ app: AppController) {
        let controller = DialogController(model: app.model)
        let presenter = DialogPresenter(controller: controller)
        controller.services = presenter
        controller.fontFamiliesProvider = { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") } }
        controller.didChange = { [weak presenter] in presenter?.sync() }
        self.controller = controller
        self.presenter = presenter
        observe(controller, presenter)

        for id in DialogController.commands {
            app.handle([id]) { p in controller.uiCommand(id, p) ?? .failure(CommandError("unknown UI command `\(id)`")) }
        }
        app.onRequest { controller.request($0) }

        // Control channel: deckcraft's `ui.dialog.open {id, fields}` and `ui.dialog.close`, and what drives
        // an open dialog without pixels: `list`, `get`, `set {fields}`, `press {button}`.
        app.control(["ui.dialog.open"]) { p in
            guard let id = p["id"]?.asStr else { return err("missing `id`") }
            var fields: [String: String] = [:]
            for e in p["fields"]?.asObject?.entries ?? [] { fields[e.key] = e.value.asStr ?? JSONWriter().string(e.value) }
            controller.open(id, params: p["params"] ?? .null, fields: fields)
            return ok(controller.describe())
        }
        app.control(["ui.dialog.close"]) { _ in
            controller.cancel()
            return ok(.null)
        }
        app.control(["ui.dialog.list"]) { _ in
            ok(["open": controller.current.map { .string($0.id) } ?? .null, "ids": .array(DialogCatalog.ids.map { .string($0) })])
        }
        app.control(["ui.dialog.get"]) { _ in ok(controller.describe()) }
        app.control(["ui.dialog.set"]) { p in
            guard controller.current != nil else { return err("no dialog is open") }
            guard let fields = p["fields"]?.asObject else { return err("missing `fields`") }
            for e in fields.entries { controller.set(e.key, e.value.asStr ?? (e.value.asBool.map { $0 ? "1" : "0" } ?? JSONWriter().string(e.value))) }
            return ok(controller.describe())
        }
        app.control(["ui.dialog.press"]) { p in
            guard controller.current != nil else { return err("no dialog is open") }
            guard let b = p["button"]?.asStr ?? p["id"]?.asStr else { return err("missing `button`") }
            guard controller.press(b) else { return err("the dialog has no button `\(b)`") }
            return ok(["dialog": controller.describe(), "status": controller.model.status.map { .string($0) } ?? .null])
        }
        app.control(["ui.palette"]) { p in
            if p["open"]?.asBool == false { controller.palette = nil } else if controller.palette == nil { controller.palette = PaletteState() }
            if let q = p["query"]?.asStr { controller.palette?.query = q }
            if p["run"]?.asBool == true { controller.paletteRun() }
            return ok(["open": .bool(controller.palette != nil), "items": .array(controller.paletteItems.prefix(20).map { .string($0.id) })])
        }
        app.inspect("dialog") { controller.current.map { .string($0.id) } ?? .null }
        app.inspect("palette") {
            controller.palette.map { ["query": .string($0.query), "shown": .bool(presenter.palettePanel?.isVisible ?? false)] } ?? .null
        }

        // Settings live in `prefs.json` beside `ui.json` (`settings.rs`).
        if !AppDelegate.noPrefs, let prefs = DialogSettings.loadPrefs(app.supportDirectory) { app.model.session.prefs = prefs }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !AppDelegate.noPrefs { DialogSettings.savePrefs(app.model.session.prefs, to: app.supportDirectory) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .deckCraftModelChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                controller.noteMissingFonts()
                applyAppearance(app.model.ui.brightness)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                applyAppearance(app.model.ui.brightness)
                let target = DialogsMenuTarget(app: app)
                menuTarget = target
                target.install()
            }
        })
    }

    static func ok(_ v: JSON) -> ControlOutcome { .done(["ok": true, "result": v]) }
    static func err(_ e: String) -> ControlOutcome { .done(["ok": false, "error": .string(e)]) }

    /// The palette and the toast follow the controller.
    static func observe(_ controller: DialogController, _ presenter: DialogPresenter) {
        withObservationTracking {
            _ = controller.palette
            _ = controller.toast
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    presenter.syncPalette()
                    presenter.syncToast()
                    observe(controller, presenter)
                }
            }
        }
    }

    /// View › Dark and Settings › Appearance: the app's appearance (`system` follows macOS).
    static func applyAppearance(_ b: Brightness) {
        let want: NSAppearance? = switch b {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != want?.name { NSApp.appearance = want }
    }
}

/// Menu items for dialogs the menu tree has no entry for (Hyperlink ⌘K, Header and Footer, Custom Shows…),
/// added beside the tree's items at launch so the shared menu files stay as they are. Each runs its command
/// through `AppModel.run`.
@MainActor
final class DialogsMenuTarget: NSObject {
    let app: AppController
    init(app: AppController) { self.app = app }

    struct Entry {
        var menu: String
        var after: String?
        var title: String
        var command: String
        var params: JSON
        var key: String = ""
        var mods: NSEvent.ModifierFlags = [.command]
    }

    static let entries: [Entry] = [
        Entry(menu: "File", after: "file.new", title: String(localized: "New from Template…", bundle: .module), command: "app.backstage", params: ["page": "new"], key: "n", mods: [.command, .option]),
        Entry(menu: "File", after: "file.properties", title: String(localized: "Properties…", bundle: .module), command: "app.backstage", params: ["page": "info"]),
        Entry(menu: "Edit", after: "app.replace", title: String(localized: "Spelling…", bundle: .module), command: "app.dialog", params: ["id": "spelling"]),
        Entry(menu: "Edit", after: "app.replace", title: String(localized: "Accessibility Checker…", bundle: .module), command: "app.dialog", params: ["id": "accessibility"]),
        Entry(menu: "Edit", after: "app.replace", title: String(localized: "Language…", bundle: .module), command: "app.dialog", params: ["id": "language"]),
        Entry(menu: "Insert", after: "insert.slideNumber", title: String(localized: "Hyperlink…", bundle: .module), command: "app.dialog", params: ["id": "hyperlink"], key: "k"),
        Entry(menu: "Insert", after: "insert.slideNumber", title: String(localized: "Header and Footer…", bundle: .module), command: "app.dialog", params: ["id": "headerFooter"]),
        Entry(menu: "Insert", after: "insert.slideNumber", title: String(localized: "Symbol…", bundle: .module), command: "app.dialog", params: ["id": "symbol"]),
        Entry(menu: "Insert", after: "insert.slideNumber", title: String(localized: "Equation…", bundle: .module), command: "app.dialog", params: ["id": "equation"]),
        Entry(menu: "Insert", after: "insert.chart", title: String(localized: "SmartArt…", bundle: .module), command: "app.dialog", params: ["id": "smartart"]),
        Entry(menu: "Insert", after: "slide.duplicate", title: String(localized: "Slides from Outline…", bundle: .module), command: "app.dialog", params: ["id": "outline"]),
        Entry(menu: "Insert", after: "slide.duplicate", title: String(localized: "Reuse Slides…", bundle: .module), command: "app.reuseSlidesDialog", params: [:]),
        Entry(menu: "Format", after: "format.paragraphDialog", title: String(localized: "Bullets and Numbering…", bundle: .module), command: "app.dialog", params: ["id": "bullets"]),
        Entry(menu: "Format", after: "format.paragraphDialog", title: String(localized: "Columns…", bundle: .module), command: "format.columns", params: [:]),
        Entry(menu: "Format", after: "format.paragraphDialog", title: String(localized: "Replace Fonts…", bundle: .module), command: "app.dialog", params: ["id": "replaceFonts"]),
        Entry(menu: "Slide Show", after: "show.setup", title: String(localized: "Custom Shows…", bundle: .module), command: "app.dialog", params: ["id": "customShow"]),
        Entry(menu: "Help", after: "app.palette", title: String(localized: "Command Palette…", bundle: .module), command: "app.palette", params: [:]),
    ]

    func install() {
        guard let main = NSApp.mainMenu else { return }
        for e in Self.entries.reversed() {
            guard let menu = main.items.first(where: { $0.title == L10n.menuTitle(e.menu) })?.submenu else { continue }
            if e.title == String(localized: "Properties…", bundle: .module), let old = menu.items.first(where: { ($0.representedObject as? String) == "file.properties" }) {
                // The tree's Properties runs the engine's query, which has nothing to show: open the sheet instead.
                retarget(old, e)
                continue
            }
            if e.command == "app.palette", menu.items.contains(where: { ($0.representedObject as? String) == "app.palette" }) { continue }
            if menu.items.contains(where: { $0.title == e.title }) { continue }
            let item = NSMenuItem(title: e.title, action: #selector(run(_:)), keyEquivalent: e.key)
            item.keyEquivalentModifierMask = e.mods
            item.target = self
            item.representedObject = Box(e)
            let at = e.after.flatMap { a in menu.items.firstIndex { ($0.representedObject as? String) == a } }.map { $0 + 1 } ?? menu.items.count
            menu.insertItem(item, at: at)
        }
    }

    private func retarget(_ item: NSMenuItem, _ e: Entry) {
        item.title = e.title
        item.target = self
        item.action = #selector(run(_:))
        item.representedObject = Box(e)
    }

    @objc func run(_ sender: Any?) {
        guard let e = ((sender as? NSMenuItem)?.representedObject as? Box)?.entry else { return }
        app.model.run(e.command, e.params)
    }

    final class Box: NSObject {
        let entry: Entry
        init(_ e: Entry) { entry = e }
    }
}
