// DCGeometry — more preset outlines: line callouts, arrow callouts, curved and circular arrows, curved
// ribbons, gears, tabs and chart markers. Port of deckcraft crates/geom/src/preset/extra.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Like the rest of `Preset`, every
// outline is deckcraft's own construction, fitted to how the shapes look and what their adjust values
// mean.
import Darwin

extension Preset {
    /// Builds the presets this file knows; nil for any other name.
    static func buildExtra(_ name: String, _ w: Double, _ h: Double, _ a: (Int) -> Double) -> Geometry? {
        let ss = fmin(w, h)
        let full = Rect(0.0, 0.0, w, h)
        let b = Pb()
        switch name {
        case "lineInv":
            let l = b.m(0.0, h).l(w, 0.0).take()
            return Geometry(paths: [strokeOnly(l)], textRect: full, handles: [], sites: [Point(0.0, h), Point(w, 0.0)])
        case "nonIsoscelesTrapezoid":
            let max = 50000.0 * w / fmax(ss, 1e-9)
            let (v1, v2) = (a(0).clamp(0.0, max), a(1).clamp(0.0, max))
            let (d1, d2) = (ss * v1 / 1e5, ss * v2 / 1e5)
            var g = simple(b.poly([(0.0, h), (d1, 0.0), (w - d2, 0.0), (w, h)]).take(), Rect(d1 * 0.66, h * 0.2, w - d2 * 0.66, h), w, h)
            g.handles.append(.new(0, .zero, Vec2(ss / 1e5, 0.0), v1, 0.0, max))
            g.handles.append(.new(1, Point(w, 0.0), Vec2(-ss / 1e5, 0.0), v2, 0.0, max))
            return g
        case "pieWedge":
            b.m(0.0, h).arc(w, h, 180.0, 90.0).l(w, h).z()
            return simple(b.take(), Rect(w * 0.29289, h * 0.29289, w, h), w, h)
        case "flowChartOfflineStorage":
            let tri = b.poly([(0.0, 0.0), (w, 0.0), (w / 2.0, h)]).take()
            let bar = Pb().m(w * 0.4, h * 0.8).l(w * 0.6, h * 0.8).take()
            return Geometry(
                paths: [fill(tri), strokeOnly(bar)], textRect: Rect(w / 4.0, 0.0, w * 0.75, h * 0.8), handles: [],
                sites: [Point(w / 2.0, 0.0), Point(w / 4.0, h / 2.0), Point(w / 2.0, h), Point(w * 0.75, h / 2.0)]
            )
        case "chartX", "chartStar", "chartPlus":
            let body = cornerRect(w, h, [.square, .square, .square, .square])
            let l = Pb()
            if name != "chartPlus" { l.m(0.0, 0.0).l(w, h).m(0.0, h).l(w, 0.0) }
            if name != "chartX" { l.m(w / 2.0, 0.0).l(w / 2.0, h) }
            if name == "chartPlus" { l.m(0.0, h / 2.0).l(w, h / 2.0) }
            return Geometry(paths: [fillOnly(body), strokeOnly(l.take())], textRect: full, handles: [], sites: midSites(w, h))
        case "cornerTabs", "squareTabs", "plaqueTabs":
            // Each tab's size is a twentieth of the diagonal.
            let d = fmin(fmin(Darwin.hypot(w, h) / 20.0, w / 2.0), h / 2.0)
            switch name {
            case "cornerTabs":
                b.poly([(0.0, 0.0), (d, 0.0), (0.0, d)])
                b.poly([(w - d, 0.0), (w, 0.0), (w, d)])
                b.poly([(w, h - d), (w, h), (w - d, h)])
                b.poly([(0.0, h - d), (d, h), (0.0, h)])
            case "squareTabs":
                b.poly([(0.0, 0.0), (d, 0.0), (d, d), (0.0, d)])
                b.poly([(w - d, 0.0), (w, 0.0), (w, d), (w - d, d)])
                b.poly([(w - d, h - d), (w, h - d), (w, h), (w - d, h)])
                b.poly([(0.0, h - d), (d, h - d), (d, h), (0.0, h)])
            default:
                if d > 0.0 {
                    b.m(0.0, 0.0).l(d, 0.0).arc(d, d, 0.0, 90.0).z()
                    b.m(w, 0.0).l(w, d).arc(d, d, 90.0, 90.0).z()
                    b.m(w, h).l(w - d, h).arc(d, d, 180.0, 90.0).z()
                    b.m(0.0, h).l(0.0, h - d).arc(d, d, 270.0, 90.0).z()
                } else {
                    b.m(0.0, 0.0).z()
                }
            }
            return Geometry(paths: [fill(b.take())], textRect: full.inset(-d), handles: [], sites: midSites(w, h))
        case "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2", "accentCallout3", "borderCallout2",
             "borderCallout3", "accentBorderCallout1", "accentBorderCallout2", "accentBorderCallout3":
            let n: Int = switch name.last {
            case "2": 2
            case "3": 3
            default: 1
            }
            return lineCallout(w, h, a, n + 1, name.hasPrefix("accent"), name.contains("order"))
        case "leftRightArrowCallout", "upDownArrowCallout":
            let vertical = name == "upDownArrowCallout"
            let (l, t) = vertical ? (h, w) : (w, h)
            let ss = fmin(l, t)
            let head = fmin(ss * fmax(a(1), 0.0) / 1e5, t / 2.0)
            let shaft = fmin(ss * fmax(a(0), 0.0) / 1e5, head * 2.0)
            let hl = fmin(ss * fmax(a(2), 0.0) / 1e5, l / 2.0)
            let boxl = fmin(l * fmax(a(3), 0.0) / 1e5, l - 2.0 * hl)
            let (c, b0, b1) = (t / 2.0, (l - boxl) / 2.0, (l + boxl) / 2.0)
            let raw: [(Double, Double)] = [
                (0.0, c), (hl, c - head), (hl, c - shaft / 2.0), (b0, c - shaft / 2.0), (b0, 0.0), (b1, 0.0), (b1, c - shaft / 2.0),
                (l - hl, c - shaft / 2.0), (l - hl, c - head), (l, c), (l - hl, c + head), (l - hl, c + shaft / 2.0),
                (b1, c + shaft / 2.0), (b1, t), (b0, t), (b0, c + shaft / 2.0), (hl, c + shaft / 2.0), (hl, c + head),
            ]
            let d: Dir = vertical ? .down : .right
            let pts = orient(d, w, h, raw)
            let tr = orient(d, w, h, [(b0, 0.0), (b1, t)])
            return simple(b.poly(pts).take(), Rect.fromPoints(pt(tr[0]), pt(tr[1])).abs, w, h)
        case "quadArrowCallout":
            let head = fmin(ss * fmax(a(1), 0.0) / 1e5, ss / 2.0)
            let shaft = fmin(ss * fmax(a(0), 0.0) / 1e5, head * 2.0)
            let hl = fmin(ss * fmax(a(2), 0.0) / 1e5, ss / 2.0)
            let k = a(3).clamp(0.0, 100_000.0) / 1e5
            let (bw, bh) = (fmax(fmin(w * k, w - 2.0 * hl), shaft), fmax(fmin(h * k, h - 2.0 * hl), shaft))
            let (cx, cy) = (w / 2.0, h / 2.0)
            let (bx0, bx1, by0, by1) = (cx - bw / 2.0, cx + bw / 2.0, cy - bh / 2.0, cy + bh / 2.0)
            let (s2, hd) = (shaft / 2.0, head)
            let pts: [(Double, Double)] = [
                (0.0, cy), (hl, cy - hd), (hl, cy - s2), (bx0, cy - s2), (bx0, by0), (cx - s2, by0), (cx - s2, hl), (cx - hd, hl),
                (cx, 0.0), (cx + hd, hl), (cx + s2, hl), (cx + s2, by0), (bx1, by0), (bx1, cy - s2), (w - hl, cy - s2),
                (w - hl, cy - hd), (w, cy), (w - hl, cy + hd), (w - hl, cy + s2), (bx1, cy + s2), (bx1, by1), (cx + s2, by1),
                (cx + s2, h - hl), (cx + hd, h - hl), (cx, h), (cx - hd, h - hl), (cx - s2, h - hl), (cx - s2, by1), (bx0, by1),
                (bx0, cy + s2), (hl, cy + s2), (hl, cy + hd),
            ]
            return simple(b.poly(pts).take(), Rect(bx0, by0, bx1, by1), w, h)
        case "curvedRightArrow", "curvedLeftArrow", "curvedUpArrow", "curvedDownArrow":
            return curvedArrow(name, w, h, a(0), a(1), a(2))
        case "swooshArrow":
            return swoosh(w, h, a(0), a(1))
        case "ellipseRibbon", "ellipseRibbon2":
            return ellipseRibbon(name == "ellipseRibbon2", w, h, a(0), a(1), a(2))
        case "leftRightRibbon":
            return leftRightRibbon(w, h, a(0), a(1), a(2))
        case "gear6", "gear9":
            return gear(name == "gear6" ? 6 : 9, w, h, a(0), a(1))
        case "funnel":
            return funnel(w, h)
        case "circularArrow", "leftCircularArrow", "leftRightCircularArrow":
            return circularArrow(name, w, h, [a(0), a(1), a(2), a(3), a(4)])
        default:
            return nil
        }
    }

