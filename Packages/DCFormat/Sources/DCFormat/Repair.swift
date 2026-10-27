// DCFormat — making a loaded presentation safe to edit and draw: a master exists, every slide's layout
// exists, duplicate ids are re-id'd, and numbers no view can draw are brought into range. Port of
// deckcraft crates/format/src/lib.rs (`repair` and the `sane_*` functions; MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel

extension DeckFormat {
    /// Smallest and largest slide side, in points: PowerPoint's 1–56 in, as Design › Slide Size allows.
    public static let slideSide: ClosedRange<Double> = 72.0 ... 4032.0

    /// Make a loaded presentation safe to edit: a master exists, every slide's layout exists, tables are
    /// rectangular, and duplicate ids are re-id'd — unless the deck has used every id, in which case a
    /// duplicate stays (growth is refused; see the comment in the loop).
    public static func repair(_ p: inout Presentation) {
        if p.masters.isEmpty {
            p.masters = blankPresentation(p.slideSize, .default, false).masters
        }
        p.fixNextId()
        let firstLayout = p.masters.first?.layouts.first?.id ?? LayoutId(0)
        var seen = Set<SlideId>()
        for i in p.slides.indices {
            let needsLayout = p.layout(p.slides[i].layout) == nil
            let dup = !seen.insert(p.slides[i].id).inserted
            if needsLayout || dup {
                // An exhausted id space leaves a duplicate slide as it is: the engine refuses to grow such a
                // deck (edits by id stay ambiguous for the duplicate), and the duplicate stays visible rather
                // than the file failing to open (#407).
                let newId = dup ? p.allocId().map(SlideId.init) : nil
                if needsLayout { p.slides[i].layout = firstLayout }
                if let id = newId { p.slides[i].id = id }
            }
        }
        reidDuplicateShapes(&p)
        p.slideSize = saneSlideSize(p.slideSize)
        // The notes page only lays out notes, but its size divides too.
        let n = p.notesSize
        if !(n.width.isFinite && n.width > 0 && n.height.isFinite && n.height > 0) {
            p.notesSize = Size(540.0, 720.0)
        }
        saneNumbers(&p)
    }

    /// Give a shape that repeats an id already used on its slide, layout or master (groups included) a
    /// fresh one, so edits, selection and the Selection Pane find one shape per id. The first keeps its
    /// id, and with it what animations and connectors point at. An exhausted id space leaves the rest as
    /// they are (#407).
    static func reidDuplicateShapes(_ p: inout Presentation) {
        func hasDuplicates(_ shapes: [Shape]) -> Bool {
            var seen = Set<ShapeId>()
            var dup = false
            walk(shapes) { sh, _ in dup = !seen.insert(sh.id).inserted || dup }
            return dup
        }
        func reid(_ shapes: inout [Shape], _ seen: inout Set<ShapeId>, _ next: inout UInt32, _ depth: Int) {
            if depth > 64 { return }
            for i in shapes.indices {
                if !seen.insert(shapes[i].id).inserted {
                    let (id, overflow) = Swift.max(next, 1).addingReportingOverflow(1)
                    if !overflow {
                        next = id
                        shapes[i].id = ShapeId(id)
                        seen.insert(shapes[i].id)
                    }
                }
                shapes[i].mutateChildren { reid(&$0, &seen, &next, depth + 1) }
            }
        }
        var next = p.nextId
        func fix(_ shapes: inout [Shape]) {
            if hasDuplicates(shapes) {
                var seen = Set<ShapeId>()
                reid(&shapes, &seen, &next, 0)
            }
        }
        for i in p.slides.indices where hasDuplicates(p.slides[i].shapes) {
            fix(&p.slides[i].shapes)
        }
        func fixMaster(_ m: inout Master) {
            guard hasDuplicates(m.shapes) || m.layouts.contains(where: { hasDuplicates($0.shapes) }) else { return }
            fix(&m.shapes)
            for l in m.layouts.indices { fix(&m.layouts[l].shapes) }
        }
        for i in p.masters.indices { fixMaster(&p.masters[i]) }
        if var m = p.notesMaster {
            fixMaster(&m)
            p.notesMaster = m
        }
        if var m = p.handoutMaster {
            fixMaster(&m)
            p.handoutMaster = m
        }
        p.nextId = next
    }

