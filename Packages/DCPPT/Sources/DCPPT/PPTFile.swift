// DCPPT — the legacy binary PowerPoint format ([MS-PPT] v2026-02), read: the container (P1 of
// Docs/plans/Legacy-PPT-and-Encryption.md). A `.ppt` is a compound file (DCCFB) whose `Current User` stream points at
// the newest UserEditAtom in the `PowerPoint Document` stream. Each edit (a save; PowerPoint appends one on every
// incremental save) has a persist directory mapping persist object ids to stream offsets; the directories are merged
// oldest first, so a newer save's objects replace older ones, and records no directory reaches are dead and ignored.
// An encrypted file (RC4 CryptoAPI, DCOffCrypto) has a CryptSession10Container: every persist object but that one is
// decrypted with its persist id as the block number, its record header included. Written from the specification;
// deckcraft has no `.ppt` reader. ppt2pptx (MIT) was consulted as prior art.
//
// Every offset, length and id comes from the file: each is range-checked before use, the edit chain must move
// backwards (and is bounded), and records nest no deeper than `maxDepth`. Nothing here traps.
import DCCFB
import DCOffCrypto

/// A `.ppt` file's container: its persist objects, decrypted when the file is encrypted.
public struct PPTFile: Sendable {
    /// The `PowerPoint Document` stream (still encrypted, for an encrypted file: `object` decrypts).
    let stream: [UInt8]
    /// Persist object id → offset in the stream, newest edit winning.
    public let directory: [UInt32: Int]
    /// The persist id of the DocumentContainer.
    public let documentRef: UInt32
    /// How many edits (saves) the edit chain holds; more than one means incremental saves.
    public let edits: Int
    /// The key of an encrypted file.
    let key: RC4CryptoAPI.Key?
    /// The persist id of the CryptSession10Container (never decrypted).
    let cryptSessionRef: UInt32?
    /// Whether the file is encrypted, and whether it opened with PowerPoint's default password.
    public var isEncrypted: Bool { key != nil }
    public let usedDefaultPassword: Bool

    static let maxEdits = 4096

    /// Whether `bytes` is a compound file with the streams of a `.ppt` (PowerPoint 95's included, which
    /// `init` refuses by name).
    public static func isPPT(_ bytes: [UInt8]) -> Bool {
        guard CompoundFile.isCompoundFile(bytes), let cfb = try? CompoundFile(bytes) else { return false }
        return cfb.contains("PowerPoint Document") && cfb.contains("Current User")
    }

    /// PowerPoint 95 wrote "dual" files that keep its own format at the root and a PowerPoint 97 copy in the
    /// `PP97_DUALSTORAGE` storage (not in [MS-PPT]; Apache POI and ppt2pptx read it the same way).
    static let dualStorage = "PP97_DUALSTORAGE"

    /// The `Current User` and `PowerPoint Document` streams of the PowerPoint 97 document in `cfb`.
    static func streams(_ cfb: CompoundFile) throws(PPTError) -> (user: [UInt8], document: [UInt8]) {
        for prefix in ["", dualStorage + "/"] {
            guard let user = try? cfb.stream(prefix + "Current User"), let doc = try? cfb.stream(prefix + "PowerPoint Document"),
                  let r = Record(user, at: 0), r.type == RT.currentUserAtom
            else { continue }
            return (user, doc)
        }
        if cfb.contains("Header") || cfb.contains("PersistentStorage Directory") {
            throw .unsupported("PowerPoint 95 and earlier presentations")
        }
        throw .damaged("the Current User stream has no CurrentUserAtom")
    }

