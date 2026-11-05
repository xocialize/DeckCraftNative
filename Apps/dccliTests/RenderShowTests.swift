// dccliTests — render-show: a short show played through DCShow's renderer, its frames timed and counted.
import DCAppModel
import DCEngine
import DCShow
import Foundation
import Metal
import Testing
@testable import dccli

@MainActor
@Suite(.serialized) struct RenderShowTests {
    @Test func sizesParse() {
        #expect(RenderShow.parseSize("1920x1080")! == (1920, 1080))
        #expect(RenderShow.parseSize("640X360")! == (640, 360))
        #expect(RenderShow.parseSize("1920") == nil)
        #expect(RenderShow.parseSize("0x0") == nil)
        #expect(RenderShow.parseSize("99999x10") == nil)
    }

    @Test func percentiles() {
        let s = RenderShow.Stats([5, 1, 3, 2, 4, .nan])
        #expect(s.n == 5 && s.p50 == 3 && s.max == 5 && s.mean == 3)
        #expect(RenderShow.Stats([]).n == 0)
    }

    /// Three slides with a fade, played at 64×36: every step taken, the transitions drawn, a resting slide not
    /// drawn again (no keep-alive), and every frame timed.
    @Test func aShortShowIsPlayedAndTimed() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let metal = ShowMetal(device: device) else { return }
        let s = Session.withNew()
        for _ in 0 ..< 2 {
            _ = try s.execute("slide.new", .emptyObject)
            _ = try s.execute("transition.set", ["kind": "fade", "duration": 200])
        }
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let r = try RenderShow.play(m, metal, deck: "test", 64, 36, fps: 60, dwell: 0.4, maxSteps: 2, from: 0, keepAlive: nil)
        #expect(r.steps == 2)
        #expect(r.drawn > 0 && r.drawn == r.samples?.count)
        #expect(r.byKind["transition"].map { $0.n > 0 } == true, "\(r.byKind.keys)")
        #expect(r.skipped > 0, "a resting slide draws nothing")
        #expect(r.total.max >= r.frame.max)
    }
}
