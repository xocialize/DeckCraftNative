// DCRender — Windows Metafile and Enhanced Metafile pictures (`image/x-wmf`, `image/x-emf`): parsed by
// DCMetafile and drawn as vectors into a bitmap of the size the slide needs, so they go through the same
// crop, tile and recolour path as any other picture. Port of deckcraft crates/render/src/metafile.rs (MIT
// OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors); `Images.metafile` by default.
//
// Text items name the font the file asks for; they are drawn with the face slide text would use for that
// family (`FontDB.documentFace`, so a missing font falls back the same way), symbol fonts mapped as
// bullets map them, and the file's own advances (the dx array) placing each character.
import CoreGraphics
import CoreText
import DCColor
import DCCore
import DCGeometry
import DCMetafile
import DCText
import Foundation

public enum MetafileRender {
    /// Longest side of a metafile drawn without a target size (export, thumbnails of the picture).
    public static let defaultSide = 1024
    /// Largest side drawn.
    static let maxSide = 8192
    /// Pattern cells smaller than this (output pixels) are drawn as the tile's average colour: a sub-pixel
    /// pattern would only alias.
    static let minCellPx = 1.5
    /// Size of text whose font gives no height (LOGFONT height 0), in text units.
    static let defaultEm = 12.0

    /// The hooks `Images` decodes metafile pictures through (its default).
    public static let hooks = Images.MetafileHooks(isMetafile: { Metafile.isMetafile($0) }, rasterize: { rasterize($0, $1) })

    /// Draws the metafile `bytes` into straight RGBA with its longer side `side` px (transparent where it
    /// draws nothing). nil when it doesn't parse or has no size.
    public static func rasterize(_ bytes: [UInt8], _ side: Int) -> StraightImage? {
        guard var pic = try? Metafile.parse(bytes), pic.hasSize else { return nil }
        let s = Double(Swift.min(Swift.max(side, 16), maxSide))
        let (pw, ph) = (Double(pic.width), Double(pic.height))
        let k = s / pw.rustMax(ph)
        let w = Int(rustCast: (pw * k).rounded().clamped(1, Double(maxSide)))
        let h = Int(rustCast: (ph * k).rounded().clamped(1, Double(maxSide)))
        let images: [CGImage?] = pic.items.indices.map { i in
            pic.items[i].takePixels().flatMap { premul(Int($0.width), Int($0.height), $0.rgba) }
        }
        // Pattern tiles shared by several fills are converted once.
        var tiles: [ObjectIdentifier: (CGImage?, Rgba)] = [:]
        guard let c = Canvas(width: w, height: h) else { return nil }
        let r = MetafileRect(0, 0, Double(w), Double(h))
        c.pushClipLayer(rectPath(Rect(0, 0, Double(w), Double(h))))
        for it in pic.place(r, crop: .zero) {
            switch it {
            case .path(let path, let fill, let stroke, let evenOdd, let region):
                clipped(c, region) {
                    let p = bez(path)
                    if let f = fill {
                        c.setPaint(.solid(rgba(f), 1))
                        c.setFillRule(evenOdd ? .evenOdd : .nonZero)
                        c.fillPath(p)
                    }
                    // GDI pens: round caps and joins; a cosmetic (zero-width) pen is one pixel.
                    if let (s, sw) = stroke {
                        c.setPaint(.solid(rgba(s), 1))
                        c.setStroke(StrokeStyle(sw.rustMax(1)).withCaps(.round).withJoin(.round))
                        c.strokePath(p)
                    }
                }
            case .bitmap(let index, let rect, let region):
                clipped(c, region) {
                    guard let img = images.at(index) ?? nil else { return }
                    let (bw, bh) = (Double(Swift.max(img.width, 1)), Double(Swift.max(img.height, 1)))
                    c.setPaint(.image(img, xExtend: .pad, yExtend: .pad, quality: .medium, alpha: 1))
                    c.setPaintTransform(Affine.translate(Vec2(rect.x0, rect.y0)) * Affine.scaleNonUniform(rect.width / bw, rect.height / bh))
                    c.fillRect(Rect(rect.x0, rect.y0, rect.x1, rect.y1))
                    c.resetPaintTransform()
                }
            case .pattern(let index, let path, let evenOdd, let tile, let region):
                clipped(c, region) {
                    guard case .pattern(_, _, let t, _)? = pic.items.at(index) else { return }
                    let key = ObjectIdentifier(t)
                    let (img, avg) = tiles[key] ?? {
                        let v = (premul(Int(t.width), Int(t.height), t.rgba), average(t.rgba))
                        tiles[key] = v
                        return v
                    }()
                    c.setFillRule(evenOdd ? .evenOdd : .nonZero)
                    let m = affine(tile)
                    if let img, Swift.abs(m.determinant).squareRoot() >= minCellPx {
                        c.setPaint(.image(img, xExtend: .repeat, yExtend: .repeat, quality: .low, alpha: 1))
                        c.setPaintTransform(m)
                        c.fillPath(bez(path))
                        c.resetPaintTransform()
                    } else {
                        c.setPaint(.solid(avg, 1))
                        c.fillPath(bez(path))
                    }
                }
            case .text(let index, let transform, let clip, let region):
                clipped(c, region) {
                    guard case .text(let t)? = pic.items.at(index) else { return }
                    if let clip { c.pushClipLayer(rectPath(Rect(clip.x0, clip.y0, clip.x1, clip.y1))) }
                    drawText(c, t, affine(transform))
                    if clip != nil { c.popLayer() }
                }
            }
        }
        c.setFillRule(.nonZero)
        c.popLayer()
        let img = c.finish()
        return StraightImage(width: w, height: h, pixels: img.toStraight())
    }

