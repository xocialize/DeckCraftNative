// DCApp — the choices the intents offer: export formats and PDF layouts (`file.export`), slide layouts
// (`slide.new`), and the themes, starters and command ids the engine knows.
import AppIntents
import DCAppModel
import DCEngine
import DCModel
import Foundation

/// Export Presentation's file formats (`file.export`'s `format`). Format names aren't translated.
public enum ExportFormatOption: String, AppEnum {
    case pdf, pptx, png, jpeg

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Export Format")
    )
    public static let caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] = [
        .pdf: DisplayRepresentation(title: LocalizedStringResource("PDF", comment: "A file format name.")),
        .pptx: DisplayRepresentation(title: LocalizedStringResource("PowerPoint (PPTX)", comment: "A file format name.")),
        .png: DisplayRepresentation(title: LocalizedStringResource("PNG Image", comment: "A file format name.")),
        .jpeg: DisplayRepresentation(title: LocalizedStringResource("JPEG Image", comment: "A file format name.")),
    ]
}

/// What a PDF export lays out (`file.export`'s `layout`).
public enum PDFLayoutOption: String, AppEnum {
    case slides, notes, handouts

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("PDF Layout")
    )
    public static let caseDisplayRepresentations: [PDFLayoutOption: DisplayRepresentation] = [
        .slides: DisplayRepresentation(title: LocalizedStringResource("Slides", comment: "PDF layout: one slide per page.")),
        .notes: DisplayRepresentation(title: LocalizedStringResource("Notes Pages", comment: "PDF layout: each slide with its speaker notes.")),
        .handouts: DisplayRepresentation(title: LocalizedStringResource("Handouts", comment: "PDF layout: several slides per page.")),
    ]
}

/// Handouts' slides per page (`file.export`'s `perPage`).
public enum HandoutsPerPageOption: Int, AppEnum {
    case one = 1, two = 2, three = 3, four = 4, six = 6, nine = 9

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Slides per Page")
    )
    public static let caseDisplayRepresentations: [HandoutsPerPageOption: DisplayRepresentation] = [
        .one: DisplayRepresentation(title: LocalizedStringResource("1 slide per page")),
        .two: DisplayRepresentation(title: LocalizedStringResource("2 slides per page")),
        .three: DisplayRepresentation(title: LocalizedStringResource("3 slides per page")),
        .four: DisplayRepresentation(title: LocalizedStringResource("4 slides per page")),
        .six: DisplayRepresentation(title: LocalizedStringResource("6 slides per page")),
        .nine: DisplayRepresentation(title: LocalizedStringResource("9 slides per page")),
    ]
}

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
