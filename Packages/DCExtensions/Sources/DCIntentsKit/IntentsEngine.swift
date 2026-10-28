// DCIntentsKit — what the App Intents do with a presentation file and no window: export it, read its outline,
// count its slides. Each call reads the file into a session of its own, on a thread with a large stack (deep
// groups recurse once per level: `LargeStack`), runs the engine's own commands (`file.export`), and drops the
// session. Nothing here touches the app's session, its windows or AppKit, so it runs in the App Intents
// extension (`Apps/DeckCraftNative/Extensions/Intents`), in the app, and in tests alike.
import AppIntents
import DCCore
import DCEngine
import DCExtensionKit
import Foundation
import UniformTypeIdentifiers

/// A failure an intent reports to Shortcuts, Siri or Spotlight.
public struct DeckIntentError: Error, CustomLocalizedStringResourceConvertible, CustomStringConvertible {
    public let localizedStringResource: LocalizedStringResource
    public init(_ resource: LocalizedStringResource) { localizedStringResource = resource }
    public var description: String { String(localized: localizedStringResource) }

    /// An engine failure shown as the engine words it (not translated: CLAUDE.md, String Catalogs).
    public static func engine(_ message: String) -> DeckIntentError {
        DeckIntentError(LocalizedStringResource("\(message)", bundle: .atURL(Bundle.module.bundleURL), comment: "An engine error message, shown as is."))
    }

    /// A file an intent was given that can't be read; `message` is the engine's reason.
    public static func unreadable(_ name: String, _ message: String) -> DeckIntentError {
        DeckIntentError(LocalizedStringResource(
            "\(name) couldn't be opened: \(message)", bundle: .atURL(Bundle.module.bundleURL),
            comment: "A presentation file an intent was given can't be read. The first value is the file name, the second the engine's reason."
        ))
    }
}

/// A presentation's bytes and file name, as an intent was given them.
public struct PresentationInput: Sendable {
    public var name: String
    public var bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }

    /// The file's bytes: from its URL when Shortcuts passes one (security-scoped when it comes from a sandboxed
    /// caller), else the data it carries.
    public init(_ file: IntentFile) throws(DeckIntentError) {
        name = file.filename
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                bytes = [UInt8](data)
                return
            }
        }
        let data = file.data
        guard !data.isEmpty else {
            throw DeckIntentError.unreadable(file.filename, String(localized: "the file is empty or can't be read", bundle: .module))
        }
        bytes = [UInt8](data)
    }

    /// The file name without its extension: the stem of what an export writes.
    public var stem: String {
        let base = (name as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? String(localized: "Presentation", bundle: .module, comment: "The file name an export uses when the input has none.") : stem
    }
}

/// What Export Presentation writes: `file.export`'s parameters, in the intent's terms.
public struct ExportRequest: Sendable, Equatable {
    /// `pdf`, `pptx`, `png` or `jpeg` (`file.export`'s `format`).
    public var format: String
    /// PDF: `slides`, `notes` or `handouts`.
    public var layout: String = "slides"
    /// PDF handouts: slides per page (1, 2, 3, 4, 6 or 9).
    public var perPage: Int = 6
    /// Images: the slide to export, 1-based; nil means the first slide, or every slide with `allSlides`.
    public var slide: Int?
    /// Images: every slide, one file each.
    public var allSlides = false

    public init(format: String, layout: String = "slides", perPage: Int = 6, slide: Int? = nil, allSlides: Bool = false) {
        self.format = format
        self.layout = layout
        self.perPage = perPage
        self.slide = slide
        self.allSlides = allSlides
    }

    /// The written file's extension.
    public var fileExtension: String {
        switch format {
        case "jpeg": "jpg"
        default: format
        }
    }

    /// The written file's type.
    public var contentType: UTType {
        switch format {
        case "pdf": .pdf
        case "png": .png
        case "jpeg": .jpeg
        default: UTType(filenameExtension: "pptx") ?? .data
        }
    }

