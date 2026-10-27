// Port of deckcraft crates/pptx/tests/it/corpus_style.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned corpus: text effects, body layout, theme effects, fills, bevels and connectors.
// Open → save → reopen, twice, and compare the model.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

private func shadow(_ inner: Bool, _ dir: Double) -> Shadow {
    Shadow(
        color: ColorRef.rgb(inner ? .rgb(0, 0, 80) : .black).with(.alpha(50_000)),
        blur: inner ? 4.0 : 8.0,
        dist: inner ? 2.0 : 5.0,
        dir: dir,
        inner: inner,
        sx: inner ? 1.0 : 0.5,
        sy: 1.0,
        kx: 0.0,
        ky: inner ? 0.0 : 15.0,
        align: inner ? "" : "ctr",
        rotateWithShape: inner
    )
}

private func glow() -> Glow { Glow(color: .scheme(.accent3), radius: 10.0) }

private func reflection() -> Reflection { Reflection(blur: 2.0, startAlpha: 0.5, endAlpha: 0.0, endPos: 0.75, dist: 6.0) }

private func gradient(_ angle: Double) -> Fill {
    .gradient(Gradient(
        stops: [GradientStop(pos: 0.0, color: .rgb(.rgb(255, 80, 0))), GradientStop(pos: 1.0, color: .scheme(.accent1))],
        shape: .linear(angle: angle, scaled: true),
        rotateWithShape: true,
        tile: [0, 0, 0, 0]
    ))
}

private func styledRun() -> RunProps {
    var r = RunProps.default
    r.fill = gradient(20.0)
    var outline = Line.solid(.rgb(.rgb(0, 40, 80)), 1.5)
    outline.dash = .preset(name: "dash")
    r.outline = outline
    r.shadow = shadow(false, 135.0)
    r.innerShadow = shadow(true, 45.0)
    r.glow = glow()
    r.reflection = reflection()
    r.softEdge = 4.0
    return r
}

private let tabs = [
    TabStop(pos: 36.0, align: "l"),
    TabStop(pos: 72.0, align: "ctr"),
    TabStop(pos: 108.0, align: "r"),
    TabStop(pos: 144.0, align: "dec"),
]

private func styleDeck() throws -> Presentation {
    var p = newPresentation(nil)
    try #require(!p.masters.isEmpty, "master")
    var fx = Effects.default
    fx.glow = glow()
    fx.reflection = reflection()
    // Preset only: no kept `scene3d`/`sp3d`. A save must still write the bevel.
    fx.bevel = "circle"
    p.masters[0].theme.format.effects[0] = fx

    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    let sOpt = newSlide(&p, layout)
    var s = try #require(sOpt, "slide")

    var word = IT.shape(&p, "Styled text", 40.0, 40.0, 400.0, 180.0)
    var body = BodyProps.default
    body.autofit = .shrink(fontScale: 0.8, lineReduction: 0.2)
    body.columns = 2
    body.colSpacing = 12.0
    body.vert = .vertical270
    body.rtlCol = true
    var para = ParaProps.default
    para.align = .right
    para.rtl = true
    para.lineSpacing = .pct(1.5)
    para.spaceBefore = .pts(6.0)
    para.tabs = tabs
    word.text = TextBody(body: body, paragraphs: [Paragraph(props: para, runs: [Run.with("Gradient glow", styledRun())])])

    var path = IT.shape(&p, "Path gradient", 40.0, 260.0, 140.0, 100.0)
    path.fill = .gradient(Gradient(
        stops: [
            GradientStop(pos: 0.0, color: .rgb(.rgb(10, 20, 30))),
            GradientStop(pos: 0.5, color: .scheme(.accent5)),
            GradientStop(pos: 1.0, color: .rgb(.rgb(240, 240, 240))),
        ],
        shape: .path(path: "circle", focus: [0.2, 0.2, 0.2, 0.2]),
        rotateWithShape: false,
        tile: [0, 0, 0, 0]
    ))

    var patt = IT.shape(&p, "Pattern", 200.0, 260.0, 120.0, 80.0)
    patt.fill = .pattern(PatternFill(preset: "smCheck", fg: .scheme(.accent4), bg: .rgb(.white)))

    var named = IT.shape(&p, "Bevel preset", 460.0, 260.0, 80.0, 60.0)
    named.effects = Effects(bevel: "relaxedInset")

    var bevel = IT.shape(&p, "Bevel", 340.0, 260.0, 100.0, 80.0)
    bevel.effects = Effects(
        raw3d: "<a:scene3d><a:camera prst=\"orthographicFront\"><a:rot lat=\"0\" lon=\"0\" rev=\"0\"/></a:camera><a:lightRig rig=\"threePt\" dir=\"t\"/></a:scene3d><a:sp3d><a:bevelT w=\"63500\" h=\"25400\" prst=\"angle\"/></a:sp3d>"
    )

    let left = IT.shape(&p, "Left", 40.0, 400.0, 80.0, 40.0)
    let right = IT.shape(&p, "Right", 240.0, 400.0, 80.0, 40.0)
    let (leftId, rightId) = (left.id, right.id)
    var cx = IT.shape(&p, "Connector", 120.0, 420.0, 120.0, 0.0)
    cx.kind = .connector(start: Pair(leftId, 3), end: Pair(rightId, 1))
    cx.geom = .preset("straightConnector1")
    cx.line = Line.solid(.scheme(.tx1), 1.5)

    s.shapes += [word, path, patt, named, bevel, left, right, cx]
    p.slides.append(s)
    return p
}

