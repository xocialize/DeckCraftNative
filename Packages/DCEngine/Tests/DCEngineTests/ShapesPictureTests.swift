// DCEngineTests — Picture Format (styles, recolour, transparent colour, artistic effects) and Merge Shapes.
// Ports the picture tests of deckcraft crates/engine/src/tests.rs and the tests of cmd/merge.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Merge Shapes runs on CoreGraphics' path
// booleans, so its tests measure areas, as deckcraft's do.
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import Foundation
import Testing

/// deckcraft's 1 × 1 PNG of the picture style and recolour tests.
private let onePixelPNG: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF,
    0xC0, 0xF0, 0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
    0x82,
]

private func insertPicture(_ s: Session, _ png: [UInt8], _ name: String, _ rect: [Double]? = nil) -> ShapeId {
    var o = JSONObject([.init(key: "data", value: .string(Cmd.base64Encode(png))), .init(key: "name", value: .string(name))])
    if let rect { o.set("rect", .array(rect.map { .double($0) })) }
    return answerId(s.run("insert.picture", JSON.object(o).display))
}

/// Shape `id`, searched into groups.
private func shapeNamed(_ s: Session, _ id: ShapeId) -> Shape? { s.st.shape(id) }

private func pictureFill(_ s: Session, _ id: ShapeId) -> PictureFill? {
    if case .picture(let fill)? = shapeNamed(s, id)?.kind { return fill }
    return nil
}

/// A picture of `n` one-pixel columns whose red channel is 20 × column, inserted at `rect`.
private func rampPicture(_ s: Session, _ n: Int, _ rect: [Double]) -> ShapeId {
    insertPicture(s, pngOf(n, 1) { x, _ in [UInt8(20 * x), 0, 0, 255] }, "r.png", rect)
}

