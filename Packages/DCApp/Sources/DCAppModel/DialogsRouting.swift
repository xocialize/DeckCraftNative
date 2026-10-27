// DCAppModel — the UI commands and engine requests the dialogs answer, the file pickers, the File
// backstage's pages, the command palette, and the settings files. Port of the dialog arms of `run_ui`,
// `drain_requests`, `pick_and_run`, `pick_and_reuse`, `reuse_slides`, `execute_on_target` and the file
// purposes of deckcraft `crates/ui-egui/src/lib.rs`, the page table and `format_bytes` of `backstage.rs`,
// `palette` of `menus.rs`, and `settings.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCEngine
import DCModel
import Foundation

/// Where a picked file goes (`FileTarget`): the presentation and slide current when the panel opened.
public struct FileTarget: Equatable, Sendable {
    public var doc: UInt64
    public var slide: SlideId?
}

extension DialogController {
    /// The UI commands the dialogs own.
    public static let commands = [
        "app.dialog", "view.zoomDialog", "view.gridOptions", "app.about", "app.preferences", "app.exportDialog", "app.pasteSpecial",
        "app.find", "app.replace", "app.palette", "app.insertPictureDialog", "app.changePictureDialog", "app.insertAudioDialog",
        "app.insertVideoDialog", "app.smartArtPictureDialog", "app.browseThemeDialog", "app.reuseSlidesDialog", "app.compareDialog",
        "app.backstage", "app.home",
    ]

    /// Answer UI command `id` (`run_ui`'s dialog arms); nil when it isn't one of `commands`.
    public func uiCommand(_ id: String, _ p: JSON) -> Result<JSON, CommandError>? {
        switch id {
        case "app.dialog":
            guard let d = p["id"]?.asStr else { return .failure("missing `id`") }
            open(d)
        case "view.zoomDialog": open("zoom")
        case "view.gridOptions":
            // AppModel answers it when values are given; without any, the dialog opens.
            open("gridOptions")
            return .success([
                "spacing": .num(model.session.prefs.gridSpacing), "snap": .bool(model.session.prefs.snapToGrid),
                "smartGuides": .bool(model.session.prefs.smartGuides), "gridlines": .bool(model.ui.gridlines), "guides": .bool(model.ui.guides),
            ])
        case "app.about": open("about")
        case "app.preferences": open("preferences")
        case "app.exportDialog": open("export")
        case "app.pasteSpecial": open("pasteSpecial")
        case "app.find", "app.replace":
            if model.session.activeDoc != nil {
                open("find", fields: ["replace": id == "app.replace" ? "1" : "0"])
            } else {
                palette = PaletteState()
            }
        case "app.palette": palette = PaletteState()
        case "app.insertPictureDialog": pickAndRun("picture", "insert.picture")
        case "app.changePictureDialog": pickAndRun("picture", "picture.change")
        case "app.insertAudioDialog": pickAndRun("audio", "insert.audio")
        case "app.insertVideoDialog": pickAndRun("video", "insert.video")
        case "app.smartArtPictureDialog":
            guard services != nil else { return .failure("picking a SmartArt picture needs the app") }
            pickAndRun("picture", "smartArt.picture", p)
        case "app.browseThemeDialog":
            guard model.session.activeDoc != nil else { return .failure("open a presentation first") }
            pickAndRun("theme", "design.browseTheme")
        case "app.compareDialog":
            guard model.session.activeDoc != nil else { return .failure("open the presentation to compare first") }
            pickAndRun("open", "review.compare")
        case "app.reuseSlidesDialog": pickAndReuse(keep: p["keepFormatting"]?.asBool ?? false)
        case "app.backstage": return backstage(p)
        case "app.home":
            let on = p["on"]?.asBool ?? (current?.id != "new")
            if on { open("new") } else if current?.id == "new" { cancel() }
        default: return nil
        }
        return .success(.null)
    }

    /// An engine request the dialogs take (`drain_requests`): a dialog, or the Save As panel.
    public func request(_ r: UiRequest) -> Bool {
        switch r {
        case .dialog(let id, let params):
            open(id, params: params)
            return true
        case .pickFile(let purpose) where purpose == "saveAs":
            model.run("app.saveAsDialog")
            return true
        default:
            return false
        }
    }

