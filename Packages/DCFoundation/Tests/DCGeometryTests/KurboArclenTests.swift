// Ported from kurbo 0.13.1's tests (common.rs, line.rs, quadbez.rs, cubicbez.rs, affine.rs, offset.rs;
// MIT OR Apache-2.0, © the kurbo authors).
import Darwin
@testable import DCGeometry
import Testing

private func near(_ a: Point, _ b: Point, _ eps: Double = 1e-9) -> Bool { (a - b).hypot < eps }

private func verifyRoots(_ roots: [Double], _ expected: [Double]) -> Bool {
    guard roots.count == expected.count else { return false }
    return zip(roots.sorted(), expected).allSatisfy { Swift.abs($0 - $1) < 1e-12 }
}

@Suite struct KurboArclenTests {
    @Test func solveCubicRoots() {
        #expect(verifyRoots(solveCubic(-5.0, 0.0, 0.0, 1.0), [Darwin.cbrt(5.0)]))
        #expect(verifyRoots(solveCubic(-5.0, -1.0, 0.0, 1.0), [1.90416085913492]))
        #expect(verifyRoots(solveCubic(0.0, -1.0, 0.0, 1.0), [-1.0, 0.0, 1.0]))
        #expect(verifyRoots(solveCubic(-2.0, -3.0, 0.0, 1.0), [-1.0, 2.0]))
        #expect(verifyRoots(solveCubic(2.0, -3.0, 0.0, 1.0), [-2.0, 1.0]))
        #expect(verifyRoots(solveCubic(2.0 - 1e-12, 5.0, 4.0, 1.0),
                            [-1.9999999999989995, -1.0000010000848456, -0.9999989999161546]))
        #expect(verifyRoots(solveCubic(2.0 + 1e-12, 5.0, 4.0, 1.0), [-2.0]))
    }

    @Test func solveITPRoot() {
        let f = { (x: Double) in x * x * x - x - 2.0 }
        let x = solveITP(f, 1, 2, 1e-12, 0, 0.2, f(1), f(2))
        #expect(Swift.abs(f(x)) < 6e-12)
    }

    @Test func itpOnArclen() {
        let c = CubicBez(Point(0, 0), Point(100.0 / 3.0, 0), Point(200.0 / 3.0, 100.0 / 3.0), Point(100, 100))
        let target = 100.0
        let t = solveITP({ c.subsegment(0, $0).arclen(1e-9) - target }, 0, 1, 1e-6, 1, 0.2, -target, c.arclen(1e-9) - target)
        #expect(Swift.abs(c.subsegment(0, t).arclen(1e-9) - target) < 1e-3)
    }

    @Test func lineArclen() {
        let l = LineSeg(Point(0, 0), Point(1, 1))
        let trueLen = Double(2).squareRoot()
        #expect(l.arclen(1e-9) - trueLen < 1e-9)
        #expect(Swift.abs(l.invArclen(trueLen / 3.0, 1e-9) - 1.0 / 3.0) < 1e-9)
    }

    @Test func quadArclen() {
        let q = QuadBez(Point(0, 0), Point(0, 0.5), Point(1, 1))
        let trueArclen = 0.5 * Double(5).squareRoot() + 0.25 * Darwin.log(2.0 + Double(5).squareRoot())
        for i in 0 ..< 12 {
            let accuracy = Darwin.pow(0.1, Double(i))
            #expect(Swift.abs(q.arclen(accuracy) - trueArclen) < accuracy)
        }
    }

    @Test func quadArclenPathological() {
        let q = QuadBez(Point(-1, 0), Point(1.03, 0), Point(1, 0))
        #expect(Swift.abs(q.arclen(1e-11) - 2.0008737864167325) < 1e-11)
    }

    @Test func quadSubsegmentAndRaise() {
        let q = QuadBez(Point(3.1, 4.1), Point(5.9, 2.6), Point(5.3, 5.8))
        let (t0, t1) = (0.1, 0.8)
        let qs = q.subsegment(t0, t1)
        let c = q.raise()
        for i in 0 ... 10 {
            let t = Double(i) * (1.0 / 10.0)
            #expect(near(q.eval(t0 + t * (t1 - t0)), qs.eval(t), 1e-12))
            #expect(near(q.eval(t), c.eval(t), 1e-12))
        }
    }

    @Test func quadNearest() {
        let q = QuadBez(Point(-1, 1), Point(0, -1), Point(1, 1))
        for (p, t) in [(Point(0, 0), 0.5), (Point(0, 0.1), 0.5), (Point(0, -0.1), 0.5), (Point(0.5, 0.25), 0.75),
                       (Point(1, 1), 1.0), (Point(1.1, 1.1), 1.0), (Point(-1.1, 1.1), 0.0)] {
            #expect(Swift.abs(q.nearest(p).t - t) < 1e-6)
        }
        let low = QuadBez(Point(-1, 0), Point(0, 0), Point(1, 0))
        #expect(Swift.abs(low.nearest(Point(0, 0)).t - 0.5) < 1e-6)
        #expect(Swift.abs(low.nearest(Point(0, 1)).t - 0.5) < 1e-6)
        // Must not trap on huge inputs.
        _ = QuadBez(Point(-1.0394736842105263, 0), Point(0.8210526315789474, -1.511111111111111), Point(0, 1.9333333333333333))
            .nearest(Point(-1.7976931348623157e308, 0.8571428571428571))
    }

    @Test func cubicArclen() {
        let c = CubicBez(Point(0, 0), Point(1.0 / 3.0, 0), Point(2.0 / 3.0, 1.0 / 3.0), Point(1, 1))
        let trueArclen = 0.5 * Double(5).squareRoot() + 0.25 * Darwin.log(2.0 + Double(5).squareRoot())
        for i in 0 ..< 12 {
            let accuracy = Darwin.pow(0.1, Double(i))
            #expect(Swift.abs(c.arclen(accuracy) - trueArclen) < accuracy)
        }
    }

    @Test func cubicInvArclen() {
        let c = CubicBez(Point(0, 0), Point(100.0 / 3.0, 0), Point(200.0 / 3.0, 100.0 / 3.0), Point(100, 100))
        let trueArclen = 100.0 * (0.5 * Double(5).squareRoot() + 0.25 * Darwin.log(2.0 + Double(5).squareRoot()))
        for i in 0 ..< 12 {
            let accuracy = Darwin.pow(0.1, Double(i))
            for j in 0 ... 10 {
                let arc = Double(j) * ((1.0 / 10.0) * trueArclen)
                let t = c.invArclen(arc, accuracy * 0.5)
                let actual = c.subsegment(0, t).arclen(accuracy * 0.5)
                #expect(Swift.abs(arc - actual) < accuracy, "accuracy \(accuracy) arc \(arc) got \(actual)")
            }
        }
        let accuracy = trueArclen * 1.1
        let arc = trueArclen * 0.5
        let t = c.invArclen(arc, accuracy)
        #expect(Swift.abs(arc - c.subsegment(0, t).arclen(accuracy)) < 2.0 * accuracy)
    }

    @Test func cubicInvArclenAccuracy() {
        let c = CubicBez(Point(0.2, 0.73), Point(0.35, 1.08), Point(0.85, 1.08), Point(1.0, 0.73))
        let trueT = c.invArclen(0.5, 1e-12)
        for i in 1 ..< 12 {
            let accuracy = Darwin.pow(0.1, Double(i))
            #expect(Swift.abs(c.invArclen(0.5, accuracy) - trueT) <= accuracy)
        }
    }

    @Test func cubicSubdivide() {
        let c = CubicBez(Point(3.1, 4.1), Point(5.9, 2.6), Point(5.3, 5.8), Point(8, 1))
        let (a, b) = c.subdivide()
        for i in 0 ... 10 {
            let t = Double(i) / 10.0
            #expect(near(a.eval(t), c.eval(0.5 * t), 1e-12))
            #expect(near(b.eval(t), c.eval(0.5 + 0.5 * t), 1e-12))
        }
    }

    @Test func cubicInflections() {
        let a = CubicBez(Point(0, 0), Point(0.8, 1), Point(0.2, 1), Point(1, 0)).inflections
        #expect(a.count == 2)
        #expect(Swift.abs((a.first ?? 0) - 0.311018) < 1e-6)
        #expect(Swift.abs((a.last ?? 0) - 0.688982) < 1e-6)
        let b = CubicBez(Point(0, 0), Point(1, 1), Point(2, -1), Point(3, 0)).inflections
        #expect(b.count == 1)
        #expect(Swift.abs((b.first ?? 0) - 0.5) < 1e-6)
        #expect(CubicBez(Point(0, 0), Point(1, 1), Point(2, 1), Point(3, 0)).inflections.isEmpty)
    }

    @Test func svd() {
        let (scale, rotation) = Affine(1, 2, 3, 4, 5, 6).svd
        let (scale0, rotation0) = Affine(1, 2, 3, 4, 0, 0).svd
        #expect(near(scale.toPoint, scale0.toPoint))
        #expect(Swift.abs(rotation - rotation0) <= 1e-9)
        #expect(near(scale.toPoint, Point(5.4649857042190427, 0.36596619062625782)))
        #expect(Swift.abs(rotation - 0.95691013360780001) <= 1e-9)
        let singular = Affine(0, 0, 0, 0, 5, 6).svd
        #expect(singular.scale == Vec2(0, 0))
        #expect(singular.angle == 0)
        for (m, s) in [(Affine(1, 0, 0, 1, 0, 0), Point(1, 1)), (Affine(1, 0, 0, -1, 0, 0), Point(1, 1)),
                       (Affine(1, 1, 1, 1, 0, 0), Point(2, 0)), (Affine(0, 0, 1, 0, 0, 0), Point(1, 0)),
                       (Affine.scaleNonUniform(-20, 3), Point(20, 3)), (Affine.scaleNonUniform(-20, -3), Point(20, 3))] {
            #expect(near(m.svd.scale.toPoint, s))
        }
    }

    @Test func ellipsePathIsAClosedTurnNotClosed() {
        let e = Ellipse(center: Point(10, 20), radii: Vec2(30, 15), xRotation: 0)
        let p = e.path(0.1)
        #expect(p.elements.first == .moveTo(Point(40, 20)))
        #expect(!p.elements.contains(.closePath))
        if case .curveTo(_, _, let end) = p.elements.last {
            #expect(near(end, Point(40, 20), 1e-9))
        } else {
            Issue.record("last element is not a curve")
        }
    }

    @Test func offsetPathologicalCurves() {
        let curve = CubicBez(Point(-1236.3746269978635, 152.17981429574826), Point(-1175.18662093517, 108.04721798590596),
                             Point(-1152.142883879584, 105.76260301083356), Point(-1151.842639804639, 105.73040758939104))
        let r = offsetCubic(curve, 3603.7267536453924, 0.1)
        if case .moveTo = r.elements.first {} else { Issue.record("no moveTo") }
    }

    @Test func offsetInfiniteRecursionAndLine() {
        let c = CubicBez(Point(1096.2962962962963, 593.90243902439033), Point(1043.6213991769548, 593.90243902439033),
                         Point(1030.4526748971193, 593.90243902439033), Point(1056.7901234567901, 593.90243902439033))
        _ = offsetCubic(c, -0.5, 0.1)
        let line = offsetCubic(CubicBez(Point(0, 0), Point(10, 0), Point(20, 0), Point(30, 0)), 5, 1e-6)
        #expect(line.elements.first == .moveTo(Point(0, 5)))
        if case .curveTo(_, _, let end) = line.elements.last {
            #expect(near(end, Point(30, 5), 1e-9))
        } else {
            Issue.record("last element is not a curve")
        }
    }

    @Test func offsetOfAnArcStaysAtDistance() {
        // Not in kurbo: the offset of a quarter circle lies on the larger circle within tolerance.
        let k = 0.5522847498
        let c = CubicBez(Point(100, 0), Point(100, 100 * k), Point(100 * k, 100), Point(0, 100))
        let r = offsetCubic(c, -10, 0.01)
        for el in r.elements {
            if case .curveTo(_, _, let p) = el { #expect(Swift.abs(p.toVec2.hypot - 110) < 0.1) }
        }
    }
}
