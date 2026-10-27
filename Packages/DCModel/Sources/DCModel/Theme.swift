// DCModel — themes: colour, font and format schemes, and the built-in themes. Port of deckcraft
// crates/model/src/theme.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The
// built-in themes' colours and names are deckcraft's own.
import DCColor
import DCCore

extension Theme {
    public static var `default`: Theme {
        builtinThemes().first ?? Theme(
            name: "DeckCraft",
            colors: ColorScheme(name: "DeckCraft", colors: Array(repeating: .black, count: 12)),
            fonts: .default, format: .default, rawExtra: nil
        )
    }

    /// Resolve a theme font reference (`+mj-lt`, `+mn-ea`…) to a family name.
    public func font(_ name: String) -> String {
        switch name {
        case "+mj-lt": fonts.major.latin
        case "+mn-lt": fonts.minor.latin
        case "+mj-ea": fonts.major.ea
        case "+mn-ea": fonts.minor.ea
        case "+mj-cs": fonts.major.cs
        case "+mn-cs": fonts.minor.cs
        default: name
        }
    }
}

private func hex(_ s: String) -> Rgba { Rgba.fromHex(s) ?? .black }

private func scheme(_ name: String, _ c: [String]) -> ColorScheme {
    ColorScheme(name: name, colors: c.map(hex))
}

private func ph() -> ColorRef { .scheme(.phClr) }

/// deckcraft's default format scheme: flat solid fills, a soft gradient, and a gentle shadow for
/// "intense".
public func defaultFormat() -> FormatScheme {
    func grad(_ a: Int32, _ b: Int32) -> Fill {
        .gradient(Gradient(
            stops: [
                GradientStop(pos: 0.0, color: ph().with(.lumMod(a)).with(.satMod(103000))),
                GradientStop(pos: 1.0, color: ph().with(.lumMod(b))),
            ],
            shape: .linear(angle: 90.0, scaled: false),
            rotateWithShape: true,
            tile: [0, 0, 0, 0]
        ))
    }
    var intense = Effects()
    intense.outerShadow = Shadow(
        color: .rgb(.black).with(.alpha(40000)), blur: 6.0, dist: 3.0, dir: 90.0, inner: false,
        sx: 1.0, sy: 1.0, kx: 0.0, ky: 0.0, align: "t", rotateWithShape: false
    )
    return FormatScheme(
        name: "DeckCraft",
        fills: [.solid(ph()), grad(110000, 92000), grad(105000, 80000)],
        lines: [.solid(ph(), 0.75), .solid(ph(), 1.0), .solid(ph(), 1.5)],
        effects: [Effects(), Effects(), intense],
        bgFills: [.solid(ph()), .solid(ph().with(.tint(95000)).with(.satMod(170000))), grad(102000, 85000)]
    )
}

/// Design ▸ Variants: four colour variations of `t`, built from its built-in colours when it is a
/// built-in theme (so picking one variant after another doesn't drift), else from its own. 1: as
/// designed; 2 and 3: the accents rotated; 4: dark (light and dark colours swapped).
public func themeVariants(_ t: Theme) -> [ColorScheme] {
    let base = builtinThemes().first { $0.name == t.name }?.colors ?? t.colors
    func rotate(_ by: Int) -> ColorScheme {
        var c = base
        let accents = base.colors.count >= 10 ? Array(base.colors[4 ..< 10]) : []
        for i in 0 ..< 6 where c.colors.indices.contains(4 + i) {
            if let a = accents.at((i + by) % Swift.max(accents.count, 1)) {
                c.colors[4 + i] = a
            }
        }
        return c
    }
    var dark = base
    if dark.colors.count >= 4 {
        dark.colors.swapAt(0, 1)
        dark.colors.swapAt(2, 3)
    }
    var out = [base, rotate(1), rotate(3), dark]
    for i in 1 ..< out.count {
        out[i].name = "\(base.name) \(i + 1)"
    }
    return out
}

/// deckcraft's original built-in themes (shown in Design ▸ Themes). Colours and names are its own.
public func builtinThemes() -> [Theme] {
    func t(_ name: String, _ colors: ColorScheme, _ major: String, _ minor: String) -> Theme {
        Theme(
            name: name, colors: colors,
            fonts: FontScheme(name: name, major: FontSet(latin: major), minor: FontSet(latin: minor)),
            format: defaultFormat(), rawExtra: nil
        )
    }
    return [
        t("DeckCraft", scheme("DeckCraft", ["000000", "FFFFFF", "1E2B3C", "EDEBE7", "2E6FD8", "F26B1D", "2EA36F", "8A5CD8", "D83F6B", "E3B21C", "2E6FD8", "7A5BA6"]), "Inter", "Inter"),
        t("Harbor", scheme("Harbor", ["0B1F2A", "FFFFFF", "12384D", "E4EEF2", "1B7FA6", "36B3A8", "F2C14E", "F78154", "5D576B", "8AA29E", "1B7FA6", "5D576B"]), "Merriweather", "Open Sans"),
        t("Ember", scheme("Ember", ["1A1A1A", "FFFCF7", "3D2B1F", "F6EDE3", "D9480F", "F59F00", "A61E4D", "5C940D", "1971C2", "862E9C", "D9480F", "862E9C"]), "Montserrat", "Lato"),
        t("Meadow", scheme("Meadow", ["14281D", "FFFFFF", "2D4A37", "EEF5EE", "4C9A2A", "A4C639", "2F6F4E", "E9B44C", "9B2915", "50A2A7", "2F6F4E", "9B2915"]), "Merriweather", "Open Sans"),
        t("Nocturne", scheme("Nocturne", ["FFFFFF", "121826", "F2F4F8", "1E2638", "7C5CFF", "00C2A8", "FF6B9A", "FFC53D", "4DA3FF", "B2F35F", "7C5CFF", "FF6B9A"]), "Inter", "Inter"),
        t("Paper", scheme("Paper", ["262626", "FFFFFF", "404040", "F2F2F2", "595959", "8C8C8C", "C0504D", "4F81BD", "9BBB59", "F79646", "4F81BD", "8064A2"]), "Playfair Display", "Lato"),
        t("Coral Reef", scheme("Coral Reef", ["0F2A33", "FFFFFF", "0E4D64", "FDF1EC", "FF6F59", "254441", "43AA8B", "B2B09B", "EF3054", "3F88C5", "3F88C5", "EF3054"]), "Poppins", "Nunito Sans"),
        t("Slate", scheme("Slate", ["111827", "FFFFFF", "374151", "F3F4F6", "6366F1", "0EA5E9", "10B981", "F59E0B", "EF4444", "8B5CF6", "6366F1", "8B5CF6"]), "Roboto", "Roboto"),
    ]
}

