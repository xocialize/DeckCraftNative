// DCAppModel — the Format pane's fill logic without a window: the gradient editor's edits and presets, the
// pattern gallery, fills as command parameters, and the transparency rules of Fill & Line. Port of deckcraft
// `crates/ui-egui/src/fillui.rs` and the pure helpers of `panes.rs` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
import DCColor
import DCCore
import DCEngine
import DCModel

public enum InspectorFill {
    // MARK: Kinds

    /// Fill & Line's radio choice for a shape's fill (`auto` when it follows the theme style).
    public static func kind(_ fill: Fill?) -> String {
        switch fill {
        case nil: "auto"
        case .none_?: "none"
        case .solid?: "solid"
        case .gradient?: "gradient"
        case .picture?: "picture"
        case .pattern?: "pattern"
        default: "auto"
        }
    }

    /// The fill choices of Format Shape ▸ Fill: label and kind.
    public static let shapeKinds: [(label: String, kind: String)] = [
        ("No fill", "none"), ("Solid fill", "solid"), ("Gradient fill", "gradient"),
        ("Picture or texture fill", "picture"), ("Pattern fill", "pattern"), ("Automatic", "auto"),
    ]

    /// The fill choices of Format Background.
    public static let backgroundKinds: [(label: String, kind: String)] = [
        ("Solid fill", "solid"), ("Gradient fill", "gradient"), ("Picture or texture fill", "picture"),
        ("Pattern fill", "pattern"), ("Follow the layout", "auto"),
    ]

    /// `shape.fill` parameters that switch the selection to fill kind `kind` (`picture` asks for a file).
    public static func shapeKindParams(_ kind: String) -> JSON? {
        switch kind {
        case "none": ["none": true]
        case "solid": ["color": "accent1"]
        case "gradient": ["gradient": ["stops": [[0, "accent1"], [1, ["scheme": "accent1", "lumMod": 50000]]], "angle": 90]]
        case "pattern": ["pattern": ["preset": "pct25", "fg": "accent1", "bg": "bg1"]]
        case "auto": ["reset": true]
        default: nil
        }
    }

    /// `design.background` parameters that switch the slide's background to `kind` (`picture` asks for a file).
    public static func backgroundKindParams(_ kind: String) -> JSON? {
        switch kind {
        case "solid": return ["color": "bg1"]
        case "gradient":
            var g = defaultGradient(.scheme(.bg2), 90)
            g.rotateWithShape = false
            return ["gradient": gradientJSON(g)]
        case "pattern": return ["pattern": ["preset": "pct20", "fg": "accent1", "bg": "bg1"]]
        case "auto": return ["reset": true]
        default: return nil
        }
    }

    /// The background's fill (nil for one that follows the layout or references the theme).
    public static func backgroundFill(_ bg: Background?) -> Fill? {
        if case .fill(let f)? = bg { return f }
        return nil
    }

    /// Format Background's kind for the slide's background.
    public static func backgroundKind(_ bg: Background?) -> String {
        switch backgroundFill(bg) {
        case .solid?: "solid"
        case .gradient?: "gradient"
        case .picture?: "picture"
        case .pattern?: "pattern"
        default: "auto"
        }
    }

    /// What "Apply to All" re-applies: the current background as `design.background` parameters with
    /// `all`, or `{copy: true}` for a picture (its bytes are already in the presentation); nil when there is
    /// nothing to apply.
    public static func applyToAllParams(_ bg: Background?) -> JSON? {
        var p: JSON
        switch backgroundFill(bg) {
        case .solid(let color)?: p = ["color": InspectorColors.param(color)]
        case .gradient(let g)?: p = ["gradient": gradientJSON(g)]
        case .pattern(let pt)?: p = ["pattern": patternJSON(pt)]
        case .picture?: return ["copy": true]
        default: return nil
        }
        p.set("all", true)
        return p
    }

    // MARK: Transparency (panes.rs)

    /// `solid_fill_transparency_percent`: percent transparency (0 = opaque) of a solid fill, the number
    /// `shape.fill {transparency}` writes as an alpha transform; anything else is 0.
    public static func solidFillTransparencyPercent(_ fill: Fill?) -> Double {
        guard case .solid(let color)? = fill else { return 0 }
        return Double(Float((1.0 - color.alpha) * 100.0))
    }

