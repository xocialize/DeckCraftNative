// DCAppTests — the App Intents' logic, without a window or the App Intents runtime: the export and read intents
// on corpus decks (PDF, PPTX, images, outline, slide count), damaged files, Run DeckCraft Command's parsing and
// failures, and the parameters New Presentation and Add Slide hand the engine.
import AppIntents
import CoreGraphics
import DCAppModel
import DCCore
import DCEngine
import DCTestSupport
import Foundation
import Testing
@testable import DCApp

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

@Suite @MainActor struct IntentsCommandTests {
    private func model() -> AppModel { AppModel(session: Session.withNew()) }

    @Test func runsACommandAndAnswersItsJSON() throws {
        let m = model()
        let before = m.session.activeDoc?.doc.slides.count ?? 0
        let out = try RunDeckCraftCommandIntent.run(m, "slide.new", #"{"title": "From Shortcuts"}"#)
        let json = try JSONParser.parse(out)
        #expect(json["index"]?.asU64 != nil)
        #expect(m.session.activeDoc?.doc.slides.count == before + 1)
        // Empty parameters are `{}`.
        let info = try JSONParser.parse(try RunDeckCraftCommandIntent.run(m, " file.info ", ""))
        #expect(info["slides"]?.asU64 == UInt64(before + 1))
    }

    @Test func badCommandsFailCleanly() {
        let m = model()
        #expect(throws: DeckIntentError.self) { try RunDeckCraftCommandIntent.run(m, "no.suchCommand", "{}") }
        #expect(throws: DeckIntentError.self) { try RunDeckCraftCommandIntent.run(m, "slide.new", "{title: nope}") }
        #expect(throws: DeckIntentError.self) { try RunDeckCraftCommandIntent.run(m, "slide.new", "[1, 2]") }
        // The command's own failure, as the engine words it.
        do {
            _ = try RunDeckCraftCommandIntent.run(m, "file.export", "{}")
            Issue.record("file.export without a path should fail")
        } catch {
            #expect(error.description.contains("missing `path`"))
        }
        // A UI command with no app around it fails rather than opening anything.
        #expect(throws: DeckIntentError.self) { try RunDeckCraftCommandIntent.run(m, "app.exportDialog", "{}") }
    }

    @Test func commandOptionsListEveryCommandOnce() {
        let ids = IntentsCommands.ids()
        #expect(ids.count == Set(ids).count)
        #expect(ids.contains("file.export"))
        #expect(ids.contains("show.start"))
        #expect(ids.count == Set(commandSpecs().map(\.id) + UICommands.all.map(\.id)).count)
        #expect(IntentsCommands.isKnown("view.sorter"))
        #expect(!IntentsCommands.isKnown("view.nothing"))
    }

    @Test func newPresentationParameters() throws {
        #expect(try NewPresentationIntent.params(theme: nil, starter: nil) == .object(JSONObject()))
        #expect(try NewPresentationIntent.params(theme: "harbor", starter: "")["theme"]?.asStr == "Harbor")
        let starter = try #require(Templates.starters().first).name
        #expect(try NewPresentationIntent.params(theme: nil, starter: starter)["template"]?.asStr == starter)
        #expect(throws: DeckIntentError.self) { try NewPresentationIntent.params(theme: "Harbor", starter: starter) }
        #expect(throws: DeckIntentError.self) { try NewPresentationIntent.params(theme: "No Such Theme", starter: nil) }
        // What the engine makes of them.
        let m = AppModel()
        _ = m.run("file.new", try NewPresentationIntent.params(theme: nil, starter: starter))
        #expect((m.session.activeDoc?.doc.slides.count ?? 0) > 1)
    }

    @Test func addSlideParameters() throws {
        let p = AddSlideIntent.params(layout: .titleOnly, title: "Q3", body: "One\nTwo")
        #expect(p["layout"]?.asStr == "titleOnly")
        #expect(p["title"]?.asStr == "Q3")
        #expect(AddSlideIntent.params(layout: nil, title: "", body: nil) == .object(JSONObject()))
        // Every layout the intent offers is one `slide.new` knows.
        let m = model()
        for layout in SlideLayoutOption.allCases {
            if case .failure(let e) = m.run("slide.new", AddSlideIntent.params(layout: layout, title: "T", body: "B")) {
                Issue.record("\(layout): \(e.message)")
            }
        }
    }

    @Test func entitiesNeedTheApp() async throws {
        // Without the running app there are no open presentations to offer, and nothing to act on.
        if AppController.shared == nil {
            #expect(try await PresentationQuery().suggestedEntities().isEmpty)
            #expect(throws: DeckIntentError.self) { try IntentsHost.controller() }
        }
        let m = model()
        let st = try #require(m.session.activeDoc)
        let e = IntentsHost.entity(st)
        #expect(e.id == String(st.uid))
        #expect(e.slideCount == st.doc.slides.count)
    }
}
