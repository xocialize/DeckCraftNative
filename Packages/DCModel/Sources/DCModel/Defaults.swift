// DCModel — a new presentation: one master with the standard set of layouts, master text styles, and
// a first title slide. Positions and sizes are deckcraft's own (16:9 at 960 × 540 pt, 4:3 scaled).
// Port of deckcraft crates/model/src/defaults.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry

public let wideSlideSize = Size(960.0, 540.0)
public let standardSlideSize = Size(720.0, 540.0)

/// Slide size presets for Design ▸ Slide Size (label, width, height in points).
public let slideSizes: [(label: String, width: Double, height: Double)] = [
    ("Widescreen (16:9)", 960.0, 540.0),
    ("Standard (4:3)", 720.0, 540.0),
    ("On-screen Show (16:10)", 720.0, 450.0),
    ("Letter Paper (8.5x11 in)", 720.0, 540.0),
    ("Ledger Paper (11x17 in)", 960.0, 720.0),
    ("A3 Paper (297x420 mm)", 1008.0, 756.0),
    ("A4 Paper (210x297 mm)", 780.0, 540.0),
    ("B4 (ISO) Paper (250x353 mm)", 852.0, 639.0),
    ("B5 (ISO) Paper (176x250 mm)", 598.0, 448.5),
    ("35mm Slides", 810.0, 540.0),
    ("Overhead", 720.0, 540.0),
    ("Banner", 576.0, 72.0),
    ("Widescreen (13.333x7.5 in)", 960.0, 540.0),
    ("Square (1:1)", 540.0, 540.0),
    ("Portrait (9:16)", 540.0, 960.0),
]

private func ph(_ kind: PhType, _ idx: UInt32) -> Placeholder {
    Placeholder(kind: kind, idx: idx)
}

private func bodyWith(_ anchor: Anchor?, _ autofit: AutoFit?) -> TextBody {
    TextBody(body: BodyProps(anchor: anchor, autofit: autofit))
}

/// Hands out shape ids while a master is built.
private struct Builder {
    var next: UInt32

