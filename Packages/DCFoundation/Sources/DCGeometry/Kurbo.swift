// DCGeometry — the kurbo value types deckcraft builds on: `Point`, `Vec2`, `Size`, `Rect`, `Affine`.
// Ported from kurbo 0.13.1 (MIT OR Apache-2.0, © the kurbo authors), keeping its formulas and operand
// order so results match deckcraft's to the bit. CoreGraphics types appear only at the rendering
// boundary, never in the model.
import DCCore
import Darwin

// MARK: - Rust float semantics

// Rust's `f64::min`/`max` lower to AArch64 `fminnm`/`fmaxnm`: a NaN operand is ignored, and -0 orders
// below +0. `f64::clamp` passes NaN and -0 through untouched. Swift's `min`/`max` differ on signed
// zeros, which changes bit patterns, so ported geometry uses these.

/// Rust's `a.min(b)` (IEEE minNum, -0 < +0).
@inlinable
func fmin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return b }
    if b.isNaN { return a }
    if a == b { return a.sign == .minus ? a : b }
    return a < b ? a : b
}

/// Rust's `a.max(b)` (IEEE maxNum, -0 < +0).
@inlinable
func fmax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return b }
    if b.isNaN { return a }
    if a == b { return a.sign == .plus ? a : b }
    return a > b ? a : b
}

extension Double {
    /// Rust's `f64::clamp(lo, hi)`.
    @inlinable
    func clamp(_ lo: Double, _ hi: Double) -> Double {
        var x = self
        if x < lo { x = lo }
        if x > hi { x = hi }
        return x
    }

    /// Rust's `f64::rem_euclid`.
    @inlinable
    func remEuclid(_ rhs: Double) -> Double {
        let r = truncatingRemainder(dividingBy: rhs)
        return r < 0 ? r + Swift.abs(rhs) : r
    }

    /// Rust's `f64::signum`: ±1 by the sign bit, NaN for NaN.
    @inlinable
    var signum: Double {
        if isNaN { return .nan }
        return sign == .minus ? -1.0 : 1.0
    }

    /// Rust's `f64::copysign`.
    @inlinable
    func copysign(_ s: Double) -> Double {
        Double(signOf: s, magnitudeOf: self)
    }

    /// Rust's `f64::to_radians` (`self * (PI / 180)`).
    @inlinable
    var radians: Double { self * (Double.pi / 180.0) }

    /// Rust's `f64::to_degrees` (`self * (180 / PI)`).
    @inlinable
    var degrees: Double { self * (180.0 / Double.pi) }
}

/// `sin` and `cos` of one value from Darwin's `__sincos_stret`. Rust's release builds compute a sine and
/// cosine of the same value in one basic block with that call (LLVM merges the pair), and it rounds
/// differently from separate `sin`/`cos` for about 0.14% of inputs; calling it explicitly gives deckcraft's
/// bits in debug and release alike. Constant arguments are folded by LLVM with separate calls, so those
/// sites keep `Darwin.sin`/`Darwin.cos`.
@inlinable
func sinCos(_ x: Double) -> (sin: Double, cos: Double) {
    let r = __sincos_stret(x)
    return (r.__sinval, r.__cosval)
}

/// Rust's `x as usize` (saturating, NaN → 0), as an `Int`.
@inlinable
func asUsize(_ x: Double) -> Int {
    Int(clamping: UInt64(rustCast: x))
}

// MARK: - Point

public struct Point: Sendable, Hashable, JSONCodable {
    public var x: Double
    public var y: Double

    public static let zero = Point(0, 0)

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public var toVec2: Vec2 { Vec2(x, y) }

    public func distance(_ other: Point) -> Double { (self - other).hypot }

    public func distanceSquared(_ other: Point) -> Double { (self - other).hypot2 }

    public func lerp(_ other: Point, _ t: Double) -> Point {
        (toVec2.lerp(other.toVec2, t)).toPoint
    }

    public func midpoint(_ other: Point) -> Point {
        Point(0.5 * (x + other.x), 0.5 * (y + other.y))
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }

    /// Bitwise equality as Rust's derived `PartialEq` sees it (`-0 == +0`, NaN ≠ NaN).
    public static func == (a: Point, b: Point) -> Bool { a.x == b.x && a.y == b.y }

