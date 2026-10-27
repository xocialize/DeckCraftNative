// DCAppModel — Shape Format's Edit Shape choices without a window: Smooth Corners' radius
// (`smooth_corners_row`), the Quick Styles grid (`quick_styles`), the action buttons (Insert ▸ Action) and
// Insert ▸ Zoom's parameters (`zoom_menu`), from deckcraft `crates/ui-egui/src/ribbon.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
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
        ("Black Pen", "pen", .rgb(20, 20, 20), 1.5), ("Red Pen", "pen", .rgb(0xD8, 0x3F, 0x3F), 1.5),
        ("Blue Pen", "pen", .rgb(0x2E, 0x6F, 0xD8), 1.5), ("Pencil", "pen", .rgb(90, 90, 90), 1.0),
        ("Highlighter", "highlighter", .rgb(255, 230, 0), 10.0), ("Eraser", "eraser", .black, 2.0),
    ]

    /// Insert ▸ Zoom (`zoom_menu`): the kinds, and `insert.zoom`'s parameters for the checked items (sorted).
    public static let zoomKinds: [(String, String)] = [("Slide Zoom", "slide"), ("Section Zoom", "section"), ("Summary Zoom", "summary")]

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
}
