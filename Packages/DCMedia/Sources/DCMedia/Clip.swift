// DCMedia — trim, fade and volume: the playback range of a clip and its gain over time. Port of deckcraft
// crates/media/src/clip.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore

/// How a clip plays (PowerPoint's Playback tab). Times in seconds.
public struct ClipParams: Sendable, Equatable {
    /// Trimmed from the start.
    public var trimStart: Double
    /// Trimmed from the end.
    public var trimEnd: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// 0…1.
    public var volume: Float

    public init(trimStart: Double = 0, trimEnd: Double = 0, fadeIn: Double = 0, fadeOut: Double = 0, volume: Float = 1) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.volume = volume
    }

    /// From the model's millisecond fields.
    public static func fromMs(_ trimStart: UInt32, _ trimEnd: UInt32, _ fadeIn: UInt32, _ fadeOut: UInt32, _ volume: Double) -> ClipParams {
        ClipParams(trimStart: Double(trimStart) / 1000, trimEnd: Double(trimEnd) / 1000, fadeIn: Double(fadeIn) / 1000, fadeOut: Double(fadeOut) / 1000,
                   volume: Float(volume.clamped(0, 1)))
    }

    /// The played range `[start, end)` in media seconds for a clip `duration` long. Trims that would leave
    /// nothing are ignored (the whole clip plays); an unknown duration (0) gives an open end (`.infinity`).
    public func range(_ duration: Double) -> (Double, Double) {
        if duration.isNaN || duration <= 0 { return (trimStart.rustMax(0), .infinity) }
        let start = trimStart.clamped(0, duration)
        let end = (duration - trimEnd.rustMax(0)).clamped(0, duration)
        return end - start < 0.01 ? (0, duration) : (start, end)
    }

    /// Gain at media time `t`: volume × fade-in ramp × fade-out ramp (linear). Fades longer than half the
    /// played range are shortened so they never overlap.
    public func gain(_ t: Double, _ duration: Double) -> Float {
        let (start, end) = range(duration)
        let len = end - start
        let half = len.isFinite ? len / 2 : .infinity
        let fi = fadeIn.rustMax(0).rustMin(half)
        let fo = fadeOut.rustMax(0).rustMin(half)
        var g = 1.0
        if fi > 0 { g *= ((t - start) / fi).clamped(0, 1) }
        if fo > 0 && end.isFinite { g *= ((end - t) / fo).clamped(0, 1) }
        return volume * Float(g)
    }
}
