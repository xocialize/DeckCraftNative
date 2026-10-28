// DCAppModel — the ribbon as data: tabs, groups and controls, each control a registry command with deckcraft's
// parameters (Docs/plans/Ribbon-and-StartScreen.md §4). Ports the tabs of deckcraft `crates/ui-egui/src/ribbon.rs`
// and `ribbon/{home,insert,draw,design,transitions,animations,slide_show,review,view,shape_format,picture_format,
// table,chart,smartart,playback,masters,arrange}.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), arranged as someone who knows PowerPoint expects to find them: familiarity, not a 100% match.
// Controls deckcraft keeps permanently disabled (Screenshot, Ink to Text, Ink to Math, Cameo, Translate) are left out.
//
// No AppKit: the layout is a description, tested without a window. Labels, shortcuts and enabled state are not
// written here: they come from the registry through `L10n`, as the menus' and the toolbar's do. A control carries a
// title only where its command's label doesn't name it (`app.dialog`, `view.pane`, a menu). The menus it opens are
// `CommandMenus` where the toolbar has the same one; the ribbon's own menus list the commands they run in `also`,
// and R1 builds them. `RibbonMap` (where each group lives in the Mac layout) is derived from this table.
import DCCore
import Foundation

/// The sizes a control or group takes as the ribbon narrows (§5).
public enum RibbonSize: String, Sendable, CaseIterable {
    /// A big icon over its label.
    case large
    /// A small icon with its label.
    case medium
    /// A small icon only.
    case small
}

public struct RibbonControl: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case button
        /// Shown on while `state` is set: a `format.state` key, or the ui state the command toggles.
        case toggle(state: String)
        /// The main half runs `command`; the arrow opens the menu (nil: the ribbon's own menu, built in R1).
        case split(CommandMenus.ID?)
        /// A button that only opens a menu; `command` is its first item.
        case menu(CommandMenus.ID?)
        /// An inline gallery of `source` (themes, transitions, styles…) with a "more" menu.
        case gallery(source: String)
        /// A pop-up list of `source` (font families, sizes, sounds…).
        case dropdown(source: String)
        /// A number field with a stepper, setting `field` of the command's parameters.
        case spinner(field: String)
        /// A check box, setting `field` of the command's parameters.
        case check(field: String)
        /// A colour split: the main half reapplies the last colour, the arrow opens the colour grid.
        case color
    }

    public var id: String
    /// The title to show when the command's label doesn't name the control.
    public var title: String?
    public var command: CommandRef
    public var kind: Kind
    /// The sizes it can take, largest first.
    public var sizes: [RibbonSize]
    /// The other commands its menu, gallery or pane runs, when that menu isn't a `CommandMenus` one.
    public var also: [String]

    /// Every command the control can run, in order, without repeats.
    public var commands: [String] {
        var menu: [String] = []
        switch kind {
        case .split(let m?), .menu(let m?): menu = CommandMenus.commands(m)
        default: break
        }
        var out: [String] = []
        for c in [command.id] + menu + also where !out.contains(c) { out.append(c) }
        return out
    }
}

public struct RibbonGroup: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Which groups give way first as the ribbon narrows: the highest first; 0 never folds (§5).
    public var foldOrder: Int
    public var controls: [RibbonControl]

    /// Every command the group's controls run, in order, without repeats.
    public var commands: [String] {
        var out: [String] = []
        for c in controls.flatMap(\.commands) where !out.contains(c) { out.append(c) }
        return out
    }
}

public struct RibbonTab: Sendable, Equatable {
    public var id: String
    public var title: String
    /// For a contextual tab, the name `InspectorController.contextual()` gives it; nil for the ten regular tabs.
    public var contextual: String?
    public var groups: [RibbonGroup]
}

public enum RibbonLayout {
    // MARK: Builders

    static func c(_ id: String, _ command: String, _ params: JSON = .emptyObject, _ kind: RibbonControl.Kind = .button,
                  title: String? = nil, sizes: [RibbonSize] = [.large, .medium, .small], also: [String] = []) -> RibbonControl {
        RibbonControl(id: id, title: title, command: CommandRef(command, params), kind: kind, sizes: sizes, also: also)
    }

    /// A small control: it is never drawn large.
    static func s(_ id: String, _ command: String, _ params: JSON = .emptyObject, _ kind: RibbonControl.Kind = .button,
                  title: String? = nil, also: [String] = []) -> RibbonControl {
        c(id, command, params, kind, title: title, sizes: [.medium, .small], also: also)
    }

    /// An icon-only control (B I U, the alignments): never drawn with its label; the tooltip names it.
    static func i(_ id: String, _ command: String, _ params: JSON = .emptyObject, _ kind: RibbonControl.Kind = .button,
                  title: String? = nil, also: [String] = []) -> RibbonControl {
        c(id, command, params, kind, title: title, sizes: [.small], also: also)
    }

    static func g(_ id: String, _ title: String, fold: Int, _ controls: [RibbonControl]) -> RibbonGroup {
        RibbonGroup(id: id, title: title, foldOrder: fold, controls: controls)
    }

