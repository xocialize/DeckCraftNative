// DCAppModel — spelling squiggles: misspelt and repeated words on the current slide (shapes and table
// cells) and in the speaker notes get a red wavy underline; the word the caret is in isn't marked, as in
// PowerPoint. Port of deckcraft `crates/ui-egui/src/squiggles.rs` (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
//
// The checker is the engine's (`Spell`: an installed Hunspell dictionary, else `NSSpellChecker`). deckcraft
// checks on a worker thread, and on the web on the UI thread a few milliseconds per frame; here the second
// path is the only one: the session and the system spell checker live on the main thread, so the canvas
// spends a budget per pass and asks for another pass until the check is done. Results are cached by
// paragraph, so typing re-checks only the paragraph typed in.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation

/// Where a checked paragraph is (`Tag`).
public enum SquiggleTag: Sendable, Hashable {
    case shape(id: ShapeId, para: Int)
    case cell(id: ShapeId, row: Int, col: Int, para: Int)
    /// A line of the notes, starting at character `start` of the notes text.
    case notes(start: Int)
}

/// A flagged word under the pointer, with what its menu offers (`MenuWord`).
public struct SquiggleWord: Sendable, Equatable {
    public var tag: SquiggleTag
    public var start: Int
    public var word: String
    public var suggestions: [String]
    /// A repeated word: Delete Repeated Word removes characters `deleteFrom ..< start + word`.
    public var deleteFrom: Int?
}

public final class CanvasSquiggles {
    /// Milliseconds of checking per pass (`FRAME_BUDGET_MS`).
    public static let budgetMs = 4.0

    /// Proofing languages offered by Review › Language: (name, tag) (`LANGS`).
    public static let languages: [(String, String)] = [
        ("English (United States)", "en-US"), ("English (United Kingdom)", "en-GB"), ("English (Australia)", "en-AU"),
        ("English (Canada)", "en-CA"), ("Español (España)", "es-ES"), ("Español (México)", "es-MX"), ("Français (France)", "fr-FR"),
        ("Français (Canada)", "fr-CA"), ("Deutsch (Deutschland)", "de-DE"), ("Deutsch (Schweiz)", "de-CH"), ("Italiano", "it-IT"),
        ("Nederlands", "nl-NL"), ("Português (Brasil)", "pt-BR"), ("Português (Portugal)", "pt-PT"), ("Polski", "pl-PL"),
        ("Svenska", "sv-SE"), ("Dansk", "da-DK"), ("Norsk bokmål", "nb-NO"), ("Suomi", "fi-FI"), ("Čeština", "cs-CZ"),
        ("Українська", "uk-UA"), ("Русский", "ru-RU"), ("Беларуская", "be-BY"), ("Türkçe", "tr-TR"), ("Ελληνικά", "el-GR"),
        ("日本語", "ja-JP"), ("中文(中国)", "zh-CN"), ("한국어", "ko-KR"), ("العربية", "ar-SA"), ("עברית", "he-IL"),
    ]

    /// The display name of a language tag (the tag itself when it isn't listed) (`lang_name`).
    public static func languageName(_ tag: String) -> String {
        languages.first { $0.1.lowercased() == tag.lowercased() }?.0 ?? tag
    }

    enum Kind { case slide, notes }

    /// What a check is for: the text's identity and the user dictionary's version (`Key`).
    struct Key: Equatable {
        var of: Int
        var user: UInt64
    }

    struct Job {
        var kind: Kind
        var key: Key
        var defaultLang: String
        var paras: [(SquiggleTag, Paragraph)]
        var at = 0
        var found: [(SquiggleTag, Int, Int)] = []
    }

