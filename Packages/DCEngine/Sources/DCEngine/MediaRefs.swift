// DCEngine — every `MediaId` the model can reference, found by type rather than by scanning JSON keys.
// Port of deckcraft crates/engine/src/media_refs.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// One walker, written twice (Rust writes it once with a macro): `MediaRefs.Visit` reads ids,
// `MediaRefs.VisitMut` rewrites them in place. It covers pictures (and their artistic-effect originals),
// picture fills wherever a fill can sit (shapes, lines, text runs, table cells and styles, chart series
// and points, backgrounds, theme format schemes), media clips and their posters, 3-D models, OLE and
// SmartArt previews and kept parts, SmartArt node pictures, picture bullets, hyperlink, transition and
// animation sounds, and embedded font faces. Adding a `MediaId` field to the model means adding it to
// both walkers; the shape kinds are matched exhaustively so a new kind can't be missed.
import DCModel

public enum MediaRefs {
    /// Deepest group nesting walked (the model's other walkers stop at 64 too).
    static let maxDepth = 64

    /// Read every media id under a part of the model.
    public enum Visit {
        public typealias F = (MediaId) -> Void

        public static func picture(_ p: PictureFill, _ f: F) {
            f(p.media)
            if let a = p.artistic { f(a.original) }
        }

        public static func fill(_ x: Fill, _ f: F) {
            if case .picture(let p) = x { picture(p, f) }
        }

        static func optFill(_ x: Fill?, _ f: F) { if let x { fill(x, f) } }

        public static func line(_ l: Line, _ f: F) { optFill(l.fill, f) }

        static func optLine(_ l: Line?, _ f: F) { if let l { line(l, f) } }

        static func link(_ h: Hyperlink?, _ f: F) { if let id = h?.sound { f(id) } }

        static func run(_ r: RunProps, _ f: F) {
            optFill(r.fill, f)
            optLine(r.outline, f)
            link(r.link, f)
            link(r.hover, f)
        }

        static func para(_ p: ParaProps, _ f: F) {
            if case .picture(let media) = p.bullet { f(media) }
        }

        public static func list(_ l: ListStyle, _ f: F) {
            for lv in l.levels {
                guard let lv else { continue }
                para(lv.para, f)
                run(lv.run, f)
            }
        }

        public static func text(_ t: TextBody, _ f: F) {
            list(t.listStyle, f)
            for p in t.paragraphs {
                para(p.props, f)
                run(p.defProps, f)
                run(p.endProps, f)
                for r in p.runs { run(r.props, f) }
            }
        }

        static func table(_ t: Table, _ f: F) {
            optFill(t.background, f)
            for row in t.rows {
                for c in row.cells {
                    text(c.text, f)
                    optFill(c.fill, f)
                    for b in c.borders { optLine(b, f) }
                    optLine(c.diagDown, f)
                    optLine(c.diagUp, f)
                }
            }
        }

        static func tablePart(_ s: TablePartStyle, _ f: F) {
            optFill(s.fill, f)
            for b in s.borders {
                if case .line(let l)? = b { line(l, f) }
            }
        }

        public static func tableStyle(_ t: TableStyleDef, _ f: F) {
            for p in t.parts { tablePart(p.b, f) }
            if let s = t.background { tablePart(s, f) }
        }

        static func chart(_ c: Chart, _ f: F) {
            for s in c.series {
                optFill(s.fill, f)
                optLine(s.line, f)
                for p in s.pointFills { fill(p.b, f) }
            }
            optFill(c.plotFill, f)
            optFill(c.chartFill, f)
        }

        static func shapeAt(_ s: Shape, _ f: F, _ depth: Int) {
            if depth > maxDepth { return }
            switch s.kind {
            case .shape, .connector, .ink: break
            case .picture(let fill): picture(fill, f)
            case .group(let children, _): for c in children { shapeAt(c, f, depth + 1) }
            case .table(let t): table(t, f)
            case .chart(let c): chart(c, f)
            case .media(let m):
                f(m.media)
                if let p = m.poster { f(p) }
            case .model3d(let media, let poster):
                f(media)
                if let p = poster { f(p) }
            case .opaque(_, let preview, _, let parts):
                if let p = preview { f(p) }
                // SmartArt data, OLE embeddings… kept as media items (#209).
                for part in parts { f(part.c) }
            }
            optFill(s.fill, f)
            optLine(s.line, f)
            if let t = s.text { text(t, f) }
            link(s.click, f)
            link(s.hover, f)
            if let d = s.diagram {
                for n in d.nodes { if let p = n.picture { f(p) } }
            }
        }

        /// A shape and, for a group, everything in it.
        public static func shape(_ s: Shape, _ f: F) { shapeAt(s, f, 0) }

        public static func shapes(_ v: [Shape], _ f: F) { for s in v { shapeAt(s, f, 0) } }

        static func background(_ b: Background?, _ f: F) {
            if case .fill(let x)? = b { fill(x, f) }
        }

