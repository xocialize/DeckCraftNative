// DCTextTests — the font layer: the database (craft-fonts, substitutes, Windows family names, Calibri for
// missing fonts), fallback, scripts and slots, emoji clusters, shaping through CoreText, the bidi helpers,
// and date fields. Port of the tests in deckcraft crates/fonts/src/{lib,fallback,script,shape}.rs and
// crates/text/src/{bidi,datetime}.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
// Font fixtures are read from the deckcraft checkout beside this repository; tests that need them return
// early without it.
import DCCore
import DCModel
import Foundation
import Synchronization
@testable import DCText
import Testing

/// deckcraft's test fixture fonts (`crates/<crate>/tests/fixtures/<name>`), if the checkout is there.
func deckcraftFixture(_ crate: String, _ name: String) -> [UInt8]? {
    let root = ProcessInfo.processInfo.environment["DECKCRAFT_DIR"].map { URL(filePath: $0) }
        ?? URL(filePath: "/Volumes/Satechi/Development/research/deckcraft")
    return (try? Data(contentsOf: root.appending(path: "crates/\(crate)/tests/fixtures/\(name)"))).map { [UInt8]($0) }
}

func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

@Suite struct FontDBTests {
    /// A family macOS downloads on demand but hasn't (Osaka, from the legacy crash corpus) is missing, at once:
    /// asking CoreText about it would put up macOS's download prompt and block until someone answers it. (Where
    /// Osaka is installed the lookup is simply quick; this Mac had it on demand until 2026-10-31.)
    /// The lookup runs on its own thread, so a regression fails here rather than hanging the run.
    @Test func aFontMacOSWouldDownloadIsMissingAtOnce() {
        let fresh = FontDB(craftFontsDir: nil, systemFonts: true)
        let done = DispatchSemaphore(value: 0)
        let found = Mutex<Bool?>(nil)
        Thread {
            let has = fresh.hasFamily("Osaka")
            found.withLock { $0 = has }
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + 20) == .success, "looking up Osaka blocked")
        #expect(found.withLock { $0 } == FontDB.isInstalled("Osaka"))
    }

    @Test func requestedFaceWinsWhenItCovers() {
        let inter = db.face(fallbackFamily, "Regular")
        #expect(db.cascade(["a"], [inter], "Regular") === inter)
        // Spaces and joiners never force a fallback.
        #expect(db.cascade([" ", "\u{200D}"], [inter], "Regular") === inter)
        #expect(!db.cascade([], [], "Regular").family.isEmpty)
    }

    @Test func arabicClusterFallsBackToAnArabicFace() {
        let inter = db.face(fallbackFamily, "Regular")
        let cluster: [Unicode.Scalar] = ["\u{0628}", "\u{064E}"]
        let f = db.cascade(cluster, [inter], "Regular")
        if Fallback.coversCluster(f, cluster) { #expect(f.covers("\u{0628}")) }
    }

    @Test func fallingBackWithNothingLoadedStillAnswers() {
        let iso = FontDB(craftFontsDir: nil, systemFonts: false)
        #expect(!iso.cascade(["\u{10FFFD}"], [], "Regular").family.isEmpty)
        let f = iso.face("No Such Font Anywhere", "Regular")
        #expect(!f.family.isEmpty)
        #expect(!Shaper.shapeLogical(f, scalars("Hello")).isEmpty)
    }

    @Test func ligatureCaretsNeverFail() {
        let face = db.face(fallbackFamily, "Regular")
        for gid: UInt32 in [0, 1, 100, .max] {
            let c = face.ligatureCarets(gid)
            #expect(zip(c, c.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test func emojiClustersAreRecognised() {
        for yes in ["😀", "👍🏽", "❤\u{FE0F}", "👨\u{200D}👩\u{200D}👧", "🇯🇵", "🏳\u{FE0F}\u{200D}🌈", "⭐", "✅", "☔", "⌚", "⏩", "🀄"] {
            #expect(Fallback.isEmojiCluster(scalars(yes)), "\(yes)")
        }
        for no in ["a", "1", "❤", "☺\u{FE0E}", "😀\u{FE0E}", "字", "→", "♥", "✔", "☎", "⬆", "▶", "1\u{FE0F}\u{20E3}", "#\u{20E3}"] {
            #expect(!Fallback.isEmojiCluster(scalars(no)), "\(no)")
        }
    }

    @Test func colourFontsAreRecognised() throws {
        let bytes = try #require(deckcraftFixture("render", "colr-squares.ttf"), "no deckcraft checkout")
        let iso = FontDB(craftFontsDir: nil, systemFonts: false)
        #expect(iso.addFont(bytes) > 0)
        #expect(iso.face("DeckCraft Colr Squares", "Regular").isColor)
        #expect(!db.face(fallbackFamily, "Regular").isColor)
    }

    @Test func lineSplitFollowsTheWindowsAscentAndDescent() throws {
        let f = db.face(fallbackFamily, "Regular")
        let os2 = SFNT.table(f.emFont, "OS/2")
        let (a, d) = (Double(os2.u16(74) ?? 0), Double(os2.u16(76) ?? 0))
        let want = (a + d) > 1.5 * f.upem ? 0.81 : a / (a + d)
        #expect(abs(f.lineSplit - want.clamped(0.5, 1)) < 1e-9, "\(f.lineSplit) vs \(want)")
        #expect(f.lineSplit > 0.5 && f.lineSplit < 1)
    }

    @Test func concurrentLookupsAllFindAnInstalledFamily() {
        // Threads resolving an installed family nobody had loaded yet fell back to another face when a
        // different thread was still loading it.
        let family = ["Georgia", "Verdana", "Times New Roman", "Helvetica Neue"].first { db.hasFamily($0) } ?? "Helvetica"
        for _ in 0 ..< 10 {
            let fresh = FontDB(craftFontsDir: nil, systemFonts: true)
            let got = Mutex<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let f = fresh.face(family, "Regular").family
                got.withLock { $0.append(f) }
            }
            #expect(got.withLock { $0 }.allSatisfy { rustASCIILowercase($0) == rustASCIILowercase(family) }, "\(got.withLock { $0 })")
        }
    }

    @Test func windowsFamilyNamesFindTheirFaces() throws {
        let bytes = try #require(deckcraftFixture("fonts", "legacy-semibold.ttf"), "no deckcraft checkout")
        let iso = FontDB(craftFontsDir: nil, systemFonts: false)
        #expect(iso.addFont(bytes) == 1)
        #expect(iso.hasFamily("DeckCraft Legacy Semibold"))
        for style in ["Regular", "Bold"] {
            let f = iso.face("DeckCraft Legacy Semibold", style)
            #expect(f.family == "DeckCraft Legacy" && f.style == "Semibold", "\(style)")
        }
        #expect(iso.documentFace("DeckCraft Legacy Semibold", "Regular").family == "DeckCraft Legacy", "installed, so not Calibri")
        #expect(iso.face("DeckCraft Legacy", "Semibold").style == "Semibold")
    }

    /// `documentFace` keeps its answers, and the fallback order is kept too; adding a font clears both, so a family
    /// that was missing is found once it arrives (an embedded font, after the slide asked for it).
    @Test func aFontAddedAfterALookupIsFound() throws {
        let bytes = try #require(deckcraftFixture("fonts", "legacy-semibold.ttf"), "no deckcraft checkout")
        let iso = FontDB(craftFontsDir: nil, systemFonts: false)
        // With nothing loaded, the lookup settles on a last-resort face, the only one there is.
        let before = iso.documentFace("DeckCraft Legacy Semibold", "Regular")
        #expect(before.family != "DeckCraft Legacy")
        #expect(iso.fallback(for: "A", excluding: before.id) == nil)
        #expect(iso.addFont(bytes) == 1)
        #expect(iso.documentFace("DeckCraft Legacy Semibold", "Regular").family == "DeckCraft Legacy")
        #expect(iso.fallback(for: "A", excluding: before.id)?.family == "DeckCraft Legacy")
    }

    @Test func missingDocumentFontsAreDrawnInCalibri() {
        for missing in ["Qqq Nonexistent", "Avenir Next Qqq", "", "Arimo Qqq"] {
            #expect(db.documentFace(missing, "Bold").family == db.face(missingFontFamily, "Bold").family, "\(missing)")
        }
        for (missing, twin) in [("Liberation Sans", "Arial"), ("Liberation Serif", "Times New Roman"), ("Arial CE", "Arial"), ("Times New Roman CYR", "Times New Roman")]
            where !db.hasFamily(missing)
        {
            #expect(db.documentFace(missing, "Regular").family == db.face(twin, "Regular").family, "\(missing)")
        }
        for kept in ["Arial", "Times New Roman", "Cambria", "Courier New", fallbackFamily, "Aptos", "Aptos Display", "Grandview"] {
            #expect(db.documentFace(kept, "Regular").family == db.face(kept, "Regular").family, "\(kept)")
        }
    }

    @Test func officeFontsHaveSubstitutes() {
        #expect(FontDB.substitutes("Calibri").contains("Carlito"))
        #expect(FontDB.substitutes("Cambria").contains("Caladea"))
        #expect(FontDB.substitutes("Times New Roman").contains("Liberation Serif"))
        #expect(FontDB.substitutes("Aptos").contains("Inter"))
        #expect(FontDB.substitutes("zzz").isEmpty)
    }

    /// An Embedded OpenType header of `version` around `font`, with the font at the end.
    func wrapEOT(_ font: [UInt8], _ version: UInt32) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 82)
        func put(_ v: UInt32, _ at: Int) { for i in 0 ..< 4 { h[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) } }
        put(UInt32(82 + font.count), 0)
        put(UInt32(font.count), 4)
        put(version, 8)
        h[34] = 0x4C
        h[35] = 0x50
        return h + font
    }

    @Test func embeddedOpenTypeYieldsTheFont() throws {
        let font = try #require(deckcraftFixture("fonts", "legacy-regular.ttf"), "no deckcraft checkout")
        #expect(embeddedSFNT(font).map(Array.init) == font)
        #expect(embeddedSFNT(wrapEOT(font, 0x0002_0001)).map(Array.init) == font)
        #expect(embeddedSFNT(wrapEOT(font, 0x0001_0000)).map(Array.init) == font)
        #expect(embeddedSFNT(Array("not a font file".utf8)) == nil)
        #expect(embeddedSFNT(wrapEOT(Array("hello world!!".utf8), 0x0002_0002)) == nil)
        #expect(embeddedSFNT(Array(wrapEOT(font, 0x0002_0001).prefix(40))) == nil)
    }

    @Test func outlinesAndMetrics() {
        let face = db.face(fallbackFamily, "Regular")
        #expect(face.ascent > 0 && face.descent > 0)
        #expect(SFNT.hasOutlines(face.emFont))
        #expect(face.glyph(for: "O") != 0)
    }

    /// When craft-fonts is there, the catalogue carries its Latin faces; `CRAFT_FONTS_REQUIRED` makes their
    /// absence a failure.
    @Test func craftFontsLatinWhenPresent() {
        let required = ProcessInfo.processInfo.environment["CRAFT_FONTS_REQUIRED"] != nil
        guard db.bundledScripts.contains(where: { $0.family == "Inter" }) else {
            #expect(!required, "CRAFT_FONTS_REQUIRED but no Inter in craft-fonts")
            return
        }
        // The bundled faces alone, as deckcraft checks them (an installed Calibri or Aptos would win).
        let bundled = FontDB(craftFontsDir: FontDB.defaultCraftFontsDir(), systemFonts: false)
        let r = bundled.face("Inter", "Regular")
        let b = bundled.face("Inter", "Bold")
        #expect(r.family == "Inter" && r.style == "Regular")
        #expect(b.family == "Inter" && b.style == "Bold")
        #expect(r !== b && b.weight > r.weight)
        #expect(bundled.face("Aptos", "Regular").family == "Inter")
        if bundled.bundledScripts.contains(where: { $0.family == "Carlito" }) { #expect(bundled.face("Calibri", "Bold").family == "Carlito") }
    }
}

