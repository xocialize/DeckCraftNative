// DCAnim — the transition effects, as measured by deckcraft on PowerPoint (see Transition.swift). Port of
// deckcraft crates/anim/src/transition_fx.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// `t` is linear progress (0...1) through the transition's duration; each effect applies its own curve.
// Directions follow the file format's option: for Push, Wipe, Cover, Uncover, Pan, Vortex, Cube… `dir` is
// where things move (`l`: toward the left); for Glitter it is the side the effect starts from; Ripple's
// corner is where the wave heads.
import DCCore
import DCModel
import Darwin

private let pi = Double.pi

private let randomKinds: [String] = [
    "fade", "push", "wipe", "split", "reveal", "randomBar", "shape", "uncover", "cover", "fallOver", "drape", "curtains", "wind",
    "prestige", "fracture", "crush", "peelOff", "pageCurlDouble", "airplane", "origami", "dissolve", "checker", "blinds", "clock",
    "ripple", "honeycomb", "glitter", "vortex", "shred", "switch", "flip", "gallery", "cube", "doors", "box", "comb", "zoom", "pan",
    "ferris", "conveyor", "rotate", "window", "orbit", "flythrough",
]

enum TransitionFX {
    static func layers(_ kind: String, _ o: String, _ t: Double, _ a: Double, _ depth: UInt32) -> [Layer] {
        switch kind {
        case "none":
            return [Layer.full(.new, 1.0)]
        case "cut":
            if o == "throughBlack" && t < 0.5 { return [Layer.full(.black, 1.0)] }
            return [Layer.full(.new, 1.0)]
        case "fade" where o == "throughBlack":
            return throughBlack(t, 0.5, 0.5)
        case "fade", "morph":
            return [Layer.full(.old, 1.0), Layer.full(.new, ss(t))]
        case "push":
            let (dx, dy) = dir(o, (-1.0, 0.0))
            let s = q2(t)
            return [moved(.old, dx * s, dy * s, 1.0), moved(.new, dx * (s - 1.0), dy * (s - 1.0), 1.0)]
        case "uncover":
            let (dx, dy) = dir(o, (-1.0, 0.0))
            // Diagonal: the old slide accelerates off in the first third.
            let s = o.utf8.count == 2 ? ein(win(t, 0.05, 0.35)) : powInOut(t, 3.0)
            return [Layer.full(.new, 1.0), moved(.old, dx * s, dy * s, 1.0)]
        case "cover":
            let (dx, dy) = dir(o, (-1.0, 0.0))
            // Diagonal: the new slide shoots in and settles slowly.
            let s: Double
            if o.utf8.count == 2 {
                let k = 1.0 - win(t, 0.07, 0.95)
                s = 1.0 - k * k * k
            } else {
                s = powInOut(t, 4.0)
            }
            return [Layer.full(.old, 1.0), moved(.new, dx * (s - 1.0), dy * (s - 1.0), 1.0)]
        case "wipe": return wipe(o, t)
        case "split": return split(o, t)
        case "reveal": return reveal(o, t)
        case "randomBar": return randomBars(o == "vert", t)
        case "shape": return shape(o, t, a)
        case "flash": return flash(t)
        case "dissolve": return dissolve(t)
        case "checker": return checker(o == "vert", t, a)
        case "blinds": return blinds(o == "vert", t, a)
        case "clock": return clock(o, t, a)
        case "ripple": return ripple(o, t, a)
        case "comb": return comb(o == "vert", t)
        case "zoom": return zoom(o, t, a)
        case "pan": return pan(o, t)
        case "fallOver": return fallOver(o == "r", t, a)
        case "drape": return drape(o == "r", t, a)
        case "curtains": return curtains(t, a)
        case "wind": return wind(o == "r", t, a)
        case "prestige": return prestige(t, a)
        case "fracture": return fracture(t, a)
        case "crush": return crush(t, a)
        case "peelOff": return peelOff(o == "r", t)
        case "pageCurlDouble": return pageCurl(o, t)
        case "airplane": return airplane(o == "r", t, a)
        case "origami": return origami(o == "r", t, a)
        case "honeycomb": return honeycomb(t, a)
        case "glitter": return glitter(o, t, a)
        case "vortex": return vortex(o, t, a)
        case "shred": return shred(o, t, a)
        case "switch": return switchCards(o == "r", t, a)
        case "flip": return flip(o == "r", t, a)
        case "gallery": return gallery(o == "r", t, a)
        case "conveyor": return conveyor(o == "r", t, a)
        case "cube", "box", "rotate", "orbit": return prism(kind, o, t, a)
        case "doors", "window": return doors(kind == "window", o == "horz", t, a)
        case "ferris": return ferris(o == "r", t, a)
        case "flythrough": return flythrough(o, t)
        case "random" where depth == 0:
            let h = o.utf8.reduce(UInt64(0x51ED)) { hash64($0 ^ UInt64($1)) }
            let k = randomKinds.at(Int(h % UInt64(randomKinds.count))) ?? "fade"
            let opt = transitions.first { $0.id == k }?.options.first ?? ""
            return layers(k, opt, t, a, depth + 1)
        default:
            return [Layer.full(.old, 1.0), Layer.full(.new, ss(t))]
        }
    }

    /// Old fades to black over [0, `out`], new fades in from black over [`inn`, 1] (smoothstep).
    private static func throughBlack(_ t: Double, _ out: Double, _ inn: Double) -> [Layer] {
        var v = [Layer.full(.black, 1.0)]
        if t < out { v.append(Layer.full(.old, 1.0 - ss(win(t, 0.0, out)))) }
        if t > inn { v.append(Layer.full(.new, ss(win(t, inn, 1.0)))) }
        return v
    }

    // MARK: Subtle

    /// Width of the soft edge of Wipe and Split (slide units along the motion).
    private static let wipeSoft = 0.8

    /// Where the middle of the soft edge is at `t`: from fully before the slide to fully past it.
    private static func wipePos(_ t: Double) -> Double {
        -wipeSoft / 2.0 + (1.0 + wipeSoft) * 1.05 * t
    }

    private static func wipe(_ o: String, _ t: Double) -> [Layer] {
        let c = wipePos(t)
        // Position along the motion, 0 where the new slide starts showing.
        let p: (Double, Double) -> Double = switch o {
        case "l": { x, _ in 1.0 - x }
        case "u": { _, y in 1.0 - y }
        case "d": { _, y in y }
        case "lu": { x, y in (2.0 - x - y) / 2.0 }
        case "ru": { x, y in (1.0 + x - y) / 2.0 }
        case "ld": { x, y in (1.0 - x + y) / 2.0 }
        case "rd": { x, y in (x + y) / 2.0 }
        default: { x, _ in x }
        }
        let diag = o.utf8.count == 2
        let (n, m) = diag ? (32, 18) : (o == "u" || o == "d" ? (1, 36) : (48, 1))
        var v = [Layer.full(.old, 1.0)]
        v.append(contentsOf: field(.new, n, m) { x, y in edge(c, p(x, y), wipeSoft) })
        return v
    }

