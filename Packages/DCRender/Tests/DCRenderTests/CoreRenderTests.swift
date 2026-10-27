// Ported from deckcraft crates/render/src/tests.rs (the core slide rendering tests: backgrounds, fills,
// shadows and glows, soft edges, groups, pictures, placeholders, render options, extent, `render_shapes`,
// `place_slide`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Pixel positions and
// tolerances are the Rust ones unless a comment says otherwise.
import CoreGraphics
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import DCText
import Foundation
import ImageIO
import Testing

// MARK: Helpers shared by the core, text, metafile and wild render tests

/// Render options at `scale` pixels per point, adjusted by `set`.
func renderOpts(_ scale: Double = 1, _ set: (inout RenderOpts) -> Void = { _ in }) -> RenderOpts {
    var o = RenderOpts(scale: scale)
    set(&o)
    return o
}

/// A line with no fill (deckcraft's `Line { fill: Some(Fill::None), .. }`).
func noLine() -> Line { Line(fill: .none_) }

/// A shape `id` in frame `x`, adjusted by `set`.
func shapeWith(_ id: UInt32, _ x: Xfrm, _ set: (inout Shape) -> Void = { _ in }) -> Shape {
    var s = shapeOf(id, x)
    set(&s)
    return s
}

/// A 600×120 text box at (`x`, `y`) holding `text` at 40 pt (tests.rs `text_shape`).
func textShape(_ id: UInt32, _ text: String, _ x: Double, _ y: Double) -> Shape {
    var t = TextBody.fromText(text)
    for p in t.paragraphs.indices {
        for r in t.paragraphs[p].runs.indices { t.paragraphs[p].runs[r].props.size = 40 }
    }
    return shapeWith(id, Xfrm(x, y, 600, 120)) {
        $0.textBox = true
        $0.text = t
    }
}

/// The number of pixels of `img` that pass `f` (straight RGBA).
func countPixels(_ img: RenderImage, _ f: ([UInt8]) -> Bool) -> Int { straightPixels(img).filter(f).count }

/// Ink box (x0, y0, x1, y1) of the pixels whose red is under 128, and the top ink row of each column
/// (tests.rs `ink`).
func inkBox(_ img: RenderImage) -> ((Int, Int, Int, Int), [Int?]) {
    var b = (Int.max, Int.max, 0, 0)
    var tops = [Int?](repeating: nil, count: img.width)
    let s = img.toStraight()
    for y in 0 ..< img.height {
        for x in 0 ..< img.width where s[(y * img.width + x) * 4] < 128 {
            b = (Swift.min(b.0, x), Swift.min(b.1, y), Swift.max(b.2, x), Swift.max(b.3, y))
            if tops[x] == nil { tops[x] = y }
        }
    }
    return (b, tops)
}

/// A `w` × `h` PNG whose pixel (x, y) is `f(x, y)` (straight RGBA), with no resolution chunk.
func pngOf(_ w: Int, _ h: Int, _ f: (Int, Int) -> [UInt8]) -> [UInt8] {
    var px: [UInt8] = []
    px.reserveCapacity(w * h * 4)
    for y in 0 ..< h {
        for x in 0 ..< w { px += f(x, y) }
    }
    return withoutPHYs(png(w, h, px))
}

/// A `w` × `h` PNG of one opaque colour.
func solidPNG(_ w: Int, _ h: Int, _ rgb: [UInt8]) -> [UInt8] { pngOf(w, h) { _, _ in rgb + [255] } }

/// The default deck with a picture shape `id` of `bytes` (named `name`, of type `type`) in frame `x`.
func pictureDeck(_ id: UInt32, _ x: Xfrm, _ name: String, _ type: String, _ bytes: [UInt8], _ set: (inout Shape) -> Void = { _ in }) -> Presentation? {
    var p = Presentation.default
    guard let media = p.addMedia(name, type, bytes) else { return nil }
    var s = shapeOf(id, x, .picture(fill: PictureFill(media: media)))
    set(&s)
    p.slides[0].shapes = [s]
    return p
}

/// The accent colour `slot` of the default deck's first master.
func accent(_ p: Presentation, _ slot: SchemeSlot) -> Rgba { p.masters[0].theme.colors.get(slot) }

/// A shadow of black, with no transform (tests.rs `shadow`).
func plainShadow(_ blur: Double, _ dist: Double, _ dir: Double, inner: Bool = false) -> Shadow {
    Shadow(color: .rgb(.black), blur: blur, dist: dist, dir: dir, inner: inner, sx: 1, sy: 1, kx: 0, ky: 0, align: "", rotateWithShape: false)
}

/// deckcraft's `pasteboard_region` (it comes with the app here, Wave 5): the pixels the editor renders,
/// the slide plus the part of `extent` in view, rounded out to 256-pixel tiles.
struct PasteboardRegion: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var offset: (Double, Double) { (-Double(x), -Double(y)) }
    var size: (Int, Int) { (w, h) }

    static func of(_ slidePx: (Int, Int), _ scale: Double, _ extent: Rect, _ visible: PasteboardRegion) -> PasteboardRegion {
        let page = PasteboardRegion(x: 0, y: 0, w: Swift.max(slidePx.0, 1), h: Swift.max(slidePx.1, 1))
        guard scale.isFinite, scale > 0, extent.isFinite else { return page }
        let (ex0, ey0) = (Int((extent.x0 * scale).rounded(.down)), Int((extent.y0 * scale).rounded(.down)))
        let (ex1, ey1) = (Int((extent.x1 * scale).rounded(.up)), Int((extent.y1 * scale).rounded(.up)))
        let tile = 256
        func floorTile(_ v: Int) -> Int { Int((Double(v) / Double(tile)).rounded(.down)) * tile }
        let (vx0, vy0) = (floorTile(visible.x), floorTile(visible.y))
        let (vx1, vy1) = (floorTile(visible.x + visible.w + tile - 1), floorTile(visible.y + visible.h + tile - 1))
        let (cx0, cy0, cx1, cy1) = (Swift.max(ex0, vx0), Swift.max(ey0, vy0), Swift.min(ex1, vx1), Swift.min(ey1, vy1))
        if cx0 >= cx1 || cy0 >= cy1 { return page }
        let (x0, y0) = (Swift.min(cx0, 0), Swift.min(cy0, 0))
        let (x1, y1) = (Swift.max(cx1, page.w), Swift.max(cy1, page.h))
        func side(_ d: Int) -> Int { Swift.min(Swift.max(d, 1), maxRenderSide) }
        return PasteboardRegion(x: x0, y: y0, w: side(x1 - x0), h: side(y1 - y0))
    }
}

