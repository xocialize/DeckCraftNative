// DCEngineTests — the pointer: drawing, moving, resizing and snapping shapes, connectors, freeforms, ink,
// drawing guides, right clicks, the frame of edited text, WordArt handles and shapes off the slide.
// Ports the tests of deckcraft crates/engine/src/tools.rs and the pointer tests of crates/engine/src/tests.rs,
// cmd/selection_tests.rs and cmd/guides_tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Each test names its source.
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing

@Suite("Pointer: tools.rs")
struct PointerToolsTests {
    // tools.rs resize_corner_and_flip
    @Test func resizeCornerAndFlip() {
        let o = Xfrm(100, 100, 100, 50)
        var n = Tools.resizeBox(o, 4, Vec2(20, 10), false, false)
        #expect(abs(n.x - 100) < 1e-9 && abs(n.w - 120) < 1e-9 && abs(n.h - 60) < 1e-9)
        n = Tools.resizeBox(o, 0, Vec2(10, 10), false, false)
        #expect(abs(n.x - 110) < 1e-9 && abs(n.w - 90) < 1e-9)
        n = Tools.resizeBox(o, 3, Vec2(-150, 0), false, false)
        #expect(n.flipH && abs(n.w - 50) < 1e-9 && abs(n.x - 50) < 1e-9)
        n = Tools.resizeBox(o, 4, Vec2(100, 0), true, false)
        #expect(abs(n.w / n.h - 2) < 1e-9)
        n = Tools.resizeBox(o, 3, Vec2(10, 0), false, true)
        #expect(abs(n.w - 120) < 1e-9 && abs(n.x - 90) < 1e-9)
    }

    // tools.rs resize_rotated_keeps_opposite_corner
    @Test func resizeRotatedKeepsOppositeCorner() {
        let o = Xfrm(x: 100, y: 100, w: 100, h: 50, rot: 90)
        let anchor = o.affine * Point(0, 0)
        let n = Tools.resizeBox(o, 4, Vec2(-10, 30), false, false)
        let anchor2 = n.affine * Point(0, 0)
        #expect((anchor - anchor2).hypot < 1e-6, "\(anchor) \(anchor2)")
    }

    /// A pointer event with non-finite coordinates does nothing, and hostile tolerances and pressures are
    /// tamed (never crash).
    @Test func hostileEventsAreHarmless() throws {
        let s = session()
        s.setTool(.shape(preset: "rect"))
        #expect(s.ptr(.down, .nan, 10) == .null)
        #expect(s.ptr(.down, 10, .infinity) == .null)
        #expect(!s.tool.dragging)
        s.ptr(.down, 100, 100, tol: .nan, pressure: .nan)
        s.ptr(.drag, 200, 200, tol: -5)
        let r = s.ptr(.up, 200, 200, tol: .infinity)
        #expect(r.get("id") != nil)
        // Every kind on an empty session is an error or nothing, never a trap.
        let empty = Session()
        for kind in [PointerKind.down, .drag, .up, .move, .doubleClick, .tripleClick, .contextClick] {
            _ = try? empty.pointer(pev(kind, 1, 1))
        }
        // Edit Points on a hostile index is refused by the command, not the pointer.
        _ = Tools.resizeBox(Xfrm(0, 0, 0, 0), 9, Vec2(.nan, .infinity), true, true)
        var sh = Shape.default
        Tools.setWarpAdj(&sh, "textArchUp", [], 99, 1)
        Tools.setWarpAdj(&sh, "textArchUp", [], -1, 1)
        #expect(sh.text == nil)
    }
}

@Suite("Pointer: drawing and moving shapes")
struct PointerShapeTests {
    // tests.rs pointer_draw_move_resize
    @Test func pointerDrawMoveResize() throws {
        let s = session()
        s.setTool(.shape(preset: "rect"))
        s.ptr(.down, 100, 100)
        s.ptr(.drag, 200, 180)
        let r = s.ptr(.up, 200, 180)
        let id = try #require(r.get("id")?.asU64)
        #expect(s.tool.kind == .select)
        // Move by dragging the middle.
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        s.ptr(.down, 150, 140)
        s.ptr(.drag, 170, 150)
        s.ptr(.up, 170, 150)
        var v = s.exec("shape.inspect", ["id": .integer(id)])
        #expect(v.get("box")?.get("x")?.asF64 == 120)
        #expect(v.get("box")?.get("y")?.asF64 == 110)
        // One undo step per gesture.
        s.run("edit.undo")
        v = s.exec("shape.inspect", ["id": .integer(id)])
        #expect(v.get("box")?.get("x")?.asF64 == 100)
        // Resize from the SE handle.
        s.exec("edit.select", ["ids": [.integer(id)]])
        s.ptr(.down, 200, 180)
        s.ptr(.drag, 250, 200)
        s.ptr(.up, 250, 200)
        v = s.exec("shape.inspect", ["id": .integer(id)])
        #expect(v.get("box")?.get("w")?.asF64 == 150)
    }

