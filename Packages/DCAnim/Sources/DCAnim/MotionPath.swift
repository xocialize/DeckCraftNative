// DCAnim — motion paths: deckcraft's SVG-like syntax (`M x y L x y C x1 y1 x2 y2 x y Q x1 y1 x y Z E`,
// lowercase = relative) in slide-fraction units, relative to the shape's start position. Positions are
// evaluated by arc length. Port of deckcraft crates/anim/src/path.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel
import Darwin

private let maxTokens = 100_000
private let maxPoints = 20_000
private let curveSteps = 16

/// A flattened motion path.
public struct MotionPath: Sendable, Equatable {
    /// Polyline vertices (slide fractions).
    public private(set) var points: [Point] = []
    /// Cumulative arc length at each vertex.
    private var cum: [Double] = []

    public init() {}

    private enum Tok {
        case cmd(Unicode.Scalar)
        case num(Double)
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    /// Does an exponent start at `cs[i]` (`e` then a digit, or a sign and a digit)?
    private static func exponentFollows(_ cs: [Unicode.Scalar], _ i: Int) -> Bool {
        let space: Unicode.Scalar = " "
        let n1 = cs.at(i + 1) ?? space
        let n2 = cs.at(i + 2) ?? space
        return isDigit(n1) || ((n1 == "-" || n1 == "+") && isDigit(n2))
    }

    private static func tokenize(_ s: String) -> [Tok] {
        let cs = Array(s.unicodeScalars.prefix(1_000_000))
        var out: [Tok] = []
        var i = 0
        let space: Unicode.Scalar = " "
        while i < cs.count && out.count < maxTokens {
            let c = cs.at(i) ?? space
            if c.properties.isWhitespace || c == "," {
                i += 1
                continue
            }
            if isDigit(c) || c == "." || c == "-" || c == "+" {
                let start = i
                i += 1
                var seenDot = c == "."
                while let d = cs.at(i) {
                    if isDigit(d) {
                        i += 1
                    } else if d == "." && !seenDot {
                        seenDot = true
                        i += 1
                    } else if d == "e" || d == "E", exponentFollows(cs, i) {
                        i += 2
                        while let e = cs.at(i), isDigit(e) { i += 1 }
                        break
                    } else {
                        break
                    }
                }
                var text = String.UnicodeScalarView()
                text.append(contentsOf: cs[start ..< Swift.min(i, cs.count)])
                if let v = rustParseF64(String(text)), v.isFinite {
                    out.append(.num(v))
                } else {
                    out.append(.cmd("?"))
                }
                continue
            }
            out.append(.cmd(c))
            i += 1
        }
        return out
    }

    private static func isLower(_ c: Unicode.Scalar) -> Bool { c.value >= 0x61 && c.value <= 0x7A }

    private static func upper(_ c: Unicode.Scalar) -> Unicode.Scalar {
        isLower(c) ? Unicode.Scalar(UInt8(c.value - 32)) : c
    }

    /// Parse a path. Malformed input yields the part parsed before the error (possibly empty).
    public static func parse(_ s: String) -> MotionPath {
        let toks = tokenize(s)
        var pts: [Point] = []
        var cur = Point(0.0, 0.0)
        var start = Point(0.0, 0.0)
        var cmd: Unicode.Scalar = "M"
        var i = 0
        func push(_ p: Point) {
            if pts.count < maxPoints { pts.append(p) }
        }
        func num(_ i: Int) -> Double? {
            if case .num(let v)? = toks.at(i) { return v }
            return nil
        }
        loop: while i < toks.count {
            if case .cmd(let c)? = toks.at(i) {
                cmd = c
                i += 1
                switch cmd {
                case "Z", "z":
                    push(start)
                    cur = start
                    continue loop
                case "E", "e":
                    break loop
                case "M", "m", "L", "l", "C", "c", "Q", "q", "H", "h", "V", "v":
                    continue loop
                default:
                    break loop
                }
            }
            let rel = isLower(cmd)
            let base = rel ? cur : Point(0.0, 0.0)
            let need: Int
            switch upper(cmd) {
            case "M", "L": need = 2
            case "C": need = 6
            case "Q": need = 4
            case "H", "V": need = 1
            default: break loop
            }
            var v = [Double](repeating: 0.0, count: 6)
            var ok = true
            for k in 0 ..< need {
                if let x = num(i + k) { v[k] = x } else { ok = false }
            }
            if !ok { break loop }
            i += need
            switch upper(cmd) {
            case "M":
                cur = Point(base.x + v[0], base.y + v[1])
                start = cur
                // A move inside a motion path is a jump; it stays continuous as a segment.
                push(cur)
                cmd = rel ? "l" : "L"
            case "L":
                if pts.isEmpty { push(cur) }
                cur = Point(base.x + v[0], base.y + v[1])
                push(cur)
            case "H", "V":
                if pts.isEmpty { push(cur) }
                cur = upper(cmd) == "H" ? Point(base.x + v[0], cur.y) : Point(cur.x, base.y + v[0])
                push(cur)
            case "C":
                if pts.isEmpty { push(cur) }
                let p0 = cur
                let p1 = Point(base.x + v[0], base.y + v[1])
                let p2 = Point(base.x + v[2], base.y + v[3])
                let p3 = Point(base.x + v[4], base.y + v[5])
                for k in 1 ... curveSteps {
                    let t = Double(k) / Double(curveSteps)
                    let u = 1.0 - t
                    let a = u * u * u
                    let b = 3.0 * u * u * t
                    let c = 3.0 * u * t * t
                    let d = t * t * t
                    push(Point(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y))
                }
                cur = p3
            case "Q":
                if pts.isEmpty { push(cur) }
                let p0 = cur
                let p1 = Point(base.x + v[0], base.y + v[1])
                let p2 = Point(base.x + v[2], base.y + v[3])
                for k in 1 ... curveSteps {
                    let t = Double(k) / Double(curveSteps)
                    let u = 1.0 - t
                    push(Point(u * u * p0.x + 2.0 * u * t * p1.x + t * t * p2.x, u * u * p0.y + 2.0 * u * t * p1.y + t * t * p2.y))
                }
                cur = p2
            default:
                break loop
            }
        }
        pts.removeAll { !($0.x.isFinite && $0.y.isFinite) }
        var cum: [Double] = []
        cum.reserveCapacity(pts.count)
        var acc = 0.0
        var prev: Point?
        for p in pts {
            if let q = prev {
                let dx = p.x - q.x, dy = p.y - q.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d.isFinite { acc += d }
            }
            cum.append(acc)
            prev = p
        }
        var mp = MotionPath()
        mp.points = pts
        mp.cum = cum
        return mp
    }

