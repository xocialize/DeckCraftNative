// DCRender — PDF export: the page plan and the writer. Port of deckcraft crates/pdf/src/lib.rs (paper
// sizes, notes pages, handouts, master header/footer text, bookmarks, links; MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors) onto CGPDFContext.
//
// deckcraft draws each slide as a raster with invisible text over it. Here a slide is the renderer's
// recorded drawing replayed as vector paths (`DisplayList`), with only blurs and backdrop compose modes
// as images, and the same invisible real-text layer over it for search, selection and copy.
import CoreGraphics
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

public enum PDFError: Error, Equatable, CustomStringConvertible {
    case noPages
    case write(String)

    public var description: String {
        switch self {
        case .noPages: "nothing to export (no slides in range)"
        case .write(let m): "PDF writer: \(m)"
        }
    }
}

/// What each page shows.
public enum PageLayout: Sendable, Equatable {
    /// One slide per page at the slide size.
    case slides
    /// Portrait page: the slide above its notes.
    case notes
    /// Portrait page with `perPage` slides (1, 2, 3, 4, 6 or 9).
    case handouts(perPage: UInt8)
}

public struct PDFOptions: Sendable {
    public var layout: PageLayout = .slides
    /// Resolution of what is drawn as a raster (blurs, soft edges, backdrop compose modes), in dots per
    /// inch; lowered for a slide whose raster would pass 64M pixels.
    public var dpi: Double = 200
    /// Slide indices to export (0-based); nil = all.
    public var slides: [Int]?
    public var includeHidden = false
    /// Invisible real-text layer (search, select, copy).
    public var textLayer = true
    /// Thin frame around each slide (notes/handouts).
    public var frameSlides = true
    /// Document title (defaults to the presentation title).
    public var title: String?
    /// Handout/notes page size in points (default US Letter portrait; see `PDF.paperSize`).
    public var paper: (Double, Double) = (612, 792)

    public init() {}
}

public enum PDF {
    /// Paper sizes the Print page offers, as (id, label, width × height in points, portrait).
    public static let papers: [(id: String, label: String, size: (Double, Double))] = [
        ("letter", "Letter (8.5 × 11 in)", (612.0, 792.0)),
        ("a4", "A4 (210 × 297 mm)", (595.28, 841.89)),
        ("legal", "Legal (8.5 × 14 in)", (612.0, 1008.0)),
        ("a3", "A3 (297 × 420 mm)", (841.89, 1190.55)),
    ]

    /// The page size in points for a paper id from `papers` (case-insensitive), turned on its side when
    /// `landscape`. nil for an unknown id.
    public static func paperSize(_ id: String, landscape: Bool) -> (Double, Double)? {
        let key = rustTrim(id).lowercased()
        guard let p = papers.first(where: { $0.id == key }) else { return nil }
        return landscape ? (p.size.1, p.size.0) : p.size
    }

    /// The slide box on a notes page of `paper`: an inch of margin at the sides and the slide at most
    /// half the page tall, so landscape paper still leaves room for the notes.
    public static func notesSlideBox(_ paper: (Double, Double), _ aspect: Double) -> Rect {
        let (pw, ph) = paper
        var w = (pw - 2 * 72).rustMax(1)
        var h = w / aspect.rustMax(0.01)
        let maxH = (ph * 0.5 - 54).rustMax(1)
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        let x = (pw - w) / 2
        return Rect(x, 54, x + w, 54 + h)
    }

    /// Slide boxes for a handout page (portrait paper, half-inch-ish margins).
    public static func handoutBoxes(_ perPage: UInt8, _ paper: (Double, Double), _ aspect: Double) -> [Rect] {
        let (pw, ph) = paper
        let (mx, top, bottom) = (54.0, 54.0, 54.0)
        let (cols, rows, notes): (Int, Int, Bool) = switch perPage {
        case 0, 1: (1, 1, false)
        case 2: (1, 2, false)
        case 3: (1, 3, true)
        case 4: (2, 2, false)
        case 6: (2, 3, false)
        default: (3, 3, false)
        }
        let gap = 18.0
        let aw = notes ? (pw - 2 * mx) * 0.5 : pw - 2 * mx
        let ah = ph - top - bottom - 18
        let cw = (aw - gap * Double(cols - 1)) / Double(cols)
        let ch = (ah - gap * Double(rows - 1)) / Double(rows)
        let (w, h) = cw / ch > aspect ? (ch * aspect, ch) : (cw, cw / aspect)
        var out: [Rect] = []
        for r in 0 ..< rows {
            for c in 0 ..< cols {
                var cx = mx + Double(c) * (cw + gap) + (cw - w) / 2
                let cy = top + Double(r) * (ch + gap) + (ch - h) / 2
                if notes { cx = mx }
                out.append(Rect(cx, cy, cx + w, cy + h))
            }
        }
        return out
    }

