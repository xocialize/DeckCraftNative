// DCGeometry — units, shape transforms and helpers. Port of deckcraft crates/geom/src/lib.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The document model keeps positions in points (1/72 inch) as `Double`. Office Open XML stores EMU
// (English Metric Units, 12 700 per point); `emuToPt` and `ptToEmu` convert losslessly for integer EMU
// values, so files round-trip exactly.
import DCCore
import Foundation

/// EMU per point.
public let emuPerPt: Double = 12_700.0
/// EMU per inch.
public let emuPerIn: Double = 914_400.0
/// EMU per centimetre.
public let emuPerCm: Double = 360_000.0

public func emuToPt(_ emu: Int64) -> Double {
    Double(emu) / emuPerPt
}

/// Points to EMU, rounded. Non-finite input becomes 0; huge values saturate.
public func ptToEmu(_ pt: Double) -> Int64 {
    guard pt.isFinite else { return 0 }
    return Int64(rustCast: (pt * emuPerPt).rounded())
}

/// Display units for measurements (inches on US English systems, centimetres elsewhere).
public enum Unit: String, JSONStringEnum, Sendable {
    case inches
    case centimeters
    case points
    case pixels

    public static let `default` = Unit.inches

    public var pointsPerUnit: Double {
        switch self {
        case .inches: 72.0
        case .centimeters: 72.0 / 2.54
        case .points: 1.0
        case .pixels: 0.75
        }
    }

    public var suffix: String {
        switch self {
        case .inches: "\""
        case .centimeters: " cm"
        case .points: " pt"
        case .pixels: " px"
        }
    }

    /// `2.08"` style text for a length in points.
    public func format(_ pt: Double) -> String {
        let v = pt / pointsPerUnit
        return rustFixed(v, places: 2) + suffix
    }

    /// Parses `2.5`, `2.5"`, `2.5 in`, `6 cm`, `30 pt`, `40px`, `5mm` into points. A bare number uses
    /// `self`.
    public func parse(_ text: String) -> Double? {
        let t = rustASCIILowercase(String(rustTrim(text)))
        guard let (num, unit) = splitNumber(t) else { return nil }
        let ppu: Double
        switch String(rustTrim(unit)) {
        case "": ppu = pointsPerUnit
        case "\"", "in", "inch", "inches": ppu = 72.0
        case "cm": ppu = 72.0 / 2.54
        case "mm": ppu = 72.0 / 25.4
        case "pt", "pts": ppu = 1.0
        case "px": ppu = 0.75
        default: return nil
        }
        let v = num * ppu
        return v.isFinite ? v : nil
    }
}

