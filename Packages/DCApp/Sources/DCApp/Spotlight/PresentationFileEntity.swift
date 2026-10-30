// DCApp — a presentation file as an App Intents entity (the presentation App Schema's document), indexed in
// Spotlight so Siri and Spotlight can find it by what its slides say (SpotlightFeature), and opened by the schema's
// open intent when a result is chosen.
import AppIntents
import AppKit
import CoreSpotlight
import DCSpotlight
import Foundation

@AppEntity(schema: .presentation.document)
public struct PresentationFileEntity: IndexedEntity {
    public static let defaultQuery = PresentationFileQuery()

    /// The file's path.
    public let id: String
    @Property(indexingKey: \.displayName)
    public var name: String
    @Property(indexingKey: \.textContent)
    public var text: String
    /// Everything `DeckIndex` learns, for the item's other attributes; nil when resolved from a path alone.
    var index: DeckIndex?

    public init(path: String, index: DeckIndex? = nil) {
        id = path
        name = URL(filePath: path).deletingPathExtension().lastPathComponent
        text = index?.textContent ?? ""
        self.index = index
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let a = defaultAttributeSet
        index?.apply(to: a)
        a.displayName = name
        a.contentURL = URL(filePath: id)
        return a
    }
}

public struct PresentationFileQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [PresentationFileEntity.ID]) async throws -> [PresentationFileEntity] {
        identifiers.filter { FileManager.default.fileExists(atPath: $0) }.map { PresentationFileEntity(path: $0) }
    }
}

@AppIntent(schema: .presentation.open)
public struct OpenPresentationFileIntent: OpenIntent {
    @Parameter public var target: PresentationFileEntity

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = SpotlightFeature.open(path: target.id)
        return .result()
    }
}
