// DCPPT — the pictures (P4): every picture in every fixture's BLIP store has POI's bytes; the import report names each
// OLE object that came over as its picture; PowerPoint's own save of the pictures deck (Tools/legacy/picture-deck.py,
// local only) comes back as the original's pictures, crops, corrections, fills and backgrounds; every slide's comments
// are POI's; and hostile blips, objects and comments never trap.
import CryptoKit
import DCEngine
import DCModel
import DCPPTX
import DCZip
import Foundation
import Testing
@testable import DCPPT

@Suite struct PictureTests {
    static func sha256(_ b: [UInt8]) -> String { SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined() }

    /// The pictures of every fixture, as files, are POI's (a PICT, which POI leaves as PICT, aside); the report lists
    /// one entry per OLE object POI finds on the slides; and each slide's comments are POI's.
    @Test func everyPictureAndCommentIsPOIs() throws {
        struct Dump: Decodable {
            struct Shape: Decodable { let kind: String; let children: [Shape]? }
            struct Comment: Decodable { let author: String?; let initials: String?; let text: String?; let x: Double; let y: Double }
            struct Slide: Decodable { let shapes: [Shape]; let comments: [Comment]? }
            let slides: [Slide]
            let pictures: [ShapeTests.Dump.Picture]?
        }
        var pictures = 0, comments = 0
        for c in try ShapeTests.cases() {
            guard FileManager.default.fileExists(atPath: c.ref.path) else { continue }
            let ref = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: c.ref))
            let bytes = Array(try Data(contentsOf: c.file))
            let file = try PPTFile(bytes, password: c.password)
            let doc = try #require(file.object(file.documentRef))
            let root = try #require(Record(doc, at: 0))
            let store = Pictures.read(file, doc, root.children(doc))
            let ours = (1 ... max(1, store.entries.count)).compactMap { store.blip(UInt32($0)) }
                .filter { $0.contentType != "image/pict" }.map { Self.sha256($0.data) }
            let theirs = (ref.pictures ?? []).filter { $0.type != "PICT" }.compactMap(\.sha256)
            #expect(ours.sorted() == theirs.sorted(), "\(c.name): \(ours.count) pictures, POI \(theirs.count)")
            pictures += ours.count

