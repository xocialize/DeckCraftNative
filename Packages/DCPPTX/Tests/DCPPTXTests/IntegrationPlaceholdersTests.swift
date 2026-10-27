// Port of deckcraft crates/pptx/tests/it/placeholders.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Placeholder inheritance in decks written by PowerPoint.
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
}
