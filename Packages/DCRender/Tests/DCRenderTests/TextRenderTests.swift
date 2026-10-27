// Ported from deckcraft crates/render/src/tests.rs (the text-drawing tests: ink, flips, hyperlinks,
// colour glyphs, gradient text, text effects, WordArt warps, decorations, vertical text, fields and empty
// bullets; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The COLR test font is
// deckcraft's crates/render/tests/fixtures/colr-squares.ttf (contributor-original, CC0-1.0), embedded
// below. Pixel positions and tolerances are the Rust ones unless a comment says otherwise.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import DCText
import Foundation
import Testing

/// DeckCraft Colr Squares (deckcraft's `make_colr_font.py`, CC0-1.0): U+E000 is a red square with a blue
/// square in its middle, U+E001 a square in the text colour.
private let colrSquares = """
AAEAAAAMAIAAAwBAQ09MUgAHAD0AAAM8AAAAJkNQQUwA//8SAAADZAAAABZPUy8yRQA3FQAAAUgAAABgY21hcL/yIJ0AAAG4AAAAPGdseWaixKS4\
AAACBAAAAGRoZWFkMOIGKAAAAMwAAAA2aGhlYQfRA+oAAAEEAAAAJGhtdHgD6AAAAAABqAAAAA5sb2NhAEoAMAAAAfQAAAAObWF4cAAIAAYAAAEo\
AAAAIG5hbWWljbI7AAACaAAAAI1wb3N0Ig/kjgAAAvgAAABEAAEAAAABAADEZcueXw889QABA+gAAAAA5vLgsAAAAADm8uCwAAAAAAPoA+gAAAAD\
AAIAAAAAAAAAAQAAA+gAAAAAA+gAAAAAA+gAAQAAAAAAAAAAAAAAAAAAAAEAAQAAAAYABAABAAAAAAACAAAAAAAAAAAAAAAAAAAAAAADA+gBkAAF\
AAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEQAAAAAAAAAAAAAAA/Pz8/AAAAIOABA+gAAAAAA+gAAAAAAAAAAAAAAAAAAAAA\
ACAAAAPoAAAAAAAAAAAAAAAAAAAAAAACAAAAAwAAABQAAwABAAAAFAAEACgAAAAGAAQAAQACACDgAf//AAAAIOAA////4SACAAEAAAAAAAAAAAAA\
AAAADAAYACQAMgAAAAEAAAAAA+gD6AADAAAxESERA+gD6PwYAAEAAAAAA+gD6AADAAAxESERA+gD6PwYAAEAAAAAA+gD6AADAAAxESERA+gD6PwY\
AAEBLAEsArwCvAADAAABESERASwBkAEsAZD+cAAAAAQANgABAAAAAAABABYAAAABAAAAAAACAAcAFgADAAEECQABACwAHQADAAEECQACAA4ASURl\
Y2tDcmFmdCBDb2xyIFNxdWFyZXNSZWd1bGFyAEQAZQBjAGsAQwByAGEAZgB0ACAAQwBvAGwAcgAgAFMAcQB1AGEAcgBlAHMAUgBlAGcAdQBsAGEA\
cgAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAADAQIBAwEEAQUHcmVkYmx1ZQNpbmsDYmlnBXNtYWxsAAAAAgAAAA4AAAAa\
AAMAAgAAAAIAAwACAAEABAAAAAUAAQAE//8AAAAAAAIAAQACAAAADgAAAAD///8AAP8AAA==
"""

@Suite struct TextRenderTests {
    // tests.rs: text_draws_ink
    @Test func textDrawsInk() {
        var t = TextBody.fromText("HELLO WORLD")
        t.paragraphs[0].runs[0].props.size = 120
        let p = deckOf([shapeWith(501, Xfrm(0, 0, 960, 540)) {
            $0.textBox = true
            $0.text = t
        }])
        let img = renderSlide(p, 0, renderOpts(0.5))
        let dark = countPixels(img) { $0[0] < 128 }
        #expect(dark > 500, "dark pixels \(dark)")
    }

