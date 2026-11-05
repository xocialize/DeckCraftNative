// DCShowTests — DCShow's public renderer: a running show drawn into a texture its caller owns, on the caller's
// device and queue, exactly as the renderer's own offscreen path draws it; targets it can't draw into refused;
// when to draw (ShowFramePacer, the show window's rule); and the target's import rule (no AppKit or SwiftUI).
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

    /// An ended show has nothing to draw: the client shows its clear colour.
    @Test func anEndedShowHasAnEmptyFrame() throws {
        guard let metal = ShowMetal.shared else { return }
        let (c, renderer) = try Self.show(metal)
        while c.navigate(true, now: 11), c.show?.ended == false {}
        #expect(renderer.frame(pixels: CGSize(width: 64, height: 36), now: 12).isEmpty || c.show == nil)
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
