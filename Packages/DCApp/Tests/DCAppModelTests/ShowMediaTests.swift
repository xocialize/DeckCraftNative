// DCAppModelTests — media playback in the app and in the show: the host follows the document and the clip, GIF
// clocks, clip lookup per slide, carry-over, the media bar and the GIF button, and the "can't play" state. Ported
// from the tests of deckcraft `crates/ui-egui/src/media.rs` and the media tests of `show.rs` (names in camelCase).
import CoreGraphics
import DCCore
import DCEngine
import DCGeometry
import DCMedia
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCAppModel

/// 16-bit mono WAV at 8 kHz, `secs` long, at a constant level.
func wavLevel(_ secs: Double, _ amp: Float) -> [UInt8] {
    let rate: UInt32 = 8000
    let n = Int((Double(rate) * secs).rounded())
    let sample = Int16(amp * 32767)
    var data: [UInt8] = []
    data.reserveCapacity(n * 2)
    for _ in 0 ..< n { data += [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)] }
    func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    var b = Array("RIFF".utf8) + le32(36 + UInt32(data.count)) + Array("WAVEfmt ".utf8)
    b += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
    b += Array("data".utf8) + le32(UInt32(data.count)) + data
    return b
}

/// Two 1×1 frames (black, then white), 100 ms each.
func twoFrameGIF() -> [UInt8] {
    var b: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF]
    for pixel in [[0x44, 0x01], [0x4C, 0x01]] as [[UInt8]] {
        b += [0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00]
        b += [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0x02, 0x02]
        b += pixel
        b.append(0)
    }
    b.append(0x3B)
    return b
}

@MainActor
@Suite struct ShowMediaTests {
    static func deck(_ shape: UInt32, _ bytes: [UInt8]) -> (Presentation, ShapeId, MediaClip) {
        var doc = Presentation.default
        let media = doc.addMedia("clip.wav", "audio/wav", bytes) ?? MediaId(0)
        let clip = MediaClip(media: media, volume: 1)
        let id = ShapeId(shape)
        var sh = Shape.default
        sh.id = id
        sh.xfrm = Xfrm(0, 0, 120, 40)
        sh.kind = .media(clip)
        doc.slides[0].shapes.append(sh)
        return (doc, id, clip)
    }

    /// The first mixed sample of shape `id`, after its audio has decoded.
    static func level(_ host: MediaHost, _ id: ShapeId) -> Float {
        #expect(host.player.waitLoaded(MediaHost.key(id), timeout: 5), "decode")
        var buf = [Float](repeating: 0, count: 4)
        host.player.render(&buf, channels: 1, rate: 8000)
        return buf[0]
    }

    // media.rs: a_video_crop_shows_only_the_cropped_part_of_the_frame
    @Test func aVideoCropShowsOnlyTheCroppedPartOfTheFrame() {
        #expect(ShowGeometry.cropUV([0, 0, 0, 0]) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(ShowGeometry.cropUV([0.25, 0.5, 0.25, 0]) == CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        #expect(ShowGeometry.cropUV([.nan]) == CGRect(x: 0, y: 0, width: 1, height: 1), "hostile crops read as none")
    }

