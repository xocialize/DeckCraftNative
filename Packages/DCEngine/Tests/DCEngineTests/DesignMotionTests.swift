// DCEngineTests — Design Ideas, animations, transitions and Remove Background.
// Ports the tests of deckcraft crates/engine/src/cmd/ideas.rs, cmd/animation.rs and cmd/background.rs, the
// transition test of tests.rs, and the command-only checks of it/roundtrip.rs's transition-sound tests (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import Foundation
import Testing

// MARK: - Design Ideas

/// A slide with a title, a body text box and (with `picture`) a 2:1 picture over most of it (ideas.rs `deck`).
private func ideasDeck(_ picture: Bool) -> Session {
    let s = session()
    _ = try? s.edit { doc, _ in
        doc.slides[0].shapes.removeAll()
        var title = Shape.default
        title.id = ShapeId(500)
        title.ph = Placeholder(kind: .title)
        title.xfrm = Xfrm(50.0, 30.0, 860.0, 90.0)
        title.text = TextBody.fromText("Harbour at dawn")
        var body = Shape.default
        body.id = ShapeId(501)
        body.textBox = true
        body.xfrm = Xfrm(50.0, 140.0, 860.0, 350.0)
        body.text = TextBody.fromText("one\ntwo")
        doc.slides[0].shapes.append(title)
        doc.slides[0].shapes.append(body)
        if picture {
            // A 2:1 picture covering most of the slide, over the title.
            var pic = Shape.default
            pic.id = ShapeId(502)
            pic.kind = .picture(fill: PictureFill())
            pic.xfrm = Xfrm(0.0, 0.0, 900.0, 450.0)
            doc.slides[0].shapes.append(pic)
        }
    }
    return s
}

private func shape(_ s: Session, _ id: UInt32) -> Shape {
    s.st.doc.slides[0].shapes.first { $0.id == ShapeId(id) } ?? Shape.default
}

private func overlaps(_ a: Xfrm, _ b: Xfrm) -> Bool {
    a.x < b.x + b.w - 0.5 && b.x < a.x + a.w - 0.5 && a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5
}

private func ideaIds(_ s: Session, _ i: Int = 0) -> [String] { IdeasCommands.ideasFor(s.st.doc, i).map(\.id) }

private func editSlide(_ s: Session, _ f: (inout Slide) -> Void) {
    _ = try? s.edit { doc, _ in f(&doc.slides[0]) }
}

@Suite("Design Ideas", .enabled(if: ported("design.applyIdea")))
struct DesignIdeasTests {
    // Rust: cmd/ideas.rs::picture_slides_get_layout_ideas_and_text_slides_get_text_ideas
    @Test func pictureSlidesGetLayoutIdeasAndTextSlidesGetTextIdeas() {
        #expect(ideaIds(ideasDeck(true)) == ["fullBleed", "pictureLeft", "pictureRight", "framed"])
        let s = ideasDeck(false)
        #expect(ideaIds(s).count == 3)
        #expect(ideaIds(s, 9).isEmpty)
    }

    // Rust: cmd/ideas.rs::picture_left_puts_text_beside_the_picture_cropped_to_fill
    @Test func pictureLeftPutsTextBesideThePictureCroppedToFill() throws {
        let s = ideasDeck(true)
        let themeBefore = s.st.doc.masters[0].theme.name
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        let (pic, title, body) = (shape(s, 502), shape(s, 500), shape(s, 501))
        let px = try #require(pic.xfrm)
        #expect([px.x, px.y, px.w, px.h] == [0.0, 0.0, 480.0, 540.0])
        let tx = try #require(title.xfrm)
        let bx = try #require(body.xfrm)
        #expect(!overlaps(px, tx) && !overlaps(px, bx))
        #expect(!overlaps(tx, bx))
        // 2:1 source into an 8:9 box: cut equally from left and right.
        guard case .picture(let fill) = pic.kind else {
            Issue.record("not a picture")
            return
        }
        #expect(fill.crop[0] > 0.25 && abs(fill.crop[0] - fill.crop[2]) < 1e-9 && fill.crop[1] == 0.0, "\(fill.crop)")
        // Only this slide's arrangement changed, not the theme; undo restores it.
        #expect(s.st.doc.masters[0].theme.name == themeBefore)
        #expect(s.st.doc.slides[0].shapes[0].id == ShapeId(502), "picture at the back")
        s.run("edit.undo")
        #expect(shape(s, 502).xfrm?.w == 900.0)
    }

