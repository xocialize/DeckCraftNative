// DCIntentsKit — the App Intents package of the file intents. Two bundles list it: the App Intents extension
// (`Apps/DeckCraftNative/Extensions/Intents`), which is where the system runs them without launching the app, and
// the app (through DCApp's `DCAppIntentsPackage`), whose App Shortcuts name them: an App Shortcut must map to an
// action in the app's own `Metadata.appintents`, and the provider must be in the app target. With the same intent
// in both, the system prefers the extension for a background intent and may use the app when it's already running
// (Apple, "Configuring the runtime behavior of your app intents").
import AppIntents
import DCExtensionKit

/// The file intents, for the extension's and the app's `AppIntentsPackage` to include.
public struct DCIntentsKitPackage: AppIntentsPackage {}

/// Set-up for the App Intents extension's process.
public enum IntentsExtensionSupport {
    /// Loads the fonts the extension carries (`Contents/Resources/fonts`) and logs where they came from.
    public static func prepare() { ExtensionFonts.prepare() }
}
