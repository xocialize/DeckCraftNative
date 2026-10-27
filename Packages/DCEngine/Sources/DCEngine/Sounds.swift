// DCEngine — built-in transition sounds, synthesised on demand so the app ships no sound files: short mono
// 16-bit WAVs named like PowerPoint's (Chime, Click, Camera, Whoosh, Drum Roll, Laser).
// Port of deckcraft crates/engine/src/sounds.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The arithmetic is Rust's, step for step, so the bytes are the same.
import DCCore
import Foundation

public enum Sounds {
    /// (id, label) of the built-in sounds, in menu order.
    public static let builtin: [(String, String)] = [
        ("chime", "Chime"), ("click", "Click"), ("camera", "Camera"), ("whoosh", "Whoosh"), ("drumRoll", "Drum Roll"), ("laser", "Laser"),
    ]

    static let rate: UInt32 = 22_050
    private static let tau = 2.0 * Double.pi

    /// The WAV bytes of built-in sound `id`, or nil for an unknown id.
    public static func builtin(_ id: String) -> [UInt8]? {
        var noise = Lcg(0x9E37_79B9)
        let samples: [Double]
        switch id {
        case "chime":
            samples = tone(1.2) { t in
                let env = exp(-t * 3.0) * attack(t, 0.005)
                return env * (0.6 * sin(tau * 880.0 * t) + 0.3 * sin(tau * 1318.5 * t) + 0.15 * sin(tau * 1760.0 * t))
            }
        case "click":
            samples = tone(0.03) { t in exp(-t * 300.0) * noise.next() }
        case "camera":
            samples = tone(0.35) { t in
                let a = exp(-t * 250.0)
                let b = t > 0.18 ? exp(-(t - 0.18) * 180.0) : 0.0
                return (a + 0.8 * b) * noise.next()
            }
        case "whoosh":
            var lp = 0.0
            samples = tone(0.7) { t in
                // Noise through a low-pass filter that opens and closes.
                let k = 0.02 + 0.25 * sin(Double.pi * t / 0.7)
                lp += k * (noise.next() - lp)
                return 3.0 * lp * sin(Double.pi * t / 0.7)
            }
        case "drumRoll":
            samples = tone(1.4) { t in
                let x = t * 24.0
                let beat = (x - x.rounded(.towardZero)) / 24.0
                let swell = 0.4 + 0.6 * (t / 1.4)
                return swell * exp(-beat * 90.0) * (0.7 * noise.next() + 0.5 * sin(tau * 110.0 * t))
            }
        case "laser":
            var phase = 0.0
            samples = tone(0.5) { t in
                phase += tau * (2400.0 * exp(-t * 5.0) + 200.0) / Double(rate)
                return exp(-t * 4.0) * attack(t, 0.003) * sin(phase).rustSignum * 0.35
            }
        default:
            return nil
        }
        return wav(samples)
    }

    private static func attack(_ t: Double, _ len: Double) -> Double { (t / len).rustMin(1.0) }

    private static func tone(_ secs: Double, _ f: (Double) -> Double) -> [Double] {
        let n = Int(rustCast: secs * Double(rate))
        return (0 ..< max(n, 0)).map { f(Double($0) / Double(rate)) }
    }

    /// A small deterministic noise source (-1..1).
    private struct Lcg {
        var state: UInt32
        init(_ s: UInt32) { state = s }
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(UInt32(1) << 23) - 1.0
        }
    }

    private static func wav(_ samples: [Double]) -> [UInt8] {
        let dataLen = UInt32(truncatingIfNeeded: samples.count * 2)
        var v: [UInt8] = []
        v.reserveCapacity(44 + Int(dataLen))
        func le32(_ x: UInt32) { v += [UInt8(x & 0xff), UInt8((x >> 8) & 0xff), UInt8((x >> 16) & 0xff), UInt8(x >> 24)] }
        func le16(_ x: UInt16) { v += [UInt8(x & 0xff), UInt8(x >> 8)] }
        v += Array("RIFF".utf8)
        le32(36 &+ dataLen)
        v += Array("WAVEfmt ".utf8)
        le32(16)
        le16(1) // PCM
        le16(1) // mono
        le32(rate)
        le32(rate * 2)
        le16(2)
        le16(16)
        v += Array("data".utf8)
        le32(dataLen)
        for s in samples {
            let x = Int16(rustCast: s.clamped(-1.0, 1.0) * 0.8 * Double(Int16.max))
            le16(UInt16(bitPattern: x))
        }
        return v
    }
}
