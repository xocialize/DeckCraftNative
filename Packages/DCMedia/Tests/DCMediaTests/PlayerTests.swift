// DCMediaTests — the playback mixer and clock: deckcraft crates/media/src/player.rs's tests and the player test
// of tests/it/decode.rs, ported (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
@testable import DCMedia
import Foundation
import Synchronization
import Testing

private func spec(_ duration: Double, _ looping: Bool) -> VoiceSpec {
    VoiceSpec(clip: ClipParams(), looping: looping, duration: duration, audio: false)
}

private func pos(_ p: Player, _ key: UInt64) -> Double { p.status(key)?.position ?? -1 }

/// An output that starts, then fails or goes quiet on command (deckcraft's `Flaky`).
private final class Flaky: AudioOut, @unchecked Sendable {
    private let lock = NSLock()
    private var fill: AudioFill?
    private var fail: String?
    private var startCount: UInt32 = 0

    func start(_ fill: @escaping AudioFill) throws(AudioOutError) {
        lock.withLock {
            self.fill = fill
            startCount += 1
        }
    }

    func stop() { lock.withLock { fill = nil } }

    func failure() -> String? {
        lock.withLock {
            defer { fail = nil }
            return fail
        }
    }

    func setFailure(_ s: String) { lock.withLock { fail = s } }

    /// The device asks for `frames` stereo frames at 48 kHz.
    func pull(_ frames: Int) {
        let f = lock.withLock { fill }
        var buf = [Float](repeating: 0, count: frames * 2)
        buf.withUnsafeMutableBufferPointer { f?($0, 2, 48000) }
    }

    var starts: UInt32 { lock.withLock { startCount } }
    var hasFill: Bool { lock.withLock { fill != nil } }
}

