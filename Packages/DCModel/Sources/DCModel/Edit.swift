// DCModel — text editing on a `TextBody`: positions are (paragraph, character offset). Inserting text
// with `\n` splits paragraphs; formatting a range splits runs at its ends. Port of deckcraft
// crates/model/src/edit.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Character offsets count Unicode scalars, as Rust's `chars()` does.
import DCCore

/// (paragraph, char offset in the paragraph).
public typealias TextPos = (Int, Int)

public enum TextEdit {
    private static func clamp(_ body: TextBody, _ p: TextPos) -> TextPos {
        if body.paragraphs.isEmpty { return (0, 0) }
        let pi = Swift.min(Swift.max(p.0, 0), body.paragraphs.count - 1)
        let n = body.paragraphs[pi].charLen
        return (pi, Swift.min(Swift.max(p.1, 0), n))
    }

    private static func order(_ a: TextPos, _ b: TextPos) -> (TextPos, TextPos) {
        a <= b ? (a, b) : (b, a)
    }

    /// Split the paragraph's runs so a run boundary falls at char `at`; returns the index of the first
    /// run starting at or after `at`.
    private static func splitAt(_ p: inout Paragraph, _ at: Int) -> Int {
        var pos = 0
        var i = 0
        while i < p.runs.count {
            let len = p.runs[i].charLen
            if pos == at { return i }
            if at < pos + len {
                let r = p.runs[i]
                if r.kind != .text { return i + 1 }
                let scalars = Array(r.text.unicodeScalars)
                let k = at - pos
                let first = String(String.UnicodeScalarView(scalars[..<k]))
                let second = Run(text: String(String.UnicodeScalarView(scalars[k...])), props: r.props, kind: .text)
                p.runs[i].text = first
                p.runs.insert(second, at: i + 1)
                return i + 1
            }
            pos += len
            i += 1
        }
        return p.runs.count
    }

    /// The explicit run properties in effect at `pos` (the run before the caret, or the end mark).
    public static func propsAt(_ body: TextBody, _ pos: TextPos) -> RunProps {
        let (pi, ch) = clamp(body, pos)
        guard let p = body.paragraphs.at(pi) else { return RunProps() }
        var acc = 0
        var last: RunProps?
        for r in p.runs {
            let len = r.charLen
            if ch <= acc + len && ch > acc { return r.props }
            if acc + len >= ch && ch == 0 { return r.props }
            acc += len
            last = r.props
        }
        return last ?? p.endProps
    }

    /// Splits `s` on `sep` like Rust's `str::split`, keeping empty pieces.
    private static func split(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        s.unicodeScalars.split(separator: sep, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// Insert `text` at `pos` (with `props`, else the props at `pos`). `\n` starts a new paragraph (same
    /// level and paragraph props); `\u{0B}` inserts a line break. Returns the caret after it.
    @discardableResult
    public static func insert(_ body: inout TextBody, _ pos: TextPos, _ text: String, _ props: RunProps? = nil) -> TextPos {
        if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph()) }
        var (pi, ch) = clamp(body, pos)
        let props = props ?? propsAt(body, (pi, ch))
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var first = true
        for part in split(text, "\n") {
            if !first {
                // Split paragraph pi at ch.
                guard body.paragraphs.indices.contains(pi) else { break }
                let idx = splitAt(&body.paragraphs[pi], ch)
                let p = body.paragraphs[pi]
                let tail = Array(p.runs[idx...])
                body.paragraphs[pi].runs.removeSubrange(idx...)
                let newp = Paragraph(level: p.level, props: p.props, runs: tail, defProps: p.defProps, endProps: p.endProps)
                body.paragraphs[pi].endProps = props
                body.paragraphs.insert(newp, at: pi + 1)
                pi += 1
                ch = 0
            }
            first = false
            for (k, seg) in split(part, "\u{0B}").enumerated() {
                guard body.paragraphs.indices.contains(pi) else { break }
                if k > 0 {
                    let idx = splitAt(&body.paragraphs[pi], ch)
                    body.paragraphs[pi].runs.insert(Run(text: "", props: props, kind: .break), at: idx)
                    ch += 1
                }
                if seg.isEmpty { continue }
                let idx = splitAt(&body.paragraphs[pi], ch)
                body.paragraphs[pi].runs.insert(Run.with(seg, props), at: idx)
                ch += seg.charCount
            }
            if body.paragraphs.indices.contains(pi) {
                body.paragraphs[pi].normalize()
                if body.paragraphs[pi].runs.isEmpty { body.paragraphs[pi].endProps = props }
            }
        }
        return (pi, ch)
    }

