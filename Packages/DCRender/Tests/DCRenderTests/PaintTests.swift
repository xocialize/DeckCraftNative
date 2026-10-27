// Ported from deckcraft crates/render/src/tests.rs and tests_wild.rs (fills, gradients, pictures,
// pattern tiles; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The Rust tests
// render a slide holding the shape; these draw the same fill straight onto a `Canvas` at the same pixel
// positions, so they check the paint code apart from the renderer core.
import CoreGraphics
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import Foundation
import ImageIO
import Testing

// MARK: Helpers shared by the paint, stroke and image tests

/// The default deck and a resolving context for its first master.
func testContext() -> (Presentation, Resolve.Ctx) {
    let p = Presentation.default
    let master = p.masters.first ?? Master()
    return (p, Resolve.Ctx.forMaster(p, master))
}

/// A canvas painted white (a slide's background), so pixels read as straight colours.
func whiteCanvas(_ w: Int, _ h: Int) -> Canvas? {
    guard let c = Canvas(width: w, height: h) else { return nil }
    c.setPaint(.solid(.white, 1))
    c.fillRect(Rect(0, 0, Double(w), Double(h)))
    return c
}

func pixel(_ img: RenderImage, _ x: Int, _ y: Int) -> [UInt8]? { img.straight(x, y) }

/// Whether pixel (`x`, `y`) is within `tol` of `c` on every colour channel.
func near(_ img: RenderImage, _ x: Int, _ y: Int, _ c: Rgba, _ tol: Int) -> Bool {
    guard let p = pixel(img, x, y) else { return false }
    return abs(Int(p[0]) - Int(c.r)) <= tol && abs(Int(p[1]) - Int(c.g)) <= tol && abs(Int(p[2]) - Int(c.b)) <= tol
}

/// An 8×4 PNG, red on the left half and blue on the right.
func halfRedHalfBlue() -> [UInt8] {
    var px = [UInt8](repeating: 255, count: 8 * 4 * 4)
    for y in 0 ..< 4 {
        for x in 0 ..< 8 {
            let i = (y * 8 + x) * 4
            (px[i], px[i + 1], px[i + 2]) = x < 4 ? (255, 0, 0) : (0, 0, 255)
        }
    }
    return withoutPHYs(png(8, 4, px))
}

/// Straight RGBA encoded as a PNG with ImageIO.
func png(_ w: Int, _ h: Int, _ straight: [UInt8], gray: Bool = false) -> [UInt8] {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return [] }
    let image: CGImage?
    if gray {
        let g = Swift.stride(from: 0, to: straight.count, by: 4).map { straight[$0] }
        image = CGDataProvider(data: Data(g) as CFData).flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
    } else {
        image = CGDataProvider(data: Data(straight) as CFData).flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
    }
    guard let image else { return [] }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return [] }
    return [UInt8](data as Data)
}

let red = Rgba.rgb(255, 0, 0)
let blue = Rgba.rgb(0, 0, 255)

@Suite struct PaintTests {
    func gradient(_ shape: GradientShape, _ stops: [(Double, Rgba)]) -> Fill {
        .gradient(Gradient(stops: stops.map { GradientStop(pos: $0.0, color: .rgb($0.1)) }, shape: shape, rotateWithShape: true, tile: [0, 0, 0, 0]))
    }

    /// A 400×200 box at (100, 100) with a white-to-black circle gradient from `focus`.
    func radial(_ focus: [Double]) -> RenderImage? {
        let (pres, rctx) = testContext()
        guard let c = whiteCanvas(600, 400) else { return nil }
        let box = Rect(0, 0, 400, 200)
        PaintFill.fillPath(c, rctx, gradient(.path(path: "circle", focus: focus), [(0, .white), (1, .black)]), nil, rectPath(box), box,
                           .translate(Vec2(100, 100)), .norm, 1, pres)
        return c.finish()
    }

