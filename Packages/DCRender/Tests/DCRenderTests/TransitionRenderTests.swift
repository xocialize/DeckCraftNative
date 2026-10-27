// Ported from deckcraft crates/render/src/transition.rs (its in-file tests: compositing, PowerPoint probes,
// dynamic content) and the Morph tests of crates/render/src/tests.rs skipped in Wave 2 (render_blend, text and
// path morphs) (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Pixel positions and
// tolerances are the Rust ones.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import DCText
import Testing

/// deckcraft's `Image::pixel`: the stored bytes (premultiplied), transparent black outside the image.
private func raw(_ img: RenderImage, _ x: Int, _ y: Int) -> [UInt8] {
    guard x >= 0, y >= 0, x < img.width, y < img.height else { return [0, 0, 0, 0] }
    let i = (y * img.width + x) * 4
    return Array(img.pixels[i ..< i + 4])
}

private func solidImage(_ w: Int, _ h: Int, _ c: [UInt8]) -> RenderImage {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0 ..< w * h {
        for k in 0 ..< 4 { px[i * 4 + k] = c[k] }
    }
    return RenderImage(width: w, height: h, pixels: px)
}

// MARK: transition.rs

private let FW = 160
private let FH = 90
private let OLD: [UInt8] = [220, 40, 40, 255]
private let NEW: [UInt8] = [30, 60, 200, 255]

private enum Is: Equatable {
    case old, new, black, white
    /// Something between (a blend).
    case mix
}

private func classify(_ p: [UInt8]) -> Is {
    func d(_ c: [UInt8]) -> Int { (0 ..< 3).map { abs(Int(p[$0]) - Int(c[$0])) }.reduce(0, +) }
    let near = 40
    if d(OLD) < near { return .old }
    if d(NEW) < near { return .new }
    if d([0, 0, 0, 255]) < near { return .black }
    if d([255, 255, 255, 255]) < near { return .white }
    // A face shaded in 3-D: a darker copy of one of the slides.
    func shaded(_ c: [UInt8]) -> Bool {
        func dot(_ a: [UInt8], _ b: [UInt8]) -> Double { (0 ..< 3).map { Double(a[$0]) * Double(b[$0]) }.reduce(0, +) }
        let k = dot(p, c) / dot(c, c)
        return (0.3 ... 1.05).contains(k) && (0 ..< 3).allSatisfy { abs(Double(p[$0]) - k * Double(c[$0])) < 14.0 }
    }
    if shaded(OLD) { return .old }
    if shaded(NEW) { return .new }
    return .mix
}

private func frame(_ kind: String, _ option: String, _ t: Double) -> RenderImage {
    compositeTransition(solidImage(FW, FH, OLD), solidImage(FW, FH, NEW), nil, transitionFrame(kind, option, t, 16.0 / 9.0))
}

private func at(_ img: RenderImage, _ x: Double, _ y: Double) -> Is {
    let px = Swift.min(Int(x * Double(FW)), FW - 1)
    let py = Swift.min(Int(y * Double(FH)), FH - 1)
    return classify(raw(img, px, py))
}