    /// `app.backstage {page?, on?}`: the File tab's pages, as the Mac shows them: New is the template gallery,
    /// Info the Properties sheet, Export the export sheet, Account the About window; Open, Save As and Print
    /// are the system's.
    func backstage(_ p: JSON) -> Result<JSON, CommandError> {
        if p["on"]?.asBool == false {
            if let id = current?.id, ["new", "info", "export", "about"].contains(id) { cancel() }
            return .success(["page": .null])
        }
        let id = p["page"]?.asStr ?? "home"
        guard let page = DialogBackstage.pages.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
            return .failure(CommandError("unknown File page `\(id)`"))
        }
        if DialogBackstage.needsDoc(page) && model.session.activeDoc == nil {
            return .failure(CommandError("File › \(DialogBackstage.label(page)) needs an open presentation"))
        }
        switch page {
        case "home", "new": open("new")
        case "open": model.run("app.openDialog")
        case "info": open("info")
        case "saveAs": model.run("app.saveAsDialog")
        case "print": model.run("app.print")
        case "export": open("export")
        default: open("about")
        }
        return .success(["page": .string(page)])
    }

    // MARK: File pickers

    /// The document and slide a picked file goes to (`capture_file_target`).
    func captureTarget() -> FileTarget? {
        guard let d = model.session.activeDoc else { return nil }
        return FileTarget(doc: d.uid, slide: d.selection.target == .slides ? d.currentSlide?.id : nil)
    }

    /// `pick_and_run`: an open panel for `purpose`, then `cmd` with the file's `name` and `data` added to
    /// `extra`, on the presentation and slide that were current when the panel opened.
    public func pickAndRun(_ purpose: String, _ cmd: String, _ extra: JSON = .emptyObject) {
        guard let services else {
            status("Choosing a \(purpose) file needs the app")
            return
        }
        let target = captureTarget()
        services.pickOpen(purpose) { [weak self] path in
            guard let self, let path else { return }
            self.runWithFile(path, cmd, extra, target)
        }
    }

    /// Run `cmd` with the file at `path` (`name` + `data`) on `target`.
    public func runWithFile(_ path: String, _ cmd: String, _ extra: JSON, _ target: FileTarget?) {
        var args = extra.isObject ? extra : .emptyObject
        do {
            let bytes = [UInt8](try Data(contentsOf: URL(filePath: path)))
            args.set("name", .string((path as NSString).lastPathComponent))
            args.set("data", .string(Cmd.base64Encode(bytes)))
        } catch {
            args.set("path", .string(path))
        }
        switch onTarget(target, (path as NSString).lastPathComponent, { self.model.run(cmd, args) }) {
        case .failure(let e): status(e.message)
        case .success: break
        }
    }

    /// `execute_on_target`: run `body` on the captured presentation and slide, then put the view back. A
    /// closed presentation or a deleted slide cancels it.
    func onTarget(_ target: FileTarget?, _ name: String, _ body: () -> Result<JSON, CommandError>) -> Result<JSON, CommandError> {
        let s = model.session
        guard let target else { return body() }
        guard let idx = s.documents.firstIndex(where: { $0.uid == target.doc }) else {
            return .failure(CommandError("\(name) was not applied: the presentation it was chosen for is closed"))
        }
        let view = s.activeIndex
        guard let st = s.documents.at(idx) else { return body() }
        if view == idx, st.selection.target != .slides || target.slide == nil || st.currentSlide?.id == target.slide { return body() }
        let saved = st.selection
        s.setActive(idx)
        if let slide = target.slide {
            guard let i = st.doc.slides.firstIndex(where: { $0.id == slide }) else {
                if let view { s.setActive(view) }
                return .failure(CommandError("\(name) was not applied: its slide was deleted"))
            }
            st.selection.target = .slides
            st.selection.slide = i
            st.selection.slides = []
            st.selection.shapes = []
            st.selection.text = nil
            st.selection.cells = nil
        }
        let r = body()
        if view == idx {
            st.selection = saved
        } else if let view, view < s.documents.count {
            s.setActive(view)
        }
        model.changed()
        return r
    }

    /// `pick_and_reuse`: pick a presentation, list its slides, and offer them in Reuse Slides.
    func pickAndReuse(keep: Bool) {
        guard let services else {
            status("Reuse Slides needs the app")
            return
        }
        let target = captureTarget()
        services.pickOpen("open") { [weak self] path in
            guard let self, let path else { return }
            self.offerReuse(path, keep: keep, target: target)
        }
    }

    /// Read `path` once and open Reuse Slides on its slides: the list shown and the slides inserted come
    /// from the same bytes, even if the file changes while the dialog is open.
    public func offerReuse(_ path: String, keep: Bool, target: FileTarget? = nil) {
        var source: JSON = .emptyObject
        do {
            let bytes = [UInt8](try Data(contentsOf: URL(filePath: path)))
            source.set("name", .string((path as NSString).lastPathComponent))
            source.set("data", .string(Cmd.base64Encode(bytes)))
        } catch {
            status("\(path): \(error.localizedDescription)")
            return
        }
        do {
            let list = try model.session.execute("slide.reuseList", source)
            reuseTarget = target ?? captureTarget()
            open("reuseSlides", params: ["path": .string(path), "source": source, "keep": .bool(keep), "slides": list["slides"] ?? []])
        } catch {
            status(error.description)
        }
    }

    /// `reuse_slides`: insert the `picked` slides of `source` after the slide that was current when the
    /// picker opened, in that presentation. Returns whether they were inserted.
    func reuseSlides(_ source: JSON, keep: Bool, picked: [Int]) -> Bool {
        var args = source.isObject ? source : .emptyObject
        args.set("keepFormatting", .bool(keep))
        args.set("slides", .array(picked.map { .integer($0) }))
        switch onTarget(reuseTarget, "Reuse Slides", { self.model.run("slide.reuse", args) }) {
        case .success:
            reuseTarget = nil
            status("Inserted \(picked.count) slides")
            return true
        case .failure(let e):
            status(e.message)
            return false
        }
    }

    // MARK: Command palette

    /// The palette's entries for its query (`palette_items`).
    public var paletteItems: [PaletteItem] { Palette.items(model.session, palette?.query ?? "") }

    /// Move the palette's selection by `delta` rows.
    public func paletteMove(_ delta: Int) {
        guard var p = palette else { return }
        let n = paletteItems.count
        p.selection = Swift.max(0, Swift.min(p.selection + delta, Swift.max(n - 1, 0)))
        palette = p
    }

    /// Run the palette's selected entry (or `id`), closing it first.
    public func paletteRun(_ id: String? = nil) {
        guard let p = palette else { return }
        let items = paletteItems
        guard let run = id ?? items.at(p.selection)?.id else { return }
        palette = nil
        model.run(run)
    }
}