    /// Arrange (`arrange.rs` `arrange_group`), shared by the object tabs.
    static func arrange(_ tab: String) -> RibbonGroup {
        g("\(tab).arrange", "Arrange", fold: 3, [
            c("\(tab).bringForward", "arrange.bringForward", .emptyObject, .split(nil), also: ["arrange.bringToFront"]),
            c("\(tab).sendBackward", "arrange.sendBackward", .emptyObject, .split(nil), also: ["arrange.sendToBack"]),
            c("\(tab).selectionPane", "view.pane", ["pane": "selection"], title: "Selection Pane",
              also: ["arrange.reorder", "selection.select", "selection.showAll", "selection.hideAll", "shape.visible", "shape.lock", "shape.rename"]),
            s("\(tab).align", "arrange.align", .emptyObject, .menu(nil), title: "Align", also: ["arrange.distribute"]),
            s("\(tab).group", "arrange.group", .emptyObject, .split(nil), also: ["arrange.ungroup", "arrange.regroup"]),
            s("\(tab).rotate", "arrange.rotateRight", .emptyObject, .split(nil), title: "Rotate",
              also: ["arrange.rotateLeft", "arrange.flipVertical", "arrange.flipHorizontal"]),
        ])
    }

    /// Size (`arrange.rs` `size_group`), shared by the object tabs.
    static func size(_ tab: String) -> RibbonGroup {
        g("\(tab).size", "Size", fold: 2, [
            s("\(tab).height", "shape.resize", .emptyObject, .spinner(field: "h"), title: "Height"),
            s("\(tab).width", "shape.resize", .emptyObject, .spinner(field: "w"), title: "Width"),
            s("\(tab).sizePosition", "shape.sizePosition", also: ["shape.rotate", "shape.move"]),
        ])
    }

    // MARK: The tabs

    public static let tabs: [RibbonTab] = regular + contextualTabs

    /// Home, Insert, Draw, Design, Transitions, Animations, Slide Show, Record, Review, View (`ribbon.rs` `TABS`).
    static let regular: [RibbonTab] = [home, insert, draw, design, transitions, animations, slideShow, record, review, view]

    static let home = RibbonTab(id: "home", title: "Home", contextual: nil, groups: [
        g("home.clipboard", "Clipboard", fold: 1, [
            c("home.paste", "edit.paste", .emptyObject, .split(nil), sizes: [.large], also: ["edit.pasteText", "app.pasteSpecial", "format.painterApply"]),
            s("home.cut", "edit.cut"),
            s("home.copy", "edit.copy"),
            s("home.formatPainter", "format.painter", .emptyObject, .toggle(state: "painter")),
        ]),
        g("home.slides", "Slides", fold: 4, [
            c("home.newSlide", "slide.new", .emptyObject, .split(.newSlide)),
            s("home.layout", "slide.layout", .emptyObject, .menu(nil), title: "Layout"),
            s("home.reset", "slide.reset"),
            s("home.section", "section.add", .emptyObject, .menu(nil), title: "Section", also: ["section.removeAll"]),
        ]),
        g("home.font", "Font", fold: 1, [
            s("home.fontFamily", "format.font", .emptyObject, .dropdown(source: "fonts"), also: ["font.rescan"]),
            s("home.fontSize", "format.size", .emptyObject, .dropdown(source: "sizes")),
            i("home.grow", "format.grow"),
            i("home.shrink", "format.shrink"),
            i("home.clear", "format.clear"),
            i("home.bold", "format.bold", .emptyObject, .toggle(state: "bold")),
            i("home.italic", "format.italic", .emptyObject, .toggle(state: "italic")),
            i("home.underline", "format.underline", .emptyObject, .toggle(state: "underline")),
            i("home.strikethrough", "format.strikethrough", .emptyObject, .toggle(state: "strike")),
            i("home.superscript", "format.superscript", .emptyObject, .toggle(state: "superscript")),
            i("home.subscript", "format.subscript", .emptyObject, .toggle(state: "subscript")),
            i("home.spacing", "format.spacing", .emptyObject, .menu(nil), title: "Character Spacing"),
            i("home.case", "format.case", .emptyObject, .menu(nil), title: "Change Case"),
            i("home.highlight", "format.highlight", .emptyObject, .color),
            i("home.fontColor", "format.color", .emptyObject, .color),
            s("home.fontDialog", "format.fontDialog"),
        ]),
        g("home.paragraph", "Paragraph", fold: 3, [
            i("home.bullets", "format.bullets", .emptyObject, .split(nil), also: ["app.dialog"]),
            i("home.numbering", "format.numbering", .emptyObject, .split(nil)),
            i("home.outdent", "format.outdent"),
            i("home.indent", "format.indent"),
            i("home.lineSpacing", "format.lineSpacing", .emptyObject, .menu(nil), title: "Line Spacing", also: ["format.paragraphDialog", "app.dialog"]),
            i("home.columns", "format.columns", .emptyObject, .menu(nil), title: "Columns"),
            i("home.alignLeft", "format.alignLeft", .emptyObject, .toggle(state: "align")),
            i("home.alignCenter", "format.alignCenter", .emptyObject, .toggle(state: "align")),
            i("home.alignRight", "format.alignRight", .emptyObject, .toggle(state: "align")),
            i("home.justify", "format.justify", .emptyObject, .toggle(state: "align")),
            i("home.direction", "format.direction", .emptyObject, .menu(nil), title: "Text Direction"),
            i("home.anchor", "format.anchor", .emptyObject, .menu(nil), title: "Align Text"),
            i("home.convertSmartArt", "smartArt.fromText", .emptyObject, .menu(nil), title: "Convert to SmartArt"),
            s("home.paragraphDialog", "format.paragraphDialog"),
        ]),
        // PowerPoint's Home tab groups Picture, Shapes and Text Box together; deckcraft splits them into
        // Images and Drawing.
        g("home.insert", "Insert", fold: 5, [
            c("home.picture", "app.insertPictureDialog", .emptyObject, .split(.picture), title: "Picture"),
            c("home.shapes", "shape.insert", ["preset": "rect"], .split(.shapes), title: "Shapes"),
            c("home.textBox", "insert.textBox"),
        ]),
        g("home.drawing", "Drawing", fold: 6, [
            c("home.arrange", "arrange.bringToFront", .emptyObject, .menu(nil), title: "Arrange",
              also: ["arrange.sendToBack", "arrange.bringForward", "arrange.sendBackward", "arrange.group", "arrange.ungroup",
                     "arrange.regroup", "arrange.align", "arrange.distribute", "arrange.rotateRight", "arrange.rotateLeft",
                     "arrange.flipVertical", "arrange.flipHorizontal"]),
            c("home.quickStyles", "shape.quickStyle", .emptyObject, .gallery(source: "quickStyles"), title: "Quick Styles"),
            s("home.shapeFill", "shape.fill", .emptyObject, .color, title: "Shape Fill"),
            s("home.shapeOutline", "shape.line", .emptyObject, .color, title: "Shape Outline"),
            s("home.shapeEffects", "shape.effects", .emptyObject, .menu(nil), title: "Shape Effects"),
        ]),
        g("home.editing", "Editing", fold: 2, [
            s("home.find", "app.find"),
            s("home.replace", "app.replace", .emptyObject, .split(nil), also: ["app.dialog", "font.replace"]),
            s("home.selectionPane", "view.pane", ["pane": "selection"], title: "Selection Pane"),
        ]),
        g("home.designer", "Designer", fold: 0, [
            c("home.designer", "view.pane", ["pane": "designer"], title: "Designer", sizes: [.large], also: ["design.applyIdea", "design.theme"]),
        ]),
    ])

