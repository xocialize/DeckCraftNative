// DCAppTests — the tests of deckcraft `crates/ui-egui/src/lib.rs` that need real views, in-process: keys and
// scroll events into the canvas, the notes pane, the pasteboard, Select All by focus, New Window and the
// control channel's `show.start` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Each test
// names its source, Rust names in camelCase; the triage of all 62 is in PORT-NOTES.md ("lib.rs tests").
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct LibTests {
    typealias Fixture = CanvasViewTests.Fixture

    // MARK: Keys and the wheel on the canvas

    // lib.rs: tab_in_an_edited_list_keeps_the_keyboard (#93). Tab indents the item and the canvas keeps the
    // keyboard, so typing and Enter go on reaching the text.
    @Test func tabInAnEditedListKeepsTheKeyboard() throws {
        let f = Fixture()
        f.model.session.prefs.autocorrect = false
        let r = try f.model.session.execute("insert.textBox", ["rect": [100, 250, 400, 150], "text": ""])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        f.model.run("text.edit", ["id": id.toJSON()])
        let none = NSRange(location: NSNotFound, length: 0)
        let enter = try #require(f.key("\r", code: 36)), tab = try #require(f.key("\t", code: 48))
        f.canvas.insertText("one", replacementRange: none)
        f.canvas.keyDown(with: enter)
        f.canvas.keyDown(with: tab)
        #expect(f.window.firstResponder === f.canvas, "Tab doesn't hand the keyboard to another view")
        f.canvas.insertText("sub", replacementRange: none)
        f.canvas.keyDown(with: enter)
        f.canvas.insertText("two", replacementRange: none)
        let body = try #require(f.model.session.activeDoc?.shape(id)?.text)
        #expect(body.text == "one\nsub\ntwo", "typing after Tab must reach the text")
        #expect(body.paragraphs.map(\.level) == [0, 1, 1], "Tab indents one level; Enter keeps the level")
    }

    /// A scroll event: a mouse wheel's lines, or a trackpad's points in gesture `phase`.
    static func scroll(_ dx: Int32, _ dy: Int32, trackpad: Bool, phase: CGScrollPhase? = nil) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: trackpad ? .pixel : .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return nil
        }
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        return NSEvent(cgEvent: cg)
    }

    /// A canvas fitted at 40 % (a flick turns the page) on a deck of `slides`, on the first slide.
    static func flickFixture(_ slides: Int, zoom: Double = 0.4) -> Fixture {
        let f = Fixture(zoom: zoom)
        for _ in 1 ..< slides { f.model.run("slide.new") }
        f.model.run("slide.go", ["index": 0])
        f.vc.refresh()
        return f
    }

    static func slide(_ f: Fixture) -> Int? { f.model.session.activeDoc?.selection.slide }

    // lib.rs: mouse_wheel_over_a_zoomed_canvas_pans_and_outside_the_canvas_does_not_navigate. Over a zoomed slide the
    // canvas leaves the wheel to its NSScrollView, which pans (AppKit's own scrolling, as the canvas.rs scroll-bar
    // tests are), and the page never turns. Outside the canvas AppKit sends the wheel to the view under the
    // pointer, so the canvas never sees it.
    @Test func mouseWheelOverAZoomedCanvasPansAndOutsideTheCanvasDoesNotNavigate() throws {
        let f = Self.flickFixture(2, zoom: 3)
        let e = try #require(Self.scroll(0, -3, trackpad: false))
        #expect(!f.canvas.wheel(e), "the canvas leaves a zoomed slide's wheel to the scroll view")
        f.vc.scroll.scrollWheel(with: e)
        #expect(Self.slide(f) == 0, "the wheel doesn't turn the page")
        f.model.ui.zoom = 0.4
        f.vc.refresh()
        #expect(f.canvas.wheel(e), "fitted, the same notch is the canvas's")
        #expect(Self.slide(f) == 1, "and turns the page")
    }

    // lib.rs: a_sideways_trackpad_swipe_turns_the_page_and_a_second_flick_waits
    @Test func aSidewaysTrackpadSwipeTurnsThePageAndASecondFlickWaits() throws {
        let f = Self.flickFixture(3)
        #expect(f.canvas.wheel(try #require(Self.scroll(-24, 0, trackpad: true, phase: .began))))
        #expect(Self.slide(f) == 1, "swipe left goes to the next slide")
        _ = f.canvas.wheel(try #require(Self.scroll(-24, 0, trackpad: true, phase: .changed)))
        #expect(Self.slide(f) == 1, "the next event of the same gesture does not skip a slide")
        _ = f.canvas.wheel(try #require(Self.scroll(-24, 0, trackpad: true, phase: .began)))
        #expect(Self.slide(f) == 1, "a second flick straight after waits")
        // Blocks the main thread (no other test's main-actor work runs meanwhile) past the cooldown.
        Thread.sleep(forTimeInterval: CanvasMetrics.flickCooldown + 0.1)
        _ = f.canvas.wheel(try #require(Self.scroll(24, 0, trackpad: true, phase: .began)))
        #expect(Self.slide(f) == 0, "swipe right goes back")
    }

    // lib.rs: a_vertical_wheel_still_turns_the_page_and_a_zoomed_slide_pans_instead
    @Test func aVerticalWheelStillTurnsThePageAndAZoomedSlidePansInstead() throws {
        let f = Self.flickFixture(2)
        _ = f.canvas.wheel(try #require(Self.scroll(-2, -24, trackpad: true, phase: .began)))
        #expect(Self.slide(f) == 1, "a vertical flick still goes to the next slide")
        f.model.ui.zoom = 3
        f.model.run("slide.go", ["index": 0])
        f.vc.refresh()
        #expect(!f.canvas.wheel(try #require(Self.scroll(-24, 0, trackpad: true, phase: .began))), "zoomed in, the scroll view pans")
        #expect(Self.slide(f) == 0, "zoomed in, a sideways swipe doesn't turn the page")
    }

    // MARK: Notes

    // lib.rs: editing_notes_in_the_pane_keeps_their_formatting. Typing into a bold heading, Enter after a
    // bulleted point, then saving as .pptx and reopening.
    @Test func editingNotesInThePaneKeepsTheirFormatting() throws {
        var bold = RunProps()
        bold.bold = true
        var pointProps = ParaProps()
        pointProps.marginLeft = 22.5
        pointProps.indent = -22.5
        pointProps.bullet = .char(char: "§")
        pointProps.bulletFont = "Wingdings"
        func run(_ t: String, _ p: RunProps = RunProps()) -> Run { Run(text: t, props: p, kind: .text) }
        let notes = TextBody(paragraphs: [
            Paragraph(runs: [run("Metodický prehľad", bold)]),
            Paragraph(runs: [run("Žiaci pracujú vo dvojiciach.")]),
            Paragraph(level: 1, props: pointProps, runs: [run("Cieľ: ", bold), run("vysvetliť cyklus")]),
            Paragraph(level: 1, props: pointProps, runs: [run("Reflexia")]),
            Paragraph(runs: [run("Pomôcky: počítač")]),
        ])
        let s = Session.withNew()
        _ = try s.execute("slide.notes", ["index": 0, "body": notes.toJSON()])
        let m = AppModel(session: s)
        let uid = try #require(s.activeDoc?.uid)
        let pane = NotesPaneController(link: DocLink(model: m, uid: { uid }))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = pane
        defer { w.close() }
        pane.refresh()
        let tv = pane.editor.textView
        #expect(tv.string == notes.text)
        func type(_ text: String) {
            tv.string = text
            pane.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        }
        type(tv.string.replacingOccurrences(of: "prehľad", with: "prehľad hodiny"))
        type(tv.string.replacingOccurrences(of: "cyklus", with: "cyklus\nNový bod"))
        // Leaving the field saves the notes.
        pane.editor.save()
        func check(_ n: TextBody?, _ when: String) {
            guard let n, n.paragraphs.count == 6 else {
                Issue.record("\(when): \(String(describing: n?.text))")
                return
            }
            #expect(n.text == "Metodický prehľad hodiny\nŽiaci pracujú vo dvojiciach.\nCieľ: vysvetliť cyklus\nNový bod\nReflexia\nPomôcky: počítač", "\(when)")
            #expect(n.paragraphs[0].runs.count == 1 && n.paragraphs[0].runs.first?.props.bold == true, "\(when): the heading stays bold")
            #expect(n.paragraphs[1].props == ParaProps(), "\(when)")
            #expect(n.paragraphs[2].runs.first?.props.bold == true, "\(when): the bold label")
            #expect(n.paragraphs[2].runs.at(1)?.props.bold == nil, "\(when)")
            for i in [2, 3, 4] {
                #expect(n.paragraphs[i].level == 1 && n.paragraphs[i].props == pointProps, "\(when): point \(i)")
            }
            #expect(n.paragraphs[5].level == 0 && n.paragraphs[5].props == ParaProps(), "\(when)")
        }
        check(s.activeDoc?.doc.slides.first?.notes, "saved")
        let data = try s.execute("file.saveBytes", ["format": "pptx"])["data"] ?? .null
        _ = try s.execute("file.openBytes", ["name": "notes.pptx", "data": data])
        check(s.activeDoc?.doc.slides.first?.notes, "reopened")
    }

    // MARK: Pasteboard

    func board() -> PasteboardBridge { PasteboardBridge(board: NSPasteboard(name: NSPasteboard.Name("dc-lib-test-\(UUID().uuidString)"))) }

    /// A model on a new presentation with a text box reading `text` (not being edited) and its id.
    func textBox(_ text: String) throws -> (AppModel, ShapeId) {
        let s = Session.withNew()
        _ = try s.execute("slide.layout", ["layout": "blank"])
        let r = try s.execute("insert.textBox", ["rect": [80, 120, 400, 100], "text": .string(text)])
        _ = try? s.execute("text.exit")
        return (AppModel(session: s), ShapeId(UInt32(r["id"]?.asU64 ?? 0)))
    }

    // lib.rs: copy_and_cut_commands_reach_the_system_clipboard (#431). Copy and Cut run from anywhere (a menu, the
    // context menu, the control channel) put the text on the pasteboard, once; Cut also removes the shape.
    @Test func copyAndCutCommandsReachTheSystemClipboard() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, id) = try textBox("Aurora")
        pb.board.clearContents()
        pb.flushPending(m)
        #expect(pb.board.string(forType: .string) == nil, "nothing copied yet")
        m.run("edit.copy")
        pb.flushPending(m)
        #expect(pb.board.string(forType: .string) == "Aurora", "Copy puts the text on the pasteboard")
        let change = pb.board.changeCount
        pb.flushPending(m)
        #expect(pb.board.changeCount == change, "only once")
        m.run("edit.cut")
        pb.flushPending(m)
        #expect(pb.board.string(forType: .string) == "Aurora", "Cut does too")
        #expect(pb.board.changeCount != change)
        #expect(m.session.activeDoc?.shape(id) == nil, "and removes the shape")
    }

    // lib.rs: copy_offers_html_and_paste_keeps_bold — the copy half (the paste half is ViewsWindowTests'
    // textAndHtmlFromAnotherAppPasteAsText).
    @Test func copyOffersHtmlAndPasteKeepsBold() throws {
        let pb = board()
        defer { pb.board.releaseGlobally() }
        let (m, id) = try textBox("Hi")
        m.run("text.edit", ["id": id.toJSON()])
        m.run("text.selectAll")
        m.run("format.bold", ["on": true])
        _ = try pb.copy(m, cut: false, slides: false).get()
        let html = try #require(pb.board.string(forType: .html), "HTML offered")
        #expect(html.contains("<b>"), "\(html)")
        #expect(pb.board.string(forType: .string) == "Hi")
    }

    // MARK: Select All

    // lib.rs: select_all_follows_the_focused_pane (#188). ⌘A with the slide navigator focused selects every slide;
    // with the canvas focused it selects shapes.
    @Test func selectAllFollowsTheFocusedPane() throws {
        let f = Fixture()
        f.model.run("slide.new")
        f.model.run("slide.new")
        f.model.run("slide.go", ["index": 0])
        f.model.run("edit.deselect")
        let uid = try #require(f.model.session.activeDoc?.uid)
        let nav = NavigatorViewController(link: DocLink(model: f.model, uid: { uid }))
        let nw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 236, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        nw.isReleasedWhenClosed = false
        nw.contentViewController = nav
        defer {
            nw.close()
            f.window.close()
        }
        nav.refresh()
        // The window with the keyboard is the key window's in the app; a test process has no key window, so the
        // first responder is handed over as the menu would find it.
        nw.makeFirstResponder(nav.table)
        _ = try PasteboardBridge.shared.menuCommand(f.model, "edit.selectAll", .emptyObject, responder: nw.firstResponder).get()
        #expect(f.model.session.activeDoc?.selection.slides.count == 3, "every slide is selected")
        _ = try PasteboardBridge.shared.menuCommand(f.model, "edit.selectAll", .emptyObject, responder: f.window.firstResponder).get()
        #expect(f.model.session.activeDoc?.selection.shapes.isEmpty == false, "the canvas's Select All picks the shapes")
    }

    // MARK: New Window

    // lib.rs: new_window_shows_the_same_document_on_its_own_slide. Its slide is its own; opening it again keeps
    // that slide; closing the presentation closes it.
    @Test func newWindowShowsTheSameDocumentOnItsOwnSlide() throws {
        defer { ViewsFeature.docWindow?.close() }
        guard case .failure(let e) = ViewsFeature.newWindow(AppModel(session: Session()), .emptyObject) else {
            Issue.record("New Window opened with nothing open")
            return
        }
        #expect(e.message.contains("presentation"), "\(e.message)")
        let s = Session.withNew()
        _ = try s.execute("slide.new")
        _ = try s.execute("slide.go", ["index": 1])
        let m = AppModel(session: s)
        let name = try #require(s.activeDoc?.displayTitle)
        let opened = try ViewsFeature.newWindow(m, .emptyObject).get()
        #expect(opened["open"] == true && opened["window"]?.asU64 == 2 && opened["slide"]?.asU64 == 1)
        #expect(opened["title"]?.asStr == "\(name):2")
        let moved = try ViewsFeature.newWindow(m, ["delta": -1]).get()
        #expect(moved["slide"]?.asU64 == 0 && ViewsFeature.docWindow?.state.slide == 0)
        #expect(s.activeDoc?.selection.slide == 1, "the editor stays on its slide")
        let again = try ViewsFeature.newWindow(m, .emptyObject).get()
        #expect(again["window"]?.asU64 == 2 && again["slide"]?.asU64 == 0, "opening again keeps the window's slide")
        m.run("file.close")
        ViewsFeature.modelChanged(m)
        #expect(ViewsFeature.docWindow == nil, "closing the presentation closes the extra window")
        #expect(s.activeDoc == nil)
    }

    // MARK: The show over the control channel

    // lib.rs: show_start_refuses_a_from_that_is_not_a_slide — the control channel's half (the command's is
    // DCAppModelTests' LibTests). Reading View starts where `from` says too.
    @Test func showStartRefusesAFromThatIsNotASlide() throws {
        _ = NSApplication.shared
        let app = AppController()
        app.syncSuspended += 1
        guard ShowMetal.shared != nil, let coord = ShowFeature.coordinator else { return }
        app.model.run("file.new")
        app.model.run("slide.new")
        app.model.run("slide.new")
        app.model.run("slide.hide", ["index": 1, "hidden": true])
        app.model.run("slide.go", ["index": 0])
        func call(_ p: JSON) -> JSON {
            guard let h = app.controlHandlers["show.start"], case .done(let v) = h(p) else { return .null }
            return v
        }
        defer { coord.endShow() }
        for from: JSON in [-1, 1.5, "1", 3, .uint(UInt64.max)] {
            for reading in [false, true] {
                #expect(call(["from": from, "reading": .bool(reading)])["ok"] == false, "\(from) reading \(reading)")
                #expect(coord.show == nil, "\(from)")
            }
        }
        #expect(call(["from": 1, "windowed": true])["ok"] == true)
        #expect(coord.show?.state.slide == 1 && coord.show?.state.ended == false, "a hidden slide is a slide")
        coord.endShow()
        #expect(call(["from": 2, "reading": true])["ok"] == true)
        #expect(coord.show?.state.slide == 2 && coord.show?.reading == true, "Reading View from slide 3")
    }
}
