// DCPPT — a `.ppt`'s pictures (P4 of Docs/plans/Legacy-PPT-and-Encryption.md). The drawing group's BLIP store
// ([MS-ODRAW] 2.2.20 OfficeArtBStoreContainer) lists them; shapes, fills and backgrounds name them by their 1-based
// index in it (pib, fillBlip). Each entry (2.2.32 OfficeArtFBSE) holds its blip after its name or points into the
// `Pictures` stream (foDelay). A blip (2.2.23) is a picture file after one or two 16-byte ids:
//
// - JPEG, PNG, DIB and TIFF after a tag byte. A DIB gets the BITMAPFILEHEADER that makes it a `.bmp`.
// - EMF, WMF and PICT after a 34-byte header (2.2.31 OfficeArtMetafileHeader), usually deflated. A WMF gets the
//   placeable header ([MS-WMF] 2.3.2.3, its bounds from the header's) and a PICT the 512-byte header a PICT file
//   starts with, as Apache POI writes them, so they are complete files.
//
// macOS no longer draws PICT, so a PICT holding a JPEG (QuickTime's compressed opcode, as PowerPoint for Mac wrote
// photos) becomes that JPEG, and any other goes to `PPTHooks.pict` (the engine draws it with AppKit, as PNG). Every
// length comes from the file: each is checked against what's there, and inflating stops at `maxBytes`.
import DCModel
import DCZip

/// What a `.ppt` import needs from outside DCPPT, which has no drawing code of its own.
public struct PPTHooks: Sendable {
    /// A PICT file as PNG; nil leaves the picture out.
    public var pict: (@Sendable ([UInt8]) -> [UInt8]?)?
    /// The DrawingML preset whose 8×8 tile a pattern fill's bitmap (a PNG or BMP, its dark pixels the foreground)
    /// shows; nil when none does.
    public var pattern: (@Sendable ([UInt8]) -> String?)?

    public init(pict: (@Sendable ([UInt8]) -> [UInt8]?)? = nil, pattern: (@Sendable ([UInt8]) -> String?)? = nil) {
        self.pict = pict
        self.pattern = pattern
    }
}

/// One picture as a file.
struct Blip: Equatable {
    var contentType: String
    var ext: String
    var data: [UInt8]
}

struct Pictures {
    /// Where each BLIP store entry's blip is: in the document's bytes (its own record) or at an offset in `Pictures`.
    enum Location { case inline(Range<Int>), stream(Int), none }

    let entries: [Location]
    /// The document's bytes, which inline blips are in.
    let doc: [UInt8]
    let file: PPTFile?

    /// Most bytes one picture may inflate to.
    static let maxBytes = 256 << 20
    /// Most entries a BLIP store is read for.
    static let maxEntries = 65_536

    init(entries: [Location], doc: [UInt8], file: PPTFile?) {
        self.entries = entries
        self.doc = doc
        self.file = file
    }

    /// The BLIP store of the document's drawing group.
    static func read(_ file: PPTFile, _ b: [UInt8], _ document: [Record]) -> Pictures {
        guard let group = document.first(where: { $0.type == RT.drawingGroup }),
              let dgg = group.children(b).first(where: { $0.type == RT.dggContainer }),
              let store = dgg.children(b).first(where: { $0.type == RT.bstoreContainer })
        else { return Pictures(entries: [], doc: b, file: file) }
        var entries: [Location] = []
        for r in store.children(b).prefix(maxEntries) {
            guard r.type == RT.fbse, r.body.count >= 36 else { entries.append(.none); continue }
            let p = r.body.lowerBound
            let size = le32(b, p + 20), delay = le32(b, p + 28), nameLength = Int(b[p + 33])
            let blip = p + 36 + nameLength
            if blip + 8 <= r.body.upperBound {
                entries.append(.inline(blip ..< r.body.upperBound))
            } else if size > 0, delay != 0xFFFF_FFFF {
                entries.append(.stream(Int(delay)))
            } else {
                entries.append(.none)
            }
        }
        return Pictures(entries: entries, doc: b, file: file)
    }