    static let insert = RibbonTab(id: "insert", title: "Insert", contextual: nil, groups: [
        g("insert.slides", "Slides", fold: 1, [
            c("insert.newSlide", "slide.new", .emptyObject, .split(.newSlide)),
        ]),
        g("insert.tables", "Tables", fold: 2, [
            c("insert.table", "insert.table", ["rows": 3, "cols": 3], .split(.table), title: "Table"),
        ]),
        g("insert.images", "Images", fold: 3, [
            c("insert.pictures", "app.insertPictureDialog", .emptyObject, .split(.picture), title: "Pictures"),
            c("insert.photoAlbum", "insert.photoAlbum", .emptyObject, .split(nil), also: ["insert.photoAlbumEdit"]),
        ]),
        g("insert.illustrations", "Illustrations", fold: 4, [
            c("insert.shapes", "shape.insert", ["preset": "rect"], .split(.shapes), title: "Shapes"),
            c("insert.icons", "insert.icon", .emptyObject, .menu(nil), title: "Icons"),
            c("insert.smartArt", "app.dialog", ["id": "smartart"], title: "SmartArt"),
            c("insert.chart", "insert.chart", ["type": "Column"], .split(.chart), title: "Chart"),
        ]),
        g("insert.links", "Links", fold: 5, [
            c("insert.zoom", "insert.zoom", .emptyObject, .menu(nil), title: "Zoom"),
            c("insert.link", "app.dialog", ["id": "hyperlink"], title: "Link"),
            c("insert.action", "insert.actionButton", .emptyObject, .menu(nil), title: "Action", also: ["app.dialog"]),
        ]),
        g("insert.comments", "Comments", fold: 2, [
            c("insert.comment", "app.dialog", ["id": "comment"], title: "Comment"),
        ]),
        g("insert.text", "Text", fold: 6, [
            c("insert.textBox", "insert.textBox"),
            c("insert.headerFooter", "app.dialog", ["id": "headerFooter"], title: "Header & Footer"),
            c("insert.wordArt", "insert.wordArt", .emptyObject, .menu(nil)),
            s("insert.dateTime", "insert.dateTime"),
            s("insert.slideNumber", "insert.slideNumber"),
        ]),
        g("insert.symbols", "Symbols", fold: 5, [
            c("insert.equation", "app.dialog", ["id": "equation"], title: "Equation"),
            c("insert.symbol", "app.dialog", ["id": "symbol"], title: "Symbol"),
        ]),
        g("insert.media", "Media", fold: 3, [
            c("insert.video", "app.insertVideoDialog", title: "Video"),
            c("insert.audio", "app.insertAudioDialog", title: "Audio"),
        ]),
    ])

