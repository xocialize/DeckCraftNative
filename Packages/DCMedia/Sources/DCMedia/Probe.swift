// DCMedia — media probing: container, duration, audio and video stream parameters, without decoding
// (except for audio files whose container doesn't state a length). Port of deckcraft
// crates/media/src/probe.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// deckcraft hands plain audio files (WAV, AIFF, CAF, FLAC, MP3, ADTS, Ogg Vorbis/FLAC) to symphonia's
// probe. symphonia is MPL-2.0, so it is not ported: `PlainAudio` reads those headers from their
// specifications, and the oracle (Tools/oracle/media-vectors) checks it gives the same answers.
import DCCore

enum Probe {
    static func ms(_ secs: Double) -> UInt64 {
        secs.isFinite && secs > 0 ? UInt64(rustCast: (secs * 1000).rounded()) : 0
    }

    /// deckcraft's `probe`.
    static func probe(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        var info = try probeHeaders(bytes)
        if info.durationMs == 0, info.audio?.decodable == true, info.video == nil {
            // No length in the header (raw MP3 / ADTS without an index): measure. deckcraft decodes the
            // whole stream; the frame count it ends with is what `PlainAudio.decodedFrames` counts.
            if let frames = PlainAudio.decodedFrames(bytes), let rate = info.audio?.sampleRate, rate > 0 {
                info.durationMs = ms(Double(frames) / Double(rate))
            }
        }
        return info
    }

    /// deckcraft's `probe_headers`.
    static func probeHeaders(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        let c = Container.sniff(bytes)
        var info: MediaInfo
        switch c {
        case .mp4: info = try probeMP4(bytes)
        case .matroska: info = try probeMKV(bytes)
        case .asf: info = try probeASF(bytes)
        case .ogg: info = probeOgg(bytes) ?? MediaInfo(container: "ogg")
        default: info = MediaInfo(container: c.name)
        }
        if (info.audio == nil && info.video == nil) || info.audio?.sampleRate == 0 {
            if c == .mp4 && !MP4Guard.tablesFit(bytes) {
                throw .corrupt("the MP4's sample tables do not fit the file")
            }
            guard let (codec, rate, channels, frames) = PlainAudio.probe(bytes, c) else {
                throw .unsupported("this kind of media file")
            }
            info.audio = AudioInfo(codec: codecLabel(codec), sampleRate: rate, channels: channels, decodable: true)
            if info.durationMs == 0, let n = frames, rate > 0 {
                info.durationMs = ms(Double(n) / Double(rate))
            }
        }
        return info
    }

    static func codecLabel(_ short: String) -> String {
        switch short {
        case "mp3": "MP3"
        case "mp2": "MP2"
        case "mp1": "MP1"
        case "aac": "AAC"
        case "alac": "ALAC"
        case "flac": "FLAC"
        case "vorbis": "Vorbis"
        case let s where s.hasPrefix("pcm"): "PCM"
        case let s where s.hasPrefix("adpcm"): "ADPCM"
        default: short
        }
    }

    static func probeMP4(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        let f: BMFFFile
        do { f = try BMFF.open(bytes) } catch { throw .corrupt(error.message) }
        var info = MediaInfo(container: f.isQuickTime ? "mov" : "mp4")
        var dur = f.timescale > 0 ? Double(f.duration) / Double(f.timescale) : 0
        if let ti = f.trackOfKind(.video) {
            let t = f.tracks[ti]
            let secs = t.timescale > 0 ? Double(t.duration) / Double(t.timescale) : 0
            if let e = t.entries.first {
                let (w, h) = e.video.map { (UInt32($0.width), UInt32($0.height)) } ?? (t.width, t.height)
                let decodable: Bool
                switch e.codec {
                case .avc, .hevc, .vp9, .av1: decodable = true
                default: decodable = false
                }
                let frames = UInt64(t.samples.count)
                info.video = VideoInfo(codec: e.codec.name, width: w, height: h, fps: secs > 0 ? Double(frames) / secs : 0, frames: frames,
                                       decodable: decodable)
            }
            dur = dur.rustMax(secs)
        }
        if let ti = f.trackOfKind(.audio) {
            let t = f.tracks[ti]
            if let e = t.entries.first {
                let (rate, channels) = e.audio.map { (UInt32(rustCast: $0.sampleRate.rounded()), UInt16(truncatingIfNeeded: $0.channels)) } ?? (0, 0)
                let decodable: Bool
                switch e.codec {
                case .aac, .mp3, .pcm, .alac, .flac: decodable = true
                default: decodable = false
                }
                info.audio = AudioInfo(codec: e.codec.name, sampleRate: rate, channels: channels, decodable: decodable)
            }
            if t.timescale > 0 { dur = dur.rustMax(Double(t.duration) / Double(t.timescale)) }
        }
        info.durationMs = ms(dur)
        return info
    }

