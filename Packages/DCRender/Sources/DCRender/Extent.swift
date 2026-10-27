// DCRender — how far a slide's drawing reaches: lines, shadows, glows and reflections spill past a shape's
// box. Port of deckcraft crates/render/src/extent.rs (`spill`, `slide_extent`, `layout_extent`; MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The editor's pasteboard regions come with
// the app (Wave 5).
import DCCore
import DCGeometry
import DCModel

public enum Extent {
    static let maxSpill = 2000.0

    /// How far a shape's line and effects reach past its `w` × `h` box, in points.
    static func spill(_ line: Line?, _ effects: Effects?, _ w: Double, _ h: Double) -> Double {
        func fin(_ v: Double) -> Double { v.isFinite ? Swift.abs(v) : 0 }
        var s = 0.0
        if let l = line, let f = l.fill, !f.isNone { s = s.rustMax(fin(l.width ?? 0.75) * 3 + 1) }
        if let e = effects {
            let big = fin(w).rustMax(fin(h))
            if let sh = e.outerShadow {
                let grow = (fin(sh.sx).rustMax(fin(sh.sy)) - 1).rustMax(0) * big
                s = s.rustMax(fin(sh.dist) + fin(sh.blur) + grow)
            }
            if let g = e.glow { s = s.rustMax(fin(g.radius)) }
            if let r = e.reflection { s = s.rustMax(fin(h) + fin(r.dist)) }
        }
        return s.rustMin(maxSpill)
    }

    static func shapeBox(_ rctx: Resolve.Ctx, _ s: Shape) -> Rect? {
        if s.hidden { return nil }
        let x = Resolve.xfrm(rctx, s)
        if !x.isFinite { return nil }
        if case .ink(let strokes) = s.kind {
            let pts = strokes.flatMap(\.points).filter { $0.a.isFinite && $0.b.isFinite }
            guard let p0 = pts.first else { return nil }
            let r = pts.dropFirst().reduce(Rect(p0.a, p0.b, p0.a, p0.b)) { $0.unionPoint(Point($1.a, $1.b)) }
            let w = strokes.map(\.width).filter(\.isFinite).reduce(0.0) { $0.rustMax($1) }.rustMin(maxSpill)
            return r.inflate(w, w)
        }
        let d = spill(Resolve.line(rctx, s).line, Resolve.effects(rctx, s).effects, x.w, x.h)
        return x.bounds.inflate(d, d)
    }

    static func unionBoxes(_ rctx: Resolve.Ctx, _ shapes: [Shape], _ into: Rect) -> Rect {
        shapes.compactMap { shapeBox(rctx, $0) }.filter(\.isFinite).reduce(into) { $0.union($1) }
    }

    /// The area slide `index` draws over: the slide, and whatever its shapes and the master and layout
    /// graphics it shows reach beyond it.
    public static func slideExtent(_ pres: Presentation, _ index: Int) -> Rect {
        let page = Rect(0, 0, pres.slideSize.width, pres.slideSize.height)
        guard let slide = pres.slides.at(index), let rctx = Resolve.Ctx.forSlide(pres, slide) else { return page }
        var r = unionBoxes(rctx, slide.shapes, page)
        let (showLayout, showMaster) = Resolve.showMasterShapes(slide, rctx.layout)
        if showMaster {
            r = unionBoxes(Resolve.Ctx.forMaster(pres, rctx.master), rctx.master.shapes.filter { $0.ph == nil }, r)
        }
        if showLayout, let l = rctx.layout {
            r = unionBoxes(Resolve.Ctx.forLayout(pres, rctx.master, l), l.shapes.filter { $0.ph == nil }, r)
        }
        return r
    }

    /// The area a layout (or a master, with `layout` nil) draws over.
    public static func layoutExtent(_ pres: Presentation, _ master: Int, _ layout: Int?) -> Rect {
        let page = Rect(0, 0, pres.slideSize.width, pres.slideSize.height)
        guard let m = pres.masters.at(master) else { return page }
        if let li = layout, let l = m.layouts.at(li) {
            var r = unionBoxes(Resolve.Ctx.forLayout(pres, m, l), l.shapes, page)
            if l.showMasterShapes { r = unionBoxes(Resolve.Ctx.forMaster(pres, m), m.shapes.filter { $0.ph == nil }, r) }
            return r
        }
        return unionBoxes(Resolve.Ctx.forMaster(pres, m), m.shapes, page)
    }
}