    private static func split(_ o: String, _ t: Double) -> [Layer] {
        let horz = o.bytesHavePrefix("horz")
        let inward = o.bytesHaveSuffix("In")
        let c = wipePos(t)
        func p(_ x: Double, _ y: Double) -> Double {
            let d = horz ? Swift.abs(y - 0.5) * 2.0 : Swift.abs(x - 0.5) * 2.0
            return inward ? 1.0 - d : d
        }
        let (n, m) = horz ? (1, 36) : (48, 1)
        var v = [Layer.full(.old, 1.0)]
        v.append(contentsOf: field(.new, n, m) { x, y in edge(c, p(x, y), wipeSoft) })
        return v
    }

    private static func reveal(_ o: String, _ t: Double) -> [Layer] {
        let dx = o.bytesHaveSuffix("Right") ? 1.0 : -1.0
        if o.bytesHavePrefix("black") {
            // Old slides away fading to black, a pause on black, new slides in from black.
            var v = [Layer.full(.black, 1.0)]
            if t < 0.4 {
                let u = win(t, 0.0, 0.38)
                v.append(moved(.old, dx * 0.12 * ein(u), 0.0, 1.0 - ss(u)))
            }
            if t > 0.55 {
                let u = win(t, 0.55, 1.0)
                v.append(moved(.new, -dx * 0.12 * (1.0 - eout(u)), 0.0, ss(u)))
            }
            return v
        }
        // Smoothly: the backgrounds cross-fade while the old content slides off fading and the new content
        // follows.
        var v = [Layer.full(.oldBack, 1.0), Layer.full(.newBack, ss(t))]
        if t < 0.5 {
            let u = win(t, 0.0, 0.45)
            v.append(moved(.oldContent, dx * 0.12 * ein(u), 0.0, 1.0 - ss(u)))
        }
        if t > 0.45 {
            let u = win(t, 0.47, 0.95)
            v.append(moved(.newContent, -dx * 0.12 * (1.0 - eout(u)), 0.0, ss(u)))
        }
        return v
    }

    private static func randomBars(_ vert: Bool, _ t: Double) -> [Layer] {
        // Thin bars, each cross-fading quickly at its own random moment.
        let n = 160
        let w = 0.2
        var v = [Layer.full(.old, 1.0)]
        for i in 0 ..< n {
            let start = rnd(UInt64(i) * 7 + 17) * (1.0 - w)
            let k = win(t, start, start + w)
            if k <= 0.0 { continue }
            let (a, b) = (Double(i) / Double(n), Double(i + 1) / Double(n))
            let r = vert ? R(a, 0.0, b, 1.0) : R(0.0, a, 1.0, b)
            v.append(Layer.inplace(.new, r, k))
        }
        return v
    }

    private static func shape(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        switch o {
        case "in":
            // Shape In: the old slide shrinks into the centre over the first half.
            let s = 1.0 - win(t, 0.0, 0.5)
            var v = [Layer.full(.new, 1.0)]
            if s > 0.0 { v.append(contentsOf: softRect(.old, fullRect, scaleRect(fullRect, s), 0.012, 1.0)) }
            return v
        case "out":
            // Shape Out: the new slide grows out of the centre over the second half.
            let s = win(t, 0.5, 1.0)
            var v = [Layer.full(.old, 1.0)]
            if s > 0.0 { v.append(contentsOf: softRect(.new, fullRect, scaleRect(fullRect, s), 0.012, 1.0)) }
            return v
        default:
            let soft = 0.18
            let c = -soft / 2.0 + (1.0 + soft) * t
            let f: (Double, Double) -> Double
            switch o {
            case "diamond":
                f = { x, y in edge(c, Swift.abs(x - 0.5) + Swift.abs(y - 0.5), soft) }
            case "plus":
                f = { x, y in edge(c, Swift.abs(x - 0.5).rustMin(Swift.abs(y - 0.5)) * 2.0, soft) }
            default:
                let ha = 0.5 * a
                let rmax = (ha * ha + 0.25).squareRoot()
                f = { x, y in
                    let dx = (x - 0.5) * a, dy = y - 0.5
                    return edge(c, (dx * dx + dy * dy).squareRoot() / rmax, soft)
                }
            }
            var v = [Layer.full(.old, 1.0)]
            v.append(contentsOf: field(.new, 48, 27, f))
            return v
        }
    }

    private static func flash(_ t: Double) -> [Layer] {
        // A flash bulb: the old slide burns out to white fast, the white holds, then fades off the new slide.
        let white = t < 0.1 ? t / 0.1 : (t < 0.47 ? 1.0 : 1.0 - win(t, 0.47, 0.88))
        let base: Source = t < 0.2 ? .old : .new
        return [Layer.full(base, 1.0), Layer.full(.white, white)]
    }

    // MARK: Exciting: patterns

    private static func cell(_ c: Int, _ r: Int, _ n: Int, _ m: Int) -> R {
        R(Double(c) / Double(n), Double(r) / Double(m), Double(c + 1) / Double(n), Double(r + 1) / Double(m))
    }

    private static func dissolve(_ t: Double) -> [Layer] {
        let (n, m) = (48, 27)
        var v = [Layer.full(.old, 1.0)]
        for r in 0 ..< m {
            for c in 0 ..< n where t > rnd(UInt64(r * n + c) + 991) * 0.97 {
                v.append(Layer.inplace(.new, cell(c, r, n, m), 1.0))
            }
        }
        return v
    }

    /// One tile flipping in 3-D about its own vertical (or horizontal) axis: old face for the first half of
    /// `k`, new face for the second.
    private static func flipTile(_ cam: Cam, _ cellR: R, _ k: Double, _ verticalAxis: Bool, _ out: inout [Layer]) {
        if k <= 0.0 {
            out.append(Layer.inplace(.old, cellR, 1.0))
            return
        }
        if k >= 1.0 {
            out.append(Layer.inplace(.new, cellR, 1.0))
            return
        }
        let ang = 180.0 * k
        let cc = center(cellR)
        let c3 = cam.unit(cc[0], cc[1])
        let (src, deg): (Source, Double) = k < 0.5 ? (.old, ang) : (.new, ang - 180.0)
        let pts = cam.rect(cellR).map { verticalAxis ? $0.yaw(c3, deg) : $0.pitch(c3, deg) }
        let sh = facingShade(pts, 0.6)
        out.append(contentsOf: card(cam, src, cellR, pts, 1.0, sh, true))
    }

    private static func checker(_ vert: Bool, _ t: Double, _ a: Double) -> [Layer] {
        let (n, m) = (10, 8)
        let cam = Cam(a: a, d: 3.0)
        var v = [Layer.full(.black, 1.0)]
        for r in 0 ..< m {
            for c in 0 ..< n {
                let ce = cell(c, r, n, m)
                let across = vert ? Double(r) / Double(m) : Double(c) / Double(n)
                let start = across * 0.55 + rnd(UInt64(r * n + c) + 5) * 0.12
                let k = q2(win(t, start, start + 0.3))
                flipTile(cam, ce, k, !vert, &v)
            }
        }
        return v
    }

    private static func blinds(_ vert: Bool, _ t: Double, _ a: Double) -> [Layer] {
        let n = 12
        let cam = Cam(a: a, d: 3.0)
        var v = [Layer.full(.black, 1.0)]
        for i in 0 ..< n {
            let (s, e) = (Double(i) / Double(n), Double(i + 1) / Double(n))
            let ce = vert ? R(s, 0.0, e, 1.0) : R(0.0, s, 1.0, e)
            let start = 0.1 + 0.3 * Double(i) / Double(n)
            let k = q2(win(t, start, start + 0.4))
            flipTile(cam, ce, k, vert, &v)
        }
        return v
    }

