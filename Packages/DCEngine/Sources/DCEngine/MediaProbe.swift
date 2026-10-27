// DCEngine — what the engine core needs from DCMedia, behind a small seam (tests can swap the prober).
//
// deckcraft's file.rs (`probe_clips`) reads each audio and video clip's length and picture size from its
// headers when a `.pptx` is opened (a `.pptx` doesn't store them): `Media.probeHeaders`, through
// `EngineMedia.prober`.
import DCMedia

/// A clip's length and picture size, as `deckcraft_media::MediaInfo` reports them.
public struct EngineMediaInfo: Sendable, Equatable {
    public var durationMs: UInt64
    /// The video's picture size, nil for audio.
    public var video: (width: UInt32, height: UInt32)?

    public init(durationMs: UInt64, video: (width: UInt32, height: UInt32)?) {
        self.durationMs = durationMs
        self.video = video
    }

    public static func == (a: EngineMediaInfo, b: EngineMediaInfo) -> Bool {
        a.durationMs == b.durationMs && a.video?.width == b.video?.width && a.video?.height == b.video?.height
    }
}

/// Reads a clip's headers (`deckcraft_media::probe_headers`).
public protocol EngineMediaProbing: Sendable {
    func probeHeaders(_ bytes: [UInt8]) -> EngineMediaInfo?
}

/// DCMedia's header probe (`deckcraft_media::probe_headers`).
public struct DCMediaProber: EngineMediaProbing {
    public init() {}

    public func probeHeaders(_ bytes: [UInt8]) -> EngineMediaInfo? {
        guard let info = try? Media.probeHeaders(bytes) else { return nil }
        return EngineMediaInfo(durationMs: info.durationMs, video: info.video.map { ($0.width, $0.height) })
    }
}

public enum EngineMedia {
    /// The prober the engine uses: DCMedia's, or nil to keep the lengths a file gives.
    nonisolated(unsafe) public static var prober: (any EngineMediaProbing)? = DCMediaProber()
}
