// DCAppModelTests — the start window's model: its sources (tiles, templates, the sample, recent files), what
// creating from each tile makes (the same deck as `file.new` with the same parameters), search, missing files,
// the page it reopens on, the launch rule, the Settings switch, and `app.backstage` / `app.home` routing. Ports
// deckcraft's start-screen tests from `crates/ui-egui/src/backstage/tests.rs` and `recent_exists_tells_missing_
// from_present` from `src/tests.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors) where they
// apply; each names its source. Docs/plans/Ribbon-and-StartScreen.md §7, milestone S1.
import DCAppModel
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing

@MainActor
@Suite struct StartScreenTests {
    /// A host with no presentation open and a start window, its recent list `recent` (newest first).
    func host(_ recent: [String] = []) -> (DialogsHost, StartScreenModel) {
        let h = DialogsHost(Session())
        let start = StartScreenModel(model: h.model)
        var list = recent
        start.recentSource = { list }
        start.forgetRecent = { p in list.removeAll { $0 == p } }
        h.dialogs.startScreen = start
        return (h, start)
    }

    // MARK: Sources

    @Test func tilesAreBlankTheThemesTheSampleThenTheTemplates() {
        let tiles = StartCatalog.themeTiles("")
        #expect(tiles.first?.id == "blank")
        #expect(tiles.last?.id == "sample")
        #expect(tiles.dropFirst().dropLast().map(\.title) == builtinThemes().map(\.name))
        #expect(StartCatalog.templateTiles("").map(\.title) == Templates.starters().map(\.name))
        #expect(Set(StartCatalog.allTiles().map(\.id)).count == StartCatalog.allTiles().count, "ids are unique")
    }

    // backstage/files.rs new_tiles, template_tiles: the search filters themes by name, the sample by its words,
    // and templates by name, summary, theme or slide title; Blank only shows unfiltered.
    @Test func searchFiltersTheTiles() {
        #expect(StartCatalog.themeTiles(" HARB ").map(\.id) == ["theme:Harbor"])
        #expect(StartCatalog.themeTiles("north").map(\.id) == ["sample"])
        #expect(StartCatalog.themeTiles("zzz").isEmpty)
        #expect(StartCatalog.templateTiles("pitch").map(\.id) == ["template:Pitch"])
        #expect(StartCatalog.templateTiles("harbor").map(\.title) == Templates.matching("harbor").map(\.name))
        let (_, start) = host()
        start.query = "ember"
        #expect(start.themeTiles.map(\.id) == ["theme:Ember"])
    }

    @Test func newParamsNameOnlyRealTiles() {
        #expect(StartCatalog.newParams("blank") == .emptyObject)
        #expect(StartCatalog.newParams("theme:Harbor") == ["theme": "Harbor"])
        #expect(StartCatalog.newParams("template:Briefing") == ["template": "Briefing"])
        #expect(StartCatalog.newParams("theme:Nope") == nil)
        #expect(StartCatalog.newParams("template:Nope") == nil)
        #expect(StartCatalog.newParams("sample") == nil)
        #expect(StartCatalog.newParams("") == nil)
    }

