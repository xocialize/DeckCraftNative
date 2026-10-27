// Ported from deckcraft crates/render/src/tests_wild.rs (dashes, caps, arrowheads, trims, gradient
// lines, shadow transforms; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The
// pixel tests draw the line straight onto a `Canvas` where the Rust ones render a slide holding it;
// tolerances are the Rust ones unless noted.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import Testing

@Suite struct StrokeTests {
    /// A horizontal line `len` long from (100, 100), as the `line` preset draws it, with its heads
    /// trimmed off and drawn as the renderer core does.
    func drawLine(_ line: Line, _ len: Double, _ w: Int = 400, _ h: Int = 200) -> RenderImage? {
        let (_, rctx) = testContext()
        guard let c = whiteCanvas(w, h), let geo = Preset.build("line", len, 0, []), let sp = geo.paths.first(where: \.stroke) else { return nil }
        let lw = line.width ?? 0.75
        let m = Affine.translate(Vec2(100, 100))
        let trims = headTrims(line, lw)
        let path = trims == (0, 0) ? sp.path : trimEnds(sp.path, trims.0, trims.1)
        strokeLine(c, rctx, line, nil, path, sp.path, m, lw, 1)
        arrowheads(c, rctx, line, nil, geo, .identity, m, lw)
        return c.finish()
    }

    func dotted(_ cap: LineCap, _ len: Double) -> RenderImage? {
        drawLine(Line(fill: .solid(color: .rgb(red)), width: 10, dash: .preset(name: "sysDot"), cap: cap), len)
    }

    @Test func roundDotsAreSeparateCirclesWithTheCapsInsideEachDash() throws {
        let img = try #require(dotted(.round, 200))
        #expect(near(img, 100, 100, red, 40), "a dot centred on the start \(pixel(img, 100, 100) ?? [])")
        #expect(near(img, 120, 100, red, 40), "the next dot one period on")
        #expect(near(img, 110, 100, .white, 10), "a gap between dots \(pixel(img, 110, 100) ?? [])")
        // Flat caps: each dash is a width long, from the start.
        let flat = try #require(dotted(.flat, 200))
        #expect(near(flat, 105, 100, red, 40) && near(flat, 115, 100, .white, 10))
        // Square caps: dashes end flat; only the line's own start is squared off, half a width back.
        let sq = try #require(dotted(.square, 200))
        #expect(near(sq, 97, 100, red, 40), "square cap before the start \(pixel(sq, 97, 100) ?? [])")
        #expect(near(sq, 105, 100, red, 40) && near(sq, 115, 100, .white, 10), "dashes keep their length")
        #expect(near(sq, 122, 100, red, 40) && near(sq, 118, 100, .white, 10), "no cap on the next dash")
        // 200 pt is ten whole periods, so the line ends in a gap and gets no cap.
        #expect(near(sq, 302, 100, .white, 10), "\(pixel(sq, 302, 100) ?? [])")
        // 205 pt ends half way through a dash: squared off past the end.
        let sq2 = try #require(dotted(.square, 205))
        #expect(near(sq2, 308, 100, red, 40), "\(pixel(sq2, 308, 100) ?? [])")
    }

    @Test func dashLengthsMakeRoomForRoundAndSquareCaps() {
        #expect(dashWithCaps([4, 3], .round, 1) == [3, 4])
        #expect(dashWithCaps([1, 1], .round, 2) == [0.002, 3])
        #expect(dashWithCaps([1, 1], .square, 2) == [1, 1])
        #expect(dashWithCaps([4, 3], .butt, 1) == [4, 3])
        #expect(dashWithCaps([4, 3, 1], .round, 1) == [4, 3, 1])
    }

    func arrow(_ kind: String, _ width: Double, _ c: Rgba) -> Line {
        Line(fill: .solid(color: .rgb(c)), width: width, tail: LineEnd(kind: kind, w: "med", len: "med"))
    }

    @Test func aWideLineStopsInsideItsArrowhead() throws {
        // 10 pt line, medium triangle (30 pt long, 30 wide) whose tip is the line's end at x = 300.
        let img = try #require(drawLine(arrow("triangle", 10, red), 200))
        #expect(near(img, 297, 100, red, 40), "the tip \(pixel(img, 297, 100) ?? [])")
        // 2 pt back from the tip the triangle is 2 pt wide: the line's corner must not show there.
        #expect(near(img, 298, 104, .white, 10), "line corner past the head \(pixel(img, 298, 104) ?? [])")
    }

    @Test func anOpenArrowheadsPointIsOnTheLinesEnd() throws {
        let img = try #require(drawLine(arrow("arrow", 8, red), 200))
        let reach = (290 ..< 320).reversed().first { (pixel(img, $0, 100)?[1] ?? 255) < 128 }
        #expect(reach.map { $0 <= 300 && $0 >= 297 } == true, "point reaches \(String(describing: reach))")
    }

