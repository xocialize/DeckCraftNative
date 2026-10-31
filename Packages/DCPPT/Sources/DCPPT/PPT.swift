// DCPPT — a `.ppt` as a DCModel presentation. P1 (Docs/plans/Legacy-PPT-and-Encryption.md) reads the document: the
// slide and notes size from the DocumentAtom ([MS-PPT] 2.4.2, in master units of 1/576 inch) and the slides from
// the slide list (the SlideListWithTextContainer of instance 0, 2.4.14.3: one SlidePersistAtom per slide, in order).
// Each slide is a slide of the default master's blank layout holding the file's text-bearing shapes and placeholders
// (P2a: their text, paragraphs and character formatting), with its notes page's text as its notes. P2b adds the first
// main master's text styles, colour scheme and background to the default master, each slide's own scheme and
// background, headers and footers, and hyperlinks. P3 brings every shape (Shapes.swift): geometry, fill, line, shadow,
// groups, connectors, tables and WordArt. P4 brings the pictures (Pictures.swift: shapes, picture and pattern fills,
// backgrounds), OLE objects as their pictures, movies and sounds (Objects.swift), and comments. P5 brings the slide
// show (SlideShow.swift): transitions, hidden slides and animations. The import report lists what isn't brought over,
// and each object that became a picture.
import DCCFB
import DCColor
import DCGeometry
import DCModel

/// What a `.ppt` import read and what it left behind.
public struct PPTReport: Sendable, Equatable {
    /// Slides in the file's slide list.
    public var slides: Int
    /// 1-based numbers of the slides whose record couldn't be read (they're blank).
    public var unreadSlides: [Int]
    /// Saves in the file's edit chain (more than one: PowerPoint saved it incrementally).
    public var edits: Int
    public var encrypted: Bool
    /// What this version doesn't bring over yet.
    public var notImported: [String]
    /// The objects that came over as their picture, one per object: "slide 3: MSGraph.Chart.8".
    public var asPictures: [String] = []
    /// Pictures that couldn't be read (damaged, or a PICT that couldn't be drawn).
    public var lostPictures = 0
    /// PICT pictures converted to JPEG or PNG.
    public var convertedPictures = 0
}

public enum PPT {
    /// Whether `bytes` is a `.ppt`.
    public static func sniff(_ bytes: [UInt8]) -> Bool { PPTFile.isPPT(bytes) }

    /// Points per master unit: 72 / 576.
    static let pointsPerMasterUnit = 1.0 / 8.0
    /// The DocumentAtom's sizes are clamped to what PowerPoint allows (1 to 56 inches).
    static let sizeRange = 72.0 ... 4032.0

