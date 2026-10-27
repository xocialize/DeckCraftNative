// DCAutomation — the app's loopback control server: JSON lines in, one reply per line out. This is the
// transport `deckcraft-cli mcp --connect` and `deckcraft-cli app` (`Remote`) talk to. Port of deckcraft
// apps/deckcraft/src/control_server.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), on BSD sockets as `Remote` is: per-socket read and write timeouts (`SO_RCVTIMEO`,
// `SO_SNDTIMEO`) give Rust's `set_read_timeout` / `set_write_timeout` exactly, and a half-close
// (`shutdown(SHUT_WR)`) followed by a bounded drain is Rust's polite close.
//
// The server only reads requests: a line that is not a JSON object with a string `method` (an HTTP request
// line, a stray `nc`, binary data) gets one error reply and the connection is closed, so nothing sent after
// it runs. Every resource a client can hold is bounded (`ControlServer.Limits`): simultaneous connections,
// request line length, queued requests, and how long a socket may sit idle or blocked on a write.
//
// The server answers nothing itself: each request goes into a bounded queue (Rust's `sync_channel`) that
// the app drains on its main thread (`tryReceive`), after the server's `wake` callback (egui's
// `request_repaint`) says there is something to drain.
import DCCore
import DCEngine
import Darwin
import Foundation
import Synchronization

/// A loopback (127.0.0.1) JSON-lines control server. Requests come out of `tryReceive` / `receive`; answer
/// each with `ControlRequest.take`, `Control.handle` and `reply.send`.
public final class ControlServer: Sendable {
    /// Resource bounds for the control server (Rust's `Limits`).
    public struct Limits: Sendable, Equatable {
        /// Connections served at once; more are told `busy` and closed.
        public var maxClients: Int
        /// Longest request line in bytes (newline excluded); a longer one closes the connection.
        public var maxLine: Int
        /// Requests waiting for the UI at once; more are answered `busy`.
        public var queue: Int
        /// How long a connection may go without sending a byte before it is closed.
        public var idleTimeout: Duration
        /// How long a reply write may block before the connection is closed.
        public var writeTimeout: Duration
        /// How long a request waits for the UI's answer.
        public var replyTimeout: Duration

        /// deckcraft's defaults. Picture and media inserts carry base64 payloads: 256 MiB lines leave room
        /// for files of about 190 MB.
        public init(
            maxClients: Int = 16, maxLine: Int = 256 * 1024 * 1024, queue: Int = 64,
            idleTimeout: Duration = .seconds(600), writeTimeout: Duration = .seconds(30), replyTimeout: Duration = .seconds(60)
        ) {
            self.maxClients = maxClients
            self.maxLine = maxLine
            self.queue = queue
            self.idleTimeout = idleTimeout
            self.writeTimeout = writeTimeout
            self.replyTimeout = replyTimeout
        }
    }

    /// How long the accepting thread waits after a failed accept. Accepting can keep failing, for example
    /// while the process has no file descriptors left, and retrying at once would keep a core busy until it
    /// recovers.
    static let acceptRetry: Duration = .milliseconds(100)
    /// The longest a connection refused as busy is drained before it is closed.
    static let refusedGrace: Duration = .milliseconds(250)
    /// Refused connections drained at once, each on a thread of its own. Past this many, a refused
    /// connection gets the busy reply and is closed without a drain.
    static let maxRefusing = 16
    /// What a polite close drains at most: enough for a pipelined line or two.
    static let maxDrain = 64 << 10

    /// The port the server listens on (the one asked for, or the one the system chose for 0).
    public let port: UInt16
    public let limits: Limits
    let queue: ControlQueue
    let state: ServerState

