// Port of deckcraft crates/pptx/tests/it/placeholders.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Placeholder inheritance in decks written by PowerPoint.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationPlaceholdersTests {
    /// `bytes` with `edit` applied to every slide part.
    private static func editSlides(_ bytes: [UInt8], _ edit: (String) -> String) throws -> [UInt8] {
        try IT.zip(IT.entries(bytes).map { e in
            guard e.name.hasPrefix("ppt/slides/slide"), e.name.hasSuffix(".xml") else { return e }
            return (e.name, Array(edit(String(decoding: e.data, as: UTF8.self)).utf8))
        })
    }

    private static func isPreset(_ g: Geom, _ want: String) -> Bool {
        if case .preset(let name, _) = g { return name == want }
        return false
    }

    // Rust: it/placeholders.rs::a_placeholder_without_geometry_takes_its_layouts
    @Test func aPlaceholderWithoutGeometryTakesItsLayouts() throws {
        // PowerPoint leaves a slide placeholder's spPr empty and draws it with the layout
        // placeholder's geometry (a picture placeholder cut into a shape keeps the shape).
        var p = newPresentation(nil)
        let layout = p.slides[0].layout
        let li = try #require(p.masters[0].layouts.firstIndex { $0.id == layout }, "layout")
        for i in p.masters[0].layouts[li].shapes.indices where p.masters[0].layouts[li].shapes[i].ph != nil {
            p.masters[0].layouts[li].shapes[i].geom = .preset(name: "ellipse", adj: [])
        }
        let bytes = try PPTX.export(p)
        // Strip the slide's own geometry, as PowerPoint writes inheriting placeholders.
        let bare = try Self.editSlides(bytes) { s in
            var s = s
            while let i = s.byteFind("<a:prstGeom") {
                guard let j = s.byteFind("</a:prstGeom>", from: i).map({ $0 + "</a:prstGeom>".utf8.count }) else { break }
                s = s.bytes(0, i) + s.bytes(j)
            }
            return s
        }
        let q = try PPTX.import(bare)
        let phs = q.slides[0].shapes.filter { $0.ph != nil }
        #expect(!phs.isEmpty)
        for s in phs {
            #expect(Self.isPreset(s.geom, "ellipse"), "\(s.geom)")
        }
        // A placeholder with its own geometry keeps it.
        let first = p.slides[0].id
        _ = p.mutateSlide(first) { s in
            for i in s.shapes.indices where s.shapes[i].ph != nil {
                s.shapes[i].geom = .preset(name: "triangle", adj: [])
            }
        }
        let q2 = try PPTX.import(PPTX.export(p))
        #expect(q2.slides[0].shapes.filter { $0.ph != nil }.allSatisfy { Self.isPreset($0.geom, "triangle") })
    }

    // Rust: it/placeholders.rs::a_picture_placeholder_without_geometry_takes_its_layouts
    @Test func aPicturePlaceholderWithoutGeometryTakesItsLayouts() throws {
        // The slide's picture sits in a layout's picture placeholder drawn as an ellipse; PowerPoint
        // writes its spPr with a frame only and shows the picture cut into the circle.
        var p = newPresentation(nil)
        let m = p.addMedia("image1.png", "image/png", IT.png(4, 4, (10, 200, 30)))
        let img = try #require(m, "media")
        let ph = Placeholder(kind: .picture, idx: 15)
        let layout = p.slides[0].layout
        var slot = Shape.default
        let slotId = p.allocId()
        slot.id = ShapeId(try #require(slotId, "ids"))
        slot.name = "Picture Placeholder"
        slot.xfrm = Xfrm(100.0, 100.0, 200.0, 200.0)
        slot.geom = .preset(name: "ellipse", adj: [])
        slot.ph = ph
        let li = try #require(p.masters[0].layouts.firstIndex { $0.id == layout }, "layout")
        p.masters[0].layouts[li].shapes.append(slot)
        var pic = Shape.default
        let picId = p.allocId()
        pic.id = ShapeId(try #require(picId, "ids"))
        pic.name = "Photo"
        pic.xfrm = Xfrm(100.0, 100.0, 200.0, 200.0)
        pic.kind = .picture(fill: PictureFill(media: img))
        pic.ph = ph
        p.slides[0].shapes = [pic]
        let bytes = try PPTX.export(p)
        let bare = try Self.editSlides(bytes) { s in
            var s = s
            while let i = s.byteFind("<a:prstGeom") {
                guard let j = s.byteFind("</a:prstGeom>", from: i).map({ $0 + "</a:prstGeom>".utf8.count }) else { break }
                s = s.bytes(0, i) + s.bytes(j)
            }
            return s
        }
        let q = try PPTX.import(bare)
        let photo = try #require(q.slides[0].shapes.first { if case .picture = $0.kind { true } else { false } }, "picture")
        #expect(Self.isPreset(photo.geom, "ellipse"), "\(photo.geom)")
    }
}
