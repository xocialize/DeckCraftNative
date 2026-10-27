// DCPPTX — DrawingML custom geometry (`a:custGeom`): guide formula evaluation and conversion of
// `a:pathLst` to our `M L C Q Z` path syntax, and back. Port of deckcraft crates/pptx/src/custgeom.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Formulas follow the ECMA-376 shape guide semantics (§20.1.9.11): angles are in 1/60 000 degree, and
// every operand is a guide name, a built-in variable or an integer literal. Numbers are written as
// deckcraft writes them (`{}` of an `f64`, DCCore's `rustDisplay`), and the trigonometry is the
// system libm's, as Rust's `f64` methods are on macOS.
import DCCore
import DCGeometry
import DCModel
import Darwin

/// The `custgeom` module.
enum CustGeom {
    static let deg = 60_000.0

    static func toRad(_ a: Double) -> Double {
        a / deg * Double.pi / 180.0
    }

    static func toAng(_ r: Double) -> Double {
        r * 180.0 / Double.pi * deg
    }

    static func finite(_ v: Double) -> Double {
        v.isFinite ? v.clamped(-1.0e15, 1.0e15) : 0.0
    }

    /// `num`: rounded to 1/1000; integral values as integers.
    static func num(_ s: inout String, _ v: Double) {
        let v = finite(v)
        let r = (v * 1000.0).rounded() / 1000.0
        if r == r.rounded(.towardZero) {
            s += String(Int64(rustCast: r))
        } else {
            s += r.rustDisplay
        }
    }

    static func pt(_ g: Guides, _ e: XMLEl) -> (Double, Double) {
        (g.get(e.attr("x") ?? "0"), g.get(e.attr("y") ?? "0"))
    }

    /// Convert `a:custGeom` to custom paths. `wEMU`/`hEMU` is the shape size in EMU (used for guides
    /// and for paths that don't give their own coordinate space).
    static func readCustGeom(_ cg: XMLEl, _ wEMU: Double, _ hEMU: Double) -> [CustomPath] {
        var out: [CustomPath] = []
        guard let pl = cg.child("pathLst") else { return out }
        for p in pl.childrenNamed("path").prefix(1000) {
            let pw = p.f64("w") ?? 0.0
            let ph = p.f64("h") ?? 0.0
            // Guides are evaluated in the path's own space when it has one.
            let (gw, gh) = pw > 0.0 || ph > 0.0 ? (pw, ph) : (wEMU, hEMU)
            var g = Guides(gw, gh)
            g.evalList(cg.child("avLst"))
            g.evalList(cg.child("gdLst"))
            var d = ""
            var cur = (0.0, 0.0)
            var start = (0.0, 0.0)
            for c in p.elements.prefix(100_000) {
                switch c.local {
                case "moveTo":
                    if let q = c.child("pt") {
                        cur = pt(g, q)
                        start = cur
                        d += "M "
                        num(&d, cur.0)
                        d += " "
                        num(&d, cur.1)
                        d += " "
                    }
                case "lnTo":
                    if let q = c.child("pt") {
                        cur = pt(g, q)
                        d += "L "
                        num(&d, cur.0)
                        d += " "
                        num(&d, cur.1)
                        d += " "
                    }
                case "cubicBezTo":
                    let pts = c.childrenNamed("pt").map { pt(g, $0) }
                    if pts.count == 3 {
                        d += "C "
                        for (x, y) in pts {
                            num(&d, x)
                            d += " "
                            num(&d, y)
                            d += " "
                        }
                        cur = pts[2]
                    }
                case "quadBezTo":
                    let pts = c.childrenNamed("pt").map { pt(g, $0) }
                    if pts.count == 2 {
                        d += "Q "
                        for (x, y) in pts {
                            num(&d, x)
                            d += " "
                            num(&d, y)
                            d += " "
                        }
                        cur = pts[1]
                    }
                case "arcTo":
                    let wr = g.get(c.attr("wR") ?? "0")
                    let hr = g.get(c.attr("hR") ?? "0")
                    let st = g.get(c.attr("stAng") ?? "0")
                    let sw = g.get(c.attr("swAng") ?? "0")
                    cur = arcTo(&d, cur, wr, hr, st, sw)
                case "close":
                    d += "Z "
                    cur = start
                default:
                    break
                }
            }
            let fill: FillMode = switch p.attr("fill") ?? "norm" {
            case "none": FillMode.none
            case "lighten": .lighten
            case "lightenLess": .lightenLess
            case "darken": .darken
            case "darkenLess": .darkenLess
            default: .norm
            }
            let (ow, oh) = pw > 0.0 || ph > 0.0 ? (pw, ph) : (wEMU.rustMax(1.0), hEMU.rustMax(1.0))
            out.append(CustomPath(w: ow, h: oh, d: String(rustTrimEnd(d[...])), fill: fill, stroke: p.bool("stroke") ?? true))
        }
        return out
    }

