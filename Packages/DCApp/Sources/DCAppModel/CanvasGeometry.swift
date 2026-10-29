// DCAppModel — the canvas's geometry without a window: where the slide sits at a zoom, the slide-to-view
// mapping, zoom anchoring, the grid's and rulers' steps, page turning by wheel and flick, the resize
// cursor's axis, and the handles drawn round a selection. Port of `Xf`, `layout`, `page_flick`,
// `wheel_slide_target`, `grid_line_step`, `grid_fits`, `ruler_steps` and `resize_cursor` in deckcraft
// `crates/ui-egui/src/canvas.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import CoreGraphics
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender

/// Slide-to-view mapping (`Xf`): view points = `origin` + slide points × `scale`.
public struct CanvasXf: Sendable, Equatable {
    public var origin: CGPoint
    public var scale: Double

    public init(origin: CGPoint, scale: Double) {
        self.origin = origin
        self.scale = scale
    }

    public func toView(_ p: Point) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }

    public func toSlide(_ p: CGPoint) -> Point {
        let s = scale > 0 && scale.isFinite ? scale : 1
        return Point((p.x - origin.x) / s, (p.y - origin.y) / s)
    }

    /// The view rect of a slide-space rect (rotation ignored).
    public func toView(_ r: Rect) -> CGRect {
        let a = toView(Point(r.x0, r.y0)), b = toView(Point(r.x1, r.y1))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(a.y - b.y))
    }
}

/// Where the slide goes in the canvas (`layout`), as a scrolled document: the document's size, the slide's
/// rect in it, and the scale. The document is the viewport while the slide fits; past it the slide keeps a
/// margin all round and the document grows so it can scroll.
public struct CanvasLayout: Sendable, Equatable {
    /// Points kept between the slide and the canvas edge (deckcraft's 28).
    public static let margin = 28.0

    public var documentSize: CGSize
    public var slideRect: CGRect
    public var scale: Double
    /// The scale that fits the slide in the viewport.
    public var fit: Double

    public var xf: CanvasXf { CanvasXf(origin: slideRect.origin, scale: scale) }

    /// How far the document overflows the viewport on each axis (0 when it fits).
    public func overflow(_ viewport: CGSize) -> CGSize {
        CGSize(width: max(documentSize.width - viewport.width, 0), height: max(documentSize.height - viewport.height, 0))
    }

    /// The layout of a slide of `slide` points in a viewport of `viewport` points at `zoom` (nil: fit).
    public static func make(slide: Size, viewport: CGSize, zoom: Double?) -> CanvasLayout {
        // Loaded sizes are repaired; a zero or non-finite side would still make the fit infinite.
        func side(_ v: Double) -> Double { v.isFinite ? max(v, 1) : 1 }
        let (sw, sh) = (side(slide.width), side(slide.height))
        let vw = viewport.width.isFinite ? max(viewport.width, 0) : 0, vh = viewport.height.isFinite ? max(viewport.height, 0) : 0
        let fit = max(min((vw - margin * 2) / sw, (vh - margin * 2) / sh), 0.05)
        // A zoom from outside the editor's own controls (settings, the control channel) is kept in range.
        let scale = zoom.flatMap { $0.isFinite && $0 > 0 ? min(max($0, UiState.zoomRange.lowerBound), UiState.zoomRange.upperBound) : nil } ?? fit
        let w = sw * scale, h = sh * scale
        let doc = CGSize(width: max(vw, w + margin * 2), height: max(vh, h + margin * 2))
        let rect = CGRect(x: (doc.width - w) / 2, y: (doc.height - h) / 2, width: w, height: h)
        return CanvasLayout(documentSize: doc, slideRect: rect, scale: scale, fit: fit)
    }

    /// The scroll origin that puts the slide point under `anchor` (viewport coordinates) at `target` (by default the
    /// same place), going from `old` (scrolled to `scroll`) to this layout; clamped to the document (#106). A zoom
    /// keeping the middle of the view targets the middle of the viewport it ends with, which legacy scroll bars make
    /// smaller than the one it started from.
    public func anchoredScroll(from old: CanvasLayout, scroll: CGPoint, anchor: CGPoint, target: CGPoint? = nil, viewport: CGSize) -> CGPoint {
        let s = old.scale > 0 ? old.scale : 1
        let at = CGPoint(x: (anchor.x + scroll.x - old.slideRect.minX) / s, y: (anchor.y + scroll.y - old.slideRect.minY) / s)
        let to = target ?? anchor
        let raw = CGPoint(x: slideRect.minX + at.x * scale - to.x, y: slideRect.minY + at.y * scale - to.y)
        let over = overflow(viewport)
        func clamp(_ v: CGFloat, _ hi: CGFloat) -> CGFloat { v.isFinite ? min(max(v, 0), hi) : 0 }
        return CGPoint(x: clamp(raw.x, over.width), y: clamp(raw.y, over.height))
    }
}

