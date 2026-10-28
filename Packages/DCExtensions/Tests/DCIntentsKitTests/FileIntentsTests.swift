// DCIntentsKitTests — the file intents' logic, without a window, the app or the App Intents runtime: Export
// Presentation, Get Outline and Get Slide Count on corpus decks (PDF slides/notes/handouts, PPTX, images, outline,
// slide count), damaged files, the export's parameters, and an intent's file parameter. Moved from DCAppTests with
// the intents (they run in the App Intents extension now).
import AppIntents
import CoreGraphics
import DCCore
import DCEngine
import DCTestSupport
import Foundation
import Testing
@testable import DCIntentsKit

/// A corpus deck's bytes, or nil without the fixtures (the test then skips its checks).
private func corpusDeck(_ name: String) -> (url: URL, input: PresentationInput)? {
    guard let corpus = Fixtures.oracleCorpus else { return nil }
    let url = corpus.appending(path: "decks/\(name)")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (url, PresentationInput(name: name, bytes: [UInt8](data)))
}

/// The slide count deckcraft recorded for a corpus deck (`<base>.info.json`).
private func corpusSlideCount(_ base: String) -> Int? {
    guard let corpus = Fixtures.oracleCorpus,
          let data = try? Data(contentsOf: corpus.appending(path: "decks/\(base).info.json")),
          let info = try? JSONParser.parse([UInt8](data)), let slides = info["slides"]?.asArray else { return nil }
    return slides.count
}

private func pdfPages(_ url: URL) -> Int? { CGPDFDocument(url as CFURL)?.numberOfPages }

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "DCAppIntentsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// The intent error's message, or nil when `body` didn't fail with one.
private func intentError(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch let e as DeckIntentError {
        return e.description
    } catch {
        return nil
    }
}

@Suite struct IntentsFileTests {
    @Test func exportPDFSlidesNotesAndHandouts() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let n = corpusSlideCount("content") else { return }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let slides = try await IntentsEngine.export(deck.input, ExportRequest(format: "pdf"), into: dir.appending(path: "slides"))
        #expect(slides.map(\.lastPathComponent) == ["content.pdf"])
        let bytes = try Data(contentsOf: try #require(slides.first))
        #expect(bytes.starts(with: Array("%PDF".utf8)))
        #expect(pdfPages(try #require(slides.first)) == n)

        let notes = try await IntentsEngine.export(deck.input, ExportRequest(format: "pdf", layout: "notes"), into: dir.appending(path: "notes"))
        #expect(pdfPages(try #require(notes.first)) == n)

        let handouts = try await IntentsEngine.export(deck.input, ExportRequest(format: "pdf", layout: "handouts", perPage: 2), into: dir.appending(path: "handouts"))
        #expect(pdfPages(try #require(handouts.first)) == (n + 1) / 2)
    }

