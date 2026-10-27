// DCModel — inheritance: effective position, fill, line, body and text properties of a shape,
// following slide → layout placeholder → master placeholder → master text styles → theme. Port of
// deckcraft crates/model/src/resolve.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry

public enum Resolve {
    /// Where a shape lives, for resolving inherited values.
    public enum Owner: Sendable {
        case slide, layout, master
    }

    public struct Ctx: Sendable {
        public var pres: Presentation
        public var master: Master
        public var layout: Layout?
        public var owner: Owner
        public var scheme: ColorScheme
        /// The colour map in force: the slide's override, else its layout's, else the master's.
        public var colorMap: [Pair<String, String>]

        public static func forSlide(_ pres: Presentation, _ slide: Slide) -> Ctx? {
            guard let (master, layout) = pres.masterFor(slide) else { return nil }
            let map = slide.colorMap ?? layout?.colorMap ?? master.colorMap
            return Ctx(pres: pres, master: master, layout: layout, owner: .slide, scheme: master.scheme(with: map), colorMap: map)
        }

        public static func forLayout(_ pres: Presentation, _ master: Master, _ layout: Layout) -> Ctx {
            let map = layout.colorMap ?? master.colorMap
            return Ctx(pres: pres, master: master, layout: layout, owner: .layout, scheme: master.scheme(with: map), colorMap: map)
        }

        public static func forMaster(_ pres: Presentation, _ master: Master) -> Ctx {
            Ctx(pres: pres, master: master, layout: nil, owner: .master, scheme: master.scheme, colorMap: master.colorMap)
        }

        public func color(_ c: ColorRef, _ ph: Rgba?) -> Rgba {
            var c = c
            if case .scheme(let slot) = c.base, [.bg1, .tx1, .bg2, .tx2].contains(slot) {
                c.base = .scheme(slot: mapSlot(colorMap, slot))
            }
            return c.resolve(master.theme.colors, ph)
        }
    }

    private static func compatible(_ slide: PhType, _ other: PhType) -> Bool {
        switch slide {
        case .title, .ctrTitle:
            return other == .title || other == .ctrTitle
        case .subTitle, .body, .obj, .chart, .table, .clipArt, .diagram, .media, .picture:
            return ![.title, .ctrTitle, .date, .footer, .slideNum, .header].contains(other)
        default:
            return slide == other
        }
    }

    private static func findPh(_ shapes: [Shape], _ shape: Shape, _ byIdx: Bool) -> Shape? {
        guard let ph = shape.ph else { return nil }
        if byIdx && ph.idx != 0,
           let s = shapes.first(where: { s in s.ph.map { $0.idx == ph.idx && compatible(ph.kind, $0.kind) } ?? false }) {
            return s
        }
        // Same type first, then a compatible one.
        return shapes.first(where: { s in
            s.ph.map { $0.kind == ph.kind && (!byIdx || ph.idx == 0 || $0.idx == ph.idx || ph.kind.isTitle) } ?? false
        })
            ?? shapes.first(where: { s in s.ph.map { $0.kind == ph.kind } ?? false })
            ?? shapes.first(where: { s in s.ph.map { compatible(ph.kind, $0.kind) } ?? false })
    }

    private static func masterPh(_ master: Master, _ kind: PhType) -> Shape? {
        let want: PhType
        switch kind {
        case .title, .ctrTitle: want = .title
        case .date, .footer, .slideNum, .header: want = kind
        default: want = .body
        }
        return master.shapes.first { $0.phType == want }
    }

    /// The layout and master placeholders a shape inherits from.
    public static func parents(_ ctx: Ctx, _ shape: Shape) -> (layout: Shape?, master: Shape?) {
        guard let ph = shape.ph else { return (nil, nil) }
        switch ctx.owner {
        case .slide:
            let lp = ctx.layout.flatMap { findPh($0.shapes, shape, true) }
            let kind = lp?.phType ?? ph.kind
            return (lp, masterPh(ctx.master, kind))
        case .layout:
            return (nil, masterPh(ctx.master, ph.kind))
        case .master:
            return (nil, nil)
        }
    }

    private static func isTable(_ shape: Shape) -> Bool {
        if case .table = shape.kind { return true }
        return false
    }

    /// The text style group (title / body / other) a shape draws from. Text in a table takes the
    /// master's other-text style, also when the table sits in a content placeholder, as in PowerPoint
    /// for Mac; other shapes take the presentation's default text style.
    public static func masterListStyle(_ ctx: Ctx, _ shape: Shape) -> ListStyle {
        if isTable(shape) { return ctx.master.otherStyle }
        switch shape.phType {
        case .title?, .ctrTitle?:
            return ctx.master.titleStyle
        case .body?, .obj?, .subTitle?, .table?, .chart?, .diagram?, .media?, .picture?, .clipArt?:
            return ctx.master.bodyStyle
        case .some:
            return ctx.master.otherStyle
        case nil:
            return ctx.pres.defaultTextStyle
        }
    }

