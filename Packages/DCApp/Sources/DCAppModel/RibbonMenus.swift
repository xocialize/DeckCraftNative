// DCAppModel — the ribbon's own menus: the ones a split arrow, a menu button, a gallery or a pop-up list opens
// when the toolbar has no such menu (the toolbar's are `CommandMenus`). Ports the menus of deckcraft
// `crates/ui-egui/src/ribbon/{home,insert,design,transitions,animations,review,view}.rs` and `galleries.rs`'
// `effects_menu` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with deckcraft's parameters.
// Galleries are menus until R2 draws them as tiles; Quick Styles opens the Format pane, which has its grid.
import DCCore
import DCEngine
import DCModel
import Foundation

@MainActor
public enum RibbonMenus {
    /// The menu for ribbon control `id`, built from the session's state (layouts, the theme, the transition, the
    /// animation picked). Empty for a control without one.
    public static func entries(_ id: String, _ model: AppModel) -> [CommandMenuEntry] {
        let doc = model.session.activeDoc
        switch id {
        // Home
        case "home.paste":
            return [
                .item(L10n.commandLabel("edit.paste", "Paste"), "edit.paste"),
                .item(L10n.commandLabel("edit.pasteText", "Paste and Match Formatting"), "edit.pasteText"),
                .item(L10n.commandLabel("app.pasteSpecial", "Paste Special…"), "app.pasteSpecial"),
                .item(String(localized: "Paste Formatting", bundle: .module), "format.painterApply"),
            ]
        case "home.layout":
            return (doc?.doc.masters.first?.layouts ?? []).map { .item($0.name, "slide.layout", ["layout": .integer($0.id.rawValue)]) }
        case "home.section":
            return [
                .item(String(localized: "Add Section", bundle: .module), "section.add"),
                .item(String(localized: "Remove All Sections", bundle: .module), "section.removeAll"),
            ]
        case "home.fontFamily":
            let fams = InspectorText.fontFamilies(doc, installed: DialogFonts.installedFamilies())
            var out: [CommandMenuEntry] = fams.theme.map { .item($0, "format.font", ["family": .string($0)]) }
            if !out.isEmpty { out.append(.separator) }
            out += fams.all.map { .item($0, "format.font", ["family": .string($0)]) }
            out += [.separator, .item(L10n.commandLabel("font.rescan", "Rescan Installed Fonts"), "font.rescan")]
            return out
        case "home.fontSize":
            return InspectorText.sizes.map { .item(RibbonNumber.number($0), "format.size", ["size": .num($0)]) }
        case "home.spacing":
            return InspectorText.spacings.map { .item($0.0, "format.spacing", ["pt": .num($0.1)]) }
        case "home.case":
            return InspectorText.cases.map { .item($0.0, "format.case", ["mode": .string($0.1)]) }
        case "home.bullets":
            return [.item(String(localized: "None", bundle: .module), "format.bullets", ["on": false])]
                + InspectorText.bulletChars.map { .item(String(localized: "\($0)  Bullet", bundle: .module, comment: "A bullet character, then 'Bullet'"), "format.bullets", ["on": true, "char": .string($0)]) }
                + [.separator, .item(String(localized: "Bullets and Numbering…", bundle: .module), "app.dialog", ["id": "bullets"])]
        case "home.numbering":
            return [.item(String(localized: "None", bundle: .module), "format.numbering", ["on": false])]
                + InspectorText.numberings.map { .item($0.0, "format.numbering", ["on": true, "scheme": .string($0.1)]) }
                + [.separator, .item(String(localized: "Bullets and Numbering…", bundle: .module), "app.dialog", ["id": "bullets"])]
        case "home.lineSpacing":
            return InspectorText.lineSpacings.map { .item(rustFixed($0, places: 1), "format.lineSpacing", ["lines": .num($0)]) } + [
                .separator,
                .item(String(localized: "Line Spacing Options…", bundle: .module), "format.paragraphDialog"),
                .item(String(localized: "Tabs…", bundle: .module), "app.dialog", ["id": "tabs"]),
            ]
        case "home.columns":
            return (1 ... 3).map { .item(String(localized: "\($0) Column(s)", bundle: .module, comment: "Columns menu: the number of text columns"), "format.columns", ["count": .integer($0), "spacing": 18]) }
                + [.item(String(localized: "More Columns…", bundle: .module), "format.columns")]
        case "home.direction":
            return InspectorText.directions.map { .item($0.0, "format.direction", ["dir": .string($0.1)]) }
        case "home.anchor":
            return InspectorText.anchors.map { .item($0.0, "format.anchor", ["anchor": .string($0.1)]) }
        case "home.convertSmartArt":
            return SmartArtCommands.layouts.map { .item($0.1, "smartArt.fromText", ["kind": .string($0.0)]) }
        case "home.arrange":
            return arrange(model)
        case "home.shapeEffects":
            return effects
        case "home.replace":
            return [
                .item(L10n.commandLabel("app.replace", "Replace…"), "app.replace"),
                .item(String(localized: "Replace Fonts…", bundle: .module), "app.dialog", ["id": "replaceFonts"]),
            ]
        // Insert
        case "insert.photoAlbum":
            return [
                .item(String(localized: "New Photo Album…", bundle: .module), "insert.photoAlbum"),
                .item(String(localized: "Edit Photo Album…", bundle: .module), "insert.photoAlbumEdit"),
            ]
        case "insert.icons":
            var cats: [String] = []
            for i in Icons.icons where !cats.contains(i.category) { cats.append(i.category) }
            return cats.map { c in .submenu(c, Icons.icons.filter { $0.category == c }.map { .item($0.label, "insert.icon", ["name": .string($0.name)]) }) }
        case "insert.zoom":
            // A zoom to the current slide, to every section, or a summary of every slide (`zoom_menu` picks them).
            let slide = doc?.selection.slide ?? 0
            let slides = Set(0 ..< (doc?.doc.slides.count ?? 0)), sections = Set(0 ..< (doc?.doc.sections.count ?? 0))
            return InspectorShape.zoomKinds.compactMap { label, kind in
                let picked = kind == "slide" ? [slide] : kind == "section" ? sections : slides
                return InspectorShape.zoomParams(kind, picked).map { .item(label, "insert.zoom", $0) }
            }
        case "insert.action":
            return InspectorShape.actionButtons.map {
                .item(String(localized: "Action Button: \($0)", bundle: .module, comment: "An action button's kind follows: Home, Back, Next…"), "insert.actionButton", ["kind": .string($0)])
            } + [.separator, .item(String(localized: "Action Settings…", bundle: .module), "app.dialog", ["id": "action"])]
        case "insert.wordArt":
            return (0 ..< 6).map { .item(String(localized: "WordArt style \($0 + 1)", bundle: .module), "insert.wordArt", ["style": .integer($0)]) }
        // Design
        case "design.themes":
            return builtinThemes().map { .item($0.name, "design.theme", ["name": .string($0.name)]) }
                + [.separator, .item(L10n.commandLabel("app.browseThemeDialog", "Browse for Themes…"), "app.browseThemeDialog")]
        case "design.variants":
            guard let theme = doc?.doc.masters.first?.theme else { return [] }
            return themeVariants(theme).enumerated().map { .item($0.element.name, "design.variant", ["index": .integer($0.offset)]) }
        case "design.colors":
            return builtinColorSchemes().map { .item($0.name, "design.colors", ["name": .string($0.name)]) }
                + [.separator, .item(String(localized: "Customize Colors…", bundle: .module), "design.colors")]
        case "design.fonts":
            return builtinFontSchemes().map { .item("\($0.name) — \($0.major.latin) / \($0.minor.latin)", "design.fonts", ["name": .string($0.name)]) }
                + [.separator, .item(String(localized: "Customize Fonts…", bundle: .module), "design.fonts")]
        case "design.effects":
            return builtinFormatSchemes().map { .item($0.name, "design.effects", ["name": .string($0.name)]) }
        case "design.background":
            return (1 ... 12).map { .item(String(localized: "Style \($0)", bundle: .module), "design.background", ["style": .integer($0), "all": true]) }
                + [.separator, .item(String(localized: "Reset Slide Background", bundle: .module), "design.background", ["reset": true])]
        case "design.slideSize":
            return [
                .item(String(localized: "Standard (4:3)", bundle: .module), "design.slideSize", ["preset": "standard"]),
                .item(String(localized: "Widescreen (16:9)", bundle: .module), "design.slideSize", ["preset": "widescreen"]),
                .item(String(localized: "Page Setup…", bundle: .module), "app.dialog", ["id": "slideSize"]),
            ]
        // Transitions
        case "transitions.gallery":
            return transitionCategories.map { cat, title in
                .submenu(title, transitions.filter { $0.category == cat }.map { .item($0.label, "transition.set", ["kind": .string($0.id)]) })
            }
        case "transitions.effectOptions":
            let t = doc?.currentSlide?.transition
            return InspectorMotion.transitionEffectRows(t?.kind ?? "none", t?.option)
                .map { .item(InspectorMotion.optionLabel($0.0), "transition.options", ["option": .string($0.0)]) }
        case "transitions.sound":
            let loop = JSON.bool(doc?.currentSlide?.transition?.soundLoop ?? false)
            return [
                .item(String(localized: "[No Sound]", bundle: .module), "transition.sound", ["none": true]),
                .item(String(localized: "[Stop Previous Sound]", bundle: .module), "transition.sound", ["stopPrevious": true]),
                .separator,
            ] + Sounds.builtin.map { .item($0.1, "transition.sound", ["builtin": .string($0.0), "loop": loop]) }
        // Animations
        case "animations.gallery", "animations.add":
            let cmd = id == "animations.gallery" ? "animation.set" : "animation.add"
            return [AnimClass.entrance, .emphasis, .exit, .path].map { cls in
                .submenu(InspectorMotion.className(cls), animations.filter { $0.animClass == cls }.map {
                    .item($0.label, cmd, ["effect": .string($0.id), "class": .string(cls.rawValue)])
                })
            }
        case "animations.effectOptions":
            guard let a = RibbonModel.currentAnimation(model) else { return [] }
            return InspectorMotion.animationEffectRows(a.effect, a.class, a.option).map { .item(InspectorMotion.optionLabel($0.0), "animation.options", ["option": .string($0.0)]) } + [
                .separator,
                .item(String(localized: "As One Object", bundle: .module), "animation.options", ["textBuild": "asOne"]),
                .item(String(localized: "By Paragraph", bundle: .module), "animation.options", ["textBuild": "byParagraph"]),
            ]
        case "animations.trigger":
            return [.item(String(localized: "On Click Sequence", bundle: .module), "animation.timing", ["trigger": .null])]
                + (doc?.shapes ?? []).map { .item(String(localized: "On Click of \($0.name)", bundle: .module), "animation.timing", ["trigger": .integer(Int($0.id.rawValue))]) }
        case "animations.start":
            return InspectorMotion.starts.map { .item($0.0, "animation.timing", ["start": .string($0.1)]) }
        // Review
        case "review.accept":
            return [
                .item(String(localized: "Accept All Changes", bundle: .module), "review.accept", ["all": true]),
                .item(String(localized: "Reject All Changes", bundle: .module), "review.reject", ["all": true]),
            ]
        // View
        case "view.zoom":
            return [400, 200, 150, 100, 75, 66, 50, 33].map { .item("\($0)%", "view.zoom", ["percent": .integer($0)]) }
                + [.item(String(localized: "Fit", bundle: .module, comment: "Zoom menu: fit the slide to the window"), "view.fit")]
        default:
            return arrangeControl(id, model)
        }
    }

