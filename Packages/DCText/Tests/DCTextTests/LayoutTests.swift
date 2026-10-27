// DCTextTests — line breaking, kerning and ligatures, autofit, spacing, carets, alignment, numbering. Port
// of deckcraft crates/text/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Widths come from CoreText, not HarfRust: assertions compare layouts with each other, so
// they hold for either shaper.
import DCColor
import DCGeometry
import DCModel
@testable import DCText
import Testing

@Suite struct LayoutTests {
    @Test func wrapsLongTextIntoLines() {
        let text = "The quick brown fox jumps over the lazy dog and keeps on running far away"
        let l = setup(text, 200, 400).lay(200, 400)
        #expect(l.lines.count >= 3)
        for li in l.lines {
            #expect((li.caretX.last ?? 0) <= 200.5)
            #expect(li.caretX.count == li.end - li.start + 1)
        }
        #expect(l.lines.first?.start == 0)
        #expect(!l.runs.isEmpty)
    }

    @Test func bulletsAreDrawnForBodyText() {
        let l = setup("One\nTwo", 600, 300).lay(600, 300)
        // Two text runs + two bullet runs.
        #expect(l.runs.count >= 4)
        #expect(l.paraLines.count == 2)
    }

    /// Glyph count and width of `text` laid out in one line of `family` at 40 pt, kern threshold `kern`.
    func glyphsAndWidth(_ family: String, _ text: String, _ kern: Double?) -> (Int, Double) {
        var f = setup(text, 2000, 300)
        f.eachPara { $0.props.bullet = .none_ }
        f.eachRun {
            $0.props.font = family
            $0.props.size = 40
            $0.props.kern = kern
        }
        let l = f.lay(2000, 300)
        return (l.runs.map(\.glyphs.count).reduce(0, +), l.lines[0].extent.right - l.lines[0].extent.left)
    }

    func ligates(_ f: FontFace) -> Bool { Shaper.shapeLogical(f, Array("office".unicodeScalars)).count < 6 }

    func kerns(_ f: FontFace) -> Bool {
        let s = Array("AVATAR".unicodeScalars)
        let on = Shaper.shape(f, s, rtl: false, kern: true, ligatures: true, lang: nil).map(\.xAdvance).reduce(0, +)
        let off = Shaper.shape(f, s, rtl: false, kern: false, ligatures: true, lang: nil).map(\.xAdvance).reduce(0, +)
        return on != off
    }

    @Test func latinTextDrawsNoLigatures() throws {
        // PowerPoint keeps "fi", "ffi" and Calibri's "ti" apart, although the fonts have them as ligatures.
        let family = try #require(firstFamily(latinFamilies, ligates), "no font with an ffi ligature")
        let (n, _) = glyphsAndWidth(family, "office fifth", 0)
        #expect(n == 12, "\(family): one glyph per character")
    }

    @Test func pairsAreKernedOnlyFromTheKernSize() throws {
        let family = try #require(firstFamily(latinFamilies, kerns), "no font that kerns AVATAR")
        // `kern` is the smallest size kerned; 0 is no kerning.
        let off = glyphsAndWidth(family, "AVATAR WAVE", 0).1
        let on = glyphsAndWidth(family, "AVATAR WAVE", 12).1
        let at = glyphsAndWidth(family, "AVATAR WAVE", 40).1
        let above = glyphsAndWidth(family, "AVATAR WAVE", 48).1
        #expect(on < off - 2, "\(family): kerned \(on) vs \(off)")
        #expect(near(at, on), "kerned at exactly the threshold size")
        #expect(near(above, off), "40 pt is below a 48 pt threshold")
    }

