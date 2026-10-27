// DCAppTests — the slide show's Metal compositor against DCRender's CPU compositor and deckcraft's frames: every
// transition frame of the transitions deck (`DeckCraftNative-Fixtures/anim/transitions/`, 640 px wide, drawn by
// deckcraft-render) and of the corpus decks, composited on the GPU from the same slide pictures the CPU
// compositor uses, scored by SSIMULACRA2 (DCTestSupport.RenderParity) with the parity suite's floors. Morph frames
// are rendered by DCRender in both paths (`renderBlend`), so they are not composited here. SSIMULACRA2 is slow
// unoptimised, so the full comparison runs only in release or with `DECKCRAFT_PARITY=1`:
//   swift test -c release -Xswiftc -enable-testing --filter ShowMetalTests --scratch-path .build-show-rel
// A debug run checks one transition at a small size against the CPU compositor. The report goes to
// `.build-parity/show-parity/report-<deck>.json`.
import AppKit
import DCAnim
import DCAppModel
import DCCore
import DCEngine
import DCFormat
import DCModel
import DCRender
import DCTestSupport
import Foundation
import Metal
import Testing
@testable import DCApp

private struct ShowFrameScore: Codable {
    var deck: String
    var frame: String
    var cpu: Double?
    var oracle: Double?
    var differing: Double?
}

private struct ShowFrameSet {
    var name: String
    var deck: URL
    var frames: URL
    var width: Double?
}

/// The full comparison runs in a release build, or with `DECKCRAFT_PARITY=1` (or `DECKCRAFT_SHOW_PARITY_FULL=1`):
/// SSIMULACRA2 unoptimised takes many minutes. The default debug run has `quickMetalTransitionMatchesTheCPU`.
private var fullParity: Bool {
    #if DEBUG
    let env = ProcessInfo.processInfo.environment
    return env["DECKCRAFT_PARITY"] == "1" || env["DECKCRAFT_SHOW_PARITY_FULL"] == "1"
    #else
    return true
    #endif
}

private func showFrameSets() -> [ShowFrameSet] {
    guard fullParity else { return [] }
    var out: [ShowFrameSet] = []
    let deck = Fixtures.root.appending(path: "engine/transitions.deckcraft")
    let frames = Fixtures.root.appending(path: "anim/transitions", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: deck.path), FileManager.default.fileExists(atPath: frames.path) {
        out.append(ShowFrameSet(name: "transitions", deck: deck, frames: frames, width: 640))
    }
    if corpusToo, let corpus = Fixtures.oracleCorpus {
        let decks = corpus.appending(path: "decks", directoryHint: .isDirectory)
        for base in ["sample", "content", "motion"] {
            let file = decks.appending(path: "\(base).deckcraft")
            let f = decks.appending(path: "\(base).transitions", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: f.path) {
                out.append(ShowFrameSet(name: base, deck: file, frames: f, width: nil))
            }
        }
    }
    return out
}

/// `slide-12-t0.350.png` → (11, 0.35).
private func parseShowFrame(_ file: String) -> (index: Int, t: Double)? {
    guard file.hasPrefix("slide-"), file.hasSuffix(".png") else { return nil }
    let parts = file.dropFirst("slide-".count).dropLast(".png".count).split(separator: "-t")
    guard parts.count == 2, let n = Int(parts[0]), n >= 1, let t = Double(parts[1]) else { return nil }
    return (n - 1, t)
}

private var showParityOut: URL { Fixtures.repositoryRoot.appending(path: ".build-parity/show-parity", directoryHint: .isDirectory) }

private var corpusToo: Bool { true }

private var scoreEvery: Int { 1 }

