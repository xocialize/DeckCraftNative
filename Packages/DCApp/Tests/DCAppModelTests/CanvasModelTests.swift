// DCAppModelTests — the canvas's window-free logic: layout and zoom anchoring, the grid's and rulers' steps,
// page turns by wheel and flick, resize cursors, handles, the context menu, drops and keys. Ported from
// deckcraft `crates/ui-egui/src/canvas.rs`' tests, `lib.rs`' wheel and flick tests and `units_tests.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors); the egui-harness parts are checked at
// the level the Swift app exposes them.
import CoreGraphics
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Testing
@testable import DCAppModel

@MainActor
@Suite struct CanvasModelTests {
    /// A new presentation with a blank slide and one rectangle at `rect`; its id.
    static func shapeOn(_ rect: [Double]) throws -> (Session, ShapeId) {
        let s = Session.withNew()
        _ = try s.execute("slide.layout", ["layout": "blank"])
        let r = try s.execute("shape.insert", ["preset": "rect", "rect": .array(rect.map { .num($0) })])
        let id = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        return (s, id)
    }

    static func setRotation(_ s: Session, _ id: ShapeId, _ deg: Double) throws {
        try s.edit { doc, sel in
            _ = mutateShapes(&doc, sel) { shapes in DCEngine.withShape(&shapes, id) { $0.xfrm?.rot = deg } }
        }
    }

    // canvas.rs: grid_step_follows_spacing_and_rejects_unusable_values
    @Test func gridStepFollowsSpacingAndRejectsUnusableValues() {
        #expect(abs((CanvasMetrics.gridLineStep(72, 0.5) ?? 0) - 36) < 1e-3)
        #expect(CanvasMetrics.gridLineStep(6, 1) != nil)
        #expect(CanvasMetrics.gridLineStep(0, 1) == nil)
        #expect(CanvasMetrics.gridLineStep(.nan, 1) == nil)
        #expect(CanvasMetrics.gridLineStep(1000, 1) == nil)
        #expect(CanvasMetrics.gridLineStep(6, 0) == nil)
        #expect(CanvasMetrics.gridLineStep(6, 0.1) == nil, "a 6 pt grid at 10% zoom is finer than one screen point")
        #expect(CanvasMetrics.gridFits(800, 1) && !CanvasMetrics.gridFits(801, 1) && !CanvasMetrics.gridFits(.infinity, 4))
    }

    // canvas.rs: resize_cursor_tracks_rotation (#745)
    @Test func resizeCursorTracksRotation() throws {
        let (s, id) = try Self.shapeOn([100, 100, 100, 100])
        func axis(_ h: UInt8) -> ResizeAxis? { CanvasHandles.resizeAxis(s, id, h) }
        #expect(axis(0) == .nwse && axis(4) == .nwse && axis(2) == .nesw && axis(6) == .nesw)
        #expect(axis(1) == .vertical && axis(3) == .horizontal)
        try Self.setRotation(s, id, 45)
        #expect(axis(0) == .vertical, "45°: NW handle drags vertically")
        #expect(axis(2) == .horizontal, "45°: NE handle drags horizontally")
        try Self.setRotation(s, id, 90)
        #expect(axis(0) == .nesw, "90°: the diagonal is NE-SW")
        #expect(axis(2) == .nwse, "90°: NE diagonal is NW-SE")
        #expect(axis(1) == .horizontal, "90°: the top edge is horizontal")
    }

    // canvas.rs: a_wide_shape_keeps_its_corner_cursors_diagonal
    @Test func aWideShapeKeepsItsCornerCursorsDiagonal() throws {
        let (s, id) = try Self.shapeOn([100, 100, 400, 80])
        func axis(_ h: UInt8) -> ResizeAxis? { CanvasHandles.resizeAxis(s, id, h) }
        #expect(axis(0) == .nwse && axis(4) == .nwse)
        #expect(axis(2) == .nesw && axis(6) == .nesw)
        #expect(axis(1) == .vertical && axis(3) == .horizontal)
    }

