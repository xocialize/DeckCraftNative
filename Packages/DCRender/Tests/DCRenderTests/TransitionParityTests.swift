// DCRenderTests — transition parity: every transition frame of the oracle corpus (`<deck>.transitions/
// slide-N-tT.png`, drawn by deckcraft-cli's `render-transition` at scale 2) and of the transitions deck
// (`Tools/oracle/engine-scripts/transitions.cmds`: every kind, and Morph by objects, words and characters;
// frames 640 px wide in `DeckCraftNative-Fixtures/anim/transitions/`, drawn by anim-vectors/run.sh), rendered
// by `renderTransition` and scored by SSIMULACRA2 against deckcraft's PNG. Scores go to
// `.build-parity/transition-parity/report-<deck>.json`, with both images of every frame within 20 points of
// the floor (`DECKCRAFT_PARITY_OUT` moves it). Run it in release: SSIMULACRA2 unoptimised takes minutes.
import CoreGraphics
import DCFormat
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCRender

private struct FrameScore: Codable {
    var deck: String
    var frame: String
    var score: Double?
    var differing: Double?
}

private var outDir: URL {
    if let env = ProcessInfo.processInfo.environment["DECKCRAFT_PARITY_OUT"], !env.isEmpty {
        return URL(filePath: env).appending(path: "transition-parity", directoryHint: .isDirectory)
    }
    return Fixtures.repositoryRoot.appending(path: ".build-parity/transition-parity", directoryHint: .isDirectory)
}

/// A deck with oracle transition frames: the deck, the folder of `slide-N-tT.png` frames and the width they
/// were drawn at (nil: scale 2).
private struct FrameSet {
    var name: String
    var deck: URL
    var frames: URL
    var width: Double?
}

private func frameSets() -> [FrameSet] {
    var out: [FrameSet] = []
    if let corpus = Fixtures.oracleCorpus {
        let decks = corpus.appending(path: "decks", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: decks.path)) ?? []
        for file in names.sorted() where file.hasSuffix(".deckcraft") {
            let base = String(file.dropLast(".deckcraft".count))
            let frames = decks.appending(path: "\(base).transitions", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: frames.path) {
                out.append(FrameSet(name: base, deck: decks.appending(path: file), frames: frames, width: nil))
            }
        }
    }
    let deck = Fixtures.root.appending(path: "engine/transitions.deckcraft")
    let frames = Fixtures.root.appending(path: "anim/transitions", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: deck.path), FileManager.default.fileExists(atPath: frames.path) {
        out.append(FrameSet(name: "transitions", deck: deck, frames: frames, width: 640))
    }
    return out
}

/// The lowest score a frame may have: a little under the worst frame measured (2026-10-26: 90.2 on the corpus
/// decks, 89.0 on the transitions deck, under 0.6% of pixels more than 8 levels apart). The report says
/// where each deck stands.
private func threshold(_ deck: String) -> Double {
    deck == "transitions" ? 87 : 88
}

/// `slide-12-t0.350.png` → (11, 0.35).
private func parseFrame(_ file: String) -> (index: Int, t: Double)? {
    guard file.hasPrefix("slide-"), file.hasSuffix(".png") else { return nil }
    let parts = file.dropFirst("slide-".count).dropLast(".png".count).split(separator: "-t")
    guard parts.count == 2, let n = Int(parts[0]), n >= 1, let t = Double(parts[1]) else { return nil }
    return (n - 1, t)
}

@Suite struct TransitionParityTests {
    /// One deck per test case, so decks run in parallel; each writes `report-<deck>.json`.
    @Test(arguments: frameSets().map(\.name)) func framesMatchOracle(_ name: String) throws {
        guard let set = frameSets().first(where: { $0.name == name }) else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let pres = try DeckFormat.load([UInt8](Data(contentsOf: set.deck)))
        let opts = RenderOpts(scale: set.width.map { $0 / pres.slideSize.width.rustMax(1) } ?? 2)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: set.frames.path)) ?? []).filter { parseFrame($0) != nil }.sorted()
        #expect(!files.isEmpty, "\(name): no frames")
        var report: [FrameScore] = []
        for file in files {
            guard let (i, t) = parseFrame(file), let reference = RenderParity.load(set.frames.appending(path: file)) else { continue }
            guard let mine = renderTransition(pres, i, t, opts).cgImage() else {
                Issue.record("\(name) \(file): nothing rendered")
                continue
            }
            let score = RenderParity.score(reference: reference, distorted: mine)
            let differing = RenderParity.differingPixels(reference, mine)
            report.append(FrameScore(deck: name, frame: file, score: score, differing: differing))
            if (score ?? -.infinity) < threshold(name) + 20 {
                let stem = "\(name)-\(file.dropLast(4))"
                RenderParity.writePNG(mine, to: outDir.appending(path: "\(stem).swift.png"))
                RenderParity.writePNG(reference, to: outDir.appending(path: "\(stem).oracle.png"))
            }
            #expect((score ?? -.infinity) >= threshold(name), "\(name) \(file): SSIMULACRA2 \(score.map { String(format: "%.1f", $0) } ?? "n/a")")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: outDir.appending(path: "report-\(name).json"))
    }

    @Test func framesArePresent() {
        #expect(!frameSets().isEmpty, "no oracle transition frames: run Tools/oracle/oracle.sh corpus")
    }
}
