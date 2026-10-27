// DCMediaTests — the codecs beyond deckcraft's own: MPEG-1/2, ProRes and Motion JPEG video through VideoToolbox;
// MPEG audio layers I/II, AC-3, E-AC-3 and Vorbis through AudioToolbox; VP9/VP8 through the external-decoder seam.
// Probe fields stay deckcraft's (`decodable` included); only `videoSupport`/`audioSupport` and playback change.
// Test media is written here (MPEG-1/2 pictures and MPEG audio frames bit by bit, ProRes/JPEG by AVAssetWriter).
import AudioToolbox
import AVFoundation
import CoreVideo
@testable import DCMedia
import Foundation
import Testing

/// A stand-in for vpx-swift's `VpxVideoDecoder`: claims VP9 and VP8, but only inside a test that turns it on,
/// so tests running alongside (the oracle comparison, the VP9 "unsupported" check) never see it.
struct FakeVPX: MediaExternalVideoDecoder {
    @TaskLocal static var enabled = false

    func canDecode(codecID: String) -> Bool { FakeVPX.enabled && (codecID == "V_VP9" || codecID == "V_VP8") }

    /// One solid BGRA frame per packet, grey level 10 × the packet's index.
    func decodeStreaming(codecID: String, codecPrivate: Data?, packets: [MediaExternalVideoPacket],
                         onFrame: (MediaDecodedVideoFrame) async throws -> Void) async throws
    {
        for (i, p) in packets.enumerated() {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess, let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, Int32(10 * i % 256), CVPixelBufferGetBytesPerRow(pb) * 48)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            try await onFrame(MediaDecodedVideoFrame(image: pb, ptsNanos: p.ptsNanos))
        }
    }
}

private let fakeRegistered: Bool = {
    Media.register(externalDecoder: FakeVPX())
    return true
}()