    public static func + (p: Point, v: Vec2) -> Point { Point(p.x + v.x, p.y + v.y) }
    public static func - (p: Point, v: Vec2) -> Point { Point(p.x - v.x, p.y - v.y) }
    public static func - (p: Point, q: Point) -> Vec2 { Vec2(p.x - q.x, p.y - q.y) }
    public static func += (p: inout Point, v: Vec2) { p = p + v }

    // serde (kurbo `serde` feature): a derived struct, {"x","y"}.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("x", x)
        o.put("y", y)
        return .object(o)
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Point")
        self.init(try f.required("x"), try f.required("y"))
    }
}

// MARK: - Vec2

public struct Vec2: Sendable, Hashable, JSONCodable {
    public var x: Double
    public var y: Double

    public static let zero = Vec2(0, 0)

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public var toPoint: Point { Point(x, y) }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }
    /// The z component of the cross product (`x * other.y - y * other.x`).
    public func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }
    /// kurbo's magnitude: `hypot2().sqrt()`, not libm `hypot`.
    public var hypot: Double { hypot2.squareRoot() }
    public var hypot2: Double { dot(self) }
    public var length: Double { hypot }
    public var atan2: Double { Darwin.atan2(y, x) }

    public static func fromAngle(_ th: Double) -> Vec2 {
        Vec2(sinCos(th).cos, sinCos(th).sin)
    }

    /// `self + t * (other - self)`.
    public func lerp(_ other: Vec2, _ t: Double) -> Vec2 { self + t * (other - self) }

    /// The unit vector in this direction (NaN components for the zero vector, as in kurbo).
    public var normalize: Vec2 { self / hypot }
    public var turn90: Vec2 { Vec2(-y, x) }

    public static func == (a: Vec2, b: Vec2) -> Bool { a.x == b.x && a.y == b.y }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(s * a.x, s * a.y) }
    /// kurbo divides by multiplying with the reciprocal.
    public static func / (a: Vec2, s: Double) -> Vec2 { a * (1.0 / s) }

    // serde: a derived struct, {"x","y"}.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("x", x)
        o.put("y", y)
        return .object(o)
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Vec2")
        self.init(try f.required("x"), try f.required("y"))
    }
}

// MARK: - Size

public struct Size: Sendable, Hashable, JSONCodable {
    public var width: Double
    public var height: Double

    public static let zero = Size(0, 0)

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public var toVec2: Vec2 { Vec2(width, height) }

    public static func == (a: Size, b: Size) -> Bool { a.width == b.width && a.height == b.height }

    // serde: a derived struct, {"width","height"}.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("width", width)
        o.put("height", height)
        return .object(o)
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Size")
        self.init(try f.required("width"), try f.required("height"))
    }
}

// MARK: - Rect

/// An axis-aligned rectangle by its edges, as kurbo keeps it: (`x0`, `y0`) to (`x1`, `y1`).
public struct Rect: Sendable, Hashable, JSONCodable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public static let zero = Rect(0, 0, 0, 0)

    public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    /// The rectangle spanning two points, whatever their order.
    public static func fromPoints(_ p0: Point, _ p1: Point) -> Rect {
        Rect(p0.x, p0.y, p1.x, p1.y).abs
    }

    public static func fromOrigin(_ origin: Point, size: Size) -> Rect {
        fromPoints(origin, origin + size.toVec2)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var origin: Point { Point(x0, y0) }
    public var size: Size { Size(width, height) }
    public var area: Double { width * height }
    public var center: Point { Point(0.5 * (x0 + x1), 0.5 * (y0 + y1)) }
    public var minX: Double { fmin(x0, x1) }
    public var maxX: Double { fmax(x0, x1) }
    public var minY: Double { fmin(y0, y1) }
    public var maxY: Double { fmax(y0, y1) }
    public var isFinite: Bool { x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite }

    /// The same rectangle with positive width and height.
    public var abs: Rect {
        Rect(fmin(x0, x1), fmin(y0, y1), fmax(x0, x1), fmax(y0, y1))
    }

    public func contains(_ p: Point) -> Bool {
        p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1
    }

    public func union(_ other: Rect) -> Rect {
        Rect(fmin(x0, other.x0), fmin(y0, other.y0), fmax(x1, other.x1), fmax(y1, other.y1))
    }

    public func unionPoint(_ p: Point) -> Rect {
        Rect(fmin(x0, p.x), fmin(y0, p.y), fmax(x1, p.x), fmax(y1, p.y))
    }

    public func intersect(_ other: Rect) -> Rect {
        let nx0 = fmax(x0, other.x0)
        let ny0 = fmax(y0, other.y0)
        let nx1 = fmin(x1, other.x1)
        let ny1 = fmin(y1, other.y1)
        return Rect(nx0, ny0, fmax(nx1, nx0), fmax(ny1, ny0))
    }

    public func inflate(_ width: Double, _ height: Double) -> Rect {
        Rect(x0 - width, y0 - height, x1 + width, y1 + height)
    }

    /// kurbo's `rect.inset(d)` with uniform insets: the normalised rectangle grown by `d` on every side
    /// (a negative `d` shrinks it).
    public func inset(_ d: Double) -> Rect {
        let r = abs
        return Rect(r.x0 - d, r.y0 - d, r.x1 + d, r.y1 + d)
    }

    public static func == (a: Rect, b: Rect) -> Bool {
        a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1
    }

    // serde: a derived struct, {"x0","y0","x1","y1"}.
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("x0", x0)
        o.put("y0", y0)
        o.put("x1", x1)
        o.put("y1", y1)
        return .object(o)
    }

    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Rect")
        self.init(try f.required("x0"), try f.required("y0"), try f.required("x1"), try f.required("y1"))
    }
}

