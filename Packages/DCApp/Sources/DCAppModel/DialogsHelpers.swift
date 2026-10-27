// DCAppModel — the dialogs' pure helpers: parsing and formatting fields, seeding from the selection, and
// building command parameters. Port of the free functions of deckcraft `crates/ui-egui/src/dialogs.rs`
// and `widgets::fmt_num` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCText
import Foundation

public enum DialogMath {
    /// `fmt_num(v, "")`: two decimals with trailing zeros dropped.
    public static func fmtNum(_ v: Double) -> String {
        var s = rustFixed(v, places: 2)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// `s.trim().trim_end_matches(chars)`.
    static func trimEnd(_ s: String, _ chars: Set<Character>) -> String {
        var t = String(rustTrim(s))
        while let c = t.last, chars.contains(c) { t.removeLast() }
        return t
    }

    /// Rust's `str::parse::<f64>` over already-trimmed text, finite values only.
    static func finite(_ s: some StringProtocol) -> Double? {
        let t = String(s)
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// `num`'s parse: `"`, `%` and spaces at the end are ignored.
    static func number(_ s: String) -> Double? { finite(trimEnd(s, ["\"", "%", " "])) }

    /// `parse_shown`.
    static func parseShown(_ s: String) -> Double? {
        let t = trimEnd(String(rustTrim(s)), ["%", "\""])
        return finite(rustTrim(t))
    }

    /// `finite_pt`: a number with an optional `pt` after it.
    public static func finitePt(_ text: String) -> Double? {
        var t = String(rustTrim(text))
        while t.hasSuffix("pt") { t.removeLast(2) }
        return finite(rustTrim(t))
    }

    /// `x as usize` for a float.
    static func usize(_ v: Double) -> Int { Int(clamping: UInt64(rustCast: v)) }

    /// `json_text`: a dialog param as field text.
    static func jsonText(_ v: JSON?, _ def: String) -> String {
        switch v {
        case .string(let s)?: s
        case .bool(true)?: "1"
        case .bool(false)?: "0"
        case let n? where n.isNumber: n.asF64.map(fmtNum) ?? def
        default: def
        }
    }

    /// `color_label`: a colour param as the text the field shows.
    static func colorLabel(_ v: JSON) -> String {
        switch v {
        case .string(let s): s
        case .object(let o): (o["scheme"] ?? o["rgb"])?.asStr ?? ""
        default: ""
        }
    }

    /// `parse_zoom_percent`: a typed zoom percent as a scale in 0.1…4. nil when it is not a finite number.
    public static func parseZoomPercent(_ text: String) -> Double? {
        var t = String(rustTrim(text))
        while t.hasSuffix("%") { t.removeLast() }
        let n = String(rustTrim(t))
        guard !n.isEmpty, let v = finite(n) else { return nil }
        return Double(Float(v / 100).clamped(0.1, 4))
    }

    /// `ms_as_seconds`: three decimals, trailing zeros dropped.
    public static func msAsSeconds(_ ms: UInt32) -> String {
        var s = rustFixed(Double(ms) / 1000, places: 3)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }

    /// `seconds_text_to_ms`: blank, junk and negatives are 0; rounded.
    public static func secondsTextToMs(_ text: String) -> UInt32 {
        let v = finite(rustTrim(text)) ?? 0
        let ms = (Swift.max(v, 0) * 1000).rounded()
        return ms >= Double(UInt32.max) ? UInt32.max : UInt32(rustCast: ms)
    }

    /// `format_spacing`: the grid spacing as the field shows it.
    public static func formatSpacing(_ v: Double) -> String {
        guard v.isFinite else { return "6" }
        if abs(v - v.rounded()) < 1e-6 && abs(v) < 1e6 { return String(Int64(rustCast: v.rounded())) }
        return rustFixed(v, places: 2)
    }

    /// `pretty_equation`: a linear equation with superscripts and math symbols.
    public static func prettyEquation(_ s: String) -> String {
        let sup: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "n": "ⁿ", "i": "ⁱ",
            "+": "⁺", "-": "⁻",
        ]
        var out = ""
        let chars = Array(s.unicodeScalars).map(Character.init)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            switch c {
            case "^":
                while i < chars.count {
                    let n = chars[i]
                    guard (n.isASCII && (n.isLetter || n.isNumber)) || n == "+" || n == "-" else { break }
                    out.append(sup[n] ?? n)
                    i += 1
                    if !(n.isASCII && n.isNumber) { break }
                }
            case "*": out.append("·")
            default: out.append(c)
            }
        }
        return out.replacingOccurrences(of: "sqrt", with: "√").replacingOccurrences(of: "<=", with: "≤")
            .replacingOccurrences(of: ">=", with: "≥").replacingOccurrences(of: "!=", with: "≠")
            .replacingOccurrences(of: "pi", with: "π").replacingOccurrences(of: "+-", with: "±")
    }

