// DCEngine — the File menu: new, open, save, export, close, properties, AutoRecover.
// Port of deckcraft crates/engine/src/cmd/file.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import Foundation

/// What a file lost on opening.
public struct Damage: Sendable, Equatable {
    /// Pictures and media a `.deckcraft` file had lost or damaged.
    public var media: [String] = []
    /// Slides a `.pptx` lists but that couldn't be read, so they are not in the presentation.
    public var slides: [String] = []
    public init(media: [String] = [], slides: [String] = []) {
        self.media = media
        self.slides = slides
    }

    public var isEmpty: Bool { media.isEmpty && slides.isEmpty }
}

/// A presentation read from disk, not yet added to a session: `FileCommands.readPresentationFile` needs no
/// session, so a host can run it on a background thread, hand the result to `Session.stageLoaded` and add
/// it with `file.adopt`.
public struct LoadedFile: Sendable {
    public var path: String
    public var doc: Presentation
    /// A native or PPTX file (saving goes back to it); an outline import has no file to save to.
    public var native: Bool
    /// What the file had lost or damaged.
    public var damaged: Damage
}

/// Rust's `std::path::Path` name helpers, on `/`-separated strings.
enum RustPath {
    /// The last component (`file_name`), nil for `..`, `/` or empty.
    static func fileName(_ path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard let last = comps.last, last != ".." else { return nil }
        if path.hasSuffix("/.") { return nil }
        return String(last)
    }

    /// `file_stem`: the file name without its final extension (a leading dot is part of the name).
    static func fileStem(_ path: String) -> String? {
        guard let name = fileName(path) else { return nil }
        let b = Array(name.utf8)
        guard let dot = b.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return name }
        return String(decoding: b[..<dot], as: UTF8.self)
    }

    /// `extension`: after the file name's last dot, nil without one (or with only a leading dot).
    static func ext(_ path: String) -> String? {
        guard let name = fileName(path) else { return nil }
        let b = Array(name.utf8)
        guard let dot = b.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return nil }
        return String(decoding: b[(dot + 1)...], as: UTF8.self)
    }

    /// `with_file_name`: the last component replaced.
    static func withFileName(_ path: String, _ name: String) -> String {
        let b = Array(path.utf8)
        guard let slash = b.lastIndex(of: UInt8(ascii: "/")) else { return name }
        return String(decoding: b[...slash], as: UTF8.self) + name
    }
}

