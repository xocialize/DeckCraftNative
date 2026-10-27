// DCAutomationTests — the connected backend against a fake app on a loopback socket. Port of the tests in
// deckcraft crates/mcp/src/backend.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
@testable import DCAutomation
import Darwin
import Foundation
import Synchronization
import Testing

/// A loopback listener on a free port (`TcpListener::bind("127.0.0.1:0")`).
final class TestListener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw IOFailure.current
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    var addr: String { "127.0.0.1:\(port)" }

    /// The next connection.
    func accept() -> TestStream? {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return TestStream(fd: c)
    }

    deinit { close(fd) }
}

/// One accepted connection, read a line at a time.
final class TestStream: @unchecked Sendable {
    let fd: Int32
    var buffer: [UInt8] = []
    init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    /// A line with its newline; "" at the end of the stream.
    func readLine() -> String {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[...i])
                buffer.removeFirst(i + 1)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                let rest = buffer
                buffer = []
                return String(decoding: rest, as: UTF8.self)
            }
            buffer.append(contentsOf: chunk[0 ..< n])
        }
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress?.advanced(by: done), bytes.count - done, 0) }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    func write(_ s: String) { write(Array(s.utf8)) }
}

/// Runs `body` on a thread of its own; `join` waits for it.
final class Peer<T>: @unchecked Sendable {
    private var result: T?
    private let done = DispatchSemaphore(value: 0)

    init(_ body: @escaping @Sendable () -> T) {
        let t = Thread { [self] in
            result = body()
            done.signal()
        }
        t.start()
    }

    func join() -> T? {
        done.wait()
        return result
    }
}

/// A fake app that reads one request, checks its id is 1, and answers `reply`.
func replyOnce(_ reply: [UInt8]) throws -> (Remote, Peer<Void>) {
    let listener = try TestListener()
    let peer = Peer<Void> {
        guard let stream = listener.accept() else { return }
        let line = stream.readLine()
        #expect((try? JSONParser.parse(line))?.get("id")?.asU64 == 1)
        // An oversized reply may be rejected before the peer finishes writing it.
        stream.write(reply)
    }
    return (try Remote.connect(listener.addr), peer)
}

@Suite("Connected backend (deckcraft-mcp backend.rs)", .serialized)
struct RemoteTests {
    @Test func wrongReplyIdIsNotCommandSuccess() throws {
        let (remote, peer) = try replyOnce(Array("{\"id\":999,\"ok\":true,\"result\":\"unrelated\"}\n".utf8))
        let result = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", ["command": "slide.new"]) }
        _ = peer.join()
        guard case .failure(let error) = result else {
            Issue.record("an unrelated reply cannot confirm a mutation")
            return
        }
        #expect(error.message.contains("may or may not have run"), "\(error)")
        #expect(remote.conn == nil, "discard the invalid connection without replaying")
    }