    /// An ellipse-centred frame for the circular arrows: the band's middle runs on the ellipse
    /// `(rx, ry)`, its edges `th/2` either side.
    struct Ring {
        var c: Point
        var rx: Double
        var ry: Double
        var th: Double
        var hw: Double

        /// The point at visual angle `deg` on the ellipse grown by `d`.
        func at(_ deg: Double, _ d: Double) -> Point {
            let (ax, ay) = (fmax(rx + d, 0.0), fmax(ry + d, 0.0))
            let t = Preset.vis(deg, ax, ay).radians
            return Point(c.x + ax * sinCos(t).cos, c.y + ay * sinCos(t).sin)
        }

        /// Parametric angle (degrees) of `p` on the ellipse grown by `d`.
        func param(_ p: Point, _ d: Double) -> Double {
            let (ax, ay) = (fmax(rx + d, 1e-9), fmax(ry + d, 1e-9))
            return Darwin.atan2((p.y - c.y) / ay, (p.x - c.x) / ax).degrees
        }

        /// Where the line `b + s·u` meets the ellipse grown by `d`, taking the crossing nearest `b` on the
        /// side `sign` (+1 outwards, −1 inwards).
        func cross(_ b: Point, _ u: Vec2, _ d: Double, _ sign: Double) -> Point {
            let (ax, ay) = (fmax(rx + d, 1e-9), fmax(ry + d, 1e-9))
            let (px, py) = ((b.x - c.x) / ax, (b.y - c.y) / ay)
            let (ux, uy) = (u.x / ax, u.y / ay)
            let qa = ux * ux + uy * uy
            let qb = 2.0 * (px * ux + py * uy)
            let qc = px * px + py * py - 1.0
            let disc = qb * qb - 4.0 * qa * qc
            if qa < 1e-18 || disc < 0.0 {
                // The line misses (a long head on a thin ring): the edge then carries on from the base
                // centre itself, as the reference does.
                return b
            }
            let r = disc.squareRoot()
            let (s0, s1) = ((-qb - r) / (2.0 * qa), (-qb + r) / (2.0 * qa))
            let s: Double
            if sign > 0.0 {
                s = s0 >= 0.0 ? s0 : s1
            } else if s1 <= 0.0 {
                s = s1
            } else {
                s = s0
            }
            return b + u * s
        }