    /// The transition categories, as the Animate pane lists them.
    static var transitionCategories: [(String, String)] {
        [
            ("Subtle", String(localized: "Subtle", bundle: .module, comment: "A category of slide transitions")),
            ("Exciting", String(localized: "Exciting", bundle: .module, comment: "A category of slide transitions")),
            ("Dynamic Content", String(localized: "Dynamic Content", bundle: .module, comment: "A category of slide transitions")),
        ]
    }

    /// Home ▸ Arrange: order, group, align and rotate (`arrange_menu`).
    static func arrange(_ model: AppModel) -> [CommandMenuEntry] {
        let to = JSON.string(model.session.activeDoc.map { $0.selection.shapes.count < 2 } ?? true ? "slide" : "selection")
        return [
            .item(L10n.commandLabel("arrange.bringToFront", "Bring to Front"), "arrange.bringToFront"),
            .item(L10n.commandLabel("arrange.sendToBack", "Send to Back"), "arrange.sendToBack"),
            .item(L10n.commandLabel("arrange.bringForward", "Bring Forward"), "arrange.bringForward"),
            .item(L10n.commandLabel("arrange.sendBackward", "Send Backward"), "arrange.sendBackward"),
            .separator,
            .item(L10n.commandLabel("arrange.group", "Group"), "arrange.group"),
            .item(L10n.commandLabel("arrange.ungroup", "Ungroup"), "arrange.ungroup"),
            .item(L10n.commandLabel("arrange.regroup", "Regroup"), "arrange.regroup"),
            .separator,
            .submenu(String(localized: "Align", bundle: .module), align(to)),
            .submenu(String(localized: "Rotate", bundle: .module), rotate),
        ]
    }