            func objects(_ list: [Dump.Shape]) -> Int {
                list.reduce(0) { $0 + ($1.kind == "HSLFObjectShape" ? 1 : 0) + objects($1.children ?? []) }
            }
            let (p, report) = try PPT.importChecked(bytes, password: c.password)
            #expect(report.asPictures.count == ref.slides.reduce(0) { $0 + objects($1.shapes) }, "\(c.name): \(report.asPictures)")
            #expect(report.lostPictures == 0, "\(c.name)")
            for (i, (slide, theirs)) in zip(p.slides, ref.slides).enumerated() {
                let want = theirs.comments ?? []
                #expect(slide.comments.count == want.count, "\(c.name) slide \(i + 1): comments")
                for (ours, poi) in zip(slide.comments, want) {
                    #expect(ours.author == poi.author ?? "" && ours.initials == poi.initials ?? "" && ours.text == poi.text ?? "",
                            "\(c.name) slide \(i + 1): \(ours.text)")
                    #expect(abs(ours.x - poi.x) < 0.01 && abs(ours.y - poi.y) < 0.01, "\(c.name) slide \(i + 1): at \(ours.x),\(ours.y)")
                    #expect(!ours.date.isEmpty)
                    comments += 1
                }
            }
        }
        #expect(pictures > 150)
        #expect(comments >= 4)
    }

    /// PowerPoint's save of the pictures deck comes back as the original: each picture's bytes, crop and corrections;
    /// the picture, tiled and pattern fills; the backgrounds; and the comments.
    @Test func powerPointsPicturesComeBackAsTheOriginals() throws {
        let file = ShapeTests.local.appending(path: "pictures.open.ppt")
        let original = PPTFileTests.legacy.appending(path: "pptx/pictures.pptx")
        guard FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: original.path) else { return }
        let (ours, report) = try PPT.importChecked(Array(try Data(contentsOf: file)), password: "Password1", hooks: LegacyPictures.hooks)
        let (want, _) = try PPTX.importChecked(Array(try Data(contentsOf: original)))
        try #require(ours.slides.count == want.slides.count)
        #expect(report.lostPictures == 0)
        func bytes(_ p: Presentation, _ m: MediaId) -> [UInt8] { p.media(m)?.data ?? [] }

        // Pictures: the same file, crop and corrections.
        let pics = ours.slides[1].shapes, orig = want.slides[1].shapes
        try #require(pics.count == orig.count)
        for (k, (s, o)) in zip(pics, orig).enumerated() {
            guard case .picture(let f) = s.kind, case .picture(let g) = o.kind else { Issue.record("picture \(k): \(s.kind)"); continue }
            #expect(bytes(ours, f.media) == bytes(want, g.media), "picture \(k)")
            #expect(zip(f.crop, g.crop).allSatisfy { abs($0 - $1) < 0.001 }, "picture \(k): crop \(f.crop), original \(g.crop)")
            #expect(abs(f.adjust.brightness - g.adjust.brightness) < 0.02, "picture \(k): brightness \(f.adjust.brightness), original \(g.adjust.brightness)")
            #expect(abs(f.adjust.contrast - g.adjust.contrast) < 0.02, "picture \(k): contrast \(f.adjust.contrast), original \(g.adjust.contrast)")
            #expect(f.adjust.grayscale == g.adjust.grayscale, "picture \(k): greyscale")
            #expect((f.adjust.bilevel == nil) == (g.adjust.bilevel == nil), "picture \(k): black and white")
            #expect(f.adjust.clearColor == g.adjust.clearColor, "picture \(k): transparent colour")
            if let x = s.xfrm, let y = o.xfrm { #expect(abs(x.x - y.x) < 0.6 && abs(x.w - y.w) < 0.6, "picture \(k): box") }
        }

        // Fills: a picture stretched, a picture tiled, a JPEG, and the patterns by preset.
        let fills = ours.slides[2].shapes, ofills = want.slides[2].shapes
        try #require(fills.count == ofills.count)
        var patterns = 0
        for (k, (s, o)) in zip(fills, ofills).enumerated() {
            switch (s.fill, o.fill) {
            case (.picture(let f)?, .picture(let g)?):
                #expect(bytes(ours, f.media) == bytes(want, g.media), "fill \(k)")
                let tiled = if case .tile = f.mode { true } else { false }, otiled = if case .tile = g.mode { true } else { false }
                #expect(tiled == otiled, "fill \(k): tiled \(tiled)")
            case (.pattern(let f)?, .pattern(let g)?):
                #expect(f.preset == g.preset, "fill \(k): \(f.preset), original \(g.preset)")
                patterns += 1
            default:
                // PowerPoint keeps a pattern with no legacy bitmap as a picture of it, in a group.
                if case .group = s.kind { continue }
                Issue.record("fill \(k): \(String(describing: s.fill)), original \(String(describing: o.fill))")
            }
        }
        #expect(patterns == 5)

        // Backgrounds: a picture, a tiled picture, a pattern.
        for i in 3 ... 5 {
            switch (ours.slides[i].background, want.slides[i].background) {
            case (.fill(.picture(let f))?, .fill(.picture(let g))?):
                #expect(bytes(ours, f.media) == bytes(want, g.media), "background \(i)")
                let tiled = if case .tile = f.mode { true } else { false }, otiled = if case .tile = g.mode { true } else { false }
                #expect(tiled == otiled, "background \(i): tiled \(tiled)")
            case (.fill(.pattern(let f))?, .fill(.pattern(let g))?):
                #expect(f.preset == g.preset, "background \(i): \(f.preset), original \(g.preset)")
            case (let a, let b):
                Issue.record("background \(i): \(String(describing: a)), original \(String(describing: b))")
            }
        }

        // PowerPoint 16 leaves its comments out of a `.ppt` (they're checked on LibreOffice's files, against POI).
        #expect(ours.slides[6].comments.isEmpty)
    }

    /// Each kind of blip becomes a complete file; damaged ones are refused, never read past.
    @Test func blipsBecomeFiles() throws {
        func record(_ type: UInt16, instance: UInt16, _ body: [UInt8]) -> [UInt8] {
            let vi = instance << 4
            let n = UInt32(body.count)
            return [UInt8(vi & 0xFF), UInt8(vi >> 8), UInt8(type & 0xFF), UInt8(type >> 8),
                    UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + body
        }
        let uid = [UInt8](repeating: 7, count: 16)
        // A PNG: one id and a tag.
        let png = Pictures.file(record(RT.blipPNG, instance: 0x6E0, uid + [0xFF] + [1, 2, 3]))
        #expect(png == Blip(contentType: "image/png", ext: "png", data: [1, 2, 3]))
        // Two ids when the instance is odd.
        #expect(Pictures.file(record(RT.blipJPEG, instance: 0x46B, uid + uid + [0xFF, 9]))?.data == [9])

        // A deflated WMF gets the placeable header, its checksum the XOR of its first ten words.
        let wmf: [UInt8] = [1, 0, 9, 0, 0, 3, 0x10, 0, 0, 0]
        let deflated = try Deflate.zlibDeflate(wmf)
        var header = [UInt8](repeating: 0, count: 34)
        for (k, v) in [Int32(0), 0, 2000, 1000].enumerated() { withUnsafeBytes(of: v.littleEndian) { header.replaceSubrange(4 + 4 * k ..< 8 + 4 * k, with: $0) } }
        withUnsafeBytes(of: UInt32(deflated.count).littleEndian) { header.replaceSubrange(28 ..< 32, with: $0) }
        let w = try #require(Pictures.file(record(RT.blipWMF, instance: 0x216, uid + header + deflated)))
        #expect(w.contentType == "image/x-wmf" && Array(w.data.prefix(4)) == [0xD7, 0xCD, 0xC6, 0x9A] && Array(w.data.dropFirst(22)) == wmf)
        let words = (0 ..< 11).map { UInt16(w.data[2 * $0]) | UInt16(w.data[2 * $0 + 1]) << 8 }
        #expect(words[0 ..< 10].reduce(0, ^) == words[10])
        #expect(words[5] == 2000 && words[6] == 1000 && words[7] == 72)

        // A PICT gets its 512-byte header; one holding a JPEG gives that JPEG.
        header[32] = 0xFE
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9]
        let quicktime: [UInt8] = [0x00, 0x11, 0x02, 0xFF, 0x82, 0x00] + jpeg + [0x00, 0xFF]
        withUnsafeBytes(of: UInt32(quicktime.count).littleEndian) { header.replaceSubrange(28 ..< 32, with: $0) }
        let pict = try #require(Pictures.file(record(RT.blipPICT, instance: 0x542, uid + header + quicktime)))
        #expect(pict.data.count == 512 + quicktime.count && pict.data.prefix(512).allSatisfy { $0 == 0 })
        #expect(Pictures.jpeg(inPICT: pict.data) == jpeg)
        #expect(Pictures.jpeg(inPICT: [UInt8](repeating: 0, count: 600)) == nil)

        // A DIB becomes a .bmp whose bits start after its header and colour table.
        var dib = [UInt8](repeating: 0, count: 40 + 8 + 4)
        dib[0] = 40; dib[4] = 1; dib[8] = 1; dib[12] = 1; dib[14] = 1   // 1×1, 1 bit: two palette entries
        let bmp = try #require(Pictures.bmp(dib))
        #expect(Array(bmp.prefix(2)) == [0x42, 0x4D] && bmp[10] == 14 + 40 + 8 && bmp.count == dib.count + 14)

        // Damage: a header and nothing else, a metafile shorter than its header, a stored length past the end, a
        // deflated stream that isn't one, an unknown type.
        #expect(Pictures.file(record(RT.blipPNG, instance: 0x6E0, [])) == nil)
        #expect(Pictures.file(record(RT.blipEMF, instance: 0x3D4, uid + [1, 2, 3])) == nil)
        header[32] = 0
        withUnsafeBytes(of: UInt32.max.littleEndian) { header.replaceSubrange(28 ..< 32, with: $0) }
        #expect(Pictures.file(record(RT.blipEMF, instance: 0x3D4, uid + header + [1, 2, 3, 4])) == nil)
        #expect(Pictures.file(record(0xF0FF, instance: 0, uid + [0, 1])) == nil)
        #expect(Pictures.bmp([1, 2, 3]) == nil)
        var odd = dib
        odd[20] = 0xFF; odd[21] = 0xFF; odd[22] = 0xFF; odd[23] = 0x7F   // an image size past the file
        odd[32] = 0xFF; odd[33] = 0xFF; odd[34] = 0xFF; odd[35] = 0xFF   // and a colour count past any table
        #expect(Pictures.bmp(odd).map { Int(le32($0, 10)) <= $0.count } == true)

        // A BLIP store index outside the store, and an empty store.
        let none = Pictures(entries: [.none, .stream(1 << 40), .inline(0 ..< 4)], doc: [1, 2, 3, 4], file: nil)
        for pib: UInt32 in [0, 1, 2, 3, 4, .max] { #expect(none.blip(pib) == nil) }
    }

    /// Hostile external objects and comments: short atoms and junk give nothing, never a trap.
    @Test func hostileObjectsAndCommentsAreBounded() throws {
        func record(_ type: UInt16, instance: UInt16 = 0, version: UInt8 = 0, _ body: [UInt8]) -> [UInt8] {
            let vi = instance << 4 | UInt16(version)
            let n = UInt32(body.count)
            return [UInt8(vi & 0xFF), UInt8(vi >> 8), UInt8(type & 0xFF), UInt8(type >> 8),
                    UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + body
        }
        // An object list with a short OLE atom, a movie with no path, and a sound collection with a short sound.
        let list = record(RT.externalObjectList, version: 0xF,
                          record(RT.exOleEmbed, version: 0xF, record(RT.exOleObjAtom, [1, 2, 3]))
                          + record(RT.exMciMovie, version: 0xF, record(RT.exVideo, version: 0xF, record(RT.exMediaAtom, [5, 0, 0, 0, 1, 0, 0, 0]))))
        let sounds = record(RT.soundCollection, version: 0xF, record(RT.sound, version: 0xF, record(RT.cString, instance: 2, [0x31, 0])))
        let b = list + sounds
        let doc = [Record(b, at: 0), Record(b, at: list.count)].compactMap { $0 }
        var objects = ExObjects.read(b, doc)
        #expect(objects.objects.isEmpty && objects.sounds.isEmpty)
        var p = Presentation.default
        #expect(objects.media(5, &p) == nil && p.media.isEmpty)

        // A comment with a date of nonsense and a short atom.
        let comment = record(RT.comment10, version: 0xF, record(RT.cString, [0x41, 0]) + record(RT.comment10Atom, [UInt8](repeating: 0xFF, count: 28)))
        let short = record(RT.comment10, version: 0xF, record(RT.comment10Atom, [1, 2]))
        let slide = record(RT.slide, version: 0xF, record(RT.progTags, version: 0xF, record(RT.progBinaryTag, version: 0xF,
                           record(RT.binaryTagDataBlob, comment + short))))
        let list2 = Document.comments(slide, try #require(Record(slide, at: 0)))
        #expect(list2.count == 2 && list2[0].author == "A" && list2[0].date.isEmpty)

        // Paths become file URLs.
        #expect(ExObjects.url("C:\\Movies\\a b#1.avi") == "file:///C:/Movies/a%20b%231.avi")
        #expect(ExObjects.url("\\\\server\\share\\x.wav") == "file://server/share/x.wav")
        #expect(ExObjects.fileName("C:\\Movies\\clip.mpg") == "clip.mpg")
    }
}