        /// A slide: shapes, background, transition and animation sounds, notes.
        public static func slide(_ s: Slide, _ f: F) {
            shapes(s.shapes, f)
            background(s.background, f)
            if let id = s.transition?.sound { f(id) }
            for a in s.animations { if let id = a.sound { f(id) } }
            text(s.notes, f)
        }

        public static func layout(_ l: Layout, _ f: F) {
            shapes(l.shapes, f)
            background(l.background, f)
        }

        public static func theme(_ t: Theme, _ f: F) {
            for x in t.format.fills { fill(x, f) }
            for x in t.format.bgFills { fill(x, f) }
            for l in t.format.lines { line(l, f) }
        }

        /// A master with its theme, text styles and layouts.
        public static func master(_ m: Master, _ f: F) {
            theme(m.theme, f)
            shapes(m.shapes, f)
            background(m.background, f)
            list(m.titleStyle, f)
            list(m.bodyStyle, f)
            list(m.otherStyle, f)
            for l in m.layouts { layout(l, f) }
        }

        public static func font(_ e: EmbeddedFont, _ f: F) {
            for id in [e.regular, e.bold, e.italic, e.boldItalic] { if let id { f(id) } }
        }
    }

    /// Rewrite every media id under a part of the model in place.
    public enum VisitMut {
        public typealias F = (inout MediaId) -> Void

        public static func picture(_ p: inout PictureFill, _ f: F) {
            f(&p.media)
            if var a = p.artistic {
                f(&a.original)
                p.artistic = a
            }
        }

        public static func fill(_ x: inout Fill, _ f: F) {
            if case .picture(var p) = x {
                picture(&p, f)
                x = .picture(p)
            }
        }

        static func optFill(_ x: inout Fill?, _ f: F) {
            guard var v = x else { return }
            fill(&v, f)
            x = v
        }

        public static func line(_ l: inout Line, _ f: F) { optFill(&l.fill, f) }

        static func optLine(_ l: inout Line?, _ f: F) {
            guard var v = l else { return }
            line(&v, f)
            l = v
        }

        static func link(_ h: inout Hyperlink?, _ f: F) {
            guard var v = h, var id = v.sound else { return }
            f(&id)
            v.sound = id
            h = v
        }

        static func run(_ r: inout RunProps, _ f: F) {
            optFill(&r.fill, f)
            optLine(&r.outline, f)
            link(&r.link, f)
            link(&r.hover, f)
        }

        static func para(_ p: inout ParaProps, _ f: F) {
            if case .picture(var media) = p.bullet {
                f(&media)
                p.bullet = .picture(media: media)
            }
        }

        public static func list(_ l: inout ListStyle, _ f: F) {
            for i in l.levels.indices {
                guard var lv = l.levels[i] else { continue }
                para(&lv.para, f)
                run(&lv.run, f)
                l.levels[i] = lv
            }
        }

        public static func text(_ t: inout TextBody, _ f: F) {
            list(&t.listStyle, f)
            for i in t.paragraphs.indices {
                para(&t.paragraphs[i].props, f)
                run(&t.paragraphs[i].defProps, f)
                run(&t.paragraphs[i].endProps, f)
                for k in t.paragraphs[i].runs.indices { run(&t.paragraphs[i].runs[k].props, f) }
            }
        }

        static func table(_ t: inout Table, _ f: F) {
            optFill(&t.background, f)
            for r in t.rows.indices {
                for c in t.rows[r].cells.indices {
                    text(&t.rows[r].cells[c].text, f)
                    optFill(&t.rows[r].cells[c].fill, f)
                    for b in t.rows[r].cells[c].borders.indices { optLine(&t.rows[r].cells[c].borders[b], f) }
                    optLine(&t.rows[r].cells[c].diagDown, f)
                    optLine(&t.rows[r].cells[c].diagUp, f)
                }
            }
        }

        static func tablePart(_ s: inout TablePartStyle, _ f: F) {
            optFill(&s.fill, f)
            for i in s.borders.indices {
                if case .line(var l)? = s.borders[i] {
                    line(&l, f)
                    s.borders[i] = .line(line: l)
                }
            }
        }

        public static func tableStyle(_ t: inout TableStyleDef, _ f: F) {
            for i in t.parts.indices { tablePart(&t.parts[i].b, f) }
            if var s = t.background {
                tablePart(&s, f)
                t.background = s
            }
        }

        static func chart(_ c: inout Chart, _ f: F) {
            for i in c.series.indices {
                optFill(&c.series[i].fill, f)
                optLine(&c.series[i].line, f)
                for k in c.series[i].pointFills.indices { fill(&c.series[i].pointFills[k].b, f) }
            }
            optFill(&c.plotFill, f)
            optFill(&c.chartFill, f)
        }

