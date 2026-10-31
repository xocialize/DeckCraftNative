// Port of deckcraft crates/pptx/tests/it/media_timing.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Media settings PowerPoint keeps in the timing tree, spliced into an exported deck
// and read back.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationMediaTimingTests {
    private static func node(_ tag: String, _ attrs: String, _ spid: UInt32, _ media: String, _ ctn: String) -> String {
        #"<p:par><p:cTn id="2" fill="hold"><p:childTnLst><p:\#(tag)\#(attrs)><p:cMediaNode\#(media)><p:cTn id="3"\#(ctn)/><p:tgtEl><p:spTgt spid="\#(spid)"/></p:tgtEl></p:cMediaNode></p:\#(tag)></p:childTnLst></p:cTn></p:par>"#
    }

    /// A video and a sound clip, with the timing tree `nodes(videoId, audioId)` spliced into the slide,
    /// read back: the clips, in order.
    private static func clips(_ nodes: (UInt32, UInt32) -> String) throws -> [MediaClip] {
        var p = newPresentation(nil)
        let v = p.addMedia("clip.mp4", "video/mp4", Array("video".utf8))
        let a = p.addMedia("clip.m4a", "audio/mp4", Array("audio".utf8))
        let video = try #require(v, "media")
        let audio = try #require(a, "media")
        var ids: [UInt32] = []
        for (media, isVideo) in [(video, true), (audio, false)] {
            let n = p.allocId()
            let id = try #require(n, "id")
            ids.append(id)
            var s = Shape.default
            s.id = ShapeId(id)
            s.name = "Clip"
            s.xfrm = Xfrm(40.0, 40.0, 200.0, 100.0)
            s.kind = .media(MediaClip(media: media, video: isVideo, volume: 1.0))
            p.slides[0].shapes.append(s)
        }
        let timing = #"<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\#(nodes(ids[0], ids[1]))</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>"#
        let bytes = try IT.zip(IT.entries(PPTX.export(p)).map { e in
            guard e.name == "ppt/slides/slide1.xml" else { return e }
            let s = String(decoding: e.data, as: UTF8.self)
            #expect(!s.has("<p:timing"))
            let end = try #require(s.byteRFind("</p:sld>"), "end")
            return (e.name, Array((s.bytes(0, end) + timing + s.bytes(end)).utf8))
        })
        let q = try PPTX.import(bytes)
        return q.slides[0].shapes.compactMap { s in
            if case .media(let m) = s.kind { m } else { nil }
        }
    }

    // Rust: it/media_timing.rs::video_settings_are_read_from_the_timing_tree
    @Test func videoSettingsAreReadFromTheTimingTree() throws {
        let c = try Self.clips { v, _ in
            Self.node("video", #" fullScrn="1""#, v, #" vol="80000" showWhenStopped="0""#, #" repeatCount="indefinite""#)
        }
        try #require(c.count == 2)
        #expect(c[0].volume == 0.8 && c[0].hideWhileNotPlaying && c[0].loopPlay && c[0].fullScreen)
        // The sound next to it has no node: defaults stay.
        #expect(c[1].volume == 1.0 && !c[1].hideWhileNotPlaying && !c[1].loopPlay && !c[1].fullScreen)
    }

    // Rust: it/media_timing.rs::muted_audio_has_no_volume_and_other_clips_keep_theirs
    @Test func mutedAudioHasNoVolumeAndOtherClipsKeepTheirs() throws {
        let c = try Self.clips { _, a in Self.node("audio", "", a, #" vol="50000" mute="1""#, "") }
        try #require(c.count == 2)
        #expect(c[0].volume == 1.0)
        #expect(c[1].volume == 0.0 && !c[1].loopPlay && !c[1].fullScreen)
    }
}
