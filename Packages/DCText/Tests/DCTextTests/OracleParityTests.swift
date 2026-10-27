// DCTextTests — parity with deckcraft-text. Tools/oracle/text-vectors lays out every text body of the
// oracle corpus decks and of a synthetic deck with the pinned deckcraft and writes the decks' models and
// the layouts to DeckCraftNative-Fixtures/text/; this lays out the same bodies and compares.
//
// Line breaks must match exactly for the Latin bodies of the corpus decks, and their baselines and extents
// within `tolerance`. Everything else (the synthetic deck's scripts, fonts and features) is measured and
// reported, not asserted: CoreText shapes where deckcraft runs HarfRust, so advances can differ by a
// fraction of a point and a line can break one word earlier or later (PORT-NOTES.md).
import DCCore
import DCGeometry
import DCModel
@testable import DCText
import DCTestSupport
import Foundation
import Testing

@Suite struct OracleParityTests {
    /// Points: the largest baseline or extent difference accepted on the Latin corpus bodies.
    static let tolerance = 0.5

    struct Body {
        var deck: String
        var slide: Int
        var path: [Int]
        var rect: Rect
        var text: String
        var fontScale: Double
        var lines: [[Double]]
        var runs: [JSON]
    }

    static var dir: URL { Fixtures.root.appending(path: "text", directoryHint: .isDirectory) }

    static func number(_ j: JSON?) -> Double? {
        switch j {
        case .double(let v)?: v
        case .uint(let v)?: Double(v)
        case .int(let v)?: Double(v)
        case .float(let v)?: Double(v)
        default: nil
        }
    }

    static func array(_ j: JSON?) -> [JSON] {
        if case .array(let a)? = j { return a }
        return []
    }

    static func string(_ j: JSON?) -> String? {
        if case .string(let s)? = j { return s }
        return nil
    }

    static func bodies() -> [Body]? {
        guard let data = try? Data(contentsOf: dir.appending(path: "vectors.json")), let doc = try? JSONParser.parse([UInt8](data)) else { return nil }
        return array(doc["bodies"]).compactMap { b in
            guard let deck = string(b["deck"]), let slide = number(b["slide"]) else { return nil }
            let r = array(b["rect"]).compactMap { number($0) }
            guard r.count == 4 else { return nil }
            return Body(
                deck: deck, slide: Int(slide), path: array(b["path"]).compactMap { number($0).map { Int($0) } }, rect: Rect(r[0], r[1], r[2], r[3]),
                text: string(b["text"]) ?? "", fontScale: number(b["font_scale"]) ?? 1,
                lines: array(b["lines"]).map { array($0).compactMap { number($0) } }, runs: array(b["runs"])
            )
        }
    }

    static func deck(_ name: String) -> Presentation? {
        guard let data = try? Data(contentsOf: dir.appending(path: "decks/\(name).json")), let json = try? JSONParser.parse([UInt8](data)) else { return nil }
        return try? JSONDecoding.$nullFloatsAsZero.withValue(true) { try Presentation(fromJSON: json) }
    }

    static func shape(_ shapes: [Shape], _ path: [Int]) -> Shape? {
        guard let first = path.first, let s = shapes.at(first) else { return nil }
        if path.count == 1 { return s }
        if case .group(let children, _) = s.kind { return shape(children, Array(path.dropFirst())) }
        return nil
    }

