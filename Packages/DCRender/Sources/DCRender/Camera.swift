// DCRender — 3-D cameras (`a:scene3d/a:camera`) turning a flat shape, approximated in 2-D. Port of
// deckcraft crates/render/src/camera.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A shape seen through a 3-D camera preset (isometric, perspective…) or rotated with `a:camera/a:rot` is
// drawn by PowerPoint as its plane turned in space and projected. The shape's corners are turned the same
// way and the shape drawn under the affine transform that best fits them: exact for orthographic cameras,
// within about 2% of the shape's size for the perspective ones. Depth, bevels' sides and lighting are not
// drawn here. (`cameraTurn`, the per-shape entry point, lives in Render.swift.)
//
// The presets' turns were fitted by deckcraft to PowerPoint's exports (black-box): points relative to the
// shape's centre are turned `p = Rz(-rev) · Rx(lat) · Ry(lon) · (x, y, 0)` and, for perspective cameras,
// scaled by `D / (D - p.z)` with `D = dist · max(w, h)`.
import DCCore
import DCGeometry
import Darwin

/// A camera's turn of the shape's plane.
public struct Camera: Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var rev: Double
    /// Perspective distance in shape sizes; 0 for an orthographic camera.
    public var dist: Double

    public init(lat: Double, lon: Double, rev: Double, dist: Double) {
        self.lat = lat
        self.lon = lon
        self.rev = rev
        self.dist = dist
    }

    /// (preset, lat, lon, rev in degrees, perspective distance in shape sizes or 0 for orthographic).
    static let presets: [(String, Double, Double, Double, Double)] = [
        ("orthographicFront", 0.0, 0.0, 0.0, 0.0),
        ("isometricTopUp", 215.52, 134.75, 240.17, 0.0),
        ("isometricTopDown", 324.69, 45.30, 299.88, 0.0),
        ("isometricBottomUp", 215.52, 134.75, 240.17, 0.0),
        ("isometricBottomDown", 215.36, 225.28, 119.86, 0.0),
        ("isometricLeftUp", 324.94, 44.77, 0.03, 0.0),
        ("isometricLeftDown", 144.84, 224.73, 179.95, 0.0),
        ("isometricRightUp", 324.81, 44.75, 359.98, 0.0),
        ("isometricRightDown", 144.84, 224.73, 179.95, 0.0),
        ("isometricOffAxis1Left", 17.94, 64.06, 359.94, 0.0),
        ("isometricOffAxis1Right", 341.80, 25.84, 0.0, 0.0),
        ("isometricOffAxis1Top", 238.56, 127.22, 237.03, 0.0),
        ("isometricOffAxis2Left", 161.88, 205.84, 179.98, 0.0),
        ("isometricOffAxis2Right", 197.91, 244.06, 180.06, 0.0),
        ("isometricOffAxis2Top", 301.42, 52.80, 302.97, 0.0),
        ("isometricOffAxis3Left", 197.95, 244.05, 180.06, 0.0),
        ("isometricOffAxis3Right", 161.88, 205.84, 179.98, 0.0),
        ("isometricOffAxis3Bottom", 301.42, 52.78, 302.98, 0.0),
        ("isometricOffAxis4Left", 198.00, 205.84, 180.05, 0.0),
        ("isometricOffAxis4Right", 17.94, 64.06, 359.94, 0.0),
        ("isometricOffAxis4Bottom", 121.42, 232.75, 237.00, 0.0),
        ("perspectiveLeft", 359.91, 341.75, 0.02, 12.14),
        ("perspectiveRight", 180.27, 198.23, 179.94, 8.02),
        ("perspectiveAbove", 18.92, 0.38, 0.09, 16.61),
        ("perspectiveBelow", 198.83, 180.39, 179.89, 9.31),
        ("perspectiveAboveLeftFacing", 320.78, 346.02, 340.95, 11.54),
        ("perspectiveAboveRightFacing", 219.25, 194.14, 198.98, 9.28),
        ("perspectiveContrastingLeftFacing", 190.42, 136.41, 176.42, 12.21),
        ("perspectiveContrastingRightFacing", 190.52, 223.59, 183.56, 9.53),
        ("perspectiveHeroicLeftFacing", 10.89, 346.28, 2.75, 13.22),
        ("perspectiveHeroicRightFacing", 169.53, 194.00, 177.22, 8.45),
        ("perspectiveHeroicExtremeLeftFacing", 351.98, 325.89, 357.00, 5.98),
        ("perspectiveHeroicExtremeRightFacing", 188.39, 214.22, 182.81, 5.26),
        ("perspectiveRelaxed", 50.02, 0.03, 0.0, 11.32),
        ("perspectiveRelaxedModerately", 34.42, 0.33, 0.16, 11.14),
    ]

    /// Perspective distance for a perspective camera given its own rotation (fitted on `perspectiveFront`
    /// with `a:rot`, about 11 shape sizes).
    static let perspectiveDist = 11.0

    /// The camera of 3-D XML kept from the file, when it turns the shape.
    public static func fromRaw(_ raw: String) -> Camera? {
        guard let i = raw.range(of: "camera ") else { return nil }
        let rest = raw[i.lowerBound...]
        guard let openEnd = rest.firstIndex(of: ">") else { return nil }
        let open = rest[..<openEnd]
        let prst = xmlAttr(open, "prst") ?? "orthographicFront"
        let preset = presets.first { $0.0 == prst }
        let perspective = prst.hasPrefix("perspective")
        // Its own `a:rot` (inside the camera element, not the light rig's).
        let selfClosing = open.hasSuffix("/")
        var ownRot: (Double, Double, Double)?
        if !selfClosing {
            let bodyEnd = rest.range(of: "camera>")?.lowerBound ?? rest.endIndex
            guard openEnd <= bodyEnd else { return nil }
            let body = rest[openEnd ..< bodyEnd]
            if let j = body.range(of: "rot ") {
                let t0 = body[j.lowerBound...]
                if let e = t0.firstIndex(of: ">") {
                    let t = t0[..<e]
                    func deg(_ n: String) -> Double { xmlAttr(t, n).flatMap(rustParseF64).map { $0 / 60000.0 } ?? 0 }
                    ownRot = (deg("lat"), deg("lon"), deg("rev"))
                }
            }
        }
        let cam: Camera
        if let (lat, lon, rev) = ownRot {
            // PowerPoint turns the other way about the horizontal and vertical axes for `a:rot`.
            let dist: Double
            if let p = preset, p.4 > 0 {
                dist = p.4
            } else if perspective {
                dist = perspectiveDist
            } else {
                dist = 0
            }
            cam = Camera(lat: -lat, lon: -lon, rev: rev, dist: dist)
        } else if let p = preset {
            cam = Camera(lat: p.1, lon: p.2, rev: p.3, dist: p.4)
        } else {
            return nil
        }
        let flat = [cam.lat, cam.lon, cam.rev].allSatisfy { a in
            let r = remEuclid(a, 360.0)
            return r.rustMin(360.0 - r) < 1e-6
        }
        return flat ? nil : cam
    }

    /// Where a point of the shape (relative to its centre) lands.
    func project(_ p: Point, _ size: Double) -> Point { project3(p.x, p.y, 0, size) }

    /// Direction `v` (shape space: x right, y down, z to the viewer) turned by the camera, without
    /// perspective: a surface normal as the camera sees it.
    public func rotate(_ v: [Double]) -> [Double] {
        let (a, b, r) = (lat.toRadians, lon.toRadians, -rev.toRadians)
        let (x, y, z) = (v.at(0) ?? 0, v.at(1) ?? 0, v.at(2) ?? 0)
        let (x1, y1, z1) = (x * cos(b) + z * sin(b), y, -x * sin(b) + z * cos(b))
        let (x2, y2, z2) = (x1, y1 * cos(a) - z1 * sin(a), y1 * sin(a) + z1 * cos(a))
        return [x2 * cos(r) - y2 * sin(r), x2 * sin(r) + y2 * cos(r), z2]
    }

    /// Where a point in the shape's space (relative to its centre; z towards the viewer, so an extrusion
    /// runs to negative z) lands.
    public func project3(_ x: Double, _ y: Double, _ z: Double, _ size: Double) -> Point {
        let (a, b, r) = (lat.toRadians, lon.toRadians, -rev.toRadians)
        let (x1, y1, z1) = (x * cos(b) + z * sin(b), y, -x * sin(b) + z * cos(b))
        let (x2, y2, z2) = (x1, y1 * cos(a) - z1 * sin(a), y1 * sin(a) + z1 * cos(a))
        let (x3, y3) = (x2 * cos(r) - y2 * sin(r), x2 * sin(r) + y2 * cos(r))
        if dist > 0 {
            let d = dist * size
            let s = d / (d - z2)
            if s.isFinite && s > 0 { return Point(x3 * s, y3 * s) }
        }
        return Point(x3, y3)
    }

    /// The transform (shape space to shape space) that turns a `w` × `h` shape as camera `c` does: the
    /// affine map best fitting its turned corners.
    public static func affine(_ c: Camera, _ w: Double, _ h: Double) -> Affine? {
        if !(w.isFinite && h.isFinite) || w <= 0 || h <= 0 { return nil }
        let size = w.rustMax(h)
        let src: [(Double, Double)] = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
        let dst = src.map { c.project(Point($0.0, $0.1), size) }
        // Least squares over the four corners. The corners are symmetric about the centre, so the normal
        // equations are diagonal: x' = a x + b y + e with a = Σ x x' / Σ x², and so on.
        let sxx = src.reduce(0.0) { $0 + $1.0 * $1.0 }
        let syy = src.reduce(0.0) { $0 + $1.1 * $1.1 }
        func dot(_ f: ((Double, Double), Point) -> Double) -> Double { zip(src, dst).reduce(0.0) { $0 + f($1.0, $1.1) } }
        let a = dot { s, d in s.0 * d.x } / sxx
        let b = dot { s, d in s.1 * d.x } / syy
        let cy = dot { s, d in s.0 * d.y } / sxx
        let dy = dot { s, d in s.1 * d.y } / syy
        let e = dot { _, d in d.x } / 4
        let f = dot { _, d in d.y } / 4
        let local = Affine(a, cy, b, dy, e, f)
        let m = Affine.translate(Vec2(w / 2, h / 2)) * local * Affine.translate(Vec2(-w / 2, -h / 2))
        return m.isFinite && Swift.abs(m.determinant) > 1e-9 ? m : nil
    }
}

/// The value of attribute `name` in an element's text (XML as kept from the file).
func xmlAttr(_ tag: Substring, _ name: String) -> String? {
    guard let s = tag.range(of: " \(name)=\"") else { return nil }
    let rest = tag[s.upperBound...]
    guard let e = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<e])
}

/// Rust's `f64::rem_euclid`.
func remEuclid(_ v: Double, _ m: Double) -> Double {
    let r = v.rem(m)
    return r < 0 ? r + Swift.abs(m) : r
}
