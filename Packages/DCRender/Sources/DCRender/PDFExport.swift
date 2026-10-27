// DCRender — PDF export of a presentation: deckcraft crates/pdf/src/lib.rs `export` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) on `PDFWriter`. Slides are the renderer's recorded
// drawing replayed as vectors; an invisible layer of real glyphs from the text engine lies over them
// (CoreGraphics embeds the font subsets and maps glyphs back to text), so text can be searched,
// selected and copied. Hyperlinks and shape actions become link annotations, slide titles bookmarks.
import CoreGraphics
import CoreText
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText
import Foundation

extension PDF {
    /// Exports `pres` as PDF bytes.
    public static func export(_ pres: Presentation, _ opts: PDFOptions) throws(PDFError) -> Data {
        let slides = selectedSlides(pres, opts)
        if slides.isEmpty { throw .noPages }
        let title = opts.title ?? pres.props.title
        guard let w = PDFWriter(title: title, author: pres.props.author) else { throw .write("can't create a PDF context") }
        let (sw, sh) = (pres.slideSize.width.rustMax(1), pres.slideSize.height.rustMax(1))
        let pages = planPages(pres, opts, slides, sw, sh)
        var pageOf: [Int: Int] = [:]
        for (p, v) in pages.enumerated() {
            for (i, _) in v where pageOf[i] == nil { pageOf[i] = p }
        }
        for (p, v) in pages.enumerated() {
            for (i, _) in v { w.bookmark(bookmark(pres, i), page: p) }
        }
        let ex = Exporter(pres: pres, opts: opts, w: w)
        for v in pages {
            let (pw, ph) = opts.layout == .slides ? (sw, sh) : opts.paper
            w.beginPage(pw, ph)
            for (i, b) in v {
                ex.slide(i, b)
                ex.links(i, b, pageOf)
            }
            switch opts.layout {
            case .notes:
                if let (i, _) = v.first {
                    ex.paragraphs(pres.slides[i].notesText, notesFrames(pres, opts.paper).notes, 12)
                    ex.pageTexts(pres.notesMaster, pw, ph, i + 1)
                }
            case .handouts(let perPage):
                if perPage == 3 {
                    for (_, b) in v { ex.noteLines(Rect(b.x1 + 24, b.y0, pw - 54, b.y1)) }
                }
                ex.pageTexts(pres.handoutMaster, pw, ph, v.first.flatMap { pageOf[$0.0] }.map { $0 + 1 } ?? 1)
            case .slides:
                break
            }
            w.endPage()
        }
        return w.finish()
    }
}

private struct Exporter {
    let pres: Presentation
    let opts: PDFOptions
    let w: PDFWriter
    var ctx: CGContext { w.ctx }

