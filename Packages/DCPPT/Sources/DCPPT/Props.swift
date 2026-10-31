// DCPPT — a shape's OfficeArt properties ([MS-ODRAW] 2.3) as DCModel: its fill, line, shadow and text frame. A
// property the shape doesn't set comes from the drawing's defaults (the OfficeArtDggContainer's options, where
// PowerPoint puts the default shape's fill and line) and then from the specification's default. A placeholder takes
// only what it or its master's placeholder (hspMaster) sets: the rest comes from its layout, as in DrawingML.
import DCColor
import Darwin
import DCModel

struct ShapeProps {
    let b: [UInt8]
    let shape: DrawnShape
    /// What the shape doesn't set comes from these, in order: the master shape it names (hspMaster), then the
    /// drawing group's defaults.
    let defaults: [[UInt16: UInt32]]
    let scheme: [Rgba]
    /// Scheme colours stay theme colours when the slide uses its master's colours; otherwise they are resolved.
    let linked: Bool
    /// The pictures' media and the patterns' presets.
    let pictures: PictureRefs

    init(_ b: [UInt8], _ shape: DrawnShape, defaults: [UInt16: UInt32], master: [UInt16: UInt32]? = nil, scheme: [Rgba],
         linked: Bool, pictures: PictureRefs = PictureRefs()) {
        self.b = b
        self.shape = shape
        self.defaults = shape.placeholder == nil ? [master ?? [:], defaults] : [master ?? [:]]
        self.scheme = scheme
        self.linked = linked
        self.pictures = pictures
    }

    func value(_ id: UInt16) -> UInt32? { shape.props[id] ?? defaults.lazy.compactMap { $0[id] }.first }
    func int(_ id: UInt16) -> Int32? { value(id).map { Int32(bitPattern: $0) } }
    /// A FixedPoint ([MS-OSHARED] 2.2.1.6): 16.16.
    func fixed(_ id: UInt16) -> Double? { int(id).map { Double($0) / 65536 } }
    /// EMUs as points.
    func points(_ id: UInt16) -> Double? { int(id).map { Double($0) / 12700 } }
    /// Whether the shape itself sets any of these properties.
    func sets(_ ids: UInt16...) -> Bool { ids.contains { shape.props[$0] != nil } }
    /// Whether the shape or one it inherits from sets any of these (for a placeholder, its master's placeholder).
    func given(_ ids: UInt16...) -> Bool { ids.contains { value($0) != nil } }

    /// A boolean property's flag ([MS-ODRAW] 2.3, "… Boolean Properties"): the shape's when its fUse bit (16 above
    /// the flag) says it sets it, else the defaults', else `fallback`.
    func flag(_ id: UInt16, _ bit: UInt32, _ fallback: Bool) -> Bool {
        for v in [shape.props[id]] + defaults.map({ $0[id] }) {
            if let v, v & (1 << (bit + 16)) != 0 { return v & (1 << bit) != 0 }
        }
        return fallback
    }

    /// A complex property's IMsoArray ([MS-ODRAW] 2.2.51): its elements' bytes. A size of 0xFFF0 means 4-byte elements.
    func array(_ id: UInt16) -> (size: Int, elements: [Range<Int>])? {
        guard let r = shape.complex[id], r.count >= 6 else { return nil }
        let n = Int(le16(b, r.lowerBound)), raw = Int(le16(b, r.lowerBound + 4))
        let size = raw == 0xFFF0 ? 4 : raw
        guard size > 0, size <= 64 else { return nil }
        let count = min(n, (r.count - 6) / size)
        return (size, (0 ..< count).map { r.lowerBound + 6 + $0 * size ..< r.lowerBound + 6 + ($0 + 1) * size })
    }

    /// A complex property's UTF-16 string (wzName, gtextUNICODE…), up to its terminator.
    func string(_ id: UInt16) -> String? {
        guard let r = shape.complex[id] else { return nil }
        let s = Document.unicode(b, r)
        return s.isEmpty ? nil : s
    }

    // MARK: Colours

    /// The colour scheme's entries as theme colours: background, text, shadow, title text, fills, accent, accent and
    /// hyperlink, accent and followed hyperlink (the mapping `Masters.themeColors` makes). The shadow colour has no slot.
    static let slots: [SchemeSlot?] = [.lt1, .dk1, nil, .dk2, .lt2, .accent1, .accent2, .accent3]

