// DCAutomation — MCP over stdio: newline-delimited JSON-RPC, one reply line per request line, written
// and flushed before the next line is read. Port of deckcraft crates/mcp/src/server.rs `Server::serve`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with PhotoCraftNative's reader
// thread.
//
// Lines are read as Rust's `BufRead::lines` reads them: split at `\n`, a trailing `\r` dropped, the last
// line kept without its newline, and a line that isn't UTF-8 ends the session with an error. Unlike
// deckcraft, a line is bounded (`maxLineBytes`), so a peer can't grow memory without end.
import Darwin
import Foundation

/// Reads lines from a file descriptor (or bytes in memory) on the calling thread.
public final class LineReader {
    let source: (UnsafeMutableRawBufferPointer) throws(IOFailure) -> Int
    var buffer: [UInt8] = []
    var position = 0
    var finished = false

    /// `read` fills the buffer it is given and returns the count, 0 at the end.
    public init(read: @escaping (UnsafeMutableRawBufferPointer) throws(IOFailure) -> Int) { source = read }

    /// Reads a file descriptor (stdin, a pipe); `EINTR` is retried.
    public convenience init(fd: Int32) {
        self.init { (buffer: UnsafeMutableRawBufferPointer) throws(IOFailure) -> Int in
            while true {
                let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
                if n >= 0 { return n }
                if errno == EINTR { continue }
                throw .current
            }
        }
    }

    /// Reads bytes in memory, `chunk` at a time.
    public convenience init(bytes: [UInt8], chunk: Int = 64 << 10) {
        var offset = 0
        self.init { (buffer: UnsafeMutableRawBufferPointer) throws(IOFailure) -> Int in
            let n = min(chunk, buffer.count, bytes.count - offset)
            if n <= 0 { return 0 }
            bytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset ..< offset + n])) }
            offset += n
            return n
        }
    }

    private func fill() throws(IOFailure) -> Bool {
        if position < buffer.count { return true }
        if finished { return false }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let r = chunk.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Result<Int, IOFailure> in
            Result { () throws(IOFailure) -> Int in try source(b) }
        }
        let n = try r.get()
        if n <= 0 {
            finished = true
            return false
        }
        buffer = Array(chunk[..<n])
        position = 0
        return true
    }

    /// The next line without its `\n` (and a `\r` before it); nil at the end. A line longer than
    /// `maximum` bytes, or not UTF-8, is an error.
    public func readLine(maximum: Int) throws(IOFailure) -> String? {
        var line: [UInt8] = []
        var sawAny = false
        while try fill() {
            sawAny = true
            let rest = buffer[position...]
            if let nl = rest.firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[position ..< nl])
                position = nl + 1
                if line.count > maximum { throw IOFailure("a request line exceeds \(maximum) bytes") }
                return try Self.text(line)
            }
            line.append(contentsOf: rest)
            position = buffer.count
            if line.count > maximum { throw IOFailure("a request line exceeds \(maximum) bytes") }
        }
        return sawAny ? try Self.text(line) : nil
    }

    private static func text(_ bytes: [UInt8]) throws(IOFailure) -> String {
        var b = bytes
        if b.last == 0x0D { b.removeLast() }
        guard let s = String(validating: b, as: UTF8.self) else { throw IOFailure("stream did not contain valid UTF-8") }
        return s
    }
}

extension MCPServer {
    /// The longest request line read: 256 MiB (a picture sent as base64 fits).
    public static let maxLineBytes = 256 << 20

    /// Serve newline-delimited JSON-RPC from `reader` until it ends, writing each reply line with `write`.
    /// Logs go to stderr only (stdout is the protocol stream).
    public func serve(_ reader: LineReader, write: @escaping @Sendable ([UInt8]) throws(IOFailure) -> Void) async throws(IOFailure) {
        enum Event: Sendable {
            case line(String)
            case failed(IOFailure)
        }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let box = EngineConfined(reader)
        let thread = Thread {
            reading: while true {
                switch Result(catching: { () throws(IOFailure) -> String? in try box.value.readLine(maximum: MCPServer.maxLineBytes) }) {
                case .success(let line?):
                    continuation.yield(.line(line))
                case .success(nil):
                    break reading
                case .failure(let e):
                    continuation.yield(.failed(e))
                    break reading
                }
            }
            continuation.finish()
        }
        thread.name = "dc.mcp.stdin"
        thread.start()
        for await event in events {
            switch event {
            case .line(let line):
                if let reply = await handleLine(line) { try write(Array("\(reply)\n".utf8)) }
            case .failed(let e):
                throw e
            }
        }
    }

    /// Serve on stdin and stdout.
    public func serveStdio() async throws(IOFailure) {
        signal(SIGPIPE, SIG_IGN)
        try await serve(LineReader(fd: STDIN_FILENO)) { (bytes: [UInt8]) throws(IOFailure) in
            try Sockets.writeAll(STDOUT_FILENO, bytes)
        }
    }
}
