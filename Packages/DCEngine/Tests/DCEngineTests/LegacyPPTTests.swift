// DCEngineTests — opening a legacy `.ppt` (Docs/plans/Legacy-PPT-and-Encryption.md, P1): it is converted and opens as
// an untitled copy with the file's slides and slide size; the reply and the status line say what was converted and
// what isn't brought over yet. An encrypted one needs its password, unless it used PowerPoint's default. Its OLE
// objects come over as their pictures (P4), the reply naming each, and save to `.pptx` as pictures.
import DCCore
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
}