        /// An arrow head whose base centre sits on the middle ellipse at `base` degrees and whose tip
        /// sits there at `base + sweep`. The base runs along the line from the centre to the tip.
        /// Returns (band outer edge, outer wing, tip, inner wing, band inner edge).
        func head(_ base: Double, _ sweep: Double) -> [Point] {
            let b = at(base, 0.0)
            let tip = at(base + sweep, 0.0)
            let d = tip - c
            let u = d.hypot > 1e-12 ? d / d.hypot : Vec2(1.0, 0.0)
            let half = th / 2.0
            return [cross(b, u, half, 1.0), b + u * hw, tip, b - u * hw, cross(b, u, -half, -1.0)]
        }
    }

    /// Sweep (degrees) from `a` to `b` turning one way: positive when `dir > 0`.
    static func turn(_ a: Double, _ b: Double, _ dir: Double) -> Double {
        dir > 0.0 ? (b - a).remEuclid(360.0) : -(a - b).remEuclid(360.0)
    }

    /// The circular arrows: a band along an ellipse with one head (`circularArrow` clockwise,
    /// `leftCircularArrow` anticlockwise) or a head at each end (`leftRightCircularArrow`). Adjusts: band
    /// thickness, head sweep (degrees), end angle, start angle, head half-width.
    static func circularArrow(_ name: String, _ w: Double, _ h: Double, _ a: [Double]) -> Geometry {
        let ss = fmin(w, h)
        if ss <= 0.0 {
            return simple(cornerRect(w, h, [.square, .square, .square, .square]), Rect(0.0, 0.0, w, h), w, h)
        }
        let av = { (i: Int) in a.at(i) ?? 0.0 }
        let a5 = av(4).clamp(0.0, 25000.0)
        let hw = ss * a5 / 1e5
        let th = ss * av(0).clamp(0.0, 2.0 * a5) / 1e5
        let ring = Ring(c: Point(w / 2.0, h / 2.0), rx: fmax(w / 2.0 - hw, th / 2.0), ry: fmax(h / 2.0 - hw, th / 2.0), th: th, hw: hw)
        func deg(_ v: Double) -> Double { (v / 60000.0).truncatingRemainder(dividingBy: 360.0) }
        let (sweep, end, start) = (deg(av(1)), deg(av(2)), deg(av(3)))
        let half = th / 2.0
        let b = Pb()
        // Arcs of the ellipse grown by `d`, drawn on from the current point (which is on it except in
        // the degenerate case above, where the arc shifts with it like the reference's).
        func edgeArc(_ from: Point, _ to: Point, _ d: Double, _ dir: Double) {
            let (ax, ay) = (fmax(ring.rx + d, 0.0), fmax(ring.ry + d, 0.0))
            let (s, e) = (ring.param(from, d), ring.param(to, d))
            b.arc(ax, ay, s, turn(s, e, dir))
        }
        if name == "leftRightCircularArrow" {
            let hs = ring.head(start, -sweep)
            let he = ring.head(end, sweep)
            b.m(hs[0].x, hs[0].y)
            edgeArc(hs[0], he[0], half, 1.0)
            b.l(he[1].x, he[1].y).l(he[2].x, he[2].y).l(he[3].x, he[3].y).l(he[4].x, he[4].y)
            edgeArc(he[4], hs[4], -half, -1.0)
            b.l(hs[3].x, hs[3].y).l(hs[2].x, hs[2].y).l(hs[1].x, hs[1].y).z()
        } else {
            let dir = name == "circularArrow" ? 1.0 : -1.0
            let he = ring.head(end, sweep)
            let (o0, i0) = (ring.at(start, half), ring.at(start, -half))
            b.m(o0.x, o0.y)
            edgeArc(o0, he[0], half, dir)
            b.l(he[1].x, he[1].y).l(he[2].x, he[2].y).l(he[3].x, he[3].y).l(he[4].x, he[4].y)
            edgeArc(he[4], i0, -half, -dir)
            b.z()
        }
        return simple(b.take(), Rect(0.0, 0.0, w, h), w, h)
    }

