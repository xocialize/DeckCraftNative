// DCPPTX — a minimal PNG encoder for the placeholder image written when a picture's media is missing.
// Port of deckcraft crates/pptx/src/png.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

/// The `png` module.
enum PNG {
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0 ..< 8 {
                c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
        }
        return ~c
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in data {
            a = (a + UInt32(x)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ out: inout [UInt8], _ kind: String, _ data: [UInt8]) {
        out += be32(UInt32(data.count))
        let c = Array(kind.utf8) + data
        out += c
        out += be32(crc32(c))
    }

    /// A 1×1 fully transparent RGBA PNG.
    static func transparent1x1() -> [UInt8] {
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        ihdr += be32(1)
        ihdr += be32(1)
        ihdr += [8, 6, 0, 0, 0]
        chunk(&out, "IHDR", ihdr)
        // One scanline: filter byte + RGBA, stored (uncompressed) deflate block.
        let raw: [UInt8] = [0, 0, 0, 0, 0]
        var z: [UInt8] = [0x78, 0x01, 0x01]
        let len = UInt16(raw.count)
        z += [UInt8(len & 0xFF), UInt8(len >> 8)]
        z += [UInt8(~len & 0xFF), UInt8(~len >> 8)]
        z += raw
        z += be32(adler32(raw))
        chunk(&out, "IDAT", z)
        chunk(&out, "IEND", [])
        return out
    }
}
