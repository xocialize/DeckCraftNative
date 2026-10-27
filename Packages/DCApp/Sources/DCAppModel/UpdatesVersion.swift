// DCAppModel — the app's version, in one place. `MARKETING_VERSION` in
// `Apps/DeckCraftNative/DeckCraftNative.xcodeproj` must equal it: `Tools/release.sh` refuses to build when they
// differ, and `UpdatesVersionTests` fails. Bump both together.
import Foundation

public enum DCAppVersion {
    /// The version this build calls itself: the update check compares releases with it, and DeckCraftDev (no
    /// bundle, so no `CFBundleShortVersionString`) shows it in About.
    public static let current = "0.1.0"

    /// The running bundle's `CFBundleShortVersionString`, else `current`.
    public static func shown(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? current
    }
}