@MainActor
@Suite(.serialized) struct ShowMetalTests {
    /// The transition frame of slide `i` at `t` through the Metal compositor, from the pictures
    /// `renderTransition` composites on the CPU, and the CPU's own frame.
    static func frames(_ metal: ShowMetal, _ pres: Presentation, _ i: Int, _ t: Double, _ opts: RenderOpts) -> (gpu: RenderImage?, cpu: RenderImage)? {
        guard let slide = pres.slides.at(i) else { return nil }
        let (kind, option) = slide.transition.map { ($0.kind, $0.option) } ?? ("none", "")
        if kind == "morph" { return nil }
        let prev: Int? = i > 0 ? i - 1 : nil
        let new = renderSlide(pres, i, opts)
        let old = prev.map { renderSlide(pres, $0, opts) }
        let parts = usesSlideParts(kind, option) ? SlideParts.render(pres, prev, i, opts) : nil
        let aspect = pres.slideSize.width / Swift.max(pres.slideSize.height, 1)
        let cpu = compositeTransition(old, new, parts, transitionFrame(kind, option, t, aspect))
        guard let newTex = metal.texture(new) else { return (nil, cpu) }
        let partTex: [MTLTexture?]? = parts.map { p in
            [p.oldBack.flatMap { metal.texture($0) }, p.oldContent.flatMap { metal.texture($0) }, metal.texture(p.newBack), metal.texture(p.newContent)]
        }
        let tex = ShowTransitionTextures(old: old.flatMap { metal.texture($0) }, new: newTex, parts: partTex)
        let rect = CGRect(x: 0, y: 0, width: new.width, height: new.height)
        let draws = ShowMetal.transitionDraws(kind, option, t, aspect: aspect, rect: rect, tex)
        return (metal.renderOffscreen(draws, width: new.width, height: new.height), cpu)
    }

