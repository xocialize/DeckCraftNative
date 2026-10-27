// DCEngine — Insert › Icons: Lucide stroke icons as custom geometry.
// Port of deckcraft crates/engine/src/icons.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), with kurbo 0.13.1's SVG path parser (`BezPath::from_svg`, src/svg.rs) and its elliptical arc
// to cubic conversion (`Arc::from_svg_arc`, `Arc::append_iter`, src/arc.rs) (Apache-2.0 OR MIT, © the Kurbo
// Authors), so the converted paths are deckcraft's to the digit.
//
// The paths in `IconData.swift` are Lucide 1.56.0 centerlines (24×24, fill none). They are converted to
// DeckCraft's `M`/`L`/`C`/`Q`/`Z` syntax when inserted, so the shape is a stroked outline rather than a filled
// silhouette or an SVG picture.
import DCCore
import DCGeometry
import Foundation

public enum Icons {
    /// Design size of every icon, in path units. Lucide's viewBox is `0 0 24 24`.
    public static let view = 24.0

    /// One icon from the Insert gallery.
    public struct Icon: Sendable {
        public let name: String
        public let label: String
        public let category: String
        /// Design stroke width in viewBox units (Lucide's default is 2).
        public let stroke: Double
        /// SVG path data. Independent subpaths (separate SVG elements) are separated by ` | `.
        public let d: String
    }

    /// Every icon, in gallery order.
    public static var icons: [Icon] { all }

    /// `name` is the Lucide id (`arrow-right`, `arrow_right`) or the gallery label (`Arrow right`).
    public static func find(_ name: String) -> Icon? {
        let raw = String(rustTrim(name))
        if raw.isEmpty { return nil }
        let key = rustASCIILowercase(raw).replacingOccurrences(of: "_", with: "-")
        return all.first { $0.name == key || InsertCommands.eqIgnoreASCIICase($0.label, raw) }
    }

    /// The icon's outline in the 24×24 viewBox.
    public static func outline(_ name: String) -> BezPath? {
        guard let icon = find(name) else { return nil }
        return parsed[icon.name]
    }

    /// DeckCraft path syntax for `name`, in the 24×24 viewBox.
    public static func pathData(_ name: String) -> String? {
        outline(name).flatMap(deckPath)
    }

    /// Stroke width in points for a shape `w`×`h` points. Lucide's stroke is `stroke` units on a 24-unit
    /// box, so a 72 pt icon is a 6 pt line. Resizing the shape later does not change it.
    public static func strokeWidth(_ icon: Icon, _ w: Double, _ h: Double) -> Double {
        let span = abs(w.rustMin(h)).rustMin(4_000.0)
        let design = icon.stroke.isFinite && icon.stroke > 0.0 ? icon.stroke : 2.0
        return (span * design / view).clamped(0.25, 400.0)
    }

    private static let parsed: [String: BezPath] = {
        var m: [String: BezPath] = [:]
        for icon in all {
            if let bp = bezpath(icon.d) { m[icon.name] = bp }
        }
        return m
    }()

    /// Parse SVG path data, one independent subpath at a time (` | ` resets the current point).
    static func bezpath(_ d: String) -> BezPath? {
        var out = BezPath()
        for part in d.components(separatedBy: " | ") {
            let part = String(rustTrim(part))
            if part.isEmpty { continue }
            guard let bp = SVGPath.parse(part) else { return nil }
            for el in bp.elements { out.push(el) }
        }
        return out.elements.isEmpty ? nil : out
    }

    static func deckPath(_ bp: BezPath) -> String? {
        var out = ""
        var started = false
        func push(_ cmd: String) {
            if !out.isEmpty { out += " " }
            out += cmd
        }
        for el in bp.elements {
            switch el {
            case .moveTo(let p):
                push("M \(num(p.x)) \(num(p.y))")
                started = true
            case .lineTo(let p) where started:
                push("L \(num(p.x)) \(num(p.y))")
            case .quadTo(let a, let b) where started:
                push("Q \(num(a.x)) \(num(a.y)) \(num(b.x)) \(num(b.y))")
            case .curveTo(let a, let b, let c) where started:
                push("C \(num(a.x)) \(num(a.y)) \(num(b.x)) \(num(b.y)) \(num(c.x)) \(num(c.y))")
            case .closePath where started:
                out += " Z"
            default:
                break
            }
        }
        return out.isEmpty ? nil : out
    }

