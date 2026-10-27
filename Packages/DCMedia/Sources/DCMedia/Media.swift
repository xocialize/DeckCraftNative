// DCMedia — the public entry points deckcraft-media's free functions map to. Port of the API of deckcraft
// crates/media/src/{lib,probe,video}.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).

/// deckcraft-media's free functions.
public enum Media {
    /// Container, duration, audio and video stream parameters (deckcraft's `probe`). A raw MP3 or ADTS
    /// stream without an index is measured by walking its frames.
    public static func probe(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        try Probe.probe(bytes)
    }

    /// `probe` from the headers alone (deckcraft's `probe_headers`): a raw MP3 or ADTS stream without an
    /// index reports a `durationMs` of 0.
    public static func probeHeaders(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        try Probe.probeHeaders(bytes)
    }
}
