// DCAppModel — what the start window offers: the new-presentation tiles (Blank, the built-in themes, the
// sample deck, the starter templates), what each one creates, the recent presentations as rows, the rule
// for showing the start window at launch, and the tiles' pictures, rendered from the decks they create and
// cached. Ports `new_tiles`, `template_tiles`, `split_path` and `recent_list`'s rows of deckcraft
// `crates/ui-egui/src/backstage/files.rs`, and `recent_exists` of `app/files.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors). Docs/plans/Ribbon-and-StartScreen.md §7.
import DCCore
import DCEngine
import DCModel
import DCRender
import Foundation

/// A tile that creates a presentation.
public struct StartTile: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case blank, theme, sample, template }
    /// `blank`, `theme:<name>`, `sample` or `template:<name>`; the "new" dialog's actions are this with `new:` before it.
    public var id: String
    public var kind: Kind
    public var title: String
    /// A template's summary.
    public var detail: String?
    /// The theme the deck uses (nil for Blank).
    public var theme: String?
}

/// A row of the recent list.
public struct StartRecent: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var folder: String
    /// The file isn't there: the row says "(missing)" and choosing it does nothing.
    public var missing: Bool
    public var id: String { "recent:\(path)" }
}

/// What a launch with nothing to open shows.
public enum StartLaunch: Equatable, Sendable {
    /// Something else opens a document (Finder, the command line, `--sample`, state restoration).
    case nothing
    /// An untitled presentation: the start window is turned off in Settings.
    case untitled
    case startWindow
}

public enum StartCatalog {
    /// The pages of the start window's sidebar.
    public static let pages = ["home", "new", "open"]

    /// The sample deck's tile title, and what a search matches it by (`new_tiles`).
    static var sampleTitle: String { L10n.text("Sample deck: Northern Lights") }
    static let sampleMatch = "sample deck northern lights"

    /// `trim().to_lowercase()`, as deckcraft's start page compares queries.
    static func normalized(_ query: String) -> String { rustLowercase(String(rustTrim(query))) }

    /// Blank (unless `blank` is false), the built-in themes whose name contains `query`, then the sample deck
    /// when it matches (`new_tiles`).
    public static func themeTiles(_ query: String, blank: Bool = true) -> [StartTile] {
        let q = normalized(query)
        var out: [StartTile] = []
        if blank && q.isEmpty { out.append(StartTile(id: "blank", kind: .blank, title: L10n.text("Blank Presentation"))) }
        for th in builtinThemes() where q.isEmpty || rustLowercase(th.name).contains(q) {
            out.append(StartTile(id: "theme:\(th.name)", kind: .theme, title: th.name, theme: th.name))
        }
        if q.isEmpty || sampleMatch.contains(q) {
            out.append(StartTile(id: "sample", kind: .sample, title: sampleTitle, theme: "DeckCraft"))
        }
        return out
    }

    /// The starter templates whose name, summary, theme or a slide title matches `query` (`template_tiles`).
    public static func templateTiles(_ query: String) -> [StartTile] {
        Templates.matching(query).map { StartTile(id: "template:\($0.name)", kind: .template, title: $0.name, detail: $0.summary, theme: $0.theme) }
    }

    /// Every tile, in the order the New page shows them.
    public static func allTiles() -> [StartTile] { themeTiles("") + templateTiles("") }

    /// `file.new`'s parameters for a tile; nil for the sample deck (built by its own commands) and for ids
    /// that name no tile.
    public static func newParams(_ id: String) -> JSON? {
        if id == "blank" { return .emptyObject }
        if id.hasPrefix("theme:") {
            let name = String(id.dropFirst(6))
            guard builtinThemes().contains(where: { $0.name == name }) else { return nil }
            return ["theme": .string(name)]
        }
        if id.hasPrefix("template:") {
            let name = String(id.dropFirst(9))
            guard Templates.find(name) != nil else { return nil }
            return ["template": .string(name)]
        }
        return nil
    }

    /// Create the presentation tile `id` stands for: `file.new` with its parameters, or the sample deck.
    @MainActor @discardableResult
    public static func create(_ id: String, in model: AppModel) -> Result<JSON, CommandError> {
        if id == "sample" {
            do {
                try Sample.openSample(model.session)
            } catch {
                model.status = error.description
                return .failure(CommandError(error.description))
            }
            model.changed()
            return .success(.null)
        }
        guard let p = newParams(id) else { return .failure(CommandError("no start-screen tile `\(id)`")) }
        return model.run("file.new", p)
    }

    // MARK: Recent presentations