    private static func clock(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        // The hand sweeps at a constant speed with a soft leading edge.
        let soft = 0.12
        let c = -soft / 2.0 + (1.0 + soft) * t
        func f(_ ang: Double) -> Double {
            let p: Double
            switch o {
            case "counterClockwise": p = (2.0 * pi - ang) / (2.0 * pi)
            case "wedge":
                let d = ang > pi ? 2.0 * pi - ang : ang
                p = d / pi
            default: p = ang / (2.0 * pi)
            }
            return edge(c, p, soft)
        }
        var v = [Layer.full(.old, 1.0)]
        v.append(contentsOf: fan(.new, a, 240, f))
        return v
    }

    private static func ripple(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        // A soft disc of the new slide spreads from the centre, or from the corner opposite to where the wave
        // heads.
        let origin: P = switch o {
        case "lu": P(1.0, 1.0)
        case "ru": P(0.0, 1.0)
        case "ld": P(1.0, 0.0)
        case "rd": P(0.0, 0.0)
        default: P(0.5, 0.5)
        }
        func dist(_ x: Double, _ y: Double) -> Double {
            let dx = (x - origin[0]) * a, dy = y - origin[1]
            return (dx * dx + dy * dy).squareRoot()
        }
        let far = [P(0.0, 0.0), P(1.0, 0.0), P(0.0, 1.0), P(1.0, 1.0)].map { dist($0[0], $0[1]) }.reduce(0.0) { $0.rustMax($1) }
        let soft = 0.16
        let c = -soft / 2.0 + (1.0 + soft) * t
        var v = [Layer.full(.old, 1.0)]
        v.append(contentsOf: field(.new, 48, 27) { x, y in
            let d = dist(x, y) / far.rustMax(1e-6)
            return edge(c, d, soft)
        })
        // Rings of shade travelling inside the wave.
        v.append(contentsOf: field(.black, 48, 27) { x, y in
            let d = dist(x, y) / far.rustMax(1e-6)
            let inside = edge(c, d, soft)
            let w = Swift.abs(Darwin.sin((d - c) * 30.0))
            return 0.18 * inside * (1.0 - w) * (1.0 - t)
        })
        return v
    }

    private static func comb(_ vert: Bool, _ t: Double) -> [Layer] {
        // Bands of the old slide slide off to alternate sides, one after another from the last band,
        // uncovering the new slide.
        let n = vert ? 10 : 7
        var v = [Layer.full(.new, 1.0)]
        for i in 0 ..< n {
            let (a, b) = (Double(i) / Double(n), Double(i + 1) / Double(n))
            let d = (n - 1 - i) % 2 == 0 ? 1.0 : -1.0
            let start = 0.06 + 0.05 * Double(n - 1 - i) * 7.0 / Double(n)
            let s = ein(win(t, start, start + 0.55))
            if s >= 1.0 { continue }
            let band = vert ? R(a, 0.0, b, 1.0) : R(0.0, a, 1.0, b)
            let (ox, oy) = vert ? (0.0, d * s) : (d * s, 0.0)
            v.append(Layer.rect(.old, band, offset(band, ox, oy), 1.0))
        }
        return v
    }

    private static func zoom(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        switch o {
        case "rotate":
            // Zoom and Rotate: the new slide spins in from the centre, a full clockwise turn, fading in as it
            // grows.
            let u = win(t, 0.1, 0.98)
            let s = 0.1 + 0.9 * u
            let ang = 360.0 * (1.0 - u)
            let r = scaleRect(fullRect, s)
            let q = rotQuad(corners(r), P(0.5, 0.5), ang, a)
            return [Layer.full(.old, 1.0), Layer.quad(.new, fullRect, q, 0.35 + 0.65 * ss(win(t, 0.0, 0.45)))]
        case "out":
            // Zoom Out: the new slide comes down from large underneath while the old one shrinks away fading.
            let s = eout(win(t, 0.0, 0.8))
            return [
                scaled(.new, 1.9 - 0.9 * s, 0.5, 0.5, 0.0, 0.0, 1.0),
                scaled(.old, 1.0 - 0.5 * eout(t), 0.5, 0.5, 0.0, 0.0, 1.0 - ss(win(t, 0.0, 0.95))),
            ]
        default:
            // Zoom In: the old slide grows toward the viewer fading, the new one grows into place from small.
            return [
                Layer.full(.black, 1.0),
                scaled(.old, 1.0 + 0.3 * ss(t), 0.5, 0.5, 0.0, 0.0, 1.0 - ss(win(t, 0.0, 0.9))),
                scaled(.new, 0.5 + 0.5 * ss(win(t, 0.15, 0.95)), 0.5, 0.5, 0.0, 0.0, ss(win(t, 0.0, 0.85))),
            ]
        }
    }

    private static func fallOver(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide tips forward about its bottom edge and falls out of view.
        let cam = Cam(a: a, d: 2.2)
        let u = ein(win(t, 0.0, 0.88))
        let ang = 92.0 * u
        let pivot = v3(0.0, 0.5, 0.0)
        let side = right ? 1.0 : -1.0
        let pts = cam.rect(fullRect).map { $0.pitch(pivot, ang).roll(pivot, side * 6.0 * u) }
        var v = [Layer.full(.new, 1.0)]
        if u < 1.0 { v.append(contentsOf: card(cam, .old, fullRect, pts, 1.0, facingShade(pts, 0.4), true)) }
        return v
    }

    private static func drape(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The new slide drops from its top edge like cloth over the old one.
        let cam = Cam(a: a, d: 2.2)
        let u = q2(win(t, 0.25, 0.62))
        let wob = 4.0 * (1.0 - win(t, 0.6, 1.0)) * Darwin.sin(win(t, 0.6, 1.0) * pi * 2.0)
        let ang = 90.0 * (1.0 - u) + wob * u
        let pivot = v3(0.0, -0.5, 0.0)
        let side = right ? -1.0 : 1.0
        let pts = cam.rect(fullRect).map { $0.pitch(pivot, -ang).roll(pivot, side * 3.0 * (1.0 - u)) }
        var v = [Layer.full(.old, 1.0)]
        if u > 0.0 { v.append(contentsOf: card(cam, .new, fullRect, pts, 1.0, facingShade(pts, 0.5), true)) }
        return v
    }

    private static func curtains(_ t: Double, _ a: Double) -> [Layer] {
        // The old slide parts in the middle into two curtains drawn to the sides, then lifted away.
        let open = q2(win(t, 0.0, 0.35))
        let lift = ein(win(t, 0.62, 0.9))
        var v = [Layer.full(.new, 1.0)]
        let wTop = 0.5 - 0.22 * open
        let wBot = 0.5 - 0.12 * open
        let up = 0.15 * lift
        let sw = 0.75 * lift
        let left = Quad(P(-sw, -up), P(wTop - sw, -up), P(wBot - 0.6 * sw, 1.0 - up), P(-0.6 * sw, 1.0 - up))
        let right = Quad(P(1.0 - wTop + sw, -up), P(1.0 + sw, -up), P(1.0 + 0.6 * sw, 1.0 - up), P(1.0 - wBot + 0.6 * sw, 1.0 - up))
        v.append(Layer.quad(.old, R(0.0, 0.0, 0.5, 1.0), left, 1.0))
        v.append(Layer.quad(.old, R(0.5, 0.0, 1.0, 1.0), right, 1.0))
        _ = a
        return v
    }