@Suite struct ShaperTests {
    @Test func shapingProducesClustersAndAdvances() {
        let g = Shaper.shapeLogical(db.face(fallbackFamily, "Regular"), scalars("Hello"))
        #expect(g.count == 5)
        #expect(g.map(\.cluster) == [0, 1, 2, 3, 4])
        #expect(g.allSatisfy { $0.xAdvance > 0 && $0.gid != 0 })
    }

    @Test func rtlItemsComeInVisualOrderAndMirror() {
        let face = db.face(fallbackFamily, "Regular")
        let g = Shaper.shape(face, scalars("(ab)"), rtl: true, kern: true, ligatures: true, lang: nil)
        #expect(g.map(\.cluster) == [3, 2, 1, 0])
        // L4: in a right-to-left run "(" is drawn with the ")" glyph and vice versa.
        if face.covers("("), face.covers(")"), g.count == 4 {
            #expect(g[3].gid == face.glyph(for: ")"))
            #expect(g[0].gid == face.glyph(for: "("))
        }
    }

    @Test func clustersAreGraphemeMergedAndMonotone() throws {
        // CoreText indexes each character; deckcraft's clusters (HarfRust's monotone graphemes) put a
        // combining mark in its base's cluster.
        var f = bidiSetup([Run("e\u{0301}x")], 2000, false, .left)
        f.body.paragraphs[0].runs[0].props.size = 20
        let l = f.lay(2000, 300)
        let line = l.lines[0]
        #expect(line.boundary == [true, false, true])
        #expect(line.edges[1].right - line.edges[1].left == 0, "no advance inside a grapheme")
    }
}

