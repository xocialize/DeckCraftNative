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

    public static let spacings: [(String, Double)] = [(String(localized: "Very Tight", bundle: .module, comment: "character spacing"), -3), (String(localized: "Tight", bundle: .module, comment: "character spacing"), -1.5), (String(localized: "Normal", bundle: .module, comment: "character spacing"), 0), (String(localized: "Loose", bundle: .module, comment: "character spacing"), 3), (String(localized: "Very Loose", bundle: .module, comment: "character spacing"), 6)]
    public static let cases: [(String, String)] = [
        (String(localized: "Sentence case.", bundle: .module, comment: "Change Case option; keep the example casing"), "sentence"), (String(localized: "lowercase", bundle: .module, comment: "Change Case option; written in lower case"), "lower"), (String(localized: "UPPERCASE", bundle: .module, comment: "Change Case option; written in upper case"), "upper"), (String(localized: "Capitalize Each Word", bundle: .module, comment: "Change Case option; each word capitalized"), "title"), (String(localized: "tOGGLE cASE", bundle: .module, comment: "Change Case option; written in toggled case"), "toggle"),
    ]
    public static let bulletChars = ["•", "○", "■", "□", "◆", "➢", "✓", "–", "★"]
    public static let numberings: [(String, String)] = [
        ("1. 2. 3.", "arabicPeriod"), ("1) 2) 3)", "arabicParenR"), ("I. II. III.", "romanUcPeriod"), ("i. ii. iii.", "romanLcPeriod"),
        ("A. B. C.", "alphaUcPeriod"), ("a) b) c)", "alphaLcParenR"), ("a. b. c.", "alphaLcPeriod"),
    ]
    public static let lineSpacings: [Double] = [1.0, 1.5, 2.0, 2.5, 3.0]
    public static let directions: [(String, String)] = [(String(localized: "Horizontal", bundle: .module, comment: "text direction"), "horizontal"), (L10n.text("Rotate all text 90°"), "rotate90"), (L10n.text("Rotate all text 270°"), "rotate270"), (String(localized: "Stacked", bundle: .module, comment: "text direction"), "stacked")]
    public static let anchors: [(String, String)] = [(String(localized: "Top", bundle: .module, comment: "vertical text alignment"), "top"), (String(localized: "Middle", bundle: .module, comment: "vertical text alignment"), "middle"), (String(localized: "Bottom", bundle: .module, comment: "vertical text alignment"), "bottom")]
    public static let autofits: [(String, String)] = [(L10n.text("Do not Autofit"), "none"), (L10n.text("Shrink text on overflow"), "shrink"), (L10n.text("Resize shape to fit text"), "resize")]
    /// The paragraph alignments: label, command, `format.state`'s `align`, SF Symbol.
    public static let aligns: [(String, String, String, String)] = [
        (L10n.text("Align Left"), "format.alignLeft", "l", "text.alignleft"), (String(localized: "Center", bundle: .module, comment: "paragraph alignment"), "format.alignCenter", "ctr", "text.aligncenter"),
        (L10n.text("Align Right"), "format.alignRight", "r", "text.alignright"), (String(localized: "Justify", bundle: .module, comment: "paragraph alignment"), "format.justify", "just", "text.justify"),
    ]
    /// The character styles: label, command, `format.state` key, SF Symbol.
    public static let styles: [(String, String, String, String)] = [
        (L10n.text("Bold"), "format.bold", "bold", "bold"), (L10n.text("Italic"), "format.italic", "italic", "italic"),
        (L10n.text("Underline"), "format.underline", "underline", "underline"), (L10n.text("Strikethrough"), "format.strikethrough", "strike", "strikethrough"),
        (L10n.text("Superscript"), "format.superscript", "superscript", "textformat.superscript"), (L10n.text("Subscript"), "format.subscript", "subscript", "textformat.subscript"),
    ]

    /// The text box's insets with PowerPoint's defaults (left, right, top, bottom in points).
    public static func margins(_ sh: Shape) -> [(label: String, key: String, value: Double)] {
        let b = sh.text?.body ?? BodyProps.default
        return [(String(localized: "Left", bundle: .module, comment: "text box inset"), "left", b.insetL ?? 7.2), (String(localized: "Right", bundle: .module, comment: "text box inset"), "right", b.insetR ?? 7.2), (String(localized: "Top", bundle: .module, comment: "text box inset"), "top", b.insetT ?? 3.6), (String(localized: "Bottom", bundle: .module, comment: "text box inset"), "bottom", b.insetB ?? 3.6)]
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
