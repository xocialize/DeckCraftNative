// DCMedia — errors, the container sniff and the probe result types. Port of deckcraft
// crates/media/src/lib.rs and the types of crates/media/src/probe.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors), at the commit in Tools/oracle/pin.env.

/// What can go wrong with media. The cases and their messages are deckcraft's `MediaError`.
public enum MediaError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `{0} isn't supported`.
    case unsupported(String)
    /// `the media can't be read: {0}`.
    case corrupt(String)
    /// `the file has no {0}`.
    case missing(String)

    public var description: String {
        switch self {
        case .unsupported(let s): "\(s) isn't supported"
        case .corrupt(let s): "the media can't be read: \(s)"
        case .missing(let s): "the file has no \(s)"
        }
    }
}

/// Container formats recognised from the first bytes.
public enum Container: Sendable, Equatable, CaseIterable {
    /// ISO BMFF: MP4, M4A, MOV, 3GP.
    case mp4
    /// Matroska / WebM.
    case matroska
    case ogg
    case wav
    case aiff
    case caf
    case flac
    case mp3
    /// AAC in ADTS frames (`.aac`).
    case adts
    /// Advanced Systems Format (WMA / WMV).
    case asf
    case unknown

    /// The ASF header object GUID (30 26 B2 75 8E 66 CF 11 A6 D9 00 AA 00 62 CE 6C).
    static let asfHeader: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]

    public static func sniff(_ b: [UInt8]) -> Container {
        sniff(b, from: 0)
    }

    /// `Container::sniff` of `b[from...]`. The chain of ID3v2 tags is walked iteratively — a crafted
    /// file can carry thousands of empty tags — and only the bytes after the last one are sniffed.
    static func sniff(_ b: [UInt8], from start: Int) -> Container {
        func at(_ o: Int, _ m: [UInt8]) -> Bool {
            let s = start + o
            guard s >= 0, s <= b.count, b.count - s >= m.count else { return false }
            for (i, x) in m.enumerated() where b[s + i] != x { return false }
            return true
        }
        let n = b.count - start
        if at(4, Array("ftyp".utf8)) || at(4, Array("moov".utf8)) || at(4, Array("mdat".utf8)) || at(4, Array("wide".utf8))
            || at(4, Array("free".utf8))
        {
            return .mp4
        } else if at(0, [0x1A, 0x45, 0xDF, 0xA3]) {
            return .matroska
        } else if at(0, Array("OggS".utf8)) {
            return .ogg
        } else if (at(0, Array("RIFF".utf8)) || at(0, Array("RF64".utf8))) && at(8, Array("WAVE".utf8)) {
            return .wav
        } else if at(0, Array("FORM".utf8)) && (at(8, Array("AIFF".utf8)) || at(8, Array("AIFC".utf8))) {
            return .aiff
        } else if at(0, Array("caff".utf8)) {
            return .caf
        } else if at(0, Array("fLaC".utf8)) {
            return .flac
        } else if at(0, asfHeader) {
            return .asf
        } else if at(0, Array("ID3".utf8)) {
            var rest = start
            while b.count - rest >= 3 && b[rest] == 0x49 && b[rest + 1] == 0x44 && b[rest + 2] == 0x33 {
                var size = 0
                if b.count - rest >= 10 {
                    for i in 6..<10 { size = (size &<< 7) | Int(b[rest + i] & 0x7F) }
                }
                // `rest.get(10 + size..).unwrap_or(&[])`.
                let next = rest + 10 + size
                rest = next <= b.count ? next : b.count
            }
            return sniff(b, from: rest) == .adts ? .adts : .mp3
        } else if n > 1 && b[start] == 0xFF && b[start + 1] & 0xF0 == 0xF0 && b[start + 1] & 0x06 == 0 {
            return .adts
        } else if n > 1 && b[start] == 0xFF && b[start + 1] & 0xE0 == 0xE0 && b[start + 1] & 0x06 != 0 {
            return .mp3
        } else {
            return .unknown
        }
    }

    public var name: String {
        switch self {
        case .mp4: "mp4"
        case .matroska: "matroska"
        case .ogg: "ogg"
        case .wav: "wav"
        case .aiff: "aiff"
        case .caf: "caf"
        case .flac: "flac"
        case .mp3: "mp3"
        case .adts: "adts"
        case .asf: "asf"
        case .unknown: "unknown"
        }
    }
}

/// The audio stream of a media file.
public struct AudioInfo: Sendable, Equatable {
    public var codec: String
    public var sampleRate: UInt32
    public var channels: UInt16
    /// DeckCraft can decode it (deckcraft's own decoders: kept as deckcraft says, so probe results stored
    /// in documents are the same in both apps). What this app can decode is `MediaInfo.audioSupport`.
    public var decodable: Bool

    public init(codec: String = "", sampleRate: UInt32 = 0, channels: UInt16 = 0, decodable: Bool = false) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.decodable = decodable
    }
}

/// The video stream of a media file.
public struct VideoInfo: Sendable, Equatable {
    public var codec: String
    public var width: UInt32
    public var height: UInt32
    public var fps: Double
    public var frames: UInt64
    /// DeckCraft can decode it (see `AudioInfo.decodable`); what this app can decode is
    /// `MediaInfo.videoSupport`.
    public var decodable: Bool

    public init(codec: String = "", width: UInt32 = 0, height: UInt32 = 0, fps: Double = 0, frames: UInt64 = 0, decodable: Bool = false) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.decodable = decodable
    }
}

/// Container, duration, audio and video stream parameters (deckcraft's `MediaInfo`).
public struct MediaInfo: Sendable, Equatable {
    public var container: String
    /// Duration in milliseconds (0 when unknown).
    public var durationMs: UInt64
    public var audio: AudioInfo?
    public var video: VideoInfo?

    public init(container: String, durationMs: UInt64 = 0, audio: AudioInfo? = nil, video: VideoInfo? = nil) {
        self.container = container
        self.durationMs = durationMs
        self.audio = audio
        self.video = video
    }

    public var duration: Double { Double(durationMs) / 1000.0 }

    /// Something in it can be played (deckcraft's `playable`, from the `decodable` flags).
    public var playable: Bool { audio?.decodable == true || video?.decodable == true }
}

/// Whether this app can decode a stream on this Mac. A format it can't becomes `.unsupported`, a
/// "can't play" state, never a crash.
public enum MediaSupport: Sendable, Equatable {
    case supported
    /// The reason, worded for a `MediaError.unsupported` ("VP8 video").
    case unsupported(String)
    /// The file has no such stream.
    case absent

    public var isSupported: Bool { self == .supported }
}
