// DCPPT — text ([MS-PPT] 2.9): a text body is a TextHeaderAtom (its type), the characters (TextCharsAtom, UTF-16, or
// TextBytesAtom, one byte per character) and a StyleTextPropAtom: paragraph runs, then character runs, each covering
// a count of characters. The run arrays have no counts of their own: they run until they cover the text plus one
// (an implied final paragraph mark). Each run's formatting is an exception record whose fields are present only when
// its mask says so, in a fixed order (2.9.20 TextPFException, 2.9.13 TextCFException); a field this reader doesn't
// use is still stepped over by its size. Paragraphs end at U+000D; U+000B is a line break inside one.
//
// P2a brings over the text, paragraph levels, alignment and bullets, and bold, italic, underline, size, font and
// RGB colour. Colours from the colour scheme and the master text styles come in P2b. Every count and length is
// bounded; a style record that runs out ends the runs it was giving.
import DCColor
import DCModel

/// A text body as read: its type, characters and runs.
struct PPTText {
    /// Tx_TYPE_* ([MS-PPT] 2.13.33): 0 title, 1 body, 2 notes, 4 other, 5 center body, 6 center title, 7 half body,
    /// 8 quarter body.
    var type: UInt32 = 4
    var chars: [UInt16] = []
    var paragraphs: [ParagraphRun] = []
    var characters: [CharacterRun] = []

    struct ParagraphRun {
        var count: Int
        var level: UInt8
        var align: UInt16?
        var bullet: Bool?
        var bulletChar: UInt16?
    }

    struct CharacterRun {
        var count: Int
        var bold: Bool?, italic: Bool?, underline: Bool?
        var fontRef: UInt16?
        var size: Int16?
        /// An RGB colour (ColorIndexStruct with index 0xFE); scheme colours come in P2b.
        var rgb: (UInt8, UInt8, UInt8)?
    }

