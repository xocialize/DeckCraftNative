// DeckCraftNative — the app's App Intents: the intents and the open-presentation entity are in the `DCApp` library
// (`Packages/DCApp/Sources/DCApp/Intents`), which includes DCIntentsKit's file intents; listing its package here is
// what has Xcode's metadata processor put them in the app's `Metadata.appintents`, so Shortcuts and Spotlight see
// them and the App Shortcuts (`DeckCraftIntentShortcuts.swift`) can name them. The App Intents extension lists the
// file intents too, and runs them without launching the app.
import AppIntents
import DCApp

struct DeckCraftNativeIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [DCAppIntentsPackage.self] }
}
