// Ported from deckcraft crates/geom/src/preset.rs and preset/extra.rs `mod tests` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
@testable import DCGeometry
import Foundation
import Testing

/// The squared distance from `p` to a segment. kurbo's `nearest` solves it analytically; this samples the
/// curve and refines the best sample by golden-section search, which is as exact as the tests need.
func nearestDistanceSquared(_ seg: PathSeg, _ p: Point) -> Double {
    func d2(_ t: Double) -> Double { seg.eval(t).distanceSquared(p) }
    if case .line(let l) = seg {
        let ab = l.p1 - l.p0
        let len2 = ab.hypot2
        let t = len2 > 0 ? ((p - l.p0).dot(ab) / len2).clamp(0, 1) : 0
        return d2(t)
    }
    let n = 512
    var bestT = 0.0
    var best = d2(0)
    for i in 1 ... n {
        let t = Double(i) / Double(n)
        let v = d2(t)
        if v < best { (best, bestT) = (v, t) }
    }
    var lo = max(bestT - 1.0 / Double(n), 0), hi = min(bestT + 1.0 / Double(n), 1)
    let g = (5.0.squareRoot() - 1) / 2
    for _ in 0 ..< 100 {
        let a = hi - g * (hi - lo), b = lo + g * (hi - lo)
        if d2(a) < d2(b) { hi = b } else { lo = a }
    }
    return min(best, d2((lo + hi) / 2))
}

func onPath(_ g: Preset.Geometry, _ p: Point, _ tol: Double) -> Bool {
    g.paths.contains { sp in sp.path.segments.contains { nearestDistanceSquared($0, p) <= tol * tol } }
}

/// The end points of a path's move/line elements, in order.
func vertices(_ p: BezPath) -> [Point] {
    p.elements.compactMap { e in
        switch e {
        case .moveTo(let q), .lineTo(let q): q
        default: nil
        }
    }
}

func build(_ name: String, _ w: Double, _ h: Double, _ adj: [Double] = []) throws -> Preset.Geometry {
    try #require(Preset.build(name, w, h, adj), "\(name) did not build")
}

@Suite struct PresetTests {
    @Test func everyCatalogPresetBuildsWithinBounds() throws {
        for p in Preset.catalog {
            for (w, h) in [(200.0, 100.0), (100.0, 200.0), (50.0, 50.0), (0.0, 0.0), (1.0, 300.0)] {
                let g = try build(p.name, w, h)
                #expect(!g.paths.isEmpty, "\(p.name) has no paths")
                for s in g.paths {
                    let bb = s.path.boundingBox
                    if w > 0 && h > 0 && !p.name.contains("Connector") && !p.name.contains("allout") {
                        let tol = max(w, h) * 0.35 + 1.0
                        #expect(bb.x0 >= -tol && bb.y0 >= -tol && bb.x1 <= w + tol && bb.y1 <= h + tol, "\(p.name) \(w)x\(h) out of bounds: \(bb)")
                    }
                    #expect(bb.x0.isFinite && bb.y1.isFinite, "\(p.name) produced non-finite geometry")
                }
                #expect(g.textRect.x0.isFinite && g.textRect.y1.isFinite, "\(p.name)")
            }
        }
    }

    @Test func hostileAdjustValuesNeverPanic() {
        for p in Preset.catalog {
            for v in [Double.nan, .infinity, -1e12, 1e12, -1.0, 0.0] {
                #expect(Preset.build(p.name, 120, 80, Array(repeating: v, count: 6)) != nil, "\(p.name)")
            }
        }
        #expect(Preset.build("rect", .nan, 10, []) == nil)
        #expect(Preset.build("noSuchShape", 10, 10, []) == nil)
    }