    static func align(_ to: JSON) -> [CommandMenuEntry] {
        [
            ("left", String(localized: "Align Left", bundle: .module)), ("center", String(localized: "Align Center", bundle: .module)),
            ("right", String(localized: "Align Right", bundle: .module)), ("top", String(localized: "Align Top", bundle: .module)),
            ("middle", String(localized: "Align Middle", bundle: .module)), ("bottom", String(localized: "Align Bottom", bundle: .module)),
        ].map { .item($0.1, "arrange.align", ["edge": .string($0.0), "to": to]) } + [
            .separator,
            .item(String(localized: "Distribute Horizontally", bundle: .module), "arrange.distribute", ["dir": "horizontal"]),
            .item(String(localized: "Distribute Vertically", bundle: .module), "arrange.distribute", ["dir": "vertical"]),
        ]
    }

    static var rotate: [CommandMenuEntry] {
        ["arrange.rotateRight", "arrange.rotateLeft", "arrange.flipVertical", "arrange.flipHorizontal"].map {
            .item(L10n.commandLabel($0, RibbonModel.registryLabel($0) ?? $0), $0)
        }
    }

    /// The object tabs' Arrange splits (R2 shows them; their menus are here so the layout is complete).
    static func arrangeControl(_ id: String, _ model: AppModel) -> [CommandMenuEntry] {
        let to = JSON.string(model.session.activeDoc.map { $0.selection.shapes.count < 2 } ?? true ? "slide" : "selection")
        let label = { (c: String) in CommandMenuEntry.item(L10n.commandLabel(c, RibbonModel.registryLabel(c) ?? c), c) }
        switch id.split(separator: ".").last.map(String.init) {
        case "bringForward": return [label("arrange.bringForward"), label("arrange.bringToFront")]
        case "sendBackward": return [label("arrange.sendBackward"), label("arrange.sendToBack")]
        case "align": return align(to)
        case "group": return [label("arrange.group"), label("arrange.ungroup"), label("arrange.regroup")]
        case "rotate": return rotate
        default: return []
        }
    }