    /// `alt_text_starts_decorative`: checked when every selected shape is already decorative.
    public static func altTextStartsDecorative(_ decorative: [Bool]) -> Bool {
        !decorative.isEmpty && decorative.allSatisfy { $0 }
    }

    /// `line_preset_label`.
    static func linePresetLabel(_ kind: String, _ value: String) -> String {
        if kind == "exactly" { return "Exactly" }
        switch value {
        case "1": return "Single"
        case "1.5": return "1.5 lines"
        case "2": return "Double"
        default: return "Multiple"
        }
    }
}

// MARK: - Hyperlink

/// What Insert Hyperlink would edit on the selection (`CurrentLink`).
public enum CurrentLink: Equatable, Sendable {
    case none
    case one(Hyperlink)
    case mixed
}

/// The fields Insert Hyperlink opens with (`HyperlinkSeed`).
public struct HyperlinkSeed: Equatable, Sendable {
    public var mode: String
    public var url: String
    public var email: String
    public var slide: Int
    public var tip: String
    public var highlight: Bool
    /// The action isn't one this dialog edits (or the selection mixes links): OK leaves it until a new
    /// target is chosen.
    public var preserve: Bool

    /// A new link: the address starts at `https://`.
    public static let blank = HyperlinkSeed(mode: "url", url: "https://", email: "", slide: 0, tip: "", highlight: false, preserve: false)

    /// `seed_of_link`.
    public static func of(_ link: Hyperlink, _ slideIds: [SlideId]) -> HyperlinkSeed {
        var seed = HyperlinkSeed(mode: "url", url: "", email: "", slide: 0, tip: link.tooltip, highlight: link.highlightClick, preserve: true)
        switch link.action {
        case .url(let url):
            seed.preserve = false
            if url.hasPrefix("mailto:") {
                seed.mode = "email"
                seed.email = String(url.dropFirst("mailto:".count))
                seed.url = "https://"
            } else {
                seed.url = url
            }
        case .slide(let slide):
            if let i = slideIds.firstIndex(of: slide) {
                seed.preserve = false
                seed.mode = "slide"
                seed.slide = i
                seed.url = "https://"
            }
        default: break
        }
        return seed
    }

    /// `seed_from`.
    public static func from(_ current: CurrentLink, _ slideIds: [SlideId]) -> HyperlinkSeed {
        switch current {
        case .none: return .blank
        case .mixed:
            var s = HyperlinkSeed.blank
            s.preserve = true
            s.url = ""
            return s
        case .one(let link): return of(link, slideIds)
        }
    }

    /// `link_covering`: links on the half-open span `[a, b)`. A point span is a new link.
    public static func linkCovering(_ body: TextBody, _ a: (Int, Int), _ b: (Int, Int)) -> CurrentLink {
        if a == b { return .none }
        var seen: Hyperlink??
        for (pi, para) in body.paragraphs.enumerated() {
            if pi < a.0 || pi > b.0 { continue }
            let from = pi == a.0 ? a.1 : 0
            let to = pi == b.0 ? b.1 : Int.max
            if from >= to { continue }
            var acc = 0
            var covered = false
            for run in para.runs {
                let len = run.charLen
                let end = acc + len
                if len > 0 && end > from && acc < to {
                    covered = true
                    switch seen {
                    case .none: seen = .some(run.props.link)
                    case .some(let prev) where prev == run.props.link: break
                    case .some: return .mixed
                    }
                }
                acc = end
            }
            if !covered && para.charLen == 0 {
                switch seen {
                case .none: seen = .some(para.endProps.link)
                case .some(let prev) where prev == para.endProps.link: break
                case .some: return .mixed
                }
            }
        }
        if case .some(.some(let link)) = seen { return .one(link) }
        return .none
    }

