// DCAppModel — the update check's data: release versions, GitHub's releases answer, and the DMG to fetch.
// Ported from craft-update (storytold/craft-libs @495e5971, `crates/update/src/version.rs` `parse`/`is_newer` and
// `release.rs` `parse_github_release_list`/`release_from_value` and its URL checks; MIT OR Apache-2.0,
// © ArtCraft Team and the Craft contributors), which deckcraft's Help › Check for Updates… uses
// (`crates/ui-egui/src/updates_ui.rs`). Everything here is untrusted input: sizes are capped, a download must
// point at the releases repo's own downloads, and checksums must look like checksums.
import Foundation

// MARK: - Where releases come from

/// The releases repo and the URLs derived from it.
public struct UpdateSource: Sendable, Equatable {
    /// The public repo DeckCraftNative's releases are published to (`Tools/publish-release.sh`). The one place
    /// it is named in the app.
    public static let releasesRepo = "xocialize/deckcraftnative-releases"

    /// GitHub's releases list, newest first (`GET /repos/<repo>/releases`).
    public var feed: URL
    /// Every installer link must be `<downloadPrefix><tag>/<name>`.
    public var downloadPrefix: String
    /// The releases page: the fallback link, and the prefix a release's own page must have.
    public var releasesPage: String

    public init(feed: URL, downloadPrefix: String, releasesPage: String) {
        self.feed = feed
        self.downloadPrefix = downloadPrefix
        self.releasesPage = releasesPage
    }

    /// GitHub, for `repo`.
    public static func github(_ repo: String = releasesRepo) -> UpdateSource {
        UpdateSource(
            feed: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10") ?? URL(filePath: "/"),
            downloadPrefix: "https://github.com/\(repo)/releases/download/",
            releasesPage: "https://github.com/\(repo)/releases")
    }

    /// A stand-in feed for trying the flow against a local server (debug builds only, `DECKCRAFT_UPDATES_FEED`):
    /// downloads must come from the same origin, under `/download/`.
    public static func local(_ feed: URL) -> UpdateSource? {
        guard let scheme = feed.scheme, ["http", "https"].contains(scheme), let host = feed.host() else { return nil }
        let origin = "\(scheme)://\(host)" + (feed.port.map { ":\($0)" } ?? "")
        return UpdateSource(feed: feed, downloadPrefix: "\(origin)/download/", releasesPage: "\(origin)/releases")
    }
}

// MARK: - Versions

/// A release version: `MAJOR.MINOR.PATCH[-PRE][+BUILD]` as SemVer orders it (craft-update's `semver::Version`).
public struct UpdateVersion: Sendable, Equatable, CustomStringConvertible {
    public var major: UInt64
    public var minor: UInt64
    public var patch: UInt64
    /// Pre-release identifiers (`rc.1` → `["rc", "1"]`); empty for a release.
    public var pre: [String]
    /// Build metadata: kept, never ordered by.
    public var build: String

    public init(_ major: UInt64, _ minor: UInt64, _ patch: UInt64, pre: [String] = [], build: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.pre = pre
        self.build = build
    }

    /// `version::parse`: `v0.5.0`, `0.5.0`, `0.2.0-rc.1`, `1.0.0+abc`, and the two-part `0.5`. Nil otherwise.
    public static func parse(_ text: String) -> UpdateVersion? {
        var t = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let f = t.first, f == "v" || f == "V" { t = t.dropFirst() }
        guard !t.isEmpty, t.utf8.count <= 64 else { return nil }
        var build = ""
        if let plus = t.firstIndex(of: "+") {
            build = String(t[t.index(after: plus)...])
            t = t[..<plus]
            guard build.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(isIdentChar) })
            else { return nil }
        }
        var pre: [String] = []
        if let dash = t.firstIndex(of: "-") {
            let preText = t[t.index(after: dash)...]
            t = t[..<dash]
            let ids = preText.split(separator: ".", omittingEmptySubsequences: false)
            for id in ids {
                guard !id.isEmpty, id.allSatisfy(isIdentChar) else { return nil }
                if id.allSatisfy(\.isASCIIDigit), id.count > 1, id.first == "0" { return nil }
                pre.append(String(id))
            }
        }
        let core = t.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 || core.count == 2 else { return nil }
        var nums: [UInt64] = []
        for part in core {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), part.count == 1 || part.first != "0", let n = UInt64(part)
            else { return nil }
            nums.append(n)
        }
        // `0.5` is `0.5.0`, as craft-update reads platforms that report two parts.
        return UpdateVersion(nums[0], nums[1], nums.count == 3 ? nums[2] : 0, pre: pre, build: build)
    }

    private static func isIdentChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }

    public var isStable: Bool { pre.isEmpty }

    /// SemVer precedence (build metadata ignored).
    public static func precedence(_ a: UpdateVersion, _ b: UpdateVersion) -> ComparisonResult {
        for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)] where x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
        switch (a.pre.isEmpty, b.pre.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (UInt64(x), UInt64(y)) {
            case let (nx?, ny?): return nx < ny ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending    // numeric identifiers sort below alphanumeric ones
            case (nil, .some): return .orderedDescending
            case (nil, nil): return x < y ? .orderedAscending : .orderedDescending   // ASCII order
            }
        }
        if a.pre.count == b.pre.count { return .orderedSame }
        return a.pre.count < b.pre.count ? .orderedAscending : .orderedDescending
    }

    /// `is_newer`: strictly later by precedence.
    public func isNewer(than other: UpdateVersion) -> Bool { Self.precedence(self, other) == .orderedDescending }

    public var description: String {
        "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) + (build.isEmpty ? "" : "+\(build)")
    }
}