    /// Draw (`draw.rs`): the canvas's tools, not commands (`tool.*`, as the toolbar's Draw menu runs them).
    static let draw = RibbonTab(id: "draw", title: "Draw", contextual: nil, groups: [
        g("draw.tools", "Tools", fold: 1, [
            c("draw.select", "tool.select", title: "Select"),
            c("draw.eraser", "tool.ink", ["pen": 5], .toggle(state: "tool"), title: "Eraser"),
        ]),
        g("draw.pens", "Pens", fold: 2, [
            c("draw.blackPen", "tool.ink", ["pen": 0], .toggle(state: "tool"), title: "Black Pen"),
            c("draw.redPen", "tool.ink", ["pen": 1], .toggle(state: "tool"), title: "Red Pen"),
            c("draw.bluePen", "tool.ink", ["pen": 2], .toggle(state: "tool"), title: "Blue Pen"),
            c("draw.pencil", "tool.ink", ["pen": 3], .toggle(state: "tool"), title: "Pencil"),
            c("draw.highlighter", "tool.ink", ["pen": 4], .toggle(state: "tool"), title: "Highlighter"),
        ]),
        g("draw.convert", "Convert", fold: 1, [
            c("draw.inkToShape", "draw.inkToShape"),
        ]),
    ])

    static let design = RibbonTab(id: "design", title: "Design", contextual: nil, groups: [
        g("design.themes", "Themes", fold: 2, [
            c("design.themes", "design.theme", .emptyObject, .gallery(source: "themes"), title: "Themes", also: ["app.browseThemeDialog"]),
        ]),
        g("design.variants", "Variants", fold: 3, [
            c("design.variants", "design.variant", .emptyObject, .gallery(source: "variants"), title: "Variants"),
            s("design.colors", "design.colors", .emptyObject, .menu(nil), title: "Colors"),
            s("design.fonts", "design.fonts", .emptyObject, .menu(nil), title: "Fonts"),
            s("design.effects", "design.effects", .emptyObject, .menu(nil), title: "Effects"),
            s("design.background", "design.background", .emptyObject, .menu(nil), title: "Background Styles"),
        ]),
        g("design.customize", "Customize", fold: 1, [
            c("design.slideSize", "design.slideSize", .emptyObject, .menu(nil), title: "Slide Size", also: ["app.dialog"]),
            c("design.formatBackground", "view.pane", ["pane": "background"], title: "Format Background", also: ["design.background", "design.hideBackgroundGraphics"]),
        ]),
        g("design.designer", "Designer", fold: 0, [
            c("design.designer", "view.pane", ["pane": "designer"], title: "Designer", sizes: [.large], also: ["design.applyIdea"]),
        ]),
    ])

    static let transitions = RibbonTab(id: "transitions", title: "Transitions", contextual: nil, groups: [
        g("transitions.preview", "Preview", fold: 1, [
            c("transitions.preview", "show.start", ["preview": true], title: "Preview"),
        ]),
        g("transitions.transition", "Transition to This Slide", fold: 3, [
            c("transitions.gallery", "transition.set", .emptyObject, .gallery(source: "transitions"), title: "Transitions"),
            c("transitions.effectOptions", "transition.options", .emptyObject, .menu(nil), title: "Effect Options"),
        ]),
        g("transitions.timing", "Timing", fold: 2, [
            s("transitions.sound", "transition.sound", .emptyObject, .dropdown(source: "sounds"), title: "Sound"),
            s("transitions.duration", "transition.timing", .emptyObject, .spinner(field: "duration"), title: "Duration"),
            s("transitions.onClick", "transition.timing", .emptyObject, .check(field: "onClick"), title: "On Mouse Click"),
            s("transitions.after", "transition.timing", .emptyObject, .spinner(field: "after"), title: "After"),
            c("transitions.applyAll", "transition.applyAll"),
        ]),
    ])

    static let animations = RibbonTab(id: "animations", title: "Animations", contextual: nil, groups: [
        g("animations.preview", "Preview", fold: 1, [
            c("animations.preview", "animation.preview", title: "Preview"),
        ]),
        g("animations.animation", "Animation", fold: 3, [
            c("animations.gallery", "animation.set", .emptyObject, .gallery(source: "animations"), title: "Animations"),
            c("animations.effectOptions", "animation.options", .emptyObject, .menu(nil), title: "Effect Options"),
        ]),
        g("animations.advanced", "Advanced Animation", fold: 4, [
            c("animations.add", "animation.add", .emptyObject, .menu(nil), title: "Add Animation"),
            s("animations.pane", "view.pane", ["pane": "animation"], title: "Animation Pane", also: ["animation.move", "animation.remove"]),
            s("animations.trigger", "animation.timing", .emptyObject, .menu(nil), title: "Trigger"),
            s("animations.painter", "animation.painter", .emptyObject, .toggle(state: "animationPainter")),
        ]),
        g("animations.timing", "Timing", fold: 2, [
            s("animations.start", "animation.timing", .emptyObject, .dropdown(source: "animationStart"), title: "Start"),
            s("animations.duration", "animation.timing", .emptyObject, .spinner(field: "duration"), title: "Duration"),
            s("animations.delay", "animation.timing", .emptyObject, .spinner(field: "delay"), title: "Delay"),
        ]),
    ])

