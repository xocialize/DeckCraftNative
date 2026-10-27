// DCAppModel — what each dialog starts with and the form it shows. Port of the seeding and drawing halves
// of `body` and the `*_dialog` functions in deckcraft `crates/ui-egui/src/dialogs.rs`, and of the Info and
// New pages of `backstage.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// deckcraft seeds a field the first frame it draws it (`d.get(key, default)`); here every field is seeded
// when the dialog opens, so the form is a pure function of the fields.
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation

extension DialogController {
    var doc: DocState? { model.session.activeDoc }

    /// The first selected chart and its shape id (`chartData`).
    func chartOf(_ s: Session) -> (Chart, ShapeId)? {
        guard let st = s.activeDoc else { return nil }
        for sh in st.selectedShapes { if case .chart(let c) = sh.kind { return (c, sh.id) } }
        return nil
    }

    /// The selection's slide titles, numbered (`"{i+1}. {title}"`).
    var slideTitles: [String] { doc.map { $0.doc.slides.enumerated().map { "\($0.offset + 1). \($0.element.title)" } } ?? [] }

    /// Fill in what dialog `d` starts with.
    func seed(_ d: inout Dialog) {
        let st = doc
        let prefs = model.session.prefs
        switch d.id {
        case "table":
            d.seed("cols", "5")
            d.seed("rows", "2")
        case "slideSize":
            let cur = st?.doc.slideSize ?? Size(960, 540)
            let ppu = prefs.units.pointsPerUnit
            if d.fields["wPt"] == nil {
                putSlideDim(&d, "w", cur.width, ppu)
                putSlideDim(&d, "h", cur.height, ppu)
            }
            d.seed("preset", "")
            d.seed("max", "0")
            syncOrientation(&d)
        case "sizePosition":
            SizePosition.seed(&d, st)
        case "headerFooter":
            let hf = st?.doc.headerFooter ?? HeaderFooter()
            d.seed("date", hf.date ? "1" : "0")
            d.seed("dateText", hf.dateText)
            d.seed("num", hf.slideNumber ? "1" : "0")
            d.seed("footer", hf.footer ? "1" : "0")
            d.seed("footerText", hf.footerText)
            d.seed("hide", hf.hideOnTitle ? "1" : "0")
            d.shown["dateFormat"] = hf.dateFormat.isEmpty ? "datetime1" : hf.dateFormat
        case "hyperlink":
            let s = HyperlinkSeed.of(st)
            d.fields["seedMode"] = s.mode
            d.fields["seedUrl"] = s.url
            d.fields["seedEmail"] = s.email
            d.fields["seedSlide"] = String(s.slide)
            d.fields["seedPreserve"] = s.preserve ? "1" : "0"
            d.fields["seedHighlight"] = s.highlight ? "1" : "0"
            d.seed("mode", s.mode)
            d.seed("url", s.url)
            d.seed("email", s.email)
            d.seed("slide", String(s.slide))
            d.seed("tip", s.tip)
        case "setupShow":
            if let sh = st?.doc.show {
                d.seed("type", sh.showType)
                d.seed("loop", sh.loopUntilEsc ? "1" : "0")
                d.seed("nn", sh.withoutNarration ? "1" : "0")
                d.seed("na", sh.withoutAnimation ? "1" : "0")
                d.seed("ut", sh.useTimings ? "1" : "0")
                d.seed("custom", sh.customShow ?? "")
            } else {
                for (k, v) in [("type", "speaker"), ("loop", "0"), ("nn", "0"), ("na", "0"), ("ut", "1"), ("custom", "")] { d.seed(k, v) }
            }
        case "zoom":
            if d.fields["mode"] == nil {
                let shown = model.ui.zoom ?? model.canvasScale
                let pct = shown.isFinite ? (shown * 100).rounded().clamped(10, 400) : 100
                d.fields["mode"] = model.ui.zoom == nil ? "fit" : "percent"
                d.fields["percent"] = rustFixed(pct, places: 0)
            }
            syncZoomPick(&d)
        case "comment", "outline", "equation":
            d.seed(d.id == "equation" ? "eq" : "text", "")
        case "altText":
            let shapes = st?.selectedShapes ?? []
            d.seed("text", shapes.first?.descr ?? "")
            d.seed("deco", DialogMath.altTextStartsDecorative(shapes.map(\.decorative)) ? "1" : "0")
        case "renameSection", "renameShape", "renameLayout":
            d.seed("name", d.params["name"]?.asStr ?? "")
        case "reuseSlides":
            d.seed("keep", d.params["keep"]?.asBool == true ? "1" : "0")
            for (i, _) in reuseList(d) { d.seed("slide\(i)", "1") }
        case "paragraph":
            seedParagraph(&d)
        case "tabs":
            seedTabs(&d)
        case "font":
            seedFont(&d)
        case "preferences":
            if d.params["before"] == nil { d.params = ["before": preferencesSnapshot()] }
            d.seed("appearance", model.ui.brightness.rawValue)
            d.seed("units", prefs.units == .centimeters ? "centimeters" : "inches")
            d.seed("smartGuides", prefs.smartGuides ? "1" : "0")
            d.seed("snapToGrid", prefs.snapToGrid ? "1" : "0")
            d.seed("smartQuotes", prefs.smartQuotes ? "1" : "0")
            d.seed("autocorrect", prefs.autocorrect ? "1" : "0")
            d.seed("author", prefs.author)
        case "autocorrect":
            for (k, v) in autocorrectFlags(prefs) { d.seed(k, v ? "1" : "0") }
            d.seed("from", "")
            d.seed("to", "")
        case "gridOptions":
            d.seed("snap", prefs.snapToGrid ? "1" : "0")
            d.seed("smart", prefs.smartGuides ? "1" : "0")
            d.seed("spacing", DialogMath.formatSpacing(prefs.gridSpacing))
            d.seed("gridlines", model.ui.gridlines ? "1" : "0")
            d.seed("guides", model.ui.guides ? "1" : "0")
        case "columns":
            let count = String(d.params["count"]?.asU64 ?? 1)
            let spacing = DialogMath.fmtNum((d.params["spacing"]?.asF64 ?? 0) / 72)
            d.fields["shownCount"] = count
            d.fields["shownSpacing"] = spacing
            d.seed("count", count)
            d.seed("spacing", spacing)
        case "export":
            let n = st?.doc.slides.count ?? 0
            for (k, v) in [
                ("fmt", "pdf"), ("pdfLayout", "slides"), ("pdfHidden", "0"), ("pngTransparent", "0"), ("gifSize", "medium"),
                ("gifWidth", "960"), ("gifSeconds", "5"), ("gifFrom", "1"), ("gifTo", String(Swift.max(n, 1))), ("gifLoop", "1"),
                ("gifHidden", "0"),
            ] { d.seed(k, v) }
        case "photoAlbum":
            seedPhotoAlbum(&d)
        case "replaceFonts":
            let used = usedFonts()
            d.seed("from", used.first ?? "")
            d.seed("to", "")
        case "dateTime":
            d.seed("language", "en-US")
            d.seed("format", "datetime1")
            d.seed("update", "1")
            fixDateFormat(&d)
        case "spelling":
            d.seed("ignore", "")
        case "pasteSpecial":
            d.seed("as", "destinationTheme")
        case "find":
            for (k, v) in [("text", ""), ("with", ""), ("matchCase", "0"), ("wholeWords", "0"), ("replace", "0"), ("status", "")] { d.seed(k, v) }
        case "language":
            let (cur, np) = DialogLists.selectedLanguage(model.session)
            d.fields["current"] = cur
            d.seed("lang", cur)
            d.seed("noProof", np ? "1" : "0")
            d.seed("scope", Cmd.hasTextOrShapes(model.session) == nil ? "sel" : "all")
        case "customShow":
            d.seed("name", "Custom Show 1")
            d.seed("slides", "1")
        case "chartData":
            if d.params["grid"] == nil, let (c, _) = chartOf(model.session) {
                var g: [[String]] = [[""] + c.series.map(\.name)]
                for (i, cat) in c.categories.enumerated() {
                    g.append([cat] + c.series.map { s in s.values.at(i).flatMap { $0 }.map { String($0) } ?? "" })
                }
                d.params = ["grid": .array(g.map { .array($0.map { .string($0) }) })]
            }
        case "trim":
            let s = TrimSeed.of(st)
            d.seed("start", s.start)
            d.seed("end", s.end)
            d.seed("fin", s.fadeIn)
            d.seed("fout", s.fadeOut)
        case "smartart":
            d.seed("kind", "process")
            d.seed("text", "Plan\nBuild\nLaunch")
        case "bullets":
            let numbered = query("format.state")?["numbering"]?.asBool ?? false
            for (k, v) in [("tab", numbered ? "numbered" : "bulleted"), ("char", "•"), ("scheme", "arabicPeriod"), ("custom", ""), ("start", "1"), ("size", "100"), ("color", "")] {
                d.seed(k, v)
            }
        case "action":
            seedAction(&d)
        case "themeColors":
            if d.fields["seeded"] == nil {
                d.fields["schemeName"] = d.params["name"]?.asStr ?? "Custom"
                for slot in SchemeSlot.theme {
                    d.fields[slot.xmlName] = d.params["colors"]?[slot.xmlName]?.asStr ?? "000000"
                }
                d.fields["seeded"] = "1"
            }
        case "themeFonts":
            if d.fields["seeded"] == nil {
                let major = d.params["major"]?.asStr ?? "Inter"
                d.fields["schemeName"] = d.params["name"]?.asStr ?? "Custom"
                d.fields["major"] = major
                d.fields["minor"] = d.params["minor"]?.asStr ?? major
                d.fields["seeded"] = "1"
            }
        case "info":
            if let v = query("file.info") {
                for (k, _, _) in DialogBackstage.properties { d.seed(k, v["properties"]?[k]?.asStr ?? "") }
            }
        case "new":
            d.seed("query", "")
        case "about":
            d.seed("tab", "about")
        default:
            break
        }
    }