    static func num(_ v: Double) -> String {
        if !v.isFinite { return "0" }
        var s = Substring(rustFixed(v, places: 4))
        while s.hasSuffix("0") { s = s.dropLast() }
        while s.hasSuffix(".") { s = s.dropLast() }
        return s == "-0" ? "0" : String(s)
    }
}

/// kurbo's `BezPath::from_svg` (src/svg.rs): SVG path data to a path, arcs as cubics (tolerance 0.1).
enum SVGPath {
    private struct Lexer {
        let data: [UInt8]
        var ix = 0
        var lastPt = Point(0, 0)

        mutating func skipWs() {
            while ix < data.count {
                let c = data[ix]
                if !(c == 0x20 || c == 9 || c == 10 || c == 12 || c == 13) { break }
                ix += 1
            }
        }

        mutating func getByte() -> UInt8? {
            guard ix < data.count else { return nil }
            ix += 1
            return data[ix - 1]
        }

        mutating func unget() { ix = max(ix - 1, 0) }

        static func isAlpha(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        static func isLower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }

        mutating func getCmd(_ lastCmd: UInt8) -> UInt8? {
            skipWs()
            if let c = getByte() {
                if Self.isAlpha(c) { return c }
                if lastCmd != 0 && (c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || Self.isDigit(c)) {
                    unget()
                    return lastCmd
                }
                unget()
            }
            return nil
        }

