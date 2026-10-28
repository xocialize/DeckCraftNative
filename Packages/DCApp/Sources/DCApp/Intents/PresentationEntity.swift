// DCApp — the open presentations as App Intents entities, and the main-actor side of the intents that act on
// the running app: every one of them goes through `AppModel.run`, as a menu item or the control channel does.
import AppIntents
import DCAppModel
import DCCore
import DCEngine
import DCIntentsKit
import Foundation

/// A presentation open in DeckCraftNative (`DocState`, by its `uid`).
public struct PresentationEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Presentation", comment: "The type of an open presentation, in Shortcuts.")
    )
    public static let defaultQuery = PresentationQuery()

    /// `DocState.uid`, in decimal.
    public let id: String
    @Property(title: LocalizedStringResource("Title", comment: "An open presentation's title, in Shortcuts."))
    public var title: String
    @Property(title: LocalizedStringResource("Slide Count", comment: "How many slides an open presentation has, in Shortcuts."))
    public var slideCount: Int
    /// The file it was opened from or saved to; nil for an untitled presentation.
    @Property(title: LocalizedStringResource("File Path", comment: "Where an open presentation is saved, in Shortcuts."))
    public var path: String?

    public init(id: String, title: String, slideCount: Int, path: String?) {
        self.id = id
        self.title = title
        self.slideCount = slideCount
        self.path = path
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource("\(title)", bundle: .atURL(Bundle.module.bundleURL), comment: "An open presentation's name."),
            subtitle: LocalizedStringResource("\(slideCount) slides", bundle: .atURL(Bundle.module.bundleURL), comment: "An open presentation's slide count.")
        )
    }
}

/// The presentations open in the running app.
public struct PresentationQuery: EntityQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [PresentationEntity.ID]) async throws -> [PresentationEntity] {
        IntentsHost.entities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [PresentationEntity] {
        IntentsHost.entities()
    }
}

/// The running app, as the intents that act on it see it.
@MainActor
enum IntentsHost {
    static func entity(_ st: DocState) -> PresentationEntity {
        PresentationEntity(id: String(st.uid), title: st.displayTitle, slideCount: st.doc.slides.count, path: st.path)
    }

    /// The entity an intent returns for `st` (reported to the control channel's run).
    static func result(_ st: DocState) -> PresentationEntity {
        let e = entity(st)
        IntentsRun.report(["id": .string(e.id), "title": .string(e.title), "slides": .integer(e.slideCount)])
        return e
    }

    /// Every open presentation, in the session's order.
    static func entities() -> [PresentationEntity] {
        AppController.shared?.model.session.documents.map(entity) ?? []
    }

    /// The app's controller, or why there is none (the app hasn't finished launching).
    static func controller() throws(DeckIntentError) -> AppController {
        guard let app = AppController.shared else {
            throw DeckIntentError(LocalizedStringResource("DeckCraftNative isn't ready yet. Try again in a moment.", bundle: .atURL(Bundle.module.bundleURL)))
        }
        return app
    }

    /// `presentation` (else the active one) made the engine's active document: the one the next command acts on.
    @discardableResult
    static func activate(_ presentation: PresentationEntity?, in app: AppController) throws(DeckIntentError) -> DocState {
        let session = app.model.session
        if let presentation {
            guard let st = session.documents.first(where: { String($0.uid) == presentation.id }) else {
                throw DeckIntentError(LocalizedStringResource(
                    "\(presentation.title) is no longer open.", bundle: .atURL(Bundle.module.bundleURL),
                    comment: "An intent named a presentation that has since been closed. The value is its title."
                ))
            }
            app.activate(uid: st.uid)
            return st
        }
        guard let st = session.activeDoc else {
            throw DeckIntentError(LocalizedStringResource("No presentation is open.", bundle: .atURL(Bundle.module.bundleURL)))
        }
        return st
    }

    /// Bring the window of `st` to the front.
    static func showWindow(_ st: DocState, in app: AppController) {
        app.documents.first { $0.uid == st.uid }?.showWindows()
    }

    /// Run a command through `AppModel.run`, its failure as the intent's error.
    @discardableResult
    static func run(_ app: AppController, _ id: String, _ params: JSON = .object(JSONObject())) throws(DeckIntentError) -> JSON {
        switch app.model.run(id, params) {
        case .success(let v): return v
        case .failure(let e): throw DeckIntentError.engine(e.message)
        }
    }
}
