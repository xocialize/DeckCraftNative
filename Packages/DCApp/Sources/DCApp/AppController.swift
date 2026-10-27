// DCApp — the app delegate and the host around `AppModel`: it turns UI commands that need a window into
// AppKit (panels, documents, alerts), keeps one `PresentationDocument` per engine document, and wires the
// menu bar. Adapts deckcraft `apps/deckcraft/src/main.rs` and the window side of `SlideApp` in
// `crates/ui-egui/src/lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted on the main thread after every command: windows redraw from the session.
    public static let deckCraftModelChanged = Notification.Name("DeckCraftModelChanged")
}

/// A UI command's implementation, registered by the app area that owns it.
public typealias UIHandler = @MainActor (JSON) -> Result<JSON, CommandError>
/// A control-channel method that drives the window (`ui.*`, `show.*`, `app.quit`), registered by its area.
public typealias ControlHandler = @MainActor (JSON) -> ControlOutcome

@MainActor
public final class AppController: NSObject, AppHost {
    public static private(set) var shared: AppController?

    public let model: AppModel
    /// Where `ui.json` lives.
    let supportDirectory: URL
    /// Above 0 while a document is being made: the engine has it before NSDocumentController does.
    var syncSuspended = 0

    // MARK: Extension points
    //
    // Each area of the app (Canvas, Inspector, Dialogs, Show, Views, Automation) registers what it handles
    // from its own `<Area>Feature.install`, listed in `Features.swift`, so areas never edit each other's files.

    /// UI commands by id (`run_ui`'s window-side arms).
    var uiHandlers: [String: UIHandler] = [:]
    /// The engine's UI requests: each handler returns true when it took the request.
    var requestHandlers: [@MainActor (UiRequest) -> Bool] = []
    /// Control-channel methods by name (`ControlHost.handleUI`).
    var controlHandlers: [String: ControlHandler] = [:]
    /// Contributions to `ui.inspect`, by key.
    var inspectors: [String: @MainActor () -> JSON] = [:]
    /// Keys the window takes before the engine (the show, animation preview): `ControlHost.interceptKey`.
    var keyInterceptors: [@MainActor (String) -> ControlOutcome?] = []

    /// Register a key interceptor for the control channel's `ui.key` (return nil to let the engine have it).
    public func interceptKeys(_ f: @escaping @MainActor (String) -> ControlOutcome?) { keyInterceptors.append(f) }
    /// How the menu bar and toolbar run a command, where that differs from a script (Paste reads the system
    /// pasteboard): registered by the area that owns it. Scripts and the control channel run the command itself.
    var menuHandlers: [String: UIHandler] = [:]

    /// Register `handler` for the menu bar's and toolbar's `ids`.
    public func handleMenu(_ ids: [String], _ handler: @escaping UIHandler) {
        for id in ids { menuHandlers[id] = handler }
    }

    /// Register `handler` for the UI commands `ids`.
    public func handle(_ ids: [String], _ handler: @escaping UIHandler) {
        for id in ids { uiHandlers[id] = handler }
    }

    /// Register a handler for the engine's UI requests.
    public func onRequest(_ handler: @escaping @MainActor (UiRequest) -> Bool) { requestHandlers.append(handler) }

    /// Register `handler` for the control-channel methods `methods`.
    public func control(_ methods: [String], _ handler: @escaping ControlHandler) {
        for m in methods { controlHandlers[m] = handler }
    }

    /// Add `key` to `ui.inspect`'s answer.
    public func inspect(_ key: String, _ value: @escaping @MainActor () -> JSON) { inspectors[key] = value }

