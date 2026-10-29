// DCAppModelTests — Help › Check for Updates… without a window or a network: versions, GitHub's releases answer,
// the check against a stubbed `URLProtocol` (up to date, newer, pre-release, malformed JSON, no DMG, network
// error, rate limit), the download (a stubbed server and a file URL), the update center's flow and the daily
// automatic check, and the one version number. Behaviour from craft-update (storytold/craft-libs @495e5971,
// `crates/update/src/{version,release,updater,http}.rs` tests; MIT OR Apache-2.0, © ArtCraft Team and the Craft
// contributors) as deckcraft uses it (`crates/ui-egui/src/updates_ui.rs`); Rust names in camelCase.
import CryptoKit
import Foundation
import Testing
@testable import DCAppModel

// MARK: - A stub server

/// Answers requests for one host from a handler, so tests running in parallel never see each other's answers.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case http(Int, [String: String], Data)
        case fail(URLError.Code)
    }

    typealias Handler = @Sendable (URLRequest) -> Answer
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func handler(for host: String) -> Handler? { lock.withLock { handlers[host] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host().map { handler(for: $0) != nil } ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let h = request.url?.host().flatMap(Self.handler(for:)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch h(request) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// A stub host, its session and a source pointing at it.
struct Stub {
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    let session: URLSession

    init(_ handler: @escaping StubProtocol.Handler) {
        StubProtocol.register(host, handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
    }

    var source: UpdateSource {
        UpdateSource(feed: URL(string: "https://\(host)/repos/x/releases") ?? URL(filePath: "/"),
                     downloadPrefix: "https://\(host)/download/", releasesPage: "https://\(host)/releases")
    }

    func checker(_ current: String = "0.1.0") -> UpdateChecker {
        UpdateChecker(source: source, currentVersion: current, session: session)
    }

    /// One release as GitHub's API writes it.
    func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: [String] = [], digest: String? = nil, size: Int = 0) -> String {
        let list = assets.map { name in
            """
            {"name":"\(name)","size":\(size),"browser_download_url":"https://\(host)/download/\(tag)/\(name)"\
            \(digest.map { ",\"digest\":\"sha256:\($0)\"" } ?? "")}
            """
        }
        return """
            {"tag_name":"\(tag)","name":"DeckCraftNative \(tag)","draft":\(draft),"prerelease":\(prerelease),\
            "published_at":"2026-10-27T12:00:00Z","html_url":"https://\(host)/releases/tag/\(tag)",\
            "body":"**Fixes** and [notes](https://example.com).","assets":[\(list.joined(separator: ","))]}
            """
    }
}

func ok(_ json: String, _ headers: [String: String] = [:]) -> StubProtocol.Answer { .http(200, headers, Data(json.utf8)) }

// MARK: - Versions (version.rs)

@Suite struct UpdatesVersionTests {
    // version.rs `reads_tags_and_platform_spellings`
    @Test func readsTagsAndPlatformSpellings() {
        #expect(UpdateVersion.parse("v0.5.0") == UpdateVersion(0, 5, 0))
        #expect(UpdateVersion.parse(" 1.2.3\n") == UpdateVersion(1, 2, 3))
        #expect(UpdateVersion.parse("0.5") == UpdateVersion(0, 5, 0))
        #expect(UpdateVersion.parse("0.2.0-rc.1") == UpdateVersion(0, 2, 0, pre: ["rc", "1"]))
        #expect(UpdateVersion.parse("1.0.0+abc.5") == UpdateVersion(1, 0, 0, build: "abc.5"))
        for bad in ["", "v", "1", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-", "1.2.3-01", "1.2.3+", "1..3", "-1.2.3", String(repeating: "9", count: 70) + ".0.0"] {
            #expect(UpdateVersion.parse(bad) == nil, "\(bad)")
        }
        #expect(UpdateVersion.parse("99999999999999999999.0.0") == nil, "overflow is not a version")
    }

    // version.rs: ordering by precedence, build metadata ignored
    @Test func ordersByPrecedence() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let vs = try ordered.map { try #require(UpdateVersion.parse($0)) }
        for (a, b) in zip(vs, vs.dropFirst()) {
            #expect(b.isNewer(than: a), "\(b) > \(a)")
            #expect(!a.isNewer(than: b))
        }
        let x = try #require(UpdateVersion.parse("1.0.0+a")), y = try #require(UpdateVersion.parse("1.0.0+b"))
        #expect(!x.isNewer(than: y) && !y.isNewer(than: x))
        #expect(x.description == "1.0.0+a")
    }

    /// The one version number: DCAppVersion and every MARKETING_VERSION in the Xcode project agree.
    @Test func appVersionMatchesTheProject() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
        let pbx = try String(contentsOf: root.appending(path: "Apps/DeckCraftNative/DeckCraftNative.xcodeproj/project.pbxproj"), encoding: .utf8)
        let versions = Set(pbx.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "MARKETING_VERSION = ") else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
        })
        #expect(versions == [DCAppVersion.current])
        #expect(UpdateVersion.parse(DCAppVersion.current) != nil)
        #expect(DCAppVersion.shown(["CFBundleShortVersionString": "9.9.9"]) == "9.9.9")
        #expect(DCAppVersion.shown(nil) == DCAppVersion.current)
    }
}

