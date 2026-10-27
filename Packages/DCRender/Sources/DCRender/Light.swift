// DCRender — light rigs (`a:lightRig rig= dir=`) and materials (`a:sp3d prstMaterial=`) for 3-D shapes:
// how bright a surface is for its normal. Port of deckcraft crates/render/src/light.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
//
// The three-point rig with the matte material is fitted to PowerPoint's exports (see Bevel.swift):
// `c · (0.453 + 0.731 · max(0, n · L)) + 14.7` with the key light from the upper left. The other rigs and
// materials are modelled on it, not measured.
import DCColor
import DCCore
import Darwin

/// A light rig and material: what lights a 3-D surface.
public struct Lighting: Sendable, Equatable {
    /// Unit directions from the surface towards each light (x right, y down, z to the viewer) and their
    /// strengths.
    public var lights: [(dir: [Double], strength: Double)]
    public var ambient: Double
    public var diffuse: Double
    /// Added to every channel (the measured lift of the three-point rig).
    public var lift: Double
    /// Colour of the light, per channel.
    public var tint: [Double]
    public var specular: Double
    public var shininess: Double
    /// `flat`: no shading at all.
    public var flat: Bool

    public static func == (a: Lighting, b: Lighting) -> Bool {
        a.lights.count == b.lights.count && zip(a.lights, b.lights).allSatisfy { $0.dir == $1.dir && $0.strength == $1.strength }
            && a.ambient == b.ambient && a.diffuse == b.diffuse && a.lift == b.lift && a.tint == b.tint
            && a.specular == b.specular && a.shininess == b.shininess && a.flat == b.flat
    }

    static func dir(_ az: Double, _ el: Double) -> [Double] {
        let (az, el) = (az.toRadians, el.toRadians)
        return [cos(el) * cos(az), cos(el) * sin(az), sin(el)]
    }

    static func valueAfter(_ raw: String, _ key: String) -> String? {
        guard let s = raw.range(of: key) else { return nil }
        let rest = raw[s.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<e])
    }

    /// The rig's lights as (azimuth, elevation, strength), its ambient level and tint.
    static func rig(_ name: String) -> ([(Double, Double, Double)], Double, [Double]) {
        let white: [Double] = [1, 1, 1]
        switch name {
        case "balanced": return ([(240, 40, 0.75), (300, 40, 0.35), (90, 30, 0.25)], 0.47, white)
        case "soft": return ([(270, 60, 0.6)], 0.58, white)
        case "harsh": return ([(225, 30, 1.15)], 0.3, white)
        case "flood": return ([(270, 70, 0.8), (240, 40, 0.35)], 0.5, white)
        case "contrasting": return ([(210, 30, 1.05), (30, 20, 0.3)], 0.33, white)
        case "morning": return ([(240, 35, 0.9)], 0.45, [1.0, 0.95, 0.85])
        case "sunrise": return ([(200, 20, 0.95)], 0.42, [1.0, 0.88, 0.75])
        case "sunset": return ([(340, 20, 0.95)], 0.42, [1.0, 0.82, 0.7])
        case "chilly": return ([(240, 45, 0.85)], 0.45, [0.88, 0.94, 1.0])
        case "freezing": return ([(240, 45, 0.85)], 0.45, [0.8, 0.9, 1.0])
        case "twoPt": return ([(225, 45, 0.8), (315, 45, 0.45)], 0.42, white)
        case "glow": return ([(270, 85, 0.55)], 0.68, white)
        case "brightRoom": return ([(270, 60, 0.45)], 0.75, white)
        // threePt and the legacy rigs.
        default: return ([(240, 45, 1.0)], 0.453, white)
        }
    }

    /// The rig direction (`dir`) turns the lights about the view axis.
    static func dirTurn(_ d: String) -> Double {
        switch d {
        case "tr": 45
        case "r": 90
        case "br": 135
        case "b": 180
        case "bl": 225
        case "l": 270
        case "tl": 315
        default: 0
        }
    }

    /// The lighting of 3-D XML kept from the file; the three-point rig and warm matte material when unset.
    public static func fromRaw(_ raw: String) -> Lighting {
        let rigName = valueAfter(raw, "rig=\"") ?? "threePt"
        let turn = dirTurn(valueAfter(raw, " dir=\"") ?? "t")
        let material = valueAfter(raw, "prstMaterial=\"") ?? "warmMatte"
        let (lights, ambient, tint) = rig(rigName)
        let (dk, ak, specular, shininess): (Double, Double, Double, Double) = switch material {
        case "plastic": (1.0, 1.0, 0.45, 24.0)
        case "metal": (0.8, 0.9, 0.7, 40.0)
        case "softmetal": (0.9, 0.95, 0.35, 12.0)
        case "powder", "translucentPowder": (0.85, 1.12, 0.0, 1.0)
        case "dkEdge": (1.12, 0.8, 0.1, 8.0)
        case "softEdge": (0.9, 1.08, 0.05, 6.0)
        case "clear": (0.9, 1.0, 0.6, 50.0)
        default: (1.0, 1.0, 0.0, 1.0)
        }
        return Lighting(
            lights: lights.map { (dir($0.0 + turn, $0.1), $0.2) }, ambient: ambient * ak, diffuse: 0.731 * dk, lift: 14.7,
            tint: tint, specular: specular, shininess: shininess, flat: rigName == "flat" || material == "flat"
        )
    }

    /// The diffuse brightness factor for unit normal `n` (the three-point matte rig: 0.453 + 0.731 ·
    /// max(0, n · L)).
    public func factor(_ n: [Double]) -> Double {
        if flat { return 1 }
        func dot(_ l: [Double]) -> Double { (n[0] * l[0] + n[1] * l[1] + n[2] * l[2]).rustMax(0) }
        return ambient + diffuse * lights.reduce(0.0) { $0 + $1.strength * dot($1.dir) }
    }

    /// The specular highlight (0–1) for unit normal `n`, seen from the front.
    public func highlight(_ n: [Double]) -> Double {
        if flat || specular <= 0 { return 0 }
        return lights.reduce(0.0) { acc, light in
            let l = light.dir
            let h = [l[0], l[1], l[2] + 1.0]
            let len = (h[0] * h[0] + h[1] * h[1] + h[2] * h[2]).squareRoot().rustMax(1e-9)
            let d = ((n[0] * h[0] + n[1] * h[1] + n[2] * h[2]) / len).rustMax(0)
            return acc + light.strength * pow(d, shininess)
        } * specular
    }

    /// Colour `c` lit on a surface with unit normal `n`.
    public func shade(_ c: Rgba, _ n: [Double]) -> Rgba {
        if flat { return c }
        let f = factor(n)
        let hi = highlight(n) * 255
        func ch(_ v: UInt8, _ t: Double) -> UInt8 { UInt8(rustCast: (Double(v) * f * t + lift + hi).rounded().clamped(0, 255)) }
        return .rgba(ch(c.r, tint[0]), ch(c.g, tint[1]), ch(c.b, tint[2]), c.a)
    }
}
