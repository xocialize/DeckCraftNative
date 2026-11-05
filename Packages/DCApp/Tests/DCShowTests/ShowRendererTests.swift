// DCShowTests — DCShow's public renderer: a running show drawn into a texture its caller owns, on the caller's
// device and queue, exactly as the renderer's own offscreen path draws it; targets it can't draw into refused;
// what the audience sees over the slide (blank screens, ink, the end screen), drawn by the renderer alone; when to
// draw (ShowFramePacer, the show window's rule, and what it notices in the show); and the target's import rule.
import CNCore
import DCAppModel
import DCEngine
import DCRender
import DCTestSupport
import Foundation
import Metal
import Testing
@testable import DCShow

@MainActor
@Suite(.serialized) struct ShowRendererTests {
    /// A running two-slide show on its second slide, through a renderer on `metal`.
    static func show(_ metal: ShowMetal) throws -> (ShowCoordinator, ShowRenderer) {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        _ = try s.execute("shape.insert", ["preset": "star5", "rect": [100, 100, 300, 200]])
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m)
        c.startShow(from: 1, reading: false)
        _ = c.tick(10)
        return (c, ShowRenderer(coord: c, metal: metal))
    }

    static func target(_ device: MTLDevice, _ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        td.usage = usage
        td.storageMode = .shared
        return device.makeTexture(descriptor: td)
    }

    /// A host's device and queue, a host's BGRA texture: the frame encoded on the host's command buffer is the
    /// renderer's own offscreen frame, channel for channel.
    @Test func aShowIsDrawnIntoACallersTextureOnTheCallersDevice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let queue = try #require(device.makeCommandQueue())
        let metal = try #require(ShowMetal(device: device, queue: queue))
        #expect(metal.device === device)
        #expect(metal.queue === queue, "the host's queue is used, so the frame lands in the host's command order")
        let (_, renderer) = try Self.show(metal)
        let (w, h) = (320, 180)
        let frame = renderer.frame(pixels: CGSize(width: w, height: h), now: 10)
        #expect(!frame.isEmpty)
        let target = try #require(Self.target(device, .bgra8Unorm, w, h))
        let cb = try #require(queue.makeCommandBuffer())
        #expect(renderer.encode(frame, into: target, commandBuffer: cb))
        cb.commit()
        cb.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        bgra.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { target.getBytes(base, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        }
        let want = try #require(renderer.renderOffscreen(frame, width: w, height: h))
        var differing = 0
        for p in 0 ..< w * h {
            let (b, g, r, a) = (bgra[p * 4], bgra[p * 4 + 1], bgra[p * 4 + 2], bgra[p * 4 + 3])
            let want4 = want.pixels[p * 4 ..< p * 4 + 4]
            if [r, g, b, a] != Array(want4) { differing += 1 }
        }
        #expect(differing == 0, "\(differing) pixels differ between the BGRA target and the offscreen frame")
        // The slide's 16:9 fills a 16:9 target: no letterbox, so the corner is the slide's white, not black.
        #expect(Array(want.pixels[0 ..< 3]) != [0, 0, 0])
    }

    /// A target the pipelines can't draw is refused and nothing is encoded: not a render target, a format without
    /// a pipeline (sRGB would blend in linear light).
    @Test func aTargetItCantDrawIntoIsRefused() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let metal = try #require(ShowMetal(device: device))
        let (_, renderer) = try Self.show(metal)
        let frame = renderer.frame(pixels: CGSize(width: 64, height: 36), now: 10)
        let cb = try #require(metal.queue.makeCommandBuffer())
        let readOnly = try #require(Self.target(device, .bgra8Unorm, 64, 36, usage: [.shaderRead]))
        #expect(!renderer.encode(frame, into: readOnly, commandBuffer: cb))
        let srgb = try #require(Self.target(device, .bgra8Unorm_srgb, 64, 36))
        #expect(!renderer.encode(frame, into: srgb, commandBuffer: cb))
        let rgba = try #require(Self.target(device, .rgba8Unorm, 64, 36))
        #expect(renderer.encode(frame, into: rgba, commandBuffer: cb))
        cb.commit()
    }

    /// A queue of another device is not used; the compositor makes its own on the device it was given.
    @Test func aQueueOfAnotherDeviceIsNotUsed() throws {
        let devices = MTLCopyAllDevices()
        guard devices.count > 1, let a = devices.first, let b = devices.last, let qb = b.makeCommandQueue() else { return }
        let metal = try #require(ShowMetal(device: a, queue: qb))
        #expect(metal.queue.device === a)
    }

    /// The show window's rule: draw after a change, every tick while the picture moves by itself or a transition
    /// runs, and otherwise every 0.25 s; with no keep-alive, never while nothing changes.
    @Test func thePacerDrawsWhatChangedAndKeepsAlive() throws {
        guard let metal = ShowMetal.shared else { return }
        let (_, renderer) = try Self.show(metal)
        let still = renderer.frame(pixels: CGSize(width: 64, height: 36), now: 10)
        #expect(!still.animating)
        var p = ShowFramePacer()
        #expect(p.shouldDraw(now: 10, transitioning: false), "the first frame is drawn")
        p.willDraw(now: 10)
        p.drew(still)
        #expect(!p.shouldDraw(now: 10.1, transitioning: false))
        #expect(p.shouldDraw(now: 10.1, transitioning: true), "a transition draws every tick")
        #expect(p.shouldDraw(now: 10.3, transitioning: false), "the keep-alive")
        p.willDraw(now: 10.3)
        p.invalidate()
        #expect(p.shouldDraw(now: 10.31, transitioning: false), "a change is drawn on the next tick")
        p.willDraw(now: 10.31)
        #expect(!p.shouldDraw(now: 10.32, transitioning: false))
        var quiet = ShowFramePacer(keepAlive: nil)
        quiet.willDraw(now: 0)
        quiet.drew(still)
        #expect(!quiet.shouldDraw(now: 1_000, transitioning: false), "no keep-alive: nothing changed, nothing drawn")
        var nan = ShowFramePacer(keepAlive: .nan)
        nan.willDraw(now: 0)
        nan.drew(still)
        #expect(!nan.shouldDraw(now: 1_000, transitioning: false))
    }

    /// The frame at 320 × 180 through the renderer alone (no window, no AppKit overlay), as RGBA.
    static func pixels(_ r: ShowRenderer, now: Double = 10) -> [UInt8]? {
        let f = r.frame(pixels: CGSize(width: 320, height: 180), now: now)
        return r.renderOffscreen(f, width: 320, height: 180)?.pixels
    }

    /// B and W are the renderer's: a client of the renderer alone shows a black or white screen, all of it.
    @Test func blankScreensAreTheRenderers() throws {
        guard let metal = ShowMetal.shared else { return }
        let (c, renderer) = try Self.show(metal)
        let s = try #require(c.show)
        s.toggleBlank(.black)
        let black = try #require(Self.pixels(renderer))
        #expect(black.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
        s.toggleBlank(.white)
        let white = try #require(Self.pixels(renderer))
        #expect(white.allSatisfy { $0 == 255 })
        s.toggleBlank(.white)
        let slide = try #require(Self.pixels(renderer))
        #expect(slide != white && slide != black, "the slide again")
    }

    /// Ink is drawn over the slide in the pen colour (red by default) and goes when the strokes are cleared.
    @Test func inkIsTheRenderers() throws {
        guard let metal = ShowMetal.shared else { return }
        let (c, renderer) = try Self.show(metal)
        let s = try #require(c.show)
        let before = try #require(Self.pixels(renderer))
        s.strokes = [[CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]]
        let inked = try #require(Self.pixels(renderer))
        // The stroke runs across the middle row: red there, where the slide was white.
        let mid = (90 * 320 + 160) * 4
        #expect(Array(inked[mid ..< mid + 4]) == [255, 0, 0, 255], "\(Array(inked[mid ..< mid + 4]))")
        #expect(Array(before[mid ..< mid + 3]) != [255, 0, 0])
        s.strokes = []
        #expect(try #require(Self.pixels(renderer)) == before)
    }

    /// The end screen: the client's line in grey near the top on black; without a line, nothing to draw.
    @Test func theEndScreenIsTheRenderers() throws {
        guard let metal = ShowMetal.shared else { return }
        let (c, renderer) = try Self.show(metal)
        while c.navigate(true, now: 11), c.show?.ended == false {}
        let s = try #require(c.show, "past the last slide the show waits on its end screen")
        #expect(s.ended)
        #expect(renderer.frame(pixels: CGSize(width: 320, height: 180), now: 12).isEmpty, "no line set: nothing drawn")
        renderer.endText = "End of slide show, click to exit."
        let f = renderer.frame(pixels: CGSize(width: 320, height: 180), now: 12)
        #expect(!f.isEmpty && !f.animating)
        let px = try #require(renderer.renderOffscreen(f, width: 320, height: 180)?.pixels)
        func lit(_ rows: Range<Int>) -> Int { rows.reduce(0) { n, y in n + (0 ..< 320).filter { px[(y * 320 + $0) * 4] > 60 }.count } }
        #expect(lit(28 ..< 52) > 50, "the line, centred 40 points from the top")
        #expect(lit(60 ..< 180) == 0, "black below it")
    }

    /// The pacer sees what changed in the show without being told: a blank screen toggled by presenter view, ink,
    /// the slide; and nothing when nothing changed.
    @Test func thePacerSeesChangesInTheShow() throws {
        guard let metal = ShowMetal.shared else { return }
        let (c, renderer) = try Self.show(metal)
        let s = try #require(c.show)
        var p = ShowFramePacer(keepAlive: nil)
        p.observe(s)
        p.willDraw(now: 10)
        p.drew(renderer.frame(pixels: CGSize(width: 64, height: 36), now: 10))
        p.observe(s)
        #expect(!p.shouldDraw(now: 10.1, transitioning: false), "nothing changed")
        s.toggleBlank(.black)
        p.observe(s)
        #expect(p.shouldDraw(now: 10.2, transitioning: false), "a blank screen")
        p.willDraw(now: 10.2)
        s.strokes = [[CGPoint(x: 0.1, y: 0.1)]]
        p.observe(s)
        #expect(p.shouldDraw(now: 10.3, transitioning: false), "a new stroke")
        p.willDraw(now: 10.3)
        s.strokes[0].append(CGPoint(x: 0.2, y: 0.2))
        p.observe(s)
        #expect(p.shouldDraw(now: 10.4, transitioning: false), "the stroke grows")
        p.willDraw(now: 10.4)
        p.observe(s)
        #expect(!p.shouldDraw(now: 10.5, transitioning: false))
        p.observe(nil)
        #expect(p.shouldDraw(now: 10.6, transitioning: false), "the show went away")
    }

    /// DCShow is Metal and Core Graphics: none of its sources import AppKit, SwiftUI or Cocoa, so a program
    /// without the app's windows (a headless tool, another app's process) can link it.
    @Test func dcShowImportsNoUIFramework() throws {
        let dir = Fixtures.repositoryRoot.appending(path: "Packages/DCApp/Sources/DCShow", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for f in files {
            let text = try String(contentsOf: dir.appending(path: f), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                for banned in ["AppKit", "SwiftUI", "Cocoa", "UIKit"] {
                    #expect(!(l.hasPrefix("import \(banned)") || l.hasPrefix("@preconcurrency import \(banned)")), "\(f): \(l)")
                }
            }
        }
    }
}
