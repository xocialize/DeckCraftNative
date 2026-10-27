// Port of deckcraft crates/pptx/tests/it/corpus_media.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned corpus: SmartArt and OLE kept as XML, audio and video bookmarks and trims, a section with a
// hidden slide, slide-number and date fields, ink, 3-D models, and animation repeat, bounce and triggers.
//
// Relationship-bearing SmartArt and OLE parts stay with issue #203. Media playback options stay with
// #74. Animation rewind (`cTn fill="remove"`) stays with #77. This file does not assert those.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

private func png(_ rgb: (UInt8, UInt8, UInt8)) -> [UInt8] { IT.png(4, 4, rgb) }

private func glb(_ marker: UInt8) -> [UInt8] {
    Array("glTF".utf8) + [0x02, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x00, 0x00, marker]
}

private func field(_ text: String, _ kind: String) -> TextBody {
    var body = TextBody.fromText("")
    body.paragraphs[0].runs = [Run(text: text, props: .default, kind: .field(field: kind))]
    return body
}

private let smartart = #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr name="Diagram"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="3657600" cy="1828800"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:relIds xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram"/><dgm:pt xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:t>Quarter</dgm:t></dgm:pt></a:graphicData></a:graphic></p:graphicFrame>"#

private let ole = #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr name="Embedded"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="3810000" y="0"/><a:ext cx="1828800" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/presentationml/2006/ole"><p:oleObj name="Note" progId="DeckCraft.Note.1"><p:embed/></p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"#

private func corpus() throws -> (Presentation, [UInt8], [UInt8], [UInt8]) {
    var p = newPresentation(nil)
    let audioBytes = Array("audio-bytes-deckcraft".utf8)
    let videoBytes = Array("video-bytes-deckcraft".utf8)
    let block = glb(1)
    let globe = glb(2)
    let poster = png((20, 80, 160))
    let audioOpt = p.addMedia("clip.m4a", "audio/mp4", audioBytes)
    let audio = try #require(audioOpt, "media")
    let videoOpt = p.addMedia("clip.mp4", "video/mp4", videoBytes)
    let video = try #require(videoOpt, "media")
    let blockIdOpt = p.addMedia("block.glb", "model/gltf-binary", block)
    let blockId = try #require(blockIdOpt, "media")
    let globeIdOpt = p.addMedia("globe.glb", "model/gltf-binary", globe)
    let globeId = try #require(globeIdOpt, "media")
    let posterIdOpt = p.addMedia("globe-poster.png", "image/png", poster)
    let posterId = try #require(posterIdOpt, "media")

    var objects = IT.newSlide(&p, "Objects")
    var diagram = IT.shape(&p, "Diagram", 40.0, 80.0, 288.0, 144.0)
    diagram.kind = .opaque(xml: smartart, preview: nil, label: "SmartArt", parts: [])
    var embedded = IT.shape(&p, "Embedded", 340.0, 80.0, 144.0, 72.0)
    embedded.kind = .opaque(xml: ole, preview: nil, label: "DeckCraft.Note.1", parts: [])
    var blockShape = IT.shape(&p, "Block", 40.0, 240.0, 120.0, 90.0)
    blockShape.kind = .model3d(media: blockId, poster: nil)
    var globeShape = IT.shape(&p, "Globe", 180.0, 240.0, 160.0, 120.0)
    globeShape.kind = .model3d(media: globeId, poster: posterId)
    var number = IT.shape(&p, "Slide number", 360.0, 240.0, 80.0, 28.0)
    number.text = field("4", "slidenum")
    var date = IT.shape(&p, "Date", 360.0, 276.0, 160.0, 28.0)
    date.text = field("14 October 2026", "datetime4")
    objects.shapes += [diagram, embedded, blockShape, globeShape, number, date]
    p.slides.append(objects)

    var media = IT.newSlide(&p, "Media")
    var clip = IT.shape(&p, "Narration", 40.0, 80.0, 80.0, 80.0)
    clip.kind = .media(MediaClip(
        media: audio, video: false, trimStartMs: 400, trimEndMs: 2600, fadeInMs: 80, fadeOutMs: 120, volume: 1.0,
        bookmarks: [Pair("Intro", 400), Pair("Outro", 2200)]
    ))
    var film = IT.shape(&p, "Film", 160.0, 80.0, 240.0, 135.0)
    film.kind = .media(MediaClip(
        media: video, video: true, poster: posterId, trimStartMs: 250, trimEndMs: 9000, volume: 1.0, bookmarks: [Pair("Mark", 1500)]
    ))
    var trigger = IT.shape(&p, "Trigger", 40.0, 240.0, 100.0, 36.0)
    trigger.text = TextBody.fromText("Play")
    var fader = IT.shape(&p, "Fader", 160.0, 240.0, 140.0, 60.0)
    fader.text = TextBody.fromText("Hello")
    let triggerId = trigger.id
    let faderId = fader.id
    media.shapes += [clip, film, trigger, fader]
    var fade = Animation.default
    fade.shape = faderId
    fade.effect = "fade"
    fade.durationMs = 600
    fade.repeat = 4
    fade.bounceEnd = 0.25
    fade.trigger = triggerId
    var pulse = Animation.default
    pulse.shape = faderId
    pulse.class = .emphasis
    pulse.effect = "pulse"
    pulse.durationMs = 400
    pulse.repeat = UInt32.max
    media.animations = [fade, pulse]
    p.slides.append(media)

    var aside = IT.newSlide(&p, "Aside")
    aside.hidden = true
    var ink = IT.shape(&p, "Sketch", 48.0, 96.0, 200.0, 80.0)
    ink.kind = .ink(strokes: [
        InkStroke(
            points: [Triple(48.0, 100.0, 0.4), Triple(90.0, 140.0, 0.8), Triple(150.0, 110.0, 0.3)], color: .rgb(20, 20, 20), width: 2.0,
            highlighter: false
        ),
        InkStroke(points: [Triple(50.0, 150.0, 1.0), Triple(160.0, 156.0, 1.0)], color: .rgb(255, 230, 40), width: 12.0, highlighter: true),
    ])
    aside.shapes.append(ink)
    p.slides.append(aside)

    let ids = p.slides.map(\.id)
    let hidden = try #require(ids.last, "aside")
    p.sections = [
        Section(name: "Open", slides: ids.filter { $0 != hidden }),
        Section(name: "Aside", slides: [hidden]),
    ]
    p.firstSlideNumber = 4
    return (p, block, globe, poster)
}

