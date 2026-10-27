// DCEngine — the `review` command module: the Review tab (comments, spelling, the thesaurus,
// accessibility, Compare) and the Slide Show requests.
// Port of deckcraft crates/engine/src/cmd/review.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel
import Foundation

public enum ReviewCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("comment.add", "New Comment", ["Review", "Comments"], "Cmd+Alt+M", "{text, x?, y?, id?: shape}", Cmd.hasSlide, add),
            .cmd("comment.reply", "Reply", ["Comments"], nil, "{index, text}", Cmd.hasSlide, reply),
            .cmd("comment.delete", "Delete Comment", ["Review", "Comments"], nil, "{index? | all?: bool}", Cmd.hasSlide, delete),
            .cmd("comment.resolve", "Resolve Thread", ["Comments"], nil, "{index, resolved?: bool}", Cmd.hasSlide, resolve),
            .query("comment.list", "Comments", [], nil, "{slide?} → comments", Cmd.hasSlide, list),
            .noundo("comment.next", "Next Comment", ["Review", "Comments"], nil, "{slide?, index?} → {slide, index, text}", Cmd.hasSlide) { s, p in
                try neighbour(s, p, true)
            },
            .noundo("comment.prev", "Previous Comment", ["Review", "Comments"], nil, "{slide?, index?} → {slide, index, text}", Cmd.hasSlide) { s, p in
                try neighbour(s, p, false)
            },
            .query("review.accessibility", "Check Accessibility", ["Review", "Accessibility"], nil, "{} → [{slide, shape, issue}]", Cmd.hasDoc, accessibility),
            .query(
                "review.spelling",
                "Spelling",
                ["Review", "Proofing"],
                "F7",
                "{lang?, ignore?:[word]} → [{slide, shape?, row?, col?, notes?, para, start, end, word, lang, suggestions}] (shapes, table cells and notes; repeated words as {repeated, deleteFrom}; runs marked noProof skipped; each run in its own language, lang? for runs without one; Hunspell dictionaries installed on the system, else a built-in list of common misspellings)",
                Cmd.hasDoc,
                spelling
            ),
            .cmd(
                "review.spellingChange",
                "Change Spelling",
                ["Review", "Proofing"],
                nil,
                "{shape, word, to, all?, para?, start?, row?, col?} → {changed} (replace the whole word in that shape's text, the one at para/start, or in every shape with all)",
                Cmd.hasDoc,
                spellingChange
            ),
            .noundo(
                "review.addToDictionary",
                "Add to Dictionary",
                ["Review", "Proofing"],
                nil,
                "{word} → {word, file} (append to the user dictionary file; not an undo step)",
                Cmd.always,
                addToDictionary
            ),
            .query(
                "review.dictionary",
                "Spelling Dictionary",
                ["Review", "Proofing"],
                nil,
                "{lang?} → {lang, available, found, folders} (whether review.spelling has a dictionary, and which file)",
                Cmd.always,
                dictionaryInfo
            ),
            .query(
                "review.thesaurus",
                "Thesaurus",
                ["Review", "Proofing"],
                nil,
                "{word? (default: the selected word, or the word at the caret)} → {word, senses: [{word, synonyms}]}",
                Cmd.hasDoc,
                thesaurus
            ),
            .cmd("review.replaceWord", "Insert Synonym", [], nil, "{with}: replace the selected word (or the word at the caret) while editing text", Cmd.hasText, insertSynonym),
            .noundo("review.compare", "Compare", ["Review", "Compare"], nil, "{path} | {name, data: base64} — compare with a revised copy → {name, changes}", Cmd.hasDoc, compare),
            .query("review.revisions", "Revisions", [], nil, "{} → {name, changes: [{kind: inserted|deleted|changed, slide, revised, details}]}", Cmd.hasDoc, revisions),
            .cmd("review.accept", "Accept Revision", ["Review", "Compare"], nil, "{index} | {all: true}", comparing, accept),
            .noundo(
                "review.reject",
                "Reject Revision",
                ["Review", "Compare"],
                nil,
                "{index} | {all: true} → {rejected} (drop revisions without applying them: the open deck stays as it is; not an undo step)",
                comparing,
                reject
            ),
            .noundo("review.endCompare", "End Review", ["Review", "Compare"], nil, "{}", comparing, endCompare),
            .noundo("show.fromStart", "Play from Start", ["Slide Show", "Start Slide Show"], "Cmd+Shift+Enter", "{}", Cmd.hasSlide) { s, _ in start(s, 0) },
            .noundo("show.fromCurrent", "Play from Current Slide", ["Slide Show", "Start Slide Show"], "Cmd+Enter", "{}", Cmd.hasSlide) { s, _ in
                try start(s, s.doc().selection.slide)
            },
            .cmd(
                "show.setup",
                "Set Up Slide Show…",
                ["Slide Show", "Set Up"],
                nil,
                "{type?: speaker|browsed|kiosk, loop?: bool, noNarration?, noAnimation?, useTimings?, showMediaControls?, from?, to?, custom?: name}",
                Cmd.hasDoc,
                setup
            ),
            .cmd("show.customShow", "Custom Slide Show", ["Slide Show", "Start Slide Show"], nil, "{name, slides: [index]} | {name, delete: true}", Cmd.hasDoc, customShow),
        ]
    }
}