    // media.rs: playback_follows_the_document_and_the_clip
    @Test func playbackFollowsTheDocumentAndTheClip() {
        let (loudDoc, id, loud) = Self.deck(4000, wavLevel(0.05, 0.5))
        let (quietDoc, _, quiet) = Self.deck(4000, wavLevel(0.10, 0.25))
        let host = MediaHost(nil)
        host.play(1, loudDoc, id, loud, from: nil, owner: .editor)
        var sample = Self.level(host, id)
        #expect(Swift.abs(sample - 0.5) < 0.02, "loud sample \(sample)")
        #expect(Swift.abs((host.status(id)?.duration ?? -1) - 0.05) < 0.01)
        #expect(host.durations[loud.media]?.source == loudDoc.media(loud.media)?.data)
        // Replacing the clip on the same shape plays the new bytes.
        host.play(1, quietDoc, id, quiet, from: nil, owner: .editor)
        sample = Self.level(host, id)
        #expect(Swift.abs(sample - 0.25) < 0.02, "replaced sample \(sample)")
        #expect(Swift.abs((host.status(id)?.duration ?? -1) - 0.10) < 0.01)
        #expect(host.player.keys == [MediaHost.key(id)])
        // Another deck reuses the shape id: leaving the first stops its voice.
        host.setDocument(2)
        #expect(host.status(id) == nil, "the previous document's voice is gone")
        host.play(2, loudDoc, id, loud, from: nil, owner: .editor)
        sample = Self.level(host, id)
        #expect(Swift.abs(sample - 0.5) < 0.02)
        host.setDocument(nil)
        #expect(host.ids.isEmpty, "closing the last document stops playback")
        #expect(host.status(id) == nil)
    }

    // media.rs: gif_clocks_do_not_carry_across_documents
    @Test func gifClocksDoNotCarryAcrossDocuments() {
        func gif(_ shape: UInt32) -> (Presentation, ShapeId) {
            var doc = Presentation.default
            let media = doc.addMedia("a.gif", "image/gif", Array("GIF89a-not-animated".utf8)) ?? MediaId(0)
            var sh = Shape.default
            sh.id = ShapeId(shape)
            sh.xfrm = Xfrm(0, 0, 80, 80)
            var fill = PictureFill.default
            fill.media = media
            sh.kind = .picture(fill: fill)
            doc.slides[0].shapes.append(sh)
            return (doc, sh.id)
        }
        let (a, id) = gif(7)
        let (b, _) = gif(7)
        let host = MediaHost(nil)
        _ = host.gifs(1, a, 0, 10, [])
        #expect(host.gifClocks[id]?.0 == 10)
        _ = host.gifs(1, a, 0, 12, [])
        #expect(host.gifClocks[id]?.0 == 10, "the same document keeps its clock")
        _ = host.gifs(2, b, 0, 50, [])
        #expect(host.gifClocks[id]?.0 == 50, "a new document starts its own clock")
        host.setDocument(nil)
        #expect(host.gifClocks.isEmpty)
    }

    // media.rs: a_clip_is_looked_up_on_the_slide_it_was_asked_from
    @Test func aClipIsLookedUpOnTheSlideItWasAskedFrom() {
        var (doc, id, first) = Self.deck(4000, wavLevel(0.05, 0.5))
        let other = doc.addMedia("two.wav", "audio/wav", wavLevel(0.05, 0.25)) ?? MediaId(0)
        var second = doc.slides[0]
        second.shapes[second.shapes.count - 1].kind = .media(MediaClip(media: other, volume: 1))
        doc.slides.append(second)
        #expect(MediaHost.findClip(doc, id, near: 0)?.media == first.media)
        #expect(MediaHost.findClip(doc, id, near: 1)?.media == other, "the second slide's own clip")
        #expect(MediaHost.findClip(doc, id, near: nil)?.media == first.media, "without a hint: first match")
        #expect(MediaHost.findClip(doc, id, near: 9)?.media == first.media, "a slide that doesn't exist")
    }

    // media.rs: a_clip_across_slides_stops_where_the_next_slide_reuses_its_id
    @Test func aClipAcrossSlidesStopsWhereTheNextSlideReusesItsId() {
        var (doc, id, first) = Self.deck(4000, wavLevel(0.05, 0.5))
        var playing = first
        playing.playAcrossSlides = true
        var plain = doc.slides[0]
        plain.shapes.removeAll()
        doc.slides.append(plain)
        #expect(MediaHost.carriesOver(playing, doc, id, 1), "a slide without that id")
        #expect(MediaHost.carriesOver(playing, doc, id, 0), "the same media under that id")
        #expect(!MediaHost.carriesOver(first, doc, id, 1), "a clip that doesn't play across slides")
        let other = doc.addMedia("two.wav", "audio/wav", wavLevel(0.05, 0.25)) ?? MediaId(0)
        var reused = doc.slides[0]
        var c = first
        c.media = other
        c.autoplay = true
        reused.shapes[reused.shapes.count - 1].kind = .media(c)
        doc.slides.append(reused)
        #expect(!MediaHost.carriesOver(playing, doc, id, 2), "another clip under that id")
        let host = MediaHost(nil)
        host.play(1, doc, id, playing, from: nil, owner: .show)
        #expect(host.clip(id) == playing, "the voice keeps the clip it was started with")
    }

