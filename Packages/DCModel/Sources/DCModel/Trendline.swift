// DCModel — least-squares trendlines: linear, exponential, logarithmic, polynomial, power, and a moving
// average. The fit is what the chart drawer plots and what the axis grows to include. Port of deckcraft
// crates/model/src/trendline.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import Foundation

/// A fitted trendline. `y` is nil where the model is undefined (a log of a non-positive x, an
/// exponential that overflowed).
public struct TrendFit: Sendable, Equatable {
    enum Model: Sendable, Equatable {
        /// `y = c[0] + c[1] x + c[2] x² + …`
        case poly([Double])
        /// `y = c · e^(b x)`
        case exp(c: Double, b: Double)
        /// `y = b + c · ln(x)`
        case log(b: Double, c: Double)
        /// `y = c · x^b`
        case power(c: Double, b: Double)
        /// Window averages in x order. No equation.
        case moving([Pair<Double, Double>])
    }

    let kind: TrendlineType
    let model: Model
    let r2: Double
    let xMin: Double
    let xMax: Double

    public func y(_ x: Double) -> Double? {
        if !x.isFinite { return nil }
        let y: Double
        switch model {
        case .poly(let c): y = polyY(c, x)
        case .exp(let c, let b): y = c * Foundation.exp(b * x)
        case .log(let b, let c):
            if x <= 0.0 { return nil }
            y = b + c * Foundation.log(x)
        case .power(let c, let b):
            if x <= 0.0 { return nil }
            y = c * pow(x, b)
        case .moving: return nil
        }
        return y.isFinite ? y : nil
    }

    /// Samples from `x0` to `x1`, forecast included. A moving average returns its window points and
    /// ignores the forecast (Excel does not extend one).
    public func samples(_ x0: Double, _ x1: Double) -> [(x: Double, y: Double)] {
        let (x0, x1) = x0 <= x1 ? (x0, x1) : (x1, x0)
        if !x0.isFinite || !x1.isFinite { return [] }
        if case .moving(let pts) = model {
            return pts.filter { $0.a.isFinite && $0.b.isFinite }.prefix(10_000).map { ($0.a, $0.b) }
        }
        if kind == .linear {
            return [x0, x1].compactMap { x in y(x).map { (x, $0) } }
        }
        let steps = 48
        return (0 ... steps).compactMap { i in
            let x = x0 + (x1 - x0) * Double(i) / Double(steps)
            return y(x).map { (x, $0) }
        }
    }

    /// Data x plus forecast, in category (or scatter x) units. Forecast is capped so a hostile value
    /// cannot walk off the chart.
    public func span(_ forward: Double?, _ backward: Double?) -> (Double, Double) {
        func pad(_ v: Double?) -> Double {
            guard let v, v.isFinite, v > 0.0 else { return 0.0 }
            return v.rustMin(24.0)
        }
        if kind == .movingAvg { return (xMin, xMax) }
        return (xMin - pad(backward), xMax + pad(forward))
    }

    public func equation() -> String? {
        switch model {
        case .poly(let c):
            return polyEquation(c)
        case .exp(let c, let b):
            return "y = \(trendNum(c))e^(\(trendNum(b))x)"
        case .log(let b, let c):
            guard let s = polyEquation([b, c]) else { return nil }
            guard let r = s.range(of: "x") else { return s }
            return s.replacingCharacters(in: r, with: "ln(x)")
        case .power(let c, let b):
            let mag = Swift.abs(Swift.abs(c) - 1.0) < 1e-6 ? "" : trendNum(Swift.abs(c))
            let sign = c < 0.0 ? "-" : ""
            return "y = \(sign)\(mag)\(xPow(b))"
        case .moving:
            return nil
        }
    }

    public func r2Label() -> String {
        let r = r2.isFinite ? r2 : 0.0
        return Swift.abs(r - 1.0) < 5e-4 ? "R² = 1" : "R² = \(rustFixed(r, places: 3))"
    }
}