// MARK: - Comments

extension ReviewCommands {
    /// Seconds since the Unix epoch.
    static func nowSecs() -> UInt64 { UInt64(rustCast: Date().timeIntervalSince1970) }

    /// A UTC timestamp as saved on comments: `2026-10-10T13:10:35Z` (`iso_utc`).
    static func isoUTC(_ secs: UInt64) -> String {
        let (y, m, d) = DesignCommands.civil(Int64(secs / 86_400))
        let t = secs % 86_400
        func two(_ v: UInt64) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let year = y >= 0 && y < 1000 ? String(repeating: "0", count: 4 - String(y).count) + String(y) : String(y)
        return "\(year)-\(two(UInt64(m)))-\(two(UInt64(d)))T\(two(t / 3600)):\(two(t / 60 % 60)):\(two(t % 60))Z"
    }

    static func now() -> String { isoUTC(nowSecs()) }

    @Sendable static func add(_ s: Session, _ p: JSON) throws -> JSON {
        guard let text = Cmd.strParam(p, "text") else { throw Cmd.bad("comment.add", "missing `text`") }
        let author = s.prefs.author
        let shape = try Cmd.idParam(p, "id", "comment.add") ?? s.activeDoc?.selection.shapes.first
        let (x, y) = (Cmd.f64Or(p, "x", 10.0), Cmd.f64Or(p, "y", 10.0))
        return try s.edit { doc, sel in
            guard doc.slides.indices.contains(sel.slide) else { throw Cmd.bad("comment.add", "no slide") }
            let initials = author.unicodeScalars.split(whereSeparator: \.properties.isWhitespace).compactMap(\.first).map(String.init).joined()
            doc.slides[sel.slide].comments.append(Comment(author: author, initials: initials, text: text, date: now(), x: x, y: y, resolved: false, replies: [], shape: shape))
            return ["index": .integer(doc.slides[sel.slide].comments.count - 1)]
        }
    }

