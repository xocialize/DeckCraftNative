// DCEngine — the pointer's geometry: resizing a box by a handle (rotation and flips kept, dragging past the
// opposite edge flips), 45° constraints, smart guides and grid snapping for moves and resizes, and WordArt
// warp adjusts. Port of deckcraft crates/engine/src/tools.rs (`resize_box`, `constrain_45`, `contains_rect`,
// `snap_rect`, `snap_edges`, `snap_resize`, `set_warp_adj`; MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel
import Darwin

extension Tools {
    /// New box when dragging resize handle `h` by `d` (slide space), keeping the shape's rotation
    /// (`resize_box`). `keepAspect` keeps the width:height ratio on corner handles, `fromCenter` grows both
    /// sides.
    public static func resizeBox(_ o: Xfrm, _ h: UInt8, _ d: Vec2, _ keepAspect: Bool, _ fromCenter: Bool) -> Xfrm {
        // Work in the shape's rotated frame.
        let rot = Affine.rotate(-o.rot.toRadians)
        let ld = rot * Point(d.x, d.y)
        var (l, t, r, b) = (0.0, 0.0, o.w, o.h)
        let (sx, sy) = (o.flipH ? -1.0 : 1.0, o.flipV ? -1.0 : 1.0)
        let (dx, dy) = (ld.x * sx, ld.y * sy)
        switch h {
        case 0:
            l += dx
            t += dy
        case 1: t += dy
        case 2:
            r += dx
            t += dy
        case 3: r += dx
        case 4:
            r += dx
            b += dy
        case 5: b += dy
        case 6:
            l += dx
            b += dy
        default: l += dx
        }
        if fromCenter {
            // Symmetric growth about the centre.
            let gw: Double = switch h {
            case 0, 6, 7: -dx
            case 2 ... 4: dx
            default: 0
            }
            let gh: Double = switch h {
            case 0 ... 2: -dy
            case 4 ... 6: dy
            default: 0
            }
            l = -gw
            r = o.w + gw
            t = -gh
            b = o.h + gh
        }
        var w = r - l
        var hh = b - t
        if keepAspect && o.w > 1e-9 && o.h > 1e-9 && ![1, 3, 5, 7].contains(h) {
            let ar = o.w / o.h
            if abs(w / ar) > abs(hh) {
                hh = abs(w) / ar * hh.rustSignum.rustMax(hh == 0 ? 1.0 : hh.rustSignum)
            } else {
                w = abs(hh) * ar * w.rustSignum.rustMax(w == 0 ? 1.0 : w.rustSignum)
            }
            if h == 0 || h == 6 { l = r - w } else { r = l + w }
            if h == 0 || h == 2 { t = b - hh } else { b = t + hh }
            if fromCenter {
                let (cx, cy) = (o.w / 2.0, o.h / 2.0)
                l = cx - w / 2.0
                r = cx + w / 2.0
                t = cy - hh / 2.0
                b = cy + hh / 2.0
            }
        }
        // Dragging past the opposite edge flips.
        var (fh, fv) = (o.flipH, o.flipV)
        if r < l {
            swap(&l, &r)
            fh.toggle()
        }
        if b < t {
            swap(&t, &b)
            fv.toggle()
        }
        let (nw, nh) = (r - l, b - t)
        // New centre in slide space: old centre + rotated offset of the local centre change.
        let localC = Point((l + r) / 2.0 * sx + (sx < 0.0 ? o.w : 0.0), (t + b) / 2.0 * sy + (sy < 0.0 ? o.h : 0.0))
        let c = o.affine * Point(o.flipH ? o.w - localC.x : localC.x, o.flipV ? o.h - localC.y : localC.y)
        return Xfrm(x: c.x - nw / 2.0, y: c.y - nh / 2.0, w: nw, h: nh, rot: o.rot, flipH: fh, flipV: fv)
    }

    /// `b` moved to the nearest 45° direction from `a`, at the same distance (`constrain_45`).
    static func constrain45(_ a: Point, _ b: Point) -> Point {
        let d = b - a
        let ang = Darwin.atan2(d.y, d.x)
        let step = Double.pi / 4.0
        let snapped = (ang / step).rounded() * step
        let len = d.hypot
        // One sincos call, as Rust's release build computes the pair (see DCGeometry's `sinCos`).
        let sc = __sincos_stret(snapped)
        return a + Vec2(sc.__cosval, sc.__sinval) * len
    }

    /// Whether `inner` lies inside `outer`, edges included (`contains_rect`).
    static func containsRect(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.x0 >= outer.x0 && inner.y0 >= outer.y0 && inner.x1 <= outer.x1 && inner.y1 <= outer.y1
    }

    /// kurbo's `Rect + Vec2`: the rectangle moved by `v`.
    static func offset(_ r: Rect, _ v: Vec2) -> Rect { Rect(r.x0 + v.x, r.y0 + v.y, r.x1 + v.x, r.y1 + v.y) }

    /// Write one warp adjust, keeping the others from `base` (empty: the preset defaults) (`set_warp_adj`).
    static func setWarpAdj(_ sh: inout Shape, _ name: String, _ base: [Double], _ index: Int, _ value: Double) {
        guard var text = sh.text else { return }
        if !value.isFinite || index > 7 || index < 0 { return }
        let defaults = Warp.adjustDefaults(name)
        let n = min(max(defaults.count, index + 1), 8)
        if n == 0 { return }
        var adj: [Double] = []
        adj.reserveCapacity(n)
        for i in 0 ..< n {
            adj.append(i == index ? value : (base.at(i).flatMap { $0.isFinite ? $0 : nil } ?? defaults.at(i) ?? 0.0))
        }
        text.body.warp = name
        text.body.warpAdj = adj
        sh.text = text
    }
}

