// Ported from deckcraft crates/render/src/tests.rs (the metafile tests: WMF and EMF pictures on a slide,
// broken files, and `metafile::rasterize` with text, escapement, dx arrays, symbol fonts, opaque cells,
// pattern brushes and clipping; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The
// test files are built byte by byte as there. Pixel positions and tolerances are the Rust ones unless a
// comment says otherwise.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import Testing

private extension Array where Element == UInt8 {
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le16(_ v: Int16) { le16(UInt16(bitPattern: v)) }
    mutating func le32(_ v: UInt32) { append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
    mutating func le32(_ v: Int32) { le32(UInt32(bitPattern: v)) }
}

/// The placeable header and standard header of a WMF of `w` × `h` units at 1440 per inch, `bodyBytes`
/// long after them.
private func wmfHeader(_ w: Int16, _ h: Int16, _ bodyBytes: Int) -> [UInt8] {
    var f: [UInt8] = []
    f.le32(UInt32(0x9AC6_CDD7))
    f.le16(UInt16(0))
    for v in [Int16(0), 0, w, h] { f.le16(v) }
    f.le16(UInt16(1440))
    f.le32(UInt32(0))
    f.le16(UInt16(0))
    let total = (f.count + 18 + bodyBytes) / 2
    for v: UInt16 in [1, 9, 0x300] { f.le16(v) }
    f.le32(UInt32(total))
    f.le16(UInt16(16))
    f.le32(UInt32(0))
    f.le16(UInt16(0))
    return f
}

/// A placeable WMF, 2 × 1 inch (2880 × 1440 twips): a solid red brush and a rectangle over the left half,
/// nothing on the right (tests.rs `half_red_wmf`).
func halfRedWMF() -> [UInt8] {
    func rec(_ fn: UInt16, _ params: [Int16]) -> [UInt8] {
        var v: [UInt8] = []
        v.le32(UInt32(3 + params.count))
        v.le16(fn)
        for p in params { v.le16(p) }
        return v
    }
    // CREATEBRUSHINDIRECT (solid, COLORREF 0x000000FF = red), SELECTOBJECT 0, RECTANGLE (bottom, right,
    // top, left).
    let body = rec(0x02FC, [0, 0xFF, 0, 0]) + rec(0x012D, [0]) + rec(0x041B, [1440, 1440, 0, 0]) + rec(0, [])
    return wmfHeader(2880, 1440, body.count) + body
}

/// A placeable WMF (1440 units per inch, bounds `w` × `h`) holding `records` (function, parameter bytes)
/// (tests.rs `wmf_with`).
private func wmfWith(_ w: Int16, _ h: Int16, _ records: [(UInt16, [UInt8])]) -> [UInt8] {
    var body: [UInt8] = []
    for (fn, params) in records {
        var p = params
        if p.count % 2 == 1 { p.append(0) }
        body.le32(UInt32((6 + p.count) / 2))
        body.le16(fn)
        body += p
    }
    body += [3, 0, 0, 0, 0, 0]
    return wmfHeader(w, h, body.count) + body
}

private func i16s(_ v: [Int]) -> [UInt8] {
    var out: [UInt8] = []
    for x in v { out.le16(Int16(truncatingIfNeeded: x)) }
    return out
}

/// CREATEFONTINDIRECT (height, escapement, face) then SELECTOBJECT of it (handle 0), a transparent
/// background, and the alignment `ta` (tests.rs `font_records`).
private func fontRecords(_ height: Int, _ esc: Int, _ face: String, _ ta: Int) -> [(UInt16, [UInt8])] {
    var f = i16s([height, 0, esc, esc, 400])
    f += [0, 0, 0, face.contains("dings") ? 2 : 0, 0, 0, 0, 0]
    f += Array(face.utf8)
    f.append(0)
    return [(0x02FB, f), (0x012D, i16s([0])), (0x0102, i16s([1])), (0x012E, i16s([ta]))]
}

/// EXTTEXTOUT at (`x`, `y`) with an optional dx array (tests.rs `text_record`).
private func textRecord(_ x: Int, _ y: Int, _ s: String, _ dx: [Int] = []) -> (UInt16, [UInt8]) {
    let bytes = Array(s.utf8)
    var v = i16s([y, x, bytes.count, 0])
    v += bytes
    if bytes.count % 2 == 1 { v.append(0) }
    v += i16s(dx)
    return (0x0A32, v)
}

/// Pixel (`x`, `y`) of a straight image, transparent black outside it.
private func px(_ img: StraightImage, _ x: Int, _ y: Int) -> [UInt8] {
    guard x >= 0, y >= 0, x < img.width, y < img.height else { return [0, 0, 0, 0] }
    let i = (y * img.width + x) * 4
    return Array(img.pixels[i ..< i + 4])
}

/// Bounding box (x0, y0, x1, y1) of the pixels at least half opaque and darker than mid-grey
/// (tests.rs `mf_ink`).
private func mfInk(_ img: StraightImage) -> (Int, Int, Int, Int)? {
    var b: (Int, Int, Int, Int)?
    for y in 0 ..< img.height {
        for x in 0 ..< img.width {
            let p = px(img, x, y)
            guard p[3] > 128, Int(p[0]) + Int(p[1]) + Int(p[2]) < 384 else { continue }
            b = b.map { (Swift.min($0.0, x), Swift.min($0.1, y), Swift.max($0.2, x), Swift.max($0.3, y)) } ?? (x, y, x, y)
        }
    }
    return b
}

@Suite struct MetafileRenderTests {
    // tests.rs: metafile_pictures_draw_their_vectors
    @Test func metafilePicturesDrawTheirVectors() throws {
        let made = pictureDeck(600, Xfrm(100, 100, 400, 200), "image1.wmf", "image/x-wmf", halfRedWMF())
        let p = try #require(made)
        for scale in [0.5, 1.0, 3.0] {
            let img = renderSlide(p, 0, renderOpts(scale))
            func at(_ x: Double, _ y: Double) -> [UInt8] { pixelAt(img, Int(x * scale), Int(y * scale)) }
            let left = at(200, 200)
            #expect(left[0] > 200 && left[1] < 60 && left[2] < 60, "left half red at \(scale): \(left)")
            let right = at(400, 200)
            #expect(right[0] > 200 && right[1] > 200 && right[2] > 200, "right half empty at \(scale): \(right)")
        }
    }

