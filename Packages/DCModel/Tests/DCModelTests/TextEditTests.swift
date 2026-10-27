// Ported from deckcraft crates/model/src/{words,edit,bidi,anim}.rs tests (MIT OR Apache-2.0, © ArtCraft
// Team and the DeckCraft contributors). The word-stop traces are PowerPoint's, as deckcraft observed them.
import DCCore
@testable import DCModel
import Testing

/// Stops drawn as `|` in the text, for readable assertions.
private func marked(_ text: String, _ st: [Int]) -> String {
    var out = ""
    let scalars = Array(text.unicodeScalars)
    for (i, c) in scalars.enumerated() {
        if st.contains(i) { out += "|" }
        switch c {
        case "\u{0B}": out += "↵"
        case "\t": out += "→"
        default: out.unicodeScalars.append(c)
        }
    }
    if st.contains(scalars.count) { out += "|" }
    return out
}

private func fwd(_ t: String) -> String { marked(t, Words.stops(t)) }
private func back(_ t: String) -> String { marked(t, Words.backStops(t)) }

@Suite struct WordsTests {
    @Test func punctuationAndSpaces() {
        let t = "Hello, world!  Foo...bar baz-qux it's 3.14 e.g. a_b x@y.com (end) \"q\" end."
        let want = "|Hello|, |world|!  |Foo|...|bar |baz-qux |it's |3.14 |e|.|g|. |a|_|b |x|@|y|.|com |(|end|) |\"|q|\" |end|.|"
        #expect(fwd(t) == want)
        #expect(back(t) == want)
    }

    @Test func hyphensApostrophesNumbers() {
        let t = "a-b -b a--b a - b a- b dogs' x 'q' 1,000.5 3:45 v1.2.3 $5 50% a/b x&y #tag a+b c++ end"
        #expect(fwd(t) == "|a-b |-|b |a-|-|b |a |- |b |a- |b |dogs|' |x |'q|' |1,000.5 |3:45 |v1.2.3 |$|5 |50|% |a|/|b |x|&|y |#|tag |a|+|b |c|++ |end|")
        let u = "it’s x a?!b a.)b a),b 1.a a1.b 1.5.x 1-2 a1-b A-1 —x x— a's 'tis o'clock ‘q’ end"
        #expect(fwd(u) == "|it’s |x |a|?!|b |a|.)|b |a|),|b |1|.|a |a1|.|b |1.5|.|x |1-2 |a1-b |A-1 |—|x |x|— |a's |'tis |o'clock |‘|q|’ |end|")
    }

    @Test func marksEmojiSymbols() {
        let t = "café e\u{301}te 👍🏽 x 👨\u{200d}👩\u{200d}👧 y ½ ®z «q» “w” ¿no? ok—em dash–en x"
        let want = "|café |e\u{301}te |👍🏽 |x |👨\u{200d}👩\u{200d}👧 |y |½ |®|z |«|q|» |“|w|” |¿|no|? |ok|—|em |dash|–|en |x|"
        #expect(rustEqual(fwd(t), want))
        #expect(rustEqual(back(t), want))
        // A run of emoji is one token; emoji then punctuation is two going right, one going left.
        #expect(fwd("👍👍 x 👍? x👍y") == "|👍👍 |x |👍|? |x|👍|y|")
        #expect(back("👍👍 x 👍? x👍y") == "|👍👍 |x |👍? |x|👍|y|")
    }

    @Test func cjkEachCharacter() {
        let t = "日本語のテキストです。カタカナ漢字 abc 中文字符，标点。한국어 문장 a。。b"
        #expect(fwd(t) == "|日|本|語|の|テ|キ|ス|ト|で|す|。|カ|タ|カ|ナ|漢|字 |abc |中|文|字|符|，|标|点|。|한|국|어 |문|장 |a|。。|b|")
        #expect(back(t) == fwd(t))
    }