@Suite struct CoreRenderTests {
    // tests.rs: blank_slide_renders_white_background
    @Test func blankSlideRendersWhiteBackground() {
        let img = renderSlide(Presentation.default, 0, renderOpts(0.25))
        #expect(img.width == 240 && img.height == 135)
        #expect(pixelAt(img, 5, 5) == [255, 255, 255, 255])
    }

    // tests.rs: shape_fill_uses_theme_accent
    @Test func shapeFillUsesThemeAccent() {
        let p = deckOf([shapeWith(500, Xfrm(100, 100, 200, 100)) { $0.style = .accent(.accent1) }])
        let img = renderDeck(p)
        let a = accent(p, .accent1)
        let px = pixelAt(img, 200, 150)
        #expect(abs(Int(px[0]) - Int(a.r)) <= 2 && abs(Int(px[2]) - Int(a.b)) <= 2, "\(px) vs \(a)")
        #expect(pixelAt(img, 50, 50) == [255, 255, 255, 255])
    }

    // tests.rs: a_quick_style_fills_an_empty_placeholder
    @Test func aQuickStyleFillsAnEmptyPlaceholder() {
        // #832: a quick style on an empty placeholder paints its fill; a placeholder with no style at all
        // still shows nothing but its dashed outline.
        func placeholder() -> Shape { shapeWith(910, Xfrm(100, 100, 200, 100)) { $0.ph = Placeholder(kind: .body, idx: 1) } }
        var styled = placeholder()
        styled.style = .accent(.accent1)
        let p = deckOf([styled])
        let img = renderSlide(p, 0, renderOpts(1) { $0.edit = true })
        let a = accent(p, .accent1)
        // Lower right of the shape: the prompt text sits at the top of the text rect.
        let px = pixelAt(img, 280, 185)
        #expect(nearRGB(px, a, 2), "the quick style's fill is drawn on the empty placeholder: \(px) vs \(a)")
        // An unformatted empty placeholder stays empty: the gate is not simply gone.
        let plain = renderSlide(deckOf([placeholder()]), 0, renderOpts(1) { $0.edit = true })
        #expect(pixelAt(plain, 280, 185) == [255, 255, 255, 255], "an unformatted placeholder has no fill")
    }

    // tests.rs: render_shapes_draws_the_selection_on_a_transparent_canvas
    @Test func renderShapesDrawsTheSelectionOnATransparentCanvas() throws {
        let p = deckOf([shapeWith(880, Xfrm(100, 80, 60, 40)) {
            $0.fill = .solid(.rgb(.rgb(255, 0, 0)))
            $0.line = .none()
        }])
        let img = try #require(renderShapes(p, p.slides[0], [ShapeId(880)], 1))
        let mid = pixelAt(img, img.width / 2, img.height / 2)
        #expect(mid[0] > 200 && mid[1] < 40 && mid[3] > 200, "\(mid)")
        #expect(pixelAt(img, 0, 0)[3] == 0, "\(pixelAt(img, 0, 0))")
        // `renderShape` draws the one shape the same way.
        let one = try #require(renderShape(p, p.slides[0], ShapeId(880), 1))
        #expect(pixelAt(one, one.width / 2, one.height / 2)[0] > 200 && pixelAt(one, 0, 0)[3] == 0)
    }

    /// A slide-sized ink shape: one 24 pt stroke across, pressure `left` on its first half and `right`
    /// on its second (tests.rs `ink_line`).
    func inkLine(_ left: Float, _ right: Float) -> Presentation {
        let points = (0 ... 40).map { i in Triple(40.0 + Double(i) * 8.0, 100.0, i < 20 ? left : right) }
        let stroke = InkStroke(points: points, color: .rgb(0, 0, 0), width: 24, highlighter: false)
        return deckOf([shapeOf(7, Xfrm(0, 0, 960, 540), .ink(strokes: [stroke]))])
    }

    /// Pixels in columns `x0..<x1`, rows `y0..<y1` whose red is under 200 (tests.rs `dark_in`).
    func darkIn(_ img: RenderImage, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Int {
        var n = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 where pixelAt(img, x, y)[0] < 200 { n += 1 }
        }
        return n
    }

    // tests.rs: ink_pressure_tapers_the_stroke_and_a_flat_half_stays_full_width
    @Test func inkPressureTapersTheStrokeAndAFlatHalfStaysFullWidth() {
        let tapered = renderDeck(inkLine(1.0, 0.12))
        let flat = renderDeck(inkLine(0.5, 0.5))
        let full = renderDeck(inkLine(1.0, 1.0))
        let heavy = darkIn(tapered, 50, 140, 70, 130)
        let light = darkIn(tapered, 280, 360, 70, 130)
        #expect(heavy > light * 3, "a firm point covers more of the slide than a light one (\(heavy) vs \(light))")
        let (a, b) = (darkIn(flat, 40, 370, 70, 130), darkIn(full, 40, 370, 70, 130))
        #expect(a > 100 && abs(a - b) * 10 < a, "the old constant 0.5 still draws at the pen width (\(a) vs \(b))")
    }

    // tests.rs: every_preset_renders_without_panic
    @Test func everyPresetRendersWithoutPanic() {
        let shapes = Preset.catalog.enumerated().map { i, pr in
            shapeWith(1000 + UInt32(i), Xfrm(Double(i % 16) * 60, Double(i / 16) * 55, 50, 45)) {
                $0.geom = .preset(pr.name)
                $0.style = .accent(.accent2)
            }
        }
        let img = renderSlide(deckOf(shapes), 0, renderOpts(1) { $0.edit = true })
        #expect(img.width == 960)
    }