    @Test func catalogNamesAreUnique() {
        let names = Preset.catalog.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count >= 140, "catalog has \(names.count) presets")
    }

    @Test func roundRectHandleMapsBack() throws {
        let g = try build("roundRect", 200, 100, [16667])
        let h = try #require(g.handles.first)
        #expect(abs(h.valueAt(h.pos) - 16667) <= 1)
        #expect(h.valueAt(Point(-50, 0)) == 0)
        #expect(h.valueAt(Point(500, 0)) == 50000)
    }

    @Test func partialCircleAngleHandlesMapBack() throws {
        // Start 0° sits at the right of the ellipse, end 270° at its top.
        for name in ["pie", "chord", "arc"] {
            let g = try build(name, 200, 100, [0, 16_200_000])
            #expect(g.handles.map(\.index) == [0, 1], "\(name)")
            let (s, e) = (g.handles[0], g.handles[1])
            #expect((s.pos - Point(200, 50)).hypot < 1e-6, "\(name) \(s.pos)")
            #expect((e.pos - Point(100, 0)).hypot < 1e-6, "\(name) \(e.pos)")
            #expect(s.valueAt(s.pos) == 0, "\(name)")
            #expect(e.valueAt(e.pos) == 16_200_000, "\(name)")
            // Dragging to the bottom of the ellipse gives 90°.
            #expect(s.valueAt(Point(100, 100)) == 5_400_000, "\(name)")
            // Off-axis angles on a non-square ellipse: the visual 45° ray meets the 200×100 ellipse at
            // offset (√2000, √2000) from the centre.
            let k = 2000.0.squareRoot()
            let g2 = try build(name, 200, 100, [2_700_000, 8_100_000])
            let (s2, e2) = (g2.handles[0], g2.handles[1])
            #expect((s2.pos - Point(100 + k, 50 + k)).hypot < 1e-6, "\(name) \(s2.pos)")
            #expect((e2.pos - Point(100 - k, 50 + k)).hypot < 1e-6, "\(name) \(e2.pos)")
            for (deg, h) in [(45.0, s2), (135.0, e2)] {
                let ox = (h.pos.x - 100) / 100, oy = (h.pos.y - 50) / 50
                #expect(abs(ox * ox + oy * oy - 1) < 1e-9, "\(name) \(deg)° off ellipse: \(h.pos)")
                #expect(abs(h.valueAt(h.pos) - deg * 60000) <= 1, "\(name) \(deg)°: \(h.valueAt(h.pos))")
            }
        }
        for deg in [45.0, 135.0, 200.0, 315.0] {
            let g = try build("blockArc", 200, 100, [deg * 60000, 0, 25000])
            let start = try #require(g.handles.first { $0.index == 0 })
            // Thickness 25 → the handle runs on the 87.5×37.5 mid-ring ellipse.
            let ox = (start.pos.x - 100) / 87.5, oy = (start.pos.y - 50) / 37.5
            #expect(abs(ox * ox + oy * oy - 1) < 1e-9, "blockArc \(deg)° off ring: \(start.pos)")
            let d = start.pos - Point(100, 50)
            #expect(abs(atan2(d.y, d.x).degrees.remEuclid(360) - deg) < 1e-6, "blockArc \(deg)°: \(start.pos)")
            #expect(abs(start.valueAt(start.pos) - deg * 60000) <= 1, "blockArc \(deg)°")
        }
        let g = try build("blockArc", 200, 100, [10_800_000, 0, 25000])
        let start = try #require(g.handles.first { $0.index == 0 })
        #expect(start.valueAt(start.pos) == 10_800_000)
        let thick = try #require(g.handles.first { $0.index == 2 })
        #expect(abs(thick.valueAt(thick.pos) - 25000) <= 1)
    }

    @Test func presetsWithAdjustValuesExposeHandles() throws {
        // Presets whose adjust values have no handle of their own yet.
        let noHandles: Set<String> = [
            "curvedConnector3", "snip2SameRect", "snip2DiagRect", "snipRoundRect", "round1Rect", "round2SameRect",
            "round2DiagRect", "teardrop", "halfFrame", "corner", "diagStripe", "foldedCorner", "smileyFace", "moon",
            "gear6", "gear9", "bracketPair", "bracePair", "leftBracket", "rightBracket", "leftBrace", "rightBrace",
            "leftRightArrow", "upDownArrow", "quadArrow", "leftRightUpArrow", "bentArrow", "uturnArrow", "curvedRightArrow",
            "curvedLeftArrow", "curvedUpArrow", "curvedDownArrow", "leftUpArrow", "bentUpArrow", "circularArrow",
            "leftCircularArrow", "leftRightCircularArrow", "swooshArrow", "rightArrowCallout", "downArrowCallout",
            "leftArrowCallout", "upArrowCallout", "leftRightArrowCallout", "upDownArrowCallout", "quadArrowCallout",
            "mathPlus", "mathMinus", "mathMultiply", "mathDivide", "mathEqual", "mathNotEqual", "ribbon2", "ribbon",
            "ellipseRibbon2", "ellipseRibbon", "leftRightRibbon", "verticalScroll", "horizontalScroll", "wave",
            "doubleWave", "borderCallout1", "borderCallout2", "borderCallout3", "accentCallout1", "accentCallout2",
            "accentCallout3", "callout1", "callout2", "callout3", "accentBorderCallout1", "accentBorderCallout2",
            "accentBorderCallout3",
        ]
        for p in Preset.catalog where !p.defaults.isEmpty && !noHandles.contains(p.name) {
            #expect(try !build(p.name, 200, 100).handles.isEmpty, "\(p.name) has adjust values but no handles")
        }
    }

    @Test func rectAreaAndEllipseArea() throws {
        #expect(abs(abs(try build("rect", 100, 50).paths[0].path.area) - 5000) < 1e-6)
        let expect = Double.pi * 50 * 25
        #expect(abs(abs(try build("ellipse", 100, 50).paths[0].path.area) - expect) / expect < 0.01)
    }

    @Test func linesAreOpen() throws {
        #expect(try build("line", 10, 10).isOpen)
        #expect(try !build("rect", 10, 10).isOpen)
    }

    @Test func fixedShapesFollowTheStandardsCoordinates() throws {
        // Points of ECMA-376's definitions (in 21600ths), checked on a 216 × 108 box.
        let (w, h) = (216.0, 108.0)
        func at(_ x: Double, _ y: Double) -> Point { Point(w * x / 21600, h * y / 21600) }
        var g = try build("lightningBolt", w, h)
        for (x, y) in [(8472.0, 0.0), (16577, 12007), (21600, 21600), (0, 3890)] {
            #expect(onPath(g, at(x, y), 1e-6), "lightningBolt (\(x), \(y))")
        }
        g = try build("irregularSeal1", w, h)
        #expect(onPath(g, at(14522, 0), 1e-6) && onPath(g, at(8485, 21600), 1e-6))
        g = try build("irregularSeal2", w, h)
        #expect(onPath(g, at(14790, 0), 1e-6) && onPath(g, at(4917, 21600), 1e-6))
        // The heart's point is the middle of the bottom edge, its notch a quarter down.
        g = try build("heart", w, h)
        #expect(onPath(g, Point(w / 2, h), 1e-6) && onPath(g, Point(w / 2, h / 4), 1e-6))
        g = try build("flowChartDocument", w, h)
        #expect(onPath(g, at(21600, 17322), 1e-6) && onPath(g, at(0, 20172), 1e-6))
        // Punched tape: the top edge dips to a fifth of the height a quarter of the way along.
        g = try build("flowChartPunchedTape", w, h)
        #expect(onPath(g, Point(w / 4, h / 5), 1e-3) && onPath(g, Point(w * 0.75, 0), 1e-3))
        g = try build("flowChartMultidocument", w, h)
        #expect(onPath(g, at(2972, 0), 1e-6) && onPath(g, at(18595, 18022), 1e-6))
    }

    @Test func notchedArrowNotchParallelsTheHead() throws {
        // presetShapeDefinitions: the notch's point is at x1 = dy1 · dx2 / hd2, so its edges run parallel
        // to the head's (25 on a 200 × 100 arrow at the default adjusts).
        for (w, h, adj, x1) in [(200.0, 100.0, [50000.0, 50000], 25.0), (300, 120, [80000, 30000], 28.8)] {
            let g = try build("notchedRightArrow", w, h, adj)
            let notch = vertices(g.paths[0].path).first { abs($0.y - h / 2) < 1e-9 && $0.x < w / 2 }
            #expect(notch.map { abs($0.x - x1) < 1e-6 } == true, "\(w)x\(h) \(adj): notch at \(String(describing: notch)), want x = \(x1)")
        }
    }

    @Test func equationShapesMatchPowerpointsOutlines() throws {
        // Corners read off PowerPoint's own outlines of the presets at their default adjusts.
        var g = try build("mathMultiply", 216, 216)
        for (x, y) in [(0.32333, 0.15702), (0.5, 0.33369), (0.84298, 0.32333), (0.66631, 0.5), (0.33369, 0.5)] {
            #expect(onPath(g, Point(216 * x, 216 * y), 0.01), "multiply (\(x), \(y))")
        }
        g = try build("mathEqual", 300, 120)
        for (x, y) in [(0.13255, 0.5588), (0.86745, 0.794), (0.13255, 0.206), (0.86745, 0.4412)] {
            #expect(onPath(g, Point(300 * x, 120 * y), 0.01), "equal (\(x), \(y))")
        }
        g = try build("mathPlus", 216, 216)
        #expect(onPath(g, Point(216 * 0.3824, 216 * 0.13255), 0.01) && onPath(g, Point(216 * 0.86745, 216 * 0.6176), 0.01))
        // A tall "not equal": its slash, leaning at the default 110° from top to bottom, reaches past the
        // box's sides exactly as far as PowerPoint's (-22.242 to 122.242).
        g = try build("mathNotEqual", 100, 260)
        let bb = g.paths[0].path.boundingBox
        #expect(abs(bb.x0 + 22.242) < 0.01 && abs(bb.x1 - 122.242) < 0.01 && abs(bb.y0) < 1e-6 && abs(bb.y1 - 260) < 1e-6, "\(bb)")
    }

    @Test func sunAndWavesMatchPowerpointsOutlines() throws {
        // Points read off PowerPoint's outlines of the presets (216 pt square, default adjusts).
        let k = 216.0
        var g = try build("sun", k, k)
        for (x, y) in [(0.85352, 0.14644), (0.76161, 0.33987), (0.66013, 0.23839), (0.42825, 0.79823), (0.20177, 0.57175), (0.75, 0.5), (0.5, 0.25)] {
            #expect(onPath(g, Point(k * x, k * y), 0.02), "sun (\(x), \(y))")
        }
        g = try build("wave", k, k)
        for (x, y) in [(0.21875, 0.00484), (1.0, 0.125), (1.0, 0.875), (0.0, 0.875)] {
            #expect(onPath(g, Point(k * x, k * y), 0.05), "wave (\(x), \(y))")
        }
        // Shifted: a wave of 300 × 120 with adj (20000, 8000) starts 0.16 of the width in.
        g = try build("wave", 300, 120, [20000, 8000])
        for (x, y) in [(0.18375, 0.00774), (0.84, 0.2), (1.0, 0.8), (0.16, 0.8)] {
            #expect(onPath(g, Point(300 * x, 120 * y), 0.05), "shifted wave (\(x), \(y))")
        }
    }

    @Test func starTextRectanglesFollowTheStandard() throws {
        // star5 at its default 19098 in a 144 pt square: the inner pentagon, about 0.38 of the width,
        // from y ≈ 55 to ≈ 110.
        let t = try build("star5", 144, 144).textRect
        #expect(abs(t.width - 55) < 1, "\(t)")
        #expect(abs(t.y0 - 55) < 1 && abs(t.y1 - 110) < 1, "\(t)")
        // star4 at 12500: the square through its inner points' 45° corners.
        let t4 = try build("star4", 144, 144).textRect
        #expect(abs(t4.width - 72 * 0.25 * 2.0.squareRoot()) < 0.5, "\(t4)")
    }

    @Test func starsAreStretchedLikeTheStandards() throws {
        // star5 in a 216 pt square: top point at the top middle, side points at 18 degrees on an ellipse
        // 5.146% wider and 10.557% taller, centred 10.557% below the middle; its bottom points reach the
        // box's bottom edge.
        let k = 216.0
        let g = try build("star5", k, k)
        let (rx, ry, cy) = (k / 2 * 1.05146, k / 2 * 1.10557, k / 2 * 1.10557)
        let a = 18.0.radians
        #expect(onPath(g, Point(k / 2, 0), 1e-6))
        #expect(onPath(g, Point(k / 2 + rx * cos(a), cy - ry * sin(a)), 1e-6))
        let bb = g.paths[0].path.boundingBox
        #expect(abs(bb.x0) < 0.5 && abs(bb.x1 - k) < 0.5 && abs(bb.y1 - k) < 0.5, "\(bb)")
        // star6 is 15.47% wider than its box's half-width allows (its points touch the sides).
        let b6 = try build("star6", k, k).paths[0].path.boundingBox
        #expect(abs(b6.x0) < 0.5 && abs(b6.x1 - k) < 0.5, "\(b6)")
    }

    @Test func moonDiskAndDrumMatchPowerpointsOutlines() throws {
        let k = 216.0
        // Moon, default: the inner edge runs through (0.5, 0.5) and (0.625, 0.2266) of the box.
        var g = try build("moon", k, k)
        for (x, y) in [(0.5, 0.5), (0.626, 0.2266), (0.0, 0.5), (1.0, 0.0)] {
            #expect(onPath(g, Point(k * x, k * y), 0.5), "moon (\(x), \(y))")
        }
        // 300 × 120 at 30%: its inner edge reaches 30% of the width in.
        g = try build("moon", 300, 120, [30000])
        #expect(onPath(g, Point(90, 60), 0.5))
        // Magnetic disk ends are ellipses h/6 high, drum ends w/6 across.
        g = try build("flowChartMagneticDisk", k, k)
        #expect(onPath(g, Point(k, k / 6), 0.01) && onPath(g, Point(k / 2, k / 3), 0.5))
        g = try build("flowChartMagneticDrum", k, k)
        #expect(onPath(g, Point(k / 6, 0), 0.01) && onPath(g, Point(0, k / 2), 0.01))
    }

    @Test func theCloudFillsItsBoxAtAnyAspectAndHasCreases() throws {
        for (w, h) in [(200.0, 200.0), (300, 100), (60, 180)] {
            let g = try build("cloud", w, h)
            let bb = g.paths[0].path.boundingBox
            #expect(abs(bb.x0) < w * 0.02 && abs(bb.x1 - w) < w * 0.02, "\(w)×\(h): \(bb)")
            #expect(abs(bb.y0) < h * 0.02 && abs(bb.y1 - h) < h * 0.02, "\(w)×\(h): \(bb)")
            #expect(g.paths.count == 2, "outline and creases")
            #expect(g.paths[1].stroke && g.paths[1].fill == .none)
        }
    }

    @Test func specArcsTakeAnglesAsDirectionsFromTheCentre() throws {
        // A DrawingML arc of a 2:1 ellipse from 45° to 90°: 45° is the direction (1, 1) from the centre.
        let b = Pb()
        b.m(0, 0).arcSpec(200, 100, 45, 45)
        let p = b.take()
        guard case .curveTo(_, _, let q)? = p.elements.last else {
            Issue.record("no curve")
            return
        }
        // Centre: the start sits at direction 45°, i.e. at (k, k) from it with (k/200)² + (k/100)² = 1.
        let k = 1.0 / (1.0 / 40000.0 + 1.0 / 10000.0).squareRoot()
        let c = Point(-k, -k)
        #expect(abs(q.x - c.x) < 1e-6 && abs(q.y - (c.y + 100)) < 1e-6, "\(q) vs centre \(c)")
    }

    @Test func bracketsAndBracesFillOutToTheirStraightSide() throws {
        // PowerPoint fills a bracket or brace (when it has a fill) between its curve and the straight side
        // it opens to; only the curve is outlined.
        for name in ["leftBracket", "rightBracket", "leftBrace", "rightBrace"] {
            let g = try build(name, 40, 100)
            let filled = g.paths.filter { $0.fill != .none }
            #expect(filled.count == 1, "\(name)")
            #expect(filled.first.map { !$0.stroke } == true, "\(name): the filled area is not outlined")
            let area = abs(filled.first?.path.area ?? 0)
            #expect(area > 40 * 100 * 0.4 && area < 40 * 100, "\(name): \(area)")
            #expect(g.paths.contains { $0.stroke && $0.fill == .none }, "\(name): the curve is outlined")
        }
    }

    @Test func wedgeCalloutMirrorsWithItsTip() throws {
        // A tip below and right of the centre draws the mirror image of the same tip on the left; the
        // same for a tip right of the centre, above or below it.
        let (w, h) = (240.0, 120.0)
        func sorted(_ v: [Point]) -> [Point] {
            var out: [Point] = []
            for p in v.sorted(by: { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }) where !(out.last.map { ($0 - p).hypot < 1e-9 } ?? false) {
                out.append(p)
            }
            return out
        }
        for (right, left, flipX) in [([10000.0, 80000], [-10000.0, 80000], true), ([80000, 10000], [80000, -10000], false)] {
            let a = sorted(vertices(try build("wedgeRectCallout", w, h, right).paths[0].path))
            let b = sorted(vertices(try build("wedgeRectCallout", w, h, left).paths[0].path).map { flipX ? Point(w - $0.x, $0.y) : Point($0.x, h - $0.y) })
            #expect(a.count == b.count, "\(right): \(a) vs mirrored \(left): \(b)")
            for (p, q) in zip(a, b) {
                #expect((p - q).hypot < 1e-6, "\(right): \(a)\n is not the mirror of \(left): \(b)")
            }
        }
        // The bottom wedge of a tip right of the centre leaves the edge at 7/12 and 10/12 of the width.
        let a = vertices(try build("wedgeRectCallout", w, h, [10000, 80000]).paths[0].path)
        for x in [w * 7 / 12, w * 10 / 12] {
            #expect(a.contains { abs($0.x - x) < 1e-6 && abs($0.y - h) < 1e-6 }, "no wedge corner at (\(x), \(h)): \(a)")
        }
    }
}