    @Test func rtlWordsInLogicalOrder() {
        #expect(fwd("Hello مرحبا بالعالم world שלום עולם end") == "|Hello |مرحبا |بالعالم |world |שלום |עולם |end|")
    }

    @Test func tabsBreaksAndOtherSpaces() {
        #expect(fwd("  lead x   mid  ") == "|  |lead |x   |mid  |")
        #expect(fwd("Five\u{0B}six seven\tTab   x") == "|Five|↵|six |seven|→|Tab   |x|")
        #expect(fwd("a\t  b x  \u{0B}  y q\u{0B}\u{0B}z") == "|a|→|  |b |x  |↵|  |y |q|↵|↵|z|")
        let t = "a\u{a0}\u{a0}b a\u{3000}b a\u{2003}b a \u{a0}b a\t\tb a \tb a\u{a0} b end"
        #expect(fwd(t) == "|a\u{a0}\u{a0}|b |a\u{3000}|b |a\u{2003}|b |a \u{a0}|b |a|→|→|b |a |→|b |a\u{a0} |b |end|")
        #expect(back(t) == "|a|\u{a0}|\u{a0}|b |a|\u{3000}|b |a|\u{2003}|b |a |\u{a0}|b |a|→|→|b |a |→|b |a\u{a0} |b |end|")
    }

    @Test func nextAndPrev() {
        let t = "  lead x   mid  "
        #expect(Words.nextStop(t, 1) == 2)
        #expect(Words.nextStop(t, 9) == 11)
        #expect(Words.nextStop(t, 16) == nil)
        #expect(Words.prevStop(t, 1) == 0)
        #expect(Words.prevStop(t, 9) == 7)
        #expect(Words.prevStop(t, 15) == 11)
        #expect(Words.prevStop(t, 0) == nil)
        #expect(Words.nextStop("", 0) == nil)
        #expect(Words.prevStop("", 0) == nil)
    }

    @Test func doubleClickWord() {
        let t = "Hello world,  foo bar"
        #expect(Words.wordAt(t, 7) == (6, 11))
        #expect(Words.wordAt(t, 15) == (14, 17))
        #expect(Words.wordAt(t, 11) == (11, 12))
        #expect(Words.wordAt(t, 12) == (11, 12))
        #expect(Words.wordAt(t, 13) == (12, 14))
        #expect(Words.wordAt(t, 21) == (18, 21))
        #expect(Words.wordAt("日本語のテキスト abc", 5) == (5, 6))
        #expect(Words.wordAt("", 3) == (0, 0))
        #expect(Words.wordAt("x👨\u{200d}👩\u{200d}👧y", 2) == (1, 6))
    }

    @Test func deleteForwardExtent() {
        let t = "ab   cd...ef gh"
        let ends = (0 ... t.utf8.count).map { Words.deleteForwardEnd(t, $0) }
        // Before smart spacing: PowerPoint's results after it are tested with the editing tests.
        #expect(ends == [5, 2, 7, 5, 5, 7, 7, 10, 10, 10, 13, 12, 15, 15, 15, nil])
        #expect(Words.deleteForwardEnd("ab\t cd", 2) == 3)
        #expect(Words.deleteForwardEnd("ab  ", 2) == 4)
    }
}

private func body(_ t: String) -> TextBody { TextBody.fromText(t) }

/// Ctrl+Backspace / Ctrl+Delete from `at`: the text and caret after (PowerPoint's results).
private func delWord(_ text: String, _ at: TextPos, _ forward: Bool) -> (String, TextPos) {
    var b = body(text)
    let c = TextEdit.deleteWord(&b, at, forward)
    return (b.text, c)
}

private func same(_ got: (String, TextPos), _ want: (String, TextPos)) -> Bool {
    rustEqual(got.0, want.0) && got.1 == want.1
}

@Suite struct EditTests {
    @Test func insertAndSplit() {
        var b = body("Hello")
        let c = TextEdit.insert(&b, (0, 5), " world\nNext")
        #expect(b.text == "Hello world\nNext")
        #expect(c == (1, 4))
        let c2 = TextEdit.insert(&b, (0, 0), ">")
        #expect(c2 == (0, 1))
        #expect(b.paragraphs[0].runs.count == 1)
    }

