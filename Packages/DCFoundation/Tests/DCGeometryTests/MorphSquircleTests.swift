// Ported from deckcraft crates/geom/src/morph.rs and squircle.rs `mod tests` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
@testable import DCGeometry
import Foundation
import Testing

private func bbox(_ g: Preset.Geometry) -> Rect { g.outline.boundingBox }

private func near(_ a: Rect, _ b: Rect) -> Bool {
    abs(a.x0 - b.x0) < 1e-6 && abs(a.y0 - b.y0) < 1e-6 && abs(a.x1 - b.x1) < 1e-6 && abs(a.y1 - b.y1) < 1e-6
}

@Suite struct MorphTests {
    @Test func contoursTurnLinesAndQuadsIntoCubics() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(3, 0))
        p.quadTo(Point(3, 3), Point(0, 3))
        p.closePath()
        // After a close, drawing goes on from the start point.
        p.lineTo(Point(5, 5))
        p.moveTo(Point(9, 9))
        let cs = Morph.contours(p)
        #expect(cs.count == 2, "\(cs)")
        guard cs.count == 2 else { return }
        #expect(cs[0].closed && !cs[1].closed)
        // line, quad and the closing line.
        #expect(cs[0].curves == 3)
        #expect(cs[0].pts[1] == Point(1, 0))
        #expect(cs[0].pts.last == cs[0].pts.first)
        let end = Point(5, 5)
        #expect(cs[1].pts == [.zero, Point.zero.lerp(end, 1.0 / 3.0), Point.zero.lerp(end, 2.0 / 3.0), end])
        // The lone move_to at the end makes no contour, and the path comes back the same.
        #expect(Morph.contours(Morph.toPath(cs)) == cs)
    }

    @Test func refineSplitsTheLongestCurvesAndKeepsTheShape() {
        let c = Morph.Contour(closed: false, pts: [.zero, Point(1, 0), Point(2, 0), Point(3, 0)])
        var long = c
        Morph.lineTo(&long.pts, Point(3, 30))
        let r = Morph.refine(long, 5)
        #expect(r.curves == 5)
        // The short first side stays one curve, the long one gets the other four.
        #expect(r.pts[3] == Point(3, 0))
        #expect(r.pts.last == Point(3, 30))
        #expect(r.pts.allSatisfy { abs($0.x - 3) < 1e-9 || $0.y == 0 })
        #expect(Morph.refine(c, 1) == c)
        #expect(Morph.curvesFor(3, 4) == 12)
        #expect(Morph.curvesFor(4, 4) == 12)
        // The common multiple 77 is too many: the larger count, doubled to reach the minimum.
        #expect(Morph.curvesFor(7, 11) == 22)
        #expect(Morph.curvesFor(0, 0) == 12)
    }

    @Test func ellipseTurnsIntoAStarAndLandsExactly() throws {
        let a = try build("ellipse", 100, 100), b = try build("star5", 200, 100)
        let m = GeometryMorph(a, b)
        let one = Vec2(1, 1)
        #expect(near(bbox(m.at(0, one, one).0), bbox(a)))
        #expect(near(bbox(m.at(1, one, one).0), bbox(b)))
        let mid = m.at(0.5, one, one).0
        #expect(mid.paths.count == 1)
        #expect(mid.paths[0].path.elements.allSatisfy { $0.endPoint.map(\.isFinite) ?? true })
        // Non-finite progress is the start.
        #expect(near(bbox(m.at(.nan, one, one).0), bbox(a)))
    }

    @Test func triangleDoesNotTwistIntoACircle() throws {
        let a = try build("triangle", 100, 100), b = try build("ellipse", 100, 100)
        let (x, y) = Morph.align(Morph.contours(a.paths[0].path), Morph.contours(b.paths[0].path), nil, nil)
        // Every point travels less than the shapes are wide: no point crosses to the other side.
        let far = zip(x[0].pts, y[0].pts).map { $0.distance($1) }.reduce(0.0, max)
        #expect(far < 60, "\(far)")
    }

    @Test func extraSubPathsGrowOutOfAPoint() throws {
        let a = try build("rect", 100, 100), b = try build("cube", 100, 100)
        #expect(b.paths.count > 1)
        let m = GeometryMorph(a, b)
        let one = Vec2(1, 1)
        let start = m.at(0, one, one).0
        #expect(start.paths.count == b.paths.count)
        for sp in start.paths.dropFirst() {
            let r = sp.path.boundingBox
            #expect(r.width < 1e-9 && r.height < 1e-9, "\(r)")
        }
        // Looks switch at the midpoint: the cube's shaded faces show from there on.
        #expect(m.at(1, one, one).0.paths.map(\.fill) == b.paths.map(\.fill))
        // And the other way round, the faces shrink away.
        let back = GeometryMorph(b, a).at(1, one, one).0
        #expect(back.paths.dropFirst().allSatisfy { $0.path.boundingBox.area < 1e-9 })
    }

    @Test func differingLooksCrossFade() throws {
        let one = Vec2(1, 1)
        func fades(_ a: Preset.Geometry, _ b: Preset.Geometry, _ t: Double) -> [String] {
            let (g, f) = GeometryMorph(a, b).at(t, one, one)
            return zip(g.paths, f).map { "\($0.fill) \($0.evenOdd) \($0.stroke) \($1.fill) \($1.stroke)" }
        }
        // A filled rectangle into a line: the fill fades out, the outline stays.
        let r = try build("rect", 100, 100), line = try build("line", 100, 0)
        #expect(fades(r, line, 0.25) == ["norm false true 0.75 1.0"])
        #expect(fades(line, r, 0.25) == ["norm false true 0.25 1.0"])
        // A donut into a circle: the donut (even-odd) lies underneath, the circle fades in over its hole.
        let d = try build("donut", 100, 100), e = try build("ellipse", 100, 100)
        #expect(d.paths[0].evenOdd && !e.paths[0].evenOdd)
        #expect(fades(d, e, 0.25) == ["norm true true 1.0 1.0", "norm false false 0.25 0.0"])
        #expect(fades(e, d, 0.25) == ["norm true true 1.0 1.0", "norm false false 0.75 0.0"])
        // Same looks: one layer, fully there.
        #expect(fades(e, r, 0.5) == ["norm false true 1.0 1.0"])
    }

    @Test func scalesBringBothSidesIntoTheCurrentBox() throws {
        let a = try build("rect", 10, 10), b = try build("ellipse", 40, 20)
        let m = GeometryMorph(a, b)
        // Current box 20 x 20: a scaled up twice, b to half the width.
        var g = m.at(0, Vec2(2, 2), Vec2(0.5, 1)).0
        #expect(near(bbox(g), Rect(0, 0, 20, 20)))
        #expect(near(g.textRect, Rect(a.textRect.x0 * 2, a.textRect.y0 * 2, a.textRect.x1 * 2, a.textRect.y1 * 2)))
        g = m.at(1, Vec2(2, 2), Vec2(0.5, 1)).0
        #expect(near(bbox(g), Rect(0, 0, 20, 20)))
    }

    @Test func emptyAndDegenerateGeometriesDoNotCrash() throws {
        let empty = Preset.Geometry(paths: [], textRect: .zero, handles: [], sites: [])
        let r = try build("rect", 10, 10), line = try build("line", 10, 0)
        var nan = BezPath()
        nan.moveTo(Point(.nan, 0))
        nan.lineTo(Point(1, 1))
        var bad = empty
        bad.paths = [Preset.SubPath(path: nan, fill: .norm, stroke: true, evenOdd: false)]
        for (x, y) in [(empty, empty), (empty, r), (r, empty), (r, line), (line, r), (bad, r), (r, bad)] {
            for t in [0.0, 0.5, 1.0, .infinity] {
                let g = GeometryMorph(x, y).at(t, Vec2(1, 1), Vec2(0, 1e300)).0
                // At most two layers per sub-path pair.
                #expect(g.paths.count <= 2 * max(x.paths.count, y.paths.count))
            }
        }
        // A rectangle into a line: the line is open, so the morph ends open.
        let g = GeometryMorph(r, line).at(1, Vec2(1, 1), Vec2(1, 1)).0
        #expect(!g.paths[0].path.elements.contains(.closePath))
    }

    @Test func longContoursSampleTheirStartPoints() throws {
        // A polygon with many corners still aligns (and quickly): the start search is capped.
        var p = BezPath()
        for k in 0 ..< 2000 {
            let a = Double(k) / 2000 * 2 * Double.pi
            let q = Point(50 + 50 * cos(a), 50 + 50 * sin(a))
            if k == 0 { p.moveTo(q) } else { p.lineTo(q) }
        }
        p.closePath()
        let many = Morph.contours(p)
        let e = Morph.contours(try build("ellipse", 100, 100).paths[0].path)
        let (x, y) = Morph.align(many, e, nil, nil)
        #expect(x[0].curves == y[0].curves)
        #expect(x[0].curves == 2000)
    }
}

