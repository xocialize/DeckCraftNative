// DCEngine — spell checking for Review › Spelling.
//
// deckcraft checks spelling with Hunspell-format dictionaries (`xx_YY.aff` + `xx_YY.dic`) it finds in the
// folders the system's own spell checkers use; it ships none. This port keeps that checker, as deckcraft's
// own logic (a subset of Hunspell: `SET`, `FLAG`, `PFX`/`SFX` with strip, conditions and cross products,
// one level of continuation flags, `NEEDAFFIX`, `FORBIDDENWORD`, `NOSUGGEST`, `KEEPCASE`, `TRY`, `REP`,
// `WORDCHARS` and simple compounding), and puts it behind `SpellChecking`, so the Mac's own spell checker
// (`NSSpellChecker`, AppKit) can answer for the languages no Hunspell dictionary is installed for. The
// engine itself stays free of AppKit: the system checker is compiled only where AppKit exists.
//
// Port of deckcraft crates/engine/src/spell.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel
import Foundation
import Synchronization

#if canImport(AppKit)
import AppKit
#endif

// MARK: - The checker protocol

/// A spelling checker for one or more languages.
public protocol SpellChecking: Sendable {
    /// Is `word` spelt correctly in `lang` (a BCP-47 tag such as `en-US`)? nil when this checker has no
    /// dictionary for the language.
    func isCorrect(_ word: String, lang: String) -> Bool?
    /// Up to `limit` corrections for a misspelt `word`, best first (empty without a dictionary).
    func suggestions(_ word: String, lang: String, limit: Int) -> [String]
    /// Whether this checker has a dictionary for `lang`.
    func hasDictionary(_ lang: String) -> Bool
}

/// deckcraft's checker: the Hunspell dictionaries installed in `Spell.searchDirs()` (and the ones `install`
/// put in). Deterministic: it gives deckcraft's answers for the same dictionaries.
public struct HunspellSpelling: SpellChecking {
    public init() {}

    public func isCorrect(_ word: String, lang: String) -> Bool? { Spell.dictionary(lang).map { $0.check(word) } }

    public func suggestions(_ word: String, lang: String, limit: Int) -> [String] {
        Spell.dictionary(lang)?.suggest(word, limit) ?? []
    }

    public func hasDictionary(_ lang: String) -> Bool { Spell.dictionary(lang) != nil }
}

/// The first checker that has a dictionary for the language answers.
public struct ChainedSpelling: SpellChecking {
    public var checkers: [any SpellChecking]

    public init(_ checkers: [any SpellChecking]) { self.checkers = checkers }

    public func isCorrect(_ word: String, lang: String) -> Bool? {
        for c in checkers { if let r = c.isCorrect(word, lang: lang) { return r } }
        return nil
    }

    public func suggestions(_ word: String, lang: String, limit: Int) -> [String] {
        checkers.first { $0.hasDictionary(lang) }?.suggestions(word, lang: lang, limit: limit) ?? []
    }

    public func hasDictionary(_ lang: String) -> Bool { checkers.contains { $0.hasDictionary(lang) } }
}

#if canImport(AppKit)
/// The Mac's spell checker (`NSSpellChecker`), for the languages it has (`en`, `en_GB`, `de`…).
public struct SystemSpelling: SpellChecking {
    public init() {}

    /// The checker's name for `lang`: the exact locale (`en_GB`), else the language (`en`); nil when it
    /// has neither.
    func language(_ lang: String) -> String? {
        guard Spell.validLang(lang) else { return nil }
        let (full, base) = Spell.names(lang)
        let available = Set(NSSpellChecker.shared.availableLanguages)
        if available.contains(full) { return full }
        if available.contains(base) { return base }
        return nil
    }

    public func isCorrect(_ word: String, lang: String) -> Bool? {
        guard let l = language(lang) else { return nil }
        let r = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: l, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    public func suggestions(_ word: String, lang: String, limit: Int) -> [String] {
        guard let l = language(lang), word.charCount <= Spell.maxSuggestChars else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let g = NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: l, inSpellDocumentWithTag: 0) ?? []
        return Array(g.prefix(limit))
    }

    public func hasDictionary(_ lang: String) -> Bool { language(lang) != nil }
}
#endif

