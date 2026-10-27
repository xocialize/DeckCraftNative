// DCApp — what the canvas draws over the slide, in its own layer: gridlines, drawing guides, spelling
// squiggles, the selection with its handles (resize, rotate, adjust, WordArt, line ends, Edit Points), the
// text selection and an input method's underlines, table cells, smart guides, the marquee, drawing previews,
// connection sites, ink, and the Eyedropper's loupe. Port of `overlays`, `draw_grid`, `draw_guides`,
// `draw_preview`, `rotate_handle` in deckcraft `crates/ui-egui/src/canvas.rs`, `paint` in `squiggles.rs` and
// `loupe` in `eyedropper.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender

@MainActor
final class CanvasOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// The overlay never takes the pointer: the canvas under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let st = canvas.document?.state, let l = canvas.layoutInfo, let model = canvas.model,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let xf = l.xf
        let s = model.session
        if st.doc.slides.isEmpty && st.selection.target == .slides {
            drawCentered("Click to add first slide", in: bounds, CanvasStyle.emptyFont, CanvasStyle.secondaryLabel)
            return
        }
        if model.ui.gridlines, let step = CanvasMetrics.gridLineStep(s.prefs.gridSpacing, l.scale) { grid(ctx, l.slideRect, step) }
        let active = canvas.activeState != nil
        if model.ui.guides { guides(ctx, st, xf, l.slideRect, s.tool, active: active) }
        if st.selection.target == .slides {
            let lines = canvas.squiggles.update(st)
            for (a, b) in lines { squiggle(ctx, xf.toView(a), xf.toView(b), xf.scale) }
            if canvas.squiggles.busy {
                // More to check: another pass soon, a few milliseconds at a time.
                DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            }
        }
        selection(ctx, st, xf, s, active: active)
        if active { tools(ctx, st, xf, s) }
        if let e = canvas.eyedropper, let at = canvas.pointerAt, l.slideRect.contains(at), let c = e.color(at: xf.toSlide(at)) {
            loupe(ctx, at, c)
        }
    }

    // MARK: Primitives

    private func stroke(_ ctx: CGContext, _ pts: [CGPoint], _ color: NSColor, width: CGFloat = 1, dash: [CGFloat] = [], closed: Bool = false) {
        guard pts.count > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.addLines(between: pts)
        if closed { ctx.closePath() }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func dot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, fill: NSColor, stroke: NSColor, width: CGFloat = 1) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: rect)
    }

    private func square(_ ctx: CGContext, _ c: CGPoint, _ side: CGFloat, fill: NSColor, stroke: NSColor) {
        let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        ctx.setFillColor(fill.cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect)
    }

    private func fillPolygon(_ ctx: CGContext, _ pts: [CGPoint], _ color: NSColor) {
        guard pts.count > 2 else { return }
        ctx.setFillColor(color.cgColor)
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawCentered(_ text: String, in r: CGRect, _ font: NSFont, _ color: NSColor) {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = s.size()
        s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    /// A label on a small tag, its top-left at `at`.
    private func tag(_ text: String, at: CGPoint) {
        let s = NSAttributedString(string: text, attributes: [.font: CanvasStyle.tagFont, .foregroundColor: CanvasStyle.label])
        let size = s.size()
        let r = CGRect(origin: at, size: size).insetBy(dx: -CanvasStyle.tagInset, dy: -CanvasStyle.tagInset)
        CanvasStyle.tagFill.setFill()
        NSBezierPath(roundedRect: r, xRadius: CanvasStyle.tagRadius, yRadius: CanvasStyle.tagRadius).fill()
        s.draw(at: at)
    }

    // MARK: Grid and guides

    /// Gridlines across the slide (`draw_grid`); none when they would be denser than a pixel slab.
    private func grid(_ ctx: CGContext, _ slide: CGRect, _ step: Double) {
        guard CanvasMetrics.gridFits(slide.width, step), CanvasMetrics.gridFits(slide.height, step) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasStyle.grid.cgColor)
        ctx.setLineWidth(0.5)
        var x = slide.minX + step
        while x < slide.maxX {
            ctx.move(to: CGPoint(x: x, y: slide.minY))
            ctx.addLine(to: CGPoint(x: x, y: slide.maxY))
            x += step
        }
        var y = slide.minY + step
        while y < slide.maxY {
            ctx.move(to: CGPoint(x: slide.minX, y: y))
            ctx.addLine(to: CGPoint(x: slide.maxX, y: y))
            y += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The presentation's drawing guides (`draw_guides`): dashed; the one being dragged at its new place,
    /// labelled with its distance from the slide's centre.
    private func guides(_ ctx: CGContext, _ st: DocState, _ xf: CanvasXf, _ slide: CGRect, _ tool: ToolState, active: Bool) {
        let size = st.doc.slideSize
        let drag = active ? tool.guideDrag : nil
        for (i, g) in st.doc.guides.enumerated() {
            var pos = g.pos
            var hot = active && tool.guideHover == i
            if let (di, p) = drag, di == i {
                pos = p
                hot = true
            }
            let color = hot ? CanvasStyle.drawingGuideActive : CanvasStyle.drawingGuide
            let (a, b): (CGPoint, CGPoint) = g.vertical
                ? (CGPoint(x: xf.toView(Point(pos, 0)).x, y: slide.minY), CGPoint(x: xf.toView(Point(pos, 0)).x, y: slide.maxY))
                : (CGPoint(x: slide.minX, y: xf.toView(Point(0, pos)).y), CGPoint(x: slide.maxX, y: xf.toView(Point(0, pos)).y))
            stroke(ctx, [a, b], color, dash: CanvasStyle.guideDash)
            if let (di, _) = drag, di == i {
                let centre = g.vertical ? size.width / 2 : size.height / 2
                let off = pos - centre
                let side: String = switch (g.vertical, off < 0, off > 0) {
                case (true, true, _): " left of centre"
                case (true, _, true): " right of centre"
                case (false, true, _): " above centre"
                case (false, _, true): " below centre"
                default: " (centre)"
                }
                let label = "\(Int(abs(off).rounded())) pt\(side)"
                tag(label, at: g.vertical ? CGPoint(x: a.x + 6, y: slide.minY + 6) : CGPoint(x: slide.minX + 6, y: a.y + 4))
            }
        }
    }

    // MARK: Spelling

    /// The underline under a flagged word: the Mac's dotted red line rather than deckcraft's wave.
    private func squiggle(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ scale: Double) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len >= 1, len.isFinite else { return }
        let width = min(max(2 * scale, 1.5), 2.5)
        ctx.saveGState()
        ctx.setStrokeColor(CanvasStyle.squiggle.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [0, width * 2])
        // Just under the baseline.
        let n = CGPoint(x: -(b.y - a.y) / len * width, y: (b.x - a.x) / len * width)
        ctx.move(to: CGPoint(x: a.x + n.x, y: a.y + n.y))
        ctx.addLine(to: CGPoint(x: b.x + n.x, y: b.y + n.y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Selection

    private func selection(_ ctx: CGContext, _ st: DocState, _ xf: CanvasXf, _ s: Session, active: Bool) {
        let editing = st.selection.text
        for id in st.selection.shapes {
            guard let sh = st.shape(id) else { continue }
            let x = Cmd.xfrmOf(st.doc, st.selection, sh)
            let a = x.affine
            let corners = [Point(0, 0), Point(x.w, 0), Point(x.w, x.h), Point(0, x.h)].map { xf.toView(a * $0) }
            if sh.isLine {
                let ends = [xf.toView(a * Point(0, 0)), xf.toView(a * Point(x.w, x.h))]
                var glued = [false, false]
                if case .connector(let start, let end) = sh.kind { glued = [start != nil, end != nil] }
                for (q, g) in zip(ends, glued) {
                    // Glued ends are filled with the accent, like attached connector ends.
                    dot(ctx, q, CanvasStyle.handleRadius, fill: g ? CanvasStyle.selection : CanvasStyle.handleFill,
                        stroke: g ? CanvasStyle.handleFill : CanvasStyle.handleStroke)
                }
                continue
            }
            let editingThis = editing.map { $0.shape == id && !$0.notes } ?? false
            if active, s.tool.editingPoints(st) == sh.id {
                // Edit Points: the outline's vertices are the handles; no box.
                if let (path, index) = s.tool.editVertex, let (hin, hout, v) = PointsCommands.slideHandles(st.doc, st.selection, sh, path, index) {
                    for h in [hin, hout].compactMap({ $0 }) {
                        stroke(ctx, [xf.toView(v), xf.toView(h)], CanvasStyle.selection)
                        square(ctx, xf.toView(h), CanvasStyle.controlSide, fill: CanvasStyle.handleFill, stroke: CanvasStyle.selection)
                    }
                }
                for q in PointsCommands.slideVertices(st.doc, st.selection, sh).joined() {
                    square(ctx, xf.toView(q), CanvasStyle.vertexSide, fill: .black, stroke: .white)
                }
                continue
            }
            stroke(ctx, corners, CanvasStyle.selection, dash: editingThis ? CanvasStyle.editDash : [], closed: true)
            if sh.locked && !editingThis {
                // Locked: greyed handles that don't respond, no rotate or adjust handles.
                for h in CanvasHandles.box(x).handles {
                    dot(ctx, xf.toView(h), CanvasStyle.lockedHandleRadius, fill: CanvasStyle.lockedHandle, stroke: CanvasStyle.handleFill)
                }
                continue
            }
            if st.selection.shapes.count == 1 || !editingThis {
                let (hs, rot) = CanvasHandles.box(x)
                if !editingThis, let top = hs.at(1) {
                    let r = xf.toView(rot)
                    stroke(ctx, [xf.toView(top), r], CanvasStyle.selection)
                    rotateHandle(ctx, r)
                }
                for h in hs { dot(ctx, xf.toView(h), CanvasStyle.handleRadius, fill: CanvasStyle.handleFill, stroke: CanvasStyle.handleStroke) }
                for hd in shapeGeometry(sh, x.w, x.h).handles {
                    dot(ctx, xf.toView(a * hd.pos), CanvasStyle.handleRadius, fill: CanvasStyle.adjustFill, stroke: CanvasStyle.adjustStroke)
                }
                for hd in CanvasHandles.wordart(st.doc, st.selection, sh, x.w, x.h) {
                    dot(ctx, xf.toView(a * hd.pos), CanvasStyle.handleRadius, fill: CanvasStyle.adjustFill, stroke: CanvasStyle.adjustStroke)
                }
            }
        }
        // The text selection and an input method's composition, in a shape or a table cell.
        if let t = editing, !t.notes {
            for quad in CanvasTextInput.selectionQuads(st, t) { fillPolygon(ctx, quad.map(xf.toView), CanvasStyle.textSelection) }
            for (a, b, thick) in TextCommands.compositionUnderlines(st) {
                stroke(ctx, [xf.toView(a), xf.toView(b)], CanvasStyle.caret, width: thick ? 2 : 1)
            }
            // A caret on rotated text can't be the system's upright one: drawn here.
            if active, !t.isRange, canvas?.overlayDrawsCaret == true, canvas?.window?.firstResponder === canvas,
               let (top, bottom) = TextCommands.caretLine(st, t) {
                let color = TextCommands.caretColor(st, t).map { CanvasViewController.color($0.r, $0.g, $0.b, $0.a) } ?? CanvasStyle.caret
                stroke(ctx, [xf.toView(top), xf.toView(bottom)], color, width: 1.5)
            }
            // Table cell editing: the cell outlined (merged cells as drawn).
            if let cell = t.cell, let sh = st.shape(t.shape), let f = TableCommands.tableFrame(st, sh), let cr = f.cellRect(cell.para, cell.char) {
                let pts = [Point(cr.x0, cr.y0), Point(cr.x1, cr.y0), Point(cr.x1, cr.y1), Point(cr.x0, cr.y1)].map { xf.toView(f.affine * $0) }
                stroke(ctx, pts, CanvasStyle.selection, width: 2, closed: true)
            }
        }
        // Selected table cells shaded, each merged cell as it is drawn.
        if let cells = st.selection.cells, st.selection.text == nil, let sh = st.shape(cells.table), case .table(let table) = sh.kind,
           let f = TableCommands.tableFrame(st, sh) {
            let range = TableCommands.selectedRange(cells, cells.table, table)
            for (r, c, cr) in f.cells where range != nil && TableCommands.inRange(range, r, c) {
                let pts = [Point(cr.x0, cr.y0), Point(cr.x1, cr.y0), Point(cr.x1, cr.y1), Point(cr.x0, cr.y1)].map { xf.toView(f.affine * $0) }
                fillPolygon(ctx, pts, CanvasStyle.textSelection)
            }
        }
    }

    /// The rotation handle: a dot with a circular arrow (`rotate_handle`).
    private func rotateHandle(_ ctx: CGContext, _ c: CGPoint) {
        ctx.setFillColor(CanvasStyle.handleFill.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - CanvasStyle.rotateHandleRadius, y: c.y - CanvasStyle.rotateHandleRadius,
                                   width: CanvasStyle.rotateHandleRadius * 2, height: CanvasStyle.rotateHandleRadius * 2))
        let pts = (0 ... 20).map { i -> CGPoint in
            let a = -0.4 + Double(i) / 20 * 5.2
            return CGPoint(x: c.x + 4 * cos(a), y: c.y + 4 * sin(a))
        }
        stroke(ctx, pts, CanvasStyle.handleStroke, width: 1.3)
    }

    // MARK: Tools

    /// Smart guides, the marquee, drawing previews, freeforms, connection sites and ink.
    private func tools(_ ctx: CGContext, _ st: DocState, _ xf: CanvasXf, _ s: Session) {
        let tool = s.tool
        for g in tool.guides {
            let (a, b) = g.vertical ? (Point(g.pos, g.from), Point(g.pos, g.to)) : (Point(g.from, g.pos), Point(g.to, g.pos))
            stroke(ctx, [xf.toView(a), xf.toView(b)], CanvasStyle.smartGuide, dash: CanvasStyle.smartDash)
        }
        if let m = tool.marquee {
            let r = xf.toView(m)
            ctx.setFillColor(CanvasStyle.marqueeFill.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(CanvasStyle.marqueeStroke.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
        if let pv = tool.preview { preview(ctx, xf, pv, tool.kind) }
        // A freeform being drawn.
        let path = tool.pathPreview
        if path.count > 1 {
            var pts = path
            if tool.pathSmooth && path.count > 2 {
                pts = []
                presetFlatten(parsePath(ShapeCommands.freeformPath(path, false, true))) { el in
                    if let p = el.endPoint { pts.append(p) }
                }
            }
            stroke(ctx, pts.map(xf.toView), CanvasStyle.selection, width: 1.5)
            if tool.pathClosing, let s0 = path.first { dot(ctx, xf.toView(s0), CanvasStyle.glueRadius, fill: CanvasStyle.selection, stroke: CanvasStyle.handleFill, width: 1.5) }
        }
        // Connection sites of the shape under a connector end, and the one it would glue to.
        for q in tool.sites { dot(ctx, xf.toView(q), CanvasStyle.siteRadius, fill: CanvasStyle.handleFill, stroke: CanvasStyle.handleStroke) }
        if let g = tool.glue { dot(ctx, xf.toView(g), CanvasStyle.glueRadius, fill: CanvasStyle.selection, stroke: CanvasStyle.handleFill, width: 1.5) }
        if tool.inkPreview.count > 1, case .ink(let mode, let c, let width) = tool.kind {
            ink(ctx, xf, tool.inkPreview, mode, CanvasViewController.color(c.r, c.g, c.b, c.a), width)
        }
    }

    /// What a drawing tool will make (`draw_preview`): a table's border or outline, a line, or the preset's
    /// outline.
    private func preview(_ ctx: CGContext, _ xf: CanvasXf, _ x: Xfrm, _ kind: ToolKind) {
        let preset: String = if case .shape(let p) = kind { p } else { "rect" }
        let a = xf.toView(Point(x.x, x.y)), b = xf.toView(Point(x.x + x.w, x.y + x.h))
        if preset == Tools.drawTable {
            if x.w < 0.5 || x.h < 0.5 {
                stroke(ctx, [a, b], CanvasStyle.selection, width: 1.5)
            } else {
                ctx.setStrokeColor(CanvasStyle.selection.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            }
            return
        }
        if Preset.isLineLike(preset) {
            let m = x.affine
            stroke(ctx, [xf.toView(m * Point(0, 0)), xf.toView(m * Point(x.w, x.h))], CanvasStyle.selection, width: 1.5)
            return
        }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard r.width >= 1, r.height >= 1 else { return }
        guard let geo = Preset.build(preset, r.width, r.height, []) else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        let path = CGMutablePath()
        for sub in geo.paths {
            for el in sub.path.elements {
                switch el {
                case .moveTo(let p): path.move(to: CGPoint(x: p.x, y: p.y))
                case .lineTo(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
                case .quadTo(let c, let p): path.addQuadCurve(to: CGPoint(x: p.x, y: p.y), control: CGPoint(x: c.x, y: c.y))
                case .curveTo(let c1, let c2, let p):
                    path.addCurve(to: CGPoint(x: p.x, y: p.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
                case .closePath: path.closeSubpath()
                }
            }
        }
        ctx.addPath(path)
        ctx.setFillColor(CanvasStyle.marqueeFill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CanvasStyle.selection.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Ink being drawn: one line for the highlighter and old pressure-less ink, else a width per segment.
    private func ink(_ ctx: CGContext, _ xf: CanvasXf, _ pts: [(Double, Double, Float)], _ mode: String, _ color: NSColor, _ width: Double) {
        let triples = pts.map { Triple($0.0, $0.1, $0.2) }
        let legacy = inkPressureIsLegacy(triples)
        var c = color
        if mode == "highlighter" { c = c.withAlphaComponent(c.alphaComponent * 0.45) }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if legacy || mode == "highlighter" {
            stroke(ctx, pts.map { xf.toView(Point($0.0, $0.1)) }, c, width: max(width * xf.scale, 1))
        } else {
            for i in 1 ..< pts.count {
                let q0 = pts[i - 1], q1 = pts[i]
                let w = (inkSampleWidth(width, q0.2, legacy) + inkSampleWidth(width, q1.2, legacy)) * 0.5 * xf.scale
                stroke(ctx, [xf.toView(Point(q0.0, q0.1)), xf.toView(Point(q1.0, q1.1))], c, width: max(w, 1))
            }
        }
        ctx.restoreGState()
    }

    // MARK: Eyedropper

    /// The colour under the pointer, beside it with its hex (`loupe`).
    private func loupe(_ ctx: CGContext, _ at: CGPoint, _ c: [UInt8]) {
        guard c.count >= 3 else { return }
        let swatch = CGRect(x: at.x + 18, y: at.y + 18, width: 64, height: 26)
        let color = NSColor(srgbRed: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: 1)
        ctx.setFillColor(color.cgColor)
        ctx.fill(swatch)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(swatch.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(swatch.insetBy(dx: -2.5, dy: -2.5))
        tag("#" + CanvasEyedropper.hex(c), at: CGPoint(x: swatch.minX + 4, y: swatch.maxY + 6))
    }
}
