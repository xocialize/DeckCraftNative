// DCEngineTests — the media, compress, reuse and zoom modules: deckcraft crates/engine/src/cmd/media.rs,
// compress.rs and reuse.rs's tests, and the engine tests deferred from DCPPTXTests (deckcraft
// crates/pptx/tests/it/roundtrip.rs: `reuse_slides_from_another_presentation`,
// `compress_pictures_shrinks_the_file_and_keeps_shared_originals`, `zoom_inserts_linked_slide_pictures`).
import CoreGraphics
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import DCTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// An RGB picture from `f` as a PNG (`image::RgbImage::from_fn(w, h, f)` written as PNG).
func insertPNG(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0 ..< h {
        for x in 0 ..< w {
            let (r, g, b) = f(x, y)
            let i = (y * w + x) * 4
            px[i] = r
            px[i + 1] = g
            px[i + 2] = b
        }
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)
    else { return [] }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return [] }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return [] }
    return [UInt8](data as Data)
}

/// An RGB picture from `f` as a PNG whose pixel data is stored, not deflated (an encoder that trades size for
/// speed, as the `image` crate's PNGs are bigger than ImageIO's).
func insertStoredPNG(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var raw: [UInt8] = []
    for y in 0 ..< h {
        raw.append(0)
        for x in 0 ..< w {
            let (r, g, b) = f(x, y)
            raw += [r, g, b]
        }
    }
    func be(_ v: UInt32) -> [UInt8] { (0 ..< 4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0 ..< 8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
    var z: [UInt8] = [0x78, 0x01]
    var i = 0
    repeat {
        let n = min(65535, raw.count - i)
        let last: UInt8 = i + n >= raw.count ? 1 : 0
        z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
        z += raw[i ..< i + n]
        i += n
    } while i < raw.count
    var a: UInt32 = 1, b: UInt32 = 0
    for v in raw {
        a = (a + UInt32(v)) % 65521
        b = (b + a) % 65521
    }
    z += be(b << 16 | a)
    func chunk(_ out: inout [UInt8], _ kind: String, _ data: [UInt8]) {
        let body = Array(kind.utf8) + data
        out += be(UInt32(data.count)) + body + be(crc(body))
    }
    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    chunk(&out, "IHDR", be(UInt32(w)) + be(UInt32(h)) + [8, 2, 0, 0, 0])
    chunk(&out, "IDAT", z)
    chunk(&out, "IEND", [])
    return out
}

/// A picture's pixel size.
func insertImageSize(_ bytes: [UInt8]) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (img.width, img.height)
}

private func b64(_ d: [UInt8]) -> String { Cmd.base64Encode(d) }

/// media.rs `wav()`: half a second of a 8 kHz mono 16-bit tone.
private func wav() -> [UInt8] {
    let rate: UInt32 = 8000
    let samples: [Int16] = (0 ..< Int(rate / 2)).map { i in Int16(rustCast: Float(sin(Float(i) * 0.3) * 3000.0)) }
    var data: [UInt8] = []
    for s in samples { data += [UInt8(truncatingIfNeeded: s), UInt8(truncatingIfNeeded: s >> 8)] }
    func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    var b = Array("RIFF".utf8) + le32(36 + UInt32(data.count)) + Array("WAVEfmt ".utf8)
    b += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
    b += Array("data".utf8) + le32(UInt32(data.count)) + data
    return b
}

private func fixtureMedia(_ name: String) -> [UInt8]? {
    try? [UInt8](Data(contentsOf: Fixtures.root.appending(path: "media/inputs/\(name)")))
}

@Suite("Insert: media")
struct InsertMediaTests {
    // media.rs::insert_audio_probes_and_play_requests_reach_the_host
    @Test func insertAudioProbesAndPlayRequestsReachTheHost() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let r = s.run("insert.audio", #"{"name": "tone.wav", "data": "\#(b64(wav()))"}"#)
        #expect(r.get("durationMs") == 500)
        #expect(r.get("playable") == true)
        let id = try #require(r.get("id")?.asU32)
        s.uiRequests.removeAll()
        s.run("media.play", #"{"from": 100}"#)
        #expect(s.uiRequests == [.media(action: "play", shape: ShapeId(id), ms: 100)])
        s.run("media.seek", #"{"id": \#(id), "ms": 250}"#)
        #expect(s.fails("media.seek", #"{"id": \#(id)}"#))
        // The host reports state; media.info returns it with the probe.
        var st = MediaStatus()
        st.state = "playing"
        st.positionMs = 250
        st.durationMs = 500
        s.mediaStatus[ShapeId(id)] = st
        let i = s.run("media.info")
        #expect(i.get("probe")?.get("audio")?.get("sampleRate") == 8000)
        #expect(i.get("probe")?.get("container") == "wav")
        #expect(i.get("status")?.get("positionMs") == 250)
        #expect(i.get("status")?.get("state") == "playing")
        #expect(s.fails("media.posterFrame"), "audio has no poster frame")
    }

    // media.rs::a_video_reopened_from_pptx_keeps_its_length_and_size (on the generated H.264 + AAC movie of
    // DeckCraftNative-Fixtures/media/inputs, in place of upstream's clip-h264.mp4)
    @Test(.enabled(if: fixtureMedia("av-h264-aac.mp4") != nil, "no media fixtures"))
    func aVideoReopenedFromPptxKeepsItsLengthAndSize() throws {
        let clip = try #require(fixtureMedia("av-h264-aac.mp4"))
        let s = session()
        s.run("insert.video", #"{"name": "clip.mp4", "data": "\#(b64(clip))"}"#)
        let before = s.run("media.info")
        #expect((before.get("durationMs")?.asU64 ?? 0) > 0)
        #expect(s.st.selectedShapes.first.map { sh in if case .media(let m) = sh.kind { return m.poster != nil }; return false } == true, "a poster frame")
        let saved = s.run("file.saveBytes", #"{"format": "pptx"}"#)
        _ = try s.execute("file.openBytes", .object(JSONObject(["name": "deck.pptx", "data": saved.get("data") ?? .null])))
        let after = s.run("media.info")
        for key in ["durationMs", "width", "height"] {
            #expect(after.get(key) == before.get(key), "\(key)")
        }
    }

    // media.rs::media_commands_need_media
    @Test func mediaCommandsNeedMedia() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.fails("media.play"))
        let sh = s.run("shape.insert", #"{"preset": "rect", "rect": [0, 0, 10, 10]}"#)
        #expect(s.fails("media.play", #"{"id": \#(sh.get("id")?.display ?? "0")}"#))
    }

    // media.rs::gif_play_pauses_and_resumes_an_animated_gif
    @Test func gifPlayPausesAndResumesAnAnimatedGif() throws {
        func frame(_ c: [UInt8]) -> [UInt8] { Array([[UInt8]](repeating: c, count: 64).joined()) }
        let gif = try #require(ImageEncoding.gif([frame([255, 0, 0, 255]), frame([0, 0, 255, 255])], width: 8, height: 8, delayCs: 10, loop: true))
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.fails("media.gifPlay"), "no GIF yet")
        let id = try #require(s.run("insert.picture", #"{"name": "a.gif", "data": "\#(b64(gif))"}"#).get("id")?.asU32)
        let r = s.run("media.gifPlay")
        #expect(r.get("playing") == false)
        #expect(s.gifPaused.contains(ShapeId(id)))
        let r2 = s.run("media.gifPlay", #"{"id": \#(id), "play": true}"#)
        #expect(r2.get("playing") == true)
        #expect(s.gifPaused.isEmpty)
        let sh = s.run("shape.insert", #"{"preset": "rect", "rect": [0, 0, 10, 10]}"#)
        #expect(s.fails("media.gifPlay", #"{"id": \#(sh.get("id")?.display ?? "0")}"#))
    }

    // media.rs::wma_inserts_but_reports_unplayable
    @Test func wmaInsertsButReportsUnplayable() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        // A minimal ASF header object with no children.
        var asf: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
        asf += (0 ..< 8).map { UInt8(truncatingIfNeeded: UInt64(30) >> (8 * $0)) }
        asf += [0, 0, 0, 0, 0, 0]
        let r = s.run("insert.audio", #"{"name": "song.wma", "data": "\#(b64(asf))"}"#)
        #expect(r.get("playable") == false)
        #expect(r.get("warning")?.asStr?.contains("can't be played") == true, "\(r.display)")
    }

    // media.rs::a_vp8_webm_is_playable_and_warns_that_only_the_audio_plays
    @Test(.disabled("needs upstream's CC0 clip-vp8.webm, which DeckCraftNative-Fixtures doesn't carry; VP8 can't be generated here"))
    func aVp8WebmIsPlayableAndWarnsThatOnlyTheAudioPlays() {}

    /// New: a Matroska video is inserted at its natural size (96 dpi), with its probe.
    @Test(.enabled(if: fixtureMedia("mkv-h264.mkv") != nil, "no media fixtures")) func videoWithoutAudioIsInsertedAtItsSize() throws {
        let clip = try #require(fixtureMedia("mkv-h264.mkv"))
        let s = session()
        let r = s.run("insert.video", #"{"name": "clip.mkv", "data": "\#(b64(clip))"}"#)
        #expect(r.get("contentType") == "video/x-matroska")
        #expect(r.get("probe")?.get("video")?.get("codec") != nil)
        let box = try #require(s.st.selectedShapes.first?.xfrm)
        #expect(abs(box.w - Double(r.get("width")?.asU64 ?? 0) * 0.75) < 1e-9)
    }
}

@Suite("Insert: Compress Pictures")
struct InsertCompressTests {
    private func png(_ w: Int, _ h: Int) -> [UInt8] {
        insertStoredPNG(w, h) { x, y in (UInt8(truncatingIfNeeded: x * 7 % 256), UInt8(truncatingIfNeeded: y * 5 % 256), UInt8(truncatingIfNeeded: (x ^ y) % 256)) }
    }

    // compress.rs::pack_downsamples_to_the_shown_size
    @Test func packDownsamplesToTheShownSize() throws {
        // 2000 px shown at 1 inch: 150 ppi needs 150 px.
        let pk = try #require(CompressCommands.pack(png(2000, 1000), [0, 0, 0, 0], 72.0, 36.0, 150.0, true))
        #expect(insertImageSize(pk.bytes).map { [$0.0, $0.1] } == [150, 75])
        #expect(pk.contentType == "image/png")
        // Already small enough: nothing to do.
        #expect(CompressCommands.pack(png(100, 50), [0, 0, 0, 0], 72.0, 36.0, 150.0, true)?.bytes == nil)
        // Not a raster we re-encode.
        #expect(CompressCommands.pack(Array("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), [0, 0, 0, 0], 72.0, 72.0, 150.0, true)?.bytes == nil)
    }

    // compress.rs::pack_deletes_cropped_areas_or_keeps_them
    @Test func packDeletesCroppedAreasOrKeepsThem() throws {
        let src = png(400, 400)
        // Left half cropped away, shown 2 in wide at 100 ppi → 200 px of the visible half.
        let pk = try #require(CompressCommands.pack(src, [0.5, 0, 0, 0], 144.0, 288.0, 100.0, true))
        #expect(pk.crop == [0, 0, 0, 0])
        #expect(insertImageSize(pk.bytes).map { [$0.0, $0.1] } == [200, 400])
        // Keeping the crop: the whole image stays, scaled so the visible half has its pixels.
        let kept = try #require(CompressCommands.pack(src, [0.5, 0, 0, 0], 72.0, 72.0, 100.0, false))
        #expect(kept.crop == [0.5, 0, 0, 0])
        #expect(insertImageSize(kept.bytes)?.0 == 200)
    }

    /// A PNG whose header claims `w` × `h` (no pixel data): enough for the size check.
    private func pngHeader(_ w: UInt32, _ h: UInt32) -> [UInt8] {
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                c ^= UInt32(b)
                for _ in 0 ..< 8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        func be(_ v: UInt32) -> [UInt8] { (0 ..< 4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func chunk(_ out: inout [UInt8], _ kind: String, _ data: [UInt8]) {
            let body = Array(kind.utf8) + data
            out += be(UInt32(data.count)) + body + be(crc(body))
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        chunk(&out, "IHDR", be(w) + be(h) + [8, 2, 0, 0, 0])
        chunk(&out, "IDAT", [])
        chunk(&out, "IEND", [])
        return out
    }

    // compress.rs::huge_pictures_are_not_decoded
    @Test func hugePicturesAreNotDecoded() throws {
        // 72 MP: over the cap (ImageIO reads no size from it at all, which refuses it as well).
        let data = pngHeader(9_000, 8_000)
        #expect(CompressCommands.decode(data) == nil)
        #expect(CompressCommands.pack(data, [0, 0, 0, 0], 72.0, 72.0, 96.0, true)?.bytes == nil)
    }

    // compress.rs::media_still_used_as_an_artistic_original_is_kept
    @Test func mediaStillUsedAsAnArtisticOriginalIsKept() throws {
        let s = session()
        let big = png(1200, 600)
        let processed = png(1100, 600)
        try s.edit { doc, _ in
            guard let original = doc.addMedia("original.png", "image/png", big), let shown = doc.addMedia("processed.png", "image/png", processed) else {
                throw Cmd.bad("test", "media")
            }
            let xfrm = Xfrm(0.0, 0.0, 72.0, 36.0)
            var a = Shape.default
            a.id = ShapeId(70_001)
            a.xfrm = xfrm
            a.kind = .picture(fill: PictureFill(media: shown, artistic: Artistic(effect: "artisticBlur", original: original)))
            var b = Shape.default
            b.id = ShapeId(70_002)
            b.xfrm = xfrm
            b.kind = .picture(fill: PictureFill(media: original))
            doc.slides[0].shapes += [a, b]
        }
        let r = s.run("picture.compress", #"{"all": true, "ppi": 96}"#)
        #expect(r.get("pictures") == 2, "\(r.display)")
        let doc = s.st.doc
        // Every reference left in the deck resolves to media that is still there.
        for id in MediaRefs.presentationMedia(doc) { #expect(doc.media(id) != nil, "\(id) was deleted while still referenced") }
        #expect(doc.media.contains { $0.data == big }, "the artistic original was deleted")
        #expect(!doc.media.contains { $0.data == processed }, "the replaced processed picture is dropped")
    }

    /// Picture Format › Compress Pictures: a big picture shown small is downsampled, its original goes when
    /// nothing else uses it, the saved file shrinks, a copy that wasn't compressed keeps the original, and undo
    /// brings everything back.
    // Rust: pptx it/roundtrip.rs::compress_pictures_shrinks_the_file_and_keeps_shared_originals (from DCPPTXTests)
    @Test(.enabled(if: ported("shape.resize", "edit.duplicate"))) func compressPicturesShrinksTheFileAndKeepsSharedOriginals() throws {
        // A noisy 1600 × 1600 picture (doesn't compress away on its own).
        let big = insertStoredPNG(1600, 1600) { x, y in
            (UInt8(truncatingIfNeeded: x * 31 % 251), UInt8(truncatingIfNeeded: y * 17 % 253), UInt8(truncatingIfNeeded: (x * y) % 255))
        }
        let s = session()
        s.run("insert.picture", #"{"data": "\#(b64(big))", "name": "noise.png"}"#)
        s.run("shape.resize", #"{"w": 144, "h": 144}"#)
        let sizeBefore = try PPTX.export(s.st.doc).count
        let r = s.run("picture.compress", #"{"ppi": 150}"#)
        #expect(r.get("pictures") == 1, "\(r.display)")
        var doc = s.st.doc
        #expect(doc.media.count == 1, "the original is gone")
        let size = try #require(doc.media.first.flatMap { insertImageSize($0.data) })
        #expect(size.0 == 300 && size.1 == 300, "2 in at 150 ppi")
        let sizeAfter = try PPTX.export(doc).count
        #expect(sizeAfter * 4 < sizeBefore, "\(sizeBefore) → \(sizeAfter)")
        s.run("edit.undo")
        #expect(s.st.doc.media.first?.data.count == big.count, "undo restores the original")

        // A duplicate that isn't compressed still needs the original.
        s.run("edit.duplicate")
        let copy = s.st.selection.shapes
        let first = try #require(s.st.doc.slides[0].shapes.map(\.id).filter { !copy.contains($0) }.last)
        s.run("picture.compress", #"{"ppi": 150, "ids": [\#(first.rawValue)]}"#)
        doc = s.st.doc
        #expect(doc.media.count == 2)
        #expect(doc.media.contains { $0.data.count == big.count }, "the copy keeps the original")
        // All pictures: the copy gets compressed too, and the original goes.
        s.run("picture.compress", #"{"ppi": 150, "all": true}"#)
        doc = s.st.doc
        #expect(doc.media.allSatisfy { $0.data.count < big.count / 4 })
        #expect(s.fails("picture.compress", #"{"ppi": 5, "all": true}"#))
    }
}

@Suite("Insert: Reuse Slides")
struct InsertReuseTests {
    private func link(_ slide: SlideId) -> Hyperlink {
        Hyperlink(action: .slide(slide: slide), tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
    }

    // reuse.rs::reused_slides_bring_every_media_reference
    @Test func reusedSlidesBringEveryMediaReference() throws {
        var src = newPresentation(nil)
        let blobs: [[UInt8]] = (0 ..< 8).map { i in [0xD0, UInt8(i), UInt8(i), UInt8(i)] }
        let ids: [MediaId] = blobs.enumerated().compactMap { i, b in src.addMedia("m\(i).bin", "application/octet-stream", b) }
        try #require(ids.count == 8)
        var text = TextBody.fromText("bullet")
        text.paragraphs[0].props.bullet = .picture(media: ids[6])
        var a = Shape.default
        a.id = ShapeId(9001)
        a.kind = .picture(fill: PictureFill(media: ids[0], artistic: Artistic(effect: "artisticBlur", original: ids[1])))
        var b = Shape.default
        b.id = ShapeId(9002)
        b.kind = .media(MediaClip(media: ids[2], poster: ids[3]))
        var c = Shape.default
        c.id = ShapeId(9003)
        c.click = Hyperlink(action: .nextSlide, tooltip: "", highlightClick: false, sound: ids[5], stopSound: false, zoomReturn: nil)
        c.text = text
        src.slides[0].shapes = [a, b, c]
        src.slides[0].background = .fill(fill: .picture(PictureFill(media: ids[4])))
        var t = Transition.default
        t.sound = ids[7]
        src.slides[0].transition = t
        let bytes = try DeckFormat.save(src)

        let s = session()
        let own: [UInt8] = [1, 2, 3]
        let ownId = try s.edit { doc, _ in doc.addMedia("own.bin", "application/octet-stream", own) }
        s.run("slide.reuse", #"{"data": "\#(b64(bytes))", "name": "src.deckcraft", "slides": [0]}"#)
        let doc = s.st.doc
        #expect(ownId.flatMap { doc.media($0)?.data } == own, "own media untouched")
        let reused = try #require(doc.slides.at(1))
        let got = MediaRefs.slideMedia(reused).map { doc.media($0)?.data ?? [] }.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(got == blobs.sorted { $0.lexicographicallyPrecedes($1) }, "every reference resolves to its own copied bytes")
    }

    // reuse.rs::reused_slides_link_to_each_others_copies
    @Test func reusedSlidesLinkToEachOthersCopies() throws {
        var src = newPresentation(nil)
        let template = src.slides[0]
        for _ in 0 ..< 2 {
            var sl = template
            let raw = src.allocId()
            sl.id = SlideId(try #require(raw))
            src.slides.append(sl)
        }
        let ids = src.slides.map(\.id)
        var linked = TextBody.fromText("go")
        linked.paragraphs[0].runs[0].props.link = link(ids[1])
        func shape(_ id: UInt32, click: Hyperlink? = nil, text: TextBody? = nil) -> Shape {
            var sh = Shape.default
            sh.id = ShapeId(id)
            sh.click = click
            sh.text = text
            return sh
        }
        src.slides[0].shapes = [shape(9001, click: link(ids[1])), shape(9002, text: linked), shape(9003, click: link(ids[2]))]
        src.slides[1].shapes = [shape(9004, click: link(ids[0]))]
        let bytes = try DeckFormat.save(src)
        let reopened = try FileCommands.openPresentation("src.deckcraft", bytes)
        let leftBehind = try #require(reopened.slides.at(2)?.id)

        let s = session()
        for _ in 0 ..< 3 { s.run("slide.new") }
        let out = s.run("slide.reuse", #"{"data": "\#(b64(bytes))", "name": "src.deckcraft", "slides": [0, 1]}"#)
        let new = (out.get("ids")?.asArray ?? []).compactMap(\.asU32).map(SlideId.init)
        let doc = s.st.doc
        let first = try #require(new.first.flatMap { doc.slide($0) })
        let second = try #require(new.at(1).flatMap { doc.slide($0) })
        #expect(first.shapes.first?.click?.action == .slide(slide: new[1]), "shape click follows the copy")
        #expect(first.shapes.at(1)?.text?.paragraphs.first?.runs.first?.props.link?.action == .slide(slide: new[1]), "text link follows the copy")
        #expect(first.shapes.at(2)?.click?.action == .slide(slide: leftBehind), "a slide not reused keeps its link")
        #expect(second.shapes.first?.click?.action == .slide(slide: new[0]), "a link back to an earlier copy follows too")
    }

    // reuse.rs::reuse_list_names_the_slides_and_the_picked_ones_come_in
    @Test(.enabled(if: ported("slide.hide"))) func reuseListNamesTheSlidesAndThePickedOnesComeIn() throws {
        let src = session()
        for t in ["Alpha", "Beta", "Gamma"] { src.run("slide.new", #"{"layout": "titleAndContent", "title": "\#(t)"}"#) }
        src.run("slide.hide", #"{"index": \#(src.st.doc.slides.count - 1)}"#)
        let data = b64(try FileCommands.saveBytes(src.st.doc, "deckcraft"))

        let s = session()
        let listed = s.run("slide.reuseList", #"{"data": "\#(data)", "name": "src.deckcraft"}"#)
        let slides = listed.get("slides")?.asArray ?? []
        func title(_ i: Int) -> String { slides.first { $0.get("index")?.asU64 == UInt64(i) }?.get("title")?.asStr ?? "" }
        #expect(slides.count >= 3)
        #expect([title(slides.count - 3), title(slides.count - 2), title(slides.count - 1)] == ["Alpha", "Beta", "Gamma"])
        #expect(slides.last?.get("hidden") == true)
        #expect(s.st.doc.slides.count == 1, "listing changes nothing")

        let last = slides.count - 1
        s.run("slide.reuse", #"{"data": "\#(data)", "name": "src.deckcraft", "slides": [\#(last - 2), \#(last)]}"#)
        let titles = s.st.doc.slides.map(\.title)
        #expect(titles.contains("Alpha") && titles.contains("Gamma"))
        #expect(!titles.contains("Beta"), "a slide that was not picked stays out")
    }

    /// Home › New Slide › Reuse Slides: slides from another .pptx land after the current slide with their
    /// pictures (fresh media ids, same bytes) and animations on the renumbered shapes. By default they take a
    /// destination layout; Keep Source Formatting brings the source master.
    // Rust: pptx it/roundtrip.rs::reuse_slides_from_another_presentation (from DCPPTXTests)
    @Test(.enabled(if: ported("animation.add"))) func reuseSlidesFromAnotherPresentation() throws {
        let pic = insertPNG(8, 8) { _, _ in (10, 200, 30) }
        let red = insertPNG(4, 4) { _, _ in (200, 0, 0) }
        // Source: three slides, a picture with an animation on the second.
        let src = session()
        src.run("slide.new")
        src.run("insert.picture", #"{"data": "\#(b64(pic))", "name": "green.png"}"#)
        src.run("animation.add", #"{"effect": "fade"}"#)
        src.run("slide.new")
        let srcBytes = try PPTX.export(src.st.doc)

        let s = session()
        // Media ids in the two decks overlap; the destination's own picture must stay its own.
        s.run("insert.picture", #"{"data": "\#(b64(red))", "name": "red.png"}"#)
        var r = s.run("slide.reuse", #"{"data": "\#(b64(srcBytes))", "name": "src.pptx", "slides": [1]}"#)
        #expect(r.get("slides") == 1, "\(r.display)")
        var doc = s.st.doc
        #expect(doc.slides.count == 2)
        #expect(s.st.selection.slide == 1, "the reused slide is selected")
        func pictures(_ sl: Slide) -> [MediaId] {
            var v: [MediaId] = []
            walk(sl.shapes) { sh, _ in if case .picture(let fill) = sh.kind { v.append(fill.media) } }
            return v
        }
        #expect(pictures(doc.slides[0]).first.flatMap { doc.media($0)?.data } == red, "own picture untouched")
        #expect(pictures(doc.slides[1]).first.flatMap { doc.media($0)?.data } == pic, "reused picture copied")
        let anim = try #require(doc.slides[1].animations.first)
        #expect(doc.slides[1].shapes.contains { $0.id == anim.shape }, "animation follows its shape")
        #expect(doc.layout(doc.slides[1].layout) != nil, "uses a destination layout")
        #expect(doc.masters.count == 1)
        // The result saves and reopens.
        #expect(try PPTX.import(PPTX.export(doc)).slides.count == 2)

        // Keep Source Formatting: every slide, and the source master comes along.
        r = s.run("slide.reuse", #"{"data": "\#(b64(srcBytes))", "name": "src.pptx", "keepFormatting": true, "at": 0}"#)
        #expect(r.get("slides") == 3)
        doc = s.st.doc
        #expect(doc.slides.count == 5)
        #expect(doc.masters.count == 2)
        for sl in doc.slides.prefix(3) {
            #expect(doc.layout(sl.layout)?.master.id == doc.masters.at(1)?.id, "source master")
        }
        // One undo removes the whole reuse.
        s.run("edit.undo")
        #expect(s.st.doc.slides.count == 2)
        #expect(s.fails("slide.reuse", #"{"data": "\#(b64(srcBytes))", "name": "src.pptx", "slides": [7]}"#))
        #expect(s.fails("slide.reuse", #"{"data": "\#(b64([0, 159, 146, 150]))", "name": "x.bin"}"#))
    }
}

@Suite("Insert: Zoom")
struct InsertZoomTests {
    /// Insert › Zoom: slide, section and summary zooms are linked pictures of their targets, with Return to
    /// Zoom on section and summary zooms; a summary zoom makes its own slide; all of it is one undo step and
    /// saves as linked pictures.
    // Rust: pptx it/roundtrip.rs::zoom_inserts_linked_slide_pictures (from DCPPTXTests)
    @Test(.enabled(if: ported("section.add"))) func zoomInsertsLinkedSlidePictures() throws {
        let s = session()
        for t in ["Intro", "Plan", "Budget", "Risks"] { s.run("slide.new", #"{"title": "\#(t)"}"#) }
        // Slides: 0 title, 1 Intro, 2 Plan, 3 Budget, 4 Risks.
        s.run("slide.go", #"{"index": 0}"#)
        let r = s.run("insert.zoom", #"{"slides": [2]}"#)
        #expect(r.get("returnToZoom") == false)
        var doc = s.st.doc
        let zoom = try #require(doc.slides[0].shapes.first { $0.name.hasPrefix("Slide Zoom") }, "slide zoom")
        let link = try #require(zoom.click)
        #expect(link.action == .slide(slide: doc.slides[2].id))
        #expect(link.zoomReturn == nil)
        #expect(link.tooltip == "Plan")
        guard case .picture(let fill) = zoom.kind else {
            Issue.record("not a picture")
            return
        }
        #expect(doc.media(fill.media)?.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        // Section zoom: back after the section's last slide.
        s.run("section.add", #"{"name": "Start", "at": 0}"#)
        s.run("section.add", #"{"name": "Money", "at": 3}"#)
        doc = s.st.doc
        let money = try #require(doc.sections.firstIndex { $0.name == "Money" })
        s.run("slide.go", #"{"index": 0}"#)
        s.run("insert.zoom", #"{"kind": "section", "sections": [\#(money)]}"#)
        doc = s.st.doc
        let sec = try #require(doc.slides[0].shapes.first { $0.name.hasPrefix("Section Zoom") })
        #expect(sec.click?.zoomReturn == doc.sections[money].slides.last)

        // Summary zoom on slides 1 and 3: a new slide in front, parts 1–2 and 3–4.
        let before = doc.slides.count
        s.run("insert.zoom", #"{"kind": "summary", "slides": [1, 3]}"#)
        doc = s.st.doc
        #expect(doc.slides.count == before + 1)
        let sum = doc.slides[1]
        #expect(sum.title.contains("Summary"))
        let tiles = sum.shapes.compactMap(\.click)
        #expect(tiles.count == 2)
        #expect(tiles.first?.zoomReturn == doc.slides[3].id, "part one runs to the slide before part two")
        #expect(tiles.last?.zoomReturn == doc.slides.last?.id)
        s.run("edit.undo")
        #expect(s.st.doc.slides.count == before, "one undo step")

        // Saved as linked pictures.
        let back = try PPTX.import(PPTX.export(s.st.doc))
        let z = try #require(back.slides[0].shapes.first { sh in if case .picture = sh.kind { return sh.click != nil }; return false })
        if case .slide? = z.click?.action {} else { Issue.record("not a slide link") }
        #expect(s.fails("insert.zoom", #"{"slides": [42]}"#))
        #expect(s.fails("insert.zoom", #"{"kind": "slide"}"#))
    }

    /// New: tiles are laid out in a centred grid of the slide's aspect, a single slide zoom a quarter of the
    /// slide wide (zoom.rs `grid`).
    @Test func gridLaysTilesOutCentred() {
        let one = ZoomCommands.grid(1, Xfrm(480, 270, 432, 243), 16.0 / 9.0)
        #expect(one.count == 1 && one[0].w <= 216.0001)
        let five = ZoomCommands.grid(5, Xfrm(0, 0, 900, 500), 16.0 / 9.0)
        #expect(five.count == 5)
        #expect(Set(five.map(\.w)).count == 1, "equal tiles")
        #expect(five.allSatisfy { $0.x >= -1e-9 && $0.x + $0.w <= 900.0001 && $0.y >= -1e-9 && $0.y + $0.h <= 500.0001 })
    }
}
