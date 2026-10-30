// DCPPT — text ([MS-PPT] 2.9): a text body is a TextHeaderAtom (its type), the characters (TextCharsAtom, UTF-16, or
// TextBytesAtom, one byte per character) and a StyleTextPropAtom: paragraph runs, then character runs, each covering
// a count of characters. The run arrays have no counts of their own: they run until they cover the text plus one
// (an implied final paragraph mark). Each run's formatting is an exception record (TextPFException 2.9.20,
// TextCFException 2.9.13) whose fields are present only when its mask says so, in a fixed order; `PF.read` and
// `CF.read` decode them, and the master's text styles (TextMasterStyleAtom, `MasterStyles`) are made of the same
// records. Paragraphs end at U+000D; U+000B is a line break inside one.
//
// The formatting becomes DCModel paragraph and run properties. PowerPoint's indent is where the first line (the
// bullet) starts and its left margin where the text starts, both from the text box's edge; DrawingML's indent is
// relative to the margin, so it's indent − margin, worked out with the master's values for whichever of the two a
// paragraph doesn't set. Colours given as scheme indexes are resolved with the slide's colour scheme. Every count and
// length is bounded; an exception that runs out ends the runs it was giving.
import DCColor
import DCModel

/// A colour: RGB, or an index into the colour scheme (ColorIndexStruct, [MS-PPT] 2.12.2).
struct ColorIndex: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, index: UInt8

    /// The colour, with `scheme` the slide's eight scheme colours; nil when undefined.
    func rgba(_ scheme: [Rgba]) -> Rgba? {
        if index == 0xFE { return Rgba.rgb(r, g, b) }
        return scheme.indices.contains(Int(index)) ? scheme[Int(index)] : nil
    }
}

/// Reads little-endian fields from a range of bytes; each read fails (nil) rather than run past the end.
struct Cursor {
    let b: [UInt8]
    var p: Int
    let end: Int

    mutating func u16() -> UInt16? { guard p + 2 <= end else { return nil }; defer { p += 2 }; return le16(b, p) }
    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    mutating func u32() -> UInt32? { guard p + 4 <= end else { return nil }; defer { p += 4 }; return le32(b, p) }
    mutating func color() -> ColorIndex? {
        guard p + 4 <= end else { return nil }
        defer { p += 4 }
        return ColorIndex(r: b[p], g: b[p + 1], b: b[p + 2], index: b[p + 3])
    }
    mutating func skip(_ n: Int) -> Bool { guard n >= 0, p + n <= end else { return false }; p += n; return true }
}

/// A TextPFException: paragraph formatting, each field nil when the exception doesn't set it.
struct PF: Equatable {
    var hasBullet: Bool?, bulletHasFont: Bool?, bulletHasColor: Bool?, bulletHasSize: Bool?
    var bulletChar: UInt16?, bulletFont: UInt16?, bulletSize: Int16?, bulletColor: ColorIndex?
    var align: UInt16?
    var lineSpacing: Int16?, spaceBefore: Int16?, spaceAfter: Int16?
    var leftMargin: Int16?, indent: Int16?
    var defaultTab: UInt16?

    /// The exception at the cursor; nil when it runs out.
    static func read(_ c: inout Cursor) -> PF? {
        guard let masks = c.u32() else { return nil }
        func has(_ bit: Int) -> Bool { masks & (1 << bit) != 0 }
        var f = PF()
        if masks & 0xF != 0 {
            guard let flags = c.u16() else { return nil }
            if has(0) { f.hasBullet = flags & 1 != 0 }
            if has(1) { f.bulletHasFont = flags & 2 != 0 }
            if has(2) { f.bulletHasColor = flags & 4 != 0 }
            if has(3) { f.bulletHasSize = flags & 8 != 0 }
        }
        if has(7) { guard let v = c.u16() else { return nil }; f.bulletChar = v }
        if has(4) { guard let v = c.u16() else { return nil }; f.bulletFont = v }
        if has(6) { guard let v = c.i16() else { return nil }; f.bulletSize = v }
        if has(5) { guard let v = c.color() else { return nil }; f.bulletColor = v }
        if has(11) { guard let v = c.u16() else { return nil }; f.align = v }
        if has(12) { guard let v = c.i16() else { return nil }; f.lineSpacing = v }
        if has(13) { guard let v = c.i16() else { return nil }; f.spaceBefore = v }
        if has(14) { guard let v = c.i16() else { return nil }; f.spaceAfter = v }
        if has(8) { guard let v = c.i16() else { return nil }; f.leftMargin = v }
        if has(10) { guard let v = c.i16() else { return nil }; f.indent = v }
        if has(15) { guard let v = c.u16() else { return nil }; f.defaultTab = v }
        if has(20) { guard let n = c.u16(), c.skip(Int(n) * 4) else { return nil } }                 // tabStops
        if has(16) { guard c.skip(2) else { return nil } }                                         // fontAlign
        if masks & (7 << 17) != 0 { guard c.skip(2) else { return nil } }                          // wrapFlags
        if has(21) { guard c.skip(2) else { return nil } }                                         // textDirection
        return f
    }