private func numbers(_ d: String) -> [Double] {
    d.split(separator: " ").compactMap { Double($0) }
}

@Suite struct SquircleTests {
    @Test func noRadiusIsARectangle() {
        #expect(Squircle.pathD(100, 50, 0, 0.6) == "M 0 0 L 100 0 L 100 50 L 0 50 Z")
    }

    @Test func edgeCurveMeetsTheArc() {
        for s in [0.0, 0.3, 0.6, 1.0] {
            let c = Squircle.corner(10, s)
            let seg = c.segments
            let e3 = (c.p - c.a - c.b - c.c, c.d)
            // The arc starts on the circle and where the edge curve ends.
            #expect(abs(seg[3].0 - e3.0) < 1e-6 && abs(seg[3].1 - e3.1) < 1e-6, "s=\(s): \(seg[3]) vs \(e3)")
            // The arc is symmetric about the diagonal u = v.
            #expect(abs(seg[3].0 - seg[6].1) < 1e-9 && abs(seg[3].1 - seg[6].0) < 1e-9)
        }
    }

    @Test func zeroSmoothingIsACircularCorner() {
        let c = Squircle.corner(10, 0)
        let seg = c.segments
        #expect(abs(c.p - 10) < 1e-9)
        #expect(abs(seg[3].0 - 10) < 1e-9 && abs(seg[3].1) < 1e-9)
        #expect(abs(seg[6].0) < 1e-9 && abs(seg[6].1 - 10) < 1e-9)
    }

