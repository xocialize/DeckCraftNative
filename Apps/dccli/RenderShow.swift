// dccli — render-show: plays a presentation's slide show in real time through DCShow's renderer into an offscreen
// texture, as a program drawing a show into its own texture would (the first is MVS's Marquee Presentation, which
// hands each frame to another app's compositor), and times every frame it draws. DeckCraftNative's own; deckcraft
// has no such command.
//
// The show runs on the main thread (ShowCoordinator is main-actor), so `DCCLI.main` runs this before handing the
// other commands to the engine thread. The clock is the real one: display frames come at --fps, the show steps
// forward every --dwell seconds, and a frame drawn late (its work longer than a frame) is counted. Whether a tick
// draws at all is DCShow's ShowFramePacer's rule, with no keep-alive unless asked: a resting slide draws nothing.
import CNCore
import DCAppModel
import DCAutomation
import DCEngine
import DCModel
import DCRender
import DCShow
import Foundation
import Metal
import QuartzCore

@MainActor
enum RenderShow {
    /// Milliseconds: count, median, 95th percentile, largest, mean.
    struct Stats: Codable {
        var n: Int
        var p50: Double
        var p95: Double
        var max: Double
        var mean: Double

        init(_ xs: [Double]) {
            let s = xs.filter(\.isFinite).sorted()
            n = s.count
            func q(_ p: Double) -> Double { s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
            p50 = q(0.5)
            p95 = q(0.95)
            max = s.last ?? 0
            mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
        }
    }

    /// One drawn frame.
    struct Sample: Codable {
        /// Seconds since the show started.
        var t: Double
        var slide: Int
        /// still, animation, transition, morph, media (a playing video or GIF), end.
        var kind: String
        /// `renderer.frame`: the draw list, with any slide render it needs (DCRender, on the CPU).
        var frameMs: Double
        /// Encoding and committing the draws.
        var encodeMs: Double
        /// The command buffer on the GPU.
        var gpuMs: Double
        /// From the start of the frame's work to the GPU finishing it.
        var totalMs: Double
    }

    struct Run: Codable {
        var deck: String
        var width: Int
        var height: Int
        var fps: Double
        var dwell: Double
        var seconds: Double
        var steps: Int
        var ticks: Int
        var drawn: Int
        /// Ticks the pacer skipped: nothing changed.
        var skipped: Int
        /// Display frames that passed while a frame was being drawn (the show would have dropped them).
        var missed: Int
        var total: Stats
        var frame: Stats
        var gpu: Stats
        var byKind: [String: Stats]
        var samples: [Sample]?
    }

    static let help = """
    render-show FILE [--size WxH]... [--fps N] [--dwell S] [--steps N] [--from N] [--keep-alive S] [--json OUT]
    """