    public init(model: AppModel = AppModel()) {
        self.model = model
        supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "DeckCraftNative") ?? URL(filePath: NSTemporaryDirectory())
        super.init()
        model.host = self
        Self.shared = self
        Features.installAll(self)
    }

    // MARK: AppHost

    public func uiCommand(_ id: String, _ params: JSON) -> Result<JSON, CommandError>? {
        if let h = uiHandlers[id] { return h(params) }
        switch id {
        case "app.openDialog":
            NSDocumentController.shared.openDocument(nil)
            return .success(.null)
        case "app.saveAsDialog":
            guard let d = currentDocument else { return .failure("no presentation is open") }
            d.saveAs(nil)
            return .success(.null)
        case "app.closePresentation":
            guard let d = currentDocument else { return .failure("no presentation is open") }
            d.close()
            return .success(.null)
        case "app.about":
            NSApp.orderFrontStandardAboutPanel(nil)
            return .success(.null)
        default:
            return nil
        }
    }

    public func uiRequest(_ request: UiRequest) {
        for h in requestHandlers where h(request) { return }
        switch request {
        case .pickFile(let purpose):
            model.status = String(localized: "Choosing a \(purpose) file isn't available yet", bundle: .module, comment: "Status message; the placeholder is the engine's file purpose id (picture, audio, video…)")
        default:
            break
        }
    }

    public func modelChanged() {
        syncDocuments()
        NotificationCenter.default.post(name: .deckCraftModelChanged, object: self)
    }

    // MARK: Documents

    /// The document of the key window, else the session's active one.
    var currentDocument: PresentationDocument? {
        if let d = NSDocumentController.shared.currentDocument as? PresentationDocument { return d }
        return documents.first { $0.uid == model.session.activeDoc?.uid }
    }

    var documents: [PresentationDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? PresentationDocument }
    }

    /// One `PresentationDocument` per engine document: documents the engine opened (a command, a script,
    /// the control channel) get a window; documents the engine closed lose theirs.
    func syncDocuments() {
        guard syncSuspended == 0 else { return }
        let live = Set(model.session.documents.map(\.uid))
        for d in documents where d.uid != 0 && !live.contains(d.uid) { d.closeWithoutEngine() }
        let known = Set(documents.map(\.uid))
        syncSuspended += 1
        for st in model.session.documents where !known.contains(st.uid) {
            let d = PresentationDocument(adopting: st.uid)
            NSDocumentController.shared.addDocument(d)
            d.makeWindowControllers()
            d.showWindows()
        }
        syncSuspended -= 1
        for d in documents { d.syncChangeCount() }
    }

    /// Make the engine's active document the one in `window` (a window became key).
    func activate(uid: UInt64) {
        guard let i = model.session.documents.firstIndex(where: { $0.uid == uid }), model.session.activeIndex != i else { return }
        model.session.setActive(i)
        model.changed()
    }

    // MARK: Menu commands

    /// A menu item or toolbar button: its represented object is the command id. The commands AppKit owns
    /// (new, open, save, close) go through NSDocument so the document lifecycle stays native.
    @objc public func runCommand(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue
        guard let id else { return }
        perform(id)
    }

    func perform(_ id: String, _ params: JSON = .object(JSONObject())) {
        switch id {
        case "file.new": NSDocumentController.shared.newDocument(nil)
        case "file.save": currentDocument?.save(nil)
        default:
            if let h = menuHandlers[id] { _ = h(params) } else { model.run(id, params) }
        }
    }
}

/// The application delegate: launch arguments, the menu bar, and saving UI state at quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let launch: Launch
    let controller = AppController()

    init(launch: Launch) {
        self.launch = launch
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !Self.noPrefs { controller.model.ui = UiState.load(from: controller.supportDirectory.appending(path: "ui.json")) }
        NSApp.mainMenu = MenuBuilder.mainMenu(target: controller)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for f in launch.files {
            NSDocumentController.shared.openDocument(withContentsOf: URL(filePath: f), display: true) { _, _, _ in }
        }
        if let port = launch.controlPort { AutomationFeature.start(port: port) }
        if launch.sample {
            do { try Sample.openSample(controller.model.session) } catch { controller.model.status = error.description }
            controller.model.changed()
        }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.noPrefs { controller.model.ui.save(to: controller.supportDirectory.appending(path: "ui.json")) }
    }

    /// AppKit asks only when nothing else (Finder, the command line, `--sample`) opened a document.
    /// `DECKCRAFT_NO_PREFS`: neither read nor write `ui.json` (deckcraft's switch, for tests and scripted runs).
    static var noPrefs: Bool { ProcessInfo.processInfo.environment["DECKCRAFT_NO_PREFS"] != nil }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launch.files.isEmpty && !launch.sample && controller.model.session.documents.isEmpty
    }
}
