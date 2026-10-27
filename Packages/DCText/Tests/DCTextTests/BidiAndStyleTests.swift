// DCTextTests — bidirectional text and Arabic typography, symbol fonts, capitals, decorations, tabs,
// vertical text, columns and anchoring. Port of deckcraft crates/text/src/tests.rs (MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors). Tests that need a font this machine lacks return early,
// as deckcraft's do.
import DCColor
import DCGeometry
import DCModel
@testable import DCText
import Testing

let mixed = "سنة 2024 (Retrait) فقط"

@Suite struct BidiTests {
    @Test func rtlMixedStringIsReorderedPerLine() throws {
        // An Arabic run: its digits and brackets go with the right-to-left text.
        let l = bidiSetup([run(mixed, lang: "ar-SA")], 2000, true, .right).lay(2000, 300)
        try #require(l.lines.count == 1)
        let line = l.lines[0]
        #expect(line.rtl)
        let n = mixed.unicodeScalars.count
        #expect(line.edges.count == n && line.caretX.count == n + 1)
        func mid(_ k: Int) -> Double { (line.edges[k].left + line.edges[k].right) / 2 }
        #expect(mid(0) > mid(4) && mid(4) > mid(10) && mid(10) > mid(19))
        #expect(mid(0) > mid(1) && mid(1) > mid(2))
        #expect(mid(4) < mid(5) && mid(5) < mid(7))
        #expect(mid(10) < mid(16))
        #expect(mid(9) > mid(16) && mid(17) < mid(10))
        #expect(near(line.extent.right, l.inner.x1, 0.5))
        #expect(near(line.caretX[0], line.extent.right))
        #expect(line.levels[0] == 1 && line.levels[4] == 2 && line.levels[10] == 2)
    }

    @Test func anEnglishRunKeepsDigitsAndBracketsLeftToRight() {
        let line = bidiSetup([Run(mixed)], 2000, true, .right).lay(2000, 300).lines[0]
        func mid(_ k: Int) -> Double { (line.edges[k].left + line.edges[k].right) / 2 }
        #expect(mid(0) > mid(10))
        #expect(mid(4) < mid(10))
        #expect(mid(9) < mid(10) && mid(17) > mid(16))
        #expect(mid(19) < mid(4))
    }

    @Test func rtlParagraphStartsAtTheRightWithTheBulletOutside() throws {
        var f = bidiSetup([Run("مرحبا بكم")], 400, true, .right)
        f.body.paragraphs[0].props.bullet = .char(char: "•")
        f.body.paragraphs[0].props.marginLeft = 36
        f.body.paragraphs[0].props.indent = -36
        var l = f.lay(400, 300)
        let line = l.lines[0]
        let s = l.inner.x1
        #expect(near(line.extent.right, s - 36, 0.5))
        let bx = try #require(l.runs.first { $0.chars == (0, 0) }).glyphs[0].x
        #expect(bx > line.extent.right - 0.5 && bx < s)
        f.body.paragraphs[0].props.rtl = false
        f.body.paragraphs[0].props.align = .left
        l = f.lay(400, 300)
        #expect(try #require(l.runs.first { $0.chars == (0, 0) }).glyphs[0].x < l.lines[0].extent.left)
    }

    @Test func rtlLeftAndCenterAlignment() {
        var l = bidiSetup([Run("سلام")], 400, true, .left).lay(400, 300)
        #expect(near(l.lines[0].extent.left, l.inner.x0, 0.5))
        l = bidiSetup([Run("سلام")], 400, true, .center).lay(400, 300)
        #expect(near((l.lines[0].extent.left + l.lines[0].extent.right) / 2, (l.inner.x0 + l.inner.x1) / 2, 0.5))
    }

    @Test func bidiCaretStopsRoundTripThroughHitTesting() throws {
        for rtl in [true, false] {
            let l = bidiSetup([Run(mixed)], 2000, rtl, rtl ? .right : .left).lay(2000, 300)
            let line = l.lines[0]
            for (x, ch, aff) in line.visualStops() {
                let c = try #require(l.caretAt(CaretPos(para: 0, ch: ch), aff))
                #expect(near(c.x, x), "stop \(ch) \(aff)")
            }
            for (a, b) in line.graphemes() {
                guard let (x0, x1) = line.graphemeBox(a, b), x1 - x0 >= 1 else { continue }
                let y = (line.top + line.bottom) / 2
                for x in [x0 + 0.2, x1 - 0.2] {
                    let (pos, aff) = l.hitAffinity(Point(x, y))
                    let c = try #require(l.caretAt(pos, aff))
                    #expect(near(c.x, x < (x0 + x1) / 2 ? x0 : x1), "rtl=\(rtl) grapheme \(a)")
                }
            }
        }
    }