    @Sendable static func reply(_ s: Session, _ p: JSON) throws -> JSON {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad("comment.reply", "missing `index`") }
        let text = Cmd.strParam(p, "text") ?? ""
        let author = s.prefs.author
        try s.edit { doc, sel in
            guard doc.slides.indices.contains(sel.slide) else { throw Cmd.bad("comment.reply", "no slide") }
            guard doc.slides[sel.slide].comments.indices.contains(i) else { throw Cmd.bad("comment.reply", "no such comment") }
            doc.slides[sel.slide].comments[i].replies.append(Comment(author: author, text: text, date: now()))
        }
        return Cmd.ok()
    }

    @Sendable static func delete(_ s: Session, _ p: JSON) throws -> JSON {
        let all = Cmd.boolOr(p, "all", false)
        var i: Int?
        if let v = p.get("index"), !v.isNull {
            guard let x = v.asU64.flatMap({ Int(exactly: $0) }) else {
                throw Cmd.bad("comment.delete", "`index` is not a valid comment index: \(v.display)")
            }
            i = x
        }
        try s.edit { doc, sel in
            if all {
                for k in doc.slides.indices { doc.slides[k].comments.removeAll() }
                return
            }
            guard doc.slides.indices.contains(sel.slide) else { throw Cmd.bad("comment.delete", "no slide") }
            switch i {
            case .some(let i) where i < doc.slides[sel.slide].comments.count: doc.slides[sel.slide].comments.remove(at: i)
            case nil: doc.slides[sel.slide].comments.removeAll()
            default: throw Cmd.bad("comment.delete", "no such comment")
            }
        }
        return Cmd.ok()
    }

    @Sendable static func resolve(_ s: Session, _ p: JSON) throws -> JSON {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad("comment.resolve", "missing `index`") }
        let v = Cmd.boolOr(p, "resolved", true)
        try s.edit { doc, sel in
            guard doc.slides.indices.contains(sel.slide) else { throw Cmd.bad("comment.resolve", "no slide") }
            guard doc.slides[sel.slide].comments.indices.contains(i) else { throw Cmd.bad("comment.resolve", "no such comment") }
            doc.slides[sel.slide].comments[i].resolved = v
        }
        return Cmd.ok()
    }

    @Sendable static func list(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let i = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        return .array((st.doc.slides.at(i)?.comments ?? []).map { $0.toJSON() })
    }

    /// Step to the next or previous comment (`neighbour`).
    private static func neighbour(_ s: Session, _ p: JSON, _ forward: Bool) throws -> JSON {
        let cmd = forward ? "comment.next" : "comment.prev"
        let st = try s.doc()
        var threads: [(Int, Int)] = []
        for (si, sl) in st.doc.slides.enumerated() { for ci in sl.comments.indices { threads.append((si, ci)) } }
        let slide = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        let index = Cmd.usizeParam(p, "index")
        if threads.isEmpty { throw Cmd.bad(cmd, "no comments") }
        let pos = index.flatMap { i in threads.firstIndex { $0.0 == slide && $0.1 == i } }
        let target: (Int, Int)? = switch (pos, forward) {
        case (.some(let i), true): threads.at(i + 1)
        case (.some(let i), false): i > 0 ? threads.at(i - 1) : nil
        case (nil, true): threads.first { $0.0 >= slide }
        case (nil, false): threads.last { $0.0 < slide }
        }
        guard let (tslide, tindex) = target else { throw Cmd.bad(cmd, "no more comments") }
        try s.select { doc, sel in
            sel.slide = tslide
            sel.slides = doc.slides.at(tslide).map { [$0.id] } ?? []
            sel.shapes.removeAll()
            sel.text = nil
            sel.cells = nil
            sel.target = .slides
        }
        let text = try s.doc().doc.slides.at(tslide)?.comments.at(tindex)?.text ?? ""
        return ["slide": .integer(tslide), "index": .integer(tindex), "text": .string(text)]
    }
}

// MARK: - Accessibility and spelling

extension ReviewCommands {
    @Sendable static func accessibility(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        var out: [JSON] = []
        for (i, sl) in st.doc.slides.enumerated() {
            if rustTrim(sl.title).isEmpty { out.append(["slide": .integer(i), "issue": "Missing slide title"]) }
            walk(sl.shapes) { sh, _ in
                let needsAlt: Bool = switch sh.kind {
                case .picture, .chart, .media, .group: true
                default: false
                }
                if needsAlt && rustTrim(sh.descr).isEmpty && !sh.decorative {
                    out.append(["slide": .integer(i), "shape": sh.id.toJSON(), "name": .string(sh.name), "issue": "Missing alternative text"])
                }
            }
            // Low-contrast text against the slide background.
            guard let ctx = Resolve.Ctx.forSlide(st.doc, sl) else { continue }
            let (bgFill, ph) = Resolve.background(ctx, sl)
            guard case .solid(let color) = bgFill else { continue }
            let bg = ctx.color(color, ph)
            for sh in sl.shapes {
                guard let t = sh.text, let para = t.paragraphs.first(where: { !$0.isEmpty }) else { continue }
                let rp = Resolve.run(ctx, sh, para, para.runs.first?.props ?? RunProps())
                if let f = Resolve.fill(ctx, sh).fill, !f.isNone { continue }
                let fg = Resolve.textColor(ctx, rp)
                if fg.contrast(bg) < 3.0 {
                    out.append([
                        "slide": .integer(i), "shape": sh.id.toJSON(), "name": .string(sh.name),
                        "issue": .string("Hard-to-read text contrast (\(rustFixed(fg.contrast(bg), places: 1)):1)"),
                    ])
                }
            }
        }
        return .array(out)
    }

