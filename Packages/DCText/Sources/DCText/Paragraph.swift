// DCText — a paragraph shaped into cells: run styles resolved through the placeholder chain, bidi levels,
// a face per grapheme (the `a:latin`/`a:ea`/`a:cs`/`a:sym` slots, the theme's script fonts, fallback), and
// items of one level, script, face and shaping style shaped through CoreText. Port of deckcraft
// crates/text/src/lib.rs (`make_style`, `face_chain`, `shape_para`, `shape_cells`, `shape_item`,
// `break_opportunities`, `break_lines` and the tab helpers; MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Differences from deckcraft, all from the shaper (see PORT-NOTES.md): an item is shaped without the rest
// of the paragraph as context, and CoreText's per-character string indices are merged into HarfRust's
// monotone grapheme clusters here.
import DCColor
import DCCore
import DCModel
import Foundation

/// An underline style (`a:rPr/@u`).
enum Underline: Equatable {
    case single, double, heavy
    /// Dotted or dashed, heavy or not.
    case dashed(DecoDash, Bool)
    /// Wavy, heavy or not.
    case wavy(Bool)

    static func fromXML(_ u: String) -> Underline? {
        switch u {
        case "none": nil
        // PowerPoint underlines the spaces of a "words" underline too.
        case "words": .single
        // At text sizes PowerPoint's double wave reads as two straight lines.
        case "dbl", "wavyDbl": .double
        case "heavy": .heavy
        case "dotted": .dashed(.dot, false)
        case "dottedHeavy": .dashed(.dot, true)
        case "dash": .dashed(.dash, false)
        case "dashHeavy": .dashed(.dash, true)
        case "dashLong": .dashed(.long, false)
        case "dashLongHeavy": .dashed(.long, true)
        case "dotDash": .dashed(.dotDash, false)
        case "dotDashHeavy": .dashed(.dotDash, true)
        case "dotDotDash": .dashed(.dotDotDash, false)
        case "dotDotDashHeavy": .dashed(.dotDotDash, true)
        case "wavy": .wavy(false)
        case "wavyHeavy": .wavy(true)
        default: .single
        }
    }

    /// The boxes of this underline below the baseline (top, bottom, fill), from the font's underline
    /// position `p` and thickness `t` at the run's size. Measured on PowerPoint's export (Arial 96 pt: p =
    /// 10.2, t = 7.0): single at p..p+t; heavy from p-t to p+0.55t; double as two lines 0.55t thick spanning
    /// p-t..p+t; wavy a thin zigzag from p-0.6t to p+1.1t, a wave every 3.9t.
    func boxes(_ p: Double, _ t: Double) -> [(Double, Double, DecoLine)] {
        let heavy = (p - t, p + 0.55 * t)
        switch self {
        case .single: return [(p, p + t, .solid)]
        case .heavy: return [(heavy.0, heavy.1, .solid)]
        case .double: return [(p - t, p - 0.45 * t, .solid), (p + 0.45 * t, p + t, .solid)]
        case .dashed(let d, false): return [(p, p + t, .dashed(d))]
        case .dashed(let d, true): return [(heavy.0, heavy.1, .dashed(d))]
        case .wavy(let h):
            let stroke = (t * 0.15).rustMax(0.4) * (h ? 2.0 : 1.0)
            return [(p - 0.6 * t, p + 1.1 * t, .wave(stroke: stroke, period: t * 3.9))]
        }
    }
}

struct Style {
    var face: FontFace
    var size: Double
    var color: Rgba
    var alpha: Double
    var fakeBold: Bool
    var fakeItalic: Bool
    var baseline: Double
    var spacing: Double
    var caps: Caps
    var underline: (color: Rgba, kind: Underline)?
    var strike: Strike?
    var highlight: Rgba?
    var outline: (color: Rgba, width: Double)?
    var link: Bool
    var gradient: Gradient?
    var effects: RunEffects?
    /// "Regular", "Bold"… for the slot and fallback faces.
    var styleName: String
    /// BCP 47 language (`a:rPr/@lang`), for shaping.
    var lang: String?
    /// The `a:ea` and `a:cs` families (theme references resolved), if the document names one.
    var ea: String?
    var cs: String?
    /// The `a:sym` family: private-use characters (U+F000–U+F0FF) are drawn in it.
    var sym: String?
    /// Heading font (`+mj-…`): the theme's major font set applies.
    var major: Bool
    /// Pair kerning on: `a:rPr/@kern` is set and the size reaches it.
    var kern: Bool
}