public enum FileCommands {
    public static func specs() -> [CommandSpec] {
        [
            .noundo("file.new", "New Presentation", ["File"], "Cmd+N", "{theme?: name, template?: starter name, size?: [w,h] pt, blank?: bool}", Cmd.always, new),
            .query("file.templates", "Starter Templates", [], nil, "{} → [{name, summary, theme, slides}]", Cmd.always, templates),
            .noundo("file.open", "Open…", ["File"], "Cmd+O", "{path}", Cmd.always, open),
            .noundo(
                "file.adopt",
                "Open",
                [],
                nil,
                "{path, token?} (a presentation the host read in the background and staged with Session::stage_loaded; without one, reads path like file.open)",
                Cmd.always,
                adopt
            ),
            .noundo("file.openBytes", "Open Data", [], nil, "{name, data: base64}", Cmd.always, openBytes),
            .noundo("file.save", "Save", ["File"], "Cmd+S", "{path?, format?: deckcraft|pptx}", Cmd.hasDoc, save),
            .noundo("file.saveAs", "Save As…", ["File"], "Cmd+Shift+S", "{path, format?}", Cmd.hasDoc, saveAs),
            .noundo("file.saveTemplate", "Save as Template…", ["File"], nil, "{path}", Cmd.hasDoc, saveAs),
            .query("file.saveBytes", "Save to Data", [], nil, "{format?: deckcraft|pptx} → {data: base64}", Cmd.hasDoc, saveBytesCmd),
            .noundo("file.export", "Export…", ["File"], nil, "{path, format?: png|jpeg|pptx|deckcraft|outline|rtf|pdf|gif (else by path), slide?: index, all?: bool, scale?: px per pt, layout?: slides|notes|handouts (pdf), perPage?: 1|2|3|4|6|9, paper?: letter|a4|legal|a3 (pdf), orientation?: portrait|landscape (pdf), dpi?, slides?: [index]|range (\"1-3,5\"), includeHidden?, textLayer?, frame?, transparentBackground?: bool (png: leave the slide background out), width?: px 16-3840|small|medium|large|extraLarge (gif), secondsPerSlide?: 0.1-600 (gif; 5), loop?: bool (gif; true: forever)} → {path, bytes} or {files} (png, jpeg); gif adds frames, width, height, secondsPerSlide", Cmd.hasDoc, export),
            .query("file.info", "Info", ["File"], nil, "{} → {title, path, format, dirty, slides, hiddenSlides, sections, bytes?, properties}", Cmd.hasDoc, info),
            .query("file.render", "Render Slide", [], nil, "{slide?: index, scale?, edit?: bool, transparentBackground?: bool} → {png: base64, width, height}", Cmd.hasDoc, render),
            .query(
                "slide.colorAt",
                "Color At",
                [],
                nil,
                "{slide?: index, x, y (slide units), scale?: px per unit (2)} → {color: \"RRGGBB\", alpha: 0..255, x, y}: the colour drawn at a point of the slide (the Eyedropper)",
                Cmd.hasDoc,
                colorAt
            ),
            .noundo("file.close", "Close", ["File"], "Cmd+W", "{}", Cmd.hasDoc, close),
            .cmd(
                "file.properties",
                "Properties",
                ["File"],
                nil,
                "{title?, subject?, author?, keywords?, comments?, category?, company?} → properties",
                Cmd.hasDoc,
                properties
            ),
            .noundo("file.recovery.save", "Save AutoRecover Information", [], nil, "{} → {written}", Cmd.hasDoc, recoverySave),
            .query("file.recovery.list", "Recovered Presentations", [], nil, "{} → [{uid, path, title, saved}]", Cmd.always, recoveryList),
            .noundo("file.recovery.open", "Open Recovered Presentations", [], nil, "{} → {opened: [document index]}", Cmd.always, recoveryOpen),
            .noundo("file.recovery.discard", "Discard Recovered Presentations", [], nil, "{uid?: one entry (else all)}", Cmd.always, recoveryDiscard),
            .noundo("file.revert", "Revert", [], nil, "{}", Cmd.hasDoc, revert),
            .noundo("window.next", "Next Window", ["Window"], "Cmd+`", "{index?}", Cmd.hasDoc, nextWindow),
        ]
    }

    static func eqIgnoreASCIICase(_ a: String, _ b: String) -> Bool { Array(rustASCIILowercase(a).utf8) == Array(rustASCIILowercase(b).utf8) }

    static func themeNamed(_ name: String) -> Theme? { builtinThemes().first { eqIgnoreASCIICase($0.name, name) } }

    static func slideSize(_ p: JSON) -> Size {
        if let a = p.get("size")?.asArray, let w = a.at(0)?.asF64, let h = a.at(1)?.asF64,
           w >= 1, h >= 1, w < 5000, h < 5000 {
            return Size(w, h)
        }
        return wideSlideSize
    }

    @Sendable static func templates(_ s: Session, _ p: JSON) throws -> JSON {
        ["templates": .array(Templates.starters().map { t in
            ["name": .string(t.name), "summary": .string(t.summary), "theme": .string(t.theme), "slides": .integer(t.slides.count)]
        })]
    }

    @Sendable static func new(_ s: Session, _ p: JSON) throws -> JSON {
        let template = Cmd.strParam(p, "template").flatMap { $0.isEmpty ? nil : $0 }
        let themeName = Cmd.strParam(p, "theme").flatMap { $0.isEmpty ? nil : $0 }
        if template != nil && themeName != nil { throw Cmd.bad("file.new", "pass `theme` or `template`, not both") }
        if template != nil && Cmd.boolOr(p, "blank", false) { throw Cmd.bad("file.new", "a template is not a blank presentation") }
        let size = slideSize(p)
        let doc: Presentation
        var templateName: String?
        if let name = template {
            doc = try Templates.build(name, size)
            templateName = Templates.find(name)?.name
        } else {
            let theme = themeName.flatMap(themeNamed) ?? .default
            doc = blankPresentation(size, theme, !Cmd.boolOr(p, "blank", false))
        }
        let slides = doc.slides.count
        let title = s.nextUntitled()
        let i = s.addDocument(DocState(doc, path: nil, title: title))
        var out: JSON = ["document": .integer(i), "slides": .integer(slides)]
        if let name = templateName { out.set("template", .string(name)) }
        return out
    }