// MARK: - preset/extra.rs

private let newPresets = [
    "lineInv", "nonIsoscelesTrapezoid", "pieWedge", "leftRightArrowCallout", "upDownArrowCallout", "quadArrowCallout",
    "circularArrow", "leftCircularArrow", "leftRightCircularArrow", "curvedRightArrow", "curvedLeftArrow", "curvedUpArrow",
    "curvedDownArrow", "swooshArrow", "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2", "accentCallout3",
    "borderCallout2", "borderCallout3", "accentBorderCallout1", "accentBorderCallout2", "accentBorderCallout3", "ellipseRibbon",
    "ellipseRibbon2", "leftRightRibbon", "flowChartOfflineStorage", "gear6", "gear9", "funnel", "cornerTabs", "squareTabs",
    "plaqueTabs", "chartX", "chartStar", "chartPlus",
]

private func outline(_ name: String, _ w: Double, _ h: Double, _ adj: [Double]) -> BezPath {
    Preset.build(name, w, h, adj)?.outline ?? BezPath()
}

/// Distance from `p` to the nearest point of the (flattened) outline.
private func dist(_ path: BezPath, _ p: Point) -> Double {
    var best = Double.greatestFiniteMagnitude
    var prev = Point.zero
    var start = Point.zero
    flatten(path.elements, 0.01) { el in
        let a: Point, b: Point
        switch el {
        case .moveTo(let q):
            prev = q
            start = q
            return
        case .lineTo(let q): (a, b) = (prev, q)
        case .closePath: (a, b) = (prev, start)
        default: return
        }
        let d = b - a
        let t = d.hypot2 > 0 ? ((p - a).dot(d) / d.hypot2).clamp(0, 1) : 0
        best = min(best, (a + d * t - p).hypot)
        prev = b
    }
    return best
}