    /// Bind 127.0.0.1:`port` (0 for any free port) and start accepting. `wake` is called, on a connection's
    /// thread, after each request is queued: the app schedules a drain of `tryReceive` on its main thread.
    /// Throws when the port can't be bound; deckcraft then logs
    /// `control server failed to bind 127.0.0.1:{port}: {error}` and runs without a control channel.
    public init(port: UInt16, limits: Limits = Limits(), wake: @escaping @Sendable () -> Void = {}) throws(IOFailure) {
        let (listener, bound) = try ControlServer.bindLoopback(port)
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            let e = IOFailure.current
            Darwin.close(listener)
            throw e
        }
        for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        self.port = bound
        self.limits = limits
        queue = ControlQueue(capacity: max(limits.queue, 1))
        state = ServerState(wakeRead: ends[0], wakeWrite: ends[1])
        let (state, queue) = (state, queue)
        ControlServer.spawn("control-accept") {
            ControlServer.acceptLoop(listener, state: state, queue: queue, limits: limits, wake: wake)
        }
    }

    deinit { stop() }

    /// The next queued request, without waiting; nil when none is queued. The app's main thread drains
    /// these (deckcraft's `SlideApp::drain_control`).
    public func tryReceive() -> ControlRequest? { queue.tryReceive() }

    /// The next queued request, waiting up to `timeout` (for ever when nil); nil when none came or the
    /// server stopped.
    public func receive(timeout: Duration? = nil) -> ControlRequest? {
        queue.receive(until: timeout.map { Date().addingTimeInterval(ControlServer.seconds($0)) })
    }

    /// Stop accepting, close every connection and drop the queued requests (their senders give up at their
    /// reply timeout). Idempotent.
    public func stop() {
        guard state.stop() else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(state.wakeWrite, &byte, 1)
        queue.close()
    }

    // MARK: - Accepting

    /// The connections `incoming` accepts, calling `wait` after each failed accept.
    static func accepted<T, E: Error>(_ incoming: some Sequence<Result<T, E>>, wait: @escaping () -> Void) -> some Sequence<T> {
        incoming.lazy.compactMap { r -> T? in
            switch r {
            case .success(let v): return v
            case .failure:
                wait()
                return nil
            }
        }
    }

    /// `TcpListener::bind(("127.0.0.1", port))`: `SO_REUSEADDR`, close-on-exec, the system's backlog.
    static func bindLoopback(_ port: UInt16) throws(IOFailure) -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .current }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
            let e = IOFailure.current
            Darwin.close(fd)
            throw e
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else {
            let e = IOFailure.current
            Darwin.close(fd)
            throw e
        }
        // Non-blocking, so a connection that goes away between `poll` and `accept` can't block the loop.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// The next accepted connection or failed accept; nil once the server stops.
    static func nextConnection(_ listener: Int32, _ state: ServerState) -> Result<Int32, IOFailure>? {
        while true {
            if state.isStopped { return nil }
            var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: state.wakeRead, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, -1)
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(.current)
            }
            if fds[1].revents != 0 { return nil }
            if fds[0].revents == 0 { continue }
            let c = accept(listener, nil, nil)
            if c >= 0 {
                // An accepted socket inherits the listener's O_NONBLOCK on Darwin; Rust's streams block.
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                Sockets.noSigPipe(c)
                return .success(c)
            }
            let e = errno
            if e == EINTR || e == EAGAIN || e == EWOULDBLOCK { continue }
            return .failure(IOFailure(os: e))
        }
    }

    static func acceptLoop(_ listener: Int32, state: ServerState, queue: ControlQueue, limits: Limits, wake: @escaping @Sendable () -> Void) {
        defer { Darwin.close(listener) }
        let incoming = IteratorSequence(AnyIterator { nextConnection(listener, state) })
        for fd in accepted(incoming, wait: { Thread.sleep(forTimeInterval: seconds(acceptRetry)) }) {
            _ = setTimeout(fd, SO_SNDTIMEO, limits.writeTimeout)
            if state.active.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue >= limits.maxClients {
                state.active.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                _ = try? Sockets.writeAll(fd, line(["ok": false, "error": "busy: too many control connections"]))
                refuse(fd, state, grace: min(limits.writeTimeout, refusedGrace))
                continue
            }
            guard state.register(fd) else {
                state.active.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                Darwin.close(fd)
                continue
            }
            spawn("control-client") {
                defer {
                    state.unregisterAndClose(fd)
                    state.active.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                }
                serve(fd, queue: queue, limits: limits, wake: wake)
            }
        }
    }

    /// Close a connection that was told it is refused. A peer that wrote a line before it read the reply
    /// would see only a reset, so the connection is drained for up to `grace` first, on a thread of its
    /// own: the accepting thread goes straight back to accepting. Past `maxRefusing` drains at once, the
    /// connection is closed without one.
    static func refuse(_ fd: Int32, _ state: ServerState, grace: Duration) {
        if state.refusing.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue >= maxRefusing {
            state.refusing.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            Darwin.close(fd)
            return
        }
        spawn("control-refused") {
            defer {
                Darwin.close(fd)
                state.refusing.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
            ControlStream(fd).closePolitely(grace: grace)
        }
    }

    // MARK: - Serving one connection

    /// One request line, parsed.
    enum Parsed: Equatable {
        case request(id: JSON, method: String, params: JSON)
        case blank
        /// Not a request: reply with this error and close the connection.
        case reject(String)
    }

    static func parse(_ bytes: [UInt8]) -> Parsed {
        guard let decoded = String(validating: bytes, as: UTF8.self) else {
            return .reject("not a control request (invalid UTF-8); closing the connection")
        }
        let text = trimmed(decoded)
        if text.isEmpty { return .blank }
        if isHTTPRequestLine(text) {
            return .reject("HTTP is not served here: this port takes JSON lines; closing the connection")
        }
        let msg: JSON
        do {
            // A serde_json `Value`: of duplicate keys, the last.
            msg = try JSONParser.parse(text).canonical
        } catch {
            return .reject("bad JSON (\(error)); expected one JSON request object per line; closing the connection")
        }
        guard let obj = msg.asObject else {
            return .reject("not a control request (expected a JSON object); closing the connection")
        }
        guard let method = obj["method"]?.asStr else {
            return .reject("not a control request (missing string `method`); closing the connection")
        }
        return .request(id: obj["id"] ?? .null, method: method, params: obj["params"] ?? .emptyObject)
    }

    /// `str::trim`: Unicode White_Space removed from both ends, scalar by scalar.
    static func trimmed(_ s: String) -> String {
        let u = s.unicodeScalars
        guard let a = u.firstIndex(where: { !$0.properties.isWhitespace }), let b = u.lastIndex(where: { !$0.properties.isWhitespace }) else {
            return ""
        }
        return String(u[a ... b])
    }

    /// An HTTP/1 request line (`POST / HTTP/1.1`) or the HTTP/2 preface (`PRI * HTTP/2.0`).
    static func isHTTPRequestLine(_ text: String) -> Bool {
        let methods = ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH", "PRI"]
        let b = Array(text.utf8)
        if let i = b.firstIndex(of: 0x20), methods.contains(where: { Array($0.utf8) == Array(b[..<i]) }) { return true }
        if let j = b.lastIndex(of: 0x20), b[(j + 1)...].starts(with: "HTTP/".utf8) { return true }
        return false
    }

    static func serve(_ fd: Int32, queue: ControlQueue, limits: Limits, wake: @Sendable () -> Void) {
        guard setTimeout(fd, SO_RCVTIMEO, limits.idleTimeout), setTimeout(fd, SO_SNDTIMEO, limits.writeTimeout) else { return }
        let stream = ControlStream(fd)
        while true {
            let text: [UInt8]
            switch stream.readLine(max: limits.maxLine) {
            case .text(let t): text = t
            case .tooLong:
                _ = try? Sockets.writeAll(fd, line(["ok": false, "error": .string("request line longer than \(limits.maxLine) bytes")]))
                stream.closePolitely(grace: limits.writeTimeout)
                return
            case .closed: return
            }
            var reply: JSON
            switch parse(text) {
            case .blank: continue
            case .reject(let e):
                // The connection closes either way, but the peer is told why first: see `closePolitely`,
                // without which a peer that had pipelined another line had this reply reset away.
                _ = try? Sockets.writeAll(fd, line(["ok": false, "error": .string(e)]))
                stream.closePolitely(grace: limits.writeTimeout)
                return
            case .request(let id, let method, let params):
                let (req, answer) = ControlRequest.make(method, params)
                switch queue.trySend(req) {
                case .sent:
                    wake()
                    if let v = answer.wait(timeout: seconds(limits.replyTimeout)) {
                        reply = v
                    } else if ControlRequest.abandon(req.state) {
                        // Given up while still queued: it never runs late (#719).
                        reply = ["ok": false, "error": "timeout"]
                    } else {
                        reply = ["ok": false, "error": "timeout: the app had already started the request, so it may still run; its outcome is unknown"]
                    }
                case .full: reply = ["ok": false, "error": "busy: too many queued requests"]
                case .closed: return
                }
                if case .object(var o) = reply {
                    o.set("id", id)
                    reply = .object(o)
                }
            }
            do { try Sockets.writeAll(fd, line(reply)) } catch { return }
        }
    }

    // MARK: - Plumbing

    /// `writeln!(out, "{value}")`: serde_json's compact form, keys sorted, and a newline.
    static func line(_ v: JSON) -> [UInt8] { Array((v.display + "\n").utf8) }

    static func seconds(_ d: Duration) -> Double {
        let (s, atto) = d.components
        return Double(s) + Double(atto) / 1e18
    }

    /// `set_read_timeout` / `set_write_timeout(Some(d))`: false for a zero duration (Rust's `InvalidInput`)
    /// or a failed `setsockopt`. A duration under a microsecond is one microsecond, as in Rust: a zero
    /// `timeval` would mean no timeout at all.
    static func setTimeout(_ fd: Int32, _ option: Int32, _ d: Duration) -> Bool {
        if d <= .zero { return false }
        let (s, atto) = d.components
        var usec = Int32(atto / 1_000_000_000_000)
        let sec = Int(clamping: s)
        if sec == 0 && usec == 0 { usec = 1 }
        var tv = timeval(tv_sec: sec, tv_usec: usec)
        return setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    static func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let t = Thread(block: body)
        t.name = name
        t.start()
    }
}