    /// `fill_transparency_to_apply`: the fraction to pass to `shape.fill` when the slider moved; nil when it
    /// didn't (a focus loss, or another shape selected), so the pane doesn't rewrite the fill.
    public static func fillTransparencyToApply(_ shownPercent: Double, _ seedPercent: Double) -> Double? {
        guard shownPercent.isFinite else { return nil }
        let shown = Swift.min(Swift.max(Float(shownPercent), 0), 100)
        if abs(shown - Float(seedPercent)) <= 0.01 { return nil }
        return Double(shown) / 100.0
    }

    /// The Fill transparency slider's value for a shape: a picture fill's own transparency, else a solid's.
    public static func fillTransparencySeed(_ fill: Fill?) -> Double {
        if case .picture(let pf)? = fill { return Double(Float((1.0 - (pf.alpha ?? 1.0)) * 100.0)) }
        return solidFillTransparencyPercent(fill)
    }

    /// `shape.fill {transparency}` changes a solid fill (an automatic one through its effective colour) and
    /// a picture fill; a gradient has a transparency per stop.
    public static func showsTransparency(_ fill: Fill?) -> Bool {
        switch fill {
        case nil, .solid?, .picture?: true
        default: false
        }
    }

    /// The Color button sets a solid fill, so it shows only for a solid or automatic fill.
    public static func showsColor(_ fill: Fill?) -> Bool { ["solid", "auto"].contains(kind(fill)) }

    /// `text_transparency_of`: the transparency (0–1) of a shape's first text run as stored on it.
    public static func textTransparency(_ sh: Shape) -> Double {
        let run = sh.text?.paragraphs.lazy.flatMap(\.runs).first
        switch run?.props.fill {
        case .solid(let color)?: return 1.0 - color.alpha
        case .gradient(let g)?: return g.stops.first.map { 1.0 - $0.color.alpha } ?? 0
        default: return 0
        }
    }

    // MARK: Gradients (fillui.rs)

    /// `default_gradient`: two stops on `base`, the colour and a darker shade.
    public static func defaultGradient(_ base: ColorRef, _ angle: Double) -> Gradient {
        var dark = base
        dark.mods.append(.lumMod(60_000))
        return Gradient(stops: [GradientStop(pos: 0, color: base), GradientStop(pos: 1, color: dark)],
                        shape: .linear(angle: angle, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0])
    }

    /// `gradient_json`: the command parameter for `g` (`shape.fill {gradient}`, `design.background {gradient}`).
    public static func gradientJSON(_ g: Gradient) -> JSON {
        let stops: JSON = .array(g.stops.map { [.num($0.pos), InspectorColors.param($0.color)] })
        switch g.shape {
        case .linear(let angle, _):
            return ["stops": stops, "kind": "linear", "angle": .num(angle), "rotateWithShape": .bool(g.rotateWithShape)]
        case .path(let path, let focus):
            let kind = path == "rect" ? "rectangular" : path == "shape" ? "path" : "radial"
            return ["stops": stops, "kind": .string(kind), "focus": .array(focus.map { .num($0) }), "rotateWithShape": .bool(g.rotateWithShape)]
        }
    }

    public static func alphaOf(_ c: ColorRef) -> Double {
        for m in c.mods { if case .alpha(let a) = m { return Double(a) / 100_000.0 } }
        return 1
    }

    public static func withAlpha(_ c: ColorRef, _ a: Double) -> ColorRef {
        var c = c
        c.mods.removeAll { if case .alpha = $0 { return true } else { return false } }
        if a < 0.999 {
            let v = (Swift.min(Swift.max(a.isNaN ? 0 : a, 0), 1) * 100_000).rounded()
            c.mods.append(.alpha(Int32(v)))
        }
        return c
    }

    /// The six preset variations of the first stop's colour.
    public static func presets(_ g: Gradient) -> [Gradient] {
        let base = g.stops.first?.color ?? .scheme(.accent1)
        var light = base
        light.mods += [.lumMod(40_000), .lumOff(60_000)]
        var dark = base
        dark.mods.append(.lumMod(50_000))
        func with(_ stops: [GradientStop], _ angle: Double, _ b: ColorRef = base) -> Gradient {
            var v = defaultGradient(b, angle)
            v.stops = stops
            return v
        }
        return [
            defaultGradient(base, 90),
            with([GradientStop(pos: 0, color: light), GradientStop(pos: 1, color: base)], 90),
            with([GradientStop(pos: 0, color: base), GradientStop(pos: 1, color: dark)], 0),
            with([GradientStop(pos: 0, color: light), GradientStop(pos: 0.5, color: base), GradientStop(pos: 1, color: dark)], 45),
            Gradient(stops: [GradientStop(pos: 0, color: light), GradientStop(pos: 1, color: dark)],
                     shape: .path(path: "circle", focus: [0.5, 0.5, 0.5, 0.5]), rotateWithShape: true, tile: [0, 0, 0, 0]),
            with([GradientStop(pos: 0, color: base), GradientStop(pos: 1, color: withAlpha(base, 0))], 90, .scheme(.accent1)),
        ]
    }

