// DCRenderTests — whole-deck PDF export: pages and sizes, selection, metadata, the text layer, links,
// bookmarks and vector output. Ports deckcraft crates/pdf/src/tests.rs's export tests; the PDF is read
// back with CoreGraphics and PDFKit where deckcraft uses hayro.
import CoreGraphics
import DCGeometry
import DCModel
import DCText
import Foundation
import PDFKit
import Testing
@testable import DCRender

private func deck(_ n: Int) throws -> Presentation {
    var p = newPresentation(nil)
    let layout = p.slides[0].layout
    while p.slides.count < n {
        let s = try #require(newSlide(&p, layout))
        p.slides.append(s)
    }
    for i in p.slides.indices {
        if !p.slides[i].shapes.isEmpty { p.slides[i].shapes[0].text = TextBody.fromText("Slide title \(i)") }
        p.slides[i].notes = TextBody.fromText("Speaker notes that wrap across the page width to test line breaking of long notes.")
    }
    return p
}

private func opts(_ layout: PageLayout) -> PDFOptions {
    var o = PDFOptions()
    o.layout = layout
    o.dpi = 48
    return o
}

private func document(_ data: Data) throws -> CGPDFDocument {
    try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
}

private func infoString(_ doc: CGPDFDocument, _ key: String) -> String? {
    guard let info = doc.info else { return nil }
    var s: CGPDFStringRef?
    guard CGPDFDictionaryGetString(info, key, &s), let s else { return nil }
    return CGPDFStringCopyTextString(s) as String?
}

/// The page's `/Resources` sub-dictionary `key` and how many entries it has (0 when absent).
private func resourceCount(_ page: CGPDFPage, _ key: String, subtype: String? = nil) -> Int {
    guard let dict = page.dictionary else { return 0 }
    var res: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { return 0 }
    var sub: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(res, key, &sub), let sub else { return 0 }
    guard let subtype else { return CGPDFDictionaryGetCount(sub) }
    var n = 0
    CGPDFDictionaryApplyBlock(sub, { _, obj, _ in
        var s: CGPDFStreamRef?
        if CGPDFObjectGetValue(obj, .stream, &s), let s, let d = CGPDFStreamGetDictionary(s) {
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(d, "Subtype", &name), let name, String(cString: name) == subtype { n += 1 }
        }
        return true
    }, nil)
    return n
}

/// The URIs of the page's link annotations, and how many links it has in all.
private func links(_ page: CGPDFPage) -> (uris: [String], count: Int) {
    guard let dict = page.dictionary else { return ([], 0) }
    var annots: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, "Annots", &annots), let annots else { return ([], 0) }
    var uris: [String] = []
    let n = CGPDFArrayGetCount(annots)
    for i in 0 ..< n {
        var a: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annots, i, &a), let a else { continue }
        var action: CGPDFDictionaryRef?
        var uri: CGPDFStringRef?
        if CGPDFDictionaryGetDictionary(a, "A", &action), let action, CGPDFDictionaryGetString(action, "URI", &uri), let uri,
           let s = CGPDFStringCopyTextString(uri) as String? {
            uris.append(s)
        }
    }
    return (uris, n)
}