// MARK: - Affine

/// A 2-D affine transform `[a, b, c, d, e, f]`, mapping (x, y) to (a·x + c·y + e, b·x + d·y + f).
/// `p * q` applies `q` first, then `p`, as in kurbo.
public struct Affine: Sendable, Hashable {
    public var coeffs: (Double, Double, Double, Double, Double, Double)

    public static let identity = Affine(1, 0, 0, 1, 0, 0)

    public init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        coeffs = (a, b, c, d, e, f)
    }

    public static func translate(_ v: Vec2) -> Affine { Affine(1, 0, 0, 1, v.x, v.y) }
    public static func scale(_ s: Double) -> Affine { Affine(s, 0, 0, s, 0, 0) }
    public static func scaleNonUniform(_ sx: Double, _ sy: Double) -> Affine { Affine(sx, 0, 0, sy, 0, 0) }

    public static func rotate(_ th: Double) -> Affine {
        let s = sinCos(th).sin
        let c = sinCos(th).cos
        return Affine(c, s, -s, c, 0, 0)
    }

    public var determinant: Double { coeffs.0 * coeffs.3 - coeffs.1 * coeffs.2 }

    /// The inverse (non-finite for a singular transform, as in kurbo).
    public var inverse: Affine {
        let (a, b, c, d, e, f) = coeffs
        let invDet = 1.0 / determinant
        return Affine(
            invDet * d, -invDet * b, -invDet * c, invDet * a,
            invDet * (c * f - d * e), invDet * (b * e - a * f)
        )
    }

    public var translation: Vec2 { Vec2(coeffs.4, coeffs.5) }

    public var isFinite: Bool {
        coeffs.0.isFinite && coeffs.1.isFinite && coeffs.2.isFinite
            && coeffs.3.isFinite && coeffs.4.isFinite && coeffs.5.isFinite
    }

    /// The bounding box of `rect` after this transform.
    public func transformRectBBox(_ rect: Rect) -> Rect {
        let p00 = self * Point(rect.x0, rect.y0)
        let p01 = self * Point(rect.x0, rect.y1)
        let p10 = self * Point(rect.x1, rect.y0)
        let p11 = self * Point(rect.x1, rect.y1)
        return Rect.fromPoints(p00, p01).union(Rect.fromPoints(p10, p11))
    }

    public static func * (m: Affine, p: Point) -> Point {
        let (a, b, c, d, e, f) = m.coeffs
        return Point(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    public static func * (m: Affine, o: Affine) -> Affine {
        let (a, b, c, d, e, f) = m.coeffs
        let (oa, ob, oc, od, oe, of) = o.coeffs
        return Affine(
            a * oa + c * ob,
            b * oa + d * ob,
            a * oc + c * od,
            b * oc + d * od,
            a * oe + c * of + e,
            b * oe + d * of + f
        )
    }

    public static func == (l: Affine, r: Affine) -> Bool {
        l.coeffs == r.coeffs
    }

    public func hash(into h: inout Hasher) {
        h.combine(coeffs.0)
        h.combine(coeffs.1)
        h.combine(coeffs.2)
        h.combine(coeffs.3)
        h.combine(coeffs.4)
        h.combine(coeffs.5)
    }
}