// MARK: - Hunspell dictionaries

/// A loaded Hunspell dictionary (`Dictionary`).
public struct SpellDictionary: Sendable {
    typealias Flag = UInt32

    enum FlagMode { case char, long, num }

    enum Cond: Sendable {
        case any
        case equals(Unicode.Scalar)
        case among([Unicode.Scalar], Bool)

        func matches(_ c: Unicode.Scalar) -> Bool {
            switch self {
            case .any: true
            case .equals(let x): x == c
            case .among(let set, let neg): set.contains(c) != neg
            }
        }
    }

    struct Affix: Sendable {
        var flag: Flag
        var cross: Bool
        var strip: String
        var add: String
        var cond: [Cond]
        var cont: [Flag]

        /// Prefix: does `root` start with the condition? Suffix: does it end with it?
        func condOK(_ root: [Unicode.Scalar], _ prefix: Bool) -> Bool {
            if cond.count > root.count { return false }
            if prefix { return zip(cond, root).allSatisfy { $0.matches($1) } }
            return zip(cond.reversed(), root.reversed()).allSatisfy { $0.matches($1) }
        }
    }

    var words: [String: [[Flag]]] = [:]
    var pfx: [Affix] = []
    var sfx: [Affix] = []
    var tryChars: [Unicode.Scalar] = []
    var rep: [(String, String)] = []
    /// Characters that belong inside words besides letters and digits (the `WORDCHARS` list).
    public private(set) var wordChars: [Unicode.Scalar] = []
    var forbidden: Flag?
    var needAffix: Flag?
    var noSuggest: Flag?
    var keepCase: Flag?
    var onlyInCompound: Flag?
    var compound: Flag?
    var compoundBegin: Flag?
    var compoundMiddle: Flag?
    var compoundEnd: Flag?
    var compoundMin = 3
    var compoundMax = 0

    public init() {}

