// DCEngine — the folders automation may read and write.
// Port of deckcraft crates/engine/src/file_access.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// `dccli mcp --automation-read-root <dir> --automation-write-root <dir>` confines the files an agent's
// commands reach. `AutomationRoots` holds the two folders. While they are in force, every path a command
// reads goes through `FileAccess.checkRead` and every path it writes through `checkWrite`:
//
// - The path is made absolute against the working directory, as the file system reads it. Its links are
//   followed: for a file that doesn't exist yet, the links of its nearest existing folder, the rest of
//   the path being plain names (`..` below a missing folder is refused, and so is a link that leads
//   nowhere).
// - The result must lie inside the root, compared by whole components (`/work2` isn't inside `/work`).
// - Read and write access are separate: a root given alone grants only its own kind of access.
//
// Roots are in force inside `FileAccess.confine` (a task-local scope, so it stays on the thread or task
// that set it), and in the whole process after `confineProcess`, except inside `unconfined`. Without
// roots nothing is checked.
import Darwin
import Foundation

/// Read access or write access.
public enum Access: Sendable, Equatable {
    case read
    case write
}

/// The folders automation may read and write; a root left out grants no access of its kind.
public final class AutomationRoots: Sendable {
    struct Root: Sendable {
        /// The folder made absolute, links followed: what paths are compared with.
        var resolved: String
    }

    let read: Root?
    let write: Root?

    private init(read: Root?, write: Root?) {
        self.read = read
        self.write = write
    }

    /// The folder at `path`, which must exist.
    private static func open(_ path: String, _ access: Access) throws(FileAccessError) -> Root {
        let kind = access == .read ? "read" : "write"
        switch FileAccess.canonicalize(path) {
        case .success(let p):
            guard FileAccess.isDirectory(p) else {
                throw FileAccessError("cannot open the automation \(kind) root `\(path)`: not a directory")
            }
            return Root(resolved: p)
        case .failure(let e):
            throw FileAccessError("cannot open the automation \(kind) root `\(path)`: \(e.message)")
        }
    }

    /// The roots `read` and `write`, which must be existing folders; nil when neither is given (nothing is
    /// confined then).
    public static func make(read: String?, write: String?) throws(FileAccessError) -> AutomationRoots? {
        if read == nil && write == nil { return nil }
        let r = try read.map { (p: String) throws(FileAccessError) -> Root in try open(p, .read) }
        let w = try write.map { (p: String) throws(FileAccessError) -> Root in try open(p, .write) }
        return AutomationRoots(read: r, write: w)
    }

    /// The read root, absolute with its links followed.
    public var readRoot: String? { read?.resolved }
    /// The write root, absolute with its links followed.
    public var writeRoot: String? { write?.resolved }

    /// May the file or folder at `path` be read (or written)? The error says why not.
    public func check(_ path: String, _ access: Access) throws(FileAccessError) {
        guard let root = access == .read ? read : write else {
            let kind = access == .read ? "read" : "write"
            throw FileAccessError("automation filesystem access is not granted: \(kind) authority is absent: \(path)")
        }
        let resolved = try FileAccess.resolve(path)
        if FileAccess.inside(resolved, root.resolved) { return }
        let kind = access == .read ? "read" : "write"
        throw FileAccessError("automation path rejected: outside the \(kind) root \(root.resolved): \(path)")
    }
}

public struct FileAccessError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum FileAccess {
    /// Where the roots are in force on this task or thread.
    enum Scope: Sendable {
        case confined(AutomationRoots)
        case unconfined
    }

    @TaskLocal static var scope: Scope?

    private static let processLock = NSLock()
    nonisolated(unsafe) private static var processRoots: AutomationRoots?

