// DCAppModel — the start window's state without a window: its page, search, selection and recent list, what
// Return and a double-click do, and what the control channel reports. The window (DCApp/Start) draws it.
// deckcraft's start screen is File › Home with nothing open (`crates/ui-egui/src/backstage.rs`,
// `backstage/files.rs`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors); here it is a
// window of its own, as Docs/plans/Ribbon-and-StartScreen.md §7 describes.
import DCCore
import DCEngine
import Foundation
import Observation

@MainActor @Observable
public final class StartScreenModel {
    public enum Page: String, CaseIterable, Sendable {
        case home, new, open
    }

    /// What Return and the default button do for the selection.
    public enum Action: String, Sendable {
        /// Create the selected tile's presentation (Blank when nothing is selected).
        case create
        /// Open the selected recent presentation.
        case open
        /// Nothing: the selected file is missing.
        case none
    }

    public let model: AppModel
    /// The window is showing.
    public private(set) var isOpen = false
    /// The page shown; it is remembered in `ui.json` and the window reopens on it.
    public var page: Page {
        didSet { model.ui.startPage = page.rawValue }
    }
    /// The search field's text: it filters the tiles and the recent list.
    public var query = ""
    /// The selected tile or recent row (`StartTile.id` or `StartRecent.id`).
    public var selection: String?
    /// Bumped by ⌘F: the window focuses its search field.
    public private(set) var searchFocus: UInt64 = 0
    /// The recent paths, read when the window shows and after a row is removed.
    public private(set) var recentPaths: [String] = []

    /// The recent presentations, newest first (the app's: NSDocumentController's list).
    @ObservationIgnored public var recentSource: @MainActor () -> [String] = { [] }
    /// Remove a path from the recent list (the app's).
    @ObservationIgnored public var forgetRecent: @MainActor (String) -> Void = { _ in }
    /// Open a presentation file (the app's: NSDocumentController). Without it, choosing a recent row fails.
    @ObservationIgnored public var openFile: (@MainActor (String) -> Void)?
    /// Whether a recent file is there.
    @ObservationIgnored public var exists: (String) -> Bool = StartCatalog.recentExists
    /// Called after the window opens or closes.
    @ObservationIgnored public var didChange: (@MainActor () -> Void)?
    /// Answers of `exists` since the list was last read: each file is probed once per reading, as `recent_checked` does.
    @ObservationIgnored private var checked: [String: Bool] = [:]

    public init(model: AppModel) {
        self.model = model
        page = Page(rawValue: model.ui.startPage) ?? .home
    }

    // MARK: Opening and closing

    /// Show the window on `page`, or on the page last used.
    public func show(_ page: Page? = nil) {
        if let page { self.page = page }
        refreshRecents()
        if selection.map({ !items.contains($0) }) ?? false { selection = nil }
        isOpen = true
        didChange?()
    }

    /// Close the window (Esc, Cancel, the close button; a presentation opened or created).
    public func close() {
        guard isOpen else { return }
        isOpen = false
        query = ""
        didChange?()
    }

    /// Note that the window was closed from outside (its close button).
    public func windowClosed() {
        guard isOpen else { return }
        isOpen = false
        query = ""
    }

    /// ⌘F.
    public func focusSearch() { searchFocus &+= 1 }

    /// Read the recent list again. NSDocumentController's list is the truth for files that are there, but it drops
    /// a file that has gone: `UiState.recent` (deckcraft's list, kept in `ui.json`) remembers those where they
    /// were, so they show as "(missing)" until removed. The merged list is written back to `UiState.recent`.
    public func refreshRecents() {
        checked = [:]
        let live = recentSource()
        var merged: [String] = []
        for p in live where !p.isEmpty && !merged.contains(p) { merged.append(p) }
        for (i, p) in model.ui.recent.enumerated() where !merged.contains(p) && !probe(p) {
            merged.insert(p, at: Swift.min(i, merged.count))
        }
        recentPaths = Array(merged.prefix(UiState.recentMax))
        if model.ui.recent != recentPaths { model.ui.recent = recentPaths }
    }

    // MARK: What the pages show

    /// Home's and New's theme tiles: Blank, the themes, the sample.
    public var themeTiles: [StartTile] { StartCatalog.themeTiles(query) }
    /// Home's and New's template tiles.
    public var templateTiles: [StartTile] { StartCatalog.templateTiles(query) }
    /// The recent rows matching the search.
    public var recents: [StartRecent] {
        StartCatalog.recents(recentPaths, query: query) { [self] p in probe(p) }
    }

    /// Every recent row: what File › Open Recent lists.
    public var allRecents: [StartRecent] {
        StartCatalog.recents(recentPaths) { [self] p in probe(p) }
    }

    func probe(_ path: String) -> Bool {
        if let v = checked[path] { return v }
        let v = exists(path)
        checked[path] = v
        return v
    }

