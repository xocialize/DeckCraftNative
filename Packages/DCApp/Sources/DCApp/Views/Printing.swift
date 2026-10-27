// DCApp — File › Print (`app.print`) on NSPrintOperation. deckcraft had no printing (its gaps list, #6):
// `print_pdf` (`crates/ui-egui/src/lib.rs`, MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors) wrote a PDF with the Print page's options and opened it in the system's viewer. Here the
// same pages print natively: the presentation is laid out by DCRender's PDF export (`PDF.export`: each slide
// the renderer's recorded drawing, replayed as vectors) on the printer's paper, and each page is drawn into
// the print context as vectors. The print panel's accessory offers deckcraft's layouts (full-page slides,
// notes pages, handouts with 1–9 slides a page) and an outline, framing, hidden slides, and colour or
// grayscale. `{path}` prints to a PDF file without the panel (scripts and tests).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DCRender
import DesignScaffold

@MainActor
enum Printer {
    /// Paper margins (points): what most printers can reach.
    static let margin: CGFloat = 18

    /// `app.print`: the print panel for the active presentation (as a sheet on `window` when there is one,
    /// so a control-channel call answers at once), or with `{path}` a PDF of the printed pages, no panel.
    static func command(_ model: AppModel, _ p: JSON, window: NSWindow?) -> Result<JSON, CommandError> {
        guard let st = model.session.activeDoc else { return .failure("nothing to print: no presentation is open") }
        let settings: PrintSettings
        do { settings = try PrintSettings(params: p) } catch { return .failure(error) }
        let info = printInfo(settings)
        let view = PrintPagesView(doc: st.doc, title: st.displayTitle, settings: settings)
        // The pages are planned now, so a bad slide range is reported rather than printed blank.
        if case .failure(let e) = view.plan(info) { return .failure(e) }
        var answer = settings.json
        answer.setKey("pages", .integer(view.pageCount))
        if let path = p["path"]?.asStr {
            // The same pages on the same paper, drawn by the same code, saved as a PDF: no printer, no panel.
            let ok = view.writePDF(to: URL(filePath: path), paper: info.paperSize, margins: NSSize(width: info.leftMargin, height: info.topMargin))
            answer.setKey("printed", .bool(ok))
            answer.setKey("path", .string(path))
            return .success(answer)
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = st.displayTitle
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview, .showsCopies, .showsPageRange])
        op.printPanel.addAccessoryController(PrintAccessory(view))
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            _ = op.run()
        }
        answer.setKey("panel", true)
        return .success(answer)
    }

    /// The print info: the paper asked for (else the printer's), landscape for full-page slides unless
    /// asked otherwise, and narrow margins.
    static func printInfo(_ s: PrintSettings) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let landscape = s.landscape ?? (s.layout == .slides)
        if let id = s.paper, let size = PDF.paperSize(id, landscape: false) {
            info.paperSize = NSSize(width: size.0, height: size.1)
        }
        info.orientation = landscape ? .landscape : .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        return info
    }
}

extension JSON {
    /// Set `key` on an object (another value is left alone).
    mutating func setKey(_ key: String, _ value: JSON) {
        guard case .object(var o) = self else { return }
        o.set(key, value)
        self = .object(o)
    }
}

/// The printed pages: one paper-sized rect per page, stacked.
@MainActor
final class PrintPagesView: NSView {
    let doc: Presentation
    let title: String
    var settings: PrintSettings
    /// The pages as PDF (slides, notes, handouts) and the outline's lines per page.
    private var pdf: CGPDFDocument?
    private var outlinePages: [[OutlineLine]] = []
    private(set) var pageCount = 0
    private var pageSize = CGSize(width: 576, height: 756)
    private var plannedFor: (PrintSettings, CGSize)?

    override var isFlipped: Bool { true }

