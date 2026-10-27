// DCMediaTests — test media made in code. Nothing here comes from a Microsoft, Adobe, Avid or Autodesk
// product: WAV, AIFF, MP3 and ASF headers, Ogg pages and Matroska elements are written byte by byte from
// their specifications; AAC, ALAC, FLAC and Opus come from AudioToolbox's encoders, and H.264/HEVC movies
// from AVAssetWriter, all from a synthesised 440 Hz sine and the colour gradient deckcraft's own fixtures
// use (R = (4x + 20k) mod 256, G = 5y mod 256, B = 40k mod 256 in frame k). The WAV and AIFF writers follow
// crates/media/tests/it/decode.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
@testable import DCMedia
import DCTestSupport
import Foundation

enum TestMedia {
    // MARK: Signals

    /// A 440 Hz sine at amplitude 1/8.
    static func sine(_ rate: UInt32, _ secs: Double) -> [Float] {
        (0..<Int(Double(rate) * secs)).map { i in Float(sin(Double(i) * 440.0 * 2 * Double.pi / Double(rate))) * 0.125 }
    }

    // MARK: Little helpers

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: WAV / AIFF

    /// 16-bit PCM WAV (deckcraft's `wav` test helper).
    static func wav(_ rate: UInt32, _ channels: UInt16, _ samples: [Float]) -> [UInt8] {
        let data = samples.flatMap { le16(UInt16(bitPattern: Int16(rustCast: $0 * 32767))) }
        return wavFile(tag: 1, channels: channels, rate: rate, bits: 16, data: data)
    }

    /// A WAV with any format tag; `extra` goes after the 16-byte `fmt ` body (cbSize and the rest).
    static func wavFile(tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16, data: [UInt8], blockAlign: UInt16? = nil, extra: [UInt8] = [],
                        dataSize: UInt32? = nil, chunksBefore: [UInt8] = []) -> [UInt8]
    {
        let align = blockAlign ?? channels * max(bits / 8, 1)
        let fmt = le16(tag) + le16(channels) + le32(rate) + le32(rate * UInt32(align)) + le16(align) + le16(bits) + extra
        var body = ascii("WAVE") + ascii("fmt ") + le32(UInt32(fmt.count)) + fmt
        if fmt.count % 2 == 1 { body.append(0) }
        body += chunksBefore
        body += ascii("data") + le32(dataSize ?? UInt32(data.count)) + data
        return ascii("RIFF") + le32(UInt32(body.count)) + body
    }

    /// 80-bit IEEE extended sample rate for AIFF's COMM chunk.
    static func ext80(_ v: UInt32) -> [UInt8] {
        let e = 31 - v.leadingZeroBitCount
        let exp = UInt16(16383 + e)
        let mant = UInt64(v) << UInt64(63 - e)
        return be16(exp) + be64(mant)
    }

    /// 16-bit AIFF (deckcraft's `aiff` test helper); with `compression`, an AIFC.
    static func aiff(_ rate: UInt32, _ samples: [Float], channels: UInt16 = 1, compression: String? = nil) -> [UInt8] {
        let little = compression == "sowt"
        let data = samples.flatMap { s -> [UInt8] in
            let v = UInt16(bitPattern: Int16(rustCast: s * 32767))
            return little ? le16(v) : be16(v)
        }
        var comm = be16(channels) + be32(UInt32(samples.count) / UInt32(channels)) + be16(16) + ext80(rate)
        if let c = compression { comm += ascii(c) + [0] + [0] }
        var b = ascii(compression == nil ? "AIFF" : "AIFC")
        if compression != nil { b += ascii("FVER") + be32(4) + be32(0xA280_5140) }
        b += ascii("COMM") + be32(UInt32(comm.count)) + comm
        b += ascii("SSND") + be32(UInt32(8 + data.count)) + [UInt8](repeating: 0, count: 8) + data
        return ascii("FORM") + be32(UInt32(b.count)) + b
    }

    // MARK: MP3