    // canvas.rs: a_placeholder_that_inherits_its_box_has_a_resize_cursor
    @Test func aPlaceholderThatInheritsItsBoxHasAResizeCursor() throws {
        let s = Session.withNew()
        let st = try #require(s.activeDoc)
        let ph = try #require(st.currentSlide?.shapes.first { $0.xfrm == nil && $0.ph != nil }?.id, "the new slide has a placeholder without a box")
        #expect(CanvasHandles.resizeAxis(s, ph, 0) == .nwse)
        #expect(CanvasHandles.resizeAxis(s, ph, 2) == .nesw)
        #expect(CanvasHandles.resizeAxis(s, ph, 1) == .vertical)
    }

    // canvas.rs: format_painter_sets_the_cursor, animation_painter_sets_the_cursor (#830)
    @Test func paintersSetTheCopyCursor() {
        let s = Session.withNew()
        #expect(CanvasCursor.of(s) != .copy, "no painter is armed yet")
        s.painter = (Painted(), false)
        #expect(CanvasCursor.of(s) == .copy, "the format painter arms the Copy cursor")
        s.painter = nil
        s.animPainter = ([], false)
        #expect(CanvasCursor.of(s) == .copy, "the animation painter arms the Copy cursor")
        s.animPainter = nil
        s.setTool(.shape(preset: "rect"))
        #expect(CanvasCursor.of(s) == .crosshair)
        s.setTool(.textBox)
        #expect(CanvasCursor.of(s) == .iBeam)
    }

    /// The resize handles and the rotate handle sit round the box; a flipped box has its rotate handle below.
    @Test func boxHandlesAndTheRotateHandle() {
        let (hs, rot) = CanvasHandles.box(Xfrm(100, 50, 200, 100))
        #expect(hs.count == 8)
        #expect(hs.first == Point(100, 50) && hs.at(4) == Point(300, 150) && hs.at(7) == Point(100, 100))
        #expect(abs(rot.x - 200) < 1e-9 && abs(rot.y - 30) < 1e-9)
        var flipped = Xfrm(100, 50, 200, 100)
        flipped.flipV = true
        #expect(abs(CanvasHandles.box(flipped).rotate.y - 170) < 1e-9)
    }

    // A fitted slide's document is the viewport exactly. Its side plus the margins rounds a hair past the viewport at
    // some sizes (481.00000000000006 for a 930×481 viewport), which brought legacy scroll bars in and flipped the fit
    // on every relayout (0.1.4).
    @Test func aFittedSlideNeverOverflowsByRounding() {
        for slide in [Size(960, 540), Size(720, 540), Size(1000, 1000)] {
            for vw in stride(from: 300.0, through: 1600, by: 1) {
                for vh in [400.0, 464, 481, 517, 700, 911] {
                    let v = CGSize(width: vw, height: vh)
                    let l = CanvasLayout.make(slide: slide, viewport: v, zoom: nil)
                    if l.documentSize != v { Issue.record("\(slide) in \(v): \(l.documentSize)"); return }
                }
            }
        }
    }