    /// An OfficeArtCOLORREF ([MS-ODRAW] 2.2.2).
    func color(_ v: UInt32, depth: Int = 0) -> ColorRef? {
        let r = UInt8(v & 0xFF), g = UInt8(v >> 8 & 0xFF), bl = UInt8(v >> 16 & 0xFF), flags = UInt8(v >> 24)
        if flags == 0xFF { return nil }
        if flags & 0x10 != 0 { return system(UInt16(r) | UInt16(g) << 8, param: bl, depth: depth).map { .rgb($0) } }
        if flags & 0x08 != 0 {
            guard scheme.indices.contains(Int(r)) else { return nil }
            if linked, let slot = Self.slots[Int(r)] { return .scheme(slot) }
            return .rgb(scheme[Int(r)])
        }
        // RGB, palette RGB and system RGB alike. A palette index has no palette to look in here; its RGB bytes stand.
        return .rgb(.rgb(r, g, bl))
    }

    /// The colour as RGB.
    func rgb(_ v: UInt32, depth: Int = 0) -> Rgba? {
        guard let c = color(v, depth: depth) else { return nil }
        switch c.base {
        case .rgb(let x): return x
        case .scheme(let slot): return Self.slots.firstIndex(of: slot).flatMap { scheme.indices.contains($0) ? scheme[$0] : nil }
        default: return nil
        }
    }

    /// fSysIndex: 0x00F0–0x00F7 name another of the shape's colours, which the high byte may darken or lighten by the
    /// blue byte (0xFF leaves it as it is). Other system colours depend on the machine; they are left out.
    func system(_ index: UInt16, param: UInt8, depth: Int) -> Rgba? {
        guard depth < 2 else { return nil }
        let filled = flag(0x01BF, 4, true), lined = flag(0x01FF, 3, true)
        let fill = value(0x0181) ?? 0xFFFFFF, line = value(0x01C0) ?? 0
        let base: UInt32
        switch index & 0xFF {
        case 0xF0: base = fill
        case 0xF1: base = lined ? line : fill
        case 0xF2: base = line
        case 0xF3: base = value(0x0201) ?? 0x808080
        case 0xF5: base = value(0x0183) ?? 0xFFFFFF
        case 0xF6: base = value(0x01C2) ?? 0xFFFFFF
        case 0xF7: base = filled ? fill : line
        default: return nil
        }
        guard let c = rgb(base, depth: depth + 1) else { return nil }
        let k = Double(param) / 255
        func each(_ f: (Double) -> Double) -> Rgba {
            Rgba(r: UInt8(clamping: Int(f(Double(c.r)).rounded())), g: UInt8(clamping: Int(f(Double(c.g)).rounded())),
                 b: UInt8(clamping: Int(f(Double(c.b)).rounded())), a: c.a)
        }
        switch index >> 8 & 0x0F {
        case 1: return each { $0 * k }
        case 2: return each { 255 - (255 - $0) * k }
        default: return c
        }
    }

    /// A colour with an opacity property (16.16, 1 = opaque) applied.
    func color(_ id: UInt16, _ fallback: UInt32, opacity: UInt16) -> ColorRef? {
        guard var c = color(value(id) ?? fallback) else { return nil }
        if let o = fixed(opacity), o < 1 { c = c.with(.alpha(Int32((max(0, o) * 100_000).rounded()))) }
        return c
    }

    // MARK: Fill

    /// The fill ([MS-ODRAW] 2.3.7), or nil for a placeholder that doesn't set one.
    var fill: Fill? {
        if shape.placeholder != nil, !given(0x01BF, 0x0180, 0x0181) { return nil }
        guard flag(0x01BF, 4, true) else { return .none_ }
        let fore = color(0x0181, 0xFFFFFF, opacity: 0x0182) ?? .rgb(.rgb(255, 255, 255))
        let back = color(0x0183, 0xFFFFFF, opacity: 0x0184) ?? .rgb(.rgb(255, 255, 255))
        switch value(0x0180) ?? 0 {
        case 1:
            // A pattern: its bitmap (fillBlip) is one of the preset tiles, fillColor its dark pixels.
            let preset = value(0x0186).flatMap { pictures.patterns[$0] } ?? "pct50"
            return .pattern(PatternFill(preset: preset, fg: fore, bg: back))
        case 2, 3:
            // A texture (the picture tiled at its own size) or a picture stretched over the shape.
            guard let pib = value(0x0186), let media = pictures.media[pib] else { return .solid(color: fore) }
            var f = PictureFill(media: media)
            if value(0x0180) == 2 { f.mode = .tile(tx: 0, ty: 0, sx: 1, sy: 1, flip: "none", align: "tl") }
            if let o = fixed(0x0182), o < 1 { f.alpha = max(0, o) }
            f.upright = !flag(0x01BF, 5, true)
            return .picture(f)
        case 4, 5, 6, 7, 8: return gradient(fore, back)
        case 9: return .background
        default: return .solid(color: fore)
        }
    }

