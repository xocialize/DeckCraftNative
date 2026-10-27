// Port of deckcraft crates/pptx/tests/it/table_styles.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Fills and styles read from decks written by other tools.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationTableStylesTests {
    private static let styleGUID = "{ABCDEF01-2345-4678-9ABC-DEF012345678}"

    /// A table style definition as PowerPoint writes one: red table background, see-through white
    /// bands, 2 pt blue outer borders and no inside lines.
    private static func styleXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="\(styleGUID)"><a:tblStyle styleId="\(styleGUID)" styleName="Probe Style"><a:tblBg><a:fillRef idx="1"><a:srgbClr val="FF0000"/></a:fillRef></a:tblBg><a:wholeTbl><a:tcTxStyle b="on"><a:srgbClr val="00FF00"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:left><a:ln w="25400"><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill></a:ln></a:left><a:insideH><a:ln><a:noFill/></a:ln></a:insideH></a:tcBdr><a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl><a:band1H><a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:srgbClr val="FFFFFF"><a:alpha val="20000"/></a:srgbClr></a:solidFill></a:fill></a:tcStyle></a:band1H></a:tblStyle></a:tblStyleLst>
        """
    }

    /// An exported deck with a 3x2 table using the probe style.
    private static func tableDeck() throws -> [UInt8] {
        var p = newPresentation(nil)
        let raw = p.allocId()
        let id = ShapeId(try #require(raw, "ids"))
        var t = Table(rows: 3, cols: 2, width: 300.0, rowHeight: 30.0)
        t.style = "medium2-accent1"
        var s = Shape.default
        s.id = id
        s.name = "Styled"
        s.xfrm = Xfrm(10.0, 10.0, 300.0, 90.0)
        s.kind = .table(t)
        p.slides[0].shapes.append(s)
        // Point the table at the probe style and replace the style part.
        return try IT.zip(IT.entries(PPTX.export(p)).map { e in
            if e.name == "ppt/tableStyles.xml" { return (e.name, Array(styleXML().utf8)) }
            guard e.name.hasPrefix("ppt/slides/slide"), e.name.hasSuffix(".xml") else { return e }
            let s = String(decoding: e.data, as: UTF8.self)
            let start = s.byteFind("<a:tableStyleId>").map { $0 + "<a:tableStyleId>".utf8.count }
            let end = s.byteFind("</a:tableStyleId>")
            guard let a = start, let b = end else { return e }
            return (e.name, Array((s.bytes(0, a) + styleGUID + s.bytes(b)).utf8))
        })
    }

    // Rust: it/table_styles.rs::table_styles_the_file_defines_are_read_used_and_kept
    @Test func tableStylesTheFileDefinesAreReadUsedAndKept() throws {
        let p = try PPTX.import(Self.tableDeck())
        let def = try #require(p.tableStyles.first { $0.id == Self.styleGUID }, "the probe style is read")
        #expect(def.name == "Probe Style")
        let bg = try #require(def.background, "table background")
        #expect(bg.fillRef?.a == 1)
        let whole = try #require(def.part(.wholeTbl), "whole table")
        #expect(whole.bold == true)
        #expect(whole.textColor != nil)
        let left = whole.borders.count > 0 ? whole.borders[0] : nil
        if case .line(let line)? = left {
            #expect(line.width == 2.0)
        } else {
            Issue.record("left border: \(String(describing: left))")
        }
        let insideH = whole.borders.count > 4 ? whole.borders[4] : nil
        if case .line(let line)? = insideH, case .none_? = line.fill {
        } else {
            Issue.record("insideH border: \(String(describing: insideH))")
        }
        if case .solid? = def.part(.band1H)?.fill {
        } else {
            Issue.record("band1H fill: \(String(describing: def.part(.band1H)?.fill))")
        }
        // The table keeps the style's GUID, so it's drawn from the definition.
        let s = try #require(p.slides[0].shapes.first { $0.name == "Styled" }, "table")
        guard case .table(let t) = s.kind else {
            Issue.record("table")
            return
        }
        #expect(t.style == Self.styleGUID)
        // Saving writes the definition back, unchanged.
        let again = try PPTX.export(p)
        let q = try PPTX.import(again)
        let def2 = try #require(q.tableStyles.first { $0.id == Self.styleGUID }, "kept on save")
        #expect(def2.parts == def.parts)
    }

    // Rust: it/table_styles.rs::table_style_no_table_uses_is_kept_on_save
    @Test func tableStyleNoTableUsesIsKeptOnSave() throws {
        var p = try PPTX.import(Self.tableDeck())
        #expect(p.tableStyles.contains { $0.id == Self.styleGUID })
        // Drop the only table that uses the style; the deck still defines it.
        for i in p.slides.indices {
            p.slides[i].shapes.removeAll { sh in
                if case .table = sh.kind { return true }
                return false
            }
        }
        let q = try IT.round(p)
        let d = try #require(q.tableStyles.first { $0.id == Self.styleGUID }, "style kept")
        #expect(d.name == "Probe Style")
    }
}