    private static func wind(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide blows away like a sheet, lifting and receding toward one side.
        let cam = Cam(a: a, d: 2.2)
        let u = ein(win(t, 0.12, 0.8))
        let side = right ? 1.0 : -1.0
        let pivot = v3(0.0, 0.0, 0.0)
        let pts = cam.rect(fullRect).map { p -> V3 in
            let w = p.pitch(v3(0.0, -0.5, 0.0), -25.0 * u).yaw(pivot, -side * 20.0 * u)
            return v3(w.x + side * 1.6 * u * a / 2.0, w.y - 0.8 * u, w.z + 0.5 * u)
        }
        var v = [Layer.full(.new, 1.0)]
        if u < 1.0 { v.append(contentsOf: card(cam, .old, fullRect, pts, 1.0, 0.0, true)) }
        return v
    }

    private static func prestige(_ t: Double, _ a: Double) -> [Layer] {
        // The old slide lifts at its bottom edge and flies off upward.
        let cam = Cam(a: a, d: 2.2)
        let lift = q2(win(t, 0.4, 0.62))
        let fly = ein(win(t, 0.5, 0.85))
        let pivot = v3(0.0, -0.5, 0.0)
        let pts = cam.rect(fullRect).map { p -> V3 in
            let w = p.pitch(pivot, -40.0 * lift).roll(pivot, -12.0 * fly)
            return v3(w.x - 0.4 * fly * a / 2.0, w.y - 1.3 * fly, w.z - 0.2 * fly)
        }
        var v = [Layer.full(.new, 1.0)]
        if fly < 1.0 { v.append(contentsOf: card(cam, .old, fullRect, pts, 1.0, facingShade(pts, 0.3), true)) }
        return v
    }

    private static func fracture(_ t: Double, _ a: Double) -> [Layer] {
        // The old slide cracks into long shards radiating from its centre; the shards part a little, then
        // fall away, the top ones first.
        var v = [Layer.full(.new, 1.0)]
        let crack = ss(win(t, 0.06, 0.2))
        if crack <= 0.0 {
            v.append(Layer.full(.old, 1.0))
            return v
        }
        let n = 36
        let rings = [0.0, 0.3, 0.6, 1.0]
        let c = P(0.5, 0.5)
        for i in 0 ..< n {
            let a0 = 2.0 * pi * (Double(i) + 0.35 * rnd(UInt64(i))) / Double(n)
            let a1 = 2.0 * pi * (Double(i) + 1.0 + 0.35 * rnd(UInt64(i + 1) % UInt64(n))) / Double(n)
            for r in 0 ..< 3 {
                let (r0, r1) = (rings[r], r == 2 ? 1.6 : rings[r + 1])
                func p(_ ang: Double, _ rr: Double) -> P {
                    let b = boundary(ang, a)
                    return P(c[0] + (b[0] - c[0]) * rr, c[1] + (b[1] - c[1]) * rr)
                }
                let pts = [p(a0, r0), p(a1, r0), p(a1, r1), p(a0, r1)]
                let id = UInt64(i * 3 + r)
                let mid = P((pts[0][0] + pts[1][0] + pts[2][0] + pts[3][0]) / 4.0, (pts[0][1] + pts[1][1] + pts[2][1] + pts[3][1]) / 4.0)
                let start = 0.3 + 0.28 * mid[1].clamped(0.0, 1.0) + 0.1 * rnd(id + 300)
                let k = win(t, start, start + 0.35)
                let gap = 0.015 * crack
                let out = P((mid[0] - c[0]) * gap * 4.0, (mid[1] - c[1]) * gap * 4.0 + 1.4 * k * k)
                let ang = (rnd(id + 7) - 0.5) * 50.0 * k
                func place(_ p: P) -> P {
                    let q = P(
                        mid[0] + (p[0] - mid[0]) * (1.0 - 0.06 * crack) + out[0], mid[1] + (p[1] - mid[1]) * (1.0 - 0.06 * crack) + out[1]
                    )
                    return rot(q, P(mid[0] + out[0], mid[1] + out[1]), ang, a)
                }
                let q = Quad(place(pts[0]), place(pts[1]), place(pts[2]), place(pts[3]))
                func clampUV(_ p: P) -> P { P(p[0].clamped(0.0, 1.0), p[1].clamped(0.0, 1.0)) }
                let uv = Quad(clampUV(pts[0]), clampUV(pts[1]), clampUV(pts[2]), clampUV(pts[3]))
                if k < 1.0 {
                    let l = Layer(source: .old, src: fullRect, quad: q, uv: uv, alpha: 1.0)
                    v.append(l)
                    v.append(l.shade(0.1 * crack * rnd(id + 9) + 0.2 * k))
                }
            }
        }
        return v
    }

    private static func crush(_ t: Double, _ a: Double) -> [Layer] {
        // The old slide crumples into a ball that drops away.
        var v = [Layer.full(.new, 1.0)]
        let k = q2(win(t, 0.08, 0.55))
        let drop = ein(win(t, 0.65, 1.0))
        let size = 1.0 - 0.45 * k
        let cx = 0.5 - 0.1 * k + 0.05 * drop
        let cy = 0.5 + 0.05 * k + 0.8 * drop
        let n = 40
        let c = P(0.5, 0.5)
        for i in 0 ..< n {
            let a0 = 2.0 * pi * Double(i) / Double(n)
            let a1 = 2.0 * pi * Double(i + 1) / Double(n)
            func j(_ ang: Double, _ idx: Int) -> P {
                let b = boundary(ang, a)
                // Corners pull in toward a round ball, with crumpled jags.
                let (dx, dy) = ((b[0] - 0.5) * a, b[1] - 0.5)
                let len = (dx * dx + dy * dy).squareRoot().rustMax(1e-9)
                let rr = 0.45
                let round = P(0.5 + dx / len * rr / a, 0.5 + dy / len * rr)
                let jag = 1.0 - 0.18 * k * rnd(UInt64(idx) % UInt64(n) + 77)
                let p = P(b[0] + (round[0] - b[0]) * k, b[1] + (round[1] - b[1]) * k)
                return P(cx + (p[0] - c[0]) * size * jag, cy + (p[1] - c[1]) * size * jag)
            }
            let (p0, p1) = (j(a0, i), j(a1, i + 1))
            let (u0, u1) = (boundary(a0, a), boundary(a1, a))
            let l = Layer.triUV(.old, (P(cx, cy), p0, p1), (c, u0, u1), (1.0, 1.0, 1.0), 1.0)
            v.append(l)
            v.append(l.shade(0.35 * k * rnd(UInt64(i) + 13)))
        }
        return v
    }