    /// The presentation in a `.ppt`, and what the import couldn't bring over.
    public static func importChecked(_ bytes: [UInt8], password: String? = nil, hooks: PPTHooks = PPTHooks()) throws(PPTError)
        -> (Presentation, PPTReport)
    {
        let file = try PPTFile(bytes, password: password)
        guard let doc = file.object(file.documentRef), let root = Record(doc, at: 0), root.type == RT.document, root.isContainer else {
            throw .damaged("the DocumentContainer can't be read")
        }
        let children = root.children(doc)

        var size = Size(720, 540), notes = Size(540, 720)
        if let atom = children.first(where: { $0.type == RT.documentAtom }), atom.body.count >= 16 {
            func points(_ v: Int32, _ fallback: Double) -> Double {
                let p = Double(v) * pointsPerMasterUnit
                return p.isFinite && sizeRange.contains(p) ? p : fallback
            }
            let b = atom.body.lowerBound
            size = Size(points(i32(doc, b), 720), points(i32(doc, b + 4), 540))
            notes = Size(points(i32(doc, b + 8), 540), points(i32(doc, b + 12), 720))
        }

        let fonts = fontCollection(doc, children)

        // The slide list: SlidePersistAtoms in the SlideListWithTextContainer of instance 0, each followed by its
        // slide's outline text (what its placeholders' OutlineTextRefAtoms point at).
        var slideRefs: [(ref: UInt32, slideId: UInt32, outline: [PPTText])] = []
        if let list = children.first(where: { $0.type == RT.slideListWithText && $0.instance == 0 }) {
            var pending: [Record] = []
            for r in list.children(doc) {
                if r.type == RT.slidePersistAtom, r.body.count >= 16 {
                    if !slideRefs.isEmpty { slideRefs[slideRefs.count - 1].outline = PPTText.bodies(doc, pending) }
                    pending = []
                    slideRefs.append((le32(doc, r.body.lowerBound), le32(doc, r.body.lowerBound + 12), []))
                } else {
                    pending.append(r)
                }
            }
            if !slideRefs.isEmpty { slideRefs[slideRefs.count - 1].outline = PPTText.bodies(doc, pending) }
        }

        // The masters: the first main master's text styles (over the document's defaults), colour scheme and
        // background become the DCModel master's.
        let masters = Masters.read(file, doc, children)
        let environment = children.first { $0.type == RT.environment }
        let styles = MasterStyles.read(masters.main?.bytes ?? [], environment: environment, doc, master: masters.main?.record)
        let masterScheme = masters.main.flatMap { Masters.scheme($0.bytes, $0.record) } ?? Self.defaultScheme
        let base = TextContext(fonts: fonts, scheme: masterScheme, styles: styles)
        let hyperlinks = Document.hyperlinks(doc, children)
        let shapeDefaults = Drawing.defaults(doc, children)
        let masterShapes = masters.shapeProps()
        var pictures = PictureMedia(pictures: Pictures.read(file, doc, children), hooks: hooks)
        var objects = ExObjects.read(doc, children)
        var asPictures: [String] = []

        var p = blankPresentation(size, .default, false)
        p.notesSize = notes
        /// A drawing's background, its pictures added first.
        func background(_ b: [UInt8], _ r: Record, _ scheme: [Rgba]) -> Background? {
            if let bg = Drawing.background(b, r) { pictures.add([bg], &p, master: [:]) }
            return Masters.background(b, r, scheme: scheme, pictures: pictures.refs)
        }
        if let main = masters.main, !p.masters.isEmpty, let bg = background(main.bytes, main.record, masterScheme) { p.masters[0].background = bg }
        if var m = p.masters.first {
            m.titleStyle = styles.listStyle(0, base)
            m.bodyStyle = styles.listStyle(1, base)
            m.otherStyle = styles.listStyle(4, base)
            m.theme.colors = Masters.themeColors(masterScheme, m.theme.colors)
            p.masters[0] = m
        }
        p.defaultTextStyle = styles.listStyle(4, base)
        if let hf = Document.headerFooter(doc, children) { p.headerFooter = hf }
        let notesBodies = notesText(file, doc, children, base)

        let layout = layoutOfKind(p, .blank) ?? p.masters.first?.layouts.first?.id ?? LayoutId(0)
        var unread: [Int] = []
        for (i, entry) in slideRefs.enumerated() {
            // The deck can run out of ids only past millions of slides; a file can't make that many.
            guard var slide = newSlide(&p, layout) else { break }
            if let o = file.object(entry.ref), let r = Record(o, at: 0), r.type == RT.slide, r.isContainer {
                let scheme = masters.scheme(slide: o, r) ?? masterScheme
                let ctx = TextContext(fonts: fonts, scheme: scheme, styles: styles)
                var builder = ShapeBuilder(b: o, outline: entry.outline, ctx: ctx, hyperlinks: hyperlinks, defaults: shapeDefaults,
                                           masterShapes: masterShapes, linked: scheme == masterScheme)
                let (drawn, rules) = Drawing.tree(o, r)
                pictures.add(drawn, &p, master: masterShapes)
                for ref in Self.exObjects(o, drawn) {
                    _ = objects.media(ref, &p)
                    if case .ole(let label)? = objects.objects[ref]?.kind { asPictures.append("slide \(i + 1): \(label)") }
                }
                builder.pictures = pictures.refs
                builder.objects = objects
                slide.shapes = builder.build(&p, drawn, rules: rules)
                slide.comments = Document.comments(o, r)
                (slide.transition, slide.hidden) = SlideShow.transition(o, r) { objects.sound($0, &p) }
                slide.animations = SlideShow.animations(o, r, drawn: drawn, shapes: slide.shapes, ids: builder.ids, scheme: scheme)
                let atom = Masters.slideAtom(o, r)
                if let atom, atom.flags & 0x4 == 0, let bg = background(o, r, scheme) {
                    // Its own background.
                    slide.background = bg
                } else if scheme != masterScheme, let atom, let (mb, mr) = masters.byId[atom.masterId],
                          let bg = background(mb, mr, scheme) {
                    // A master other than the one DCModel has, or other colours: that master's background, resolved.
                    slide.background = bg
                }
            } else {
                unread.append(i + 1)
            }
            if let n = notesBodies[entry.slideId] { slide.notes = n }
            p.slides.append(slide)
        }
        var report = PPTReport(slides: slideRefs.count, unreadSlides: unread, edits: file.edits, encrypted: file.isEncrypted,
                               notImported: ["the master's own shapes", "picture bullets"])
        report.asPictures = asPictures
        report.lostPictures = pictures.lost.count
        report.convertedPictures = pictures.converted
        return (p, report)
    }