    /// `common_click`.
    public static func commonClick(_ clicks: [Hyperlink?]) -> CurrentLink {
        guard let first = clicks.first else { return .none }
        for next in clicks.dropFirst() where next != first { return .mixed }
        return first.map { .one($0) } ?? .none
    }

    /// `hyperlink_seed_of`: text when a caret or selection is active, otherwise the selected shapes' click.
    public static func of(_ st: DocState?) -> HyperlinkSeed {
        guard let st else { return .blank }
        let ids = st.doc.slides.map(\.id)
        let current: CurrentLink
        if let t = st.selection.text {
            if let body = TextCommands.bodyOf(st, t) {
                let (a, b) = TextCommands.formatRange(st, t)
                current = linkCovering(body, a, b)
            } else {
                current = .none
            }
        } else {
            current = commonClick(st.selectedShapes.map(\.click))
        }
        return from(current, ids)
    }

    /// `hyperlink_should_apply`.
    public func shouldApply(mode: String, url: String, email: String, slide: Int) -> Bool {
        if !preserve || mode != self.mode { return true }
        switch mode {
        case "email": return email != self.email
        case "slide": return slide != self.slide
        default: return url != self.url
        }
    }

    /// `hyperlink_command`: `insert.hyperlink`'s params.
    public static func command(mode: String, url: String, email: String, slide: Int, tip: String, highlight: Bool) -> JSON {
        switch mode {
        case "slide": ["slide": .integer(slide), "tooltip": .string(tip), "highlightClick": .bool(highlight)]
        case "email": ["url": .string("mailto:\(email)"), "tooltip": .string(tip), "highlightClick": .bool(highlight)]
        default: ["url": .string(url), "tooltip": .string(tip), "highlightClick": .bool(highlight)]
        }
    }
}

// MARK: - Trim Media

/// Start, end trim, fade in and fade out as the Trim Media dialog shows them (`TrimSeed`).
public struct TrimSeed: Equatable, Sendable {
    public var start: String
    public var end: String
    public var fadeIn: String
    public var fadeOut: String

    public static let zeros = TrimSeed(start: "0", end: "0", fadeIn: "0", fadeOut: "0")

    /// `trim_seed`: the first selected audio or video.
    public static func of(_ st: DocState?) -> TrimSeed {
        guard let st else { return .zeros }
        for sh in st.selectedShapes {
            if case .media(let m) = sh.kind {
                return TrimSeed(
                    start: DialogMath.msAsSeconds(m.trimStartMs), end: DialogMath.msAsSeconds(m.trimEndMs),
                    fadeIn: DialogMath.msAsSeconds(m.fadeInMs), fadeOut: DialogMath.msAsSeconds(m.fadeOutMs)
                )
            }
        }
        return .zeros
    }
}

// MARK: - Size and Position

enum SizePosition {
    static let keys = ["x", "y", "w", "h", "rot", "scaleW", "scaleH"]

    static func exact(_ d: Dialog, _ key: String) -> Double? { DialogMath.parseShown(d.field("\(key)Pt")) }
    static func edited(_ d: Dialog, _ key: String) -> Bool { d.field(key) != d.field("seed\(key)") }

    static func put(_ d: inout Dialog, _ key: String, _ exact: Double, _ shown: String) {
        d.fields[key] = shown
        d.fields["seed\(key)"] = shown
        d.fields["prev\(key)"] = shown
        d.fields["\(key)Pt"] = String(exact)
    }

    static func publish(_ d: inout Dialog, _ key: String, _ exact: Double, _ shown: String) {
        d.fields[key] = shown
        d.fields["seed\(key)"] = shown
        d.fields["\(key)Pt"] = String(exact)
    }

    static func scaleOf(_ pt: Double, _ base: Double) -> Double { base > 0 ? pt / base * 100 : 100 }

