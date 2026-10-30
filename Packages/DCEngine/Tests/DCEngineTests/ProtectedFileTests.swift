// DCEngineTests — password-protected presentations (Docs/plans/Legacy-PPT-and-Encryption.md, E2): `file.open` and
// `file.openBytes` take a password; without one, or with a wrong one, the error says which; the password stays
// with the open document only (not in the journal, AutoRecover or a reply); and until saving with a password
// arrives (E3) such a presentation isn't saved, so it can't lose its protection.
import DCCore
@testable import DCEngine
import DCTestSupport
import Foundation
import Testing

@Suite struct ProtectedFileTests {
    static var legacy: URL { Fixtures.root.appending(path: "legacy", directoryHint: .isDirectory) }
    static let fixture = "encrypted/corpus-sample.poi-agile-aes256-sha512.pptx"
    static let plain = "pptx/corpus-sample.pptx"

    /// The fixture's password, from the fixtures' manifest.
    static func password() throws -> String {
        struct M: Decodable { struct F: Decodable { let file: String; let password: String? }; let files: [F] }
        let m = try JSONDecoder().decode(M.self, from: Data(contentsOf: legacy.appending(path: "manifest.json")))
        return try #require(m.files.first { $0.file == fixture }?.password)
    }

    static func available() -> Bool { FileManager.default.fileExists(atPath: legacy.appending(path: fixture).path) }

    @Test func openingAsksForThePasswordAndSaysWhenItIsWrong() throws {
        guard Self.available() else { return }
        let path = Self.legacy.appending(path: Self.fixture).path
        let s = Session()
        #expect(throws: EngineError.passwordRequired(path)) { try s.execute("file.open", ["path": .string(path)]) }
        #expect(throws: EngineError.wrongPassword(path)) {
            try s.execute("file.open", ["path": .string(path), "password": "nope"])
        }
        #expect(s.documents.isEmpty)
        let r = try s.execute("file.open", ["path": .string(path), "password": .string(try Self.password())])
        #expect(r.get("protected") == .bool(true))
        // The same slides as the plaintext it was made from.
        let plain = try FileCommands.readPresentationFile(Self.legacy.appending(path: Self.plain).path)
        #expect(r.get("slides")?.asI64 == Int64(plain.doc.slides.count))
        let st = try s.doc()
        #expect(st.protection == DocProtection(password: try Self.password()))
        #expect(st.path == path)
        // The password isn't in the reply or the journal.
        #expect(!r.display.contains(try Self.password()))
        #expect(s.journal.allSatisfy { $0.1.get("password") == nil })
    }

    @Test func openBytesTakesAPasswordToo() throws {
        guard Self.available() else { return }
        let data = Cmd.base64Encode(Array(try Data(contentsOf: Self.legacy.appending(path: Self.fixture))))
        let s = Session()
        #expect(throws: EngineError.passwordRequired("deck.pptx")) {
            try s.execute("file.openBytes", ["name": "deck.pptx", "data": .string(data)])
        }
        _ = try s.execute("file.openBytes", ["name": "deck.pptx", "data": .string(data), "password": .string(try Self.password())])
        #expect(try s.doc().protection != nil)
    }

    /// Until E3, Save refuses a protected presentation rather than writing it without its password; PDF export
    /// still works, and AutoRecover leaves it out.
    @Test func aProtectedPresentationIsntSavedWithoutItsPassword() throws {
        guard Self.available() else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        _ = try s.execute("file.open", ["path": .string(Self.legacy.appending(path: Self.fixture).path), "password": .string(try Self.password())])
        s.run("slide.new", #"{"layout": "blank"}"#)
        let out = dir.appending(path: "copy.pptx").path
        #expect(s.fails("file.save", #"{"path": "\#(out)"}"#))
        #expect(s.fails("file.saveBytes", #"{"format": "pptx"}"#))
        #expect(!FileManager.default.fileExists(atPath: out))
        s.run("file.export", #"{"path": "\#(dir.appending(path: "copy.pdf").path)"}"#)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "copy.pdf").path))
        let rec = dir.appending(path: "recovery")
        #expect(try Recovery.save(s, rec) == 0)
        #expect(Recovery.list(rec).isEmpty)
    }
}
