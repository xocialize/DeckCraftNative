// DCText — symbol fonts (Wingdings, Symbol, Webdings…): their private-use codes, the Adobe Symbol encoding
// for installed Symbol faces that map real Unicode, and the Unicode look-alikes bullets fall back to. Port
// of deckcraft crates/text/src/lib.rs (`symbol_*`, `map_symbol_bullet`; MIT OR Apache-2.0, © ArtCraft
// Team and the DeckCraft contributors).
import DCCore

/// Is `family` a symbol font (characters at U+F000 + code)?
func isSymbolFont(_ family: String) -> Bool {
    let f = rustASCIILowercase(family)
    return f.hasPrefix("wingdings") || f == "symbol" || f.hasPrefix("webdings") || f.hasPrefix("marlett")
}

private func eqIgnoringASCIICase(_ a: String, _ b: String) -> Bool { rustASCIILowercase(a) == rustASCIILowercase(b) }

/// Does `face` draw the symbol-font character `c` (a U+F0xx private-use code)?
func coversSymbol(_ face: FontFace, _ c: Unicode.Scalar) -> Bool {
    symbolFontDraw(face, c.value & 0xFF) != nil
}

/// The character `ch` is drawn as when the item's face is the `a:sym` symbol font `sym`; nil when `ch` is
/// not such a character or the face is not that font.
func symbolMapChar(_ face: FontFace, _ ch: Unicode.Scalar, _ sym: String?) -> Unicode.Scalar? {
    let code = ch.value
    guard (0xF000 ... 0xF0FF).contains(code), let sym else { return nil }
    guard isSymbolFont(sym), eqIgnoringASCIICase(face.family, sym) else { return nil }
    return symbolFontDraw(face, code)
}

/// The real-Unicode character the Symbol font's code `code` (0x00–0xFF) maps to, in the Adobe Symbol
/// encoding (Unicode, Inc.'s `MAPPINGS/VENDORS/ADOBE/symbol.txt`). Only the non-ASCII, non-CUS entries are
/// listed.
func symbolUnicode(_ code: UInt32) -> UInt32? {
    symbolTable[code]
}

private let symbolTable: [UInt32: UInt32] = [
    0x22: 0x2200, 0x24: 0x2203, 0x27: 0x220B, 0x2A: 0x2217, 0x2D: 0x2212, 0x40: 0x2245, 0x5C: 0x2234, 0x5E: 0x22A5, 0x7E: 0x223C,
    // Greek uppercase.
    0x41: 0x0391, 0x42: 0x0392, 0x43: 0x03A7, 0x44: 0x0394, 0x45: 0x0395, 0x46: 0x03A6, 0x47: 0x0393, 0x48: 0x0397, 0x49: 0x0399,
    0x4A: 0x03D1, 0x4B: 0x039A, 0x4C: 0x039B, 0x4D: 0x039C, 0x4E: 0x039D, 0x4F: 0x039F, 0x50: 0x03A0, 0x51: 0x0398, 0x52: 0x03A1,
    0x53: 0x03A3, 0x54: 0x03A4, 0x55: 0x03A5, 0x56: 0x03C2, 0x57: 0x03A9, 0x58: 0x039E, 0x59: 0x03A8, 0x5A: 0x0396,
    // Greek lowercase (0x6A is the phi symbol, 0x6D the mu).
    0x61: 0x03B1, 0x62: 0x03B2, 0x63: 0x03C7, 0x64: 0x03B4, 0x65: 0x03B5, 0x66: 0x03C6, 0x67: 0x03B3, 0x68: 0x03B7, 0x69: 0x03B9,
    0x6A: 0x03D5, 0x6B: 0x03BA, 0x6C: 0x03BB, 0x6D: 0x03BC, 0x6E: 0x03BD, 0x6F: 0x03BF, 0x70: 0x03C0, 0x71: 0x03B8, 0x72: 0x03C1,
    0x73: 0x03C3, 0x74: 0x03C4, 0x75: 0x03C5, 0x76: 0x03D6, 0x77: 0x03C9, 0x78: 0x03BE, 0x79: 0x03C8, 0x7A: 0x03B6,
    // Euro, upsilon with hook, primes, math, suits and arrows.
    0xA0: 0x20AC, 0xA1: 0x03D2, 0xA2: 0x2032, 0xA3: 0x2264, 0xA4: 0x2215, 0xA5: 0x221E, 0xA6: 0x0192, 0xA7: 0x2663, 0xA8: 0x2666,
    0xA9: 0x2665, 0xAA: 0x2660, 0xAB: 0x2194, 0xAC: 0x2190, 0xAD: 0x2191, 0xAE: 0x2192, 0xAF: 0x2193,
    // Degree, plus-minus, double prime, math and ellipsis.
    0xB0: 0x00B0, 0xB1: 0x00B1, 0xB2: 0x2033, 0xB3: 0x2265, 0xB4: 0x00D7, 0xB5: 0x221D, 0xB6: 0x2202, 0xB7: 0x2022, 0xB8: 0x00F7,
    0xB9: 0x2260, 0xBA: 0x2261, 0xBB: 0x2248, 0xBC: 0x2026, 0xBF: 0x21B5,
    // Letterlike symbols, set relations.
    0xC0: 0x2135, 0xC1: 0x2111, 0xC2: 0x211C, 0xC3: 0x2118, 0xC4: 0x2297, 0xC5: 0x2295, 0xC6: 0x2205, 0xC7: 0x2229, 0xC8: 0x222A,
    0xC9: 0x2283, 0xCA: 0x2287, 0xCB: 0x2284, 0xCC: 0x2282, 0xCD: 0x2286, 0xCE: 0x2208, 0xCF: 0x2209,
    // Angle, nabla, product, radical, not, ands, ors, double arrows.
    0xD0: 0x2220, 0xD1: 0x2207, 0xD5: 0x220F, 0xD6: 0x221A, 0xD7: 0x22C5, 0xD8: 0x00AC, 0xD9: 0x2227, 0xDA: 0x2228, 0xDB: 0x21D4,
    0xDC: 0x21D0, 0xDD: 0x21D1, 0xDE: 0x21D2, 0xDF: 0x21D3,
    // Lozenge, angle brackets, summation, integral.
    0xE0: 0x25CA, 0xE1: 0x2329, 0xE5: 0x2211, 0xF1: 0x232A, 0xF2: 0x222B, 0xF3: 0x2320, 0xF5: 0x2321,
]

