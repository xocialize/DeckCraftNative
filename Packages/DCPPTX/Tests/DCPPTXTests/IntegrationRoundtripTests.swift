// Port of deckcraft crates/pptx/tests/it/roundtrip.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): round trips of decks built in code, model → PPTX → model.
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCZip
import Foundation
import Testing
@testable import DCPPTX

/// `by_name`: the first shape named `name` on `s`, groups included.
private func rtByName(_ s: Slide, _ name: String) throws -> Shape {
    try #require(IT.find(s.shapes, name), "no shape \(name)")
}

/// A one-slide deck's slide XML for each transition in `list` (kind, option, ms, advance after).
private func rtTransitionDeck(_ list: [(String, String, UInt32, UInt32?)]) throws -> (Presentation, [String]) {
    var p = newPresentation(nil)
    let base = p.slides[0]
    p.slides.removeAll()
    for (kind, option, ms, adv) in list {
        var s = base
        let n = p.allocId()
        s.id = SlideId(try #require(n, "ids"))
        var t = Transition.default
        t.kind = kind
        t.option = option
        t.durationMs = ms
        t.advanceOnClick = adv == nil
        t.advanceAfterMs = adv
        s.transition = t
        p.slides.append(s)
    }
    let bytes = try PPTX.export(p)
    let xml = try (1 ... list.count).map { i in
        String(decoding: try #require(IT.part(bytes, "ppt/slides/slide\(i).xml"), "slide"), as: UTF8.self)
    }
    return (p, xml)
}

/// The package `bytes` with `ppt/slides/slide1.xml` replaced by `xml`.
private func rtWithSlide1(_ bytes: [UInt8], _ xml: String) throws -> [UInt8] {
    try IT.zip(IT.entries(bytes).map { e in
        e.name == "ppt/slides/slide1.xml" ? (e.name, Array(xml.utf8)) : e
    })
}

@Suite struct IntegrationRoundtripTests {
    private static func hyperlink(_ action: Action, tooltip: String = "", highlightClick: Bool = false) -> Hyperlink {
        Hyperlink(action: action, tooltip: tooltip, highlightClick: highlightClick, sound: nil, stopSound: false, zoomReturn: nil)
    }

    /// A deck exercising most of what the model can hold.
    static func richDeck() -> Presentation {
        var p = newPresentation(nil)
        p.props.title = "Rich deck"
        p.props.author = "DeckCraft tests"
        p.props.created = "2025-01-02T03:04:05Z"
        let img = p.addMedia("image1.png", "image/png", IT.png(40, 30, (200, 40, 40))) ?? MediaId(0)
        let img2 = p.addMedia("image2.png", "image/png", IT.png(8, 8, (20, 140, 220))) ?? MediaId(0)
        let video = p.addMedia("clip.mp4", "video/mp4", [0, 0, 0, 0x18] + Array("ftypmp42not-a-real-video".utf8)) ?? MediaId(0)

        // Slide 1: title slide with notes and formatted text.
        do {
            var s = p.slides[0]
            s.notes = TextBody.fromText("Speaker notes line 1\nline 2")
            var bold = RunProps.default
            bold.bold = true
            bold.size = 40.0
            var red = RunProps.default
            red.italic = true
            red.fill = Fill.solid(ColorRef.rgb(Rgba.rgb(255, 0, 0)))
            red.underline = "sng"
            red.strike = .single
            red.caps = .small
            red.spacing = 1.5
            red.baseline = 0.3
            red.font = "Lato"
            red.lang = "en-GB"
            var link = RunProps.default
            link.link = hyperlink(.url(url: "https://example.org/a?b=1&c=2"), tooltip: "tip")
            var para = Paragraph.default
            para.runs = [
                Run.with("Bold ", bold),
                Run.with("red italic", red),
                Run(text: "", props: RunProps.default, kind: .break),
                Run.with("link", link),
            ]
            var body = TextBody.default
            body.paragraphs = [para]
            if !s.shapes.isEmpty { s.shapes[0].text = body }
            var t = Transition.default
            t.kind = "fade"
            t.option = "throughBlack"
            t.durationMs = 700
            t.advanceAfterMs = 3000
            s.transition = t
            p.slides[0] = s
        }

        // Slide 2: shapes, fills, lines, effects, custom geometry, group, connector.
        var s = IT.newSlide(&p, "Shapes")
        var a = IT.shape(&p, "Gradient Star", 100.0, 120.0, 150.0, 150.0)
        a.geom = .preset(name: "star5", adj: [20000.0])
        a.fill = .gradient(Gradient(
            stops: [
                GradientStop(pos: 0.0, color: ColorRef.scheme(.accent1)),
                GradientStop(pos: 1.0, color: ColorRef.scheme(.accent2).with(.lumMod(75000))),
            ],
            shape: .linear(angle: 45.0, scaled: false),
            rotateWithShape: true,
            tile: [0, 0, 0, 0]
        ))
        var aLine = Line.solid(ColorRef.rgb(Rgba.rgb(0, 0, 0)), 3.0)
        aLine.width = 3.0
        aLine.dash = .preset(name: "dash")
        a.line = aLine
        a.effects = Effects(
            outerShadow: Shadow(
                color: ColorRef.rgb(Rgba.black).with(.alpha(40000)), blur: 6.0, dist: 3.0, dir: 90.0, inner: false,
                sx: 1.0, sy: 1.0, kx: 0.0, ky: 0.0, align: "b", rotateWithShape: false
            ),
            glow: Glow(color: ColorRef.scheme(.accent6), radius: 8.0),
            softEdge: 2.0
        )
        var ax = Xfrm(100.0, 120.0, 150.0, 150.0)
        ax.rot = 30.0
        ax.flipH = true
        a.xfrm = ax
        var b = IT.shape(&p, "Pattern Box", 300.0, 120.0, 120.0, 80.0)
        b.geom = .preset(name: "roundRect", adj: [30000.0])
        b.fill = .pattern(PatternFill(preset: "dkDnDiag", fg: ColorRef.scheme(.accent3), bg: ColorRef.rgb(Rgba.white)))
        var bBody = TextBody.default
        bBody.body.anchor = .bottom
        bBody.body.insetL = 10.0
        bBody.body.wrap = false
        bBody.body.autofit = .shape
        var bPara = Paragraph.default
        bPara.props.align = .right
        bPara.props.lineSpacing = .pct(1.5)
        bPara.props.spaceBefore = .pts(6.0)
        bPara.props.bullet = .autoNum(scheme: "romanUcPeriod", startAt: 3)
        bPara.runs = [Run("numbered")]
        bPara.level = 2
        bBody.paragraphs = [bPara]
        b.text = bBody
        b.click = hyperlink(.nextSlide, highlightClick: true)
        var c = IT.shape(&p, "Freeform", 450.0, 120.0, 100.0, 100.0)
        c.geom = .custom(paths: [CustomPath(w: 100000.0, h: 100000.0, d: "M 0 0 L 100000 0 L 50000 100000 Z", fill: .norm, stroke: true)])
        c.fill = Fill.solid(ColorRef.scheme(.accent4))
        var child1 = IT.shape(&p, "Child 1", 0.0, 0.0, 50.0, 50.0)
        child1.geom = Geom.preset("ellipse")
        var child2 = IT.shape(&p, "Child 2", 60.0, 0.0, 50.0, 50.0)
        child2.geom = Geom.preset("rect")
        let (c1, c2) = (child1.id, child2.id)
        var g = IT.shape(&p, "Group", 600.0, 120.0, 220.0, 100.0)
        g.kind = .group(children: [child1, child2], child: Xfrm(0.0, 0.0, 110.0, 50.0))
        var cx = IT.shape(&p, "Connector", 600.0, 300.0, 200.0, 0.0)
        cx.kind = .connector(start: Pair(c1, 2), end: Pair(c2, 0))
        cx.geom = Geom.preset("straightConnector1")
        var cxLine = Line.solid(ColorRef.scheme(.tx1), 2.0)
        cxLine.tail = LineEnd(kind: "triangle", w: "med", len: "lg")
        cx.line = cxLine
        var tb = IT.shape(&p, "Text Box", 100.0, 400.0, 300.0, 40.0)
        tb.textBox = true
        tb.text = TextBody.fromText("A text box")
        tb.descr = "alt text"
        var bgs = IT.shape(&p, "Uses background", 450.0, 400.0, 60.0, 60.0)
        bgs.fill = .background
        s.shapes += [a, b, c, g, cx, tb, bgs]
        s.background = .fill(fill: Fill.solid(ColorRef.rgb(Rgba.rgb(250, 248, 240))))
        var morph = Transition.default
        morph.kind = "morph"
        morph.option = "words"
        morph.durationMs = 2000
        s.transition = morph
        let ids = s.shapes.map(\.id)
        func anim(_ shape: ShapeId, _ f: (inout Animation) -> Void) -> Animation {
            var x = Animation.default
            x.shape = shape
            f(&x)
            return x
        }
        s.animations = [
            anim(ids[1]) { $0.effect = "fly"; $0.option = "l"; $0.durationMs = 750 },
            anim(ids[2]) { $0.effect = "wipe"; $0.option = "t"; $0.start = .withPrevious; $0.delayMs = 250 },
            anim(ids[3]) { $0.class = .emphasis; $0.effect = "spin"; $0.start = .afterPrevious; $0.durationMs = 2000 },
            anim(ids[4]) { $0.class = .exit; $0.effect = "fadeOut"; $0.durationMs = 400 },
            anim(ids[2]) {
                $0.class = .path
                $0.effect = "lines"
                $0.option = "right"
                $0.path = "M 0 0 L 0.25 0 E"
                $0.durationMs = 2000
            },
            anim(ids[6]) { $0.effect = "zoom"; $0.option = "in"; $0.trigger = ids[3]; $0.durationMs = 500 },
        ]
        s.comments = [Comment(author: "Ada", initials: "AL", text: "Nice star", date: "2025-02-03T04:05:06.000", x: 120.0, y: 64.0)]
        p.slides.append(s)

        // Slide 3: pictures, media, ink.
        s = IT.newSlide(&p, "Pictures")
        var pic = IT.shape(&p, "Picture", 100.0, 120.0, 200.0, 150.0)
        pic.kind = .picture(fill: PictureFill(
            media: img,
            crop: [0.1, 0.05, 0.2, 0.0],
            mode: .stretch(fillRect: [0, 0, 0, 0]),
            alpha: 0.5,
            adjust: PictureAdjust(brightness: 0.2, contrast: -0.1, grayscale: true),
            upright: false,
            artistic: nil
        ))
        var tiled = IT.shape(&p, "Tiled", 350.0, 120.0, 200.0, 150.0)
        tiled.fill = .picture(PictureFill(media: img2, mode: .tile(tx: 0.0, ty: 0.0, sx: 0.5, sy: 0.5, flip: "none", align: "tl")))
        var vid = IT.shape(&p, "Video", 600.0, 120.0, 240.0, 135.0)
        vid.kind = .media(MediaClip(
            media: video, video: true, poster: img, crop: [0.1, 0.0, 0.2, 0.25], trimStartMs: 500, fadeInMs: 250, volume: 1.0
        ))
        var ink = IT.shape(&p, "Ink", 100.0, 350.0, 200.0, 100.0)
        ink.kind = .ink(strokes: [InkStroke(
            points: [Triple(100.0, 350.0, Float(0.5)), Triple(150.0, 400.0, Float(0.5)), Triple(300.0, 360.0, Float(0.5))],
            color: Rgba.rgb(0, 0, 255),
            width: 3.0,
            highlighter: false
        )])
        s.shapes += [pic, tiled, vid, ink]
        var vortex = Transition.default
        vortex.kind = "vortex"
        vortex.option = "r"
        vortex.durationMs = 3000
        s.transition = vortex
        s.hidden = true
        p.slides.append(s)

        // Slide 4: table with merges and a chart per type.
        s = IT.newSlide(&p, "Table")
        var t = Table(rows: 3, cols: 3, width: 450.0, rowHeight: 30.0)
        for r in 0 ..< 3 {
            for col in 0 ..< 3 {
                t.mutateCell(r, col) { $0.text = TextBody.fromText("r\(r)c\(col)") }
            }
        }
        _ = t.merge(1, 0, 2, 1)
        t.style = "light2-accent3"
        t.mutateCell(0, 2) { cell in
            cell.fill = Fill.solid(ColorRef.rgb(Rgba.rgb(255, 255, 0)))
            cell.margins = [5.0, 5.0, 2.0, 2.0]
            cell.anchor = .middle
            cell.borders[3] = Line.solid(ColorRef.rgb(Rgba.black), 2.0)
        }
        var ts = IT.shape(&p, "Table 1", 100.0, 120.0, 450.0, 90.0)
        ts.kind = .table(t)
        s.shapes.append(ts)
        var split = Transition.default
        split.kind = "split"
        split.option = "vertIn"
        split.durationMs = 1500
        split.advanceOnClick = false
        split.advanceAfterMs = 2000
        s.transition = split
        p.slides.append(s)

        let kinds: [ChartType] = [.column, .stackedBar, .percentColumn, .line, .lineMarkers, .area, .pie, .doughnut, .scatter, .radar, .bubble]
        s = IT.newSlide(&p, "Charts")
        for (i, k) in kinds.enumerated() {
            var ch = IT.shape(&p, "Chart \(i)", 20.0 + Double(i % 4) * 230.0, 100.0 + Double(i / 4) * 140.0, 220.0, 130.0)
            var chart = Chart.sample(k)
            chart.title = k.label
            ch.kind = .chart(chart)
            s.shapes.append(ch)
        }
        var combo = Chart.sample(.column)
        combo.kind = .combo
        combo.series[0].kind = .column
        combo.series[1].kind = .line
        combo.series[2].kind = .line
        var ch = IT.shape(&p, "Combo", 710.0, 380.0, 220.0, 130.0)
        ch.kind = .chart(combo)
        s.shapes.append(ch)
        p.slides.append(s)

        // Slide 6: bulleted content with a by-paragraph build, a slide link and an equation.
        let layout = layoutOfKind(p, .titleAndContent) ?? LayoutId.default
        s = newSlide(&p, layout) ?? Slide.default
        s.shapes[0].text = TextBody.fromText("Build")
        s.shapes[1].text = TextBody.fromText("One\nTwo\nThree")
        let body = s.shapes[1].id
        s.animations = [anim(body) { $0.effect = "fade"; $0.textBuild = .byParagraph; $0.durationMs = 500 }]
        let target = p.slides[1].id
        var link = IT.shape(&p, "Go to shapes", 600.0, 450.0, 200.0, 40.0)
        link.text = TextBody.fromText("Back to shapes")
        link.click = hyperlink(.slide(slide: target))
        var eq = IT.shape(&p, "Equation", 100.0, 450.0, 300.0, 40.0)
        var eqPara = Paragraph.default
        eqPara.runs = [Run(
            text: "x=1",
            props: RunProps.default,
            kind: .math(omml: #"<m:oMathPara xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><m:oMath><m:r><m:t>x=1</m:t></m:r></m:oMath></m:oMathPara>"#)
        )]
        var eqBody = TextBody.default
        eqBody.paragraphs = [eqPara]
        eq.text = eqBody
        s.shapes += [link, eq]
        var curtains = Transition.default
        curtains.kind = "curtains"
        curtains.durationMs = 2000
        s.transition = curtains
        p.slides.append(s)

        let slideIds = p.slides.map(\.id)
        p.sections = [Section(name: "Start", slides: Array(slideIds[..<2])), Section(name: "Rest", slides: Array(slideIds[2...]))]
        p.customShows = [CustomShow(name: "Short", slides: [slideIds[0], slideIds[3]])]
        p.firstSlideNumber = 0
        return p
    }

    // Rust: it/roundtrip.rs::rich_deck_writes_to_dir
    @Test func richDeckWritesToDir() throws {
        let p = Self.richDeck()
        let bytes = try PPTX.export(p)
        if let dir = IT.env("DECKCRAFT_PPTX_OUT") {
            try Data(bytes).write(to: URL(filePath: "\(dir)/rich.pptx"))
        }
        #expect(bytes.count > 1000)
    }

    // Rust: it/roundtrip.rs::deck_level_round_trip
    @Test func deckLevelRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        try #require(q.slides.count == p.slides.count)
        #expect(q.validate().isEmpty, "\(q.validate())")
        #expect(q.slideSize == p.slideSize)
        #expect(q.firstSlideNumber == 0)
        #expect(q.props.title == "Rich deck")
        #expect(q.props.author == "DeckCraft tests")
        #expect(q.props.created == "2025-01-02T03:04:05Z")
        #expect(q.sections.map(\.name) == ["Start", "Rest"])
        #expect(q.sections.map(\.slides.count) == [2, 4])
        try #require(q.customShows.count == 1)
        #expect(q.customShows[0].slides == [q.slides[0].id, q.slides[3].id])
        #expect(q.slides[2].hidden)
        // Themes and layouts.
        try #require(q.masters.count == 1)
        let (pm, qm) = (p.masters[0], q.masters[0])
        #expect(qm.theme.colors.colors == pm.theme.colors.colors)
        #expect(qm.theme.fonts.major.latin == pm.theme.fonts.major.latin)
        #expect(qm.layouts.count == pm.layouts.count)
        for (a, b) in zip(pm.layouts, qm.layouts) {
            #expect(a.name == b.name)
            #expect(a.kind == b.kind)
            #expect(a.shapes.count == b.shapes.count)
        }
        #expect(qm.titleStyle == pm.titleStyle)
        #expect(qm.bodyStyle == pm.bodyStyle)
        #expect(q.defaultTextStyle == p.defaultTextStyle)
        for (a, b) in zip(p.slides, q.slides) {
            #expect(p.layout(a.layout)?.layout.name == q.layout(b.layout)?.layout.name)
        }
    }

    // Rust: it/roundtrip.rs::text_and_formatting_round_trip
    @Test func textAndFormattingRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        #expect(q.slides[0].notesText == "Speaker notes line 1\nline 2")
        let (a, b) = (p.slides[0].shapes[0], q.slides[0].shapes[0])
        #expect(a.text == b.text)
        #expect(b.xfrm == nil, "placeholder without xfrm inherits")
        let sa = try rtByName(p.slides[1], "Pattern Box")
        let sb = try rtByName(q.slides[1], "Pattern Box")
        #expect(sa.text == sb.text)
        #expect(sa.click == sb.click)
        #expect(try rtByName(q.slides[1], "Text Box").textBox)
        #expect(try rtByName(q.slides[1], "Text Box").descr == "alt text")
        let la = try rtByName(p.slides[5], "Go to shapes")
        let lb = try rtByName(q.slides[5], "Go to shapes")
        #expect(lb.click.map(\.action) == Action.slide(slide: q.slides[1].id))
        #expect(la.click != nil)
        let eq = try rtByName(q.slides[5], "Equation")
        let run = try #require(eq.text?.paragraphs.first?.runs.first, "text")
        if case .math(let omml) = run.kind {
            #expect(omml.has("oMath"), "\(run)")
        } else {
            Issue.record("\(run)")
        }
        #expect(run.text == "x=1")
    }

    // Rust: it/roundtrip.rs::shapes_fills_lines_effects_round_trip
    @Test func shapesFillsLinesEffectsRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        for name in ["Gradient Star", "Pattern Box", "Freeform", "Uses background"] {
            let (a, b) = (try rtByName(p.slides[1], name), try rtByName(q.slides[1], name))
            #expect(a.geom == b.geom, "\(name)")
            #expect(a.fill == b.fill, "\(name)")
            #expect(a.line == b.line, "\(name)")
            #expect(a.effects == b.effects, "\(name)")
            #expect(a.xfrm == b.xfrm, "\(name)")
        }
        let g = try rtByName(q.slides[1], "Group")
        if case .group(let children, let child) = g.kind {
            #expect(children.count == 2 && child.w == 110.0)
        } else {
            Issue.record("not a group: \(g.kind)")
        }
        let c = try rtByName(q.slides[1], "Connector")
        let (c1, c2) = (try rtByName(q.slides[1], "Child 1").id, try rtByName(q.slides[1], "Child 2").id)
        if case .connector(let start, let end) = c.kind, let start, let end {
            #expect(start.a == c1 && start.b == 2 && end.a == c2 && end.b == 0, "\(c.kind)")
        } else {
            Issue.record("\(c.kind)")
        }
        #expect(c.line == (try rtByName(p.slides[1], "Connector")).line)
        // Ids are kept.
        #expect(try rtByName(q.slides[1], "Group").id == rtByName(p.slides[1], "Group").id)
    }

    // Rust: it/roundtrip.rs::pictures_media_and_ink_round_trip
    @Test func picturesMediaAndInkRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        let (a, b) = (try rtByName(p.slides[2], "Picture"), try rtByName(q.slides[2], "Picture"))
        guard case .picture(let fa) = a.kind, case .picture(let fb) = b.kind else {
            Issue.record("not pictures")
            return
        }
        #expect(fa.crop == fb.crop)
        #expect(fa.alpha == fb.alpha)
        #expect(fa.adjust == fb.adjust)
        #expect(p.media(fa.media).map(\.data) == q.media(fb.media).map(\.data))
        let t = try rtByName(q.slides[2], "Tiled")
        if case .picture(let pf) = t.fill, case .tile(_, _, let sx, _, _, _) = pf.mode {
            #expect(sx == 0.5)
        } else {
            Issue.record("\(String(describing: t.fill))")
        }
        let v = try rtByName(q.slides[2], "Video")
        guard case .media(let m) = v.kind else {
            Issue.record("not media: \(v.kind)")
            return
        }
        #expect(m.video)
        #expect(m.trimStartMs == 500 && m.fadeInMs == 250)
        #expect(q.media(m.media).map { $0.data.starts(with: [0, 0, 0, 0x18] + Array("ftyp".utf8)) } == true)
        #expect(m.poster != nil)
        // The crop of the video survives the round trip (#972).
        for (got, want) in zip(m.crop, [0.1, 0.0, 0.2, 0.25]) {
            #expect(abs(got - want) < 1e-4, "video crop \(m.crop)")
        }
        // Ink comes back as freeform lines in a group. A flat 0.5 stroke keeps the pen width.
        let ink = try rtByName(q.slides[2], "Ink")
        guard case .group(let children, _) = ink.kind else {
            Issue.record("ink is not a group: \(ink.kind)")
            return
        }
        try #require(children.count == 1)
        if case .custom = children[0].geom {} else { Issue.record("\(children[0].geom)") }
        let w = children[0].line?.width ?? 0.0
        #expect(abs(w - 3.0) < 0.05, "a flat 0.5 stroke keeps the pen width, got \(w)")
    }

    // Rust: it/roundtrip.rs::pressured_ink_exports_at_its_mean_width
    @Test func pressuredInkExportsAtItsMeanWidth() throws {
        var p = Presentation.default
        let n = p.allocId()
        let id = ShapeId(try #require(n, "id"))
        var ink = Shape.default
        ink.id = id
        ink.name = "Ink"
        ink.xfrm = Xfrm(0.0, 0.0, 960.0, 540.0)
        ink.kind = .ink(strokes: [InkStroke(
            points: [Triple(10.0, 10.0, Float(1.0)), Triple(40.0, 10.0, Float(0.5)), Triple(80.0, 10.0, Float(0.0))],
            color: Rgba.rgb(0, 0, 0),
            width: 10.0,
            highlighter: false
        )])
        p.slides[0].shapes.append(ink)
        let q = try IT.round(p)
        let back = try rtByName(q.slides[0], "Ink")
        guard case .group(let children, _) = back.kind, let first = children.first else {
            Issue.record("\(back.kind)")
            return
        }
        let w = first.line?.width ?? 0.0
        // Full, half, and the 8% floor: (10 + 5 + 0.8) / 3.
        #expect(abs(w - (10.0 + 5.0 + 0.8) / 3.0) < 0.05, "\(w)")
    }

    // Rust: it/roundtrip.rs::tables_round_trip
    @Test func tablesRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        guard case .table(let a) = try rtByName(p.slides[3], "Table 1").kind,
              case .table(let b) = try rtByName(q.slides[3], "Table 1").kind else {
            Issue.record("not tables")
            return
        }
        // A cell always has at least one paragraph in the file; compare without empty ones.
        func norm(_ t: Table) -> Table {
            var t = t
            for r in t.rows.indices {
                for c in t.rows[r].cells.indices {
                    t.rows[r].cells[c].text.paragraphs.removeAll { $0.isEmpty }
                }
            }
            return t
        }
        #expect(norm(a) == norm(b))
    }

    // Rust: it/roundtrip.rs::charts_round_trip
    @Test func chartsRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        for (sa, sb) in zip(p.slides[4].shapes, q.slides[4].shapes) {
            guard case .chart(let a) = sa.kind, case .chart(let b) = sb.kind else { continue }
            #expect(a.kind == b.kind, "\(sa.name)")
            #expect(a.title == b.title)
            #expect(a.series.count == b.series.count)
            for (x, y) in zip(a.series, b.series) {
                #expect(x.name == y.name)
                #expect(x.values == y.values, "\(sa.name)")
            }
            if a.kind != .scatter, a.kind != .bubble {
                #expect(a.categories == b.categories)
            }
            #expect(b.raw != nil)
        }
        // Second export reuses the kept chart XML unchanged.
        let r = try IT.round(q)
        for (sa, sb) in zip(q.slides[4].shapes, r.slides[4].shapes) {
            if case .chart(var a) = sa.kind, case .chart(var b) = sb.kind {
                a.raw = nil
                b.raw = nil
                #expect(a == b)
            }
        }
    }

    // Rust: it/roundtrip.rs::transitions_and_animations_round_trip
    @Test func transitionsAndAnimationsRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        for (a, b) in zip(p.slides, q.slides) {
            switch (a.transition, b.transition) {
            case (let x?, let y?):
                #expect(x.kind == y.kind && x.option == y.option && x.durationMs == y.durationMs, "\(x) vs \(y)")
                #expect(x.advanceOnClick == y.advanceOnClick && x.advanceAfterMs == y.advanceAfterMs, "\(x) vs \(y)")
            case (nil, nil):
                break
            case let other:
                Issue.record("\(other)")
            }
            #expect(a.animations.count == b.animations.count)
            for (x, y) in zip(a.animations, b.animations) {
                #expect(x.effect == y.effect && x.option == y.option && x.class == y.class && x.start == y.start, "\(x) vs \(y)")
                #expect(x.durationMs == y.durationMs && x.delayMs == y.delayMs && x.textBuild == y.textBuild, "\(x) vs \(y)")
                #expect(x.shape == y.shape)
                #expect(x.trigger == y.trigger)
                if x.class == .path {
                    #expect(x.path == y.path)
                }
            }
        }
    }

    // Rust: it/roundtrip.rs::comments_round_trip
    @Test func commentsRoundTrip() throws {
        let p = Self.richDeck()
        let q = try IT.round(p)
        let c = q.slides[1].comments
        try #require(c.count == 1)
        #expect(c[0].author == "Ada" && c[0].initials == "AL" && c[0].text == "Nice star")
        #expect(c[0].x == 120.0 && c[0].y == 64.0)
    }

    // Rust: it/roundtrip.rs::every_transition_kind_survives
    @Test func everyTransitionKindSurvives() throws {
        var p = newPresentation(nil)
        let base = p.slides[0]
        p.slides.removeAll()
        for info in transitions {
            var s = base
            let n = p.allocId()
        s.id = SlideId(try #require(n, "ids"))
            var t = Transition.default
            t.kind = info.id
            t.durationMs = 1200
            s.transition = t
            p.slides.append(s)
        }
        let q = try IT.round(p)
        for (a, b) in zip(p.slides, q.slides) {
            let k = a.transition?.kind ?? ""
            if k == "none" { continue }
            #expect(b.transition?.kind == k)
            #expect(b.transition?.durationMs == 1200, "\(k)")
        }
    }

    // Rust: it/roundtrip.rs::every_animation_effect_survives
    @Test func everyAnimationEffectSurvives() throws {
        var p = newPresentation(nil)
        var s = p.slides[0]
        var sh = IT.shape(&p, "Target", 100.0, 100.0, 100.0, 100.0)
        sh.text = TextBody.fromText("hi")
        let id = sh.id
        s.shapes.append(sh)
        for info in animations {
            var a = Animation.default
            a.shape = id
            a.class = info.animClass
            a.effect = info.id
            a.option = info.options.first ?? ""
            a.durationMs = Swift.max(info.defaultDurationMs, 1)
            s.animations.append(a)
        }
        p.slides[0] = s
        let q = try IT.round(p)
        let (a, b) = (p.slides[0].animations, q.slides[0].animations)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            // Effects sharing a preset number come back as the first effect with that number.
            let samePreset = animationInfo(x.effect, x.class)?.presetId == animationInfo(y.effect, y.class)?.presetId
            #expect(x.effect == y.effect || samePreset, "\(x.effect) vs \(y.effect)")
            #expect(x.class == y.class)
        }
    }

    // Rust: it/roundtrip.rs::animation_rewind_survives
    @Test func animationRewindSurvives() throws {
        var p = newPresentation(nil)
        var s = p.slides[0]
        let sh = IT.shape(&p, "Target", 100.0, 100.0, 100.0, 100.0)
        let id = sh.id
        s.shapes.append(sh)
        var first = Animation.default
        first.shape = id
        first.rewind = true
        s.animations.append(first)
        var second = Animation.default
        second.shape = id
        second.effect = "fly"
        second.option = "l"
        second.start = .withPrevious
        s.animations.append(second)
        p.slides[0] = s
        let q = try IT.round(p)
        let b = q.slides[0].animations
        try #require(b.count == 2)
        #expect(b[0].rewind)
        #expect(!b[1].rewind)
    }

    // Rust: it/roundtrip.rs::bisect_variants
    /// Writes bisection variants of the rich deck to `DECKCRAFT_PPTX_BISECT` (manual checks).
    @Test func bisectVariants() throws {
        guard let dir = IT.env("DECKCRAFT_PPTX_BISECT") else { return }
        let p = Self.richDeck()
        for i in p.slides.indices {
            var q = p
            q.slides = [p.slides[i]]
            q.sections.removeAll()
            q.customShows.removeAll()
            try Data(PPTX.export(q)).write(to: URL(filePath: "\(dir)/bis-slide\(i).pptx"))
        }
        var q = p
        q.sections.removeAll()
        q.customShows.removeAll()
        q.firstSlideNumber = 1
        for i in q.slides.indices { q.slides[i].comments.removeAll() }
        try Data(PPTX.export(q)).write(to: URL(filePath: "\(dir)/bis-nodeck.pptx"))
    }

    // Rust: it/roundtrip.rs::bisect_slide_variants
    /// Finer bisection of one slide (`DECKCRAFT_PPTX_BISECT_SLIDE=<index>`): one variant per removed
    /// shape, plus no animations / no transition.
    @Test func bisectSlideVariants() throws {
        guard let dir = IT.env("DECKCRAFT_PPTX_BISECT"), let idx = IT.env("DECKCRAFT_PPTX_BISECT_SLIDE") else { return }
        let p = Self.richDeck()
        let i = try #require(Int(idx), "index")
        let base = try #require(p.slides.indices.contains(i) ? p.slides[i] : nil, "index")
        func one(_ s: Slide) throws -> [UInt8] {
            var q = p
            q.slides = [s]
            q.sections.removeAll()
            q.customShows.removeAll()
            return try PPTX.export(q)
        }
        var s = base
        s.animations.removeAll()
        try Data(one(s)).write(to: URL(filePath: "\(dir)/v-noanim.pptx"))
        s = base
        s.transition = nil
        try Data(one(s)).write(to: URL(filePath: "\(dir)/v-notrans.pptx"))
        for k in base.shapes.indices {
            var s = base
            s.animations.removeAll()
            s.transition = nil
            let keep = s.shapes[k]
            s.shapes.removeAll { $0.id != keep.id }
            try Data(one(s)).write(to: URL(filePath: "\(dir)/v-only\(k).pptx"))
        }
    }

    // Rust: it/roundtrip.rs::rtl_paragraphs_script_fonts_and_just_low_round_trip
    @Test func rtlParagraphsScriptFontsAndJustLowRoundTrip() throws {
        var p = Self.richDeck()
        p.masters[0].theme.fonts.minor.cs = "Noto Naskh Arabic"
        p.masters[0].theme.fonts.minor.scripts = [
            ScriptFont(script: "Arab", typeface: "Noto Naskh Arabic"),
            ScriptFont(script: "Hebr", typeface: "Noto Sans Hebrew"),
        ]
        let k = try #require(p.slides[0].shapes.firstIndex { $0.text != nil }, "a text shape")
        var body = try #require(p.slides[0].shapes[k].text, "text")
        var para = Paragraph.default
        para.runs = [Run("سنة 2024 (Retrait) فقط")]
        body.paragraphs = [para]
        body.paragraphs[0].props.rtl = true
        body.paragraphs[0].props.align = .justLow
        p.slides[0].shapes[k].text = body
        let name = p.slides[0].shapes[k].name
        let q = try IT.round(p)
        #expect(q.masters[0].theme.fonts.minor.scripts == p.masters[0].theme.fonts.minor.scripts)
        #expect(q.masters[0].theme.fonts.minor.script("arab") == "Noto Naskh Arabic")
        let back = try #require(try rtByName(q.slides[0], name).text?.paragraphs.first, "text")
        #expect(back.props.rtl == true)
        #expect(back.props.align == .justLow)
        #expect(back.runs.first.map { bytesEqual($0.text, "سنة 2024 (Retrait) فقط") } == true)
    }

    // Rust: it/roundtrip.rs::date_fields_keep_their_type_and_saved_text
    @Test func dateFieldsKeepTheirTypeAndSavedText() throws {
        // An automatic date is a field (its saved text is what readers without a clock show); a fixed
        // date is plain text.
        var p = Presentation.default
        var auto = IT.shape(&p, "Auto date", 10.0, 10.0, 200.0, 40.0)
        var body = TextBody.fromText("")
        body.paragraphs[0].runs = [Run(text: "March 3, 2025", props: RunProps.default, kind: .field(field: "datetime4"))]
        auto.text = body
        var fixed = IT.shape(&p, "Fixed date", 10.0, 60.0, 200.0, 40.0)
        fixed.text = TextBody.fromText("Launch day")
        p.slides[0].shapes = [auto, fixed]
        let q = try IT.round(p)
        for name in ["Auto date", "Fixed date"] {
            #expect(try rtByName(q.slides[0], name).text == rtByName(p.slides[0], name).text, "\(name)")
        }
    }

    // Rust: it/roundtrip.rs::colour_map_overrides_round_trip
    @Test func colourMapOverridesRoundTrip() throws {
        var p = newPresentation(nil)
        let dark = [("bg1", "dk1"), ("tx1", "lt1"), ("bg2", "dk2"), ("tx2", "lt2")].map { Pair($0.0, $0.1) }
        let layout = p.slides[0].layout
        let li = try #require(p.masters[0].layouts.firstIndex { $0.id == layout }, "layout")
        p.masters[0].layouts[li].colorMap = dark
        p.slides[0].colorMap = dark
        let q = try IT.round(p)
        func get(_ m: [Pair<String, String>]?, _ k: String) -> String? { m?.first { bytesEqual($0.a, k) }?.b }
        let ql = try #require(q.masters[0].layouts.first { $0.colorMap != nil }, "the layout keeps its override")
        #expect(get(ql.colorMap, "bg1") == "dk1")
        #expect(get(q.slides[0].colorMap, "tx1") == "lt1")
        // Layouts and slides without one keep following the master.
        #expect(q.masters[0].layouts.filter { $0.colorMap == nil }.count >= 1)
    }

    // Rust: it/roundtrip.rs::a_picture_duotone_round_trips
    @Test func aPictureDuotoneRoundTrips() throws {
        var p = newPresentation(nil)
        let added = p.addMedia("image1.png", "image/png", IT.png(4, 4, (128, 128, 128)))
        let img = try #require(added, "media")
        var pic = IT.shape(&p, "Duotone", 10.0, 10.0, 100.0, 100.0)
        var pf = PictureFill(media: img)
        pf.adjust.duotone = Pair(ColorRef.scheme(.accent1).with(.shade(30000)), ColorRef.rgb(Rgba.rgb(250, 240, 200)))
        pic.kind = .picture(fill: pf)
        p.slides[0].shapes.append(pic)
        let q = try IT.round(p)
        let sh = try rtByName(q.slides[0], "Duotone")
        guard case .picture(let fill) = sh.kind else {
            Issue.record("picture")
            return
        }
        let duo = try #require(fill.adjust.duotone, "duotone kept")
        #expect(duo.a.base == .scheme(slot: .accent1))
        #expect(duo.b.base == .rgb(rgb: Rgba.rgb(250, 240, 200)))
    }

    // Rust: it/roundtrip.rs::line_break_options_round_trip
    @Test func lineBreakOptionsRoundTrip() throws {
        var p = newPresentation(nil)
        var t = TextBody.fromText("x")
        t.paragraphs[0].props.latinLineBreak = true
        t.paragraphs[0].props.hangingPunct = false
        p.slides[0].shapes[0].text = t
        let q = try IT.round(p)
        let props = try #require(q.slides[0].shapes[0].text?.paragraphs.first, "text").props
        #expect(props.latinLineBreak == true)
        #expect(props.hangingPunct == false)
    }

    // Rust: it/roundtrip.rs::a_table_fill_round_trips
    @Test func aTableFillRoundTrips() throws {
        var p = newPresentation(nil)
        var t = Table(rows: 2, cols: 2, width: 200.0, rowHeight: 40.0)
        t.background = Fill.solid(ColorRef.rgb(Rgba.rgb(0, 112, 192)))
        var sh = IT.shape(&p, "Filled table", 10.0, 10.0, 200.0, 80.0)
        sh.kind = .table(t)
        p.slides[0].shapes.append(sh)
        let q = try IT.round(p)
        guard case .table(let back) = try rtByName(q.slides[0], "Filled table").kind else {
            Issue.record("table")
            return
        }
        #expect(back.background == .solid(color: ColorRef.rgb(Rgba.rgb(0, 112, 192))))
    }

    // Rust: it/roundtrip.rs::wordart_warps_and_their_adjusts_round_trip
    @Test func wordartWarpsAndTheirAdjustsRoundTrip() throws {
        var p = Presentation.default
        let cases: [(String, String, [Double])] = [
            ("Arch pour", "textArchUpPour", [13_500_000.0, 30_000.0]),
            ("Wave", "textWave1", [18_000.0, -5_000.0]),
            ("Inflate", "textInflate", [30_000.0]),
            ("Arch", "textArchUp", []),
            ("Ring", "textRingInside", [75_000.0]),
        ]
        var shapes: [Shape] = []
        for (i, (name, warp, adj)) in cases.enumerated() {
            var s = IT.shape(&p, name, 10.0, 10.0 + 50.0 * Double(i), 300.0, 40.0)
            var body = TextBody.fromText("WordArt")
            body.body.warp = warp
            body.body.warpAdj = adj
            s.text = body
            shapes.append(s)
        }
        p.slides[0].shapes = shapes
        let q = try IT.round(p)
        for (name, warp, adj) in cases {
            let b = try #require(try rtByName(q.slides[0], name).text, "text").body
            #expect(b.warp == warp, "\(name)")
            #expect(b.warpAdj == adj, "\(name)")
        }
        // The single-adjust preset is written with the guide name `adj`, two-adjust ones with
        // `adj1`/`adj2`, and a preset with no adjusts given gets an empty list.
        let bytes = try PPTX.export(p)
        let xml = String(decoding: try #require(IT.part(bytes, "ppt/slides/slide1.xml"), "slide"), as: UTF8.self)
        #expect(xml.has(#"<a:prstTxWarp prst="textInflate"><a:avLst><a:gd name="adj" fmla="val 30000"/></a:avLst></a:prstTxWarp>"#), "\(xml)")
        #expect(xml.has(#"<a:gd name="adj1" fmla="val 13500000"/><a:gd name="adj2" fmla="val 30000"/>"#))
        #expect(xml.has(#"<a:prstTxWarp prst="textArchUp"><a:avLst/></a:prstTxWarp>"#))
        // A file that gives only `adj2` keeps the preset's default for `adj1`; hostile values are
        // read as numbers or dropped.
        let edited = xml
            .replace(#"<a:gd name="adj1" fmla="val 13500000"/>"#, "")
            .replace(#"<a:gd name="adj" fmla="val 30000"/>"#, #"<a:gd name="adj" fmla="val NaN"/>"#)
        let back = try PPTX.import(rtWithSlide1(bytes, edited))
        let pour = try #require(try rtByName(back.slides[0], "Arch pour").text, "text").body
        #expect(pour.warpAdj == [10_800_000.0, 30_000.0])
        let inflate = try #require(try rtByName(back.slides[0], "Inflate").text, "text").body
        #expect(inflate.warp == "textInflate")
        #expect(inflate.warpAdj.isEmpty)
    }

    // Rust: it/roundtrip.rs::transition_xml_matches_powerpoints_elements
    @Test func transitionXmlMatchesPowerpointsElements() throws {
        // The elements, attributes and namespaces PowerPoint itself writes for these effect options
        // (observed on files it saved), inside `mc:AlternateContent` with a `p:fade` fallback for
        // the 2010+ effects.
        let cases: [(String, String, [String], String)] = [
            ("wipe", "ru", [#"<p:strips dir="ru"/>"#], "p14"),
            ("wipe", "u", [#"<p:wipe dir="u"/>"#], "p14"),
            ("zoom", "in", [#"<p14:warp dir="in"/>"#], "p14"),
            ("zoom", "rotate", ["<p:newsflash/>"], "p14"),
            ("shape", "out", [#"<p:zoom dir="out"/>"#], "p14"),
            ("glitter", "hexD", [#"<p14:glitter dir="d" pattern="hexagon"/>"#], "p14"),
            ("shred", "particlesOut", [#"<p14:shred pattern="rectangle" dir="out"/>"#], "p14"),
            ("wind", "l", [#"<p15:prstTrans prst="wind" invX="1"/>"#], "p15"),
            ("wind", "r", [#"<p15:prstTrans prst="wind"/>"#], "p15"),
            ("fallOver", "r", [#"<p15:prstTrans prst="fallOver" invX="1"/>"#], "p15"),
            ("pageCurlDouble", "singleR", [#"<p15:prstTrans prst="pageCurlSingle" invX="1"/>"#], "p15"),
            ("orbit", "u", [#"<p14:prism dir="u" isContent="1" isInverted="1"/>"#], "p14"),
            ("vortex", "r", [#"<p14:vortex dir="r"/>"#], "p14"),
            ("morph", "words", [#"<p159:morph option="byWord"/>"#], "p159"),
        ]
        let list = cases.map { ($0.0, $0.1, UInt32(2000), UInt32?(1000)) }
        let (p, xml) = try rtTransitionDeck(list)
        for ((kind, option, wants, req), x) in zip(cases, xml) {
            for w in wants {
                #expect(x.has(w), "\(kind)/\(option): \(w) in \(x)")
            }
            #expect(x.has(#"Requires="\#(req)""#), "\(kind)/\(option)")
            #expect(x.has(#"p14:dur="2000""#) && x.has(#"advTm="1000""#) && x.has(#"advClick="0""#), "\(kind)/\(option)")
            #expect(x.has("<mc:Fallback>"), "\(kind)/\(option)")
        }
        // Back in, everything is as it was.
        let q = try PPTX.import(PPTX.export(p))
        for ((kind, option, _, _), s) in zip(cases, q.slides) {
            let t = try #require(s.transition, "transition")
            #expect(t.kind == kind && t.option == option, "\(kind)/\(option): \(t)")
            #expect(t.durationMs == 2000 && t.advanceAfterMs == 1000 && !t.advanceOnClick, "\(kind)/\(option): \(t)")
        }
    }

    // Rust: it/roundtrip.rs::transition_defaults_read_like_powerpoint
    @Test func transitionDefaultsReadLikePowerpoint() throws {
        // PowerPoint leaves out an option when it is the element's default; these are its defaults.
        let cases: [(String, String, String)] = [
            ("<p:push/>", "push", "l"),
            ("<p:wipe/>", "wipe", "l"),
            ("<p:strips/>", "wipe", "lu"),
            ("<p:randomBar/>", "randomBar", "horz"),
            ("<p:checker/>", "checker", "horz"),
            ("<p:blinds/>", "blinds", "horz"),
            ("<p:comb/>", "comb", "horz"),
            ("<p:zoom/>", "shape", "out"),
            (#"<p:zoom dir="in"/>"#, "shape", "in"),
            ("<p:split/>", "split", "horzOut"),
            ("<p14:doors/>", "doors", "horz"),
            ("<p14:window/>", "window", "horz"),
            ("<p14:pan/>", "pan", "l"),
            ("<p14:warp/>", "zoom", "out"),
            ("<p14:glitter/>", "glitter", "l"),
            ("<p14:shred/>", "shred", "stripsIn"),
            ("<p14:reveal/>", "reveal", "smoothlyLeft"),
            ("<p14:prism/>", "cube", "l"),
            (#"<p15:prstTrans prst="airplane"/>"#, "airplane", "r"),
            (#"<p15:prstTrans prst="peelOff"/>"#, "peelOff", "l"),
            (#"<p15:prstTrans prst="pageCurlSingle"/>"#, "pageCurlDouble", "singleL"),
        ]
        let (_, xml) = try rtTransitionDeck([("fade", "smoothly", 2000, nil)])
        let x = try #require(xml.first, "no slide")
        let start = try #require(x.byteFind("<mc:AlternateContent"), "transition")
        let end = try #require(x.byteFind("</mc:AlternateContent>"), "transition end") + "</mc:AlternateContent>".utf8.count
        let p14 = #"xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main""#
        let p15 = #"xmlns:p15="http://schemas.microsoft.com/office/powerpoint/2012/main""#
        for (el, kind, option) in cases {
            let tr = #"<p:transition \#(p14) \#(p15) spd="slow" p14:dur="2000">\#(el)</p:transition>"#
            let edited = x.bytes(0, start) + tr + x.bytes(end)
            var p = newPresentation(nil)
            p.slides = [p.slides[0]]
            let bytes = try rtWithSlide1(PPTX.export(p), edited)
            let q = try PPTX.import(bytes)
            let t = try #require(q.slides.first?.transition, "transition")
            #expect(t.kind == kind && t.option == option && t.durationMs == 2000, "\(el): \(t)")
        }
    }

    // Rust: it/roundtrip.rs::linked_pictures_are_written_with_r_link
    @Test func linkedPicturesAreWrittenWithRLink() throws {
        // A picture whose bytes live outside the package must be referenced with `r:link`; `r:embed`
        // may only name a part inside the package (PowerPoint won't load the linked image otherwise).
        var p = newPresentation(nil)
        let media = MediaId(5000)
        p.media.append(MediaItem(id: media, name: "linked.png", contentType: "image/png", data: [], link: "file:///tmp/linked.png"))
        var pic = IT.shape(&p, "Linked", 100.0, 100.0, 200.0, 150.0)
        pic.kind = .picture(fill: PictureFill(media: media))
        p.slides[0].shapes.append(pic)

        let bytes = try PPTX.export(p)
        let xml = IT.text(bytes, "ppt/slides/slide1.xml")
        #expect(xml.has(#"r:link="rId"#), "\(xml)")
        #expect(!xml.has(#"r:embed="rId"#), "\(xml)")
        let rels = IT.text(bytes, "ppt/slides/_rels/slide1.xml.rels")
        #expect(rels.has(#"Target="file:///tmp/linked.png" TargetMode="External""#), "\(rels)")
    }

    // Rust: it/roundtrip.rs::templates_and_slide_shows_declare_their_own_main_content_type
    /// #210: `.potx` and `.ppsx` were written with the `.pptx` main content type.
    @Test func templatesAndSlideShowsDeclareTheirOwnMainContentType() throws {
        let p = Self.richDeck()
        for (ext, kind) in [("pptx", "presentation"), ("potx", "template"), ("ppsx", "slideshow")] {
            let bytes = try PPTX.exportAs(p, ext)
            let ct = String(decoding: try #require(IT.part(bytes, "[Content_Types].xml"), "content types"), as: UTF8.self)
            #expect(ct.has("presentationml.\(kind).main+xml"), "\(ext): \(ct)")
            #expect(try PPTX.import(bytes).slides.count == p.slides.count, "\(ext) reads back")
        }
    }
}

// MARK: roundtrip.rs from `single_guide_names_follow_the_preset` on.
//
// The engine (`deckcraft_engine::Session`) is Wave 4. Where its commands only build a model, the model is
// built here directly, following the command's code in deckcraft crates/engine/src/cmd: `file.new` is
// `newPresentation(nil)`, `slide.new` is `newSlide` after the current slide, `insert.chart` is
// `Chart.sample(kind)` at 15 % / 70 % of the slide, `chart.options` and `chart.data` set fields, and
// `transition.set` / `transition.sound` / `format.color` / `format.textTransparency` set the transition
// or run. Assertions about what only a command does (its result, refusals, undo, dedupe) are compiled
// out under `#if DCENGINE`.

/// Replace `from` with `to` in every slide part of an exported deck (Rust `patch_slides`).
private func tailPatchSlides(_ bytes: [UInt8], _ from: String, _ to: String) throws -> [UInt8] {
    try IT.zip(IT.entries(bytes).map { e in
        guard e.name.hasPrefix("ppt/slides/slide"), e.name.hasSuffix(".xml") else { return e }
        return (e.name, Array(String(decoding: e.data, as: UTF8.self).replace(from, to).utf8))
    })
}

private struct TailRun: Equatable, CustomStringConvertible {
    var kind: RunKind
    var text: String
    var description: String { "(\(kind), \(text.debugDescription))" }
}

/// The runs of the first paragraph holding `needle` (Rust `runs_of`).
private func tailRunsOf(_ p: Presentation, _ needle: String) -> [TailRun]? {
    for s in p.slides {
        for sh in s.shapes {
            guard let t = sh.text else { continue }
            for para in t.paragraphs where para.runs.contains(where: { $0.text.has(needle) }) {
                return para.runs.map { TailRun(kind: $0.kind, text: $0.text) }
            }
        }
    }
    return nil
}

/// Rewrite a package's `.xml` and `.rels` parts with `edit`, then add `extra` parts (Rust `repack`).
private func tailRepack(_ pkg: [UInt8], _ edit: (String, String) -> String, _ extra: [(String, [UInt8])]) throws -> [UInt8] {
    var files = try IT.entries(pkg).map { e -> (name: String, data: [UInt8]) in
        guard e.name.hasSuffix(".xml") || e.name.hasSuffix(".rels") else { return e }
        return (e.name, Array(edit(e.name, String(decoding: e.data, as: UTF8.self)).utf8))
    }
    for (n, d) in extra { files.append((n, d)) }
    return try IT.zip(files)
}

/// The first chart in the deck.
private func tailChart(_ d: Presentation) -> Chart? {
    for s in d.slides {
        for sh in s.shapes {
            if case .chart(let c) = sh.kind { return c }
        }
    }
    return nil
}

/// `Session::with_new()` + `slide.new {"layout": "blank"}` + `insert.chart {"type": kind}`, built without
/// the engine: a new deck, a blank slide after the title slide, and `Chart.sample(kind)` at 15 % / 70 % of
/// the slide; `configure` stands in for the `chart.options` / `chart.data` that follow.
private func tailChartDeck(_ kind: ChartType, _ configure: (inout Chart) -> Void) -> Presentation {
    var p = newPresentation(nil)
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    var slide = newSlide(&p, layout) ?? Slide.default
    var c = Chart.sample(kind)
    configure(&c)
    var sh = Shape.default
    sh.id = ShapeId(p.allocId() ?? 0)
    sh.name = "Chart 1"
    let size = p.slideSize
    sh.xfrm = Xfrm(size.width * 0.15, size.height * 0.15, size.width * 0.7, size.height * 0.7)
    sh.kind = .chart(c)
    slide.shapes.append(sh)
    p.slides.append(slide)
    return p
}

/// `transition.set {"kind": kind}` on slide `i`, built without the engine (the gallery's first option
/// and default duration).
private func tailSetTransition(_ p: inout Presentation, _ i: Int, _ kind: String) {
    guard let info = transitions.first(where: { eqIgnoreASCIICase($0.id, kind) }), p.slides.indices.contains(i) else { return }
    var t = p.slides[i].transition ?? Transition.default
    t.kind = info.id
    t.option = info.options.first ?? ""
    t.durationMs = info.defaultDurationMs
    t.raw = nil
    p.slides[i].transition = t
}

private let tailWaterfallCX = #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cx:chartSpace xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex"><cx:chartData><cx:externalData r:id="rId1" cx:autoUpdate="0"/><cx:data id="0"><cx:strDim type="cat"><cx:f>Sheet1!$A$2:$A$5</cx:f><cx:lvl ptCount="4"><cx:pt idx="0">Start</cx:pt><cx:pt idx="1">Sales</cx:pt><cx:pt idx="2">Costs</cx:pt><cx:pt idx="3">End</cx:pt></cx:lvl></cx:strDim><cx:numDim type="val"><cx:f>Sheet1!$B$2:$B$5</cx:f><cx:lvl ptCount="4" formatCode="General"><cx:pt idx="0">100</cx:pt><cx:pt idx="1">40</cx:pt><cx:pt idx="2">-25</cx:pt><cx:pt idx="3">115</cx:pt></cx:lvl></cx:numDim></cx:data></cx:chartData><cx:chart><cx:title pos="t" align="ctr" overlay="0"><cx:tx><cx:txData><cx:v>Cash flow</cx:v></cx:txData></cx:tx></cx:title><cx:plotArea><cx:plotAreaRegion><cx:series layoutId="waterfall" uniqueId="{1}"><cx:tx><cx:txData><cx:f>Sheet1!$B$1</cx:f><cx:v>Amount</cx:v></cx:txData></cx:tx><cx:dataLabels pos="outEnd"><cx:visibility seriesName="0" categoryName="0" value="1"/></cx:dataLabels><cx:dataId val="0"/><cx:layoutPr><cx:subtotals><cx:idx val="0"/><cx:idx val="3"/></cx:subtotals></cx:layoutPr></cx:series></cx:plotAreaRegion><cx:axis id="0"><cx:catScaling gapWidth="0.5"/><cx:tickLabels/></cx:axis><cx:axis id="1"><cx:valScaling/><cx:majorGridlines/><cx:tickLabels/></cx:axis></cx:plotArea><cx:legend pos="b" align="ctr" overlay="0"/></cx:chart></cx:chartSpace>
"""#

/// A waterfall frame as PowerPoint writes it: the chart in a `cx1` choice, a text box fallback.
private let tailWaterfallFrame = #"<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" Requires="cx1"><p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="90" name="Waterfall 1"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="914400" y="914400"/><a:ext cx="6096000" cy="4064000"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex"><cx:chart xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex" r:id="rIdCx"/></a:graphicData></a:graphic></p:graphicFrame></mc:Choice><mc:Fallback><p:sp><p:nvSpPr><p:cNvPr id="90" name="Waterfall 1"/><p:cNvSpPr><a:spLocks noTextEdit="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="6096000" cy="4064000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>This chart isn't available in your version of PowerPoint.</a:t></a:r></a:p></p:txBody></p:sp></mc:Fallback></mc:AlternateContent>"#

extension IntegrationRoundtripTests {
    /// #214: a lone guide was always written `adj`, but these presets name it `adj1`, and PowerPoint
    /// won't open the file otherwise. (Names as PowerPoint writes them.)
    // Rust: it/roundtrip.rs::single_guide_names_follow_the_preset
    @Test func singleGuideNamesFollowThePreset() throws {
        var p = newPresentation(nil)
        var s = IT.newSlide(&p, "Guides")
        let cases = [
            ("bentConnector3", "adj1"), ("curvedConnector3", "adj1"), ("frame", "adj1"), ("mathPlus", "adj1"),
            ("mathMinus", "adj1"), ("mathMultiply", "adj1"), ("roundRect", "adj"), ("chevron", "adj"),
        ]
        for (prst, _) in cases {
            var sh = IT.shape(&p, prst, 0, 0, 100, 50)
            sh.geom = .preset(name: prst, adj: [20000.0])
            s.shapes.append(sh)
        }
        p.slides.append(s)
        let bytes = try PPTX.export(p)
        let xml = try #require(IT.part(bytes, "ppt/slides/slide2.xml").map { String(decoding: $0, as: UTF8.self) }, "slide")
        for (prst, gd) in cases {
            #expect(xml.has(#"<a:prstGeom prst="\#(prst)"><a:avLst><a:gd name="\#(gd)" fmla="val 20000"/>"#), "\(prst) → \(gd): \(xml)")
        }
    }

    /// #147: PowerPoint's Float Down is preset 47 (Float Up is 42); it imported as a plain fade.
    // Rust: it/roundtrip.rs::float_down_is_preset_47_both_ways
    @Test func floatDownIsPreset47BothWays() throws {
        var p = newPresentation(nil)
        var s = IT.newSlide(&p, "Float")
        let sh = IT.shape(&p, "Building", 0, 0, 100, 100)
        let id = sh.id
        s.shapes.append(sh)
        func anim(_ cls: AnimClass, _ effect: String, _ option: String) -> Animation {
            var a = Animation.default
            a.shape = id
            a.class = cls
            a.effect = effect
            a.option = option
            return a
        }
        s.animations = [anim(.entrance, "float", "d"), anim(.exit, "floatOut", "d"), anim(.exit, "floatOut", "u")]
        p.slides.append(s)
        let bytes = try PPTX.export(p)
        let xml = IT.text(bytes, "ppt/slides/slide2.xml")
        #expect(xml.has(#"presetID="47" presetClass="entr" presetSubtype="0""#), "\(xml)")
        #expect(xml.has(#"presetID="47" presetClass="exit" presetSubtype="0""#), "\(xml)")
        #expect(xml.has(#"presetID="42" presetClass="exit" presetSubtype="0""#), "\(xml)")
        let q = try PPTX.import(bytes)
        let got = try #require(q.slides.at(1)).animations.map { "\($0.effect)/\($0.option)" }
        #expect(got == ["float/d", "floatOut/d", "floatOut/u"])
    }

    // Rust: it/roundtrip.rs::embedded_fonts_round_trip
    @Test func embeddedFontsRoundTrip() throws {
        var p = Presentation.default
        let regularBytes = Array("REGULAR-FONT-BYTES-0123456789".utf8)
        let boldBytes = Array("BOLD-FONT-BYTES-0123456789abcd".utf8)
        let regularAdded = p.addMedia("font1.fntdata", "application/x-fontdata", regularBytes)
        let regular = try #require(regularAdded, "media")
        let boldAdded = p.addMedia("font2.fntdata", "application/x-fontdata", boldBytes)
        let bold = try #require(boldAdded, "media")
        p.embeddedFonts.append(EmbeddedFont(
            typeface: "Deck Test Face", panose: "020B0604020202020204", pitchFamily: 34, charset: 0, regular: regular,
            bold: bold, italic: regular, boldItalic: nil
        ))
        // The same typeface again is one entry: PowerPoint requires each typeface once.
        p.embeddedFonts.append(EmbeddedFont(typeface: "Deck Test Face", regular: bold))
        let bytes = try PPTX.export(p)
        let xml = IT.text(bytes, "ppt/presentation.xml")
        #expect(xml.has("embedTrueTypeFonts=\"1\""))
        let notes = try #require(xml.byteFind("<p:notesSz"), "notesSz")
        let list = try #require(xml.byteFind("<p:embeddedFontLst>"), "list")
        let dts = try #require(xml.byteFind("<p:defaultTextStyle"), "style")
        #expect(notes < list && list < dts)
        #expect(xml.has(#"<p:font typeface="Deck Test Face" panose="020B0604020202020204" pitchFamily="34" charset="0"/>"#))
        #expect(xml.count(of: "<p:embeddedFont>") == 1)
        let rels = IT.text(bytes, "ppt/_rels/presentation.xml.rels")
        #expect(rels.count(of: "relationships/font") == 2, "regular and italic share one part")
        let q = try PPTX.import(bytes)
        #expect(q.embeddedFonts.count == 1)
        let f = try #require(q.embeddedFonts.first)
        #expect(f.typeface == "Deck Test Face")
        #expect(f.panose == "020B0604020202020204")
        #expect(f.pitchFamily == 34)
        #expect(f.charset == 0)
        let r = try #require(f.regular, "regular")
        let b = try #require(f.bold, "bold")
        #expect(q.media(r)?.data == regularBytes)
        #expect(q.media(b)?.data == boldBytes)
        #expect(f.italic == f.regular)
        #expect(f.boldItalic == nil)
    }

    /// A package whose font list this writer did not produce: bold only, relationship id not `rIdN`.
    // Rust: it/roundtrip.rs::an_embedded_font_list_already_in_the_package_is_read
    @Test func anEmbeddedFontListAlreadyInThePackageIsRead() throws {
        let bytes = try PPTX.export(Presentation.default)
        let font = Array("FACE-BYTES-FROM-THE-PACKAGE".utf8)
        var files = try IT.entries(bytes).map { e -> (name: String, data: [UInt8]) in
            let xml = String(decoding: e.data, as: UTF8.self)
            switch e.name {
            case "ppt/presentation.xml":
                return (e.name, Array(xml.replacen(
                    "<p:defaultTextStyle",
                    #"<p:embeddedFontLst><p:embeddedFont><p:font typeface="Package Face" pitchFamily="2"/>"#
                        + #"<p:bold r:id="rIdFont"/></p:embeddedFont></p:embeddedFontLst><p:defaultTextStyle"#,
                    1
                ).utf8))
            case "ppt/_rels/presentation.xml.rels":
                return (e.name, Array(xml.replacen(
                    "</Relationships>",
                    #"<Relationship Id="rIdFont" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/font" Target="fonts/font1.fntdata"/></Relationships>"#,
                    1
                ).utf8))
            case "[Content_Types].xml":
                return (e.name, Array(xml.replacen("</Types>", #"<Default Extension="fntdata" ContentType="application/x-fontdata"/></Types>"#, 1).utf8))
            default:
                return e
            }
        }
        files.append(("ppt/fonts/font1.fntdata", font))
        let p = try PPTX.import(IT.zip(files))
        let f = try #require(p.embeddedFonts.first, "font")
        #expect(f.typeface == "Package Face")
        #expect(f.pitchFamily == 2)
        #expect(f.panose == nil && f.regular == nil && f.italic == nil && f.boldItalic == nil)
        let b = try #require(f.bold, "bold")
        #expect(p.media(b)?.data == font)
    }

    /// Text transparency (#32) is `a:alpha` on the run's colour, and survives a save.
    // Rust: it/roundtrip.rs::text_transparency_round_trips
    // Built without the engine: `shape.insert {preset: rect, rect: [100, 100, 200, 100], text: "Hi"}`
    // on the new deck's title slide, then `format.color #336699` (the run's fill) and
    // `format.textTransparency 0.4` (an alpha of round((1 − 0.4) × 100000) on that colour).
    @Test func textTransparencyRoundTrips() throws {
        var doc = newPresentation(nil)
        var sh = Shape.default
        sh.id = ShapeId(doc.allocId() ?? 0)
        sh.name = "Rectangle 1"
        sh.xfrm = Xfrm(100, 100, 200, 100)
        sh.geom = .preset(name: "rect", adj: [])
        sh.style = ShapeStyle.accent(.accent1)
        var body = TextBody.fromText("Hi")
        TextEdit.formatAll(&body) { r in
            r.fill = .solid(ColorRef.rgb(Rgba.rgb(0x33, 0x66, 0x99)).with(.alpha(60000)))
        }
        sh.text = body
        try #require(!doc.slides.isEmpty)
        doc.slides[0].shapes.append(sh)
        let bytes = try PPTX.export(doc)
        let back = try PPTX.import(bytes)
        let found = try #require(back.slides[0].shapes.first { $0.text.map { $0.text.has("Hi") } ?? false })
        let run = try #require(found.text?.paragraphs.first?.runs.first)
        guard case .solid(let color) = run.props.fill else {
            Issue.record("not a solid fill: \(String(describing: run.props.fill))")
            return
        }
        #expect(abs(color.alpha - 0.6) < 1e-9, "\(color)")
    }

    /// Transitions › Sound: a chosen sound is embedded, saved as `p:sndAc`, read back, and No Sound
    /// removes it; a file that isn't audio is refused.
    // Rust: it/roundtrip.rs::transition_sound_is_set_saved_and_removed
    // Built without the engine: `transition.set fade` and `transition.sound {data, name: chime.wav}` set
    // the first slide's transition and embed the sound (content type `audio/wav`, as the engine's
    // `content_type` names a RIFF/WAVE file). The command's own results (`playable`, No Sound, the
    // refusal of a file that isn't audio) need DCEngine (wave 4).
    @Test func transitionSoundIsSetSavedAndRemoved() throws {
        var doc = newPresentation(nil)
        tailSetTransition(&doc, 0, "fade")
        let mAdded = doc.addMedia("chime.wav", "audio/wav", IT.wav(800))
        let m = try #require(mAdded)
        try #require(doc.slides.first?.transition != nil)
        doc.slides[0].transition?.sound = m
        doc.slides[0].transition?.stopSound = false
        doc.slides[0].transition?.soundLoop = false
        #if DCENGINE
        let b64 = Data(IT.wav(800)).base64EncodedString()
        var s = Session.withNew()
        try s.execute("transition.set", ["kind": "fade"])
        let r = try s.execute("transition.sound", ["data": b64, "name": "chime.wav"])
        #expect(r["playable"] == true, "\(r)")
        let doc = s.doc().doc
        #endif
        let set = try #require(doc.slides[0].transition?.sound, "sound set")
        #expect(doc.media(set)?.name == "chime.wav")
        let bytes = try PPTX.export(doc)
        let back = try PPTX.import(bytes)
        let t = try #require(back.slides[0].transition, "transition")
        #expect(t.kind == "fade")
        let saved = try #require(t.sound, "sound survives the save")
        #expect(back.media(saved)?.data.count == IT.wav(800).count)
        #if DCENGINE
        try s.execute("transition.sound", ["none": true])
        #expect(s.doc().doc.slides[0].transition.map { $0.sound == nil } ?? false)
        let notAudio = Data("hello, not a sound".utf8).base64EncodedString()
        #expect(throws: (any Error).self) { try s.execute("transition.sound", ["data": notAudio, "name": "notes.txt"]) }
        #endif
    }

    /// Built-in transition sounds, Loop Until Next Sound and [Stop Previous Sound] are set, saved as
    /// PowerPoint writes them (`p:stSnd loop="1"`, `p:endSnd`) and read back.
    // Rust: it/roundtrip.rs::transition_sound_options_round_trip
    // Built without the engine: a new deck and two `slide.new`, then the transitions `transition.sound`
    // gives them (the built-in Chime as `Chime.wav`, looping on slide 1; again on slide 2; Stop Previous
    // Sound on slide 3). The engine's built-in sound bytes are its own; any WAV stands in for them here.
    // Embedding a built-in sound once, turning the loop off alone and refusing an unknown built-in are
    // the command's and need DCEngine (wave 4).
    @Test func transitionSoundOptionsRoundTrip() throws {
        var doc = newPresentation(nil)
        let layout = layoutOfKind(doc, .titleAndContent) ?? LayoutId.default
        for _ in 0 ..< 2 {
            let added = newSlide(&doc, layout)
            doc.slides.append(try #require(added))
        }
        let mAdded = doc.addMedia("Chime.wav", "audio/wav", IT.wav(800))
        let m = try #require(mAdded)
        for (i, lp) in [(0, true), (1, false)] {
            var t = doc.slides[i].transition ?? Transition.default
            t.sound = m
            t.stopSound = false
            t.soundLoop = lp
            doc.slides[i].transition = t
        }
        var stop = doc.slides[2].transition ?? Transition.default
        stop.sound = nil
        stop.soundLoop = false
        stop.stopSound = true
        doc.slides[2].transition = stop
        #expect(doc.media.count == 1, "the same built-in sound is embedded once")
        #expect(doc.media.first?.name == "Chime.wav")
        let bytes = try PPTX.export(doc)
        let slide1 = IT.text(bytes, "ppt/slides/slide1.xml")
        #expect(slide1.has(#"<p:stSnd loop="1">"#) && slide1.has(#"name="Chime.wav""#), "\(slide1)")
        let back = try PPTX.import(bytes)
        let t = back.slides.map { $0.transition ?? Transition.default }
        try #require(t.count == 3)
        #expect(t[0].sound != nil && t[0].soundLoop && !t[0].stopSound)
        #expect(t[1].sound != nil && !t[1].soundLoop)
        #expect(t[2].sound == nil && t[2].stopSound, "\(t[2])")
        #if DCENGINE
        // Turning the loop off alone keeps the sound.
        try s.execute("transition.sound", ["loop": false, "index": 0])
        let t0 = try #require(s.doc().doc.slides[0].transition)
        #expect(t0.sound != nil && !t0.soundLoop)
        #expect(throws: (any Error).self) { try s.execute("transition.sound", ["builtin": "foghorn"]) }
        #endif
    }

    // Rust: it/roundtrip.rs::literal_line_ends_in_run_text_read_as_breaks_and_survive_save
    @Test func literalLineEndsInRunTextReadAsBreaksAndSurviveSave() throws {
        var p = newPresentation(nil)
        var s = IT.shape(&p, "Code", 10, 10, 400, 100)
        s.text = TextBody.fromText("CRLFHERE")
        try #require(!p.slides.isEmpty)
        p.slides[0].shapes.append(s)
        let bytes = try tailPatchSlides(PPTX.export(p), "CRLFHERE", "one\r\n   two\rthree")
        let a = try PPTX.import(bytes)
        let want = [
            TailRun(kind: .text, text: "one"), TailRun(kind: .break, text: ""), TailRun(kind: .text, text: "   two"),
            TailRun(kind: .break, text: ""), TailRun(kind: .text, text: "three"),
        ]
        #expect(tailRunsOf(a, "one") == want)
        #expect(tailRunsOf(try IT.round(a), "one") == want, "save and reopen keep the runs")
    }

    // Rust: it/roundtrip.rs::color_pulse_keeps_its_effect_colour_and_duration
    @Test func colorPulseKeepsItsEffectColourAndDuration() throws {
        var p = newPresentation(nil)
        let s = IT.shape(&p, "Pulsed", 10, 10, 200, 100)
        try #require(!p.slides.isEmpty)
        p.slides[0].shapes.append(s)
        let white = ColorRef.rgb(Rgba.rgb(255, 255, 255))
        var a = Animation.default
        a.shape = s.id
        a.class = .emphasis
        a.effect = "colorPulse"
        a.durationMs = 1000
        a.color = white
        p.slides[0].animations.append(a)
        let q = try IT.round(p)
        let b = try #require(q.slides.first?.animations.first)
        #expect(b.class == .emphasis && b.effect == "colorPulse")
        #expect(b.color == white)
        #expect(b.amount == nil, "no grow/shrink scale is invented")
        #expect(b.durationMs == 1000)
    }

    // Rust: it/roundtrip.rs::notes_master_placeholders_and_colour_map_survive_save
    @Test func notesMasterPlaceholdersAndColourMapSurviveSave() throws {
        var p = newPresentation(nil)
        var box1 = IT.shape(&p, "Confidential", 100000.0, 200000.0, 3000000.0, 400000.0)
        box1.text = TextBody.fromText("Company confidential")
        let map = [("bg1", "dk1"), ("tx1", "lt1"), ("bg2", "dk2"), ("tx2", "lt2")]
            + ["accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"].map { ($0, $0) }
        let pairs = map.map { Pair($0.0, $0.1) }
        p.notesMaster = Master(name: "Notes Master", shapes: [box1], colorMap: pairs)
        // No slide has notes: the notes master must still be written.
        let q = try IT.round(p)
        let nm = try #require(q.notesMaster, "notes master kept")
        #expect(nm.shapes.count == 1, "own shapes, not the defaults")
        let sh = try #require(nm.shapes.first)
        #expect(sh.name == "Confidential")
        #expect(sh.text?.text == "Company confidential")
        #expect(nm.colorMap == pairs)
    }

    /// Office 2016 charts (`chartEx`): a waterfall reads as a waterfall chart with its data, not as
    /// the "isn't available" fallback text, and an unchanged one is written back as itself with a
    /// plain chart fallback; an edited one is written as a plain chart.
    // Rust: it/roundtrip.rs::chartex_waterfall_reads_and_round_trips
    // Built without the engine: `Session::with_new()` + `slide.new {"layout": "blank"}` is a new deck
    // with a blank slide after its title slide.
    @Test func chartexWaterfallReadsAndRoundTrips() throws {
        var base0 = newPresentation(nil)
        let blank = layoutOfKind(base0, .blank) ?? LayoutId.default
        let added = newSlide(&base0, blank)
        base0.slides.append(try #require(added))
        let base = try PPTX.export(base0)
        let slide = try #require((1 ... 9).map { "ppt/slides/slide\($0).xml" }.first { IT.part(base, $0) != nil })
        let slideRels = slide.replace("slides/", "slides/_rels/") + ".rels"
        let cxRels = #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/package" Target="../embeddings/Microsoft_Excel_Worksheet.xlsx"/></Relationships>"#
        let pptx = try tailRepack(base, { name, x in
            if name == slide {
                return x.replacen("</p:spTree>", "\(tailWaterfallFrame)</p:spTree>", 1)
            } else if name == slideRels {
                return x.replace("</Relationships>", #"<Relationship Id="rIdCx" Type="http://schemas.microsoft.com/office/2014/relationships/chartEx" Target="../charts/chartEx1.xml"/></Relationships>"#)
            } else if name == "[Content_Types].xml" {
                return x.replace("</Types>", #"<Override PartName="/ppt/charts/chartEx1.xml" ContentType="application/vnd.ms-office.chartex+xml"/></Types>"#)
            }
            return x
        }, [("ppt/charts/chartEx1.xml", Array(tailWaterfallCX.utf8)), ("ppt/charts/_rels/chartEx1.xml.rels", Array(cxRels.utf8))])
        let doc = try PPTX.import(pptx)
        let c = try #require(tailChart(doc), "the waterfall is a chart, not the fallback text")
        #expect(c.kind == .waterfall)
        #expect(c.title == "Cash flow")
        #expect(c.categories == ["Start", "Sales", "Costs", "End"])
        #expect(c.series.count == 1)
        #expect(c.series.first?.name == "Amount")
        #expect(c.series.first?.values == [100.0, 40.0, -25.0, 115.0])
        #expect(c.dataLabels)
        #expect(c.legend == "b")
        let noFallbackText = doc.slides.flatMap(\.shapes).allSatisfy { !"\($0.kind)".has("isn't available") }
        #expect(noFallbackText)

        // Unchanged: chartEx back in a cx1 choice, a plain chart as fallback, no workbook link.
        var out = try PPTX.export(doc)
        var ex = String(decoding: try #require(IT.part(out, "ppt/charts/chartEx1.xml"), "chartEx part"), as: UTF8.self)
        #expect(ex.has(#"layoutId="waterfall""#) && !ex.has("externalData"), "\(ex)")
        let types = IT.text(out, "[Content_Types].xml")
        #expect(types.has("application/vnd.ms-office.chartex+xml"))
        let sx = IT.text(out, slide)
        #expect(sx.has(#"Requires="cx1""#) && sx.has("mc:Fallback") && sx.has("c:chart "), "\(sx)")
        let srels = IT.text(out, slideRels)
        #expect(srels.has("relationships/chartEx") && srels.has("relationships/chart\""), "\(srels)")
        #expect(IT.part(out, "ppt/charts/chart1.xml") != nil)
        let again = try #require(tailChart(PPTX.import(out)))
        #expect(again.kind == .waterfall && again.categories == c.categories && again.series.count == 1)

        // Edited: the kept part no longer matches, so a chartEx part is written from the model,
        // still a waterfall with the new value.
        var edited = doc
        for i in edited.slides.indices {
            for j in edited.slides[i].shapes.indices {
                if case .chart(var ch) = edited.slides[i].shapes[j].kind, !ch.series.isEmpty, ch.series[0].values.count > 1 {
                    ch.series[0].values[1] = 55.0
                    edited.slides[i].shapes[j].kind = .chart(ch)
                }
            }
        }
        out = try PPTX.export(edited)
        ex = String(decoding: try #require(IT.part(out, "ppt/charts/chartEx1.xml"), "a written chartEx part"), as: UTF8.self)
        #expect(ex.has(#"layoutId="waterfall""#), "\(ex)")
        #expect(IT.text(out, slide).has("cx1"))
        let reread = try #require(tailChart(PPTX.import(out)))
        #expect(reread.kind == .waterfall)
        #expect(reread.series.first?.values.at(1) == .some(55.0))
        #expect(reread.subtotals == c.subtotals)
    }

    /// New Office 2016 charts made in DeckCraft are written as chartEx parts that read back as the
    /// same type, data and options.
    // Rust: it/roundtrip.rs::chartex_new_charts_save_as_their_own_type
    // Built without the engine: `insert.chart` is `Chart.sample(kind)`; `chart.options` with `binCount`
    // sets it and clears `binSize`, `subtotals` keeps the in-range indices sorted and deduplicated, and
    // `title` sets the title (see `tailChartDeck`).
    @Test func chartexNewChartsSaveAsTheirOwnType() throws {
        let kinds: [(String, ChartType)] = [
            ("waterfall", .waterfall), ("funnel", .funnel), ("treemap", .treemap), ("sunburst", .sunburst),
            ("histogram", .histogram), ("pareto", .pareto), ("boxwhisker", .boxWhisker),
        ]
        for (ty, kind) in kinds {
            let doc = tailChartDeck(kind) { c in
                switch kind {
                case .histogram, .pareto:
                    c.binCount = 4
                    c.binSize = nil
                case .waterfall:
                    let n = c.series.first?.values.count ?? 0
                    c.subtotals = Array(Set([3].filter { $0 < n })).sorted()
                default: break
                }
                c.title = "T"
                c.raw = nil
            }
            let before = try #require(tailChart(doc))
            let out = try PPTX.export(doc)
            #expect(IT.part(out, "ppt/charts/chartEx1.xml") != nil, "\(ty): no chartEx part")
            #expect(IT.part(out, "ppt/charts/chart1.xml") != nil, "\(ty): no fallback chart")
            let after = try #require(tailChart(PPTX.import(out)))
            #expect(after.kind == kind, "\(ty)")
            #expect(after.title == "T", "\(ty)")
            #expect(after.categories == before.categories, "\(ty)")
            let n = kind == .boxWhisker ? before.series.count : 1
            #expect(after.series.count == n, "\(ty)")
            #expect(after.series.first?.values == before.series.first?.values, "\(ty)")
            #expect(after.binCount == before.binCount && after.subtotals == before.subtotals, "\(ty)")
        }
    }

    /// A two-level treemap keeps its parent level, and a box chart its inclusive quartiles, through
    /// a save and reopen.
    // Rust: it/roundtrip.rs::chartex_levels_and_quartiles_round_trip
    // Built without the engine: `chart.data {levels}` sets `categoryLevels` (two levels, under the
    // engine's cap of 16) and `chart.options {quartiles: inclusive}` sets `inclusiveQuartiles`.
    @Test func chartexLevelsAndQuartilesRoundTrip() throws {
        for (ty, kind) in [("treemap", ChartType.treemap), ("sunburst", .sunburst), ("boxwhisker", .boxWhisker)] {
            let doc = tailChartDeck(kind) { c in
                if kind == .boxWhisker {
                    c.inclusiveQuartiles = true
                } else {
                    c.categoryLevels = [["Q1", "", "", "Q2", "", "", "Q3", ""], ["H1", "", "", "", "", "", "H2", ""]]
                }
                c.raw = nil
            }
            let before = try #require(tailChart(doc))
            let out = try PPTX.export(doc)
            let after = try #require(tailChart(PPTX.import(out)))
            #expect(after.categoryLevels == before.categoryLevels, "\(ty)")
            #expect(after.inclusiveQuartiles == before.inclusiveQuartiles, "\(ty)")
            #expect(after.categoryTree() == before.categoryTree(), "\(ty)")
            // Unchanged since import, the part is written back as read.
            let again = try PPTX.export(PPTX.import(out))
            #expect(try #require(tailChart(PPTX.import(again))).categoryLevels == before.categoryLevels, "\(ty)")
        }
    }

    /// Radar, stock (with and without up/down bars) and combo charts keep their own plot groups
    /// through a save and reopen, written as PowerPoint writes them.
    // Rust: it/roundtrip.rs::radar_stock_and_combo_round_trip
    // Built without the engine: `insert.chart` is `Chart.sample(kind)`, and `chart.options
    // {upDownBars: true}` sets `upDownBars`.
    @Test func radarStockAndComboRoundTrip() throws {
        let cases: [(String, ChartType, Bool)] = [
            ("radar", .radar, false), ("filledradar", .filledRadar, false), ("stock", .stock, false), ("stock", .stock, true),
            ("combo", .combo, false),
        ]
        for (ty, kind, bars) in cases {
            let doc = tailChartDeck(kind) { c in
                if bars {
                    c.upDownBars = true
                    c.raw = nil
                }
            }
            let before = try #require(tailChart(doc))
            let out = try PPTX.export(doc)
            let after = try #require(tailChart(PPTX.import(out)))
            #expect(after.kind == before.kind, "\(ty)")
            #expect(after.upDownBars == bars, "\(ty)")
            #expect(after.series.count == before.series.count, "\(ty)")
            let kinds = after.series.map { after.seriesKind($0) }
            let want = before.series.map { before.seriesKind($0) }
            #expect(kinds == want, "\(ty)")
            for (a, b) in zip(after.series, before.series) {
                #expect(a.values == b.values, "\(ty)")
            }
        }
    }

    /// Home › New Slide › Reuse Slides: slides from another .pptx land after the current slide with
    /// their pictures (fresh media ids, same bytes) and animations on the renumbered shapes. By
    /// default they take a destination layout; Keep Source Formatting brings the source master.
    // Rust: it/roundtrip.rs::reuse_slides_from_another_presentation
    // `slide.reuse` is the engine's: it merges another deck's slides, media and masters.
    @Test(.disabled("needs DCEngine (wave 4)")) func reuseSlidesFromAnotherPresentation() throws {
        let pic = IT.png(8, 8, (10, 200, 30))
        let red = IT.png(4, 4, (200, 0, 0))
        _ = (pic, red)
        #if DCENGINE
        let b64 = { (d: [UInt8]) in Data(d).base64EncodedString() }
        // Source: three slides, a picture with an animation on the second.
        var src = Session.withNew()
        try src.execute("slide.new", [:])
        try src.execute("insert.picture", ["data": b64(pic), "name": "green.png"])
        try src.execute("animation.add", ["effect": "fade"])
        try src.execute("slide.new", [:])
        let srcBytes = try PPTX.export(src.doc().doc)

        var s = Session.withNew()
        // Media ids in the two decks overlap; the destination's own picture must stay its own.
        try s.execute("insert.picture", ["data": b64(red), "name": "red.png"])
        var r = try s.execute("slide.reuse", ["data": b64(srcBytes), "name": "src.pptx", "slides": [1]])
        #expect(r["slides"] == 1, "\(r)")
        var doc = s.doc().doc
        #expect(doc.slides.count == 2)
        #expect(s.doc().selection.slide == 1, "the reused slide is selected")
        func pictures(_ sl: Slide) -> [MediaId] {
            var v: [MediaId] = []
            walk(sl.shapes) { sh, _ in
                if case .picture(let fill) = sh.kind { v.append(fill.media) }
            }
            return v
        }
        let mine = pictures(doc.slides[0])
        let reused = pictures(doc.slides[1])
        #expect(doc.media(mine[0])?.data == red, "own picture untouched")
        #expect(doc.media(reused[0])?.data == pic, "reused picture copied")
        let anim = doc.slides[1].animations[0]
        #expect(doc.slides[1].shapes.contains { $0.id == anim.shape }, "animation follows its shape")
        #expect(doc.layout(doc.slides[1].layout) != nil, "uses a destination layout")
        #expect(doc.masters.count == 1)
        // The result saves and reopens.
        let back = try IT.round(doc)
        #expect(back.slides.count == 2)

        // Keep Source Formatting: every slide, and the source master comes along.
        r = try s.execute("slide.reuse", ["data": b64(srcBytes), "name": "src.pptx", "keepFormatting": true, "at": 0])
        #expect(r["slides"] == 3)
        doc = s.doc().doc
        #expect(doc.slides.count == 5)
        #expect(doc.masters.count == 2)
        for sl in doc.slides[..<3] {
            #expect(doc.layout(sl.layout)?.master.id == doc.masters[1].id, "source master")
        }
        // One undo removes the whole reuse.
        try s.execute("edit.undo", [:])
        #expect(s.doc().doc.slides.count == 2)
        #expect(throws: (any Error).self) { try s.execute("slide.reuse", ["data": b64(srcBytes), "name": "src.pptx", "slides": [7]]) }
        #expect(throws: (any Error).self) { try s.execute("slide.reuse", ["data": b64([0, 159, 146, 150]), "name": "x.bin"]) }
        #endif
    }

    /// Picture Format › Compress Pictures: a big picture shown small is downsampled, its original
    /// goes when nothing else uses it, the saved file shrinks, a copy that wasn't compressed keeps
    /// the original, and undo brings everything back.
    // Rust: it/roundtrip.rs::compress_pictures_shrinks_the_file_and_keeps_shared_originals
    // `picture.compress` (downsampling, sharing, undo) is the engine's.
    @Test(.disabled("needs DCEngine (wave 4)")) func compressPicturesShrinksTheFileAndKeepsSharedOriginals() throws {
        // A noisy 1600 × 1600 picture (doesn't compress away on its own).
        let big = IT.pngFrom(1600, 1600) { x, y in
            (UInt8(truncatingIfNeeded: x * 31 % 251), UInt8(truncatingIfNeeded: y * 17 % 253), UInt8(truncatingIfNeeded: (x * y) % 255))
        }
        _ = big
        #if DCENGINE
        let b64 = { (d: [UInt8]) in Data(d).base64EncodedString() }
        var s = Session.withNew()
        try s.execute("insert.picture", ["data": b64(big), "name": "noise.png"])
        try s.execute("shape.resize", ["w": 144, "h": 144])
        let sizeBefore = try PPTX.export(s.doc().doc).count
        let r = try s.execute("picture.compress", ["ppi": 150])
        #expect(r["pictures"] == 1, "\(r)")
        var doc = s.doc().doc
        #expect(doc.media.count == 1, "the original is gone")
        let size = try #require(IT.imageSize(doc.media[0].data))
        #expect(size == (300, 300), "2 in at 150 ppi")
        let sizeAfter = try PPTX.export(doc).count
        #expect(sizeAfter * 4 < sizeBefore, "\(sizeBefore) → \(sizeAfter)")
        try s.execute("edit.undo", [:])
        #expect(s.doc().doc.media[0].data.count == big.count, "undo restores the original")

        // A duplicate that isn't compressed still needs the original.
        try s.execute("edit.duplicate", [:])
        let copy = s.doc().selection.shapes
        let first = s.doc().doc.slides[0].shapes.map(\.id).filter { !copy.contains($0) }
        try s.execute("picture.compress", ["ppi": 150, "ids": [first.last!.rawValue]])
        doc = s.doc().doc
        #expect(doc.media.count == 2)
        #expect(doc.media.contains { $0.data.count == big.count }, "the copy keeps the original")
        // All pictures: the copy gets compressed too, and the original goes.
        try s.execute("picture.compress", ["ppi": 150, "all": true])
        doc = s.doc().doc
        #expect(doc.media.allSatisfy { $0.data.count < big.count / 4 })
        #expect(throws: (any Error).self) { try s.execute("picture.compress", ["ppi": 5, "all": true]) }
        #endif
    }

    /// #203: SmartArt we can't draw kept its XML but lost its diagram parts on save.
    // Rust: it/roundtrip.rs::smartart_without_a_drawing_keeps_its_parts
    @Test func smartartWithoutADrawingKeepsItsParts() throws {
        var p = newPresentation(nil)
        let dataAdded = p.addMedia(
            "data1.xml",
            "application/vnd.openxmlformats-officedocument.drawingml.diagramData+xml",
            Array(#"<dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:ptLst><dgm:pt modelId="1"><dgm:t><a:p><a:r><a:t>Manager</a:t></a:r></a:p></dgm:t></dgm:pt></dgm:ptLst><dgm:extLst><a:ext uri="http://schemas.microsoft.com/office/drawing/2008/diagram"><dsp:dataModelExt xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" relId="rId6"/></a:ext></dgm:extLst></dgm:dataModel>"#.utf8)
        )
        let data = try #require(dataAdded, "media")
        var parts = [Triple("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/diagramData", data)]
        for (i, kind) in ["Layout", "QuickStyle", "Colors"].enumerated() {
            let xml = Array(#"<dgm:\#(kind) xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram"/>"#.utf8)
            let mAdded = p.addMedia("\(kind)1.xml", "application/vnd.openxmlformats-officedocument.drawingml.diagram\(kind)+xml", xml)
            let m = try #require(mAdded, "media")
            parts.append(Triple("rId\(i + 3)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/diagram\(kind)", m))
        }
        let xml = #"<p:graphicFrame xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:nvGraphicFramePr><p:cNvPr id="4" name="Diagram 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:relIds xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" r:dm="rId2" r:lo="rId3" r:qs="rId4" r:cs="rId5"/></a:graphicData></a:graphic></p:graphicFrame>"#
        var s = IT.newSlide(&p, "SmartArt")
        var frame = IT.shape(&p, "Diagram 3", 0, 0, 72, 72)
        frame.kind = .opaque(xml: xml, preview: nil, label: "SmartArt", parts: parts)
        s.shapes.append(frame)
        p.slides.append(s)

        // Twice: the second save starts from what the first one wrote.
        let q = try IT.round(IT.round(p))
        let shape = try #require(q.slides.at(1).flatMap { IT.find($0.shapes, "Diagram 3") })
        guard case .opaque(_, _, _, let kept) = shape.kind else {
            Issue.record("not kept as an object")
            return
        }
        #expect(kept.count == 4, "data, layout, style and colours all kept")
        let dataPart = try #require(kept.first { $0.b.hasSuffix("/diagramData") }, "data")
        let item = try #require(q.media(dataPart.c), "media")
        let text = String(decoding: item.data, as: UTF8.self)
        #expect(text.has("Manager"), "\(text)")
        #expect(!text.has("dataModelExt"), "the link to a drawing that isn't written is dropped: \(text)")
    }

    /// #203: a legacy OLE object (preview in the VML drawing we don't write) is saved in PowerPoint's
    /// fallback form, without `spid` and with a `p:pic` preview, or PowerPoint won't open the file.
    // Rust: it/roundtrip.rs::legacy_ole_object_is_written_in_the_fallback_form
    @Test func legacyOleObjectIsWrittenInTheFallbackForm() throws {
        var p = newPresentation(nil)
        let binAdded = p.addMedia(
            "oleObject1.bin", "application/vnd.openxmlformats-officedocument.oleObject", [0xD0, 0xCF, 0x11, 0xE0] + Array("not-a-real-ole".utf8)
        )
        let bin = try #require(binAdded, "media")
        let prevAdded = p.addMedia("image1.png", "image/png", IT.png(4, 3, (10, 20, 30)))
        let prev = try #require(prevAdded, "media")
        let xml = #"<p:graphicFrame xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:nvGraphicFramePr><p:cNvPr id="4" name="Object 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/presentationml/2006/ole"><p:oleObj spid="_x0000_s1026" name="Slide" r:id="rId4" progId="PowerPoint.Slide.8"><p:embed/></p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"#
        let parts = [Triple("rId4", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject", bin)]
        var s = IT.newSlide(&p, "OLE")
        var frame = IT.shape(&p, "Object 3", 0, 0, 72, 72)
        frame.kind = .opaque(xml: xml, preview: prev, label: "Slide", parts: parts)
        s.shapes.append(frame)
        p.slides.append(s)

        let q = try IT.round(IT.round(p))
        let shape = try #require(q.slides.at(1).flatMap { IT.find($0.shapes, "Object 3") })
        guard case .opaque(let keptXML, let preview, _, let kept) = shape.kind else {
            Issue.record("not kept as an object")
            return
        }
        #expect(keptXML.has("<p:pic>") && !keptXML.has("spid"), "\(keptXML)")
        #expect(preview != nil, "the preview picture is kept")
        #expect(kept.contains { $0.b.hasSuffix("/oleObject") }, "the embedding is kept: \(kept)")
    }

    /// Insert › Zoom: slide, section and summary zooms are linked pictures of their targets, with
    /// Return to Zoom on section and summary zooms; a summary zoom makes its own slide; all of it is
    /// one undo step and saves as linked pictures.
    // Rust: it/roundtrip.rs::zoom_inserts_linked_slide_pictures
    // `insert.zoom` (rendering the target slides, summary slides, undo) is the engine's.
    @Test(.disabled("needs DCEngine (wave 4)")) func zoomInsertsLinkedSlidePictures() throws {
        #if DCENGINE
        var s = Session.withNew()
        for t in ["Intro", "Plan", "Budget", "Risks"] {
            try s.execute("slide.new", ["title": t])
        }
        // Slides: 0 title, 1 Intro, 2 Plan, 3 Budget, 4 Risks.
        try s.execute("slide.go", ["index": 0])
        let r = try s.execute("insert.zoom", ["slides": [2]])
        #expect(r["returnToZoom"] == false)
        var doc = s.doc().doc
        let zoom = try #require(doc.slides[0].shapes.first { $0.name.hasPrefix("Slide Zoom") }, "slide zoom")
        let link = try #require(zoom.click)
        #expect(link.action == .slide(slide: doc.slides[2].id))
        #expect(link.zoomReturn == nil)
        #expect(link.tooltip == "Plan")
        guard case .picture(let fill) = zoom.kind else { Issue.record("not a picture"); return }
        #expect(doc.media(fill.media)?.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        // Section zoom: back after the section's last slide.
        try s.execute("section.add", ["name": "Start", "at": 0])
        try s.execute("section.add", ["name": "Money", "at": 3])
        doc = s.doc().doc
        let money = try #require(doc.sections.firstIndex { $0.name == "Money" })
        try s.execute("slide.go", ["index": 0])
        try s.execute("insert.zoom", ["kind": "section", "sections": [money]])
        doc = s.doc().doc
        let sec = try #require(doc.slides[0].shapes.first { $0.name.hasPrefix("Section Zoom") })
        let last = try #require(doc.sections[money].slides.last)
        #expect(sec.click?.zoomReturn == last)

        // Summary zoom on slides 1 and 3: a new slide in front, parts 1–2 and 3–4.
        let before = doc.slides.count
        try s.execute("insert.zoom", ["kind": "summary", "slides": [1, 3]])
        doc = s.doc().doc
        #expect(doc.slides.count == before + 1)
        let sum = doc.slides[1]
        #expect(sum.title.has("Summary"))
        let tiles = sum.shapes.compactMap(\.click)
        #expect(tiles.count == 2)
        #expect(tiles[0].zoomReturn == doc.slides[3].id, "part one runs to the slide before part two")
        #expect(tiles[1].zoomReturn == doc.slides.last?.id)
        try s.execute("edit.undo", [:])
        #expect(s.doc().doc.slides.count == before, "one undo step")

        // Saved as linked pictures.
        let back = try IT.round(s.doc().doc)
        let z = try #require(back.slides[0].shapes.first { if case .picture = $0.kind { return $0.click != nil }; return false })
        if case .slide = z.click?.action {} else { Issue.record("not a slide link") }
        #expect(throws: (any Error).self) { try s.execute("insert.zoom", ["slides": [42]]) }
        #expect(throws: (any Error).self) { try s.execute("insert.zoom", ["kind": "slide"]) }
        #endif
    }
}