    static func currentPoints(_ d: Dialog, _ key: String) -> Double? {
        edited(d, key) ? DialogMath.parseShown(d.field(key)).map { $0 * 72 } : exact(d, key)
    }

    /// `seed_size_position`.
    @MainActor static func seed(_ d: inout Dialog, _ st: DocState?) {
        if d.fields["baseW"] != nil { return }
        func num(_ k: String) -> Double? { d.params[k]?.asF64.flatMap { $0.isFinite ? $0 : nil } }
        var sel: Xfrm?
        if let st, let id = st.selection.shapes.first, let sh = st.shape(id) { sel = Cmd.xfrmOf(st.doc, st.selection, sh) }
        let x = num("x") ?? sel?.x ?? 0, y = num("y") ?? sel?.y ?? 0
        let w = num("w") ?? sel?.w ?? 72, h = num("h") ?? sel?.h ?? 72
        let rot = num("rot") ?? sel?.rot ?? 0
        let sw = num("scaleW") ?? 100, sh = num("scaleH") ?? 100
        let lock = d.params["lockAspect"]?.asBool ?? false
        put(&d, "x", x, DialogMath.fmtNum(x / 72))
        put(&d, "y", y, DialogMath.fmtNum(y / 72))
        put(&d, "w", w, DialogMath.fmtNum(w / 72))
        put(&d, "h", h, DialogMath.fmtNum(h / 72))
        put(&d, "rot", rot, DialogMath.fmtNum(rot))
        put(&d, "scaleW", sw, DialogMath.fmtNum(sw))
        put(&d, "scaleH", sh, DialogMath.fmtNum(sh))
        d.fields["baseW"] = String(w)
        d.fields["baseH"] = String(h)
        d.fields["lock"] = lock ? "1" : "0"
        d.fields["prevlock"] = lock ? "1" : "0"
    }

    /// `reconcile_size_fields`: scale tied to size, and the other side tied when the aspect is locked.
    static func reconcile(_ d: inout Dialog) {
        let lock = d.field("lock") == "1"
        let wasLocked = d.field("prevlock") == "1"
        let baseW = DialogMath.parseShown(d.field("baseW")) ?? 1
        let baseH = DialogMath.parseShown(d.field("baseH")) ?? 1
        let ar = baseH > 0 ? baseW / baseH : 1
        let fmt = DialogMath.fmtNum
        if d.field("w") != d.field("prevw") {
            if let inches = DialogMath.parseShown(d.field("w")) {
                let wPt = inches * 72
                d.fields["wPt"] = String(wPt)
                let pct = scaleOf(wPt, baseW)
                publish(&d, "scaleW", pct, fmt(pct))
                if lock {
                    let hPt = ar > 0 ? wPt / ar : wPt
                    publish(&d, "h", hPt, fmt(hPt / 72))
                    let hp = scaleOf(hPt, baseH)
                    publish(&d, "scaleH", hp, fmt(hp))
                }
            }
        } else if d.field("h") != d.field("prevh") {
            if let inches = DialogMath.parseShown(d.field("h")) {
                let hPt = inches * 72
                d.fields["hPt"] = String(hPt)
                let pct = scaleOf(hPt, baseH)
                publish(&d, "scaleH", pct, fmt(pct))
                if lock {
                    let wPt = hPt * ar
                    publish(&d, "w", wPt, fmt(wPt / 72))
                    let wp = scaleOf(wPt, baseW)
                    publish(&d, "scaleW", wp, fmt(wp))
                }
            }
        } else if d.field("scaleW") != d.field("prevscaleW") {
            if let pct = DialogMath.parseShown(d.field("scaleW")) {
                let wPt = baseW * pct / 100
                d.fields["scaleWPt"] = String(pct)
                publish(&d, "w", wPt, fmt(wPt / 72))
                if lock {
                    let hPt = ar > 0 ? wPt / ar : wPt
                    publish(&d, "h", hPt, fmt(hPt / 72))
                    publish(&d, "scaleH", pct, fmt(pct))
                }
            }
        } else if d.field("scaleH") != d.field("prevscaleH") {
            if let pct = DialogMath.parseShown(d.field("scaleH")) {
                let hPt = baseH * pct / 100
                d.fields["scaleHPt"] = String(pct)
                publish(&d, "h", hPt, fmt(hPt / 72))
                if lock {
                    let wPt = hPt * ar
                    publish(&d, "w", wPt, fmt(wPt / 72))
                    publish(&d, "scaleW", pct, fmt(pct))
                }
            }
        } else if lock && !wasLocked, let wPt = currentPoints(d, "w") {
            let hPt = ar > 0 ? wPt / ar : wPt
            publish(&d, "h", hPt, fmt(hPt / 72))
            let hp = scaleOf(hPt, baseH)
            publish(&d, "scaleH", hp, fmt(hp))
            let wp = scaleOf(wPt, baseW)
            publish(&d, "scaleW", wp, fmt(wp))
        }
        for key in keys { d.fields["prev\(key)"] = d.field(key) }
        d.fields["prevlock"] = lock ? "1" : "0"
    }

