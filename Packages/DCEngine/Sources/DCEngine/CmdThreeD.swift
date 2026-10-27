// DCEngine — the `three_d` module: Format Shape ▸ 3-D Format and 3-D Rotation. A shape's `a:scene3d` /
// `a:sp3d` is kept as XML on the model (`Effects.raw3d`), read into fields, changed, and written back.
// It registers no commands: `shape.effects` (`threeD`, `bevel`) and the picture styles use it.
// Port of deckcraft crates/engine/src/cmd/three_d.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel
import DCPPTX

public enum ThreeDCommands {
    public static func specs() -> [CommandSpec] { [] }

    /// Camera presets PowerPoint offers (3-D Rotation ▸ Presets).
    public static let cameras: [String] = [
        "orthographicFront", "isometricTopUp", "isometricTopDown", "isometricBottomUp", "isometricBottomDown",
        "isometricLeftUp", "isometricLeftDown", "isometricRightUp", "isometricRightDown", "obliqueTopLeft",
        "obliqueTopRight", "obliqueBottomLeft", "obliqueBottomRight", "perspectiveFront", "perspectiveLeft",
        "perspectiveRight", "perspectiveAbove", "perspectiveBelow", "perspectiveAboveLeftFacing",
        "perspectiveAboveRightFacing", "perspectiveContrastingLeftFacing", "perspectiveContrastingRightFacing",
        "perspectiveHeroicLeftFacing", "perspectiveHeroicRightFacing", "perspectiveHeroicExtremeLeftFacing",
        "perspectiveHeroicExtremeRightFacing", "perspectiveRelaxed", "perspectiveRelaxedModerately",
    ]

    /// Bevel presets (`ST_BevelPresetType`).
    public static let bevels: [String] = [
        "circle", "relaxedInset", "cross", "coolSlant", "angle", "softRound", "convex", "slope", "divot", "riblet",
        "hardEdge", "artDeco",
    ]

    /// Materials (`ST_PresetMaterialType`).
    public static let materials: [String] = [
        "warmMatte", "matte", "plastic", "metal", "dkEdge", "softEdge", "flat", "legacyWireframe", "powder",
        "translucentPowder", "clear", "softmetal",
    ]

    /// Light rigs (`ST_LightRigType`) PowerPoint offers.
    public static let lights: [String] = [
        "threePt", "balanced", "soft", "harsh", "flood", "contrasting", "morning", "sunrise", "sunset", "chilly",
        "freezing", "flat", "twoPt", "glow", "brightRoom",
    ]

    /// Every camera preset the file format defines (`ST_PresetCameraType`); a file's camera is kept only
    /// when it is one of these.
    public static let allCameras: [String] = [
        "legacyObliqueTopLeft", "legacyObliqueTop", "legacyObliqueTopRight", "legacyObliqueLeft",
        "legacyObliqueFront", "legacyObliqueRight", "legacyObliqueBottomLeft", "legacyObliqueBottom",
        "legacyObliqueBottomRight", "legacyPerspectiveTopLeft", "legacyPerspectiveTop", "legacyPerspectiveTopRight",
        "legacyPerspectiveLeft", "legacyPerspectiveFront", "legacyPerspectiveRight", "legacyPerspectiveBottomLeft",
        "legacyPerspectiveBottom", "legacyPerspectiveBottomRight", "orthographicFront", "isometricTopUp",
        "isometricTopDown", "isometricBottomUp", "isometricBottomDown", "isometricLeftUp", "isometricLeftDown",
        "isometricRightUp", "isometricRightDown", "isometricOffAxis1Left", "isometricOffAxis1Right",
        "isometricOffAxis1Top", "isometricOffAxis2Left", "isometricOffAxis2Right", "isometricOffAxis2Top",
        "isometricOffAxis3Left", "isometricOffAxis3Right", "isometricOffAxis3Bottom", "isometricOffAxis4Left",
        "isometricOffAxis4Right", "isometricOffAxis4Bottom", "obliqueTopLeft", "obliqueTop", "obliqueTopRight",
        "obliqueLeft", "obliqueRight", "obliqueBottomLeft", "obliqueBottom", "obliqueBottomRight", "perspectiveFront",
        "perspectiveLeft", "perspectiveRight", "perspectiveAbove", "perspectiveBelow", "perspectiveAboveLeftFacing",
        "perspectiveAboveRightFacing", "perspectiveContrastingLeftFacing", "perspectiveContrastingRightFacing",
        "perspectiveHeroicLeftFacing", "perspectiveHeroicRightFacing", "perspectiveHeroicExtremeLeftFacing",
        "perspectiveHeroicExtremeRightFacing", "perspectiveRelaxed", "perspectiveRelaxedModerately",
    ]