/// One character of a paragraph after shaping.
struct TextCell {
    var ch: Unicode.Scalar
    var style: Int
    var face: Int
    /// Resolved bidi embedding level (before the line rules).
    var level: UInt8
    /// Glyphs of the shaping cluster this cell heads, from the cluster's visual left edge. Empty for the
    /// other cells of a cluster.
    var glyphs: [(gid: UInt32, x: Double, y: Double)] = []
    /// This character's advance: its share of the cluster (ligature carets); 0 inside a grapheme.
    var adv: Double = 0
    /// Index of the cell heading this character's shaping cluster.
    var head: Int
    /// A grapheme starts here: carets stand and lines break only before such cells.
    var boundary: Bool
    /// Drawn upright in East Asian vertical text.
    var upright: Bool = false

    /// A line may start before this cell: a grapheme that starts a shaping cluster.
    func breakable(_ i: Int) -> Bool { boundary && head == i }
}

struct ParaShaped {
    var cells: [TextCell]
    var styles: [Style]
    var faces: [FontFace]
    var props: ParaProps
    /// Size of the paragraph's first run (spacing percentages, empty lines).
    var leadSize: Double
    var leadFace: FontFace
    /// Size of the paragraph mark (`a:endParaRPr`): what an empty last line is sized by.
    var endSize: Double
    var endFace: FontFace
    var bullet: (text: String, style: Style)?
    /// Right-to-left paragraph (`a:pPr/@rtl`).
    var rtl: Bool
}

/// Which characters stand upright in vertical text.
enum Upright: Equatable {
    /// None (horizontal text, vert, vert270, mongolianVert).
    case none_
    /// Ideographs, kana and the like (eaVert).
    case cjk
    /// Every character, one under the other (wordArtVert).
    case all
}

/// Size of superscript and subscript text relative to the run's size.
let subSuper = 0.66

func styleName(_ bold: Bool, _ italic: Bool) -> String {
    switch (bold, italic) {
    case (true, true): "Bold Italic"
    case (true, false): "Bold"
    case (false, true): "Italic"
    case (false, false): "Regular"
    }
}

extension Unicode.Scalar {
    /// Rust `char::is_whitespace` (White_Space).
    var isWS: Bool { properties.isWhitespace }
}

func makeStyle(_ ctx: Resolve.Ctx, _ r: RunProps, _ scale: Double, _ prompt: Rgba?) -> Style {
    let family = Resolve.fontFamily(ctx, r)
    let bold = r.bold ?? false
    let italic = r.italic ?? false
    let face = FontDB.shared.documentFace(family, styleName(bold, italic))
    let fakeBold = bold && face.weight < 550
    let fakeItalic = italic && !face.italic
    let size = ((r.size ?? 18) * scale).clamped(0.5, 4000)
    var color: Rgba
    let alpha: Double
    var gradient: Gradient?
    switch r.fill {
    case .solid(let c)?:
        // The resolved colour carries the fill's transparency (`a:alpha`): it is applied once.
        color = ctx.color(c, nil)
        alpha = 1
    case .gradient(var g)?:
        // Colours resolved here (theme, colour map), so the renderer needs no colour scheme.
        for i in g.stops.indices { g.stops[i].color = ColorRef.rgb(ctx.color(g.stops[i].color, nil)) }
        color = g.stops.first.map { ctx.color($0.color, nil) } ?? .black
        alpha = 1
        gradient = g
    case .none_?:
        color = .transparent
        alpha = 0
    default:
        color = Resolve.textColor(ctx, r)
        alpha = 1
    }
    if let prompt { color = prompt }
    let major = r.font?.hasPrefix("+mj") ?? false
    let theme = ctx.master.theme
    func slotFamily(_ explicit: String?, _ themeRef: String) -> String? {
        let name = theme.font(explicit ?? themeRef)
        return rustTrim(name).isEmpty ? nil : name
    }
    let ea = slotFamily(r.fontEa, major ? "+mj-ea" : "+mn-ea")
    let cs = slotFamily(r.fontCs, major ? "+mj-cs" : "+mn-cs")
    let underline = r.underline.flatMap(Underline.fromXML).map { u in (color: r.underlineColor.map { ctx.color($0, nil) } ?? color, kind: u) }
    var outline: (color: Rgba, width: Double)?
    if let l = r.outline, case .solid(let c)? = l.fill { outline = (ctx.color(c, nil), l.width ?? 0.75) }
    return Style(
        face: face, size: size, color: color, alpha: alpha, fakeBold: fakeBold, fakeItalic: fakeItalic,
        baseline: r.baseline ?? 0, spacing: (r.spacing ?? 0) * scale, caps: r.caps ?? .none_, underline: underline,
        strike: r.strike.flatMap { $0 == .none_ ? nil : $0 }, highlight: r.highlight.map { ctx.color($0, nil) }, outline: outline,
        link: r.link != nil, gradient: gradient, effects: runEffects(ctx, r, scale), styleName: styleName(bold, italic),
        lang: r.lang.flatMap { $0.isEmpty ? nil : $0 }, ea: ea, cs: cs,
        sym: r.fontSym.map { theme.font($0) }.flatMap { rustTrim($0).isEmpty ? nil : $0 }, major: major,
        kern: r.kern.map { k in k > 0 && size + 1e-6 >= k * scale } ?? false
    )
}