private func link(_ action: Action) -> Hyperlink {
    Hyperlink(action: action, tooltip: "Link", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
}

@Suite struct PDFExportTests {
    @Test func exportsSlidesNotesAndHandouts() throws {
        let p = try deck(5)
        let cases: [(PageLayout, Int, CGSize)] = [
            (.slides, 5, CGSize(width: 960, height: 540)),
            (.notes, 5, CGSize(width: 612, height: 792)),
            (.handouts(perPage: 3), 2, CGSize(width: 612, height: 792)),
            (.handouts(perPage: 6), 1, CGSize(width: 612, height: 792)),
        ]
        for (layout, pages, size) in cases {
            let data = try PDF.export(p, opts(layout))
            #expect(data.starts(with: Array("%PDF-".utf8)), "\(layout)")
            let doc = try document(data)
            #expect(doc.numberOfPages == pages, "\(layout)")
            for i in 1 ... doc.numberOfPages { #expect(doc.page(at: i)?.getBoxRect(.mediaBox).size == size, "\(layout)") }
        }
    }

    @Test func emptyRangeIsAnError() throws {
        let p = try deck(1)
        var o = opts(.slides)
        o.slides = [7]
        #expect(throws: PDFError.noPages) { try PDF.export(p, o) }
    }

    @Test func hiddenSlidesSkippedUnlessAsked() throws {
        var p = try deck(2)
        p.slides[1].hidden = true
        #expect(try document(PDF.export(p, opts(.slides))).numberOfPages == 1)
        var o = opts(.slides)
        o.includeHidden = true
        #expect(try document(PDF.export(p, o)).numberOfPages == 2)
        o = opts(.slides)
        o.slides = [1, 0, 9]
        #expect(try document(PDF.export(p, o)).numberOfPages == 2)
    }

    /// CoreGraphics writes its own Producer, so only the title, author and creator are checked.
    @Test func metadataRetainsValuesAndOmitsBlankFields() throws {
        var p = try deck(1)
        p.props.title = "  Deck title  "
        p.props.author = "  Author  "
        var doc = try document(PDF.export(p, opts(.slides)))
        #expect(infoString(doc, "Title") == "  Deck title  ")
        #expect(infoString(doc, "Author") == "  Author  ")
        #expect(infoString(doc, "Creator") == "DeckCraft")
        p.props.author = " "
        var o = opts(.slides)
        o.title = " "
        doc = try document(PDF.export(p, o))
        #expect(infoString(doc, "Title") == nil)
        #expect(infoString(doc, "Author") == nil)
    }

    @Test func textLayerLinksAndBookmarksSurviveSerialization() throws {
        var p = try deck(2)
        let last = p.slides[1].id
        let actions = [Action.url(url: "https://example.com/deck"), .slide(slide: last)]
        for (i, a) in actions.enumerated() where i < p.slides[0].shapes.count { p.slides[0].shapes[i].click = link(a) }
        for textLayer in [true, false] {
            var o = opts(.slides)
            o.textLayer = textLayer
            let doc = try document(PDF.export(p, o))
            let page = try #require(doc.page(at: 1))
            #expect(links(page).count == 2)
            #expect(links(page).uris == ["https://example.com/deck"])
            // Slide text is drawn as paths: fonts come only from the text layer.
            #expect((resourceCount(page, "Font") > 0) == textLayer, "text layer \(textLayer)")
            let outline = try #require(doc.outline as? [String: Any])
            let kids = try #require(outline[kCGPDFOutlineChildren as String] as? [[String: Any]])
            #expect(kids.compactMap { $0[kCGPDFOutlineTitle as String] as? String } == ["1. Slide title 0", "2. Slide title 1"])
        }
    }

    /// Links from an untrusted deck: only web and mail links become PDF links.
    @Test func unsafeURLLinksAreNotExported() throws {
        let safe = ["https://example.com/deck", "mailto:someone@example.com"]
        let refused = [
            "file:///C:/talks/notes.pdf", "notes.pdf", "ms-msdt:/id PCWDiagnostic /skip force",
            "ms-word:ofe|u|\\\\attacker.example\\share\\x.docx", "ldap://attacker.example/x",
            "file:///%5C%5Cattacker.example/share/x", "javascript:alert(1)", "\t JavaScript:alert(1)", "java\nscript:alert(1)",
            "vbscript:MsgBox(1)", "data:text/html,<script>alert(1)</script>", "\\\\attacker.example\\share\\x",
            "//attacker.example/share/x", "file://attacker.example/share/x", "file:////attacker.example/share/x",
            "smb://attacker.example/share/x", "search-ms:query=x&crumb=location:\\\\attacker.example\\share",
            "search:query=x&crumb=location:\\\\attacker.example\\share",
        ]
        var p = try deck(1)
        p.slides[0].shapes = (safe + refused).enumerated().map { i, url in
            var s = Shape.default
            s.id = ShapeId(UInt32(9000 + i))
            s.xfrm = Xfrm(20, 20 + 32 * Double(i), 400, 26)
            s.click = link(.url(url: url))
            return s
        }
        let page = try #require(document(PDF.export(p, opts(.slides))).page(at: 1))
        #expect(links(page).uris == safe)
    }

    /// The invisible text layer reads back as the slide's text (PDFKit's extraction goes through the
    /// font's ToUnicode map, as a reader's search and copy do).
    @Test func supportedUnicodeIsRecoveredFromThePageTextLayer() throws {
        let text = "Café Ελληνικά Привет"
        var body = TextBody.fromText(text)
        for pi in body.paragraphs.indices {
            for ri in body.paragraphs[pi].runs.indices {
                body.paragraphs[pi].runs[ri].props.font = "Inter"
                body.paragraphs[pi].runs[ri].props.size = 20
            }
        }
        var p = try deck(1)
        var s = Shape.default
        s.id = ShapeId(9001)
        s.xfrm = Xfrm(20, 20, 920, 100)
        s.text = body
        p.slides[0].shapes = [s]
        let runs = placeSlide(p, 0).texts.flatMap(\.layout.runs)
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { !$0.glyphs.isEmpty && $0.glyphs.allSatisfy { $0.gid != 0 } })
        let data = try PDF.export(p, opts(.slides))
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let got = (page.string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        #expect(got == text, "extracted: \(got.debugDescription)")
    }

    /// A plain deck's slides are vectors: no images on the page.
    @Test func plainSlidesAreVector() throws {
        let p = try deck(2)
        let doc = try document(PDF.export(p, opts(.slides)))
        for i in 1 ... doc.numberOfPages {
            let page = try #require(doc.page(at: i))
            #expect(resourceCount(page, "XObject", subtype: "Image") == 0)
        }
    }

    @Test func notesPagesAndHandoutsFollowTheirMastersAndPapers() throws {
        var p = try deck(3)
        p.notesSize = Size(612, 792)
        var m = Master.default
        var header = Shape.default
        header.xfrm = Xfrm(0, 0, 300, 30)
        header.ph = Placeholder(kind: .header)
        header.text = TextBody.fromText("Q3 review")
        m.shapes = [header]
        p.notesMaster = m
        p.handoutMaster = m
        for paper in PDF.papers {
            for landscape in [false, true] {
                let size = try #require(PDF.paperSize(paper.id, landscape: landscape))
                for layout in [PageLayout.notes, .handouts(perPage: 6)] {
                    var o = opts(layout)
                    o.paper = size
                    let data = try PDF.export(p, o)
                    let box = try #require(document(data).page(at: 1)?.getBoxRect(.mediaBox))
                    #expect(abs(box.width - size.0) < 0.01 && abs(box.height - size.1) < 0.01, "\(paper.id) \(landscape) \(layout)")
                    // The master's header is real, visible text.
                    #expect(PDFDocument(data: data)?.page(at: 0)?.string?.contains("Q3 review") == true, "\(paper.id) \(landscape) \(layout)")
                }
            }
        }
    }
}