/// Expects every point within 1pt of the outline.
private func on(_ name: String, _ w: Double, _ h: Double, _ adj: [Double], _ pts: [(Double, Double)], sourceLocation: SourceLocation = #_sourceLocation) {
    let path = outline(name, w, h, adj)
    for (x, y) in pts {
        let d = dist(path, Point(x, y))
        #expect(d < 1, "\(name) \(w)x\(h) \(adj): (\(x), \(y)) is \(d) from the outline", sourceLocation: sourceLocation)
    }
}

@Suite struct PresetExtraTests {
    @Test func newPresetsAreInTheCatalog() {
        for n in newPresets {
            #expect(Preset.info(n).map { !$0.label.isEmpty } == true, "\(n) missing from the catalog")
        }
        #expect(Preset.catalog.count >= 183)
    }

    @Test func newPresetsBuildWithinBoundsAtManySizesAndAdjusts() throws {
        let sizes = [(480.0, 300.0), (300, 300), (200, 460), (100, 460), (1, 1), (0, 0), (0, 50), (60, 0)]
        let adjusts: [[Double]] = [
            [], Array(repeating: 0, count: 8), Array(repeating: 100_000, count: 8), Array(repeating: -50000, count: 8),
            [1e12, -1e12, 1e12, -1e12, 1e12, -1e12, 1e12, -1e12],
            [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
             .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude],
            [.nan, .infinity, -.infinity, .nan, 5, 6, 7, 8],
            [30000, 60000, 20000, 9_000_000, 20000, 40000, 120_000, -30000],
        ]
        for n in newPresets {
            // Line callouts' leaders may reach anywhere, by design.
            let callout = n.contains("allout") && !n.contains("Arrow")
            for (w, h) in sizes {
                for adj in adjusts {
                    let g = try build(n, w, h, adj)
                    #expect(!g.paths.isEmpty, "\(n) has no paths")
                    for s in g.paths {
                        let bb = s.path.boundingBox
                        #expect(bb.isFinite, "\(n) \(w)x\(h) \(adj): \(bb)")
                        if !callout {
                            // Circular arrows with a head longer than their ring can hold carry the inner
                            // edge on from the head, as the reference does, so may spill.
                            let spill = n.contains("ircular") ? 0.5 : 0.01
                            let tol = 0.5 + max(w, h) * spill
                            #expect(bb.x0 >= -tol && bb.y0 >= -tol && bb.x1 <= w + tol && bb.y1 <= h + tol, "\(n) \(w)x\(h) \(adj) out of bounds: \(bb)")
                        }
                    }
                    #expect(g.textRect.isFinite, "\(n) text rect \(g.textRect)")
                }
            }
            #expect(try build(n, 480, 300).outline.elements.count >= 2, "\(n) default outline is empty")
        }
    }

