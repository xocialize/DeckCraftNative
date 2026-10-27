// DCAppModel — presenter view's speaker notes: each paragraph's bullet or number, numbered as on a slide, and
// its runs with bold, italic, underline and strike-through, at the pane's size (`presenter_notes` in deckcraft
// `crates/ui-egui/src/show.rs`, which draws them with `notes::view`; `bullets` and `format` in `notes.rs`, MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The window side lays them out with AttributedString.
import DCModel
import DCText

/// One run of notes text and how it looks.
public struct ShowNotesRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    /// Points, scaled from the pane's size by the run's own size against 12 pt.
    public var size: Double
}

/// One paragraph of notes.
public struct ShowNotesParagraph: Equatable, Sendable {
    /// The bullet or number, nil for none.
    public var marker: String?
    /// Outline level (0 is the first).
    public var level: Int
    public var runs: [ShowNotesRun]
}

public enum ShowNotes {
    /// Each paragraph's bullet or number, numbered per level and restarting after an unnumbered paragraph at the
    /// same or a lower level (`bullets`).
    public static func markers(_ body: TextBody) -> [String?] {
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
                let (n, o) = numbering[lvl].addingReportingOverflow(1)
                numbering[lvl] = o ? UInt32.max : n
                let start = startAt == 0 ? 0 : startAt - 1
                let (v, o2) = start.addingReportingOverflow(numbering[lvl])
                return autonum(scheme, o2 ? UInt32.max : v)
            case .picture?: return "•"
            }
        }
    }

    /// The notes as paragraphs for a pane whose 12-pt text is `size` points; nil when the notes are empty
    /// ("No notes.").
    public static func paragraphs(_ body: TextBody, size: Double) -> [ShowNotesParagraph]? {
        if body.text.isEmpty { return nil }
        let marks = markers(body)
        return body.paragraphs.enumerated().map { i, p in
            ShowNotesParagraph(marker: marks.at(i) ?? nil, level: Int(p.level), runs: p.runs.map { r in
                let pr = r.props
                var s = size
                if let pt = pr.size, pt.isFinite, pt > 0 { s = Swift.min(Swift.max(size * pt / 12, size * 0.75), size * 2) }
                var strike = false
                if let k = pr.strike, k == .single || k == .double { strike = true }
                return ShowNotesRun(
                    text: r.content, bold: pr.bold == true, italic: pr.italic == true, underline: pr.underline.map { $0 != "none" } ?? false,
                    strike: strike, size: s
                )
            })
        }
    }
}