    private static func peelOff(_ right: Bool, _ t: Double) -> [Layer] {
        // The old slide peels from a bottom corner toward the opposite top corner; the peeled flap shows the
        // page's back folded over.
        let u = ss(win(t, 0.2, 0.95))
        // Fold line perpendicular to the diagonal, sweeping from the corner.
        let (cx, cy) = right ? (0.0, 1.0) : (1.0, 1.0)
        let nd = right ? P(1.0, -1.0) : P(-1.0, -1.0)
        let len = (nd[0] * nd[0] + nd[1] * nd[1]).squareRoot()
        let n = P(nd[0] / len, nd[1] / len)
        let span = 2.0.squareRoot()
        let d0 = n[0] * cx + n[1] * cy
        let fold = d0 + span * 1.25 * u
        var v = [Layer.full(.new, 1.0)]
        let full = rectPoly(fullRect)
        // Kept part: beyond the fold line from the corner.
        let keep = clipPoly(full, P(-n[0], -n[1]), -fold)
        v.append(contentsOf: polyLayers(.old, keep, 1.0) { $0 })
        // Peeled part, reflected over the fold line.
        let peeled = clipPoly(full, n, fold)
        func refl(_ p: P) -> P {
            let d = n[0] * p[0] + n[1] * p[1] - fold
            return P(p[0] - 2.0 * d * n[0], p[1] - 2.0 * d * n[1])
        }
        for l in polyLayers(.old, peeled, 1.0, refl) {
            v.append(l)
            v.append(l.shade(0.25))
        }
        return v
    }

    private static func pageCurl(_ o: String, _ t: Double) -> [Layer] {
        let single = o.bytesHavePrefix("single")
        let right = o.bytesHaveSuffix("r") || o.bytesHaveSuffix("R")
        var v = [Layer.full(.new, 1.0)]
        // A roll travelling across the old slide: x of the roll's front edge.
        func roll(_ area: R, _ k: Double, _ towardLeft: Bool) {
            let w = area[2] - area[0]
            let r = 0.06
            if towardLeft {
                let e = area[2] - (w + r) * k
                let keep = R(area[0], area[1], e.rustMax(area[0]), area[3])
                if keep[2] > keep[0] { v.append(Layer.inplace(.old, keep, 1.0)) }
                // The roll: a band squeezing the rolled-up part.
                let band = R(e.rustMax(area[0]), area[1], (e + r).rustMin(area[2]).rustMax(area[0]), area[3])
                if band[2] > band[0] && k < 1.0 {
                    let src = R(band[0], area[1], area[2], area[3])
                    let l = Layer.rect(.old, src, band, 1.0)
                    v.append(l)
                    v.append(l.shade(0.3).faded(SIMD4(0.2, 1.0, 1.0, 0.2)))
                }
            } else {
                let e = area[0] + (w + r) * k
                let keep = R(e.rustMin(area[2]), area[1], area[2], area[3])
                if keep[2] > keep[0] { v.append(Layer.inplace(.old, keep, 1.0)) }
                let band = R((e - r).rustMax(area[0]).rustMin(area[2]), area[1], e.rustMin(area[2]), area[3])
                if band[2] > band[0] && k < 1.0 {
                    let src = R(area[0], area[1], band[2], area[3])
                    let l = Layer.rect(.old, src, band, 1.0)
                    v.append(l)
                    v.append(l.shade(0.3).faded(SIMD4(1.0, 0.2, 0.2, 1.0)))
                }
            }
        }
        if single {
            let k = q2(win(t, 0.25, 0.85))
            roll(fullRect, k, !right)
        } else {
            // Double: the half on the far side rolls first, then the near half.
            let k1 = q2(win(t, 0.1, 0.6))
            let k2 = q2(win(t, 0.45, 0.85))
            if right {
                roll(R(0.0, 0.0, 0.5, 1.0), k1, false)
                roll(R(0.5, 0.0, 1.0, 1.0), k2, false)
            } else {
                roll(R(0.5, 0.0, 1.0, 1.0), k1, true)
                roll(R(0.0, 0.0, 0.5, 1.0), k2, true)
            }
        }
        return v
    }

    private static func airplane(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide folds into a big paper dart (nose to the right for "l") that hangs low, then flies off
        // up and away.
        let fold = q2(win(t, 0.0, 0.3))
        let fly = ein(win(t, 0.82, 0.95))
        var v = [Layer.full(.new, 1.0)]
        if fly >= 1.0 { return v }
        func mx(_ p: P) -> P { right ? P(1.0 - p[0], p[1]) : p }
        // The dart in its hanging pose ("l"), then flown off.
        let drift = 0.04 * win(t, 0.3, 0.82)
        func pose(_ p0: P) -> P {
            let p = P(p0[0] + drift, p0[1] + drift)
            let c = P(0.75, 0.65)
            let k = 1.0 - 0.85 * fly
            return P(c[0] + (p[0] - c[0]) * k - 0.4 * fly, c[1] + (p[1] - c[1]) * k - 1.0 * fly)
        }
        let dart = [P(0.42, 0.28), P(1.02, 0.66), P(1.0, 0.72), P(0.46, 1.08)]
        let flat = [P(0.0, 0.0), P(1.0, 0.0), P(1.0, 1.0), P(0.0, 1.0)]
        let pts: [P] = (0 ..< 4).map { i in
            let (f, d) = (flat[i], dart[i])
            return mx(pose(P(f[0] + (d[0] - f[0]) * fold, f[1] + (d[1] - f[1]) * fold)))
        }
        let uv = flat.map(mx)
        let l1 = Layer.triUV(.old, (pts[0], pts[1], pts[2]), (uv[0], uv[1], uv[2]), (1.0, 1.0, 1.0), 1.0)
        let l2 = Layer.triUV(.old, (pts[0], pts[2], pts[3]), (uv[0], uv[2], uv[3]), (1.0, 1.0, 1.0), 1.0)
        v.append(l1)
        v.append(l1.shade(0.1 * fold))
        v.append(l2)
        v.append(l2.shade(0.3 * fold))
        _ = a
        return v
    }

    private static func origami(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide folds into a bird that flies off.
        let fold = q2(win(t, 0.0, 0.2))
        let fly = ein(win(t, 0.2, 0.85))
        let side = right ? 1.0 : -1.0
        var v = [Layer.full(.new, 1.0)]
        if win(t, 0.2, 0.92) >= 1.0 { return v }
        let size = 1.0 - 0.35 * fold
        let cx = 0.47 + side * 0.65 * fly
        let cy = 0.42 + 0.05 * fly
        let flap = Darwin.sin(t * 18.0) * 0.08 * fold
        func body(_ p: P) -> P { P(cx + (p[0] - 0.5) * size, cy + (p[1] - 0.5) * size) }
        let shape: [(P, P)] = [
            (P(0.0, 0.0), P(-0.45 * side, -0.25 - flap)),
            (P(1.0, 0.0), P(0.15 * side, -0.4 + flap)),
            (P(1.0, 1.0), P(0.45 * side, 0.05)),
            (P(0.0, 1.0), P(-0.1 * side, 0.2)),
        ]
        let pts: [P] = shape.map { flat, bird in
            body(P(flat[0] + (0.5 + bird[0] - flat[0]) * fold, flat[1] + (0.5 + bird[1] - flat[1]) * fold))
        }
        let uv: [P] = shape.map(\.0)
        let l1 = Layer.triUV(.old, (pts[0], pts[1], pts[2]), (uv[0], uv[1], uv[2]), (1.0, 1.0, 1.0), 1.0)
        let l2 = Layer.triUV(.old, (pts[0], pts[2], pts[3]), (uv[0], uv[2], uv[3]), (1.0, 1.0, 1.0), 1.0)
        v.append(l1)
        v.append(l1.shade(0.15 * fold))
        v.append(l2)
        v.append(l2.shade(0.3 * fold))
        _ = a
        return v
    }

