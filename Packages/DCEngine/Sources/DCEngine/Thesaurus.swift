// DCEngine — Review › Thesaurus: synonyms from deckcraft's small built-in English word list
// (`ThesaurusData.swift`, its `data/thesaurus.txt` verbatim), looked up offline.
// Port of deckcraft crates/engine/src/thesaurus.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum Thesaurus {
    /// One sense of a word: its headword and synonyms.
    public struct Sense: Sendable, Equatable {
        public var word: String
        public var synonyms: [String]

        public func toJSON() -> JSON { ["word": .string(word), "synonyms": .array(synonyms.map(JSON.string))] }
    }

    /// The data's entries: (headword, synonyms), comments skipped.
    static let entries: [(String, [String])] = rustLines(data).compactMap { l in
        if l.hasPrefix("#") { return nil }
        guard let bar = l.unicodeScalars.firstIndex(of: "|") else { return nil }
        let h = String(rustTrim(String(l.unicodeScalars[..<bar])))
        let rest = String(l.unicodeScalars[l.unicodeScalars.index(after: bar)...])
        let syn = rest.split(separator: ",", omittingEmptySubsequences: false).map { String(rustTrim(String($0))) }.filter { !$0.isEmpty }
        return (h, syn)
    }

    static func sensesOf(_ head: String) -> [Sense] {
        entries.filter { rustEqual($0.0, head) }.map { Sense(word: $0.0, synonyms: $0.1) }
    }

    /// The senses for `word`, trying simple English endings when the word itself isn't listed ("goals" →
    /// "goal", "improved" → "improve", "growing" → "grow"). Synonyms take the word's capitalisation
    /// ("Goal" → "Aim", "GOAL" → "AIM") (`lookup`).
    public static func lookup(_ word: String) -> [Sense] {
        let trimmed = Array(rustTrim(word).unicodeScalars)
        func keep(_ c: Unicode.Scalar) -> Bool { rustIsAlphanumeric(c) || c == "-" }
        var lo = 0
        var hi = trimmed.count
        while lo < hi && !keep(trimmed[lo]) { lo += 1 }
        while hi > lo && !keep(trimmed[hi - 1]) { hi -= 1 }
        let w = String(String.UnicodeScalarView(trimmed[lo ..< hi].prefix(64)))
        let lower = rustLowercase(w)
        if lower.isEmpty { return [] }
        var tries = [lower]
        for (suffix, add) in [("ies", "y"), ("es", ""), ("s", ""), ("ied", "y"), ("ed", "e"), ("ed", ""), ("ing", "e"), ("ing", "")] {
            let ls = Array(lower.unicodeScalars)
            let ss = Array(suffix.unicodeScalars)
            if ls.count >= ss.count, Array(ls.suffix(ss.count)) == ss {
                let stem = Array(ls.dropLast(ss.count))
                if stem.count >= 2 { tries.append(String(String.UnicodeScalarView(stem)) + add) }
            }
        }
        guard let found = tries.lazy.map(sensesOf).first(where: { !$0.isEmpty }) else { return [] }
        let ws = Array(w.unicodeScalars)
        let upper = ws.count > 1 && ws.allSatisfy { !$0.properties.isLowercase }
        let title = !upper && (ws.first?.properties.isUppercase ?? false)
        return found.map { s in
            Sense(word: s.word, synonyms: s.synonyms.map { x in
                if upper { return rustUppercase(x) }
                if title, let f = x.unicodeScalars.first { return f.properties.uppercaseMapping + String(String.UnicodeScalarView(x.unicodeScalars.dropFirst())) }
                return x
            })
        }
    }
}