    @Test func deleteWithinAndAcross() {
        var b = body("abc\ndef\nghi")
        #expect(TextEdit.delete(&b, (0, 1), (2, 1)) == (0, 1))
        #expect(b.text == "ahi")
        var d = body("abcdef")
        TextEdit.delete(&d, (0, 4), (0, 2))
        #expect(d.text == "abef")
        // hostile positions
        TextEdit.delete(&d, (99, 99), (0, 0))
        #expect(d.text == "")
    }

    @Test func formatSplitsRuns() {
        var b = body("abcdef")
        TextEdit.format(&b, (0, 2), (0, 4)) { $0.bold = true }
        let p = b.paragraphs[0]
        #expect(p.runs.count == 3)
        #expect(p.runs[1].text == "cd")
        #expect(p.runs[1].props.bold == true)
        #expect(TextEdit.propsAt(b, (0, 3)).bold == true)
        #expect(TextEdit.textRange(b, (0, 1), (0, 5)) == "bcde")
        let s = TextEdit.slice(b, (0, 1), (0, 5))
        #expect(s.text == "bcde")
        var c = body("XY")
        let caret = TextEdit.insertBody(&c, (0, 1), s)
        #expect(c.text == "XbcdeY")
        #expect(caret == (0, 5))
    }

    @Test func wordsAndMoves() {
        let b = body("Hello brave world")
        let w = TextEdit.wordAt(b, (0, 7))
        #expect(w.0 == (0, 6) && w.1 == (0, 11))
        #expect(TextEdit.wordMove(b, (0, 0), true) == (0, 6))
        #expect(TextEdit.wordMove(b, (0, 8), false) == (0, 6))
        #expect(TextEdit.charMove(b, (0, 17), true) == (0, 17))
        #expect(TextEdit.changeCase("hello world. again", "sentence") == "Hello world. Again")
        #expect(TextEdit.changeCase("hello world", "title") == "Hello World")
    }

    @Test func lineBreakInsert() {
        var b = body("ab")
        let c = TextEdit.insert(&b, (0, 1), "\u{0B}")
        #expect(c == (0, 2))
        #expect(b.paragraphs[0].charLen == 3)
        #expect(b.paragraphs.count == 1)
    }

    @Test func ctrlBackspaceLikePowerPoint() {
        let t = "ab   cd...ef gh"
        let want: [(String, Int)] = [
            ("ab   cd...ef gh", 0), ("b   cd...ef gh", 0), ("   cd...ef gh", 0), ("  cd...ef gh", 0), (" cd...ef gh", 0),
            ("cd...ef gh", 0), ("ab   d...ef gh", 5), ("ab   ...ef gh", 5), ("ab   cd..ef gh", 7), ("ab   cd.ef gh", 7),
            ("ab   cdef gh", 7), ("ab   cd...f gh", 10), ("ab   cd... gh", 10), ("ab   cd...gh", 10), ("ab   cd...ef h", 13),
            ("ab   cd...ef ", 13),
        ]
        for (c, (txt, caret)) in want.enumerated() {
            #expect(same(delWord(t, (0, c), false), (txt, (0, caret))), "caret \(c)")
        }
        let w = "Hello world  foo, bar\nnext para"
        #expect(same(delWord(w, (0, 12), false), ("Hello  foo, bar\nnext para", (0, 6))))
        #expect(same(delWord(w, (0, 17), false), ("Hello world  foo bar\nnext para", (0, 16))))
        // At a paragraph's start it joins the paragraph before.
        #expect(same(delWord(w, (1, 0), false), ("Hello world  foo, barnext para", (0, 21))))
        #expect(same(delWord("ab\n  cd", (1, 2), false), ("ab\ncd", (1, 0))))
        // A line break is a word of its own.
        var b = body("ab")
        TextEdit.insert(&b, (0, 2), "\u{0B}cd")
        #expect(TextEdit.deleteWord(&b, (0, 3), false) == (0, 2))
        #expect(b.text == "abcd")
        var b2 = body("ab")
        TextEdit.insert(&b2, (0, 2), "\u{0B}cd")
        #expect(TextEdit.deleteWord(&b2, (0, 2), true) == (0, 2))
        #expect(b2.text == "abcd")
        #expect(same(delWord("x", (0, 0), false), ("x", (0, 0))))
        // Emoji sequences and combining marks are never split.
        #expect(same(delWord("a 👨\u{200d}👩\u{200d}👧", (0, 7), false), ("a ", (0, 2))))
        #expect(same(delWord("ce\u{301}te x", (0, 5), false), (" x", (0, 0))))
        #expect(same(delWord("ce\u{301}te x", (0, 6), false), ("x", (0, 0))))
        // Each CJK character is a word.
        #expect(same(delWord("日本語", (0, 3), false), ("日本", (0, 2))))
    }

