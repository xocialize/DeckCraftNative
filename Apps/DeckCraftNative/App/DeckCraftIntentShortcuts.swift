// DeckCraftNative — the App Shortcuts: phrases that run DeckCraftNative's intents from Spotlight, Siri and the
// Shortcuts app with no setup. The intents that act on the app's windows are in the `DCApp` library
// (`Packages/DCApp/Sources/DCApp/Intents`); the file intents (Export Presentation, Get Outline, Get Slide Count) are
// in `DCIntentsKit`, and the App Intents extension (`DeckCraftIntents.appex`) runs them without launching the app.
// The provider is here because App Shortcuts are read from the app target's own metadata, not merged from a
// package's, and each App Shortcut must map to an action in that metadata: the app lists DCIntentsKit's package
// too (through DCApp's). App Intents metadata strings are in the main bundle (the metadata processor refuses any
// other).
import AppIntents
import DCApp
import DCIntentsKit

/// The phrases that run the intents from Spotlight and Siri. Each names the app (`.applicationName`), as App
/// Shortcuts require. Run DeckCraft Command is an action in Shortcuts only.
struct DeckCraftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewPresentationIntent(),
            phrases: [
                "New \(.applicationName) presentation",
                "Create a presentation in \(.applicationName)",
                "Start a new presentation in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("New Presentation"),
            systemImageName: "plus.rectangle.on.rectangle"
        )
        AppShortcut(
            intent: OpenPresentationIntent(),
            phrases: [
                "Open a presentation in \(.applicationName)",
                "Open a \(.applicationName) presentation",
            ],
            shortTitle: LocalizedStringResource("Open Presentation"),
            systemImageName: "doc.richtext"
        )
        AppShortcut(
            intent: ExportPresentationIntent(),
            phrases: [
                "Export a presentation with \(.applicationName)",
                "Export a \(.applicationName) presentation",
                "Make a PDF of a presentation with \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Export Presentation"),
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: StartSlideShowIntent(),
            phrases: [
                "Start the slide show in \(.applicationName)",
                "Play the \(.applicationName) slide show",
                "Present with \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Start Slide Show"),
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: AddSlideIntent(),
            phrases: [
                "Add a slide in \(.applicationName)",
                "Add a slide to my \(.applicationName) presentation",
            ],
            shortTitle: LocalizedStringResource("Add Slide"),
            systemImageName: "rectangle.badge.plus"
        )
        AppShortcut(
            intent: GetOutlineIntent(),
            phrases: [
                "Get a presentation's outline with \(.applicationName)",
                "Get the outline of a \(.applicationName) presentation",
            ],
            shortTitle: LocalizedStringResource("Get Outline"),
            systemImageName: "list.bullet.indent"
        )
        AppShortcut(
            intent: GetSlideCountIntent(),
            phrases: [
                "Count the slides in a presentation with \(.applicationName)",
                "How many slides are in a \(.applicationName) presentation",
            ],
            shortTitle: LocalizedStringResource("Get Slide Count"),
            systemImageName: "number"
        )
    }
}