    /// A funnel: an elliptical rim (with an open mouth) across the top quarter, and straight sides down
    /// to a small rounded spout. The side lines leave the rim and meet the spout at fixed angles, fitted
    /// to the reference look.
    static func funnel(_ w: Double, _ h: Double) -> Geometry {
        let rim = 173.0 // where the left side leaves the rim, degrees on the rim ellipse
        let spout = 163.4 // where it meets the spout, degrees on the spout ellipse
        let ss = fmin(w, h)
        let (cx, rimY) = (w / 2.0, h / 4.0)
        let (sx, sy) = (w / 8.0, h / 15.0)
        let spoutY = h - sy
        func at(_ rx: Double, _ ry: Double, _ cy: Double, _ deg: Double) -> Point {
            let t = deg.radians
            return Point(cx + rx * sinCos(t).cos, cy + ry * sinCos(t).sin)
        }
        let p0 = at(cx, rimY, rimY, rim)
        let p1 = at(sx, sy, spoutY, 180.0 - spout)
        let b = Pb()
        b.m(p0.x, p0.y).arc(cx, rimY, rim, 540.0 - 2.0 * rim)
        b.l(p1.x, p1.y).arc(sx, sy, 180.0 - spout, 2.0 * spout - 180.0).z()
        let d = ss / 20.0
        b.ellipse(cx, rimY, fmax(cx - d, 0.0), fmax(rimY - d, 0.0))
        return Geometry(paths: [fillEO(b.take())], textRect: Rect(w / 4.0, h / 2.0, w * 0.75, h - sy), handles: [], sites: midSites(w, h))
    }