    /// Delete the range between `a` and `b`; returns the caret at the start.
    @discardableResult
    public static func delete(_ body: inout TextBody, _ a: TextPos, _ b: TextPos) -> TextPos {
        if body.paragraphs.isEmpty { return (0, 0) }
        let (s, e) = order(clamp(body, a), clamp(body, b))
        if s == e { return s }
        if s.0 == e.0 {
            let endProps = propsOfRange(body.paragraphs[s.0], s.1)
            let i0 = splitAt(&body.paragraphs[s.0], s.1)
            let i1 = splitAt(&body.paragraphs[s.0], e.1)
            if i1 > i0 { body.paragraphs[s.0].runs.removeSubrange(i0 ..< i1) }
            body.paragraphs[s.0].normalize()
            if body.paragraphs[s.0].runs.isEmpty { body.paragraphs[s.0].endProps = endProps }
            return s
        }
        // Keep the head of s.0 and the tail of e.0, joined; drop paragraphs between.
        var tail: [Run] = []
        if body.paragraphs.indices.contains(e.0) {
            let i = splitAt(&body.paragraphs[e.0], e.1)
            tail = Array(body.paragraphs[e.0].runs[i...])
            body.paragraphs[e.0].runs.removeSubrange(i...)
        }
        let i = splitAt(&body.paragraphs[s.0], s.1)
        body.paragraphs[s.0].runs.removeSubrange(i...)
        body.paragraphs[s.0].runs += tail
        body.paragraphs[s.0].normalize()
        if e.0 > s.0 && e.0 < body.paragraphs.count {
            body.paragraphs.removeSubrange((s.0 + 1) ... e.0)
        }
        return s
    }

    private static func propsOfRange(_ p: Paragraph, _ at: Int) -> RunProps {
        var acc = 0
        for r in p.runs {
            let len = r.charLen
            if at < acc + len || (at == acc + len && at > 0) { return r.props }
            acc += len
        }
        return p.runs.last?.props ?? p.endProps
    }

    /// Apply `f` to the run properties of every run in [a, b). An empty range changes the empty
    /// paragraph's end mark (so typing there picks the formatting up).
    public static func format(_ body: inout TextBody, _ a: TextPos, _ b: TextPos, _ f: (inout RunProps) -> Void) {
        if body.paragraphs.isEmpty { return }
        let (s, e) = order(clamp(body, a), clamp(body, b))
        for pi in s.0 ... e.0 where body.paragraphs.indices.contains(pi) {
            let from = pi == s.0 ? s.1 : 0
            let to = pi == e.0 ? e.1 : body.paragraphs[pi].charLen
            if body.paragraphs[pi].runs.isEmpty || (from == to && s == e) {
                f(&body.paragraphs[pi].endProps)
                continue
            }
            let i0 = splitAt(&body.paragraphs[pi], from)
            let i1 = splitAt(&body.paragraphs[pi], to)
            if i1 > i0 {
                for k in i0 ..< i1 { f(&body.paragraphs[pi].runs[k].props) }
            }
            if to == body.paragraphs[pi].charLen { f(&body.paragraphs[pi].endProps) }
            body.paragraphs[pi].normalize()
        }
    }