    /// Frequent misspellings, used when no dictionary for the language is installed.
    static let common = [
        "teh", "recieve", "seperate", "occured", "untill", "wich", "becuase", "definately", "thier", "alot", "accomodate", "acheive",
        "adress", "begining", "beleive", "calender", "commited", "enviroment", "goverment", "independant", "neccessary", "occassion",
        "publically", "reccomend", "tommorow", "wierd",
    ]

    /// The language a check uses: the `lang` parameter, else the first run that says, else US English
    /// (`check_lang`).
    static func checkLang(_ doc: Presentation, _ p: JSON) -> String {
        if let l = Cmd.strParam(p, "lang") { return l }
        var found: String?
        for sl in doc.slides {
            walk(sl.shapes) { sh, _ in
                if found == nil, let t = sh.text {
                    found = t.paragraphs.lazy.flatMap(\.runs).compactMap(\.props.lang).first
                }
            }
        }
        return found ?? "en-US"
    }

    private static func merged(_ v: JSON, _ at: JSON) -> JSON {
        guard case .object(var o) = v, case .object(let a) = at else { return v }
        for e in a.entries { o.set(e.key, e.value) }
        return .object(o)
    }

    @Sendable static func spelling(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let defaultLang = checkLang(st.doc, p)
        let ignore = (p.get("ignore")?.asArray ?? []).compactMap(\.asStr).map(rustLowercase)
        let checker = Spell.checker
        var hasDict: [String: Bool] = [:]
        var out: [JSON] = []
        // Each misspelt word of `para`, reported with `at` (where the paragraph is) merged in.
        func check(_ para: Paragraph, _ at: JSON) {
            let repeats = Spell.repeated(para, defaultLang)
            for w in repeats {
                let v: JSON = [
                    "start": .integer(w.start), "end": .integer(w.end), "word": .string(w.text), "lang": .string(w.lang), "repeated": true,
                    "deleteFrom": w.repeated.map { JSON.integer($0) } ?? .null, "suggestions": .array([]),
                ]
                out.append(merged(v, at))
            }
            let rep = repeats.map(\.start)
            for w in Spell.paragraphWords(para, defaultLang) {
                if ignore.contains(where: { rustEqual($0, rustLowercase(w.text)) }) || rep.contains(w.start) { continue }
                let dict: Bool
                if let d = hasDict[w.lang] {
                    dict = d
                } else {
                    dict = checker.hasDictionary(w.lang)
                    hasDict[w.lang] = dict
                }
                let bad = dict ? Spell.isCorrect(checker, w.text, w.lang) == false : common.contains { rustEqual($0, rustLowercase(w.text)) }
                if bad {
                    let sug = dict ? checker.suggestions(w.text, lang: w.lang, limit: 5) : []
                    let v: JSON = [
                        "start": .integer(w.start), "end": .integer(w.end), "word": .string(w.text), "lang": .string(w.lang),
                        "suggestions": .array(sug.map(JSON.string)),
                    ]
                    out.append(merged(v, at))
                }
            }
        }
        for (i, sl) in st.doc.slides.enumerated() {
            walk(sl.shapes) { sh, _ in
                if let t = sh.text {
                    for (pi, para) in t.paragraphs.enumerated() { check(para, ["slide": .integer(i), "shape": sh.id.toJSON(), "para": .integer(pi)]) }
                }
                if case .table(let tb) = sh.kind {
                    for (r, row) in tb.rows.enumerated() {
                        for (c, cell) in row.cells.enumerated() where !cell.isCovered {
                            for (pi, para) in cell.text.paragraphs.enumerated() {
                                check(para, ["slide": .integer(i), "shape": sh.id.toJSON(), "row": .integer(r), "col": .integer(c), "para": .integer(pi)])
                            }
                        }
                    }
                }
            }
            // Speaker notes, a paragraph per line.
            for (pi, para) in sl.notes.paragraphs.enumerated() { check(para, ["slide": .integer(i), "notes": true, "para": .integer(pi)]) }
        }
        return .array(out)
    }