// MARK: - GitHub's answer (release.rs)

@Suite struct UpdatesFeedTests {
    let stub = Stub { _ in .fail(.badURL) }

    // release.rs `picks_the_newest_stable_release`
    @Test func picksTheNewestStableRelease() throws {
        let json = "[" + [stub.release("v0.6.0-rc.1"), stub.release("v0.5.1", prerelease: true), stub.release("v0.7.0", draft: true),
                          stub.release("v0.5.0"), stub.release("v0.4.0")].joined(separator: ",") + "]"
        #expect(try UpdateFeed.newest(in: Data(json.utf8), source: stub.source)?.tag == "v0.5.0")
        #expect(try UpdateFeed.newest(in: Data(json.utf8), source: stub.source, allowPrerelease: true)?.tag == "v0.6.0-rc.1")
        #expect(try UpdateFeed.newest(in: Data("[]".utf8), source: stub.source) == nil)
        #expect(try UpdateFeed.newest(in: Data(#"[{"tag_name":"nightly"}]"#.utf8), source: stub.source) == nil, "no version, no offer")
    }

    // release.rs `reads_the_latest_release`
    @Test func readsARelease() throws {
        let hash = String(repeating: "ab", count: 32)
        let json = "[" + stub.release("v0.2.0", assets: ["DeckCraftNative-0.2.0.dmg", "DeckCraftNative-0.2.0.dmg.sha256"], digest: hash.uppercased(), size: 42) + "]"
        let r = try #require(try UpdateFeed.newest(in: Data(json.utf8), source: stub.source))
        #expect(r.version == UpdateVersion(0, 2, 0))
        #expect(r.name == "DeckCraftNative v0.2.0")
        #expect(r.page.absoluteString == "https://\(stub.host)/releases/tag/v0.2.0")
        #expect(r.notes.hasPrefix("**Fixes**"))
        #expect(r.publishedAt == Date(timeIntervalSince1970: 1_793_102_400))
        #expect(r.installer?.name == "DeckCraftNative-0.2.0.dmg")
        #expect(r.installer?.sha256 == hash, "the digest is kept, lowercased")
        #expect(r.installer?.size == 42)
    }

