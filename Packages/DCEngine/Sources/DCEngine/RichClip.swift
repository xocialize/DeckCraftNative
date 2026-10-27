// DCEngine — rich text on the system clipboard, as HTML.
// Port of deckcraft crates/engine/src/cmd/richclip.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Pages and Keynote put copied text on the pasteboard as HTML (and plain text). DeckCraft writes the same
// pair when it copies, and reads it back on paste: bold, italic and underline survive. Anything else in
// the markup is skipped. A hostile fragment is capped, never executed. Indices are UTF-8 byte offsets,
// as in Rust; every cut falls on an ASCII delimiter, so it is always a character boundary.
import DCCore
import DCModel
import Foundation

enum RichClip {
    static let maxHTML = 1 << 20
    static let maxParas = 2_000
    static let maxRuns = 10_000

    /// HTML for `body`: one `<p>` per paragraph, `<b>`, `<i>` and `<u>` for the formatting.
    static func bodyToHTML(_ body: TextBody) -> String {
        var out = ""
        for (i, p) in body.paragraphs.enumerated() {
            if i > 0 { out += "<br>" }
            out += "<p>"
            for r in p.runs {
                let (open, close) = tags(r.props)
                out += open
                if case .break = r.kind { out += "<br>" } else { pushEscaped(&out, r.text) }
                out += close
                if out.utf8.count > maxHTML { break }
            }
            out += "</p>"
        }
        return out
    }

    private static func tags(_ props: RunProps) -> (String, String) {
        var open = ""
        var close = ""
        if props.bold == true {
            open += "<b>"
            close = "</b>" + close
        }
        if props.italic == true {
            open += "<i>"
            close = "</i>" + close
        }
        if let u = props.underline, rustASCIILowercase(u) != "none" {
            open += "<u>"
            close = "</u>" + close
        }
        return (open, close)
    }