    // tests.rs click_into_placeholder_starts_editing
    @Test func clickIntoPlaceholderStartsEditing() {
        let s = session()
        s.ptr(.down, 480, 200)
        s.ptr(.up, 480, 200)
        #expect(s.st.selection.text != nil)
        s.run("text.insert", #"{"text": "Typed"}"#)
        #expect(s.st.currentSlide?.title == "Typed")
    }

    private func lineEnds(_ s: Session, _ id: ShapeId) -> (Point, Point) { Connect.endpoints(s.boxOf(id)) }

    // tests.rs drawing_a_line_between_shapes_glues_it
    @Test func drawingALineBetweenShapesGluesIt() throws {
        let s = session()
        let a = shapeIdOf(s.run("shape.insert", #"{"preset": "ellipse", "rect": [100, 100, 100, 100]}"#))
        let b = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [400, 100, 100, 100]}"#))
        s.run("edit.deselect")
        s.tool.kind = .shape(preset: "straightConnector1")
        // Right site of the ellipse (200,150) → left site of the rect (400,150), a little off.
        s.ptr(.down, 202, 151, tol: 4)
        s.ptr(.drag, 300, 150, tol: 4)
        #expect(!s.tool.sites.isEmpty || s.tool.glue == nil)
        s.ptr(.drag, 398, 149, tol: 4)
        #expect(s.tool.glue != nil)
        s.ptr(.up, 398, 149, tol: 4)
        let line = try #require(s.st.shapes.first { $0.isLine })
        if case .connector(let start?, let end?) = line.kind {
            #expect(start.a == a && end.a == b)
        } else {
            Issue.record("not glued: \(line.kind)")
        }
        let (p0, p1) = lineEnds(s, line.id)
        #expect(abs(p0.x - 200) < 1e-6 && abs(p1.x - 400) < 1e-6, "\(p0) \(p1)")
    }

    // tests.rs freeform_tools_and_command
    @Test func freeformToolsAndCommand() throws {
        let s = session()
        let before = s.st.shapes.count
        // Composite command: one undo step.
        let r = s.run("shape.freeform", #"{"points": [[100, 100], [200, 120], [150, 220]], "closed": true}"#)
        #expect(r.get("id")?.asU64 != nil)
        s.run("edit.undo")
        #expect(s.st.shapes.count == before)
        s.run("edit.redo")
        #expect(s.st.shapes.count == before + 1)

        // Polygon: click, click, click, click on the start → closed, filled.
        s.setTool(.shape(preset: "freeform"))
        for (x, y) in [(300.0, 300.0), (400, 300), (400, 400)] {
            s.ptr(.down, x, y)
            s.ptr(.up, x, y)
        }
        #expect(s.tool.drawingFreeform)
        s.ptr(.down, 301, 301)
        #expect(!s.tool.drawingFreeform)
        let sh = try #require(s.st.shapes.last)
        if case .custom(let paths) = sh.geom, let d = paths.first?.d {
            #expect(d.hasSuffix("Z") && d.components(separatedBy: " L ").count - 1 == 2, "\(d)")
        } else {
            Issue.record("\(sh.geom)")
        }
        let x = try #require(sh.xfrm)
        #expect(x.x == 300 && x.y == 300 && x.w == 100 && x.h == 100)

        // Scribble: one drag, open path.
        s.setTool(.shape(preset: "scribble"))
        s.ptr(.down, 10, 10)
        for i in 1 ..< 20 { s.ptr(.drag, 10 + Double(i) * 5, 10 + sin(Double(i)) * 10) }
        let r2 = s.ptr(.up, 110, 10)
        #expect(r2.get("id")?.asU64 != nil)
        #expect(s.tool.kind == .select)

        // Curve: clicks then Enter → smooth open path.
        s.setTool(.shape(preset: "curve"))
        for (x, y) in [(500.0, 100.0), (550, 50), (600, 100), (650, 50)] {
            s.ptr(.down, x, y)
            s.ptr(.up, x, y)
        }
        let k = try s.key("Enter", Mods())
        let id = ShapeId(try #require(k.get("id")?.asU32))
        if case .custom(let paths)? = s.st.shape(id)?.geom, let d = paths.first?.d {
            #expect(d.components(separatedBy: " C ").count - 1 == 3)
        } else {
            Issue.record("not a freeform")
        }
    }

    // tests.rs double_click_edits_text_inside_group
    @Test func doubleClickEditsTextInsideGroup() {
        // A text member of a group is still editable: double-click reaches it through the group.
        let s = session()
        let a = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100.0, 100.0, 120.0, 50.0], "text": "Hello"}"#))
        let b = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [300.0, 200.0, 50.0, 50.0]}"#))
        s.exec("edit.select", ["ids": [a.toJSON(), b.toJSON()]])
        s.run("arrange.group")
        // Double-click the grouped text box: it becomes editable and targets that member.
        s.ptr(.doubleClick, 160, 125)
        #expect(s.st.selection.text?.shape == a)
    }

    // tests.rs shapes_off_the_slide_can_be_selected_and_moved
    @Test func shapesOffTheSlideCanBeSelectedAndMoved() {
        // #270: shapes off the slide are hit, selected, moved and marqueed like any other.
        let s = session()
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        let off = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [1000.0, 100.0, 120.0, 80.0]}"#))
        let half = shapeIdOf(s.run("shape.insert", #"{"preset": "ellipse", "rect": [-60.0, 300.0, 120.0, 80.0]}"#))
        // Inserting off the slide keeps the box where it was asked for.
        #expect(s.inspectBox(off).get("x")?.asF64 == 1000)
        s.run("edit.select", #"{"ids": []}"#)
        // Hover and click wholly off the slide.
        if case .shape(let id, _)? = s.hitTest(Point(1060, 140), 3) { #expect(id == off) } else { Issue.record("no hit") }
        s.clickAt(1060, 140)
        #expect(s.st.selection.shapes == [off])
        // Drag it further off, then back onto the slide.
        s.ptr(.down, 1060, 140)
        s.ptr(.drag, 1110, 160)
        s.ptr(.up, 1110, 160)
        let v = s.inspectBox(off)
        #expect(v.get("x")?.asF64 == 1050 && v.get("y")?.asF64 == 120)
        s.ptr(.down, 1110, 160)
        s.ptr(.drag, 500, 160)
        s.ptr(.up, 500, 160)
        #expect(s.inspectBox(off).get("x")?.asF64 == 440)
        // The off-slide half of a straddling shape is hit too.
        s.clickAt(-30, 340)
        #expect(s.st.selection.shapes == [half])
        // A marquee started on the pasteboard selects what it encloses there.
        s.ptr(.down, -100, 250)
        s.ptr(.drag, 80, 420)
        s.ptr(.up, 80, 420)
        #expect(s.st.selection.shapes == [half])
    }

    // tests.rs pen_pressure_is_kept_and_a_mouse_draws_at_full_width
    @Test func penPressureIsKeptAndAMouseDrawsAtFullWidth() {
        let s = session()
        s.setTool(.ink(mode: "pen", color: .rgb(20, 20, 20), width: 4))
        s.ptr(.down, 40, 80, pressure: 0.2)
        s.ptr(.drag, 80, 80, pressure: 1.0)
        s.ptr(.drag, 120, 80, pressure: 0.4)
        s.ptr(.up, 120, 80, pressure: 0.4)
        s.ptr(.down, 40, 160)
        s.ptr(.drag, 100, 160, pressure: .nan)
        s.ptr(.up, 100, 160)
        var got: [[Float]] = []
        if case .ink(let strokes)? = s.st.shapes.last(where: { if case .ink = $0.kind { true } else { false } })?.kind {
            got = strokes.map { $0.points.map(\.c) }
        }
        #expect(got == [[0.2, 1.0, 0.4], [1.0, 1.0]])
    }

    /// The eraser takes the strokes it touches, as one undo step (tools.rs `erase_at`), and the highlighter
    /// draws a highlighter stroke.
    @Test func eraserTakesTouchedStrokes() {
        let s = session()
        s.setTool(.ink(mode: "highlighter", color: .rgb(255, 230, 0), width: 10))
        for y in [100.0, 200.0] {
            s.ptr(.down, 50, y)
            s.ptr(.drag, 150, y)
            s.ptr(.up, 150, y)
        }
        func strokes() -> [InkStroke] {
            if case .ink(let st)? = s.st.shapes.last(where: { if case .ink = $0.kind { true } else { false } })?.kind { return st }
            return []
        }
        #expect(strokes().count == 2 && strokes().allSatisfy(\.highlighter))
        #expect(s.st.shapes.filter { if case .ink = $0.kind { true } else { false } }.count == 1, "one ink layer per slide")
        let n = s.st.history.undo.count
        s.setTool(.ink(mode: "eraser", color: .black, width: 2))
        // Within reach of a sample of the second stroke (they are where the pointer reported, not between).
        s.ptr(.down, 100, 205)
        #expect(strokes().count == 2)
        s.ptr(.down, 148, 205)
        #expect(strokes().count == 1)
        #expect(s.st.history.undo.count == n + 2, "each press is a step, as in deckcraft")
        s.run("edit.undo")
        #expect(strokes().count == 2)
    }

    // selection_tests.rs locked_objects_are_picked_on_the_canvas_but_not_dragged
    @Test func lockedObjectsArePickedOnTheCanvasButNotDragged() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        // A: x 20..120, y 50..130 (the first shape of selection_tests.rs' deck).
        let a = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [20, 50, 100, 80]}"#))
        s.run("shape.insert", #"{"preset": "rect", "rect": [130, 50, 100, 80]}"#)
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        s.exec("shape.lock", ["id": a.toJSON(), "locked": true])
        s.run("edit.select", #"{"ids": []}"#)
        let n = s.st.history.undo.count
        s.ptr(.down, 60, 90)
        #expect(s.st.selection.shapes == [a], "a click selects a locked object")
        s.ptr(.drag, 160, 190)
        s.ptr(.up, 160, 190)
        #expect(s.inspectBox(a).get("x")?.asF64 == 20)
        // No resize handle: pressing on the SE corner and dragging doesn't size it.
        s.ptr(.down, 120, 130)
        s.ptr(.drag, 200, 200)
        s.ptr(.up, 200, 200)
        #expect(s.inspectBox(a).get("w")?.asF64 == 100)
        #expect(s.st.history.undo.count == n, "no undo steps for gestures that changed nothing")
    }

    // tests.rs wordart_adjust_handle_drags_and_undoes
    @Test func wordartAdjustHandleDragsAndUndoes() throws {
        let s = session()
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        let id = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [80.0, 60.0, 420.0, 200.0], "text": "ARCHED"}"#))
        let st0 = s.st
        var doc = st0.doc
        let slide = st0.selection.slide
        withShape(&doc.slides[slide].shapes, id) { $0.text?.body.warp = "textArchUp" }
        st0.docRef = DocRef(doc)
        s.exec("edit.select", ["ids": [id.toJSON()]])
        let st = s.st
        let sh = try #require(st.shape(id))
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let hs = Tools.wordartHandles(st.doc, st.selection, sh, x.w, x.h)
        #expect(hs.count == 1)
        let at = x.affine * (try #require(hs.first)).pos
        let top = Point(x.center.x, x.y)
        if case .warp(_, 0)? = s.hitTest(at, 4) {} else { Issue.record("not the warp handle: \(String(describing: s.hitTest(at, 4)))") }
        s.ptr(pev(.down, at, tol: 4))
        s.ptr(pev(.drag, top, tol: 4))
        s.ptr(pev(.up, top, tol: 4))
        let adj = s.st.shape(id)?.text?.body.warpAdj ?? []
        let deg = (adj.first ?? 0) / 60_000
        #expect(abs(deg - 270) < 2, "\(deg) from \(adj)")
        s.run("edit.undo")
        let body = s.st.shape(id)?.text?.body
        #expect(body?.warp == "textArchUp")
        #expect(body?.warpAdj.isEmpty == true, "undo restores the default adjusts")
    }

    /// Shift draws squares and 45° lines, Alt from the centre, and a click draws the default size; the tool
    /// stays when sticky (tools.rs `drag` › `Create`, `up` › `Create`).
    @Test func drawingModifiersAndClicks() throws {
        let s = session()
        s.setTool(.shape(preset: "ellipse"))
        s.ptr(.down, 100, 100)
        s.ptr(.drag, 160, 130, mods: Mods(shift: true))
        #expect(s.tool.preview == Xfrm(100, 100, 60, 60))
        s.ptr(.drag, 160, 130, mods: Mods(alt: true))
        #expect(s.tool.preview == Xfrm(40, 70, 120, 60))
        s.ptr(.up, 160, 130, mods: Mods(alt: true))
        // A click: 72 pt square, and the sticky tool stays.
        s.setTool(.shape(preset: "rect"))
        s.tool.sticky = true
        let r = s.ptr(.down, 300, 300)
        #expect(r == .null)
        let id = shapeIdOf(s.ptr(.up, 300, 300))
        #expect(s.boxOf(id) == Xfrm(300, 300, 72, 72))
        #expect(s.tool.kind == .shape(preset: "rect"))
        // Double-click while drawing turns the lock off.
        s.ptr(.doubleClick, 10, 10)
        #expect(!s.tool.sticky)
        // A line with Shift snaps to 45°, and runs the way it was drawn.
        s.setTool(.shape(preset: "line"))
        s.ptr(.down, 400, 400)
        s.ptr(.drag, 300, 310, mods: Mods(shift: true))
        let lid = shapeIdOf(s.ptr(.up, 300, 310, mods: Mods(shift: true)))
        let (p0, p1) = lineEnds(s, lid)
        #expect((p0 - Point(400, 400)).hypot < 1e-6)
        #expect(abs((p1.x - 400) - (p1.y - 400)) < 1e-6 && p1.x < 400, "\(p1)")
        // A text box: its width from the drag, 30 pt tall.
        s.setTool(.textBox)
        s.ptr(.down, 50, 450)
        s.ptr(.drag, 250, 470)
        let tb = s.ptr(.up, 250, 470)
        #expect(tb.get("id") != nil)
        #expect(s.tool.kind == .select)
    }

    /// Rotating with the handle (Shift: 15° steps), several shapes about their common centre; Alt-drag moves
    /// a copy; a marquee adds with Shift (tools.rs `down` › `Rotate`, `Move`, `Marquee`).
    @Test func rotateDuplicateAndMarquee() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        let a = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 100, 100]}"#))
        // The rotation handle sits 20 pt above the top edge's middle.
        s.ptr(.down, 150, 80)
        #expect(s.tool.dragging)
        s.ptr(.drag, 250, 150, mods: Mods(shift: true))
        s.ptr(.up, 250, 150, mods: Mods(shift: true))
        #expect(s.boxOf(a).rot == 90)
        s.run("edit.undo")
        #expect(s.boxOf(a).rot == 0)
        // Alt-drag: a copy moves, the original stays.
        let n = s.st.shapes.count
        s.ptr(.down, 150, 150, mods: Mods(alt: true))
        s.ptr(.drag, 200, 150, mods: Mods(alt: true))
        s.ptr(.up, 200, 150, mods: Mods(alt: true))
        #expect(s.st.shapes.count == n + 1)
        #expect(s.boxOf(a).x == 100)
        let copy = try #require(s.st.selection.shapes.first)
        #expect(copy != a && s.boxOf(copy).x == 150)
        // A marquee around both selects them; Shift adds to the selection.
        s.run("edit.deselect")
        let m = s.ptr(.down, 50, 50)
        #expect(m.get("hit") == .null)
        s.ptr(.drag, 210, 210)
        #expect(s.tool.marquee == Rect(50, 50, 210, 210))
        let r = s.ptr(.up, 210, 210)
        #expect(r.get("selected")?.asArray?.count == 1)
        s.ptr(.down, 90, 90, mods: Mods(shift: true))
        s.ptr(.up, 300, 300, mods: Mods(shift: true))
        #expect(Set(s.st.selection.shapes) == [a, copy])
        // Rotating two shapes turns them about their common centre.
        s.ptr(.down, 150, 80)
        s.ptr(.drag, 250, 150)
        s.ptr(.up, 250, 150)
        #expect(s.boxOf(a).rot != 0 && s.boxOf(copy).rot == s.boxOf(a).rot)
    }
}

@Suite("Pointer: snapping")
struct PointerSnapTests {
    /// A box at `rect` and a second box at `other` on a fresh slide; smart guides on, the grid off. The first
    /// box is selected (tests.rs `snap_scene`).
    private func snapScene(_ rect: [Double], _ other: [Double]) -> (Session, ShapeId) {
        let s = session()
        s.prefs.snapToGrid = false
        s.exec("shape.insert", ["preset": "rect", "rect": .array(other.map { .num($0) })])
        let id = shapeIdOf(s.exec("shape.insert", ["preset": "rect", "rect": .array(rect.map { .num($0) })]))
        s.exec("edit.select", ["ids": [id.toJSON()]])
        s.prefs.smartGuides = true
        return (s, id)
    }