/// A run's outer shadow and glow (inner shadows aren't drawn on text), at the layout's `scale`.
func runEffects(_ ctx: Resolve.Ctx, _ r: RunProps, _ scale: Double) -> RunEffects? {
    let shadow = r.shadow.flatMap { s -> TextShadow? in
        guard !s.inner else { return nil }
        let a = s.dir.toRadians
        return TextShadow(color: ctx.color(s.color, nil), blur: s.blur.rustMax(0) * scale, dx: cos(a) * s.dist * scale, dy: sin(a) * s.dist * scale)
    }
    let glow = r.glow.flatMap { g in g.radius > 0 ? RunEffects.Glow(color: ctx.color(g.color, nil), radius: g.radius * scale) : nil }
    return shadow != nil || glow != nil ? RunEffects(shadow: shadow, glow: glow) : nil
}

/// The faces to try for a cluster of `slot`/`script` in style `st`, in order: the slot's typeface, the
/// theme's font for the script (`a:font[@script]`), then the run's Latin face.
func faceChain(_ ctx: Resolve.Ctx, _ st: Style, _ slot: FontSlot, _ script: ScriptTag?) -> [FontFace] {
    let db = FontDB.shared
    var chain: [FontFace] = []
    func push(_ family: String) {
        // Only families that exist: `FontDB.face` would substitute the default face.
        guard db.hasFamily(family) else { return }
        let f = db.face(family, st.styleName)
        if !chain.contains(where: { $0 === f }) { chain.append(f) }
    }
    switch slot {
    case .eastAsian: if let f = st.ea { push(f) }
    case .complexScript: if let f = st.cs { push(f) }
    case .latin: break
    }
    if let sc = script {
        let set = st.major ? ctx.master.theme.fonts.major : ctx.master.theme.fonts.minor
        if let f = set.script(sc) { push(f) }
    }
    if !chain.contains(where: { $0 === st.face }) { chain.append(st.face) }
    return chain
}

/// Space before or after a paragraph, points. Shrink-on-overflow's line spacing reduction doesn't apply
/// to it (PowerPoint keeps it).
func spacingPts(_ s: Spacing?, _ size: Double) -> Double {
    switch s {
    case .pct(let p)?: p * size * 1.2
    case .pts(let v)?: v
    case nil: 0
    }
}

