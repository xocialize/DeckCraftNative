// DCText — the laid-out text a renderer draws and an editor navigates: glyph runs, decorations, lines with
// caret geometry. Port of the public types of deckcraft crates/text/src/lib.rs (MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors). Coordinates are shape-local points, y down, baselines as
// in deckcraft.
import DCColor
import DCGeometry
import DCModel

/// One glyph placed: its id in the run's face and the pen position of its origin (on the baseline).
public struct PositionedGlyph: Sendable, Equatable {
    public var gid: UInt32
    public var x: Double
    public var y: Double

    public init(gid: UInt32, x: Double, y: Double) {
        self.gid = gid
        self.x = x
        self.y = y
    }
}

/// A run of glyphs in one face, size and colour.
public struct GlyphRun: Sendable {
    public var face: FontFace
    /// Font size in points (after autofit scaling).
    public var size: Double
    public var color: Rgba
    public var glyphs: [PositionedGlyph]
    /// Per glyph: the paragraph character it draws (index, character); empty for bullets.
    public var cells: [(index: Int, char: Unicode.Scalar)]
    /// Draw a heavier stroke because the family has no bold face.
    public var fakeBold: Bool
    /// Slant because the family has no italic face.
    public var fakeItalic: Bool
    public var outline: (color: Rgba, width: Double)?
    /// Paragraph and character range this run covers (hyperlinks, selection colours).
    public var para: Int
    public var chars: (start: Int, end: Int)
    public var link: Bool
    /// Opacity of the fill on top of `color`'s own alpha (0 for no fill).
    public var alpha: Double
    public var gradient: Gradient?
    /// Shadow and glow behind the glyphs (`a:rPr/a:effectLst`).
    public var effects: RunEffects?
    /// East Asian vertical text: each glyph stands upright, turned a quarter turn back about the centre of
    /// its em box (`uprightCentre`).
    public var upright: Bool

    public init(
        face: FontFace, size: Double, color: Rgba, glyphs: [PositionedGlyph], cells: [(index: Int, char: Unicode.Scalar)] = [],
        fakeBold: Bool = false, fakeItalic: Bool = false, outline: (color: Rgba, width: Double)? = nil, para: Int = 0,
        chars: (start: Int, end: Int) = (0, 0), link: Bool = false, alpha: Double = 1, gradient: Gradient? = nil, effects: RunEffects? = nil,
        upright: Bool = false
    ) {
        self.face = face
        self.size = size
        self.color = color
        self.glyphs = glyphs
        self.cells = cells
        self.fakeBold = fakeBold
        self.fakeItalic = fakeItalic
        self.outline = outline
        self.para = para
        self.chars = chars
        self.link = link
        self.alpha = alpha
        self.gradient = gradient
        self.effects = effects
        self.upright = upright
    }

    /// The point an upright glyph at pen position (`x`, `y`) turns about: the centre of its em box (nil
    /// when the run is not upright).
    public func uprightCentre(_ gid: UInt32, _ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        guard upright else { return nil }
        let adv = face.advance(gid) * size / Swift.max(face.unitsPerEm, 1)
        return (x + adv / 2, y - size * uprightCentreShare)
    }
}

/// Share of the size the ideographic em box's centre sits above the baseline.
public let uprightCentreShare = 0.38

/// A text run's shadow and glow, colours resolved.
public struct RunEffects: Sendable, Equatable {
    public var shadow: TextShadow?
    /// Glow colour (with its alpha) and radius in points.
    public var glow: Glow?

    public init(shadow: TextShadow? = nil, glow: Glow? = nil) {
        self.shadow = shadow
        self.glow = glow
    }

    public struct Glow: Sendable, Equatable {
        public var color: Rgba
        public var radius: Double

        public init(color: Rgba, radius: Double) {
            self.color = color
            self.radius = radius
        }
    }
}

/// An outer shadow: colour (with its alpha), blur radius and offset in points.
public struct TextShadow: Sendable, Equatable {
    public var color: Rgba
    public var blur: Double
    public var dx: Double
    public var dy: Double

    public init(color: Rgba, blur: Double, dx: Double, dy: Double) {
        self.color = color
        self.blur = blur
        self.dx = dx
        self.dy = dy
    }
}

/// Dash patterns of the dotted and dashed underlines, in units of the line's thickness.
public enum DecoDash: Sendable, Equatable {
    case dot, dash, long, dotDash, dotDotDash

    /// On, off, on, off… lengths in thicknesses.
    var pattern: [Double] {
        switch self {
        case .dot: [1, 1]
        case .dash: [3, 2]
        case .long: [6, 2]
        case .dotDash: [3, 2, 1, 2]
        case .dotDotDash: [3, 2, 1, 2, 1, 2]
        }
    }
}

/// How an underline fills its box.
public enum DecoLine: Sendable, Equatable {
    /// The whole box.
    case solid
    /// Dashes or dots across the box's height, from its left end.
    case dashed(DecoDash)
    /// A zigzag between the box's top and bottom: `stroke` wide, one wave every `period`.
    case wave(stroke: Double, period: Double)
}

/// An underline, strikethrough or highlight box.
public struct Deco: Sendable {
    public var rect: Rect
    public var color: Rgba
    /// Highlights draw behind text.
    public var behind: Bool
    /// Paragraph the decoration belongs to (by-paragraph animation).
    public var para: Int
    /// How the line fills `rect`.
    public var line: DecoLine

    public init(rect: Rect, color: Rgba, behind: Bool = false, para: Int = 0, line: DecoLine = .solid) {
        self.rect = rect
        self.color = color
        self.behind = behind
        self.para = para
        self.line = line
    }

