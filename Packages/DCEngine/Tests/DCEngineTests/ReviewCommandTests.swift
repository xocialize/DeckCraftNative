// DCEngineTests — the `review` and `find` command modules, Review › Compare, spelling and the thesaurus:
// tests ported from deckcraft crates/engine/src/cmd/review.rs, cmd/find.rs, compare.rs, spell.rs,
// thesaurus.rs and tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Spelling tests that check deckcraft's own answers run with its checker alone
// (`Spell.$checker.withValue(HunspellSpelling())`): the default chain falls back to the Mac's spell checker
// for the languages no Hunspell dictionary is installed for.
//
// Every Rust test of these files is ported; none is pointer-driven. Tests that need another group's
// commands use them once registered (`shape.insert`, `insert.textBox`, `insert.table`); until then the
// same shape is added directly (`insertShape`, `insertTextBox`, `insertTable` below), so they run today.
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCTestSupport
import Foundation
import Testing

// MARK: - Helpers

/// Add `sh` to the current slide with a fresh id and select it (insert.rs `add_shape`).
private func addShape(_ s: Session, _ shape: Shape) -> ShapeId {
    var id = ShapeId(0)
    do {
        try s.edit { doc, sel in
            id = ShapeId(doc.allocId() ?? 0)
            var sh = shape
            sh.id = id
            if sh.name.isEmpty { sh.name = "Shape \(id.rawValue)" }
            mutateShapes(&doc, sel) { $0.append(sh) }
            sel.shapes = [id]
            sel.text = nil
        }
    } catch {
        Issue.record("addShape: \(error)")
    }
    return id
}

/// `shape.insert` of a rectangle holding `text` (or the same shape added directly until it's registered).
private func insertShape(_ s: Session, _ rect: [Double], _ text: String? = nil) -> ShapeId {
    if ported("shape.insert") {
        var p: JSON = ["preset": "rect", "rect": .array(rect.map { .double($0) })]
        if let text { p.set("text", .string(text)) }
        return ShapeId(s.run("shape.insert", p.display).get("id")?.asU32 ?? 0)
    }
    var sh = Shape.default
    sh.xfrm = Xfrm(rect[0], rect[1], rect[2], rect[3])
    sh.geom = .preset("rect")
    sh.text = text.map(TextBody.fromText)
    return addShape(s, sh)
}

/// `insert.textBox` (or the same text box added directly until it's registered).
private func insertTextBox(_ s: Session, _ rect: [Double], _ text: String) -> ShapeId {
    if ported("insert.textBox") {
        let p: JSON = ["rect": .array(rect.map { .double($0) }), "text": .string(text)]
        return ShapeId(s.run("insert.textBox", p.display).get("id")?.asU32 ?? 0)
    }
    var sh = Shape.default
    sh.xfrm = Xfrm(rect[0], rect[1], rect[2], rect[3])
    sh.textBox = true
    sh.text = TextBody.fromText(text)
    return addShape(s, sh)
}

/// `insert.table` (or the same table added directly until it's registered).
private func insertTable(_ s: Session, _ rows: Int, _ cols: Int) -> ShapeId {
    if ported("insert.table") {
        return ShapeId(s.run("insert.table", "{\"rows\": \(rows), \"cols\": \(cols)}").get("id")?.asU32 ?? 0)
    }
    let size = s.st.doc.slideSize
    var sh = Shape.default
    sh.xfrm = Xfrm(size.width * 0.1, max(size.height - 40.0 * Double(rows), 0) / 2, size.width * 0.8, 40.0 * Double(rows))
    sh.kind = .table(Table(rows: rows, cols: cols, width: size.width * 0.8, rowHeight: 40))
    return addShape(s, sh)
}

private func texts(_ s: Session, _ id: ShapeId) -> String { s.st.shape(id)?.text?.text ?? "" }

private func hunspell<T>(_ body: () throws -> T) rethrows -> T {
    try Spell.$checker.withValue(HunspellSpelling(), operation: body)
}

/// spell.rs tests' contributor-original miniature dictionary in Hunspell format.
private let spellTestAFF = "SET UTF-8\nTRY esianrtolcdugmphbyfvkwzxjq\nFORBIDDENWORD !\nNEEDAFFIX ?\nKEEPCASE K\n"
    + "REP 1\nREP f ph\n"
    + "PFX U Y 1\nPFX U 0 un .\n"
    + "SFX S Y 2\nSFX S y ies [^aeiou]y\nSFX S 0 s [^y]\n"
    + "SFX G Y 2\nSFX G e ing e\nSFX G 0 ing [^e]\n"
    + "SFX D Y 1\nSFX D 0 ed/S .\n"
private let spellTestDIC = "9\nslide/S\nmake/G\nhappy\ncity/S\ndo/U\nwork/USG\nphoto/S\nNASA/K\nfoo/?S\n"

private func dict(_ aff: String, _ dic: String) -> SpellDictionary { SpellDictionary.parse(Array(aff.utf8), Array(dic.utf8)) }

private func words(_ v: JSON) -> [String] { (v.asArray ?? []).compactMap { $0.get("word")?.asStr } }

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "deckcraft-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ... .max))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - cmd/review.rs

