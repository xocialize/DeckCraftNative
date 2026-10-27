// DCModel — slide transitions and object animations. Port of deckcraft crates/model/src/anim.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Animations are kept as the flat, ordered list the Animation Pane shows; the PPTX writer builds the
// nested timing tree from it and the reader flattens files back into it.
import DCCore
import Darwin

extension Transition {
    public static var `default`: Transition {
        Transition(
            kind: "none", option: "", durationMs: 1000, advanceOnClick: true, advanceAfterMs: nil, sound: nil,
            soundLoop: false, stopSound: false, raw: nil
        )
    }
}

/// One transition of the gallery: id, label, category, default duration ms, effect options.
public struct TransitionInfo: Sendable {
    public let id: String
    public let label: String
    public let category: String
    public let defaultDurationMs: UInt32
    public let options: [String]
}

public let transitions: [TransitionInfo] = [
    ("none", "None", "Subtle", 0, []),
    ("morph", "Morph", "Subtle", 2000, ["objects", "words", "characters"]),
    ("fade", "Fade", "Subtle", 700, ["smoothly", "throughBlack"]),
    ("push", "Push", "Subtle", 1000, ["u", "d", "l", "r"]),
    ("wipe", "Wipe", "Subtle", 1000, ["r", "l", "u", "d", "ru", "lu", "rd", "ld"]),
    ("split", "Split", "Subtle", 1500, ["vertOut", "vertIn", "horzOut", "horzIn"]),
    ("reveal", "Reveal", "Subtle", 2000, ["smoothlyLeft", "smoothlyRight", "blackLeft", "blackRight"]),
    ("cut", "Cut", "Subtle", 0, ["", "throughBlack"]),
    ("randomBar", "Random Bars", "Subtle", 1000, ["vert", "horz"]),
    ("shape", "Shape", "Subtle", 2000, ["circle", "diamond", "plus", "in", "out"]),
    ("uncover", "Uncover", "Subtle", 1000, ["l", "r", "u", "d", "lu", "ru", "ld", "rd"]),
    ("cover", "Cover", "Subtle", 1000, ["l", "r", "u", "d", "lu", "ru", "ld", "rd"]),
    ("flash", "Flash", "Subtle", 1000, []),
    ("fallOver", "Fall Over", "Exciting", 2000, ["l", "r"]),
    ("drape", "Drape", "Exciting", 2000, ["l", "r"]),
    ("curtains", "Curtains", "Exciting", 2000, []),
    ("wind", "Wind", "Exciting", 2000, ["l", "r"]),
    ("prestige", "Prestige", "Exciting", 2000, []),
    ("fracture", "Fracture", "Exciting", 2000, []),
    ("crush", "Crush", "Exciting", 2000, []),
    ("peelOff", "Peel Off", "Exciting", 1500, ["l", "r"]),
    ("pageCurlDouble", "Page Curl", "Exciting", 1500, ["l", "r", "singleL", "singleR"]),
    ("airplane", "Airplane", "Exciting", 2000, ["l", "r"]),
    ("origami", "Origami", "Exciting", 2000, ["l", "r"]),
    ("dissolve", "Dissolve", "Exciting", 1200, []),
    ("checker", "Checkerboard", "Exciting", 1500, ["horz", "vert"]),
    ("blinds", "Blinds", "Exciting", 1600, ["vert", "horz"]),
    ("clock", "Clock", "Exciting", 2000, ["clockwise", "counterClockwise", "wedge"]),
    ("ripple", "Ripple", "Exciting", 1400, ["center", "lu", "ru", "ld", "rd"]),
    ("honeycomb", "Honeycomb", "Exciting", 3000, []),
    ("glitter", "Glitter", "Exciting", 2500, ["l", "r", "u", "d", "hexL", "hexR", "hexU", "hexD"]),
    ("vortex", "Vortex", "Exciting", 3000, ["l", "r", "u", "d"]),
    ("shred", "Shred", "Exciting", 2000, ["stripsIn", "stripsOut", "particlesIn", "particlesOut"]),
    ("switch", "Switch", "Exciting", 1250, ["l", "r"]),
    ("flip", "Flip", "Exciting", 1250, ["l", "r"]),
    ("gallery", "Gallery", "Exciting", 1500, ["l", "r"]),
    ("cube", "Cube", "Exciting", 1250, ["l", "r", "u", "d"]),
    ("doors", "Doors", "Exciting", 1400, ["vert", "horz"]),
    ("box", "Box", "Exciting", 1250, ["l", "r", "u", "d"]),
    ("comb", "Comb", "Exciting", 1000, ["horz", "vert"]),
    ("zoom", "Zoom", "Exciting", 1000, ["in", "out", "rotate"]),
    ("random", "Random", "Exciting", 2000, []),
    ("pan", "Pan", "Dynamic Content", 1000, ["u", "d", "l", "r"]),
    ("ferris", "Ferris Wheel", "Dynamic Content", 2000, ["l", "r"]),
    ("conveyor", "Conveyor", "Dynamic Content", 2000, ["l", "r"]),
    ("rotate", "Rotate", "Dynamic Content", 2000, ["l", "r", "u", "d"]),
    ("window", "Window", "Dynamic Content", 1250, ["vert", "horz"]),
    ("orbit", "Orbit", "Dynamic Content", 2000, ["l", "r", "u", "d"]),
    ("flythrough", "Fly Through", "Dynamic Content", 1000, ["in", "out", "inBounce", "outBounce"]),
].map { TransitionInfo(id: $0.0, label: $0.1, category: $0.2, defaultDurationMs: $0.3, options: $0.4) }

