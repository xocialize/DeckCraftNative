// DCApp — Spotlight: the .deckcraft presentations this app opens and saves are indexed, so Spotlight finds them by
// name and Siri by what their slides, notes and comments say ("open my presentation that mentions …"), and choosing
// one opens it here. macOS doesn't hand .deckcraft files to the app's import extension (DCExtensions/PORT-NOTES.md),
// so the app indexes what it reads and writes, with the extension's `DeckIndex`: a Core Spotlight item for each file
// (Spotlight's result, which hands the app its path) and its `PresentationFileEntity` (Siri's, through the
// presentation App Schema; macOS 27's Spotlight matches neither by body text). Open XML files are left to macOS's
// own Office importer, which indexes their text already. Only the app itself indexes: `DeckCraftDev`, tests and
// scripted runs (`DECKCRAFT_NO_PREFS`) don't. Not a port: deckcraft has no Spotlight support.
import AppKit
import CoreSpotlight
import DCCore
import DCEngine
import DCSpotlight
import os
import UniformTypeIdentifiers

/// Where the items and entities go: Core Spotlight's default index in the app, a recorder in tests.
@MainActor
protocol SpotlightIndex {
    func index(_ items: [CSSearchableItem], _ entities: [PresentationFileEntity])
    /// Remove the items and entities of the files at `paths`.
    func delete(_ paths: [String])
}