    // Rust: cmd/ideas.rs::full_bleed_covers_the_slide_and_puts_the_title_on_a_band
    @Test func fullBleedCoversTheSlideAndPutsTheTitleOnABand() throws {
        let s = ideasDeck(true)
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        let px = try #require(shape(s, 502).xfrm)
        #expect([px.w, px.h] == [960.0, 540.0])
        let t = shape(s, 500)
        #expect(t.fill != nil)
        #expect((t.xfrm?.y ?? 0) > 300.0)
    }

    // Rust: cmd/ideas.rs::every_idea_keeps_shapes_on_the_slide_and_unknown_ideas_are_refused
    @Test func everyIdeaKeepsShapesOnTheSlideAndUnknownIdeasAreRefused() throws {
        for pic in [true, false] {
            for id in ideaIds(ideasDeck(pic)) {
                let s = ideasDeck(pic)
                s.run("design.applyIdea", "{\"id\": \"\(id)\"}")
                for sh in s.st.doc.slides[0].shapes {
                    let x = try #require(sh.xfrm)
                    #expect(x.x >= -0.01 && x.y >= -0.01 && x.x + x.w <= 960.01 && x.y + x.h <= 540.01 && x.w > 0.0 && x.h > 0.0, "\(id): \(x)")
                }
            }
        }
        let s = ideasDeck(false)
        #expect(s.fails("design.applyIdea", ##"{"id": "fullBleed"}"##))
        #expect(s.fails("design.applyIdea", ##"{"id": "nope"}"##))
    }

    // Rust: cmd/ideas.rs::switching_from_full_bleed_removes_the_title_band
    @Test func switchingFromFullBleedRemovesTheTitleBand() {
        let s = ideasDeck(true)
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        #expect(shape(s, 500).fill == IdeasCommands.bandFill())
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        #expect(shape(s, 500).fill == nil, "the band belongs to full-bleed only")
    }

    // Rust: cmd/ideas.rs::the_band_goes_on_the_visible_title_not_a_hidden_one_before_it
    @Test func theBandGoesOnTheVisibleTitleNotAHiddenOneBeforeIt() {
        let s = ideasDeck(true)
        editSlide(s) { slide in
            var hidden = Shape.default
            hidden.id = ShapeId(503)
            hidden.hidden = true
            hidden.ph = Placeholder(kind: .title)
            hidden.xfrm = Xfrm(50.0, 30.0, 860.0, 90.0)
            hidden.text = TextBody.fromText("Old title")
            slide.shapes.insert(hidden, at: 0)
        }
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        #expect(shape(s, 500).fill == IdeasCommands.bandFill(), "visible title gets the band")
        #expect(shape(s, 503).fill == nil, "hidden title is untouched")
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        #expect(shape(s, 500).fill == nil, "switching clears the visible title's band")
        #expect(shape(s, 503).fill == nil)
    }

    // Rust: cmd/ideas.rs::switching_ideas_removes_the_band_after_a_pptx_round_trip
    @Test func switchingIdeasRemovesTheBandAfterAPptxRoundTrip() throws {
        let s = ideasDeck(true)
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        let back = try PPTX.import(PPTX.export(s.st.doc))
        s.st.docRef = DocRef(back)
        let title = try #require(s.st.doc.slides[0].shapes.first { $0.ph?.kind.isTitle == true })
        let id = title.id.rawValue
        #expect(shape(s, id).fill == IdeasCommands.bandFill(), "band survives the save")
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        #expect(shape(s, id).fill == nil, "the band is removed after reopening")
    }

