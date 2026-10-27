// DCMedia — video decoding: the video track of an MP4/MOV or Matroska/WebM file decoded frame by frame in
// presentation order, seeking, poster frames. Port of deckcraft crates/media/src/video.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors). deckcraft's own decoders (deckcraft-h264, -hevc, -vp9,
// -av1) and its Y'CbCr conversion (yuv.rs) are replaced by VideoToolbox, which hands back BGRA, and by the
// external-decoder seam (ExternalDecoders.swift):
//
// - VideoToolbox: H.264 and HEVC everywhere; AV1 where VideoToolbox has a decoder (Apple M3 and later);
//   MPEG-1, MPEG-2, Apple ProRes and baseline Motion JPEG where a session for them can be created (all of
//   them on this generation of Macs). MPEG-1/2 format descriptions come from media-bridge's
//   `FormatDescriptionFactory`, and the codec matrix from its `SupportGate`.
// - VP9, VP8 and any other codec a registered `ExternalVideoDecoder` claims (vpx-swift's `VpxVideoDecoder`,
//   when the app registers it) go through that decoder, a keyframe-to-keyframe run at a time.
// - Everything else is `MediaError.unsupported`.
//
// The demuxing, timing, seeking and frame-order rules are deckcraft's; only the pixels differ (VideoToolbox's
// conversion matrix and rounding instead of yuv.rs's).
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import DCCore
import Foundation
import ImageIO
import MediaImport
import VideoToolbox

/// A decoded picture, RGBA8 (straight alpha, always opaque), with its presentation time.
public struct Frame: Sendable, Equatable {
    /// Presentation time in seconds from the start of the media.
    public var time: Double
    public var width: UInt32
    public var height: UInt32
    public var rgba: [UInt8]

    public init(time: Double, width: UInt32, height: UInt32, rgba: [UInt8]) {
        self.time = time
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Which video codecs play on this Mac.
enum VideoSupport {
    static let av1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    static let mpeg1 = sessionAvailable(kCMVideoCodecType_MPEG1Video)
    static let mpeg2 = sessionAvailable(kCMVideoCodecType_MPEG2Video)
    static let proRes = sessionAvailable(kCMVideoCodecType_AppleProRes422)
    static let jpeg = sessionAvailable(kCMVideoCodecType_JPEG)

    /// Whether VideoToolbox will open a session for `type` (the decoder is installed).
    static func sessionAvailable(_ type: CMVideoCodecType) -> Bool {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: type, width: 64, height: 48, extensions: nil, formatDescriptionOut: &fd) == noErr,
              let fd
        else { return false }
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: nil,
                                              outputCallback: nil, decompressionSessionOut: &s)
        if let s { VTDecompressionSessionInvalidate(s) }
        return st == noErr
    }

    /// The Matroska CodecID for a `VideoInfo.codec` name (deckcraft's names for MP4 and Matroska tracks).
    static func codecID(_ name: String) -> String? {
        switch name {
        case "H.264": "V_MPEG4/ISO/AVC"
        case "HEVC": "V_MPEGH/ISO/HEVC"
        case "AV1": "V_AV1"
        case "VP9": "V_VP9"
        case "VP8", "FourCc(\"vp08\")": "V_VP8"
        case "Apple ProRes", "prores": "V_PRORES"
        case "Motion JPEG", "mjpeg": "V_MJPEG"
        case let s where s.hasPrefix("V_"): s
        default: nil
        }
    }

    /// `MediaSupport` for a video codec name (`VideoInfo.codec`).
    static func of(_ name: String) -> MediaSupport {
        guard let id = codecID(name) else { return .unsupported("\(name) video") }
        let native: Bool
        switch id {
        case "V_AV1": if !av1 { return .unsupported("AV1 video on this Mac") } else { native = true }
        case "V_MPEG1": native = mpeg1
        case "V_MPEG2": native = mpeg2
        case "V_PRORES": native = proRes
        case "V_MJPEG": native = jpeg
        default: native = SupportGate.status(forCodecID: id) == .nativeVideo
        }
        if native { return .supported }
        return Media.externalDecoder(for: id) != nil ? .supported : .unsupported("\(name) video")
    }
}