    /// A slide holding the left-aligned, asymmetric text box at `x`, in a group at `group` if given
    /// (tests.rs `flipped_text`).
    func flippedText(_ x: Xfrm, _ group: Xfrm? = nil) -> RenderImage {
        var s = textShape(1, "Fly 42 RJ", 0, 0)
        s.xfrm = x
        if let g = group { s = shapeOf(2, g, .group(children: [s], child: Xfrm(0, 0, 600, 120))) }
        return renderSlide(deckOf([s]), 0, renderOpts(0.5))
    }

    func with(_ x: Xfrm, _ set: (inout Xfrm) -> Void) -> Xfrm {
        var y = x
        set(&y)
        return y
    }

    // tests.rs: flipped_shapes_draw_readable_text
    @Test func flippedShapesDrawReadableText() {
        let base = Xfrm(180, 200, 600, 120)
        var plain = flippedText(base)
        // Warm up: faces load lazily, so the first render may still fall back.
        if differingValues(plain, flippedText(base)) > 0 { plain = flippedText(base) }
        let turned = flippedText(with(base) { $0.rot = 180 })
        #expect(differingValues(plain, turned) > 200, "the comparisons below must mean something")
        // flipH: text as unflipped (the text box is symmetric). flipV and both: turned 180°.
        var d = differingValues(plain, flippedText(with(base) { $0.flipH = true }))
        #expect(d < 40, "flipH mirrored the text: \(d)")
        d = differingValues(turned, flippedText(with(base) { $0.flipV = true }))
        #expect(d < 40, "flipV mirrored the text: \(d)")
        d = differingValues(turned, flippedText(with(base) { ($0.flipH, $0.flipV) = (true, true) }))
        #expect(d < 40, "flipH+flipV: \(d)")
        // Rotation then flipH: still the rotated text, not its mirror image.
        let rot = with(base) { $0.rot = 30 }
        d = differingValues(flippedText(rot), flippedText(with(rot) { $0.flipH = true }))
        #expect(d < 40, "rotated flipH: \(d)")
        // Groups: a flipped group's text isn't mirrored; a flipped child in a flipped group neither.
        let child = Xfrm(0, 0, 600, 120)
        d = differingValues(plain, flippedText(child, with(base) { $0.flipH = true }))
        #expect(d < 40, "group flipH: \(d)")
        d = differingValues(plain, flippedText(with(child) { $0.flipH = true }, with(base) { $0.flipH = true }))
        #expect(d < 40, "flipH child in flipH group: \(d)")
        d = differingValues(turned, flippedText(child, with(base) { $0.flipV = true }))
        #expect(d < 40, "group flipV: \(d)")
    }

    /// A text box with one 40 pt run of `props` (tests.rs `run_deck`).
    func runDeck(_ props: RunProps) -> Presentation {
        var sh = textShape(1, "Linked text", 40, 40)
        var rp = props
        rp.size = 40
        sh.text?.paragraphs[0].runs[0].props = rp
        return deckOf([sh])
    }

    // tests.rs: hyperlinks_draw_in_the_hyperlink_colour_underlined
    @Test func hyperlinksDrawInTheHyperlinkColourUnderlined() {
        func px(_ p: Presentation) -> RenderImage { renderSlide(p, 0, renderOpts(0.5)) }
        let link = Hyperlink(action: .url(url: "https://example.org"), tooltip: "", highlightClick: false, stopSound: false)
        let hlink = Fill.solid(.scheme(.hlink))
        let red = Fill.solid(.rgb(.rgb(200, 0, 0)))
        _ = px(runDeck(RunProps())) // faces load lazily
        let linked = px(runDeck(RunProps(link: link)))
        #expect(differingValues(linked, px(runDeck(RunProps()))) > 100, "a link doesn't look like plain text")
        // Exactly the theme's hyperlink colour, single underline.
        let styled = px(runDeck(RunProps(underline: "sng", fill: hlink)))
        #expect(differingValues(linked, styled) == 0)
        // A colour on the run itself wins; u="none" drops the underline.
        var own = px(runDeck(RunProps(underline: "none", fill: red, link: link)))
        #expect(differingValues(own, px(runDeck(RunProps(fill: red)))) == 0)
        own = px(runDeck(RunProps(fill: red, link: link)))
        #expect(differingValues(own, px(runDeck(RunProps(underline: "sng", fill: red)))) == 0)
    }