@Suite struct PlayerTests {
    @Test func wallClockAdvancesPausesAndSeeks() {
        let p = Player(nil)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(2, false))
        p.tick(10.0)
        p.tick(10.2)
        p.tick(10.4)
        #expect(abs(pos(p, 1) - 0.4) < 1e-3)
        p.pause(1)
        p.tick(10.6)
        #expect(abs(pos(p, 1) - 0.4) < 1e-3)
        #expect(p.status(1)?.state == .paused)
        p.seek(1, 1.5)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(2, false))
        for t in [10.8, 11.0, 11.2, 11.4] { p.tick(t) }
        let st = p.status(1)
        #expect(st?.state == .ended)
        #expect(st?.position == 2.0)
        // Playing an ended voice starts over.
        p.play(1, mediaKey: 1, bytes: [], spec: spec(2, false))
        #expect(p.status(1)?.position == 0.0)
    }

    @Test func loopingWrapsWithinTheTrimmedRange() {
        let p = Player(nil)
        var s = spec(1, true)
        s.clip.trimStart = 0.5
        p.play(7, mediaKey: 7, bytes: [], spec: s)
        p.tick(0)
        for i in 1...4 { p.tick(Double(i) * 0.2) }
        // 0.8 s played in a 0.5 s loop starting at 0.5: 0.5 + (0.8 mod 0.5) = 0.8.
        #expect(abs(pos(p, 7) - 0.8) < 1e-3)
        #expect(p.status(7)?.state == .playing)
    }

    @Test func mixerAppliesVolumeFadeAndChannelMapping() {
        let slot = AudioSlot()
        slot.set(.success(Pcm(rate: 10, channels: 1, samples: [Float](repeating: 1, count: 10))))
        let clip = ClipParams(fadeIn: 0.5, volume: 0.5)
        var m = Mixer(voices: [Voice(key: 1, mediaKey: 1, audio: slot, spec: VoiceSpec(clip: clip, looping: false, duration: 1, audio: true), t: 0,
                                     state: .playing)])
        var buf = [Float](repeating: 0, count: 2 * 12)
        buf.withUnsafeMutableBufferPointer { m.mix($0, 12, 2, 10) }
        // Frame 0: the fade starts at 0; frame 3: 0.3/0.5 × 0.5 = 0.3; both channels carry the mono source.
        #expect(buf[0] == 0)
        #expect(abs(buf[6] - 0.3) < 1e-5 && abs(buf[7] - 0.3) < 1e-5)
        #expect(abs(buf[16] - 0.5) < 1e-5)
        // Past the end: silence, and the voice has ended.
        #expect(buf[22] == 0)
        #expect(m.voices[0].state == .ended)
    }

    @Test func deviceClockDrivesPosition() {
        let out = Flaky()
        let p = Player(out)
        p.play(3, mediaKey: 3, bytes: [], spec: spec(10, false))
        // Wall time alone doesn't move a device-clocked voice…
        p.tick(0)
        p.tick(0.2)
        #expect(p.status(3)?.position == 0)
        // …the device pulling 4800 frames at 48 kHz does.
        out.pull(4800)
        #expect(abs(pos(p, 3) - 0.1) < 1e-6)
    }

    /// 16-bit mono WAV of a constant level, `secs` long at 8 kHz.
    private func wavLevel(_ secs: Double, _ amp: Float) -> [UInt8] {
        TestMedia.wav(8000, 1, [Float](repeating: amp, count: Int((8000 * secs).rounded())))
    }

    private func audible(_ duration: Double) -> VoiceSpec {
        VoiceSpec(clip: ClipParams(), looping: false, duration: duration, audio: true)
    }

    /// First mixed sample of voice `key`, after its audio has decoded.
    private func firstSample(_ p: Player, _ key: UInt64) -> Float {
        #expect(p.waitLoaded(key, timeout: 5), "decode")
        var buf = [Float](repeating: 0, count: 4)
        p.render(&buf, channels: 1, rate: 8000)
        return buf[0]
    }

    @Test func replacingTheSourcePlaysTheNewAudioAndKeepsItsBytes() {
        let p = Player(nil)
        let loud = wavLevel(0.05, 0.5)
        let quiet = wavLevel(0.10, 0.25)
        // Duration 0: the clock takes its length from the decoded audio, so a stale slot would report the
        // previous clip.
        p.play(1, mediaKey: 11, bytes: loud, spec: audible(0))
        let a = firstSample(p, 1)
        #expect(abs(a - 0.5) < 0.02, "loud sample \(a)")
        let d1 = p.status(1)?.duration ?? -1
        #expect(abs(d1 - 0.05) < 0.01, "loud duration \(d1)")
        #expect(p.cache[11]?.source == loud)

        // The same key with different bytes is not the cached clip: it decodes the new ones.
        p.play(1, mediaKey: 11, bytes: quiet, spec: audible(0))
        #expect(p.cache[11]?.source == quiet)
        p.play(1, mediaKey: 12, bytes: quiet, spec: audible(0))
        let b = firstSample(p, 1)
        #expect(abs(b - 0.25) < 0.02, "quiet sample \(b)")
        let d2 = p.status(1)?.duration ?? -1
        #expect(abs(d2 - 0.10) < 0.01, "quiet duration \(d2)")
        #expect(p.cache[12]?.source == quiet)
        // Resuming the same source does not jump back to the start.
        let before = pos(p, 1)
        p.play(1, mediaKey: 12, bytes: quiet, spec: audible(0))
        #expect(abs(pos(p, 1) - before) < 1e-6)
    }

    @Test func aFailedOutputFallsBackToTheWallClock() {
        let out = Flaky()
        let p = Player(out)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(10, false))
        p.tick(0)
        out.pull(4800)
        #expect(abs(pos(p, 1) - 0.1) < 1e-6)
        out.setFailure("unplugged")
        p.tick(0.2)
        p.tick(0.4)
        // The voice keeps moving on wall time instead of freezing: 0.1 s from the device, then the 0.4 s of
        // wall time since the last tick before the failure.
        #expect(abs(pos(p, 1) - 0.5) < 1e-3, "\(pos(p, 1))")
        #expect(p.status(1)?.state == .playing)
        // Playing again restarts the device.
        p.play(2, mediaKey: 2, bytes: [], spec: spec(10, false))
        #expect(out.starts == 2)
        #expect(p.hasOutput)
    }

    @Test func aStalledOutputFallsBackToTheWallClock() {
        let out = Flaky()
        let p = Player(out)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(10, false))
        // No callback ever arrives: after the first-callback grace the wall clock takes over.
        for i in 0...21 { p.tick(Double(i) * 0.25) }
        let before = pos(p, 1)
        #expect(before > 0, "\(before)")
        p.tick(5.5)
        #expect(abs(pos(p, 1) - before - 0.25) < 1e-3)
    }

    @Test func aSlowDeviceThatAnswersWithinTheGraceIsNotAStall() {
        let out = Flaky()
        let p = Player(out)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(10, false))
        for i in 0...8 { p.tick(Double(i) * 0.25) }
        // Two seconds in, the device starts asking for samples: the same stream keeps playing.
        out.pull(256)
        p.tick(2.25)
        p.tick(2.5)
        #expect(out.starts == 1, "the stream was not restarted")
    }

    @Test func anIdleStreamWithoutCallbacksIsNotAStall() {
        let out = Flaky()
        let p = Player(out)
        p.play(1, mediaKey: 1, bytes: [], spec: spec(10, false))
        p.pause(1)
        for i in 0...8 { p.tick(Double(i) * 0.25) }
        // Resuming keeps the running stream: no restart.
        p.play(1, mediaKey: 1, bytes: [], spec: spec(10, false))
        #expect(out.starts == 1)
    }

    @Test func repeatedFailuresGiveUpOnTheDevice() {
        let out = Flaky()
        let p = Player(out)
        var now = 0.0
        for _ in 0..<maxOutputFailures {
            p.play(1, mediaKey: 1, bytes: [], spec: spec(100, false))
            out.setFailure("broken")
            p.tick(now)
            now += 0.1
        }
        #expect(!p.hasOutput)
        #expect(out.starts == maxOutputFailures)
        // Still plays, silently on wall time.
        let before = pos(p, 1)
        p.tick(now + 0.2)
        #expect(pos(p, 1) > before)
    }

    @Test func undecodableAudioPlaysSilentlyAndSaysWhy() {
        let p = Player(nil)
        p.play(1, mediaKey: 1, bytes: Container.asfHeader + [UInt8](repeating: 0, count: 64), spec: VoiceSpec(duration: 1, audio: true))
        #expect(p.waitLoaded(1, timeout: 5))
        #expect(p.status(1)?.error == "Windows Media Audio (WMA) isn't supported")
        p.tick(0)
        p.tick(0.2)
        #expect(abs(pos(p, 1) - 0.2) < 1e-3)
        #expect(p.keys == [1])
        p.stopAll()
        #expect(p.keys.isEmpty)
    }

    @Test func playerPlaysDecodedAudioThroughTheMixer() {
        let b = TestMedia.wav(48000, 1, TestMedia.sine(48000, 0.5))
        let p = Player(nil)
        p.play(1, mediaKey: 1, bytes: b, spec: VoiceSpec(clip: ClipParams(volume: 0.5), looping: false, duration: 0.5, audio: true))
        #expect(p.waitLoaded(1, timeout: 5))
        var buf = [Float](repeating: 0, count: 4800 * 2)
        p.render(&buf, channels: 2, rate: 48000)
        let rms = (buf.reduce(Float(0)) { $0 + $1 * $1 } / Float(buf.count)).squareRoot()
        #expect(abs(rms - 0.0884 * 0.5) < 0.005, "\(rms)")
        #expect(abs((p.status(1)?.position ?? 0) - 0.1) < 1e-6)
    }

    @Test func audioEngineOutputRunsTheMixerOrDeclines() throws {
        // On a Mac with an output device the engine starts and pulls samples; without one, start throws and
        // the player falls back to the wall clock. Either way nothing crashes.
        let out = AudioEngineOutput()
        let p = Player(out)
        p.play(1, mediaKey: 1, bytes: [], spec: VoiceSpec(duration: 10, audio: false))
        Thread.sleep(forTimeInterval: 0.2)
        p.tick(0)
        p.tick(0.1)
        #expect(pos(p, 1) >= 0)
        p.stopAll()
        out.stop()
    }
}
