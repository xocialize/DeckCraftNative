// Ported from deckcraft crates/render/src/tests.rs and tests_wild.rs (the table tests; MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors). table.rs has no tests of its own. Tolerances are the Rust
// ones unless noted.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import DCText
import Testing

@Suite struct TableTests {
    @Test func tableRowsOfZeroHeightGrowToFitText() throws {
        // pandoc and python-pptx write `<a:tr h="0">`: the stored row height is only a minimum.
        var t = Table(rows: 3, cols: 2, width: 300, rowHeight: 0)
        for (r, row) in [["Col A", "Col B"], ["1", "alpha"], ["2", "beta"]].enumerated() {
            for (c, text) in row.enumerated() { t.mutateCell(r, c) { $0.text = .fromText(text) } }
        }
        let p = deckOf([shapeOf(610, Xfrm(100, 100, 300, 0), .table(t))])
        let ctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        let hs = TableRender.rowHeights(ctx, t, NoFields())
        #expect(hs.count == 3)
        #expect(hs.allSatisfy { $0 > 10 }, "\(hs)")
        let tops = TableRender.cellRects(t, hs).filter { $0.1 == 0 }.map(\.2.y0)
        #expect(tops.count == 3 && zip(tops, tops.dropFirst()).allSatisfy { $1 > $0 + 10 }, "\(tops)")
        // A taller stored height is kept.
        var tall = t
        tall.rows[1].height = 200
        #expect(TableRender.rowHeights(ctx, tall, NoFields())[1] == 200)
        // The PDF text layer gets every cell's text, rows one below the other.
        let placed = placeSlide(p, 0)
        func top(_ s: String) throws -> Double {
            let pt = try #require(placed.texts.first { $0.body.text == s }, "no placed text \(s)")
            let line = try #require(pt.layout.lines.first)
            return (pt.transform * Point(0, line.top)).y
        }
        #expect(try top("Col A") < top("1") && top("1") < top("2"))
        #expect(try abs(top("alpha") - top("1")) < 1 && abs(top("beta") - top("2")) < 1)
        #expect(try top("Col B") >= 100)
    }

    @Test func aFileDefinedTableStyleDrawsItsParts() {
        // Red table background (tblBg), see-through white on banded rows, a 4 pt blue left border and no inside
        // lines: drawn from the definition, not DeckCraft's own look for the style.
        func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ColorRef { .rgb(.rgb(r, g, b)) }
        var t = Table(rows: 4, cols: 2, width: 400, rowHeight: 50)
        t.style = "{ABCDEF01-2345-4678-9ABC-DEF012345678}"
        t.firstRow = false
        t.bandRow = true
        func line(_ c: ColorRef, _ w: Double) -> TableBorder {
            var l = Line.default
            l.fill = .solid(c)
            l.width = w
            return .line(line: l)
        }
        var whole = TablePartStyle(fill: .none_)
        whole.borders[0] = line(rgb(0, 0, 255), 4)
        var none = Line.default
        none.fill = .none_
        whole.borders[4] = .line(line: none)
        let seeThrough = ColorRef.rgb(Rgba(r: 255, g: 255, b: 255, a: 51))
        let band = TablePartStyle(fill: .solid(seeThrough))
        var def = TableStyleDef.default
        def.id = t.style
        def.name = "Probe"
        def.parts = [Pair(.wholeTbl, whole), Pair(.band1H, band)]
        def.background = TablePartStyle(fill: .solid(rgb(255, 0, 0)))
        var p = deckOf([shapeOf(790, Xfrm(100, 100, 400, 200), .table(t))])
        p.tableStyles.append(def)
        let img = renderDeck(p)
        // Row 1 (band1H): red with 20 % white over it; row 2 (band2H, undefined): plain red.
        let banded = pixelAt(img, 300, 125)
        #expect(banded[0] > 250 && (40 ..< 65).contains(banded[1]), "\(banded)")
        #expect(Array(pixelAt(img, 300, 175).prefix(3)) == [255, 0, 0])
        // No line between the rows; a blue left border.
        let edge = pixelAt(img, 300, 150)
        #expect(edge[0] > 240, "no inside line: \(edge)")
        let left = pixelAt(img, 100, 175)
        #expect(left[2] > 200 && left[0] < 60, "\(left)")
    }