// MARK: - Releases

/// One downloadable file of a release.
public struct UpdateAsset: Sendable, Equatable {
    public var name: String
    /// Bytes; 0 when unknown.
    public var size: Int64
    public var url: URL
    /// Lowercase hex SHA-256, when GitHub gave one (`digest`).
    public var sha256: String?

    public init(name: String, size: Int64, url: URL, sha256: String? = nil) {
        self.name = name
        self.size = size
        self.url = url
        self.sha256 = sha256
    }
}

/// A published release.
public struct UpdateRelease: Sendable, Equatable {
    public var tag: String
    public var version: UpdateVersion?
    /// `DeckCraftNative 0.2.0`; the tag when the release has no name.
    public var name: String
    public var publishedAt: Date?
    /// The release's page on GitHub (or the releases page).
    public var page: URL
    /// Release notes (Markdown), capped.
    public var notes: String
    public var prerelease: Bool
    public var assets: [UpdateAsset]

    public init(tag: String, version: UpdateVersion?, name: String, publishedAt: Date?, page: URL, notes: String, prerelease: Bool, assets: [UpdateAsset]) {
        self.tag = tag
        self.version = version
        self.name = name
        self.publishedAt = publishedAt
        self.page = page
        self.notes = notes
        self.prerelease = prerelease
        self.assets = assets
    }

    /// The version to show: the parsed one, else the tag.
    public var versionLabel: String { version?.description ?? tag }

    /// The disk image to download: `DeckCraftNative-<version>.dmg` when there is one, else the only other notarized
    /// `.dmg` (never an `-unnotarized` build). Nil when the release has none: the update window offers the page.
    public var installer: UpdateAsset? {
        let dmgs = assets.filter { a in
            let n = a.name.lowercased()
            return n.hasSuffix(".dmg") && !n.contains("unnotarized")
        }
        let expected = "DeckCraftNative-\(versionLabel).dmg".lowercased()
        return dmgs.first { $0.name.lowercased() == expected } ?? dmgs.first
    }
}

/// Why a check or a download didn't work. `message` is what the update window shows.
public enum UpdateError: Error, Sendable, Equatable {
    /// No connection, a timeout, TLS: URLSession's description.
    case network(String)
    /// GitHub's request limit was reached; checking again works after `until` (when GitHub said).
    case rateLimited(until: Date?)
    /// The server answered with this HTTP status.
    case http(Int)
    /// The answer wasn't a releases list.
    case malformed(String)
    /// The answer, or the download, is bigger than anything legitimate.
    case tooLarge
    /// The download doesn't match the release's checksum or size.
    case corrupt
    /// The download couldn't be saved.
    case file(String)
    /// The user stopped it.
    case cancelled

    public var message: String {
        switch self {
        case .network(let why):
            String(localized: "The update server couldn't be reached: \(why)", bundle: .module)
        case .rateLimited(let until?):
            String(localized: "GitHub's request limit was reached. Try again after \(until.formatted(date: .omitted, time: .shortened)).", bundle: .module)
        case .rateLimited(nil):
            String(localized: "GitHub's request limit was reached. Try again later.", bundle: .module)
        case .http(let status):
            String(localized: "The update server answered with HTTP \(status).", bundle: .module)
        case .malformed(let why):
            String(localized: "The update server's answer couldn't be read (\(why)).", bundle: .module,
                   comment: "The parenthesized part is a technical detail in English.")
        case .tooLarge:
            String(localized: "The update server's answer is too large.", bundle: .module)
        case .corrupt:
            String(localized: "The download is damaged: it doesn't match the release's checksum.", bundle: .module)
        case .file(let why):
            String(localized: "The download couldn't be saved: \(why)", bundle: .module)
        case .cancelled:
            String(localized: "The download was cancelled.", bundle: .module)
        }
    }
}

// MARK: - GitHub's answer

public enum UpdateFeed {
    /// Release notes longer than this are cut (`MAX_NOTES`).
    public static let maxNotes = 64 * 1024
    /// A releases list bigger than this isn't one.
    public static let maxFeedBytes = 4 << 20

