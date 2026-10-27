// DCRender — gradient colour ramps as PowerPoint draws them. Port of deckcraft crates/render/src/ramp.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A gradient of exactly two stops, at 0 % and 100 %, is not blended linearly in sRGB by PowerPoint: it
// mixes the colours in linear light, and the second colour's share follows an S-shaped curve of the
// position (black to white is 105 a quarter of the way, 186 half way, 238 three quarters). Gradients
// with three or more stops, or a stop moved off an end, blend linearly in sRGB. The canvas interpolates
// linearly in sRGB, so a two-colour gradient is expanded into short pieces following PowerPoint's ramp.
import DCColor
import DCCore
import Foundation

public enum Ramp {
    /// The next stop's share of the linear-light mix at sixteenths of a segment. Measured, then made
    /// symmetric: `w(1 - t) = 1 - w(t)`.
    static let weights: [Double] = [
        0.0, 0.0205, 0.0469, 0.0878, 0.1431, 0.2143, 0.2989, 0.3972, 0.5,
        0.6028, 0.7011, 0.7857, 0.8569, 0.9122, 0.9531, 0.9795, 1.0,
    ]

    /// Pieces each segment between two stops is cut into.
    static let pieces = 16

    /// The next stop's share at `t` (0…1) between two stops.
    public static func weight(_ t: Double) -> Double {
        if !t.isFinite { return 0.0 }
        let x = t.clamped(0.0, 1.0) * Double(weights.count - 1)
        let i = min(Int(rustCast: x.rounded(.down)), weights.count - 2)
        let f = x - Double(i)
        let a = weights.at(i) ?? 0.0, b = weights.at(i + 1) ?? 1.0
        return a + (b - a) * f
    }

    static func toLinear(_ v: UInt8) -> Double {
        let v = Double(v) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func toSRGB(_ v: Double) -> UInt8 {
        let v = v.clamped(0.0, 1.0)
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
        return UInt8(rustCast: (s * 255.0).rounded().clamped(0.0, 255.0))
    }

    /// The colour at `t` between stops `a` and `b`. Alpha mixes by the same share.
    public static func mix(_ a: Rgba, _ b: Rgba, _ t: Double) -> Rgba {
        let w = weight(t)
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 { toSRGB(toLinear(x) + (toLinear(y) - toLinear(x)) * w) }
        let alpha = (Double(a.a) + (Double(b.a) - Double(a.a)) * w).rounded().clamped(0.0, 255.0)
        return Rgba(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: UInt8(rustCast: alpha))
    }

    /// Sorted stops (position 0…1, colour) as a renderer interpolating linearly in sRGB should get them:
    /// a two-colour gradient (two stops, at 0 and 1) expanded to follow PowerPoint's ramp, anything else
    /// unchanged.
    public static func expand(_ stops: [(Double, Rgba)]) -> [(Double, Rgba)] {
        guard stops.count == 2, let first = stops.first, let last = stops.last,
              first.0 <= 1e-6, last.0 >= 1.0 - 1e-6 else { return stops }
        var out: [(Double, Rgba)] = []
        out.reserveCapacity(stops.count * pieces + 1)
        for (i, (p, c)) in stops.enumerated() {
            out.append((p, c))
            guard let (q, d) = stops.at(i + 1) else { continue }
            if q - p <= 1e-6 || c == d { continue }
            for k in 1 ..< pieces {
                let t = Double(k) / Double(pieces)
                out.append((p + (q - p) * t, mix(c, d, t)))
            }
        }
        return out
    }
}
