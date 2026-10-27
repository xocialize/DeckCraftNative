// DCApp — the intents that act on the running app: Open Presentation, New Presentation, Start Slide Show, Add
// Slide and Run DeckCraft Command. They run on the main actor and go through `AppModel.run`, as the menus and the
// control channel do; documents the engine opens get their window from `AppController.syncDocuments`.
import AppIntents
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import Foundation

/// Open a presentation file in a window.
public struct OpenPresentationIntent: AppIntent {
    public static let title = LocalizedStringResource("Open Presentation")
    public static let description = IntentDescription(LocalizedStringResource(
        "Opens a DeckCraft or PowerPoint presentation in DeckCraftNative."
    ))
    public static let supportedModes: IntentModes = .foreground

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "The presentation file an intent works on."),
        supportedContentTypes: [.presentation]
    )
    public var file: IntentFile

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$file)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<PresentationEntity> {
        let app = try IntentsHost.controller()
        NSApp.activate()
        if let url = file.fileURL, FileManager.default.isReadableFile(atPath: url.path) {
            // A file on disk opens as a document of its own: Save goes back to it.
            do {
                let (doc, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
                if let d = doc as? PresentationDocument, let st = app.model.session.documents.first(where: { $0.uid == d.uid }) {
                    return .result(value: IntentsHost.result(st))
                }
            } catch {
                throw DeckIntentError.unreadable(file.filename, error.localizedDescription)
            }
        } else {
            // Only the bytes (another app's file): an untitled copy, as `file.openBytes` opens one.
            let input = try PresentationInput(file)
            try IntentsHost.run(app, "file.openBytes", ["name": .string(input.name), "data": .string(Data(input.bytes).base64EncodedString())])
        }
        guard let st = app.model.session.activeDoc else { throw DeckIntentError.unreadable(file.filename, "") }
        return .result(value: IntentsHost.result(st))
    }
}

/// Start a new presentation, blank in a theme or filled from a starter.
public struct NewPresentationIntent: AppIntent {
    public static let title = LocalizedStringResource("New Presentation")
    public static let description = IntentDescription(LocalizedStringResource(
        "Creates a new presentation in DeckCraftNative, in a built-in theme or from a starter presentation."
    ))
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: LocalizedStringResource("Theme"), optionsProvider: ThemeOptions())
    public var theme: String?

    @Parameter(
        title: LocalizedStringResource("Starter", comment: "A starter presentation (a template with slides) to begin from."),
        optionsProvider: StarterOptions()
    )
    public var starter: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("New presentation") {
            \.$theme
            \.$starter
        }
    }

    /// `file.new`'s parameters, or why these choices can't make a presentation.
    static func params(theme: String?, starter: String?) throws(DeckIntentError) -> JSON {
        let theme = theme.flatMap { $0.isEmpty ? nil : $0 }
        let starter = starter.flatMap { $0.isEmpty ? nil : $0 }
        if theme != nil && starter != nil {
            throw DeckIntentError(LocalizedStringResource("Choose a theme or a starter, not both.", bundle: .atURL(Bundle.module.bundleURL)))
        }
        if let theme {
            // The engine falls back to the default theme for a name it doesn't know; an intent says so instead.
            guard let t = builtinThemes().first(where: { $0.name.lowercased() == theme.lowercased() }) else {
                let names = builtinThemes().map(\.name).joined(separator: ", ")
                throw DeckIntentError(LocalizedStringResource(
                    "There's no theme named \(theme). The themes are \(names).", bundle: .atURL(Bundle.module.bundleURL),
                    comment: "The first value is the name asked for, the second the list of built-in theme names."
                ))
            }
            return ["theme": .string(t.name)]
        }
        if let starter { return ["template": .string(starter)] }
        return .object(JSONObject())
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<PresentationEntity> {
        let app = try IntentsHost.controller()
        let params = try Self.params(theme: theme, starter: starter)
        NSApp.activate()
        try IntentsHost.run(app, "file.new", params)
        guard let st = app.model.session.activeDoc else { throw DeckIntentError.engine("no active presentation") }
        return .result(value: IntentsHost.result(st))
    }
}

/// Play a presentation's slide show.
public struct StartSlideShowIntent: AppIntent {
    public static let title = LocalizedStringResource("Start Slide Show")
    public static let description = IntentDescription(LocalizedStringResource(
        "Plays an open presentation's slide show, from the first slide or another one."
    ))
    public static let supportedModes: IntentModes = .foreground

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "An open presentation; empty means the frontmost one.")
    )
    public var presentation: PresentationEntity?

    @Parameter(title: LocalizedStringResource("From Slide"), default: 1, inclusiveRange: (1, 100_000))
    public var slide: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Start the slide show of \(\.$presentation) from slide \(\.$slide)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let app = try IntentsHost.controller()
        let st = try IntentsHost.activate(presentation, in: app)
        let count = st.doc.slides.count
        guard slide >= 1, slide <= count else { throw IntentsEngine.noSlide(slide, count) }
        NSApp.activate()
        IntentsHost.showWindow(st, in: app)
        try IntentsHost.run(app, "show.start", ["from": .integer(slide - 1)])
        IntentsRun.report(.integer(slide))
        return .result()
    }
}