/// The Effect Options label PowerPoint shows for a transition option. Options are stored as the file
/// format's values: for moving transitions (Push, Wipe, Cover, Pan, Cube…) the direction things move,
/// so "l" is the effect coming "From Right"; Glitter and the preset effects (Fall Over, Wind…) name the
/// side itself; Ripple names where the wave heads.
public func transitionOptionLabel(_ kind: String, _ option: String) -> String {
    func side(_ c: Character) -> String {
        switch c {
        case "l": "Left"
        case "r": "Right"
        case "u": "Top"
        default: "Bottom"
        }
    }
    func opposite(_ c: Character) -> Character {
        switch c {
        case "l": "r"
        case "r": "l"
        case "u": "d"
        default: "u"
        }
    }
    func corner(_ o: String, _ flip: Bool) -> String? {
        let cs = Array(o)
        guard cs.count >= 2 else { return nil }
        let (h, v) = flip ? (opposite(cs[0]), opposite(cs[1])) : (cs[0], cs[1])
        return "From \(side(v))-\(side(h))"
    }
    let moving = [
        "push", "wipe", "cover", "uncover", "pan", "vortex", "cube", "box", "rotate", "orbit", "gallery", "conveyor",
        "ferris", "switch", "flip",
    ].contains(kind)
    let o = option
    switch (kind, o) {
    case (_, "horz"): return "Horizontal"
    case (_, "vert"): return "Vertical"
    case ("split", _): return "\(o.hasPrefix("horz") ? "Horizontal" : "Vertical") \(o.hasSuffix("In") ? "In" : "Out")"
    case ("fade", "throughBlack"), ("cut", "throughBlack"): return "Through Black"
    case ("fade", _): return "Smoothly"
    case ("cut", _): return "Cut"
    case ("clock", "counterClockwise"): return "Counterclockwise"
    case ("clock", "wedge"): return "Wedge"
    case ("clock", _): return "Clockwise"
    case ("zoom", "rotate"): return "Zoom and Rotate"
    case ("ripple", "center"): return "Center"
    case ("ripple", _): return corner(o, true) ?? "Center"
    case ("glitter", _):
        let (pat, d) = o.hasPrefix("hex") ? ("Hexagons", rustASCIILowercase(String(o.dropFirst(3)))) : ("Diamonds", o)
        return "\(pat) From \(side(d.first ?? "l"))"
    case ("pageCurlDouble", _):
        switch o {
        case "singleL": return "Single Left"
        case "singleR": return "Single Right"
        case "r": return "Double Right"
        default: return "Double Left"
        }
    case ("shred", _):
        return "\(o.hasPrefix("particles") ? "Particles" : "Strips") \(o.hasSuffix("Out") ? "Out" : "In")"
    case ("reveal", _):
        return "\(o.hasPrefix("black") ? "Through Black" : "Smoothly") \(o.hasSuffix("Right") ? "From Right" : "From Left")"
    case ("flythrough", _):
        return "\(o.hasPrefix("out") ? "Out" : "In")\(o.hasSuffix("Bounce") ? " with Bounce" : "")"
    case ("morph", _):
        switch o {
        case "words": return "Words"
        case "characters": return "Characters"
        default: return "Objects"
        }
    default:
        break
    }
    // Rust's `str::len` counts bytes.
    if o.utf8.count == 2 && moving { return corner(o, true) ?? "" }
    if o.utf8.count == 1 && moving { return "From \(side(opposite(o.first ?? "l")))" }
    switch o {
    case "l": return "Left"
    case "r": return "Right"
    case "u": return "Top"
    case "d": return "Bottom"
    case "in": return "In"
    case "out": return "Out"
    default: return o
    }
}