/// Which audio codecs play on this Mac: media-bridge's `SupportGate` over deckcraft's codec names.
enum AudioSupport {
    static func codecID(_ name: String) -> String? {
        switch name {
        case "AAC", "aac": "A_AAC"
        case "MP3", "mp3": "A_MPEG/L3"
        case "MP2", "mp2": "A_MPEG/L2"
        case "MP1", "mp1": "A_MPEG/L1"
        case "ALAC", "alac": "A_ALAC"
        case "FLAC", "flac": "A_FLAC"
        case "Opus", "opus": "A_OPUS"
        case "AC-3", "ac3": "A_AC3"
        case "E-AC-3", "eac3": "A_EAC3"
        case "Vorbis", "vorbis": "A_VORBIS"
        case let s where s == "PCM" || s.hasPrefix("pcm"): "A_PCM/INT/LIT"
        default: nil
        }
    }

    /// AudioToolbox lists a Vorbis decoder (media-bridge's gate defers Vorbis; this Mac decodes it).
    static let vorbis: Bool = {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains(kAudioFormatVorbis)
    }()

    static func of(_ name: String) -> MediaSupport {
        if name == "ADPCM" { return .supported }  // IMA/MS ADPCM in WAV: AudioFile decodes both
        if name == "Vorbis" || name == "vorbis" { return vorbis ? .supported : .unsupported("Vorbis audio") }
        if name.hasPrefix("WMA") { return .unsupported("Windows Media Audio (WMA)") }
        guard let id = codecID(name), SupportGate.status(forCodecID: id) == .nativeAudio else { return .unsupported("\(name) audio") }
        return .supported
    }
}

extension MediaInfo {
    /// Whether this app can decode the video here (`decodable` keeps deckcraft's answer). Counts registered
    /// external decoders.
    public var videoSupport: MediaSupport {
        guard let v = video else { return .absent }
        return VideoSupport.of(v.codec)
    }

    /// Whether this app can decode the audio here (`decodable` keeps deckcraft's answer).
    public var audioSupport: MediaSupport {
        guard let a = audio else { return .absent }
        return AudioSupport.of(a.codec)
    }
}

/// What the decoder's output handler hands back (it may run on VideoToolbox's thread).
private final class DecodeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: Frame?
    private var failed = false

    func set(_ f: Frame?, failed: Bool) {
        lock.withLock {
            frame = f
            self.failed = self.failed || failed
        }
    }

    func get() -> (Frame?, Bool) { lock.withLock { (frame, failed) } }
}

/// A picture before ordering: presentation time in track ticks.
private struct Pic {
    var pts: Int64
    var frame: Frame
}

/// How a track's samples become pictures.
enum VideoBackend {
    /// VideoToolbox; `gated`: a session that fails to open means the decoder isn't installed (unsupported),
    /// not a damaged stream.
    case toolbox(CMVideoFormatDescription, gated: Bool)
    /// A registered external decoder, fed a keyframe-to-keyframe run of packets at a time.
    case external(any MediaExternalVideoDecoder, codecID: String, codecPrivate: Data?)
}

/// Decodes the video track of a file, frame by frame in presentation order (deckcraft's `VideoDecoder`).
public final class VideoDecoder {
    /// (pts in ticks, sync) per sample, decode order.
    private let samples: [(Int64, Bool)]
    /// The smallest pts of samples `i...` (decode order): a picture is safe to emit once no sample still
    /// to be fed can come before it.
    private let suffixMinPts: [Int64]
    /// Seconds per tick (num, den).
    private let timebase: (Int64, Int64)
    private let read: (Int) -> [UInt8]?
    private let backend: VideoBackend
    private var session: VTDecompressionSession?
    public let size: (UInt32, UInt32)
    public let codec: String
    private var next = 0
    private var ready: [Pic] = []
    private var skipBefore = -Double.infinity
    private var eos = false
    private var errors = 0

    public var frameCount: Int { samples.count }

