// DCPPT — P6: structure-aware fuzzing of every record reader. Each `.ppt` fixture (and PowerPoint's own files,
// decrypted into the local cache's `plain/` folder, when present) is a seed. Each round damages its streams where
// the readers look: a record's length, type, container flag or instance; boundary integers in an atom's data; one
// record copied over another; a record repeated; the stream cut short; the Current User pointing elsewhere; and the
// same for the Pictures stream's BLIP records. The result is imported, written back out as `.pptx`, its slide show
// evaluated and (every few rounds) its first slide drawn. Anything may fail; nothing may trap, and nothing may take
// much longer than the undamaged seed.
//
// DCPPT_FUZZ_ROUNDS sets the rounds per seed (default 12); DCPPT_FUZZ_DIR keeps every tenth damaged file there (for
// Tools/legacy/crash-run.sh to open and render through dccli) and `current.ppt`, the input being read, which is what
// a trap leaves behind to reproduce it.
import DCAnim
import DCCFB
import DCEngine
import DCModel
import DCPPTX
import DCRender
import Foundation
import Testing
@testable import DCPPT

@Suite struct FuzzTests {
    struct Seed {
        let name: String
        let user: [UInt8]
        let document: [UInt8]
        let pictures: [UInt8]
    }

    /// A small deterministic generator (Knuth's LCG), so a failing round can be replayed.
    struct Rng {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        mutating func below(_ n: Int) -> Int { n > 0 ? next() % n : 0 }
        mutating func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[below(a.count)] }
    }

    /// A record header in a stream: where it is, whether it's a container, and its declared length.
    struct Header { let at: Int; let container: Bool; let length: Int }

    static var plainPowerPoint: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected/plain")
    }

    static func seeds() throws -> [Seed] {
        var files = PPTFileTests.manifest().filter { $0.kind == "ppt" }.map { PPTFileTests.legacy.appending(path: $0.file) }
        let local = (try? FileManager.default.contentsOfDirectory(atPath: plainPowerPoint.path)) ?? []
        files += local.filter { $0.hasSuffix(".ppt") }.sorted().map { plainPowerPoint.appending(path: $0) }
        var seen = Set<[UInt8]>()
        var out: [Seed] = []
        for f in files {
            let cfb = try CompoundFile(Array(try Data(contentsOf: f)))
            let s = try PPTFile.streams(cfb)
            guard seen.insert(s.document).inserted else { continue }
            out.append(Seed(name: f.deletingPathExtension().lastPathComponent, user: s.user, document: s.document, pictures: s.pictures))
        }
        return out
    }

    /// Every record header in `b`: the top-level records in sequence and, depth-bounded, each container's children.
    static func headers(_ b: [UInt8]) -> [Header] {
        var out: [Header] = []
        func visit(_ r: Record, _ depth: Int) {
            let at = r.body.lowerBound - 8
            out.append(Header(at: at, container: r.isContainer, length: Int(le32(b, at + 4))))
            guard r.isContainer, depth < 32 else { return }
            for c in r.children(b) { visit(c, depth + 1) }
        }
        var p = 0
        while let r = Record(b, at: p) {
            visit(r, 0)
            guard r.body.upperBound > p else { break }
            p = r.body.upperBound
        }
        return out
    }

    static func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
        guard at >= 0, at + 4 <= b.count else { return }
        for i in 0 ..< 4 { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    static let boundaries: [UInt32] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF]

    /// One piece of damage to `b`, aimed at the records `hs` found in it before any damage.
    static func damage(_ b: inout [UInt8], _ hs: [Header], _ types: [UInt16], _ rng: inout Rng) {
        guard !b.isEmpty, let h = rng.pick(hs) else { return }
        switch rng.below(9) {
        case 0, 1: // the length
            let lengths = [0, 1, 7, 8, h.length - 1, h.length + 1, h.length * 2, b.count - h.at, rng.below(1 << 20)]
            let v = rng.below(4) == 0 ? rng.pick(boundaries) ?? 0 : UInt32(truncatingIfNeeded: lengths[rng.below(lengths.count)])
            put32(&b, h.at + 4, v)
        case 2: // the type, another one the file uses
            let t = rng.pick(types) ?? 0
            if h.at + 4 <= b.count { b[h.at + 2] = UInt8(t & 0xFF); b[h.at + 3] = UInt8(t >> 8) }
        case 3: // the container flag, or the instance
            guard h.at + 2 <= b.count else { return }
            if rng.below(2) == 0 { b[h.at] = h.container ? b[h.at] & 0xF0 : b[h.at] | 0x0F } else { b[h.at] = b[h.at] & 0x0F | UInt8(rng.below(16) << 4); b[h.at + 1] = UInt8(rng.below(256)) }
        case 4, 5: // a boundary integer in the data, at an aligned offset
            guard h.length > 0 else { return }
            let width = [1, 2, 4][rng.below(3)]
            let at = h.at + 8 + rng.below(max(1, min(h.length, 256) / width)) * width
            let v = rng.pick(boundaries) ?? 0
            for i in 0 ..< width where at + i < b.count { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
        case 6: // another record copied over this one
            guard let o = rng.pick(hs), o.at != h.at else { return }
            let n = min(8 + max(0, o.length), b.count - o.at, b.count - h.at, 1 << 16)
            guard n > 0 else { return }
            b.replaceSubrange(h.at ..< h.at + n, with: b[o.at ..< o.at + n])
        case 7: // this record repeated
            let n = min(8 + max(0, h.length), b.count - h.at, 1 << 16)
            guard n > 0 else { return }
            b.insert(contentsOf: b[h.at ..< h.at + n], at: h.at)
        default: // random bytes in the data, or the stream cut short
            if rng.below(3) == 0 { b.removeLast(rng.below(b.count)); return }
            for _ in 0 ... rng.below(16) {
                let at = h.at + 8 + rng.below(max(1, h.length))
                if at < b.count { b[at] = UInt8(rng.below(256)) }
            }
        }
    }

    /// Imports `bytes`, writes the result as `.pptx`, evaluates every slide's animations and, with `draw`, renders
    /// the first slide. Errors are fine.
    static func exercise(_ bytes: [UInt8], draw: Bool) {
        guard let (p, _) = try? PPT.importChecked(bytes, hooks: LegacyPictures.hooks) else { return }
        _ = try? PPTX.export(p)
        for (i, s) in p.slides.enumerated() where !s.animations.isEmpty {
            let tl = Timeline(s, p.slideSize.width, p.slideSize.height)
            let steps = min(ShowState.steps(p, i), 64)
            for a in s.animations.prefix(64) {
                for step in 0 ... steps { for t in [0.0, 0.5, 1.0] { _ = tl.state(a.shape, a.paragraph.map(Int.init), step, t) } }
            }
        }
        if draw, !p.slides.isEmpty {
            var o = RenderOpts()
            o.scale = 0.1
            _ = renderSlide(p, 0, o)
        }
    }

    static func file(_ s: Seed, user: [UInt8], document: [UInt8], pictures: [UInt8]) throws -> [UInt8] {
        var w = CompoundFileWriter()
        try w.addStream("Current User", user)
        try w.addStream("PowerPoint Document", document)
        if !pictures.isEmpty { try w.addStream("Pictures", pictures) }
        return try w.bytes()
    }

    @Test func damagedRecordsNeverTrapOrHang() throws {
        let env = ProcessInfo.processInfo.environment
        let rounds = Int(env["DCPPT_FUZZ_ROUNDS"] ?? "") ?? 12
        let keep = env["DCPPT_FUZZ_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        if let keep { try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true) }
        let seeds = try Self.seeds()
        try #require(seeds.count >= 60, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        let clock = ContinuousClock()
        var slow: [String] = []
        var total = 0
        for (k, seed) in seeds.enumerated() {
            let docHeaders = Self.headers(seed.document), picHeaders = Self.headers(seed.pictures)
            let types = Array(Set(docHeaders.map { le16(seed.document, $0.at + 2) })).sorted()
            let picTypes = Array(Set(picHeaders.map { le16(seed.pictures, $0.at + 2) })).sorted()
            let base = clock.measure { Self.exercise((try? Self.file(seed, user: seed.user, document: seed.document, pictures: seed.pictures)) ?? [], draw: true) }
            let limit = max(.seconds(5), base * 20)
            var rng = Rng(state: UInt64(2026_1031 + k))
            for round in 0 ..< rounds {
                var doc = seed.document, pics = seed.pictures, user = seed.user
                for _ in 0 ... rng.below(3) {
                    switch rng.below(10) {
                    case 0: Self.damage(&pics, picHeaders, picTypes, &rng)
                    case 1: if let h = rng.pick(docHeaders) { Self.put32(&user, 16, UInt32(truncatingIfNeeded: rng.below(3) == 0 ? rng.next() : h.at)) }
                    default: Self.damage(&doc, docHeaders, types, &rng)
                    }
                }
                let bytes = try Self.file(seed, user: user, document: doc, pictures: pics)
                if let keep {
                    try Data(bytes).write(to: keep.appending(path: "current.ppt"))
                    if round % 10 == 0 { try Data(bytes).write(to: keep.appending(path: "\(seed.name)-\(round).ppt")) }
                }
                let took = clock.measure { Self.exercise(bytes, draw: round % 4 == 0) }
                if took > limit { slow.append("\(seed.name) round \(round): \(took), undamaged \(base)") }
                total += 1
            }
        }
        #expect(slow.isEmpty, "\(slow.joined(separator: "\n"))")
        #expect(total == seeds.count * rounds)
    }

    // MARK: Amplification: a small file naming the same work many times

    /// `bytes` inserted into `object` at `at`, each container in `path` (header offsets, outermost first) grown to
    /// hold them.
    static func insert(_ bytes: [UInt8], into object: [UInt8], at: Int, path: [Int]) -> [UInt8] {
        var o = object
        o.insert(contentsOf: bytes, at: at)
        for h in path { put32(&o, h + 4, le32(o, h + 4) + UInt32(bytes.count)) }
        return o
    }

    /// `file` with an incremental save that replaces persist object `ref` with `object`.
    static func saved(_ file: [UInt8], replacing ref: UInt32, with object: [UInt8]) throws -> [UInt8] {
        let s = try PPTFile.streams(try CompoundFile(file))
        var stream = PPTFileTests.Stream()
        stream.bytes = s.document
        let at = stream.bytes.count
        stream.bytes += object
        let e = stream.edit([ref: at], last: Int(le32(s.user, 16)))
        var w = CompoundFileWriter()
        try w.addStream("Current User", stream.currentUser(e))
        try w.addStream("PowerPoint Document", stream.bytes)
        if !s.pictures.isEmpty { try w.addStream("Pictures", s.pictures) }
        return try w.bytes()
    }

    static func presets() throws -> (bytes: [UInt8], file: PPTFile) {
        let bytes = Array(try Data(contentsOf: PPTFileTests.legacy.appending(path: "ppt/presets.ppt")))
        return (bytes, try PPTFile(bytes))
    }

    /// A slide list naming one slide object again: the repeat is blank and reported, so a few bytes per entry can't
    /// multiply a heavy slide's work; past `PPT.maxSlides` entries the rest are counted, not read.
    @Test func aSlideObjectIsReadOnce() throws {
        let (bytes, file) = try Self.presets()
        let (original, _) = try PPT.importChecked(bytes)
        let doc = try #require(file.object(file.documentRef))
        let root = try #require(Record(doc, at: 0))
        let list = try #require(root.children(doc).first { $0.type == RT.slideListWithText && $0.instance == 0 })
        let atom = try #require(list.children(doc).first { $0.type == RT.slidePersistAtom })
        let entry = Array(doc[atom.body.lowerBound - 8 ..< atom.body.upperBound])
        for extra in [400, PPT.maxSlides + 1000] {
            let more = Array([[UInt8]](repeating: entry, count: extra).joined())
            let grown = Self.insert(more, into: doc, at: list.body.upperBound, path: [0, list.body.lowerBound - 8])
            let file = try Self.saved(bytes, replacing: file.documentRef, with: grown)
            let (p, report) = try PPT.importChecked(file)
            let kept = min(original.slides.count + extra, PPT.maxSlides)
            #expect(p.slides.count == kept)
            #expect(report.slides == original.slides.count + extra)
            #expect(report.slidesLeftOut == original.slides.count + extra - kept)
            #expect(report.unreadSlides.count == kept - original.slides.count)
            #expect(p.slides.reduce(0) { $0 + $1.shapes.count } == original.slides.reduce(0) { $0 + $1.shapes.count })
        }
    }

    /// A drawing of more than `Drawing.maxShapes` shapes is cut there.
    @Test func aDrawingIsBounded() throws {
        let (bytes, file) = try Self.presets()
        let doc = try #require(file.object(file.documentRef))
        let root = try #require(Record(doc, at: 0))
        let list = try #require(root.children(doc).first { $0.type == RT.slideListWithText && $0.instance == 0 })
        let ref = le32(doc, try #require(list.children(doc).first { $0.type == RT.slidePersistAtom }).body.lowerBound)
        let slide = try #require(file.object(ref))
        let r = try #require(Record(slide, at: 0))
        let drawing = try #require(r.children(slide).first { $0.type == RT.drawing })
        let dg = try #require(drawing.children(slide).first { $0.type == RT.dgContainer })
        let group = try #require(dg.children(slide).first { $0.type == RT.spgrContainer })
        let shape = try #require(group.children(slide).dropFirst().first { $0.type == RT.spContainer })
        let copy = Array(slide[shape.body.lowerBound - 8 ..< shape.body.upperBound])
        let more = Array([[UInt8]](repeating: copy, count: 25_000).joined())
        let path = [0, drawing.body.lowerBound - 8, dg.body.lowerBound - 8, group.body.lowerBound - 8]
        let grown = Self.insert(more, into: slide, at: group.body.upperBound, path: path)
        let clock = ContinuousClock()
        var p = Presentation.default
        let took = try clock.measure { p = try PPT.importChecked(try Self.saved(bytes, replacing: ref, with: grown)).0 }
        #expect(p.slides[0].shapes.count == Drawing.maxShapes)
        #expect(took < .seconds(60), "\(took)")
    }

    /// Placeholders naming the same outline text: the first shows it, as PowerPoint writes them (one placeholder per
    /// text), rather than each taking a copy. No fixture has outline text (LibreOffice and PowerPoint 16 keep text
    /// in the shape), so the slide is built by hand.
    @Test func outlineTextHasOneOwner() throws {
        typealias S = PPTFileTests.Stream
        func rec(_ type: UInt16, _ instance: UInt16 = 0, _ ver: UInt16 = 0, _ body: [UInt8]) -> [UInt8] { S.header(ver, instance, type, body.count) + body }
        let patriarch = rec(RT.spContainer, 0, 0xF, rec(RT.fspgr, 0, 1, [UInt8](repeating: 0, count: 16)) + rec(RT.fsp, 0, 2, le32(1024) + le32(0x5)))
        var shapes: [UInt8] = []
        for i in 0 ..< 3 {
            let top = UInt16(100 * i)
            let anchor: [UInt8] = le16(top) + le16(100) + le16(400) + le16(top + 80)
            var sp = rec(RT.fsp, 1, 2, le32(1025 + UInt32(i)) + le32(0xA00))
            sp += rec(RT.clientAnchor, 0, 0, anchor)
            sp += rec(RT.clientTextbox, 0, 0xF, rec(RT.outlineTextRefAtom, 0, 0, le32(0)))
            shapes += rec(RT.spContainer, 0, 0xF, sp)
        }
        let drawing = rec(RT.drawing, 0, 0xF, rec(RT.dgContainer, 0, 0xF, rec(0xF008, 1, 0, le32(4) + le32(1028)) + rec(RT.spgrContainer, 0, 0xF, patriarch + shapes)))
        var s = S()
        let slide = s.bytes.count
        s.bytes += rec(RT.slide, 0, 0xF, drawing)
        let text = Array("Outline".utf16).flatMap { le16($0) }
        let doc = s.document(size: (5760, 4320), slides: [2], outline: rec(RT.textHeaderAtom, 0, 0, le32(1)) + rec(RT.textCharsAtom, 0, 0, text))
        let e = s.edit([1: doc, 2: slide], last: 0)
        let (p, _) = try PPT.importChecked(try s.file(currentEdit: e))
        let shown = p.slides[0].shapes.map { $0.text?.paragraphs.flatMap { $0.runs.map(\.text) }.joined() ?? "" }
        #expect(shown == ["Outline", "", ""])
    }

    /// PICT pictures, which AppKit's NSPICTImageRep draws (DCEngine's hook): damage to the header, the frame and the
    /// opcodes (big-endian words) never traps, and drawing stays bounded.
    @Test func damagedPICTsNeverTrap() throws {
        var picts: [[UInt8]] = []
        for seed in try Self.seeds() {
            var w = CompoundFileWriter()
            try w.addStream("Current User", seed.user)
            try w.addStream("PowerPoint Document", seed.document)
            if !seed.pictures.isEmpty { try w.addStream("Pictures", seed.pictures) }
            let file = try PPTFile(try w.bytes())
            guard let doc = file.object(file.documentRef), let root = Record(doc, at: 0) else { continue }
            let pictures = Pictures.read(file, doc, root.children(doc))
            for pib in 1 ... UInt32(max(1, pictures.entries.count)) {
                if let b = pictures.blip(pib), b.contentType == "image/pict", !picts.contains(b.data) { picts.append(b.data) }
            }
        }
        // The fixtures' producers don't write PICT (only old PowerPoint for Mac did), so hand-built ones are added.
        picts += Self.handBuiltPICTs()
        let pict = try #require(LegacyPictures.hooks.pict)
        for p in Self.handBuiltPICTs() { #expect(pict(p) != nil, "AppKit draws the undamaged PICT") }
        let clock = ContinuousClock()
        var rng = Rng(state: 2026_1031)
        var slow: [String] = []
        let rounds = 150 * max(1, (Int(ProcessInfo.processInfo.environment["DCPPT_FUZZ_ROUNDS"] ?? "") ?? 12) / 12)
        for (k, original) in picts.enumerated() {
            for round in 0 ..< rounds {
                var b = original
                for _ in 0 ... rng.below(4) {
                    // Most damage lands in the frame and the first opcodes, after the 512-byte header.
                    let at = rng.below(4) == 0 ? rng.below(b.count) : min(b.count - 1, 512 + rng.below(256))
                    if rng.below(2) == 0 { b[at] = UInt8(rng.below(256)) } else if at + 1 < b.count {
                        let v = UInt16(truncatingIfNeeded: rng.pick(Self.boundaries) ?? 0)
                        b[at & ~1] = UInt8(v >> 8)
                        if at & ~1 + 1 < b.count { b[at & ~1 + 1] = UInt8(v & 0xFF) }
                    }
                }
                if rng.below(8) == 0 { b.removeLast(rng.below(b.count)) }
                let took = clock.measure {
                    _ = Pictures.jpeg(inPICT: b)
                    _ = pict(b)
                }
                if took > .seconds(5) { slow.append("PICT \(k) round \(round): \(took)") }
            }
        }
        #expect(slow.isEmpty, "\(slow.joined(separator: "\n"))")
    }

    /// Version 2 PICTs, written opcode by opcode (Inside Macintosh: Imaging With QuickDraw, appendix A): a clip
    /// region, colours, rectangles, lines and a polygon; and an 8-bit indexed PackBitsRect.
    static func handBuiltPICTs() -> [[UInt8]] {
        func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v) }
        func rect(_ t: Int, _ l: Int, _ b: Int, _ r: Int) -> [UInt8] { be16(t) + be16(l) + be16(b) + be16(r) }
        func pict(_ ops: [UInt8]) -> [UInt8] {
            let frame = rect(0, 0, 64, 96)
            var body = be16(0) + frame
            body += be16(0x0011) + be16(0x02FF)
            body += be16(0x0C00) + be16(-2) + be16(0) + be32(72 << 16) + be32(72 << 16) + frame + be32(0)
            body += be16(0x0001) + be16(10) + frame
            body += ops + be16(0x00FF)
            return [UInt8](repeating: 0, count: 512) + body
        }
        let shapes = pict(be16(0x001A) + be16(0xFFFF) + be16(0) + be16(0)
            + be16(0x0031) + rect(4, 4, 40, 60)
            + be16(0x001A) + be16(0) + be16(0) + be16(0xFFFF)
            + be16(0x0030) + rect(10, 10, 50, 90)
            + be16(0x0007) + be16(3) + be16(3)
            + be16(0x0020) + be16(0) + be16(0) + be16(63) + be16(95)
            + be16(0x0070) + be16(10 + 3 * 4) + rect(20, 20, 60, 80) + be16(20) + be16(20) + be16(60) + be16(50) + be16(20) + be16(80))
        // 4×4 pixels, 8 bits each from a 2-colour table; rows under 8 bytes are stored unpacked.
        var bitmap = be16(0x0098) + be16(0x8000 | 4) + rect(0, 0, 4, 4)
        bitmap += be16(0) + be16(0) + be32(0) + be32(72 << 16) + be32(72 << 16) + be16(0) + be16(8) + be16(1) + be16(8) + be32(0) + be32(0) + be32(0)
        bitmap += be32(0) + be16(0) + be16(1) + be16(0) + be16(0xFFFF) + be16(0) + be16(0) + be16(1) + be16(0) + be16(0) + be16(0xFFFF)
        bitmap += rect(0, 0, 4, 4) + rect(0, 0, 64, 96) + be16(0)
        bitmap += [0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0]
        return [shapes, pict(bitmap)]
    }

    /// Encrypted files: damage to the CryptSession10Container's encryption header and to the encrypted records.
    @Test func damagedEncryptedFilesNeverTrap() throws {
        let files = PPTFileTests.manifest().filter { $0.kind == "encrypted-ppt" }
        try #require(!files.isEmpty, "no encrypted .ppt fixtures")
        var rng = Rng(state: 2026_1031)
        for f in files {
            let bytes = Array(try Data(contentsOf: PPTFileTests.legacy.appending(path: f.file)))
            let ppt = try PPTFile(bytes, password: f.password)
            let s = try PPTFile.streams(try CompoundFile(bytes))
            guard let ref = ppt.cryptSessionRef, let at = ppt.directory[ref], let session = Record(s.document, at: at) else { continue }
            for _ in 0 ..< 40 {
                var doc = s.document
                for _ in 0 ... rng.below(3) {
                    let range = rng.below(3) == 0 ? 0 ..< doc.count : session.body
                    guard !range.isEmpty else { continue }
                    let i = range.lowerBound + rng.below(range.count)
                    if rng.below(2) == 0 { doc[i] = UInt8(rng.below(256)) } else { Self.put32(&doc, i & ~3, rng.pick(Self.boundaries) ?? 0) }
                }
                var w = CompoundFileWriter()
                try w.addStream("Current User", s.user)
                try w.addStream("PowerPoint Document", doc)
                if !s.pictures.isEmpty { try w.addStream("Pictures", s.pictures) }
                let b = try w.bytes()
                _ = try? PPT.importChecked(b, password: f.password)
                _ = try? PPT.importChecked(b)
            }
        }
    }
}
