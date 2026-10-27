// DCAutomation — where MCP tool calls end up: a control-channel method call, answered in process
// (`Headless`) or by a running DeckCraft app over its loopback control port (`Remote`).
// Port of deckcraft crates/mcp/src/backend.rs and lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors), on BSD sockets.
import DCCore
import DCEngine
import Darwin
import Foundation

/// A failed control-channel call: the message deckcraft's `Err(String)` carries.
public struct AutomationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Something that answers control-channel methods (`engine.execute`, `document.inspect`, `ui.pointer`,
/// `ui.render`, …). Implementations are used from one thread at a time (an `EngineThread`).
public protocol Backend: AnyObject {
    /// Call one method: its `result`, or the error message.
    func call(_ method: String, _ params: JSON) throws(AutomationError) -> JSON
    /// True when a real UI is attached (`ui.screenshot`, `ui.click`, dialogs… work).
    var hasUI: Bool { get }
    /// Short human description ("headless", "connected to 127.0.0.1:7979").
    func describe() -> String
}

public enum Automation {
    /// Default control-channel port of the desktop app.
    public static let defaultPort: UInt16 = 7979

    /// `"7979"` → `"127.0.0.1:7979"`; `"host:port"` is kept as is.
    public static func controlAddr(_ s: String) -> String {
        RustParse.u16(s) != nil ? "127.0.0.1:\(s)" : s
    }
}

/// Rust's `str::parse` for the integer types the command line reads: an optional `+`, ASCII digits, no
/// whitespace, in range.
public enum RustParse {
    public static func u64(_ s: String) -> UInt64? {
        var digits = Substring(s)
        if digits.hasPrefix("+") { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return UInt64(digits)
    }

    public static func u16(_ s: String) -> UInt16? { u64(s).flatMap { UInt16(exactly: $0) } }

    /// `usize`: a 64-bit unsigned value; one above `Int.max` saturates (it is out of range anyway).
    public static func usize(_ s: String) -> Int? { u64(s).map { Int(exactly: $0) ?? Int.max } }
}

// MARK: - std::io::Error, as Rust prints it

/// An I/O failure as Rust's `io::Error` displays it: an OS error is `"<strerror> (os error N)"`, a
/// custom one its message.
public struct IOFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// The OS error number, when there is one.
    public var code: Int32?

    public init(_ message: String) {
        self.message = message
        code = nil
    }

    public init(os code: Int32) {
        message = "\(String(cString: strerror(code))) (os error \(code))"
        self.code = code
    }

    /// The current `errno`.
    public static var current: IOFailure { IOFailure(os: errno) }

    public var description: String { message }
}

// MARK: - Loopback TCP

/// BSD-socket plumbing with the behaviours `TcpStream` gives deckcraft: address resolution as
/// `ToSocketAddrs` for a string does it, connect deadlines, read timeouts, no SIGPIPE.
enum Sockets {
    /// `ToSocketAddrs for str`: a literal `ip:port` (or `[ip6]:port`), else `host:port` looked up.
    static func resolve(_ addr: String) throws(IOFailure) -> [Data] {
        guard let colon = addr.lastIndex(of: ":") else { throw IOFailure("invalid socket address") }
        var host = String(addr[..<colon])
        let portText = String(addr[addr.index(after: colon)...])
        guard let port = RustParse.u16(portText) else { throw IOFailure("invalid port value") }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        if rc != 0 {
            throw IOFailure("failed to lookup address information: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }
        var out: [Data] = []
        var p = res
        while let ai = p {
            if let a = ai.pointee.ai_addr { out.append(Data(bytes: a, count: Int(ai.pointee.ai_addrlen))) }
            p = ai.pointee.ai_next
        }
        return out
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `TcpStream::connect_timeout`.
    static func connect(_ address: Data, timeout: Double) throws(IOFailure) -> Int32 {
        let family: Int32 = address.withUnsafeBytes { raw in
            raw.baseAddress.map { Int32($0.assumingMemoryBound(to: sockaddr.self).pointee.sa_family) } ?? AF_INET
        }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .current }
        noSigPipe(fd)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = address.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.connect(fd, base.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
        }
        if rc != 0 {
            let e = errno
            guard e == EINPROGRESS else {
                Darwin.close(fd)
                throw IOFailure(os: e)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000).rounded(.up))
                let n = poll(&pfd, 1, ms)
                if n < 0 && errno == EINTR { continue }
                if n == 0 {
                    Darwin.close(fd)
                    throw IOFailure("connection timed out")
                }
                if n < 0 {
                    let e = errno
                    Darwin.close(fd)
                    throw IOFailure(os: e)
                }
                break
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                Darwin.close(fd)
                throw IOFailure(os: err)
            }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setNoDelay(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `write_all`.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws(IOFailure) {
        var failure: IOFailure?
        bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress?.advanced(by: done), raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = .current
                    return
                }
                if n == 0 {
                    failure = IOFailure("failed to write whole buffer")
                    return
                }
                done += n
            }
        }
        if let failure { throw failure }
    }
}

/// A connected socket with its read buffer (Rust's `BufReader<TcpStream>` and the cloned writer).
final class Connection {
    let fd: Int32
    /// Bytes read past the last line.
    var buffer: [UInt8] = []

    init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }

    /// Reads into the buffer; the count read, 0 at the end.
    func fill() throws(IOFailure) -> Int {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw .current
            }
            buffer.append(contentsOf: chunk[0 ..< n])
            return n
        }
    }

    /// `take(limit).read_until(b'\n')`: the bytes up to and including the first newline, at most `limit`
    /// of them; fewer (no newline) at the end of the stream.
    func readUntilNewline(limit: Int) throws(IOFailure) -> [UInt8] {
        var scanned = 0
        while true {
            if let i = buffer[scanned...].firstIndex(of: 0x0A), i < limit {
                let line = Array(buffer[...i])
                buffer.removeFirst(i + 1)
                return line
            }
            if buffer.count >= limit {
                let line = Array(buffer[..<limit])
                buffer.removeFirst(limit)
                return line
            }
            scanned = buffer.count
            if try fill() == 0 {
                let line = buffer
                buffer = []
                return line
            }
        }
    }
}

