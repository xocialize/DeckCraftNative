// DCEngineTests — media references, built-in sounds, keys, connectors, fonts, the sample deck and the
// Selection pane.
// Ports the tests of deckcraft crates/engine/src/media_refs.rs, sounds.rs, keys.rs, tests_keys.rs,
// cmd/selection_tests.rs and the sample and connector tests of tests.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCRender
import Foundation
import Testing

private func pf(_ media: UInt32) -> PictureFill { PictureFill(media: MediaId(media)) }

/// One reference of each kind, every one a different id.
private func mediaDeck() -> Presentation {
    var p = newPresentation(nil)
    var s = p.slides.first ?? .default
    var pic = Shape.default
    var f = pf(9001)
    f.artistic = Artistic(effect: "artisticBlur", original: MediaId(9002))
    pic.kind = .picture(fill: f)
    var clip = Shape.default
    clip.kind = .media(MediaClip(media: MediaId(9003), poster: MediaId(9004)))
    var text = TextBody.fromText("x")
    text.paragraphs[0].props.bullet = .picture(media: MediaId(9007))
    var filled = Shape.default
    filled.fill = .picture(pf(9005))
    filled.click = Hyperlink(action: .nextSlide, tooltip: "", highlightClick: false, sound: MediaId(9006), stopSound: false, zoomReturn: nil)
    filled.text = text
    var group = Shape.default
    group.kind = .group(children: [pic, clip], child: Xfrm())
    s.shapes = [group, filled]
    s.background = .fill(fill: .picture(pf(9008)))
    p.slides = [s]
    p.masters[0].theme.format.bgFills.append(.picture(pf(9009)))
    var e = EmbeddedFont.default
    e.regular = MediaId(9010)
    p.embeddedFonts.append(e)
    return p
}

@Suite("Media references")
struct MediaRefsTests {
    @Test func everyKindOfReferenceIsFound() throws {
        let p = mediaDeck()
        #expect(MediaRefs.presentationMedia(p).sorted() == (9001 ... 9010).map(MediaId.init))
        #expect(MediaRefs.slideMedia(try #require(p.slides.first)).sorted() == (9001 ... 9008).map(MediaId.init))
    }

    @Test func visitMutRewritesEveryReference() throws {
        var s = try #require(mediaDeck().slides.first)
        MediaRefs.VisitMut.slide(&s) { $0 = MediaId($0.rawValue + 100) }
        #expect(MediaRefs.slideMedia(s).sorted() == (9101 ... 9108).map(MediaId.init))
    }

    /// SmartArt and OLE objects keep their parts as media items (#209); those count as used.
    @Test func keptPartsOfUnmodelledObjectsAreReferences() {
        var opaque = Shape.default
        opaque.kind = .opaque(xml: "", preview: MediaId(9101), label: "object", parts: [Triple("rId2", "oleObject", MediaId(9102))])
        #expect(MediaRefs.shapesMedia([opaque]) == [MediaId(9101), MediaId(9102)])
    }
}

@Suite("Built-in sounds")
struct SoundsTests {
    @Test func everyBuiltinSoundIsAWAV() {
        for (id, _) in Sounds.builtin {
            let bytes = Sounds.builtin(id) ?? []
            #expect(bytes.count > 44, "\(id)")
            #expect(bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8 ..< 16]) == Array("WAVEfmt ".utf8), "\(id)")
            let dataLen = Int(bytes[40]) | Int(bytes[41]) << 8 | Int(bytes[42]) << 16 | Int(bytes[43]) << 24
            #expect(dataLen == bytes.count - 44, "\(id)")
            let seconds = Double(dataLen / 2) / 22_050
            #expect(seconds > 0.01 && seconds < 2.0, "\(id): \(seconds)")
        }
        #expect(Sounds.builtin("nope") == nil)
        // Deterministic: the same bytes every time.
        #expect(Sounds.builtin("whoosh") == Sounds.builtin("whoosh"))
    }
}