/// (kind, option, t, x, y, what PowerPoint shows there), read off PowerPoint's own frames.
private let probes: [(String, String, Double, Double, Double, Is)] = [
    ("fade", "smoothly", 0.1, 0.5, 0.5, .old),
    ("fade", "smoothly", 0.5, 0.5, 0.5, .mix),
    ("fade", "smoothly", 0.9, 0.5, 0.5, .new),
    ("fade", "throughBlack", 0.5, 0.5, 0.5, .black),
    ("cut", "throughBlack", 0.3, 0.5, 0.5, .black),
    ("cut", "", 0.3, 0.5, 0.5, .new),
    // Push / Cover / Uncover: "l" moves things toward the left; the new slide comes from the right.
    ("push", "l", 0.25, 0.97, 0.5, .new),
    ("push", "l", 0.25, 0.1, 0.5, .old),
    ("push", "r", 0.25, 0.03, 0.5, .new),
    ("push", "u", 0.25, 0.5, 0.97, .new),
    ("push", "d", 0.25, 0.5, 0.03, .new),
    ("cover", "l", 0.5, 0.75, 0.5, .new),
    ("cover", "l", 0.5, 0.25, 0.5, .old),
    ("cover", "rd", 0.5, 0.05, 0.05, .new),
    ("cover", "rd", 0.2, 0.97, 0.97, .old),
    ("uncover", "l", 0.5, 0.25, 0.5, .old),
    ("uncover", "l", 0.5, 0.75, 0.5, .new),
    ("uncover", "lu", 0.5, 0.5, 0.5, .new),
    // Wipe "r" sweeps rightward with a soft edge; "u" upward; diagonals from a corner.
    ("wipe", "r", 0.5, 0.05, 0.5, .new),
    ("wipe", "r", 0.5, 0.97, 0.5, .old),
    ("wipe", "l", 0.5, 0.97, 0.5, .new),
    ("wipe", "u", 0.5, 0.5, 0.97, .new),
    ("wipe", "u", 0.5, 0.5, 0.03, .old),
    ("wipe", "d", 0.5, 0.5, 0.03, .new),
    ("wipe", "ru", 0.5, 0.03, 0.97, .new),
    ("wipe", "ru", 0.5, 0.97, 0.03, .old),
    ("wipe", "r", 0.5, 0.55, 0.5, .mix),
    // Split: Out opens from the middle, In closes from the edges.
    ("split", "horzOut", 0.5, 0.5, 0.5, .new),
    ("split", "horzOut", 0.5, 0.5, 0.02, .old),
    ("split", "horzIn", 0.5, 0.5, 0.02, .new),
    ("split", "horzIn", 0.5, 0.5, 0.5, .old),
    ("split", "vertOut", 0.5, 0.5, 0.5, .new),
    ("split", "vertOut", 0.5, 0.02, 0.5, .old),
    ("split", "vertIn", 0.5, 0.02, 0.5, .new),
    // Shape: grows from the centre; In shrinks the old slide over the first half, Out grows the new one over
    // the second.
    ("shape", "circle", 0.5, 0.5, 0.5, .new),
    ("shape", "circle", 0.5, 0.02, 0.03, .old),
    ("shape", "diamond", 0.5, 0.5, 0.5, .new),
    ("shape", "diamond", 0.5, 0.02, 0.03, .old),
    ("shape", "plus", 0.5, 0.5, 0.05, .new),
    ("shape", "plus", 0.5, 0.05, 0.05, .old),
    ("shape", "in", 0.25, 0.5, 0.5, .old),
    ("shape", "in", 0.25, 0.05, 0.05, .new),
    ("shape", "in", 0.75, 0.5, 0.5, .new),
    ("shape", "out", 0.25, 0.5, 0.5, .old),
    ("shape", "out", 0.75, 0.5, 0.5, .new),
    ("shape", "out", 0.75, 0.05, 0.05, .old),
    // Flash: white in the middle.
    ("flash", "", 0.3, 0.5, 0.5, .white),
    // Clock: a hand sweeping from 12 o'clock.
    ("clock", "clockwise", 0.25, 0.6, 0.15, .new),
    ("clock", "clockwise", 0.25, 0.4, 0.15, .old),
    ("clock", "counterClockwise", 0.25, 0.4, 0.15, .new),
    ("clock", "counterClockwise", 0.25, 0.6, 0.15, .old),
    ("clock", "wedge", 0.5, 0.5, 0.05, .new),
    ("clock", "wedge", 0.5, 0.5, 0.95, .old),
    // Ripple: from the centre, or from the corner opposite the option.
    ("ripple", "center", 0.5, 0.5, 0.5, .new),
    ("ripple", "center", 0.5, 0.02, 0.03, .old),
    ("ripple", "ru", 0.4, 0.03, 0.97, .new),
    ("ripple", "ru", 0.4, 0.97, 0.03, .old),
    // Comb: the old slide's bands slide off, the bottom band first.
    ("comb", "horz", 0.5, 0.5, 0.97, .new),
    ("comb", "horz", 0.5, 0.5, 0.03, .old),
    // Glitter "l": the sweep starts on the left.
    ("glitter", "l", 0.45, 0.03, 0.5, .new),
    ("glitter", "l", 0.45, 0.97, 0.5, .old),
    ("glitter", "r", 0.45, 0.97, 0.5, .new),
    // Vortex "l": the old slide whirls off toward the left, its right side first.
    ("vortex", "l", 0.25, 0.03, 0.5, .old),
    ("vortex", "l", 0.97, 0.03, 0.5, .new),
    // Cube / Box "l": the new face comes in from the right.
    ("cube", "l", 0.5, 0.85, 0.5, .new),
    ("cube", "l", 0.5, 0.15, 0.5, .old),
    ("cube", "r", 0.5, 0.15, 0.5, .new),
    ("box", "l", 0.25, 0.97, 0.5, .new),
    ("box", "l", 0.25, 0.3, 0.5, .old),
    ("cube", "u", 0.5, 0.5, 0.9, .new),
    ("cube", "d", 0.5, 0.5, 0.1, .new),
    // Switch "l": the old card is pulled out to the left, the new one to the right.
    ("switch", "l", 0.25, 0.97, 0.5, .new),
    ("switch", "l", 0.25, 0.3, 0.5, .old),
    ("switch", "r", 0.25, 0.03, 0.5, .new),
    // Gallery "l": the slides travel left along the wall.
    ("gallery", "l", 0.6, 0.9, 0.5, .new),
    // Flip: the old face, then the new one.
    ("flip", "l", 0.2, 0.5, 0.5, .old),
    ("flip", "l", 0.8, 0.5, 0.5, .new),
    // Doors open in the middle, the new slide coming forward between them.
    ("doors", "vert", 0.9, 0.5, 0.5, .new),
    // Fall Over: the old slide tips backward, uncovering the new one at the top first.
    ("fallOver", "l", 0.6, 0.5, 0.03, .new),
    ("fallOver", "l", 0.6, 0.5, 0.97, .old),
    // Peel Off "l": from the bottom-right corner.
    ("peelOff", "l", 0.4, 0.98, 0.98, .new),
    ("peelOff", "l", 0.4, 0.03, 0.03, .old),
    ("peelOff", "r", 0.4, 0.02, 0.98, .new),
    // Page Curl: the far half rolls up first.
    ("pageCurlDouble", "l", 0.5, 0.9, 0.5, .new),
    ("pageCurlDouble", "l", 0.5, 0.1, 0.5, .old),
    ("pageCurlDouble", "r", 0.5, 0.1, 0.5, .new),
    ("pageCurlDouble", "singleL", 0.6, 0.95, 0.5, .new),
    ("pageCurlDouble", "singleL", 0.6, 0.05, 0.5, .old),
    // Airplane "l": a dart with its nose to the right, hanging low.
    ("airplane", "l", 0.5, 0.15, 0.1, .new),
    ("airplane", "l", 0.5, 0.8, 0.68, .old),
    ("airplane", "r", 0.5, 0.2, 0.68, .old),
    // Origami "l": the bird flies off to the left.
    ("origami", "l", 0.75, 0.97, 0.5, .new),
    // Fracture: shards fall, the top first.
    ("fracture", "", 0.6, 0.5, 0.05, .new),
    // Crush: the old slide crumples toward the centre.
    ("crush", "", 0.5, 0.03, 0.03, .new),
    ("crush", "", 0.5, 0.45, 0.5, .old),
    // Curtains part in the middle.
    ("curtains", "", 0.4, 0.5, 0.5, .new),
    ("curtains", "", 0.4, 0.02, 0.5, .old),
    // Zoom and Rotate: the new slide spins in from the centre over the old one.
    ("zoom", "rotate", 0.2, 0.03, 0.03, .old),
    ("zoom", "out", 0.8, 0.5, 0.5, .new),
    ("dissolve", "", 0.02, 0.5, 0.5, .old),
    ("dissolve", "", 0.99, 0.5, 0.5, .new),
]