        mutating func getNumber() -> Double? {
            skipWs()
            let start = ix
            guard let c = getByte() else { return nil }
            if !(c == UInt8(ascii: "-") || c == UInt8(ascii: "+")) { unget() }
            var digits = 0
            var seenPeriod = false
            while let c = getByte() {
                if Self.isDigit(c) {
                    digits += 1
                } else if c == UInt8(ascii: "."), !seenPeriod {
                    seenPeriod = true
                } else {
                    unget()
                    break
                }
            }
            if let c = getByte() {
                if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                    guard var c = getByte() else { return nil }
                    if c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                        guard let d = getByte() else { return nil }
                        c = d
                    }
                    if !Self.isDigit(c) { return nil }
                    while let c = getByte() {
                        if !Self.isDigit(c) {
                            unget()
                            break
                        }
                    }
                } else {
                    unget()
                }
            }
            guard digits > 0, start <= ix, ix <= data.count else { return nil }
            return rustParseF64(String(decoding: data[start ..< ix], as: UTF8.self))
        }

        mutating func getFlag() -> Bool? {
            skipWs()
            switch getByte() {
            case UInt8(ascii: "0"): return false
            case UInt8(ascii: "1"): return true
            default: return nil
            }
        }

        mutating func getNumberPair() -> Point? {
            guard let x = getNumber() else { return nil }
            optComma()
            guard let y = getNumber() else { return nil }
            optComma()
            return Point(x, y)
        }

        mutating func getMaybeRelative(_ cmd: UInt8) -> Point? {
            guard let pt = getNumberPair() else { return nil }
            return Self.isLower(cmd) ? Point(lastPt.x + pt.x, lastPt.y + pt.y) : pt
        }

        mutating func optComma() {
            skipWs()
            if let c = getByte(), c != UInt8(ascii: ",") { unget() }
        }
    }

    static func parse(_ text: String) -> BezPath? {
        var lexer = Lexer(data: Array(text.utf8))
        var path = BezPath()
        var lastCmd: UInt8 = 0
        var lastCtrl: Point?
        var firstPt = Point(0, 0)
        var implicitMoveto: Point?
        func reflect(_ ctrl: Point?, _ last: Point) -> Point {
            guard let c = ctrl else { return last }
            return Point(2.0 * last.x - c.x, 2.0 * last.y - c.y)
        }
        while let c = lexer.getCmd(lastCmd) {
            if c != UInt8(ascii: "m") && c != UInt8(ascii: "M") {
                if path.elements.isEmpty { return nil }
                if let pt = implicitMoveto {
                    implicitMoveto = nil
                    path.moveTo(pt)
                }
            }
            switch c {
            case UInt8(ascii: "m"), UInt8(ascii: "M"):
                implicitMoveto = nil
                guard let pt = lexer.getMaybeRelative(c) else { return nil }
                path.moveTo(pt)
                lexer.lastPt = pt
                firstPt = pt
                lastCtrl = pt
                lastCmd = c - (UInt8(ascii: "M") - UInt8(ascii: "L"))
            case UInt8(ascii: "l"), UInt8(ascii: "L"):
                guard let pt = lexer.getMaybeRelative(c) else { return nil }
                path.lineTo(pt)
                lexer.lastPt = pt
                lastCtrl = pt
                lastCmd = c
            case UInt8(ascii: "h"), UInt8(ascii: "H"):
                guard var x = lexer.getNumber() else { return nil }
                lexer.optComma()
                if c == UInt8(ascii: "h") { x += lexer.lastPt.x }
                let pt = Point(x, lexer.lastPt.y)
                path.lineTo(pt)
                lexer.lastPt = pt
                lastCtrl = pt
                lastCmd = c
            case UInt8(ascii: "v"), UInt8(ascii: "V"):
                guard var y = lexer.getNumber() else { return nil }
                lexer.optComma()
                if c == UInt8(ascii: "v") { y += lexer.lastPt.y }
                let pt = Point(lexer.lastPt.x, y)
                path.lineTo(pt)
                lexer.lastPt = pt
                lastCtrl = pt
                lastCmd = c
            case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                guard let p1 = lexer.getMaybeRelative(c), let p2 = lexer.getMaybeRelative(c) else { return nil }
                path.quadTo(p1, p2)
                lastCtrl = p1
                lexer.lastPt = p2
                lastCmd = c
            case UInt8(ascii: "t"), UInt8(ascii: "T"):
                let p1 = reflect(lastCtrl, lexer.lastPt)
                guard let p2 = lexer.getMaybeRelative(c) else { return nil }
                path.quadTo(p1, p2)
                lastCtrl = p1
                lexer.lastPt = p2
                lastCmd = c
            case UInt8(ascii: "c"), UInt8(ascii: "C"):
                guard let p1 = lexer.getMaybeRelative(c), let p2 = lexer.getMaybeRelative(c), let p3 = lexer.getMaybeRelative(c) else { return nil }
                path.curveTo(p1, p2, p3)
                lastCtrl = p2
                lexer.lastPt = p3
                lastCmd = c
            case UInt8(ascii: "s"), UInt8(ascii: "S"):
                let p1 = reflect(lastCtrl, lexer.lastPt)
                guard let p2 = lexer.getMaybeRelative(c), let p3 = lexer.getMaybeRelative(c) else { return nil }
                path.curveTo(p1, p2, p3)
                lastCtrl = p2
                lexer.lastPt = p3
                lastCmd = c
            case UInt8(ascii: "a"), UInt8(ascii: "A"):
                guard let radii = lexer.getNumberPair(), let rot = lexer.getNumber() else { return nil }
                lexer.optComma()
                guard let large = lexer.getFlag() else { return nil }
                lexer.optComma()
                guard let sweep = lexer.getFlag() else { return nil }
                lexer.optComma()
                guard let p = lexer.getMaybeRelative(c) else { return nil }
                if let arc = SVGArc.toArc(from: lexer.lastPt, to: p, radii: radii, xRotation: rot.toRadians, largeArc: large, sweep: sweep) {
                    for (p1, p2, p3) in arc.cubics(0.1) { path.curveTo(p1, p2, p3) }
                } else {
                    path.lineTo(p)
                }
                lastCtrl = p
                lexer.lastPt = p
                lastCmd = c
            case UInt8(ascii: "z"), UInt8(ascii: "Z"):
                path.closePath()
                lexer.lastPt = firstPt
                implicitMoveto = firstPt
            default:
                return nil
            }
        }
        return path
    }
}

/// kurbo's `Arc` (src/arc.rs) and `Arc::from_svg_arc` (src/svg.rs).
struct SVGArc {
    var center: Point
    var radii: Vec2
    var startAngle: Double
    var sweepAngle: Double
    var xRotation: Double