    /// Ellipse parametric angle for a visual angle `a` (radians).
    static func param(_ a: Double, _ wr: Double, _ hr: Double) -> Double {
        atan2(wr * sin(a), hr * cos(a))
    }

    /// Append an elliptical arc as cubic Béziers; returns the end point.
    static func arcTo(_ d: inout String, _ cur: (Double, Double), _ wr: Double, _ hr: Double, _ st: Double, _ sw: Double) -> (Double, Double) {
        if Swift.abs(wr) < 1e-9 || Swift.abs(hr) < 1e-9 || sw == 0.0 {
            return cur
        }
        let stR = toRad(st)
        let swR = toRad(sw).clamped(-4.0 * Double.pi, 4.0 * Double.pi)
        let t0 = param(stR, wr, hr)
        var t1 = param(stR + swR, wr, hr)
        // Keep the sweep direction and size of the visual angle.
        let full = Swift.abs(swR) >= 2.0 * Double.pi - 1e-9
        if full {
            t1 = t0 + swR.rustSignum * 2.0 * Double.pi
        } else {
            while swR > 0.0 && t1 < t0 { t1 += 2.0 * Double.pi }
            while swR < 0.0 && t1 > t0 { t1 -= 2.0 * Double.pi }
        }
        let cx = cur.0 - wr * cos(t0)
        let cy = cur.1 - hr * sin(t0)
        let total = t1 - t0
        let n = Swift.min(Swift.max(Int(rustCast: (Swift.abs(total) / (Double.pi / 2.0)).rounded(.up)), 1), 16)
        let step = total / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4.0)
        var a = t0
        var end = cur
        for _ in 0 ..< n {
            let b = a + step
            let (ca, sa, cb, sb) = (cos(a), sin(a), cos(b), sin(b))
            let p1 = (cx + wr * (ca - k * sa), cy + hr * (sa + k * ca))
            let p2 = (cx + wr * (cb + k * sb), cy + hr * (sb - k * cb))
            end = (cx + wr * cb, cy + hr * sb)
            d += "C "
            for (x, y) in [p1, p2, end] {
                num(&d, x)
                d += " "
                num(&d, y)
                d += " "
            }
            a = b
        }
        return end
    }

    /// Parse our path syntax into commands: `M`/`L` take 2 numbers, `C` 6, `Q` 4, `Z`/`E` none;
    /// coordinates repeated after `M` continue as `L`. At most 1,000,000 commands.
    static func parsePath(_ d: String) -> [(Character, [Double])] {
        var out: [(Character, [Double])] = []
        var cmd: Character?
        var nums: [Double] = []
        func flush() {
            if let c = cmd {
                let n = switch c {
                case "M", "L": 2
                case "C": 6
                case "Q": 4
                default: 0
                }
                if n == 0 {
                    out.append((c, []))
                } else {
                    var i = 0
                    var at = 0
                    while at < nums.count {
                        let chunk = Array(nums[at ..< Swift.min(at + n, nums.count)])
                        if chunk.count == n && out.count < 1_000_000 {
                            // Repeated coordinates after M continue as L.
                            out.append((c == "M" && i > 0 ? "L" : c, chunk))
                        }
                        at += n
                        i += 1
                    }
                }
            }
            nums.removeAll()
        }
        var token = ""
        func pushTok() {
            if !token.isEmpty {
                if let v = rustParseF64(token), v.isFinite { nums.append(v) }
                token = ""
            }
        }
        for ch in d.unicodeScalars {
            switch ch {
            case "M", "L", "C", "Q", "Z", "m", "l", "c", "q", "z", "E":
                pushTok()
                flush()
                cmd = Character(ch.properties.isLowercase && ch.isASCII ? Unicode.Scalar(ch.value - 32) ?? ch : ch)
            case " ", ",", "\t", "\n":
                pushTok()
            case "-" where !token.isEmpty && !hasByteSuffix(token, "e"):
                pushTok()
                token.unicodeScalars.append(ch)
            default:
                token.unicodeScalars.append(ch)
            }
        }
        pushTok()
        flush()
        return out
    }

    /// Write custom paths as `a:custGeom`. Coordinates are integers in the file, so small path spaces
    /// are scaled up.
    static func writeCustGeom(_ w: inout W, _ paths: [CustomPath]) {
        w.open0("a:custGeom")
        w.empty0("a:avLst")
        w.empty0("a:gdLst")
        w.empty0("a:ahLst")
        w.empty0("a:cxnLst")
        w.empty("a:rect", A().a("l", "l").a("t", "t").a("r", "r").a("b", "b"))
        w.open0("a:pathLst")
        for p in paths {
            let (pw, ph) = (Swift.abs(finite(p.w)), Swift.abs(finite(p.h)))
            let m = pw.rustMax(ph)
            let k = m > 0.0 && m < 20_000.0 ? 100_000.0 / m : 1.0
            func r(_ v: Double) -> Int64 { Int64(rustCast: (finite(v) * k).rounded().clamped(-2.0e9, 2.0e9)) }
            let fill: String? = switch p.fill {
            case .norm: nil
            case .none: "none"
            case .lighten: "lighten"
            case .lightenLess: "lightenLess"
            case .darken: "darken"
            case .darkenLess: "darkenLess"
            }
            let a = A().a("w", Swift.max(r(pw), 0)).a("h", Swift.max(r(ph), 0)).o("fill", fill).o("stroke", p.stroke ? nil : "0")
            w.open("a:path", a)
            for (c, v) in parsePath(p.d) {
                var pts: [(Int64, Int64)] = []
                var i = 0
                while i + 1 < v.count {
                    pts.append((r(v[i]), r(v[i + 1])))
                    i += 2
                }
                let tag: String
                switch c {
                case "M": tag = "a:moveTo"
                case "L": tag = "a:lnTo"
                case "C": tag = "a:cubicBezTo"
                case "Q": tag = "a:quadBezTo"
                case "Z":
                    w.empty0("a:close")
                    continue
                default:
                    continue
                }
                w.open0(tag)
                for (x, y) in pts {
                    w.empty("a:pt", A().a("x", x).a("y", y))
                }
                w.close(tag)
            }
            w.close("a:path")
        }
        w.close("a:pathLst")
        w.close("a:custGeom")
    }
}