    /// The gradient's type name.
    public static func typeName(_ g: Gradient) -> String {
        switch g.shape {
        case .linear: "Linear"
        case .path(let path, _) where path == "rect": "Rectangular"
        case .path(let path, _) where path == "shape": "Path"
        case .path: "Radial"
        }
    }

    public static let types = ["Linear", "Radial", "Rectangular", "Path"]

    /// `g` as another type; nil when it already is one.
    public static func withType(_ g: Gradient, _ type: String) -> Gradient? {
        guard typeName(g) != type else { return nil }
        let focus: [Double]
        if case .path(_, let f) = g.shape { focus = f } else { focus = [0.5, 0.5, 0.5, 0.5] }
        var n = g
        switch type {
        case "Linear": n.shape = .linear(angle: 90, scaled: false)
        case "Rectangular": n.shape = .path(path: "rect", focus: focus)
        case "Path": n.shape = .path(path: "shape", focus: focus)
        default: n.shape = .path(path: "circle", focus: focus)
        }
        return n
    }

    public static let linearDirections: [(label: String, angle: Double)] = [
        ("→", 0), ("↘", 45), ("↓", 90), ("↙", 135), ("←", 180), ("↖", 225), ("↑", 270), ("↗", 315),
    ]
    public static let pathDirections: [(label: String, focus: [Double])] = [
        ("From center", [0.5, 0.5, 0.5, 0.5]), ("From top left", [0, 0, 1, 1]), ("From top right", [1, 0, 0, 1]),
        ("From bottom left", [0, 1, 1, 0]), ("From bottom right", [1, 1, 0, 0]),
    ]

    /// A linear gradient at `angle` (degrees, wrapped into 0..<360).
    public static func withAngle(_ g: Gradient, _ angle: Double) -> Gradient {
        var n = g
        let r = angle.isFinite ? angle.truncatingRemainder(dividingBy: 360) : 0
        n.shape = .linear(angle: r < 0 ? r + 360 : r, scaled: false)
        return n
    }

    public static func withFocus(_ g: Gradient, _ focus: [Double]) -> Gradient {
        guard case .path(let path, _) = g.shape else { return g }
        var n = g
        n.shape = .path(path: path, focus: focus)
        return n
    }

    /// The most stops the bar takes.
    public static let maxStops = 10

    /// A click on the stop bar at `pos` (0–1): a new stop, coloured like the nearest one. Returns the
    /// gradient and the new stop's index; nil when the bar is full.
    public static func addStop(_ g: Gradient, at pos: Double) -> (Gradient, Int)? {
        guard g.stops.count < maxStops, pos.isFinite else { return nil }
        let p = (Swift.min(Swift.max(pos, 0), 1) * 1000).rounded() / 1000
        let near = g.stops.min { abs($0.pos - p) < abs($1.pos - p) }?.color
        var n = g
        n.stops.append(GradientStop(pos: p, color: near ?? .scheme(.accent1)))
        sortStops(&n.stops)
        return (n, n.stops.firstIndex { $0.pos == p } ?? 0)
    }

    /// A stop dragged to `pos`, rounded to a thousandth (the stops stay in the order they were in).
    public static func moveStop(_ g: Gradient, _ i: Int, to pos: Double) -> Gradient {
        var n = g
        guard n.stops.indices.contains(i), pos.isFinite else { return n }
        n.stops[i].pos = (Swift.min(Swift.max(pos, 0), 1) * 1000).rounded() / 1000
        return n
    }

    /// Position field: percent, clamped, then the stops sorted.
    public static func setStopPosition(_ g: Gradient, _ i: Int, percent: Double) -> Gradient {
        var n = g
        guard n.stops.indices.contains(i), percent.isFinite else { return n }
        n.stops[i].pos = Swift.min(Swift.max(percent / 100, 0), 1)
        sortStops(&n.stops)
        return n
    }