    // release.rs: links that leave the repo's downloads are dropped (`download_url_under`)
    @Test func refusesLinksOutsideTheRepo() {
        let p = "https://github.com/o/r/releases/download/"
        #expect(UpdateFeed.downloadURL(p + "v1/a.dmg", under: p))
        for bad in ["v1/../../x/a.dmg", "v1/a/b.dmg", "../a.dmg", "v1/.dmg", "v1/a.dmg?x=1", "v1/a.dmg#f", "v1%2fa.dmg", "v1/a%5c.dmg", "v1/", "/a.dmg"] {
            #expect(!UpdateFeed.downloadURL(p + bad, under: p), "\(bad)")
        }
        #expect(!UpdateFeed.downloadURL("https://evil.example/o/r/releases/download/v1/a.dmg", under: p))
        let src = UpdateSource.github("o/r")
        #expect(UpdateFeed.safeReleasePage("https://github.com/o/r/releases/tag/v1", source: src) != nil)
        for bad in ["https://github.com/o/r/releases/tag/../../x", "https://github.com/o/rx/releases", "http://github.com/o/r/releases", "https://github.com/o/r/releases/tag/v1|ls", "https://github.com/o/r/releases/tag/v 1"] {
            #expect(UpdateFeed.safeReleasePage(bad, source: src) == nil, "\(bad)")
        }
        #expect(!UpdateFeed.validFileName(".hidden") && !UpdateFeed.validFileName("a/b") && !UpdateFeed.validFileName("a\u{7}"))
    }

    @Test func capsNotesAndNames() throws {
        let long = String(repeating: "é", count: 40_000)   // 80 000 bytes
        let json = #"[{"tag_name":"v1.0.0","name":"\#(String(repeating: "n", count: 300))","body":"\#(long)"}]"#
        let r = try #require(try UpdateFeed.newest(in: Data(json.utf8), source: stub.source))
        #expect(r.notes.utf8.count <= UpdateFeed.maxNotes + 3 && r.notes.hasSuffix("…"))
        #expect(r.name.utf8.count <= 123)
        #expect(throws: UpdateError.tooLarge) { try UpdateFeed.newest(in: Data(count: UpdateFeed.maxFeedBytes + 1), source: stub.source) }
    }

    @Test func picksTheInstaller() {
        func r(_ names: [String]) -> UpdateRelease {
            UpdateRelease(tag: "v0.2.0", version: UpdateVersion(0, 2, 0), name: "", publishedAt: nil, page: URL(filePath: "/"), notes: "", prerelease: false,
                          assets: names.map { UpdateAsset(name: $0, size: 0, url: URL(filePath: "/\($0)")) })
        }
        #expect(r(["other.dmg", "DeckCraftNative-0.2.0.dmg"]).installer?.name == "DeckCraftNative-0.2.0.dmg")
        #expect(r(["DeckCraftNative-0.2.0-unnotarized.dmg", "x.zip"]).installer == nil)
        #expect(r(["Some.DMG"]).installer?.name == "Some.DMG")
        #expect(r([]).installer == nil)
    }
}

// MARK: - The check (lib.rs `check_for_update`, http.rs)

@Suite struct UpdatesCheckTests {
    @Test func upToDate() async {
        let stub = Stub { _ in ok("[" + "]") }
        #expect(await stub.checker().check() == .upToDate(current: "0.1.0", latest: nil))
        let same = Stub { _ in .fail(.badURL) }
        StubProtocol.register(same.host) { _ in ok("[" + same.release("v0.1.0") + "," + same.release("v0.0.9") + "]") }
        #expect(await same.checker().check() == .upToDate(current: "0.1.0", latest: "0.1.0"))
    }

