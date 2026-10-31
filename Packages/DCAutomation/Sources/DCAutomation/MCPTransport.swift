// DCAutomation — MCP over stdio: newline-delimited JSON-RPC, one reply line per request line, written
// and flushed before the next line is read. Port of deckcraft crates/mcp/src/server.rs `Server::serve`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with PhotoCraftNative's reader
// thread.
//
// Frames are read as deckcraft's `read_frame` reads them: through each `\n` (the last frame may end
// without one), at most 16 MiB with the newline. A longer frame is drained to its newline without being
// kept and answered with an error; a frame that isn't UTF-8 gets a parse error. Either way serving goes on.
import Darwin
import Foundation

/// Reads request frames from a file descriptor (or bytes in memory) on the calling thread.
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

    /// One request frame: its bytes through the `\n`, or word that it was longer than allowed.
    public enum Frame: Equatable, Sendable {
        case complete([UInt8])
        case tooLarge
    }

    /// The next frame, read through one newline while keeping no more than `maximum` bytes; nil at the end.
    public func readFrame(maximum: Int) throws(IOFailure) -> Frame? {
        var bytes: [UInt8] = []
        var tooLarge = false
        while true {
            guard try fill() else {
                if bytes.isEmpty && !tooLarge { return nil }
                return tooLarge ? .tooLarge : .complete(bytes)
            }
            let rest = buffer[position...]
            let end = rest.firstIndex(of: 0x0A).map { $0 + 1 } ?? buffer.count
            if !tooLarge {
                if end - position > maximum - bytes.count {
                    tooLarge = true
                    bytes = []
                } else {
                    bytes.append(contentsOf: buffer[position ..< end])
                }
            }
            let ended = buffer[end - 1] == 0x0A
            position = end
            if ended { return tooLarge ? .tooLarge : .complete(bytes) }
        }
    }
}

extension MCPServer {
    /// The longest request frame kept, its newline included: 16 MiB, in step with the connected backend's
    /// reply limit.
    public static let maxFrameBytes = 16 << 20

    /// Serve newline-delimited JSON-RPC from `reader` until it ends, writing each reply line with `write`.
    /// Logs go to stderr only (stdout is the protocol stream).
    public func serve(_ reader: LineReader, write: @escaping @Sendable ([UInt8]) throws(IOFailure) -> Void) async throws(IOFailure) {
        enum Event: Sendable {
            case frame(LineReader.Frame)
            case failed(IOFailure)
        }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let box = EngineConfined(reader)
        let thread = Thread {
            reading: while true {
                switch Result(catching: { () throws(IOFailure) -> LineReader.Frame? in try box.value.readFrame(maximum: MCPServer.maxFrameBytes) }) {
                case .success(let frame?):
                    continuation.yield(.frame(frame))
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
            case .frame(let frame):
                let reply: String?
                switch frame {
                case .complete(let bytes):
                    if let line = String(validating: bytes, as: UTF8.self) {
                        reply = await handleLine(line)
                    } else {
                        reply = Self.error(.null, RPCCode.parseError, "request frame is not valid UTF-8").display
                    }
                case .tooLarge:
                    reply = Self.error(.null, RPCCode.invalidRequest, "request frame exceeds 16 MiB").display
                }
                if let reply { try write(Array("\(reply)\n".utf8)) }
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
