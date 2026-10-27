// DCApp — the window toolbar: the ribbon's most used controls as native toolbar items (deckcraft
// `crates/ui-egui/src/ribbon.rs`: Home ▸ New Slide, Insert ▸ Shapes, Text Box, Table, Chart, Pictures, Video
// and Audio, Comment, Slide Show ▸ Play) and the Quick Access Toolbar's buttons (`qat.rs`). Split buttons
// (`split_button_tests.rs`) are `NSMenuToolbarItem`s: the button runs the main command, the arrow opens its
// menu. Every item runs a registry command; the toolbar is customisable (View ▸ Customize Toolbar…), and
// `app.qat` adds and removes command items. MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel

/// A menu item's or toolbar item's command and parameters.
final class ToolbarPayload: NSObject {
    let id: String
    let params: JSON
    init(_ id: String, _ params: JSON = .emptyObject) {
        self.id = id
        self.params = params
    }
}

/// The toolbar's target: runs a payload's command and validates items by the command's `enabled`.
@MainActor
final class ToolbarActions: NSObject, NSToolbarItemValidation, NSMenuItemValidation {
    static let shared = ToolbarActions()

    @objc func run(_ sender: Any?) {
        let payload = (sender as? NSMenuItem)?.representedObject as? ToolbarPayload
            ?? ToolbarCatalog.payloads[(sender as? NSToolbarItem)?.itemIdentifier.rawValue ?? ""]
        guard let p = payload else { return }
        ToolbarCatalog.perform(p.id, p.params)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let p = ToolbarCatalog.payloads[item.itemIdentifier.rawValue] else { return true }
        return ToolbarCatalog.enabled(p.id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let p = item.representedObject as? ToolbarPayload else { return true }
        return ToolbarCatalog.enabled(p.id)
    }
}

@MainActor
enum ToolbarCatalog {
    static let newSlide = NSToolbarItem.Identifier("dc.newSlide")
    static let shapes = NSToolbarItem.Identifier("dc.shapes")
    static let textBox = NSToolbarItem.Identifier("insert.textBox")
    static let table = NSToolbarItem.Identifier("dc.table")
    static let chart = NSToolbarItem.Identifier("dc.chart")
    static let picture = NSToolbarItem.Identifier("dc.picture")
    static let media = NSToolbarItem.Identifier("dc.media")
    static let comment = NSToolbarItem.Identifier("dc.comment")
    static let play = NSToolbarItem.Identifier("dc.play")
    static let smartArt = NSToolbarItem.Identifier("dc.smartArt")
    /// The Quick Access Toolbar: one item whose menu holds its buttons and the Customize choices.
    static let quickAccess = NSToolbarItem.Identifier("dc.quickAccess")
    static let qatPrefix = "qat:"

    /// Command items: identifier, label, SF Symbol, the main command and its parameters.
    static let commands: [(id: NSToolbarItem.Identifier, label: String, symbol: String, command: String, params: JSON)] = [
        (newSlide, String(localized: "New Slide", bundle: .module), "plus.rectangle.on.rectangle", "slide.new", .emptyObject),
        (shapes, String(localized: "Shape", bundle: .module, comment: "Toolbar item: insert a shape"), "square.on.circle", "shape.insert", ["preset": "rect"]),
        (textBox, String(localized: "Text Box", bundle: .module), "textformat", "insert.textBox", .emptyObject),
        (table, String(localized: "Table", bundle: .module), "tablecells", "insert.table", ["rows": 3, "cols": 3]),
        (chart, String(localized: "Chart", bundle: .module), "chart.bar", "insert.chart", ["type": "Column"]),
        (smartArt, String(localized: "SmartArt", bundle: .module), "rectangle.3.group", "app.dialog", ["id": "smartart"]),
        (picture, String(localized: "Picture", bundle: .module), "photo", "app.insertPictureDialog", .emptyObject),
        (media, String(localized: "Media", bundle: .module), "play.rectangle", "app.insertVideoDialog", .emptyObject),
        (comment, String(localized: "Comment", bundle: .module, comment: "Toolbar item: add a comment"), "text.bubble", "app.dialog", ["id": "comment"]),
        (play, String(localized: "Play", bundle: .module, comment: "Toolbar item: play the slide show"), "play.fill", "show.start", .emptyObject),
    ]

