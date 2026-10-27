// DCFormat — Outline/RTF: PowerPoint's "Outline/RTF" save type, and reading such a file back as slides.
// Port of deckcraft crates/format/src/rtf.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// The export writes one paragraph per slide title (outline level 0, bold, larger) and one per body
// paragraph (outline level = indent + 1, indented), keeping bold, italic and underline. The import reads
// paragraphs and their `\outlinelevel` (or, failing that, `\li` indent) into the tab-indented outline
// `outlineToSlides` understands.
import DCCore
import DCModel

public enum RTF {
    /// RTF-escape `s` (non-ASCII as `\uN?`, UTF-16, signed as RTF wants).
    private static func escape(_ out: inout String, _ s: String) {
        for c in s.unicodeScalars {
            switch c {
            case "\\", "{", "}":
                out += "\\"
                out.unicodeScalars.append(c)
            case "\t":
                out += "\\tab "
            case "\u{0B}", "\n":
                out += "\\line "
            default:
                if c.isASCII {
                    // ASCII controls are dropped.
                    if c.value >= 0x20 && c.value != 0x7F { out.unicodeScalars.append(c) }
                } else {
                    for u in String(c).utf16 { out += "\\u\(Int16(bitPattern: u))?" }
                }
            }
        }
    }

    private static func runs(_ out: inout String, _ p: Paragraph) {
        for r in p.runs {
            if case .break = r.kind {
                out += "\\line "
                continue
            }
            let b = r.props.bold == true
            let i = r.props.italic == true
            let u = r.props.underline.map { $0 != "none" } ?? false
            if !(b || i || u) {
                escape(&out, r.text)
                continue
            }
            out += "{" + (b ? "\\b" : "") + (i ? "\\i" : "") + (u ? "\\ul" : "") + " "
            escape(&out, r.text)
            out += "}"
        }
    }