    // MARK: Seeding helpers

    /// `put_slide_dim`.
    func putSlideDim(_ d: inout Dialog, _ key: String, _ pt: Double, _ ppu: Double) {
        d.fields[key] = rustFixed(pt / ppu, places: 2)
        d.fields["\(key)Pt"] = String(pt)
    }

    /// `slide_dim_points`.
    func slideDimPoints(_ d: Dialog, _ key: String, _ ppu: Double, _ def: Double) -> Double {
        let text = d.field(key)
        if let pt = DialogMath.parseShown(d.field("\(key)Pt")), text == rustFixed(pt / ppu, places: 2) { return pt }
        return DialogMath.number(text).map { $0 * ppu } ?? def
    }

    func syncOrientation(_ d: inout Dialog) {
        let ppu = model.session.prefs.units.pointsPerUnit
        let cur = doc?.doc.slideSize ?? Size(960, 540)
        let w = slideDimPoints(d, "w", ppu, cur.width), h = slideDimPoints(d, "h", ppu, cur.height)
        d.fields["orientation"] = h > w ? "portrait" : "landscape"
    }

    func syncZoomPick(_ d: inout Dialog) {
        let mode = d.field("mode"), pct = d.field("percent")
        d.fields["zoomPick"] = mode == "fit" ? "fit" : DialogLists.zoomPresets.contains { String($0) == pct } ? pct : ""
    }

    func seedParagraph(_ d: inout Dialog) {
        let p = d.params
        func inches(_ v: JSON?) -> String { DialogMath.fmtNum((v?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? 0) / 72) }
        func pts(_ v: JSON?, _ def: Double) -> String { DialogMath.fmtNum(v?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? def) }
        d.seed("align", DialogMath.jsonText(p["align"], "left"))
        d.seed("before", inches(p["indentLeft"]))
        d.seed("after", inches(p["indentRight"]))
        d.seed("special", DialogMath.jsonText(p["special"], "none"))
        d.seed("by", inches(p["specialBy"]))
        d.seed("spaceBefore", pts(p["spaceBefore"], 0))
        d.seed("spaceBeforeSeed", pts(p["spaceBefore"], 0))
        d.seed("spaceAfter", pts(p["spaceAfter"], 0))
        d.seed("spaceAfterSeed", pts(p["spaceAfter"], 0))
        d.seed("lineKind", DialogMath.jsonText(p["lineKind"], "multiple"))
        d.seed("lineValue", pts(p["lineValue"], 1))
        d.fields["linePreset"] = DialogMath.linePresetLabel(d.field("lineKind"), d.field("lineValue"))
    }

    func seedTabs(_ d: inout Dialog) {
        guard d.fields["stops"] == nil else { return }
        let r = d.params["tabs"] != nil ? d.params : (query("format.ruler") ?? .null)
        let stops = (r["tabs"]?.asArray ?? []).compactMap { t -> String? in
            guard let pos = t["pos"]?.asF64 else { return nil }
            return "\(pos / 72):\(t["align"]?.asStr ?? "l")"
        }
        d.fields["stops"] = stops.joined(separator: "|")
        d.fields["default"] = "\((r["defaultTab"]?.asF64 ?? 72) / 72)"
        d.seed("newpos", "")
        d.seed("newalign", "l")
    }

