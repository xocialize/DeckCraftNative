// DCMedia — the stream parameters of plain audio files: WAV, AIFF/AIFC, CAF, FLAC, MP3 (and MP1/MP2),
// ADTS AAC, and Vorbis/FLAC in Ogg. deckcraft gets these from symphonia's probe (crates/media/src/audio.rs
// `probe_symphonia`), which is MPL-2.0 and not ported: this file is written from the formats'
// specifications (RIFF/WAVE, AIFF 1.3 and AIFF-C, Apple's CAF specification, the FLAC format, ISO/IEC
// 11172-3 and 13818-3 with the Xing/Info and LAME tags, ISO/IEC 13818-7 ADTS, Vorbis I) and checked
// against symphonia's answers by the oracle (Tools/oracle/media-vectors).
import DCCore

enum PlainAudio {
    /// (codec short name, sample rate, channels, frames if the header says) or nil when symphonia
    /// can't read the file (`probe` then reports "this kind of media file isn't supported").
    typealias Params = (String, UInt32, UInt16, UInt64?)

    static func probe(_ b: [UInt8], _ c: Container) -> Params? {
        switch c {
        case .wav: wav(b)
        case .aiff: aiff(b)
        case .caf: caf(b)
        case .flac: flac(b)
        case .mp3: mpeg(b)
        case .adts: adts(b)
        case .ogg: ogg(b)
        case .mp4: isoAudio(b)
        case .unknown: unknownStream(b)
        default: nil
        }
    }

    /// Without a recognised container the reader searches the stream for an MPEG layer III frame
    /// followed by another.
    static func unknownStream(_ b: [UInt8]) -> Params? {
        guard let p = MPEG.searchLayer3(b) else { return nil }
        return mpeg(b, from: p)
    }

    /// An MP4 whose audio track the demuxer didn't classify (a damaged handler): the reader takes the
    /// first track with an audio sample entry, at the track's timescale, without a channel count.
    static func isoAudio(_ b: [UInt8]) -> Params? {
        guard let f = try? BMFF.open(b) else { return nil }
        for t in f.tracks {
            guard let e = t.entries.first else { continue }
            let codec: String
            switch e.codec {
            case .aac: codec = "aac"
            case .alac: codec = "alac"
            case .flac: codec = "flac"
            case .mp3: codec = "mp3"
            case .pcm: codec = "pcm"
            default: continue
            }
            return (codec, t.timescale, 0, nil)
        }
        return nil
    }

    /// The frames deckcraft's decoder ends with for a stream without a length in its header (MP3 and
    /// ADTS): every frame whose header parses decodes to a fixed number of samples.
    static func decodedFrames(_ b: [UInt8]) -> UInt64? {
        switch Container.sniff(b) {
        case .mp3: MPEG.decodedFrames(b)
        case .adts: ADTS.decodedFrames(b)
        case .unknown: MPEG.searchLayer3(b).flatMap { MPEG.decodedFrames(b, from: $0) }
        default: nil
        }
    }

    // MARK: Byte access

    static func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64? {
        guard o >= 0, o <= b.count, b.count - o >= n else { return nil }
        var v: UInt64 = 0
        for i in (0..<n).reversed() { v = v << 8 | UInt64(b[o + i]) }
        return v
    }