    /// The presentation's outline (slide titles and body text) as RTF.
    public static func slidesToRTF(_ p: Presentation) -> String {
        var out = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fswiss Liberation Sans;}}\n"
        for s in p.slides {
            let title = s.shapes.first { $0.phType?.isTitle ?? false }?.text
            out += "\\pard\\outlinelevel0\\sb240\\b\\fs32 "
            // The title stays one outline paragraph (a `\par` would start another slide on re-import), so
            // its paragraphs are joined with line breaks.
            let tps = (title?.paragraphs ?? []).filter { !$0.isEmpty }
            if tps.isEmpty { escape(&out, s.title) }
            for (k, tp) in tps.enumerated() {
                if k > 0 { out += "\\line " }
                runs(&out, tp)
            }
            out += "\\b0\\par\n"
            for sh in s.shapes {
                if sh.phType?.isTitle ?? false { continue }
                guard let t = sh.text else { continue }
                for para in t.paragraphs where !para.isEmpty {
                    let lvl = UInt32(Swift.min(para.level, 8))
                    out += "\\pard\\outlinelevel\(lvl + 1)\\li\(360 * (lvl + 1))\\fs24 "
                    runs(&out, para)
                    out += "\\par\n"
                }
            }
        }
        out += "}\n"
        return out
    }

    /// Whether `bytes` look like RTF.
    public static func sniff(_ bytes: [UInt8]) -> Bool {
        let start = bytes.firstIndex { !(UInt8(ascii: "\t") ... UInt8(ascii: "\r")).contains($0) && $0 != 0x20 } ?? bytes.count
        return bytes[start...].starts(with: Array("{\\rtf".utf8))
    }

    /// Destinations whose text is not document text.
    private static let skip: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "footnote", "listtable",
        "listoverridetable", "generator", "xmlnstbl", "themedata", "datastore", "latentstyles", "rsidtbl", "object",
        "fldinst",
        // A list item's rendered bullet or number, written before its text (Word: listtext; RTF 1.5 and older
        // writers: pntext, pntxta, pntxtb). Its `\pard` must not reset the paragraph's indent.
        "listtext", "pntext", "pntxta", "pntxtb",
    ]

    /// Read an RTF outline into tab-indented outline text: a paragraph's outline level (or its left indent
    /// in 0.25" steps) becomes its number of tabs.
    public static func rtfToOutline(_ rtf: String) -> String {
        var p = OutlineParser(Array(rtf.utf8))
        p.run()
        p.flush()
        return finishSurrogates(p.out)
    }

    /// Group state: whether the text is being skipped, and the `\uc` fallback count.
    private struct GroupState {
        var skip = false
        var uc = 1
    }

    /// Parser state: the cursor over the UTF-8 bytes, the group stack and the outline so far.
    private struct OutlineParser {
        let b: [UInt8]
        var i = 0
        var stack: [GroupState] = []
        var st = GroupState()
        var level: UInt32?
        var indent: Int64 = 0
        var pendingSkip = 0
        var line = ""
        var out = ""

        init(_ b: [UInt8]) {
            self.b = b
        }

        func isBoundary(_ i: Int) -> Bool { i == b.count || (i < b.count && b[i] & 0xC0 != 0x80) }

        /// `i + n`, or one character on when that would land inside a multi-byte character.
        func advance(_ i: Int, _ n: Int) -> Int {
            if isBoundary(i + n) { return i + n }
            guard i < b.count else { return i + 1 }
            let lead = b[i]
            let len = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            return i + len
        }

        func text(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }

        mutating func run() {
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "{"): openGroup()
                case UInt8(ascii: "}"): closeGroup()
                case UInt8(ascii: "\\"):
                    i += 1
                    if !escape() { return }
                case UInt8(ascii: "\r"), UInt8(ascii: "\n"): i += 1
                default: plainText()
                }
            }
        }

        /// `{`: push the group; `{\*\dest …}` is an ignorable destination.
        mutating func openGroup() {
            stack.append(st)
            i += 1
            if b[i...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "*")]) { st.skip = true }
        }

        mutating func closeGroup() {
            st = stack.popLast() ?? GroupState()
            i += 1
        }

        /// The character after a backslash: a control word, a hex escape or a symbol. False at the end.
        mutating func escape() -> Bool {
            guard i < b.count else { return false }
            let n = b[i]
            if isAlpha(n) {
                controlWord()
            } else if n == UInt8(ascii: "'") {
                hexEscape()
            } else {
                symbol(n)
            }
            return true
        }

        func isAlpha(_ c: UInt8) -> Bool { (65 ... 90).contains(c) || (97 ... 122).contains(c) }
        func isDigit(_ c: UInt8) -> Bool { (48 ... 57).contains(c) }

        mutating func controlWord() {
            let s = i
            while i < b.count && isAlpha(b[i]) { i += 1 }
            let word = text(s ..< i)
            let ns = i
            if i < b.count && (b[i] == UInt8(ascii: "-") || isDigit(b[i])) {
                i += 1
                while i < b.count && isDigit(b[i]) { i += 1 }
            }
            let arg = Int64(text(ns ..< i))
            if i < b.count && b[i] == UInt8(ascii: " ") { i += 1 }
            if pendingSkip > 0 {
                pendingSkip -= 1
                return
            }
            if RTF.skip.contains(word) { st.skip = true }
            if !st.skip { apply(word, arg) }
        }

        mutating func apply(_ word: String, _ arg: Int64?) {
            switch word {
            case "par": flush()
            case "pard":
                level = nil
                indent = 0
            case "outlinelevel": level = arg.map { UInt32(Swift.min(Swift.max($0, 0), 9)) }
            case "li": indent = arg ?? 0
            case "tab", "line": line += " "
            case "uc": st.uc = Int(Swift.min(Swift.max(arg ?? 1, 0), 8))
            case "u": unicode(arg ?? 0)
            case "emdash": line += "—"
            case "endash": line += "–"
            case "bullet": line += "•"
            case "lquote": line += "‘"
            case "rquote": line += "’"
            case "ldblquote": line += "“"
            case "rdblquote": line += "”"
            default: break
            }
        }

        /// `\uN`: one UTF-16 unit, then the `\uc` fallback characters, which are skipped.
        mutating func unicode(_ v: Int64) {
            // RTF writes UTF-16 units as signed 16-bit values.
            pushUTF16(UInt32(v & 0xFFFF))
            pendingSkip = 0
            var k = st.uc
            while k > 0 && i < b.count {
                if b[i] == UInt8(ascii: "\\") && b.at(i + 1) == UInt8(ascii: "'") {
                    i = advance(i, 4)
                } else if [UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\\")].contains(b[i]) {
                    break
                } else {
                    i = advance(i, 1)
                }
                k -= 1
            }
        }

        /// `\'hh`: one cp1252 byte.
        mutating func hexEscape() {
            var hex: UInt8?
            if i + 3 <= b.count, isBoundary(i + 1), isBoundary(i + 3) {
                let h = b[(i + 1) ..< (i + 3)]
                if h.allSatisfy({ isDigit($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) {
                    hex = UInt8(text((i + 1) ..< (i + 3)), radix: 16)
                }
            }
            i = advance(i, 3)
            if !st.skip, let h = hex, h != 0 { line.unicodeScalars.append(cp1252(h)) }
        }

        /// A one-character control symbol (`\\`, `\{`, `\~`, ...).
        mutating func symbol(_ n: UInt8) {
            i += 1
            if st.skip { return }
            switch n {
            case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"): line.unicodeScalars.append(Unicode.Scalar(n))
            case UInt8(ascii: "~"): line += "\u{A0}"
            case UInt8(ascii: "_"): line += "\u{2011}"
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"): flush()
            default: break
            }
        }

        /// Plain text up to the next special character.
        mutating func plainText() {
            let s = i
            while i < b.count && ![UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\\"), UInt8(ascii: "\r"), UInt8(ascii: "\n")].contains(b[i]) {
                i += 1
            }
            if !st.skip {
                line += String(decoding: b[s ..< i].filter { $0 != 0 }, as: UTF8.self)
            }
        }

        /// Push a UTF-16 unit; surrogate halves are parked as private markers (NUL plus four hex digits)
        /// and joined afterwards. NUL itself is the marker, so a NUL unit is dropped.
        mutating func pushUTF16(_ v: UInt32) {
            if v == 0 { return }
            if let c = Unicode.Scalar(v) {
                line.unicodeScalars.append(c)
            } else {
                let h = String(v, radix: 16)
                line += "\u{0}" + String(repeating: "0", count: Swift.max(0, 4 - h.count)) + h
            }
        }

        /// Ends the current line: a non-empty line becomes one outline entry, indented by its level.
        mutating func flush() {
            let t = rustTrim(line)
            if !t.isEmpty {
                let (sum, overflow) = indent.addingReportingOverflow(180)
                let byIndent = (overflow ? Int64.max : sum) / 360
                let n = Int(Swift.min(Swift.max(level.map(Int64.init) ?? byIndent, 0), 9))
                out += String(repeating: "\t", count: n) + t + "\n"
            }
            line = ""
        }
    }

    private static func finishSurrogates(_ s: String) -> String {
        let b = Array(s.utf8)
        guard b.contains(0) else { return s }
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= b.count else { return nil }
            return UInt32(String(decoding: b[at ..< at + 4], as: UTF8.self), radix: 16)
        }
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            guard b[i] == 0 else {
                out.append(b[i])
                i += 1
                continue
            }
            let hi = hex4(i + 1)
            let lo = b.at(i + 5) == 0 ? hex4(i + 6) : nil
            if let h = hi, let l = lo, (0xD800 ..< 0xDC00).contains(h), (0xDC00 ..< 0xE000).contains(l),
               let c = Unicode.Scalar(0x10000 + ((h - 0xD800) << 10) + (l - 0xDC00)) {
                out += Array(String(c).utf8)
                i += 10
            } else {
                out += Array("\u{FFFD}".utf8)
                // Skip the NUL and, when four hex digits follow, the digits; otherwise resume right after the
                // NUL so no following character is lost.
                i += hi != nil ? 5 : 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func cp1252(_ b: UInt8) -> Unicode.Scalar {
        let high: [Unicode.Scalar] = [
            "€", "\u{81}", "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", "\u{8D}", "Ž", "\u{8F}", "\u{90}", "‘", "’",
            "“", "”", "•", "–", "—", "˜", "™", "š", "›", "œ", "\u{9D}", "ž", "Ÿ",
        ]
        if (0x80 ... 0x9F).contains(b) { return high[Int(b - 0x80)] }
        return Unicode.Scalar(b)
    }
}
