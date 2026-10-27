// DCMediaTests — decoding and probing every supported format: deckcraft crates/media/tests/it/decode.rs, ported
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). WAV and AIFF are written here; the
// compressed files are upstream's CC0 fixtures (a 0.5 s 440 Hz sine and a 6-frame 64×48 gradient, encoded with
// ffmpeg by its make.sh), read from the deckcraft checkout beside this repo; tests that need them skip without
// it. Where macOS has no decoder (Vorbis, VP9, WMA) the test checks the typed "unsupported" state instead.
import AudioToolbox
@testable import DCMedia
import DCTestSupport
import Foundation
import Testing

enum UpstreamFixtures {
    /// `../deckcraft/crates/media/tests/fixtures`, beside the fixtures repository.
    static var dir: URL {
        Fixtures.root.deletingLastPathComponent().appending(path: "deckcraft/crates/media/tests/fixtures", directoryHint: .isDirectory)
    }

    static var available: Bool { FileManager.default.fileExists(atPath: dir.appending(path: "tone.mp3").path) }

    static func load(_ name: String) -> [UInt8]? {
        (try? Data(contentsOf: dir.appending(path: name))).map { [UInt8]($0) }
    }
}

/// Frequency of channel 0 from its zero crossings (with hysteresis), over the span between the first and
/// last crossing.
func frequency(_ p: Pcm) -> Double {
    var sign = 0
    var crossings: [Int] = []
    for i in 0..<p.frames {
        let s = p.at(i, 0)
        let now = s > 0.03 ? 1 : s < -0.03 ? -1 : 0
        if now != 0 && now != sign {
            if sign != 0 { crossings.append(i) }
            sign = now
        }
    }
    guard let a = crossings.first, let b = crossings.last, b > a else { return 0 }
    return Double(crossings.count - 1) / 2 / (Double(b - a) / Double(p.rate))
}

/// The tone decodes to ~0.5 s of a 440 Hz sine at amplitude 1/8, and probes to match.
func checkTone(_ name: String, _ b: [UInt8], _ rate: UInt32, _ channels: UInt16, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let p = try Media.decodeAudio(b)
    #expect(p.rate == rate && p.channels == channels, "\(name): \(p.rate) Hz × \(p.channels)", sourceLocation: sourceLocation)
    #expect(abs(p.duration - 0.5) < 0.06, "\(name): \(p.duration) s", sourceLocation: sourceLocation)
    let f = frequency(p)
    #expect(abs(f - 440) < 15, "\(name): \(f) Hz", sourceLocation: sourceLocation)
    #expect((0.055..<0.105).contains(p.rms), "\(name): rms \(p.rms)", sourceLocation: sourceLocation)
    let info = try Media.probe(b)
    let a = try #require(info.audio, "\(name): no audio info", sourceLocation: sourceLocation)
    #expect(a.decodable, "\(name)", sourceLocation: sourceLocation)
    #expect(a.sampleRate == rate && a.channels == channels, "\(name)", sourceLocation: sourceLocation)
    #expect(abs(Int(info.durationMs) - 500) <= 60, "\(name): \(info.durationMs) ms", sourceLocation: sourceLocation)
    #expect(info.video == nil, "\(name)", sourceLocation: sourceLocation)
    #expect(info.audioSupport == .supported, "\(name)", sourceLocation: sourceLocation)
}

@Suite struct AudioDecodeTests {
    @Test func wavWrittenInCode() throws {
        let b = TestMedia.wav(44100, 1, TestMedia.sine(44100, 0.5))
        #expect(Container.sniff(b) == .wav)
        try checkTone("wav", b, 44100, 1)
        try checkTone("wav stereo", TestMedia.wav(22050, 2, TestMedia.sine(22050, 0.5).flatMap { [$0, $0] }), 22050, 2)
    }

