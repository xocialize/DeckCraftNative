// DCEngine — the `ideas` command module: Design Ideas, arrangements of what is on the current slide (picture
// full-bleed with the title on a band, picture on one half, a framed picture, text-only layouts). An idea
// moves and resizes the slide's own shapes and crops pictures to their new box; it changes only that slide.
// Everything is computed here, offline and deterministically.
// Port of deckcraft crates/engine/src/cmd/ideas.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

public enum IdeasCommands {
    public static func specs() -> [CommandSpec] {
        [
            .query("design.ideas", "Design Ideas", [], nil, "{slide?} → [{id, label}] ideas for the slide", Cmd.hasSlide, ideasCmd),
            .cmd("design.applyIdea", "Apply Design Idea", ["Home", "Designer"], nil, "{id, slide?}", Cmd.hasSlide, applyCmd),
        ]
    }

    /// An idea: id and label.
    public typealias Idea = (id: String, label: String)

    static let pictureIdeas: [Idea] = [
        ("fullBleed", "Full-bleed picture, title on a band"),
        ("pictureLeft", "Picture left, text right"),
        ("pictureRight", "Picture right, text left"),
        ("framed", "Framed picture beside the title"),
    ]
    static let textIdeas: [Idea] = [
        ("titleColumn", "Title column beside the text"), ("centred", "Centred title over the text"), ("titleBottom", "Text above, title at the foot"),
    ]

    /// The roles of a slide's top-level shapes, by index.
    struct Roles {
        var title: Int?
        var picture: Int?
        var text: [Int] = []
    }

    static func isPicture(_ s: Shape) -> Bool {
        if case .picture = s.kind { return true }
        return false
    }

    static func isTitle(_ s: Shape) -> Bool { s.ph?.kind.isTitle ?? false }

    static func hasText(_ s: Shape) -> Bool { s.text.map { !rustTrim($0.text).isEmpty } ?? false }

    static func roles(_ shapes: [Shape]) -> Roles {
        var r = Roles()
        func area(_ j: Int) -> Double { shapes.at(j)?.xfrm.map { $0.w * $0.h } ?? 0.0 }
        for (i, s) in shapes.enumerated() {
            if s.hidden { continue }
            if isTitle(s) && r.title == nil {
                r.title = i
            } else if isPicture(s) {
                // The largest picture leads.
                if r.picture.map({ area(i) > area($0) }) ?? true { r.picture = i }
            } else if hasText(s) {
                r.text.append(i)
            }
        }
        return r
    }

    /// Whether `s` paints a fill or an outline once inherited and style-referenced values are resolved, as
    /// the renderer does (`fill: nil` alone means inherited, not invisible).
    static func shows(_ ctx: Resolve.Ctx?, _ s: Shape) -> Bool {
        func visible(_ f: Fill?) -> Bool { f.map { !$0.isNone } ?? false }
        if let ctx {
            return visible(Resolve.fill(ctx, s).fill) || visible(Resolve.line(ctx, s).line.fill)
        }
        return visible(s.fill) || visible(s.line?.fill)
    }

    /// Whether an idea may move this shape: a picture, a placeholder or a plain text box. Diagram boxes,
    /// connectors, groups, tables, charts and media are laid out by their own geometry, which the ideas do
    /// not know, so a slide holding one gets no ideas.
    static func arrangeable(_ ctx: Resolve.Ctx?, _ s: Shape) -> Bool {
        switch s.kind {
        case .picture: return true
        case .shape:
            // Only titles and shapes with text are moved (see `roles`): an empty one that shows (filled or
            // outlined) would stay where it is, over the rearranged slide.
            return (s.ph != nil || s.textBox) && (isTitle(s) || hasText(s) || !shows(ctx, s))
        default: return false
        }
    }

