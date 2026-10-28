// DeckCraftNative's App Intents extension (com.apple.appintents-extension, ExtensionKit): runs the file intents —
// Export Presentation, Get Presentation Outline, Get Slide Count — for Shortcuts, Siri and Spotlight in a process of
// its own, so the app isn't launched (and AppKit opens no window) for them. The intents are DCIntentsKit's; this
// bundle's `Metadata.appintents` lists them through `DeckCraftIntentsExtensionPackage`. Their metadata strings are
// this bundle's (`Localizable.xcstrings` beside this file); the app's App Shortcuts name them from the app target.
import AppIntents
import DCIntentsKit
import ExtensionFoundation

@main
struct DeckCraftIntentsExtension: AppIntentsExtension {
    init() {
        IntentsExtensionSupport.prepare()
    }
}

/// The file intents, merged into this extension's `Metadata.appintents`.
struct DeckCraftIntentsExtensionPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [DCIntentsKitPackage.self] }
}