    /// Remove a stop (two always stay); returns the gradient and the stop selected after.
    public static func removeStop(_ g: Gradient, _ i: Int) -> (Gradient, Int)? {
        guard g.stops.count > 2, g.stops.indices.contains(i) else { return nil }
        var n = g
        n.stops.remove(at: i)
        return (n, Swift.max(i - 1, 0))
    }

    /// A stop recoloured, keeping its transparency.
    public static func setStopColor(_ g: Gradient, _ i: Int, _ c: ColorRef) -> Gradient {
        var n = g
        guard n.stops.indices.contains(i) else { return n }
        n.stops[i].color = withAlpha(c, alphaOf(n.stops[i].color))
        return n
    }

    /// A stop's transparency (percent).
    public static func setStopTransparency(_ g: Gradient, _ i: Int, percent: Double) -> Gradient {
        var n = g
        guard n.stops.indices.contains(i), percent.isFinite else { return n }
        n.stops[i].color = withAlpha(n.stops[i].color, 1.0 - percent / 100.0)
        return n
    }

    /// Rust's `sort_by(total_cmp)` on positions: stable, −0 before +0.
    static func sortStops(_ s: inout [GradientStop]) {
        s = s.enumerated().sorted { a, b in
            let x = a.element.pos, y = b.element.pos
            let below = x.isTotallyOrdered(belowOrEqualTo: y), above = y.isTotallyOrdered(belowOrEqualTo: x)
            if below && above { return a.offset < b.offset }
            return below
        }.map(\.element)
    }

    // MARK: Patterns (fillui.rs)

    static let patternLabels: [(String, String)] = [
        ("pct5", "5%"), ("pct10", "10%"), ("pct20", "20%"), ("pct25", "25%"), ("pct30", "30%"), ("pct40", "40%"),
        ("pct50", "50%"), ("pct60", "60%"), ("pct70", "70%"), ("pct75", "75%"), ("pct80", "80%"), ("pct90", "90%"),
        ("horz", "Horizontal"), ("vert", "Vertical"), ("ltHorz", "Light horizontal"), ("ltVert", "Light vertical"),
        ("dkHorz", "Dark horizontal"), ("dkVert", "Dark vertical"), ("narHorz", "Narrow horizontal"), ("narVert", "Narrow vertical"),
        ("dashHorz", "Dashed horizontal"), ("dashVert", "Dashed vertical"), ("cross", "Cross"), ("dnDiag", "Downward diagonal"),
        ("upDiag", "Upward diagonal"), ("ltDnDiag", "Light downward diagonal"), ("ltUpDiag", "Light upward diagonal"),
        ("dkDnDiag", "Dark downward diagonal"), ("dkUpDiag", "Dark upward diagonal"), ("wdDnDiag", "Wide downward diagonal"),
        ("wdUpDiag", "Wide upward diagonal"), ("dashDnDiag", "Dashed downward diagonal"), ("dashUpDiag", "Dashed upward diagonal"),
        ("diagCross", "Diagonal cross"), ("smCheck", "Small checkerboard"), ("lgCheck", "Large checkerboard"), ("smGrid", "Small grid"),
        ("lgGrid", "Large grid"), ("dotGrid", "Dotted grid"), ("smConfetti", "Small confetti"), ("lgConfetti", "Large confetti"),
        ("horzBrick", "Horizontal brick"), ("diagBrick", "Diagonal brick"), ("solidDmnd", "Solid diamond"), ("openDmnd", "Outlined diamond"),
        ("dotDmnd", "Dotted diamond"), ("plaid", "Plaid"), ("sphere", "Sphere"), ("weave", "Weave"), ("divot", "Divot"),
        ("shingle", "Shingle"), ("wave", "Wave"), ("trellis", "Trellis"), ("zigZag", "Zig zag"),
    ]

    /// `pattern_gallery`: the 48 presets the gallery offers, in its 6 rows of 8. `horz`, `vert`, `cross`,
    /// `dnDiag`, `upDiag` and `diagCross` are left out, as in PowerPoint's gallery; a fill using one still draws.
    public static let patternGallery: [String] = [
        "pct5", "pct10", "pct20", "pct25", "pct30", "pct40", "pct50", "pct60",
        "pct70", "pct75", "pct80", "pct90", "ltDnDiag", "ltUpDiag", "dkDnDiag", "dkUpDiag",
        "wdDnDiag", "wdUpDiag", "ltVert", "ltHorz", "narVert", "narHorz", "dkVert", "dkHorz",
        "dashDnDiag", "dashUpDiag", "dashHorz", "dashVert", "smConfetti", "lgConfetti", "zigZag", "wave",
        "diagBrick", "horzBrick", "weave", "plaid", "divot", "dotGrid", "dotDmnd", "shingle",
        "trellis", "sphere", "smGrid", "lgGrid", "smCheck", "lgCheck", "openDmnd", "solidDmnd",
    ]