    private static func pushEscaped(_ out: inout String, _ text: String) {
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(c)
            }
        }
    }

    private static func str(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }

    /// `trim_start_matches(c)`.
    private static func dropScalars(_ s: String, _ c: Unicode.Scalar) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.drop { $0 == c }))
    }

    /// The formatted text of an HTML fragment, or nil when it has no text.
    ///
    /// Understands `<b>`, `<strong>`, `<i>`, `<em>`, `<u>`, `<br>`, paragraphs, and a `style` that says
    /// bold, italic or underline. Other tags are ignored. The result is capped.
    static func htmlToBody(_ html: String) -> TextBody? {
        let bytes = Array(html.utf8)
        if bytes.count > maxHTML { return nil }
        var i = 0
        var bold: Int32 = 0
        var italic: Int32 = 0
        var underline: Int32 = 0
        var stack: [(String, Int32, Int32, Int32)] = []
        var paragraphs: [Paragraph] = [Paragraph.default]
        var runs = 0
        var skip: Int32 = 0
        while i < bytes.count && paragraphs.count <= maxParas && runs <= maxRuns {
            if bytes[i] == UInt8(ascii: "<") {
                let end = bytes[(i + 1)...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count
                let raw = str(bytes[(i + 1) ..< max(i + 1, end)])
                i = min(end + 1, bytes.count)
                let token = String(rustTrim(raw))
                if token.utf8.first == UInt8(ascii: "!") || token.utf8.first == UInt8(ascii: "?") { continue }
                let closing = token.utf8.first == UInt8(ascii: "/")
                let nameSrc = String(rustTrim(dropScalars(token, "/")))
                let nameEnd = nameSrc.unicodeScalars.firstIndex { $0.properties.isWhitespace || $0 == "/" || $0 == ">" } ?? nameSrc.unicodeScalars.endIndex
                let name = rustASCIILowercase(String(nameSrc.unicodeScalars[..<nameEnd]))
                if name == "script" || name == "style" || name == "head" {
                    if closing {
                        skip = max(skip - 1, 0)
                    } else if token.utf8.last != UInt8(ascii: "/") {
                        skip += 1
                    }
                    continue
                }
                if skip > 0 { continue }
                if closing {
                    let kind = tagKind(name)
                    if !kind.isEmpty {
                        let searchStart = max(stack.count - 64, 0)
                        if let pos = stack[searchStart...].lastIndex(where: { $0.0 == kind }) {
                            let (_, db, di, du) = stack[pos]
                            bold -= db
                            italic -= di
                            underline -= du
                            stack.removeSubrange(pos...)
                        }
                    }
                    if isBlock(name) { newPara(&paragraphs) }
                    continue
                }
                if isBreak(name) {
                    newPara(&paragraphs)
                    continue
                }
                let (db, di, du) = tagStyle(name, nameSrc)
                if db + di + du > 0 {
                    bold += db
                    italic += di
                    underline += du
                    if token.utf8.last != UInt8(ascii: "/") && stack.count < 128 {
                        stack.append((tagKind(name), db, di, du))
                    } else {
                        bold -= db
                        italic -= di
                        underline -= du
                    }
                }
                continue
            }
            if skip > 0 {
                i += 1
                continue
            }
            let end = bytes[i...].firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
            var text = decodeText(str(bytes[i ..< end]))
            i = end
            // A space at the start of a paragraph, or after a space, does not render in HTML.
            let afterSpace = paragraphs.last?.runs.last.map { $0.text.utf8.last == UInt8(ascii: " ") } ?? true
            if afterSpace { text = dropScalars(text, " ") }
            if text.isEmpty { continue }
            pushRun(&paragraphs, &runs, text, bold > 0, italic > 0, underline > 0)
        }
        while let last = paragraphs.last, last.isEmpty, paragraphs.count > 1 { paragraphs.removeLast() }
        trimEndSpace(&paragraphs)
        if paragraphs.allSatisfy(\.isEmpty) { return nil }
        for k in paragraphs.indices { paragraphs[k].normalize() }
        var body = TextBody.default
        body.paragraphs = paragraphs
        return body
    }

    private static func tagKind(_ name: String) -> String {
        switch name {
        case "b", "strong": "b"
        case "i", "em": "i"
        case "u": "u"
        case "span", "font": "span"
        case "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6": "block"
        default: ""
        }
    }

    private static func isBreak(_ name: String) -> Bool { name == "br" || name == "hr" }

    private static func isBlock(_ name: String) -> Bool {
        ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"].contains(name)
    }

    private static func tagStyle(_ name: String, _ src: String) -> (Int32, Int32, Int32) {
        var bold: Int32 = name == "b" || name == "strong" ? 1 : 0
        var italic: Int32 = name == "i" || name == "em" ? 1 : 0
        var underline: Int32 = name == "u" ? 1 : 0
        if let style = attr(src, "style") {
            let s = rustASCIILowercase(style)
            if let on = weightBold(s) { bold = on ? 1 : 0 }
            if s.contains("font-style:italic") || s.contains("font-style: italic") { italic = 1 }
            if s.contains("text-decoration:underline") || s.contains("text-decoration: underline")
                || s.contains("text-decoration-line:underline") || s.contains("text-decoration-line: underline") {
                underline = 1
            }
        }
        return (bold, italic, underline)
    }

    /// Whether a `font-weight` in `style` turns bold on (true) or off (false).
    private static func weightBold(_ style: String) -> Bool? {
        guard let at = style.range(of: "font-weight") else { return nil }
        let rest = style[at.upperBound...].drop { $0 == ":" || $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }
        if rest.hasPrefix("bold") { return true }
        if rest.hasPrefix("normal") || rest.hasPrefix("lighter") { return false }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let weight = UInt32(digits) else { return nil }
        return weight >= 600
    }

    private static func attr(_ tag: String, _ key: String) -> String? {
        let t = Array(tag.utf8)
        let lower = Array(rustASCIILowercase(tag).utf8)
        let k = Array(key.utf8)
        guard !k.isEmpty, lower.count >= k.count else { return nil }
        var found: Int?
        var at = 0
        while at + k.count <= lower.count {
            if Array(lower[at ..< at + k.count]) == k {
                let named = at > 0 && isASCIIWhitespace(lower[at - 1])
                let afterKey = trimStartBytes(t[(at + k.count)...])
                let eq = afterKey.first == UInt8(ascii: "=")
                if named && eq {
                    found = at
                    break
                }
            }
            at += 1
        }
        guard let at = found else { return nil }
        var after = trimStartBytes(t[(at + k.count)...])
        guard after.first == UInt8(ascii: "=") else { return nil }
        after = trimStartBytes(after.dropFirst())
        guard let quote = after.first, quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return nil }
        let rest = after.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return str(rest[..<end])
    }

    private static func isASCIIWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }

    /// `str::trim_start` over bytes (Unicode whitespace, decoded).
    private static func trimStartBytes(_ b: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let s = str(b)
        let trimmed = rustTrimStart(Substring(s))
        let dropped = s.utf8.count - trimmed.utf8.count
        return b.dropFirst(dropped)
    }

    private static func newPara(_ paragraphs: inout [Paragraph]) {
        if paragraphs.count >= maxParas { return }
        if let last = paragraphs.last, !last.isEmpty {
            trimEndSpace(&paragraphs)
            paragraphs.append(Paragraph.default)
        }
    }

    /// Whitespace at the end of a paragraph does not render in HTML.
    private static func trimEndSpace(_ paragraphs: inout [Paragraph]) {
        guard let p = paragraphs.indices.last, let r = paragraphs[p].runs.indices.last else { return }
        var t = Array(paragraphs[p].runs[r].text.unicodeScalars)
        while t.last == " " { t.removeLast() }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: t)
        paragraphs[p].runs[r].text = String(v)
    }

    private static func pushRun(_ paragraphs: inout [Paragraph], _ runs: inout Int, _ text: String, _ bold: Bool, _ italic: Bool, _ underline: Bool) {
        if runs >= maxRuns { return }
        guard let p = paragraphs.indices.last else { return }
        var props = RunProps.default
        if bold { props.bold = true }
        if italic { props.italic = true }
        if underline { props.underline = "sng" }
        paragraphs[p].runs.append(Run.with(text, props))
        runs += 1
    }

    /// Text with each run of HTML whitespace (spaces, tabs, line breaks) collapsed to one space.
    private static func collapseSpace(_ s: Substring) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for c in s.unicodeScalars {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(c)
                space = false
            }
        }
        return String(out)
    }

    static func decodeText(_ raw: String) -> String {
        var out = ""
        let b = Array(raw.utf8)
        var rest = b[...]
        while let at = rest.firstIndex(of: UInt8(ascii: "&")) {
            out += collapseSpace(Substring(str(rest[..<at])))
            rest = rest[at...]
            var window = min(rest.count, 32)
            // Back up to a character boundary (a UTF-8 continuation byte is 0b10xx_xxxx).
            while window > 0 && window < rest.count && rest[rest.startIndex + window] & 0xC0 == 0x80 { window -= 1 }
            let head = rest.prefix(window)
            guard let end = head.firstIndex(of: UInt8(ascii: ";")) else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            let entity = str(rest[(rest.startIndex + 1) ..< end])
            let decoded: Unicode.Scalar? = switch entity {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            case "nbsp": "\u{a0}"
            default: entity.hasPrefix("#") ? numericChar(String(entity.dropFirst())) : nil
            }
            if let c = decoded {
                out.unicodeScalars.append(c)
                rest = rest[(end + 1)...]
            } else {
                // Not a well-formed entity (e.g. a bare "R&D"): keep the '&' as typed.
                out += "&"
                rest = rest.dropFirst()
            }
        }
        if !rest.isEmpty && rest.first != UInt8(ascii: "&") {
            out += collapseSpace(Substring(str(rest)))
        }
        return out
    }

    private static func numericChar(_ digits: String) -> Unicode.Scalar? {
        var body = digits
        var radix = 10
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            body = String(digits.dropFirst())
            radix = 16
        }
        // `parse` and `from_str_radix` accept a leading '+', which is not a valid reference.
        guard !body.isEmpty, body.unicodeScalars.allSatisfy({ c in
            radix == 10 ? ("0" ... "9").contains(c) : (("0" ... "9").contains(c) || ("a" ... "f").contains(c) || ("A" ... "F").contains(c))
        }) else { return nil }
        guard let n = UInt32(body, radix: radix), let c = Unicode.Scalar(n) else { return nil }
        if c.properties.generalCategory == .control && c != "\n" && c != "\t" { return nil }
        return c
    }

    /// Do the HTML's words and the paste's plain text say the same thing?
    static func sameWords(_ htmlPlain: String, _ pasted: String) -> Bool {
        rustEqual(fold(htmlPlain), fold(pasted))
    }

    private static func fold(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{00a0}", with: " ")
        let scalars = Array(t.unicodeScalars)
        let isTrim: (Unicode.Scalar) -> Bool = { $0 == "\n" || $0 == " " || $0 == "\t" }
        guard let first = scalars.firstIndex(where: { !isTrim($0) }), let last = scalars.lastIndex(where: { !isTrim($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[first ... last])
        return String(out)
    }
}