    // tests.rs: colour_glyphs_paint_their_layers
    @Test func colourGlyphsPaintTheirLayers() throws {
        // A COLRv0 test font: U+E000 is a red square with a blue square in its middle, U+E001 a square in
        // the text colour.
        let font = try #require(Data(base64Encoded: colrSquares))
        FontDB.shared.addFont([UInt8](font))
        var t = TextBody.fromText("\u{E000} \u{E001}")
        t.paragraphs[0].runs[0].props.size = 72
        t.paragraphs[0].runs[0].props.font = "DeckCraft Colr Squares"
        t.paragraphs[0].runs[0].props.fill = .solid(.rgb(.rgb(0, 160, 0)))
        let p = deckOf([shapeWith(720, Xfrm(0, 0, 400, 200)) {
            $0.textBox = true
            $0.text = t
        }])
        let img = renderDeck(p)
        let red = countPixels(img) { $0[0] > 230 && $0[1] < 30 && $0[2] < 30 }
        let blue = countPixels(img) { $0[0] < 30 && $0[1] < 30 && $0[2] > 230 }
        let green = countPixels(img) { $0[0] < 30 && $0[1] > 140 && $0[1] < 180 && $0[2] < 30 }
        // 72 pt squares: the blue one is 40 % of the side (16 % of the area).
        #expect(red > 2500 && blue > 500, "red \(red) blue \(blue)")
        let share = Double(blue) / Double(red + blue)
        #expect(abs(share - 0.16) < 0.03, "blue share \(share)")
        // The text-colour glyph is as big as the other square.
        #expect(abs(Double(green) / Double(red + blue) - 1) < 0.1, "green \(green) vs \(red + blue)")
    }

    // tests.rs: a_text_gradient_starts_over_on_every_line
    @Test func aTextGradientStartsOverOnEveryLine() {
        // PowerPoint fills each line of gradient text with the whole gradient, spanning that line (black at
        // the top of every line to white at its bottom), not the text box.
        var t = TextBody.fromText("HHHH\nHHHH")
        let stops = [GradientStop(pos: 0, color: .rgb(.rgb(0, 0, 0))), GradientStop(pos: 1, color: .rgb(.rgb(255, 255, 255)))]
        for p in t.paragraphs.indices {
            t.paragraphs[p].runs[0].props.size = 80
            t.paragraphs[p].runs[0].props.fill = .gradient(Gradient(stops: stops, shape: .linear(angle: 90, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0]))
        }
        let img = renderDeck(deckOf([shapeWith(730, Xfrm(0, 0, 600, 500)) {
            $0.textBox = true
            $0.text = t
        }]))
        // Ink rows (any pixel not white), grouped into the two lines.
        func ink(_ y: Int) -> Bool { (0 ..< 600).contains { pixelAt(img, $0, y)[0] < 250 } }
        var bands: [(Int, Int)] = []
        for y in 0 ..< 500 where ink(y) {
            if let last = bands.last, last.1 + 1 == y { bands[bands.count - 1].1 = y } else { bands.append((y, y)) }
        }
        #expect(bands.count == 2, "\(bands)")
        guard bands.count == 2 else { return }
        func darkest(_ rows: ClosedRange<Int>) -> Int {
            rows.flatMap { y in (0 ..< 600).map { Int(pixelAt(img, $0, y)[0]) } }.min() ?? 255
        }
        // The darkest ink in the first rows of each line.
        let (a, b) = (darkest(bands[0].0 ... bands[0].0 + 5), darkest(bands[1].0 ... bands[1].0 + 5))
        #expect(a < 140 && abs(a - b) < 25, "line tops \(a) and \(b): the second line starts dark again")
        // ...and each line ends light.
        for band in bands {
            let end = darkest(band.1 - 5 ... band.1)
            #expect(end > 150, "line \(band) ends at \(end)")
        }
    }