/// Apple's Mac OS Symbol diverges from the Adobe table on a few codes; tried after the Adobe mapping.
func symbolUnicodeAlts(_ code: UInt32) -> [UInt32] {
    switch code {
    case 0xA4: [0x2044]
    case 0xE1: [0x3008]
    case 0xF1: [0x3009]
    default: []
    }
}

/// The character the symbol font draws the code `code` at, when the installed `face` is that font: its
/// private-use code U+F000 + code, or, when the face has no private-use mapping (Apple's "Symbol"), the
/// Adobe Symbol encoding's real character (then its Apple alternative, then printable ASCII itself).
func symbolFontDraw(_ face: FontFace, _ code: UInt32) -> Unicode.Scalar? {
    let code = code & 0xFF
    guard let pua = Unicode.Scalar(0xF000 | code) else { return nil }
    if face.covers(pua) { return pua }
    // The table is the Symbol font's encoding; Wingdings, Webdings and the like are not Symbol.
    guard eqIgnoringASCIICase(face.family, "symbol") else { return nil }
    if let real = symbolUnicode(code) {
        return ([real] + symbolUnicodeAlts(code)).lazy.compactMap { Unicode.Scalar($0) }.first { face.covers($0) }
    }
    if (0x20 ... 0x7E).contains(code), let ascii = Unicode.Scalar(code), face.covers(ascii) { return ascii }
    return nil
}

/// The character to draw bullet `c` with the installed symbol font `face`, when `font` names a symbol font
/// that `face` is (not a substitute) and it has the glyph.
func symbolFontChar(_ face: FontFace, _ c: String, _ font: String?) -> Unicode.Scalar? {
    guard let font, isSymbolFont(font), eqIgnoringASCIICase(face.family, font), let first = c.unicodeScalars.first else { return nil }
    let cp = first.value
    // Only symbol-font codes (low byte, or the U+F000 + code form) take the mapping.
    if cp < 0x100 || (0xF000 ... 0xF0FF).contains(cp), let m = symbolFontDraw(face, cp & 0xFF) { return m }
    return face.covers(first) ? first : nil
}

/// The character that draws `c`, a character of text set in the symbol font `font`, with `face`: the
/// installed symbol font's own glyph when `face` is that font, else a Unicode look-alike as bullets use.
/// nil when `font` is not a symbol font or `c` is not a symbol code. Metafile text takes this path.
public func symbolChar(_ face: FontFace, _ font: String, _ c: Unicode.Scalar) -> Unicode.Scalar? {
    let code = c.value
    guard isSymbolFont(font), code < 0x100 || (0xF000 ... 0xF0FF).contains(code), let plain = Unicode.Scalar(code & 0xFF) else { return nil }
    let s = String(plain)
    return symbolFontChar(face, s, font) ?? mapSymbolBullet(s, font).unicodeScalars.first ?? "•"
}

/// The Unicode bullet for a symbol-font bullet character (Wingdings, Symbol), or the character.
public func mapSymbolBullet(_ c: String, _ font: String?) -> String {
    let f = rustASCIILowercase(font ?? "")
    let first = c.unicodeScalars.first ?? "•"
    if f.hasPrefix("webdings") {
        let m: Character = switch first.value & 0xFF {
        case 0x6E: "●"
        case 0x67: "■"
        case 0x61: "✓"
        case 0x72: "✕"
        case 0x33: "◀"
        case 0x34: "▶"
        case 0x35: "▲"
        case 0x36: "▼"
        default: "•"
        }
        return String(m)
    }
    if f.contains("wingdings") || f.contains("symbol") || (0xF000 ... 0xF0FF).contains(first.value) {
        let code = first.value & 0xFF
        // Wingdings 2 and 3 put different shapes at the same codes.
        if f.hasPrefix("wingdings 2") {
            let m: Character = switch code {
            case 0x97, 0x98: "●"
            case 0x9E ... 0xA1: "■"
            case 0xA2 ... 0xA5: "◆"
            case 0xEA ... 0xF3: "★"
            case 0xB7 ... 0xBF: "○"
            case 0x50: "✓"
            default: "•"
            }
            return String(m)
        }
        if f.hasPrefix("wingdings 3") {
            let m: Character = switch code {
            case 0x7D, 0x75: "►"
            case 0x7C, 0x74: "◄"
            case 0x70: "▲"
            case 0x71: "▼"
            case 0xC6, 0xC7: "➔"
            default: "▶"
            }
            return String(m)
        }
        let m: Character = switch code {
        case 0xA7: "▪"
        case 0xD8: "➢"
        case 0xFC: "✓"
        case 0x76: "❖"
        case 0x71: "❑"
        case 0x6E: "■"
        case 0x6C: "●"
        case 0xA8: "◆"
        case 0xB7: "•"
        case 0x2D: "–"
        default: "•"
        }
        return String(m)
    }
    // PowerPoint draws only the first character of a longer `buChar` ("••" draws one dot).
    return c.first.map { String($0) } ?? "•"
}