    @Test func visualMovementWalksTheLineLeftToRight() throws {
        let l = bidiSetup([Run(mixed)], 2000, true, .right).lay(2000, 300)
        let stops = l.lines[0].visualStops()
        var (pos, aff) = (CaretPos(para: 0, ch: stops[0].1), stops[0].2)
        var xs = [stops[0].0]
        for _ in 0 ..< 200 {
            let (np, na) = l.moveCaret(pos, aff, forward: true, .visual)
            if np == pos && na == aff { break }
            (pos, aff) = (np, na)
            xs.append(try #require(l.caretAt(pos, aff)).x)
        }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 > $0 }, "\(xs)")
        #expect(near(xs.last ?? 0, l.lines[0].extent.right))
        #expect(l.moveCaret(pos, aff, forward: true, .visual).0 == pos)
        #expect(l.moveCaret(CaretPos(para: 0, ch: 0), .downstream, forward: false, .visual).0.ch == 1)
    }

    @Test func logicalMovementStepsOverHarakat() {
        let l = bidiSetup([Run("\u{0628}\u{064E}\u{062A}")], 400, true, .right).lay(400, 300)
        let (n1, _) = l.moveCaret(CaretPos(para: 0, ch: 0), .downstream, forward: true, .logical)
        #expect(n1.ch == 2)
        #expect(l.moveCaret(n1, .downstream, forward: false, .logical).0.ch == 0)
        #expect(l.lines[0].visualStops().allSatisfy { $0.1 != 1 })
    }

    @Test func selectionIsTheUnionOfVisualBoxes() {
        let l = bidiSetup([Run("ab سنة cd")], 2000, false, .left).lay(2000, 300)
        #expect(l.selectionRects(CaretPos(para: 0, ch: 1), CaretPos(para: 0, ch: 5)).count == 2)
        #expect(l.selectionRects(CaretPos(para: 0, ch: 0), CaretPos(para: 0, ch: 9)).count == 1)
    }

    @Test func paintOnlyStyleChangesKeepArabicJoining() throws {
        // Paint-only attributes (colour) never split an item, so the word is shaped whole either way.
        let face = try #require(arabicFace(), "no Arabic face available")
        func glyphs(_ runs: [Run]) -> [UInt32] {
            let l = bidiSetup(runs, 400, true, .right).lay(400, 300)
            return l.runs.flatMap { r in r.glyphs.map { ($0.gid, $0.x) } }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        let word = "سنة"
        let whole = glyphs([Run(word)])
        var red = Run("سن")
        red.props.fill = .solid(color: ColorRef.rgb(Rgba.fromHex("C00000") ?? .black))
        #expect(whole == glyphs([red, Run("ة")]), "a colour change inside a word keeps the joined forms")
        #expect(Array(whole.reversed()) != word.unicodeScalars.map { face.glyph(for: $0) })
    }

    @Test func justLowStretchesArabicWithKashida() throws {
        try #require(arabicFace() != nil, "no Arabic face available")
        func tatweels(_ l: TextLayout) -> Int {
            l.runs.map { r in
                let tg = r.face.glyph(for: "\u{0640}")
                return tg == 0 ? 0 : r.glyphs.filter { $0.gid == tg }.count
            }.reduce(0, +)
        }
        let text = "بسم الله الرحمن الرحيم نستعين به ونستغفره ونتوب إليه"
        var l = bidiSetup([Run(text)], 220, true, .justLow).lay(220, 600)
        #expect(l.lines.count >= 2)
        let first = l.lines[0]
        #expect(near(first.extent.right - first.extent.left, l.inner.width, 0.5))
        guard !l.runs.allSatisfy({ $0.face.glyph(for: "\u{0640}") == 0 }) else { return }
        #expect(tatweels(l) > 0, "kashida drawn")
        #expect(near(l.lines.last?.extent.right ?? 0, l.inner.x1, 0.5))
        l = bidiSetup([Run(text)], 220, true, .justify).lay(220, 600)
        #expect(tatweels(l) == 0)
    }

    @Test func wrappedRTLLinesBreakInLogicalOrder() {
        let text = "واحد اثنان ثلاثة أربعة خمسة ستة سبعة ثمانية تسعة عشرة"
        let l = bidiSetup([Run(text)], 160, true, .right).lay(160, 600)
        #expect(l.lines.count >= 2)
        #expect(l.lines[0].start == 0)
        for (a, b) in zip(l.lines, l.lines.dropFirst()) { #expect(b.start >= a.end) }
        for line in l.lines {
            #expect(line.extent.left >= l.inner.x0 - 0.5)
            #expect(near(line.extent.right, l.inner.x1, 0.5))
        }
        #expect(l.lineOf(CaretPos(para: 0, ch: l.lines[0].end), .upstream) == 0)
    }

    @Test func hostileBidiInputNeverCrashes() {
        let nasty = String(repeating: "\u{202B}", count: 200) + "\t\u{0B}\u{202E}abc\u{2069}" + String(repeating: "\u{2067}", count: 130)
            + "(]))[ ١٢٣ \u{0640}\u{064E}\u{064E}\u{200D}"
        for rtl in [true, false] {
            for align: Align in [.left, .right, .center, .justify, .justLow, .distributed] {
                let l = bidiSetup([Run(nasty), Run(mixed)], 60, rtl, align).lay(60, 60)
                for line in l.lines {
                    #expect(line.caretX.count == line.end - line.start + 1)
                    #expect(line.edges.count == line.end - line.start)
                }
                _ = l.hitAffinity(Point(-1e9, 1e9))
                _ = l.selectionRects(CaretPos(para: 0, ch: 0), CaretPos(para: 0, ch: 9999))
                var pos = (CaretPos(para: 0, ch: 0), Affinity.downstream)
                for i in 0 ..< 50 { pos = l.moveCaret(pos.0, pos.1, forward: i % 3 != 0, i % 2 == 0 ? .visual : .logical) }
                _ = l.caretAt(CaretPos(para: 7, ch: 7), .upstream)
            }
        }
    }
}

@Suite struct StyleTests {
    @Test func emojiTakeAColourFaceWhenOneIsInstalled() throws {
        guard db.cascade(["😀"], [], "Regular").isColor else { return }
        for s in ["😀", "👍🏽", "❤\u{FE0F}", "👨\u{200D}👩\u{200D}👧"] {
            let l = bidiSetup([Run("a\(s)b")], 2000, false, .left).lay(2000, 300)
            let emoji = try #require(l.runs.first { $0.cells.contains { !$0.char.isASCII } })
            #expect(emoji.face.isColor, "\(s) drawn with \(emoji.face.family)")
            #expect(l.runs.filter { $0.cells.allSatisfy { $0.char.isASCII } }.allSatisfy { !$0.face.isColor })
        }
    }

    @Test func aBulletTheTextFontLacksFallsBackToAFaceThatHasIt() {
        guard db.cascade(["①"], [], "Regular").covers("①") else { return }
        var f = setup("One\nTwo", 600, 300)
        f.eachPara { $0.props.bullet = .autoNum(scheme: "circleNumDbPlain", startAt: 1) }
        let bullets = f.lay(600, 300).runs.filter { $0.cells.isEmpty }
        #expect(bullets.count == 2)
        for b in bullets {
            #expect(b.face.covers("①"), "drawn with \(b.face.family)")
            #expect(b.glyphs.allSatisfy { $0.gid != 0 })
        }
    }

    @Test func symbolFontBulletsMapByFont() {
        #expect(mapSymbolBullet("\u{F0EA}", "Wingdings 2") == "★")
        #expect(mapSymbolBullet("\u{7D}", "Wingdings 3") == "►")
        #expect(mapSymbolBullet("\u{F0A7}", "Wingdings") == "▪")
        #expect(mapSymbolBullet("•", "Arial") == "•")
        #expect(isSymbolFont("Wingdings 2") && isSymbolFont("Symbol") && !isSymbolFont("Arial"))
    }

    @Test func anInstalledSymbolFontDrawsItsOwnBullet() {
        guard db.hasFamily("Wingdings 2") else { return }
        let face = db.face("Wingdings 2", "Regular")
        #expect(symbolFontChar(face, "\u{EA}", "Wingdings 2") == "\u{F0EA}")
        #expect(symbolFontChar(face, "\u{EA}", "Arial") == nil)
    }

    @Test func symbolFontCharKeepsCoveredNonSymbolBullets() {
        guard db.hasFamily("Symbol") else { return }
        let face = db.face("Symbol", "Regular")
        guard face.covers("•") else { return }
        #expect(symbolFontChar(face, "•", "Symbol") == "•")
        #expect(symbolFontChar(face, "\u{F0DE}", "Symbol") == symbolFontDraw(face, 0xDE))
    }

    @Test func symbolCharMapsSymbolFontCodes() {
        let face = db.face("Inter", "Regular")
        #expect(symbolChar(face, "Arial", "n") == nil)
        #expect(symbolChar(face, "Webdings", "n") == "\u{25CF}")
        #expect(symbolChar(face, "Webdings", "\u{F06E}") == "\u{25CF}")
        #expect(symbolChar(face, "Wingdings", "\u{F06E}") == "\u{25A0}")
        #expect(symbolChar(face, "Wingdings", "\u{100}") == nil)
    }

    @Test func symbolFontRemapsPrivateUseToRealUnicode() {
        guard db.hasFamily("Symbol") else { return }
        let face = db.face("Symbol", "Regular")
        let drawn = symbolFontDraw(face, 0xDE)
        #expect(drawn == (face.covers("\u{F0DE}") ? "\u{F0DE}" : "\u{21D2}"))
    }

    @Test func symbolFontDrawFallsBackToASCII() {
        guard db.hasFamily("Symbol") else { return }
        let face = db.face("Symbol", "Regular")
        for code: UInt32 in [0x3C, 0x3D, 0x3E, 0x3F, 0x31, 0x28, 0x30, 0x2B] {
            let pua = Unicode.Scalar(0xF000 | code)!
            let ascii = Unicode.Scalar(code)!
            let drawn = symbolFontDraw(face, code)
            if face.covers(pua) {
                #expect(drawn == pua)
            } else if face.covers(ascii) {
                #expect(drawn == ascii)
            } else {
                #expect(drawn == nil)
            }
        }
    }

    @Test func symbolFontDrawTriesAppleAlternatives() {
        guard db.hasFamily("Symbol") else { return }
        let face = db.face("Symbol", "Regular")
        for (code, adobe, alt): (UInt32, Unicode.Scalar, Unicode.Scalar) in [(0xA4, "\u{2215}", "\u{2044}"), (0xE1, "\u{2329}", "\u{3008}"), (0xF1, "\u{232A}", "\u{3009}")] {
            let pua = Unicode.Scalar(0xF000 | code)!
            let drawn = symbolFontDraw(face, code)
            if face.covers(pua) {
                #expect(drawn == pua)
            } else if face.covers(adobe) {
                #expect(drawn == adobe)
            } else {
                #expect(drawn == alt)
            }
        }
    }

    @Test func symbolUnicodeMapsTheEuroAndTheAppleAlternatives() {
        #expect(symbolUnicode(0xA0) == 0x20AC)
        #expect(symbolUnicodeAlts(0xA4) == [0x2044] && symbolUnicodeAlts(0xE1) == [0x3008] && symbolUnicodeAlts(0xF1) == [0x3009])
        #expect(symbolUnicodeAlts(0x44).isEmpty && symbolUnicodeAlts(0x57).isEmpty && symbolUnicodeAlts(0x6D).isEmpty)
    }

    @Test func symbolUnicodeTableCoversTheAdobeEncoding() {
        // (code, real Unicode) from unicode.org/Public/MAPPINGS/VENDORS/ADOBE/symbol.txt, typed separately
        // from the table under test.
        let table: [(UInt32, UInt32)] = [
            (0x22, 0x2200), (0x24, 0x2203), (0x27, 0x220B), (0x2A, 0x2217), (0x2D, 0x2212), (0x40, 0x2245), (0x5C, 0x2234), (0x5E, 0x22A5),
            (0x7E, 0x223C), (0x41, 0x0391), (0x42, 0x0392), (0x43, 0x03A7), (0x44, 0x0394), (0x45, 0x0395), (0x46, 0x03A6), (0x47, 0x0393),
            (0x48, 0x0397), (0x49, 0x0399), (0x4A, 0x03D1), (0x4B, 0x039A), (0x4C, 0x039B), (0x4D, 0x039C), (0x4E, 0x039D), (0x4F, 0x039F),
            (0x50, 0x03A0), (0x51, 0x0398), (0x52, 0x03A1), (0x53, 0x03A3), (0x54, 0x03A4), (0x55, 0x03A5), (0x56, 0x03C2), (0x57, 0x03A9),
            (0x58, 0x039E), (0x59, 0x03A8), (0x5A, 0x0396), (0x61, 0x03B1), (0x62, 0x03B2), (0x63, 0x03C7), (0x64, 0x03B4), (0x65, 0x03B5),
            (0x66, 0x03C6), (0x67, 0x03B3), (0x68, 0x03B7), (0x69, 0x03B9), (0x6A, 0x03D5), (0x6B, 0x03BA), (0x6C, 0x03BB), (0x6D, 0x03BC),
            (0x6E, 0x03BD), (0x6F, 0x03BF), (0x70, 0x03C0), (0x71, 0x03B8), (0x72, 0x03C1), (0x73, 0x03C3), (0x74, 0x03C4), (0x75, 0x03C5),
            (0x76, 0x03D6), (0x77, 0x03C9), (0x78, 0x03BE), (0x79, 0x03C8), (0x7A, 0x03B6), (0xA0, 0x20AC), (0xA1, 0x03D2), (0xA2, 0x2032),
            (0xA3, 0x2264), (0xA4, 0x2215), (0xA5, 0x221E), (0xA6, 0x0192), (0xA7, 0x2663), (0xA8, 0x2666), (0xA9, 0x2665), (0xAA, 0x2660),
            (0xAB, 0x2194), (0xAC, 0x2190), (0xAD, 0x2191), (0xAE, 0x2192), (0xAF, 0x2193), (0xB0, 0x00B0), (0xB1, 0x00B1), (0xB2, 0x2033),
            (0xB3, 0x2265), (0xB4, 0x00D7), (0xB5, 0x221D), (0xB6, 0x2202), (0xB7, 0x2022), (0xB8, 0x00F7), (0xB9, 0x2260), (0xBA, 0x2261),
            (0xBB, 0x2248), (0xBC, 0x2026), (0xBF, 0x21B5), (0xC0, 0x2135), (0xC1, 0x2111), (0xC2, 0x211C), (0xC3, 0x2118), (0xC4, 0x2297),
            (0xC5, 0x2295), (0xC6, 0x2205), (0xC7, 0x2229), (0xC8, 0x222A), (0xC9, 0x2283), (0xCA, 0x2287), (0xCB, 0x2284), (0xCC, 0x2282),
            (0xCD, 0x2286), (0xCE, 0x2208), (0xCF, 0x2209), (0xD0, 0x2220), (0xD1, 0x2207), (0xD5, 0x220F), (0xD6, 0x221A), (0xD7, 0x22C5),
            (0xD8, 0x00AC), (0xD9, 0x2227), (0xDA, 0x2228), (0xDB, 0x21D4), (0xDC, 0x21D0), (0xDD, 0x21D1), (0xDE, 0x21D2), (0xDF, 0x21D3),
            (0xE0, 0x25CA), (0xE1, 0x2329), (0xE5, 0x2211), (0xF1, 0x232A), (0xF2, 0x222B), (0xF3, 0x2320), (0xF5, 0x2321),
        ]
        for (code, uni) in table { #expect(symbolUnicode(code) == uni, "0x\(String(code, radix: 16))") }
        let none: [UInt32] = [
            0x20, 0x21, 0x23, 0x25, 0x26, 0x28, 0x29, 0x2B, 0x2C, 0x2E, 0x2F, 0x30, 0x31, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x5B, 0x5D, 0x5F,
            0x7B, 0x7C, 0x7D, 0x60, 0xBD, 0xBE, 0xD2, 0xD3, 0xD4, 0xE2, 0xE3, 0xE4, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xF0,
            0xF4, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
        ]
        for code in none { #expect(symbolUnicode(code) == nil, "0x\(String(code, radix: 16))") }
    }

    @Test func symbolFontCharactersDrawInTheSymFont() {
        guard db.hasFamily("Symbol"), coversSymbol(db.face("Symbol", "Regular"), "\u{F0DE}") else { return }
        var f = setup("x\u{F0DE}y", 600, 300)
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].runs[0].props.font = "Arial"
        f.body.paragraphs[0].runs[0].props.fontSym = "Symbol"
        let fams = f.lay(600, 300).runs.map { (family: $0.face.family.lowercased(), start: $0.chars.start) }
        #expect(fams.contains { $0.family == "symbol" && $0.start == 1 }, "\(fams)")
        #expect(fams.allSatisfy { $0.start == 1 || $0.family != "symbol" }, "\(fams)")
    }

    @Test func smallCapitalsDrawSmallerThanTheCapitalsBesideThem() {
        var f = setup("HxHx", 2000, 300)
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].runs[0].props.caps = .small
        f.body.paragraphs[0].runs[0].props.size = 40
        let sizes = f.lay(2000, 300).runs.map { [Double($0.glyphs.count), $0.size] }
        #expect(sizes == [[1, 40], [1, 32], [1, 40], [1, 32]])
    }

    @Test func capitalsKeepCharactersWhoseCapitalIsASequence() throws {
        #expect(capsChar("a") == "A")
        #expect(capsChar("ǆ") == "Ǆ")
        #expect(capsChar("ß") == "ß")
        #expect(capsChar("\u{FB01}") == "\u{FB01}")
        #expect(capsChar("ŉ") == "ŉ")
        var f = setup("aß", 2000, 300)
        f.body.paragraphs[0].runs[0].props.caps = .all
        let r = try #require(f.lay(2000, 300).runs.first { !$0.cells.isEmpty })
        if r.face.covers("ß") { #expect(r.glyphs[1].gid == r.face.glyph(for: "ß")) }
    }

    @Test func transparentTextIsFadedOnce() throws {
        var f = setup("Faded", 2000, 300)
        f.body.paragraphs[0].runs[0].props.fill = .solid(color: ColorRef.rgb(Rgba.rgb(255, 0, 0)).with(.alpha(40000)))
        let r = try #require(f.lay(2000, 300).runs.first { !$0.cells.isEmpty })
        let opacity = Double(r.color.a) / 255 * r.alpha
        #expect(abs(opacity - 0.4) < 0.01, "\(opacity)")
    }

    /// One paragraph `text` with tab stops `tabs` (position, `algn`), no bullet or indent.
    func tabbed(_ text: String, _ tabs: [(Double, String)], _ w: Double) -> TextLayout {
        var f = setup(text, w, 300)
        f.eachRun { $0.props.size = 18 }
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].props.marginLeft = 0
        f.body.paragraphs[0].props.indent = 0
        f.body.paragraphs[0].props.defaultTab = 72
        f.body.paragraphs[0].props.tabs = tabs.map { TabStop(pos: $0.0, align: $0.1) }
        return f.lay(w, 300)
    }

    @Test func tabStopsAlignTheTextAfterThem() {
        var l = tabbed("a\tright", [(200, "r")], 600)
        #expect(near(l.lines[0].extent.right - l.inner.x0, 200))
        l = tabbed("a\tmid", [(200, "ctr")], 600)
        #expect(near((l.lines[0].edges[2].left + l.lines[0].edges[4].right) / 2 - l.inner.x0, 200))
        l = tabbed("x\t1234.567", [(150, "dec")], 600)
        #expect(near(l.lines[0].edges[6].left - l.inner.x0, 150), "the point sits at the stop")
        l = tabbed("x\t12,5", [(150, "dec")], 600)
        #expect(near(l.lines[0].extent.right - l.inner.x0, 150))
        l = tabbed("x\twider than the gap", [(20, "r")], 600)
        #expect(near(l.lines[0].edges[2].left, l.lines[0].edges[0].right))
        l = tabbed("a\tb\tc", [(30, "l")], 600)
        #expect(near(l.lines[0].edges[2].left - l.inner.x0, 30))
        #expect(near(l.lines[0].edges[4].left - l.inner.x0, 72))
    }

    @Test func aTabPastTheEndMovesToTheNextLine() throws {
        let l = tabbed("abcdefghij\tk", [], 130)
        try #require(l.lines.count == 2)
        #expect(l.lines[1].start == 10)
        #expect(near(l.lines[1].edges[1].left - l.inner.x0, 72))
    }

    /// Underline decorations of "ab cd" underlined `u` at 40 pt.
    func underlineDecos(_ u: String) -> (TextLayout, [Deco]) {
        var f = setup("ab cd", 2000, 300)
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].runs[0].props.size = 40
        f.body.paragraphs[0].runs[0].props.underline = u
        let l = f.lay(2000, 300)
        return (l, l.decos.filter { !$0.behind })
    }

    @Test func underlinesSitAtTheFontUnderlineInTheirStyle() throws {
        let (l, sng) = underlineDecos("sng")
        let r = try #require(l.runs.first { !$0.cells.isEmpty })
        let k = 40 / r.face.upem
        let base = l.lines[0].baseline
        try #require(sng.count == 1)
        #expect(near(sng[0].rect.y0 - base, r.face.underline.position * k))
        #expect(near(sng[0].rect.height, (r.face.underline.thickness * k).rustMax(0.5)))
        let t = sng[0].rect.height
        let (_, dbl) = underlineDecos("dbl")
        try #require(dbl.count == 2)
        #expect(near(dbl[0].rect.y0, sng[0].rect.y0 - t) && near(dbl[1].rect.y1, sng[0].rect.y1))
        #expect(underlineDecos("heavy").1[0].rect.height > t * 1.4)
        let dotted = underlineDecos("dotted").1[0]
        #expect(dotted.line == .dashed(.dot))
        let pieces = dotted.pieces()
        #expect(pieces.count > 3)
        #expect(near(pieces[0].width, t) && near(pieces[1].x0 - pieces[0].x1, t))
        let (pts, w) = try #require(underlineDecos("wavy").1[0].wave())
        #expect(pts.count > 4 && w > 0 && w < t)
        #expect(pts[0].y < pts[1].y)
        #expect(underlineDecos("words").1.count == 1)
    }

    @Test func strikethroughSitsAtTheFontStrikeoutPosition() throws {
        var f = setup("Struck", 2000, 300)
        f.body.paragraphs[0].props.bullet = .none_
        f.body.paragraphs[0].runs[0].props.size = 96
        f.body.paragraphs[0].runs[0].props.strike = .single
        let l = f.lay(2000, 300)
        let r = try #require(l.runs.first { !$0.cells.isEmpty })
        let k = 96 / r.face.upem
        let d = try #require(l.decos.first { !$0.behind })
        #expect(near(l.lines[0].baseline - d.rect.y0, r.face.strikeout.position * k))
        #expect(near(d.rect.height, (r.face.strikeout.thickness * k).rustMax(0.5)))
    }

    @Test func symbolsAfterAnEmojiKeepATextFace() {
        guard db.cascade(["✅"], [], "Regular").isColor else { return }
        let l = bidiSetup([Run("✅ ⚠ ™")], 2000, false, .left).lay(2000, 300)
        for r in l.runs {
            for c in r.cells { #expect(r.face.isColor == (c.char == "✅"), "\(c.char) drawn with \(r.face.family)") }
        }
    }

    @Test func fallbackFacesDoNotMoveTheBaseline() {
        func base(_ text: String) -> (Double, Double) {
            let l = bidiSetup([Run(text)], 2000, false, .left).lay(2000, 300)
            return (l.lines[0].baseline, l.lines[0].bottom)
        }
        let plain = base("Hxg Hxg")
        for text in ["Hxg \u{1F600} Hxg", "Hxg \u{0E2A}\u{0E27}\u{0E31}\u{0E2A}", "Hxg \u{222B}\u{2211}"] {
            let b = base(text)
            #expect(near(b.0, plain.0) && near(b.1, plain.1), "\(text)")
        }
    }

    @Test func stackedCombiningMarksTakeAFaceThatDrawsThem() {
        let cluster: [Unicode.Scalar] = ["Z", "\u{0334}", "\u{0321}", "\u{031B}"]
        let runFace = db.face("Inter", "Regular")
        guard !Fallback.coversCluster(runFace, cluster), ["DejaVu Sans", "Segoe UI"].contains(where: db.hasFamily) else { return }
        for fam in ["DejaVu Sans", "Segoe UI"] where db.hasFamily(fam) { _ = db.face(fam, "Regular") }
        let f = db.cascade(cluster, [runFace], "Regular")
        #expect(Fallback.coversCluster(f, cluster), "\(f.family) lacks the marks")
    }
}

@Suite struct BoxTests {
    @Test func eastAsianVerticalTextMarksCJKUpright() {
        var f = setup("日本、ABC 12", 300, 600)
        f.body.body.vert = .eaVertical
        var l = f.lay(300, 600)
        #expect(l.rotation == 90)
        let upright = l.runs.filter { !$0.cells.isEmpty }.flatMap { r in r.cells.map { (c: $0.char, u: r.upright) } }.filter { $0.c != " " }.map(\.u)
        #expect(upright == [true, true, true, false, false, false, false, false])
        f.body.body.vert = .vertical
        l = f.lay(300, 600)
        #expect(l.runs.allSatisfy { !$0.upright })
        #expect(isUpright("あ") && isUpright("、") && isUpright("Ａ") && !isUpright("A") && !isUpright("1"))
    }

    @Test func mongolianLinesRunLeftToRightAndStackedLettersStandOneEmApart() {
        var f = setup("one\ntwo", 200, 400)
        f.body.body.vert = .vertical
        let v = f.lay(200, 400)
        f.body.body.vert = .mongolianVertical
        let m = f.lay(200, 400)
        #expect(m.rotation == 90)
        #expect(v.lines[0].top < v.lines[1].top)
        #expect(m.lines[0].top > m.lines[1].top)
        let mid = (m.inner.y0 + m.inner.y1) / 2
        #expect(near((m.lines[0].top + m.lines[0].bottom) / 2 - mid + ((v.lines[0].top + v.lines[0].bottom) / 2 - mid), 0))
        var g = setup("Lil", 200, 400)
        g.body.body.vert = .stacked
        g.body.paragraphs[0].runs[0].props.size = 20
        let s = g.lay(200, 400)
        #expect(s.runs.filter { !$0.cells.isEmpty }.allSatisfy { $0.upright })
        var h = setup("one\ntwo", 200, 400)
        h.body.body.vert = .stacked
        let st = h.lay(200, 400)
        #expect(st.lines[0].top > st.lines[1].top)
        h.body.body.vert = .stackedRtl
        let sr = h.lay(200, 400)
        #expect(sr.lines[0].top < sr.lines[1].top)
        #expect(sr.runs.filter { !$0.cells.isEmpty }.allSatisfy { $0.upright })
        let e = s.lines[0].edges
        #expect(near(e[1].right - e[1].left, 20) && near(e[2].right - e[2].left, 20), "\(e)")
    }

    @Test func rtlColumnsStartOnTheRightAndJustAnchoringSitsAtTheBottom() throws {
        var f = setup(String(repeating: "word ", count: 200), 400, 200)
        f.body.body.columns = 2
        f.body.body.colSpacing = 20
        f.body.paragraphs[0].runs[0].props.size = 12
        let ltr = f.lay(400, 200)
        f.body.body.rtlCol = true
        let rtl = f.lay(400, 200)
        func col(_ l: TextLayout, _ c: Int) throws -> Double { try #require(l.lines.first { $0.column == c }).extent.left }
        let (l0, l1, r0, r1) = (try col(ltr, 0), try col(ltr, 1), try col(rtl, 0), try col(rtl, 1))
        #expect(l0 < l1)
        #expect(r0 > r1)
        var g = setup("one line", 400, 300)
        g.body.body.anchor = .bottom
        let b = g.lay(400, 300).lines[0].top
        for a: Anchor in [.justified, .distributed] {
            g.body.body.anchor = a
            #expect(near(g.lay(400, 300).lines[0].top, b))
        }
    }

    @Test func anchorCtrCentresTheTextBlock() {
        let text = "The shape is top - center - overriding paragraph right alignment."
        func blockCentre(_ l: TextLayout) -> Double {
            var (lo, hi) = (Double.infinity, -Double.infinity)
            for li in l.lines where li.end > li.start {
                lo = Swift.min(lo, li.extent.left)
                hi = Swift.max(hi, li.extent.right)
            }
            return (lo + hi) / 2
        }
        func para(_ align: Align?, _ text: String) -> Paragraph {
            var p = Paragraph(runs: [Run(text)])
            p.props.align = align
            return p
        }
        func anchored(_ paras: [Paragraph], wrap: Bool? = nil) -> TextBody {
            var b = TextBody(paragraphs: paras)
            b.body.anchorCtr = true
            b.body.wrap = wrap
            return b
        }
        func lay(_ body: TextBody, _ w: Double) -> TextLayout {
            var f = setup("", w, 104)
            f.body = body
            return f.lay(w, 104)
        }
        #expect(near(blockCentre(lay(anchored([para(.right, text)]), 828)), 414, 1))
        #expect(near(blockCentre(lay(anchored([para(nil, text)]), 828)), 414, 1))
        #expect(near(blockCentre(lay(anchored([para(.right, text), para(nil, "")]), 828)), 414, 1))
        #expect(near(blockCentre(lay(anchored([para(.right, text), para(nil, "short")]), 828)), 414, 1))
        #expect(near(blockCentre(lay(anchored([para(.right, text)], wrap: false), 300)), 150, 2))
        let control = lay(TextBody(paragraphs: [para(.right, text)]), 828)
        #expect(control.lines.allSatisfy { $0.extent.right > 810 })
    }
}
