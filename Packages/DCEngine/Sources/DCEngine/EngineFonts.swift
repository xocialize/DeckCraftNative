// DCEngine — fonts a presentation uses that this machine doesn't have, so opening it can say so (its text
// draws in a stand-in; see `FontDB.documentFace`), and Replace Fonts.
// Port of deckcraft crates/engine/src/fonts.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel
import DCText

public enum EngineFonts {
    /// Load each embedded face into the font database, so text in that family draws with the file's font
    /// on a machine that doesn't have it. A face already loaded stays; the part bytes are kept either
    /// way. MicroType Express subsets have no TrueType or OpenType font to load and are left for the round
    /// trip.
    public static func installEmbeddedFonts(_ p: Presentation) {
        let db = FontDB.shared
        for font in p.embeddedFonts {
            for id in font.faces.compactMap({ $0 }) {
                guard let item = p.media(id), let sfnt = embeddedSFNT(item.data) else { continue }
                _ = db.addFont(Array(sfnt))
            }
        }
    }

    /// The font families the slides' text is drawn in (theme fonts resolved, bullet fonts included) that
    /// aren't installed or bundled, sorted, without duplicates (case-insensitive).
    public static func missingFonts(_ p: Presentation) -> [String] {
        let db = FontDB.shared
        var out: [String] = []
        for family in usedFonts(p) {
            if !db.hasFamily(family) && !out.contains(where: { eqIgnoreASCIICase($0, family) }) { out.append(family) }
        }
        // `sort_by_key(to_lowercase)`: stable, by the lowercased name's bytes.
        return out.enumerated().sorted { a, b in
            let ka = Array(rustLowercase(a.element).utf8)
            let kb = Array(rustLowercase(b.element).utf8)
            return ka == kb ? a.offset < b.offset : ka.lexicographicallyPrecedes(kb)
        }.map(\.element)
    }

    static func eqIgnoreASCIICase(_ a: String, _ b: String) -> Bool { Array(rustASCIILowercase(a).utf8) == Array(rustASCIILowercase(b).utf8) }

    /// The families the slides' text runs and bullets are drawn in.
    public static func usedFonts(_ p: Presentation) -> [String] {
        var out: [String] = []
        func add(_ f: String) {
            let f = String(rustTrim(f))
            if !f.isEmpty && !out.contains(where: { eqIgnoreASCIICase($0, f) }) { out.append(f) }
        }
        for slide in p.slides {
            guard let ctx = Resolve.Ctx.forSlide(p, slide) else { continue }
            walk(slide.shapes) { s, _ in
                if let body = s.text { bodyFonts(ctx, s, body, add) }
                if case .table(let t) = s.kind {
                    for row in t.rows { for cell in row.cells { bodyFonts(ctx, s, cell.text, add) } }
                }
            }
        }
        return out
    }

    private static func bodyFonts(_ ctx: Resolve.Ctx, _ s: Shape, _ body: TextBody, _ add: (String) -> Void) {
        for para in body.paragraphs {
            let hasText = para.runs.contains { !rustTrim($0.text).isEmpty }
            if !hasText { continue }
            for run in para.runs where !rustTrim(run.text).isEmpty {
                let r = Resolve.run(ctx, s, para, run.props)
                add(Resolve.fontFamily(ctx, r))
            }
            let pp = Resolve.para(ctx, s, para)
            if case .char? = pp.bullet, let f = pp.bulletFont {
                add(ctx.master.theme.font(f))
            }
        }
    }

    /// Replace the font family `from` with `to` everywhere it is named explicitly: text runs (and their
    /// east Asian, complex script and symbol faces), bullet fonts, paragraph end marks, list styles of
    /// shapes, layouts and masters, the master text styles, the deck default style, speaker notes, tables
    /// and the theme fonts. Names compare case-insensitively; theme references (`+mn-lt`) are left alone.
    /// Returns how many names changed.
    @discardableResult
    public static func replaceFont(_ p: inout Presentation, _ fromName: String, _ toName: String) -> Int {
        let from = String(rustTrim(fromName))
        let to = String(rustTrim(toName))
        if from.isEmpty || to.isEmpty || from.hasPrefix("+") || from == to { return 0 }
        var n = 0
        func fix(_ f: inout String?) {
            if let x = f, eqIgnoreASCIICase(String(rustTrim(x)), from) {
                f = to
                n += 1
            }
        }
        replaceList(&p.defaultTextStyle, fix)
        for i in p.slides.indices {
            replaceShapes(&p.slides[i].shapes, fix)
            replaceBody(&p.slides[i].notes, fix)
        }
        var themeHits = 0
        func master(_ m: inout Master) {
            replaceShapes(&m.shapes, fix)
            replaceList(&m.titleStyle, fix)
            replaceList(&m.bodyStyle, fix)
            replaceList(&m.otherStyle, fix)
            for l in m.layouts.indices { replaceShapes(&m.layouts[l].shapes, fix) }
            func set(_ s: inout FontSet) {
                func face(_ f: inout String) {
                    if eqIgnoreASCIICase(String(rustTrim(f)), from) {
                        f = to
                        themeHits += 1
                    }
                }
                face(&s.latin)
                face(&s.ea)
                face(&s.cs)
                for k in s.scripts.indices { face(&s.scripts[k].typeface) }
            }
            set(&m.theme.fonts.major)
            set(&m.theme.fonts.minor)
        }
        for i in p.masters.indices { master(&p.masters[i]) }
        if var m = p.notesMaster {
            master(&m)
            p.notesMaster = m
        }
        if var m = p.handoutMaster {
            master(&m)
            p.handoutMaster = m
        }
        return n + themeHits
    }

    private static func replaceShapes(_ shapes: inout [Shape], _ fix: (inout String?) -> Void) {
        for i in shapes.indices {
            if var body = shapes[i].text {
                replaceBody(&body, fix)
                shapes[i].text = body
            }
            if case .table(var t) = shapes[i].kind {
                for r in t.rows.indices { for c in t.rows[r].cells.indices { replaceBody(&t.rows[r].cells[c].text, fix) } }
                shapes[i].kind = .table(t)
            }
            shapes[i].mutateChildren { replaceShapes(&$0, fix) }
        }
    }

    private static func replaceBody(_ body: inout TextBody, _ fix: (inout String?) -> Void) {
        replaceList(&body.listStyle, fix)
        for i in body.paragraphs.indices {
            fix(&body.paragraphs[i].props.bulletFont)
            replaceRun(&body.paragraphs[i].endProps, fix)
            for k in body.paragraphs[i].runs.indices { replaceRun(&body.paragraphs[i].runs[k].props, fix) }
        }
    }

    private static func replaceList(_ l: inout ListStyle, _ fix: (inout String?) -> Void) {
        for i in l.levels.indices {
            guard var lvl = l.levels[i] else { continue }
            fix(&lvl.para.bulletFont)
            replaceRun(&lvl.run, fix)
            l.levels[i] = lvl
        }
    }

    private static func replaceRun(_ r: inout RunProps, _ fix: (inout String?) -> Void) {
        fix(&r.font)
        fix(&r.fontEa)
        fix(&r.fontCs)
        fix(&r.fontSym)
    }
}
