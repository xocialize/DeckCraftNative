// DCAppTests — the dialogs in the app, in-process: the UI commands and engine requests reach the dialog
// controller, the control channel's `ui.dialog.*` methods and `ui.inspect`'s `dialog` key drive and report
// it, every dialog's SwiftUI form lays out, Settings and About show in windows of their own, and the menu
// items the dialogs add are there. Behaviour from deckcraft `crates/ui-egui/src/control.rs` (`ui.dialog.open`,
// `ui.dialog.close`, `inspect`) and `dialogs.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import DCModel
import Foundation
import SwiftUI
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct DialogsWindowTests {
    /// An app with one presentation and a selected rectangle; documents aren't synced to windows.
    func app() throws -> (AppController, DialogController) {
        _ = NSApplication.shared
        let app = AppController()
        app.syncSuspended += 1
        app.model.run("file.new")
        app.model.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100], "text": "Hi"])
        app.model.run("text.exit")
        return (app, try #require(DialogsFeature.controller))
    }

    func call(_ app: AppController, _ method: String, _ p: JSON = .emptyObject) -> JSON {
        guard let h = app.controlHandlers[method], case .done(let v) = h(p) else { return .null }
        return v
    }

    // control.rs: `ui.dialog.open {id, fields}`, `ui.dialog.close`, and `inspect`'s `dialog`
    @Test func controlChannelOpensDrivesAndClosesADialog() throws {
        let (app, dialogs) = try app()
        #expect(app.inspectors["dialog"]?() == .null)
        let opened = call(app, "ui.dialog.open", ["id": "table", "fields": ["rows": "3", "cols": 4]])
        #expect(opened["ok"] == true)
        #expect(app.inspectors["dialog"]?() == "table")
        #expect(dialogs.current?.value("rows") == "3")
        #expect(dialogs.current?.value("cols") == "4", "a number field is taken as its text")
        let got = call(app, "ui.dialog.get")["result"]
        #expect(got?["title"] == "Insert Table")
        #expect(got?["buttons"]?.asArray?.compactMap { $0["id"]?.asStr } == ["cancel", "ok"])
        _ = call(app, "ui.dialog.set", ["fields": ["cols": "2"]])
        let pressed = call(app, "ui.dialog.press", ["button": "ok"])
        #expect(pressed["ok"] == true)
        #expect(dialogs.current == nil)
        let t = app.model.session.activeDoc?.currentSlide?.shapes.compactMap { sh -> DCModel.Table? in if case .table(let t) = sh.kind { return t }; return nil }.first
        #expect(t?.rows.count == 3 && t?.cols.count == 2)
        #expect(call(app, "ui.dialog.press", ["button": "ok"])["ok"] == false, "nothing is open")
        _ = call(app, "ui.dialog.open", ["id": "zoom"])
        _ = call(app, "ui.dialog.close")
        #expect(dialogs.current == nil)
        let list = call(app, "ui.dialog.list")["result"]
        #expect(list?["ids"]?.asArray?.count == DialogCatalog.ids.count)
    }

    @Test func uiCommandsAndEngineRequestsOpenDialogs() throws {
        let (app, dialogs) = try app()
        app.model.run("app.dialog", ["id": "hyperlink"])
        #expect(dialogs.current?.id == "hyperlink")
        app.model.run("format.fontDialog")
        #expect(dialogs.current?.id == "font", "the engine's dialog request reaches the controller")
        app.model.run("app.about")
        #expect(dialogs.current?.id == "about")
        app.model.run("app.palette")
        #expect(dialogs.palette != nil)
        dialogs.palette = nil
        dialogs.cancel()
        dialogs.cancel()
    }

    /// Every dialog's form lays out in SwiftUI (no dialog crashes or draws empty).
    @Test func everyDialogLaysOut() throws {
        let (_, dialogs) = try app()
        for id in DialogCatalog.ids {
            dialogs.open(id)
            let host = NSHostingController(rootView: DialogView(controller: dialogs))
            let size = host.view.fittingSize
            #expect(size.width >= 300 && size.height > 40, "\(id): \(size)")
            dialogs.cancel()
        }
    }

    /// Settings and About are windows of their own; closing one is Cancel (`show`: the close button).
    @Test func settingsShowInAWindowAndClosingCancels() throws {
        let (app, dialogs) = try app()
        let presenter = try #require(DialogsFeature.presenter)
        let was = app.model.session.prefs.smartGuides
        app.model.run("app.preferences")
        let window = try #require(NSApp.windows.first { $0.title == "Settings" && $0.isVisible })
        dialogs.set("smartGuides", was ? "0" : "1")
        #expect(app.model.session.prefs.smartGuides == !was)
        window.performClose(nil)
        #expect(dialogs.current == nil)
        #expect(app.model.session.prefs.smartGuides == was, "the close button restores the setting")
        _ = presenter
    }

    @Test func appearanceFollowsTheSetting() throws {
        let (app, _) = try app()
        app.model.run("view.dark", ["on": true])
        DialogsFeature.applyAppearance(app.model.ui.brightness)
        #expect(NSApp.appearance?.name == .darkAqua)
        app.model.ui.brightness = .system
        DialogsFeature.applyAppearance(app.model.ui.brightness)
        #expect(NSApp.appearance == nil)
    }

    @Test func menuItemsForTheDialogs() throws {
        let (app, dialogs) = try app()
        NSApp.mainMenu = MenuBuilder.mainMenu(target: app)
        let target = DialogsMenuTarget(app: app)
        target.install()
        target.install()
        let insert = try #require(NSApp.mainMenu?.items.first { $0.title == "Insert" }?.submenu)
        let hyperlink = try #require(insert.items.first { $0.title == "Hyperlink…" })
        #expect(hyperlink.keyEquivalent == "k" && hyperlink.keyEquivalentModifierMask == [.command])
        #expect(insert.items.filter { $0.title == "Hyperlink…" }.count == 1, "installing twice adds nothing")
        target.run(hyperlink)
        #expect(dialogs.current?.id == "hyperlink")
        dialogs.cancel()
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        let props = try #require(file.items.first { $0.title == "Properties…" })
        target.run(props)
        #expect(dialogs.current?.id == "info")
        dialogs.cancel()
    }

    @Test func panelsOfferDeckcraftsFileTypes() {
        #expect(DialogPresenter.extensions("picture").contains("png"))
        #expect(DialogPresenter.extensions("audio").contains("flac"))
        #expect(DialogPresenter.extensions("video").contains("mov"))
        #expect(DialogPresenter.extensions("theme") == ["thmx", "pptx", "potx", "ppsx"])
        #expect(DialogPresenter.extensions("open").contains("deckcraft"))
        #expect(!DialogPresenter.types(DialogPresenter.extensions("picture")).isEmpty)
    }

    // menus.rs / ribbon.rs pretty_shortcut
    @Test func paletteShowsMacShortcuts() {
        #expect(PaletteView.pretty("Cmd+Shift+N") == "⇧⌘N")
        #expect(PaletteView.pretty("F5") == "F5")
        #expect(PaletteView.pretty("Cmd+Alt+V") == "⌥⌘V")
    }

    @Test func hexColorsRoundTrip() {
        let c = HexColor.color("#3366CC")
        #expect(c.map(HexColor.hex) == "3366CC")
        #expect(HexColor.color("nope") == nil)
    }
}