    /// Recognise and read presentation bytes (native, PPTX).
    public static func openPresentation(_ name: String, _ bytes: [UInt8]) throws -> Presentation {
        try openChecked(name, bytes).0
    }

    /// `openPresentation`, plus what the file had lost or damaged.
    public static func openChecked(_ name: String, _ bytes: [UInt8]) throws -> (Presentation, Damage) {
        if DeckFormat.sniff(bytes) {
            do {
                let (p, media) = try DeckFormat.loadChecked(bytes)
                return (p, Damage(media: media, slides: []))
            } catch {
                throw EngineError.other(error.description)
            }
        }
        let (p, slides) = try openOther(name, bytes)
        return (p, Damage(media: [], slides: slides))
    }

    private static func openOther(_ name: String, _ bytes: [UInt8]) throws -> (Presentation, [String]) {
        if PPTX.sniff(bytes) {
            var p: Presentation
            let lost: [String]
            do { (p, lost) = try PPTX.importChecked(bytes) } catch { throw EngineError.other(error.description) }
            DeckFormat.repair(&p)
            probeClips(&p)
            return (p, lost)
        }
        if PPTX.isEncrypted(bytes) {
            throw EngineError.other("\(name) is password-protected. DeckCraft can't open password-protected presentations yet.")
        }
        let lower = rustASCIILowercase(name)
        let rtf = RTF.sniff(bytes)
        if rtf || lower.hasSuffix(".txt") || lower.hasSuffix(".md") {
            var text = String(decoding: bytes, as: UTF8.self)
            if rtf { text = RTF.rtfToOutline(text) }
            var p = blankPresentation(wideSlideSize, .default, false)
            if lower.hasSuffix(".md") {
                _ = DeckFormat.markdownToSlides(&p, text)
            } else {
                _ = DeckFormat.outlineToSlides(&p, text)
            }
            if p.slides.isEmpty { p = newPresentation(nil) }
            return (p, [])
        }
        throw EngineError.other("\(name): not a presentation DeckCraft can read")
    }

    /// Fill in each audio and video clip's length and picture size from its bytes: a `.pptx` doesn't
    /// store them. Headers only, so opening never decodes a whole audio file. Without DCMedia wired in
    /// (`EngineMedia.prober`), clips keep what the file said.
    static func probeClips(_ p: inout Presentation) {
        guard let prober = EngineMedia.prober else { return }
        var probed: [MediaId: EngineMediaInfo?] = [:]
        let media = p.media
        func rec(_ shapes: inout [Shape], _ depth: Int) {
            if depth > 64 { return }
            for i in shapes.indices {
                if case .media(var m) = shapes[i].kind, m.durationMs == 0 || (m.width == 0 && m.height == 0) {
                    if probed[m.media] == nil {
                        probed[m.media] = .some(media.first { $0.id == m.media }.flatMap { prober.probeHeaders($0.data) })
                    }
                    if let info = probed[m.media] ?? nil {
                        if m.durationMs == 0 { m.durationMs = UInt32(min(info.durationMs, UInt64(UInt32.max))) }
                        if m.width == 0 && m.height == 0, let v = info.video { (m.width, m.height) = (v.width, v.height) }
                        shapes[i].kind = .media(m)
                    }
                }
                shapes[i].mutateChildren { rec(&$0, depth + 1) }
            }
        }
        for i in p.slides.indices { rec(&p.slides[i].shapes, 0) }
    }

    /// An outline file's text: RTF is read into the tab-indented outline, anything else as UTF-8.
    public static func outlineText(_ bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return RTF.sniff(bytes) ? RTF.rtfToOutline(text) : text
    }

    @discardableResult
    public static func addOpened(_ s: Session, _ name: String, _ path: String?, _ p: Presentation) -> Int {
        let title = RustPath.fileStem(name) ?? name
        EngineFonts.installEmbeddedFonts(p)
        let missing = EngineFonts.missingFonts(p)
        let st = DocState(p, path: path, title: title)
        st.missingFonts = missing
        return s.addDocument(st)
    }

    /// Read and parse the presentation at `path`.
    public static func readPresentationFile(_ path: String) throws -> LoadedFile {
        let bytes = try IO.readFile(path)
        let (doc, damaged) = try openChecked(path, bytes)
        let native = DeckFormat.sniff(bytes) || PPTX.sniff(bytes)
        return LoadedFile(path: path, doc: doc, native: native, damaged: damaged)
    }

