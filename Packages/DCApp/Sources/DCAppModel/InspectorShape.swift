// DCAppModel — Shape Format's Edit Shape choices without a window: Smooth Corners' radius
// (`smooth_corners_row`), the Quick Styles grid (`quick_styles`), the action buttons (Insert ▸ Action) and
// Insert ▸ Zoom's parameters (`zoom_menu`), from deckcraft `crates/ui-egui/src/ribbon.rs`; Format Shape's effect
// presets (`panels/effect_presets.rs`) and Size's Scale and From (`panels/format_shape.rs`) (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import CNCore
import DCEngine
import DCGeometry
import DCModel

public enum InspectorShape {
    /// Edit Shape ▸ Smooth Corners: the corner radius (points) a rectangle or rounded rectangle has; nil for
    /// another shape (the slider is then off).
    public static func cornerRadius(_ sh: Shape) -> Double? {
        guard let x = sh.xfrm else { return nil }
        let side = Swift.max(Swift.min(x.w, x.h), 0)
        switch sh.geom {
        case .preset(let name, let adj) where name == "roundRect":
            let a = adj.first ?? 16667
            return side * Swift.min(Swift.max(a.isNaN ? 16667 : a, 0), 50000) / 100_000
        case .preset(let name, _) where name == "rect":
            return side * 16667 / 100_000
        default:
            return nil
        }
    }

    /// `shape.smoothCorners` for `percent`, with the radius taken from the shape when the slider started.
    public static func smoothParams(_ percent: Double, radius: Double) -> JSON {
        ["smoothing": .num(Swift.min(Swift.max(percent.isFinite ? percent.rounded() : 0, 0), 100)), "radius": .num(radius)]
    }

    /// Quick Styles' columns: Dark 1 and the six accents.
    public static let quickStyleSlots: [SchemeSlot] = [.dk1, .accent1, .accent2, .accent3, .accent4, .accent5, .accent6]
    /// Quick Styles' rows (theme style intensity).
    public static let quickStyleRows = 6

    /// `shape.quickStyle`'s index for a grid cell.
    public static func quickStyleIndex(row: Int, column: Int) -> Int { row * quickStyleSlots.count + column }

    /// Insert ▸ Action ▸ Action Button kinds.
    public static let actionButtons = ["back", "forward", "beginning", "end", "home", "information", "return", "movie", "document", "sound", "help", "custom"]

    /// The Draw tab's pens (`draw`): label, ink mode, colour, width in points.
    public static let pens: [(label: String, mode: String, color: Rgba, width: Double)] = [
        (L10n.text("Black Pen"), "pen", .rgb(20, 20, 20), 1.5), (L10n.text("Red Pen"), "pen", .rgb(0xD8, 0x3F, 0x3F), 1.5),
        (L10n.text("Blue Pen"), "pen", .rgb(0x2E, 0x6F, 0xD8), 1.5), (String(localized: "Pencil", bundle: .module, comment: "ink tool"), "pen", .rgb(90, 90, 90), 1.0),
        (String(localized: "Highlighter", bundle: .module, comment: "ink tool"), "highlighter", .rgb(255, 230, 0), 10.0), (String(localized: "Eraser", bundle: .module, comment: "ink tool"), "eraser", .black, 2.0),
    ]

    /// Insert ▸ Zoom (`zoom_menu`): the kinds, and `insert.zoom`'s parameters for the checked items (sorted).
    public static let zoomKinds: [(String, String)] = [(L10n.text("Slide Zoom"), "slide"), (L10n.text("Section Zoom"), "section"), (L10n.text("Summary Zoom"), "summary")]

    public static func zoomParams(_ kind: String, _ picked: Set<Int>) -> JSON? {
        guard !picked.isEmpty else { return nil }
        let v = JSON.array(picked.sorted().map { .integer($0) })
        return kind == "section" ? ["kind": "section", "sections": v] : ["kind": .string(kind), "slides": v]
    }

    /// The zoom checklist: section names, or the slides as "n. title".
    public static func zoomItems(_ doc: Presentation, _ kind: String) -> [String] {
        if kind == "section" { return doc.sections.map(\.name) }
        return doc.slides.enumerated().map { i, s in "\(i + 1). \(String(rustTrim(s.title.split(separator: "\n").first.map(String.init) ?? "")))" }
    }

    // MARK: Format Shape ▸ Effects presets (effect_presets.rs)

    /// The shadow presets `shape.effects {shadow}` takes.
    public static let shadowPresets = ["none", "outer", "bottom", "center", "inner", "perspective"]
    /// The glow radii (pt) the ribbon's Glow menu offers (`GLOWS`); 0 is "no glow".
    public static let glowPresets: [Double] = [0, 5, 8, 11, 18]
    /// The soft-edge radii (pt) the ribbon's Soft Edges menu offers (`SOFT_EDGES`); 0 is "none".
    public static let softEdgePresets: [Double] = [0, 1, 2.5, 5, 10, 25]

    /// `shadow_preset_id`: the `shape.effects` shadow preset `fx`'s current shadow came from. An inner shadow
    /// wins, as the detail controls read it first.
    public static func shadowPresetId(_ fx: Effects) -> String {
        if fx.innerShadow != nil { return "inner" }
        guard let s = fx.outerShadow else { return "none" }
        if s.align == "bl" { return "perspective" }
        if s.dist == 0 { return "center" }
        if s.dir == 90 { return "bottom" }
        return "outer"
    }

    /// The shadow the detail controls (colour, transparency, blur, angle, distance) edit: the inner one first,
    /// as `shadowPresetId` reads it.
    public static func detailShadow(_ fx: Effects) -> Shadow? { fx.innerShadow ?? fx.outerShadow }

    /// A glow preset: `glowProps {radius}`, which keeps the glow's colour and transparency (0 removes it).
    public static func glowPresetParams(_ radius: Double) -> JSON { ["glowProps": ["radius": .num(radius)]] }

    // MARK: Format Shape ▸ Size: Scale and From (format_shape.rs)

    /// Scale Height or Width: the current size as a percent of the size the pane first showed (100 when that
    /// was zero).
    public static func scalePercent(_ current: Double, base: Double) -> Double { base > 0 ? current / base * 100 : 100 }

    /// `shape.sizePosition` for a Scale field set to `percent` of `base` along `key` (`h` or `w`); nil for a
    /// percent that isn't positive.
    public static func scaleParams(_ key: String, base: Double, percent: Double, lockAspect: Bool) -> JSON? {
        guard percent.isFinite, percent > 0 else { return nil }
        var p: JSON = .emptyObject
        p.set(key, .num(base * percent / 100))
        if lockAspect { p.set("lockAspect", true) }
        return p
    }

    /// Position ▸ From: how far the shown Horizontal and Vertical are from the top-left corner (half the
    /// size for Center). `shape.move` takes the corner, so a typed value is shifted back by as much.
    public static func positionOffset(_ x: Xfrm, center: Bool) -> (dx: Double, dy: Double) {
        center ? (x.w / 2, x.h / 2) : (0, 0)
    }
}