    /// The Metal compositor draws every transition frame as DCRender's CPU compositor does (SSIMULACRA2 ≥ 88 to
    /// it) and as deckcraft does (the parity suite's floor against the oracle's frame).
    @Test(arguments: showFrameSets().map(\.name)) func metalTransitionFramesMatch(_ name: String) throws {
        guard let metal = ShowMetal.shared else { return }
        guard let set = showFrameSets().first(where: { $0.name == name }) else { return }
        try? FileManager.default.createDirectory(at: showParityOut, withIntermediateDirectories: true)
        let pres = try DeckFormat.load([UInt8](Data(contentsOf: set.deck)))
        let opts = RenderOpts(scale: set.width.map { $0 / Swift.max(pres.slideSize.width, 1) } ?? 2)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: set.frames.path)) ?? []).filter { parseShowFrame($0) != nil }.sorted()
        var report: [ShowFrameScore] = []
        var checked = 0
        for (n, file) in files.enumerated() {
            guard let (i, t) = parseShowFrame(file), let (gpu0, cpu) = Self.frames(metal, pres, i, t, opts) else { continue }
            guard let gpuImage = gpu0, let gpu = gpuImage.cgImage(), let cpuCG = cpu.cgImage() else {
                Issue.record("\(name) \(file): nothing composited")
                continue
            }
            checked += 1
            let differing = RenderParity.differingPixels(cpuCG, gpu, tolerance: 8)
            #expect((differing ?? 1) < 0.02, "\(name) \(file): \(differing ?? 1) of the pixels differ from the CPU compositor")
            var row = ShowFrameScore(deck: name, frame: file, differing: differing)
            if n % scoreEvery == 0 {
                row.cpu = RenderParity.score(reference: cpuCG, distorted: gpu)
                #expect((row.cpu ?? 0) >= 88, "\(name) \(file): SSIMULACRA2 to the CPU compositor \(row.cpu ?? 0)")
                if let reference = RenderParity.load(set.frames.appending(path: file)) {
                    row.oracle = RenderParity.score(reference: reference, distorted: gpu)
                    let floor = name == "transitions" ? 87.0 : 88.0
                    #expect((row.oracle ?? 0) >= floor, "\(name) \(file): SSIMULACRA2 to deckcraft \(row.oracle ?? 0)")
                    if (row.oracle ?? 0) < floor + 3 {
                        RenderParity.writePNG(gpu, to: showParityOut.appending(path: "\(name)-\(file.dropLast(4)).metal.png"))
                    }
                }
            }
            report.append(row)
        }
        #expect(checked > 0, "\(name): no transition frames composited")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: showParityOut.appending(path: "report-\(name).json"))
    }

    /// The default (debug) run's quick check: a few transitions of a two-slide deck at 160 × 90, composited on
    /// the GPU and on the CPU from the same pictures, nearly every pixel the same.
    @Test func quickMetalTransitionMatchesTheCPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let metal = try #require(ShowMetal.shared, "the show's shaders compile")
        #expect(metal.pipeline(.rgba8Unorm, exact: true) != nil, "the exact pipeline compiles")
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        _ = try s.execute("shape.insert", ["preset": "star5", "rect": [100, 100, 300, 200]])
        for (kind, option) in [("push", "u"), ("fade", ""), ("cube", "l"), ("pan", "d")] {
            _ = try s.execute("transition.set", ["kind": .string(kind), "option": .string(option), "index": 1])
            let pres = try #require(s.activeDoc?.doc)
            let opts = RenderOpts(scale: 160 / Swift.max(pres.slideSize.width, 1))
            for t in [0.3, 0.7] {
                let (gpu0, cpu) = try #require(Self.frames(metal, pres, 1, t, opts))
                let gpu = try #require(gpu0?.cgImage())
                let cpuCG = try #require(cpu.cgImage())
                let differing = RenderParity.differingPixels(cpuCG, gpu, tolerance: 8) ?? 1
                #expect(differing < 0.02, "\(kind) at \(t): \(differing) of the pixels differ from the CPU compositor")
            }
        }
    }

    /// A frame of a running show through the stage: the slide's texture over black in its letterboxed rectangle,
    /// the same picture DCRender draws (show.rs: the_prefetched_frame_is_the_frame_shown_on_entry, on the GPU).
    @Test func theStageDrawsTheSlideLetterboxed() throws {
        guard let metal = ShowMetal.shared else { return }
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m)
        c.startShow(from: 1, reading: false)
        _ = c.tick(10)
        let stage = ShowStage(coord: c, metal: metal)
        let full = CGRect(x: 0, y: 0, width: 400, height: 400)
        let (draws, animating) = stage.draws(full: full, scale: 1, now: 10)
        #expect(!animating)
        let img = try #require(metal.renderOffscreen(draws, width: 400, height: 400))
        // 16:9 in a square: black above and below, the slide in the middle.
        let top = Array(img.pixels[0 ..< 4])
        #expect(top == [0, 0, 0, 255])
        let doc = try #require(c.showState?.doc)
        let srect = ShowGeometry.slideRect(full, reading: false, doc)
        let want = ShowRender.frame(doc, 1, ShowState.timeline(doc, 1), 0, 0, ShowRender.fitSize(Int(srect.width.rounded()), Int(srect.height.rounded())), hidden: [])
        let (cx, cy) = (200, 200)
        let wy = cy - Int(srect.minY.rounded())
        let got = Array(img.pixels[(cy * 400 + cx) * 4 ..< (cy * 400 + cx) * 4 + 3])
        let ref = Array(want.pixels[(wy * want.width + cx) * 4 ..< (wy * want.width + cx) * 4 + 3])
        #expect(zip(got, ref).allSatisfy { Swift.abs(Int($0) - Int($1)) <= 2 }, "\(got) \(ref)")
        // The frame is kept: a second pass reuses the texture.
        let tex = c.show?.frame?.image
        _ = stage.draws(full: full, scale: 1, now: 10.5)
        #expect(c.show?.frame?.image === tex)
    }

    /// A windowed show opens, draws and closes; Escape in its window ends it (show.rs's keyboard path, through
    /// the window's key handler) and the editor is left on the last slide.
    @Test func aWindowedShowOpensAndEscapeEndsIt() throws {
        guard let metal = ShowMetal.shared else { return }
        _ = NSApplication.shared
        let s = Session.withNew()
        _ = try s.execute("slide.new", .emptyObject)
        let m = AppModel(session: s)
        m.ui.presenterView = true
        let c = ShowCoordinator(model: m)
        let w = ShowWindows(coord: c, metal: metal)
        c.onShowStarted = { sh in
            w.windowedNext = true
            w.open(sh)
        }
        c.onShowEnded = { w.close() }
        c.startShow(from: 0, reading: false)
        #expect(w.audience != nil)
        #expect(w.presenterWindow != nil, "windowed: presenter view opens in its own window")
        let view = try #require(w.showView)
        view.tick()
        #expect(view.snapshot() != nil)
        w.presenter?.refresh()
        #expect(w.presenter?.counter == "Slide 1 of 2")
        func key(_ code: UInt16, _ chars: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.audience?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
            )
        }
        if let right = key(124, "") { #expect(w.key(right, presenter: false)) }
        #expect(c.show?.state.slide == 1)
        if let b = key(11, "b") { #expect(w.key(b, presenter: true)) }
        #expect(c.show?.blank == .black, "presenter view's keys drive the show too")
        if let esc = key(53, "\u{1b}") { #expect(w.key(esc, presenter: false)) }
        #expect(c.show == nil)
        #expect(w.audience == nil && w.presenterWindow == nil)
        #expect(s.activeDoc?.selection.slide == 1)
    }
}
