// Ported from deckcraft crates/render/src/ramp.rs `mod tests` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
import DCColor
@testable import DCRender
import Testing

@Suite struct RampTests {
    @Test func blackToWhiteFollowsPowerPoint() {
        // PowerPoint's export: 105 at a quarter, 186 half way, 238 at three quarters.
        for (t, want) in [(0.25, 105), (0.5, 186), (0.75, 238)] {
            let got = Int(Ramp.mix(.rgb(0, 0, 0), .rgb(255, 255, 255), t).r)
            #expect(abs(got - want) <= 3, "\(t): \(got) vs \(want)")
        }
    }

    @Test func colourPairsFollowPowerPoint() {
        // Blue (4472C4) to orange (ED7D31) half way: PowerPoint draws (178, 120, 146).
        let m = Ramp.mix(.rgb(68, 114, 196), .rgb(237, 125, 49), 0.5)
        #expect(abs(Int(m.r) - 178) <= 3 && abs(Int(m.g) - 120) <= 3 && abs(Int(m.b) - 146) <= 3, "\(m)")
        // Red to blue a quarter of the way: (238, 0, 105).
        let n = Ramp.mix(.rgb(255, 0, 0), .rgb(0, 0, 255), 0.25)
        #expect(abs(Int(n.r) - 238) <= 3 && abs(Int(n.b) - 105) <= 3, "\(n)")
    }

    @Test func theEndsAreTheStopsAndTheWeightIsSymmetric() {
        let (a, b) = (Rgba.rgb(10, 200, 30), Rgba.rgb(240, 20, 90))
        #expect(Ramp.mix(a, b, 0.0) == a)
        #expect(Ramp.mix(a, b, 1.0) == b)
        for k in 0 ... 32 {
            let t = Double(k) / 32.0
            #expect(abs(Ramp.weight(t) + Ramp.weight(1.0 - t) - 1.0) < 1e-9)
            #expect(Ramp.weight(t) <= Ramp.weight(min(t + 0.01, 1.0)), "monotonic")
        }
        #expect(Ramp.weight(.nan) == 0.0)
    }

    @Test func expandKeepsStopsAndHardEdges() {
        let (r, g) = (Rgba.rgb(255, 0, 0), Rgba.rgb(0, 255, 0))
        func same(_ x: [(Double, Rgba)], _ y: [(Double, Rgba)]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
        // Three or more stops, or a stop off an end, blend linearly in sRGB: unchanged.
        let four: [(Double, Rgba)] = [(0.0, r), (0.5, r), (0.5, g), (1.0, g)]
        #expect(same(Ramp.expand(four), four))
        #expect(same(Ramp.expand([(0.2, r), (1.0, g)]), [(0.2, r), (1.0, g)]))
        #expect(Ramp.expand([(0.0, r), (0.5, g), (1.0, r)]).count == 3)
        // Two equal colours add nothing.
        #expect(same(Ramp.expand([(0.0, r), (1.0, r)]), [(0.0, r), (1.0, r)]))
        let e = Ramp.expand([(0.0, r), (1.0, g)])
        #expect(e.count == Ramp.pieces + 1)
        #expect(e.first.map { $0.0 == 0.0 && $0.1 == r } == true)
        #expect(e.last.map { $0.0 == 1.0 && $0.1 == g } == true)
        #expect(zip(e, e.dropFirst()).allSatisfy { $0.0 <= $1.0 })
    }
}