    /// Draws `draw` inside the device-context clip. No region is the default clip.
    static func clipped(_ c: Canvas, _ region: MetafilePath?, _ draw: () -> Void) {
        guard let region else { return draw() }
        c.setTransform(.identity)
        c.pushClipLayer(bez(region))
        draw()
        c.popLayer()
    }

    static func bez(_ p: MetafilePath) -> BezPath {
        var b = BezPath()
        for el in p.elements {
            switch el {
            case .moveTo(let q): b.moveTo(Point(q.x, q.y))
            case .lineTo(let q): b.lineTo(Point(q.x, q.y))
            case .curveTo(let a, let q, let e): b.curveTo(Point(a.x, a.y), Point(q.x, q.y), Point(e.x, e.y))
            case .closePath: b.closePath()
            }
        }
        return b
    }

    static func affine(_ m: MetafileAffine) -> Affine {
        let c = m.coeffs
        guard c.count == 6 else { return .identity }
        return Affine(c[0], c[1], c[2], c[3], c[4], c[5])
    }

    static func rgba(_ c: MetafileColor) -> Rgba { Rgba(r: c.x, g: c.y, b: c.z, a: c.w) }

    /// One glyph placed in text space (x along the baseline from the string's start).
    struct Glyph {
        var face: FontFace
        var gid: UInt32
        var x: Double
        var y: Double
    }

