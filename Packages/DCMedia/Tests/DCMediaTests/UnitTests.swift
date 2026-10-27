// DCMediaTests — the unit tests of deckcraft crates/media/src (lib.rs, probe.rs, audio.rs, clip.rs), ported
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). yuv.rs's three tests check deckcraft's own
// Y'CbCr conversion, which VideoToolbox replaces: the colour checks of the decode tests stand in for them.
@testable import DCMedia
import Testing

@Suite struct ContainerTests {
    @Test func id3TagChainsDoNotRecurseTheStack() {
        // 2 MB of empty ID3v2 tags (10 bytes each) ahead of the MP3 frames: walking the chain must not cost
        // one stack frame per tag.
        var b: [UInt8] = []
        b.reserveCapacity(200_000 * 10 + 2)
        for _ in 0..<200_000 { b += [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0] }
        b += [0xFF, 0xFB]
        #expect(Container.sniff(b) == .mp3)
    }

    @Test func sniffsEveryContainer() {
        #expect(Container.sniff(TestMedia.wav(8000, 1, [0, 0])) == .wav)
        #expect(Container.sniff(TestMedia.aiff(8000, [0, 0])) == .aiff)
        #expect(Container.sniff(TestMedia.mp3(frames: 2)) == .mp3)
        #expect(Container.sniff(TestMedia.mp3(frames: 2, id3: 20)) == .mp3)
        #expect(Container.sniff(TestMedia.asf(playMs: 100, prerollMs: 0)) == .asf)
        #expect(Container.sniff(TestMedia.oggOpus(packets: 2)) == .ogg)
        #expect(Container.sniff([0x1A, 0x45, 0xDF, 0xA3, 0]) == .matroska)
        #expect(Container.sniff([0xFF, 0xF1, 0x50, 0x80]) == .adts)
        #expect(Container.sniff([0, 0, 0, 8] + Array("ftyp".utf8)) == .mp4)
        #expect(Container.sniff([]) == .unknown)
        #expect(Container.sniff([0xFF]) == .unknown)
        #expect(Container.allCases.map(\.name) == ["mp4", "matroska", "ogg", "wav", "aiff", "caf", "flac", "mp3", "adts", "asf", "unknown"])
    }

    @Test func errorMessagesAreDeckcrafts() {
        #expect(MediaError.unsupported("VP9 video").description == "VP9 video isn't supported")
        #expect(MediaError.corrupt("bad").description == "the media can't be read: bad")
        #expect(MediaError.missing("video track").description == "the file has no video track")
    }
}

@Suite struct ProbeUnitTests {
    @Test func hostileAsfObjectSizesEndTheWalk() throws {
        // The header object GUID followed by 48 × 0xFF: the walk reads a huge size back as every object
        // size and must end instead of wrapping (and trapping).
        let b = Container.asfHeader + [UInt8](repeating: 0xFF, count: 48)
        let info = try Probe.probeASF(b)
        #expect(info.container == "asf")
    }

    @Test func asfHeaderFields() throws {
        let info = try Media.probe(TestMedia.asf(playMs: 4000, prerollMs: 3100, video: (320, 240)))
        #expect(info == MediaInfo(container: "asf", durationMs: 900, audio: AudioInfo(codec: "WMA 2", sampleRate: 44100, channels: 1, decodable: false),
                                  video: VideoInfo(codec: "WMV", width: 320, height: 240, decodable: false)))
        #expect(!info.playable)
        #expect(info.audioSupport == .unsupported("Windows Media Audio (WMA)"))
        #expect(info.videoSupport == .unsupported("WMV video"))
    }

    @Test func mp3WithoutAnIndexIsMeasured() throws {
        // Fewer than 17 frames and no Xing tag: no estimate in the header, so `probe` counts the frames.
        let b = TestMedia.mp3(frames: 12)
        #expect(try Media.probeHeaders(b).durationMs == 0)
        #expect(try Media.probe(b).durationMs == 313)
        // An Info tag gives the count; a LAME tag whose CRC checks trims the encoder delay and padding.
        #expect(try Media.probeHeaders(TestMedia.mp3(frames: 20, info: true)).durationMs == 522)
    }

    @Test func garbageIsAnErrorNotAPanic() {
        let b = (0..<4000).map { UInt8($0 * 7919 % 251) }
        #expect(throws: MediaError.unsupported("this kind of media file")) { try Media.probe(b) }
        #expect(throws: (any Error).self) { try Media.decodeAudio(b) }
        #expect(throws: (any Error).self) { try VideoDecoder(b) }
    }
}

@Suite struct AudioUnitTests {
    @Test func resampleKeepsDurationAndShape() {
        let pcm = Pcm(rate: 100, channels: 1, samples: (0..<100).map { Float($0) / 100 })
        let r = Media.resample(pcm, 200)
        #expect(r.frames == 200)
        #expect(abs(r.duration - 1.0) < 1e-9)
        #expect(abs(r.at(101, 0) - 0.505) < 1e-3)
    }

    @Test func wmaIsReportedUnsupported() {
        let b = Container.asfHeader + [UInt8](repeating: 0, count: 64)
        #expect(throws: MediaError.unsupported("Windows Media Audio (WMA)")) { try Media.decodeAudio(b) }
    }

    @Test func pcmAccessorsAreBounded() {
        let p = Pcm(rate: 0, channels: 0, samples: [0.5, -0.5])
        #expect(p.frames == 2)
        #expect(p.at(5, 3) == 0)
        #expect(p.at(-1, 0) == 0)
        #expect(p.at(Int.max, 0) == 0)
        #expect(abs(p.rms - 0.5) < 1e-6)
        #expect(Pcm(rate: 1, channels: 1, samples: []).rms == 0)
    }
}

@Suite struct ClipTests {
    @Test func rangeAppliesTrims() {
        let c = ClipParams(trimStart: 1, trimEnd: 2)
        #expect(c.range(10) == (1, 8))
        // Trims longer than the clip are ignored.
        #expect(ClipParams(trimStart: 6, trimEnd: 6).range(10) == (0, 10))
        // Unknown duration: open end.
        #expect(ClipParams().range(0) == (0, .infinity))
    }

    @Test func gainFadesAndVolume() {
        let c = ClipParams(trimStart: 1, fadeIn: 2, fadeOut: 1, volume: 0.5)
        let d = 10.0
        #expect(c.gain(1, d) == 0)
        #expect(abs(c.gain(2, d) - 0.25) < 1e-6)
        #expect(abs(c.gain(5, d) - 0.5) < 1e-6)
        #expect(abs(c.gain(9.5, d) - 0.25) < 1e-6)
        #expect(c.gain(10, d) == 0)
    }

    @Test func longFadesNeverOverlap() {
        let c = ClipParams(fadeIn: 5, fadeOut: 5)
        // 2 s clip: each fade is capped at 1 s, so the middle reaches full volume.
        #expect(abs(c.gain(1, 2) - 1) < 1e-6)
        #expect(abs(c.gain(0.5, 2) - 0.5) < 1e-6)
    }

    @Test func fromMsConverts() {
        let c = ClipParams.fromMs(1500, 250, 0, 1000, 2)
        #expect(c.trimStart == 1.5 && c.trimEnd == 0.25 && c.fadeOut == 1 && c.volume == 1)
    }
}