    @Test func ctrlDeleteLikePowerPoint() {
        let t = "ab   cd...ef gh"
        let want: [(String, Int)] = [
            ("cd...ef gh", 0), ("a   cd...ef gh", 1), ("ab...ef gh", 2), ("ab cd...ef gh", 3), ("ab  cd...ef gh", 4),
            ("ab...ef gh", 2), ("ab   c...ef gh", 6), ("ab   cdef gh", 7), ("ab   cd. ef gh", 9), ("ab   cd.. ef gh", 10),
            ("ab   cd... gh", 11), ("ab   cd...e gh", 11), ("ab   cd...ef", 12), ("ab   cd...ef", 12), ("ab   cd...ef g", 14),
            ("ab   cd...ef gh", 15),
        ]
        for (c, (txt, caret)) in want.enumerated() {
            #expect(same(delWord(t, (0, c), true), (txt, (0, caret))), "caret \(c)")
        }
        let w = "Hello world  foo, bar\nnext para"
        let cases: [(Int, String, Int)] = [
            (0, "world  foo, bar\nnext para", 0), (2, "He world  foo, bar\nnext para", 2), (5, "Hello  foo, bar\nnext para", 5),
            (6, "Hello foo, bar\nnext para", 6), (8, "Hello wo  foo, bar\nnext para", 8), (11, "Hello world, bar\nnext para", 11),
            (12, "Hello world foo, bar\nnext para", 12), (16, "Hello world  foobar\nnext para", 16),
            (17, "Hello world  foo,\nnext para", 17), (18, "Hello world  foo, \nnext para", 18),
            (21, "Hello world  foo, barnext para", 21),
        ]
        for (c, txt, caret) in cases {
            #expect(same(delWord(w, (0, c), true), (txt, (0, caret))), "caret \(c)")
        }
        #expect(same(delWord(w, (1, 0), true), ("Hello world  foo, bar\npara", (1, 0))))
        #expect(same(delWord(w, (1, 2), true), ("Hello world  foo, bar\nne para", (1, 2))))
        #expect(same(delWord("ab  \ncd", (0, 2), true), ("ab\ncd", (0, 2))))
        #expect(same(delWord("ab  \ncd", (0, 3), true), ("ab\ncd", (0, 2))))
        #expect(same(delWord("ab\t cd", (0, 2), true), ("ab cd", (0, 2))))
        #expect(same(delWord("ab cd(x) ef", (0, 3), true), ("ab (x) ef", (0, 3))))
        #expect(same(delWord("ab cd, ef", (0, 3), true), ("ab, ef", (0, 2))))
        #expect(same(delWord("ab. (cd) ef", (0, 5), true), ("ab. () ef", (0, 5))))
        #expect(same(delWord("ab \"cd\" ef", (0, 4), true), ("ab \"\" ef", (0, 4))))
        #expect(same(delWord("ab, cd", (0, 4), true), ("ab, ", (0, 4))))
        // Right-to-left text deletes in logical order like any other.
        #expect(same(delWord("مرحبا بالعالم hello", (0, 6), true), ("مرحبا hello", (0, 6))))
        #expect(same(delWord("مرحبا بالعالم hello", (0, 8), false), ("مرحبا لعالم hello", (0, 6))))
        // Numbers keep their separators: no space is pushed into "3.14".
        #expect(same(delWord("3.x 14", (0, 2), true), ("3.14", (0, 2))))
        // Hostile positions clamp.
        #expect(delWord("ab", (9, 9), true).0 == "ab")
        #expect(delWord("", (0, 0), false).0 == "")
        var empty = TextBody()
        #expect(TextEdit.deleteWord(&empty, (3, 3), true) == (0, 0))
    }