@Suite struct ScriptTests {
    @Test func scriptsAndSlots() {
        #expect(Script.of("س") == "Arab" && Script.of("ש") == "Hebr" && Script.of("R") == "Latn")
        #expect(Script.of("2") == nil && Script.of("(") == nil)
        #expect(Script.of("\u{064E}") == nil && Script.of("\u{0640}") == nil)
        #expect(Script.slot(of: "س") == .complexScript)
        #expect(Script.slot(of: "日") == .eastAsian && Script.slot(of: "、") == .eastAsian)
        #expect(Script.slot(of: "a") == .latin && Script.slot(of: " ") == nil)
        #expect(Script.of("\u{10FFFF}") == nil && Script.of("\0") == nil)
    }

    @Test func neutralsTakeTheSurroundingSlot() {
        let chars = scalars(mixed)
        let r = Script.resolve(chars)
        for i in 0 ..< 10 { #expect(r[i].slot == .complexScript, "\(chars[i])") }
        #expect(r[10].slot == .latin && r[17].slot == .latin)
        #expect(r[19].script == "Arab" && r[19].slot == .complexScript)
        #expect(Script.resolve(["(", "س"])[0].slot == .complexScript)
        #expect(Script.resolve([]).isEmpty)
        #expect(Script.resolve(["1"])[0].script == nil && Script.resolve(["1"])[0].slot == .latin)
    }

    @Test func joiningClasses() {
        #expect(Script.joinsFollowing("س") && Script.joinsFollowing("ن"))
        #expect(!Script.joinsFollowing("ا") && !Script.joinsFollowing("د") && !Script.joinsFollowing("ء"))
        #expect(Script.joinsPreceding("ا") && !Script.joinsPreceding("ء"))
        #expect(!Script.joinsFollowing("a"))
    }
}

@Suite struct BidiUnitTests {
    @Test func mixedArabicLatinNumbersAndBrackets() {
        let chars = scalars(mixed)
        let l = Bidi.levels(chars, true)
        #expect(l.count == chars.count)
        #expect(l[0] == 1 && Array(l[4 ..< 8]) == [2, 2, 2, 2] && Array(l[10 ..< 17]) == Array(repeating: 2, count: 7) && l[19] == 1)
        #expect(l[9] % 2 == 1 && l[17] % 2 == 1)
        let order = Bidi.visualOrder(Bidi.lineLevels(chars, l, 1))
        #expect(String(String.UnicodeScalarView(order.map { chars[$0] })) == "طقف )Retrait( 2024 ةنس")
    }

