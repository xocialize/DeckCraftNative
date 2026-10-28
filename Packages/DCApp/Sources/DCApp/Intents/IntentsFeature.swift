// DCApp — the intents run in the app's own process from the control channel, so a script can check them end to
// end in the built app without the Shortcuts app: `intents.run {intent, …parameters}` builds the real intent,
// sets its parameters as Shortcuts would, starts its `perform()` and answers a token; `intents.result {token}`
// answers once it finished: the files it wrote, the value it returned, or its error. The file intents are
// DCIntentsKit's (the App Intents extension runs them for Shortcuts); here they run in the app's process.
//
//   dccli app --port 4242 --method intents.run '{"intent":"export","file":"/path/deck.deckcraft","format":"pdf"}'
//   dccli app --port 4242 --method intents.result '{"token":1}'
import AppIntents
import DCAutomation
import DCCore
import DCIntentsKit
import Foundation

@MainActor
enum IntentsFeature {
    /// Finished and running intents by token: nil while running.
    private static var results: [UInt64: JSON?] = [:]
    private static var nextToken: UInt64 = 0

    static func install(_ app: AppController) {
        app.control(["intents.run"]) { p in start(p) }
        app.control(["intents.result"]) { p in
            guard let t = p["token"]?.asU64, let r = results[t] else { return err("unknown `token`") }
            guard let done = r else { return ok(["done": false]) }
            results[t] = nil
            return ok(done)
        }
    }

    private static func ok(_ v: JSON) -> ControlOutcome { .done(["ok": true, "result": v]) }
    private static func err(_ e: String) -> ControlOutcome { .done(["ok": false, "error": .string(e)]) }

    private static func file(_ p: JSON) -> IntentFile? {
        guard let path = p["file"]?.asStr else { return nil }
        let url = URL(filePath: path)
        return IntentFile(fileURL: url, filename: url.lastPathComponent, type: nil)
    }

    /// The intent `p` names, with its parameters set; nil for an unknown name or a missing file.
    private static func intent(_ p: JSON) -> (any AppIntent)? {
        switch p["intent"]?.asStr {
        case "export":
            guard let f = file(p) else { return nil }
            let i = ExportPresentationIntent()
            i.file = f
            i.format = p["format"]?.asStr.flatMap(ExportFormatOption.init(rawValue:)) ?? .pdf
            i.layout = p["layout"]?.asStr.flatMap(PDFLayoutOption.init(rawValue:)) ?? .slides
            i.perPage = p["perPage"]?.asU64.flatMap { Int(exactly: $0) }.flatMap(HandoutsPerPageOption.init(rawValue:)) ?? .six
            i.allSlides = p["allSlides"]?.asBool ?? false
            i.slide = p["slide"]?.asU64.flatMap { Int(exactly: $0) } ?? 1
            return i
        case "outline":
            guard let f = file(p) else { return nil }
            let i = GetOutlineIntent()
            i.file = f
            return i
        case "slideCount":
            guard let f = file(p) else { return nil }
            let i = GetSlideCountIntent()
            i.file = f
            return i
        case "open":
            guard let f = file(p) else { return nil }
            let i = OpenPresentationIntent()
            i.file = f
            return i
        case "new":
            let i = NewPresentationIntent()
            i.theme = p["theme"]?.asStr
            i.starter = p["starter"]?.asStr
            return i
        case "addSlide":
            let i = AddSlideIntent()
            i.layout = p["layout"]?.asStr.flatMap(SlideLayoutOption.init(rawValue:))
            i.slideTitle = p["title"]?.asStr
            i.body = p["body"]?.asStr
            return i
        case "show":
            let i = StartSlideShowIntent()
            i.slide = p["slide"]?.asU64.flatMap { Int(exactly: $0) } ?? 1
            return i
        case "command":
            let i = RunDeckCraftCommandIntent()
            i.command = p["command"]?.asStr ?? ""
            i.parameters = p["parameters"]?.asStr ?? "{}"
            return i
        default:
            return nil
        }
    }

    private static func start(_ p: JSON) -> ControlOutcome {
        guard let intent = intent(p) else {
            return err("`intent` must be export, outline, slideCount, open, new, addSlide, show or command, with `file` where it takes one")
        }
        nextToken &+= 1
        let token = nextToken
        results[token] = .some(nil)
        let run = IntentsRun(directory: IntentsEngine.exportDirectory())
        let box = EngineConfined(intent)
        Task { @MainActor in
            var out: JSON = ["done": true]
            do {
                try await IntentsRun.$current.withValue(run) { _ = try await box.value.perform() }
                out.set("ok", .bool(true))
                out.set("values", .array(run.reported))
            } catch {
                out.set("ok", .bool(false))
                out.set("error", .string((error as? DeckIntentError)?.description ?? error.localizedDescription))
            }
            results[token] = .some(out)
        }
        return ok(["token": .integer(token)])
    }
}