    @Test func matchingSuccessAndErrorRepliesKeepTheirMeaning() throws {
        let cases: [(String, Result<JSON, AutomationError>)] = [
            ("{\"id\":1,\"ok\":true,\"result\":null}\r\n", .success(.null)),
            ("{\"id\":1,\"ok\":true,\"result\":{\"slides\":2}}\n", .success(j(#"{"slides":2}"#))),
            ("{\"id\":1,\"ok\":false,\"error\":\"disabled\"}\n", .failure(AutomationError("disabled"))),
        ]
        for (reply, expected) in cases {
            let (remote, peer) = try replyOnce(Array(reply.utf8))
            let got = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", .emptyObject) }
            #expect(got == expected, "\(reply)")
            #expect(remote.conn != nil, "valid responses do not invalidate the connection")
            _ = peer.join()
        }
    }

    @Test func malformedReplyEnvelopesLeaveTheOutcomeUnknown() throws {
        for reply in [
            "not JSON\n",
            "[]\n",
            "{\"ok\":true,\"result\":null}\n",
            "{\"id\":\"1\",\"ok\":true,\"result\":null}\n",
            "{\"id\":1,\"ok\":1,\"result\":null}\n",
            "{\"id\":1,\"ok\":true}\n",
            "{\"id\":1,\"ok\":false}\n",
            "{\"id\":1,\"ok\":false,\"error\":42}\n",
            "{\"id\":1,\"ok\":true,\"result\":null,\"error\":\"failed\"}\n",
            "{\"id\":1,\"ok\":false,\"result\":null,\"error\":\"failed\"}\n",
        ] {
            let (remote, peer) = try replyOnce(Array(reply.utf8))
            let result = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", .emptyObject) }
            _ = peer.join()
            guard case .failure(let error) = result else {
                Issue.record("\(reply): accepted")
                continue
            }
            #expect(error.message.contains("may or may not have run"), "\(reply): \(error)")
            #expect(remote.conn == nil, "\(reply): discard the invalid connection")
        }
    }

    @Test func eofWithoutANewlineIsNotACompleteReply() throws {
        let (remote, peer) = try replyOnce(Array("{\"id\":1,\"ok\":true,\"result\":null}".utf8))
        let result = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", .emptyObject) }
        _ = peer.join()
        #expect((try? result.get()) == nil, "a truncated frame cannot confirm a mutation")
        #expect(remote.conn == nil)
    }

    @Test func oversizedReplyIsRejected() throws {
        let reply = "{\"id\":1,\"ok\":true,\"result\":\"\(String(repeating: "x", count: 16 * 1024 * 1024))\"}\n"
        let (remote, peer) = try replyOnce(Array(reply.utf8))
        let result = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", .emptyObject) }
        let invalidated = remote.conn == nil
        // Close the socket before joining: the bounded reader need not drain the peer's reply.
        remote.conn = nil
        _ = peer.join()
        guard case .failure(let error) = result else {
            Issue.record("a reply is limited to 16 MiB")
            return
        }
        #expect(error.message.contains("may or may not have run"), "\(error)")
        #expect(invalidated, "discard the oversized reply's connection")
    }

    @Test func replyAtTheSizeLimitIsAccepted() throws {
        let prefix = "{\"id\":1,\"ok\":true,\"result\":\"", suffix = "\"}\n"
        let payloadLen = 16 * 1024 * 1024 - prefix.utf8.count - suffix.utf8.count
        let (remote, peer) = try replyOnce(Array((prefix + String(repeating: "x", count: payloadLen) + suffix).utf8))
        let result = try remote.call("document.inspect", .emptyObject)
        #expect(result.asStr?.utf8.count == payloadLen)
        _ = peer.join()
    }

    @Test func bufferedUnsolicitedReplyIsDiscardedBeforeSending() throws {
        let listener = try TestListener()
        let peer = Peer<Bool> {
            guard let first = listener.accept() else { return true }
            _ = first.readLine()
            // Even a stale frame whose ID happens to match must not answer a new request.
            first.write("{\"id\":1,\"ok\":true,\"result\":\"first\"}\n{\"id\":2,\"ok\":true,\"result\":\"stale\"}\n")
            let sentOnStale = !first.readLine().isEmpty
            if !sentOnStale, let fresh = listener.accept() {
                _ = fresh.readLine()
                fresh.write("{\"id\":2,\"ok\":false,\"error\":\"rejected\"}\n")
            }
            return sentOnStale
        }
        let remote = try Remote.connect(listener.addr)
        #expect((try? remote.call("document.inspect", .emptyObject)) == "first")
        // Force the stale frame into the read buffer, where a socket-only peek cannot see it.
        if let c = remote.conn, c.buffer.isEmpty { _ = try c.fill() }
        #expect(remote.conn?.buffer.isEmpty == false)
        let result = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", ["command": "slide.new"]) }
        let sentOnStale = peer.join() ?? true
        #expect(result == .failure(AutomationError("rejected")), "only the fresh peer's response counts")
        #expect(!sentOnStale, "replace a connection with buffered unsolicited bytes before sending")
    }

    @Test func lostReplyIsNotResent() throws {
        let listener = try TestListener()
        let counter = UnsafeCounter()
        _ = Peer<Void> {
            while let stream = listener.accept() {
                if stream.readLine().isEmpty { continue }
                let n = counter.increment()
                if n > 1 { stream.write("{\"id\":2,\"ok\":true,\"result\":null}\n") }
                // The first request is executed, then the connection drops without a reply.
                if n >= 2 { return }
            }
        }
        let remote = try Remote.connect(listener.addr)
        let first = Result { () throws(AutomationError) -> JSON in try remote.call("engine.execute", .emptyObject) }
        guard case .failure(let err) = first else {
            Issue.record("lost reply must be an error")
            return
        }
        #expect(err.message.contains("may or may not have run"), "\(err)")
        #expect(counter.value == 1, "the command must not be replayed")
        // The next call opens a fresh connection and works.
        #expect((try? remote.call("document.inspect", .emptyObject)) != nil)
        #expect(counter.value == 2)
    }

    @Test func connectionClosedBeforeTheCallIsRetried() throws {
        let listener = try TestListener()
        let closed = DispatchSemaphore(value: 0)
        let counter = UnsafeCounter()
        _ = Peer<Void> {
            // The app restarts: the first connection closes before any request arrives.
            if let first = listener.accept() { _ = first }
            closed.signal()
            while let stream = listener.accept() {
                if stream.readLine().isEmpty { continue }
                _ = counter.increment()
                stream.write("{\"id\":1,\"ok\":true,\"result\":null}\n")
                return
            }
        }
        let remote = try Remote.connect(listener.addr)
        closed.wait()
        Thread.sleep(forTimeInterval: 0.2)
        #expect((try? remote.call("engine.execute", .emptyObject)) != nil, "a request that never left must be sent on a fresh connection")
        #expect(counter.value == 1)
    }

    @Test func controlAddressesAndUnreachableApps() {
        #expect(Automation.controlAddr("7979") == "127.0.0.1:7979")
        #expect(Automation.controlAddr("host:1") == "host:1")
        #expect(Automation.controlAddr("70000") == "70000")
        // Rust's `ToSocketAddrs` messages for what can't be an address.
        for (addr, message) in [("nohost", "invalid socket address"), ("h:x", "invalid port value")] {
            do {
                _ = try Remote.connect(addr)
                Issue.record("\(addr) connected")
            } catch {
                #expect(error.message == message)
            }
        }
    }
}

/// A shared counter for a peer thread and the test.
final class UnsafeCounter: @unchecked Sendable {
    let atomic = Atomic<Int>(0)
    func increment() -> Int { atomic.add(1, ordering: .sequentiallyConsistent).newValue }
    var value: Int { atomic.load(ordering: .sequentiallyConsistent) }
}
