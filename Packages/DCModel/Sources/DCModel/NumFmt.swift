// DCModel — number formats: Excel format codes (`#,##0`, `0.0%`, `_-* # ##0 "₽"_-;…`, `General`) as chart
// axes and data labels show them, in the chart's language (digit grouping and decimal mark). Port of
// deckcraft crates/model/src/numfmt.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), plus the Rust float semantics the chart, trendline and table ports share.
import DCCore
import Foundation

// MARK: - Rust semantics shared by Chart, Trendline, NumFmt and Table

/// Rust's `f64::powi` (LLVM's `__powidf2`): repeated squaring, so results match deckcraft's to the bit
/// where `pow` would round differently.
func rsPowi(_ x: Double, _ n: Int32) -> Double {
    var a = x
    var b = n
    var r = 1.0
    while true {
        if b & 1 != 0 { r *= a }
        b /= 2
        if b == 0 { break }
        a *= a
    }
    return n < 0 ? 1.0 / r : r
}

/// Rust's `Iterator::sum` for `f64`: a left fold from `-0.0` (an empty sum is `-0.0`).
func rsSum<S: Sequence>(_ s: S) -> Double where S.Element == Double {
    s.reduce(-0.0, +)
}

/// Rust's `format!("{}", v)` for `f64`: the shortest digits that read back, laid out without an
/// exponent (`1`, `-0`, `0.00000015`, `1000000000000000000000`).
func rsDisplay(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    let negative = v.sign == .minus
    let desc = v.magnitude.description
    var mantissa = Substring(desc)
    var exponent = 0
    if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = desc[..<e]
        exponent = Int(desc[desc.index(after: e)...]) ?? 0
    }
    var digits: [Character] = []
    var afterPoint = 0
    var seenPoint = false
    for c in mantissa {
        if c == "." {
            seenPoint = true
        } else if c.isASCII, c.isNumber {
            digits.append(c)
            if seenPoint { afterPoint += 1 }
        }
    }
    var k = exponent - afterPoint // value = digits × 10^k
    while let f = digits.first, f == "0" { digits.removeFirst() }
    while let l = digits.last, l == "0" {
        digits.removeLast()
        k += 1
    }
    var s = negative ? "-" : ""
    if digits.isEmpty { return s + "0" }
    if k >= 0 {
        s += String(digits) + String(repeating: "0", count: k)
    } else if -k < digits.count {
        let point = digits.count + k
        s += String(digits[..<point]) + "." + String(digits[point...])
    } else {
        s += "0." + String(repeating: "0", count: -k - digits.count) + String(digits)
    }
    return s
}

/// Rust's `format!("{v:.Ne}")` / `{v:.NE}`: the mantissa correctly rounded to `places` decimals, the
/// exponent with no `+` and no padding (`2.00e-9`, `1.50e6`).
func rsExp(_ v: Double, _ places: Int, upper: Bool) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    let c = String(format: "%.\(places)e", v)
    guard let e = c.firstIndex(of: "e") else { return c }
    let exp = Int(c[c.index(after: e)...]) ?? 0
    return String(c[..<e]) + (upper ? "E" : "e") + String(exp)
}

/// A stable sort by a strict "comes before" order, as Rust's `sort_by` is.
func rsStableSorted<T>(_ items: [T], by before: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { l, r in
        if before(l.element, r.element) { return true }
        if before(r.element, l.element) { return false }
        return l.offset < r.offset
    }.map(\.element)
}

/// Rust's `f64::total_cmp` as a strict order.
func rsTotalLess(_ a: Double, _ b: Double) -> Bool {
    a.isTotallyOrdered(belowOrEqualTo: b) && !b.isTotallyOrdered(belowOrEqualTo: a)
}

/// Rust's `str::eq_ignore_ascii_case`.
func rsEqIgnoreASCIICase(_ a: Substring, _ b: String) -> Bool {
    rustASCIILowercase(String(a)) == rustASCIILowercase(b)
}

// MARK: - Number formats

