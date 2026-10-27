// DCAnim — time easing: acceleration / deceleration fractions and bounce. Port of deckcraft
// crates/anim/src/easing.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import Darwin

/// Map linear progress `p` (0...1) through PowerPoint-style easing: `accel` and `decel` are the fractions of
/// the duration spent speeding up and slowing down (velocity ramps linearly); `bounce` (0...1) makes the
/// last part of the motion bounce against the end.
public func ease(_ p0: Double, _ accel: Double, _ decel: Double, _ bounce: Double) -> Double {
    let p = clampf(p0, 0.0, 1.0, 0.0)
    var a = clampf(accel, 0.0, 1.0, 0.0)
    var d = clampf(decel, 0.0, 1.0, 0.0)
    if a + d > 1.0 {
        let s = a + d
        a /= s
        d /= s
    }
    let v = 2.0 / (2.0 - a - d)
    var y: Double
    if a > 0.0 && p < a {
        y = v * p * p / (2.0 * a)
    } else if d > 0.0 && p > 1.0 - d {
        let q = 1.0 - p
        y = 1.0 - v * q * q / (2.0 * d)
    } else {
        y = v * a / 2.0 + v * (p - a)
    }
    let b = clampf(bounce, 0.0, 1.0, 0.0)
    if b > 0.0 {
        // Reach the end early, then bounce back with decaying hops over the last `b` fraction.
        let hit = 1.0 - b
        if p < hit {
            let q = hit > 0.0 ? p / hit : 1.0
            y = q * q
        } else {
            let s = (p - hit) / b
            y = 1.0 - bounceHops(s) * 0.25
        }
    }
    return clampf(y, -1.0, 2.0, 0.0)
}

/// Decaying hops for s in 0...1: 0 at the ends of each hop, peaks shrinking.
private func bounceHops(_ s0: Double) -> Double {
    let s = clampf(s0, 0.0, 1.0, 1.0)
    let hops = 3.0
    let k = (s * hops).rounded(.down).rustMin(hops - 1.0)
    let local = s * hops - k
    let amp = Darwin.pow(0.5, k)
    return amp * Darwin.sin(local * Double.pi)
}

/// Classic bounce-out: falls to 1 and bounces with decaying height.
func bounceOut(_ p0: Double) -> Double {
    let p = clampf(p0, 0.0, 1.0, 0.0)
    let n = 7.5625
    let d = 2.75
    let y: Double
    if p < 1.0 / d {
        y = n * p * p
    } else if p < 2.0 / d {
        let q = p - 1.5 / d
        y = n * q * q + 0.75
    } else if p < 2.5 / d {
        let q = p - 2.25 / d
        y = n * q * q + 0.9375
    } else {
        let q = p - 2.625 / d
        y = n * q * q + 0.984375
    }
    return y.rustMin(1.0)
}

/// Smooth ease-in-out (cubic smoothstep).
func smooth(_ p0: Double) -> Double {
    let p = clampf(p0, 0.0, 1.0, 0.0)
    return p * p * (3.0 - 2.0 * p)
}