    // MARK: Picture

    /// A picture shape's picture ([MS-ODRAW] 2.3.23 Blip properties): its crop, transparent colour, brightness,
    /// contrast, and greyscale or black-and-white; nil when its picture isn't there.
    var picture: PictureFill? {
        guard let pib = value(0x0104), let media = pictures.media[pib] else { return nil }
        var f = PictureFill(media: media)
        // cropFromLeft, …Top, …Right, …Bottom: 16.16 fractions of the picture, negative to pad.
        f.crop = [0x0102, 0x0100, 0x0103, 0x0101].map { id in fixed(id).map { min(max($0, -10), 1) } ?? 0 }
        if let t = value(0x0107), t >> 24 != 0xFF, let c = rgb(t) { f.adjust.clearColor = c }
        // pictureContrast: 0x10000 leaves it; less lowers it to 0, more raises it toward 1 (as 1 - 0x10000/v).
        if let c = value(0x0108), c != 0x10000 {
            let v = Double(c)
            f.adjust.contrast = v <= 65536 ? v / 65536 - 1 : 1 - 65536 / v
        }
        // pictureBrightness: -0x8000 (black) to 0x8000 (white).
        if let v = int(0x0109), v != 0 { f.adjust.brightness = min(max(Double(v) / 32768, -1), 1) }
        // The blip booleans: fPictureBiLevel (bit 1), fPictureGray (bit 2).
        if flag(0x013F, 1, false) { f.adjust.bilevel = 0.5 } else if flag(0x013F, 2, false) { f.adjust.grayscale = true }
        return f
    }

    /// A shaded fill. The first colour (fillColor, or fillShadeColors' first) runs to the last (fillBackColor);
    /// fillFocus places the last colour along the vector: 100 at its end, 0 at its start, between them a mirrored
    /// fill, below 0 the first colour inside with the last at both ends. A linear fill's vector turns counterclockwise
    /// from bottom-to-top by fillAngle; a concentric one runs from the fillTo rectangle out to the edge.
    func gradient(_ fore: ColorRef, _ back: ColorRef) -> Fill {
        var colors: [(pos: Double, color: ColorRef)] = [(0, fore), (1, back)]
        if let a = array(0x0197), a.size == 8, a.elements.count >= 2 {
            // MSOSHADECOLOR: a colour and a 16.16 position.
            let list = a.elements.compactMap { e -> (Double, ColorRef)? in
                color(le32(b, e.lowerBound)).map { (min(1, max(0, Double(i32(b, e.lowerBound + 4)) / 65536)), $0) }
            }
            if list.count >= 2 { colors = list }
        }
        let f = min(1, max(-1, Double(int(0x018C) ?? 0) / 100))
        var stops: [(Double, ColorRef)]
        switch f {
        case 1: stops = colors
        case 0: stops = colors.map { (1 - $0.pos, $0.color) }
        case 0 ..< 1: stops = colors.map { ($0.pos * f, $0.color) } + colors.map { (1 - $0.pos * (1 - f), $0.color) }
        default: stops = colors.map { (-f * (1 - $0.pos), $0.color) } + colors.map { (-f + (1 + f) * $0.pos, $0.color) }
        }
        stops.sort { $0.0 < $1.0 }
        let type = value(0x0180) ?? 4
        let shape: GradientShape
        if type == 5 || type == 6 {
            let l = fixed(0x018D) ?? 0, t = fixed(0x018E) ?? 0, r = fixed(0x018F) ?? 0, bt = fixed(0x0190) ?? 0
            shape = .path(path: type == 5 ? "rect" : "shape", focus: [l, t, 1 - r, 1 - bt])
        } else {
            let angle = (270 - (fixed(0x018B) ?? 0)).truncatingRemainder(dividingBy: 360)
            shape = .linear(angle: angle < 0 ? angle + 360 : angle, scaled: type == 7)
        }
        return .gradient(Gradient(stops: stops.map { GradientStop(pos: $0.0, color: $0.1) }, shape: shape,
                                  rotateWithShape: flag(0x01BF, 5, true), tile: []))
    }

    // MARK: Line

