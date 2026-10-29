// DCAppModel — the ribbon's galleries as data (Docs/plans/Ribbon-and-StartScreen.md R2): for each gallery source,
// its items by category, the ones shown in the ribbon itself, the one the selection has, and the command a click
// runs with deckcraft's parameters. Ports the galleries of deckcraft `crates/ui-egui/src/ribbon/{design,transitions,
// animations,table,picture_format,smartart}.rs` and `galleries.rs` (`quick_styles`, `smartart_gallery`; MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). DCApp's `RibbonGalleryView` draws the tiles: a
// theme is the start window's tile for it, so both show the same picture.
import DCCore
import DCEngine
import DCModel
import Foundation

/// One tile of a gallery.
public struct RibbonGalleryItem: Equatable, Sendable {
    /// What the tile shows.
    public enum Art: Equatable, Sendable {
        /// The start window's tile with this id (`StartTile.id`, "theme:<name>").
        case startTile(String)
        /// The current theme in variant `index`'s colours.
        case variant(Int)
        /// A transition: its SF Symbol over its name.
        case transition(symbol: String)
        /// An animation: its class's mark over its name.
        case animation(AnimClass)
        /// A table style, drawn from the theme.
        case tableStyle(String)
        /// A picture style's frame and effects (`paint_picture_style`).
        case pictureStyle(String)
        /// Quick Style `index`: a row of the theme styles by Dark 1 and the six accents.
        case quickStyle(Int)
        /// A SmartArt layout (`smartart_gallery`), in a style and colours.
        case smartArt(kind: String, style: String, colors: String)
    }

    public var id: String
    public var label: String
    /// The category title it is listed under when the gallery is expanded; nil for an unsectioned gallery.
    public var category: String?
    public var command: CommandRef
    public var art: Art
}

/// A gallery for the selection: its items, how many the ribbon shows before "›", and the current one.
public struct RibbonGallery: Equatable, Sendable {
    public var source: String
    public var items: [RibbonGalleryItem]
    /// The items the ribbon shows inline, by id, in order.
    public var inline: [String]
    /// The item the selection has, if one does.
    public var selected: String?

    public var inlineItems: [RibbonGalleryItem] { inline.compactMap { id in items.first { $0.id == id } } }

    /// The categories in order, each with its items (one untitled section when nothing is sectioned).
    public var sections: [(title: String?, items: [RibbonGalleryItem])] {
        var out: [(title: String?, items: [RibbonGalleryItem])] = []
        for i in items {
            if let k = out.indices.last, out[k].title == i.category { out[k].items.append(i) } else { out.append((i.category, [i])) }
        }
        return out
    }

    public static func == (a: RibbonGallery, b: RibbonGallery) -> Bool {
        a.source == b.source && a.items == b.items && a.inline == b.inline && a.selected == b.selected
    }
}

@MainActor
public enum RibbonGalleries {
    /// How many tiles each gallery shows in the ribbon before its "›" button.
    static let inlineCount = [
        "themes": 6, "variants": 4, "transitions": 10, "animations": 10, "tableStyles": 7, "pictureStyles": 6,
        "quickStyles": 7, "smartArtLayouts": 4, "smartArtStyles": 5,
    ]

    /// The quick animations deckcraft's Animations tab shows inline (`animations.rs`).
    static let quickAnimations = ["appear", "fade", "fly", "float", "split", "wipe", "zoom", "pulse", "spin", "growShrink", "fadeOut", "flyOut", "lines"]

    /// Every gallery source the ribbon has.
    public static let sources = ["themes", "variants", "transitions", "animations", "tableStyles", "pictureStyles", "quickStyles", "smartArtLayouts", "smartArtStyles"]

