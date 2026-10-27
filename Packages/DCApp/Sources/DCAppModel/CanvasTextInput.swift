// DCAppModel — in-place text editing as the Mac's text system sees it: the edited text as one UTF-16
// document (what `NSTextInputClient` ranges count in), and the routing of its calls — typing, an input
// method's marked text and its commit, replacement ranges — to the engine's text commands. The canvas's
// `NSTextInputClient` view is a thin shell over this, so the behaviour is tested without a window.
//
// Behaviour from deckcraft `crates/ui-egui/src/lib.rs` (`keyboard`'s Text arm, `ime_event`,
// `apply_ime_event`) and `canvas.rs` (`ime_area`, `text_marks`) (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). deckcraft feeds egui's IME events (preedit, commit, delete-surrounding) to the
// engine; AppKit's equivalents are `setMarkedText`, `insertText` and replacement ranges.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import DCText
import Foundation

/// The text being edited, flattened: paragraphs joined by "\n" (a soft line break, U+000B, reads as a
/// newline too, as the engine's IME surrounding text has it). Positions convert between the engine's
/// (paragraph, character) — characters are Unicode scalars — and UTF-16 offsets.
public struct CanvasTextDocument: Sendable, Equatable {
    /// The UTF-16 code units of the flattened text.
    public let units: [UInt16]
    /// Per paragraph: the UTF-16 offset of each character, and one past the last.
    let offsets: [[Int]]

    public init(_ body: TextBody?) {
        var units: [UInt16] = []
        var offsets: [[Int]] = []
        let paras = body?.paragraphs ?? []
        for (i, p) in (paras.isEmpty ? [Paragraph()] : paras).enumerated() {
            if i > 0 { units.append(0x0A) }
            var o: [Int] = []
            for r in p.runs {
                for ch in r.content.unicodeScalars {
                    o.append(units.count)
                    let c: Unicode.Scalar = ch == "\u{0B}" ? "\n" : ch
                    units.append(contentsOf: Array(String(Character(c)).utf16))
                }
            }
            o.append(units.count)
            offsets.append(o)
        }
        self.units = units
        self.offsets = offsets
    }

    /// The text being edited in `st`, or nil when nothing is.
    public init?(_ st: DocState) {
        guard let t = st.selection.text else { return nil }
        self.init(TextCommands.bodyOf(st, t))
    }

    public var string: String { String(decoding: units, as: UTF16.self) }
    public var length: Int { units.count }

    /// The UTF-16 offset of `p`, clamped into the text.
    public func offset(_ p: TextPoint) -> Int {
        guard let last = offsets.last else { return 0 }
        guard let para = offsets.at(max(p.para, 0)) else { return last.last ?? 0 }
        return para.at(max(p.char, 0)) ?? para.last ?? 0
    }

    /// The position at UTF-16 offset `u`: inside a surrogate pair it is the character's start; a paragraph
    /// break belongs to the end of the paragraph before it.
    public func point(_ u: Int) -> TextPoint {
        let u = min(max(u, 0), length)
        for (pi, para) in offsets.enumerated() {
            guard let end = para.last else { continue }
            if u <= end || pi == offsets.count - 1 {
                // The last character starting at or before `u`.
                var ch = 0
                for (ci, o) in para.enumerated() where o <= u { ch = ci }
                return TextPoint(pi, min(ch, para.count - 1))
            }
        }
        return TextPoint(0, 0)
    }

    /// The UTF-16 range between two positions.
    public func range(_ a: TextPoint, _ b: TextPoint) -> NSRange {
        let (x, y) = (offset(a), offset(b))
        return NSRange(location: min(x, y), length: abs(y - x))
    }

    /// The text of a UTF-16 range, clamped to the document (`attributedSubstring`).
    public func substring(_ r: NSRange) -> (String, NSRange)? {
        guard r.location != NSNotFound else { return nil }
        let lo = min(max(r.location, 0), length)
        let hi = min(max(r.location + max(r.length, 0), lo), length)
        return (String(decoding: units[lo ..< hi], as: UTF16.self), NSRange(location: lo, length: hi - lo))
    }

    /// Characters (Unicode scalars) in the first `utf16` units of `text`, for the input method's selected
    /// range within its marked text.
    public static func scalarCount(_ text: String, utf16 n: Int) -> Int {
        var count = 0, units = 0
        for s in text.unicodeScalars {
            if units >= n { break }
            units += UTF16.width(s)
            count += 1
        }
        return count
    }
}

/// What `NSTextInputClient` asks and does, against the session.
public enum CanvasTextInput {
    /// The selected range in the edited text (`selectedRange`); nil when no text is being edited.
    public static func selectedRange(_ st: DocState) -> NSRange? {
        guard let t = st.selection.text, let d = CanvasTextDocument(st) else { return nil }
        return d.range(t.anchor, t.caret)
    }

    /// The input method's marked text (`markedRange`): the composition in the edited text.
    public static func markedRange(_ st: DocState) -> NSRange? {
        guard let c = st.composition, st.selection.text != nil, let d = CanvasTextDocument(st) else { return nil }
        return d.range(c.start, TextPoint(c.start.para, c.start.char &+ c.len))
    }

    /// Select UTF-16 range `r` of the edited text (an input method's replacement range).
    static func select(_ s: Session, _ r: NSRange) throws(EngineError) {
        guard r.location != NSNotFound, let st = s.activeDoc, let d = CanvasTextDocument(st) else { return }
        let a = d.point(r.location), b = d.point(r.location + max(r.length, 0))
        _ = try s.execute("text.select", ["anchor": a.toJSON(), "caret": b.toJSON()])
    }