    /// The external objects (ExObjRefAtom ids) a drawing's shapes show, in z-order, groups' members included.
    static func exObjects(_ b: [UInt8], _ drawn: [DrawnShape], depth: Int = 0) -> [UInt32] {
        guard depth < Drawing.maxDepth else { return [] }
        return drawn.flatMap { d -> [UInt32] in
            let own = d.clientData.first { $0.type == RT.exObjRefAtom && $0.body.count >= 4 }.map { [le32(b, $0.body.lowerBound)] } ?? []
            return own + exObjects(b, d.children, depth: depth + 1)
        }
    }

    /// PowerPoint's default colour scheme (white background, black text), for a file without one.
    static let defaultScheme: [Rgba] = [
        .rgb(255, 255, 255), .rgb(0, 0, 0), .rgb(128, 128, 128), .rgb(0, 0, 0),
        .rgb(187, 224, 227), .rgb(51, 51, 153), .rgb(0, 153, 153), .rgb(153, 204, 0),
    ]

    /// The document's font collection ([MS-PPT] 2.9.8): FontEntityAtoms in the Environment's FontCollectionContainer,
    /// each a 32-character UTF-16 face name.
    static func fontCollection(_ b: [UInt8], _ document: [Record]) -> [String] {
        guard let env = document.first(where: { $0.type == RT.environment }),
              let fc = env.children(b).first(where: { $0.type == RT.fontCollection })
        else { return [] }
        return fc.children(b).filter { $0.type == RT.fontEntityAtom }.map { r in
            var u: [UInt16] = []
            var p = r.body.lowerBound
            while p + 2 <= min(r.body.upperBound, r.body.lowerBound + 64) {
                let c = le16(b, p)
                if c == 0 { break }
                u.append(c)
                p += 2
            }
            return String(decoding: u, as: UTF16.self)
        }
    }

    /// Each notes page's text, by the id of the slide it belongs to: the notes list (SlideListWithTextContainer of
    /// instance 2) names the NotesContainers; each NotesAtom names its slide, and its notes-body placeholder holds the
    /// text.
    static func notesText(_ file: PPTFile, _ b: [UInt8], _ document: [Record], _ ctx: TextContext) -> [UInt32: TextBody] {
        guard let list = document.first(where: { $0.type == RT.slideListWithText && $0.instance == 2 }) else { return [:] }
        var out: [UInt32: TextBody] = [:]
        for r in list.children(b) where r.type == RT.slidePersistAtom && r.body.count >= 4 {
            guard let o = file.object(le32(b, r.body.lowerBound)), let notes = Record(o, at: 0), notes.type == RT.notes,
                  let atom = notes.children(o).first(where: { $0.type == RT.notesAtom }), atom.body.count >= 4
            else { continue }
            let slideId = le32(o, atom.body.lowerBound)
            for drawn in Drawing.shapes(o, notes) where drawn.placeholder?.type == 0x0C {
                if let text = PPTText.bodies(o, drawn.textbox).first, !text.chars.isEmpty {
                    out[slideId] = text.body(ctx)
                }
            }
        }
        return out
    }

    /// The DCModel placeholder for a PlaceholderEnum ([MS-PPT] 2.13.25).
    static func placeholderKind(_ t: UInt8) -> (type: PhType, vertical: Bool)? {
        switch t {
        case 0x01, 0x0D: (.title, false)
        case 0x03, 0x0F: (.ctrTitle, false)
        case 0x02, 0x0E: (.body, false)
        case 0x04, 0x10: (.subTitle, false)
        case 0x11: (.title, true)
        case 0x12: (.body, true)
        case 0x13: (.obj, false)
        case 0x19: (.obj, true)
        case 0x14: (.chart, false)
        case 0x15: (.table, false)
        case 0x16: (.clipArt, false)
        case 0x17: (.diagram, false)
        case 0x18: (.media, false)
        case 0x1A: (.picture, false)
        case 0x07: (.date, false)
        case 0x08: (.slideNum, false)
        case 0x09: (.footer, false)
        case 0x0A: (.header, false)
        case 0x05, 0x0B: (.slideImage, false)
        case 0x06, 0x0C: (.body, false)
        default: nil
        }
    }
}
