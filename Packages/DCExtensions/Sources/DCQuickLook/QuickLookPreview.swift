// DCQuickLook — the Quick Look preview of a presentation: every slide as a page of a vector PDF, made by
// DCRender's PDF export (`recordSlide` replayed through `DisplayList.draw`, with the invisible text layer, so the
// preview is sharp at any zoom and its text can be found and selected), titled with the deck's title. Quick
// Look shows a PDF scrollable, zoomable and with page thumbnails, so the extension is a data-based preview
// (`QLPreviewReply` with PDF data) rather than a view of its own. A file that can't be read gets a page that
// says why. Not a port: deckcraft has no Quick Look extension.
import CoreGraphics
import DCCore
import DCEngine
import DCExtensionKit
import DCModel
import DCRender
import Foundation

/// What the preview extension hands Quick Look.
public struct DeckPreview: Sendable {
    public enum Body: Sendable {
        /// The slides, one per page, at `pageSize` points.
        case pdf(Data, pageSize: CGSize)
        /// A page saying why there is no preview.
        case html(Data)
    }

    /// The preview window's title.
    public var title: String
    public var body: Body
    /// Slides in the deck, and pages in the PDF (fewer when the deck has more than `QuickLookPreview.maxSlides`).
    public var slides: Int
    public var pages: Int
}

public enum QuickLookPreview {
    /// The most slides a preview shows. Measured in a release build (PORT-NOTES): reading and exporting the
    /// corpus decks takes 60–150 ms a slide, so a 100-slide preview is ready in about ten seconds at worst.
    public static let maxSlides = 100
    /// The resolution of what the PDF has to draw as pixels (blurs, soft edges, backdrop blend modes).
    public static let rasterDPI = 144.0

    /// The preview of the file at `url`. Never throws: a file that can't be shown gets a message page.
    public static func make(fileAt url: URL, limits: DeckLimits = .preview, maxSlides: Int = maxSlides) -> DeckPreview {
        ExtensionFonts.prepare()
        do {
            return make(try DeckReader.read(url, limits: limits, orText: true), maxSlides: maxSlides)
        } catch {
            return failure(url.lastPathComponent, error)
        }
    }

    /// The preview of a deck already read.
    public static func make(_ file: DeckFile, maxSlides: Int = maxSlides) -> DeckPreview {
        let p = file.presentation
        let total = p.slides.count
        if total == 0 {
            let headline = String(localized: "“\(file.fileName)” has no slides.", bundle: .module, comment: "Quick Look preview of an empty presentation")
            return DeckPreview(title: file.title, body: .html(messagePage(headline, nil)), slides: 0, pages: 0)
        }
        if !file.textOnly { EngineFonts.installEmbeddedFonts(p) }
        let shown = Swift.min(total, Swift.max(1, maxSlides))
        var opts = PDFOptions()
        // A preview shows the file as it is: hidden slides too.
        opts.slides = Array(0 ..< shown)
        opts.dpi = rasterDPI
        opts.title = file.title
        do {
            let data = try PDF.export(p, opts)
            let size = CGSize(width: p.slideSize.width.rustMax(1), height: p.slideSize.height.rustMax(1))
            return DeckPreview(title: title(file, shown: shown, total: total), body: .pdf(data, pageSize: size), slides: total, pages: shown)
        } catch {
            let headline = String(localized: "“\(file.fileName)” can't be previewed.", bundle: .module, comment: "Quick Look preview headline when drawing the slides failed")
            return DeckPreview(title: file.title, body: .html(messagePage(headline, error.description)), slides: total, pages: 0)
        }
    }

    /// The deck's title, saying when the preview leaves slides or pictures out.
    static func title(_ file: DeckFile, shown: Int, total: Int) -> String {
        var t = file.title
        if shown < total {
            t = String(localized: "\(t) (first \(shown) of \(total) slides)", bundle: .module, comment: "Quick Look title of a preview that shows only the first slides: title, shown, total")
        }
        if file.textOnly {
            t = String(localized: "\(t) (without pictures)", bundle: .module, comment: "Quick Look title of a preview of a file too large to read its pictures")
        }
        return t
    }

    /// The message page for a file that couldn't be read.
    static func failure(_ name: String, _ error: DeckFileError) -> DeckPreview {
        let (headline, detail) = message(name, error)
        return DeckPreview(title: name, body: .html(messagePage(headline, detail)), slides: 0, pages: 0)
    }

    /// A headline and a detail line for `error`.
    public static func message(_ name: String, _ error: DeckFileError) -> (String, String?) {
        switch error {
        case .unreadable(let why):
            return (String(localized: "“\(name)” couldn't be read.", bundle: .module, comment: "Quick Look preview headline: the file couldn't be opened"), why)
        case .tooLarge(let bytes, _):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return (String(localized: "“\(name)” is too large to preview (\(size)).", bundle: .module, comment: "Quick Look preview headline: name, file size"), nil)
        case .notAPresentation:
            return (
                String(localized: "“\(name)” isn't a presentation DeckCraftNative can read.", bundle: .module, comment: "Quick Look preview headline: not a presentation"),
                nil
            )
        case .encrypted:
            return (
                String(localized: "“\(name)” is password-protected.", bundle: .module, comment: "Quick Look preview headline: an encrypted file"),
                String(localized: "DeckCraftNative can't open password-protected presentations yet.", bundle: .module, comment: "Quick Look preview detail for an encrypted file")
            )
        case .damaged(let why):
            return (String(localized: "“\(name)” can't be previewed.", bundle: .module, comment: "Quick Look preview headline when drawing the slides failed"), why)
        }
    }

    /// A page with `headline` and `detail`, in the system's font and colours, light or dark.
    public static func messagePage(_ headline: String, _ detail: String?) -> Data {
        let detailHTML = detail.map { "<p>\(escape($0))</p>" } ?? ""
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
                   font-family: -apple-system, sans-serif; text-align: center; color: CanvasText; background: Canvas; }
            main { max-width: 32em; padding: 2em; }
            h1 { font-size: 1.25em; font-weight: 600; margin: 0 0 0.5em; }
            p { margin: 0; opacity: 0.7; overflow-wrap: anywhere; }
            </style></head><body><main><h1>\(escape(headline))</h1>\(detailHTML)</main></body></html>
            """
        return Data(html.utf8)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
