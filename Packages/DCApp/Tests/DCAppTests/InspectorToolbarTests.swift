// DCAppTests — the toolbar's items and menus, and the inspector's catalogues against the registry. Ports the
// behaviour of deckcraft `crates/ui-egui/src/split_button_tests.rs` (a split control's main half runs its
// command and its arrow opens its menu: on the Mac, `NSMenuToolbarItem`) and checks every ribbon group's
// commands (`ribbon.rs`) and the pattern gallery (`pattern_fill_tests.rs`) against the engine.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCRender
import Testing
@testable import DCApp

@MainActor
@Suite struct InspectorToolbarTests {
    /// Every command a toolbar item or menu item runs, with the items' titles.
    static func payloads(_ menu: NSMenu?) -> [(String, String)] {
        guard let menu else { return [] }
        var out: [(String, String)] = []
        for i in menu.items {
            if let p = i.representedObject as? ToolbarPayload { out.append((i.title, p.id)) }
            out += payloads(i.submenu)
        }
        return out
    }

    static func known(_ id: String) -> Bool { findCommand(id) != nil || UICommands.contains(id) || id.hasPrefix("tool.") }

    // split_button_tests.rs: the split controls — the main half runs a command, the arrow opens a menu.
    @Test func splitToolbarItemsHaveAMainCommandAndAMenu() {
        for id in [ToolbarCatalog.newSlide, ToolbarCatalog.shapes, ToolbarCatalog.table, ToolbarCatalog.chart, ToolbarCatalog.picture, ToolbarCatalog.media, ToolbarCatalog.play] {
            let item = ToolbarCatalog.item(id, document: nil)
            #expect(item is NSMenuToolbarItem, "\(id.rawValue) is a split button")
            #expect(item?.action == #selector(ToolbarActions.run(_:)), "\(id.rawValue)'s main half runs its command")
            let main = ToolbarCatalog.payloads[id.rawValue]?.id ?? ""
            #expect(Self.known(main), "\(id.rawValue): \(main)")
        }
        #expect(!(ToolbarCatalog.item(ToolbarCatalog.textBox, document: nil) is NSMenuToolbarItem))
        #expect(ToolbarCatalog.item(NSToolbarItem.Identifier("no.such"), document: nil) == nil)
    }

