// DCMedia — checks an MP4's box tree before the plain-audio probe and the audio decoder read it: every box
// fits inside its parent, every sample table's entries fit inside its box and every sample fits inside the
// file. Port of deckcraft crates/media/src/mp4guard.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). deckcraft runs it in front of symphonia, whose MP4 reader reserves memory from
// unchecked counts; here it keeps the same files out of the same code paths (and AudioToolbox).

enum MP4Guard {
    private static let containers: [FourCC] = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "mvex", "moof", "traf"].map {
        FourCC(bytes: Slice(Array($0.utf8)))
    }

    /// Whether `b` (an MP4) can be read without a damaged size reaching an allocation.
    static func tablesFit(_ b: [UInt8]) -> Bool {
        boxesFit(b[...], UInt64(b.count), 0)
    }

    private static func be32(_ b: Slice, _ at: Int) -> UInt64? {
        let s = b.startIndex + at
        guard at >= 0, s <= b.endIndex - 4 else { return nil }
        return UInt64(b[s]) << 24 | UInt64(b[s + 1]) << 16 | UInt64(b[s + 2]) << 8 | UInt64(b[s + 3])
    }

    private static func boxesFit(_ b: Slice, _ fileLen: UInt64, _ depth: Int) -> Bool {
        if depth > 16 { return false }
        var at = 0
        while b.count - at >= 8 {
            guard let size32 = be32(b, at) else { return false }
            let kind = FourCC(bytes: b[(b.startIndex + at + 4)..<(b.startIndex + at + 8)])
            let header: Int
            let size: UInt64
            switch size32 {
            case 0:
                (header, size) = (8, UInt64(b.count - at))
            case 1:
                guard let hi = be32(b, at + 8), let lo = be32(b, at + 12) else { return false }
                (header, size) = (16, hi << 32 | lo)
            default:
                (header, size) = (8, size32)
            }
            if size < UInt64(header) || size > UInt64(b.count - at) {
                // A box that runs past the end is fine at the top level (the file was cut short), but
                // never inside a parent.
                return depth == 0 && kind != FourCC("moov") && kind != FourCC("moof")
            }
            let body = b[(b.startIndex + at + header)..<(b.startIndex + at + Int(size))]
            let ok: Bool
            if containers.contains(kind) {
                ok = boxesFit(body, fileLen, depth + 1)
            } else if kind == FourCC("meta") {
                // ISO `meta` is a full box (version and flags first); QuickTime's is not.
                let skip = be32(body, 0) == 0 ? 4 : 0
                ok = boxesFit(body.dropFirst(min(skip, body.count)), fileLen, depth + 1)
            } else {
                ok = tableFits(kind, body, fileLen)
            }
            if !ok { return false }
            at += Int(size)
        }
        return true
    }

    /// A sample table: a full box with a count and that many entries.
    private static func tableFits(_ kind: FourCC, _ body: Slice, _ fileLen: UInt64) -> Bool {
        let entry: UInt64
        switch kind {
        case FourCC("stts"), FourCC("ctts"), FourCC("co64"): entry = 8
        case FourCC("stsc"): entry = 12
        case FourCC("stco"), FourCC("stss"): entry = 4
        case FourCC("stsz"):
            guard let size = be32(body, 4), let count = be32(body, 8) else { return false }
            if size != 0 { return size <= fileLen }
            guard body.count >= 12 else { return false }
            let entries = body.dropFirst(12)
            guard count <= UInt64(entries.count / 4) else { return false }
            var i = 0
            while UInt64(i) < count {
                guard let v = be32(entries, i * 4), v <= fileLen else { return false }
                i += 1
            }
            return true
        default:
            return true
        }
        guard let count = be32(body, 4) else { return false }
        return count <= UInt64(max(body.count - 8, 0)) / entry
    }
}
