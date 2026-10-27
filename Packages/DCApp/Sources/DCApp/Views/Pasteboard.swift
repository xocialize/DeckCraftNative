// DCApp — Copy, Cut and Paste through NSPasteboard. Port of deckcraft `apps/deckcraft/src/pasteboard.rs`
// and of `publish_clipboard` and the paste routing in `SlideApp::keyboard` (`crates/ui-egui/src/lib.rs`;
// MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), on the system pasteboard instead of
// arboard:
//
// - The session keeps its own clipboard (objects, slides, formatted text); the pasteboard gets the text,
//   HTML for formatted text (Pages and Keynote keep bold, italic and underline), and for copied shapes a
//   PDF (vector) and PNG of them for other apps. Objects without text leave the invisible objects marker
//   as their text, as deckcraft does.
// - Paste uses the session's clipboard while the pasteboard still holds DeckCraft's own copy; otherwise a
//   picture (PNG, TIFF, PDF, or an image file copied in Finder) is inserted as a picture, and text is
//   pasted with its HTML.
// - The menu bar's Cut, Copy, Paste, Paste and Match Formatting and Select All reach a text field or text
//   view that has the keyboard (the notes, the outline, an inspector field) instead of the slide.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import UniformTypeIdentifiers

@MainActor
final class PasteboardBridge {
    static let shared = PasteboardBridge()

    /// The pasteboard written and read (tests use a private one).
    var board: NSPasteboard
    /// The pasteboard's change count after DeckCraft's last write: while it is unchanged, a paste uses
    /// the session's own clipboard.
    private(set) var ownedChange: Int?
    /// Set while this class runs a copy itself, so the generic `pendingCopy` hand-off doesn't write twice.
    private var publishing = false

    /// Marks DeckCraft's own copy on the pasteboard.
    static let objectsType = NSPasteboard.PasteboardType("ai.storyteller.deckcraft.objects")

    init(board: NSPasteboard = .general) {
        self.board = board
    }

    // MARK: Copy

    /// Copy or Cut the selection (the slides when `slides`), then put it on the pasteboard.
    @discardableResult
    func copy(_ model: AppModel, cut: Bool, slides: Bool) -> Result<JSON, CommandError> {
        publishing = true
        defer { publishing = false }
        let p: JSON = slides ? ["scope": "slides"] : .object(JSONObject())
        let r = model.run(cut ? "edit.cut" : "edit.copy", p)
        model.pendingCopy = nil
        if case .success(let v) = r {
            publish(text: v["text"]?.asStr ?? "", html: v["html"]?.asStr ?? "", session: model.session)
        }
        return r
    }

    func copy(_ link: DocLink, cut: Bool, slides: Bool) {
        link.activate()
        copy(link.model, cut: cut, slides: slides)
    }

    /// Text a Copy or Cut run elsewhere (the control channel, a script, a toolbar) left in `pendingCopy`.
    func flushPending(_ model: AppModel) {
        guard !publishing, let t = model.pendingCopy else { return }
        model.pendingCopy = nil
        publish(text: t, html: "", session: model.session)
    }

    /// Write what was just copied: text (or the objects marker), HTML for text, and a PDF and PNG of copied
    /// shapes.
    func publish(text: String, html: String, session: Session) {
        let item = NSPasteboardItem()
        let clip = session.clipboard
        if clip.slides.isEmpty && !html.isEmpty {
            item.setString(html, forType: .html)
            item.setString(text, forType: .string)
        } else {
            item.setString(PasteboardLogic.systemText(text), forType: .string)
        }
        item.setString(String(session.clipboard.pastes), forType: Self.objectsType)
        if clip.slides.isEmpty, !clip.shapes.isEmpty, let doc = session.activeDoc {
            let slideIndex = doc.selection.slide
            if let pdf = Self.shapesPDF(doc.doc, slideIndex, clip.shapes) { item.setData(pdf, forType: .pdf) }
            if let png = Self.shapesPNG(doc.doc, slideIndex, clip.shapes) { item.setData(png, forType: .png) }
        }
        board.clearContents()
        if board.writeObjects([item]) { ownedChange = board.changeCount }
    }