    /// This exception's fields over `base`'s.
    func over(_ base: PF?) -> PF {
        guard let base else { return self }
        var f = self
        f.hasBullet = hasBullet ?? base.hasBullet
        f.bulletHasFont = bulletHasFont ?? base.bulletHasFont
        f.bulletHasColor = bulletHasColor ?? base.bulletHasColor
        f.bulletHasSize = bulletHasSize ?? base.bulletHasSize
        f.bulletChar = bulletChar ?? base.bulletChar
        f.bulletFont = bulletFont ?? base.bulletFont
        f.bulletSize = bulletSize ?? base.bulletSize
        f.bulletColor = bulletColor ?? base.bulletColor
        f.align = align ?? base.align
        f.lineSpacing = lineSpacing ?? base.lineSpacing
        f.spaceBefore = spaceBefore ?? base.spaceBefore
        f.spaceAfter = spaceAfter ?? base.spaceAfter
        f.leftMargin = leftMargin ?? base.leftMargin
        f.indent = indent ?? base.indent
        f.defaultTab = defaultTab ?? base.defaultTab
        return f
    }

    /// DCModel paragraph properties: what this exception sets, with `base` (the master's merged values) for the
    /// half of the margin/indent pair it doesn't.
    func props(base: PF?, _ ctx: TextContext) -> ParaProps {
        var p = ParaProps()
        if let a = align { p.align = Self.align(a) }
        if leftMargin != nil || indent != nil {
            let margin = Double(leftMargin ?? base?.leftMargin ?? 0), first = Double(indent ?? base?.indent ?? 0)
            p.marginLeft = margin * PPT.pointsPerMasterUnit
            p.indent = (first - margin) * PPT.pointsPerMasterUnit
        }
        p.lineSpacing = lineSpacing.map(Self.spacing)
        p.spaceBefore = spaceBefore.map(Self.spacing)
        p.spaceAfter = spaceAfter.map(Self.spacing)
        if let t = defaultTab, t > 0 { p.defaultTab = Double(t) * PPT.pointsPerMasterUnit }
        let font = (bulletFont ?? base?.bulletFont).flatMap { ctx.font($0) }
        if let on = hasBullet {
            if !on {
                p.bullet = Bullet.none_
            } else {
                let c = bulletChar ?? base?.bulletChar ?? 0x2022
                p.bullet = .char(char: Self.bulletText(c, font: font))
            }
        } else if let c = bulletChar {
            p.bullet = .char(char: Self.bulletText(c, font: font))
        }
        if bulletHasFont != false, let f = bulletFont.flatMap({ ctx.font($0) }), !Self.symbolFont(f) { p.bulletFont = f }
        if bulletHasColor != false, let c = bulletColor?.rgba(ctx.scheme) { p.bulletColor = .rgb(c) }
        if bulletHasSize != false, let s = bulletSize, (25 ... 400).contains(s) { p.bulletSize = Double(s) / 100 }
        return p
    }

    /// ParaSpacing ([MS-PPT] 2.2.20): 0…13200 a percentage of the line, negative master units.
    static func spacing(_ v: Int16) -> Spacing {
        v >= 0 ? .pct(Double(min(v, 13200)) / 100) : .pts(Double(-Int(v)) * PPT.pointsPerMasterUnit)
    }

    static func align(_ a: UInt16) -> Align? {
        switch a {
        case 0: .left
        case 1: .center
        case 2: .right
        case 3: .justify
        case 4: .distributed
        case 6: .justLow
        default: nil
        }
    }