    @Test func ltrParagraphFastPathAndEmbeddedRTL() {
        #expect(Bidi.levels(scalars("Hello 123"), false) == Array(repeating: 0, count: 9))
        let chars = scalars("ab سن cd")
        let l = Bidi.levels(chars, false)
        #expect(l == [0, 0, 0, 1, 1, 0, 0, 0])
        #expect(String(String.UnicodeScalarView(Bidi.visualOrder(l).map { chars[$0] })) == "ab نس cd")
        #expect(Bidi.levels(scalars("ab"), true) == [2, 2])
    }

    func visLang(_ s: String, _ rtl: Bool, _ rtlLang: Bool) -> String {
        let chars = scalars(s)
        let l = Bidi.levelsLang(chars, rtl, Array(repeating: rtlLang, count: chars.count))
        return String(String.UnicodeScalarView(Bidi.visualOrder(Bidi.lineLevels(chars, l, rtl ? 1 : 0)).map { chars[$0] }))
    }

    @Test func runLanguageDecidesNeutralsLikePowerPoint() {
        #expect(visLang("x אב גד y", false, false) == "x  דג באy")
        #expect(visLang("אב גד x y", false, false) == " דג באx y")
        #expect(visLang("x אב, גד! y", false, false) == "x בא, דג! y")
        #expect(visLang("אב 12", false, false) == " בא12")
        #expect(visLang("אב גד x y", false, true) == " דג באx y")
        #expect(visLang("12 אב 34 x", false, true) == " 34 בא 12x")
        #expect(visLang("x אב, גד! y", false, true) == "x !דג ,בא y")
        #expect(visLang("Version 2.0 ok", false, true) == "Version 2.0 ok")
        #expect(visLang("Hello world.", true, false) == "Hello world.")
        #expect(visLang("אב 45.6% גד", false, true) == "דג 45.6% בא")
        #expect(Bidi.levelsLang(scalars("plain, text"), false, Array(repeating: false, count: 11)) == Array(repeating: 0, count: 11))
        #expect(Bidi.isRTLLang("he-IL") && Bidi.isRTLLang("ar") && Bidi.isRTLLang("FA-ir") && !Bidi.isRTLLang("en-US") && !Bidi.isRTLLang(""))
    }