extension Trendline {
    /// Fit `xs`/`ys` (paired). Non-finite pairs are dropped. nil when the type needs more points than
    /// it was given, or the normal equations have no solution.
    public func fit(_ xs: [Double], _ ys: [Double]) -> TrendFit? {
        var pairs: [(Double, Double)] = []
        for (x, y) in zip(xs, ys) where x.isFinite && y.isFinite {
            pairs.append((x, y))
            if pairs.count == 10_000 { break }
        }
        if pairs.count < 2 { return nil }
        pairs = rsStableSorted(pairs) { $0.0 < $1.0 }
        guard let xMinAll = pairs.first?.0, let xMaxAll = pairs.last?.0 else { return nil }
        let intercept = self.intercept.flatMap { $0.isFinite ? $0 : nil }
        let model: TrendFit.Model
        let usedY: [Double]
        let yhat: [Double]
        switch kind {
        case .linear:
            let (xs, ys) = split(pairs)
            guard let (b, m) = linreg(xs, ys, intercept) else { return nil }
            (model, usedY, yhat) = (.poly([b, m]), ys, xs.map { b + m * $0 })
        case .poly:
            let order = Int(Swift.min(Swift.max(order ?? 2, 2), 6))
            if pairs.count < order + 1 { return nil }
            let (xs, ys) = split(pairs)
            guard let coeff = polyfit(xs, ys, order, intercept) else { return nil }
            (model, usedY, yhat) = (.poly(coeff), ys, xs.map { polyY(coeff, $0) })
        case .exp:
            guard let r = fitExp(pairs, intercept) else { return nil }
            (model, usedY, yhat) = r
        case .log:
            let pos = pairs.filter { $0.0 > 0.0 }
            if pos.count < 2 { return nil }
            let lnX = pos.map { Foundation.log($0.0) }
            let ys = pos.map(\.1)
            guard let (b, c) = linreg(lnX, ys, intercept) else { return nil }
            (model, usedY, yhat) = (.log(b: b, c: c), ys, lnX.map { b + c * $0 })
        case .power:
            guard let r = fitPower(pairs, intercept) else { return nil }
            (model, usedY, yhat) = r
        case .movingAvg:
            let period = Int(Swift.min(Swift.max(period ?? 2, 2), 255))
            guard let r = fitMovingAvg(pairs, period) else { return nil }
            (model, usedY, yhat) = r
        }
        if yhat.contains(where: { !$0.isFinite }) { return nil }
        // A moving average starts at the first full window, not at the first data point.
        var (xMin, xMax) = (xMinAll, xMaxAll)
        if case .moving(let pts) = model, let a = pts.first, let b = pts.last {
            (xMin, xMax) = (a.a, b.a)
        }
        return TrendFit(kind: kind, model: model, r2: rSquared(usedY, yhat), xMin: xMin, xMax: xMax)
    }

    /// The equation and R² lines this trendline asks to show. Empty when neither is on. A moving
    /// average has no equation, and PowerPoint does not show its R², so that label is left off even
    /// when the file asks for it.
    public func caption(_ fit: TrendFit) -> String {
        var lines: [String] = []
        if dispEq, let eq = fit.equation() { lines.append(eq) }
        if dispRSqr && kind != .movingAvg { lines.append(fit.r2Label()) }
        return lines.joined(separator: "\n")
    }
}

