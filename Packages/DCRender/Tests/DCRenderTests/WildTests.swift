// Ported from deckcraft crates/render/src/tests_wild.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): shape, line, fill and effect cases checked against PowerPoint's own exports of
// synthetic "wild" slides, rendered as whole slides. The tests of that file that StrokeTests, PaintTests,
// ImagesTests, PatternTests, TableTests and ThreeDTests already port are not repeated here. Pixel
// positions and tolerances are the Rust ones unless a comment says otherwise.
import DCColor
import DCCore
import DCGeometry
import DCModel
@testable import DCRender
import Testing

/// Slide 0 of the default deck holding `shapes`, at 1 px/pt (tests_wild.rs `render`).
private func render(_ shapes: [Shape]) -> RenderImage { renderDeck(deckOf(shapes)) }

/// A solid fill of `c` (tests_wild.rs `solid`).
private func solid(_ c: Rgba) -> Fill { .solid(.rgb(c)) }

/// A horizontal 200 pt `line` preset from (100, 100) with a medium `kind` tail (tests_wild.rs `arrow_line`).
private func arrowLine(_ kind: String, _ width: Double, _ c: Rgba) -> Shape {
    shapeWith(12, Xfrm(100, 100, 200, 0)) {
        $0.geom = .preset("line")
        $0.line = Line(fill: solid(c), width: width, tail: LineEnd(kind: kind, w: "med", len: "med"))
    }
}

/// A black shadow with no blur or offset, scaled by `sx`, `sy`, skewed by `kx` about `align`
/// (tests_wild.rs `shadow`).
private func shadow(_ sx: Double, _ sy: Double, _ kx: Double, _ align: String) -> Shadow {
    Shadow(color: .rgb(.black), blur: 0, dist: 0, dir: 0, inner: false, sx: sx, sy: sy, kx: kx, ky: 0, align: align, rotateWithShape: false)
}

/// A 100×100 shape at (100, 100) with `fill`, `line` and `effects` (tests_wild.rs `with_effects`).
private func withEffects(_ fill: Fill?, _ line: Line?, _ effects: Effects) -> Shape {
    shapeWith(14, Xfrm(100, 100, 100, 100)) {
        $0.fill = fill
        $0.line = line
        $0.effects = effects
    }
}

/// An outer shadow 20 pt to the right (tests_wild.rs `offset_shadow`).
private func offsetShadow() -> Effects {
    var sh = shadow(1, 1, 0, "b")
    sh.dist = 20
    sh.dir = 0
    return Effects(outerShadow: sh)
}

/// The default deck with a 200×100 picture at (100, 100) of an 8×8 blue PNG, outlined by `line`
/// (tests_wild.rs `picture_deck`).
private func bluePictureDeck(_ line: Line?) -> Presentation? {
    pictureDeck(15, Xfrm(100, 100, 200, 100), "image1.png", "image/png", solidPNG(8, 8, [0, 0, 255])) { $0.line = line }
}

/// A 400×200 box at (100, 100) with a white-to-black circle gradient from `focus` (tests_wild.rs `radial`).
private func radial(_ focus: [Double], tile: [Double] = [0, 0, 0, 0]) -> Shape {
    shapeWith(13, Xfrm(100, 100, 400, 200)) {
        let stops = [GradientStop(pos: 0, color: .rgb(.white)), GradientStop(pos: 1, color: .rgb(.black))]
        $0.fill = .gradient(Gradient(stops: stops, shape: .path(path: "circle", focus: focus), rotateWithShape: true, tile: tile))
        $0.line = noLine()
    }
}

@Suite struct WildTests {
    // tests_wild.rs: custom_geometry_sub_paths_cut_holes_whichever_way_they_wind
    @Test func customGeometrySubPathsCutHolesWhicheverWayTheyWind() {
        // Outer square clockwise, inner square also clockwise: PowerPoint still shows a hole.
        let d = "M 0 0 L 100 0 L 100 100 L 0 100 Z M 25 25 L 75 25 L 75 75 L 25 75 Z"
        var path = CustomPath.default
        (path.w, path.h, path.d) = (100, 100, d)
        let img = render([shapeWith(10, Xfrm(100, 100, 200, 200)) {
            $0.geom = .custom(paths: [path])
            $0.fill = solid(red)
            $0.line = noLine()
        }])
        #expect(nearRGB(pixelAt(img, 120, 120), red, 2), "outer ring filled")
        #expect(nearRGB(pixelAt(img, 200, 200), .white, 2), "inner square is a hole: \(pixelAt(img, 200, 200))")
    }