    init(doc: Presentation, title: String, settings: PrintSettings) {
        self.doc = doc
        self.title = title
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 576, height: 756))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Lay the pages out for `info`'s paper (again only when the settings or the paper changed).
    @discardableResult
    func plan(_ info: NSPrintInfo) -> Result<Int, CommandError> {
        let paper = info.paperSize
        let size = CGSize(width: max(72, paper.width - info.leftMargin - info.rightMargin), height: max(72, paper.height - info.topMargin - info.bottomMargin))
        if let p = plannedFor, p.0 == settings, p.1 == size { return .success(pageCount) }
        pageSize = size
        plannedFor = (settings, size)
        pdf = nil
        outlinePages = []
        do {
            let opts = try settings.pdfOptions(doc, paper: (Double(size.width), Double(size.height)))
            if settings.layout == .outline {
                outlinePages = paginate(PrintLogic.outline(doc, PrintLogic.slides(doc, opts)), size)
                pageCount = outlinePages.count
            } else {
                let data = try PDF.export(doc, opts)
                guard let provider = CGDataProvider(data: data as CFData), let d = CGPDFDocument(provider) else {
                    pageCount = 0
                    return .failure("the pages couldn't be laid out")
                }
                pdf = d
                pageCount = d.numberOfPages
            }
        } catch let e as CommandError {
            pageCount = 0
            return .failure(e)
        } catch {
            pageCount = 0
            return .failure(CommandError("\(error)"))
        }
        setFrameSize(NSSize(width: size.width, height: size.height * CGFloat(max(1, pageCount))))
        return .success(pageCount)
    }

    /// The pages as a PDF of `paper`-sized pages, each placed at `margins`, as the printer would place it.
    func writePDF(to url: URL, paper: NSSize, margins: NSSize) -> Bool {
        var media = CGRect(origin: .zero, size: paper)
        guard pageCount > 0, let ctx = CGContext(url as CFURL, mediaBox: &media, [kCGPDFContextTitle as String: title] as CFDictionary) else { return false }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        for n in 0 ..< pageCount {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Page space is y up; the pages are laid out y down, as the view is flipped.
            ctx.translateBy(x: 0, y: paper.height)
            ctx.scaleBy(x: 1, y: -1)
            let r = rectForPage(n + 1)
            ctx.translateBy(x: margins.width - r.minX, y: margins.height - r.minY)
            if settings.grayscale { ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil) }
            drawPage(n, in: r, ctx)
            if settings.grayscale {
                ctx.setBlendMode(.saturation)
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(r)
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.closePDF()
        return true
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo { plan(info) }
        range.pointee = NSRange(location: 1, length: max(1, pageCount))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(max(0, page - 1)) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for n in 0 ..< pageCount {
            let r = rectForPage(n + 1)
            guard r.intersects(dirtyRect) else { continue }
            ctx.saveGState()
            if settings.grayscale { ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil) }
            drawPage(n, in: r, ctx)
            if settings.grayscale {
                // Saturation from a gray: every colour of the page loses its saturation, vectors included.
                ctx.setBlendMode(.saturation)
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(r)
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
        }
    }

    private func drawPage(_ n: Int, in r: CGRect, _ ctx: CGContext) {
        if settings.layout == .outline {
            drawOutline(outlinePages.at(n) ?? [], in: r)
            return
        }
        guard let page = pdf?.page(at: n + 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        let k = min(r.width / box.width, r.height / box.height)
        let (w, h) = (box.width * k, box.height * k)
        ctx.saveGState()
        ctx.clip(to: r)
        // The view is flipped; PDF pages are y up.
        ctx.translateBy(x: r.midX - w / 2, y: r.midY + h / 2)
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    // MARK: Outline

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let indent: CGFloat = 24

    private static func attributed(_ l: OutlineLine) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent * CGFloat(l.level)
        style.headIndent = indent * CGFloat(l.level)
        style.paragraphSpacingBefore = l.isTitle ? 8 : 0
        let text = l.number.map { "\($0)  \(l.text)" } ?? l.text
        return NSAttributedString(string: text, attributes: [
            .font: l.isTitle ? titleFont : bodyFont, .foregroundColor: PaperColors.ink, .paragraphStyle: style,
        ])
    }

    private static func height(_ s: NSAttributedString, _ width: CGFloat) -> CGFloat {
        let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let r = s.boundingRect(with: NSSize(width: max(1, width - (style?.headIndent ?? 0)), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height) + (style?.paragraphSpacingBefore ?? 0)
    }

    /// The outline's lines in pages of `size`.
    private func paginate(_ lines: [OutlineLine], _ size: CGSize) -> [[OutlineLine]] {
        var pages: [[OutlineLine]] = [[]]
        var y: CGFloat = 0
        for l in lines {
            let h = Self.height(Self.attributed(l), size.width)
            if y + h > size.height, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                y = 0
            }
            pages[pages.count - 1].append(l)
            y += h
        }
        return pages.last?.isEmpty == true && pages.count == 1 ? [[]] : pages
    }

    private func drawOutline(_ lines: [OutlineLine], in r: CGRect) {
        var y = r.minY
        for l in lines {
            let s = Self.attributed(l)
            let h = Self.height(s, r.width)
            let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let before = style?.paragraphSpacingBefore ?? 0
            s.draw(with: NSRect(x: r.minX, y: y + before, width: r.width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h
        }
    }
}

/// The print panel's DeckCraft options: layout, framing, hidden slides, colour.
@MainActor
final class PrintAccessory: NSViewController, NSPrintPanelAccessorizing {
    let pages: PrintPagesView
    let layout = NSPopUpButton()
    let frame = NSButton(checkboxWithTitle: "Frame slides", target: nil, action: nil)
    let hidden = NSButton(checkboxWithTitle: "Print hidden slides", target: nil, action: nil)
    let color = NSPopUpButton()
    /// Bumped on every change, so the panel redraws its preview.
    @objc dynamic var version = 0

    init(_ pages: PrintPagesView) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        title = "DeckCraft"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        for l in PrintLayout.all { layout.addItem(withTitle: l.label) }
        layout.selectItem(at: PrintLayout.all.firstIndex(of: pages.settings.layout) ?? 0)
        color.addItems(withTitles: ["Color", "Grayscale"])
        color.selectItem(at: pages.settings.grayscale ? 1 : 0)
        frame.state = pages.settings.frame ? .on : .off
        hidden.state = pages.settings.includeHidden ? .on : .off
        for c in [layout, color, frame, hidden] as [NSControl] {
            c.target = self
            c.action = #selector(changed)
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Layout:"), layout],
            [NSGridCell.emptyContentView, frame],
            [NSGridCell.emptyContentView, hidden],
            [NSTextField(labelWithString: "Color:"), color],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = Tokens.Space.s
        grid.columnSpacing = Tokens.Space.s
        let root = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Tokens.Space.m),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Tokens.Space.m),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Tokens.Space.l),
        ])
        view = root
    }

    @objc private func changed() {
        var s = pages.settings
        s.layout = PrintLayout.all.at(layout.indexOfSelectedItem) ?? .slides
        s.frame = frame.state == .on
        s.includeHidden = hidden.state == .on
        s.grayscale = color.indexOfSelectedItem == 1
        pages.settings = s
        version += 1
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [
            [.itemName: "Layout", .itemDescription: pages.settings.layout.label],
            [.itemName: "Frame slides", .itemDescription: pages.settings.frame ? "On" : "Off"],
            [.itemName: "Hidden slides", .itemDescription: pages.settings.includeHidden ? "Printed" : "Not printed"],
            [.itemName: "Color", .itemDescription: pages.settings.grayscale ? "Grayscale" : "Color"],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["version"] }
}
