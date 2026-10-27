// DCAppModel — the app's single entry point for commands. Port of `SlideApp::run`, `run_ui` (the state-only
// UI commands) and `flag` in deckcraft `crates/ui-egui/src/lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
//
// Every action — a menu item, a toolbar button, a key, the palette, the control channel — goes through
// `AppModel.run`. UI commands that only change UI state are answered here; the ones that need a window
// (dialogs, the show, file pickers, printing, the backstage) go to the `AppHost`; everything else is the
// engine's. The model owns the one `Session` every window shares, as deckcraft's app does.
import DCCore
import DCEngine
import Foundation
import Observation

/// A command's failure: the message the status bar and the control channel show.
public struct CommandError: Error, Equatable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var message: String
    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { message = value }
    public var description: String { message }
}

/// What the model needs from the app around it: everything that opens a window or asks the user.
@MainActor
public protocol AppHost: AnyObject {
    /// A UI command the model doesn't answer itself. nil means "not a command this host knows".
    func uiCommand(_ id: String, _ params: JSON) -> Result<JSON, CommandError>?
    /// The engine asked for UI (a dialog, a pane, the show, a file picker, a message, media playback).
    func uiRequest(_ request: UiRequest)
    /// The documents, the selection or UI state may have changed: views refresh.
    func modelChanged()
}

/// The app's state and command router (`SlideApp`, without the drawing).
@MainActor @Observable
public final class AppModel {
    public let session: Session
    public var ui: UiState
    /// The status bar's message, set by failures and `message` requests.
    public var status: String?
    /// Bumps after every command, so views know to refresh.
    public private(set) var revision: UInt64 = 0
    /// Text a Copy or Cut leaves for the system clipboard (`pending_copy`); the host takes it.
    public var pendingCopy: String?
    /// The canvas's current scale when zoom is "fit" (`canvas_scale`), for Zoom In/Out.
    public var canvasScale: Double = 1
    /// The Thesaurus pane's query (`thesaurus_query`).
    public var thesaurusQuery = ""
    @ObservationIgnored public weak var host: (any AppHost)?

    public init(session: Session = Session(), ui: UiState = UiState()) {
        self.session = session
        self.ui = ui.sanitized()
    }

    /// `run`: one command, by id, from anywhere in the app. Failures go to the status bar too.
    @discardableResult
    public func run(_ id: String, _ params: JSON = .object(JSONObject())) -> Result<JSON, CommandError> {
        let r: Result<JSON, CommandError>
        if UICommands.contains(id) {
            r = runUI(id, params)
        } else {
            do { r = .success(try session.execute(id, params)) } catch { r = .failure(CommandError(error.description)) }
        }
        switch r {
        case .success(let v) where id == "edit.copy" || id == "edit.cut":
            // Copy and Cut from anywhere put the text on the system clipboard, as ⌘C and ⌘X do (#431).
            if let t = v["text"]?.asStr { pendingCopy = t }
        case .success: break
        case .failure(let e): status = e.message
        }
        drainRequests()
        changed()
        return r
    }

    /// Tell views something changed (after work done outside `run`, such as a document opened by the host).
    public func changed() {
        revision &+= 1
        host?.modelChanged()
    }

    /// Hand the engine's UI requests to the host (`drain_requests`).
    func drainRequests() {
        let requests = session.uiRequests
        session.uiRequests.removeAll()
        for r in requests {
            switch r {
            case .message(let text): status = text
            case .pane(let id): ui.pane = id
            default: host?.uiRequest(r)
            }
        }
    }

    /// `flag`: the `on` parameter, or the opposite of `cur`.
    func flag(_ p: JSON, _ cur: Bool) -> Bool { p["on"]?.asBool ?? !cur }