    /// The Tabs dialog's stops as (inches, alignment).
    func tabStops(_ d: Dialog) -> [(Double, String)] {
        d.field("stops").split(separator: "|").compactMap { x in
            let parts = x.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let p = DialogMath.finite(parts[0]) else { return nil }
            return (p, String(parts[1]))
        }
    }

    func seedFont(_ d: inout Dialog) {
        let p = d.params
        d.seed("family", DialogMath.jsonText(p["family"], ""))
        d.seed("size", DialogMath.jsonText(p["size"], "18"))
        d.seed("bold", DialogMath.jsonText(p["bold"], "0"))
        d.seed("italic", DialogMath.jsonText(p["italic"], "0"))
        d.seed("underline", DialogMath.jsonText(p["underline"], "none"))
        d.seed("strike", DialogMath.jsonText(p["strike"], "none"))
        d.seed("baseline", DialogMath.jsonText(p["baseline"], "none"))
        d.seed("caps", DialogMath.jsonText(p["caps"], "none"))
        d.seed("spacing", DialogMath.jsonText(p["spacing"], "0"))
        let shown = p["color"].map(DialogMath.colorLabel) ?? ""
        d.seed("color", shown)
        d.seed("colorSeed", shown)
    }

    func seedPhotoAlbum(_ d: inout Dialog) {
        if d.fields["seeded"] != nil { return }
        d.fields["seeded"] = "1"
        let p = d.params
        if let items = p["items"]?.asArray {
            d.fields["items"] = JSONWriter().string(.array(items))
            d.fields["editing"] = "1"
        }
        for key in ["layout", "frame", "theme"] {
            if let v = p[key]?.asStr, !v.isEmpty { d.fields[key] = v }
        }
        for key in ["captions", "grayscale"] {
            if let v = p[key]?.asBool { d.fields[key] = v ? "1" : "0" }
        }
        if let id = p["album"].flatMap({ $0.asU64 ?? $0.asStr.flatMap { UInt64(String(rustTrim($0))) } }), id != 0 { d.fields["album"] = String(id) }
        let themeWas = d.fields["theme"].flatMap { $0.isEmpty ? nil : $0 } ?? currentTheme()
        d.seed("theme", themeWas)
        d.seed("themeWas", themeWas)
        d.seed("items", "[]")
        d.seed("sel", "0")
        d.seed("boxText", "Text Box")
        d.seed("layout", "1")
        d.seed("frame", "rect")
        d.seed("captions", "0")
        d.seed("grayscale", "0")
    }

    /// `current_theme`.
    func currentTheme() -> String {
        doc?.doc.masters.first.map(\.theme.name).flatMap { $0.isEmpty ? nil : $0 } ?? "DeckCraft"
    }

    func seedAction(_ d: inout Dialog) {
        let tab = d.get("tab", "click")
        let (kind, arg, highlight) = currentAction(tab)
        d.seed("kind", kind)
        d.seed("arg", arg)
        d.seed("highlight", highlight ? "1" : "0")
    }

    /// The selected shape's action for `tab` as (kind, argument, highlight).
    func currentAction(_ tab: String) -> (String, String, Bool) {
        guard let st = doc else { return ("none", "", true) }
        let sh = st.selectedShapes.first
        guard let h = tab == "hover" ? sh?.hover : sh?.click else { return ("none", "", true) }
        let ids = st.doc.slides.map(\.id)
        let kind: (String, String)
        switch h.action {
        case .nextSlide: kind = ("next", "")
        case .previousSlide: kind = ("previous", "")
        case .firstSlide: kind = ("first", "")
        case .lastSlide: kind = ("last", "")
        case .lastViewed: kind = ("lastViewed", "")
        case .endShow: kind = ("endShow", "")
        case .playMedia: kind = ("playMedia", "")
        case .url(let url): kind = ("url", url)
        case .customShow(let name, _): kind = ("customShow", name)
        case .program(let path): kind = ("program", path)
        case .slide(let slide): kind = ("slide", String(ids.firstIndex(of: slide) ?? 0))
        }
        return (kind.0, kind.1, h.highlightClick)
    }

    func fixDateFormat(_ d: inout Dialog) {
        let rows = DialogLists.dateRows(d.value("language"))
        if !rows.contains(where: { $0.0 == d.value("format") }), let first = rows.first { d.fields["format"] = first.0 }
    }

    func usedFonts() -> [String] {
        (query("font.used")?.asArray ?? []).compactMap(\.asStr)
    }

    func fontFamilies() -> [String] { DialogFonts.families(model.session, installed: fontFamiliesProvider()) }

    func reuseList(_ d: Dialog) -> [(Int, String)] {
        (d.params["slides"]?.asArray ?? []).compactMap { x in
            guard let i = x["index"]?.asUsize else { return nil }
            return (i, x["title"]?.asStr ?? "")
        }
    }

    func autocorrectFlags(_ p: Prefs) -> [(String, Bool)] {
        [
            ("acTwoInitials", p.acTwoInitials), ("acSentenceCaps", p.acSentenceCaps), ("acDays", p.acDays), ("acCapsLock", p.acCapsLock),
            ("acFractions", p.acFractions), ("acOrdinals", p.acOrdinals), ("acLists", p.acLists), ("replaceText", p.autocorrect),
        ]
    }

    // MARK: Forms

