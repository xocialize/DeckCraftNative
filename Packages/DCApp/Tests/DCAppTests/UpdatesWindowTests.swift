// DCAppTests — Help › Check for Updates… in the app, in-process: `app.checkUpdates` answers at once and opens the
// Software Update window without blocking, `ui.inspect` reports the update's state, the window lays out in every
// state (the release notes too), and closing it is "Later". deckcraft `crates/ui-egui/src/updates_ui.rs`
// (`an_offered_release_opens_the_prompt`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCCore
import Foundation
import SwiftUI
import Testing
@testable import DCApp
@testable import DCAppModel

/// Answers every request to its host with an empty releases list.
final class UpdatesWindowStubProtocol: URLProtocol, @unchecked Sendable {
    static let host = "updates-window-tests.test"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct UpdatesWindowTests {
    func release(installer: Bool, notes: String = "## Changes\n- **Faster** export\n- [Details](https://example.com)") -> UpdateRelease {
        UpdateRelease(
            tag: "v0.2.0", version: UpdateVersion(0, 2, 0), name: "DeckCraftNative 0.2.0", publishedAt: Date(timeIntervalSince1970: 1_793_102_400),
            page: URL(string: "https://github.com/xocialize/deckcraftnative-releases/releases/tag/v0.2.0") ?? URL(filePath: "/"), notes: notes,
            prerelease: false,
            assets: installer ? [UpdateAsset(name: "DeckCraftNative-0.2.0.dmg", size: 1, url: URL(filePath: "/x.dmg"))] : [])
    }

    func stubChecker() -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdatesWindowStubProtocol.self]
        let source = UpdateSource(feed: URL(string: "https://\(UpdatesWindowStubProtocol.host)/releases") ?? URL(filePath: "/"),
                                  downloadPrefix: "https://\(UpdatesWindowStubProtocol.host)/download/",
                                  releasesPage: "https://\(UpdatesWindowStubProtocol.host)/releases")
        return UpdateChecker(source: source, currentVersion: "0.1.0", session: URLSession(configuration: config))
    }

    @Test func checkForUpdatesAnswersAtOnceAndOpensTheWindow() async throws {
        _ = NSApplication.shared
        let app = AppController()
        let center = try #require(UpdatesFeature.center)
        center.checker = stubChecker()
        #expect(app.uiHandlers["app.checkUpdates"] != nil)
        #expect(app.inspectors["updates"]?()["phase"] == "idle")

        let result = app.model.run("app.checkUpdates")
        #expect((try? result.get()) == .null, "the command answers before the check ends")
        #expect(center.phase == .checking)
        let inspected = app.inspectors["updates"]?()
        #expect(inspected?["phase"] == "checking")
        #expect(inspected?["windowVisible"] == true)
        #expect(inspected?["current"] == "0.1.0")
        let window = try #require(UpdatesFeature.window?.window)
        #expect(window.isVisible && window.sheetParent == nil, "a window of its own, not modal")

        let deadline = Date().addingTimeInterval(10)
        while center.isChecking && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(center.phase == .upToDate(current: "0.1.0"))
        window.close()   // (closing is Later: `theWindowLaysOutInEveryState`; other suites' apps may own the window by now)
    }

    // updates_ui.rs `an_offered_release_opens_the_prompt`, and every other state lays out
    @Test func theWindowLaysOutInEveryState() throws {
        _ = NSApplication.shared
        let center = UpdateCenter(checker: stubChecker(), preferences: UpdatePreferences(UserDefaults(suiteName: "dc-updates-window-\(UUID().uuidString)") ?? .standard))
        let file = URL(filePath: "/tmp/DeckCraftNative-0.2.0.dmg")
        let phases: [UpdateCenter.Phase] = [
            .idle, .checking, .upToDate(current: "0.1.0"), .failed(.rateLimited(until: nil)), .failed(.network("offline")),
            .available(release(installer: true)), .available(release(installer: false)), .available(release(installer: true, notes: "")),
            .downloading(release(installer: true)), .downloaded(release(installer: true), file: file),
            .downloadFailed(release(installer: true), .corrupt),
        ]
        var heights: [CGFloat] = []
        for phase in phases {
            center.phase = phase
            let view = NSHostingView(rootView: UpdatesView(center: center, close: {}))
            let size = view.fittingSize
            #expect(size.width == UpdatesView.width, "\(phase)")
            #expect(size.height > 0, "\(phase)")
            heights.append(size.height)
        }
        #expect((heights.max() ?? 0) <= 600, "the window fits a small screen")

        center.phase = .available(release(installer: true))
        let controller = UpdatesWindowController(center: center)
        controller.show()
        #expect(controller.window?.isVisible == true)
        #expect(controller.window?.title == "Software Update")
        controller.close()
        #expect(center.phase == .idle)
    }

    @Test func releaseNotesKeepInlineMarkdown() {
        let s = UpdatesView.attributed("**Bold** and [a link](https://example.com)")
        #expect(String(s.characters) == "Bold and a link")
        #expect(s.runs.contains { $0.link?.absoluteString == "https://example.com" })
        #expect(String(UpdatesView.attributed("").characters) == "No release notes.")
    }
}
