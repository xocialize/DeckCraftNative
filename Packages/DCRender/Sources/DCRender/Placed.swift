// DCRender — laid-out text and click areas of a slide, in slide coordinates, without drawing: for the PDF
// text layer and links, for text extraction and for the slide show's click targets. Port of deckcraft
// crates/render/src/placed.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText

/// One shape's text as drawn on the slide.
public struct PlacedText {
    public var layout: TextLayout
    /// Shape-local → slide points (text rotation included, flips not: see `textTransform`).
    public var transform: Affine
    public var body: TextBody
}

/// A clickable area: a shape action or a text hyperlink.
public struct PlacedLink {
    /// Slide-space bounding box.
    public var rect: Rect
    public var link: Hyperlink
    /// The shape that owns the link (for a text hyperlink, the shape holding the text).
    public var shape: ShapeId
    /// A hyperlink on text, not the shape's own action.
    public var text: Bool
}

/// A shape of the slide itself (not of its layout or master) with its slide-space bounding box: what a
/// click in a slide show lands on.
public struct PlacedShape {
    public var id: ShapeId
    /// Index into `Placed.shapes` of the group this shape is in.
    public var parent: Int?
    public var isGroup: Bool
    /// Slide-space bounding box.
    public var rect: Rect
    /// The shape's own action (Insert ▸ Action), not its text hyperlinks.
    public var link: Hyperlink?
}

public struct Placed {
    public var texts: [PlacedText] = []
    public var links: [PlacedLink] = []
    /// The slide's own shapes in drawing order (back to front; a group before its children). Hidden shapes
    /// are left out.
    public var shapes: [PlacedShape] = []
}

/// Text and links of slide `index` (master and layout graphics first, as rendered).
public func placeSlide(_ pres: Presentation, _ index: Int) -> Placed {
    var out = Placed()
    guard let slide = pres.slides.at(index), let rctx = Resolve.Ctx.forSlide(pres, slide) else { return out }
    let fields = SlideFields(pres.slideNumber(index), pres.headerFooter.footerText, RenderOpts())
    let (showLayout, showMaster) = Resolve.showMasterShapes(slide, rctx.layout)
    if showMaster {
        let mctx = Resolve.Ctx.forMaster(pres, rctx.master)
        for s in rctx.master.shapes where s.ph == nil { place(&out, mctx, fields, s, .identity, 0, nil, false) }
    }
    if showLayout, let l = rctx.layout {
        let lctx = Resolve.Ctx.forLayout(pres, rctx.master, l)
        for s in l.shapes where s.ph == nil { place(&out, lctx, fields, s, .identity, 0, nil, false) }
    }
    for s in slide.shapes { place(&out, rctx, fields, s, .identity, 0, nil, true) }
    return out
}

/// The header, date, footer and page-number text of a notes or handout `master`, laid out in its
/// placeholders (master points) with their own formatting and wrapping, for page `n`. The page number
/// placeholder shows `n` in its first run's formatting.
public func placeMasterTexts(_ pres: Presentation, _ master: Master, _ n: Int) -> [PlacedText] {
    var out = Placed()
    let ctx = Resolve.Ctx.forMaster(pres, master)
    let fields = SlideFields(UInt32(rustCast: Double(n)), pres.headerFooter.footerText, RenderOpts())
    for var s in master.shapes {
        guard let kind = s.phType, [PhType.header, .date, .footer, .slideNum].contains(kind) else { continue }
        if kind == .slideNum {
            var body = s.text ?? TextBody.default
            let first = body.paragraphs.first
            let props = first.map { $0.runs.first?.props ?? $0.endProps } ?? RunProps.default
            var para = first ?? Paragraph.default
            para.runs = [Run.with(String(n), props)]
            body.paragraphs = [para]
            s.text = body
        }
        place(&out, ctx, fields, s, .identity, 0, nil, false)
    }
    return out.texts
}