    static let slideShow = RibbonTab(id: "slideShow", title: "Slide Show", contextual: nil, groups: [
        g("slideShow.start", "Start Slide Show", fold: 1, [
            c("slideShow.fromStart", "show.fromStart"),
            c("slideShow.fromCurrent", "show.fromCurrent"),
            c("slideShow.presenter", "show.presenter", .emptyObject, .toggle(state: "presenterView")),
            c("slideShow.customShow", "app.dialog", ["id": "customShow"], title: "Custom Show"),
        ]),
        g("slideShow.setUp", "Set Up", fold: 2, [
            c("slideShow.setUpShow", "app.dialog", ["id": "setupShow"], title: "Set Up Slide Show"),
            c("slideShow.hide", "slide.hide", .emptyObject, .toggle(state: "hidden")),
            c("slideShow.rehearse", "show.start", ["rehearse": true], title: "Rehearse Timings"),
        ]),
        g("slideShow.options", "Options", fold: 3, [
            s("slideShow.useTimings", "show.setup", .emptyObject, .check(field: "useTimings"), title: "Use Timings"),
            s("slideShow.narrations", "show.setup", .emptyObject, .check(field: "noNarration"), title: "Play Narrations"),
            s("slideShow.mediaControls", "show.setup", .emptyObject, .check(field: "showMediaControls"), title: "Show Media Controls"),
        ]),
    ])

    /// Record (`slide_show.rs` `record`): rehearsing from the start or the current slide. Cameo is left out.
    static let record = RibbonTab(id: "record", title: "Record", contextual: nil, groups: [
        g("record.record", "Record", fold: 1, [
            c("record.fromBeginning", "show.start", ["rehearse": true, "from": 0], title: "From Beginning"),
            // R1 adds `from`, the current slide, when it runs.
            c("record.fromCurrent", "show.start", ["rehearse": true], title: "From Current Slide"),
        ]),
    ])

    /// Review: Proofing, Accessibility, Language, Comments, then Compare, in PowerPoint's order (deckcraft puts
    /// Compare before Comments). Translate is left out.
    static let review = RibbonTab(id: "review", title: "Review", contextual: nil, groups: [
        g("review.proofing", "Proofing", fold: 2, [
            c("review.spelling", "app.dialog", ["id": "spelling"], title: "Spelling"),
            c("review.thesaurus", "review.thesaurusPane", also: ["review.replaceWord"]),
        ]),
        g("review.accessibility", "Accessibility", fold: 1, [
            c("review.checkAccessibility", "app.dialog", ["id": "accessibility"], title: "Check Accessibility"),
        ]),
        g("review.language", "Language", fold: 1, [
            c("review.language", "app.dialog", ["id": "language"], title: "Language"),
        ]),
        g("review.comments", "Comments", fold: 3, [
            c("review.newComment", "app.dialog", ["id": "comment"], title: "New Comment"),
            c("review.delete", "comment.delete"),
            c("review.previous", "comment.prev"),
            c("review.next", "comment.next"),
            c("review.showComments", "view.pane", ["pane": "comments"], title: "Show Comments", also: ["comment.reply", "comment.resolve"]),
        ]),
        g("review.compare", "Compare", fold: 4, [
            c("review.compare", "app.compareDialog"),
            s("review.accept", "review.accept", ["all": true], .split(nil), also: ["review.reject"]),
            s("review.endReview", "review.endCompare"),
        ]),
    ])

    static let view = RibbonTab(id: "view", title: "View", contextual: nil, groups: [
        g("view.views", "Presentation Views", fold: 3, [
            c("view.normal", "view.normal", .emptyObject, .toggle(state: "view")),
            c("view.outline", "view.outline", .emptyObject, .toggle(state: "view")),
            c("view.sorter", "view.sorter", .emptyObject, .toggle(state: "view")),
            c("view.notesPage", "view.notesPage", .emptyObject, .toggle(state: "view")),
            c("view.reading", "view.reading", .emptyObject, .toggle(state: "view")),
        ]),
        g("view.masters", "Master Views", fold: 4, [
            c("view.slideMaster", "view.slideMaster", .emptyObject, .toggle(state: "target"), also: ["view.closeMaster"]),
            c("view.handoutMaster", "view.handoutMaster", .emptyObject, .toggle(state: "target"), also: ["view.closeMaster"]),
            c("view.notesMaster", "view.notesMaster", .emptyObject, .toggle(state: "target"), also: ["view.closeMaster"]),
        ]),
        g("view.show", "Show", fold: 2, [
            s("view.ruler", "view.ruler", .emptyObject, .check(field: "on")),
            s("view.gridlines", "view.gridlines", .emptyObject, .check(field: "on")),
            s("view.guides", "view.guides", .emptyObject, .check(field: "on")),
            s("view.gridOptions", "view.gridOptions"),
            c("view.notes", "view.notes", .emptyObject, .toggle(state: "notes")),
        ]),
        g("view.zoom", "Zoom", fold: 1, [
            c("view.zoom", "view.zoomDialog", .emptyObject, .split(nil), title: "Zoom", also: ["view.zoom", "view.fit"]),
            c("view.fit", "view.fit"),
        ]),
        g("view.window", "Window", fold: 5, [
            c("view.newWindow", "view.newWindow"),
        ]),
        g("view.color", "Color", fold: 5, [
            s("view.grayscale", "view.grayscale", .emptyObject, .toggle(state: "grayscale")),
            s("view.dark", "view.dark", .emptyObject, .toggle(state: "dark")),
        ]),
    ])