    /// A text box of big black "IIII" with `set` applied to its run (tests.rs `effect_text`).
    func effectText(_ set: (inout RunProps) -> Void) -> Presentation {
        var t = TextBody.fromText("IIII")
        t.paragraphs[0].runs[0].props.size = 100
        t.paragraphs[0].runs[0].props.fill = .solid(.rgb(.rgb(0, 0, 0)))
        set(&t.paragraphs[0].runs[0].props)
        return deckOf([shapeWith(740, Xfrm(100, 100, 600, 300)) {
            $0.textBox = true
            $0.text = t
        }])
    }

    // tests.rs: text_glow_and_shadow_are_drawn
    // The Rust test also asserts `needs_filters`, vello's choice of a filter pass, which has no
    // counterpart on CoreGraphics; those two assertions are left out.
    @Test func textGlowAndShadowAreDrawn() {
        func green(_ p: [UInt8]) -> Bool { p[1] > 150 && p[0] < 120 && p[2] < 120 }
        let plain = effectText { _ in }
        #expect(countPixels(renderDeck(plain), green) == 0)
        // Glow: a green halo hugging the letters.
        let glow = effectText { $0.glow = Glow(color: .rgb(.rgb(0, 255, 0)), radius: 8) }
        let halo = countPixels(renderDeck(glow), green)
        #expect(halo > 300, "green halo pixels \(halo)")
        // Shadow: grey ink below and right of the letters, where the plain text has none.
        let shadow = effectText {
            $0.shadow = Shadow(color: .rgb(.rgba(0, 0, 0, 128)), blur: 2, dist: 12, dir: 45, inner: false, sx: 1, sy: 1, kx: 0, ky: 0, align: "", rotateWithShape: false)
        }
        func grey(_ p: [UInt8]) -> Bool { p[0] > 60 && p[0] < 230 && p[0] == p[1] && p[1] == p[2] }
        let (shaded, base) = (countPixels(renderDeck(shadow), grey), countPixels(renderDeck(plain), grey))
        #expect(shaded > base + 300, "a grey shadow appears: \(shaded) vs \(base)")
    }

    /// A 400 × 200 text box at (100, 100) holding `text` at 40 pt, centred, warped by `warp`
    /// (tests.rs `wordart`).
    func wordart(_ warp: String?, _ text: String) -> Presentation {
        var t = TextBody.fromText(text)
        t.paragraphs[0].runs[0].props.size = 40
        t.paragraphs[0].props.align = .center
        t.body.warp = warp
        return deckOf([shapeWith(700, Xfrm(100, 100, 400, 200)) { $0.text = t }])
    }

