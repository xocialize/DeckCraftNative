// DCEngine — the `insert` command module: shapes, text boxes, pictures, photo albums, tables, charts, audio,
// video, WordArt, fields, links and action buttons.
// Port of deckcraft crates/engine/src/cmd/insert.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCMedia
import DCModel
import DCRender
import DCText
import Foundation
import ImageIO

public enum InsertCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "shape.insert",
                "Shapes",
                ["Insert", "Illustrations"],
                nil,
                "{preset: rect|roundRect|ellipse|triangle|rightArrow|star5|… (see shape.presets), rect: [x,y,w,h] pt, text?: string}",
                Cmd.hasSlide,
                insertShape
            ),
            .cmd(
                "insert.icon",
                "Icons",
                ["Insert", "Illustrations"],
                nil,
                "{name: star|arrow-right|… (see insert.icons), rect?: [x,y,w,h]}",
                Cmd.hasSlide,
                insertIcon
            ),
            .query("insert.icons", "Icon Gallery", [], nil, "{} → [{name, label, category}]", Cmd.always, listIcons),
            .query("shape.presets", "Shape Gallery", [], nil, "{} → [{name, label, category}]", Cmd.always, presets),
            .cmd("insert.textBox", "Text Box", ["Insert", "Text"], nil, "{rect?: [x,y,w,h], text?: string}", Cmd.hasSlide, textBox),
            .cmd(
                "insert.picture",
                "Picture from File…",
                ["Insert", "Images", "Pictures"],
                nil,
                "{path? | data: base64, name?, rect?: [x,y,w,h]}",
                Cmd.hasSlide,
                picture
            ),
            .cmd(
                "insert.photoAlbum",
                "Photo Album…",
                ["Insert", "Images"],
                nil,
                "{pictures?: [{path?|data: base64, name?, rot?: deg, brightness?: -1..1, contrast?: -1..1} | {text}], layout?: fit|1|2|4|1title|2title|4title, frame?: none|rect|rounded|simple, captions?: bool, grayscale?: bool, theme?: name} — omit pictures to open the dialog",
                Cmd.hasDoc,
                photoAlbum
            ),
            .cmd(
                "insert.photoAlbumEdit",
                "Edit Photo Album…",
                ["Insert", "Images"],
                nil,
                "{album?: id, pictures?: same as insert.photoAlbum, layout?, frame?, captions?, grayscale?, theme?} — omit pictures to reopen the dialog on the current album",
                Cmd.hasDoc,
                photoAlbumEdit
            ),
            .cmd("insert.table", "Table…", ["Insert", "Tables"], nil, "{rows, cols, rect?}", Cmd.hasSlide, table),
            .cmd(
                "insert.chart",
                "Chart…",
                ["Insert", "Illustrations"],
                nil,
                "{type?: column|bar|line|pie|doughnut|area|scatter|stackedColumn|…, rect?, categories?: [..], series?: [{name, values}]}",
                Cmd.hasSlide,
                chart
            ),
            .cmd("insert.audio", "Audio from File…", ["Insert", "Media", "Audio"], nil, "{path? | data: base64, name?, rect?}", Cmd.hasSlide, audio),
            .cmd("insert.video", "Video from File…", ["Insert", "Media", "Video"], nil, "{path? | data: base64, name?, rect?}", Cmd.hasSlide, video),
            .cmd("insert.wordArt", "WordArt", ["Insert", "Text"], nil, "{text?, style?: 0..}", Cmd.hasSlide, wordArt),
            .cmd("insert.slideNumber", "Slide Number", ["Insert", "Text"], nil, "{}", Cmd.hasSlide, slideNumber),
            .cmd(
                "insert.dateTime",
                "Date & Time",
                ["Insert", "Text"],
                nil,
                "{format?: datetime1..datetime13, update?: bool, language?: en-US|en-GB|fr-FR|ja-JP|sv-SE} — no keys opens the dialog",
                Cmd.hasSlide,
                dateTime
            ),
            .cmd("insert.symbol", "Symbol", ["Insert", "Symbols"], nil, "{text: character(s)}", Cmd.hasSlide, symbol),
            .cmd(
                "shape.action",
                "Action Settings",
                ["Insert", "Links"],
                nil,
                "{on?: click|hover, action: none|next|previous|first|last|lastViewed|endShow|playMedia|slide|url|customShow|program, slide?: index, url?, show?: custom show name, path?, highlight?: bool, tooltip?, ids?}",
                Cmd.hasSelection,
                shapeAction
            ),
            .cmd(
                "insert.hyperlink",
                "Link",
                ["Insert", "Links"],
                "Cmd+K",
                "{url? | slide?: index, tooltip?, text?: shown when nothing is selected, highlightClick?, ids?}",
                Cmd.hasTextOrShapes,
                hyperlink
            ),
            .cmd("chart.type", "Change Chart Type", ["Chart Design", "Type"], nil, "{type, id?}", Cmd.hasSelection, chartTypeCmd),
            .cmd(
                "chart.data",
                "Edit Data",
                ["Chart Design", "Data"],
                nil,
                "{categories?: [..], levels?: [[..]] (outer category levels, innermost first), series?: [{name, values}], id?}",
                Cmd.hasSelection,
                chartData
            ),
            .cmd(
                "chart.options",
                "Chart Elements",
                ["Chart Design", "Chart Layouts"],
                nil,
                "{title?: string|null, legend?: b|t|l|r|null, dataLabels?: bool, gridlines?: bool, palette?, binCount?: n|null, binSize?: n|null, subtotals?: [point index], quartiles?: exclusive|inclusive, upDownBars?: bool, textColor?: #RRGGBB|accent1..6|tx1…|null (title, axes, legend and labels; null for PowerPoint's default: the theme's text colour at 65 % plus 35 %, 595959 on a light theme), id?}",
                Cmd.hasSelection,
                chartOptions
            ),
            .cmd(
                "insert.smartArt",
                "SmartArt",
                ["Insert", "Illustrations"],
                nil,
                "{kind: list|process|cycle|hierarchy|pyramid|matrix, items?: [text] (leading tabs = sub-points), nodes?: [{text, level}]} → {id}",
                Cmd.hasSlide,
                smartArt
            ),
            .cmd(
                "insert.actionButton",
                "Action Buttons",
                ["Insert", "Illustrations"],
                nil,
                "{kind: back|forward|beginning|end|home|information|return|movie|document|sound|help|custom, rect?}",
                Cmd.hasSlide,
                actionButton
            ),
        ]
    }

    // MARK: - Shared helpers (called by other modules)

    /// Default size for a click-inserted shape (1 inch square, PowerPoint style), centred on the slide.
    static func defaultRect(_ s: Session, _ w: Double, _ h: Double) -> Xfrm {
        let size = s.activeDoc?.doc.slideSize ?? wideSlideSize
        return Xfrm((size.width - w) / 2.0, (size.height - h) / 2.0, w, h)
    }

    /// The word an automatic shape name starts with ("Rectangle" in "Rectangle 3").
    public static func autoNameBase(_ shape: Shape) -> String {
        switch shape.kind {
        case .picture: return "Picture"
        case .table: return "Table"
        case .chart: return "Chart"
        case .media(let m): return m.video ? "Video" : "Audio"
        case .model3d: return "3D Model"
        default:
            if shape.textBox { return "TextBox" }
            guard let info = shape.geom.presetName.flatMap(Preset.info) else { return "Shape" }
            let first = info.label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? info.label
            return String(rustTrim(first))
        }
    }

    /// Add `shape` to the edited tree with a fresh id (and an automatic name when it has none);
    /// `select` makes it the selection (`add_shape`).
    public static func addShape(_ s: Session, _ cmd: String, _ shape: Shape, _ select: Bool) throws -> ShapeId {
        var shape = shape
        return try s.edit { doc, sel in
            guard let raw = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
            shape.id = ShapeId(raw)
            if shape.name.isEmpty {
                let base = autoNameBase(shape)
                let taken = Cmd.currentNames(doc, sel)
                shape.name = firstFreeName(base, taken)
            }
            let id = shape.id
            let added = shape
            try withShapes(&doc, sel, missing: Cmd.bad("insert", "no slide")) { list in list.append(added) }
            if select {
                sel.shapes = [id]
                sel.text = nil
            }
            return id
        }
    }

    /// Read media bytes from `data` (base64) or `path` (`media_bytes`).
    public static func mediaBytes(_ p: JSON, _ cmd: String) throws -> (String, [UInt8]) {
        if let d = Cmd.strParam(p, "data") {
            guard let bytes = Cmd.base64Decode(d) else { throw Cmd.bad(cmd, "invalid base64 `data`") }
            return (Cmd.strParam(p, "name") ?? "media", bytes)
        }
        if let path = Cmd.strParam(p, "path") {
            let bytes = try IO.readFile(path)
            return (RustPath.fileName(path) ?? "media", bytes)
        }
        throw Cmd.bad(cmd, "missing `path` or `data`")
    }

    /// The content type of media `bytes` named `name`, by signature first (`content_type`).
    public static func contentType(_ name: String, _ bytes: [UInt8]) -> String {
        let l = rustASCIILowercase(name)
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes[0 ..< prefix.count]) == prefix }
        func at(_ a: Int, _ b: Int, _ want: String) -> Bool { bytes.count >= b && Array(bytes[a ..< b]) == Array(want.utf8) }
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
        let b0 = bytes.first ?? 0
        let b1 = bytes.count > 1 ? bytes[1] : 0
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8]) { return "image/jpeg" }
        if starts(ascii("GIF8")) { return "image/gif" }
        if starts(ascii("RIFF")) && at(8, 12, "WEBP") { return "image/webp" }
        if starts(ascii("RIFF")) && at(8, 12, "WAVE") { return "audio/wav" }
        if starts(ascii("BM")) { return "image/bmp" }
        if starts(ascii("II*\0")) || starts(ascii("MM\0*")) { return "image/tiff" }
        if starts(ascii("fLaC")) { return "audio/flac" }
        if starts(ascii("OggS")) { return l.hasSuffix(".ogv") ? "video/ogg" : "audio/ogg" }
        // ADTS (layer bits 00): AAC.
        if bytes.count > 1 && b0 == 0xFF && b1 & 0xF6 == 0xF0 { return "audio/aac" }
        if starts(ascii("ID3")) || (bytes.count > 1 && b0 == 0xFF && (b1 & 0xE0) == 0xE0 && !l.hasSuffix(".aac")) { return "audio/mpeg" }
        if starts(ascii("FORM")) { return "audio/aiff" }
        if at(4, 8, "ftyp") {
            if l.hasSuffix(".m4a") || l.hasSuffix(".m4b") || at(8, 11, "M4A") { return "audio/mp4" }
            if l.hasSuffix(".mov") || at(8, 12, "qt  ") { return "video/quicktime" }
            return "video/mp4"
        }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) {
            if l.hasSuffix(".mka") || l.hasSuffix(".weba") { return "audio/webm" }
            if l.hasSuffix(".mkv") { return "video/x-matroska" }
            return "video/webm"
        }
        if starts([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return l.hasSuffix(".wmv") || l.hasSuffix(".asf") ? "video/x-ms-wmv" : "audio/x-ms-wma"
        }
        if starts(ascii("caff")) { return "audio/x-caf" }
        if l.hasSuffix(".svg") || hasSVGTag(bytes) { return "image/svg+xml" }
        if l.hasSuffix(".aac") { return "audio/aac" }
        return "application/octet-stream"
    }

    /// `bytes.windows(4).take(512).any(|w| w == b"<svg")`.
    private static func hasSVGTag(_ bytes: [UInt8]) -> Bool {
        let tag = Array("<svg".utf8)
        guard bytes.count >= 4 else { return false }
        for i in 0 ..< min(512, bytes.count - 3) where bytes[i] == tag[0] && bytes[i + 1] == tag[1] && bytes[i + 2] == tag[2] && bytes[i + 3] == tag[3] {
            return true
        }
        return false
    }

    /// A text box: wrapping, growing to fit its text (`new_text_box`).
    public static func newTextBox(_ rect: Xfrm, _ text: String) -> Shape {
        var body = TextBody.fromText(text)
        body.body.wrap = true
        body.body.autofit = .shape
        var sh = Shape.default
        sh.xfrm = rect
        sh.textBox = true
        sh.fill = nil
        sh.text = body
        sh.geom = .preset("rect")
        return sh
    }

    /// A raster picture's pixel size from its header (the `image` crate's `into_dimensions`). Nil for
    /// what isn't a raster ImageIO reads (SVG included, as for the `image` crate).
    static func pixelSize(_ bytes: [UInt8]) -> (Int, Int)? {
        guard !bytes.isEmpty,
              let src = CGImageSourceCreateWithData(Data(bytes) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        if let t = CGImageSourceGetType(src) as String?, t == "public.svg-image" || t == "com.adobe.pdf" { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// `str::eq_ignore_ascii_case`.
    static func eqIgnoreASCIICase(_ a: String, _ b: String) -> Bool {
        Array(rustASCIILowercase(a).utf8) == Array(rustASCIILowercase(b).utf8)
    }

    // MARK: - Shapes, icons, text boxes

    @Sendable static func insertShape(_ s: Session, _ p: JSON) throws -> JSON {
        let preset = Cmd.strParam(p, "preset") ?? "rect"
        guard let info = Preset.info(preset) else { throw Cmd.bad("shape.insert", "unknown preset `\(preset)`") }
        let lineLike = Preset.isLineLike(preset)
        let rect = Cmd.rectParam(p, "rect") ?? defaultRect(s, 72.0, lineLike ? 0.0 : 72.0)
        let adj: [Double] = p.get("adj")?.asArray.map { $0.compactMap(\.asF64) } ?? []
        var shape = Shape.default
        shape.xfrm = rect
        shape.geom = .preset(name: info.name, adj: adj)
        shape.style = lineLike ? ShapeStyle.line(.accent1) : ShapeStyle.accent(.accent1)
        if let fl = p.get("flip")?.asStr {
            shape.xfrm?.flipH = fl.contains("h")
            shape.xfrm?.flipV = fl.contains("v")
        }
        if !lineLike {
            var empty = TextBody.default
            empty.paragraphs = []
            shape.text = empty
            if let t = Cmd.strParam(p, "text") { shape.text = TextBody.fromText(t) }
            if var tb = shape.text {
                for i in tb.paragraphs.indices { tb.paragraphs[i].props.align = .center }
                shape.text = tb
            }
        } else {
            shape.kind = preset.contains("Connector") ? .connector(start: nil, end: nil) : .shape
            if preset == "straightConnector1" {
                shape.line = Line(tail: LineEnd(kind: "triangle", w: "med", len: "med"))
            }
        }
        if let look = s.defaultLook, !lineLike {
            FormatCommands.applyPainted(&shape, look)
        }
        let id = try addShape(s, "shape.insert", shape, true)
        return ["id": id.toJSON()]
    }

    @Sendable static func presets(_ s: Session, _ p: JSON) throws -> JSON {
        .array(Preset.catalog.map { i in ["name": .string(i.name), "label": .string(i.label), "category": .string(i.category.label)] })
    }

    @Sendable static func listIcons(_ s: Session, _ p: JSON) throws -> JSON {
        .array(Icons.icons.map { i in ["name": .string(i.name), "label": .string(i.label), "category": .string(i.category)] })
    }

    /// A Lucide stroke icon: custom geometry, no fill, round line scaled from the 24-unit design.
    @Sendable static func insertIcon(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("insert.icon", "missing `name`") }
        guard let icon = Icons.find(name) else { throw Cmd.bad("insert.icon", "unknown icon `\(name)`") }
        guard let d = Icons.pathData(icon.name) else { throw Cmd.bad("insert.icon", "could not build icon `\(icon.name)`") }
        let rect = Cmd.rectParam(p, "rect") ?? defaultRect(s, 72.0, 72.0)
        if rect.w < 1.0 || rect.h < 1.0 { throw Cmd.bad("insert.icon", "rect needs a positive width and height") }
        var shape = Shape.default
        shape.name = icon.label
        shape.xfrm = rect
        shape.geom = .custom(paths: [CustomPath(w: Icons.view, h: Icons.view, d: d, fill: .none, stroke: true)])
        shape.fill = Fill.none_
        shape.line = Line(fill: .solid(.scheme(.tx1)), width: Icons.strokeWidth(icon, rect.w, rect.h), cap: .round, join: .round)
        shape.style = ShapeStyle.line(.tx1)
        let id = try addShape(s, "insert.icon", shape, true)
        return ["id": id.toJSON()]
    }

    @Sendable static func textBox(_ s: Session, _ p: JSON) throws -> JSON {
        let text = Cmd.strParam(p, "text") ?? ""
        let rect = Cmd.rectParam(p, "rect") ?? defaultRect(s, 216.0, 36.0)
        var shape = newTextBox(rect, text)
        // Click-to-create (no width) text boxes grow sideways without wrapping.
        if rect.w < 1.0 {
            var x = rect
            x.w = 100.0
            shape.xfrm = x
            shape.text?.body.wrap = false
        }
        let id = try addShape(s, "insert.textBox", shape, true)
        try TextCommands.fitTextBox(s, id)
        if text.isEmpty {
            // Start typing immediately.
            try s.select { _, sel in
                sel.shapes = [id]
                sel.text = TextSel(shape: id)
            }
        }
        return ["id": id.toJSON()]
    }

    // MARK: - Pictures

    /// Natural size of an image in points (96 dpi), fitted inside the slide.
    static func fitted(_ s: Session, _ bytes: [UInt8]) -> (Double, Double) {
        let (w, h) = pixelSize(bytes).map { (Double($0.0) * 0.75, Double($0.1) * 0.75) } ?? (288.0, 216.0)
        let size = s.activeDoc?.doc.slideSize ?? wideSlideSize
        let k = (size.width * 0.9 / w.rustMax(1.0)).rustMin(size.height * 0.9 / h.rustMax(1.0)).rustMin(1.0)
        return (w * k, h * k)
    }

    @Sendable static func picture(_ s: Session, _ p: JSON) throws -> JSON {
        let (name, bytes) = try mediaBytes(p, "insert.picture")
        let ct = contentType(name, bytes)
        if !ct.hasPrefix("image/") { throw Cmd.bad("insert.picture", "\(name) is not a picture") }
        if ct != "image/svg+xml" && Images.decode(bytes) == nil {
            throw EngineError.other("\(name): the picture can't be read")
        }
        let (w, h) = fitted(s, bytes)
        // Into a selected empty picture/content placeholder, if there is one.
        var targetPh: (ShapeId, Xfrm)?
        if let d = s.activeDoc {
            if let x = d.selectedShapes.first(where: { x in
                guard let k = x.phType, k == .picture || k == .obj || k == .body else { return false }
                return x.text.map(\.isEmpty) ?? true
            }) {
                targetPh = (x.id, Cmd.xfrmOf(d.doc, d.selection, x))
            }
        }
        let given = Cmd.rectParam(p, "rect")
        let rect: Xfrm = given ?? targetPh.map(\.1) ?? defaultRect(s, w, h)
        var crop: [Double] = [0, 0, 0, 0]
        if targetPh != nil && given == nil {
            // Fill the placeholder, cropping the picture to its aspect.
            let ia = w / h.rustMax(1e-9)
            let ba = rect.w / rect.h.rustMax(1e-9)
            if ia > ba {
                let c = (1.0 - ba / ia) / 2.0
                crop = [c, 0.0, c, 0.0]
            } else {
                let c = (1.0 - ia / ba) / 2.0
                crop = [0.0, c, 0.0, c]
            }
        }
        let media = try s.edit { doc, _ in
            guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("insert.picture", Cmd.noIdSpace) }
            return m
        }
        var shape = Shape.default
        shape.xfrm = rect
        shape.kind = .picture(fill: PictureFill(media: media, crop: crop))
        shape.descr = name
        if let (phId, _) = targetPh {
            // Replace the placeholder with the picture (it keeps the placeholder link).
            let phv = try s.doc().shape(phId)?.ph
            let kind = shape.kind
            try s.edit { doc, sel in
                try withShapes(&doc, sel, missing: Cmd.bad("insert.picture", "no slide")) { list in
                    if let i = list.firstIndex(where: { $0.id == phId }) {
                        list[i].kind = kind
                        list[i].xfrm = rect
                        list[i].ph = phv.map { ph in
                            var ph = ph
                            ph.kind = .picture
                            return ph
                        }
                        list[i].text = nil
                        list[i].descr = name
                    }
                }
                sel.shapes = [phId]
            }
            return ["id": phId.toJSON()]
        }
        let id = try addShape(s, "insert.picture", shape, true)
        return ["id": id.toJSON()]
    }

    // MARK: - Photo album

    static let albumMaxItems = 48
    static let albumMaxBytes = 32 * 1024 * 1024
    static let albumMaxTotal = 64 * 1024 * 1024
    static let albumMaxText = 400

    struct AlbumLayout {
        var cols: Int
        var rows: Int
        var per: Int
        var title: Bool
        var fit: Bool
    }

    enum AlbumFrame { case none, rect, rounded, simple }

    struct AlbumPic {
        var name: String
        var bytes: [UInt8]
        var pxW: Double
        var pxH: Double
        var rot: Double
        var brightness: Double
        var contrast: Double
    }

    struct AlbumOpts {
        var layoutKey: String
        var frameKey: String
        var layout: AlbumLayout
        var frame: AlbumFrame
        var captions: Bool
        var grayscale: Bool
        var theme: String?
    }

    enum AlbumItem {
        case picture(AlbumPic)
        case text(String)
    }

    enum AlbumSlide {
        case pictures([AlbumPic])
        case text(String)
    }

    /// Insert a photo album after the current slide. PowerPoint starts a new presentation; these slides go
    /// into the open one, so the album is one undo step. Omitting `pictures` asks the UI to open the dialog
    /// and does not edit.
    @Sendable static func photoAlbum(_ s: Session, _ p: JSON) throws -> JSON {
        if p.get("pictures")?.isNull ?? true {
            s.uiRequests.append(.dialog(id: "photoAlbum", params: .emptyObject))
            return ["dialog": "photoAlbum"]
        }
        let opts = try albumOpts(p)
        let items = try albumItems(p)
        return try commitAlbum(s, items, opts, nil)
    }

    @Sendable static func photoAlbumEdit(_ s: Session, _ p: JSON) throws -> JSON {
        if p.get("pictures")?.isNull ?? true {
            let seed = try albumSeed(s)
            let album = seed.get("album") ?? .null
            s.uiRequests.append(.dialog(id: "photoAlbum", params: seed))
            return ["dialog": "photoAlbum", "album": album]
        }
        let opts = try albumOpts(p)
        let items = try albumItems(p)
        let (id, ids) = try albumTarget(s, p)
        return try commitAlbum(s, items, opts, (id, ids))
    }

    static func commitAlbum(_ s: Session, _ items: [AlbumItem], _ opts: AlbumOpts, _ replace: (UInt32, [UInt64])?) throws -> JSON {
        let st = try s.doc()
        let snapshot = st.docRef
        let sel = st.selection
        do {
            let albumId: UInt32
            if let r = replace, r.0 != 0 {
                albumId = r.0
            } else {
                let cmd = replace != nil ? "insert.photoAlbumEdit" : "insert.photoAlbum"
                albumId = try s.edit { doc, _ in
                    guard let id = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                    return id
                }
            }
            var at: Int?
            if let (_, ids) = replace {
                let doc = try s.doc().doc
                let indices = ids.compactMap { id in UInt32(exactly: id).flatMap { doc.slideIndex(SlideId($0)) } }
                guard let first = indices.min() else {
                    throw Cmd.bad("insert.photoAlbumEdit", "that photo album is no longer in this presentation")
                }
                _ = try s.execute("slide.delete", ["ids": .array(ids.map { .uint($0) })])
                at = first
            }
            var opts = opts
            if (opts.theme ?? "").isEmpty {
                opts.theme = s.activeDoc?.doc.masters.first.map(\.theme.name).flatMap { $0.isEmpty ? nil : $0 }
            }
            try applyThemeIfNeeded(s, opts.theme)
            return try insertAlbum(s, items, opts, at, albumId)
        } catch {
            if let st = s.activeDoc {
                st.docRef = snapshot
                st.selection = sel
            }
            throw error
        }
    }

    static func albumNorm(_ s: String) -> String {
        rustASCIILowercase(String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)) })))
    }

    static func albumLayout(_ p: JSON) throws -> AlbumLayout {
        guard let v = p.get("layout") else { return AlbumLayout(cols: 1, rows: 1, per: 1, title: false, fit: false) }
        guard case .string(let key) = v else { throw Cmd.bad("insert.photoAlbum", "`layout` must be text") }
        switch albumNorm(key) {
        case "fit": return AlbumLayout(cols: 1, rows: 1, per: 1, title: false, fit: true)
        case "1", "one": return AlbumLayout(cols: 1, rows: 1, per: 1, title: false, fit: false)
        case "1title", "onetitle": return AlbumLayout(cols: 1, rows: 1, per: 1, title: true, fit: false)
        case "2", "two": return AlbumLayout(cols: 2, rows: 1, per: 2, title: false, fit: false)
        case "2title", "twotitle": return AlbumLayout(cols: 2, rows: 1, per: 2, title: true, fit: false)
        case "4", "four": return AlbumLayout(cols: 2, rows: 2, per: 4, title: false, fit: false)
        case "4title", "fourtitle": return AlbumLayout(cols: 2, rows: 2, per: 4, title: true, fit: false)
        default: throw Cmd.bad("insert.photoAlbum", "unknown layout `\(key)` (use fit, 1, 2, 4, 1title, 2title or 4title)")
        }
    }

    static func albumFrame(_ p: JSON) throws -> AlbumFrame {
        guard let v = p.get("frame") else { return .none }
        guard case .string(let key) = v else { throw Cmd.bad("insert.photoAlbum", "`frame` must be text") }
        switch albumNorm(key) {
        case "none": return .none
        case "rect", "rectangle": return .rect
        case "rounded", "round", "roundedrect", "roundedrectangle": return .rounded
        case "simple", "simpleframe", "simplewhite", "white": return .simple
        default: throw Cmd.bad("insert.photoAlbum", "unknown frame `\(key)` (use none, rect, rounded or simple)")
        }
    }

    static func albumCaptions(_ p: JSON) throws -> Bool {
        guard let v = p.get("captions") else { return false }
        guard case .bool(let b) = v else { throw Cmd.bad("insert.photoAlbum", "`captions` must be true or false") }
        return b
    }

    static func albumBool(_ p: JSON, _ key: String) throws -> Bool {
        guard let v = p.get(key), !v.isNull else { return false }
        guard case .bool(let b) = v else { throw Cmd.bad("insert.photoAlbum", "`\(key)` must be true or false") }
        return b
    }

    static func layoutKeyOf(_ layout: AlbumLayout) -> String {
        if layout.fit { return "fit" }
        let n = switch layout.per {
        case 2: "2"
        case 4: "4"
        default: "1"
        }
        return layout.title ? "\(n)title" : n
    }

    static func frameKeyOf(_ frame: AlbumFrame) -> String {
        switch frame {
        case .none: "none"
        case .rect: "rect"
        case .rounded: "rounded"
        case .simple: "simple"
        }
    }

    static func albumOpts(_ p: JSON) throws -> AlbumOpts {
        let layout = try albumLayout(p)
        let frame = try albumFrame(p)
        var theme: String?
        switch p.get("theme") {
        case nil, .null?:
            theme = nil
        case .string(let s)?:
            let name = String(rustTrim(s))
            if name.isEmpty {
                theme = nil
            } else {
                guard let t = builtinThemes().first(where: { eqIgnoreASCIICase($0.name, name) }) else {
                    throw Cmd.bad("insert.photoAlbum", "unknown theme `\(name)`")
                }
                theme = t.name
            }
        default:
            throw Cmd.bad("insert.photoAlbum", "`theme` must be a theme name")
        }
        return AlbumOpts(
            layoutKey: layoutKeyOf(layout), frameKey: frameKeyOf(frame), layout: layout, frame: frame,
            captions: try albumCaptions(p), grayscale: try albumBool(p, "grayscale"), theme: theme
        )
    }

    /// A finite number, or 0 when the key is absent. A present non-number is an error.
    static func albumFinite(_ item: JSON, _ key: String) throws -> Double {
        guard let v = item.get(key), !v.isNull else { return 0.0 }
        guard let n = v.asF64, n.isFinite else { throw Cmd.bad("insert.photoAlbum", "`\(key)` must be a number") }
        return n
    }

    static func albumRot(_ item: JSON) throws -> Double {
        let n = try albumFinite(item, "rot")
        return (n.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    static func albumUnit(_ item: JSON, _ key: String) throws -> Double {
        let n = try albumFinite(item, key)
        if !(-1.0 ... 1.0).contains(n) { throw Cmd.bad("insert.photoAlbum", "`\(key)` must be between -1 and 1") }
        return n
    }

    static func albumItems(_ p: JSON) throws -> [AlbumItem] {
        guard let arr = p.get("pictures")?.asArray else { throw Cmd.bad("insert.photoAlbum", "`pictures` must be a list") }
        if arr.isEmpty { throw Cmd.bad("insert.photoAlbum", "add at least one picture or text box") }
        if arr.count > albumMaxItems { throw Cmd.bad("insert.photoAlbum", "a photo album holds at most 48 pictures or text boxes") }
        var items: [AlbumItem] = []
        items.reserveCapacity(arr.count)
        var total = 0
        for item in arr {
            guard let obj = item.asObject else { throw Cmd.bad("insert.photoAlbum", "each album item must be a picture or a text box") }
            let hasMedia = obj["data"] != nil || obj["path"] != nil
            if !hasMedia {
                guard let raw = obj["text"]?.asStr else { throw Cmd.bad("insert.photoAlbum", "each album item needs `path`, `data` or `text`") }
                let text = String(rustTrim(raw))
                if text.isEmpty { throw Cmd.bad("insert.photoAlbum", "a text box needs some text") }
                if text.unicodeScalars.count > albumMaxText { throw Cmd.bad("insert.photoAlbum", "text is longer than 400 characters") }
                items.append(.text(text))
                continue
            }
            let (name, bytes) = try mediaBytes(item, "insert.photoAlbum")
            if bytes.count > albumMaxBytes { throw Cmd.bad("insert.photoAlbum", "\(name) is larger than 32 MB") }
            let next = total.addingReportingOverflow(bytes.count)
            let sum = next.overflow ? Int.max : next.partialValue
            if sum > albumMaxTotal { throw Cmd.bad("insert.photoAlbum", "the album is larger than 64 MB") }
            total = sum
            let ct = contentType(name, bytes)
            if !ct.hasPrefix("image/") { throw Cmd.bad("insert.photoAlbum", "\(name) is not a picture") }
            if ct != "image/svg+xml" && Images.decode(bytes) == nil { throw Cmd.bad("insert.photoAlbum", "\(name): the picture can't be read") }
            let (pxW, pxH) = imagePx(bytes)
            items.append(.picture(AlbumPic(
                name: name, bytes: bytes, pxW: pxW, pxH: pxH, rot: try albumRot(item),
                brightness: try albumUnit(item, "brightness"), contrast: try albumUnit(item, "contrast")
            )))
        }
        return items
    }

    static func imagePx(_ bytes: [UInt8]) -> (Double, Double) {
        guard let (w, h) = pixelSize(bytes), w > 0, h > 0 else { return (4.0, 3.0) }
        return (Double(w), Double(h))
    }

    static func fileStem(_ name: String) -> String {
        let base = RustPath.fileName(name) ?? name
        var stem = base
        if let dot = base.lastIndex(of: ".") {
            let s = base[..<dot]
            let ext = base[base.index(after: dot)...]
            if !s.isEmpty && !ext.isEmpty { stem = String(s) }
        }
        return stem.isEmpty ? "Picture" : stem
    }

    static func albumPlan(_ items: [AlbumItem], _ per: Int) -> [AlbumSlide] {
        let per = max(per, 1)
        var out: [AlbumSlide] = []
        var batch: [AlbumPic] = []
        for item in items {
            switch item {
            case .text(let text):
                if !batch.isEmpty {
                    out.append(.pictures(batch))
                    batch = []
                }
                out.append(.text(text))
            case .picture(let pic):
                batch.append(pic)
                if batch.count >= per {
                    out.append(.pictures(batch))
                    batch = []
                }
            }
        }
        if !batch.isEmpty { out.append(.pictures(batch)) }
        return out
    }

    struct Placed {
        var pic: [Double]
        var caption: [Double]?
    }

    static func fitIn(_ boxW: Double, _ boxH: Double, _ pxW: Double, _ pxH: Double) -> (Double, Double) {
        let aspect = pxH > 0.0 ? pxW / pxH : 4.0 / 3.0
        let boxW = boxW.rustMax(1.0)
        let boxH = boxH.rustMax(1.0)
        if !aspect.isFinite || aspect <= 0.0 { return (boxW, boxH) }
        return aspect >= boxW / boxH ? (boxW, (boxW / aspect).rustMax(1.0)) : ((boxH * aspect).rustMax(1.0), boxH)
    }

    static func placeAlbum(_ width: Double, _ height: Double, _ layout: AlbumLayout, _ n: Int, _ captions: Bool) -> ([Double]?, [Placed]) {
        let margin = layout.fit ? 18.0 : 36.0
        let titleBand = layout.title ? 48.0 : 0.0
        let gap = 12.0
        let capH = 22.0
        let capGap = 4.0
        let left = margin
        let top = margin + titleBand
        let gridW = (width - margin - left).rustMax(1.0)
        let gridH = (height - margin - top).rustMax(1.0)
        let cols = max(layout.cols, 1)
        let rows = max(layout.rows, 1)
        let cellW = ((gridW - gap * Double(cols - 1)) / Double(cols)).rustMax(1.0)
        let cellH = ((gridH - gap * Double(rows - 1)) / Double(rows)).rustMax(1.0)
        let picH = captions ? (cellH - capH - capGap).rustMax(1.0) : cellH
        var placed: [Placed] = []
        for i in 0 ..< max(n, 0) {
            let col = i % cols
            let row = i / cols
            if row >= rows { break }
            let cellX = left + Double(col) * (cellW + gap)
            let cellY = top + Double(row) * (cellH + gap)
            placed.append(Placed(pic: [cellX, cellY, cellW, picH], caption: nil))
        }
        let title: [Double]? = layout.title ? [margin, 8.0, (width - 2.0 * margin).rustMax(1.0), 32.0] : nil
        return (title, placed)
    }

    static func placePictures(_ width: Double, _ height: Double, _ layout: AlbumLayout, _ pics: [AlbumPic], _ captions: Bool) -> ([Double]?, [Placed]) {
        let (title, slots) = placeAlbum(width, height, layout, pics.count, captions)
        let placed = zip(pics, slots).map { pic, slot -> Placed in
            let (dw, dh) = fitIn(slot.pic[2], slot.pic[3], pic.pxW, pic.pxH)
            let x = slot.pic[0] + (slot.pic[2] - dw) / 2.0
            let y = slot.pic[1] + (slot.pic[3] - dh) / 2.0
            let caption: [Double]? = captions ? [x, y + dh + 4.0, dw.rustMax(36.0), 22.0] : nil
            return Placed(pic: [x, y, dw, dh], caption: caption)
        }
        return (title, placed)
    }

    static func applyFrame(_ s: Session, _ frame: AlbumFrame, _ id: UInt64) throws {
        let params: JSON
        switch frame {
        case .none: return
        case .rect: params = ["id": .uint(id), "color": "#1A1A1A", "width": 1.5]
        case .rounded: params = ["id": .uint(id), "color": "#1A1A1A", "width": 2.25, "join": "round"]
        case .simple: params = ["id": .uint(id), "color": "#FFFFFF", "width": 6.0]
        }
        _ = try s.execute("shape.line", params)
    }

    struct AlbumMark {
        var id: UInt32
        var layout: String
        var frame: String
        var captions: Bool
        var grayscale: Bool
        var theme: String
    }

    static let albumPrefix = "deckcraft-album:"

    static func parseAlbumMark(_ raw: String) -> AlbumMark? {
        guard raw.hasPrefix(albumPrefix) else { return nil }
        let rest = String(raw.dropFirst(albumPrefix.count))
        let idStr: String
        let tail: String
        if let semi = rest.firstIndex(of: ";") {
            idStr = String(rest[..<semi])
            tail = String(rest[rest.index(after: semi)...])
        } else {
            idStr = rest
            tail = ""
        }
        guard let id = rustParseU32(idStr), id != 0 else { return nil }
        var mark = AlbumMark(id: id, layout: "", frame: "", captions: false, grayscale: false, theme: "")
        if !tail.isEmpty {
            for part in tail.split(separator: ";", omittingEmptySubsequences: false) {
                guard let eq = part.firstIndex(of: "=") else { continue }
                let k = String(part[..<eq])
                let v = String(part[part.index(after: eq)...])
                switch k {
                case "layout": mark.layout = v
                case "frame": mark.frame = v
                case "captions": mark.captions = v == "1"
                case "gray": mark.grayscale = v == "1"
                case "theme": mark.theme = v
                default: break
                }
            }
        }
        return mark
    }

    /// Rust's `str::parse::<u32>`: ASCII digits with an optional leading `+`.
    static func rustParseU32(_ s: String) -> UInt32? {
        var digits = Substring(s)
        if digits.hasPrefix("+") { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return UInt32(digits)
    }

    static func albumMarker(_ id: UInt32, _ opts: AlbumOpts) -> String {
        let theme = opts.theme ?? ""
        return "deckcraft-album:\(id);layout=\(opts.layoutKey);frame=\(opts.frameKey);captions=\(opts.captions ? 1 : 0);gray=\(opts.grayscale ? 1 : 0);theme=\(theme)"
    }

    static func stampAlbumSlide(_ s: Session, _ albumId: UInt32, _ opts: AlbumOpts) throws {
        let marker = albumMarker(albumId, opts)
        try s.edit { doc, sel in
            guard sel.slide >= 0, sel.slide < doc.slides.count else { throw Cmd.bad("insert.photoAlbum", "no slide to mark") }
            if doc.slides[sel.slide].rawExt.map({ $0.hasPrefix(albumPrefix) }) ?? true {
                doc.slides[sel.slide].rawExt = marker
            }
            doc.slides[sel.slide].name = "Photo Album"
        }
    }

    static func applyThemeIfNeeded(_ s: Session, _ theme: String?) throws {
        guard let name = theme, !name.isEmpty else { return }
        let current = try s.doc().doc.masters.first?.theme.name ?? ""
        if eqIgnoreASCIICase(current, name) { return }
        _ = try s.execute("design.theme", ["name": .string(name)])
    }

    static func albumIdParam(_ p: JSON) -> UInt32? {
        switch p.get("album") {
        case .string(let s)?:
            return rustParseU32(String(rustTrim(s))).flatMap { $0 != 0 ? $0 : nil }
        case let v? where v.isNumber:
            return v.asU64.flatMap { UInt32(exactly: $0) }.flatMap { $0 != 0 ? $0 : nil }
        default:
            return nil
        }
    }

    static func slidesWithAlbum(_ doc: Presentation, _ id: UInt32) -> [UInt64] {
        doc.slides.filter { $0.rawExt.flatMap(parseAlbumMark)?.id == id }.map { UInt64($0.id.rawValue) }
    }

    static func albumNameRun(_ doc: Presentation, _ index: Int) -> [UInt64] {
        guard let s = doc.slides.at(index), s.name == "Photo Album" else { return [] }
        var start = index
        while start > 0, doc.slides.at(start - 1)?.name == "Photo Album" { start -= 1 }
        var end = index
        while doc.slides.at(end + 1)?.name == "Photo Album" { end += 1 }
        return doc.slides[start ... end].map { UInt64($0.id.rawValue) }
    }

    /// The album under the selection, or the one named by `album`. Id 0 is a name-only run (no marker).
    static func albumTarget(_ s: Session, _ p: JSON) throws -> (UInt32, [UInt64]) {
        let st = try s.doc()
        if let id = albumIdParam(p) {
            let ids = slidesWithAlbum(st.doc, id)
            if ids.isEmpty { throw Cmd.bad("insert.photoAlbumEdit", "that photo album is no longer in this presentation") }
            return (id, ids)
        }
        guard let slide = st.doc.slides.at(st.selection.slide) else {
            throw Cmd.bad("insert.photoAlbumEdit", "this slide is not part of a photo album")
        }
        if let mark = slide.rawExt.flatMap(parseAlbumMark) {
            let ids = slidesWithAlbum(st.doc, mark.id)
            if ids.isEmpty { throw Cmd.bad("insert.photoAlbumEdit", "this slide is not part of a photo album") }
            return (mark.id, ids)
        }
        if slide.name == "Photo Album" {
            let ids = albumNameRun(st.doc, st.selection.slide)
            if !ids.isEmpty { return (0, ids) }
        }
        throw Cmd.bad("insert.photoAlbumEdit", "this slide is not part of a photo album")
    }

    static func isPicture(_ sh: Shape) -> Bool {
        if case .picture = sh.kind { return true }
        return false
    }

    static func picCount(_ slide: Slide) -> Int { slide.shapes.filter(isPicture).count }

    static func inferAlbum(_ slides: [Slide], _ themeNow: String) -> (String, String, Bool, Bool, String) {
        let maxPics = slides.map(picCount).max() ?? 1
        let per = maxPics >= 3 ? "4" : maxPics == 2 ? "2" : "1"
        let title = slides.contains { s in
            picCount(s) > 0 && s.shapes.contains { sh in sh.textBox && (sh.xfrm.map { $0.y < 36.0 && $0.h <= 48.0 } ?? false) }
        }
        let layout = title ? "\(per)title" : per
        var width: Double?
        outer: for s in slides {
            for sh in s.shapes where isPicture(sh) {
                if let w = sh.line?.width {
                    width = w
                    break outer
                }
            }
        }
        let frame: String
        if let w = width {
            if abs(w - 6.0) < 0.2 {
                frame = "simple"
            } else if abs(w - 2.25) < 0.2 {
                frame = "rounded"
            } else if w < 0.2 {
                frame = "none"
            } else {
                frame = "rect"
            }
        } else {
            frame = "none"
        }
        let captions = slides.contains { s in
            let bottoms = s.shapes.filter(isPicture).compactMap { sh in sh.xfrm.map { $0.y + $0.h } }
            return !bottoms.isEmpty && s.shapes.contains { sh in
                sh.textBox && (sh.xfrm.map { x in bottoms.contains { x.y + 1.0 >= $0 } } ?? false)
            }
        }
        var any = false
        var gray = true
        for s in slides {
            for sh in s.shapes {
                if case .picture(let fill) = sh.kind {
                    any = true
                    gray = gray && fill.adjust.grayscale
                }
            }
        }
        return (layout, frame, captions, any && gray, themeNow)
    }

    static func itemsFromSlides(_ doc: Presentation, _ slides: [Slide]) -> [JSON] {
        var items: [JSON] = []
        for slide in slides {
            let pics = slide.shapes.filter(isPicture)
            if pics.isEmpty {
                let text = slide.shapes.filter(\.textBox).compactMap { $0.text?.text }.first { !rustTrim($0).isEmpty } ?? ""
                if !rustTrim(text).isEmpty { items.append(["text": .string(String(rustTrim(text)))]) }
                continue
            }
            for sh in pics {
                guard case .picture(let fill) = sh.kind else { continue }
                let media = doc.media(fill.media)
                let name: String
                if !sh.descr.isEmpty {
                    name = sh.descr
                } else if let n = media?.name, !n.isEmpty {
                    name = n
                } else {
                    name = "picture"
                }
                items.append([
                    "name": .string(name),
                    "data": .string(media.map { Cmd.base64Encode($0.data) } ?? ""),
                    "rot": .num(sh.xfrm?.rot ?? 0.0),
                    "brightness": .num(fill.adjust.brightness),
                    "contrast": .num(fill.adjust.contrast),
                ])
            }
        }
        return items
    }

    static func albumSeed(_ s: Session) throws -> JSON {
        let (id, ids) = try albumTarget(s, .null)
        let st = try s.doc()
        let slides: [Slide] = ids.compactMap { UInt32(exactly: $0) }.compactMap { st.doc.slide(SlideId($0)) }
        let themeNow = st.doc.masters.first.map(\.theme.name).flatMap { $0.isEmpty ? nil : $0 } ?? "DeckCraft"
        let inferred = inferAlbum(slides, themeNow)
        let mark = slides.first?.rawExt.flatMap(parseAlbumMark)
        let (layout, frame, captions, grayscale, theme): (String, String, Bool, Bool, String)
        if let m = mark {
            (layout, frame, captions, grayscale, theme) = (
                m.layout.isEmpty ? inferred.0 : m.layout,
                m.frame.isEmpty ? inferred.1 : m.frame,
                m.captions,
                m.grayscale,
                m.theme.isEmpty ? themeNow : m.theme
            )
        } else {
            (layout, frame, captions, grayscale, theme) = inferred
        }
        return [
            "album": id == 0 ? .null : .uint(UInt64(id)),
            "layout": .string(layout),
            "frame": .string(frame),
            "captions": .bool(captions),
            "grayscale": .bool(grayscale),
            "theme": .string(theme),
            "items": .array(itemsFromSlides(st.doc, slides)),
        ]
    }

    static func rectJSON(_ r: [Double]) -> JSON { .array(r.map { .num($0) }) }

    static func insertAlbum(_ s: Session, _ items: [AlbumItem], _ opts: AlbumOpts, _ at: Int?, _ albumId: UInt32) throws -> JSON {
        let st = try s.doc()
        let first = at ?? (st.doc.slides.isEmpty ? 0 : st.selection.slide.addingReportingOverflow(1).partialValue)
        let width = st.doc.slideSize.width
        let height = st.doc.slideSize.height
        let layout = opts.layout
        let captions = opts.captions
        let plan = albumPlan(items, layout.per)
        var slides = 0
        var pictures = 0
        var pin = at
        for slide in plan {
            if let index = pin {
                pin = nil
                _ = try s.execute("slide.new", ["layout": "blank", "at": .integer(index)])
            } else {
                _ = try s.execute("slide.new", ["layout": "blank"])
            }
            try stampAlbumSlide(s, albumId, opts)
            slides += 1
            switch slide {
            case .text(let text):
                let rect: [Double] = layout.title
                    ? [36.0, 18.0, (width - 72.0).rustMax(36.0), 48.0]
                    : [36.0, 36.0, (width - 72.0).rustMax(36.0), (height - 72.0).rustMax(36.0)]
                _ = try s.execute("insert.textBox", ["rect": rectJSON(rect), "text": .string(text)])
            case .pictures(let pics):
                let stem = pics.first.map { fileStem($0.name) } ?? ""
                let (title, placed) = placePictures(width, height, layout, pics, captions)
                for (pic, cell) in zip(pics, placed) {
                    let data = Cmd.base64Encode(pic.bytes)
                    let inserted = try s.execute("insert.picture", ["name": .string(pic.name), "data": .string(data), "rect": rectJSON(cell.pic)])
                    guard let id = inserted.get("id")?.asU64 else { throw Cmd.bad("insert.photoAlbum", "the picture was not inserted") }
                    try applyFrame(s, opts.frame, id)
                    if opts.grayscale || abs(pic.brightness) > 1e-6 || abs(pic.contrast) > 1e-6 {
                        _ = try s.execute("picture.adjust", [
                            "id": .uint(id), "grayscale": .bool(opts.grayscale), "brightness": .num(pic.brightness), "contrast": .num(pic.contrast),
                        ])
                    }
                    if pic.rot > 0.01 {
                        _ = try s.execute("shape.rotate", ["id": .uint(id), "deg": .num(pic.rot)])
                    }
                    pictures += 1
                    if let cap = cell.caption {
                        _ = try s.execute("insert.textBox", ["rect": rectJSON(cap), "text": .string(fileStem(pic.name))])
                    }
                }
                if let rect = title {
                    _ = try s.execute("insert.textBox", ["rect": rectJSON(rect), "text": .string(stem)])
                }
            }
        }
        _ = try s.execute("slide.go", ["index": .integer(first)])
        return ["slides": .integer(slides), "first": .integer(first), "pictures": .integer(pictures), "album": .uint(UInt64(albumId))]
    }

    // MARK: - Tables and charts

    @Sendable static func table(_ s: Session, _ p: JSON) throws -> JSON {
        let rows = min(max(Cmd.usizeParam(p, "rows") ?? 2, 1), 75)
        let cols = min(max(Cmd.usizeParam(p, "cols") ?? 2, 1), 75)
        let size = try s.doc().doc.slideSize
        let w = size.width * 0.8
        let rh = 40.0
        let rect = Cmd.rectParam(p, "rect") ?? Xfrm(size.width * 0.1, (size.height - rh * Double(rows)).rustMax(0.0) / 2.0, w, rh * Double(rows))
        var t = Table(rows: rows, cols: cols, width: rect.w, rowHeight: rect.h / Double(rows))
        if let data = p.get("data")?.asArray {
            for (r, row) in data.enumerated() {
                for (c, v) in (row.asArray ?? []).enumerated() {
                    guard let text = v.asStr, r < t.rows.count, c < t.rows[r].cells.count else { continue }
                    t.rows[r].cells[c].text = TextBody.fromText(text)
                }
            }
        }
        var shape = Shape.default
        shape.xfrm = rect
        shape.kind = .table(t)
        let id = try addShape(s, "insert.table", shape, true)
        return ["id": id.toJSON()]
    }

    /// A chart type from its name (`chart_type`); anything unknown is a column chart.
    public static func chartType(_ name: String) -> ChartType {
        let key = String(String.UnicodeScalarView(rustASCIILowercase(name).unicodeScalars.filter { $0 != "-" && $0 != "_" && $0 != " " }))
        switch key {
        case "bar", "clusteredbar": return .bar
        case "stackedbar": return .stackedBar
        case "percentbar": return .percentBar
        case "line": return .line
        case "linemarkers", "linewithmarkers": return .lineMarkers
        case "stackedline": return .stackedLine
        case "area": return .area
        case "stackedarea": return .stackedArea
        case "pie": return .pie
        case "doughnut", "donut": return .doughnut
        case "scatter", "xy": return .scatter
        case "bubble": return .bubble
        case "radar": return .radar
        case "filledradar": return .filledRadar
        case "stackedcolumn": return .stackedColumn
        case "percentcolumn": return .percentColumn
        case "waterfall": return .waterfall
        case "funnel": return .funnel
        case "histogram": return .histogram
        case "pareto": return .pareto
        case "treemap": return .treemap
        case "sunburst": return .sunburst
        case "boxwhisker", "box": return .boxWhisker
        case "stock": return .stock
        case "surface": return .surface
        case "combo": return .combo
        default: return .column
        }
    }

    /// A category label: the string, or any other value as JSON text.
    static func labelOf(_ v: JSON) -> String { v.asStr ?? v.display }

    static func seriesOf(_ sv: JSON) -> Series {
        var x = Series.default
        x.name = sv.get("name")?.asStr ?? "Series"
        x.values = sv.get("values")?.asArray?.map(\.asF64) ?? []
        return x
    }

    @Sendable static func chart(_ s: Session, _ p: JSON) throws -> JSON {
        let kind = chartType(Cmd.strParam(p, "type") ?? "column")
        var c = Chart.sample(kind)
        if let cats = p.get("categories")?.asArray { c.categories = cats.map(labelOf) }
        if let series = p.get("series")?.asArray { c.series = series.map(seriesOf) }
        if let t = p.get("title") { c.title = t.asStr }
        let size = try s.doc().doc.slideSize
        let rect = Cmd.rectParam(p, "rect") ?? Xfrm(size.width * 0.15, size.height * 0.15, size.width * 0.7, size.height * 0.7)
        var shape = Shape.default
        shape.xfrm = rect
        shape.kind = .chart(c)
        let id = try addShape(s, "insert.chart", shape, true)
        return ["id": id.toJSON()]
    }

    // MARK: - Audio and video

    static func media(_ s: Session, _ p: JSON, _ video: Bool) throws -> JSON {
        let cmd = video ? "insert.video" : "insert.audio"
        let (name, bytes) = try mediaBytes(p, cmd)
        let ct = contentType(name, bytes)
        let info: Result<MediaInfo, MediaError> = Result { () throws(MediaError) -> MediaInfo in try Media.probe(bytes) }
        let probed = try? info.get()
        let hasVideo = probed?.video != nil
        let hasAudio = probed?.audio != nil
        switch info {
        case .success:
            if video && !hasVideo { throw Cmd.bad(cmd, "\(name) has no video") }
            if !video && !hasAudio && !hasVideo { throw Cmd.bad(cmd, "\(name) has no audio") }
        case .failure:
            // Not something we can read: embed it anyway when the type says it's media (it still
            // round-trips through PPTX), otherwise refuse.
            if video && !ct.hasPrefix("video/") { throw Cmd.bad(cmd, "\(name) is not a supported video (\(ct))") }
            if !video && !ct.hasPrefix("audio/") { throw Cmd.bad(cmd, "\(name) is not a supported audio file (\(ct))") }
        }
        var durationMs: UInt32 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var playable = false
        if let i = probed {
            if let v = i.video {
                width = v.width
                height = v.height
            }
            durationMs = UInt32(min(i.durationMs, UInt64(UInt32.max)))
            playable = i.playable
        }
        let decodableVideo = probed?.video?.decodable ?? false
        var warning: String?
        if !playable {
            switch info {
            case .success(let i):
                let codecs = (i.audio.map { [$0.codec] } ?? []) + (i.video.map { [$0.codec] } ?? [])
                warning = "\(name) was inserted, but it can't be played (\(codecs.joined(separator: " / ")) isn't supported yet)"
            case .failure(let e):
                warning = "\(name) was inserted, but it can't be played (\(e))"
            }
        } else if video && !decodableVideo {
            // A video codec without a decoder (VP8, say): the clip's audio still plays, but no frame can ever
            // show — say so instead of leaving an unexplained black box (#1237).
            warning = probed?.video.map { "\(name) was inserted, but its video can't be played (\($0.codec) isn't supported yet); only the audio plays" }
        }
        let posterPng = video && decodableVideo ? MediaCommands.posterPNG(bytes, 0) : nil
        let size = try s.doc().doc.slideSize
        let rect: Xfrm
        if let r = Cmd.rectParam(p, "rect") {
            rect = r
        } else if video {
            // Natural size (96 dpi), fitted inside 90 % of the slide and centred.
            let (w0, h0) = width > 0 && height > 0
                ? (Double(width) * 0.75, Double(height) * 0.75)
                : (size.width * 0.6, size.width * 0.6 * 9.0 / 16.0)
            let k = (size.width * 0.9 / w0).rustMin(size.height * 0.9 / h0).rustMin(1.0)
            let (w, h) = (w0 * k, h0 * k)
            rect = Xfrm((size.width - w) / 2.0, (size.height - h) / 2.0, w, h)
        } else {
            rect = Xfrm((size.width - 48.0) / 2.0, (size.height - 48.0) / 2.0, 48.0, 48.0)
        }
        let (mediaId, poster) = try s.edit { doc, _ -> (MediaId, MediaId?) in
            guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("insert.media", Cmd.noIdSpace) }
            var poster: MediaId?
            if let png = posterPng {
                guard let pm = doc.addMedia("\(name)-poster.png", "image/png", png) else { throw Cmd.bad("insert.media", Cmd.noIdSpace) }
                poster = pm
            }
            return (m, poster)
        }
        let clip = MediaClip(media: mediaId, video: video, poster: poster, volume: 1.0, durationMs: durationMs, width: width, height: height)
        var shape = Shape.default
        shape.xfrm = rect
        shape.kind = .media(clip)
        shape.descr = name
        let id = try addShape(s, "insert.media", shape, true)
        if let w = warning { s.uiRequests.append(.message(text: w)) }
        var r: JSON = [
            "id": id.toJSON(), "contentType": .string(ct), "durationMs": .uint(UInt64(durationMs)), "width": .uint(UInt64(width)),
            "height": .uint(UInt64(height)), "playable": .bool(playable), "warning": .opt(warning),
        ]
        if let i = probed { r.set("probe", MediaCommands.probeJSON(i)) }
        return r
    }

    @Sendable static func audio(_ s: Session, _ p: JSON) throws -> JSON { try media(s, p, false) }
    @Sendable static func video(_ s: Session, _ p: JSON) throws -> JSON { try media(s, p, true) }

    // MARK: - WordArt and fields

    @Sendable static func wordArt(_ s: Session, _ p: JSON) throws -> JSON {
        let text = Cmd.strParam(p, "text") ?? "Your text here"
        let size = try s.doc().doc.slideSize
        let style = Cmd.usizeParam(p, "style") ?? 0
        var shape = newTextBox(Xfrm(size.width * 0.2, size.height * 0.4, size.width * 0.6, 80.0), text)
        if var t = shape.text {
            let slot: SchemeSlot = switch style % 4 {
            case 0: .tx1
            case 1: .accent1
            case 2: .accent2
            default: .accent4
            }
            for pi in t.paragraphs.indices {
                t.paragraphs[pi].props.align = .center
                for ri in t.paragraphs[pi].runs.indices {
                    t.paragraphs[pi].runs[ri].props.size = 54.0
                    t.paragraphs[pi].runs[ri].props.bold = style % 2 == 1
                    t.paragraphs[pi].runs[ri].props.fill = .solid(.scheme(slot))
                    if style % 3 == 2 {
                        t.paragraphs[pi].runs[ri].props.outline = Line.solid(.scheme(.bg1), 1.0)
                    }
                }
            }
            shape.text = t
        }
        let id = try addShape(s, "insert.wordArt", shape, true)
        try TextCommands.fitTextBox(s, id)
        return ["id": id.toJSON()]
    }

    static func fieldRun(_ s: Session, _ field: String, _ text: String) throws -> JSON {
        if try s.doc().selection.text != nil {
            return try TextCommands.insertField(s, field, text)
        }
        // Not editing: turn on the footer field for the slide (Header & Footer).
        let key = field == "slidenum" ? "slideNumber" : "date"
        return try s.execute("design.headerFooter", .object(JSONObject([key: .bool(true)])))
    }

    @Sendable static func slideNumber(_ s: Session, _ p: JSON) throws -> JSON {
        try fieldRun(s, "slidenum", "‹#›")
    }

    static let dateFormats = (1 ... 13).map { "datetime\($0)" }

    struct DateOpts {
        var format: String
        var update: Bool
        /// BCP 47 tag when the caller set `language`; absent keeps the surrounding run's language.
        var lang: String?
        var sample: String
    }

    /// True when the call carries a format, update flag or language (apply it). Empty params open the
    /// dialog instead.
    static func dateTimeApply(_ p: JSON) -> Bool {
        guard let o = p.asObject else { return false }
        return o["format"] != nil || o["update"] != nil || o["language"] != nil
    }

    static func canonLang(_ raw: String) -> String? {
        let k = rustASCIILowercase(String(rustTrim(raw))).replacingOccurrences(of: "_", with: "-")
        switch k {
        case "en", "en-us": return "en-US"
        case "en-gb": return "en-GB"
        case "fr", "fr-fr": return "fr-FR"
        case "ja", "ja-jp": return "ja-JP"
        case "sv", "sv-se": return "sv-SE"
        default: return nil
        }
    }

    static func dateOpts(_ p: JSON) throws -> DateOpts {
        if p.get("format") != nil {
            if !(Cmd.strParam(p, "format").map { dateFormats.contains($0) } ?? false) {
                throw Cmd.bad("insert.dateTime", "`format` must be datetime1..datetime13")
            }
        }
        if p.get("update") != nil && Cmd.boolParam(p, "update") == nil {
            throw Cmd.bad("insert.dateTime", "`update` must be true or false")
        }
        var lang: String?
        if p.get("language") != nil {
            let msg = "`language` must be en-US, en-GB, fr-FR, ja-JP or sv-SE"
            guard let raw = Cmd.strParam(p, "language"), !rustTrim(raw).isEmpty else { throw Cmd.bad("insert.dateTime", msg) }
            guard let l = canonLang(raw) else { throw Cmd.bad("insert.dateTime", msg) }
            lang = l
        }
        let format = Cmd.strParam(p, "format") ?? "datetime1"
        let sample = try dateSample(format, lang)
        return DateOpts(format: format, update: Cmd.boolOr(p, "update", true), lang: lang, sample: sample)
    }

    /// The text `format` shows now in `lang`. Errors when that language has no names for the format
    /// (month names and AM/PM are English only).
    static func dateSample(_ format: String, _ lang: String?) throws -> String {
        let probe = DCText.DateTime(2026, 10, 9, 20, 5, 7)
        if DateFields.fieldText(format, lang, probe) == nil {
            throw Cmd.bad("insert.dateTime", "this format isn't available in that language")
        }
        return DCText.DateTime.nowLocal().flatMap { DateFields.fieldText(format, lang, $0) } ?? ""
    }

    @Sendable static func dateTime(_ s: Session, _ p: JSON) throws -> JSON {
        if !dateTimeApply(p) {
            s.uiRequests.append(.dialog(id: "dateTime", params: .emptyObject))
            return Cmd.ok()
        }
        let opts = try dateOpts(p)
        let st = try s.doc()
        let doc = st.docRef
        let sel = st.selection
        do {
            return try applyDate(s, opts)
        } catch {
            if let st = s.activeDoc {
                st.docRef = doc
                st.selection = sel
            }
            throw error
        }
    }

    static func dateAnswer(_ whereTo: String, _ o: DateOpts) -> JSON {
        ["where": .string(whereTo), "format": .string(o.format), "update": .bool(o.update), "text": .string(o.sample)]
    }

    static func applyDate(_ s: Session, _ o: DateOpts) throws -> JSON {
        if try s.doc().selection.text != nil {
            if o.update {
                _ = try TextCommands.insertField(s, o.format, o.sample)
                if let lang = o.lang { try stampCaretLang(s, lang) }
            } else {
                try insertPlain(s, o.sample, o.lang)
            }
            return dateAnswer("caret", o)
        }
        // Not editing: the slide's date placeholder (this slide only). A layout with no date placeholder
        // gets a text box instead, so the chosen format is still inserted.
        _ = try s.execute("design.headerFooter", ["date": true, "all": false])
        if !(try writeDatePlaceholder(s, o)) { return try insertDateBox(s, o) }
        return dateAnswer("footer", o)
    }

    /// Point the current slide's date placeholder at this format (a field, or the sample as plain text).
    static func writeDatePlaceholder(_ s: Session, _ o: DateOpts) throws -> Bool {
        try s.edit { doc, sel in
            guard sel.slide >= 0, sel.slide < doc.slides.count else { return false }
            guard let i = doc.slides[sel.slide].shapes.firstIndex(where: { $0.phType == .date }) else { return false }
            let sh = doc.slides[sel.slide].shapes[i]
            var props = sh.text?.paragraphs.first?.runs.first?.props ?? RunProps.default
            if let lang = o.lang { props.lang = lang }
            let kind: RunKind = o.update ? .field(field: o.format) : .text
            let para = Paragraph(runs: [Run(text: o.sample, props: props, kind: kind)])
            var body = sh.text ?? TextBody.default
            body.paragraphs = [para]
            doc.slides[sel.slide].shapes[i].text = body
            return true
        }
    }

    static func insertDateBox(_ s: Session, _ o: DateOpts) throws -> JSON {
        let size = try s.doc().doc.slideSize
        let y = (size.height - 48.0).rustMax(0.0)
        _ = try s.execute("insert.textBox", ["rect": rectJSON([36.0, y, 360.0, 28.0]), "text": ""])
        if o.update {
            _ = try TextCommands.insertField(s, o.format, o.sample)
        } else {
            _ = try TextCommands.insertText(s, o.sample, nil)
        }
        if let lang = o.lang { try stampCaretLang(s, lang) }
        return dateAnswer("textBox", o)
    }

    /// Insert `text` at the caret. `lang`, when set, is on that run before runs with equal props merge, so
    /// the date stays its own run next to the surrounding text.
    static func insertPlain(_ s: Session, _ text: String, _ lang: String?) throws {
        try TextCommands.editText(s) { body, t in
            let (a, b) = t.ordered
            let at = TextEdit.delete(&body, a.tuple, b.tuple)
            var props = TextEdit.propsAt(body, at)
            if let lang { props.lang = lang }
            let c = TextEdit.insert(&body, at, text, props)
            t.anchor = TextPoint(c.0, c.1)
            t.caret = TextPoint(c.0, c.1)
        }
    }

    /// Tag the run that ends at the caret with `lang`, so a date field keeps that language when it updates.
    static func stampCaretLang(_ s: Session, _ lang: String) throws {
        try TextCommands.editText(s) { body, t in
            let pi = t.caret.para
            guard pi >= 0, pi < body.paragraphs.count else { return }
            var at = 0
            for ri in body.paragraphs[pi].runs.indices {
                let n = body.paragraphs[pi].runs[ri].charLen
                if n > 0 && at < t.caret.char && t.caret.char <= at + n {
                    body.paragraphs[pi].runs[ri].props.lang = lang
                    return
                }
                at += n
            }
        }
    }

    @Sendable static func symbol(_ s: Session, _ p: JSON) throws -> JSON {
        guard let t = Cmd.strParam(p, "text") else { throw Cmd.bad("insert.symbol", "missing `text`") }
        if try s.doc().selection.text == nil { throw Cmd.bad("insert.symbol", "place the insertion point in text first") }
        return try TextCommands.insertText(s, t, nil)
    }

    // MARK: - Links and actions

    @Sendable static func hyperlink(_ s: Session, _ p: JSON) throws -> JSON {
        // `display`: what a caret with nothing to link inserts, the address or the slide's title.
        let action: Action
        var display: String
        if let u = Cmd.strParam(p, "url") {
            action = .url(url: u)
            display = u.hasPrefix("mailto:") ? String(u.dropFirst("mailto:".count)) : u
        } else if let i = Cmd.usizeParam(p, "slide") {
            guard let slide = try s.doc().doc.slides.at(i) else { throw Cmd.bad("insert.hyperlink", "no such slide") }
            let title = slide.title
            action = .slide(slide: slide.id)
            display = title.isEmpty ? "Slide \(i + 1)" : title
        } else {
            throw Cmd.bad("insert.hyperlink", "missing `url` or `slide`")
        }
        if let t = Cmd.strParam(p, "text") { display = t }
        let link = Hyperlink(
            action: action, tooltip: Cmd.strParam(p, "tooltip") ?? "", highlightClick: Cmd.boolOr(p, "highlightClick", false),
            sound: nil, stopSound: false, zoomReturn: nil
        )
        if try s.doc().selection.text != nil {
            return try TextCommands.linkText(s, link, display)
        }
        return try Cmd.editShapes(s, p, "insert.hyperlink") { sh in sh.click = link }
    }

    /// Insert ▸ Action (Action Settings): what clicking the selected shapes, or pointing at them, does in a
    /// show.
    @Sendable static func shapeAction(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "shape.action"
        let hover: Bool
        switch Cmd.strParam(p, "on") ?? "click" {
        case "click": hover = false
        case "hover", "over": hover = true
        case let o: throw Cmd.bad(cmd, "`on` is click or hover, not `\(o)`")
        }
        func need(_ k: String) throws -> String {
            guard let v = Cmd.strParam(p, k), !rustTrim(v).isEmpty else { throw Cmd.bad(cmd, "missing `\(k)`") }
            return v
        }
        let action: Action?
        switch Cmd.strParam(p, "action") ?? "none" {
        case "none": action = nil
        case "next": action = .nextSlide
        case "previous": action = .previousSlide
        case "first": action = .firstSlide
        case "last": action = .lastSlide
        case "lastViewed": action = .lastViewed
        case "endShow": action = .endShow
        case "playMedia": action = .playMedia
        case "url": action = .url(url: try need("url"))
        case "customShow":
            let name = try need("show")
            if !(try s.doc().doc.customShows.contains { $0.name == name }) { throw Cmd.bad(cmd, "no custom show `\(name)`") }
            action = .customShow(name: name, returns: true)
        case "program": action = .program(path: try need("path"))
        case "slide":
            guard let i = Cmd.usizeParam(p, "slide") else { throw Cmd.bad(cmd, "missing `slide`") }
            guard let slide = try s.doc().doc.slides.at(i) else { throw Cmd.bad(cmd, "no such slide") }
            action = .slide(slide: slide.id)
        case let a: throw Cmd.bad(cmd, "unknown action `\(a)`")
        }
        let highlight = Cmd.boolParam(p, "highlight") ?? true
        let tooltip = Cmd.strParam(p, "tooltip") ?? ""
        let link = action.map { Hyperlink(action: $0, tooltip: tooltip, highlightClick: highlight, sound: nil, stopSound: false, zoomReturn: nil) }
        return try Cmd.editShapes(s, p, cmd) { sh in
            if hover { sh.hover = link } else { sh.click = link }
        }
    }

    @Sendable static func actionButton(_ s: Session, _ p: JSON) throws -> JSON {
        let kind = Cmd.strParam(p, "kind") ?? "custom"
        let (preset, action): (String, Action?) = switch kind {
        case "back", "previous": ("actionButtonBackPrevious", .previousSlide)
        case "forward", "next": ("actionButtonForwardNext", .nextSlide)
        case "beginning": ("actionButtonBeginning", .firstSlide)
        case "end": ("actionButtonEnd", .lastSlide)
        case "home": ("actionButtonHome", .firstSlide)
        case "information": ("actionButtonInformation", nil)
        case "return": ("actionButtonReturn", .lastViewed)
        case "movie": ("actionButtonMovie", nil)
        case "document": ("actionButtonDocument", nil)
        case "sound": ("actionButtonSound", nil)
        case "help": ("actionButtonHelp", nil)
        default: ("actionButtonBlank", nil)
        }
        let rect = Cmd.rectParam(p, "rect") ?? defaultRect(s, 48.0, 48.0)
        var shape = Shape.default
        shape.xfrm = rect
        shape.geom = .preset(preset)
        shape.style = ShapeStyle.accent(.accent1)
        shape.click = action.map { Hyperlink(action: $0, tooltip: "", highlightClick: true, sound: nil, stopSound: false, zoomReturn: nil) }
        let id = try addShape(s, "insert.actionButton", shape, true)
        return ["id": id.toJSON()]
    }

    // MARK: - Chart editing

    static func withChart(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Chart) throws -> Void) throws -> JSON {
        try Cmd.editShapes(s, p, cmd) { sh in
            guard case .chart(var c) = sh.kind else { throw Cmd.bad(cmd, "not a chart") }
            try f(&c)
            sh.kind = .chart(c)
        }
    }

    @Sendable static func chartTypeCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let k = chartType(Cmd.strParam(p, "type") ?? "column")
        return try withChart(s, p, "chart.type") { c in
            c.kind = k
            c.varyColors = [.pie, .doughnut, .funnel, .treemap, .sunburst, .waterfall].contains(k) || (c.series.count == 1 && c.varyColors)
            if [.waterfall, .histogram, .pareto, .boxWhisker].contains(k) { c.gridlines = true }
            c.raw = nil
        }
    }

    @Sendable static func chartData(_ s: Session, _ p: JSON) throws -> JSON {
        let cats: [String]? = p.get("categories")?.asArray?.map(labelOf)
        let series: [Series]? = p.get("series")?.asArray?.map(seriesOf)
        let levels: [[String]]? = p.get("levels")?.asArray.map { a in
            a.prefix(maxChartLevels).map { l in l.asArray?.map(labelOf) ?? [] }
        }
        return try withChart(s, p, "chart.data") { c in
            if let cs = cats { c.categories = cs }
            if let l = levels { c.categoryLevels = l }
            if let se = series {
                // Keep series formatting by position.
                let old = c.series
                c.series = se.enumerated().map { i, n in
                    var x = old.at(i) ?? Series.default
                    x.name = n.name
                    x.values = n.values
                    return x
                }
            }
            c.raw = nil
        }
    }

    static func applyBinOptions(_ c: inout Chart, _ binCount: UInt32??, _ binSize: Double??) {
        if let n = binCount {
            c.binCount = n
            if n != nil { c.binSize = nil }
        }
        if let w = binSize {
            c.binSize = w
            if w != nil { c.binCount = nil }
        }
    }

    static func applySubtotalsAndBars(_ c: inout Chart, _ p: JSON, _ subtotals: [Int]?) {
        if let t = subtotals {
            let n = c.series.first?.values.count ?? 0
            c.subtotals = Array(Set(t.filter { $0 < n })).sorted()
        }
        if let b = p.get("upDownBars")?.asBool {
            c.upDownBars = b
            c.raw = nil
        }
        if let q = p.get("quartiles")?.asStr {
            c.inclusiveQuartiles = eqIgnoreASCIICase(q, "inclusive")
            c.raw = nil
        }
    }

    @Sendable static func chartOptions(_ s: Session, _ p: JSON) throws -> JSON {
        // Histogram bins: a count or a width (setting one clears the other; null for automatic).
        let binCount: UInt32?? = p.get("binCount").map { v in v.asU64.map { UInt32(min(max($0, 1), UInt64(maxBins))) } }
        let binSize: Double?? = p.get("binSize").map { v in v.asF64.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil } }
        if let v = p.get("binSize"), !v.isNull, (binSize ?? nil) == nil {
            throw Cmd.bad("chart.options", "binSize must be a positive number")
        }
        // Waterfall total points.
        let subtotals: [Int]? = p.get("subtotals")?.asArray?.compactMap(\.asU64).map { Int(exactly: $0) ?? Int.max }
        // Colour of the chart's text (title, axes, legend, data labels); null goes back to PowerPoint's
        // default (tx1 at lumMod 65 % / lumOff 35 %).
        var textColor: ColorRef??
        if let v = p.get("textColor") {
            if v.isNull {
                textColor = .some(nil)
            } else {
                guard let c = Cmd.colorValue(v) else {
                    throw Cmd.bad("chart.options", "`textColor` is a colour: #RRGGBB, accent1…accent6, tx1…, or null")
                }
                textColor = .some(c)
            }
        }
        return try withChart(s, p, "chart.options") { c in
            if let t = textColor { c.textColor = t }
            applyBinOptions(&c, binCount, binSize)
            applySubtotalsAndBars(&c, p, subtotals)
            if binCount != nil || binSize != nil || subtotals != nil { c.raw = nil }
            if let t = p.get("title") { c.title = t.asStr }
            if let l = p.get("legend") { c.legend = l.asStr }
            if let v = Cmd.boolParam(p, "dataLabels") {
                c.dataLabels = v
                // A series' own setting would otherwise keep overriding the chart-wide switch.
                for i in c.series.indices { c.series[i].dataLabels = nil }
            }
            if let v = Cmd.boolParam(p, "gridlines") { c.gridlines = v }
            if let v = Cmd.strParam(p, "palette") { c.palette = v }
            c.raw = nil
        }
    }

    // MARK: - SmartArt

    /// A SmartArt graphic: a group regenerated from its outline (see `SmartArtCommands`). Items with
    /// leading tabs are sub-points; `nodes` (`[{text, level}]`) may be given instead.
    @Sendable static func smartArt(_ s: Session, _ p: JSON) throws -> JSON {
        let kind = Cmd.strParam(p, "kind") ?? "process"
        let nodes: [DiagramNode]
        if let v = p.get("nodes") {
            do {
                nodes = try [DiagramNode](fromJSON: v)
            } catch {
                throw Cmd.bad("insert.smartArt", String(describing: error))
            }
        } else {
            nodes = SmartArtCommands.nodesFromLines((p.get("items")?.asArray ?? []).compactMap(\.asStr))
        }
        return try SmartArtCommands.insert(s, kind, nodes)
    }
}

// MARK: - Called by the core (cmd/edit.rs). Keep these signatures.

extension InsertCommands {
    /// "{base} n" with the first `n` from the shape count + 1 that no shape on the slide already uses, so
    /// a gap left by a deleted shape never makes a second shape with the same name (`first_free_name`).
    /// Ported by the core.
    static func firstFreeName(_ base: String, _ taken: Set<String>) -> String {
        var n = taken.count + 1
        while true {
            let c = "\(base) \(n)"
            if !taken.contains(c) { return c }
            n += 1
        }
    }
}