extension AnimClass {
    public var xml: String {
        switch self {
        case .entrance: "entr"
        case .emphasis: "emph"
        case .exit: "exit"
        case .path: "path"
        case .media: "mediacall"
        }
    }

    public static func fromXML(_ s: String) -> AnimClass {
        switch s {
        case "emph": .emphasis
        case "exit": .exit
        case "path": .path
        case "mediacall": .media
        default: .entrance
        }
    }
}

/// Most paragraphs a by-paragraph build animates separately; later ones follow the last of them.
public let maxBuildParagraphs = 1_000

/// What a paragraph does in a by-paragraph build.
public enum BuildRole: Sendable, Equatable {
    /// Animated on its own: a filled paragraph at the shallowest filled level.
    case top
    /// Follows the top paragraph with this index (deeper, empty or blank paragraphs after it).
    case member(Int)
    /// Before the first top paragraph: not animated.
    case unowned
}

/// Does the paragraph show any text? A by-paragraph build doesn't animate blank ones on their own.
public func buildFilled(_ p: Paragraph) -> Bool {
    p.runs.contains { !rustTrim($0.text).isEmpty }
}

/// The role of every paragraph of `text` in a by-paragraph build, by paragraph index: what the
/// timeline plays, and what the PPTX reader and writer map to one file effect per paragraph.
public func paragraphBuildRoles(_ text: TextBody) -> [BuildRole] {
    let top = text.paragraphs.filter(buildFilled).map(\.level).min() ?? 0
    var tops = 0
    var owner: Int?
    return text.paragraphs.enumerated().map { i, p in
        if p.level <= top && buildFilled(p) && tops < maxBuildParagraphs {
            tops += 1
            owner = i
            return .top
        }
        return owner.map(BuildRole.member) ?? .unowned
    }
}

extension Animation {
    public static var `default`: Animation {
        Animation(
            shape: ShapeId(0), class: .entrance, effect: "fade", option: "", start: .onClick, durationMs: 500,
            delayMs: 0, repeat: 1, rewind: false, textBuild: .asOne, paragraph: nil, path: nil, trigger: nil,
            amount: nil, color: nil, presetId: nil, presetSubtype: nil, after: nil, sound: nil, smoothStart: 0.0,
            smoothEnd: 0.0, bounceEnd: 0.0, autoReverse: false
        )
    }
}

/// One animation effect of the gallery: id, label, class, PowerPoint preset id, default duration ms,
/// options.
public struct AnimationInfo: Sendable {
    public let id: String
    public let label: String
    public let animClass: AnimClass
    public let presetId: UInt32
    public let defaultDurationMs: UInt32
    public let options: [String]
}

