// DCModel — text bodies: body properties, paragraphs, runs, list styles. Port of deckcraft
// crates/model/src/text.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Text positions count Unicode scalar values, as Rust's `chars()` does, never grapheme clusters: a
// caret offset means the same character in both ports.
import DCColor
import DCCore

extension String {
    /// Rust's `s.chars().count()`.
    public var charCount: Int { unicodeScalars.count }
}

extension Anchor {
    public var xml: String {
        switch self {
        case .top: "t"
        case .middle: "ctr"
        case .bottom: "b"
        case .justified: "just"
        case .distributed: "dist"
        }
    }

    public static func fromXML(_ s: String) -> Anchor? {
        switch s {
        case "t": .top
        case "ctr": .middle
        case "b": .bottom
        case "just": .justified
        case "dist": .distributed
        default: nil
        }
    }
}

extension TextDir {
    public var xml: String {
        switch self {
        case .horizontal: "horz"
        case .vertical: "vert"
        case .vertical270: "vert270"
        case .stacked: "wordArtVert"
        case .eaVertical: "eaVert"
        case .mongolianVertical: "mongolianVert"
        case .stackedRtl: "wordArtVertRtl"
        }
    }

    public static func fromXML(_ s: String) -> TextDir? {
        switch s {
        case "horz": .horizontal
        case "vert": .vertical
        case "mongolianVert": .mongolianVertical
        case "vert270": .vertical270
        case "wordArtVert": .stacked
        case "wordArtVertRtl": .stackedRtl
        case "eaVert": .eaVertical
        default: nil
        }
    }
}

extension BodyProps {
    public mutating func inherit(_ p: BodyProps) {
        insetL = insetL ?? p.insetL
        insetT = insetT ?? p.insetT
        insetR = insetR ?? p.insetR
        insetB = insetB ?? p.insetB
        anchor = anchor ?? p.anchor
        anchorCtr = anchorCtr ?? p.anchorCtr
        wrap = wrap ?? p.wrap
        autofit = autofit ?? p.autofit
        vert = vert ?? p.vert
        rot = rot ?? p.rot
        columns = columns ?? p.columns
        colSpacing = colSpacing ?? p.colSpacing
        if warp == nil {
            warp = p.warp
            warpAdj = p.warpAdj
        }
        rtlCol = rtlCol ?? p.rtlCol
        upright = upright ?? p.upright
        spaceFirstLast = spaceFirstLast ?? p.spaceFirstLast
    }
}

extension Align {
    public var xml: String {
        switch self {
        case .left: "l"
        case .center: "ctr"
        case .right: "r"
        case .justify: "just"
        case .justLow: "justLow"
        case .distributed: "dist"
        }
    }

    public static func fromXML(_ s: String) -> Align? {
        switch s {
        case "l": .left
        case "ctr": .center
        case "r": .right
        case "just", "thaiDist": .justify
        case "justLow": .justLow
        case "dist": .distributed
        default: nil
        }
    }
}

extension ParaProps {
    public mutating func inherit(_ p: ParaProps) {
        align = align ?? p.align
        marginLeft = marginLeft ?? p.marginLeft
        marginRight = marginRight ?? p.marginRight
        indent = indent ?? p.indent
        lineSpacing = lineSpacing ?? p.lineSpacing
        spaceBefore = spaceBefore ?? p.spaceBefore
        spaceAfter = spaceAfter ?? p.spaceAfter
        bullet = bullet ?? p.bullet
        bulletFont = bulletFont ?? p.bulletFont
        bulletColor = bulletColor ?? p.bulletColor
        bulletSize = bulletSize ?? p.bulletSize
        tabs = tabs ?? p.tabs
        defaultTab = defaultTab ?? p.defaultTab
        rtl = rtl ?? p.rtl
        fontAlign = fontAlign ?? p.fontAlign
        eastAsianLineBreak = eastAsianLineBreak ?? p.eastAsianLineBreak
        latinLineBreak = latinLineBreak ?? p.latinLineBreak
        hangingPunct = hangingPunct ?? p.hangingPunct
    }
}

/// Only `http(s)://…` and `mailto:` links may be opened.
public func safeURL(_ url: String) -> Bool {
    let u = rustTrim(url)
    guard let colon = u.firstIndex(of: ":") else { return false }
    let scheme = u[..<colon]
    let rest = u[u.index(after: colon)...]
    switch rustASCIILowercase(String(scheme)) {
    case "http", "https": return rest.hasPrefix("//") && rest.utf8.count > 2
    case "mailto": return !rest.isEmpty
    default: return false
    }
}