    /// A notes-size master's rect of placeholder `kind`, scaled to a page of `paper` points.
    static func masterRect(_ pres: Presentation, _ m: Master, _ kind: PhType, _ paper: (Double, Double)) -> Rect? {
        guard let x = m.shapes.first(where: { $0.phType == kind })?.xfrm else { return nil }
        let kx = paper.0 / pres.notesSize.width.rustMax(1), ky = paper.1 / pres.notesSize.height.rustMax(1)
        let r = Rect(x.x * kx, x.y * ky, (x.x + x.w) * kx, (x.y + x.h) * ky)
        return r.width > 1 && r.height > 1 ? r : nil
    }

    /// A notes page's slide box and notes area on `paper`: where the notes master puts its slide image
    /// and body placeholders, or the default layout when it has none.
    public static func notesFrames(_ pres: Presentation, _ paper: (Double, Double)) -> (slide: Rect, notes: Rect) {
        let (pw, ph) = paper
        let aspect = pres.slideSize.width.rustMax(1) / pres.slideSize.height.rustMax(1)
        let nm = pres.notesMaster
        let slide: Rect
        if let m = nm, let f = masterRect(pres, m, .slideImage, paper) {
            // The slide keeps its own shape, centred in the frame.
            let (w, h) = f.width / f.height > aspect ? (f.height * aspect, f.height) : (f.width, f.width / aspect)
            let c = f.center
            slide = Rect(c.x - w / 2, c.y - h / 2, c.x + w / 2, c.y + h / 2)
        } else {
            slide = notesSlideBox(paper, aspect)
        }
        let notes = nm.flatMap { masterRect(pres, $0, .body, paper) } ?? Rect(72, slide.y1 + 36, pw - 72, ph - 54)
        return (slide, notes)
    }

    /// How a master's header, date, footer or page number is printed: its own resolved formatting.
    public struct TextStyle: Sendable, Equatable {
        public var family: String
        /// Points, before scaling to the paper.
        public var size: Double
        public var bold: Bool
        public var italic: Bool
        public var color: Rgba
    }

    /// The resolved style of placeholder `sh`'s first run (or its paragraph's end properties) on master
    /// `m`: run, list style, master text styles, theme fonts and colours.
    public static func masterTextStyle(_ pres: Presentation, _ m: Master, _ sh: Shape) -> TextStyle {
        let ctx = Resolve.Ctx.forMaster(pres, m)
        let para = sh.text?.paragraphs.first ?? Paragraph.default
        let own = para.runs.first?.props ?? para.endProps
        let r = Resolve.run(ctx, sh, para, own)
        let family = r.font.map { $0.hasPrefix("+") ? m.theme.font($0) : $0 } ?? ""
        let color: Rgba = if case .solid(let c)? = r.fill { ctx.color(c, nil) } else { Rgba.rgb(0x60, 0x60, 0x60) }
        return TextStyle(family: family, size: (r.size ?? 12).clamped(1, 400), bold: r.bold == true, italic: r.italic == true, color: color)
    }

    /// The header, date, footer and page-number text a master puts on page `n`, with where it goes,
    /// whether it's right-aligned and its style. Placeholders with no text are left out; the page number
    /// is always `n`.
    public static func masterTexts(_ pres: Presentation, _ m: Master, _ paper: (Double, Double), _ n: Int) -> [(rect: Rect, text: String, right: Bool, style: TextStyle)] {
        var out: [(Rect, String, Bool, TextStyle)] = []
        for kind in [PhType.header, .date, .footer, .slideNum] {
            guard let r = masterRect(pres, m, kind, paper), let sh = m.shapes.first(where: { $0.phType == kind }) else { continue }
            let text = kind == .slideNum ? String(n) : String(rustTrim(sh.text?.text ?? ""))
            if text.isEmpty { continue }
            let right = sh.text?.paragraphs.first?.props.align.map { $0 == .right } ?? (kind == .date || kind == .slideNum)
            var style = masterTextStyle(pres, m, sh)
            // Sizes scale with the page, as the placeholders do.
            style.size *= paper.1 / pres.notesSize.height.rustMax(1)
            out.append((r, text, right, style))
        }
        return out
    }