// MARK: - Serving a ControlChannel

extension ControlChannel {
    /// Serve this channel's host on a loopback control port as the app serves its window: one consumer takes
    /// the queued requests in order and answers each on the channel's engine thread before taking the next,
    /// skipping abandoned ones. For tests and fake apps (`HeadlessControlHost`); `stop()` the server to end
    /// it. The channel lives as long as the server serves.
    public func serve(port: UInt16 = 0, limits: ControlServer.Limits = ControlServer.Limits()) throws(IOFailure) -> ControlServer {
        let server = try ControlServer(port: port, limits: limits)
        let queue = server.queue
        ControlServer.spawn("control-headless") { [self] in
            while let req = queue.receive(until: nil) {
                let host = host
                _ = engine.sync {
                    guard req.take() else { return }
                    switch Control.handle(host.value, req.method, req.params) {
                    case .done(let v): req.reply.send(v)
                    case .screenshot: req.reply.send(["ok": false, "error": .string("`ui.screenshot`: \(needsApp)")])
                    }
                }
            }
        }
        return server
    }
}

// MARK: - Shared state

/// What the accepting thread, the connection threads and `stop` share.
final class ServerState: Sendable {
    /// Connections being served (Rust's `active`).
    let active = Atomic<Int>(0)
    /// Refused connections being drained.
    let refusing = Atomic<Int>(0)
    /// The self-pipe that wakes the accepting thread on `stop`.
    let wakeRead: Int32
    let wakeWrite: Int32