    @Test func l1ResetsTrailingWhitespaceAndTabs() {
        #expect(Bidi.lineLevels(scalars("ab\tcd  "), [2, 2, 2, 2, 2, 2, 2], 1) == [2, 2, 1, 2, 2, 1, 1])
        #expect(Bidi.lineLevels(["a", "b"], [], 1) == [1, 1])
    }

    @Test func nextNonETPointsPastEachETRun() {
        #expect(Bidi.nextNonET(scalars("a$$1%").map(bidiClass)) == [3, 3, 3, nil, nil])
    }

    @Test func currencySignsJoinNumbersOnEitherSideInRTLRuns() throws {
        let chars = scalars("שלום $$5 5%% $$")
        let l = Bidi.levelsLang(chars, true, Array(repeating: true, count: chars.count))
        let num = l[try #require(chars.firstIndex(of: "5"))]
        #expect(Array(l[5 ..< 8]) == [num, num, num], "\(l)")
        #expect(Array(l[9 ..< 12]) == [num, num, num], "\(l)")
        #expect(l[13] % 2 == 1 && l[13] != num)
    }

    @Test func longCurrencyAndNeutralRunsAreLinear() {
        let n = 200_000
        let dollars: [Unicode.Scalar] = ["ש"] + Array(repeating: "$", count: n)
        #expect(Bidi.levelsLang(dollars, true, Array(repeating: true, count: n + 1)).allSatisfy { $0 % 2 == 1 })
        let s = Array(String(repeating: "! ", count: n / 2).unicodeScalars)
        #expect(Bidi.levelsLang(s, true, (0 ..< n).map { $0 % 2 == 0 }).count == n)
    }

    @Test func visualOrderEdgeCases() {
        #expect(Bidi.visualOrder([]).isEmpty)
        #expect(Bidi.visualOrder([0, 0]) == [0, 1])
        #expect(Bidi.visualOrder([1, 1, 1]) == [2, 1, 0])
        #expect(Bidi.visualOrder([1, 2, 2, 1]) == [3, 1, 2, 0])
        #expect(Bidi.visualOrder([125, 125]) == [1, 0])
    }
}

@Suite struct DateTimeTests {
    let fri = DateTime(2026, 10, 9, 20, 5, 7)