    @Test func everyToolbarMenuItemRunsAKnownCommand() {
        for id in [ToolbarCatalog.shapes, ToolbarCatalog.table, ToolbarCatalog.chart, ToolbarCatalog.picture, ToolbarCatalog.media, ToolbarCatalog.play] {
            let items = Self.payloads(ToolbarCatalog.menu(for: id))
            #expect(!items.isEmpty, "\(id.rawValue)")
            for (title, cmd) in items { #expect(Self.known(cmd), "\(id.rawValue) ▸ \(title): \(cmd)") }
        }
        let shapes = Self.payloads(ToolbarCatalog.menu(for: ToolbarCatalog.shapes))
        #expect(shapes.contains { $0.0 == "Rectangle" && $0.1 == "shape.insert" })
        #expect(shapes.filter { $0.1 == "insert.icon" }.count == Icons.icons.count)
        let charts = Self.payloads(ToolbarCatalog.menu(for: ToolbarCatalog.chart))
        #expect(charts.count == ChartMenu.types.joined().count)
    }

    @Test func toolbarIdentifiersAndQuickAccessItems() {
        let defaults = ToolbarCatalog.defaultItems
        #expect(defaults.contains(.toggleInspector) && defaults.contains(.inspectorTrackingSeparator))
        #expect(Set(defaults).isSubset(of: Set(ToolbarCatalog.allowedItems)))
        let qat = QAT.common.map { NSToolbarItem.Identifier(ToolbarCatalog.qatPrefix + $0.identifier) }
        #expect(Set(qat).isSubset(of: Set(ToolbarCatalog.allowedItems)))
        let save = ToolbarCatalog.qatItem(NSToolbarItem.Identifier(ToolbarCatalog.qatPrefix + "file.save"))
        #expect(save?.label == "Save")
        #expect(ToolbarCatalog.payloads[ToolbarCatalog.qatPrefix + "file.save"]?.id == "file.save")
        #expect(ToolbarCatalog.tip("format.bold", "Bold") == "Bold (⌘B)")
        // The Quick Access item's menu: the buttons, then Customize with the common commands ticked.
        let qa = Self.payloads(ToolbarCatalog.quickAccessMenu())
        #expect(Array(qa.prefix(QAT.defaults.count)).map(\.1) == QAT.defaults.map(\.id))
        #expect(qa.filter { $0.1 == "app.qat" }.count == QAT.common.count + 1)
        #expect(ToolbarCatalog.item(ToolbarCatalog.quickAccess, document: nil) is NSMenuToolbarItem)
        #expect(ChartMenu.param(.stackedColumn) == "StackedColumn")
    }

    /// The items look as they did before their symbols and menus moved into DCAppModel (`CommandSymbols`,
    /// `CommandMenus`): the same SF Symbols, and New Slide's menu still built from the presentation's layouts.
    @Test func toolbarSymbolsAndMenusAreUnchanged() {
        let expected: [NSToolbarItem.Identifier: String] = [
            ToolbarCatalog.newSlide: "plus.rectangle.on.rectangle", ToolbarCatalog.shapes: "square.on.circle", ToolbarCatalog.textBox: "textformat",
            ToolbarCatalog.table: "tablecells", ToolbarCatalog.chart: "chart.bar", ToolbarCatalog.smartArt: "rectangle.3.group",
            ToolbarCatalog.picture: "photo", ToolbarCatalog.media: "play.rectangle", ToolbarCatalog.comment: "text.bubble", ToolbarCatalog.play: "play.fill",
        ]
        for c in ToolbarCatalog.commands { #expect(ToolbarCatalog.symbol(c.command, c.params) == expected[c.id], "\(c.id.rawValue)") }
        #expect(ToolbarCatalog.commands.count == expected.count)
        #expect(ToolbarCatalog.menu(for: ToolbarCatalog.newSlide)?.delegate === LayoutMenuDelegate.shared)
        let menu = NSMenu()
        LayoutMenuDelegate.shared.menuNeedsUpdate(menu)
        #expect(Self.payloads(menu).map(\.1).suffix(6) == ["slide.duplicate", "app.dialog", "app.reuseSlidesDialog", "app.reuseSlidesDialog", "section.add", "section.removeAll"])
        let play = Self.payloads(ToolbarCatalog.menu(for: ToolbarCatalog.play)).map(\.0)
        #expect(play == ["Play from Start", "Play from Current Slide", "Presenter View", "Rehearse Timings", "Set Up Slide Show…"])
    }

    // pattern_fill_tests.rs: every gallery preset is one DCRender draws.
    @Test func patternGalleryPresetsAreDrawable() {
        for name in InspectorFill.patternGallery { #expect(Pattern.presets.contains(name), "\(name)") }
    }

    // ribbon.rs: every group of the ribbon has a place on the Mac, and its commands are the registry's.
    @Test func everyRibbonGroupMapsToKnownCommands() {
        let tabs = Set(RibbonMap.groups.map(\.tab))
        for t in ["Home", "Insert", "Draw", "Design", "Transitions", "Animations", "Slide Show", "Record", "Review", "View",
                  "Shape Format", "Picture Format", "Table Design", "Layout", "Chart Design", "SmartArt Design", "Playback",
                  "Slide Master", "Notes Master", "Handout Master"] {
            #expect(tabs.contains(t), "\(t) is mapped")
        }
        for g in RibbonMap.groups {
            #expect(!g.place.isEmpty)
            for c in g.commands { #expect(Self.known(c), "\(g.tab) ▸ \(g.group): \(c)") }
        }
    }
}