    @Test func characterSpacingInTheBodyKeepsKerning() throws {
        let family = try #require(firstFamily(latinFamilies, kerns), "no font that kerns AVATAR")
        let off = glyphsAndWidth(family, "AVATAR WAVE", 0).1
        let on = glyphsAndWidth(family, "AVATAR WAVE", 12).1
        #expect(on < off)
        for spc in [0.0, 0.5, -1.0, 0.6, 2.0] {
            var f = setup("AVATAR WAVE", 2000, 300)
            var second = f.body.paragraphs[0]
            second.runs[0].props.spacing = spc
            f.body.paragraphs.append(second)
            f.eachPara { $0.props.bullet = .none_ }
            f.eachRun {
                $0.props.font = family
                $0.props.size = 40
                $0.props.kern = 12
            }
            let l = f.lay(2000, 300)
            let w = l.lines[0].extent.right - l.lines[0].extent.left
            #expect(near(w, on), "\(family) spc \(spc): \(w) vs \(on)")
        }
    }

    @Test func ligaturesStayForScriptsThatNeedThem() {
        func cells(_ s: String) -> ArraySlice<TextCell> {
            ArraySlice(s.unicodeScalars.map { TextCell(ch: $0, style: 0, face: 0, level: 0, head: 0, boundary: true) })
        }
        let latin = shapingFeatures(cells("office"), [], "Latn")
        #expect(!latin.ligatures && !latin.kern)
        // Arabic needs its ligatures; emoji sequences are joined by them.
        #expect(shapingFeatures(cells("\u{644}\u{627}"), [], "Arab").ligatures)
        #expect(shapingFeatures(cells("a\u{1F469}\u{200D}\u{1F4BB}"), [], "Latn").ligatures)
        #expect(shapingFeatures(cells("12"), [], nil).ligatures)
    }

    @Test func onlyTheFirstCharacterOfABulletIsDrawn() throws {
        // "••" (seen in the wild) draws one dot in PowerPoint.
        for (char, glyphs) in [("\u{2022}\u{2022}", 1), ("\u{2022}", 1), ("-->", 1)] {
            var f = setup("One", 600, 300)
            f.body.paragraphs[0].props.bullet = .char(char: char)
            let l = f.lay(600, 300)
            let bullet = try #require(l.runs.first { $0.chars == (0, 0) })
            #expect(bullet.glyphs.count == glyphs, "\(char)")
        }
        // The first grapheme cluster is kept whole.
        #expect(mapSymbolBullet("e\u{301}x", nil) == "e\u{301}")
    }

    @Test func shrinkOnOverflow() {
        let text = (0 ..< 30).map { "Line number \($0)" }.joined(separator: "\n")
        let l = setup(text, 600, 200).lay(600, 200)
        #expect(l.fontScale < 1)
        #expect(!l.overflow || l.fontScale <= 0.11)
    }

    @Test func savedShrinkScaleIsDrawn() {
        // A file saved with fontScale 62.5% and lnSpcReduction 20% draws at that scale.
        var f = setup("Short", 600, 300)
        f.body.body.autofit = .shrink(fontScale: 0.625, lineReduction: 0.2)
        var l = f.lay(600, 300)
        #expect(l.fontScale == 0.625 && l.lineReduction == 0.2)
        let text = (0 ..< 30).map { "Line number \($0)" }.joined(separator: "\n")
        f = setup(text, 600, 200)
        f.body.body.autofit = .shrink(fontScale: 0.9, lineReduction: 0.1)
        l = f.lay(600, 200)
        #expect(l.fontScale == 0.9 && l.lineReduction == 0.1)
        f.body.body.autofit = .shrink(fontScale: 1, lineReduction: 0)
        l = f.lay(600, 200)
        #expect(l.fontScale < 0.9)
        // Nonsense saved values are ignored.
        f = setup("Short", 600, 300)
        f.body.body.autofit = .shrink(fontScale: .nan, lineReduction: 5)
        l = f.lay(600, 300)
        #expect(l.fontScale == 1 && l.lineReduction == 0.2)
    }