    // canvas.rs: wheel_and_pinch_zoom_keep_the_point_under_the_pointer, zoom_commands_keep_the_middle_of_the_view (#106)
    @Test func zoomKeepsThePointUnderTheAnchor() {
        let slide = Size(960, 540)
        let viewport = CGSize(width: 1000, height: 700)
        let fit = CanvasLayout.make(slide: slide, viewport: viewport, zoom: nil)
        #expect(fit.overflow(viewport) == .zero, "a fitted slide has no scroll bars")
        #expect(abs(fit.slideRect.midX - 500) < 1e-9 && abs(fit.slideRect.midY - 350) < 1e-9, "centred")
        // Pinch in about a point at 80 % / 70 % of the slide.
        let p = CGPoint(x: fit.slideRect.minX + fit.slideRect.width * 0.8, y: fit.slideRect.minY + fit.slideRect.height * 0.7)
        func under(_ l: CanvasLayout, _ scroll: CGPoint) -> Point {
            l.xf.toSlide(CGPoint(x: p.x + scroll.x, y: p.y + scroll.y))
        }
        let before = under(fit, .zero)
        var layout = fit, scroll = CGPoint.zero
        for z in [fit.scale * 2, fit.scale * 2.4, fit.scale * 1.7, fit.scale * 1.36] {
            let next = CanvasLayout.make(slide: slide, viewport: viewport, zoom: z)
            scroll = next.anchoredScroll(from: layout, scroll: scroll, anchor: p, viewport: viewport)
            layout = next
            let now = under(layout, scroll)
            #expect(abs(now.x - before.x) < 0.5 && abs(now.y - before.y) < 0.5, "the point under the pointer stays: \(now) vs \(before)")
        }
        // Zoomed out below the window size, the slide is centred again.
        let small = CanvasLayout.make(slide: slide, viewport: viewport, zoom: fit.scale * 0.5)
        #expect(small.anchoredScroll(from: layout, scroll: scroll, anchor: p, viewport: viewport) == .zero)
        #expect(abs(small.slideRect.midX - 500) < 1e-9)
        // Zoomed past the window there is a margin all round and room to scroll.
        let big = CanvasLayout.make(slide: slide, viewport: viewport, zoom: 2)
        #expect(big.slideRect.minX == CanvasLayout.margin && big.overflow(viewport).width > 0)
        // Zoom In about the middle of the view keeps the middle.
        let mid = CGPoint(x: 500, y: 350)
        let at = fit.xf.toSlide(mid)
        let zin = CanvasLayout.make(slide: slide, viewport: viewport, zoom: 1.5)
        let s2 = zin.anchoredScroll(from: fit, scroll: .zero, anchor: mid, viewport: viewport)
        let still = zin.xf.toSlide(CGPoint(x: mid.x + s2.x, y: mid.y + s2.y))
        #expect(abs(still.x - at.x) < 0.5 && abs(still.y - at.y) < 0.5)
    }

    /// A zoom from outside the editor's controls is kept in range; bad sizes never make the fit infinite.
    @Test func layoutSurvivesHostileValues() {
        let l = CanvasLayout.make(slide: Size(.nan, 0), viewport: CGSize(width: -5, height: CGFloat.infinity), zoom: Double.infinity)
        #expect(l.scale.isFinite && l.scale > 0)
        #expect(CanvasLayout.make(slide: Size(960, 540), viewport: CGSize(width: 800, height: 600), zoom: 100).scale == 4)
        #expect(CanvasXf(origin: .zero, scale: 0).toSlide(CGPoint(x: 10, y: 10)).x.isFinite)
    }

    // lib.rs: page_flick_uses_the_stronger_axis
    @Test func pageFlickUsesTheStrongerAxis() {
        #expect(CanvasMetrics.pageFlick(-30, 5) == true)
        #expect(CanvasMetrics.pageFlick(30, -5) == false)
        #expect(CanvasMetrics.pageFlick(5, -30) == true)
        #expect(CanvasMetrics.pageFlick(-5, 30) == false)
        #expect(CanvasMetrics.pageFlick(10, 10) == nil, "a resting finger doesn't turn the page")
    }

