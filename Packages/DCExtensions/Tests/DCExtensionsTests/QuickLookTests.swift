// DCExtensionsTests — the Quick Look preview and thumbnail over the oracle corpus and damaged files.
import CoreGraphics
import DCEngine
import DCTestSupport
@testable import DCExtensionKit
import DCModel
@testable import DCQuickLook
import DCZip
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@Suite struct QuickLookPreviewTests {
    /// Every corpus deck previews as a PDF with a page per slide, titled with its title or file name (the
    /// `.from-pptx` copies are the same decks again, left to the thumbnail and Spotlight tests).
    @Test func corpusDecksPreviewEverySlide() throws {
        let files = Corpus.files().filter { !$0.lastPathComponent.contains(".from-pptx") }
        try #require(!files.isEmpty, "the oracle corpus is missing")
        for url in files {
            let preview = QuickLookPreview.make(fileAt: url)
            guard case .pdf(let data, let size) = preview.body else {
                Issue.record("\(url.lastPathComponent): no PDF")
                continue
            }
            let pdf = try #require(PDFDocument(data: data))
            if let titles = Corpus.titles(Corpus.stem(url)) {
                #expect(pdf.pageCount == titles.count, "\(url.lastPathComponent)")
            }
            #expect(pdf.pageCount == preview.slides && preview.pages == preview.slides, "\(url.lastPathComponent)")
            #expect(size == CGSize(width: 960, height: 540))
            #expect(!preview.title.isEmpty)
        }
    }

    @Test func titleIsTheDocumentsOrTheFileName() throws {
        let dir = try #require(Corpus.decks)
        #expect(QuickLookPreview.make(fileAt: dir.appending(path: "review.pptx")).title == "Review deck")
        #expect(QuickLookPreview.make(fileAt: dir.appending(path: "shapes.pptx")).title == "shapes")
    }

    /// The PDF is vector with the text layer: its words can be found and selected.
    @Test func previewTextIsSearchable() throws {
        let preview = QuickLookPreview.make(fileAt: try #require(Corpus.decks).appending(path: "sample.pptx"))
        guard case .pdf(let data, _) = preview.body else { throw Failure("no PDF") }
        let text = try #require(PDFDocument(data: data)?.string)
        #expect(text.contains("Northern Lights"))
        #expect(text.contains("Field checklist"))
    }

    /// Templates and slide shows are the same package; the preview reads them by content.
    @Test func templatesAndSlideShowsPreview() throws {
        let src = try #require(Corpus.decks).appending(path: "review.pptx")
        let doc = try FileCommands.openPresentation("review.pptx", [UInt8](Data(contentsOf: src)))
        let scratch = try Scratch()
        for format in ["potx", "ppsx"] {
            let url = try scratch.write("review.\(format)", try FileCommands.saveBytes(doc, format))
            let preview = QuickLookPreview.make(fileAt: url)
            guard case .pdf(let data, _) = preview.body else {
                Issue.record("\(format): no PDF")
                continue
            }
            #expect(PDFDocument(data: data)?.pageCount == 5)
            #expect(preview.title == "Review deck")
        }
    }

    @Test func longDecksShowTheirFirstSlides() throws {
        let preview = QuickLookPreview.make(fileAt: try #require(Corpus.decks).appending(path: "review.deckcraft"), maxSlides: 2)
        guard case .pdf(let data, _) = preview.body else { throw Failure("no PDF") }
        #expect(PDFDocument(data: data)?.pageCount == 2)
        #expect(preview.pages == 2 && preview.slides == 5)
        #expect(preview.title == "Review deck (first 2 of 5 slides)")
    }

    /// A file over the whole-file limit is previewed from its text parts, and says so.
    @Test func largeFilesPreviewWithoutPictures() throws {
        let limits = DeckLimits(maxFileBytes: 0, maxPartBytes: 1 << 20, maxTextBytes: 8 << 20)
        let preview = QuickLookPreview.make(fileAt: try #require(Corpus.decks).appending(path: "motion.pptx"), limits: limits)
        guard case .pdf(let data, _) = preview.body else { throw Failure("no PDF") }
        #expect(PDFDocument(data: data)?.pageCount == 4)
        #expect(preview.title == "motion (without pictures)")
    }

    /// Damaged and foreign files get a page that names the file and says why; nothing throws or traps.
    @Test func damagedFilesShowAMessage() throws {
        let scratch = try Scratch()
        for url in try scratch.damaged() {
            let preview = QuickLookPreview.make(fileAt: url)
            guard case .html(let data) = preview.body else {
                Issue.record("\(url.lastPathComponent): previewed")
                continue
            }
            let page = String(decoding: data, as: UTF8.self)
            #expect(page.contains(url.lastPathComponent), "\(url.lastPathComponent)")
            #expect(preview.pages == 0)
        }
    }

    @Test func messagePagesEscapeText() {
        let page = String(decoding: QuickLookPreview.messagePage("<b>&", "\"x\""), as: UTF8.self)
        #expect(page.contains("&lt;b&gt;&amp;"))
        #expect(page.contains("&quot;x&quot;"))
        #expect(!page.contains("<b>&"))
    }

    @Test func emptyDecksSayTheyHaveNoSlides() throws {
        var file = try DeckReader.read(try #require(Corpus.decks).appending(path: "review.deckcraft"), limits: .preview, orText: false)
        file.presentation.slides = []
        let preview = QuickLookPreview.make(file)
        guard case .html(let data) = preview.body else { throw Failure("previewed") }
        #expect(String(decoding: data, as: UTF8.self).contains("has no slides"))
    }
}

@Suite struct QuickLookThumbnailTests {
    @Test func contextSizeFitsTheRequest() {
        #expect(QuickLookThumbnail.contextSize(aspect: (960, 540), maximum: CGSize(width: 512, height: 512)) == CGSize(width: 512, height: 288))
        #expect(QuickLookThumbnail.contextSize(aspect: (540, 960), maximum: CGSize(width: 512, height: 512)) == CGSize(width: 288, height: 512))
        #expect(QuickLookThumbnail.contextSize(aspect: (720, 540), maximum: CGSize(width: 64, height: 64)) == CGSize(width: 64, height: 48))
        // Hostile sizes fall back rather than trap.
        let odd = QuickLookThumbnail.contextSize(aspect: (.nan, -1), maximum: CGSize(width: CGFloat.infinity, height: 0))
        #expect(odd.width >= 1 && odd.height >= 1 && odd.width.isFinite)
    }

    @Test func pixelSizeIsBounded() {
        #expect(QuickLookThumbnail.pixelSize(CGSize(width: 512, height: 288), scale: 2) == (1024, 576))
        let (w, h) = QuickLookThumbnail.pixelSize(CGSize(width: 4096, height: 2304), scale: 2)
        #expect(w == QuickLookThumbnail.maxPixelSide && h == 1152)
        #expect(QuickLookThumbnail.pixelSize(CGSize(width: 10, height: 10), scale: .nan) == (10, 10))
    }

    /// Every corpus deck's thumbnail is its first slide at the size asked, and isn't blank.
    @Test func corpusDecksThumbnailTheirFirstSlide() throws {
        let files = Corpus.files()
        try #require(!files.isEmpty, "the oracle corpus is missing")
        for url in files {
            let t = try #require(QuickLookThumbnail.make(fileAt: url, maximumSize: CGSize(width: 512, height: 512), scale: 1), "\(url.lastPathComponent)")
            #expect(t.contextSize == CGSize(width: 512, height: 288))
            #expect(t.image.width == 512 && t.image.height == 288, "\(url.lastPathComponent)")
            #expect(t.source == .slide(textOnly: false))
        }
        // Most corpus decks open on an empty title slide (blank in the oracle's render too); these two don't.
        let dir = try #require(Corpus.decks)
        for name in ["sample.pptx", "review.deckcraft"] {
            let t = try #require(QuickLookThumbnail.make(fileAt: dir.appending(path: name), maximumSize: CGSize(width: 512, height: 512), scale: 1))
            #expect(distinctColours(t.image) > 1, "\(name) is blank")
        }
    }

    /// The thumbnail is the slide the oracle draws: each deck's first slide at the oracle's size, by SSIMULACRA2.
    @Test func thumbnailsMatchTheOracle() throws {
        let dir = try #require(Corpus.decks)
        for name in ["sample", "review", "content", "charts", "text"] {
            let oracle = try #require(RenderParity.load(dir.appending(path: "\(name).render/slide-01.png")))
            // At a quarter of the oracle's 1920 × 1080: a thumbnail's size, and a quick comparison.
            let reference = try #require(Self.scaled(oracle, 480, 270))
            let size = CGSize(width: 480, height: 270)
            let t = try #require(QuickLookThumbnail.make(fileAt: dir.appending(path: "\(name).deckcraft"), maximumSize: size, scale: 1))
            #expect(t.image.width == reference.width && t.image.height == reference.height)
            let score = try #require(RenderParity.score(reference: reference, distorted: t.image))
            // A downscaled reference against a direct render: text antialiasing differs; ~70 is "high quality".
            #expect(score > 70, "\(name): SSIMULACRA2 \(score)")
        }
    }

    /// Drawn the way Quick Look asks: a bitmap context of the context size times the scale.
    @Test func drawsIntoQuickLooksContext() throws {
        let url = try #require(Corpus.decks).appending(path: "sample.pptx")
        let t = try #require(QuickLookThumbnail.make(fileAt: url, maximumSize: CGSize(width: 256, height: 256), scale: 2))
        #expect(t.image.width == 512 && t.image.height == 288)
        let ctx = try #require(CGContext(
            data: nil, width: 512, height: 288, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.scaleBy(x: 2, y: 2)
        #expect(t.draw(in: ctx))
        let drawn = try #require(ctx.makeImage())
        #expect(distinctColours(drawn) > 1)
    }

    /// Too large to read whole and without a package picture: the first slide without its pictures.
    @Test func largeFilesThumbnailFromTheirText() throws {
        let limits = DeckLimits(maxFileBytes: 0, maxPartBytes: 1 << 20, maxTextBytes: 8 << 20)
        let url = try #require(Corpus.decks).appending(path: "sample.pptx")
        let t = try #require(QuickLookThumbnail.make(fileAt: url, maximumSize: CGSize(width: 256, height: 256), scale: 1, limits: limits))
        #expect(t.source == .slide(textOnly: true))
        #expect(t.image.width == 256)
    }

    /// A package that carries a picture of its first slide gives it when the file is too large or damaged.
    @Test func packagePictureStandsIn() throws {
        let scratch = try Scratch()
        let src = try [UInt8](Data(contentsOf: try #require(Corpus.decks).appending(path: "review.pptx")))
        let jpeg = try #require(Self.jpeg(320, 180))
        let withThumb = try scratch.write("thumb.pptx", try Self.addThumbnail(src, jpeg, damage: false))
        let limits = DeckLimits(maxFileBytes: 0, maxPartBytes: 1 << 20, maxTextBytes: 8 << 20)
        let big = try #require(QuickLookThumbnail.make(fileAt: withThumb, maximumSize: CGSize(width: 512, height: 512), scale: 1, limits: limits))
        #expect(big.source == .embedded)
        #expect(big.contextSize == CGSize(width: 512, height: 288))
        let broken = try scratch.write("broken.pptx", try Self.addThumbnail(src, jpeg, damage: true))
        #expect(QuickLookThumbnail.make(fileAt: broken, maximumSize: CGSize(width: 128, height: 128), scale: 1)?.source == .embedded)
        // Read whole, the slide wins over the package's picture.
        #expect(QuickLookThumbnail.make(fileAt: withThumb, maximumSize: CGSize(width: 128, height: 128), scale: 1)?.source == .slide(textOnly: false))
    }

    @Test func damagedFilesHaveNoThumbnail() throws {
        let scratch = try Scratch()
        for url in try scratch.damaged() {
            #expect(QuickLookThumbnail.make(fileAt: url, maximumSize: CGSize(width: 256, height: 256), scale: 2) == nil, "\(url.lastPathComponent)")
        }
    }

    @Test func emptyDecksThumbnailABlankPage() throws {
        var file = try DeckReader.read(try #require(Corpus.decks).appending(path: "review.deckcraft"), limits: .thumbnail, orText: false)
        file.presentation.slides = []
        let t = try #require(QuickLookThumbnail.make(file, maximumSize: CGSize(width: 64, height: 64), scale: 1))
        #expect(t.source == .blank && t.image.width == 64 && t.image.height == 36)
    }

    @Test func thumbnailRelationshipIsFollowed() {
        let rels = """
            <Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" Target="/docProps/thumb.png"/></Relationships>
            """
        #expect(DeckReader.thumbnailTarget(rels) == "docProps/thumb.png")
        #expect(DeckReader.thumbnailTarget(rels.replacingOccurrences(of: "/docProps/thumb.png", with: "../x.png")) == nil)
        #expect(DeckReader.thumbnailTarget("<Relationships/>") == nil)
    }

    // MARK: Helpers

    /// How many different colours a picture has (sampled).
    func distinctColours(_ img: CGImage) -> Int {
        guard let ctx = CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt32.self, capacity: img.width * img.height)
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: img.width * img.height, by: 7) { seen.insert(px[i]) }
        return seen.count
    }

    static func scaled(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func jpeg(_ w: Int, _ h: Int) -> [UInt8]? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }

    /// `pptx` with `docProps/thumbnail.jpeg` (and its relationship); `damage` empties its slide parts.
    static func addThumbnail(_ pptx: [UInt8], _ jpeg: [UInt8], damage: Bool) throws -> [UInt8] {
        let r = try ZipReader(pptx)
        var w = ZipWriter()
        for e in r.entries {
            var data = try r.read(e, max: 64 << 20)
            if e.name == "_rels/.rels" {
                data = Array(String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: "</Relationships>",
                    with: "<Relationship Id=\"rIdT\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail\" Target=\"docProps/thumbnail.jpeg\"/></Relationships>"
                ).utf8)
            }
            if damage, e.name.hasPrefix("ppt/") { data = [] }
            if damage, e.name == "[Content_Types].xml" { continue }
            try w.add(e.name, data)
        }
        try w.add("docProps/thumbnail.jpeg", jpeg, compress: false)
        return try w.finish()
    }
}

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}