extension Session {
    /// Smart guides: snap `r`'s edges and centres to the slide, drawing guides and other shapes. Returns the
    /// offset to apply and the guides to draw (`snap_rect`).
    func snapRect(_ r: Rect, _ exclude: [ShapeId], _ tol: Double, _ enabled: Bool) -> (Vec2, [Guide]) {
        snapEdges(r, exclude, tol, enabled, [true, true, true], [true, true, true])
    }

    /// `snapRect` looking only at some of `r`'s edges: `xsOn` is left, centre, right and `ysOn` top, centre,
    /// bottom. Resizing passes just the edges being dragged, so a fixed edge that already sits on a line
    /// (distance 0) doesn't win and leave the dragged edge unsnapped (`snap_edges`).
    func snapEdges(_ r: Rect, _ exclude: [ShapeId], _ tol: Double, _ enabled: Bool, _ xsOn: [Bool], _ ysOn: [Bool]) -> (Vec2, [Guide]) {
        guard let st = activeDoc else { return (.zero, []) }
        if !enabled || !prefs.smartGuides { return (.zero, []) }
        let size = st.doc.slideSize
        var xs: [(Double, Rect)] = [
            (0.0, Rect(0, 0, 0, size.height)),
            (size.width / 2.0, Rect(size.width / 2.0, 0, size.width / 2.0, size.height)),
            (size.width, Rect(size.width, 0, size.width, size.height)),
        ]
        var ys: [(Double, Rect)] = [
            (0.0, Rect(0, 0, size.width, 0)),
            (size.height / 2.0, Rect(0, size.height / 2.0, size.width, size.height / 2.0)),
            (size.height, Rect(0, size.height, size.width, size.height)),
        ]
        if tool.guidesVisible {
            for g in st.doc.guides {
                if g.vertical {
                    xs.append((g.pos, Rect(g.pos, 0, g.pos, size.height)))
                } else {
                    ys.append((g.pos, Rect(0, g.pos, size.width, g.pos)))
                }
            }
        }
        for sh in st.shapes where !exclude.contains(sh.id) && !sh.hidden {
            let b = Cmd.xfrmOf(st.doc, st.selection, sh).bounds
            for x in [b.x0, b.center.x, b.x1] { xs.append((x, b)) }
            for y in [b.y0, b.center.y, b.y1] { ys.append((y, b)) }
        }
        var bestX: (Double, Double, Rect)?
        for (edge, on) in zip([r.x0, r.center.x, r.x1], xsOn) where on {
            for (x, b) in xs {
                let d = x - edge
                if abs(d) <= tol && (bestX.map { abs(d) < abs($0.0) } ?? true) { bestX = (d, x, b) }
            }
        }
        var bestY: (Double, Double, Rect)?
        for (edge, on) in zip([r.y0, r.center.y, r.y1], ysOn) where on {
            for (y, b) in ys {
                let d = y - edge
                if abs(d) <= tol && (bestY.map { abs(d) < abs($0.0) } ?? true) { bestY = (d, y, b) }
            }
        }
        var off = Vec2.zero
        var guides: [Guide] = []
        if let (d, x, b) = bestX {
            off = Vec2(d, off.y)
            let rr = Tools.offset(r, Vec2(d, 0))
            guides.append(Guide(vertical: true, pos: x, from: b.y0.rustMin(rr.y0), to: b.y1.rustMax(rr.y1)))
        } else if prefs.snapToGrid && xsOn.contains(true) {
            let at = xsOn.at(0) == true ? r.x0 : xsOn.at(2) == true ? r.x1 : r.center.x
            off = Vec2(snap(at, prefs.gridSpacing) - at, off.y)
        }
        if let (d, y, b) = bestY {
            off = Vec2(off.x, d)
            let rr = Tools.offset(r, Vec2(0, d))
            guides.append(Guide(vertical: false, pos: y, from: b.x0.rustMin(rr.x0), to: b.x1.rustMax(rr.x1)))
        } else if prefs.snapToGrid && ysOn.contains(true) {
            let at = ysOn.at(0) == true ? r.y0 : ysOn.at(2) == true ? r.y1 : r.center.y
            off = Vec2(off.x, snap(at, prefs.gridSpacing) - at)
        }
        return (off, guides)
    }

    /// Snap the edges that resize handle `handle` drags in the resized box `x` to the smart guides
    /// (`snap_resize`).
    func snapResize(_ x: Xfrm, _ handle: UInt8, _ id: ShapeId, _ tol: Double) -> Xfrm {
        if x.rot != 0 {
            tool.guides.removeAll()
            return x
        }
        let r = x.rect
        // Only the dragged edges move, so only they look for a line to snap to. The handles sit in the box's
        // unflipped frame: in a flipped box, also one that a drag past the opposite edge just flipped, the
        // dragged handle is on the other side.
        let (left, right) = (handle == 0 || handle == 6 || handle == 7, (2 ... 4).contains(handle))
        let (top, bottom) = ((0 ... 2).contains(handle), (4 ... 6).contains(handle))
        let (movesLeft, movesRight) = x.flipH ? (right, left) : (left, right)
        let (movesTop, movesBottom) = x.flipV ? (bottom, top) : (top, bottom)
        let (off, guides) = snapEdges(r, [id], tol * 1.5, true, [movesLeft, false, movesRight], [movesTop, false, movesBottom])
        var nx = x
        if movesLeft {
            nx.x += off.x
            nx.w -= off.x
        } else if movesRight {
            nx.w += off.x
        }
        if movesTop {
            nx.y += off.y
            nx.h -= off.y
        } else if movesBottom {
            nx.h += off.y
        }
        nx.w = nx.w.rustMax(0)
        nx.h = nx.h.rustMax(0)
        tool.guides = guides
        return nx
    }
}
