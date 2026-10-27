// Ported from deckcraft crates/render/src/pathgrad.rs `mod tests` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
import DCColor
import DCGeometry
@testable import DCRender
import Foundation
import Testing

@Suite struct PathGradientTests {
    let centre = [0.5, 0.5, 0.5, 0.5]

    func ellipse(_ b: Rect) -> [[Point]] {
        PathGradient.polygons(Ellipse(center: b.center, radii: Vec2(b.width / 2, b.height / 2), xRotation: 0).path(0.01))
    }

    @Test func rectPathsTakeTheLargerAxisShare() {
        // PowerPoint, 280x200 box from the centre: 20 px across is 1/7, 20 px down is 1/5.
        let b = Rect(0, 0, 280, 200)
        func at(_ x: Double, _ y: Double) -> Double { PathGradient.position("rect", b, centre, [], Point(x, y)) }
        #expect(abs(at(160, 100) - 20.0 / 140.0) < 1e-9)
        #expect(abs(at(140, 120) - 20.0 / 100.0) < 1e-9)
        #expect(abs(at(168, 120) - 0.2) < 1e-9, "the diagonal takes the larger share")
        #expect(at(0, 0) == 1.0)
        // From a corner (fillToRect 0,0,100%,100%): the far corner is the end.
        #expect(abs(PathGradient.position("rect", b, [0, 0, 1, 1], [], Point(140, 50)) - 0.5) < 1e-9)
    }

    @Test func shapePathsFollowTheOutline() {
        let b = Rect(0, 0, 280, 200)
        let e = ellipse(b)
        func at(_ x: Double, _ y: Double) -> Double { PathGradient.position("shape", b, centre, e, Point(x, y)) }
        #expect(abs(at(160, 100) - 20.0 / 140.0) < 0.01)
        #expect(abs(at(140, 120) - 0.2) < 0.01)
        // Half way to the outline along any ray is 0.5.
        let (dx, dy) = (140.0 * 0.6, 100.0 * 0.8)
        #expect(abs(at(140 + dx * 0.5, 100 + dy * 0.5) - 0.5) < 0.01)
        // A triangle: half way from its centre to its apex is 0.5.
        var tri = BezPath()
        tri.moveTo(Point(140, 0))
        tri.lineTo(Point(280, 200))
        tri.lineTo(Point(0, 200))
        tri.closePath()
        #expect(abs(PathGradient.position("shape", b, centre, PathGradient.polygons(tri), Point(140, 50)) - 0.5) < 1e-6)
    }

    @Test func shapePathsFromOffTheShapeOrAFocusBox() {
        let b = Rect(0, 0, 280, 200)
        let e = ellipse(b)
        // Focus on the box's corner, outside the ellipse: its far edge is the end and its middle part way.
        let corner = [0.0, 0.0, 1.0, 1.0]
        let mid = PathGradient.position("shape", b, corner, e, Point(140, 100))
        #expect(mid > 0.3 && mid < 0.8, "\(mid)")
        #expect(PathGradient.position("shape", b, corner, e, Point(279, 100)) > 0.95)
        // A focus rectangle is the first colour inside, and the colour runs from its edge out.
        let boxed = [0.25, 0.25, 0.25, 0.25]
        #expect(PathGradient.position("shape", b, boxed, e, Point(150, 110)) == 0.0)
        let half = PathGradient.position("shape", b, boxed, e, Point(140 + 70 + 35, 100))
        #expect(abs(half - 0.5) < 0.02, "\(half)")
    }

    func manySegmentSquare(_ n: Int) -> BezPath {
        // A 200x200 square whose sides are split into `n` segments each.
        var p = BezPath()
        p.moveTo(Point(0, 0))
        var from = (0.0, 0.0)
        for to in [(200.0, 0.0), (200.0, 200.0), (0.0, 200.0), (0.0, 0.0)] {
            for i in 1 ... n {
                let t = Double(i) / Double(n)
                p.lineTo(Point(from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t))
            }
            from = to
        }
        p.closePath()
        return p
    }

    @Test func denseOutlinesAreSimplifiedToTheWorkBudget() {
        let polys = PathGradient.polygons(manySegmentSquare(20_000))
        #expect(PathGradient.edges(polys) >= 80_000)
        let b = Rect(0, 0, 200, 200)
        let simple = PathGradient.simplify(polys, 200.0 / 384.0, 400)
        let edges = PathGradient.edges(simple)
        #expect((PathGradient.minPolyEdges ... 400).contains(edges), "\(edges)")
        // Still the square: half way to a side or a corner is 0.5.
        for q in [Point(150, 100), Point(150, 150), Point(100, 50)] {
            let t = PathGradient.position("shape", b, centre, simple, q)
            #expect(abs(t - 0.5) < 0.01, "\(q) \(t)")
        }
        // Small outlines pass through untouched.
        let tri = [[Point(0, 0), Point(1, 0), Point(0, 1), Point(0, 0)]]
        #expect(PathGradient.simplify(tri, 10, 400) == tri)
    }

    @Test func aDenseShapeGradientRendersPromptly() throws {
        let path = manySegmentSquare(20_000)
        let c = try #require(Canvas(width: 400, height: 400))
        let start = Date()
        PathGradient.fill(c, "shape", centre, [(0, .rgb(0, 0, 0)), (1, .rgb(255, 255, 255))], Rect(0, 0, 200, 200), path, .scale(2), 1)
        // Unbudgeted this is 147k pixels × 80k edges (minutes); budgeted, well under a second in release.
        #expect(Date().timeIntervalSince(start) < 20)
        let img = c.finish()
        #expect((pixel(img, 200, 200)?[0] ?? 255) < 10, "dark at the centre")
        #expect((pixel(img, 2, 200)?[0] ?? 0) > 240, "light at the edge")
    }

    @Test func theRampRunsThroughTheStops() {
        let r = PathGradient.ramp([(0, .rgb(0, 0, 0)), (0.5, .rgb(128, 128, 128)), (1, .rgb(255, 255, 255))])
        #expect(r.count == 256)
        #expect(r[0] == .rgb(0, 0, 0))
        #expect(r[255] == .rgb(255, 255, 255))
        #expect(abs(Int(r[64].r) - 64) <= 2)
        #expect(PathGradient.ramp([(0.3, .rgb(9, 9, 9))]).allSatisfy { $0 == .rgb(9, 9, 9) })
    }
}