@Suite("Shapes: pictures")
struct ShapesPictureTests {
    // tests.rs picture_styles_replace_each_other_in_one_step
    @Test(.enabled(if: ported("insert.picture")))
    func pictureStylesReplaceEachOtherInOneStep() throws {
        let s = session()
        let id = insertPicture(s, onePixelPNG, "a.png", [100, 100, 200, 150])
        #expect(s.run("picture.styles").asArray?.count == 24)
        s.run("picture.style", #"{"ids": [\#(id.rawValue)], "style": "reflectedRoundedRectangle"}"#)
        var p = try #require(shapeNamed(s, id))
        #expect(p.geom.presetName == "roundRect")
        #expect(p.effects?.reflection != nil)
        // The next style replaces the whole look: no leftover reflection.
        s.run("picture.style", #"{"ids": [\#(id.rawValue)], "style": "simpleFrameWhite"}"#)
        p = try #require(shapeNamed(s, id))
        #expect(p.geom.presetName == "rect")
        #expect(p.effects?.reflection == nil && p.effects?.outerShadow != nil)
        #expect(p.line?.width == 7)
        s.run("picture.style", #"{"ids": [\#(id.rawValue)], "style": "softEdgeOval"}"#)
        p = try #require(shapeNamed(s, id))
        #expect(p.geom.presetName == "ellipse")
        #expect(p.effects?.softEdge == 12)
        #expect(p.line?.fill == .none_)
        // Survives PPTX.
        let back = try PPTX.import(try PPTX.export(s.st.doc))
        let bp = try #require(back.slides.flatMap(\.shapes).first { if case .picture = $0.kind { true } else { false } })
        #expect(bp.geom.presetName == "ellipse")
        #expect(bp.effects?.softEdge == 12)
        // One undo step per style; none clears; unknown is refused.
        s.run("edit.undo")
        #expect(shapeNamed(s, id)?.geom.presetName == "rect")
        s.run("picture.style", #"{"ids": [\#(id.rawValue)], "style": "none"}"#)
        #expect(shapeNamed(s, id)?.effects == nil && shapeNamed(s, id)?.line == nil)
        #expect(s.fails("picture.style", #"{"ids": [\#(id.rawValue)], "style": "sparkly"}"#))
    }

    // tests.rs picture_recolor_and_transparent_color
    @Test(.enabled(if: ported("insert.picture")))
    func pictureRecolorAndTransparentColor() throws {
        let s = session()
        let id = insertPicture(s, onePixelPNG, "a.png")
        func adj() -> PictureAdjust? { pictureFill(s, id)?.adjust }
        #expect(s.run("picture.recolors").asArray?.count == 21)
        s.run("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "bw50"}"#)
        #expect(adj()?.bilevel == 0.5)
        // A new preset replaces the old one.
        s.run("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "accent2Light"}"#)
        #expect(adj()?.bilevel == nil)
        #expect(adj()?.duotone?.a == ColorRef.scheme(.accent2))
        s.run("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "washout"}"#)
        #expect(adj()?.duotone == nil && adj()?.brightness == 0.7 && adj()?.contrast == -0.7)
        s.run("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "grayscale"}"#)
        #expect(adj()?.grayscale == true && adj()?.brightness == 0, "washout undone by the next preset")
        #expect(s.fails("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "plaid"}"#))
        s.run("picture.transparentColor", ##"{"ids": [\##(id.rawValue)], "color": "#FFFFFF"}"##)
        #expect(adj()?.clearColor == .rgb(255, 255, 255))
        // Both survive PPTX.
        let back = try PPTX.import(try PPTX.export(s.st.doc))
        let ba = try #require(back.slides.flatMap(\.shapes).compactMap { sh -> PictureAdjust? in
            if case .picture(let fill) = sh.kind { return fill.adjust }
            return nil
        }.first)
        #expect(ba.grayscale)
        #expect(ba.clearColor == .rgb(255, 255, 255))
        s.run("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "none": true}"#)
        #expect(adj()?.clearColor == nil)
        s.run("picture.recolor", #"{"ids": [\#(id.rawValue)], "preset": "none"}"#)
        #expect(adj() == PictureAdjust.default)
    }

    // tests.rs transparent_color_at_a_point_takes_the_pictures_own_pixel_there
    @Test(.enabled(if: ported("insert.picture")))
    func transparentColorAtAPointTakesThePicturesOwnPixelThere() {
        // Red on the left half, blue on the right.
        let s = session()
        let id = insertPicture(s, pngOf(4, 2) { x, _ in x < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }, "a.png", [100, 100, 400, 200])
        func clear() -> Rgba? { pictureFill(s, id)?.adjust.clearColor }
        let (red, blue) = (Rgba.rgb(255, 0, 0), Rgba.rgb(0, 0, 255))
        s.run("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [450, 200]}"#)
        #expect(clear() == blue)
        // The picture's own colour, not the one drawn after a correction brightened it.
        s.run("picture.adjust", #"{"ids": [\#(id.rawValue)], "brightness": 0.4}"#)
        s.run("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [150, 200]}"#)
        #expect(clear() == red)
        // Flipped, the blue half is drawn on the left.
        s.run("shape.flip", #"{"ids": [\#(id.rawValue)], "axis": "horizontal"}"#)
        s.run("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [150, 200]}"#)
        #expect(clear() == blue)
        // Beside the picture there is no colour to take, and nothing changes.
        #expect(s.fails("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [50, 50]}"#))
        #expect(clear() == blue)
        // A spot that is already transparent hides a colour (black here, as in most PNGs): taking it would
        // clear the black drawn elsewhere in the picture.
        let logo = insertPicture(s, pngOf(4, 2) { x, _ in x < 2 ? [0, 0, 0, 0] : [0, 0, 0, 255] }, "b.png", [100, 400, 400, 200])
        #expect(s.fails("picture.transparentColor", #"{"ids": [\#(logo.rawValue)], "at": [150, 500]}"#))
        s.run("picture.transparentColor", #"{"ids": [\#(logo.rawValue)], "at": [450, 500]}"#)
    }

    // tests.rs transparent_color_at_a_point_follows_the_pictures_3d_camera
    @Test(.enabled(if: ported("insert.picture")))
    func transparentColorAtAPointFollowsThePictures3DCamera() {
        let s = session()
        let id = rampPicture(s, 10, [100, 100, 200, 100])
        // Turned 60 degrees about the vertical axis the picture is drawn about half as wide, centred where it
        // was: 149..251 instead of 100..300.
        s.run("shape.effects", #"{"ids": [\#(id.rawValue)], "threeD": {"camera": "orthographicFront", "rotX": 60}}"#)
        // 175 is a quarter of the way across the drawn picture: column 2, not column 3 (the 75/200 of the
        // unturned box).
        s.run("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [175, 150]}"#)
        #expect(pictureFill(s, id)?.adjust.clearColor == .rgb(40, 0, 0))
        // Inside the unturned box but outside the drawn picture: nothing is under the pointer.
        #expect(s.fails("picture.transparentColor", #"{"ids": [\#(id.rawValue)], "at": [120, 150]}"#))
    }

    // tests.rs transparent_color_at_a_point_finds_a_grouped_picture_without_its_own_box
    @Test(.enabled(if: ported("insert.picture", "shape.insert", "arrange.group")))
    func transparentColorAtAPointFindsAGroupedPictureWithoutItsOwnBox() throws {
        let s = session()
        let pic = rampPicture(s, 10, [100, 100, 200, 100])
        let other = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [400, 300, 50, 50]}"#))
        s.run("edit.select", #"{"ids": [\#(pic.rawValue), \#(other.rawValue)]}"#)
        s.run("arrange.group")
        // A grouped picture that keeps no box of its own is drawn where the default box puts it.
        let sz = s.st.doc.slideSize
        try s.edit { doc, sel in
            mutateShapes(&doc, sel) { list in walkMut(&list) { sh in if sh.id == pic { sh.xfrm = nil } } }
        }
        // Left tenth of the default box (10%, 10%, 80% x 20% of the slide): column 0.
        s.run("picture.transparentColor", #"{"ids": [\#(pic.rawValue)], "at": [\#(sz.width * 0.1 + 1), \#(sz.height * 0.2)]}"#)
        #expect(pictureFill(s, pic)?.adjust.clearColor == .rgb(0, 0, 0))
        s.run("picture.transparentColor", #"{"ids": [\#(pic.rawValue)], "at": [\#(sz.width * 0.9 - 1), \#(sz.height * 0.2)]}"#)
        #expect(pictureFill(s, pic)?.adjust.clearColor == .rgb(180, 0, 0))
    }

    // tests.rs transparent_color_at_a_point_takes_the_topmost_selected_picture
    @Test(.enabled(if: ported("insert.picture")))
    func transparentColorAtAPointTakesTheTopmostSelectedPicture() {
        let s = session()
        // `under` is inserted first (drawn below), `over` after it (drawn on top); they overlap in x 150..300.
        let under = rampPicture(s, 10, [100, 100, 200, 100])
        let over = rampPicture(s, 10, [150, 100, 200, 100])
        // Selected bottom first: selection order is the opposite of the stacking order.
        s.run("edit.select", #"{"ids": [\#(under.rawValue), \#(over.rawValue)]}"#)
        // x = 250 is column 7 of `under` (140) and column 5 of `over` (100): the click is on `over`.
        s.run("picture.transparentColor", #"{"at": [250, 150]}"#)
        #expect(pictureFill(s, over)?.adjust.clearColor == .rgb(100, 0, 0))
        #expect(pictureFill(s, under)?.adjust.clearColor == nil)
        // Where `over` is not, the picture below is still found.
        s.run("picture.transparentColor", #"{"at": [120, 150]}"#)
        #expect(pictureFill(s, under)?.adjust.clearColor == .rgb(20, 0, 0))
    }

    // tests.rs artistic_effects_apply_change_remove_and_round_trip
    @Test(.enabled(if: ported("insert.picture", "file.openBytes")))
    func artisticEffectsApplyChangeRemoveAndRoundTrip() throws {
        let png = pngOf(40, 30) { x, y in x < 20 ? [200, 30, 30, 255] : [20, 20, 220, y < 5 ? 0 : 255] }
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let id = insertPicture(s, png, "a.png")
        let original = try #require(pictureFill(s, id)?.media)
        #expect(s.fails("picture.artisticEffect", #"{"effect": "artisticBogus"}"#))
        // Every effect draws something of the same size and keeps transparency.
        for (e, _) in ArtisticCommands.effects {
            s.run("picture.artisticEffect", #"{"effect": "\#(e)"}"#)
            let f = try #require(pictureFill(s, id))
            #expect(f.artistic == Artistic(effect: e, original: original))
            #expect(f.media != original)
            let out = try #require(s.st.doc.media(f.media).flatMap { Images.decode($0.data) })
            #expect(out.width == 40 && out.height == 30)
            #expect(out.pixels[(1 * 40 + 30) * 4 + 3] == 0, "\(e)")
        }
        // A pencil sketch is grey.
        s.run("picture.artisticEffect", #"{"effect": "artisticPencilGrayscale"}"#)
        let sketch = try #require(pictureFill(s, id).flatMap { s.st.doc.media($0.media) }.flatMap { Images.decode($0.data) })
        #expect(stride(from: 0, to: sketch.pixels.count, by: 4).allSatisfy { sketch.pixels[$0] == sketch.pixels[$0 + 1] && sketch.pixels[$0 + 1] == sketch.pixels[$0 + 2] })
        // Saved and reopened, the effect and the original are both there.
        let bytes = try FileCommands.saveBytes(s.st.doc, "pptx")
        let t = Session()
        _ = try t.execute("file.openBytes", ["name": "a.pptx", "data": .string(Cmd.base64Encode(bytes))])
        let back = try #require(try t.doc().doc.slides.flatMap(\.shapes).compactMap { sh -> PictureFill? in
            if case .picture(let fill) = sh.kind { return fill }
            return nil
        }.first)
        let art = try #require(back.artistic)
        #expect(art.effect == "artisticPencilGrayscale")
        #expect(try t.doc().doc.media(art.original)?.data == png)
        // None (and Reset Picture) puts the original back.
        s.run("picture.artisticEffect", #"{"effect": "none"}"#)
        #expect(pictureFill(s, id)?.media == original && pictureFill(s, id)?.artistic == nil)
        s.run("picture.artisticEffect", #"{"effect": "artisticBlur"}"#)
        s.run("picture.reset")
        #expect(pictureFill(s, id)?.media == original && pictureFill(s, id)?.artistic == nil)
    }

    @Test("The blur is the image crate's: kernel sizes and weights")
    func theBlurIsTheImageCrates() {
        // `kernel_size_from_sigma`: odd, at least 3.
        #expect(ArtisticCommands.kernelSize(0.5) == 3)
        #expect(ArtisticCommands.kernelSize(1) == 5)
        #expect(ArtisticCommands.kernelSize(6) == 37)
        #expect(ArtisticCommands.kernelSize(9) == 57)
        let k = ArtisticCommands.gaussianKernel(7, 1.4)
        #expect(Swift.abs(k.reduce(0, +) - 1) < 1e-6)
        #expect(k[0] == k[6] && k[1] == k[5] && k[3] > k[2])
        // A flat picture stays flat; a 1 × 1 picture is itself.
        let flat = ArtisticCommands.Pixels(width: 9, height: 7, channels: 4, data: Array(repeating: 77, count: 9 * 7 * 4))
        #expect(ArtisticCommands.blur(flat, 3).data == flat.data)
        let one = ArtisticCommands.Pixels(width: 1, height: 1, channels: 1, data: [200])
        #expect(ArtisticCommands.blur(one, 9).data == [200])
        // Pictures bigger than 3000 px are scaled down first, keeping their aspect.
        #expect(ArtisticCommands.resizeDimensions(6000, 4000, 3000, 3000) == (3000, 2000))
        let t = ArtisticCommands.thumbnail(ArtisticCommands.Pixels(width: 4, height: 2, channels: 1, data: [0, 10, 20, 30, 40, 50, 60, 70]), 2, 1)
        #expect(t.data == [25, 45])
    }
}

@Suite("Shapes: Merge Shapes")
struct ShapesMergeTests {
    private func square(_ x: Double, _ y: Double, _ s: Double) -> MergeCommands.Area {
        [[Point(x, y), Point(x + s, y), Point(x + s, y + s), Point(x, y + s)]]
    }

    // merge.rs tests::boolean_ops_have_the_expected_areas
    @Test func booleanOpsHaveTheExpectedAreas() {
        let areas = [square(0, 0, 10), square(5, 5, 10)]
        func size(_ op: String) -> Double { MergeCommands.mergeAreas(op, areas).map(MergeCommands.areaSize).reduce(0, +) }
        #expect(Swift.abs(size("union") - 175) < 1e-6)
        #expect(Swift.abs(size("intersect") - 25) < 1e-6)
        #expect(Swift.abs(size("subtract") - 75) < 1e-6)
        #expect(Swift.abs(size("combine") - 150) < 1e-6)
        let frags = MergeCommands.mergeAreas("fragment", areas)
        #expect(frags.count == 3)
        #expect(Swift.abs(frags.map(MergeCommands.areaSize).reduce(0, +) - 175) < 1e-6)
        // Disjoint intersect is empty.
        #expect(MergeCommands.mergeAreas("intersect", [square(0, 0, 1), square(5, 5, 1)]).isEmpty)
    }

    @Test("A hole stays a hole: contours are oriented against their outer one")
    func aHoleStaysAHole() {
        // A frame: a big square minus a small one inside it, then united with a square elsewhere.
        let frame = MergeCommands.mergeAreas("subtract", [square(0, 0, 10), square(3, 3, 4)])
        #expect(frame.count == 1)
        #expect(Swift.abs(MergeCommands.areaSize(frame[0]) - 84) < 1e-6)
        let united = MergeCommands.mergeAreas("union", [frame[0], square(20, 0, 2)])
        #expect(Swift.abs(MergeCommands.areaSize(united[0]) - 88) < 1e-6)
        // Its path text, filled non-zero as a custom path is, still has the hole: XOR with the hole's square
        // fills it back.
        let filled = MergeCommands.mergeAreas("combine", [united[0], square(3, 3, 4)])
        #expect(Swift.abs(MergeCommands.areaSize(filled[0]) - 104) < 1e-6)
        // Pieces that touch at a corner keep their own orientation.
        let touching = MergeCommands.mergeAreas("combine", [square(0, 0, 10), square(10, 10, 10)])
        #expect(Swift.abs(MergeCommands.areaSize(touching[0]) - 200) < 1e-6)
    }

    private func pictureAndText(_ s: Session) -> (ShapeId, ShapeId) {
        let png = pngOf(40, 20) { _, _ in [0, 128, 255, 255] }
        s.run("slide.new", #"{"layout": "blank"}"#)
        let pic = insertPicture(s, png, "a.png", [100, 100, 400, 200])
        let text = answerId(s.run("insert.textBox", #"{"rect": [150.0, 120.0, 300.0, 100.0], "text": "HI"}"#))
        return (pic, text)
    }

    // merge.rs tests::a_picture_intersected_with_text_fills_the_letters
    @Test(.enabled(if: ported("insert.picture", "insert.textBox")))
    func aPictureIntersectedWithTextFillsTheLetters() throws {
        // #653: the letters didn't change and the picture vanished (the text box counted as its whole box, and
        // the merge took the text's outline but kept the box's formatting).
        let s = session()
        let (pic, text) = pictureAndText(s)
        let textShape = try #require(s.st.shape(text))
        let letters = try #require(MergeCommands.lettersOf(s.st.doc, s.st.selection, textShape), "the text box is its letters").0
        let boxArea = 300.0 * 100.0
        #expect(MergeCommands.areaSize(letters) > 10 && MergeCommands.areaSize(letters) < boxArea * 0.5, "\(MergeCommands.areaSize(letters))")
        let ids = s.run("shape.merge", #"{"op": "intersect", "ids": [\#(pic.rawValue), \#(text.rawValue)]}"#).get("ids")?.asArray ?? []
        #expect(ids.count == 1)
        let out = try #require(ids.first?.asU32.flatMap { s.st.shape(ShapeId($0)) })
        guard case .picture(let fill) = out.kind else {
            Issue.record("the picture fills the letters: \(out.kind)")
            return
        }
        #expect(out.text == nil, "the letters are outlines now")
        // The result is the letters' outline, well inside the text box.
        let x = try #require(out.xfrm)
        #expect(x.x >= 150 && x.y >= 120 && x.x + x.w <= 450 && x.y + x.h <= 220, "\(x)")
        let merged = MergeCommands.areaOf(s.st.doc, s.st.selection, out)
        #expect(Swift.abs(MergeCommands.areaSize(merged) - MergeCommands.areaSize(letters)) < MergeCommands.areaSize(letters) * 0.05)
        // The picture stays where it was on the slide: cropped to the new box.
        let (l, t, r, b) = (fill.crop[0], fill.crop[1], fill.crop[2], fill.crop[3])
        let iw = x.w / (1 - l - r)
        let ih = x.h / (1 - t - b)
        #expect(Swift.abs(x.x - l * iw - 100) < 1e-6 && Swift.abs(iw - 400) < 1e-6, "\(fill.crop)")
        #expect(Swift.abs(x.y - t * ih - 100) < 1e-6 && Swift.abs(ih - 200) < 1e-6, "\(fill.crop)")
    }

    // merge.rs tests::text_merged_first_becomes_shapes_in_its_colour
    @Test(.enabled(if: ported("insert.picture", "insert.textBox")))
    func textMergedFirstBecomesShapesInItsColour() throws {
        let s = session()
        let (pic, text) = pictureAndText(s)
        let r = s.run("shape.merge", #"{"op": "union", "ids": [\#(text.rawValue), \#(pic.rawValue)]}"#)
        let out = try #require(r.get("ids")?.at(0)?.asU32.flatMap { s.st.shape(ShapeId($0)) })
        #expect(out.kind == .shape && out.text == nil)
        if case .solid? = out.fill {} else { Issue.record("\(String(describing: out.fill))") }
    }
}