    @Test func smoothingUsesMoreOfTheEdge() {
        let d0 = numbers(Squircle.pathD(200, 100, 20, 0))
        let d6 = numbers(Squircle.pathD(200, 100, 20, 0.6))
        // The first point is where the top-right corner starts on the top edge.
        #expect(d0[0] == 180 && d0[1] == 0)
        #expect(d6[0] == 168 && d6[1] == 0)
    }

    @Test func staysInsideAndReducesSmoothingWhenTheRectangleIsSmall() {
        for (w, h, r, s) in [(100.0, 40.0, 20.0, 1.0), (40, 40, 50, 0.8), (10, 300, 4, 0.6), (300, 120, 30, 0.6)] {
            let n = numbers(Squircle.pathD(w, h, r, s))
            #expect(stride(from: 0, to: n.count - 1, by: 2).allSatisfy { n[$0] >= -1e-6 && n[$0] <= w + 1e-6 && n[$0 + 1] >= -1e-6 && n[$0 + 1] <= h + 1e-6 }, "\(w)x\(h) r\(r) s\(s)")
            // Corners never cross the middle of an edge.
            #expect(n[0] >= w / 2 - 1e-6)
        }
        #expect(numbers(Squircle.pathD(.nan, 10, .infinity, .nan)).allSatisfy { $0.isFinite })
    }

    @Test func fourSymmetricCorners() {
        let n = numbers(Squircle.pathD(120, 80, 16, 0.6))
        // 4 corners x 10 points, 2 numbers each.
        #expect(n.count == 80)
        let pts = stride(from: 0, to: n.count - 1, by: 2).map { (n[$0], n[$0 + 1]) }
        for (x, y) in pts {
            let mirrored = (120 - x, 80 - y)
            #expect(pts.contains { abs($0.0 - mirrored.0) < 0.01 && abs($0.1 - mirrored.1) < 0.01 }, "\(x),\(y)")
        }
    }

    // New: Rust's `Display` for floats, which the path text relies on.
    @Test func rustDisplayFormatting() {
        #expect(rustDisplay(168) == "168")
        #expect(rustDisplay(0.5) == "0.5")
        #expect(rustDisplay(-0.0) == "-0")
        #expect(rustDisplay(1e21) == "1000000000000000000000")
        #expect(rustDisplay(1e-7) == "0.0000001")
        #expect(rustDisplay(191.046) == "191.046")
        #expect(rustDisplay(.nan) == "NaN")
    }
}
