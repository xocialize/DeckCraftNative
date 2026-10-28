// DCApp — the App Intents package the app target lists (`DeckCraftIntentsPackage.swift` in
// `Apps/DeckCraftNative/App`), so Xcode's metadata processor merges this module's intents, entity and enums into
// the app's `Metadata.appintents`, with DCIntentsKit's file intents (Export Presentation, Get Outline, Get Slide
// Count), which the App Intents extension runs and the app's App Shortcuts name. The App Shortcuts are declared in
// the app target (`DeckCraftIntentShortcuts.swift`): the merge takes actions, entities and enums from a package,
// not its `AppShortcutsProvider`.
import AppIntents
import DCIntentsKit

/// This module's intents and DCIntentsKit's, for the app's `AppIntentsPackage` to include.
public struct DCAppIntentsPackage: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [DCIntentsKitPackage.self] }
}