    /// A gear: an elliptical body with `n` teeth, the first pointing straight up. Each tooth leaves the
    /// body at two points an equal angle either side of its centre, and its tip corners sit a tooth
    /// height further out along the body's normal and a flank lean further in.
    static func gear(_ n: Int, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
        let ss = fmin(w, h)
        let th = ss * a0.clamp(0.0, 20000.0) / 1e5 // tooth height
        let leanMax = n == 6 ? 5380.0 : 2730.0
        let l = ss * a1.clamp(0.0, fmin(a0.clamp(0.0, 20000.0), leanMax)) / 1e5 // flank lean
        let (cx, cy) = (w / 2.0, h / 2.0)
        let (rx, ry) = (fmax(cx - th, 0.0), fmax(cy - th, 0.0))
        let r = fmax(ss / 2.0 - th, 1e-9)
        let half = Darwin.atan((th + l) / 2.0 / r)
        let step = 2.0 * Double.pi / Double(n)
        func onBody(_ t: Double) -> Point { Point(cx + rx * sinCos(t).cos, cy + ry * sinCos(t).sin) }
        let b = Pb()
        for k in 0 ..< n {
            let t = -(Double.pi / 2.0) + step * Double(k)
            // The tooth stands along the body's normal at its centre.
            let nrm = Vec2(sinCos(t).cos * ry, sinCos(t).sin * rx)
            let u = nrm.hypot > 1e-12 ? nrm / nrm.hypot : Vec2(sinCos(t).cos, sinCos(t).sin)
            let v = Vec2(-u.y, u.x)
            let (r0, r1) = (onBody(t - half), onBody(t + half))
            let (c0, c1) = (r0 + u * th + v * l, r1 + u * th - v * l)
            if k == 0 {
                b.m(r0.x, r0.y)
            } else {
                b.arc(rx, ry, (t - step + half).degrees, (step - 2.0 * half).degrees)
            }
            b.l(c0.x, c0.y).l(c1.x, c1.y).l(r1.x, r1.y)
        }
        let tLast = -(Double.pi / 2.0) + step * Double(n - 1)
        b.arc(rx, ry, (tLast + half).degrees, (step - 2.0 * half).degrees).z()
        let k = 0.707_106_781_186_547_524_400_844_362_104_849_039 // FRAC_1_SQRT_2
        let text = Rect(cx - rx * k, cy - ry * k, cx + rx * k, cy + ry * k)
        return simple(b.take(), text, w, h)
    }

