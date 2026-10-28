// DCAppModel — what editing a dialog's fields and pressing its buttons do. Port of the acting halves of
// `body` and the `*_dialog` functions in deckcraft `crates/ui-egui/src/dialogs.rs`, `preferences_snapshot`,
// `restore_preferences`, `SlideApp::export_as` and `reuse_slides` in `lib.rs` (MIT OR Apache-2.0, © ArtCraft
// Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCText
import Foundation

extension DialogController {
    // MARK: Edits

    /// Set `key` to `value` in `d`, and keep the fields that depend on it in step.
    func edit(_ d: inout Dialog, _ key: String, _ value: String) {
        if key.hasPrefix("cell:"), d.id == "chartData" {
            setCell(&d, key, value)
            return
        }
        switch (d.id, key) {
        case ("slideSize", "preset"):
            d.fields["preset"] = value
            if let s = slideSizes.first(where: { $0.label == value }) {
                let ppu = model.session.prefs.units.pointsPerUnit
                putSlideDim(&d, "w", s.width, ppu)
                putSlideDim(&d, "h", s.height, ppu)
            }
            syncOrientation(&d)
        case ("slideSize", "orientation"):
            let ppu = model.session.prefs.units.pointsPerUnit
            let cur = doc?.doc.slideSize ?? Size(960, 540)
            let w = slideDimPoints(d, "w", ppu, cur.width), h = slideDimPoints(d, "h", ppu, cur.height)
            // Picking the other orientation swaps the width and height.
            if (value == "portrait" && w > h) || (value == "landscape" && h > w) {
                putSlideDim(&d, "w", h, ppu)
                putSlideDim(&d, "h", w, ppu)
            }
            syncOrientation(&d)
        case ("slideSize", _):
            d.fields[key] = value
            syncOrientation(&d)
        case ("sizePosition", _):
            d.fields[key] = value
            SizePosition.reconcile(&d)
        case ("zoom", "zoomPick"):
            if value == "fit" {
                d.fields["mode"] = "fit"
            } else if !value.isEmpty {
                d.fields["mode"] = "percent"
                d.fields["percent"] = value
            }
            syncZoomPick(&d)
        case ("zoom", "percent"):
            d.fields["percent"] = value
            d.fields["mode"] = "percent"
            syncZoomPick(&d)
        case ("paragraph", "linePreset"):
            let picked: (String, String?)? = switch value {
            case "Single": ("multiple", "1")
            case "1.5 lines": ("multiple", "1.5")
            case "Double": ("multiple", "2")
            case "Multiple": ("multiple", nil)
            case "Exactly": ("exactly", nil)
            default: nil
            }
            if let (kind, v) = picked {
                d.fields["lineKind"] = kind
                if let v {
                    d.fields["lineValue"] = v
                } else if kind == "exactly", (DialogMath.finitePt(d.value("lineValue")).map { $0 <= 9.99 } ?? false) {
                    d.fields["lineValue"] = "18"
                } else if kind == "multiple", (DialogMath.finitePt(d.value("lineValue")).map { $0 > 9.99 } ?? false) {
                    d.fields["lineValue"] = "1"
                }
            }
            d.fields["linePreset"] = DialogMath.linePresetLabel(d.value("lineKind"), d.value("lineValue"))
        case ("paragraph", "lineValue"), ("paragraph", "lineKind"):
            d.fields[key] = value
            d.fields["linePreset"] = DialogMath.linePresetLabel(d.value("lineKind"), d.value("lineValue"))
        case ("preferences", _):
            d.fields[key] = value
            applyPreference(key, value)
        case ("autocorrect", _):
            d.fields[key] = value
            applyAutocorrect(key, value == "1" || value == "true")
        case ("dateTime", "language"):
            d.fields[key] = value
            fixDateFormat(&d)
        case ("action", "tab"):
            guard value != d.value("tab") else { return }
            d.fields = ["tab": value]
            seedAction(&d)
        case ("action", "group"):
            setActionKind(&d, value == "hyperlink" ? (actionGroup(d.value("kind")) == "hyperlink" ? d.value("kind") : "next") : value)
        case ("action", "kind"):
            setActionKind(&d, value)
        default:
            d.fields[key] = value
        }
    }

    func setActionKind(_ d: inout Dialog, _ kind: String) {
        guard kind != d.value("kind") else { return }
        let (curKind, curArg, _) = currentAction(d.value("tab"))
        d.fields["kind"] = kind
        if kind == curKind {
            d.fields["arg"] = curArg
        } else {
            switch kind {
            case "url": d.fields["arg"] = "https://"
            case "slide": d.fields["arg"] = "0"
            case "customShow": d.fields["arg"] = doc?.doc.customShows.first?.name ?? ""
            default: d.fields["arg"] = ""
            }
        }
    }

    func setCell(_ d: inout Dialog, _ key: String, _ value: String) {
        let parts = key.split(separator: ":")
        guard parts.count == 3, let r = Int(parts[1]), let c = Int(parts[2]) else { return }
        var grid = chartGrid(d)
        guard grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        grid[r][c] = value
        d.params = ["grid": .array(grid.map { .array($0.map { .string($0) }) })]
    }

    // MARK: Buttons

