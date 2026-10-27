// DCEngine — the `find` command module: Home › Editing's Find and Replace across slide text, table cells
// and speaker notes.
// Port of deckcraft crates/engine/src/cmd/find.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum FindCommands {
    public static func specs() -> [CommandSpec] {
        [
            .query(
                "text.find",
                "Find",
                ["Home", "Editing"],
                nil,
                "{text, matchCase?: bool, wholeWords?: bool} → [{slide, shape (null = notes), cell?: [row, col], para, start, end}] (char offsets in the paragraph)",
                Cmd.hasDoc,
                find
            ),
            .cmd(
                "text.replace",
                "Replace",
                ["Home", "Editing"],
                nil,
                "{text, with, matchCase?, wholeWords?, at?: a text.find match (replace just that one; default: replace all)} → {replaced}",
                Cmd.hasDoc,
                replace
            ),
        ]
    }

    /// Where a text body lives on a slide.
    struct Loc: Equatable {
        var shape: UInt64?
        var cell: (Int, Int)?

        static func == (a: Loc, b: Loc) -> Bool {
            a.shape == b.shape && a.cell?.0 == b.cell?.0 && a.cell?.1 == b.cell?.1
        }
    }

    /// Visit every text body on a slide: shapes depth-first (groups, table cells), then the notes.
    static func bodies(_ slide: inout Slide, _ f: (Loc, inout TextBody) -> Void) {
        func rec(_ shapes: inout [Shape], _ depth: Int) {
            if depth > 64 { return }
            for i in shapes.indices {
                let id = UInt64(shapes[i].id.rawValue)
                if var t = shapes[i].text {
                    f(Loc(shape: id, cell: nil), &t)
                    shapes[i].text = t
                }
                if case .table(var t) = shapes[i].kind {
                    for r in t.rows.indices {
                        for c in t.rows[r].cells.indices { f(Loc(shape: id, cell: (r, c)), &t.rows[r].cells[c].text) }
                    }
                    shapes[i].kind = .table(t)
                } else if case .group = shapes[i].kind {
                    shapes[i].mutateChildren { rec(&$0, depth + 1) }
                }
            }
        }
        rec(&slide.shapes, 0)
        f(Loc(shape: nil, cell: nil), &slide.notes)
    }

    struct Opts {
        var pat: [Unicode.Scalar]
        var matchCase: Bool
        var whole: Bool

        init(pat: [Unicode.Scalar], matchCase: Bool, whole: Bool) {
            self.pat = pat
            self.matchCase = matchCase
            self.whole = whole
        }

        init(_ p: JSON, _ cmd: String) throws {
            pat = Array((Cmd.strParam(p, "text") ?? "").unicodeScalars)
            if pat.isEmpty { throw Cmd.bad(cmd, "missing `text`") }
            matchCase = Cmd.boolOr(p, "matchCase", false)
            whole = Cmd.boolOr(p, "wholeWords", false)
        }

        func eq(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
            a == b || (!matchCase && rustEqual(a.properties.lowercaseMapping, b.properties.lowercaseMapping))
        }

        /// Non-overlapping matches as char ranges.
        func matches(_ text: [Unicode.Scalar]) -> [(Int, Int)] {
            let n = pat.count
            func word(_ c: Unicode.Scalar?) -> Bool { c.map { rustIsAlphanumeric($0) || $0 == "_" } ?? false }
            var out: [(Int, Int)] = []
            var i = 0
            while i + n <= text.count {
                var hit = zip(text[i ..< i + n], pat).allSatisfy { eq($0, $1) }
                if hit && whole { hit = !word(i > 0 ? text[i - 1] : nil) && !word(text.at(i + n)) }
                if hit {
                    out.append((i, i + n))
                    i += n
                } else {
                    i += 1
                }
            }
            return out
        }
    }

    static func paraChars(_ p: Paragraph) -> [Unicode.Scalar] { p.runs.flatMap { Array($0.content.unicodeScalars) } }

    /// Matches that lie wholly in plain text runs (never inside a field, equation or break).
    static func paraMatches(_ p: Paragraph, _ o: Opts) -> [(Int, Int)] {
        var spans: [(Int, Int, Bool)] = []
        var off = 0
        for r in p.runs {
            let n = r.charLen
            spans.append((off, off + n, r.kind == .text))
            off += n
        }
        return o.matches(paraChars(p)).filter { a, b in spans.allSatisfy { s, e, text in text || e <= a || s >= b || s == e } }
    }

    /// Replace chars `a..<b` of the paragraph; the replacement takes the first run's formatting.
    static func splice(_ p: inout Paragraph, _ a: Int, _ b: Int, _ with: String) {
        var off = 0
        var placed = false
        for i in p.runs.indices {
            let chars = Array(p.runs[i].content.unicodeScalars)
            let (s, e) = (off, off + chars.count)
            off = e
            if e <= a || s >= b { continue }
            let head = String(String.UnicodeScalarView(chars.prefix(max(a - s, 0))))
            let tail = String(String.UnicodeScalarView(chars.dropFirst(min(max(b - s, 0), chars.count))))
            p.runs[i].text = placed ? tail : head + with + tail
            placed = true
        }
        if p.runs.count > 1 {
            p.runs.removeAll { $0.text.isEmpty && $0.kind == .text }
        }
    }

    @Sendable static func find(_ s: Session, _ p: JSON) throws -> JSON {
        let o = try Opts(p, "text.find")
        let st = try s.doc()
        var out: [JSON] = []
        for (i, slide) in st.doc.slides.enumerated() {
            var sl = slide
            bodies(&sl) { loc, t in
                for (pi, para) in t.paragraphs.enumerated() {
                    for (a, b) in paraMatches(para, o) {
                        out.append([
                            "slide": .integer(i), "shape": loc.shape.map { JSON.integer($0) } ?? .null,
                            "cell": loc.cell.map { [.integer($0.0), .integer($0.1)] } ?? .null,
                            "para": .integer(pi), "start": .integer(a), "end": .integer(b),
                        ])
                    }
                }
            }
        }
        return .array(out)
    }

    @Sendable static func replace(_ s: Session, _ p: JSON) throws -> JSON {
        let o = try Opts(p, "text.replace")
        let with = Cmd.strParam(p, "with") ?? ""
        var at: (Int, Loc, Int, Int)?
        if let v = p.get("at"), v.isObject {
            func n(_ k: String) throws -> Int {
                guard let x = v.get(k)?.asUsize else { throw Cmd.bad("text.replace", "`at` needs `\(k)`") }
                return x
            }
            var cell: (Int, Int)?
            if let c = v.get("cell")?.asArray, let r = c.at(0)?.asUsize, let k = c.at(1)?.asUsize { cell = (r, k) }
            at = (try n("slide"), Loc(shape: v.get("shape")?.asU64, cell: cell), try n("para"), try n("start"))
        }
        let target = at
        let count = try s.edit { doc, _ -> Int in
            var count = 0
            for i in doc.slides.indices {
                if let a = target, a.0 != i { continue }
                var sl = doc.slides[i]
                var changed = 0
                bodies(&sl) { loc, t in
                    if let a = target, a.1 != loc { return }
                    for pi in t.paragraphs.indices {
                        if let a = target, a.2 != pi { continue }
                        for (a, b) in paraMatches(t.paragraphs[pi], o).reversed() {
                            if let x = target, x.3 != a { continue }
                            splice(&t.paragraphs[pi], a, b, with)
                            changed += 1
                        }
                    }
                }
                if changed > 0 {
                    doc.slides[i] = sl
                    count += changed
                }
            }
            if count == 0 { throw Cmd.bad("text.replace", "no matches") }
            return count
        }
        return ["replaced": .integer(count)]
    }
}
