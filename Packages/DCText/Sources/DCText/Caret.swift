// DCText — caret geometry and movement over laid-out text: bidirectional carets with affinity, hit
// testing, logical and visual movement, line navigation, selection as the union of visual boxes, and IME
// composition underlines. Port of deckcraft crates/text/src/lib.rs (`impl LineInfo`, `impl TextLayout`;
// MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCGeometry

extension LineInfo {
    var len: Int { Swift.max(end - start, 0) }

    func odd(_ k: Int) -> Bool { (levels.at(k) ?? 0) % 2 == 1 }

    /// Leading edge (where its direction begins) of character `k` of the line.
    func leading(_ k: Int) -> Double? { edges.at(k).map { odd(k) ? $0.right : $0.left } }

    /// Trailing edge (where its direction ends) of character `k` of the line.
    func trailing(_ k: Int) -> Double? { edges.at(k).map { odd(k) ? $0.left : $0.right } }

    /// Graphemes on the line as (first, end) character indices from the line start.
    func graphemes() -> [(Int, Int)] {
        let n = len
        var out: [(Int, Int)] = []
        var k = 0
        while k < n {
            var e = k + 1
            while e < n && !(boundary.at(e) ?? true) { e += 1 }
            out.append((k, e))
            k = e
        }
        return out
    }

    /// Visual extent of characters `from..<to` (k from the line start).
    func graphemeBox(_ from: Int, _ to: Int) -> (Double, Double)? {
        guard from <= to, to <= edges.count else { return nil }
        let es = edges[from ..< to]
        let l = es.map(\.left).reduce(Double.infinity) { $0.rustMin($1) }
        let r = es.map(\.right).reduce(-Double.infinity) { $0.rustMax($1) }
        return l <= r ? (l, r) : nil
    }

    /// Visual x intervals covering paragraph characters `from..<to` on this line, left to right and merged
    /// where they touch. Bidi text can make a logical range several boxes.
    public func spans(_ from: Int, _ to: Int) -> [(Double, Double)] {
        let a = Swift.max(from, start) - start
        let b = Swift.max(Swift.min(to, end) - start, 0)
        let hi = Swift.max(a, b)
        guard a <= edges.count, hi <= edges.count else { return [] }
        return mergeSpans(edges[a ..< hi].map { ($0.left, $0.right) })
    }

    /// Horizontal extent of paragraph characters `from..<to` on this line.
    public func span(_ from: Int, _ to: Int) -> (Double, Double)? {
        let s = spans(from, to)
        guard let f = s.first, let l = s.last else { return nil }
        return (f.0, l.1)
    }

    /// Caret stops left to right: (x, character offset in the paragraph, affinity).
    func visualStops() -> [(Double, Int, Affinity)] {
        var gs: [(Double, Double, Int, Int, Bool)] = graphemes().compactMap { a, b in graphemeBox(a, b).map { ($0.0, $0.1, a, b, odd(a)) } }
        gs.sort { $0.0 < $1.0 }
        var out: [(Double, Int, Affinity)] = []
        func push(_ s: (Double, Int, Affinity)) {
            if let l = out.last, abs(l.0 - s.0) < 0.01 && l.1 == s.1 { return }
            out.append(s)
        }
        for (l, r, a, b, rtl) in gs {
            let (a, b) = (start + a, start + b)
            if rtl {
                push((l, b, .upstream))
                push((r, a, .downstream))
            } else {
                push((l, a, .downstream))
                push((r, b, .upstream))
            }
        }
        if out.isEmpty { out.append((caretX.first ?? 0, start, .downstream)) }
        return out
    }
}

/// Non-empty x intervals sorted left to right, merged where they touch.
func mergeSpans(_ v: [(Double, Double)]) -> [(Double, Double)] {
    let v = v.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
    var out: [(Double, Double)] = []
    for e in v {
        if let last = out.last, e.0 <= last.1 + 0.01 {
            out[out.count - 1].1 = last.1.rustMax(e.1)
        } else {
            out.append(e)
        }
    }
    return out
}

extension TextLayout {
    /// The line containing a caret position (the later line at a soft wrap boundary).
    public func lineOf(_ pos: CaretPos) -> Int? { lineOf(pos, .downstream) }

