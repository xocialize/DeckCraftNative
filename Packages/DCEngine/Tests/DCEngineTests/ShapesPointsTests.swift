// DCEngineTests — Edit Points: the freeform conversion, moved, added and deleted points, point and segment
// types, handles, and open and closed outlines.
// Ports the Edit Points tests of deckcraft crates/engine/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors). The tests that drag, click or right-click with the pointer are in
// PointerPointsTests.swift, apart from `edit_points_types_and_handles` and
// `edit_points_right_click_records_the_place_on_the_segment`, whole here.
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing

@Suite("Shapes: Edit Points")
struct ShapesPointsTests {
    private func points(_ s: Session) -> [[Double]] {
        (s.run("shape.points").get("paths")?.at(0)?.asArray ?? []).map { [$0.at(0)?.asF64 ?? .nan, $0.at(1)?.asF64 ?? .nan] }
    }

    private func pts(_ v: [[Double]]) -> [[Double]] { v }

    private func near(_ a: [Double], _ b: [Double]) -> Bool { Swift.abs(a[0] - b[0]) < 1e-6 && Swift.abs(a[1] - b[1]) < 1e-6 }

    private func d(_ s: Session) -> String {
        if case .custom(let paths)? = s.st.selectedShapes.first?.geom { return paths.first?.d ?? "" }
        Issue.record("not a freeform")
        return ""
    }

    private func handles(_ s: Session, _ id: ShapeId, _ i: Int) -> (Point?, Point?, Point)? {
        guard let sh = s.st.shape(id) else { return nil }
        return PointsCommands.slideHandles(s.st.doc, s.st.selection, sh, 0, i)
    }

    private func rect(_ s: Session) {
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
    }

