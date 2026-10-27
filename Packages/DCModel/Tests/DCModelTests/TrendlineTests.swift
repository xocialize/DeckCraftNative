// Ported from deckcraft crates/model/src/trendline.rs tests (MIT OR Apache-2.0).
import DCModel
import Foundation
import Testing

private func line(_ kind: TrendlineType) -> Trendline {
    var t = Trendline.default
    t.kind = kind
    return t
}

@Suite struct TrendlineTests {
    @Test func linearFitsTinyXValues() throws {
        let xs = [1e-10, 2e-10, 3e-10, 4e-10, 5e-10]
        let ys = [1.0, 2.0, 3.0, 4.0, 5.0]
        let fit = try #require(line(.linear).fit(xs, ys))
        #expect(abs(try #require(fit.y(3e-10)) - 3.0) < 1e-6)
    }

    @Test func linearFitsOffsetButNarrowXRange() throws {
        let ys = [1.0, 2.0, 3.0, 4.0, 5.0]
        let fit = try #require(line(.linear).fit([45000.00, 45000.01, 45000.02, 45000.03, 45000.04], ys))
        #expect(abs(try #require(fit.y(45000.02)) - 3.0) < 1e-4)
        let xs = [1e7, 1e7 + 1.0, 1e7 + 2.0, 1e7 + 3.0, 1e7 + 4.0]
        let fit2 = try #require(line(.linear).fit(xs, ys))
        #expect(abs(try #require(fit2.y(1e7 + 2.0)) - 3.0) < 1e-4)
    }

    @Test func linearFixedInterceptOnOffsetNarrowXRange() throws {
        let xs = [1e7, 1e7 + 1.0, 1e7 + 2.0, 1e7 + 3.0, 1e7 + 4.0]
        let ys = xs.map { 2.0 * $0 }
        var forced = line(.linear)
        forced.intercept = 0.0
        let fit = try #require(forced.fit(xs, ys))
        let y: Double = try #require(fit.y(1e7 + 2.0))
        let want: Double = 2.0 * (1e7 + 2.0)
        #expect(abs(y / want - 1.0) < 1e-9)
    }

    @Test func linearFixedInterceptRejectsOverflowingX() {
        var forced = line(.linear)
        forced.intercept = 0.0
        #expect(forced.fit([1e160, 2e160, 3e160], [1.0, 2.0, 3.0]) == nil)
    }

    @Test func linearRejectsConstantXWithLargeOffset() {
        #expect(line(.linear).fit(Array(repeating: 45000.1, count: 5), [1.0, 2.0, 3.0, 4.0, 5.0]) == nil)
    }

    @Test func linearRecoversSlopeAndAFixedIntercept() throws {
        let fit = try #require(line(.linear).fit([1.0, 2.0, 3.0, 4.0], [3.0, 5.0, 7.0, 9.0]))
        #expect(abs(try #require(fit.y(1.0)) - 3.0) < 1e-9)
        #expect(abs(try #require(fit.y(4.0)) - 9.0) < 1e-9)
        #expect(fit.equation() == "y = 2x + 1")
        #expect(fit.r2Label() == "R² = 1")
        var forced = line(.linear)
        forced.intercept = 0.0
        let fit2 = try #require(forced.fit([1.0, 2.0], [2.0, 4.0]))
        #expect(abs(try #require(fit2.y(3.0)) - 6.0) < 1e-6)
        #expect(fit2.equation() == "y = 2x")
    }

