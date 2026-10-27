// DCApp — the App Intents package the app target lists (`DeckCraftIntentsPackage.swift` in
// `Apps/DeckCraftNative/App`), so Xcode's metadata processor merges this module's intents, entity and enums into
// the app's `Metadata.appintents`. The App Shortcuts are declared in the app target
// (`DeckCraftIntentShortcuts.swift`): the merge takes actions, entities and enums from a package, not its
// `AppShortcutsProvider`.
import AppIntents

/// This module's intents, for the app's `AppIntentsPackage` to include.
public struct DCAppIntentsPackage: AppIntentsPackage {}
