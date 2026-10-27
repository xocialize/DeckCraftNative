// DCApp — the canvas's look in one place: the system's semantic colours for selection, handles, guides and
// text marks (deckcraft's `Tokens` selection/handle/guide/caret colours), and the overlay geometry deckcraft
// draws with (handle radii, the rulers' strip). Sizes that are hit targets on the slide follow deckcraft's
// canvas, not the design tokens: they match the engine's hit tolerance (about 4 screen points).
import AppKit
import DesignScaffold

@MainActor
enum CanvasStyle {
    // MARK: Colours (system semantics: they follow the accent colour, appearance and Increase Contrast)

    /// Selection outlines, the text-editing frame, table cell outline.
    static var selection: NSColor { .controlAccentColor }
    /// Handle fill and outline: a light dot ringed in the accent, legible on any slide.
    static var handleFill: NSColor { .white }
    static var handleStroke: NSColor { .controlAccentColor }
    /// Locked shapes' greyed handles.
    static var lockedHandle: NSColor { .tertiaryLabelColor }
    /// Adjustment and WordArt warp handles: PowerPoint's yellow.
    static var adjustFill: NSColor { .systemYellow }
    static var adjustStroke: NSColor { .systemBrown }
    /// Smart guides while dragging.
    static var smartGuide: NSColor { .systemPink }
    /// Text selection (the system's selected-text colour, translucent over the slide).
    static var textSelection: NSColor { .selectedTextBackgroundColor.withAlphaComponent(0.55) }
    /// Composition underline and the fallback caret.
    static var caret: NSColor { .textColor }
    /// Spelling squiggles: the system's red.
    static var squiggle: NSColor { .systemRed }
    /// Marquee selection.
    static var marqueeFill: NSColor { .controlAccentColor.withAlphaComponent(0.12) }
    static var marqueeStroke: NSColor { .controlAccentColor }
    /// Drawing guides (View › Guides), and the one under the pointer or being dragged.
    static var drawingGuide: NSColor { .secondaryLabelColor }
    static var drawingGuideActive: NSColor { .controlAccentColor }
    /// Gridlines.
    static var grid: NSColor { .black.withAlphaComponent(0.16) }
    /// The surround the slide sits on, and its shadow.
    static var surround: NSColor { .underPageBackgroundColor }
    static var shadow: NSColor { .shadowColor.withAlphaComponent(0.3) }
    /// Rulers.
    static var rulerFill: NSColor { .windowBackgroundColor }
    static var rulerTick: NSColor { .tertiaryLabelColor }
    static var rulerLabel: NSColor { .secondaryLabelColor }
    static var rulerMarker: NSColor { .labelColor }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tagFill: NSColor { .windowBackgroundColor }

    // MARK: Geometry (deckcraft's canvas)

    /// Resize and line-end handles.
    static let handleRadius: CGFloat = 4.5
    static let lockedHandleRadius: CGFloat = 4
    static let rotateHandleRadius: CGFloat = 6
    static let siteRadius: CGFloat = 3.5
    static let glueRadius: CGFloat = 5
    /// Edit Points' vertex and control-handle squares.
    static let vertexSide: CGFloat = 7
    static let controlSide: CGFloat = 6
    /// The rulers' strips.
    static let ruler: CGFloat = 16
    /// The canvas's shadow under the slide.
    static let shadowBlur: CGFloat = 8
    static let shadowOffset: CGFloat = 2
    /// Dash patterns (on, off) for the text-editing frame, guides and smart guides.
    static let editDash: [CGFloat] = [4, 3]
    static let guideDash: [CGFloat] = [4, 3]
    static let smartDash: [CGFloat] = [5, 3]
    /// Type on the canvas.
    static var rulerFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize - 3) }
    static var tagFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
    static var emptyFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize * 1.7) }
    static let tagRadius: CGFloat = Tokens.Radius.control / 2
    static let tagInset: CGFloat = Tokens.Space.xs - 1
}