    // The spot checks below are outline points measured on reference renders.

    @Test func simpleNewPresetsMatchReferencePoints() throws {
        on("lineInv", 480, 300, [], [(0, 300), (480, 0)])
        on("nonIsoscelesTrapezoid", 480, 300, [], [(75, 0), (405, 0), (0, 300)])
        on("nonIsoscelesTrapezoid", 200, 460, [80000, 20000], [(100, 0), (160, 0)])
        on("pieWedge", 480, 300, [], [(64.3, 150), (0, 300), (480, 0)])
        on("flowChartOfflineStorage", 480, 300, [], [(240, 300), (192, 240), (288, 240)])
        on("squareTabs", 480, 300, [], [(28.3, 28.3), (451.7, 271.7)])
        on("cornerTabs", 480, 300, [], [(23.3, 5)])
        on("plaqueTabs", 480, 300, [], [(27.85, 5)])
        on("chartStar", 480, 300, [], [(240, 0), (240, 300), (48, 30)])
        on("chartPlus", 480, 300, [], [(0, 150), (240, 0)])
        // Chart markers and plain callouts leave the box unstroked.
        for n in ["chartX", "callout1", "accentCallout2"] {
            #expect(try !build(n, 100, 100).paths[0].stroke, "\(n)")
        }
    }