    /// The gallery `source` for the session now; nil for an unknown source.
    public static func gallery(_ source: String, _ model: AppModel) -> RibbonGallery? {
        let doc = model.session.activeDoc
        let (items, selected): ([RibbonGalleryItem], String?)
        var inline: [String]?
        switch source {
        case "themes":
            items = builtinThemes().map { th in
                RibbonGalleryItem(id: th.name, label: th.name, command: CommandRef("design.theme", ["name": .string(th.name)]), art: .startTile("theme:\(th.name)"))
            }
            selected = doc?.doc.masters.first?.theme.name
        case "variants":
            let theme = doc?.doc.masters.first?.theme
            let variants = theme.map(themeVariants) ?? []
            items = variants.enumerated().map { i, v in
                RibbonGalleryItem(id: String(i), label: v.name, command: CommandRef("design.variant", ["index": .integer(Int64(i))]), art: .variant(i))
            }
            selected = variants.firstIndex { $0.colors == theme?.colors.colors }.map { String($0) }
        case "transitions":
            let titles = RibbonMenus.transitionCategories
            items = DCModel.transitions.map { t in
                RibbonGalleryItem(id: t.id, label: t.label, category: titles.first { $0.0 == t.category }?.1 ?? t.category,
                                  command: CommandRef("transition.set", ["kind": .string(t.id)]), art: .transition(symbol: transitionSymbol(t.id, t.category)))
            }
            selected = doc?.currentSlide?.transition?.kind ?? "none"
        case "animations":
            items = [AnimClass.entrance, .emphasis, .exit, .path].flatMap { cls in
                DCModel.animations.filter { $0.animClass == cls }.map { a in
                    RibbonGalleryItem(id: "\(cls.rawValue):\(a.id)", label: a.label, category: InspectorMotion.className(cls),
                                      command: CommandRef("animation.set", ["effect": .string(a.id), "class": .string(cls.rawValue)]), art: .animation(cls))
                }
            }
            inline = quickAnimations.compactMap { q in items.first { $0.id.hasSuffix(":\(q)") }?.id }
            selected = RibbonModel.currentAnimation(model).map { "\($0.class.rawValue):\($0.effect)" }
        case "tableStyles":
            let all = tableStyles()
            items = all.map { s in
                RibbonGalleryItem(id: s.id, label: s.label, category: tableStyleCategory(s.id), command: CommandRef("table.style", ["style": .string(s.id)]), art: .tableStyle(s.id))
            }
            // deckcraft's inline row: the plain styles and Medium Style 2 (`table.rs`).
            inline = all.filter { $0.id.hasPrefix("medium2") || $0.id == "none" || $0.id == "grid" }.map(\.id)
            selected = selectedTable(doc)?.style
        case "pictureStyles":
            items = PictureStyleCommands.styles.map { id, label in
                RibbonGalleryItem(id: id, label: label, command: CommandRef("picture.style", ["style": .string(id)]), art: .pictureStyle(id))
            }
            selected = nil
        case "quickStyles":
            items = (0 ..< InspectorShape.quickStyleRows * InspectorShape.quickStyleSlots.count).map { i in
                RibbonGalleryItem(id: String(i), label: String(localized: "Style \(i + 1)", bundle: .module),
                                  command: CommandRef("shape.quickStyle", ["index": .integer(Int64(i))]), art: .quickStyle(i))
            }
            selected = nil
        case "smartArtLayouts":
            let sel = doc.flatMap(SmartArtCommands.selected)
            let (style, colors) = (sel?.1.style ?? "", sel?.1.colors ?? "")
            let id: JSON = sel.map { .integer(Int64($0.0.rawValue)) } ?? .null
            items = smartArtCategories.flatMap { cat, title in
                SmartArtCommands.layouts.filter { SmartArtCommands.category($0.0) == cat }.map { kind, label in
                    RibbonGalleryItem(id: kind, label: label, category: title, command: CommandRef("smartArt.layout", ["id": id, "kind": .string(kind)]),
                                      art: .smartArt(kind: kind, style: style, colors: colors))
                }
            }
            selected = sel?.1.kind
        case "smartArtStyles":
            let sel = doc.flatMap(SmartArtCommands.selected)
            let id: JSON = sel.map { .integer(Int64($0.0.rawValue)) } ?? .null
            let kind = sel?.1.kind ?? "list"
            items = SmartArtCommands.styles.map { style, label in
                RibbonGalleryItem(id: style, label: label, command: CommandRef("smartArt.style", ["id": id, "style": .string(style)]),
                                  art: .smartArt(kind: kind, style: style, colors: sel?.1.colors ?? ""))
            }
            selected = sel.map { $0.1.style.isEmpty ? "flat" : $0.1.style }
        default:
            return nil
        }
        let n = inlineCount[source] ?? 6
        var shown = Array((inline ?? items.map(\.id)).prefix(n))
        // The row starts at the selection's tile when it isn't among the first ones, as a gallery scrolled to it is.
        if let selected, !shown.contains(selected), let k = items.firstIndex(where: { $0.id == selected }) {
            shown = Array(items[k...].prefix(n).map(\.id))
        }
        return RibbonGallery(source: source, items: items, inline: shown, selected: selected)
    }

