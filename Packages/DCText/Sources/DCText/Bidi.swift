// DCText — bidirectional text for paragraph layout: embedding levels, rule L1 per line and rule L2's
// visual order. Port of deckcraft crates/text/src/bidi.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// deckcraft computes most levels itself (`levels_lang`) and hands paragraphs with explicit embedding
// controls (LRE…PDI) to unicode-bidi's full UAX #9. Here those rare paragraphs take their levels from
// CoreText's own bidi analysis (CTLine run directions), the one place this file is not a literal port.
import CoreText
import DCCore
import Foundation

enum Bidi {
    private static let explicit: Set<BidiClass> = [.LRE, .RLE, .LRO, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI]

    /// Does the text need the bidi algorithm at all (any right-to-left, Arabic number or explicit control)?
    static func needsBidi(_ chars: [Unicode.Scalar]) -> Bool {
        chars.contains { c in
            let k = bidiClass(c)
            return k == .R || k == .AL || k == .AN || explicit.contains(k)
        }
    }

    /// Embedding levels from CoreText's bidi analysis: right-to-left runs odd, left-to-right runs even,
    /// above the paragraph level.
    static func coreTextLevels(_ chars: [Unicode.Scalar], _ rtl: Bool) -> [UInt8] {
        let base: UInt8 = rtl ? 1 : 0
        var out = [UInt8](repeating: base, count: chars.count)
        let text = String(String.UnicodeScalarView(chars))
        // UTF-16 offset of each scalar.
        var utf16Of: [Int] = []
        utf16Of.reserveCapacity(chars.count + 1)
        var u = 0
        for c in chars {
            utf16Of.append(u)
            u += c.utf16.count
        }
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle(rtl)])
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return out }
        for run in runs {
            let range = CTRunGetStringRange(run)
            let runRTL = CTRunGetStatus(run).contains(.rightToLeft)
            let level: UInt8 = runRTL ? (rtl ? 1 : 1) : (rtl ? 2 : 0)
            for (i, off) in utf16Of.enumerated() where off >= range.location && off < range.location + range.length {
                out[i] = level
            }
        }
        return out
    }

    /// A CoreText paragraph style with the given base direction.
    static func paragraphStyle(_ rtl: Bool) -> CTParagraphStyle {
        var dir: CTWritingDirection = rtl ? .rightToLeft : .leftToRight
        return withUnsafeBytes(of: &dir) { raw in
            guard let base = raw.baseAddress else { return CTParagraphStyleCreate(nil, 0) }
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: base)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    /// deckcraft `levels`: the full algorithm (here CoreText's), or all level 0 for a left-to-right
    /// paragraph with nothing that needs it.
    static func levels(_ chars: [Unicode.Scalar], _ rtl: Bool) -> [UInt8] {
        if !rtl && !needsBidi(chars) { return Array(repeating: 0, count: chars.count) }
        return coreTextLevels(chars, rtl)
    }

    /// Languages written right to left (the run's `lang`): their neutrals and numbers lean right to left.
    static func isRTLLang(_ lang: String) -> Bool {
        let primary = rustASCIILowercase(String(lang.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? ""))
        return ["ar", "he", "iw", "fa", "ur", "yi", "ji", "ps", "sd", "ug", "dv", "syr", "ckb", "arc"].contains(primary)
    }

    private enum Dir: Equatable {
        case l, r, num, open
    }

    /// deckcraft `levels_lang`: embedding levels where runs in a right-to-left language (`rtlLang`) set
    /// how their neutrals and numbers resolve, as PowerPoint does.
    static func levelsLang(_ chars: [Unicode.Scalar], _ rtl: Bool, _ rtlLang: [Bool]) -> [UInt8] {
        let base: UInt8 = rtl ? 1 : 0
        let anyRTLLang = rtlLang.contains(true)
        if !rtl && !anyRTLLang && !needsBidi(chars) { return Array(repeating: 0, count: chars.count) }
        var cls = chars.map(bidiClass)
        if cls.contains(where: { explicit.contains($0) }) { return levels(chars, rtl) }
        let n = chars.count
        func rl(_ i: Int) -> Bool { rtlLang.at(i) ?? false }
        let sos: Dir = rtl ? .r : .l
        // W1: a non-spacing mark takes the class of the character before it.
        for i in 0 ..< n where cls[i] == .NSM {
            cls[i] = i == 0 ? (rtl ? .R : .L) : cls[i - 1]
        }
        var dir = [Dir](repeating: .open, count: n)
        var lastStrong: BidiClass?
        for i in 0 ..< n {
            let c = cls[i]
            let d: Dir
            switch c {
            case .L: d = .l
            case .R, .AL: d = .r
            case .AN: d = .num
            case .EN where !rl(i): d = .l
            case .EN where lastStrong == .L: d = .l
            case .EN: d = .num
            default: d = .open
            }
            if c == .L || c == .R || c == .AL { lastStrong = c }
            dir[i] = d
        }
        let afterET = nextNonET(cls)
        for i in 0 ..< n {
            guard rl(i), dir[i] == .open else { continue }
            let c = cls[i]
            func num(_ j: Int?) -> Bool { j.flatMap { dir.at($0) } == .num }
            let joined: Bool
            switch c {
            case .ES, .CS: joined = num(i > 0 ? i - 1 : nil) && num(i + 1)
            case .ET: joined = num(i > 0 ? i - 1 : nil) || num(afterET.at(i) ?? nil)
            default: joined = false
            }
            if joined { dir[i] = .num }
        }
        for i in 0 ..< n where !rl(i) && dir[i] == .open && cls[i] != .WS && cls[i] != .S {
            dir[i] = .l
        }
        func strongAt(_ j: Int) -> Dir? {
            switch dir.at(j) {
            case .l?: return .l
            case .r?, .num?: return .r
            default: return nil
            }
        }
        var nextStrong = [Dir?](repeating: nil, count: n + 1)
        if n > 0 {
            for j in stride(from: n - 1, through: 0, by: -1) {
                nextStrong[j] = strongAt(j) ?? nextStrong[j + 1]
            }
        }
        var last: Dir?
        var i = 0
        while i < n {
            if !(rl(i) && dir[i] == .open) {
                last = strongAt(i) ?? last
                i += 1
                continue
            }
            let start = i
            while i < n && rl(i) && dir[i] == .open { i += 1 }
            let before = last ?? sos
            let after = (nextStrong.at(i) ?? nil) ?? sos
            let d: Dir = before == after ? before : .r
            for k in start ..< i { dir[k] = d }
            if start < i { last = d == .num ? .r : d }
        }
        var prev: Dir = .l
        for k in 0 ..< n {
            if dir[k] == .open { dir[k] = prev }
            prev = dir[k] == .num ? .r : dir[k]
        }
        let odd = base % 2 == 1
        return dir.map { d in
            switch (d, odd) {
            case (.l, false), (.r, true): base
            case (.l, true), (.r, false), (.open, _): base + 1
            case (.num, false): base + 2
            case (.num, true): base + 1
            }
        }
    }

    static func nextNonET(_ cls: [BidiClass]) -> [Int?] {
        var out = [Int?](repeating: nil, count: cls.count)
        var next: Int?
        if !cls.isEmpty {
            for i in stride(from: cls.count - 1, through: 0, by: -1) {
                out[i] = next
                if cls[i] != .ET { next = i }
            }
        }
        return out
    }

    private static func l1Whitespace(_ c: BidiClass) -> Bool {
        [.WS, .FSI, .LRI, .RLI, .PDI, .BN, .LRE, .RLE, .LRO, .RLO, .PDF].contains(c)
    }

    /// Rule L1 for one line: segment and paragraph separators, any whitespace run before them, and
    /// whitespace at the end of the line take the paragraph level.
    static func lineLevels(_ chars: [Unicode.Scalar], _ levels: [UInt8], _ paraLevel: UInt8) -> [UInt8] {
        var out = levels
        if out.count < chars.count { out += Array(repeating: paraLevel, count: chars.count - out.count) }
        if out.count > chars.count { out.removeLast(out.count - chars.count) }
        var trailing = true
        if !chars.isEmpty {
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                let k = bidiClass(chars[i])
                if k == .S || k == .B {
                    out[i] = paraLevel
                    trailing = true
                } else if l1Whitespace(k) {
                    if trailing { out[i] = paraLevel }
                } else {
                    trailing = false
                }
            }
        }
        return out
    }

    /// Rule L2: the visual order of a line's characters (indices into `levels`, left to right).
    static func visualOrder(_ levels: [UInt8]) -> [Int] {
        var order = Array(levels.indices)
        guard let mx = levels.max() else { return order }
        let minOdd = levels.filter { $0 % 2 == 1 }.min() ?? (mx == .max ? mx : mx + 1)
        var lvl = mx
        while lvl >= minOdd && lvl > 0 {
            var i = 0
            while i < order.count {
                if levels[order[i]] >= lvl {
                    let start = i
                    while i < order.count && levels[order[i]] >= lvl { i += 1 }
                    order[start ..< i].reverse()
                } else {
                    i += 1
                }
            }
            lvl -= 1
        }
        return order
    }
}
