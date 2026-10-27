// DCGeometry — WordArt text warps (DrawingML `a:bodyPr/a:prstTxWarp`). Port of deckcraft
// crates/geom/src/warp.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A warp preset is a list of bands laid over the shape's text rectangle (insets are ignored). Text lines
// are shared out over the bands in order (the first ⌈n/k⌉ lines to the first band and so on). A band
// either
// - stretches its lines between a top and a bottom guide (`Band.fill`): the ink box of the band's lines
//   fills the band vertically (a band whose ink is shorter than the tallest band's keeps the same scale,
//   centred), and horizontally the text is scaled so that the widest band is filled along the mean
//   length of its guides (one scale for the whole text), or
// - sets its lines at their natural size along one guide (`Band.follow`, arches and circles): glyphs
//   keep their size, are placed by arc length (aligned as in the paragraph, the whole guide being the
//   line's width: insets don't count) and stand on the guide's left normal; lines further from the
//   guide stack outwards. Lines that are longer than the guide are shrunk to fit.
//
// Positions along a guide are by arc length; a fill band maps the same fraction of its top and bottom
// guide's length and interpolates between them. The guide curves were derived from observation: synthetic
// decks of `I` bars were drawn with PowerPoint and every curve fitted to the measured bar ends (most fit
// within a point on a 420 × 200 pt box).
import Darwin

/// A resolved warp: its bands in shape-local points.
public struct Warp: Sendable, Hashable {
    public var bands: [Band]

    public init(bands: [Band]) {
        self.bands = bands
    }

    /// Flattening tolerance for guides, in points.
    static let tol = 0.02

    // MARK: Guide

    /// A guide curve flattened to a polyline with cumulative arc lengths.
    public struct Guide: Sendable, Hashable {
        public private(set) var pts: [Point] = []
        public private(set) var cum: [Double] = []
        public private(set) var isClosed = false

        public init() {}

        init(points raw: [Point], closed: Bool) {
            var pts: [Point] = []
            var cum: [Double] = []
            for p in raw {
                if !(p.x.isFinite && p.y.isFinite) { continue }
                if let q = pts.last {
                    let d = (p - q).hypot
                    if d > 1e-9 {
                        cum.append((cum.last ?? 0.0) + d)
                        pts.append(p)
                    }
                } else {
                    pts.append(p)
                    cum.append(0.0)
                }
                if pts.count > 100_000 { break }
            }
            self.pts = pts
            self.cum = cum
            isClosed = closed
        }

        /// A guide through `path` (any curves), flattened.
        public init(path: BezPath, closed: Bool) {
            var pts: [Point] = []
            flatten(path.elements, Warp.tol) { el in
                switch el {
                case .moveTo(let p), .lineTo(let p): pts.append(p)
                default: break
                }
            }
            self.init(points: pts, closed: closed)
        }

        /// Total arc length.
        public var length: Double { cum.last ?? 0.0 }

        /// Point and unit tangent at arc length `s`. Open guides continue along their end tangents past
        /// either end; closed guides wrap.
        public func at(_ sIn: Double) -> (Point, Vec2) {
            let len = length
            guard let first = pts.first, let last = pts.last else { return (.zero, Vec2(1.0, 0.0)) }
            if pts.count < 2 || len <= 1e-9 { return (first, Vec2(1.0, 0.0)) }
            var s = sIn.isFinite ? sIn : 0.0
            if isClosed { s = s.remEuclid(len) }
            let n = pts.count
            let i: Int
            if s <= 0.0 {
                i = 0
            } else if s >= len {
                i = n - 2
            } else {
                // partition_point(|c| c <= s), less one, saturating, at most n - 2.
                var lo = 0, hi = cum.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if cum[mid] <= s { lo = mid + 1 } else { hi = mid }
                }
                i = Swift.min(Swift.max(lo - 1, 0), n - 2)
            }
            let a = pts.at(i) ?? first
            let b = pts.at(i + 1) ?? last
            let c0 = cum.at(i) ?? 0.0
            let d = b - a
            let l = d.hypot
            let t = l > 1e-12 ? d / l : Vec2(1.0, 0.0)
            return (a + t * (s - c0), t)
        }

        /// The parallel curve `d` points away on the left of the direction of travel (above a guide
        /// running left to right).
        public func offset(_ d: Double) -> Guide {
            let n = pts.count
            if n < 2 || !d.isFinite || d == 0.0 { return self }
            func unit(_ i: Int) -> Vec2 {
                let a = pts.at(i) ?? .zero
                let b = pts.at(i + 1) ?? .zero
                let v = b - a
                let l = v.hypot
                return l > 1e-12 ? v / l : .zero
            }
            let out: [Point] = (0 ..< n).map { i in
                let before: Vec2 = i > 0 ? unit(i - 1) : (isClosed ? unit(n - 2) : .zero)
                let after: Vec2 = i + 1 < n ? unit(i) : (isClosed ? unit(0) : .zero)
                let t0 = before + after
                let l = t0.hypot
                let t = l > 1e-12 ? t0 / l : Vec2(1.0, 0.0)
                return (pts.at(i) ?? .zero) + Vec2(t.y, -t.x) * d
            }
            return Guide(points: out, closed: isClosed)
        }