    /// The rows dialog `d` shows.
    func rows(_ d: Dialog) -> [FormRow] {
        let st = doc
        switch d.id {
        case "table":
            return [.text(label: "Number of columns:", key: "cols"), .text(label: "Number of rows:", key: "rows")]
        case "slideSize":
            let abbr = unitAbbr(model.session.prefs.units)
            return [
                .choice(label: "Slides sized for:", key: "preset", options: [FormOption("", "Custom")] + slideSizes.map { FormOption($0.label, $0.label) }),
                .text(label: "Width (\(abbr)):", key: "w"), .text(label: "Height (\(abbr)):", key: "h"),
                .radio(label: "Orientation:", key: "orientation", options: [FormOption("portrait", "Portrait"), FormOption("landscape", "Landscape")]),
                .check(label: "Maximize content (else ensure fit)", key: "max"),
            ]
        case "sizePosition":
            return [
                .heading("Size"), .text(label: "Height (in):", key: "h"), .text(label: "Width (in):", key: "w"),
                .text(label: "Rotation (°):", key: "rot"), .text(label: "Scale height (%):", key: "scaleH"),
                .text(label: "Scale width (%):", key: "scaleW"), .check(label: "Lock aspect ratio", key: "lock"),
                .heading("Position"), .note("From the top-left corner of the slide"),
                .text(label: "Horizontal (in):", key: "x"), .text(label: "Vertical (in):", key: "y"),
            ]
        case "headerFooter":
            let automatic = d.value("dateText").isEmpty
            let format = FormRow.choice(label: "Format:", key: "dateFormat", options: DialogLists.dateRows("en-US").map { FormOption($0.0, $0.1) })
            return [
                .check(label: "Date and time", key: "date"),
                .text(label: "Fixed date (empty = update automatically):", key: "dateText"),
                d.flag("date") && automatic ? format : .disabled([format]),
                .check(label: "Slide number", key: "num"), .check(label: "Footer", key: "footer"),
                .text(label: "Footer text:", key: "footerText"), .check(label: "Don't show on title slide", key: "hide"),
            ]
        case "hyperlink":
            var r: [FormRow] = [.tabs(key: "mode", options: [FormOption("url", "Web Page or File"), FormOption("slide", "This Document"), FormOption("email", "Email Address")])]
            switch d.value("mode") {
            case "slide": r.append(.list(label: "Slide:", key: "slide", options: slideTitles.enumerated().map { FormOption(String($0.offset), $0.element) }, findable: false))
            case "email": r.append(.text(label: "Email address:", key: "email"))
            default: r.append(.text(label: "Address:", key: "url"))
            }
            r.append(.text(label: "ScreenTip:", key: "tip"))
            return r
        case "setupShow":
            let names = st?.doc.customShows.map(\.name) ?? []
            return [
                .radio(label: "Show type", key: "type", options: [
                    FormOption("speaker", "Presented by a speaker (full screen)"), FormOption("browsed", "Browsed by an individual (window)"),
                    FormOption("kiosk", "Browsed at a kiosk (full screen)"),
                ]),
                .check(label: "Loop continuously until 'Esc'", key: "loop"), .check(label: "Show without narration", key: "nn"),
                .check(label: "Show without animation", key: "na"), .check(label: "Use timings, if present", key: "ut"),
                .choice(label: "Slides", key: "custom", options: [FormOption("", "All slides")] + names.map { FormOption($0, $0) }),
            ]
        case "zoom":
            return [
                .radio(label: "Zoom to", key: "zoomPick", options: [FormOption("fit", "Fit")] + DialogLists.zoomPresets.map { FormOption(String($0), "\($0)%") }),
                .text(label: "Percent:", key: "percent"),
            ]
        case "comment":
            return [.multiline(label: "Comment", key: "text", lines: 4)]
        case "altText":
            return [
                .note("How would you describe this object and its context to someone who is blind or has low vision?"),
                .multiline(label: "Alt text", key: "text", lines: 4), .check(label: "Mark as decorative", key: "deco"),
            ]
        case "outline":
            return [
                .note("Paste or type an outline. Unindented lines become slide titles; tab-indented lines become bullets."),
                .multiline(label: "Outline", key: "text", lines: 10),
            ]
        case "renameSection", "renameShape", "renameLayout":
            return [.text(label: "Name:", key: "name")]
        case "reuseSlides":
            let path = d.params["path"]?.asStr ?? ""
            let name = (path as NSString).lastPathComponent
            var r: [FormRow] = [
                .note("Insert slides from \(name.isEmpty ? path : name) after the current slide:"),
                .actions([FormAction("selectAll", "Select All"), FormAction("selectNone", "Select None")]),
            ]
            for (i, title) in reuseList(d) {
                let t = String(rustTrim(title))
                r.append(.check(label: t.isEmpty ? "\(i + 1)  (no title)" : "\(i + 1)  \(t)", key: "slide\(i)"))
            }
            r.append(.check(label: "Keep source formatting", key: "keep"))
            return r
        case "paragraph":
            return [
                .choice(label: "Alignment", key: "align", options: [
                    FormOption("left", "Left"), FormOption("center", "Center"), FormOption("right", "Right"), FormOption("justify", "Justify"),
                    FormOption("justLow", "Justify low"), FormOption("distributed", "Distributed"),
                ]),
                .heading("Indentation"),
                .row([.text(label: "Before text (in)", key: "before"), .text(label: "After text (in)", key: "after")]),
                .row([
                    .choice(label: "Special", key: "special", options: [FormOption("none", "None"), FormOption("first", "First line"), FormOption("hanging", "Hanging")]),
                    .text(label: "By (in)", key: "by"),
                ]),
                .heading("Spacing"),
                .row([.text(label: "Before (pt)", key: "spaceBefore"), .text(label: "After (pt)", key: "spaceAfter")]),
                .row([
                    .choice(label: "Line spacing", key: "linePreset", options: ["Single", "1.5 lines", "Double", "Multiple", "Exactly"].map { FormOption($0, $0) }),
                    .text(label: "At", key: "lineValue"),
                ]),
                .actions([FormAction("tabs", "Tabs…")]),
            ]
        case "tabs":
            let kinds = [FormOption("l", "Left"), FormOption("ctr", "Center"), FormOption("r", "Right"), FormOption("dec", "Decimal")]
            var r: [FormRow] = [.text(label: "Default tab stops (in):", key: "default"), .heading("Tab stops")]
            let stops = tabStops(d)
            if stops.isEmpty { r.append(.note("(none)")) }
            for (i, (pos, align)) in stops.enumerated() {
                let label = kinds.first { $0.value == align }?.label ?? "Left"
                r.append(.item("\(rustFixed(pos, places: 2))\"  \(label)", actions: [FormAction("clear:\(i)", "Clear")]))
            }
            r += [
                .text(label: "Tab stop position (in):", key: "newpos"), .radio(label: "Alignment:", key: "newalign", options: kinds),
                .actions([FormAction("set", "Set"), FormAction("clearAll", "Clear All")]),
            ]
            return r
        case "font":
            var fams = fontFamilies()
            let family = d.value("family")
            if !family.isEmpty && !fams.contains(family) { fams.insert(family, at: 0) }
            var sample = FormSample(text: "AaBbCcDd", family: family, size: (DialogMath.finitePt(d.value("size")) ?? 18).clamped(12, 28))
            sample.bold = d.flag("bold")
            sample.italic = d.flag("italic")
            sample.underline = d.value("underline") != "none"
            sample.strike = d.value("strike") != "none"
            return [
                .list(label: "Font", key: "family", options: fams.map { FormOption($0, $0) }, findable: true),
                .row([.text(label: "Size", key: "size"), .check(label: "Bold", key: "bold"), .check(label: "Italic", key: "italic")]),
                .row([
                    .choice(label: "Underline", key: "underline", options: [
                        FormOption("none", "None"), FormOption("sng", "Single"), FormOption("dbl", "Double"), FormOption("heavy", "Heavy"),
                        FormOption("dotted", "Dotted"), FormOption("dash", "Dash"), FormOption("wavy", "Wavy"),
                    ]),
                    .color(label: "Color", key: "color"),
                ]),
                .choice(label: "Strikethrough", key: "strike", options: [FormOption("none", "None"), FormOption("sng", "Single"), FormOption("dbl", "Double")]),
                .row([
                    .choice(label: "Baseline", key: "baseline", options: [FormOption("none", "None"), FormOption("super", "Superscript"), FormOption("sub", "Subscript")]),
                    .choice(label: "Caps", key: "caps", options: [FormOption("none", "None"), FormOption("small", "Small caps"), FormOption("all", "All caps")]),
                ]),
                .row([
                    .text(label: "Spacing (pt)", key: "spacing"),
                    .choice(label: "", key: "spacing", options: [
                        FormOption("-3", "Very tight"), FormOption("-1.5", "Tight"), FormOption("0", "Normal"), FormOption("3", "Loose"),
                        FormOption("6", "Very loose"),
                    ]),
                ]),
                .sample(sample),
            ]
        case "about":
            return [
                .heading("DeckCraft"), .note(DialogBackstage.versionLine()),
                .note("Presentations and slide shows, ported to native macOS from DeckCraft."),
                .note("An open-source, clean-room project. Not affiliated with Microsoft."),
                .actions([
                    FormAction("link:\(Links.discord)", "Join our community on Discord"), FormAction("link:\(Links.appPage)", "DeckCraft on the web"),
                    FormAction("link:\(Links.github)", "Source on GitHub"),
                ]),
                .note("MIT OR Apache-2.0 · © 2026 ArtCraft Team and the DeckCraft contributors"),
            ]
        case "preferences":
            return [
                .heading("General"),
                .choice(label: "Appearance:", key: "appearance", options: [FormOption("system", "System"), FormOption("light", "Light"), FormOption("dark", "Dark")]),
                .radio(label: "Measurement units:", key: "units", options: [FormOption("inches", "Inches"), FormOption("centimeters", "Centimeters")]),
                .heading("Editing"),
                .check(label: "Show smart guides", key: "smartGuides"), .check(label: "Snap objects to grid", key: "snapToGrid"),
                .check(label: "Replace straight quotes with smart quotes", key: "smartQuotes"),
                .row([.check(label: "AutoCorrect as you type", key: "autocorrect"), .actions([FormAction("autocorrectOptions", "AutoCorrect Options…")])]),
                .text(label: "Your name (comments):", key: "author"),
            ]
        case "autocorrect":
            var r: [FormRow] = [
                .check(label: "Correct TWo INitial CApitals", key: "acTwoInitials"),
                .check(label: "Capitalize first letter of sentences", key: "acSentenceCaps"),
                .check(label: "Capitalize names of days", key: "acDays"),
                .check(label: "Correct accidental use of cAPS LOCK key", key: "acCapsLock"),
                .check(label: "Replace fractions (1/2) with fraction characters (½)", key: "acFractions"),
                .check(label: "Ordinals (1st) with superscript", key: "acOrdinals"),
                .check(label: "Automatic bulleted and numbered lists", key: "acLists"),
                .check(label: "Replace text as you type", key: "replaceText"),
                .row([.text(label: "Replace", key: "from"), .text(label: "With", key: "to"), .actions([FormAction("add", "Add", enabled: !rustTrim(d.value("from")).isEmpty)])]),
            ]
            let q = String(rustTrim(d.value("from"))).lowercased()
            for (k, v) in autocorrectEntries().filter({ q.isEmpty || $0.0.lowercased().hasPrefix(q) }).prefix(200) {
                r.append(.item("\(k)  →  \(v)", actions: [FormAction("remove:\(k)", "Delete")]))
            }
            return r
        case "gridOptions":
            var r: [FormRow] = [
                .heading("Snap"), .check(label: "Snap objects to grid", key: "snap"), .check(label: "Snap objects to other objects", key: "smart"),
                .text(label: "Spacing (pt):", key: "spacing"), .heading("Display"),
                .check(label: "Display grid on screen", key: "gridlines"), .check(label: "Display drawing guides on screen", key: "guides"),
            ]
            if !d.value("error").isEmpty { r.append(.error(d.value("error"))) }
            return r
        case "columns":
            var r: [FormRow] = [.text(label: "Number:", key: "count"), .text(label: "Spacing (in):", key: "spacing")]
            if !d.value("error").isEmpty { r.append(.error(d.value("error"))) }
            return r
        case "export":
            return exportRows(d)
        case "symbol":
            var r: [FormRow] = [.note("Click a symbol to insert it at the insertion point.")]
            for (g, chars) in DialogLists.symbols {
                r.append(.heading(g))
                r.append(.actions(chars.map { FormAction("symbol:\($0)", String($0)) }))
            }
            return r
        case "photoAlbum":
            return photoAlbumRows(d)
        case "replaceFonts":
            let used = usedFonts()
            let needle = String(rustTrim(d.value("to"))).lowercased()
            var r: [FormRow] = [
                .choice(label: "Replace:", key: "from", options: used.map { FormOption($0, $0) }),
                .text(label: "With:", key: "to", placeholder: "Font name"),
                .list(label: "Fonts", key: "to", options: fontFamilies().filter { needle.isEmpty || $0.lowercased().contains(needle) }.prefix(200).map { FormOption($0, $0) }, findable: false),
            ]
            if let msg = d.fields["result"] { r.append(.note(msg)) }
            return r
        case "equation":
            return [.note("Type an equation in linear form (e.g. a^2+b^2=c^2, x=(-b±√(b^2-4ac))/2a)."), .text(label: "Equation", key: "eq")]
        case "dateTime":
            return [
                .list(label: "Available formats:", key: "format", options: DialogLists.dateRows(d.value("language")).map { FormOption($0.0, $0.1) }, findable: false),
                .choice(label: "Language:", key: "language", options: DialogLists.dateLanguages.map { FormOption($0.0, $0.1) }),
                .note("Month names and AM/PM are listed for English. Other languages list the numeric date and 24-hour time."),
                .check(label: "Update automatically", key: "update"),
            ]
        case "spelling":
            return spellingRows(d)
        case "pasteSpecial":
            let hasShapes = !model.session.clipboard.shapes.isEmpty
            return [.radio(label: "As:", key: "as", options: [
                FormOption("destinationTheme", "Use Destination Theme"), FormOption("keepSource", "Keep Source Formatting", enabled: hasShapes),
                FormOption("picture", "Picture (PNG)", enabled: hasShapes), FormOption("text", "Keep Text Only"),
            ])]
        case "find":
            let replace = d.flag("replace")
            let has = !d.value("text").isEmpty
            var r: [FormRow] = [.text(label: "Find what:", key: "text")]
            if replace { r.append(.text(label: "Replace with:", key: "with")) }
            r += [.check(label: "Match case", key: "matchCase"), .check(label: "Find whole words only", key: "wholeWords")]
            r.append(.actions(replace ? [FormAction("replaceOne", "Replace", enabled: has), FormAction("replaceAll", "Replace All", enabled: has)] : [FormAction("showReplace", "Replace…")]))
            if !d.value("status").isEmpty { r.append(.note(d.value("status"))) }
            return r
        case "accessibility":
            let list = query("review.accessibility")?.asArray ?? []
            if list.isEmpty { return [.note("No accessibility issues found. People with disabilities should not have difficulty reading this document.")] }
            return list.enumerated().map { i, item in
                let name = item["name"]?.asStr.map { " — \($0)" } ?? ""
                return .item("Slide \((item["slide"]?.asU64 ?? 0) + 1): \(item["issue"]?.asStr ?? "")\(name)", actions: [FormAction("goto:\(i)", "Go to")])
            }
        case "language":
            let hasSel = Cmd.hasTextOrShapes(model.session) == nil
            let all = !hasSel || d.value("scope") == "all"
            let cur = d.field("current")
            var langs = DialogLists.languages.map { ($0.1, $0.0) }
            if !langs.contains(where: { $0.0.caseInsensitiveCompare(cur) == .orderedSame }) { langs.insert((cur, cur), at: 0) }
            return [
                .radio(label: "Apply to:", key: "scope", options: [FormOption("sel", "Selected text", enabled: hasSel), FormOption("all", "Whole presentation")]),
                .note(all ? "Mark all text in the presentation as:" : "Mark selected text as:"),
                .list(label: "Language", key: "lang", options: langs.map { tag, name in
                    FormOption(tag, Spell.dictionary(tag) != nil ? "\(name)  (dictionary)" : name)
                }, findable: true),
                .note("Spelling is checked for languages marked (dictionary)."),
                .check(label: "Do not check spelling or grammar", key: "noProof"),
            ]
        case "customShow":
            let shows = st?.doc.customShows ?? []
            var r: [FormRow] = shows.enumerated().map { i, s in
                .item("\(s.name) (\(s.slides.count) slides)", actions: [FormAction("show:\(i)", "Show"), FormAction("delete:\(i)", "Delete")])
            }
            r += [.text(label: "New show name:", key: "name"), .text(label: "Slides (e.g. 1,3,5):", key: "slides")]
            return r
        case "chartData":
            guard chartOf(model.session) != nil else { return [.note("Select a chart first.")] }
            return [
                .note("Edit the data: first row = series names, first column = categories."), .grid(cells: chartGrid(d)),
                .actions([FormAction("addRow", "+ Row"), FormAction("addSeries", "+ Series")]),
            ]
        case "trim":
            return [
                .text(label: "Start time (s):", key: "start"), .text(label: "End trim (s):", key: "end"),
                .text(label: "Fade in (s):", key: "fin"), .text(label: "Fade out (s):", key: "fout"),
            ]
        case "smartart":
            return [
                .note("Pick a graphic; type one item per line."),
                .tabs(key: "kind", options: [
                    FormOption("list", "Basic List"), FormOption("process", "Basic Process"), FormOption("cycle", "Basic Cycle"),
                    FormOption("hierarchy", "Hierarchy"), FormOption("pyramid", "Pyramid"), FormOption("matrix", "Matrix"),
                ]),
                .multiline(label: "SmartArt items", key: "text", lines: 5),
            ]
        case "bullets":
            let numbered = d.value("tab") == "numbered"
            let styles: [FormOption] = numbered
                ? [("arabicPeriod", "1. 2. 3."), ("arabicParenR", "1) 2) 3)"), ("romanUcPeriod", "I. II. III."), ("romanLcPeriod", "i. ii. iii."),
                   ("alphaUcPeriod", "A. B. C."), ("alphaLcParenR", "a) b) c)"), ("alphaLcPeriod", "a. b. c.")].map { FormOption($0.0, $0.1) }
                : ["•", "○", "■", "□", "◆", "➢", "✓", "–", "★"].map { FormOption($0, $0) }
            return [
                .tabs(key: "tab", options: [FormOption("bulleted", "Bulleted"), FormOption("numbered", "Numbered")]),
                .radio(label: "Style", key: numbered ? "scheme" : "char", options: styles),
                numbered ? .text(label: "Start at:", key: "start") : .text(label: "Custom character:", key: "custom"),
                .text(label: "Size (% of text):", key: "size"),
                .choice(label: "Color:", key: "color", options: [
                    FormOption("", "Automatic"), FormOption("tx1", "Text"), FormOption("accent1", "Accent 1"), FormOption("accent2", "Accent 2"),
                    FormOption("accent3", "Accent 3"), FormOption("accent4", "Accent 4"), FormOption("accent5", "Accent 5"), FormOption("accent6", "Accent 6"),
                ]),
                .actions([FormAction("none", "None")]),
            ]
        case "action":
            return actionRows(d)
        case "themeColors":
            let left: [SchemeSlot] = [.dk1, .lt1, .dk2, .lt2, .hlink, .folHlink]
            let right: [SchemeSlot] = [.accent1, .accent2, .accent3, .accent4, .accent5, .accent6]
            var r: [FormRow] = zip(left, right).map { a, b in .row([.color(label: a.label, key: a.xmlName), .color(label: b.label, key: b.xmlName)]) }
            r += [.text(label: "Name:", key: "schemeName"), .note("Applies to this presentation's theme colours.")]
            return r
        case "themeFonts":
            let choices = themeFontChoices
            return [
                .row([
                    .list(label: "Heading:", key: "major", options: choices(d.value("major")).map { FormOption($0, $0) }, findable: true),
                    .list(label: "Body:", key: "minor", options: choices(d.value("minor")).map { FormOption($0, $0) }, findable: true),
                ]),
                .sample(FormSample(text: "Heading sample  \(d.value("major"))", family: d.value("major"), size: 20)),
                .sample(FormSample(text: "Body sample  \(d.value("minor"))", family: d.value("minor"), size: 14)),
                .text(label: "Name:", key: "schemeName"), .note("Heading and body fonts for this presentation."),
            ]
        case "info":
            return infoRows(d)
        case "new":
            return newRows(d)
        default:
            return [.note("“\(d.id)” is not available yet.")]
        }
    }

