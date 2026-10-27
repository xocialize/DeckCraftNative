// DCAppModelTests — the file panels the engine asks for, the File backstage, Settings files, toasts and the
// palette, without a window. Ported from deckcraft `crates/ui-egui/src/reuse_picker_tests.rs`,
// `inbox_tests.rs`, `browsetheme_tests.rs`, `compare_tests.rs`, `backstage_tests.rs`, `settings.rs`,
// `toast.rs` and `dialogs.rs` (MIT OR Apache-2.0); each test names its source.
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct DialogsFilesTests {
    // MARK: Reuse Slides (reuse_picker_tests.rs)

    func deckBytes(_ titles: [String]) throws -> [UInt8] {
        let s = Session.withNew()
        for t in titles { _ = try s.execute("slide.new", ["layout": "titleAndContent", "title": .string(t)]) }
        _ = try s.execute("slide.delete", ["index": 0])
        return try FileCommands.saveBytes(try #require(s.activeDoc).doc, "deckcraft")
    }

    /// An app whose open panel picks `src.deckcraft` in `dir`.
    func reuseHost(_ dir: TempDir, _ titles: [String]) throws -> DialogsHost {
        try Data(try deckBytes(titles)).write(to: URL(filePath: dir.path("src.deckcraft")))
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        let h = DialogsHost(s)
        h.openPaths = [dir.path("src.deckcraft")]
        h.run("app.reuseSlidesDialog")
        #expect(h.dialog?.id == "reuseSlides")
        return h
    }

    func titles(_ h: DialogsHost) -> [String] { h.st?.doc.slides.map(\.title) ?? [] }

    // reuse_picker_tests.rs: inserts_the_ticked_slides_and_closes
    @Test func insertsTheTickedSlidesAndCloses() throws {
        let dir = TempDir("reuse1")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha", "Beta", "Gamma"])
        #expect(h.asked == ["open"])
        h.press("ok", ["slide1": "0"])
        #expect(h.dialog == nil)
        let t = titles(h)
        #expect(t.contains("Alpha") && t.contains("Gamma") && !t.contains("Beta"), "\(t)")
    }

    // reuse_picker_tests.rs: inserts_what_was_listed_even_if_the_file_changed_meanwhile
    @Test func insertsWhatWasListedEvenIfTheFileChangedMeanwhile() throws {
        let dir = TempDir("reuse2")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha", "Beta"])
        try Data(try deckBytes(["Other", "Beta"])).write(to: URL(filePath: dir.path("src.deckcraft")))
        // deckcraft's own field for an unticked slide works too.
        h.press("ok", ["off1": "1"])
        let t = titles(h)
        #expect(t.contains("Alpha") && !t.contains("Other") && !t.contains("Beta"), "\(t)")
    }

    // reuse_picker_tests.rs: inserts_into_the_presentation_the_picker_was_opened_for
    @Test func insertsIntoThePresentationThePickerWasOpenedFor() throws {
        let dir = TempDir("reuse3")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha"])
        let first = try #require(h.st).uid
        _ = try h.session.execute("file.new")
        let second = try #require(h.st).uid
        #expect(first != second)
        h.dialogs.press("ok")
        #expect(h.dialog == nil)
        let doc = { (uid: UInt64) in h.session.documents.first { $0.uid == uid } }
        #expect(doc(first)?.doc.slides.contains { $0.title == "Alpha" } == true, "inserted where the picker was opened")
        #expect(doc(second)?.doc.slides.count == 1, "the other presentation is untouched")
        #expect(h.st?.uid == second, "the view stays on the presentation the user moved to")
    }

    // reuse_picker_tests.rs: nothing_is_inserted_once_that_presentation_is_closed
    @Test func nothingIsInsertedOnceThatPresentationIsClosed() throws {
        let dir = TempDir("reuse4")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha"])
        _ = try h.session.execute("file.new")
        h.session.closeDocument(0)
        h.dialogs.press("ok")
        #expect(h.session.documents.count == 1)
        #expect(!titles(h).contains("Alpha"))
        #expect(h.dialog?.id == "reuseSlides", "the dialog stays open with the reason")
        #expect(h.model.status?.contains("closed") == true)
    }

    // reuse_picker_tests.rs: a_failed_insert_keeps_the_dialog_open
    @Test func aFailedInsertKeepsTheDialogOpen() throws {
        let dir = TempDir("reuse5")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha"])
        let before = titles(h)
        var params = try #require(h.dialog).params
        var slides = params["slides"]?.asArray ?? []
        slides.append(["index": 9, "title": "Ghost", "hidden": false])
        params.set("slides", .array(slides))
        h.dialogs.open("reuseSlides", params: params)
        h.dialogs.press("ok")
        #expect(h.dialog?.id == "reuseSlides", "the dialog closed on a failed insert")
        #expect(titles(h) == before)
    }

    @Test func noTickedSlideKeepsTheDialog() throws {
        let dir = TempDir("reuse6")
        defer { dir.clean() }
        let h = try reuseHost(dir, ["Alpha", "Beta"])
        h.dialogs.press("selectNone")
        h.dialogs.press("ok")
        #expect(h.dialog?.id == "reuseSlides")
        #expect(h.model.status == "Tick at least one slide to insert")
    }

    // MARK: Pickers (inbox_tests.rs, browsetheme_tests.rs, compare_tests.rs, lib.rs change picture)

    // inbox_tests.rs: late_picker_files_keep_their_document_slide_and_operation
    @Test func latePickerFilesKeepTheirDocumentSlideAndOperation() throws {
        let dir = TempDir("inbox")
        defer { dir.clean() }
        try Data(redPNG()).write(to: URL(filePath: dir.path("a.png")))
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        let h = DialogsHost(s)
        h.holdPicks = true
        let doc = try #require(h.st).uid
        let slideId = try #require(h.st?.currentSlide?.id)
        h.run("app.insertPictureDialog")
        // The user moves to the first slide, then to another presentation, before the picker answers.
        _ = try s.execute("slide.go", ["index": 0])
        _ = try s.execute("file.new")
        let other = try #require(h.st).uid
        h.release(dir.path("a.png"))
        let pictures = { (uid: UInt64, sid: SlideId) in
            h.session.documents.first { $0.uid == uid }?.doc.slides.first { $0.id == sid }?.shapes.filter { if case .picture = $0.kind { true } else { false } }.count ?? -1
        }
        #expect(pictures(doc, slideId) == 1, "the picture lands on the slide that asked")
        #expect(h.session.documents.first { $0.uid == doc }?.doc.slides.first?.shapes.contains { if case .picture = $0.kind { true } else { false } } == false)
        #expect(h.st?.uid == other, "the view stays where the user is")
    }

    // inbox_tests.rs: a_closed_or_cancelled_request_does_not_insert_into_the_active_document
    @Test func aClosedOrCancelledRequestDoesNotInsertIntoTheActiveDocument() throws {
        let dir = TempDir("inbox2")
        defer { dir.clean() }
        try Data(redPNG()).write(to: URL(filePath: dir.path("a.png")))
        let h = DialogsHost()
        h.holdPicks = true
        h.run("app.insertPictureDialog")
        h.release(nil)
        #expect(h.st?.currentSlide?.shapes.contains { if case .picture = $0.kind { true } else { false } } == false, "cancelled")
        h.run("app.insertPictureDialog")
        _ = try h.session.execute("file.new")
        h.session.closeDocument(0)
        h.release(dir.path("a.png"))
        #expect(h.st?.currentSlide?.shapes.contains { if case .picture = $0.kind { true } else { false } } == false, "closed: not inserted elsewhere")
        #expect(h.model.status?.contains("closed") == true)
    }

    @Test func insertPictureAudioAndVideoAskForTheirKind() throws {
        let dir = TempDir("kinds")
        defer { dir.clean() }
        try Data(redPNG()).write(to: URL(filePath: dir.path("a.png")))
        let h = DialogsHost()
        h.openPaths = [dir.path("a.png"), nil, nil]
        h.run("app.insertPictureDialog")
        h.run("app.insertAudioDialog")
        h.run("app.insertVideoDialog")
        #expect(h.asked == ["picture", "audio", "video"])
        #expect(h.st?.selectedShapes.first.map { if case .picture = $0.kind { true } else { false } } == true)
        h.openPaths = [dir.path("a.png")]
        h.run("app.changePictureDialog")
        #expect(h.asked.last == "picture")
        #expect(h.undoLabels.count == 2, "\(h.undoLabels)")
    }

    // browsetheme_tests.rs: browse_button_applies_the_picked_files_theme
    @Test func browseButtonAppliesThePickedFilesTheme() throws {
        let dir = TempDir("thmx")
        defer { dir.clean() }
        let brand = Session.withNew()
        _ = try brand.execute("design.fonts", ["major": "Lato", "minor": "Lato"])
        _ = try brand.execute("file.saveAs", ["path": .string(dir.path("Brand.pptx"))])
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "title", "title": "Hello"])
        let h = DialogsHost(s)
        h.openPaths = [dir.path("Brand.pptx")]
        h.run("app.browseThemeDialog")
        #expect(h.asked == ["theme"])
        #expect(h.st?.doc.masters.first?.theme.fonts.major.latin == "Lato")
    }

    // compare_tests.rs: pane_opens_lists_changes… (the picker half: Compare… picks a file and opens the pane)
    @Test func compareDialogComparesWithThePickedFile() throws {
        let dir = TempDir("compare")
        defer { dir.clean() }
        let s = Session.withNew()
        _ = try s.execute("file.saveAs", ["path": .string(dir.path("rev.deckcraft"))])
        _ = try s.execute("slide.new")
        let h = DialogsHost(s)
        h.openPaths = [dir.path("rev.deckcraft")]
        h.run("app.compareDialog")
        #expect(h.asked == ["open"])
        #expect(h.model.ui.pane == "revisions", "compare opens the Revisions pane")
        #expect(h.st?.compare != nil)
        #expect(throws: (any Error).self) { try DialogsHost(Session()).run("app.compareDialog").get() }
    }

    // MARK: Export (dialogs.rs export_dialog_writes_an_animated_gif, …_png_with_a_transparent_background)

    @Test func exportDialogWritesAnAnimatedGif() throws {
        let dir = TempDir("gif")
        defer { dir.clean() }
        let h = DialogsHost()
        _ = h.run("slide.new")
        h.savePath = dir.path("deck.gif")
        h.run("app.exportDialog")
        h.dialogs.set("fmt", "gif")
        #expect(h.dialogs.form.contains { if case .text(_, "gifSeconds", _) = $0 { true } else { false } })
        h.dialogs.set("gifLoop", "0")
        // A range outside the deck keeps the dialog open with a message, and nothing is written.
        h.press("ok", ["gifTo": "9"])
        #expect(h.dialog?.id == "export")
        #expect(h.model.status?.contains("Slides") == true, "\(h.model.status ?? "")")
        #expect(!FileManager.default.fileExists(atPath: dir.path("deck.gif")))
        h.press("ok", ["gifTo": "2"])
        #expect(h.dialog == nil, "the dialog closes after exporting")
        #expect(h.suggested.last?.hasSuffix(".gif") == true)
        let bytes = [UInt8](try Data(contentsOf: URL(filePath: dir.path("deck.gif"))))
        #expect(bytes.starts(with: Array("GIF89a".utf8)))
        #expect(UInt16(bytes[6]) | UInt16(bytes[7]) << 8 == 960, "medium by default")
        #expect(!String(decoding: bytes, as: UTF8.self).contains("NETSCAPE2.0"), "Loop forever unticked: plays once")
    }

    @Test func exportDialogOffersTransparentBackgroundForPNGOnly() throws {
        let dir = TempDir("png")
        defer { dir.clean() }
        let h = DialogsHost()
        h.savePath = dir.path("slide.png")
        h.run("app.exportDialog")
        func hasTransparent() -> Bool { h.dialogs.form.contains { if case .check(_, "pngTransparent") = $0 { true } else { false } } }
        #expect(!hasTransparent(), "PDF has no transparent background")
        h.dialogs.set("fmt", "jpeg")
        #expect(!hasTransparent(), "nor has JPEG")
        h.dialogs.set("fmt", "png")
        #expect(hasTransparent())
        h.press("ok", ["pngTransparent": "1"])
        #expect(h.dialog == nil)
        let bytes = [UInt8](try Data(contentsOf: URL(filePath: dir.path("slide.png"))))
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func exportDialogWritesAPdfOfHandouts() throws {
        let dir = TempDir("pdf")
        defer { dir.clean() }
        let h = DialogsHost()
        h.savePath = dir.path("deck.pdf")
        h.run("app.exportDialog")
        h.press("ok", ["pdfLayout": "h3"])
        let bytes = [UInt8](try Data(contentsOf: URL(filePath: dir.path("deck.pdf"))))
        #expect(bytes.starts(with: Array("%PDF".utf8)))
        #expect(h.model.status == "Exported \(dir.path("deck.pdf"))")
    }

    // MARK: File backstage (backstage_tests.rs)

    // backstage_tests.rs: page_ids_round_trip_and_unknown_ids_are_refused
    @Test func pageIdsRoundTripAndUnknownIdsAreRefused() {
        let h = DialogsHost()
        for page in DialogBackstage.pages where !["open", "saveAs", "print"].contains(page) {
            let r = h.run("app.backstage", ["page": .string(page)])
            #expect((try? r.get())?["page"]?.asStr == page, "\(page)")
            h.dialogs.cancel()
        }
        #expect(throws: (any Error).self) { try h.run("app.backstage", ["page": "nowhere"]).get() }
        let empty = DialogsHost(Session())
        #expect(throws: (any Error).self) { try empty.run("app.backstage", ["page": "info"]).get() }
        #expect((try? empty.run("app.backstage", ["page": "new"]).get())?["page"] == "new", "New needs nothing open")
    }

    // backstage_tests.rs: new_template_opens_a_starter_deck, new_creates_a_presentation
    @Test func newFromTemplateOpensAStarterDeck() throws {
        let h = DialogsHost(Session())
        h.run("app.backstage", ["page": "new"])
        #expect(h.dialog?.id == "new")
        let tiles = tilesOf(h.dialogs.form)
        #expect(tiles.contains { $0.id == "new:theme:Harbor" })
        #expect(tiles.contains { $0.id == "new:template:Briefing" })
        #expect(tiles.contains { $0.id == "new:sample" })
        h.dialogs.press("new:template:Briefing")
        #expect(h.dialog == nil, "a new presentation leaves the gallery")
        #expect((h.st?.doc.slides.count ?? 0) > 1)
        h.run("app.home", ["on": true])
        h.dialogs.press("new:blank")
        #expect(h.session.documents.count == 2)
        h.run("app.home", ["on": true])
        h.dialogs.press("new:theme:Ember")
        #expect(h.st?.doc.masters.first?.theme.name == "Ember")
    }

    @Test func newGalleryFiltersByTheSearch() {
        let h = DialogsHost()
        h.run("app.home")
        h.dialogs.set("query", "zzzz-no-theme")
        #expect(h.dialogs.form.contains { if case .note(let t) = $0 { t.hasPrefix("No themes or templates match") } else { false } })
        h.dialogs.set("query", "harb")
        let tiles = tilesOf(h.dialogs.form)
        #expect(tiles.map(\.id).contains("new:theme:Harbor"))
        #expect(!tiles.map(\.id).contains("new:theme:Ember"))
    }

    // backstage_tests.rs: info_shows_and_edits_the_properties, info_saves_a_property_draft_when_save_is_clicked
    @Test func infoShowsAndEditsTheProperties() throws {
        let h = DialogsHost()
        h.run("app.backstage", ["page": "info"])
        #expect(h.dialog?.id == "info")
        #expect(h.dialogs.form.contains { if case .note(let t) = $0 { t.contains("Slides: 1") } else { false } })
        h.press("ok", ["title": "Quarterly", "author": "Ann"])
        #expect(h.dialog == nil)
        let props = try #require(try h.session.execute("file.info")["properties"])
        #expect(props["title"] == "Quarterly")
        #expect(props["author"] == "Ann")
        // A field left as it was is not written again (no extra undo step).
        let n = h.undoLabels.count
        h.run("app.backstage", ["page": "info"])
        h.dialogs.press("ok")
        #expect(h.undoLabels.count == n)
    }

    @Test func infoChecksForIssuesAndCopiesThePath() throws {
        let dir = TempDir("info")
        defer { dir.clean() }
        let s = Session.withNew()
        _ = try s.execute("file.saveAs", ["path": .string(dir.path("a.deckcraft"))])
        let h = DialogsHost(s)
        h.run("app.backstage", ["page": "info"])
        h.dialogs.press("copyPath")
        #expect(h.copied == [dir.path("a.deckcraft")])
        h.dialogs.press("checkIssues")
        #expect(h.dialog?.id == "accessibility")
    }

    // backstage_tests.rs: options_in_backstage_opens_preferences_and_cancel_closes_it (Account → About on the Mac)
    @Test func accountShowsAbout() {
        let h = DialogsHost()
        h.run("app.backstage", ["page": "account"])
        #expect(h.dialog?.id == "about")
        h.dialogs.press("link:\(Links.github)")
        #expect(h.opened == [Links.github])
        h.dialogs.press("ok")
        #expect(h.dialog == nil)
    }

    // MARK: Settings files (settings.rs)

    // settings.rs: damaged_settings_files_give_the_defaults
    @Test func damagedSettingsFilesGiveTheDefaults() throws {
        let dir = TempDir("settings")
        defer { dir.clean() }
        for bytes: [UInt8] in [[], Array("{".utf8), [0xFF, 0xFE, 0x20], Array("[1, 2, 3]".utf8), Array("null".utf8)] {
            try Data(bytes).write(to: dir.url.appending(path: DialogSettings.prefsFile))
            #expect(DialogSettings.loadPrefs(dir.url) == nil, "\(bytes)")
        }
        try Data(repeating: 0x20, count: DialogSettings.maxBytes + 1).write(to: dir.url.appending(path: DialogSettings.prefsFile))
        #expect(DialogSettings.loadPrefs(dir.url) == nil, "oversized")
        try FileManager.default.removeItem(at: dir.url.appending(path: DialogSettings.prefsFile))
        try FileManager.default.createDirectory(at: dir.url.appending(path: DialogSettings.prefsFile), withIntermediateDirectories: true)
        #expect(DialogSettings.loadPrefs(dir.url) == nil, "a folder where the file should be")
        #expect(DialogSettings.loadPrefs(dir.url.appending(path: "missing")) == nil)
    }

    // settings.rs: out_of_range_values_are_brought_into_range
    @Test func outOfRangeValuesAreBroughtIntoRange() throws {
        let dir = TempDir("ranges")
        defer { dir.clean() }
        let text = #"{"gridSpacing": 0.0, "duplicateOffset": 1.0e300, "recoveryMinutes": -5.0, "author": "\#(String(repeating: "a", count: 1000))"}"#
        try Data(text.utf8).write(to: dir.url.appending(path: DialogSettings.prefsFile))
        let p = try #require(DialogSettings.loadPrefs(dir.url))
        #expect(p.gridSpacing == Prefs().gridSpacing)
        #expect(p.duplicateOffset == 1000)
        #expect(p.recoveryMinutes == 0.1)
        #expect(p.author.count == 256)
    }

    // settings.rs: saving_round_trips_and_leaves_no_temporary_file
    @Test func savingRoundTripsAndLeavesNoTemporaryFile() throws {
        let dir = TempDir("save")
        defer { dir.clean() }
        var prefs = Prefs()
        prefs.author = "Ann"
        prefs.units = .centimeters
        let nested = dir.url.appending(path: "nested")
        DialogSettings.savePrefs(prefs, to: nested)
        DialogSettings.savePrefs(prefs, to: nested)
        let p = try #require(DialogSettings.loadPrefs(nested))
        #expect(p.author == "Ann" && p.units == .centimeters)
        let names = try FileManager.default.contentsOfDirectory(atPath: nested.path)
        #expect(names.allSatisfy { !$0.hasSuffix(".tmp") }, "\(names)")
        // A settings folder that is a file: nothing saved, no crash.
        try Data("file".utf8).write(to: dir.url.appending(path: "blocked"))
        DialogSettings.savePrefs(prefs, to: dir.url.appending(path: "blocked"))
    }

    // MARK: Toast (toast.rs) and the palette (menus.rs)

    // toast.rs: the_message_names_the_fonts
    @Test func theMessageNamesTheFonts() {
        let f = DialogToast.missingFontsMessage
        #expect(f([]) == nil)
        #expect(f(["Aptos"]) == "Aptos isn't installed on this computer. Text that uses it is shown in a similar font.")
        #expect(f(["Aptos", "Sora"])?.hasPrefix("Aptos and Sora aren't installed") == true)
        #expect(f(["A", "B", "C"])?.hasPrefix("A, B and C aren't") == true)
        #expect(f(["A", "B", "C", "D", "E"])?.hasPrefix("A, B, C and 2 more aren't") == true)
    }

    // lib.rs: opening_a_file_with_missing_fonts_shows_a_toast_once
    @Test func missingFontsToastOncePerDocument() throws {
        let h = DialogsHost()
        h.dialogs.noteMissingFonts()
        #expect(h.dialogs.toast == nil, "a new presentation has nothing to say")
        let st = try #require(h.st)
        st.missingFonts = ["Aptos"]
        h.dialogs.noteMissingFonts()
        #expect(h.dialogs.toast == nil, "only once per document")
        _ = try h.session.execute("file.new")
        h.st?.missingFonts = ["Aptos"]
        h.dialogs.noteMissingFonts()
        #expect(h.dialogs.toast?.text.hasPrefix("Aptos isn't installed") == true)
        #expect(h.dialogs.freshToast(now: Date().addingTimeInterval(Toast.showSeconds + 1)) == nil, "gone after a few seconds")
    }

    @Test func paletteRunsTheSelectedCommand() {
        let h = DialogsHost()
        h.run("app.palette")
        #expect(h.dialogs.palette != nil)
        h.dialogs.palette?.query = "new slide"
        #expect(h.dialogs.paletteItems.first?.id == "slide.new")
        h.dialogs.paletteMove(-5)
        #expect(h.dialogs.palette?.selection == 0)
        h.dialogs.paletteRun()
        #expect(h.dialogs.palette == nil)
        #expect(h.st?.doc.slides.count == 2)
    }

    @Test func saveAsRequestRunsTheSaveAsCommand() {
        let h = DialogsHost()
        #expect(h.dialogs.request(.pickFile(purpose: "saveAs")))
        #expect(h.model.status == "unknown UI command `app.saveAsDialog`", "the app's NSDocument answers it")
        #expect(!h.dialogs.request(.message(text: "x")))
    }
}