    /// The line containing a caret position: at a soft wrap boundary, the earlier line for an upstream caret
    /// and the later one for a downstream caret.
    public func lineOf(_ pos: CaretPos, _ affinity: Affinity) -> Int? {
        var found: Int?
        for (i, l) in lines.enumerated() where l.para == pos.para && pos.ch >= l.start && pos.ch <= l.end {
            if affinity == .upstream && pos.ch == l.end && pos.ch > l.start { return i }
            found = i
            if pos.ch < l.end { break }
        }
        return found
            ?? lines.lastIndex { $0.para == pos.para && $0.start <= pos.ch }
            ?? lines.lastIndex { $0.para == pos.para }
    }

    /// Caret line segment (x, top, bottom) in shape-local, unrotated coordinates (downstream).
    public func caret(_ pos: CaretPos) -> (x: Double, top: Double, bottom: Double)? { caretAt(pos, .downstream) }

    /// Caret line segment for a position and affinity: downstream at the leading edge of the character after
    /// the boundary, upstream at the trailing edge of the one before.
    public func caretAt(_ pos: CaretPos, _ affinity: Affinity) -> (x: Double, top: Double, bottom: Double)? {
        guard let li = lineOf(pos, affinity), let l = lines.at(li) else { return nil }
        let k = Swift.min(Swift.max(pos.ch, l.start), Swift.max(l.end, l.start)) - l.start
        var x: Double?
        switch affinity {
        case .downstream where k < l.len: x = l.leading(k)
        case .upstream where k > 0: x = l.trailing(k - 1)
        default: x = nil
        }
        guard let x = x ?? l.caretX.at(k) ?? l.caretX.last else { return nil }
        return (x, l.top, l.bottom)
    }

    /// Nearest caret position for a point.
    public func hit(_ p: Point) -> CaretPos { hitAffinity(p).0 }

    /// Nearest caret position for a point, with the affinity that keeps the caret on the side of the
    /// character that was hit (bidi text has two carets at a direction change).
    public func hitAffinity(_ p: Point) -> (CaretPos, Affinity) {
        var best: LineInfo?
        for l in lines where p.y >= l.top && p.y < l.bottom {
            // In multi-column bodies pick the line whose column contains x.
            if best == nil || p.x >= l.extent.left.rustMin(l.caretX.first ?? l.extent.left) - 4 { best = l }
        }
        let l: LineInfo
        if let b = best {
            l = b
        } else if let f = lines.first, p.y < f.top {
            l = f
        } else if let z = lines.last {
            l = z
        } else {
            return (CaretPos(para: 0, ch: 0), .downstream)
        }
        var gs: [(Double, Double, Int, Int, Bool)] = l.graphemes().compactMap { a, b in l.graphemeBox(a, b).map { ($0.0, $0.1, a, b, l.odd(a)) } }
        if gs.isEmpty { return (CaretPos(para: l.para, ch: l.start), .downstream) }
        gs.sort { $0.0 < $1.0 }
        let g: (Double, Double, Int, Int, Bool)
        let leftHalf: Bool
        if let h = gs.first(where: { p.x >= $0.0 && p.x <= $0.1 && $0.1 > $0.0 }) {
            (g, leftHalf) = (h, p.x < (h.0 + h.1) / 2)
        } else if let f = gs.first, p.x < f.0 {
            (g, leftHalf) = (f, true)
        } else if let z = gs.last, p.x > z.1 {
            (g, leftHalf) = (z, false)
        } else if let near = gs.min(by: { abs(($0.0 + $0.1) / 2 - p.x) < abs(($1.0 + $1.1) / 2 - p.x) }) {
            // Between zero-width graphemes: the nearest one.
            (g, leftHalf) = (near, p.x < (near.0 + near.1) / 2)
        } else {
            return (CaretPos(para: l.para, ch: l.start), .downstream)
        }
        let (_, _, a, b, rtl) = g
        let before = CaretPos(para: l.para, ch: l.start + a)
        let after = CaretPos(para: l.para, ch: l.start + b)
        // The leading half of a character puts the caret before it, the trailing half after it.
        return leftHalf != rtl ? (before, .downstream) : (after, .upstream)
    }

