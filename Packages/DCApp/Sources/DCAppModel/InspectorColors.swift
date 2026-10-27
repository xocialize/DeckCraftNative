// DCAppModel — the inspector's colour vocabulary: colours as command parameters (`cref_param` in deckcraft
// `crates/ui-egui/src/ribbon.rs`), the colour grid's theme colours, tints and shades and standard colours
// (`color_grid` in `widgets.rs`), and the scheme a pane draws them in. MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors.
import DCColor
import DCCore
import DCEngine
import DCModel

/// One swatch of the colour grid: what it draws, the colour it picks, and its tooltip.
public struct ColorSwatch: Sendable, Equatable {
    public var rgba: Rgba
    public var ref: ColorRef
    public var label: String
}

public enum InspectorColors {
    /// `cref_param`: a `ColorRef` as a command's colour parameter. A plain RGB colour is `"#RRGGBB"`; a
    /// scheme, preset or system colour (or an RGB one with transforms) is an object carrying its
    /// transforms by their XML names, which `Cmd.colorValue` reads back.
    public static func param(_ c: ColorRef) -> JSON {
        var o = JSONObject()
        switch c.base {
        case .scheme(let slot):
            o.set("scheme", .string(slot.xmlName))
        case .rgb(let rgb) where c.mods.isEmpty:
            return .string("#\(rgb.hex)")
        case .rgb(let rgb):
            o.set("rgb", .string("#\(rgb.hex)"))
        case .preset(let name):
            o.set("preset", .string(name))
        case .system(let name, let last):
            o.set("system", .string(name))
            o.set("last", .string("#\(last.hex)"))
        }
        for m in c.mods {
            if let v = m.value { o.set(m.xmlName, .integer(v)) }
        }
        return .object(o)
    }

    /// The colour scheme panes draw in: the first master's (with its colour map), else the default theme's.
    public static func scheme(_ session: Session) -> ColorScheme {
        session.activeDoc?.doc.masters.first?.scheme ?? Theme.default.colors
    }

    /// The grid's theme columns, in PowerPoint's order.
    public static let themeSlots: [SchemeSlot] = [.lt1, .dk1, .lt2, .dk2, .accent1, .accent2, .accent3, .accent4, .accent5, .accent6]

    /// A picked theme colour is stored by its mapped alias (`bg1`, `tx1`…), as PowerPoint stores it.
    public static func alias(_ slot: SchemeSlot) -> SchemeSlot {
        switch slot {
        case .lt1: .bg1
        case .dk1: .tx1
        case .lt2: .bg2
        case .dk2: .tx2
        default: slot
        }
    }

    /// The theme grid: the ten theme colours, then five rows of their tints and shades.
    public static func themeGrid(_ scheme: ColorScheme) -> [[ColorSwatch]] {
        var rows: [[ColorSwatch]] = [themeSlots.map { ColorSwatch(rgba: scheme.get($0), ref: .scheme(alias($0)), label: $0.label) }]
        for row in 0 ..< 5 {
            var line: [ColorSwatch] = []
            for slot in themeSlots {
                let base = scheme.get(slot)
                guard let v = themeVariants(base).at(row) else { continue }
                var r = ColorRef.scheme(alias(slot))
                r.mods = v.transforms
                line.append(ColorSwatch(rgba: applyTransforms(base, v.transforms), ref: r, label: v.label))
            }
            rows.append(line)
        }
        return rows
    }

    /// The standard colours row.
    public static var standard: [ColorSwatch] {
        standardColors.map { ColorSwatch(rgba: $0.color, ref: .rgb($0.color), label: $0.name) }
    }

    /// "More Colors… #": a typed hex colour, nil when it isn't one.
    public static func hex(_ text: String) -> ColorRef? {
        Rgba.fromHex(text).map(ColorRef.rgb)
    }

    /// `ColorRef.resolve` against `scheme`.
    public static func resolve(_ c: ColorRef, _ scheme: ColorScheme) -> Rgba { c.resolve(scheme, nil) }
}