    @Test func paragraphMoves() {
        let b = body("one two\nthree\n\nfour")
        #expect(TextEdit.paraDown(b, (0, 2)) == (1, 0))
        #expect(TextEdit.paraDown(b, (1, 0)) == (2, 0))
        #expect(TextEdit.paraDown(b, (3, 1)) == (3, 4))
        #expect(TextEdit.paraUp(b, (3, 2)) == (3, 0))
        #expect(TextEdit.paraUp(b, (3, 0)) == (2, 0))
        #expect(TextEdit.paraUp(b, (0, 0)) == (0, 0))
        #expect(TextEdit.wordMove(b, (0, 4), true) == (0, 7))
        #expect(TextEdit.wordMove(b, (0, 7), true) == (1, 0))
        #expect(TextEdit.wordMove(b, (1, 0), false) == (0, 7))
        #expect(TextEdit.wordMove(b, (2, 0), true) == (3, 0))
        #expect(TextEdit.wordMove(b, (3, 4), true) == (3, 4))
        #expect(TextEdit.wordMove(b, (0, 0), false) == (0, 0))
    }

    @Test func caseCycle() {
        #expect(TextEdit.nextCase("hello world") == "title")
        #expect(TextEdit.nextCase("Hello World") == "upper")
        #expect(TextEdit.nextCase("HELLO WORLD") == "lower")
        #expect(TextEdit.nextCase("Hello world") == "upper")
        #expect(TextEdit.nextCase("hELLO wORLD") == "upper")
        #expect(TextEdit.nextCase("hello. world is HERE") == "upper")
        #expect(TextEdit.nextCase("123") == "upper")
        // Rust's `to_lowercase` ends a word with final sigma.
        #expect(TextEdit.changeCase("ΟΔΟΣ", "lower") == "οδος".replacingOccurrences(of: "σ", with: "ς", options: .backwards, range: nil))
    }

    /// Speaker notes: a bold heading over indented bullet points.
    private func notes() -> TextBody {
        var b = body("Overview\nFirst point\nSecond point")
        TextEdit.format(&b, (0, 0), (0, 8)) { $0.bold = true }
        for i in b.paragraphs.indices.dropFirst() {
            b.paragraphs[i].level = 1
            b.paragraphs[i].props = ParaProps(marginLeft: 36.0, indent: -18.0, bullet: .char(char: "•"))
        }
        return b
    }