    /// Apply `f` to every run in the body (and end marks).
    public static func formatAll(_ body: inout TextBody, _ f: (inout RunProps) -> Void) {
        for pi in body.paragraphs.indices {
            for ri in body.paragraphs[pi].runs.indices { f(&body.paragraphs[pi].runs[ri].props) }
            f(&body.paragraphs[pi].endProps)
            body.paragraphs[pi].normalize()
        }
    }

    /// The text between two positions (`\n` between paragraphs).
    public static func textRange(_ body: TextBody, _ a: TextPos, _ b: TextPos) -> String {
        let (s, e) = order(clamp(body, a), clamp(body, b))
        var out = String.UnicodeScalarView()
        for pi in s.0 ... e.0 {
            guard let p = body.paragraphs.at(pi) else { continue }
            let t = Array(p.text.unicodeScalars)
            let from = pi == s.0 ? s.1 : 0
            let to = pi == e.0 ? e.1 : t.count
            let lo = Swift.min(from, t.count)
            let hi = Swift.min(to, t.count)
            if lo < hi { out.append(contentsOf: t[lo ..< hi]) }
            if pi != e.0 { out.append("\n") }
        }
        return String(out)
    }

    /// A formatted copy of the range.
    public static func slice(_ body: TextBody, _ a: TextPos, _ b: TextPos) -> TextBody {
        let (s, e) = order(clamp(body, a), clamp(body, b))
        var out = TextBody(body: body.body, listStyle: body.listStyle, paragraphs: [])
        for pi in s.0 ... e.0 {
            guard var p = body.paragraphs.at(pi) else { continue }
            let to = pi == e.0 ? e.1 : p.charLen
            let i1 = splitAt(&p, to)
            p.runs.removeSubrange(i1...)
            let from = pi == s.0 ? s.1 : 0
            let i0 = splitAt(&p, from)
            p.runs.removeSubrange(..<i0)
            out.paragraphs.append(p)
        }
        return out
    }

    /// Insert a formatted body at `pos` (paste): first paragraph merges into the current one.
    @discardableResult
    public static func insertBody(_ body: inout TextBody, _ pos: TextPos, _ src: TextBody) -> TextPos {
        var caret = clamp(body, pos)
        for (k, sp) in src.paragraphs.enumerated() {
            if k > 0 {
                caret = insert(&body, caret, "\n", nil)
                if body.paragraphs.indices.contains(caret.0) {
                    body.paragraphs[caret.0].level = sp.level
                    body.paragraphs[caret.0].props = sp.props
                }
            }
            for r in sp.runs {
                switch r.kind {
                case .text: caret = insert(&body, caret, r.text, r.props)
                case .break: caret = insert(&body, caret, "\u{0B}", r.props)
                default:
                    if body.paragraphs.indices.contains(caret.0) {
                        let idx = splitAt(&body.paragraphs[caret.0], caret.1)
                        body.paragraphs[caret.0].runs.insert(r, at: idx)
                        caret.1 += r.charLen
                    }
                }
            }
        }
        return caret
    }

    private static func paraText(_ body: TextBody, _ pi: Int) -> String { body.paragraphs.at(pi)?.text ?? "" }

    /// The word a double-click selects around `pos` (see `Words.wordAt`): the word without its trailing
    /// spaces, as PowerPoint selects it.
    public static func wordAt(_ body: TextBody, _ pos: TextPos) -> (TextPos, TextPos) {
        let (pi, ch) = clamp(body, pos)
        let (s, e) = Words.wordAt(paraText(body, pi), ch)
        return ((pi, s), (pi, e))
    }

    /// Next/previous word stop (Ctrl+Right/Left on Windows, Option+arrows on the Mac). At the end of a
    /// paragraph Ctrl+Right goes to the start of the next one; at its start Ctrl+Left goes to the end of
    /// the previous one.
    public static func wordMove(_ body: TextBody, _ pos: TextPos, _ forward: Bool) -> TextPos {
        let (pi, ch) = clamp(body, pos)
        let t = paraText(body, pi)
        if forward {
            if let s = Words.nextStop(t, ch) { return (pi, s) }
            return pi + 1 < body.paragraphs.count ? (pi + 1, 0) : (pi, ch)
        }
        if let s = Words.prevStop(t, ch) { return (pi, s) }
        return pi > 0 ? (pi - 1, body.paragraphs.at(pi - 1)?.charLen ?? 0) : (pi, 0)
    }