    @Sendable static func addToDictionary(_ s: Session, _ p: JSON) throws -> JSON {
        guard let word = Cmd.strParam(p, "word"), !rustTrim(word).isEmpty else { throw Cmd.bad("review.addToDictionary", "missing `word`") }
        do { try Spell.addUserWord(word) } catch { throw Cmd.bad("review.addToDictionary", error.description) }
        return ["word": .string(String(rustTrim(word))), "file": .opt(Spell.userDictionaryPath())]
    }

    /// Replace whole-word `from` with `to` in `text`; how many were replaced (`replace_word`).
    static func replaceWord(_ text: inout String, _ from: String, _ to: String, _ all: Bool) -> Int {
        func isWord(_ c: Unicode.Scalar) -> Bool { rustIsAlphanumeric(c) || c == "'" || c == "’" }
        var bytes = Array(text.utf8)
        let f = Array(from.utf8)
        let t = Array(to.utf8)
        var n = 0
        var at = 0
        while let i = SpellDictionary.find(bytes, f, at), !f.isEmpty {
            let end = i + f.count
            let before = String(decoding: bytes[..<i], as: UTF8.self).unicodeScalars.last.map(isWord) ?? false
            let after = String(decoding: bytes[end...], as: UTF8.self).unicodeScalars.first.map(isWord) ?? false
            if before || after {
                at = end
                continue
            }
            bytes.replaceSubrange(i ..< end, with: t)
            n += 1
            at = i + t.count
            if !all { break }
        }
        if n > 0 { text = String(decoding: bytes, as: UTF8.self) }
        return n
    }

    /// Replace characters `start..<end` of `p` with `to`, in the run where they start (later runs lose the
    /// rest of the range) (`replace_chars`).
    static func replaceChars(_ p: inout Paragraph, _ start: Int, _ end: Int, _ to: String) {
        var at = 0
        var placed = false
        for i in p.runs.indices {
            let n = p.runs[i].charLen
            let (a, b) = (max(start, at), min(end, at + n))
            if a < b && p.runs[i].kind == .text {
                let sc = Array(p.runs[i].text.unicodeScalars)
                let x = min(a - at, sc.count)
                let y = min(max(b - at, x), sc.count)
                p.runs[i].text = String(String.UnicodeScalarView(sc[..<x])) + (placed ? "" : to) + String(String.UnicodeScalarView(sc[y...]))
                placed = true
            }
            at += n
        }
        p.runs.removeAll { $0.kind == .text && $0.text.isEmpty }
    }

    private static func walkTextMut(_ shapes: inout [Shape], _ depth: Int, _ f: (inout Shape) -> Void) {
        if depth > 64 { return }
        for i in shapes.indices {
            f(&shapes[i])
            if case .group = shapes[i].kind { shapes[i].mutateChildren { walkTextMut(&$0, depth + 1, f) } }
        }
    }