@Suite("Keys")
struct KeysTests {
    @Test func shortcutParsing() {
        func m(_ shift: Bool, _ alt: Bool, _ cmd: Bool) -> Mods { Mods(shift: shift, alt: alt, cmd: cmd) }
        #expect(Keys.shortcutMatches("Cmd+B", "b", m(false, false, true)))
        #expect(!Keys.shortcutMatches("Cmd+B", "b", m(true, false, true)))
        #expect(Keys.shortcutMatches("Cmd+Shift+]", "]", m(true, false, true)))
        #expect(Keys.shortcutMatches("Cmd+Shift+.", ".", m(true, false, true)))
        #expect(Keys.shortcutMatches("Delete", "Delete", m(false, false, false)))
        #expect(Keys.shortcutMatches("Cmd++", "+", m(false, false, true)))
        #expect(Keys.keyToken("ArrowLeft") == "left")
        #expect(Keys.keyToken("CloseBracket") == "]")
        #expect(Keys.keyToken("Period") == ".")
    }

    @Test func keysWithoutAShapeDriveTheSlides() throws {
        let s = session()
        for _ in 0 ..< 3 { s.run("slide.new") }
        _ = try s.key("Home", Mods())
        #expect(s.st.selection.slide == 0)
        _ = try s.key("PageDown", Mods())
        _ = try s.key("ArrowDown", Mods())
        #expect(s.st.selection.slide == 2)
        _ = try s.key("End", Mods())
        #expect(s.st.selection.slide == 3)
        _ = try s.key("Up", Mods())
        #expect(s.st.selection.slide == 2)
        // Tab cycles through the slide's shapes, Escape lets go.
        _ = try s.key("Tab", Mods())
        let first = s.st.selection.shapes
        #expect(first.count == 1)
        _ = try s.key("Tab", Mods())
        #expect(s.st.selection.shapes != first)
        _ = try s.key("Tab", Mods(shift: true))
        #expect(s.st.selection.shapes == first)
        _ = try s.key("Escape", Mods())
        #expect(s.st.selection.shapes.isEmpty)
        // Enter makes a new slide; registry shortcuts run their command.
        let n = s.st.doc.slides.count
        _ = try s.key("Enter", Mods())
        #expect(s.st.doc.slides.count == n + 1)
        let r = try s.key("z", Mods(cmd: true))
        #expect(r.get("command") == "edit.undo")
        #expect(s.st.doc.slides.count == n)
        #expect(try s.key("F13", Mods()).get("handled") == false)
    }

    @Test func deleteKeyRemovesTheSelectedShape() throws {
        let s = session()
        _ = try s.key("Tab", Mods())
        #expect(s.st.selection.shapes.count == 1)
        _ = try s.key("Backspace", Mods())
        #expect(s.st.currentSlide?.shapes.count == 1)
        #expect(s.st.selection.shapes.isEmpty)
    }

    @Test func typingWithNothingSelectedIsNotHandled() throws {
        let s = session()
        #expect(try s.typeText("x") == ["handled": false])
        #expect(try s.composeText("x", nil) == ["handled": false])
        #expect(try s.commitText("x") == ["handled": false])
    }

    @Test(.enabled(if: ported("text.edit", "text.selectAll", "text.insert", "text.exit", "text.get", "text.delete", "format.bold", "shape.move")))
    func keysDriveEditing() throws {
        let s = session()
        let title = try #require(s.st.currentSlide?.shapes.first?.id)
        s.run("edit.select", "{\"ids\": [\(title)]}")
        _ = try s.typeText("Hi")
        _ = try s.key("Enter", Mods())
        _ = try s.typeText("there")
        _ = try s.key("Backspace", Mods())
        _ = try s.key("Escape", Mods())
        #expect(s.run("text.get", "{\"id\": \(title)}").get("text") == "Hi\nther")
        let r = try s.key("b", Mods(cmd: true))
        #expect(r.get("command") == "format.bold")
        _ = try s.key("Right", Mods())
        _ = try s.key("Delete", Mods())
        #expect(s.st.currentSlide?.shapes.count == 1)
    }
}

/// Text-editing keys driven through `Session.key`, as the keyboard, control channel and MCP send them.
/// Every expectation is PowerPoint for Windows' observed behaviour unless it says Mac. (tests_keys.rs)
@Suite("Text keys", .enabled(if: ported("insert.textBox", "text.set", "text.edit", "text.get", "text.move", "text.select", "text.delete", "text.insert", "text.selectAll")))
struct TextKeysTests {
    static let none = Mods()
    static let ctrl = Mods(cmd: true)
    static let ctrlShift = Mods(shift: true, cmd: true)
    static let shift = Mods(shift: true)
    static let alt = Mods(alt: true)