func shapePara(_ ctx: Resolve.Ctx, _ shape: Shape, _ body: TextBody, _ pi: Int, _ scale: Double, _ opts: TextOpts, _ number: UInt32?, _ vertical: Upright) -> ParaShaped {
    let db = FontDB.shared
    guard let para = body.paragraphs.at(pi) else {
        let face = db.face("Inter", "Regular")
        return ParaShaped(cells: [], styles: [], faces: [], props: ParaProps(), leadSize: 18, leadFace: face, endSize: 18, endFace: face, bullet: nil, rtl: false)
    }
    let props = Resolve.para(ctx, shape, para)
    let rtl = props.rtl ?? false
    var styles: [Style] = []
    var faces: [FontFace] = []
    // The logical paragraph: its text and each character's style.
    var text: [Unicode.Scalar] = []
    var charStyle: [Int] = []
    for run in para.runs {
        let rp = Resolve.run(ctx, shape, para, run.props)
        let st = makeStyle(ctx, rp, scale, opts.promptColor)
        let t: String
        switch run.kind {
        case .text: t = run.text
        case .break: t = "\u{0B}"
        case .field(let field): t = opts.fields.field(field, lang: rp.lang) ?? run.text
        case .math: t = run.text
        }
        let si = styles.count
        styles.append(st)
        charStyle += Array(repeating: si, count: t.unicodeScalars.count)
        text += t.unicodeScalars
    }
    let cells = shapeCells(ctx, text, charStyle, styles, &faces, rtl, vertical)
    let lead = para.runs.first.map { Resolve.run(ctx, shape, para, $0.props) } ?? Resolve.run(ctx, shape, para, para.endProps)
    let leadStyle = makeStyle(ctx, lead, scale, opts.promptColor)
    // The paragraph mark, which ends the last line when no break does.
    let endStyle = makeStyle(ctx, Resolve.run(ctx, shape, para, para.endProps), scale, opts.promptColor)
    var bullet: (text: String, style: Style)?
    switch props.bullet {
    case .char(let char)?:
        var rp = lead
        if let f = props.bulletFont { rp.font = f }
        rp.bold = false
        rp.italic = false
        if let c = props.bulletColor { rp.fill = .solid(color: c) }
        rp.size = (lead.size ?? 18) * (props.bulletSize ?? 1)
        rp.underline = nil
        rp.strike = nil
        rp.highlight = nil
        var st = makeStyle(ctx, rp, scale, opts.promptColor)
        st.baseline = 0
        // Symbol fonts (Wingdings) aren't available: map common private-use bullets.
        bulletFace(db, &st, mapSymbolBullet(char, props.bulletFont))
        // A symbol font that is installed draws its own glyph, found at U+F000 + the character code as such
        // fonts map them; otherwise common symbol bullets are mapped to Unicode look-alikes.
        let ch = symbolFontChar(st.face, char, props.bulletFont).map { String($0) } ?? mapSymbolBullet(char, props.bulletFont)
        if !st.face.covers(ch.unicodeScalars.first ?? "•") { st.face = db.face("Inter", "Regular") }
        bullet = (ch, st)
    case .autoNum(let scheme, let startAt)?:
        var rp = lead
        if let c = props.bulletColor { rp.fill = .solid(color: c) }
        rp.size = (lead.size ?? 18) * (props.bulletSize ?? 1)
        rp.underline = nil
        var st = makeStyle(ctx, rp, scale, opts.promptColor)
        let (sum, over) = (startAt == 0 ? 0 : startAt - 1).addingReportingOverflow(number ?? 1)
        let label = autonum(scheme, over ? .max : sum)
        bulletFace(db, &st, label)
        bullet = (label, st)
    default:
        bullet = nil
    }
    return ParaShaped(
        cells: cells, styles: styles, faces: faces, props: props, leadSize: leadStyle.size, leadFace: leadStyle.face,
        endSize: endStyle.size, endFace: endStyle.face, bullet: bullet, rtl: rtl
    )
}

/// A face that draws the bullet `label` when the bullet's own can't (circled numbers ①, arrows and other
/// symbols missing from the text font), by the usual fallback.
func bulletFace(_ db: FontDB, _ st: inout Style, _ label: String) {
    let chars = Array(label.unicodeScalars)
    if !chars.isEmpty && !Fallback.coversCluster(st.face, chars) {
        st.face = db.cascade(chars, [st.face], st.styleName)
    }
}

/// Grapheme clusters of `chars` as [start, end) scalar ranges.
func graphemeRanges(_ chars: [Unicode.Scalar]) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var i = 0
    for g in String(String.UnicodeScalarView(chars)) {
        let n = g.unicodeScalars.count
        out.append((i, i + n))
        i += n
    }
    return out
}

private struct ChainKey: Hashable {
    var style: Int
    var slot: FontSlot
    var script: ScriptTag?
}

private struct ItemKey: Equatable {
    var level: UInt8
    var face: Int
    var script: ScriptTag?
    var upper: Bool
    var lang: String?
    var kern: Bool
    var upright: Bool
}

