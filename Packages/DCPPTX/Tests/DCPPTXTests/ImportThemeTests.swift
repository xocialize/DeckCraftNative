// The `import_theme_tests` of deckcraft crates/pptx/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).

import DCColor
import DCModel
@testable import DCPPTX
import DCZip
import Testing

@Suite struct ImportThemeTests {
    static func custom() -> Presentation {
        var p = Presentation.default
        p.masters[0].theme.name = "Harbour"
        p.masters[0].theme.fonts.major.latin = "Lato"
        p.masters[0].theme.fonts.minor.latin = "Source Sans 3"
        p.masters[0].theme.colors.set(.accent1, Rgba.rgb(0x12, 0x34, 0x56))
        return p
    }

    /// A `.thmx`: the deck's theme part as the package's main document.
    static func thmx(_ pptx: [UInt8]) throws -> [UInt8] {
        let z = try ZipReader(pptx)
        let theme = try z.read(named: "ppt/theme/theme1.xml", max: .max)
        var out = ZipWriter()
        try out.add("[Content_Types].xml", Array(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/theme/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>"#.utf8), compress: true)
        try out.add("_rels/.rels", Array(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="theme/theme/theme1.xml"/></Relationships>"#.utf8), compress: true)
        try out.add("theme/theme/theme1.xml", theme, compress: true)
        return try out.finish()
    }

    @Test
    func readsTheThemeOfAPptxAndOfAThmx() throws {
        let pptx = try PPTX.export(Self.custom())
        for bytes in [pptx, try Self.thmx(pptx)] {
            let (t, _) = try PPTX.importTheme(bytes)
            #expect(t.name == "Harbour")
            #expect(t.fonts.major.latin == "Lato")
            #expect(t.fonts.minor.latin == "Source Sans 3")
            #expect(t.colors.get(.accent1) == Rgba.rgb(0x12, 0x34, 0x56))
        }
    }

    @Test
    func nonThemePackagesAreErrors() throws {
        #expect(throws: PPTXError.self) { try PPTX.importTheme(Array("not a zip".utf8)) }
        var out = ZipWriter()
        try out.add("[Content_Types].xml", Array("<Types/>".utf8), compress: true)
        let bytes = try out.finish()
        #expect(throws: PPTXError.self) { try PPTX.importTheme(bytes) }
    }
}