    /// `pattern_label`: the name the gallery shows (the preset itself when it has none).
    public static func patternLabel(_ name: String) -> String {
        patternLabels.first { $0.0 == name }?.1 ?? name
    }

    /// `pattern_json`.
    public static func patternJSON(_ pt: PatternFill) -> JSON {
        ["preset": .string(pt.preset), "fg": InspectorColors.param(pt.fg), "bg": InspectorColors.param(pt.bg)]
    }

    /// The pattern with another preset, keeping both colours; nil when it is the same one.
    public static func withPreset(_ pt: PatternFill, _ name: String) -> PatternFill? {
        guard pt.preset != name else { return nil }
        var n = pt
        n.preset = name
        return n
    }

    // MARK: Picture fills

    public static let tileAlignments: [(key: String, label: String)] = [
        ("tl", "Top Left"), ("t", "Top"), ("tr", "Top Right"), ("l", "Left"), ("ctr", "Center"),
        ("r", "Right"), ("bl", "Bottom Left"), ("b", "Bottom"), ("br", "Bottom Right"),
    ]
    public static let mirrors: [(key: String, label: String)] = [("none", "None"), ("x", "Horizontal"), ("y", "Vertical"), ("xy", "Both")]

    // MARK: Lines (panes.rs `line_details`)

    public static let compounds: [(String, String)] = [("Single", "single"), ("Double", "double"), ("Thick Thin", "thickThin"), ("Thin Thick", "thinThick"), ("Triple", "triple")]
    public static let caps: [(String, String)] = [("Flat", "flat"), ("Round", "round"), ("Square", "square")]
    public static let joins: [(String, String)] = [("Round", "round"), ("Bevel", "bevel"), ("Miter", "miter")]
    public static let arrows: [(String, String)] = [("None", "none"), ("Arrow", "triangle"), ("Open Arrow", "arrow"), ("Stealth", "stealth"), ("Diamond", "diamond"), ("Oval", "oval")]
    public static let arrowSizes: [(String, String)] = [("Small", "sm"), ("Medium", "med"), ("Large", "lg")]
    /// The outline menu's dashes (ribbon `outline_menu`).
    public static let dashes: [(String, String)] = [
        ("Solid", "solid"), ("Round Dot", "sysDot"), ("Square Dot", "sysDash"), ("Dash", "dash"),
        ("Dash Dot", "dashDot"), ("Long Dash", "lgDash"), ("Long Dash Dot", "lgDashDot"),
    ]
    public static let weights: [Double] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.25, 3.0, 4.5, 6.0]
    /// The outline menu's arrow combinations: label, head, tail.
    public static let arrowCombos: [(String, String, String)] = [
        ("None", "none", "none"), ("Arrow at end", "none", "triangle"), ("Arrow at start", "triangle", "none"),
        ("Arrows at both ends", "triangle", "triangle"), ("Stealth end", "none", "stealth"), ("Oval ends", "oval", "oval"),
    ]

    /// The line's stored choices as `shape.line` names.
    public static func lineChoices(_ l: Line?) -> (compound: String, cap: String, join: String, head: String, tail: String, headSize: String?, tailSize: String?) {
        let l = l ?? Line()
        return ((l.compound ?? .single).rawValue, (l.cap ?? .flat).rawValue, (l.join ?? .round).rawValue,
                l.head?.kind ?? "none", l.tail?.kind ?? "none", l.head?.w, l.tail?.w)
    }

    /// The Line radio: `none`, `solid` or `auto`.
    public static func lineKind(_ l: Line?) -> String {
        guard let l else { return "auto" }
        if case .none_? = l.fill { return "none" }
        return "solid"
    }

    // MARK: 3-D (panes.rs)

    /// `preset_label`: "perspectiveHeroicLeftFacing" → "Perspective heroic left facing".
    public static func presetLabel(_ name: String) -> String {
        var out = ""
        for (i, c) in name.enumerated() {
            if i == 0 {
                out += c.uppercased()
            } else if c.isUppercase {
                out += " " + c.lowercased()
            } else {
                out.append(c)
            }
        }
        return out
    }
}