    // tests.rs resizing_snaps_the_dragged_edge_when_the_fixed_edge_is_already_aligned
    @Test func resizingSnapsTheDraggedEdgeWhenTheFixedEdgeIsAlreadyAligned() {
        let (s, id) = snapScene([100, 100, 100, 80], [100, 300, 200, 80])
        s.dragGesture((200, 140), (297, 140))
        let b = s.inspectBox(id)
        #expect(b.get("x")?.asF64 == 100, "the fixed edge stays: \(b.display)")
        #expect(b.get("w")?.asF64 == 200, "the right edge snaps to the other box's right edge at 300: \(b.display)")
    }

    // tests.rs resizing_is_not_shifted_by_a_fixed_edge_near_a_line
    @Test func resizingIsNotShiftedByAFixedEdgeNearALine() {
        let (s, id) = snapScene([100, 100, 100, 80], [103, 300, 50, 80])
        s.dragGesture((200, 140), (421, 140))
        let b = s.inspectBox(id)
        #expect(b.get("x")?.asF64 == 100, "the fixed edge stays: \(b.display)")
        #expect(b.get("w")?.asF64 == 321, "the dragged edge goes where the pointer went: \(b.display)")
    }

    // tests.rs resizing_past_the_opposite_edge_snaps_the_dragged_edge
    @Test func resizingPastTheOppositeEdgeSnapsTheDraggedEdge() {
        var (s, id) = snapScene([100, 100, 100, 80], [0, 300, 50, 80])
        s.dragGesture((200, 140), (3, 140))
        var b = s.inspectBox(id)
        #expect(b.get("x") == .double(0) && b.get("w") == .double(100), "the dragged edge snaps to 0, the fixed edge stays at 100: \(b.display)")
        (s, id) = snapScene([100, 100, 100, 80], [300, 0, 80, 50])
        s.dragGesture((150, 180), (150, 3))
        b = s.inspectBox(id)
        #expect(b.get("y") == .double(0) && b.get("h") == .double(100), "the dragged edge snaps to 0, the fixed edge stays at 100: \(b.display)")
    }