public let animations: [AnimationInfo] = [
    ("appear", "Appear", AnimClass.entrance, 1, 0, []),
    ("fade", "Fade", .entrance, 10, 500, []),
    ("fly", "Fly In", .entrance, 2, 500, ["b", "lb", "l", "lt", "t", "rt", "r", "rb"]),
    ("float", "Float In", .entrance, 42, 1000, ["u", "d"]),
    ("split", "Split", .entrance, 16, 500, ["horzIn", "horzOut", "vertIn", "vertOut"]),
    ("wipe", "Wipe", .entrance, 22, 500, ["b", "l", "t", "r"]),
    ("shape", "Shape", .entrance, 6, 2000, ["circleIn", "circleOut", "boxIn", "boxOut", "diamondIn", "diamondOut", "plusIn", "plusOut"]),
    ("wheel", "Wheel", .entrance, 21, 2000, ["1", "2", "3", "4", "8"]),
    ("randomBars", "Random Bars", .entrance, 14, 500, ["horz", "vert"]),
    ("grow", "Grow & Turn", .entrance, 31, 500, []),
    ("zoom", "Zoom", .entrance, 53, 500, ["in", "out"]),
    ("swivel", "Swivel", .entrance, 45, 2000, ["horz", "vert"]),
    ("bounce", "Bounce", .entrance, 26, 2000, []),
    ("blinds", "Blinds", .entrance, 3, 500, ["horz", "vert"]),
    ("box", "Box", .entrance, 4, 500, ["in", "out"]),
    ("checkerboard", "Checkerboard", .entrance, 5, 500, ["across", "down"]),
    ("circle", "Circle", .entrance, 6, 500, ["in", "out"]),
    ("diamond", "Diamond", .entrance, 8, 500, ["in", "out"]),
    ("dissolve", "Dissolve In", .entrance, 9, 500, []),
    ("peek", "Peek In", .entrance, 12, 500, ["b", "l", "t", "r"]),
    ("strips", "Strips", .entrance, 18, 500, ["lu", "ru", "ld", "rd"]),
    ("expand", "Expand", .entrance, 55, 500, []),
    ("rise", "Rise Up", .entrance, 37, 1000, []),
    ("spinner", "Spinner", .entrance, 49, 1000, []),
    ("pulse", "Pulse", .emphasis, 26, 500, []),
    ("colorPulse", "Color Pulse", .emphasis, 27, 500, []),
    ("teeter", "Teeter", .emphasis, 32, 1000, []),
    ("spin", "Spin", .emphasis, 8, 2000, ["clockwise", "counterClockwise"]),
    ("growShrink", "Grow/Shrink", .emphasis, 6, 2000, ["both", "horz", "vert"]),
    ("desaturate", "Desaturate", .emphasis, 35, 500, []),
    ("darken", "Darken", .emphasis, 25, 500, []),
    ("lighten", "Lighten", .emphasis, 30, 500, []),
    ("transparency", "Transparency", .emphasis, 9, 500, []),
    ("objectColor", "Object Color", .emphasis, 19, 2000, []),
    ("complementaryColor", "Complementary Color", .emphasis, 21, 500, []),
    ("lineColor", "Line Color", .emphasis, 7, 2000, []),
    ("fillColor", "Fill Color", .emphasis, 1, 2000, []),
    ("fontColor", "Font Color", .emphasis, 3, 2000, []),
    ("underline", "Underline", .emphasis, 18, 500, []),
    ("boldFlash", "Bold Flash", .emphasis, 10, 500, []),
    ("wave", "Wave", .emphasis, 34, 500, []),
    ("disappear", "Disappear", .exit, 1, 0, []),
    ("fadeOut", "Fade", .exit, 10, 500, []),
    ("flyOut", "Fly Out", .exit, 2, 500, ["b", "lb", "l", "lt", "t", "rt", "r", "rb"]),
    ("floatOut", "Float Out", .exit, 42, 1000, ["u", "d"]),
    ("splitOut", "Split", .exit, 16, 500, ["horzIn", "horzOut", "vertIn", "vertOut"]),
    ("wipeOut", "Wipe", .exit, 22, 500, ["b", "l", "t", "r"]),
    ("shapeOut", "Shape", .exit, 6, 2000, ["circleIn", "circleOut"]),
    ("wheelOut", "Wheel", .exit, 21, 2000, ["1", "2", "3", "4", "8"]),
    ("randomBarsOut", "Random Bars", .exit, 14, 500, ["horz", "vert"]),
    ("shrinkTurn", "Shrink & Turn", .exit, 31, 500, []),
    ("zoomOut", "Zoom", .exit, 53, 500, ["in", "out"]),
    ("swivelOut", "Swivel", .exit, 45, 2000, ["horz", "vert"]),
    ("bounceOut", "Bounce", .exit, 26, 2000, []),
    ("dissolveOut", "Dissolve Out", .exit, 9, 500, []),
    ("blindsOut", "Blinds", .exit, 3, 500, ["horz", "vert"]),
    ("boxOut", "Box", .exit, 4, 500, ["in", "out"]),
    ("checkerboardOut", "Checkerboard", .exit, 5, 500, ["across", "down"]),
    ("diamondOut", "Diamond", .exit, 8, 500, ["in", "out"]),
    ("peekOut", "Peek Out", .exit, 12, 500, ["b", "l", "t", "r"]),
    ("stripsOut", "Strips", .exit, 18, 500, ["lu", "ru", "ld", "rd"]),
    ("sinkDown", "Sink Down", .exit, 37, 1000, []),
    ("spinnerOut", "Spinner", .exit, 49, 1000, []),
    ("contract", "Contract", .exit, 55, 500, []),
    ("lines", "Lines", .path, 64, 2000, ["down", "up", "right", "left"]),
    ("arcs", "Arcs", .path, 37, 2000, ["down", "up", "right", "left"]),
    ("turns", "Turns", .path, 43, 2000, ["down", "up", "right", "left"]),
    ("shapes", "Shapes", .path, 1, 2000, ["circle", "diamond", "hexagon", "triangle", "square", "trapezoid", "octagon", "parallelogram", "pentagon"]),
    ("loops", "Loops", .path, 61, 2000, []),
    ("diagonalDownRight", "Diagonal Down Right", .path, 49, 2000, []),
    ("diagonalUpRight", "Diagonal Up Right", .path, 56, 2000, []),
    ("zigzag", "Zigzag", .path, 38, 2000, []),
    ("sineWave", "Sine Wave", .path, 40, 2000, []),
    ("pathWave", "Wave", .path, 47, 2000, []),
    ("decayingWave", "Decaying Wave", .path, 60, 2000, []),
    ("heartbeat", "Heartbeat", .path, 45, 2000, []),
    ("sCurve1", "S Curve 1", .path, 59, 2000, []),
    ("sCurve2", "S Curve 2", .path, 39, 2000, []),
    ("stairsDown", "Stairs Down", .path, 62, 2000, []),
    ("bounceRight", "Bounce Right", .path, 54, 2000, []),
    ("bounceLeft", "Bounce Left", .path, 41, 2000, []),
    ("spiralRight", "Spiral Right", .path, 46, 2000, []),
    ("spiralLeft", "Spiral Left", .path, 55, 2000, []),
    ("spring", "Spring", .path, 53, 2000, []),
    ("funnel", "Funnel", .path, 52, 2000, []),
    ("swoosh", "Swoosh", .path, 30, 2000, []),
    ("star4", "4 Point Star", .path, 16, 2000, []),
    ("star5", "5 Point Star", .path, 5, 2000, []),
    ("star6", "6 Point Star", .path, 11, 2000, []),
    ("star8", "8 Point Star", .path, 17, 2000, []),
    ("heart", "Heart", .path, 9, 2000, []),
    ("crescentMoon", "Crescent Moon", .path, 6, 2000, []),
    ("teardrop", "Teardrop", .path, 18, 2000, []),
    ("football", "Football", .path, 12, 2000, []),
    ("plusPath", "Plus", .path, 32, 2000, []),
    ("rightTriangle", "Right Triangle", .path, 2, 2000, []),
    ("curvedSquare", "Curved Square", .path, 20, 2000, []),
    ("figure8Horizontal", "Horizontal Figure 8", .path, 26, 2000, []),
    ("figure8Vertical", "Vertical Figure 8", .path, 22, 2000, []),
    ("loopDeLoop", "Loop de Loop", .path, 24, 2000, []),
    ("bean", "Bean", .path, 31, 2000, []),
    ("peanut", "Peanut", .path, 27, 2000, []),
    ("neutron", "Neutron", .path, 29, 2000, []),
    ("customPath", "Custom Path", .path, 0, 2000, []),
    ("play", "Play", .media, 1, 0, []),
    ("pause", "Pause", .media, 2, 0, []),
    ("stop", "Stop", .media, 3, 0, []),
].map { AnimationInfo(id: $0.0, label: $0.1, animClass: $0.2, presetId: $0.3, defaultDurationMs: $0.4, options: $0.5) }