    @Test func newerReleaseAndTheRequestItMakes() async throws {
        let seen = Seen()
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { req in
            seen.set(req)
            return ok("[" + stub.release("v0.1.0") + "," + stub.release("v0.2.0", assets: ["DeckCraftNative-0.2.0.dmg"]) + "]")
        }
        guard case .available(let r) = await stub.checker().check() else {
            Issue.record("expected an offer")
            return
        }
        #expect(r.versionLabel == "0.2.0" && r.installer?.name == "DeckCraftNative-0.2.0.dmg")
        let req = try #require(seen.get())
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "DeckCraftNative/0.1.0")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(req.url == stub.source.feed)
        #expect(UpdateSource.github().feed.absoluteString == "https://api.github.com/repos/xocialize/DeckCraftNative/releases?per_page=10")
    }

    // craft-update never offers a pre-release to a desktop app
    @Test func preReleasesAreNotOffered() async {
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { _ in
            ok("[" + [stub.release("v0.3.0-rc.1", prerelease: true, assets: ["a.dmg"]), stub.release("v0.4.0-beta", assets: ["a.dmg"]),
                      stub.release("v0.1.0")].joined(separator: ",") + "]")
        }
        #expect(await stub.checker().check() == .upToDate(current: "0.1.0", latest: "0.1.0"))
        var pre = stub.checker()
        pre.allowPrerelease = true
        guard case .available(let r) = await pre.check() else {
            Issue.record("a pre-release is offered when asked for")
            return
        }
        #expect(r.versionLabel == "0.4.0-beta")
    }

    @Test func malformedJSON() async {
        for body in ["{not json", #"{"releases":[]}"#, #"{"message":"Bad credentials"}"#, "42"] {
            let stub = Stub { _ in ok(body) }
            guard case .failed(.malformed) = await stub.checker().check() else {
                Issue.record("\(body) is not a releases list")
                continue
            }
        }
        // Items that aren't releases are skipped, not fatal.
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { _ in ok(#"[1, "x", null, {"tag_name": 5}, "# + stub.release("v0.2.0") + "]") }
        guard case .available(let r) = await stub.checker().check() else {
            Issue.record("the good item is still read")
            return
        }
        #expect(r.tag == "v0.2.0")
    }

    @Test func newerReleaseWithoutADMG() async {
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { _ in
            // A zip, an unnotarized DMG, and a DMG hosted somewhere else: none is an installer.
            var json = stub.release("v0.2.0", assets: ["DeckCraftNative-0.2.0.zip", "DeckCraftNative-0.2.0-unnotarized.dmg"])
            json = json.replacingOccurrences(of: #""assets":["#, with: #""assets":[{"name":"DeckCraftNative-0.2.0.dmg","browser_download_url":"https://evil.example/download/v0.2.0/DeckCraftNative-0.2.0.dmg"},"#)
            return ok("[" + json + "]")
        }
        guard case .available(let r) = await stub.checker().check() else {
            Issue.record("a newer release is offered even without a DMG")
            return
        }
        #expect(r.installer == nil)
        #expect(r.assets.map(\.name) == ["DeckCraftNative-0.2.0.zip", "DeckCraftNative-0.2.0-unnotarized.dmg"], "the foreign link is dropped")
        #expect(r.page.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    }

    @Test func networkError() async {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .serverCertificateUntrusted] {
            let stub = Stub { _ in .fail(code) }
            guard case .failed(.network(let why)) = await stub.checker().check() else {
                Issue.record("\(code) is a network error")
                continue
            }
            #expect(!why.isEmpty)
        }
    }

    // http.rs `refused_until`
    @Test func rateLimit() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 1_800
        let quota = Stub { _ in .http(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"], Data(#"{"message":"API rate limit exceeded"}"#.utf8)) }
        #expect(await quota.checker().check() == .failed(.rateLimited(until: Date(timeIntervalSince1970: TimeInterval(reset)))))

        let now = Date()
        let checker = Stub { _ in .fail(.badURL) }.checker()
        func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: URL(filePath: "/"), statusCode: status, httpVersion: nil, headerFields: headers))
        }
        #expect(checker.interpret(Data(), try response(429, [:]), now: now) == .failed(.rateLimited(until: now.addingTimeInterval(60))))
        #expect(checker.interpret(Data(), try response(403, ["retry-after": "120"]), now: now) == .failed(.rateLimited(until: now.addingTimeInterval(120))))
        #expect(checker.interpret(Data(), try response(403, ["x-ratelimit-remaining": "0"]), now: now) == .failed(.rateLimited(until: nil)))
        #expect(checker.interpret(Data(), try response(403, ["x-ratelimit-remaining": "12"]), now: now) == .failed(.http(403)), "refused, not throttled")
        #expect(checker.interpret(Data(), try response(500, [:]), now: now) == .failed(.http(500)))
        #expect(checker.interpret(Data(), try response(404, [:]), now: now) == .upToDate(current: "0.1.0", latest: nil), "no releases yet")
        #expect(checker.interpret(Data(), URLResponse(), now: now) == .failed(.malformed("no HTTP answer")))
        #expect(!UpdateError.rateLimited(until: nil).message.isEmpty)
    }
}