    /// Most pixels one raster may have.
    static let maxRasterPixels = 64_000_000.0

    /// Raster scale (pixels per slide unit) for a slide of `slide` units drawn `boxWidth` points wide at
    /// `dpi`, with the total pixel count capped.
    static func rasterScale(_ boxWidth: Double, _ slide: (Double, Double), _ dpi: Double) -> Double {
        let scale = (boxWidth / 72 * dpi.clamped(36, 600)) / slide.0
        let pixels = slide.0 * scale * slide.1 * scale
        return pixels > maxRasterPixels ? scale * (maxRasterPixels / pixels).squareRoot() : scale
    }

    /// Per page, the slides on it with their boxes (page points).
    static func planPages(_ pres: Presentation, _ opts: PDFOptions, _ slides: [Int], _ sw: Double, _ sh: Double) -> [[(Int, Rect)]] {
        switch opts.layout {
        case .slides:
            return slides.map { [($0, Rect(0, 0, sw, sh))] }
        case .notes:
            let b = notesFrames(pres, opts.paper).slide
            return slides.map { [($0, b)] }
        case .handouts(let perPage):
            let boxes = handoutBoxes(perPage, opts.paper, sw / sh)
            return stride(from: 0, to: slides.count, by: boxes.count).map { start in
                zip(slides[start ..< min(start + boxes.count, slides.count)], boxes).map { ($0, $1) }
            }
        }
    }

    /// The bookmark label of slide `i`: "n. first line of its title", or "Slide n".
    static func bookmark(_ pres: Presentation, _ i: Int) -> String {
        let t = rustLines(pres.slides.at(i)?.title ?? "").first.map { String(rustTrim($0)) } ?? ""
        return t.isEmpty ? "Slide \(i + 1)" : "\(i + 1). \(t)"
    }

    /// The slides an export covers: the range asked for (out-of-range indices dropped), or every slide
    /// that isn't hidden (hidden ones too when asked).
    static func selectedSlides(_ pres: Presentation, _ opts: PDFOptions) -> [Int] {
        if let v = opts.slides { return v.filter { $0 >= 0 && $0 < pres.slides.count } }
        return pres.slides.indices.filter { opts.includeHidden || !pres.slides[$0].hidden }
    }
}

/// A PDF being written on CGPDFContext, in page points with y down (as the slides are drawn).
public final class PDFWriter {
    let data = NSMutableData()
    let ctx: CGContext
    private var pageHeight = 0.0
    private var pageCount = 0
    private var outline: [(String, Int)] = []

    public init?(title: String?, author: String?) {
        var info: [CFString: Any] = [kCGPDFContextCreator: "DeckCraft"]
        if let t = title, !rustTrim(t).isEmpty { info[kCGPDFContextTitle] = t }
        if let a = author, !rustTrim(a).isEmpty { info[kCGPDFContextAuthor] = a }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else { return nil }
        ctx = c
    }

    /// Starts a page of `w` × `h` points; the context's user space is then page points, y down.
    public func beginPage(_ w: Double, _ h: Double) {
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        pageHeight = h
        pageCount += 1
        // Every page is a named destination for internal links and bookmarks.
        ctx.addDestination(Self.destination(pageCount - 1), at: CGPoint(x: 0, y: h))
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
    }

    public func endPage() { ctx.endPDFPage() }

    /// `rect` (page points, y down) in PDF default user space (y up), where annotations live.
    private func pdfRect(_ r: Rect) -> CGRect {
        CGRect(x: r.x0, y: pageHeight - r.y1, width: r.width, height: r.height)
    }

    /// A link on the current page to a web or mail address.
    public func link(_ rect: Rect, url: URL) { ctx.setURL(url as CFURL, for: pdfRect(rect)) }

    /// A link on the current page to page `page` (0-based; it may come later).
    public func link(_ rect: Rect, page: Int) { ctx.setDestination(Self.destination(page), for: pdfRect(rect)) }

    /// A top-level bookmark to page `page` (0-based).
    public func bookmark(_ title: String, page: Int) { outline.append((title, page)) }

    static func destination(_ page: Int) -> CFString { "page-\(page + 1)" as CFString }

    /// The finished PDF.
    public func finish() -> Data {
        if !outline.isEmpty {
            let kids = outline.map { t, p -> CFDictionary in
                [kCGPDFOutlineTitle: t, kCGPDFOutlineDestination: p + 1] as CFDictionary
            }
            CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: kids] as CFDictionary)
        }
        ctx.closePDF()
        return data as Data
    }
}
