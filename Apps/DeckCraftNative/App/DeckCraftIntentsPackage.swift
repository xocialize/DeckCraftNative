// DeckCraftNative — the app's App Intents: the intents, the open-presentation entity and the App Shortcuts are
// in the `DCApp` library (`Packages/DCApp/Sources/DCApp/Intents`); listing its package here is what has Xcode's
// metadata processor put them in the app's `Metadata.appintents`, so Shortcuts and Spotlight see them.
import AppIntents
import DCApp

struct DeckCraftNativeIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [DCAppIntentsPackage.self] }
}