    /// Two arrows on a band that steps down in the middle: the left arrow sits high, the right one low,
    /// and the band rolls over between them in a shaded half-ellipse curl.
    static func leftRightRibbon(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
        let ss = fmin(w, h)
        let sh = h * a2.clamp(0.0, 33333.0) / 1e5 // step between the two halves
        let bt = fmin(h * fmax(a0, 0.0) / 1e5, h - sh) // band thickness
        let cx = w / 2.0
        let (rx, ry) = (w / 32.0, fmin(sh / 4.0, w / 24.0))
        let hb = fmin(ss * fmax(a1, 0.0) / 1e5, cx - rx) // head length
        let yc = (h - sh) / 2.0
        let (lt, lb) = (yc - bt / 2.0, yc + bt / 2.0)
        let (rt, rb) = (lt + sh, lb + sh)
        // The left half: filled as a closed outline, stroked only where it can show.
        let edgeB = Pb()
        edgeB.m(cx - rx, lb).l(hb, lb).l(hb, h - sh).l(0.0, yc).l(hb, 0.0).l(hb, lt).l(cx, lt)
        edgeB.arc(rx, ry, 270.0, 180.0).arc(rx, ry, 270.0, -90.0)
        let edge = edgeB.take()
        let leftB = Pb()
        leftB.m(0.0, yc).l(hb, 0.0).l(hb, lt).l(cx, lt).arc(rx, ry, 270.0, 180.0).arc(rx, ry, 270.0, -180.0)
        leftB.l(cx, fmax(lb, lt + 4.0 * ry)).l(hb, lb).l(hb, h - sh).z()
        let left = leftB.take()
        let curl = Pb()
        curl.m(cx + rx, lt + ry).l(cx + rx, rt).l(cx, lt + 4.0 * ry).arc(rx, ry, 90.0, 180.0).arc(rx, ry, 90.0, -90.0).z()
        let right = Pb()
        right.m(w, yc + sh).l(w - hb, h).l(w - hb, rb).l(cx, rb).arc(rx, ry, 90.0, 90.0).l(cx - rx, rt - ry).arc(rx, ry, 180.0, -90.0)
        right.l(w - hb, rt).l(w - hb, sh).z()
        return Geometry(
            paths: [fillOnly(left), strokeOnly(edge), shade(curl.take(), .darkenLess), fill(right.take())],
            textRect: Rect(fmin(hb, cx - rx), rt, fmax(w - hb, cx + rx), fmax(lb, rt)),
            handles: [],
            sites: [Point(0.0, yc), Point(cx, rt), Point(w, yc + sh), Point(cx, lb)]
        )
    }

    /// Adds a piece of the parabola `y = y0 + d·(1 − ((x − w/2)/(w/2))²)` from the current point (at
    /// `xa`) to `xb`, as one quadratic curve.
    static func sag(_ b: Pb, _ w: Double, _ d: Double, _ y0: Double, _ xa: Double, _ xb: Double) {
        let hw = fmax(w / 2.0, 1e-9)
        func f(_ x: Double) -> Double {
            let u = (x - hw) / hw
            return y0 + d * (1.0 - u * u)
        }
        let slope = -2.0 * d * (xa - hw) / (hw * hw)
        b.q((xa + xb) / 2.0, f(xa) + slope * (xb - xa) / 2.0, xb, f(xb))
    }