    /// File name and folder of a recent path, split as text: nothing on disk is read (`split_path`).
    public static func splitPath(_ path: String) -> (name: String, folder: String) {
        var p = Substring(path)
        while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
        guard let slash = p.lastIndex(of: "/") else { return (path, "") }
        let name = p[p.index(after: slash)...]
        let folder = slash == p.startIndex ? "/" : p[..<slash]
        return (name.isEmpty ? path : String(name), String(folder))
    }

    /// Whether a recent file is there (`recent_exists`). A path that looks remote (a UNC share, a URL) is never
    /// probed: a stat on a dead network location can wait for the system's timeout, so it counts as present
    /// and is judged when chosen.
    public static func recentExists(_ path: String) -> Bool {
        if path.hasPrefix("\\\\") || path.hasPrefix("//") || path.contains("://") { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The recent list's rows: `paths` newest first, at most `UiState.recentMax`, those whose name contains
    /// `query` (`recent_list`). `exists` decides "(missing)".
    public static func recents(_ paths: [String], query: String = "", exists: (String) -> Bool = recentExists) -> [StartRecent] {
        let q = normalized(query)
        var seen = Set<String>()
        var out: [StartRecent] = []
        for p in paths where !p.isEmpty && seen.insert(p).inserted {
            if out.count >= UiState.recentMax { break }
            let (name, folder) = splitPath(p)
            guard q.isEmpty || rustLowercase(name).contains(q) else { continue }
            out.append(StartRecent(path: p, name: name, folder: folder, missing: !exists(p)))
        }
        return out
    }

    // MARK: At launch

    /// What a launch shows: AppKit asks only when nothing else opened a document, and the start window takes the
    /// untitled presentation's place while Settings has it on (decision 5).
    public static func atLaunch(files: Int, sample: Bool, documents: Int, showStartScreen: Bool) -> StartLaunch {
        guard files == 0, !sample, documents == 0 else { return .nothing }
        return showStartScreen ? .startWindow : .untitled
    }
}

/// The tiles' pictures: DCRender's render of the title slide of the deck each tile creates, made in a scratch
/// session and cached as PNG under the caches folder, keyed by tile and app version. Nothing is shipped: every
/// picture is drawn from the app's own themes and fonts (§7).
public enum StartTileArt {
    /// The longest side, in pixels, a tile is drawn at.
    public static let maxWidth = 1024
    /// Larger cache files are not tiles.
    static let maxBytes = 8 << 20

    /// `~/Library/Caches/DeckCraftNative/StartTiles/<version>`.
    public static func cacheDirectory(version: String = DCAppVersion.current) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "DeckCraftNative/StartTiles/\(fileSafe(version))")
    }

    /// `id` with everything but ASCII letters and digits replaced, for a file name.
    static func fileSafe(_ id: String) -> String {
        String(id.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") ? Character($0) : "_" }.prefix(120))
    }

    /// The PNG of tile `id` `width` pixels wide: from `cache` when it is there, else rendered and stored. nil
    /// for an unknown tile or a failed render. Safe to call off the main thread: the scratch session is its own.
    public static func png(_ id: String, width: Int, cache: URL? = cacheDirectory()) -> [UInt8]? {
        let w = Swift.min(Swift.max(width, 16), maxWidth)
        let file = cache?.appending(path: "\(fileSafe(id))-\(w).png")
        if let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int, size > 0, size <= maxBytes, let data = try? Data(contentsOf: file) {
            return [UInt8](data)
        }
        guard let bytes = render(id, width: w), !bytes.isEmpty else { return nil }
        if let cache, let file {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? Data(bytes).write(to: file, options: .atomic)
        }
        return bytes
    }

    /// The title slide of tile `id`'s deck, rendered `width` pixels wide, as PNG.
    static func render(_ id: String, width: Int) -> [UInt8]? {
        let s = Session()
        do {
            if id == "sample" {
                try Sample.openSample(s)
            } else {
                guard let p = StartCatalog.newParams(id) else { return nil }
                _ = try s.execute("file.new", p)
                // A theme's title slide is empty placeholders: the picture shows its name in its title style.
                if let name = p["theme"]?.asStr, let title = s.activeDoc?.currentSlide?.shapes.first?.id.rawValue {
                    _ = try s.execute("text.set", ["id": .integer(title), "text": .string(name)])
                }
            }
        } catch {
            return nil
        }
        guard let doc = s.activeDoc?.doc, !doc.slides.isEmpty else { return nil }
        let sw = doc.slideSize.width
        guard sw.isFinite, sw > 0 else { return nil }
        let image = renderSlide(doc, 0, RenderOpts(scale: Double(width) / sw))
        let png = ImageEncoding.png(image)
        return png.isEmpty ? nil : png
    }
}