    @Test func bareNormAutofitDrawsAtFullSize() {
        let text = (0 ..< 30).map { "Line number \($0)" }.joined(separator: "\n")
        var f = setup(text, 600, 200)
        f.body.body.autofit = .shrink(fontScale: nil, lineReduction: 0)
        let l = f.lay(600, 200)
        #expect(l.fontScale == 1, "a body with no saved fontScale draws at 100%")
        #expect(l.overflow, "it overflows, as PowerPoint draws it")
    }

    @Test func exactLineSpacingEndsAtTheLastDescent() {
        var f = setup("One\nTwo", 600, 300)
        f.eachPara {
            $0.props.lineSpacing = .pts(26.59)
            $0.props.bullet = .none_
        }
        f.eachRun { $0.props.size = 12 }
        var l = f.lay(600, 300)
        let first = l.lines[0]
        #expect(near(first.baseline - first.top, 26.59 * 0.8))
        let short = (l.lines[1].bottom - l.lines[0].top) - l.contentHeight
        #expect(short > 1 && short < 26.59 * 0.2, "\(short)")
        f.eachPara { $0.props.lineSpacing = .pct(1) }
        l = f.lay(600, 300)
        #expect(near(l.contentHeight, l.lines[1].bottom - l.lines[0].top))
    }

    @Test func lineSpacingReductionComesOffThePercentage() throws {
        var f = setup("One\nTwo\nThree", 600, 400)
        for i in f.body.paragraphs.indices {
            f.body.paragraphs[i].props.lineSpacing = .pct(0.9)
            f.body.paragraphs[i].props.spaceBefore = .pts(10)
            f.body.paragraphs[i].props.bullet = .none_
            if i == 0 { f.body.paragraphs[i].runs[0].text += " wraps onto a second line because this paragraph is long enough to wrap in a narrow box" }
        }
        let ctx = try #require(f.ctx)
        let bp = Resolve.body(ctx, f.shape)
        let opts = TextOpts(rect: Rect(0, 0, 200, 400), noShrink: true)
        let full = TextLayoutEngine.layoutScaled(ctx, f.shape, f.body, bp, opts, 1, 0)
        let reduced = TextLayoutEngine.layoutScaled(ctx, f.shape, f.body, bp, opts, 1, 0.2)
        func pitch(_ l: TextLayout) -> Double { l.lines[1].top - l.lines[0].top }
        #expect(full.lines[1].para == 0 && reduced.lines[1].para == 0)
        #expect(abs(pitch(reduced) / pitch(full) - 0.7 / 0.9) < 0.005)
        func gap(_ l: TextLayout) -> Double {
            let k = l.lines.firstIndex { $0.para == 1 } ?? 1
            return l.lines[k].top - l.lines[k - 1].bottom
        }
        #expect(near(gap(full), 10, 1e-6) && near(gap(reduced), 10, 1e-6))
    }

    @Test func shrinkGivesUpAtOnceWhenEvenTheSmallestScaleOverflows() {
        let text = (0 ..< 400).map { "Line number \($0)" }.joined(separator: "\n")
        let f = setup(text, 100, 20)
        let counter = TextLayoutEngine.PassCounter()
        let l = TextLayoutEngine.$passCounter.withValue(counter) { f.lay(100, 20) }
        #expect(l.overflow && l.fontScale <= 0.11)
        #expect(counter.count.withLock { $0 } <= 2)
        // Text that fits somewhere in the range still gets the search.
        let l2 = setup((0 ..< 12).map { "Line number \($0)" }.joined(separator: "\n"), 600, 200).lay(600, 200)
        #expect(l2.fontScale > 0.11 && l2.fontScale < 1 && !l2.overflow)
    }

    @Test func spaceBeforeTheFirstParagraphWithSpcFirstLastPara() {
        var f = setup("One\nTwo", 600, 300)
        f.eachPara {
            $0.props.spaceBefore = .pts(10)
            $0.props.spaceAfter = .pts(6)
        }
        let plain = f.lay(600, 300)
        f.body.body.spaceFirstLast = true
        let both = f.lay(600, 300)
        #expect(near(both.lines[0].top - plain.lines[0].top, 10, 1e-6))
        #expect(near(both.contentHeight - plain.contentHeight, 16, 1e-6))
    }