    private static func honeycomb(_ t: Double, _ a: Double) -> [Layer] {
        // The old slide splits into hexagonal cells along dark seams; the cells fly at the viewer and out of
        // sight, leaving black; cells of the new slide pop in one by one and close the seams.
        let cols = 11
        let w = 1.0 / Double(cols)
        let rh = w * a * 0.5
        // Rows sit 0.866*rh apart; a settled hex reaches only 0.577*rh from its centre at the side vertices,
        // and the flat bottom zone 0.289*rh. Count the rows whose FLAT zone still covers the slide's bottom:
        // counting the vertex reach instead left V-notches of black above the bottom edge on about a third of
        // the aspect ratios (#420).
        let rows = Int(rustCast: (1.0 / (rh * 0.866) - 1.0 / 3.0).rounded(.up).rustMax(1.0)) &+ 1
        var v = [Layer.full(.black, 1.0)]
        let seam = ss(win(t, 0.0, 0.12)) * (1.0 - ss(win(t, 0.85, 1.0)))
        func hex(_ cx: Double, _ cy: Double, _ s: Double) -> [P] {
            (0 ..< 6).map { k in
                let ang = pi / 3.0 * Double(k) + pi / 6.0
                let (sn, cs) = sinCos(ang)
                return P(cx + cs * s * w * 0.577, cy + sn * s * rh * 0.577 / 0.5 * 0.5)
            }
        }
        for r in 0 ..< Swift.max(rows, 0) {
            for c in 0 ... cols {
                let cx = (Double(c) + (r % 2 == 1 ? 0.5 : 0.0)) * w
                let cy = Double(r) * rh * 0.866
                let id = UInt64(r &* 64 &+ c)
                let srcHex = hex(cx, cy, 1.0)
                let outStart = 0.1 + 0.2 * rnd(id + 1)
                let outK = ein(win(t, outStart, outStart + 0.12))
                let inStart = 0.38 + 0.42 * rnd(id + 3)
                let inK = eout(win(t, inStart, inStart + 0.1))
                let gap = 1.0 - 0.1 * seam
                func cellAt(_ src: Source, _ s: Double, _ alpha: Double) {
                    let dst = hex(cx, cy, s)
                    for k in 0 ..< 6 {
                        let (p0, p1) = (dst[k], dst[(k + 1) % 6])
                        let (u0, u1) = (srcHex[k], srcHex[(k + 1) % 6])
                        v.append(Layer.triUV(src, (P(cx, cy), p0, p1), (P(cx, cy), u0, u1), (1.0, 1.0, 1.0), alpha))
                    }
                }
                if t < 0.5 && outK < 1.0 { cellAt(.old, gap * (1.0 + 3.0 * outK), 1.0 - outK * outK) }
                if inK > 0.0 { cellAt(.new, gap * (0.3 + 0.7 * inK), 1.0) }
            }
        }
        return v
    }

    private static func glitter(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        // Tiles flip from the old slide to the new in a sparkling sweep starting on the option's side.
        let hexes = o.bytesHavePrefix("hex")
        // `trim_start_matches("hex")`, on bytes.
        var rest = Array(o.utf8)[...]
        while rest.starts(with: "hex".utf8) { rest = rest.dropFirst(3) }
        let d = rustASCIILowercase(String(decoding: rest, as: UTF8.self))
        let (n, m) = hexes ? (28, 16) : (40, 22)
        let cam = Cam(a: a, d: 3.0)
        var v = [Layer.full(.old, 1.0)]
        for r in 0 ..< m {
            for c in 0 ..< n {
                let ce = cell(c, r, n, m)
                let cc = center(ce)
                // Distance from the side the sweep starts on ("r": from the right).
                let grad: Double = switch d {
                case "r": 1.0 - cc[0]
                case "u": cc[1]
                case "d": 1.0 - cc[1]
                default: cc[0]
                }
                let start = 0.75 * grad * 0.85 + rnd(UInt64(r * n + c) + 77) * 0.12
                let k = win(t, start, start + 0.25)
                if k <= 0.0 { continue }
                v.append(Layer.inplace(.black, ce, 1.0))
                flipTile(cam, ce, k, true, &v)
            }
        }
        return v
    }

    private static func vortex(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide breaks into fine particles that whirl off toward the option's side, the trailing side
        // first; the new slide's particles whirl in and settle, the leading side first.
        let (dx, dy) = dir(o, (-1.0, 0.0))
        let (n, m) = (48, 27)
        var v = [Layer.full(.black, 1.0)]
        for r in 0 ..< m {
            for c in 0 ..< n {
                let id = UInt64(r * n + c)
                let ce = cell(c, r, n, m)
                let cc = center(ce)
                // 1 on the side things move toward, 0 on the other.
                let lead = (0.5 + (cc[0] - 0.5) * dx + (cc[1] - 0.5) * dy).clamped(0.0, 1.0)
                let go = 0.4 * lead + 0.08 * rnd(id + 31)
                let ko = win(t, go, go + 0.35)
                let end = 0.62 + 0.3 * (1.0 - lead) + 0.06 * rnd(id + 41)
                let kn = 1.0 - win(t, end - 0.35, end)
                func piece(_ src: Source, _ k: Double) {
                    let swirl = 2.0 * pi * (rnd(id + 5) - 0.5) * k
                    let (ss, sc) = sinCos(swirl)
                    let off = P(dx * k * 0.8 + ss * 0.15 * k, dy * k * 0.8 - Swift.abs(sc) * 0.12 * k)
                    let s = 0.8 - 0.5 * k
                    let r2 = offset(scaleRect(ce, s), off[0], off[1])
                    let q = rotQuad(corners(r2), center(r2), rnd(id) * 360.0 * k, a)
                    v.append(Layer.quad(src, ce, q, 1.0 - k * k))
                }
                if kn < 1.0 { piece(.new, kn) }
                if ko > 0.0 && ko < 1.0 && kn >= 1.0 {
                    piece(.old, ko)
                } else if ko <= 0.0 {
                    v.append(Layer.inplace(.old, ce, 1.0))
                }
            }
        }
        return v
    }