// MARK: tests.rs helpers

private func deckWith(_ shapes: [Shape]) -> Presentation { deckOf(shapes) }

private func accentShape(_ id: UInt32, _ x: Xfrm, _ geom: Geom = .default) -> Shape {
    var s = Shape.default
    s.id = ShapeId(id)
    s.xfrm = x
    s.geom = geom
    s.style = ShapeStyle.accent(.accent1)
    return s
}

private func half(_ scale: Double = 0.5) -> RenderOpts { RenderOpts(scale: scale) }

/// Channel values more than `k` apart.
private func differ(_ a: RenderImage, _ b: RenderImage, _ k: Int) -> Int {
    zip(a.pixels, b.pixels).filter { abs(Int($0) - Int($1)) > k }.count
}

@Suite struct TransitionRenderTests {
    @Test func layersCompositeInOrder() {
        let old = solidImage(40, 20, [255, 0, 0, 255])
        let new = solidImage(40, 20, [0, 0, 255, 255])
        #expect(raw(compositeTransition(old, new, nil, transitionLayers("cover", "l", 0.0)), 20, 10) == [255, 0, 0, 255])
        #expect(raw(compositeTransition(old, new, nil, transitionLayers("cover", "l", 1.0)), 20, 10) == [0, 0, 255, 255])
    }