    /// Add a loaded presentation as the active document: the shared end of `file.open` and `file.adopt`.
    /// A damaged file opens as an untitled repaired copy, so Save can't overwrite the original with the
    /// empty media.
    private static func adoptLoaded(_ s: Session, _ f: LoadedFile) throws -> JSON {
        let keepPath = f.native && f.damaged.isEmpty
        let i = addOpened(s, f.path, keepPath ? f.path : nil, f.doc)
        try reportDamage(s, f.damaged)
        let st = try s.doc()
        return [
            "document": .integer(i), "slides": .integer(st.doc.slides.count), "missingFonts": st.missingFonts.toJSON(),
            "damagedMedia": f.damaged.media.toJSON(), "lostSlides": f.damaged.slides.toJSON(),
        ]
    }

    @Sendable static func open(_ s: Session, _ p: JSON) throws -> JSON {
        guard let path = Cmd.strParam(p, "path") else { throw Cmd.bad("file.open", "missing `path`") }
        return try adoptLoaded(s, readPresentationFile(path))
    }

    /// `file.adopt {path, token?}`: add the presentation a host read in the background and staged with
    /// `Session.stageLoaded`. Without that staged file (a replayed journal, a stale token) it reads `path`
    /// like `file.open`, so the journal entry stays replayable.
    @Sendable static func adopt(_ s: Session, _ p: JSON) throws -> JSON {
        guard let path = Cmd.strParam(p, "path") else { throw Cmd.bad("file.adopt", "missing `path`") }
        if let t = p.get("token")?.asU64, let f = s.takeLoaded(t), f.path == path {
            return try adoptLoaded(s, f)
        }
        return try adoptLoaded(s, readPresentationFile(path))
    }

    @Sendable static func openBytes(_ s: Session, _ p: JSON) throws -> JSON {
        let name = Cmd.strParam(p, "name") ?? "Presentation"
        guard let data = Cmd.strParam(p, "data").flatMap(Cmd.base64Decode) else {
            throw Cmd.bad("file.openBytes", "missing or invalid base64 `data`")
        }
        let (doc, damaged) = try openChecked(name, data)
        let i = addOpened(s, name, nil, doc)
        try reportDamage(s, damaged)
        return try [
            "document": .integer(i), "missingFonts": s.doc().missingFonts.toJSON(), "damagedMedia": damaged.media.toJSON(),
            "lostSlides": damaged.slides.toJSON(),
        ]
    }

    /// Tell the user which pictures, media and slides a damaged file lost, and mark the copy repaired.
    private static func reportDamage(_ s: Session, _ damaged: Damage) throws {
        if damaged.isEmpty { return }
        let st = try s.docMut()
        st.title = "\(st.title) (Repaired)"
        var text = ""
        var n = damaged.media.count
        if n > 0 {
            text = "\(n) picture\(n == 1 ? "" : "s") or media file\(n == 1 ? "" : "s") in this presentation couldn't be read and \(n == 1 ? "is" : "are") empty. "
        }
        n = damaged.slides.count
        if n > 0 {
            text += "\(n) slide\(n == 1 ? "" : "s") in this file couldn't be read and \(n == 1 ? "was" : "were") left out. "
        }
        text += "It was opened as a repaired copy; save it under a new name to keep the original file."
        s.uiRequests.append(.message(text: text))
    }

    /// Encode the presentation in `format` (`deckcraft`, `pptx`, `potx`, `ppsx`, `outline`, `pdf`, `gif`).
    public static func saveBytes(_ doc: Presentation, _ format: String) throws -> [UInt8] {
        switch format {
        case "pptx", "potx", "ppsx":
            do { return try PPTX.exportAs(doc, format) } catch { throw EngineError.other(error.description) }
        case "outline", "txt":
            return Array(DeckFormat.slidesToOutline(doc).utf8)
        case "rtf":
            return Array(RTF.slidesToRTF(doc).utf8)
        case "pdf":
            do { return [UInt8](try PDF.export(doc, PDFOptions())) } catch { throw EngineError.other(error.description) }
        case "gif":
            return try gifBytes(doc, .null)
        default:
            do { return try DeckFormat.save(doc) } catch { throw EngineError.other(error.description) }
        }
    }

