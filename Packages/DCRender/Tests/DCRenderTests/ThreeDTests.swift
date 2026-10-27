// Ported from deckcraft crates/render/src/camera.rs, light.rs, bevel.rs and extrude.rs (their in-file
// tests), and the 3-D tests of tests.rs and tests_wild.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Tolerances are the Rust ones unless noted.
import DCColor
import DCGeometry
import DCModel
@testable import DCRender
import Darwin
import Testing

@Suite struct ThreeDTests {
    // MARK: camera.rs

    func corners(_ m: Affine, _ w: Double, _ h: Double) -> [Point] {
        [(0.0, 0.0), (w, 0), (w, h), (0, h)].map { m * Point($0.0, $0.1) }
    }

    @Test func turningAboutTheVerticalAxisNarrowsTheShape() throws {
        // orthographicFront with lon 60: half as wide, as tall (PowerPoint: 0.506 of the width).
        let c = try #require(Camera.fromRaw(#"<a:scene3d><a:camera prst="orthographicFront"><a:rot lat="0" lon="3600000" rev="0"/></a:camera><a:lightRig rig="threePt" dir="t"><a:rot lat="0" lon="0" rev="1200000"/></a:lightRig></a:scene3d>"#))
        let m = try #require(Camera.affine(c, 100, 75))
        let k = corners(m, 100, 75)
        #expect(abs(k[1].x - k[0].x - 50) < 0.01 && abs(k[3].y - k[0].y - 75) < 0.01, "\(k)")
        #expect(abs((k[0].x + k[1].x) / 2 - 50) < 1e-9, "about the centre")
    }

