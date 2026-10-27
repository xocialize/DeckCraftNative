// Port of deckcraft crates/pptx/tests/it/smartart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). SmartArt drawings: the text of each pre-drawn shape is laid out on its `dsp:txXfrm`.
//
// The deck is built here: an export of a new presentation with a SmartArt frame, data part and drawing
// part written by the test. `deckcraft_engine::render::place_slide` is DCRender's `placeSlide`.
import DCCore
import DCGeometry
import DCModel
import DCRender
import Testing
@testable import DCPPTX

@Suite struct IntegrationSmartartTests {
    private static let emuPerPt = 12_700.0

    /// Frame of the diagram on the slide, in points.
    private static let frame = (72.0, 72.0, 432.0, 288.0)

    private static func emu(_ pt: Double) -> Int64 { Int64(rustCast: (pt * emuPerPt).rounded()) }

    private static func xfrm(_ tag: String, _ rot: Double, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
        let r = rot == 0.0 ? "" : " rot=\"\(Int64(rustCast: (rot * 60_000.0).rounded()))\""
        return #"<\#(tag)\#(r)><a:off x="\#(emu(x))" y="\#(emu(y))"/><a:ext cx="\#(emu(w))" cy="\#(emu(h))"/></\#(tag)>"#
    }

    /// One `dsp:sp`: shape box, text rectangle (both in diagram points) and text.
    private static func drawingShape(
        _ prst: String, _ shape: (Double, Double, Double, Double, Double), _ textRect: (Double, Double, Double, Double, Double), _ text: String
    ) -> String {
        let (r, x, y, w, h) = shape
        let (tr, tx, ty, tw, th) = textRect
        return #"<dsp:sp modelId="{00000000-0000-0000-0000-000000000000}"><dsp:nvSpPr><dsp:cNvPr id="0" name=""/><dsp:cNvSpPr/></dsp:nvSpPr><dsp:spPr>"#
            + xfrm("a:xfrm", r, x, y, w, h)
            + #"<a:prstGeom prst="\#(prst)"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="DDEEFF"/></a:solidFill></dsp:spPr><dsp:style><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="dk1"/></a:fontRef></dsp:style><dsp:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="ctr"><a:noAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="1000"/><a:t>\#(text)</a:t></a:r></a:p></dsp:txBody>"#
            + xfrm("dsp:txXfrm", tr, tx, ty, tw, th)
            + "</dsp:sp>"
    }

    private static func replace(_ files: inout [(name: String, data: [UInt8])], _ name: String, _ from: String, _ to: String) throws {
        let i = try #require(files.firstIndex { $0.name == name }, "\(name) missing")
        let s = String(decoding: files[i].data, as: UTF8.self)
        #expect(s.has(from), "\(name) has no \(from)")
        files[i].data = Array(s.replacen(from, to, 1).utf8)
    }

    /// A deck whose first slide holds a SmartArt frame drawn by `shapes`.
    private static func smartartDeck(_ shapes: [String]) throws -> [UInt8] {
        var files = try IT.entries(PPTX.export(newPresentation(nil)))
        let (fx, fy, fw, fh) = frame
        let frameXML = #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="90" name="Diagram 1"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="\#(emu(fx))" y="\#(emu(fy))"/><a:ext cx="\#(emu(fw))" cy="\#(emu(fh))"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:relIds xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" r:dm="rIdDm" r:lo="rIdLo" r:qs="rIdQs" r:cs="rIdCs"/></a:graphicData></a:graphic></p:graphicFrame></p:spTree>"#
        try replace(&files, "ppt/slides/slide1.xml", "</p:spTree>", frameXML)
        try replace(
            &files,
            "ppt/slides/_rels/slide1.xml.rels",
            "</Relationships>",
            #"<Relationship Id="rIdDm" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/diagramData" Target="../diagrams/data1.xml"/><Relationship Id="rIdDr" Type="http://schemas.microsoft.com/office/2007/relationships/diagramDrawing" Target="../diagrams/drawing1.xml"/></Relationships>"#
        )
        let data = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:ptLst/><dgm:extLst><a:ext uri="http://schemas.microsoft.com/office/drawing/2008/diagram"><dsp:dataModelExt xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" relId="rIdDr" minVer="http://schemas.openxmlformats.org/drawingml/2006/diagram"/></a:ext></dgm:extLst></dgm:dataModel>
            """
        let drawing = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dsp:drawing xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dsp:spTree><dsp:nvGrpSpPr><dsp:cNvPr id="0" name=""/><dsp:cNvGrpSpPr/></dsp:nvGrpSpPr><dsp:grpSpPr/>\(shapes.joined())</dsp:spTree></dsp:drawing>
            """
        files.append(("ppt/diagrams/data1.xml", Array(data.utf8)))
        files.append(("ppt/diagrams/drawing1.xml", Array(drawing.utf8)))
        return try IT.zip(files)
    }