    /// Shape Effects (`effects_menu`): shadow, reflection, glow and soft edges.
    static var effects: [CommandMenuEntry] {
        [
            .submenu(String(localized: "Shadow", bundle: .module), [
                ("none", String(localized: "No Shadow", bundle: .module)), ("outer", String(localized: "Outer", bundle: .module, comment: "A shadow")),
                ("bottom", String(localized: "Bottom", bundle: .module, comment: "A shadow")), ("center", String(localized: "Centered", bundle: .module, comment: "A shadow")),
                ("inner", String(localized: "Inner", bundle: .module, comment: "A shadow")), ("perspective", String(localized: "Perspective", bundle: .module, comment: "A shadow")),
            ].map { .item($0.1, "shape.effects", ["shadow": .string($0.0)]) }),
            .submenu(String(localized: "Reflection", bundle: .module), [
                ("none", String(localized: "No Reflection", bundle: .module)), ("tight", String(localized: "Tight", bundle: .module, comment: "A reflection")),
                ("half", String(localized: "Half", bundle: .module, comment: "A reflection")), ("full", String(localized: "Full", bundle: .module, comment: "A reflection")),
            ].map { .item($0.1, "shape.effects", ["reflection": .string($0.0)]) }),
            .submenu(String(localized: "Glow", bundle: .module), [.item(String(localized: "No Glow", bundle: .module), "shape.effects", ["glow": .null])]
                + [5.0, 8.0, 11.0, 18.0].map { .item(String(localized: "\(RibbonNumber.number($0)) pt glow", bundle: .module), "shape.effects", ["glow": .num($0)]) }),
            .submenu(String(localized: "Soft Edges", bundle: .module), [0.0, 1.0, 2.5, 5.0, 10.0, 25.0].map {
                .item($0 == 0 ? String(localized: "No Soft Edges", bundle: .module) : String(localized: "\(RibbonNumber.number($0)) pt", bundle: .module, comment: "A size in points"),
                      "shape.effects", ["softEdges": .num($0)])
            }),
        ]
    }
}

/// Numbers in menu titles as deckcraft writes them (`fmt_num`): two decimals at most, trailing zeros dropped.
enum RibbonNumber {
    static func number(_ v: Double) -> String {
        var s = rustFixed(v, places: 2)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