    /// `run_ui`, for the commands that only change UI state; the host gets the rest.
    func runUI(_ id: String, _ p: JSON) -> Result<JSON, CommandError> {
        switch id {
        case "view.normal": ui.view = .normal
        case "view.outline": ui.view = .outline
        case "view.sorter": ui.view = .sorter
        case "view.notesPage": ui.view = .notesPage
        case "view.notes": ui.notes = flag(p, ui.notes)
        case "view.ruler": ui.ruler = flag(p, ui.ruler)
        case "view.gridlines": ui.gridlines = flag(p, ui.gridlines)
        case "view.guides":
            ui.guides = flag(p, ui.guides)
            addDefaultGuidesIfNeeded()
        case "view.gridOptions" where gridOptionsTouched(p):
            return gridOptions(p)
        case "view.zoomIn", "view.zoomOut":
            let cur = ui.zoom ?? canvasScale
            let steps = [0.1, 0.25, 0.33, 0.5, 0.66, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
            ui.zoom = id == "view.zoomIn" ? (steps.first { $0 > cur + 0.01 } ?? 4) : (steps.last { $0 < cur - 0.01 } ?? 0.1)
        case "view.zoom":
            guard let pct = p["percent"]?.asF64 else { return .failure("missing `percent`") }
            let z = Double(Float(pct) / 100)
            ui.zoom = z.isNaN ? 0.1 : Swift.min(Swift.max(z, 0.1), 4)
        case "view.fit": ui.zoom = nil
        case "review.thesaurusPane":
            thesaurusQuery = p["word"]?.asStr ?? ((try? session.execute("review.thesaurus", .object(JSONObject())))?["word"]?.asStr ?? "")
            ui.pane = "thesaurus"
        case "view.pane":
            let pane = p["pane"]?.asStr
            ui.pane = pane != nil && pane == ui.pane && (p["toggle"]?.asBool ?? false) ? nil : pane
            if let tab = p["tab"]?.asStr { ui.formatTab = tab }
        case "view.tab":
            guard let tab = p["tab"]?.asStr else { return .failure("missing `tab`") }
            ui.tab = tab
            ui.ribbonCollapsed = false
        case "view.collapseRibbon": ui.ribbonCollapsed.toggle()
        case "view.dark":
            ui.brightness = flag(p, ui.brightness == .dark) ? .dark : .light
        case "view.grayscale": ui.grayscale = flag(p, ui.grayscale)
        case "show.presenter": ui.presenterView = flag(p, ui.presenterView)
        case "app.links":
            return .success([
                "discord": .string(Links.discord), "website": .string(Links.website), "apps": .string(Links.apps),
                "appPage": .string(Links.appPage), "github": .string(Links.github),
            ])
        default:
            // Everything with a window: the host's. Without a host (tests, headless), say so.
            if let r = host?.uiCommand(id, p) { return r }
            return .failure(CommandError("unknown UI command `\(id)`"))
        }
        return .success(.null)
    }

    /// View › Guides: a presentation without guides gets PowerPoint's two centre guides.
    private func addDefaultGuidesIfNeeded() {
        if ui.guides, let d = session.activeDoc, d.doc.guides.isEmpty {
            _ = try? session.execute("guide.add", ["defaults": true])
        }
    }

    /// `grid_options_touched`: any of the dialog's values given (else the host opens the dialog).
    func gridOptionsTouched(_ p: JSON) -> Bool {
        ["spacing", "snap", "smartGuides", "gridlines", "guides"].contains { p[$0] != nil }
    }

    /// View › Grid Options with values: applied, then all of them answered.
    private func gridOptions(_ p: JSON) -> Result<JSON, CommandError> {
        var spacing: Double?
        if let raw = p["spacing"] {
            guard let n = raw.asF64, n.isFinite else { return .failure("`spacing` must be a finite number of points") }
            guard (1 ... 288).contains(n) else { return .failure("`spacing` must be from 1 to 288 points") }
            spacing = n
        }
        func gridFlag(_ key: String) -> Result<Bool?, CommandError> {
            guard let v = p[key], v != .null else { return .success(nil) }
            guard let b = v.asBool else { return .failure(CommandError("`\(key)` must be true or false")) }
            return .success(b)
        }
        let snap: Bool?, smart: Bool?, gridlines: Bool?, guides: Bool?
        switch (gridFlag("snap"), gridFlag("smartGuides"), gridFlag("gridlines"), gridFlag("guides")) {
        case (.success(let a), .success(let b), .success(let c), .success(let d)): (snap, smart, gridlines, guides) = (a, b, c, d)
        case (.failure(let e), _, _, _), (_, .failure(let e), _, _), (_, _, .failure(let e), _), (_, _, _, .failure(let e)): return .failure(e)
        }
        if let n = spacing { session.prefs.gridSpacing = n }
        if let b = snap { session.prefs.snapToGrid = b }
        if let b = smart {
            session.prefs.smartGuides = b
            ui.smartGuides = b
        }
        if let b = gridlines { ui.gridlines = b }
        if let b = guides {
            ui.guides = b
            addDefaultGuidesIfNeeded()
        }
        return .success([
            "spacing": .double(session.prefs.gridSpacing), "snap": .bool(session.prefs.snapToGrid),
            "smartGuides": .bool(session.prefs.smartGuides), "gridlines": .bool(ui.gridlines), "guides": .bool(ui.guides),
        ])
    }
}