    /// Each text of slide 1 with the slide-space box it is laid out in (insets applied), the number of
    /// lines, and the direction of its baseline.
    private static func textBoxes(_ p: Presentation) -> [(String, Rect, Int, Point)] {
        placeSlide(p, 0).texts.map { t in
            let m = t.transform
            let r = t.layout.inner
            let corners = [Point(r.x0, r.y0), Point(r.x1, r.y0), Point(r.x1, r.y1), Point(r.x0, r.y1)].map { m * $0 }
            var bounds = Rect.fromPoints(corners[0], corners[2])
            bounds = bounds.unionPoint(corners[1]).unionPoint(corners[3])
            let d = (m * Point(1.0, 0.0)) - (m * Point(0.0, 0.0))
            let dir = Point(d.x / d.hypot, d.y / d.hypot)
            return (t.body.text, bounds, t.layout.lines.count, dir)
        }
    }

    private static func near(_ a: Rect, _ b: Rect) -> Bool {
        [a.x0 - b.x0, a.y0 - b.y0, a.x1 - b.x1, a.y1 - b.y1].allSatisfy { abs($0) < 0.05 }
    }

    /// Diagram rectangle (x, y, w, h) → slide rectangle.
    private static func onSlide(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(frame.0 + x, frame.1 + y, frame.0 + x + w, frame.1 + y + h)
    }

    private static func check(_ p: Presentation, _ expected: [(String, Rect)]) throws {
        let boxes = textBoxes(p)
        for (text, want) in expected {
            let (_, got, lines, dir) = try #require(boxes.first { $0.0 == text }, "no text \(text) in \(boxes)")
            #expect(near(got, want), "\(text): laid out in \(got), want \(want)")
            #expect(abs(dir.x - 1.0) < 1e-6 && abs(dir.y) < 1e-6, "\(text): baseline turned to \(dir)")
            #expect(lines == 1, "\(text): wrapped into \(lines) lines")
        }
    }

    // Rust: it/smartart.rs::smartart_text_follows_tx_xfrm
    @Test func smartartTextFollowsTxXfrm() throws {
        let deck = try Self.smartartDeck([
            // A narrow shape whose text rectangle is three times wider.
            Self.drawingShape("rect", (0.0, 0.0, 0.0, 72.0, 144.0), (0.0, 0.0, 36.0, 216.0, 72.0), "wider than its shape"),
            // A tall shape turned by 90° (wide on the slide), its text rectangle turned back: horizontal text.
            Self.drawingShape("roundRect", (90.0, 300.0, -60.0, 48.0, 216.0), (-90.0, 220.0, 28.0, 208.0, 40.0), "turned shape, upright text"),
            // A text rectangle inside the shape: the shape keeps its text, with wider insets.
            Self.drawingShape("roundRect", (0.0, 0.0, 192.0, 216.0, 72.0), (0.0, 24.0, 204.0, 168.0, 48.0), "inside its shape"),
        ])
        let expected = [
            ("wider than its shape", Self.onSlide(0.0, 36.0, 216.0, 72.0)),
            ("turned shape, upright text", Self.onSlide(220.0, 28.0, 208.0, 40.0)),
            ("inside its shape", Self.onSlide(24.0, 204.0, 168.0, 48.0)),
        ]

        let p = try PPTX.import(deck)
        #expect(p.validate().isEmpty, "\(p.validate())")
        try Self.check(p, expected)
        // The diagram is one group; text that left its shape is in a frameless shape of the group.
        let group = try #require(p.slides[0].shapes.first { $0.name == "Diagram 1" }, "diagram")
        guard case .group(let children, _) = group.kind else {
            Issue.record("diagram is not a group")
            return
        }
        #expect(children.count == 5)
        let inside = try #require(children.first { $0.text?.text == "inside its shape" }, "inside")
        #expect(inside.geom.presetName == "roundRect", "\(inside.geom)")
        for moved in children where moved.text.map({ $0.text != "inside its shape" }) ?? false {
            #expect(moved.fill == Fill.none_)
            #expect(moved.line?.fill == Fill.none_)
        }

        // The exported deck lays the text out in the same places.
        let q = try PPTX.import(PPTX.export(p))
        try Self.check(q, expected)
    }
}