    @Test func missingOldSlideIsBlack() {
        let new = solidImage(10, 10, [0, 255, 0, 255])
        #expect(raw(compositeTransition(nil, new, nil, [Layer.full(.old, 1.0)]), 5, 5) == [0, 0, 0, 255])
    }

    @Test func halfAlphaBlends() {
        let old = solidImage(10, 10, [200, 0, 0, 255])
        let new = solidImage(10, 10, [0, 0, 200, 255])
        let p = raw(compositeTransition(old, new, nil, [Layer.full(.old, 1.0), Layer.full(.new, 0.5)]), 5, 5)
        #expect(abs(Int(p[0]) - 100) <= 1 && abs(Int(p[2]) - 100) <= 1, "\(p)")
    }

    @Test func framesMatchPowerpointProbes() {
        var bad: [String] = []
        for (kind, option, t, x, y, want) in probes {
            let got = at(frame(kind, option, t), x, y)
            if got != want { bad.append("\(kind)/\(option) t=\(t) (\(x),\(y)): want \(want), got \(got)") }
        }
        #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
    }

    @Test func everyTransitionStartsOldAndEndsNew() {
        for info in transitions {
            for o in info.options + [""] {
                #expect(at(frame(info.id, o, 0.0), 0.5, 0.5) == .old, "\(info.id)/\(o)")
                #expect(at(frame(info.id, o, 1.0), 0.5, 0.5) == .new, "\(info.id)/\(o)")
                for t in [0.25, 0.5, 0.75] {
                    let img = frame(info.id, o, t)
                    #expect(img.width == FW && img.height == FH)
                }
            }
        }
    }