    // tests.rs resizing_a_flipped_box_snaps_the_dragged_edge
    @Test func resizingAFlippedBoxSnapsTheDraggedEdge() {
        let (s, id) = snapScene([100, 100, 100, 80], [0, 300, 50, 80])
        s.run("shape.flip", #"{"axis": "horizontal"}"#)
        s.dragGesture((100, 140), (3, 140))
        let b = s.inspectBox(id)
        #expect(b.get("x") == .double(0) && b.get("w") == .double(200), "the dragged edge snaps to 0, the fixed edge stays at 200: \(b.display)")
    }

    /// A move snaps to other shapes and shows the guide; Cmd turns snapping off; with smart guides on, the
    /// grid takes an edge no line is near; Shift keeps the move on one axis (tools.rs `snap_rect`,
    /// `snap_edges`).
    @Test func movesSnapToShapesAndTheGrid() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.prefs.snapToGrid = false
        s.run("shape.insert", #"{"preset": "rect", "rect": [400, 300, 100, 100]}"#)
        let id = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [101, 101, 50, 50]}"#))
        s.ptr(.down, 120, 120)
        s.ptr(.drag, 417, 120)
        // The moved left edge (398) snaps to the other box's left edge at 400.
        #expect(s.boxOf(id).x == 400)
        #expect(s.tool.guides.contains { $0.vertical && $0.pos == 400 })
        // Cmd: no snapping, the pointer's delta exactly.
        s.ptr(.drag, 417, 120, mods: Mods(cmd: true))
        #expect(s.boxOf(id).x == 398 && s.tool.guides.isEmpty)
        s.ptr(.up, 417, 120, mods: Mods(cmd: true))
        // The grid: away from every line, the box's left and top edges land on the 6 pt grid.
        s.prefs.snapToGrid = true
        s.ptr(.down, 420, 120)
        s.ptr(.drag, 432, 133)
        #expect(s.boxOf(id).x == 408 && s.boxOf(id).y == 114, "\(s.boxOf(id))")
        // Shift: only the larger component of the move; the left edge (398 again) snaps to 400.
        s.ptr(.drag, 432, 200, mods: Mods(shift: true))
        #expect(s.boxOf(id).x == 400 && s.boxOf(id).y == 180, "\(s.boxOf(id))")
        s.ptr(.up, 432, 200, mods: Mods(shift: true))
        #expect(s.tool.guides.isEmpty)
    }