    /// Every item's main command, by identifier (the QAT's included).
    static var payloads: [String: ToolbarPayload] = {
        var m: [String: ToolbarPayload] = [:]
        for c in commands { m[c.id.rawValue] = ToolbarPayload(c.command, c.params) }
        return m
    }()

    static var defaultItems: [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, newSlide, .flexibleSpace, shapes, textBox, table, chart, picture, media, .flexibleSpace,
         quickAccess, comment, play, .inspectorTrackingSeparator, .toggleInspector]
    }

    static var allowedItems: [NSToolbarItem.Identifier] {
        let qat = (QAT.common + (InspectorFeature.controller?.qat ?? [])).map { NSToolbarItem.Identifier(qatPrefix + $0.identifier) }
        return defaultItems + [smartArt, .space] + qat
    }

    static func enabled(_ id: String) -> Bool {
        if id == "file.new" || id == "app.openDialog" { return true }
        if id.hasPrefix("tool.") { return AppController.shared?.model.session.activeDoc != nil }
        if UICommands.contains(id) { return AppController.shared?.model.session.activeDoc != nil || !id.hasPrefix("app.insert") }
        guard let spec = findCommand(id), let s = AppController.shared?.model.session else { return false }
        return spec.enabled(s) == nil
    }

    /// Run a toolbar command: through the app's `perform` (Save and New go through NSDocument), with the
    /// QAT's special cases (`qat::run`).
    static func perform(_ id: String, _ params: JSON) {
        guard let app = AppController.shared else { return }
        switch id {
        case "review.spelling": app.perform("app.dialog", ["id": "spelling"])
        case "tool.shape":
            // The freeform tools and Draw Table draw with the pointer: the session's tool, as deckcraft sets it.
            app.model.session.setTool(.shape(preset: params["preset"]?.asStr ?? "rect"))
            app.model.changed()
        case "tool.ink":
            // Draw ▸ Pens: the canvas's ink tool (`draw`).
            if let pen = InspectorShape.pens.at(Int(params["pen"]?.asU64 ?? 0)) {
                app.model.session.setTool(.ink(mode: pen.mode, color: pen.color, width: pen.width))
                app.model.changed()
            }
        case "tool.select":
            app.model.session.setTool(.select)
            app.model.changed()
        default: app.perform(id, params.isNull ? .emptyObject : params)
        }
    }

