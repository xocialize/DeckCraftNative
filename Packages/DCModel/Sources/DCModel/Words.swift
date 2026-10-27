// DCModel — word boundaries in a paragraph, as PowerPoint's Ctrl+arrow, Ctrl+Backspace/Delete and
// double-click see them. Port of deckcraft crates/model/src/words.rs (MIT OR Apache-2.0, © ArtCraft
// Team and the DeckCraft contributors), which records them as observed black-box in PowerPoint.
//
// A paragraph splits into *tokens*. Each token is a run of one class of grapheme clusters plus the
// spaces that follow it:
//
// - word: letters, digits and combining marks. An apostrophe (`'` or `’`) joins a word when a letter or
//   digit follows it; a hyphen joins when a letter or digit comes before it; `.`, `,` and `:` join
//   between digits.
// - punctuation: everything else that is not a symbol; a run of it is one token.
// - symbol: emoji and pictographs (a run of them is one token), `©`, `®`, `™`.
// - ideograph: each CJK ideograph, kana or Hangul syllable is a token of its own.
// - tab and line break: each is a token of its own, and spaces after one form their own token.
// - space: U+0020, no-break space, ideographic space and the other fixed-width spaces. Spaces join the
//   token before them; spaces at the start of a paragraph (or after a tab or line break) are a token.
//
// Positions are character (Unicode scalar) offsets in the paragraph text, where a line break is one
// `\u{0B}`. A token never splits a grapheme cluster (Swift's `Character` is the same extended grapheme
// cluster as Rust's `unicode-segmentation`).
import DCCore

private enum WordClass {
    case space, tab, lineBreak, word, ideo, punct, symbol
}

/// One grapheme cluster: its first character offset and class.
private struct Cluster {
    var start: Int
    var cls: WordClass
}

/// A space for word movement: absorbed into the token before it.
public func isWordSpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x202F, 0x205F, 0x3000: true
    default: false
    }
}

/// CJK ideographs, kana and Hangul: every one is a word of its own.
private func isIdeo(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x1100 ... 0x11FF, 0x2E80 ... 0x2FDF, 0x3005 ... 0x3007, 0x3021 ... 0x3029, 0x3031 ... 0x3035,
         0x3038 ... 0x303C, 0x3040 ... 0x309F, 0x30A0 ... 0x30FF, 0x3100 ... 0x318F, 0x31A0 ... 0x31FF,
         0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA960 ... 0xA97F, 0xAC00 ... 0xD7FF, 0xF900 ... 0xFAFF,
         0xFF66 ... 0xFFDC, 0x20000 ... 0x3134F:
        true
    default:
        false
    }
}

/// Emoji, pictographs and the common letter-like symbols.
private func isSymbol(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0xA9, 0xAE, 0x2122, 0x2190 ... 0x21FF, 0x2300 ... 0x23FF, 0x25A0 ... 0x27BF, 0x2B00 ... 0x2BFF,
         0x1F000 ... 0x1FAFF:
        true
    default:
        false
    }
}

/// Rust's `char::is_numeric`: general category Nd, Nl or No.
public func rustIsNumeric(_ c: Unicode.Scalar) -> Bool {
    switch c.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: true
    default: false
    }
}

/// Rust's `char::is_alphabetic`: the Unicode `Alphabetic` property.
public func rustIsAlphabetic(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic }

/// Rust's `char::is_alphanumeric`.
public func rustIsAlphanumeric(_ c: Unicode.Scalar) -> Bool { rustIsAlphabetic(c) || rustIsNumeric(c) }

private func baseClass(_ c: Unicode.Scalar) -> WordClass {
    switch c.value {
    case 0x0B, 0x0A, 0x0D, 0x2028, 0x2029: return .lineBreak
    case 0x09: return .tab
    default: break
    }
    if isWordSpace(c) { return .space }
    if isIdeo(c) { return .ideo }
    if rustIsAlphanumeric(c) { return .word }
    if isSymbol(c) { return .symbol }
    // A combining mark with no base (or any other mark) stays with letters.
    switch c.value {
    case 0x300 ... 0x36F, 0x1AB0 ... 0x1AFF, 0x1DC0 ... 0x1DFF, 0x20D0 ... 0x20FF, 0xFE20 ... 0xFE2F: return .word
    default: return .punct
    }
}

private func clusters(_ text: String) -> [Cluster] {
    var out: [Cluster] = []
    var firsts: [Unicode.Scalar] = []
    var pos = 0
    for g in text {
        let scalars = g.unicodeScalars
        let first = scalars.first ?? " "
        // "\r\n" is one grapheme; any other cluster takes the class of its first character.
        out.append(Cluster(start: pos, cls: baseClass(first)))
        firsts.append(first)
        pos += scalars.count
    }
    // Context: apostrophes, hyphens and number separators that belong to a word.
    let classes = out.map(\.cls)
    for i in out.indices {
        let c = firsts[i]
        let prev = i > 0 ? firsts[i - 1] : nil
        let next = firsts.at(i + 1)
        let joins: Bool
        switch c {
        case "'", "\u{2019}": joins = next.map(rustIsAlphanumeric) ?? false
        case "-": joins = prev.map(rustIsAlphanumeric) ?? false
        case ".", ",", ":": joins = (prev.map(rustIsNumeric) ?? false) && (next.map(rustIsNumeric) ?? false)
        default: joins = false
        }
        if joins && classes[i] == .punct { out[i].cls = .word }
    }
    return out
}