    public static func xfrm(_ ctx: Ctx, _ shape: Shape) -> Xfrm {
        if let x = shape.xfrm { return x }
        let (lp, mp) = parents(ctx, shape)
        if let x = lp?.xfrm ?? mp?.xfrm { return x }
        let sz = ctx.pres.slideSize
        return Xfrm(sz.width * 0.1, sz.height * 0.1, sz.width * 0.8, sz.height * 0.2)
    }

    /// A theme format list entry by 1-based style index (0 is never asked for).
    private static func styleEntry<T>(_ list: [T], _ oneBased: UInt32) -> T? {
        oneBased >= 1 ? list.at(Int(oneBased - 1)) : nil
    }

    /// Effective fill and the style colour (`phClr`) to resolve it with.
    public static func fill(_ ctx: Ctx, _ shape: Shape) -> (fill: Fill?, ph: Rgba?) {
        let (lp, mp) = parents(ctx, shape)
        func styleFill(_ s: Shape) -> (Fill?, Rgba?)? {
            guard let st = s.style else { return nil }
            let idx = st.fillRef.a
            let ph = ctx.color(st.fillRef.b, nil)
            let f: Fill?
            switch idx {
            case 0: f = .none_
            case 1001...: f = ctx.master.theme.format.bgFills.at(Int(idx - 1001))
            default: f = styleEntry(ctx.master.theme.format.fills, idx)
            }
            return (f, ph)
        }
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let f = s.fill {
                // A gradient without stops (`a:gradFill` with no `a:gsLst`) takes them from the gradient its
                // style refers to, keeping its own direction, as PowerPoint draws it.
                if case .gradient(var g) = f, g.stops.isEmpty, let (sf, ph) = styleFill(s), case .gradient(let sg)? = sf {
                    g.stops = sg.stops
                    return (.gradient(g), ph)
                }
                return (f, nil)
            }
            if let r = styleFill(s) { return r }
        }
        if shape.textBox { return (.none_, nil) }
        return (nil, nil)
    }

    public static func line(_ ctx: Ctx, _ shape: Shape) -> (line: Line, ph: Rgba?) {
        let (lp, mp) = parents(ctx, shape)
        var out = Line()
        var ph: Rgba?
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let l = s.line { out.inherit(l) }
            if let st = s.style {
                let idx = st.lineRef.a
                if ph == nil { ph = ctx.color(st.lineRef.b, nil) }
                if idx == 0 {
                    out.inherit(.none())
                } else if let l = styleEntry(ctx.master.theme.format.lines, idx) {
                    out.inherit(l)
                }
                break
            }
        }
        return (out, ph)
    }

    public static func effects(_ ctx: Ctx, _ shape: Shape) -> (effects: Effects?, ph: Rgba?) {
        let (lp, mp) = parents(ctx, shape)
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let e = s.effects { return (e, nil) }
            if let st = s.style {
                let idx = st.effectRef.a
                if idx == 0 { return (nil, nil) }
                return (styleEntry(ctx.master.theme.format.effects, idx), ctx.color(st.effectRef.b, nil))
            }
        }
        return (nil, nil)
    }

    /// Body properties with defaults filled in.
    public static func body(_ ctx: Ctx, _ shape: Shape) -> BodyProps {
        let (lp, mp) = parents(ctx, shape)
        var b = shape.text?.body ?? BodyProps()
        for s in [lp, mp].compactMap({ $0 }) {
            if let t = s.text { b.inherit(t.body) }
        }
        b.inherit(BodyProps(
            insetL: 7.2, insetT: 3.6, insetR: 7.2, insetB: 3.6,
            anchor: shape.ph == nil && !shape.textBox && !isTable(shape) ? .middle : .top,
            anchorCtr: false, wrap: true, autofit: shape.textBox ? .shape : .none_, vert: .horizontal, rot: 0.0,
            columns: 1, colSpacing: 0.0, warp: nil, warpAdj: [], rtlCol: false, upright: false, spaceFirstLast: false
        ))
        return b
    }

    /// The merged level style (paragraph + run defaults) for paragraphs at `level` in `shape`.
    public static func levelStyle(_ ctx: Ctx, _ shape: Shape, _ level: UInt8) -> LevelStyle {
        // A table's text inherits nothing from a placeholder the table sits in: PowerPoint draws it in
        // the other-text style even under list styles on the layout's and master's placeholders.
        let (lp, mp) = isTable(shape) ? (nil, nil) : parents(ctx, shape)
        var out = LevelStyle()
        func add(_ ls: LevelStyle?) {
            guard let l = ls else { return }
            out.para.inherit(l.para)
            out.run.inherit(l.run)
        }
        if let t = shape.text { add(t.listStyle.level(level)) }
        for s in [lp, mp].compactMap({ $0 }) {
            if let t = s.text { add(t.listStyle.level(level)) }
        }
        // Shape style font reference (theme font + colour) sits above the defaults.
        if let st = shape.style ?? lp?.style {
            let font: String? = switch st.fontRef.a {
            case "major": "+mj-lt"
            case "minor": "+mn-lt"
            default: nil
            }
            out.run.inherit(RunProps(font: font, fill: st.fontRef.b.map(Fill.solid)))
        }
        add(masterListStyle(ctx, shape).level(level))
        add(ctx.pres.defaultTextStyle.level(level))
        // Last resort.
        out.run.inherit(RunProps(font: "+mn-lt", size: 18.0, bold: false, italic: false))
        out.para.inherit(ParaProps(align: .left, marginLeft: 0.0, indent: 0.0))
        return out
    }

    /// Fully resolved run properties for `run` in paragraph `para` (explicit → paragraph style).
    public static func run(_ ctx: Ctx, _ shape: Shape, _ para: Paragraph, _ run: RunProps) -> RunProps {
        var r = run
        // Paragraph `defRPr` fills gaps in the run, and the list style (including the layout placeholder
        // this shape inherits from) fills whatever is still unset.
        r.inherit(para.defProps)
        let lvl = levelStyle(ctx, shape, para.level)
        r.inherit(lvl.run)
        // Hyperlinked text is drawn in the theme's hyperlink colour and underlined, as in PowerPoint,
        // unless the run itself sets a colour (honoured since PowerPoint 2019) or an underline (`u="none"`
        // removes it). Colours and underlines from list styles don't count.
        if r.link != nil {
            // A colour or underline on the run, or on the same `defRPr` that carries the link, is kept. A
            // colour that arrived only from a list style is not.
            let fromDef = run.link == nil
            if run.fill == nil && !(fromDef && para.defProps.fill != nil) {
                r.fill = .solid(.scheme(.hlink))
            }
            if run.underline == nil && !(fromDef && para.defProps.underline != nil) {
                r.underline = "sng"
            }
        }
        return r
    }

    public static func para(_ ctx: Ctx, _ shape: Shape, _ para: Paragraph) -> ParaProps {
        var p = para.props
        p.inherit(levelStyle(ctx, shape, para.level).para)
        return p
    }

    /// Concrete font family for a run (theme references resolved).
    public static func fontFamily(_ ctx: Ctx, _ r: RunProps) -> String {
        let name = ctx.master.theme.font(r.font ?? "+mn-lt")
        return name.isEmpty ? ctx.master.theme.fonts.minor.latin : name
    }

    /// Text colour of resolved run props.
    public static func textColor(_ ctx: Ctx, _ r: RunProps) -> Rgba {
        switch r.fill {
        case .solid(let color)?: return ctx.color(color, nil)
        case .gradient(let g)?: return g.stops.first.map { ctx.color($0.color, nil) } ?? .black
        case .none_?: return .transparent
        default: return ctx.color(.scheme(.tx1), nil)
        }
    }

    /// The background fill (and its style colour) of a slide.
    public static func background(_ ctx: Ctx, _ slide: Slide?) -> (fill: Fill, ph: Rgba?) {
        let bg = slide?.background ?? ctx.layout?.background ?? ctx.master.background
        switch bg {
        case .fill(let fill)?:
            return (fill, nil)
        case .ref(let idx, let color)?:
            let ph = ctx.color(color, nil)
            let f = idx >= 1001
                ? ctx.master.theme.format.bgFills.at(Int(idx - 1001))
                : ctx.master.theme.format.fills.at(Int(idx > 0 ? idx - 1 : 0))
            return (f ?? .solid(.rgb(ph)), ph)
        case nil:
            return (.solid(.scheme(.bg1)), nil)
        }
    }

    /// Should the layout/master graphics (non-placeholder shapes) show behind this slide?
    public static func showMasterShapes(_ slide: Slide, _ layout: Layout?) -> (layout: Bool, master: Bool) {
        let showLayout = slide.showMasterShapes
        let showMaster = showLayout && (layout.map(\.showMasterShapes) ?? true)
        return (showLayout, showMaster)
    }
}