    /// Reads the container. An encrypted file needs `password`, unless it was encrypted with PowerPoint's default.
    public init(_ bytes: [UInt8], password: String? = nil) throws(PPTError) {
        let cfb: CompoundFile
        do { cfb = try CompoundFile(bytes) } catch { throw .notPPT }
        guard cfb.contains("Current User") || cfb.contains(Self.dualStorage + "/Current User") else { throw .notPPT }
        let (user, stream) = try Self.streams(cfb)
        self.stream = stream

        // CurrentUserAtom: where the newest edit is.
        guard user.count >= 20 else { throw .damaged("the CurrentUserAtom is too short") }
        var offset = Int(le32(user, 16))

        // The edit chain, newest first, each edit before the last one in the stream.
        var chain: [(edit: UserEdit, at: Int)] = []
        var seen = Set<Int>()
        while chain.count < Self.maxEdits {
            guard seen.insert(offset).inserted, let edit = UserEdit(stream, at: offset) else {
                if chain.isEmpty { throw .damaged("no UserEditAtom at offset \(offset)") }
                break
            }
            chain.append((edit, offset))
            guard edit.offsetLastEdit != 0, Int(edit.offsetLastEdit) < offset else { break }
            offset = Int(edit.offsetLastEdit)
        }
        guard let newest = chain.first?.edit else { throw .damaged("no edits") }
        edits = chain.count

        // The persist directories, oldest first: a newer edit's entries replace an older one's.
        var dir: [UInt32: Int] = [:]
        for (edit, _) in chain.reversed() {
            guard let atom = Record(stream, at: Int(edit.offsetPersistDirectory)), atom.type == RT.persistDirectoryAtom else { continue }
            var p = atom.body.lowerBound
            while p + 4 <= atom.body.upperBound {
                let word = le32(stream, p)
                let first = word & 0xF_FFFF, count = Int(word >> 20)
                p += 4
                for i in 0 ..< count {
                    guard p + 4 <= atom.body.upperBound else { break }
                    dir[first &+ UInt32(i)] = Int(le32(stream, p))
                    p += 4
                }
            }
        }
        directory = dir
        documentRef = newest.docPersistIdRef

        // Encryption.
        if let ref = newest.encryptSessionPersistIdRef {
            guard let at = dir[ref], let session = Record(stream, at: at), session.type == RT.cryptSession10Container else {
                throw .damaged("the file is encrypted but its CryptSession10Container can't be found")
            }
            let header: RC4CryptoAPI
            do { header = try RC4CryptoAPI(header: Array(stream[session.body])) } catch { throw .unsupported("this password protection (\(error))") }
            cryptSessionRef = ref
            if let password {
                guard let k = header.key(password: password) else { throw .wrongPassword }
                key = k
                usedDefaultPassword = password == RC4CryptoAPI.defaultPassword
            } else if let k = header.key(password: RC4CryptoAPI.defaultPassword) {
                key = k
                usedDefaultPassword = true
            } else {
                throw .passwordRequired
            }
        } else {
            key = nil
            cryptSessionRef = nil
            usedDefaultPassword = false
        }
    }

    /// The persist object `id`, its header and data, decrypted; nil when the directory doesn't have it or it runs
    /// past the stream.
    public func object(_ id: UInt32) -> [UInt8]? {
        guard let at = directory[id], at >= 0, at + 8 <= stream.count else { return nil }
        guard let key, id != cryptSessionRef else {
            guard let r = Record(stream, at: at) else { return nil }
            return Array(stream[at ..< r.body.upperBound])
        }
        let rc4 = key.cipher(block: id)
        let header = rc4.process(stream[at ..< at + 8])
        let length = Int(le32(header, 4))
        guard length <= stream.count - at - 8 else { return nil }
        return header + rc4.process(stream[at + 8 ..< at + 8 + length])
    }
}

public enum PPTError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not a `.ppt` (no `PowerPoint Document` and `Current User` streams).
    case notPPT
    /// Encrypted with a password other than PowerPoint's default, and none was given.
    case passwordRequired
    case wrongPassword
    case unsupported(String)
    case damaged(String)

    public var description: String {
        switch self {
        case .notPPT: "not a PowerPoint 97–2003 presentation"
        case .passwordRequired: "the presentation is password-protected"
        case .wrongPassword: "the password is incorrect"
        case let .unsupported(m): "DeckCraft can't open \(m)"
        case let .damaged(m): "the presentation is damaged: \(m)"
        }
    }
}

/// A UserEditAtom ([MS-PPT] 2.3.3).
struct UserEdit {
    let offsetLastEdit: UInt32
    let offsetPersistDirectory: UInt32
    let docPersistIdRef: UInt32
    let encryptSessionPersistIdRef: UInt32?

