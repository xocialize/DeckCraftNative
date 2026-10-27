// Ported from deckcraft crates/model/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), plus checks of the JSON shape serde writes.
import DCColor
import DCCore
import DCGeometry
@testable import DCModel
import Testing

private func ctx(_ p: Presentation, _ s: Slide) throws -> Resolve.Ctx {
    try #require(Resolve.Ctx.forSlide(p, s))
}

@Suite struct ModelTests {
    @Test func newPresentationIsValid() throws {
        let p = Presentation.default
        #expect(p.slides.count == 1)
        #expect(p.masters.count == 1)
        #expect(p.masters[0].layouts.count == 11)
        #expect(p.validate().isEmpty, "\(p.validate())")
        let s = p.slides[0]
        let (m, l) = try #require(p.masterFor(s))
        #expect(l?.kind == .title)
        #expect(m.theme.name == "DeckCraft")
        // Title slide has a centred title and a subtitle.
        #expect(s.shapes.compactMap(\.phType) == [.ctrTitle, .subTitle])
    }

    @Test func placeholderInheritsPositionAndStyles() throws {
        let p = Presentation.default
        let s = p.slides[0]
        let c = try ctx(p, s)
        let title = s.shapes[0]
        let x = Resolve.xfrm(c, title)
        #expect(Swift.abs(x.x - 120.0) < 1e-9 && Swift.abs(x.w - 720.0) < 1e-9)
        let lvl = Resolve.levelStyle(c, title, 0)
        #expect(lvl.run.size == 60.0) // layout overrides the master's 44
        #expect(lvl.para.align == .center)
        #expect(Resolve.fontFamily(c, lvl.run) == "Inter")
        #expect(Resolve.body(c, title).anchor == .bottom)
    }

    @Test func bodyLevelsFromMaster() throws {
        var p = Presentation.default
        let lay = try #require(layoutOfKind(p, .titleAndContent))
        let made = newSlide(&p, lay)
        let s = try #require(made)
        let c = try ctx(p, s)
        let body = s.shapes[1]
        #expect(body.phType == .obj)
        let l0 = Resolve.levelStyle(c, body, 0)
        let l1 = Resolve.levelStyle(c, body, 1)
        #expect(l0.run.size == 28.0)
        #expect(l1.run.size == 24.0)
        guard case .char? = l0.para.bullet else {
            Issue.record("expected a character bullet")
            return
        }
    }

    @Test func shapeStyleFillResolvesThroughTheme() throws {
        let p = Presentation.default
        let c = try ctx(p, p.slides[0])
        var sh = Shape.default
        sh.style = .accent(.accent1)
        sh.xfrm = Xfrm(0, 0, 10, 10)
        let (f, ph) = Resolve.fill(c, sh)
        guard case .solid(let color)? = f else {
            Issue.record("expected solid")
            return
        }
        #expect(c.color(color, ph) == p.masters[0].theme.colors.get(.accent1))
        let (l, lph) = Resolve.line(c, sh)
        #expect(l.width != nil)
        #expect(lph != nil)
    }

    @Test func aGradientWithoutStopsTakesThemFromItsStyle() throws {
        // `a:gradFill` with only a direction: PowerPoint fills it with the stops of the theme gradient the
        // style's fillRef names, in the style's colour, along the shape's own direction.
        let p = Presentation.default
        let c = try ctx(p, p.slides[0])
        let own = Gradient(stops: [], shape: .linear(angle: 45.0, scaled: true), rotateWithShape: true, tile: [0, 0, 0, 0])
        var st = ShapeStyle.accent(.accent2)
        st.fillRef.a = 3
        var sh = Shape.default
        sh.style = st
        sh.fill = .gradient(own)
        let (f, ph) = Resolve.fill(c, sh)
        guard case .gradient(let g)? = f, case .gradient(let theme)? = p.masters[0].theme.format.fills.at(2) else {
            Issue.record("expected gradients")
            return
        }
        #expect(g.stops == theme.stops)
        #expect(g.shape == own.shape, "the shape's own direction")
        #expect(ph == p.masters[0].theme.colors.get(.accent2))
        // A solid style fill has no stops to give: the gradient stays empty (draws nothing).
        st.fillRef.a = 1
        sh.style = st
        #expect(Resolve.fill(c, sh).fill == .gradient(own))
    }

