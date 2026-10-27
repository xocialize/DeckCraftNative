// DCApp — the canvas rulers (View › Ruler): inches in quarters or centimetres in halves across the slide,
// and while text is edited the paragraph's indents and tab stops on the top ruler, draggable as in
// PowerPoint — a click on the ruler adds a stop of the kind the corner selector shows, a stop dragged off
// the ruler is removed, a double-click opens the Tabs dialog. Port of `ruler`, `ruler_markers` and
// `tab_glyph` in deckcraft `crates/ui-egui/src/canvas.rs` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Not `NSRulerView`: deckcraft's ruler counts from the slide's edge and spans only the slide, its markers
// are the engine's paragraph (`format.ruler`), and the canvas maps slide points itself; a custom strip
// keeps that exactly.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry

@MainActor
final class CanvasRulerView: NSView {
    weak var canvas: CanvasView?

    /// What is being dragged on the ruler (`RulerDrag`).
    enum Drag: Equatable {
        /// First-line indent (the top triangle).
        case first
        /// Hanging indent (the bottom triangle): moves the left indent, the first line stays put.
        case hanging
        /// Left indent (the box under the hanging triangle): moves both.
        case left
        /// The tab stop that was at this position (points from the text area's left).
        case tab(Double)
    }

    /// The tab kinds the corner selector cycles through (`KINDS`).
    static let kinds: [(String, String)] = [("l", "Left Tab"), ("ctr", "Center Tab"), ("r", "Right Tab"), ("dec", "Decimal Tab")]
    private(set) var kind = 0
    private var drag: Drag?
    private var press: CGPoint?
    private var dragging = false
    private var pointer: CGPoint?

    override var isFlipped: Bool { true }