    @Test func aTableFillShowsBehindCellsWithoutTheirOwn() {
        // `a:tblPr` solidFill (tdf#127237): cells with no fill show the table's blue.
        var t = Table(rows: 2, cols: 2, width: 200, rowHeight: 50)
        t.style = "none"
        t.background = .solid(.rgb(.rgb(0, 112, 192)))
        for r in 0 ..< 2 {
            for c in 0 ..< 2 { t.mutateCell(r, c) { $0.fill = .none_ } }
        }
        let img = renderDeck(deckOf([shapeOf(795, Xfrm(100, 100, 200, 100), .table(t))]))
        #expect(Array(pixelAt(img, 150, 160).prefix(3)) == [0, 112, 192])
        #expect(Array(pixelAt(img, 50, 50).prefix(3)) == [255, 255, 255])
    }

    @Test func tableBodyTextIsDarkOnTheTintedCellsOfADarkTheme() throws {
        // The default style (medium2) tints body cells towards white, so their text must be the theme's dark
        // colour, as PowerPoint's medium styles set it (dk1): inheriting the text colour leaves it light, and
        // unreadable, on a dark theme such as Nocturne.
        func fillAndDarkest(_ theme: String) throws -> (Double, Double) {
            var t = Table(rows: 2, cols: 2, width: 200, rowHeight: 40)
            for (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)] { t.mutateCell(r, c) { $0.text = .fromText("Body") } }
            var p = deckOf([shapeOf(796, Xfrm(100, 100, 200, 80), .table(t))])
            p.masters[0].theme = try #require(builtinThemes().first { $0.name == theme })
            let img = renderDeck(p)
            func lum(_ x: Int, _ y: Int) -> Double {
                let px = pixelAt(img, x, y)
                return Rgba.rgb(px[0], px[1], px[2]).luminance
            }
            // Body cell (1, 1) covers (200, 140)–(300, 180); its top-left corner is clear of the text (cell
            // margins) and of the white grid line.
            let fill = lum(203, 143)
            var darkest = 1.0
            for y in 143 ..< 177 {
                for x in 203 ..< 297 { darkest = Swift.min(darkest, lum(x, y)) }
            }
            return (fill, darkest)
        }
        for theme in ["Nocturne", "Harbor"] {
            let (fill, darkest) = try fillAndDarkest(theme)
            #expect(fill > 0.4, "\(theme): the body cell's fill is a light tint, luminance \(fill)")
            #expect(darkest < 0.15 && darkest < fill / 3, "\(theme): darkest pixel in the body cell has luminance \(darkest) on a fill of \(fill): its text is not dark")
        }
    }

    @Test func tableLightAndDarkPresetsGiveTheirOwnHeaderAndBodyLooks() throws {
        // light1, light2 and dark1 each style the header and banded body cells their own way.
        let p = Presentation.default
        let ctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        let a = ctx.color(.scheme(.accent1), nil)
        func look(_ style: String, _ r: Int) -> CellLook {
            var t = Table(rows: 3, cols: 1, width: 100, rowHeight: 90)
            t.style = style
            t.firstRow = true
            t.bandRow = true
            return TableRender.lookWithDef(ctx, nil, t, r, 0)
        }
        let edge = { (c: Rgba, w: Double) in Pair(c, w) }

        // light1: header has no fill, bold text and an accent border; banded body rows get a light tint.
        var h = look("light1", 0)
        #expect(h.fill == nil && h.bold && h.border == edge(a, 1))
        var b = look("light1", 1)
        #expect(b.fill == applyTransforms(a, [.tint(20000)]))
        #expect(b.text != nil && !b.bold)

        // light2: accent-filled header with white bold text; body has no fill.
        h = look("light2", 0)
        #expect(h.fill == a && h.text == .white && h.bold && h.border == edge(a, 1))
        b = look("light2", 1)
        #expect(b.fill == nil && b.text == nil && !b.bold)

        // dark1: black header, shaded accent body (darker when banded), white text and white borders.
        h = look("dark1", 0)
        #expect(h.fill == .black && h.text == .white && h.bold && h.border == edge(.white, 1))
        b = look("dark1", 1)
        #expect(b.fill == applyTransforms(a, [.shade(60000)]))
        #expect(b.text == .white)
    }

    @Test func tableRowsBelowTheSlideAreNotLaidOutAndTheSlideLooksTheSame() {
        // A fuzzed deck's 200 × 200 table of long text took 70 s to draw, most of it off the slide.
        func table(_ rows: Int) -> Shape {
            var t = Table(rows: rows, cols: 2, width: 400, rowHeight: 30)
            for r in 0 ..< rows {
                for c in 0 ..< 2 { t.mutateCell(r, c) { $0.text = .fromText("Row \(r) col \(c)") } }
            }
            return shapeOf(611, Xfrm(50, 50, 400, 30 * Double(rows)), .table(t))
        }
        let counter = TableRender.TextCellCounter()
        let big = TableRender.$textCellsDrawn.withValue(counter) { renderDeck(deckOf([table(500)]), 0.5) }
        let drawn = counter.value
        #expect(drawn > 2 * 10 && drawn < 2 * 40, "\(drawn) cells drawn")
        // 30 rows already run past the slide's bottom: the same picture.
        let small = renderDeck(deckOf([table(30)]), 0.5)
        #expect(big.width == small.width && big.height == small.height)
        #expect(big.pixels == small.pixels)
    }

    @Test func tableBordersTakeTheirDashesAndDiagonalsAreDrawn() {
        var t = Table(rows: 1, cols: 1, width: 200, rowHeight: 100)
        t.style = "none"
        var dashed = Line.solid(.rgb(solidRed), 4)
        dashed.dash = .preset(name: "dash")
        t.mutateCell(0, 0) { c in
            c.borders[2] = dashed
            c.diagDown = .solid(.rgb(.rgb(0, 0, 255)), 4)
        }
        let img = renderDeck(deckOf([shapeOf(27, Xfrm(100, 100, 200, 100), .table(t))]))
        // Dashes of 4 widths (16 pt) on, 3 (12 pt) off along the top edge, from its start.
        #expect(nearRGB(pixelAt(img, 108, 100), solidRed, 40) && nearRGB(pixelAt(img, 122, 100), .white, 30) && nearRGB(pixelAt(img, 135, 100), solidRed, 40))
        // The diagonal from top-left to bottom-right passes through the middle.
        #expect(nearRGB(pixelAt(img, 200, 150), .rgb(0, 0, 255), 40), "\(pixelAt(img, 200, 150))")
    }

    @Test func cellBodiesTakeTheStylesTextColourBoldAndMargins() throws {
        // Not a deckcraft test: `cellBody` as the PDF text layer reads it. medium2's header is bold white on
        // the accent; the margins default to 7.2 / 3.6 pt and the anchor to the top.
        let p = Presentation.default
        let ctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        var t = Table(rows: 2, cols: 1, width: 100, rowHeight: 30)
        t.mutateCell(0, 0) { $0.text = .fromText("Head") }
        let cell = try #require(t.cell(0, 0))
        let body = TableRender.cellBody(ctx, t, 0, 0, cell)
        #expect(body.body.insetL == 7.2 && body.body.insetR == 7.2 && body.body.insetT == 3.6 && body.body.insetB == 3.6)
        #expect(body.body.anchor == .top)
        let run = try #require(body.paragraphs.first?.runs.first)
        #expect(run.props.bold == true)
        #expect(run.props.fill == .solid(.rgb(.white)))
        // A style id matches whatever its ASCII case.
        var styled = t
        styled.style = "{abcdef01-2345-4678-9abc-def012345678}"
        var q = p
        var def = TableStyleDef.default
        def.id = "{ABCDEF01-2345-4678-9ABC-DEF012345678}"
        q.tableStyles = [def]
        let qctx = try #require(Resolve.Ctx.forSlide(q, q.slides[0]))
        #expect(TableRender.resolveStyle(qctx, styled)?.id == def.id)
    }
}