    public init(_ bytes: [UInt8]) throws(MediaError) {
        let t = try VideoTrack.open(bytes)
        samples = t.samples
        timebase = t.timebase
        read = t.read
        size = (t.width, t.height)
        codec = t.codec
        backend = t.backend
        var m = [Int64](repeating: .max, count: t.samples.count + 1)
        for i in stride(from: t.samples.count - 1, through: 0, by: -1) { m[i] = min(m[i + 1], t.samples[i].0) }
        suffixMinPts = m
        if case .toolbox(let fd, let gated) = t.backend {
            guard let s = Self.makeSession(fd) else {
                throw gated ? .unsupported("\(t.codec) video") : .corrupt("the \(t.codec) stream can't be decoded")
            }
            session = s
        }
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    private static func makeSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        var s: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs,
                                           outputCallback: nil, decompressionSessionOut: &s) == noErr
        else { return nil }
        return s
    }

    private func secs(_ pts: Int64) -> Double {
        Double(pts) * Double(timebase.0) / Double(timebase.1)
    }

    /// Decode sample `i` through VideoToolbox, adding its picture (if any) to `ready`; false when the decoder
    /// rejected it.
    private func decode(_ i: Int, _ format: CMVideoFormatDescription) -> Bool {
        guard let session, let data = read(i), !data.isEmpty else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block
        else { return false }
        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return false }
        let pts = samples[i].0
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1), decodeTimeStamp: .invalid)
        var sizes = [data.count]
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr,
            let sb
        else { return false }
        let out = DecodeOutput()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            out.set(status == noErr ? image.flatMap(Self.rgba) : nil, failed: status != noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let (produced, failed) = out.get()
        if st != noErr || failed { return false }
        if var f = produced {
            f.time = secs(pts)
            ready.append(Pic(pts: pts, frame: f))
        }
        return true
    }

    /// Feed the external decoder the run of samples from `start` to the next keyframe; returns where the run
    /// ended and whether the decoder failed.
    private func decodeRun(_ start: Int, _ decoder: any MediaExternalVideoDecoder, _ codecID: String, _ codecPrivate: Data?) -> (Int, Bool) {
        var end = start + 1
        while end < samples.count && !samples[end].1 { end += 1 }
        var packets: [MediaExternalVideoPacket] = []
        var ticks: [Int64: Int64] = [:]
        for i in start..<end {
            guard let data = read(i), !data.isEmpty else { continue }
            let ns = Int64(rustCast: (secs(samples[i].0) * 1e9).rounded())
            ticks[ns] = samples[i].0
            packets.append(MediaExternalVideoPacket(data: Data(data), ptsNanos: ns))
        }
        if packets.isEmpty { return (end, true) }
        let (frames, failed) = ExternalRun.decode(decoder, codecID: codecID, codecPrivate: codecPrivate, packets: packets)
        for (ns, f) in frames {
            let pts = ticks[ns] ?? Int64(rustCast: (Double(ns) / 1e9 * Double(timebase.1) / Double(timebase.0)).rounded())
            var frame = f
            frame.time = secs(pts)
            ready.append(Pic(pts: pts, frame: frame))
        }
        return (end, failed)
    }

    /// BGRA pixel buffer to tightly packed RGBA.
    static func rgba(_ image: CVImageBuffer) -> Frame? {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image), row = CVPixelBufferGetBytesPerRow(image)
        guard w > 0, h > 0, w <= 16384, h <= 16384, row >= w * 4 else { return nil }
        let px = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let src = px + y * row
                for x in 0..<w {
                    let s = x * 4, d = (y * w + x) * 4
                    o[d] = src[s + 2]
                    o[d + 1] = src[s + 1]
                    o[d + 2] = src[s]
                }
            }
        }
        return Frame(time: 0, width: UInt32(w), height: UInt32(h), rgba: out)
    }

    /// The next frame in presentation order, nil at the end.
    public func nextFrame() throws(MediaError) -> Frame? {
        while true {
            // A picture can go once no sample still to be fed has an earlier pts.
            if let k = ready.indices.min(by: { ready[$0].pts < ready[$1].pts }), eos || ready[k].pts <= suffixMinPts[min(next, samples.count)] {
                let p = ready.remove(at: k)
                if p.frame.time + 1e-6 < skipBefore { continue }
                return p.frame
            }
            if eos { return nil }
            if next >= samples.count {
                eos = true
                continue
            }
            let ok: Bool
            switch backend {
            case .toolbox(let fd, _):
                ok = decode(next, fd)
                next += 1
            case .external(let d, let id, let p):
                let (end, failed) = decodeRun(next, d, id, p)
                next = end
                ok = !failed
            }
            if !ok {
                // A corrupt sample: carry on (the picture is lost), give up after many.
                errors += 1
                if errors > 50 { throw .corrupt("the video can't be decoded") }
            }
        }
    }

    /// Position so that the next frame is the one shown at `t` seconds (decoding resumes at the preceding
    /// sync sample).
    public func seek(_ t: Double) {
        let target = Int64(rustCast: t * Double(timebase.1) / Double(timebase.0))
        var start = 0
        for (i, (pts, sync)) in samples.enumerated() where sync && pts <= target { start = i }
        if case .toolbox(let fd, _) = backend {
            if let s = session {
                VTDecompressionSessionWaitForAsynchronousFrames(s)
                VTDecompressionSessionInvalidate(s)
            }
            session = Self.makeSession(fd)
        }
        ready.removeAll()
        next = start
        eos = false
        let shown = samples.map(\.0).filter { $0 <= target }.max()
        skipBefore = shown.map(secs) ?? -.infinity
    }
}