    private static func shred(_ o: String, _ t: Double, _ a: Double) -> [Layer] {
        let particles = o.bytesHavePrefix("particles") || o.bytesHavePrefix("rect")
        let out = o.bytesHaveSuffix("Out")
        let cam = Cam(a: a, d: 2.5)
        var v = [Layer.full(.black, 1.0)]
        // First half: the old slide comes apart and recedes; second half: the new one assembles.
        let (src, k): (Source, Double) = t < 0.55 ? (.old, q2(win(t, 0.05, 0.55))) : (.new, 1.0 - q2(win(t, 0.55, 0.95)))
        if particles {
            let (n, m) = (64, 36)
            for r in 0 ..< m {
                for c in 0 ..< n {
                    let id = UInt64(r * n + c)
                    let ce = cell(c, r, n, m)
                    let cc = center(ce)
                    let z = (out ? -0.6 : 1.5) * k * (0.5 + rnd(id))
                    let jitter = P((rnd(id + 1) - 0.5) * 0.4 * k, (rnd(id + 2) - 0.5) * 0.4 * k)
                    let p3 = cam.unit(cc[0] + jitter[0], cc[1] + jitter[1])
                    let pc = cam.p(v3(p3.x, p3.y, z))
                    let s = 0.8 * (1.0 - 0.3 * k) * cam.d / (cam.d + z).rustMax(0.1)
                    let r2 = offset(scaleRect(ce, s), pc[0] - cc[0], pc[1] - cc[1])
                    let l = Layer.rect(src, ce, r2, 1.0 - 0.3 * k * rnd(id + 5))
                    v.append(l)
                    v.append(l.shade(0.4 * k))
                }
            }
        } else {
            let n = 30
            for i in 0 ..< n {
                let id = UInt64(i)
                let (x0, x1) = (Double(i) / Double(n), Double(i + 1) / Double(n))
                let ce = R(x0, 0.0, x1, 1.0)
                let z = (out ? -0.3 : 1.0) * k * k * (0.6 + rnd(id + 11))
                let tilt = (rnd(id + 12) - 0.5) * 30.0 * k
                let drop = (rnd(id + 13) - 0.3) * 0.25 * k
                let inset = 0.004 * k
                let w3 = cam.rect(R(x0 + inset, 0.0, x1 - inset, 1.0))
                let c3 = cam.unit((x0 + x1) / 2.0, 0.5)
                let pts = w3.map { p -> V3 in
                    let q = p.roll(c3, tilt * 0.2).yaw(c3, tilt)
                    return v3(q.x, q.y + drop, q.z + z)
                }
                v.append(contentsOf: card(cam, src, ce, pts, 1.0, 0.3 * k, true))
            }
        }
        return v
    }

    private static func switchCards(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // Switching cards: the old slide is pulled out to one side ("l": left) and slipped behind while the
        // new one, pulled out to the other side from behind it, comes to the front. Both turn a little away at
        // their outer edges.
        let cam = Cam(a: a, d: 2.5)
        let side = right ? -1.0 : 1.0
        let u = (t + ss(t)) / 2.0
        let k = Darwin.sin(u * pi)
        let shift = 0.5 * k * a
        let old = cam.rect(fullRect).map { p -> V3 in
            let q = p.yaw(v3(0.0, 0.0, 0.0), side * 14.0 * k)
            return v3(q.x - side * shift, q.y, q.z + 0.12 * k)
        }
        let new = cam.rect(fullRect).map { p -> V3 in
            let q = p.yaw(v3(0.0, 0.0, 0.0), -side * 14.0 * k)
            return v3(q.x + side * shift, q.y, q.z + 0.12 * k)
        }
        var v = [Layer.full(.black, 1.0)]
        let o = card(cam, .old, fullRect, old, 1.0, facingShade(old, 0.3), true)
        let n = card(cam, .new, fullRect, new, 1.0, facingShade(new, 0.3), true)
        if u < 0.5 {
            v.append(contentsOf: n)
            v.append(contentsOf: o)
        } else {
            v.append(contentsOf: o)
            v.append(contentsOf: n)
        }
        return v
    }

    private static func flip(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The slide turns over like a card: the old face, then the new one on its back.
        let cam = Cam(a: a, d: 2.5)
        let s = q2(t)
        let side = right ? 1.0 : -1.0
        let deg = 180.0 * s * side
        let back = 0.6 * Darwin.sin(s * pi)
        let c = v3(0.0, 0.0, 0.0)
        let pts = cam.rect(fullRect).map { p -> V3 in
            let q = p.yaw(c, deg)
            return v3(q.x, q.y, q.z + back)
        }
        var v = [Layer.full(.black, 1.0)]
        if s < 0.5 {
            v.append(contentsOf: card(cam, .old, fullRect, pts, 1.0, facingShade(pts, 0.5), true))
        } else {
            // The back face: the new slide, mirrored so it reads right way round.
            let m = Corners3(pts[1], pts[0], pts[3], pts[2])
            v.append(contentsOf: card(cam, .new, fullRect, m, 1.0, facingShade(m, 0.5), true))
        }
        return v
    }

    private static func gallery(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The slides hang on a wall: it turns away and recedes, the slides slide along it, then it turns
        // back. A faint reflection shows below.
        let cam = Cam(a: a, d: 2.5)
        let side = right ? 1.0 : -1.0
        let k = ss(win(t, 0.0, 0.35)) * (1.0 - ss(win(t, 0.7, 1.0)))
        let s = q2(win(t, 0.3, 0.8))
        let gap = 0.15
        let back = 0.7 * k
        let yaw = -side * 22.0 * k
        var v = [Layer.full(.black, 1.0)]
        for (src, shift) in [(Source.old, side * s), (Source.new, side * (s - 1.0))] {
            let x0 = shift * (a + gap)
            let pts = cam.rect(fullRect).map { p in v3(p.x + x0, p.y, p.z + back) }.map { p in p.yaw(v3(0.0, 0.0, back), yaw) }
            // Reflection: the slide flipped below its bottom edge, faint.
            let refl = Corners3(pts[3], pts[2], v3(pts[2].x, pts[2].y + 0.25, pts[2].z), v3(pts[3].x, pts[3].y + 0.25, pts[3].z))
            let rq = cam.quad(refl)
            v.append(Layer(
                source: src,
                src: R(0.0, 0.75, 1.0, 1.0),
                quad: rq,
                uv: Quad(P(0.0, 1.0), P(1.0, 1.0), P(1.0, 0.75), P(0.0, 0.75)),
                alpha: 0.3 * k,
                fade: SIMD4(1.0, 1.0, 0.0, 0.0)
            ))
            v.append(contentsOf: card(cam, src, fullRect, pts, 1.0, 0.0, true))
        }
        return v
    }

    private static func conveyor(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The contents ride a belt: it turns away, the contents slide along, it turns back; the backgrounds
        // cross-fade underneath.
        let cam = Cam(a: a, d: 2.5)
        let side = right ? 1.0 : -1.0
        let k = ss(win(t, 0.0, 0.35)) * (1.0 - ss(win(t, 0.65, 1.0)))
        let s = q2(win(t, 0.33, 0.75))
        let back = 0.45 * k
        let yaw = -side * 18.0 * k
        var v = [Layer.full(.oldBack, 1.0), Layer.full(.newBack, ss(t))]
        for (src, shift) in [(Source.oldContent, side * s), (Source.newContent, side * (s - 1.0))] {
            let x0 = shift * a * 1.05
            let pts = cam.rect(fullRect).map { p in v3(p.x + x0, p.y, p.z + back) }.map { p in p.yaw(v3(0.0, 0.0, back), yaw) }
            v.append(contentsOf: card(cam, src, fullRect, pts, 1.0, 0.0, true))
        }
        return v
    }