    // lib.rs: mouse_wheel_keeps_fast_notches_in_both_directions_without_a_smoothed_tail
    @Test func mouseWheelKeepsFastNotchesInBothDirections() {
        var carry = 0.0
        let down = [CanvasMetrics.Wheel(dy: -1), CanvasMetrics.Wheel(dy: -1), CanvasMetrics.Wheel(dy: -1)]
        #expect(CanvasMetrics.wheelSlideTarget(down, 0, 10, &carry) == 3, "three notches in one batch are three slides")
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: 1), CanvasMetrics.Wheel(dy: 1)], 3, 10, &carry) == 1)
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -5)], 8, 10, &carry) == 9, "clamped at the last slide")
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: 5)], 1, 10, &carry) == 0, "and at the first")
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -1, cmdOrCtrl: true)], 1, 10, &carry) == nil, "⌘ zooms instead")
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dx: -3, dy: -1)], 1, 10, &carry) == nil, "sideways is not a notch")
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -1)], 0, 0, &carry) == nil, "no slides")
        // Hostile deltas never trap.
        var big = 0.0
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -1e308), CanvasMetrics.Wheel(dy: -1e308), CanvasMetrics.Wheel(dy: -1)], 0, 10, &big) != nil)
        #expect(big.isFinite)
    }

    // lib.rs: mouse_wheel_fractional_lines_accumulate_into_one_slide_per_line
    @Test func mouseWheelFractionalLinesAccumulateIntoOneSlidePerLine() {
        var carry = 0.0
        var at = 0
        var moves = 0
        for _ in 0 ..< 10 {
            if let t = CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -0.1)], at, 10, &carry), t != at {
                at = t
                moves += 1
            }
        }
        #expect(at == 1 && moves == 1, "ten tenths of a line are one slide")
        // A change of direction drops what was left over.
        _ = CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: -0.5)], at, 10, &carry)
        #expect(CanvasMetrics.wheelSlideTarget([CanvasMetrics.Wheel(dy: 0.6)], at, 10, &carry) == 1)
        #expect(abs(carry - 0.6) < 1e-9)
    }

    // lib.rs: mouse_wheel_fraction_does_not_carry_into_another_presentation
    @Test func mouseWheelFractionDoesNotCarryIntoAnotherPresentation() {
        var c = CanvasMetrics.WheelCarry()
        c.use(1)
        c.carry = -0.7
        c.use(1)
        #expect(c.carry == -0.7)
        c.use(2)
        #expect(c.carry == 0, "another presentation starts from zero")
    }

    // units_tests.rs: the_ruler_counts_centimetres_in_halves_and_inches_in_quarters
    @Test func theRulerCountsCentimetresInHalvesAndInchesInQuarters() {
        let cm = CanvasMetrics.rulerSteps(.centimeters)
        #expect(abs(cm.step - 72 / 2.54) < 1e-9 && cm.ticks == 2)
        #expect(CanvasMetrics.rulerSteps(.inches) == (72, 4))
        #expect(CanvasMetrics.rulerSteps(.points) == (72, 4), "any other unit keeps inches")
    }

    // canvas.rs: edit_points_menu_sets_segment_types_and_opens_the_path (the menu; the right click's hit is the pointer's)
    @Test func editPointsMenuSetsSegmentTypesAndOpensThePath() throws {
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        app.run("shape.insert", ["preset": "rect", "rect": [200, 150, 300, 200]])
        app.run("shape.editPoints", ["on": true])
        func points() throws -> JSON { try app.session.execute("shape.points", .emptyObject) }
        // The right edge: the segment ending at point 2.
        app.session.tool.editSegment = (0, 2)
        var menu = CanvasContextMenu.entries(app.session, word: nil, guidesOn: false)
        guard case .item(_, let curved, _, _, _)? = CanvasMenuEntry.find(menu, "Curved Segment") else {
            Issue.record("no Curved Segment in \(menu)")
            return
        }
        CanvasContextMenu.perform(curved, app, squiggles: nil)
        #expect(try points()["segments"]?.at(0) == ["straight", "straight", "curved", "straight"])
        // The bottom-right corner (point 2): Open Path breaks the outline there, Close Path joins it again.
        app.session.tool.editSegment = nil
        app.session.tool.editVertex = (0, 2)
        menu = CanvasContextMenu.entries(app.session, word: nil, guidesOn: false)
        guard case .item(_, let open, _, _, _)? = CanvasMenuEntry.find(menu, "Open Path") else {
            Issue.record("no Open Path in \(menu)")
            return
        }
        CanvasContextMenu.perform(open, app, squiggles: nil)
        #expect(try points()["paths"]?.at(0)?.asArray?.count == 5)
        #expect(app.session.tool.editVertex == nil, "the points are numbered from the new start")
        app.session.tool.editVertex = (0, 2)
        menu = CanvasContextMenu.entries(app.session, word: nil, guidesOn: false)
        guard case .item(_, let close, _, _, _)? = CanvasMenuEntry.find(menu, "Close Path") else {
            Issue.record("no Close Path in \(menu)")
            return
        }
        CanvasContextMenu.perform(close, app, squiggles: nil)
        #expect(try points()["paths"]?.at(0)?.asArray?.count == 4)
        #expect(CanvasMenuEntry.find(CanvasContextMenu.entries(app.session, word: nil, guidesOn: false), "Exit Edit Points") != nil)
    }

    // canvas.rs: edit_points_segment_menu_adds_points_and_deletes_segments
    @Test func editPointsSegmentMenuAddsPointsAndDeletesSegments() throws {
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        app.run("shape.insert", ["preset": "rect", "rect": [200, 150, 300, 200]])
        app.run("shape.editPoints", ["on": true])
        func points() throws -> JSON { try app.session.execute("shape.points", .emptyObject) }
        func item(_ title: String) -> CanvasMenuEntry? { CanvasMenuEntry.find(CanvasContextMenu.entries(app.session, word: nil, guidesOn: false), title) }
        func perform(_ title: String) {
            guard case .item(_, let a, let enabled, _, _)? = item(title), enabled else {
                Issue.record("no enabled \(title)")
                return
            }
            CanvasContextMenu.perform(a, app, squiggles: nil)
        }
        // A quarter of the way along the top edge: the new point goes there.
        app.session.tool.editSegment = (0, 1)
        app.session.tool.editSegmentT = 0.25
        perform("Add Point")
        #expect(try points()["paths"]?.at(0) == [[200.0, 150.0], [275.0, 150.0], [500.0, 150.0], [500.0, 350.0], [200.0, 350.0]])
        #expect(app.session.tool.editSegment == nil, "the points are renumbered: the pick is dropped")
        // The right edge: Open Path opens the outline at its top end.
        app.session.tool.editSegment = (0, 3)
        perform("Open Path")
        #expect(try points()["paths"]?.at(0)?.at(0) == [500.0, 150.0])
        #expect(try points()["paths"]?.at(0)?.asArray?.count == 6)
        app.run("edit.undo")
        // Delete Segment removes the right edge.
        app.session.tool.editSegment = (0, 3)
        perform("Delete Segment")
        #expect(try points()["paths"]?.at(0) == [[500.0, 350.0], [200.0, 350.0], [200.0, 150.0], [275.0, 150.0], [500.0, 150.0]])
        // On the open outline Delete Segment is greyed out; Close Path joins the ends again.
        app.session.tool.editSegment = (0, 1)
        guard case .item(_, _, let enabled, _, _)? = item("Delete Segment") else {
            Issue.record("no Delete Segment")
            return
        }
        #expect(!enabled)
        perform("Close Path")
        #expect(try points()["segments"]?.at(0)?.at(0) == "straight")
    }

    /// The menu for an object, for text being edited, and for the slide itself (`context_menu`).
    @Test func contextMenuFollowsWhatIsSelected() throws {
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        func titles() -> [String] { CanvasContextMenu.entries(app.session, word: nil, guidesOn: false).compactMap(\.title) }
        // The slide: layouts, grid and guides, background, comment.
        #expect(titles().contains("Layout") && titles().contains("Format Background…") && titles().contains("New Comment"))
        guard case .submenu(_, let layouts)? = CanvasMenuEntry.find(CanvasContextMenu.entries(app.session, word: nil, guidesOn: false), "Layout") else {
            Issue.record("no Layout submenu")
            return
        }
        #expect(!layouts.isEmpty)
        app.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
        let object = titles()
        #expect(object.prefix(3) == ["Cut", "Copy", "Paste"])
        #expect(object.contains("Edit Text") && object.contains("Edit Points") && object.contains("Lock") && object.contains("Format Shape…"))
        #expect(!object.contains("Change Picture…"), "not a picture")
        app.run("shape.lock", ["locked": true])
        #expect(titles().contains("Unlock"))
        app.run("text.edit")
        let text = titles()
        #expect(text.contains("Paragraph…") && text.contains("Bullets") && text.contains("Link…") && !text.contains("Edit Text"))
        // A guide added from the menu shows the guides.
        app.run("text.exit")
        app.run("edit.deselect")
        guard case .submenu(_, let grid)? = CanvasMenuEntry.find(CanvasContextMenu.entries(app.session, word: nil, guidesOn: false), "Grid and Guides"),
              case .item(_, let add, _, _, _)? = CanvasMenuEntry.find(grid, "Add Vertical Guide") else {
            Issue.record("no Add Vertical Guide")
            return
        }
        CanvasContextMenu.perform(add, app, squiggles: nil)
        #expect(app.ui.guides && app.session.activeDoc?.doc.guides.contains { $0.vertical } == true)
    }

    /// A dropped file: a presentation opens, a picture, sound or video is inserted, an outline becomes slides.
    @Test func dropsBecomeTheRightCommand() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(CanvasDrop.infer("Talk.PPTX", []) == .open)
        #expect(CanvasDrop.infer("deck.deckcraft", []) == .open)
        #expect(CanvasDrop.infer("photo.png", png) == .insert("insert.picture"))
        #expect(CanvasDrop.infer("song.mp3", Array("ID3".utf8) + [4, 0, 0, 0, 0, 0]) == .insert("insert.audio"))
        #expect(CanvasDrop.infer("clip.mp4", [0, 0, 0, 0x18] + Array("ftypmp42".utf8)) == .insert("insert.video"))
        #expect(CanvasDrop.infer("notes.md", []) == .outline)
        #expect(CanvasDrop.infer("archive.zip", [0x50, 0x4B, 3, 4]) == nil)
    }

    /// The canvas hands the engine deckcraft's key names (`key_name`), Command or Control as `cmd`.
    @Test func keysHaveTheEnginesNames() {
        #expect(CanvasKeys.name("\r") == "Enter" && CanvasKeys.name("\u{1B}") == "Escape" && CanvasKeys.name("\u{7F}") == "Backspace")
        #expect(CanvasKeys.name(Unicode.Scalar(0xF728) ?? "x") == "Delete" && CanvasKeys.name("\u{19}") == "Tab")
        #expect(CanvasKeys.name(Unicode.Scalar(0xF702) ?? "x") == "Left" && CanvasKeys.name(Unicode.Scalar(0xF72D) ?? "x") == "PageDown")
        #expect(CanvasKeys.name("a") == nil)
        #expect(CanvasKeys.mods(shift: true, option: false, command: false, control: true) == Mods(shift: true, alt: false, cmd: true))
    }

    /// Keys through `AppModel.key`: arrows nudge, Tab cycles, Delete deletes, Escape deselects, and the
    /// view refreshes.
    @Test func keysNudgeCycleDeleteAndDeselect() throws {
        let app = AppModel(session: Session.withNew())
        app.run("slide.layout", ["layout": "blank"])
        app.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
        app.run("shape.insert", ["preset": "ellipse", "rect": [400, 100, 100, 100]])
        let revision = app.revision
        app.key("Right", Mods())
        #expect(app.session.activeDoc?.selectedShapes.first?.xfrm?.x == 406, "an arrow nudges 6 points")
        app.key("Left", Mods(alt: true))
        #expect(app.session.activeDoc?.selectedShapes.first?.xfrm?.x == 405, "Option nudges 1 point")
        #expect(app.revision > revision, "views refresh after a key")
        let first = app.session.activeDoc?.selection.shapes
        app.key("Tab", Mods())
        #expect(app.session.activeDoc?.selection.shapes != first, "Tab cycles the selection")
        app.key("Escape", Mods())
        #expect(app.session.activeDoc?.selection.shapes.isEmpty == true)
        app.key("Tab", Mods())
        app.key("Delete", Mods())
        #expect(app.session.activeDoc?.shapes.count == 1, "Delete deletes the selected shape")
    }
}