    /// A slide size the views and renderer can always lay out: a missing, zero, negative or non-finite
    /// side gives the 16:9 default, and each side is brought into `slideSide`.
    public static func saneSlideSize(_ s: Size) -> Size {
        func ok(_ v: Double) -> Bool { v.isFinite && v > 0 }
        if !(ok(s.width) && ok(s.height)) { return wideSlideSize }
        return Size(s.width.clamped(slideSide.lowerBound, slideSide.upperBound), s.height.clamped(slideSide.lowerBound, slideSide.upperBound))
    }

    /// Largest coordinate or size kept, in points (about 350 m; PowerPoint's own limit is far smaller).
    static let maxCoord = 1.0e6

    /// The largest effect sizes, in points: what Format Shape and `shape.effects` allow. A file can say
    /// anything, and the renderer's memory grows with these (a glow of 10^18 pt asked for 34 GB).
    static let maxGlow = 150.0
    static let maxSoftEdge = 100.0
    static let maxShadow = 200.0
    static let maxReflection = 100.0

    private static func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// Rust's `f64::rem_euclid`: the non-negative remainder.
    static func remEuclid(_ v: Double, _ m: Double) -> Double {
        let r = v.rem(m)
        return r < 0 ? r + Swift.abs(m) : r
    }

    /// Numbers no view can draw or no file should keep: non-finite positions, sizes and angles become 0,
    /// huge ones are clamped, angles are brought into 0–360.
    static func saneXfrm(_ x: inout Xfrm) {
        x.x = fin(x.x).clamped(-maxCoord, maxCoord)
        x.y = fin(x.y).clamped(-maxCoord, maxCoord)
        x.w = fin(x.w).clamped(0.0, maxCoord)
        x.h = fin(x.h).clamped(0.0, maxCoord)
        x.rot = remEuclid(fin(x.rot), 360.0)
        if x.rot >= 360.0 { x.rot = 0.0 }
    }

    /// `v` within 0...`max`; not a number is 0.
    static func effectSize(_ v: Double, _ max: Double) -> Double {
        v.isFinite ? v.clamped(0.0, max) : 0.0
    }

    static func saneRun(_ p: inout RunProps) {
        p.size = p.size.flatMap { $0.isFinite && $0 > 0 ? $0.clamped(1.0, 4000.0) : nil }
        if var s = p.shadow {
            saneShadow(&s)
            p.shadow = s
        }
        if var s = p.innerShadow {
            saneShadow(&s)
            p.innerShadow = s
        }
        if var g = p.glow {
            g.radius = effectSize(g.radius, maxGlow)
            p.glow = g
        }
        if var r = p.reflection {
            saneReflection(&r)
            p.reflection = r
        }
        p.softEdge = p.softEdge.map { effectSize($0, maxSoftEdge) }
    }

    static func saneShadow(_ s: inout Shadow) {
        s.blur = effectSize(s.blur, maxShadow)
        s.dist = effectSize(s.dist, maxShadow)
        s.dir = s.dir.isFinite ? remEuclid(s.dir, 360.0) : 0.0
        // Perspective scale (1 = 100%) and skew (degrees).
        s.sx = s.sx.isFinite ? s.sx.clamped(-10.0, 10.0) : 1.0
        s.sy = s.sy.isFinite ? s.sy.clamped(-10.0, 10.0) : 1.0
        s.kx = s.kx.isFinite ? s.kx.clamped(-89.0, 89.0) : 0.0
        s.ky = s.ky.isFinite ? s.ky.clamped(-89.0, 89.0) : 0.0
    }

    static func saneReflection(_ r: inout Reflection) {
        r.blur = effectSize(r.blur, maxReflection)
        r.dist = effectSize(r.dist, maxReflection)
    }