    /// Total arc length (slide fractions).
    public var length: Double { cum.last ?? 0.0 }

    /// Position at arc-length fraction `p` (0...1), relative to the path's origin (0, 0).
    public func at(_ p0: Double) -> (Double, Double) {
        let first = points.first ?? Point(0.0, 0.0)
        let len = length
        if len.isNaN || len <= 0.0 || !len.isFinite { return (first.x, first.y) }
        let p = clampf(p0, 0.0, 1.0, 0.0)
        let target = p * len
        // `partition_point(|c| c < target)`: `cum` never decreases.
        var lo = 0, hi = cum.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if cum[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        let i = lo
        if i == 0 { return (first.x, first.y) }
        guard let a = points.at(i - 1), let b = points.at(i), let ca = cum.at(i - 1), let cb = cum.at(i) else {
            let l = points.last ?? first
            return (l.x, l.y)
        }
        let seg = cb - ca
        let f = seg > 0.0 ? (target - ca) / seg : 0.0
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
}

private func polygon(_ n: Int, _ r: Double, _ rot0: Double) -> String {
    // Regular polygon through (0, 0), centred below it.
    var s = "M 0 0"
    let c = (0.0, r)
    let a0 = -(Double.pi / 2) + rot0
    let (s0, c0) = sinCos(a0)
    let start = (c.0 + r * c0, c.1 + r * s0)
    for k in 1 ... Swift.max(n, 1) {
        let a = a0 + 2 * Double.pi * Double(k) / Double(n)
        let (sa, ca) = sinCos(a)
        s += " L \(rustFixed(c.0 + r * ca - start.0, places: 4)) \(rustFixed(c.1 + r * sa - start.1, places: 4))"
    }
    s += " E"
    return s
}

/// The path a preset motion-path effect uses when the animation has none of its own.
public func defaultPath(_ effect: String, _ option: String) -> String {
    let (sx, sy, swap): (Double, Double, Bool) = switch option {
    case "up": (1.0, -1.0, false)
    case "right": (1.0, 1.0, true)
    case "left": (-1.0, 1.0, true)
    default: (1.0, 1.0, false)
    }
    // Base paths go down; `swap` turns them to the horizontal.
    func tr(_ pts: [(Double, Double)]) -> [(Double, Double)] {
        pts.map { x, y in swap ? (y * sx, x * sy) : (x * sx, y * sy) }
    }
    func fmt(_ head: String, _ pts: [(Double, Double)]) -> String {
        var s = head
        for (x, y) in pts { s += " \(rustFixed(x, places: 4)) \(rustFixed(y, places: 4))" }
        s += " E"
        return s
    }
    switch effect {
    case "lines": return fmt("M 0 0 L", tr([(0.0, 0.25)]))
    case "arcs": return fmt("M 0 0 C", tr([(0.1, 0.05), (0.1, 0.2), (0.0, 0.25)]))
    case "turns":
        let p = tr([(0.0, 0.12), (0.0, 0.2), (0.05, 0.25), (0.12, 0.25)])
        var s = "M 0 0"
        if let (x, y) = p.first { s += " L \(rustFixed(x, places: 4)) \(rustFixed(y, places: 4)) C" }
        for (x, y) in p.dropFirst() { s += " \(rustFixed(x, places: 4)) \(rustFixed(y, places: 4))" }
        s += " E"
        return s
    case "shapes":
        switch option {
        case "diamond": return polygon(4, 0.1, 0.0)
        case "hexagon": return polygon(6, 0.1, 0.0)
        case "triangle": return polygon(3, 0.1, 0.0)
        case "square": return polygon(4, 0.1, Double.pi / 4)
        case "octagon": return polygon(8, 0.1, 0.0)
        case "pentagon": return polygon(5, 0.1, 0.0)
        case "trapezoid": return "M 0 0 L 0.1 0 L 0.15 0.15 L -0.05 0.15 Z E"
        case "parallelogram": return "M 0 0 L 0.15 0 L 0.1 0.15 L -0.05 0.15 Z E"
        default:
            return "M 0 0 C 0.0552 0 0.1 0.0448 0.1 0.1 C 0.1 0.1552 0.0552 0.2 0 0.2 C -0.0552 0.2 -0.1 0.1552 -0.1 0.1 C -0.1 0.0448 -0.0552 0 0 0 Z E"
        }
    case "loops": return "M 0 0 C 0.08 -0.1 0.16 0 0.08 0.05 C 0 0.1 -0.08 0.1 -0.08 0 C -0.08 -0.1 0 -0.05 0 0 E"
    default: return presetPath(effect) ?? ""
    }
}