    static func parseCond(_ s: String) -> [Cond] {
        var out: [Cond] = []
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c {
            case ".": out.append(.any)
            case "[":
                var set: [Unicode.Scalar] = []
                var neg = false
                var i = 0
                while let d = it.next() {
                    if d == "]" { break }
                    if i == 0 && d == "^" { neg = true } else { set.append(d) }
                    i += 1
                }
                out.append(.among(set, neg))
            default: out.append(.equals(c))
            }
        }
        return out
    }

    static func decode(_ bytes: [UInt8], _ latin1: Bool) -> String {
        if latin1 { return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parseFlags(_ s: String, _ mode: FlagMode) -> [Flag] {
        switch mode {
        case .char:
            return s.unicodeScalars.map(\.value)
        case .long:
            let c = Array(s.unicodeScalars)
            return stride(from: 0, to: c.count, by: 2).map { i in
                c[i ..< min(i + 2, c.count)].reduce(UInt32(0)) { $0 &* 0x11_0000 &+ $1.value }
            }
        case .num:
            return s.split(separator: ",", omittingEmptySubsequences: false).compactMap { parseUInt(String(rustTrim(String($0)))).flatMap { UInt32(exactly: $0) } }
        }
    }

    static func oneFlag(_ s: String?, _ mode: FlagMode) -> Flag? { s.flatMap { parseFlags($0, mode).first } }

    /// Rust's `str::parse::<u64>()`: an optional `+`, then ASCII digits only.
    static func parseUInt(_ s: String) -> UInt64? {
        var b = Array(s.utf8)
        if b.first == UInt8(ascii: "+") { b.removeFirst() }
        if b.isEmpty || !b.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return nil }
        var v: UInt64 = 0
        for d in b {
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(UInt64(d - 0x30))
            if o1 || o2 { return nil }
            v = a
        }
        return v
    }

    static func parseUsize(_ s: String) -> Int? { parseUInt(s).flatMap { Int(exactly: $0) } }

    /// Rust's `split_whitespace`.
    static func fields(_ l: String) -> [String] {
        l.unicodeScalars.split(whereSeparator: \.properties.isWhitespace).map { String(String.UnicodeScalarView($0)) }
    }

    /// Parse a dictionary from the bytes of its `.aff` and `.dic` files (`Dictionary::parse`).
    public static func parse(_ affBytes: [UInt8], _ dicBytes: [UInt8]) -> SpellDictionary {
        let head = String(decoding: affBytes, as: UTF8.self)
        let latin1 = rustLines(head).contains { l in
            let w = fields(l)
            guard w.first == "SET", let e = w.at(1) else { return false }
            return rustASCIIUppercase(e).replacingOccurrences(of: "-", with: "").hasPrefix("ISO8859")
        }
        let aff = decode(affBytes, latin1)
        let mode: FlagMode = rustLines(aff).lazy.compactMap { l -> FlagMode? in
            let w = fields(l)
            guard w.first == "FLAG" else { return nil }
            switch w.at(1) {
            case "long": return .long
            case "num": return .num
            default: return .char
            }
        }.first ?? .char
        var d = SpellDictionary()
        d.compoundMin = 3
        let lines = rustLines(aff).map { l in String(l.unicodeScalars.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map { String(String.UnicodeScalarView($0)) } ?? "") }
        var k = 0
        func next() -> String {
            defer { k += 1 }
            return lines.at(k) ?? ""
        }
        while k < lines.count {
            let w = fields(next())
            guard let key = w.first else { continue }
            switch (key, w.count) {
            case ("TRY", 2...): d.tryChars = Array(w[1].unicodeScalars)
            case ("WORDCHARS", 2...): d.wordChars = Array(w[1].unicodeScalars)
            case ("FORBIDDENWORD", 2...): d.forbidden = oneFlag(w[1], mode)
            case ("NEEDAFFIX", 2...), ("PSEUDOROOT", 2...): d.needAffix = oneFlag(w[1], mode)
            case ("NOSUGGEST", 2...): d.noSuggest = oneFlag(w[1], mode)
            case ("KEEPCASE", 2...): d.keepCase = oneFlag(w[1], mode)
            case ("ONLYINCOMPOUND", 2...): d.onlyInCompound = oneFlag(w[1], mode)
            case ("COMPOUNDFLAG", 2...): d.compound = oneFlag(w[1], mode)
            case ("COMPOUNDBEGIN", 2...): d.compoundBegin = oneFlag(w[1], mode)
            case ("COMPOUNDMIDDLE", 2...): d.compoundMiddle = oneFlag(w[1], mode)
            case ("COMPOUNDEND", 2...), ("COMPOUNDLAST", 2...): d.compoundEnd = oneFlag(w[1], mode)
            case ("COMPOUNDMIN", 2...): d.compoundMin = max(parseUsize(w[1]) ?? 3, 1)
            case ("COMPOUNDWORDMAX", 2...): d.compoundMax = parseUsize(w[1]) ?? 0
            case ("REP", 2):
                for _ in 0 ..< (parseUsize(w[1]) ?? 0) {
                    if k >= lines.count { break }
                    let r = fields(next())
                    if r.count >= 3 { d.rep.append((r[1].replacingOccurrences(of: "_", with: " "), r[2].replacingOccurrences(of: "_", with: " "))) }
                }
            case ("PFX", 4), ("SFX", 4):
                guard let n = parseUsize(w[3]) else { break }
                let prefix = key == "PFX"
                guard let flag = oneFlag(w[1], mode) else { break }
                let cross = rustASCIILowercase(w[2]) == "y"
                for _ in 0 ..< n {
                    if k >= lines.count { break }
                    let r = fields(next())
                    guard r.count >= 4 else { continue }
                    let (strip, addField) = (r[2], r[3])
                    var add = addField
                    var cont: [Flag] = []
                    if let slash = addField.unicodeScalars.firstIndex(of: "/") {
                        add = String(addField.unicodeScalars[..<slash])
                        cont = parseFlags(String(addField.unicodeScalars[addField.unicodeScalars.index(after: slash)...]), mode)
                    }
                    let a = Affix(
                        flag: flag, cross: cross, strip: strip == "0" ? "" : strip, add: add == "0" ? "" : add,
                        cond: parseCond(r.at(4) ?? "."), cont: cont
                    )
                    if prefix { d.pfx.append(a) } else { d.sfx.append(a) }
                }
            default: break
            }
        }
        let dic = decode(dicBytes, latin1)
        for (i, l) in rustLines(dic).enumerated() {
            if i == 0, parseUsize(String(rustTrim(l))) != nil { continue }
            let first = l.unicodeScalars.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map { String(String.UnicodeScalarView($0)) } ?? ""
            let trimmed = String(rustTrimEnd(Substring(first)))
            // Morphological fields follow a space (`word/flags po:noun`).
            let entry = trimmed.unicodeScalars.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map { String(String.UnicodeScalarView($0)) } ?? ""
            if entry.isEmpty { continue }
            var word = entry
            var flags: [Flag] = []
            if let slash = entry.unicodeScalars.firstIndex(of: "/"), slash != entry.unicodeScalars.startIndex {
                word = String(entry.unicodeScalars[..<slash])
                flags = parseFlags(String(entry.unicodeScalars[entry.unicodeScalars.index(after: slash)...]), mode)
            }
            d.words[word, default: []].append(flags)
        }
        return d
    }

    /// Add `word` (no flags), as a user's own dictionary entry.
    public mutating func addWord(_ word: String) { words[word, default: []].append([]) }

    func has(_ flags: [Flag], _ f: Flag?) -> Bool { f.map { flags.contains($0) } ?? false }

    /// `word` as a root carrying all of `need` (and not forbidden).
    func root(_ word: String, _ need: [Flag], _ affixed: Bool) -> Bool {
        words[word]?.contains { f in
            !has(f, forbidden) && (affixed || !has(f, needAffix)) && !has(f, onlyInCompound) && need.allSatisfy { f.contains($0) }
        } ?? false
    }

    func forbiddenWord(_ word: String) -> Bool { words[word]?.contains { has($0, forbidden) } ?? false }

    static func str(_ v: [Unicode.Scalar]) -> String { String(String.UnicodeScalarView(v)) }
    static func str(_ v: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(v)) }

    /// Strip suffixes from `w` (one, or two through continuation flags).
    func suffixed(_ w: [Unicode.Scalar], _ extra: [Flag], _ cross: Bool) -> Bool {
        for s in sfx {
            if cross && !s.cross { continue }
            guard let stem = Self.stripEnd(w, s.add, s.strip), s.condOK(stem, false) else { continue }
            if root(Self.str(stem), extra + [s.flag], true) { return true }
            // A second suffix whose continuation allows this one (`walk/A` + `ing/B`…).
            for s2 in sfx {
                if !s.cont.isEmpty || !s2.cont.contains(s.flag) { continue }
                guard let stem2 = Self.stripEnd(stem, s2.add, s2.strip) else { continue }
                if s2.condOK(stem2, false) && root(Self.str(stem2), extra + [s2.flag], true) { return true }
            }
        }
        return false
    }

    /// A root (or, for the last part, a suffixed root) carrying `flag`, as a compound part.
    func compoundPart(_ part: [Unicode.Scalar], _ flag: Flag, _ last: Bool) -> Bool {
        let ok = words[Self.str(part)]?.contains { !has($0, forbidden) && $0.contains(flag) } ?? false
        return ok || (last && suffixedCompoundEnd(part, flag))
    }

    func suffixedCompoundEnd(_ w: [Unicode.Scalar], _ flag: Flag) -> Bool {
        sfx.contains { s in
            guard let stem = Self.stripEnd(w, s.add, s.strip) else { return false }
            return s.condOK(stem, false) && (words[Self.str(stem)]?.contains { !has($0, forbidden) && $0.contains(flag) && $0.contains(s.flag) } ?? false)
        }
    }

    /// `w` made of dictionary parts allowed in compounds, each at least `COMPOUNDMIN` characters long.
    func compounded(_ w: [Unicode.Scalar], _ index: Int) -> Bool {
        if compound == nil && compoundEnd == nil { return false }
        let lo = max(compoundMin, 1)
        if index >= 8 || (compoundMax > 0 && index + 1 >= compoundMax) || w.count < 2 * lo { return false }
        let role = index == 0 ? compoundBegin : compoundMiddle
        for i in lo ... (w.count - lo) {
            let head = Array(w[..<i])
            let rest = Array(w[i...])
            let headOK = [compound, role].compactMap { $0 }.contains { compoundPart(head, $0, false) }
            if !headOK { continue }
            if [compound, compoundEnd].compactMap({ $0 }).contains(where: { compoundPart(rest, $0, true) }) { return true }
            if compounded(rest, index + 1) { return true }
        }
        return false
    }

    func checkExact(_ word: String) -> Bool {
        if forbiddenWord(word) { return false }
        if root(word, [], false) { return true }
        let w = Array(word.unicodeScalars)
        if suffixed(w, [], false) { return true }
        for p in pfx {
            guard let stem = Self.stripStart(w, p.add, p.strip), p.condOK(stem, true) else { continue }
            if root(Self.str(stem), [p.flag], true) { return true }
            if p.cross && suffixed(stem, [p.flag], true) { return true }
        }
        return compounded(w, 0)
    }

    /// Is `word` spelt correctly? Capitalised and upper-case forms of a lower-case word pass.
    public func check(_ word: String) -> Bool {
        if word.unicodeScalars.contains("\u{2019}") {
            return check(String(String.UnicodeScalarView(word.unicodeScalars.map { $0 == "\u{2019}" ? "'" : $0 })))
        }
        if word.isEmpty || word.unicodeScalars.allSatisfy({ !rustIsAlphabetic($0) }) { return true }
        if checkExact(word) { return true }
        let lower = rustLowercase(word)
        let tail = word.unicodeScalars.dropFirst()
        let upperTail = tail.allSatisfy { !$0.properties.isLowercase }
        let capOnly = (word.unicodeScalars.first?.properties.isUppercase ?? false) && tail.allSatisfy { !$0.properties.isUppercase }
        func keep(_ w: String) -> Bool { words[w]?.contains { has($0, keepCase) } ?? false }
        if (capOnly || upperTail) && !keep(lower) && checkExact(lower) { return true }
        if upperTail && !capOnly {
            let cap = Self.capitalise(lower)
            if !keep(cap) && checkExact(cap) { return true }
        }
        return false
    }

    func suggestible(_ w: String) -> Bool {
        check(w) && !(words[w].map { hs in hs.allSatisfy { has($0, noSuggest) && !$0.isEmpty } } ?? false)
    }

    /// Up to `n` corrections for a misspelt `word`, best first.
    public func suggest(_ word: String, _ n: Int) -> [String] {
        // Edit-distance candidates grow with the word: nothing is suggested for a run-on token.
        if word.charCount > Spell.maxSuggestChars { return [] }
        let first = word.unicodeScalars.first
        let cap = first?.properties.isUppercase ?? false
        let lower = cap && word.unicodeScalars.dropFirst().allSatisfy({ !$0.properties.isUppercase }) ? rustLowercase(word) : word
        let w = Array(lower.unicodeScalars)
        var out: [String] = []
        var seen = Set<[UInt8]>()
        func push(_ s: String) {
            if !rustEqual(s, lower) && seen.insert(Array(rustLowercase(s).utf8)).inserted
                && s.split(separator: " ", omittingEmptySubsequences: false).allSatisfy({ suggestible(String($0)) }) {
                out.append(s)
            }
        }
        let lb = Array(lower.utf8)
        func isBoundary(_ i: Int) -> Bool { i == lb.count || (i < lb.count && (lb[i] & 0xC0) != 0x80) }
        for (a, b) in rep {
            let ab = Array(a.utf8)
            var from = 0
            while from <= lb.count && isBoundary(from) {
                guard let i = Self.find(lb, ab, from) else { break }
                push(String(decoding: lb[..<i], as: UTF8.self) + b + String(decoding: lb[(i + ab.count)...], as: UTF8.self))
                from = i + max(ab.count, 1)
            }
        }
        let tryChars: [Unicode.Scalar] = self.tryChars.isEmpty ? Array("esianrtolcdugmphbyfvkwzxjq".unicodeScalars) : self.tryChars
        if w.count >= 2 {
            for i in 0 ..< (w.count - 1) {
                var v = w
                v.swapAt(i, i + 1)
                push(Self.str(v))
            }
        }
        for i in w.indices {
            var v = w
            v.remove(at: i)
            push(Self.str(v))
        }
        for i in w.indices {
            for c in tryChars where c != w[i] {
                var v = w
                v[i] = c
                push(Self.str(v))
            }
        }
        for i in 0 ... w.count {
            for c in tryChars {
                var v = w
                v.insert(c, at: i)
                push(Self.str(v))
            }
        }
        if w.count > 1 {
            for i in 1 ..< w.count { push("\(Self.str(w[..<i])) \(Self.str(w[i...]))") }
        }
        out = Array(out.prefix(max(n, 0)))
        if cap { out = out.map(Self.capitalise) }
        return out
    }

    static func find(_ hay: [UInt8], _ needle: [UInt8], _ from: Int) -> Int? {
        if needle.isEmpty { return from <= hay.count ? from : nil }
        if hay.count < needle.count { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i ..< i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    static func capitalise(_ s: String) -> String {
        guard let f = s.unicodeScalars.first else { return "" }
        return f.properties.uppercaseMapping + String(String.UnicodeScalarView(s.unicodeScalars.dropFirst()))
    }

    static func stripEnd(_ w: [Unicode.Scalar], _ add: String, _ strip: String) -> [Unicode.Scalar]? {
        let a = Array(add.unicodeScalars)
        if (w.count <= a.count && strip.isEmpty) || !w.reversed().starts(with: a.reversed()) { return nil }
        guard w.count >= a.count else { return nil }
        let v = Array(w[..<(w.count - a.count)]) + Array(strip.unicodeScalars)
        return v.isEmpty ? nil : v
    }

    static func stripStart(_ w: [Unicode.Scalar], _ add: String, _ strip: String) -> [Unicode.Scalar]? {
        let a = Array(add.unicodeScalars)
        if (w.count <= a.count && strip.isEmpty) || !w.starts(with: a) { return nil }
        guard w.count >= a.count else { return nil }
        let v = Array(strip.unicodeScalars) + Array(w[a.count...])
        return v.isEmpty ? nil : v
    }
}

/// Rust's `to_ascii_uppercase`.
private func rustASCIIUppercase(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { ("a" ... "z").contains($0) ? Unicode.Scalar($0.value - 32) ?? $0 : $0 }))
}

