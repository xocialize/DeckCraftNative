// DCAppModelTests — the tests of deckcraft `crates/ui-egui/src/lib.rs` that no area had ported, at the level the
// Mac app exposes them without a window: the trackpad twist, Change Picture, Home, Grid Options, About, the
// Language dialog, the File menu's Export…, the canvas animation preview's frames and the show's commands and
// swipes (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Each test names its source, Rust
// names in camelCase; the triage of all 62 is in PORT-NOTES.md ("lib.rs tests").
import DCAnim
import DCCore
import DCEngine
import DCModel
import DCRender
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct LibTests {
    static func shape(_ s: Session, _ id: ShapeId) -> Shape? { s.activeDoc?.shape(id) }

    static func id(_ r: JSON) -> ShapeId { ShapeId(UInt32(r["id"]?.asU64 ?? 0)) }

    // MARK: Canvas

    // lib.rs: a_trackpad_twist_rotates_the_shape_under_the_canvas. The twist turns the selection and letting go
    // is one undo step. Off the canvas AppKit doesn't send `rotate(with:)` to the canvas at all (the event goes
    // to the view under the pointer), so that half has nothing to call here.
    @Test func aTrackpadTwistRotatesTheShapeUnderTheCanvas() throws {
        let app = AppModel(session: Session.withNew())
        let id = Self.id(try app.session.execute("shape.insert", ["preset": "rect", "rect": [80, 80, 100, 60]]))
        _ = try app.session.execute("edit.select", ["ids": [id.toJSON()]])
        let undo = app.session.activeDoc?.history.undo.count ?? 0
        var twisting = false
        CanvasInput.twist(app, degrees: 20, ended: false, twisting: &twisting)
        CanvasInput.twist(app, degrees: 10, ended: false, twisting: &twisting)
        #expect(abs((Self.shape(app.session, id)?.xfrm?.rot ?? 0) - 30) < 0.05, "twist landed on \(Self.shape(app.session, id)?.xfrm?.rot ?? 0)")
        #expect(twisting)
        CanvasInput.twist(app, degrees: 0, ended: true, twisting: &twisting)
        #expect(!twisting)
        #expect(app.session.activeDoc?.interaction == nil, "letting go ends the gesture")
        #expect(app.session.activeDoc?.history.undo.count == undo + 1, "the whole twist is one undo step")
        app.run("edit.undo")
        #expect(abs(Self.shape(app.session, id)?.xfrm?.rot ?? 1) < 0.01, "one undo puts it back")
        // A twist while editing text doesn't turn the box.
        _ = try app.session.execute("text.edit", ["id": id.toJSON()])
        CanvasInput.twist(app, degrees: 20, ended: false, twisting: &twisting)
        #expect(abs(Self.shape(app.session, id)?.xfrm?.rot ?? 1) < 0.01)
        #expect(!twisting)
    }

    // MARK: Dialogs

    static func svg(_ colour: String) -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='4' fill='\(colour)'/></svg>".utf8)
    }

    /// The media of the one picture on the first slide (failing the test when there isn't exactly one).
    static func onlyPicture(_ h: DialogsHost) -> MediaId? {
        let pics = h.st?.doc.slides.first?.shapes.compactMap { sh -> MediaId? in
            if case .picture(let fill) = sh.kind { return fill.media }
            return nil
        } ?? []
        #expect(pics.count == 1, "one picture, replaced in place")
        return pics.first
    }

    // lib.rs: change_picture_replaces_the_selected_picture (#115). The file panel answers at once (deckcraft's
    // desktop picker) or later (its web inbox: here a panel that answers after the user did something else).
    @Test func changePictureReplacesTheSelectedPicture() throws {
        let dir = TempDir("change-picture")
        defer { dir.clean() }
        try Self.svg("red").write(to: URL(filePath: dir.path("a.svg")))
        try Self.svg("blue").write(to: URL(filePath: dir.path("b.svg")))
        for later in [false, true] {
            let h = DialogsHost()
            let r = try h.session.execute("insert.picture", ["path": .string(dir.path("a.svg"))])
            _ = try h.session.execute("edit.select", ["ids": [Self.id(r).toJSON()]])
            let before = Self.onlyPicture(h)
            h.holdPicks = later
            h.openPaths = [dir.path("b.svg")]
            h.run("app.changePictureDialog")
            if later {
                #expect(Self.onlyPicture(h) == before, "nothing changes before the panel answers")
                h.release(dir.path("b.svg"))
            }
            #expect(Self.onlyPicture(h) != before, later ? "a late answer" : "an answer at once")
        }
    }

    // lib.rs: home_shows_the_start_screen_over_the_open_presentation (#17). The Mac's Home is the template
    // gallery (a window of its own, so typing can't reach the presentation behind it): it opens over the open
    // presentation without making one, toggles, and picking a theme leaves it with a new presentation.
    @Test func homeShowsTheStartScreenOverTheOpenPresentation() {
        let h = DialogsHost()
        h.run("app.home")
        #expect(h.dialog?.id == "new")
        #expect(h.session.documents.count == 1, "Home doesn't create a presentation")
        h.run("app.home")
        #expect(h.dialog == nil, "Home again toggles")
        h.run("app.home", ["on": true])
        h.run("app.home", ["on": true])
        #expect(h.dialog?.id == "new", "{on: true} keeps it open")
        h.dialogs.press("new:blank")
        #expect(h.dialog == nil, "a new presentation leaves Home")
        #expect(h.session.documents.count == 2)
    }

    // lib.rs: title_bar_export_opens_the_export_dialog. Export… had no visible control; on the Mac it is the File
    // menu's Export…, which opens the Export sheet.
    @Test func titleBarExportOpensTheExportDialog() throws {
        let file = try #require(MenuTree.menus.first { $0.title == "File" })
        let export = file.entries.compactMap { e -> String? in
            if case .command("Export…", let id) = e { return id }
            return nil
        }
        #expect(export == ["app.exportDialog"])
        let h = DialogsHost()
        #expect(h.dialog == nil)
        h.run(try #require(export.first))
        #expect(h.dialog?.id == "export")
    }

    // lib.rs: web_export_all_slides_gives_one_file_per_slide (#64). deckcraft's browser download; the Mac's Export ›
    // PNG (all slides) writes one numbered file per slide through the save panel, PNG (current slide) one file.
    @Test func webExportAllSlidesGivesOneFilePerSlide() throws {
        let dir = TempDir("export-all")
        defer { dir.clean() }
        let h = DialogsHost()
        h.run("slide.new")
        h.run("slide.new")
        #expect(h.st?.doc.slides.count == 3)
        h.savePath = dir.path("Deck.png")
        #expect(h.dialogs.exportAs("pngAll", .emptyObject))
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
        #expect(all == ["Deck1.png", "Deck2.png", "Deck3.png"])
        let one = TempDir("export-one")
        defer { one.clean() }
        h.savePath = one.path("Deck.png")
        #expect(h.dialogs.exportAs("png", .emptyObject))
        #expect(try FileManager.default.contentsOfDirectory(atPath: one.url.path) == ["Deck.png"])
    }

    // lib.rs: web_png_export_can_leave_the_background_transparent (#784). The Mac's Export sheet (`export_as`, through
    // the save panel instead of a browser download): a transparent PNG leaves the slide background out, so the
    // corner is clear; a JPEG stays opaque (the sheet offers the checkbox for PNG only and doesn't pass it on).
    @Test func webPngExportCanLeaveTheBackgroundTransparent() throws {
        let dir = TempDir("export-alpha")
        defer { dir.clean() }
        let h = DialogsHost()
        func cornerAlpha(_ fmt: String, transparent: Bool, _ name: String) throws -> UInt8? {
            h.savePath = dir.path(name)
            h.run("app.exportDialog")
            h.dialogs.set("fmt", fmt)
            h.press("ok", ["pngTransparent": transparent ? "1" : "0"])
            #expect(h.dialog == nil && h.model.status == "Exported \(dir.path(name))", "\(h.model.status ?? "")")
            let bytes = [UInt8](try Data(contentsOf: URL(filePath: dir.path(name))))
            guard let img = Images.decode(bytes), img.width > 2, img.height > 2 else { return nil }
            return img.pixels.at((2 * img.width + 2) * 4 + 3)
        }
        #expect(try cornerAlpha("png", transparent: false, "a.png") == 255, "opaque by default")
        #expect(try cornerAlpha("png", transparent: true, "b.png") == 0, "transparent background")
        #expect(try cornerAlpha("jpeg", transparent: true, "c.jpg") == 255, "JPEG has no transparency")
    }

    // lib.rs: grid_options_sets_spacing_and_display_or_opens_the_dialog
    @Test func gridOptionsSetsSpacingAndDisplayOrOpensTheDialog() throws {
        let h = DialogsHost()
        #expect(h.session.prefs.gridSpacing == 6)
        let v = try h.run("view.gridOptions", ["spacing": 72.0, "snap": false, "smartGuides": false, "gridlines": true, "guides": true]).get()
        #expect(v["spacing"]?.asF64 == 72)
        #expect(v["snap"] == false && v["smartGuides"] == false && v["gridlines"] == true && v["guides"] == true)
        #expect(h.dialog == nil, "values given: no dialog")
        #expect(h.model.ui.gridlines && h.model.ui.guides)
        #expect(!h.session.prefs.snapToGrid && !h.model.ui.smartGuides)

        _ = try h.run("view.gridOptions", ["snap": true]).get()
        #expect(h.session.prefs.snapToGrid)
        #expect(h.session.prefs.gridSpacing == 72, "what isn't given is kept")
        #expect(h.dialog == nil)

        let bad: [JSON] = [["spacing": 0], ["spacing": 289], ["spacing": "72"], ["spacing": .null], ["snap": 1]]
        for p in bad {
            #expect(throws: CommandError.self, "rejected \(p)") { try h.run("view.gridOptions", p).get() }
        }
        #expect(h.session.prefs.gridSpacing == 72 && h.session.prefs.snapToGrid, "a refused call changes nothing")

        _ = try h.run("view.gridOptions").get()
        #expect(h.dialog?.id == "gridOptions", "no values: the dialog opens")
        #expect(h.session.prefs.gridSpacing == 72)
    }

    // lib.rs: grid_options_dialog_lists_spacing_and_display
    @Test func gridOptionsDialogListsSpacingAndDisplay() {
        let h = DialogsHost()
        h.run("view.gridOptions")
        let labels = h.dialogs.form.compactMap { row -> String? in
            switch row {
            case .check(let label, _), .text(let label, _, _): label
            default: nil
            }
        }
        for want in ["Display grid on screen", "Snap objects to grid", "Spacing (pt)"] {
            #expect(labels.contains { $0.contains(want) }, "\(want) in \(labels)")
        }
        h.dialogs.set("gridlines", "1")
        h.dialogs.press("ok")
        #expect(h.dialog == nil, "OK closes Grid Options")
        #expect(h.model.ui.gridlines, "OK applies the grid checkbox")
        #expect(h.session.prefs.gridSpacing == 6)

        h.run("view.gridOptions")
        h.dialogs.set("gridlines", "0")
        h.dialogs.press("cancel")
        #expect(h.dialog == nil, "Cancel closes Grid Options")
        #expect(h.model.ui.gridlines, "Cancel leaves the grid on")
        #expect(h.session.prefs.gridSpacing == 6)
    }

    // lib.rs: about_dialog_close_and_cancel_close_it. About has one button, Close; Esc and the window's close
    // button are Cancel.
    @Test func aboutDialogCloseAndCancelCloseIt() {
        let h = DialogsHost()
        h.run("app.about")
        #expect(h.dialog?.id == "about")
        h.dialogs.cancel()
        #expect(h.dialog == nil, "Cancel closes About")
        h.run("app.about")
        #expect(h.dialogs.buttons.map(\.label) == ["Close"])
        h.dialogs.press("ok")
        #expect(h.dialog == nil, "Close closes About")
    }

    // MARK: Language (#339)

    /// The first shape's first run's language on every slide.
    static func langs(_ h: DialogsHost) -> [String?] {
        h.st?.doc.slides.map { $0.shapes.first?.text?.paragraphs.first?.runs.first?.props.lang } ?? []
    }

    /// A deck whose title reads `first`, and a second slide titled `second` when given.
    static func titled(_ first: String, _ second: String? = nil) throws -> DialogsHost {
        let s = Session.withNew()
        let title = try #require(s.activeDoc?.doc.slides.first?.shapes.first?.id)
        _ = try s.execute("text.edit", ["id": title.toJSON()])
        _ = try s.execute("text.insert", ["text": .string(first)])
        if let second { _ = try s.execute("slide.new", ["title": .string(second)]) }
        return DialogsHost(s)
    }

    // lib.rs: the_language_dialog_marks_the_selected_text
    @Test func theLanguageDialogMarksTheSelectedText() throws {
        let h = try Self.titled("Bonjour")
        _ = try h.session.execute("text.selectAll")
        h.run("app.dialog", ["id": "language"])
        #expect(h.dialog?.value("scope") == "sel")
        h.dialogs.set("lang", "fr-FR")
        h.dialogs.press("ok")
        #expect(h.dialog == nil)
        #expect(Self.langs(h) == ["fr-FR"])
    }

    // lib.rs: the_language_dialog_marks_the_whole_presentation
    @Test func theLanguageDialogMarksTheWholePresentation() throws {
        let h = try Self.titled("Hola", "Adiós")
        let second = try #require(h.st?.doc.slides.at(1)?.shapes.first?.id)
        _ = try h.session.execute("text.edit", ["id": second.toJSON()])
        _ = try h.session.execute("text.selectAll")
        h.run("app.dialog", ["id": "language"])
        h.dialogs.set("scope", "all")
        h.dialogs.set("lang", "es-ES")
        h.dialogs.press("ok")
        #expect(h.dialog == nil)
        #expect(Self.langs(h) == ["es-ES", "es-ES"], "every text box, not only the selected one")
    }

    // lib.rs: the_language_dialog_marks_the_whole_presentation_with_nothing_selected
    @Test func theLanguageDialogMarksTheWholePresentationWithNothingSelected() throws {
        let h = try Self.titled("Hola", "Adiós")
        _ = try h.session.execute("edit.select", ["ids": []])
        #expect(h.st?.selection.text == nil && h.st?.selection.shapes.isEmpty == true)
        h.run("app.dialog", ["id": "language"])
        let scope = h.dialogs.form.compactMap { row -> [FormOption]? in
            if case .radio(_, "scope", let options) = row { return options }
            return nil
        }.first
        #expect(scope?.first { $0.value == "sel" }?.enabled == false, "Selected text can't be picked")
        h.dialogs.set("lang", "es-ES")
        h.dialogs.press("ok")
        #expect(h.dialog == nil)
        #expect(Self.langs(h) == ["es-ES", "es-ES"])
    }

    // MARK: Show

    // lib.rs: preview_hides_an_entrance_until_it_plays
    @Test func previewHidesAnEntranceUntilItPlays() throws {
        let s = Session.withNew()
        let text = Self.id(try s.execute("shape.insert", ["preset": "rect", "rect": [40, 40, 220, 80]]))
        _ = try s.execute("text.set", ["id": text.toJSON(), "text": "Alpha\nBeta"])
        _ = try s.execute("animation.set", ["effect": "fade", "duration": 1000])
        _ = try s.execute("animation.options", ["textBuild": "byParagraph"])
        var doc = try #require(s.activeDoc?.doc)
        var tl = ShowState.timeline(doc, 0)
        func para(_ time: Double, _ i: Int) -> ParaState? {
            ShowCoordinator.previewState(tl, text, time).paras.first { $0.0 == i }?.1
        }
        let p0 = try #require(para(0, 0)), p1 = try #require(para(0, 1))
        #expect(!p0.visible && !p1.visible, "entrances have not started")
        let mid = try #require(para(0.25, 0))
        #expect(mid.visible && mid.opacity > 0.05 && mid.opacity < 0.95, "\(mid)")
        #expect(para(0.25, 1)?.visible == false, "the next paragraph waits for its step")

        _ = try s.execute("animation.clear")
        let id = Self.id(try s.execute("shape.insert", ["preset": "rect", "rect": [400, 300, 120, 80]]))
        _ = try s.execute("shape.fill", ["id": id.toJSON(), "color": "#CC2200"])
        _ = try s.execute("animation.set", ["effect": "fade", "duration": 1000])
        doc = try #require(s.activeDoc?.doc)
        tl = ShowState.timeline(doc, 0)
        let size = (Int(doc.slideSize.width.rounded()), Int(doc.slideSize.height.rounded()))
        let timeline = tl
        func paint(_ time: Double?) -> Int {
            var opts = RenderOpts()
            opts.size = size
            if let time { opts.state = { ShowCoordinator.previewState(timeline, $0, time) } }
            let px = renderSlide(doc, 0, opts).straight(460, 340) ?? [0, 0, 0, 0]
            return Int(px[0]) - Int(max(px[1], px[2]))
        }
        let rest = paint(nil), start = paint(0), end = paint(tl.totalDuration + 0.05)
        #expect(rest > 40, "the shape is filled at rest: \(rest)")
        #expect(start < rest / 2, "hidden at the first preview frame: \(start) vs \(rest)")
        #expect(end > 40, "visible again once the sequence has played: \(end)")
    }

    /// A coordinator over a deck of three slides, the second hidden.
    static func threeSlides() throws -> ShowCoordinator {
        let s = Session.withNew()
        _ = try s.execute("slide.new")
        _ = try s.execute("slide.new")
        _ = try s.execute("slide.hide", ["index": 1, "hidden": true])
        return ShowCoordinator(model: AppModel(session: s))
    }

    // lib.rs: show_start_refuses_a_from_that_is_not_a_slide. `show.start {from}` naming no slide is refused instead
    // of starting at slide 0 or on the end screen; a hidden slide is a slide. (The control channel's `show.start`
    // runs the same command: DCAppTests' LibTests.)
    @Test func showStartRefusesAFromThatIsNotASlide() throws {
        let c = try Self.threeSlides()
        for from: JSON in [-1, 1.5, "1", 3, .uint(UInt64.max)] {
            guard case .failure? = c.command("show.start", ["from": from]) else {
                Issue.record("\(from) was accepted")
                continue
            }
            #expect(c.show == nil, "\(from)")
        }
        _ = try #require(c.command("show.start", ["from": 1])).get()
        #expect(c.show?.state.slide == 1 && c.show?.state.ended == false, "From Current Slide plays a hidden slide")
        c.endShow()
        _ = try #require(c.command("show.start", ["from": 2, "reading": true])).get()
        #expect(c.show?.state.slide == 2 && c.show?.reading == true)
        c.endShow()
    }

    // lib.rs: a_swipe_during_the_show_turns_the_page
    @Test func aSwipeDuringTheShowTurnsThePage() throws {
        let s = Session.withNew()
        _ = try s.execute("slide.new")
        _ = try s.execute("slide.go", ["index": 0])
        let c = ShowCoordinator(model: AppModel(session: s))
        c.startShow(from: 0, reading: false)
        _ = c.tick(10)
        let full = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let centre = CGPoint(x: 600, y: 400)
        _ = c.scroll(centre, full, zoomLines: nil, flick: (-24, 0), now: 11)
        #expect(c.show?.state.slide == 1, "a swipe left goes to the next slide")
        _ = c.scroll(centre, full, zoomLines: nil, flick: (24, 0), now: 11.5)
        #expect(c.show?.state.slide == 0, "a swipe right goes back")
    }

    // lib.rs: the_pen_ignores_a_swipe_during_the_show
    @Test func thePenIgnoresASwipeDuringTheShow() throws {
        let s = Session.withNew()
        _ = try s.execute("slide.new")
        _ = try s.execute("slide.go", ["index": 0])
        let c = ShowCoordinator(model: AppModel(session: s))
        c.startShow(from: 0, reading: false)
        _ = c.tick(10)
        _ = c.key(.p, ShowMods(command: true), presenter: false, now: 10.5)
        #expect(c.show?.pen == true, "⌘P takes the pen")
        _ = c.scroll(CGPoint(x: 600, y: 400), CGRect(x: 0, y: 0, width: 1200, height: 800), zoomLines: nil, flick: (-24, 0), now: 11)
        #expect(c.show?.state.slide == 0, "the page doesn't turn under the stroke")
    }
}