/// The leading number of `t` (digits, `.`, `-`, `+`) parsed as Rust's `f64::from_str`, and the rest.
private func splitNumber(_ t: String) -> (Double, String)? {
    let end = t.firstIndex { !($0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+")) } ?? t.endIndex
    guard let n = rustParseFloat(String(t[..<end])) else { return nil }
    return (n, String(t[end...]))
}

/// Rust's `str::parse::<f64>` for the characters `splitNumber` keeps: an optional sign, digits and at
/// most one point, with at least one digit. Swift's `Double(_:)` also takes hex and `nan`, so the
/// shape is checked first.
func rustParseFloat(_ s: String) -> Double? {
    var body = Substring(s)
    if let f = body.first, f == "+" || f == "-" { body = body.dropFirst() }
    guard !body.isEmpty, body.filter({ $0 == "." }).count <= 1, body.contains(where: \.isNumber),
          body.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
    return Double(s.hasPrefix("+") ? String(s.dropFirst()) : s)
}

/// A shape's placement on its slide (or in its group's child space): offset, extent, rotation (degrees
/// clockwise) and flips. Rotation and flips are about the centre.
public struct Xfrm: Sendable, Hashable, JSONCodable {
    public var x: Double = 0
    public var y: Double = 0
    public var w: Double = 0
    public var h: Double = 0
    public var rot: Double = 0
    public var flipH = false
    public var flipV = false

    public init(x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0, rot: Double = 0, flipH: Bool = false, flipV: Bool = false) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rot = rot
        self.flipH = flipH
        self.flipV = flipV
    }

    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.init(x: x, y: y, w: w, h: h)
    }

    public var rect: Rect { Rect(x, y, x + w, y + h) }
    public var center: Point { Point(x + w / 2.0, y + h / 2.0) }

    /// Local shape space (0..w, 0..h) → parent space, applying flips and rotation about the centre.
    public var affine: Affine {
        let c = Vec2(w / 2.0, h / 2.0)
        let sx: Double = flipH ? -1.0 : 1.0
        let sy: Double = flipV ? -1.0 : 1.0
        return Affine.translate(Vec2(x, y) + c)
            * Affine.rotate(rot.toRadians)
            * Affine.scaleNonUniform(sx, sy)
            * Affine.translate(-c)
    }

    /// Axis-aligned bounds of the rotated box in parent space.
    public var bounds: Rect {
        let a = affine
        let pts = [Point(0, 0), Point(w, 0), Point(w, h), Point(0, h)].map { a * $0 }
        return Rect.fromPoints(pts[0], pts[1]).unionPoint(pts[2]).unionPoint(pts[3])
    }

    /// True when no dimension is NaN/inf.
    public var isFinite: Bool { [x, y, w, h, rot].allSatisfy(\.isFinite) }

    /// Rotation normalised to 0..360.
    public var rotNorm: Double {
        let r = rot.rem(360.0)
        return r < 0 ? r + 360.0 : r
    }

    // serde: `#[serde(default, rename_all = "camelCase")]`, `rot` skipped when 0, flips when false.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("x", x)
        o.put("y", y)
        o.put("w", w)
        o.put("h", h)
        o.put("rot", rot, skipIf: rot == 0)
        o.put("flipH", flipH, skipIf: !flipH)
        o.put("flipV", flipV, skipIf: !flipV)
        return .object(o)
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Xfrm")
        self.init(
            x: try f.get("x", default: 0), y: try f.get("y", default: 0),
            w: try f.get("w", default: 0), h: try f.get("h", default: 0),
            rot: try f.get("rot", default: 0),
            flipH: try f.get("flipH", default: false), flipV: try f.get("flipV", default: false)
        )
    }
}

/// Maps a group's child coordinate space (`chOff`, `chExt`) onto the group's own box.
public func groupChildAffine(_ group: Xfrm, _ ch: Rect) -> Affine {
    let sx = Swift.abs(ch.width) > 1e-9 ? group.w / ch.width : 1.0
    let sy = Swift.abs(ch.height) > 1e-9 ? group.h / ch.height : 1.0
    return group.affine * Affine.scaleNonUniform(sx, sy) * Affine.translate(-ch.origin.toVec2)
}

/// Distance from `p` to the segment `a`–`b`.
public func distToSegment(_ p: Point, _ a: Point, _ b: Point) -> Double {
    let ab = b - a
    let len2 = ab.hypot2
    if len2 < 1e-12 { return (p - a).hypot }
    let t = ((p - a).dot(ab) / len2).clamp(0.0, 1.0)
    return (p - (a + ab * t)).hypot
}

/// Snap `v` to the nearest multiple of `step` (step <= 0 returns `v`).
public func snap(_ v: Double, _ step: Double) -> Double {
    step > 0 && step.isFinite ? (v / step).rounded() * step : v
}

/// Is `p` within `tol` of the outline of `path` (flattened)?
public func nearPath(_ path: BezPath, _ p: Point, _ tol: Double) -> Bool {
    var hit = false
    var start = Point.zero
    var last = Point.zero
    flatten(path.elements, 0.25) { el in
        if hit { return }
        switch el {
        case .moveTo(let q):
            start = q
            last = q
        case .lineTo(let q):
            if distToSegment(p, last, q) <= tol { hit = true }
            last = q
        case .closePath:
            if distToSegment(p, last, start) <= tol { hit = true }
            last = start
        default:
            break
        }
    }
    return hit
}

/// Flatten a path to move/line/close elements (tolerance 0.2).
public func presetFlatten(_ path: BezPath, _ f: (PathEl) -> Void) {
    flatten(path.elements, 0.2, f)
}
