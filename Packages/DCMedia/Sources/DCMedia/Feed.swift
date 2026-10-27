// DCMedia — video frames for a playback clock: decoding runs ahead on a worker thread, and
// `VideoFeed.frameAt` hands out the frame due at the clock's time, seeking when the clock jumps (seek, loop).
// Port of deckcraft crates/media/src/feed.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors); Rust's mpsc channels become the two small queues below.
import Foundation

/// Frames decoded ahead of the clock.
let feedAhead = 6
/// A jump forward larger than this (seconds) seeks instead of decoding through.
private let maxCatchUp = 1.5

/// The feed's commands to its worker: an unbounded queue (Rust's `mpsc::channel`).
final class FeedCommands: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [(Double, UInt64)] = []
    private var closed = false

    func send(_ t: Double, _ generation: UInt64) {
        cond.lock()
        items.append((t, generation))
        cond.signal()
        cond.unlock()
    }

    /// The next command, waiting for one; nil once closed and empty.
    func recv() -> (Double, UInt64)? {
        cond.lock()
        defer { cond.unlock() }
        while items.isEmpty && !closed { cond.wait() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    enum TryRecv { case item(Double, UInt64), empty, closed }

    func tryRecv() -> TryRecv {
        cond.lock()
        defer { cond.unlock() }
        if !items.isEmpty {
            let (t, g) = items.removeFirst()
            return .item(t, g)
        }
        return closed ? .closed : .empty
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }
}

/// The worker's frames to the feed: a bounded queue (Rust's `mpsc::sync_channel(AHEAD)`). A nil frame is
/// the end of the stream.
final class FeedFrames: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [(UInt64, Frame?)] = []
    private let capacity: Int
    private var receiverGone = false
    private var senderGone = false

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Waits for room; false once the receiver is gone.
    @discardableResult
    func send(_ generation: UInt64, _ frame: Frame?) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while items.count >= capacity && !receiverGone { cond.wait() }
        if receiverGone { return false }
        items.append((generation, frame))
        cond.broadcast()
        return true
    }

    enum TryRecv { case item(UInt64, Frame?), empty, disconnected }

    func tryRecv() -> TryRecv {
        cond.lock()
        defer { cond.unlock() }
        if !items.isEmpty {
            let (g, f) = items.removeFirst()
            cond.broadcast()
            return .item(g, f)
        }
        return senderGone ? .disconnected : .empty
    }

    func closeReceiver() {
        cond.lock()
        receiverGone = true
        cond.broadcast()
        cond.unlock()
    }

    func closeSender() {
        cond.lock()
        senderGone = true
        cond.broadcast()
        cond.unlock()
    }
}

/// Video frames decoded ahead of a playback clock (deckcraft's `VideoFeed`).
public final class VideoFeed {
    public let size: (UInt32, UInt32)
    private var current: Frame?
    private var next: Frame?
    private var generation: UInt64 = 0
    private var endedFlag = false
    private let commands: FeedCommands
    private let frames: FeedFrames

    public init(_ bytes: [UInt8]) throws(MediaError) {
        let dec = try VideoDecoder(bytes)
        size = dec.size
        let commands = FeedCommands()
        let frames = FeedFrames(capacity: feedAhead)
        self.commands = commands
        self.frames = frames
        let box = DecoderBox(dec)
        let thread = Thread { VideoFeed.worker(box, commands, frames) }
        thread.name = "dcmedia-video-decode"
        thread.start()
    }

    /// A feed over channels a test drives.
    init(size: (UInt32, UInt32), commands: FeedCommands, frames: FeedFrames) {
        self.size = size
        self.commands = commands
        self.frames = frames
    }

    deinit {
        commands.close()
        frames.closeReceiver()
    }

    /// Restart decoding at `t`.
    public func seek(_ t: Double) {
        generation += 1
        current = nil
        next = nil
        endedFlag = false
        // `pull` discards stale generations and so unblocks the worker. Draining here could also discard
        // the new generation's frames or its end if the worker answers the seek fast.
        commands.send(t, generation)
    }

    private enum Pulled { case frame(Frame), none, end }

    /// The next decoded frame, if one is ready.
    private func pull() -> Pulled {
        while true {
            switch frames.tryRecv() {
            case .item(let g, _) where g != generation: continue
            case .item(_, let f?): return .frame(f)
            case .item(_, nil): return .end
            case .empty: return .none
            case .disconnected: return .end
            }
        }
    }

    /// The frame on screen at media time `t` (seconds): the last one whose time is ≤ `t`, or the first one
    /// while nothing earlier exists. nil until the first frame has decoded.
    public func frameAt(_ t: Double) -> Frame? {
        let behind = current.map { t + 0.02 < $0.time } ?? false
        let far = (next ?? current).map { t > $0.time + maxCatchUp } ?? false
        if behind || far { seek(t) }
        while true {
            if next == nil && !endedFlag {
                switch pull() {
                case .frame(let f): next = f
                case .none: break
                case .end: endedFlag = true
                }
                if next == nil && !endedFlag { break }
            }
            if let n = next, n.time <= t + 1e-3 || current == nil {
                current = n
                next = nil
            } else {
                break
            }
        }
        return current
    }

    /// The decoder has delivered its last frame.
    public var ended: Bool { endedFlag && next == nil }

    /// Wait (up to `timeout` seconds) for the frame at `t`: for tests and offline rendering.
    public func frameAtBlocking(_ t: Double, timeout: Double) -> Frame? {
        var waited = 0.0
        while true {
            let f = frameAt(t)
            let done = endedFlag || next != nil
            if done || waited >= timeout { return f }
            Thread.sleep(forTimeInterval: 0.002)
            waited += 0.002
        }
    }

    /// Hands the decoder to the worker thread, which alone uses it from then on.
    private final class DecoderBox: @unchecked Sendable {
        let decoder: VideoDecoder
        init(_ d: VideoDecoder) { decoder = d }
    }

    private static func worker(_ box: DecoderBox, _ commands: FeedCommands, _ frames: FeedFrames) {
        defer { frames.closeSender() }
        let dec = box.decoder
        var generation: UInt64 = 0
        var atEnd = false
        while true {
            // Commands first; block on them once the stream has ended.
            var cmd: (Double, UInt64)?
            if atEnd {
                guard let c = commands.recv() else { return }
                cmd = c
            } else {
                switch commands.tryRecv() {
                case .item(let t, let g): cmd = (t, g)
                case .empty: cmd = nil
                case .closed: return
                }
            }
            if let c = cmd {
                var (t, g) = c
                // Only the latest seek matters.
                while case .item(let t2, let g2) = commands.tryRecv() { (t, g) = (t2, g2) }
                dec.seek(t)
                generation = g
            }
            let frame: Frame?
            do {
                frame = try dec.nextFrame()
            } catch {
                frame = nil
            }
            atEnd = frame == nil
            if !frames.send(generation, frame) { return }
        }
    }
}
