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
            return [.text(label: L10n.text("Number of columns:"), key: "cols"), .text(label: L10n.text("Number of rows:"), key: "rows")]
        case "slideSize":
            let abbr = unitAbbr(model.session.prefs.units)
            return [
                .choice(label: L10n.text("Slides sized for:"), key: "preset", options: [FormOption("", L10n.text("Custom"))] + slideSizes.map { FormOption($0.label, $0.label) }),
                .text(label: L10n.text("Width (\(abbr)):"), key: "w"), .text(label: L10n.text("Height (\(abbr)):"), key: "h"),
                .radio(label: L10n.text("Orientation:"), key: "orientation", options: [FormOption("portrait", L10n.text("Portrait")), FormOption("landscape", L10n.text("Landscape"))]),
                .check(label: L10n.text("Maximize content (else ensure fit)"), key: "max"),
            ]
        case "sizePosition":
            return [
                .heading(L10n.text("Size")), .text(label: L10n.text("Height (in):"), key: "h"), .text(label: L10n.text("Width (in):"), key: "w"),
                .text(label: L10n.text("Rotation (°):"), key: "rot"), .text(label: L10n.text("Scale height (%):"), key: "scaleH"),
                .text(label: L10n.text("Scale width (%):"), key: "scaleW"), .check(label: L10n.text("Lock aspect ratio"), key: "lock"),
                .heading(L10n.text("Position")), .note(L10n.text("From the top-left corner of the slide")),
                .text(label: L10n.text("Horizontal (in):"), key: "x"), .text(label: L10n.text("Vertical (in):"), key: "y"),
            ]
        case "headerFooter":
            let automatic = d.value("dateText").isEmpty
            let format = FormRow.choice(label: L10n.text("Format:"), key: "dateFormat", options: DialogLists.dateRows("en-US").map { FormOption($0.0, $0.1) })
            return [
                .check(label: L10n.text("Date and time"), key: "date"),
                .text(label: L10n.text("Fixed date (empty = update automatically):"), key: "dateText"),
                d.flag("date") && automatic ? format : .disabled([format]),
                .check(label: L10n.text("Slide number"), key: "num"), .check(label: L10n.text("Footer"), key: "footer"),
                .text(label: L10n.text("Footer text:"), key: "footerText"), .check(label: L10n.text("Don't show on title slide"), key: "hide"),
            ]
        case "hyperlink":
            var r: [FormRow] = [.tabs(key: "mode", options: [FormOption("url", L10n.text("Web Page or File")), FormOption("slide", L10n.text("This Document")), FormOption("email", L10n.text("Email Address"))])]
            switch d.value("mode") {
            case "slide": r.append(.list(label: L10n.text("Slide:"), key: "slide", options: slideTitles.enumerated().map { FormOption(String($0.offset), $0.element) }, findable: false))
            case "email": r.append(.text(label: L10n.text("Email address:"), key: "email"))
            default: r.append(.text(label: L10n.text("Address:"), key: "url"))
            }
            r.append(.text(label: L10n.text("ScreenTip:"), key: "tip"))
            return r
        case "setupShow":
            let names = st?.doc.customShows.map(\.name) ?? []
            return [
                .radio(label: L10n.text("Show type"), key: "type", options: [
                    FormOption("speaker", L10n.text("Presented by a speaker (full screen)")), FormOption("browsed", L10n.text("Browsed by an individual (window)")),
                    FormOption("kiosk", L10n.text("Browsed at a kiosk (full screen)")),
                ]),
                .check(label: L10n.text("Loop continuously until 'Esc'"), key: "loop"), .check(label: L10n.text("Show without narration"), key: "nn"),
                .check(label: L10n.text("Show without animation"), key: "na"), .check(label: L10n.text("Use timings, if present"), key: "ut"),
                .choice(label: L10n.text("Slides"), key: "custom", options: [FormOption("", L10n.text("All slides"))] + names.map { FormOption($0, $0) }),
            ]
        case "zoom":
            return [
                .radio(label: L10n.text("Zoom to"), key: "zoomPick", options: [FormOption("fit", L10n.text("Fit"))] + DialogLists.zoomPresets.map { FormOption(String($0), "\($0)%") }),
                .text(label: L10n.text("Percent:"), key: "percent"),
            ]
        case "comment":
            return [.multiline(label: L10n.text("Comment"), key: "text", lines: 4)]
        case "altText":
            return [
                .note(L10n.text("How would you describe this object and its context to someone who is blind or has low vision?")),
                .multiline(label: L10n.text("Alt text"), key: "text", lines: 4), .check(label: L10n.text("Mark as decorative"), key: "deco"),
            ]
        case "outline":
            return [
                .note(L10n.text("Paste or type an outline. Unindented lines become slide titles; tab-indented lines become bullets.")),
                .multiline(label: L10n.text("Outline"), key: "text", lines: 10),
            ]
        case "renameSection", "renameShape", "renameLayout":
            return [.text(label: L10n.text("Name:"), key: "name")]
        case "reuseSlides":
            let path = d.params["path"]?.asStr ?? ""
            let name = (path as NSString).lastPathComponent
            var r: [FormRow] = [
                .note(L10n.text("Insert slides from \(name.isEmpty ? path : name) after the current slide:")),
                .actions([FormAction("selectAll", L10n.text("Select All")), FormAction("selectNone", L10n.text("Select None"))]),
            ]
            for (i, title) in reuseList(d) {
                let t = String(rustTrim(title))
                r.append(.check(label: t.isEmpty ? L10n.text("\(i + 1)  (no title)") : "\(i + 1)  \(t)", key: "slide\(i)"))
            }
            r.append(.check(label: L10n.text("Keep source formatting"), key: "keep"))
            return r
        case "paragraph":
            return [
                .choice(label: L10n.text("Alignment"), key: "align", options: [
                    FormOption("left", L10n.text("Left")), FormOption("center", L10n.text("Center")), FormOption("right", L10n.text("Right")), FormOption("justify", L10n.text("Justify")),
                    FormOption("justLow", L10n.text("Justify low")), FormOption("distributed", L10n.text("Distributed")),
                ]),
                .heading(L10n.text("Indentation")),
                .row([.text(label: L10n.text("Before text (in)"), key: "before"), .text(label: L10n.text("After text (in)"), key: "after")]),
                .row([
                    .choice(label: L10n.text("Special"), key: "special", options: [FormOption("none", L10n.text("None")), FormOption("first", L10n.text("First line")), FormOption("hanging", L10n.text("Hanging"))]),
                    .text(label: L10n.text("By (in)"), key: "by"),
                ]),
                .heading(L10n.text("Spacing")),
                .row([.text(label: L10n.text("Before (pt)"), key: "spaceBefore"), .text(label: L10n.text("After (pt)"), key: "spaceAfter")]),
                .row([
                    .choice(label: L10n.text("Line spacing"), key: "linePreset", options: [
                        ("Single", L10n.text("Single")), ("1.5 lines", L10n.text("1.5 lines")), ("Double", L10n.text("Double")),
                        ("Multiple", L10n.text("Multiple")), ("Exactly", L10n.text("Exactly")),
                    ].map { FormOption($0.0, $0.1) }),
                    .text(label: L10n.text("At"), key: "lineValue"),
                ]),
                .actions([FormAction("tabs", L10n.text("Tabs…"))]),
            ]
        case "tabs":
            let kinds = [FormOption("l", L10n.text("Left")), FormOption("ctr", L10n.text("Center")), FormOption("r", L10n.text("Right")), FormOption("dec", L10n.text("Decimal"))]
            var r: [FormRow] = [.text(label: L10n.text("Default tab stops (in):"), key: "default"), .heading(L10n.text("Tab stops"))]
            let stops = tabStops(d)
            if stops.isEmpty { r.append(.note(L10n.text("(none)"))) }
            for (i, (pos, align)) in stops.enumerated() {
                let label = kinds.first { $0.value == align }?.label ?? L10n.text("Left")
                r.append(.item("\(rustFixed(pos, places: 2))\"  \(label)", actions: [FormAction("clear:\(i)", String(localized: "Clear", bundle: .module, comment: "Button: removes this tab stop"))]))
            }
            r += [
                .text(label: L10n.text("Tab stop position (in):"), key: "newpos"), .radio(label: L10n.text("Alignment:"), key: "newalign", options: kinds),
                .actions([FormAction("set", L10n.text("Set")), FormAction("clearAll", L10n.text("Clear All"))]),
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
                .list(label: L10n.text("Font"), key: "family", options: fams.map { FormOption($0, $0) }, findable: true),
                .row([.text(label: L10n.text("Size"), key: "size"), .check(label: L10n.text("Bold"), key: "bold"), .check(label: L10n.text("Italic"), key: "italic")]),
                .row([
                    .choice(label: L10n.text("Underline"), key: "underline", options: [
                        FormOption("none", L10n.text("None")), FormOption("sng", L10n.text("Single")), FormOption("dbl", L10n.text("Double")), FormOption("heavy", L10n.text("Heavy")),
                        FormOption("dotted", L10n.text("Dotted")), FormOption("dash", L10n.text("Dash")), FormOption("wavy", L10n.text("Wavy")),
                    ]),
                    .color(label: L10n.text("Color"), key: "color"),
                ]),
                .choice(label: L10n.text("Strikethrough"), key: "strike", options: [FormOption("none", L10n.text("None")), FormOption("sng", L10n.text("Single")), FormOption("dbl", L10n.text("Double"))]),
                .row([
                    .choice(label: L10n.text("Baseline"), key: "baseline", options: [FormOption("none", L10n.text("None")), FormOption("super", L10n.text("Superscript")), FormOption("sub", L10n.text("Subscript"))]),
                    .choice(label: L10n.text("Caps"), key: "caps", options: [FormOption("none", L10n.text("None")), FormOption("small", L10n.text("Small caps")), FormOption("all", L10n.text("All caps"))]),
                ]),
                .row([
                    .text(label: L10n.text("Spacing (pt)"), key: "spacing"),
                    .choice(label: "", key: "spacing", options: [
                        FormOption("-3", L10n.text("Very tight")), FormOption("-1.5", L10n.text("Tight")), FormOption("0", L10n.text("Normal")), FormOption("3", L10n.text("Loose")),
                        FormOption("6", L10n.text("Very loose")),
                    ]),
                ]),
                .sample(sample),
            ]
        case "about":
            return [
                // Wave 6 (Release): the fork's About — plain-text attribution, no ArtCraft marks or community links
                // (deckcraft docs/brand/LICENSE-brand.txt, "Forks and modified versions").
                .heading("DeckCraftNative"), .note(DialogBackstage.versionLine()),
                .note(L10n.text("DeckCraftNative, based on DeckCraft by the ArtCraft team.")),
                .note(L10n.text("Presentations and slide shows, ported to native macOS from DeckCraft.")),
                .note(L10n.text("An open-source, clean-room project. Not affiliated with Microsoft.")),
                .actions([
                    FormAction("link:\(Links.github)", L10n.text("DeckCraft's source on GitHub")),
                ]),
                .note(L10n.text("Licensed under MIT OR Apache-2.0. Includes code ported from DeckCraft, © 2026 ArtCraft Team and the DeckCraft contributors (MIT OR Apache-2.0).")),
            ]
        case "preferences":
            return [
                .heading(L10n.text("General")),
                .choice(label: L10n.text("Appearance:"), key: "appearance", options: [FormOption("system", L10n.text("System")), FormOption("light", L10n.text("Light")), FormOption("dark", L10n.text("Dark"))]),
                .radio(label: L10n.text("Measurement units:"), key: "units", options: [FormOption("inches", L10n.text("Inches")), FormOption("centimeters", L10n.text("Centimeters"))]),
                .heading(L10n.text("Editing")),
                .check(label: L10n.text("Show smart guides"), key: "smartGuides"), .check(label: L10n.text("Snap objects to grid"), key: "snapToGrid"),
                .check(label: L10n.text("Replace straight quotes with smart quotes"), key: "smartQuotes"),
                .row([.check(label: L10n.text("AutoCorrect as you type"), key: "autocorrect"), .actions([FormAction("autocorrectOptions", L10n.text("AutoCorrect Options…"))])]),
                .text(label: L10n.text("Your name (comments):"), key: "author"),
            ]
        case "autocorrect":
            var r: [FormRow] = [
                .check(label: L10n.text("Correct TWo INitial CApitals"), key: "acTwoInitials"),
                .check(label: L10n.text("Capitalize first letter of sentences"), key: "acSentenceCaps"),
                .check(label: L10n.text("Capitalize names of days"), key: "acDays"),
                .check(label: L10n.text("Correct accidental use of cAPS LOCK key"), key: "acCapsLock"),
                .check(label: L10n.text("Replace fractions (1/2) with fraction characters (½)"), key: "acFractions"),
                .check(label: L10n.text("Ordinals (1st) with superscript"), key: "acOrdinals"),
                .check(label: L10n.text("Automatic bulleted and numbered lists"), key: "acLists"),
                .check(label: L10n.text("Replace text as you type"), key: "replaceText"),
                .row([.text(label: L10n.text("Replace"), key: "from"), .text(label: L10n.text("With"), key: "to"), .actions([FormAction("add", L10n.text("Add"), enabled: !rustTrim(d.value("from")).isEmpty)])]),
            ]
            let q = String(rustTrim(d.value("from"))).lowercased()
            for (k, v) in autocorrectEntries().filter({ q.isEmpty || $0.0.lowercased().hasPrefix(q) }).prefix(200) {
                r.append(.item("\(k)  →  \(v)", actions: [FormAction("remove:\(k)", L10n.text("Delete"))]))
            }
            return r
        case "gridOptions":
            var r: [FormRow] = [
                .heading(L10n.text("Snap")), .check(label: L10n.text("Snap objects to grid"), key: "snap"), .check(label: L10n.text("Snap objects to other objects"), key: "smart"),
                .text(label: L10n.text("Spacing (pt):"), key: "spacing"), .heading(L10n.text("Display")),
                .check(label: L10n.text("Display grid on screen"), key: "gridlines"), .check(label: L10n.text("Display drawing guides on screen"), key: "guides"),
            ]
            if !d.value("error").isEmpty { r.append(.error(d.value("error"))) }
            return r
        case "columns":
            var r: [FormRow] = [.text(label: L10n.text("Number:"), key: "count"), .text(label: L10n.text("Spacing (in):"), key: "spacing")]
            if !d.value("error").isEmpty { r.append(.error(d.value("error"))) }
            return r
        case "export":
            return exportRows(d)
        case "symbol":
            var r: [FormRow] = [.note(L10n.text("Click a symbol to insert it at the insertion point."))]
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
                .choice(label: L10n.text("Replace:"), key: "from", options: used.map { FormOption($0, $0) }),
                .text(label: L10n.text("With:"), key: "to", placeholder: L10n.text("Font name")),
                .list(label: L10n.text("Fonts"), key: "to", options: fontFamilies().filter { needle.isEmpty || $0.lowercased().contains(needle) }.prefix(200).map { FormOption($0, $0) }, findable: false),
            ]
            if let msg = d.fields["result"] { r.append(.note(msg)) }
            return r
        case "equation":
            return [.note(L10n.text("Type an equation in linear form (e.g. a^2+b^2=c^2, x=(-b±√(b^2-4ac))/2a).")), .text(label: L10n.text("Equation"), key: "eq")]
        case "dateTime":
            return [
                .list(label: L10n.text("Available formats:"), key: "format", options: DialogLists.dateRows(d.value("language")).map { FormOption($0.0, $0.1) }, findable: false),
                .choice(label: L10n.text("Language:"), key: "language", options: DialogLists.dateLanguages.map { FormOption($0.0, $0.1) }),
                .note(L10n.text("Month names and AM/PM are listed for English. Other languages list the numeric date and 24-hour time.")),
                .check(label: L10n.text("Update automatically"), key: "update"),
            ]
        case "spelling":
            return spellingRows(d)
        case "pasteSpecial":
            let hasShapes = !model.session.clipboard.shapes.isEmpty
            return [.radio(label: L10n.text("As:"), key: "as", options: [
                FormOption("destinationTheme", L10n.text("Use Destination Theme")), FormOption("keepSource", L10n.text("Keep Source Formatting"), enabled: hasShapes),
                FormOption("picture", L10n.text("Picture (PNG)"), enabled: hasShapes), FormOption("text", L10n.text("Keep Text Only")),
            ])]
        case "find":
            let replace = d.flag("replace")
            let has = !d.value("text").isEmpty
            var r: [FormRow] = [.text(label: L10n.text("Find what:"), key: "text")]
            if replace { r.append(.text(label: L10n.text("Replace with:"), key: "with")) }
            r += [.check(label: L10n.text("Match case"), key: "matchCase"), .check(label: L10n.text("Find whole words only"), key: "wholeWords")]
            r.append(.actions(replace ? [FormAction("replaceOne", L10n.text("Replace"), enabled: has), FormAction("replaceAll", L10n.text("Replace All"), enabled: has)] : [FormAction("showReplace", L10n.text("Replace…"))]))
            if !d.value("status").isEmpty { r.append(.note(d.value("status"))) }
            return r
        case "accessibility":
            let list = query("review.accessibility")?.asArray ?? []
            if list.isEmpty { return [.note(L10n.text("No accessibility issues found. People with disabilities should not have difficulty reading this document."))] }
            return list.enumerated().map { i, item in
                let name = item["name"]?.asStr.map { " — \($0)" } ?? ""
                return .item(L10n.text("Slide \((item["slide"]?.asU64 ?? 0) + 1): \(item["issue"]?.asStr ?? "")\(name)"), actions: [FormAction("goto:\(i)", L10n.text("Go to"))])
            }
        case "language":
            let hasSel = Cmd.hasTextOrShapes(model.session) == nil
            let all = !hasSel || d.value("scope") == "all"
            let cur = d.field("current")
            var langs = DialogLists.languages.map { ($0.1, $0.0) }
            if !langs.contains(where: { $0.0.caseInsensitiveCompare(cur) == .orderedSame }) { langs.insert((cur, cur), at: 0) }
            return [
                .radio(label: L10n.text("Apply to:"), key: "scope", options: [FormOption("sel", L10n.text("Selected text"), enabled: hasSel), FormOption("all", L10n.text("Whole presentation"))]),
                .note(all ? L10n.text("Mark all text in the presentation as:") : L10n.text("Mark selected text as:")),
                .list(label: L10n.text("Language"), key: "lang", options: langs.map { tag, name in
                    FormOption(tag, Spell.dictionary(tag) != nil ? String(localized: "\(name)  (dictionary)", bundle: .module, comment: "A language name, marked as having a spelling dictionary") : name)
                }, findable: true),
                .note(L10n.text("Spelling is checked for languages marked (dictionary).")),
                .check(label: L10n.text("Do not check spelling or grammar"), key: "noProof"),
            ]
        case "customShow":
            let shows = st?.doc.customShows ?? []
            var r: [FormRow] = shows.enumerated().map { i, s in
                .item(L10n.text("\(s.name) (\(s.slides.count) slides)"), actions: [FormAction("show:\(i)", L10n.text("Show")), FormAction("delete:\(i)", L10n.text("Delete"))])
            }
            r += [.text(label: L10n.text("New show name:"), key: "name"), .text(label: L10n.text("Slides (e.g. 1,3,5):"), key: "slides")]
            return r
        case "chartData":
            guard chartOf(model.session) != nil else { return [.note(L10n.text("Select a chart first."))] }
            return [
                .note(L10n.text("Edit the data: first row = series names, first column = categories.")), .grid(cells: chartGrid(d)),
                .actions([FormAction("addRow", L10n.text("+ Row")), FormAction("addSeries", L10n.text("+ Series"))]),
            ]
        case "trim":
            return [
                .text(label: L10n.text("Start time (s):"), key: "start"), .text(label: L10n.text("End trim (s):"), key: "end"),
                .text(label: L10n.text("Fade in (s):"), key: "fin"), .text(label: L10n.text("Fade out (s):"), key: "fout"),
            ]
        case "smartart":
            return [
                .note(L10n.text("Pick a graphic; type one item per line.")),
                .tabs(key: "kind", options: [
                    FormOption("list", L10n.text("Basic List")), FormOption("process", L10n.text("Basic Process")), FormOption("cycle", L10n.text("Basic Cycle")),
                    FormOption("hierarchy", L10n.text("Hierarchy")), FormOption("pyramid", L10n.text("Pyramid")), FormOption("matrix", L10n.text("Matrix")),
                ]),
                .multiline(label: L10n.text("SmartArt items"), key: "text", lines: 5),
            ]
        case "bullets":
            let numbered = d.value("tab") == "numbered"
            let styles: [FormOption] = numbered
                ? [("arabicPeriod", "1. 2. 3."), ("arabicParenR", "1) 2) 3)"), ("romanUcPeriod", "I. II. III."), ("romanLcPeriod", "i. ii. iii."),
                   ("alphaUcPeriod", "A. B. C."), ("alphaLcParenR", "a) b) c)"), ("alphaLcPeriod", "a. b. c.")].map { FormOption($0.0, $0.1) }
                : ["•", "○", "■", "□", "◆", "➢", "✓", "–", "★"].map { FormOption($0, $0) }
            return [
                .tabs(key: "tab", options: [FormOption("bulleted", L10n.text("Bulleted")), FormOption("numbered", L10n.text("Numbered"))]),
                .radio(label: L10n.text("Style"), key: numbered ? "scheme" : "char", options: styles),
                numbered ? .text(label: L10n.text("Start at:"), key: "start") : .text(label: L10n.text("Custom character:"), key: "custom"),
                .text(label: L10n.text("Size (% of text):"), key: "size"),
                .choice(label: L10n.text("Color:"), key: "color", options: [
                    FormOption("", L10n.text("Automatic")), FormOption("tx1", L10n.text("Text")), FormOption("accent1", L10n.text("Accent 1")), FormOption("accent2", L10n.text("Accent 2")),
                    FormOption("accent3", L10n.text("Accent 3")), FormOption("accent4", L10n.text("Accent 4")), FormOption("accent5", L10n.text("Accent 5")), FormOption("accent6", L10n.text("Accent 6")),
                ]),
                .actions([FormAction("none", L10n.text("None"))]),
            ]
        case "action":
            return actionRows(d)
        case "themeColors":
            let left: [SchemeSlot] = [.dk1, .lt1, .dk2, .lt2, .hlink, .folHlink]
            let right: [SchemeSlot] = [.accent1, .accent2, .accent3, .accent4, .accent5, .accent6]
            var r: [FormRow] = zip(left, right).map { a, b in .row([.color(label: L10n.colorLabel(a.label), key: a.xmlName), .color(label: L10n.colorLabel(b.label), key: b.xmlName)]) }
            r += [.text(label: L10n.text("Name:"), key: "schemeName"), .note(L10n.text("Applies to this presentation's theme colours."))]
            return r
        case "themeFonts":
            let choices = themeFontChoices
            return [
                .row([
                    .list(label: L10n.text("Heading:"), key: "major", options: choices(d.value("major")).map { FormOption($0, $0) }, findable: true),
                    .list(label: L10n.text("Body:"), key: "minor", options: choices(d.value("minor")).map { FormOption($0, $0) }, findable: true),
                ]),
                .sample(FormSample(text: L10n.text("Heading sample  \(d.value("major"))"), family: d.value("major"), size: 20)),
                .sample(FormSample(text: L10n.text("Body sample  \(d.value("minor"))"), family: d.value("minor"), size: 14)),
                .text(label: L10n.text("Name:"), key: "schemeName"), .note(L10n.text("Heading and body fonts for this presentation.")),
            ]
        case "info":
            return infoRows(d)
        case "new":
            return newRows(d)
        default:
            return [.note(L10n.text("“\(d.id)” is not available yet."))]
        }
    }

    func unitAbbr(_ u: DCGeometry.Unit) -> String {
        switch u {
        case .inches: String(localized: "in", bundle: .module, comment: "Unit abbreviation: inches")
        case .centimeters: String(localized: "cm", bundle: .module, comment: "Unit abbreviation: centimeters")
        case .points: String(localized: "pt", bundle: .module, comment: "Unit abbreviation: points")
        case .pixels: String(localized: "px", bundle: .module, comment: "Unit abbreviation: pixels")
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
        var r: [FormRow] = [.radio(label: L10n.text("Export the presentation as:"), key: "fmt", options: DialogBackstage.exportFormats.map { FormOption($0.0, $0.1) })]
        switch d.value("fmt") {
        case "pdf":
            r.append(.choice(label: L10n.text("Print layout:"), key: "pdfLayout", options: DialogBackstage.pdfLayouts.map { FormOption($0.0, $0.1) }))
            r.append(.check(label: L10n.text("Include hidden slides"), key: "pdfHidden"))
        case "png", "pngAll":
            r.append(.check(label: L10n.text("Transparent background"), key: "pngTransparent"))
        case "gif":
            r.append(.choice(label: L10n.text("Size:"), key: "gifSize", options: [
                FormOption("small", L10n.text("Small (640 px wide)")), FormOption("medium", L10n.text("Medium (960 px wide)")), FormOption("large", L10n.text("Large (1280 px wide)")),
                FormOption("extraLarge", L10n.text("Extra Large (1920 px wide)")), FormOption("custom", L10n.text("Custom width")),
            ]))
            if d.value("gifSize") == "custom" { r.append(.text(label: L10n.text("Width (pixels):"), key: "gifWidth")) }
            r += [
                .text(label: L10n.text("Seconds per slide:"), key: "gifSeconds"), .text(label: L10n.text("From slide:"), key: "gifFrom"), .text(label: L10n.text("To slide:"), key: "gifTo"),
                .check(label: L10n.text("Loop forever"), key: "gifLoop"), .check(label: L10n.text("Include hidden slides"), key: "gifHidden"),
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
        var r: [FormRow] = [.heading(L10n.text("Pictures in album"))]
        if items.isEmpty {
            r.append(.note(L10n.text("No pictures yet")))
        } else {
            r.append(.list(label: L10n.text("Pictures in album"), key: "sel", options: items.enumerated().map { FormOption(String($0.offset), DialogAlbum.label($0.element)) }, findable: false))
        }
        r.append(.actions([FormAction("addPictures", L10n.text("Add Pictures…")), FormAction("newTextBox", L10n.text("New Text Box")), FormAction("remove", L10n.text("Remove"))]))
        r.append(.text(label: L10n.text("Text box:"), key: "boxText"))
        r.append(.note(DialogAlbum.status(items, sel)))
        let picture = DialogAlbum.isPicture(items.at(sel))
        let pictureActions = FormRow.actions([
            FormAction("rotateLeft", L10n.text("Rotate Left")), FormAction("rotateRight", L10n.text("Rotate Right")), FormAction("moreBrightness", L10n.text("More Brightness")),
            FormAction("lessBrightness", L10n.text("Less Brightness")), FormAction("moreContrast", L10n.text("More Contrast")), FormAction("lessContrast", L10n.text("Less Contrast")),
        ])
        r.append(picture ? pictureActions : .disabled([pictureActions]))
        r += [
            .choice(label: L10n.text("Picture layout"), key: "layout", options: [
                FormOption("fit", L10n.text("Fit to slide")), FormOption("1", L10n.text("1 picture")), FormOption("2", L10n.text("2 pictures")), FormOption("4", L10n.text("4 pictures")),
                FormOption("1title", L10n.text("1 picture with title")), FormOption("2title", L10n.text("2 pictures with title")), FormOption("4title", L10n.text("4 pictures with title")),
            ]),
            .choice(label: L10n.text("Frame shape"), key: "frame", options: [FormOption("none", L10n.text("None")), FormOption("rect", L10n.text("Rectangle")), FormOption("rounded", L10n.text("Rounded")), FormOption("simple", L10n.text("Simple, white"))]),
            .check(label: L10n.text("Captions under pictures"), key: "captions"), .check(label: L10n.text("ALL pictures black and white"), key: "grayscale"),
            .choice(label: L10n.text("Album theme"), key: "theme", options: DialogLists.albumThemes.map { FormOption($0, $0) }),
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
            r.append(.note(L10n.text("Dictionary: \(f.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? f)")))
        } else if available {
            r.append(.note(L10n.text("Dictionary: \(info["lang"]?.asStr ?? "")")))
        } else {
            r.append(.note(L10n.text("The \(info["lang"]?.asStr ?? "en-US") dictionary isn't installed, so only common misspellings and the system spelling checker's suggestions are found.")))
        }
        if list.isEmpty { r.append(.note(L10n.text("The spelling check is complete. No issues found."))) }
        for (i, item) in list.enumerated() {
            let w = item["word"]?.asStr ?? ""
            r.append(.item(L10n.text("Slide \((item["slide"]?.asU64 ?? 0) + 1): “\(w)”"), actions: [
                FormAction("goto:\(i)", L10n.text("Go to")), FormAction("ignoreAll:\(i)", L10n.text("Ignore All")), FormAction("addWord:\(i)", L10n.text("Add to Dictionary")),
            ]))
            if item["repeated"]?.asBool == true && item["notes"]?.asBool != true {
                r.append(.item(L10n.text("Repeated word"), actions: [FormAction("deleteRepeated:\(i)", L10n.text("Delete Repeated Word"))]))
            }
            let sug = (item["suggestions"]?.asArray ?? []).compactMap(\.asStr)
            if !sug.isEmpty {
                var acts = sug.enumerated().map { FormAction("change:\(i):\($0.offset)", $0.element) }
                if item["notes"]?.asBool != true { acts.append(FormAction("changeAll:\(i):0", L10n.text("Change All to “\(sug[0])”"))) }
                r.append(.item(L10n.text("Change to:"), actions: acts))
            }
        }
        return r
    }

    /// The Action Settings targets (`targets`).
    static let actionTargets: [FormOption] = [
        FormOption("next", L10n.text("Next Slide")), FormOption("previous", L10n.text("Previous Slide")), FormOption("first", L10n.text("First Slide")), FormOption("last", L10n.text("Last Slide")),
        FormOption("lastViewed", L10n.text("Last Slide Viewed")), FormOption("endShow", L10n.text("End Show")), FormOption("customShow", L10n.text("Custom Show…")),
        FormOption("slide", L10n.text("Slide…")), FormOption("url", L10n.text("URL…")),
    ]

    func actionRows(_ d: Dialog) -> [FormRow] {
        let kind = d.value("kind")
        let hover = d.value("tab") == "hover"
        var r: [FormRow] = [
            .tabs(key: "tab", options: [FormOption("click", L10n.text("Mouse Click")), FormOption("hover", L10n.text("Mouse Over"))]),
            .radio(label: hover ? L10n.text("Action on mouse over") : L10n.text("Action on click"), key: "group", options: [
                FormOption("none", L10n.text("None")), FormOption("hyperlink", L10n.text("Hyperlink to:")), FormOption("program", L10n.text("Run program:")),
                FormOption("playMedia", L10n.text("Play the shape's media")),
            ]),
        ]
        switch actionGroup(kind) {
        case "hyperlink":
            r.append(.choice(label: L10n.text("Hyperlink to:"), key: "kind", options: Self.actionTargets))
            switch kind {
            case "url": r.append(.text(label: L10n.text("Address:"), key: "arg"))
            case "slide": r.append(.list(label: L10n.text("Slide:"), key: "arg", options: slideTitles.enumerated().map { FormOption(String($0.offset), $0.element) }, findable: false))
            case "customShow":
                let shows = doc?.doc.customShows.map(\.name) ?? []
                if shows.isEmpty { r.append(.note(L10n.text("This presentation has no custom shows (Slide Show ▸ Custom Shows)."))) }
                r.append(.list(label: L10n.text("Custom show:"), key: "arg", options: shows.map { FormOption($0, $0) }, findable: false))
            default: break
            }
        case "program":
            r.append(.text(label: L10n.text("Program:"), key: "arg"))
        default: break
        }
        r.append(.check(label: L10n.text("Highlight click"), key: "highlight"))
        return r
    }

    /// The radio choice an action kind belongs to.
    func actionGroup(_ kind: String) -> String {
        ["none", "program", "playMedia"].contains(kind) ? kind : "hyperlink"
    }

    func infoRows(_ d: Dialog) -> [FormRow] {
        guard let v = query("file.info") else { return [.note(L10n.text("No presentation is open."))] }
        let path = v["path"]?.asStr
        let dirty = v["dirty"]?.asBool ?? false
        var r: [FormRow] = [.heading(v["title"]?.asStr ?? ""), .note(path ?? L10n.text("Not saved yet"))]
        if path != nil { r.append(.actions([FormAction("copyPath", L10n.text("Copy Path")), FormAction("reveal", L10n.text("Show in Finder"))])) }
        let revert = !dirty ? L10n.text("There are no unsaved changes.")
            : path != nil ? L10n.text("This presentation has unsaved changes. Revert goes back to the saved file.")
            : L10n.text("This presentation has never been saved.")
        r += [
            .item(L10n.text("Inspect Presentation: before you share it, check it for things people with disabilities might find hard to read."), actions: [FormAction("checkIssues", L10n.text("Check for Issues"))]),
            .item(L10n.text("Manage Presentation: \(revert)"), actions: [FormAction("revert", L10n.text("Revert"), enabled: dirty && path != nil)]),
            .heading(L10n.text("Properties")),
        ]
        var facts: [String] = []
        if let b = v["bytes"]?.asU64 { facts.append(L10n.text("Size: \(DialogBackstage.formatBytes(b))")) }
        facts.append(L10n.text("Slides: \(v["slides"]?.asU64 ?? 0)"))
        facts.append(L10n.text("Hidden slides: \(v["hiddenSlides"]?.asU64 ?? 0)"))
        r.append(.note(facts.joined(separator: " · ")))
        for (key, label, hint) in DialogBackstage.properties { r.append(.text(label: label, key: key, placeholder: hint)) }
        return r
    }

    func newRows(_ d: Dialog) -> [FormRow] {
        let q = String(rustTrim(d.value("query"))).lowercased()
        let themes = builtinThemes().filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let sample = q.isEmpty || "sample deck northern lights".contains(q)
        var r: [FormRow] = [.text(label: L10n.text("Search"), key: "query", placeholder: L10n.text("Search for themes and templates"))]
        func swatches(_ name: String) -> [String] {
            guard let th = builtinThemes().first(where: { $0.name == name }) else { return [] }
            return [SchemeSlot.lt1, .dk1, .accent1, .accent2, .accent3, .accent4].map { th.colors.get($0).hex }
        }
        var tiles = themes.map { FormTile("new:theme:\($0.name)", $0.name, colors: swatches($0.name)) }
        if sample { tiles.append(FormTile("new:sample", L10n.text("Sample deck: Northern Lights"), colors: swatches("DeckCraft"))) }
        if !tiles.isEmpty { r += [.heading(L10n.text("Themes")), .tiles(tiles)] }
        let starters = Templates.matching(q)
        if !starters.isEmpty {
            r += [.heading(L10n.text("Templates")), .tiles(starters.map { FormTile("new:template:\($0.name)", $0.name, detail: $0.summary, colors: swatches($0.theme)) })]
        }
        if tiles.isEmpty && starters.isEmpty { r.append(.note(L10n.text("No themes or templates match “\(q)”."))) }
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
            return t.isEmpty ? L10n.text("Text Box") : L10n.text("Text: \(t)")
        }
        return v["name"]?.asStr.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Picture")
    }

    static func isPicture(_ v: JSON?) -> Bool { v?["data"] != nil || v?["path"] != nil }

    /// `album_picture_status`.
    static func status(_ items: [JSON], _ sel: Int) -> String {
        guard let item = items.at(sel) else { return L10n.text("Select a picture to rotate it or change brightness and contrast") }
        if !isPicture(item) { return L10n.text("Text boxes have no picture options") }
        let rot = item["rot"]?.asF64 ?? 0, b = item["brightness"]?.asF64 ?? 0, c = item["contrast"]?.asF64 ?? 0
        return L10n.text("Rotation \(rustFixed(rot, places: 0))°, brightness \(rustFixed(b, places: 1)), contrast \(rustFixed(c, places: 1))")
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
