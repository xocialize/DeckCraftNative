// DCCore — Rust's string semantics where Swift's differ: Unicode-whitespace trimming, ASCII-only case
// mapping, and `format!("{v:.N}")`.
import Foundation

/// Rust's `str::trim`: strips Unicode `White_Space` from both ends.
public func rustTrim(_ s: String) -> Substring {
    let ws: (Character) -> Bool = { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
    guard let start = s.firstIndex(where: { !ws($0) }), let end = s.lastIndex(where: { !ws($0) }) else { return "" }
    return s[start ... end]
}

/// Rust's `to_ascii_lowercase`: only A–Z change.
public func rustASCIILowercase(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { ("A" ... "Z").contains($0) ? Unicode.Scalar($0.value + 32) ?? $0 : $0 }))
}

/// Rust's `format!("{v:.N}")`: fixed places, correctly rounded from the exact binary value, `-` kept on
/// a negative value that rounds to zero, `NaN` and `inf` spelled as Rust spells them.
public func rustFixed(_ v: Double, places: Int) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    return String(format: "%.\(places)f", v)
}

/// Rust's `==` on strings: the same Unicode scalars (Swift's `==` also equates canonically equivalent
/// strings, such as precomposed and decomposed `é`).
public func rustEqual(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// Rust's `str::to_uppercase`: each scalar's full uppercase mapping, no context.
public func rustUppercase(_ s: String) -> String {
    s.unicodeScalars.map(\.properties.uppercaseMapping).joined()
}

/// Rust's `str::to_lowercase`: each scalar's full lowercase mapping, except that a capital sigma at the
/// end of a word becomes final sigma `ς` (preceded by a cased letter and not followed by one, skipping
/// case-ignorable characters), as Unicode's Final_Sigma condition says.
public func rustLowercase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = ""
    for (i, c) in scalars.enumerated() {
        if c == "\u{03A3}" {
            let before = scalars[..<i].reversed().first { !$0.properties.isCaseIgnorable }
            let after = scalars[(i + 1)...].first { !$0.properties.isCaseIgnorable }
            if before?.properties.isCased == true && after?.properties.isCased != true {
                out += "\u{03C2}"
                continue
            }
        }
        out += c.properties.lowercaseMapping
    }
    return out
}

/// Rust's `str::lines`: split on `\n`, dropping a `\r` before it and the empty piece after a final
/// newline.
public func rustLines(_ s: String) -> [String] {
    var lines = s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { piece -> String in
        var v = String.UnicodeScalarView(piece)
        if v.last == "\r" { v.removeLast() }
        return String(v)
    }
    if s.unicodeScalars.last == "\n" || s.isEmpty { lines.removeLast() }
    return lines
}

/// Rust's `str::trim_start`.
public func rustTrimStart(_ s: Substring) -> Substring {
    let ws: (Character) -> Bool = { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
    guard let start = s.firstIndex(where: { !ws($0) }) else { return s[s.endIndex...] }
    return s[start...]
}

/// Rust's `str::trim_end`.
public func rustTrimEnd(_ s: Substring) -> Substring {
    let ws: (Character) -> Bool = { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
    guard let end = s.lastIndex(where: { !ws($0) }) else { return s[s.startIndex ..< s.startIndex] }
    return s[...end]
}