    @Test func lineCalloutsFollowTheirAdjusts() throws {
        on("callout3", 480, 300, [], [(-40, 56.25), (-80, 56.25), (-80, 300), (-40, 338.9)])
        let adj: [Double] = [50000, 110_000, 20000, 120_000, -20000, 80000, 30000, 40000]
        let g = try build("accentBorderCallout3", 480, 300, adj)
        #expect(g.paths.count == 3)
        #expect(g.paths[0].stroke)
        let accent = g.paths[1].path.boundingBox
        #expect(abs(accent.x0 - 528) < 1e-6 && accent.y0 == 0 && accent.y1 == 300, "\(accent)")
        on("accentBorderCallout3", 480, 300, adj, [(576, 60), (384, -60), (192, 90)])
    }

    @Test func arrowCalloutsMatchReferencePoints() {
        on("leftRightArrowCallout", 480, 300, [], [(0, 150), (75, 75), (124.5, 0), (355.5, 300), (480, 150)])
        on("leftRightArrowCallout", 200, 460, [], [(50, 180), (52, 0), (148, 460)])
        on("upDownArrowCallout", 480, 300, [], [(240, 0), (0, 77.8), (480, 222.2), (240, 300)])
        on("quadArrowCallout", 480, 300, [], [(0, 150), (124.5, 77.8), (240, 0), (480, 150), (240, 300)])
    }