    /// Ctrl+Up: the start of the paragraph, or of the previous one when already there.
    public static func paraUp(_ body: TextBody, _ pos: TextPos) -> TextPos {
        let (pi, ch) = clamp(body, pos)
        return ch > 0 ? (pi, 0) : (Swift.max(pi - 1, 0), 0)
    }

    /// Ctrl+Down: the start of the next paragraph, or the end of the last one.
    public static func paraDown(_ body: TextBody, _ pos: TextPos) -> TextPos {
        let (pi, _) = clamp(body, pos)
        return pi + 1 < body.paragraphs.count ? (pi + 1, 0) : (pi, body.paragraphs.at(pi)?.charLen ?? 0)
    }

    /// Delete a word from `pos` as Ctrl+Backspace (`forward == false`) or Ctrl+Delete does in
    /// PowerPoint; returns the caret.
    ///
    /// Ctrl+Backspace deletes back to the previous word stop (at a paragraph's start it joins the
    /// paragraph to the one before). Ctrl+Delete deletes the rest of the word, or the spaces after a word
    /// and the next word, or up to the next stop (see `Words.deleteForwardEnd`), then tidies the spacing
    /// as PowerPoint's smart cut does: spaces left before closing punctuation or at the end of the
    /// paragraph after a word go, and sentence punctuation left against a word gets a space. At a
    /// paragraph's end it joins the next paragraph.
    @discardableResult
    public static func deleteWord(_ body: inout TextBody, _ pos: TextPos, _ forward: Bool) -> TextPos {
        if body.paragraphs.isEmpty { return (0, 0) }
        let (pi, ch) = clamp(body, pos)
        let t = paraText(body, pi)
        if !forward {
            let to = Words.prevStop(t, ch).map { (pi, $0) } ?? charMove(body, (pi, ch), false)
            return delete(&body, to, (pi, ch))
        }
        guard let e = Words.deleteForwardEnd(t, ch) else {
            let to = charMove(body, (pi, ch), true)
            return delete(&body, (pi, ch), to)
        }
        let at = delete(&body, (pi, ch), (pi, e))
        return smartSpace(&body, at)
    }

    /// PowerPoint's smart-cut spacing after a word was deleted at `at`; returns the caret.
    private static func smartSpace(_ body: inout TextBody, _ at: TextPos) -> TextPos {
        let (pi, s) = at
        let chars = Array(paraText(body, pi).unicodeScalars)
        let after = chars.at(s)
        let before = s > 0 ? chars.at(s - 1) : nil
        if (after.map(Words.isClosingPunct) ?? true) && before == " " {
            var w = s
            while w > 0 && chars.at(w - 1) == " " { w -= 1 }
            if w > 0 && (chars.at(w - 1).map(rustIsAlphanumeric) ?? false) {
                return delete(&body, (pi, w), (pi, s))
            }
            return at
        }
        if let b = before, let a = after, Words.isSentencePunct(b), rustIsAlphanumeric(a) {
            let digits = s >= 2 && (chars.at(s - 2).map(rustIsNumeric) ?? false) && rustIsNumeric(a)
            if !digits { return insert(&body, at, " ", nil) }
        }
        return at
    }

    /// One character left/right across paragraph boundaries.
    public static func charMove(_ body: TextBody, _ pos: TextPos, _ forward: Bool) -> TextPos {
        let (pi, ch) = clamp(body, pos)
        let n = body.paragraphs.at(pi)?.charLen ?? 0
        if forward {
            if ch < n { return (pi, ch + 1) }
            return pi + 1 < body.paragraphs.count ? (pi + 1, 0) : (pi, ch)
        }
        if ch > 0 { return (pi, ch - 1) }
        if pi > 0 { return (pi - 1, body.paragraphs.at(pi - 1)?.charLen ?? 0) }
        return (0, 0)
    }