    @Test func exportPPTXReopensWithTheSameSlides() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let n = corpusSlideCount("content") else { return }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try await IntentsEngine.export(deck.input, ExportRequest(format: "pptx"), into: dir)
        let url = try #require(files.first)
        #expect(url.lastPathComponent == "content.pptx")
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes.starts(with: Array("PK".utf8)))
        let reopened = try FileCommands.openChecked("content.pptx", bytes).0
        #expect(reopened.slides.count == n)
        // The file the export read is exported, not some other document.
        #expect(try await IntentsEngine.slideCount(PresentationInput(name: "content.pptx", bytes: bytes)) == n)
    }

    @Test func exportImagesOfOneSlideOrAll() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let n = corpusSlideCount("content") else { return }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let one = try await IntentsEngine.export(deck.input, ExportRequest(format: "png", slide: 2), into: dir.appending(path: "one"))
        #expect(one.map(\.lastPathComponent) == ["content.png"])
        let png = try Data(contentsOf: try #require(one.first))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let all = try await IntentsEngine.export(deck.input, ExportRequest(format: "jpeg", allSlides: true), into: dir.appending(path: "all"))
        #expect(all.count == n)
        #expect(all.first?.lastPathComponent == "content1.jpg")
        for url in all { #expect(FileManager.default.fileExists(atPath: url.path)) }
        let jpeg = try Data(contentsOf: try #require(all.first))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
    }

    @Test func exportOfASlidePastTheEndFailsBeforeWriting() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let n = corpusSlideCount("content") else { return }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let message = await intentError { _ = try await IntentsEngine.export(deck.input, ExportRequest(format: "png", slide: n + 1), into: dir) }
        #expect(message == "There's no slide \(n + 1): the presentation has \(n) slides.")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
        #expect(await intentError { _ = try await IntentsEngine.export(deck.input, ExportRequest(format: "png", slide: 0), into: dir) } != nil)
    }

    @Test func outlineMatchesDeckcraftsOutlineExport() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let corpus = Fixtures.oracleCorpus else { return }
        let expected = try String(contentsOf: corpus.appending(path: "decks/content.md"), encoding: .utf8)
        #expect(try await IntentsEngine.outline(deck.input) == expected)
    }

    @Test func slideCountMatchesTheCorpus() async throws {
        for base in ["content", "charts", "sample"] {
            guard let deck = corpusDeck("\(base).deckcraft"), let n = corpusSlideCount(base) else { continue }
            #expect(try await IntentsEngine.slideCount(deck.input) == n, "\(base)")
            guard let pptx = corpusDeck("\(base).pptx") else { continue }
            #expect(try await IntentsEngine.slideCount(pptx.input) == n, "\(base).pptx")
        }
    }

    @Test func damagedFilesFailCleanly() async throws {
        let garbage = PresentationInput(name: "garbage.pptx", bytes: Array("not a presentation at all".utf8))
        let m1 = await intentError { _ = try await IntentsEngine.slideCount(garbage) }
        #expect(m1?.hasPrefix("garbage.pptx couldn't be opened: ") == true)

        let empty = PresentationInput(name: "empty.deckcraft", bytes: [])
        #expect(await intentError { _ = try await IntentsEngine.outline(empty) } != nil)

        // A real deck cut short: its zip directory is gone.
        if let deck = corpusDeck("content.deckcraft") {
            let cut = PresentationInput(name: "cut.deckcraft", bytes: Array(deck.input.bytes.prefix(deck.input.bytes.count / 2)))
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(await intentError { _ = try await IntentsEngine.export(cut, ExportRequest(format: "pdf"), into: dir) } != nil)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
        }
        if let deck = corpusDeck("content.pptx") {
            let cut = PresentationInput(name: "cut.pptx", bytes: Array(deck.input.bytes.prefix(4096)))
            #expect(await intentError { _ = try await IntentsEngine.slideCount(cut) } != nil)
        }
    }

    @Test func exportRequestParameters() throws {
        let pdf = try ExportRequest(format: "pdf", layout: "handouts", perPage: 4).params(path: "/x/a.pdf", count: 3)
        #expect(pdf["layout"]?.asStr == "handouts")
        #expect(pdf["perPage"]?.asU64 == 4)
        let notes = try ExportRequest(format: "pdf", layout: "notes", perPage: 4).params(path: "/x/a.pdf", count: 3)
        #expect(notes["perPage"] == nil)
        let image = try ExportRequest(format: "jpeg", slide: 3).params(path: "/x/a.jpg", count: 3)
        #expect(image["slide"]?.asU64 == 2)
        #expect(throws: DeckIntentError.self) { try ExportRequest(format: "jpeg", slide: 4).params(path: "/x/a.jpg", count: 3) }
        #expect(throws: DeckIntentError.self) { try ExportRequest(format: "odp").params(path: "/x/a.odp", count: 3) }
        #expect(ExportRequest(format: "jpeg").fileExtension == "jpg")
        #expect(ExportRequest(format: "pptx").contentType.preferredFilenameExtension == "pptx")
    }

    /// An intent's file parameter, set as Shortcuts sets it, reads the file it names.
    @Test func intentFileParameterReadsTheFile() async throws {
        guard let deck = corpusDeck("content.deckcraft"), let n = corpusSlideCount("content") else { return }
        let intent = GetSlideCountIntent()
        intent.file = IntentFile(fileURL: deck.url, filename: deck.url.lastPathComponent, type: nil)
        let input = try PresentationInput(intent.file)
        #expect(input.bytes == deck.input.bytes)
        #expect(try await IntentsEngine.slideCount(input) == n)
    }
}

@Suite struct IntentsKitTests {
    /// The file intents never ask for the foreground: an App Intents extension can only run them in the background,
    /// and with the app listing them too, this tells the system they don't need it.
    @Test func fileIntentsRunInTheBackground() {
        #expect(ExportPresentationIntent.supportedModes == .background)
        #expect(GetOutlineIntent.supportedModes == .background)
        #expect(GetSlideCountIntent.supportedModes == .background)
    }

    /// The text built at run time (errors, dialogs) comes from DCIntentsKit's own catalog.
    @Test func runtimeTextComesFromTheKitsCatalog() {
        let sentinel = "\u{1}missing"
        for key in ["%@ couldn't be opened: %@", "There's no slide %lld: the presentation has %lld slides.", "Exported %lld files.",
                    "The presentation has %lld slides.", "the file is empty or can't be read", "Presentation"] {
            #expect(Bundle.module.localizedString(forKey: key, value: sentinel, table: "Localizable") != sentinel, "\(key)")
        }
        #expect(DeckIntentError.unreadable("a.pptx", "bad zip").description == "a.pptx couldn't be opened: bad zip")
        #expect(IntentsEngine.noSlide(4, 3).description == "There's no slide 4: the presentation has 3 slides.")
    }

    /// A run started by the app's control channel collects what the intents report; outside one, nothing is kept.
    @Test func runsCollectReportedValues() async throws {
        IntentsRun.report(.integer(1))
        let run = IntentsRun(directory: FileManager.default.temporaryDirectory)
        IntentsRun.$current.withValue(run) {
            IntentsRun.report(.integer(2))
            IntentsRun.report(.string("x"))
        }
        #expect(run.reported == [.integer(2), .string("x")])
        #expect(IntentsRun.$current.withValue(run) { IntentsEngine.exportDirectory() } == run.directory)
        #expect(IntentsEngine.exportDirectory() != run.directory)
    }
}