private func byName(_ p: Presentation, _ name: String) throws -> Shape {
    for s in p.slides {
        if let x = IT.find(s.shapes, name) { return x }
    }
    return try #require(nil as Shape?, "no shape \(name)")
}

private func mediaBytes(_ p: Presentation, _ shape: String) throws -> [UInt8] {
    let id: MediaId
    switch try byName(p, shape).kind {
    case .model3d(let media, _): id = media
    case .media(let clip): id = clip.media
    case let other:
        Issue.record("\(shape) has no media: \(other)")
        return []
    }
    return try #require(p.media(id), "media").data
}

private func assertField(_ p: Presentation, _ name: String, _ kind: String, _ text: String) throws {
    let body = try #require(try byName(p, name).text, "text")
    let run = try #require(body.paragraphs.first?.runs.first)
    #expect(run.kind == .field(field: kind), "\(name): \(run.kind)")
    #expect(run.text == text)
}

private func assertInk(_ s: Shape) {
    guard case .group(let children, _) = s.kind else {
        Issue.record("ink comes back as a group, got \(s.kind)")
        return
    }
    #expect(children.count == 2, "pen and highlighter")
    #expect(children.allSatisfy { if case .custom = $0.geom { true } else { false } })
}

/// An exported deck with `parts` added (or replaced) and `edit` applied to every XML part.
private func withParts(_ parts: [(String, [UInt8])], _ edit: (String, String) -> String) throws -> [UInt8] {
    let base = try PPTX.export(newPresentation(nil))
    var out: [(name: String, data: [UInt8])] = []
    for e in try IT.entries(base) {
        if parts.contains(where: { $0.0 == e.name }) { continue }
        var d = e.data
        if e.name.hasSuffix(".xml") || e.name.hasSuffix(".rels") {
            d = Array(edit(e.name, String(decoding: d, as: UTF8.self)).utf8)
        }
        out.append((e.name, d))
    }
    for (name, data) in parts { out.append((name, data)) }
    return try IT.zip(out)
}

private func zipText(_ bytes: [UInt8], _ name: String) throws -> String {
    let d = try #require(IT.part(bytes, name), "no \(name)")
    return String(decoding: d, as: UTF8.self)
}

private func zipHasPayload(_ bytes: [UInt8], _ payload: [UInt8]) throws -> Bool {
    try IT.entries(bytes).contains { $0.data == payload }
}