    private struct Clients {
        var fds: Set<Int32> = []
        var stopped = false
    }

    private let clients = Mutex(Clients())

    init(wakeRead: Int32, wakeWrite: Int32) {
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
    }

    deinit {
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    var isStopped: Bool { clients.withLock { $0.stopped } }

    /// Track a served connection so `stop` can shut it; false once stopped.
    func register(_ fd: Int32) -> Bool {
        clients.withLock { c in
            if c.stopped { return false }
            c.fds.insert(fd)
            return true
        }
    }

    /// Forget and close a served connection, under the lock `stop` shuts connections under, so `stop` never
    /// shuts a descriptor number that was closed and reused.
    func unregisterAndClose(_ fd: Int32) {
        clients.withLock { c in
            c.fds.remove(fd)
            Darwin.close(fd)
        }
    }

    /// Mark stopped and shut every served connection (their blocked reads end); false when already stopped.
    func stop() -> Bool {
        clients.withLock { c in
            if c.stopped { return false }
            c.stopped = true
            for fd in c.fds { _ = shutdown(fd, SHUT_RDWR) }
            return true
        }
    }
}

/// The requests waiting for the app: Rust's `sync_channel(queue)`, a bounded queue whose sender never
/// waits.
final class ControlQueue: @unchecked Sendable {
    enum Sent { case sent, full, closed }