    /// `file.export`'s parameters for writing to `path` in a presentation of `count` slides.
    public func params(path: String, count: Int) throws(DeckIntentError) -> JSON {
        var p: JSON = ["path": .string(path), "format": .string(format)]
        switch format {
        case "pdf":
            p.set("layout", .string(layout))
            if layout == "handouts" { p.set("perPage", .integer(perPage)) }
        case "png", "jpeg":
            if allSlides {
                p.set("all", .bool(true))
            } else {
                let n = slide ?? 1
                guard n >= 1, n <= count else { throw IntentsEngine.noSlide(n, count) }
                p.set("slide", .integer(n - 1))
            }
        case "pptx":
            break
        default:
            throw DeckIntentError.engine("unknown format `\(format)`")
        }
        return p
    }
}

/// The window-free engine work behind the export and read intents.
public enum IntentsEngine {
    /// An intent was asked for a slide past the end of a presentation of `count` slides.
    public static func noSlide(_ n: Int, _ count: Int) -> DeckIntentError {
        DeckIntentError(LocalizedStringResource(
            "There's no slide \(n): the presentation has \(count) slides.", bundle: .atURL(Bundle.module.bundleURL),
            comment: "An intent was asked for a slide past the end. The first value is the slide asked for (1-based), the second the slide count."
        ))
    }

    /// Run `body` with `input` open as the active document of a session of its own, on a thread of its own with
    /// a `LargeStack.stackSize` stack (an extension and a Swift concurrency task get 512 KB). Each call has its own
    /// session, so calls never share engine state and can run side by side.
    static func withDocument<T: Sendable>(_ input: PresentationInput, _ body: @escaping @Sendable (Session) throws(DeckIntentError) -> T) async throws(DeckIntentError) -> T {
        let r: Result<T, DeckIntentError> = await withCheckedContinuation { (done: CheckedContinuation<Result<T, DeckIntentError>, Never>) in
            LargeStack.async({ () -> Result<T, DeckIntentError> in
                let s = Session()
                do {
                    let (pres, _) = try FileCommands.openChecked(input.name, input.bytes)
                    FileCommands.addOpened(s, input.name, nil, pres)
                } catch {
                    return .failure(DeckIntentError.unreadable(input.name, "\(error)"))
                }
                return Result { () throws(DeckIntentError) -> T in try body(s) }
            }, then: { done.resume(returning: $0) })
        }
        return try r.get()
    }

    /// The number of slides in the presentation.
    public static func slideCount(_ input: PresentationInput) async throws(DeckIntentError) -> Int {
        try await withDocument(input) { s throws(DeckIntentError) in
            guard let st = s.activeDoc else { throw DeckIntentError.engine("no active presentation") }
            return st.doc.slides.count
        }
    }

    /// The presentation's outline: slide titles and their body text, indented by tabs (File › Export › Outline).
    public static func outline(_ input: PresentationInput) async throws(DeckIntentError) -> String {
        try await withDocument(input) { s throws(DeckIntentError) in
            guard let st = s.activeDoc else { throw DeckIntentError.engine("no active presentation") }
            do {
                return String(decoding: try FileCommands.saveBytes(st.doc, "outline"), as: UTF8.self)
            } catch {
                throw DeckIntentError.engine("\(error)")
            }
        }
    }

    /// Export the presentation as `request` asks into `directory` (made if missing), named after the input:
    /// the files written, in slide order.
    public static func export(_ input: PresentationInput, _ request: ExportRequest, into directory: URL) async throws(DeckIntentError) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DeckIntentError.engine(error.localizedDescription)
        }
        let path = directory.appending(path: "\(input.stem).\(request.fileExtension)").path
        let written = try await withDocument(input) { s throws(DeckIntentError) -> [String] in
            guard let st = s.activeDoc else { throw DeckIntentError.engine("no active presentation") }
            let params = try request.params(path: path, count: st.doc.slides.count)
            let out: JSON
            do { out = try s.execute("file.export", params) } catch { throw DeckIntentError.engine("\(error)") }
            if let files = out["files"]?.asArray { return files.compactMap(\.asStr) }
            return [out["path"]?.asStr ?? path]
        }
        return written.map { URL(filePath: $0) }
    }

    /// A fresh folder for one export's files, under the temporary directory (the control channel's run picks
    /// its own, `IntentsFeature`).
    public static func exportDirectory() -> URL {
        if let run = IntentsRun.current { return run.directory }
        return FileManager.default.temporaryDirectory.appending(path: "DeckCraftNative Intents", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
