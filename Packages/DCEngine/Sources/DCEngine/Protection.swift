// DCEngine — password-protected presentations (Docs/plans/Legacy-PPT-and-Encryption.md §3–4): a password to open
// (the file is encrypted, DCOffCrypto) and a password to modify (a verifier in `ppt/presentation.xml`; without the
// password, the file opens read-only). Both are kept with the open document (`DocState.protection`), in memory
// only, and applied when it is saved as `.pptx`, `.potx` or `.ppsx`; a format that can't hold them (`.deckcraft`,
// an outline) saves without them, and the document then has none. Not a port: deckcraft has neither.
import DCOffCrypto
import DCPPTX
import DCZip

/// A presentation's passwords, kept with its open document.
public struct DocProtection: Sendable, Equatable {
    /// The password to open: the file is encrypted with it.
    public var password: String?
    /// The password to modify.
    public var modifyPassword: String?

    public init(password: String? = nil, modifyPassword: String? = nil) {
        self.password = password
        self.modifyPassword = modifyPassword
    }

    /// Nil when there's neither password.
    var orNil: DocProtection? { password == nil && modifyPassword == nil ? nil : self }
}

public enum Protection {
    static let presentationPart = "ppt/presentation.xml"

    /// The formats that keep a presentation's passwords.
    public static func keepsPasswords(_ format: String) -> Bool { ["pptx", "potx", "ppsx"].contains(format) }

    /// The password-to-modify verifier of an OOXML package, nil without one.
    public static func verifier(inPackage zip: [UInt8]) -> ModifyVerifier? {
        guard let r = try? ZipReader(zip), let xml = try? r.read(named: presentationPart, max: 64 << 20) else { return nil }
        return ModifyVerifier.find(inPresentationXML: String(decoding: xml, as: UTF8.self))
    }

    /// The package with a new verifier for `modifyPassword`, or with none when it is nil. Every other part is kept
    /// as it was, in order.
    public static func setVerifier(_ zip: [UInt8], modifyPassword: String?) throws -> [UInt8] {
        let r = try ZipReader(zip)
        var w = ZipWriter()
        for e in r.entries {
            var data = try r.read(e, max: Int.max)
            if e.name == presentationPart {
                let xml = String(decoding: data, as: UTF8.self)
                let out = modifyPassword.map { ModifyVerifier.make(password: $0).insert(intoPresentationXML: xml) }
                    ?? ModifyVerifier.remove(fromPresentationXML: xml)
                data = Array(out.utf8)
            }
            try w.add(e.name, data, compress: e.method != 0)
        }
        return try w.finish()
    }

    /// The bytes `st` is saved as in `format`: in an OOXML format with its password to modify and encrypted with its
    /// password to open; in any other format as `FileCommands.saveBytes` writes it.
    public static func fileBytes(_ st: DocState, _ format: String) throws -> [UInt8] {
        var bytes = try FileCommands.saveBytes(st.doc, format)
        guard let p = st.protection, keepsPasswords(format) else { return bytes }
        if let modify = p.modifyPassword { bytes = try setVerifier(bytes, modifyPassword: modify) }
        if let password = p.password {
            do { bytes = try OfficeCrypto.encrypt(bytes, password: password) } catch { throw EngineError.other("\(error)") }
        }
        return bytes
    }

    /// After `st` was saved in `format`: a format that can't hold its passwords leaves the document without them, and
    /// the status line says so.
    static func didSave(_ s: Session, _ st: DocState, _ format: String) {
        guard st.protection != nil, !keepsPasswords(format) else { return }
        st.protection = nil
        st.protectionEdited = false
        s.uiRequests.append(.message(text: "“\(st.title)” was saved in a format that can't keep a password, so this copy isn't password-protected."))
    }
}
