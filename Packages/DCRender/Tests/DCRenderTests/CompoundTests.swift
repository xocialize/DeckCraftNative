// Ported from deckcraft crates/render/src/compound.rs `mod tests` and tests.rs
// `compound_lines_draw_their_bands` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCGeometry
import DCModel
@testable import DCRender
import Testing

@Suite struct CompoundTests {
    @Test func bandsSplitTheWidthLikePowerPoint() {
        for c: Compound in [.single, .double, .thinThick, .thickThin, .triple] {
            let b = CompoundLine.bands(c)
            #expect(b.first?.0 == 0.0)
            #expect(b.last?.1 == 1.0)
            #expect(zip(b, b.dropFirst()).allSatisfy { $0.1 < $1.0 }, "\(c): bands in order with gaps")
        }
        // Thin-thick: the thin line on the left, thick-thin its mirror.
        let (tt, th) = (CompoundLine.bands(.thinThick), CompoundLine.bands(.thickThin))
        #expect(tt[0].1 - tt[0].0 < tt[1].1 - tt[1].0)
        #expect(th[0].1 - th[0].0 > th[1].1 - th[1].0)
    }

    @Test func offsettingARectangleGrowsOrShrinksIt() {
        // Clockwise in y-down coordinates: the left of travel is the outside.
        let r = rectPath(Rect(0, 0, 100, 50))
        let out = CompoundLine.offset(r, -5.0, 0.01).boundingBox
        #expect(abs(out.x0 + 5) < 1e-6 && abs(out.y0 + 5) < 1e-6 && abs(out.x1 - 105) < 1e-6 && abs(out.y1 - 55) < 1e-6, "\(out)")
        let inn = CompoundLine.offset(r, 5.0, 0.01).boundingBox
        #expect(abs(inn.x0 - 5) < 1e-6 && abs(inn.y1 - 45) < 1e-6, "\(inn)")
        // Corners meet at their miter points: the area is the offset rectangle's.
        #expect(abs(abs(CompoundLine.offset(r, -5.0, 0.01).area) - 110.0 * 60.0) < 1e-6)
    }

    @Test func offsettingACircleChangesItsRadius() {
        let c = Circle(Point(50, 50), 20).path(0.01)
        let b = CompoundLine.offset(c, 4.0, 0.01).boundingBox
        let w = b.width / 2.0
        #expect(abs(w - 16.0) < 0.2 || abs(w - 24.0) < 0.2, "radius \(w)")
        // A hostile path never traps.
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(0, 0))
        p.curveTo(Point(Double.greatestFiniteMagnitude, 0), Point(0, Double.leastNormalMagnitude), Point(1, 1))
        p.closePath()
        _ = CompoundLine.offset(p, 3.0, 0.01)
    }

    @Test func compoundLinesDrawTheirBands() {
        // A 24 pt outline on a rectangle, as PowerPoint's export draws each kind (top edge, outside
        // first): double 8/8/8, thin-thick 4.8/4.8/14.4, triple 4/4/8/4/4. Drawn straight on a canvas
        // at 2 px/pt (the Rust test renders a slide with the shape).
        let (_, rctx) = testContext()
        func runs(_ c: Compound) -> [Double] {
            guard let canvas = whiteCanvas(1000, 700) else { return [] }
            let line = Line(fill: .solid(color: .rgb(.rgb(0, 0, 0))), width: 24, compound: c)
            let m = Affine.scale(2.0) * Affine.translate(Vec2(100, 100))
            strokeLine(canvas, rctx, line, nil, rectPath(Rect(0, 0, 300, 200)), nil, m, 24, 1)
            let img = canvas.finish()
            var out: [(Bool, Double)] = []
            for y in 160 ..< 240 {
                let dark = (pixel(img, 500, y)?[0] ?? 255) < 128
                if let l = out.last, l.0 == dark { out[out.count - 1].1 += 0.5 } else { out.append((dark, 0.5)) }
            }
            return out.filter(\.0).map(\.1)
        }
        func close(_ got: [Double], _ want: [Double]) -> Bool {
            got.count == want.count && zip(got, want).allSatisfy { abs($0 - $1) <= 1.0 }
        }
        #expect(close(runs(.single), [24.0]))
        let d = runs(.double)
        #expect(close(d, [8.0, 8.0]), "\(d)")
        let t = runs(.thinThick)
        #expect(close(t, [4.8, 14.4]), "\(t)")
        let k = runs(.thickThin)
        #expect(close(k, [14.4, 4.8]), "\(k)")
        let tri = runs(.triple)
        #expect(close(tri, [4.0, 8.0, 4.0]), "\(tri)")
    }
}
