// DCEngineTests — password-protected presentations (Docs/plans/Legacy-PPT-and-Encryption.md, E2–E3): `file.open` and
// `file.openBytes` take a password; without one, or with a wrong one, the error says which; the password stays
// with the open document only (not in the journal, AutoRecover or a reply); saving as .pptx keeps it, and a password
// to modify opens the file read-only without it (E3).
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

    /// Saving as .pptx keeps the password (the file is encrypted with it); saving as .deckcraft can't, so the
    /// document has none afterwards and the status line says so. AutoRecover leaves a protected presentation out.
    @Test func savingKeepsThePasswordWhereTheFormatCan() throws {
        guard Self.available() else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pw = try Self.password()
        let s = Session()
        _ = try s.execute("file.open", ["path": .string(Self.legacy.appending(path: Self.fixture).path), "password": .string(pw)])
        let slides = try s.doc().doc.slides.count
        s.run("slide.new", #"{"layout": "blank"}"#)
        let rec = dir.appending(path: "recovery")
        #expect(try Recovery.save(s, rec) == 0)

        let out = dir.appending(path: "copy.pptx").path
        s.run("file.save", #"{"path": "\#(out)"}"#)
        let saved = Array(try Data(contentsOf: URL(filePath: out)))
        #expect(FileCommands.isProtected(saved))
        #expect(throws: EngineError.passwordRequired("copy.pptx")) { try FileCommands.openFile("copy.pptx", saved) }
        #expect(try FileCommands.openFile("copy.pptx", saved, password: pw).presentation.slides.count == slides + 1)
        #expect(try s.doc().protection?.password == pw)
        let data = s.run("file.saveBytes", #"{"format": "pptx"}"#).get("data")?.asStr ?? ""
        #expect(FileCommands.isProtected(Cmd.base64Decode(data) ?? []))

        s.run("file.save", #"{"path": "\#(dir.appending(path: "copy.deckcraft").path)"}"#)
        #expect(try s.doc().protection == nil)
        #expect(s.uiRequests.contains { if case let .message(t) = $0 { t.contains("can't keep a password") } else { false } })
    }

    /// A password to modify: saved as a verifier in presentation.xml; without it the file opens read-only, as an
    /// untitled copy; with it, editable; with a wrong one, an error. The password never reaches the journal.
    @Test func aPasswordToModifyOpensReadOnlyWithoutIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-modify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = session()
        try s.doc().protection = DocProtection(modifyPassword: "Modify2")
        let out = dir.appending(path: "m.pptx").path
        s.run("file.save", #"{"path": "\#(out)"}"#)
        let bytes = Array(try Data(contentsOf: URL(filePath: out)))
        #expect(!FileCommands.isProtected(bytes), "a password to modify alone doesn't encrypt")
        #expect(Protection.verifier(inPackage: bytes)?.matches("Modify2") == true)

        let t = Session()
        let r = try t.execute("file.open", ["path": .string(out)])
        #expect(r.get("readOnly") == .bool(true))
        #expect(try t.doc().path == nil)
        #expect(try t.doc().title.hasSuffix("(Read-Only)"))
        #expect(throws: EngineError.wrongPassword(out)) { try t.execute("file.open", ["path": .string(out), "modifyPassword": "nope"]) }
        let ok = try t.execute("file.open", ["path": .string(out), "modifyPassword": "Modify2"])
        #expect(ok.get("readOnly") == nil)
        #expect(try t.doc().path == out)
        #expect(try t.doc().protection?.modifyPassword == "Modify2")
        #expect(t.journal.allSatisfy { $0.1.get("modifyPassword") == nil })
    }

    /// PowerPoint's own files with a password to modify (local only, Tools/legacy/powerpoint-protect.sh): the
    /// verifier reads, and its password opens them for editing.
    @Test func powerPointsPasswordToModifyIsRead() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".modify-only.pptx") } ?? []
        guard !files.isEmpty else { return }
        struct Meta: Decodable { let modifyPassword: String }
        for f in files {
            let url = dir.appending(path: f)
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appending(path: "\(f).meta.json")))
            let bytes = Array(try Data(contentsOf: url))
            #expect(Protection.verifier(inPackage: bytes)?.matches(meta.modifyPassword) == true, "\(f)")
            #expect(try FileCommands.openFile(f, bytes).readOnly)
            #expect(try !FileCommands.openFile(f, bytes, modifyPassword: meta.modifyPassword).readOnly)
        }
    }
}
