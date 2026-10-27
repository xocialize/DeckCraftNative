// DCAnim — evaluation of one animation effect at a progress value. Port of deckcraft
// crates/anim/src/effects.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import Darwin

/// Everything an effect needs besides its progress.
struct EffectSpec: Sendable {
    var animClass: AnimClass
    /// Base effect id (exit ids mapped to their entrance counterpart).
    var effect: String
    var option: String
    var accel: Double
    var decel: Double
    var bounce: Double
    var amount: Double?
    var color: Rgba?
    var path: MotionPath?
    /// Shape box in points (sanitized).
    var xf: Xfrm
    var slideW: Double
    var slideH: Double
}

/// Map an exit effect id to the entrance effect it mirrors.
func exitBase(_ effect: String) -> String {
    switch effect {
    case "disappear": "appear"
    case "fadeOut": "fade"
    case "flyOut": "fly"
    case "floatOut": "float"
    case "splitOut": "split"
    case "wipeOut": "wipe"
    case "shapeOut": "shape"
    case "wheelOut": "wheel"
    case "randomBarsOut": "randomBars"
    case "shrinkTurn": "grow"
    case "zoomOut": "zoom"
    case "swivelOut": "swivel"
    case "bounceOut": "bounce"
    case "dissolveOut": "dissolve"
    case "blindsOut": "blinds"
    case "boxOut": "box"
    case "checkerboardOut": "checkerboard"
    case "diamondOut": "diamond"
    case "peekOut": "peek"
    case "stripsOut": "strips"
    case "sinkDown": "rise"
    case "spinnerOut": "spinner"
    case "contract": "expand"
    default: effect
    }
}

/// Emphasis effects whose end state persists after they finish (PowerPoint keeps the spun angle, the new
/// size, the new colour and transparency).
func emphasisPersists(_ effect: String) -> Bool {
    switch effect {
    case "spin", "growShrink", "desaturate", "darken", "lighten", "transparency", "objectColor", "complementaryColor", "lineColor",
         "fillColor", "fontColor":
        true
    default: false
    }
}

private func usesDefaultSmoothing(_ effect: String) -> Bool {
    switch effect {
    case "fly", "float", "rise", "peek", "lines", "arcs", "turns", "shapes", "loops", "customPath": true
    default: presetPath(effect) != nil
    }
}

extension EffectSpec {
    /// Eased progress.
    func eased(_ p: Double) -> Double {
        if accel <= 0.0 && decel <= 0.0 && bounce <= 0.0 && usesDefaultSmoothing(effect) {
            smooth(p)
        } else {
            ease(p, accel, decel, bounce)
        }
    }

    /// The state delta at linear progress `p` (0...1) while the effect plays. `cur` is the shape's current
    /// fill colour (for colour emphasis).
    func eval(_ p0: Double, _ cur: Rgba) -> AnimState {
        let p = clampf(p0, 0.0, 1.0, 0.0)
        let s: AnimState = switch animClass {
        case .entrance: entrance(p, false)
        case .exit: entrance(1.0 - p, true)
        case .emphasis: emphasis(p, cur)
        case .path: motion(p)
        case .media: AnimState()
        }
        return s.sanitized()
    }

    /// The state the effect leaves behind once done.
    func endState(_ cur: Rgba) -> AnimState {
        switch animClass {
        case .entrance, .media: AnimState()
        case .exit: AnimState.hidden()
        case .emphasis where emphasisPersists(effect): emphasis(1.0, cur).sanitized()
        case .emphasis: AnimState()
        case .path: motion(1.0).sanitized()
        }
    }

