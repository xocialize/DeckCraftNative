// DCAutomationTests — the loopback control server. Port of the tests in deckcraft
// apps/deckcraft/src/control_server.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), every one, plus its replies byte for byte and an end-to-end run through `Remote`.
import DCCore
import DCEngine
@testable import DCAutomation
import Darwin
import Foundation
import Synchronization
import Testing

/// Rust's `small()`: limits short enough for tests.
func small(
    maxClients: Int = 2, maxLine: Int = 64, idleTimeout: Duration = .milliseconds(300)
) -> ControlServer.Limits {
    ControlServer.Limits(
        maxClients: maxClients, maxLine: maxLine, queue: 1,
        idleTimeout: idleTimeout, writeTimeout: .milliseconds(300), replyTimeout: .milliseconds(300)
    )
}

/// A server on a free loopback port.
func controlServer(_ limits: ControlServer.Limits) throws -> ControlServer {
    try ControlServer(port: 0, limits: limits)
}

/// A test peer: one socket, read with a 5 s timeout (Rust's `client`). Closed explicitly or when released.
final class ControlPeer {
    let conn: Connection
    private(set) var open = true

    init(_ port: UInt16) throws {
        let addr = try Sockets.resolve("127.0.0.1:\(port)")
        let fd = try Sockets.connect(addr[0], timeout: 5)
        Sockets.setReadTimeout(fd, seconds: 5)
        conn = Connection(fd: fd)
    }

    /// `write_all`; false when it failed.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool { (try? Sockets.writeAll(conn.fd, bytes)) != nil }

    @discardableResult
    func write(_ text: String) -> Bool { write(Array(text.utf8)) }

    /// The next reply line as written, newline included; nil at the end of the stream or on an error.
    func rawReply() -> String? {
        guard let bytes = try? conn.readUntilNewline(limit: 1 << 24), !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Rust's `reply`: the next line, parsed; nil when none came or it isn't JSON.
    func reply() -> JSON? { rawReply().flatMap { try? JSONParser.parse($0) } }

    /// Every reply line until the server closes the connection.
    func repliesUntilClosed() -> [JSON] {
        var out: [JSON] = []
        while let v = reply() { out.append(v) }
        return out
    }

    func close() {
        if open { _ = shutdown(conn.fd, SHUT_RDWR) }
        open = false
    }
}

/// Answer every request with its method name until the server stops (Rust's `ui`).
func ui(_ server: ControlServer) {
    let queue = server.queue
    ControlServer.spawn("test-ui") {
        while let req = queue.receive(until: nil) {
            req.reply.send(["ok": true, "result": .string(req.method)])
        }
    }
}

/// Runs `body` on a thread of its own; wait for it with the semaphore.
func onThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    ControlServer.spawn("test") {
        body()
        done.signal()
    }
    return done
}

func errorText(_ v: JSON?) -> String { v?.get("error")?.asStr ?? "" }

@Suite("Control server", .serialized)
struct ControlServerTests {
    /// `a_failed_accept_waits_before_the_next`: a failed accept is followed by a wait before the next one,
    /// so a listener that keeps failing does not spin, and the connections around the failures still come
    /// through.
    @Test func aFailedAcceptWaitsBeforeTheNext() {
        let failed = Result<Int, IOFailure>.failure(IOFailure("no file descriptors left"))
        let incoming = [failed, .success(1), failed, failed, .success(2)]
        var waits = 0
        let connections = Array(ControlServer.accepted(incoming, wait: { waits += 1 }))
        #expect(connections == [1, 2])
        #expect(waits == 3, "one wait per failed accept")
    }

    /// `request_round_trip`.
    @Test func requestRoundTrip() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        ui(server)
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(#"{"id":7,"method":"ui.inspect"}"# + "\n")
        let v = try #require(c.reply())
        #expect(v.get("id") == 7)
        #expect(v.get("result") == "ui.inspect")
    }

    /// `an_http_request_closes_the_connection_before_its_body_is_dispatched`: a browser can POST to the
    /// port: its request line closes the connection before the JSON line in its body is read, so nothing is
    /// dispatched.
    @Test func anHttpRequestClosesTheConnectionBeforeItsBodyIsDispatched() throws {
        let server = try controlServer(small(maxLine: 512))
        defer { server.stop() }
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(
            "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\n\r\n"
                + #"{"id":1,"method":"engine.execute","params":{"command":"slide.new"}}"# + "\n"
        )
        let replies = c.repliesUntilClosed()
        #expect(replies.count == 1, "\(replies)")
        #expect(errorText(replies.first).contains("closing the connection"), "\(replies)")
        #expect(server.tryReceive() == nil, "the body was dispatched")
    }

