// DCAppModel — the app's persisted UI state. Port of `UiState` and `ViewMode` in deckcraft
// `crates/ui-egui/src/lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The ribbon is an optional window layout (PLAN.md "Decided", amended 2026-10-27; Docs/plans/Ribbon-and-
// StartScreen.md): `layout` picks it, and `tab` / `ribbonCollapsed` are the tab it shows and whether it is minimised.
// `ui.inspect` reports them and `view.tab` / `view.collapseRibbon` answer in either layout, so scripts written against
// deckcraft keep working.
import Foundation

/// The editor's view (`ViewMode`).
public enum ViewMode: String, Codable, Sendable, CaseIterable {
    case normal, outline, sorter, notesPage, reading
}

/// Light or dark appearance (`theme::Brightness`); `system` follows macOS.
public enum Brightness: String, Codable, Sendable {
    case system, light, dark
}

/// Persisted UI state (`UiState`), saved as `ui.json` in the app's support folder.
public struct UiState: Codable, Sendable, Equatable {
    public var brightness: Brightness = .system
    public var tab = "Home"
    public var ribbonCollapsed = false
    /// The window layout (View › Ribbon, Settings › General). A `ui.json` from before the ribbon reads as the Mac layout.
    public var layout: WindowLayout = .mac
    public var view: ViewMode = .normal
    public var notes = true
    public var notesHeight: Double = 52
    public var thumbsWidth: Double = 236
    /// Vertical scroll offset of the slide navigator, kept for the control channel; not persisted.
    public var thumbsScroll: Double = 0
    /// Open inspector pane: `format`, `animation`, `selection`, `comments`, `designer`, `background`,
    /// `smartart` (Text Pane), `thesaurus`.
    public var pane: String?
    public var paneWidth: Double = 300
    public var ruler = false
    public var gridlines = false
    /// Slides per page previewed in Handout Master view (1, 2, 3, 4, 6 or 9).
    public var handoutPerPage: Int = 6
    public var guides = false
    public var smartGuides = true
    /// nil = fit to window.
    public var zoom: Double?
    public var sorterZoom: Double = 1
    public var recent: [String] = []
    public var presenterView = true
    public var uiScale: Double = 1
    /// Format Shape pane: tab (`fill`, `effects`, `size`, `picture`, `text`).
    public var formatTab = "fill"
    public var grayscale = false
    /// Settings › "Show the start screen when DeckCraftNative opens" (on by default; Ribbon-and-StartScreen §7).
    public var showStartScreen = true
    /// The start window's page (`home`, `new` or `open`): it reopens on the one used last.
    public var startPage = "home"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case brightness, tab, ribbonCollapsed, layout, view, notes, notesHeight, thumbsWidth, pane, paneWidth, ruler, gridlines,
             handoutPerPage, guides, smartGuides, zoom, sorterZoom, recent, presenterView, uiScale, formatTab, grayscale,
             showStartScreen, startPage
    }

    /// Every field optional on the way in (`#[serde(default)]`): a missing or mistyped key keeps its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        let d = UiState()
        brightness = v(.brightness, d.brightness)
        tab = v(.tab, d.tab)
        ribbonCollapsed = v(.ribbonCollapsed, d.ribbonCollapsed)
        layout = v(.layout, d.layout)
        view = v(.view, d.view)
        notes = v(.notes, d.notes)
        notesHeight = v(.notesHeight, d.notesHeight)
        thumbsWidth = v(.thumbsWidth, d.thumbsWidth)
        pane = (try? c.decodeIfPresent(String.self, forKey: .pane)) ?? nil
        paneWidth = v(.paneWidth, d.paneWidth)
        ruler = v(.ruler, d.ruler)
        gridlines = v(.gridlines, d.gridlines)
        handoutPerPage = v(.handoutPerPage, d.handoutPerPage)
        guides = v(.guides, d.guides)
        smartGuides = v(.smartGuides, d.smartGuides)
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)) ?? nil
        sorterZoom = v(.sorterZoom, d.sorterZoom)
        recent = v(.recent, d.recent)
        presenterView = v(.presenterView, d.presenterView)
        uiScale = v(.uiScale, d.uiScale)
        formatTab = v(.formatTab, d.formatTab)
        grayscale = v(.grayscale, d.grayscale)
        showStartScreen = v(.showStartScreen, d.showStartScreen)
        startPage = v(.startPage, d.startPage)
    }

    /// How many recent files File › Open Recent lists (`RECENT_MAX`).
    public static let recentMax = 12
    /// The editor's zoom range (1 = 100 %, `ZOOM_RANGE`).
    public static let zoomRange: ClosedRange<Double> = 0.1 ... 4

    /// The state with every value usable (`sanitized`): `ui.json` is a file on disk, and a damaged or
    /// hand-edited one must not stop the window from opening.
    public func sanitized() -> UiState {
        var s = self
        let d = UiState()
        func within(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? Swift.min(Swift.max(v, lo), hi) : fallback
        }
        s.zoom = zoom.flatMap { $0.isFinite && $0 > 0 ? Swift.min(Swift.max($0, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : nil }
        s.sorterZoom = within(sorterZoom, 0.5, 3, d.sorterZoom)
        s.uiScale = within(uiScale, 0.5, 3, d.uiScale)
        s.notesHeight = within(notesHeight, 0, 2000, d.notesHeight)
        s.thumbsWidth = within(thumbsWidth, 60, 1000, d.thumbsWidth)
        s.paneWidth = within(paneWidth, 240, 520, d.paneWidth)
        if tab.utf8.count > 64 { s.tab = d.tab }
        if formatTab.utf8.count > 64 { s.formatTab = d.formatTab }
        if let p = pane, p.utf8.count > 64 { s.pane = nil }
        if !StartCatalog.pages.contains(startPage) { s.startPage = d.startPage }
        if ![1, 2, 3, 4, 6, 9].contains(handoutPerPage) { s.handoutPerPage = d.handoutPerPage }
        var recent: [String] = []
        for p in self.recent where !p.isEmpty && p.utf8.count <= 4096 && !p.contains("\0") && recent.last != p {
            recent.append(p)
        }
        s.recent = Array(recent.prefix(Self.recentMax))
        return s
    }

    /// Read `ui.json`; a missing or unreadable file gives the defaults.
    public static func load(from url: URL) -> UiState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(UiState.self, from: data) else { return UiState() }
        return s.sanitized()
    }

    /// Write `ui.json` (atomically); failures are ignored, as deckcraft's are.
    public func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