    /// The copied shapes on slide `index`'s page, as the presentation draws them.
    private static func page(_ doc: Presentation, _ index: Int, _ shapes: [Shape]) -> Presentation? {
        guard var slide = doc.slides.at(index) else { return nil }
        var p = doc
        slide.shapes = shapes
        slide.showMasterShapes = false
        p.slides[index] = slide
        return p
    }

    /// The copied shapes as one PNG on a transparent background (`renderShapes`, as Paste Special ›
    /// Picture draws them).
    static func shapesPNG(_ doc: Presentation, _ index: Int, _ shapes: [Shape]) -> Data? {
        guard let p = page(doc, index, shapes), let slide = p.slides.at(index) else { return nil }
        guard let img = renderShapes(p, slide, shapes.map(\.id), 2)?.cgImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// The copied shapes as a one-page vector PDF cropped to them (8 pt of room for shadows and outlines).
    static func shapesPDF(_ doc: Presentation, _ index: Int, _ shapes: [Shape]) -> Data? {
        let xs = shapes.compactMap(\.xfrm).filter { $0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.h.isFinite }
        guard let first = xs.first, var p = page(doc, index, shapes) else { return nil }
        var box = CGRect(x: first.x, y: first.y, width: max(first.w, 0), height: max(first.h, 0))
        for x in xs.dropFirst() { box = box.union(CGRect(x: x.x, y: x.y, width: max(x.w, 0), height: max(x.h, 0))) }
        box = box.insetBy(dx: -8, dy: -8)
        guard box.width > 0, box.height > 0, box.width < 100_000, box.height < 100_000 else { return nil }
        p.slides[index].background = nil
        var opts = RenderOpts(scale: 2)
        opts.transparentBackground = true
        guard let list = recordSlide(p, index, nil, opts) else { return nil }
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: box.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        // The slide is drawn y down.
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: box.size)
        list.draw(in: ctx, view: Affine.translate(Vec2(-box.minX, -box.minY)) * Affine.scale(0.5), bounds: bounds, rasterScale: 2)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: Paste

    /// Whether the pasteboard still holds DeckCraft's last copy.
    var owned: Bool { ownedChange == board.changeCount }

    /// Whether the pasteboard has a picture.
    var hasImage: Bool {
        board.availableType(from: [.png, .tiff, .pdf]) != nil || imageFile() != nil
    }

    /// Paste (⌘V): the session's clipboard, a picture, or text from another app.
    @discardableResult
    func paste(_ model: AppModel, slides: Bool) -> Result<JSON, CommandError> {
        let action = PasteboardLogic.action(
            owned: owned, text: board.string(forType: .string), html: board.string(forType: .html), hasImage: hasImage
        )
        guard let params = PasteboardLogic.pasteParams(action, slides: slides) else { return pastePicture(model) }
        return model.run("edit.paste", params)
    }

    func paste(_ link: DocLink, slides: Bool) {
        link.activate()
        paste(link.model, slides: slides)
    }

    /// Paste and Match Formatting (⇧⌘V): the pasteboard's text as plain text.
    @discardableResult
    func pasteText(_ model: AppModel) -> Result<JSON, CommandError> {
        if !owned, let t = board.string(forType: .string), t != PasteboardLogic.objectsMarker, !t.isEmpty {
            return model.run("edit.pasteText", ["text": .string(t)])
        }
        return model.run("edit.pasteText")
    }

    /// An image file copied in Finder.
    private func imageFile() -> URL? {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { u in UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false }
    }

    /// The pasteboard's picture inserted (`insert.picture`), at most 16 megapixels.
    private func pastePicture(_ model: AppModel) -> Result<JSON, CommandError> {
        if board.availableType(from: [.png, .tiff, .pdf]) == nil, let url = imageFile() {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= 256 << 20, let data = try? Data(contentsOf: url) else {
                return fail(model, "the copied picture file can't be read")
            }
            return model.run("insert.picture", ["name": .string(url.lastPathComponent), "data": .string(Cmd.base64Encode([UInt8](data)))])
        }
        let png: Data
        if let d = board.data(forType: .png), let rep = NSBitmapImageRep(data: d) {
            if let problem = PasteboardLogic.imageProblem(width: rep.pixelsWide, height: rep.pixelsHigh) { return fail(model, problem) }
            png = d
        } else if let d = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: d) {
            if let problem = PasteboardLogic.imageProblem(width: rep.pixelsWide, height: rep.pixelsHigh) { return fail(model, problem) }
            guard let out = rep.representation(using: .png, properties: [:]) else { return fail(model, "the pasted image can't be read") }
            png = out
        } else if let d = board.data(forType: .pdf), let rep = NSPDFImageRep(data: d) {
            // A PDF picture (another app's vector copy) is drawn at twice its size.
            let w = Int((rep.bounds.width * 2).rounded()), h = Int((rep.bounds.height * 2).rounded())
            if let problem = PasteboardLogic.imageProblem(width: w, height: h) { return fail(model, problem) }
            guard let out = Self.rasterize(rep, w, h) else { return fail(model, "the pasted image can't be read") }
            png = out
        } else {
            return fail(model, "the pasteboard has no picture")
        }
        return model.run("insert.picture", ["name": "Pasted image.png", "data": .string(Cmd.base64Encode([UInt8](png)))])
    }

