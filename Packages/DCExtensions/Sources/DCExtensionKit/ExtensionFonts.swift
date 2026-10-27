// DCExtensionKit — which fonts an extension draws with, and a log line saying so. A sandboxed extension can't read
// its containing app's bundle (measured: `stat` succeeds, `open` fails with EPERM, NSCocoaErrorDomain 257), so the
// app's craft-fonts are out of reach; the preview and thumbnail extensions carry the Latin set in their own
// `Contents/Resources/fonts/`, where `FontDB.bundledCraftFontsDir` finds it. Spotlight lays nothing out.
import DCText
import Foundation
import os

public enum ExtensionFonts {
    static let log = Logger(subsystem: "com.xocialize.deckcraftnative", category: "fonts")

    /// Loads the font database once and logs where its craft-fonts came from (`log stream --predicate
    /// 'subsystem == "com.xocialize.deckcraftnative"'`).
    public static func prepare() {
        _ = loaded
    }

    private static let loaded: Bool = {
        let main = Bundle.main.bundleURL.path
        let dir = FontDB.defaultCraftFontsDir()?.path ?? "none"
        let families = FontDB.shared.bundledScripts.count
        let inter = FontDB.shared.hasFamily("Inter")
        log.notice("bundle \(main, privacy: .public): craft-fonts \(dir, privacy: .public), \(families) families, Inter \(inter)")
        return true
    }()
}
