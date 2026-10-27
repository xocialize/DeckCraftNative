// DCAppModel — asking the releases repo whether there is a newer DeckCraftNative. One GET of GitHub's releases
// list with URLSession; the answer goes through `UpdateFeed`. Behaviour from craft-update
// (storytold/craft-libs @495e5971, `crates/update/src/lib.rs` `check_for_update` and `http.rs` `refused_until`;
// MIT OR Apache-2.0, © ArtCraft Team and the Craft contributors): 404 means no release yet, a 403 or 429 with
// an exhausted quota or `Retry-After` means "slow down", pre-releases and drafts are never offered.
import Foundation

/// What a check found.
public enum UpdateCheckResult: Sendable, Equatable {
    /// Nothing newer than `current`; `latest` is the newest release, when there is one.
    case upToDate(current: String, latest: String?)
    /// A newer release. `release.installer` is nil when it has no DMG.
    case available(UpdateRelease)
    case failed(UpdateError)
}

public struct UpdateChecker: Sendable {
    public var source: UpdateSource
    /// The running app's version (`DCAppVersion.shown()`).
    public var currentVersion: String
    public var session: URLSession
    /// Offer pre-releases too (off: deckcraft's desktop app never offers them).
    public var allowPrerelease = false

    public init(source: UpdateSource = .github(), currentVersion: String = DCAppVersion.shown(), session: URLSession = .shared) {
        self.source = source
        self.currentVersion = currentVersion
        self.session = session
    }

    /// The request: GitHub's REST API with a User-Agent naming the app, as GitHub asks.
    public var request: URLRequest {
        var r = URLRequest(url: source.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("DeckCraftNative/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Ask, and say what was found. Never throws: every failure is a `.failed`.
    public func check() async -> UpdateCheckResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError where e.code == .cancelled {
            return .failed(.cancelled)
        } catch {
            return .failed(.network(error.localizedDescription))
        }
        return interpret(data, response, now: Date())
    }

    /// The answer's meaning (window-free, so tests feed it directly too).
    public func interpret(_ data: Data, _ response: URLResponse, now: Date) -> UpdateCheckResult {
        guard let http = response as? HTTPURLResponse else { return .failed(.malformed("no HTTP answer")) }
        switch http.statusCode {
        case 200 ..< 300:
            break
        case 404:
            // The repo has no releases (or doesn't exist yet): nothing to offer.
            return .upToDate(current: currentVersion, latest: nil)
        case 403, 429:
            if let until = Self.refusedUntil(http, now: now) { return .failed(.rateLimited(until: until)) }
            return .failed(.http(http.statusCode))
        default:
            return .failed(.http(http.statusCode))
        }
        let newest: UpdateRelease?
        do { newest = try UpdateFeed.newest(in: data, source: source, allowPrerelease: allowPrerelease) } catch {
            return .failed(error)
        }
        guard let newest, let latest = newest.version else { return .upToDate(current: currentVersion, latest: nil) }
        // An unreadable current version (a hand-edited bundle) is treated as older than any release.
        let current = UpdateVersion.parse(currentVersion) ?? UpdateVersion(0, 0, 0)
        return latest.isNewer(than: current) ? .available(newest) : .upToDate(current: currentVersion, latest: latest.description)
    }

    /// `refused_until`: whether a 403/429 means "slow down", and until when. `.some(nil)`: slow down, no time given.
    static func refusedUntil(_ r: HTTPURLResponse, now: Date) -> Date?? {
        func header(_ name: String) -> String? { r.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces) }
        let retry = header("retry-after").flatMap { Int64($0) }.map { now.addingTimeInterval(TimeInterval(max(0, min($0, 86_400)))) }
        if header("x-ratelimit-remaining") == "0" {
            let reset = header("x-ratelimit-reset").flatMap { Int64($0) }.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            switch (reset, retry) {
            case let (a?, b?): return .some(max(a, b))
            case let (a, b): return .some(a ?? b)
            }
        }
        if let retry { return .some(retry) }
        return r.statusCode == 429 ? .some(now.addingTimeInterval(60)) : nil
    }
}