@Suite("Review commands")
struct ReviewCommandTests {
    /// review.rs `previous_and_next_comment_walk_the_deck`.
    @Test func previousAndNextCommentWalkTheDeck() throws {
        let s = session()
        do {
            _ = try s.execute("comment.next", .emptyObject)
            Issue.record("comment.next with no comments succeeded")
        } catch {
            #expect("\(error)".contains("no comments"), "\(error)")
        }
        s.run("comment.add", #"{"text": "on first"}"#)
        _ = insertShape(s, [10, 10, 40, 40])
        s.run("slide.new")
        s.run("comment.add", #"{"text": "on second a"}"#)
        s.run("comment.add", #"{"text": "on second b"}"#)
        s.run("slide.new")
        #expect(s.st.selection.slide == 2)
        do {
            _ = try s.execute("comment.next", .emptyObject)
            Issue.record("comment.next past the last comment succeeded")
        } catch {
            #expect("\(error)".contains("no more comments"), "\(error)")
        }
        let undoBefore = s.st.history.undo.count
        let back = s.run("comment.prev")
        #expect(back.get("slide") == 1 && back.get("index") == 1 && back.get("text") == "on second b")
        #expect(s.st.selection.slide == 1)
        #expect(s.st.selection.shapes.isEmpty)
        #expect(s.st.history.undo.count == undoBefore)
        let prev = s.run("comment.prev", #"{"slide": 1, "index": 1}"#)
        #expect(prev.get("index") == 0 && prev.get("text") == "on second a")
        let first = s.run("comment.prev", JSON.object(JSONObject(["slide": prev.get("slide") ?? .null, "index": prev.get("index") ?? .null])).display)
        #expect(first.get("slide") == 0 && first.get("text") == "on first")
        #expect(s.fails("comment.prev", #"{"slide": 0, "index": 0}"#))
        let next = s.run("comment.next", #"{"slide": 0, "index": 0}"#)
        #expect(next.get("slide") == 1 && next.get("text") == "on second a")
        s.run("slide.go", #"{"index": 0}"#)
        #expect(s.run("comment.next").get("text") == "on first")
    }

    /// review.rs `timestamps_are_iso_utc`.
    @Test func timestampsAreIsoUtc() {
        #expect(ReviewCommands.isoUTC(0) == "1970-01-01T00:00:00Z")
        #expect(ReviewCommands.isoUTC(1_791_637_835) == "2026-10-10T13:10:35Z")
    }

    /// review.rs `the_clock_is_not_empty`.
    @Test func theClockIsNotEmpty() {
        #expect(ReviewCommands.now().hasPrefix("20"), "\(ReviewCommands.now())")
    }

    /// review.rs `show_media_controls_follow_setup`.
    @Test func showMediaControlsFollowSetup() {
        let s = session()
        #expect(s.st.doc.show.showMediaControls)
        let off = s.run("show.setup", #"{"showMediaControls": false}"#)
        #expect(off.get("showMediaControls") == false)
        #expect(off.get("useTimings") == true, "other setup flags stay")
        let timings = s.run("show.setup", #"{"useTimings": false}"#)
        #expect(timings.get("showMediaControls") == false && timings.get("useTimings") == false)
        s.run("show.setup", #"{"showMediaControls": true}"#)
        #expect(s.st.doc.show.showMediaControls)
    }

    /// review.rs `setup_remembers_a_custom_show`.
    @Test func setupRemembersACustomShow() {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        s.run("show.customShow", #"{"name": "Short", "slides": [0, 1]}"#)
        let v = s.run("show.setup", #"{"custom": "Short"}"#)
        #expect(v.get("customShow")?.asStr == "Short")
        #expect(s.st.doc.show.range == nil)
        s.run("show.setup", #"{"custom": ""}"#)
        #expect(s.st.doc.show.customShow == nil)
    }

    /// review.rs `delete_rejects_an_invalid_index_and_keeps_the_comments`.
    @Test func deleteRejectsAnInvalidIndexAndKeepsTheComments() {
        let s = session()
        s.run("comment.add", #"{"text": "a"}"#)
        s.run("comment.add", #"{"text": "b"}"#)
        for bad in ["-1", "\"2\"", "1.5"] {
            #expect(s.fails("comment.delete", "{\"index\": \(bad)}"), "index \(bad)")
            #expect(s.st.doc.slides[0].comments.count == 2, "index \(bad)")
        }
        s.run("comment.delete")
        #expect(s.st.doc.slides[0].comments.isEmpty)
    }

    /// review.rs `spelling_change_range_tests::spelling_change_huge_start_is_bad_params`.
    @Test func spellingChangeHugeStartIsBadParams() {
        let s = session()
        let id = insertTextBox(s, [10, 10, 200, 40], "Hello")
        do {
            _ = try s.execute("review.spellingChange", j("{\"shape\": \(id.rawValue), \"para\": 0, \"start\": \(UInt64.max), \"word\": \"Hello\", \"to\": \"x\"}"))
            Issue.record("a huge start succeeded")
        } catch {
            if case .badParams = error {} else { Issue.record("\(error)") }
        }
    }
}

// MARK: - cmd/find.rs and tests.rs Find and Replace

@Suite("Find and replace")
struct FindCommandTests {
    private func opts(_ t: String, _ matchCase: Bool, _ whole: Bool) -> FindCommands.Opts {
        FindCommands.Opts(pat: Array(t.unicodeScalars), matchCase: matchCase, whole: whole)
    }

    private func textRun(_ t: String) -> Run { Run(text: t, props: RunProps(), kind: .text) }

    private func br() -> Run { Run(text: "", props: RunProps(), kind: .break) }

    private func eq(_ a: [(Int, Int)], _ b: [(Int, Int)]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0 == $1 } }

    /// find.rs `matching_honours_case_and_whole_words`.
    @Test func matchingHonoursCaseAndWholeWords() {
        let t = Array("Cat cat category".unicodeScalars)
        #expect(opts("cat", false, false).matches(t).count == 3)
        #expect(opts("cat", true, false).matches(t).count == 2)
        #expect(eq(opts("cat", false, true).matches(t), [(0, 3), (4, 7)]))
    }

    /// find.rs `a_match_never_spans_a_line_break`.
    @Test func aMatchNeverSpansALineBreak() {
        let p = Paragraph(runs: [textRun("a"), br(), textRun("b")])
        #expect(FindCommands.paraMatches(p, opts("ab", true, false)).isEmpty)
    }

    /// find.rs `offsets_count_a_line_break_as_one_char`.
    @Test func offsetsCountALineBreakAsOneChar() {
        let p = Paragraph(runs: [textRun("ab"), br(), textRun("cd")])
        #expect(eq(FindCommands.paraMatches(p, opts("cd", true, false)), [(3, 5)]))
    }

    /// find.rs `splice_after_a_line_break_keeps_the_break`.
    @Test func spliceAfterALineBreakKeepsTheBreak() {
        var p = Paragraph(runs: [textRun("ab"), br(), textRun("cd")])
        FindCommands.splice(&p, 3, 5, "X")
        #expect(p.text == "ab\u{0B}X")
        #expect(p.runs[1].kind == .break)
    }

    /// find.rs `splice_across_runs_keeps_the_first_runs_format`.
    @Test func spliceAcrossRunsKeepsTheFirstRunsFormat() {
        let bold = RunProps(bold: true)
        var p = Paragraph(runs: [Run(text: "Hel", props: bold, kind: .text), Run(text: "lo world", props: RunProps(), kind: .text)])
        FindCommands.splice(&p, 1, 5, "ola")
        #expect(String(String.UnicodeScalarView(FindCommands.paraChars(p))) == "Hola world")
        #expect(p.runs[0].text == "Hola")
        #expect(p.runs[0].props == bold)
    }

    /// tests.rs `find_and_replace_across_shapes_and_notes`.
    @Test func findAndReplaceAcrossShapesAndNotes() {
        let s = session()
        _ = insertShape(s, [100, 100, 200, 100], "Old plan, old team\nboldly")
        s.run("slide.notes", #"{"text": "Discuss the old plan"}"#)
        let q = #"{"text": "old"}"#
        let found = s.run("text.find", q)
        let n = found.asArray?.count ?? 0
        #expect(n >= 3, "\(found.display)")
        let whole = s.run("text.find", #"{"text": "old", "wholeWords": true, "matchCase": true}"#)
        #expect(whole.asArray?.count == n - 2, "Old and boldly are not whole lower-case matches")
        let first = found.at(0) ?? .null
        #expect(first.get("para")?.asU64 == 0 && first.get("start")?.asU64 == 0)
        s.run("text.replace", JSON.object(JSONObject(["text": "old", "with": "New", "at": first])).display)
        #expect(s.run("text.find", q).asArray?.count == n - 1)
        let r = s.run("text.replace", #"{"text": "old", "with": "new", "wholeWords": true}"#)
        #expect(r.get("replaced")?.asU64 == UInt64(n - 2))
        let text = s.st.doc.slides[0].shapes.compactMap { $0.text?.text }.joined(separator: "|")
        #expect(text.contains("New plan, new team\nboldly"), "\(text)")
        #expect(s.fails("text.replace", #"{"text": "zebra", "with": "x"}"#))
        s.run("edit.undo")
        #expect(s.run("text.find", q).asArray?.count == n - 1)
    }

    /// tests.rs `find_and_replace_after_a_line_break`.
    @Test func findAndReplaceAfterALineBreak() {
        let s = session()
        let id = insertTextBox(s, [10, 10, 300, 80], "ab")
        s.run("text.edit", "{\"id\": \(id.rawValue), \"end\": true}")
        s.run("text.insert", #"{"text": "\u000bcd"}"#)
        s.run("text.exit")
        #expect(texts(s, id) == "ab\u{0B}cd")
        #expect(s.run("text.find", #"{"text": "bc"}"#).asArray?.isEmpty == true, "no match spans the break")
        let found = s.run("text.find", #"{"text": "cd"}"#)
        #expect(found.at(0)?.get("start")?.asU64 == 3 && found.at(0)?.get("end")?.asU64 == 5, "\(found.display)")
        s.run("text.replace", #"{"text": "cd", "with": "X"}"#)
        #expect(texts(s, id) == "ab\u{0B}X")
        s.run("edit.undo")
        #expect(texts(s, id) == "ab\u{0B}cd")
    }
}

// MARK: - compare.rs

@Suite("Compare")
struct CompareTests {
    /// The sample deck, and a revised copy of it as base64 `.deckcraft` bytes: slide 1's title retyped,
    /// slide 2 deleted, a new slide at the end, a shape moved on slide 3 (compare.rs tests `decks`).
    /// The sample deck: built by `Sample.openSample` once every command it runs is registered, until then
    /// the corpus's `sample.deckcraft` (the same deck, as deckcraft built it).
    private func decks() throws -> (Session, String, Int) {
        let s = Session()
        if ported(Sample.commands) {
            try Sample.openSample(s)
        } else {
            let deck = try #require(Fixtures.oracleCorpus?.appending(path: "decks/sample.deckcraft"))
            _ = try s.execute("file.open", ["path": .string(deck.path)])
        }
        let n = s.st.doc.slides.count
        let orig = try #require(s.run("file.saveBytes").get("data")?.asStr)
        // Make the revision in a second document.
        s.run("file.openBytes", JSON.object(JSONObject(["name": "rev.deckcraft", "data": .string(orig)])).display)
        let first = try #require(s.st.doc.slides[0].shapes.first { $0.text != nil }?.id.rawValue)
        s.run("edit.select", "{\"ids\": [\(first)]}")
        s.run("text.edit", "{\"id\": \(first)}")
        s.run("edit.selectAll")
        s.run("text.insert", #"{"text": "Revised title"}"#)
        s.run("text.exit")
        s.run("slide.delete", #"{"index": 1}"#)
        _ = try? s.execute("slide.go", ["index": 1])
        let moved = s.st.doc.slides[1].shapes[0].id.rawValue
        _ = try? s.execute("shape.move", j("{\"ids\": [\(moved)], \"dx\": 30, \"dy\": 0}"))
        _ = try? s.execute("slide.go", ["index": .integer(n - 2)])
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "Brand new", "body": "x"}"#)
        let rev = try #require(s.run("file.saveBytes").get("data")?.asStr)
        s.closeDocument(1)
        s.setActive(0)
        return (s, rev, n)
    }

    private func compareParams(_ rev: String) -> String { JSON.object(JSONObject(["name": "rev.deckcraft", "data": .string(rev)])).display }

    private func kinds(_ v: JSON) -> [String] { (v.get("changes")?.asArray ?? []).compactMap { $0.get("kind")?.asStr } }

    private func changes(_ s: Session) -> [JSON] { s.run("review.revisions").get("changes")?.asArray ?? [] }

    /// compare.rs `lists_inserted_deleted_and_changed_slides`.
    @Test(.enabled(if: ported(Sample.commands) || Fixtures.oracleCorpus != nil, "needs the sample deck")) func listsInsertedDeletedAndChangedSlides() throws {
        let (s, rev, n) = try decks()
        let v = s.run("review.compare", compareParams(rev))
        let k = kinds(v)
        #expect(k.contains("deleted") && k.contains("inserted") && k.contains("changed"), "\(v.display)")
        let ch = try #require(v.get("changes")?.at(0))
        #expect(ch.get("slide") == 0)
        #expect(ch.get("details")?.display.contains("text") == true, "\(ch.display)")
        let ins = try #require(v.get("changes")?.asArray?.first { $0.get("kind") == "inserted" })
        #expect(ins.get("details")?.at(0) == "Brand new")
        #expect(ins.get("slide")?.asUsize == n, "after the open slide matching the revised one before it")
        #expect(s.st.doc.slides.count == n, "comparing alone changes nothing")
    }

    /// A deck with one slide: a table whose cell has a picture fill, a picture background and a transition
    /// sound. `tag` starts the bytes of each (compare.rs tests `media_deck`).
    private func mediaDeck(_ tag: String) -> Presentation {
        var p = newPresentation(nil)
        let cell = p.addMedia("cell.png", "image/png", Array("\(tag) cell".utf8)) ?? MediaId(0)
        let back = p.addMedia("back.png", "image/png", Array("\(tag) background".utf8)) ?? MediaId(0)
        let sound = p.addMedia("sound.wav", "audio/wav", Array("\(tag) sound".utf8)) ?? MediaId(0)
        var t = Table(rows: 1, cols: 1, width: 100, rowHeight: 40)
        t.rows[0].cells[0].fill = .picture(PictureFill(media: cell))
        let id = ShapeId(p.allocId() ?? 0)
        var s = p.slides.first ?? Slide.default
        var sh = Shape.default
        sh.id = id
        sh.kind = .table(t)
        s.shapes.append(sh)
        s.background = .fill(fill: .picture(PictureFill(media: back)))
        s.transition = Transition(kind: "fade", option: "", durationMs: 0, advanceOnClick: true, sound: sound, soundLoop: false, stopSound: false)
        p.slides = [s]
        return p
    }

    /// compare.rs `an_accepted_slide_keeps_its_cell_picture_background_and_sound`.
    @Test func anAcceptedSlideKeepsItsCellPictureBackgroundAndSound() throws {
        // Both decks hold the same media ids with different bytes.
        var doc = mediaDeck("open")
        let rev = mediaDeck("revised")
        let sl = try Comparing.adopt(&doc, rev, rev.slides[0], nil)
        func bytes(_ id: MediaId) -> String { String(decoding: doc.media(id)?.data ?? [], as: UTF8.self) }
        let table = try #require(sl.shapes.lazy.compactMap { sh -> Table? in
            if case .table(let t) = sh.kind { return t }
            return nil
        }.first)
        guard case .picture(let cell)? = table.rows[0].cells[0].fill else { Issue.record("no cell picture"); return }
        guard case .fill(.picture(let back))? = sl.background else { Issue.record("no background picture"); return }
        let sound = try #require(sl.transition?.sound)
        #expect([bytes(cell.media), bytes(back.media), bytes(sound)] == ["revised cell", "revised background", "revised sound"])
        // The open deck's own slide is untouched.
        guard case .fill(.picture(let own))? = doc.slides[0].background else { Issue.record("no background picture"); return }
        #expect(bytes(own.media) == "open background")
    }

    /// compare.rs `accept_one_then_all_makes_the_decks_equal_and_undoes`.
    @Test(.enabled(if: ported(Sample.commands) || Fixtures.oracleCorpus != nil, "needs the sample deck")) func acceptOneThenAllMakesTheDecksEqualAndUndoes() throws {
        let (s, rev, n) = try decks()
        s.run("review.compare", compareParams(rev))
        let before = changes(s).count
        s.run("review.accept", #"{"index": 0}"#)
        #expect(changes(s).count == before - 1)
        #expect(s.st.doc.slides[0].shapes.contains { $0.text?.text.contains("Revised title") == true })
        s.run("review.accept", #"{"all": true}"#)
        #expect(changes(s).isEmpty)
        #expect(s.st.doc.validate().isEmpty, "\(s.st.doc.validate())")
        #expect(s.st.doc.slides.count == n)
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(changes(s).count == before)
        s.run("review.endCompare")
        #expect(s.fails("review.revisions"))
        #expect(s.fails("review.accept", #"{"all": true}"#))
    }

    /// compare.rs `reject_keeps_the_open_deck_and_accept_all_skips_rejected_revisions`.
    @Test(.enabled(if: ported(Sample.commands) || Fixtures.oracleCorpus != nil, "needs the sample deck")) func rejectKeepsTheOpenDeckAndAcceptAllSkipsRejectedRevisions() throws {
        let (s, rev, n) = try decks()
        s.run("review.compare", compareParams(rev))
        let before = changes(s)
        let ins = try #require(before.firstIndex { $0.get("kind") == "inserted" })
        let doc = s.st.docRef
        let undo = s.st.history.undo.count
        #expect(s.run("review.reject", "{\"index\": \(ins)}").get("rejected") == 1)
        #expect(doc === s.st.docRef, "rejecting leaves the open deck as it is")
        let left = s.run("review.revisions")
        #expect(kinds(left).count == before.count - 1)
        #expect(!kinds(left).contains("inserted"), "\(left.display)")
        // Accept All takes the rest, never the rejected slide.
        s.run("review.accept", #"{"all": true}"#)
        #expect(s.st.doc.slides.count == n - 1, "the deleted slide goes, the rejected insertion never comes")
        #expect(!s.st.doc.slides.contains { Comparing.slideTitle($0) == "Brand new" })
        #expect(changes(s).isEmpty)
        s.run("edit.undo")
        #expect(doc === s.st.docRef)
        #expect(s.st.history.undo.count == undo, "rejecting is not an undo step")
        // Reject All: nothing left to review, the deck as it was; Accept All then has nothing to take.
        #expect(s.run("review.reject", #"{"all": true}"#).get("rejected")?.asUsize == before.count - 1)
        #expect(changes(s).isEmpty)
        #expect(s.fails("review.accept", #"{"all": true}"#))
        #expect(doc === s.st.docRef)
        #expect(s.fails("review.reject", #"{"all": true}"#), "nothing left to reject")
        #expect(s.fails("review.reject"))
        s.run("review.endCompare")
        #expect(s.fails("review.reject", #"{"index": 0}"#))
    }

    /// compare.rs `rejecting_one_revision_keeps_the_others_in_order`.
    @Test(.enabled(if: ported(Sample.commands) || Fixtures.oracleCorpus != nil, "needs the sample deck")) func rejectingOneRevisionKeepsTheOthersInOrder() throws {
        let (s, rev, _) = try decks()
        s.run("review.compare", compareParams(rev))
        let before = changes(s)
        #expect(s.fails("review.reject", "{\"index\": \(before.count)}"))
        s.run("review.reject", #"{"index": 0}"#)
        #expect(changes(s) == Array(before.dropFirst()), "the rejected one goes, the others stay in order")
    }

    private func pptxOf(_ titles: [String]) throws -> String {
        let other = session()
        for t in titles { other.run("slide.new", "{\"layout\": \"title\", \"title\": \"\(t)\"}") }
        return try #require(other.run("file.saveBytes", #"{"format": "pptx"}"#).get("data")?.asStr)
    }

    private func pptxParams(_ data: String) -> String { JSON.object(JSONObject(["name": "o.pptx", "data": .string(data)])).display }

    /// compare.rs `unrelated_decks_match_by_position_and_bad_input_fails`.
    @Test func unrelatedDecksMatchByPositionAndBadInputFails() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "title", "title": "A"}"#)
        let v = s.run("review.compare", pptxParams(try pptxOf(["B", "C"])))
        #expect(kinds(v).contains("inserted"), "\(v.display)")
        s.run("review.accept", #"{"all": true}"#)
        #expect(changes(s).isEmpty)
        #expect(s.st.doc.validate().isEmpty)
        #expect(s.fails("review.compare", #"{"data": "!!"}"#))
        #expect(s.fails("review.compare", #"{"name": "x.bin", "data": "AAAA"}"#))
        #expect(s.fails("review.compare"))
        #expect(s.fails("review.accept", #"{"index": 999}"#))
    }

    private func slideTexts(_ s: Session) -> [String] { s.st.doc.slides.map { $0.shapes.compactMap { $0.text?.text }.joined() } }

    /// compare.rs `a_rejected_positional_revision_stays_rejected_after_a_slide_is_inserted`.
    @Test func aRejectedPositionalRevisionStaysRejectedAfterASlideIsInserted() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "title", "title": "A"}"#)
        let v = s.run("review.compare", pptxParams(try pptxOf(["B"])))
        #expect(v.get("byPosition") == true, "\(v.display)")
        func changed(_ v: JSON) -> [UInt64] { (v.get("changes")?.asArray ?? []).filter { $0.get("kind") == "changed" }.compactMap { $0.get("revised")?.asU64 } }
        let last = try #require(changed(v).last, "a changed slide")
        let at = try #require(v.get("changes")?.asArray?.firstIndex { $0.get("revised")?.asU64 == last })
        s.run("review.reject", "{\"index\": \(at)}")
        // A new slide at the front shifts every open slide down by one.
        s.run("slide.new", #"{"layout": "title", "title": "N"}"#)
        let nAt = try #require(slideTexts(s).firstIndex { $0.contains("N") })
        s.run("slide.move", "{\"from\": \(nAt), \"to\": 0}")
        #expect(slideTexts(s).firstIndex { $0.contains("N") } == 0)
        let now = s.run("review.revisions")
        #expect(!changed(now).contains(last), "\(now.display)")
        s.run("review.accept", #"{"all": true}"#)
        #expect(!slideTexts(s).contains { $0.contains("B") }, "\(slideTexts(s))")
    }

    /// compare.rs `a_rejected_positional_revision_does_not_become_a_deletion_when_a_slide_is_inserted`.
    @Test func aRejectedPositionalRevisionDoesNotBecomeADeletionWhenASlideIsInserted() throws {
        let s = session()
        for t in ["A", "X"] { s.run("slide.new", "{\"layout\": \"title\", \"title\": \"\(t)\"}") }
        let v = s.run("review.compare", pptxParams(try pptxOf(["B", "Y"])))
        #expect(v.get("byPosition") == true, "\(v.display)")
        let list = v.get("changes")?.asArray ?? []
        let revisedOfChanged = list.filter { $0.get("kind") == "changed" }.compactMap { $0.get("revised")?.asU64 }
        let last = try #require(revisedOfChanged.max(), "a changed slide")
        let at = try #require(list.firstIndex { $0.get("kind") == "changed" && $0.get("revised")?.asU64 == last })
        let openId = s.st.doc.slides[Int(last)].id
        s.run("review.reject", "{\"index\": \(at)}")
        s.run("slide.new", #"{"layout": "title", "title": "N"}"#)
        let nAt = try #require(slideTexts(s).firstIndex { $0.contains("N") })
        s.run("slide.move", "{\"from\": \(nAt), \"to\": 0}")
        s.run("review.accept", #"{"all": true}"#)
        #expect(s.st.doc.slides.contains { $0.id == openId }, "the open slide whose revision was rejected was deleted")
    }
}

// MARK: - spell.rs and tests.rs spelling

@Suite("Spelling")
struct SpellTests {
    /// spell.rs `curly_apostrophe_matches_ascii_entry`.
    @Test func curlyApostropheMatchesAsciiEntry() {
        let d = dict(spellTestAFF, "2\ndon't\nwork\n")
        #expect(d.check("don't"))
        #expect(d.check("don\u{2019}t"))
    }

    /// spell.rs `roots_affixes_and_cross_products_check`.
    @Test func rootsAffixesAndCrossProductsCheck() {
        let d = dict(spellTestAFF, spellTestDIC)
        for w in ["slide", "slides", "making", "cities", "undo", "unworks", "working", "Slide", "SLIDES", "NASA", "foos"] {
            #expect(d.check(w), "\(w)")
        }
        for w in ["slidez", "makeing", "citys", "unslide", "Nasa", "nasa", "foo", "teh"] {
            #expect(!d.check(w), "\(w)")
        }
    }

    /// spell.rs `a_language_tag_cannot_leave_the_dictionary_folders`.
    @Test func aLanguageTagCannotLeaveTheDictionaryFolders() throws {
        let dir = tempDir("dict-lang")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appending(path: "dicts")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("SET UTF-8\n".utf8).write(to: dir.appending(path: "evil.aff"))
        try Data("1\nword\n".utf8).write(to: dir.appending(path: "evil.dic"))
        #expect(Spell.findIn([inner.path], "../evil") == nil)
        #expect(Spell.findIn([inner.path], "en/../../evil") == nil)
        #expect(!Spell.validLang("") && !Spell.validLang(String(repeating: "a", count: 17)) && Spell.validLang("en-US") && Spell.validLang("pt_BR"))
    }

    /// spell.rs `suggestions_come_from_edits_and_replacements`.
    @Test func suggestionsComeFromEditsAndReplacements() {
        let d = dict(spellTestAFF, spellTestDIC)
        #expect(d.suggest("sldie", 3).first == "slide")
        #expect(d.suggest("foto", 5).contains("photo"))
        #expect(d.suggest("Slidse", 5).contains("Slides"))
        #expect(d.suggest("workingslides", 5).contains("working slides"))
    }

    /// spell.rs `compounds_join_flagged_parts`.
    @Test func compoundsJoinFlaggedParts() {
        let d = dict("COMPOUNDFLAG X\nCOMPOUNDMIN 3\nONLYINCOMPOUND O\nSFX S Y 1\nSFX S 0 en .\n", "4\nhaus/X\ntuer/XS\nschluessel/X\nfugs/OX\n")
        for w in ["haustuer", "haustueren", "haustuerschluessel", "haus", "hausfugstuer"] { #expect(d.check(w), "\(w)") }
        for w in ["hausx", "fugs", "tuerhausz"] { #expect(!d.check(w), "\(w)") }
    }

    /// spell.rs `runs_give_words_their_language`.
    @Test func runsGiveWordsTheirLanguage() {
        let p = Paragraph(runs: [
            Run.with("Hello wor", RunProps(lang: "en-GB")),
            Run.with("ld, Grüße well-known 3rd l'été", RunProps(lang: "de-DE")),
        ])
        let got = Spell.paragraphWords(p, "en-US").map { "\($0.text)|\($0.lang)|\($0.start)" }
        #expect(got == ["Hello|en-GB|0", "world|en-GB|6", "Grüße|de-DE|13", "well|de-DE|19", "known|de-DE|24", "l'été|de-DE|34"])
    }

    /// spell.rs `repeated_words_and_no_proof_runs`.
    @Test func repeatedWordsAndNoProofRuns() {
        let p = Paragraph("See the the plan, plan. The THE end")
        let r = Spell.repeated(p, "en-US").map { "\($0.start) \($0.end) \($0.repeated.map(String.init) ?? "-")" }
        #expect(r == ["8 11 7", "28 31 27"])
        let q = Paragraph(runs: [Run("check "), Run.with("xyzzy qq", RunProps(noProof: true)), Run(" done")])
        #expect(Spell.paragraphWords(q, "en-US").map(\.text) == ["check", "done"])
    }

    /// spell.rs `long_and_numeric_flags_and_latin1`.
    @Test func longAndNumericFlagsAndLatin1() {
        #expect(dict("FLAG long\nSFX Aa Y 1\nSFX Aa 0 s .\n", "1\ncat/Aa\n").check("cats"))
        #expect(dict("FLAG num\nSFX 101 Y 1\nSFX 101 0 s .\n", "1\ndog/7,101\n").check("dogs"))
        #expect(SpellDictionary.parse(Array("SET ISO8859-1\n".utf8), [0x31, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x0A]).check("café"))
    }

    /// spell.rs `dictionaries_are_found_by_locale_then_language`.
    @Test func dictionariesAreFoundByLocaleThenLanguage() throws {
        let dir = tempDir("dict")
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["en_GB", "de_DE"] {
            try Data().write(to: dir.appending(path: "\(n).aff"))
            try Data().write(to: dir.appending(path: "\(n).dic"))
        }
        func stem(_ l: String) -> String? {
            Spell.findIn([dir.path], l).map { URL(filePath: $0.0).deletingPathExtension().lastPathComponent }
        }
        #expect(stem("de-DE") == "de_DE")
        #expect(stem("en-US") == "en_GB")
        #expect(stem("fr-FR") == nil)
    }

    #if canImport(AppKit)
    /// The Mac's spell checker answers for the languages it has, and the default chain asks an installed
    /// Hunspell dictionary first (no Rust test: the system checker is this port's).
    @Test func systemSpellingAndTheChainPreferringHunspell() {
        let sys = SystemSpelling()
        #expect(sys.hasDictionary("en-US"))
        #expect(sys.isCorrect("teh", lang: "en-US") == false)
        #expect(sys.isCorrect("slide", lang: "en-US") == true)
        #expect(sys.suggestions("teh", lang: "en-US", limit: 5).contains("the"))
        #expect(sys.isCorrect("teh", lang: "zz-NONE") == nil && !sys.hasDictionary("zz-NONE"))
        Spell.install("en-QQ", dict("", "1\nteh\n"))
        let chain = Spell.defaultChecker
        #expect(chain.isCorrect("teh", lang: "en-QQ") == true, "the installed Hunspell dictionary answers first")
        #expect(chain.isCorrect("teh", lang: "en-US") == false, "the system checker answers where no Hunspell dictionary is")
        #expect(chain.hasDictionary("en-US") && !chain.hasDictionary("zz-NONE"))
    }
    #endif

    /// tests.rs `spelling_uses_a_dictionary_suggests_and_changes`.
    @Test func spellingUsesADictionarySuggestsAndChanges() throws {
        try hunspell {
            Spell.install("xx-TEST", dict(spellTestAFF, spellTestDIC))
            let s = session()
            let id = insertShape(s, [100, 100, 300, 100], "Making sldie photos, sldie").rawValue
            let v = s.run("review.spelling", #"{"lang": "xx-TEST"}"#)
            let list = try #require(v.asArray)
            #expect(list.count == 2, "\(v.display)")
            #expect(list.first?.get("word") == "sldie")
            #expect(list.first?.get("suggestions")?.at(0) == "slide")
            #expect(s.run("review.spelling", #"{"lang": "xx-TEST", "ignore": ["SLDIE"]}"#).asArray?.isEmpty == true)
            #expect(s.run("review.spellingChange", "{\"shape\": \(id), \"word\": \"sldie\", \"to\": \"slide\"}").get("changed") == 1)
            #expect(s.run("review.spelling", #"{"lang": "xx-TEST"}"#).asArray?.count == 1)
            #expect(s.run("review.spellingChange", #"{"word": "sldie", "to": "slide", "all": true}"#).get("changed") == 1)
            #expect(s.run("review.spelling", #"{"lang": "xx-TEST"}"#).asArray?.isEmpty == true)
            // Whole words only, and one undo step per change.
            #expect(s.run("review.spellingChange", #"{"word": "slid", "to": "x", "all": true}"#).get("changed") == 0)
            s.run("edit.undo")
            #expect(s.run("review.spelling", #"{"lang": "xx-TEST"}"#).asArray?.count == 1)
        }
    }

    /// tests.rs `spelling_without_a_dictionary_falls_back_to_common_misspellings`.
    @Test func spellingWithoutADictionaryFallsBackToCommonMisspellings() {
        hunspell {
            let s = session()
            _ = insertShape(s, [100, 100, 300, 100], "Teh qzxv")
            let v = s.run("review.spelling", #"{"lang": "zz-NONE"}"#)
            #expect(v.asArray?.count == 1)
            #expect(v.at(0)?.get("word") == "Teh")
            let d = s.run("review.dictionary", #"{"lang": "zz-NONE"}"#)
            #expect(d.get("found")?.isNull == true)
            #expect(d.get("available") == false)
        }
    }

    /// tests.rs `language_marks_text_and_no_proof_and_repeats_are_reported`.
    @Test func languageMarksTextAndNoProofAndRepeatsAreReported() {
        hunspell {
            Spell.install("xx-LN", dict("", "3\nthe\nend\nis\n"))
            let s = session()
            let id = insertShape(s, [100, 100, 300, 100], "the the end is nigh").rawValue
            s.run("edit.select", "{\"ids\": [\(id)]}")
            s.run("format.language", #"{"lang": "xx-LN"}"#)
            let v = s.run("review.spelling")
            let got = (v.asArray ?? []).map { "\($0.get("word")?.asStr ?? "?") \($0.get("repeated") == true)" }
            #expect(got == ["the true", "nigh false"])
            #expect(v.at(0)?.get("deleteFrom") == 3)
            // Deleting the repeat through the exact-occurrence change.
            s.run("review.spellingChange", "{\"shape\": \(id), \"para\": 0, \"start\": 3, \"word\": \" the\", \"to\": \"\"}")
            #expect(s.st.shape(ShapeId(id))?.text?.paragraphs[0].runs[0].text == "the end is nigh")
            s.run("format.language", #"{"noProof": true}"#)
            #expect(s.run("review.spelling").asArray?.isEmpty == true)
            #expect(s.fails("format.language", #"{"lang": "en US!"}"#))
        }
    }

    /// tests.rs `language_all_marks_every_text_in_the_deck_with_nothing_selected`.
    @Test func languageAllMarksEveryTextInTheDeckWithNothingSelected() throws {
        try hunspell {
            Spell.install("xx-AL", dict("", "2\nhello\nworld\n"))
            let s = session()
            let a = insertShape(s, [100, 100, 300, 100], "hello wurld")
            s.run("edit.select", "{\"ids\": [\(a.rawValue)]}")
            s.run("format.language", #"{"lang": "de-DE"}"#)
            s.run("slide.new", #"{"title": "world hellow"}"#)
            _ = insertTable(s, 1, 1)
            s.run("edit.select", #"{"ids": []}"#)
            // A layout placeholder with its own list style (a:lstStyle) in another language.
            let placeholder: ShapeId = try s.edit { doc, _ in
                var found = ShapeId(0)
                guard let k = doc.masters[0].layouts[0].shapes.firstIndex(where: { $0.text != nil }) else { throw EngineError.other("no text") }
                var lv = LevelStyle()
                lv.run.lang = "de-DE"
                doc.masters[0].layouts[0].shapes[k].text?.listStyle.set(0, lv)
                found = doc.masters[0].layouts[0].shapes[k].id
                return found
            }
            s.run("format.languageAll", #"{"lang": "xx-AL"}"#)
            let st = s.st
            let ph = findShape(st.doc.masters[0].layouts[0].shapes, placeholder)
            #expect(ph?.text?.listStyle.level(0)?.run.lang == "xx-AL")
            // A body without a list style doesn't get one.
            let boxed = st.doc.slides.lazy.compactMap { findShape($0.shapes, a) }.first
            #expect(boxed?.text?.listStyle.isEmpty == true)
            var langs: [String?] = []
            for sl in st.doc.slides {
                walk(sl.shapes) { sh, _ in
                    langs += (sh.text?.paragraphs ?? []).flatMap(\.runs).map(\.props.lang)
                    if case .table(let t) = sh.kind { langs += t.rows.flatMap(\.cells).flatMap(\.text.paragraphs).map(\.endProps.lang) }
                }
            }
            #expect(!langs.isEmpty && langs.allSatisfy { $0 == "xx-AL" }, "\(langs)")
            // The defaults new text inherits.
            #expect(st.doc.defaultTextStyle.level(0)?.run.lang == "xx-AL")
            #expect(st.doc.masters.allSatisfy { $0.bodyStyle.level(0)?.run.lang == "xx-AL" })
            #expect(words(s.run("review.spelling")) == ["wurld", "hellow"])
            // One undo step puts the per-box language back.
            s.run("edit.undo")
            let sh = s.st.doc.slides.lazy.compactMap { findShape($0.shapes, a) }.first
            #expect(sh?.text?.paragraphs[0].runs[0].props.lang == "de-DE")
            #expect(s.fails("format.languageAll"))
            #expect(s.fails("format.languageAll", #"{"lang": "en US!"}"#))
        }
    }
}

/// Tests that point the user dictionary at a temporary file: one at a time, as it is process-wide.
@Suite("User dictionary", .serialized)
struct UserDictionaryTests {
    /// tests.rs `spelling_checks_each_run_in_its_language_and_learns_words`.
    @Test func spellingChecksEachRunInItsLanguageAndLearnsWords() throws {
        try hunspell {
            let dir = tempDir("userdic")
            defer { try? FileManager.default.removeItem(at: dir) }
            Spell.setUserDictionaryPath(dir.appending(path: "user.dic").path)
            Spell.install("xx-ONE", dict("", "2\nhello\nworld\n"))
            Spell.install("xx-TWO", dict("", "2\nhallo\nwelt\n"))
            let s = session()
            let id = insertShape(s, [100, 100, 300, 100], "hello hallo deckcraft")
            // The second word is in another language (as a PPTX run's `lang` gives it).
            try s.edit { doc, _ in
                withShape(&doc.slides[0].shapes, id) { sh in
                    guard var p = sh.text?.paragraphs.first, let run = p.runs.first else { return }
                    let t = Array(run.text.unicodeScalars)
                    func part(_ r: Range<Int>) -> String { String(String.UnicodeScalarView(t[r])) }
                    var one = run.props
                    one.lang = "xx-ONE"
                    var two = run.props
                    two.lang = "xx-TWO"
                    p.runs = [Run.with(part(0 ..< 6), one), Run.with(part(6 ..< 12), two), Run.with(part(12 ..< t.count), one)]
                    sh.text?.paragraphs[0] = p
                }
            }
            let v = s.run("review.spelling")
            let got = (v.asArray ?? []).map { "\($0.get("word")?.asStr ?? "") \($0.get("lang")?.asStr ?? "") \($0.get("start")?.asU64 ?? 0)" }
            #expect(got == ["deckcraft xx-ONE 12"])
            s.run("review.addToDictionary", #"{"word": "deckcraft"}"#)
            #expect(s.run("review.spelling").asArray?.isEmpty == true)
            #expect(try String(contentsOf: dir.appending(path: "user.dic"), encoding: .utf8) == "deckcraft\n")
        }
    }
}

// MARK: - thesaurus.rs

@Suite("Thesaurus")
struct ThesaurusTests {
    /// thesaurus.rs `senses_endings_and_case`.
    @Test func sensesEndingsAndCase() {
        let g = Thesaurus.lookup("goal")
        #expect(g.count == 1)
        #expect(g.first?.synonyms.contains("objective") == true)
        #expect(Thesaurus.lookup("change").count == 2, "verb and noun senses")
        #expect(Thesaurus.lookup("Goals").first?.synonyms.first == "Aim")
        #expect(Thesaurus.lookup("GOAL").first?.synonyms.first == "AIM")
        #expect(Thesaurus.lookup("improved").first?.word == "improve")
        #expect(Thesaurus.lookup("growing").first?.word == "grow")
        #expect(Thesaurus.lookup("strategies").first?.word == "strategy")
        #expect(Thesaurus.lookup("“goal,”").first?.word == "goal", "punctuation around the word")
        #expect(Thesaurus.lookup("").isEmpty && Thesaurus.lookup("zzxq").isEmpty && Thesaurus.lookup("   ").isEmpty)
        #expect(Thesaurus.lookup(String(repeating: "a", count: 10_000)).isEmpty)
    }

    /// thesaurus.rs `data_is_well_formed`.
    @Test func dataIsWellFormed() {
        for l in rustLines(Thesaurus.data) where !l.hasPrefix("#") && !rustTrim(l).isEmpty {
            guard let bar = l.firstIndex(of: "|") else {
                Issue.record("no `|`: \(l)")
                continue
            }
            let h = String(l[..<bar])
            #expect(rustEqual(h, rustLowercase(String(rustTrim(h)))), "\(l)")
            let syn = l[l.index(after: bar)...].split(separator: ",", omittingEmptySubsequences: false).map { String(rustTrim(String($0))) }
            #expect(syn.count >= 2 && syn.allSatisfy { !$0.isEmpty && $0 != h }, "\(l)")
            #expect(Set(syn).count == syn.count, "duplicate synonym: \(l)")
        }
    }

    /// thesaurus.rs `commands_look_up_and_replace_the_word_at_the_caret`.
    @Test func commandsLookUpAndReplaceTheWordAtTheCaret() {
        let s = session()
        let id = insertTextBox(s, [50, 50, 400, 40], "")
        s.run("text.edit", "{\"id\": \(id.rawValue)}")
        s.run("text.insert", #"{"text": "Our Goal is growth."}"#)
        s.run("text.edit", "{\"id\": \(id.rawValue), \"at\": [0, 6]}")
        let r = s.run("review.thesaurus")
        #expect(r.get("word") == "Goal")
        #expect(r.get("senses")?.at(0)?.get("synonyms")?.at(0) == "Aim")
        s.run("review.replaceWord", #"{"with": "Aim"}"#)
        #expect(s.st.shape(id)?.text?.paragraphs[0].text == "Our Aim is growth.")
        s.run("edit.undo")
        #expect(s.st.shape(id)?.text?.paragraphs[0].text == "Our Goal is growth.")
        #expect(s.run("review.thesaurus", #"{"word": "growth."}"#).get("senses")?.at(0)?.get("word") == "growth")
        #expect(s.fails("review.replaceWord", #"{"with": ""}"#))
    }
}