extension Series {
    /// Trendline y values, including a short forecast, that sit near this series. The axis uses them
    /// so a forecast is not clipped off the plot. A value many times the series' own range is left
    /// out, so a wild polynomial cannot flatten the chart.
    public func trendlineYs(_ scatter: Bool) -> [Double] {
        let n = Swift.min(values.count, 10_000)
        var xs: [Double] = []
        var ys: [Double] = []
        for i in 0 ..< n {
            guard let y = values.at(i) ?? nil, y.isFinite else { continue }
            let x: Double
            if scatter {
                guard let sx = xValues.at(i) ?? nil, sx.isFinite else { continue }
                x = sx
            } else {
                x = Double(i + 1)
            }
            xs.append(x)
            ys.append(y)
        }
        let (dataLo, dataHi) = ys.reduce((Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)) { r, y in
            (r.0.rustMin(y), r.1.rustMax(y))
        }
        if !dataLo.isFinite || !dataHi.isFinite { return [] }
        let span = Swift.abs(dataHi - dataLo).rustMax(1.0)
        let mid = (dataLo + dataHi) / 2.0
        var out: [Double] = []
        for t in trendlines.prefix(8) {
            guard let fit = t.fit(xs, ys) else { continue }
            let (x0, x1) = fit.span(t.forward, t.backward)
            for (_, y) in fit.samples(x0, x1) where y.isFinite && Swift.abs(y - mid) <= span * 8.0 {
                out.append(y)
            }
        }
        return out
    }
}

/// Whether a series is plotted against numeric x values rather than category positions.
public func seriesIsScatter(_ kind: ChartType) -> Bool {
    kind == .scatter || kind == .bubble
}

private func split(_ pairs: [(Double, Double)]) -> ([Double], [Double]) {
    (pairs.map(\.0), pairs.map(\.1))
}

/// `y = b + m x`. `intercept` fixes `b`.
private func linreg(_ xs: [Double], _ ys: [Double], _ intercept: Double?) -> (Double, Double)? {
    if xs.count != ys.count || xs.count < 2 { return nil }
    if let b = intercept {
        var sxx = 0.0
        var sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += x * x
            sxy += x * (y - b)
        }
        if sxx <= 0.0 || !sxx.isFinite { return nil }
        let m = sxy / sxx
        return m.isFinite && b.isFinite ? (b, m) : nil
    }
    let n = Double(xs.count)
    let mx = rsSum(xs) / n
    let my = rsSum(ys) / n
    var sxx = 0.0
    var sxy = 0.0
    for (x, y) in zip(xs, ys) {
        let dx = x - mx
        sxx += dx * dx
        sxy += dx * (y - my)
    }
    // Constant x with a large offset leaves rounding residue in `mx`, so compare against the rounding
    // scale of the mean instead of zero.
    let r = Double.ulpOfOne * Swift.abs(mx)
    if sxx <= 4.0 * n * (r * r) || !sxx.isFinite { return nil }
    let m = sxy / sxx
    let b = my - m * mx
    return m.isFinite && b.isFinite ? (b, m) : nil
}

private func polyY(_ coeff: [Double], _ x: Double) -> Double {
    var acc = 0.0
    var xp = 1.0
    for c in coeff {
        acc += c * xp
        if !acc.isFinite { return .nan }
        xp *= x
    }
    return acc
}

private typealias FitResult = (TrendFit.Model, [Double], [Double])

private func fitExp(_ pairs: [(Double, Double)], _ intercept: Double?) -> FitResult? {
    let pairs = pairs.filter { $0.1 > 0.0 }
    if pairs.count < 2 { return nil }
    let xs = pairs.map(\.0)
    let lnY = pairs.map { Foundation.log($0.1) }
    let fixed = intercept.flatMap { $0 > 0.0 ? Foundation.log($0) : nil }
    guard let (lnC, b) = linreg(xs, lnY, fixed) else { return nil }
    let c = Foundation.exp(lnC)
    if !c.isFinite || c <= 0.0 { return nil }
    let ys = pairs.map(\.1)
    let yhat = xs.map { c * Foundation.exp(b * $0) }
    return (.exp(c: c, b: b), ys, yhat)
}