    /// The text bodies in a run of records (a client textbox, or one slide's part of a slide list): each starts at a
    /// TextHeaderAtom and takes the records after it up to the next one.
    static func bodies(_ b: [UInt8], _ records: [Record]) -> [PPTText] {
        var out: [PPTText] = []
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
            default: continue
            }
        }
        return out
    }

    /// The StyleTextPropAtom's paragraph runs, then its character runs.
    mutating func readStyles(_ b: [UInt8], _ range: Range<Int>) {
        let total = chars.count + 1
        var p = range.lowerBound
        let end = range.upperBound
        func u16() -> UInt16? { guard p + 2 <= end else { return nil }; defer { p += 2 }; return le16(b, p) }
        func u32() -> UInt32? { guard p + 4 <= end else { return nil }; defer { p += 4 }; return le32(b, p) }
        func skip(_ n: Int) -> Bool { guard p + n <= end else { return false }; p += n; return true }

        var covered = 0
        paragraphs: while covered < total {
            guard let count = u32(), let level = u16(), let masks = u32() else { break }
            var run = ParagraphRun(count: Int(count), level: UInt8(min(level, 8)))
            func has(_ bit: Int) -> Bool { masks & (1 << bit) != 0 }
            if masks & 0xF != 0 {                                   // bulletFlags
                guard let flags = u16() else { break paragraphs }
                if has(0) { run.bullet = flags & 1 != 0 }
            }
            if has(7) { guard let c = u16() else { break paragraphs }; run.bulletChar = c }       // bulletChar
            if has(4) { guard skip(2) else { break paragraphs } }                                // bulletFontRef
            if has(6) { guard skip(2) else { break paragraphs } }                                // bulletSize
            if has(5) { guard skip(4) else { break paragraphs } }                                // bulletColor
            if has(11) { guard let a = u16() else { break paragraphs }; run.align = a }          // textAlignment
            for bit in [12, 13, 14, 8, 10, 15] where has(bit) {                                  // spacing, margins, tab size
                guard skip(2) else { break paragraphs }
            }
            if has(20) {                                                                         // tabStops
                guard let n = u16(), skip(Int(n) * 4) else { break paragraphs }
            }
            if has(16) { guard skip(2) else { break paragraphs } }                               // fontAlign
            if masks & (7 << 17) != 0 { guard skip(2) else { break paragraphs } }                // wrapFlags
            if has(21) { guard skip(2) else { break paragraphs } }                               // textDirection
            guard run.count > 0 else { break }
            paragraphs.append(run)
            covered += run.count
        }

        covered = 0
        while covered < total {
            guard let count = u32(), let masks = u32() else { break }
            var run = CharacterRun(count: Int(count))
            func has(_ bit: Int) -> Bool { masks & (1 << bit) != 0 }
            if masks & 0x3FFF != 0 {                                // fontStyle (bold … emboss, fHasStyle)
                guard let style = u16() else { break }
                if has(0) { run.bold = style & 1 != 0 }
                if has(1) { run.italic = style & 2 != 0 }
                if has(2) { run.underline = style & 4 != 0 }
            }
            if has(16) { guard let f = u16() else { break }; run.fontRef = f }   // fontRef
            var ok = true
            for bit in [21, 22, 23] where has(bit) { ok = ok && skip(2) }       // East Asian, ANSI, symbol fonts
            guard ok else { break }
            if has(17) { guard let s = u16() else { break }; run.size = Int16(bitPattern: s) }
            if has(18) {                                                         // color: red, green, blue, index
                guard p + 4 <= end else { break }
                if b[p + 3] == 0xFE { run.rgb = (b[p], b[p + 1], b[p + 2]) }
                p += 4
            }
            if has(19) { guard skip(2) else { break } }                         // position
            if has(20) { guard skip(4) else { break } }                         // pp10runid
            if has(24) { guard skip(2) else { break } }                         // newEAFontRef
            if has(25) { guard skip(2) else { break } }                         // csFontRef
            if has(26) { guard skip(4) else { break } }                         // pp11ext
            guard run.count > 0 else { break }
            characters.append(run)
            covered += run.count
        }
    }

    /// The text as DCModel paragraphs, with `fonts` the document's font collection.
    func body(fonts: [String]) -> TextBody {
        // Split at paragraph marks; each paragraph's style from the paragraph run covering its first character.
        var paras: [Paragraph] = []
        var start = 0
        var pfIndex = 0, pfEnd = paragraphs.first?.count ?? Int.max
        var cfIndex = 0, cfEnd = characters.first?.count ?? Int.max
        var i = 0
        func pf(_ at: Int) -> ParagraphRun? {
            while at >= pfEnd, pfIndex + 1 < paragraphs.count { pfIndex += 1; pfEnd += paragraphs[pfIndex].count }
            return paragraphs.indices.contains(pfIndex) ? paragraphs[pfIndex] : nil
        }
        func cf(_ at: Int) -> CharacterRun? {
            while at >= cfEnd, cfIndex + 1 < characters.count { cfIndex += 1; cfEnd += characters[cfIndex].count }
            return characters.indices.contains(cfIndex) ? characters[cfIndex] : nil
        }
        while i <= chars.count {
            guard i == chars.count || chars[i] == 0x0D else { i += 1; continue }
            let p = pf(start)
            var para = Paragraph(level: p?.level ?? 0)
            if let a = p?.align { para.props.align = Self.align(a) }
            if p?.bullet == false { para.props.bullet = Bullet.none_ }
            if p?.bullet == true {
                // A character from a symbol font's private range (Wingdings…) needs the bullet's font, which comes in
                // P2b; until then such a bullet is drawn as "•".
                let c = p?.bulletChar ?? 0x2022
                let usable = c >= 0x20 && !(0xE000 ... 0xF8FF).contains(c) && !UTF16.isLeadSurrogate(c) && !UTF16.isTrailSurrogate(c)
                para.props.bullet = .char(char: usable ? String(decoding: [c], as: UTF16.self) : "•")
            }
            // Runs: a new one wherever the character run changes or a line break comes.
            var j = start
            while j < i {
                if chars[j] == 0x0B {
                    para.runs.append(Run(text: "", props: RunProps(), kind: .break))
                    j += 1
                    continue
                }
                let c = cf(j)
                let runEnd = min(i, cfEnd)
                var k = j
                while k < runEnd, chars[k] != 0x0B { k += 1 }
                let text = String(decoding: chars[j ..< max(j, k)], as: UTF16.self)
                if !text.isEmpty { para.runs.append(Run(text: text, props: Self.props(c, fonts), kind: .text)) }
                j = max(k, j + 1)
            }
            paras.append(para)
            start = i + 1
            i += 1
        }
        return TextBody(paragraphs: paras)
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

    static func props(_ c: CharacterRun?, _ fonts: [String]) -> RunProps {
        var r = RunProps()
        guard let c else { return r }
        r.bold = c.bold
        r.italic = c.italic
        if let u = c.underline { r.underline = u ? "sng" : "none" }
        if let s = c.size, (1 ... 4000).contains(s) { r.size = Double(s) }
        if let f = c.fontRef, fonts.indices.contains(Int(f)) { r.font = fonts[Int(f)] }
        if let (red, green, blue) = c.rgb { r.fill = .solid(color: .rgb(Rgba.rgb(red, green, blue))) }
        return r
    }
}
