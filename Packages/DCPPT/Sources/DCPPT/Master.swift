// DCPPT — the masters' side of a `.ppt` (P2b of Docs/plans/Legacy-PPT-and-Encryption.md):
//
// - Text styles ([MS-PPT] 2.9.35 TextMasterStyleAtom): per text type (title, body, notes, other, center body…), up to
//   five levels of TextPFException and TextCFException. The document's defaults (in the Environment) are merged under
//   the main master's. Center title, center body, half body and quarter body hold only their differences from title
//   and body.
// - Colour schemes (2.4.17 SlideSchemeColorSchemeAtom, eight colours) on masters and on slides that don't follow
//   their master's.
// - Which master a slide follows (SlideAtom.masterIdRef → MasterPersistAtom → a MainMasterContainer, or a title
//   master that names its main master in turn), and what it inherits from it (SlideFlags).
// - Backgrounds: the drawing's background shape ([MS-ODRAW] fBackground), its fill type and colour.
// - Headers and footers (HeadersFootersContainer, instance 3 for slides) and hyperlinks (2.10.16
//   ExHyperlinkContainer in the ExObjList).
//
// DCModel has one master per presentation here: the first main master's styles, scheme and background go onto the
// default master; a slide whose master or scheme differs carries its colours resolved, so it still looks right.
import DCColor
import DCGeometry
import DCModel

/// The master text styles, by text type and level, merged.
struct MasterStyles {
    /// Text type → level → (paragraph, character) exceptions.
    var levels: [UInt32: [Int: (pf: PF, cf: CF)]] = [:]

    /// The text type a type's differences are taken against: center title → title, center/half/quarter body → body.
    static func baseType(_ t: UInt32) -> UInt32? {
        switch t {
        case 6: 0
        case 5, 7, 8: 1
        default: nil
        }
    }

    func entry(_ type: UInt32, _ level: UInt8) -> (pf: PF, cf: CF)? {
        let own = levels[type]?[Int(level)]
        guard let base = Self.baseType(type), let b = levels[base]?[Int(level)] else { return own }
        guard let own else { return b }
        return (own.pf.over(b.pf), own.cf.over(b.cf))
    }

    func pf(_ type: UInt32, _ level: UInt8) -> PF? { entry(type, level)?.pf }

    /// The styles in the document's Environment and a main master: the master's over the document's, level by level.
    static func read(_ b: [UInt8], environment: Record?, _ eb: [UInt8], master: Record?) -> MasterStyles {
        var s = MasterStyles()
        func add(_ bytes: [UInt8], _ container: Record?) {
            for atom in container?.children(bytes) ?? [] where atom.type == RT.textMasterStyleAtom {
                let type = UInt32(atom.instance)
                var c = Cursor(b: bytes, p: atom.body.lowerBound, end: atom.body.upperBound)
                guard let count = c.u16() else { continue }
                for i in 0 ..< min(Int(count), 5) {
                    var level = i
                    if type >= 5 { guard let l = c.u16() else { break }; level = min(Int(l), 4) }
                    guard let pf = PF.read(&c), let cf = CF.read(&c) else { break }
                    let old = s.levels[type]?[level]
                    s.levels[type, default: [:]][level] = (pf.over(old?.pf), cf.over(old?.cf))
                }
            }
        }
        add(eb, environment)
        add(b, master)
        // A level takes what it doesn't set from the level above it, as PowerPoint writes them: its own files give
        // the body's second to fifth levels only their margins, the bullet and spacing coming from the first.
        for (type, levels) in s.levels {
            for l in 1 ..< 5 {
                guard let above = s.levels[type]?[l - 1] else { continue }
                let own = levels[l]
                s.levels[type]?[l] = own.map { ($0.pf.over(above.pf), $0.cf.over(above.cf)) } ?? above
            }
        }
        return s
    }

    /// A DCModel list style for `type`: its levels' paragraph and run properties. With `own`, only the type's own
    /// differences (a shape's list style, over the master's); otherwise merged with its base type.
    func listStyle(_ type: UInt32, own: Bool = false, _ ctx: TextContext) -> ListStyle {
        var ls = ListStyle(levels: Array(repeating: nil, count: 5))
        for l in 0 ..< 5 {
            let e = own ? levels[type]?[l] : entry(type, UInt8(l))
            guard let e else { continue }
            let base = own ? Self.baseType(type).flatMap { levels[$0]?[l]?.pf } : nil
            ls.levels[l] = LevelStyle(para: e.pf.props(base: base, ctx), run: e.cf.props(ctx))
        }
        return ls
    }
}

