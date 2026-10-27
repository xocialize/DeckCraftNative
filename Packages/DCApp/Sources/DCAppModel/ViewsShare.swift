// DCAppModel — the window-free halves of the pasteboard and of printing. The pasteboard rules port
// `OBJECTS_MARKER`, `system_clipboard_text`, the paste routing of `SlideApp::keyboard` and
// `MAX_PASTE_IMAGE_PIXELS` (deckcraft `crates/ui-egui/src/lib.rs`); the print settings are `app.print`'s
// parameters (`print_pdf`, which prints through `file.export`'s PDF), plus the Outline layout and the
// colour choice the Mac print panel adds (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCEngine
import DCModel
import DCRender

// MARK: Pasteboard

public enum PasteboardLogic {
    /// What a copy of objects without text (a rectangle, a picture, slides) leaves as the pasteboard's
    /// text: an invisible word joiner, so the copy still reads as DeckCraft's own and a paste of it into
    /// another app adds nothing visible (`OBJECTS_MARKER`).
    public static let objectsMarker = "\u{2060}"

    /// `system_clipboard_text`: the text a Copy or Cut leaves for the copied text `t`.
    public static func systemText(_ t: String) -> String { t.isEmpty ? objectsMarker : t }

    /// The largest picture a paste inserts: 16 megapixels (`MAX_PASTE_IMAGE_PIXELS`).
    public static let maxPasteImagePixels = 16_000_000

    /// Why a pasted picture of `width` × `height` pixels is refused, or nil (`color_image_png`'s checks).
    public static func imageProblem(width: Int, height: Int) -> String? {
        let (pixels, o) = width.multipliedReportingOverflow(by: height)
        if o || width < 0 || height < 0 { return L10n.text("the pasted image is too large") }
        if pixels == 0 { return L10n.text("the pasted image is empty") }
        if pixels > maxPasteImagePixels { return L10n.text("the pasted image is \(String(width))×\(String(height)) pixels; the limit is 16 megapixels") }
        return nil
    }

    /// What ⌘V does with what is on the pasteboard.
    public enum Action: Equatable, Sendable {
        /// Paste the session's own clipboard (`edit.paste {}`): the pasteboard still holds DeckCraft's copy.
        case session
        /// Insert the pasteboard's picture (`insert.picture`).
        case picture
        /// Paste text from another app (`edit.paste {text, html?}`): HTML keeps bold, italic and underline.
        case text(String, html: String?)
    }