    /// AutoRecover holds presentations to recover (Open's Recover Unsaved Presentations).
    public var recoverable: Bool {
        guard model.session.recoveryDir != nil else { return false }
        return !((try? model.session.execute("file.recovery.list", .emptyObject))?.asArray ?? []).isEmpty
    }

    /// The page's items in the order the arrow keys move through them.
    public var items: [String] {
        switch page {
        case .home, .new: (themeTiles + templateTiles).map(\.id) + (page == .home ? recents.map(\.id) : [])
        case .open: recents.map(\.id)
        }
    }

    /// Move the selection `delta` items through the page (the arrow keys), stopping at the ends.
    public func move(_ delta: Int) {
        let list = items
        guard !list.isEmpty else { return }
        guard let cur = selection, let i = list.firstIndex(of: cur) else {
            selection = delta < 0 ? list.last : list.first
            return
        }
        selection = list.at(Swift.min(Swift.max(i + delta, 0), list.count - 1))
    }

    /// The recent row with `id`, if it is one.
    func recent(_ id: String) -> StartRecent? {
        guard id.hasPrefix("recent:") else { return nil }
        let path = String(id.dropFirst(7))
        let (name, folder) = StartCatalog.splitPath(path)
        return StartRecent(path: path, name: name, folder: folder, missing: !probe(path))
    }

    /// What Return does for the selection: Open for a recent row, Create for a tile or nothing selected.
    public var action: Action {
        guard let id = selection, let r = recent(id) else { return .create }
        return r.missing ? .none : .open
    }

    // MARK: Acting

    /// Create or open `id` (a double-click, or Return on the selection; Blank when nothing is selected). A tile
    /// creates its presentation and closes the window. A recent row opens its file, and the window closes when
    /// the presentation appears; a missing one does nothing.
    @discardableResult
    public func activate(_ id: String? = nil) -> Result<JSON, CommandError> {
        let target = id ?? selection ?? "blank"
        if let r = recent(target) {
            if r.missing { return .failure(CommandError("\(r.path) can't be found")) }
            guard let openFile else { return .failure("opening a file needs the app") }
            openFile(r.path)
            return .success(["opened": .string(r.path)])
        }
        let r = StartCatalog.create(target, in: model)
        if case .success = r { close() }
        return r
    }

    /// Remove a recent row (its context menu's Remove from List).
    public func remove(_ path: String) {
        forgetRecent(path)
        model.ui.recent.removeAll { $0 == path }
        checked[path] = nil
        refreshRecents()
        if selection == "recent:\(path)" { selection = nil }
    }

    /// Empty the recent list (File › Open Recent › Clear Menu).
    public func clearRecents() {
        for p in recentPaths { forgetRecent(p) }
        model.ui.recent = []
        refreshRecents()
        if selection?.hasPrefix("recent:") == true { selection = nil }
    }

    /// A presentation appeared (created or opened): the start window has done its job.
    public func presentationOpened() { close() }

    // MARK: Control channel

    /// `ui.inspect`'s `startScreen`.
    public func inspect() -> JSON {
        [
            "open": .bool(isOpen), "page": .string(page.rawValue), "selection": selection.map(JSON.string) ?? .null,
            "query": .string(query), "action": .string(action.rawValue),
            "items": .array(items.map(JSON.string)),
            "recent": .array(allRecents.map {
                ["path": .string($0.path), "name": .string($0.name), "missing": .bool($0.missing)]
            }),
        ]
    }

    /// `ui.startScreen {page?, query?, select?, move?, activate?, remove?, open?}`: drive the window without
    /// pixels, as `ui.dialog.*` drives a dialog. Answers `inspect()` and, after `activate`, what it did.
    public func control(_ p: JSON) -> Result<JSON, CommandError> {
        if p["open"]?.asBool == false {
            close()
            return .success(inspect())
        }
        if let s = p["page"]?.asStr {
            guard let pg = Page(rawValue: s) else { return .failure(CommandError("unknown start page `\(s)`")) }
            show(pg)
        } else if !isOpen || p["open"]?.asBool == true {
            show()
        }
        if let q = p["query"]?.asStr { query = q }
        if let s = p["select"] {
            guard let id = s.asStr else {
                selection = nil
                return .success(inspect())
            }
            guard items.contains(id) else { return .failure(CommandError("the start page shows no `\(id)`")) }
            selection = id
        }
        if let d = p["move"]?.asI64 { move(Int(clamping: d)) }
        if let path = p["remove"]?.asStr { remove(path) }
        if p["activate"]?.asBool == true {
            let state = inspect()
            switch activate() {
            case .success(let v): return .success(["start": state, "result": v, "open": .bool(isOpen)])
            case .failure(let e): return .failure(e)
            }
        }
        return .success(inspect())
    }
}