    // MARK: Contextual tabs (`ribbon.rs` `contextual`)

    static let contextualTabs: [RibbonTab] = [slideMaster, notesMaster, handoutMaster, shapeFormat, pictureFormat, tableDesign, tableLayout,
                                              smartArtDesign, chartDesign, playback]

    static let shapeFormat = RibbonTab(id: "shapeFormat", title: "Shape Format", contextual: "Shape Format", groups: [
        g("shapeFormat.insertShapes", "Insert Shapes", fold: 4, [
            c("shapeFormat.shapes", "shape.insert", ["preset": "rect"], .split(.shapes), title: "Shapes"),
            s("shapeFormat.textBox", "insert.textBox"),
            s("shapeFormat.editShape", "shape.change", .emptyObject, .menu(nil), title: "Edit Shape", also: ["shape.editPoints", "shape.smoothCorners"]),
            s("shapeFormat.merge", "shape.merge", .emptyObject, .menu(nil), title: "Merge Shapes"),
        ]),
        g("shapeFormat.shapeStyles", "Shape Styles", fold: 5, [
            c("shapeFormat.quickStyles", "shape.quickStyle", .emptyObject, .gallery(source: "quickStyles"), title: "Shape Styles"),
            s("shapeFormat.fill", "shape.fill", .emptyObject, .color, title: "Shape Fill", also: ["view.pane"]),
            s("shapeFormat.outline", "shape.line", .emptyObject, .color, title: "Shape Outline"),
            s("shapeFormat.effects", "shape.effects", .emptyObject, .menu(nil), title: "Shape Effects"),
        ]),
        g("shapeFormat.wordArt", "WordArt Styles", fold: 6, [
            s("shapeFormat.textFill", "format.color", .emptyObject, .color, title: "Text Fill", also: ["format.textTransparency"]),
            s("shapeFormat.textOutline", "format.textOutline", .emptyObject, .menu(nil), title: "Text Outline"),
            s("shapeFormat.textEffects", "format.textShadow", .emptyObject, .menu(nil), title: "Text Effects", also: ["format.textWarp"]),
        ]),
        g("shapeFormat.accessibility", "Accessibility", fold: 1, [
            c("shapeFormat.altText", "app.dialog", ["id": "altText"], title: "Alt Text", also: ["shape.altText"]),
        ]),
        arrange("shapeFormat"),
        size("shapeFormat"),
        g("shapeFormat.pane", "Format Pane", fold: 0, [
            c("shapeFormat.formatPane", "view.pane", ["pane": "format"], title: "Format Pane", sizes: [.large]),
        ]),
    ])

    static let pictureFormat = RibbonTab(id: "pictureFormat", title: "Picture Format", contextual: "Picture Format", groups: [
        g("pictureFormat.adjust", "Adjust", fold: 4, [
            c("pictureFormat.removeBackground", "picture.removeBackground", .emptyObject, .menu(nil), title: "Remove Background"),
            c("pictureFormat.corrections", "picture.adjust", .emptyObject, .menu(nil), title: "Corrections"),
            c("pictureFormat.color", "picture.recolor", .emptyObject, .menu(nil), title: "Color", also: ["picture.adjust", "picture.transparentColor"]),
            c("pictureFormat.artistic", "picture.artisticEffect", .emptyObject, .menu(nil), title: "Artistic Effects"),
            c("pictureFormat.transparency", "picture.adjust", .emptyObject, .menu(nil), title: "Transparency"),
            s("pictureFormat.change", "app.changePictureDialog"),
            s("pictureFormat.reset", "picture.reset"),
            s("pictureFormat.compress", "picture.compress", .emptyObject, .split(nil)),
        ]),
        g("pictureFormat.styles", "Picture Styles", fold: 5, [
            c("pictureFormat.gallery", "picture.style", .emptyObject, .gallery(source: "pictureStyles"), title: "Picture Styles"),
            s("pictureFormat.border", "shape.line", .emptyObject, .color, title: "Picture Border"),
            s("pictureFormat.altText", "app.dialog", ["id": "altText"], title: "Alt Text", also: ["shape.altText"]),
        ]),
        arrange("pictureFormat"),
        g("pictureFormat.crop", "Crop", fold: 2, [
            c("pictureFormat.crop", "picture.crop", .emptyObject, .split(nil), title: "Crop", also: ["shape.change"]),
        ]),
        size("pictureFormat"),
    ])