private func byName(_ p: Presentation, _ name: String) throws -> Shape {
    try #require(p.slides.flatMap(\.shapes).first { bytesEqual($0.name, name) }, "missing \(name)")
}

private func runOf(_ p: Presentation) throws -> RunProps {
    let t = try #require(try byName(p, "Styled text").text, "text")
    return try #require(t.paragraphs.first?.runs.first).props
}

@Suite struct IntegrationCorpusStyleTests {
    // Rust: it/corpus_style.rs::style_kinds_round_trip
    @Test func styleKindsRoundTrip() throws {
        let p = try styleDeck()
        let once = try IT.round(p)
        let twice = try IT.round(once)

        let text = try #require(try byName(once, "Styled text").text, "text")
        let body = text.body
        #expect(body.autofit == .shrink(fontScale: 0.8, lineReduction: 0.2))
        #expect(body.columns == 2)
        #expect(body.colSpacing == 12.0)
        #expect(body.vert == .vertical270)
        #expect(body.rtlCol == true)
        let para = try #require(text.paragraphs.first).props
        #expect(para.rtl == true)
        #expect(para.align == .right)
        #expect(para.lineSpacing == .pct(1.5))
        #expect(para.spaceBefore == .pts(6.0))
        #expect(para.tabs == tabs)

        let got = try runOf(once)
        let expect = try runOf(p)
        #expect(got.fill == expect.fill, "text gradient")
        #expect(got.outline == expect.outline, "text outline")
        #expect(got.shadow == expect.shadow, "text shadow")
        #expect(got.glow == expect.glow, "text glow")
        #expect(got.innerShadow == expect.innerShadow, "text inner shadow")
        #expect(got.reflection == expect.reflection, "text reflection")
        #expect(got.softEdge == expect.softEdge, "text soft edge")
        #expect(try runOf(twice) == runOf(once))
        let t2 = try byName(twice, "Styled text").text, t1 = try byName(once, "Styled text").text
        #expect(t2?.body == t1?.body)
        #expect(t2?.paragraphs.first?.props == t1?.paragraphs.first?.props)

        #expect(try byName(once, "Path gradient").fill == byName(p, "Path gradient").fill)
        #expect(try byName(once, "Pattern").fill == byName(p, "Pattern").fill)
        #expect(try byName(twice, "Path gradient").fill == byName(once, "Path gradient").fill)
        #expect(try byName(twice, "Pattern").fill == byName(once, "Pattern").fill)

        let theme = once.masters[0].theme.format.effects[0]
        #expect(theme.glow == glow())
        #expect(theme.reflection == reflection())
        #expect(theme.bevel == "circle", "theme bevel preset")
        let theme2 = twice.masters[0].theme.format.effects[0]
        #expect(theme2.glow == theme.glow)
        #expect(theme2.reflection == theme.reflection)
        #expect(theme2.bevel == theme.bevel)
        #expect(theme2.raw3d == theme.raw3d)

        let named = try #require(try byName(once, "Bevel preset").effects, "effects")
        #expect(named.bevel == "relaxedInset")
        #expect((named.raw3d ?? "").has("relaxedInset"))
        #expect(try byName(twice, "Bevel preset").effects?.bevel == "relaxedInset")

        let bevel = try #require(try byName(once, "Bevel").effects, "effects")
        #expect(bevel.bevel == "angle")
        let raw = bevel.raw3d ?? ""
        #expect(raw.has("bevelT") && raw.has("angle") && raw.has("scene3d"), "\(raw)")
        #expect(try byName(twice, "Bevel").effects?.raw3d == raw)

        let c = try byName(once, "Connector")
        let leftId = try byName(p, "Left").id, rightId = try byName(p, "Right").id
        if case .connector(let start?, let end?) = c.kind {
            #expect(start.b == 3 && end.b == 1 && start.a == leftId && end.a == rightId, "\(c.kind)")
        } else {
            Issue.record("\(c.kind)")
        }
        #expect(try c.line == byName(p, "Connector").line)
        #expect(try c.geom == byName(p, "Connector").geom)
        #expect(try byName(twice, "Connector").kind == c.kind)
    }
}