/// Shape a logical paragraph into cells: bidi levels, per-grapheme faces, items of one level, script,
/// face and shaping style.
func shapeCells(
    _ ctx: Resolve.Ctx, _ chars: [Unicode.Scalar], _ charStyle: [Int], _ styles: [Style], _ faces: inout [FontFace], _ rtl: Bool,
    _ vertical: Upright
) -> [TextCell] {
    let db = FontDB.shared
    let n = chars.count
    let styleRTL = styles.map { $0.lang.map(Bidi.isRTLLang) ?? false }
    let rtlLang = charStyle.map { styleRTL.at($0) ?? false }
    let levels = Bidi.levelsLang(chars, rtl, rtlLang)
    let scripts = Script.resolve(chars)
    let graphemes = graphemeRanges(chars)
    var boundary = [Bool](repeating: false, count: n)
    for (a, _) in graphemes where a < n { boundary[a] = true }
    func faceIndex(_ f: FontFace) -> Int {
        if let i = faces.firstIndex(where: { $0 === f }) { return i }
        faces.append(f)
        return faces.count - 1
    }
    // A face per grapheme cluster (never split between faces).
    var charFace = [Int](repeating: 0, count: n)
    var chains: [ChainKey: [FontFace]] = [:]
    var prev: FontFace?
    for (a, b) in graphemes {
        let cluster = Array(chars[a ..< b])
        let si = charStyle.at(a) ?? 0
        guard let st = styles.at(si) else { continue }
        let (sc, slot) = scripts.at(a) ?? (nil, .latin)
        // Spaces, digits and punctuation stay in the face of the text before them when it can draw them,
        // so a phrase isn't cut into items at every space. Emoji, and pictographs asked to look like text
        // (U+FE0E), pick their own face.
        let neutral = cluster.allSatisfy { Script.of($0) == nil } && !Fallback.isEmojiCluster(cluster) && !cluster.contains("\u{FE0E}")
        // A symbol-font character (U+F0xx) with an `a:sym` font draws in that font when it's there.
        var symFace: FontFace?
        if let sym = st.sym, let first = cluster.first, (0xF000 ... 0xF0FF).contains(first.value), db.hasFamily(sym) {
            let f = db.face(sym, st.styleName)
            if coversSymbol(f, first) { symFace = f }
        }
        let face: FontFace
        if let symFace {
            face = symFace
        } else if let p = prev, neutral, !p.isColor, Fallback.coversCluster(p, cluster), a > 0, charStyle.at(a - 1) == si {
            face = p
        } else {
            let key = ChainKey(style: si, slot: slot, script: sc)
            let chain = chains[key] ?? faceChain(ctx, st, slot, sc)
            chains[key] = chain
            face = db.cascade(cluster, chain, st.styleName)
        }
        let fi = faceIndex(face)
        for i in a ..< b { charFace[i] = fi }
        prev = face
    }
    var cells = (0 ..< n).map { i in
        TextCell(ch: chars[i], style: charStyle.at(i) ?? 0, face: charFace[i], level: levels.at(i) ?? 0, head: i, boundary: boundary[i])
    }
    // In East Asian vertical text, ideographs, kana, Hangul, full-width forms and the like stand upright (a
    // whole grapheme at a time); other text lies on its side.
    if vertical != .none_ {
        for (a, b) in graphemes {
            let up = vertical == .all ? !chars[a].isWS : isUpright(chars[a])
            for i in a ..< b { cells[i].upright = up }
        }
    }
    // Items: maximal ranges of one level, face, script and shaping style (case mapping, language).
    func st(_ i: Int) -> Style? { styles.at(charStyle.at(i) ?? 0) }
    func upper(_ i: Int) -> Bool { st(i).map { $0.caps != .none_ } ?? false }
    func lang(_ i: Int) -> String? { st(i)?.lang }
    func key(_ i: Int) -> ItemKey {
        ItemKey(level: levels.at(i) ?? 0, face: charFace[i], script: scripts.at(i)?.script, upper: upper(i), lang: lang(i), kern: st(i)?.kern ?? false, upright: cells[i].upright)
    }
    var a = 0
    while a < n {
        var b = a + 1
        let k = key(a)
        while b < n && key(b) == k { b += 1 }
        // Upright glyphs keep their horizontal forms: PowerPoint turns "、", "。" and "「" as they are.
        shapeItem(&cells, styles, faces, a ..< b, scripts.at(a)?.script, lang(a), upper(a))
        a = b
    }
    // Stacked text: each character takes one em down the line, centred across it.
    if vertical == .all {
        for i in 0 ..< n {
            let c = cells[i]
            guard c.upright, c.head == i, !c.glyphs.isEmpty else { continue }
            let size = styles.at(c.style)?.size ?? 18
            var width = 0.0
            var j = i
            while j < n && cells[j].head == i {
                width += cells[j].adv
                j += 1
            }
            let pad = (size - width) / 2
            for g in cells[i].glyphs.indices { cells[i].glyphs[g].x += pad }
            for j in i ..< n {
                guard cells[j].head == i else { break }
                cells[j].adv = j == i ? size : 0
            }
        }
    }
    return cells
}

/// A character in capitals (`cap="all"`/`"small"`): its uppercase when that is one character. "ß" stays
/// "ß" (not "SS"), "ﬁ" and "ŉ" stay.
func capsChar(_ ch: Unicode.Scalar) -> Unicode.Scalar {
    let up = ch.properties.uppercaseMapping.unicodeScalars
    return up.count == 1 ? (up.first ?? ch) : ch
}

/// Does `c` stand upright in East Asian vertical text? (Unicode's Vertical_Orientation U and T, roughly.)
func isUpright(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x1100 ... 0x11FF, 0x2460 ... 0x24FF, 0x2E80 ... 0x2FFF, 0x3000 ... 0x303F, 0x3040 ... 0x30FF, 0x3100 ... 0x312F, 0x3130 ... 0x318F,
         0x3190 ... 0x31FF, 0x3200 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA960 ... 0xA97F, 0xAC00 ... 0xD7FF, 0xF900 ... 0xFAFF,
         0xFE10 ... 0xFE1F, 0xFE30 ... 0xFE6F, 0xFF01 ... 0xFF60, 0xFFE0 ... 0xFFE6, 0x1F000 ... 0x1FAFF, 0x20000 ... 0x3FFFF:
        true
    default:
        false
    }
}