    /// Misspelt character ranges per paragraph content (`Checker.cache`).
    private var cache: [Int: [(Int, Int)]] = [:]
    private var cacheUser: UInt64?
    private var jobs: [Job] = []
    private var done: [Kind: (Key, [(SquiggleTag, Int, Int)])] = [:]
    /// Underlines in slide points for the slide's result, and the key they were laid out for.
    private var lines: [((SquiggleTag, Int, Int), Point, Point)] = []
    private var linesFor: Key?
    /// Words skipped with Ignore All this session (lower-case).
    private var ignored: [String] = []

    /// Off (tests or the setting).
    public var disabled = false
    /// The flagged word a context menu is open on.
    public var menuWord: SquiggleWord?

    public init() {}

    /// Work is waiting: the host should give another pass.
    public var busy: Bool { !jobs.isEmpty }

    private static func hash(_ p: Paragraph, _ lang: String) -> Int {
        var h = Hasher()
        h.combine(lang)
        for r in p.runs {
            h.combine(r.content)
            h.combine(r.props.lang)
            h.combine(r.props.noProof)
        }
        return h.finalize()
    }

    private func push(_ job: Job) {
        jobs.removeAll { $0.kind == job.kind }
        jobs.append(job)
    }

    /// Check until `budgetMs` is spent or everything is done (`Checker::step`).
    private func step(_ budgetMs: Double) {
        let t0 = Date()
        while var job = jobs.first {
            if cacheUser != job.key.user {
                cache.removeAll()
                cacheUser = job.key.user
            }
            while job.at < job.paras.count {
                let (tag, p) = job.paras[job.at]
                let k = Self.hash(p, job.defaultLang)
                let r: [(Int, Int)]
                if let c = cache[k] {
                    r = c
                } else {
                    r = Spell.misspelt(p, job.defaultLang, []).map { ($0.start, $0.end) }
                    cache[k] = r
                }
                job.found += r.map { (tag, $0.0, $0.1) }
                job.at += 1
                if Date().timeIntervalSince(t0) * 1000 > budgetMs {
                    jobs[0] = job
                    return
                }
            }
            jobs.removeFirst()
            done[job.kind] = (job.key, job.found)
        }
        if cache.count > 20000 { cache.removeAll() }
    }

    private func ask(_ kind: Kind, _ key: Key, _ lang: String, _ paras: () -> [(SquiggleTag, Paragraph)]) {
        if let d = done[kind], d.0 == key { return }
        if jobs.contains(where: { $0.kind == kind && $0.key == key }) { return }
        push(Job(kind: kind, key: key, defaultLang: lang, paras: paras()))
    }

    private func isIgnored(_ word: String) -> Bool { !ignored.isEmpty && ignored.contains(word.lowercased()) }

    /// The presentation's language: the first run's that names one, else US English (`default_lang`).
    public static func defaultLanguage(_ st: DocState) -> String {
        for sl in st.doc.slides {
            var found: String?
            walk(sl.shapes) { sh, _ in
                if found == nil, let t = sh.text {
                    found = t.paragraphs.lazy.flatMap(\.runs).compactMap(\.props.lang).first
                }
            }
            if let l = found { return l }
        }
        return "en-US"
    }

