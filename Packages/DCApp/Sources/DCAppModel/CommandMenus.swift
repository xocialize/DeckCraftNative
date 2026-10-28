// DCAppModel — the menus behind the split controls, as data: what the toolbar's split items open today and the
// ribbon's split buttons will open (Docs/plans/Ribbon-and-StartScreen.md §4). Ports deckcraft
// `crates/ui-egui/src/ribbon/{home,insert,draw,slide_show}.rs`' menus (`new_slide_menu`, `section_menu`,
// `shapes_gallery`, `table_grid_picker`, `chart_menu_types`, `photo_album_button`, the Draw pens) and
// `split_button_tests.rs`' rule that every split item has a main command and a menu. MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors. No AppKit: DCApp turns the entries into NSMenus.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation

/// A command and its parameters (deckcraft's, unchanged).
public struct CommandRef: Sendable, Equatable {
    public var id: String
    public var params: JSON
    public init(_ id: String, _ params: JSON = .emptyObject) {
        self.id = id
        self.params = params
    }
}

/// One entry of a command menu.
public indirect enum CommandMenuEntry: Sendable, Equatable {
    /// A titled item that runs a command; `preset` names the preset shape whose outline is its icon.
    case item(String, CommandRef, preset: String? = nil)
    case separator
    case submenu(String, [CommandMenuEntry])

    static func item(_ title: String, _ id: String, _ params: JSON = .emptyObject) -> CommandMenuEntry { .item(title, CommandRef(id, params)) }

    /// Every command the entry and its submenus run, in order, with repeats.
    var commands: [String] {
        switch self {
        case .item(_, let c, _): [c.id]
        case .separator: []
        case .submenu(_, let items): items.flatMap(\.commands)
        }
    }
}

/// The chart types of Insert Chart and Change Chart Type (`chart_menu_types`): the main ones, then the
/// Office 2016 types not already listed.
public enum ChartMenu {
    public static var types: [[ChartType]] { [ChartType.main, ChartType.office2016.filter { !ChartType.main.contains($0) }] }
    /// Rust's `{:?}` of the type, the parameter deckcraft passes.
    public static func param(_ k: ChartType) -> String { k.rawValue.prefix(1).uppercased() + k.rawValue.dropFirst() }
}

public enum CommandMenus {
    /// The menus that split controls open. The toolbar's split items use all of them.
    public enum ID: String, CaseIterable, Sendable {
        case newSlide, shapes, table, chart, picture, media, play
    }

    /// The menu's entries. New Slide's lists the active presentation's layouts first, so it is built when it opens.
    public static func entries(_ id: ID, layouts: [Layout] = []) -> [CommandMenuEntry] {
        switch id {
        case .newSlide: newSlide(layouts)
        case .shapes: shapes
        case .table: table
        case .chart: chart
        case .picture: picture
        case .media: media
        case .play: play
        }
    }

    /// Every command the menu can run, in order, without repeats.
    public static func commands(_ id: ID) -> [String] {
        var seen: [String] = []
        for c in entries(id, layouts: [Layout()]).flatMap(\.commands) where !seen.contains(c) { seen.append(c) }
        return seen
    }

    /// New Slide's menu: the layouts (`layout_menu`), Duplicate, Slides from Outline, Reuse Slides, sections.
    static func newSlide(_ layouts: [Layout]) -> [CommandMenuEntry] {
        layouts.map { .item($0.name, "slide.new", ["layout": .integer($0.id.rawValue)]) } + [
            .separator,
            .item(String(localized: "Duplicate Selected Slides", bundle: .module), "slide.duplicate"),
            .item(String(localized: "Slides from Outline…", bundle: .module), "app.dialog", ["id": "outline"]),
            .item(String(localized: "Reuse Slides…", bundle: .module), "app.reuseSlidesDialog", ["keepFormatting": false]),
            .item(String(localized: "Reuse Slides (Keep Source Formatting)…", bundle: .module), "app.reuseSlidesDialog", ["keepFormatting": true]),
            .separator,
            .item(String(localized: "Add Section", bundle: .module), "section.add"),
            .item(String(localized: "Remove All Sections", bundle: .module), "section.removeAll"),
        ]
    }

