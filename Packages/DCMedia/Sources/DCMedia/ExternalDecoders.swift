// DCMedia — the external-decoder seam: video codecs Apple's frameworks don't decode (VP9, VP8, …) play when
// the app registers a decoder for them. The protocol is media-bridge's `ExternalVideoDecoder` (MediaImport),
// so vpx-swift's `VpxVideoDecoder` plugs in unchanged; this package carries no decoder binary and does not
// depend on vpx-swift. Registering one is the app's decision. Mirrors `MediaBridge.register(externalDecoder:)`.
import CoreVideo
import Foundation
import MediaImport

/// media-bridge's pluggable decoder protocol, named here so callers need not import MediaImport.
public typealias MediaExternalVideoDecoder = MediaImport.ExternalVideoDecoder
/// One compressed frame handed to an external decoder (absolute nanosecond PTS).
public typealias MediaExternalVideoPacket = MediaImport.ExternalVideoPacket
/// One decoded frame an external decoder hands back: a BGRA `CVPixelBuffer` and its nanosecond PTS.
public typealias MediaDecodedVideoFrame = MediaImport.DecodedVideoFrame

extension Media {
    private static let registry = ExternalRegistry()

    /// Register a decoder for video codecs DCMedia doesn't decode natively. The most recently registered
    /// decoder that claims a codec wins. Typically called once at app start.
    public static func register(externalDecoder: any MediaExternalVideoDecoder) {
        registry.add(externalDecoder)
    }

    /// Remove every registered external decoder.
    public static func unregisterAllExternalDecoders() {
        registry.removeAll()
    }

    /// The decoder for a Matroska CodecID (`V_VP9`, `V_VP8`, …), if one is registered.
    static func externalDecoder(for codecID: String) -> (any MediaExternalVideoDecoder)? {
        registry.decoder(for: codecID)
    }
}

private final class ExternalRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [any MediaExternalVideoDecoder] = []

    func add(_ d: any MediaExternalVideoDecoder) { lock.withLock { decoders.append(d) } }
    func removeAll() { lock.withLock { decoders.removeAll() } }
    func decoder(for id: String) -> (any MediaExternalVideoDecoder)? {
        let all = lock.withLock { decoders }
        return all.last { $0.canDecode(codecID: id) }
    }
}

/// Runs an external decoder over one run of packets (a keyframe to the next) and waits for its frames.
/// The protocol is async; DCMedia's decoder is synchronous like deckcraft's, so the call runs on a
/// detached task and this thread waits for it.
enum ExternalRun {
    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var frames: [(Int64, Frame)] = []
        var failed = false
    }

    static func decode(_ decoder: any MediaExternalVideoDecoder, codecID: String, codecPrivate: Data?,
                       packets: [MediaExternalVideoPacket]) -> (frames: [(ptsNanos: Int64, frame: Frame)], failed: Bool)
    {
        let out = Collected()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await decoder.decodeStreaming(codecID: codecID, codecPrivate: codecPrivate, packets: packets) { f in
                    if let frame = VideoDecoder.rgba(f.image) { out.lock.withLock { out.frames.append((f.ptsNanos, frame)) } }
                }
            } catch {
                out.lock.withLock { out.failed = true }
            }
            done.signal()
        }
        done.wait()
        let (frames, failed) = out.lock.withLock { (out.frames, out.failed) }
        return (frames.map { (ptsNanos: $0.0, frame: $0.1) }, failed)
    }
}