    static func shownPoints(_ d: Dialog, _ key: String, _ label: String) -> Result<Double, CommandError> {
        if edited(d, key) {
            guard let n = DialogMath.parseShown(d.field(key)) else { return .failure(CommandError("\(label) must be a number")) }
            return .success(n * 72)
        }
        return exact(d, key).map { .success($0) } ?? .failure(CommandError("\(label) must be a number"))
    }

    static func shownNumber(_ d: Dialog, _ key: String, _ label: String) -> Result<Double, CommandError> {
        if edited(d, key) {
            return DialogMath.parseShown(d.field(key)).map { .success($0) } ?? .failure(CommandError("\(label) must be a number"))
        }
        return exact(d, key).map { .success($0) } ?? .failure(CommandError("\(label) must be a number"))
    }

    /// `size_position_value`: `shape.sizePosition`'s params.
    static func value(_ d: Dialog) -> Result<JSON, CommandError> {
        do {
            let x = try shownPoints(d, "x", "Horizontal").get()
            let y = try shownPoints(d, "y", "Vertical").get()
            let rot = try shownNumber(d, "rot", "Rotation").get()
            let baseW = DialogMath.parseShown(d.field("baseW")) ?? 1
            let baseH = DialogMath.parseShown(d.field("baseH")) ?? 1
            var w = edited(d, "w") ? try shownPoints(d, "w", "Width").get()
                : edited(d, "scaleW") ? baseW * (try shownNumber(d, "scaleW", "Scale width").get()) / 100
                : try shownPoints(d, "w", "Width").get()
            var h = edited(d, "h") ? try shownPoints(d, "h", "Height").get()
                : edited(d, "scaleH") ? baseH * (try shownNumber(d, "scaleH", "Scale height").get()) / 100
                : try shownPoints(d, "h", "Height").get()
            let lock = d.field("lock") == "1"
            if lock {
                let ar = baseH > 0 ? baseW / baseH : 1
                let widthDrives = edited(d, "w") || edited(d, "scaleW") || (!edited(d, "h") && !edited(d, "scaleH"))
                if widthDrives { h = ar > 0 ? w / ar : h } else { w = h * ar }
            }
            return .success(["x": .num(x), "y": .num(y), "w": .num(w), "h": .num(h), "rot": .num(rot), "lockAspect": .bool(lock)])
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Columns, Paragraph, GIF

enum DialogParams {
    /// `columns_value`: the changed fields as `format.columns` params; nil when neither changed.
    static func columns(_ d: Dialog, shownCount: String, shownSpacing: String) -> Result<JSON?, CommandError> {
        var p = JSONObject()
        let count = d.field("count")
        if count != shownCount {
            guard let n = UInt32(String(rustTrim(count))), (1 ... 16).contains(n) else {
                return .failure("Number must be a whole number from 1 to 16")
            }
            p.set("count", .integer(n))
        }
        let spacing = d.field("spacing")
        if spacing != shownSpacing {
            var t = String(rustTrim(spacing))
            while t.hasSuffix("in") { t.removeLast(2) }
            while t.hasSuffix("\"") { t.removeLast() }
            guard let inches = DialogMath.finite(rustTrim(t)), (0 ... 22).contains(inches) else {
                return .failure("Spacing must be from 0 to 22 inches")
            }
            p.set("spacing", .num(inches * 72))
        }
        return .success(p.isEmpty ? nil : .object(p))
    }

    /// `paragraph_return_params`: Paragraph's fields as the params it reopens with after Tabs….
    static func paragraphReturn(_ d: inout Dialog) -> JSON {
        let pt = DialogMath.finitePt
        let before = (pt(d.get("before", "0")) ?? 0) * 72
        let after = (pt(d.get("after", "0")) ?? 0) * 72
        let by = (pt(d.get("by", "0")) ?? 0) * 72
        let spaceBefore = pt(d.get("spaceBefore", "0")) ?? 0
        let spaceAfter = pt(d.get("spaceAfter", "0")) ?? 0
        let lineValue = pt(d.get("lineValue", "1")) ?? 1
        let beforeSame = d.get("spaceBefore", "") == d.get("spaceBeforeSeed", "")
        let afterSame = d.get("spaceAfter", "") == d.get("spaceAfterSeed", "")
        return [
            "align": .string(d.get("align", "left")), "indentLeft": .num(before), "indentRight": .num(after),
            "special": .string(d.get("special", "none")), "specialBy": .num(by), "spaceBefore": .num(spaceBefore),
            "spaceBeforeKind": .string(beforeSame ? d.params["spaceBeforeKind"]?.asStr ?? "pts" : "pts"),
            "spaceAfter": .num(spaceAfter),
            "spaceAfterKind": .string(afterSame ? d.params["spaceAfterKind"]?.asStr ?? "pts" : "pts"),
            "lineKind": .string(d.get("lineKind", "multiple")), "lineValue": .num(lineValue),
            "tabs": d.params["tabs"] ?? [], "defaultTab": d.params["defaultTab"] ?? .double(72),
        ]
    }

    /// `gif_options`: the Animated GIF fields as `file.export` params, or why they don't fit the deck.
    static func gif(_ d: inout Dialog, slides n: Int) -> Result<JSON, CommandError> {
        let size = d.get("gifSize", "medium")
        let width: JSON
        if size == "custom" {
            let w = (DialogMath.number(d.get("gifWidth", "960")) ?? 960).rounded()
            guard Double(GifExport.minWidth) ... Double(GifExport.maxWidth) ~= w else {
                return .failure(CommandError("Width: enter \(GifExport.minWidth) to \(GifExport.maxWidth) pixels"))
            }
            width = .integer(UInt32(rustCast: w))
        } else {
            width = .string(size)
        }
        let seconds = DialogMath.number(d.get("gifSeconds", "5")) ?? .nan
        if (try? GifExport.checkSeconds(seconds)) == nil {
            return .failure(CommandError("Seconds per slide: enter \(DialogMath.fmtNum(GifExport.minSeconds)) to \(DialogMath.fmtNum(GifExport.maxSeconds))"))
        }
        var p: JSON = [
            "width": width, "secondsPerSlide": .num(seconds), "loop": .bool(d.get("gifLoop", "1") == "1"),
            "includeHidden": .bool(d.get("gifHidden", "0") == "1"),
        ]
        let from = (DialogMath.number(d.get("gifFrom", "1")) ?? 1).rounded()
        let to = (DialogMath.number(d.get("gifTo", String(Swift.max(n, 1)))) ?? Double(n)).rounded()
        guard from >= 1 && from <= to && to <= Double(n) else { return .failure(CommandError("Slides: choose a range from 1 to \(n)")) }
        if from > 1 || to < Double(n) {
            p.set("slides", .array((DialogMath.usize(from) - 1 ..< DialogMath.usize(to)).map { .integer($0) }))
        }
        return .success(p)
    }
}

// MARK: - Lists the dialogs offer

public enum DialogLists {
    /// `squiggles::LANGS`: the proofing languages, by native name.
    public static let languages: [(String, String)] = [
        ("English (United States)", "en-US"), ("English (United Kingdom)", "en-GB"), ("English (Australia)", "en-AU"),
        ("English (Canada)", "en-CA"), ("Español (España)", "es-ES"), ("Español (México)", "es-MX"), ("Français (France)", "fr-FR"),
        ("Français (Canada)", "fr-CA"), ("Deutsch (Deutschland)", "de-DE"), ("Deutsch (Schweiz)", "de-CH"), ("Italiano", "it-IT"),
        ("Nederlands", "nl-NL"), ("Português (Brasil)", "pt-BR"), ("Português (Portugal)", "pt-PT"), ("Polski", "pl-PL"),
        ("Svenska", "sv-SE"), ("Dansk", "da-DK"), ("Norsk bokmål", "nb-NO"), ("Suomi", "fi-FI"), ("Čeština", "cs-CZ"),
        ("Українська", "uk-UA"), ("Русский", "ru-RU"), ("Беларуская", "be-BY"), ("Türkçe", "tr-TR"), ("Ελληνικά", "el-GR"),
        ("日本語", "ja-JP"), ("中文(中国)", "zh-CN"), ("한국어", "ko-KR"), ("العربية", "ar-SA"), ("עברית", "he-IL"),
    ]

    /// `DATE_LANGS`.
    public static let dateLanguages: [(String, String)] = [
        ("en-US", "English (United States)"), ("en-GB", "English (United Kingdom)"), ("fr-FR", "French (France)"),
        ("ja-JP", "Japanese"), ("sv-SE", "Swedish"),
    ]

    /// `ALBUM_THEMES`.
    public static let albumThemes = ["DeckCraft", "Harbor", "Ember", "Meadow", "Nocturne", "Paper", "Coral Reef", "Slate"]

    /// `ZOOM_PRESETS`, largest first.
    public static let zoomPresets = [400, 200, 150, 100, 75, 66, 50, 33]

    /// `date_rows`: the date formats `lang` can show, each with today's sample.
    public static func dateRows(_ lang: String, now: DateTime? = DateTime.nowLocal()) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let now {
            for kind in DateFields.dateKinds {
                if let sample = DateFields.fieldText(kind, lang, now) { rows.append((kind, sample)) }
            }
        }
        if rows.isEmpty { rows.append(("datetime1", "datetime1")) }
        return rows
    }

    /// The Symbol dialog's groups.
    public static let symbols: [(String, String)] = [
        ("Punctuation", "–—‘’“”…•·§¶†‡‰′″‹›«»¡¿"),
        ("Currency", "$€£¥¢₹₩₽₺₿"),
        ("Math", "±×÷≠≈≤≥∞√∑∏∫∂∆∇∈∉∩∪⊂⊃∀∃¬∧∨⇒⇔°′"),
        ("Greek", "αβγδεζηθικλμνξοπρστυφχψωΓΔΘΛΞΠΣΦΨΩ"),
        ("Arrows", "←↑→↓↔↕⇐⇑⇒⇓↖↗↘↙⟵⟶"),
        ("Shapes", "■□▪▫▲△▶▷▼▽◀◁◆◇○●◎★☆✓✔✗✘♠♣♥♦"),
    ]

    /// `selected_language`: the selection's proofing language and Do Not Check Spelling.
    @MainActor public static func selectedLanguage(_ session: Session) -> (String, Bool) {
        guard let st = session.activeDoc else { return ("en-US", false) }
        func run(_ sh: Shape, _ at: (Int, Int)?) -> RunProps? {
            guard let t = sh.text else { return nil }
            if let (p, c) = at {
                guard let para = t.paragraphs.at(p) else { return nil }
                var n = 0
                for r in para.runs {
                    n += r.charLen
                    if c <= n { return r.props }
                }
                return para.runs.last?.props
            }
            return t.paragraphs.lazy.flatMap(\.runs).first?.props
        }
        var props: RunProps?
        if let t = st.selection.text, !t.notes, t.cell == nil {
            props = st.shape(t.shape).flatMap { run($0, t.caret.tuple) }
        } else {
            props = st.selection.shapes.first.flatMap { st.shape($0) }.flatMap { run($0, nil) }
        }
        return (props?.lang ?? "en-US", props?.noProof == true)
    }
}
