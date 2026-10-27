// DCPPTX — just enough of the Compound File Binary (CFB/OLE2) container to tell a password-protected
// presentation apart: PowerPoint wraps an encrypted `.pptx` in a CFB holding `EncryptionInfo` and
// `EncryptedPackage` streams (ECMA-376 / [MS-OFFCRYPTO]) instead of a zip. Every read is bounds-checked
// and every loop bounded. Port of deckcraft crates/pptx/src/cfb.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors), itself copied from GridCraft's `crates/xlsx/src/cfb.rs`.
import DCCore

/// The `cfb` module.
enum CFB {
    /// The CFB signature at the start of the file.
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static let endOfChain: UInt32 = 0xFFFF_FFFE
    /// Sector ids at or above this are markers (free, end of chain, FAT/DIFAT sector), not sectors.
    static let maxRegSect: UInt32 = 0xFFFF_FFFA
    /// Directory sectors followed at most (4096 entries with 512-byte sectors).
    static let maxDirSectors = 1024
    /// DIFAT sectors followed at most.
    static let maxDifatSectors = 1024

    /// Stream names that mark an encrypted (password-protected) OOXML package.
    static let encryptedStreams = ["EncryptedPackage", "EncryptionInfo"]

    static func u16At(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt16? {
        let s = b.startIndex + at
        guard at >= 0, s <= b.endIndex - 2 else { return nil }
        return UInt16(b[s]) | UInt16(b[s + 1]) << 8
    }

    static func u32At(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt32? {
        let s = b.startIndex + at
        guard at >= 0, s <= b.endIndex - 4 else { return nil }
        return UInt32(b[s]) | UInt32(b[s + 1]) << 8 | UInt32(b[s + 2]) << 16 | UInt32(b[s + 3]) << 24
    }

    /// Whether `bytes` is a compound file holding an encryption stream. Walks the directory through the
    /// FAT; when the structure can't be followed (truncated or malformed), falls back to scanning the
    /// bytes for the UTF-16LE stream names.
    static func isEncrypted(_ bytes: [UInt8]) -> Bool {
        guard bytes.starts(with: signature) else { return false }
        if let names = directoryNames(bytes) {
            // `eq_ignore_ascii_case`
            return names.contains { n in encryptedStreams.contains { rustASCIILowercaseBytes(n) == rustASCIILowercaseBytes($0) } }
        }
        return encryptedStreams.contains { containsUTF16(bytes, $0) }
    }

    private static func rustASCIILowercaseBytes(_ s: String) -> [UInt8] {
        s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
    }

    static func containsUTF16(_ hay: [UInt8], _ needle: String) -> Bool {
        let n = needle.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        guard !n.isEmpty, hay.count >= n.count else { return false }
        for i in 0 ... (hay.count - n.count) where hay[i] == n[0] && hay[i ..< i + n.count].elementsEqual(n) {
            return true
        }
        return false
    }

    /// Names of every directory entry, or nil when the directory can't be read.
    static func directoryNames(_ bytes: [UInt8]) -> [String]? {
        let b = bytes[...]
        guard bytes.starts(with: signature) else { return nil }
        guard let shift = u16At(b, 30), shift == 9 || shift == 12 else { return nil }
        let size = 1 << Int(shift)
        let per = size / 4
        func sector(_ id: UInt32) -> ArraySlice<UInt8>? {
            let start = (Int(id) + 1) * size
            guard start + size <= bytes.count else { return nil }
            return b[start ..< start + size]
        }
        // The DIFAT: the FAT's sector ids, 109 in the header then chained DIFAT sectors.
        var difat: [UInt32] = (0 ..< 109).compactMap { u32At(b, 76 + $0 * 4) }.filter { $0 < maxRegSect }
        guard var next = u32At(b, 68) else { return nil }
        for _ in 0 ..< maxDifatSectors {
            if next >= maxRegSect { break }
            guard let s = sector(next) else { return nil }
            difat += (0 ..< per - 1).compactMap { u32At(s, $0 * 4) }.filter { $0 < maxRegSect }
            guard let n = u32At(s, (per - 1) * 4) else { return nil }
            next = n
        }
        func fatNext(_ id: UInt32) -> UInt32? {
            let idx = Int(id)
            guard let fatSector = difat.at(idx / per), let s = sector(fatSector) else { return nil }
            return u32At(s, (idx % per) * 4)
        }
        var names: [String] = []
        guard var id = u32At(b, 48) else { return nil }
        for _ in 0 ..< maxDirSectors {
            if id == endOfChain { return names }
            if id >= maxRegSect { return nil }
            guard let s = sector(id) else { return nil }
            var e = s.startIndex
            while e + 128 <= s.endIndex {
                let entry = s[e ..< e + 128]
                e += 128
                guard let raw = u16At(entry, 64) else { return nil }
                let len = Int(raw)
                if !(2 ... 64).contains(len) { continue }
                let units: [UInt16] = (0 ..< (len - 2) / 2).compactMap { u16At(entry, $0 * 2) }
                names.append(String(decoding: units, as: UTF16.self))
            }
            guard let n = fatNext(id) else { return nil }
            id = n
        }
        // A directory longer than the bound (or a cyclic chain): report what was read.
        return names
    }
}