private func fitPower(_ pairs: [(Double, Double)], _ intercept: Double?) -> FitResult? {
    let pairs = pairs.filter { $0.0 > 0.0 && $0.1 > 0.0 }
    if pairs.count < 2 { return nil }
    let lnX = pairs.map { Foundation.log($0.0) }
    let lnY = pairs.map { Foundation.log($0.1) }
    let fixed = intercept.flatMap { $0 > 0.0 ? Foundation.log($0) : nil }
    guard let (lnC, b) = linreg(lnX, lnY, fixed) else { return nil }
    let c = Foundation.exp(lnC)
    if !c.isFinite || c <= 0.0 { return nil }
    let ys = pairs.map(\.1)
    let yhat = pairs.map { c * pow($0.0, b) }
    return (.power(c: c, b: b), ys, yhat)
}

private func fitMovingAvg(_ pairs: [(Double, Double)], _ period: Int) -> FitResult? {
    if pairs.count <= period { return nil }
    var pts: [Pair<Double, Double>] = []
    var ys: [Double] = []
    var yhat: [Double] = []
    for i in (period - 1) ..< pairs.count {
        let avg = rsSum(pairs[(i + 1 - period) ... i].map(\.1)) / Double(period)
        if avg.isFinite {
            pts.append(Pair(pairs[i].0, avg))
            ys.append(pairs[i].1)
            yhat.append(avg)
        }
    }
    if pts.count < 2 { return nil }
    return (.moving(pts), ys, yhat)
}

private func polyfitWithIntercept(_ xs: [Double], _ ys: [Double], _ order: Int, _ b0: Double) -> [Double]? {
    let m = order
    var ata = Array(repeating: Array(repeating: 0.0, count: m), count: m)
    var atb = Array(repeating: 0.0, count: m)
    for (x, y) in zip(xs, ys) {
        let dy = y - b0
        for i in 0 ..< m {
            let xi = rsPowi(x, Int32(i + 1))
            atb[i] += dy * xi
            for j in i ..< m {
                ata[i][j] += xi * rsPowi(x, Int32(j + 1))
            }
        }
    }
    for i in 0 ..< m {
        for j in 0 ..< i { ata[i][j] = ata[j][i] }
    }
    guard let solved = solve(ata, atb) else { return nil }
    let coeff = [b0] + solved
    return coeff.allSatisfy(\.isFinite) ? coeff : nil
}

/// Polynomial through the normal equations. `x` is centred when the intercept is free, then expanded
/// back to powers of `x`, so order 6 on category numbers stays solvable.
private func polyfit(_ xs: [Double], _ ys: [Double], _ order: Int, _ intercept: Double?) -> [Double]? {
    let n = xs.count
    if n != ys.count || !(1 ... 6).contains(order) || n < order + 1 { return nil }
    if let b0 = intercept { return polyfitWithIntercept(xs, ys, order, b0) }
    let xm = rsSum(xs) / Double(n)
    let us = xs.map { $0 - xm }
    let m = order + 1
    var ata = Array(repeating: Array(repeating: 0.0, count: m), count: m)
    var atb = Array(repeating: 0.0, count: m)
    for (u, y) in zip(us, ys) {
        for i in 0 ..< m {
            let ui = i == 0 ? 1.0 : rsPowi(u, Int32(i))
            atb[i] += y * ui
            for j in i ..< m {
                let uj = j == 0 ? 1.0 : rsPowi(u, Int32(j))
                ata[i][j] += ui * uj
            }
        }
    }
    for i in 0 ..< m {
        for j in 0 ..< i { ata[i][j] = ata[j][i] }
    }
    guard let centred = solve(ata, atb) else { return nil }
    let coeff = expandShift(centred, xm)
    return coeff.allSatisfy(\.isFinite) ? coeff : nil
}

/// `a[k]` is the coefficient of `(x - xm)^k`. Return coefficients of powers of `x`.
private func expandShift(_ a: [Double], _ xm: Double) -> [Double] {
    var c = Array(repeating: 0.0, count: a.count)
    for (k, ak) in a.enumerated() {
        var binom = 1.0
        for j in 0 ... k {
            c[j] += ak * binom * rsPowi(-xm, Int32(k - j))
            if j < k { binom *= Double(k - j) / Double(j + 1) }
        }
    }
    return c
}