    @Test func englishFormatsOfEveryType() {
        func f(_ k: String) -> String? { DateFields.fieldText(k, "en-US", fri) }
        #expect(f("datetime1") == "10/9/2026")
        #expect(f("datetime2") == "Friday, October 9, 2026")
        #expect(f("datetime3") == "9 October 2026")
        #expect(f("datetime4") == "October 9, 2026")
        #expect(f("datetime5") == "9-Oct-26")
        #expect(f("datetime6") == "October 26")
        #expect(f("datetime7") == "Oct-26")
        #expect(f("datetime8") == "10/9/2026 8:05 PM")
        #expect(f("datetime9") == "10/9/2026 8:05:07 PM")
        #expect(f("datetime10") == "20:05")
        #expect(f("datetime11") == "20:05:07")
        #expect(f("datetime12") == "8:05 PM")
        #expect(f("datetime13") == "8:05:07 PM")
        #expect(f("datetimeFigureOut") == "10/9/2026")
        #expect(f("datetime") == "10/9/2026")
        #expect(DateFields.fieldText("datetime12", nil, DateTime(2024, 2, 29, 0, 0, 0)) == "12:00 AM")
        #expect(DateFields.fieldText("datetime12", nil, DateTime(2024, 2, 29, 12, 30, 0)) == "12:30 PM")
        #expect(DateFields.fieldText("datetime2", nil, DateTime(2000, 1, 1, 0, 0, 0)) == "Saturday, January 1, 2000")
    }

    @Test func languageOrdersNumericDatesAndKeepsNamesEnglishOnly() {
        #expect(DateFields.fieldText("datetime1", "en-GB", fri) == "09/10/2026")
        #expect(DateFields.fieldText("datetimeFigureOut", "de-DE", fri) == "09.10.2026")
        #expect(DateFields.fieldText("datetime1", "ja-JP", fri) == "2026/10/9")
        #expect(DateFields.fieldText("datetime1", "sv-SE", fri) == "2026-10-09")
        #expect(DateFields.fieldText("datetime10", "fr-FR", fri) == "20:05")
        #expect(DateFields.fieldText("datetime2", "de-DE", fri) == nil)
        #expect(DateFields.fieldText("datetime12", "fr-FR", fri) == nil)
        #expect(DateFields.fieldText("datetime4", "en-GB", fri) == "October 9, 2026")
    }

    @Test func unknownTypesAndImpossibleDatesGiveNothing() {
        #expect(DateFields.fieldText("slidenum", nil, fri) == nil)
        #expect(DateFields.fieldText("datetime14", nil, fri) == nil)
        for bad in [
            DateTime(2026, 0, 9, 0, 0, 0), DateTime(2026, 13, 9, 0, 0, 0), DateTime(2026, 2, 29, 0, 0, 0), DateTime(2026, 4, 31, 0, 0, 0),
            DateTime(2026, 1, 1, 24, 0, 0), DateTime(.min, 1, 1, 0, 0, 0), DateTime(.max, .max, .max, .max, .max, .max),
        ] {
            #expect(DateFields.fieldText("datetime2", nil, bad) == nil, "\(bad)")
        }
        #expect(DateFields.isDateField("datetimeFigureOut") && !DateFields.isDateField("slidenum"))
        #expect(DateFields.dateKinds.count == 13 && DateFields.dateKinds.first == "datetime1")
    }

    @Test func theClockReadsARealDate() throws {
        let now = try #require(DateTime.nowLocal())
        #expect(DateFields.fieldText("datetime1", nil, now) != nil)
    }
}