    // tests.rs edit_points_turns_a_preset_into_a_freeform_and_moves_adds_deletes
    @Test(.enabled(if: ported("shape.insert", "file.openBytes")))
    func editPointsTurnsAPresetIntoAFreeformAndMovesAddsDeletes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        let id = try #require(s.run("shape.editPoints").get("editing")?.asU32)
        if case .custom = s.st.selectedShapes.first?.geom {} else { Issue.record("a freeform") }
        var v = points(s)
        #expect(v.count == 4, "\(v)")
        #expect(near(v[0], [100, 100]) && near(v[2], [300, 200]))
        // Drag the bottom-right corner out: the box grows to fit, other points stay on the slide.
        s.run("shape.movePoint", #"{"index": 2, "x": 350, "y": 260}"#)
        v = points(s)
        #expect(near(v[0], [100, 100]) && near(v[2], [350, 260]) && near(v[3], [100, 200]), "\(v)")
        var x = try #require(s.st.selectedShapes.first?.xfrm)
        #expect(Swift.abs(x.w - 250) < 1e-6 && Swift.abs(x.h - 160) < 1e-6)
        // Move the first point up-left: the box moves with it.
        s.run("shape.movePoint", #"{"index": 0, "x": 80, "y": 90}"#)
        x = try #require(s.st.selectedShapes.first?.xfrm)
        #expect(Swift.abs(x.x - 80) < 1e-6 && Swift.abs(x.y - 90) < 1e-6)
        #expect(near(points(s)[0], [80, 90]))
        // Add a point in the middle of the closing edge (from the last point back to the first) and of the
        // top edge, then delete one.
        s.run("shape.addPoint", #"{"segment": 0}"#)
        #expect(points(s).count == 5)
        s.run("shape.addPoint", #"{"segment": 1, "t": 0.5}"#)
        v = points(s)
        #expect(v.count == 6)
        let mid: [Double] = [(80.0 + 300.0) / 2.0, (90.0 + 100.0) / 2.0]
        #expect(near(v[1], mid), "\(v)")
        s.run("shape.deletePoint", #"{"index": 1}"#)
        s.run("shape.deletePoint", #"{"index": 0}"#)
        #expect(points(s).count == 4)
        // Bad input is an error, not a crash; an outline keeps two points. (deckcraft's test passes NaN,
        // which serde_json writes as null.)
        #expect(s.fails("shape.movePoint", #"{"index": 99, "x": 1, "y": 1}"#))
        #expect(s.fails("shape.movePoint", #"{"index": 0, "x": null, "y": 1}"#))
        s.run("shape.deletePoint", #"{"index": 0}"#)
        s.run("shape.deletePoint", #"{"index": 0}"#)
        #expect(s.fails("shape.deletePoint", #"{"index": 0}"#))
        // Each edit is one undo step.
        s.run("edit.undo")
        #expect(points(s).count == 3)
        // It saves as custom geometry.
        let bytes = try FileCommands.saveBytes(s.st.doc, "pptx")
        s.run("file.openBytes", JSON.object(JSONObject([.init(key: "name", value: "e.pptx"), .init(key: "data", value: .string(Cmd.base64Encode(bytes)))])).display)
        let back = s.st.doc.slides.flatMap(\.shapes).first { $0.id.rawValue == id }?.geom
        if case .custom? = back {} else { Issue.record("\(String(describing: back))") }
    }

    // tests.rs edit_points_path_parse_and_write
    @Test func editPointsPathParseAndWrite() {
        let segs = PointsCommands.parse("M 0 0 L 10 0 C 10 5 5 10 0 10 Z junk L")
        // The closing edge is made explicit; its end is not a vertex of its own.
        #expect(segs.count == 5)
        if case .l = segs[3] {} else { Issue.record("\(segs[3])") }
        #expect(PointsCommands.vertices(segs) == [0, 1, 2])
        #expect(PointsCommands.write(PointsCommands.parse(PointsCommands.write(segs))) == PointsCommands.write(segs))
        #expect(PointsCommands.parse("C 1 2 3").isEmpty)
    }

    // tests.rs edit_points_types_and_handles
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsTypesAndHandles() throws {
        let s = session()
        rect(s)
        func type1() -> String? { s.run("shape.points").get("types")?.at(0)?.at(1)?.asStr }
        #expect(type1() == "corner")
        // A rectangle's corner has no handles until it is a smooth point.
        let id = ShapeId(try #require(s.run("shape.points").get("id")?.asU32))
        let h0 = try #require(handles(s, id, 1))
        #expect(h0.0 == nil && h0.1 == nil)
        #expect(s.fails("shape.moveHandle", #"{"index": 1, "side": "out", "x": 0, "y": 0}"#))
        s.run("shape.pointType", #"{"index": 1, "type": "smooth"}"#)
        #expect(type1() == "smooth")
        var h = try #require(handles(s, id, 1))
        var (hi, ho, v) = (try #require(h.0), try #require(h.1), h.2)
        #expect(Swift.abs((hi - v).hypot - (ho - v).hypot) < 1e-6)
        #expect(((hi - v).normalize + (ho - v).normalize).hypot < 1e-6)
        // Dragging one handle of a smooth point mirrors the other.
        let to = v + Vec2(40, 10)
        s.run("shape.moveHandle", #"{"index": 1, "side": "out", "x": \#(to.x), "y": \#(to.y)}"#)
        h = try #require(handles(s, id, 1))
        (hi, ho, v) = (try #require(h.0), try #require(h.1), h.2)
        #expect((ho - to).hypot < 1e-6 || type1() == "smooth")
        #expect(((hi - v) + (ho - v)).hypot < 1e-6)
        // Straight: in line, lengths kept; corner: independent.
        s.run("shape.pointType", #"{"index": 1, "type": "straight"}"#)
        h = try #require(handles(s, id, 1))
        let far = h.2 + (try #require(h.1) - h.2) * 3
        s.run("shape.moveHandle", #"{"index": 1, "side": "out", "x": \#(far.x), "y": \#(far.y), "type": "straight"}"#)
        #expect(type1() == "straight")
        s.run("shape.pointType", #"{"index": 1, "type": "corner"}"#)
        h = try #require(handles(s, id, 1))
        let (hi0, v0) = (try #require(h.0), h.2)
        let off = v0 + Vec2(0, -30)
        // (The pointer passes the type last chosen for the vertex, as here.)
        s.run("shape.moveHandle", #"{"index": 1, "side": "out", "x": \#(off.x), "y": \#(off.y), "type": "corner"}"#)
        h = try #require(handles(s, id, 1))
        #expect(((try #require(h.0) - h.2) - (hi0 - v0)).hypot < 1e-6)
        #expect(type1() == "corner")
        #expect(s.fails("shape.pointType", #"{"index": 1, "type": "wobbly"}"#))
        // With the pointer: click a vertex to show its handles, drag one (one undo step).
        s.run("shape.pointType", #"{"index": 2, "type": "smooth"}"#)
        let h2 = try #require(handles(s, id, 2))
        let ho2 = try #require(h2.1)
        s.ptr(.down, h2.2.x, h2.2.y, tol: 0)
        s.ptr(.up, h2.2.x, h2.2.y, tol: 0)
        #expect(s.tool.editVertex.map { $0 == (0, 2) } == true)
        s.ptr(.down, ho2.x, ho2.y, tol: 0)
        s.ptr(.drag, ho2.x + 20, ho2.y + 20, tol: 0)
        s.ptr(.up, ho2.x + 20, ho2.y + 20, tol: 0)
        let moved = try #require(handles(s, id, 2)?.1)
        #expect((moved - (ho2 + Vec2(20, 20))).hypot < 1e-3, "\(moved)")
        s.run("edit.undo")
        let back = try #require(handles(s, id, 2)?.1)
        #expect((back - ho2).hypot < 1e-3)
    }

    // tests.rs edit_points_straight_and_curved_segments
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsStraightAndCurvedSegments() throws {
        let s = session()
        rect(s)
        let before = s.run("shape.points").get("paths")
        func segments() -> JSON? { s.run("shape.points").get("segments")?.at(0) }
        // The closing edge ends on the first point, so it is segment 0; an outline starts straight.
        #expect(segments() == j(#"["straight", "straight", "straight", "straight"]"#))
        // Curved Segment: the top edge gets handles at its thirds, so it looks the same until dragged.
        s.run("shape.segmentType", #"{"segment": 1, "type": "curved"}"#)
        #expect(segments() == j(#"["straight", "curved", "straight", "straight"]"#))
        #expect(s.run("shape.points").get("paths") == before)
        let id = ShapeId(try #require(s.run("shape.points").get("id")?.asU32))
        let (out0, in1) = (try #require(handles(s, id, 0)?.1), try #require(handles(s, id, 1)?.0))
        #expect((out0 - Point(100 + 200.0 / 3, 100)).hypot < 1e-3, "\(out0)")
        #expect((in1 - Point(100 + 400.0 / 3, 100)).hypot < 1e-3, "\(in1)")
        // Bend it, then Straight Segment drops its handles; the points stay where they are.
        s.run("shape.moveHandle", #"{"index": 1, "side": "in", "x": \#(in1.x), "y": 60}"#)
        let bent = s.run("shape.points").get("paths")
        s.run("shape.segmentType", #"{"segment": 1, "type": "straight"}"#)
        #expect(segments()?.at(1)?.asStr == "straight")
        #expect(handles(s, id, 0)?.1 == nil && handles(s, id, 1)?.0 == nil)
        #expect(s.run("shape.points").get("paths") == before)
        // Each change is one undo step.
        s.run("edit.undo")
        #expect(segments()?.at(1)?.asStr == "curved")
        #expect(s.run("shape.points").get("paths") == bent)
        // The closing edge is segment 0.
        s.run("shape.segmentType", #"{"segment": 0, "type": "curved"}"#)
        #expect(segments()?.at(0)?.asStr == "curved")
        // Asking for the type a segment already has is not an undo step.
        let depth = s.st.history.undo.count
        s.run("shape.segmentType", #"{"segment": 2, "type": "straight"}"#)
        #expect(s.st.history.undo.count == depth)
        #expect(s.fails("shape.segmentType", #"{"segment": 9, "type": "curved"}"#))
        #expect(s.fails("shape.segmentType", #"{"segment": 1, "type": "wavy"}"#))
    }

    // tests.rs edit_points_open_and_close_path
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsOpenAndClosePath() {
        let s = session()
        rect(s)
        #expect(s.fails("shape.closePath", #"{"index": 0}"#), "the outline is closed already")
        // A point type remembered for handle drags belongs to the old numbering: opening forgets it.
        s.tool.vertexKind = s.tool.editPoints.map { VertexKind($0, 0, 2, "straight") }
        #expect(s.tool.vertexKind != nil)
        // Open Path at the bottom-right corner: the outline now starts and ends there, as two points.
        s.run("shape.openPath", #"{"index": 2}"#)
        #expect(!d(s).contains("Z"), "\(d(s))")
        #expect(s.tool.vertexKind == nil)
        #expect(points(s) == pts([[300, 200], [100, 200], [100, 100], [300, 100], [300, 200]]))
        #expect(s.fails("shape.openPath", #"{"index": 1}"#), "the outline is open already")
        // The two ends move apart; Close Path joins them with a straight segment.
        s.run("shape.movePoint", #"{"index": 4, "x": 320, "y": 180}"#)
        s.run("shape.closePath", #"{"index": 1}"#)
        #expect(d(s).hasSuffix("Z"), "\(d(s))")
        #expect(points(s).count == 5)
        #expect(s.run("shape.points").get("segments")?.at(0)?.at(0)?.asStr == "straight")
        // Ends that meet become one point again.
        s.run("edit.undo")
        s.run("edit.undo")
        s.run("shape.closePath", #"{"index": 4}"#)
        #expect(points(s) == pts([[300, 200], [100, 200], [100, 100], [300, 100]]))
        // Opening at the first point keeps the order.
        s.run("shape.openPath", #"{"index": 0}"#)
        #expect(points(s) == pts([[300, 200], [100, 200], [100, 100], [300, 100], [300, 200]]))
        #expect(s.fails("shape.openPath", #"{"index": 9}"#))
    }

    // tests.rs edit_points_delete_segment_opens_the_outline
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsDeleteSegmentOpensTheOutline() {
        let s = session()
        rect(s)
        // A point type remembered for handle drags belongs to the old numbering: deleting forgets it.
        s.run("shape.pointType", #"{"index": 2, "type": "straight"}"#)
        s.run("edit.undo")
        // The right edge ends at point 2: the outline now starts at its end and ends at its start.
        s.run("shape.deleteSegment", #"{"segment": 2}"#)
        #expect(!d(s).contains("Z"), "\(d(s))")
        #expect(s.tool.vertexKind == nil)
        #expect(points(s) == pts([[300, 200], [100, 200], [100, 100], [300, 100]]))
        #expect(s.run("shape.points").get("segments")?.at(0) == j(#"[null, "straight", "straight", "straight"]"#))
        // A segment of an open outline cannot be deleted, as in PowerPoint, where the item is grayed out.
        #expect(s.fails("shape.deleteSegment", #"{"segment": 1}"#))
        // One undo step brings the closed outline back.
        s.run("edit.undo")
        #expect(d(s).hasSuffix("Z"), "\(d(s))")
        #expect(points(s) == pts([[100, 100], [300, 100], [300, 200], [100, 200]]))
        // The closing edge ends at point 0.
        s.run("shape.deleteSegment", #"{"segment": 0}"#)
        #expect(!d(s).contains("Z"), "\(d(s))")
        #expect(points(s) == pts([[100, 100], [300, 100], [300, 200], [100, 200]]))
        #expect(s.fails("shape.deleteSegment", #"{"segment": 0}"#), "the first point of an open outline ends no segment")
        #expect(s.fails("shape.deleteSegment", #"{"segment": 9}"#))
    }

    /// Adding or deleting a point renumbers the points: a point type remembered for handle drags is
    /// forgotten, as it is when the outline opens or closes.
    // tests.rs edit_points_add_and_delete_point_forget_the_point_type
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsAddAndDeletePointForgetThePointType() {
        let s = session()
        rect(s)
        s.run("shape.pointType", #"{"index": 2, "type": "straight"}"#)
        #expect(s.tool.vertexKind != nil)
        s.run("shape.addPoint", #"{"segment": 1}"#)
        #expect(s.tool.vertexKind == nil)
        s.run("shape.pointType", #"{"index": 2, "type": "straight"}"#)
        s.run("shape.deletePoint", #"{"index": 1}"#)
        #expect(s.tool.vertexKind == nil)
    }

    /// A right click on a segment records where on it the click was, for Add Point.
    // tests.rs edit_points_right_click_records_the_place_on_the_segment
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsRightClickRecordsThePlaceOnTheSegment() throws {
        let s = session()
        rect(s)
        func pick(_ x: Double, _ y: Double) -> (Int, Int, Double)? {
            s.ptr(.contextClick, x, y)
            guard let (path, seg) = s.tool.editSegment, let t = s.tool.editSegmentT else { return nil }
            return (path, seg, t)
        }
        // A quarter of the way along the top edge, which ends at point 1.
        let (path, seg, t) = try #require(pick(150, 100))
        #expect(path == 0 && seg == 1)
        #expect(Swift.abs(t - 0.25) < 1e-9, "\(t)")
        s.run("shape.addPoint", #"{"segment": 1, "t": \#(t)}"#)
        #expect(s.run("shape.points").get("paths")?.at(0) == j("[[100.0, 100.0], [150.0, 100.0], [300.0, 100.0], [300.0, 200.0], [100.0, 200.0]]"))
        // Between the places the hit test samples (40% of the way along the edge that now ends at point 2)
        // and on a curve, the new point goes where the click was.
        func added(_ x: Double, _ y: Double) throws -> (Double, [Double]) {
            let (path, seg, t) = try #require(pick(x, y), "a segment is picked")
            let before = (s.run("shape.points").get("paths")?.at(path)?.asArray ?? []).map { [$0.at(0)?.asF64 ?? 0, $0.at(1)?.asF64 ?? 0] }
            s.run("shape.addPoint", #"{"path": \#(path), "segment": \#(seg), "t": \#(t)}"#)
            let after = (s.run("shape.points").get("paths")?.at(path)?.asArray ?? []).map { [$0.at(0)?.asF64 ?? 0, $0.at(1)?.asF64 ?? 0] }
            let new = try #require(after.first { !before.contains($0) }, "a new point")
            return (Foundation.hypot(new[0] - x, new[1] - y), new)
        }
        var (miss, new) = try added(210, 100)
        #expect(miss < 1e-3, "\(new)")
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [100, 300, 200, 100]}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
        // 30° up from the right-most point; the outline is a Bézier copy of the ellipse.
        let a = 30.0 * Double.pi / 180
        (miss, new) = try added(200 + 100 * cos(a), 350 - 50 * sin(a))
        #expect(miss < 0.1, "\(new)")
    }

    /// No segment ends at the first point of an open outline, also when a closed outline follows it in the
    /// same path: Add Point there returns an error and leaves the path unchanged.
    // tests.rs edit_points_add_point_at_the_start_of_an_open_outline
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsAddPointAtTheStartOfAnOpenOutline() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        // The donut's two rings are one path.
        s.run("shape.insert", #"{"preset": "donut", "rect": [100, 100, 200, 200]}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
        s.run("shape.openPath", #"{"index": 0}"#)
        let before = d(s)
        #expect(before.components(separatedBy: "Z").count - 1 == 1, "\(before)")
        #expect(s.fails("shape.addPoint", #"{"segment": 0}"#))
        #expect(d(s) == before)
    }

    /// Edit Points turns a preset into a freeform: one undo step, so Undo brings the preset back (and leaves
    /// Edit Points), Redo the freeform; leaving Edit Points adds no step.
    // tests.rs edit_points_conversion_is_one_undo_step
    @Test(.enabled(if: ported("shape.insert")))
    func editPointsConversionIsOneUndoStep() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "star5", "rect": [100, 100, 200, 100]}"#)
        func preset() -> Bool { s.st.selectedShapes.first?.geom.presetName != nil }
        s.run("shape.editPoints", #"{"on": true}"#)
        #expect(!preset(), "Edit Points made a freeform")
        #expect(s.tool.editingPoints(s.st) != nil)
        s.run("shape.editPoints", #"{"on": false}"#)
        // Leaving changed nothing, so the next undo is the conversion itself.
        s.run("edit.undo")
        #expect(preset(), "Undo brings the star back")
        s.run("edit.redo")
        #expect(!preset(), "Redo makes it a freeform again")
        // Undo while still editing points ends Edit Points: the star has no points to edit.
        s.run("edit.undo")
        s.run("shape.editPoints", #"{"on": true}"#)
        s.run("edit.undo")
        #expect(preset())
        #expect(s.tool.editingPoints(s.st) == nil)
        // A freeform needs no conversion: entering Edit Points again adds no undo step.
        s.run("edit.redo")
        s.run("shape.editPoints", #"{"on": false}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
        s.run("edit.undo")
        #expect(preset(), "the only step was the conversion")
    }

    @Test("Points of grouped, locked and line shapes are refused")
    func pointsOfGroupedLockedAndLineShapesAreRefused() throws {
        let s = session()
        var doc = s.st.doc
        func add(_ geom: Geom, _ kind: ShapeKind = .shape, locked: Bool = false) throws -> ShapeId {
            let raw = doc.allocId()
            var sh = Shape.default
            sh.id = ShapeId(try #require(raw))
            sh.xfrm = Xfrm(10, 10, 100, 50)
            sh.geom = geom
            sh.kind = kind
            sh.locked = locked
            doc.slides[0].shapes.append(sh)
            return sh.id
        }
        let line = try add(.preset("line"))
        let locked = try add(.preset("rect"), locked: true)
        let rect = try add(.preset("rect"))
        s.st.docRef = DocRef(doc)
        for (id, why) in [(line, "only a shape with an outline has points to edit"), (locked, "the shape is locked")] {
            do {
                _ = try s.execute("shape.editPoints", ["id": id.toJSON(), "on": true])
                Issue.record("\(id) accepted")
            } catch {
                #expect("\(error)".contains(why), "\(error)")
            }
        }
        s.st.selection.shapes = [rect, line]
        do {
            _ = try s.execute("shape.movePoint", j(#"{"index": 0, "x": 1, "y": 1}"#))
            Issue.record("two selected shapes accepted")
        } catch {
            #expect("\(error)".contains("select one shape"), "\(error)")
        }
    }
}