/// Named colour schemes for Design ▸ Variants ▸ Colors.
public func builtinColorSchemes() -> [ColorScheme] {
    var v = builtinThemes().map(\.colors)
    v.append(scheme("Grayscale", ["000000", "FFFFFF", "000000", "F8F8F8", "DDDDDD", "B2B2B2", "969696", "808080", "5F5F5F", "4D4D4D", "5F5F5F", "919191"]))
    v.append(scheme("Ocean", ["000000", "FFFFFF", "13293D", "E8F1F2", "006494", "247BA0", "1B98E0", "6CC1E8", "13293D", "0B3954", "1B98E0", "6CC1E8"]))
    v.append(scheme("Sunset", ["2B2118", "FFFFFF", "6F1A07", "FFF3E6", "FF9F1C", "FFBF69", "CB997E", "E76F51", "F4A261", "2A9D8F", "E76F51", "2A9D8F"]))
    v.append(scheme("Forest", ["1B1B1B", "FFFFFF", "283618", "FEFAE0", "606C38", "DDA15E", "BC6C25", "283618", "8A9A5B", "4F772D", "606C38", "BC6C25"]))
    v.append(scheme("Berry", ["1F0A1D", "FFFFFF", "4A1942", "F7E8F3", "893168", "C6426E", "EB6A8F", "4A1942", "7D7ABC", "56A3A6", "893168", "56A3A6"]))
    return v
}

/// Named font pairs for Design ▸ Variants ▸ Fonts.
public func builtinFontSchemes() -> [FontScheme] {
    func f(_ name: String, _ major: String, _ minor: String) -> FontScheme {
        FontScheme(name: name, major: FontSet(latin: major), minor: FontSet(latin: minor))
    }
    return [
        f("Inter", "Inter", "Inter"),
        f("Classic", "Merriweather", "Open Sans"),
        f("Geometric", "Montserrat", "Lato"),
        f("Editorial", "Playfair Display", "Lato"),
        f("Humanist", "Merriweather", "Open Sans"),
        f("Friendly", "Poppins", "Nunito Sans"),
        f("Neutral", "Roboto", "Roboto"),
        f("Office Compatible", "Carlito", "Carlito"),
        f("Times / Arial", "Liberation Serif", "Liberation Sans"),
    ]
}

private func shadowEffect(_ blur: Double, _ dist: Double, _ alpha: Int32) -> Effects {
    var e = Effects()
    e.outerShadow = Shadow(
        color: .rgb(.black).with(.alpha(alpha)), blur: blur, dist: dist, dir: 90.0, inner: false,
        sx: 1.0, sy: 1.0, kx: 0.0, ky: 0.0, align: "b", rotateWithShape: false
    )
    return e
}

private func glowEffect(_ radius: Double) -> Effects {
    var e = Effects()
    e.glow = Glow(color: ph().with(.alpha(60_000)), radius: radius)
    return e
}

/// Named effect schemes for Design ▸ Effects. Each one replaces the theme's format scheme (subtle,
/// moderate and intense fills, lines and effects) and leaves the colour and font schemes.
public func builtinFormatSchemes() -> [FormatScheme] {
    var soft = defaultFormat()
    soft.name = "Soft"
    soft.lines = [.solid(ph(), 0.5), .solid(ph(), 0.75), .solid(ph(), 1.0)]
    soft.effects = [shadowEffect(16.0, 1.0, 18_000), shadowEffect(12.0, 2.0, 22_000), shadowEffect(10.0, 3.0, 28_000)]

    var crisp = defaultFormat()
    crisp.name = "Crisp"
    crisp.fills = [.solid(ph()), .solid(ph()), .solid(ph())]
    crisp.lines = [.solid(ph(), 1.0), .solid(ph(), 1.5), .solid(ph(), 2.25)]
    crisp.effects = [Effects(), Effects(), shadowEffect(0.0, 2.0, 55_000)]

    var lift = defaultFormat()
    lift.name = "Lift"
    lift.effects = [Effects(), shadowEffect(8.0, 6.0, 28_000), shadowEffect(12.0, 10.0, 35_000)]

    var glowScheme = defaultFormat()
    glowScheme.name = "Glow"
    glowScheme.effects = [Effects(), glowEffect(6.0), glowEffect(12.0)]

    var plain = defaultFormat()
    plain.name = "Plain"
    plain.fills = [.solid(ph()), .solid(ph()), .solid(ph())]
    plain.lines = [.solid(ph(), 0.75), .solid(ph(), 0.75), .solid(ph(), 0.75)]
    plain.effects = [Effects(), Effects(), Effects()]

    return [defaultFormat(), soft, crisp, lift, glowScheme, plain]
}