    @Sendable static func spellingChange(_ s: Session, _ p: JSON) throws -> JSON {
        guard let word = Cmd.strParam(p, "word"), !word.isEmpty else { throw Cmd.bad("review.spellingChange", "missing `word`") }
        guard let to = Cmd.strParam(p, "to") else { throw Cmd.bad("review.spellingChange", "missing `to`") }
        let all = Cmd.boolOr(p, "all", false)
        let shape = p.get("shape")?.asU64
        if shape == nil && !all { throw Cmd.bad("review.spellingChange", "give `shape`, or `all: true`") }
        // One exact occurrence (a squiggled word): paragraph `para`, from character `start`.
        if let sid = shape, let para = Cmd.usizeParam(p, "para"), let start = Cmd.usizeParam(p, "start") {
            guard let raw = UInt32(exactly: sid) else { throw Cmd.bad("review.spellingChange", "bad `shape`") }
            let id = ShapeId(raw)
            let (end, o) = start.addingReportingOverflow(word.charCount)
            if o || start == Int.max { throw Cmd.bad("review.spellingChange", "bad `start`") }
            let cell: (Int, Int)? = Cmd.usizeParam(p, "row").flatMap { r in Cmd.usizeParam(p, "col").map { (r, $0) } }
            let st = try s.doc()
            func paraOf(_ sh: Shape) -> Paragraph? {
                if let (r, c) = cell {
                    guard case .table(let tb) = sh.kind else { return nil }
                    return tb.cell(r, c)?.text.paragraphs.at(para)
                }
                return sh.text?.paragraphs.at(para)
            }
            guard let slide = st.doc.slides.firstIndex(where: { sl in
                guard let pp = findShape(sl.shapes, id).flatMap(paraOf) else { return false }
                let sc = Array(pp.text.unicodeScalars)
                let piece = start < sc.count ? sc[start ..< min(end, sc.count)] : []
                return rustEqual(String(String.UnicodeScalarView(piece)), word)
            }) else { throw Cmd.bad("review.spellingChange", "the word isn't there") }
            try s.edit { doc, _ in
                guard doc.slides.indices.contains(slide) else { throw Cmd.bad("review.spellingChange", "no slide") }
                let found: Void? = withShape(&doc.slides[slide].shapes, id) { (sh: inout Shape) -> Void in
                    if let (r, c) = cell {
                        guard case .table(var tb) = sh.kind else { return }
                        tb.mutateCell(r, c) { cl in
                            if cl.text.paragraphs.indices.contains(para) { replaceChars(&cl.text.paragraphs[para], start, end, to) }
                        }
                        sh.kind = .table(tb)
                    } else if var t = sh.text, t.paragraphs.indices.contains(para) {
                        replaceChars(&t.paragraphs[para], start, end, to)
                        sh.text = t
                    }
                }
                if found == nil { throw Cmd.bad("review.spellingChange", "no shape") }
            }
            return ["changed": 1]
        }
        // Nothing to change makes no undo step.
        func matches(_ sh: Shape) -> Bool { shape.map { UInt64(sh.id.rawValue) == $0 } ?? true }
        var any = false
        let st = try s.doc()
        for sl in st.doc.slides {
            walk(sl.shapes) { sh, _ in
                if matches(sh), let t = sh.text {
                    any = any || t.paragraphs.flatMap(\.runs).contains { r in
                        var copy = r.text
                        return replaceWord(&copy, word, to, false) > 0
                    }
                }
            }
        }
        if !any { return ["changed": 0] }
        let changed = try s.edit { doc, _ -> Int in
            var n = 0
            for k in doc.slides.indices {
                var hit = false
                walk(doc.slides[k].shapes) { sh, _ in
                    hit = hit || (matches(sh) && (sh.text.map { $0.text.contains(word) } ?? false))
                }
                if !hit || (!all && n > 0) { continue }
                walkTextMut(&doc.slides[k].shapes, 0) { sh in
                    if !matches(sh) || (!all && n > 0) { return }
                    guard var t = sh.text else { return }
                    outer: for pi in t.paragraphs.indices {
                        for ri in t.paragraphs[pi].runs.indices {
                            if !all && n > 0 { break outer }
                            n += replaceWord(&t.paragraphs[pi].runs[ri].text, word, to, all)
                        }
                    }
                    sh.text = t
                }
            }
            return n
        }
        return ["changed": .integer(changed)]
    }

    @Sendable static func dictionaryInfo(_ s: Session, _ p: JSON) throws -> JSON {
        let lang = s.activeDoc.map { checkLang($0.doc, p) } ?? Cmd.strParam(p, "lang") ?? "en-US"
        let dirs = Spell.searchDirs()
        let found = Spell.findIn(dirs, lang).map { a, _ in a.hasSuffix(".aff") ? String(a.dropLast(4)) : a }
        let available = Spell.checker.hasDictionary(lang)
        return ["lang": .string(lang), "available": .bool(available), "found": .opt(found), "folders": .array(dirs.map(JSON.string))]
    }