    func unitAbbr(_ u: DCGeometry.Unit) -> String {
        switch u {
        case .inches: "in"
        case .centimeters: "cm"
        case .points: "pt"
        case .pixels: "px"
        }
    }

    /// `theme_font_choices`.
    func themeFontChoices(_ selected: String) -> [String] {
        var v = fontFamilies()
        for scheme in builtinFontSchemes() { v += [scheme.major.latin, scheme.minor.latin] }
        if !selected.isEmpty { v.append(selected) }
        var seen = Set<String>()
        return v.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func autocorrectEntries() -> [(String, String)] {
        (query("text.autocorrect")?["entries"]?.asArray ?? []).compactMap { e in
            guard let k = e.at(0)?.asStr, let v = e.at(1)?.asStr else { return nil }
            return (k, v)
        }
    }

    func chartGrid(_ d: Dialog) -> [[String]] {
        (d.params["grid"]?.asArray ?? []).map { ($0.asArray ?? []).map { $0.asStr ?? "" } }
    }

    func exportRows(_ d: Dialog) -> [FormRow] {
        var r: [FormRow] = [.radio(label: "Export the presentation as:", key: "fmt", options: DialogBackstage.exportFormats.map { FormOption($0.0, $0.1) })]
        switch d.value("fmt") {
        case "pdf":
            r.append(.choice(label: "Print layout:", key: "pdfLayout", options: DialogBackstage.pdfLayouts.map { FormOption($0.0, $0.1) }))
            r.append(.check(label: "Include hidden slides", key: "pdfHidden"))
        case "png", "pngAll":
            r.append(.check(label: "Transparent background", key: "pngTransparent"))
        case "gif":
            r.append(.choice(label: "Size:", key: "gifSize", options: [
                FormOption("small", "Small (640 px wide)"), FormOption("medium", "Medium (960 px wide)"), FormOption("large", "Large (1280 px wide)"),
                FormOption("extraLarge", "Extra Large (1920 px wide)"), FormOption("custom", "Custom width"),
            ]))
            if d.value("gifSize") == "custom" { r.append(.text(label: "Width (pixels):", key: "gifWidth")) }
            r += [
                .text(label: "Seconds per slide:", key: "gifSeconds"), .text(label: "From slide:", key: "gifFrom"), .text(label: "To slide:", key: "gifTo"),
                .check(label: "Loop forever", key: "gifLoop"), .check(label: "Include hidden slides", key: "gifHidden"),
            ]
            var copy = d
            if case .failure(let e) = DialogParams.gif(&copy, slides: doc?.doc.slides.count ?? 0) { r.append(.error(e.message)) }
        default: break
        }
        return r
    }

    func photoAlbumRows(_ d: Dialog) -> [FormRow] {
        let items = DialogAlbum.items(d) ?? []
        let sel = Int(d.value("sel")) ?? 0
        var r: [FormRow] = [.heading("Pictures in album")]
        if items.isEmpty {
            r.append(.note("No pictures yet"))
        } else {
            r.append(.list(label: "Pictures in album", key: "sel", options: items.enumerated().map { FormOption(String($0.offset), DialogAlbum.label($0.element)) }, findable: false))
        }
        r.append(.actions([FormAction("addPictures", "Add Pictures…"), FormAction("newTextBox", "New Text Box"), FormAction("remove", "Remove")]))
        r.append(.text(label: "Text box:", key: "boxText"))
        r.append(.note(DialogAlbum.status(items, sel)))
        let picture = DialogAlbum.isPicture(items.at(sel))
        let pictureActions = FormRow.actions([
            FormAction("rotateLeft", "Rotate Left"), FormAction("rotateRight", "Rotate Right"), FormAction("moreBrightness", "More Brightness"),
            FormAction("lessBrightness", "Less Brightness"), FormAction("moreContrast", "More Contrast"), FormAction("lessContrast", "Less Contrast"),
        ])
        r.append(picture ? pictureActions : .disabled([pictureActions]))
        r += [
            .choice(label: "Picture layout", key: "layout", options: [
                FormOption("fit", "Fit to slide"), FormOption("1", "1 picture"), FormOption("2", "2 pictures"), FormOption("4", "4 pictures"),
                FormOption("1title", "1 picture with title"), FormOption("2title", "2 pictures with title"), FormOption("4title", "4 pictures with title"),
            ]),
            .choice(label: "Frame shape", key: "frame", options: [FormOption("none", "None"), FormOption("rect", "Rectangle"), FormOption("rounded", "Rounded"), FormOption("simple", "Simple, white")]),
            .check(label: "Captions under pictures", key: "captions"), .check(label: "ALL pictures black and white", key: "grayscale"),
            .choice(label: "Album theme", key: "theme", options: DialogLists.albumThemes.map { FormOption($0, $0) }),
        ]
        return r
    }

    /// The Spelling dialog's results for the words ignored so far.
    func spellingList(_ d: Dialog) -> [JSON] {
        let ignore = d.value("ignore").split(separator: "\n").filter { !$0.isEmpty }.map { JSON.string(String($0)) }
        return query("review.spelling", ["ignore": .array(ignore)])?.asArray ?? []
    }

    func spellingRows(_ d: Dialog) -> [FormRow] {
        let list = spellingList(d)
        let info = query("review.dictionary") ?? .null
        let available = info["available"]?.asBool ?? false
        var r: [FormRow] = []
        if available, let f = info["found"]?.asStr {
            r.append(.note("Dictionary: \(f.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? f)"))
        } else if available {
            r.append(.note("Dictionary: \(info["lang"]?.asStr ?? "")"))
        } else {
            r.append(.note("The \(info["lang"]?.asStr ?? "en-US") dictionary isn't installed, so only common misspellings and the system spelling checker's suggestions are found."))
        }
        if list.isEmpty { r.append(.note("The spelling check is complete. No issues found.")) }
        for (i, item) in list.enumerated() {
            let w = item["word"]?.asStr ?? ""
            r.append(.item("Slide \((item["slide"]?.asU64 ?? 0) + 1): “\(w)”", actions: [
                FormAction("goto:\(i)", "Go to"), FormAction("ignoreAll:\(i)", "Ignore All"), FormAction("addWord:\(i)", "Add to Dictionary"),
            ]))
            if item["repeated"]?.asBool == true && item["notes"]?.asBool != true {
                r.append(.item("Repeated word", actions: [FormAction("deleteRepeated:\(i)", "Delete Repeated Word")]))
            }
            let sug = (item["suggestions"]?.asArray ?? []).compactMap(\.asStr)
            if !sug.isEmpty {
                var acts = sug.enumerated().map { FormAction("change:\(i):\($0.offset)", $0.element) }
                if item["notes"]?.asBool != true { acts.append(FormAction("changeAll:\(i):0", "Change All to “\(sug[0])”")) }
                r.append(.item("Change to:", actions: acts))
            }
        }
        return r
    }

    /// The Action Settings targets (`targets`).
    static let actionTargets: [FormOption] = [
        FormOption("next", "Next Slide"), FormOption("previous", "Previous Slide"), FormOption("first", "First Slide"), FormOption("last", "Last Slide"),
        FormOption("lastViewed", "Last Slide Viewed"), FormOption("endShow", "End Show"), FormOption("customShow", "Custom Show…"),
        FormOption("slide", "Slide…"), FormOption("url", "URL…"),
    ]

    func actionRows(_ d: Dialog) -> [FormRow] {
        let kind = d.value("kind")
        let hover = d.value("tab") == "hover"
        var r: [FormRow] = [
            .tabs(key: "tab", options: [FormOption("click", "Mouse Click"), FormOption("hover", "Mouse Over")]),
            .radio(label: hover ? "Action on mouse over" : "Action on click", key: "group", options: [
                FormOption("none", "None"), FormOption("hyperlink", "Hyperlink to:"), FormOption("program", "Run program:"),
                FormOption("playMedia", "Play the shape's media"),
            ]),
        ]
        switch actionGroup(kind) {
        case "hyperlink":
            r.append(.choice(label: "Hyperlink to:", key: "kind", options: Self.actionTargets))
            switch kind {
            case "url": r.append(.text(label: "Address:", key: "arg"))
            case "slide": r.append(.list(label: "Slide:", key: "arg", options: slideTitles.enumerated().map { FormOption(String($0.offset), $0.element) }, findable: false))
            case "customShow":
                let shows = doc?.doc.customShows.map(\.name) ?? []
                if shows.isEmpty { r.append(.note("This presentation has no custom shows (Slide Show ▸ Custom Shows).")) }
                r.append(.list(label: "Custom show:", key: "arg", options: shows.map { FormOption($0, $0) }, findable: false))
            default: break
            }
        case "program":
            r.append(.text(label: "Program:", key: "arg"))
        default: break
        }
        r.append(.check(label: "Highlight click", key: "highlight"))
        return r
    }

    /// The radio choice an action kind belongs to.
    func actionGroup(_ kind: String) -> String {
        ["none", "program", "playMedia"].contains(kind) ? kind : "hyperlink"
    }

    func infoRows(_ d: Dialog) -> [FormRow] {
        guard let v = query("file.info") else { return [.note("No presentation is open.")] }
        let path = v["path"]?.asStr
        let dirty = v["dirty"]?.asBool ?? false
        var r: [FormRow] = [.heading(v["title"]?.asStr ?? ""), .note(path ?? "Not saved yet")]
        if path != nil { r.append(.actions([FormAction("copyPath", "Copy Path"), FormAction("reveal", "Show in Finder")])) }
        let revert = !dirty ? "There are no unsaved changes." : path != nil ? "This presentation has unsaved changes. Revert goes back to the saved file." : "This presentation has never been saved."
        r += [
            .item("Inspect Presentation: before you share it, check it for things people with disabilities might find hard to read.", actions: [FormAction("checkIssues", "Check for Issues")]),
            .item("Manage Presentation: \(revert)", actions: [FormAction("revert", "Revert", enabled: dirty && path != nil)]),
            .heading("Properties"),
        ]
        var facts: [String] = []
        if let b = v["bytes"]?.asU64 { facts.append("Size: \(DialogBackstage.formatBytes(b))") }
        facts.append("Slides: \(v["slides"]?.asU64 ?? 0)")
        facts.append("Hidden slides: \(v["hiddenSlides"]?.asU64 ?? 0)")
        r.append(.note(facts.joined(separator: " · ")))
        for (key, label, hint) in DialogBackstage.properties { r.append(.text(label: label, key: key, placeholder: hint)) }
        return r
    }

    func newRows(_ d: Dialog) -> [FormRow] {
        let q = String(rustTrim(d.value("query"))).lowercased()
        let themes = builtinThemes().filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let sample = q.isEmpty || "sample deck northern lights".contains(q)
        var r: [FormRow] = [.text(label: "Search", key: "query", placeholder: "Search for themes and templates")]
        func swatches(_ name: String) -> [String] {
            guard let th = builtinThemes().first(where: { $0.name == name }) else { return [] }
            return [SchemeSlot.lt1, .dk1, .accent1, .accent2, .accent3, .accent4].map { th.colors.get($0).hex }
        }
        var tiles = themes.map { FormTile("new:theme:\($0.name)", $0.name, colors: swatches($0.name)) }
        if sample { tiles.append(FormTile("new:sample", "Sample deck: Northern Lights", colors: swatches("DeckCraft"))) }
        if !tiles.isEmpty { r += [.heading("Themes"), .tiles(tiles)] }
        let starters = Templates.matching(q)
        if !starters.isEmpty {
            r += [.heading("Templates"), .tiles(starters.map { FormTile("new:template:\($0.name)", $0.name, detail: $0.summary, colors: swatches($0.theme)) })]
        }
        if tiles.isEmpty && starters.isEmpty { r.append(.note("No themes or templates match “\(q)”.")) }
        return r
    }
}

/// The Photo Album's picture list (`album_items` and friends).
enum DialogAlbum {
    static func items(_ d: Dialog) -> [JSON]? {
        (try? JSONParser.parse(d.value("items").isEmpty ? "[]" : d.value("items")))?.asArray
    }

