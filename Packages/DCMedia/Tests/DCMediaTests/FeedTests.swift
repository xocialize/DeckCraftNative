// DCMediaTests — the video feed: deckcraft crates/media/src/feed.rs's tests and the feed tests of
// tests/it/decode.rs, ported (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
@testable import DCMedia
import Foundation
import Testing

private func frame(_ time: Double) -> Frame { Frame(time: time, width: 1, height: 1, rgba: [0, 0, 0, 255]) }

@Suite struct FeedTests {
    @Test func seekKeepsNewGenerationFramesAndEndOfStream() {
        let commands = FeedCommands()
        let frames = FeedFrames(capacity: feedAhead)
        frames.send(0, frame(0.3))
        frames.send(0, nil)
        // A fast worker's answer to the seek, already waiting when the seek happens.
        frames.send(1, frame(0.0))
        frames.send(1, nil)
        let feed = VideoFeed(size: (1, 1), commands: commands, frames: frames)

        feed.seek(0.05)
        #expect(feed.frameAt(0.05)?.time == 0.0)
        #expect(feed.ended)

        frames.send(2, frame(0.3))
        frames.send(2, nil)
        frames.send(3, frame(0.0))
        frames.send(3, nil)
        feed.seek(0.35)
        feed.seek(0.05)
        #expect(feed.frameAt(0.05)?.time == 0.0, "the latest seek wins")
        #expect(feed.ended)
    }

    @Test func seekUnblocksTheWorkerWhenTheStaleQueueIsFull() {
        let commands = FeedCommands()
        let frames = FeedFrames(capacity: feedAhead)
        for _ in 0..<feedAhead { frames.send(0, frame(0)) }
        let done = Thread {
            guard let (_, generation) = commands.recv() else { return }
            frames.send(generation, frame(0))
            frames.send(generation, nil)
        }
        done.start()
        let feed = VideoFeed(size: (1, 1), commands: commands, frames: frames)
        feed.seek(0.05)
        let shown = feed.frameAtBlocking(0.05, timeout: 5)
        #expect(shown?.time == 0.0)
        #expect(feed.ended)
    }

    @Test func videoFeedFollowsTheClock() throws {
        guard let b = UpstreamFixtures.load("clip-h264.mov") else { return }
        let feed = try VideoFeed(b)
        #expect(feed.size == (64, 48))
        #expect(feed.frameAtBlocking(0, timeout: 5)?.time == 0)
        let f = feed.frameAtBlocking(0.25, timeout: 5)?.time ?? -1
        #expect(abs(f - 0.2) < 0.02, "\(f)")
        // Jumping back (a loop) seeks.
        #expect(feed.frameAtBlocking(0.05, timeout: 5)?.time == 0)
        let g = feed.frameAtBlocking(0.55, timeout: 5)?.time ?? -1
        #expect(abs(g - 0.5) < 0.02, "\(g)")
    }

    @Test func videoFeedRepeatedSeeksKeepTheRequestedFrame() throws {
        var names = ["clip-h264.mov", "clip-hevc.mp4"]
        if VideoSupport.av1 { names.append("clip-av1.mkv") }
        for name in names {
            guard let b = UpstreamFixtures.load(name) else { return }
            let feed = try VideoFeed(b)
            for _ in 0..<20 {
                // A decoder can finish this small clip before the consumer next polls it. Rewinding must keep
                // the new generation's first frame, even at the end of the stream.
                feed.seek(0.05)
                #expect(feed.frameAtBlocking(0.05, timeout: 5)?.time == 0, "\(name)")
                let t = feed.frameAtBlocking(0.45, timeout: 5)?.time ?? -1
                #expect(abs(t - 0.4) < 0.02, "\(name): \(t)")
            }
        }
    }
}