extension RunProps {
    public mutating func inherit(_ p: RunProps) {
        font = font ?? p.font
        fontEa = fontEa ?? p.fontEa
        fontCs = fontCs ?? p.fontCs
        fontSym = fontSym ?? p.fontSym
        size = size ?? p.size
        bold = bold ?? p.bold
        italic = italic ?? p.italic
        underline = underline ?? p.underline
        underlineColor = underlineColor ?? p.underlineColor
        strike = strike ?? p.strike
        baseline = baseline ?? p.baseline
        caps = caps ?? p.caps
        spacing = spacing ?? p.spacing
        kern = kern ?? p.kern
        fill = fill ?? p.fill
        outline = outline ?? p.outline
        highlight = highlight ?? p.highlight
        link = link ?? p.link
        hover = hover ?? p.hover
        lang = lang ?? p.lang
        shadow = shadow ?? p.shadow
        innerShadow = innerShadow ?? p.innerShadow
        glow = glow ?? p.glow
        reflection = reflection ?? p.reflection
        softEdge = softEdge ?? p.softEdge
        noProof = noProof ?? p.noProof
    }
}

func isDefaultProps(_ p: RunProps) -> Bool { p == RunProps() }
func isTextKind(_ k: RunKind) -> Bool { k == .text }
func isDefaultPara(_ p: ParaProps) -> Bool { p == ParaProps() }

extension Run {
    public init(_ text: String) {
        self.init(text: text, props: RunProps(), kind: .text)
    }

    public static func with(_ text: String, _ props: RunProps) -> Run {
        Run(text: text, props: props, kind: .text)
    }

    /// The characters this run contributes to the paragraph (a break is one `\u{0B}`).
    public var content: String {
        if case .break = kind { return "\u{0B}" }
        return text
    }

    public var charLen: Int { content.charCount }
}

extension Paragraph {
    public init(_ text: String) {
        self.init(runs: text.isEmpty ? [] : [Run(text)])
    }

    /// Leading tabs are the outline level (at most 8), the same rule as a typed indent. Returns whether
    /// any tab was consumed.
    public mutating func promoteLeadingTabs() -> Bool {
        guard var r = runs.first, r.kind == .text else { return false }
        let tabs = r.text.unicodeScalars.prefix { $0 == "\t" }.count
        if tabs == 0 { return false }
        r.text = String(String.UnicodeScalarView(r.text.unicodeScalars.drop { $0 == "\t" }))
        runs[0] = r
        level = UInt8(Swift.min(tabs, 8))
        return true
    }

    public var text: String { runs.map(\.content).joined() }
    public var charLen: Int { runs.reduce(0) { $0 + $1.charLen } }
    public var isEmpty: Bool { charLen == 0 }

    /// Merge adjacent text runs with identical properties.
    public mutating func normalize() {
        var out: [Run] = []
        out.reserveCapacity(runs.count)
        for r in runs {
            if r.kind == .text, r.text.isEmpty { continue }
            if let last = out.last, last.kind == .text, r.kind == .text, last.props == r.props {
                out[out.count - 1].text += r.text
                continue
            }
            out.append(r)
        }
        runs = out
    }
}

extension FontSet {
    /// The typeface the theme gives `script` (`"Arab"`), if any.
    public func script(_ script: String) -> String? {
        scripts.first { rustASCIILowercase($0.script) == rustASCIILowercase(script) && !$0.typeface.isEmpty }?.typeface
    }
}

extension ListStyle {
    public func level(_ l: UInt8) -> LevelStyle? { levels.at(Int(l)) ?? nil }

    public mutating func set(_ l: UInt8, _ s: LevelStyle) {
        let i = Swift.min(Int(l), 8)
        if levels.count <= i { levels.append(contentsOf: Array(repeating: nil, count: i + 1 - levels.count)) }
        levels[i] = s
    }

    public var isEmpty: Bool { levels.allSatisfy { $0 == nil } }
}

extension TextBody {
    public static func fromText(_ text: String) -> TextBody {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return TextBody(paragraphs: text.split(separator: "\n", omittingEmptySubsequences: false).map { Paragraph(String($0)) })
    }

    /// Plain text with `\n` between paragraphs.
    public var text: String { paragraphs.map(\.text).joined(separator: "\n") }
    public var isEmpty: Bool { paragraphs.allSatisfy(\.isEmpty) }

    /// Total characters, counting one separator between paragraphs.
    public var charLen: Int {
        paragraphs.reduce(0) { $0 + $1.charLen } + Swift.max(paragraphs.count - 1, 0)
    }
}