    /// The line ([MS-ODRAW] 2.3.8), or nil for a placeholder that doesn't set one.
    var line: Line? {
        if shape.placeholder != nil, !given(0x01FF, 0x01C0, 0x01CB) { return nil }
        guard flag(0x01FF, 3, true) else { return Line(fill: Fill.none_) }
        var l = Line(fill: .solid(color: color(0x01C0, 0, opacity: 0x01C1) ?? .rgb(.rgb(0, 0, 0))))
        l.width = points(0x01CB) ?? 0.75
        let dashes = ["solid", "sysDash", "sysDot", "sysDashDot", "sysDashDotDot", "dot", "dash", "lgDash", "dashDot",
                      "lgDashDot", "lgDashDotDot"]
        if let d = value(0x01CE), Int(d) < dashes.count, d != 0 { l.dash = .preset(name: dashes[Int(d)]) }
        let compounds: [Compound] = [.single, .double, .thickThin, .thinThick, .triple]
        if let c = value(0x01CD), Int(c) < compounds.count, c != 0 { l.compound = compounds[Int(c)] }
        switch value(0x01D6) {
        case 0: l.join = .bevel
        case 1: l.join = .miter
        case 2: l.join = .round
        default: break
        }
        switch value(0x01D7) {
        case 0: l.cap = .round
        case 1: l.cap = .square
        case 2: l.cap = .flat
        default: break
        }
        l.head = end(0x01D0, 0x01D2, 0x01D3)
        l.tail = end(0x01D1, 0x01D4, 0x01D5)
        return l
    }

    /// An arrowhead (MSOLINEEND, MSOLINEENDWIDTH, MSOLINEENDLENGTH).
    func end(_ kind: UInt16, _ width: UInt16, _ length: UInt16) -> LineEnd? {
        let kinds = ["none", "triangle", "stealth", "diamond", "oval", "arrow"], sizes = ["sm", "med", "lg"]
        guard let k = value(kind), k != 0, Int(k) < kinds.count else { return nil }
        let w = Int(value(width) ?? 1), n = Int(value(length) ?? 1)
        return LineEnd(kind: kinds[Int(k)], w: sizes.indices.contains(w) ? sizes[w] : "med",
                       len: sizes.indices.contains(n) ? sizes[n] : "med")
    }

    // MARK: Shadow

    /// The shadow ([MS-ODRAW] 2.3.13): a hard offset shadow, as the binary format draws it.
    var effects: Effects? {
        guard flag(0x023F, 1, false) else { return nil }
        let dx = points(0x0205) ?? 2, dy = points(0x0206) ?? 2
        guard let c = color(0x0201, 0x808080, opacity: 0x0204) else { return nil }
        var dir = atan2(dy, dx) * 180 / .pi
        if dir < 0 { dir += 360 }
        let shadow = Shadow(color: c, blur: 0, dist: (dx * dx + dy * dy).squareRoot(), dir: dir, inner: false, sx: 1, sy: 1,
                            kx: 0, ky: 0, align: "b", rotateWithShape: false)
        return Effects(outerShadow: shadow)
    }

    // MARK: Text frame

    /// The text frame ([MS-ODRAW] 2.3.21): insets, anchoring, wrapping, direction and fitting, over `body`. A
    /// placeholder keeps what it doesn't set for its layout.
    func frame(_ body: BodyProps) -> BodyProps {
        var p = body
        let own = shape.placeholder == nil
        func set(_ id: UInt16) -> Bool { own || shape.props[id] != nil }
        if set(0x0081) { p.insetL = points(0x0081) ?? 7.2 }
        if set(0x0082) { p.insetT = points(0x0082) ?? 3.6 }
        if set(0x0083) { p.insetR = points(0x0083) ?? 7.2 }
        if set(0x0084) { p.insetB = points(0x0084) ?? 3.6 }
        if set(0x0085) { p.wrap = (value(0x0085) ?? 0) != 2 }
        if set(0x0087) {
            // MSOANCHOR: top, middle, bottom, then the same centred, then baseline variants.
            let a = value(0x0087) ?? 0
            p.anchor = [Anchor.top, .middle, .bottom, .top, .middle, .bottom, .top, .bottom, .top, .bottom][Int(min(a, 9))]
            p.anchorCtr = [3, 4, 5, 8, 9].contains(a)
        }
        if let f = shape.props[0x0088] {
            // MSOTXFL: horizontal, top to bottom, bottom to top, top to bottom (East Asian), horizontal, vertical.
            switch f {
            case 1, 5: p.vert = .vertical
            case 2: p.vert = .vertical270
            case 3: p.vert = .eaVertical
            default: break
            }
        }
        if own || shape.props[0x00BF] != nil, flag(0x00BF, 1, false) { p.autofit = .shape }
        return p
    }
}