    /// The record bytes of BLIP store entry `pib` (1-based).
    func record(_ pib: UInt32) -> [UInt8]? {
        guard pib >= 1, Int(pib) <= entries.count else { return nil }
        switch entries[Int(pib) - 1] {
        case .inline(let r): return Array(doc[r])
        case .stream(let at): return file?.blip(at: at)
        case .none: return nil
        }
    }

    /// Picture `pib` as a file.
    func blip(_ pib: UInt32) -> Blip? { record(pib).flatMap { Self.file($0) } }

    /// A blip record as a file.
    static func file(_ rec: [UInt8]) -> Blip? {
        guard let r = Record(rec, at: 0) else { return nil }
        let end = r.body.upperBound
        // One 16-byte id, or two when the instance is odd (the second the original's, before editing).
        let start = r.body.lowerBound + (r.instance & 1 == 1 ? 32 : 16)
        switch r.type {
        case RT.blipEMF, RT.blipWMF, RT.blipPICT:
            guard start + 34 <= end else { return nil }
            let cbSave = Int(le32(rec, start + 28)), compression = rec[start + 32]
            let stored = Array(rec[start + 34 ..< min(end, start + 34 + max(0, cbSave))])
            var data = stored
            if compression == 0 {
                guard let inflated = try? Deflate.zlibInflate(stored, limit: maxBytes) else { return nil }
                data = inflated
            }
            guard !data.isEmpty else { return nil }
            switch r.type {
            case RT.blipEMF: return Blip(contentType: "image/x-emf", ext: "emf", data: data)
            case RT.blipWMF:
                if Array(data.prefix(4)) == [0xD7, 0xCD, 0xC6, 0x9A] { return Blip(contentType: "image/x-wmf", ext: "wmf", data: data) }
                // rcBounds: left, top, right, bottom.
                let bounds = (0 ..< 4).map { Int16(truncatingIfNeeded: i32(rec, start + 4 + 4 * $0)) }
                return Blip(contentType: "image/x-wmf", ext: "wmf", data: placeable(bounds) + data)
            default:
                return Blip(contentType: "image/pict", ext: "pct", data: [UInt8](repeating: 0, count: 512) + data)
            }
        case RT.blipJPEG, RT.blipJPEGCMYK, RT.blipPNG, RT.blipDIB, RT.blipTIFF:
            guard start + 1 < end else { return nil }
            let data = Array(rec[start + 1 ..< end])
            switch r.type {
            case RT.blipPNG: return Blip(contentType: "image/png", ext: "png", data: data)
            case RT.blipTIFF: return Blip(contentType: "image/tiff", ext: "tif", data: data)
            case RT.blipDIB: return bmp(data).map { Blip(contentType: "image/bmp", ext: "bmp", data: $0) }
            default: return Blip(contentType: "image/jpeg", ext: "jpg", data: data)
            }
        default:
            return nil
        }
    }