    /// `setMarkedText`: the input method's preedit replaces the last one in place (#101), underlined, the
    /// part being converted (`selected`, UTF-16 in `text`) drawn thicker. On a selected shape that isn't
    /// being edited the first preedit starts editing it, as typing does. Empty text cancels it.
    @discardableResult
    public static func setMarkedText(_ s: Session, _ text: String, selected: NSRange, replacement: NSRange) throws(EngineError) -> JSON {
        if s.activeDoc?.composition == nil, s.activeDoc?.selection.text != nil, replacement.location != NSNotFound {
            try select(s, replacement)
        }
        var active: (Int, Int)?
        if selected.location != NSNotFound, selected.length > 0 {
            let a = CanvasTextDocument.scalarCount(text, utf16: selected.location)
            let b = CanvasTextDocument.scalarCount(text, utf16: selected.location + selected.length)
            if b > a { active = (a, b) }
        }
        return try s.composeText(text, active)
    }

    /// `insertText`: an input method's commit replaces its composition as one undo step; otherwise it is
    /// typing, which on one selected shape starts editing it and replaces its text (PowerPoint's
    /// behaviour). A replacement range (reconversion, the accent menu) is selected first.
    @discardableResult
    public static func insertText(_ s: Session, _ text: String, replacement: NSRange) throws(EngineError) -> JSON {
        guard let st = s.activeDoc else { return ["handled": false] }
        if st.composition != nil { return try s.commitText(text) }
        if st.selection.text != nil, replacement.location != NSNotFound { try select(s, replacement) }
        if text.isEmpty { return ["handled": false] }
        guard st.selection.text != nil || st.selection.shapes.count == 1 else { return ["handled": false] }
        return try s.typeText(text)
    }

    /// `unmarkText`: the input method ended its composition itself; its text stays.
    public static func unmarkText(_ s: Session) { s.endComposition() }

    /// The UTF-16 offset of the edited text under slide point `p` (`characterIndex(for:)`).
    public static func characterIndex(_ st: DocState, _ p: Point) -> Int? {
        guard let t = st.selection.text, let d = CanvasTextDocument(st) else { return nil }
        let (para, ch) = TextCommands.textPosAt(st, t, p)
        return d.offset(TextPoint(para, ch))
    }

    /// Where UTF-16 range `r` of the edited text is drawn, as a slide-space box (`firstRect`): the first
    /// line of its selection, or the insertion point's line for an empty range. nil for notes.
    public static func firstRect(_ st: DocState, _ r: NSRange) -> Rect? {
        guard let t = st.selection.text, !t.notes, let d = CanvasTextDocument(st), r.location != NSNotFound else { return nil }
        let a = d.point(r.location), b = d.point(r.location + max(r.length, 0))
        if let (l, m) = TextCommands.textFrame(st, t) {
            if a != b, let first = l.selectionRects(CaretPos(para: a.para, ch: a.char), CaretPos(para: b.para, ch: b.char)).first {
                return quadBounds(m, first)
            }
            if let c = l.caretDrawn(CaretPos(para: a.para, ch: a.char), .downstream) {
                return quadBounds(m, Rect(c.x, c.top, c.x + 1, c.bottom))
            }
        }
        guard let (top, bottom) = TextCommands.caretLine(st, t) else { return nil }
        return Rect(min(top.x, bottom.x), min(top.y, bottom.y), max(top.x, bottom.x) + 1, max(top.y, bottom.y))
    }

    /// The slide-space bounds of `r` drawn through `m`.
    static func quadBounds(_ m: Affine, _ r: Rect) -> Rect {
        let q = [Point(r.x0, r.y0), Point(r.x1, r.y0), Point(r.x1, r.y1), Point(r.x0, r.y1)].map { m * $0 }
        let xs = q.map(\.x), ys = q.map(\.y)
        return Rect(xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    /// The text selection of the edited text as slide-space quads (`text_marks`).
    public static func selectionQuads(_ st: DocState, _ t: TextSel) -> [[Point]] {
        guard let (l, m) = TextCommands.textFrame(st, t) else { return [] }
        let (s0, s1) = t.ordered
        return l.selectionRects(CaretPos(para: s0.para, ch: s0.char), CaretPos(para: s1.para, ch: s1.char)).map { r in
            [Point(r.x0, r.y0), Point(r.x1, r.y0), Point(r.x1, r.y1), Point(r.x0, r.y1)].map { m * $0 }
        }
    }

    /// Where an input method composes for the slide (`ime_area`), in slide points: the insertion point's
    /// line while editing, else the one selected shape (typing on it starts editing). nil when there is
    /// nothing to type into.
    public static func imeArea(_ st: DocState) -> Rect? {
        if let t = st.selection.text {
            if t.notes { return nil }
            if let (top, bottom) = TextCommands.caretLine(st, t) {
                return Rect(min(top.x, bottom.x) - 1, min(top.y, bottom.y), max(top.x, bottom.x) + 1, max(top.y, bottom.y))
            }
            guard let sh = st.shape(t.shape) else { return nil }
            return Cmd.xfrmOf(st.doc, st.selection, sh).rect
        }
        guard st.selection.shapes.count == 1, let id = st.selection.shapes.first, let sh = st.shape(id), !sh.isLine else { return nil }
        return Cmd.xfrmOf(st.doc, st.selection, sh).rect
    }
}
