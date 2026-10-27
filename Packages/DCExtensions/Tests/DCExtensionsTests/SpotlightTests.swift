// DCExtensionsTests — what Spotlight indexes, over the oracle corpus and damaged files.
import CoreSpotlight
import DCCore
@testable import DCExtensionKit
import DCModel
@testable import DCSpotlight
import DCZip
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct SpotlightTests {
    /// Every corpus deck indexes its slide count and its slides' titles as the oracle recorded them.
    @Test func corpusDecksIndexTheirSlides() throws {
        let files = Corpus.files()
        try #require(!files.isEmpty, "the oracle corpus is missing")
        for url in files {
            let index = try DeckIndex.make(fileAt: url)
            let titles = try #require(Corpus.titles(Corpus.stem(url)), "\(url.lastPathComponent)")
            #expect(index.slideCount == titles.count, "\(url.lastPathComponent)")
            #expect(index.slideTitles == titles, "\(url.lastPathComponent)")
            #expect(index.slideSize == CGSize(width: 960, height: 540))
        }
    }

    /// The review deck: properties, notes, comments with their replies and authors, slide text.
    @Test func reviewDeckIndexesPropertiesNotesAndComments() throws {
        let dir = try #require(Corpus.decks)
        for name in ["review.pptx", "review.deckcraft"] {
            let index = try DeckIndex.make(fileAt: dir.appending(path: name))
            #expect(index.title == "Review deck", "\(name)")
            #expect(index.subject == "Corpus", "\(name)")
            #expect(index.authors == ["Oracle"], "\(name)")
            #expect(index.keywords == ["pptx review"], "\(name)")
            #expect(index.slideCount == 5)
            #expect(index.notes.contains { $0.contains("Opening notes.") && $0.contains("Second paragraph of notes.") }, "\(name)")
            #expect(index.comments == ["Check the title", "Done"], "\(name)")
            #expect(index.commentAuthors == ["Presenter"], "\(name)")
            #expect(index.slideText.contains("With notes and comments"), "\(name)")
            #expect(index.slideText.contains("Visit the site"), "\(name)")
            // The slide titles are indexed once, as titles, not again as slide text.
            #expect(!index.slideText.contains("Links"), "\(name)")
        }
    }

    /// Tables, charts, groups and SmartArt give their words too.
    @Test func tablesChartsAndDiagramsAreIndexed() throws {
        let dir = try #require(Corpus.decks)
        let sample = try DeckIndex.make(fileAt: dir.appending(path: "sample.pptx")).textContent
        #expect(sample.contains("Faint aurora"))
        #expect(sample.contains("Manual, on a bright star"))
        #expect(sample.contains("Tripod and spare batteries"))
        let charts = try DeckIndex.make(fileAt: dir.appending(path: "charts.deckcraft"))
        #expect(!charts.slideText.isEmpty)
        let smartart = try DeckIndex.make(fileAt: dir.appending(path: "smartart.pptx"))
        #expect(smartart.slideText.count > 3)
        print("charts: \(charts.slideText.prefix(6))")
        print("smartart: \(smartart.slideText.prefix(6))")
    }

    @Test func attributesAreSet() throws {
        let index = try DeckIndex.make(fileAt: try #require(Corpus.decks).appending(path: "review.pptx"))
        let a = CSSearchableItemAttributeSet(contentType: .presentation)
        index.apply(to: a)
        #expect(a.title == "Review deck")
        #expect(a.subject == "Corpus")
        #expect(a.authorNames == ["Oracle"])
        #expect(a.keywords == ["pptx review"])
        #expect(a.contributors == ["Presenter"])
        #expect(a.pageCount == 5)
        #expect(a.pageWidth == 960 && a.pageHeight == 540)
        let text = try #require(a.textContent)
        for word in ["Review deck", "Links", "Visit the site", "Opening notes.", "Check the title", "Done"] {
            #expect(text.contains(word), "\(word)")
        }
    }

    /// Spotlight never reads pictures, media, embedded files or fonts.
    @Test func textReadLeavesMediaOut() throws {
        let dir = try #require(Corpus.decks)
        for name in ["motion.deckcraft", "motion.pptx"] {
            let fd = open(dir.appending(path: name).path, O_RDONLY)
            let zip = try ZipFileReader(fileDescriptor: fd)
            let bytes = try DeckReader.textPackage(zip, limits: .spotlight)
            let names = try ZipReader(bytes).entries.map(\.name)
            #expect(!names.contains { $0.hasPrefix("media/") || $0.hasPrefix("ppt/media/") }, "\(name)")
            #expect(names.first == (name.hasSuffix(".deckcraft") ? "mimetype" : names.first))
            let file = try DeckReader.readText(dir.appending(path: name), limits: .spotlight)
            #expect(file.textOnly && file.presentation.slides.count == 4)
        }
        #expect(!DeckReader.keepsText("ppt/media/image1.png") && !DeckReader.keepsText("Media/3") && !DeckReader.keepsText("docProps/thumbnail.jpeg"))
        #expect(DeckReader.keepsText("ppt/slides/slide1.xml") && DeckReader.keepsText("presentation.json"))
    }

    /// A part over the per-part limit is left out rather than read.
    @Test func oversizedPartsAreSkipped() throws {
        let url = try #require(Corpus.decks).appending(path: "review.deckcraft")
        let tiny = DeckLimits(maxFileBytes: 0, maxPartBytes: 1024, maxTextBytes: 1 << 20)
        #expect(throws: DeckFileError.self) { try DeckIndex.make(fileAt: url, limits: tiny) }
    }

    @Test func damagedFilesThrow() throws {
        let scratch = try Scratch()
        for url in try scratch.damaged() {
            do {
                let index = try DeckIndex.make(fileAt: url)
                // A package the engine reads leniently may come out with nothing in it; that is all it may give.
                #expect(index.slideCount == 0, "\(url.lastPathComponent)")
            } catch {
                // Typed: a `DeckFileError`, never a trap.
                #expect(!String(describing: error).isEmpty)
            }
        }
    }

    @Test func textIsBounded() {
        var budget = TextBudget(left: 5)
        #expect(budget.take("abc") == "abc")
        #expect(budget.take("déf") == "d")
        #expect(budget.left == 0 && budget.take("more") == "")
    }

    @Test func propertiesAreSplitAndDated() {
        #expect(DeckIndex.split(" Ann ; Bob;;", ";") == ["Ann", "Bob"])
        #expect(DeckIndex.split("a, b;c", ",;") == ["a", "b", "c"])
        #expect(DeckIndex.date("2026-10-27T01:13:13Z") == Date(timeIntervalSince1970: 1_793_063_593))
        #expect(DeckIndex.date("2026-10-27T01:13:13.250Z") != nil)
        #expect(DeckIndex.date("yesterday") == nil && DeckIndex.date("") == nil)
    }

    /// Groups and replies nested past any sensible depth are cut off, not recursed into without end. Built,
    /// read and freed on the extensions' large stack, as the importer reads a file (a 200-deep value takes
    /// more than a test thread's 512 KB to free).
    @Test func deepNestingIsBounded() throws {
        let counts = LargeStack.sync { () -> [Int] in
            var shape = Shape.default
            shape.text = TextBody.fromText("deep")
            for _ in 0 ..< 200 {
                var group = Shape.default
                group.kind = .group(children: [shape], child: .init())
                shape = group
            }
            var out: [String] = []
            var budget = TextBudget(left: 1 << 20)
            DeckIndex.collect(shape, 0, into: &out, &budget)
            let fromShapes = out.count
            var c = Comment(text: "leaf")
            for i in 0 ..< 200 { c = Comment(author: "A\(i % 3)", text: "c\(i)", replies: [c]) }
            var people: [String] = []
            out = []
            DeckIndex.collect(c, 0, into: &out, &people, &budget)
            return [fromShapes, out.count, people.count]
        }
        #expect(counts == [0, DeckIndex.maxDepth + 1, 3])
    }
}
