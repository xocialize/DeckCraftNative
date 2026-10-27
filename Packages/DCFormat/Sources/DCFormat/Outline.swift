// DCFormat — outline text: slides from a tab-indented outline or Markdown, and the deck as an outline.
// Port of deckcraft crates/format/src/lib.rs (`outline_to_slides`, `markdown_to_slides`,
// `slides_to_outline`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCModel

extension DeckFormat {
    /// Slides read from an outline: each title with its body paragraphs (level 0–8, text).
    typealias OutlineSlides = [(title: String, body: [(level: UInt8, text: String)])]

    /// Append a Title and Content slide per outline entry; the number made.
    static func addOutlineSlides(_ p: inout Presentation, _ slides: OutlineSlides) -> Int {
        guard let lay = layoutOfKind(p, .titleAndContent) else { return 0 }
        var made = 0
        for (title, body) in slides {
            // An exhausted id space makes no new slides: what fit is kept (#407).
            guard var s = newSlide(&p, lay) else { break }
            if !s.shapes.isEmpty { s.shapes[0].text = TextBody.fromText(title) }
            if s.shapes.count > 1 {
                for (level, line) in body {
                    var tb = s.shapes[1].text ?? TextBody()
                    var para = Paragraph(line)
                    para.level = Swift.min(level, 8)
                    tb.paragraphs.append(para)
                    s.shapes[1].text = tb
                }
            }
            p.slides.append(s)
            made += 1
        }
        return made
    }

    /// Outline text: one slide per unindented line; tab-indented lines become body bullets at their
    /// level (Insert ▸ Slides from Outline, View ▸ Outline copy).
    @discardableResult
    public static func outlineToSlides(_ p: inout Presentation, _ text: String) -> Int {
        var slides: OutlineSlides = []
        for raw in rustLines(text) {
            if rustTrim(raw).isEmpty { continue }
            let scalars = raw.unicodeScalars
            let tabs = scalars.prefix { $0 == "\t" }.count
            let spaces = scalars.prefix { $0 == " " }.count / 2
            let level = Swift.max(tabs, spaces)
            let t = rustTrim(raw)
            var line = String(t)
            if let first = t.unicodeScalars.first, first == "-" || first == "*" || first == "•" {
                let rest = String(String.UnicodeScalarView(t.unicodeScalars.dropFirst()))
                if let r = rest.unicodeScalars.first, r == " " || r == "\t" { line = String(rustTrim(rest)) }
            }
            if level == 0 {
                slides.append((line, []))
            } else if !slides.isEmpty {
                slides[slides.count - 1].body.append((UInt8(Swift.min(level - 1, 8)), line))
            }
        }
        return addOutlineSlides(&p, slides)
    }

    /// An ATX heading's text (CommonMark: up to three spaces, one to six `#`, then a space or the end; a
    /// closing run of `#` is dropped).
    static func mdHeading(_ line: String) -> String? {
        var t = Substring(line)
        for prefix in ["   ", "  ", " "] where t.hasPrefix(prefix) {
            t = t.dropFirst(prefix.count)
            break
        }
        let hashes = t.unicodeScalars.prefix { $0 == "#" }.count
        let rest = t.dropFirst(hashes)
        guard (1 ... 6).contains(hashes), rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        let trimmed = rustTrim(String(rest))
        var closed = Substring(trimmed)
        while closed.last == "#" { closed = closed.dropLast() }
        if closed.isEmpty || closed.hasSuffix(" ") || closed.hasSuffix("\t") { return String(rustTrimEnd(closed)) }
        return String(trimmed)
    }

    /// A list item's nesting level (two spaces or a tab each) and text: `-`, `*` or `+`, or digits then
    /// `.` or `)`, followed by a space.
    static func mdListItem(_ line: String) -> (level: UInt8, text: String)? {
        let indent = line.unicodeScalars.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let t = rustTrimStart(Substring(line))
        var rest: Substring
        if let f = t.first, f == "-" || f == "*" || f == "+" {
            rest = t.dropFirst()
        } else {
            let digits = t.unicodeScalars.prefix { ("0" ... "9").contains($0) }.count
            if digits == 0 || digits > 9 { return nil }
            let after = t.dropFirst(digits)
            guard let f = after.first, f == "." || f == ")" else { return nil }
            rest = after.dropFirst()
        }
        guard rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        return (UInt8(Swift.min(indent / 2, 8)), String(rustTrim(String(rest))))
    }

    /// Markdown outline text (`.md`): each heading starts a slide with its text as the title; list items
    /// under it become bullets nested by their indentation, other lines body paragraphs. Text before the
    /// first heading is skipped. A file without headings is read as a plain outline.
    @discardableResult
    public static func markdownToSlides(_ p: inout Presentation, _ text: String) -> Int {
        let lines = rustLines(text)
        if !lines.contains(where: { mdHeading($0) != nil }) { return outlineToSlides(&p, text) }
        var slides: OutlineSlides = []
        for line in lines {
            if rustTrim(line).isEmpty { continue }
            if let title = mdHeading(line) {
                slides.append((title, []))
            } else if !slides.isEmpty {
                let item = mdListItem(line) ?? (0, String(rustTrim(line)))
                slides[slides.count - 1].body.append(item)
            }
        }
        return addOutlineSlides(&p, slides)
    }

    /// The deck as outline text (titles unindented, body paragraphs tab-indented by level).
    public static func slidesToOutline(_ p: Presentation) -> String {
        var out = ""
        for s in p.slides {
            // One line per title: a newline would start another slide on re-import.
            out += s.title.replacingOccurrences(of: "\n", with: " ") + "\n"
            for sh in s.shapes {
                if sh.phType?.isTitle ?? false { continue }
                if let t = sh.text {
                    for para in t.paragraphs where !para.isEmpty {
                        out += String(repeating: "\t", count: Int(para.level) + 1)
                        out += para.text.replacingOccurrences(of: "\u{0B}", with: " ") + "\n"
                    }
                }
                if case .table(let t) = sh.kind {
                    for row in t.rows {
                        let cells = row.cells.map {
                            $0.text.text.replacingOccurrences(of: "\u{0B}", with: " ").replacingOccurrences(of: "\n", with: " ")
                        }
                        out += "\t" + cells.joined(separator: "\t") + "\n"
                    }
                }
            }
        }
        return out
    }
}