    mutating func shape(_ name: String, _ kind: PhType, _ idx: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Shape {
        next &+= 1
        var s = Shape.default
        s.id = ShapeId(next)
        s.name = name
        s.xfrm = Xfrm(x, y, w, h)
        s.ph = ph(kind, idx)
        s.text = TextBody()
        return s
    }
}

private func tx1Fill() -> Fill { .solid(.scheme(.tx1)) }

private func level(_ size: Double, _ margin: Double, _ indent: Double, _ before: Double) -> LevelStyle {
    LevelStyle(
        para: ParaProps(
            align: .left, marginLeft: margin, indent: indent, lineSpacing: .pct(0.9), spaceBefore: .pts(before),
            bullet: .char(char: "•"), bulletFont: "Arial"
        ),
        run: RunProps(font: "+mn-lt", size: size, kern: 12.0, fill: tx1Fill())
    )
}

/// Master text styles: title, body (bulleted levels) and other.
public func masterStyles() -> (title: ListStyle, body: ListStyle, other: ListStyle) {
    var title = ListStyle()
    title.set(0, LevelStyle(
        para: ParaProps(align: .left, lineSpacing: .pct(0.9), spaceBefore: .pts(0.0), bullet: .none_),
        run: RunProps(font: "+mj-lt", size: 44.0, kern: 12.0, fill: tx1Fill())
    ))
    var body = ListStyle()
    let sizes: [Double] = [28.0, 24.0, 20.0, 18.0, 18.0, 18.0, 18.0, 18.0, 18.0]
    for (i, sz) in sizes.enumerated() {
        let margin = 18.0 + 36.0 * Double(i)
        body.set(UInt8(i), level(sz, margin, -18.0, i == 0 ? 10.0 : 5.0))
    }
    return (title, body, defaultTextStyle())
}

/// Presentation default text style for free shapes and text boxes (also the masters' other style).
public func defaultTextStyle() -> ListStyle {
    var s = ListStyle()
    for i in UInt8(0) ..< 9 {
        s.set(i, LevelStyle(
            para: ParaProps(align: .left, marginLeft: 36.0 * Double(i)),
            run: RunProps(font: "+mn-lt", size: 18.0, kern: 12.0, fill: tx1Fill())
        ))
    }
    return s
}

private func withPhKind(_ s: Shape, _ kind: PhType) -> Shape {
    var s = s
    s.ph?.kind = kind
    return s
}

/// The master and its eleven standard layouts for a slide size, with ids starting at `firstId`.
/// Returns the master and the next free id.
public func buildMaster(_ size: Size, _ theme: Theme, _ firstId: UInt32) -> (master: Master, nextId: UInt32) {
    let (w, h) = (size.width, size.height)
    let sx = w / 960.0
    let sy = h / 540.0
    func r(_ x: Double, _ y: Double, _ ww: Double, _ hh: Double) -> (Double, Double, Double, Double) {
        (x * sx, y * sy, ww * sx, hh * sy)
    }
    var b = Builder(next: firstId)

    func footers(_ b: inout Builder) -> [Shape] {
        let (x1, y1, w1, h1) = r(60.0, 500.0, 216.0, 28.0)
        let (x2, _, w2, _) = r(318.0, 500.0, 324.0, 28.0)
        let (x3, _, w3, _) = r(684.0, 500.0, 216.0, 28.0)
        var d = b.shape("Date Placeholder", .date, 10, x1, y1, w1, h1)
        var f = b.shape("Footer Placeholder", .footer, 11, x2, y1, w2, h1)
        var n = b.shape("Slide Number Placeholder", .slideNum, 12, x3, y1, w3, h1)
        func small(_ align: Align) -> ListStyle {
            var ls = ListStyle()
            ls.set(0, LevelStyle(
                para: ParaProps(align: align),
                run: RunProps(size: 12.0, fill: .solid(ColorRef.scheme(.tx1).with(.tint(75000))))
            ))
            return ls
        }
        for (i, a) in [Align.left, .center, .right].enumerated() {
            func apply(_ s: inout Shape) {
                s.text?.body.anchor = .middle
                s.text?.listStyle = small(a)
            }
            switch i {
            case 0: apply(&d)
            case 1: apply(&f)
            default: apply(&n)
            }
        }
        n.text?.paragraphs = [Paragraph(runs: [Run(text: "‹#›", props: RunProps(), kind: .field(field: "slidenum"))])]
        return [d, f, n]
    }
    func titleBox(_ b: inout Builder) -> Shape {
        let (x, y, ww, hh) = r(60.0, 29.0, 840.0, 104.0)
        var s = b.shape("Title 1", .title, 0, x, y, ww, hh)
        s.text = bodyWith(.middle, .shrink(fontScale: 1.0, lineReduction: 0.0))
        return s
    }
    func bodyBox(_ b: inout Builder, _ name: String, _ idx: UInt32, _ x: Double, _ y: Double, _ ww: Double, _ hh: Double) -> Shape {
        let (x, y, ww, hh) = r(x, y, ww, hh)
        var s = b.shape(name, .body, idx, x, y, ww, hh)
        s.text = bodyWith(.top, .shrink(fontScale: 1.0, lineReduction: 0.0))
        return s
    }
    func noBullet(_ size: Double, bold: Bool? = nil, fill: Fill? = nil) -> ListStyle {
        var ls = ListStyle()
        ls.set(0, LevelStyle(
            para: ParaProps(marginLeft: 0.0, indent: 0.0, bullet: .none_),
            run: RunProps(size: size, bold: bold, fill: fill)
        ))
        return ls
    }
    func sized(_ size: Double) -> ListStyle {
        var ls = ListStyle()
        ls.set(0, LevelStyle(run: RunProps(size: size)))
        return ls
    }

    // Master placeholders.
    var mshapes = [titleBox(&b), bodyBox(&b, "Text Placeholder 2", 1, 60.0, 144.0, 840.0, 343.0)]
    mshapes += footers(&b)
    for i in mshapes.indices {
        let kind = mshapes[i].phType
        guard let t = mshapes[i].text, t.paragraphs.isEmpty else { continue }
        let prompt = switch kind {
        case .title: "Click to edit Master title style"
        case .body: "Click to edit Master text styles"
        default: ""
        }
        if !prompt.isEmpty { mshapes[i].text?.paragraphs = [Paragraph(prompt)] }
    }

    var layouts: [Layout] = []
    func lay(_ b: inout Builder, _ name: String, _ kind: LayoutType, _ shapes: [Shape]) {
        b.next &+= 1
        layouts.append(Layout(
            id: LayoutId(b.next), name: name, kind: kind, shapes: shapes, background: nil,
            showMasterShapes: true, preserve: true, colorMap: nil, rawExt: nil
        ))
    }

    // Title Slide
    do {
        let (x, y, ww, hh) = r(120.0, 88.0, 720.0, 188.0)
        var t = b.shape("Title 1", .ctrTitle, 0, x, y, ww, hh)
        var ls = ListStyle()
        ls.set(0, LevelStyle(para: ParaProps(align: .center), run: RunProps(size: 60.0)))
        t.text = TextBody(body: BodyProps(anchor: .bottom, autofit: .shrink(fontScale: 1.0, lineReduction: 0.0)), listStyle: ls, paragraphs: [])
        let (x2, y2, ww2, hh2) = r(120.0, 284.0, 720.0, 130.0)
        var st = b.shape("Subtitle 2", .subTitle, 1, x2, y2, ww2, hh2)
        var ls2 = ListStyle()
        ls2.set(0, LevelStyle(
            para: ParaProps(align: .center, marginLeft: 0.0, indent: 0.0, bullet: .none_),
            run: RunProps(size: 24.0)
        ))
        st.text = TextBody(body: BodyProps(anchor: .top, autofit: .shrink(fontScale: 1.0, lineReduction: 0.0)), listStyle: ls2, paragraphs: [])
        var v = [t, st]
        v += footers(&b)
        lay(&b, "Title Slide", .title, v)
    }
    // Title and Content
    do {
        let t = titleBox(&b)
        let c = withPhKind(bodyBox(&b, "Content Placeholder 2", 1, 60.0, 144.0, 840.0, 343.0), .obj)
        var v = [t, c]
        v += footers(&b)
        lay(&b, "Title and Content", .titleAndContent, v)
    }
    // Section Header
    do {
        let (x, y, ww, hh) = r(65.0, 135.0, 830.0, 225.0)
        var t = b.shape("Title 1", .title, 0, x, y, ww, hh)
        t.text = TextBody(body: BodyProps(anchor: .bottom), listStyle: sized(60.0), paragraphs: [])
        var s = bodyBox(&b, "Text Placeholder 2", 1, 65.0, 362.0, 830.0, 118.0)
        s.text?.listStyle = noBullet(24.0, fill: .solid(ColorRef.scheme(.tx1).with(.tint(82000))))
        var v = [t, s]
        v += footers(&b)
        lay(&b, "Section Header", .sectionHeader, v)
    }
    // Two Content
    do {
        let t = titleBox(&b)
        let l = withPhKind(bodyBox(&b, "Content Placeholder 2", 1, 60.0, 144.0, 412.0, 343.0), .obj)
        let rr = withPhKind(bodyBox(&b, "Content Placeholder 3", 2, 488.0, 144.0, 412.0, 343.0), .obj)
        var v = [t, l, rr]
        v += footers(&b)
        lay(&b, "Two Content", .twoContent, v)
    }
    // Comparison
    do {
        let t = titleBox(&b)
        func head(_ b: inout Builder, _ name: String, _ idx: UInt32, _ x: Double) -> Shape {
            let (x, y, ww, hh) = r(x, 133.0, 412.0, 62.0)
            var s = b.shape(name, .body, idx, x, y, ww, hh)
            s.text = TextBody(body: BodyProps(anchor: .bottom), listStyle: noBullet(24.0, bold: true), paragraphs: [])
            return s
        }
        let h1 = head(&b, "Text Placeholder 2", 1, 60.0)
        let c1 = withPhKind(bodyBox(&b, "Content Placeholder 3", 2, 60.0, 198.0, 412.0, 289.0), .obj)
        let h2 = head(&b, "Text Placeholder 4", 3, 488.0)
        let c2 = withPhKind(bodyBox(&b, "Content Placeholder 5", 4, 488.0, 198.0, 412.0, 289.0), .obj)
        var v = [t, h1, c1, h2, c2]
        v += footers(&b)
        lay(&b, "Comparison", .comparison, v)
    }
    // Title Only
    do {
        var v = [titleBox(&b)]
        v += footers(&b)
        lay(&b, "Title Only", .titleOnly, v)
    }
    // Blank
    do {
        let v = footers(&b)
        lay(&b, "Blank", .blank, v)
    }
    // Content with Caption
    do {
        let (x, y, ww, hh) = r(60.0, 36.0, 322.0, 126.0)
        var t = b.shape("Title 1", .title, 0, x, y, ww, hh)
        t.text = TextBody(body: BodyProps(anchor: .bottom), listStyle: sized(32.0), paragraphs: [])
        let c = withPhKind(bodyBox(&b, "Content Placeholder 2", 1, 412.0, 78.0, 488.0, 384.0), .obj)
        var cap = bodyBox(&b, "Text Placeholder 3", 2, 60.0, 162.0, 322.0, 300.0)
        cap.text?.listStyle = noBullet(16.0)
        var v = [t, c, cap]
        v += footers(&b)
        lay(&b, "Content with Caption", .contentWithCaption, v)
    }
    // Picture with Caption
    do {
        let (x, y, ww, hh) = r(60.0, 36.0, 322.0, 126.0)
        var t = b.shape("Title 1", .title, 0, x, y, ww, hh)
        t.text = TextBody(body: BodyProps(anchor: .bottom), listStyle: sized(32.0), paragraphs: [])
        let (px, py, pw, phh) = r(412.0, 78.0, 488.0, 384.0)
        let p = b.shape("Picture Placeholder 2", .picture, 1, px, py, pw, phh)
        var cap = bodyBox(&b, "Text Placeholder 3", 2, 60.0, 162.0, 322.0, 300.0)
        cap.text?.listStyle = noBullet(16.0)
        var v = [t, p, cap]
        v += footers(&b)
        lay(&b, "Picture with Caption", .pictureWithCaption, v)
    }
    // Title and Vertical Text
    do {
        let t = titleBox(&b)
        var c = bodyBox(&b, "Vertical Text Placeholder 2", 1, 60.0, 144.0, 840.0, 343.0)
        c.text?.body.vert = .eaVertical
        c.ph?.vertical = true
        var v = [t, c]
        v += footers(&b)
        lay(&b, "Title and Vertical Text", .titleAndVerticalText, v)
    }
    // Vertical Title and Text
    do {
        let (x, y, ww, hh) = r(687.0, 29.0, 213.0, 458.0)
        var t = b.shape("Vertical Title 1", .title, 0, x, y, ww, hh)
        t.text = TextBody(body: BodyProps(vert: .eaVertical))
        t.ph?.vertical = true
        var c = bodyBox(&b, "Vertical Text Placeholder 2", 1, 60.0, 29.0, 612.0, 458.0)
        c.text?.body.vert = .eaVertical
        c.ph?.vertical = true
        var v = [t, c]
        v += footers(&b)
        lay(&b, "Vertical Title and Text", .verticalTitleAndText, v)
    }

    let styles = masterStyles()
    b.next &+= 1
    let master = Master(
        id: MasterId(b.next), name: theme.name, theme: theme, shapes: mshapes,
        background: .ref(idx: 1001, color: .scheme(.bg1)),
        titleStyle: styles.title, bodyStyle: styles.body, otherStyle: styles.other,
        layouts: layouts, colorMap: [], preserve: false, rawExt: nil
    )
    return (master, b.next &+ 1)
}

/// A new presentation with one title slide.
public func newPresentation(_ theme: Theme?) -> Presentation {
    blankPresentation(wideSlideSize, theme ?? .default, true)
}

public func blankPresentation(_ size: Size, _ theme: Theme, _ titleSlide: Bool) -> Presentation {
    let (master, next) = buildMaster(size, theme, 1)
    let firstLayout = master.layouts.first?.id ?? LayoutId(0)
    var p = Presentation(
        slideSize: size, notesSize: Size(540.0, 720.0), slides: [], masters: [master], notesMaster: nil,
        handoutMaster: nil, sections: [], customShows: [], show: .default, headerFooter: HeaderFooter(),
        props: Properties(), defaultTextStyle: defaultTextStyle(), media: [], firstSlideNumber: 1,
        nextId: Swift.max(next, 256), embeddedFonts: [], tableStyles: [], tags: [], keptParts: [], guides: [],
        rawExt: nil
    )
    if titleSlide {
        // A fresh deck starts at id 256 and this builds a handful of ids, so the slide always fits;
        // should that ever stop holding, the deck arrives without its title slide rather than with a
        // duplicated id.
        if let s = newSlide(&p, firstLayout) { p.slides.append(s) }
    }
    return p
}

/// A slide for `layout` with its placeholders instantiated (empty, inheriting position). nil when the
/// deck has used every object id and cannot grow (#407).
public func newSlide(_ p: inout Presentation, _ layout: LayoutId) -> Slide? {
    guard let raw = p.allocId() else { return nil }
    let id = SlideId(raw)
    var shapes: [Shape] = []
    let layShapes = p.layout(layout)?.layout.shapes ?? []
    for ls in layShapes {
        guard let ph = ls.ph else { continue }
        if ph.kind.isFooterKind { continue }
        guard let sid = p.allocId() else { return nil }
        var s = Shape.default
        s.id = ShapeId(sid)
        s.name = ls.name
        s.ph = ph
        s.text = TextBody()
        shapes.append(s)
    }
    var slide = Slide.default
    slide.id = id
    slide.layout = layout
    slide.shapes = shapes
    return slide
}

/// Layout for a kind in the first master.
public func layoutOfKind(_ p: Presentation, _ kind: LayoutType) -> LayoutId? {
    p.masters.first?.layouts.first { $0.kind == kind }?.id
}