    static func run(_ args: [String]) throws(CLIFailure) {
        var input: String?
        var sizes: [(Int, Int)] = []
        var fps = 60.0
        var dwell = 1.5
        var maxSteps = 60
        var from = 0
        var keepAlive: Double?
        var jsonOut: String?
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--size":
                guard let v = it.next(), let s = parseSize(v) else { throw CLIFailure("--size needs WxH, such as 1920x1080") }
                sizes.append(s)
            case "--fps":
                guard let v = it.next().flatMap({ rustParseF64($0) }), v.isFinite, (1 ... 240).contains(v) else { throw CLIFailure("--fps needs 1 to 240") }
                fps = v
            case "--dwell":
                guard let v = it.next().flatMap({ rustParseF64($0) }), v.isFinite, (0.05 ... 60).contains(v) else { throw CLIFailure("--dwell needs seconds, 0.05 to 60") }
                dwell = v
            case "--steps":
                guard let n = it.next().flatMap(RustParse.usize), (1 ... 10_000).contains(n) else { throw CLIFailure("--steps needs 1 to 10000") }
                maxSteps = n
            case "--from":
                guard let n = it.next().flatMap(RustParse.usize) else { throw CLIFailure("--from needs a slide index") }
                from = n
            case "--keep-alive":
                guard let v = it.next().flatMap({ rustParseF64($0) }), v.isFinite, v > 0 else { throw CLIFailure("--keep-alive needs seconds") }
                keepAlive = v
            case "--json":
                guard let v = it.next() else { throw CLIFailure("--json needs a path") }
                jsonOut = v
            case let f where !f.hasPrefix("--") && input == nil: input = f
            default: throw CLIFailure("render-show: unknown argument `\(a)`")
            }
        }
        guard let input else { throw CLIFailure("render-show needs a FILE") }
        if sizes.isEmpty { sizes = [(1920, 1080)] }
        guard let device = MTLCreateSystemDefaultDevice(), let metal = ShowMetal(device: device) else {
            throw CLIFailure("render-show needs a Metal device")
        }
        let s = Session()
        try CLI.open(s, input, false)
        let n: Int
        do { n = try s.doc().doc.slides.count } catch { throw CLIFailure(error.description) }
        guard from < n else { throw CLIFailure("no slide \(from) (the deck has \(n))") }
        let model = AppModel(session: s)
        model.ui.presenterView = false
        let deck = (input as NSString).lastPathComponent
        Out.line("render-show \(deck): \(n) slides, \(Int(fps)) fps, \(dwell) s a step, \(device.name)")
        var runs: [Run] = []
        for (w, h) in sizes {
            let r = try play(model, metal, deck: deck, w, h, fps: fps, dwell: dwell, maxSteps: maxSteps, from: from, keepAlive: keepAlive)
            runs.append(r)
            Out.line(line(r))
            for (k, st) in r.byKind.sorted(by: { $0.key < $1.key }) {
                Out.line("    \(k.padding(toLength: 10, withPad: " ", startingAt: 0)) \(st.n) frames, total ms p50 \(f1(st.p50)) p95 \(f1(st.p95)) max \(f1(st.max))")
            }
        }
        if let jsonOut {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try enc.encode(runs).write(to: URL(filePath: jsonOut)) } catch { throw CLIFailure("\(jsonOut): \(error)") }
        }
    }

    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }

    static func line(_ r: Run) -> String {
        "  \(r.width)x\(r.height): \(r.steps) steps in \(f1(r.seconds)) s; drew \(r.drawn) of \(r.ticks) ticks, \(r.missed) display frames missed; "
            + "total ms p50 \(f1(r.total.p50)) p95 \(f1(r.total.p95)) max \(f1(r.total.max)); "
            + "frame p50 \(f1(r.frame.p50)) p95 \(f1(r.frame.p95)); gpu p50 \(f1(r.gpu.p50)) p95 \(f1(r.gpu.p95))"
    }

    static func parseSize(_ v: String) -> (Int, Int)? {
        let p = v.lowercased().split(separator: "x")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]), (16 ... 16384).contains(w), (16 ... 16384).contains(h) else { return nil }
        return (w, h)
    }

    /// One show at `w`×`h`, from slide `from` to its end or `maxSteps` steps.
    static func play(_ model: AppModel, _ metal: ShowMetal, deck: String, _ w: Int, _ h: Int, fps: Double, dwell: Double, maxSteps: Int,
                     from: Int, keepAlive: Double?) throws(CLIFailure) -> Run {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let target = metal.device.makeTexture(descriptor: td) else { throw CLIFailure("can't make a \(w)x\(h) texture") }
        let coord = ShowCoordinator(model: model)
        coord.startShow(from: from, reading: false)
        let renderer = ShowRenderer(coord: coord, metal: metal)
        renderer.endText = "End of slide show, click to exit."
        var pacer = ShowFramePacer(keepAlive: keepAlive)
        let period = 1 / fps
        let start = ShowCoordinator.now()
        var next = start
        var nextStep = start + dwell
        var steps = 0, ticks = 0, skipped = 0, missed = 0
        var samples: [Sample] = []
        let size = CGSize(width: w, height: h)
        while true {
            // Wait for the next display frame, keeping the main run loop turning (media and prefetch post to it).
            let wait = next - ShowCoordinator.now()
            if wait > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: wait)) }
            let now = ShowCoordinator.now()
            next += period
            while next <= now {
                next += period
                missed += 1
            }
            ticks += 1
            guard coord.tick(now), let s = coord.show else { break }
            if now >= nextStep {
                if s.ended || steps >= maxSteps { break }
                guard coord.navigate(true, now: now) else { break }
                steps += 1
                nextStep = now + dwell
                pacer.invalidate()
            }
            guard let sh = coord.show else { break }
            if coord.media.syncVideoFrames() { pacer.invalidate() }
            pacer.observe(sh)
            guard pacer.shouldDraw(now: now, transitioning: sh.trans != nil) else {
                skipped += 1
                continue
            }
            pacer.willDraw(now: now)
            let kind: String
            if sh.ended {
                kind = "end"
            } else if let tr = sh.trans {
                kind = tr.isMorph ? "morph" : "transition"
            } else if sh.animating {
                kind = "animation"
            } else {
                kind = "still"
            }
            let t0 = CACurrentMediaTime()
            let frame = renderer.frame(pixels: size, now: now)
            let t1 = CACurrentMediaTime()
            guard let cb = metal.queue.makeCommandBuffer() else { throw CLIFailure("no command buffer") }
            renderer.encode(frame, into: target, commandBuffer: cb)
            cb.commit()
            let t2 = CACurrentMediaTime()
            cb.waitUntilCompleted()
            let t3 = CACurrentMediaTime()
            pacer.drew(frame)
            let k = kind == "still" && frame.animating ? "media" : kind
            samples.append(Sample(
                t: now - start, slide: sh.state.slide, kind: k, frameMs: (t1 - t0) * 1000, encodeMs: (t2 - t1) * 1000,
                gpuMs: Swift.max(0, cb.gpuEndTime - cb.gpuStartTime) * 1000, totalMs: (t3 - t0) * 1000
            ))
        }
        coord.endShow()
        var byKind: [String: Stats] = [:]
        for k in Set(samples.map(\.kind)) { byKind[k] = Stats(samples.filter { $0.kind == k }.map(\.totalMs)) }
        return Run(
            deck: deck, width: w, height: h, fps: fps, dwell: dwell, seconds: ShowCoordinator.now() - start, steps: steps, ticks: ticks,
            drawn: samples.count, skipped: skipped, missed: missed, total: Stats(samples.map(\.totalMs)), frame: Stats(samples.map(\.frameMs)),
            gpu: Stats(samples.map(\.gpuMs)), byKind: byKind, samples: samples
        )
    }
}