    @Test func jsonRoundtrip() throws {
        let p = Presentation.default
        let j = JSONWriter().bytes(p.toJSON())
        let q = try Presentation(fromJSON: try JSONParser.parse(j))
        #expect(p == q)
        #expect(JSONWriter().bytes(q.toJSON()) == j)
        // Unknown and missing fields are tolerated.
        let r = try Presentation(fromJSON: try JSONParser.parse(#"{"slides":[],"zzz":1}"#))
        #expect(r.slides.isEmpty)
    }

    /// A deck whose ids are used up (a hostile file can arrive that way) yields no further ids:
    /// allocating never repeats one (#407).
    @Test func exhaustedIdSpaceAllocatesNothing() {
        var p = Presentation.default
        p.nextId = .max
        let first = p.allocId()
        let second = p.allocId()
        #expect(first == nil && second == nil)
        let media = p.addMedia("x.png", "image/png", [9])
        #expect(media == nil, "fresh media bytes are refused too")
        let lay = layoutOfKind(p, .titleAndContent) ?? LayoutId(0)
        let refused = newSlide(&p, lay)
        #expect(refused == nil, "a new slide is refused")
    }

    @Test func idsAreUniqueAndFixNextId() throws {
        var p = Presentation.default
        let a0 = p.allocId()
        let b0 = p.allocId()
        let a = try #require(a0)
        let b = try #require(b0)
        #expect(b > a)
        p.nextId = 0
        p.fixNextId()
        #expect(p.nextId >= Swift.min(b, p.nextId))
        let c0 = p.allocId()
        let c = try #require(c0)
        var all: [UInt32] = []
        for s in p.slides {
            all.append(s.id.rawValue)
            walk(s.shapes) { sh, _ in all.append(sh.id.rawValue) }
        }
        #expect(!all.contains(c))
    }

    @Test func groupFindAndWalk() {
        var child = Shape.default
        child.id = ShapeId(900)
        var g = Shape.default
        g.id = ShapeId(901)
        g.kind = .group(children: [child], child: Xfrm(0, 0, 1, 1))
        var slide = Slide.default
        slide.shapes = [g]
        #expect(slide.shape(ShapeId(900)) != nil)
        let found: Void? = slide.mutateShape(ShapeId(900)) { $0.name = "found" }
        #expect(found != nil)
        #expect(slide.shape(ShapeId(900))?.name == "found")
        var n = 0
        walk(slide.shapes) { _, _ in n += 1 }
        #expect(n == 2)
    }

    @Test func textBodyHelpers() {
        var t = TextBody.fromText("Hello\nWorld")
        #expect(t.text == "Hello\nWorld")
        #expect(t.charLen == 11)
        t.paragraphs[0].runs.append(Run(" there"))
        t.paragraphs[0].normalize()
        #expect(t.paragraphs[0].runs.count == 1)
        #expect(t.paragraphs[0].text == "Hello there")
    }

    @Test func builtinThemesHaveDistinctNames() {
        let t = builtinThemes()
        #expect(Set(t.map(\.name)).count == t.count)
        #expect(t.count >= 8)
    }

    @Test func fourByThreeMasterScales() throws {
        let p = blankPresentation(standardSlideSize, .default, true)
        let title = try #require(p.masters[0].shapes.first { $0.phType == .title })
        let x = try #require(title.xfrm)
        #expect(x.x + x.w <= 720.0 + 1e-6)
    }

    @Test func hyperlinkedRunsTakeTheThemeHyperlinkLook() throws {
        let p = Presentation.default
        let s = p.slides[0]
        let c = try ctx(p, s)
        let title = s.shapes[0]
        let para = Paragraph()
        let link = Hyperlink(action: .url(url: "https://example.org"), tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
        let hlink = Fill.solid(.scheme(.hlink))
        // The title's master style colours its text tx1; a link is hlink and underlined instead.
        #expect(Resolve.run(c, title, para, RunProps()).fill == .solid(.scheme(.tx1)))
        let r = Resolve.run(c, title, para, RunProps(link: link))
        #expect(r.fill == hlink && r.underline == "sng")
        #expect(c.color(.scheme(.hlink), nil) == p.masters[0].theme.colors.get(.hlink))
        // A slide link looks the same.
        let slide = Hyperlink(action: .slide(slide: s.id), tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
        #expect(Resolve.run(c, title, para, RunProps(link: slide)).fill == hlink)
        // The run's own colour and underline win; u="none" removes the underline.
        let red = Fill.solid(.rgb(.rgb(255, 0, 0)))
        let own = Resolve.run(c, title, para, RunProps(underline: "none", fill: red, link: link))
        #expect(own.fill == red && own.underline == "none")
        let dbl = Resolve.run(c, title, para, RunProps(underline: "dbl", link: link))
        #expect(dbl.fill == hlink && dbl.underline == "dbl")
    }

    @Test func aLayoutColourMapOverrideAppliesToItsSlides() throws {
        // A dark "section" layout maps bg1→dk1 and tx1→lt1; a slide on it that keeps the master mapping
        // (`masterClrMapping`) follows the layout, as PowerPoint draws it.
        var p = Presentation.default
        let dark = [("bg1", "dk1"), ("tx1", "lt1"), ("bg2", "dk2"), ("tx2", "lt2")].map { Pair($0.0, $0.1) }
        let layout = p.slides[0].layout
        let colors = p.masters[0].theme.colors
        let li = try #require(p.masters[0].layouts.firstIndex { $0.id == layout })
        p.masters[0].layouts[li].colorMap = dark
        let s = p.slides[0]
        let c = try ctx(p, s)
        #expect(c.color(.scheme(.bg1), nil) == colors.get(.dk1))
        #expect(c.color(.scheme(.tx2), nil) == colors.get(.lt2))
        #expect(c.scheme.get(.lt1) == colors.get(.dk1))
        // The slide's own override wins over the layout's.
        var own = s
        own.colorMap = [Pair("bg1", "lt1"), Pair("tx1", "dk1")]
        #expect(try ctx(p, own).color(.scheme(.bg1), nil) == colors.get(.lt1))
        // The layout itself draws with its override; the master keeps its own map.
        let m = p.masters[0]
        let l = try #require(m.layout(layout))
        #expect(Resolve.Ctx.forLayout(p, m, l).color(.scheme(.bg1), nil) == colors.get(.dk1))
        #expect(Resolve.Ctx.forMaster(p, m).color(.scheme(.bg1), nil) == colors.get(.lt1))
    }

    @Test func siblingListsAndParentsReachIntoGroups() {
        func leaf(_ id: UInt32) -> Shape {
            var s = Shape.default
            s.id = ShapeId(id)
            return s
        }
        func group(_ id: UInt32, _ children: [Shape]) -> Shape {
            var s = leaf(id)
            s.kind = .group(children: children, child: Xfrm())
            return s
        }
        var tree = [leaf(1), group(2, [leaf(3), group(4, [leaf(5)])]), leaf(6)]
        #expect(parentOf(tree, ShapeId(1)) == .some(nil))
        #expect(parentOf(tree, ShapeId(3)) == .some(ShapeId(2)))
        #expect(parentOf(tree, ShapeId(5)) == .some(ShapeId(4)))
        #expect(parentOf(tree, ShapeId(9)) == nil)
        let ids = { (v: inout [Shape]) in v.map(\.id.rawValue) }
        let top = mutateSiblings(&tree, ShapeId(6), ids)
        let inner = mutateSiblings(&tree, ShapeId(4), ids)
        let deepest = mutateSiblings(&tree, ShapeId(5), ids)
        let absent = mutateSiblings(&tree, ShapeId(9), ids)
        #expect(top == [1, 2, 6])
        #expect(inner == [3, 4])
        #expect(deepest == [5])
        #expect(absent == nil)
    }

    @Test func inkWidthFollowsPressureAndKeepsTheOldPlaceholder() {
        #expect(inkPressureIsLegacy([Triple(0, 0, 0.5), Triple(1, 1, 0.5)]))
        #expect(!inkPressureIsLegacy([Triple(0, 0, 0.5), Triple(1, 1, 1.0)]))
        #expect(!inkPressureIsLegacy([]))
        #expect(Swift.abs(inkSampleWidth(8.0, 0.5, true) - 8.0) < 1e-9)
        #expect(Swift.abs(inkSampleWidth(8.0, 1.0, false) - 8.0) < 1e-9)
        #expect(Swift.abs(inkSampleWidth(8.0, 0.25, false) - 2.0) < 1e-9)
        let floor = inkSampleWidth(8.0, 0.0, false)
        #expect(Swift.abs(floor - 0.64) < 1e-4, "a light touch stays visible, got \(floor)")
        #expect(Swift.abs(inkSampleWidth(8.0, .nan, false) - 8.0) < 1e-9)
    }

    @Test func tableTextTakesTheMastersOtherStyleAndShapesTheDefaultTextStyle() throws {
        // PowerPoint for Mac, with an otherStyle of 14 pt, a defaultTextStyle of 26 pt and a 36 pt
        // bodyStyle: a table cell's text is 14 pt, also in a table placed in a content placeholder; a
        // shape's and a text box's is 26 pt.
        var p = Presentation.default
        func size(_ pt: Double) -> LevelStyle { LevelStyle(run: RunProps(size: pt)) }
        p.defaultTextStyle.set(0, size(26.0))
        p.masters[0].otherStyle.set(0, size(14.0))
        p.masters[0].bodyStyle.set(0, size(36.0))
        let c = try ctx(p, p.slides[0])
        let para = Paragraph()
        func pt(_ sh: Shape) -> Double? { Resolve.run(c, sh, para, RunProps()).size }
        let body = TextBody.fromText("Cell")
        #expect(pt(Shape.tableCell(body)) == 14.0, "a table cell")
        var table = Shape.default
        table.kind = .table(.default)
        #expect(pt(table) == 14.0, "the table itself (its formatting state)")
        var inPlaceholder = table
        inPlaceholder.ph = Placeholder(kind: .obj, idx: 1)
        #expect(pt(inPlaceholder) == 14.0, "a table in a content placeholder")
        var shape = Shape.default
        shape.text = body
        #expect(pt(shape) == 26.0, "a shape")
        shape.textBox = true
        #expect(pt(shape) == 26.0, "a text box")
    }

    @Test func onlyWebAndMailLinksAreSafeToOpen() {
        for url in ["https://example.com", " HTTP://example.com/x", "mailto:someone@example.com"] {
            #expect(safeURL(url), "\(url)")
        }
        let refused = [
            "https://", "mailto:", "file:///C:/notes.pdf", "notes.pdf", "javascript:alert(1)", "ms-msdt:/id PCWDiagnostic",
            "ldap://attacker.example/x", "//attacker.example/share", "\\\\attacker.example\\share", "smb://attacker.example/share",
            "search-ms:query=x",
        ]
        for url in refused {
            #expect(!safeURL(url), "\(url)")
        }
    }

    /// The JSON shape serde writes for representative values: `null` for unskipped options, snake_case
    /// struct-variant fields, internally tagged enums, skipped defaults.
    @Test func jsonShapeMatchesSerde() throws {
        let w = JSONWriter()
        #expect(w.string(Fill.none_.toJSON()) == #"{"kind":"none"}"#)
        #expect(w.string(Fill.solid(.scheme(.tx1)).toJSON()) == #"{"kind":"solid","color":{"base":{"kind":"scheme","slot":"tx1"}}}"#)
        #expect(w.string(PictureMode.default.toJSON()) == #"{"kind":"stretch","fill_rect":[0.0,0.0,0.0,0.0]}"#)
        #expect(w.string(Spacing.pct(0.9).toJSON()) == #"{"kind":"pct","v":0.9}"#)
        #expect(w.string(AutoFit.shrink(fontScale: nil, lineReduction: 0).toJSON()) == #"{"kind":"shrink","line_reduction":0.0}"#)
        #expect(w.string(Run("a").toJSON()) == #"{"text":"a"}"#)
        #expect(w.string(Placeholder(kind: .title).toJSON()) == #"{"kind":"title","idx":0,"vertical":false,"size":null,"hasCustomPrompt":false}"#)
        // A missing struct-variant default and an absent option read back.
        let b = try Bullet(fromJSON: try JSONParser.parse(#"{"kind":"autoNum","scheme":"arabicPeriod"}"#))
        #expect(b == .autoNum(scheme: "arabicPeriod", startAt: 1))
    }
}