    private static func prism(_ kind: String, _ o: String, _ t: Double, _ a: Double) -> [Layer] {
        // Cube: the slides are two faces of a cube turning; Box: two inside walls of a box; Rotate and Orbit:
        // the same with the contents only, over cross-fading backgrounds.
        let (dx, dy) = dir(o, (-1.0, 0.0))
        let vertical = dy != 0.0 && dx == 0.0
        let content = kind == "rotate" || kind == "orbit"
        let inverted = kind == "box" || kind == "orbit"
        let cam = Cam(a: a, d: 2.5)
        let s = q2(t)
        let half = vertical ? 0.5 : a / 2.0
        // Faces on a cube around (0, 0, half) (outside), or the inside of a box around (0, 0, -half).
        let c = v3(0.0, 0.0, inverted ? -half : half)
        // Positive turns the right (or top) side away.
        let sign = vertical ? -dy : dx
        let deg = 90.0 * s * sign * (inverted ? -1.0 : 1.0)
        func turn(_ p: V3, _ base: Double) -> V3 { vertical ? p.pitch(c, base + deg) : p.yaw(c, base + deg) }
        let sideBase = -90.0 * sign * (inverted ? -1.0 : 1.0)
        let (os, ns): (Source, Source) = content ? (.oldContent, .newContent) : (.old, .new)
        let old0 = cam.rect(fullRect).map { turn($0, 0.0) }
        let new0 = cam.rect(fullRect).map { turn($0, sideBase) }
        // Keep the nearest edge on the screen plane, as PowerPoint's camera does.
        let near = (old0.all + new0.all).map(\.z).reduce(Double.infinity) { $0.rustMin($1) }
        let lift = inverted ? 0.0 : -near.rustMin(0.0) - near.rustMax(0.0)
        // The box is seen from further back mid-turn.
        let back = (inverted ? 0.5 : 0.15) * Darwin.sin(s * pi)
        func push(_ q: Corners3) -> Corners3 { q.map { p in v3(p.x, p.y, p.z + lift + back) } }
        let (old, new) = (push(old0), push(new0))
        var v = content ? [Layer.full(.oldBack, 1.0), Layer.full(.newBack, ss(t))] : [Layer.full(.black, 1.0)]
        v.append(contentsOf: card(cam, os, fullRect, old, 1.0, content ? 0.0 : facingShade(old, 0.6), false))
        v.append(contentsOf: card(cam, ns, fullRect, new, 1.0, content ? 0.0 : facingShade(new, 0.6), false))
        return v
    }

    private static func doors(_ window: Bool, _ horz: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The old slide parts in two halves that swing open toward the viewer and darken; the new one comes
        // forward from the middle, fading in over them. Window does it with the contents only, over
        // cross-fading backgrounds.
        let cam = Cam(a: a, d: 2.2)
        let open = ein(win(t, 0.05, 0.68))
        let come = q2(win(t, 0.0, 0.72))
        let (os, ns): (Source, Source) = window ? (.oldContent, .newContent) : (.old, .new)
        var v = window ? [Layer.full(.oldBack, 1.0), Layer.full(.newBack, ss(t))] : [Layer.full(.black, 1.0)]
        let halves: [(R, Double)] = horz
            ? [(R(0.0, 0.0, 1.0, 0.5), -1.0), (R(0.0, 0.5, 1.0, 1.0), 1.0)]
            : [(R(0.0, 0.0, 0.5, 1.0), -1.0), (R(0.5, 0.0, 1.0, 1.0), 1.0)]
        if open < 1.0 {
            for (r, sgn) in halves {
                let hinge = horz ? cam.unit(0.5, sgn < 0.0 ? 0.0 : 1.0) : cam.unit(sgn < 0.0 ? 0.0 : 1.0, 0.5)
                let ang = 30.0 * open
                let slide = 0.55 * open
                let pts = cam.rect(r).map { p -> V3 in
                    let q = horz ? p.pitch(hinge, sgn * ang) : p.yaw(hinge, -sgn * ang)
                    return horz ? v3(q.x, q.y + sgn * slide, q.z) : v3(q.x + sgn * slide * a, q.y, q.z)
                }
                let dark = window ? 0.0 : 0.7 * open
                let alpha = window ? 1.0 - ss(win(t, 0.2, 0.6)) : 1.0
                v.append(contentsOf: card(cam, os, r, pts, alpha, dark, true))
            }
        }
        let sc = 0.5 + 0.5 * come
        let fadeIn = window ? ss(t) : ss(win(t, 0.05, 0.62))
        v.append(scaled(ns, sc, 0.5, 0.5, 0.0, 0.0, fadeIn))
        return v
    }

    private static func ferris(_ right: Bool, _ t: Double, _ a: Double) -> [Layer] {
        // The contents ride a big wheel turning about a hub far off the lower corner: the old ones drop away
        // down and sideways, the new ones come down round from the top, over cross-fading backgrounds.
        let side = right ? -1.0 : 1.0
        var v = [Layer.full(.oldBack, 1.0), Layer.full(.newBack, ss(t))]
        let out = ein(win(t, 0.0, 0.5))
        if out < 1.0 {
            let (dx, dy) = (-side * 0.45 * Darwin.pow(out, 1.5), 0.9 * out)
            let q = rotQuad(corners(offset(fullRect, dx, dy)), P(0.5 + dx, 0.5 + dy), side * -15.0 * out, a)
            v.append(Layer.quad(.oldContent, fullRect, q, 1.0))
        }
        let inn = q2(win(t, 0.5, 1.0))
        if inn > 0.0 {
            let k = 1.0 - inn
            let (dx, dy) = (-side * 0.5 * Darwin.pow(k, 1.3), -0.75 * k)
            let r = offset(scaleRect(fullRect, 1.0 - 0.25 * k), dx, dy)
            let q = rotQuad(corners(r), center(r), side * -18.0 * k, a)
            v.append(Layer.quad(.newContent, fullRect, q, 1.0))
        }
        return v
    }

    private static func pan(_ o: String, _ t: Double) -> [Layer] {
        // The contents slide along together while the backgrounds cross-fade.
        let (dx, dy) = dir(o, (-1.0, 0.0))
        // Quick start, long glide.
        let s = ease(t, 0.2, 0.8, 0.0)
        return [
            Layer.full(.oldBack, 1.0),
            Layer.full(.newBack, s),
            moved(.oldContent, dx * s, dy * s, 1.0),
            moved(.newContent, dx * (s - 1.0), dy * (s - 1.0), 1.0),
        ]
    }

    private static func flythrough(_ o: String, _ t: Double) -> [Layer] {
        // The contents fly past the viewer (in) or recede (out) while the backgrounds cross-fade.
        let bounce = o.bytesHaveSuffix("Bounce")
        let out = o.bytesHavePrefix("out")
        let s = q2(t)
        let b = bounce ? 0.08 * Darwin.sin(win(t, 0.6, 1.0) * pi) : 0.0
        let oldA = 1.0 - ss(win(t, 0.0, 0.6))
        let newA = ss(win(t, 0.3, 0.95))
        let (os, ns) = out ? (1.0 - 0.5 * s, 1.8 - 0.8 * s - b) : (1.0 + 1.5 * s, 0.4 + 0.6 * s + b)
        return [
            Layer.full(.oldBack, 1.0),
            Layer.full(.newBack, ss(t)),
            scaled(.newContent, ns, 0.5, 0.5, 0.0, 0.0, newA),
            scaled(.oldContent, os, 0.5, 0.5, 0.0, 0.0, oldA),
        ]
    }
}