    /// Draws a text item; `m` maps its text space to the output.
    static func drawText(_ c: Canvas, _ t: MetafileText, _ m: Affine) {
        let db = FontDB.shared
        let font = t.font
        let trimmed = String(rustTrim(font.family))
        let family = trimmed.isEmpty ? "Arial" : trimmed
        let (bold, italic) = (font.weight >= 600, font.italic)
        let style = switch (bold, italic) {
        case (true, true): "Bold Italic"
        case (true, false): "Bold"
        case (false, true): "Italic"
        case (false, false): "Regular"
        }
        let face = db.documentFace(family, style)
        let upem = face.upem.rustMax(1)
        let (asc, desc) = winMetrics(face)
        // LOGFONT height: negative is the em, positive the cell (ascent plus descent).
        let h = Double(font.height)
        let em = h < 0 ? -h : h > 0 ? h * upem / (asc + desc).rustMax(1) : defaultEm
        let k = em / upem
        guard k.isFinite, k > 0 else { return }
        // Characters as drawn: symbol fonts (Wingdings…) map like bullets; each character takes the face
        // that has it.
        let chars: [Unicode.Scalar] = t.text.unicodeScalars.map { symbolChar(face, family, $0) ?? $0 }
        let faces: [FontFace] = chars.map { ch in
            ch.properties.isWhitespace || ch.properties.generalCategory == .control || face.covers(ch) ? face : db.cascade([ch], [face], style)
        }
        // Shape runs of one face; record each glyph's pen position and its character.
        var shaped: [(Glyph, Int)] = []
        var charPen = [Double](repeating: 0, count: chars.count + 1)
        var pen = 0.0
        var i = 0
        while i < chars.count {
            let f = faces[i]
            var j = i + 1
            while j < faces.count, faces[j].id == f.id { j += 1 }
            let s = em / f.upem.rustMax(1)
            for g in Shaper.shape(f, Array(chars[i ..< j]), rtl: false, kern: true, ligatures: true, lang: nil) {
                let ci = i + Swift.min(g.cluster, j - i - 1)
                shaped.append((Glyph(face: f, gid: g.gid, x: pen + g.xOffset * s, y: -g.yOffset * s), ci))
                pen += g.xAdvance * s
                if ci + 1 < charPen.count { charPen[ci + 1] = pen }
            }
            i = j
        }
        // Character start pens: a character's start is the previous one's end.
        for ci in charPen.indices.dropFirst() where charPen[ci] < charPen[ci - 1] { charPen[ci] = charPen[ci - 1] }
        // The file's advances place each character; glyphs keep their offset within their character.
        let useDx = !t.dx.isEmpty && t.dx.count == chars.count
        var width = pen
        var xScale = 1.0
        if useDx {
            var starts: [Double] = []
            var x = 0.0
            for d in t.dx {
                starts.append(x)
                x += Double(d)
            }
            width = x
            for n in shaped.indices {
                let ci = shaped[n].1
                shaped[n].0.x = (starts.at(ci) ?? 0) + (shaped[n].0.x - (charPen.at(ci) ?? 0))
            }
        } else if font.width > 0 {
            // A LOGFONT width narrows or widens the font against its average character width.
            let avg = avgCharWidth(face) * k
            if avg > 0 {
                xScale = (Double(font.width) / avg).clamped(0.05, 20)
                width *= xScale
                for n in shaped.indices { shaped[n].0.x *= xScale }
            }
        }
        let x0: Double = switch t.hAlign {
        case .left: 0
        case .center: -width / 2
        case .right: -width
        }
        let (a, d) = (asc * k, desc * k)
        let base: Double = switch t.vAlign {
        case .baseline: 0
        case .top: a
        case .bottom: -d
        }
        let at = m * Affine.translate(Vec2(x0, base))
        c.setTransform(.identity)
        c.setFillRule(.nonZero)
        if let bg = t.background, width > 0 {
            c.setPaint(.solid(rgba(bg), 1))
            c.fillPath(transformed(rectPath(Rect(0, -a, width, d)), at))
        }
        c.setPaint(.solid(rgba(t.color), 1))
        for (g, _) in shaped {
            let path = glyphPath(g.face, g.gid)
            if path.isEmpty { continue }
            let s = em / g.face.upem.rustMax(1)
            let skew = italic && !g.face.italic ? Affine(1, 0, -0.2, 1, 0, 0) : Affine.identity
            let gm = at * Affine.translate(Vec2(g.x, g.y)) * Affine.scaleNonUniform(xScale, 1) * skew * Affine.scale(s)
            let sc = scaleOf(gm)
            if !sc.isFinite || sc > 1e5 { continue }
            let p = transformed(path, gm)
            let bb = p.boundingBox
            if p.elements.count > 10_000 || bb.width > 1e6 || bb.height > 1e6 { continue }
            c.fillPath(p)
            if bold && g.face.weight < 600 {
                c.setStroke(StrokeStyle(em * 0.025 * scaleOf(at)).withJoin(.round))
                c.strokePath(p)
            }
        }
        // Underline and strike-out: the font's own positions and thickness.
        func deco(_ on: Bool, _ m: (position: Double, thickness: Double)?, _ fallback: (Double, Double)) -> Rect? {
            guard on, width > 0 else { return nil }
            let (off, th0) = m.map { ($0.position * k, $0.thickness * k) } ?? fallback
            let th = th0 > 0 ? th0 : em / 20
            // Offsets are y-up from the baseline; text space is y-down.
            return Rect(0, -off - th / 2, width, -off + th / 2)
        }
        let lines = [
            deco(font.underline, face.underline.thickness > 0 || face.underline.position != 0 ? face.underline : nil, (-em * 0.1, em / 20)),
            deco(font.strike, face.strikeout.thickness > 0 || face.strikeout.position != 0 ? face.strikeout : nil, (em * 0.26, em / 20)),
        ]
        for r in lines.compactMap({ $0 }) { c.fillPath(transformed(rectPath(r), at)) }
    }