    @Test func replaceTextKeepsFormatting() {
        let before = notes()
        // Same text: nothing changes.
        var b = before
        TextEdit.replaceText(&b, "Overview\nFirst point\nSecond point")
        #expect(b == before)
        // A word typed into a bullet: heading stays bold, bullets keep level, indent and bullet.
        TextEdit.replaceText(&b, "Overview\nFirst main point\nSecond point")
        #expect(b.text == "Overview\nFirst main point\nSecond point")
        #expect(b.paragraphs[0].runs[0].props.bold == true)
        #expect(b.paragraphs[1].props == before.paragraphs[1].props)
        #expect(b.paragraphs[1].level == 1 && b.paragraphs[2].level == 1)
        // Typing at the end of the heading continues it in bold.
        TextEdit.replaceText(&b, "Overview (5 min)\nFirst main point\nSecond point")
        #expect(b.paragraphs[0].runs.count == 1)
        #expect(b.paragraphs[0].runs[0].props.bold == true)
        // Enter after a bullet starts another bullet; deleting one joins nothing else.
        TextEdit.replaceText(&b, "Overview (5 min)\nFirst main point\nThird\nSecond point")
        #expect(b.paragraphs.count == 4)
        #expect(b.paragraphs[2].level == 1 && b.paragraphs[2].props == before.paragraphs[1].props)
        TextEdit.replaceText(&b, "Overview (5 min)\nSecond point")
        #expect(b.text == "Overview (5 min)\nSecond point")
        #expect(b.paragraphs[0].runs[0].props.bold == true)
        #expect(b.paragraphs[1].level == 1)
        // Text with nothing in common is new plain text.
        TextEdit.replaceText(&b, "Plain")
        #expect(b == body("Plain"))
        TextEdit.replaceText(&b, "")
        #expect(b.isEmpty)
        // Into an empty body.
        var e = TextBody()
        TextEdit.replaceText(&e, "a\nb")
        #expect(e.text == "a\nb")
    }
}

@Suite struct BidiTests {
    @Test func detectsArabicAndKurdish() {
        #expect(firstStrongIsRTL("مرحبا"))
        #expect(firstStrongIsRTL("من ناوم هێڤاره"))
        #expect(firstStrongIsRTL("سلام"))
    }

    @Test func detectsHebrew() { #expect(firstStrongIsRTL("שלום")) }

    @Test func detectsLatinAsNotRTL() {
        #expect(!firstStrongIsRTL("Hello"))
        #expect(!firstStrongIsRTL("DeckCraft"))
    }

    @Test func skipsNeutralsNumbersAndWhitespace() {
        #expect(firstStrongIsRTL("  123 مرحبا"))
        #expect(firstStrongIsRTL("... (2024) سنة"))
        #expect(!firstStrongIsRTL("  123 Hello"))
        #expect(!firstStrongIsRTL(""))
        #expect(!firstStrongIsRTL("   12345 "))
    }

    @Test func honoursDirectionalMarks() {
        #expect(firstStrongIsRTL("\u{200F}Hello"))
        #expect(!firstStrongIsRTL("\u{200E}مرحبا"))
    }
}

@Suite struct AnimTests {
    @Test func transitionOptionLabels() {
        #expect(transitionOptionLabel("push", "l") == "From Right")
        #expect(transitionOptionLabel("push", "u") == "From Bottom")
        #expect(transitionOptionLabel("wipe", "r") == "From Left")
        #expect(transitionOptionLabel("cover", "ru") == "From Bottom-Left")
        #expect(transitionOptionLabel("ripple", "ru") == "From Bottom-Left")
        #expect(transitionOptionLabel("glitter", "hexU") == "Hexagons From Top")
        #expect(transitionOptionLabel("glitter", "l") == "Diamonds From Left")
        #expect(transitionOptionLabel("wind", "l") == "Left")
        #expect(transitionOptionLabel("pageCurlDouble", "singleR") == "Single Right")
        #expect(transitionOptionLabel("shred", "particlesOut") == "Particles Out")
        #expect(transitionOptionLabel("zoom", "rotate") == "Zoom and Rotate")
        #expect(transitionOptionLabel("split", "vertIn") == "Vertical In")
        for t in transitions {
            for o in t.options {
                #expect(!transitionOptionLabel(t.id, o).isEmpty, "\(t.id)/\(o)")
            }
        }
    }

    @Test func blankAndDeeperParagraphsFollowTheTopOneBeforeThem() {
        var t = TextBody.fromText("Before\nLead\n \nSub\nNext")
        for (i, lvl) in [1, 0, 0, 1, 0].enumerated() { t.paragraphs[i].level = UInt8(lvl) }
        #expect(paragraphBuildRoles(t) == [.unowned, .top, .member(1), .member(1), .top])
    }
}