/// A value a stub saw, read back by the test.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ r: URLRequest) { lock.withLock { request = r } }
    func get() -> URLRequest? { lock.withLock { request } }
}

// MARK: - The download

@Suite struct UpdatesDownloadTests {
    func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func download(_ asset: UpdateAsset, _ dir: URL, _ session: URLSession = .shared) async -> Result<URL, UpdateError> {
        await withCheckedContinuation { c in UpdateDownloader.start(asset, into: dir, session: session) { c.resume(returning: $0) } }
    }

    @Test func downloadsAndVerifiesFromAServer() async throws {
        let body = Data((0 ..< 200_000).map { UInt8($0 % 251) })
        let stub = Stub { req in
            req.url?.lastPathComponent == "DeckCraftNative-0.2.0.dmg" ? .http(200, [:], body) : .http(404, [:], Data())
        }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(URL(string: "https://\(stub.host)/download/v0.2.0/DeckCraftNative-0.2.0.dmg"))
        let asset = UpdateAsset(name: "DeckCraftNative-0.2.0.dmg", size: Int64(body.count), url: url, sha256: hex(body))
        let saved = try await download(asset, dir, stub.session).get()
        #expect(saved == dir.appending(path: "DeckCraftNative-0.2.0.dmg"))
        #expect(try Data(contentsOf: saved) == body)
        let q = try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(q?["LSQuarantineAgentName"] as? String == "DeckCraftNative", "downloaded files are quarantined")

        // The same name again does not overwrite.
        let again = try await download(asset, dir, stub.session).get()
        #expect(again.lastPathComponent == "DeckCraftNative-0.2.0 (2).dmg")

        // A wrong checksum or size is refused, and nothing is left behind.
        #expect(await download(UpdateAsset(name: "x.dmg", size: 0, url: url, sha256: String(repeating: "0", count: 64)), dir, stub.session) == .failure(.corrupt))
        #expect(await download(UpdateAsset(name: "x.dmg", size: 7, url: url), dir, stub.session) == .failure(.corrupt))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "x.dmg").path))

        let missing = try #require(URL(string: "https://\(stub.host)/download/v0.2.0/nope.dmg"))
        #expect(await download(UpdateAsset(name: "nope.dmg", size: 0, url: missing), dir, stub.session) == .failure(.http(404)))
        let offline = Stub { _ in .fail(.networkConnectionLost) }
        let off = try #require(URL(string: "https://\(offline.host)/download/v/a.dmg"))
        guard case .failure(.network) = await download(UpdateAsset(name: "a.dmg", size: 0, url: off), dir, offline.session) else {
            Issue.record("a dropped connection is a network error")
            return
        }
    }

    @Test func downloadsFromAFileURL() async throws {
        let src = try temp(), dir = try temp()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dir)
        }
        let body = Data("not really a disk image".utf8)
        let file = src.appending(path: "DeckCraftNative-0.2.0.dmg")
        try body.write(to: file)
        let saved = try await download(UpdateAsset(name: "DeckCraftNative-0.2.0.dmg", size: Int64(body.count), url: file, sha256: hex(body)), dir).get()
        #expect(try Data(contentsOf: saved) == body)
        #expect(UpdateDownloader.sha256(of: saved) == .success(hex(body)))
        // A name from the feed that isn't a plain file name is replaced.
        let odd = try await download(UpdateAsset(name: "../escape.dmg", size: 0, url: file), dir).get()
        #expect(odd.deletingLastPathComponent().path == dir.path && odd.lastPathComponent == "DeckCraftNative-update.dmg")
    }
}

// MARK: - The update center (updater.rs)

@MainActor
@Suite struct UpdatesCenterTests {
    func defaults() -> UpdatePreferences {
        let suite = "dc-updates-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        return UpdatePreferences(d)
    }

    func center(_ stub: Stub, _ prefs: UpdatePreferences? = nil) -> (UpdateCenter, Counter) {
        let c = UpdateCenter(checker: stub.checker(), preferences: prefs ?? defaults(), downloadsDirectory: FileManager.default.temporaryDirectory, downloadSession: stub.session)
        let n = Counter()
        c.onPresent = { n.presented += 1 }
        c.onDownloaded = { n.opened.append($0) }
        return (c, n)
    }