    // tests.rs: wordart_arch_up_lifts_the_middle_of_the_line
    @Test func wordartArchUpLiftsTheMiddleOfTheLine() throws {
        let flat = renderDeck(wordart(nil, "ARCHED WORDART"))
        let arched = renderDeck(wordart("textArchUp", "ARCHED WORDART"))
        #expect(differingValues(flat, arched) > 1000)
        let ((fx0, _, fx1, _), ftops) = inkBox(flat)
        let ((ax0, ay0, ax1, _), atops) = inkBox(arched)
        func topNear(_ tops: [Int?], _ x: Int) -> Int? {
            (Swift.max(x - 15, 0) ..< x + 15).compactMap { tops.at($0) ?? nil }.min()
        }
        // Flat text: the ends and the middle stand on one line.
        let (fl, fm) = (try #require(topNear(ftops, fx0 + 20)), try #require(topNear(ftops, (fx0 + fx1) / 2)))
        #expect(abs(fl - fm) < 4, "flat \(fl) \(fm)")
        // Arched: the line follows the top of the ellipse inscribed in the box, so the middle is at the box
        // top and the ends sit clearly lower.
        let al = try #require(topNear(atops, ax0 + 20))
        let am = try #require(topNear(atops, (ax0 + ax1) / 2))
        let ar = try #require(topNear(atops, ax1 - 20))
        #expect(al > am + 10 && ar > am + 10, "arched \(al) \(am) \(ar)")
        // At the box top (y = 100), give or take the font.
        #expect((70 ... 110).contains(ay0), "arch top \(ay0)")
    }

    // tests.rs: wordart_plain_stretches_the_ink_over_the_text_rect
    @Test func wordartPlainStretchesTheInkOverTheTextRect() {
        let img = renderDeck(wordart("textPlain", "PLAIN"))
        let ((x0, y0, x1, y1), _) = inkBox(img)
        for (got, want) in [(x0, 100), (y0, 100), (x1, 499), (y1, 299)] {
            #expect(abs(got - want) <= 2, "ink box \((x0, y0, x1, y1))")
        }
    }

    // tests.rs: unknown_or_absent_warps_draw_flat_text
    @Test func unknownOrAbsentWarpsDrawFlatText() {
        let o = renderOpts(0.5)
        // Warm the font database first (other tests load fonts concurrently).
        _ = renderSlide(wordart(nil, "FLAT"), 0, o)
        let flat = renderSlide(wordart(nil, "FLAT"), 0, o)
        for w in ["textNoShape", "bogus", ""] {
            #expect(differingValues(flat, renderSlide(wordart(w, "FLAT"), 0, o)) == 0, "\(w)")
        }
    }

    // tests.rs: every_warp_preset_renders_text_inside_the_slide
    @Test func everyWarpPresetRendersTextInsideTheSlide() {
        for name in ["textArchUp", "textArchDown", "textCircle", "textButton", "textWave1", "textRingInside", "textCirclePour", "textDeflateInflateDeflate"] {
            var p = wordart(name, "One line\nTwo line\nThree")
            p.slides[0].shapes[0].text?.body.warpAdj = [.nan, -1e12]
            let ((x0, y0, x1, y1), _) = inkBox(renderSlide(p, 0, renderOpts(0.5)))
            #expect(x0 <= x1 && y0 <= y1, "\(name): no ink")
        }
    }

    // warp.rs `mod tests`: warp_path_subdivides_and_maps_every_point
    @Test func warpPathSubdividesAndMapsEveryPoint() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(10, 0))
        p.lineTo(Point(10, 10))
        p.closePath()
        var out = WarpText.warpPath(p, 0.01, 1) { Point($0.x, $0.y + $0.x * $0.x * 0.01) }
        // 10 + 10 + ~15 pieces of at most 1 pt.
        #expect(out.elements.count > 30, "\(out.elements.count)")
        // The first edge is bent onto the parabola.
        let mid = out.elements.lazy.compactMap { e -> Point? in
            if case .lineTo(let q) = e, q.x == 5 { return q }
            return nil
        }.first
        #expect(mid == Point(5, 0.25))
        // A huge path with a tiny segment length stays bounded.
        var big = BezPath()
        big.moveTo(Point(0, 0))
        for i in 0 ..< 1000 { big.lineTo(Point(1e6 * Double(i % 2), Double(i))) }
        out = WarpText.warpPath(big, 0.01, 1e-3) { $0 }
        #expect(out.elements.count <= WarpText.maxPoints + 2)
    }

    // tests.rs: text_in_a_scaled_group_keeps_its_point_size
    @Test func textInAScaledGroupKeepsItsPointSize() {
        // A group's child coordinates scale its shapes' boxes, never their type: a 24 pt word in a group
        // whose child space is 1/1600 of its size (as old decks write them) or 4 times it is 24 pt on the
        // slide, and inside its box.
        func draw(_ scale: Double) -> RenderImage {
            var body = TextBody.fromText("Hello")
            body.paragraphs[0].runs[0].props.size = 24
            body.paragraphs[0].runs[0].props.fill = .solid(.rgb(.black))
            let child = shapeWith(601, Xfrm(0, 0, 400 / scale, 200 / scale)) { $0.text = body }
            return renderDeck(deckOf([shapeOf(600, Xfrm(100, 100, 400, 200), .group(children: [child], child: Xfrm(0, 0, 400 / scale, 200 / scale)))]))
        }
        let ((_, y0, _, y1), _) = inkBox(draw(1))
        let plain = y1 - y0
        #expect(plain > 10 && plain < 30, "24 pt word ink height \(plain)")
        for scale in [1600.0, 4, 0.25] {
            let ((x0, sy0, x1, sy1), _) = inkBox(draw(scale))
            #expect(abs((sy1 - sy0) - plain) <= 1, "scale \(scale): ink height \(sy1 - sy0) vs \(plain)")
            #expect(x0 >= 100 && x1 <= 500 && sy0 >= 100 && sy1 <= 300, "scale \(scale): ink inside the box")
        }
    }

    // tests.rs: dotted_and_wavy_underlines_draw_their_pattern
    @Test func dottedAndWavyUnderlinesDrawTheirPattern() {
        // Underlined spaces only, so the underline is the only ink: a red line under the spaces.
        func rowRuns(_ u: String) -> (Int, Int) {
            var t = TextBody.fromText("            ")
            t.paragraphs[0].runs[0].props.size = 96
            t.paragraphs[0].runs[0].props.underline = u
            t.paragraphs[0].runs[0].props.fill = .solid(.rgb(.rgb(255, 0, 0)))
            let img = renderDeck(deckOf([shapeWith(760, Xfrm(0, 0, 900, 300)) {
                $0.textBox = true
                $0.text = t
            }]))
            let s = img.toStraight()
            func isRed(_ x: Int, _ y: Int) -> Bool {
                let i = (y * img.width + x) * 4
                return s[i] > 150 && s[i + 1] < 120
            }
            // The ink's rows, and the number of separate red stretches along the most inked row.
            let rows = (0 ..< 300).filter { y in (0 ..< 900).contains { isRed($0, y) } }
            let best = rows.max { a, b in (0 ..< 900).filter { isRed($0, a) }.count < (0 ..< 900).filter { isRed($0, b) }.count } ?? 0
            let stretches = (1 ..< 900).filter { isRed($0, best) && !isRed($0 - 1, best) }.count
            return (rows.count, stretches)
        }
        let (sngRows, sngRuns) = rowRuns("sng")
        #expect(sngRuns == 1, "a single line is one stretch")
        let (_, dottedRuns) = rowRuns("dotted")
        #expect(dottedRuns > 10, "dots: \(dottedRuns)")
        let (wavyRows, _) = rowRuns("wavy")
        #expect(wavyRows > sngRows, "a wave spans more rows (\(wavyRows)) than a single line (\(sngRows))")
    }

    // tests.rs: east_asian_vertical_text_stands_ideographs_upright
    @Test func eastAsianVerticalTextStandsIdeographsUpright() {
        // "一" is a horizontal stroke. In eaVert text it stays horizontal (upright) while the line runs down
        // the shape; in vert it lies on its side like Latin text.
        func ink(_ dir: TextDir) -> (Int, Int)? {
            var t = TextBody.fromText("一")
            t.body.vert = dir
            t.paragraphs[0].runs[0].props.size = 80
            t.paragraphs[0].runs[0].props.fill = .solid(.rgb(.rgb(0, 0, 0)))
            let img = renderDeck(deckOf([shapeWith(770, Xfrm(100, 50, 200, 400)) {
                $0.textBox = true
                $0.text = t
            }]))
            let ((x0, y0, x1, y1), _) = inkBox(img)
            guard x1 >= x0, y1 >= y0 else { return nil }
            return (x1 - x0, y1 - y0)
        }
        let ea = ink(.eaVertical)
        #expect(ea.map { $0.0 > $0.1 * 3 } == true, "eaVert: upright stroke \(String(describing: ea))")
        let v = ink(.vertical)
        #expect(v.map { $0.1 > $0.0 * 3 } == true, "vert: stroke on its side \(String(describing: v))")
    }

    /// A text box holding one run of field `kind` (plain text for nil) saved as `saved`
    /// (tests.rs `field_shape`).
    func fieldShape(_ kind: String?, _ saved: String) -> Shape {
        var sh = textShape(1, saved, 40, 40)
        if let k = kind { sh.text?.paragraphs[0].runs[0].kind = .field(field: k) }
        return sh
    }

    // tests.rs: date_fields_show_the_date_in_their_format
    @Test func dateFieldsShowTheDateInTheirFormat() {
        let fri = DateTime(2026, 10, 9, 20, 5, 7)
        func at(_ p: Presentation, _ now: DateTime) -> RenderImage { renderSlide(p, 0, renderOpts(0.5) { $0.now = now }) }
        var p = deckOf([fieldShape("datetime1", "1/1/2000")])
        _ = at(p, fri) // faces load lazily
        // The field shows the date (it changes with the clock), not its saved text.
        let a = at(p, fri)
        #expect(differingValues(a, at(p, DateTime(2027, 3, 4, 0, 0, 0))) > 0)
        let shown = deckOf([fieldShape(nil, "10/9/2026")])
        #expect(differingValues(a, at(shown, fri)) == 0, "datetime1 is M/D/YYYY")
        // Another slide's fixed date (a deck-wide Header & Footer text) doesn't replace it.
        p.headerFooter.dateText = "Fixed on another slide"
        #expect(differingValues(a, at(p, fri)) == 0)
        // Every type has its format; the run's language orders numeric dates.
        let f = Renderer().fields(p, 0, renderOpts { $0.now = fri })
        #expect(f.field("datetime4", lang: "en-US") == "October 9, 2026")
        #expect(f.field("datetimeFigureOut", lang: "en-GB") == "09/10/2026")
        #expect(f.field("datetime13") == "8:05:07 PM")
        #expect(f.field("slidenum") == "1")
        // A date the app can't compute (no clock, unknown type, other-language names) keeps the saved text.
        var noClock = f
        noClock.now = nil
        #expect(noClock.field("datetime1") == nil)
        let unknown = deckOf([fieldShape("datetime99", "Saved text")])
        let plain = deckOf([fieldShape(nil, "Saved text")])
        #expect(differingValues(at(unknown, fri), at(plain, fri)) == 0)
        // An explicit override still wins.
        let o = renderOpts {
            $0.dateText = "Today"
            $0.now = fri
        }
        #expect(Renderer().fields(p, 0, o).field("datetime2") == "Today")
    }

    // tests.rs: empty_bullet_is_gray_only_while_editing_and_never_in_exports
    @Test func emptyBulletIsGrayOnlyWhileEditingAndNeverInExports() {
        var para = Paragraph()
        para.props.bullet = .char(char: "•")
        para.props.marginLeft = 24
        para.props.indent = -24
        para.endProps.size = 32
        let p = deckOf([shapeWith(901, Xfrm(100, 100, 400, 120)) { $0.text = TextBody(paragraphs: [para]) }])
        func render(_ edit: Bool, _ editingText: ShapeId?) -> RenderImage {
            renderSlide(p, 0, renderOpts(1) {
                $0.edit = edit
                $0.editingText = editingText
            })
        }
        let plain = render(false, nil)
        #expect(plain.pixels == render(true, nil).pixels)
        #expect(plain.pixels == render(false, ShapeId(901)).pixels, "export ignores editor markers")
        #expect(plain.pixels == render(true, ShapeId(902)).pixels, "other shapes stay empty")
        let editing = render(true, ShapeId(901))
        let changed = zip(straightPixels(editing), straightPixels(plain)).filter { $0.0 != $0.1 }.map(\.0)
        #expect(!changed.isEmpty, "an empty bullet must be visible")
        #expect(changed.contains { $0[0] == 179 && $0[1] == 179 && $0[2] == 179 })
        #expect(changed.allSatisfy { $0[0] >= 179 && $0[0] == $0[1] && $0[1] == $0[2] })
    }
}