    /// The filled boxes of a solid or dashed line (dashes start at the box's left end). A wavy line gives
    /// a thin box along its middle, for drawing that can't stroke a path.
    public func pieces() -> [Rect] {
        let r = rect
        switch line {
        case .solid:
            return [r]
        case .wave(let stroke, _):
            let c = (r.y0 + r.y1) / 2
            return [Rect(r.x0, c - stroke / 2, r.x1, c + stroke / 2)]
        case .dashed(let d):
            let unit = r.height.rustMax(0.1)
            let pat = d.pattern
            var out: [Rect] = []
            var x = r.x0
            var k = 0
            while x < r.x1 && out.count < 10_000 {
                let len = pat[k % pat.count] * unit
                if k % 2 == 0 { out.append(Rect(x, r.y0, (x + len).rustMin(r.x1), r.y1)) }
                x += len
                k += 1
            }
            return out
        }
    }

    /// The zigzag of a wavy underline, left to right from the box's top, and its stroke width; nil for
    /// other lines.
    public func wave() -> (points: [Point], stroke: Double)? {
        guard case .wave(let stroke, let period) = line else { return nil }
        let r = rect
        let half = (period / 2).rustMax(0.1)
        let n = Swift.min(Int(rustCast: (r.width.rustMax(0) / half).rounded(.up)), 20_000)
        let pts = (0 ... n).map { i in
            Point((r.x0 + Double(i) * half).rustMin(r.x1), i % 2 == 0 ? r.y0 : r.y1)
        }
        return (pts, stroke)
    }
}

/// One laid-out line.
public struct LineInfo: Sendable {
    public var para: Int = 0
    /// Character range [start, end) in the paragraph (end excludes the line's break/newline).
    public var start: Int = 0
    public var end: Int = 0
    public var top: Double = 0
    public var baseline: Double = 0
    public var bottom: Double = 0
    /// Caret x for each character boundary start...end (downstream).
    public var caretX: [Double] = []
    /// Column index (multi-column bodies).
    public var column: Int = 0
    /// Right-to-left paragraph.
    public var rtl: Bool = false
    /// Bidi level of each character start..<end after rule L1 (odd = right-to-left).
    public var levels: [UInt8] = []
    /// Visual box (left, right) of each character start..<end.
    public var edges: [(left: Double, right: Double)] = []
    /// Whether a caret may stand before each character start..<end (grapheme boundaries).
    public var boundary: [Bool] = []
    /// Visual extent (left, right) of the line's text.
    public var extent: (left: Double, right: Double) = (0, 0)
    /// Distance from the paragraph's start edge to the line's text (indent, margin, bullet).
    public var startOffset: Double = 0

    public init() {}
}

/// Laid-out text: glyph runs, decorations and lines in shape-local coordinates.
public struct TextLayout: Sendable {
    public var runs: [GlyphRun] = []
    /// Empty list markers for the editor only; ordinary rendering and export omit them.
    public var emptyBullets: [GlyphRun] = []
    public var decos: [Deco] = []
    public var lines: [LineInfo] = []
    /// Inner text box (insets applied), shape-local.
    public var inner: Rect = .zero
    /// Height of the laid-out text (before anchoring).
    public var contentHeight: Double = 0
    /// Widest line.
    public var contentWidth: Double = 0
    /// Autofit font scale used (1 = none).
    public var fontScale: Double = 1
    public var lineReduction: Double = 0
    public var overflow: Bool = false
    /// Text rotation about the shape centre, degrees (vertical text = 90/270).
    public var rotation: Double = 0
    /// Per paragraph: (first line index, line count).
    public var paraLines: [(first: Int, count: Int)] = []
    /// Per paragraph: whether a caret may stand at each character offset 0...len.
    public var boundaries: [[Bool]] = []

    public init() {}
}

/// Values for fields (`slidenum`, `datetime…`, `footer`). nil keeps the field's saved text.
public protocol TextFields {
    func field(_ kind: String) -> String?
    /// The value of field `kind` in a run of language `lang` (BCP 47): dates are written the language's way.
    func field(_ kind: String, lang: String?) -> String?
}

extension TextFields {
    public func field(_ kind: String, lang: String?) -> String? { field(kind) }
}

/// No field values: slide numbers read 1, other fields keep their saved text.
public struct NoFields: TextFields {
    public init() {}
    public func field(_ kind: String) -> String? { kind == "slidenum" ? "1" : nil }
}

public struct TextOpts {
    /// The text box: the preset's text rectangle in shape-local space.
    public var rect: Rect
    public var fields: any TextFields
    /// Draw this text instead of the body (placeholder prompts), in this colour.
    public var promptColor: Rgba?
    /// Ignore autofit shrinking (used to measure natural height).
    public var noShrink: Bool

    public init(rect: Rect, fields: any TextFields = NoFields(), promptColor: Rgba? = nil, noShrink: Bool = false) {
        self.rect = rect
        self.fields = fields
        self.promptColor = promptColor
        self.noShrink = noShrink
    }
}

/// Which side of a boundary a caret belongs to.
public enum Affinity: Sendable, Hashable {
    case upstream, downstream
}

/// Caret movement: through the text order, or across the screen.
public enum MoveMode: Sendable, Hashable {
    case logical, visual
}

/// A caret position: paragraph and character offset within it.
public struct CaretPos: Sendable, Hashable, Comparable {
    public var para: Int
    public var ch: Int

    public init(para: Int, ch: Int) {
        self.para = para
        self.ch = ch
    }

    public static func < (a: CaretPos, b: CaretPos) -> Bool { (a.para, a.ch) < (b.para, b.ch) }
}