    /// `parse_github_release_list`: the newest published release in GitHub's `/releases` answer — not a draft,
    /// with a version, and stable unless `allowPrerelease`. Nil when there is none.
    public static func newest(in data: Data, source: UpdateSource, allowPrerelease: Bool = false) throws(UpdateError) -> UpdateRelease? {
        guard data.count <= maxFeedBytes else { throw .tooLarge }
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) } catch { throw .malformed("not JSON") }
        if let object = any as? [String: Any], let message = object["message"] as? String {
            throw .malformed("GitHub says: \(truncate(message, 200))")
        }
        guard let list = any as? [Any] else { throw .malformed("not a list of releases") }
        var best: UpdateRelease?
        for case let item as [String: Any] in list {
            if item["draft"] as? Bool == true { continue }
            guard let r = release(item, source: source), let v = r.version else { continue }
            if !allowPrerelease && (r.prerelease || !v.isStable) { continue }
            if best?.version.map({ v.isNewer(than: $0) }) ?? true { best = r }
        }
        return best
    }

    /// `release_from_value`: one release, its links checked. Nil without a usable tag.
    static func release(_ v: [String: Any], source: UpdateSource) -> UpdateRelease? {
        guard let tag = v["tag_name"] as? String, !tag.isEmpty, tag.utf8.count <= 64 else { return nil }
        let fallback = URL(string: source.releasesPage) ?? URL(filePath: "/")
        let page = (v["html_url"] as? String).flatMap { safeReleasePage($0, source: source) } ?? fallback
        let assets: [UpdateAsset] = (v["assets"] as? [Any] ?? []).compactMap { any in
            guard let a = any as? [String: Any], let name = a["name"] as? String, validFileName(name),
                  let link = a["browser_download_url"] as? String, downloadURL(link, under: source.downloadPrefix),
                  let url = URL(string: link)
            else { return nil }
            let digest = (a["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            let size = (a["size"] as? NSNumber).map { max(0, $0.int64Value) } ?? 0
            return UpdateAsset(name: name, size: size, url: url, sha256: digest.flatMap { isHex64($0) ? $0.lowercased() : nil })
        }
        let name = (v["name"] as? String).map { truncate($0, 120) }.flatMap { $0.isEmpty ? nil : $0 } ?? tag
        return UpdateRelease(
            tag: tag, version: UpdateVersion.parse(tag), name: name,
            publishedAt: (v["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
            page: page, notes: (v["body"] as? String).map { truncate($0, maxNotes) } ?? "",
            prerelease: v["prerelease"] as? Bool ?? false, assets: assets)
    }

    // MARK: Checks (release.rs)

    /// `valid_file_name`.
    public static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control || "/\\:<>\"|?*".unicodeScalars.contains($0) }
    }

    /// `download_url_under`: `<prefix><tag>/<name>`, two plain segments, nothing that could climb out.
    public static func downloadURL(_ url: String, under prefix: String) -> Bool {
        guard url.hasPrefix(prefix) else { return false }
        let rest = url.dropFirst(prefix.count)
        if rest.contains(where: { $0 == "?" || $0 == "#" || $0 == "\\" }) || containsEncodedSeparator(rest) { return false }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let tag = parts[0], name = String(parts[1])
        return !tag.isEmpty && tag != "." && tag != ".." && tag.utf8.count <= 64 && validFileName(name.removingPercentEncoding ?? name)
    }

    /// `safe_release_html_url`: the releases page or a page under it, with nothing a shell could misread.
    public static func safeReleasePage(_ url: String, source: UpdateSource) -> URL? {
        guard url.utf8.count <= 2000, !url.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }),
              !url.contains(where: { "|&;<>()$`\"'^!*%{}[]".contains($0) })
        else { return nil }
        if url == source.releasesPage { return URL(string: url) }
        guard url.hasPrefix(source.releasesPage + "/") else { return nil }
        let path = url.dropFirst(source.releasesPage.count + 1)
        if path.isEmpty || path.contains(where: { $0 == "?" || $0 == "#" || $0 == "\\" }) { return nil }
        for seg in path.split(separator: "/", omittingEmptySubsequences: false) where seg.isEmpty || seg == "." || seg == ".." {
            return nil
        }
        return URL(string: url)
    }

    static func containsEncodedSeparator(_ s: Substring) -> Bool {
        let lower = s.lowercased()
        return lower.contains("%2f") || lower.contains("%5c")
    }

    static func isHex64(_ s: String) -> Bool { s.utf8.count == 64 && s.allSatisfy(\.isHexDigit) }

    /// `truncate`: at most `max` UTF-8 bytes, on a character boundary, with an ellipsis.
    static func truncate(_ s: String, _ max: Int) -> String {
        guard s.utf8.count > max else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out + "…"
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