    /// A ribbon whose edges sag along one parabola: a front band in the middle and two notched ends
    /// behind it, joined by shaded folds. Built sagging downwards; `up` mirrors it vertically.
    static func ellipseRibbon(_ up: Bool, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
        let th = h * a0.clamp(0.0, 100_000.0) / 1e5 // band drop at the centre
        // Sag of every edge: never more than the drop, never so little that the band would rise above
        // the ends by more than half their height.
        let d = fmax(h * fmax(a2, 0.0) / 1e5, th - (h - th) / 2.0).clamp(0.0, th)
        let bw = w * a1.clamp(25000.0, 75000.0) / 1e5
        let (x0, x1) = ((w - bw) / 2.0, (w + bw) / 2.0)
        let ear = w / 8.0
        let (xf, xg) = (x0 + ear, x1 - ear)
        let e = h - th // band height
        let off = th - d // band top below the ends' top
        func t(_ x: Double) -> Double {
            let hw = fmax(w / 2.0, 1e-9)
            let u = (x - hw) / hw
            return d * (1.0 - u * u)
        }
        let ends = Pb()
        ends.m(0.0, 0.0)
        sag(ends, w, d, 0.0, 0.0, xf)
        ends.l(xf, t(xf) + off).l(x0, t(x0) + off).l(x0, t(x0) + e)
        sag(ends, w, d, e, x0, 0.0)
        ends.l(ear, t(ear) + e / 2.0).z()
        ends.m(w, 0.0).l(w - ear, t(w - ear) + e / 2.0).l(w, e)
        sag(ends, w, d, e, w, x1)
        ends.l(x1, t(x1) + off).l(xg, t(xg) + off).l(xg, t(xg))
        sag(ends, w, d, 0.0, xg, w)
        ends.z()
        let folds = Pb()
        folds.poly([(x0, t(x0) + off), (xf, t(xf)), (xf, t(xf) + off)])
        folds.poly([(x1, t(x1) + off), (xg, t(xg)), (xg, t(xg) + off)])
        let band = Pb()
        band.m(x0, t(x0) + off)
        sag(band, w, d, off, x0, x1)
        band.l(x1, t(x1) + off + e)
        sag(band, w, d, off + e, x1, x0)
        band.z()
        var paths = [fill(ends.take()), shade(folds.take(), .darkenLess), fill(band.take())]
        var text = Rect(x0, th, x1, t(x0) + off + e)
        if up {
            let m = Affine(1.0, 0.0, 0.0, -1.0, 0.0, h)
            for i in paths.indices { paths[i].path.applyAffine(m) }
            text = m.transformRectBBox(text)
        }
        return Geometry(paths: paths, textRect: text, handles: [], sites: midSites(w, h))
    }

    /// A sweeping arrow rising from the bottom-left corner. The band's two edges are quadratic curves
    /// from the corner; the head's base leans slightly forward and reaches one eighth of the shorter side
    /// above and below the band. The tilt and the tip's lift were fitted to the reference look.
    static func swoosh(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
        let tilt = 0.1126 // tan of the head base's lean from vertical
        let lift = 0.051 // tip height above the band's centre, per unit of height
        let ss = fmin(w, h)
        let e = ss / 8.0
        let th = fmin(h * fmax(a0, 0.0) / 1e5, fmax(h - 2.0 * e, 0.0))
        // The head is at least long enough to keep its leaning base inside the frame.
        let hl = fmin(fmax(ss * fmax(a1, 0.0) / 1e5, (e + th) * tilt), fmax(w - e * tilt, 0.0))
        let qx = w - hl
        let b = Pb()
        b.m(0.0, h)
            .q(w / 6.0, h / 3.0, qx, e)
            .l(qx - e * tilt, 0.0)
            .l(w, (e + th / 2.0 - lift * h).clamp(0.0, 2.0 * e + th))
            .l(fmin(qx + (e + th) * tilt, w), 2.0 * e + th)
            .l(fmin(qx + th * tilt, w), e + th)
            .q(w / 4.0, fmin(th + h / 12.0 + e, h), 0.0, h)
            .z()
        return simple(b.take(), Rect(0.0, 0.0, w, h), w, h)
    }