    static func item(_ id: NSToolbarItem.Identifier, document: PresentationDocument?) -> NSToolbarItem? {
        if id.rawValue.hasPrefix(qatPrefix) { return qatItem(id) }
        if id == quickAccess { return quickAccessItem() }
        guard let entry = commands.first(where: { $0.id == id }) else { return nil }
        let menu = self.menu(for: id)
        let item: NSToolbarItem
        if let menu {
            let m = NSMenuToolbarItem(itemIdentifier: id)
            m.menu = menu
            m.showsIndicator = true
            item = m
        } else {
            item = NSToolbarItem(itemIdentifier: id)
        }
        item.label = entry.label
        item.paletteLabel = entry.label
        item.toolTip = tip(entry.command, entry.label)
        item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.label)
        item.target = ToolbarActions.shared
        item.action = #selector(ToolbarActions.run(_:))
        return item
    }

    /// A tooltip with the command's shortcut (`ribbon::tip`).
    static func tip(_ id: String, _ label: String) -> String {
        guard let s = findCommand(id)?.shortcut ?? UICommands.find(id)?.shortcut else { return label }
        let keys = s.replacingOccurrences(of: "Cmd+", with: "⌘").replacingOccurrences(of: "Shift+", with: "⇧").replacingOccurrences(of: "Alt+", with: "⌥").replacingOccurrences(of: "Ctrl+", with: "⌃")
        return String(localized: "\(label) (\(keys))", bundle: .module, comment: "A toolbar tooltip: the command's label, then its keyboard shortcut in parentheses")
    }

    // MARK: Menus

    static func menuItem(_ title: String, _ id: String, _ params: JSON = .emptyObject, image: NSImage? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(ToolbarActions.run(_:)), keyEquivalent: "")
        m.target = ToolbarActions.shared
        m.representedObject = ToolbarPayload(id, params)
        m.image = image
        return m
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for i in items { sub.addItem(i) }
        m.submenu = sub
        return m
    }

    static func menu(for id: NSToolbarItem.Identifier) -> NSMenu? {
        let menu = NSMenu()
        switch id {
        case newSlide:
            // The layouts of the active presentation, read when the menu opens.
            menu.delegate = LayoutMenuDelegate.shared
        case shapes:
            for cat in Preset.Category.all {
                var items = Preset.catalog.filter { $0.category == cat }.map { menuItem($0.label, "shape.insert", ["preset": .string($0.name)], image: PresetIcons.image($0.name)) }
                if cat == .lines {
                    items.append(.separator())
                    items += Tools.freeformTools.map { menuItem($0.1, "tool.shape", ["preset": .string($0.0)]) }
                }
                menu.addItem(submenu(cat.label, items))
            }
            menu.addItem(.separator())
            var cats: [String] = []
            for i in Icons.icons where !cats.contains(i.category) { cats.append(i.category) }
            menu.addItem(submenu(String(localized: "Icons", bundle: .module), cats.map { c in submenu(c, Icons.icons.filter { $0.category == c }.map { menuItem($0.label, "insert.icon", ["name": .string($0.name)]) }) }))
            menu.addItem(menuItem(String(localized: "WordArt", bundle: .module), "insert.wordArt"))
            menu.addItem(.separator())
            menu.addItem(submenu(String(localized: "Action Buttons", bundle: .module), InspectorShape.actionButtons.map {
                menuItem(String(localized: "Action Button: \($0)", bundle: .module, comment: "An action button's kind follows: Home, Back, Next…"), "insert.actionButton", ["kind": .string($0)])
            }))
            menu.addItem(menuItem(String(localized: "Action Settings…", bundle: .module), "app.dialog", ["id": "action"]))
            menu.addItem(menuItem(String(localized: "Link…", bundle: .module), "app.dialog", ["id": "hyperlink"]))
            menu.addItem(.separator())
            var draw = [menuItem(String(localized: "Select", bundle: .module, comment: "The selection tool"), "tool.select")]
            draw += InspectorShape.pens.enumerated().map { menuItem($0.element.label, "tool.ink", ["pen": .integer($0.offset)]) }
            draw += [.separator(), menuItem(String(localized: "Ink to Shape", bundle: .module), "draw.inkToShape")]
            menu.addItem(submenu(String(localized: "Draw", bundle: .module, comment: "The Draw tools menu"), draw))
        case table:
            for n in [(2, 2), (3, 3), (4, 4), (3, 5), (5, 5), (8, 10)] {
                menu.addItem(menuItem(String(localized: "\(n.1)×\(n.0) Table", bundle: .module, comment: "Columns × rows"), "insert.table", ["rows": .integer(n.0), "cols": .integer(n.1)]))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "Insert Table…", bundle: .module), "app.dialog", ["id": "table"]))
            menu.addItem(menuItem(String(localized: "Draw Table", bundle: .module), "tool.shape", ["preset": .string(Tools.drawTable)]))
        case chart:
            for (i, group) in ChartMenu.types.enumerated() {
                if i > 0 { menu.addItem(.separator()) }
                for k in group { menu.addItem(menuItem(k.label, "insert.chart", ["type": .string(ChartMenu.param(k))])) }
            }
        case picture:
            menu.addItem(menuItem(String(localized: "Picture from File…", bundle: .module), "app.insertPictureDialog"))
            menu.addItem(menuItem(String(localized: "New Photo Album…", bundle: .module), "insert.photoAlbum"))
            menu.addItem(menuItem(String(localized: "Edit Photo Album…", bundle: .module), "insert.photoAlbumEdit"))
        case media:
            menu.addItem(menuItem(String(localized: "Video from File…", bundle: .module), "app.insertVideoDialog"))
            menu.addItem(menuItem(String(localized: "Audio from File…", bundle: .module), "app.insertAudioDialog"))
        case play:
            menu.addItem(menuItem(String(localized: "Play from Start", bundle: .module), "show.fromStart"))
            menu.addItem(menuItem(String(localized: "Play from Current Slide", bundle: .module), "show.fromCurrent"))
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "Presenter View", bundle: .module), "show.presenter"))
            menu.addItem(menuItem(String(localized: "Rehearse Timings", bundle: .module), "show.start", ["rehearse": true]))
            menu.addItem(menuItem(String(localized: "Set Up Slide Show…", bundle: .module), "app.dialog", ["id": "setupShow"]))
        default:
            return nil
        }
        return menu
    }

    // MARK: Quick Access Toolbar

    static func qatItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let key = String(id.rawValue.dropFirst(qatPrefix.count))
        guard let q = ((InspectorFeature.controller?.qat ?? []) + QAT.common).first(where: { $0.identifier == key }) else { return nil }
        payloads[id.rawValue] = ToolbarPayload(q.id, q.paramsJSON)
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = q.label
        item.paletteLabel = q.label
        item.toolTip = tip(q.id, q.label)
        item.image = NSImage(systemSymbolName: symbol(q.icon), accessibilityDescription: q.label)
            ?? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: q.label)
        item.target = ToolbarActions.shared
        item.action = #selector(ToolbarActions.run(_:))
        return item
    }

    /// deckcraft's icon names as SF Symbols.
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "home": "house"
        case "file": "doc"
        case "folder": "folder"
        case "save": "square.and.arrow.down"
        case "print": "printer"
        case "undo": "arrow.uturn.backward"
        case "redo": "arrow.uturn.forward"
        case "playFromStart": "play.rectangle"
        case "search": "magnifyingglass"
        case "spelling": "textformat.abc.dottedunderline"
        case "export": "square.and.arrow.up"
        case "table": "tablecells"
        case "chart": "chart.bar"
        case "picture": "photo"
        default: "ellipsis.circle"
        }
    }

    /// The Quick Access Toolbar item: its menu runs the buttons (`qat::show`) and customises them.
    static func quickAccessItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: quickAccess)
        item.label = String(localized: "Quick Access", bundle: .module)
        item.paletteLabel = String(localized: "Quick Access Toolbar", bundle: .module)
        item.toolTip = String(localized: "Quick Access Toolbar", bundle: .module)
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: String(localized: "Quick Access Toolbar", bundle: .module))
        item.showsIndicator = true
        item.menu = quickAccessMenu()
        return item
    }

    static func quickAccessMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Quick Access Toolbar", bundle: .module))
        let items = InspectorFeature.controller?.qat ?? QAT.defaults
        for q in items {
            menu.addItem(menuItem(q.label, q.id, q.paramsJSON, image: NSImage(systemSymbolName: symbol(q.icon), accessibilityDescription: q.label)))
        }
        menu.addItem(.separator())
        // Customize: the common commands as checkboxes, the others added, and Reset (`qat::show`'s menu).
        var custom: [NSMenuItem] = []
        for c in QAT.common {
            let on = items.contains { $0.same(c.id, .null) }
            let m = menuItem(c.label, "app.qat", [on ? "remove" : "add": .string(c.id)])
            m.state = on ? .on : .off
            custom.append(m)
        }
        let extra = items.filter { q in !QAT.common.contains { q.same($0.id, .null) } }
        if !extra.isEmpty {
            custom.append(.separator())
            for q in extra {
                let m = menuItem(q.label, "app.qat", ["remove": .string(q.id), "params": q.paramsJSON])
                m.state = .on
                custom.append(m)
            }
        }
        custom.append(.separator())
        custom.append(menuItem(String(localized: "Reset to Defaults", bundle: .module), "app.qat", ["reset": true]))
        menu.addItem(submenu(String(localized: "Customize Quick Access Toolbar", bundle: .module), custom))
        return menu
    }

    /// After `app.qat`: every window's Quick Access item gets the new buttons.
    static func syncQAT() {
        for w in NSApp.windows {
            for item in w.toolbar?.items ?? [] where item.itemIdentifier == quickAccess {
                (item as? NSMenuToolbarItem)?.menu = quickAccessMenu()
            }
        }
    }
}

/// New Slide's menu: the active presentation's layouts (`layout_menu`), Duplicate, Reuse Slides.
@MainActor
final class LayoutMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = LayoutMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let layouts = AppController.shared?.model.session.activeDoc?.doc.masters.first?.layouts ?? []
        for l in layouts { menu.addItem(ToolbarCatalog.menuItem(l.name, "slide.new", ["layout": .integer(l.id.rawValue)])) }
        menu.addItem(.separator())
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Duplicate Selected Slides", bundle: .module), "slide.duplicate"))
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Slides from Outline…", bundle: .module), "app.dialog", ["id": "outline"]))
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Reuse Slides…", bundle: .module), "app.reuseSlidesDialog", ["keepFormatting": false]))
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Reuse Slides (Keep Source Formatting)…", bundle: .module), "app.reuseSlidesDialog", ["keepFormatting": true]))
        menu.addItem(.separator())
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Add Section", bundle: .module), "section.add"))
        menu.addItem(ToolbarCatalog.menuItem(String(localized: "Remove All Sections", bundle: .module), "section.removeAll"))
    }
}