    @Test func presetsTurnTheShapeAsPowerPointDoes() throws {
        // isometricTopUp, 100 × 75: PowerPoint's corners at (-1.247, 0.127), (0.170, -0.955), (1.237, -0.141),
        // (-0.181, 0.941) of the half sizes from the centre.
        let c = try #require(Camera.fromRaw(#"<a:scene3d><a:camera prst="isometricTopUp"/><a:lightRig rig="threePt" dir="t"/></a:scene3d>"#))
        let k = corners(try #require(Camera.affine(c, 100, 75)), 100, 75)
        for (p, (u, v)) in zip(k, [(-1.247, 0.127), (0.170, -0.955), (1.237, -0.141), (-0.181, 0.941)]) {
            let (x, y) = ((p.x - 50) / 50, (p.y - 37.5) / 37.5)
            #expect(abs(x - u) < 0.03 && abs(y - v) < 0.03, "(\(x), \(y)) vs (\(u), \(v))")
        }
        // Front-facing cameras and the oblique ones leave a flat shape as it is.
        for raw in [#"<a:scene3d><a:camera prst="orthographicFront"/></a:scene3d>"#, #"<a:scene3d><a:camera prst="obliqueTopLeft"/></a:scene3d>"#] {
            #expect(Camera.fromRaw(raw) == nil)
        }
        #expect(Camera.fromRaw("<a:sp3d/>") == nil)
    }

    @Test func aPerspectiveCameraIsApproximatedClosely() throws {
        // perspectiveContrastingLeftFacing on 100 × 75: PowerPoint's corners within 3% of the size.
        let c = try #require(Camera.fromRaw(#"<a:scene3d><a:camera prst="perspectiveContrastingLeftFacing"/></a:scene3d>"#))
        let k = corners(try #require(Camera.affine(c, 100, 75)), 100, 75)
        for (p, (u, v)) in zip(k, [(-0.657, -1.189), (0.791, -0.795), (0.685, 1.244), (-0.742, 0.729)]) {
            let (dx, dy) = (p.x - 50 - u * 50, p.y - 37.5 - v * 37.5)
            #expect(Darwin.hypot(dx, dy) < 3, "\(p) vs (\(u), \(v))")
        }
    }

    // MARK: light.rs

    @Test func threePointMatteIsTheMeasuredFormula() {
        let l = Lighting.fromRaw(#"<a:lightRig rig="threePt" dir="t"/>"#)
        let n: [Double] = [0, 0, 1]
        let expect = 0.453 + 0.731 * sin(45.0 * Double.pi / 180)
        #expect(abs(l.factor(n) - expect) < 1e-9)
        #expect(l.highlight(n) == 0)
        let c = l.shade(.rgb(100, 100, 100), n)
        #expect(c.r == UInt8((100 * expect + 14.7).rounded()))
    }

    @Test func rigsAndMaterialsDifferAsNamed() {
        let face: [Double] = [0, 0, 1]
        func f(_ raw: String) -> Double { Lighting.fromRaw(raw).factor(face) }
        #expect(f(#"rig="brightRoom""#) > f(#"rig="threePt""#), "a bright room is brighter")
        #expect(f(#"rig="harsh""#) < f(#"rig="soft""#) + 0.2)
        #expect(Lighting.fromRaw(#"rig="flat""#).shade(.rgb(10, 20, 30), face) == .rgb(10, 20, 30))
        // Metal shines where plastic shines less and matte not at all.
        let upLeft: [Double] = {
            let d = Lighting.dir(240, 45)
            let h = [d[0], d[1], d[2] + 1]
            let l = (h[0] * h[0] + h[1] * h[1] + h[2] * h[2]).squareRoot()
            return [h[0] / l, h[1] / l, h[2] / l]
        }()
        func hi(_ m: String) -> Double { Lighting.fromRaw(#"prstMaterial="\#(m)""#).highlight(upLeft) }
        #expect(hi("metal") > hi("plastic") && hi("plastic") > 0 && hi("matte") == 0)
        // Turning the rig to the right moves the key light: a right-facing surface gets brighter.
        let right: [Double] = [0.7, 0, 0.7]
        #expect(Lighting.fromRaw(#"rig="threePt" dir="r""#).factor(right) > Lighting.fromRaw(#"rig="threePt" dir="t""#).factor(right))
        // Sunset is warm.
        let warm = Lighting.fromRaw(#"rig="sunset""#).shade(.rgb(200, 200, 200), face)
        #expect(warm.r > warm.b)
    }

    // MARK: bevel.rs

    /// The three-point rig's key light (deckcraft's test helper `light()`).
    func light() -> [Double] {
        let (az, el) = (240.0 * Double.pi / 180, 45.0 * Double.pi / 180)
        return [cos(el) * cos(az), cos(el) * sin(az), sin(el)]
    }

    @Test func bevelsAreReadFromKept3dXML() throws {
        var raw = #"<a:scene3d><a:camera prst="orthographicFront"/></a:scene3d><a:sp3d><a:bevelT w="50800" h="16510" prst="angle"/></a:sp3d>"#
        let b = try #require(Bevel.fromRaw(raw))
        #expect(b.w == 4.0 && b.h == 1.3 && b.preset == "angle")
        #expect(b.lighting == Lighting.fromRaw(raw))
        // Defaults: 6 pt square, circle.
        raw = #"<a:scene3d/><a:sp3d><a:bevelT/></a:sp3d>"#
        #expect(Bevel.fromRaw(raw).map { $0.w == 6 && $0.h == 6 && $0.preset == "circle" } == true)
        // Another rig or material is lit by it.
        raw = #"<a:scene3d><a:lightRig rig="flood" dir="t"/></a:scene3d><a:sp3d prstMaterial="metal"><a:bevelT/></a:sp3d>"#
        #expect(Bevel.fromRaw(raw).map { $0.lighting.specular > 0 } == true)
        // No scene: flat in PowerPoint.
        #expect(Bevel.fromRaw(#"<a:sp3d><a:bevelT w="50800"/></a:sp3d>"#) == nil)
        // A 3-D shape with no bevel: a bevel of no width (its face is lit).
        #expect(Bevel.fromRaw(#"<a:scene3d/><a:sp3d extrusionH="10"/>"#).map { $0.w == 0 } == true)
        #expect(Bevel.fromRaw(#"<a:scene3d/>"#) == nil)
    }

    @Test func theLightComesFromTheUpperLeft() {
        let l = light()
        #expect(l[0] < 0 && l[1] < 0 && l[2] > 0)
        // An upward-facing edge (outward normal up) is lit more than a downward one.
        func lit(_ e: [Double]) -> Double {
            let z = Bevel.slope("circle", 0.3) * 0.5
            let n = [e[0] * z, e[1] * z, 1.0]
            let len = (n[0] * n[0] + n[1] * n[1] + 1).squareRoot()
            return (n[0] * l[0] + n[1] * l[1] + n[2] * l[2]) / len
        }
        #expect(lit([0, -1]) > lit([-1, 0]) && lit([-1, 0]) > lit([1, 0]) && lit([1, 0]) > lit([0, 1]))
    }

    // MARK: extrude.rs

    @Test func readsDepthAndColour() throws {
        let raw = #"<a:scene3d><a:camera prst="isometricOffAxis2Left"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="381000"><a:extrusionClr><a:srgbClr val="C00000"/></a:extrusionClr></a:sp3d>"#
        let e = try #require(Extrude.fromRaw(raw))
        #expect(abs(e.depth - 30) < 1e-9)
        #expect(e.color == .rgb(.rgb(0xC0, 0, 0)))
        #expect(Extrude.fromRaw(#"<a:sp3d extrusionH="381000"/>"#) == nil, "no scene: drawn flat")
        #expect(Extrude.fromRaw(#"<a:scene3d/><a:sp3d/>"#) == nil)
    }

    @Test func theBackFaceGoesAwayFromTheViewer() {
        // Turned left about the vertical axis, the back face shows to the right... of the turned face for a
        // positive longitude, and nothing for a front camera.
        let c = Camera(lat: 0, lon: 30, rev: 0, dist: 0)
        let o = Extrude.backOffset(c, 20, 100, 50)
        #expect(abs(abs(o.x) - 10) < 1e-9 && abs(o.y) < 1e-9, "\(o)")
        let front = Camera(lat: 0, lon: 0, rev: 0, dist: 0)
        #expect(Extrude.backOffset(front, 20, 100, 50).hypot < 1e-9)
    }
}

/// The 3-D tests of tests.rs and tests_wild.rs: shapes with depth, contours and bevels on a rendered slide.
@Suite struct ThreeDRenderTests {
    /// A shape `id` at `x` with preset `preset`, accent 1's style and 3-D XML `raw`.
    func solid3d(_ id: UInt32, _ x: Xfrm, _ preset: String, _ raw: String) -> Shape {
        var s = shapeOf(id, x)
        s.geom = .preset(preset)
        s.style = .accent(.accent1)
        s.effects = Effects(raw3d: raw)
        return s
    }

    /// Shapes with depth under turned cameras (an `extrusionH` and, on two, an `extrusionClr`).
    func extrudedDeck() -> Presentation {
        func mk(_ id: UInt32, _ x: Double, _ preset: String, _ raw: String) -> Shape { solid3d(id, Xfrm(x, 170, 170, 130), preset, raw) }
        return deckOf([
            mk(700, 40, "rect", #"<a:scene3d><a:camera prst="isometricOffAxis2Left"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="381000"/>"#),
            mk(701, 280, "ellipse", #"<a:scene3d><a:camera prst="isometricTopUp"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="254000" contourW="63500"><a:extrusionClr><a:srgbClr val="C00000"/></a:extrusionClr><a:contourClr><a:srgbClr val="FFC000"/></a:contourClr></a:sp3d>"#),
            mk(702, 520, "star5", #"<a:scene3d><a:camera prst="perspectiveContrastingLeftFacing"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="508000"><a:extrusionClr><a:schemeClr val="accent2"/></a:extrusionClr></a:sp3d>"#),
            mk(703, 760, "rect", #"<a:scene3d><a:camera prst="orthographicFront"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="381000" contourW="76200" prstMaterial="metal"><a:contourClr><a:srgbClr val="00B050"/></a:contourClr></a:sp3d>"#),
        ])
    }

    /// Pixels of `img` in columns `x0..<x1`, rows `y0..<y1`, that pass `f`.
    func count(_ img: RenderImage, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ f: ([UInt8]) -> Bool) -> Int {
        var n = 0
        for x in x0 ..< Swift.min(x1, img.width) {
            for y in y0 ..< Swift.min(y1, img.height) where f(pixelAt(img, x, y)) { n += 1 }
        }
        return n
    }

    @Test func contoursBandTheOutlineInTheirColour() {
        let img = renderDeck(extrudedDeck())
        // The ellipse's yellow contour and the flat rectangle's green one.
        #expect(count(img, 260, 480, 0, img.height) { $0[0] > 200 && (150 ..< 230).contains($0[1]) && $0[2] < 80 } > 200)
        #expect(count(img, 740, 960, 0, img.height) { $0[0] < 80 && $0[1] > 120 && $0[2] < 120 } > 300)
    }

    @Test func extrusionsShowTheirSidesUnderATurnedCamera() {
        let img = renderDeck(extrudedDeck())
        // The red sides of the ellipse; the dark accent-1 sides of the cube; none for a front camera.
        #expect(count(img, 250, 500, 100, 400) { $0[0] > 100 && $0[1] < 40 && $0[2] < 40 } > 300, "red extrusion")
        let flat = renderDeck(deckOf([]))
        func ink(_ img: RenderImage, _ x0: Int, _ x1: Int) -> Int { count(img, x0, x1, 100, 400) { $0 != [255, 255, 255, 255] } }
        var noDepth = extrudedDeck()
        for i in noDepth.slides[0].shapes.indices {
            let raw = noDepth.slides[0].shapes[i].effects?.raw3d
            noDepth.slides[0].shapes[i].effects?.raw3d = raw?.replacingOccurrences(of: " extrusionH=", with: " x=")
        }
        let thin = renderDeck(noDepth)
        #expect(ink(img, 0, 260) > ink(thin, 0, 260) + 1000, "the cube's sides add ink")
        #expect(ink(img, 740, 960) == ink(thin, 740, 960), "a front camera shows no sides")
        #expect(ink(flat, 0, 960) == 0)
    }

    /// The extruded deck plus a bevelled rectangle `id` with 3-D XML `raw`.
    func withBevel(_ id: UInt32, _ raw: String) -> Presentation {
        var deck = extrudedDeck()
        deck.slides[0].shapes.append(solid3d(id, Xfrm(40, 340, 170, 130), "rect", raw))
        return deck
    }

    func inked(_ img: RenderImage) -> Int { straightPixels(img).filter { $0 != [255, 255, 255, 255] }.count }

    @Test func groupChildScaleDoesNotScale3dDepthContoursOrBevels() {
        // A legacy group child space (here 100 points per unit) scales the shapes' boxes, but extrusion depths,
        // contour widths and bevels are points: a 1 pt contour on a small extruded cube in such a group was
        // drawn hundreds of points wide, a band across the whole slide.
        let shapes = withBevel(704, #"<a:scene3d><a:camera prst="orthographicFront"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d><a:bevelT w="254000" h="254000"/></a:sp3d>"#).slides[0].shapes
        func grouped(_ k: Double) -> RenderImage {
            let children = shapes.map { s -> Shape in
                var c = s
                let x = s.xfrm ?? Xfrm()
                c.xfrm = Xfrm(x.x / k, x.y / k, x.w / k, x.h / k)
                return c
            }
            return renderDeck(deckOf([shapeOf(10, Xfrm(0, 0, 960, 540), .group(children: children, child: Xfrm(0, 0, 960 / k, 540 / k)))]))
        }
        let reference = grouped(1)
        let drawn = inked(reference)
        #expect(drawn > 20_000, "the reference draws the shapes: \(drawn)")
        let scaled = grouped(100)
        let (n, d) = (inked(scaled), differingValues(reference, scaled))
        #expect(abs(n - drawn) * 20 < drawn, "\(n) inked pixels against \(drawn)")
        #expect(d * 20 < drawn, "\(d) differing values against \(drawn) inked pixels")
    }

    @Test func aTurnedCameraInAOneToOneGroupDrawsIts3dSizesAsOutsideOne() {
        // The camera's turn is part of the shape's transform; its foreshortening is not a group scale, so a 1:1
        // group must not change extrusion depths, contours or bevels under a turned camera.
        let deck = withBevel(705, #"<a:scene3d><a:camera prst="isometricOffAxis1Right"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d extrusionH="254000" contourW="38100"><a:bevelT w="254000" h="254000"/></a:sp3d>"#)
        let alone = renderDeck(deck)
        let group = shapeOf(10, Xfrm(0, 0, 960, 540), .group(children: deck.slides[0].shapes, child: Xfrm(0, 0, 960, 540)))
        let d = differingValues(alone, renderDeck(deckOf([group])))
        #expect(d < 200, "\(d) values differ between the shapes alone and in a 1:1 group")
    }

    // MARK: tests_wild.rs

    /// A shape at `x` filled with `fill`, no line, with 3-D XML `raw` (and the bevel name `bevel`).
    func lit(_ id: UInt32, _ x: Xfrm, _ fill: Rgba, _ raw: String, bevel: String? = nil) -> Shape {
        var s = shapeOf(id, x)
        s.fill = .solid(.rgb(fill))
        var none = Line.default
        none.fill = .none_
        s.line = none
        s.effects = Effects(bevel: bevel, raw3d: raw)
        return s
    }

    @Test func aBevelledShapeIsLitFromTheUpperLeft() {
        let base = Rgba.rgb(91, 155, 213)
        func bevelled(_ raw: String) -> RenderImage { renderDeck(deckOf([lit(26, Xfrm(100, 100, 130, 130), base, raw, bevel: "circle")])) }
        var img = bevelled(#"<a:scene3d><a:camera prst="orthographicFront"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d><a:bevelT w="152400" h="76200"/></a:sp3d>"#)
        // PowerPoint: face (99, 166, 226); top of the band saturates, its bottom and right darken.
        let face = pixelAt(img, 165, 165)
        #expect(nearRGB(face, .rgb(99, 166, 226), 8), "face \(face)")
        let (top, bottom, right) = (pixelAt(img, 165, 104)[2], pixelAt(img, 165, 226)[2], pixelAt(img, 226, 165)[2])
        #expect(top > face[2] && bottom < face[2] && right < face[2], "top \(top) bottom \(bottom) right \(right) face \(face[2])")
        // Without a 3-D scene PowerPoint draws it flat.
        img = bevelled(#"<a:sp3d><a:bevelT w="152400" h="76200"/></a:sp3d>"#)
        #expect(nearRGB(pixelAt(img, 165, 104), base, 2) && nearRGB(pixelAt(img, 165, 165), base, 2))
    }

    @Test func a3dShapesFaceIsLitEvenWithoutABevel() {
        let base = Rgba.rgb(237, 125, 49)
        func shape(_ raw: String) -> RenderImage { renderDeck(deckOf([lit(31, Xfrm(100, 100, 150, 100), base, raw)])) }
        // PowerPoint shows this face as about (251, 135, 56).
        var img = shape(#"<a:scene3d><a:camera prst="orthographicFront"/><a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d/>"#)
        #expect(nearRGB(pixelAt(img, 175, 150), .rgb(248, 136, 60), 8), "\(pixelAt(img, 175, 150))")
        // No shape properties in 3-D: flat.
        img = shape(#"<a:scene3d><a:camera prst="orthographicFront"/><a:lightRig rig="threePt" dir="t"/></a:scene3d>"#)
        #expect(nearRGB(pixelAt(img, 175, 150), base, 1))
    }

    @Test func a3dPicturesBorderStaysCentredOnItsEdge() throws {
        var p = Presentation.default
        let added = p.addMedia("image1.png", "image/png", png(8, 8, Array([0, 0, 255, 255].joined(count: 64))))
        let media = try #require(added)
        var sh = shapeOf(15, Xfrm(100, 100, 200, 100), .picture(fill: PictureFill(media: media)))
        sh.line = .solid(.rgb(solidRed), 8)
        sh.effects = Effects(bevel: "circle", raw3d: #"<a:scene3d><a:camera prst="orthographicFront"/></a:scene3d><a:sp3d><a:bevelT/></a:sp3d>"#)
        p.slides[0].shapes = [sh]
        let img = renderDeck(p)
        #expect(nearRGB(pixelAt(img, 102, 150), solidRed, 30), "covers the picture's edge \(pixelAt(img, 102, 150))")
        #expect(nearRGB(pixelAt(img, 94, 150), .white, 10), "reaches half the width out \(pixelAt(img, 94, 150))")
    }
}

private extension Array where Element == UInt8 {
    func joined(count n: Int) -> [UInt8] { (0 ..< n).flatMap { _ in self } }
}
