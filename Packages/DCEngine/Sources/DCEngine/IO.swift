// DCEngine — reading and writing the files a command names by path.
// Port of deckcraft crates/engine/src/io.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Every such read and write goes through `IO.readFile` and `IO.writeFile`, so the automation roots
// (`FileAccess`) are checked in one place. A command module that touched the file system itself would
// bypass them.
import Darwin
import Foundation

public enum IO {
    /// Largest file read: 2 GiB.
    static let maxFileSize: Int64 = 2 << 30

    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    private static func nextCounter() -> UInt64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        let v = counter
        counter &+= 1
        return v
    }

    static func osMessage(_ code: Int32) -> String { "\(String(cString: strerror(code))) (os error \(code))" }

    /// The bytes of the file at `path`, inside the automation read root when there is one.
    public static func readFile(_ path: String) throws(EngineError) -> [UInt8] {
        do { try FileAccess.checkRead(path) } catch { throw .other(error.message) }
        var st = stat()
        guard stat(path, &st) == 0 else { throw .other("\(path): \(osMessage(errno))") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw .other("\(path): not a regular file") }
        if Int64(st.st_size) > maxFileSize {
            throw .other("\(path): file size \(st.st_size) exceeds 2 GiB limit")
        }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .other("\(path): \(osMessage(errno))") }
        defer { close(fd) }
        var out: [UInt8] = []
        out.reserveCapacity(Int(st.st_size))
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw .other("\(path): \(osMessage(errno))")
            }
            if n == 0 { break }
            out.append(contentsOf: buf[0 ..< n])
            if Int64(out.count) > maxFileSize { throw .other("\(path): file size \(out.count) exceeds 2 GiB limit") }
        }
        return out
    }

    /// Write `bytes` to the file at `path`, inside the automation write root when there is one.
    ///
    /// The bytes go to a temporary sibling first and are renamed over `path`, so a failed save never
    /// truncates the old file. The sibling is in the same folder, so it is inside the root whenever
    /// `path` is.
    public static func writeFile(_ path: String, _ bytes: [UInt8]) throws(EngineError) {
        do { try FileAccess.checkWrite(path) } catch { throw .other(error.message) }
        func err(_ code: Int32) -> EngineError { .other("\(path): \(osMessage(code))") }
        let target: String
        switch FileAccess.canonicalize(path) {
        case .success(let p): target = p
        case .failure: target = path
        }
        var existing = stat()
        let existingMode: mode_t? = stat(target, &existing) == 0 ? existing.st_mode & 0o7777 : nil

        var attempts = 0
        var tmp = ""
        var fd: Int32 = -1
        while true {
            tmp = "\(target).\(getpid()).\(nextCounter()).saving"
            fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
            if fd >= 0 { break }
            let code = errno
            if code == EEXIST && attempts < 16 {
                attempts += 1
                continue
            }
            throw err(code)
        }
        if let mode = existingMode { _ = fchmod(fd, mode) }
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
        if failure == nil && rename(tmp, target) != 0 { failure = errno }
        if let code = failure {
            unlink(tmp)
            throw err(code)
        }
    }

    /// The size in bytes of the file at `path`; nil when it can't be read (or is outside the automation
    /// read root, so File › Info doesn't reveal files the agent may not read).
    public static func fileLen(_ path: String) -> UInt64? {
        guard (try? FileAccess.checkRead(path)) != nil else { return nil }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(max(st.st_size, 0))
    }
}

// MARK: - The engine's own files (spelling dictionaries)

/// Files the engine finds itself, never a path a command names: the spelling dictionaries in the folders
/// the system's spell checkers use, and the user dictionary Add to Dictionary appends to (spell.rs reads
/// and writes these with `std::fs`, outside the automation roots, as Recovery's folder is).
extension IO {
    /// Whether `path` is a regular file (`Path::is_file`).
    static func isOwnFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// The names in folder `path`; nil when it can't be listed.
    static func ownDirectoryEntries(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// The bytes of the engine's own file at `path`; nil when it can't be read.
    static func readOwnFile(_ path: String) -> [UInt8]? {
        FileManager.default.contents(atPath: path).map { [UInt8]($0) }
    }

    /// Append `bytes` to the engine's own file at `path`, creating it and its folders.
    static func appendOwnFile(_ path: String, _ bytes: [UInt8]) throws {
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(bytes))
        } else {
            try Data(bytes).write(to: url)
        }
    }
}
