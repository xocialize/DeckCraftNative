// DCAppTests — R1 of Docs/plans/Ribbon-and-StartScreen.md in a window: switching a document window between the Mac
// layout and the ribbon layout (the ribbon above the split view, the ribbon toolbar with the Quick Access Toolbar at
// its leading edge), the ribbon drawing every tab, its symbols, and the toolbar's tooltip descriptions.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import SwiftUI
import Testing
@testable import DCApp

@MainActor
@Suite struct RibbonWindowTests {
    @MainActor struct Fixture {
        let app: AppController
        let doc: PresentationDocument
        let wc: DocumentWindowController
        var model: AppModel { app.model }

        init() {
            _ = NSApplication.shared
            app = AppController()
            app.syncSuspended += 1
            app.model.ui = UiState()
            app.model.run("file.new")
            app.model.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
            doc = PresentationDocument(adopting: app.model.session.activeDoc?.uid ?? 0)
            wc = DocumentWindowController(document: doc)
            wc.window?.isReleasedWhenClosed = false
        }

        func layout(_ ribbon: Bool) {
            model.run("view.ribbon", ["on": .bool(ribbon)])
            RibbonFeature.apply(wc)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // R1: switching layouts keeps the document, the selection and the undo stack; the window gets the ribbon and
    // the ribbon toolbar, and gets its own back.
    @Test func switchingTheLayoutSwapsTheRibbonAndTheToolbar() throws {
        let f = Fixture()
        let window = try #require(f.wc.window)
        #expect(window.contentViewController === f.wc.split)
        #expect(window.toolbar?.identifier == "DeckCraftDocument")
        let doc = try #require(f.model.session.activeDoc)
        let (selection, undo) = (doc.selection, doc.history.undo.count)

        f.layout(true)
        let container = try #require(window.contentViewController as? RibbonContainerController)
        #expect(container.split === f.wc.split && f.wc.split.parent === container)
        #expect(window.toolbar?.identifier == "DeckCraftRibbon")
        #expect(window.titleVisibility == .hidden)
        let ids = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        // The Quick Access Toolbar's buttons come first, then the title, then Search, Present and Comments.
        let qat = (InspectorFeature.controller?.qat ?? QAT.defaults).map { ToolbarCatalog.qatPrefix + $0.identifier }
        #expect(Array(ids.prefix(qat.count)) == qat)
        #expect(ids.suffix(3) == ["dc.ribbon.search", "dc.ribbon.present", "dc.ribbon.comments"])
        #expect(ids.contains("dc.ribbon.title"))
        // The inspector is the task pane, closed until a pane is asked for.
        #expect(f.wc.split.splitViewItems.last?.isCollapsed == true)
        #expect(container.host.frame.height == RibbonView.height(collapsed: false))

        f.model.run("view.collapseRibbon")
        RibbonFeature.apply(f.wc)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(container.host.frame.height == RibbonView.height(collapsed: true))
        f.model.run("view.collapseRibbon")

        f.layout(false)
        #expect(window.contentViewController === f.wc.split && f.wc.ribbon == nil)
        #expect(window.toolbar?.identifier == "DeckCraftDocument")
        #expect(window.titleVisibility == .visible)
        let after = try #require(f.model.session.activeDoc)
        #expect(after.selection == selection && after.history.undo.count == undo)
        // Again, to be sure the split view moves back and forth cleanly.
        f.layout(true)
        f.layout(false)
        #expect(window.contentViewController === f.wc.split)
    }

    @Test func theRibbonDrawsEveryTab() throws {
        let f = Fixture()
        f.layout(true)
        let container = try #require(f.wc.window?.contentViewController as? RibbonContainerController)
        for tab in RibbonModel.tabs {
            f.model.run("view.tab", ["tab": .string(tab.title)])
            container.host.rootView = RibbonView(model: f.model)
            container.host.layoutSubtreeIfNeeded()
            #expect(RibbonModel.selected(f.model.ui).id == tab.id)
            let fmt = RibbonModel.formatState(f.model.session)
            for g in tab.groups {
                let v = NSHostingView(rootView: RibbonGroupView(group: g, model: f.model, fmt: fmt))
                #expect(v.fittingSize.width > 30 && v.fittingSize.height <= RibbonView.bodyHeight, "\(g.id) draws its controls")
            }
        }
        f.layout(false)
    }

    @Test func everyRibbonSymbolIsAnSFSymbol() {
        var missing: [String] = []
        for tab in RibbonModel.tabs {
            for g in tab.groups {
                for c in g.controls where NSImage(systemSymbolName: RibbonModel.symbol(c), accessibilityDescription: nil) == nil {
                    missing.append("\(c.id): \(RibbonModel.symbol(c))")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing)")
        for e in RibbonToolbar.commands { #expect(NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil) != nil) }
    }

    // Decision 3: the toolbar's items, in either layout, describe what they do.
    @Test func toolbarTooltipsHaveDescriptions() {
        for c in ToolbarCatalog.commands {
            #expect(CommandHelp.description(CommandRef(c.command, c.params)) != nil, "\(c.id.rawValue)")
            #expect(ToolbarCatalog.item(c.id, document: nil)?.toolTip?.contains("\n") == true, "\(c.id.rawValue)")
        }
        for e in RibbonToolbar.commands { #expect(CommandHelp.description(CommandRef(e.command, e.params)) != nil, "\(e.id.rawValue)") }
        #expect(ToolbarCatalog.tooltip("format.bold", .emptyObject, "Bold") == "Bold (⌘B)\nMake the selected text bold.")
        // View › Ribbon is a menu item with PowerPoint for Mac's shortcut.
        #expect(MenuBuilder.shortcut(for: "view.ribbon").flatMap(MenuBuilder.keyEquivalent)?.0 == "r")
    }
}
