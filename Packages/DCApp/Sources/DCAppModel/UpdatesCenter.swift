// DCAppModel — Help › Check for Updates… and the daily automatic check, without a window: what is being checked,
// what was found, the download, and the preferences. The update window (DCApp/Updates) draws `phase`.
// Behaviour from craft-update's `Updater` (storytold/craft-libs @495e5971, `crates/update/src/updater.rs`) as
// deckcraft uses it (`crates/ui-egui/src/updates_ui.rs`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors): a requested check reports its outcome either way; an automatic check speaks only when it finds
// a newer release; a request made while an automatic check runs is not lost. deckcraft checks once at every
// start and installs in place; here the automatic check is a preference, off by default, at most daily, and the
// update is the notarized DMG, downloaded and opened for the user to drag to Applications.
import Foundation
import Observation

/// The automatic-check preferences, in the app's user defaults.
public struct UpdatePreferences: @unchecked Sendable {
    public static let automaticKey = "DCUpdatesCheckAutomatically"
    public static let lastCheckKey = "DCUpdatesLastCheck"
    public static let skippedKey = "DCUpdatesSkippedVersion"
    /// At most one automatic check a day.
    public static let interval: TimeInterval = 24 * 60 * 60

    // UserDefaults is thread-safe; it isn't marked Sendable.
    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Check for updates once a day without being asked. Off by default.
    public var checksAutomatically: Bool {
        get { defaults.bool(forKey: Self.automaticKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    /// When the last automatic check finished.
    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    /// A version the user chose to skip: automatic checks don't offer it (a requested check still does).
    public var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.skippedKey) }
    }

    /// Whether an automatic check is due at `now`: switched on, and never run, or run a day ago or more (or in
    /// the future: the clock moved back).
    public func isDue(_ now: Date) -> Bool {
        guard checksAutomatically else { return false }
        guard let last = lastCheck else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= Self.interval || elapsed < 0
    }
}

@MainActor
@Observable
public final class UpdateCenter {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate(current: String)
        case failed(UpdateError)
        /// A newer release; `release.installer` is its DMG, or nil (then the window offers its page).
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        /// Downloaded to `file` and opened.
        case downloaded(UpdateRelease, file: URL)
        case downloadFailed(UpdateRelease, UpdateError)
    }

    public internal(set) var phase: Phase = .idle
    /// The download's progress, while there is one.
    public private(set) var progress: Progress?

    @ObservationIgnored public var checker: UpdateChecker
    @ObservationIgnored public let preferences: UpdatePreferences
    @ObservationIgnored public var downloadsDirectory: URL
    @ObservationIgnored public var downloadSession: URLSession
    /// Show the update window (a requested check, or an automatic one that found something).
    @ObservationIgnored public var onPresent: (@MainActor () -> Void)?
    /// Open the downloaded DMG.
    @ObservationIgnored public var onDownloaded: (@MainActor (URL) -> Void)?
    /// Mirrors `checksAutomatically` for the window's checkbox.
    public var checksAutomatically: Bool {
        didSet { preferences.checksAutomatically = checksAutomatically }
    }

    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var checkIsManual = false
    @ObservationIgnored private var download: URLSessionDownloadTask?
    @ObservationIgnored private var generation = 0

    public init(checker: UpdateChecker = UpdateChecker(), preferences: UpdatePreferences = UpdatePreferences(),
                downloadsDirectory: URL = UpdateDownloader.downloadsDirectory, downloadSession: URLSession = .shared) {
        self.checker = checker
        self.preferences = preferences
        self.downloadsDirectory = downloadsDirectory
        self.downloadSession = downloadSession
        checksAutomatically = preferences.checksAutomatically
    }

    public var isChecking: Bool { check != nil }

    /// Help › Check for Updates… (`request_check`): check and report the outcome either way. While a download
    /// runs or has finished, the window shows it again instead.
    public func checkNow() {
        switch phase {
        case .downloading, .downloaded:
            onPresent?()
            return
        default:
            break
        }
        checkIsManual = true
        if check == nil { start() }   // a request during an automatic check takes over its result
        phase = .checking
        onPresent?()
    }

    /// The automatic check (`check_at_start`, daily): when it's due, check quietly.
    public func checkAutomaticallyIfDue(now: Date = Date()) {
        guard check == nil, preferences.isDue(now) else { return }
        switch phase {
        case .idle, .upToDate, .failed: break
        default: return   // something is already on offer or downloading
        }
        checkIsManual = false
        start()
    }

    private func start() {
        generation += 1
        let gen = generation
        let checker = checker
        check = Task { [weak self] in
            let result = await checker.check()
            self?.finish(result, generation: gen)
        }
    }

    /// The check's outcome (`tick`).
    func finish(_ result: UpdateCheckResult, generation gen: Int) {
        guard gen == generation else { return }
        check = nil
        let manual = checkIsManual
        checkIsManual = false
        if !manual { preferences.lastCheck = Date() }
        switch result {
        case .available(let release):
            if !manual, let skipped = preferences.skippedVersion, skipped == release.versionLabel { return }
            phase = .available(release)
            if !manual { onPresent?() }
        case .upToDate(let current, _):
            if manual { phase = .upToDate(current: current) }
        case .failed(let error):
            // An automatic check stays quiet when it fails (the network may simply be off).
            if manual { phase = .failed(error) }
        }
    }

    /// Download the offered release's DMG, then open it.
    public func downloadUpdate() {
        guard case .available(let release) = phase, let asset = release.installer, download == nil else { return }
        phase = .downloading(release)
        let task = UpdateDownloader.start(asset, into: downloadsDirectory, session: downloadSession) { [weak self] result in
            Task { @MainActor in self?.downloadFinished(release, result) }
        }
        download = task
        progress = task.progress
    }

    func downloadFinished(_ release: UpdateRelease, _ result: Result<URL, UpdateError>) {
        download = nil
        progress = nil
        switch result {
        case .success(let file):
            phase = .downloaded(release, file: file)
            onDownloaded?(file)
            onPresent?()
        case .failure(.cancelled):
            phase = .available(release)
        case .failure(let error):
            phase = .downloadFailed(release, error)
            onPresent?()
        }
    }

    /// After a failed download: try it again.
    public func retryDownload() {
        guard case .downloadFailed(let release, _) = phase else { return }
        phase = .available(release)
        downloadUpdate()
    }

    /// Stop the download; the release stays on offer.
    public func cancelDownload() { download?.cancel() }

    /// Don't offer this release again automatically.
    public func skip() {
        if case .available(let release) = phase { preferences.skippedVersion = release.versionLabel }
        dismiss()
    }

    /// The window closed (Later): forget the outcome. A download carries on and reports when done.
    public func dismiss() {
        switch phase {
        case .downloading: return
        default: phase = .idle
        }
        if check != nil {
            // A check the user walked away from is dropped (an automatic one starts again when due).
            check?.cancel()
            check = nil
            checkIsManual = false
            generation += 1
        }
    }
}
