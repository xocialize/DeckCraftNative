// DCApp — the choices the app's intents offer: slide layouts (`slide.new`), and the themes, starters and command
// ids the engine knows. Export Presentation's (formats, PDF layouts) are DCIntentsKit's.
import AppIntents
import DCAppModel
import DCEngine
import DCModel
import Foundation

/// New slides' layouts (`slide.new`'s `layout`: the layout kinds).
public enum SlideLayoutOption: String, AppEnum {
    case title, titleAndContent, sectionHeader, twoContent, comparison, titleOnly, blank, contentWithCaption, pictureWithCaption

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Slide Layout")
    )
    public static let caseDisplayRepresentations: [SlideLayoutOption: DisplayRepresentation] = [
        .title: DisplayRepresentation(title: LocalizedStringResource("Title Slide", comment: "A slide layout.")),
        .titleAndContent: DisplayRepresentation(title: LocalizedStringResource("Title and Content", comment: "A slide layout.")),
        .sectionHeader: DisplayRepresentation(title: LocalizedStringResource("Section Header", comment: "A slide layout.")),
        .twoContent: DisplayRepresentation(title: LocalizedStringResource("Two Content", comment: "A slide layout.")),
        .comparison: DisplayRepresentation(title: LocalizedStringResource("Comparison", comment: "A slide layout.")),
        .titleOnly: DisplayRepresentation(title: LocalizedStringResource("Title Only", comment: "A slide layout.")),
        .blank: DisplayRepresentation(title: LocalizedStringResource("Blank", comment: "A slide layout.")),
        .contentWithCaption: DisplayRepresentation(title: LocalizedStringResource("Content with Caption", comment: "A slide layout.")),
        .pictureWithCaption: DisplayRepresentation(title: LocalizedStringResource("Picture with Caption", comment: "A slide layout.")),
    ]
}

/// The built-in themes, by name (deckcraft's fixed names: not translated).
public struct ThemeOptions: DynamicOptionsProvider {
    public init() {}
    public func results() async throws -> [String] { builtinThemes().map(\.name) }
}

/// The starter presentations, by name (deckcraft's fixed names: not translated).
public struct StarterOptions: DynamicOptionsProvider {
    public init() {}
    public func results() async throws -> [String] { Templates.starters().map(\.name) }
}

/// Every command id: the engine's registry, then the app's UI commands.
public struct CommandOptions: DynamicOptionsProvider {
    public init() {}
    public func results() async throws -> [String] { IntentsCommands.ids() }
}

/// The command ids Run DeckCraft Command accepts.
public enum IntentsCommands {
    public static func ids() -> [String] {
        var seen = Set<String>()
        return (commandSpecs().map(\.id) + UICommands.all.map(\.id)).filter { seen.insert($0).inserted }
    }

    public static func isKnown(_ id: String) -> Bool { findCommand(id) != nil || UICommands.contains(id) }
}