    /// The shapes gallery by category with the freeform tools, Icons, WordArt, Action Buttons, links and Draw.
    static var shapes: [CommandMenuEntry] {
        var out: [CommandMenuEntry] = []
        for cat in Preset.Category.all {
            var items: [CommandMenuEntry] = Preset.catalog.filter { $0.category == cat }.map { .item($0.label, CommandRef("shape.insert", ["preset": .string($0.name)]), preset: $0.name) }
            if cat == .lines {
                items.append(.separator)
                items += Tools.freeformTools.map { .item($0.1, "tool.shape", ["preset": .string($0.0)]) }
            }
            out.append(.submenu(cat.label, items))
        }
        out.append(.separator)
        var cats: [String] = []
        for i in Icons.icons where !cats.contains(i.category) { cats.append(i.category) }
        out.append(.submenu(String(localized: "Icons", bundle: .module), cats.map { c in
            .submenu(c, Icons.icons.filter { $0.category == c }.map { .item($0.label, "insert.icon", ["name": .string($0.name)]) })
        }))
        out.append(.item(String(localized: "WordArt", bundle: .module), "insert.wordArt"))
        out.append(.separator)
        out.append(.submenu(String(localized: "Action Buttons", bundle: .module), InspectorShape.actionButtons.map {
            .item(String(localized: "Action Button: \($0)", bundle: .module, comment: "An action button's kind follows: Home, Back, Next…"), "insert.actionButton", ["kind": .string($0)])
        }))
        out.append(.item(String(localized: "Action Settings…", bundle: .module), "app.dialog", ["id": "action"]))
        out.append(.item(String(localized: "Link…", bundle: .module), "app.dialog", ["id": "hyperlink"]))
        out.append(.separator)
        var draw: [CommandMenuEntry] = [.item(String(localized: "Select", bundle: .module, comment: "The selection tool"), "tool.select")]
        draw += InspectorShape.pens.enumerated().map { .item($0.element.label, "tool.ink", ["pen": .integer($0.offset)]) }
        draw += [.separator, .item(String(localized: "Ink to Shape", bundle: .module), "draw.inkToShape")]
        out.append(.submenu(String(localized: "Draw", bundle: .module, comment: "The Draw tools menu"), draw))
        return out
    }

    /// Table sizes, Insert Table…, Draw Table (`table_grid_picker`).
    static var table: [CommandMenuEntry] {
        [(2, 2), (3, 3), (4, 4), (3, 5), (5, 5), (8, 10)].map {
            .item(String(localized: "\($0.1)×\($0.0) Table", bundle: .module, comment: "Columns × rows"), "insert.table", ["rows": .integer($0.0), "cols": .integer($0.1)])
        } + [
            .separator,
            .item(String(localized: "Insert Table…", bundle: .module), "app.dialog", ["id": "table"]),
            .item(String(localized: "Draw Table", bundle: .module), "tool.shape", ["preset": .string(Tools.drawTable)]),
        ]
    }

    static var chart: [CommandMenuEntry] {
        var out: [CommandMenuEntry] = []
        for (i, group) in ChartMenu.types.enumerated() {
            if i > 0 { out.append(.separator) }
            out += group.map { .item($0.label, "insert.chart", ["type": .string(ChartMenu.param($0))]) }
        }
        return out
    }

    static var picture: [CommandMenuEntry] {
        [
            .item(String(localized: "Picture from File…", bundle: .module), "app.insertPictureDialog"),
            .item(String(localized: "New Photo Album…", bundle: .module), "insert.photoAlbum"),
            .item(String(localized: "Edit Photo Album…", bundle: .module), "insert.photoAlbumEdit"),
        ]
    }

    static var media: [CommandMenuEntry] {
        [
            .item(String(localized: "Video from File…", bundle: .module), "app.insertVideoDialog"),
            .item(String(localized: "Audio from File…", bundle: .module), "app.insertAudioDialog"),
        ]
    }

    static var play: [CommandMenuEntry] {
        [
            .item(String(localized: "Play from Start", bundle: .module), "show.fromStart"),
            .item(String(localized: "Play from Current Slide", bundle: .module), "show.fromCurrent"),
            .separator,
            .item(String(localized: "Presenter View", bundle: .module), "show.presenter"),
            .item(String(localized: "Rehearse Timings", bundle: .module), "show.start", ["rehearse": true]),
            .item(String(localized: "Set Up Slide Show…", bundle: .module), "app.dialog", ["id": "setupShow"]),
        ]
    }
}