    private func entrance(_ p: Double, _ exit: Bool) -> AnimState {
        let e = eased(p)
        let q = 1.0 - e
        let o = option
        let (x, y, w, h) = (xf.x, xf.y, xf.w, xf.h)
        let (sw, sh) = (slideW, slideH)
        var st = AnimState()
        func centerClip(_ f0: Double, _ horz: Bool, _ vert: Bool) -> SIMD4<Double>? {
            let f = f0.clamped(0.0, 1.0) / 2.0
            let (l, r) = horz ? (0.5 - f, 0.5 + f) : (0.0, 1.0)
            let (t, b) = vert ? (0.5 - f, 0.5 + f) : (0.0, 1.0)
            return SIMD4(l, t, r, b)
        }
        switch effect {
        case "appear":
            st.visible = p > 0.0
        case "fade", "dissolve", "randomBars", "blinds", "checkerboard", "wheel":
            st.opacity = e
        case "fly":
            let o = o.isEmpty ? "b" : o
            if o.bytesContain("l") { st.offsetX = -(x + w) * q }
            if o.bytesContain("r") { st.offsetX = (sw - x) * q }
            if o.bytesContain("t") { st.offsetY = -(y + h) * q }
            if o.bytesContain("b") { st.offsetY = (sh - y) * q }
        case "float", "rise":
            // Float Up enters from below and leaves upward; Float Down the reverse.
            let down = o == "d"
            var dir = down ? -1.0 : 1.0
            if exit { dir = -dir }
            st.offsetY = dir * 0.1 * sh * q
            st.opacity = e
        case "split":
            let horz = o.bytesHavePrefix("horz")
            // "In" closes from the edges: approximated with the centre reveal plus a fade.
            st.clip = horz ? centerClip(e, false, true) : centerClip(e, true, false)
            if o.bytesHaveSuffix("In") { st.opacity = e }
        case "wipe":
            st.clip = switch o {
            case "l": SIMD4(0.0, 0.0, e, 1.0)
            case "t": SIMD4(0.0, 0.0, 1.0, e)
            case "r": SIMD4(1.0 - e, 0.0, 1.0, 1.0)
            default: SIMD4(0.0, 1.0 - e, 1.0, 1.0)
            }
        case "shape", "circle", "box", "diamond", "expandClip":
            let round = effect == "circle" || effect == "diamond" || o.bytesHavePrefix("circle") || o.bytesHavePrefix("diamond")
                || o.bytesHavePrefix("plus")
            let f = round ? (e * 2.0.squareRoot()).rustMin(1.0) : e
            st.clip = centerClip(f, true, true)
            if o.bytesHaveSuffix("In") || o == "in" { st.opacity = e }
        case "grow":
            st.scaleX = e
            st.scaleY = e
            st.rotate = -90.0 * q
            st.opacity = e
        case "zoom":
            let s = o == "out" ? 1.0 + 3.0 * q : e
            st.scaleX = s
            st.scaleY = s
            st.opacity = e
        case "swivel":
            let s = e * Darwin.cos(q * 2.5 * Double.pi)
            if o == "vert" { st.scaleY = s } else { st.scaleX = s }
            st.opacity = e.rustMin(1.0)
        case "bounce":
            let b = bounceOut(p)
            st.offsetY = -(0.25 * sh) * (1.0 - b)
            st.offsetX = -0.1 * sw * (1.0 - p)
            st.opacity = (p * 4.0).rustMin(1.0)
        case "peek":
            switch o {
            case "l":
                st.offsetX = -w * q
                st.clip = SIMD4(q, 0.0, 1.0, 1.0)
            case "r":
                st.offsetX = w * q
                st.clip = SIMD4(0.0, 0.0, e, 1.0)
            case "t":
                st.offsetY = -h * q
                st.clip = SIMD4(0.0, q, 1.0, 1.0)
            default:
                st.offsetY = h * q
                st.clip = SIMD4(0.0, 0.0, 1.0, e)
            }
        case "strips":
            st.clip = switch o {
            case "ru": SIMD4(0.0, q, e, 1.0)
            case "ld": SIMD4(q, 0.0, 1.0, e)
            case "rd": SIMD4(0.0, 0.0, e, e)
            default: SIMD4(q, q, 1.0, 1.0)
            }
        case "expand":
            st.scaleX = 0.3 + 0.7 * e
            st.opacity = e
        case "spinner":
            st.rotate = 360.0 * q
            st.scaleX = 0.5 + 0.5 * e
            st.scaleY = 0.5 + 0.5 * e
            st.opacity = e
        default:
            st.opacity = e
        }
        return st
    }

    private func emphasis(_ p: Double, _ cur: Rgba) -> AnimState {
        let e = eased(p)
        let bump = Darwin.sin(p * Double.pi)
        var st = AnimState()
        let target = color ?? Rgba.rgb(0xC0, 0x00, 0x00)
        switch effect {
        case "pulse":
            st.scaleX = 1.0 + 0.1 * bump
            st.scaleY = st.scaleX
        case "colorPulse":
            st.tint = cur.lerp(target, bump)
        case "teeter":
            st.rotate = 8.0 * Darwin.sin(p * 4.0 * Double.pi) * (1.0 - p * 0.5)
        case "spin":
            let amt = (amount.flatMap { $0.isFinite ? $0 : nil } ?? 360.0).clamped(-36_000.0, 36_000.0)
            let sign = option == "counterClockwise" ? -1.0 : 1.0
            st.rotate = sign * amt * e
        case "growShrink":
            let amt = (amount.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil } ?? 1.5).clamped(0.0, 100.0)
            let s = 1.0 + (amt - 1.0) * e
            switch option {
            case "horz": st.scaleX = s
            case "vert": st.scaleY = s
            default:
                st.scaleX = s
                st.scaleY = s
            }
        case "desaturate":
            let lum = (0.299 * Double(cur.r) + 0.587 * Double(cur.g) + 0.114 * Double(cur.b)).rounded().clamped(0.0, 255.0)
            let l = UInt8(rustCast: lum)
            st.tint = cur.lerp(Rgba.rgba(l, l, l, cur.a), e)
        case "darken":
            st.tint = cur.lerp(Rgba.rgba(0, 0, 0, cur.a), 0.4 * e)
        case "lighten":
            st.tint = cur.lerp(Rgba.rgba(255, 255, 255, cur.a), 0.4 * e)
        case "transparency":
            // `amount` is the transparency (0.5 = 50 %).
            let a = (amount.flatMap { $0.isFinite ? $0 : nil } ?? 0.5).clamped(0.0, 1.0)
            st.opacity = 1.0 - a * e
        case "objectColor", "fillColor", "lineColor", "fontColor":
            st.tint = cur.lerp(target, e)
        case "complementaryColor":
            st.tint = cur.lerp(Rgba.rgba(255 - cur.r, 255 - cur.g, 255 - cur.b, cur.a), e)
        case "underline", "boldFlash":
            st.scaleX = 1.0 + 0.04 * bump
            st.scaleY = st.scaleX
            if effect == "boldFlash" { st.tint = cur.lerp(Rgba.rgba(0, 0, 0, cur.a), 0.3 * bump) }
        case "wave":
            st.offsetY = -0.02 * slideH * bump
            st.scaleY = 1.0 + 0.05 * bump
        default:
            break
        }
        return st
    }

    private func motion(_ p: Double) -> AnimState {
        let e = eased(p)
        let (fx, fy) = path.map { $0.at(e) } ?? (0.0, 0.0)
        return AnimState(offsetX: fx * slideW, offsetY: fy * slideH)
    }
}

/// The path for a motion-path animation: its own, or the preset default.
func motionPath(_ effect: String, _ option: String, _ own: String?) -> MotionPath {
    if let s = own, !rustTrim(s).isEmpty { return MotionPath.parse(s) }
    return MotionPath.parse(defaultPath(effect, option))
}