    @Test func caretAndHitRoundtrip() throws {
        let l = setup("Hello world", 600, 100).lay(600, 100)
        for ch in 0 ... 11 {
            let pos = CaretPos(para: 0, ch: ch)
            let c = try #require(l.caret(pos))
            #expect(l.hit(Point(c.x + 0.1, (c.top + c.bottom) / 2)) == pos, "at \(ch)")
        }
        #expect(l.selectionRects(CaretPos(para: 0, ch: 0), CaretPos(para: 0, ch: 5)).count == 1)
    }

    @Test func compositionIsUnderlinedPerLine() throws {
        var l = setup("Hello 한국어 world", 600, 100).lay(600, 100)
        let (a, b) = (CaretPos(para: 0, ch: 6), CaretPos(para: 0, ch: 9))
        let u = l.compositionUnderlines(a, b)
        try #require(u.count == 1)
        let (x0, x1, y) = u[0]
        let cx0 = try #require(l.caret(a)).x
        let cx1 = try #require(l.caret(b)).x
        #expect(near(x0, cx0) && near(x1, cx1))
        let line = l.lines[0]
        #expect(y > line.baseline && y <= line.bottom)
        #expect(l.compositionUnderlines(b, a).map { [$0.0, $0.1, $0.2] } == u.map { [$0.0, $0.1, $0.2] })
        #expect(l.compositionUnderlines(a, a).isEmpty)
        // Wrapped: one underline per line.
        l = setup("가나다라마바사아자차카타파하 가나다라마바사아자차카타파하 가나다라마바사", 120, 400).lay(120, 400)
        #expect(l.lines.count >= 2)
        let w = l.compositionUnderlines(CaretPos(para: 0, ch: 0), CaretPos(para: 0, ch: 40))
        #expect(w.count >= 2)
        #expect(zip(w, w.dropFirst()).allSatisfy { $1.2 > $0.2 })
        _ = l.compositionUnderlines(CaretPos(para: 3, ch: 0), CaretPos(para: 9, ch: 99))
    }

    @Test func alignmentCenterAndRight() {
        var f = setup("Hi", 400, 100)
        f.body.paragraphs[0].props.align = .center
        f.body.paragraphs[0].props.bullet = .none_
        let c = f.lay(400, 100)
        f.body.paragraphs[0].props.align = .right
        let r = f.lay(400, 100)
        let cx = c.lines[0].caretX[0]
        let rx = r.lines[0].caretX[0]
        #expect(rx > cx && cx > 100, "center \(cx) right \(rx)")
    }

    @Test func emptyAndHostileBodiesNeverCrash() {
        var f = setup("", 10, 10)
        _ = f.lay(10, 10)
        _ = f.lay(0, 0)
        var para = Paragraph(runs: [Run("\t\u{0B}\u{0B}🙂 ﷽ 日本語"), Run(text: "", props: RunProps(), kind: .break)])
        para.props.marginLeft = -50
        para.props.indent = .nan
        para.props.lineSpacing = .pct(-3)
        f.body.paragraphs = [para]
        f.body.body.columns = 1000
        let l = f.lay(50, 50)
        _ = l.hit(Point(-100, 1e9))
        _ = l.caret(CaretPos(para: 99, ch: 99))
        _ = l.selectionRects(CaretPos(para: 5, ch: 0), CaretPos(para: 0, ch: 3))
    }

    @Test func autonumFormats() {
        #expect(autonum("arabicPeriod", 3) == "3.")
        #expect(autonum("romanUcPeriod", 4) == "IV.")
        #expect(autonum("alphaLcParenR", 2) == "b)")
        #expect(autonum("arabicParenBoth", 1) == "(1)")
        #expect(autonum("alphaUcPeriod", 27) == "AA.")
        #expect(autonum("alphaUcPeriod", .max).count == 51)
    }

