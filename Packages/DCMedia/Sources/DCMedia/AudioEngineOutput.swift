// DCMedia — an `AudioOut` on AVAudioEngine: a source node pulls interleaved samples from the player's mixer
// and hands them to the engine's output. Replaces deckcraft's cpal output (ui-egui), which deckcraft-media
// takes as an injected `AudioOut`. AVFoundation only: nothing here imports AppKit.
import AVFoundation
import Synchronization

/// Plays the mixer through the default output device.
public final class AudioEngineOutput: AudioOut {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var observer: NSObjectProtocol?
    private final class Failure: Sendable {
        let reason = Mutex<String?>(nil)
    }
    private let failed = Failure()
    private let channels: Int

    /// An output of `channels` interleaved channels (2: stereo).
    public init(channels: Int = 2) {
        self.channels = max(1, min(channels, 8))
    }

    deinit { stop() }

    /// Scratch space for one render call, allocated once so the device thread never allocates.
    private final class Scratch: @unchecked Sendable {
        let capacity: Int
        let buffer: UnsafeMutablePointer<Float>
        init(_ n: Int) {
            capacity = n
            buffer = .allocate(capacity: n)
            buffer.initialize(repeating: 0, count: n)
        }
        deinit { buffer.deallocate() }
    }

    public func start(_ fill: @escaping AudioFill) throws(AudioOutError) {
        stop()
        let engine = AVAudioEngine()
        let device = engine.outputNode.outputFormat(forBus: 0)
        let rate = device.sampleRate > 0 ? device.sampleRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else {
            throw AudioOutError("no audio format at \(rate) Hz")
        }
        let ch = channels
        let chunk = 4096
        let scratch = Scratch(chunk * ch)
        let r = UInt32(rate)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(chunk, total - done)
                let slice = UnsafeMutableBufferPointer(start: scratch.buffer, count: n * ch)
                fill(slice, ch, r)
                for (c, b) in buffers.enumerated() {
                    guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let src = min(c, ch - 1)
                    for f in 0..<n { data[done + f] = slice[f * ch + src] }
                }
                done += n
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        failed.reason.withLock { $0 = nil }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [failed] _ in
            failed.reason.withLock { $0 = "the audio device changed" }
        }
        do {
            try engine.start()
        } catch {
            throw AudioOutError("the audio engine did not start: \(error.localizedDescription)")
        }
        self.engine = engine
        source = node
    }

    public func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine?.stop()
        if let e = engine, let s = source { e.detach(s) }
        engine = nil
        source = nil
    }

    public func failure() -> String? {
        failed.reason.withLock { f in
            defer { f = nil }
            return f
        }
    }
}