    /// Latin text: nothing past Latin Extended-B but general punctuation, symbols and the like.
    static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value < 0x0250 || (0x2000 ... 0x206F).contains($0.value) || (0x20A0 ... 0x20CF).contains($0.value) || (0x2100 ... 0x214F).contains($0.value) }
    }

    struct Stats: CustomStringConvertible {
        var bodies = 0
        var linesSame = 0
        var breaksSame = 0
        var baselineMax = 0.0
        var baselineSum = 0.0
        var extentMax = 0.0
        var extentSum = 0.0
        var measured = 0
        var scaleSame = 0
        var runs = 0
        var runFamilySame = 0
        var runGlyphsSame = 0

        var description: String {
            let n = Swift.max(measured, 1)
            return "\(bodies) bodies: line breaks identical in \(breaksSame) (line counts in \(linesSame)), font scale in \(scaleSame); "
                + "\(measured) lines compared: baseline Δ max \(rustFixed(baselineMax, places: 3)) mean \(rustFixed(baselineSum / Double(n), places: 3)) pt, "
                + "extent Δ max \(rustFixed(extentMax, places: 3)) mean \(rustFixed(extentSum / Double(n), places: 3)) pt; "
                + "runs: \(runFamilySame)/\(runs) same family, \(runGlyphsSame)/\(runs) same glyph count"
        }
    }

    @Test func layoutsMatchDeckcraft() throws {
        guard let bodies = Self.bodies() else {
            print("text parity: no vectors at \(Self.dir.path) (run Tools/oracle/text-vectors)")
            return
        }
        var decks: [String: Presentation] = [:]
        var latin = Stats()
        var other = Stats()
        var divergences: [String] = []
        for b in bodies {
            if decks[b.deck] == nil { decks[b.deck] = Self.deck(b.deck) }
            let p = try #require(decks[b.deck], "deck \(b.deck)")
            let slide = try #require(p.slides.at(b.slide))
            let shape = try #require(Self.shape(slide.shapes, b.path))
            let ctx = try #require(Resolve.Ctx.forSlide(p, slide))
            let body = try #require(shape.text)
            let l = TextLayoutEngine.layout(ctx, shape, body, TextOpts(rect: b.rect))
            let strict = b.deck != "synthetic" && Self.isLatin(b.text)
            var s = strict ? latin : other
            s.bodies += 1
            let breaks = l.lines.map { [Double($0.para), Double($0.start), Double($0.end)] }
            let want = b.lines.map { Array($0.prefix(3)) }
            if breaks == want { s.breaksSame += 1 }
            if breaks.count == want.count { s.linesSame += 1 }
            if abs(l.fontScale - b.fontScale) < 1e-9 { s.scaleSame += 1 }
            if breaks != want {
                divergences.append("\(b.deck) slide \(b.slide) \(b.path): breaks \(breaks.map { $0.map { Int($0) } }) vs \(want.map { $0.map { Int($0) } }) — \(b.text.prefix(60))")
            }
            if strict { #expect(breaks == want, "\(b.deck) slide \(b.slide) \(b.path): \(b.text.prefix(60))") }
            for (li, w) in zip(l.lines, b.lines) where w.count == 8 && [Double(li.para), Double(li.start), Double(li.end)] == Array(w.prefix(3)) {
                let db = abs(li.baseline - w[4])
                let de = Swift.max(abs(li.extent.left - w[6]), abs(li.extent.right - w[7]))
                s.measured += 1
                s.baselineMax = Swift.max(s.baselineMax, db)
                s.baselineSum += db
                s.extentMax = Swift.max(s.extentMax, de)
                s.extentSum += de
                if strict {
                    #expect(db <= Self.tolerance && de <= Self.tolerance, "\(b.deck) slide \(b.slide) \(b.path) line \(li.start): baseline Δ \(db), extent Δ \(de)")
                }
            }
            for (r, w) in zip(l.runs, b.runs) {
                s.runs += 1
                if Self.string(w["family"]) == r.face.family { s.runFamilySame += 1 }
                if Self.number(w["n"]).map({ Int($0) }) == r.glyphs.count { s.runGlyphsSame += 1 }
            }
            if strict { latin = s } else { other = s }
        }
        print("text parity, Latin corpus: \(latin)")
        print("text parity, other: \(other)")
        for d in divergences { print("text parity divergence: \(d)") }
        #expect(latin.bodies > 0)
    }

    /// Items shaped directly: deckcraft-fonts' `shape_range` (HarfRust) against `Shaper` (CoreText). Reported,
    /// and the Latin samples must agree glyph for glyph with advances within a font unit.
    @Test func shapingMatchesHarfRustForLatin() throws {
        guard let data = try? Data(contentsOf: Self.dir.appending(path: "vectors.json")), let doc = try? JSONParser.parse([UInt8](data)) else { return }
        for sample in Self.array(doc["shapes"]) {
            guard let family = Self.string(sample["family"]), let text = Self.string(sample["text"]) else { continue }
            let rtl = sample["rtl"] == .bool(true)
            let latin = sample["latin"] == .bool(true)
            let script = Self.string(sample["script"])
            let want = Self.array(sample["glyphs"]).map { Self.array($0).compactMap { Self.number($0) } }
            let face = db.face(family, "Regular")
            guard face.family == family else {
                print("shaping parity: \(family) not available here")
                continue
            }
            let got = Shaper.shape(face, Array(text.unicodeScalars), rtl: rtl, kern: false, ligatures: !latin, lang: script.flatMap(Script.defaultLanguage), script: script)
            let sameGlyphs = got.map { Double($0.gid) } == want.map { $0[0] }
            let sameClusters = got.map { Double($0.cluster) } == want.map { $0[1] }
            let width = got.map(\.xAdvance).reduce(0, +)
            let wantWidth = want.map { $0[2] }.reduce(0, +)
            print("shaping parity: \(family) \(script ?? "-"): \(got.count)/\(want.count) glyphs, ids \(sameGlyphs ? "same" : "differ"), clusters \(sameClusters ? "same" : "differ"), width \(Int(width)) vs \(Int(wantWidth)) units")
            if latin {
                #expect(sameGlyphs && sameClusters, "\(family): \(text)")
                #expect(abs(width - wantWidth) <= Double(want.count), "\(family): \(width) vs \(wantWidth)")
            }
        }
    }
}