    @Test func aiffWrittenInCode() throws {
        let b = TestMedia.aiff(48000, TestMedia.sine(48000, 0.5))
        #expect(Container.sniff(b) == .aiff)
        try checkTone("aiff", b, 48000, 1)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func mp3() throws {
        let b = try #require(UpstreamFixtures.load("tone.mp3"))
        #expect(Container.sniff(b) == .mp3)
        try checkTone("mp3", b, 44100, 1)
        // The LAME/ffmpeg tag's delay and padding are trimmed, as deckcraft's reader does.
        #expect(try Media.decodeAudio(b).frames == 22050)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func aacM4aAndAdts() throws {
        try checkTone("m4a", try #require(UpstreamFixtures.load("tone.m4a")), 44100, 1)
        let adts = try #require(UpstreamFixtures.load("tone.aac"))
        #expect(Container.sniff(adts) == .adts)
        try checkTone("aac", adts, 44100, 1)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func alac() throws {
        try checkTone("alac", try #require(UpstreamFixtures.load("tone-alac.m4a")), 44100, 1)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func flac() throws {
        try checkTone("flac", try #require(UpstreamFixtures.load("tone.flac")), 44100, 1)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func oggVorbis() throws {
        // Probed like deckcraft; decoded by AudioToolbox's Vorbis decoder where macOS has one, else "can't play".
        let b = try #require(UpstreamFixtures.load("tone.ogg"))
        let info = try Media.probe(b)
        #expect(info.audio == AudioInfo(codec: "Vorbis", sampleRate: 44100, channels: 2, decodable: true))
        if AudioSupport.vorbis {
            try checkTone("vorbis", b, 44100, 2)
        } else {
            #expect(info.audioSupport == .unsupported("Vorbis audio"))
            #expect(throws: MediaError.unsupported("Vorbis audio")) { try Media.decodeAudio(b) }
        }
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func oggOpus() throws {
        try checkTone("opus", try #require(UpstreamFixtures.load("tone.opus")), 48000, 1)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func wmaIsProbedButNotDecoded() throws {
        let b = try #require(UpstreamFixtures.load("tone.wma"))
        #expect(Container.sniff(b) == .asf)
        let info = try Media.probe(b)
        let a = try #require(info.audio)
        #expect(a.codec == "WMA 2" && a.sampleRate == 44100 && a.channels == 1 && !a.decodable)
        #expect(abs(Int(info.durationMs) - 500) <= 120, "\(info.durationMs)")
        #expect(!info.playable)
        #expect(throws: MediaError.unsupported("Windows Media Audio (WMA)")) { try Media.decodeAudio(b) }
    }

    @Test func generatedAudioDecodes() async throws {
        // AudioToolbox's own encodes of the tone, through this package's demuxers and decoders.
        let s = TestMedia.sine(44100, 0.5)
        let m4a = try TestMedia.encode(s, rate: 44100, channels: 1, fileType: kAudioFileM4AType, format: kAudioFormatMPEG4AAC, ext: "m4a")
        let aac = try Media.decodeAudio(m4a)
        #expect(aac.rate == 44100 && aac.channels == 1)
        #expect(abs(frequency(aac) - 440) < 15)
        // AudioToolbox writes 2 in the sample entry's channel count of a mono AAC track; the probe reports the
        // sample entry, as deckcraft's does, and the decoder the stream.
        #expect(try Media.probe(m4a).audio?.channels == 2)
        let caf = try TestMedia.encode(s, rate: 44100, channels: 1, fileType: kAudioFileCAFType, format: kAudioFormatAppleLossless, ext: "caf")
        let p = try Media.decodeAudio(caf)
        #expect(p.frames == 22050)
        #expect(abs(frequency(p) - 440) < 15)
        // The movie's AAC track.
        let mp4 = try await TestMedia.movie(fileType: .mp4, codec: .h264, frames: 5, audio: true)
        #expect(abs(frequency(try Media.decodeAudio(mp4)) - 440) < 15)
    }
}

/// Mean colour of a 16×16 block in the middle of the frame.
func centre(_ f: Frame) -> [Double] {
    let (w, h) = (Int(f.width), Int(f.height))
    var s = [0.0, 0.0, 0.0]
    var n = 0.0
    for y in (h / 2 - 8)..<(h / 2 + 8) {
        for x in (w / 2 - 8)..<(w / 2 + 8) {
            for c in 0..<3 { s[c] += Double(f.rgba[(y * w + x) * 4 + c]) }
            n += 1
        }
    }
    return s.map { $0 / n }
}

/// The gradient's mean over the same block in frame `k`.
func expectedCentre(_ w: Int, _ h: Int, _ k: Int) -> [Double] {
    var s = [0.0, 0.0, 0.0]
    var n = 0.0
    for y in (h / 2 - 8)..<(h / 2 + 8) {
        for x in (w / 2 - 8)..<(w / 2 + 8) {
            s[0] += Double((x * 4 + k * 20) % 256)
            s[1] += Double((y * 5) % 256)
            s[2] += Double((k * 40) % 256)
            n += 1
        }
    }
    return s.map { $0 / n }
}

func checkVideo(_ name: String, _ b: [UInt8], _ w: UInt32, _ h: UInt32, _ frames: Int, _ codec: String) throws {
    let info = try Media.probe(b)
    let v = try #require(info.video, "\(name): no video info")
    #expect(v.codec == codec && v.width == w && v.height == h && v.decodable, "\(name)")
    #expect(abs(v.fps - 10) < 0.6, "\(name): \(v.fps) fps")
    #expect(abs(Int(info.durationMs) - frames * 100) <= 120, "\(name): \(info.durationMs) ms")
    #expect(info.videoSupport == .supported, "\(name)")
    let d = try VideoDecoder(b)
    var got: [Frame] = []
    while let f = try d.nextFrame() {
        #expect(f.width == w && f.height == h && f.rgba.count == Int(w * h * 4), "\(name)")
        got.append(f)
    }
    #expect(got.count == frames, "\(name)")
    for (k, f) in got.enumerated() {
        #expect(abs(f.time - Double(k) * 0.1) < 0.02, "\(name): frame \(k) at \(f.time)")
        // VideoToolbox's colour conversion stands in for deckcraft's yuv.rs: the gradient comes back.
        let (c, e) = (centre(f), expectedCentre(Int(w), Int(h), k))
        for i in 0..<3 { #expect(abs(c[i] - e[i]) < 24, "\(name): frame \(k) channel \(i): \(c) vs \(e)") }
    }
    // Seeking lands on the frame shown at that time.
    d.seek(0.35)
    let f = try #require(try d.nextFrame(), "\(name): no frame after seek")
    #expect(abs(f.time - 0.3) < 0.02, "\(name): seek gave \(f.time)")
    // Poster frames.
    let p = try Media.posterFrame(b, 0.25)
    #expect(abs(p.time - 0.2) < 0.02, "\(name): poster at \(p.time)")
    let png = try Media.posterPNG(b, 0)
    #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
}

@Suite struct VideoDecodeTests {
    @Test(.enabled(if: UpstreamFixtures.available)) func h264Mp4WithBFramesAndAacAudio() throws {
        let b = try #require(UpstreamFixtures.load("clip-h264.mp4"))
        try checkVideo("clip-h264.mp4", b, 64, 48, 5, "H.264")
        // Its audio track decodes too.
        let info = try Media.probe(b)
        #expect(info.audio?.codec == "AAC" && info.audio?.decodable == true)
        #expect(abs(frequency(try Media.decodeAudio(b)) - 440) < 15)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func h264Mov() throws {
        let b = try #require(UpstreamFixtures.load("clip-h264.mov"))
        try checkVideo("clip-h264.mov", b, 64, 48, 6, "H.264")
        #expect(try Media.probe(b).container == "mov")
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func hevcMp4() throws {
        try checkVideo("clip-hevc.mp4", try #require(UpstreamFixtures.load("clip-hevc.mp4")), 64, 48, 6, "HEVC")
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func vp9WebmIsProbedAndItsOpusAudioDecodes() throws {
        // VP9 is deferred (PLAN.md §8): probed as deckcraft does, decoded as "unsupported"; the Opus track plays.
        let b = try #require(UpstreamFixtures.load("clip-vp9.webm"))
        let info = try Media.probe(b)
        #expect(info.video?.codec == "VP9" && info.video?.decodable == true)
        #expect(info.videoSupport == .unsupported("VP9 video"))
        #expect(throws: MediaError.unsupported("VP9 video")) { try VideoDecoder(b) }
        #expect(info.audio?.codec == "Opus" && info.audio?.sampleRate == 48000)
        let p = try Media.decodeAudio(b)
        #expect(p.rate == 48000)
        #expect(abs(frequency(p) - 440) < 15)
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func av1Mkv() throws {
        let b = try #require(UpstreamFixtures.load("clip-av1.mkv"))
        if VideoSupport.av1 {
            try checkVideo("clip-av1.mkv", b, 64, 64, 6, "AV1")
        } else {
            #expect(try Media.probe(b).videoSupport == .unsupported("AV1 video on this Mac"))
            #expect(throws: MediaError.unsupported("AV1 video")) { try VideoDecoder(b) }
        }
    }

    @Test func generatedMoviesDecode() async throws {
        // AVAssetWriter's H.264 (with B-frames) and HEVC, and the H.264 samples rewrapped in Matroska.
        try checkVideo("h264 mp4", try await TestMedia.movie(fileType: .mp4, codec: .h264, frames: 6, reorder: true), 64, 48, 6, "H.264")
        try checkVideo("hevc mov", try await TestMedia.movie(fileType: .mov, codec: .hevc), 64, 48, 6, "HEVC")
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func garbageAndTruncatedFilesAreErrorsNotCrashes() throws {
        for name in ["tone.mp3", "tone.m4a", "tone.opus", "clip-h264.mp4", "clip-vp9.webm"] {
            let full = try #require(UpstreamFixtures.load(name))
            let cut = Array(full[0..<(full.count / 3)])
            _ = try? Media.probe(cut)
            _ = try? Media.decodeAudio(cut)
            if let d = try? VideoDecoder(cut) {
                while case .some(.some) = try? d.nextFrame() {}
            }
        }
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func damagedMediaNeitherCrashesNorHangs() throws {
        // Damaged files found by mutation fuzzing deckcraft's fixtures: each must come back as an error or
        // as audio, within the time limit.
        for name in ["damaged/ebml-header.mkv", "damaged/ebml-position.webm", "damaged/demux-loop.mp4", "damaged/demux-loop.m4a"] {
            let b = try #require(UpstreamFixtures.load(name))
            let start = Date()
            _ = try? Media.probe(b)
            _ = try? Media.decodeAudio(b)
            if let d = try? VideoDecoder(b) {
                for _ in 0..<12 { guard case .some(.some) = try? d.nextFrame() else { break } }
            }
            #expect(Date().timeIntervalSince(start) < 20, "\(name) still decoding")
        }
    }

    @Test(.enabled(if: UpstreamFixtures.available)) func mp4SampleTablesThatOverrunTheFileAreCorrupt() throws {
        for name in ["damaged/stsc-count.m4a", "damaged/stsz-size.m4a"] {
            let b = try #require(UpstreamFixtures.load(name))
            #expect(throws: MediaError.corrupt("the MP4's sample tables do not fit the file")) { try Media.decodeAudio(b) }
            _ = try? Media.probe(b)
        }
        for name in ["tone.m4a", "tone-alac.m4a"] {
            #expect((try? Media.decodeAudio(try #require(UpstreamFixtures.load(name)))) != nil, "\(name) still decodes")
        }
    }
}