    @Test func curvedArrowsMatchReferencePoints() throws {
        on("curvedRightArrow", 480, 300, [], [(480, 0), (480, 75), (480, 225), (405, 149), (405, 299), (100, 151.5), (300, 6.7)])
        on("curvedRightArrow", 200, 460, [30000, 60000, 40000], [(200, 400), (120, 324.5), (120, 443.5), (200, 60)])
        // The band never outgrows the head; the head never outgrows half the frame.
        on("curvedRightArrow", 200, 460, [60000, 30000, 80000], [(200, 60)])
        on("curvedLeftArrow", 480, 300, [], [(0, 225), (0, 0)])
        on("curvedUpArrow", 480, 300, [], [(405, 0), (0, 0), (75, 0)])
        on("curvedDownArrow", 480, 300, [], [(405, 300), (0, 300)])
        #expect(try build("curvedRightArrow", 480, 300).paths[0].fill == .darkenLess)
    }

    @Test func swooshMatchesReferencePoints() {
        on("swooshArrow", 480, 300, [], [(0, 300), (425.8, 0), (480, 59.7), (442.8, 150), (202, 105.5), (202, 159)])
        on("swooshArrow", 480, 300, [40000, 16667], [(480, 82.2), (447.8, 195)])
        on("swooshArrow", 200, 460, [], [(163.9, 0), (200, 59.4)])
    }