/// `group` is the index in `out.shapes` of the enclosing group; `own` is true for the slide's own shapes
/// (recorded in `out.shapes`), false for the layout's and master's.
private func place(_ out: inout Placed, _ rctx: Resolve.Ctx, _ fields: SlideFields, _ s: Shape, _ parent: Affine, _ depth: Int, _ group: Int?, _ own: Bool) {
    if depth > 32 || s.hidden { return }
    let x = Resolve.xfrm(rctx, s)
    if !x.isFinite { return }
    let m = parent * x.affine
    let rect = m.transformRectBBox(Rect(0, 0, x.w, x.h))
    if let link = s.click { out.links.append(PlacedLink(rect: rect, link: link, shape: s.id, text: false)) }
    var me: Int?
    if own {
        var isGroup = false
        if case .group = s.kind { isGroup = true }
        out.shapes.append(PlacedShape(id: s.id, parent: group, isGroup: isGroup, rect: rect, link: s.click))
        me = out.shapes.count - 1
    }
    switch s.kind {
    case .group(let children, let child):
        let ch = Rect(child.x, child.y, child.x + child.w, child.y + child.h)
        let gm = parent * groupChildAffine(x, ch)
        for c in children { place(&out, rctx, fields, c, gm, depth + 1, me, own) }
    case .table(let t):
        // Cell text, laid out exactly as the table draws it.
        for (r, c, cellRect) in TableRender.cellRects(t, TableRender.rowHeights(rctx, t, fields)) {
            guard let cell = t.cell(r, c), !cell.text.isEmpty else { continue }
            let body = TableRender.cellBody(rctx, t, r, c, cell)
            let tmp = Shape.tableCell(body)
            placeText(&out, rctx, fields, s.id, tmp, body, cellRect, m)
        }
    case .chart, .ink:
        break
    default:
        guard let body = s.text, !body.isEmpty else { return }
        let tr = shapeGeometry(s, x.w, x.h).textRect
        placeText(&out, rctx, fields, s.id, s, body, tr, m)
    }
}

/// Lay out `body` in text rect `tr` of shape `s` (shape-local → slide `m`) and record it and its hyperlinks.
private func placeText(_ out: inout Placed, _ rctx: Resolve.Ctx, _ fields: SlideFields, _ owner: ShapeId, _ s: Shape, _ body: TextBody, _ tr: Rect, _ m0: Affine) {
    let layout = TextLayoutEngine.layout(rctx, s, body, TextOpts(rect: tr, fields: fields))
    let m = textTransform(m0, tr, layout.rotation)
    // Text hyperlinks: one box per line segment of a linked run.
    for run in layout.runs where run.link && !run.glyphs.isEmpty {
        guard let link = runLink(body, run.para, run.chars.start),
              let line = layout.lines.first(where: { $0.para == run.para && $0.start <= run.chars.start && run.chars.start <= $0.end }) else { continue }
        // The run's visual extent (right-to-left runs run from right to left).
        let first = run.glyphs.first?.x ?? 0
        let (x0, x1) = line.span(run.chars.start, run.chars.end) ?? (first, first)
        out.links.append(PlacedLink(rect: m.transformRectBBox(Rect(x0, line.top, x1, line.bottom)), link: link, shape: owner, text: true))
    }
    out.texts.append(PlacedText(layout: layout, transform: m, body: body))
}

/// The hyperlink of the model run containing character `at` of paragraph `para`.
private func runLink(_ body: TextBody, _ para: Int, _ at: Int) -> Hyperlink? {
    guard let p = body.paragraphs.at(para) else { return nil }
    var pos = 0
    for r in p.runs {
        let n = r.charLen
        if at < pos + Swift.max(n, 1) { return r.props.link }
        pos += n
    }
    return nil
}

/// The outlines of shape `s`'s text as drawn, in the space `m` maps shape-local points to, and the colour
/// of its first visible run: what Merge Shapes turns letters into. Empty when the shape has no text.
public func textOutline(_ rctx: Resolve.Ctx, _ s: Shape, _ m0: Affine) -> (BezPath, Rgba?) {
    var out = BezPath()
    guard let body = s.text, !body.isEmpty else { return (out, nil) }
    let x = Resolve.xfrm(rctx, s)
    let tr = shapeGeometry(s, x.w, x.h).textRect
    let layout = TextLayoutEngine.layout(rctx, s, body, TextOpts(rect: tr))
    let m = textTransform(m0, tr, layout.rotation)
    var first: Rgba?
    for run in layout.runs {
        let k = run.size / run.face.upem.rustMax(1)
        let skew = run.fakeItalic ? Affine(1, 0, -0.2, 1, 0, 0) : Affine.identity
        for g in run.glyphs {
            let path = glyphPath(run.face, g.gid)
            if path.isEmpty { continue }
            if first == nil && run.color.a > 0 { first = run.color }
            out.extend(transformed(path, m * glyphPlace(run, g.gid, g.x, g.y) * skew * Affine.scale(k)).elements)
        }
    }
    return (out, first)
}