    /// Move a caret one grapheme: logically (`forward` = towards the end of the text, crossing paragraphs)
    /// or visually (`forward` = to the right on screen, continuing on the next or previous line in the
    /// paragraph's direction at the line's edge).
    public func moveCaret(_ pos: CaretPos, _ affinity: Affinity, forward: Bool, _ mode: MoveMode) -> (CaretPos, Affinity) {
        if mode == .visual, let li = lineOf(pos, affinity), let l = lines.at(li) {
            let stops = l.visualStops()
            let curX = caretAt(pos, affinity)?.x ?? 0
            let idx = stops.firstIndex { $0.1 == pos.ch && $0.2 == affinity }
                ?? stops.firstIndex { $0.1 == pos.ch }
                ?? stops.indices.min { abs(stops[$0].0 - curX) < abs(stops[$1].0 - curX) }
            if let idx {
                var j = idx
                while true {
                    let nj = forward ? j + 1 : j - 1
                    guard nj >= 0, let s = stops.at(nj) else { break }
                    // Skip stops that wouldn't move the caret on screen or in the text.
                    if s.1 != pos.ch && abs(s.0 - curX) > 0.01 { return (CaretPos(para: l.para, ch: s.1), s.2) }
                    j = nj
                }
            }
            // Off the line's edge: on to the neighbouring line in reading order.
            let logicalForward = forward != l.rtl
            let target = logicalForward ? li + 1 : li - 1
            guard target >= 0, let t = lines.at(target) else { return (pos, affinity) }
            if logicalForward { return (CaretPos(para: t.para, ch: t.start), .downstream) }
            return (CaretPos(para: t.para, ch: t.end), t.para == l.para ? .upstream : .downstream)
        }
        guard let b = boundaries.at(pos.para) else { return (pos, affinity) }
        let len = Swift.max(b.count - 1, 0)
        let ch = Swift.min(pos.ch, len)
        let next: Int? = forward
            ? (ch < len ? (ch + 1 ... len).first { b.at($0) ?? true } : nil)
            : (0 ..< ch).reversed().first { b.at($0) ?? true }
        if let k = next { return (CaretPos(para: pos.para, ch: k), .downstream) }
        if forward && pos.para + 1 < boundaries.count { return (CaretPos(para: pos.para + 1, ch: 0), .downstream) }
        if !forward && pos.para > 0 {
            let prev = pos.para - 1
            return (CaretPos(para: prev, ch: Swift.max((boundaries.at(prev)?.count ?? 1) - 1, 0)), .downstream)
        }
        return (CaretPos(para: pos.para, ch: ch), .downstream)
    }

    /// Selection highlight rectangles between two positions: per line, the union of the visual boxes of the
    /// selected characters (one logical range can be several boxes in bidi text).
    public func selectionRects(_ a: CaretPos, _ b: CaretPos) -> [Rect] {
        let (s, e) = a <= b ? (a, b) : (b, a)
        var out: [Rect] = []
        for l in lines {
            let lp = CaretPos(para: l.para, ch: l.start)
            let le = CaretPos(para: l.para, ch: l.end)
            if le < s || lp > e { continue }
            let from = s > lp ? s.ch : l.start
            let to = e < le ? e.ch : l.end
            var spans = l.spans(from, to)
            // Selecting across a paragraph end shows a small extra box for the newline, at the paragraph's
            // end side.
            if e.para > l.para && to == l.end {
                let endX = l.caretX.last ?? l.extent.right
                spans.append(l.rtl ? (endX - 6, endX) : (endX, endX + 6))
                spans = mergeSpans(spans)
            }
            for (x0, x1) in spans where x1 > x0 { out.append(Rect(x0, l.top, x1, l.bottom)) }
        }
        return out
    }