    // guides_tests.rs drag_a_guide_drop_it_off_the_slide_and_snap_shapes_to_it
    @Test func dragAGuideDropItOffTheSlideAndSnapShapesToIt() throws {
        let s = Session.withNew()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("guide.add", #"{"vertical": true, "pos": 300}"#)
        // Hidden guides can't be grabbed: the press starts a marquee instead.
        s.ptr(.down, 300, 50, tol: 4)
        s.ptr(.up, 300, 50, tol: 4)
        #expect(s.st.doc.guides.first?.pos == 300)
        s.tool.guidesVisible = true
        s.ptr(.down, 301, 50, tol: 4)
        s.ptr(.drag, 350.4, 60, tol: 4)
        #expect(s.tool.guideDrag.map { $0.0 == 0 && $0.1 == 350 } == true, "whole points while dragging")
        s.ptr(.up, 350.4, 60, tol: 4)
        #expect(s.st.doc.guides.first?.pos == 350)
        #expect(s.tool.guideDrag == nil)

        // A shape dragged near the guide snaps its left edge onto it.
        let id = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 200, 80, 60]}"#))
        s.prefs.snapToGrid = false
        s.ptr(.down, 140, 230, tol: 4)
        s.ptr(.drag, 200, 230, tol: 4)
        s.ptr(.drag, 388, 231, tol: 4)
        s.ptr(.up, 388, 231, tol: 4)
        let x = try #require(s.st.shapes.first { $0.id == id }?.xfrm)
        #expect(abs(x.x - 350) < 0.01, "\(x)")

