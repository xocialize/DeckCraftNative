// Port of deckcraft crates/pptx/tests/it/ole.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Embedded (OLE) objects and their preview pictures, as other versions of PowerPoint write
// them.
import DCColor
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationOleTests {
    private static func png() -> [UInt8] { IT.png(4, 4, (10, 200, 30)) }

    /// An exported deck with `parts` added (or replaced) and `edit` applied to every part's text.
    private static func withParts(_ parts: [(String, [UInt8])], _ edit: (String, String) -> String) throws -> [UInt8] {
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

    /// PowerPoint 2007 style: `p:oleObj spid` with no `p:pic`; the preview is the `v:imagedata` of the
    /// VML shape with that id in the slide's legacy drawing part.
    private static func oleDeck(_ spidInVML: String) throws -> [UInt8] {
        let vml = """
            <xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
             <v:shape id="_x0000_s9999" style='position:absolute;left:0;top:0;width:1in;height:1in'><v:imagedata o:relid="rId7" o:title=""/></v:shape>
             <v:shape id="\(spidInVML)" style='position:absolute;left:0;top:0;width:2in;height:1in'><v:imagedata o:relid="rId1" o:title=""/></v:shape>
            </xml>
            """
        let vmlRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/preview.png"/><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/other.png"/></Relationships>
            """
        let frame = #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="900" name="Object 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/presentationml/2006/ole"><p:oleObj spid="_x0000_s681987" name="Slide" r:id="rIdOle" imgW="4664160" imgH="3497400" progId="PowerPoint.Slide.8"><p:embed/></p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"#
        return try withParts(
            [
                ("ppt/drawings/vmlDrawing1.vml", Array(vml.utf8)),
                ("ppt/drawings/_rels/vmlDrawing1.vml.rels", Array(vmlRels.utf8)),
                ("ppt/media/preview.png", png()),
                ("ppt/media/other.png", [1, 2, 3]),
                ("ppt/embeddings/oleObject1.bin", [UInt8](repeating: 0, count: 16)),
            ]
        ) { name, s in
            if name == "ppt/slides/slide1.xml" {
                return s.replacen("</p:spTree>", "\(frame)</p:spTree>", 1)
            } else if name == "ppt/slides/_rels/slide1.xml.rels" {
                return s.replacen(
                    "</Relationships>",
                    #"<Relationship Id="rIdVml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../drawings/vmlDrawing1.vml"/><Relationship Id="rIdOle" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject" Target="../embeddings/oleObject1.bin"/></Relationships>"#,
                    1
                )
            }
            return s
        }
    }

    private static func objectPreview(_ bytes: [UInt8]) throws -> [UInt8]? {
        let p = try PPTX.import(bytes)
        let s = try #require(p.slides[0].shapes.first { $0.name == "Object 3" }, "object")
        guard case .opaque(_, let preview, let label, _) = s.kind else {
            Issue.record("\(s.kind)")
            return nil
        }
        #expect(label == "PowerPoint.Slide.8")
        return preview.flatMap { p.media($0) }.map(\.data)
    }

    // Rust: it/ole.rs::an_old_ole_object_shows_its_vml_preview
    @Test func anOldOleObjectShowsItsVMLPreview() throws {
        #expect(try Self.objectPreview(Self.oleDeck("_x0000_s681987")) == Self.png(), "the VML shape with the object's spid")
    }

    // Rust: it/ole.rs::an_ole_object_without_a_matching_vml_shape_has_no_preview
    @Test func anOleObjectWithoutAMatchingVMLShapeHasNoPreview() throws {
        #expect(try Self.objectPreview(Self.oleDeck("_x0000_s1")) == nil)
    }

    // Rust: it/ole.rs::an_ole_objects_fallback_picture_gives_it_its_fill_and_outline
    /// PowerPoint 2010 and later: `p:oleObj` with a fallback `p:pic` inside `mc:AlternateContent`, whose
    /// `spPr` can give the object a fill and an outline (old equation objects on coloured boxes).
    @Test func anOleObjectsFallbackPictureGivesItItsFillAndOutline() throws {
        func pic(_ spr: String) -> String {
            #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="900" name="Object 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/presentationml/2006/ole"><mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:v="urn:schemas-microsoft-com:vml" Requires="v"><p:oleObj name="Equation" r:id="rIdOle" imgW="1663700" imgH="228600" progId="Equation.3"><p:embed/></p:oleObj></mc:Choice><mc:Fallback><p:oleObj name="Equation" r:id="rIdOle" imgW="1663700" imgH="228600" progId="Equation.3"><p:embed/><p:pic><p:nvPicPr><p:cNvPr id="0" name="Object 3"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdImg"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>"#
                + spr + #"</p:spPr></p:pic></p:oleObj></mc:Fallback></mc:AlternateContent></a:graphicData></a:graphic></p:graphicFrame>"#
        }
        func deck(_ frame: String) throws -> [UInt8] {
            try Self.withParts([("ppt/media/eq.png", Self.png()), ("ppt/embeddings/oleObject1.bin", [UInt8](repeating: 0, count: 16))]) { name, s in
                if name == "ppt/slides/slide1.xml" {
                    return s.replacen("</p:spTree>", "\(frame)</p:spTree>", 1)
                } else if name == "ppt/slides/_rels/slide1.xml.rels" {
                    return s.replacen(
                        "</Relationships>",
                        #"<Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/eq.png"/><Relationship Id="rIdOle" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject" Target="../embeddings/oleObject1.bin"/></Relationships>"#,
                        1
                    )
                }
                return s
            }
        }
        func object(_ bytes: [UInt8]) throws -> Shape {
            let p = try PPTX.import(bytes)
            let s = try #require(p.slides[0].shapes.first { $0.name == "Object 3" }, "object")
            var ok = false
            if case .opaque(_, let preview, let label, _) = s.kind, preview != nil, label == "Equation.3" { ok = true }
            #expect(ok, "\(s.kind)")
            return s
        }
        let filled = try object(deck(pic(
            #"<a:solidFill><a:srgbClr val="FF9900"/></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill></a:ln>"#
        )))
        let orange = Fill.solid(ColorRef.rgb(Rgba.rgb(0xFF, 0x99, 0)))
        #expect(filled.fill == orange)
        #expect(filled.line?.width == 1.0)
        // Saved as its preview picture (its kept XML can't be written back), it keeps the fill.
        var p = try PPTX.import(deck(pic(#"<a:solidFill><a:srgbClr val="FF9900"/></a:solidFill>"#)))
        for i in p.slides[0].shapes.indices {
            if case .opaque(_, let preview, let label, let parts) = p.slides[0].shapes[i].kind {
                p.slides[0].shapes[i].kind = .opaque(xml: "", preview: preview, label: label, parts: parts)
            }
        }
        let back = try PPTX.import(PPTX.export(p))
        let saved = try #require(back.slides[0].shapes.first { $0.name == "Object 3" }, "object")
        var isPicture = false
        if case .picture = saved.kind { isPicture = true }
        #expect(isPicture, "\(saved.kind)")
        #expect(saved.fill == orange)
        // Without a fill of its own the object stays unfilled.
        #expect(try object(deck(pic(""))).fill == nil)
    }
}
