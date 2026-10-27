// DCMedia — the playback mixer and clock. Port of deckcraft crates/media/src/player.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
//
// The host owns a `Player` and, optionally, an `AudioOut` (`AudioEngineOutput` on a Mac with sound; none in
// tests, where the clock runs on wall time). Each playing media shape is a *voice* with its own clock
// (`position`, in media seconds), advanced by the audio callback as it pulls samples — so video frames synced
// to it stay in step with what is heard. Without an output device `Player.tick` advances the clocks on wall
// time, so playback, looping and video still work silently.
//
// Audio is decoded once per media item, on a worker thread, and cached with its source bytes; a cached entry
// is reused only for the same `mediaKey` *and* the same bytes. A voice whose audio is still decoding holds at
// its start (`.loading`); one whose audio can't be decoded runs silently and reports why.
import DCCore
import Foundation
import Synchronization

/// Why an output could not start.
public struct AudioOutError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Fills an interleaved float buffer: (buffer, channels, sample rate). Called on the device's thread.
public typealias AudioFill = @Sendable (UnsafeMutableBufferPointer<Float>, Int, UInt32) -> Void

/// An audio output device (deckcraft's `AudioOut`).
public protocol AudioOut: AnyObject {
    func start(_ fill: @escaping AudioFill) throws(AudioOutError)
    func stop()
    /// Why the started stream has died, if it has, reported once. Polled by `Player.tick` on the host
    /// thread; must not block. Outputs that cannot tell return nil: the player also notices a stream whose
    /// callbacks stopped.
    func failure() -> String?
}

extension AudioOut {
    public func failure() -> String? { nil }
}

public enum PlayState: Sendable, Equatable {
    /// Waiting for the audio to decode.
    case loading
    case playing
    case paused
    /// Reached the end (not looping).
    case ended

    public var name: String {
        switch self {
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .ended: "ended"
        }
    }
}

/// What to play.
public struct VoiceSpec: Sendable, Equatable {
    public var clip: ClipParams
    public var looping: Bool
    /// Media duration in seconds from the probe (0 = unknown: taken from the decoded audio).
    public var duration: Double
    /// Decode and mix the audio (false for videos without sound, or muted).
    public var audio: Bool

    public init(clip: ClipParams = ClipParams(), looping: Bool = false, duration: Double = 0, audio: Bool = true) {
        self.clip = clip
        self.looping = looping
        self.duration = duration
        self.audio = audio
    }
}

public struct VoiceStatus: Sendable, Equatable {
    public var state: PlayState
    /// Media time in seconds.
    public var position: Double
    public var duration: Double
    /// Why the audio is silent, if it couldn't be decoded.
    public var error: String?
}

/// Why a voice's audio could not be decoded.
struct SlotError: Error, Sendable, Equatable {
    var message: String
}

/// One item's decoded audio, filled in once by the decoding thread.
final class AudioSlot: Sendable {
    private let value = Mutex<Result<Pcm, SlotError>?>(nil)

    func get() -> Result<Pcm, SlotError>? { value.withLock { $0 } }

    func set(_ r: Result<Pcm, SlotError>) {
        value.withLock { if $0 == nil { $0 = r } }
    }
}

struct Voice {
    var key: UInt64
    /// Identity of the bytes this voice plays. A different key replaces `audio`.
    var mediaKey: UInt64
    var audio: AudioSlot?
    var spec: VoiceSpec
    var t: Double
    var state: PlayState

    func duration() -> Double {
        if spec.duration > 0 { return spec.duration }
        if case .success(let p)? = audio?.get() { return p.duration }
        return 0
    }

    func pcm() -> Pcm? {
        if case .success(let p)? = audio?.get() { return p }
        return nil
    }

    var loading: Bool { audio != nil && audio?.get() == nil }
}

/// The voices, shared with the audio callback.
struct Mixer {
    var voices: [Voice] = []

