// DCRenderTests — render parity: every slide of every corpus deck, rendered at the oracle's scale (2),
// scored by SSIMULACRA2 against the Rust oracle's PNG. The scores are written to
// `.build-parity/render-parity/report-<deck>.json` with both images of every slide under its threshold, for
// looking at side by side (`DECKCRAFT_PARITY_OUT` moves it).
import CoreGraphics
import DCFormat
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCRender

private struct SlideScore: Codable {
    var deck: String
    var slide: Int
    var score: Double?
    var differing: Double?
}

private var outDir: URL {
    if let env = ProcessInfo.processInfo.environment["DECKCRAFT_PARITY_OUT"], !env.isEmpty { return URL(filePath: env) }
    return Fixtures.repositoryRoot.appending(path: ".build-parity/render-parity", directoryHint: .isDirectory)
}

/// The corpus decks with oracle renders: each `<name>.deckcraft` and `<name>.from-pptx.deckcraft` beside
/// its `.render` folder.
private func corpusDecks() -> [(name: String, deck: URL, renders: URL)] {
    guard let corpus = Fixtures.oracleCorpus else { return [] }
    let decks = corpus.appending(path: "decks", directoryHint: .isDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: decks.path)) ?? []
    return names.filter { $0.hasSuffix(".deckcraft") }.sorted().compactMap { file in
        let base = String(file.dropLast(".deckcraft".count))
        let renders = decks.appending(path: "\(base).render", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: renders.path) else { return nil }
        return (base, decks.appending(path: file), renders)
    }
}

/// The lowest score a slide of `deck` may have: a little under the worst slide measured (2026-10-26:
/// 90.6–100 on every deck, under 0.6% of pixels more than 8 levels apart), so a regression shows. The
/// report says where each deck stands.
private func threshold(_ deck: String) -> Double {
    88
}

@Suite struct RenderParityTests {
    /// One deck per test case, so decks run in parallel; each writes `report-<deck>.json`.
    @Test(arguments: corpusDecks().map(\.name)) func deckMatchesOracle(_ name: String) throws {
        guard let d = corpusDecks().first(where: { $0.name == name }) else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report: [SlideScore] = []
        let bytes = try [UInt8](Data(contentsOf: d.deck))
        let pres = try DeckFormat.load(bytes)
        for i in pres.slides.indices {
            let png = d.renders.appending(path: String(format: "slide-%02d.png", i + 1))
            guard let reference = RenderParity.load(png) else {
                Issue.record("\(d.name) slide \(i + 1): no oracle PNG")
                continue
            }
            let image = renderSlide(pres, i, RenderOpts(scale: 2))
            guard let mine = image.cgImage() else {
                Issue.record("\(d.name) slide \(i + 1): nothing rendered")
                continue
            }
            let score = RenderParity.score(reference: reference, distorted: mine)
            let differing = RenderParity.differingPixels(reference, mine)
            report.append(SlideScore(deck: d.name, slide: i + 1, score: score, differing: differing))
            if (score ?? -.infinity) < threshold(d.name) + 20 {
                let stem = "\(d.name)-slide-\(String(format: "%02d", i + 1))"
                RenderParity.writePNG(mine, to: outDir.appending(path: "\(stem).swift.png"))
                RenderParity.writePNG(reference, to: outDir.appending(path: "\(stem).oracle.png"))
            }
            #expect((score ?? -.infinity) >= threshold(d.name), "\(d.name) slide \(i + 1): SSIMULACRA2 \(score.map { String(format: "%.1f", $0) } ?? "n/a")")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: outDir.appending(path: "report-\(d.name).json"))
    }

    @Test func corpusIsPresent() {
        #expect(!corpusDecks().isEmpty, "no oracle corpus: run Tools/oracle/oracle.sh corpus")
    }
}