    /// PDF options from command params: `{layout: slides|notes|handouts, perPage, dpi, slides,
    /// includeHidden, textLayer, frame, paper: letter|a4|legal|a3, orientation: portrait|landscape}` for a
    /// presentation of `count` slides. `slides` is a list of 0-based indices or a range as typed in
    /// PowerPoint's Print page (`"1-3, 5"`, 1-based).
    public static func pdfOptions(_ p: JSON, _ count: Int) throws -> PDFOptions {
        var o = PDFOptions()
        switch Cmd.strParam(p, "layout") ?? "slides" {
        case "notes": o.layout = .notes
        case "handouts": o.layout = .handouts(perPage: UInt8(min(max(Cmd.usizeParam(p, "perPage") ?? 6, 1), 9)))
        default: o.layout = .slides
        }
        o.dpi = Cmd.f64Or(p, "dpi", o.dpi).clamped(36, 600)
        switch p.get("slides") {
        case .array(let a)?: o.slides = a.compactMap(\.asU64).compactMap { Int(exactly: $0) }.filter { $0 < count }
        case .string(let text)? where !rustTrim(text).isEmpty: o.slides = try parseSlideRange(text, count)
        default: o.slides = nil
        }
        o.includeHidden = Cmd.boolOr(p, "includeHidden", false)
        o.textLayer = Cmd.boolOr(p, "textLayer", true)
        o.frameSlides = Cmd.boolOr(p, "frame", true)
        let landscape: Bool
        switch Cmd.strParam(p, "orientation") ?? "portrait" {
        case "portrait": landscape = false
        case "landscape": landscape = true
        case let other: throw Cmd.bad("file.export", "orientation “\(other)” isn't portrait or landscape")
        }
        let paper = Cmd.strParam(p, "paper") ?? "letter"
        guard let size = PDF.paperSize(paper, landscape: landscape) else {
            throw Cmd.bad("file.export", "paper “\(paper)” isn't one of \(PDF.papers.map(\.id).joined(separator: ", "))")
        }
        o.paper = size
        return o
    }

    /// A slide range as typed in the Print page's Slides box (`"1-3, 5"`; 1-based, either separator `,` or
    /// `;`, ranges either way round) → 0-based indices in order, without repeats. Numbers past the last
    /// slide or a range that isn't numbers is an error, as in PowerPoint.
    public static func parseSlideRange(_ text: String, _ count: Int) throws -> [Int] {
        let invalid = Cmd.bad("file.export", "“\(text)” isn't a valid slide range: use numbers and ranges such as 1-3, 5")
        var out: [Int] = []
        let parts = text.split(omittingEmptySubsequences: false) { $0 == "," || $0 == ";" }.map { String(rustTrim(String($0))) }.filter { !$0.isEmpty }
        for part in parts {
            let a: String
            let b: String
            if let dash = part.firstIndex(of: "-") {
                a = String(rustTrim(String(part[..<dash])))
                b = String(rustTrim(String(part[part.index(after: dash)...])))
            } else {
                (a, b) = (part, part)
            }
            guard let x = parseUsize(a), let y = parseUsize(b) else { throw invalid }
            let (lo, hi) = (min(x, y), max(x, y))
            if lo == 0 || hi > count { throw Cmd.bad("file.export", "the presentation has \(count) slides; “\(part)” is outside them") }
            for i in (lo - 1) ..< hi where !out.contains(i) { out.append(i) }
        }
        if out.isEmpty { throw invalid }
        return out
    }

    /// `str::parse::<usize>`: ASCII digits with an optional leading `+`.
    static func parseUsize(_ s: String) -> Int? {
        var t = Substring(s)
        if t.hasPrefix("+") { t = t.dropFirst() }
        guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return Int(t)
    }

    /// PDF bytes for `doc` with `pdfOptions` from `p`.
    public static func pdfBytes(_ doc: Presentation, _ p: JSON) throws -> [UInt8] {
        do { return [UInt8](try PDF.export(doc, pdfOptions(p, doc.slides.count))) } catch let e as PDFError { throw EngineError.other(e.description) }
    }

    /// The output extensions `formatForPath` maps to a writer of that format.
    public static let writableExtensions = ["deckcraft", "pptx", "potx", "ppsx", "pdf", "png", "jpg", "jpeg", "gif", "txt", "md", "rtf"]