    let capacity: Int
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var items: [ControlRequest] = []
    private var closed = false

    init(capacity: Int) { self.capacity = capacity }

    /// `try_send`: full when `capacity` requests wait, closed once the server stopped.
    func trySend(_ r: ControlRequest) -> Sent {
        condition.lock()
        defer { condition.unlock() }
        if closed { return .closed }
        if items.count >= capacity { return .full }
        items.append(r)
        condition.signal()
        return .sent
    }

    func tryReceive() -> ControlRequest? {
        condition.lock()
        defer { condition.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// Waits until `deadline` (for ever when nil); nil when none came or the queue was closed.
    func receive(until deadline: Date?) -> ControlRequest? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !closed {
            if let deadline {
                if !condition.wait(until: deadline) { break }
            } else {
                condition.wait()
            }
        }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// Drop the queued requests and refuse new ones (Rust's receiver dropped).
    func close() {
        condition.lock()
        closed = true
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Reading lines

/// A served socket's reads (Rust's `BufReader<TcpStream>`). It doesn't own the descriptor.
final class ControlStream {
    enum Line: Equatable {
        case text([UInt8])
        case tooLong
        case closed
    }

    let fd: Int32
    private var buffer: [UInt8] = []
    private var head = 0
    private var chunk = [UInt8](repeating: 0, count: 64 << 10)

    init(_ fd: Int32) { self.fd = fd }

    /// One `read` into the buffer: the count, 0 at the end, nil on an error or timeout.
    private func fill() -> Int? {
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: chunk[0 ..< n])
            return n
        }
    }

    /// One `\n`-terminated line of at most `max` bytes, without holding more than `max + 1` of it
    /// (`take(max + 1).read_until(b'\n')`). A read error or timeout, even mid-line, is `closed`; the end of
    /// the stream inside a line serves what arrived, and the next read is `closed`.
    func readLine(max: Int) -> Line {
        let limit = max < Int.max ? max + 1 : Int.max
        var line: [UInt8] = []
        while true {
            if head == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                head = 0
                guard let n = fill() else { return .closed }
                if n == 0 { return line.isEmpty ? .closed : .text(line) }
            }
            let room = limit - line.count
            let end = buffer.count - head <= room ? buffer.count : head + room
            if let i = buffer[head ..< end].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[head ..< i])
                head = i + 1
                return .text(line)
            }
            line.append(contentsOf: buffer[head ..< end])
            head = end
            if line.count >= limit { return .tooLong }
        }
    }

    /// Close after the last reply so the peer can still read it. A peer that had sent another line before
    /// the reply arrived (two lines in one write, which any script does) leaves input unread in the socket,
    /// and closing a socket with unread input resets the connection: the reply already queued for the peer
    /// is discarded and it sees only the reset. Sending the FIN first and then draining, briefly and
    /// boundedly, makes the close orderly and the reason survive. The read timeout is what is left of the
    /// grace before each read, so a peer trickling bytes can't hold the connection past the deadline.
    func closePolitely(grace: Duration) {
        if shutdown(fd, SHUT_WR) != 0 { return }
        let clock = ContinuousClock()
        let until = clock.now + grace
        var drained = 0
        var sink = [UInt8](repeating: 0, count: 4 << 10)
        while drained < ControlServer.maxDrain {
            let left = until - clock.now
            if left <= .zero || !ControlServer.setTimeout(fd, SO_RCVTIMEO, left) { break }
            if head < buffer.count {
                // What the reader had buffered comes first, as `BufReader::read` serves it.
                let n = min(buffer.count - head, sink.count)
                head += n
                drained += n
                continue
            }
            let n = sink.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            drained += n
        }
    }
}