    static let tableDesign = RibbonTab(id: "tableDesign", title: "Table Design", contextual: "Table Design", groups: [
        g("tableDesign.options", "Table Style Options", fold: 3, [
            s("tableDesign.headerRow", "table.options", .emptyObject, .check(field: "headerRow"), title: "Header Row"),
            s("tableDesign.firstColumn", "table.options", .emptyObject, .check(field: "firstColumn"), title: "First Column"),
            s("tableDesign.totalRow", "table.options", .emptyObject, .check(field: "totalRow"), title: "Total Row"),
            s("tableDesign.lastColumn", "table.options", .emptyObject, .check(field: "lastColumn"), title: "Last Column"),
            s("tableDesign.bandedRows", "table.options", .emptyObject, .check(field: "bandedRows"), title: "Banded Rows"),
            s("tableDesign.bandedColumns", "table.options", .emptyObject, .check(field: "bandedColumns"), title: "Banded Columns"),
        ]),
        g("tableDesign.styles", "Table Styles", fold: 4, [
            c("tableDesign.gallery", "table.style", .emptyObject, .gallery(source: "tableStyles"), title: "Table Styles"),
            s("tableDesign.shading", "table.cellFill", .emptyObject, .color, title: "Shading"),
            s("tableDesign.borders", "table.borders", .emptyObject, .menu(nil), title: "Borders"),
        ]),
        g("tableDesign.drawBorders", "Draw Borders", fold: 2, [
            c("tableDesign.drawTable", "tool.shape", ["preset": "drawTable"], .toggle(state: "tool"), title: "Draw Table"),
            c("tableDesign.eraser", "tool.shape", ["preset": "tableEraser"], .toggle(state: "tool"), title: "Eraser"),
        ]),
    ])

    /// Table Layout (`table.rs` `table_layout`).
    static let tableLayout = RibbonTab(id: "tableLayout", title: "Layout", contextual: "Layout", groups: [
        g("tableLayout.rowsColumns", "Rows & Columns", fold: 3, [
            c("tableLayout.delete", "table.deleteRow", .emptyObject, .menu(nil), title: "Delete", also: ["table.deleteColumn", "edit.delete"]),
            c("tableLayout.insertAbove", "table.insertRowAbove"),
            c("tableLayout.insertBelow", "table.insertRowBelow"),
            c("tableLayout.insertLeft", "table.insertColumnLeft"),
            c("tableLayout.insertRight", "table.insertColumnRight"),
        ]),
        g("tableLayout.merge", "Merge", fold: 2, [
            c("tableLayout.merge", "table.merge"),
            c("tableLayout.split", "table.split"),
        ]),
        g("tableLayout.cellSize", "Cell Size", fold: 2, [
            s("tableLayout.distributeRows", "table.distributeRows"),
            s("tableLayout.distributeColumns", "table.distributeColumns"),
        ]),
        g("tableLayout.alignment", "Alignment", fold: 4, [
            s("tableLayout.alignLeft", "format.alignLeft", .emptyObject, .toggle(state: "align")),
            s("tableLayout.alignCenter", "format.alignCenter", .emptyObject, .toggle(state: "align")),
            s("tableLayout.alignRight", "format.alignRight", .emptyObject, .toggle(state: "align")),
            s("tableLayout.alignTop", "table.cellAlign", ["anchor": "top"], .toggle(state: "anchor"), title: "Align Top"),
            s("tableLayout.alignMiddle", "table.cellAlign", ["anchor": "middle"], .toggle(state: "anchor"), title: "Center Vertically"),
            s("tableLayout.alignBottom", "table.cellAlign", ["anchor": "bottom"], .toggle(state: "anchor"), title: "Align Bottom"),
            s("tableLayout.margins", "table.cellMargins", .emptyObject, .menu(nil), title: "Cell Margins"),
        ]),
        arrange("tableLayout"),
    ])

    static let chartDesign = RibbonTab(id: "chartDesign", title: "Chart Design", contextual: "Chart Design", groups: [
        g("chartDesign.type", "Type", fold: 2, [
            c("chartDesign.changeType", "chart.type", .emptyObject, .menu(nil), title: "Change Chart Type"),
        ]),
        g("chartDesign.data", "Data", fold: 1, [
            c("chartDesign.editData", "app.dialog", ["id": "chartData"], title: "Edit Data"),
        ]),
        arrange("chartDesign"),
    ])

    static let smartArtDesign = RibbonTab(id: "smartArtDesign", title: "SmartArt Design", contextual: "SmartArt Design", groups: [
        g("smartArtDesign.create", "Create Graphic", fold: 3, [
            c("smartArtDesign.textPane", "view.pane", ["pane": "smartart"], title: "Text Pane", also: ["smartArt.setNodes", "smartArt.removeNode"]),
            c("smartArtDesign.addShape", "smartArt.addNode", .emptyObject, .split(nil), title: "Add Shape"),
            s("smartArtDesign.promote", "smartArt.promote"),
            s("smartArtDesign.demote", "smartArt.demote"),
            s("smartArtDesign.insertPicture", "app.smartArtPictureDialog"),
        ]),
        g("smartArtDesign.layouts", "Layouts", fold: 4, [
            c("smartArtDesign.layouts", "smartArt.layout", .emptyObject, .gallery(source: "smartArtLayouts"), title: "Layouts"),
            s("smartArtDesign.convert", "smartArt.toText", .emptyObject, .menu(nil), title: "Convert", also: ["smartArt.toShapes"]),
        ]),
        g("smartArtDesign.styles", "SmartArt Styles", fold: 5, [
            c("smartArtDesign.colors", "smartArt.colors", .emptyObject, .menu(nil), title: "Change Colors"),
            c("smartArtDesign.gallery", "smartArt.style", .emptyObject, .gallery(source: "smartArtStyles"), title: "SmartArt Styles"),
        ]),
        arrange("smartArtDesign"),
    ])