    /// `a_line_that_is_not_a_request_closes_the_connection`.
    @Test func aLineThatIsNotARequestClosesTheConnection() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        ui(server)
        let junk: [[UInt8]] = [Array("hello\n".utf8), Array("[1,2]\n".utf8), Array(#"{"id":1}"#.utf8) + [10], Array(#"{"method":5}"#.utf8) + [10], [0xFF, 0xFE, 0x0A], Array("GET /x HTTP/1.1\n".utf8)]
        for j in junk {
            let c = try ControlPeer(server.port)
            c.write(j)
            c.write(#"{"id":2,"method":"m"}"# + "\n")
            let replies = c.repliesUntilClosed()
            #expect(replies.count == 1, "\(j): \(replies)")
            #expect(replies.first?.get("ok") == false)
            c.close()
        }
        #expect(ControlServer.isHTTPRequestLine("OPTIONS * HTTP/1.1"))
        #expect(ControlServer.isHTTPRequestLine("PRI * HTTP/2.0"))
        #expect(!ControlServer.isHTTPRequestLine(#"{"method":"GET /"}"#))
    }

    /// `a_pipelined_peer_still_reads_why_its_line_was_rejected`: a peer that pipelines (two lines in one
    /// write, as a script does) still reads why its line was rejected. Closing with its second line unread
    /// resets the connection and discards the reply already on its way; repeated because it depends on the
    /// timing of the two.
    @Test func aPipelinedPeerStillReadsWhyItsLineWasRejected() throws {
        // A slot comes back only when the thread serving a peer ends, which can be after the next peer
        // connects, so every peer has a slot of its own.
        let peers = 12
        let server = try controlServer(small(maxClients: peers))
        defer { server.stop() }
        for _ in 0 ..< peers {
            let c = try ControlPeer(server.port)
            c.write("hello\n")
            // A second line, written after the first as a script writes it: it races the close.
            c.write(#"{"id":2,"method":"m"}"# + "\n")
            let replies = c.repliesUntilClosed()
            #expect(replies.count == 1, "\(replies)")
            #expect(replies.first?.get("ok") == false)
            #expect(errorText(replies.first).contains("closing the connection"), "\(replies)")
            c.close()
        }
        // The line after the rejected one is never dispatched, pipelined or not.
        #expect(server.tryReceive() == nil, "a line after the rejection was dispatched")
    }

    /// `a_pipelined_peer_refused_as_busy_still_reads_why`: a peer refused because every connection is
    /// taken still reads why when it had already written a line. Repeated because it depends on timing.
    @Test func aPipelinedPeerRefusedAsBusyStillReadsWhy() throws {
        let server = try controlServer(small(maxClients: 1, idleTimeout: .seconds(30)))
        defer { server.stop() }
        ui(server)
        // Take the only slot, and make sure it is being served.
        let holder = try ControlPeer(server.port)
        defer { holder.close() }
        holder.write(#"{"id":1,"method":"m"}"# + "\n")
        #expect(holder.reply() != nil)
        for _ in 0 ..< 50 {
            let c = try ControlPeer(server.port)
            c.write(#"{"id":2,"method":"m"}"# + "\n")
            let replies = c.repliesUntilClosed()
            #expect(replies.count == 1, "\(replies)")
            #expect(errorText(replies.first).hasPrefix("busy"), "\(replies)")
            c.close()
        }
    }

    /// `silent_refused_peers_do_not_delay_the_next_refusal`: peers refused as busy that stay connected
    /// without sending anything don't hold up the connections after them: each one's drain runs to its
    /// deadline on a thread of its own, and past `maxRefusing` drains at once a refused connection is closed
    /// without one.
    @Test func silentRefusedPeersDoNotDelayTheNextRefusal() throws {
        let server = try controlServer(small(maxClients: 1, idleTimeout: .seconds(30)))
        defer { server.stop() }
        ui(server)
        let holder = try ControlPeer(server.port)
        defer { holder.close() }
        holder.write(#"{"id":1,"method":"m"}"# + "\n")
        #expect(holder.reply() != nil)
        // Twenty drains of 250 ms each, one after another, would take five seconds.
        let silent = try (0 ..< ControlServer.maxRefusing + 4).map { _ in try ControlPeer(server.port) }
        let start = ContinuousClock.now
        let c = try ControlPeer(server.port)
        defer { c.close() }
        let refused = try #require(c.reply())
        #expect(errorText(refused).hasPrefix("busy"), "\(refused)")
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "refused after \(elapsed)")
        for s in silent { s.close() }
    }

    /// `a_rejected_peer_that_stays_connected_frees_its_slot_at_the_deadline`: a peer that keeps its
    /// connection open after its line was rejected gives its slot back at the drain deadline (the write
    /// timeout), not at the idle timeout.
    @Test func aRejectedPeerThatStaysConnectedFreesItsSlotAtTheDeadline() throws {
        let server = try controlServer(small(maxClients: 1, idleTimeout: .seconds(30)))
        defer { server.stop() }
        ui(server)
        let c = try ControlPeer(server.port)
        c.write("hello\n")
        #expect(c.reply()?.get("ok") == false)
        // `c` stays open, sending nothing.
        let deadline = ContinuousClock.now + .seconds(4)
        while true {
            let d = try ControlPeer(server.port)
            d.write(#"{"id":2,"method":"m"}"# + "\n")
            let ok = d.reply()?.get("ok") == true
            d.close()
            if ok { break }
            try #require(ContinuousClock.now < deadline, "slot never freed")
            Thread.sleep(forTimeInterval: 0.05)
        }
        c.close()
    }

    /// `oversized_line_closes_connection`.
    @Test func oversizedLineClosesConnection() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        ui(server)
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write([UInt8](repeating: UInt8(ascii: "x"), count: 200))
        let v = try #require(c.reply())
        #expect(errorText(v).contains("longer than 64"))
        #expect(c.reply() == nil)
    }

    /// `idle_connection_is_closed`.
    @Test func idleConnectionIsClosed() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        ui(server)
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(#"{"id":1,"#) // unterminated, then silence
        let t = ContinuousClock.now
        #expect(c.reply() == nil)
        #expect(ContinuousClock.now - t < .seconds(4))
    }

    /// `connection_limit_refuses_then_frees_slot`.
    @Test func connectionLimitRefusesThenFreesSlot() throws {
        // `a` sends nothing. Under a 300 ms idle timeout, a slow run could close it before the third peer
        // connected, and that peer then took its slot instead of reading `busy`.
        let server = try controlServer(small(idleTimeout: .seconds(30)))
        defer { server.stop() }
        ui(server)
        let a = try ControlPeer(server.port)
        let b = try ControlPeer(server.port)
        defer { b.close() }
        // Make sure both are being served before the third arrives.
        b.write(#"{"id":1,"method":"m"}"# + "\n")
        #expect(b.reply() != nil)
        let c = try ControlPeer(server.port)
        defer { c.close() }
        #expect(errorText(c.reply()).hasPrefix("busy"))
        a.close()
        // The freed slot is reusable once the server notices the disconnect.
        let deadline = ContinuousClock.now + .seconds(4)
        while true {
            let d = try ControlPeer(server.port)
            d.write(#"{"id":2,"method":"m"}"# + "\n")
            let ok = d.reply()?.get("ok") == true
            d.close()
            if ok { break }
            try #require(ContinuousClock.now < deadline, "slot never freed")
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// `blocked_ui_times_out_and_full_queue_is_busy`.
    @Test func blockedUiTimesOutAndFullQueueIsBusy() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        // No UI: the request that reaches the one-slot queue first fills it and times out; the other finds
        // it full. Each connection has its own thread, so either request can be first.
        let a = try ControlPeer(server.port)
        let b = try ControlPeer(server.port)
        defer {
            a.close()
            b.close()
        }
        a.write(#"{"id":1,"method":"m"}"# + "\n")
        b.write(#"{"id":2,"method":"m"}"# + "\n")
        let ra = try #require(a.reply())
        let rb = try #require(b.reply())
        #expect(ra.get("id") == 1 && rb.get("id") == 2)
        let errors = [errorText(ra), errorText(rb)].sorted()
        #expect(errors == ["busy: too many queued requests", "timeout"], "\(ra.display) \(rb.display)")
    }

    /// `timed_out_request_does_not_run_when_the_window_resumes`: a request that timed out while it was
    /// still queued must not run when the window resumes (#719).
    @Test func timedOutRequestDoesNotRunWhenTheWindowResumes() throws {
        let server = try controlServer(small(maxLine: 512))
        defer { server.stop() }
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(#"{"id":1,"method":"engine.execute","params":{"command":"slide.new"}}"# + "\n")
        #expect(c.reply()?.get("error") == "timeout")
        // The window resumes and drains the queue, exactly as the app's drain does.
        let host = HeadlessControlHost(Session.withNew())
        let before = host.session.activeDoc?.doc.slides.count
        let req = try #require(server.tryReceive(), "the timed-out request is still queued")
        if req.take() {
            _ = Control.handle(host, req.method, req.params)
        }
        #expect(host.session.activeDoc?.doc.slides.count == before, "a request that timed out must not run when the window resumes")
    }

    /// `a_request_already_started_when_the_reply_times_out_reports_an_unknown_outcome` (#719).
    @Test func aRequestAlreadyStartedWhenTheReplyTimesOutReportsAnUnknownOutcome() throws {
        let server = try controlServer(small())
        defer { server.stop() }
        let claimed = Mutex<Bool?>(nil)
        let queue = server.queue
        let done = onThread {
            guard let req = queue.receive(until: Date().addingTimeInterval(5)) else { return }
            claimed.withLock { $0 = req.take() }
            // Still running it when the sender's wait expires.
            Thread.sleep(forTimeInterval: 0.45)
            req.reply.send(["ok": true, "result": "ran"])
        }
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(#"{"id":1,"method":"m"}"# + "\n")
        let v = try #require(c.reply())
        #expect(errorText(v).contains("outcome is unknown"), "\(v.display)")
        done.wait()
        #expect(claimed.withLock { $0 } == true, "the app claims the request")
    }

    // MARK: - Beyond deckcraft's tests

    /// Every reply the server writes itself, byte for byte as deckcraft's `json!` values print (keys
    /// sorted): the literals of control_server.rs.
    @Test func repliesAreDeckcraftsBytes() throws {
        let server = try controlServer(small(maxClients: 16))
        defer { server.stop() }
        let rejected: [([UInt8], String)] = [
            (Array("hello\n".utf8), "bad JSON (expected value at line 1 column 1); expected one JSON request object per line; closing the connection"),
            (Array(#"{"id":1,} "#.utf8) + [10], "bad JSON (trailing comma at line 1 column 9); expected one JSON request object per line; closing the connection"),
            (Array("[1,2]\n".utf8), "not a control request (expected a JSON object); closing the connection"),
            (Array(#"{"id":1}"#.utf8) + [10], "not a control request (missing string `method`); closing the connection"),
            (Array(#"{"method":5}"#.utf8) + [10], "not a control request (missing string `method`); closing the connection"),
            ([0xFF, 0xFE, 0x0A], "not a control request (invalid UTF-8); closing the connection"),
            (Array("  GET /x HTTP/1.1\r\n".utf8), "HTTP is not served here: this port takes JSON lines; closing the connection"),
            (Array("PRI * HTTP/2.0\n".utf8), "HTTP is not served here: this port takes JSON lines; closing the connection"),
            (Array("x".utf8) + [UInt8](repeating: 0x20, count: 70), "request line longer than 64 bytes"),
        ]
        for (input, error) in rejected {
            let c = try ControlPeer(server.port)
            c.write(input)
            #expect(c.rawReply() == #"{"error":"\#(error)","ok":false}"# + "\n")
            #expect(c.rawReply() == nil)
            c.close()
        }
        // Blank lines are skipped; the id is echoed whatever it is; params default to `{}`.
        let ids = Mutex<[JSON]>([])
        let queue = server.queue
        let uiDone = onThread {
            for _ in 0 ..< 2 {
                guard let req = queue.receive(until: Date().addingTimeInterval(5)) else { return }
                ids.withLock { $0.append(req.params) }
                req.reply.send(["result": .string(req.method), "ok": true])
            }
            // The third request is left to time out.
        }
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write("\n \t\r\n" + #"{"id":[1.5,"x"],"method":"ui.inspect"}"# + "\n")
        #expect(c.rawReply() == #"{"id":[1.5,"x"],"ok":true,"result":"ui.inspect"}"# + "\n")
        c.write(#"{"method":"m","params":null}"# + "\n")
        #expect(c.rawReply() == #"{"id":null,"ok":true,"result":"m"}"# + "\n")
        uiDone.wait()
        #expect(ids.withLock { $0 } == [.emptyObject, .null])
        c.write(#"{"id":3,"method":"m"}"# + "\n")
        #expect(c.rawReply() == #"{"error":"timeout","id":3,"ok":false}"# + "\n")
        // The abandoned request fills the one-slot queue: the next is busy.
        c.write(#"{"id":4,"method":"m"}"# + "\n")
        #expect(c.rawReply() == #"{"error":"busy: too many queued requests","id":4,"ok":false}"# + "\n")
        // A request the app started and didn't finish in time.
        _ = server.tryReceive()
        let started = onThread {
            guard let req = queue.receive(until: Date().addingTimeInterval(5)) else { return }
            _ = req.take()
            Thread.sleep(forTimeInterval: 0.45)
        }
        c.write(#"{"id":5,"method":"m"}"# + "\n")
        #expect(c.rawReply() == #"{"error":"timeout: the app had already started the request, so it may still run; its outcome is unknown","id":5,"ok":false}"# + "\n")
        started.wait()
    }

    /// The refusal when every connection is taken, byte for byte.
    @Test func busyRefusalIsDeckcraftsBytes() throws {
        let server = try controlServer(small(maxClients: 1, idleTimeout: .seconds(30)))
        defer { server.stop() }
        ui(server)
        let holder = try ControlPeer(server.port)
        defer { holder.close() }
        holder.write(#"{"id":1,"method":"m"}"# + "\n")
        #expect(holder.rawReply() == #"{"id":1,"ok":true,"result":"m"}"# + "\n")
        let refused = try ControlPeer(server.port)
        defer { refused.close() }
        #expect(refused.rawReply() == #"{"error":"busy: too many control connections","ok":false}"# + "\n")
        #expect(refused.rawReply() == nil)
    }

    /// `stop` ends the connections being served and closes the listener; stopping twice is harmless.
    @Test func stopClosesConnectionsAndTheListener() throws {
        let server = try controlServer(small(idleTimeout: .seconds(30)))
        ui(server)
        let c = try ControlPeer(server.port)
        defer { c.close() }
        c.write(#"{"id":1,"method":"m"}"# + "\n")
        #expect(c.reply() != nil)
        let t = ContinuousClock.now
        server.stop()
        #expect(c.reply() == nil)
        #expect(ContinuousClock.now - t < .seconds(2), "the connection ended at the stop, not at a timeout")
        let address = try Sockets.resolve("127.0.0.1:\(server.port)")[0]
        let deadline = ContinuousClock.now + .seconds(4)
        while let fd = try? Sockets.connect(address, timeout: 1) {
            Darwin.close(fd)
            try #require(ContinuousClock.now < deadline, "still listening")
            Thread.sleep(forTimeInterval: 0.02)
        }
        server.stop()
    }

    /// End to end: a headless app serving its control channel, driven by `Remote` (what `dccli app` and
    /// `dccli mcp --connect` use).
    @Test func remoteDrivesAHeadlessAppThroughTheServer() throws {
        let channel = ControlChannel(HeadlessControlHost(Session.withNew()))
        let server = try channel.serve(port: 0)
        defer { server.stop() }
        let remote = try Remote.connect("127.0.0.1:\(server.port)")
        let first = try remote.call("engine.execute", ["command": "slide.new", "params": ["layout": "blank"]])
        #expect(first.get("index") == 1, "\(first.display)")
        _ = try remote.call("engine.execute", ["command": "slide.new"])
        let shape = try remote.call("engine.execute", ["command": "shape.insert", "params": ["preset": "star5", "rect": [10, 10, 100, 100]]])
        #expect(shape.isObject, "\(shape.display)")
        let doc = try remote.call("document.inspect", .emptyObject)
        #expect(doc.get("slides")?.asArray?.count == 3, "\(doc.display.prefix(300))")
        #expect(throws: AutomationError("unknown command `no.such`")) {
            try remote.call("engine.execute", ["command": "no.such"])
        }
        #expect(throws: AutomationError("`ui.click`: \(needsApp)")) { try remote.call("ui.click", .emptyObject) }
        #expect(try remote.call("ui.inspect", .emptyObject).get("headless") == true)
        // What the server's peer made is in the channel's session.
        #expect(channel.call("document.inspect", .emptyObject).get("result")?.get("slides")?.asArray?.count == 3)
    }
}
