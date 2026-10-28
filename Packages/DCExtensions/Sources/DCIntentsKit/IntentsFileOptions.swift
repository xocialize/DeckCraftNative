// DCIntentsKit — the choices Export Presentation offers: file formats, PDF layouts and handouts' slides per page
// (`file.export`'s parameters). Format names aren't translated.
import AppIntents

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
