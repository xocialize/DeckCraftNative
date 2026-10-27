// DCModel — bidirectional text helpers (UAX #9 rules P2 and P3: paragraph base direction). Port of
// deckcraft crates/model/src/bidi.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

/// Does the first strong directional character in `text` belong to a right-to-left script? Strong AL
/// or R characters (Arabic, Hebrew, Syriac, Thaana…) give true; strong L characters (Latin, Greek,
/// Cyrillic, CJK…) give false. Neutral, weak, and whitespace characters are skipped. As in deckcraft,
/// "strong" is approximated by Rust's `char::is_alphabetic`, with the RLM and LRM marks honoured.
public func firstStrongIsRTL(_ text: String) -> Bool {
    for c in text.unicodeScalars {
        if c == "\u{200F}" { return true } // Right-to-Left Mark (RLM)
        if c == "\u{200E}" { return false } // Left-to-Right Mark (LRM)
        if rustIsAlphabetic(c) { return isRTLScript(c) }
    }
    return false
}

/// Does `c` belong to one of the standard right-to-left Unicode blocks?
public func isRTLScript(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x0590 ... 0x05FF, // Hebrew
         0x0600 ... 0x06FF, // Arabic
         0x0700 ... 0x074F, // Syriac
         0x0750 ... 0x077F, // Arabic Supplement
         0x0780 ... 0x07BF, // Thaana
         0x0870 ... 0x089F, // Arabic Extended-B
         0x08A0 ... 0x08FF, // Arabic Extended-A
         0xFB1D ... 0xFB4F, // Hebrew Presentation Forms
         0xFB50 ... 0xFDFF, // Arabic Presentation Forms-A
         0xFE70 ... 0xFEFE: // Arabic Presentation Forms-B
        true
    default:
        false
    }
}