/// The shaping features to change from the defaults for an item, as PowerPoint draws it: kerning only
/// where the run asks for it, and no standard or contextual ligatures in Latin, Greek and Cyrillic. Other
/// scripts need their ligatures (Arabic lam-alef), and emoji sequences are joined by them.
func shapingFeatures(_ cells: ArraySlice<TextCell>, _ styles: [Style], _ script: ScriptTag?) -> (kern: Bool, ligatures: Bool) {
    let kern = cells.first.flatMap { styles.at($0.style) }?.kern ?? false
    let alphabetic = script == "Latn" || script == "Grek" || script == "Cyrl"
    let emoji = cells.contains { c in
        switch c.ch.value {
        case 0x200D, 0x20E3, 0xFE0F, 0x2600 ... 0x27BF, 0x1F000 ... 0x1FAFF, 0xE0020 ... 0xE007F: true
        default: false
        }
    }
    return (kern, !(alphabetic && !emoji))
}

/// Shape cells `range` (one item) and hang each cluster's glyphs on its first cell, sharing the cluster's
/// advance among its graphemes (by the ligature's GDEF carets when it has them).
func shapeItem(_ cells: inout [TextCell], _ styles: [Style], _ faces: [FontFace], _ range: Range<Int>, _ script: ScriptTag?, _ lang: String?, _ upper: Bool) {
    guard let first = cells.at(range.lowerBound), let face = faces.at(first.face) else { return }
    let rtl = first.level % 2 == 1
    let features = shapingFeatures(cells[range], styles, script)
    let sym = styles.at(first.style)?.sym
    let mapped: [Unicode.Scalar] = cells[range].map { c in
        // Line and tab controls are never drawn; CoreText would lay them out as paragraph and tab breaks.
        if (0x09 ... 0x0D).contains(c.ch.value) { return " " }
        let ch = upper ? capsChar(c.ch) : c.ch
        return symbolMapChar(face, ch, sym) ?? ch
    }
    var glyphs = Shaper.shape(face, mapped, rtl: rtl, kern: features.kern, ligatures: features.ligatures, lang: lang ?? script.flatMap(Script.defaultLanguage), script: script)
    // HarfRust's clusters: graphemes merged, and monotone in the item's direction (a reordered glyph, an
    // Indic pre-base matra, joins the cluster it moved across).
    for g in glyphs.indices {
        var h = glyphs[g].cluster + range.lowerBound
        while h > range.lowerBound && !cells[h].boundary { h -= 1 }
        glyphs[g].cluster = h
    }
    if rtl {
        var m = Int.max
        for g in glyphs.indices {
            m = Swift.min(m, glyphs[g].cluster)
            glyphs[g].cluster = m
        }
    } else {
        var m = Int.max
        for g in glyphs.indices.reversed() {
            m = Swift.min(m, glyphs[g].cluster)
            glyphs[g].cluster = m
        }
    }
    let upem = face.upem.rustMax(1)
    func scaleOf(_ cell: TextCell) -> Double {
        let st = styles.at(cell.style)
        var size = st?.size ?? 18
        if st?.caps == .small && cell.ch.properties.isLowercase { size *= 0.8 }
        // Superscript and subscript glyphs are drawn at two thirds of the size, so they advance by two
        // thirds too.
        if let s = st, s.baseline != 0 { size *= subSuper }
        return size / upem
    }
    // Cluster heads in this item, ascending; each cluster spans to the next head.
    let heads = Array(Set(glyphs.map(\.cluster).filter { range.contains($0) })).sorted()
    var width: [Int: Double] = [:]
    var lig: [Int: (gid: UInt32, count: Int)] = [:]
    for g in glyphs {
        let h = g.cluster
        guard range.contains(h) else { continue }
        if (0x09 ... 0x0B).contains(cells[h].ch.value) { continue }
        let s = scaleOf(cells[h])
        let w = width[h] ?? 0
        cells[h].glyphs.append((g.gid, w + g.xOffset * s, -g.yOffset * s))
        width[h] = w + g.xAdvance * s
        var e = lig[h] ?? (g.gid, 0)
        e.count += 1
        lig[h] = e
    }
    for (hi, h) in heads.enumerated() {
        let end = Swift.min(heads.at(hi + 1) ?? range.upperBound, range.upperBound)
        let w = width[h] ?? 0
        for i in h ..< end { cells[i].head = h }
        let stops = (h ..< end).filter { $0 == h || cells[$0].boundary }
        let m = Swift.max(stops.count, 1)
        // Visual widths of the cluster's graphemes, left to right.
        var bounds: [Double] = [0]
        if m > 1, let l = lig[h], l.count == 1 {
            let s = scaleOf(cells[h])
            let carets = face.ligatureCarets(l.gid)
            if carets.count + 1 >= m { bounds += carets.prefix(m - 1).map { ($0 * s).clamped(0, w) } }
        }
        if bounds.count != m { bounds = (0 ..< m).map { w * Double($0) / Double(m) } }
        bounds.append(w)
        for (j, i) in stops.enumerated() {
            let vj = rtl ? m - 1 - j : j
            let share = (bounds.at(vj + 1) ?? w) - (bounds.at(vj) ?? 0)
            cells[i].adv = share.rustMax(0)
        }
    }
    // Tracking (character spacing) after every drawn grapheme and space.
    for i in range {
        let c = cells[i]
        let drawn = !(cells.at(c.head)?.glyphs.isEmpty ?? true)
        if c.boundary && (drawn || c.ch == " "), let sp = styles.at(c.style)?.spacing { cells[i].adv += sp }
    }
}