/// A running DeckCraft app, reached through its loopback control port.
public final class Remote: Backend {
    /// Includes the newline, matching the control server's request budget. In particular a peer must
    /// not be able to grow a reply indefinitely by withholding its newline.
    static let maxReplyBytes = 16 * 1024 * 1024

    public let addr: String
    var conn: Connection?
    var nextId: UInt64 = 1

    private init(addr: String) { self.addr = addr }

    /// Connect to `addr` (`127.0.0.1:7979`), failing fast when nothing is listening.
    public static func connect(_ addr: String) throws(IOFailure) -> Remote {
        let r = Remote(addr: addr)
        try r.reconnect()
        return r
    }

    func reconnect() throws(IOFailure) {
        conn = nil
        var last = IOFailure("cannot resolve \(addr)")
        for sa in try Sockets.resolve(addr) {
            do {
                let fd = try Sockets.connect(sa, timeout: 0.8)
                Sockets.setNoDelay(fd)
                // The app answers within 60 s (its own timeout); leave headroom.
                Sockets.setReadTimeout(fd, seconds: 90)
                conn = Connection(fd: fd)
                return
            } catch {
                last = error
            }
        }
        throw last
    }

    /// Write one request line. A failure here means the app never got a complete line, so retrying is
    /// safe. A connection the app has already closed (it restarted since the last call) is replaced
    /// before writing.
    func send(_ line: String) throws(IOFailure) {
        if conn.map({ !$0.buffer.isEmpty || Remote.isClosed($0.fd) }) ?? true {
            try reconnect()
        }
        guard let c = conn else { throw IOFailure("not connected") }
        try Sockets.writeAll(c.fd, Array("\(line)\n".utf8))
    }

    /// Read the reply to a request that was already sent: the app's result or error message, or an I/O
    /// failure that leaves the outcome unknown.
    func receive(_ id: UInt64) throws(IOFailure) -> Result<JSON, AutomationError> {
        guard let c = conn else { throw IOFailure("not connected") }
        let reply = try c.readUntilNewline(limit: Remote.maxReplyBytes + 1)
        if reply.count > Remote.maxReplyBytes { throw IOFailure("control reply exceeds 16 MiB") }
        if reply.last != 0x0A { throw IOFailure("control reply has no terminating newline") }
        let v: JSON
        do { v = try JSONParser.parse(reply).canonical } catch { throw IOFailure("bad reply from app: \(error)") }
        if v.get("id")?.asU64 != id { throw IOFailure("control reply has an unexpected request id") }
        switch v.get("ok")?.asBool {
        case true? where v.get("error") == nil:
            guard let r = v.get("result") else { throw IOFailure("successful control reply has no result") }
            return .success(r)
        case false? where v.get("result") == nil:
            guard let e = v.get("error")?.asStr else { throw IOFailure("failed control reply has no error string") }
            return .failure(AutomationError(e))
        default:
            throw IOFailure("control reply has an invalid envelope")
        }
    }

    /// True when the peer has closed or reset the socket, or sent bytes nobody asked for. Between calls
    /// nothing should be waiting, so only "would block" means the connection is still good.
    static func isClosed(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 { return true }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK)
        let open = n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
        return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0 || !open
    }

    public func call(_ method: String, _ params: JSON) throws(AutomationError) -> JSON {
        let id = nextId
        nextId += 1
        let line = JSON.object(JSONObject(["id": .uint(id), "method": .string(method), "params": params])).display
        // One retry with a fresh connection (the app may have restarted), but only while the request was
        // not sent. Once it is out, a lost reply leaves the outcome unknown and a resend could run an
        // insert/delete/undo twice, so report that instead.
        do {
            try send(line)
        } catch {
            conn = nil
            do {
                try send(line)
            } catch {
                conn = nil
                throw AutomationError("DeckCraft app at \(addr) is not reachable: \(error)")
            }
        }
        let outcome: Result<JSON, AutomationError>
        do {
            outcome = try receive(id)
        } catch {
            conn = nil
            throw AutomationError("lost the reply from the DeckCraft app at \(addr) (\(error)); the command may or may not have run, check the document before retrying")
        }
        return try outcome.get()
    }

    public var hasUI: Bool { true }

    public func describe() -> String { "connected to the DeckCraft app at \(addr)" }
}
