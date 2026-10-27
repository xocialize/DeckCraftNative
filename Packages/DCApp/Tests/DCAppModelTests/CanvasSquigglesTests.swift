// DCAppModelTests — spelling squiggles and the Eyedropper without a window. Ported from deckcraft
// `crates/ui-egui/src/spelling_tests.rs` and `eyedropper_tests.rs` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct CanvasSquigglesTests {
    static let aff = "SET UTF-8\nTRY esianrtolcdugmphbyfvkwzxjq\nSFX S Y 1\nSFX S 0 s .\n"

    // spelling_tests.rs: squiggles_mark_misspelt_words_in_the_background
    @Test func squigglesMarkMisspeltWordsButNotTheWordBeingTyped() throws {
        let dic = "7\nthe/S\nslide/S\nquarter/S\nplan/S\nour\nfor\nreview\n"
        Spell.install("xx-SQ", SpellDictionary.parse(Array(Self.aff.utf8), Array(dic.utf8)))
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        let r = try app.session.execute("shape.insert", ["preset": "rect", "rect": [80, 120, 700, 160], "text": "Our plna for teh quarter reveiw"])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        app.run("format.size", ["size": 40])
        app.run("format.languageAll", ["lang": "xx-SQ"])
        app.run("edit.select", ["ids": []])
        let squiggles = CanvasSquiggles()
        var st = try #require(app.session.activeDoc)
        let lines = squiggles.settle(st)
        #expect(lines.count == 3, "plna, teh, reveiw: \(lines)")
        // The context menu's word under the first squiggle, and its correction.
        let a = try #require(lines.first).0
        let w = try #require(squiggles.wordAt(st, Point(a.x + 5, a.y - 5), 2))
        #expect(w.word == "plna")
        #expect(w.suggestions.first == "plan")
        let menu = CanvasContextMenu.entries(app.session, word: w, guidesOn: false)
        guard case .item(_, let fix, _, _, let bold)? = CanvasMenuEntry.find(menu, "plan") else {
            Issue.record("no suggestion in \(menu)")
            return
        }
        #expect(bold, "suggestions are bold, as PowerPoint shows them")
        #expect(CanvasMenuEntry.find(menu, "Ignore All") != nil && CanvasMenuEntry.find(menu, "Add to Dictionary") != nil)
        CanvasContextMenu.perform(fix, app, squiggles: squiggles)
        #expect(app.session.activeDoc?.shape(id)?.text?.text == "Our plan for teh quarter reveiw")
        st = try #require(app.session.activeDoc)
        #expect(squiggles.settle(st).count == 2)
        // Ignore All skips the word for the session.
        CanvasContextMenu.perform(.ignoreAll("reveiw"), app, squiggles: squiggles)
        #expect(squiggles.settle(st).count == 1)
        // Typing at the end of a misspelt word: no squiggle under it until the caret leaves.
        app.run("edit.select", ["ids": [id.toJSON()]])
        app.run("text.edit")
        app.run("text.select", ["anchor": [0, 16], "caret": [0, 16]])
        st = try #require(app.session.activeDoc)
        #expect(st.selection.text?.caret == TextPoint(0, 16))
        #expect(squiggles.settle(st).isEmpty, "the word being typed isn't marked")
    }

    // spelling_tests.rs: squiggles_in_table_cells_and_notes_and_on_the_ui_thread
    @Test func squigglesInTableCellsAndNotesAFewMillisecondsAtATime() throws {
        let dic = "10\nthe/S\nplan/S\nsales\nregion/S\ntotal/S\nnorth\nsouth\nremember\nto\nshow\n"
        Spell.install("xx-TB", SpellDictionary.parse(Array(Self.aff.utf8), Array(dic.utf8)))
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        let r = try app.session.execute("insert.table", [
            "rows": 2, "cols": 2, "rect": [80, 80, 600, 160], "data": [["Regoin", "Sales"], ["North", "Soth totals"]],
        ])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        app.run("format.languageAll", ["lang": "xx-TB"])
        app.run("edit.select", ["ids": []])
        let squiggles = CanvasSquiggles()
        let st = try #require(app.session.activeDoc)
        // One pass with no budget does part of the work; the canvas asks for more passes while busy.
        _ = squiggles.update(st, budgetMs: 0)
        let lines = squiggles.settle(st)
        #expect(!squiggles.busy)
        #expect(lines.count == 2, "Regoin and Soth: \(lines)")
        if lines.count == 2 {
            // Each under its own cell: the first in the top-left one, the second in the bottom-right one.
            #expect(lines[0].0.x < 380 && lines[0].0.y < 160 && lines[1].0.x > 380 && lines[1].0.y > 160, "\(lines)")
        }
        var notes: [(Int, Int)] = []
        for _ in 0 ..< 100 where notes.isEmpty { notes = squiggles.notes("Remmeber to show the totl", lang: "xx-TB", caret: nil, budgetMs: 50) }
        #expect(notes.map { [$0.0, $0.1] } == [[0, 8], [21, 25]])
        let a = try #require(lines.first).0
        let w = try #require(squiggles.wordAt(st, Point(a.x + 3, a.y - 5), 2))
        #expect(w.word == "Regoin" && w.suggestions.first == "Region")
        let p = try #require(CanvasSquiggles.changeParams(w, to: "Region"))
        #expect(p["row"]?.asU64 == 0 && p["col"]?.asU64 == 0 && p["shape"]?.asU64 == UInt64(id.rawValue))
        app.run("review.spellingChange", p)
        #expect(squiggles.settle(try #require(app.session.activeDoc)).count == 1)
    }

    /// A repeated word offers Delete Repeated Word, which takes the gap with it.
    @Test func aRepeatedWordOffersDeleteRepeatedWord() throws {
        let dic = "3\nthe\nplan\nis\n"
        Spell.install("xx-RW", SpellDictionary.parse(Array(Self.aff.utf8), Array(dic.utf8)))
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        let r = try app.session.execute("shape.insert", ["preset": "rect", "rect": [80, 120, 700, 160], "text": "the the plan"])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        app.run("format.languageAll", ["lang": "xx-RW"])
        app.run("edit.select", ["ids": []])
        let squiggles = CanvasSquiggles()
        let st = try #require(app.session.activeDoc)
        let lines = squiggles.settle(st)
        let a = try #require(lines.first).0
        let w = try #require(squiggles.wordAt(st, Point(a.x + 3, a.y - 5), 2))
        #expect(w.deleteFrom == 3 && w.suggestions.isEmpty)
        guard case .item(_, let del, _, _, _)? = CanvasMenuEntry.find(CanvasContextMenu.entries(app.session, word: w, guidesOn: false), "Delete Repeated Word") else {
            Issue.record("no Delete Repeated Word")
            return
        }
        CanvasContextMenu.perform(del, app, squiggles: squiggles)
        #expect(app.session.activeDoc?.shape(id)?.text?.text == "the plan")
        #expect(squiggles.menuWord == nil)
    }

    /// Languages for Review › Language, by name.
    @Test func languageNames() {
        #expect(CanvasSquiggles.languageName("en-gb") == "English (United Kingdom)")
        #expect(CanvasSquiggles.languageName("xx-YY") == "xx-YY")
    }

    // eyedropper_tests.rs: a_click_on_the_slide_takes_the_colour_under_it_and_nothing_else_happens
    @Test func theEyedropperTakesTheColourUnderTheClick() throws {
        let app = AppModel(session: Session.withNew())
        app.run("slide.new", ["layout": "blank"])
        app.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
        app.run("shape.fill", ["color": "#ff0000"])
        let before = app.session.activeDoc?.selection.shapes
        let revision = app.session.activeDoc?.revision
        var taken: String?
        let e = try CanvasEyedropper.begin(app.session, .color { taken = $0 }).get()
        #expect(e.prompt.hasPrefix("Eyedropper"))
        #expect(e.color(at: Point(150, 150)).map(CanvasEyedropper.hex) == "FF0000", "the loupe shows the red under the pointer")
        e.click(app, Point(150, 150))
        #expect(taken == "FF0000", "the colour goes to whoever asked")
        #expect(app.session.activeDoc?.selection.shapes == before, "the click did not select or move anything")
        #expect(app.session.activeDoc?.revision == revision)
        #expect(e.color(at: Point(.nan, 1)) == nil)
    }

    // eyedropper_tests.rs: the Eyedropper takes colours from a slide only
    @Test func theEyedropperNeedsASlide() {
        let s = Session.withNew()
        _ = try? s.execute("view.slideMaster", .emptyObject)
        guard case .failure(let e) = CanvasEyedropper.begin(s, .transparentColor) else {
            Issue.record("the Eyedropper started on a master")
            return
        }
        #expect(e.message == "The Eyedropper takes colours from a slide")
    }
}