/// Width and glyphs (id, x) of `s` set in `face` at `size`, with the shaper's default features.
func measureStr(_ face: FontFace, _ size: Double, _ s: String) -> (width: Double, glyphs: [(gid: UInt32, x: Double)]) {
    let g = Shaper.shapeLogical(face, Array(s.unicodeScalars))
    let k = size / face.upem.rustMax(1)
    var x = 0.0
    var out: [(gid: UInt32, x: Double)] = []
    for gl in g {
        out.append((gl.gid, x + gl.xOffset * k))
        x += gl.xAdvance * k
    }
    return (x, out)
}

/// Single line spacing as a multiple of the font size. PowerPoint spaces single-spaced lines 1.2 times the
/// size apart in every font, whatever the font's own ascent and descent (measured on one Windows install
/// of desktop PowerPoint).
let linePitch = 1.2

/// A line's height above and below the baseline at `size`: `linePitch` × size, split where the font's
/// Windows ascent and descent put the baseline.
func lineMetrics(_ face: FontFace, _ size: Double) -> (Double, Double) {
    let h = size * linePitch
    return (h * face.lineSplit, h * (1 - face.lineSplit))
}

/// Hangul syllables and jamo: PowerPoint wraps Korean at word boundaries (spaces), not between syllables.
func isHangul(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xA960 ... 0xA97F, 0xAC00 ... 0xD7FF: true
    default: false
    }
}

/// East Asian commas and full stops, the punctuation PowerPoint lets hang past the end of a line.
func isHangingPunct(_ c: Unicode.Scalar) -> Bool {
    ["、", "。", "，", "．", "､", "｡"].contains(c)
}

/// Small kana, the prolonged sound mark and iteration marks: PowerPoint keeps them off the start of a line.
func isCJNonstarter(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ", "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ", "ー",
         "々", "〻", "ゝ", "ゞ", "ヽ", "ヾ":
        return true
    default:
        return (0x31F0 ... 0x31FF).contains(c.value) || (0xFF67 ... 0xFF70).contains(c.value)
    }
}

/// Break opportunities: allowed[i] = a line may start at char i. Unicode line breaking, then PowerPoint's
/// differences: without `latinLnBrk` a word doesn't break after `/` or `\`, and Korean breaks only between
/// words.
func breakOpportunities(_ chars: [Unicode.Scalar], _ latinBreak: Bool) -> (allowed: [Bool], mandatory: [Bool]) {
    let n = chars.count
    var allowed = [Bool](repeating: false, count: n + 1)
    var mandatory = [Bool](repeating: false, count: n + 1)
    for (off, m) in lineBreaks(chars) where off <= n {
        allowed[off] = true
        if m { mandatory[off] = true }
    }
    if n >= 2 {
        for i in 0 ..< n - 1 {
            let (prev, next) = (chars[i], chars[i + 1])
            // PowerPoint never breaks after a zero-width space, nor before an em dash (only after it).
            let keep: Bool
            if (isHangul(prev) && isHangul(next)) || prev == "\u{200B}" || next == "\u{2014}" || isCJNonstarter(next) {
                keep = false
            } else {
                keep = latinBreak || !(prev == "/" || prev == "\\") || next.isWS
            }
            if !keep && !mandatory[i + 1] { allowed[i + 1] = false }
        }
    }
    return (allowed, mandatory)
}

struct RawLine {
    var start: Int
    var end: Int
    /// End including trailing spaces / the break char consumed.
    var next: Int
}