    /// Symbol fonts whose characters are mapped to Unicode look-alikes for bullets rather than drawn in the font.
    static func symbolFont(_ name: String) -> Bool {
        ["wingdings", "wingdings 2", "wingdings 3", "symbol", "webdings", "monotype sorts", "zapfdingbats"].contains(name.lowercased())
    }

    /// A bullet character as Unicode. Symbol-font characters (often written in the private-use range, U+F0xx) are
    /// mapped to their Unicode look-alikes; anything else unusable becomes "•".
    static func bulletText(_ c: UInt16, font: String?) -> String {
        let code = c >= 0xF000 && c <= 0xF0FF ? c - 0xF000 : c
        if (font.map(symbolFont) ?? false) || (0xF000 ... 0xF0FF).contains(c) {
            let wingdings: [UInt16: String] = [0x6C: "●", 0x6E: "■", 0x71: "❑", 0x75: "◆", 0x76: "❖", 0xA7: "▪", 0xA8: "◻",
                                               0xD8: "➢", 0xFC: "✓", 0xE0: "➔", 0x9F: "•"]
            let symbol: [UInt16: String] = [0xB7: "•", 0x2D: "–", 0x6F: "o"]
            if font?.lowercased() == "symbol", let s = symbol[code] { return s }
            if let s = wingdings[code] { return s }
            return "•"
        }
        guard c >= 0x20, !UTF16.isLeadSurrogate(c), !UTF16.isTrailSurrogate(c), !(0xE000 ... 0xF8FF).contains(c) else { return "•" }
        return String(decoding: [c], as: UTF16.self)
    }
}

/// A TextCFException: character formatting.
struct CF: Equatable {
    var bold: Bool?, italic: Bool?, underline: Bool?
    var fontRef: UInt16?
    /// East Asian (newEAFontRef, else oldEAFontRef), complex script and symbol fonts.
    var eaFontRef: UInt16?, csFontRef: UInt16?, symbolFontRef: UInt16?
    var size: Int16?
    var color: ColorIndex?

    static func read(_ c: inout Cursor) -> CF? {
        guard let masks = c.u32() else { return nil }
        func has(_ bit: Int) -> Bool { masks & (1 << bit) != 0 }
        var f = CF()
        if masks & 0x3FFF != 0 {
            guard let style = c.u16() else { return nil }
            if has(0) { f.bold = style & 1 != 0 }
            if has(1) { f.italic = style & 2 != 0 }
            if has(2) { f.underline = style & 4 != 0 }
        }
        if has(16) { guard let v = c.u16() else { return nil }; f.fontRef = v }
        if has(21) { guard let v = c.u16() else { return nil }; f.eaFontRef = v }
        if has(22) { guard c.skip(2) else { return nil } }                               // ansiFontRef
        if has(23) { guard let v = c.u16() else { return nil }; f.symbolFontRef = v }
        if has(17) { guard let v = c.i16() else { return nil }; f.size = v }
        if has(18) { guard let v = c.color() else { return nil }; f.color = v }
        if has(19) { guard c.skip(2) else { return nil } }                               // position
        if has(20) { guard c.skip(4) else { return nil } }                               // pp10runid
        if has(24) { guard let v = c.u16() else { return nil }; f.eaFontRef = v }
        if has(25) { guard let v = c.u16() else { return nil }; f.csFontRef = v }
        if has(26) { guard c.skip(4) else { return nil } }                               // pp11ext
        return f
    }

    func over(_ base: CF?) -> CF {
        guard let base else { return self }
        return CF(bold: bold ?? base.bold, italic: italic ?? base.italic, underline: underline ?? base.underline,
                  fontRef: fontRef ?? base.fontRef, eaFontRef: eaFontRef ?? base.eaFontRef, csFontRef: csFontRef ?? base.csFontRef,
                  symbolFontRef: symbolFontRef ?? base.symbolFontRef, size: size ?? base.size, color: color ?? base.color)
    }