    @Test func dynamicContentMovesContentsOverBackgrounds() {
        // Old: red background with a white content square in the middle; new: blue background with a yellow
        // square.
        func content(_ c: [UInt8]) -> RenderImage {
            var img = solidImage(FW, FH, [0, 0, 0, 0])
            for y in 35 ..< 55 {
                for x in 70 ..< 90 {
                    let i = (y * FW + x) * 4
                    img.pixels.replaceSubrange(i ..< i + 4, with: c)
                }
            }
            return img
        }
        let parts = SlideParts(
            oldBack: solidImage(FW, FH, OLD), oldContent: content([255, 255, 255, 255]), newBack: solidImage(FW, FH, NEW),
            newContent: content([255, 220, 0, 255])
        )
        let old = solidImage(FW, FH, OLD)
        let new = solidImage(FW, FH, NEW)
        func f(_ kind: String, _ o: String, _ t: Double) -> RenderImage {
            compositeTransition(old, new, parts, transitionFrame(kind, o, t, 16.0 / 9.0))
        }
        // Pan left at the middle: the backgrounds blend, the old square has moved left.
        let img = f("pan", "l", 0.5)
        let bg = raw(img, 5, 5)
        #expect(bg[0] > 60 && bg[2] > 60, "\(bg)")
        #expect(raw(img, 80, 45) == bg, "the middle shows background only")
        // Pan right: the new square arrives from the left.
        let img2 = f("pan", "r", 0.6)
        #expect((0 ..< 80).contains { x in
            let p = raw(img2, x, 45)
            return p[0] > 200 && p[1] > 180 && p[2] < 80
        })
        // Reveal: the new content is in place near the end.
        let p = raw(f("reveal", "smoothlyLeft", 0.97), 80, 45)
        #expect(p[0] > 200 && p[1] > 180, "\(p)")
        // Without parts the dynamic transitions still draw whole slides.
        let whole = compositeTransition(old, new, nil, transitionFrame("pan", "l", 0.5, 16.0 / 9.0))
        #expect(raw(whole, 80, 45) != [0, 0, 0, 255])
    }

    // MARK: tests.rs

    @Test func blendEndsMatchTheSlidesAndMixesBackdrops() {
        let sh = accentShape(500, Xfrm(100, 100, 200, 100))
        var p = deckWith([sh])
        var dark = p.slides[0]
        dark.background = .fill(fill: Fill.solid(ColorRef.rgb(Rgba.rgb(0, 0, 0))))
        p.slides.append(dark)
        let o = half()
        let shapes = [(sh, false)]
        // At the ends the frame is the slide itself; the shape stays opaque throughout.
        #expect(renderBlend(p, 0, 1, 1.0, shapes, [], [], o).pixels == renderSlide(p, 1, o).pixels)
        let mid = renderBlend(p, 0, 1, 0.5, shapes, [], [], o)
        let px = raw(mid, 5, 5)
        #expect(abs(Int(px[0]) - 128) <= 3, "\(px)")
        #expect(raw(mid, 100, 75) == raw(renderSlide(p, 1, o), 100, 75))
        // Hostile input: bad indices and NaN never trap.
        #expect(renderBlend(p, 0, 9, 0.5, shapes, [], [], o).width == 0)
        _ = renderBlend(p, 0, 1, .nan, shapes, [], [], o)
    }

    @Test func morphTextTokensAreWordsOrCharacters() throws {
        let p = Presentation.default
        let rctx = try #require(Resolve.Ctx.forSlide(p, p.slides[0]))
        let s = textShape(1, "Hello big  world\nHello", 0, 0)
        let body = try #require(s.text)
        let l = TextLayoutEngine.layout(rctx, s, body, TextOpts(rect: Rect(0, 0, 600, 120), fields: NoFields(), promptColor: nil, noShrink: false))
        #expect(MorphTextDraw.tokenKeys(l, false) == ["Hello", "big", "world", "Hello"])
        #expect(MorphTextDraw.tokenKeys(l, true).joined() == "Hellobigworld" + "Hello")
        #expect(MorphTextDraw.tokenKeys(l, true).count == 18)
    }

    @Test func morphTextEndsMatchTheSlides() {
        let from = Xfrm(100, 60, 600, 120)
        let to = Xfrm(200, 300, 600, 120)
        var p = deckWith([textShape(1, "Hello wide world", from.x, from.y)])
        var b = p.slides[0]
        b.shapes = [textShape(1, "world says Hello", to.x, to.y)]
        p.slides.append(b)
        let o = half()
        func frame(_ t: Double) -> RenderImage {
            let x = Xfrm(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t, 600, 120)
            var sb = textShape(10, "world says Hello", 0, 0)
            var sa = textShape(11, "Hello wide world", 0, 0)
            sb.xfrm = x
            sa.xfrm = x
            let tm = TextMorph(old: ShapeId(11), new: ShapeId(10), from: from, to: to, chars: false, t: t)
            return renderBlend(p, 0, 1, t, [(sb, false), (sa, true)], [tm], [], o)
        }
        // Warm up: faces load lazily, so the first render may still fall back.
        _ = (renderSlide(p, 0, o), renderSlide(p, 1, o), frame(0.5))
        let d0 = differ(frame(0.0), renderSlide(p, 0, o), 8)
        #expect(d0 < 40, "start differs \(d0)")
        let d1 = differ(frame(1.0), renderSlide(p, 1, o), 8)
        #expect(d1 < 40, "end differs \(d1)")
        // Halfway the shared words are on their way: ink between the two texts' rows.
        let mid = frame(0.5)
        var ink = 0
        for y in 95 ..< 140 {
            for x in 0 ..< 480 where raw(mid, x, y)[0] < 128 { ink += 1 }
        }
        #expect(ink > 50, "ink \(ink)")
    }

    @Test func morphPathEndsMatchTheSlides() {
        let from = Xfrm(100, 100, 200, 200)
        let to = Xfrm(500, 150, 300, 150)
        var p = deckWith([accentShape(1, from, .preset("ellipse"))])
        var b = p.slides[0]
        b.shapes = [accentShape(1, to, .preset("star5"))]
        p.slides.append(b)
        let o = half()
        func frame(_ t: Double) -> RenderImage {
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            let x = Xfrm(lerp(from.x, to.x), lerp(from.y, to.y), lerp(from.w, to.w), lerp(from.h, to.h))
            let pm = PathMorph(id: ShapeId(10), from: .preset("ellipse"), fromBox: from, toBox: to, t: t)
            return renderBlend(p, 0, 1, t, [(accentShape(10, x, .preset("star5")), false)], [], [pm], o)
        }
        // The morph splits the outlines into more curves, which flatten slightly differently: edge pixels may
        // differ a little, a different shape differs a lot. At the start the star is still the circle, at the
        // end the star.
        let d0 = differ(frame(0.0), renderSlide(p, 0, o), 60)
        #expect(d0 < 40, "start differs \(d0)")
        let d1 = differ(frame(1.0), renderSlide(p, 1, o), 60)
        #expect(d1 < 40, "end differs \(d1)")
        // Without the morph the start would show the star.
        let star = renderBlend(p, 0, 1, 0.0, [(accentShape(10, from, .preset("star5")), false)], [], [], o)
        #expect(differ(star, renderSlide(p, 0, o), 60) > 400)
        // Halfway the shape is filled around the middle of its box.
        let mid = frame(0.5)
        let c = ((from.center.x + to.center.x) * 0.5 * 0.5, (from.center.y + to.center.y) * 0.5 * 0.5)
        #expect(raw(mid, Int(c.0), Int(c.1)) != [255, 255, 255, 255])
    }

    @Test func morphPathFadesAFillOnlyOneSideHas() {
        let bx = Xfrm(100, 100, 200, 200)
        var p = deckWith([accentShape(1, bx, .preset("rect"))])
        var b = p.slides[0]
        b.shapes = [accentShape(1, bx, .preset("line"))]
        p.slides.append(b)
        let o = half()
        func at(_ t: Double) -> [UInt8] {
            let pm = PathMorph(id: ShapeId(10), from: .preset("rect"), fromBox: bx, toBox: bx, t: t)
            // A point near the line but not on it: inside the shape all the way.
            return raw(renderBlend(p, 0, 1, t, [(accentShape(10, bx, .preset("line")), false)], [], [pm], o), 110, 90)
        }
        let (full, halfway, none) = (at(0.0), at(0.5), at(1.0))
        #expect(none == [255, 255, 255, 255])
        #expect(full[0] < 128, "\(full)")
        // Halfway the fill is half there: between the full colour and the white slide.
        #expect(Int(halfway[0]) > Int(full[0]) + 40 && halfway[0] < 215, "\(halfway) vs \(full)")
    }

    @Test func morphPathAlignsOncePerTransition() {
        let (from, to) = (Xfrm(0, 0, 200, 200), Xfrm(0, 0, 300, 150))
        var star = Shape.default
        star.geom = .preset("star5")
        func pm(_ t: Double) -> PathMorph { PathMorph(id: ShapeId(10), from: .preset("ellipse"), fromBox: from, toBox: to, t: t) }
        func els(_ r: (Preset.Geometry, [Morph.Fade])) -> ([[PathEl]], [Morph.Fade]) { (r.0.paths.map(\.path.elements), r.1) }
        let cache = MorphPathCache()
        for t in [0.0, 0.3, 0.7, 1.0] {
            let got = els(cache.geometry(pm(t), star, 250, 175))
            // The same as aligning afresh.
            let fresh = els(MorphPathCache().geometry(pm(t), star, 250, 175))
            #expect(got.0 == fresh.0 && got.1 == fresh.1)
            cache.sweep()
        }
        #expect(cache.count == 1)
        // Another target outline is another morph.
        var rect = Shape.default
        rect.geom = .preset("rect")
        _ = cache.geometry(pm(0.5), rect, 250, 175)
        #expect(cache.count == 2)
        // A frame without morphs ends the transition: the cache empties.
        cache.sweep()
        cache.sweep()
        #expect(cache.count == 0)
    }
}