    // tests_wild.rs: a_see_through_line_and_its_arrowhead_are_one_shape
    @Test func aSeeThroughLineAndItsArrowheadAreOneShape() {
        let img = render([arrowLine("triangle", 10, .rgba(255, 0, 0, 128))])
        let lineOnly = pixelAt(img, 200, 100)
        let headOverLine = pixelAt(img, 285, 100)
        #expect(nearRGB(lineOnly, .rgb(255, 127, 127), 6), "\(lineOnly)")
        #expect(nearRGB(headOverLine, .rgb(lineOnly[0], lineOnly[1], lineOnly[2]), 3), "no darker overlap: \(headOverLine)")
    }

    // tests_wild.rs: a_perspective_shadow_lies_along_the_edge_its_alignment_names
    // (StrokeTests.aPerspectiveShadowPivotsOnItsAlignment checks the shadow's transform; this draws it.)
    @Test func aPerspectiveShadowLiesAlongTheEdgeItsAlignmentNames() {
        // Half height, skewed 45° so its top leans right, anchored at the bottom middle: the shadow's
        // bottom edge is the shape's (y = 200) and its top (y = 150) is 50 pt to the right.
        var img = render([withEffects(solid(red), noLine(), Effects(outerShadow: shadow(1, 0.5, -45, "b")))])
        #expect(nearRGB(pixelAt(img, 210, 175), .black, 30), "\(pixelAt(img, 210, 175))")
        #expect(nearRGB(pixelAt(img, 240, 155), .black, 30), "\(pixelAt(img, 240, 155))")
        #expect(nearRGB(pixelAt(img, 240, 180), .white, 10), "\(pixelAt(img, 240, 180))")
        #expect(nearRGB(pixelAt(img, 205, 140), .white, 10), "nothing above the half height \(pixelAt(img, 205, 140))")
        // Anchored bottom-right and half as big again: it grows up and to the left only.
        img = render([withEffects(solid(red), noLine(), Effects(outerShadow: shadow(1.5, 1.5, 0, "br")))])
        #expect(nearRGB(pixelAt(img, 70, 70), .black, 30) && nearRGB(pixelAt(img, 210, 210), .white, 10))
    }

    // tests_wild.rs: shadows_are_cast_by_what_is_drawn
    @Test func shadowsAreCastByWhatIsDrawn() {
        // An outline-only square: its shadow (20 pt to the right) is a frame, not a solid square.
        var img = render([withEffects(.none_, .solid(.rgb(red), 4), offsetShadow())])
        #expect(nearRGB(pixelAt(img, 220, 150), .black, 30), "the frame's shadow \(pixelAt(img, 220, 150))")
        #expect(nearRGB(pixelAt(img, 160, 150), .white, 10), "no shadow inside the frame \(pixelAt(img, 160, 150))")
        // A half see-through fill casts a half see-through shadow.
        img = render([withEffects(solid(.rgba(255, 0, 0, 128)), noLine(), offsetShadow())])
        let px = pixelAt(img, 210, 150)
        #expect(nearRGB(px, .rgb(127, 127, 127), 8), "half shadow \(px)")
        // A line casts a shadow too.
        var ln = arrowLine("none", 6, red)
        ln.effects = offsetShadow()
        img = render([ln])
        #expect(nearRGB(pixelAt(img, 310, 100), .black, 30), "line shadow \(pixelAt(img, 310, 100))")
    }