    /// Mix `frames` frames at `rate` into `out` (interleaved, `channels` wide; nil: advance the clocks only).
    mutating func mix(_ out: UnsafeMutableBufferPointer<Float>?, _ frames: Int, _ channels: Int, _ rate: UInt32) {
        if let o = out { o.update(repeating: 0) }
        let step = 1.0 / Double(max(rate, 1))
        let channels = max(channels, 1)
        for vi in voices.indices {
            if voices[vi].state != .playing || voices[vi].loading { continue }
            var v = voices[vi]
            let dur = v.duration()
            let (start, end) = v.spec.clip.range(dur)
            if v.t < start { v.t = start }
            if let o = out, let pcm = v.pcm() {
                let srcCh = Int(max(pcm.channels, 1))
                let nSrc = pcm.frames
                for f in 0..<frames {
                    if v.t >= end {
                        if v.spec.looping {
                            v.t = start
                        } else {
                            v.state = .ended
                            v.t = end
                            break
                        }
                    }
                    let g = v.spec.clip.gain(v.t, dur)
                    let x = v.t * Double(pcm.rate)
                    let k = Int(rustCast: x)
                    if g > 0 && k >= 0 && k < nSrc {
                        let fr = Float(x - Double(k))
                        for c in 0..<channels {
                            let sc: Int
                            if srcCh == 1 {
                                sc = 0
                            } else if c < srcCh {
                                sc = c
                            } else {
                                continue
                            }
                            let a = pcm.at(k, sc)
                            let b = k + 1 < nSrc ? pcm.at(k + 1, sc) : a
                            let i = f * channels + c
                            if i < o.count { o[i] += (a + (b - a) * fr) * g }
                        }
                    }
                    v.t += step
                }
            } else {
                // Silent: just run the clock.
                var left = Double(frames) * step
                while left > 0 {
                    let room = end - v.t
                    if left < room {
                        v.t += left
                        break
                    }
                    left -= max(room, 0)
                    if v.spec.looping && end.isFinite && end - start > 1e-3 {
                        v.t = start
                    } else {
                        v.t = end
                        v.state = .ended
                        break
                    }
                }
            }
            voices[vi] = v
        }
        if let o = out {
            for i in o.indices { o[i] = o[i].clamped(-1, 1) }
        }
    }
}

/// The mixer and its lock, shared by the host and the device thread.
final class SharedMixer: Sendable {
    private let state = Mutex(Mixer())
    /// Device callbacks so far (the audio thread counts, `Player.tick` watches).
    let pulls = Atomic<UInt64>(0)

    func with<R>(_ f: (inout Mixer) -> R) -> R { state.withLock { f(&$0) } }
}

/// Default mix rate when no device says otherwise.
private let defaultRate: UInt32 = 48000
/// Seconds without a single device callback, while a voice plays, after which the stream counts as stalled.
private let stallSecs = 1.0
/// Seconds a just-started stream may take to ask for its first samples (Bluetooth and other slow devices).
private let firstCallbackSecs = 5.0
/// Output failures after which the player stops retrying the device and plays silently.
let maxOutputFailures: UInt32 = 3

/// The playback mixer and clock (deckcraft's `Player`). Owned by one host thread.
public final class Player {
    private var out: AudioOut?
    private var streaming = false
    let mixer = SharedMixer()
    private var lastTick: Double?
    private var idleSince: Double?
    struct CachedAudio {
        var slot: AudioSlot
        var source: [UInt8]
    }
    var cache: [UInt64: CachedAudio] = [:]
    private var pullsSeen: (UInt64, Double)?
    private var failures: UInt32 = 0
    private var pullsAtStart: UInt64 = 0

    /// A player over `out` (nil: silent, clocked by `tick`).
    public init(_ out: AudioOut?) {
        self.out = out
    }

    deinit {
        out?.stop()
    }

    public var hasOutput: Bool { out != nil }

    /// The decoded audio of `bytes`, cached by `mediaKey` (decoding starts now).
    private func slot(_ mediaKey: UInt64, _ bytes: [UInt8]) -> AudioSlot {
        if cache.count > 16 {
            // Forget audio no voice uses.
            let used = Set(mixer.with { m in m.voices.compactMap { $0.audio.map(ObjectIdentifier.init) } })
            cache = cache.filter { used.contains(ObjectIdentifier($0.value.slot)) }
        }
        if let hit = cache[mediaKey], hit.source == bytes { return hit.slot }
        // A key whose bytes differ is not this clip: decode again.
        cache[mediaKey] = nil
        let slot = AudioSlot()
        let job = { @Sendable in
            do throws(MediaError) {
                slot.set(.success(try AudioDecode.decode(bytes)))
            } catch {
                slot.set(.failure(SlotError(message: error.description)))
            }
        }
        let thread = Thread(block: job)
        thread.name = "dcmedia-audio-decode"
        thread.start()
        cache[mediaKey] = CachedAudio(slot: slot, source: bytes)
        return slot
    }

    /// Play voice `key` (a shape) from `from` seconds (default: the trimmed start). Resumes a paused voice
    /// when `from` is nil and `mediaKey` is unchanged. A different `mediaKey` replaces the decoded audio and
    /// starts the new clip (at `from`, or at its start).
    public func play(_ key: UInt64, mediaKey: UInt64, bytes: [UInt8], spec: VoiceSpec, from: Double? = nil) {
        let audio = spec.audio ? slot(mediaKey, bytes) : nil
        mixer.with { m in
            if let i = m.voices.firstIndex(where: { $0.key == key }) {
                var v = m.voices[i]
                let same = v.mediaKey == mediaKey
                v.mediaKey = mediaKey
                v.spec = spec
                if same {
                    if v.audio == nil { v.audio = audio }
                    if let t = from {
                        v.t = t
                    } else if v.state == .ended {
                        v.t = spec.clip.range(v.duration()).0
                    }
                } else {
                    v.audio = audio
                    v.t = from ?? spec.clip.range(spec.duration).0
                }
                v.state = .playing
                m.voices[i] = v
            } else {
                let t = from ?? spec.clip.range(spec.duration).0
                m.voices.append(Voice(key: key, mediaKey: mediaKey, audio: audio, spec: spec, t: t, state: .playing))
            }
        }
        ensureStream()
    }