// MARK: - Finding dictionaries, the user dictionary, the words of a paragraph

public enum Spell {
    /// Longest word `suggest` generates corrections for.
    static let maxSuggestChars = 64

    /// The checker Review › Spelling uses: deckcraft's Hunspell dictionaries first (installed ones, or ones
    /// `install` put in), then the system's spell checker where there is one. Task-local, so a test can
    /// run with only the Hunspell checker (`Spell.$checker.withValue(HunspellSpelling()) { … }`).
    @TaskLocal public static var checker: any SpellChecking = defaultChecker

    public static let defaultChecker: any SpellChecking = {
        #if canImport(AppKit)
        ChainedSpelling([HunspellSpelling(), SystemSpelling()])
        #else
        HunspellSpelling()
        #endif
    }()

    /// The folders searched for dictionaries, in order (`search_dirs`).
    public static func searchDirs() -> [String] {
        var out: [String] = []
        let env = ProcessInfo.processInfo.environment
        if let v = env["DECKCRAFT_DICTIONARIES"] {
            out += v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        }
        if let h = env["HOME"] {
            out.append(h + "/Library/Application Support/DeckCraft/Dictionaries")
            out.append(h + "/Library/Spelling")
        }
        out.append("/Library/Spelling")
        return out
    }

    /// `en-US` → `en_US`; the language alone (`en`) as a fallback.
    static func names(_ lang: String) -> (String, String) {
        let full = lang.replacingOccurrences(of: "-", with: "_")
        let base = rustLowercase(String(full.split(separator: "_", omittingEmptySubsequences: false).first ?? ""))
        return (full, base)
    }