@Suite struct IntegrationCorpusMediaTests {
    // Rust: it/corpus_media.rs::object_corpus_round_trips
    @Test func objectCorpusRoundTrips() throws {
        let (p, block, globe, poster) = try corpus()
        let bytes = try PPTX.export(p)
        let types = try zipText(bytes, "[Content_Types].xml")
        #expect(types.has("model/gltf-binary"), "\(types)")
        #expect(try zipHasPayload(bytes, block), "block model was not written")
        #expect(try zipHasPayload(bytes, globe), "globe model was not written")
        let once = try PPTX.import(bytes)
        let twice = try IT.round(once)

        for q in [once, twice] {
            let diagram = try byName(q, "Diagram")
            guard case .opaque(let xml, _, let label, _) = diagram.kind else {
                Issue.record("\(diagram.kind)")
                continue
            }
            #expect(label == "SmartArt")
            #expect(xml.has("Quarter"), "\(xml)")
            #expect(!xml.has("r:dm"), "diagram parts are not part of this corpus")

            let embedded = try byName(q, "Embedded")
            guard case .opaque(let exml, _, let elabel, _) = embedded.kind else {
                Issue.record("\(embedded.kind)")
                continue
            }
            #expect(elabel == "DeckCraft.Note.1")
            #expect(exml.has("DeckCraft.Note.1"), "\(exml)")
            #expect(!exml.has("r:id"), "an embedding part is issue #203")

            let blockShape = try byName(q, "Block")
            guard case .model3d(let bmedia, let bposter) = blockShape.kind else {
                Issue.record("\(blockShape.kind)")
                continue
            }
            #expect(bposter == nil, "\(blockShape.kind)")
            #expect(blockShape.xfrm == Xfrm(40.0, 240.0, 120.0, 90.0))
            #expect(try mediaBytes(q, "Block") == block)
            let blockMedia = try #require(q.media(bmedia), "block media")
            #expect(blockMedia.contentType == "model/gltf-binary")
            #expect(rustASCIILowercase(blockMedia.name).hasSuffix(".glb"), "\(blockMedia.name)")

            let globeShape = try byName(q, "Globe")
            guard case .model3d(let gmedia, let posterMedia?) = globeShape.kind else {
                Issue.record("\(globeShape.kind)")
                continue
            }
            #expect(globeShape.xfrm == Xfrm(180.0, 240.0, 160.0, 120.0))
            #expect(q.media(gmedia)?.data == globe)
            #expect(q.media(posterMedia)?.data == poster)

            let narration = try byName(q, "Narration")
            guard case .media(let m) = narration.kind else {
                Issue.record("\(narration.kind)")
                continue
            }
            #expect(!m.video)
            #expect(m.trimStartMs == 400)
            #expect(m.trimEndMs == 2600)
            #expect(m.fadeInMs == 80)
            #expect(m.fadeOutMs == 120)
            #expect(m.bookmarks == [Pair("Intro", 400), Pair("Outro", 2200)])
            #expect(q.media(m.media)?.data == Array("audio-bytes-deckcraft".utf8))

            let film = try byName(q, "Film")
            guard case .media(let f) = film.kind else {
                Issue.record("\(film.kind)")
                continue
            }
            #expect(f.video)
            #expect(f.trimStartMs == 250)
            #expect(f.trimEndMs == 9000)
            #expect(f.bookmarks == [Pair("Mark", 1500)])
            #expect(q.media(f.media)?.data == Array("video-bytes-deckcraft".utf8))

            try assertField(q, "Slide number", "slidenum", "4")
            try assertField(q, "Date", "datetime4", "14 October 2026")
            #expect(q.firstSlideNumber == 4)

            #expect(q.sections.map(\.name) == ["Open", "Aside"])
            let hidden = try #require(q.slides.firstIndex { $0.hidden }, "a hidden slide")
            #expect(q.slides.filter(\.hidden).count == 1)
            try #require(q.sections.count == 2)
            #expect(q.sections[1].slides.contains(q.slides[hidden].id))
            #expect(!q.sections[0].slides.contains(q.slides[hidden].id))

            assertInk(try byName(q, "Sketch"))

            let timing = try #require(q.slides.first { $0.animations.contains { $0.effect == "fade" } }, "timing slide")
            let fade = try #require(timing.animations.first { $0.effect == "fade" }, "fade")
            let pulse = try #require(timing.animations.first { $0.effect == "pulse" }, "pulse")
            #expect(fade.repeat == 4)
            #expect(abs(fade.bounceEnd - 0.25) < 1e-9, "\(fade.bounceEnd)")
            #expect(try fade.trigger == byName(q, "Trigger").id)
            #expect(try fade.shape == byName(q, "Fader").id)
            #expect(pulse.repeat == UInt32.max)
            #expect(pulse.class == .emphasis)
            #expect(pulse.trigger == nil)
        }
    }