struct CoreSpotlightIndex: SpotlightIndex {
    func index(_ items: [CSSearchableItem], _ entities: [PresentationFileEntity]) {
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { SpotlightFeature.log.error("indexing failed: \(error.localizedDescription)") }
        }
        Task {
            do { try await CSSearchableIndex.default().indexAppEntities(entities) } catch {
                SpotlightFeature.log.error("indexing entities failed: \(error.localizedDescription)")
            }
        }
    }

    func delete(_ paths: [String]) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: paths) { error in
            if let error { SpotlightFeature.log.error("removing items failed: \(error.localizedDescription)") }
        }
        Task {
            do { try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: paths, ofType: PresentationFileEntity.self) } catch {
                SpotlightFeature.log.error("removing entities failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Indexes each presentation's saved revision once, by its file's path, and keeps the list of indexed paths so the
/// items of files that have gone are removed at the next launch.
@MainActor
final class SpotlightIndexer {
    static let domain = "presentations"
    /// How long an item stays without its presentation being opened or saved again (Core Spotlight's default is a
    /// month).
    static let lifetime: TimeInterval = 365 * 24 * 60 * 60

    let index: any SpotlightIndex
    /// The file listing the indexed paths; nil keeps none.
    let listURL: URL?
    private(set) var paths: Set<String> = []
    /// The saved revision last indexed, by path.
    private var indexed: [String: Weak] = [:]

    private final class Weak {
        weak var ref: DocRef?
        init(_ ref: DocRef) { self.ref = ref }
    }

    init(index: any SpotlightIndex, listURL: URL?) {
        self.index = index
        self.listURL = listURL
        if let listURL, let data = try? Data(contentsOf: listURL), let list = try? JSONDecoder().decode([String].self, from: data) {
            paths = Set(list)
        }
    }

    /// Whether the file at `path` is indexed by the app: .deckcraft only.
    static func indexes(_ path: String) -> Bool { URL(filePath: path).pathExtension.lowercased() == "deckcraft" }

    /// Index every presentation whose file the app read or wrote since the last call: one with a path whose saved
    /// revision isn't the one indexed. Edits that aren't saved change nothing.
    func update(_ documents: [DocState]) {
        indexed = indexed.filter { $0.value.ref != nil }
        var items: [CSSearchableItem] = []
        var entities: [PresentationFileEntity] = []
        var added = false
        for st in documents {
            guard let path = st.path, Self.indexes(path), indexed[path]?.ref !== st.savedDocRef else { continue }
            indexed[path] = Weak(st.savedDocRef)
            let x = DeckIndex.make(st.savedDoc)
            items.append(Self.item(x, path: path))
            entities.append(PresentationFileEntity(path: path, index: x))
            if paths.insert(path).inserted { added = true }
        }
        if !items.isEmpty { index.index(items, entities) }
        if added { saveList() }
    }

    /// The item for the presentation at `path`: everything `DeckIndex` learns, the file's name as its name.
    static func item(_ x: DeckIndex, path: String, now: Date = Date()) -> CSSearchableItem {
        let url = URL(filePath: path)
        let a = CSSearchableItemAttributeSet(contentType: UTType(DocumentTypes.deckcraft) ?? .presentation)
        x.apply(to: a)
        let name = url.deletingPathExtension().lastPathComponent
        a.displayName = name
        if x.title.isEmpty { a.title = name }
        a.contentURL = url
        a.lastUsedDate = now
        // The same file's entity, which Siri finds and opens.
        a.associateAppEntity(PresentationFileEntity(path: path, index: x))
        let item = CSSearchableItem(uniqueIdentifier: path, domainIdentifier: domain, attributeSet: a)
        item.expirationDate = now.addingTimeInterval(lifetime)
        return item
    }

    /// Remove the items of files that have gone (`gone`).
    func prune(gone: (String) -> Bool = SpotlightIndexer.isGone) {
        forget(paths.filter { !Self.indexes($0) || gone($0) })
    }

    /// The file a Spotlight result names, if it is still there; a file that has gone loses its item.
    func resolve(_ path: String, gone: (String) -> Bool = SpotlightIndexer.isGone) -> URL? {
        if FileManager.default.fileExists(atPath: path) { return URL(filePath: path) }
        if gone(path) { forget([path]) }
        return nil
    }

    func forget(_ gone: Set<String>) {
        guard !gone.isEmpty else { return }
        index.delete(gone.sorted())
        paths.subtract(gone)
        for p in gone { indexed[p] = nil }
        saveList()
    }

    /// Whether the file at `path` has gone. A file on a volume that isn't mounted (`/Volumes/<name>/…`) hasn't.
    nonisolated static func isGone(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return false }
        let parts = URL(filePath: path).pathComponents
        if parts.count > 3, parts[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/\(parts[2])") { return false }
        return true
    }

    private func saveList() {
        guard let listURL else { return }
        do {
            try FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(paths.sorted()).write(to: listURL, options: .atomic)
        } catch {
            SpotlightFeature.log.error("the list of indexed presentations wasn't saved: \(error.localizedDescription)")
        }
    }
}

@MainActor
enum SpotlightFeature {
    nonisolated static let log = Logger(subsystem: "com.xocialize.deckcraftnative", category: "spotlight")
    static let appBundleID = "com.xocialize.deckcraftnative"
    static private(set) var indexer: SpotlightIndexer?
    private static var observer: (any NSObjectProtocol)?

    static func install(_ app: AppController) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        indexer = nil
        app.inspect("spotlight") {
            ["enabled": .bool(indexer != nil), "paths": .array((indexer?.paths.sorted() ?? []).map { .string($0) })]
        }
        guard enabled() else { return }
        let indexer = SpotlightIndexer(index: CoreSpotlightIndex(), listURL: app.supportDirectory.appending(path: "spotlight.json"))
        self.indexer = indexer
        indexer.prune()
        observer = NotificationCenter.default.addObserver(forName: .deckCraftModelChanged, object: app, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated {
                guard let app else { return }
                indexer.update(app.model.session.documents)
            }
        }
    }

    /// The app (this bundle id) indexes unless scripted (`DECKCRAFT_NO_PREFS`); `DECKCRAFT_SPOTLIGHT=1` or `0` decides
    /// either way.
    static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment, bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if let v = environment["DECKCRAFT_SPOTLIGHT"] { return v == "1" }
        return bundleID == appBundleID && environment["DECKCRAFT_NO_PREFS"] == nil
    }

    /// A Spotlight result was chosen: open its presentation, or say it has gone.
    static func continueActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        open(path: path)
        return true
    }

    /// Open the presentation a Spotlight result names, or say it has gone. False when it has.
    @discardableResult
    static func open(path: String) -> Bool {
        let url = indexer?.resolve(path) ?? (FileManager.default.fileExists(atPath: path) ? URL(filePath: path) : nil)
        guard let url else {
            NSApp.presentError(CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]))
            return false
        }
        NSApp.activate()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
        return true
    }
}