    @Test func expLogPowerAndQuadraticRoundTheirPoints() throws {
        let xs = [1.0, 2.0, 3.0, 4.0]
        let exp = try #require(line(.exp).fit(xs, [1.0, 2.0, 4.0, 8.0]))
        for (x, y) in zip(xs, [1.0, 2.0, 4.0, 8.0]) {
            #expect(abs(try #require(exp.y(x)) - y) < 1e-6, "\(x)")
        }
        #expect(try #require(exp.equation()).contains("e^("))
        let log = try #require(line(.log).fit(xs, [Foundation.log(1.0), Foundation.log(2.0), Foundation.log(3.0), Foundation.log(4.0)]))
        #expect(abs(try #require(log.y(2.0)) - Foundation.log(2.0)) < 1e-6)
        #expect(try #require(log.equation()).contains("ln(x)"))
        let power = try #require(line(.power).fit(xs, [1.0, 4.0, 9.0, 16.0]))
        #expect(abs(try #require(power.y(3.0)) - 9.0) < 1e-6)
        #expect(power.equation() == "y = x²")
        var poly = line(.poly)
        poly.order = 2
        let quad = try #require(poly.fit(xs, [1.0, 4.0, 9.0, 16.0]))
        #expect(abs(try #require(quad.y(3.0)) - 9.0) < 1e-6)
        #expect(quad.equation() == "y = x²")
    }

    @Test func movingAverageAndForecastSpan() throws {
        var ma = Trendline.default
        ma.kind = .movingAvg
        ma.period = 2
        let fit = try #require(ma.fit([1.0, 2.0, 3.0, 4.0], [2.0, 8.0, 4.0, 10.0]))
        let pts = fit.samples(0.0, 10.0)
        #expect(pts.count == 3)
        #expect(abs(pts[0].y - 5.0) < 1e-9)
        #expect(abs(pts[1].y - 6.0) < 1e-9)
        #expect(abs(pts[2].y - 7.0) < 1e-9)
        #expect(fit.equation() == nil)
        let linear = try #require(line(.linear).fit([1.0, 2.0], [1.0, 2.0]))
        #expect(linear.span(1.5, -3.0) == (1.0, 3.5))
        #expect(fit.span(4.0, 4.0) == (2.0, 4.0))
    }

    @Test func movingAverageShowsNeitherEquationNorR2() throws {
        var t = Trendline.default
        t.kind = .movingAvg
        t.period = 2
        t.dispEq = true
        t.dispRSqr = true
        let fit = try #require(t.fit([1.0, 2.0, 3.0, 4.0], [2.0, 8.0, 4.0, 10.0]))
        #expect(fit.r2Label().hasPrefix("R² ="))
        #expect(t.caption(fit).isEmpty, "\(t.caption(fit))")
    }

    @Test func tooFewPointsAndNonFiniteInputFitNothing() throws {
        #expect(line(.linear).fit([1.0], [2.0]) == nil)
        #expect(line(.exp).fit([1.0, 2.0], [-1.0, -2.0]) == nil)
        #expect(line(.poly).fit([1.0, 2.0], [1.0, 2.0]) == nil)
        #expect(line(.linear).fit([.nan, .infinity], [1.0, 2.0]) == nil)
        var t = line(.linear)
        t.dispEq = true
        t.dispRSqr = true
        let fit = try #require(t.fit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]))
        #expect(t.caption(fit) == "y = x\nR² = 1")
    }

    @Test func equationKeepsTinyCoefficients() throws {
        let xs = [1.0, 2.0, 3.0, 4.0]
        let lin = try #require(line(.linear).fit(xs, [2e-9, 4e-9, 6e-9, 8e-9]))
        #expect(lin.equation() == "y = 2.00e-9x")
        var poly = line(.poly)
        poly.order = 2
        let quad = try #require(poly.fit(xs, xs.map { 3e-9 * $0 * $0 + 1e-9 }))
        #expect(quad.equation() == "y = 3.00e-9x² + 1.00e-9")
        let log = try #require(line(.log).fit(xs, xs.map { 5e-9 * Foundation.log($0) }))
        #expect(log.equation() == "y = 5.00e-9ln(x)")
        let zero = try #require(line(.linear).fit(xs, [0.0, 0.0, 0.0, 0.0]))
        #expect(zero.equation() == "y = 0")
    }
}