/// The File backstage on the Mac (`backstage.rs`).
public enum DialogBackstage {
    /// `Page::ALL`, by id.
    public static let pages = ["home", "new", "open", "info", "saveAs", "print", "export", "account"]

    public static func needsDoc(_ page: String) -> Bool { ["info", "saveAs", "print", "export"].contains(page) }

    public static func label(_ page: String) -> String {
        switch page {
        case "saveAs": "Save As"
        default: page.prefix(1).uppercased() + page.dropFirst()
        }
    }

    /// The Info page's properties (`PROPERTIES`): `file.properties` key, label, hint.
    public static let properties: [(String, String, String)] = [
        ("title", "Title", "Add a title"), ("subject", "Subject", "Specify the subject"), ("keywords", "Tags", "Add a tag"),
        ("category", "Categories", "Add a category"), ("company", "Company", "Specify the company"), ("comments", "Comments", "Add comments"),
        ("author", "Author", "Add an author"),
    ]

    /// The Export dialog's formats.
    public static let exportFormats: [(String, String)] = [
        ("pdf", "PDF document (.pdf)"), ("png", "PNG images (current slide)"), ("pngAll", "PNG images (all slides)"),
        ("jpeg", "JPEG image (current slide)"), ("pptx", "PowerPoint Presentation (.pptx)"), ("outline", "Outline (.txt)"),
        ("gif", "Animated GIF (.gif)"), ("rtf", "Outline/RTF (.rtf)"),
    ]

    /// The PDF's layouts (`LAYOUTS`).
    public static let pdfLayouts: [(String, String)] = [
        ("slides", "Full Page Slides"), ("notes", "Notes Pages"), ("h1", "Handouts (1 slide per page)"), ("h2", "Handouts (2 slides per page)"),
        ("h3", "Handouts (3 slides per page)"), ("h4", "Handouts (4 slides per page)"), ("h6", "Handouts (6 slides per page)"),
        ("h9", "Handouts (9 slides per page)"),
    ]

    /// `format_bytes`: `1234567` → `1.2 MB`.
    public static func formatBytes(_ b: UInt64) -> String {
        switch b {
        case 0 ..< 1024: "\(b) bytes"
        case 1024 ..< 1_048_576: "\(rustFixed(Double(b) / 1024, places: 1)) KB"
        default: "\(rustFixed(Double(b) / 1_048_576, places: 1)) MB"
        }
    }

    /// `version_line`: the bundle's version, and the build when there is one.
    public static func versionLine(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "Version \(v) (\($0))" } ?? "Version \(v)"
    }
}

/// `settings.rs`: `prefs.json` beside `ui.json`. Reading never fails and never trusts the file; writing goes
/// through a temporary file and a rename.
public enum DialogSettings {
    public static let prefsFile = "prefs.json"
    /// Larger settings files are not settings (`MAX_BYTES`).
    public static let maxBytes = 4 << 20

    /// The saved preferences in `dir`, or nil when missing or unusable.
    public static func loadPrefs(_ dir: URL) -> Prefs? {
        let url = dir.appending(path: prefsFile)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxBytes,
              let data = try? Data(contentsOf: url),
              let json = try? JSONParser.parse([UInt8](data)),
              let prefs = try? Prefs(fromJSON: json)
        else { return nil }
        return prefs.sanitized()
    }

    /// Save `prefs` into `dir` (created when missing). Failures are ignored, as deckcraft logs and goes on.
    public static func savePrefs(_ prefs: Prefs, to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appending(path: "\(prefsFile).tmp")
            try Data(JSONWriter().bytes(prefs.toJSON())).write(to: tmp)
            let dest = dir.appending(path: prefsFile)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir.appending(path: "\(prefsFile).tmp"))
        }
    }
}