    /// Ask for a check of the current slide if it changed, spend this pass's budget, and return the
    /// underlines to draw, in slide points (`update`).
    public func update(_ st: DocState, budgetMs: Double = CanvasSquiggles.budgetMs) -> [(Point, Point)] {
        if disabled { return [] }
        var h = Hasher()
        h.combine(ObjectIdentifier(st.docRef))
        h.combine(st.revision)
        h.combine(st.selection.slide)
        let key = Key(of: h.finalize(), user: Spell.userGeneration())
        ask(.slide, key, Self.defaultLanguage(st)) {
            var paras: [(SquiggleTag, Paragraph)] = []
            guard let sl = st.doc.slides.at(st.selection.slide) else { return paras }
            walk(sl.shapes) { sh, _ in
                if let t = sh.text {
                    for (i, p) in t.paragraphs.enumerated() { paras.append((.shape(id: sh.id, para: i), p)) }
                }
                if case .table(let tb) = sh.kind {
                    for (r, row) in tb.rows.enumerated() {
                        for (c, cell) in row.cells.enumerated() where !cell.isCovered {
                            for (i, p) in cell.text.paragraphs.enumerated() { paras.append((.cell(id: sh.id, row: r, col: c, para: i), p)) }
                        }
                    }
                }
            }
            return paras
        }
        step(budgetMs)
        guard let d = done[.slide], d.0 == key else { return [] }
        if linesFor != key {
            lines.removeAll()
            for (tag, a, b) in d.1 {
                let under: [(Point, Point)] = switch tag {
                case .shape(let id, let para): TextCommands.rangeUnderlines(st, id, [(para, a, b)])
                case .cell(let id, let row, let col, let para): TextCommands.cellRangeUnderlines(st, id, row, col, [(para, a, b)])
                case .notes: []
                }
                lines += under.map { ((tag, a, b), $0.0, $0.1) }
            }
            linesFor = key
        }
        // Not under the word the caret is in.
        let typing = st.selection.text.flatMap { $0.notes ? nil : $0 }
        func underCaret(_ tag: SquiggleTag, _ a: Int, _ b: Int) -> Bool {
            guard let t = typing else { return false }
            let here: Bool = switch tag {
            case .shape(let id, let para): t.cell == nil && id == t.shape && para == t.caret.para
            case .cell(let id, let row, let col, let para): t.cell == TextPoint(row, col) && id == t.shape && para == t.caret.para
            case .notes: false
            }
            return here && t.caret.char >= a && t.caret.char <= b
        }
        return lines.filter { m, _, _ in
            !underCaret(m.0, m.1, m.2) && (ignored.isEmpty || !(Self.wordOf(st, m.0, m.1, m.2).map(isIgnored) ?? false))
        }.map { ($0.1, $0.2) }
    }

