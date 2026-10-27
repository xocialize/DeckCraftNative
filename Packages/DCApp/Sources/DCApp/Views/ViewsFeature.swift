// DCApp — the Views area: the slide navigator, Slide Sorter, Outline and Notes Page views, the notes pane,
// the status bar, New Window, printing, and the pasteboard (deckcraft `thumbs.rs`, `sorter.rs`, `notes.rs`,
// `status.rs`, `doc_window.rs`, `apps/deckcraft/src/pasteboard.rs`, `print_pdf`). The window's composition
// is `DocumentWindowController`. This registers the area's UI commands, the Edit menu's pasteboard
// routing, and its `ui.inspect` keys.
import AppKit
import DCAppModel
import DCCore
import DCEngine

@MainActor
enum ViewsFeature {
    /// View › New Window's window (one at a time, as deckcraft's).
    static var docWindow: DocViewerWindowController?
    private static var observer: (any NSObjectProtocol)?
    /// The presentations each model had open at its last change, so only the ones it closed lose their
    /// thumbnails (the cache is shared; another model's presentations, as in tests, keep theirs).
    private static var openDocs: [ObjectIdentifier: Set<UInt64>] = [:]

    static func install(_ app: AppController) {
        let model = app.model
        app.handle(["view.newWindow"]) { p in newWindow(model, p) }
        app.handle(["app.print"]) { p in
            Printer.command(model, p, window: documentWindow(model))
        }
        for id in ["edit.cut", "edit.copy", "edit.paste", "edit.pasteText", "edit.selectAll"] {
            app.handleMenu([id]) { p in PasteboardBridge.shared.menuCommand(model, id, p) }
        }
        app.inspect("thumbsScroll") { .double(model.ui.thumbsScroll) }
        app.inspect("docWindow") {
            guard let w = docWindow else { return ["open": false] }
            return ["open": true, "slide": .integer(w.state.slide), "title": .string(w.window?.title ?? "")]
        }
        app.inspect("views") { inspect(model) }
        if let old = observer { NotificationCenter.default.removeObserver(old) }
        observer = NotificationCenter.default.addObserver(forName: .deckCraftModelChanged, object: app, queue: .main) { _ in
            MainActor.assumeIsolated { modelChanged(model) }
        }
    }

    /// After every command: Copy and Cut from anywhere reach the pasteboard; the extra window follows
    /// its presentation; closed presentations drop their thumbnails.
    static func modelChanged(_ model: AppModel) {
        PasteboardBridge.shared.flushPending(model)
        docWindow?.refresh()
        let open = Set(model.session.documents.map(\.uid))
        for uid in openDocs[ObjectIdentifier(model), default: []].subtracting(open) { Thumbnails.shared.drop(uid) }
        openDocs[ObjectIdentifier(model)] = open
    }

    /// `ui.inspect`'s `views`: what the active window's Views area shows.
    static func inspect(_ model: AppModel) -> JSON {
        guard let wc = documentWindow(model)?.windowController as? DocumentWindowController else { return .null }
        let ed = wc.editor
        var o = JSONObject()
        o.set("area", .string(ed.shown?.rawValue ?? ""))
        o.set("sidebar", .string(wc.sidebarItem.isCollapsed ? "none" : (wc.sidebar.current === wc.outline ? "outline" : "navigator")))
        o.set("navigatorRows", .integer(wc.navigator.items.count))
        o.set("notesPane", ed.notes.view.isHidden || ed.shown != .normal ? .null : .string(ed.notes.editor.textView.string))
        if ed.shown == .notesPage {
            let tv = ed.notesPage.editor.textView
            o.set("notesPage", ["text": .string(tv.string), "frame": [.double(tv.frame.minX), .double(tv.frame.minY), .double(tv.frame.width), .double(tv.frame.height)]])
        }
        if ed.shown == .sorter { o.set("sorterGroups", .integer(ed.sorter.groups.count)) }
        return .object(o)
    }

    /// The window of the active presentation (a print sheet goes on it).
    static func documentWindow(_ model: AppModel) -> NSWindow? {
        let uid = model.session.activeDoc?.uid
        return NSApp.windows.first { w in
            (w.windowController as? DocumentWindowController)?.presentation?.uid == uid && w.isVisible
        } ?? NSApp.mainWindow
    }

    /// `view.newWindow` (`doc_window::command`).
    static func newWindow(_ model: AppModel, _ p: JSON) -> Result<JSON, CommandError> {
        switch DocWindowLogic.command(p, current: docWindow?.state, active: model.session.activeDoc) {
        case .failure(let e): return .failure(e)
        case .success((nil, let answer)):
            docWindow?.close()
            docWindow = nil
            return .success(answer)
        case .success((let state?, let answer)):
            if let w = docWindow, w.state.uid == state.uid {
                w.update(state)
            } else {
                docWindow?.close()
                let w = DocViewerWindowController(model: model, state: state)
                w.onClose = { [weak w] in if docWindow === w { docWindow = nil } }
                docWindow = w
                w.showWindow(nil)
            }
            return .success(answer)
        }
    }
}