    func props(_ ctx: TextContext) -> RunProps {
        var r = RunProps()
        r.bold = bold
        r.italic = italic
        if let u = underline { r.underline = u ? "sng" : "none" }
        if let s = size, (1 ... 4000).contains(s) { r.size = Double(s) }
        if let f = fontRef.flatMap({ ctx.font($0) }) { r.font = f }
        if let f = eaFontRef.flatMap({ ctx.font($0) }) { r.fontEa = f }
        if let f = csFontRef.flatMap({ ctx.font($0) }) { r.fontCs = f }
        if let f = symbolFontRef.flatMap({ ctx.font($0) }) { r.fontSym = f }
        if let c = color?.rgba(ctx.scheme) { r.fill = .solid(color: .rgb(c)) }
        return r
    }
}

/// What text formatting is resolved against: the document's fonts, the slide's colour scheme, and the master's
/// merged styles by text type.
struct TextContext {
    var fonts: [String]
    /// The eight scheme colours ([MS-PPT] 2.4.17 SlideSchemeColorSchemeAtom).
    var scheme: [Rgba]
    var styles: MasterStyles

    func font(_ i: UInt16) -> String? { fonts.indices.contains(Int(i)) ? fonts[Int(i)] : nil }
}

/// A text body as read: its type, characters and runs.
struct PPTText {
    /// Tx_TYPE_* ([MS-PPT] 2.13.33): 0 title, 1 body, 2 notes, 4 other, 5 center body, 6 center title, 7 half body,
    /// 8 quarter body.
    var type: UInt32 = 4
    var chars: [UInt16] = []
    var paragraphs: [(count: Int, level: UInt8, pf: PF)] = []
    var characters: [(count: Int, cf: CF)] = []
    /// Hyperlinks on character ranges (TextInteractiveInfoAtom after a MouseClickInteractiveInfoContainer), each with
    /// its ExHyperlinkId.
    var links: [(range: Range<Int>, hyperlink: UInt32)] = []
    /// The TextRulerAtom's margins and indents by level ([MS-PPT] 2.9.30): over the master's, under each
    /// paragraph's own.
    var ruler: [Int: PF] = [:]

    /// The text bodies in a run of records (a client textbox, or one slide's part of a slide list): each starts at a
    /// TextHeaderAtom and takes the records after it up to the next one.
    static func bodies(_ b: [UInt8], _ records: [Record]) -> [PPTText] {
        var out: [PPTText] = []
        var pendingLink: UInt32?
        for r in records {
            switch r.type {
            case RT.textHeaderAtom:
                out.append(PPTText(type: le32(b, r.body.lowerBound)))
            case RT.textCharsAtom:
                guard !out.isEmpty else { continue }
                var u: [UInt16] = []
                u.reserveCapacity(r.body.count / 2)
                var p = r.body.lowerBound
                while p + 2 <= r.body.upperBound { u.append(le16(b, p)); p += 2 }
                out[out.count - 1].chars = u
            case RT.textBytesAtom:
                guard !out.isEmpty else { continue }
                out[out.count - 1].chars = b[r.body].map { UInt16($0) }
            case RT.styleTextPropAtom:
                guard !out.isEmpty else { continue }
                out[out.count - 1].readStyles(b, r.body)
            case RT.textRulerAtom:
                guard !out.isEmpty else { continue }
                out[out.count - 1].ruler = Self.ruler(b, r.body)
            case RT.interactiveInfo where r.instance == 0:
                // A mouse-click action: its InteractiveInfoAtom's hyperlink, for the TextInteractiveInfoAtom after it.
                pendingLink = nil
                if let atom = r.children(b).first(where: { $0.type == RT.interactiveInfoAtom }), atom.body.count >= 16 {
                    let id = le32(b, atom.body.lowerBound + 4)
                    if id != 0 { pendingLink = id }
                }
            case RT.textInteractiveInfoAtom where r.instance == 0:
                guard !out.isEmpty, let link = pendingLink, r.body.count >= 8 else { continue }
                let begin = Int(le32(b, r.body.lowerBound)), end = Int(le32(b, r.body.lowerBound + 4))
                if begin >= 0, end > begin { out[out.count - 1].links.append((begin ..< end, link)) }
                pendingLink = nil
            default: continue
            }
        }
        return out
    }