    /// Run properties a list style hands down to the text that inherits it.
    static func saneListStyle(_ ls: inout ListStyle) {
        for i in ls.levels.indices {
            guard var level = ls.levels[i] else { continue }
            saneRun(&level.run)
            ls.levels[i] = level
        }
    }

    static func saneEffects(_ e: inout Effects) {
        if var s = e.outerShadow {
            saneShadow(&s)
            e.outerShadow = s
        }
        if var s = e.innerShadow {
            saneShadow(&s)
            e.innerShadow = s
        }
        if var g = e.glow {
            g.radius = effectSize(g.radius, maxGlow)
            e.glow = g
        }
        e.softEdge = e.softEdge.map { effectSize($0, maxSoftEdge) }
        if var r = e.reflection {
            saneReflection(&r)
            e.reflection = r
        }
    }

    private static func saneParagraphs(_ paragraphs: inout [Paragraph]) {
        for pi in paragraphs.indices {
            saneRun(&paragraphs[pi].endProps)
            for ri in paragraphs[pi].runs.indices { saneRun(&paragraphs[pi].runs[ri].props) }
        }
    }

    private static func saneCrop(_ crop: inout [Double]) {
        for i in crop.indices {
            crop[i] = crop[i].isFinite ? crop[i].clamped(-10.0, 1.0) : 0.0
        }
    }

    static func saneShapes(_ shapes: inout [Shape], _ depth: Int) {
        if depth > 64 { return }
        for i in shapes.indices {
            if var x = shapes[i].xfrm {
                saneXfrm(&x)
                shapes[i].xfrm = x
            }
            if var l = shapes[i].line {
                l.width = l.width.flatMap { $0.isFinite && $0 >= 0 ? Swift.min($0, 1584.0) : nil }
                shapes[i].line = l
            }
            if var e = shapes[i].effects {
                saneEffects(&e)
                shapes[i].effects = e
            }
            if var t = shapes[i].text {
                saneListStyle(&t.listStyle)
                saneParagraphs(&t.paragraphs)
                shapes[i].text = t
            }
            switch shapes[i].kind {
            case .picture(var fill):
                saneCrop(&fill.crop)
                shapes[i].kind = .picture(fill: fill)
            case .media(var clip):
                saneCrop(&clip.crop)
                shapes[i].kind = .media(clip)
            case .group(var children, var child):
                saneXfrm(&child)
                shapes[i].kind = .shape
                saneShapes(&children, depth + 1)
                shapes[i].kind = .group(children: children, child: child)
            case .table(var t):
                for r in t.rows.indices {
                    for c in t.rows[r].cells.indices {
                        saneListStyle(&t.rows[r].cells[c].text.listStyle)
                        saneParagraphs(&t.rows[r].cells[c].text.paragraphs)
                    }
                }
                shapes[i].kind = .table(t)
            default:
                break
            }
        }
    }

    /// `saneShapes` over every slide, layout and master.
    public static func saneNumbers(_ p: inout Presentation) {
        for i in p.slides.indices {
            var fixed = p.slides[i]
            saneShapes(&fixed.shapes, 0)
            if fixed != p.slides[i] { p.slides[i] = fixed }
        }
        // What text and shapes inherit: the deck's default text style, each master's title, body and
        // other styles, and the theme's effect styles that shape styles point at.
        saneListStyle(&p.defaultTextStyle)
        func fixMaster(_ m: inout Master) {
            var fixed = m
            saneShapes(&fixed.shapes, 0)
            for l in fixed.layouts.indices { saneShapes(&fixed.layouts[l].shapes, 0) }
            saneListStyle(&fixed.titleStyle)
            saneListStyle(&fixed.bodyStyle)
            saneListStyle(&fixed.otherStyle)
            for e in fixed.theme.format.effects.indices { saneEffects(&fixed.theme.format.effects[e]) }
            if fixed != m { m = fixed }
        }
        for i in p.masters.indices { fixMaster(&p.masters[i]) }
        if var m = p.notesMaster {
            fixMaster(&m)
            p.notesMaster = m
        }
        if var m = p.handoutMaster {
            fixMaster(&m)
            p.handoutMaster = m
        }
    }
}
