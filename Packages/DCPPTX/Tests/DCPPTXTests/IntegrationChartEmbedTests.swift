// Port of deckcraft crates/pptx/tests/it/chart_embed.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): an unchanged chart keeps the embedded workbook its `c:externalData` points
// at (#335).
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

private let workbook = Array("chart-workbook-bytes-v1".utf8)
private let embed = "ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx"
private let rt = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

/// A one-slide deck (Blank layout) holding a chart of `kind` named "Pie", unexported.
private func chartDeck(_ kind: ChartType) throws -> Presentation {
    var p = newPresentation(nil)
    p.slides.removeAll()
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    var slide = try #require(newSlide(&p, layout), "slide")
    var shape = IT.shape(&p, "Pie", 40, 40, 400, 300)
    shape.kind = .chart(Chart.sample(kind))
    slide.shapes.append(shape)
    p.slides.append(slide)
    return p
}

private func chartPPTX() throws -> [UInt8] {
    try PPTX.export(chartDeck(.pie))
}

/// Add an embedded workbook and point the chart part at it, the way PowerPoint writes a chart.
private func withWorkbook(_ bytes: [UInt8]) throws -> [UInt8] {
    var out: [(name: String, data: [UInt8])] = []
    var chartPart: String?
    for (name, d) in try IT.entries(bytes) {
        var data = d
        if name.hasPrefix("ppt/charts/chart"), name.hasSuffix(".xml"), !name.has("_rels") {
            let xml = String(decoding: data, as: UTF8.self)
            #expect(xml.has("</c:chartSpace>"), "\(name)")
            data = Array(xml.replacen("</c:chartSpace>", #"<c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>"#, 1).utf8)
            chartPart = name
        } else if name == "[Content_Types].xml" {
            let xml = String(decoding: data, as: UTF8.self)
            data = Array(xml.replacen(
                "</Types>",
                #"<Override PartName="/ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"/></Types>"#,
                1
            ).utf8)
        }
        out.append((name, data))
    }
    let part = try #require(chartPart, "chart part")
    let file = part.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "chart1.xml"
    let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/package" Target="../embeddings/Microsoft_Excel_Worksheet1.xlsx"/><Relationship Id="rIdBad" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide1.xml"/></Relationships>
    """
    out.append(("ppt/charts/_rels/\(file).rels", Array(relsXML.utf8)))
    out.append((embed, workbook))
    return try IT.zip(out)
}

private func chartOf(_ bytes: [UInt8]) throws -> Chart {
    let p = try PPTX.import(bytes)
    for s in p.slides.flatMap(\.shapes) {
        if case let .chart(c) = s.kind, s.name == "Pie" { return c }
    }
    Issue.record("pie chart")
    throw PPTXError.notPptx("no pie chart")
}

/// Rewrite `src`: `edit` may change any entry (name, bytes → new bytes), then `extra` entries are added.
private func rewrite(_ src: [UInt8], _ edit: (String, [UInt8]) -> [UInt8], _ extra: [(String, [UInt8])]) throws -> [UInt8] {
    var out = try IT.entries(src).map { (name: $0.name, data: edit($0.name, $0.data)) }
    out += extra.map { (name: $0.0, data: $0.1) }
    return try IT.zip(out)
}

private func uniqueNames(_ parts: [(name: String, data: [UInt8])]) {
    var seen = Set<[UInt8]>()
    for (n, _) in parts {
        // `to_ascii_lowercase`, compared byte-wise.
        let key = n.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
        #expect(seen.insert(key).inserted, "duplicate zip entry \(n)")
    }
}

private func textOf(_ parts: [(name: String, data: [UInt8])], _ name: String) throws -> String {
    let d = try #require(parts.first { $0.name == name }?.data, "no \(name)")
    return String(decoding: d, as: UTF8.self)
}

@Suite struct IntegrationChartEmbedTests {
    // Rust: it/chart_embed.rs::an_unchanged_chart_keeps_its_embedded_workbook
    @Test func anUnchangedChartKeepsItsEmbeddedWorkbook() throws {
        let src = try withWorkbook(chartPPTX())
        let chart = try chartOf(src)
        #expect(chart.kept.parts.filter { $0.name == embed }.count == 1)
        #expect(chart.kept.parts.first { $0.name == embed }?.bytes == workbook)

        let saved = try PPTX.export(PPTX.import(src))
        let savedParts = try IT.entries(saved)
        // Kept parts are written under fresh names, so they can't land on a part the writer makes.
        let wb = savedParts.first { $0.name == "ppt/embeddings/kept1.xlsx" }?.data
        #expect(wb == workbook, "the embedding part is dropped on save")
        let relsData = try #require(
            savedParts.first { $0.name.hasPrefix("ppt/charts/_rels/chart") && $0.name.hasSuffix(".xml.rels") }?.data, "chart relationships"
        )
        let rels = String(decoding: relsData, as: UTF8.self)
        #expect(rels.has(#"Id="rId1""#) && rels.has("../embeddings/kept1.xlsx"), "\(rels)")
        #expect(!rels.has("slide1.xml"), "a chart relationship must not replace the slide: \(rels)")
        let slideData = try #require(savedParts.first { $0.name == "ppt/slides/slide1.xml" }?.data, "slide")
        let slide = String(decoding: slideData, as: UTF8.self)
        #expect(slide.has("sld"), "\(slide)")
        #expect(!String(decoding: slideData, as: UTF8.self).has(String(decoding: workbook, as: UTF8.self)))
        let xmlData = try #require(savedParts.first { $0.name.hasPrefix("ppt/charts/chart") && $0.name.hasSuffix(".xml") }?.data, "chart xml")
        let xml = String(decoding: xmlData, as: UTF8.self)
        #expect(xml.has("externalData"), "\(xml)")
    }

    // Rust: it/chart_embed.rs::an_edited_chart_does_not_write_a_stale_workbook
    @Test func anEditedChartDoesNotWriteAStaleWorkbook() throws {
        let src = try withWorkbook(chartPPTX())
        var p = try PPTX.import(src)
        try #require(!p.slides.isEmpty, "slide")
        let i = try #require(p.slides[0].shapes.firstIndex { s in
            if case .chart = s.kind { return s.name == "Pie" }
            return false
        }, "pie")
        guard case var .chart(chart) = p.slides[0].shapes[i].kind else { return }
        try #require(!chart.series.isEmpty && !chart.series[0].values.isEmpty, "value")
        chart.series[0].values[0] = 99.0
        p.slides[0].shapes[i].kind = .chart(chart)
        let saved = try IT.entries(PPTX.export(p))
        #expect(saved.allSatisfy { !$0.name.hasPrefix("ppt/embeddings/") }, "a stale workbook was written after the chart changed")
        let xmlData = try #require(saved.first { $0.name.hasPrefix("ppt/charts/chart") && $0.name.hasSuffix(".xml") }?.data, "chart xml")
        let xml = String(decoding: xmlData, as: UTF8.self)
        #expect(!xml.has("externalData"), "\(xml)")
    }

    /// A chart whose relationships reach parts named like the ones the writer generates
    /// (`ppt/media/image1.png`, `ppt/drawings/…`) must not collide with them on save: no duplicate
    /// zip entries, and the slide's own picture keeps its bytes.
    // Rust: it/chart_embed.rs::kept_chart_parts_never_collide_with_written_parts
    @Test func keptChartPartsNeverCollideWithWrittenParts() throws {
        let picture = IT.png(4, 4, (10, 200, 30))
        var p = newPresentation(nil)
        p.slides.removeAll()
        let imgAdded = p.addMedia("image1.png", "image/png", picture)
        let img = try #require(imgAdded, "media")
        let layout = layoutOfKind(p, .blank) ?? LayoutId.default
        var slide = try #require(newSlide(&p, layout), "slide")
        // The chart comes first, so its kept parts are written before the picture.
        var chart = IT.shape(&p, "Pie", 40, 40, 400, 300)
        chart.kind = .chart(Chart.sample(.pie))
        slide.shapes.append(chart)
        var pic = IT.shape(&p, "Pic", 500, 40, 80, 80)
        pic.kind = .picture(fill: PictureFill(media: img))
        slide.shapes.append(pic)
        p.slides.append(slide)
        let base = try PPTX.export(p)
        #expect(try IT.entries(base).contains { $0.name == "ppt/media/image1.png" && $0.data == picture })

        // The chart's own relationships reach the slide picture's part and a drawing whose
        // relationships reach it too (and, hostile, the slide).
        let chartRels = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/package" Target="../embeddings/Microsoft_Excel_Worksheet1.xlsx"/><Relationship Id="rId2" Type="\#(rt)/chartUserShapes" Target="../drawings/drawing1.xml"/><Relationship Id="rId3" Type="\#(rt)/image" Target="../media/image1.png"/></Relationships>"#
        let drawingRels = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/image" Target="../media/image1.png"/><Relationship Id="rId2" Type="\#(rt)/slide" Target="../slides/slide1.xml"/></Relationships>"#
        let drawing = Array(#"<c:userShapes xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"/>"#.utf8)
        let src = try rewrite(
            base,
            { name, data in
                guard name.hasPrefix("ppt/charts/chart"), name.hasSuffix(".xml") else { return data }
                return Array(String(decoding: data, as: UTF8.self)
                    .replacen("</c:chartSpace>", #"<c:externalData r:id="rId1"/><c:userShapes r:id="rId2"/></c:chartSpace>"#, 1).utf8)
            },
            [
                ("ppt/charts/_rels/chart1.xml.rels", Array(chartRels.utf8)),
                ("ppt/drawings/drawing1.xml", drawing),
                ("ppt/drawings/_rels/drawing1.xml.rels", Array(drawingRels.utf8)),
                (embed, workbook),
            ]
        )

        let saved = try IT.entries(PPTX.export(PPTX.import(src)))
        uniqueNames(saved)
        let pictureParts = saved.filter { $0.data == picture }.map(\.name)
        #expect(pictureParts.contains("ppt/media/image1.png"), "\(pictureParts)")
        let slideRels = try textOf(saved, "ppt/slides/_rels/slide1.xml.rels")
        #expect(slideRels.has("../media/image1.png"), "\(slideRels)")

        // The chart's relationships point at the renamed parts, which hold the kept bytes.
        let rels = try textOf(saved, "ppt/charts/_rels/chart1.xml.rels")
        #expect(!rels.has("image1.png") && !rels.has("drawing1.xml") && !rels.has("Worksheet1"), "\(rels)")
        func target(_ rels: String, _ id: String) throws -> String {
            let at = try #require(rels.byteFind(#"Id="\#(id)""#), "\(id) in \(rels)")
            let rest = rels.bytes(at)
            let t = try #require(rest.byteFind(#"Target=""#), "target") + 8
            let tail = rest.bytes(t)
            return tail.bytes(0, tail.byteFind("\"") ?? tail.utf8.count)
        }
        // `format!("ppt/{}", t.trim_start_matches("../").trim_start_matches(""))`.
        func resolve(_ t: String) -> String {
            var t = t
            while t.hasPrefix("../") { t = t.bytes(3) }
            return "ppt/\(t)"
        }
        let imgPart = try resolve(target(rels, "rId3"))
        #expect(imgPart.hasPrefix("ppt/media/kept"), "\(imgPart)")
        #expect(saved.contains { $0.name == imgPart && $0.data == picture }, "\(imgPart)")
        let drawingPart = try resolve(target(rels, "rId2"))
        #expect(saved.contains { $0.name == drawingPart && $0.data == drawing }, "\(drawingPart)")
        let wb = try resolve(target(rels, "rId1"))
        #expect(saved.contains { $0.name == wb && $0.data == workbook }, "\(wb)")

        // The drawing's own relationships follow the rename; the one to the slide is dropped.
        let file = drawingPart.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let drels = try textOf(saved, "ppt/drawings/_rels/\(file).rels")
        #expect(try resolve(target(drels, "rId1")) == imgPart, "\(drels)")
        #expect(!drels.has("slide"), "\(drels)")

        // And the result reads back with the same kept parts.
        let again = try PPTX.export(PPTX.import(IT.zip(saved)))
        uniqueNames(try IT.entries(again))
    }

    /// An unchanged Office 2016 chart keeps its embedded workbook too; its plain-chart fallback
    /// carries none.
    // Rust: it/chart_embed.rs::an_unchanged_chartex_keeps_its_embedded_workbook
    @Test func anUnchangedChartexKeepsItsEmbeddedWorkbook() throws {
        let base = try PPTX.export(chartDeck(.waterfall))
        #expect(try IT.entries(base).contains { $0.name == "ppt/charts/chartEx1.xml" })
        let rels = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rt)/package" Target="../embeddings/Microsoft_Excel_Worksheet1.xlsx"/></Relationships>"#
        let src = try rewrite(
            base,
            { name, data in
                guard name == "ppt/charts/chartEx1.xml" else { return data }
                return Array(String(decoding: data, as: UTF8.self)
                    .replacen("<cx:chartData>", #"<cx:chartData><cx:externalData r:id="rId1" cx:autoUpdate="0"/>"#, 1).utf8)
            },
            [("ppt/charts/_rels/chartEx1.xml.rels", Array(rels.utf8)), (embed, workbook)]
        )
        let chart = try chartOf(src)
        #expect(chart.kind == .waterfall)
        #expect(chart.kept.parts.contains { $0.bytes == workbook })

        let saved = try IT.entries(PPTX.export(PPTX.import(src)))
        uniqueNames(saved)
        let xml = try textOf(saved, "ppt/charts/chartEx1.xml")
        #expect(xml.has("externalData"), "\(xml)")
        let savedRels = try textOf(saved, "ppt/charts/_rels/chartEx1.xml.rels")
        #expect(savedRels.has("../embeddings/kept1.xlsx"), "\(savedRels)")
        #expect(saved.contains { $0.name == "ppt/embeddings/kept1.xlsx" && $0.data == workbook })
        #expect(saved.allSatisfy { $0.name != "ppt/charts/_rels/chart1.xml.rels" }, "the fallback chart has no workbook")
        #expect(!(try textOf(saved, "ppt/charts/chart1.xml")).has("externalData"))
    }
}