    /// Press `id` in `d`. Returns whether the dialog closes, or nil when `d` has no such button.
    func act(_ d: inout Dialog, _ id: String) -> Bool? {
        if id.hasPrefix("link:") {
            services?.openURL(String(id.dropFirst(5)))
            return false
        }
        switch d.id {
        case "table":
            guard id == "ok" else { return nil }
            let r = DialogMath.usize(DialogMath.number(d.value("rows")) ?? 2)
            let c = DialogMath.usize(DialogMath.number(d.value("cols")) ?? 5)
            run("insert.table", ["rows": .integer(r), "cols": .integer(c)])
            return true
        case "slideSize":
            guard id == "ok" else { return nil }
            let ppu = model.session.prefs.units.pointsPerUnit
            let cur = doc?.doc.slideSize ?? Size(960, 540)
            let w = slideDimPoints(d, "w", ppu, cur.width), h = slideDimPoints(d, "h", ppu, cur.height)
            run("design.slideSize", ["w": .num(w), "h": .num(h), "scale": d.flag("max") ? "maximize" : "ensureFit"])
            return true
        case "sizePosition":
            guard id == "ok" else { return nil }
            switch SizePosition.value(d) {
            case .success(let p): return ok("shape.sizePosition", p)
            case .failure(let e):
                status(e.message)
                return false
            }
        case "headerFooter":
            guard id == "apply" || id == "applyAll" else { return nil }
            var p: JSON = [
                "date": .bool(d.flag("date")), "dateText": .string(d.value("dateText")), "slideNumber": .bool(d.flag("num")),
                "footer": .bool(d.flag("footer")), "footerText": .string(d.value("footerText")), "hideOnTitle": .bool(d.flag("hide")),
                "all": .bool(id == "applyAll"),
            ]
            // Only a format the user picked: the default would rewrite every slide's existing date field.
            if let f = d.fields["dateFormat"] { p.set("dateFormat", .string(f)) }
            run("design.headerFooter", p)
            return true
        case "hyperlink":
            guard id == "ok" else { return nil }
            let seed = HyperlinkSeed(
                mode: d.field("seedMode"), url: d.field("seedUrl"), email: d.field("seedEmail"), slide: Int(d.field("seedSlide")) ?? 0,
                tip: "", highlight: d.field("seedHighlight") == "1", preserve: d.field("seedPreserve") == "1"
            )
            let mode = d.value("mode"), url = d.value("url"), email = d.value("email"), slide = Int(d.value("slide")) ?? 0
            if seed.shouldApply(mode: mode, url: url, email: email, slide: slide) {
                run("insert.hyperlink", HyperlinkSeed.command(mode: mode, url: url, email: email, slide: slide, tip: d.value("tip"), highlight: seed.highlight))
            }
            return true
        case "setupShow":
            guard id == "ok" else { return nil }
            run("show.setup", [
                "type": .string(d.value("type").isEmpty ? "speaker" : d.value("type")), "loop": .bool(d.flag("loop")), "noNarration": .bool(d.flag("nn")),
                "noAnimation": .bool(d.flag("na")), "useTimings": .bool(d.flag("ut")), "custom": .string(d.value("custom")),
            ])
            return true
        case "zoom":
            guard id == "ok" else { return nil }
            if d.value("mode") == "fit" {
                model.ui.zoom = nil
            } else if let scale = DialogMath.parseZoomPercent(d.value("percent")) {
                model.ui.zoom = scale
            } else {
                status(L10n.text("Enter a zoom percent"))
                return false
            }
            model.changed()
            return true
        case "comment":
            guard id == "ok" else { return nil }
            let v = d.value("text")
            if !rustTrim(v).isEmpty {
                run("comment.add", ["text": .string(v)])
                model.ui.pane = "comments"
                model.changed()
            }
            return true
        case "altText":
            guard id == "ok" else { return nil }
            run("shape.altText", ["text": .string(d.value("text")), "decorative": .bool(d.flag("deco"))])
            return true
        case "outline":
            guard id == "ok" else { return nil }
            run("slide.fromOutline", ["text": .string(d.value("text"))])
            return true
        case "renameSection", "renameShape", "renameLayout":
            guard id == "ok" else { return nil }
            let name = JSON.string(d.value("name"))
            switch d.id {
            case "renameSection": run("section.rename", ["index": d.params["index"] ?? .null, "name": name])
            case "renameShape": run("shape.rename", ["id": d.params["id"] ?? .null, "name": name])
            default: run("master.renameLayout", ["name": name])
            }
            return true
        case "reuseSlides":
            let list = reuseList(d)
            switch id {
            case "selectAll":
                for (i, _) in list { d.fields["slide\(i)"] = "1" }
                return false
            case "selectNone":
                for (i, _) in list { d.fields["slide\(i)"] = "0" }
                return false
            case "ok":
                let picked = list.map(\.0).filter { d.flag("slide\($0)") && !d.flag("off\($0)") }
                if picked.isEmpty {
                    status(L10n.text("Tick at least one slide to insert"))
                    return false
                }
                // A failed insert keeps the dialog (and the ticked slides) open; the error is in the status bar.
                return reuseSlides(d.params["source"] ?? .emptyObject, keep: d.flag("keep"), picked: picked)
            default: return nil
            }
        case "paragraph": return paragraphAct(&d, id)
        case "tabs": return tabsAct(&d, id)
        case "font": return fontAct(&d, id)
        case "about": return id == "ok" ? true : nil
        case "preferences":
            if id == "autocorrectOptions" {
                // Replaces Preferences (what it opened with is not put back, as in deckcraft).
                open("autocorrect")
                return true
            }
            return id == "ok" ? true : nil
        case "autocorrect":
            switch id {
            case "add":
                let from = String(rustTrim(d.value("from")))
                guard !from.isEmpty else { return false }
                run("text.autocorrect", ["add": [.string(from), .string(d.value("to"))]])
                d.fields["from"] = ""
                d.fields["to"] = ""
                return false
            case "ok": return true
            default:
                if id.hasPrefix("remove:") {
                    run("text.autocorrect", ["remove": .string(String(id.dropFirst(7)))])
                    return false
                }
                return nil
            }
        case "gridOptions":
            guard id == "ok" else { return nil }
            let spacing = DialogMath.number(d.value("spacing")) ?? model.session.prefs.gridSpacing
            switch model.run("view.gridOptions", [
                "spacing": .num(spacing), "snap": .bool(d.flag("snap")), "smartGuides": .bool(d.flag("smart")),
                "gridlines": .bool(d.flag("gridlines")), "guides": .bool(d.flag("guides")),
            ]) {
            case .success: return true
            case .failure(let e):
                d.fields["error"] = e.message
                return false
            }
        case "columns":
            guard id == "ok" else { return nil }
            let applied: Result<Void, CommandError>
            switch DialogParams.columns(d, shownCount: d.field("shownCount"), shownSpacing: d.field("shownSpacing")) {
            case .success(let p?): applied = model.run("format.columns", p).map { _ in () }
            case .success(nil): applied = .success(())
            case .failure(let e): applied = .failure(e)
            }
            if case .failure(let e) = applied {
                d.fields["error"] = e.message
                return false
            }
            return true
        case "export":
            guard id == "ok" else { return nil }
            return exportAct(&d)
        case "symbol":
            if id == "ok" { return true }
            guard id.hasPrefix("symbol:") else { return nil }
            if doc?.selection.text == nil { run("text.edit") }
            run("insert.symbol", ["text": .string(String(id.dropFirst(7)))])
            return false
        case "photoAlbum": return photoAlbumAct(&d, id)
        case "replaceFonts":
            guard id == "ok" else { return nil }
            let from = d.value("from"), to = String(rustTrim(d.value("to")))
            guard !from.isEmpty, !to.isEmpty else { return false }
            let n = (try? model.run("font.replace", ["from": .string(from), "to": .string(to)]).get())?["replaced"]?.asU64 ?? 0
            d.fields["result"] = n == 0 ? L10n.text("“\(from)” isn't used explicitly.") : L10n.text("Replaced “\(from)” with “\(to)”.")
            d.fields["from"] = usedFonts().first ?? ""
            // Stays open, like PowerPoint, so several fonts can be replaced in a row.
            return false
        case "equation":
            guard id == "ok" else { return nil }
            let v = d.value("eq")
            if !v.isEmpty {
                let size = doc?.doc.slideSize ?? Size(960, 540)
                run("insert.textBox", ["rect": [.num(size.width / 2 - 150), .num(size.height / 2 - 25), 300, 50], "text": .string(DialogMath.prettyEquation(v))])
                run("text.exit")
                run("format.font", ["family": "Liberation Serif"])
                run("format.italic", ["on": true])
                run("format.size", ["size": 28])
            }
            return true
        case "dateTime":
            guard id == "ok" else { return nil }
            let lang = d.value("language")
            var format = d.value("format")
            if DateFields.fieldText(format, lang, DateTime(2026, 10, 9, 20, 5, 7)) == nil { format = "datetime1" }
            return ok("insert.dateTime", ["format": .string(format), "update": .bool(d.flag("update")), "language": .string(lang)])
        case "spelling": return spellingAct(&d, id)
        case "pasteSpecial":
            guard id == "ok" else { return nil }
            run("edit.pasteSpecial", ["as": .string(d.value("as"))])
            return true
        case "find": return findAct(&d, id)
        case "accessibility":
            if id == "ok" { return true }
            guard id.hasPrefix("goto:"), let i = Int(id.dropFirst(5)) else { return nil }
            let list = query("review.accessibility")?.asArray ?? []
            if let item = list.at(i) {
                run("slide.go", ["index": item["slide"] ?? 0])
                if let shape = item["shape"] { run("edit.select", ["ids": [shape]]) }
            }
            return false
        case "language":
            guard id == "ok" else { return nil }
            let all = Cmd.hasTextOrShapes(model.session) != nil || d.value("scope") == "all"
            run(all ? "format.languageAll" : "format.language", ["lang": .string(d.value("lang")), "noProof": .bool(d.flag("noProof"))])
            return true
        case "customShow":
            let shows = doc?.doc.customShows ?? []
            if id.hasPrefix("show:"), let s = Int(id.dropFirst(5)).flatMap({ shows.at($0) }) {
                run("show.start", ["custom": .string(s.name)])
                return true
            }
            if id.hasPrefix("delete:"), let s = Int(id.dropFirst(7)).flatMap({ shows.at($0) }) {
                run("show.customShow", ["name": .string(s.name), "delete": true])
                return false
            }
            guard id == "ok" else { return nil }
            let idx = d.value("slides").split(separator: ",").compactMap { UInt64(String(rustTrim(String($0)))) }.filter { $0 > 0 }.map { JSON.integer($0 - 1) }
            run("show.customShow", ["name": .string(d.value("name").isEmpty ? "Custom Show" : d.value("name")), "slides": .array(idx)])
            return true
        case "chartData": return chartDataAct(&d, id)
        case "trim":
            guard id == "ok" else { return nil }
            run("media.options", [
                "trimStart": .integer(DialogMath.secondsTextToMs(d.value("start"))), "trimEnd": .integer(DialogMath.secondsTextToMs(d.value("end"))),
                "fadeIn": .integer(DialogMath.secondsTextToMs(d.value("fin"))), "fadeOut": .integer(DialogMath.secondsTextToMs(d.value("fout"))),
            ])
            return true
        case "smartart":
            guard id == "ok" else { return nil }
            let items = d.value("text").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !rustTrim($0).isEmpty }
            run("insert.smartArt", ["kind": .string(d.value("kind")), "items": .array(items.map { .string($0) })])
            model.ui.pane = "smartart"
            model.changed()
            return true
        case "bullets": return bulletsAct(&d, id)
        case "action":
            guard id == "ok" else { return nil }
            let kind = d.value("kind"), arg = d.value("arg")
            var p: JSON = ["on": .string(d.value("tab")), "action": .string(kind), "highlight": .bool(d.flag("highlight"))]
            switch kind {
            case "url": p.set("url", .string(arg))
            case "slide": p.set("slide", .integer(Int(arg) ?? 0))
            case "customShow": p.set("show", .string(arg))
            case "program": p.set("path", .string(arg))
            default: break
            }
            run("shape.action", p)
            return true
        case "themeColors":
            guard id == "ok" else { return nil }
            switch DialogPayloads.themeColors(d) {
            case .success(let p): return ok("design.colors", p)
            case .failure(let e):
                status(e.message)
                return false
            }
        case "themeFonts":
            guard id == "ok" else { return nil }
            switch DialogPayloads.themeFonts(d) {
            case .success(let p): return ok("design.fonts", p)
            case .failure(let e):
                status(e.message)
                return false
            }
        case "info": return infoAct(&d, id)
        case "new": return newAct(id)
        default:
            return id == "ok" ? true : nil
        }
    }

    // MARK: Paragraph, Tabs, Font

    func paragraphAct(_ d: inout Dialog, _ id: String) -> Bool? {
        switch id {
        case "tabs":
            let ret = DialogParams.paragraphReturn(&d)
            open("tabs", params: [
                "tabs": d.params["tabs"] ?? [], "defaultTab": d.params["defaultTab"] ?? .double(72), "returnId": "paragraph", "returnParams": ret,
            ])
            return true
        case "ok":
            let pt = DialogMath.finitePt
            guard let beforeIn = pt(d.value("before")) else { status(L10n.text("Indent before text must be a number of inches")); return false }
            guard let afterIn = pt(d.value("after")) else { status(L10n.text("Indent after text must be a number of inches")); return false }
            guard let byIn = pt(d.value("by")) else { status(L10n.text("Special indent must be a number of inches")); return false }
            guard let spaceBefore = pt(d.value("spaceBefore")) else { status(L10n.text("Spacing before must be a number")); return false }
            guard let spaceAfter = pt(d.value("spaceAfter")) else { status(L10n.text("Spacing after must be a number")); return false }
            guard let lineValue = pt(d.value("lineValue")) else { status(L10n.text("Line spacing must be a number")); return false }
            let beforeSame = d.value("spaceBefore") == d.value("spaceBeforeSeed")
            let afterSame = d.value("spaceAfter") == d.value("spaceAfterSeed")
            var p: JSON = [
                "align": .string(d.value("align")), "indentLeft": .num(beforeIn * 72), "indentRight": .num(afterIn * 72),
                "special": .string(d.value("special")), "specialBy": .num(byIn * 72), "spaceBefore": .num(spaceBefore), "spaceAfter": .num(spaceAfter),
                "spaceBeforeKind": .string(beforeSame ? d.params["spaceBeforeKind"]?.asStr ?? "pts" : "pts"),
                "spaceAfterKind": .string(afterSame ? d.params["spaceAfterKind"]?.asStr ?? "pts" : "pts"),
            ]
            p.set(d.value("lineKind") == "exactly" ? "lineSpacingPt" : "lineSpacing", .num(lineValue))
            return ok("format.paragraphDialog", p)
        default: return nil
        }
    }

    func tabsAct(_ d: inout Dialog, _ id: String) -> Bool? {
        var stops = tabStops(d)
        func store() { d.fields["stops"] = stops.map { "\($0.0):\($0.1)" }.joined(separator: "|") }
        switch id {
        case "set":
            if let p = DialogMath.number(d.value("newpos")), p >= 0, p <= 56 {
                stops.removeAll { abs($0.0 - p) <= 0.005 }
                stops.append((p, d.value("newalign")))
                stops.sort { $0.0 < $1.0 }
                d.fields["newpos"] = ""
                store()
            }
            return false
        case "clearAll":
            stops.removeAll()
            store()
            return false
        case "ok":
            let set: [JSON] = stops.map { ["pos": .num($0.0 * 72), "align": .string($0.1)] }
            let dt = (DialogMath.number(d.value("default")) ?? 1).clamped(0.02, 56) * 72
            if case .success = model.run("format.tabs", ["set": .array(set), "defaultTab": .num(dt)]), var ret = d.params["returnParams"], ret.isObject {
                // Back in Paragraph, its Tabs… shows what was just applied.
                ret.set("tabs", .array(set))
                ret.set("defaultTab", .num(dt))
                d.params.set("returnParams", ret)
            }
            return true
        default:
            if id.hasPrefix("clear:"), let i = Int(id.dropFirst(6)), stops.indices.contains(i) {
                stops.remove(at: i)
                store()
                return false
            }
            return nil
        }
    }

    func fontAct(_ d: inout Dialog, _ id: String) -> Bool? {
        guard id == "ok" else { return nil }
        let family = String(rustTrim(d.value("family")))
        guard !family.isEmpty else { status(L10n.text("Choose a font")); return false }
        guard let size = DialogMath.finitePt(d.value("size")) else { status(L10n.text("Font size must be a number")); return false }
        guard let spacing = DialogMath.finitePt(d.value("spacing")) else { status(L10n.text("Character spacing must be a number")); return false }
        var p: JSON = [
            "family": .string(family), "size": .num(size), "bold": .bool(d.flag("bold")), "italic": .bool(d.flag("italic")),
            "underline": .string(d.value("underline")), "strike": .string(d.value("strike")), "baseline": .string(d.value("baseline")),
            "caps": .string(d.value("caps")), "spacing": .num(spacing),
        ]
        let color = d.value("color")
        if color == d.value("colorSeed") {
            if let c = d.params["color"], !c.isNull { p.set("color", c) }
        } else if !rustTrim(color).isEmpty {
            p.set("color", .string(String(rustTrim(color))))
        }
        run("format.fontDialog", p)
        return true
    }

    // MARK: Export

    func exportAct(_ d: inout Dialog) -> Bool {
        let fmt = d.value("fmt")
        let extra: JSON
        switch fmt {
        case "pdf":
            let layout = d.value("pdfLayout")
            let (name, per): (String, Int) = layout == "notes" ? ("notes", 0) : layout.hasPrefix("h") ? ("handouts", Int(layout.dropFirst()) ?? 6) : ("slides", 0)
            extra = ["layout": .string(name), "perPage": .integer(per), "includeHidden": .bool(d.flag("pdfHidden"))]
        case "gif":
            switch DialogParams.gif(&d, slides: doc?.doc.slides.count ?? 0) {
            case .success(let p): extra = p
            case .failure(let e):
                // Keep the dialog open so the range or width can be corrected.
                status(e.message)
                return false
            }
        case "png", "pngAll":
            extra = d.flag("pngTransparent") ? ["transparentBackground": true] : .emptyObject
        default:
            extra = .emptyObject
        }
        exportAs(fmt, extra)
        return true
    }

    /// `export_as`: the save panel, then `file.export` with `extra`. The presentation keeps its own file.
    /// Returns false when the format is unknown or there is nothing to export.
    @discardableResult
    public func exportAs(_ fmt: String, _ extra: JSON, completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        guard let st = doc else { return false }
        let table: [String: (String, String, Bool)] = [
            "pdf": ("pdf", "pdf", false), "png": ("png", "png", false), "pngAll": ("png", "png", true), "jpeg": ("jpg", "jpeg", false),
            "jpg": ("jpg", "jpeg", false), "pptx": ("pptx", "pptx", false), "outline": ("txt", "outline", false), "txt": ("txt", "outline", false),
            "rtf": ("rtf", "rtf", false), "deckcraft": ("deckcraft", "deckcraft", false), "gif": ("gif", "gif", false),
        ]
        guard let (ext, format, all) = table[fmt] else {
            status(L10n.text("DeckCraftNative can't export “\(fmt)”"))
            return false
        }
        guard let services else {
            status(L10n.text("Exporting needs the app's save panel"))
            return false
        }
        let base = (st.title as NSString).deletingPathExtension
        services.pickSave("\(base.isEmpty ? String(localized: "Presentation", bundle: .module, comment: "The file name suggested when exporting an untitled presentation") : base).\(ext)") { [weak self] path in
            guard let self, let path else {
                completion?(false)
                return
            }
            var p: JSON = ["path": .string(path), "format": .string(format), "all": .bool(all)]
            for e in extra.asObject?.entries ?? [] { p.set(e.key, e.value) }
            let done = self.ok("file.export", p)
            if done { self.status(L10n.text("Exported \(path)")) }
            completion?(done)
        }
        return true
    }

    // MARK: Photo Album

    func photoAlbumAct(_ d: inout Dialog, _ id: String) -> Bool? {
        switch id {
        case "addPictures":
            pickAlbumPicture()
            return false
        case "newTextBox":
            let text = String(rustTrim(d.value("boxText")))
            if text.isEmpty {
                status(L10n.text("Type the text for the new text box"))
            } else if text.charCount > 400 {
                status(L10n.text("Text is longer than 400 characters"))
            } else if var list = DialogAlbum.items(d) {
                if list.count >= 48 {
                    status(L10n.text("A photo album holds at most 48 pictures or text boxes"))
                } else {
                    list.append(["text": .string(text)])
                    DialogAlbum.store(&d, list)
                    d.fields["sel"] = String(list.count - 1)
                }
            }
            return false
        case "remove":
            if var list = DialogAlbum.items(d), let i = Int(d.value("sel")), list.indices.contains(i) {
                list.remove(at: i)
                DialogAlbum.store(&d, list)
                d.fields["sel"] = String(Swift.min(i, Swift.max(list.count - 1, 0)))
            }
            return false
        case "rotateLeft", "rotateRight":
            let delta: Double = id == "rotateLeft" ? -90 : 90
            DialogAlbum.withSelected(&d) { obj in
                let cur = obj["rot"]?.asF64 ?? 0
                obj.set("rot", .num(((cur + delta).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)))
            }
            return false
        case "moreBrightness": DialogAlbum.nudge(&d, "brightness", 0.1); return false
        case "lessBrightness": DialogAlbum.nudge(&d, "brightness", -0.1); return false
        case "moreContrast": DialogAlbum.nudge(&d, "contrast", 0.1); return false
        case "lessContrast": DialogAlbum.nudge(&d, "contrast", -0.1); return false
        case "ok":
            guard let list = DialogAlbum.items(d) else { status(L10n.text("The picture list is invalid")); return false }
            if list.isEmpty {
                status(L10n.text("Add a picture or a text box first"))
                return false
            }
            var p: JSON = [
                "pictures": .array(list), "layout": .string(d.value("layout")), "frame": .string(d.value("frame")),
                "captions": .bool(d.flag("captions")), "grayscale": .bool(d.flag("grayscale")),
            ]
            if d.value("theme") != d.field("themeWas") { p.set("theme", .string(d.value("theme"))) }
            if d.flag("editing") {
                if let album = UInt64(d.field("album")), album != 0 { p.set("album", .integer(album)) }
                return ok("insert.photoAlbumEdit", p)
            }
            return ok("insert.photoAlbum", p)
        default: return nil
        }
    }

    /// `pick_album_picture`: a picture from the open panel, added to the open album's list.
    func pickAlbumPicture() {
        guard let services else {
            status(L10n.text("Pass pictures to insert.photoAlbum"))
            return
        }
        let gen = generation
        services.pickOpen("picture") { [weak self] path in
            guard let self, let path, self.generation == gen, var d = self.current, d.id == "photoAlbum" else { return }
            guard let item = self.albumPicture(path) else { return }
            switch DialogAlbum.items(d) {
            case .some(var list) where list.count < 48:
                list.append(item)
                DialogAlbum.store(&d, list)
                d.fields["sel"] = String(list.count - 1)
                self.current = d
            case .some: self.status(L10n.text("A photo album holds at most 48 pictures or text boxes"))
            case .none: self.status(L10n.text("The picture list is invalid"))
            }
        }
    }

    func albumPicture(_ path: String) -> JSON? {
        let bytes: [UInt8]
        do { bytes = [UInt8](try Data(contentsOf: URL(filePath: path))) } catch {
            status("\(path): \(error.localizedDescription)")
            return nil
        }
        if bytes.isEmpty { status(L10n.text("That file is empty")); return nil }
        if bytes.count > 32 * 1024 * 1024 { status(L10n.text("That picture is larger than 32 MB")); return nil }
        let name = (path as NSString).lastPathComponent
        return ["name": .string(name.isEmpty ? "picture" : name), "data": .string(Cmd.base64Encode(bytes))]
    }

    // MARK: Spelling

    func spellingAct(_ d: inout Dialog, _ id: String) -> Bool? {
        if id == "ok" { return true }
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count >= 2, let i = Int(parts[1]) else { return nil }
        let list = spellingList(d)
        guard let item = list.at(i) else { return false }
        let w = item["word"]?.asStr ?? ""
        let slide = item["slide"] ?? 0
        let shape = item["shape"] ?? .null
        switch parts[0] {
        case "goto":
            run("slide.go", ["index": slide])
            run("edit.select", ["ids": [shape]])
        case "ignoreAll":
            d.fields["ignore"] = d.value("ignore") + w + "\n"
        case "addWord":
            do { _ = try model.session.execute("review.addToDictionary", ["word": .string(w)]) } catch { status(error.description) }
        case "deleteRepeated":
            let from = item["deleteFrom"]?.asUsize ?? 0, end = item["end"]?.asUsize ?? 0, para = item["para"]?.asUsize ?? 0
            if let gap = repeatedGap(item, shape: shape, para: para, from: from, end: end) {
                var p: JSON = ["shape": shape, "para": .integer(para), "start": .integer(from), "word": .string(gap), "to": ""]
                if let r = item["row"], let c = item["col"] {
                    p.set("row", r)
                    p.set("col", c)
                }
                run("review.spellingChange", p)
            }
        case "change", "changeAll":
            let sug = (item["suggestions"]?.asArray ?? []).compactMap(\.asStr)
            guard parts.count == 3, let j = Int(parts[2]), let to = sug.at(j) else { return false }
            if item["notes"]?.asBool == true {
                changeInNotes(item, word: w, to: to)
            } else if parts[0] == "changeAll" {
                run("review.spellingChange", ["word": .string(w), "to": .string(to), "all": true])
            } else {
                var p: JSON = ["shape": shape, "word": .string(w), "to": .string(to), "para": item["para"] ?? .null, "start": item["start"] ?? .null]
                if let r = item["row"], let c = item["col"] {
                    p.set("row", r)
                    p.set("col", c)
                }
                run("review.spellingChange", p)
            }
        default: return nil
        }
        return false
    }

    func repeatedGap(_ item: JSON, shape: JSON, para: Int, from: Int, end: Int) -> String? {
        guard let st = doc, let raw = shape.asU32, let sh = st.shape(ShapeId(raw)) else { return nil }
        let text: String?
        if let r = item["row"]?.asUsize, let c = item["col"]?.asUsize, case .table(let tb) = sh.kind {
            text = tb.cell(r, c)?.text.paragraphs.at(para)?.text
        } else {
            text = sh.text?.paragraphs.at(para)?.text
        }
        guard let pp = text else { return nil }
        return String(String.UnicodeScalarView(pp.unicodeScalars.dropFirst(from).prefix(Swift.max(end - from, 0))))
    }

    /// A word in the notes: change that line of the slide's notes.
    func changeInNotes(_ item: JSON, word w: String, to: String) {
        let si = item["slide"]?.asUsize ?? 0
        let notes = doc?.doc.slides.at(si)?.notesText ?? ""
        let pi = item["para"]?.asUsize ?? 0, start = item["start"]?.asUsize ?? 0
        let n = w.unicodeScalars.count
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, l -> String in
            let c = Array(l.unicodeScalars)
            guard i == pi, n <= c.count, start <= c.count - n, String(String.UnicodeScalarView(c[start ..< start + n])) == w else { return String(l) }
            return String(String.UnicodeScalarView(c[..<start])) + to + String(String.UnicodeScalarView(c[(start + n)...]))
        }
        run("slide.notes", ["text": .string(lines.joined(separator: "\n")), "index": .integer(si)])
    }

    // MARK: Find

    func findAct(_ d: inout Dialog, _ id: String) -> Bool? {
        let text = d.value("text")
        let q: JSON = ["text": .string(text), "matchCase": .bool(d.flag("matchCase")), "wholeWords": .bool(d.flag("wholeWords"))]
        var findNext = false
        switch id {
        case "findNext": findNext = !text.isEmpty
        case "showReplace":
            d.fields["replace"] = "1"
            return false
        case "replaceOne":
            if let cur = try? JSONParser.parse(d.value("cur")), !text.isEmpty {
                var p = q
                p.set("with", .string(d.value("with")))
                p.set("at", cur)
                if (try? model.session.execute("text.replace", p)) != nil {
                    let n = UInt(d.value("next")) ?? 1
                    d.fields["next"] = String(n > 0 ? n - 1 : 0)
                    model.changed()
                }
            }
            findNext = !text.isEmpty
        case "replaceAll":
            guard !text.isEmpty else { return false }
            var p = q
            p.set("with", .string(d.value("with")))
            if let v = try? model.session.execute("text.replace", p) {
                d.fields["status"] = L10n.text("Replaced \(v["replaced"]?.asU64 ?? 0) occurrence(s).")
                model.changed()
            } else {
                d.fields["status"] = L10n.text("DeckCraftNative can't find “\(text)”.")
            }
            d.fields["cur"] = nil
            return false
        default: return nil
        }
        if findNext {
            let list = query("text.find", q)?.asArray ?? []
            if list.isEmpty {
                d.fields["status"] = L10n.text("DeckCraftNative can't find “\(text)”.")
                d.fields["cur"] = nil
            } else {
                let n = Int((UInt(d.value("next")) ?? 0) % UInt(list.count))
                let m = list[n]
                run("slide.go", ["index": m["slide"] ?? 0])
                if let shape = m["shape"], !shape.isNull { run("edit.select", ["ids": [shape]]) }
                d.fields["cur"] = JSONWriter().string(m)
                d.fields["next"] = String(n + 1)
                let notes = m["shape"]?.isNull ?? false ? String(localized: " (notes)", bundle: .module, comment: "After a find match: it is in the speaker notes") : ""
                d.fields["status"] = L10n.text("Match \(n + 1) of \(list.count) on slide \((m["slide"]?.asU64 ?? 0) + 1)\(notes).")
            }
        }
        return false
    }

    // MARK: Chart Data, Bullets

    func chartDataAct(_ d: inout Dialog, _ id: String) -> Bool? {
        guard let (_, shapeId) = chartOf(model.session) else { return id == "ok" ? true : nil }
        var grid = chartGrid(d)
        switch id {
        case "addRow":
            grid.append(Array(repeating: "", count: grid.first?.count ?? 2))
        case "addSeries":
            for i in grid.indices { grid[i].append("") }
        case "ok":
            let names = Array(grid.first?.dropFirst() ?? [])
            let cats: [JSON] = grid.dropFirst().map { .string($0.first ?? "") }
            let series: [JSON] = names.enumerated().map { k, n in
                ["name": .string(n), "values": .array(grid.dropFirst().map { r in
                    r.at(k + 1).flatMap { DialogMath.finite(rustTrim($0)) }.map { JSON.num($0) } ?? .null
                })]
            }
            run("chart.data", ["id": .integer(shapeId.rawValue), "categories": .array(cats), "series": .array(series)])
            return true
        default: return nil
        }
        d.params = ["grid": .array(grid.map { .array($0.map { .string($0) }) })]
        return false
    }

    func bulletsAct(_ d: inout Dialog, _ id: String) -> Bool? {
        let numbered = d.value("tab") == "numbered"
        switch id {
        case "none":
            run(numbered ? "format.numbering" : "format.bullets", ["on": false])
            return true
        case "ok":
            var p: JSON = ["on": true]
            if let size = DialogMath.finite(DialogMath.trimEnd(d.value("size"), ["%"])) { p.set("size", .num(size.clamped(25, 400))) }
            if !d.value("color").isEmpty { p.set("color", .string(d.value("color"))) }
            if numbered {
                p.set("scheme", .string(d.value("scheme")))
                p.set("start", .integer(Swift.min(Swift.max(UInt64(String(rustTrim(d.value("start")))) ?? 1, 1), 32767)))
                run("format.numbering", p)
            } else {
                let custom = d.value("custom").first { !$0.isWhitespace }.map(String.init)
                p.set("char", .string(custom ?? d.value("char")))
                run("format.bullets", p)
            }
            return true
        default: return nil
        }
    }

    // MARK: Info, New

    func infoAct(_ d: inout Dialog, _ id: String) -> Bool? {
        let path = query("file.info")?["path"]?.asStr
        switch id {
        case "copyPath":
            if let path {
                services?.copyText(path)
                status(L10n.text("Copied the path"))
            }
            return false
        case "reveal":
            if let path { services?.openURL(URL(filePath: path).deletingLastPathComponent().absoluteString) }
            return false
        case "checkIssues":
            commitProperties(d)
            open("accessibility")
            return true
        case "revert":
            run("file.revert")
            return false
        case "ok":
            commitProperties(d)
            return true
        default: return nil
        }
    }

    /// `commit_props`: the property fields that differ from the presentation's, through `file.properties`.
    func commitProperties(_ d: Dialog) {
        guard let v = query("file.info") else { return }
        var p = JSONObject()
        for (k, _, _) in DialogBackstage.properties where (v["properties"]?[k]?.asStr ?? "") != d.value(k) {
            p.set(k, .string(d.value(k)))
        }
        if !p.isEmpty { run("file.properties", .object(p)) }
    }

    func newAct(_ id: String) -> Bool? {
        // The start window's tiles: `new:` and the tile's id.
        guard id.hasPrefix("new:") else { return nil }
        let tile = String(id.dropFirst(4))
        guard tile == "sample" || StartCatalog.newParams(tile) != nil else { return nil }
        StartCatalog.create(tile, in: model)
        return true
    }

    // MARK: Preferences

    /// `preferences_snapshot`: what the Preferences dialog can change, as it was when it opened.
    func preferencesSnapshot() -> JSON {
        ["brightness": .string(model.ui.brightness.rawValue), "uiScale": .num(model.ui.uiScale), "layout": .string(model.ui.layout.rawValue), "prefs": model.session.prefs.toJSON(),
         "startScreen": .bool(model.ui.showStartScreen)]
    }

    /// `restore_preferences`: puts back what the Preferences dialog opened with (Cancel, Esc, the close button).
    func restorePreferences(_ d: Dialog) {
        guard let before = d.params["before"] else { return }
        if let b = before["brightness"]?.asStr.flatMap(Brightness.init(rawValue:)) { model.ui.brightness = b }
        if let s = before["uiScale"]?.asF64 { model.ui.uiScale = s }
        if let l = before["layout"]?.asStr.flatMap(WindowLayout.init(rawValue:)), l != model.ui.layout { model.run("view.ribbon", ["on": .bool(l == .ribbon)]) }
        if let s = before["startScreen"]?.asBool { model.ui.showStartScreen = s }
        if let p = before["prefs"], let prefs = try? Prefs(fromJSON: p) { model.session.prefs = prefs }
        model.changed()
    }

    /// A Preferences control applies as it changes.
    func applyPreference(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "appearance":
            if let b = Brightness(rawValue: value) { model.ui.brightness = b }
        case "layout":
            if let l = WindowLayout(rawValue: value), l != model.ui.layout { model.run("view.ribbon", ["on": .bool(l == .ribbon)]) }
        case "units": model.session.prefs.units = value == "centimeters" ? .centimeters : .inches
        case "startScreen": model.ui.showStartScreen = on
        case "smartGuides":
            model.session.prefs.smartGuides = on
            model.ui.smartGuides = on
        case "snapToGrid": model.session.prefs.snapToGrid = on
        case "smartQuotes": model.session.prefs.smartQuotes = on
        case "autocorrect": model.session.prefs.autocorrect = on
        case "author": model.session.prefs.author = value
        default: return
        }
        model.session.prefs = model.session.prefs.sanitized()
        model.changed()
    }

    func applyAutocorrect(_ key: String, _ on: Bool) {
        switch key {
        case "acTwoInitials": model.session.prefs.acTwoInitials = on
        case "acSentenceCaps": model.session.prefs.acSentenceCaps = on
        case "acDays": model.session.prefs.acDays = on
        case "acCapsLock": model.session.prefs.acCapsLock = on
        case "acFractions": model.session.prefs.acFractions = on
        case "acOrdinals": model.session.prefs.acOrdinals = on
        case "acLists": model.session.prefs.acLists = on
        case "replaceText": model.session.prefs.autocorrect = on
        default: break
        }
    }
}