        // Dropped off the slide: gone, and undo brings it back.
        s.ptr(.down, 350, 10, tol: 4)
        s.ptr(.drag, -40, 10, tol: 4)
        s.ptr(.up, -40, 10, tol: 4)
        #expect(s.st.doc.guides.isEmpty)
        s.run("edit.undo")
        #expect(s.st.doc.guides.count == 1)
    }
}

@Suite("Pointer: right clicks")
struct PointerContextClickTests {
    /// A blank slide with a rectangle A (100,100 200×100) and a text box B (400,100 200 wide), nothing
    /// selected (tests.rs `two_shapes`).
    private func twoShapes() throws -> (Session, ShapeId, ShapeId) {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let a = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100.0, 100.0, 200.0, 100.0], "text": "Shape A"}"#))
        let b = shapeIdOf(s.run("insert.textBox", #"{"rect": [400.0, 100.0, 200.0, 40.0], "text": "Box B"}"#))
        try s.select { _, sel in
            sel.shapes.removeAll()
            sel.text = nil
        }
        return (s, a, b)
    }

    // tests.rs right_click_selects_the_shape_under_the_pointer
    @Test func rightClickSelectsTheShapeUnderThePointer() throws {
        let (s, a, b) = try twoShapes()
        let undoBefore = s.st.history.undo.count
        // An unselected shape: selected alone, no text editing, no drag.
        var r = s.ptr(.contextClick, 150, 150)
        #expect(r.get("selected") == [a.toJSON()])
        #expect(s.st.selection.shapes == [a])
        #expect(s.st.selection.text == nil)
        #expect(!s.tool.dragging)
        s.ptr(.drag, 190, 190)
        #expect(s.boxOf(a).x == 100)
        // A text box, which a left click would start editing: only selected.
        s.ptr(.contextClick, 450, 115)
        #expect(s.st.selection.shapes == [b])
        #expect(s.st.selection.text == nil)
        // A multiple selection stays when the right click lands on one of its shapes.
        s.exec("edit.select", ["ids": [a.toJSON(), b.toJSON()]])
        s.ptr(.contextClick, 450, 115)
        #expect(s.st.selection.shapes == [a, b])
        // Empty slide: nothing selected (the slide menu).
        r = s.ptr(.contextClick, 700, 450)
        #expect(r.get("hit") == .null, "\(r.display)")
        #expect(s.st.selection.shapes.isEmpty)
        #expect(s.st.history.undo.count == undoBefore)
    }

    // tests.rs right_click_in_edited_text_keeps_the_text_selection
    @Test func rightClickInEditedTextKeepsTheTextSelection() throws {
        let (s, a, b) = try twoShapes()
        s.exec("text.edit", ["id": a.toJSON(), "at": [0, 0]])
        s.run("text.move", #"{"to": "wordRight", "extend": true}"#)
        let before = try #require(s.st.selection.text)
        #expect(before.isRange)
        // Anywhere in the box, even away from the selected word.
        let r = s.ptr(.contextClick, 280, 185)
        #expect(r.get("editing") == true)
        #expect(s.st.selection.text == before)
        // The context menu's Copy and Cut then act on the selected text.
        #expect(s.run("edit.copy").get("text")?.asStr.map { String(rustTrim($0)) } == "Shape")
        s.run("edit.cut")
        #expect(s.exec("text.get", ["id": a.toJSON()]).get("text")?.asStr.map { String(rustTrim($0)) } == "A")
        // A right click on another shape leaves editing and selects that shape.
        s.ptr(.contextClick, 450, 115)
        #expect(s.st.selection.text == nil)
        #expect(s.st.selection.shapes == [b])
    }
}

@Suite("Pointer: the frame of edited text")
struct PointerFrameTests {
    /// A blank slide holding one text box being edited, smart guides and grid snapping off so drags move by
    /// exactly the pointer delta (tests.rs `editing_text_box`).
    private func editingTextBox(_ rot: Double) -> (Session, ShapeId, Xfrm) {
        let s = session()
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        s.run("slide.new", #"{"layout": "blank"}"#)
        let id = shapeIdOf(s.run("insert.textBox", #"{"rect": [200.0, 150.0, 240.0, 60.0], "text": "Hello world"}"#))
        if rot != 0 { s.exec("shape.rotate", ["ids": [id.toJSON()], "deg": .num(rot)]) }
        s.exec("text.edit", ["id": id.toJSON(), "at": [0, 0]])
        return (s, id, s.boxOf(id))
    }

    /// Slide point for a point in the box's own (rotated) frame (tests.rs `on_box`).
    private func onBox(_ x: Xfrm, _ lx: Double, _ ly: Double) -> (Double, Double) {
        let p = x.affine * Point(lx, ly)
        return (p.x, p.y)
    }

    // tests.rs dragging_the_frame_of_edited_text_moves_the_box
    @Test func draggingTheFrameOfEditedTextMovesTheBox() {
        let (s, id, x) = editingTextBox(0)
        #expect(x.h > 12, "\(x)")
        // Hovering the band on either side of the edge says "move"; the inside says "text".
        for ly in [-2.0, 2.0, x.h + 2.0] {
            let (px, py) = onBox(x, x.w / 4.0, ly)
            s.ptr(.move, px, py)
            #expect(s.tool.hover == .frame(id: id), "ly \(ly)")
        }
        let (px, py) = onBox(x, x.w / 4.0, x.h / 2.0)
        s.ptr(.move, px, py)
        #expect(s.tool.hover == .shape(id: id, text: true))

        // Press on the top edge, just outside, and drag: the box moves, text editing ends.
        var undoBefore = s.st.history.undo.count
        let from = onBox(x, x.w / 4.0, -1.0)
        let down = s.dragGesture(from, (from.0 + 30, from.1 + 20))
        #expect(down.get("hit") == ["kind": "frame", "id": id.toJSON()])
        let moved = s.boxOf(id)
        #expect(abs(moved.x - (x.x + 30)) < 1e-9 && abs(moved.y - (x.y + 20)) < 1e-9, "\(moved)")
        #expect(moved.w == x.w && moved.h == x.h)
        #expect(s.st.selection.text == nil)
        #expect(s.st.selection.shapes == [id])
        // One undo step, which puts the box back.
        #expect(s.st.history.undo.count == undoBefore + 1)
        s.run("edit.undo")
        #expect(s.boxOf(id) == x)

        // The inner side of the band works too; a click there without a drag selects the box whole and
        // changes nothing.
        s.exec("text.edit", ["id": id.toJSON(), "at": [0, 0]])
        undoBefore = s.st.history.undo.count
        let (qx, qy) = onBox(x, x.w * 0.75, x.h - 1.0)
        s.clickAt(qx, qy)
        #expect(s.st.selection.text == nil)
        #expect(s.st.selection.shapes == [id])
        #expect(s.st.history.undo.count == undoBefore)
        #expect(s.boxOf(id) == x)
    }

    // tests.rs clicking_the_frame_of_a_text_box_selects_it_whole
    @Test func clickingTheFrameOfATextBoxSelectsItWhole() {
        let (s, id, x) = editingTextBox(0)
        let undoBefore = s.st.history.undo.count
        // Leave editing and select nothing: a click on empty slide.
        s.clickAt(20, 20)
        #expect(s.st.selection.shapes.isEmpty)
        // Edges and corner bands, inside and just outside the box, select it but don't start typing.
        for (lx, ly) in [(x.w / 4.0, 1.0), (x.w / 4.0, -2.0), (x.w * 0.75, x.h - 1.0), (1.0, x.h / 2.0), (x.w + 2.0, x.h / 2.0)] {
            s.clickAt(20, 20)
            let (px, py) = onBox(x, lx, ly)
            s.clickAt(px, py)
            #expect(s.st.selection.shapes == [id], "(\(lx), \(ly))")
            #expect(s.st.selection.text == nil, "(\(lx), \(ly)) entered text")
        }
        // Dragging the frame moves the box; the inside of an unselected box still takes the caret.
        s.clickAt(20, 20)
        let from = onBox(x, x.w / 4.0, 1.0)
        s.dragGesture(from, (from.0 + 30, from.1 + 20))
        let moved = s.boxOf(id)
        #expect(abs(moved.x - (x.x + 30)) < 1e-9 && abs(moved.y - (x.y + 20)) < 1e-9, "\(moved)")
        s.clickAt(20, 20)
        var (px, py) = onBox(moved, moved.w / 4.0, moved.h / 2.0)
        s.clickAt(px, py)
        #expect(s.st.selection.text != nil)
        // The frame also deletes: select by frame, press Delete.
        s.clickAt(20, 20)
        (px, py) = onBox(moved, moved.w / 4.0, 1.0)
        s.clickAt(px, py)
        s.run("edit.delete")
        #expect(s.st.shape(id) == nil)
        #expect(s.st.history.undo.count > undoBefore)
    }

    // tests.rs clicking_the_frame_of_a_selected_plain_shape_still_takes_the_caret
    @Test func clickingTheFrameOfASelectedPlainShapeStillTakesTheCaret() {
        let s = session()
        s.prefs.snapToGrid = false
        s.prefs.smartGuides = false
        s.run("slide.new", #"{"layout": "blank"}"#)
        let id = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [200.0, 150.0, 240.0, 60.0], "text": "Hello"}"#))
        let x = s.boxOf(id)
        // The first click selects an ordinary shape, the second puts the caret, as before; the frame rule is
        // for text boxes and placeholders only.
        s.clickAt(20, 20)
        var (px, py) = onBox(x, x.w / 4.0, x.h / 2.0)
        s.clickAt(px, py)
        #expect(s.st.selection.shapes == [id])
        #expect(s.st.selection.text == nil)
        (px, py) = onBox(x, x.w / 4.0, 1.0)
        s.clickAt(px, py)
        #expect(s.st.selection.text != nil, "frame click on a selected plain shape lost the caret")
    }

    // tests.rs dragging_inside_edited_text_selects_text
    @Test func draggingInsideEditedTextSelectsText() throws {
        let (s, id, x) = editingTextBox(0)
        let undoBefore = s.st.history.undo.count
        let down = s.dragGesture(onBox(x, 8, x.h / 2.0), onBox(x, x.w - 8, x.h / 2.0))
        #expect(down.get("caret") != nil, "\(down.display)")
        #expect(s.boxOf(id) == x)
        let t = try #require(s.st.selection.text, "still editing")
        #expect(t.isRange, "\(t)")
        #expect(sameRange(orderedOf(t), ((0, 0), (0, 11))))
        #expect(s.st.history.undo.count == undoBefore)
    }

    // tests.rs frame_of_rotated_edited_text_follows_the_rotation
    @Test func frameOfRotatedEditedTextFollowsTheRotation() {
        let (s, id, x) = editingTextBox(30)
        #expect(x.rot == 30)
        // The rotated bottom edge is the frame; dragging it moves the box and keeps its rotation.
        let from = onBox(x, x.w / 4.0, x.h + 1.0)
        #expect(s.hitTest(Point(from.0, from.1), 3) == .frame(id: id))
        let down = s.dragGesture(from, (from.0 + 25, from.1 - 10))
        #expect(down.get("hit")?.get("kind") == "frame")
        let moved = s.boxOf(id)
        #expect(abs(moved.x - (x.x + 25)) < 1e-9 && abs(moved.y - (x.y - 10)) < 1e-9, "\(moved)")
        #expect(moved.rot == 30)
        // Inside the rotated box, pressing still places the caret.
        s.exec("text.edit", ["id": id.toJSON(), "at": [0, 0]])
        let mx = s.boxOf(id)
        let (px, py) = onBox(mx, mx.w / 2.0, mx.h / 2.0)
        var r = s.ptr(.down, px, py)
        s.ptr(.up, px, py)
        #expect(r.get("caret") != nil, "\(r.display)")
        #expect(s.boxOf(id) == mx)
        // Inside the axis-aligned bounds but off the rotated box: neither text nor frame, so a press there
        // leaves editing instead of moving the caret.
        let off = onBox(mx, mx.w / 2.0, -mx.h)
        let offPt = Point(off.0, off.1)
        #expect(mx.bounds.contains(offPt))
        #expect(s.hitTest(offPt, 3) != .frame(id: id))
        r = s.ptr(.down, off.0, off.1)
        s.ptr(.up, off.0, off.1)
        #expect(r.get("caret") == nil, "\(r.display)")
        #expect(s.st.selection.text == nil)
        #expect(s.boxOf(id) == mx)
    }

    // tests.rs resize_handles_beat_the_frame_of_edited_text
    @Test func resizeHandlesBeatTheFrameOfEditedText() {
        let (s, id, x) = editingTextBox(0)
        // The SE corner lies in the frame band, but its handle wins.
        let from = onBox(x, x.w, x.h)
        let down = s.dragGesture(from, (from.0 + 40, from.1))
        #expect(down.get("hit")?.get("kind") == "resize")
        let sized = s.boxOf(id)
        #expect(abs(sized.w - (x.w + 40)) < 1e-9, "\(sized)")
        #expect(sized.x == x.x && sized.y == x.y)
    }

    // tests.rs a_shape_in_front_of_edited_text_takes_the_click
    @Test func aShapeInFrontOfEditedTextTakesTheClick() throws {
        // #931: a shape in front of edited placeholder text still takes a click; a click on the text where
        // nothing is in front still moves the caret.
        let s = Session.withNew()
        s.run("slide.new", #"{"layout": "titleAndContent"}"#)
        let square = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [380, 260, 200, 120]}"#))
        s.run("edit.deselect")
        // The content placeholder's edge: its (empty) text is now being edited.
        s.clickAt(66, 300, tol: 4)
        let body = try #require(s.st.selection.text?.shape, "editing the content placeholder")
        #expect(body != square)
        // A click on the text away from the square keeps editing it.
        s.clickAt(200, 300, tol: 4)
        #expect(s.st.selection.text?.shape == body)
        // A click on the square, in front of the text, selects the square.
        s.clickAt(480, 320, tol: 4)
        #expect(s.st.selection.shapes == [square])
        #expect(s.st.selection.text.map { $0.shape == square } ?? true, "\(String(describing: s.st.selection.text))")

        // A shape over the edited box's edge takes the click there too: the edge would otherwise drag the box.
        let bx = s.boxOf(body)
        let edge = (bx.x, bx.y + bx.h / 2.0)
        let corner = shapeIdOf(s.exec("shape.insert", ["preset": "ellipse", "rect": [.num(edge.0 - 10), .num(edge.1 - 10), 20, 20]]))
        s.run("edit.deselect")
        s.exec("text.edit", ["id": body.toJSON()])
        // On the box's left edge, inside the band that drags it, clear of its middle handle.
        s.clickAt(edge.0 + 1, edge.1 - 9, tol: 4)
        #expect(s.st.selection.shapes == [corner], "\(s.st.selection.toJSON().display)")

        // Text inside a group: a member in front of it takes the click instead of the caret.
        s.run("slide.new", #"{"layout": "blank"}"#)
        let tb = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 300, 150], "text": "Grouped text"}"#))
        let cover = shapeIdOf(s.run("shape.insert", #"{"preset": "rect", "rect": [200, 150, 60, 40]}"#))
        s.exec("arrange.group", ["ids": [tb.toJSON(), cover.toJSON()]])
        s.exec("text.edit", ["id": tb.toJSON()])
        #expect(s.st.selection.text?.shape == tb)
        s.clickAt(230, 170, tol: 4)
        #expect(s.st.selection.text.map { $0.shape != tb } ?? true, "the click on the member in front left the text: \(s.st.selection.toJSON().display)")
    }
}