    /// A TextRuler: masks, then cLevels, defaultTabSize and tab stops when present, then each level's left margin
    /// and indent when present. Only the margins and indents are kept.
    static func ruler(_ b: [UInt8], _ range: Range<Int>) -> [Int: PF] {
        var c = Cursor(b: b, p: range.lowerBound, end: range.upperBound)
        guard let masks = c.u32() else { return [:] }
        func has(_ bit: Int) -> Bool { masks & (1 << bit) != 0 }
        if has(1) { guard c.skip(2) else { return [:] } }
        if has(0) { guard c.skip(2) else { return [:] } }
        if has(2) { guard let n = c.u16(), c.skip(Int(n) * 4) else { return [:] } }
        var out: [Int: PF] = [:]
        for level in 0 ..< 5 {
            var f = PF()
            if has(3 + level) { guard let v = c.i16() else { break }; f.leftMargin = v }
            if has(8 + level) { guard let v = c.i16() else { break }; f.indent = v }
            if f.leftMargin != nil || f.indent != nil { out[level] = f }
        }
        return out
    }

    /// The StyleTextPropAtom's paragraph runs, then its character runs.
    mutating func readStyles(_ b: [UInt8], _ range: Range<Int>) {
        let total = chars.count + 1
        var c = Cursor(b: b, p: range.lowerBound, end: range.upperBound)
        var covered = 0
        while covered < total {
            guard let count = c.u32(), let level = c.u16(), let pf = PF.read(&c), count > 0 else { break }
            paragraphs.append((Int(count), UInt8(min(level, 8)), pf))
            covered += Int(count)
        }
        covered = 0
        while covered < total {
            guard let count = c.u32(), let cf = CF.read(&c), count > 0 else { break }
            characters.append((Int(count), cf))
            covered += Int(count)
        }
    }

    /// The text as DCModel paragraphs. `ctx.styles` gives the master's values for this text type (for the
    /// margin/indent pair); `hyperlinks` maps ExHyperlinkIds to links.
    func body(_ ctx: TextContext, hyperlinks: [UInt32: Hyperlink] = [:]) -> TextBody {
        var paras: [Paragraph] = []
        var start = 0
        var pfIndex = 0, pfEnd = paragraphs.first?.count ?? Int.max
        var cfIndex = 0, cfEnd = characters.first?.count ?? Int.max
        func pf(_ at: Int) -> (count: Int, level: UInt8, pf: PF)? {
            while at >= pfEnd, pfIndex + 1 < paragraphs.count { pfIndex += 1; pfEnd += paragraphs[pfIndex].count }
            return paragraphs.indices.contains(pfIndex) ? paragraphs[pfIndex] : nil
        }
        func cf(_ at: Int) -> CF? {
            while at >= cfEnd, cfIndex + 1 < characters.count { cfIndex += 1; cfEnd += characters[cfIndex].count }
            return characters.indices.contains(cfIndex) ? characters[cfIndex].cf : nil
        }
        func link(_ at: Int) -> Hyperlink? { links.first { $0.range.contains(at) }.flatMap { hyperlinks[$0.hyperlink] } }
        var i = 0
        while i <= chars.count {
            guard i == chars.count || chars[i] == 0x0D else { i += 1; continue }
            let p = pf(start)
            let level = p?.level ?? 0
            var para = Paragraph(level: level)
            let rule = ruler[Int(level)]
            let base = rule.map { $0.over(ctx.styles.pf(type, level)) } ?? ctx.styles.pf(type, level)
            if let p {
                para.props = p.pf.over(rule).props(base: base, ctx)
            } else if let rule {
                para.props = rule.props(base: base, ctx)
            }
            // Runs: a new one wherever the character run or the hyperlink changes, or a line break comes.
            var j = start
            while j < i {
                if chars[j] == 0x0B {
                    para.runs.append(Run(text: "", props: RunProps(), kind: .break))
                    j += 1
                    continue
                }
                let c = cf(j), l = link(j)
                let runEnd = min(i, cfEnd)
                var k = j
                while k < runEnd, chars[k] != 0x0B, link(k) == l { k += 1 }
                let text = String(decoding: chars[j ..< max(j, k)], as: UTF16.self)
                if !text.isEmpty {
                    var props = c?.props(ctx) ?? RunProps()
                    props.link = l
                    para.runs.append(Run(text: text, props: props, kind: .text))
                }
                j = max(k, j + 1)
            }
            paras.append(para)
            start = i + 1
            i += 1
        }
        return TextBody(paragraphs: paras)
    }
}