    /// Every light rig the file format defines (`ST_LightRigType`).
    public static let allLights: [String] = [
        "legacyFlat1", "legacyFlat2", "legacyFlat3", "legacyFlat4", "legacyNormal1", "legacyNormal2", "legacyNormal3",
        "legacyNormal4", "legacyHarsh1", "legacyHarsh2", "legacyHarsh3", "legacyHarsh4", "threePt", "balanced", "soft",
        "harsh", "flood", "contrasting", "morning", "sunrise", "sunset", "chilly", "freezing", "flat", "twoPt", "glow",
        "brightRoom",
    ]

    /// Light rig directions (`ST_LightRigDirection`).
    public static let lightDirs: [String] = ["tl", "t", "tr", "l", "r", "bl", "b", "br"]

    /// Every material the file format defines (`ST_PresetMaterialType`).
    public static let allMaterials: [String] = [
        "legacyMatte", "legacyPlastic", "legacyMetal", "legacyWireframe", "matte", "plastic", "metal", "warmMatte",
        "translucentPowder", "powder", "dkEdge", "softEdge", "clear", "flat", "softmetal",
    ]

    /// One bevel: preset, width and height in points.
    public struct Bevel: Sendable, Equatable {
        public var preset: String
        public var w: Double
        public var h: Double
        public init(preset: String, w: Double, h: Double) {
            self.preset = preset
            self.w = w
            self.h = h
        }
    }

    /// Camera rotation (X, Y, Z in degrees, as PowerPoint shows them).
    public struct Rotation: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double
        public init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    static let emu = 12700.0
    static let angle = 60000.0
    /// Largest length kept, in points (PowerPoint's own limit).
    static let maxPt = 1584.0

    /// `value` when it is one of `known`, else `def`. Values from a file are written back into XML as they
    /// are, so nothing outside these lists may pass.
    static func known(_ value: String?, _ known: [String], _ def: String) -> String {
        if let v = value, known.contains(where: { rustEqual($0, v) }) { return v }
        return def
    }