public func animationInfo(_ effect: String, _ animClass: AnimClass) -> AnimationInfo? {
    animations.first { $0.id == effect && $0.animClass == animClass } ?? animations.first { $0.id == effect }
}

/// Rust's `f64::signum`: ±1 by the sign bit (so ±0 give ±1), NaN for NaN.
private func signum(_ v: Double) -> Double {
    v.isNaN ? .nan : (v.sign == .minus ? -1.0 : 1.0)
}

/// Rust's `{:.4}`.
private func f4(_ v: Double) -> String { rustFixed(v, places: 4) }

/// The path of a motion-path preset beyond Lines, Arcs, Turns, Shapes and Loops, in slide fractions
/// from the shape's position (the path syntax: `M`, `L`, `Z`, ending in `E`). nil for an effect that
/// isn't one of these presets.
public func presetPath(_ effect: String) -> String? {
    let pi = Double.pi
    let tau = 2.0 * Double.pi
    // Sample `f` over 0...1 into a polyline starting at (0, 0).
    func poly(_ n: Int, _ closed: Bool, _ f: (Double) -> (Double, Double)) -> String {
        let (x0, y0) = f(0.0)
        var s = "M 0 0"
        for k in 1 ... n {
            let (x, y) = f(Double(k) / Double(n))
            s += " L \(f4(x - x0)) \(f4(y - y0))"
        }
        if closed { s += " Z" }
        s += " E"
        return s
    }
    func pts(_ p: [(Double, Double)], _ closed: Bool) -> String {
        var s = "M 0 0"
        for (x, y) in p { s += " L \(f4(x)) \(f4(y))" }
        if closed { s += " Z" }
        s += " E"
        return s
    }
    // A closed curve in polar form r(θ), starting at its top.
    func polar(_ scale: Double, _ r: (Double) -> Double) -> String {
        poly(96, true) { t in
            let a = -pi / 2.0 + tau * t
            let rr = r(a + pi / 2.0) * scale
            return (rr * cos(a), rr * sin(a))
        }
    }
    func star(_ n: Int, _ outer: Double, _ inner: Double) -> String {
        var p: [(Double, Double)] = []
        let start = (0.0, -outer)
        for k in 1 ... 2 * n {
            let a = -pi / 2.0 + pi * Double(k) / Double(n)
            let r = k % 2 == 1 ? inner : outer
            p.append((r * cos(a) - start.0, r * sin(a) - start.1))
        }
        return pts(p, true)
    }
    func spiral(_ dir: Double) -> String {
        poly(120, false) { t in
            let r = 0.12 * (1.0 - t)
            let a = dir * 3.0 * tau * t
            return (dir * (0.12 - r * cos(a)), -r * sin(a))
        }
    }
    func bounce(_ dir: Double) -> String {
        poly(90, false) { t in (dir * 0.3 * t, 0.15 * t - 0.1 * (1.0 - t) * Swift.abs(sin(3.0 * pi * t))) }
    }
    switch effect {
    case "diagonalDownRight": return pts([(0.2, 0.2)], false)
    case "diagonalUpRight": return pts([(0.2, -0.2)], false)
    case "zigzag": return pts([(0.05, 0.04), (0.1, 0.0), (0.15, 0.04), (0.2, 0.0), (0.25, 0.04), (0.3, 0.0)], false)
    case "sineWave": return poly(64, false) { t in (0.3 * t, 0.04 * sin(2.0 * tau * t)) }
    case "pathWave": return poly(48, false) { t in (0.3 * t, 0.06 * sin(tau * t)) }
    case "decayingWave": return poly(96, false) { t in (0.3 * t, 0.07 * exp(-3.0 * t) * sin(3.0 * tau * t)) }
    case "heartbeat": return pts([(0.08, 0.0), (0.1, -0.08), (0.13, 0.06), (0.15, 0.0), (0.25, 0.0)], false)
    case "sCurve1": return poly(48, false) { t in (0.2 * t, 0.1 - 0.1 * cos(pi * t)) }
    case "sCurve2": return poly(48, false) { t in (0.1 - 0.1 * cos(pi * t), 0.2 * t) }
    case "stairsDown": return pts([(0.06, 0.0), (0.06, 0.06), (0.12, 0.06), (0.12, 0.12), (0.18, 0.12), (0.18, 0.18)], false)
    case "bounceRight": return bounce(1.0)
    case "bounceLeft": return bounce(-1.0)
    case "spiralRight": return spiral(1.0)
    case "spiralLeft": return spiral(-1.0)
    case "spring": return poly(160, false) { t in (0.3 * t + 0.03 * cos(5.0 * tau * t), 0.03 * sin(5.0 * tau * t)) }
    case "funnel":
        return poly(160, false) { t in
            let r = 0.12 * (1.0 - t)
            return (r * cos(3.0 * tau * t), 0.25 * t + 0.03 * sin(3.0 * tau * t) * (1.0 - t))
        }
    case "swoosh": return poly(48, false) { t in (0.3 * t, -0.12 * sin(pi * t) + 0.1 * t * t) }
    case "star4": return star(4, 0.1, 0.04)
    case "star5": return star(5, 0.1, 0.04)
    case "star6": return star(6, 0.1, 0.05)
    case "star8": return star(8, 0.1, 0.06)
    case "heart":
        return poly(96, true) { t in
            let a = tau * t
            let s = sin(a)
            // Rust's `powi(3)` lowers to multiplications.
            return (0.006 * 16.0 * (s * s * s), -0.006 * (13.0 * cos(a) - 5.0 * cos(2.0 * a) - 2.0 * cos(3.0 * a) - cos(4.0 * a)))
        }
    case "crescentMoon":
        // The outer arc of a circle, back along a smaller, offset one.
        var p: [(Double, Double)] = (1 ... 32).map { k in
            let a = -pi / 2.0 - pi * Double(k) / 32.0
            return (0.1 * cos(a), 0.1 + 0.1 * sin(a))
        }
        p += (1 ... 32).map { k in
            let a = pi / 2.0 - pi * Double(k) / 32.0
            return (0.06 * cos(a) - 0.03, 0.1 + 0.1 * sin(a))
        }
        return pts(p, true)
    case "teardrop": return polar(0.1) { a in 0.6 + 0.4 * pow(Swift.abs(cos(a / 2.0)), 3.0) }
    case "football":
        return poly(64, true) { t in
            let a = tau * t
            return (0.12 * sin(a), 0.06 * (1.0 - cos(a)) * (1.0 - 0.3 * Swift.abs(cos(2.0 * a))))
        }
    case "plusPath":
        return pts([
            (0.04, 0.0), (0.04, 0.04), (0.08, 0.04), (0.08, 0.08), (0.04, 0.08), (0.04, 0.12), (0.0, 0.12),
            (0.0, 0.08), (-0.04, 0.08), (-0.04, 0.04), (0.0, 0.04),
        ], true)
    case "rightTriangle": return pts([(0.0, 0.15), (0.15, 0.15)], true)
    case "curvedSquare":
        return poly(96, true) { t in
            let a = -pi / 2.0 + tau * t
            func sg(_ v: Double) -> Double { signum(v) * Swift.abs(v).squareRoot() }
            return (0.1 * sg(cos(a)), 0.1 + 0.1 * sg(sin(a)))
        }
    case "figure8Horizontal":
        return poly(96, true) { t in
            let a = tau * t
            return (0.15 * sin(a), 0.06 * sin(2.0 * a))
        }
    case "figure8Vertical":
        return poly(96, true) { t in
            let a = tau * t
            return (0.06 * sin(2.0 * a), 0.15 * (1.0 - cos(a)))
        }
    case "loopDeLoop":
        return poly(120, false) { t in (0.3 * t - 0.05 * sin(2.0 * tau * t), -0.05 * (1.0 - cos(2.0 * tau * t))) }
    case "bean": return polar(0.1) { a in 0.75 + 0.25 * cos(a) + 0.15 * cos(2.0 * a) }
    case "peanut": return polar(0.1) { a in 0.7 + 0.3 * Swift.abs(cos(2.0 * a)) }
    case "neutron": return polar(0.1) { a in 0.35 + 0.65 * Swift.abs(cos(3.0 * a)) }
    default: return nil
    }
}
