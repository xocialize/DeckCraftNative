// DCEngineTests — Edit Points with the pointer: dragging vertices and handles, Ctrl-clicks, Esc during a drag,
// the point type a modifier chooses and its memory across Undo, Redo and shapes, and right clicks that pick
// the point or the segment. Ports the Edit Points pointer tests of deckcraft crates/engine/src/tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import Testing

@Suite("Pointer: Edit Points")
struct PointerPointsTests {
    /// An ellipse (or `preset`) at (100, 100) 200×100 on a blank slide, in Edit Points; its id.
    private func editing(_ preset: String = "ellipse") throws -> (Session, ShapeId) {
        let s = Session.withNew()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.exec("shape.insert", ["preset": .string(preset), "rect": [100, 100, 200, 100]])
        s.run("shape.editPoints", #"{"on": true}"#)
        let id = ShapeId(try #require(s.run("shape.points").get("id")?.asU32))
        return (s, id)
    }

    private func pts(_ s: Session) -> [Point] {
        (s.run("shape.points").get("paths")?.at(0)?.asArray ?? []).map { Point($0.at(0)?.asF64 ?? .nan, $0.at(1)?.asF64 ?? .nan) }
    }

    /// The handles (in, out) and the point of vertex `index` of path 0.
    private func handles(_ s: Session, _ id: ShapeId, _ index: Int = 0) throws -> (Point, Point, Point) {
        let sh = try #require(s.st.shape(id))
        let (hi, ho, v) = try #require(PointsCommands.slideHandles(s.st.doc, s.st.selection, sh, 0, index))
        return (try #require(hi), try #require(ho), v)
    }

    private func type0(_ s: Session) -> String? { s.run("shape.points").get("types")?.at(0)?.at(0)?.asStr }

    /// Press at `from`, drag to `to` with `mods`, release (the press is plain).
    private func drag(_ s: Session, _ from: Point, _ to: Point, _ mods: Mods = Mods(), sourceLocation: SourceLocation = #_sourceLocation) {
        s.ptr(pev(.down, from, tol: 0), sourceLocation: sourceLocation)
        s.ptr(pev(.drag, to, tol: 0, mods: mods), sourceLocation: sourceLocation)
        s.ptr(pev(.up, to, tol: 0, mods: mods), sourceLocation: sourceLocation)
    }

    // tests.rs edit_points_with_the_pointer_and_curves
    @Test func editPointsWithThePointerAndCurves() throws {
        let (s, _) = try editing()
        let v = pts(s)
        #expect(v.count >= 4, "\(v)")
        // Drag the first vertex 30 pt left: one undo step.
        let (x0, y0) = (v[0].x, v[0].y)
        s.ptr(.down, x0, y0, tol: 0)
        s.ptr(.drag, x0 - 15, y0, tol: 0)
        s.ptr(.drag, x0 - 30, y0, tol: 0)
        s.ptr(.up, x0 - 30, y0, tol: 0)
        let w = pts(s)
        #expect(abs(w[0].x - (x0 - 30)) < 1e-3 && abs(w[0].y - y0) < 1e-3, "\(w)")
        #expect(zip(w.dropFirst(), v.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-3 && abs($0.y - $1.y) < 1e-3 })
        s.run("edit.undo")
        #expect(abs((pts(s).first?.x ?? 0) - x0) < 1e-3)
        // Ctrl-click a vertex deletes it.
        let n = pts(s).count
        let p1 = pts(s)[1]
        s.ptr(.down, p1.x, p1.y, tol: 0, mods: Mods(cmd: true))
        s.ptr(.up, p1.x, p1.y, tol: 0, mods: Mods(cmd: true))
        #expect(pts(s).count == n - 1)
        // Escape leaves Edit Points.
        _ = try s.key("Escape", Mods())
        #expect(s.tool.editPoints == nil)
    }

    // tests.rs edit_points_escape_cancels_a_point_or_handle_drag
    @Test func editPointsEscapeCancelsAPointOrHandleDrag() throws {
        // Esc before the button is released cancels a point or handle drag: the shape is as it was at the
        // press, no undo step is added, and Edit Points stays on.
        let (s, id) = try editing()
        func path() -> Geom? { s.st.shape(id)?.geom }
        let (before, steps) = (path(), s.st.history.undo.count)
        // A vertex: drag it, press Esc, keep dragging, release.
        let p0 = pts(s)[0]
        s.ptr(.down, p0.x, p0.y, tol: 0)
        s.ptr(.drag, p0.x - 30, p0.y, tol: 0)
        #expect(path() != before, "the drag moves the point")
        #expect(try s.key("Escape", Mods()).get("handled") == true)
        #expect(path() == before, "Esc puts the point back")
        #expect(!s.tool.dragging)
        s.ptr(.drag, p0.x - 50, p0.y, tol: 0)
        s.ptr(.up, p0.x - 50, p0.y, tol: 0)
        #expect(path() == before, "the rest of the drag does nothing")
        #expect(s.st.history.undo.count == steps, "no undo step")
        #expect(s.tool.editingPoints(s.st) == id, "Edit Points stays on")
        // A handle of the same point, which the press on the point shows.
        let (_, ho, _) = try handles(s, id)
        s.ptr(.down, ho.x, ho.y, tol: 0)
        s.ptr(.drag, ho.x + 20, ho.y + 20, tol: 0)
        #expect(path() != before, "the drag moves the handle")
        _ = try s.key("Escape", Mods())
        s.ptr(.up, ho.x + 20, ho.y + 20, tol: 0)
        #expect(path() == before, "Esc puts the handle back")
        #expect(s.st.history.undo.count == steps, "no undo step")
        #expect(s.tool.editingPoints(s.st) == id, "Edit Points stays on")
        // Without a drag, Esc still leaves Edit Points.
        _ = try s.key("Escape", Mods())
        #expect(s.tool.editPoints == nil)
    }

    // tests.rs edit_points_handle_drag_modifiers_set_the_point_type
    @Test func editPointsHandleDragModifiersSetThePointType() throws {
        // Alt, Shift or Ctrl held while dragging a handle makes the point a corner, smooth or straight point,
        // and the point keeps that type for the next drag.
        let (s, id) = try editing()
        // Click the point to show its handles.
        let (hi, ho, v) = try handles(s, id)
        drag(s, v, v)
        #expect(s.tool.editVertex.map { $0 == (0, 0) } == true)
        // Alt: only the dragged handle moves.
        let to = ho + Vec2(10, -25)
        drag(s, ho, to, Mods(alt: true))
        let (hi1, ho1, _) = try handles(s, id)
        #expect((ho1 - to).hypot < 1e-3, "\(ho1)")
        #expect((hi1 - hi).hypot < 1e-3, "the other handle stays: \(hi1) \(hi)")
        #expect(type0(s) == "corner")
        // A plain drag afterwards keeps it a corner point.
        let to2 = ho1 + Vec2(5, 5)
        drag(s, ho1, to2)
        #expect((try handles(s, id).0 - hi).hypot < 1e-3)
        // Shift: the other handle mirrors the dragged one at the same length.
        let to3 = v + Vec2(0, 40)
        drag(s, to2, to3, Mods(shift: true))
        let (hi3, ho3, _) = try handles(s, id)
        #expect((ho3 - to3).hypot < 1e-3, "\(ho3)")
        #expect((hi3 - (v - Vec2(0, 40))).hypot < 1e-3, "\(hi3)")
        #expect(type0(s) == "smooth")
        // Ctrl: the other handle turns in line and keeps its length.
        let to4 = v + Vec2(30, 0)
        drag(s, ho3, to4, Mods(cmd: true))
        let (hi4, ho4, _) = try handles(s, id)
        #expect((ho4 - to4).hypot < 1e-3, "\(ho4)")
        #expect((hi4 - (v - Vec2(40, 0))).hypot < 1e-3, "\(hi4)")
        #expect(type0(s) == "straight")
    }

    // tests.rs edit_points_escape_takes_back_the_point_type_of_a_modifier_drag
    @Test func editPointsEscapeTakesBackThePointTypeOfAModifierDrag() throws {
        // Esc during a handle drag with Shift also takes back the point type the modifier chose, so the next
        // plain drag still treats the point as a corner.
        let (s, id) = try editing()
        let (_, ho, v) = try handles(s, id)
        s.ptr(pev(.down, v, tol: 0))
        s.ptr(pev(.up, v, tol: 0))
        // Alt makes it a corner point.
        let to = ho + Vec2(10, -25)
        drag(s, ho, to, Mods(alt: true))
        let (hi1, ho1, _) = try handles(s, id)
        let kind = s.tool.vertexKind
        // Shift would make it smooth; Esc cancels that drag.
        s.ptr(pev(.down, ho1, tol: 0))
        s.ptr(pev(.drag, v + Vec2(0, 40), tol: 0, mods: Mods(shift: true)))
        _ = try s.key("Escape", Mods())
        s.ptr(pev(.up, v + Vec2(0, 40), tol: 0))
        #expect(s.tool.vertexKind == kind)
        // A plain drag leaves the other handle where it is.
        drag(s, ho1, ho1 + Vec2(5, 5))
        #expect((try handles(s, id).0 - hi1).hypot < 1e-3, "the other handle stays")
    }

    // tests.rs edit_points_remembered_point_type_follows_undo_redo_and_its_shape
    @Test func editPointsRememberedPointTypeFollowsUndoRedoAndItsShape() throws {
        // A handle drag without a modifier follows the point type remembered with the document that Undo or
        // Redo restores, and only on the shape the type was chosen on.
        let (s, id) = try editing()
        let (_, ho, v) = try handles(s, id)
        drag(s, v, v)
        #expect(type0(s) == "smooth")
        drag(s, ho, ho + Vec2(10, -25), Mods(alt: true))
        #expect(type0(s) == "corner")
        s.run("edit.undo")
        #expect(type0(s) == "smooth")
        // A plain drag moves the other handle with the dragged one, as for a smooth point.
        let (_, ho1, _) = try handles(s, id)
        let to = v + Vec2(0, 40)
        drag(s, ho1, to)
        let (hi2, ho2, _) = try handles(s, id)
        #expect((ho2 - to).hypot < 1e-3, "\(ho2)")
        #expect((hi2 - (v - Vec2(0, 40))).hypot < 1e-3, "the other handle mirrors the dragged one: \(hi2)")
        #expect(type0(s) == "smooth")
        // Undo of a Corner Point choice that left the outline as it was: the point is smooth again.
        s.run("shape.pointType", #"{"index": 0, "type": "corner"}"#)
        s.run("edit.undo")
        let to50 = v + Vec2(0, 50)
        drag(s, v + Vec2(0, 40), to50)
        let (hi3, ho3, _) = try handles(s, id)
        #expect((ho3 - to50).hypot < 1e-3, "\(ho3)")
        #expect((hi3 - (v - Vec2(0, 50))).hypot < 1e-3, "the other handle mirrors the dragged one: \(hi3)")
        // Undo of a step that leaves the outline alone keeps a Straight choice, which equal handles cannot
        // show: a plain drag keeps the other handle's length.
        s.run("shape.pointType", #"{"index": 0, "type": "straight"}"#)
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        s.run("edit.undo")
        let to2 = v + Vec2(0, 70)
        drag(s, to50, to2)
        let (hi4, ho4, _) = try handles(s, id)
        #expect((ho4 - to2).hypot < 1e-3, "\(ho4)")
        #expect((hi4 - (v - Vec2(0, 50))).hypot < 1e-3, "the other handle keeps its length: \(hi4)")
        // Redo brings a Corner Point choice back with the step: a plain drag moves one handle.
        s.run("shape.pointType", #"{"index": 0, "type": "corner"}"#)
        s.run("edit.undo")
        s.run("edit.redo")
        drag(s, to2, to2 + Vec2(10, 0))
        let (hi5, ho5, _) = try handles(s, id)
        #expect((ho5 - (to2 + Vec2(10, 0))).hypot < 1e-3, "\(ho5)")
        #expect((hi5 - hi4).hypot < 1e-3, "the other handle stays: \(hi5)")
        // A Point Type choice that fails leaves the remembered type as it was.
        #expect(s.fails("shape.pointType", #"{"index": 99, "type": "smooth"}"#))
        #expect(s.tool.vertexKind == VertexKind(id, 0, 0, "corner"))
        // The remembered type belongs to its shape: the same point of another ellipse stays smooth.
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [100, 300, 200, 100]}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
        let other = ShapeId(try #require(s.run("shape.points").get("id")?.asU32))
        #expect(other != id)
        let (_, ho6, v6) = try handles(s, other)
        drag(s, v6, v6)
        let to6 = v6 + Vec2(0, 40)
        drag(s, ho6, to6)
        let (hi6, _, _) = try handles(s, other)
        #expect((hi6 - (v6 - Vec2(0, 40))).hypot < 1e-3, "the other handle mirrors the dragged one: \(hi6)")
        // Another document can have a shape with the same id: a change of active document forgets the
        // remembered type, and choosing the active document again keeps it.
        s.run("shape.pointType", #"{"index": 0, "type": "corner"}"#)
        s.run("file.new")
        #expect(s.tool.vertexKind == nil)
        s.tool.vertexKind = VertexKind(other, 0, 0, "corner")
        let newDoc = try #require(s.activeIndex)
        s.setActive(newDoc)
        #expect(s.tool.vertexKind != nil)
        s.setActive(0)
        #expect(s.tool.vertexKind == nil)
    }

    // tests.rs edit_points_right_click_picks_the_point_or_the_segment
    @Test func editPointsRightClickPicksThePointOrTheSegment() throws {
        let (s, _) = try editing("rect")
        func picked() -> ((Int, Int)?, (Int, Int)?) { (s.tool.editSegment, s.tool.editVertex) }
        // The middle of the right edge: the segment ending at point 2.
        s.ptr(.contextClick, 300, 150)
        #expect(picked().0.map { $0 == (0, 2) } == true && picked().1 == nil)
        s.ptr(.contextClick, 300, 100)
        #expect(picked().0 == nil && picked().1.map { $0 == (0, 1) } == true)
        s.ptr(.contextClick, 200, 150)
        #expect(picked().0 == nil && picked().1 == nil)
    }

    // tests.rs edit_points_right_click_on_a_handle_keeps_the_picked_vertex
    @Test func editPointsRightClickOnAHandleKeepsThePickedVertex() throws {
        // A right-click on a control handle keeps the point menu: the vertex stays picked.
        let (s, _) = try editing()
        // The right-most point of the ellipse.
        s.ptr(.contextClick, 300, 150)
        let (path, index) = try #require(s.tool.editVertex, "the point is picked")
        let id = try #require(s.tool.editingPoints(s.st))
        let sh = try #require(s.st.shape(id))
        let (hin, hout, _) = try #require(PointsCommands.slideHandles(s.st.doc, s.st.selection, sh, path, index))
        let handle = try #require(hout ?? hin, "a smooth point has a handle")
        let r = s.ptr(.contextClick, handle.x, handle.y)
        #expect(r.get("hit")?.get("kind") == "handle", "\(r.display)")
        #expect(s.tool.editSegment == nil && s.tool.editVertex.map { $0 == (path, index) } == true)
    }
}