func breakLines(_ p: ParaShaped, _ firstW: Double, _ restW: Double, _ wrap: Bool, _ tabStops: [Tab], _ defaultTab: Double, _ x0First: Double, _ x0Rest: Double) -> [RawLine] {
    let n = p.cells.count
    if n == 0 { return [RawLine(start: 0, end: 0, next: 0)] }
    let (allowed, _) = breakOpportunities(p.cells.map(\.ch), p.props.latinLineBreak ?? false)
    let hang = p.props.hangingPunct ?? false
    var lines: [RawLine] = []
    var start = 0
    func breakable(_ j: Int) -> Bool { p.cells.at(j).map { $0.breakable(j) } ?? true }
    while start < n {
        let avail = lines.isEmpty ? firstW : restW
        let x0 = lines.isEmpty ? x0First : x0Rest
        var x = 0.0
        var lastBreak: Int?
        var i = start
        var end = n
        var next = n
        while i < n {
            let c = p.cells[i].ch
            if c == "\u{0B}" || c == "\n" {
                end = i
                next = i + 1
                break
            }
            let adv = c == "\t" ? tabAdvance(x0 + x, tabStops, defaultTab, tabSegment(p.cells, i)) : p.cells[i].adv
            if i > start && allowed[i] && breakable(i) { lastBreak = i }
            // Closing East Asian punctuation hangs past the end instead of wrapping; the line breaks after it.
            if wrap && hang && x + adv > avail + 0.01 && x <= avail + 0.01 && isHangingPunct(c) && i > start {
                end = i + 1
                next = i + 1
                break
            }
            // A tab that would run past the end moves to the next line (and to its first stop there).
            if wrap && c == "\t" && x + adv > avail + 0.01 && i > start {
                end = i
                next = i
                while end > start && p.cells[end - 1].ch == " " { end -= 1 }
                break
            }
            if wrap && x + adv > avail + 0.01 && !c.isWS && i > start {
                // Break at the last opportunity, or force mid-word (between clusters).
                let b: Int
                if let lb = lastBreak, lb > start {
                    b = lb
                } else {
                    b = (start + 1 ... i).reversed().first(where: breakable) ?? (i + 1 < n ? (i + 1 ..< n).first(where: breakable) : nil) ?? n
                }
                end = b
                next = b
                // Trailing spaces belong to the line but don't count.
                while end > start && p.cells[end - 1].ch == " " { end -= 1 }
                break
            }
            x += adv
            i += 1
        }
        if i >= n {
            end = n
            next = n
        }
        lines.append(RawLine(start: start, end: end, next: next))
        if next <= start {
            // No progress: force one char.
            let to = start + 1 < n ? ((start + 1 ..< n).first(where: breakable) ?? n) : n
            lines[lines.count - 1].end = to
            lines[lines.count - 1].next = to
            start = to
        } else {
            start = next
        }
        if next == n && p.cells.last?.ch == "\u{0B}" && start >= n {
            // A trailing line break opens an empty last line.
            lines.append(RawLine(start: n, end: n, next: n))
        }
    }
    return lines
}

/// How a tab stop aligns the text after it (`a:tab/@algn`).
enum TabAlign: Equatable {
    case left, center, right
    /// The first "." of the text sits at the stop (text without one ends there).
    case decimal
}

struct Tab: Equatable {
    var pos: Double
    var align: TabAlign
}

func tabsOf(_ props: ParaProps) -> [Tab] {
    (props.tabs ?? []).map { s in
        let a: TabAlign = switch s.align {
        case "ctr": .center
        case "r": .right
        case "dec": .decimal
        default: .left
        }
        return Tab(pos: s.pos, align: a)
    }
}

/// Width of the text after the tab at cell `i` up to the next tab or line break, and the width of that text
/// before its first ".".
func tabSegment(_ cells: [TextCell], _ i: Int) -> (Double, Double) {
    var w = 0.0
    var dec: Double?
    for c in cells.dropFirst(i + 1) {
        if (0x09 ... 0x0B).contains(c.ch.value) { break }
        if c.ch == "." && dec == nil { dec = w }
        w += c.adv
    }
    return (w, dec ?? w)
}

/// Advance of a tab at `x` (from the start edge) to the next stop, placing the text after it as the stop
/// aligns it but never moving back, as PowerPoint does; past the last stop, to the next default stop.
func tabAdvance(_ x: Double, _ stops: [Tab], _ defaultTab: Double, _ seg: (Double, Double)) -> Double {
    for s in stops where s.pos > x + 0.5 {
        let to = s.pos - x
        switch s.align {
        case .left: return to
        case .right: return (to - seg.0).rustMax(0)
        case .center: return (to - seg.0 / 2).rustMax(0)
        case .decimal: return (to - seg.1).rustMax(0)
        }
    }
    let d = defaultTab > 1 ? defaultTab : 72
    let next = ((x / d).rounded(.down) + 1) * d
    return (next - x).rustMax(1)
}