    /// The misspelt character ranges of notes text being shown (`caret`'s word isn't marked); empty until
    /// the check is in (`notes`).
    public func notes(_ text: String, lang: String, caret: Int?, budgetMs: Double = CanvasSquiggles.budgetMs) -> [(Int, Int)] {
        if disabled { return [] }
        var h = Hasher()
        h.combine(text)
        h.combine(lang)
        let key = Key(of: h.finalize(), user: Spell.userGeneration())
        ask(.notes, key, lang) {
            var out: [(SquiggleTag, Paragraph)] = []
            var start = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append((.notes(start: start), Paragraph(String(line))))
                start += line.unicodeScalars.count + 1
            }
            return out
        }
        step(budgetMs)
        guard let d = done[.notes], d.0 == key else { return [] }
        let chars = Array(text.unicodeScalars)
        return d.1.compactMap { tag, a, b -> (Int, Int)? in
            guard case .notes(let start) = tag else { return nil }
            return (start + a, start + b)
        }.filter { a, b in
            !(caret.map { $0 >= a && $0 <= b } ?? false)
                && (ignored.isEmpty || !isIgnored(a <= b && b <= chars.count ? String(String.UnicodeScalarView(chars[a ..< b])) : ""))
        }
    }

    /// Skip `word` everywhere for the rest of the session (Ignore All).
    public func ignore(_ word: String) { ignored.append(word.lowercased()) }

    /// The flagged word at slide point `p`, within `tol` points of its underline (`word_at`): from about a
    /// line above the underline to just below it.
    public func wordAt(_ st: DocState, _ p: Point, _ tol: Double) -> SquiggleWord? {
        guard let hit = lines.first(where: { _, a, b in
            p.x >= min(a.x, b.x) - tol && p.x <= max(a.x, b.x) + tol && p.y <= max(a.y, b.y) + tol && p.y >= min(a.y, b.y) - 24
        }) else { return nil }
        guard let para = Self.paragraphOf(st, hit.0.0) else { return nil }
        return Self.menuWord(para, Self.defaultLanguage(st), hit.0.0, hit.0.1)
    }

    /// The flagged word of `p` starting at `start`, with what its menu offers (`menu_word`).
    public static func menuWord(_ p: Paragraph, _ lang: String, _ tag: SquiggleTag, _ start: Int) -> SquiggleWord? {
        guard let w = Spell.misspelt(p, lang, []).first(where: { $0.start == start }) else { return nil }
        let suggestions = w.repeated != nil ? [] : Spell.checker.suggestions(w.text, lang: w.lang, limit: 5)
        return SquiggleWord(tag: tag, start: start, word: w.text, suggestions: suggestions, deleteFrom: w.repeated)
    }

    /// Check (tests) until the slide's check for `st` is in.
    public func settle(_ st: DocState) -> [(Point, Point)] {
        var v = update(st)
        var n = 0
        while busy && n < 10000 {
            v = update(st, budgetMs: 50)
            n += 1
        }
        return v
    }

    static func paragraphOf(_ st: DocState, _ tag: SquiggleTag) -> Paragraph? {
        guard let sl = st.doc.slides.at(st.selection.slide) else { return nil }
        switch tag {
        case .shape(let id, let para): return findShape(sl.shapes, id)?.text?.paragraphs.at(para)
        case .cell(let id, let row, let col, let para):
            guard case .table(let tb)? = findShape(sl.shapes, id)?.kind else { return nil }
            return tb.cell(row, col)?.text.paragraphs.at(para)
        case .notes: return nil
        }
    }

    static func wordOf(_ st: DocState, _ tag: SquiggleTag, _ a: Int, _ b: Int) -> String? {
        guard let p = paragraphOf(st, tag) else { return nil }
        let chars = Array(p.text.unicodeScalars)
        guard a >= 0, a <= b, b <= chars.count else { return nil }
        return String(String.UnicodeScalarView(chars[a ..< b]))
    }

    /// The parameters of `review.spellingChange` replacing flagged word `w` with `to` (the suggestion
    /// arm of `context_menu`); nil for notes words.
    public static func changeParams(_ w: SquiggleWord, to: String) -> JSON? {
        switch w.tag {
        case .shape(let id, let para):
            ["shape": id.toJSON(), "para": .integer(para), "start": .integer(w.start), "word": .string(w.word), "to": .string(to)]
        case .cell(let id, let row, let col, let para):
            ["shape": id.toJSON(), "row": .integer(row), "col": .integer(col), "para": .integer(para), "start": .integer(w.start),
             "word": .string(w.word), "to": .string(to)]
        case .notes: nil
        }
    }

    /// The parameters of `review.spellingChange` for Delete Repeated Word: the gap and the word, taken from
    /// the text so tabs or no-break spaces match. nil when the word isn't repeated.
    public static func deleteRepeatedParams(_ st: DocState, _ w: SquiggleWord) -> JSON? {
        guard let from = w.deleteFrom else { return nil }
        let end = w.start + w.word.unicodeScalars.count
        let gap = paragraphOf(st, w.tag).flatMap { p -> String? in
            let chars = Array(p.text.unicodeScalars)
            guard from >= 0, from <= end, end <= chars.count else { return nil }
            return String(String.UnicodeScalarView(chars[from ..< end]))
        } ?? String(repeating: " ", count: max(w.start - from, 0)) + w.word
        switch w.tag {
        case .shape(let id, let para):
            return ["shape": id.toJSON(), "para": .integer(para), "start": .integer(from), "word": .string(gap), "to": ""]
        case .cell(let id, let row, let col, let para):
            return ["shape": id.toJSON(), "row": .integer(row), "col": .integer(col), "para": .integer(para), "start": .integer(from),
                    "word": .string(gap), "to": ""]
        case .notes:
            return ["para": 0, "start": .integer(from), "word": .string(gap), "to": ""]
        }
    }
}
