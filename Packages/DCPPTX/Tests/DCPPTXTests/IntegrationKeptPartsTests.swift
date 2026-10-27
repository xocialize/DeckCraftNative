// Port of deckcraft crates/pptx/tests/it/kept_parts.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): custom XML data (SharePoint metadata), the sensitivity label and custom
// document properties survive opening and saving a deck.
//
// The engine's sample deck (`deckcraft_engine::sample::open_sample`) is read from the oracle corpus,
// where deckcraft saved it, so this test runs without DCEngine (wave 4) and skips without the corpus.
import DCModel
import Testing
@testable import DCPPTX

private let item = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><b:Sources xmlns:b="http://schemas.openxmlformats.org/officeDocument/2006/bibliography"/>"#
private let props = #"<?xml version="1.0" encoding="UTF-8" standalone="no"?><ds:datastoreItem ds:itemID="{11111111-2222-3333-4444-555555555555}" xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs/></ds:datastoreItem>"#
private let itemRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps" Target="itemProps1.xml"/></Relationships>"#
private let label = #"<?xml version="1.0" encoding="utf-8" standalone="yes"?><clbl:labelList xmlns:clbl="http://schemas.microsoft.com/office/2020/mipLabelMetadata"><clbl:label id="{aaaaaaaa-0000-0000-0000-000000000001}" enabled="1" method="Standard" siteId="{bbbbbbbb-0000-0000-0000-000000000002}" removed="0"/></clbl:labelList>"#
private let custom = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="ContentTypeId"><vt:lpwstr>0x0101</vt:lpwstr></property></Properties>"#

private let added: [(String, String)] = [
    ("customXml/item1.xml", item),
    ("customXml/itemProps1.xml", props),
    ("customXml/_rels/item1.xml.rels", itemRels),
    ("docMetadata/LabelInfo.xml", label),
    ("docProps/custom.xml", custom),
]

/// The sample deck, exported, with the custom XML, label and custom properties added.
private func deck() throws -> [UInt8] {
    let p = try #require(try IT.sample(), "sample")
    let bytes = try PPTX.export(p)
    // `replacen(at, "{add}{at}", 1)`.
    func edit(_ d: [UInt8], _ at: String, _ add: String) -> [UInt8] {
        Array(String(decoding: d, as: UTF8.self).replacen(at, "\(add)\(at)", 1).utf8)
    }
    var out = try IT.entries(bytes).map { e -> (name: String, data: [UInt8]) in
        switch e.name {
        case "[Content_Types].xml":
            (e.name, edit(
                e.data, "</Types>",
                #"<Override PartName="/customXml/itemProps1.xml" ContentType="application/vnd.openxmlformats-officedocument.customXmlProperties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/><Override PartName="/docMetadata/LabelInfo.xml" ContentType="application/vnd.ms-office.classificationlabels+xml"/>"#
            ))
        case "_rels/.rels":
            (e.name, edit(
                e.data, "</Relationships>",
                #"<Relationship Id="rIdL" Type="http://schemas.microsoft.com/office/2020/02/relationships/classificationlabels" Target="docMetadata/LabelInfo.xml"/><Relationship Id="rIdC" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/>"#
            ))
        case "ppt/_rels/presentation.xml.rels":
            (e.name, edit(
                e.data, "</Relationships>",
                #"<Relationship Id="rIdX" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml" Target="../customXml/item1.xml"/>"#
            ))
        default:
            e
        }
    }
    out += added.map { (name: $0.0, data: Array($0.1.utf8)) }
    return try IT.zip(out)
}

private func read(_ bytes: [UInt8], _ name: String) throws -> String {
    let d = try #require(IT.part(bytes, name), "\(name) missing")
    return String(decoding: d, as: UTF8.self)
}

@Suite struct IntegrationKeptPartsTests {
    // Rust: it/kept_parts.rs::custom_xml_label_and_custom_properties_survive_save
    @Test(.enabled(if: IT.hasCorpus, "needs the oracle corpus's sample deck"))
    func customXmlLabelAndCustomPropertiesSurviveSave() throws {
        let p = try PPTX.import(deck())
        #expect(p.keptParts.count == 5)
        let saved = try PPTX.export(p)
        for (n, d) in added {
            #expect(try read(saved, n) == d, "\(n)")
        }
        let ct = try read(saved, "[Content_Types].xml")
        #expect(ct.has("/docMetadata/LabelInfo.xml") && ct.has("customXmlProperties+xml") && ct.has("custom-properties+xml"))
        let root = try read(saved, "_rels/.rels")
        #expect(root.has("classificationlabels") && root.has(#"Target="docProps/custom.xml""#))
        #expect(try read(saved, "ppt/_rels/presentation.xml.rels").has(#"Target="../customXml/item1.xml""#))
        // And again: a second save keeps them once.
        let again = try PPTX.import(saved)
        #expect(again.keptParts == p.keptParts)
    }
}