    static let playback = RibbonTab(id: "playback", title: "Playback", contextual: "Playback", groups: [
        g("playback.preview", "Preview", fold: 1, [
            c("playback.play", "media.toggle", title: "Play"),
        ]),
        g("playback.editing", "Editing", fold: 2, [
            c("playback.trim", "app.dialog", ["id": "trim"], title: "Trim"),
        ]),
        g("playback.options", "Options", fold: 3, [
            s("playback.autoplay", "media.options", .emptyObject, .check(field: "autoplay"), title: "Start Automatically"),
            s("playback.acrossSlides", "media.options", .emptyObject, .check(field: "acrossSlides"), title: "Play Across Slides"),
            s("playback.loop", "media.options", .emptyObject, .check(field: "loop"), title: "Loop until Stopped"),
            s("playback.hide", "media.options", .emptyObject, .check(field: "hide"), title: "Hide During Show"),
            s("playback.rewind", "media.options", .emptyObject, .check(field: "rewind"), title: "Rewind after Playing"),
            s("playback.fullScreen", "media.options", .emptyObject, .check(field: "fullScreen"), title: "Play Full Screen"),
            s("playback.volume", "media.options", .emptyObject, .menu(nil), title: "Volume"),
        ]),
    ])

    static let slideMaster = RibbonTab(id: "slideMaster", title: "Slide Master", contextual: "Slide Master", groups: [
        g("slideMaster.edit", "Edit Master", fold: 2, [
            c("slideMaster.insertLayout", "master.insertLayout"),
            s("slideMaster.delete", "master.deleteLayout"),
            s("slideMaster.rename", "app.dialog", ["id": "renameLayout"], title: "Rename"),
            s("slideMaster.preserve", "master.preserve", .emptyObject, .check(field: "preserve"), title: "Preserve"),
        ]),
        g("slideMaster.layout", "Master Layout", fold: 3, [
            c("slideMaster.insertPlaceholder", "master.insertPlaceholder", .emptyObject, .menu(nil), title: "Insert Placeholder"),
            s("slideMaster.title", "master.placeholders", .emptyObject, .check(field: "title"), title: "Title"),
            s("slideMaster.footers", "master.placeholders", .emptyObject, .check(field: "footers"), title: "Footers"),
        ]),
        g("slideMaster.theme", "Edit Theme", fold: 4, [
            c("slideMaster.themes", "design.theme", .emptyObject, .menu(nil), title: "Themes", also: ["app.browseThemeDialog"]),
        ]),
        g("slideMaster.background", "Background", fold: 4, [
            c("slideMaster.background", "view.pane", ["pane": "background"], title: "Background Styles"),
        ]),
        g("slideMaster.close", "Close", fold: 0, [
            c("slideMaster.close", "view.closeMaster", sizes: [.large]),
        ]),
    ])

    static let notesMaster = RibbonTab(id: "notesMaster", title: "Notes Master", contextual: "Notes Master", groups: [
        g("notesMaster.placeholders", "Placeholders", fold: 2, ["header", "slideImage", "footer", "date", "body", "pageNumber"].map {
            s("notesMaster.\($0)", "notes.placeholders", .emptyObject, .check(field: $0))
        }),
        g("notesMaster.background", "Background", fold: 3, [
            c("notesMaster.background", "view.pane", ["pane": "background"], title: "Background Styles"),
        ]),
        g("notesMaster.close", "Close", fold: 0, [
            c("notesMaster.close", "view.closeMaster", sizes: [.large]),
        ]),
    ])

    /// Handout Master (`masters.rs` `handout_master`). deckcraft's Slides Per Page is UI state with no command;
    /// R2 gives it one.
    static let handoutMaster = RibbonTab(id: "handoutMaster", title: "Handout Master", contextual: "Handout Master", groups: [
        g("handoutMaster.placeholders", "Placeholders", fold: 2, ["header", "date", "footer", "pageNumber"].map {
            s("handoutMaster.\($0)", "handout.placeholders", .emptyObject, .check(field: $0))
        }),
        g("handoutMaster.background", "Background", fold: 3, [
            c("handoutMaster.background", "view.pane", ["pane": "background"], title: "Background Styles"),
        ]),
        g("handoutMaster.close", "Close", fold: 0, [
            c("handoutMaster.close", "view.closeMaster", sizes: [.large]),
        ]),
    ])

    // MARK: Lookups

    /// The group with this id, in any tab.
    public static func group(_ id: String) -> RibbonGroup? {
        for t in tabs { if let g = t.groups.first(where: { $0.id == id }) { return g } }
        return nil
    }

    /// The control with this id, in any tab.
    public static func control(_ id: String) -> RibbonControl? {
        for t in tabs { for g in t.groups { if let c = g.controls.first(where: { $0.id == id }) { return c } } }
        return nil
    }

    /// The commands a group or a control runs; nil for an id that is neither.
    public static func commands(of id: String) -> [String]? { group(id)?.commands ?? control(id)?.commands }

    /// Every command the ribbon can run, without repeats.
    public static var commands: Set<String> { Set(tabs.flatMap { $0.groups.flatMap(\.commands) }) }
}
