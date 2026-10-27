// Port of deckcraft crates/pptx/tests/it/sample.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The engine's sample deck: export, re-import, compare. Set `DECKCRAFT_PPTX_OUT=<dir>` to
// also write the exported file there (for checking it in other applications).
//
// `open_sample` is the corpus's `sample.deckcraft` (`IT.sample()`), which deckcraft saved from it at the pin.
import DCModel
import Foundation
import Testing
@testable import DCPPTX

@Suite struct IntegrationSampleTests {
    // Rust: it/sample.rs::sample_deck_round_trips
    @Test(.enabled(if: IT.hasCorpus)) func sampleDeckRoundTrips() throws {
        let p = try #require(try IT.sample())
        let bytes = try PPTX.export(p)
        if let dir = IT.env("DECKCRAFT_PPTX_OUT") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(bytes).write(to: URL(filePath: "\(dir)/sample.pptx"))
        }
        #expect(PPTX.sniff(bytes))
        let q = try PPTX.import(bytes)
        #expect(q.slides.count == p.slides.count)
        #expect(q.validate().isEmpty, "\(q.validate())")
        for (a, b) in zip(p.slides, q.slides) {
            #expect(a.title == b.title)
            #expect(a.notesText == b.notesText)
            #expect(a.shapes.count == b.shapes.count, "shape count on slide '\(a.title)'")
            for (sa, sb) in zip(a.shapes, b.shapes) {
                #expect(sa.kindName == sb.kindName, "\(sa.name)")
                #expect(sa.text.map(\.text) == sb.text.map(\.text), "\(sa.name)")
                if let x = sa.xfrm, let y = sb.xfrm {
                    #expect(abs(x.x - y.x) < 0.01 && abs(x.w - y.w) < 0.01, "\(sa.name): \(x) vs \(y)")
                }
                if case .table(let ta) = sa.kind, case .table(let tb) = sb.kind {
                    #expect(ta.style == tb.style)
                    #expect(ta.rows.count == tb.rows.count)
                }
                if case .chart(let ca) = sa.kind, case .chart(let cb) = sb.kind {
                    #expect(ca.kind == cb.kind)
                    #expect(ca.categories == cb.categories)
                    #expect(ca.series.count == cb.series.count)
                    for (x, y) in zip(ca.series, cb.series) {
                        #expect(x.name == y.name)
                        #expect(x.values == y.values)
                    }
                }
            }
            #expect(a.transition?.kind == b.transition?.kind && a.transition?.option == b.transition?.option)
            #expect(a.animations.count == b.animations.count, "animations on '\(a.title)'")
            for (x, y) in zip(a.animations, b.animations) {
                #expect(x.effect == y.effect && x.class == y.class && x.start == y.start)
                #expect(x.durationMs == y.durationMs && x.delayMs == y.delayMs && x.textBuild == y.textBuild)
                #expect(x.shape == y.shape)
            }
        }
        #expect(q.sections.count == p.sections.count)
        for (a, b) in zip(p.sections, q.sections) {
            #expect(a.name == b.name)
            #expect(a.slides.count == b.slides.count)
        }
        // A second round trip is stable.
        let bytes2 = try PPTX.export(q)
        let r = try PPTX.import(bytes2)
        #expect(r.slides.count == q.slides.count)
    }

    // Rust: it/sample.rs::external_file_imports
    /// Reads any file named by `DECKCRAFT_PPTX_IN` (for checking decks made by other applications).
    @Test func externalFileImports() throws {
        guard let path = IT.env("DECKCRAFT_PPTX_IN") else { return }
        let bytes = try [UInt8](Data(contentsOf: URL(filePath: path)))
        let p = try PPTX.import(bytes)
        print("\(path): \(p.slides.count) slides, \(p.masters.count) masters, \(p.masters.reduce(0) { $0 + $1.layouts.count }) layouts")
        for (i, s) in p.slides.enumerated() {
            let kinds = s.shapes.map(\.kindName)
            print("  slide \(i + 1): title \(s.title) shapes \(kinds) layout \(p.layout(s.layout).map(\.layout.name) ?? "nil")")
        }
        #expect(p.validate().isEmpty)
        let again = try PPTX.import(PPTX.export(p))
        #expect(again.slides.count == p.slides.count)
        if let dir = IT.env("DECKCRAFT_PPTX_OUT") {
            try Data(PPTX.export(p)).write(to: URL(filePath: "\(dir)/reexport.pptx"))
        }
    }
}