/// Grid, ruler and page-turn arithmetic.
public enum CanvasMetrics {
    /// View points between grid lines (`grid_line_step`): nil when the grid wouldn't be a finite set of
    /// lines (bad inputs, or so fine a line would land on every pixel).
    public static func gridLineStep(_ spacing: Double, _ scale: Double) -> Double? {
        guard spacing.isFinite, (1 ... 288).contains(spacing), scale.isFinite, scale > 0 else { return nil }
        let step = Double(Float(spacing) * Float(scale))
        return step.isFinite && step >= 1 ? step : nil
    }

    /// A grid denser than this paints a grey slab and costs a frame (`grid_fits`).
    public static func gridFits(_ span: Double, _ step: Double) -> Bool {
        span.isFinite && span > 0 && step >= 1 && span / step <= 800
    }

    /// The ruler's numbered step in points and the ticks per step (`ruler_steps`): quarter inches, or half
    /// centimetres. Any other unit keeps inches, since a tick per point or pixel would be a solid bar.
    public static func rulerSteps(_ unit: Unit) -> (step: Double, ticks: Int) {
        unit == .centimeters ? (unit.pointsPerUnit, 2) : (72, 4)
    }

    /// A trackpad flick or wheel notch that should turn the page (`page_flick`): the stronger axis wins;
    /// content moving left or up (negative) is the next slide. Under 18 points is a resting finger.
    public static func pageFlick(_ dx: Double, _ dy: Double) -> Bool? {
        let along = abs(dx) > abs(dy) ? dx : dy
        return abs(along) > 18 ? along < 0 : nil
    }

    /// Seconds a trackpad page turn waits before the next one (deckcraft's gate).
    public static let flickCooldown = 0.35

    /// One wheel event in lines: `delta` down-positive as AppKit gives it (`scrollingDeltaY` without
    /// precise deltas), with the modifiers deckcraft checks.
    public struct Wheel: Sendable, Equatable {
        public var dx: Double
        public var dy: Double
        public var cmdOrCtrl = false
        public var shift = false
        public init(dx: Double = 0, dy: Double, cmdOrCtrl: Bool = false, shift: Bool = false) {
            self.dx = dx
            self.dy = dy
            self.cmdOrCtrl = cmdOrCtrl
            self.shift = shift
        }
    }

    /// The fraction of a wheel line left over, for one presentation (`wheel_carry`).
    public struct WheelCarry: Sendable, Equatable {
        public var uid: UInt64 = 0
        public var carry: Double = 0
        public init() {}

        /// The carry for presentation `uid`: another presentation starts from zero.
        public mutating func use(_ uid: UInt64) {
            if self.uid != uid {
                self.uid = uid
                carry = 0
            }
        }
    }

    /// Discrete wheel input turns one slide per whole line (`wheel_slide_target`): fractions accumulate in
    /// `carry`, a change of direction drops what was left over, the ends of the deck clamp. nil when no
    /// event counted.
    public static func wheelSlideTarget(_ events: [Wheel], _ current: Int, _ slides: Int, _ carry: inout Double) -> Int? {
        guard slides > 0 else { return nil }
        let last = slides - 1
        var target = min(max(current, 0), last)
        var handled = false
        for e in events where !e.cmdOrCtrl && !e.shift && e.dy.isFinite && abs(e.dy) > 0 && abs(e.dy) >= abs(e.dx) {
            if carry * e.dy < 0 { carry = 0 }
            carry += e.dy
            // The small slack keeps sums such as 10 × 0.1 from falling just short of a line.
            let whole = (abs(carry) + 1e-4).rounded(.down)
            carry -= carry < 0 ? -whole : whole
            if !carry.isFinite { carry = 0 }
            let steps = Int(rustCast: min(whole.isFinite ? whole : 0, Double(slides)))
            target = e.dy < 0 ? min(target + steps, last) : max(target - steps, 0)
            handled = true
        }
        return handled ? target : nil
    }
}