    /// The format a file named `path` is written in, or nil when its extension names no format DeckCraft
    /// writes (`.odp`, `.svg`, no extension …).
    public static func writableFormatForPath(_ path: String) -> String? {
        guard let ext = RustPath.ext(path) else { return nil }
        return writableExtensions.contains(rustASCIILowercase(ext)) ? formatForPath(path) : nil
    }

    /// Animated GIF bytes for `doc` with the options in `p`.
    public static func gifBytes(_ doc: Presentation, _ p: JSON) throws -> [UInt8] {
        try GifExport.encode(doc, GifExport.options(p)).bytes
    }

    public static func formatForPath(_ path: String) -> String {
        let l = rustASCIILowercase(path)
        if l.hasSuffix(".pptx") { return "pptx" }
        if l.hasSuffix(".potx") { return "potx" }
        if l.hasSuffix(".ppsx") { return "ppsx" }
        if l.hasSuffix(".png") { return "png" }
        if l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") { return "jpeg" }
        if l.hasSuffix(".pdf") { return "pdf" }
        if l.hasSuffix(".gif") { return "gif" }
        if l.hasSuffix(".txt") || l.hasSuffix(".md") { return "outline" }
        if l.hasSuffix(".rtf") { return "rtf" }
        return "deckcraft"
    }

    private static func markSaved(_ s: Session, _ path: String?) throws {
        let st = try s.docMut()
        st.savedDocRef = st.docRef
        if let path { st.path = path }
        st.revision += 1
        if let dir = s.recoveryDir { Recovery.discard(dir, st.uid) }
    }

    static func writeFile(_ path: String, _ bytes: [UInt8]) throws { try IO.writeFile(path, bytes) }

    @Sendable static func save(_ s: Session, _ p: JSON) throws -> JSON {
        guard let path = Cmd.strParam(p, "path") ?? s.activeDoc?.path else {
            s.uiRequests.append(.pickFile(purpose: "saveAs"))
            return ["needsPath": true]
        }
        let format = Cmd.strParam(p, "format") ?? formatForPath(path)
        let bytes = try saveBytes(s.doc().doc, format)
        try writeFile(path, bytes)
        try markSaved(s, path)
        return ["path": .string(path), "bytes": .integer(bytes.count)]
    }

    @Sendable static func saveAs(_ s: Session, _ p: JSON) throws -> JSON {
        if Cmd.strParam(p, "path") == nil {
            s.uiRequests.append(.pickFile(purpose: "saveAs"))
            return ["needsPath": true]
        }
        return try save(s, p)
    }

