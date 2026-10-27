// DCRender — small helpers every part of the renderer shares. Port of deckcraft crates/render/src/lib.rs
// (`shade`, `scale_of`, `crop_dest`, `shape_geometry`, `parse_path`, `blur`; MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

/// Largest pixmap side rendered (deckcraft's vello limit, kept for the same outputs).
public let maxRenderSide = 16_000

/// A fill shaded for a 3-D-looking face (`FillMode.lighten`…).
public func shade(_ c: Rgba, _ m: FillMode) -> Rgba {
    switch m {
    case .lighten: c.lerp(Rgba.white.withAlpha(c.a), 0.4)
    case .lightenLess: c.lerp(Rgba.white.withAlpha(c.a), 0.2)
    case .darken: c.lerp(Rgba.black.withAlpha(c.a), 0.4)
    case .darkenLess: c.lerp(Rgba.black.withAlpha(c.a), 0.2)
    default: c
    }
}

/// The uniform scale of a transform: the square root of its determinant's magnitude.
public func scaleOf(_ m: Affine) -> Double { Swift.abs(m.determinant).squareRoot() }

/// deckcraft's `blur(sigma)`: a Gaussian standard deviation, clamped as vello clamps it.
func blurSigma(_ sigma: Double) -> Double { sigma.clamped(0, 500) }

/// The rectangle a picture's image occupies given its crop (fractions; negative = padding).
public func cropDest(_ bounds: Rect, _ crop: [Double]) -> Rect {
    let c = (0 ..< 4).map { i -> Double in
        let v = crop.at(i) ?? 0
        return v.isFinite ? v.clamped(-10, 0.99) : 0
    }
    let (l, t, r, b) = (c[0], c[1], c[2], c[3])
    let visW = (1 - l - r).rustMax(1e-6)
    let visH = (1 - t - b).rustMax(1e-6)
    let fw = bounds.width / visW
    let fh = bounds.height / visH
    return Rect(bounds.x0 - l * fw, bounds.y0 - t * fh, bounds.x0 - l * fw + fw, bounds.y0 - t * fh + fh)
}

/// kurbo's `Rect::to_path`: the four corners clockwise from the top left, closed.
public func rectPath(_ r: Rect) -> BezPath {
    var p = BezPath()
    p.moveTo(Point(r.x0, r.y0))
    p.lineTo(Point(r.x1, r.y0))
    p.lineTo(Point(r.x1, r.y1))
    p.lineTo(Point(r.x0, r.y1))
    p.closePath()
    return p
}

/// `m * path`: the path transformed.
public func transformed(_ path: BezPath, _ m: Affine) -> BezPath {
    var p = path
    p.applyAffine(m)
    return p
}

/// Geometry of a shape at its size.
public func shapeGeometry(_ shape: Shape, _ w: Double, _ h: Double) -> Preset.Geometry {
    switch shape.geom {
    case .preset(let name, let adj):
        return Preset.build(name, w, h, adj) ?? Preset.build("rect", w, h, [])
            ?? Preset.Geometry(paths: [], textRect: Rect(0, 0, w, h), handles: [], sites: [])
    case .custom(let paths):
        var out: [Preset.SubPath] = []
        for p in paths {
            let pw = p.w > 0 ? p.w : w.rustMax(1e-9)
            let ph = p.h > 0 ? p.h : h.rustMax(1e-9)
            var bp = parsePath(p.d)
            bp.applyAffine(Affine.scaleNonUniform(w / pw, h / ph))
            // PowerPoint fills each custom path's sub-paths alternately (even-odd): a sub-path inside
            // another cuts a hole whichever way it winds, as in icons and outlined text.
            out.append(Preset.SubPath(path: bp, fill: p.fill, stroke: p.stroke, evenOdd: true))
        }
        return Preset.Geometry(paths: out, textRect: Rect(0, 0, w, h), handles: [], sites: [])
    }
}

/// Parse the custom path syntax (`M x y L x y C … Q … Z`).
public func parsePath(_ d: String) -> BezPath {
    var bp = BezPath()
    let toks = d.unicodeScalars.split { $0.properties.isWhitespace || $0 == "," }.map { String(String.UnicodeScalarView($0)) }
    func num(_ i: Int) -> Double? {
        guard let t = toks.at(i), let v = rustParseF64(t), v.isFinite else { return nil }
        return v
    }
    var i = 0
    var started = false
    while i < toks.count {
        switch toks[i] {
        case "M":
            if let x = num(i + 1), let y = num(i + 2) {
                bp.moveTo(Point(x, y))
                started = true
            }
            i += 3
        case "L":
            if let x = num(i + 1), let y = num(i + 2) {
                if !started {
                    bp.moveTo(Point(x, y))
                    started = true
                } else {
                    bp.lineTo(Point(x, y))
                }
            }
            i += 3
        case "C":
            if let a = num(i + 1), let b = num(i + 2), let c = num(i + 3), let d2 = num(i + 4), let e = num(i + 5), let f = num(i + 6), started {
                bp.curveTo(Point(a, b), Point(c, d2), Point(e, f))
            }
            i += 7
        case "Q":
            if let a = num(i + 1), let b = num(i + 2), let c = num(i + 3), let d2 = num(i + 4), started {
                bp.quadTo(Point(a, b), Point(c, d2))
            }
            i += 5
        case "Z", "z":
            if started { bp.closePath() }
            i += 1
        default:
            i += 1
        }
    }
    return bp
}

/// Rust's `str::parse::<f64>`: decimal digits, an optional sign, point and exponent, or `inf`/`nan` in any
/// case (Swift's `Double(_:)` also accepts hex floats, which Rust refuses).
func rustParseF64(_ s: String) -> Double? {
    let lower = s.lowercased()
    var body = Substring(lower)
    if body.first == "+" || body.first == "-" { body = body.dropFirst() }
    if ["inf", "infinity", "nan"].contains(String(body)) { return Double(lower.replacingOccurrences(of: "infinity", with: "inf")) }
    guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "e" || $0 == "+" || $0 == "-") }),
          body.contains(where: \.isNumber) else { return nil }
    return Double(s)
}
