// DCApp — Format ▸ Effects: preset tiles that draw what each Shadow, Glow and Soft Edges preset does to a small
// card, so the choice is made by looking rather than by reading names. Port of deckcraft's `effect_presets.rs`
// (`shadow_row`, `glow_row`, `soft_edge_row`; 9ad147b3, MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). egui fakes blur with stacked translucent rectangles; here the card is drawn with SwiftUI's own
// blur and shadow filters.
import AppKit
import DesignScaffold
import SwiftUI

/// One effect preset as a tile draws it.
enum EffectPreset: Hashable {
    case shadow(String)
    case glow(Double)
    case softEdge(Double)
}

/// A wrapping row of preset tiles; the tile of `current` is marked, and a click picks one.
struct EffectPresetTiles: View {
    let label: String
    let presets: [(preset: EffectPreset, label: String)]
    let current: EffectPreset?
    let pick: (EffectPreset) -> Void

    static let tile = CGSize(width: 46, height: 38)
    /// The tiles are drawn on a slide's light paper, a little dimmer in Dark Mode: a shadow can't be seen on a dark
    /// field, and it is the slide it will fall on.
    static let paper = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.84, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    })

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile.width, maximum: Self.tile.width), spacing: Tokens.Space.xs)],
                  alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(presets, id: \.preset) { p in
                let selected = p.preset == current
                Button { pick(p.preset) } label: {
                    Canvas { ctx, size in Self.draw(p.preset, in: &ctx, size: size) }
                        .frame(width: Self.tile.width, height: Self.tile.height)
                        .background(Self.paper, in: RoundedRectangle(cornerRadius: Tokens.Radius.control - 1))
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control - 1))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control - 1)
                                .strokeBorder(selected ? Tokens.Color.accent : Tokens.Color.separator, lineWidth: selected ? 2 : 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.label)
                .accessibilityLabel(p.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The sample card every preview draws on, centred in the tile.
    static func card(_ size: CGSize) -> CGRect {
        CGRect(x: (size.width - 22) / 2, y: (size.height - 16) / 2, width: 22, height: 16)
    }

    static func draw(_ preset: EffectPreset, in ctx: inout GraphicsContext, size: CGSize) {
        let r = card(size)
        let shape = Path(roundedRect: r, cornerRadius: 2)
        let accent = Tokens.Color.accent
        let ink = Color.black.opacity(0.55)
        switch preset {
        case .shadow(let id):
            var shadowed = ctx
            switch id {
            case "outer": shadowed.addFilter(.shadow(color: ink, radius: 2, x: 3, y: 3))
            case "bottom": shadowed.addFilter(.shadow(color: ink, radius: 2, x: 0, y: 4))
            case "center": shadowed.addFilter(.shadow(color: ink, radius: 3.5))
            case "perspective":
                // The shadow laid on the ground behind the card, slanting back from its base.
                var ground = ctx
                ground.addFilter(.blur(radius: 1.5))
                var slant = Path()
                slant.move(to: CGPoint(x: r.minX - 6, y: r.maxY + 1))
                slant.addLine(to: CGPoint(x: r.maxX - 8, y: r.maxY + 1))
                slant.addLine(to: CGPoint(x: r.maxX - 2, y: r.maxY + 6))
                slant.addLine(to: CGPoint(x: r.minX - 12, y: r.maxY + 6))
                slant.closeSubpath()
                ground.fill(slant, with: .color(.black.opacity(0.4)))
            default: break
            }
            if id == "inner" {
                shadowed.fill(shape, with: .style(accent.shadow(.inner(color: ink, radius: 2, x: 2, y: 2))))
            } else {
                shadowed.fill(shape, with: .color(accent))
            }
            if id == "none" { slash(&ctx, size) }
        case .glow(let radius):
            if radius > 0 {
                // 18 pt fills the tile's margin; smaller radii scale down.
                var glow = ctx
                glow.addFilter(.blur(radius: max(1.5, radius / 18 * 5)))
                let spread = max(1, radius / 18 * 5)
                glow.fill(Path(roundedRect: r.insetBy(dx: -spread, dy: -spread), cornerRadius: 2 + spread), with: .color(accent.opacity(0.75)))
            }
            ctx.fill(shape, with: .color(accent))
            if radius == 0 { slash(&ctx, size) }
        case .softEdge(let radius):
            let big = r.insetBy(dx: -2, dy: -2)
            var soft = ctx
            soft.clip(to: Path(big))
            if radius > 0 {
                // The rim fades inward: a blurred card a little smaller than its box, clipped to the box. The fade
                // grows with the square root of the size, so 1 pt and 2.5 pt still look apart from none.
                let depth = 1.4 * radius.squareRoot()
                soft.addFilter(.blur(radius: depth / 1.6))
                soft.fill(Path(roundedRect: big.insetBy(dx: depth / 2, dy: depth / 2), cornerRadius: 2), with: .color(accent))
            } else {
                soft.fill(Path(roundedRect: big, cornerRadius: 2), with: .color(accent))
                slash(&ctx, size)
            }
        }
    }

    /// The faint diagonal stroke across a "none" tile.
    private static func slash(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var p = Path()
        p.move(to: CGPoint(x: 6, y: size.height - 6))
        p.addLine(to: CGPoint(x: size.width - 6, y: 6))
        ctx.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 1.5)
    }
}