        static func shapeAt(_ s: inout Shape, _ f: F, _ depth: Int) {
            if depth > maxDepth { return }
            switch s.kind {
            case .shape, .connector, .ink: break
            case .picture(var fill):
                picture(&fill, f)
                s.kind = .picture(fill: fill)
            case .group:
                s.mutateChildren { kids in for i in kids.indices { shapeAt(&kids[i], f, depth + 1) } }
            case .table(var t):
                table(&t, f)
                s.kind = .table(t)
            case .chart(var c):
                chart(&c, f)
                s.kind = .chart(c)
            case .media(var m):
                f(&m.media)
                if var p = m.poster {
                    f(&p)
                    m.poster = p
                }
                s.kind = .media(m)
            case .model3d(var media, var poster):
                f(&media)
                if var p = poster {
                    f(&p)
                    poster = p
                }
                s.kind = .model3d(media: media, poster: poster)
            case .opaque(let xml, var preview, let label, var parts):
                if var p = preview {
                    f(&p)
                    preview = p
                }
                for i in parts.indices { f(&parts[i].c) }
                s.kind = .opaque(xml: xml, preview: preview, label: label, parts: parts)
            }
            optFill(&s.fill, f)
            optLine(&s.line, f)
            if var t = s.text {
                text(&t, f)
                s.text = t
            }
            link(&s.click, f)
            link(&s.hover, f)
            if var d = s.diagram {
                for i in d.nodes.indices {
                    if var p = d.nodes[i].picture {
                        f(&p)
                        d.nodes[i].picture = p
                    }
                }
                s.diagram = d
            }
        }

        /// A shape and, for a group, everything in it.
        public static func shape(_ s: inout Shape, _ f: F) { shapeAt(&s, f, 0) }

        public static func shapes(_ v: inout [Shape], _ f: F) { for i in v.indices { shapeAt(&v[i], f, 0) } }

        static func background(_ b: inout Background?, _ f: F) {
            if case .fill(var x)? = b {
                fill(&x, f)
                b = .fill(fill: x)
            }
        }

        /// A slide: shapes, background, transition and animation sounds, notes.
        public static func slide(_ s: inout Slide, _ f: F) {
            shapes(&s.shapes, f)
            background(&s.background, f)
            if var t = s.transition, var id = t.sound {
                f(&id)
                t.sound = id
                s.transition = t
            }
            for i in s.animations.indices {
                if var id = s.animations[i].sound {
                    f(&id)
                    s.animations[i].sound = id
                }
            }
            text(&s.notes, f)
        }

        public static func layout(_ l: inout Layout, _ f: F) {
            shapes(&l.shapes, f)
            background(&l.background, f)
        }

        public static func theme(_ t: inout Theme, _ f: F) {
            for i in t.format.fills.indices { fill(&t.format.fills[i], f) }
            for i in t.format.bgFills.indices { fill(&t.format.bgFills[i], f) }
            for i in t.format.lines.indices { line(&t.format.lines[i], f) }
        }

        /// A master with its theme, text styles and layouts.
        public static func master(_ m: inout Master, _ f: F) {
            theme(&m.theme, f)
            shapes(&m.shapes, f)
            background(&m.background, f)
            list(&m.titleStyle, f)
            list(&m.bodyStyle, f)
            list(&m.otherStyle, f)
            for i in m.layouts.indices { layout(&m.layouts[i], f) }
        }

        public static func font(_ e: inout EmbeddedFont, _ f: F) {
            func one(_ id: inout MediaId?) {
                if var v = id {
                    f(&v)
                    id = v
                }
            }
            one(&e.regular)
            one(&e.bold)
            one(&e.italic)
            one(&e.boldItalic)
        }
    }

    /// Every media reference in a presentation: slides, masters (with their layouts and themes), the notes
    /// and handout masters, default text style, table styles and embedded fonts.
    public static func visitPresentation(_ p: Presentation, _ f: Visit.F) {
        for s in p.slides { Visit.slide(s, f) }
        for m in p.masters + [p.notesMaster, p.handoutMaster].compactMap({ $0 }) { Visit.master(m, f) }
        Visit.list(p.defaultTextStyle, f)
        for t in p.tableStyles { Visit.tableStyle(t, f) }
        for e in p.embeddedFonts { Visit.font(e, f) }
    }

    /// The media ids a presentation references, each once, in the order first met.
    public static func presentationMedia(_ p: Presentation) -> [MediaId] { collect { visitPresentation(p, $0) } }

    /// The media ids a slide references (shapes, background, sounds, notes), each once.
    public static func slideMedia(_ s: Slide) -> [MediaId] { collect { Visit.slide(s, $0) } }

    /// The media ids shapes reference (groups included), each once.
    public static func shapesMedia(_ v: [Shape]) -> [MediaId] { collect { Visit.shapes(v, $0) } }

    private static func collect(_ walk: (Visit.F) -> Void) -> [MediaId] {
        var seen = Set<MediaId>()
        var out: [MediaId] = []
        walk { id in
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}