    /// Waits until the running check has reported (`settle`). The check reports on the main actor, which the
    /// other main-actor suites hold for whole tests at a time in a full run, so the deadline is generous: a
    /// passing check returns as soon as it reports.
    func settle(_ c: UpdateCenter) async {
        let deadline = Date().addingTimeInterval(120)
        while c.isChecking && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    nonisolated static func newer(_ stub: Stub, assets: [String] = ["DeckCraftNative-0.2.0.dmg"]) -> StubProtocol.Answer { ok("[" + stub.release("v0.2.0", assets: assets) + "]") }

    // updater.rs `a_requested_check_reports_an_up_to_date_app`
    @Test func aRequestedCheckReportsAnUpToDateApp() async {
        let (c, n) = center(Stub { _ in ok("[]") })
        c.checkNow()
        #expect(c.phase == .checking && n.presented == 1)
        await settle(c)
        #expect(c.phase == .upToDate(current: "0.1.0"))
        c.dismiss()
        #expect(c.phase == .idle)
    }

    // updater.rs `a_requested_check_reports_a_failure_but_the_startup_check_stays_quiet`
    @Test func aRequestedCheckReportsAFailureButTheAutomaticCheckStaysQuiet() async {
        let stub = Stub { _ in .fail(.notConnectedToInternet) }
        let (c, _) = center(stub)
        c.checkNow()
        await settle(c)
        guard case .failed(.network) = c.phase else {
            Issue.record("a requested check reports its failure")
            return
        }
        let prefs = defaults()
        prefs.checksAutomatically = true
        let (auto, n) = center(stub, prefs)
        auto.checkAutomaticallyIfDue()
        #expect(auto.isChecking)
        await settle(auto)
        #expect(auto.phase == .idle && n.presented == 0)
        #expect(prefs.lastCheck != nil, "a failed automatic check still counts for the day")
    }

    // updater.rs `a_newer_release_opens_the_prompt_and_later_closes_it`
    @Test func aNewerReleaseOpensTheWindowAndLaterClosesIt() async {
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { _ in Self.newer(stub) }
        let prefs = defaults()
        prefs.checksAutomatically = true
        let (c, n) = center(stub, prefs)
        c.checkAutomaticallyIfDue()
        await settle(c)
        guard case .available(let r) = c.phase else {
            Issue.record("an automatic check offers a newer release")
            return
        }
        #expect(r.versionLabel == "0.2.0" && n.presented == 1)
        c.dismiss()
        #expect(c.phase == .idle)
        // An automatic check that finds nothing says nothing.
        let (quiet, m) = center(Stub { _ in ok("[]") }, { let p = defaults(); p.checksAutomatically = true; return p }())
        quiet.checkAutomaticallyIfDue()
        await settle(quiet)
        #expect(quiet.phase == .idle && m.presented == 0)
    }

    // updater.rs `the_startup_check_runs_once`: at most daily, and only when switched on
    @Test func theAutomaticCheckRunsWhenDue() async {
        let prefs = defaults()
        let (c, _) = center(Stub { _ in ok("[]") }, prefs)
        #expect(!prefs.checksAutomatically, "off by default")
        c.checkAutomaticallyIfDue()
        #expect(!c.isChecking)
        c.checksAutomatically = true
        #expect(prefs.checksAutomatically, "the window's checkbox is the preference")
        c.checkAutomaticallyIfDue()
        await settle(c)
        let last = prefs.lastCheck ?? .distantPast
        c.checkAutomaticallyIfDue(now: last.addingTimeInterval(3_600))
        #expect(!c.isChecking, "not again within the day")
        #expect(prefs.isDue(last.addingTimeInterval(UpdatePreferences.interval)))
        #expect(prefs.isDue(last.addingTimeInterval(-60)), "a clock that went back")
    }

    // updater.rs `a_request_during_the_startup_check_is_not_lost`
    @Test func aRequestDuringTheAutomaticCheckIsNotLost() async {
        let prefs = defaults()
        prefs.checksAutomatically = true
        let (c, n) = center(Stub { _ in ok("[]") }, prefs)
        c.checkAutomaticallyIfDue()
        c.checkNow()
        await settle(c)
        #expect(c.phase == .upToDate(current: "0.1.0") && n.presented == 1)
    }

    @Test func aSkippedVersionIsNotOfferedAutomatically() async {
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { _ in Self.newer(stub) }
        let prefs = defaults()
        prefs.checksAutomatically = true
        let (c, n) = center(stub, prefs)
        c.checkNow()
        await settle(c)
        c.skip()
        #expect(prefs.skippedVersion == "0.2.0" && c.phase == .idle)
        prefs.lastCheck = nil
        c.checkAutomaticallyIfDue()
        await settle(c)
        #expect(c.phase == .idle && n.presented == 1)
        c.checkNow()
        await settle(c)
        #expect(c.phase != .idle, "asking still shows it")
    }

    @Test func walkingAwayFromACheckDropsIt() async {
        let (c, n) = center(Stub { _ in ok("[]") })
        c.checkNow()
        c.dismiss()
        #expect(!c.isChecking && c.phase == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(c.phase == .idle && n.presented == 1)
    }

    // The download, then the DMG opens (Updater's install, the Mac way).
    @Test func downloadsAndOpensTheDMG() async throws {
        let body = Data("dmg".utf8)
        let stub = Stub { _ in .fail(.badURL) }
        StubProtocol.register(stub.host) { req in
            req.url?.path().hasPrefix("/download/") == true ? .http(200, [:], body) : ok("[" + stub.release("v0.2.0", assets: ["DeckCraftNative-0.2.0.dmg"]) + "]")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, n) = center(stub)
        c.downloadsDirectory = dir
        c.checkNow()
        await settle(c)
        c.downloadUpdate()
        guard case .downloading = c.phase else {
            Issue.record("downloading")
            return
        }
        #expect(c.progress != nil)
        let deadline = Date().addingTimeInterval(120)
        while n.opened.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let file = dir.appending(path: "DeckCraftNative-0.2.0.dmg")
        #expect(n.opened.map(\.standardizedFileURL) == [file.standardizedFileURL])
        guard case .downloaded(_, let saved) = c.phase else {
            Issue.record("downloaded")
            return
        }
        #expect(try Data(contentsOf: saved) == body)
        c.checkNow()
        #expect(!c.isChecking, "nothing starts once an update is downloaded: the window shows it again")
    }

    @Test func aFailedDownloadCanBeRetried() async throws {
        let stub = Stub { _ in .fail(.badURL) }
        let failing = Flag()
        StubProtocol.register(stub.host) { req in
            if req.url?.path().hasPrefix("/download/") == true { return failing.value ? .http(500, [:], Data()) : .http(200, [:], Data("x".utf8)) }
            return ok("[" + stub.release("v0.2.0", assets: ["DeckCraftNative-0.2.0.dmg"]) + "]")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, n) = center(stub)
        c.downloadsDirectory = dir
        c.checkNow()
        await settle(c)
        failing.value = true
        c.downloadUpdate()
        let deadline = Date().addingTimeInterval(10)
        while c.progress != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard case .downloadFailed(_, .http(500)) = c.phase else {
            Issue.record("the failure is shown: \(c.phase)")
            return
        }
        failing.value = false
        c.retryDownload()
        while n.opened.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(n.opened.count == 1)
    }

    @Test func noInstallerNoDownload() {
        let (c, _) = center(Stub { _ in .fail(.badURL) })
        c.phase = .available(UpdateRelease(tag: "v0.2.0", version: UpdateVersion(0, 2, 0), name: "", publishedAt: nil, page: URL(filePath: "/"), notes: "", prerelease: false, assets: []))
        c.downloadUpdate()
        #expect(c.progress == nil)
        guard case .available = c.phase else {
            Issue.record("still on offer")
            return
        }
    }
}

@MainActor
final class Counter {
    var presented = 0
    var opened: [URL] = []
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