/// Which way a resize handle drags on screen.
public enum ResizeAxis: Sendable, Equatable {
    case horizontal, vertical, nwse, nesw
}

/// Selection handles.
public enum CanvasHandles {
    /// The 8 resize handles (NW, N, NE, E, SE, S, SW, W) and the rotation handle of a box, in slide points
    /// (`box_handles`): the engine's, so what is drawn is what the pointer hits.
    public static func box(_ x: Xfrm) -> (handles: [Point], rotate: Point) {
        let (h, r) = Tools.boxHandles(x)
        return (h, r)
    }

    /// WordArt's yellow handles for `sh`, in shape-local points (`wordart_handles`).
    public static func wordart(_ doc: Presentation, _ sel: Selection, _ sh: Shape, _ w: Double, _ h: Double) -> [Warp.Handle] {
        Tools.wordartHandles(doc, sel, sh, w, h)
    }

    /// The axis resize handle `handle` of box `x` drags along on screen (`resize_cursor`): the handle's
    /// direction from the centre in the shape's own space (corners on the 45° diagonal whatever the
    /// proportions), mapped through its rotation and flips (#745). nil when the box can't say.
    public static func resizeAxis(_ x: Xfrm, _ handle: UInt8) -> ResizeAxis? {
        let (dx, dy): (Double, Double) = switch handle {
        case 0: (-1, -1)
        case 1: (0, -1)
        case 2: (1, -1)
        case 3: (1, 0)
        case 4: (1, 1)
        case 5: (0, 1)
        case 6: (-1, 1)
        default: (-1, 0)
        }
        let c = Point(x.x + x.w / 2, x.y + x.h / 2)
        let a = x.affine
        let p0 = a * c, p1 = a * Point(c.x + dx, c.y + dy)
        let vx = p1.x - p0.x, vy = p1.y - p0.y
        if !vx.isFinite || !vy.isFinite || (abs(vx) < 1e-12 && abs(vy) < 1e-12) { return nil }
        var deg = atan2(vy, vx) * 180 / .pi
        if deg < 0 { deg += 180 }
        if (22.5 ..< 67.5).contains(deg) { return .nwse }
        if (67.5 ..< 112.5).contains(deg) { return .vertical }
        if (112.5 ..< 157.5).contains(deg) { return .nesw }
        return .horizontal
    }

    /// The resize axis for handle `handle` of shape `id` in the active presentation, from the box its
    /// handles are drawn from (a placeholder's inherited one too).
    public static func resizeAxis(_ session: Session, _ id: ShapeId, _ handle: UInt8) -> ResizeAxis? {
        guard let d = session.activeDoc, let sh = d.shape(id) else { return nil }
        return resizeAxis(Cmd.xfrmOf(d.doc, d.selection, sh), handle)
    }
}

/// The pointer's look over the canvas (the cursor match in `pointer`).
public enum CanvasCursor: Sendable, Equatable {
    case arrow, copy, crosshair, iBeam, move, rotate, pointingHand, resizeColumn, resizeRow, resizeLeftRight, resizeUpDown
    case resize(ResizeAxis)

    /// The cursor for the session's tool and what the pointer is over. The Format and Animation Painters
    /// override everything: the point is to show they wait for a click (#830).
    public static func of(_ session: Session) -> CanvasCursor {
        if session.painter != nil || session.animPainter != nil { return .copy }
        let tool = session.tool
        switch tool.kind {
        case .shape: return .crosshair
        case .textBox: return .iBeam
        case .ink: return .crosshair
        case .select: break
        }
        switch tool.hover {
        case .resize(let id, let handle)?: return CanvasHandles.resizeAxis(session, id, handle).map(CanvasCursor.resize) ?? .arrow
        case .rotate?: return .rotate
        case .tableColumn?: return .resizeColumn
        case .tableRow?: return .resizeRow
        case .adjust?, .warp?, .lineEnd?: return .pointingHand
        case .shape(_, let text)?:
            return text && session.activeDoc?.selection.text != nil ? .iBeam : .move
        case .frame?: return .move
        case .handle?, .vertex?, nil: break
        }
        let guide = tool.guideDrag.map(\.0) ?? tool.guideHover
        guard let i = guide else { return .arrow }
        return session.activeDoc?.doc.guides.at(i)?.vertical == true ? .resizeLeftRight : .resizeUpDown
    }
}