    // S1 acceptance: create with each theme and template gives the same deck as `file.new` with the same
    // parameters, compared with `document.inspect`; the sample is the engine's sample deck.
    @Test func creatingFromEachTileMatchesFileNew() throws {
        for tile in StartCatalog.allTiles() {
            let (h, start) = host()
            start.show(.new)
            start.selection = tile.id
            let r = start.activate()
            #expect((try? r.get()) != nil, "\(tile.id) creates")
            #expect(h.session.documents.count == 1, "\(tile.id) makes one presentation")
            #expect(!start.isOpen, "\(tile.id) closes the start window")
            let made = try h.session.execute("document.inspect", .emptyObject)
            let direct = Session()
            if tile.id == "sample" {
                try Sample.openSample(direct)
            } else {
                _ = try direct.execute("file.new", try #require(StartCatalog.newParams(tile.id)))
            }
            #expect(made == (try direct.execute("document.inspect", .emptyObject)), "\(tile.id) is file.new's deck")
        }
    }

    @Test func returnWithNothingSelectedCreatesABlankPresentation() throws {
        let (h, start) = host()
        start.show()
        #expect(start.action == .create)
        _ = start.activate()
        #expect(h.session.documents.count == 1)
        #expect(try h.session.execute("document.inspect", .emptyObject) == (try Session.withNew().execute("document.inspect", .emptyObject)))
    }

    @Test func unknownTileIsRefused() {
        let (h, start) = host()
        start.show()
        #expect((try? start.activate("theme:Nope").get()) == nil)
        #expect(h.session.documents.isEmpty)
        #expect(start.isOpen)
    }

    // MARK: Recent files

    // backstage/tests.rs page_ids_round_trip_and_unknown_ids_are_refused: split_path; the start screen's pages
    @Test func splitPathAndPages() {
        #expect(StartCatalog.splitPath("/home/me/Talk.pptx") == ("Talk.pptx", "/home/me"))
        #expect(StartCatalog.splitPath("Talk.pptx") == ("Talk.pptx", ""))
        #expect(StartCatalog.splitPath("/Talk.pptx") == ("Talk.pptx", "/"))
        #expect(StartCatalog.splitPath("/home/me/") == ("me", "/home"))
        #expect(StartCatalog.pages == ["home", "new", "open"], "the start screen has no presentation pages")
        #expect(StartScreenModel.Page.allCases.map(\.rawValue) == StartCatalog.pages)
    }

    // tests.rs recent_exists_tells_missing_from_present (#172)
    @Test func recentExistsTellsMissingFromPresent() throws {
        let dir = TempDir("start-172")
        defer { dir.clean() }
        let path = dir.path("present.deckcraft")
        try Data().write(to: URL(filePath: path))
        #expect(StartCatalog.recentExists(path), "the file exists")
        #expect(!StartCatalog.recentExists("/deckcraft-tests/172/missing.deckcraft"))
        #expect(StartCatalog.recentExists("\\\\server/share/deck.deckcraft"), "UNC paths are never probed")
        #expect(StartCatalog.recentExists("smb://server/share/deck.deckcraft"), "URLs are never probed")
    }

    @Test func recentRowsAreDedupedCappedAndFiltered() {
        let paths = ["/a/One.pptx", "/a/One.pptx", "", "/b/Two.deckcraft"] + (0 ..< 20).map { "/c/f\($0).pptx" }
        let rows = StartCatalog.recents(paths) { _ in true }
        #expect(rows.count == UiState.recentMax)
        #expect(rows.prefix(2).map(\.name) == ["One.pptx", "Two.deckcraft"])
        #expect(StartCatalog.recents(paths, query: "two") { _ in true }.map(\.path) == ["/b/Two.deckcraft"])
        #expect(StartCatalog.recents(["/x/Gone.pptx"]) { _ in false }.first?.missing == true)
    }

    // backstage/tests.rs open_lists_recent_files_and_opens_one: Open lists recent presentations by name, the
    // search filters them, and choosing one opens it (the window closes when the presentation appears).
    @Test func openListsRecentFilesAndOpensOne() throws {
        let dir = TempDir("start-open")
        defer { dir.clean() }
        let path = dir.path("Quarterly review.pptx")
        let s = Session.withNew()
        _ = try s.execute("file.saveAs", ["path": .string(path)])
        let other = dir.path("Other.pptx")
        let (h, start) = host([path, other])
        var opened: [String] = []
        start.openFile = { opened.append($0) }
        h.run("app.backstage", ["page": "open"])
        #expect(start.isOpen && start.page == .open)
        #expect(start.recents.map(\.name) == ["Quarterly review.pptx", "Other.pptx"])
        #expect(start.recents.map(\.missing) == [false, true], "Other.pptx was never written")
        start.query = "quarter"
        #expect(start.items == ["recent:\(path)"])
        start.selection = "recent:\(path)"
        #expect(start.action == .open)
        _ = start.activate()
        #expect(opened == [path])
        start.presentationOpened()
        #expect(!start.isOpen && start.query.isEmpty)
        #expect(h.model.ui.recent.first == path, "UiState.recent follows the list")
    }

    // S1 acceptance: a missing file shows "(missing)" and does nothing when chosen. NSDocumentController drops a
    // file that has gone; UiState.recent keeps it where it was.
    @Test func aMissingRecentFileStaysListedAndDoesNothing() throws {
        let dir = TempDir("start-missing")
        defer { dir.clean() }
        let here = dir.path("Here.deckcraft"), gone = dir.path("Gone.deckcraft")
        try Data().write(to: URL(filePath: here))
        let (h, start) = host([here])
        h.model.ui.recent = [gone, here]
        var opened: [String] = []
        start.openFile = { opened.append($0) }
        start.show(.open)
        #expect(start.allRecents.map(\.path) == [gone, here])
        #expect(start.allRecents.map(\.missing) == [true, false])
        start.selection = "recent:\(gone)"
        #expect(start.action == .none)
        #expect((try? start.activate().get()) == nil)
        #expect(opened.isEmpty && h.session.documents.isEmpty && start.isOpen, "nothing happened")
        #expect(h.model.status == nil, "and nothing was reported")
        start.remove(gone)
        #expect(start.allRecents.map(\.path) == [here])
        #expect(h.model.ui.recent == [here])
        #expect(start.selection == nil)
        start.clearRecents()
        #expect(start.allRecents.isEmpty && h.model.ui.recent.isEmpty)
    }

    @Test func aRestoredFileIsNoLongerKeptFromUiState() throws {
        let dir = TempDir("start-restored")
        defer { dir.clean() }
        let p = dir.path("Back.deckcraft")
        try Data().write(to: URL(filePath: p))
        let (h, start) = host([])
        h.model.ui.recent = [p]
        start.refreshRecents()
        #expect(start.recentPaths.isEmpty, "a file that is there but no longer in NSDocumentController's list was removed")
    }

    // MARK: State

    @Test func reopensOnTheLastPage() {
        let (h, start) = host()
        #expect(start.page == .home)
        h.run("app.backstage", ["page": "new"])
        #expect(start.page == .new && h.model.ui.startPage == "new")
        start.close()
        start.show()
        #expect(start.page == .new, "the window reopens on the page used last")
        let again = StartScreenModel(model: h.model)
        #expect(again.page == .new, "the page is kept in ui.json")
    }

    @Test func arrowsMoveThroughThePage() {
        let (_, start) = host(["/x/A.pptx"])
        start.exists = { _ in true }
        start.show(.new)
        start.move(1)
        #expect(start.selection == "blank")
        start.move(1)
        #expect(start.selection == "theme:DeckCraft")
        start.move(-5)
        #expect(start.selection == "blank", "it stops at the ends")
        start.move(1000)
        #expect(start.selection == start.items.last)
        start.page = .home
        #expect(start.items.last == "recent:/x/A.pptx", "Home lists the recent files after the tiles")
        start.page = .open
        #expect(start.items == ["recent:/x/A.pptx"])
    }

    @Test func inspectReportsThePageSelectionAndQuery() {
        let (_, start) = host()
        start.show(.new)
        start.query = "slate"
        start.selection = "theme:Slate"
        let v = start.inspect()
        #expect(v["open"] == true && v["page"] == "new" && v["selection"] == "theme:Slate" && v["query"] == "slate")
        #expect(v["action"] == "create")
        #expect(v["items"]?.asArray == ["theme:Slate"])
    }

    @Test func theControlMethodDrivesTheWindow() throws {
        let (h, start) = host()
        #expect((try? start.control(["page": "nope"]).get()) == nil)
        _ = start.control(["page": "new", "query": "harbor"])
        #expect(start.isOpen && start.query == "harbor")
        #expect((try? start.control(["select": "theme:Slate"]).get()) == nil, "only what the page shows can be selected")
        let r = try start.control(["select": "theme:Harbor", "activate": true]).get()
        #expect(r["open"] == false)
        #expect((try? h.session.execute("document.inspect", .emptyObject))?["theme"] == "Harbor")
        _ = start.control(["open": true])
        #expect(start.isOpen)
        _ = start.control(["open": false])
        #expect(!start.isOpen)
    }

    // MARK: Routing (backstage.rs; Ribbon-and-StartScreen §7 "From commands")

    // backstage/tests.rs the_start_screen_is_file_home: with nothing open, File is the start screen on Home with
    // Home, New and Open; Print has nothing to print; Blank Presentation makes one document and closes it. Esc
    // closes the Mac's window, where deckcraft's has nowhere to go (the plan's decision).
    @Test func theStartScreenIsFileHome() {
        let (h, start) = host()
        #expect(StartCatalog.atLaunch(files: 0, sample: false, documents: 0, showStartScreen: true) == .startWindow)
        h.run("app.backstage")
        #expect(start.isOpen && start.page == .home)
        #expect((try? h.run("app.backstage", ["page": "print"]).get()) == nil, "nothing to print")
        #expect((try? h.run("app.backstage", ["page": "info"]).get()) == nil, "no presentation pages")
        #expect(start.isOpen)
        _ = start.activate("blank")
        #expect(h.session.documents.count == 1)
        #expect(!start.isOpen)
    }

    @Test func backstageAndHomeRouteToTheStartWindow() {
        let (h, start) = host()
        h.run("app.backstage", ["page": "new"])
        #expect(start.isOpen && start.page == .new)
        #expect(h.dialog == nil, "the \"new\" dialog doesn't open beside it")
        h.run("app.backstage", ["on": false])
        #expect(!start.isOpen)
        h.run("app.backstage", ["page": "OPEN"])
        #expect(start.isOpen && start.page == .open, "page ids are matched as deckcraft's are")
        h.run("app.home")
        #expect(!start.isOpen, "app.home toggles")
        h.run("app.home")
        #expect(start.isOpen && start.page == .home)
        h.run("app.home", ["on": true])
        #expect(start.isOpen)
        h.run("app.home", ["on": false])
        #expect(!start.isOpen)
    }

    @Test func withoutAStartWindowNewIsTheDialog() {
        let h = DialogsHost(Session())
        h.run("app.backstage", ["page": "new"])
        #expect(h.dialog?.id == "new")
        let ids = DialogCatalog.actions(in: h.dialogs.form).map(\.id) + h.dialogs.form.flatMap { row -> [String] in
            if case .tiles(let t) = row { return t.map(\.id) }
            return []
        }
        #expect(ids.contains("new:theme:Harbor") && ids.contains("new:sample") && ids.contains("new:template:Briefing"), "its tiles are the start window's")
        h.dialogs.press("new:theme:Harbor")
        #expect((try? h.session.execute("document.inspect", .emptyObject))?["theme"] == "Harbor")
    }

    // backstage/tests.rs start_screen_opens_the_palette_and_preferences: the start screen keeps the command palette
    // and Settings, without creating a presentation.
    @Test func startScreenOpensThePaletteAndPreferences() {
        let (h, start) = host()
        start.show()
        h.run("app.palette")
        #expect(h.dialogs.palette != nil)
        #expect(h.session.activeDoc == nil, "without creating a presentation")
        h.dialogs.palette = nil
        h.run("app.preferences")
        #expect(h.dialog?.id == "preferences")
        #expect(h.session.activeDoc == nil)
        #expect(start.isOpen)
    }

    // backstage/tests.rs start_screen_opens_files_and_the_file_tab_from_the_keyboard (the File-tab half): Alt+F,
    // `app.backstage` with no page, opens Home.
    @Test func theFileCommandOpensHome() {
        let (h, start) = host()
        start.show(.new)
        start.close()
        start.page = .home
        h.run("app.backstage", [:])
        #expect(start.isOpen && start.page == .home)
    }

    // MARK: Launch and Settings

    @Test func launchRule() {
        #expect(StartCatalog.atLaunch(files: 0, sample: false, documents: 0, showStartScreen: true) == .startWindow)
        #expect(StartCatalog.atLaunch(files: 0, sample: false, documents: 0, showStartScreen: false) == .untitled, "the setting off restores the untitled document")
        #expect(StartCatalog.atLaunch(files: 1, sample: false, documents: 0, showStartScreen: true) == .nothing)
        #expect(StartCatalog.atLaunch(files: 0, sample: true, documents: 0, showStartScreen: true) == .nothing)
        #expect(StartCatalog.atLaunch(files: 0, sample: false, documents: 1, showStartScreen: true) == .nothing, "state restoration")
    }

    @Test func settingsHaveTheStartScreenSwitch() {
        let (h, _) = host()
        #expect(h.model.ui.showStartScreen, "on by default (decision 5)")
        h.run("app.preferences")
        #expect(h.dialog?.value("startScreen") == "1")
        h.dialogs.set("startScreen", "0")
        #expect(!h.model.ui.showStartScreen, "it applies as it changes")
        h.dialogs.press("cancel")
        #expect(h.model.ui.showStartScreen, "Cancel restores it")
        h.run("app.preferences")
        h.dialogs.set("startScreen", "0")
        h.dialogs.press("ok")
        #expect(!h.model.ui.showStartScreen)
    }

    @Test func uiStateKeepsTheSettingAndThePage() throws {
        let old = try JSONDecoder().decode(UiState.self, from: Data(#"{"tab":"Home"}"#.utf8))
        #expect(old.showStartScreen && old.startPage == "home", "a ui.json from before S1 gets the defaults")
        var s = UiState()
        s.showStartScreen = false
        s.startPage = "open"
        let back = try JSONDecoder().decode(UiState.self, from: JSONEncoder().encode(s))
        #expect(!back.showStartScreen && back.startPage == "open")
        s.startPage = "print"
        #expect(s.sanitized().startPage == "home")
    }

    // MARK: Pictures

    @Test func tilePicturesAreRenderedAndCached() throws {
        let dir = TempDir("start-art")
        defer { dir.clean() }
        let png = try #require(StartTileArt.png("theme:Harbor", width: 96, cache: dir.url))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(files == ["theme_Harbor-96.png"])
        #expect(StartTileArt.png("theme:Harbor", width: 96, cache: dir.url) == png, "the second call reads the cache")
        #expect(StartTileArt.png("sample", width: 64, cache: nil) != nil)
        #expect(StartTileArt.png("template:Pitch", width: 64, cache: nil) != nil)
        #expect(StartTileArt.png("theme:Nope", width: 64, cache: nil) == nil)
    }
}