    /// The gallery a ribbon control shows, or nil for a control that isn't one.
    public static func gallery(_ c: RibbonControl, _ model: AppModel) -> RibbonGallery? {
        guard case .gallery(let source) = c.kind else { return nil }
        return gallery(source, model)
    }

    /// SmartArt's gallery categories (`smartart_gallery`).
    static var smartArtCategories: [(String, String)] {
        [
            ("list", String(localized: "List", bundle: .module, comment: "A category of SmartArt layouts")),
            ("process", String(localized: "Process", bundle: .module, comment: "A category of SmartArt layouts")),
            ("cycle", String(localized: "Cycle", bundle: .module, comment: "A category of SmartArt layouts")),
            ("hierarchy", String(localized: "Hierarchy", bundle: .module, comment: "A category of SmartArt layouts")),
            ("relationship", String(localized: "Relationship", bundle: .module, comment: "A category of SmartArt layouts")),
            ("matrix", String(localized: "Matrix", bundle: .module, comment: "A category of SmartArt layouts")),
            ("pyramid", String(localized: "Pyramid", bundle: .module, comment: "A category of SmartArt layouts")),
            ("picture", String(localized: "Picture", bundle: .module, comment: "A category of SmartArt layouts")),
        ]
    }

    /// A table style's section in the expanded gallery, by the family its id names.
    static func tableStyleCategory(_ id: String) -> String {
        if id.hasPrefix("light") { return String(localized: "Light", bundle: .module, comment: "A family of table styles") }
        if id.hasPrefix("medium") { return String(localized: "Medium", bundle: .module, comment: "A family of table styles") }
        if id.hasPrefix("dark") { return String(localized: "Dark", bundle: .module, comment: "A family of table styles") }
        return String(localized: "Plain", bundle: .module, comment: "Table styles without colours")
    }

    /// The table the selection is in or on.
    static func selectedTable(_ doc: DocState?) -> Table? {
        guard let doc else { return nil }
        let id = doc.selection.text?.cell != nil ? doc.selection.text?.shape : doc.selection.shapes.first
        guard let id, let s = doc.currentSlide?.shape(id), case .table(let t) = s.kind else { return nil }
        return t
    }

    /// A transition's tile symbol: one for each kind whose motion SF Symbols can suggest, else its category's.
    static func transitionSymbol(_ id: String, _ category: String) -> String {
        if let s = transitionSymbols[id] { return s }
        switch category {
        case "Subtle": return "square.on.square"
        case "Exciting": return "sparkles"
        default: return "square.stack.3d.forward.dottedline"
        }
    }

    static let transitionSymbols = [
        "none": "nosign", "morph": "wand.and.stars", "fade": "circle.lefthalf.filled", "push": "arrow.right.square",
        "wipe": "rectangle.righthalf.filled", "split": "arrow.left.and.right", "reveal": "rectangle.lefthalf.inset.filled",
        "cut": "scissors", "randomBar": "rectangle.split.3x1", "shape": "circle.dashed", "uncover": "arrow.up.right.square",
        "cover": "arrow.down.left.square", "flash": "bolt", "fallOver": "arrow.turn.right.down", "drape": "curtains.closed",
        "curtains": "curtains.open", "wind": "wind", "fracture": "square.split.diagonal.2x2", "crush": "arrow.down.right.and.arrow.up.left",
        "peelOff": "arrow.up.forward.square", "pageCurlDouble": "book", "airplane": "airplane", "dissolve": "circle.grid.cross",
        "checker": "checkerboard.rectangle", "blinds": "line.3.horizontal", "clock": "clock", "ripple": "dot.radiowaves.left.and.right",
        "honeycomb": "hexagon", "glitter": "sparkle", "vortex": "tornado", "flip": "arrow.left.arrow.right", "cube": "cube",
        "doors": "door.left.hand.open", "box": "shippingbox", "zoom": "plus.magnifyingglass", "random": "shuffle",
        "pan": "arrow.left.and.right.square", "ferris": "circle.circle", "conveyor": "arrow.right.to.line", "rotate": "rotate.right",
        "window": "macwindow", "orbit": "circle.dotted.and.circle", "flythrough": "arrow.up.and.down.and.arrow.left.and.right",
    ]
}