    /// MPEG-1 Layer III frames of silence (all-zero side information and main data), 64 kb/s.
    /// `info`: a Xing/Info frame first; `lame`: its LAME tag with (encoder delay, padding); `id3`: an
    /// ID3v2 tag in front.
    static func mp3(frames: Int, rate: UInt32 = 44100, stereo: Bool = false, info: Bool = false, xing: String = "Info",
                    lame: (Int, Int)? = nil, id3: Int = 0) -> [UInt8]
    {
        let rateIndex: UInt8 = rate == 48000 ? 1 : rate == 32000 ? 2 : 0
        let frameLen = 144 * 64000 / Int(rate)
        let header: [UInt8] = [0xFF, 0xFB, 0x50 | rateIndex << 2, stereo ? 0x00 : 0xC0]
        let side = stereo ? 32 : 17
        var out: [UInt8] = []
        if id3 > 0 {
            let size = UInt32(id3)
            out += ascii("ID3") + [4, 0, 0] + [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
            out += [UInt8](repeating: 0, count: id3)
        }
        if info {
            var f = header + [UInt8](repeating: 0, count: side)
            f += ascii(xing) + be32(0x0F) + be32(UInt32(frames)) + be32(UInt32((frames + 1) * frameLen))
            f += (0..<100).map { UInt8($0 * 255 / 100) } + be32(50)
            if let (delay, padding) = lame {
                f += ascii("LAME3.100") + [0x00, 0x00] + [0, 0, 0, 0] + [0, 0, 0, 0] + [0x00, 0x00]
                f += [UInt8(delay >> 4), UInt8((delay & 0xF) << 4 | padding >> 8), UInt8(padding & 0xFF)]
                f += [0, 0, 0, 0] + be32(UInt32((frames + 1) * frameLen)) + [0, 0, 0, 0]
            }
            f += [UInt8](repeating: 0, count: max(0, frameLen - f.count))
            out += f
        }
        for _ in 0..<frames {
            out += header + [UInt8](repeating: 0, count: frameLen - 4)
        }
        return out
    }

    // MARK: ASF

    static let asfFileProps: [UInt8] = [0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
    static let asfStreamProps: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
    static let asfAudio: [UInt8] = [0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
    static let asfVideo: [UInt8] = [0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]

    /// An ASF header object (MS-ASF is not needed: the layout is the one deckcraft's probe reads) with a
    /// file properties object and audio and/or video stream properties. No media data.
    static func asf(playMs: UInt64, prerollMs: UInt64, audioTag: UInt16? = 0x0161, rate: UInt32 = 44100, channels: UInt16 = 1,
                    video: (UInt32, UInt32)? = nil) -> [UInt8]
    {
        var objects: [[UInt8]] = []
        var fp = [UInt8](repeating: 0x11, count: 16) + le64(0) + le64(0) + le64(1)
        fp += le64(playMs * 10_000) + le64(playMs * 10_000) + le64(prerollMs) + le32(2) + le32(3200) + le32(3200) + le32(64000)
        objects.append(asfFileProps + le64(UInt64(24 + fp.count)) + fp)
        if let tag = audioTag {
            let wfx = le16(tag) + le16(channels) + le32(rate) + le32(8000) + le16(1487) + le16(16) + le16(0)
            var sp = asfAudio + [UInt8](repeating: 0, count: 16) + le64(0) + le32(UInt32(wfx.count)) + le32(0) + le16(1) + le32(0)
            sp += wfx
            objects.append(asfStreamProps + le64(UInt64(24 + sp.count)) + sp)
        }
        if let (w, h) = video {
            let bih = le32(w) + le32(h) + [2] + le16(40) + [UInt8](repeating: 0, count: 40)
            var sp = asfVideo + [UInt8](repeating: 0, count: 16) + le64(0) + le32(UInt32(bih.count)) + le32(0) + le16(2) + le32(0)
            sp += bih
            objects.append(asfStreamProps + le64(UInt64(24 + sp.count)) + sp)
        }
        let body = objects.flatMap { $0 }
        return Container.asfHeader + le64(UInt64(30 + body.count)) + le32(UInt32(objects.count)) + [1, 2] + body + [UInt8](repeating: 0, count: 50)
    }

    // MARK: Ogg

    /// One Ogg page (RFC 3533) holding whole packets; `continued`/`eos` set the header flags.
    static func oggPage(serial: UInt32, seq: UInt32, granule: Int64, packets: [[UInt8]], bos: Bool = false, eos: Bool = false) -> [UInt8] {
        var lacing: [UInt8] = []
        for p in packets {
            var n = p.count
            while n >= 255 {
                lacing.append(255)
                n -= 255
            }
            lacing.append(UInt8(n))
        }
        var page = ascii("OggS") + [0, (bos ? 2 : 0) | (eos ? 4 : 0)] + le64(UInt64(bitPattern: granule)) + le32(serial) + le32(seq) + le32(0)
        page += [UInt8(lacing.count)] + lacing + packets.flatMap { $0 }
        let crc = Ogg.crc32(page[...])
        page.replaceSubrange(22..<26, with: le32(crc))
        return page
    }

    static func opusHead(channels: UInt8, preSkip: UInt16) -> [UInt8] {
        ascii("OpusHead") + [1, channels] + le16(preSkip) + le32(48000) + le16(0) + [0]
    }

    /// Ogg Opus with `packets` 20 ms CELT packets of silence (TOC byte and a zero byte), `perPage` to a page.
    static func oggOpus(packets: Int, perPage: Int = 10, channels: UInt8 = 1, preSkip: UInt16 = 312, trim: Int64 = 0) -> [UInt8] {
        let serial: UInt32 = 0x1234_5678
        var out = oggPage(serial: serial, seq: 0, granule: 0, packets: [opusHead(channels: channels, preSkip: preSkip)], bos: true)
        out += oggPage(serial: serial, seq: 1, granule: 0, packets: [ascii("OpusTags") + le32(4) + ascii("test") + le32(0)])
        let toc: UInt8 = 31 << 3 | (channels == 2 ? 4 : 0)
        var seq: UInt32 = 2
        var done = 0
        while done < packets {
            let n = min(perPage, packets - done)
            done += n
            let last = done == packets
            let granule = Int64(done * 960) + Int64(preSkip) - (last ? trim : 0)
            out += oggPage(serial: serial, seq: seq, granule: granule, packets: Array(repeating: [toc, 0], count: n), eos: last)
            seq += 1
        }
        return out
    }

    // MARK: Matroska

    static func ebmlID(_ id: UInt32) -> [UInt8] {
        id >= 0x100_0000 ? be32(id) : id >= 0x1_0000 ? Array(be32(id).dropFirst()) : id >= 0x100 ? be16(UInt16(id)) : [UInt8(id)]
    }

    static func ebmlSize(_ n: Int) -> [UInt8] {
        var len = 1
        while len < 8 && UInt64(n) >= (UInt64(1) << UInt64(7 * len)) - 1 { len += 1 }
        let v = UInt64(n) | UInt64(1) << UInt64(7 * len)
        return Array(be64(v).suffix(len))
    }

    static func el(_ id: UInt32, _ body: [UInt8]) -> [UInt8] { ebmlID(id) + ebmlSize(body.count) + body }
    static func elUInt(_ id: UInt32, _ v: UInt64) -> [UInt8] {
        var b = be64(v)
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        return el(id, b)
    }
    static func elFloat(_ id: UInt32, _ v: Double) -> [UInt8] { el(id, be64(v.bitPattern)) }
    static func elString(_ id: UInt32, _ s: String) -> [UInt8] { el(id, ascii(s)) }

    struct MKVTrackSpec {
        var number: UInt64
        var type: UInt64
        var codecID: String
        var codecPrivate: [UInt8] = []
        var width: UInt64 = 0
        var height: UInt64 = 0
        var rate: Double = 0
        var channels: UInt64 = 0
        var defaultDurationNs: UInt64? = nil
    }

    /// A Matroska/WebM file: EBML header, a Segment with Info and Tracks, then one Cluster per entry of
    /// `clusters` (timestamp, blocks of (track, relative ts, keyframe, frame data)).
    static func mkv(docType: String, durationMs: Double?, tracks: [MKVTrackSpec], clusters: [(UInt64, [(UInt64, Int16, Bool, [UInt8])])],
                    unknownSizeSegment: Bool = false, laced: Bool = false) -> [UInt8]
    {
        let header = el(0x1A45_DFA3, elUInt(0x4286, 1) + elUInt(0x42F7, 1) + elUInt(0x42F2, 4) + elUInt(0x42F3, 8) + elString(0x4282, docType)
            + elUInt(0x4287, 4) + elUInt(0x4285, 2))
        var info = elUInt(0x2A_D7B1, 1_000_000) + elString(0x4D80, "DCMediaTests") + elString(0x5741, "DCMediaTests")
        if let d = durationMs { info += elFloat(0x4489, d) }
        var entries: [UInt8] = []
        for t in tracks {
            var e = elUInt(0xD7, t.number) + elUInt(0x73C5, t.number + 100) + elUInt(0x83, t.type) + elString(0x86, t.codecID)
            if !t.codecPrivate.isEmpty { e += el(0x63A2, t.codecPrivate) }
            if let d = t.defaultDurationNs { e += elUInt(0x23_E383, d) }
            if t.type == 1 { e += el(0xE0, elUInt(0xB0, t.width) + elUInt(0xBA, t.height)) }
            if t.type == 2 { e += el(0xE1, elFloat(0xB5, t.rate) + elUInt(0x9F, t.channels)) }
            entries += el(0xAE, e)
        }
        var segment = el(0x1549_A966, info) + el(0x1654_AE6B, entries)
        for (ts, blocks) in clusters {
            var c = elUInt(0xE7, ts)
            if laced {
                // All frames of each track in one Xiph-laced SimpleBlock.
                var byTrack: [UInt64: [(Int16, Bool, [UInt8])]] = [:]
                for (tn, rel, key, data) in blocks { byTrack[tn, default: []].append((rel, key, data)) }
                for tn in byTrack.keys.sorted() {
                    guard let frames = byTrack[tn], let first = frames.first else { continue }
                    var lace: [UInt8] = [UInt8(frames.count - 1)]
                    for f in frames.dropLast() {
                        var n = f.2.count
                        while n >= 255 {
                            lace.append(255)
                            n -= 255
                        }
                        lace.append(UInt8(n))
                    }
                    let body = ebmlSize(Int(tn)) + be16(UInt16(bitPattern: first.0)) + [(first.1 ? 0x80 : 0) | 0x02] + lace + frames.flatMap { $0.2 }
                    c += el(0xA3, body)
                }
            } else {
                for (tn, rel, key, data) in blocks {
                    c += el(0xA3, ebmlSize(Int(tn)) + be16(UInt16(bitPattern: rel)) + [key ? 0x80 : 0] + data)
                }
            }
            segment += el(0x1F43_B675, c)
        }
        let segHeader = unknownSizeSegment ? ebmlID(0x1853_8067) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] : ebmlID(0x1853_8067) + ebmlSize(segment.count)
        return header + segHeader + segment
    }

    // MARK: AudioToolbox encodes

    struct EncodeError: Error { var status: OSStatus; var step: String }

    /// Encode mono or stereo float samples with AudioToolbox into a file of `fileType` and return its bytes.
    static func encode(_ samples: [Float], rate: Double, channels: UInt32, fileType: AudioFileTypeID, format: AudioFormatID,
                       bitsPerChannel: UInt32 = 0, flags: AudioFormatFlags = 0, ext: String) throws -> [UInt8]
    {
        let url = FileManager.default.temporaryDirectory.appending(path: "dcmedia-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        var out = AudioStreamBasicDescription()
        out.mSampleRate = rate
        out.mFormatID = format
        out.mChannelsPerFrame = channels
        out.mFormatFlags = flags
        if format == kAudioFormatLinearPCM {
            out.mBitsPerChannel = bitsPerChannel
            out.mFramesPerPacket = 1
            out.mBytesPerFrame = bitsPerChannel / 8 * channels
            out.mBytesPerPacket = out.mBytesPerFrame
        } else if format == kAudioFormatAppleLossless || format == kAudioFormatFLAC {
            out.mFormatFlags = bitsPerChannel == 24 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_16BitSourceData
        }
        var file: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(url as CFURL, fileType, &out, nil, AudioFileFlags.eraseFile.rawValue, &file)
        guard st == noErr, let f = file else { throw EncodeError(status: st, step: "create") }
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels,
                                                 mFramesPerPacket: 1, mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32,
                                                 mReserved: 0)
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { throw EncodeError(status: st, step: "client format") }
        var interleaved = samples
        let frames = UInt32(samples.count) / channels
        st = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count),
                                                                                  mData: raw.baseAddress))
            return ExtAudioFileWrite(f, frames, &list)
        }
        guard st == noErr else { throw EncodeError(status: st, step: "write") }
        st = ExtAudioFileDispose(f)
        guard st == noErr else { throw EncodeError(status: st, step: "close") }
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: AVAssetWriter movies

    /// BGRA pixel buffer of gradient frame `k`.
    static func gradient(_ w: Int, _ h: Int, _ k: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let p = pb else { return nil }
        CVPixelBufferLockBaseAddress(p, [])
        defer { CVPixelBufferUnlockBaseAddress(p, []) }
        guard let base = CVPixelBufferGetBaseAddress(p) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(p)
        let px = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * row + x * 4
                px[o] = UInt8((k * 40) % 256)
                px[o + 1] = UInt8((y * 5) % 256)
                px[o + 2] = UInt8((x * 4 + k * 20) % 256)
                px[o + 3] = 255
            }
        }
        return p
    }

    /// A PCM sample buffer of mono float samples at `start` frames.
    static func audioBuffer(_ s: [Float], rate: Double, start: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                               mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var block: CMBlockBuffer?
        let bytes = s.count * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let st = s.withUnsafeBytes { $0.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) } ?? -1 }
        guard st == noErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: s.count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    struct WriterError: Error { var message: String }

    /// A movie of `frames` gradient frames at `fps` (and, with `audio`, 0.5 s of the sine as AAC), written by
    /// AVAssetWriter.
    static func movie(fileType: AVFileType, codec: AVVideoCodecType, width: Int = 64, height: Int = 48, frames: Int = 6, fps: Int32 = 10,
                      audio: Bool = false, reorder: Bool = false, fragmentSeconds: Double? = nil) async throws -> [UInt8]
    {
        let ext = fileType == .mov ? "mov" : fileType == .m4a ? "m4a" : "mp4"
        let url = FileManager.default.temporaryDirectory.appending(path: "dcmedia-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        if let f = fragmentSeconds { writer.movieFragmentInterval = CMTime(seconds: f, preferredTimescale: 600) }
        var video: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if frames > 0 {
            var compression: [String: Any] = [AVVideoAverageBitRateKey: 400_000, AVVideoMaxKeyFrameIntervalKey: 5]
            if codec == .h264 {
                compression[AVVideoAllowFrameReorderingKey] = reorder
                compression[AVVideoProfileLevelKey] = reorder ? AVVideoProfileLevelH264HighAutoLevel : AVVideoProfileLevelH264BaselineAutoLevel
            }
            var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
            // ProRes and JPEG take no bit rate or keyframe settings.
            if codec == .h264 || codec == .hevc { settings[AVVideoCompressionPropertiesKey] = compression }
            if codec == .jpeg { settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.9] }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            v.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)
            writer.add(v)
            video = v
        }
        var sound: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            sound = a
        }
        guard writer.startWriting() else { throw WriterError(message: "start: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        if let v = video, let ad = adaptor {
            for k in 0..<frames {
                while !v.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                guard let pb = gradient(width, height, k), ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: fps)) else {
                    throw WriterError(message: "video frame \(k): \(String(describing: writer.error))")
                }
            }
            v.markAsFinished()
        }
        if let a = sound {
            let s = sine(44100, 0.5)
            var start = 0
            while start < s.count {
                while !a.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                let chunk = Array(s[start..<min(start + 4410, s.count)])
                guard let sb = audioBuffer(chunk, rate: 44100, start: start), a.append(sb) else {
                    throw WriterError(message: "audio at \(start): \(String(describing: writer.error))")
                }
                start += chunk.count
            }
            a.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw WriterError(message: "finish: \(String(describing: writer.error))") }
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: Fixtures

    /// The media inputs for the oracle (`Tools/oracle/media-vectors`), in `<fixtures>/media/inputs`.
    static var inputsDir: URL { Fixtures.root.appending(path: "media/inputs", directoryHint: .isDirectory) }

    /// Every generated input, by file name.
    static func allInputs() async throws -> [(String, [UInt8])] {
        var out: [(String, [UInt8])] = []
        let s44 = sine(44100, 0.5)
        out.append(("wav-pcm16-mono.wav", wav(44100, 1, s44)))
        out.append(("wav-pcm16-stereo.wav", wav(22050, 2, sine(22050, 0.5).flatMap { [$0, $0] })))
        out.append(("wav-pcm8.wav", wavFile(tag: 1, channels: 1, rate: 8000, bits: 8, data: sine(8000, 0.25).map { UInt8(rustCast: $0 * 127 + 128) })))
        out.append(("wav-float32.wav", wavFile(tag: 3, channels: 1, rate: 16000, bits: 32, data: sine(16000, 0.3).flatMap { le32($0.bitPattern) })))
        out.append(("wav-pcm24.wav", wavFile(tag: 1, channels: 2, rate: 48000, bits: 24,
                                             data: sine(48000, 0.2).flatMap { s -> [UInt8] in
                                                 let v = UInt32(bitPattern: Int32(rustCast: s * 8_388_607))
                                                 let b = Array(le32(v).prefix(3))
                                                 return b + b
                                             })))
        out.append(("wav-alaw.wav", wavFile(tag: 6, channels: 1, rate: 8000, bits: 8, data: [UInt8](repeating: 0xD5, count: 4000))))
        out.append(("wav-extensible.wav", wavFile(tag: 0xFFFE, channels: 1, rate: 44100, bits: 16, data: wav(44100, 1, s44).suffix(44100)
                .map { $0 }, extra: le16(22) + le16(16) + le32(4) + [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])))
        out.append(("wav-ima-adpcm.wav", wavFile(tag: 0x11, channels: 1, rate: 22050, bits: 4, data: [UInt8](repeating: 0, count: 2048),
                                                 blockAlign: 512, extra: le16(2) + le16(1017))))
        out.append(("wav-mp3-tag.wav", wavFile(tag: 0x55, channels: 1, rate: 44100, bits: 0, data: mp3(frames: 10), blockAlign: 1)))
        out.append(("wav-oversize-data.wav", wavFile(tag: 1, channels: 1, rate: 44100, bits: 16, data: wav(44100, 1, sine(44100, 0.1)).suffix(8820)
                .map { $0 }, dataSize: 100_000)))
        out.append(("wav-list-chunk.wav", wavFile(tag: 1, channels: 1, rate: 44100, bits: 16, data: wav(44100, 1, sine(44100, 0.1)).suffix(8820)
                .map { $0 }, chunksBefore: ascii("LIST") + le32(9) + ascii("INFOabcde") + [0])))
        out.append(("aiff-mono.aiff", aiff(48000, sine(48000, 0.5))))
        out.append(("aiff-stereo.aiff", aiff(22050, sine(22050, 0.3).flatMap { [$0, $0] }, channels: 2)))
        out.append(("aifc-sowt.aifc", aiff(44100, sine(44100, 0.2), compression: "sowt")))
        out.append(("mp3-plain.mp3", mp3(frames: 20)))
        out.append(("mp3-stereo-48k.mp3", mp3(frames: 12, rate: 48000, stereo: true)))
        out.append(("mp3-info.mp3", mp3(frames: 20, info: true)))
        out.append(("mp3-xing-lame.mp3", mp3(frames: 20, info: true, xing: "Xing", lame: (576, 1000))))
        out.append(("mp3-id3.mp3", mp3(frames: 15, id3: 300)))
        out.append(("mp3-junk-head.mp3", [UInt8](repeating: 0, count: 100) + mp3(frames: 20)))
        out.append(("asf-wma2.wma", asf(playMs: 4000, prerollMs: 3100)))
        out.append(("asf-wmv.wmv", asf(playMs: 12_000, prerollMs: 0, audioTag: 0x0162, rate: 48000, channels: 2, video: (320, 240))))
        out.append(("ogg-opus.opus", oggOpus(packets: 50)))
        out.append(("ogg-opus-stereo-trim.opus", oggOpus(packets: 23, perPage: 7, channels: 2, preSkip: 120, trim: 500)))
        // Matroska written by hand: a WebM with an Opus track and blocks of silence, and a Matroska whose
        // video is AV1 with made-up frames (the parser doesn't decode them).
        let opusFrames: [(UInt64, Int16, Bool, [UInt8])] = (0..<25).map { (i: Int) -> (UInt64, Int16, Bool, [UInt8]) in
            (1, Int16(i * 20), true, [UInt8(31 << 3), 0])
        }
        let opusTrack = MKVTrackSpec(number: 1, type: 2, codecID: "A_OPUS", codecPrivate: opusHead(channels: 1, preSkip: 312), rate: 48000, channels: 1)
        out.append(("mkv-opus.webm", mkv(docType: "webm", durationMs: 500, tracks: [opusTrack], clusters: [(0, opusFrames)])))
        out.append(("mkv-opus-laced.mka", mkv(docType: "matroska", durationMs: nil,
                                              tracks: [MKVTrackSpec(number: 1, type: 2, codecID: "A_OPUS", codecPrivate: opusHead(channels: 1, preSkip: 312),
                                                                    rate: 48000, channels: 1, defaultDurationNs: 20_000_000)],
                                              clusters: [(0, Array(opusFrames.prefix(10))), (200, Array(opusFrames.prefix(10)))], laced: true)))
        let av1Frames: [(UInt64, Int16, Bool, [UInt8])] = (0..<8).map { (i: Int) -> (UInt64, Int16, Bool, [UInt8]) in
            let frame: [UInt8] = [0x12, 0x00, 0x32, UInt8(i)]
            return (1, Int16(i * 40), i % 4 == 0, frame)
        }
        out.append(("mkv-av1-unknown-size.mkv", mkv(docType: "matroska", durationMs: nil,
                                                    tracks: [MKVTrackSpec(number: 1, type: 1, codecID: "V_AV1", codecPrivate: [0x81, 0x00, 0x0C, 0x00], width: 320,
                                                                          height: 180, defaultDurationNs: 40_000_000)],
                                                    clusters: [(0, av1Frames)], unknownSizeSegment: true)))
        // AudioToolbox encodes.
        out.append(("at-aac.m4a", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileM4AType, format: kAudioFormatMPEG4AAC, ext: "m4a")))
        out.append(("at-aac.aac", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileAAC_ADTSType, format: kAudioFormatMPEG4AAC, ext: "aac")))
        out.append(("at-aac-stereo-48k.aac", try encode(sine(48000, 0.3).flatMap { [$0, $0] }, rate: 48000, channels: 2, fileType: kAudioFileAAC_ADTSType,
                                                        format: kAudioFormatMPEG4AAC, ext: "aac")))
        // AudioToolbox writes MPEG-2 ADTS headers (FF F9); the same frames marked MPEG-4 (FF F1), 3 s long.
        var long = try encode(sine(44100, 3), rate: 44100, channels: 1, fileType: kAudioFileAAC_ADTSType, format: kAudioFormatMPEG4AAC, ext: "aac")
        var p = 0
        while p + 7 <= long.count, long[p] == 0xFF {
            long[p + 1] = 0xF1
            let n = Int(long[p + 3] & 3) << 11 | Int(long[p + 4]) << 3 | Int(long[p + 5] >> 5)
            if n < 7 { break }
            p += n
        }
        out.append(("at-aac-long-mpeg4.aac", long))
        out.append(("at-alac.m4a", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileM4AType, format: kAudioFormatAppleLossless, ext: "m4a")))
        out.append(("at-alac.caf", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileCAFType, format: kAudioFormatAppleLossless, ext: "caf")))
        out.append(("at-lpcm.caf", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileCAFType, format: kAudioFormatLinearPCM, bitsPerChannel: 16,
                                              flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian, ext: "caf")))
        out.append(("at-flac.flac", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileFLACType, format: kAudioFormatFLAC, bitsPerChannel: 16,
                                               ext: "flac")))
        out.append(("at-opus.caf", try encode(sine(48000, 0.5), rate: 48000, channels: 1, fileType: kAudioFileCAFType, format: kAudioFormatOpus, ext: "caf")))
        out.append(("at-pcm.aiff", try encode(s44, rate: 44100, channels: 1, fileType: kAudioFileAIFFType, format: kAudioFormatLinearPCM, bitsPerChannel: 16,
                                              flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian, ext: "aiff")))
        // AVAssetWriter movies.
        out.append(("av-h264-aac.mp4", try await movie(fileType: .mp4, codec: .h264, frames: 5, audio: true, reorder: true)))
        out.append(("av-h264.mov", try await movie(fileType: .mov, codec: .h264)))
        out.append(("av-hevc.mp4", try await movie(fileType: .mp4, codec: .hevc)))
        out.append(("av-hevc.mov", try await movie(fileType: .mov, codec: .hevc, width: 96, height: 64, frames: 10, fps: 25)))
        out.append(("av-aac.m4a", try await movie(fileType: .m4a, codec: .h264, frames: 0, audio: true)))
        out.append(("av-h264-fragmented.mp4", try await movie(fileType: .mp4, codec: .h264, frames: 12, audio: true, fragmentSeconds: 0.4)))
        // Matroska around the H.264 movie's own samples, so a Matroska file decodes too.
        if let mp4 = out.first(where: { $0.0 == "av-h264.mov" })?.1, let f = try? BMFF.open(mp4), let ti = f.trackOfKind(.video),
           case .avc(let avcc)? = f.tracks[ti].entries.first?.codec
        {
            let t = f.tracks[ti]
            let scale = Double(t.timescale)
            let blocks: [(UInt64, Int16, Bool, [UInt8])] = t.samples.indices.compactMap { i in
                guard let data = try? f.readSample(mp4, ti, i), let pts = t.presentationPts(i) else { return nil }
                return (1, Int16(Double(pts) / scale * 1000), t.samples[i].isSync, Array(data))
            }
            out.append(("mkv-h264.mkv", mkv(docType: "matroska", durationMs: 600,
                                            tracks: [MKVTrackSpec(number: 1, type: 1, codecID: "V_MPEG4/ISO/AVC", codecPrivate: avcc, width: 64, height: 48,
                                                                  defaultDurationNs: 100_000_000)],
                                            clusters: [(0, blocks)])))
        }
        return out
    }
}