    static func probeMKV(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo {
        let f: MKVFile
        do { f = try Matroska.open(bytes) } catch { throw .corrupt(error.message) }
        var info = MediaInfo(container: f.isWebM ? "webm" : "matroska")
        let dur = f.durationNs.map { Double($0) / 1e9 } ?? 0
        info.durationMs = ms(dur)
        if let t = f.tracks.first(where: { $0.kind == .video }) {
            let frames = UInt64(t.samples.count)
            let fps: Double
            if let d = t.defaultDurationNs, d > 0 {
                fps = 1e9 / Double(d)
            } else if dur > 0 {
                fps = Double(frames) / dur
            } else {
                fps = 0
            }
            let decodable: Bool
            switch t.codec {
            case .avc, .hevc, .vp9, .av1: decodable = true
            default: decodable = false
            }
            info.video = VideoInfo(codec: t.codec.name, width: t.pixelWidth ?? 0, height: t.pixelHeight ?? 0, fps: fps, frames: frames, decodable: decodable)
        }
        if let t = f.tracks.first(where: { $0.kind == .audio }) {
            var rate: UInt32 = 0, channels: UInt16 = 0
            if let a = t.audio {
                rate = UInt32(rustCast: (a.outputSamplingFrequency ?? a.samplingFrequency).rounded())
                channels = UInt16(truncatingIfNeeded: a.channels)
            }
            if case .opus = t.codec { rate = 48000 }
            let decodable: Bool
            switch t.codec {
            case .opus, .vorbis, .aac, .flac, .mp3, .pcm: decodable = true
            default: decodable = false
            }
            info.audio = AudioInfo(codec: t.codec.name, sampleRate: rate, channels: channels, decodable: decodable)
        }
        return info
    }

    static func probeOgg(_ bytes: [UInt8]) -> MediaInfo? {
        guard let f = Ogg.open(bytes), let s = f.streamOf(.opus), let st = f.streams.at(s), let first = st.headers.first,
              let head = OpusHead(first), let total = Ogg.opusTotal(st, preSkip: UInt32(head.preSkip))
        else { return nil }
        return MediaInfo(container: "ogg", durationMs: ms(Double(total) / 48000),
                         audio: AudioInfo(codec: "Opus", sampleRate: 48000, channels: UInt16(head.channels), decodable: true))
    }

    /// Windows Media (ASF): enough of the header to describe the file. There is no WMA/WMV decoder.
    static func probeASF(_ b: [UInt8]) throws(MediaError) -> MediaInfo {
        let fileProps: [UInt8] = [0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let streamProps: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let audioMedia: [UInt8] = [0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
        let videoMedia: [UInt8] = [0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
        func le(_ o: Int, _ n: Int) -> UInt64 {
            guard o >= 0, o <= b.count, b.count - o >= n else { return 0 }
            var v: UInt64 = 0
            for i in (0..<n).reversed() { v = v << 8 | UInt64(b[o + i]) }
            return v
        }
        func slice(_ o: Int, _ n: Int) -> [UInt8]? {
            guard o >= 0, o <= b.count, b.count - o >= n else { return nil }
            return Array(b[o..<(o + n)])
        }
        guard slice(0, 16) == Container.asfHeader else { throw .corrupt("not an ASF file") }
        let headerEnd = Int(min(le(16, 8), UInt64(b.count)))
        var info = MediaInfo(container: "asf")
        var pos = 30
        while pos <= Int.max - 24 && pos + 24 <= headerEnd {
            let guid = slice(pos, 16)
            let size64 = le(pos + 16, 8)
            if size64 < 24 { break }
            let d = pos + 24
            if guid == fileProps {
                let play = Double(le(d + 40, 8)) / 1e7
                let preroll = Double(le(d + 56, 8)) / 1e3
                info.durationMs = ms(play - preroll)
            } else if guid == streamProps {
                let kind = slice(d, 16)
                let td = d + 54
                if kind == audioMedia {
                    let tag = UInt16(le(td, 2))
                    let codec = switch tag {
                    case 0x0160: "WMA 1"
                    case 0x0161: "WMA 2"
                    case 0x0162: "WMA Pro"
                    case 0x0163: "WMA Lossless"
                    case 0x000A: "WMA Voice"
                    default: "WMA"
                    }
                    info.audio = AudioInfo(codec: codec, sampleRate: UInt32(le(td + 4, 4)), channels: UInt16(le(td + 2, 2)), decodable: false)
                } else if kind == videoMedia {
                    info.video = VideoInfo(codec: "WMV", width: UInt32(le(td, 4)), height: UInt32(le(td + 4, 4)), decodable: false)
                }
            }
            // A hostile size must not wrap the walk or walk off the end: an object that overruns the
            // header ends it.
            guard size64 <= UInt64(Int.max), pos <= Int.max - Int(size64) else { break }
            let next = pos + Int(size64)
            if next > headerEnd { break }
            pos = next
        }
        return info
    }
}
