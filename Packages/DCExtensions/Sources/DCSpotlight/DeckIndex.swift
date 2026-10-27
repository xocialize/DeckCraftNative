// DCSpotlight — what Spotlight learns about a presentation: its properties (title, subject, authors,
// keywords, company, dates), its slide count and size, and its words — every slide's title and text (groups,
// tables, charts' titles, labels and series names included), the speaker notes and the comments with their
// replies. The Core Spotlight import extension (`CSImportExtension`, macOS 12+, the current mechanism: the old
// `.mdimporter` bundles are a legacy plug-in format) calls `DeckIndex.make` and `apply(to:)`. The file is read
// without its pictures (`DeckReader.readText`), so the cost follows the text, not the file. Not a port:
// deckcraft has no Spotlight importer.
import CoreSpotlight
import DCCore
import DCExtensionKit
import DCModel
import Foundation

public struct DeckIndex: Sendable, Equatable {
    public var title: String
    public var subject: String
    public var authors: [String]
    public var keywords: [String]
    public var documentComments: String
    public var company: String
    public var lastModifiedBy: String
    public var created: Date?
    public var modified: Date?
    public var slideCount: Int
    public var slideSize: CGSize
    /// Each slide's title (empty for a slide without one), in order.
    public var slideTitles: [String]
    /// The text on the slides (titles excluded), the notes and the comments, in reading order.
    public var slideText: [String]
    public var notes: [String]
    public var comments: [String]
    /// Who wrote the comments and replies, once each, in order of appearance.
    public var commentAuthors: [String]

    /// The most slides read, and the most text kept (UTF-8 bytes), whatever the file holds.
    public static let maxSlides = 5000
    public static let maxTextBytes = 4 << 20
    /// How deep groups and comment replies are followed.
    static let maxDepth = 64

    /// The index of the file at `url`.
    public static func make(fileAt url: URL, limits: DeckLimits = .spotlight) throws(DeckFileError) -> DeckIndex {
        make(try DeckReader.readText(url, limits: limits).presentation)
    }

    public static func make(_ p: Presentation) -> DeckIndex {
        let props = p.props
        var budget = TextBudget(left: maxTextBytes)
        var titles: [String] = [], text: [String] = [], notes: [String] = [], comments: [String] = [], people: [String] = []
        for slide in p.slides.prefix(maxSlides) {
            titles.append(budget.take(slide.title))
            for shape in slide.shapes { collect(shape, 0, into: &text, &budget) }
            let n = rustTrim(slide.notesText)
            if !n.isEmpty { notes.append(budget.take(String(n))) }
            for c in slide.comments { collect(c, 0, into: &comments, &people, &budget) }
        }
        return DeckIndex(
            title: String(rustTrim(props.title)),
            subject: String(rustTrim(props.subject)),
            authors: split(props.author, ";"),
            keywords: split(props.keywords, ",;"),
            documentComments: String(rustTrim(props.comments)),
            company: String(rustTrim(props.company)),
            lastModifiedBy: String(rustTrim(props.lastModifiedBy)),
            created: date(props.created),
            modified: date(props.modified),
            slideCount: p.slides.count,
            slideSize: CGSize(width: p.slideSize.width.rustMax(0), height: p.slideSize.height.rustMax(0)),
            slideTitles: titles.map { $0.replacingOccurrences(of: "\n", with: " ") },
            slideText: text.filter { !$0.isEmpty },
            notes: notes.filter { !$0.isEmpty },
            comments: comments.filter { !$0.isEmpty },
            commentAuthors: people
        )
    }

    /// Everything searchable as one text: titles, slide text, notes, comments, one per line.
    public var textContent: String {
        (slideTitles.filter { !$0.isEmpty } + slideText + notes + comments).joined(separator: "\n")
    }