    /// The ideas for slide `index` (none when it has nothing to arrange, or other content in the way).
    public static func ideasFor(_ doc: Presentation, _ index: Int) -> [Idea] {
        guard let slide = doc.slides.at(index) else { return [] }
        let ctx = Resolve.Ctx.forSlide(doc, slide)
        if slide.shapes.contains(where: { !$0.hidden && !arrangeable(ctx, $0) }) { return [] }
        // The ideas move one picture; a second would stay put, over the rearranged text.
        if slide.shapes.filter({ !$0.hidden && isPicture($0) }).count > 1 { return [] }
        let r = roles(slide.shapes)
        if r.picture != nil { return pictureIdeas }
        if r.title != nil && !r.text.isEmpty { return textIdeas }
        return []
    }

    /// Crop a picture whose source has aspect `src` (w/h) to fill a box of aspect `dst`, centred.
    static func coverCrop(_ src: Double, _ dst: Double) -> [Double] {
        if !(src.isFinite && dst.isFinite && src > 0.0 && dst > 0.0) { return [0, 0, 0, 0] }
        if src > dst {
            let cut = (1.0 - dst / src) / 2.0
            return [cut, 0.0, cut, 0.0]
        }
        let cut = (1.0 - src / dst) / 2.0
        return [0.0, cut, 0.0, cut]
    }

    /// The light fill behind the title in the full-bleed idea. Its opacity is an `alpha` transform (about
    /// 220/255), as PPTX stores it, so the fill compares equal after a save and reopen.
    static func bandFill() -> Fill {
        .solid(ColorRef.rgb(.rgb(255, 255, 255)).with(.alpha(86274)))
    }

    /// The band as released versions up to 0.10 stored it (opacity in the colour's own alpha).
    static func legacyBandFill() -> Fill {
        .solid(ColorRef.rgb(.rgba(255, 255, 255, 220)))
    }

    /// Whether `f` is a Full-bleed band, in the current or the legacy form.
    static func isBand(_ f: Fill) -> Bool { f == bandFill() || f == legacyBandFill() }

