// DCAppTests — the app's App Intents' logic, without a window or the App Intents runtime: Run DeckCraft Command's
// parsing and failures, the parameters New Presentation and Add Slide hand the engine, and the open-presentation
// entity. The file intents' tests are DCIntentsKitTests' (`Packages/DCExtensions/Tests/DCIntentsKitTests`).
import AppIntents
import DCAppModel
import DCCore
import DCEngine
import DCIntentsKit
import Foundation
import Testing
@testable import DCApp

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