    // tests.rs: broken_metafiles_draw_nothing_and_never_panic
    @Test func brokenMetafilesDrawNothingAndNeverPanic() {
        let wmf = halfRedWMF()
        var cases: [[UInt8]] = Swift.stride(from: 0, to: wmf.count, by: 3).map { Array(wmf[0 ..< $0]) }
        cases.append([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        var huge = wmf
        huge[10] = 0xFF
        huge[11] = 0x7F
        cases.append(huge)
        for bytes in cases {
            guard let p = pictureDeck(600, Xfrm(0, 0, 400, 200), "image1.emf", "image/x-emf", bytes) else { continue }
            _ = renderSlide(p, 0, renderOpts(0.25))
        }
    }

    // tests.rs: metafile_text_ink_lands_at_its_reference_point
    @Test func metafileTextInkLandsAtItsReferencePoint() throws {
        // 2 × 1 inch (144 × 72 pt) drawn 288 px wide: 2 px per point. A 36-point "HH", top-left aligned at
        // (72, 18) pt.
        let recs = fontRecords(-720, 0, "Arial", 0) + [textRecord(1440, 360, "HH")]
        let img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
        let (x0, y0, x1, y1) = try #require(mfInk(img), "text ink")
        #expect((144 ..< 156).contains(x0), "left edge at the reference point: \(x0)")
        #expect(x1 > x0 + 40 && x1 < 288, "two capitals wide: \(x1)")
        // The cell's top is at 36 px; a capital starts below the cell top and sits on the baseline.
        #expect((38 ..< 72).contains(y0), "cap top below the cell top: \(y0)")
        #expect((88 ..< 112).contains(y1), "baseline one ascent below the top: \(y1)")
    }

    // tests.rs: metafile_text_centre_baseline_and_escapement
    @Test func metafileTextCentreBaselineAndEscapement() throws {
        // TA_CENTER | TA_BASELINE at (72, 36) pt: the ink is centred on 144 px and sits on 72 px.
        var recs = fontRecords(-720, 0, "Arial", 24 | 6) + [textRecord(1440, 720, "HH")]
        var img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
        let (cx0, _, cx1, cy1) = try #require(mfInk(img), "ink")
        #expect(abs((cx0 + cx1) / 2 - 144) <= 4, "centred: \(cx0)..\(cx1)")
        #expect((69 ... 74).contains(cy1), "on the baseline: \(cy1)")
        // Escapement 90°: the string runs up the picture.
        recs = fontRecords(-360, 900, "Arial", 24) + [textRecord(1440, 1300, "HHHH")]
        img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
        let (x0, y0, x1, y1) = try #require(mfInk(img), "ink")
        #expect(y1 - y0 > 2 * (x1 - x0), "a vertical run: \(x0) \(y0) \(x1) \(y1)")
        #expect(x1 <= 146 && y1 <= 132, "drawn up and left of the baseline origin (144, 130): \(x1) \(y1)")
    }

    // tests.rs: metafile_text_follows_its_dx_array
    @Test func metafileTextFollowsItsDxArray() throws {
        // "HH" with the second H a full inch (144 px) after the first: two clumps of ink, a gap between.
        let recs = fontRecords(-360, 0, "Arial", 24) + [textRecord(360, 720, "HH", [1440, 100])]
        let img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
        func colHasInk(_ x: Int) -> Bool { (0 ..< img.height).contains { px(img, x, $0)[3] > 128 } }
        #expect((36 ..< 56).contains(where: colHasInk), "first H at 36 px")
        #expect((180 ..< 200).contains(where: colHasInk), "second H one inch later")
        #expect(!(70 ..< 170).contains(where: colHasInk), "nothing between them")
    }

    // tests.rs: metafile_symbol_text_draws_a_bullet_not_a_box
    @Test func metafileSymbolTextDrawsABulletNotABox() throws {
        // Webdings "n" is a filled circle (installed, or mapped to a black circle where it is not), as is
        // Wingdings "l" in a symbol font that is not installed anywhere.
        for (face, s) in [("Webdings", "n"), ("Wingdings Not Installed", "l")] {
            let recs = fontRecords(-1080, 0, face, 0) + [textRecord(360, 0, s)]
            let img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
            let (x0, y0, x1, y1) = try #require(mfInk(img), "\(face): ink")
            #expect(x1 - x0 > 10 && y1 - y0 > 10, "\(face): a sizeable mark: \(x0) \(y0) \(x1) \(y1)")
            #expect(px(img, (x0 + x1) / 2, (y0 + y1) / 2)[3] > 200, "\(face): filled in the middle")
            for (x, y) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] {
                #expect(px(img, x, y)[3] < 128, "\(face): round, not a box: corner (\(x), \(y))")
            }
        }
    }

    // tests.rs: metafile_opaque_text_fills_its_cell
    @Test func metafileOpaqueTextFillsItsCell() throws {
        // OPAQUE background in red behind a space.
        var recs = fontRecords(-720, 0, "Arial", 0)
        recs.append((0x0102, i16s([2])))
        var bk: [UInt8] = []
        bk.le32(UInt32(0x0000_00FF))
        recs.append((0x0201, bk))
        recs.append(textRecord(1440, 360, " "))
        let img = try #require(MetafileRender.rasterize(wmfWith(2880, 1440, recs), 288))
        let p = px(img, 148, 60)
        #expect(p[0] > 200 && p[1] < 60 && p[3] > 200, "cell filled red: \(p)")
        #expect(px(img, 140, 60)[3] < 50, "nothing left of the cell")
    }

    // tests.rs: metafile_pattern_brush_tiles_and_averages_when_tiny
    @Test func metafilePatternBrushTilesAndAveragesWhenTiny() throws {
        // A 1-bit 8 × 8 checker (palette white, black), a null pen and a one-inch square.
        var dib: [UInt8] = []
        for v: UInt32 in [40, 8, 8] { dib.le32(v) }
        dib.le16(UInt16(1))
        dib.le16(UInt16(1))
        dib += [UInt8](repeating: 0, count: 24)
        dib += [255, 255, 255, 0, 0, 0, 0, 0]
        for r in 0 ..< 8 { dib += [r % 2 == 0 ? 0x55 : 0xAA, 0, 0, 0] }
        let brush = i16s([5, 0]) + dib
        let recs: [(UInt16, [UInt8])] = [(0x0142, brush), (0x012D, i16s([0])), (0x012D, i16s([0x8008])), (0x041B, i16s([1440, 1440, 0, 0]))]
        let bytes = wmfWith(1440, 1440, recs)
        // 4 px per point: a 0.75 pt cell is 3 px.
        var img = try #require(MetafileRender.rasterize(bytes, 288))
        let (a, b) = (px(img, 1, 1), px(img, 4, 1))
        #expect(a[3] > 200 && b[3] > 200)
        #expect(abs(Int(a[0]) - Int(b[0])) > 200, "neighbouring cells alternate: \(a) \(b)")
        // Far below one pixel per cell: the average grey.
        img = try #require(MetafileRender.rasterize(bytes, 32))
        let p = px(img, 16, 16)
        #expect((100 ..< 156).contains(p[0]) && p[3] > 200, "average grey: \(p)")
    }

    // tests.rs: metafile_intersect_clip_rect_hides_the_rest_of_the_picture
    @Test func metafileIntersectClipRectHidesTheRestOfThePicture() throws {
        func rec(_ type: UInt32, _ payload: [UInt8]) -> [UInt8] {
            var v: [UInt8] = []
            v.le32(type)
            v.le32(UInt32(8 + payload.count))
            return v + payload
        }
        func rect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] {
            var v: [UInt8] = []
            for x in [l, t, r, b] { v.le32(x) }
            return v
        }
        // EMR_INTERSECTCLIPRECT over the left half, then EMR_RECTANGLE over the whole picture.
        let body = rec(30, rect(0, 0, 50, 50)) + rec(43, rect(0, 0, 100, 50))
        let eof = rec(14, [UInt8](repeating: 0, count: 12))
        let total = 88 + body.count + eof.count
        var file = [UInt8](repeating: 0, count: 88)
        func put(_ at: Int, _ bytes: [UInt8]) { file.replaceSubrange(at ..< at + bytes.count, with: bytes) }
        var u: [UInt8] = []
        u.le32(UInt32(1))
        put(0, u)
        u = []
        u.le32(UInt32(88))
        put(4, u)
        put(8, rect(0, 0, 100, 50))
        u = []
        u.le32(UInt32(0x464D_4520))
        put(40, u)
        u = []
        u.le32(UInt32(0x0001_0000))
        put(44, u)
        u = []
        u.le32(UInt32(total))
        put(48, u)
        u = []
        u.le32(UInt32(2))
        put(52, u)
        u = []
        u.le16(UInt16(1))
        put(56, u)
        file += body + eof
        let img = try #require(MetafileRender.rasterize(file, 100))
        func opaque(_ x: Int, _ y: Int) -> Bool { px(img, x, y)[3] > 200 }
        #expect(opaque(20, 25), "the clipped half is drawn")
        #expect(!opaque(80, 25), "past the clip the picture stays clear, pixel \(px(img, 80, 25))")
    }
}