    static func num(_ e: XMLEl, _ name: String) -> Double? {
        e.attr(name).flatMap { rustParseF64(rustTrim($0)) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Rust's `f64::rem_euclid`.
    static func remEuclid(_ v: Double, _ m: Double) -> Double {
        let r = v.rem(m)
        return r < 0 ? r + Swift.abs(m) : r
    }

    /// The 3-D settings of a shape (`Shape3d`).
    public struct Shape3d: Sendable, Equatable {
        public var camera = "orthographicFront"
        /// Camera rotation, when set.
        public var rot: Rotation?
        public var light = "threePt"
        public var lightDir = "t"
        public var top: Bevel?
        public var bottom: Bevel?
        /// Depth (extrusion), contour width and distance from ground, in points.
        public var depth = 0.0
        public var contour = 0.0
        public var z = 0.0
        public var material = "warmMatte"
        /// `a:extrusionClr` / `a:contourClr` XML, kept as is.
        public var colors = ""

        public init() {}

        public static var `default`: Shape3d { Shape3d() }

        /// Reads kept 3-D XML (`a:scene3d` and `a:sp3d`); unknown or invalid parts take their defaults.
        public static func parse(_ raw: String) -> Shape3d {
            var s = Shape3d()
            guard let doc = try? parseXML("<r>\(raw)</r>") else { return s }
            let root = doc.root
            if let cam = root.path(["scene3d", "camera"]) {
                s.camera = known(cam.attr("prst"), allCameras, "orthographicFront")
                if let rot = cam.child("rot") {
                    func d(_ n: String) -> Double { (num(rot, n) ?? 0) / angle }
                    s.rot = Rotation(d("lon"), d("lat"), d("rev"))
                }
            }
            if let l = root.path(["scene3d", "lightRig"]) {
                s.light = known(l.attr("rig"), allLights, "threePt")
                s.lightDir = known(l.attr("dir"), lightDirs, "t")
            }
            if let sp = root.child("sp3d") {
                func pt(_ n: String, _ lo: Double) -> Double { ((num(sp, n) ?? 0) / emu).clamped(lo, maxPt) }
                s.depth = pt("extrusionH", 0)
                s.contour = pt("contourW", 0)
                s.z = pt("z", -maxPt)
                s.material = known(sp.attr("prstMaterial"), allMaterials, "warmMatte")
                for name in ["bevelT", "bevelB"] {
                    guard let b = sp.child(name) else { continue }
                    func len(_ n: String) -> Double { ((num(b, n) ?? 76200) / emu).clamped(0, maxPt) }
                    let bevel = Bevel(preset: known(b.attr("prst"), bevels, "circle"), w: len("w"), h: len("h"))
                    if name == "bevelT" { s.top = bevel } else { s.bottom = bevel }
                }
                // Colours are re-serialized by the XML writer (escaped); only `a:`-prefixed ones, since
                // they are written back inside our own `a:sp3d`.
                s.colors = sp.elements.filter { ($0.is("extrusionClr") || $0.is("contourClr")) && $0.prefix == "a" }
                    .map { $0.toXML() }.joined()
            }
            return s
        }

        /// Whether this is a flat shape with no 3-D at all.
        public var isFlat: Bool {
            camera == "orthographicFront" && (rot.map { $0.x == 0 && $0.y == 0 && $0.z == 0 } ?? true) && top == nil
                && bottom == nil && depth == 0 && contour == 0 && z == 0
        }

        /// The `a:scene3d` and `a:sp3d` XML, or nil for a flat shape.
        public func toXML() -> String? {
            if isFlat { return nil }
            func e(_ pt: Double) -> Int64 { Int64(rustCast: (pt * emu).rounded()) }
            var x = "<a:scene3d><a:camera prst=\"\(camera)\""
            if let r = rot {
                func a(_ d: Double) -> Int64 { Int64(rustCast: (remEuclid(d, 360) * angle).rounded()) % 21_600_000 }
                x += "><a:rot lat=\"\(a(r.y))\" lon=\"\(a(r.x))\" rev=\"\(a(r.z))\"/></a:camera>"
            } else {
                x += "/>"
            }
            x += "<a:lightRig rig=\"\(light)\" dir=\"\(lightDir)\"/></a:scene3d><a:sp3d"
            if z != 0 { x += " z=\"\(e(z))\"" }
            if depth > 0 { x += " extrusionH=\"\(e(depth))\"" }
            if contour > 0 { x += " contourW=\"\(e(contour))\"" }
            if material != "warmMatte" { x += " prstMaterial=\"\(material)\"" }
            x += ">"
            for (tag, b) in [("bevelT", top), ("bevelB", bottom)] {
                if let b { x += "<a:\(tag) w=\"\(e(b.w))\" h=\"\(e(b.h))\" prst=\"\(b.preset)\"/>" }
            }
            x += colors
            x += "</a:sp3d>"
            return x
        }

        /// Applies `{camera?, rotX?, rotY?, rotZ?, z?, bevelTop?, bevelTopW?, bevelTopH?, bevelBottom?,
        /// bevelBottomW?, bevelBottomH?, depth?, contour?, material?, lighting?, lightAngle?}`.
        public mutating func apply(_ p: JSON) {
            func f(_ k: String) -> Double? { p.get(k)?.asF64.flatMap { $0.isFinite ? $0 : nil } }
            func pick(_ k: String, _ list: [String]) -> String? {
                guard let v = p.get(k)?.asStr, list.contains(where: { rustEqual($0, v) }) else { return nil }
                return v
            }
            if let c = pick("camera", cameras) {
                camera = c
                // A preset sets its own angles.
                rot = nil
            }
            let (rx, ry, rz) = (f("rotX"), f("rotY"), f("rotZ"))
            if rx != nil || ry != nil || rz != nil {
                let o = rot ?? Rotation(0, 0, 0)
                func d(_ v: Double?, _ o: Double) -> Double { v.map { remEuclid($0, 360) } ?? o }
                rot = Rotation(d(rx, o.x), d(ry, o.y), d(rz, o.z))
            }
            if let v = f("z") { z = v.clamped(-1584, 1584) }
            for key in ["bevelTop", "bevelBottom"] {
                var slot = key == "bevelTop" ? top : bottom
                switch p.get(key)?.asStr {
                case "none"?: slot = nil
                case let b? where bevels.contains(where: { rustEqual($0, b) }):
                    let old = slot ?? Bevel(preset: "", w: 6, h: 6)
                    slot = Bevel(preset: b, w: old.w, h: old.h)
                default: break
                }
                if var b = slot {
                    if let w = f("\(key)W") { b.w = w.clamped(0, 1584) }
                    if let h = f("\(key)H") { b.h = h.clamped(0, 1584) }
                    slot = b
                }
                if key == "bevelTop" { top = slot } else { bottom = slot }
            }
            if let v = f("depth") { depth = v.clamped(0, 1584) }
            if let v = f("contour") { contour = v.clamped(0, 1584) }
            if let m = pick("material", materials) { material = m }
            if let l = pick("lighting", lights) { light = l }
        }
    }

    /// Sets a shape's 3-D settings on its effects, keeping `bevel` (the top bevel's preset) in step.
    public static func store(_ e: inout Effects, _ s: Shape3d) {
        e.raw3d = s.toXML()
        e.bevel = e.raw3d != nil ? s.top?.preset : nil
    }
}
