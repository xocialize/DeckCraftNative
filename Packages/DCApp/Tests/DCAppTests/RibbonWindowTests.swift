// DCAppTests — R1 to R3 of Docs/plans/Ribbon-and-StartScreen.md in a window: switching a document window between the
// Mac layout and the ribbon layout (the ribbon above the split view, the ribbon toolbar with the Quick Access Toolbar
// at its leading edge), the ribbon drawing every tab, its symbols, the toolbar's tooltip descriptions, and every tab
// folding cleanly at the four widths.
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
        // The Quick Access Toolbar's buttons come first, then the title, then Search, Present, Comments and Share.
        let qat = (InspectorFeature.controller?.qat ?? QAT.defaults).map { ToolbarCatalog.qatPrefix + $0.identifier }
        #expect(Array(ids.prefix(qat.count)) == qat)
        #expect(ids.suffix(4) == ["dc.ribbon.search", "dc.ribbon.present", "dc.ribbon.comments", "dc.ribbon.share"])
        #expect(ids.contains("dc.ribbon.title"))
        // Share hands over the saved file, so an unsaved presentation has nothing to share yet.
        let share = try #require(window.toolbar?.items.first { $0.itemIdentifier == RibbonToolbar.share })
        share.validate()
        #expect(!share.isEnabled && share.view?.accessibilityLabel() == "Share")
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
        for tab in RibbonModel.tabs(f.model) {
            f.model.run("view.tab", ["tab": .string(tab.title)])
            container.host.rootView = RibbonView(model: f.model)
            container.host.layoutSubtreeIfNeeded()
            #expect(RibbonModel.selected(f.model).id == tab.id)
            let fmt = RibbonModel.formatState(f.model.session)
            for g in tab.groups {
                let v = NSHostingView(rootView: RibbonGroupView(group: g, model: f.model, fmt: fmt))
                #expect(v.fittingSize.width > 30 && v.fittingSize.height <= RibbonView.bodyHeight, "\(g.id) draws its controls")
            }
        }
        f.layout(false)
    }

    // R2: with each kind of object selected, its contextual tabs are in the tab row, tinted, and every group draws;
    // the galleries draw their tiles and the "›" button.
    @Test func theContextualTabsDraw() throws {
        let f = Fixture()
        f.layout(true)
        let container = try #require(f.wc.window?.contentViewController as? RibbonContainerController)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let inserts: [(String, JSON)] = [
            ("shape.insert", ["preset": "rect", "rect": [300, 100, 100, 100]]), ("insert.picture", ["data": .string(png), "name": "dot.png"]),
            ("insert.table", ["rows": 2, "cols": 2]), ("insert.chart", ["type": "Column"]),
            ("insert.smartArt", ["kind": "process", "items": ["Plan", "Build"]]),
            ("insert.audio", ["data": .string(Cmd.base64Encode(Self.wav)), "name": "tone.wav"]),
        ]
        var seen = Set<String>()
        for (id, params) in inserts {
            f.model.run(id, params)
            let tabs = RibbonModel.tabs(f.model).filter { $0.contextual != nil }
            #expect(!tabs.isEmpty, "\(id) brings a contextual tab")
            for tab in tabs {
                seen.insert(tab.id)
                f.model.run("view.tab", ["tab": .string(tab.title)])
                container.host.rootView = RibbonView(model: f.model)
                container.host.layoutSubtreeIfNeeded()
                #expect(RibbonModel.selected(f.model).id == tab.id)
                let fmt = RibbonModel.formatState(f.model.session)
                for g in tab.groups {
                    let v = NSHostingView(rootView: RibbonGroupView(group: g, model: f.model, fmt: fmt))
                    #expect(v.fittingSize.width > 30 && v.fittingSize.height <= RibbonView.bodyHeight, "\(g.id) draws its controls")
                }
            }
        }
        #expect(seen.isSuperset(of: ["shapeFormat", "pictureFormat", "tableDesign", "tableLayout", "chartDesign", "smartArtDesign", "playback"]), "\(seen)")
        // Nothing selected: the contextual tab gives way to Home.
        f.model.run("edit.select", ["ids": []])
        #expect(RibbonModel.selected(f.model).id == "home")
        f.layout(false)
    }

    /// A short silent WAV: 8 kHz, 8-bit mono.
    static var wav: [UInt8] {
        let n: UInt32 = 800
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        return Array("RIFF".utf8) + le32(36 + n) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(8000)
            + le16(1) + le16(8) + Array("data".utf8) + le32(n) + [UInt8](repeating: 128, count: Int(n))
    }

    // The "›" button's whole gallery, by category, and the Shapes grid draw for every source.
    @Test func expandedGalleriesDraw() throws {
        let f = Fixture()
        f.model.run("insert.smartArt", ["kind": "process", "items": ["Plan", "Build"]])
        for source in RibbonGalleries.sources {
            let g = try #require(RibbonGalleries.gallery(source, f.model))
            let v = NSHostingView(rootView: RibbonGalleryGrid(gallery: g, model: f.model) {})
            #expect(v.fittingSize.width >= 400 && v.fittingSize.height > 40, "\(source)")
            let control = try #require(RibbonModel.allTabs.flatMap { $0.groups.flatMap(\.controls) }.first { $0.kind == .gallery(source: source) }, "\(source)")
            let strip = NSHostingView(rootView: RibbonGalleryView(control: control, model: f.model, enabled: true))
            #expect(strip.fittingSize.height <= RibbonView.bodyHeight && strip.fittingSize.width > 60, "\(source) inline")
        }
        let shapes = NSHostingView(rootView: RibbonShapesGrid(entries: CommandMenus.entries(.shapes), model: f.model) {})
        #expect(shapes.fittingSize.width >= 300 && shapes.fittingSize.height > 100)
    }

    /// Lay the window's ribbon out at `width` and let SwiftUI report where it drew.
    static func settle(_ f: Fixture, _ container: RibbonContainerController, width: CGFloat) {
        f.wc.window?.setContentSize(NSSize(width: width, height: 700))
        for _ in 0 ..< 4 {
            f.wc.window?.contentView?.layoutSubtreeIfNeeded()
            container.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // R3: every tab, the contextual ones with their object selected, lays out at 1600, 1150, 920 and 700 points with
    // nothing clipped or overlapping; the selected tab stays in the tab row; Paste and Designer stay large.
    @Test func everyTabFoldsCleanlyAtTheFourWidths() throws {
        let f = Fixture()
        f.layout(true)
        let container = try #require(f.wc.window?.contentViewController as? RibbonContainerController)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let objects: [(String, JSON)] = [
            ("shape.insert", ["preset": "rect", "rect": [300, 100, 100, 100]]), ("insert.picture", ["data": .string(png), "name": "dot.png"]),
            ("insert.table", ["rows": 2, "cols": 2]), ("insert.chart", ["type": "Column"]),
            ("insert.smartArt", ["kind": "process", "items": ["Plan", "Build"]]),
            ("insert.audio", ["data": .string(Cmd.base64Encode(Self.wav)), "name": "tone.wav"]),
        ]
        var checked = Set<String>()
        func check(_ tabs: [RibbonTab]) {
            for tab in tabs where !checked.contains(tab.id) {
                checked.insert(tab.id)
                f.model.run("view.tab", ["tab": .string(tab.title)])
                for w in [1600.0, 1150, 920, 700] as [CGFloat] {
                    Self.settle(f, container, width: w)
                    let st = container.state
                    let fit = RibbonMeasure.fit(tab, f.model, width: st.width)
                    #expect(abs(st.width - w) < 1, "\(tab.id) at \(w): the ribbon is \(st.width) wide")
                    #expect(RibbonFeature.truncated(tab, fit, st, body: true) == [], "\(tab.id) at \(w)")
                    #expect(st.tabsShown.contains(tab.id), "\(tab.id) at \(w) went into »")
                    #expect(fit.sizes["home.designer"] ?? .large == .large && fit.sizes["design.designer"] ?? .large == .large)
                }
            }
        }
        check(RibbonModel.tabs(f.model))
        for (id, p) in objects {
            f.model.run(id, p)
            check(RibbonModel.tabs(f.model).filter { $0.contextual != nil })
        }
        for m in ["view.slideMaster", "view.notesMaster", "view.handoutMaster"] {
            f.model.run(m)
            check(RibbonModel.tabs(f.model).filter { $0.contextual != nil })
            f.model.run("view.closeMaster")
        }
        #expect(checked.count == RibbonModel.allTabs.count, "\(Set(RibbonModel.allTabs.map(\.id)).subtracting(checked))")
        f.layout(false)
    }

    // The keys the container takes before the focused control sees them: AppKit's split, menu and borderless buttons
    // kept the arrows, Return and Esc from SwiftUI, so the keyboard stuck on Paste (0.1.4). With the keyboard's own
    // flags: the arrows carry function and numeric pad. Other modifiers leave the key to the app.
    @Test func theRibbonsKeysAreTakenWithTheirModifiers() throws {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> RibbonKey? {
            let arrow = (123 ... 126).contains(code)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(arrow ? [.function, .numericPad] : []),
                                     timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code)
            return e.flatMap(RibbonContainerController.key(for:))
        }
        #expect(key(123) == .left && key(124) == .right && key(126) == .up && key(125) == .down)
        #expect(key(125, .option) == .optionDown)
        #expect(key(36) == .activate && key(76) == .activate && key(53) == .escape)
        #expect(key(123, .shift) == nil && key(124, .command) == nil && key(126, .option) == nil, "the app's own shortcuts")
        #expect(key(97) == nil && key(49) == nil, "F6 is the menu's; Space is the button's")
    }

    @Test func everyRibbonSymbolIsAnSFSymbol() {
        var missing: [String] = []
        for tab in RibbonModel.allTabs {
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
