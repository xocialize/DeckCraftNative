// DCText — the font inside a PresentationML embedded-font part. Port of deckcraft crates/fonts/src/lib.rs
// (`embedded_sfnt`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).

/// The TrueType or OpenType font inside a PresentationML embedded-font part (`application/x-fontdata`):
/// the part itself, or the font at the end of an Embedded OpenType wrapper (the `0x504C` magic at byte 34).
/// A MicroType Express subset is neither, so this returns nil; the original part stays in the file for the
/// round trip.
public func embeddedSFNT(_ part: [UInt8]) -> ArraySlice<UInt8>? {
    eotPayload(part) ?? (isSFNTOrCollection(part[...]) ? part[...] : nil)
}

private func isSFNTOrCollection(_ b: ArraySlice<UInt8>) -> Bool {
    guard b.count >= 12 else { return false }
    let head = Array(b.prefix(4))
    return head == [0x00, 0x01, 0x00, 0x00] || head == Array("OTTO".utf8) || head == Array("true".utf8) || head == Array("typ1".utf8)
        || head == Array("ttcf".utf8)
}

private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

/// Font data at the end of an Embedded OpenType blob, when the header is one.
private func eotPayload(_ b: [UInt8]) -> ArraySlice<UInt8>? {
    guard b.count >= 82, UInt16(b[34]) | UInt16(b[35]) << 8 == 0x504C else { return nil }
    guard [0x0001_0000, 0x0002_0001, 0x0002_0002].contains(le32(b, 8)) else { return nil }
    let eotSize = Int(le32(b, 0))
    let fontSize = Int(le32(b, 4))
    guard fontSize >= 12, eotSize >= fontSize + 82, eotSize <= b.count else { return nil }
    let font = b[(eotSize - fontSize) ..< eotSize]
    return isSFNTOrCollection(font) ? font : nil
}