    @Test func ribbonsMatchReferencePoints() {
        on("ellipseRibbon", 480, 300, [], [(0, 0), (120, 28.1), (60, 128.9), (240, 300), (120, 66.1), (180, 72.2), (180, 35.2)])
        on("ellipseRibbon", 480, 300, [30000, 60000, 20000], [(120, 45), (240, 300), (96, 68.4)])
        on("ellipseRibbon", 480, 300, [80000, 20000, 60000], [(240, 240), (1, 61.75)])
        on("ellipseRibbon2", 480, 300, [], [(0, 300), (240, 0)])
        on("leftRightRibbon", 480, 300, [], [(0, 125), (150, 0), (150, 50), (255, 62.5), (225, 87.5), (480, 175), (330, 300)])
        on("leftRightRibbon", 480, 300, [90000, 10000, 60000], [(0, 100), (480, 200), (240, 300)])
    }

    @Test func gearsAndFunnelMatchReferencePoints() throws {
        // Square gear6: body radius 105, top tooth tip 3.5 inside the frame, tip half-width ~16.3.
        on("gear6", 300, 300, [], [(150, 3.5), (133.7, 3.5), (166.3, 3.5), (45, 150)])
        on("gear9", 300, 300, [], [(150, 1), (30, 150)])
        on("gear6", 480, 300, [], [(240, 3.5), (201, 3.5)])
        on("funnel", 480, 300, [], [(240, 0), (0, 75), (240, 15), (15, 75), (240, 300), (60.5, 150)])
        #expect(try build("funnel", 480, 300).paths[0].evenOdd)
    }

    @Test func circularArrowsMatchReferencePoints() {
        on("circularArrow", 300, 300, [], [(19, 150), (56.5, 150), (150, 19), (262.4, 150), (218.6, 113.4), (293.6, 113.4)])
        on("circularArrow", 300, 300, [20000, 1_800_000, 18_000_000, 5_400_000, 20000], [(150, 270), (150, 210), (247, 42.1), (143, 102.1), (227.9, 105)])
        on("leftCircularArrow", 300, 300, [], [(37.6, 150), (262.4, 150), (150, 281)])
        on("leftRightCircularArrow", 300, 300, [], [(262.4, 150), (37.6, 150), (150, 19)])
        // The band never grows past twice the head's half-width.
        on("circularArrow", 300, 300, [25000, 1_142_319, 20_457_681, 10_800_000, 5000], [(0, 150), (30, 150)])
    }
}
