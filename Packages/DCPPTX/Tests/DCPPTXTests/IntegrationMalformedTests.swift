// Port of deckcraft crates/pptx/tests/it/malformed.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Hostile input: the importer must return `Err` or a usable presentation, never crash.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationMalformedTests {
    private static func valid() throws -> [UInt8] {
        try PPTX.export(newPresentation(nil))
    }

    private static func isErr(_ bytes: [UInt8]) -> Bool {
        (try? PPTX.import(bytes)) == nil
    }

    // Rust: it/malformed.rs::random_bytes_and_empty
    @Test func randomBytesAndEmpty() {
        #expect(Self.isErr([]))
        #expect(Self.isErr(Array("PK\u{03}\u{04}garbage".utf8)))
        var seed: UInt64 = 7
        for len in [1, 10, 100, 1000, 10000] {
            let v: [UInt8] = (0 ..< len).map { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
            #expect(Self.isErr(v))
        }
    }

    // Rust: it/malformed.rs::truncated_zip
    @Test func truncatedZip() throws {
        let v = try Self.valid()
        for cut in [10, v.count / 4, v.count / 2, v.count - 30, v.count - 1] {
            _ = try? PPTX.import(Array(v[..<cut]))
        }
    }

    // Rust: it/malformed.rs::zip_without_presentation
    @Test func zipWithoutPresentation() throws {
        let z = try IT.zip([(name: "[Content_Types].xml", data: Array("<Types/>".utf8)), (name: "hello.txt", data: Array("hi".utf8))])
        #expect(Self.isErr(z))
    }

    // Rust: it/malformed.rs::missing_parts_still_import
    @Test func missingPartsStillImport() throws {
        let es = try IT.entries(Self.valid())
        // Drop each part in turn; import must not crash, and must succeed unless the main part is gone.
        for i in es.indices {
            var v = es
            let (name, _) = v.remove(at: i)
            let r = try? PPTX.import(IT.zip(v))
            if name == "ppt/presentation.xml" {
                #expect(r == nil)
            } else if let p = r {
                #expect(p.validate().isEmpty, "dropping \(name): \(p.validate())")
                // Whatever we read must export again.
                _ = try PPTX.export(p)
            }
        }
    }

    // Rust: it/malformed.rs::bad_xml_in_each_part
    @Test func badXMLInEachPart() throws {
        let es = try IT.entries(Self.valid())
        let bads: [[UInt8]] = [
            Array("<p:sld><unclosed".utf8), [0xFF, 0xFE, 0x00] + Array("garbage".utf8), [],
            Array("<?xml version=\"1.0\"?>".utf8), Array("<a:b c='1' c='2'/>".utf8),
        ]
        for i in es.indices {
            for bad in bads {
                var v = es
                v[i].data = bad
                if let p = try? PPTX.import(IT.zip(v)) {
                    _ = try PPTX.export(p)
                }
            }
        }
    }

    // Rust: it/malformed.rs::huge_numbers_and_nonsense_attributes
    @Test func hugeNumbersAndNonsenseAttributes() throws {
        var v = try IT.entries(Self.valid())
        for i in v.indices where v[i].name.hasSuffix(".xml") {
            let s = String(decoding: v[i].data, as: UTF8.self)
                .replace("x=\"", "x=\"99999999999999999999")
                .replace("cx=\"", "cx=\"-")
                .replace("sz=\"", "sz=\"1e309")
                .replace("rot=\"", "rot=\"NaN")
                .replace("idx=\"", "idx=\"4294967296")
                .replace("id=\"", "id=\"0")
            v[i].data = Array(s.utf8)
        }
        if let p = try? PPTX.import(IT.zip(v)) {
            for s in p.slides {
                walk(s.shapes) { sh, _ in
                    if let x = sh.xfrm {
                        #expect(x.isFinite)
                    }
                }
            }
            _ = try PPTX.export(p)
        }
    }

    // Rust: it/malformed.rs::deep_nesting_is_bounded
    @Test func deepNestingIsBounded() throws {
        var v = try IT.entries(Self.valid())
        let deep = "<?xml version=\"1.0\"?><p:sld xmlns:p=\"x\" xmlns:a=\"y\"><p:cSld><p:spTree>"
            + String(repeating: "<p:grpSp>", count: 200) + String(repeating: "</p:grpSp>", count: 200)
            + "</p:spTree></p:cSld></p:sld>"
        if let i = v.firstIndex(where: { $0.name == "ppt/slides/slide1.xml" }) { v[i].data = Array(deep.utf8) }
        let p = try PPTX.import(IT.zip(v))
        _ = try PPTX.export(p)
        // Beyond the XML depth limit the part is rejected, the deck still loads.
        let deeper = "<p:sld>" + String(repeating: "<a>", count: 5000) + "</p:sld>"
        if let i = v.firstIndex(where: { $0.name == "ppt/slides/slide1.xml" }) { v[i].data = Array(deeper.utf8) }
        _ = try? PPTX.import(IT.zip(v))
    }

    // Rust: it/malformed.rs::relationship_cycles_and_bad_targets
    @Test func relationshipCyclesAndBadTargets() throws {
        var v = try IT.entries(Self.valid())
        if let i = v.firstIndex(where: { $0.name == "ppt/slides/_rels/slide1.xml.rels" }) {
            v[i].data = Array(#"<Relationships xmlns="x"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../../../../../etc/passwd"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slide1.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="slide1.xml"/></Relationships>"#.utf8)
        }
        let p = try PPTX.import(IT.zip(v))
        #expect(p.slides.count == 1)
        #expect(p.validate().isEmpty)
    }

    // Rust: it/malformed.rs::fuzz_mutations
    /// Fixed-seed random byte mutations of a valid export (inside the zip entries, so the XML is hit).
    @Test(.enabled(if: IT.hasCorpus)) func fuzzMutations() throws {
        let p = try #require(try IT.sample())
        let es = try IT.entries(PPTX.export(p))
        var seed: UInt64 = 0x5EED
        func rnd(_ n: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(Swift.max(n, 1)))
        }
        #if DEBUG
            let iters = 300
        #else
            let iters = 2000
        #endif
        let inserts = Array("<>\"&=".utf8)
        for _ in 0 ..< iters {
            var v = es
            let k = rnd(v.count)
            var d = v[k].data
            for _ in 0 ..< 1 + rnd(8) {
                if d.isEmpty { break }
                let at = rnd(d.count)
                switch rnd(4) {
                case 0: d[at] = UInt8(truncatingIfNeeded: rnd(256))
                case 1: d.removeSubrange(at...)
                case 2: d.insert(inserts[rnd(5)], at: at)
                default:
                    let end = Swift.min(at + rnd(64), d.count)
                    d.removeSubrange(at ..< end)
                }
            }
            v[k].data = d
            if let q = try? PPTX.import(IT.zip(v)) {
                #expect(q.validate().isEmpty)
                _ = try PPTX.export(q)
            }
        }
        // Raw byte flips of the whole zip, too.
        let bytes = try PPTX.export(p)
        for _ in 0 ..< iters {
            var b = bytes
            for _ in 0 ..< 1 + rnd(16) {
                let at = rnd(b.count)
                b[at] = UInt8(truncatingIfNeeded: rnd(256))
            }
            _ = try? PPTX.import(b)
        }
    }

    // Rust: it/malformed.rs::zip_bomb_entry_is_capped
    @Test func zipBombEntryIsCapped() throws {
        // A highly compressible 64 MiB XML part: must import (or fail) without blowing up.
        let big = [UInt8](repeating: UInt8(ascii: " "), count: 64 * 1024 * 1024)
        var es = try IT.entries(Self.valid())
        es.append(("ppt/big.xml", big))
        let bytes = try IT.zip(es)
        #expect(bytes.count < 2 * 1024 * 1024)
        let p = try PPTX.import(bytes)
        #expect(p.slides.count == 1)
    }

    // Rust: it/malformed.rs::export_of_odd_models_is_valid
    @Test func exportOfOddModelsIsValid() throws {
        // No masters, dangling layout, duplicate and zero shape ids, NaN geometry, control characters.
        var p = newPresentation(nil)
        var s = Slide.default
        s.id = SlideId(9999)
        s.layout = LayoutId(12345)
        for id: UInt32 in [0, 1, 5, 5] {
            var sh = Shape.default
            sh.id = ShapeId(id)
            sh.name = "bad\u{0}name\u{b}"
            sh.xfrm = Xfrm(Double.nan, Double.infinity, -5.0, 1e300)
            sh.text = TextBody.fromText("tab\tand\u{1}control\nnew line")
            s.shapes.append(sh)
        }
        var opaque = Shape.default
        opaque.id = ShapeId(7)
        opaque.kind = .opaque(xml: "<not xml", preview: nil, label: "Thing", parts: [])
        s.shapes.append(opaque)
        p.slides.append(s)
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        #expect(q.slides.count == 2)
        #expect(q.validate().isEmpty, "\(q.validate())")
        var empty = p
        empty.masters.removeAll()
        let r = try PPTX.import(PPTX.export(empty))
        #expect(!r.masters.isEmpty)
    }

    // Rust: it/malformed.rs::unreadable_slide_is_reported
    /// A slide the file lists but that can't be read is left out, and `importChecked` names it where
    /// `import` would have said nothing (#203).
    @Test func unreadableSlideIsReported() throws {
        var p = newPresentation(nil)
        var second = try #require(p.slides.first, "a slide")
        second.id = SlideId(second.id.rawValue + 1000)
        p.slides.append(second)
        let bytes = try PPTX.export(p)

        let (q, lost) = try PPTX.importChecked(bytes)
        #expect(q.slides.count == 2 && lost.count == 0, "\(lost)")

        var es = try IT.entries(bytes)
        let i = try #require(es.firstIndex { $0.name == "ppt/slides/slide2.xml" }, "slide2")
        es[i].data = Array("<p:sld".utf8)
        let broken = try IT.zip(es)
        let (q2, lost2) = try PPTX.importChecked(broken)
        #expect(q2.slides.count == 1)
        #expect(lost2 == ["ppt/slides/slide2.xml"])
        #expect(try PPTX.import(broken).slides.count == 1)
    }
}