    static func store(_ d: inout Dialog, _ items: [JSON]) { d.fields["items"] = JSONWriter().string(.array(items)) }

    /// `album_item_label`.
    static func label(_ v: JSON) -> String {
        if let text = v["text"]?.asStr {
            let t = String(rustTrim(text))
            return t.isEmpty ? "Text Box" : "Text: \(t)"
        }
        return v["name"]?.asStr.flatMap { $0.isEmpty ? nil : $0 } ?? "Picture"
    }

    static func isPicture(_ v: JSON?) -> Bool { v?["data"] != nil || v?["path"] != nil }

    /// `album_picture_status`.
    static func status(_ items: [JSON], _ sel: Int) -> String {
        guard let item = items.at(sel) else { return "Select a picture to rotate it or change brightness and contrast" }
        if !isPicture(item) { return "Text boxes have no picture options" }
        let rot = item["rot"]?.asF64 ?? 0, b = item["brightness"]?.asF64 ?? 0, c = item["contrast"]?.asF64 ?? 0
        return "Rotation \(rustFixed(rot, places: 0))°, brightness \(rustFixed(b, places: 1)), contrast \(rustFixed(c, places: 1))"
    }

    /// `with_selected_picture`.
    static func withSelected(_ d: inout Dialog, _ f: (inout JSONObject) -> Void) {
        guard var list = items(d) else { return }
        let i = Int(d.value("sel")) ?? 0
        guard let item = list.at(i), isPicture(item), var obj = item.asObject else { return }
        f(&obj)
        list[i] = .object(obj)
        store(&d, list)
    }

    /// `nudge_picture`.
    static func nudge(_ d: inout Dialog, _ key: String, _ delta: Double) {
        withSelected(&d) { obj in
            let cur = obj[key]?.asF64 ?? 0
            obj.set(key, .num((((cur + delta) * 10).rounded() / 10).clamped(-1, 1)))
        }
    }
}