    @Test func numberedListCounts() {
        var f = setup("a\nb\nc", 400, 300)
        f.eachPara { $0.props.bullet = .autoNum(scheme: "arabicPeriod", startAt: 1) }
        #expect(f.lay(400, 300).runs.count >= 6)
    }

    /// Width of `word` laid out in a run with `baseline` (0 = normal, 0.3 = superscript …).
    func runWidth(_ word: String, _ baseline: Double?) -> Double {
        var r = run(word, size: 24)
        r.props.baseline = baseline
        let line = bidiSetup([r], 2000, false, .left).lay(2000, 300).lines[0]
        return (line.caretX.last ?? 0) - (line.caretX.first ?? 0)
    }

    @Test func superscriptAndSubscriptAdvanceAtTheirDrawnSize() {
        let normal = runWidth("superscript", nil)
        for b in [0.3, -0.25] {
            let w = runWidth("superscript", b)
            #expect(abs(w / normal - subSuper) < 0.02, "\(b): \(w) vs \(normal)")
        }
    }

    @Test func superscriptGlyphsSitInsideTheirCells() throws {
        var r = run("super", size: 24)
        r.props.baseline = 0.3
        let l = bidiSetup([r], 2000, false, .left).lay(2000, 300)
        let line = l.lines[0]
        let gr = try #require(l.runs.first { !$0.cells.isEmpty })
        #expect(near(gr.size, 24 * subSuper, 1e-6))
        for (g, c) in zip(gr.glyphs, gr.cells) {
            let e = line.edges[c.index - line.start]
            #expect(g.x >= e.left - 0.01 && g.x < e.right)
        }
    }

    /// A wrapping numbered paragraph with `marL` and `indent`: (bullet x, first line's text x, second's).
    func hanging(_ margin: Double, _ indent: Double, _ bullet: Bullet) -> (Double?, Double, Double) {
        var f = setup("Wrapping words go on and on so the paragraph needs at least two or three lines here", 300, 300)
        f.body.paragraphs[0].props.bullet = bullet
        f.body.paragraphs[0].props.marginLeft = margin
        f.body.paragraphs[0].props.indent = indent
        let l = f.lay(300, 300)
        guard l.lines.count >= 2 else { return (nil, 0, 0) }
        let bx = l.runs.first { $0.cells.isEmpty && !$0.glyphs.isEmpty }?.glyphs[0].x
        return (bx, l.lines[0].caretX[0], l.lines[1].caretX[0])
    }

    @Test func aHangPastTheBoxEdgeKeepsItsWidthOnTheFirstLine() {
        let num = Bullet.autoNum(scheme: "arabicPeriod", startAt: 1)
        var (bx, first, rest) = hanging(0, -36, num)
        #expect(near(first - rest, 36, 0.5))
        #expect(near(bx ?? -1, rest, 0.5))
        (bx, first, rest) = hanging(18, -54, num)
        #expect(near(first - rest, 36, 0.5))
        #expect(near(rest - (bx ?? -1), 18, 0.5))
        (_, first, rest) = hanging(0, -36, .char(char: "•"))
        #expect(near(first - rest, 36, 0.5))
        (_, first, rest) = hanging(0, -36, .none_)
        #expect(near(first, rest, 0.5))
    }

    @Test func anOrdinaryHangStillPutsTheTextAtTheMargin() {
        let (bx, first, rest) = hanging(36, -36, .autoNum(scheme: "arabicPeriod", startAt: 1))
        #expect(near(first, rest, 0.5))
        #expect(near(rest - (bx ?? -1), 36, 0.5))
    }