/// Does a token start at cluster `cur` (after `prev`)?
private func startsToken(_ prev: WordClass, _ cur: WordClass) -> Bool {
    if cur == .space {
        // Spaces join the token before them, except after a tab or a line break.
        return prev == .tab || prev == .lineBreak
    }
    return prev == .space || prev != cur || cur == .ideo || cur == .tab || cur == .lineBreak
}

public enum Words {
    /// The word stops of a paragraph's text in ascending order: 0, the start of every token, and the
    /// end of the text. Ctrl+Right goes to the next one.
    public static func stops(_ text: String) -> [Int] {
        let cs = clusters(text)
        var out = [0]
        for i in cs.indices.dropFirst() where startsToken(cs[i - 1].cls, cs[i].cls) {
            out.append(cs[i].start)
        }
        let n = text.charCount
        if out.last != n { out.append(n) }
        return out
    }

    /// The stops Ctrl+Left uses. PowerPoint's backward scan differs from the forward one in two observed
    /// details: a no-break or other non-ASCII space is a stop of its own (unless an ASCII space follows
    /// it), and a symbol followed by punctuation (`👍?`) is one token.
    public static func backStops(_ text: String) -> [Int] {
        let cs = clusters(text)
        let chars = Array(text.unicodeScalars)
        var out = [0]
        for i in cs.indices.dropFirst() {
            let (a, b) = (cs[i - 1].cls, cs[i].cls)
            let symbolPunct = (a == .symbol && b == .punct) || (a == .punct && b == .symbol)
            if startsToken(a, b) && !symbolPunct { out.append(cs[i].start) }
        }
        for (i, c) in chars.enumerated() where c != " " && isWordSpace(c) && chars.at(i + 1) != " " && i > 0 {
            out.append(i)
        }
        out = Array(Set(out)).sorted()
        let n = chars.count
        if out.last != n { out.append(n) }
        return out
    }

    /// The next stop after `ch` (Ctrl+Right), or nil at the end of the text.
    public static func nextStop(_ text: String, _ ch: Int) -> Int? { stops(text).first { $0 > ch } }

    /// The previous stop before `ch` (Ctrl+Left), or nil at the start.
    public static func prevStop(_ text: String, _ ch: Int) -> Int? { backStops(text).last { $0 < ch } }

    /// Is the character at `i` a space (for word purposes)?
    private static func spaceAt(_ chars: [Unicode.Scalar], _ i: Int) -> Bool {
        chars.at(i).map(isWordSpace) ?? false
    }

    /// The end of the token's text (before its trailing spaces) for the token containing `ch`.
    private static func contentEnd(_ text: String, _ ch: Int) -> Int {
        let chars = Array(text.unicodeScalars)
        let next = nextStop(text, ch) ?? chars.count
        var e = ch
        while e < next && !spaceAt(chars, e) { e += 1 }
        // A token made only of spaces (leading spaces) ends at the next stop.
        return e == ch && spaceAt(chars, ch) ? next : e
    }

    /// The word a double-click at `ch` selects: the token under the caret without its trailing spaces;
    /// on a space just after a token, that token; in a run of spaces, the spaces.
    public static func wordAt(_ text: String, _ ch: Int) -> (start: Int, end: Int) {
        let chars = Array(text.unicodeScalars)
        let n = chars.count
        if n == 0 { return (0, 0) }
        let ch = Swift.min(ch, n)
        let onSpace = ch >= n || spaceAt(chars, ch)
        let afterToken = ch > 0 && !spaceAt(chars, ch - 1)
        let at = onSpace && afterToken ? ch - 1 : Swift.min(ch, n - 1)
        if spaceAt(chars, at) {
            var s = at
            while s > 0 && spaceAt(chars, s - 1) { s -= 1 }
            var e = at
            while e < n && spaceAt(chars, e) { e += 1 }
            return (s, e)
        }
        let s = stops(text).last { $0 <= at } ?? 0
        return (s, Swift.min(Swift.max(contentEnd(text, s), at + 1), n))
    }

    /// What Ctrl+Delete removes from `ch` (before smart spacing): inside a token, the rest of its text;
    /// on spaces right after a token, those spaces and the next token's text; anywhere else up to the
    /// next stop. nil at the end of the text.
    public static func deleteForwardEnd(_ text: String, _ ch: Int) -> Int? {
        let chars = Array(text.unicodeScalars)
        let n = chars.count
        if ch >= n { return nil }
        let st = stops(text)
        let atStop = st.contains(ch)
        if !atStop && !spaceAt(chars, ch) { return contentEnd(text, ch) }
        let prevIsText = ch > 0 && chars.at(ch - 1).map { c in
            let cls = baseClass(c)
            return !isWordSpace(c) && cls != .tab && cls != .lineBreak
        } ?? false
        if spaceAt(chars, ch) && prevIsText {
            var j = ch
            while j < n && spaceAt(chars, j) { j += 1 }
            if j >= n { return n }
            return contentEnd(text, j)
        }
        return st.first { $0 > ch }
    }

    /// Closing punctuation that a smart delete pulls its word's spaces up to (`ab cd, ef` → Ctrl+Delete
    /// on `cd` gives `ab, ef`).
    public static func isClosingPunct(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case ".", ",", ";", ":", "!", "?", ")", "]", "}", "%", "\u{2026}", "\u{201D}", "\u{2019}", "\u{BB}": true
        default: false
        }
    }

    /// Punctuation that a smart delete keeps a space after when a word follows (`cd...ef gh` →
    /// Ctrl+Delete on `ef` gives `cd... gh`).
    public static func isSentencePunct(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case ".", ",", ";", ":", "!", "?", "\u{2026}": true
        default: false
        }
    }
}