    /// A session editing a new text box holding `text` (Windows keys), caret at `at`.
    func editing(_ text: String, _ at: (Int, Int), _ rect: [Double] = [60, 60, 600, 300]) -> (Session, UInt32) {
        let s = Session.withNew()
        s.macKeys = false
        s.prefs.autocorrect = false
        s.prefs.smartQuotes = false
        s.run("insert.textBox", JSON.object(JSONObject(["rect": .array(rect.map { .num($0) }), "text": "x"])).display)
        let id = s.st.selection.shapes.first?.rawValue ?? 0
        s.run("text.set", JSON.object(JSONObject(["id": .integer(id), "text": .string(text)])).display)
        s.run("text.edit", "{\"id\": \(id), \"at\": [\(at.0), \(at.1)]}")
        return (s, id)
    }

    func sel(_ s: Session) -> ((Int, Int), (Int, Int)) {
        let t = s.st.selection.text ?? TextSel()
        return ((t.anchor.para, t.anchor.char), (t.caret.para, t.caret.char))
    }

    func caret(_ s: Session) -> (Int, Int) { sel(s).1 }

    func sameSel(_ s: Session, _ a: (Int, Int), _ c: (Int, Int)) -> Bool { sel(s).0 == a && sel(s).1 == c }

    @discardableResult
    func press(_ s: Session, _ key: String, _ mods: Mods, sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        let r = (try? s.key(key, mods)) ?? .null
        #expect(r.get("handled") == true, "\(key) \(mods) not handled", sourceLocation: sourceLocation)
        return r
    }

    func text(_ s: Session, _ id: UInt32) -> String { s.run("text.get", "{\"id\": \(id)}").get("text")?.asStr ?? "" }

    /// Press `key` until the caret stops moving; the carets visited (in the first paragraph).
    func walk(_ s: Session, _ key: String, _ mods: Mods) -> [Int] {
        var out = [caret(s).1]
        for _ in 0 ..< 200 {
            let before = caret(s)
            press(s, key, mods)
            if caret(s) == before { break }
            out.append(caret(s).1)
        }
        return out
    }

    @Test func ctrlArrowsStopWherePowerPointDoes() {
        let t = "Hello, world!  Foo...bar baz-qux it's 3.14 e.g. a_b x@y.com (end) \"q\" end."
        let stops = [0, 5, 7, 12, 15, 18, 21, 25, 33, 38, 43, 44, 45, 46, 48, 49, 50, 52, 53, 54, 55, 56, 60, 61, 64, 66, 67, 68, 70, 73, 74]
        let (s, _) = editing(t, (0, 0))
        #expect(walk(s, "ArrowRight", Self.ctrl) == stops)
        #expect(walk(s, "ArrowLeft", Self.ctrl) == stops.reversed())
    }

    @Test func ctrlArrowsOverCJKRTLEmojiAndMarks() {
        var (s, _) = editing("日本語のテキスト abc 한국어", (0, 0))
        #expect(walk(s, "Right", Self.ctrl) == [0, 1, 2, 3, 4, 5, 6, 7, 9, 13, 14, 15, 16])
        (s, _) = editing("Hello مرحبا بالعالم world שלום end", (0, 0))
        #expect(walk(s, "Right", Self.ctrl) == [0, 6, 12, 20, 26, 31, 34])
        (s, _) = editing("e\u{301}te 👨\u{200d}👩\u{200d}👧 x", (0, 0))
        #expect(walk(s, "Right", Self.ctrl) == [0, 5, 11, 12])
        #expect(walk(s, "Left", Self.ctrl) == [12, 11, 5, 0])
    }