    // Rust: it/corpus_media.rs::an_alternate_content_model_keeps_the_glb_and_its_poster
    @Test func anAlternateContentModelKeepsTheGlbAndItsPoster() throws {
        let model = glb(7)
        let poster = png((200, 30, 40))
        let frame = #"<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:am3d="http://schemas.microsoft.com/office/drawing/2017/model3d" Requires="am3d"><p:contentPart r:id="rIdModel"><p:nvContentPartPr><p:cNvPr id="60" name="Model from file"/><p:cNvContentPartPr/><p:nvPr/></p:nvContentPartPr><p:xfrm><a:off x="508000" y="635000"/><a:ext cx="1524000" cy="1143000"/></p:xfrm></p:contentPart></mc:Choice><mc:Fallback><p:pic><p:nvPicPr><p:cNvPr id="61" name="Model poster"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdPoster"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="508000" y="635000"/><a:ext cx="1524000" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></mc:Fallback></mc:AlternateContent>"#
        let bytes = try withParts([("ppt/media/model.glb", model), ("ppt/media/poster.png", poster)]) { name, s in
            if name == "ppt/slides/slide1.xml" {
                return s.replacen("</p:spTree>", "\(frame)</p:spTree>", 1)
            } else if name == "ppt/slides/_rels/slide1.xml.rels" {
                return s.replacen(
                    "</Relationships>",
                    #"<Relationship Id="rIdModel" Type="http://schemas.microsoft.com/office/2017/06/relationships/model3d" Target="../media/model.glb"/><Relationship Id="rIdPoster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/poster.png"/></Relationships>"#,
                    1
                )
            }
            return s
        }
        let once = try PPTX.import(bytes)
        let twice = try IT.round(once)
        for q in [once, twice] {
            #expect(q.slides[0].shapes.allSatisfy { $0.name != "Model poster" }, "the fallback picture replaced the model")
            let s = try byName(q, "Model from file")
            guard case .model3d(let media, let posterId?) = s.kind else {
                Issue.record("\(s.kind)")
                continue
            }
            #expect(s.xfrm == Xfrm(40.0, 50.0, 120.0, 90.0))
            let modelItem = try #require(q.media(media), "glb")
            #expect(modelItem.data == model)
            #expect(modelItem.contentType == "model/gltf-binary")
            #expect(q.media(posterId)?.data == poster)
        }
    }

    // Rust: it/corpus_media.rs::an_ink_content_part_still_uses_its_fallback_picture
    @Test func anInkContentPartStillUsesItsFallbackPicture() throws {
        let poster = png((10, 10, 10))
        let frame = #"<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="p14"><p:contentPart r:id="rIdInk"><p:nvContentPartPr><p:cNvPr id="50" name="Ink marks"/><p:cNvContentPartPr/><p:nvPr/></p:nvContentPartPr></p:contentPart></mc:Choice><mc:Fallback><p:pic><p:nvPicPr><p:cNvPr id="51" name="Ink poster"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdPoster"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></mc:Fallback></mc:AlternateContent>"#
        let bytes = try withParts([("ppt/ink/ink1.xml", Array("<ink/>".utf8)), ("ppt/media/ink-poster.png", poster)]) { name, s in
            if name == "ppt/slides/slide1.xml" {
                return s.replacen("</p:spTree>", "\(frame)</p:spTree>", 1)
            } else if name == "ppt/slides/_rels/slide1.xml.rels" {
                return s.replacen(
                    "</Relationships>",
                    #"<Relationship Id="rIdInk" Type="http://schemas.microsoft.com/office/2007/relationships/ink" Target="../ink/ink1.xml"/><Relationship Id="rIdPoster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/ink-poster.png"/></Relationships>"#,
                    1
                )
            }
            return s
        }
        let p = try PPTX.import(bytes)
        #expect(p.slides[0].shapes.allSatisfy { $0.name != "Ink marks" })
        let s = try byName(p, "Ink poster")
        guard case .picture(let fill) = s.kind else {
            Issue.record("\(s.kind)")
            return
        }
        #expect(p.media(fill.media)?.data == poster)
    }
}
