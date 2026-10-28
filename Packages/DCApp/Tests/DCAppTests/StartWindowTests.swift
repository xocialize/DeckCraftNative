// DCAppTests — the start window in the app, in-process: `app.backstage` and `app.home` show it, `file.new`
// closes it, Esc closes it, typing in it reaches no presentation, the launch rule and its Settings switch,
// File › Open Recent lists what the window lists, and the control channel's `ui.inspect` keys (`home`,
// `backstage`, `startScreen`), `ui.startScreen` and `ui.screenshot {window: "start"}`. deckcraft's start-screen
// tests are in `crates/ui-egui/src/backstage/tests.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors); the ones that need a window are ported here and name their source.
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct StartWindowTests {
    /// An app with nothing open; its recent list is `recent`, and nothing touches NSDocumentController's.
    func app(_ recent: [String] = []) throws -> (AppController, StartScreenModel) {
        _ = NSApplication.shared
        let app = AppController()
        app.syncSuspended += 1
        let start = try #require(StartFeature.model)
        var list = recent
        start.recentSource = { list }
        start.forgetRecent = { p in list.removeAll { $0 == p } }
        start.openFile = { _ in }
        StartFeature.documentCount = 0
        return (app, start)
    }

    func call(_ app: AppController, _ method: String, _ p: JSON = .emptyObject) -> ControlOutcome? {
        app.controlHandlers[method]?(p)
    }

    func done(_ o: ControlOutcome?) -> JSON {
        guard case .done(let v) = o else { return .null }
        return v
    }

    func close(_ start: StartScreenModel) {
        start.close()
        StartFeature.window?.window?.orderOut(nil)
    }

    @Test func installsAndRoutesTheFileCommands() throws {
        let (app, start) = try app()
        defer { close(start) }
        #expect(DialogsFeature.controller?.startScreen === start)
        #expect(app.inspectors["home"]?() == false)
        #expect(app.inspectors["backstage"]?() == .null)
        app.model.run("app.backstage", ["page": "new"])
        #expect(StartFeature.window?.window?.isVisible == true, "the start window shows")
        #expect(app.inspectors["home"]?() == true)
        #expect(app.inspectors["backstage"]?() == "new")
        let s = try #require(app.inspectors["startScreen"]?())
        #expect(s["open"] == true && s["page"] == "new" && s["shown"] == true)
        app.model.run("app.home", ["on": false])
        #expect(StartFeature.window?.window?.isVisible == false)
    }

    // The plan: `file.new` closes the start window, as does any presentation opening.
    @Test func fileNewClosesIt() throws {
        let (app, start) = try app()
        defer { close(start) }
        start.show()
        app.model.run("file.new", ["theme": "Harbor"])
        StartFeature.modelChanged(app)
        #expect(!start.isOpen)
        #expect(StartFeature.window?.window?.isVisible == false)
        #expect(app.model.session.documents.count == 1)
    }

    // S1 acceptance: Esc closes the start window (deckcraft's start screen has nowhere to go; the Mac's is a window).
    @Test func escapeClosesIt() throws {
        let (_, start) = try app()
        defer { close(start) }
        start.show()
        let w = try #require(StartFeature.window?.window as? StartWindow)
        w.cancelOperation(nil)
        #expect(!start.isOpen)
        #expect(!w.isVisible)
        start.show()
        w.performClose(nil)
        #expect(!start.isOpen, "the close button tells the model")
    }

    @Test func commandFFocusesTheSearch() throws {
        let (_, start) = try app()
        defer { close(start) }
        start.show()
        let w = try #require(StartFeature.window?.window)
        let before = start.searchFocus
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                              context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(w.performKeyEquivalent(with: e))
        #expect(start.searchFocus == before &+ 1)
    }

    // backstage/tests.rs start_screen_ignores_text_paste_and_ime_while_file_keys_navigate: the start window has no
    // slide; typing in it creates and edits no presentation and reports nothing.
    @Test func typingReachesNoPresentation() throws {
        let (app, start) = try app()
        defer { close(start) }
        start.show()
        let w = try #require(StartFeature.window?.window)
        for (ch, code) in [("x", UInt16(7)), ("v", UInt16(9))] {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
        #expect(app.model.session.documents.isEmpty, "the start window has no slide to edit")
        #expect(app.model.status == nil, "typing was ignored, not run and refused")
        #expect(start.isOpen)
    }

    // S1 acceptance: a launch with no file shows the start window and no untitled document; turned off in
    // Settings, the untitled document comes back.
    @Test func launchShowsTheStartWindowUnlessTurnedOff() throws {
        let (app, start) = try app()
        defer { close(start) }
        #expect(!StartFeature.atLaunch(files: 0, sample: false), "no untitled presentation")
        #expect(start.isOpen && StartFeature.window?.window?.isVisible == true)
        #expect(app.model.session.documents.isEmpty)
        close(start)
        app.model.ui.showStartScreen = false
        #expect(StartFeature.atLaunch(files: 0, sample: false), "AppKit makes the untitled presentation")
        #expect(!start.isOpen)
        #expect(!StartFeature.atLaunch(files: 1, sample: false), "a file to open")
        #expect(!StartFeature.atLaunch(files: 0, sample: true), "--sample")
        #expect(!start.isOpen)
    }

    // S1 acceptance: the recents match File › Open Recent.
    @Test func openRecentListsTheStartWindowsRecents() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dcapp-start-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let here = dir.appending(path: "Here.deckcraft").path, gone = dir.appending(path: "Gone.pptx").path
        try Data().write(to: URL(filePath: here))
        let (app, start) = try app([here, gone])
        defer { close(start) }
        NSApp.mainMenu = MenuBuilder.mainMenu(target: app)
        StartFeature.recentMenu = nil
        StartFeature.installRecentMenu()
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == L10n.menuTitle("File") }?.submenu)
        let titles = file.items.map(\.title)
        let open = try #require(titles.firstIndex(of: L10n.menuTitle("Open…")))
        #expect(titles.at(open + 1) == String(localized: "Open Recent", bundle: .module), "after Open…")
        let items = StartFeature.recentMenuItems()
        start.show()
        #expect(items.map(\.path) == start.allRecents.map(\.path))
        #expect(items.first?.title == "Here.deckcraft")
        #expect(items.last.map { $0.title.hasPrefix("Gone.pptx") && $0.title != "Gone.pptx" } == true, "marked missing")
        #expect(items.map(\.enabled) == [true, false], "a missing file does nothing")
        let inspected = try #require(app.inspectors["startScreen"]?()["openRecent"]?.asArray)
        #expect(inspected.compactMap { $0["path"]?.asStr } == [here, gone])
    }

    @Test func theControlChannelDrivesAndCapturesIt() throws {
        let (app, start) = try app()
        defer { close(start) }
        let refused = done(call(app, "ui.screenshot", ["window": "start"]))
        #expect(refused["ok"] == false, "nothing to capture while it is closed")
        let r = done(call(app, "ui.startScreen", ["page": "new", "select": "theme:Paper"]))
        #expect(r["ok"] == true && r["result"]?["selection"] == "theme:Paper")
        guard case .screenshot(let path) = call(app, "ui.screenshot", ["window": "start", "path": "/tmp/x.png"]) else {
            Issue.record("the start window is captured through the Automation area")
            return
        }
        #expect(path == "/tmp/x.png")
        #expect(AutomationFeature.nextCapture === StartFeature.window?.window)
        AutomationFeature.nextCapture = nil
        guard case .screenshot = call(app, "ui.screenshot", [:]) else {
            Issue.record("any other window goes to the handler before this one")
            return
        }
        let bad = done(call(app, "ui.startScreen", ["select": "theme:Nope"]))
        #expect(bad["ok"] == false)
        let made = done(call(app, "ui.startScreen", ["activate": true]))
        #expect(made["ok"] == true && made["result"]?["open"] == false)
        #expect(app.model.session.documents.count == 1)
    }
}