    /// The position of the `n`th character of the body's plain text (`\n` between paragraphs).
    private static func posOfChar(_ body: TextBody, _ n: Int) -> TextPos {
        var n = n
        for (pi, p) in body.paragraphs.enumerated() {
            let len = p.charLen
            if n <= len { return (pi, n) }
            n -= len + 1
        }
        return end(body)
    }

    /// Make the body's plain text (paragraphs joined by `\n`) read `text`, as if it had been typed in
    /// place: only the span between the longest common prefix and suffix changes, so untouched text keeps
    /// its run and paragraph formatting and new text takes the formatting where it lands. Text that shares
    /// nothing with the old text replaces it as plain text.
    public static func replaceText(_ body: inout TextBody, _ text: String) {
        let old = Array(body.text.unicodeScalars)
        let new = Array(text.unicodeScalars)
        if old == new { return }
        let pre = zip(old, new).prefix { $0 == $1 }.count
        let room = Swift.min(old.count, new.count) - pre
        let suf = zip(old.reversed(), new.reversed()).prefix(room).prefix { $0 == $1 }.count
        if pre == 0 && suf == 0 {
            var fresh = TextBody.fromText(text)
            fresh.body = body.body
            fresh.listStyle = body.listStyle
            body = fresh
            return
        }
        let a = posOfChar(body, pre)
        let b = posOfChar(body, old.count - suf)
        let at = delete(&body, a, b)
        let mid = pre <= new.count - suf ? String(String.UnicodeScalarView(new[pre ..< (new.count - suf)])) : ""
        if !mid.isEmpty { insert(&body, at, mid, nil) }
    }

    /// End of the body.
    public static func end(_ body: TextBody) -> TextPos {
        let pi = Swift.max(body.paragraphs.count - 1, 0)
        return (pi, body.paragraphs.at(pi)?.charLen ?? 0)
    }

    /// The case Shift+F3 changes `s` to next, as PowerPoint cycles it: lowercase → Capitalize Each Word
    /// → UPPERCASE → lowercase; any other mix goes to UPPERCASE first.
    public static func nextCase(_ s: String) -> String {
        let hasAlpha = s.unicodeScalars.contains(where: rustIsAlphabetic)
        if rustEqual(s, rustLowercase(s)) && hasAlpha { return "title" }
        if rustEqual(s, rustUppercase(s)) && hasAlpha { return "lower" }
        return "upper"
    }

    /// Change case: `upper`, `lower`, `sentence`, `title`, `toggle`.
    public static func changeCase(_ s: String, _ mode: String) -> String {
        changeCaseParts([s], mode).joined()
    }

    /// Change the case of consecutive pieces of text (the runs of a paragraph) as one string, so `title`
    /// and `sentence` carry their word/sentence state across piece boundaries. Each output piece is the
    /// changed form of the matching input piece, even where a character changes length.
    public static func changeCaseParts(_ parts: [String], _ mode: String) -> [String] {
        var start = true
        return parts.map { s in
            switch mode {
            case "upper":
                return rustUppercase(s)
            case "lower":
                return rustLowercase(s)
            case "toggle":
                return s.unicodeScalars.map { c in
                    c.properties.isUppercase ? c.properties.lowercaseMapping : c.properties.uppercaseMapping
                }.joined()
            default:
                // `title` restarts after whitespace, sentence case after sentence punctuation.
                let title = mode == "title"
                var out = ""
                for c in s.unicodeScalars {
                    if start && rustIsAlphabetic(c) {
                        out += c.properties.uppercaseMapping
                        start = false
                    } else {
                        out += c.properties.lowercaseMapping
                    }
                    if (title && c.properties.isWhitespace) || (!title && (c == "." || c == "!" || c == "?")) {
                        start = true
                    }
                }
                return out
            }
        }
    }
}