    /// Only the strips take the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let p = superview.map({ convert(point, from: $0) }) else { return nil }
        return p.y < CanvasStyle.ruler || p.x < CanvasStyle.ruler ? self : nil
    }

    /// The slide mapping in this view's coordinates.
    private var xf: CanvasXf? {
        guard let canvas, let l = canvas.layoutInfo else { return nil }
        let r = canvas.convert(l.slideRect, to: self)
        return CanvasXf(origin: r.origin, scale: l.scale)
    }

    private var slideRect: CGRect? {
        guard let canvas, let l = canvas.layoutInfo else { return nil }
        return canvas.convert(l.slideRect, to: self)
    }

    /// The edited paragraph's ruler (`format.ruler`), when text is edited and isn't rotated.
    struct Info {
        var x: Double
        var width: Double
        var marginLeft: Double
        var indent: Double
        var tabs: [(Double, String)]
    }

    private var info: Info? {
        guard let canvas, canvas.activeState?.selection.text != nil, let s = canvas.model?.session,
              let v = try? s.execute("format.ruler", .emptyObject), v["rotated"]?.asBool == false else { return nil }
        func f(_ k: String) -> Double { v[k]?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        let tabs = v["tabs"]?.asArray?.compactMap { t -> (Double, String)? in
            guard let pos = t["pos"]?.asF64 else { return nil }
            return (pos, t["align"]?.asStr ?? "l")
        } ?? []
        return Info(x: f("x"), width: f("width"), marginLeft: f("marginLeft"), indent: f("indent"), tabs: tabs)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model = canvas?.model else { return }
        let b = bounds, r = CanvasStyle.ruler
        let top = CGRect(x: 0, y: 0, width: b.width, height: r), left = CGRect(x: 0, y: 0, width: r, height: b.height)
        CanvasStyle.rulerFill.setFill()
        top.fill()
        left.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: r - 0.5, width: b.width, height: 0.5).fill()
        CGRect(x: r - 0.5, y: 0, width: 0.5, height: b.height).fill()
        guard let slide = slideRect, let xf else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: r, y: 0, width: b.width - r, height: r))
        ticks(ctx, slide, xf.scale, model.session.prefs.units, horizontal: true)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: r, width: r, height: b.height - r))
        ticks(ctx, slide, xf.scale, model.session.prefs.units, horizontal: false)
        ctx.restoreGState()
        markers(ctx, xf)
    }

    /// Ticks from the slide's edge to its far edge: long at each unit (numbered across the top), shorter at
    /// halves, short between (`ruler`).
    private func ticks(_ ctx: CGContext, _ slide: CGRect, _ scale: Double, _ unit: DCGeometry.Unit, horizontal: Bool) {
        let (step, sub) = CanvasMetrics.rulerSteps(unit)
        let tick = step * scale / Double(sub)
        guard tick.isFinite, tick > 0.5 else { return }
        let r = CanvasStyle.ruler
        ctx.setStrokeColor(CanvasStyle.rulerTick.cgColor)
        ctx.setLineWidth(1)
        var k = 0
        while true {
            let at = (horizontal ? slide.minX : slide.minY) + Double(k) * tick
            if at > (horizontal ? slide.maxX : slide.maxY) || k > 100_000 { break }
            let len: CGFloat = k % sub == 0 ? 8 : k % 2 == 0 ? 5 : 3
            if horizontal {
                ctx.move(to: CGPoint(x: at, y: r - len))
                ctx.addLine(to: CGPoint(x: at, y: r))
            } else {
                ctx.move(to: CGPoint(x: r - len, y: at))
                ctx.addLine(to: CGPoint(x: r, y: at))
            }
            ctx.strokePath()
            if horizontal && k % sub == 0 {
                let s = NSAttributedString(string: "\(k / sub)", attributes: [.font: CanvasStyle.rulerFont, .foregroundColor: CanvasStyle.rulerLabel])
                s.draw(at: CGPoint(x: at + 2, y: 1))
            }
            k += 1
        }
    }

    /// The indents and tab stops of the edited paragraph, and the tab selector in the corner.
    private func markers(_ ctx: CGContext, _ xf: CanvasXf) {
        guard let info else { return }
        let r = CanvasStyle.ruler
        func sx(_ q: Double) -> CGFloat { xf.toView(Point(info.x + q, 0)).x }
        // The text area's span.
        let area = CGRect(x: sx(0), y: 2, width: sx(info.width) - sx(0), height: r - 3)
        ctx.setStrokeColor(CanvasStyle.rulerTick.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(area.insetBy(dx: 0.5, dy: 0.5))
        let live = liveDrag(xf, info)
        var first = info.marginLeft + info.indent, left = info.marginLeft
        switch live {
        case (.first, let q, _)?: first = q
        case (.hanging, let q, _)?: left = q
        case (.left, let q, _)?:
            first = q + info.indent
            left = q
        default: break
        }
        triangle(ctx, sx(first), 1, down: true)
        triangle(ctx, sx(left), 6, down: false)
        let box = CGRect(x: sx(left) - 4, y: 11.5, width: 8, height: r - 12)
        CanvasStyle.rulerFill.setFill()
        box.fill()
        ctx.setStrokeColor(CanvasStyle.rulerMarker.cgColor)
        ctx.stroke(box)
        for (pos, align) in info.tabs {
            var q = pos
            if case (.tab(let from), let at, let off)? = live, abs(from - pos) < 0.5 {
                if off { continue }
                q = at
            }
            tabGlyph(ctx, CGPoint(x: sx(q), y: r - 2), align)
        }
        // The tab selector.
        let corner = CGRect(x: 0, y: 0, width: r, height: r).insetBy(dx: 2, dy: 2)
        ctx.setStrokeColor(CanvasStyle.rulerTick.cgColor)
        ctx.stroke(corner)
        tabGlyph(ctx, CGPoint(x: r / 2 - 1, y: r / 2 + 3), Self.kinds[kind % Self.kinds.count].0)
    }

    private func triangle(_ ctx: CGContext, _ x: CGFloat, _ y0: CGFloat, down: Bool) {
        let (a, b) = down ? (y0, y0 + 5) : (y0 + 5, y0)
        ctx.move(to: CGPoint(x: x - 4, y: a))
        ctx.addLine(to: CGPoint(x: x + 4, y: a))
        ctx.addLine(to: CGPoint(x: x, y: b))
        ctx.closePath()
        ctx.setFillColor(CanvasStyle.rulerFill.cgColor)
        ctx.setStrokeColor(CanvasStyle.rulerMarker.cgColor)
        ctx.setLineWidth(1)
        ctx.drawPath(using: .fillStroke)
    }

    /// A tab stop's mark with its foot at `at` (`tab_glyph`): └ left, ┴ center, ┘ right, ┴ with a dot decimal.
    private func tabGlyph(_ ctx: CGContext, _ at: CGPoint, _ align: String) {
        let (x, y) = (at.x, at.y)
        ctx.setStrokeColor(CanvasStyle.rulerMarker.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: x, y: y - 6))
        ctx.addLine(to: CGPoint(x: x, y: y))
        switch align {
        case "r":
            ctx.move(to: CGPoint(x: x - 5, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y))
        case "ctr", "dec":
            ctx.move(to: CGPoint(x: x - 4, y: y))
            ctx.addLine(to: CGPoint(x: x + 4, y: y))
        default:
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + 5, y: y))
        }
        ctx.strokePath()
        if align == "dec" {
            ctx.setFillColor(CanvasStyle.rulerMarker.cgColor)
            ctx.fillEllipse(in: CGRect(x: x + 2, y: y - 5, width: 2, height: 2))
        }
    }

    // MARK: Dragging

    /// Points from the text area's left under view x, to the half point (`to_q`).
    private func toQ(_ x: CGFloat, _ xf: CanvasXf, _ info: Info) -> Double {
        ((xf.toSlide(CGPoint(x: x, y: 0)).x - info.x).clamped(0, info.width.rustMax(0)) * 2).rounded() / 2
    }

    /// The marker being dragged, where it is, and whether it has left the ruler (a tab being removed).
    private func liveDrag(_ xf: CanvasXf, _ info: Info) -> (Drag, Double, Bool)? {
        guard dragging, let d = drag, let p = pointer else { return nil }
        return (d, toQ(p.x, xf, info), p.y > CanvasStyle.ruler + 20)
    }

    override func mouseDown(with e: NSEvent) {
        let at = convert(e.locationInWindow, from: nil)
        press = at
        dragging = false
        drag = nil
        let r = CanvasStyle.ruler
        if at.x < r && at.y < r {
            // The tab selector: a click cycles the kind a click on the ruler sets.
            kind = (kind + 1) % Self.kinds.count
            toolTip = "\(Self.kinds[kind % Self.kinds.count].1) (click to change)"
            needsDisplay = true
            press = nil
            return
        }
        guard at.y < r, let xf, let info else { return }
        func sx(_ q: Double) -> CGFloat { xf.toView(Point(info.x + q, 0)).x }
        func near(_ q: Double) -> Bool { abs(sx(q) - at.x) <= 5 }
        let y = at.y
        let ml = info.marginLeft, ind = info.indent
        if let t = info.tabs.first(where: { near($0.0) && y >= 8 }) {
            drag = .tab(t.0)
        } else if y < 6 && near(ml + ind) {
            drag = .first
        } else if (6 ..< 11).contains(y) && near(ml) {
            drag = .hanging
        } else if y >= 11 && near(ml) {
            drag = .left
        }
        if e.clickCount == 2, info.tabs.contains(where: { near($0.0) }) || drag == nil {
            // A double-click on a stop opens the Tabs dialog, as in PowerPoint.
            canvas?.model?.run("app.dialog", ["id": "tabs"])
            press = nil
            drag = nil
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let press else { return }
        let at = convert(e.locationInWindow, from: nil)
        pointer = at
        if !dragging && hypot(at.x - press.x, at.y - press.y) > 2 { dragging = true }
        if drag != nil {
            NSCursor.columnResize(directions: .all).set()
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer {
            press = nil
            drag = nil
            dragging = false
            pointer = nil
            needsDisplay = true
        }
        guard press != nil, let model = canvas?.model, let xf, let info else { return }
        let at = convert(e.locationInWindow, from: nil)
        let q = toQ(at.x, xf, info)
        let ml = info.marginLeft, ind = info.indent
        if dragging, let d = drag {
            switch d {
            case .first: model.run("format.paragraph", ["indentFirst": .num(q - ml)])
            case .hanging: model.run("format.paragraph", ["indentLeft": .num(q), "indentFirst": .num(ml + ind - q)])
            case .left: model.run("format.paragraph", ["indentLeft": .num(q)])
            case .tab(let from) where at.y > CanvasStyle.ruler + 20: model.run("format.tabs", ["remove": .num(from)])
            case .tab(let from): model.run("format.tabs", ["move": ["from": .num(from), "to": .num(q)]])
            }
            return
        }
        // A click on bare ruler inside the text area adds a stop.
        func sx(_ q: Double) -> CGFloat { xf.toView(Point(info.x + q, 0)).x }
        guard !dragging, at.y < CanvasStyle.ruler, at.x >= sx(0), at.x <= sx(info.width) else { return }
        if info.tabs.contains(where: { abs(sx($0.0) - at.x) <= 5 }) { return }
        model.run("format.tabs", ["add": ["pos": .num(q), "align": .string(Self.kinds[kind % Self.kinds.count].0)]])
    }

    /// Select a tab kind (tests and the control channel): 0 left, 1 center, 2 right, 3 decimal.
    func setKind(_ k: Int) { kind = ((k % Self.kinds.count) + Self.kinds.count) % Self.kinds.count }
}