@Suite struct NativeCodecTests {
    @Test(arguments: [1, 2]) func mpegVideoDecodes(version: Int) throws {
        let b = TestMedia.mpegVideoMKV(version: version, frames: 4)
        let name = version == 1 ? "V_MPEG1" : "V_MPEG2"
        // The probe is deckcraft's: an "other" Matroska codec, not decodable by deckcraft.
        let info = try Media.probe(b)
        #expect(info.video == VideoInfo(codec: name, width: 64, height: 48, fps: 25, frames: 4, decodable: false))
        let supported = version == 1 ? VideoSupport.mpeg1 : VideoSupport.mpeg2
        #expect(info.videoSupport == (supported ? .supported : .unsupported("\(name) video")))
        guard supported else { return }
        let d = try VideoDecoder(b)
        var frames: [Frame] = []
        while let f = try d.nextFrame() { frames.append(f) }
        #expect(frames.count == 4)
        for (k, f) in frames.enumerated() {
            #expect(abs(f.time - Double(k) * 0.04) < 1e-9)
            // Luma 64 + 32k, neutral chroma: grey (Y − 16) × 255 / 219.
            let want = Double(64 + 32 * k - 16) * 255 / 219
            let c = centre(f)
            for i in 0..<3 { #expect(abs(c[i] - want) < 6, "\(name) frame \(k): \(c) vs \(want)") }
        }
        d.seek(0.09)
        #expect(try d.nextFrame()?.time == 0.08)
        #expect(try Media.posterPNG(b, 0).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test(arguments: [AVVideoCodecType.proRes422, .proRes4444, .jpeg])
    func proResAndJpegDecode(codec: AVVideoCodecType) async throws {
        let b = try await TestMedia.movie(fileType: .mov, codec: codec)
        let info = try Media.probe(b)
        let v = try #require(info.video)
        // deckcraft names them and can't decode them; this Mac can.
        #expect(!v.decodable)
        #expect(v.codec == (codec == .jpeg ? "Motion JPEG" : "Apple ProRes"))
        let native = codec == .jpeg ? VideoSupport.jpeg : VideoSupport.proRes
        #expect(info.videoSupport == (native ? .supported : .unsupported("\(v.codec) video")))
        guard native else { return }
        let d = try VideoDecoder(b)
        var k = 0
        while let f = try d.nextFrame() {
            #expect(abs(f.time - Double(k) * 0.1) < 0.02)
            let (c, e) = (centre(f), expectedCentre(64, 48, k))
            for i in 0..<3 { #expect(abs(c[i] - e[i]) < 24, "\(codec.rawValue) frame \(k) channel \(i): \(c) vs \(e)") }
            k += 1
        }
        #expect(k == 6)
    }

    @Test(arguments: [1, 2]) func mpegAudioLayersOneAndTwoDecode(layer: Int) throws {
        let frame = TestMedia.mpegAudioFrame(layer: layer)
        let spf = layer == 1 ? 384 : 1152
        // A plain file: probed as deckcraft does, decoded by AudioFile.
        let file = Array([[UInt8]](repeating: frame, count: 20).joined())
        let info = try Media.probe(file)
        #expect(info.audio == AudioInfo(codec: layer == 1 ? "MP1" : "MP2", sampleRate: 44100, channels: 1, decodable: true))
        #expect(info.audioSupport == .supported)
        let p = try Media.decodeAudio(file)
        #expect(p.rate == 44100 && p.channels == 1)
        #expect(abs(p.frames - 20 * spf) <= spf, "\(p.frames)")
        #expect(p.rms < 1e-3)
        // In Matroska (deckcraft probes it but can't decode it): AudioConverter, layer from the frame header.
        var blocks: [(UInt64, Int16, Bool, [UInt8])] = []
        for i in 0..<10 { blocks.append((1, Int16(i * 26), true, frame)) }
        let track = TestMedia.MKVTrackSpec(number: 1, type: 2, codecID: layer == 1 ? "A_MPEG/L1" : "A_MPEG/L2", rate: 44100, channels: 1)
        let mka = TestMedia.mkv(docType: "matroska", durationMs: nil, tracks: [track], clusters: [(0, blocks)])
        let mi = try Media.probe(mka)
        #expect(mi.audio == AudioInfo(codec: layer == 1 ? "mp1" : "mp2", sampleRate: 44100, channels: 1, decodable: false))
        #expect(mi.audioSupport == .supported)
        let q = try Media.decodeAudio(mka)
        #expect(abs(q.frames - 10 * spf) <= spf, "\(q.frames)")
    }

    @Test func ac3AndEac3HaveDecoders() {
        // No in-code AC-3 encoder exists (AudioToolbox has decoders only), so the decoders are checked directly
        // and the support matrix through deckcraft's codec names.
        for (format, name) in [(kAudioFormatAC3, "AC-3"), (kAudioFormatEnhancedAC3, "E-AC-3")] {
            var input = AudioDecode.asbd(format, rate: 48000, channels: 2, framesPerPacket: 1536)
            var output = AudioDecode.floatFormat(48000, 2)
            var conv: AudioConverterRef?
            #expect(AudioConverterNew(&input, &output, &conv) == noErr, "\(name)")
            if let conv { AudioConverterDispose(conv) }
            #expect(AudioSupport.of(name) == .supported)
            #expect(AudioSupport.of(name == "AC-3" ? "ac3" : "eac3") == .supported)
        }
    }

    @Test func supportMatrix() {
        #expect(VideoSupport.of("H.264") == .supported)
        #expect(VideoSupport.of("HEVC") == .supported)
        #expect(VideoSupport.of("DNxHD") == .unsupported("DNxHD video"))
        #expect(VideoSupport.of("WMV") == .unsupported("WMV video"))
        #expect(AudioSupport.of("WMA 2") == .unsupported("Windows Media Audio (WMA)"))
        #expect(AudioSupport.of("unknown") == .unsupported("unknown audio"))
        #expect(AudioSupport.of("pcm_s16le") == .supported)
        #expect(AudioSupport.of("ADPCM") == .supported)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func vorbisDecodesInOggAndWebm() throws {
        guard AudioSupport.vorbis else { return }
        // AudioToolbox has a Vorbis decoder on this macOS: the cookie is the Xiph-laced headers.
        try checkTone("vorbis", try #require(UpstreamFixtures.load("tone.ogg")), 44100, 2)
        #expect(try Media.decodeAudio(try #require(UpstreamFixtures.load("tone.ogg"))).frames == 22528)
        let webm = try #require(UpstreamFixtures.load("clip-vp8.webm"))
        let p = try Media.decodeAudio(webm)
        #expect(p.rate == 44100 && p.channels == 2 && p.frames == 22528)
        #expect(abs(frequency(p) - 440) < 15)
    }
}

@Suite struct ExternalDecoderTests {
    @Test(.enabled(if: UpstreamFixtures.available)) func registeredDecoderPlaysVP9AndVP8() throws {
        #expect(fakeRegistered)
        let vp9 = try #require(UpstreamFixtures.load("clip-vp9.webm"))
        let vp8 = try #require(UpstreamFixtures.load("clip-vp8.webm"))
        // Without a decoder that claims them: deckcraft's "unsupported".
        #expect(try Media.probe(vp9).videoSupport == .unsupported("VP9 video"))
        #expect(throws: MediaError.unsupported("VP8 video")) { try VideoDecoder(vp8) }
        try FakeVPX.$enabled.withValue(true) {
            for (b, codec) in [(vp9, "VP9"), (vp8, "VP8")] {
                let info = try Media.probe(b)
                // The probe is unchanged (deckcraft's `decodable`), the support is not.
                #expect(info.video?.codec == codec)
                #expect(info.videoSupport == .supported, "\(codec)")
                let d = try VideoDecoder(b)
                var times: [Double] = []
                var greys: [UInt8] = []
                while let f = try d.nextFrame() {
                    times.append(f.time)
                    greys.append(f.rgba[0])
                }
                // deckcraft's frame times for both clips: 0, 0.1, … 0.4 (the oracle's `times` line).
                #expect(times == [0, 0.1, 0.2, 0.3, 0.4], "\(codec): \(times)")
                // Keyframe runs: the fake numbers packets from each run's keyframe.
                #expect(greys.first == 0)
                // Seeking resumes at the preceding keyframe and lands on the frame shown.
                d.seek(0.35)
                #expect(try d.nextFrame()?.time == 0.3)
                #expect(try Media.posterFrame(b, 0.25).time == 0.2)
                // The feed runs on the same decoder.
                let feed = try VideoFeed(b)
                #expect(feed.frameAtBlocking(0.25, timeout: 5)?.time == 0.2)
            }
        }
    }

    @Test func aDecoderForAnotherCodecIDIsLookedUpByID() throws {
        // Any Matroska CodecID the app's decoder claims plays, not only VP9/VP8.
        struct Theora: MediaExternalVideoDecoder {
            @TaskLocal static var enabled = false
            func canDecode(codecID: String) -> Bool { Theora.enabled && codecID == "V_THEORA" }
            func decodeStreaming(codecID: String, codecPrivate: Data?, packets: [MediaExternalVideoPacket],
                                 onFrame: (MediaDecodedVideoFrame) async throws -> Void) async throws
            {
                try await FakeVPX().decodeStreaming(codecID: codecID, codecPrivate: codecPrivate, packets: packets, onFrame: onFrame)
            }
        }
        Media.register(externalDecoder: Theora())
        var blocks: [(UInt64, Int16, Bool, [UInt8])] = []
        for i in 0..<3 { blocks.append((1, Int16(i * 40), i == 0, [UInt8(0x80 | i)])) }
        let track = TestMedia.MKVTrackSpec(number: 1, type: 1, codecID: "V_THEORA", codecPrivate: [1, 2, 3], width: 64, height: 48)
        let b = TestMedia.mkv(docType: "matroska", durationMs: 120, tracks: [track], clusters: [(0, blocks)])
        #expect(throws: MediaError.unsupported("V_THEORA video")) { try VideoDecoder(b) }
        try Theora.$enabled.withValue(true) {
            #expect(try Media.probe(b).videoSupport == .supported)
            let d = try VideoDecoder(b)
            var n = 0
            while try d.nextFrame() != nil { n += 1 }
            #expect(n == 3)
        }
    }
}