    /// The selected text when it lies in one paragraph, else the word at the caret (`word_under_caret`).
    private static func wordUnderCaret(_ s: Session) -> String? {
        guard let st = s.activeDoc, let t = st.selection.text, let body = TextCommands.bodyOf(st, t) else { return nil }
        let (a, b) = t.anchor != t.caret ? (t.ordered.0.tuple, t.ordered.1.tuple) : TextEdit.wordAt(body, t.caret.tuple)
        if a.0 != b.0 { return nil }
        guard let text = body.paragraphs.at(a.0)?.text else { return nil }
        let sc = Array(text.unicodeScalars)
        let lo = min(a.1, sc.count)
        let hi = min(max(b.1, a.1), sc.count)
        let w = String(rustTrim(String(String.UnicodeScalarView(sc[lo ..< max(hi, lo)]))))
        return w.isEmpty ? nil : w
    }

    @Sendable static func thesaurus(_ s: Session, _ p: JSON) throws -> JSON {
        let word = Cmd.strParam(p, "word") ?? wordUnderCaret(s) ?? ""
        return ["word": .string(word), "senses": .array(Thesaurus.lookup(word).map { $0.toJSON() })]
    }

    @Sendable static func insertSynonym(_ s: Session, _ p: JSON) throws -> JSON {
        guard let with = Cmd.strParam(p, "with"), !rustTrim(with).isEmpty else { throw Cmd.bad("review.replaceWord", "missing `with`") }
        if with.charCount > 200 { throw Cmd.bad("review.replaceWord", "too long") }
        let collapsed = try s.doc().selection.text.map { $0.anchor == $0.caret } ?? false
        if collapsed { _ = try s.execute("text.selectWord", .emptyObject) }
        return try s.execute("text.insert", ["text": .string(with)])
    }
}

// MARK: - Compare

extension ReviewCommands {
    @Sendable static func comparing(_ s: Session) -> String? {
        s.activeDoc?.compare != nil ? nil : "not comparing"
    }

    private static func revisedBytes(_ p: JSON) throws -> (String, [UInt8]) {
        if let data = Cmd.strParam(p, "data") {
            guard let bytes = Cmd.base64Decode(data) else { throw Cmd.bad("review.compare", "invalid base64 `data`") }
            return (Cmd.strParam(p, "name") ?? "Revised", bytes)
        }
        if let path = Cmd.strParam(p, "path") { return (path, try IO.readFile(path)) }
        throw Cmd.bad("review.compare", "give `path` or `data`")
    }

    private static func revisionsJSON(_ st: DocState) throws -> JSON {
        guard let c = st.compare else { throw Cmd.bad("review.revisions", "not comparing") }
        let name = RustPath.fileName(c.name) ?? c.name
        return ["name": .string(name), "changes": .array(Comparing.pending(st.doc, c).map { $0.toJSON() }), "byPosition": .bool(c.byPosition)]
    }

    @Sendable static func compare(_ s: Session, _ p: JSON) throws -> JSON {
        let (name, bytes) = try revisedBytes(p)
        let revised = try FileCommands.openPresentation(name, bytes)
        let st = try s.doc()
        let byPosition = Comparing.unrelated(st.doc, revised)
        st.compare = Compare(name: name, revised: DocRef(revised), byPosition: byPosition, rejected: [])
        s.uiRequests.append(.pane(id: "revisions"))
        return try revisionsJSON(s.doc())
    }

    @Sendable static func revisions(_ s: Session, _ p: JSON) throws -> JSON {
        try revisionsJSON(s.doc())
    }