    @Test func aRadialGradientOffCentreEndsOnTheCircleAroundTheBox() throws {
        // Focus a fifth of the way in from the top-left corner: the last colour is reached on the circle
        // through the box's corners, so the near corner is dark as well as the far one.
        let img = try #require(radial([0.2, 0.2, 0.8, 0.8]))
        #expect((pixel(img, 181, 141)?[0] ?? 0) > 240, "white at the focus")
        #expect((pixel(img, 101, 101)?[0] ?? 255) < 60, "near corner dark")
        #expect((pixel(img, 498, 298)?[0] ?? 255) < 60, "far corner dark")
        // Straight above the focus the box's edge is well inside the circle: still light.
        #expect((pixel(img, 181, 101)?[0] ?? 0) > 150)
        // A centred one is symmetric, dark only at the corners.
        let c = try #require(radial([0.5, 0.5, 0.5, 0.5]))
        #expect((pixel(c, 300, 200)?[0] ?? 0) > 240 && (pixel(c, 101, 101)?[0] ?? 255) < 60)
        #expect(abs(Int(pixel(c, 110, 200)?[0] ?? 0) - Int(pixel(c, 490, 200)?[0] ?? 255)) <= 2)
    }

    @Test func rectPathGradientsDrawXShapedContours() throws {
        // path="rect" from the centre, black to grey to white: the colour position is the larger axis
        // share, so 20 pt right of centre in a 280x200 box is 1/7 and 20 pt down 1/5.
        let (pres, rctx) = testContext()
        let c = try #require(whiteCanvas(300, 220))
        let box = Rect(0, 0, 280, 200)
        let fill = gradient(.path(path: "rect", focus: [0.5, 0.5, 0.5, 0.5]), [(0, .rgb(0, 0, 0)), (0.5, .rgb(128, 128, 128)), (1, .rgb(255, 255, 255))])
        PaintFill.fillPath(c, rctx, fill, nil, rectPath(box), box, .identity, .norm, 1, pres)
        let img = c.finish()
        func v(_ x: Int, _ y: Int) -> Double { Double(pixel(img, x, y)?[0] ?? 0) }
        #expect(abs(v(160, 100) - 255.0 / 7.0) < 6.0, "\(v(160, 100))")
        #expect(abs(v(140, 120) - 51.0) < 6.0, "\(v(140, 120))")
        // Along the diagonal to a corner the colour follows the vertical share.
        #expect(abs(v(168, 120) - 51.0) < 6.0, "\(v(168, 120))")
    }

    @Test func aLinearTwoColourGradientFollowsPowerPointsRamp() throws {
        // Black to white left to right over 320 px: half way is 186, not 128 (see `Ramp`). CoreGraphics
        // interpolates the 16 pieces linearly as vello does; a few levels of tolerance for its dithering.
        let (pres, rctx) = testContext()
        let c = try #require(whiteCanvas(320, 20))
        let box = Rect(0, 0, 320, 20)
        PaintFill.fillPath(c, rctx, gradient(.linear(angle: 0, scaled: false), [(0, .black), (1, .white)]), nil, rectPath(box), box, .identity, .norm, 1, pres)
        let img = c.finish()
        #expect(abs(Int(pixel(img, 160, 10)?[0] ?? 0) - 186) <= 4, "\(pixel(img, 160, 10) ?? [])")
        #expect(abs(Int(pixel(img, 80, 10)?[0] ?? 0) - 105) <= 6, "\(pixel(img, 80, 10) ?? [])")
        #expect((pixel(img, 1, 10)?[0] ?? 255) < 8 && (pixel(img, 318, 10)?[0] ?? 0) > 247)
    }