    static func be(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64? {
        guard o >= 0, o <= b.count, b.count - o >= n else { return nil }
        var v: UInt64 = 0
        for i in 0..<n { v = v << 8 | UInt64(b[o + i]) }
        return v
    }

    static func tag(_ b: [UInt8], _ o: Int) -> String? {
        guard o >= 0, o <= b.count, b.count - o >= 4 else { return nil }
        return String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }

    // MARK: WAV

    /// RIFF/WAVE. Chunks are walked in order and may not run past the RIFF chunk's own length (the file
    /// may be shorter: a cut file keeps its header's frame count); `fmt ` must come before `data`; INFO
    /// lists must be well formed; and each format has the `fmt ` layout and sample sizes it requires.
    static func wav(_ b: [UInt8]) -> Params? {
        guard tag(b, 0) == "RIFF", let riffSize = le(b, 4, 4) else { return nil }
        let riffEnd = 8 + Int(riffSize)
        var pos = 12
        var fmt: (sub: UInt16, channels: UInt16, rate: UInt32, align: UInt16, bits: UInt16, fpb: UInt16)?
        while pos + 8 <= riffEnd, let id = tag(b, pos), let size = le(b, pos + 4, 4) {
            let body = pos + 8
            guard body + Int(size) <= riffEnd else { return nil }
            switch id {
            case "fmt ":
                guard size >= 16, let t = le(b, body, 2), let ch = le(b, body + 2, 2), let r = le(b, body + 4, 4), let al = le(b, body + 12, 2),
                      let bits = le(b, body + 14, 2) else { return nil }
                var sub = UInt16(t)
                var fpb: UInt16 = 0
                switch t {
                case 1:
                    guard [8, 16, 24, 32].contains(bits) else { return nil }
                case 3:
                    guard bits == 32 || bits == 64 else { return nil }
                case 6, 7:
                    guard size >= 18 else { return nil }
                case 2, 0x11:
                    guard size >= 20, bits == 4, let f = le(b, body + 18, 2) else { return nil }
                    fpb = UInt16(f)
                case 0xFFFE:
                    guard size >= 40, let s = le(b, body + 24, 2) else { return nil }
                    sub = UInt16(s)
                    switch sub {
                    case 1: guard [8, 16, 24, 32].contains(bits) else { return nil }
                    case 3: guard bits == 32 || bits == 64 else { return nil }
                    case 6, 7: break
                    default: return nil
                    }
                default:
                    return nil
                }
                guard ch > 0, r > 0 else { return nil }
                fmt = (sub, UInt16(ch), UInt32(r), UInt16(al), UInt16(bits), fpb)
            case "LIST":
                if tag(b, body) == "INFO" {
                    var p = body + 4
                    let end = body + Int(size)
                    while p < end {
                        guard p + 8 <= end, let n = le(b, p + 4, 4), p + 8 + Int(n) <= end else { return nil }
                        p += 8 + Int(n) + Int(n & 1)
                    }
                }
            case "data":
                guard let f = fmt else { return nil }
                let codec: String
                switch f.sub {
                case 1: codec = f.bits == 8 ? "pcm_u8" : "pcm_s\(f.bits)le"
                case 3: codec = f.bits == 64 ? "pcm_f64le" : "pcm_f32le"
                case 6: codec = "pcm_alaw"
                case 7: codec = "pcm_mulaw"
                case 2: codec = "adpcm_ms"
                default: codec = "adpcm_ima_wav"
                }
                let frames: UInt64?
                if f.align == 0 {
                    frames = nil
                } else if f.sub == 2 || f.sub == 0x11 {
                    frames = size / UInt64(f.align) * UInt64(f.fpb)
                } else {
                    frames = size / UInt64(f.align)
                }
                return (codec, f.rate, f.channels, frames)
            default: break
            }
            pos = body + Int(size) + Int(size & 1)
        }
        return nil
    }

    // MARK: AIFF

    /// An 80-bit IEEE extended float.
    static func ext80(_ b: [UInt8], _ o: Int) -> Double? {
        guard let e = be(b, o, 2), let m = be(b, o + 2, 8) else { return nil }
        let exp = Int(e & 0x7FFF) - 16383 - 63
        let v = Double(m) * pow2(exp)
        return e & 0x8000 != 0 ? -v : v
    }

    static func pow2(_ e: Int) -> Double {
        if e > 1023 { return .infinity }
        if e < -1074 { return 0 }
        return Double(sign: .plus, exponent: e, significand: 1)
    }

    /// AIFF/AIFC: chunks within the FORM chunk, a COMM chunk and then an SSND chunk.
    static func aiff(_ b: [UInt8]) -> Params? {
        guard let formSize = be(b, 4, 4) else { return nil }
        let formEnd = 8 + Int(formSize)
        let aifc = tag(b, 8) == "AIFC"
        var pos = 12
        var comm: Params?
        while pos + 8 <= formEnd, let id = tag(b, pos), let size = be(b, pos + 4, 4) {
            let body = pos + 8
            guard body + Int(size) <= formEnd else { return nil }
            if id == "COMM" {
                guard let ch = be(b, body, 2), let frames = be(b, body + 2, 4), let bits = be(b, body + 6, 2), let rate = ext80(b, body + 8) else { return nil }
                var codec: String
                switch bits {
                case 8: codec = "pcm_s8"
                case 16: codec = "pcm_s16be"
                case 24: codec = "pcm_s24be"
                case 32: codec = "pcm_s32be"
                default: return nil
                }
                if aifc {
                    guard let comp = tag(b, body + 18) else { return nil }
                    switch comp {
                    case "NONE", "twos": break
                    case "sowt": codec = codec.replacingSuffix("be", "le")
                    case "fl32", "FL32": codec = "pcm_f32be"
                    case "fl64", "FL64": codec = "pcm_f64be"
                    case "alaw", "ALAW": codec = "pcm_alaw"
                    case "ulaw", "ULAW": codec = "pcm_mulaw"
                    default: return nil
                    }
                }
                comm = (codec, UInt32(rustCast: rate), UInt16(truncatingIfNeeded: ch), frames)
            } else if id == "SSND" {
                return comm
            }
            pos = body + Int(size) + Int(size & 1)
        }
        return nil
    }

    // MARK: CAF

    /// CAF: version 1, `desc` first, chunks within the file (a `data` chunk of size -1 runs to the end).
    static func caf(_ b: [UInt8]) -> Params? {
        guard be(b, 4, 2) == 1 else { return nil }
        var pos = 8
        var desc: (rate: Double, format: String, bpp: UInt32, fpp: UInt32, ch: UInt32, bits: UInt32, flags: UInt32)?
        var dataSize: UInt64?
        var valid: UInt64?
        var pakt: (Int, Int)?
        while pos + 12 <= b.count, let id = tag(b, pos), let size = be(b, pos + 4, 8) {
            let body = pos + 12
            let open = size == UInt64.max && id == "data"
            if !open && size > UInt64(b.count - body) { return nil }
            switch id {
            case "desc":
                guard size >= 32, let r = be(b, body, 8), let f = tag(b, body + 8), let fl = be(b, body + 12, 4), let bpp = be(b, body + 16, 4),
                      let fpp = be(b, body + 20, 4), let ch = be(b, body + 24, 4), let bits = be(b, body + 28, 4) else { return nil }
                desc = (Double(bitPattern: r), f, UInt32(bpp), UInt32(fpp), UInt32(ch), UInt32(bits), UInt32(fl))
            case "data":
                dataSize = open ? UInt64(max(b.count - body - 4, 0)) : size >= 4 ? size - 4 : 0
            case "chan":
                if size >= 12, let n = be(b, body + 8, 4), 12 + n * 20 > size { return nil }
            case "pakt":
                valid = be(b, body + 8, 8)
                pakt = (body, Int(size))
            default: break
            }
            if open { break }
            pos = body + Int(size)
        }
        guard let d = desc else { return nil }
        if d.bpp == 0, let (body, size) = pakt {
            // Variable-size packets: the packet table must read cleanly and add up to the audio data.
            guard size >= 24, let count = be(b, body, 8) else { return nil }
            var p = body + 24
            let end = body + size
            let perPacket = d.fpp == 0 ? 2 : 1
            var k: UInt64 = 0
            var sum: UInt64 = 0
            while k < count {
                for i in 0..<perPacket {
                    var n = 0
                    var v: UInt64 = 0
                    while true {
                        guard p < end, n < 5 else { return nil }
                        let x = b[p]
                        p += 1
                        n += 1
                        v = v << 7 | UInt64(x & 0x7F)
                        if x & 0x80 == 0 { break }
                    }
                    if i == 0 { sum &+= v }
                }
                k += 1
            }
            if let data = dataSize, sum != data { return nil }
        }
        let codec: String
        switch d.format {
        case "lpcm":
            let little = d.flags & 2 != 0
            let float = d.flags & 1 != 0
            codec = float ? "pcm_f\(d.bits)\(little ? "le" : "be")" : d.bits == 8 ? "pcm_s8" : "pcm_s\(d.bits)\(little ? "le" : "be")"
        case "alac": codec = "alac"
        case "alaw": codec = "pcm_alaw"
        case "ulaw": codec = "pcm_mulaw"
        // Formats symphonia recognises in CAF but has no decoder for: it names them "unknown".
        case "opus", "aac ", ".mp3", "flac": codec = d.format == "aac " ? "aac" : d.format == ".mp3" ? "mp3" : d.format == "flac" ? "flac" : "unknown"
        default: return nil
        }
        var frames = valid
        if d.format == "lpcm", let size = dataSize, d.bpp > 0 { frames = size / UInt64(d.bpp) }
        return (codec, UInt32(rustCast: d.rate), UInt16(truncatingIfNeeded: d.ch), frames)
    }

    // MARK: FLAC

    /// Native FLAC: STREAMINFO first, and every metadata block inside the file.
    static func flac(_ b: [UInt8]) -> Params? {
        guard b.count >= 8 + 34, b[4] & 0x7F == 0, let x = be(b, 8 + 10, 8) else { return nil }
        var pos = 4
        while true {
            guard pos + 4 <= b.count, let len = be(b, pos + 1, 3) else { return nil }
            let last = b[pos] & 0x80 != 0
            pos += 4 + Int(len)
            if pos > b.count { return nil }
            if last { break }
        }
        let rate = UInt32(x >> 44)
        let ch = UInt16((x >> 41) & 7) + 1
        let total = x & 0xF_FFFF_FFFF
        return ("flac", rate, ch, total == 0 ? nil : total)
    }

    // MARK: MPEG audio

    struct MPEGHeader {
        var version: Int  // 1, 2, or 25 (MPEG-2.5)
        var layer: Int
        var bitrate: Int
        var rate: UInt32
        var padding: Int
        var channels: UInt16

        var samplesPerFrame: Int { layer == 1 ? 384 : layer == 2 ? 1152 : version == 1 ? 1152 : 576 }

        var length: Int {
            guard rate > 0 else { return 0 }
            if layer == 1 { return (12 * bitrate / Int(rate) + padding) * 4 }
            if layer == 3 && version != 1 { return 72 * bitrate / Int(rate) + padding }
            return 144 * bitrate / Int(rate) + padding
        }

        /// Side information bytes after the header (layer III).
        var sideInfo: Int { version == 1 ? (channels == 1 ? 17 : 32) : (channels == 1 ? 9 : 17) }

        static let bitrates: [[Int]] = [
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],  // V1 L1
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],  // V1 L2
            [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],  // V1 L3
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],  // V2 L1
            [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],  // V2 L2/L3
        ]

        init?(_ b: [UInt8], _ o: Int) {
            guard o >= 0, b.count - o >= 4, b[o] == 0xFF, b[o + 1] & 0xE0 == 0xE0 else { return nil }
            let v = (b[o + 1] >> 3) & 3
            let l = (b[o + 1] >> 1) & 3
            let bi = Int(b[o + 2] >> 4)
            let si = Int((b[o + 2] >> 2) & 3)
            guard v != 1, l != 0, bi != 0, bi != 15, si != 3 else { return nil }
            version = v == 3 ? 1 : v == 2 ? 2 : 25
            layer = 4 - Int(l)
            let table = version == 1 ? layer - 1 : (layer == 1 ? 3 : 4)
            bitrate = Self.bitrates[table][bi] * 1000
            let base: [UInt32] = [44100, 48000, 32000]
            rate = version == 1 ? base[si] : version == 2 ? base[si] / 2 : base[si] / 4
            padding = Int((b[o + 2] >> 1) & 1)
            channels = b[o + 3] >> 6 == 3 ? 1 : 2
        }
    }

    enum MPEG {
        /// Where the audio starts: after any chain of ID3v2 tags; nil for a tag header the reader rejects
        /// (a version byte of 0xFF, or a size byte with its top bit set).
        static func audioStart(_ b: [UInt8]) -> Int? {
            var rest = 0
            while b.count - rest >= 3 && b[rest] == 0x49 && b[rest + 1] == 0x44 && b[rest + 2] == 0x33 {
                guard b.count - rest >= 10 else { return nil }
                if b[rest + 3] == 0xFF || b[rest + 4] == 0xFF || b[(rest + 6)..<(rest + 10)].contains(where: { $0 & 0x80 != 0 }) { return nil }
                var size = 0
                for i in 6..<10 { size = size << 7 | Int(b[rest + i] & 0x7F) }
                rest = min(rest + 10 + size, b.count)
            }
            return rest
        }

        /// The Xing/Info tag of the first frame: only a frame whose side information is all zero carries one.
        struct Info {
            var frames: UInt64?
            /// Encoder delay + padding from a LAME tag (whose CRC checks) or an ffmpeg (Lavf/Lavc) tag.
            var trim: UInt64?
            /// The encoder delay alone.
            var delay: UInt64?
        }

        static func info(_ b: [UInt8], _ at: Int, _ h: MPEGHeader) -> Info? {
            let side = at + 4
            guard side + h.sideInfo <= b.count, b[side..<(side + h.sideInfo)].allSatisfy({ $0 == 0 }) else { return nil }
            let x = side + h.sideInfo
            guard let t = tag(b, x), t == "Xing" || t == "Info", let flags = be(b, x + 4, 4) else {
                return nil
            }
            var i = Info()
            var p = x + 8
            if flags & 1 != 0 {
                i.frames = be(b, p, 4)
                p += 4
            }
            if flags & 2 != 0 { p += 4 }
            if flags & 4 != 0 { p += 100 }
            if flags & 8 != 0 { p += 4 }
            if let enc = tag(b, p), let dp = be(b, p + 21, 3) {
                var ok = enc == "Lavf" || enc == "Lavc"
                if enc == "LAME", let stored = be(b, p + 34, 2) { ok = crc16(b[at..<(p + 34)]) == stored }
                if ok {
                    i.trim = (dp >> 12) + (dp & 0xFFF)
                    i.delay = dp >> 12
                }
            }
            return i
        }

        /// The first layer III frame whose successor is also a frame header.
        static func searchLayer3(_ b: [UInt8]) -> Int? {
            var p = 0
            while p + 4 <= b.count {
                if b[p] == 0xFF, let h = MPEGHeader(b, p), h.layer == 3, h.length > 0, MPEGHeader(b, p + h.length) != nil { return p }
                p += 1
            }
            return nil
        }

        /// CRC-16 (polynomial 0x8005, reflected, initial 0), as the LAME tag uses it.
        static func crc16(_ d: ArraySlice<UInt8>) -> UInt64 {
            var c: UInt16 = 0
            for x in d {
                c ^= UInt16(x)
                for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
            }
            return UInt64(c)
        }

        /// Frames a decoder gets from the stream: every whole frame, resynchronising byte by byte over
        /// damage, less the Xing/Info frame.
        static func decodedFrames(_ b: [UInt8], from: Int? = nil) -> UInt64? {
            guard let start = from ?? audioStart(b), let first = MPEGHeader(b, start) else { return nil }
            var n: UInt64 = 0
            var p = start
            if info(b, start, first) != nil, first.length > 0 { p += first.length }
            while p < b.count {
                if let h = MPEGHeader(b, p), h.length > 0, p + h.length <= b.count {
                    n += UInt64(h.samplesPerFrame)
                    p += h.length
                } else {
                    p += 1
                }
            }
            return n
        }
    }

    static func mpeg(_ b: [UInt8], from: Int? = nil) -> Params? {
        guard let start = from ?? MPEG.audioStart(b), let h = MPEGHeader(b, start) else { return nil }
        let codec = h.layer == 1 ? "mp1" : h.layer == 2 ? "mp2" : "mp3"
        var frames: UInt64?
        if let i = MPEG.info(b, start, h) {
            if let n = i.frames {
                let total = n * UInt64(h.samplesPerFrame)
                let trim = i.trim ?? 0
                frames = total > trim ? total - trim : 0
            }
        } else {
            // No index: a constant-rate estimate from the first 17 frames, when they are all there.
            var p = start
            var sum = 0
            var ok = true
            for _ in 0..<17 {
                guard let f = MPEGHeader(b, p), f.length > 0, p + f.length <= b.count else {
                    ok = false
                    break
                }
                sum += f.length
                p += f.length
            }
            if ok && sum > 0 {
                frames = UInt64((b.count - start) * 17 / sum) * UInt64(h.samplesPerFrame)
            }
        }
        return (codec, h.rate, h.channels, frames)
    }

    // MARK: ADTS

    enum ADTS {
        static let rates: [UInt32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

        struct Header {
            var rate: UInt32
            var channels: UInt16
            var length: Int

            /// An MPEG-4 ADTS header without CRC (`FF F1`): the only kind deckcraft's reader takes.
            init?(_ b: [UInt8], _ o: Int) {
                guard o >= 0, b.count - o >= 7, b[o] == 0xFF, b[o + 1] == 0xF1 else { return nil }
                let si = Int((b[o + 2] >> 2) & 0xF)
                guard si < ADTS.rates.count else { return nil }
                rate = ADTS.rates[si]
                channels = UInt16((b[o + 2] & 1) << 2 | b[o + 3] >> 6)
                length = Int(b[o + 3] & 3) << 11 | Int(b[o + 4]) << 3 | Int(b[o + 5] >> 5)
                guard length >= 7 else { return nil }
            }
        }

        /// Whole frames from `p`, resynchronising byte by byte over damage.
        static func decodedFrames(_ b: [UInt8]) -> UInt64? {
            guard var p = MPEG.audioStart(b), Header(b, p) != nil else { return nil }
            var n: UInt64 = 0
            while p < b.count {
                if let h = Header(b, p), p + h.length <= b.count {
                    n += 1024
                    p += h.length
                } else {
                    p += 1
                }
            }
            return n
        }

        /// The frame count deckcraft's reader estimates: the mean length of the whole frames from the first
        /// sync at or after the middle of the file to the first damage, into the file's length.
        static func estimate(_ b: [UInt8]) -> UInt64? {
            var p = b.count / 2
            while p < b.count && Header(b, p) == nil { p += 1 }
            var sum = 0
            var count = 0
            while let h = Header(b, p), p + h.length <= b.count {
                sum += h.length
                count += 1
                p += h.length
            }
            guard count > 0, sum > 0 else { return nil }
            return UInt64(b.count * count / sum) * 1024
        }
    }

    static func adts(_ b: [UInt8]) -> Params? {
        guard let start = MPEG.audioStart(b), let h = ADTS.Header(b, start) else { return nil }
        return ("aac", h.rate, h.channels, ADTS.estimate(b))
    }

    // MARK: Ogg

    /// Vorbis or FLAC in Ogg. deckcraft's reader takes only an undamaged file: every page in sequence with
    /// a good CRC, to the end of the file.
    static func ogg(_ b: [UInt8]) -> Params? {
        var pos = 0
        while pos < b.count {
            guard pos + 27 <= b.count, tag(b, pos) == "OggS", b[pos + 4] == 0 else { return nil }
            let nseg = Int(b[pos + 26])
            guard pos + 27 + nseg <= b.count else { return nil }
            let body = b[(pos + 27)..<(pos + 27 + nseg)].reduce(0) { $0 + Int($1) }
            let len = 27 + nseg + body
            guard pos + len <= b.count else { return nil }
            var page = Array(b[pos..<(pos + len)])
            let stored = UInt32(page[22]) | UInt32(page[23]) << 8 | UInt32(page[24]) << 16 | UInt32(page[25]) << 24
            for i in 22..<26 { page[i] = 0 }
            guard Ogg.crc32(page[...]) == stored else { return nil }
            pos += len
        }
        guard let f = Ogg.open(b) else { return nil }
        for st in f.streams {
            switch st.codec {
            case .vorbis:
                guard let h = st.headers.first, h.count >= 30 else { continue }
                let ch = UInt16(h[11])
                let rate = UInt32(le(h, 12, 4) ?? 0)
                let frames = st.lastGranule.flatMap { $0 > 0 ? UInt64($0) : nil }
                return ("vorbis", rate, ch, frames)
            case .flac:
                guard let h = st.headers.first, let x = be(h, 13 + 4 + 10, 8) else { continue }
                let rate = UInt32(x >> 44)
                let ch = UInt16((x >> 41) & 7) + 1
                let total = x & 0xF_FFFF_FFFF
                return ("flac", rate, ch, total == 0 ? nil : total)
            default:
                continue
            }
        }
        return nil
    }
}

extension String {
    func replacingSuffix(_ old: String, _ new: String) -> String {
        hasSuffix(old) ? String(dropLast(old.count)) + new : self
    }
}
