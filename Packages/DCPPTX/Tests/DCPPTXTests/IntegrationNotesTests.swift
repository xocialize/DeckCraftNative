// Port of deckcraft crates/pptx/tests/it/notes.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Speaker notes keep their run and paragraph formatting: a bold heading, indented points
// with custom bullets, plain lines.
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationNotesTests {
    private static let notesPart = "ppt/notesSlides/notesSlide1.xml"

    /// A notes slide written the way PowerPoint writes one (Slovak text): a bold heading, a plain
    /// line, two level-2 points with a hanging indent and a Wingdings square bullet (one mixing a bold
    /// label and plain text), a level-2 paragraph with buNone, and a closing plain line.
    private static let notesXML = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="sk-SK" b="1" dirty="0"/><a:t>Metodický prehľad</a:t></a:r></a:p><a:p><a:r><a:rPr lang="sk-SK" dirty="0"/><a:t>Žiaci pracujú vo dvojiciach.</a:t></a:r></a:p><a:p><a:pPr marL="285750" lvl="1" indent="-285750"><a:buFont typeface="Wingdings" panose="05000000000000000000" pitchFamily="2" charset="2"/><a:buChar char="&#167;"/></a:pPr><a:r><a:rPr lang="sk-SK" b="1" dirty="0"/><a:t>Cieľ: </a:t></a:r><a:r><a:rPr lang="sk-SK" dirty="0"/><a:t>vysvetliť cyklus</a:t></a:r></a:p><a:p><a:pPr marL="285750" lvl="1" indent="-285750"><a:buFont typeface="Wingdings" panose="05000000000000000000" pitchFamily="2" charset="2"/><a:buChar char="&#167;"/></a:pPr><a:r><a:rPr lang="sk-SK" i="1" dirty="0"/><a:t>Reflexia</a:t></a:r></a:p><a:p><a:pPr marL="285750" lvl="1" indent="-285750"><a:buNone/></a:pPr><a:r><a:rPr lang="sk-SK" dirty="0"/><a:t>Bez odrážky</a:t></a:r></a:p><a:p><a:r><a:rPr lang="sk-SK" dirty="0"/><a:t>Pomôcky: počítač</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
        """#

    /// A deck with one notes slide, its notes replaced by `notesXML`.
    private static func deck() throws -> [UInt8] {
        var p = newPresentation(nil)
        p.slides[0].notes = TextBody.fromText("placeholder")
        var found = false
        let es = try IT.entries(PPTX.export(p)).map { e in
            guard e.name == notesPart else { return e }
            found = true
            return (e.name, Array(notesXML.utf8))
        }
        try #require(found, "the export has no \(notesPart)")
        return try IT.zip(es)
    }

    private static func assertFormatted(_ notes: TextBody) throws {
        #expect(notes.text == "Metodický prehľad\nŽiaci pracujú vo dvojiciach.\nCieľ: vysvetliť cyklus\nReflexia\nBez odrážky\nPomôcky: počítač")
        try #require(notes.paragraphs.count == 6, "six paragraphs: \(notes)")
        let ps = notes.paragraphs
        let (head, plain, goal, reflect, unbulleted, closing) = (ps[0], ps[1], ps[2], ps[3], ps[4], ps[5])
        #expect(head.runs.first?.props.bold == true, "bold heading")
        for para in [head, plain, closing] {
            #expect(para.level == 0 && para.props == ParaProps.default, "\(para.text)")
        }
        #expect(plain.runs.first?.props.bold == nil)
        for para in [goal, reflect] {
            #expect(para.level == 1, "level 2")
            #expect(para.props.marginLeft == 22.5, "marL 285750 EMU")
            #expect(para.props.indent == -22.5, "hanging indent")
            #expect(para.props.bullet == .char(char: "§"))
            #expect(para.props.bulletFont == "Wingdings")
        }
        try #require(goal.runs.count >= 2)
        #expect(goal.runs[0].text == "Cieľ: " && goal.runs[0].props.bold == true, "bold label")
        #expect(goal.runs[1].text == "vysvetliť cyklus" && goal.runs[1].props.bold == nil, "then plain")
        #expect(reflect.runs.first?.props.italic == true)
        #expect(unbulleted.level == 1 && unbulleted.props.bullet == Bullet.none_ && unbulleted.props.marginLeft == 22.5)
    }

    // Rust: it/notes.rs::notes_import_keeps_bold_levels_and_indents
    @Test func notesImportKeepsBoldLevelsAndIndents() throws {
        let p = try PPTX.import(Self.deck())
        try Self.assertFormatted(p.slides[0].notes)
    }

    // Rust: it/notes.rs::notes_formatting_survives_a_round_trip
    @Test func notesFormattingSurvivesARoundTrip() throws {
        let p = try PPTX.import(Self.deck())
        let again = try IT.round(p)
        try Self.assertFormatted(again.slides[0].notes)
        // And the written XML says so, for PowerPoint.
        let xml = IT.text(try PPTX.export(again), Self.notesPart)
        #expect(xml.has(#"b="1""#), "\(xml)")
        #expect(xml.has(#"lvl="1""#) && xml.has(#"marL="285750""#) && xml.has(#"indent="-285750""#), "\(xml)")
        #expect(xml.has(#"<a:buFont typeface="Wingdings""#) && xml.has("<a:buChar") && xml.has("<a:buNone/>"), "\(xml)")
    }
}