    /// The paste's route (`SlideApp::keyboard`, `Event::Paste`): DeckCraft's own copy (`owned`, or the
    /// objects marker) pastes the session's clipboard; a picture pastes when the pasteboard has no text;
    /// otherwise its text (and HTML) is pasted.
    public static func action(owned: Bool, text: String?, html: String?, hasImage: Bool) -> Action {
        if owned { return .session }
        let t = text == objectsMarker ? "" : (text ?? "")
        if t.isEmpty { return hasImage ? .picture : .session }
        return .text(t, html: html.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `edit.paste`'s parameters for an action (nil for a picture), with `scope` when slides have the
    /// keyboard.
    public static func pasteParams(_ a: Action, slides: Bool) -> JSON? {
        var o = JSONObject()
        switch a {
        case .picture: return nil
        case .session: break
        case .text(let t, let html):
            o.set("text", .string(t))
            if let html { o.set("html", .string(html)) }
        }
        if slides { o.set("scope", "slides") }
        return .object(o)
    }
}

// MARK: Printing

/// What each printed page shows (`app.print`'s `layout`, `perPage`), plus the outline.
public enum PrintLayout: Equatable, Sendable, Hashable {
    case slides
    case notes
    case handouts(perPage: Int)
    case outline

    /// The layouts the print panel offers, in its order.
    public static let all: [PrintLayout] = [.slides, .notes, .handouts(perPage: 1), .handouts(perPage: 2), .handouts(perPage: 3),
                                            .handouts(perPage: 4), .handouts(perPage: 6), .handouts(perPage: 9), .outline]

    public var label: String {
        switch self {
        case .slides: L10n.text("Full Page Slides")
        case .notes: L10n.text("Notes Pages")
        case .handouts(let n): L10n.text("Handouts (\(n) Slides per Page)")
        case .outline: String(localized: "Outline", bundle: .module, comment: "print layout")
        }
    }

    /// `layout` as `file.export` and `app.print` name it.
    public var id: String {
        switch self {
        case .slides: "slides"
        case .notes: "notes"
        case .handouts: "handouts"
        case .outline: "outline"
        }
    }
}

/// `app.print`'s settings: what the print panel's accessory shows and the control channel passes.
public struct PrintSettings: Equatable, Sendable {
    public var layout: PrintLayout = .slides
    /// Frame each slide (notes and handouts).
    public var frame = true
    public var includeHidden = false
    public var grayscale = false
    /// Which slides: a range ("1-3,5") or nil for all.
    public var slides: String?
    /// The paper the control channel asks for (`letter`, `a4`, `legal`, `a3`); nil = the printer's.
    public var paper: String?
    public var landscape: Bool?

    public init() {}

    /// The settings `app.print`'s parameters ask for.
    public init(params p: JSON) throws(CommandError) {
        if let l = p["layout"]?.asStr {
            switch rustTrim(l).lowercased() {
            case "slides", "": layout = .slides
            case "notes": layout = .notes
            case "outline": layout = .outline
            case "handouts", "handout":
                let n = p["perPage"]?.asU64 ?? 6
                guard [1, 2, 3, 4, 6, 9].contains(n) else { throw CommandError("`perPage` must be 1, 2, 3, 4, 6 or 9") }
                layout = .handouts(perPage: Int(n))
            default: throw CommandError("unknown print layout `\(l)`: slides, notes, handouts or outline")
            }
        }
        if let b = p["frame"]?.asBool { frame = b }
        if let b = p["includeHidden"]?.asBool { includeHidden = b }
        if let b = p["grayscale"]?.asBool { grayscale = b }
        if let c = p["color"]?.asStr { grayscale = c == "grayscale" || c == "gray" }
        switch p["slides"] {
        case .string(let s)?: slides = s
        case .array(let a)?: slides = a.compactMap(\.asU64).map { String($0 + 1) }.joined(separator: ",")
        default: break
        }
        if let s = p["paper"]?.asStr {
            guard PDF.paperSize(s, landscape: false) != nil else {
                throw CommandError("paper “\(s)” isn't one of \(PDF.papers.map(\.id).joined(separator: ", "))")
            }
            paper = s
        }
        if let o = p["orientation"]?.asStr { landscape = o == "landscape" }
    }

    /// `file.export`'s PDF parameters for these settings (the outline prints the slide range only).
    public var exportParams: JSON {
        var o = JSONObject()
        switch layout {
        case .slides, .outline: o.set("layout", "slides")
        case .notes: o.set("layout", "notes")
        case .handouts(let n):
            o.set("layout", "handouts")
            o.set("perPage", .integer(n))
        }
        o.set("frame", .bool(frame))
        o.set("includeHidden", .bool(includeHidden))
        o.set("textLayer", false)
        if let s = slides { o.set("slides", .string(s)) }
        if let p = paper { o.set("paper", .string(p)) }
        if let l = landscape { o.set("orientation", l ? "landscape" : "portrait") }
        return .object(o)
    }

    /// The PDF options for `doc`, with the page size `paper` (points) when the printer gives one.
    public func pdfOptions(_ doc: Presentation, paper: (Double, Double)?) throws(CommandError) -> PDFOptions {
        var o: PDFOptions
        do { o = try FileCommands.pdfOptions(exportParams, doc.slides.count) } catch { throw CommandError(EngineError.from(error).description) }
        if let paper, self.paper == nil, paper.0.isFinite, paper.1.isFinite, paper.0 >= 72, paper.1 >= 72 { o.paper = paper }
        o.textLayer = false
        return o
    }

    /// The answer `app.print` gives: the settings as parameters.
    public var json: JSON {
        var o = JSONObject()
        o.set("layout", .string(layout.id))
        if case .handouts(let n) = layout { o.set("perPage", .integer(n)) }
        o.set("frame", .bool(frame))
        o.set("includeHidden", .bool(includeHidden))
        o.set("grayscale", .bool(grayscale))
        if let s = slides { o.set("slides", .string(s)) }
        return .object(o)
    }
}

/// One line of the printed outline.
public struct OutlineLine: Equatable, Sendable {
    /// The slide's number, on its title line.
    public var number: Int?
    public var level: Int
    public var text: String
    public var isTitle: Bool
}

public enum PrintLogic {
    /// The printed outline: per slide in `indices`, its number and title, then its other text indented by
    /// level (PowerPoint's Outline print layout).
    public static func outline(_ doc: Presentation, _ indices: [Int]) -> [OutlineLine] {
        var out: [OutlineLine] = []
        for i in indices {
            guard let e = OutlineLogic.entry(doc, i) else { continue }
            out.append(OutlineLine(number: i + 1, level: 0, text: e.title, isTitle: true))
            guard let s = doc.slides.at(i) else { continue }
            for b in e.bodies {
                guard let tb = s.shapes.first(where: { $0.id == b.shape })?.text else { continue }
                for p in tb.paragraphs where !p.isEmpty {
                    out.append(OutlineLine(number: nil, level: Int(Swift.min(p.level, 8)) + 1, text: p.text, isTitle: false))
                }
            }
        }
        return out
    }

    /// The slides an export of `o` covers (`selected_slides`): its range, else every slide but the hidden
    /// ones unless asked.
    public static func slides(_ doc: Presentation, _ o: PDFOptions) -> [Int] {
        if let v = o.slides { return v.filter { $0 >= 0 && $0 < doc.slides.count } }
        return doc.slides.indices.filter { o.includeHidden || !doc.slides[$0].hidden }
    }
}