/// Gauss–Jordan elimination with partial pivoting.
private func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    var a = a
    var b = b
    let n = b.count
    if n == 0 || n > 8 || a.count != n || a.contains(where: { $0.count != n }) { return nil }
    for col in 0 ..< n {
        var piv = col
        for r in (col + 1) ..< n where Swift.abs(a[r][col]) > Swift.abs(a[piv][col]) {
            piv = r
        }
        if Swift.abs(a[piv][col]) < 1e-12 { return nil }
        a.swapAt(col, piv)
        b.swapAt(col, piv)
        let div = a[col][col]
        for c in col ..< n { a[col][c] /= div }
        b[col] /= div
        for r in 0 ..< n where r != col {
            let f = a[r][col]
            if f == 0.0 { continue }
            for c in col ..< n { a[r][c] -= f * a[col][c] }
            b[r] -= f * b[col]
        }
    }
    return b.allSatisfy(\.isFinite) ? b : nil
}

private func rSquared(_ ys: [Double], _ yhat: [Double]) -> Double {
    if ys.isEmpty || ys.count != yhat.count { return 0.0 }
    let mean = rsSum(ys) / Double(ys.count)
    var ssTot = 0.0
    var ssRes = 0.0
    for (y, h) in zip(ys, yhat) {
        ssTot += (y - mean) * (y - mean)
        ssRes += (y - h) * (y - h)
    }
    if ssTot < 1e-18 { return ssRes < 1e-12 ? 1.0 : 0.0 }
    let r = 1.0 - ssRes / ssTot
    return r.isFinite ? r : 0.0
}

/// A coefficient in a trendline equation: three significant-ish digits, exponent form for very large
/// or small values.
private func trendNum(_ v: Double) -> String {
    if !v.isFinite { return "0" }
    let a = Swift.abs(v)
    if a == 0.0 { return "0" }
    if a >= 1.0e6 || a < 1.0e-3 { return rsExp(v, 2, upper: false).replacingOccurrences(of: "+", with: "") }
    let digits = a >= 100.0 ? 1 : (a >= 10.0 ? 2 : 3)
    var s = rustFixed(v, places: digits)
    if let dot = s.firstIndex(of: ".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.index(after: dot) == s.endIndex { s.removeLast() }
    }
    return s
}

private func xPow(_ p: Double) -> String {
    if Swift.abs(p - 1.0) < 1e-6 { return "x" }
    if Swift.abs(p - 2.0) < 1e-6 { return "x²" }
    if Swift.abs(p - 3.0) < 1e-6 { return "x³" }
    return "x^\(trendNum(p))"
}

private func polyEquation(_ coeff: [Double]) -> String? {
    // Drop terms that are negligible relative to the largest coefficient, so tiny-valued data keeps its
    // terms.
    let scale = coeff.reduce(0.0) { $0.rustMax(Swift.abs($1)) }
    var body = ""
    var first = true
    for (k, c) in coeff.enumerated().reversed() {
        if Swift.abs(c) <= scale * 1e-8 { continue }
        let pow: String = switch k {
        case 0: ""
        case 1: "x"
        default: xPow(Double(k))
        }
        let mag: String
        if pow.isEmpty {
            mag = trendNum(Swift.abs(c))
        } else if Swift.abs(Swift.abs(c) - 1.0) < scale.rustMax(1.0) * 1e-8 {
            mag = pow
        } else {
            mag = trendNum(Swift.abs(c)) + pow
        }
        if first {
            if c < 0.0 { body += "-" }
            body += mag
            first = false
        } else {
            body += (c < 0.0 ? " - " : " + ") + mag
        }
    }
    if body.isEmpty { body = "0" }
    return "y = \(body)"
}
