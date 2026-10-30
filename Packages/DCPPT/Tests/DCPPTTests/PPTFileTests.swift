// DCPPT — the container (P1): every `.ppt` in the legacy fixtures opens with the slide count and slide size Apache
// POI reads; encrypted ones open with their password (and PowerPoint's default one without asking); PowerPoint's own
// files (local only) open; hand-built streams exercise incremental saves, which no generated file has; and damaged
// input never traps or hangs.
import DCCFB
import DCGeometry
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCPPT

@Suite struct PPTFileTests {
    static var legacy: URL { Fixtures.root.appending(path: "legacy", directoryHint: .isDirectory) }

    struct Manifest: Decodable {
        struct File: Decodable { let file: String; let kind: String?; let password: String? }
        let files: [File]
    }

    struct POIDump: Decodable {
        struct Slide: Decodable { let index: Int }
        let width: Int
        let height: Int
        let slides: [Slide]
    }

    static func manifest() -> [Manifest.File] {
        guard let d = try? Data(contentsOf: legacy.appending(path: "manifest.json")) else { return [] }
        return (try? JSONDecoder().decode(Manifest.self, from: d).files) ?? []
    }

    @Test func everyPPTFixtureOpensWithPOIsSlidesAndSize() throws {
        let files = Self.manifest().filter { $0.kind == "ppt" || $0.kind == "encrypted-ppt" }
        try #require(files.count >= 60, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        for f in files {
            let name = URL(filePath: f.file).lastPathComponent
            let bytes = Array(try Data(contentsOf: Self.legacy.appending(path: f.file)))
            #expect(PPT.sniff(bytes), "\(name)")
            let ref = try JSONDecoder().decode(POIDump.self, from: Data(contentsOf: Self.legacy.appending(path: "reference/\(name).poi.json")))
            let (p, report) = try PPT.importChecked(bytes, password: f.kind == "encrypted-ppt" ? f.password : nil)
            #expect(p.slides.count == ref.slides.count, "\(name)")
            #expect(report.unreadSlides.isEmpty, "\(name)")
            #expect(report.encrypted == (f.kind == "encrypted-ppt"), "\(name)")
            #expect(p.slideSize.width.rounded() == Double(ref.width) && p.slideSize.height.rounded() == Double(ref.height), "\(name)")
        }
    }

    /// P2a: each slide's text, shape by shape in z-order, is what POI reads (paragraph marks and line breaks both as
    /// newlines; empty shapes left out on both sides), and each text shape sits where POI puts it.
    @Test func everySlidesTextIsWhatPOIReads() throws {
        struct Dump: Decodable {
            struct Shape: Decodable {
                let text: String?
                let x: Double, y: Double, w: Double, h: Double
                let children: [Shape]?
            }
            struct Slide: Decodable { let shapes: [Shape]; let notes: String }
            let slides: [Slide]
        }
        func flat(_ shapes: [Dump.Shape]) -> [Dump.Shape] { shapes.flatMap { s in s.children.map(flat) ?? [s] } }
        func norm(_ t: String) -> String {
            t.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func ours(_ body: TextBody?) -> String {
            norm((body?.paragraphs ?? []).map { p in p.runs.map { $0.kind == .break ? "\n" : $0.text }.joined() }.joined(separator: "\n"))
        }
        // The fixtures, and PowerPoint 16's own `.ppt` files when the local set is here (Tools/legacy/powerpoint-protect.sh;
        // POI's reading of them is kept beside them, as `.poi.json`).
        var cases: [(name: String, file: URL, ref: URL, password: String?)] = Self.manifest()
            .filter { $0.kind == "ppt" || $0.kind == "encrypted-ppt" }
            .map { f in
                let name = URL(filePath: f.file).lastPathComponent
                return (name, Self.legacy.appending(path: f.file), Self.legacy.appending(path: "reference/\(name).poi.json"),
                        f.kind == "encrypted-ppt" ? f.password : nil)
            }
        try #require(cases.count >= 60, "no legacy fixtures")
        let local = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        struct Meta: Decodable { let password: String }
        for n in (try? FileManager.default.contentsOfDirectory(atPath: local.path))?.filter({ $0.hasSuffix(".ppt.poi.json") }) ?? [] {
            let name = String(n.dropLast(".poi.json".count))
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: local.appending(path: "\(name).meta.json")))
            cases.append((name, local.appending(path: name), local.appending(path: n), meta.password))
        }
        var mismatches = 0
        for c in cases {
            let name = c.name
            let ref = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: c.ref))
            let (p, _) = try PPT.importChecked(Array(try Data(contentsOf: c.file)), password: c.password)
            for (i, (slide, theirs)) in zip(p.slides, ref.slides).enumerated() {
                let want = flat(theirs.shapes).filter { !norm($0.text ?? "").isEmpty }
                let got = slide.shapes.filter { !ours($0.text).isEmpty }
                let wt = want.map { norm($0.text ?? "") }, gt = got.map { ours($0.text) }
                if wt != gt {
                    mismatches += 1
                    Issue.record("\(name) slide \(i + 1) text:\n  POI:  \(wt)\n  ours: \(gt)")
                    continue
                }
                for (w, g) in zip(want, got) {
                    guard let x = g.xfrm else { continue }
                    let close = abs(x.x - w.x) < 0.6 && abs(x.y - w.y) < 0.6 && abs(x.w - w.w) < 0.6 && abs(x.h - w.h) < 0.6
                    if !close { Issue.record("\(name) slide \(i + 1) “\(w.text?.prefix(20) ?? "")”: POI \(w.x),\(w.y) \(w.w)×\(w.h), ours \(x.x),\(x.y) \(x.w)×\(x.h)") }
                }
                #expect(ours(slide.notes) == norm(theirs.notes), "\(name) slide \(i + 1) notes")
            }
        }
        #expect(mismatches == 0)
    }

    @Test func encryptedFilesNeedTheirPassword() throws {
        let f = try #require(Self.manifest().first { $0.file == "encrypted/corpus-sample.poi-rc4cryptoapi.ppt" }, "no legacy fixtures")
        let bytes = Array(try Data(contentsOf: Self.legacy.appending(path: f.file)))
        #expect(throws: PPTError.passwordRequired) { try PPT.importChecked(bytes) }
        #expect(throws: PPTError.wrongPassword) { try PPT.importChecked(bytes, password: "not it") }
        #expect(try PPT.importChecked(bytes, password: f.password).1.slides == 8)
    }

    /// PowerPoint 2003–2007 SP1 encrypted with a fixed default password when the user gave none: such a file opens
    /// without asking.
    @Test func theDefaultPasswordIsTriedFirst() throws {
        let url = Self.legacy.appending(path: "encrypted/corpus-sample.poi-rc4cryptoapi-default.ppt")
        guard let data = try? Data(contentsOf: url) else { return }
        let file = try PPTFile(Array(data))
        #expect(file.isEncrypted && file.usedDefaultPassword)
        #expect(try PPT.importChecked(Array(data)).0.slides.count == 8)
    }

    /// PowerPoint 16's own `.ppt` files with a password (Tools/legacy/powerpoint-protect.sh, kept local).
    @Test func powerPointsEncryptedFilesOpen() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".ppt") } ?? []
        guard !names.isEmpty else { return }
        struct Meta: Decodable { let password: String; let from: String }
        let counts = ["corpus-sample": 8, "corpus-content": 5, "corpus-charts": 6]
        for n in names {
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appending(path: "\(n).meta.json")))
            let bytes = Array(try Data(contentsOf: dir.appending(path: n)))
            #expect(throws: PPTError.passwordRequired) { try PPT.importChecked(bytes) }
            let (p, report) = try PPT.importChecked(bytes, password: meta.password)
            let deck = URL(filePath: meta.from).deletingPathExtension().lastPathComponent
            #expect(p.slides.count == counts[deck], "\(n)")
            #expect(report.encrypted && report.unreadSlides.isEmpty, "\(n)")
        }
    }

    // MARK: Hand-built streams

    /// A `PowerPoint Document` stream built record by record.
    struct Stream {
        var bytes: [UInt8] = []

        static func header(_ ver: UInt16, _ inst: UInt16, _ type: UInt16, _ len: Int) -> [UInt8] {
            le16(ver | inst << 4) + le16(type) + le32(UInt32(len))
        }

        /// A DocumentContainer with a DocumentAtom and a slide list of `slides` persist refs; returns its offset.
        mutating func document(size: (Int32, Int32), slides: [UInt32]) -> Int {
            var atom = Self.header(1, 0, RT.documentAtom, 40)
            atom += le32(UInt32(bitPattern: size.0)) + le32(UInt32(bitPattern: size.1)) + le32(5760) + le32(7680)
            atom += [UInt8](repeating: 0, count: 24)
            var list: [UInt8] = []
            for (i, s) in slides.enumerated() {
                list += Self.header(0, 0, RT.slidePersistAtom, 20) + le32(s) + le32(0) + le32(0) + le32(UInt32(256 + i)) + le32(0)
            }
            let slideList = Self.header(0xF, 0, RT.slideListWithText, list.count) + list
            let body = atom + slideList
            let at = bytes.count
            bytes += Self.header(0xF, 0, RT.document, body.count) + body
            return at
        }

        mutating func slide() -> Int {
            let at = bytes.count
            bytes += Self.header(0xF, 0, RT.slide, 0)
            return at
        }

        /// A persist directory and the UserEditAtom after it; returns the edit's offset.
        mutating func edit(_ entries: [UInt32: Int], last: Int) -> Int {
            var dir: [UInt8] = []
            for (id, off) in entries.sorted(by: { $0.key < $1.key }) { dir += le32(id | 1 << 20) + le32(UInt32(off)) }
            let dirAt = bytes.count
            bytes += Self.header(0, 0, RT.persistDirectoryAtom, dir.count) + dir
            let at = bytes.count
            bytes += Self.header(0, 0, RT.userEditAtom, 0x1C) + le32(0) + le32(0x0300_0000) + le32(UInt32(last))
                + le32(UInt32(dirAt)) + le32(1) + le32(100) + le32(1)
            return at
        }

        func currentUser(_ edit: Int) -> [UInt8] {
            Self.header(0, 0, RT.currentUserAtom, 20) + le32(20) + le32(0xE391_C05F) + le32(UInt32(edit)) + le16(0) + le16(0x03F4) + [3, 0, 0, 0]
        }

        func file(currentEdit: Int) throws -> [UInt8] {
            var w = CompoundFileWriter()
            try w.addStream("Current User", currentUser(currentEdit))
            try w.addStream("PowerPoint Document", bytes)
            return try w.bytes()
        }
    }

    /// An incremental save: the second edit's directory replaces the document, and its slide list wins; the first
    /// document is dead.
    @Test func theNewestEditWins() throws {
        var s = Stream()
        let a = s.slide(), b = s.slide()
        let doc1 = s.document(size: (5760, 4320), slides: [2])
        let e1 = s.edit([1: doc1, 2: a], last: 0)
        let c = s.slide()
        let doc2 = s.document(size: (7680, 4320), slides: [2, 3, 4])
        let e2 = s.edit([1: doc2, 3: b, 4: c], last: e1)
        let (p, report) = try PPT.importChecked(try s.file(currentEdit: e2))
        #expect(report.edits == 2)
        #expect(p.slides.count == 3)
        #expect(report.unreadSlides.isEmpty)
        #expect(p.slideSize == Size(960, 540))
        // Pointing Current User at the first edit gives the first save.
        #expect(try PPT.importChecked(try s.file(currentEdit: e1)).0.slides.count == 1)
    }

    @Test func aSlideTheDirectoryLacksIsReported() throws {
        var s = Stream()
        let a = s.slide()
        let doc = s.document(size: (5760, 4320), slides: [2, 9])
        let e = s.edit([1: doc, 2: a], last: 0)
        let (p, report) = try PPT.importChecked(try s.file(currentEdit: e))
        #expect(p.slides.count == 2)
        #expect(report.unreadSlides == [2])
    }

    /// A chain that points forwards or at itself ends; it never loops.
    @Test func aBrokenEditChainEnds() throws {
        var s = Stream()
        let doc = s.document(size: (5760, 4320), slides: [])
        let e = s.edit([1: doc], last: 0)
        // The edit's offsetLastEdit, set to itself.
        var file = s
        let p = e + 8 + 8
        file.bytes.replaceSubrange(p ..< p + 4, with: le32(UInt32(e)))
        #expect(try PPT.importChecked(try file.file(currentEdit: e)).1.edits == 1)
    }

    /// PowerPoint 95's "dual" files: its own format at the root, a PowerPoint 97 copy in PP97_DUALSTORAGE. The copy
    /// is read; a PowerPoint 95 file without one is refused by name.
    @Test func dualStorageFilesReadTheirPowerPoint97Copy() throws {
        var s = Stream()
        let a = s.slide()
        let doc = s.document(size: (5760, 4320), slides: [2, 2])
        let e = s.edit([1: doc, 2: a], last: 0)
        var dual = CompoundFileWriter()
        try dual.addStream("Current User", [0x1C, 0, 0, 0] + Array("PowerPoint 95 user data".utf8))
        try dual.addStream("PowerPoint Document", [UInt8](repeating: 7, count: 64))
        try dual.addStream("Header", [1, 2, 3])
        try dual.addStream("PP97_DUALSTORAGE/Current User", s.currentUser(e))
        try dual.addStream("PP97_DUALSTORAGE/PowerPoint Document", s.bytes)
        #expect(try PPT.importChecked(try dual.bytes()).0.slides.count == 2)

        var old = CompoundFileWriter()
        try old.addStream("Current User", [0x1C, 0, 0, 0] + Array("PowerPoint 95 user data".utf8))
        try old.addStream("PowerPoint Document", [UInt8](repeating: 7, count: 64))
        try old.addStream("Header", [1, 2, 3])
        #expect(throws: PPTError.unsupported("PowerPoint 95 and earlier presentations")) { try PPT.importChecked(try old.bytes()) }
    }

    // MARK: Damage

    static func readAll(_ b: [UInt8]) { _ = try? PPT.importChecked(b, password: "Password1") }

    @Test func damagedInputFailsCleanly() throws {
        let hostile = Self.legacy.appending(path: "hostile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hostile.path))?.filter { $0.hasSuffix(".ppt") } ?? []
        try #require(!names.isEmpty, "no hostile fixtures")
        for n in names { Self.readAll(Array(try Data(contentsOf: hostile.appending(path: n)))) }

        // Seeded damage to the PowerPoint Document stream of a real file and of a hand-built one.
        var s = Stream()
        let a = s.slide()
        let doc = s.document(size: (5760, 4320), slides: [2, 2, 3])
        let e = s.edit([1: doc, 2: a], last: 0)
        let built = s.bytes
        let real = try CompoundFile(Array(try Data(contentsOf: Self.legacy.appending(path: "ppt/corpus-sample.ppt"))))
        let realStream = try real.stream("PowerPoint Document"), realUser = try real.stream("Current User")
        var rng = UInt64(20_261_030)
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for round in 0 ..< 400 {
            var b = round % 2 == 0 ? built : realStream
            for _ in 0 ..< 1 + next() % 12 { b[next() % b.count] = UInt8(truncatingIfNeeded: next()) }
            if next() % 6 == 0 { b.removeLast(next() % b.count) }
            var w = CompoundFileWriter()
            var stream = Stream()
            stream.bytes = b
            if round % 2 == 0 {
                Self.readAll((try? stream.file(currentEdit: e)) ?? [])
            } else {
                try w.addStream("Current User", realUser)
                try w.addStream("PowerPoint Document", b)
                Self.readAll(try w.bytes())
            }
        }
    }
}

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
