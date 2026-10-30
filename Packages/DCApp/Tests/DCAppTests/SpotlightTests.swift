// DCAppTests — Spotlight: the app indexes the .deckcraft presentations it reads and writes (SpotlightFeature), as
// macOS doesn't call the import extension for them.
import AppKit
import CoreSpotlight
import DCCore
import DCAppModel
import DCEngine
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite struct AppSpotlightTests {
    final class Recorder: SpotlightIndex {
        var indexed: [CSSearchableItem] = []
        var entities: [PresentationFileEntity] = []
        var deleted: [String] = []
        func index(_ items: [CSSearchableItem], _ entities: [PresentationFileEntity]) {
            indexed += items
            self.entities += entities
        }
        func delete(_ identifiers: [String]) { deleted += identifiers }
    }

    private func sample(path: String?) throws -> (Session, DocState) {
        let s = Session()
        try Sample.openSample(s)
        let st = try #require(s.activeDoc)
        st.path = path
        return (s, st)
    }

    private func listURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dc-spotlight-\(UUID().uuidString)/spotlight.json")
    }

    @Test func aSavedRevisionIsIndexedOnce() throws {
        let (s, st) = try sample(path: "/tmp/Decks/Northern Lights.deckcraft")
        let rec = Recorder()
        let list = listURL()
        defer { try? FileManager.default.removeItem(at: list.deletingLastPathComponent()) }
        let indexer = SpotlightIndexer(index: rec, listURL: list)

        indexer.update(s.documents)
        let item = try #require(rec.indexed.first)
        #expect(rec.indexed.count == 1)
        #expect(item.uniqueIdentifier == "/tmp/Decks/Northern Lights.deckcraft")
        #expect(item.domainIdentifier == SpotlightIndexer.domain)
        #expect(item.attributeSet.displayName == "Northern Lights")
        #expect(item.attributeSet.contentURL == URL(filePath: "/tmp/Decks/Northern Lights.deckcraft"))
        #expect(item.attributeSet.textContent?.contains("Welcome everyone") == true, "the notes are indexed")
        #expect(item.attributeSet.textContent?.contains("A short tour of the aurora") == true, "the slides' text is indexed")
        #expect(item.expirationDate > Date().addingTimeInterval(300 * 24 * 60 * 60), "not Core Spotlight's default month")
        // Siri's entity: the same file, its words in the attribute Siri searches.
        let entity = try #require(rec.entities.first)
        #expect(rec.entities.count == 1)
        #expect(entity.id == "/tmp/Decks/Northern Lights.deckcraft")
        #expect(entity.name == "Northern Lights")
        #expect(entity.attributeSet.textContent?.contains("Welcome everyone") == true)
        #expect(entity.attributeSet.contentURL == URL(filePath: "/tmp/Decks/Northern Lights.deckcraft"))

        indexer.update(s.documents)
        #expect(rec.indexed.count == 1, "nothing changed")

        // An edit that isn't saved changes nothing: the file still holds the saved revision.
        AppModel(session: s).run("slide.notes", ["text": "Edited, not saved"])
        #expect(st.isDirty)
        indexer.update(s.documents)
        #expect(rec.indexed.count == 1)

        // Saving indexes the new revision.
        st.savedDocRef = st.docRef
        indexer.update(s.documents)
        #expect(rec.indexed.count == 2)
        #expect(rec.indexed.last?.attributeSet.textContent?.contains("Edited, not saved") == true)

        // The list survives the app.
        #expect(SpotlightIndexer(index: Recorder(), listURL: list).paths == ["/tmp/Decks/Northern Lights.deckcraft"])
    }

    @Test func onlyDeckCraftFilesAreIndexed() throws {
        let rec = Recorder()
        let indexer = SpotlightIndexer(index: rec, listURL: nil)
        for path in [nil, "/tmp/a.pptx", "/tmp/a.potx", "/tmp/a.ppsx"] {
            let (s, _) = try sample(path: path)
            indexer.update(s.documents)
        }
        #expect(rec.indexed.isEmpty, "untitled presentations have no file; macOS's Office importer indexes Open XML files")
        let (s, _) = try sample(path: "/tmp/A.DECKCRAFT")
        indexer.update(s.documents)
        #expect(rec.indexed.count == 1)
    }

    @Test func filesThatHaveGoneLoseTheirItems() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-spotlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let here = dir.appending(path: "here.deckcraft").path, gone = dir.appending(path: "gone.deckcraft").path
        try Data().write(to: URL(filePath: here))
        let rec = Recorder()
        let indexer = SpotlightIndexer(index: rec, listURL: dir.appending(path: "spotlight.json"))
        for path in [here, gone] {
            let (s, _) = try sample(path: path)
            indexer.update(s.documents)
        }
        #expect(indexer.paths == [here, gone])

        #expect(indexer.resolve(here) == URL(filePath: here))
        #expect(indexer.resolve(gone) == nil)
        #expect(rec.deleted == [gone], "a result whose file has gone is removed")
        #expect(indexer.paths == [here])

        try FileManager.default.removeItem(atPath: here)
        indexer.prune()
        #expect(rec.deleted == [gone, here], "and at launch")
        #expect(SpotlightIndexer(index: Recorder(), listURL: dir.appending(path: "spotlight.json")).paths.isEmpty)
    }

    @Test func aFileOnAVolumeThatIsNotMountedHasNotGone() {
        #expect(!SpotlightIndexer.isGone("/Volumes/dc-not-mounted-\(UUID().uuidString)/a.deckcraft"))
        #expect(SpotlightIndexer.isGone("/tmp/dc-\(UUID().uuidString).deckcraft"))
        #expect(SpotlightIndexer.isGone("/Volumes/\(UUID().uuidString)"), "the volume itself isn't a file on it")
    }

    @Test func onlyTheAppIndexesUnlessTold() {
        let app = SpotlightFeature.appBundleID
        #expect(SpotlightFeature.enabled(environment: [:], bundleID: app))
        #expect(!SpotlightFeature.enabled(environment: ["DECKCRAFT_NO_PREFS": "1"], bundleID: app), "scripted runs")
        #expect(!SpotlightFeature.enabled(environment: [:], bundleID: nil), "DeckCraftDev")
        #expect(!SpotlightFeature.enabled(environment: [:], bundleID: "com.apple.dt.xctest.tool"), "tests")
        #expect(SpotlightFeature.enabled(environment: ["DECKCRAFT_NO_PREFS": "1", "DECKCRAFT_SPOTLIGHT": "1"], bundleID: nil))
        #expect(!SpotlightFeature.enabled(environment: ["DECKCRAFT_SPOTLIGHT": "0"], bundleID: app))
    }

    @Test func otherActivitiesAreNotTaken() {
        #expect(!SpotlightFeature.continueActivity(NSUserActivity(activityType: "com.example.other")))
        let a = NSUserActivity(activityType: CSSearchableItemActionType)
        #expect(!SpotlightFeature.continueActivity(a), "a Spotlight activity without an identifier")
    }
}