    private func ensureStream() {
        if streaming { return }
        guard let out else { return }
        let m = mixer
        let fill: AudioFill = { buf, channels, rate in
            m.pulls.wrappingAdd(1, ordering: .relaxed)
            let frames = buf.count / max(channels, 1)
            m.with { $0.mix(buf, frames, channels, rate) }
        }
        do {
            try out.start(fill)
            streaming = true
            pullsSeen = nil
            pullsAtStart = mixer.pulls.load(ordering: .relaxed)
        } catch {
            // The device is unavailable: media plays silently.
            self.out = nil
        }
    }

    public func pause(_ key: UInt64) {
        mixer.with { m in
            if let i = m.voices.firstIndex(where: { $0.key == key && $0.state == .playing }) { m.voices[i].state = .paused }
        }
    }

    /// Remove voice `key`.
    public func stop(_ key: UInt64) {
        mixer.with { $0.voices.removeAll { $0.key == key } }
    }

    public func stopAll() {
        mixer.with { $0.voices.removeAll() }
    }

    /// Move voice `key` to `t` seconds (clamped to its played range).
    public func seek(_ key: UInt64, _ t: Double) {
        mixer.with { m in
            guard let i = m.voices.firstIndex(where: { $0.key == key }) else { return }
            let (s, e) = m.voices[i].spec.clip.range(m.voices[i].duration())
            m.voices[i].t = t.clamped(s, e.isFinite ? e : .greatestFiniteMagnitude)
            if m.voices[i].state == .ended { m.voices[i].state = .paused }
        }
    }

    public func status(_ key: UInt64) -> VoiceStatus? {
        mixer.with { m in
            guard let v = m.voices.first(where: { $0.key == key }) else { return nil }
            var error: String?
            if case .failure(let e)? = v.audio?.get() { error = e.message }
            return VoiceStatus(state: v.state == .playing && v.loading ? .loading : v.state, position: v.t, duration: v.duration(), error: error)
        }
    }

    /// Keys of all voices (playing, paused or ended).
    public var keys: [UInt64] { mixer.with { $0.voices.map(\.key) } }

    public var anyPlaying: Bool { mixer.with { $0.voices.contains { $0.state == .playing } } }

    /// Call every frame with the host's clock (seconds): runs the voices' clocks when there is no audio
    /// device, and releases the device after a few idle seconds.
    public func tick(_ now: Double) {
        let dt = lastTick.map { (now - $0).clamped(0, 0.25) } ?? 0
        lastTick = now
        checkOutput(now)
        if !streaming && dt > 0 {
            let frames = Int(rustCast: (dt * Double(defaultRate)).rounded())
            mixer.with { $0.mix(nil, frames, 2, defaultRate) }
        }
        if streaming {
            if anyPlaying {
                idleSince = nil
            } else {
                if idleSince == nil { idleSince = now }
                if let since = idleSince, now - since > 3 {
                    out?.stop()
                    streaming = false
                    idleSince = nil
                }
            }
        }
    }

    /// Drop a stream that died or stalled, so the voices fall back to the wall clock instead of freezing.
    /// The next `play` tries the device again, up to `maxOutputFailures` times.
    private func checkOutput(_ now: Double) {
        guard streaming else { return }
        let playing = anyPlaying
        guard let out else { return }
        let pulls = mixer.pulls.load(ordering: .relaxed)
        let running = pulls > pullsAtStart
        if running { failures = 0 }
        let limit = running ? stallSecs : firstCallbackSecs
        var reason = out.failure()
        if reason == nil {
            if let (seen, since) = pullsSeen, seen == pulls {
                if !playing {
                    pullsSeen = (pulls, now)
                } else if now - since > limit {
                    reason = "the audio device stopped asking for samples"
                }
            } else {
                pullsSeen = (pulls, now)
            }
        }
        guard reason != nil else { return }
        out.stop()
        streaming = false
        pullsSeen = nil
        idleSince = nil
        failures = failures &+ 1
        if failures >= maxOutputFailures {
            // Give up on the device: media plays silently.
            self.out = nil
        }
    }

    /// Block until voice `key`'s audio has decoded (tests, offline rendering).
    public func waitLoaded(_ key: UInt64, timeout: Double) -> Bool {
        guard let slot = mixer.with({ m in m.voices.first(where: { $0.key == key })?.audio }) else { return true }
        let t0 = DispatchTime.now().uptimeNanoseconds
        while slot.get() == nil {
            if Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 > timeout { return slot.get() != nil }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    /// Mix into `buf` directly (offline rendering and tests; the device callback does the same).
    public func render(_ buf: inout [Float], channels: Int, rate: UInt32) {
        let frames = buf.count / max(channels, 1)
        buf.withUnsafeMutableBufferPointer { b in mixer.with { $0.mix(b, frames, channels, rate) } }
    }
}