    // tests_wild.rs: a_pictures_border_lies_outside_the_picture
    // (StrokeTests.pictureBordersAreDrawnOutsideUnlessIn3D checks the outside line; this draws it.)
    @Test func aPicturesBorderLiesOutsideThePicture() throws {
        var img = renderDeck(try #require(bluePictureDeck(.solid(.rgb(red), 8))))
        // The whole picture shows, up to its edge; the 8 pt border is all outside it.
        #expect(nearRGB(pixelAt(img, 101, 150), blue, 30), "picture at its edge \(pixelAt(img, 101, 150))")
        #expect(nearRGB(pixelAt(img, 98, 150), red, 30) && nearRGB(pixelAt(img, 93, 150), red, 30), "\(pixelAt(img, 93, 150))")
        #expect(nearRGB(pixelAt(img, 90, 150), .white, 10), "border no wider than the line \(pixelAt(img, 90, 150))")
        // A dashed border keeps its dash lengths (a dash is 4 widths: 32 pt), drawn from the corner.
        var line = Line.solid(.rgb(red), 8)
        line.dash = .preset(name: "dash")
        img = renderDeck(try #require(bluePictureDeck(line)))
        #expect(nearRGB(pixelAt(img, 120, 96), red, 30) && nearRGB(pixelAt(img, 140, 96), .white, 10), "\(pixelAt(img, 140, 96))")
    }

    // tests_wild.rs: children_filled_with_the_group_fill_show_one_fill_across_the_group
    @Test func childrenFilledWithTheGroupFillShowOneFillAcrossTheGroup() {
        let stops = [GradientStop(pos: 0, color: .rgb(red)), GradientStop(pos: 1, color: .rgb(blue))]
        let grad = Fill.gradient(Gradient(stops: stops, shape: .linear(angle: 0, scaled: false), rotateWithShape: true, tile: [0, 0, 0, 0]))
        func child(_ id: UInt32, _ x: Double) -> Shape {
            shapeWith(id, Xfrm(x, 0, 90, 100)) {
                $0.fill = .group
                $0.line = noLine()
            }
        }
        var g = shapeOf(16, Xfrm(100, 100, 200, 100), .group(children: [child(17, 0), child(18, 110)], child: Xfrm(0, 0, 200, 100)))
        g.fill = grad
        let img = render([g])
        let (l, r) = (pixelAt(img, 105, 150), pixelAt(img, 295, 150))
        #expect(l[0] > 200 && l[2] < 60, "left end of the group's gradient \(l)")
        #expect(r[2] > 200 && r[0] < 60, "right end \(r)")
        #expect(nearRGB(pixelAt(img, 200, 150), .white, 5), "the gap between the children stays empty")
    }

    // tests_wild.rs: open_freeforms_take_arrowheads_even_when_filled
    @Test func openFreeformsTakeArrowheadsEvenWhenFilled() {
        // An open custom path with a fill and a tail arrow: PowerPoint draws the arrow.
        var path = CustomPath.default
        (path.w, path.h, path.d) = (100, 100, "M 0 100 L 50 0 L 100 100")
        let img = render([shapeWith(19, Xfrm(100, 100, 200, 100)) {
            $0.geom = .custom(paths: [path])
            $0.fill = solid(.rgb(0, 200, 0))
            $0.line = Line(fill: solid(red), width: 4, tail: LineEnd(kind: "triangle", w: "med", len: "med"))
        }])
        // The line ends at (300, 200) heading down-right at 45°; the 12 pt head's base corner reaches
        // (295.7, 187.3), 3.5 pt off the line's axis: outside the 4 pt line and outside the fill.
        #expect(nearRGB(pixelAt(img, 294, 189), red, 60), "arrowhead drawn \(pixelAt(img, 294, 189))")
    }

    // tests_wild.rs: a_corner_radial_centres_on_the_corner_through_its_tile
    @Test func aCornerRadialCentresOnTheCornerThroughItsTile() {
        // fillToRect on the top-left corner, tileRect reaching a whole box up and left: the circle is
        // centred on the corner and reaches the far corner (as PowerPoint's "from corner" presets).
        let img = render([radial([0, 0, 1, 1], tile: [-1, -1, 0, 0])])
        #expect(pixelAt(img, 102, 102)[0] > 240, "white at the corner \(pixelAt(img, 102, 102))")
        let (topRight, bottomLeft) = (pixelAt(img, 498, 101)[0], pixelAt(img, 101, 298)[0])
        #expect(topRight < bottomLeft, "farther is darker \(topRight) \(bottomLeft)")
        #expect(bottomLeft > 120, "the near edge stays light \(bottomLeft)")
        #expect(pixelAt(img, 497, 297)[0] < 40, "dark at the far corner \(pixelAt(img, 497, 297))")
    }

    // tests_wild.rs: a_linear_gradient_spans_its_tile_rect
    @Test func aLinearGradientSpansItsTileRect() {
        // Tile rect the left half of the box: the ramp ends half way and stays black after.
        let stops = [GradientStop(pos: 0, color: .rgb(.white)), GradientStop(pos: 1, color: .rgb(.black))]
        let img = render([shapeWith(20, Xfrm(100, 100, 400, 100)) {
            $0.fill = .gradient(Gradient(stops: stops, shape: .linear(angle: 0, scaled: false), rotateWithShape: true, tile: [0, 0, 0.5, 0]))
            $0.line = noLine()
        }])
        #expect(pixelAt(img, 102, 150)[0] > 240)
        #expect(pixelAt(img, 305, 150)[0] < 15 && pixelAt(img, 495, 150)[0] < 15, "\(pixelAt(img, 305, 150))")
    }

    // tests_wild.rs: a_groups_shadow_is_cast_by_its_children
    @Test func aGroupsShadowIsCastByItsChildren() {
        func child(_ id: UInt32, _ x: Double) -> Shape {
            shapeWith(id, Xfrm(x, 0, 80, 100)) {
                $0.fill = solid(red)
                $0.line = noLine()
            }
        }
        var g = shapeOf(22, Xfrm(100, 100, 200, 100), .group(children: [child(23, 0), child(24, 120)], child: Xfrm(0, 0, 200, 100)))
        g.effects = offsetShadow()
        let img = render([g])
        // 20 pt to the right of each child: the shadow; in the gap only the left child's shadow shows.
        #expect(nearRGB(pixelAt(img, 190, 150), .black, 30), "\(pixelAt(img, 190, 150))")
        #expect(nearRGB(pixelAt(img, 210, 150), .white, 10), "\(pixelAt(img, 210, 150))")
        #expect(nearRGB(pixelAt(img, 310, 150), .black, 30), "\(pixelAt(img, 310, 150))")
        #expect(nearRGB(pixelAt(img, 150, 150), red, 10), "children drawn over it")
    }

    // tests_wild.rs: a_large_pictures_shadow_is_whole
    @Test func aLargePicturesShadowIsWhole() throws {
        // A 400 px picture shown at 240 pt: its shadow was recoloured in the picture's pixel space and
        // covered only part of it.
        var counts: [Int] = []
        for side in [8, 400] {
            var fx = offsetShadow()
            fx.outerShadow?.blur = 8
            var x = Xfrm(360, 300, 240, 160)
            x.rot = 20
            let made = pictureDeck(15, x, "image1.png", "image/png", solidPNG(side, side * 3 / 4, [0, 0, 255])) { $0.effects = fx }
            let img = renderDeck(try #require(made))
            counts.append(countPixels(img) { $0[0] < 200 && $0[2] < 200 })
        }
        #expect(counts[1] > 3000 && abs(counts[0] - counts[1]) < 300, "\(counts)")
    }

    // tests_wild.rs: a_gradient_not_rotating_with_its_shape_keeps_to_the_slide
    // (PaintTests.gradientsKeepToTheSlideWhenNotRotatingWithTheShape checks a flipped fill on a canvas;
    // this turns the shape on a slide.)
    @Test func aGradientNotRotatingWithItsShapeKeepsToTheSlide() {
        for rotateWithShape in [true, false] {
            let stops = [GradientStop(pos: 0, color: .rgb(red)), GradientStop(pos: 1, color: .rgb(blue))]
            // 200 × 100 turned a quarter: it covers 150..250 across and 50..250 down.
            var x = Xfrm(100, 100, 200, 100)
            x.rot = 90
            let img = render([shapeWith(28, x) {
                $0.fill = .gradient(Gradient(stops: stops, shape: .linear(angle: 0, scaled: false), rotateWithShape: rotateWithShape, tile: [0, 0, 0, 0]))
                $0.line = noLine()
            }])
            let (left, top) = (pixelAt(img, 152, 150), pixelAt(img, 200, 52))
            if rotateWithShape {
                #expect(top[0] > 200 && top[2] < 60, "turned with the shape: red at the top \(top)")
            } else {
                #expect(left[0] > 200 && left[2] < 60, "upright: red at the left \(left)")
                #expect(pixelAt(img, 248, 150)[2] > 200, "blue at the right")
            }
        }
    }

    // tests_wild.rs: stars_and_right_arrows_have_sharp_corners_by_default
    @Test func starsAndRightArrowsHaveSharpCornersByDefault() {
        func shape(_ name: String, _ join: LineJoin?) -> Shape {
            shapeWith(29, Xfrm(100, 100, 100, 100)) {
                $0.geom = .preset(name)
                $0.fill = solid(.white)
                var l = Line.solid(.rgb(red), 10)
                l.join = join
                $0.line = l
            }
        }
        // A star5's top point mitred reaches about 16 pt above the box; rounded only 5.
        var img = render([shape("star5", nil)])
        #expect(nearRGB(pixelAt(img, 150, 90), red, 40), "mitred point \(pixelAt(img, 150, 90))")
        img = render([shape("star5", .round)])
        #expect(nearRGB(pixelAt(img, 150, 90), .white, 10), "an explicit round join stays round")
        // A rectangle keeps PowerPoint's round default: its corner is cut round.
        img = render([shape("rect", nil)])
        #expect(nearRGB(pixelAt(img, 95, 95), .white, 30), "\(pixelAt(img, 95, 95))")
        #expect(Preset.mitredByDefault("rightArrow") && !Preset.mitredByDefault("leftArrow"))
    }

    // tests_wild.rs: an_upright_picture_fill_stays_upright_in_a_turned_shape
    @Test func anUprightPictureFillStaysUprightInATurnedShape() throws {
        for upright in [false, true] {
            var p = Presentation.default
            let added = p.addMedia("t.png", "image/png", halfRedHalfBlue())
            let media = try #require(added)
            // Half red (left) half blue picture in a 200 × 200 square turned a quarter (and so covering the
            // same square).
            var x = Xfrm(100, 100, 200, 200)
            x.rot = 90
            p.slides[0].shapes = [shapeWith(30, x) {
                $0.fill = .picture(PictureFill(media: media, upright: upright))
                $0.line = noLine()
            }]
            let img = renderDeck(p)
            let (left, top) = (pixelAt(img, 110, 200), pixelAt(img, 200, 110))
            if upright {
                #expect(nearRGB(left, red, 30) && nearRGB(pixelAt(img, 290, 200), blue, 30), "upright: red left \(left)")
            } else {
                #expect(nearRGB(top, red, 30), "turned with the shape: red at the top \(top)")
            }
        }
    }

    // tests_wild.rs: a_picture_reflects_its_pixels
    @Test func aPictureReflectsItsPixels() throws {
        var p = try #require(bluePictureDeck(nil))
        p.slides[0].shapes[0].effects = Effects(reflection: Reflection(blur: 0, startAlpha: 1, endAlpha: 0, endPos: 0.5, dist: 0))
        let img = renderDeck(p)
        // The blue picture spans 100..200 down; just below it, its reflection tints the page blue.
        let below = pixelAt(img, 200, 204)
        #expect(below[2] > 200 && below[0] < 200, "\(below)")
        #expect(nearRGB(pixelAt(img, 200, 290), .white, 10), "faded out by half its height")
    }

    // tests_wild.rs: a_tiny_dash_on_a_huge_shape_draws_without_running_out_of_memory
    // (Its `limit_dash_count` half is StrokeTests.dashCountsAreLimited; this is the slide render.)
    @Test func aTinyDashOnAHugeShapeDrawsWithoutRunningOutOfMemory() {
        // Found by fuzzing the pptx round trip: a 1 EMU `custDash` on a 2147483647 EMU square asked the
        // stroker for hundreds of thousands of dashes and aborted on a 7.5 GB allocation.
        let sh = shapeWith(12, Xfrm(0, 0, 169_093, 169_093)) {
            $0.geom = .preset("rect")
            $0.line = Line(fill: solid(red), width: 0.0001, dash: .custom(pattern: [Pair(1.0, 1.0)]))
        }
        let img = renderSlide(deckOf([sh]), 0, renderOpts(0.25))
        #expect(img.width > 0)
    }
}