    private func fail(_ model: AppModel, _ message: String) -> Result<JSON, CommandError> {
        model.status = message
        model.changed()
        return .failure(CommandError(message))
    }

    /// A PDF picture as PNG at `w` × `h` pixels.
    static func rasterize(_ rep: NSPDFImageRep, _ w: Int, _ h: Int) -> Data? {
        guard w > 0, h > 0, let bmp = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: bmp) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return bmp.representation(using: .png, properties: [:])
    }

    // MARK: The Edit menu

    /// The standard action a text field or text view with the keyboard takes for an Edit menu command.
    static func textAction(_ id: String) -> Selector? {
        switch id {
        case "edit.cut": #selector(NSText.cut(_:))
        case "edit.copy": #selector(NSText.copy(_:))
        case "edit.paste": #selector(NSText.paste(_:))
        case "edit.pasteText": #selector(NSTextView.pasteAsPlainText(_:))
        case "edit.selectAll": #selector(NSText.selectAll(_:))
        default: nil
        }
    }

    /// The menu bar's Cut, Copy, Paste, Paste and Match Formatting and Select All (`app.handleMenu`).
    /// `responder` is the view with the keyboard (the key window's first responder; tests pass their own).
    func menuCommand(
        _ model: AppModel, _ id: String, _ params: JSON, responder: NSResponder? = NSApp.keyWindow?.firstResponder
    ) -> Result<JSON, CommandError> {
        if responder is NSText, let sel = Self.textAction(id), NSApp.sendAction(sel, to: nil, from: nil) {
            return .success(.null)
        }
        // The slide list has the keyboard (the navigator or the Slide Sorter): the command is the slides'.
        let slides = responder is NavigatorTable || responder is SorterCollectionView
        switch id {
        case "edit.copy": return copy(model, cut: false, slides: slides)
        case "edit.cut": return copy(model, cut: true, slides: slides)
        case "edit.paste": return paste(model, slides: slides)
        case "edit.pasteText": return pasteText(model)
        case "edit.selectAll": return model.run("edit.selectAll", slides ? ["scope": "slides"] : params)
        default: return model.run(id, params)
        }
    }
}
