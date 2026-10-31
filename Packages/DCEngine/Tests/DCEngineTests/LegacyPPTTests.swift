// DCEngineTests — opening a legacy `.ppt` (Docs/plans/Legacy-PPT-and-Encryption.md, P1): it is converted and opens as
// an untitled copy with the file's slides and slide size; the reply and the status line say what was converted and
// what isn't brought over yet. An encrypted one needs its password, unless it used PowerPoint's default. Its OLE
// objects come over as their pictures (P4), the reply naming each, and save to `.pptx` as pictures. Its transitions,
// hidden slides and animations come over (P5), show in the Animation Pane, and save to `.pptx`.
import DCCore
import DCPPT
@testable import DCEngine
import DCTestSupport
import Foundation
import Testing

@Suite struct LegacyPPTTests {
    static var legacy: URL { Fixtures.root.appending(path: "legacy", directoryHint: .isDirectory) }

    @Test func aPPTOpensAsAConvertedCopy() throws {
        let path = Self.legacy.appending(path: "ppt/corpus-sample.ppt").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let s = Session()
        let r = try s.execute("file.open", ["path": .string(path)])
        #expect(r.get("slides")?.asI64 == 8)
        #expect(r.get("converted")?.get("from") == "ppt")
        #expect(r.get("converted")?.get("slides")?.asI64 == 8)
        let st = try s.doc()
        #expect(st.path == nil, "a converted copy is untitled: Save asks where")
        #expect(st.title == "corpus-sample")
        #expect(st.doc.slideSize.width == 960 && st.doc.slideSize.height == 540)
        #expect(s.uiRequests.contains { if case let .message(t) = $0 { t.contains("PowerPoint 97–2003") } else { false } })
        // It saves as a modern file.
        let out = FileManager.default.temporaryDirectory.appending(path: "dc-ppt-\(UUID().uuidString).pptx").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        s.run("file.save", #"{"path": "\#(out)"}"#)
        #expect(try FileCommands.readPresentationFile(out).doc.slides.count == 8)
    }

    /// A PICT whose text is in a font macOS downloads on demand (Osaka) makes ImageIO wait on a download prompt no
    /// window shows: its conversion gives up at the deadline instead of hanging the open (found by the crash corpus).
    @Test func aPICTWaitingOnAFontDownloadGivesUp() {
        func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        let frame = be16(0) + be16(0) + be16(40) + be16(200)
        let name = Array("Osaka".utf8)
        var ops = be16(0x0011) + be16(0x02FF)
        ops += be16(0x0C00) + be16(-2) + be16(0) + be16(72) + be16(0) + be16(72) + be16(0) + frame + be16(0) + be16(0)
        ops += be16(0x0001) + be16(10) + frame
        // FontName (id 16384 is "Osaka"), TxFont, TxSize, then LongText at (20, 30).
        ops += be16(0x002C) + be16(3 + name.count) + be16(16384) + [UInt8(name.count)] + name
        ops += be16(0x0003) + be16(16384) + be16(0x000D) + be16(18)
        let text = Array("テキスト Text".utf8)
        ops += be16(0x0028) + be16(30) + be16(20) + [UInt8(text.count)] + text
        if ops.count % 2 == 1 { ops.append(0) }
        ops += be16(0x00FF)
        let pict = [UInt8](repeating: 0, count: 512) + be16(0) + frame + ops
        let start = Date()
        // Its own count of stalled conversions, so one left stuck here doesn't stop other tests' pictures.
        _ = LegacyPictures.pictToPNG(pict, stalls: LegacyPictures.Stalls())
        #expect(Date().timeIntervalSince(start) < 15, "the PICT conversion waited \(Date().timeIntervalSince(start)) s")
    }

    /// A hostile file's report stays short: ten unread slide numbers at most, and slides past the cap are counted.
    @Test func theStatusLineStaysShort() {
        var report = PPTReport(slides: 10_500, unreadSlides: Array(2 ... 400), edits: 2, encrypted: false, notImported: ["picture bullets"])
        report.slidesLeftOut = 500
        let text = FileCommands.convertedMessage("big.ppt", report)
        #expect(text.contains("Slides 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 and 389 more couldn't be read."))
        #expect(text.contains("Only its first 10000 slides were brought over."))
        #expect(text.count < 400)
    }

    @Test func anEncryptedPPTNeedsItsPassword() throws {
        let enc = Self.legacy.appending(path: "encrypted/corpus-sample.poi-rc4cryptoapi.ppt").path
        guard FileManager.default.fileExists(atPath: enc) else { return }
        struct M: Decodable { struct F: Decodable { let file: String; let password: String? }; let files: [F] }
        let m = try JSONDecoder().decode(M.self, from: Data(contentsOf: Self.legacy.appending(path: "manifest.json")))
        let pw = try #require(m.files.first { $0.file == "encrypted/corpus-sample.poi-rc4cryptoapi.ppt" }?.password)
        let s = Session()
        #expect(throws: EngineError.passwordRequired(enc)) { try s.execute("file.open", ["path": .string(enc)]) }
        #expect(throws: EngineError.wrongPassword(enc)) { try s.execute("file.open", ["path": .string(enc), "password": "nope"]) }
        let r = try s.execute("file.open", ["path": .string(enc), "password": .string(pw)])
        #expect(r.get("converted")?.get("encrypted") == .bool(true))
        // The typed password is kept: Save As .pptx encrypts with it.
        #expect(try s.doc().protection?.password == pw)

        // PowerPoint's default password opens without asking, and isn't kept.
        let def = Self.legacy.appending(path: "encrypted/corpus-sample.poi-rc4cryptoapi-default.ppt").path
        guard FileManager.default.fileExists(atPath: def) else { return }
        _ = try s.execute("file.open", ["path": .string(def)])
        #expect(try s.doc().protection == nil)
    }

    @Test func objectsComeOverAsPicturesAndSave() throws {
        let path = Self.legacy.appending(path: "ppt/corpus-content.ppt").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let s = Session()
        let r = try s.execute("file.open", ["path": .string(path)])
        let objects = r.get("converted")?.get("asPictures")?.asArray ?? []
        #expect(objects.count == 2)
        #expect(r.get("converted")?.get("lostPictures")?.asI64 == 0)
        #expect(s.uiRequests.contains { if case let .message(t) = $0 { t.contains("2 embedded objects were brought over as pictures") } else { false } })
        let out = FileManager.default.temporaryDirectory.appending(path: "dc-ppt-\(UUID().uuidString).pptx").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        s.run("file.save", #"{"path": "\#(out)"}"#)
        let saved = try FileCommands.readPresentationFile(out).doc
        let pictures = saved.slides.flatMap(\.shapes).filter { if case .picture = $0.kind { true } else { false } }
        #expect(pictures.count == 2)
        #expect(pictures.allSatisfy { if case .picture(let f) = $0.kind { saved.media(f.media)?.data.isEmpty == false } else { false } })
    }

    @Test func theSlideShowComesOverAndSaves() throws {
        let path = Self.legacy.appending(path: "ppt/motion.ppt").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let s = Session()
        _ = try s.execute("file.open", ["path": .string(path)])
        let doc = try s.doc().doc
        #expect(doc.slides[2].transition?.kind == "fade" && doc.slides[2].transition?.option == "throughBlack")
        #expect(doc.slides[32].hidden)
        // The Animation Pane of the timings slide: five shapes flown in, then the text built by paragraph and the word build.
        let pane = try s.execute("animation.get", ["slide": .int(37)])
        #expect((pane.asArray ?? []).count == 9)
        let out = FileManager.default.temporaryDirectory.appending(path: "dc-ppt-\(UUID().uuidString).pptx").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        s.run("file.save", #"{"path": "\#(out)"}"#)
        let saved = try FileCommands.readPresentationFile(out).doc
        // LibreOffice writes a paragraph build as one effect per paragraph and no build list; saved as `.pptx`, the
        // three read back as the one build by paragraph they play as.
        #expect(saved.slides.map(\.animations.count).dropLast() == doc.slides.map(\.animations.count).dropLast())
        #expect(saved.slides.last?.animations.count == 7 && doc.slides.last?.animations.count == 9)
        #expect(saved.slides.map { $0.transition?.kind } == doc.slides.map { $0.transition?.kind })
        #expect(saved.slides[32].hidden)
    }
}
