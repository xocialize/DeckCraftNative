// DCApp — the intents that work on a presentation file without opening a window: Export Presentation, Get
// Outline and Get Slide Count. Each reads the file into a session of its own (`IntentsEngine`); the app's
// documents and windows are left alone.
import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Export a presentation file as PDF (slides, notes pages or handouts), PowerPoint, or PNG or JPEG images of one
/// slide or all of them (`file.export`). Returns the written files.
public struct ExportPresentationIntent: AppIntent {
    public static let title = LocalizedStringResource("Export Presentation")
    public static let description = IntentDescription(LocalizedStringResource(
        "Exports a presentation as a PDF of its slides, notes pages or handouts, as a PowerPoint file, or as PNG or JPEG images of one slide or every slide. The presentation isn't opened in a window."
    ))

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "The presentation file an intent works on."),
        supportedContentTypes: [.presentation]
    )
    public var file: IntentFile

    @Parameter(title: LocalizedStringResource("Format"), default: .pdf)
    public var format: ExportFormatOption

    @Parameter(title: LocalizedStringResource("Layout", comment: "What a PDF export lays out."), default: .slides)
    public var layout: PDFLayoutOption

    @Parameter(title: LocalizedStringResource("Slides per Page"), default: .six)
    public var perPage: HandoutsPerPageOption

    @Parameter(title: LocalizedStringResource("All Slides", comment: "Export every slide as an image, one file each."), default: false)
    public var allSlides: Bool

    @Parameter(title: LocalizedStringResource("Slide", comment: "The slide to export as an image, from 1."), default: 1, inclusiveRange: (1, 100_000))
    public var slide: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Switch(\.$format) {
            Case(.pdf) {
                Summary("Export \(\.$file) as \(\.$format)") {
                    \.$layout
                    \.$perPage
                }
            }
            Case(.png) {
                Summary("Export \(\.$file) as \(\.$format)") {
                    \.$allSlides
                    \.$slide
                }
            }
            Case(.jpeg) {
                Summary("Export \(\.$file) as \(\.$format)") {
                    \.$allSlides
                    \.$slide
                }
            }
            DefaultCase {
                Summary("Export \(\.$file) as \(\.$format)")
            }
        }
    }

    /// `file.export`'s request for these parameters.
    public var request: ExportRequest {
        ExportRequest(format: format.rawValue, layout: layout.rawValue, perPage: perPage.rawValue, slide: slide, allSlides: allSlides)
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let input = try PresentationInput(file)
        let request = request
        let urls = try await IntentsEngine.export(input, request, into: IntentsEngine.exportDirectory())
        let files = urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: request.contentType) }
        IntentsRun.report(.array(urls.map { .string($0.path) }))
        let dialog = IntentDialog(LocalizedStringResource(
            "Exported \(files.count) files.", bundle: .atURL(Bundle.module.bundleURL), comment: "Export Presentation finished. The value is how many files it wrote."
        ))
        return .result(value: files, dialog: dialog)
    }
}

/// A presentation file's outline: each slide's title and body text, indented by tabs.
public struct GetOutlineIntent: AppIntent {
    public static let title = LocalizedStringResource("Get Presentation Outline")
    public static let description = IntentDescription(LocalizedStringResource(
        "Gets the outline of a presentation: each slide's title and text, indented by tabs. The presentation isn't opened in a window."
    ))

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "The presentation file an intent works on."),
        supportedContentTypes: [.presentation]
    )
    public var file: IntentFile

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the outline of \(\.$file)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let outline = try await IntentsEngine.outline(PresentationInput(file))
        IntentsRun.report(.string(outline))
        return .result(value: outline)
    }
}

/// How many slides a presentation file has.
public struct GetSlideCountIntent: AppIntent {
    public static let title = LocalizedStringResource("Get Slide Count")
    public static let description = IntentDescription(LocalizedStringResource(
        "Gets how many slides a presentation has. The presentation isn't opened in a window."
    ))

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "The presentation file an intent works on."),
        supportedContentTypes: [.presentation]
    )
    public var file: IntentFile

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the slide count of \(\.$file)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = try await IntentsEngine.slideCount(PresentationInput(file))
        IntentsRun.report(.integer(count))
        let dialog = IntentDialog(LocalizedStringResource(
            "The presentation has \(count) slides.", bundle: .atURL(Bundle.module.bundleURL), comment: "Get Slide Count's answer."
        ))
        return .result(value: count, dialog: dialog)
    }
}