/// The masters and slides' shared parts.
struct Masters {
    /// Master id → its container's persist object.
    var byId: [UInt32: (bytes: [UInt8], record: Record)] = [:]
    /// The first main master: its styles, scheme and background become the DCModel master's.
    var main: (bytes: [UInt8], record: Record)?

    static func read(_ file: PPTFile, _ doc: [UInt8], _ document: [Record]) -> Masters {
        var m = Masters()
        guard let list = document.first(where: { $0.type == RT.slideListWithText && $0.instance == 1 }) else { return m }
        for r in list.children(doc) where r.type == RT.slidePersistAtom && r.body.count >= 16 {
            guard let o = file.object(le32(doc, r.body.lowerBound)), let c = Record(o, at: 0), c.isContainer else { continue }
            m.byId[le32(doc, r.body.lowerBound + 12)] = (o, c)
            if m.main == nil, c.type == RT.mainMaster { m.main = (o, c) }
        }
        return m
    }

    /// Every master shape's properties by its shape id: what a slide shape naming it in hspMaster ([MS-ODRAW]
    /// 2.3.2.1) takes for the properties it doesn't set.
    func shapeProps() -> [UInt32: [UInt16: UInt32]] {
        var out: [UInt32: [UInt16: UInt32]] = [:]
        func add(_ list: [DrawnShape]) {
            for d in list {
                out[d.id] = d.props
                add(d.children)
            }
        }
        for (b, r) in byId.values { add(Drawing.tree(b, r).shapes) }
        return out
    }

    /// A slide's (or title master's) SlideAtom: its master id and SlideFlags.
    static func slideAtom(_ b: [UInt8], _ c: Record) -> (masterId: UInt32, flags: UInt16)? {
        guard let a = c.children(b).first(where: { $0.type == RT.slideAtom }), a.body.count >= 22 else { return nil }
        return (le32(b, a.body.lowerBound + 12), le16(b, a.body.lowerBound + 20))
    }

    /// A container's own colour scheme.
    static func scheme(_ b: [UInt8], _ c: Record) -> [Rgba]? {
        guard let a = c.children(b).first(where: { $0.type == RT.colorSchemeAtom && $0.instance == 1 }), a.body.count >= 32 else { return nil }
        let p = a.body.lowerBound
        return (0 ..< 8).map { Rgba.rgb(b[p + $0 * 4], b[p + $0 * 4 + 1], b[p + $0 * 4 + 2]) }
    }

    /// The colour scheme a master (main or title) gives the slides that follow it.
    func scheme(master id: UInt32, depth: Int = 0) -> [Rgba]? {
        guard depth < 4, let (b, c) = byId[id] else { return nil }
        if let own = Self.scheme(b, c) { return own }
        if let atom = Self.slideAtom(b, c), atom.masterId != id { return scheme(master: atom.masterId, depth: depth + 1) }
        return nil
    }

    /// The colour scheme in force on a slide: its own unless it follows its master's (fMasterScheme).
    func scheme(slide b: [UInt8], _ c: Record) -> [Rgba]? {
        let atom = Self.slideAtom(b, c)
        if let atom, atom.flags & 0x2 == 0, let own = Self.scheme(b, c) { return own }
        return atom.flatMap { scheme(master: $0.masterId) } ?? main.flatMap { Self.scheme($0.bytes, $0.record) }
    }

    /// A drawing's background shape's fill as DCModel (solid colours; a gradient by its first colour; a picture not
    /// yet), nil when it has none.
    static func background(_ b: [UInt8], _ c: Record, scheme: [Rgba]) -> Background? {
        guard let bg = Drawing.background(b, c) else { return nil }
        let type = bg.props[0x0180] ?? 0
        guard [0, 4, 5, 6, 7].contains(type), let color = bg.props[0x0181] else { return nil }
        return Self.color(color, scheme).map { .fill(fill: .solid(color: .rgb($0))) }
    }