    @Sendable static func accept(_ s: Session, _ p: JSON) throws -> JSON {
        guard let cmp = try s.doc().compare else { throw Cmd.bad("review.accept", "not comparing") }
        let rev = cmp.revised.value
        let all = Cmd.boolParam(p, "all") ?? false
        let index = Cmd.usizeParam(p, "index")
        if !all && index == nil { throw Cmd.bad("review.accept", "give `index` or `all`") }
        return try s.edit { doc, sel -> JSON in
            var accepted = 0
            // Each accept shifts indices, so the list is recomputed; bounded by the slide counts.
            let limit = doc.slides.count + rev.slides.count + 1
            for _ in 0 ..< limit {
                let changes = Comparing.pending(doc, cmp)
                let c: Change?
                if all {
                    let count = doc.slides.count
                    c = changes.first { !($0.kind == .deleted && count <= 1) }
                } else {
                    c = changes.at(index ?? 0)
                }
                guard let c, let at = try Comparing.accept(&doc, rev, c) else { break }
                accepted += 1
                sel.slide = at
                sel.shapes.removeAll()
                sel.text = nil
                if !all { break }
            }
            if accepted == 0 { throw Cmd.bad("review.accept", "no such revision") }
            return ["accepted": .integer(accepted)]
        }
    }

    @Sendable static func reject(_ s: Session, _ p: JSON) throws -> JSON {
        let all = Cmd.boolParam(p, "all") ?? false
        let index = Cmd.usizeParam(p, "index")
        if !all && index == nil { throw Cmd.bad("review.reject", "give `index` or `all`") }
        let st = try s.doc()
        let doc = st.doc
        guard var c = st.compare else { throw Cmd.bad("review.reject", "not comparing") }
        let pending = Comparing.pending(doc, c)
        let picked: [Change] = all ? pending : (pending.at(index ?? 0).map { [$0] } ?? [])
        if picked.isEmpty { throw Cmd.bad("review.reject", "no such revision") }
        for ch in picked { c.rejected.insert(ChangeKey.of(doc, ch)) }
        st.compare = c
        return ["rejected": .integer(picked.count)]
    }

    @Sendable static func endCompare(_ s: Session, _ p: JSON) throws -> JSON {
        try s.doc().compare = nil
        return Cmd.ok()
    }
}

// MARK: - Slide Show

extension ReviewCommands {
    private static func start(_ s: Session, _ from: Int) -> JSON {
        s.uiRequests.append(.startShow(from: from))
        return ["from": .integer(from)]
    }

    @Sendable static func setup(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, _ -> JSON in
            if let t = Cmd.strParam(p, "type") {
                doc.show.showType = t
                if t == "kiosk" { doc.show.loopUntilEsc = true }
            }
            if let v = Cmd.boolParam(p, "loop") { doc.show.loopUntilEsc = v }
            if let v = Cmd.boolParam(p, "noNarration") { doc.show.withoutNarration = v }
            if let v = Cmd.boolParam(p, "noAnimation") { doc.show.withoutAnimation = v }
            if let v = Cmd.boolParam(p, "useTimings") { doc.show.useTimings = v }
            if let v = Cmd.boolParam(p, "showMediaControls") { doc.show.showMediaControls = v }
            func clampU32(_ v: UInt64) -> UInt32 { UInt32(min(v, UInt64(UInt32.max))) }
            switch (p.get("from")?.asU64, p.get("to")?.asU64) {
            case (.some(let a), .some(let b)): doc.show.range = Pair(clampU32(a), clampU32(b))
            case (nil, nil) where p.get("all") != nil: doc.show.range = nil
            default: break
            }
            if p.get("all")?.asBool == true {
                doc.show.range = nil
                doc.show.customShow = nil
            }
            if p.get("custom") != nil {
                let name = p.get("custom")?.asStr ?? ""
                doc.show.customShow = name.isEmpty ? nil : name
                if doc.show.customShow != nil { doc.show.range = nil }
            }
            return doc.show.toJSON()
        }
    }

    @Sendable static func customShow(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("show.customShow", "missing `name`") }
        let delete = Cmd.boolOr(p, "delete", false)
        let idx = (p.get("slides")?.asArray ?? []).compactMap(\.asUsize)
        try s.edit { doc, _ in
            doc.customShows.removeAll { rustEqual($0.name, name) }
            if !delete {
                let slides = idx.compactMap { doc.slides.at($0)?.id }
                doc.customShows.append(CustomShow(name: name, slides: slides))
            }
        }
        return Cmd.ok()
    }
}