// MARK: MPEG-1/2 video and MPEG audio layers I/II, written bit by bit

/// MSB-first bit writer for MPEG elementary streams.
struct BitWriter {
    var bytes: [UInt8] = []
    private var acc: UInt8 = 0
    private var used = 0

    mutating func put(_ v: UInt64, _ bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            acc = acc << 1 | UInt8((v >> UInt64(i)) & 1)
            used += 1
            if used == 8 {
                bytes.append(acc)
                acc = 0
                used = 0
            }
        }
    }

    mutating func put(_ s: String) { for c in s { put(c == "1" ? 1 : 0, 1) } }

    mutating func align() { if used > 0 { put(0, 8 - used) } }

    mutating func startCode(_ code: UInt8) {
        align()
        bytes += [0, 0, 1, code]
    }
}

extension TestMedia {
    static let lumaDCSize = ["100", "00", "01", "101", "110", "1110", "11110", "111110", "1111110"]

    /// An intra DC differential: its size code and bits (ISO/IEC 11172-2 2.4.3.7, 13818-2 7.2.1).
    static func dc(_ w: inout BitWriter, _ d: Int) {
        let size = d == 0 ? 0 : Int.bitWidth - abs(d).leadingZeroBitCount
        w.put(lumaDCSize[size])
        if size > 0 { w.put(UInt64(d > 0 ? d : d + (1 << size) - 1), size) }
    }