    /// Sets the Spotlight attributes this index knows; leaves the rest as the system found them.
    public func apply(to a: CSSearchableItemAttributeSet) {
        if !title.isEmpty { a.title = title }
        if !subject.isEmpty { a.subject = subject }
        if !authors.isEmpty { a.authorNames = authors }
        if !keywords.isEmpty { a.keywords = keywords }
        if !documentComments.isEmpty { a.comment = documentComments }
        if !company.isEmpty { a.organizations = [company] }
        if !lastModifiedBy.isEmpty { a.editors = [lastModifiedBy] }
        if !commentAuthors.isEmpty { a.contributors = commentAuthors }
        if let created { a.contentCreationDate = created }
        if let modified { a.contentModificationDate = modified }
        a.pageCount = NSNumber(value: slideCount)
        if slideSize.width > 0, slideSize.height > 0 {
            a.pageWidth = NSNumber(value: Double(slideSize.width))
            a.pageHeight = NSNumber(value: Double(slideSize.height))
        }
        let text = textContent
        if !text.isEmpty { a.textContent = text }
    }

    // MARK: Collecting

    /// The text of `shape` and what it holds: its own text, a table's cells, a chart's words, a group's shapes.
    static func collect(_ shape: Shape, _ depth: Int, into out: inout [String], _ budget: inout TextBudget) {
        if depth > maxDepth || budget.left <= 0 { return }
        if shape.phType?.isTitle ?? false {
            // The slide's title is indexed as such.
        } else if let t = shape.text, !t.isEmpty {
            out.append(budget.take(t.text.replacingOccurrences(of: "\u{0B}", with: " ")))
        }
        switch shape.kind {
        case .group(let children, _):
            for c in children { collect(c, depth + 1, into: &out, &budget) }
        case .table(let table):
            for row in table.rows {
                let cells = row.cells.map { $0.text.text.replacingOccurrences(of: "\u{0B}", with: " ") }.filter { !rustTrim($0).isEmpty }
                if !cells.isEmpty { out.append(budget.take(cells.joined(separator: "\t"))) }
            }
        case .chart(let chart):
            var words: [String] = []
            if let t = chart.title { words.append(t) }
            if let x = chart.axisTitles.a { words.append(x) }
            if let y = chart.axisTitles.b { words.append(y) }
            words += chart.series.map(\.name)
            words += chart.categories.prefix(1000)
            let line = words.map { String(rustTrim($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
            if !line.isEmpty { out.append(budget.take(line)) }
        default:
            break
        }
    }

    /// A comment and its replies: their text, and their authors once each.
    static func collect(_ c: Comment, _ depth: Int, into out: inout [String], _ people: inout [String], _ budget: inout TextBudget) {
        if depth > maxDepth || budget.left <= 0 { return }
        let text = rustTrim(c.text)
        if !text.isEmpty { out.append(budget.take(String(text))) }
        let author = String(rustTrim(c.author))
        if !author.isEmpty, !people.contains(author) { people.append(author) }
        for r in c.replies { collect(r, depth + 1, into: &out, &people, &budget) }
    }

    /// `s` split at any of `separators`, trimmed, without empty pieces.
    static func split(_ s: String, _ separators: String) -> [String] {
        s.split { separators.contains($0) }.map { String(rustTrim(String($0))) }.filter { !$0.isEmpty }
    }

    /// An ISO 8601 date (`2026-10-27T01:13:13Z`, with or without fractional seconds), as the formats store it.
    static func date(_ s: String) -> Date? {
        let t = String(rustTrim(s))
        if t.isEmpty { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: t)
    }
}

/// What is left of `DeckIndex.maxTextBytes`.
struct TextBudget {
    var left: Int

    /// `s`, cut to what is left (at a character boundary), and the budget spent.
    mutating func take(_ s: String) -> String {
        if left <= 0 { return "" }
        let n = s.utf8.count
        if n <= left {
            left -= n
            return s
        }
        var out = ""
        var used = 0
        for ch in s {
            let k = ch.utf8.count
            if used + k > left { break }
            out.append(ch)
            used += k
        }
        left = 0
        return out
    }
}