    /// A language tag as dictionaries are named: 1–16 ASCII letters, digits, `-` or `_`.
    static func validLang(_ lang: String) -> Bool {
        (1 ... 16).contains(lang.utf8.count) && lang.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    private static func isFile(_ path: String) -> Bool { IO.isOwnFile(path) }

    /// The `.aff`/`.dic` pair for `lang` in `dirs`: the exact locale first, then any of its language
    /// (`find_in`).
    public static func findIn(_ dirs: [String], _ lang: String) -> (String, String)? {
        // A language tag names a file in the dictionary folders and nothing else: no `..`, no separators.
        if !validLang(lang) { return nil }
        let (full, base) = names(lang)
        func pair(_ d: String, _ stem: String) -> (String, String)? {
            let (a, b) = (join(d, stem + ".aff"), join(d, stem + ".dic"))
            return isFile(a) && isFile(b) ? (a, b) : nil
        }
        for d in dirs { if let p = pair(d, full) { return p } }
        for d in dirs {
            if let p = pair(d, base) { return p }
            guard let names = IO.ownDirectoryEntries(d) else { continue }
            let stems = names.compactMap { n -> String? in n.hasSuffix(".aff") ? String(n.dropLast(4)) : nil }
                .filter { rustLowercase($0).hasPrefix(base + "_") }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            if let p = stems.lazy.compactMap({ pair(d, $0) }).first { return p }
        }
        return nil
    }

    static func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

    private static let cache = Mutex<[String: SpellDictionary?]>([:])

    /// The dictionary for `lang` (a BCP-47 tag such as `en-US`), loaded once per process (`dictionary`).
    public static func dictionary(_ lang: String) -> SpellDictionary? {
        if let d = cache.withLock({ $0[lang] }) { return d }
        let loaded: SpellDictionary? = findIn(searchDirs(), lang).flatMap { a, d in
            guard let ab = IO.readOwnFile(a), let db = IO.readOwnFile(d) else { return nil }
            return SpellDictionary.parse(ab, db)
        }
        cache.withLock { $0[lang] = .some(loaded) }
        return loaded
    }

    /// Use `d` for `lang` from now on in this process (a dictionary the app loaded itself).
    public static func install(_ lang: String, _ d: SpellDictionary) {
        cache.withLock { $0[lang] = .some(d) }
    }

    // MARK: The user dictionary

    private struct UserWords {
        var words: Set<String>?
        var generation: UInt64 = 0
        var override: String?
    }

    private static let user = Mutex(UserWords())

    /// Where Add to Dictionary keeps words: `user.dic` in DeckCraft's own dictionaries folder, one word per
    /// line (`user_dictionary_path`).
    public static func userDictionaryPath() -> String? {
        if let p = user.withLock({ $0.override }) { return p }
        return ProcessInfo.processInfo.environment["HOME"].map { $0 + "/Library/Application Support/DeckCraft/Dictionaries/user.dic" }
    }

    /// Keep the user dictionary at `path` instead (tests, or a portable install).
    public static func setUserDictionaryPath(_ path: String) {
        user.withLock { u in
            u.override = path
            u.words = nil
            u.generation &+= 1
        }
    }

    /// Bumped whenever the user dictionary changes, so cached results can be dropped.
    public static func userGeneration() -> UInt64 { user.withLock { $0.generation } }

    private static func withUser<T>(_ f: (Set<String>) -> T) -> T {
        let path = userDictionaryPath()
        return user.withLock { u in
            if u.words == nil {
                let text = path.flatMap(IO.readOwnFile).map { String(decoding: $0, as: UTF8.self) } ?? ""
                u.words = Set(rustLines(text).map { String(rustTrim($0)) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
            }
            return f(u.words ?? [])
        }
    }

    public struct UserDictionaryError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Add `word` to the user dictionary file (and to checks from now on) (`add_user_word`).
    public static func addUserWord(_ word: String) throws(UserDictionaryError) {
        let word = String(rustTrim(word))
        if word.isEmpty || word.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { throw UserDictionaryError(description: "not a word") }
        if withUser({ $0.contains(word) }) { return }
        guard let path = userDictionaryPath() else { throw UserDictionaryError(description: "no folder for the user dictionary") }
        do {
            try IO.appendOwnFile(path, Array((word + "\n").utf8))
        } catch {
            throw UserDictionaryError(description: (error as NSError).localizedDescription)
        }
        user.withLock { u in
            u.words?.insert(word)
            u.generation &+= 1
        }
    }

    /// Is `word` right in `lang`: in the user dictionary (as written, or lower-case), else by `checker`
    /// (`is_correct`). nil when the checker has no dictionary for the language.
    public static func isCorrect(_ checker: any SpellChecking, _ word: String, _ lang: String) -> Bool? {
        guard checker.hasDictionary(lang) else { return nil }
        if withUser({ $0.contains(word) || $0.contains(rustLowercase(word)) }) { return true }
        return checker.isCorrect(word, lang: lang)
    }

    /// A word of a paragraph: its characters `start..<end` (paragraph character offsets) and the language
    /// of the run it starts in.
    public struct Word: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public var text: String
        public var lang: String
        /// The same word twice in a row: this is the second, and deleting `cut..<end` removes it with the
        /// space before it.
        public var repeated: Int?
    }

    /// The words of `p`, each with its run's language (`lang` on the run, else `default`). Words with
    /// digits are skipped; apostrophes inside a word belong to it; hyphenated words are checked part by
    /// part (`paragraph_words`).
    public static func paragraphWords(_ p: Paragraph, _ defaultLang: String) -> [Word] {
        var chars: [(Unicode.Scalar, Int)] = []
        for (ri, r) in p.runs.enumerated() { chars += r.content.unicodeScalars.map { ($0, ri) } }
        func langOf(_ ri: Int) -> String {
            if let l = p.runs.at(ri)?.props.lang, !l.isEmpty { return l }
            return defaultLang
        }
        func inside(_ c: Unicode.Scalar) -> Bool { rustIsAlphanumeric(c) || c == "'" || c == "’" || c == "-" }
        var out: [Word] = []
        var i = 0
        while i < chars.count {
            if !inside(chars[i].0) {
                i += 1
                continue
            }
            let start = i
            while i < chars.count && inside(chars[i].0) { i += 1 }
            var (a, b) = (start, i)
            while a < b && !rustIsAlphanumeric(chars[a].0) { a += 1 }
            while b > a && !rustIsAlphanumeric(chars[b - 1].0) { b -= 1 }
            let text = String(String.UnicodeScalarView(chars[a ..< b].map(\.0)))
            if text.isEmpty || text.unicodeScalars.contains(where: { ("0" ... "9").contains($0) }) || !text.unicodeScalars.contains(where: rustIsAlphabetic) {
                continue
            }
            var k = a
            for part in text.unicodeScalars.split(separator: "-", omittingEmptySubsequences: false) {
                let n = part.count
                if !part.isEmpty, let c = chars.at(k) {
                    if p.runs.at(c.1)?.props.noProof != true {
                        out.append(Word(start: k, end: k + n, text: String(String.UnicodeScalarView(part)), lang: langOf(c.1), repeated: nil))
                    }
                }
                k += n + 1
            }
        }
        return out
    }

    /// Words that repeat the word just before them (`the the`), with only spaces between (`repeated`).
    public static func repeated(_ p: Paragraph, _ defaultLang: String) -> [Word] {
        let words = paragraphWords(p, defaultLang)
        let chars = p.runs.flatMap { Array($0.content.unicodeScalars) }
        var out: [Word] = []
        if words.count < 2 { return out }
        for k in 0 ..< (words.count - 1) {
            let (a, b) = (words[k], words[k + 1])
            let gap: ArraySlice<Unicode.Scalar> = a.end <= b.start && b.start <= chars.count ? chars[a.end ..< b.start] : []
            if !gap.isEmpty && gap.allSatisfy({ $0 == " " || $0 == "\u{a0}" || $0 == "\t" }) && rustEqual(a.lang, b.lang)
                && rustEqual(rustLowercase(a.text), rustLowercase(b.text)) {
                var w = b
                w.repeated = a.end
                out.append(w)
            }
        }
        return out
    }

    /// The misspelt and repeated words of `p`, each checked in its own language (languages without a
    /// dictionary are skipped), leaving out `ignore` (lower-case) (`misspelt`).
    public static func misspelt(_ p: Paragraph, _ defaultLang: String, _ ignore: [String]) -> [Word] {
        let c = checker
        let bad = paragraphWords(p, defaultLang).filter { w in
            !ignore.contains(where: { rustEqual($0, rustLowercase(w.text)) }) && isCorrect(c, w.text, w.lang) == false
        }
        var v: [Word] = []
        for w in bad + repeated(p, defaultLang) {
            // A repeated misspelt word is reported once, as repeated.
            if let i = v.firstIndex(where: { $0.start == w.start }) { v[i] = w } else { v.append(w) }
        }
        return v
    }
}
