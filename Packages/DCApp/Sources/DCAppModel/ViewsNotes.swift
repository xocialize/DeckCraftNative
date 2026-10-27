// DCAppModel — speaker notes as the notes pane and Notes Page edit them: a formatted draft that typed
// text is mapped onto, each paragraph's indents, and its bullet or number. Port of the window-free parts
// of deckcraft `crates/ui-egui/src/notes.rs` (`Draft`, `typed`, `px`, `indents`, `bullets`; MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The drawing is AppKit's (NSTextView).
import DCModel
import DCText

/// Notes being edited: the text in the editor and the formatted notes it stands for (`Draft`).
public struct NotesDraft: Equatable, Sendable {
    public var text: String
    public var body: TextBody
    /// Edited since it was saved.
    public var edited: Bool

    public init(_ body: TextBody) {
        text = body.text
        self.body = body
        edited = false
    }

    /// The editor's text changed to `text`: the formatted body follows (typed text takes the formatting
    /// where it lands; the rest keeps its own).
    public mutating func type(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        TextEdit.replaceText(&body, text)
        edited = true
    }
}

public enum NotesLogic {
    /// `typed`: `body` as it reads with `text` typed in, or nil when that can't be mapped onto it.
    public static func typed(_ body: TextBody, _ text: String) -> TextBody? {
        var b = body
        TextEdit.replaceText(&b, text)
        return b.text == text ? b : nil
    }

    /// `px`: a length in points from the file at `k` pixels per point, bounded (0–400 pt).
    public static func px(_ pt: Double, _ k: Double) -> Double {
        pt.isFinite ? Swift.min(Swift.max(pt, 0), 400) * k : 0
    }

    /// `indents`: where a paragraph's first line and its other lines start (points). A level without its
    /// own margin is indented 36 pt per level, as in the default notes master.
    public static func indents(_ p: Paragraph) -> (first: Double, rest: Double) {
        let margin = p.props.marginLeft ?? 36 * Double(Swift.min(p.level, 8))
        return (margin + (p.props.indent ?? 0), margin)
    }

    /// `bullets`: each paragraph's bullet or number, numbered as on a slide (per level, restarting after
    /// an unnumbered paragraph at the same or a lower level).
    public static func bullets(_ body: TextBody) -> [String?] {
        var numbering = [UInt32](repeating: 0, count: 9)
        return body.paragraphs.map { p -> String? in
            let lvl = Int(Swift.min(p.level, 8))
            if p.isEmpty { return nil }
            var auto = false
            if case .autoNum? = p.props.bullet { auto = true }
            for i in lvl ..< numbering.count where i > lvl || !auto { numbering[i] = 0 }
            switch p.props.bullet {
            case nil, .none_?: return nil
            case .char(let c)?: return mapSymbolBullet(c, p.props.bulletFont)
            case .autoNum(let scheme, let startAt)?:
                numbering[lvl] = numbering[lvl] == .max ? .max : numbering[lvl] + 1
                let (n, o) = (startAt == 0 ? 0 : startAt - 1).addingReportingOverflow(numbering[lvl])
                return autonum(scheme, o ? UInt32.max : n)
            case .picture?: return "•"
            }
        }
    }

    /// A run's size in the editor: `base` for 12 pt, scaled by the run's own size within 0.75×–2×.
    public static func runSize(_ props: RunProps, base: Double) -> Double {
        guard let pt = props.size, pt.isFinite, pt > 0 else { return base }
        return Swift.min(Swift.max(base * pt / 12, base * 0.75), base * 2)
    }
}