    /// The OS/2 table of `face`, when it has one.
    static func os2(_ face: FontFace) -> [UInt8]? {
        guard let data = CTFontCopyTable(face.emFont, CTFontTableTag(kCTFontTableOS2), []) as Data? else { return nil }
        return [UInt8](data)
    }

    static func u16(_ t: [UInt8], _ at: Int) -> Double? {
        at + 1 < t.count ? Double(UInt16(t[at]) << 8 | UInt16(t[at + 1])) : nil
    }

    static func i16(_ t: [UInt8], _ at: Int) -> Double? {
        at + 1 < t.count ? Double(Int16(bitPattern: UInt16(t[at]) << 8 | UInt16(t[at + 1]))) : nil
    }

    /// The face's Windows ascent and descent (OS/2 `usWinAscent`/`usWinDescent`, as GDI measures the cell),
    /// in font units; the typographic ones when the font has no OS/2 table.
    static func winMetrics(_ face: FontFace) -> (Double, Double) {
        if let t = os2(face), let a = u16(t, 74), let d = u16(t, 76), a + d > 0 { return (a, d) }
        return (face.ascent.rustMax(0), face.descent.rustMax(0))
    }

    /// OS/2 `xAvgCharWidth` in font units (half an em without it).
    static func avgCharWidth(_ face: FontFace) -> Double {
        if let t = os2(face), let w = i16(t, 2), w > 0 { return w }
        return face.upem * 0.5
    }

    /// The average colour of straight RGBA pixels (alpha-weighted).
    static func average(_ px: [UInt8]) -> Rgba {
        var (r, g, b, a, n): (UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0)
        var i = 0
        while i + 3 < px.count {
            let w = UInt64(px[i + 3])
            r += UInt64(px[i]) * w
            g += UInt64(px[i + 1]) * w
            b += UInt64(px[i + 2]) * w
            a += w
            n += 1
            i += 4
        }
        if a == 0 || n == 0 { return Rgba(r: 0, g: 0, b: 0, a: 0) }
        return Rgba(r: UInt8(truncatingIfNeeded: r / a), g: UInt8(truncatingIfNeeded: g / a), b: UInt8(truncatingIfNeeded: b / a), a: UInt8(truncatingIfNeeded: a / n))
    }

    /// Straight RGBA rows to a premultiplied image.
    static func premul(_ w: Int, _ h: Int, _ px: [UInt8]) -> CGImage? {
        guard w > 0, h > 0, w <= Int(UInt16.max), h <= Int(UInt16.max), px.count >= w * h * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = UInt16(px[i + 3])
            for ch in 0 ..< 3 { out[i + ch] = UInt8((UInt16(px[i + ch]) * a + 127) / 255) }
            out[i + 3] = px[i + 3]
        }
        return RenderImage(width: w, height: h, pixels: out).cgImage()
    }
}