/// Guide variables for one shape (`custgeom::Guides`).
struct Guides {
    private var vars: [ByteKey: Double]

    /// Built-in variables for a shape `w` × `h` (in the shape's coordinate units).
    init(_ w: Double, _ h: Double) {
        let (w, h) = (CustGeom.finite(w), CustGeom.finite(h))
        let ss = w.rustMin(h)
        let ls = w.rustMax(h)
        var v: [ByteKey: Double] = [:]
        func set(_ k: String, _ x: Double) { v[ByteKey(k)] = x }
        set("w", w)
        set("h", h)
        set("l", 0.0)
        set("t", 0.0)
        set("r", w)
        set("b", h)
        set("hc", w / 2.0)
        set("vc", h / 2.0)
        set("ss", ss)
        set("ls", ls)
        for d in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 16.0, 32.0] {
            set("wd" + d.rustDisplay, w / d)
            set("hd" + d.rustDisplay, h / d)
            set("ssd" + d.rustDisplay, ss / d)
        }
        set("cd2", 10_800_000.0)
        set("cd4", 5_400_000.0)
        set("cd8", 2_700_000.0)
        set("3cd4", 16_200_000.0)
        set("3cd8", 8_100_000.0)
        set("5cd8", 13_500_000.0)
        set("7cd8", 18_900_000.0)
        vars = v
    }

    /// A guide, built-in or literal (trimmed); anything else is 0.
    func get(_ name: String) -> Double {
        let name = rustTrim(name)
        if let v = vars[ByteKey(String(name))] { return v }
        return rustParseF64(name).map(CustGeom.finite) ?? 0.0
    }

    /// Set a guide (at most 10,000 variables).
    mutating func set(_ name: String, _ v: Double) {
        if vars.count < 10_000 {
            vars[ByteKey(name)] = CustGeom.finite(v)
        }
    }

    /// Evaluate one formula (`*/ w 1 2`).
    func eval(_ fmla: String) -> Double {
        let words = splitWhitespace(fmla)
        let op = words.first ?? ""
        let args = words.dropFirst().prefix(3).map { get(String($0)) }
        func a(_ i: Int) -> Double { args.at(i) ?? 0.0 }
        func div(_ n: Double, _ d: Double) -> Double { d == 0.0 ? 0.0 : n / d }
        let r: Double = switch op {
        case "*/": div(a(0) * a(1), a(2))
        case "+-": a(0) + a(1) - a(2)
        case "+/": div(a(0) + a(1), a(2))
        case "?:": a(0) > 0.0 ? a(1) : a(2)
        case "abs": Swift.abs(a(0))
        case "at2": CustGeom.toAng(atan2(a(1), a(0)))
        case "cat2": a(0) * cos(atan2(a(2), a(1)))
        case "sat2": a(0) * sin(atan2(a(2), a(1)))
        case "cos": a(0) * cos(CustGeom.toRad(a(1)))
        case "sin": a(0) * sin(CustGeom.toRad(a(1)))
        case "tan": a(0) * tan(CustGeom.toRad(a(1)))
        case "max": a(0).rustMax(a(1))
        case "min": a(0).rustMin(a(1))
        case "mod": (a(0) * a(0) + a(1) * a(1) + a(2) * a(2)).squareRoot()
        case "pin": a(1) < a(0) ? a(0) : (a(1) > a(2) ? a(2) : a(1))
        case "sqrt": a(0).rustMax(0.0).squareRoot()
        case "val": a(0)
        default: 0.0
        }
        return CustGeom.finite(r)
    }

    /// Evaluate a list of `a:gd` elements in order (at most 5,000).
    mutating func evalList(_ list: XMLEl?) {
        guard let list else { return }
        for gd in list.childrenNamed("gd").prefix(5000) {
            guard let name = gd.attr("name"), let f = gd.attr("fmla") else { continue }
            let v = eval(f)
            set(name, v)
        }
    }
}

/// Rust's `str::split_whitespace`: pieces between runs of Unicode `White_Space`, none empty.
func splitWhitespace(_ s: String) -> [Substring] {
    var out: [Substring] = []
    var start: String.Index?
    var i = s.startIndex
    while i < s.endIndex {
        let next = s.unicodeScalars.index(after: i)
        if s.unicodeScalars[i].properties.isWhitespace {
            if let st = start {
                out.append(s[st ..< i])
                start = nil
            }
        } else if start == nil {
            start = i
        }
        i = next
    }
    if let st = start { out.append(s[st...]) }
    return out
}
