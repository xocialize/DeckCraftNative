// DCShowTests — ShowTextureSource: a show drawn into one texture only when its picture changes, keys driving it, the
// generation moving with each picture, the end of the show, and the texture's pixels equal to the renderer's own.
import CNCore
import DCAppModel
import DCEngine
import DCRender
import Foundation
import Metal
import Testing
@testable import DCShow

@MainActor
@Suite(.serialized) struct ShowTextureSourceTests {
    /// Three slides, a fade into the second, a star on the third.
    static func source(_ metal: ShowMetal, width: Int = 320, height: Int = 180) throws -> ShowTextureSource {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        _ = try s.execute("transition.set", ["kind": "fade", "duration": 500])
        _ = try s.execute("slide.new", ["title": "Third"])
        _ = try s.execute("shape.insert", ["preset": "star5", "rect": [100, 100, 300, 200]])
        let m = AppModel(session: s)
        m.ui.presenterView = false
        return ShowTextureSource(coordinator: ShowCoordinator(model: m), metal: metal, width: width, height: height)
    }

    static func pixels(_ texture: MTLTexture, _ queue: MTLCommandQueue) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        d.storageMode = .shared
        guard let copy = queue.device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    @Test func itDrawsOnlyWhenThePictureChanges() throws {
        guard let metal = ShowMetal.shared else { return }
        let source = try Self.source(metal)
        #expect(!source.tick(now: 10), "no show yet")
        source.start(from: 0)
        #expect(source.isShowing)
        #expect(source.tick(now: 10), "the first frame")
        #expect(source.generation == 1)
        let texture = try #require(source.texture)
        #expect(texture.pixelFormat == .bgra8Unorm && texture.width == 320 && texture.height == 180)
        for t in [10.1, 10.2, 11, 20] { #expect(!source.tick(now: t), "a resting slide draws nothing at \(t)") }
        #expect(source.generation == 1)
        #expect(source.stats.framesDrawn == 1 && source.stats.lastKind == "still")
    }

    @Test func aKeyStartsATransitionDrawnEveryTickUntilItEnds() throws {
        guard let metal = ShowMetal.shared else { return }
        let source = try Self.source(metal)
        source.start(from: 0)
        source.tick(now: 10)
        #expect(source.key(.arrowRight, now: 10))
        var drawn = 0
        var kinds: Set<String> = []
        for i in 1 ... 40 {
            if source.tick(now: 10 + Double(i) / 60) {
                drawn += 1
                kinds.insert(source.stats.lastKind)
            }
        }
        #expect(drawn >= 30, "the 0.5 s fade is drawn on (nearly) every tick: \(drawn)")
        #expect(kinds.contains("transition"))
        let settled = source.generation
        #expect(!source.tick(now: 12) || source.generation == settled + 1)
        #expect(!source.tick(now: 13), "on the second slide, at rest")
        #expect(source.coordinator.show?.state.slide == 1)
    }

    /// The texture holds exactly what the renderer draws for the same frame, in BGRA.
    @Test func theTextureIsTheRenderersFrame() throws {
        guard let metal = ShowMetal.shared else { return }
        let source = try Self.source(metal)
        source.start(from: 2)
        #expect(source.tick(now: 10))
        let texture = try #require(source.texture)
        let bgra = Self.pixels(texture, metal.queue)
        let want = try #require(source.renderer.renderOffscreen(source.renderer.frame(pixels: CGSize(width: 320, height: 180), now: 10), width: 320, height: 180))
        var differing = 0
        for p in 0 ..< 320 * 180 where [bgra[p * 4 + 2], bgra[p * 4 + 1], bgra[p * 4], bgra[p * 4 + 3]] != Array(want.pixels[p * 4 ..< p * 4 + 4]) {
            differing += 1
        }
        #expect(differing == 0)
    }

    @Test func blankScreensAndTheEndAreDrawnAndEscEnds() throws {
        guard let metal = ShowMetal.shared else { return }
        let source = try Self.source(metal)
        source.start(from: 0)
        source.tick(now: 10)
        #expect(source.key(.b, now: 10.5))
        #expect(source.tick(now: 10.5), "B is a new picture")
        let texture = try #require(source.texture)
        let black = Self.pixels(texture, metal.queue)
        #expect(black.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
        source.key(.b, now: 11)
        #expect(source.tick(now: 11))
        source.key(.escape, now: 12)
        #expect(!source.isShowing, "Esc ends the show")
        #expect(!source.tick(now: 12))
    }

    @Test func aResizeDrawsAtTheNewSizeOnTheNextTick() throws {
        guard let metal = ShowMetal.shared else { return }
        let source = try Self.source(metal)
        source.start(from: 0)
        source.tick(now: 10)
        source.resize(width: 640, height: 360)
        #expect(source.texture == nil)
        #expect(source.tick(now: 10.1))
        #expect(source.texture?.width == 640)
    }

    @Test func keysMapFromMacKeyEvents() {
        #expect(ShowKey(keyCode: 124, characters: nil) == .arrowRight)
        #expect(ShowKey(keyCode: 121, characters: nil) == .pageDown)
        #expect(ShowKey(keyCode: 11, characters: "b") == .b)
        #expect(ShowKey(keyCode: 13, characters: "W") == .w)
        #expect(ShowKey(keyCode: 18, characters: "1") == .digit("1"))
        #expect(ShowKey(keyCode: 0, characters: "ab") == .other)
    }
}