public enum NumFmt {
    /// Digit grouping and decimal mark for a language tag (`ru-RU`, `de-DE`, `en-US`).
    static func marks(_ lang: String?) -> (sep: Character, dec: Character) {
        let tag = lang ?? "en"
        let first = tag.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "_" }.first.map(String.init) ?? "en"
        switch rustASCIILowercase(first) {
        // Space-grouped, comma decimal.
        case "ru", "uk", "be", "kk", "fr", "pl", "cs", "sk", "sv", "fi", "nb", "nn", "no", "bg", "lt", "lv", "et", "hu", "uz", "hy",
             "ka", "az":
            return ("\u{a0}", ",")
        // Dot-grouped, comma decimal.
        case "de", "es", "it", "pt", "nl", "da", "tr", "el", "ro", "id", "sr", "hr", "sl", "vi":
            return (".", ",")
        default:
            return (",", ".")
        }
    }

    enum Tok: Equatable {
        /// Text shown as is.
        case lit(String)
        /// A digit placeholder: `0`, `#` or `?`.
        case digit(Character)
        case dot
        case comma
        case percent

        var isDigit: Bool {
            if case .digit = self { return true }
            return false
        }
    }

    /// A section's tokens (`[$₽-419]` gives its symbol; colours, conditions and locales drop out).
    static func tokens(_ section: String) -> [Tok] {
        var out: [Tok] = []
        let cs = Array(section.unicodeScalars)
        var i = 0
        func next() -> Unicode.Scalar? {
            guard i < cs.count else { return nil }
            defer { i += 1 }
            return cs[i]
        }
        while let c = next() {
            switch c {
            case "\"":
                var s = String.UnicodeScalarView()
                while let d = next(), d != "\"" { s.append(d) }
                out.append(.lit(String(s)))
            case "\\":
                if let d = next() { out.append(.lit(String(d))) }
            // Padding the width of the next character: a space.
            case "_":
                _ = next()
                out.append(.lit(" "))
            // Repeat-to-fill: nothing on an axis.
            case "*":
                _ = next()
            case "[":
                var s = String.UnicodeScalarView()
                while let d = next(), d != "]" { s.append(d) }
                let str = String(s)
                if str.hasPrefix("$") {
                    let sym = str.dropFirst().split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !sym.isEmpty { out.append(.lit(sym)) }
                }
            case "0", "#", "?": out.append(.digit(Character(c)))
            case ".": out.append(.dot)
            case ",": out.append(.comma)
            case "%": out.append(.percent)
            case "@": break
            default: out.append(.lit(String(c)))
            }
        }
        return out
    }

    /// The format's sections split at `;` (outside quotes, brackets and escapes).
    static func sections(_ code: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var quoted = false
        var bracket = false
        var escaped = false
        for c in code.unicodeScalars {
            if escaped {
                escaped = false
                current.append(c)
                continue
            }
            switch c {
            case "\\" where !quoted: escaped = true
            case "\"": quoted.toggle()
            case "[" where !quoted: bracket = true
            case "]" where !quoted: bracket = false
            case ";" where !quoted && !bracket:
                out.append(String(current))
                current = String.UnicodeScalarView()
                continue
            default: break
            }
            current.append(c)
        }
        out.append(String(current))
        return out
    }

    /// `v` in the General format: up to 10 significant digits, no grouping.
    static func general(_ v: Double, _ dec: Character) -> String {
        if v == 0.0 { return "0" }
        let a = Swift.abs(v)
        var s: String
        if !(a >= 1e-9 && a < 1e11) {
            s = rsExp(v, 5, upper: true)
            if let e = s.firstIndex(of: "E") {
                var m = String(s[..<e])
                if m.contains(".") {
                    while m.hasSuffix("0") { m.removeLast() }
                    while m.hasSuffix(".") { m.removeLast() }
                }
                let ex = Int32(s[s.index(after: e)...]) ?? 0
                let mag = String(ex.magnitude)
                s = "\(m)E\(ex < 0 ? "-" : "+")\(mag.count < 2 ? "0" + mag : mag)"
            }
        } else {
            let digits = Int(Swift.min(Swift.max(10 - (Int32(rustCast: log10(a).rounded(.down)) &+ 1), 0), 10))
            s = rustFixed(v, places: digits)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                while s.hasSuffix(".") { s.removeLast() }
            }
        }
        return s.replacingOccurrences(of: ".", with: String(dec))
    }

    /// Group an integer's digits in threes with `sep`.
    static func group(_ digits: String, _ sep: Character) -> String {
        let ds = Array(digits)
        let n = ds.count
        var out = ""
        for (i, d) in ds.enumerated() {
            if i > 0 && (n - i) % 3 == 0 { out.append(sep) }
            out.append(d)
        }
        return out
    }

    /// `v` formatted with the Excel number format `code` in language `lang` (axis labels: the text
    /// section of a format doesn't apply).
    public static func format(_ code: String, _ v: Double, _ lang: String?) -> String {
        let (sep, dec) = marks(lang)
        if !v.isFinite { return "" }
        let secs = sections(code)
        // The section for the value's sign; a negative or zero section shows the value unsigned.
        let sec: String
        let value: Double
        let minus: Bool
        if secs.count >= 2, v < 0.0 {
            (sec, value, minus) = (secs[1], -v, false)
        } else if secs.count >= 3, v == 0.0 {
            (sec, value, minus) = (secs[2], v, false)
        } else if let pos = secs.first {
            (sec, value, minus) = (pos, Swift.abs(v), v < 0.0)
        } else {
            (sec, value, minus) = ("General", Swift.abs(v), v < 0.0)
        }
        if rsEqIgnoreASCIICase(rustTrim(sec), "general") || (secs.count == 1 && rustTrim(sec).isEmpty) {
            let s = general(value, dec)
            return minus ? "-" + s : s
        }
        let toks = tokens(sec)
        guard let first = toks.firstIndex(where: \.isDigit), let last = toks.lastIndex(where: \.isDigit) else {
            // No digits: just the section's text ("-" for zero, a label).
            let s = toks.compactMap { if case .lit(let s) = $0 { s } else { nil } }.joined()
            return String(rustTrim(s))
        }
        let out = rustTrim(sci(toks, value, sep, dec) ?? fixed(toks, first, last, value, sep, dec))
        return minus && !out.isEmpty ? "-" + out : String(out)
    }

    /// The text of the literal and percent tokens in `ts`.
    static func lits(_ ts: ArraySlice<Tok>) -> String {
        ts.compactMap { t -> String? in
            switch t {
            case .lit(let s): s
            case .percent: "%"
            default: nil
            }
        }.joined()
    }

    /// Scientific notation (`0.00E+00`, `##0.0E-0`): the mantissa takes the placeholders before the
    /// `E`, the exponent's sign and minimum width come from what follows it; with several integer
    /// placeholders the exponent is a multiple of their count (engineering notation). nil if the
    /// section has no exponent part.
    static func sci(_ toks: [Tok], _ v: Double, _ sep: Character, _ dec: Character) -> String? {
        guard let e = toks.firstIndex(where: { $0 == .lit("E") || $0 == .lit("e") }) else { return nil }
        let eChar: String = if case .lit(let s) = toks[e] { s } else { "E" }
        guard let signTok = toks.at(e + 1) else { return nil }
        let plus: Bool
        switch signTok {
        case .lit("+"): plus = true
        case .lit("-"): plus = false
        default: return nil
        }
        let mant = toks[..<e]
        guard let mfirst = mant.firstIndex(where: \.isDigit), let mlast = mant.lastIndex(where: \.isDigit) else { return nil }
        guard e + 2 <= toks.count else { return nil }
        let expToks = toks[(e + 2)...]
        let expLen = expToks.prefix(while: \.isDigit).count
        if expLen == 0 { return nil }
        let width = expToks.prefix(expLen).filter { $0 == .digit("0") }.count
        let rest = expToks.dropFirst(expLen)
        let mantFrac = mant.drop { $0 != .dot }.filter(\.isDigit).count
        var m = 0.0
        var exp: Int32 = 0
        if v != 0.0 {
            exp = Int32(rustCast: log10(v).rounded(.down))
            if exp < -300 {
                // 10^exp underflows for subnormals; scale in two steps.
                m = v * 1e300 / rsPowi(10.0, exp + 300)
            } else {
                m = v / rsPowi(10.0, exp)
            }
            if !m.isFinite {
                m = 0.0
                exp = 0
            }
            if m >= 10.0 {
                m /= 10.0
                exp += 1
            } else if m < 1.0 {
                m *= 10.0
                exp -= 1
            }
            // Rounding the mantissa to its digits can reach 10 (9.999 as `0.00`).
            if rustFixed(m, places: mantFrac).hasPrefix("10") {
                m /= 10.0
                exp += 1
            }
        }
        let step = Int32(Swift.max(mant.prefix { $0 != .dot }.filter(\.isDigit).count, 1))
        // Rust's `rem_euclid`: never negative.
        let shift = ((exp % step) + step) % step
        exp -= shift
        m *= rsPowi(10.0, shift)
        let mantissa = fixed(Array(mant), mfirst, mlast, m, sep, dec)
        let sign = exp < 0 ? "-" : (plus ? "+" : "")
        let digits = String(exp.magnitude)
        let pad = String(repeating: "0", count: Swift.max(width - digits.count, 0))
        return "\(mantissa)\(eChar)\(sign)\(pad)\(digits)\(lits(rest))"
    }

    /// `v` (not negative) in the fixed-point format whose tokens are `toks`, with its digits from
    /// `first` to `last`.
    static func fixed(_ toks: [Tok], _ first: Int, _ last: Int, _ v: Double, _ sep: Character, _ dec: Character) -> String {
        let percent = toks.contains(.percent)
        let number = first <= last && last < toks.count ? toks[first ... last] : []
        let intPart: ArraySlice<Tok>
        let fracPart: ArraySlice<Tok>
        if let d = number.firstIndex(of: .dot) {
            intPart = number[..<d]
            fracPart = number[(d + 1)...]
        } else {
            intPart = number
            fracPart = []
        }
        // Grouping: a comma (or the locale's space, written literally) between integer digits.
        let grouping = intPart.contains { t in
            if t == .comma { return true }
            if case .lit(let s) = t { return rustTrim(s).isEmpty }
            return false
        }
        // Commas right after the last digit scale by a thousand each (`#,##0,` = thousands).
        let after = toks.dropFirst(last + 1)
        let scaleCommas = after.prefix { $0 == .comma }.count
        let minInt = intPart.filter { $0 == .digit("0") }.count
        let fracDigits: [Character] = fracPart.compactMap { if case .digit(let c) = $0 { c } else { nil } }
        let maxFrac = fracDigits.count
        let minFrac = fracDigits.filter { $0 == "0" }.count
        var x = v * (percent ? 100.0 : 1.0) / rsPowi(1000.0, Int32(clamping: scaleCommas))
        if !x.isFinite { x = 0.0 }
        let s = rustFixed(x, places: maxFrac)
        let ipRaw: Substring
        var fp: String
        if let dot = s.firstIndex(of: ".") {
            ipRaw = s[..<dot]
            fp = String(s[s.index(after: dot)...])
        } else {
            ipRaw = Substring(s)
            fp = ""
        }
        while fp.utf8.count > minFrac && fp.hasSuffix("0") { fp.removeLast() }
        let trimmed = String(ipRaw.drop { $0 == "0" })
        let ip = trimmed.utf8.count < minInt ? String(repeating: "0", count: minInt - trimmed.utf8.count) + trimmed : trimmed
        var num = grouping ? group(ip, sep) : ip
        if !fp.isEmpty {
            num.append(dec)
            num += fp
        }
        let before = lits(toks.prefix(first))
        let afterText = lits(toks.dropFirst(last + 1))
        return "\(before)\(num)\(afterText)"
    }
}