    /// One MPEG-1 (`version` 1) or MPEG-2 (`version` 2) picture as a self-contained packet: sequence header
    /// (and extension), GOP header and an intra picture whose luma is `luma` everywhere and chroma neutral.
    /// Every macroblock is coded with DC coefficients only.
    static func mpegPicture(version: Int, width: Int, height: Int, luma: Int) -> [UInt8] {
        var w = BitWriter()
        w.startCode(0xB3)
        w.put(UInt64(width), 12)
        w.put(UInt64(height), 12)
        w.put(1, 4)  // square pixels
        w.put(3, 4)  // 25 fps
        w.put(1000, 18)  // 400 kb/s
        w.put(1, 1)
        w.put(20, 10)
        w.put(0, 1)
        w.put(0, 1)
        w.put(0, 1)
        if version == 2 {
            w.startCode(0xB5)
            w.put(1, 4)  // sequence extension
            w.put(0x48, 8)  // main profile, main level
            w.put(1, 1)  // progressive
            w.put(1, 2)  // 4:2:0
            w.put(0, 2)
            w.put(0, 2)
            w.put(0, 12)
            w.put(1, 1)
            w.put(0, 8)
            w.put(1, 1)  // low delay
            w.put(0, 2)
            w.put(0, 5)
        }
        w.startCode(0xB8)
        w.put(0, 1 + 5 + 6)
        w.put(1, 1)
        w.put(0, 6 + 6)
        w.put(1, 1)  // closed GOP
        w.put(0, 1)
        w.startCode(0x00)
        w.put(0, 10)
        w.put(1, 3)  // I picture
        w.put(0xFFFF, 16)
        w.put(0, 1)
        if version == 2 {
            w.startCode(0xB5)
            w.put(8, 4)  // picture coding extension
            w.put(0xFFFF, 16)  // f_codes
            w.put(0, 2)  // 8-bit DC
            w.put(3, 2)  // frame picture
            w.put(0, 1)
            w.put(1, 1)  // frame_pred_frame_dct
            w.put(0, 1)
            w.put(0, 1)
            w.put(0, 1)
            w.put(0, 1)
            w.put(0, 1)
            w.put(1, 1)  // chroma_420_type
            w.put(1, 1)  // progressive frame
            w.put(0, 1)
        }
        for row in 0..<(height / 16) {
            w.startCode(UInt8(row + 1))
            w.put(8, 5)  // quantiser scale
            w.put(0, 1)  // extra_bit_slice
            for col in 0..<(width / 16) {
                w.put("1")  // address increment 1
                w.put("1")  // intra
                for b in 0..<4 {
                    dc(&w, col == 0 && b == 0 ? luma - 128 : 0)
                    w.put("10")  // end of block
                }
                for _ in 0..<2 {
                    w.put("00")  // chroma DC size 0
                    w.put("10")
                }
            }
        }
        w.align()
        return w.bytes
    }