    @Test func singleSpacedLinesAre12TimesTheSizeApartWhateverTheFont() {
        for size in [18.0, 40.0] {
            var f = bidiSetup([run("HHH", size: size)], 2000, false, .left)
            f.body.body.autofit = .none_
            let second = f.body.paragraphs[0]
            f.body.paragraphs += [second, second]
            f.eachPara {
                $0.props.lineSpacing = .pct(1)
                $0.props.spaceBefore = .pts(0)
                $0.props.spaceAfter = .pts(0)
            }
            let l = f.lay(2000, 600)
            #expect(l.lines.count == 3)
            for line in l.lines { #expect(near(line.bottom - line.top, size * linePitch, 1e-6)) }
            let face = l.runs[0].face
            #expect(near(l.lines[0].baseline - l.lines[0].top, size * linePitch * face.lineSplit, 1e-6))
        }
    }

    @Test func aWordDoesNotBreakAfterASlashOrBackslash() {
        for sep in ["/", "\\"] {
            let text = ["alpha", "beta", "gamma", "delta", "epsilon"].joined(separator: sep)
            let lines = wrapped(text, oneLine(text) * 0.6)
            #expect(lines.count >= 2)
            #expect((lines.first?.count ?? 0) > "alpha/beta".count, "\(lines)")
        }
        let text = "alpha/beta/gamma/delta/epsilon"
        let lines = wrapped(text, oneLine(text) * 0.6) { $0.latinLineBreak = true }
        #expect(lines.first?.hasSuffix("/") ?? false, "\(lines)")
        let h = wrapped("alpha-beta-gamma-delta-epsilon", oneLine("alpha-beta-gamma-") + 1)
        #expect(h.first == "alpha-beta-gamma-")
    }

    @Test func koreanWrapsBetweenWords() {
        let lines = wrapped("한국어 안녕하세요 반갑습니다 감사합니다", oneLine("한국어 안녕하세요 반") + 0.5)
        #expect(lines.map { String($0.reversed().drop { $0 == " " }.reversed()) } == ["한국어 안녕하세요", "반갑습니다", "감사합니다"], "\(lines)")
        let ja = wrapped("日本語の文章は空白なしで続きます", oneLine("日本語の文章") + 0.5)
        #expect(ja.first == "日本語の文章")
    }

    @Test func closingPunctuationHangsPastTheEndWithHangingPunct() {
        let text = "白なしで続きます。句読点も含めて。"
        let w = oneLine("白なしで続きます") + 0.5
        #expect(wrapped(text, w) { $0.hangingPunct = true }.first == "白なしで続きます。")
        #expect(wrapped(text, w) { $0.hangingPunct = false }.first == "白なしで続きま")
    }

    @Test func smallKanaAndClosingBracketsFollowPowerPointKinsoku() {
        let w = oneLine("あいうえお") + 0.5
        for (text, first) in [("あいうえおっかき", "あいうえ"), ("あいうえおーかき", "あいうえ"), ("あいうえおかき", "あいうえお")] {
            #expect(wrapped(text, w) { $0.hangingPunct = true }.first == first, "\(text)")
        }
        let w2 = oneLine("あいうえ「。") + 0.5
        #expect(wrapped("あいうえ「。」かき", w2) { $0.hangingPunct = true }.first == "あいうえ")
    }

    @Test func noBreakAfterAZeroWidthSpaceOrBeforeAnEmDash() {
        var (allowed, _) = breakOpportunities(Array("ab\u{200B}cd".unicodeScalars), false)
        #expect(!allowed[3])
        (allowed, _) = breakOpportunities(Array("ab\u{2014}cd".unicodeScalars), false)
        #expect(!allowed[2] && allowed[3])
    }

    @Test func aLineBrokenAtASoftHyphenShowsAHyphen() throws {
        var f = setup("Soft\u{AD}hyphenated\u{AD}words", 150, 300)
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].runs[0].props.size = 24
        let l = f.lay(150, 300)
        #expect(l.lines.count >= 2)
        let first = l.lines[0]
        let shy = first.end - 1
        try #require(first.end == 5, "\(l.lines.map { ($0.start, $0.end) })")
        let e = first.edges[shy - first.start]
        #expect(e.right - e.left > 2)
        let r = try #require(l.runs.first { $0.cells.contains { $0.index == shy } })
        let gi = try #require(r.cells.firstIndex { $0.index == shy })
        #expect(r.glyphs[gi].gid == r.face.glyph(for: "-"))
        let ends = l.lines.map { $0.end - 1 }
        for r in l.runs {
            for (g, c) in zip(r.glyphs, r.cells) {
                #expect(c.char != "\u{AD}" || ends.contains(c.index) || g.gid != r.face.glyph(for: "-"))
            }
        }
        let wide = f.lay(2000, 300)
        #expect(wide.lines.count == 1)
        #expect(wide.runs.allSatisfy { r in r.cells.allSatisfy { $0.char != "\u{AD}" || r.glyphs.allSatisfy { $0.gid != r.face.glyph(for: "-") } } })
    }