    /// Apply idea `id` to slide `index` of `doc` (`sel` resolves inherited placeholder boxes).
    public static func applyIdea(_ doc: inout Presentation, _ sel: Selection, _ index: Int, _ id: String) throws {
        if !ideasFor(doc, index).contains(where: { $0.id == id }) {
            throw Cmd.bad("design.applyIdea", "no idea `\(id)` for this slide (see design.ideas)")
        }
        let (sw, sh) = (doc.slideSize.width.rustMax(1.0), doc.slideSize.height.rustMax(1.0))
        var sel = sel
        sel.slide = index
        guard let shapes = doc.slides.at(index)?.shapes else { throw Cmd.bad("design.applyIdea", "no slide") }
        let r = roles(shapes)
        let boxes = shapes.map { Cmd.xfrmOf(doc, sel, $0) }
        let m = sw.rustMin(sh) * 0.06
        var place: [(Int, Xfrm)] = []
        // Text shapes stacked in a box.
        func stack(_ b: Xfrm) {
            let n = Double(max(r.text.count, 1))
            let gap = m * 0.4
            let h = ((b.h - gap * (n - 1.0)) / n).rustMax(1.0)
            for (k, i) in r.text.enumerated() {
                place.append((i, Xfrm(b.x, b.y + Double(k) * (h + gap), b.w, h)))
            }
        }
        var band = false
        switch id {
        case "fullBleed":
            if let p = r.picture { place.append((p, Xfrm(0.0, 0.0, sw, sh))) }
            if let t = r.title {
                place.append((t, Xfrm(m, sh * 0.68, sw - 2.0 * m, sh * 0.2)))
                band = true
            }
            stack(Xfrm(m, sh * 0.06, sw * 0.45, sh * 0.5))
        case "pictureLeft", "pictureRight":
            let left = id == "pictureLeft"
            let half = sw * 0.5
            let (px, tx) = left ? (0.0, half + m) : (half, m)
            if let p = r.picture { place.append((p, Xfrm(px, 0.0, half, sh))) }
            let tw = half - 2.0 * m
            if let t = r.title { place.append((t, Xfrm(tx, m, tw, sh * 0.24))) }
            stack(Xfrm(tx, m + sh * 0.28, tw, sh - 2.0 * m - sh * 0.28))
        case "framed":
            if let p = r.picture { place.append((p, Xfrm(sw * 0.42, m * 1.5, sw * 0.58 - m * 1.5, sh - 3.0 * m))) }
            let tw = sw * 0.42 - 2.0 * m
            if let t = r.title { place.append((t, Xfrm(m, m * 1.5, tw, sh * 0.3))) }
            stack(Xfrm(m, m * 1.5 + sh * 0.34, tw, sh - 3.0 * m - sh * 0.34))
        case "titleColumn":
            if let t = r.title { place.append((t, Xfrm(m, m, sw * 0.32, sh - 2.0 * m))) }
            stack(Xfrm(sw * 0.36, m, sw * 0.64 - m, sh - 2.0 * m))
        case "centred":
            if let t = r.title { place.append((t, Xfrm(sw * 0.1, m, sw * 0.8, sh * 0.26))) }
            stack(Xfrm(sw * 0.18, m + sh * 0.3, sw * 0.64, sh - 2.0 * m - sh * 0.3))
        case "titleBottom":
            stack(Xfrm(m, m, sw - 2.0 * m, sh * 0.62))
            if let t = r.title { place.append((t, Xfrm(m, sh * 0.72, sw - 2.0 * m, sh * 0.2))) }
        default:
            throw Cmd.bad("design.applyIdea", "no idea `\(id)`")
        }
        guard doc.slides.indices.contains(index) else { throw Cmd.bad("design.applyIdea", "no slide") }
        var slide = doc.slides[index]
        for (i, x) in place {
            guard slide.shapes.indices.contains(i), let old = boxes.at(i) else { continue }
            if case .picture(var fill) = slide.shapes[i].kind {
                // The source's aspect, from the current box and crop.
                let c = fill.crop
                let (c0, c1, c2, c3) = (c.at(0) ?? 0, c.at(1) ?? 0, c.at(2) ?? 0, c.at(3) ?? 0)
                let (fw, fh) = ((1.0 - c0 - c2).rustMax(0.01), (1.0 - c1 - c3).rustMax(0.01))
                let src = (old.w / fw) / (old.h / fh).rustMax(1e-6)
                fill.crop = coverCrop(src, x.w / x.h.rustMax(1e-6))
                slide.shapes[i].kind = .picture(fill: fill)
            }
            var nx = x
            nx.rot = 0.0
            slide.shapes[i].xfrm = nx
        }
        // The picture goes to the back, so text over it stays readable.
        if let p = r.picture, p < slide.shapes.count {
            let pic = slide.shapes.remove(at: p)
            slide.shapes.insert(pic, at: 0)
        }
        if let t = slide.shapes.firstIndex(where: { !$0.hidden && isTitle($0) }) {
            if band {
                slide.shapes[t].fill = bandFill()
            } else if let f = slide.shapes[t].fill, isBand(f) {
                // The band belongs to full-bleed only: another idea takes it away again.
                slide.shapes[t].fill = nil
            }
        }
        doc.slides[index] = slide
    }

    @Sendable static func ideasCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let i = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        return .array(ideasFor(st.doc, i).map { ["id": .string($0.id), "label": .string($0.label)] })
    }

    @Sendable static func applyCmd(_ s: Session, _ p: JSON) throws -> JSON {
        guard let id = Cmd.strParam(p, "id") else { throw Cmd.bad("design.applyIdea", "missing `id`") }
        let slide = Cmd.usizeParam(p, "slide")
        return try s.edit { doc, sel in
            let i = slide ?? sel.slide
            try applyIdea(&doc, sel, i, id)
            return ["slide": .integer(i), "id": .string(id)]
        }
    }
}