    // tests.rs: glow_of_an_unfilled_shape_follows_its_line
    @Test func glowOfAnUnfilledShapeFollowsItsLine() {
        // A frame (no fill, thin line) with a strong glow: the glow lines its edge, the inside stays the
        // slide's white, as PowerPoint draws it.
        func glow(_ fill: Fill?) -> RenderImage {
            renderDeck(deckOf([shapeWith(610, Xfrm(100, 100, 400, 300)) {
                $0.fill = fill
                $0.line = .solid(.rgb(.rgb(0, 176, 240)), 0.25)
                $0.effects = Effects(glow: Glow(color: .rgb(.rgb(0, 0, 255)), radius: 8))
            }]))
        }
        var img = glow(.none_)
        let inside = pixelAt(img, 300, 250)
        #expect(inside[0] > 245 && inside[1] > 245, "\(inside)")
        let edge = pixelAt(img, 300, 97)
        #expect(edge[0] < 230, "\(edge)")
        // A filled shape's glow is still the whole silhouette's (the fill covers its inside).
        img = glow(.solid(.rgb(.rgb(255, 255, 255))))
        #expect(pixelAt(img, 300, 94)[0] < 240)
    }

    // tests.rs: glow_of_a_shape_with_no_fill_and_no_line_is_not_drawn
    @Test func glowOfAShapeWithNoFillAndNoLineIsNotDrawn() {
        // A text box (no fill, no line) with a glow in its shape properties: PowerPoint shows no halo round
        // the box, so the box's edge and surroundings stay white.
        let img = renderDeck(deckOf([shapeWith(611, Xfrm(100, 100, 400, 300)) {
            $0.fill = .none_
            $0.effects = Effects(glow: Glow(color: .rgb(.rgb(255, 255, 0)), radius: 15))
        }]))
        for (x, y) in [(300, 250), (300, 100), (300, 95), (96, 250)] {
            let px = pixelAt(img, x, y)
            #expect(px[2] > 245, "(\(x), \(y)): \(px)")
        }
    }

    // tests.rs: placeholder_prompts_only_in_edit_view
    @Test func placeholderPromptsOnlyInEditView() {
        let p = Presentation.default
        let edit = renderSlide(p, 0, renderOpts(0.5) { $0.edit = true })
        let show = renderSlide(p, 0, renderOpts(0.5))
        #expect(countPixels(edit) { $0[0] < 200 } > 100)
        #expect(countPixels(show) { $0[0] < 200 } == 0)
    }

    // tests.rs: crop_dest_math
    @Test func cropDestMath() {
        var r = cropDest(Rect(0, 0, 100, 100), [0.5, 0, 0, 0])
        #expect(abs(r.x0 + 100) < 1e-9 && abs(r.width - 200) < 1e-9, "\(r)")
        r = cropDest(Rect(0, 0, 100, 100), [.nan, 2, -50, 0])
        #expect(r.x0.isFinite && r.y1.isFinite)
    }

    // tests.rs: custom_path_parse
    @Test func customPathParse() {
        let p = parsePath("M 0 0 L 10 0 C 1 2 3 4 5 6 Q 1 1 2 2 Z garbage L x y")
        #expect(p.elements.count >= 5)
        #expect(parsePath("").elements.isEmpty)
    }