    /// A band that sweeps around half an ellipse and ends in an arrow head. Built pointing right
    /// (`curvedRightArrow`) in a `cw`×`ch` frame, then turned for the other directions.
    ///
    /// Both halves of the band hang off one ellipse touching the far side: its centre sits on the head
    /// side's edge, its horizontal radius is the full length, and the band has a constant vertical
    /// thickness. The back half (shaded) starts flat against the head side; the front half runs to the
    /// head, centred on the band where it ends.
    static func curvedArrow(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
        let alongX = name == "curvedRightArrow" || name == "curvedLeftArrow"
        let (cw, ch) = alongX ? (w, h) : (h, w)
        let ss = fmin(cw, ch)
        let head = fmin(ss * fmax(a1, 0.0) / 1e5, ch / 2.0)
        let th = fmin(ss * fmax(a0, 0.0) / 1e5, head)
        let hl = fmin(ss * fmax(a2, 0.0) / 1e5, cw)
        let hh = head / 2.0
        // The band's centre line, carried on to the head side, ends at the tip, which sits half a head
        // width above the bottom.
        let r = fmax((ch - hh - th / 2.0) / 2.0, 0.0)
        // Parametric angle where the front band reaches the head base.
        let te = cw > 0.0 ? Darwin.acos((-(hl / cw)).clamp(-1.0, 1.0)).degrees : 90.0
        let back = Pb()
        back.m(cw, 0.0).arc(cw, r, 270.0, -90.0).l(0.0, r + th).arc(cw, r, 180.0, 90.0).z()
        let front = Pb()
        front.m(0.0, r).arc(cw, r, 180.0, te - 180.0)
        let yb = front.cur.y
        let yc = yb + th / 2.0
        front.l(cw - hl, yc - hh).l(cw, 2.0 * r + th / 2.0).l(cw - hl, yc + hh).l(cw - hl, yb + th).arc(cw, r, te, 180.0 - te).z()
        let m: Affine = switch name {
        case "curvedLeftArrow": Affine(-1.0, 0.0, 0.0, 1.0, w, 0.0)
        case "curvedUpArrow": Affine(0.0, -1.0, 1.0, 0.0, 0.0, h)
        case "curvedDownArrow": Affine(0.0, 1.0, 1.0, 0.0, 0.0, 0.0)
        default: .identity
        }
        var (bp, fp) = (back.take(), front.take())
        bp.applyAffine(m)
        fp.applyAffine(m)
        return Geometry(paths: [shade(bp, .darkenLess), fill(fp)], textRect: Rect(0.0, 0.0, w, h), handles: [], sites: midSites(w, h))
    }

    /// A rectangle with a callout leader through `pts` points (`(y, x)` adjust pairs in 1/100 000 of the
    /// height and width), optionally with an accent bar at the first point's x and a border.
    static func lineCallout(_ w: Double, _ h: Double, _ a: (Int) -> Double, _ pts: Int, _ accent: Bool, _ border: Bool) -> Geometry {
        let body = cornerRect(w, h, [.square, .square, .square, .square])
        // Leaders may reach well outside the box, but not without bound.
        func pt(_ i: Int) -> (Double, Double) {
            (w * a(2 * i + 1).clamp(-1e7, 1e7) / 1e5, h * a(2 * i).clamp(-1e7, 1e7) / 1e5)
        }
        let l = Pb()
        let (x0, y0) = pt(0)
        l.m(x0, y0)
        for i in 1 ..< Swift.max(pts, 1) {
            let (x, y) = pt(i)
            l.l(x, y)
        }
        var paths = [border ? fill(body) : fillOnly(body)]
        if accent { paths.append(strokeOnly(Pb().m(x0, 0.0).l(x0, h).take())) }
        paths.append(strokeOnly(l.take()))
        return Geometry(paths: paths, textRect: Rect(0.0, 0.0, w, h), handles: [], sites: midSites(w, h))
    }
}
