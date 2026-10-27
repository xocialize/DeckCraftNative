// DCEngine — crash recovery (PowerPoint's AutoRecover).
// Port of deckcraft crates/engine/src/recovery.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Unsaved changes of every open presentation are written to a recovery folder (`file.recovery.save`,
// called on a timer by the app); saving or closing a presentation removes its entry; after a crash
// `file.recovery.open` reopens what was left there as unsaved presentations that remember where they
// were saved.
//
// An entry is `<uid>.deckcraft` (the presentation) plus `<uid>.json` (`{"path", "title", "saved",
// "owner"}`: the original file, the title, when it was written (Unix seconds) and the instance that owns
// it). Several instances share the folder: document uids are unique across processes, each instance
// holds a lock (`flock`) on `owner-<instance>.lock` while it runs, and `file.recovery.open` leaves alone
// the entries of an instance whose lock is still held.
import DCCore
import DCFormat
import DCModel
import Darwin
import Foundation

public enum Recovery {
    /// The platform's per-user recovery folder.
    public static func defaultDir() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/DeckCraft/Recovery")
    }

    /// Uids and instance ids stay below 2^53 so they survive JSON numbers read as `f64`.
    static let uidMask: UInt64 = (1 << 53) - 1

    private static let instance: UInt64 = {
        var h = UInt64.random(in: 0 ... UInt64.max)
        h ^= UInt64(UInt32(bitPattern: getpid())) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(Date().timeIntervalSince1970 * 1e9)
        // Never 0: old entries are numbered from 1.
        return max((h & uidMask) & ~UInt64(0xFF_FFFF), 1 << 24)
    }()

    /// This process's random id, with the low 24 bits clear so its document uids (id + counter) don't run
    /// into another instance's.
    public static func instanceId() -> UInt64 { instance }

    static func lockPath(_ dir: URL, _ owner: UInt64) -> URL { dir.appending(path: "owner-\(owner).lock") }

    private static let heldLock = NSLock()
    nonisolated(unsafe) private static var held: [(String, Int32)] = []

    /// Hold this instance's lock in `dir` for the rest of the process (once per folder).
    static func claimDir(_ dir: URL) {
        heldLock.lock()
        defer { heldLock.unlock() }
        if held.contains(where: { $0.0 == dir.path }) { return }
        let path = lockPath(dir, instanceId()).path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            held.append((dir.path, fd))
        } else {
            close(fd)
        }
    }

    /// Whether another running instance holds `owner`'s lock in `dir`.
    static func ownerAlive(_ dir: URL, _ owner: UInt64) -> Bool {
        let fd = Darwin.open(lockPath(dir, owner).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    /// Write `bytes` to `path` through a temporary file and a rename, so a crash never leaves it torn.
    static func writeAtomic(_ path: URL, _ bytes: [UInt8]) throws(EngineError) {
        let tmp = path.deletingPathExtension().appendingPathExtension("\(path.pathExtension).tmp")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .other("\(tmp.path): \(IO.osMessage(errno))") }
        var failure: Int32?
        var written = 0
        bytes.withUnsafeBytes { raw in
            while written < raw.count {
                let n = write(fd, raw.baseAddress?.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                written += n
            }
        }
        if failure == nil && fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == nil && rename(tmp.path, path.path) != 0 { failure = errno }
        if let code = failure {
            unlink(tmp.path)
            throw .other("\(path.path): \(IO.osMessage(code))")
        }
    }

    /// Presentations reopened per start; the rest stay on disk for the next one.
    public static let maxReopen = 32
    /// Largest entry read back.
    static let maxEntryBytes: Int64 = 2 << 30
    static let maxMetaBytes: Int64 = 64 << 10

    /// `p` as bytes when it's a regular file no bigger than `max`: reading a FIFO left where an entry
    /// belongs would block start-up forever.
    static func readRegular(_ p: URL, _ max: Int64) -> [UInt8]? {
        var st = stat()
        guard stat(p.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int64(st.st_size) <= max else { return nil }
        return FileManager.default.contents(atPath: p.path).map { [UInt8]($0) }
    }

    static func files(_ dir: URL, _ uid: UInt64) -> (URL, URL) {
        (dir.appending(path: "\(uid).deckcraft"), dir.appending(path: "\(uid).json"))
    }

    static func nowSecs() -> UInt64 { UInt64(max(Date().timeIntervalSince1970, 0)) }

    /// Remove a presentation's recovery entry (it was saved or closed).
    public static func discard(_ dir: URL, _ uid: UInt64) {
        let (d, m) = files(dir, uid)
        unlink(d.path)
        unlink(m.path)
    }

    /// Write entries for the unsaved presentations (and drop those of saved ones). Returns how many were
    /// written.
    @discardableResult
    public static func save(_ s: Session, _ dir: URL) throws(EngineError) -> Int {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw .other("\(dir.path): \(error.localizedDescription)")
        }
        claimDir(dir)
        var n = 0
        for d in s.documents {
            if !d.isDirty {
                discard(dir, d.uid)
                continue
            }
            let (doc, meta) = files(dir, d.uid)
            let bytes: [UInt8]
            do { bytes = try DeckFormat.save(d.doc) } catch { throw .other(error.description) }
            try writeAtomic(doc, bytes)
            let m: JSON = ["path": .opt(d.path), "title": .string(d.displayTitle), "saved": .integer(nowSecs()), "owner": .integer(instanceId())]
            try writeAtomic(meta, Array(m.display.utf8))
            n += 1
        }
        return n
    }

    /// Entries in `dir`: (uid, metadata), by uid.
    public static func list(_ dir: URL) -> [(UInt64, JSON)] {
        var out: [(UInt64, JSON)] = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return out }
        for name in names {
            let p = dir.appending(path: name)
            guard p.pathExtension == "deckcraft" else { continue }
            var st = stat()
            guard stat(p.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            guard let uid = UInt64(p.deletingPathExtension().lastPathComponent) else { continue }
            // Metadata is a file on disk: anything but an object (corrupt, hand-edited) counts as none.
            var meta: JSON = .emptyObject
            if let t = readRegular(p.deletingPathExtension().appendingPathExtension("json"), maxMetaBytes),
               let v = try? JSONParser.parse(t), v.isObject {
                meta = v
            }
            out.append((uid, meta))
        }
        out.sort { $0.0 < $1.0 }
        return out
    }

    /// Reopen every entry left by an instance that is no longer running as an unsaved presentation.
    /// Entries stay on disk, now owned by this instance: the presentation keeps the entry's uid, so the
    /// next recovery save replaces the snapshot and saving or closing it removes it. Returns the opened
    /// documents' indices. At most `maxReopen` are opened per start, the newest first.
    @discardableResult
    public static func open(_ s: Session, _ dir: URL) throws(EngineError) -> [Int] {
        let me = instanceId()
        var opened: [Int] = []
        var entries = list(dir)
        entries.sort { a, b in
            let sa = a.1.get("saved")?.asU64 ?? 0
            let sb = b.1.get("saved")?.asU64 ?? 0
            return (sa, a.0) > (sb, b.0)
        }
        for (uid, var meta) in entries {
            if opened.count >= maxReopen { break }
            if s.documents.contains(where: { $0.uid == uid }) { continue }
            if let owner = meta.get("owner")?.asU64, owner != me, ownerAlive(dir, owner) { continue }
            let (docURL, metaURL) = files(dir, uid)
            guard let bytes = readRegular(docURL, maxEntryBytes) else { continue }
            guard var d = try? DeckFormat.load(bytes) else { continue }
            DeckFormat.repair(&d)
            let path = meta.get("path")?.asStr
            let title = meta.get("title")?.asStr.flatMap { $0.isEmpty ? nil : $0 } ?? "Presentation"
            // Take the entry over (so another instance starting now leaves it alone), keeping its
            // snapshot until this one writes a newer one.
            claimDir(dir)
            meta.set("owner", .integer(me))
            try? writeAtomic(metaURL, Array(meta.display.utf8))
            let st = DocState(d, path: path, title: "\(title) (Recovered)")
            st.uid = uid
            // Unsaved: the copy on disk (if any) is older than what was recovered.
            st.savedDocRef = DocRef(st.doc)
            st.revision += 1
            opened.append(s.addDocument(st))
        }
        removeStaleLocks(dir)
        return opened
    }

    /// Delete the lock files of instances that are no longer running.
    static func removeStaleLocks(_ dir: URL) {
        let me = instanceId()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("owner-") && name.hasSuffix(".lock") {
            guard let owner = UInt64(name.dropFirst("owner-".count).dropLast(".lock".count)) else { continue }
            if owner != me && !ownerAlive(dir, owner) { unlink(dir.appending(path: name).path) }
        }
    }
}
