// DCAppModel — the text formatting choices of the inspector's Text tab without a window: the Font and
// Paragraph groups of deckcraft's Home ribbon (`font_group`, `paragraph_group`, `font_families` in
// `crates/ui-egui/src/ribbon.rs`), Format Shape ▸ Text Options (`panes.rs`), Text Effects ▸ Transform, and
// the kept-draft rule of `widgets::text_draft`. MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors.
import DCCore
import DCEngine
import DCGeometry
import DCModel

public enum InspectorText {
    /// `text_draft`: the typed draft while the stored value is still what it started from, else the stored
    /// value (another document, a reorder or an undo changed it).
    public static func draft(_ stored: (base: String, text: String)?, _ current: String) -> String {
        if let s = stored, s.base == current { return s.text }
        return current
    }

    /// `font_families`: the theme's heading and body fonts first (one when they are the same), then
    /// `installed`, without repeats.
    public static func fontFamilies(_ doc: DocState?, installed: [String]) -> (theme: [String], all: [String]) {
        var theme: [String] = []
        if let m = doc?.doc.masters.first {
            theme = [m.theme.fonts.major.latin]
            if m.theme.fonts.minor.latin != m.theme.fonts.major.latin { theme.append(m.theme.fonts.minor.latin) }
        }
        var out: [String] = []
        for f in theme + installed where out.last != f { out.append(f) }
        return (theme, out)
    }

    /// The Font Size menu: the engine's sizes, then 72–96.
    public static var sizes: [Double] { FormatCommands.sizes + [72, 80, 88, 96] }

    public static let spacings: [(String, Double)] = [("Very Tight", -3), ("Tight", -1.5), ("Normal", 0), ("Loose", 3), ("Very Loose", 6)]
    public static let cases: [(String, String)] = [
        ("Sentence case.", "sentence"), ("lowercase", "lower"), ("UPPERCASE", "upper"), ("Capitalize Each Word", "title"), ("tOGGLE cASE", "toggle"),
    ]
    public static let bulletChars = ["•", "○", "■", "□", "◆", "➢", "✓", "–", "★"]
    public static let numberings: [(String, String)] = [
        ("1. 2. 3.", "arabicPeriod"), ("1) 2) 3)", "arabicParenR"), ("I. II. III.", "romanUcPeriod"), ("i. ii. iii.", "romanLcPeriod"),
        ("A. B. C.", "alphaUcPeriod"), ("a) b) c)", "alphaLcParenR"), ("a. b. c.", "alphaLcPeriod"),
    ]
    public static let lineSpacings: [Double] = [1.0, 1.5, 2.0, 2.5, 3.0]
    public static let directions: [(String, String)] = [("Horizontal", "horizontal"), ("Rotate all text 90°", "rotate90"), ("Rotate all text 270°", "rotate270"), ("Stacked", "stacked")]
    public static let anchors: [(String, String)] = [("Top", "top"), ("Middle", "middle"), ("Bottom", "bottom")]
    public static let autofits: [(String, String)] = [("Do not Autofit", "none"), ("Shrink text on overflow", "shrink"), ("Resize shape to fit text", "resize")]
    /// The paragraph alignments: label, command, `format.state`'s `align`, SF Symbol.
    public static let aligns: [(String, String, String, String)] = [
        ("Align Left", "format.alignLeft", "l", "text.alignleft"), ("Center", "format.alignCenter", "ctr", "text.aligncenter"),
        ("Align Right", "format.alignRight", "r", "text.alignright"), ("Justify", "format.justify", "just", "text.justify"),
    ]
    /// The character styles: label, command, `format.state` key, SF Symbol.
    public static let styles: [(String, String, String, String)] = [
        ("Bold", "format.bold", "bold", "bold"), ("Italic", "format.italic", "italic", "italic"),
        ("Underline", "format.underline", "underline", "underline"), ("Strikethrough", "format.strikethrough", "strike", "strikethrough"),
        ("Superscript", "format.superscript", "superscript", "textformat.superscript"), ("Subscript", "format.subscript", "subscript", "textformat.subscript"),
    ]

    /// The text box's insets with PowerPoint's defaults (left, right, top, bottom in points).
    public static func margins(_ sh: Shape) -> [(label: String, key: String, value: Double)] {
        let b = sh.text?.body ?? BodyProps.default
        return [("Left", "left", b.insetL ?? 7.2), ("Right", "right", b.insetR ?? 7.2), ("Top", "top", b.insetT ?? 3.6), ("Bottom", "bottom", b.insetB ?? 3.6)]
    }

    /// The anchor stored on the text box (`format.anchor`'s names).
    public static func anchor(_ sh: Shape) -> String? {
        switch sh.text?.body.anchor {
        case .top?, .middle?, .bottom?: sh.text?.body.anchor?.rawValue
        default: nil
        }
    }

    /// The selected shape's text warp (`selected_warp`).
    public static func warp(_ st: DocState?) -> String? {
        guard let st, let id = st.selection.text?.shape ?? st.selection.shapes.first else { return nil }
        return st.shape(id)?.text?.body.warp
    }

    /// Text Effects ▸ Transform: the Follow Path presets, then the warps.
    public static var followPaths: [Warp.PresetInfo] { Warp.catalog.filter { Warp.isFollow($0.id) } }
    public static var warps: [Warp.PresetInfo] { Warp.catalog.filter { !Warp.isFollow($0.id) } }
}
