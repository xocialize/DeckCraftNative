// DCModel — colours, fills, lines and effects. Port of deckcraft crates/model/src/style.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore

extension ColorRef {
    public static func rgb(_ c: Rgba) -> ColorRef { ColorRef(base: .rgb(rgb: c), mods: []) }
    public static func scheme(_ slot: SchemeSlot) -> ColorRef { ColorRef(base: .scheme(slot: slot), mods: []) }

    public func with(_ m: ColorTransform) -> ColorRef {
        var c = self
        c.mods.append(m)
        return c
    }

    /// Resolve against a colour scheme; `ph` substitutes `phClr` (style matrix colour).
    public func resolve(_ scheme: ColorScheme, _ ph: Rgba?) -> Rgba {
        let base: Rgba
        switch self.base {
        case .rgb(let rgb): base = rgb
        case .scheme(.phClr): base = ph ?? scheme.get(.accent1)
        case .scheme(let slot): base = scheme.get(slot)
        case .preset(let name): base = presetColor(name) ?? .black
        case .system(_, let last): base = last
        }
        return applyTransforms(base, mods)
    }

    /// Alpha (0–1) from an `alpha` transform, if any.
    public var alpha: Double {
        mods.reduce(1.0) { a, m in
            if case .alpha(let v) = m { return (Double(v) / 100_000.0).clamped(0.0, 1.0) }
            return a
        }
    }
}

extension PictureMode {
    public static var `default`: PictureMode { .stretch(fillRect: [0, 0, 0, 0]) }
}

extension Fill {
    public static func solid(_ c: ColorRef) -> Fill { .solid(color: c) }

    public var isNone: Bool {
        if case .none_ = self { return true }
        return false
    }
}

extension Compound {
    public var xml: String {
        switch self {
        case .single: "sng"
        case .double: "dbl"
        case .thickThin: "thickThin"
        case .thinThick: "thinThick"
        case .triple: "tri"
        }
    }

    public static func fromXML(_ s: String) -> Compound {
        switch s {
        case "dbl": .double
        case "thickThin": .thickThin
        case "thinThick": .thinThick
        case "tri": .triple
        default: .single
        }
    }
}

extension Dash {
    public static let presets = [
        "solid", "sysDot", "sysDash", "dash", "dashDot", "lgDash", "lgDashDot", "lgDashDotDot", "dot", "sysDashDot",
        "sysDashDotDot",
    ]

    /// Dash/space lengths in multiples of the line width.
    public var pattern: [Double] {
        switch self {
        case .custom(let pattern):
            return pattern.flatMap { [$0.a, $0.b] }
        case .preset(let name):
            switch name {
            case "dot": return [1, 3]
            case "dash": return [4, 3]
            case "lgDash": return [8, 3]
            case "dashDot": return [4, 3, 1, 3]
            case "lgDashDot": return [8, 3, 1, 3]
            case "lgDashDotDot": return [8, 3, 1, 3, 1, 3]
            case "sysDash": return [3, 1]
            case "sysDot": return [1, 1]
            case "sysDashDot": return [3, 1, 1, 1]
            case "sysDashDotDot": return [3, 1, 1, 1, 1, 1]
            default: return []
            }
        }
    }
}

extension Line {
    public static func solid(_ c: ColorRef, _ width: Double) -> Line {
        var l = Line()
        l.fill = .solid(c)
        l.width = width
        return l
    }

    public static func none() -> Line {
        var l = Line()
        l.fill = .none_
        return l
    }

    /// Fill unset fields from `parent`.
    public mutating func inherit(_ parent: Line) {
        if fill == nil { fill = parent.fill }
        width = width ?? parent.width
        if dash == nil { dash = parent.dash }
        cap = cap ?? parent.cap
        join = join ?? parent.join
        compound = compound ?? parent.compound
        if head == nil { head = parent.head }
        if tail == nil { tail = parent.tail }
    }
}

extension Effects {
    public var isEmpty: Bool {
        outerShadow == nil && innerShadow == nil && glow == nil && softEdge == nil && reflection == nil
            && bevel == nil && fillOverlay == nil
    }
}

extension ShapeStyle {
    /// The default for newly drawn shapes: accent 1 fill, darker accent 1 outline, light text.
    public static func accent(_ slot: SchemeSlot) -> ShapeStyle {
        ShapeStyle(
            lineRef: Pair(2, .scheme(slot).with(.shade(50000))),
            fillRef: Pair(1, .scheme(slot)),
            effectRef: Pair(0, .scheme(slot)),
            fontRef: Pair("minor", .scheme(.lt1))
        )
    }

    /// The default for lines/connectors.
    public static func line(_ slot: SchemeSlot) -> ShapeStyle {
        ShapeStyle(
            lineRef: Pair(1, .scheme(slot)),
            fillRef: Pair(0, .scheme(slot)),
            effectRef: Pair(0, .scheme(slot)),
            fontRef: Pair("minor", .scheme(.tx1))
        )
    }
}