    @Test func gradientsKeepToTheSlideWhenNotRotatingWithTheShape() throws {
        // A left-to-right gradient on a shape flipped horizontally: with `rotWithShape="0"` it still
        // runs left to right on the slide.
        let (pres, rctx) = testContext()
        let c = try #require(whiteCanvas(200, 20))
        let box = Rect(0, 0, 200, 20)
        var g = Gradient(stops: [GradientStop(pos: 0, color: .rgb(.black)), GradientStop(pos: 1, color: .rgb(.white))],
                         shape: .linear(angle: 0, scaled: false), rotateWithShape: false, tile: [0, 0, 0, 0])
        let flip = Affine(-1, 0, 0, 1, 200, 0)
        PaintFill.fillPath(c, rctx, .gradient(g), nil, rectPath(box), box, flip, .norm, 1, pres)
        var img = c.finish()
        #expect((pixel(img, 2, 10)?[0] ?? 255) < 20 && (pixel(img, 197, 10)?[0] ?? 0) > 235)
        // Rotating with the shape it flips too.
        g.rotateWithShape = true
        let d = try #require(whiteCanvas(200, 20))
        PaintFill.fillPath(d, rctx, .gradient(g), nil, rectPath(box), box, flip, .norm, 1, pres)
        img = d.finish()
        #expect((pixel(img, 2, 10)?[0] ?? 0) > 235 && (pixel(img, 197, 10)?[0] ?? 255) < 20)
    }

    @Test func aTilesFirstCopySitsOnThePointItsAlignmentNames() {
        let b = Rect(0, 0, 100, 50)
        #expect(PaintFill.tileOrigin(b, "tl", (20, 10), (0, 0)) == Point(0, 0))
        #expect(PaintFill.tileOrigin(b, "ctr", (20, 10), (0, 0)) == Point(40, 20))
        #expect(PaintFill.tileOrigin(b, "br", (20, 10), (5, -5)) == Point(85, 35))
        #expect(PaintFill.tileOrigin(b, "nonsense", (20, 10), (.nan, 1)) == Point(0, 1))
    }

    @Test func tileBoxMovesTheEdgesInOrKeepsTheBox() {
        let b = Rect(0, 0, 100, 50)
        #expect(PaintFill.tileBox(b, [0, 0, 0, 0]) == b)
        #expect(PaintFill.tileBox(b, [0.1, 0.2, 0.3, 0.4]) == Rect(10, 10, 70, 30))
        #expect(PaintFill.tileBox(b, [-0.5, 0, -0.5, 0]) == Rect(-50, 0, 150, 50))
        #expect(PaintFill.tileBox(b, [0.6, 0, 0.6, 0]) == b, "inverted")
        #expect(PaintFill.tileBox(b, [.nan, 0, 0, 0]) == b)
    }

    @Test func circleGradientsKeepTheFocusInsideTheEndCircle() {
        let b = Rect(0, 0, 100, 100)
        guard case .radial(let c0, let r0, let c1, let r1, _, _) = PaintFill.circleGradient([0.5, 0.5, 0.5, 0.5], b, b, []) else {
            Issue.record("not radial")
            return
        }
        #expect(c0 == Point(50, 50) && r0 == 0 && c1 == Point(50, 50) && abs(r1 - 50 * 2.0.squareRoot()) < 1e-5)
        // A focus past the box's corner is pulled just inside the circle.
        guard case .radial(let f, _, let ce, let r, _, _) = PaintFill.circleGradient([-2, -2, 3, 3], b, b, []) else { return }
        #expect((f - ce).hypot < r)
    }

    func tiled(_ sx: Double, _ flip: String, _ align: String) -> RenderImage? {
        var (pres, rctx) = testContext()
        guard let media = pres.addMedia("t.png", "image/png", halfRedHalfBlue()), let c = whiteCanvas(400, 250) else { return nil }
        rctx.pres = pres
        let pf = PictureFill(media: media, mode: .tile(tx: 0, ty: 0, sx: sx, sy: 10, flip: flip, align: align))
        let box = Rect(0, 0, 240, 60)
        PaintFill.fillPath(c, rctx, .picture(pf), nil, rectPath(box), box, .translate(Vec2(100, 100)), .norm, 1, pres)
        return c.finish()
    }