    // Rust: cmd/ideas.rs::switching_ideas_removes_a_band_saved_by_earlier_versions
    @Test func switchingIdeasRemovesABandSavedByEarlierVersions() {
        let s = ideasDeck(true)
        let legacy = Fill.solid(.rgb(.rgba(255, 255, 255, 220)))
        editSlide(s) { slide in
            if let i = slide.shapes.firstIndex(where: { $0.id == ShapeId(500) }) { slide.shapes[i].fill = legacy }
        }
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        #expect(shape(s, 500).fill == nil)
    }

    // Rust: cmd/ideas.rs::a_title_fill_set_by_the_user_survives_other_ideas
    @Test(.enabled(if: ported("shape.fill")))
    func aTitleFillSetByTheUserSurvivesOtherIdeas() {
        // Set through the command, and set to exactly the band's own fill.
        let s = ideasDeck(true)
        s.run("shape.fill", ##"{"id": 500, "color": "#ffffff", "transparency": 0.14}"##)
        let user = shape(s, 500).fill
        #expect(user != nil)
        s.run("design.applyIdea", ##"{"id": "pictureLeft"}"##)
        #expect(shape(s, 500).fill == user)
    }

    // Rust: cmd/ideas.rs::full_bleed_twice_keeps_the_band_and_undo_after_switching_brings_it_back
    @Test func fullBleedTwiceKeepsTheBandAndUndoAfterSwitchingBringsItBack() {
        let s = ideasDeck(true)
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        s.run("design.applyIdea", ##"{"id": "fullBleed"}"##)
        #expect(shape(s, 500).fill == IdeasCommands.bandFill())
        s.run("design.applyIdea", ##"{"id": "framed"}"##)
        #expect(shape(s, 500).fill == nil)
        s.run("edit.undo")
        #expect(shape(s, 500).fill == IdeasCommands.bandFill())
    }

    // Rust: cmd/ideas.rs::slides_with_diagrams_or_other_graphics_get_no_ideas
    @Test func slidesWithDiagramsOrOtherGraphicsGetNoIdeas() {
        // A filled autoshape with text (a diagram box) is not text to restack.
        var s = ideasDeck(false)
        editSlide(s) { slide in
            var box = Shape.default
            box.id = ShapeId(510)
            box.xfrm = Xfrm(300.0, 200.0, 200.0, 80.0)
            box.fill = .solid(.rgb(.rgba(200, 80, 20, 255)))
            box.text = TextBody.fromText("Solar wind")
            slide.shapes.append(box)
        }
        #expect(ideaIds(s).isEmpty)
        #expect(s.fails("design.applyIdea", ##"{"id": "titleColumn"}"##))
        // A connector too, and a hidden one does not count.
        s = ideasDeck(false)
        editSlide(s) { slide in
            var line = Shape.default
            line.id = ShapeId(511)
            line.kind = .connector(start: nil, end: nil)
            line.xfrm = Xfrm(300.0, 200.0, 100.0, 0.0)
            slide.shapes.append(line)
        }
        #expect(ideaIds(s).isEmpty)
        editSlide(s) { $0.shapes[2].hidden = true }
        #expect(ideaIds(s).count == 3)
    }

    // Rust: cmd/ideas.rs::two_visible_pictures_get_no_ideas_but_a_hidden_second_one_does_not_count
    @Test func twoVisiblePicturesGetNoIdeasButAHiddenSecondOneDoesNotCount() {
        let s = ideasDeck(true)
        editSlide(s) { slide in
            var pic = Shape.default
            pic.id = ShapeId(503)
            pic.kind = .picture(fill: PictureFill())
            pic.xfrm = Xfrm(600.0, 300.0, 200.0, 100.0)
            slide.shapes.append(pic)
        }
        #expect(ideaIds(s).isEmpty)
        #expect(s.fails("design.applyIdea", ##"{"id": "pictureLeft"}"##))
        editSlide(s) { $0.shapes[3].hidden = true }
        #expect(ideaIds(s).count == 4)
    }

    // Rust: cmd/ideas.rs::an_empty_text_box_blocks_ideas_only_when_it_shows
    @Test func anEmptyTextBoxBlocksIdeasOnlyWhenItShows() {
        let s = ideasDeck(false)
        editSlide(s) { slide in
            var box = Shape.default
            box.id = ShapeId(512)
            box.textBox = true
            box.xfrm = Xfrm(10.0, 10.0, 100.0, 40.0)
            slide.shapes.append(box)
        }
        #expect(ideaIds(s).count == 3, "invisible and empty: nothing in the way")
        editSlide(s) { $0.shapes[2].fill = .solid(.rgb(.rgba(200, 80, 20, 255))) }
        #expect(ideaIds(s).isEmpty, "a filled empty box would stay on top")
    }

    // Rust: cmd/ideas.rs::an_empty_box_with_an_explicit_no_fill_does_not_block_ideas
    @Test func anEmptyBoxWithAnExplicitNoFillDoesNotBlockIdeas() {
        let s = ideasDeck(false)
        editSlide(s) { slide in
            var box = Shape.default
            box.id = ShapeId(512)
            box.textBox = true
            box.xfrm = Xfrm(10.0, 10.0, 100.0, 40.0)
            box.fill = .none_
            slide.shapes.append(box)
        }
        #expect(ideaIds(s).count == 3, "an explicit no fill shows nothing")
    }

    // Rust: cmd/ideas.rs::an_empty_box_filled_through_its_style_blocks_ideas
    @Test func anEmptyBoxFilledThroughItsStyleBlocksIdeas() {
        let s = ideasDeck(false)
        editSlide(s) { slide in
            var style = ShapeStyle.accent(.accent1)
            style.lineRef.a = 0
            var box = Shape.default
            box.id = ShapeId(512)
            box.textBox = true
            box.xfrm = Xfrm(10.0, 10.0, 100.0, 40.0)
            box.style = style
            slide.shapes.append(box)
        }
        #expect(ideaIds(s).isEmpty, "the theme fill shows, so the box would stay on top")
    }

    // Rust: cmd/ideas.rs::cover_crop_matches_the_box_aspect
    @Test func coverCropMatchesTheBoxAspect() {
        var c = IdeasCommands.coverCrop(2.0, 1.0)
        #expect(abs(c[0] - 0.25) < 1e-12 && c[1] == 0.0)
        c = IdeasCommands.coverCrop(1.0, 2.0)
        #expect(abs(c[1] - 0.25) < 1e-12 && c[0] == 0.0)
        #expect(IdeasCommands.coverCrop(.nan, 1.0) == [0, 0, 0, 0])
    }

    /// Design Ideas is deterministic: the same slide gives the same ideas and the same arrangement, bit for
    /// bit, every time (deckcraft computes it all offline, with no randomness).
    @Test func ideasAreDeterministic() {
        for pic in [true, false] {
            for id in ideaIds(ideasDeck(pic)) {
                let a = ideasDeck(pic)
                let b = ideasDeck(pic)
                a.run("design.applyIdea", "{\"id\": \"\(id)\"}")
                b.run("design.applyIdea", "{\"id\": \"\(id)\"}")
                #expect(a.st.doc.slides[0].toJSON() == b.st.doc.slides[0].toJSON(), "\(id)")
            }
        }
    }
}

// MARK: - Animations

@Suite("Animation commands")
struct AnimationCommandTests {
    // Rust: cmd/animation.rs::direction_words_resolve_to_codes
    @Test func directionWordsResolveToCodes() {
        let fly = ["b", "lb", "l", "lt", "t", "rt", "r", "rb"]
        #expect(AnimationCommands.resolveOption(fly, "fromBottom") == "b")
        #expect(AnimationCommands.resolveOption(fly, "bottom") == "b")
        #expect(AnimationCommands.resolveOption(fly, "fromTopLeft") == "lt")
        #expect(AnimationCommands.resolveOption(fly, "fromBottomRight") == "rb")
        #expect(AnimationCommands.resolveOption(fly, "lt") == "lt")
        #expect(AnimationCommands.resolveOption(fly, "sideways") == nil)
        #expect(AnimationCommands.resolveOption(fly, "fromBottomTopLeft") == nil)
        let wipe = ["r", "l", "u", "d", "ru", "lu", "rd", "ld"]
        #expect(AnimationCommands.resolveOption(wipe, "fromBottom") == "d")
        #expect(AnimationCommands.resolveOption(wipe, "upRight") == "ru")
        let split = ["horzIn", "horzOut", "vertIn", "vertOut"]
        #expect(AnimationCommands.resolveOption(split, "HorzIn") == "horzIn")
        #expect(AnimationCommands.resolveOption([], "anything") == "anything")
    }

    private func insert(_ s: Session, _ preset: String, _ x: Double) -> UInt64 {
        s.run("shape.insert", "{\"preset\": \"\(preset)\", \"rect\": [\(x), 10.0, 100.0, 100.0]}")["id"]?.asU64 ?? 0
    }

    private func countOn(_ s: Session, _ id: UInt64) -> Int {
        s.run("animation.get").asArray?.filter { $0["shape"]?.asU64 == id }.count ?? -1
    }

    // Rust: cmd/animation.rs::animation_painter_copies_effects_between_shapes
    @Test(.enabled(if: ported("shape.insert")))
    func animationPainterCopiesEffectsBetweenShapes() throws {
        let s = session()
        let id1 = insert(s, "rect", 10.0)
        let id2 = insert(s, "ellipse", 150.0)
        // Add 2 animations to shape 1: fade (entrance) and spin (emphasis).
        s.run("animation.add", "{\"effect\": \"fade\", \"class\": \"entrance\", \"ids\": [\(id1)]}")
        s.run("animation.add", "{\"effect\": \"spin\", \"class\": \"emphasis\", \"ids\": [\(id1)]}")
        // Shape 2 initially has no animations.
        let before = try #require(s.run("animation.get").asArray)
        #expect(before.count == 2)
        #expect(before.allSatisfy { $0["shape"]?.asU64 == id1 })
        // Pick animations from shape 1.
        try s.select { _, sel in sel.shapes = [ShapeId(UInt32(id1))] }
        let res = s.run("animation.painter")
        #expect(res["armed"]?.asBool == true)
        #expect(res["count"]?.asU64 == 2)
        #expect(s.animPainter != nil)
        // Apply animations to shape 2.
        try s.select { _, sel in sel.shapes = [ShapeId(UInt32(id2))] }
        let applied = s.run("animation.painterApply")
        #expect(applied["applied"]?.asU64 == 2)
        // Single-click should disarm the painter.
        #expect(s.animPainter == nil)
        // Painting again replaces shape 2's animations instead of adding to them; undo restores.
        s.run("animation.painter", "{\"id\": \(id1)}")
        s.run("animation.painterApply", "{\"ids\": [\(id2)]}")
        #expect(countOn(s, id2) == 2)
        s.run("edit.undo")
        #expect(countOn(s, id2) == 2, "undo restores the first painting")
        s.run("edit.undo")
        #expect(countOn(s, id2) == 0, "undo removes the painted animations")
        s.run("edit.redo")
        // Verify shape 2 now has the 2 animations cloned.
        let after = try #require(s.run("animation.get").asArray)
        #expect(after.count == 4)
        let s2 = after.filter { $0["shape"]?.asU64 == id2 }
        #expect(s2.count == 2)
        #expect(s2.first?["effect"]?.asStr == "fade")
        #expect(s2.last?["effect"]?.asStr == "spin")
        // Picking from shape with no animations returns an error.
        s.run("animation.clear")
        #expect(s.fails("animation.painter", "{\"id\": \(id1)}"))
    }

    // Rust: cmd/animation.rs::animation_painter_sticky_mode
    @Test(.enabled(if: ported("shape.insert")))
    func animationPainterStickyMode() {
        let s = session()
        let id1 = insert(s, "rect", 10.0)
        let id2 = insert(s, "ellipse", 150.0)
        let id3 = insert(s, "roundRect", 300.0)
        s.run("animation.add", "{\"effect\": \"zoom\", \"class\": \"entrance\", \"ids\": [\(id1)]}")
        // Pick with sticky = true.
        s.run("animation.painter", "{\"id\": \(id1), \"sticky\": true}")
        #expect(s.animPainter != nil)
        // Apply to shape 2: the painter remains armed.
        s.run("animation.painterApply", "{\"ids\": [\(id2)]}")
        #expect(s.animPainter != nil)
        // Apply to shape 3: still armed.
        s.run("animation.painterApply", "{\"ids\": [\(id3)]}")
        #expect(s.animPainter != nil)
    }

    private func setupTriggers() -> (Session, [UInt64]) {
        let s = session()
        let ids = [10.0, 150.0, 300.0, 450.0].map { insert(s, "rect", $0) }
        return (s, ids)
    }

    private func triggers(_ s: Session) -> [ShapeId?] { s.st.currentSlide?.animations.map(\.trigger) ?? [] }

    // Rust: cmd/animation.rs::deleting_a_trigger_shape_clears_the_trigger
    @Test(.enabled(if: ported("shape.insert")))
    func deletingATriggerShapeClearsTheTrigger() {
        let (s, ids) = setupTriggers()
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        func id(_ v: UInt64) -> ShapeId? { ShapeId(UInt32(v)) }
        s.run("animation.add", "{\"effect\": \"fade\", \"ids\": [\(a)]}")
        s.run("animation.add", "{\"effect\": \"fade\", \"ids\": [\(d)]}")
        s.run("animation.timing", "{\"index\": 0, \"trigger\": \(b)}")
        s.run("animation.timing", "{\"index\": 1, \"trigger\": \(c)}")
        #expect(triggers(s) == [id(b), id(c)])
        s.run("edit.delete", "{\"ids\": [\(b)]}")
        #expect(triggers(s) == [nil, id(c)], "only the deleted trigger is cleared")
        #expect(s.st.currentSlide?.animations.count == 2, "the animated shapes keep their effects")
    }

    // Rust: cmd/animation.rs::deleting_a_group_clears_triggers_of_its_children
    @Test(.enabled(if: ported("shape.insert", "arrange.group")))
    func deletingAGroupClearsTriggersOfItsChildren() {
        let (s, ids) = setupTriggers()
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let g = s.run("arrange.group", "{\"ids\": [\(b), \(c)]}")["id"]?.asU64 ?? 0
        s.run("animation.add", "{\"effect\": \"fade\", \"ids\": [\(a)]}")
        s.run("animation.timing", "{\"index\": 0, \"trigger\": \(b)}")
        #expect(triggers(s) == [ShapeId(UInt32(b))])
        s.run("edit.delete", "{\"ids\": [\(g)]}")
        #expect(triggers(s) == [nil], "the trigger was inside the deleted group")
        #expect(s.st.currentSlide?.animations.count == 1)
    }

    // Rust: cmd/animation.rs::invalid_index_is_an_error_not_the_selection
    @Test(.enabled(if: ported("shape.insert")))
    func invalidIndexIsAnErrorNotTheSelection() throws {
        let s = session()
        let id = insert(s, "rect", 10.0)
        s.run("animation.add", "{\"effect\": \"fade\", \"class\": \"entrance\", \"ids\": [\(id)]}")
        try s.select { _, sel in sel.shapes = [ShapeId(UInt32(id))] }
        for badIndex in ["-1", "1.5", "\"x\""] {
            for cmd in ["animation.remove", "animation.timing", "animation.options"] {
                #expect(s.fails(cmd, "{\"index\": \(badIndex), \"duration\": 100}"), "\(cmd) accepted index \(badIndex)")
            }
            #expect(s.fails("animation.move", "{\"index\": \(badIndex), \"to\": 0}"), "animation.move accepted index \(badIndex)")
            #expect(s.run("animation.get").asArray?.count == 1)
        }
    }
}

// MARK: - Transitions

@Suite("Transition commands", .enabled(if: ported("transition.set", "transition.timing", "transition.sound")))
struct TransitionCommandTests {
    // Rust: tests.rs::transition_timing_invalid_after_keeps_value
    @Test func transitionTimingInvalidAfterKeepsValue() {
        let s = session()
        func after() -> UInt32? { s.st.doc.slides[0].transition?.advanceAfterMs }
        s.run("transition.timing", ##"{"after": 5000}"##)
        #expect(after() == 5000)
        for bad in ["-5", "1.5", "\"abc\""] {
            _ = try? s.execute("transition.timing", j("{\"after\": \(bad)}"))
            #expect(after() == 5000, "after:\(bad) must not clear the auto-advance")
        }
        s.run("transition.timing", ##"{"after": null}"##)
        #expect(after() == nil)
    }

    /// A short mono 16-bit WAV of `samples` samples (it/roundtrip.rs's `wav`).
    private func wav(_ samples: Int) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let data = (0 ..< samples).flatMap { i in le16(UInt16(bitPattern: Int16((i % 40) * 400 - 8000))) }
        return Array("RIFF".utf8) + le32(UInt32(36 + data.count)) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
            + le32(8000) + le32(16000) + le16(2) + le16(16) + Array("data".utf8) + le32(UInt32(data.count)) + data
    }

    // Rust: it/roundtrip.rs::transition_sound_is_set_saved_and_removed (the command's checks; DCPPTX tests the save)
    @Test func transitionSoundIsSetSavedAndRemoved() throws {
        let b64 = Cmd.base64Encode(wav(800))
        let s = session()
        s.run("transition.set", ##"{"kind": "fade"}"##)
        let r = try s.execute("transition.sound", ["data": .string(b64), "name": "chime.wav"])
        #expect(r["playable"] == true, "\(r.display)")
        let doc = s.st.doc
        let set = try #require(doc.slides[0].transition?.sound, "sound set")
        #expect(doc.media(set)?.name == "chime.wav")
        let back = try PPTX.import(PPTX.export(doc))
        let t = try #require(back.slides[0].transition, "transition")
        #expect(t.kind == "fade")
        let saved = try #require(t.sound, "sound survives the save")
        #expect(back.media(saved)?.data.count == wav(800).count)
        s.run("transition.sound", ##"{"none": true}"##)
        #expect(s.st.doc.slides[0].transition.map { $0.sound == nil } ?? false)
        let notAudio = Cmd.base64Encode(Array("hello, not a sound".utf8))
        #expect(throws: (any Error).self) { try s.execute("transition.sound", ["data": .string(notAudio), "name": "notes.txt"]) }
    }

    // Rust: it/roundtrip.rs::transition_sound_options_round_trip (the command's checks; DCPPTX tests the save)
    @Test func transitionSoundOptionsRoundTrip() throws {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        s.run("transition.sound", ##"{"builtin": "chime", "loop": true, "index": 0}"##)
        s.run("transition.sound", ##"{"builtin": "Chime", "index": 1}"##)
        s.run("transition.sound", ##"{"stopPrevious": true, "index": 2}"##)
        let doc = s.st.doc
        #expect(doc.media.count == 1, "the same built-in sound is embedded once")
        #expect(doc.media.first?.name == "Chime.wav")
        let back = try PPTX.import(PPTX.export(doc))
        let t = back.slides.map { $0.transition ?? .default }
        #expect(t[0].sound != nil && t[0].soundLoop && !t[0].stopSound)
        #expect(t[1].sound != nil && !t[1].soundLoop)
        #expect(t[2].sound == nil && t[2].stopSound, "\(t[2])")
        // Turning the loop off alone keeps the sound.
        s.run("transition.sound", ##"{"loop": false, "index": 0}"##)
        let after = try #require(s.st.doc.slides[0].transition)
        #expect(after.sound != nil && !after.soundLoop)
        #expect(throws: (any Error).self) { try s.execute("transition.sound", ["builtin": "foghorn"]) }
    }
}

// MARK: - Remove Background

/// A red disc on a white-to-grey gradient (background.rs `disc`).
private func disc() -> StraightImage {
    var px = [UInt8](repeating: 0, count: 80 * 60 * 4)
    for y in 0 ..< 60 {
        for x in 0 ..< 80 {
            let (dx, dy) = (Double(x) - 40.0, Double(y) - 30.0)
            let c: [UInt8]
            if dx * dx + dy * dy < 15.0 * 15.0 {
                c = [220, 30, 30, 255]
            } else {
                let g = UInt8(255 - x / 2)
                c = [g, g, g, 255]
            }
            let k = (y * 80 + x) * 4
            px[k ..< k + 4] = c[0 ..< 4]
        }
    }
    return StraightImage(width: 80, height: 60, pixels: px)
}

private func pixel(_ img: StraightImage, _ x: Int, _ y: Int) -> [UInt8] {
    let k = (y * img.width + x) * 4
    return Array(img.pixels[k ..< k + 4])
}

@Suite("Remove Background")
struct RemoveBackgroundTests {
    // Rust: cmd/background.rs::matte_clears_the_gradient_and_keeps_the_subject
    @Test func matteClearsTheGradientAndKeepsTheSubject() {
        var img = disc()
        let n = BackgroundCommands.matte(&img, 20.0)
        #expect(n > 80 * 60 / 2, "\(n)")
        #expect(pixel(img, 0, 0)[3] == 0)
        #expect(pixel(img, 79, 59)[3] == 0, "the darker end of the gradient")
        #expect(pixel(img, 40, 30) == [220, 30, 30, 255])
        // The disc's rim is softened, not cut.
        let rim = pixel(img, 40, 16)[3]
        #expect(rim > 0 && rim < 255 || pixel(img, 40, 15)[3] < 255, "\(rim)")
        // A picture with nothing but subject at its edges is left alone.
        var flat = StraightImage(width: 10, height: 10, pixels: Array((0 ..< 100).flatMap { _ in [UInt8(10), 200, 10, 255] }))
        #expect(BackgroundCommands.matte(&flat, 20.0) == 0)
        #expect(stride(from: 3, to: flat.pixels.count, by: 4).allSatisfy { flat.pixels[$0] == 255 })
    }

    // Rust: cmd/background.rs::remove_background_replaces_the_picture_and_undoes
    @Test(.enabled(if: ported("insert.picture", "shape.insert")))
    func removeBackgroundReplacesThePictureAndUndoes() throws {
        let png = try #require(BackgroundCommands.pngBytes(disc()))
        let s = session()
        let r = try s.execute("insert.picture", ["data": .string(Cmd.base64Encode(png)), "name": "disc.png"])
        let id = try #require(r["id"]?.asU32)
        func mediaOf() -> MediaId? {
            if case .picture(let fill)? = s.st.shape(ShapeId(id))?.kind { return fill.media }
            return nil
        }
        let before = mediaOf()
        s.run("picture.removeBackground", "{\"ids\": [\(id)]}")
        let after = try #require(mediaOf())
        #expect(before != after)
        let item = try #require(s.st.doc.media(after))
        #expect(item.name == "disc-no-background.png")
        let img = try #require(Images.decode(item.data))
        #expect(pixel(img, 0, 0)[3] == 0)
        s.run("edit.undo")
        #expect(mediaOf() == before)
        // Not a picture: refused.
        s.run("shape.insert", ##"{"preset": "rect", "rect": [0, 0, 50, 50]}"##)
        #expect(s.fails("picture.removeBackground"))
    }
}