    /// Underlines for text an input method is composing, from `a` to `b`: (x0, x1, y) per visual span, a
    /// little below each line's baseline. A composition that wraps gets one underline per line.
    public func compositionUnderlines(_ a: CaretPos, _ b: CaretPos) -> [(Double, Double, Double)] {
        let (s, e) = a <= b ? (a, b) : (b, a)
        var out: [(Double, Double, Double)] = []
        if s == e { return out }
        for l in lines {
            let lp = CaretPos(para: l.para, ch: l.start)
            let le = CaretPos(para: l.para, ch: l.end)
            if le <= s || lp >= e { continue }
            let from = s > lp ? s.ch : l.start
            let to = e < le ? e.ch : l.end
            // Under the baseline, in the descent, never below the line.
            let y = (l.baseline + (l.bottom - l.baseline) * 0.35).rustMin(l.bottom)
            for (x0, x1) in l.spans(from, to) where x1 > x0 { out.append((x0, x1, y)) }
        }
        return out
    }

    /// Vertical caret movement: the position on the line above/below closest to `x`.
    public func vertical(_ pos: CaretPos, down: Bool, _ x: Double) -> CaretPos { verticalAffine(pos, .downstream, down: down, x).0 }

    /// The line a caret is on. An upstream caret at the start of a soft-wrapped line (where End leaves it,
    /// after the previous line's trailing spaces) belongs to the line before.
    public func lineIndex(_ pos: CaretPos, _ affinity: Affinity) -> Int? {
        if affinity == .upstream && pos.ch > 0 && lines.count >= 2 {
            for i in 0 ..< lines.count - 1 {
                let (a, b) = (lines[i], lines[i + 1])
                if b.para == pos.para && a.para == pos.para && b.start == pos.ch { return i }
            }
        }
        return lineOf(pos, affinity)
    }

    /// Up/Down from a caret with its affinity: the position on the line above/below nearest `x`.
    public func verticalAffine(_ pos: CaretPos, _ affinity: Affinity, down: Bool, _ x: Double) -> (CaretPos, Affinity) {
        guard let li = lineIndex(pos, affinity) else { return (pos, affinity) }
        let target = down ? li + 1 : li - 1
        guard target >= 0, let l = lines.at(target) else { return (pos, affinity) }
        var h = hit(Point(x, (l.top + l.bottom) / 2))
        if h.para != l.para { h.para = l.para }
        h.ch = Swift.min(Swift.max(h.ch, l.start), Swift.max(l.end, l.start))
        return (h, .downstream)
    }

    /// Start/end of the visual line containing `pos` (logical: Home/End).
    public func lineBounds(_ pos: CaretPos) -> (CaretPos, CaretPos) { lineBounds(pos, .downstream) }

    /// Start/end of the visual line a caret with this affinity is on.
    public func lineBounds(_ pos: CaretPos, _ affinity: Affinity) -> (CaretPos, CaretPos) {
        guard let i = lineIndex(pos, affinity), let l = lines.at(i) else { return (pos, pos) }
        return (CaretPos(para: l.para, ch: l.start), CaretPos(para: l.para, ch: l.end))
    }

    /// Where End puts the caret: after a soft wrap, past the line's trailing spaces at the start of the next
    /// line with upstream affinity (so it is still drawn on this line), else the end of the paragraph.
    public func lineEndCaret(_ pos: CaretPos, _ affinity: Affinity) -> (CaretPos, Affinity) {
        guard let li = lineIndex(pos, affinity), let l = lines.at(li) else { return (pos, .downstream) }
        if let n = lines.at(li + 1), n.para == l.para, n.start > l.start { return (CaretPos(para: l.para, ch: n.start), .upstream) }
        return (CaretPos(para: l.para, ch: l.end), .downstream)
    }

    /// The caret to draw (x, top, bottom): an upstream caret after a soft wrap is drawn at the end of the
    /// line it belongs to.
    public func caretDrawn(_ pos: CaretPos, _ affinity: Affinity) -> (x: Double, top: Double, bottom: Double)? {
        guard let li = lineIndex(pos, affinity), let l = lines.at(li) else { return nil }
        if pos.ch > l.end {
            guard let x = l.caretX.last else { return nil }
            return (x, l.top, l.bottom)
        }
        return caretAt(pos, affinity)
    }

    /// Bounding box of all lines (shape-local).
    public func bounds() -> Rect {
        var r: Rect?
        for l in lines {
            let lr = Rect(l.extent.left, l.top, l.extent.right.rustMax(l.extent.left), l.bottom)
            r = r.map { $0.union(lr) } ?? lr
        }
        return r ?? inner
    }
}