        /// The point at fraction `t` of the length.
        public func atFrac(_ t: Double) -> Point { at(t * length).0 }
    }

    // MARK: Bands

    /// Which line of a follow band sits on its guide.
    public enum LineAnchor: Sendable, Hashable {
        /// The last line; earlier lines stack outwards (arch up, circle).
        case last
        /// The first line; later lines stack below it (arch down).
        case first
        /// The middle of the band's lines.
        case middle
    }

    public enum Band: Sendable, Hashable {
        /// Text stretched between two guides.
        case fill(top: Guide, bottom: Guide)
        /// Text at its natural size along a guide.
        case follow(path: Guide, anchor: LineAnchor)

        /// The length text is measured against: the mean of a fill band's guides.
        public var length: Double {
            switch self {
            case .fill(let top, let bottom): (top.length + bottom.length) / 2.0
            case .follow(let path, _): path.length
            }
        }
    }

    // MARK: Presets

    /// Presets whose text follows a guide at its natural size (no wrapping).
    public static func isFollow(_ name: String) -> Bool {
        ["textArchUp", "textArchDown", "textCircle", "textButton"].contains(name)
    }

    /// Default adjust values of a warp preset (`adj`, or `adj1`, `adj2`); empty for unknown presets.
    public static func adjustDefaults(_ name: String) -> [Double] {
        switch name {
        case "textPlain": [50_000.0]
        case "textStop": [25_000.0]
        case "textTriangle", "textTriangleInverted": [50_000.0]
        case "textChevron": [25_000.0]
        case "textChevronInverted": [75_000.0]
        case "textRingInside", "textRingOutside": [60_000.0]
        case "textArchUp", "textCircle", "textButton": [10_800_000.0]
        case "textArchDown": [0.0]
        case "textArchUpPour", "textCirclePour", "textButtonPour": [10_800_000.0, 50_000.0]
        case "textArchDownPour": [0.0, 25_000.0]
        case "textCurveUp", "textCurveDown": [45_977.0]
        case "textCanUp": [85_000.0]
        case "textCanDown": [14_286.0]
        case "textWave1", "textWave2": [12_500.0, 0.0]
        case "textDoubleWave1", "textWave4": [6_250.0, 0.0]
        case "textInflate", "textDeflate": [18_750.0]
        case "textInflateBottom": [60_000.0]
        case "textDeflateBottom", "textDeflateTop": [50_000.0]
        case "textInflateTop": [40_000.0]
        case "textDeflateInflate": [35_000.0]
        case "textDeflateInflateDeflate": [25_000.0]
        case "textFadeRight", "textFadeLeft", "textFadeUp", "textFadeDown": [33_333.0]
        case "textSlantUp": [55_556.0]
        case "textSlantDown": [44_444.0]
        case "textCascadeUp", "textCascadeDown": [44_444.0]
        default: []
        }
    }

    /// Number of adjust values a warp preset takes.
    public static func adjustCount(_ name: String) -> Int { adjustDefaults(name).count }

    /// Whether `name` is a warp preset deckcraft draws.
    public static func isSupported(_ name: String) -> Bool { !adjustDefaults(name).isEmpty }

    /// One DrawingML text-warp preset, in gallery order.
    public struct PresetInfo: Sendable, Hashable {
        /// `prstTxWarp` value, e.g. `textArchUp`.
        public var id: String
        /// Name shown on the Transform gallery tile.
        public var label: String
    }

    /// The 40 presets deckcraft draws, Follow Path first, then Warp.
    public static let catalog: [PresetInfo] = [
        ("textArchUp", "Arch Up"), ("textArchDown", "Arch Down"), ("textCircle", "Circle"), ("textButton", "Button"),
        ("textPlain", "Plain"), ("textStop", "Stop"), ("textTriangle", "Triangle"), ("textTriangleInverted", "Inverted Triangle"),
        ("textChevron", "Chevron"), ("textChevronInverted", "Inverted Chevron"), ("textRingInside", "Ring Inside"),
        ("textRingOutside", "Ring Outside"), ("textArchUpPour", "Arch Up Pour"), ("textArchDownPour", "Arch Down Pour"),
        ("textCirclePour", "Circle Pour"), ("textButtonPour", "Button Pour"), ("textCurveUp", "Curve Up"),
        ("textCurveDown", "Curve Down"), ("textCanUp", "Can Up"), ("textCanDown", "Can Down"), ("textWave1", "Wave 1"),
        ("textWave2", "Wave 2"), ("textDoubleWave1", "Double Wave 1"), ("textWave4", "Wave 4"), ("textInflate", "Inflate"),
        ("textDeflate", "Deflate"), ("textInflateBottom", "Inflate Bottom"), ("textDeflateBottom", "Deflate Bottom"),
        ("textInflateTop", "Inflate Top"), ("textDeflateTop", "Deflate Top"), ("textDeflateInflate", "Deflate Inflate"),
        ("textDeflateInflateDeflate", "Deflate Inflate Deflate"), ("textFadeRight", "Fade Right"), ("textFadeLeft", "Fade Left"),
        ("textFadeUp", "Fade Up"), ("textFadeDown", "Fade Down"), ("textSlantUp", "Slant Up"), ("textSlantDown", "Slant Down"),
        ("textCascadeUp", "Cascade Up"), ("textCascadeDown", "Cascade Down"),
    ].map { PresetInfo(id: $0.0, label: $0.1) }

    // MARK: Handles

    /// A yellow adjust handle for one warp guide value. `pos` is in the same space as `rect` (shape-local
    /// points). Dragging projects the pointer onto the handle's axis, or around the text rectangle's
    /// centre for an angle.
    public struct Handle: Sendable, Hashable {
        public var index: Int
        public var pos: Point
        var kind: HandleKind

        /// The raw guide value (`adj` / `adjN`) for a pointer at `p`.
        public func valueAt(_ p: Point) -> Double {
            switch kind {
            case .line(let origin, let dir, let min, let max):
                let l2 = dir.hypot2
                if l2 < 1e-18 || !(p.x.isFinite && p.y.isFinite) { return min }
                let v = (p - origin).dot(dir) / l2
                if !v.isFinite { return min }
                return v.clamp(fmin(min, max), fmax(max, min)).rounded()
            case .angle(let center, let invert):
                let d = p - center
                if !(d.x.isFinite && d.y.isFinite) || d.hypot < 1e-9 { return 0.0 }
                var deg = Darwin.atan2(d.y, d.x).degrees
                if invert { deg = 180.0 - deg }
                return (deg.remEuclid(360.0) * 60_000.0).rounded()
            }
        }
    }

    enum HandleKind: Sendable, Hashable {
        /// `pos = origin + dir * raw`. `valueAt` projects onto that line and clamps.
        case line(origin: Point, dir: Vec2, min: Double, max: Double)
        /// Angle about `center` (y down, 0° at +x). `invert` is arch-down, whose guide angle is `180° − adj`.
        case angle(center: Point, invert: Bool)
    }

    static func storedRaw(_ adj: [Double], _ defaults: [Double], _ i: Int) -> Double {
        if let v = adj.at(i), v.isFinite { return v }
        return defaults.at(i) ?? 0.0
    }

    static func unit(_ rect: Rect, _ u: Double, _ v: Double) -> Point {
        Point(rect.x0 + u * rect.width, rect.y0 + v * rect.height)
    }

    /// A fraction handle: unit position `(x, sign * frac)`, raw = frac × 100 000, clamped to `lo...hi`.
    static func fracHandle(_ rect: Rect, _ index: Int, _ x: Double, _ fracIn: Double, _ lo: Double, _ hi: Double, _ sign: Double) -> Handle {
        let frac = fracIn.clamp(lo, hi)
        return Handle(
            index: index, pos: unit(rect, x, sign * frac),
            kind: .line(origin: unit(rect, x, 0.0), dir: Vec2(0.0, sign * rect.height / 100_000.0), min: lo * 100_000.0, max: hi * 100_000.0)
        )
    }

    /// A fraction handle that slides horizontally: unit `(frac, y)`.
    static func fracXHandle(_ rect: Rect, _ index: Int, _ y: Double, _ fracIn: Double, _ lo: Double, _ hi: Double) -> Handle {
        let frac = fracIn.clamp(lo, hi)
        return Handle(
            index: index, pos: unit(rect, frac, y),
            kind: .line(origin: unit(rect, 0.0, y), dir: Vec2(rect.width / 100_000.0, 0.0), min: lo * 100_000.0, max: hi * 100_000.0)
        )
    }

    /// Angle handle, inset from the ellipse so it doesn't sit on a resize handle.
    static func angleHandle(_ rect: Rect, _ index: Int, _ deg: Double, _ invert: Bool) -> Handle {
        let geom = invert ? 180.0 - deg : deg
        let rad = geom.radians
        let c = rect.center
        return Handle(
            index: index,
            pos: Point(c.x + rect.width * 0.36 * sinCos(rad).cos, c.y + rect.height * 0.36 * sinCos(rad).sin),
            kind: .angle(center: c, invert: invert)
        )
    }

    /// Inner-ellipse radius (pour presets): the handle sits on the downward point of that ellipse.
    static func radiusHandle(_ rect: Rect, _ rIn: Double) -> Handle {
        let r = rIn.clamp(0.0, 0.99)
        return Handle(
            index: 1, pos: unit(rect, 0.5, 0.5 + 0.5 * r),
            kind: .line(origin: unit(rect, 0.5, 0.5), dir: Vec2(0.0, 0.5 * rect.height / 100_000.0), min: 0.0, max: 99_000.0)
        )
    }

    /// Wave phase: slides sideways around the middle of the lower half.
    static func shiftHandle(_ rect: Rect, _ sIn: Double) -> Handle {
        let s = sIn.clamp(-0.1, 0.1)
        return Handle(
            index: 1, pos: unit(rect, 0.5 + s, 0.78),
            kind: .line(origin: unit(rect, 0.5, 0.78), dir: Vec2(rect.width / 100_000.0, 0.0), min: -10_000.0, max: 10_000.0)
        )
    }

    /// Yellow handles for warp `name` over text rectangle `rect`. Empty when `name` isn't a drawn preset
    /// or `rect` isn't a usable box. Missing adjust values take the preset defaults.
    public static func handles(_ name: String, _ adj: [Double], _ rectIn: Rect) -> [Handle] {
        guard [rectIn.x0, rectIn.y0, rectIn.x1, rectIn.y1].allSatisfy(\.isFinite) else { return [] }
        let rect = Rect(fmin(rectIn.x0, rectIn.x1), fmin(rectIn.y0, rectIn.y1), fmax(rectIn.x0, rectIn.x1), fmax(rectIn.y0, rectIn.y1))
        if rect.width < 1e-3 || rect.height < 1e-3 { return [] }
        let defaults = adjustDefaults(name)
        if defaults.isEmpty { return [] }
        func raw(_ i: Int) -> Double { storedRaw(adj, defaults, i) }
        func frac(_ i: Int) -> Double { raw(i) / 100_000.0 }
        func deg(_ i: Int) -> Double { (raw(i) / 60_000.0).remEuclid(360.0) }
        var out: [Handle] = []
        func y(_ x: Double, _ lo: Double, _ hi: Double, _ sign: Double) { out.append(fracHandle(rect, 0, x, frac(0), lo, hi, sign)) }
        func xh(_ yy: Double, _ lo: Double, _ hi: Double) { out.append(fracXHandle(rect, 0, yy, frac(0), lo, hi)) }
        switch name {
        case "textPlain": xh(0.28, 0.3, 0.7)
        case "textStop": y(0.5, 0.14286, 0.5, 1.0)
        case "textTriangle", "textTriangleInverted": y(0.18, 0.0, 1.0, 1.0)
        case "textChevron": y(0.18, 0.0, 0.5, 1.0)
        case "textChevronInverted": y(0.18, 0.5, 1.0, 1.0)
        case "textFadeRight": y(0.82, 0.0, 0.49999, 1.0)
        case "textFadeLeft": y(0.18, 0.0, 0.49999, 1.0)
        case "textFadeUp": xh(0.22, 0.0, 0.49999)
        case "textFadeDown": xh(0.78, 0.0, 0.49999)
        case "textSlantUp": y(0.18, 0.44444, 1.0, 1.0)
        case "textSlantDown": y(0.18, 0.0, 0.55556, 1.0)
        case "textCascadeUp": y(0.82, 0.0, 1.0, 1.0)
        case "textCascadeDown": y(0.18, 0.0, 1.0, 1.0)
        case "textInflate": y(0.62, 0.0, 0.2, -1.0)
        case "textDeflate": y(0.62, 0.0, 0.375, 1.0)
        case "textInflateBottom": y(0.62, 0.6, 1.0, 1.0)
        case "textDeflateBottom": y(0.62, 0.0625, 1.0, 1.0)
        case "textInflateTop": y(0.62, 0.0, 0.5, 1.0)
        case "textDeflateTop": y(0.62, 0.0, 0.9375, 1.0)
        case "textDeflateInflate": y(0.5, 0.05, 0.95, 1.0)
        case "textDeflateInflateDeflate": y(0.5, 0.01, 1.0 / 3.0, 1.0)
        case "textCurveUp", "textCurveDown": y(0.18, 0.0, 0.56818, 1.0)
        case "textCanUp": y(0.62, 0.5, 1.0, 1.0)
        case "textCanDown": y(0.62, 0.0, 0.5, 1.0)
        case "textRingInside", "textRingOutside": y(0.5, 0.5, 0.99, 1.0)
        case "textArchUp", "textCircle", "textButton": out.append(angleHandle(rect, 0, deg(0), false))
        case "textArchDown": out.append(angleHandle(rect, 0, deg(0), true))
        case "textArchUpPour", "textCirclePour", "textButtonPour":
            out.append(angleHandle(rect, 0, deg(0), false))
            out.append(radiusHandle(rect, frac(1)))
        case "textArchDownPour":
            out.append(angleHandle(rect, 0, deg(0), true))
            out.append(radiusHandle(rect, frac(1)))
        case "textWave1", "textWave2":
            y(0.32, 0.0, 0.2, 1.0)
            out.append(shiftHandle(rect, frac(1)))
        case "textDoubleWave1", "textWave4":
            y(0.32, 0.0, 0.125, 1.0)
            out.append(shiftHandle(rect, frac(1)))
        default:
            return []
        }
        return out
    }

    // MARK: Guide specs

    /// Segments of a guide in unit coordinates (x, y in 0..1 over the text rectangle).
    enum Seg {
        case m(Double, Double)
        case l(Double, Double)
        case q(Double, Double, Double, Double)
        case c(Double, Double, Double, Double, Double, Double)
        /// Elliptical arc: centre, radii, start and sweep in degrees (y down: positive = clockwise).
        case a(Double, Double, Double, Double, Double, Double)
    }

    enum Spec {
        case fill([Seg], [Seg])
        case follow([Seg], LineAnchor)
    }

    struct Adj {
        var raw: [Double]
        var defaults: [Double]

        func raw(_ i: Int) -> Double {
            if let v = raw.at(i), v.isFinite { return v }
            return defaults.at(i) ?? 0.0
        }

        /// Adjust `i` as a fraction (1/100 000), pinned to `lo...hi` (fractions).
        func frac(_ i: Int, _ lo: Double, _ hi: Double) -> Double { (raw(i) / 100_000.0).clamp(lo, hi) }

        /// Adjust `i` as an angle in degrees (1/60 000), in 0..360.
        func angle(_ i: Int) -> Double { (raw(i) / 60_000.0).remEuclid(360.0) }
    }

    static func line(_ pts: [(Double, Double)]) -> [Seg] {
        pts.enumerated().map { $0.offset == 0 ? .m($0.element.0, $0.element.1) : .l($0.element.0, $0.element.1) }
    }

    /// Quadratic from (0, y0) through control (0.5, c) to (1, y0).
    static func quad(_ y0: Double, _ c: Double) -> [Seg] { [.m(0.0, y0), .q(0.5, c, 1.0, y0)] }

    /// A sweep in (0, 360]: zero means a full turn.
    static func turn(_ deg: Double) -> Double {
        let d = deg.remEuclid(360.0)
        return d < 1e-9 ? 360.0 : d
    }

    /// Arc of the ellipse inscribed in the rectangle, scaled by `s` about its centre.
    static func ellipse(_ s: Double, _ start: Double, _ sweep: Double) -> [Seg] { [.a(0.5, 0.5, 0.5 * s, 0.5 * s, start, sweep)] }

    /// The arch-up arc for adjust angle `a`: symmetric about the top (270°), clockwise.
    static func archUp(_ a: Double) -> (Double, Double) { (a, turn(2.0 * (270.0 - a))) }

    /// The arch-down arc for adjust angle `a`: symmetric about the bottom (90°), counter-clockwise.
    static func archDown(_ a: Double) -> (Double, Double) { (180.0 - a, -turn(180.0 - 2.0 * a)) }

    /// The circle arc for adjust angle `a`: from `a` clockwise, symmetric about 0°.
    static func circle(_ a: Double) -> (Double, Double) { (a, turn(2.0 * (360.0 - a))) }

    /// One cubic wave period from x0 to x1 at height y: up first when `k` > 0 (y decreases).
    static func wave(_ out: inout [Seg], _ x0: Double, _ x1: Double, _ y: Double, _ k: Double) {
        let l = x1 - x0
        out.append(.c(x0 + l / 3.0, y - k, x0 + 2.0 * l / 3.0, y + k, x1, y))
    }

    /// Wave guides: `periods` cubic waves over the width, shifted apart by `shift` (fraction).
    static func waves(_ a: Double, _ shift: Double, _ periods: Int, _ upFirst: Bool) -> Spec {
        let d = 2.0 * shift
        let (topX, botX) = d >= 0.0 ? ((0.0, 1.0 - d), (d, 1.0)) : ((-d, 1.0), (0.0, 1.0 + d))
        let k = upFirst ? a * 10.0 / 3.0 : -a * 10.0 / 3.0
        func guide(_ xs: (Double, Double), _ y: Double) -> [Seg] {
            let (x0, x1) = xs
            var v: [Seg] = [.m(x0, y)]
            let np = Swift.max(periods, 1)
            let n = Double(np)
            for i in 0 ..< np {
                let f = Double(i)
                wave(&v, x0 + (x1 - x0) * f / n, x0 + (x1 - x0) * (f + 1.0) / n, y, k)
            }
            return v
        }
        return .fill(guide(topX, a), guide(botX, 1.0 - a))
    }

    static func spec(_ name: String, _ a: Adj) -> [Spec]? {
        func fill(_ t: [Seg], _ b: [Seg]) -> [Spec] { [.fill(t, b)] }
        let top = line([(0.0, 0.0), (1.0, 0.0)])
        let bottom = line([(0.0, 1.0), (1.0, 1.0)])
        switch name {
        case "textPlain":
            let d = 2.0 * (a.frac(0, 0.3, 0.7) - 0.5)
            if d < 0.0 { return fill(line([(-d, 0.0), (1.0, 0.0)]), line([(0.0, 1.0), (1.0 + d, 1.0)])) }
            return fill(line([(0.0, 0.0), (1.0 - d, 0.0)]), line([(d, 1.0), (1.0, 1.0)]))
        case "textStop":
            let y = a.frac(0, 0.14286, 0.5)
            let t = 1.0 / 3.0
            return fill(line([(0.0, y), (t, 0.0), (1.0 - t, 0.0), (1.0, y)]), line([(0.0, 1.0 - y), (t, 1.0), (1.0 - t, 1.0), (1.0, 1.0 - y)]))
        case "textTriangle":
            let y = a.frac(0, 0.0, 1.0)
            return fill(line([(0.0, y), (0.5, 0.0), (1.0, y)]), bottom)
        case "textTriangleInverted":
            let y = a.frac(0, 0.0, 1.0)
            return fill(top, line([(0.0, y), (0.5, 1.0), (1.0, y)]))
        case "textChevron":
            let y = a.frac(0, 0.0, 0.5)
            return fill(line([(0.0, y), (0.5, 0.0), (1.0, y)]), line([(0.0, 1.0), (0.5, 1.0 - y), (1.0, 1.0)]))
        case "textChevronInverted":
            let y = a.frac(0, 0.5, 1.0)
            return fill(line([(0.0, 0.0), (0.5, 1.0 - y), (1.0, 0.0)]), line([(0.0, y), (0.5, 1.0), (1.0, y)]))
        case "textFadeRight":
            let y = a.frac(0, 0.0, 0.49999)
            return fill(line([(0.0, 0.0), (1.0, y)]), line([(0.0, 1.0), (1.0, 1.0 - y)]))
        case "textFadeLeft":
            let y = a.frac(0, 0.0, 0.49999)
            return fill(line([(0.0, y), (1.0, 0.0)]), line([(0.0, 1.0 - y), (1.0, 1.0)]))
        case "textFadeUp":
            let x = a.frac(0, 0.0, 0.49999)
            return fill(line([(x, 0.0), (1.0 - x, 0.0)]), bottom)
        case "textFadeDown":
            let x = a.frac(0, 0.0, 0.49999)
            return fill(top, line([(x, 1.0), (1.0 - x, 1.0)]))
        case "textSlantUp":
            let y = a.frac(0, 0.44444, 1.0)
            return fill(line([(0.0, y), (1.0, 0.0)]), line([(0.0, 1.0), (1.0, 1.0 - y)]))
        case "textSlantDown":
            let y = a.frac(0, 0.0, 0.55556)
            return fill(line([(0.0, 0.0), (1.0, 1.0 - y)]), line([(0.0, y), (1.0, 1.0)]))
        case "textCascadeUp":
            let y = a.frac(0, 0.0, 1.0)
            return fill(line([(0.0, (1.0 - y) / 4.0), (1.0, 0.0)]), line([(0.0, 1.0), (1.0, y)]))
        case "textCascadeDown":
            let y = a.frac(0, 0.0, 1.0)
            return fill(line([(0.0, 0.0), (1.0, (1.0 - y) / 4.0)]), line([(0.0, y), (1.0, 1.0)]))
        case "textInflate":
            let y = a.frac(0, 0.0, 0.2)
            return fill(quad(y, -y), quad(1.0 - y, 1.0 + y))
        case "textDeflate":
            let y = a.frac(0, 0.0, 0.375)
            return fill(quad(0.0, 2.0 * y), quad(1.0, 1.0 - 2.0 * y))
        case "textInflateBottom":
            let y = a.frac(0, 0.6, 1.0)
            return fill(top, quad(y, 1.0))
        case "textDeflateBottom":
            let y = a.frac(0, 0.0625, 1.0)
            return fill(top, quad(1.0, 2.0 * y - 1.0))
        case "textInflateTop":
            let y = a.frac(0, 0.0, 0.5)
            return fill(quad(y, 0.0), bottom)
        case "textDeflateTop":
            let y = a.frac(0, 0.0, 0.9375)
            return fill(quad(0.0, 2.0 * y), bottom)
        case "textDeflateInflate":
            // The bands are split by a curve from mid-height up to `y`, with a gap of a tenth of a band's
            // height.
            let y = a.frac(0, 0.05, 0.95)
            let g = 0.05
            return [.fill(top, quad(0.5 - g, 2.0 * y - 0.5 - g)), .fill(quad(0.5 + g, 2.0 * y - 0.5 + g), bottom)]
        case "textDeflateInflateDeflate":
            let y = a.frac(0, 0.01, 1.0 / 3.0)
            let g = 1.0 / 30.0
            let (t1, t2) = (1.0 / 3.0, 2.0 / 3.0)
            let (c1, c2) = (2.0 * y - t1, 2.0 * (1.0 - y) - t2)
            return [
                .fill(top, quad(t1 - g, c1 - g)),
                .fill(quad(t1 + g, c1 + g), quad(t2 - g, c2 - g)),
                .fill(quad(t2 + g, c2 + g), bottom),
            ]
        case "textCurveUp", "textCurveDown":
            let y = a.frac(0, 0.0, 0.56818)
            let b: [Seg] = [.m(0.0, 1.0 - 3.0 * y / 8.0), .c(1.0 / 3.0, 1.0 + y / 8.0, 2.0 / 3.0, 1.0 + y / 8.0, 1.0, 1.0 - 3.0 * y / 8.0)]
            let t: [Seg] = name == "textCurveUp"
                ? [.m(0.0, y), .c(1.0 / 3.0, 1.25 * y, 2.0 / 3.0, 0.75 * y, 1.0, 0.0)]
                : [.m(0.0, 0.0), .c(1.0 / 3.0, 0.75 * y, 2.0 / 3.0, 1.25 * y, 1.0, y)]
            return fill(t, b)
        case "textCanUp":
            let r = 1.0 - a.frac(0, 0.5, 1.0)
            return fill([.a(0.5, r, 0.5, r, 180.0, 180.0)], [.a(0.5, 1.0, 0.5, r, 180.0, 180.0)])
        case "textCanDown":
            let r = a.frac(0, 0.0, 0.5)
            return fill([.a(0.5, 0.0, 0.5, r, 180.0, -180.0)], [.a(0.5, 1.0 - r, 0.5, r, 180.0, -180.0)])
        case "textRingInside", "textRingOutside":
            let h = a.frac(0, 0.5, 0.99)
            let sweep = name == "textRingInside" ? 360.0 : -360.0
            return fill([.a(0.5, h / 2.0, 0.5, h / 2.0, 180.0, sweep)], [.a(0.5, 1.0 - h / 2.0, 0.5, h / 2.0, 180.0, sweep)])
        case "textWave1": return [waves(a.frac(0, 0.0, 0.2), a.frac(1, -0.1, 0.1), 1, true)]
        case "textWave2": return [waves(a.frac(0, 0.0, 0.2), a.frac(1, -0.1, 0.1), 1, false)]
        case "textDoubleWave1": return [waves(a.frac(0, 0.0, 0.125), a.frac(1, -0.1, 0.1), 2, true)]
        case "textWave4": return [waves(a.frac(0, 0.0, 0.125), a.frac(1, -0.1, 0.1), 2, false)]
        case "textArchUp":
            let (s, w) = archUp(a.angle(0))
            return [.follow(ellipse(1.0, s, w), .last)]
        case "textArchDown":
            let (s, w) = archDown(a.angle(0))
            return [.follow(ellipse(1.0, s, w), .first)]
        case "textCircle":
            let (s, w) = circle(a.angle(0))
            return [.follow(ellipse(1.0, s, w), .last)]
        case "textButton":
            let t = a.angle(0)
            let (s, w) = archUp(t)
            let half = 0.5 * Swift.abs(Darwin.cos(t.radians))
            return [
                .follow(ellipse(1.0, s, w), .last),
                .follow(line([(0.5 - half, 0.5), (0.5 + half, 0.5)]), .middle),
                .follow(ellipse(1.0, 360.0 - s, -w), .first),
            ]
        case "textArchUpPour":
            let (s, w) = archUp(a.angle(0))
            let r = a.frac(1, 0.0, 0.99)
            return fill(ellipse(1.0, s, w), ellipse(r, s, w))
        case "textArchDownPour":
            let (s, w) = archDown(a.angle(0))
            let r = a.frac(1, 0.0, 0.99)
            return fill(ellipse(r, s, w), ellipse(1.0, s, w))
        case "textCirclePour":
            let (s, w) = circle(a.angle(0))
            let r = a.frac(1, 0.0, 0.99)
            return fill(ellipse(1.0, s, w), ellipse(r, s, w))
        case "textButtonPour":
            let (s, w) = archUp(a.angle(0))
            let r = a.frac(1, 0.0, 0.99)
            // The middle band runs between chords of the inner ellipse halfway to its top and bottom.
            let (dy, half) = (0.25 * r, 0.25 * r * 3.0.squareRoot())
            return [
                .fill(ellipse(1.0, s, w), ellipse(r, s, w)),
                .fill(line([(0.5 - half, 0.5 - dy), (0.5 + half, 0.5 - dy)]), line([(0.5 - half, 0.5 + dy), (0.5 + half, 0.5 + dy)])),
                .fill(ellipse(r, 360.0 - s, -w), ellipse(1.0, 360.0 - s, -w)),
            ]
        default:
            return nil
        }
    }

    /// Build a guide from unit-space segments mapped onto `r`.
    static func guide(_ segs: [Seg], _ r: Rect) -> Guide {
        var p = BezPath()
        var started = false
        var closed = false
        for s in segs {
            switch s {
            case .m(let x, let y):
                p.moveTo(Point(x, y))
                started = true
            case .l(let x, let y):
                if started { p.lineTo(Point(x, y)) } else { p.moveTo(Point(x, y)) }
                started = true
            case .q(let cx, let cy, let x, let y):
                if started { p.quadTo(Point(cx, cy), Point(x, y)) }
            case .c(let x1, let y1, let x2, let y2, let x, let y):
                if started { p.curveTo(Point(x1, y1), Point(x2, y2), Point(x, y)) }
            case .a(let cx, let cy, let rx, let ry, let start, let sweep):
                let arc = Arc(Point(cx, cy), Vec2(fmax(rx, 0.0), fmax(ry, 0.0)), start.radians, sweep.radians, 0.0)
                let s0 = Point(cx + rx * sinCos(start.radians).cos, cy + ry * sinCos(start.radians).sin)
                if started { p.lineTo(s0) } else { p.moveTo(s0) }
                started = true
                p.extend(arc.appendElements(1e-5))
                closed = Swift.abs(sweep) >= 359.999
            }
        }
        p.applyAffine(Affine(r.width, 0.0, 0.0, r.height, r.x0, r.y0))
        return Guide(path: p, closed: closed)
    }

    /// The warp `name` with adjust values `adj` (raw guide values; missing ones take the defaults) over
    /// text rectangle `rect`. nil for unknown presets, `textNoShape` or a non-finite rect.
    public static func make(_ name: String, _ adj: [Double], _ rect: Rect) -> Warp? {
        guard [rect.x0, rect.y0, rect.x1, rect.y1].allSatisfy(\.isFinite) else { return nil }
        let r = Rect(fmin(rect.x0, rect.x1), fmin(rect.y0, rect.y1), fmax(rect.x0, rect.x1), fmax(rect.y0, rect.y1))
        let a = Adj(raw: adj, defaults: adjustDefaults(name))
        guard let specs = spec(name, a) else { return nil }
        let bands: [Band] = specs.map { s in
            switch s {
            case .fill(let t, let b): .fill(top: guide(t, r), bottom: guide(b, r))
            case .follow(let p, let anchor): .follow(path: guide(p, r), anchor: anchor)
            }
        }
        return Warp(bands: bands)
    }

    /// The band line `line` of `lines` goes to when there are `bands` bands: the first ⌈n/k⌉ lines share
    /// the first band, and so on.
    public static func bandOfLine(_ line: Int, _ lines: Int, _ bands: Int) -> Int {
        if bands <= 1 || lines == 0 { return 0 }
        // Band b holds lines ceil(b·n/k) .. ceil((b+1)·n/k).
        func divCeil(_ a: Int, _ b: Int) -> Int { a / b + (a % b > 0 ? 1 : 0) }
        return (0 ..< bands).reversed().first { divCeil($0 * lines, bands) <= line } ?? 0
    }

    // MARK: Mapping

    /// One laid-out line as the warp sees it (layout coordinates, points).
    public struct Line: Sendable, Hashable {
        /// Ink box of the line's glyphs; nil for a line without ink.
        public var ink: Rect?
        /// Advance extent of the line (left, right).
        public var extent: (Double, Double)
        /// Reference height for follow bands: the y that sits on the guide.
        public var refY: Double

        public init(ink: Rect?, extent: (Double, Double), refY: Double) {
            self.ink = ink
            self.extent = extent
            self.refY = refY
        }

        public static func == (a: Line, b: Line) -> Bool {
            a.ink == b.ink && a.extent == b.extent && a.refY == b.refY
        }

        public func hash(into h: inout Hasher) {
            h.combine(ink)
            h.combine(extent.0)
            h.combine(extent.1)
            h.combine(refY)
        }
    }

    enum LineMap {
        case fill(band: Int, cx: Double, k: Double, len: Double, y0: Double, y1: Double)
        /// `guide`: the line's own parallel guide in `Mapper.offsets`, if it is off the band's.
        case follow(band: Int, guide: Int?, e0: Double, s0: Double, k: Double, refY: Double)
    }

    /// Maps points of laid-out lines onto a warp.
    public struct Mapper {
        let warp: Warp
        let lines: [LineMap]
        let offsets: [Guide]
        /// How much the warp magnifies text at most (for flattening tolerances), ≥ 1.
        public let zoom: Double

        /// Map point `p` of line `line` (layout coordinates) onto the warp.
        public func map(_ line: Int, _ p: Point) -> Point {
            let out: Point
            switch lines.at(line) {
            case .fill(let band, let cx, let k, let len, let y0, let y1):
                guard case .fill(let top, let bottom) = warp.bands.at(band) else { return p }
                let u = len > 1e-9 ? 0.5 + (p.x - cx) * k / len : 0.5
                let v = y1 - y0 > 1e-9 ? (p.y - y0) / (y1 - y0) : 0.5
                let (t, b) = (top.atFrac(u), bottom.atFrac(u))
                out = t.lerp(b, v)
            case .follow(let band, let guide, let e0, let s0, let k, let refY):
                let path: Guide
                if let g = guide.flatMap({ offsets.at($0) }) {
                    path = g
                } else if case .follow(let bp, _) = warp.bands.at(band) {
                    path = bp
                } else {
                    return p
                }
                let s = s0 + (p.x - e0) * k
                let d = (refY - p.y) * k
                let (q, t) = path.at(s)
                out = q + Vec2(t.y, -t.x) * d
            case nil:
                out = p
            }
            return out.x.isFinite && out.y.isFinite ? out : p
        }
    }

    /// Plan the mapping of `lines`, laid out in the inner text box `inner` (the line's place in it gives
    /// its alignment along follow guides; the insets themselves don't shorten a guide).
    public func mapper(_ lines: [Line], _ inner: Rect) -> Mapper {
        let nb = Swift.max(bands.count, 1)
        let n = lines.count
        let bandOf: [Int] = (0 ..< n).map { Swift.min(Warp.bandOfLine($0, n, nb), nb - 1) }
        // Ink of the whole text, for the shared horizontal centre and scale of fill bands.
        let inkAll = lines.compactMap(\.ink).reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r }
        let cx = inkAll?.center.x ?? 0.0
        var kFill = Double.infinity
        var zoom = 1.0
        var bandY: [(Double, Double)?] = Array(repeating: nil, count: nb)
        for (i, l) in lines.enumerated() {
            guard let r = l.ink else { continue }
            let b = bandOf.at(i) ?? 0
            if bandY.indices.contains(b) {
                if let (y0, y1) = bandY[b] {
                    bandY[b] = (fmin(y0, r.y0), fmax(y1, r.y1))
                } else {
                    bandY[b] = (r.y0, r.y1)
                }
            }
        }
        // Every fill band maps a box as tall as the tallest band's ink, centred on its own ink, so a band
        // with fewer lines keeps them at the same size, centred between its guides.
        let tallest = bandY.compactMap { $0 }.map { $0.1 - $0.0 }.reduce(0.0, fmax)
        bandY = bandY.map { r in r.map { ((($0.0 + $0.1 - tallest) / 2.0), (($0.0 + $0.1 + tallest) / 2.0)) } }
        for (b, band) in bands.enumerated() {
            guard case .fill(let top, let bottom) = band else { continue }
            let half = lines.enumerated()
                .filter { bandOf.at($0.offset) == b }
                .compactMap(\.element.ink)
                .map { fmax(Swift.abs($0.x0 - cx), Swift.abs($0.x1 - cx)) }
                .reduce(0.0, fmax)
            if half > 1e-9 { kFill = fmin(kFill, band.length / (2.0 * half)) }
            if let entry = bandY.at(b), let (y0, y1) = entry {
                let thick = [0.0, 0.25, 0.5, 0.75, 1.0].map { (top.atFrac($0) - bottom.atFrac($0)).hypot }.reduce(0.0, fmax)
                if y1 - y0 > 1e-9 { zoom = fmax(zoom, thick / (y1 - y0)) }
            }
        }
        if !kFill.isFinite { kFill = 1.0 }
        zoom = fmax(zoom, kFill)
        var maps: [LineMap] = []
        maps.reserveCapacity(n)
        var offsets: [Guide] = []
        for (i, l) in lines.enumerated() {
            let b = bandOf.at(i) ?? 0
            let inBand = { (j: Int) in bandOf.at(j) == b }
            switch bands.at(b) {
            case .follow(let path, let anchor):
                var len = path.length
                let widest = (0 ..< n).filter(inBand).compactMap { lines.at($0) }.map { $0.extent.1 - $0.extent.0 }.reduce(0.0, fmax)
                let k = widest > len && widest > 1e-9 ? len / widest : 1.0
                let members = (0 ..< n).filter(inBand).compactMap { lines.at($0) }
                let refY: Double
                switch anchor {
                case .last: refY = members.last?.refY ?? l.refY
                case .first: refY = members.first?.refY ?? l.refY
                case .middle:
                    if let f = members.first, let z = members.last { refY = (f.refY + z.refY) / 2.0 } else { refY = l.refY }
                }
                // Lines off the guide run on a parallel curve at their natural length.
                let d = (refY - l.refY) * k
                var guide: Int?
                if Swift.abs(d) > 1e-6 && d.isFinite && offsets.count < 4096 {
                    let g = path.offset(d)
                    len = g.length
                    offsets.append(g)
                    guide = offsets.count - 1
                }
                let (e0, e1) = l.extent
                let w = fmax(e1 - e0, 0.0) * k
                let (gl, gr) = (fmax(e0 - inner.x0, 0.0), fmax(inner.x1 - e1, 0.0))
                let f = gl + gr > 1e-9 ? gl / (gl + gr) : 0.5
                let s0 = f * (len - w)
                maps.append(.follow(band: b, guide: guide, e0: e0, s0: s0, k: k, refY: l.refY))
            default:
                let (y0, y1) = (bandY.at(b) ?? nil) ?? (0.0, 1.0)
                let len = bands.at(b)?.length ?? 0.0
                maps.append(.fill(band: b, cx: cx, k: kFill, len: len, y0: y0, y1: y1))
            }
        }
        return Mapper(warp: self, lines: maps, offsets: offsets, zoom: zoom.isFinite ? zoom.clamp(1.0, 1.0e4) : 1.0)
    }
}