    /// Slide `i` drawn into `b` (page points).
    func slide(_ i: Int, _ b: Rect) {
        let (sw, sh) = (pres.slideSize.width.rustMax(1), pres.slideSize.height.rustMax(1))
        let k = b.width / sw
        // Recorded at the raster resolution, so whatever the renderer draws as pixels (pictures it
        // resamples, metafiles, effects) has the detail the dpi asks for.
        let scale = PDF.rasterScale(b.width, (sw, sh), opts.dpi)
        if let list = recordSlide(pres, i, nil, RenderOpts(scale: scale)) {
            let box = CGRect(x: b.x0, y: b.y0, width: b.width, height: b.height)
            ctx.saveGState()
            ctx.clip(to: box)
            list.draw(in: ctx, view: Affine.translate(Vec2(b.x0, b.y0)) * Affine.scale(k / scale), bounds: box, rasterScale: scale / k)
            ctx.restoreGState()
        }
        if opts.frameSlides && opts.layout != .slides {
            ctx.setStrokeColor(gray(0x80))
            ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: b.x0, y: b.y0, width: b.width, height: b.height))
        }
        if opts.textLayer {
            let view = Affine.translate(Vec2(b.x0, b.y0)) * Affine.scale(k)
            for pt in placeSlide(pres, i).texts { textLayer(pt, view, visible: false) }
        }
    }

    func gray(_ v: UInt8, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: Double(v) / 255, green: Double(v) / 255, blue: Double(v) / 255, alpha: a)
    }

    /// The text of `pt`'s runs over where the engine placed them: invisible over the drawn slide, or
    /// visible (master header and footer text on notes and handout pages). Each run is drawn as a CoreText
    /// line of its own characters, stretched over the run's extent: drawn that way, CoreGraphics maps the
    /// glyphs back to those characters (drawing bare glyph ids, it guesses from the font's cmap, and a
    /// glyph two characters share comes back as the wrong one: Greek ι as Latin ɩ in Inter).
    func textLayer(_ pt: PlacedText, _ view: Affine, visible: Bool) {
        for run in pt.layout.runs where !run.glyphs.isEmpty && run.size > 0 {
            guard let para = pt.body.paragraphs.at(run.para) else { continue }
            let scalars = Array(para.text.unicodeScalars)
            let lo = Swift.min(Swift.max(run.chars.start, 0), scalars.count)
            let hi = Swift.min(Swift.max(run.chars.end, lo), scalars.count)
            let text = String(String.UnicodeScalarView(scalars[lo ..< hi]))
            if rustTrim(text).isEmpty { continue }
            let k = run.size / run.face.upem.rustMax(1)
            let x0 = run.glyphs.map(\.x).min() ?? 0
            let x1 = run.glyphs.map { $0.x + run.face.advance($0.gid) * k }.max() ?? x0
            let font = run.face.ctFont(size: run.size)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width.isFinite, width > 0 else { continue }
            ctx.saveGState()
            ctx.concatenate(Canvas.cg(view * pt.transform * Affine.translate(Vec2(x0, run.glyphs[0].y))))
            if x1 > x0 { ctx.scaleBy(x: (x1 - x0) / width, y: 1) }
            // Glyph space is y up; the page is y down.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = .zero
            if visible {
                ctx.setTextDrawingMode(.fill)
                ctx.setFillColor(Canvas.cgColor(run.color, run.alpha))
            } else {
                ctx.setTextDrawingMode(.invisible)
            }
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// Link annotations for slide `i` drawn in `b`: web and mail addresses the slide show opens, and
    /// jumps to slides that are in the export.
    func links(_ i: Int, _ b: Rect, _ pageOf: [Int: Int]) {
        let k = b.width / pres.slideSize.width.rustMax(1)
        let view = Affine.translate(Vec2(b.x0, b.y0)) * Affine.scale(k)
        for l in placeSlide(pres, i).links {
            let r = view.transformRectBBox(l.rect).intersect(b)
            guard r.width > 0, r.height > 0 else { continue }
            func goto(_ s: Int?) -> Int? { s.flatMap { pageOf[$0] } }
            switch l.link.action {
            case .url(let url):
                // Only the links the slide show opens (web and mail): a reader of the file gets the rest
                // as plain text.
                if safeURL(url), let u = URL(string: url) { w.link(r, url: u) }
            case .slide(let id):
                if let p = goto(pres.slides.firstIndex { $0.id == id }) { w.link(r, page: p) }
            case .nextSlide:
                if let p = goto(i + 1) { w.link(r, page: p) }
            case .previousSlide:
                if let p = goto(i > 0 ? i - 1 : nil) { w.link(r, page: p) }
            case .firstSlide:
                if let p = goto(0) { w.link(r, page: p) }
            case .lastSlide:
                if let p = goto(pres.slides.isEmpty ? nil : pres.slides.count - 1) { w.link(r, page: p) }
            default:
                break
            }
        }
    }

    var uiFace: FontFace { FontDB.shared.face("Inter", "Regular") }

    /// Wrapped plain text (notes).
    func paragraphs(_ text: String, _ area: Rect, _ size: Double) {
        let face = uiFace
        let font = face.ctFont(size: size)
        let k = size / face.upem.rustMax(1)
        func width(_ s: String) -> Double { s.unicodeScalars.reduce(0) { $0 + face.advance(face.glyph(for: $1)) * k } }
        let lh = size * 1.3
        var y = area.y0 + size
        func draw(_ line: String) {
            let scalars = Array(line.unicodeScalars)
            var x = area.x0
            var glyphs: [CGGlyph] = [], pos: [CGPoint] = []
            for s in scalars {
                let g = face.glyph(for: s)
                glyphs.append(CGGlyph(truncatingIfNeeded: g))
                pos.append(CGPoint(x: x, y: y))
                x += face.advance(g) * k
            }
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(gray(0x20))
            CTFontDrawGlyphs(font, glyphs, pos, glyphs.count, ctx)
            ctx.restoreGState()
        }
        outer: for para in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false) {
                let cand = line.isEmpty ? String(word) : "\(line) \(word)"
                if width(cand) > area.width && !line.isEmpty {
                    if y > area.y1 { break outer }
                    draw(line)
                    y += lh
                    line = String(word)
                } else {
                    line = cand
                }
            }
            if y > area.y1 { break }
            if !line.isEmpty { draw(line) }
            y += lh
        }
    }

    /// Ruled lines for handwritten notes (3-per-page handouts).
    func noteLines(_ r: Rect) {
        ctx.saveGState()
        ctx.setStrokeColor(gray(0xB0))
        ctx.setLineWidth(0.5)
        var y = r.y0 + 18
        while y <= r.y1 {
            ctx.move(to: CGPoint(x: r.x0, y: y))
            ctx.addLine(to: CGPoint(x: r.x1, y: y))
            y += 22
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A notes or handout page's header, date, footer and page number from its master; just the page
    /// number when the deck has no such master.
    func pageTexts(_ master: Master?, _ pw: Double, _ ph: Double, _ n: Int) {
        guard let m = master else { return footer(pw, ph, n) }
        // Laid out by the text engine in the placeholders, scaled from the notes size to the page:
        // wrapping, alignment and mixed formatting as the master has them.
        let view = Affine.scaleNonUniform(pw / pres.notesSize.width.rustMax(1), ph / pres.notesSize.height.rustMax(1))
        for pt in placeMasterTexts(pres, m, n) { textLayer(pt, view, visible: true) }
    }

    func footer(_ pw: Double, _ ph: Double, _ n: Int) {
        let face = uiFace
        let font = face.ctFont(size: 9)
        var x = pw - 72
        var glyphs: [CGGlyph] = [], pos: [CGPoint] = []
        for s in String(n).unicodeScalars {
            let g = face.glyph(for: s)
            glyphs.append(CGGlyph(truncatingIfNeeded: g))
            pos.append(CGPoint(x: x, y: ph - 30))
            x += face.advance(g) * 9 / face.upem.rustMax(1)
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setFillColor(gray(0x60))
        CTFontDrawGlyphs(font, glyphs, pos, glyphs.count, ctx)
        ctx.restoreGState()
    }
}