    /// A Matroska file of MPEG-1/2 pictures at 25 fps, luma 64 + 32k in frame k.
    static func mpegVideoMKV(version: Int, frames: Int) -> [UInt8] {
        let blocks: [(UInt64, Int16, Bool, [UInt8])] = (0..<frames).map { k in
            (1, Int16(k * 40), true, mpegPicture(version: version, width: 64, height: 48, luma: 64 + 32 * k))
        }
        return mkv(docType: "matroska", durationMs: Double(frames * 40),
                   tracks: [MKVTrackSpec(number: 1, type: 1, codecID: version == 1 ? "V_MPEG1" : "V_MPEG2", width: 64, height: 48,
                                         defaultDurationNs: 40_000_000)],
                   clusters: [(0, blocks)])
    }

    /// Silent MPEG-1 audio frames, layer I or II, 44.1 kHz mono at 64 kb/s (every bit allocation zero).
    static func mpegAudioFrame(layer: Int) -> [UInt8] {
        if layer == 1 {
            return [0xFF, 0xFF, 0x20, 0xC0] + [UInt8](repeating: 0, count: (12 * 64000 / 44100) * 4 - 4)
        }
        return [0xFF, 0xFD, 0x40, 0xC0] + [UInt8](repeating: 0, count: 144 * 64000 / 44100 - 4)
    }
}
