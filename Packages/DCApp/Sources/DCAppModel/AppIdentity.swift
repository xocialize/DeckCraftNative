// DCAppModel — what the app calls itself, in one place, so a product built on DeckCraftNative (an app target that
// links DCApp and calls `DeckCraftApp.main()`) can ship under its own name, version and update feed without forking:
// it sets `AppIdentity.current` before `DeckCraftApp.main()`. DeckCraftNative's own builds leave it as it is.
//
// The app's user-visible text names "DeckCraftNative" inside translated strings (About, the update window, errors).
// Those strings keep their catalog keys and translations; `brand(_:)` puts the identity's name in their place after
// they are localized: the name is a brand and is never translated, so it reads right in every language.
import Foundation

public struct AppIdentity: Sendable, Equatable {
    /// The product's name, as text names it ("DeckCraftNative").
    public var name: String
    /// The version releases are compared with; nil: the bundle's `CFBundleShortVersionString`, else `DCAppVersion`.
    public var version: String?
    /// The public GitHub repo whose releases carry the installers (`owner/name`); nil: no update check.
    public var releasesRepo: String?
    /// What a release's tag starts with, before its version: "v" (`v0.1.15`), or a product's own prefix in a repo
    /// several products share (`presentation-v0.1.0`). Releases with another prefix are not this product's.
    public var releaseTagPrefix: String
    /// The installer's name before `-<version>.dmg`.
    public var installerName: String
    /// The folder in Application Support and Caches the app keeps its files in.
    public var supportFolder: String
    /// A line for About naming what the product is built on (nil for DeckCraftNative itself).
    public var builtOn: String?

    public init(name: String, version: String? = nil, releasesRepo: String?, releaseTagPrefix: String = "v",
                installerName: String, supportFolder: String, builtOn: String? = nil) {
        self.name = name
        self.version = version
        self.releasesRepo = releasesRepo
        self.releaseTagPrefix = releaseTagPrefix
        self.installerName = installerName
        self.supportFolder = supportFolder
        self.builtOn = builtOn
    }

    /// DeckCraftNative, as its own releases publish it.
    public static let deckCraftNative = AppIdentity(
        name: "DeckCraftNative", releasesRepo: UpdateSource.releasesRepo, releaseTagPrefix: "v",
        installerName: "DeckCraftNative", supportFolder: "DeckCraftNative")

    /// The running product's identity. Set it once, before `DeckCraftApp.main()`, on the main thread.
    nonisolated(unsafe) public static var current: AppIdentity = .deckCraftNative

    /// The version this build calls itself.
    public var shownVersion: String { version ?? DCAppVersion.shown() }

    /// `text` with "DeckCraftNative" replaced by this product's name.
    public func brand(_ text: String) -> String {
        name == AppIdentity.deckCraftNative.name ? text : text.replacingOccurrences(of: AppIdentity.deckCraftNative.name, with: name)
    }

    /// The release feed for this product; nil when it has no releases repo.
    public var updateSource: UpdateSource? {
        releasesRepo.map { UpdateSource.github($0, tagPrefix: releaseTagPrefix, installerName: installerName) }
    }

    /// `name/version`, as GitHub asks a client to say who it is.
    public var userAgent: String { "\(name.replacingOccurrences(of: " ", with: ""))/\(shownVersion)" }
}

extension String {
    /// This text with the running product's name in place of "DeckCraftNative" (`AppIdentity.brand`).
    public var branded: String { AppIdentity.current.brand(self) }
}