    @Test func autonumberSchemesFollowPowerPoint() {
        let cases: [(String, UInt32, String)] = [
            ("ea1ChsPlain", 4, "四"), ("ea1ChsPeriod", 10, "十．"), ("ea1ChtPeriod", 21, "二十一．"), ("ea1JpnKorPeriod", 10, "一〇．"),
            ("ea1JpnChsDbPeriod", 13, "一三．"), ("arabicDbPlain", 10, "１０"), ("arabicDbPeriod", 13, "１３．"), ("circleNumDbPlain", 13, "⑬"),
            ("circleNumWdWhitePlain", 13, "③"), ("circleNumWdBlackPlain", 2, "❷"), ("thaiAlphaPeriod", 1, "ก."), ("thaiAlphaParenR", 4, "ง)"),
            ("thaiAlphaParenBoth", 7, "(ช)"), ("thaiNumPeriod", 10, "๑๐."), ("hindiAlphaPeriod", 4, "ई."), ("hindiAlpha1Period", 1, "क."),
            ("hindiNumParenR", 13, "१३)"), ("hebrew2Minus", 1, "א-"), ("arabic1Minus", 13, "ش-"), ("arabic2Minus", 10, "ي-"), ("arabicPlain", 10, "10"),
        ]
        for (scheme, n, want) in cases { #expect(autonum(scheme, n) == want, "\(scheme) \(n)") }
        #expect(chineseNum(105) == "一百零五")
        #expect(chineseNum(20) == "二十")
        #expect(autonum("hebrew2Minus", 23) == "אא-")
        #expect(autonum("thaiAlphaPeriod", 0) == ".")
    }

    @Test func emptyNumberedParagraphPreviewsTheNextNumberWithoutConsumingIt() throws {
        var f = setup("One\n\nTwo", 600, 300)
        f.eachPara { $0.props.bullet = .autoNum(scheme: "arabicPeriod", startAt: 4) }
        let l = f.lay(600, 300)
        let preview = try #require(l.emptyBullets.first)
        let next = try #require(l.runs.first { $0.para == 2 && $0.cells.isEmpty })
        #expect(preview.para == 1)
        #expect(preview.glyphs.map(\.gid) == next.glyphs.map(\.gid), "both should use 5.")
        #expect(preview.glyphs.map(\.gid) == measureStr(preview.face, preview.size, "5.").glyphs.map(\.gid))
    }

    @Test func emptyPlainParagraphsAndSoftBreaksHaveNoBulletPreview() {
        var f = setup("", 600, 300)
        f.body.paragraphs[0].props.bullet = .none_
        #expect(f.lay(600, 300).emptyBullets.isEmpty)
        f.body = TextBody.fromText("First")
        var b = f.body
        TextEdit.insert(&b, (0, 5), "\u{0B}")
        f.body = b
        let l = f.lay(600, 300)
        #expect(l.lines.count == 2)
        #expect(l.emptyBullets.isEmpty, "a soft line break is not a new list item")
    }

    @Test func emptyBulletsReserveTheTypedIndentWithoutBecomingContent() throws {
        for rtl in [false, true] {
            for level: UInt8 in [0, 1, 2] {
                var f = setup("First\n", 600, 300)
                f.eachPara {
                    $0.level = level
                    $0.props.rtl = rtl
                    $0.props.align = rtl ? .right : .left
                }
                let empty = f.lay(600, 300)
                try #require(empty.emptyBullets.count == 1)
                #expect(empty.emptyBullets[0].para == 1)
                #expect(empty.runs.allSatisfy { $0.para == 0 })
                let caret = try #require(empty.caret(CaretPos(para: 1, ch: 0)))
                let bx = empty.emptyBullets[0].glyphs[0].x
                #expect(rtl ? bx >= caret.x : bx < caret.x)
                var b = f.body
                TextEdit.insert(&b, (1, 0), rtl ? "אבג" : "Next")
                f.body = b
                let typed = f.lay(600, 300)
                #expect(typed.emptyBullets.isEmpty)
                let after = try #require(typed.caret(CaretPos(para: 1, ch: 0)))
                #expect(near(caret.x, after.x, 1e-6) && near(caret.top, after.top, 1e-6) && near(caret.bottom, after.bottom, 1e-6))
            }
        }
    }

    func sizedBreak(_ size: Double) -> Run {
        var r = Run(text: "", props: RunProps(), kind: .break)
        r.props.size = size
        return r
    }

    func oneLineHeight(_ f: inout Fixture, _ size: Double) -> Double {
        f.body.paragraphs = [Paragraph(runs: [run("X", size: size)])]
        let l = f.lay(400, 400)
        return l.lines[0].bottom - l.lines[0].top
    }

    @Test func anEmptyLineIsSizedByTheBreakThatEndsIt() throws {
        var f = setup("x", 400, 400)
        let (h10, h40, h60, h20) = (oneLineHeight(&f, 10), oneLineHeight(&f, 40), oneLineHeight(&f, 60), oneLineHeight(&f, 20))
        f.body.paragraphs = [Paragraph(runs: [run("A1", size: 40), sizedBreak(40), sizedBreak(10), run("A2", size: 40)])]
        let a = f.lay(400, 400)
        try #require(a.lines.count == 3)
        let emptyA = a.lines[2].top - a.lines[1].top
        #expect(near(emptyA, h10, 0.5) && !near(emptyA, h40, 1))
        f.body.paragraphs = [Paragraph(runs: [run("C1", size: 20), sizedBreak(20), sizedBreak(60), run("C2", size: 20)])]
        let c = f.lay(400, 400)
        let emptyC = c.lines[2].top - c.lines[1].top
        #expect(near(emptyC, h60, 0.5) && !near(emptyC, h20, 1))
    }

    @Test func anEmptyLastLineIsSizedByTheParagraphMark() throws {
        var f = setup("x", 400, 400)
        let (h10, h40) = (oneLineHeight(&f, 10), oneLineHeight(&f, 40))
        var para = Paragraph(runs: [run("B1", size: 40), sizedBreak(40)])
        para.endProps.size = 10
        f.body.paragraphs = [para]
        let l = f.lay(400, 400)
        try #require(l.lines.count == 2)
        let h = l.lines[1].bottom - l.lines[1].top
        #expect(near(h, h10, 0.5) && !near(h, h40, 1))
    }

    @Test func anEmptyParagraphKeepsItsParagraphMarkHeight() throws {
        var f = setup("x", 400, 400)
        let h10 = oneLineHeight(&f, 10)
        var empty = Paragraph()
        empty.endProps.size = 10
        f.body.paragraphs = [Paragraph(runs: [run("D1", size: 40)]), empty, Paragraph(runs: [run("D2", size: 40)])]
        let l = f.lay(400, 400)
        try #require(l.lines.count == 3)
        #expect(near(l.lines[1].bottom - l.lines[1].top, h10, 0.5))
    }
}