    /// Put `roots` in force in the whole process, for good. False when roots were in force already (they
    /// stay as they were).
    @discardableResult
    public static func confineProcess(_ roots: AutomationRoots) -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        if processRoots != nil { return false }
        processRoots = roots
        return true
    }

    /// Run `f` with `roots` in force here (nil: as things stand).
    public static func confine<T>(_ roots: AutomationRoots?, _ f: () throws -> T) rethrows -> T {
        guard let roots else { return try f() }
        return try $scope.withValue(.confined(roots)) { try f() }
    }

    /// Run `f` with no roots in force here: what the person at the keyboard does, and the app's own
    /// folders.
    public static func unconfined<T>(_ f: () throws -> T) rethrows -> T {
        try $scope.withValue(.unconfined) { try f() }
    }

    /// The roots in force here, if any.
    public static func current() -> AutomationRoots? {
        switch scope {
        case .confined(let r): return r
        case .unconfined: return nil
        case nil:
            processLock.lock()
            defer { processLock.unlock() }
            return processRoots
        }
    }

    /// May `path` be read here? Always, without roots in force.
    public static func checkRead(_ path: String) throws(FileAccessError) {
        try current()?.check(path, .read)
    }

    /// May `path` be written here? Always, without roots in force.
    public static func checkWrite(_ path: String) throws(FileAccessError) {
        try current()?.check(path, .write)
    }

    // MARK: Paths

    struct OSError: Error {
        var code: Int32
        var message: String { "\(String(cString: strerror(code))) (os error \(code))" }
    }

    /// `std::fs::canonicalize` (realpath).
    static func canonicalize(_ path: String) -> Result<String, OSError> {
        guard !path.isEmpty else { return .failure(OSError(code: ENOENT)) }
        guard let p = realpath(path, nil) else { return .failure(OSError(code: errno)) }
        defer { free(p) }
        return .success(String(cString: p))
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// `std::path::absolute` on Unix: joined to the working directory, `.` components and repeated
    /// separators dropped, `..` kept.
    static func absolute(_ path: String) -> String {
        var base = path
        if !path.hasPrefix("/") {
            let cwd = FileManager.default.currentDirectoryPath
            base = cwd + "/" + path
        }
        let parts = base.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` made absolute with its links followed; for a path that doesn't exist (yet), its nearest
    /// existing folder's links followed and the rest appended.
    static func resolve(_ path: String) throws(FileAccessError) -> String {
        if path.isEmpty { throw FileAccessError("automation path rejected: path is empty") }
        var at = absolute(path)
        var missing: [String] = []
        while true {
            switch canonicalize(at) {
            case .success(let found):
                var out = found
                for name in missing.reversed() { out += (out.hasSuffix("/") ? "" : "/") + name }
                return out
            case .failure(let e):
                var st = stat()
                if lstat(at, &st) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFLNK {
                        throw FileAccessError("automation path rejected: a link that leads nowhere: \(path)")
                    }
                    // There, yet its real path can't be had (no permission): nothing to compare.
                    throw FileAccessError("automation path rejected: cannot resolve \(path): \(e.message)")
                }
                let code = errno
                if code != ENOENT {
                    throw FileAccessError("automation path rejected: cannot resolve \(path): \(OSError(code: code).message)")
                }
            }
            var comps = at.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let last = comps.popLast() else {
                throw FileAccessError("automation path rejected: cannot resolve \(path): \(OSError(code: ENOENT).message)")
            }
            if last == ".." {
                throw FileAccessError("automation path rejected: parent traversal below a folder that doesn't exist: \(path)")
            }
            missing.append(last)
            at = "/" + comps.joined(separator: "/")
        }
    }

    /// Is `path` (resolved) `root` or inside it, component by component?
    static func inside(_ path: String, _ root: String) -> Bool {
        let p = path.split(separator: "/", omittingEmptySubsequences: true)
        let r = root.split(separator: "/", omittingEmptySubsequences: true)
        guard p.count >= r.count else { return false }
        return zip(p, r).allSatisfy { Array($0.utf8) == Array($1.utf8) }
    }

    /// A Windows device name (`CON`, `NUL`, `COM1`… also with an extension), which names no file.
    static func isDeviceName(_ component: String) -> Bool {
        let first = component.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? component
        var stem = first
        while stem.hasSuffix(" ") { stem.removeLast() }
        stem = String(String.UnicodeScalarView(stem.unicodeScalars.map { ("a" ... "z").contains($0) ? Unicode.Scalar($0.value - 32) ?? $0 : $0 }))
        func numbered(_ prefix: String) -> Bool {
            guard stem.hasPrefix(prefix) else { return false }
            let n = Array(stem.unicodeScalars.dropFirst(prefix.unicodeScalars.count))
            return n.count == 1 && ("1" ... "9").contains(n[0])
        }
        return ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"].contains(stem) || numbered("COM") || numbered("LPT")
    }
}
