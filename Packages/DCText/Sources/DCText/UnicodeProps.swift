// DCText — the Unicode properties deckcraft's text layout reads, over the generated tables:
// Bidi_Class (unicode-bidi 0.3.18's `bidi_class`) and UAX #14 line-break opportunities (unicode-linebreak
// 0.1.5's `break_property` and `linebreaks`, Apache-2.0, © Axel Forsman). Same data, same answers.

/// unicode-bidi's `bidi_class`: a binary search of the range table; unlisted code points are `L`.
func bidiClass(_ c: Unicode.Scalar) -> BidiClass {
    let cp = c.value
    var lo = 0
    var hi = bidiClassRanges.count
    while lo < hi {
        let mid = (lo + hi) / 2
        let r = bidiClassRanges[mid]
        if cp < r.0 {
            hi = mid
        } else if cp > r.1 {
            lo = mid + 1
        } else {
            return r.2
        }
    }
    return .L
}

/// A strong right-to-left character (Hebrew, Arabic, …)? (deckcraft-fonts `is_rtl`)
public func isRTLChar(_ c: Unicode.Scalar) -> Bool {
    let k = bidiClass(c)
    return k == .R || k == .AL
}

private let bmpLimit: UInt32 = 0x10000
private let shift3: UInt32 = 4
private let shift2: UInt32 = 5 + shift3
private let shift1: UInt32 = 5 + shift2
private let bmpShift: UInt32 = 6
private let index2BlockLength: UInt32 = 1 << (shift1 - shift2)
private let index3BlockLength: UInt32 = 1 << (shift2 - shift3)
private let smallDataBlockLength: UInt32 = 1 << shift3
private let bmpDataBlockLength: UInt32 = 1 << bmpShift
private let allowedBreakBit: UInt8 = 0x80
private let mandatoryBreakBit: UInt8 = 0x40
private let eotClass: UInt8 = 43
private let sotState: UInt8 = 44
/// `BreakClass::Unknown` (XX) and `BreakClass::ZeroWidthJoiner`.
private let unknownClass: UInt8 = 42
private let zwjClass: UInt8 = 10

/// unicode-linebreak's `break_property`: the line-break class of a code point.
func breakProperty(_ cp: UInt32) -> UInt8 {
    let bmpIndexLength = bmpLimit >> bmpShift
    let omittedBmpIndex1Length = bmpLimit >> shift1
    let dataPos: Int
    if cp < bmpLimit {
        guard let base = lineBreakTrieIndex.at(Int(cp >> bmpShift)) else { return unknownClass }
        dataPos = Int(base) + Int(cp & (bmpDataBlockLength - 1))
    } else if cp < lineBreakTrieHighStart {
        let i1 = cp >> shift1
        guard let b2 = lineBreakTrieIndex.at(Int(i1 + bmpIndexLength - omittedBmpIndex1Length)) else { return unknownClass }
        let i2 = Int(b2) + Int((cp >> shift2) & (index2BlockLength - 1))
        guard let i3Block = lineBreakTrieIndex.at(i2) else { return unknownClass }
        let i3Pos = Int((cp >> shift3) & (index3BlockLength - 1))
        guard let dataBlock = lineBreakTrieIndex.at(Int(i3Block) + i3Pos) else { return unknownClass }
        dataPos = Int(dataBlock) + Int(cp & (smallDataBlockLength - 1))
    } else {
        return unknownClass
    }
    return lineBreakTrieData.at(dataPos) ?? unknownClass
}

/// unicode-linebreak's `linebreaks` over a scalar sequence: (scalar offset of the break, mandatory)
/// for every break opportunity, the end of the text included.
func lineBreaks(_ scalars: [Unicode.Scalar]) -> [(offset: Int, mandatory: Bool)] {
    var out: [(Int, Bool)] = []
    var state = sotState
    var afterZWJ = false
    for i in 0 ... scalars.count {
        let cls = i < scalars.count ? breakProperty(scalars[i].value) : eotClass
        let val = lineBreakPairTable.at(Int(state))?.at(Int(cls)) ?? 0
        let mandatory = val & mandatoryBreakBit != 0
        let isBreak = val & allowedBreakBit != 0 && (!afterZWJ || mandatory)
        state = val & ~(allowedBreakBit | mandatoryBreakBit)
        afterZWJ = cls == zwjClass
        if isBreak { out.append((i, mandatory)) }
    }
    return out
}