/// Add a slide, with a title and text, to an open presentation.
public struct AddSlideIntent: AppIntent {
    public static let title = LocalizedStringResource("Add Slide")
    public static let description = IntentDescription(LocalizedStringResource(
        "Adds a slide after the current one in an open presentation, with a layout, a title and body text. Returns the new slide's number."
    ))

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "An open presentation; empty means the frontmost one.")
    )
    public var presentation: PresentationEntity?

    @Parameter(title: LocalizedStringResource("Layout", comment: "A new slide's layout."))
    public var layout: SlideLayoutOption?

    @Parameter(title: LocalizedStringResource("Title", comment: "A new slide's title text."))
    public var slideTitle: String?

    @Parameter(
        title: LocalizedStringResource("Text", comment: "A new slide's body text; each line is a bullet."),
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    public var body: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add a slide to \(\.$presentation)") {
            \.$layout
            \.$slideTitle
            \.$body
        }
    }

    /// `slide.new`'s parameters.
    static func params(layout: SlideLayoutOption?, title: String?, body: String?) -> JSON {
        var p = JSON.object(JSONObject())
        if let layout { p.set("layout", .string(layout.rawValue)) }
        if let title, !title.isEmpty { p.set("title", .string(title)) }
        if let body, !body.isEmpty { p.set("body", .string(body)) }
        return p
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let app = try IntentsHost.controller()
        try IntentsHost.activate(presentation, in: app)
        let out = try IntentsHost.run(app, "slide.new", Self.params(layout: layout, title: slideTitle, body: body))
        let index = out["index"]?.asU64.flatMap { Int(exactly: $0) } ?? 0
        IntentsRun.report(.integer(index + 1))
        return .result(value: index + 1)
    }
}

/// Run any DeckCraft command by id with JSON parameters, as `dccli` and the control channel do.
public struct RunDeckCraftCommandIntent: AppIntent {
    public static let title = LocalizedStringResource("Run DeckCraft Command")
    public static let description = IntentDescription(LocalizedStringResource(
        "Runs a DeckCraft command by its id (such as slide.new or file.info) with JSON parameters, on the open presentation, and returns the command's JSON answer. For automation: the commands and their parameters are listed by `dccli describe`."
    ))

    @Parameter(title: LocalizedStringResource("Command", comment: "A command id, such as slide.new."), optionsProvider: CommandOptions())
    public var command: String

    @Parameter(
        title: LocalizedStringResource("Parameters", comment: "The command's parameters, a JSON object."),
        default: "{}",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    public var parameters: String

    @Parameter(
        title: LocalizedStringResource("Presentation", comment: "An open presentation; empty means the frontmost one.")
    )
    public var presentation: PresentationEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) with \(\.$parameters)") {
            \.$presentation
        }
    }

    /// Run `id` with the JSON object `parameters` through `model` and answer the command's JSON: what the intent
    /// does once the presentation is active. Fails on parameters that aren't a JSON object, an unknown command
    /// or the command's own failure.
    @MainActor
    public static func run(_ model: AppModel, _ id: String, _ parameters: String) throws(DeckIntentError) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntentsCommands.isKnown(id) else {
            throw DeckIntentError(LocalizedStringResource(
                "There's no command \(id).", bundle: .atURL(Bundle.module.bundleURL), comment: "The value is the command id asked for."
            ))
        }
        let text = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        let params: JSON
        do {
            params = text.isEmpty ? .object(JSONObject()) : try JSONParser.parse(text)
        } catch {
            throw DeckIntentError(LocalizedStringResource(
                "The parameters aren't valid JSON: \(error.description)", bundle: .atURL(Bundle.module.bundleURL),
                comment: "The value is the JSON parser's message."
            ))
        }
        guard case .object = params else {
            throw DeckIntentError(LocalizedStringResource("The parameters must be a JSON object, such as {}.", bundle: .atURL(Bundle.module.bundleURL)))
        }
        switch model.run(id, params) {
        case .success(let v): return JSONWriter().string(v)
        case .failure(let e): throw DeckIntentError.engine(e.message)
        }
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try IntentsHost.controller()
        if presentation != nil { try IntentsHost.activate(presentation, in: app) }
        let answer = try Self.run(app.model, command, parameters)
        IntentsRun.report(.string(answer))
        return .result(value: answer)
    }
}