    // media.rs: a_webm_with_an_undecodable_video_codec_still_plays_its_audio (#1237). Without a registered VP8
    // decoder the video opens no feed — the "can't play" state, reported in `Session.mediaStatus` — while the
    // Vorbis audio sounds.
    @Test func aWebmWithAnUndecodableVideoCodecStillPlaysItsAudio() throws {
        let url = Fixtures.repositoryRoot.deletingLastPathComponent().appending(path: "deckcraft/crates/media/tests/fixtures/clip-vp8.webm")
        guard let data = try? Data(contentsOf: url) else { return }
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        let r = try s.execute("insert.video", ["name": "clip.webm", "data": .string(Cmd.base64Encode([UInt8](data)))])
        #expect(r["playable"]?.asBool == true)
        let w = r["warning"]?.asStr ?? ""
        #expect(w.contains("VP8") && w.contains("only the audio plays"), "\(w)")
        let d = try #require(s.activeDoc)
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        guard let clip = MediaHost.findClip(d.doc, id, near: d.selection.slide) else {
            Issue.record("no clip")
            return
        }
        let host = MediaHost(nil)
        host.play(d.uid, d.doc, id, clip, from: nil, owner: .show)
        #expect(host.player.waitLoaded(MediaHost.key(id), timeout: 5), "decode")
        #expect(host.status(id)?.error == nil, "Vorbis decodes")
        var buf = [Float](repeating: 0, count: 22050)
        host.player.render(&buf, channels: 1, rate: 44100)
        let peak = buf.reduce(0) { Swift.max($0, Swift.abs($1)) }
        #expect(peak > 0.04, "the audio track sounds: peak \(peak)")
        #expect(host.videoUnplayable(id), "VP8 opens no video feed")
        host.tickClock(0.1, s)
        host.syncVideoFrames()
        #expect(host.frame(id) == nil, "no VP8 frame exists to show")
        #expect(s.mediaStatus[id]?.error?.contains("can't be played") == true, "the can't-play state is reported")
    }

    // media.rs: grouped_gifs_play_in_slide_space
    @Test func groupedGifsPlayInSlideSpace() throws {
        var doc = Presentation.default
        let media = doc.addMedia("a.gif", "image/gif", twoFrameGIF()) ?? MediaId(0)
        func pic(_ id: UInt32, _ x: Double) -> Shape {
            var sh = Shape.default
            sh.id = ShapeId(id)
            sh.xfrm = Xfrm(x, 0, 10, 10)
            var fill = PictureFill.default
            fill.media = media
            sh.kind = .picture(fill: fill)
            return sh
        }
        var inner = Shape.default
        inner.id = ShapeId(9)
        inner.xfrm = Xfrm(10, 0, 10, 10)
        inner.kind = .group(children: [pic(8, 0)], child: Xfrm(0, 0, 10, 10))
        var group = Shape.default
        group.id = ShapeId(10)
        group.xfrm = Xfrm(100, 50, 40, 20)
        group.kind = .group(children: [pic(7, 0), inner], child: Xfrm(0, 0, 20, 10))
        doc.slides[0].shapes.append(group)
        let host = MediaHost(nil)
        _ = host.gifs(1, doc, 0, 10, [])
        let gifs = Dictionary(uniqueKeysWithValues: host.gifs(1, doc, 0, 10.15, []).map { ($0.id, $0) })
        let a = try #require(gifs[ShapeId(7)], "grouped GIF plays")
        let b = try #require(gifs[ShapeId(8)], "GIF in a nested group plays")
        #expect(a.frame == 1, "the clock runs")
        #expect([a.rect.x, a.rect.y, a.rect.w, a.rect.h] == [100, 50, 20, 20])
        #expect([b.rect.x, b.rect.y, b.rect.w, b.rect.h] == [120, 50, 20, 20])
    }