    init?(_ s: [UInt8], at: Int) {
        guard let r = Record(s, at: at), r.type == RT.userEditAtom, r.body.count >= 0x1C else { return nil }
        let b = r.body.lowerBound
        offsetLastEdit = le32(s, b + 8)
        offsetPersistDirectory = le32(s, b + 12)
        docPersistIdRef = le32(s, b + 16)
        encryptSessionPersistIdRef = r.body.count >= 0x20 ? le32(s, b + 28) : nil
    }
}

/// Record types used here ([MS-PPT] 2.13.24).
enum RT {
    static let document: UInt16 = 0x03E8
    static let documentAtom: UInt16 = 0x03E9
    static let slide: UInt16 = 0x03EE
    static let notes: UInt16 = 0x03F0
    static let slidePersistAtom: UInt16 = 0x03F3
    static let mainMaster: UInt16 = 0x03F8
    static let slideShowSlideInfoAtom: UInt16 = 0x03F9
    static let slideListWithText: UInt16 = 0x0FF0
    static let userEditAtom: UInt16 = 0x0FF5
    static let currentUserAtom: UInt16 = 0x0FF6
    static let persistDirectoryAtom: UInt16 = 0x1772
    static let cryptSession10Container: UInt16 = 0x2F14
    static let slideAtom: UInt16 = 0x03EF
    static let notesAtom: UInt16 = 0x03F1
    static let environment: UInt16 = 0x03F2
    static let fontCollection: UInt16 = 0x07D5
    static let fontEntityAtom: UInt16 = 0x0FB7
    static let drawing: UInt16 = 0x040C
    static let placeholderAtom: UInt16 = 0x0BC3
    static let outlineTextRefAtom: UInt16 = 0x0F9E
    static let textHeaderAtom: UInt16 = 0x0F9F
    static let textCharsAtom: UInt16 = 0x0FA0
    static let styleTextPropAtom: UInt16 = 0x0FA1
    static let textBytesAtom: UInt16 = 0x0FA8
    // OfficeArt ([MS-ODRAW] 2.2): the drawing inside each slide.
    static let dgContainer: UInt16 = 0xF002
    static let spgrContainer: UInt16 = 0xF003
    static let spContainer: UInt16 = 0xF004
    static let fspgr: UInt16 = 0xF009
    static let fsp: UInt16 = 0xF00A
    static let clientTextbox: UInt16 = 0xF00D
    static let childAnchor: UInt16 = 0xF00F
    static let clientAnchor: UInt16 = 0xF010
    static let clientData: UInt16 = 0xF011
}

/// A record header ([MS-PPT] 2.3.1) and where its data is.
struct Record {
    let version: UInt8
    let instance: UInt16
    let type: UInt16
    /// The data's range in the bytes the record was read from, cut to what's there.
    let body: Range<Int>
    var isContainer: Bool { version == 0xF }

    /// The record at `at`, nil when its header doesn't fit; data running past `limit` (or the bytes) is cut.
    init?(_ b: [UInt8], at: Int, limit: Int? = nil) {
        let end = min(limit ?? b.count, b.count)
        guard at >= 0, at + 8 <= end else { return nil }
        let vi = le16(b, at)
        version = UInt8(vi & 0xF)
        instance = vi >> 4
        type = le16(b, at + 2)
        let length = Int(le32(b, at + 4))
        body = at + 8 ..< min(end, at + 8 + length)
    }

    /// The records in this one's data (for a container), in order; a child running past the data is cut.
    func children(_ b: [UInt8]) -> [Record] {
        var out: [Record] = []
        var p = body.lowerBound
        while let r = Record(b, at: p, limit: body.upperBound) {
            out.append(r)
            guard r.body.upperBound > p else { break }
            p = r.body.upperBound
        }
        return out
    }
}

func le16(_ b: [UInt8], _ at: Int) -> UInt16 {
    guard at >= 0, at + 2 <= b.count else { return 0 }
    return UInt16(b[at]) | UInt16(b[at + 1]) << 8
}

func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
    guard at >= 0, at + 4 <= b.count else { return 0 }
    return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

func i32(_ b: [UInt8], _ at: Int) -> Int32 { Int32(bitPattern: le32(b, at)) }