    @Test func ovalStealthAndDiamondHeadsSitOnTheEnd() throws {
        for kind in ["oval", "diamond", "stealth"] {
            let img = try #require(drawLine(arrow(kind, 4, red), 200))
            // Medium heads on a 4 pt line are 12 pt wide: red above and below the line near the end.
            let x = kind == "stealth" ? 293 : 300
            #expect(near(img, x, 102, red, 60), "\(kind) \(pixel(img, x, 102) ?? [])")
            #expect(near(img, x, 97, red, 60), "\(kind)")
            #expect(near(img, 320, 100, .white, 10), "\(kind) nothing past the end")
        }
    }

    @Test func arrowheadsAreSizedForAtLeastATwoPointLine() {
        let e = LineEnd(kind: "triangle", w: "sm", len: "lg")
        #expect(headSize(e, 0.5) == (4.0, 10.0))
        #expect(headSize(e, 4.0) == (8.0, 20.0))
    }

    @Test func trimmingAPathLeavesItsEndsOffByArcLength() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(50, 0))
        p.lineTo(Point(50, 50))
        let t = trimEnds(p, 10, 20)
        #expect(t.elements.first == .moveTo(Point(10, 0)))
        if case .lineTo(let q) = t.elements.last {
            #expect(abs(q.x - 50) < 1e-6 && abs(q.y - 30) < 1e-6, "\(q)")
        } else {
            Issue.record("\(String(describing: t.elements.last))")
        }
        // Trims longer than the path leave nothing; closed paths are untouched.
        #expect(trimEnds(p, 60, 50).elements.isEmpty)
        let r = rectPath(Rect(0, 0, 10, 10))
        #expect(trimEnds(r, 3, 3).elements.count == r.elements.count)
        // Zero-length leading segments are trimmed too.
        var p0 = BezPath()
        p0.moveTo(Point(0, 0))
        p0.lineTo(Point(0, 0))
        p0.lineTo(Point(0, 0))
        p0.lineTo(Point(50, 0))
        #expect(trimEnds(p0, 10, 0).elements.first == .moveTo(Point(10, 0)))
    }

    @Test func headTrimsReachTheBaseNotchOrMeetingPoint() {
        let line = Line(width: 10, head: LineEnd(kind: "triangle", w: "med", len: "med"), tail: LineEnd(kind: "oval", w: "med", len: "med"))
        #expect(headTrims(line, 10) == (30, 0))
        var sq = line
        sq.cap = .square
        #expect(headTrims(sq, 10) == (35, 0))
        let stealth = Line(width: 10, head: LineEnd(kind: "stealth", w: "med", len: "med"))
        #expect(abs(headTrims(stealth, 10).0 - 30 * (0.6 + 0.4 * 10 / 30)) < 1e-12)
    }

    @Test func dashCountsAreLimited() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(100, 0))
        #expect(limitDashCount(p, [1, 1]) == [1, 1])
        p.lineTo(Point(4.0e6, 0))
        let pat = limitDashCount(p, [1, 1])
        #expect(abs(4.0e6 / ((pat.first ?? 1) + (pat.last ?? 1)) - maxDashes) < 1.0, "\(pat)")
        // A hairline with a tiny custom dash on a huge path still strokes, promptly.
        let (_, rctx) = testContext()
        if let c = Canvas(width: 100, height: 20) {
            var huge = BezPath()
            huge.moveTo(Point(0, 10))
            huge.lineTo(Point(2.0e9, 10))
            let line = Line(fill: .solid(color: .rgb(red)), width: 0.0001, dash: .custom(pattern: [Pair(1.0, 1.0)]))
            strokeLine(c, rctx, line, nil, huge, nil, .scale(0.25), 0.0001, 1)
            #expect(c.finish().width == 100)
        }
    }

    @Test func squareDashEndsCapOnlyTheLinesOwnEnds() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(25, 0))
        // [10, 10] over 25: ends 5 into a dash, so both ends get a cap.
        let both = squareDashEnds(p, [10, 10], 4).boundingBox
        #expect(both == Rect(-2, -2, 27, 2), "\(both)")
        // Over 20 it ends on a period boundary (in a gap): only the start.
        var q = BezPath()
        q.moveTo(Point(0, 0))
        q.lineTo(Point(20, 0))
        #expect(squareDashEnds(q, [10, 10], 4).boundingBox == Rect(-2, -2, 0, 2))
        // Closed sub-paths get none.
        #expect(squareDashEnds(rectPath(Rect(0, 0, 10, 10)), [3, 3], 2).elements.isEmpty)
    }

    @Test func gradientLinesAndTheirHeadsTakeTheGradient() throws {
        func grad(_ angle: Double) -> Fill {
            .gradient(Gradient(stops: [GradientStop(pos: 0, color: .rgb(red)), GradientStop(pos: 1, color: .rgb(blue))],
                               shape: .linear(angle: angle, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0]))
        }
        // Left to right along a 20 pt line: red at its start, blue at its end, and the head blue too.
        var l = arrow("triangle", 20, red)
        l.fill = grad(0)
        let img = try #require(drawLine(l, 200))
        let (start, mid, head) = (pixel(img, 102, 100) ?? [], pixel(img, 200, 100) ?? [], pixel(img, 296, 100) ?? [])
        #expect((start.first ?? 0) > 200 && (start.at(2) ?? 255) < 60, "\(start)")
        #expect((mid.first ?? 0) > 60 && (mid.at(2) ?? 0) > 60, "\(mid)")
        #expect((head.at(2) ?? 0) > 200 && (head.first ?? 255) < 60, "head \(head)")
        // Top to bottom across a horizontal line: the gradient runs over the line's width.
        var n = arrow("none", 20, red)
        n.fill = grad(90)
        let across = try #require(drawLine(n, 200))
        let (top, bottom) = (pixel(across, 200, 91) ?? [], pixel(across, 200, 109) ?? [])
        #expect((top.first ?? 0) > 200 && (top.at(2) ?? 255) < 60 && (bottom.at(2) ?? 0) > 200 && (bottom.first ?? 255) < 60, "\(top) \(bottom)")
    }

    @Test func pictureBordersAreDrawnOutsideUnlessIn3D() {
        #expect(borderOutside(true, nil))
        #expect(!borderOutside(false, nil))
        #expect(borderOutside(true, Effects(bevel: "circle")))
        #expect(!borderOutside(true, Effects(bevel: "circle", raw3d: "<a:scene3d/>")))
        let line = Line(width: 4, dash: .preset(name: "dash"))
        let out = outsideLine(line, 4)
        #expect(out?.width == 8)
        #expect(out?.dash?.pattern == [2, 1.5])
        #expect(outsideLine(Line(compound: .double), 4) == nil)
        #expect(outsideLine(Line(compound: .single), 4)?.width == 8)
    }

    @Test func fillOpacityIsTheMeanAlpha() {
        let (_, rctx) = testContext()
        #expect(fillOpacity(rctx, nil, nil) == nil)
        #expect(fillOpacity(rctx, .none_, nil) == nil)
        #expect(fillOpacity(rctx, .solid(color: .rgb(.rgba(0, 0, 0, 51))), nil) == 0.2)
        let g = Fill.gradient(Gradient(stops: [GradientStop(pos: 0, color: .rgb(.rgba(0, 0, 0, 255))), GradientStop(pos: 1, color: .rgb(.rgba(0, 0, 0, 0)))],
                                       shape: .linear(angle: 0, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0]))
        #expect(fillOpacity(rctx, g, nil) == 0.5)
        #expect(fillOpacity(rctx, .pattern(PatternFill(preset: "pct50", fg: .rgb(.black), bg: .rgb(.white))), nil) == 1.0)
    }

    @Test func aPerspectiveShadowPivotsOnItsAlignment() {
        // Half height, skewed 45° so its top leans right, anchored at the bottom middle of a 100×100
        // box: the bottom edge stays put and the top (y = 50) leans right (its left corner to x = 100).
        let sh = Shadow(color: .rgb(.black), blur: 0, dist: 0, dir: 0, inner: false, sx: 1, sy: 0.5, kx: -45, ky: 0, align: "b", rotateWithShape: false)
        let m = shadowLocal(sh, 100, 100)
        let bottom = m * Point(0, 100)
        let top = m * Point(0, 0)
        #expect(abs(bottom.x) < 1e-9 && abs(bottom.y - 100) < 1e-9)
        #expect(abs(top.y - 50) < 1e-9 && abs(top.x - 100) < 1e-9, "\(top)")
        // Anchored bottom-right and half as big again: it grows up and to the left only.
        var big = sh
        (big.sx, big.sy, big.kx, big.align) = (1.5, 1.5, 0, "br")
        let g = shadowLocal(big, 100, 100)
        #expect(g * Point(100, 100) == Point(100, 100))
        #expect(g * Point(0, 0) == Point(-50, -50))
        // A non-finite skew falls back to no transform.
        big.kx = .nan
        #expect(shadowLocal(big, 100, 100) == .identity)
    }

    @Test func endPointsSkipRepeatedPoints() {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(0, 0))
        p.curveTo(Point(10, 0), Point(20, 5), Point(30, 5))
        p.lineTo(Point(30, 5))
        let e = endPoints(p)
        #expect(e?.0.0 == Point(0, 0) && e?.0.1 == Point(10, 0))
        #expect(e?.1.0 == Point(30, 5) && e?.1.1 == Point(20, 5))
        var one = BezPath()
        one.moveTo(Point(1, 1))
        #expect(endPoints(one) == nil)
    }
}