    /// Two 8×8 frames, red then blue, 100 ms each (tests.rs `two_frame_gif`).
    func twoFrameGif() -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil) else { return [] }
        for c: [UInt8] in [[255, 0, 0, 255], [0, 0, 255, 255]] {
            guard let img = RenderImage(width: 8, height: 8, pixels: Array([[UInt8]](repeating: c, count: 64).joined())).cgImage() else { continue }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1, kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(dest, img, props)
        }
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](data as Data)
    }

    // tests.rs: animated_gif_shows_the_frame_for_its_time
    @Test func animatedGifShowsTheFrameForItsTime() throws {
        let made = pictureDeck(600, Xfrm(0, 0, 960, 540), "a.gif", "image/gif", twoFrameGif())
        let p = try #require(made)
        func at(_ t: Double?) -> [UInt8] {
            pixelAt(renderSlide(p, 0, renderOpts(0.1) { o in o.gifTimes = t.map { [(ShapeId(600), $0)] } ?? [] }), 48, 27)
        }
        func isRed(_ px: [UInt8]) -> Bool { px[0] > 200 && px[2] < 60 }
        func isBlue(_ px: [UInt8]) -> Bool { px[2] > 200 && px[0] < 60 }
        #expect(isRed(at(nil)), "no time: the first frame, as exports draw it")
        #expect(isRed(at(0.05)))
        #expect(isBlue(at(0.15)))
        #expect(isRed(at(0.25)), "it loops")
        let bytes = try #require(p.media.first?.data)
        #expect(Images.gifFrame(bytes, PictureAdjust(), 0.15)?.0 == 1)
        #expect(Images.gifFrame(bytes, PictureAdjust(), .nan)?.0 == 0)
        #expect(Images.gifFrame(Array("\u{89}PNG".utf8), PictureAdjust(), 0) == nil)
    }

    // tests.rs: text_transform_unmirrors_flips
    @Test func textTransformUnmirrorsFlips() {
        // Asymmetric text rect in a 100×50 box: flips move the rect, never mirror the text.
        let tr = Rect(10, 0, 40, 50)
        func at(_ x: Xfrm, _ p: Point) -> Point { textTransform(x.affine, tr, 0) * p }
        func close(_ a: Point, _ b: Point) -> Bool { (a - b).hypot < 1e-9 }
        let base = Xfrm(0, 0, 100, 50)
        // flipH: the rect moves to 60..90 and the text still runs left to right.
        var h = base
        h.flipH = true
        #expect(close(at(h, Point(10, 0)), Point(60, 0)))
        #expect(close(at(h, Point(40, 50)), Point(90, 50)))
        // flipV: the text is turned 180° in its (vertically mirrored) rect.
        var v = base
        v.flipV = true
        #expect(close(at(v, Point(10, 0)), Point(40, 50)))
        #expect(close(at(v, Point(40, 50)), Point(10, 0)))
        // Both flips: the same as a 180° turn.
        var hv = base
        (hv.flipH, hv.flipV) = (true, true)
        var turned = base
        turned.rot = 180
        for p in [Point(10, 0), Point(40, 50), Point(25, 10)] {
            #expect(close(at(hv, p), at(turned, p)))
        }
        // Unflipped and hostile input: plain transform, nothing NaN from the helper itself.
        #expect(textTransform(base.affine, tr, 0) == base.affine)
        _ = textTransform(h.affine, Rect(.nan, 0, .infinity, 1), .nan)
    }

    /// A 800×100 shape at the slide's corner with a left-to-right gradient of `stops`, no line.
    func gradientBox(_ id: UInt32, _ stops: [(Double, Rgba)]) -> Shape {
        shapeWith(id, Xfrm(0, 0, 800, 100)) {
            $0.fill = .gradient(Gradient(stops: stops.map { GradientStop(pos: $0.0, color: .rgb($0.1)) }, shape: .linear(angle: 0, scaled: false),
                                         rotateWithShape: true, tile: [0, 0, 0, 0]))
            $0.line = noLine()
        }
    }

    // tests.rs: a_gradient_with_a_stop_off_the_end_stays_linear
    @Test func aGradientWithAStopOffTheEndStaysLinear() {
        // Stops at 20 % and 100 %: PowerPoint blends linearly in sRGB (96 at 50 %, 175 at 75 %).
        let img = renderDeck(deckOf([gradientBox(701, [(0.2, .rgb(0, 0, 0)), (1, .rgb(255, 255, 255))])]))
        for (x, want) in [(400, 96), (600, 175)] {
            let got = Int(pixelAt(img, x, 50)[0])
            #expect(abs(got - want) <= 4, "x \(x): \(got) vs \(want)")
        }
    }

    // tests.rs: a_shape_filled_with_the_background_shows_the_slide_background
    @Test func aShapeFilledWithTheBackgroundShowsTheSlideBackground() {
        // `useBgFill`: PowerPoint paints the slide's background into the shape, laid out on the slide. A
        // white panel covers a black-to-grey background; a shape on it with the background fill is a
        // window onto that background.
        let panel = shapeWith(710, Xfrm(0, 0, 960, 540)) {
            $0.fill = .solid(.rgb(.rgb(255, 255, 255)))
            $0.line = noLine()
        }
        let window = shapeWith(711, Xfrm(100, 100, 760, 340)) {
            $0.fill = .background
            $0.line = noLine()
        }
        var p = deckOf([panel, window])
        let stops = [(0.0, UInt8(0)), (0.5, 0), (1, 200)].map { GradientStop(pos: $0.0, color: .rgb(.rgb($0.1, $0.1, $0.1))) }
        p.slides[0].background = .fill(fill: .gradient(Gradient(stops: stops, shape: .linear(angle: 0, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0])))
        let img = renderDeck(p)
        #expect(pixelAt(img, 50, 50)[0] == 255, "the panel stays white outside the window")
        #expect(pixelAt(img, 300, 270)[0] < 8, "the window shows the background's black half: \(pixelAt(img, 300, 270))")
        // Laid out on the slide: three quarters across the slide is half way from black to grey.
        let v = Int(pixelAt(img, 720, 270)[0])
        #expect(abs(v - 100) <= 6, "\(v)")
    }

    // tests.rs: a_background_is_laid_over_white
    @Test func aBackgroundIsLaidOverWhite() throws {
        // A background picture stretched into the bottom-right quarter (fillRect l=50% t=50%), and a
        // half-transparent colour: PowerPoint shows white around and under them, not transparency.
        var p = deckOf([])
        let added = p.addMedia("bg.png", "image/png", solidPNG(4, 4, [0, 0, 200]))
        let media = try #require(added)
        p.slides[0].background = .fill(fill: .picture(PictureFill(media: media, mode: .stretch(fillRect: [0.5, 0.5, 0, 0]))))
        var img = renderSlide(p, 0, renderOpts(0.5))
        #expect(pixelAt(img, 20, 20) == [255, 255, 255, 255], "white where the picture doesn't reach")
        let q = pixelAt(img, 400, 230)
        #expect(q[2] > 190 && q[0] < 10 && q[3] == 255, "\(q)")
        p.slides[0].background = .fill(fill: .solid(.rgb(.rgba(0, 0, 0, 128))))
        img = renderSlide(p, 0, renderOpts(0.5))
        let g = pixelAt(img, 20, 20)
        #expect(g[3] == 255 && abs(Int(g[0]) - 127) <= 3, "half-transparent black over white is grey: \(g)")
    }

    // tests.rs: a_transparent_background_leaves_the_slide_background_out
    @Test func aTransparentBackgroundLeavesTheSlideBackgroundOut() {
        // #784: PNG export with a transparent background draws only what is on the slide; a shape filled
        // with the background (`useBgFill`) still draws.
        let redBox = shapeWith(784, Xfrm(100, 100, 200, 100)) { $0.fill = .solid(.rgb(.rgb(220, 0, 0))) }
        let bgFilled = shapeWith(785, Xfrm(500, 100, 200, 100)) { $0.fill = .background }
        var p = deckOf([redBox, bgFilled])
        p.slides[0].background = .fill(fill: .solid(.rgb(.rgb(0, 0, 200))))
        let opaque = renderDeck(p)
        #expect(pixelAt(opaque, 20, 20) == [0, 0, 200, 255], "without the option the background draws")
        let img = renderSlide(p, 0, renderOpts(1) { $0.transparentBackground = true })
        #expect(pixelAt(img, 20, 20) == [0, 0, 0, 0], "no background, no white underlay")
        #expect(pixelAt(img, 200, 150) == [220, 0, 0, 255], "the slide's shapes still draw")
        #expect(pixelAt(img, 600, 150) == [0, 0, 200, 255], "a background-filled shape still shows the background")
        // The default theme background (a style reference) is left out too.
        let blank = renderSlide(deckOf([]), 0, renderOpts(0.25) { $0.transparentBackground = true })
        #expect(straightPixels(blank).allSatisfy { $0[3] == 0 }, "a blank slide is fully transparent")
    }

    // tests.rs: soft_edges_fade_to_the_outline
    @Test func softEdgesFadeToTheOutline() {
        // An ellipse with a 12 pt soft edge: transparent at its outline, half opaque about 10 pt inside,
        // opaque further in, as in PowerPoint's export (the fade follows the curve, not the bounding box).
        let img = renderDeck(deckOf([shapeWith(780, Xfrm(100, 100, 300, 200)) {
            $0.geom = .preset("ellipse")
            $0.fill = .solid(.rgb(.rgb(0, 0, 0)))
            $0.line = noLine()
            $0.effects = Effects(softEdge: 12)
        }]))
        func alpha(_ x: Int, _ y: Int) -> Double { 1 - Double(pixelAt(img, x, y)[0]) / 255 }
        // Top of the ellipse is at y = 100, x = 250.
        #expect(alpha(250, 101) < 0.08, "edge \(alpha(250, 101))")
        let mid = alpha(250, 110)
        #expect((0.3 ..< 0.7).contains(mid), "0.85 r inside: \(mid)")
        #expect(alpha(250, 130) > 0.97, "inside \(alpha(250, 130))")
        // Near the ends of the bounding box's top edge, outside the ellipse, nothing is drawn.
        #expect(alpha(110, 105) < 0.01)
    }

    /// A white 280×200 pt rectangle at (20, 20) with `effects`, rendered at 1 px/pt (tests.rs `effect_box`).
    func effectBox(_ effects: Effects) -> RenderImage {
        renderDeck(deckOf([shapeWith(800, Xfrm(20, 20, 280, 200)) {
            $0.fill = .solid(.rgb(.rgb(255, 255, 255)))
            $0.line = noLine()
            $0.effects = effects
        }]))
    }

    // tests.rs: shadows_and_glows_spread_like_powerpoints
    @Test func shadowsAndGlowsSpreadLikePowerpoints() {
        func r(_ img: RenderImage, _ x: Int, _ y: Int) -> Int { Int(pixelAt(img, x, y)[0]) }
        // Outer shadow, 9 pt blur, no offset: PowerPoint's export reads 144, 204, 238 at 1, 3 and 5 px
        // outside the left edge.
        var img = effectBox(Effects(outerShadow: plainShadow(9, 0, 0)))
        for (d, want) in [(1, 144), (3, 204), (5, 238)] {
            #expect(abs(r(img, 20 - d, 120) - want) <= 6, "outer \(d): \(r(img, 20 - d, 120))")
        }
        // Inner shadow pointing down-right (45 degrees): it falls inside along the bottom and right edges,
        // not the top and left.
        img = effectBox(Effects(innerShadow: plainShadow(0, 10, 45, inner: true)))
        #expect(r(img, 296, 120) < 20, "right edge \(r(img, 296, 120))")
        #expect(r(img, 160, 216) < 20, "bottom edge \(r(img, 160, 216))")
        #expect(r(img, 24, 120) > 250 && r(img, 160, 24) > 250, "top and left stay clear")
        // Inner shadow with a 9 pt blur and no offset: the same profile as the outer one, inside.
        img = effectBox(Effects(innerShadow: plainShadow(9, 0, 0, inner: true)))
        for (d, want) in [(0, 144), (2, 204), (4, 238)] {
            #expect(abs(r(img, 20 + d, 120) - want) <= 6, "inner \(d): \(r(img, 20 + d, 120))")
        }
        // Glow of radius 10 pt: nearly solid 1 px out, about half strength 5 px out, gone by 10.
        img = effectBox(Effects(glow: Glow(color: .rgb(.rgb(0, 0, 0)), radius: 10)))
        #expect(r(img, 19, 120) < 20)
        #expect((60 ..< 170).contains(r(img, 15, 120)), "\(r(img, 15, 120))")
        #expect(r(img, 10, 120) > 245)
    }

    // tests.rs: an_object_deckcraft_doesnt_model_shows_its_preview_picture
    @Test func anObjectDeckcraftDoesntModelShowsItsPreviewPicture() throws {
        // An embedded OLE object (or an unknown graphic) draws its preview stretched over its frame, as
        // PowerPoint does; with no preview it draws nothing.
        for withPreview in [true, false] {
            var p = Presentation.default
            let added = p.addMedia("image1.png", "image/png", solidPNG(4, 2, [200, 20, 20]))
            let media = try #require(added)
            p.slides[0].shapes = [shapeOf(600, Xfrm(100, 100, 400, 200), .opaque(xml: "", preview: withPreview ? media : nil, label: "Package", parts: []))]
            let img = renderDeck(p)
            for (x, y) in [(110, 110), (300, 200), (490, 290)] {
                let px = pixelAt(img, x, y)
                let isRed = px[0] > 180 && px[1] < 60 && px[2] < 60
                #expect(isRed == withPreview, "(\(x), \(y)) \(px)")
            }
            #expect(pixelAt(img, 520, 200)[1] > 200, "nothing outside the frame")
        }
    }

    /// #270: a filled shape half off the slide's left edge, and one wholly below it.
    func offSlideDeck() -> Presentation {
        deckOf([
            shapeWith(2700, Xfrm(-100, 100, 200, 100)) { $0.style = .accent(.accent1) },
            shapeWith(2701, Xfrm(400, 600, 100, 60)) { $0.style = .accent(.accent2) },
        ])
    }

    /// Within 3 of `c` on every channel and opaque (tests.rs `near`).
    func opaqueNear(_ px: [UInt8], _ c: Rgba) -> Bool { nearRGB(px, c, 3) && px[3] == 255 }

    // tests.rs: shows_exports_and_thumbnails_clip_to_the_slide
    @Test func showsExportsAndThumbnailsClipToTheSlide() {
        let p = offSlideDeck()
        let img = renderDeck(p)
        #expect(img.width == 960 && img.height == 540)
        // The on-slide half is there, nothing else is drawn outside the slide.
        #expect(opaqueNear(pixelAt(img, 50, 150), accent(p, .accent1)), "\(pixelAt(img, 50, 150))")
        #expect(pixelAt(img, 150, 150) == [255, 255, 255, 255])
    }

    // tests.rs: the_editor_pasteboard_draws_shapes_off_the_slide
    @Test func theEditorPasteboardDrawsShapesOffTheSlide() {
        let p = offSlideDeck()
        let extent = Extent.slideExtent(p, 0)
        let region = PasteboardRegion.of((960, 540), 1, extent, PasteboardRegion(x: -300, y: -200, w: 1560, h: 1000))
        #expect(region.x <= -100 && region.y == 0 && region.y + region.h >= 660, "\(region)")
        let opts = renderOpts(1) {
            $0.edit = true
            $0.offset = region.offset
            $0.size = region.size
        }
        let (img, drawn) = renderSlideDrawn(p, 0, opts)
        #expect(img.width == region.w && img.height == region.h)
        func at(_ x: Int, _ y: Int) -> [UInt8] { pixelAt(img, x - region.x, y - region.y) }
        // Both halves of the straddling shape, at full strength, and the shape below the slide.
        #expect(opaqueNear(at(-50, 150), accent(p, .accent1)), "\(at(-50, 150))")
        #expect(opaqueNear(at(50, 150), accent(p, .accent1)), "\(at(50, 150))")
        #expect(opaqueNear(at(450, 630), accent(p, .accent2)), "\(at(450, 630))")
        // The pasteboard itself stays clear (the UI's own colour shows through); the slide is white.
        #expect(at(-50, 50) == [0, 0, 0, 0])
        #expect(at(200, 300) == [255, 255, 255, 255])
        // The drawing's reach, in slide space.
        #expect(drawn.x0 <= -100 && drawn.y1 >= 660 && drawn.x1 >= 960, "\(drawn)")
    }

    // tests.rs: master_graphics_off_the_slide_show_on_the_pasteboard
    @Test func masterGraphicsOffTheSlideShowOnThePasteboard() {
        var p = Presentation.default
        p.masters[0].shapes.append(shapeWith(2702, Xfrm(-150, 300, 100, 60)) { $0.style = .accent(.accent3) })
        let region = PasteboardRegion.of((960, 540), 1, Extent.slideExtent(p, 0), PasteboardRegion(x: -300, y: -100, w: 1500, h: 800))
        let img = renderSlide(p, 0, renderOpts(1) {
            $0.edit = true
            $0.offset = region.offset
            $0.size = region.size
        })
        let px = pixelAt(img, -100 - region.x, 330 - region.y)
        #expect(opaqueNear(px, accent(p, .accent3)), "\(px)")
    }

    // tests.rs: text_spilling_out_of_its_box_below_the_slide_is_reported
    @Test func textSpillingOutOfItsBoxBelowTheSlideIsReported() {
        var t = TextBody.fromText("one\ntwo\nthree\nfour\nfive")
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices { t.paragraphs[p].runs[r].props.size = 40 }
        }
        let p = deckOf([shapeWith(2703, Xfrm(100, 500, 400, 20)) { $0.text = t }])
        // The box estimate doesn't see the text below the slide; the render does.
        #expect(Extent.slideExtent(p, 0).y1 <= 540 + 4)
        let (_, drawn) = renderSlideDrawn(p, 0, renderOpts(0.5))
        #expect(drawn.y1 > 600, "\(drawn)")
        // A slide with nothing off it reaches just the slide.
        let (_, plain) = renderSlideDrawn(Presentation.default, 0, renderOpts(0.5) { $0.edit = true })
        #expect(plain == Rect(0, 0, 960, 540), "\(plain)")
    }

    /// A 400×200 group at (100, 100) holding a dashed 4 pt rectangle, a 3 pt line with an arrowhead and
    /// an ink stroke, placed in the group's child coordinates by `toChild` (slide point to child point).
    func outlinedGroup(_ child: Xfrm, _ toChild: (Double, Double) -> (Double, Double)) -> RenderImage {
        func ink(_ w: Double) -> Line { .solid(.rgb(.rgb(200, 0, 0)), w) }
        func place(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Xfrm {
            let ((a, b), (c, d)) = (toChild(x0, y0), toChild(x1, y1))
            return Xfrm(a, b, c - a, d - b)
        }
        let rect = shapeWith(11, place(140, 120, 300, 200)) {
            $0.geom = .preset("rect")
            var l = ink(4)
            l.dash = .preset(name: "dash")
            $0.line = l
        }
        var lx = place(150, 170, 450, 260)
        lx.flipV = true
        let line = shapeWith(12, lx) {
            $0.geom = .preset("line")
            var l = ink(3)
            l.tail = LineEnd(kind: "triangle", w: "lg", len: "lg")
            $0.line = l
        }
        let pts = [(160.0, 240.0), (260.0, 285.0)].map { toChild($0.0, $0.1) }.map { Triple($0.0, $0.1, Float(1)) }
        let stroke = InkStroke(points: pts, color: .rgb(200, 0, 0), width: 5, highlighter: false)
        let inkShape = shapeOf(13, place(100, 100, 500, 300), .ink(strokes: [stroke]))
        return renderDeck(deckOf([shapeOf(10, Xfrm(100, 100, 400, 200), .group(children: [rect, line, inkShape], child: child))]))
    }

    /// Pixels whose green is under 200 (tests.rs `inked`).
    func inked(_ img: RenderImage) -> Int { countPixels(img) { $0[1] < 200 } }

    // tests.rs: group_child_scale_does_not_scale_line_widths
    @Test func groupChildScaleDoesNotScaleLineWidths() {
        // Children laid out 1:1 with the slide are the reference.
        let reference = outlinedGroup(Xfrm(100, 100, 400, 200)) { ($0, $1) }
        let drawn = inked(reference)
        #expect((500 ..< 20_000).contains(drawn), "the reference draws thin lines: \(drawn)")
        // The same drawing in a small legacy child space (scale 100), and one scaled unevenly (100 across,
        // 50 down): same outlines, same line widths, dashes and arrowhead.
        let uniform = outlinedGroup(Xfrm(1, 1, 4, 2)) { (1 + ($0 - 100) / 100, 1 + ($1 - 100) / 100) }
        let uneven = outlinedGroup(Xfrm(1, 1, 4, 4)) { (1 + ($0 - 100) / 100, 1 + ($1 - 100) / 50) }
        for (name, img) in [("uniform", uniform), ("uneven", uneven)] {
            let (n, d) = (inked(img), differingValues(reference, img))
            #expect(abs(n - drawn) * 20 < drawn, "\(name): \(n) inked pixels against \(drawn)")
            #expect(d * 20 < drawn, "\(name): \(d) differing values against \(drawn) inked pixels")
        }
    }

    // tests.rs: a_picture_and_an_embedded_objects_preview_draw_their_fill_behind_transparent_pixels
    @Test func aPictureAndAnEmbeddedObjectsPreviewDrawTheirFillBehindTransparentPixels() throws {
        // PowerPoint draws a picture's own fill behind its transparent pixels (and an old equation object's
        // fallback picture on its coloured box). Here the left half of the image is clear.
        let half = pngOf(8, 4) { x, _ in x < 4 ? [0, 0, 0, 0] : [20, 20, 160, 255] }
        let orange = Fill.solid(.rgb(.rgb(255, 153, 0)))
        for (object, fill) in [(false, nil), (false, orange), (true, orange)] as [(Bool, Fill?)] {
            var p = Presentation.default
            let added = p.addMedia("half.png", "image/png", half)
            let media = try #require(added)
            let kind: ShapeKind = object ? .opaque(xml: "", preview: media, label: "Equation.3", parts: []) : .picture(fill: PictureFill(media: media))
            var sh = shapeOf(630, Xfrm(100, 100, 400, 200), kind)
            sh.fill = fill
            p.slides[0].shapes = [sh]
            let img = renderDeck(p)
            let (clear, opaque) = (pixelAt(img, 200, 200), pixelAt(img, 400, 200))
            #expect(opaque[2] > 140 && opaque[0] < 40, "the picture's own pixels (\(object)): \(opaque)")
            if fill != nil {
                #expect(Array(clear[0 ..< 3]) == [255, 153, 0], "the fill behind the clear half (\(object)): \(clear)")
                // A fill-colour emphasis recolours that fill, as it does any shape's.
                var st = ShapeState()
                st.tint = .rgb(0, 160, 60)
                let tinted = renderSlide(p, 0, renderOpts(1) { $0.state = { _ in st } })
                #expect(Array(pixelAt(tinted, 200, 200)[0 ..< 3]) == [0, 160, 60], "the tinted fill behind the clear half (\(object))")
            } else {
                #expect(clear[0 ..< 3].allSatisfy { $0 > 240 }, "no fill: the slide shows through: \(clear)")
            }
        }
    }

    // tests.rs: a_picture_casts_its_shadow_from_its_pixels
    @Test func aPictureCastsItsShadowFromItsPixels() throws {
        // PowerPoint shades only where a picture paints: a logo on a transparent background casts the
        // logo's shadow, not its frame's. Here the left half of the image is transparent.
        let logo = pngOf(8, 4) { x, _ in x < 4 ? [0, 0, 0, 0] : [20, 160, 20, 255] }
        for asFill in [false, true] {
            var p = Presentation.default
            let added = p.addMedia("logo.png", "image/png", logo)
            let media = try #require(added)
            var sh = shapeOf(600, Xfrm(100, 100, 400, 200))
            if asFill {
                sh.fill = .picture(PictureFill(media: media))
                sh.line = noLine()
            } else {
                sh.kind = .picture(fill: PictureFill(media: media))
            }
            sh.effects = Effects(outerShadow: plainShadow(0, 20, 90))
            p.slides[0].shapes = [sh]
            let img = renderDeck(p)
            // Below the picture, 10 pt down: shadow under the opaque right half only.
            let (left, right) = (pixelAt(img, 200, 310), pixelAt(img, 400, 310))
            #expect(left[0] > 240, "no shadow under the transparent half (\(asFill)): \(left)")
            #expect(right[0] < 40, "shadow under the opaque half (\(asFill)): \(right)")
            // The transparent half shows the slide, not a shadow behind it.
            #expect(pixelAt(img, 200, 200)[0] > 240, "\(asFill)")
        }
    }

    // tests.rs: rounded_corners_in_a_stretched_group_stay_round
    @Test func roundedCornersInAStretchedGroupStayRound() {
        // #1083: a group that stretches its child space 4x across makes a rounded rectangle wider on the
        // slide, but its corners stay circular, like a plain rounded rectangle of that size.
        func round(_ id: UInt32, _ x: Xfrm) -> Shape {
            shapeWith(id, x) {
                $0.geom = .preset(name: "roundRect", adj: [16667])
                $0.fill = .solid(.rgb(.black))
                $0.line = noLine()
            }
        }
        let plain = renderDeck(deckOf([round(700, Xfrm(100, 100, 400, 100))]))
        let grouped = renderDeck(deckOf([shapeOf(701, Xfrm(100, 100, 400, 100), .group(children: [round(702, Xfrm(0, 0, 100, 100))], child: Xfrm(0, 0, 100, 100)))]))
        for (x, y) in [(120, 102), (102, 120), (480, 102), (498, 180), (120, 198)] {
            #expect(pixelAt(plain, x, y) == pixelAt(grouped, x, y), "pixel (\(x),\(y)) of a roundRect in a stretched group")
        }
    }

    // tests.rs: a_fill_overlay_blends_over_the_fill
    @Test func aFillOverlayBlendsOverTheFill() {
        // `a:fillOverlay blend="mult"`: a 50% grey multiplied over a light fill darkens it; "screen" lightens
        // a dark one; the overlay stays inside the shape.
        func draw(_ base: Rgba, _ blend: String) -> ([UInt8], [UInt8]) {
            let img = renderDeck(deckOf([shapeWith(600, Xfrm(100, 100, 200, 100)) {
                $0.fill = .solid(.rgb(base))
                $0.line = noLine()
                $0.effects = Effects(fillOverlay: FillOverlay(blend: blend, fill: .solid(.rgb(.rgb(128, 128, 128)))))
            }]))
            return (pixelAt(img, 200, 150), pixelAt(img, 50, 50))
        }
        let (mult, outside) = draw(.rgb(200, 100, 50), "mult")
        #expect(nearRGB(mult, .rgb(100, 50, 25), 3), "\(mult)")
        #expect(Array(outside[0 ..< 3]) == [255, 255, 255], "nothing outside the shape")
        let (screen, _) = draw(.rgb(0, 0, 0), "screen")
        #expect(abs(Int(screen[0]) - 128) <= 3, "\(screen)")
        let (over, _) = draw(.rgb(200, 100, 50), "over")
        #expect(abs(Int(over[0]) - 128) <= 3 && abs(Int(over[1]) - 128) <= 3, "\(over)")
    }

    // tests.rs: placed_shapes_give_the_click_boxes_of_a_slide_in_drawing_order
    @Test func placedShapesGiveTheClickBoxesOfASlideInDrawingOrder() {
        let link = Hyperlink(action: .nextSlide, tooltip: "", highlightClick: false, stopSound: false)
        func rect(_ id: UInt32, _ x: Double, _ click: Hyperlink?) -> Shape { shapeWith(id, Xfrm(x, 50, 100, 40)) { $0.click = click } }
        var group = shapeOf(10, Xfrm(300, 50, 200, 40), .group(children: [rect(11, 0, nil), rect(12, 100, nil)], child: Xfrm(0, 0, 200, 40)))
        group.click = link
        var hidden = rect(13, 0, link)
        hidden.hidden = true
        let placed = placeSlide(deckOf([rect(1, 0, nil), rect(2, 150, link), hidden, group]), 0)
        // Back to front, a group before its children; the hidden shape is not there.
        #expect(placed.shapes.map(\.id.rawValue) == [1, 2, 10, 11, 12])
        // Only the shapes with an action carry a link.
        #expect(placed.shapes.filter { $0.link != nil }.map(\.id.rawValue) == [2, 10])
        // The children know their group, whose box covers them.
        guard placed.shapes.count == 5 else { return }
        let g = placed.shapes[2]
        #expect(g.isGroup && g.parent == nil)
        for child in placed.shapes[3...] {
            #expect(child.parent == 2)
            #expect(child.rect.x0 >= g.rect.x0 - 0.01 && child.rect.x1 <= g.rect.x1 + 0.01)
        }
        // Shape actions come out as links owned by their shape, not as text links.
        #expect(placed.links.allSatisfy { !$0.text })
        #expect(placed.links.map(\.shape.rawValue) == [2, 10])
    }

    // tests.rs: a_text_hyperlink_belongs_to_the_shape_that_holds_the_text
    @Test func aTextHyperlinkBelongsToTheShapeThatHoldsTheText() {
        var body = TextBody.fromText("click here")
        for r in body.paragraphs[0].runs.indices {
            body.paragraphs[0].runs[r].props.link = Hyperlink(action: .firstSlide, tooltip: "", highlightClick: false, stopSound: false)
        }
        let placed = placeSlide(deckOf([shapeWith(7, Xfrm(100, 100, 300, 60)) { $0.text = body }]), 0)
        #expect(placed.links.contains { $0.text && $0.shape == ShapeId(7) })
        #expect(placed.shapes.allSatisfy { $0.link == nil }, "a text link is not the shape's own action")
    }

    // lib.rs `mod tests`: effects_render_with_threads_requested
    // vello's `needs_filters` and `threads` have no CoreGraphics counterpart; what is left is that a shape
    // with a soft edge is drawn, not a blank fallback.
    @Test func effectsRenderWithThreadsRequested() {
        let p = deckOf([shapeWith(900, Xfrm(10, 10, 100, 100)) {
            $0.style = .accent(.accent1)
            $0.effects = Effects(softEdge: 5)
        }])
        let img = renderSlide(p, 0, renderOpts(0.5))
        #expect(img.width == 480)
        #expect(pixelAt(img, 30, 30) != [255, 255, 255, 255])
    }

    // tests.rs: a_cropped_picture_is_decoded_at_the_resolution_of_the_whole_image
    @Test func aCroppedPictureIsDecodedAtTheResolutionOfTheWholeImage() throws {
        // The top-left sixteenth of the image in a 64 pt box: 64 image pixels over 64 output pixels.
        // Decoding at the box's size instead of the whole image's blurs the stripes to grey (#762).
        let stripes = pngOf(1024, 1024) { x, _ in (x / 2) % 2 == 0 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
        let made = pictureDeck(600, Xfrm(100, 100, 64, 64), "stripes.png", "image/png", stripes) {
            if case .picture(var pf) = $0.kind {
                pf.crop = [0, 0, 15.0 / 16.0, 15.0 / 16.0]
                $0.kind = .picture(fill: pf)
            }
        }
        let img = renderDeck(try #require(made))
        var (sharp, total) = (0, 0)
        for y in 110 ..< 154 {
            for x in 110 ..< 154 {
                total += 1
                if !(48 ... 208).contains(pixelAt(img, x, y)[0]) { sharp += 1 }
            }
        }
        #expect(sharp * 10 >= total * 9, "the stripes stay sharp: \(sharp) of \(total) pixels black or white")
    }
}

/// extent.rs's own tests: how far a slide's drawing reaches. Its two `pasteboard_region` tests come with
/// the app (Wave 5).
@Suite struct ExtentTests {
    /// The default deck with one shape at (`x`, `y`) of `w` × `h` (extent.rs `deck_with`).
    func deck(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Presentation {
        var p = Presentation.default
        p.slides[0].shapes.append(shapeOf(900, Xfrm(x, y, w, h)))
        return p
    }

    func page(_ p: Presentation) -> Rect { Rect(0, 0, p.slideSize.width, p.slideSize.height) }

    // extent.rs `mod tests`: a_slide_with_nothing_off_it_extends_no_further_than_the_slide
    @Test func aSlideWithNothingOffItExtendsNoFurtherThanTheSlide() {
        let p = deck(100, 100, 50, 50)
        #expect(Extent.slideExtent(p, 0) == page(p))
    }

    // extent.rs `mod tests`: shapes_off_the_slide_grow_the_extent
    @Test func shapesOffTheSlideGrowTheExtent() {
        let p = deck(-200, 50, 100, 80)
        let e = Extent.slideExtent(p, 0)
        #expect(e.x0 <= -200 && e.x0 > -220, "\(e)")
        #expect(e.y0 == 0)
        #expect(e.x1 == p.slideSize.width)
        // Missing slides are just the page.
        #expect(Extent.slideExtent(p, 7) == page(p))
    }

    // extent.rs `mod tests`: hidden_shapes_and_hostile_boxes_do_not_grow_it
    @Test func hiddenShapesAndHostileBoxesDoNotGrowIt() {
        var p = deck(-5000, 0, 10, 10)
        p.slides[0].shapes[p.slides[0].shapes.count - 1].hidden = true
        #expect(Extent.slideExtent(p, 0) == page(p))
        p = deck(.nan, 0, 10, 10)
        #expect(Extent.slideExtent(p, 0) == page(p))
        p = deck(.infinity, 0, 10, 10)
        #expect(Extent.slideExtent(p, 0) == page(p))
    }

    // extent.rs `mod tests`: effects_count_towards_the_extent
    @Test func effectsCountTowardsTheExtent() {
        var p = deck(10, -100, 100, 50)
        p.slides[0].shapes[p.slides[0].shapes.count - 1].effects = Effects(outerShadow: plainShadow(10, 20, 270))
        #expect(Extent.slideExtent(p, 0).y0 <= -130)
        #expect(Extent.spill(nil, Effects(glow: Glow(color: .rgb(.black), radius: .greatestFiniteMagnitude)), 1, 1) == Extent.maxSpill)
    }

    // extent.rs `mod tests`: master_graphics_off_the_slide_count_but_not_master_placeholders
    @Test func masterGraphicsOffTheSlideCountButNotMasterPlaceholders() {
        var p = Presentation.default
        p.masters[0].shapes.append(shapeOf(901, Xfrm(-150, 10, 100, 50)))
        #expect(Extent.slideExtent(p, 0).x0 <= -150)
        #expect(Extent.layoutExtent(p, 0, nil).x0 <= -150)
        #expect(Extent.layoutExtent(p, 0, 0).x0 <= -150 || !p.masters[0].layouts[0].showMasterShapes)
    }
}