    @Sendable static func saveBytesCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let format = Cmd.strParam(p, "format") ?? "deckcraft"
        let bytes = try saveBytes(s.doc().doc, format)
        return ["data": .string(Cmd.base64Encode(bytes)), "bytes": .integer(bytes.count)]
    }

    /// `scale` for rendering `doc`'s slides to an image: within 0.01–16, and small enough that the slide
    /// fits the renderer's largest picture.
    public static func imageScale(_ doc: Presentation, _ scale: Double) -> Double {
        let s = scale.isFinite ? scale.clamped(0.01, 16) : 1
        let longest = doc.slideSize.width.rustMax(doc.slideSize.height).rustMax(1)
        return s.rustMin(Double(maxRenderSide) / longest)
    }

    /// Render slide `index` to PNG bytes (`render_png`).
    public static func renderPNG(_ doc: Presentation, _ index: Int, _ scale: Double, _ edit: Bool) -> ([UInt8], Int, Int) {
        renderPNGWith(doc, index, scale, edit, false)
    }

    /// `renderPNG`; `transparent` leaves the slide background out (#784).
    public static func renderPNGWith(_ doc: Presentation, _ index: Int, _ scale: Double, _ edit: Bool, _ transparent: Bool) -> ([UInt8], Int, Int) {
        let k = imageScale(doc, scale)
        var opts = RenderOpts(scale: k)
        opts.edit = edit
        opts.transparentBackground = transparent
        let img = renderSlide(doc, index, opts)
        return (ImageEncoding.png(img, dpi: ImageEncoding.dpiForScale(k)), img.width, img.height)
    }

    private static func finiteScale(_ scale: Double) -> Double { scale.isFinite ? scale.clamped(0.01, 16) : 1 }

    private static func pictureBytes(_ img: RenderImage, _ format: String, _ scale: Double) -> [UInt8] {
        let dpi = ImageEncoding.dpiForScale(scale)
        return format == "png" ? ImageEncoding.png(img, dpi: dpi) : ImageEncoding.jpeg(img, quality: 92, dpi: dpi)
    }

    @Sendable static func render(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let i = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        if i >= st.doc.slides.count { throw Cmd.bad("file.render", "no slide \(i)") }
        let (png, w, h) = renderPNGWith(st.doc, i, Cmd.f64Or(p, "scale", 1), Cmd.boolOr(p, "edit", false), Cmd.boolOr(p, "transparentBackground", false))
        return ["png": .string(Cmd.base64Encode(png)), "width": .integer(w), "height": .integer(h)]
    }

    /// The colour the slide is drawn with at one point: what the Eyedropper takes.
    @Sendable static func colorAt(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let i = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        if i >= st.doc.slides.count { throw Cmd.bad("slide.colorAt", "no slide \(i)") }
        func coord(_ key: String) throws -> Double {
            guard let v = p.get(key)?.asF64, v.isFinite else { throw Cmd.bad("slide.colorAt", "`\(key)` (a number, in slide units) is required") }
            return v
        }
        let (x, y) = (try coord("x"), try coord("y"))
        let scale = Cmd.f64Or(p, "scale", 2).clamped(0.01, 16)
        let img = renderSlide(st.doc, i, RenderOpts(scale: scale))
        let (px, py) = (x * scale, y * scale)
        let inside = px >= 0 && py >= 0 && px < Double(img.width) && py < Double(img.height)
        guard inside, let c = img.straight(Int(UInt32(rustCast: px)), Int(UInt32(rustCast: py))), c.count == 4 else {
            throw Cmd.bad("slide.colorAt", "the point is outside the slide")
        }
        return ["color": .string(rustHex(c[0], width: 2) + rustHex(c[1], width: 2) + rustHex(c[2], width: 2)), "alpha": .integer(c[3]), "x": .num(x), "y": .num(y)]
    }

    @Sendable static func export(_ s: Session, _ p: JSON) throws -> JSON {
        guard let path = Cmd.strParam(p, "path") else { throw Cmd.bad("file.export", "missing `path`") }
        let format = Cmd.strParam(p, "format") ?? formatForPath(path)
        let st = try s.doc()
        let doc = st.doc
        let scale = finiteScale(Cmd.f64Or(p, "scale", 2))
        let transparent = Cmd.boolOr(p, "transparentBackground", false)
        if transparent && format != "png" {
            throw Cmd.bad("file.export", "a transparent background is for PNG export, not \(format)")
        }
        switch format {
        case "png", "jpeg", "jpg":
            let slides: [Int]
            if let i = Cmd.usizeParam(p, "slide") {
                slides = [i]
            } else if Cmd.boolOr(p, "all", false) {
                slides = Array(0 ..< doc.slides.count)
            } else {
                slides = [st.selection.slide]
            }
            // Every slide checked before any file is written, so a bad index leaves nothing behind.
            if let i = slides.first(where: { $0 >= doc.slides.count }) { throw Cmd.bad("file.export", "no slide \(i)") }
            let k = imageScale(doc, scale)
            var written: [String] = []
            for (n, i) in slides.enumerated() {
                var opts = RenderOpts(scale: k)
                opts.transparentBackground = transparent
                let img = renderSlide(doc, i, opts)
                let bytes = pictureBytes(img, format, k)
                let out: String
                if slides.count == 1 {
                    out = path
                } else {
                    let stem = RustPath.fileStem(path) ?? "Slide"
                    let ext = RustPath.ext(path) ?? format
                    out = RustPath.withFileName(path, "\(stem)\(n + 1).\(ext)")
                }
                // Say which slides made it when one can't be written (disk full part-way).
                do {
                    try writeFile(out, bytes)
                } catch {
                    if written.isEmpty { throw error }
                    throw EngineError.other("\(EngineError.from(error).description) (slides 1–\(n) were written)")
                }
                written.append(out)
            }
            return ["files": written.toJSON()]
        case "pdf":
            let bytes = try pdfBytes(doc, p)
            try writeFile(path, bytes)
            return ["path": .string(path), "bytes": .integer(bytes.count)]
        case "gif":
            // `slides` may be a range, as for PDF ("1-3,5").
            var gp = p
            if let text = p.get("slides")?.asStr { gp.set("slides", try parseSlideRange(text, doc.slides.count).toJSON()) }
            let out = try GifExport.encode(doc, GifExport.options(gp))
            try writeFile(path, out.bytes)
            return [
                "path": .string(path), "bytes": .integer(out.bytes.count), "frames": .integer(out.frames), "width": .integer(out.width),
                "height": .integer(out.height), "secondsPerSlide": .num(Double(out.delayCs) / 100),
            ]
        case "pptx", "potx", "ppsx", "deckcraft", "outline", "txt", "rtf":
            let bytes = try saveBytes(doc, format)
            try writeFile(path, bytes)
            return ["path": .string(path), "bytes": .integer(bytes.count)]
        default:
            throw Cmd.bad("file.export", "unknown format `\(format)`")
        }
    }

    /// File › Info: what the Info page shows about the active presentation.
    @Sendable static func info(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let doc = st.doc
        let bytes = st.path.flatMap(IO.fileLen)
        return [
            "title": .string(st.displayTitle),
            "path": .opt(st.path),
            "format": .opt(st.path.map(formatForPath)),
            "dirty": .bool(st.isDirty),
            "slides": .integer(doc.slides.count),
            "hiddenSlides": .integer(doc.slides.filter(\.hidden).count),
            "sections": .integer(doc.sections.count),
            "bytes": .opt(bytes),
            "properties": doc.props.toJSON(),
        ]
    }

    @Sendable static func close(_ s: Session, _ p: JSON) throws -> JSON {
        if let i = s.activeIndex { s.closeDocument(i) }
        return Cmd.ok()
    }

    @Sendable static func properties(_ s: Session, _ p: JSON) throws -> JSON {
        let fields = ["title", "subject", "author", "keywords", "comments", "category", "company"]
        if fields.contains(where: { p.get($0) != nil }) {
            try s.edit { doc, _ in
                for f in fields {
                    guard let v = Cmd.strParam(p, f) else { continue }
                    switch f {
                    case "title": doc.props.title = v
                    case "subject": doc.props.subject = v
                    case "author": doc.props.author = v
                    case "keywords": doc.props.keywords = v
                    case "comments": doc.props.comments = v
                    case "category": doc.props.category = v
                    default: doc.props.company = v
                    }
                }
            }
        }
        return try s.doc().doc.props.toJSON()
    }

    @Sendable static func revert(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.docMut()
        st.docRef = st.savedDocRef
        st.history = History(limit: st.history.limit)
        st.revision += 1
        return Cmd.ok()
    }

    @Sendable static func nextWindow(_ s: Session, _ p: JSON) throws -> JSON {
        let n = s.documents.count
        if n == 0 { return Cmd.ok() }
        let i = Cmd.usizeParam(p, "index") ?? ((s.activeIndex ?? 0) + 1) % n
        s.setActive(min(i, n - 1))
        return Cmd.ok()
    }

    private static func recoveryDir(_ s: Session) throws -> URL {
        guard let d = s.recoveryDir else { throw EngineError.other("no recovery folder is set") }
        return d
    }

    @Sendable static func recoverySave(_ s: Session, _ p: JSON) throws -> JSON {
        let dir = try recoveryDir(s)
        return try ["written": .integer(Recovery.save(s, dir))]
    }

    @Sendable static func recoveryList(_ s: Session, _ p: JSON) throws -> JSON {
        let dir = try recoveryDir(s)
        return .array(Recovery.list(dir).map { uid, m in
            var m = m
            if m.isObject { m.set("uid", .integer(uid)) }
            return m
        })
    }

    @Sendable static func recoveryOpen(_ s: Session, _ p: JSON) throws -> JSON {
        let dir = try recoveryDir(s)
        return try ["opened": Recovery.open(s, dir).toJSON()]
    }

    @Sendable static func recoveryDiscard(_ s: Session, _ p: JSON) throws -> JSON {
        let dir = try recoveryDir(s)
        if let uid = p.get("uid")?.asU64 {
            Recovery.discard(dir, uid)
        } else {
            for (uid, _) in Recovery.list(dir) { Recovery.discard(dir, uid) }
        }
        return Cmd.ok()
    }
}
