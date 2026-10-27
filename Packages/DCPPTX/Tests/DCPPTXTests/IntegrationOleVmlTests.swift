// Port of deckcraft crates/pptx/tests/it/ole_vml.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Legacy OLE objects whose preview picture lives in the slide's VML drawing, and ActiveX
// controls shown by their pictures.
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationOleVmlTests {
    private static let frame = #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="90" name="Object 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/presentationml/2006/ole"><p:oleObj spid="_x0000_s2050" name="Slide" r:id="rIdOle" progId="Thing.1"><p:embed/></p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"#

    private static let vml = #"<xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"><v:shape id="_x0000_s2049"><v:imagedata o:relid="rIdA"/></v:shape><v:shape id="_x0000_s2050" style='position:absolute;left:0;top:0;width:1in;height:1in'><v:imagedata o:relid="rIdB" o:title=""/></v:shape></xml>"#

    private static let vmlRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdA" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/other.png"/><Relationship Id="rIdB" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/preview.png"/></Relationships>"#

    private static let slideRels = #"<Relationship Id="rIdVml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../drawings/vmlDrawing1.vml"/><Relationship Id="rIdPic" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/preview.png"/>"#

    /// An ActiveX control as PowerPoint writes it: a VML-only choice, and a fallback with its picture.
    private static let controls = #"<p:controls><mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:v="urn:schemas-microsoft-com:vml" Requires="v"><p:control spid="1137" name="CheckBox1" r:id="rIdX" imgW="1933560" imgH="514440"/></mc:Choice><mc:Fallback><p:control name="CheckBox1" r:id="rIdX" imgW="1933560" imgH="514440"><p:pic><p:nvPicPr><p:cNvPr id="4" name="CheckBox1"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdPic"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="12700" y="25400"/><a:ext cx="127000" cy="63500"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:control></mc:Fallback></mc:AlternateContent><p:control name="NoPicture" r:id="rIdY"/></p:controls>"#

    private static func png(_ v: UInt8) -> [UInt8] { IT.png(2, 2, (v, v, v)) }

    /// A new deck whose first slide holds `frame`, with the VML drawing, its rels and two pictures.
    private static func deck() throws -> [UInt8] { try deckWith(frame) }

    /// `deck` with `frames` in place of `frame`.
    private static func deckWith(_ frames: String) throws -> [UInt8] {
        let bytes = try PPTX.export(newPresentation(nil))
        var out: [(name: String, data: [UInt8])] = []
        for e in try IT.entries(bytes) {
            var d = e.data
            if e.name == "ppt/slides/slide1.xml" {
                var s = String(decoding: d, as: UTF8.self)
                let at = try #require(s.byteRFind("</p:spTree>"), "spTree")
                s = s.bytes(0, at) + frames + s.bytes(at)
                let at2 = try #require(s.byteRFind("</p:cSld>"), "cSld")
                d = Array((s.bytes(0, at2) + controls + s.bytes(at2)).utf8)
            } else if e.name == "ppt/slides/_rels/slide1.xml.rels" {
                d = Array(String(decoding: d, as: UTF8.self).replace("</Relationships>", "\(slideRels)</Relationships>").utf8)
            }
            out.append((e.name, d))
        }
        for (name, data) in [
            ("ppt/drawings/vmlDrawing1.vml", Array(vml.utf8)),
            ("ppt/drawings/_rels/vmlDrawing1.vml.rels", Array(vmlRels.utf8)),
            ("ppt/media/other.png", png(10)),
            ("ppt/media/preview.png", png(200)),
        ] { out.append((name, data)) }
        return try IT.zip(out)
    }

    // Rust: it/ole_vml.rs::an_ole_object_without_a_picture_shows_its_vml_preview
    @Test func anOleObjectWithoutAPictureShowsItsVMLPreview() throws {
        let p = try PPTX.import(Self.deck())
        let s = try #require(p.slides[0].shapes.first { $0.name == "Object 3" }, "frame")
        guard case .opaque(_, let preview, let label, _) = s.kind, let m = preview else {
            Issue.record("\(s.kind)")
            return
        }
        #expect(label == "Thing.1")
        let media = try #require(p.media.first { $0.id == m }, "media")
        // The shape whose id is the object's spid, not the first one in the drawing.
        #expect(media.name == "preview.png")
    }

    // Rust: it/ole_vml.rs::activex_controls_show_their_pictures
    @Test func activexControlsShowTheirPictures() throws {
        let p = try PPTX.import(Self.deck())
        let s = try #require(p.slides[0].shapes.first { $0.name == "CheckBox1" }, "control picture")
        guard case .picture(let fill) = s.kind else {
            Issue.record("\(s.kind)")
            return
        }
        #expect(p.media.first { $0.id == fill.media }?.name == "preview.png")
        let x = try #require(s.xfrm, "xfrm")
        #expect(x.x == 1.0 && x.y == 2.0 && x.w == 10.0 && x.h == 5.0, "\(x)")
        #expect(!p.slides[0].shapes.contains { $0.name == "NoPicture" }, "a control without a picture draws nothing")
    }

    // Rust: it/ole_vml.rs::many_objects_sharing_one_vml_drawing_each_get_their_preview
    @Test func manyObjectsSharingOneVMLDrawingEachGetTheirPreview() throws {
        // 200 frames look up the same drawing (it is parsed once); every other one names a shape id the
        // drawing doesn't have.
        let frames = (0 ..< 200).map { i -> String in
            let spid = switch i % 4 {
            case 0: "_x0000_s2050"
            case 1: "_x0000_s9999"
            case 2: "_x0000_s2049"
            default: "missing"
            }
            return Self.frame.replace("id=\"90\" name=\"Object 3\"", "id=\"\(1000 + i)\" name=\"Obj \(i)\"").replace("_x0000_s2050", spid)
        }.joined()
        let p = try PPTX.import(Self.deckWith(frames))
        for i in 0 ..< 200 {
            let s = try #require(p.slides[0].shapes.first { $0.name == "Obj \(i)" }, "frame")
            guard case .opaque(_, let preview, _, _) = s.kind else {
                Issue.record("\(s.kind)")
                continue
            }
            let name = preview.flatMap { m in p.media.first { $0.id == m } }.map(\.name)
            let want: String? = switch i % 4 {
            case 0: "preview.png"
            case 2: "other.png"
            default: nil
            }
            #expect(name == want, "frame \(i)")
        }
    }
}