    /// A running show on a slide with one 10 s clip (`show_with_clip`): the coordinator, the clip and a point on
    /// its bar's timeline.
    static func showWithClip() throws -> (ShowCoordinator, ShapeId, CGPoint) {
        let s = Session.withNew()
        let id = ShapeId(4000)
        try s.edit { doc, _ in
            let media = doc.addMedia("clip.wav", "audio/wav", wavLevel(10, 0)) ?? MediaId(0)
            let (w, h) = (doc.slideSize.width, doc.slideSize.height)
            var sh = Shape.default
            sh.id = id
            sh.xfrm = Xfrm(w * 0.2, h * 0.2, w * 0.6, h * 0.6)
            sh.kind = .media(MediaClip(media: media, video: true, volume: 1, durationMs: 10_000))
            doc.slides[0].shapes.append(sh)
        }
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m, media: MediaHost(nil))
        c.startShow(from: 0, reading: false)
        _ = c.tick(10)
        let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let doc = try #require(c.showState?.doc)
        let bar = try #require(ShowGeometry.slideMediaBars(ShowGeometry.slideRect(full, reading: false, doc), doc, 0).first?.bar)
        return (c, id, CGPoint(x: bar.minX + bar.width * 0.8, y: bar.midY))
    }

    // show.rs: media_controls_hide_when_pointer_is_idle (#967)
    @Test func mediaControlsHideWhenPointerIsIdle() throws {
        let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
        // Awake: the bar is there and a click on its timeline seeks, leaving the clip paused.
        var (c, id, track) = try Self.showWithClip()
        c.show?.lastMove = 10
        #expect(c.pointerOnMediaBar(track, full, 10.5), "the bar is under a pointer that just moved")
        _ = c.click(track, full, 10.5)
        let status = try #require(c.media.status(id), "the click on the bar cued the clip")
        #expect(!c.media.isPlaying(id), "a bar click seeks, it does not play")
        #expect(status.position > 1, "seeked along the timeline, at \(status.position)")
        // Idle: no movement for 3 s; a click where the bar was acts on the clip itself.
        (c, id, track) = try Self.showWithClip()
        c.show?.lastMove = 10
        #expect(!c.pointerOnMediaBar(track, full, 13), "the bar is hidden once the pointer is idle")
        _ = c.click(track, full, 13)
        #expect(c.media.isPlaying(id), "the click reached the clip")
        #expect((c.media.status(id)?.position ?? 0) < 5, "the click did not seek along the timeline")
        #expect(c.show?.state.slide == 0)
    }

    // show.rs: gif_button_click_needs_an_awake_pointer
    @Test func gifButtonClickNeedsAnAwakePointer() throws {
        func showWithGif() throws -> (ShowCoordinator, ShapeId, CGPoint) {
            let s = Session.withNew()
            _ = try s.execute("slide.new", ["layout": "blank"])
            _ = try s.execute("slide.new", ["layout": "blank"])
            _ = try s.execute("slide.go", ["index": 1])
            let id = ShapeId(4100)
            try s.edit { doc, _ in
                let media = doc.addMedia("a.gif", "image/gif", twoFrameGIF()) ?? MediaId(0)
                var sh = Shape.default
                sh.id = id
                sh.xfrm = Xfrm(doc.slideSize.width * 0.2, doc.slideSize.height * 0.2, doc.slideSize.width * 0.6, doc.slideSize.height * 0.6)
                var fill = PictureFill.default
                fill.media = media
                sh.kind = .picture(fill: fill)
                doc.slides[1].shapes.append(sh)
            }
            let m = AppModel(session: s)
            m.ui.presenterView = false
            let c = ShowCoordinator(model: m, media: MediaHost(nil))
            c.startShow(from: 1, reading: false)
            _ = c.tick(10)
            let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let doc = try #require(c.showState?.doc)
            let srect = ShowGeometry.slideRect(full, reading: false, doc)
            let k = srect.width / doc.slideSize.width
            let rect = try #require(doc.slides[1].shapes.last?.xfrm)
            let b = ShowGeometry.gifButtonRect(ShowGeometry.onScreen(srect, k, rect))
            return (c, id, CGPoint(x: b.midX, y: b.midY))
        }
        let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var (c, id, button) = try showWithGif()
        c.show?.lastMove = 10
        _ = c.click(button, full, 10.5)
        #expect(c.model.session.gifPaused.contains(id), "an awake pointer's click pauses the GIF")
        #expect(c.show?.state.slide == 1)
        (c, id, button) = try showWithGif()
        c.show?.lastMove = 10
        _ = c.click(button, full, 13.5)
        #expect(!c.model.session.gifPaused.contains(id), "the hidden button is not clickable")
        #expect(c.show?.state.slide == 2, "the click advanced the show")
    }

    /// Auto-play media starts when its slide appears and stops when the show leaves the slide; a transition
    /// sound plays as its slide appears (`show_media`).
    @Test func autoPlayMediaAndTransitionSounds() throws {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        let id = ShapeId(4200)
        try s.edit { doc, _ in
            let media = doc.addMedia("clip.wav", "audio/wav", wavLevel(10, 0)) ?? MediaId(0)
            var sh = Shape.default
            sh.id = id
            sh.xfrm = Xfrm(10, 10, 100, 40)
            sh.kind = .media(MediaClip(media: media, volume: 1, autoplay: true, durationMs: 10_000))
            doc.slides[0].shapes.append(sh)
            var t = Transition(kind: "fade", option: "", durationMs: 500, advanceOnClick: true, soundLoop: false, stopSound: false)
            t.sound = media
            doc.slides[1].transition = t
        }
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m, media: MediaHost(nil))
        c.startShow(from: 0, reading: false)
        _ = c.tick(10)
        #expect(c.media.isPlaying(id), "auto-play starts with its slide")
        _ = c.key(.arrowRight, ShowMods(), presenter: false, now: 11)
        #expect(!c.media.isPlaying(id) && c.media.status(id) == nil, "it stops when the show leaves the slide")
        #expect(c.media.isPlaying(ShowCoordinator.transitionSound), "the slide's transition sound plays")
        c.endShow()
        #expect(c.media.ids.isEmpty, "everything the show started stops at the end")
    }

    /// The engine's `media.*` requests reach the host: from the editor they are the editor's; leaving the slide
    /// stops them (`tick_media_clock`), and `Session.mediaStatus` reports playback.
    @Test func mediaRequestsFromTheEditor() throws {
        let s = Session.withNew()
        let id = ShapeId(4300)
        try s.edit { doc, _ in
            let media = doc.addMedia("clip.wav", "audio/wav", wavLevel(2, 0)) ?? MediaId(0)
            var sh = Shape.default
            sh.id = id
            sh.xfrm = Xfrm(10, 10, 100, 40)
            sh.kind = .media(MediaClip(media: media, volume: 1, durationMs: 2000))
            doc.slides[0].shapes.append(sh)
        }
        let m = AppModel(session: s)
        let c = ShowCoordinator(model: m, media: MediaHost(nil))
        #expect(c.request(.media(action: "play", shape: id, ms: nil)))
        #expect(c.media.owner(id) == .editor)
        c.tickMedia(100)
        #expect(s.mediaStatus[id]?.state == "playing" || s.mediaStatus[id]?.state == "loading")
        _ = try s.execute("slide.new", .emptyObject)
        c.tickMedia(100.1)
        #expect(c.media.status(id) == nil, "leaving the slide stops the editor's media")
    }
}