/// `theme_color_payload`, `theme_font_payload`.
enum DialogPayloads {
    static func themeColors(_ d: Dialog) -> Result<JSON, CommandError> {
        let name = String(rustTrim(d.value("schemeName")))
        if name.isEmpty { return .failure(CommandError(L10n.text("Enter a scheme name."))) }
        var colors = JSONObject()
        for slot in SchemeSlot.theme {
            guard let rgb = Rgba.fromHex(String(rustTrim(d.value(slot.xmlName)))) else {
                return .failure(CommandError(L10n.text("\(L10n.colorLabel(slot.label)) needs a colour like #RRGGBB.")))
            }
            colors.set(slot.xmlName, .string("#\(rgb.hex)"))
        }
        return .success(["name": .string(name), "colors": .object(colors)])
    }

    static func themeFonts(_ d: Dialog) -> Result<JSON, CommandError> {
        let name = String(rustTrim(d.value("schemeName")))
        if name.isEmpty { return .failure(CommandError(L10n.text("Enter a scheme name."))) }
        let major = String(rustTrim(d.value("major")))
        if major.isEmpty { return .failure(CommandError(L10n.text("Choose a heading font."))) }
        let minor = String(rustTrim(d.value("minor")))
        if minor.isEmpty { return .failure(CommandError(L10n.text("Choose a body font."))) }
        return .success(["name": .string(name), "major": .string(major), "minor": .string(minor)])
    }
}