    @Test func ctrlArrowsCrossParagraphsLineBreaksAndTabs() {
        let (s, id) = editing("One two\nThree four\n\nFive", (0, 0))
        var seen = [caret(s)]
        for _ in 0 ..< 9 {
            press(s, "Right", Self.ctrl)
            seen.append(caret(s))
        }
        let want = [(0, 0), (0, 4), (0, 7), (1, 0), (1, 6), (1, 10), (2, 0), (3, 0), (3, 4), (3, 4)]
        #expect(seen.count == want.count && zip(seen, want).allSatisfy { $0 == $1 })
        s.run("text.set", "{\"id\": \(id), \"text\": \"x\"}")
        s.run("text.edit", "{\"id\": \(id), \"at\": [0, 0]}")
        s.run("text.selectAll")
        s.run("text.insert", JSON.object(JSONObject(["text": "Five\u{b}six seven\tTab   x"])).display)
        s.run("text.move", #"{"to": "start"}"#)
        #expect(walk(s, "Right", Self.ctrl) == [0, 4, 5, 9, 14, 15, 21, 22])
    }

    @Test func ctrlBackspaceAndDelete() {
        var (s, id) = editing("Hello world  foo, bar\nnext para", (0, 13))
        press(s, "Backspace", Self.ctrl)
        #expect(text(s, id) == "Hello foo, bar\nnext para")
        #expect(caret(s) == (0, 6))
        press(s, "Delete", Self.ctrl)
        #expect(text(s, id) == "Hello, bar\nnext para")
        #expect(caret(s) == (0, 5))
        s.run("text.move", #"{"to": "paraEnd"}"#)
        press(s, "Delete", Self.ctrl)
        #expect(text(s, id) == "Hello, barnext para")
        (s, id) = editing("Hello world", (0, 2))
        s.run("text.select", #"{"anchor": [0, 2], "caret": [0, 7]}"#)
        press(s, "Backspace", Self.ctrl)
        #expect(text(s, id) == "llo world" && sameSel(s, (0, 0), (0, 0)))
        (s, id) = editing("Hello world", (0, 7))
        s.run("text.select", #"{"anchor": [0, 7], "caret": [0, 2]}"#)
        press(s, "Delete", Self.ctrl)
        #expect(text(s, id) == "He world" && sameSel(s, (0, 2), (0, 2)))
        s.run("edit.undo")
        #expect(text(s, id) == "Hello world")
    }

    @Test func macKeys() throws {
        let (s, id) = editing("Hello world foo\nnext", (0, 8))
        s.macKeys = true
        press(s, "Right", Self.alt)
        #expect(caret(s) == (0, 12))
        press(s, "Left", Self.alt)
        #expect(caret(s) == (0, 6))
        press(s, "Right", Self.ctrl)
        #expect(caret(s) == (0, 15))
        press(s, "Left", Self.ctrl)
        #expect(caret(s) == (0, 0))
        press(s, "Down", Self.ctrl)
        #expect(caret(s) == (1, 4))
        press(s, "Up", Self.ctrl)
        #expect(caret(s) == (0, 0))
        s.run("text.edit", "{\"id\": \(id), \"at\": [0, 11]}")
        press(s, "Backspace", Self.alt)
        #expect(text(s, id) == "Hello  foo\nnext")
        s.macKeys = false
        let before = caret(s)
        let r = try s.key("Right", Self.alt)
        #expect(r.get("handled") == false && caret(s) == before)
    }

    @Test(.enabled(if: ported("text.selectWord", "text.selectParagraph")))
    func shiftEnterAndWordAndParagraphSelection() {
        let (s, id) = editing("Hello world,  foo bar\nnext", (0, 7))
        s.run("text.selectWord")
        #expect(sameSel(s, (0, 6), (0, 11)))
        s.run("text.selectWord", #"{"at": [0, 12]}"#)
        #expect(sameSel(s, (0, 11), (0, 12)))
        s.run("text.selectParagraph", #"{"at": [0, 3]}"#)
        #expect(sameSel(s, (0, 0), (1, 0)))
        s.run("text.selectParagraph", #"{"at": [1, 1]}"#)
        #expect(sameSel(s, (1, 0), (1, 4)))
        s.run("text.edit", "{\"id\": \(id), \"at\": [1, 2]}")
        press(s, "Enter", Self.shift)
        let b = s.st.shape(ShapeId(id))?.text
        #expect(b?.paragraphs.count == 2)
        #expect(b?.paragraphs.at(1)?.text == "ne\u{b}xt")
    }

    @Test func keysNeverTrapOnAnyText() {
        let texts = ["", " ", "\u{b}", "\t\t", "👨\u{200d}👩\u{200d}👧", "e\u{301}", "日本", "مرحبا", "a\n\nb", "  x  \n  "]
        let keys = ["Left", "Right", "Up", "Down", "Home", "End", "Backspace", "Delete"]
        for t in texts {
            for k in keys {
                for m in [Self.ctrl, Self.ctrlShift, Self.none, Self.shift, Self.alt] {
                    for at in [(0, 0), (0, 1), (5, 5)] {
                        let (s, _) = editing(t, at)
                        for _ in 0 ..< 3 { _ = try? s.key(k, m) }
                    }
                }
            }
        }
    }
}

@Suite("Connectors")
struct ConnectTests {
    @Test func reroutingMovesGluedEndsAndDropsMissingShapes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        var doc = s.st.doc
        let r1 = doc.allocId(), r2 = doc.allocId(), r3 = doc.allocId()
        let (a, b, c) = (ShapeId(try #require(r1)), ShapeId(try #require(r2)), ShapeId(try #require(r3)))
        var boxA = Shape.default
        boxA.id = a
        boxA.xfrm = Xfrm(100, 100, 100, 100)
        var boxB = Shape.default
        boxB.id = b
        boxB.xfrm = Xfrm(400, 100, 100, 100)
        var line = Shape.default
        line.id = c
        line.geom = .preset("line")
        line.kind = .connector(start: Pair(a, 3), end: Pair(b, 1))
        line.xfrm = Xfrm(0, 0, 10, 10)
        doc.slides[1].shapes = [boxA, boxB, line]
        s.st.docRef = DocRef(doc)
        // Any edit reroutes: the line now runs from A's right site to B's left site.
        try s.edit { _, _ in }
        var x = try #require(s.st.shape(c)?.xfrm)
        let (p0, p1) = Connect.endpoints(x)
        let sitesA = Connect.sites(s.st.doc, s.st.selection, boxA)
        let sitesB = Connect.sites(s.st.doc, s.st.selection, boxB)
        #expect(sitesA.count == 4 && p0 == sitesA[3] && p1 == sitesB[1], "\(p0) \(p1)")
        // Deleting B drops that end and keeps the geometry.
        s.run("edit.delete", "{\"ids\": [\(b)]}")
        guard case .connector(let start, let end)? = s.st.shape(c)?.kind else {
            Issue.record("not a connector")
            return
        }
        #expect(start == Pair(a, 3) && end == nil)
        x = try #require(s.st.shape(c)?.xfrm)
        #expect(Connect.endpoints(x).1 == p1)
        #expect(Connect.nearestSite(s.st.doc, s.st.selection, s.st.shapes, Point(201, 151), 5, nil)?.0 == a)
        #expect(Connect.siteShapeAt(s.st.doc, s.st.selection, s.st.shapes, Point(150, 150), 3, nil) == a)
        #expect(Tools.lineXfrm(Point(10, 10), Point(0, 0), 0) == Xfrm(x: 0, y: 0, w: 10, h: 10, rot: 0, flipH: true, flipV: true))
    }
}

@Suite("Fonts")
struct EngineFontsTests {
    @Test func usedAndMissingFontsAndReplace() {
        var p = Presentation.default
        var body = TextBody.fromText("Hello\nWorld")
        body.paragraphs[0].runs[0].props.font = "Qqq Missing"
        body.paragraphs[1].runs[0].props.font = "qqq missing"
        p.slides[0].shapes[0].text = body
        let used = EngineFonts.usedFonts(p)
        #expect(used.filter { $0.lowercased() == "qqq missing" }.count == 1, "\(used)")
        #expect(EngineFonts.missingFonts(p) == ["Qqq Missing"])
        #expect(EngineFonts.replaceFont(&p, "QQQ MISSING", "Inter") == 2)
        #expect(EngineFonts.missingFonts(p).isEmpty)
        #expect(EngineFonts.replaceFont(&p, "+mn-lt", "Inter") == 0, "theme references stay")
        let theme = p.masters[0].theme.fonts.major.latin
        #expect(EngineFonts.replaceFont(&p, theme, "Other Face") >= 1)
        #expect(p.masters[0].theme.fonts.major.latin == "Other Face")
    }
}

@Suite("Sample deck")
struct SampleTests {
    @Test(.enabled(if: ported(Sample.commands)))
    func sampleDeckBuildsAndRenders() throws {
        let s = Session()
        try Sample.openSample(s)
        #expect(s.st.doc.slides.count >= 8)
        #expect(s.st.doc.validate().isEmpty)
        #expect(!s.st.isDirty)
        for i in s.st.doc.slides.indices {
            #expect(renderSlide(s.st.doc, i, RenderOpts(scale: 0.2)).width == 192)
        }
        #expect((s.run("document.inspect").get("slides")?.asArray?.count ?? 0) >= 8)
    }

    @Test(.enabled(if: ported(Sample.commands)))
    func saveAndReopenTheSample() throws {
        let s = Session()
        try Sample.openSample(s)
        let bytes = try #require(s.run("file.saveBytes").get("data")?.asStr)
        let n = s.st.doc.slides.count
        s.run("file.openBytes", "{\"name\": \"x.deckcraft\", \"data\": \"\(bytes)\"}")
        #expect(s.st.doc.slides.count == n)
        #expect(s.documents.count == 2)
    }
}

/// A blank slide with A, B, C (back to front) and G = group [D, H = group [E, F]] in front.
private func paneDeck() -> (Session, [UInt32]) {
    let s = Session.withNew()
    s.run("slide.new", #"{"layout": "blank"}"#)
    var ids: [UInt32] = []
    for (i, n) in ["A", "B", "C", "D", "E", "F"].enumerated() {
        let x = 20.0 + 110.0 * Double(i)
        let id = UInt32(s.run("shape.insert", "{\"preset\": \"rect\", \"rect\": [\(x), 50, 100, 80]}").get("id")?.asU64 ?? 0)
        s.run("shape.rename", "{\"id\": \(id), \"name\": \"\(n)\"}")
        ids.append(id)
    }
    let h = UInt32(s.run("arrange.group", "{\"ids\": [\(ids[4]), \(ids[5])]}").get("id")?.asU64 ?? 0)
    s.run("shape.rename", "{\"id\": \(h), \"name\": \"H\"}")
    let g = UInt32(s.run("arrange.group", "{\"ids\": [\(ids[3]), \(h)]}").get("id")?.asU64 ?? 0)
    s.run("shape.rename", "{\"id\": \(g), \"name\": \"G\"}")
    return (s, ids + [h, g])
}

/// The tree as text, back to front: `A B C G[D H[E F]]`.
private func tree(_ s: Session) -> String {
    func rec(_ v: [Shape]) -> String { v.map { $0.isGroup ? "\($0.name)[\(rec($0.children))]" : $0.name }.joined(separator: " ") }
    return rec(s.st.shapes)
}

/// (hidden, locked)
private func flags(_ s: Session, _ id: UInt32) -> (Bool, Bool) {
    let sh = s.st.shape(ShapeId(id))
    return (sh?.hidden ?? false, sh?.locked ?? false)
}

private func selected(_ s: Session) -> [UInt32] { s.st.selection.shapes.map(\.rawValue) }

/// Selection pane: reorder, groups, hide/show, lock and undo (cmd/selection_tests.rs).
@Suite("Selection pane", .enabled(if: ported("shape.insert", "shape.rename", "arrange.group", "shape.visible", "shape.lock")))
struct SelectionPaneTests {
    @Test(.enabled(if: ported("arrange.bringForward", "arrange.sendBackward", "arrange.bringToFront", "arrange.sendToBack")))
    func bringForwardAndSendBackwardStayInsideTheGroup() {
        let (s, ids) = paneDeck()
        let (a, d, e, h) = (ids[0], ids[3], ids[4], ids[6])
        #expect(tree(s) == "A B C G[D H[E F]]")
        s.run("arrange.bringForward", "{\"ids\": [\(a)]}")
        #expect(tree(s) == "B A C G[D H[E F]]")
        s.run("arrange.bringForward", "{\"ids\": [\(d)]}")
        #expect(tree(s) == "B A C G[H[E F] D]")
        s.run("arrange.bringForward", "{\"ids\": [\(d)]}")
        #expect(tree(s) == "B A C G[H[E F] D]")
        s.run("arrange.sendBackward", "{\"ids\": [\(e)]}")
        #expect(tree(s) == "B A C G[H[E F] D]", "E is already at the back of H")
        s.run("arrange.bringToFront", "{\"ids\": [\(e)]}")
        #expect(tree(s) == "B A C G[H[F E] D]")
        s.run("arrange.sendToBack", "{\"ids\": [\(d)]}")
        #expect(tree(s) == "B A C G[D H[F E]]")
        s.run("arrange.bringForward", "{\"ids\": [\(h)]}")
        #expect(tree(s) == "B A C G[D H[F E]]", "H is already in front inside G")
        s.run("edit.undo")
        #expect(tree(s) == "B A C G[H[F E] D]")
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(tree(s) == "B A C G[D H[E F]]")
    }

    @Test(.enabled(if: ported("arrange.reorder")))
    func reorderIsTheDragAndDropAmongSiblings() {
        let (s, ids) = paneDeck()
        let (a, c, d, f, g) = (ids[0], ids[2], ids[3], ids[5], ids[7])
        #expect(s.run("arrange.reorder", "{\"id\": \(a), \"index\": 99}").get("index") == 3)
        #expect(tree(s) == "B C G[D H[E F]] A")
        s.run("arrange.reorder", "{\"id\": \(g), \"index\": 0}")
        #expect(tree(s) == "G[D H[E F]] B C A")
        s.run("arrange.reorder", "{\"id\": \(d), \"index\": 5}")
        #expect(tree(s) == "G[H[E F] D] B C A")
        s.run("arrange.reorder", "{\"id\": \(f), \"index\": 0}")
        #expect(tree(s) == "G[H[F E] D] B C A")
        let n = s.st.history.undo.count
        s.run("arrange.reorder", "{\"id\": \(c), \"index\": 2}")
        #expect(s.st.history.undo.count == n)
        s.run("edit.undo")
        #expect(tree(s) == "G[H[E F] D] B C A")
        s.run("edit.undo")
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(tree(s) == "A B C G[D H[E F]]")
        #expect(s.fails("arrange.reorder", #"{"id": 4242, "index": 0}"#))
        #expect(s.fails("arrange.reorder", "{\"id\": \(a)}"))
    }

    @Test func eyeShowAllAndHideAll() {
        let (s, ids) = paneDeck()
        let (a, b, d, e, g) = (ids[0], ids[1], ids[3], ids[4], ids[7])
        s.run("shape.visible", "{\"id\": \(b), \"visible\": false}")
        #expect(flags(s, b).0)
        // Hiding a group hides only the group; its children keep their own flags.
        s.run("shape.visible", "{\"id\": \(g)}")
        #expect(flags(s, g).0 && !flags(s, d).0)
        s.run("shape.visible", "{\"id\": \(e), \"visible\": false}")
        // Hide All hides the top level only.
        s.run("selection.hideAll")
        #expect(flags(s, a).0 && flags(s, g).0 && !flags(s, d).0 && flags(s, e).0)
        // Show All shows everything, children included.
        s.run("selection.showAll")
        for id in ids { #expect(!flags(s, id).0, "\(id) still hidden") }
        let n = s.st.history.undo.count
        s.run("selection.showAll")
        #expect(s.st.history.undo.count == n, "nothing to show: no undo step")
        s.run("edit.undo")
        #expect(flags(s, a).0 && flags(s, e).0)
        s.run("edit.undo")
        #expect(!flags(s, a).0 && flags(s, g).0 && flags(s, e).0)
    }

    @Test func lockCascadesThroughGroupsAndUndoes() {
        let (s, ids) = paneDeck()
        let (a, d, e, h, g) = (ids[0], ids[3], ids[4], ids[6], ids[7])
        s.run("shape.lock", "{\"id\": \(a)}")
        #expect(flags(s, a).1)
        s.run("shape.lock", "{\"id\": \(a)}")
        #expect(!flags(s, a).1, "toggles")
        s.run("shape.lock", "{\"id\": \(g), \"locked\": true}")
        #expect(flags(s, g).1 && flags(s, d).1 && flags(s, h).1 && flags(s, e).1)
        s.run("shape.lock", "{\"id\": \(d), \"locked\": false}")
        #expect(flags(s, g).1 && !flags(s, d).1)
        s.run("shape.lock", "{\"id\": \(g)}")
        #expect(!flags(s, g).1 && !flags(s, h).1 && !flags(s, e).1)
        s.run("edit.undo")
        #expect(flags(s, g).1 && !flags(s, d).1 && flags(s, e).1)
        s.run("edit.undo")
        s.run("edit.undo")
        #expect(!flags(s, g).1 && !flags(s, e).1)
    }

    @Test(.enabled(if: ported("shape.move", "shape.resize", "shape.setBounds", "shape.rotate", "shape.flip", "arrange.align", "shape.change", "shape.fill")))
    func lockedObjectsRefuseMovingSizingRotatingButTakeFormatting() {
        let (s, ids) = paneDeck()
        let (a, b) = (ids[0], ids[1])
        func bx(_ id: UInt32) -> JSON { s.run("shape.inspect", "{\"id\": \(id)}").get("box") ?? .null }
        s.run("shape.lock", "{\"id\": \(a), \"locked\": true}")
        let before = bx(a)
        for (cmd, p) in [
            ("shape.move", "{\"ids\": [\(a)], \"dx\": 10}"), ("shape.resize", "{\"ids\": [\(a)], \"w\": 300}"),
            ("shape.setBounds", "{\"ids\": [\(a)], \"x\": 1, \"y\": 1, \"w\": 2, \"h\": 2}"), ("shape.rotate", "{\"ids\": [\(a)], \"deg\": 45}"),
            ("shape.flip", "{\"ids\": [\(a)], \"axis\": \"vertical\"}"), ("arrange.align", "{\"ids\": [\(a)], \"edge\": \"right\"}"),
            ("shape.change", "{\"ids\": [\(a)], \"preset\": \"ellipse\"}"),
        ] {
            #expect(s.fails(cmd, p), "\(cmd) changed a locked shape")
        }
        #expect(bx(a) == before)
        let bb = bx(b)
        s.run("shape.move", "{\"ids\": [\(a), \(b)], \"dx\": 10}")
        #expect(bx(a) == before)
        #expect(bx(b).get("x")?.asF64 == (bb.get("x")?.asF64 ?? 0) + 10)
        s.run("shape.fill", ##"{"ids": [A], "color": "#00ff00"}"##.replacingOccurrences(of: "A", with: "\(a)"))
        s.run("shape.rename", "{\"id\": \(a), \"name\": \"Anchor\"}")
        #expect(s.st.shape(ShapeId(a))?.name == "Anchor")
        s.run("edit.select", "{\"ids\": [\(a)]}")
        _ = try? s.key("ArrowRight", Mods())
        #expect(bx(a) == before)
    }

    @Test func selectFromThePane() {
        let (s, ids) = paneDeck()
        let (a, b, c, d, e, g) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[7])
        s.run("selection.select", "{\"id\": \(b)}")
        #expect(selected(s) == [b])
        s.run("selection.select", "{\"id\": \(c), \"toggle\": true}")
        #expect(selected(s) == [b, c])
        s.run("selection.select", "{\"id\": \(b), \"toggle\": true}")
        #expect(selected(s) == [c])
        s.run("selection.select", "{\"ids\": [\(a), \(b)], \"add\": true}")
        #expect(selected(s) == [c, a, b])
        s.run("selection.select", "{\"id\": \(d)}")
        #expect(selected(s) == [d])
        s.run("selection.select", "{\"id\": \(e), \"toggle\": true}")
        #expect(selected(s) == [d, e])
        s.run("selection.select", "{\"id\": \(g), \"toggle\": true}")
        #expect(selected(s) == [d, e])
        s.run("selection.select", "{\"id\": \(a)}")
        s.run("selection.select", "{\"id\": \(d), \"toggle\": true}")
        #expect(selected(s) == [a])
        let n = s.st.history.undo.count
        s.run("selection.select", "{\"id\": \(b)}")
        #expect(s.st.history.undo.count == n)
        s.run("shape.visible", "{\"id\": \(c), \"visible\": false}")
        s.run("selection.select", "{\"id\": \(c)}")
        #expect(selected(s) == [c])
        #expect(!flags(s, c).0, "picking a hidden object shows it")
        s.run("edit.undo")
        #expect(flags(s, c).0)
        #expect(s.fails("selection.select", #"{"id": 4242}"#))
    }

    @Test func renameFromThePaneUndoes() {
        let (s, ids) = paneDeck()
        let e = ids[4]
        s.run("shape.rename", "{\"id\": \(e), \"name\": \"Eagle\"}")
        #expect(s.st.shape(ShapeId(e))?.name == "Eagle")
        s.run("edit.undo")
        #expect(s.st.shape(ShapeId(e))?.name == "E")
    }
}
