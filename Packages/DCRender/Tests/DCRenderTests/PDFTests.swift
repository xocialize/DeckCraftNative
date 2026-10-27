// DCRenderTests — PDF export: page plan, papers, notes and handout layout, master texts and the writer.
// Ports deckcraft crates/pdf/src/tests.rs where it doesn't need the renderer.
import CoreGraphics
import DCColor
import DCGeometry
import DCModel
import Foundation
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

private func ph(_ kind: PhType, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String) -> Shape {
    var s = Shape.default
    s.xfrm = Xfrm(x, y, w, h)
    s.ph = Placeholder(kind: kind)
    s.text = TextBody.fromText(text)
    return s
}

@Suite struct PDFTests {
    @Test func handoutBoxesFitThePaper() {
        for n: UInt8 in [1, 2, 3, 4, 6, 9] {
            let v = PDF.handoutBoxes(n, (612, 792), 16.0 / 9.0)
            #expect(v.count == Int(n))
            for r in v {
                #expect(r.x0 >= 0 && r.y0 >= 0 && r.x1 <= 612 && r.y1 <= 792, "\(n): \(r)")
                #expect(abs(r.width / r.height - 16.0 / 9.0) < 1e-6)
            }
            for (i, a) in v.enumerated() {
                for b in v[(i + 1)...] { #expect(a.intersect(b).area <= 0, "\(n): overlap") }
            }
        }
    }

    @Test func notesAndHandoutsFitAnyPaperAndOrientation() {
        for paper in PDF.papers {
            for landscape in [false, true] {
                let size = PDF.paperSize(paper.id.uppercased(), landscape: landscape)!
                #expect((size.0 > size.1) == landscape, "\(paper.id)")
                let b = PDF.notesSlideBox(size, 16.0 / 9.0)
                #expect(b.x0 >= 0 && b.x1 <= size.0 && b.y1 <= size.1 * 0.5, "\(paper.id) \(landscape): \(b)")
                #expect(abs(b.width / b.height - 16.0 / 9.0) < 1e-6)
                for n: UInt8 in [1, 3, 6, 9] {
                    for r in PDF.handoutBoxes(n, size, 16.0 / 9.0) {
                        #expect(r.x0 >= 0 && r.y0 >= 0 && r.x1 <= size.0 && r.y1 <= size.1, "\(paper.id) \(landscape) \(n): \(r)")
                    }
                }
            }
        }
        #expect(PDF.paperSize("bogus", landscape: false) == nil)
    }

    @Test func pagePlanAndSelection() throws {
        var p = try deck(5)
        p.slides[1].hidden = true
        var o = PDFOptions()
        #expect(PDF.selectedSlides(p, o) == [0, 2, 3, 4])
        o.includeHidden = true
        #expect(PDF.selectedSlides(p, o) == [0, 1, 2, 3, 4])
        o.slides = [1, 0, 9]
        #expect(PDF.selectedSlides(p, o) == [1, 0])
        o.slides = [7]
        #expect(PDF.selectedSlides(p, o).isEmpty)
        o = PDFOptions()
        o.layout = .handouts(perPage: 3)
        let pages = PDF.planPages(p, o, [0, 1, 2, 3, 4], 960, 540)
        #expect(pages.map(\.count) == [3, 2])
        o.layout = .notes
        #expect(PDF.planPages(p, o, [0, 1], 960, 540).map(\.count) == [1, 1])
        #expect(PDF.bookmark(p, 0) == "1. Slide title 0")
    }

    @Test func notesPagesAndHandoutsFollowTheirMasters() throws {
        var p = try deck(2)
        let paper = (612.0, 792.0)
        let (slide0, notes0) = PDF.notesFrames(p, paper)
        #expect((slide0.x0, slide0.y0) == (72, 54))
        #expect(notes0.y0 > slide0.y1)
        p.notesSize = Size(612, 792)
        var m = Master.default
        m.shapes = [
            ph(.slideImage, 100, 400, 412, 300, ""),
            ph(.body, 50, 50, 500, 300, ""),
            ph(.header, 0, 0, 300, 30, "Q3 review"),
            ph(.date, 312, 0, 300, 30, ""),
            ph(.slideNum, 312, 760, 300, 30, "<#>"),
        ]
        p.notesMaster = m
        let (slide, notes) = PDF.notesFrames(p, paper)
        #expect(slide.y0 >= 400 && slide.y1 <= 700 + 1e-6 && slide.x0 >= 100 - 1e-6, "\(slide)")
        #expect(abs(slide.width / slide.height - p.slideSize.width / p.slideSize.height) < 1e-6)
        #expect(notes == Rect(50, 50, 550, 350))
        let texts = PDF.masterTexts(p, m, paper, 7)
        #expect(texts.map(\.text) == ["Q3 review", "7"], "empty date left out, number is the page")
        #expect(texts.map(\.right) == [false, true])
    }

    @Test func masterTextKeepsItsOwnFormatting() throws {
        var p = try deck(1)
        p.notesSize = Size(612, 792)
        var header = ph(.header, 0, 0, 300, 30, "Board pack")
        var props = RunProps.default
        props.size = 20
        props.bold = true
        props.fill = .solid(color: ColorRef.rgb(Rgba.rgb(200, 0, 0)))
        props.font = "+mj-lt"
        header.text?.paragraphs[0].runs[0].props = props
        var m = Master.default
        m.shapes = [header, ph(.footer, 0, 760, 300, 30, "plain")]
        let texts = PDF.masterTexts(p, m, (612, 792), 1)
        let st = texts[0].style
        #expect(st.size == 20 && st.bold && !st.italic && st.color == Rgba.rgb(200, 0, 0))
        #expect(st.family == m.theme.font("+mj-lt"), "theme font resolved")
        let half = PDF.masterTexts(p, m, (306, 396), 1)
        #expect(abs(half[0].style.size - 10) < 1e-9)
        #expect(texts[1].style.size > 0 && !texts[1].style.bold)
    }

    @Test func rasterScaleCapsTotalPixelsNotEachSide() {
        let s = PDF.rasterScale(20_000, (20_000, 20_000), 600)
        #expect(20_000 * s * 20_000 * s <= PDF.maxRasterPixels * 1.0001)
        let n = PDF.rasterScale(720, (960, 540), 200)
        #expect(abs(n - 720.0 / 72 * 200 / 960) < 1e-12)
    }

    /// The writer: page sizes, metadata, a bookmark per page, internal and web links.
    @Test func writerPagesOutlineAndLinks() throws {
        let w = try #require(PDFWriter(title: "  Deck title  ", author: "  "))
        for i in 0 ..< 3 {
            w.beginPage(960, 540)
            w.ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            w.ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 50))
            if i == 0 {
                w.link(Rect(10, 10, 110, 60), page: 2)
                w.link(Rect(200, 10, 300, 60), url: URL(string: "https://example.com/")!)
            }
            w.bookmark("\(i + 1). Slide", page: i)
            w.endPage()
        }
        let data = w.finish()
        #expect(data.starts(with: Array("%PDF-".utf8)))
        let doc = try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        #expect(doc.numberOfPages == 3)
        #expect(doc.page(at: 1)?.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 960, height: 540))
        let outline = try #require(doc.outline as? [String: Any])
        let kids = try #require(outline[kCGPDFOutlineChildren as String] as? [[String: Any]])
        #expect(kids.compactMap { $0[kCGPDFOutlineTitle as String] as? String } == ["1. Slide", "2. Slide", "3. Slide"])
        let info = try #require(doc.info)
        var title: CGPDFStringRef?
        #expect(CGPDFDictionaryGetString(info, "Title", &title))
        #expect(title.flatMap { CGPDFStringCopyTextString($0) as String? } == "  Deck title  ")
        var author: CGPDFStringRef?
        #expect(!CGPDFDictionaryGetString(info, "Author", &author), "blank author omitted")
        // Page 1 carries two link annotations.
        var annots: CGPDFArrayRef?
        let page = try #require(doc.page(at: 1)?.dictionary)
        #expect(CGPDFDictionaryGetArray(page, "Annots", &annots))
        #expect(annots.map(CGPDFArrayGetCount) == 2)
    }
}