    /// The placeable header of a WMF file ([MS-WMF] 2.3.2.3): its bounds, at 72 units to the inch (as POI writes it).
    static func placeable(_ bounds: [Int16]) -> [UInt8] {
        var words: [UInt16] = [0xCDD7, 0x9AC6, 0]
        words += bounds.map { UInt16(bitPattern: $0) }
        words += [72, 0, 0]
        words.append(words.reduce(0, ^))
        return words.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// A DIB with the BITMAPFILEHEADER that makes it a `.bmp`: the bits start where the image size says they end
    /// at the end (as POI computes it), or after the header and colour table.
    static func bmp(_ dib: [UInt8]) -> [UInt8]? {
        guard dib.count >= 40 else { return nil }
        let headerSize = Int(le32(dib, 0)), bits = Int(le16(dib, 14)), compression = le32(dib, 16)
        let imageSize = Int(le32(dib, 20)), used = Int(le32(dib, 32))
        let fileSize = dib.count + 14
        var offset: Int
        if imageSize > 0, imageSize <= dib.count {
            offset = fileSize - imageSize
        } else {
            let colors = used > 0 ? min(used, 256) : (bits <= 8 ? 1 << bits : 0)
            offset = 14 + headerSize + colors * 4 + (headerSize == 40 && (compression == 3 || compression == 6) ? 12 : 0)
        }
        offset = min(max(offset, 14), fileSize)
        func u32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        return [0x42, 0x4D] + u32(fileSize) + [0, 0, 0, 0] + u32(offset) + dib
    }

    /// The JPEG inside a PICT, when it holds one (QuickTime's compressed-image opcode 0x8200, as PowerPoint for Mac
    /// stored photos): from its start-of-image marker to its last end-of-image marker.
    static func jpeg(inPICT pict: [UInt8]) -> [UInt8]? {
        guard pict.count > 512 + 10 else { return nil }
        var opcode = false
        for i in 512 ..< pict.count - 1 where pict[i] == 0x82 && pict[i + 1] == 0x00 && (i - 512) % 2 == 0 {
            opcode = true
            break
        }
        guard opcode, let soi = find(pict, [0xFF, 0xD8, 0xFF], from: 512) else { return nil }
        var eoi: Int?
        var i = pict.count - 2
        while i > soi {
            if pict[i] == 0xFF, pict[i + 1] == 0xD9 { eoi = i + 2; break }
            i -= 1
        }
        guard let eoi else { return nil }
        return Array(pict[soi ..< eoi])
    }

    static func find(_ b: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= b.count, from <= b.count - needle.count else { return nil }
        for i in from ... b.count - needle.count where b[i] == needle[0] {
            if Array(b[i ..< i + needle.count]) == needle { return i }
        }
        return nil
    }
}

/// The pictures a slide's shapes use, added to the presentation as they are first needed.
struct PictureMedia {
    var pictures: Pictures
    let hooks: PPTHooks
    /// pib → the picture's media.
    var media: [UInt32: MediaId] = [:]
    /// pib → the pattern preset its bitmap shows.
    var patterns: [UInt32: String] = [:]
    /// Pictures that couldn't be read or converted.
    var lost: Set<UInt32> = []
    /// PICT pictures converted to JPEG or PNG.
    var converted = 0

    /// The media of picture `pib`, adding it to `p` the first time.
    mutating func media(_ pib: UInt32, _ p: inout Presentation) -> MediaId? {
        if let m = media[pib] { return m }
        guard !lost.contains(pib) else { return nil }
        guard var blip = pictures.blip(pib) else { lost.insert(pib); return nil }
        if blip.contentType == "image/pict" {
            if let jpeg = Pictures.jpeg(inPICT: blip.data) {
                blip = Blip(contentType: "image/jpeg", ext: "jpg", data: jpeg)
            } else if let png = hooks.pict?(blip.data) {
                blip = Blip(contentType: "image/png", ext: "png", data: png)
            } else {
                lost.insert(pib)
                return nil
            }
            converted += 1
        }
        guard let id = p.addMedia("image\(pib).\(blip.ext)", blip.contentType, blip.data) else { lost.insert(pib); return nil }
        media[pib] = id
        return id
    }

    /// The preset of pattern bitmap `pib`.
    mutating func pattern(_ pib: UInt32) -> String? {
        if let name = patterns[pib] { return name }
        guard let blip = pictures.blip(pib), let name = hooks.pattern?(blip.data) else { return nil }
        patterns[pib] = name
        return name
    }

    /// Adds the pictures `shapes` use (their own, their fills') to `p`, and finds their fills' patterns.
    mutating func add(_ shapes: [DrawnShape], _ p: inout Presentation, master: [UInt32: [UInt16: UInt32]], depth: Int = 0) {
        guard depth < Drawing.maxDepth else { return }
        for d in shapes {
            let inherited = d.props[0x0301].flatMap { master[$0] } ?? [:]
            if let pib = d.props[0x0104] ?? inherited[0x0104] { _ = media(pib, &p) }
            if let pib = d.props[0x0186] ?? inherited[0x0186] {
                let type = d.props[0x0180] ?? inherited[0x0180] ?? 0
                if type == 1 { _ = pattern(pib) } else if type == 2 || type == 3 { _ = media(pib, &p) }
            }
            add(d.children, &p, master: master, depth: depth + 1)
        }
    }
}

/// What a shape's properties need of the pictures: the media of each picture, and the preset each pattern bitmap shows.
struct PictureRefs {
    var media: [UInt32: MediaId] = [:]
    var patterns: [UInt32: String] = [:]
}

extension PictureMedia {
    var refs: PictureRefs { PictureRefs(media: media, patterns: patterns) }
}