    @Test func tiledPicturesFlipAlignAndSkipNonPositiveScales() throws {
        // 8×4 px at 96 dpi scaled ten times: 60×30 pt tiles, red then blue, from the top-left.
        let img = try #require(tiled(10, "none", "tl"))
        #expect(near(img, 115, 115, red, 30) && near(img, 145, 115, blue, 30) && near(img, 175, 115, red, 30))
        // Flipped across x: every other tile mirrored, so the second starts blue.
        let fx = try #require(tiled(10, "x", "tl"))
        #expect(near(fx, 145, 115, blue, 30) && near(fx, 175, 115, blue, 30) && near(fx, 205, 115, red, 30))
        // Aligned right: a tile ends at the box's right edge (340), so 310-340 is blue.
        let r = try #require(tiled(10, "none", "r"))
        #expect(near(r, 335, 130, blue, 30) && near(r, 305, 130, red, 30), "\(pixel(r, 305, 130) ?? [])")
        // A negative scale draws nothing, as in PowerPoint.
        let n = try #require(tiled(-10, "none", "tl"))
        #expect(near(n, 115, 115, .white, 5) && near(n, 300, 150, .white, 5))
    }

    @Test func aStretchedPictureFillsItsBoxAndAMissingOneShowsACross() throws {
        var (pres, rctx) = testContext()
        let added = pres.addMedia("t.png", "image/png", halfRedHalfBlue())
        let media = try #require(added)
        rctx.pres = pres
        let c = try #require(whiteCanvas(200, 100))
        let box = Rect(0, 0, 160, 80)
        PaintFill.fillPath(c, rctx, .picture(PictureFill(media: media)), nil, rectPath(box), box, .translate(Vec2(20, 10)), .norm, 1, pres)
        let img = c.finish()
        #expect(near(img, 40, 50, red, 12) && near(img, 160, 50, blue, 12))
        #expect(near(img, 10, 50, .white, 2) && near(img, 190, 50, .white, 2), "clipped to the box")
        // Unknown media: PowerPoint's grey placeholder with a cross.
        let d = try #require(whiteCanvas(100, 100))
        PaintFill.picture(d, pres, PictureFill(media: MediaId(9999)), Rect(0, 0, 100, 100), .identity, nil)
        let m = d.finish()
        #expect(near(m, 20, 70, .rgb(230, 230, 230), 2) && near(m, 50, 50, .rgb(160, 160, 160), 40))
    }

    @Test func resolvedTurnsADuotoneIntoPlainColours() {
        let (_, rctx) = testContext()
        var pf = PictureFill()
        #expect(PaintFill.resolved(rctx, pf, nil) == pf)
        pf.adjust.duotone = Pair(ColorRef.rgb(.rgb(1, 2, 3)), ColorRef(base: .scheme(slot: .accent1), mods: []))
        let r = PaintFill.resolved(rctx, pf, nil)
        #expect(r.adjust.duotone?.a == .rgb(.rgb(1, 2, 3)))
        if case .rgb = r.adjust.duotone?.b.base {} else { Issue.record("not resolved to RGB") }
    }

    @Test func glyphsAndIconsDrawInTheirBox() throws {
        let c = try #require(whiteCanvas(300, 100))
        PaintFill.mediaGlyph(c, true, Rect(0, 0, 100, 100))
        PaintFill.mediaGlyph(c, false, Rect(100, 0, 200, 100))
        PaintFill.placeholderIcon(c, .chart, Rect(200, 0, 300, 100))
        let img = c.finish()
        #expect(near(img, 50, 50, .rgb(30, 30, 30), 10), "video triangle")
        #expect(near(img, 150, 50, .rgb(0x2E, 0x6F, 0xD8), 10), "speaker")
        // Nothing outside the boxes' middles.
        #expect(near(img, 2, 2, .white, 0) && near(img, 102, 2, .white, 0))
    }
}