    /// An OfficeArtCOLORREF ([MS-ODRAW] 2.2.2): red, green, blue and flags; with fSchemeIndex (0x08) the red byte is a
    /// scheme index.
    static func color(_ v: UInt32, _ scheme: [Rgba]) -> Rgba? {
        let r = UInt8(v & 0xFF), g = UInt8(v >> 8 & 0xFF), b = UInt8(v >> 16 & 0xFF), flags = UInt8(v >> 24)
        if flags & 0x08 != 0 { return scheme.indices.contains(Int(r)) ? scheme[Int(r)] : nil }
        if flags & 0x17 != 0 { return nil }   // palette and system colours: no palette to look them up in
        return Rgba.rgb(r, g, b)
    }

    /// The theme colours for a PowerPoint colour scheme: background → lt1, text → dk1, title text → dk2, fills → lt2,
    /// the accents → accent1–3, and the hyperlink accents → hlink and folHlink; accent4–6 keep the theme's.
    static func themeColors(_ s: [Rgba], _ theme: ColorScheme) -> ColorScheme {
        guard s.count == 8, theme.colors.count == 12 else { return theme }
        var c = theme.colors
        c[0] = s[1]; c[1] = s[0]; c[2] = s[3]; c[3] = s[4]
        c[4] = s[5]; c[5] = s[6]; c[6] = s[7]
        c[10] = s[6]; c[11] = s[7]
        return ColorScheme(name: theme.name, colors: c)
    }
}

enum Document {
    /// The slides' headers and footers (HeadersFootersContainer of instance 3): what shows, the footer text and a fixed
    /// date.
    static func headerFooter(_ b: [UInt8], _ document: [Record]) -> HeaderFooter? {
        guard let hf = document.first(where: { $0.type == RT.headersFooters && $0.instance == 3 }) else { return nil }
        let kids = hf.children(b)
        guard let atom = kids.first(where: { $0.type == RT.headersFootersAtom }), atom.body.count >= 4 else { return nil }
        let format = Int(Int16(bitPattern: le16(b, atom.body.lowerBound))), flags = le16(b, atom.body.lowerBound + 2)
        func string(_ instance: UInt16) -> String {
            guard let r = kids.first(where: { $0.type == RT.cString && $0.instance == instance }) else { return "" }
            return unicode(b, r.body)
        }
        return HeaderFooter(date: flags & 0x1 != 0, slideNumber: flags & 0x8 != 0, footer: flags & 0x20 != 0,
                            header: flags & 0x10 != 0, footerText: string(2), dateText: flags & 0x4 != 0 ? string(0) : "",
                            dateFormat: (0 ... 12).contains(format) ? "datetime\(format + 1)" : "")
    }

    /// The document's hyperlinks by ExHyperlinkId: a target (and location within it) becomes a URL link.
    static func hyperlinks(_ b: [UInt8], _ document: [Record]) -> [UInt32: Hyperlink] {
        guard let list = document.first(where: { $0.type == RT.externalObjectList }) else { return [:] }
        var out: [UInt32: Hyperlink] = [:]
        for h in list.children(b) where h.type == RT.externalHyperlink {
            let kids = h.children(b)
            guard let atom = kids.first(where: { $0.type == RT.externalHyperlinkAtom }), atom.body.count >= 4 else { continue }
            func string(_ instance: UInt16) -> String {
                kids.first { $0.type == RT.cString && $0.instance == instance }.map { unicode(b, $0.body) } ?? ""
            }
            let target = string(1), location = string(3)
            guard !target.isEmpty else { continue }
            let url = location.isEmpty ? target : "\(target)#\(location)"
            out[le32(b, atom.body.lowerBound)] = Hyperlink(action: .url(url: url), tooltip: "", highlightClick: false, stopSound: false)
        }
        return out
    }

    /// A CString's UTF-16 text (no terminator).
    static func unicode(_ b: [UInt8], _ r: Range<Int>) -> String {
        var u: [UInt16] = []
        var p = r.lowerBound
        while p + 2 <= r.upperBound { u.append(le16(b, p)); p += 2 }
        if let z = u.firstIndex(of: 0) { u.removeSubrange(z...) }
        return String(decoding: u, as: UTF16.self)
    }
}