/// The video track of a file and how to decode it.
struct VideoTrack {
    var samples: [(Int64, Bool)]
    var timebase: (Int64, Int64)
    var width: UInt32
    var height: UInt32
    var codec: String
    var backend: VideoBackend
    var read: (Int) -> [UInt8]?

    /// A format description carrying a configuration record as a sample-description extension atom.
    static func atomFormat(_ type: CMVideoCodecType, _ atom: String, _ record: [UInt8], _ w: UInt32, _ h: UInt32, _ codec: String) throws(MediaError)
        -> VideoBackend
    {
        var fd: CMVideoFormatDescription?
        let atoms = [atom: Data(record)] as CFDictionary
        let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: type, width: Int32(clamping: w), height: Int32(clamping: h), extensions: ext,
                                             formatDescriptionOut: &fd) == noErr, let fd
        else { throw .corrupt("the \(codec) configuration can't be read") }
        return .toolbox(fd, gated: false)
    }

    /// A format description from the codec type and size alone (ProRes, JPEG): the frames describe themselves.
    static func plainFormat(_ type: CMVideoCodecType, _ w: UInt32, _ h: UInt32, _ codec: String) throws(MediaError) -> VideoBackend {
        var fd: CMVideoFormatDescription?
        guard w > 0, h > 0,
              CMVideoFormatDescriptionCreate(allocator: nil, codecType: type, width: Int32(clamping: w), height: Int32(clamping: h), extensions: nil,
                                             formatDescriptionOut: &fd) == noErr, let fd
        else { throw .unsupported("\(codec) video") }
        return .toolbox(fd, gated: true)
    }

    /// MPEG-1/2 through media-bridge's `FormatDescriptionFactory` (the sequence header travels in-band).
    static func mpegFormat(_ codecID: String, _ w: UInt32, _ h: UInt32, _ codec: String) throws(MediaError) -> VideoBackend {
        guard let fd = try? FormatDescriptionFactory.makeVideo(codecID: codecID, codecPrivate: nil, width: Int(w), height: Int(h)) else {
            throw .unsupported("\(codec) video")
        }
        return .toolbox(fd, gated: true)
    }

    /// A registered external decoder for `codecID`, or deckcraft's "unsupported".
    static func external(_ codecID: String, _ codecPrivate: [UInt8], _ codec: String) throws(MediaError) -> VideoBackend {
        guard let d = Media.externalDecoder(for: codecID) else { throw .unsupported("\(codec) video") }
        return .external(d, codecID: codecID, codecPrivate: codecPrivate.isEmpty ? nil : Data(codecPrivate))
    }

    /// deckcraft's `open_track`, with this app's codec set.
    static func open(_ bytes: [UInt8]) throws(MediaError) -> VideoTrack {
        switch Container.sniff(bytes) {
        case .mp4:
            let f: BMFFFile
            do { f = try BMFF.open(bytes) } catch { throw .corrupt(error.message) }
            guard let ti = f.trackOfKind(.video), let entry = f.tracks[ti].entries.first else { throw .missing("video track") }
            let t = f.tracks[ti]
            let (w, h) = entry.video.map { (UInt32($0.width), UInt32($0.height)) } ?? (t.width, t.height)
            let name = entry.codec.name
            let backend: VideoBackend
            switch entry.codec {
            case .avc(let r): backend = try atomFormat(kCMVideoCodecType_H264, "avcC", r, w, h, name)
            case .hevc(let r): backend = try atomFormat(kCMVideoCodecType_HEVC, "hvcC", r, w, h, name)
            case .av1(let r) where VideoSupport.av1: backend = try atomFormat(kCMVideoCodecType_AV1, "av1C", r, w, h, name)
            case .proRes, .jpeg: backend = try plainFormat(entry.format.value, w, h, name)
            case .vp9(let r): backend = try external("V_VP9", r, name)
            case .unknown(let fcc) where fcc == FourCC("vp08"): backend = try external("V_VP8", [], name)
            default: throw .unsupported("\(name) video")
            }
            let samples = t.samples.indices.map { (t.presentationPts($0) ?? 0, t.samples[$0].isSync) }
            return VideoTrack(samples: samples, timebase: (1, Int64(max(t.timescale, 1))), width: w, height: h, codec: name, backend: backend,
                              read: { i in (try? f.readSample(bytes, ti, i)).map(Array.init) })
        case .matroska:
            let f: MKVFile
            do { f = try Matroska.open(bytes) } catch { throw .corrupt(error.message) }
            guard let ti = f.tracks.firstIndex(where: { $0.kind == .video && !$0.samples.isEmpty }) else { throw .missing("video track") }
            let t = f.tracks[ti]
            let (w, h) = (t.pixelWidth ?? 0, t.pixelHeight ?? 0)
            let name = t.codec.name
            let backend: VideoBackend
            switch t.codec {
            case .avc(let r): backend = try atomFormat(kCMVideoCodecType_H264, "avcC", r, w, h, name)
            case .hevc(let r): backend = try atomFormat(kCMVideoCodecType_HEVC, "hvcC", r, w, h, name)
            case .av1(let r) where VideoSupport.av1: backend = try atomFormat(kCMVideoCodecType_AV1, "av1C", r, w, h, name)
            case .proRes(let fcc):
                backend = try plainFormat(fcc.map { FourCC(bytes: $0[...]).value } ?? kCMVideoCodecType_AppleProRes422, w, h, name)
            case .mjpeg: backend = try plainFormat(kCMVideoCodecType_JPEG, w, h, name)
            case .other("V_MPEG1"), .other("V_MPEG2"): backend = try mpegFormat(t.codecID, w, h, name)
            case .vp9(let p): backend = try external("V_VP9", p, name)
            case .vp8: backend = try external("V_VP8", t.codecPrivate, name)
            case .other(let id): backend = try external(id, t.codecPrivate, name)
            default: throw .unsupported("\(name) video")
            }
            return VideoTrack(samples: t.samples.map { ($0.pts, $0.keyframe) },
                              timebase: (Int64(clamping: max(t.timebase.0, 1)), Int64(clamping: max(t.timebase.1, 1))),
                              width: w, height: h, codec: name, backend: backend, read: { i in try? f.readSample(bytes, ti, i) })
        case .asf:
            throw .unsupported("Windows Media Video (WMV)")
        default:
            throw .missing("video track")
        }
    }
}

extension Media {
    /// The frame shown at `t` seconds (the first frame when `t` is 0) (deckcraft's `poster_frame`).
    public static func posterFrame(_ bytes: [UInt8], _ t: Double) throws(MediaError) -> Frame {
        let d = try VideoDecoder(bytes)
        if t > 0 { d.seek(t) }
        var last: Frame?
        while let f = try d.nextFrame() {
            if f.time > t + 1e-6 && last != nil { break }
            let done = f.time + 1e-6 >= t
            last = f
            if done { break }
        }
        guard let last else { throw .corrupt("no picture could be decoded") }
        return last
    }

    /// `posterFrame` as PNG bytes (deckcraft's `poster_png`).
    public static func posterPNG(_ bytes: [UInt8], _ t: Double) throws(MediaError) -> [UInt8] {
        let f = try posterFrame(bytes, t)
        guard let png = PNG.encode(f) else { throw .corrupt("bad picture size") }
        return png
    }
}

enum PNG {
    /// RGBA8 to PNG through ImageIO.
    static func encode(_ f: Frame) -> [UInt8]? {
        let w = Int(f.width), h = Int(f.height)
        guard w > 0, h > 0, f.rgba.count == w * h * 4, let provider = CGDataProvider(data: Data(f.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }
}
