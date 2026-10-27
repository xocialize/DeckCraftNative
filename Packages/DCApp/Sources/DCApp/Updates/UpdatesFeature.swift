// DCApp — Help › Check for Updates… (`app.checkUpdates`) and the daily automatic check: the `UpdateCenter` from
// DCAppModel, its window, and opening the downloaded DMG. deckcraft's `crates/ui-egui/src/updates_ui.rs` and the
// `enable_update_checks` call in `apps/deckcraft/src/main.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), done the Mac way: no in-place install, the notarized DMG opens in Finder.
import AppKit
import DCAppModel
import DCAutomation
import DCCore

@MainActor
enum UpdatesFeature {
    static private(set) var center: UpdateCenter?
    static private(set) var window: UpdatesWindowController?
    private static var timer: Timer?

    /// First automatic check this long after launch, then a look every hour (it runs when a day has passed).
    static let firstCheckDelay: TimeInterval = 10
    static let pollInterval: TimeInterval = 60 * 60

    static func install(_ app: AppController) {
        let center = UpdateCenter(checker: UpdateChecker(source: source()))
        center.onPresent = { present() }
        center.onDownloaded = { file in NSWorkspace.shared.open(file) }
        self.center = center
        // A new app (tests make many) replaces the window; the old center is left as it is.
        window?.window?.delegate = nil
        window?.close()
        window = nil

        // A control-channel call answers at once; the window is non-modal.
        app.handle(["app.checkUpdates"]) { _ in
            center.checkNow()
            return .success(.null)
        }
        app.inspect("updates") { inspect(center) }
        // `ui.updates {action}`: the window's buttons without pixels (check, download, cancel, retry, skip, later);
        // answers with `ui.inspect`'s `updates`.
        app.control(["ui.updates"]) { p in
            switch p["action"]?.asStr ?? "" {
            case "": break
            case "check": center.checkNow()
            case "download": center.downloadUpdate()
            case "cancel": center.cancelDownload()
            case "retry": center.retryDownload()
            case "skip":
                center.skip()
                window?.close()
            case "later":
                window?.close()
                center.dismiss()
            case let a: return .done(["ok": false, "error": .string("unknown action `\(a)`")])
            }
            return .done(["ok": true, "result": inspect(center)])
        }
        scheduleAutomaticChecks()
    }

    /// GitHub's releases repo. Debug builds take `DECKCRAFT_UPDATES_FEED=http://127.0.0.1:PORT/…` to try the
    /// flow against a local server (downloads from that origin's `/download/`).
    static func source() -> UpdateSource {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["DECKCRAFT_UPDATES_FEED"], let url = URL(string: text),
           let local = UpdateSource.local(url) {
            return local
        }
        #endif
        return .github()
    }

    /// The automatic check (off by default). Never in scripted runs (`DECKCRAFT_NO_PREFS`), as deckcraft's tests
    /// and web build leave it off.
    static func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard ProcessInfo.processInfo.environment["DECKCRAFT_NO_PREFS"] == nil else { return }
        let first = Timer(timeInterval: firstCheckDelay, repeats: false) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    private static func tick() {
        center?.checkAutomaticallyIfDue()
        let next = Timer(timeInterval: pollInterval, repeats: false) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    static func present() {
        guard let center else { return }
        let w = window ?? UpdatesWindowController(center: center)
        window = w
        w.show()
    }

    /// `ui.inspect`'s `updates`: what the update window shows.
    static func inspect(_ center: UpdateCenter) -> JSON {
        var phase = "idle"
        var release: UpdateRelease?
        var error: UpdateError?
        var file: URL?
        switch center.phase {
        case .idle: break
        case .checking: phase = "checking"
        case .upToDate: phase = "upToDate"
        case .failed(let e): (phase, error) = ("failed", e)
        case .available(let r): (phase, release) = ("available", r)
        case .downloading(let r): (phase, release) = ("downloading", r)
        case .downloaded(let r, let f): (phase, release, file) = ("downloaded", r, f)
        case .downloadFailed(let r, let e): (phase, release, error) = ("downloadFailed", r, e)
        }
        return [
            "phase": .string(phase),
            "current": .string(center.checker.currentVersion),
            "automatic": .bool(center.checksAutomatically),
            "version": release.map { .string($0.versionLabel) } ?? .null,
            "installer": release?.installer.map { .string($0.name) } ?? .null,
            "error": error.map { .string($0.message) } ?? .null,
            "file": file.map { .string($0.path) } ?? .null,
            "windowVisible": .bool(window?.window?.isVisible ?? false),
        ]
    }
}
