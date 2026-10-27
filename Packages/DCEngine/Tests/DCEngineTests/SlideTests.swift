// DCEngineTests — slides: new, duplicate, delete, move, layouts, ranges, sections, outlines.
// Ports the tests of deckcraft crates/engine/src/cmd/slide.rs and the slide tests of tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCModel
import Testing

private func deckOf(_ n: Int) -> Session {
    let s = session()
    while s.st.doc.slides.count < n { s.run("slide.new") }
    return s
}

private func selectedIndices(_ s: Session) -> [Int] {
    s.st.selection.slides.compactMap { s.st.doc.slideIndex($0) }.sorted()
}

/// Each slide as (title, [(level, bullet text)]).
private func outlineOf(_ p: Presentation) -> [(String, [(UInt8, String)])] {
    p.slides.map { s in (s.title, s.shapes.at(1)?.text.map { t in t.paragraphs.map { ($0.level, $0.text) } } ?? []) }
}

private func same(_ a: [(String, [(UInt8, String)])], _ b: [(String, [(UInt8, String)])]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { x, y in
        x.0 == y.0 && x.1.count == y.1.count && zip(x.1, y.1).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

private let mdOutline = "# Intro\n- Point one\n- Point two\n  - Sub point\n\n# Second\n- More\n"
private let mdExpected: [(String, [(UInt8, String)])] = [
    ("Intro", [(0, "Point one"), (0, "Point two"), (1, "Sub point")]),
    ("Second", [(0, "More")]),
]

@Suite("Slides")
struct SlideTests {
    @Test func invalidIndexParamsAreRejectedNotDefaultedToSelection() {
        let s = deckOf(3)
        for bad in ["-1", "1.5"] {
            for (cmd, p) in [
                ("slide.delete", "{\"index\": \(bad)}"), ("slide.duplicate", "{\"index\": \(bad)}"),
                ("slide.move", "{\"from\": \(bad), \"to\": 0}"), ("section.add", "{\"at\": \(bad)}"),
            ] {
                #expect(s.fails(cmd, p), "\(cmd) must reject \(p)")
                #expect(s.st.doc.slides.count == 3, "\(cmd) \(p)")
            }
        }
    }

    @Test func duplicateKeepsSectionOrderInStepWithSlides() {
        let s = deckOf(3)
        s.run("section.add", #"{"at": 0}"#)
        let orig = s.st.doc.slides[0].id
        s.run("slide.duplicate", #"{"index": 0}"#)
        let all = s.st.doc.slides.map(\.id)
        let sec = s.st.doc.sections.first?.slides ?? []
        #expect(all.count == 4)
        #expect(sec == all, "section order must match slide order")
        #expect(sec.first == orig)
    }

    @Test func newSlideBodyLeadingTabsBecomeLevels() {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "Indent", "body": "Level one\n\tLevel two\n\t\tLevel three\nLevel one again"}"#)
        let slide = s.st.doc.slides[s.st.selection.slide]
        let body = slide.shapes.first { $0.phType.map { !$0.isTitle } ?? false }
        let got = body?.text?.paragraphs.map { ($0.level, $0.text) } ?? []
        let want: [(UInt8, String)] = [(0, "Level one"), (1, "Level two"), (2, "Level three"), (0, "Level one again")]
        #expect(got.count == want.count && zip(got, want).allSatisfy { $0 == $1 })
    }

    @Test func selectRangeCoversEverySlideBetween() {
        let s = deckOf(6)
        s.run("slide.go", #"{"index": 1}"#)
        s.run("slide.selectRange", #"{"to": 4}"#)
        #expect(selectedIndices(s) == [1, 2, 3, 4])
        #expect(s.st.selection.slide == 4)
        // Backwards works too, and replaces the earlier selection.
        s.run("slide.selectRange", #"{"from": 5, "to": 3}"#)
        #expect(selectedIndices(s) == [3, 4, 5])
    }

    @Test func selectRangeAddKeepsTheExistingSelection() {
        let s = deckOf(8)
        s.run("slide.selectSlides", #"{"indices": [0, 1]}"#)
        s.run("slide.go", #"{"index": 4}"#)
        s.run("slide.selectSlides", #"{"indices": [4]}"#)
        s.run("slide.selectRange", #"{"to": 6, "add": true}"#)
        #expect(selectedIndices(s) == [4, 5, 6])
        s.run("slide.selectSlides", #"{"indices": [0]}"#)
        s.run("slide.selectRange", #"{"from": 3, "to": 5, "add": true}"#)
        #expect(selectedIndices(s) == [0, 3, 4, 5])
    }

    @Test func selectRangeRejectsOutOfRangeSlides() {
        let s = deckOf(3)
        #expect(s.fails("slide.selectRange", #"{"to": 3}"#))
        #expect(s.fails("slide.selectRange", #"{"from": 9, "to": 1}"#))
        #expect(s.fails("slide.selectRange", "{}"))
    }

    @Test func selectRangeRejectsAnInvalidFromInsteadOfUsingTheCurrentSlide() {
        let s = deckOf(4)
        s.run("slide.go", #"{"index": 2}"#)
        #expect(s.fails("slide.selectRange", #"{"from": -1, "to": 3}"#))
        #expect(s.fails("slide.selectRange", #"{"from": "x", "to": 3}"#))
        #expect(selectedIndices(s) == [2])
    }

    @Test func aSecondRangeExtendsFromTheOriginalAnchor() {
        let s = deckOf(8)
        s.run("slide.go", #"{"index": 2}"#)
        s.run("slide.selectRange", #"{"to": 5}"#)
        #expect(selectedIndices(s) == [2, 3, 4, 5])
        // Shift-click further on: still anchored at 2, not at 5.
        s.run("slide.selectRange", #"{"to": 7}"#)
        #expect(selectedIndices(s) == [2, 3, 4, 5, 6, 7])
        // Shift-click back across the anchor.
        s.run("slide.selectRange", #"{"to": 0}"#)
        #expect(selectedIndices(s) == [0, 1, 2])
        // A plain click on another slide starts a new anchor.
        s.run("slide.go", #"{"index": 4}"#)
        s.run("slide.selectRange", #"{"to": 6}"#)
        #expect(selectedIndices(s) == [4, 5, 6])
    }

    @Test func movingASlideDropsTheRangeAnchor() {
        let s = deckOf(6)
        s.run("slide.go", #"{"index": 0}"#)
        s.run("slide.selectRange", #"{"to": 2}"#)
        // Slide 0 moves to index 2 and stays current; index 0 now holds another slide, so the next
        // Shift-click starts at the moved slide instead of at index 0.
        s.run("slide.move", #"{"from": 0, "to": 2}"#)
        #expect(s.st.selection.slide == 2)
        s.run("slide.selectRange", #"{"to": 4}"#)
        #expect(selectedIndices(s) == [2, 3, 4])
    }

    @Test func selectRangeClearsATableCellSelectionAndReturnsToTheSlides() throws {
        let s = deckOf(3)
        try s.select { _, sel in
            sel.cells = CellRange(ShapeId(1), TextPoint(0, 0), TextPoint(1, 1))
            sel.target = .master(master: 0)
        }
        s.run("slide.selectRange", #"{"to": 2}"#)
        #expect(s.st.selection.cells == nil)
        #expect(s.st.selection.target == .slides)
    }

    @Test(.enabled(if: ported("text.set")))
    func newSlideBodyTabsMatchTextSet() {
        let body = "Install from DMG\nLaunch app\n\tCheck signing\n\t\tDeep\nBuild a deck"
        let s = session()
        s.run("slide.new", JSON.object(JSONObject(["layout": "titleAndContent", "title": "Test Plan", "body": .string(body)])).display)
        func levels() -> (UInt32, [(UInt8, String)]) {
            let sh = s.st.currentSlide?.shapes.first { $0.phType == .obj }
            return (sh?.id.rawValue ?? 0, sh?.text?.paragraphs.map { ($0.level, $0.text) } ?? [])
        }
        let (id, fromNew) = levels()
        let want: [(UInt8, String)] = [(0, "Install from DMG"), (0, "Launch app"), (1, "Check signing"), (2, "Deep"), (0, "Build a deck")]
        #expect(fromNew.count == want.count && zip(fromNew, want).allSatisfy { $0 == $1 })
        s.run("text.set", JSON.object(JSONObject(["id": .integer(id), "text": .string(body)])).display)
        #expect(levels().1.count == want.count && zip(levels().1, want).allSatisfy { $0 == $1 })
        s.run("text.set", "{\"id\": \(id), \"text\": \"\\t\\t\\t\\t\\t\\t\\t\\t\\tCapped\"}")
        let capped = levels().1
        #expect(capped.count == 1 && capped.first?.0 == 8 && capped.first?.1 == "Capped")
    }

    @Test func layoutChangeKeepsText() {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "T", "body": "B"}"#)
        s.run("slide.layout", #"{"layout": "twoContent"}"#)
        let v = s.run("slide.inspect")
        let texts = v.get("shapes")?.asArray?.compactMap { $0.get("text")?.asStr } ?? []
        #expect(texts.contains("T") && texts.contains("B"), "\(v.display)")
        #expect(v.get("layout") == "Two Content")
    }

    /// #725: a layout with a small body placeholder ahead of its content placeholder (as Keynote exports
    /// "Title & Bullets") still gets the body in the content placeholder (`idx="1"`).
    @Test(arguments: [true, false])
    func newSlideBodyGoesToTheContentPlaceholder(_ before: Bool) throws {
        let s = session()
        var doc = s.st.doc
        let raw = doc.allocId()
        let id = ShapeId(try #require(raw))
        let li = try #require(doc.masters[0].layouts.firstIndex { $0.kind == .titleAndContent })
        var lay = doc.masters[0].layouts[li]
        let at = try #require(lay.shapes.firstIndex { $0.ph?.idx == 1 })
        var small = lay.shapes[at]
        small.id = id
        small.name = "Subtitle 21"
        small.ph?.kind = .body
        small.ph?.idx = 21
        small.ph?.size = "quarter"
        lay.shapes.insert(small, at: before ? at : at + 1)
        doc.masters[0].layouts[li] = lay
        s.st.docRef = DocRef(doc)
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "T", "body": "Line one\nLine two"}"#)
        let slide = try #require(s.st.doc.slides.last)
        func text(_ idx: UInt32) -> String { slide.shapes.first { $0.ph?.idx == idx }?.text?.text ?? "" }
        #expect(text(1) == "Line one\nLine two", "before = \(before)")
        #expect(text(21) == "", "before = \(before)")
    }

    @Test(arguments: [false, true])
    func slidesFromOutlineJoinTheSectionOfTheSlideTheyFollow(_ markdown: Bool) {
        let s = session()
        s.run("slide.new", #"{"title": "A"}"#)
        s.run("section.add", #"{"name": "B", "at": 1}"#)
        let text = markdown ? "# Imported\\n- bullet" : "Imported\\n\\tbullet"
        s.run("slide.fromOutline", "{\"text\": \"\(text)\", \"markdown\": \(markdown)}")
        let doc = s.st.doc
        let orphans = doc.slides.map(\.id).filter { doc.sectionOf($0) == nil }
        #expect(orphans.isEmpty, "markdown=\(markdown): slides in no section: \(orphans)")
        #expect(doc.sections.flatMap(\.slides) == doc.slides.map(\.id), "markdown=\(markdown): sections follow the slide order")
    }

    @Test func slidesFromAMarkdownOutline() {
        let s = session()
        s.run("slide.fromOutline", JSON.object(JSONObject(["text": .string(mdOutline), "markdown": true])).display)
        #expect(same(Array(outlineOf(s.st.doc).dropFirst()), mdExpected))
    }

    @Test func markdownOutlinesTakeHeadingsAsSlidesAndListsAsBullets() throws {
        let p = try FileCommands.openPresentation("outline.md", Array(mdOutline.utf8))
        #expect(same(outlineOf(p), mdExpected))
        // numbered lists, `*` / `+` bullets, text under a heading, and closing #s
        let q = try FileCommands.openPresentation("o.md", Array("## Plan ##\n1. First\n2) Second\n* star\n+ plus\nA plain line\n".utf8))
        #expect(same(outlineOf(q), [("Plan", [(0, "First"), (0, "Second"), (0, "star"), (0, "plus"), (0, "A plain line")])]))
    }

    @Test func plainOutlinesAreUnchanged() throws {
        // .txt keeps the indentation format, and so does a .md without headings
        let indented = "Intro\n\tPoint one\n\t\tSub point\nSecond\n\tMore\n"
        let want: [(String, [(UInt8, String)])] = [("Intro", [(0, "Point one"), (1, "Sub point")]), ("Second", [(0, "More")])]
        for name in ["outline.txt", "outline.md"] {
            let p = try FileCommands.openPresentation(name, Array(indented.utf8))
            #expect(same(outlineOf(p), want), "\(name)")
        }
        let p = try FileCommands.openPresentation("outline.txt", Array(mdOutline.utf8))
        #expect(p.slides.first?.title == "# Intro")
    }

    @Test func selectAllSlidesScope() {
        let s = session()
        // One slide: selects it.
        let r = s.run("edit.selectAll", #"{"scope": "slides"}"#)
        #expect(r.get("selected")?.asArray?.count == 1)
        for _ in 0 ..< 3 { s.run("slide.new") }
        s.run("slide.hide", #"{"index": 1}"#)
        s.run("slide.go", #"{"index": 1}"#)
        let before = s.st.selection.slide
        s.run("edit.selectAll", #"{"scope": "slides"}"#)
        #expect(s.st.selection.slides == s.st.doc.slides.map(\.id))
        #expect(s.st.selection.slide == before, "the current slide must not jump")
        #expect(s.st.selection.shapes.isEmpty && s.st.selection.text == nil)
        #expect(s.st.doc.slides.count == 4)
    }

    @Test(.enabled(if: ported("shape.insert")))
    func selectAllSlidesLeavesShapeSelectAllAlone() {
        let s = session()
        s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 50, 50]}"#)
        s.run("slide.new")
        s.run("slide.go", #"{"index": 0}"#)
        s.run("edit.selectAll")
        #expect(!s.st.selection.shapes.isEmpty)
        #expect(s.st.selection.slides.count <= 1)
    }

    @Test func selectAllSlidesBadScopeIsAnError() {
        let s = session()
        #expect(s.fails("edit.selectAll", #"{"scope": "everything"}"#))
        #expect(s.fails("edit.selectAll", #"{"scope": 3}"#))
    }

    @Test func slideHideAndLayoutRejectInvalidIndex() {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        s.run("slide.selectSlides", #"{"indices": [0]}"#)
        for bad in ["-1", "1.5"] {
            do {
                _ = try s.execute("slide.hide", j("{\"index\": \(bad)}"))
                Issue.record("slide.hide took \(bad)")
            } catch { #expect(error.description.contains("not a valid index"), "\(error)") }
            do {
                _ = try s.execute("slide.layout", j("{\"layout\": \"blank\", \"index\": \(bad)}"))
                Issue.record("slide.layout took \(bad)")
            } catch { #expect(error.description.contains("not a valid index"), "\(error)") }
        }
        #expect(s.st.doc.slides.allSatisfy { !$0.hidden })
    }

    @Test func findLayoutTakesIdsNamesAndKinds() {
        let doc = session().st.doc
        let m = doc.masters[0]
        let title = m.layouts.first { $0.kind == .title }?.id
        #expect(SlideCommands.findLayout(doc, "title", 0) == title)
        #expect(SlideCommands.findLayout(doc, "Title Slide", 0) == title)
        #expect(SlideCommands.findLayout(doc, "TITLE-slide!", 0) == title)
        if let t = title { #expect(SlideCommands.findLayout(doc, .integer(t.rawValue), 0) == title) }
        #expect(SlideCommands.findLayout(doc, .integer(UInt64(UInt32.max) + 1), 0) == nil)
        #expect(SlideCommands.findLayout(doc, "no such layout", 0) == nil)
        #expect(SlideCommands.findLayout(doc, "blank", 99) == m.layouts.first { $0.kind == .blank }?.id, "an unknown master falls back to the first")
    }

    @Test func sectionsAddRenameMoveAndRemove() {
        let s = deckOf(5)
        s.run("section.add", #"{"name": "Two", "at": 2}"#)
        #expect(s.st.doc.sections.map(\.name) == ["Default Section", "Two"])
        s.run("section.add", #"{"name": "Four", "at": 4}"#)
        s.run("section.rename", #"{"index": 0, "name": "One"}"#)
        s.run("section.move", #"{"index": 2, "to": 0}"#)
        #expect(s.st.doc.sections.map(\.name) == ["Four", "One", "Two"])
        #expect(s.st.doc.sections.flatMap(\.slides) == s.st.doc.slides.map(\.id), "slides follow the sections")
        s.run("section.remove", #"{"index": 1}"#)
        #expect(s.st.doc.sections.map(\.name) == ["Four", "Two"])
        #expect(s.st.doc.sections.reduce(0) { $0 + $1.slides.count } == 5, "the removed section's slides join the one before")
        #expect(s.st.doc.sections.map { $0.slides.count } == [3, 2])
        s.run("section.remove", #"{"index": 1, "slides": true}"#)
        #expect(s.st.doc.slides.count == 3, "the section's two slides go with it")
        #expect(s.fails("section.rename", #"{"index": 9, "name": "x"}"#))
        s.run("section.removeAll")
        #expect(s.st.doc.sections.isEmpty)
    }

    @Test func notesAndRenameAndReset() {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "T", "body": "B"}"#)
        s.run("slide.notes", #"{"text": "Say this\nThen that"}"#)
        #expect(s.st.currentSlide?.notesText == "Say this\nThen that")
        s.run("slide.notes", #"{"body": {"paragraphs": [{"runs": [{"text": "Formatted", "props": {"b": true}}]}]}}"#)
        #expect(s.st.currentSlide?.notesText == "Formatted")
        #expect(s.fails("slide.notes", #"{"body": 5}"#))
        s.run("slide.rename", #"{"name": "Named"}"#)
        #expect(s.st.currentSlide?.name == "Named")
        s.run("slide.reset")
        #expect(s.st.currentSlide?.shapes.allSatisfy { $0.ph == nil || $0.xfrm == nil } == true)
        #expect(s.fails("slide.rename", #"{"name": "x", "index": 9}"#))
    }

    @Test func navigationStaysInsideTheDeck() {
        let s = deckOf(3)
        s.run("slide.first")
        s.run("slide.previous")
        #expect(s.st.selection.slide == 0)
        s.run("slide.last")
        s.run("slide.next")
        #expect(s.st.selection.slide == 2)
        let id = s.st.doc.slides[1].id.rawValue
        #expect(s.run("slide.go", "{\"id\": \(id)}") == ["index": 1])
        #expect(s.fails("slide.go", #"{"id": 424242}"#))
        #expect(s.fails("slide.go", #"{"index": 3}"#))
        #expect(s.fails("slide.go", "{}"))
    }
}
