// DCAppModelTests — AppIdentity: a product built on DeckCraftNative names itself in text, and its updates come from
// its own releases in a repo it may share with other products (its tag prefix).
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite(.serialized) struct AppIdentityTests {
    static let product = AppIdentity(name: "Marquee Presentation", version: "0.2.0", releasesRepo: "example/shared-releases",
                                     releaseTagPrefix: "presentation-v", installerName: "MarqueePresentation",
                                     supportFolder: "MarqueePresentation", builtOn: "Built on DeckCraftNative.")

    @Test func textIsBranded() {
        #expect(Self.product.brand("About DeckCraftNative") == "About Marquee Presentation")
        #expect(AppIdentity.deckCraftNative.brand("About DeckCraftNative") == "About DeckCraftNative")
        #expect(Self.product.userAgent == "MarqueePresentation/0.2.0")
    }

    /// A shared repo lists several products' releases: only this product's tags count, its version is the tag less
    /// the prefix, and its installer is the one named for it.
    @Test func onlyThisProductsReleasesAreOffered() throws {
        let source = try #require(Self.product.updateSource)
        #expect(source.feed.absoluteString == "https://api.github.com/repos/example/shared-releases/releases?per_page=50")
        func release(_ tag: String, _ asset: String) -> [String: Any] {
            ["tag_name": tag, "html_url": "https://github.com/example/shared-releases/releases/tag/\(tag)", "draft": false, "prerelease": false,
             "assets": [["name": asset, "size": 100, "browser_download_url": "https://github.com/example/shared-releases/releases/download/\(tag)/\(asset)"]]]
        }
        let list: [[String: Any]] = [
            release("windows-v9.0.0", "MarqueeSurface-9.0.0.exe"),
            release("v5.0.0", "Other-5.0.0.dmg"),
            release("presentation-v0.3.0", "MarqueePresentation-0.3.0.dmg"),
            release("presentation-v0.2.5", "MarqueePresentation-0.2.5.dmg"),
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        let newest = try #require(try UpdateFeed.newest(in: data, source: source))
        #expect(newest.tag == "presentation-v0.3.0")
        #expect(newest.versionLabel == "0.3.0")
        #expect(newest.installer?.name == "MarqueePresentation-0.3.0.dmg")
        let checker = UpdateChecker(source: source, currentVersion: "0.2.0")
        let http = try #require(HTTPURLResponse(url: source.feed, statusCode: 200, httpVersion: nil, headerFields: nil))
        if case .available(let r) = checker.interpret(data, http, now: Date()) { #expect(r.tag == "presentation-v0.3.0") } else { Issue.record("no update offered") }
    }

    /// DeckCraftNative's own feed is unchanged: any tag that parses as a version, ten releases.
    @Test func deckCraftNativesFeedIsUnchanged() throws {
        let source = try #require(AppIdentity.deckCraftNative.updateSource)
        #expect(source == UpdateSource.github())
        #expect(source.version(ofTag: "v0.1.15")?.description == "0.1.15")
        #expect(source.version(ofTag: "0.1.15")?.description == "0.1.15")
    }
}