    static func toArc(from: Point, to: Point, radii: Point, xRotation: Double, largeArc: Bool, sweep: Bool) -> SVGArc? {
        // A straight line: no arc.
        if abs(radii.x) <= 1e-5 || abs(radii.y) <= 1e-5 || from == to { return nil }
        var rx = abs(radii.x)
        var ry = abs(radii.y)
        let xr = xRotation.truncatingRemainder(dividingBy: 2.0 * Double.pi)
        let sinPhi = sin(xr)
        let cosPhi = cos(xr)
        let hdX = (from.x - to.x) * 0.5
        let hdY = (from.y - to.y) * 0.5
        let hsX = (from.x + to.x) * 0.5
        let hsY = (from.y + to.y) * 0.5
        // F6.5.1
        let p = Vec2(cosPhi * hdX + sinPhi * hdY, -sinPhi * hdX + cosPhi * hdY)
        // F6.6.2: radii too small to reach the end points are scaled up.
        let rf = p.x * p.x / (rx * rx) + p.y * p.y / (ry * ry)
        if rf > 1.0 {
            let scale = rf.squareRoot()
            rx *= scale
            ry *= scale
        }
        let rxry = rx * ry
        let rxpy = rx * p.y
        let rypx = ry * p.x
        let sumOfSq = rxpy * rxpy + rypx * rypx
        // F6.5.2
        let signCoe = largeArc == sweep ? -1.0 : 1.0
        let coe = signCoe * abs((rxry * rxry - sumOfSq) / sumOfSq).squareRoot()
        let tcx = coe * rxpy / ry
        let tcy = -coe * rypx / rx
        // F6.5.3
        let center = Point(cosPhi * tcx - sinPhi * tcy + hsX, sinPhi * tcx + cosPhi * tcy + hsY)
        let startV = Vec2((p.x - tcx) / rx, (p.y - tcy) / ry)
        let endV = Vec2((-p.x - tcx) / rx, (-p.y - tcy) / ry)
        let startAngle = startV.atan2
        var sweepAngle = (endV.atan2 - startAngle).truncatingRemainder(dividingBy: 2.0 * Double.pi)
        if sweep && sweepAngle < 0.0 {
            sweepAngle += 2.0 * Double.pi
        } else if !sweep && sweepAngle > 0.0 {
            sweepAngle -= 2.0 * Double.pi
        }
        return SVGArc(center: center, radii: Vec2(rx, ry), startAngle: startAngle, sweepAngle: sweepAngle, xRotation: xRotation)
    }

    private static func sampleEllipse(_ radii: Vec2, _ xRotation: Double, _ angle: Double) -> Vec2 {
        let u = radii.x * cos(angle)
        let v = radii.y * sin(angle)
        let s = sin(xRotation)
        let c = cos(xRotation)
        return Vec2(u * c - v * s, u * s + v * c)
    }

    /// `Arc::append_iter(tolerance)`: the arc as cubic Béziers.
    func cubics(_ tolerance: Double) -> [(Point, Point, Point)] {
        let sign = sweepAngle.rustSignum
        let scaledErr = radii.x.rustMax(radii.y) / tolerance
        let nErr = pow(1.1163 * scaledErr, 1.0 / 6.0).rustMax(3.999_999)
        let nf = (nErr * abs(sweepAngle) * (1.0 / (2.0 * Double.pi))).rounded(.up)
        let angleStep = sweepAngle / nf
        // Bounded: a hostile radius can't ask for an unbounded number of segments.
        let n = min(Int(rustCast: nf), 100_000)
        let armLen = (4.0 / 3.0) * abs(tan(0.25 * angleStep)) * sign
        var angle0 = startAngle
        var p0 = Self.sampleEllipse(radii, xRotation, angle0)
        var out: [(Point, Point, Point)] = []
        for _ in 0 ..< max(n, 0) {
            let angle1 = angle0 + angleStep
            let p1 = p0 + armLen * Self.sampleEllipse(radii, xRotation, angle0 + Double.pi / 2)
            let p3 = Self.sampleEllipse(radii, xRotation, angle1)
            let p2 = p3 - armLen * Self.sampleEllipse(radii, xRotation, angle1 + Double.pi / 2)
            angle0 = angle1
            p0 = p3
            out.append((center + p1, center + p2, center + p3))
        }
        return out
    }
}
