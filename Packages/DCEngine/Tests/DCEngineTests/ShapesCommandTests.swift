// DCEngineTests — Shape Format: size and position, rotation, flips, fills, outlines, effects and 3-D,
// connectors, freeforms and Ink to Shape.
// Ports the tests of deckcraft crates/engine/src/cmd/shape.rs, cmd/three_d.rs and inkshape.rs, and the shape
// tests of src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). A test that needs
// a command of another group's module (`shape.insert`, `insert.picture`…) runs once that module registers it.
import DCColor
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import Foundation
import Testing

/// The `id` of a command's answer.
func answerId(_ v: JSON) -> ShapeId { ShapeId(UInt32(truncatingIfNeeded: v.get("id")?.asU64 ?? 0)) }

/// A `width` × `height` PNG whose pixel at (x, y) is `f(x, y)` (straight RGBA).
func pngOf(_ width: Int, _ height: Int, _ f: (Int, Int) -> [UInt8]) -> [UInt8] {
    var px: [UInt8] = []
    for y in 0 ..< height { for x in 0 ..< width { px += f(x, y) } }
    return ArtisticCommands.pngBytes(ArtisticCommands.Pixels(width: width, height: height, channels: 4, data: px))
}

/// The first selected shape.
private func selected(_ s: Session) -> Shape? { s.st.selectedShapes.first }

// MARK: - cmd/shape.rs: Size and Position

@Suite("Shapes: Size and Position")
struct ShapeSizePositionTests {
    private func deck() -> (Session, ShapeId) {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let id = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [40.0, 50.0, 200.0, 100.0]}"#))
        return (s, id)
    }

    private func geom(_ s: Session, _ id: ShapeId) -> [Double] {
        let b = s.run("shape.inspect", #"{"id": \#(id.rawValue)}"#).get("box")
        return ["x", "y", "w", "h"].map { b?.get($0)?.asF64 ?? .nan } + [b?.get("rot")?.asF64 ?? 0]
    }

    private func undos(_ s: Session) -> Int { s.st.history.undo.count }

    // shape.rs size_position_tests::sets_position_size_and_rotation_in_one_undo
    @Test(.enabled(if: ported("shape.insert")))
    func setsPositionSizeAndRotationInOneUndo() {
        let (s, id) = deck()
        let n = undos(s)
        s.run("shape.sizePosition", #"{"x": 80.0, "y": 90.0, "w": 240.0, "h": 60.0, "rot": 370.0}"#)
        #expect(geom(s, id) == [80, 90, 240, 60, 10])
        #expect(undos(s) == n + 1)
        #expect(s.st.history.undo.last?.label == "Size and Position…")
        s.run("edit.undo")
        #expect(geom(s, id) == [40, 50, 200, 100, 0])
    }

    // shape.rs size_position_tests::lock_aspect_and_scale_share_one_step
    @Test(.enabled(if: ported("shape.insert")))
    func lockAspectAndScaleShareOneStep() {
        let (s, id) = deck()
        s.run("shape.sizePosition", #"{"w": 300.0, "lockAspect": true}"#)
        #expect(geom(s, id) == [40, 50, 300, 150, 0])
        s.run("edit.undo")
        s.run("shape.sizePosition", #"{"h": 50.0, "lockAspect": true}"#)
        #expect(geom(s, id) == [40, 50, 100, 50, 0])
        s.run("edit.undo")
        s.run("shape.sizePosition", #"{"scaleW": 25.0, "scaleH": 150.0}"#)
        #expect(geom(s, id) == [40, 50, 50, 150, 0])
        s.run("edit.undo")
        s.run("shape.sizePosition", #"{"scaleH": 50.0, "lockAspect": true}"#)
        #expect(geom(s, id) == [40, 50, 100, 50, 0])
        // An explicit width wins over a scale on the same axis.
        s.run("shape.sizePosition", #"{"w": 80.0, "scaleW": 50.0}"#)
        #expect(geom(s, id)[2] == 80)
    }

    // shape.rs size_position_tests::partial_fields_leave_the_rest_and_a_repeat_does_not_undo
    @Test(.enabled(if: ported("shape.insert")))
    func partialFieldsLeaveTheRestAndARepeatDoesNotUndo() {
        let (s, id) = deck()
        var n = undos(s)
        s.run("shape.sizePosition", #"{"y": 12.0, "rot": -90.0}"#)
        #expect(geom(s, id) == [40, 12, 200, 100, 270])
        #expect(undos(s) == n + 1)
        n = undos(s)
        s.run("shape.sizePosition", #"{"x": 40.0, "y": 12.0, "w": 200.0, "h": 100.0, "rot": 270.0}"#)
        #expect(undos(s) == n, "identical geometry is not an undo step")
    }

    // shape.rs size_position_tests::no_fields_opens_the_dialog_without_editing
    @Test(.enabled(if: ported("shape.insert")))
    func noFieldsOpensTheDialogWithoutEditing() throws {
        let (s, id) = deck()
        let n = undos(s)
        s.run("shape.sizePosition")
        #expect(geom(s, id) == [40, 50, 200, 100, 0])
        #expect(undos(s) == n)
        guard case .dialog(let did, let params)? = s.uiRequests.last else {
            Issue.record("expected a dialog, got \(String(describing: s.uiRequests.last))")
            return
        }
        #expect(did == "sizePosition")
        #expect(params.get("w")?.asF64 == 200)
        #expect(params.get("h")?.asF64 == 100)
        #expect(params.get("x")?.asF64 == 40)
        #expect(params.get("rot")?.asF64 == 0)
        #expect(params.get("scaleW")?.asF64 == 100)
        #expect(params.get("lockAspect")?.asBool == false)
    }

    // shape.rs size_position_tests::bad_fields_do_not_edit
    @Test(.enabled(if: ported("shape.insert")))
    func badFieldsDoNotEdit() {
        let (s, id) = deck()
        let n = undos(s)
        for p in [#"{"w": "wide"}"#, #"{"h": -5.0}"#, #"{"scaleW": 0.0}"#, #"{"x": 1e9}"#, #"{"rot": "spin"}"#, #"{"lockAspect": "yes"}"#] {
            do {
                _ = try s.execute("shape.sizePosition", j(p))
                Issue.record("\(p) was accepted")
            } catch {
                #expect("\(error)".contains("sizePosition"), "\(error)")
            }
            #expect(geom(s, id) == [40, 50, 200, 100, 0])
            #expect(undos(s) == n)
        }
    }

    // shape.rs size_position_tests::scale_is_per_shape_and_nothing_selected_is_disabled
    @Test(.enabled(if: ported("shape.insert")))
    func scaleIsPerShapeAndNothingSelectedIsDisabled() {
        let (s, a) = deck()
        let b = answerId(s.run("shape.insert", #"{"preset": "ellipse", "rect": [10.0, 10.0, 40.0, 80.0]}"#))
        s.run("shape.sizePosition", #"{"ids": [\#(a.rawValue), \#(b.rawValue)], "scaleW": 200.0}"#)
        #expect(geom(s, a)[2] == 400)
        #expect(geom(s, a)[3] == 100)
        #expect(geom(s, b)[2] == 80)
        #expect(geom(s, b)[3] == 80)
        #expect(s.st.history.undo.last?.label == "Size and Position…")
        s.run("edit.select", #"{"ids": []}"#)
        do {
            _ = try s.execute("shape.sizePosition", .emptyObject)
            Issue.record("accepted with nothing selected")
        } catch {
            #expect("\(error)".contains("nothing selected"), "\(error)")
        }
    }
}

// MARK: - cmd/shape.rs: groups, twists

@Suite("Shapes: group formatting and rotation gestures")
struct ShapeGroupAndTwistTests {
    /// Four outlined rectangles; the first two grouped, that group grouped with the third. Returns the
    /// three members, the outer group and the fourth rectangle.
    private func nestedGroup() -> (Session, [ShapeId], ShapeId, ShapeId) {
        let s = session()
        var ids: [ShapeId] = []
        for i in 0 ..< 4 {
            ids.append(answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [\#(40 + i * 100), 100, 80, 60]}"#)))
            s.run("shape.line", #"{"width": \#(i + 1), "dash": "dash"}"#)
        }
        func group(_ ids: [ShapeId]) -> ShapeId {
            s.run("edit.select", JSON.object(JSONObject([.init(key: "ids", value: ids.toJSON())])).display)
            return answerId(s.run("arrange.group"))
        }
        let inner = group(Array(ids[..<2]))
        let outer = group([inner, ids[2]])
        return (s, Array(ids[..<3]), outer, ids[3])
    }

    private func docJSON(_ s: Session) -> JSON { s.st.doc.toJSON() }

    // shape.rs tests::group_fill_reaches_nested_members_in_one_undo_step
    @Test(.enabled(if: ported("shape.insert", "arrange.group")))
    func groupFillReachesNestedMembersInOneUndoStep() {
        let (s, members, group, outside) = nestedGroup()
        let before = docJSON(s)
        let untouched = s.st.shape(outside)
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        for id in members { #expect(s.st.shape(id)?.fill == .solid(.rgb(.rgb(255, 0, 0)))) }
        #expect(s.st.selection.shapes == [group])
        #expect(s.st.shape(outside) == untouched)
        let filled = docJSON(s)
        s.run("edit.undo")
        #expect(docJSON(s) == before)
        s.run("edit.redo")
        #expect(docJSON(s) == filled)
        s.run("shape.fill", #"{"none": true}"#)
        #expect(members.allSatisfy { s.st.shape($0)?.fill == .none_ })
        s.run("shape.fill", #"{"reset": true}"#)
        #expect(members.allSatisfy { s.st.shape($0)?.fill == nil })
    }

    // shape.rs tests::group_outline_reaches_members_without_resetting_their_other_properties
    @Test(.enabled(if: ported("shape.insert", "arrange.group")))
    func groupOutlineReachesMembersWithoutResettingTheirOtherProperties() {
        let (s, members, group, outside) = nestedGroup()
        let before = docJSON(s)
        // Explicit ids work even when another object is selected.
        s.run("edit.select", #"{"ids": [\#(outside.rawValue)]}"#)
        s.run("shape.line", ##"{"ids": [\##(group.rawValue)], "color": "#00ff00"}"##)
        for (i, id) in members.enumerated() {
            let line = s.st.shape(id)?.line
            #expect(line?.fill == .solid(.rgb(.rgb(0, 255, 0))))
            #expect(line?.width == Double(i + 1))
            #expect(line?.dash == .preset(name: "dash"))
        }
        #expect(s.st.selection.shapes == [outside])
        let outlined = docJSON(s)
        s.run("edit.undo")
        #expect(docJSON(s) == before)
        s.run("edit.redo")
        #expect(docJSON(s) == outlined)
        s.run("shape.line", #"{"ids": [\#(group.rawValue)], "none": true}"#)
        #expect(members.allSatisfy { s.st.shape($0)?.line?.fill == .none_ })
        s.run("shape.line", #"{"ids": [\#(group.rawValue)], "reset": true}"#)
        #expect(members.allSatisfy { s.st.shape($0)?.line == nil })
    }

    // shape.rs tests::group_fill_transparency_keeps_each_members_inherited_colour
    @Test(.enabled(if: ported("shape.insert", "arrange.group")))
    func groupFillTransparencyKeepsEachMembersInheritedColour() throws {
        let (s, members, group, _) = nestedGroup()
        s.run("shape.fill", ##"{"ids": [\##(members[1].rawValue)], "color": "#00ff00"}"##)
        let ctx = try #require(TextCommands.ctxFor(s.st.doc, s.st.selection))
        let colours: [Rgba] = members.compactMap { id in
            guard let sh = s.st.shape(id), case let (.solid(color)?, ph) = Resolve.fill(ctx, sh) else { return nil }
            return ctx.color(color, ph)
        }
        #expect(colours.count == members.count, "solid theme fills")
        s.run("shape.fill", #"{"ids": [\#(group.rawValue)], "transparency": 0.5}"#)
        for (id, colour) in zip(members, colours) {
            #expect(s.st.shape(id)?.fill == .solid(ColorRef.rgb(colour).with(.alpha(50000))))
        }
    }

    private func rotation(_ s: Session) -> Double {
        s.st.selection.shapes.first.flatMap { s.st.shape($0)?.xfrm?.rot } ?? .nan
    }

    // shape.rs tests::a_twist_is_one_undo_and_wraps_past_a_full_turn
    @Test(.enabled(if: ported("shape.insert")))
    func aTwistIsOneUndoAndWrapsPastAFullTurn() {
        let s = session()
        s.run("edit.select", #"{"ids": []}"#)
        let id = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [40.0, 40.0, 80.0, 40.0]}"#))
        s.run("edit.select", #"{"ids": [\#(id.rawValue)]}"#)
        #expect(Swift.abs(rotation(s)) < 0.01)
        s.run("shape.rotate", #"{"by": 10.0, "gesture": "move"}"#)
        s.run("shape.rotate", #"{"by": 350.0, "gesture": "move"}"#)
        #expect(Swift.abs(rotation(s)) < 0.01, "10 + 350 wraps to 0, got \(rotation(s))")
        s.run("shape.rotate", #"{"by": 20.0, "gesture": "move"}"#)
        s.run("shape.rotate", #"{"gesture": "end", "ids": []}"#)
        #expect(Swift.abs(rotation(s) - 20) < 0.01)
        #expect(s.st.history.undo.last?.label == "Rotation")
        #expect(s.st.interaction == nil)
        s.run("edit.undo")
        #expect(Swift.abs(rotation(s)) < 0.01, "one undo undoes the whole twist")
        s.run("edit.redo")
        #expect(Swift.abs(rotation(s) - 20) < 0.01)
    }

    // shape.rs tests::ending_a_twist_does_not_commit_a_drag
    @Test(.enabled(if: ported("shape.insert")))
    func endingATwistDoesNotCommitADrag() {
        let s = session()
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [10.0, 10.0, 30.0, 30.0]}"#)
        let st = s.st
        st.interaction = Interaction(label: "Move", doc: st.docRef, selection: st.selection, vertexKind: nil)
        s.run("shape.rotate", #"{"gesture": "end", "ids": []}"#)
        #expect(s.st.interaction?.label == "Move")
    }
}

// MARK: - src/tests.rs: shape formatting and geometry

@Suite("Shapes: formatting and geometry")
struct ShapeFormatTests {
    // tests.rs insert_shape_and_format
    @Test(.enabled(if: ported("shape.insert", "format.bold")))
    func insertShapeAndFormat() {
        let s = session()
        let id = answerId(s.run("shape.insert", #"{"preset": "roundRect", "rect": [100, 100, 200, 100], "text": "Hi"}"#))
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        s.run("shape.line", #"{"width": 3, "color": "accent2", "dash": "dash"}"#)
        s.run("shape.rotate", #"{"deg": 30}"#)
        s.run("shape.move", #"{"dx": 10, "dy": -5}"#)
        s.run("format.bold")
        let v = s.run("shape.inspect", #"{"id": \#(id.rawValue)}"#)
        #expect(v.get("box")?.get("x")?.asF64 == 110)
        #expect(v.get("box")?.get("rot")?.asF64 == 30)
        let runs = v.get("shape")?.get("text")?.get("paragraphs")?.at(0)?.get("runs")?.at(0)?.get("props")
        #expect(runs?.get("bold")?.asBool == true)
        // Undo restores step by step.
        for _ in 0 ..< 5 { s.run("edit.undo") }
        #expect(s.run("shape.inspect", #"{"id": \#(id.rawValue)}"#).get("shape")?.get("fill")?.isNull == true)
    }

    // tests.rs connectors_follow_glued_shapes
    @Test(.enabled(if: ported("shape.insert", "edit.delete")))
    func connectorsFollowGluedShapes() {
        let s = session()
        let a = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 100, 50]}"#))
        let b = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [400, 300, 100, 50]}"#))
        let c = answerId(s.run("shape.connect", #"{"from": \#(a.rawValue), "to": \#(b.rawValue), "preset": "bentConnector3"}"#))
        func lineEnds() -> (Point, Point) {
            guard let sh = s.st.shape(c) else { return (.zero, .zero) }
            return Connect.endpoints(Cmd.xfrmOf(s.st.doc, s.st.selection, sh))
        }
        let (p0, p1) = lineEnds()
        // Closest pair: on the boxes either way.
        let sitesA = s.run("shape.sites", #"{"id": \#(a.rawValue)}"#).asArray ?? []
        #expect(sitesA.contains { Swift.abs(($0.at(0)?.asF64 ?? .nan) - p0.x) < 1e-6 && Swift.abs(($0.at(1)?.asF64 ?? .nan) - p0.y) < 1e-6 })
        // Move B: the connector's end follows, its start stays.
        s.run("edit.select", #"{"ids": [\#(b.rawValue)]}"#)
        s.run("shape.move", #"{"dx": 50, "dy": 20}"#)
        let (q0, q1) = lineEnds()
        #expect((q0 - p0).hypot < 1e-6)
        #expect(((q1 - p1) - Vec2(50, 20)).hypot < 1e-6, "\(p1) → \(q1)")
        // Undo puts both back in one step.
        s.run("edit.undo")
        #expect((lineEnds().1 - p1).hypot < 1e-6)
        // Deleting a glued shape unglues that end and leaves the line where it was.
        s.run("edit.select", #"{"ids": [\#(a.rawValue)]}"#)
        s.run("edit.delete")
        guard case .connector(let start, let end)? = s.st.shape(c)?.kind else {
            Issue.record("not a connector")
            return
        }
        #expect(start == nil && end != nil)
    }

    // tests.rs freeform_tools_and_command, the command half and a curve through four points (the drawing
    // tools' half is PointerShapeTests' `freeformToolsAndCommand`)
    @Test(.enabled(if: ported("shape.insert")))
    func freeformToolsAndCommand() {
        let s = session()
        let before = s.st.shapes.count
        // Composite command: one undo step.
        let r = s.run("shape.freeform", #"{"points": [[100, 100], [200, 120], [150, 220]], "closed": true}"#)
        #expect(r.get("id")?.asU64 != nil)
        s.run("edit.undo")
        #expect(s.st.shapes.count == before)
        s.run("edit.redo")
        #expect(s.st.shapes.count == before + 1)
        guard case .custom(let paths)? = s.st.shapes.last?.geom else {
            Issue.record("a freeform")
            return
        }
        #expect(paths[0].d.hasSuffix("Z") && paths[0].d.components(separatedBy: " L ").count - 1 == 2, "\(paths[0].d)")
        // A curve through four points: three cubics.
        let c = answerId(s.run("shape.freeform", #"{"points": [[500, 100], [550, 50], [600, 100], [650, 50]], "smooth": true}"#))
        guard case .custom(let cp)? = s.st.shape(c)?.geom else {
            Issue.record("a freeform")
            return
        }
        #expect(cp[0].d.components(separatedBy: " C ").count - 1 == 3)
    }

    // tests.rs shape_line_sets_compound_and_arrow_sizes
    @Test(.enabled(if: ported("shape.insert")))
    func shapeLineSetsCompoundAndArrowSizes() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "line", "rect": [100, 100, 200, 0]}"#)
        s.run("shape.line", #"{"compound": "thickThin", "head": "oval", "tail": "triangle", "tailSize": "lg"}"#)
        var l = selected(s)?.line
        #expect(l?.compound == .thickThin)
        #expect(l?.head?.kind == "oval" && l?.head?.w == "med")
        #expect(l?.tail?.kind == "triangle" && l?.tail?.w == "lg" && l?.tail?.len == "lg")
        // Changing the arrow keeps its size; an unknown size is ignored; "none" removes it.
        s.run("shape.line", #"{"tail": "stealth", "headSize": "huge"}"#)
        l = selected(s)?.line
        #expect(l?.tail?.kind == "stealth" && l?.tail?.w == "lg")
        #expect(l?.head?.w == "med")
        s.run("shape.line", #"{"head": "none", "compound": "single"}"#)
        l = selected(s)?.line
        #expect(l?.head == nil)
        #expect(l?.compound == .single)
    }

    // tests.rs shape_effects_props_adjust_shadow_glow_and_reflection
    @Test(.enabled(if: ported("shape.insert")))
    func shapeEffectsPropsAdjustShadowGlowAndReflection() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        func fx() -> Effects { selected(s)?.effects ?? Effects() }
        // No shadow yet: the props add an outer one and set it.
        s.run("shape.effects", #"{"shadowProps": {"blur": 10, "dist": 6, "dir": 405, "transparency": 0.25, "color": "accent2"}}"#)
        let sw = try #require(fx().outerShadow)
        #expect(sw.blur == 10 && sw.dist == 6 && sw.dir == 45)
        #expect(Swift.abs(sw.color.alpha - 0.75) < 1e-6)
        // A new colour keeps the transparency; an inner shadow is adjusted in place.
        s.run("shape.effects", #"{"shadowProps": {"color": "accent3"}}"#)
        #expect(Swift.abs((fx().outerShadow?.color.alpha ?? 0) - 0.75) < 1e-6)
        s.run("shape.effects", #"{"shadow": "inner"}"#)
        s.run("shape.effects", #"{"shadowProps": {"blur": 3}}"#)
        #expect(fx().outerShadow == nil)
        #expect(fx().innerShadow?.blur == 3)
        // Glow: size, colour, transparency; size 0 removes it.
        s.run("shape.effects", #"{"glowProps": {"radius": 12, "transparency": 0.5}}"#)
        let g = try #require(fx().glow)
        #expect(g.radius == 12)
        #expect(Swift.abs(g.color.alpha - 0.5) < 1e-6)
        s.run("shape.effects", #"{"glowProps": {"radius": 0}}"#)
        #expect(fx().glow == nil)
        // Reflection: transparency, size, distance, blur; hostile values are clamped or ignored.
        s.run("shape.effects", #"{"reflectionProps": {"transparency": 0.3, "size": 2.0, "dist": 5, "blur": "x"}}"#)
        let r = try #require(fx().reflection)
        #expect(Swift.abs(r.startAlpha - 0.7) < 1e-9)
        #expect(r.endPos == 1 && r.dist == 5 && r.blur == 0.5)
    }

    // tests.rs smooth_corners_makes_a_squircle_outline
    @Test(.enabled(if: ported("shape.insert")))
    func smoothCornersMakesASquircleOutline() throws {
        let s = session()
        let id = answerId(s.run("shape.insert", #"{"preset": "roundRect", "rect": [100, 100, 200, 100]}"#))
        s.run("shape.smoothCorners", #"{"smoothing": 60}"#)
        func d() -> String? {
            if case .custom(let paths)? = s.st.shape(id)?.geom { return paths.first?.d }
            return nil
        }
        // The default roundRect radius is 16.667% of the short side: 16.667 pt, smoothed 60%.
        #expect(d() == Squircle.pathD(200, 100, 16.667, 0.6))
        // The smoothed outline takes a new smoothing with the radius it was drawn with; without a radius, or
        // with another one (it could be any freeform), it is refused.
        s.run("shape.smoothCorners", #"{"smoothing": 100, "radius": 16.667}"#)
        #expect(d() == Squircle.pathD(200, 100, 16.667, 1))
        #expect(s.fails("shape.smoothCorners", #"{"smoothing": 50}"#))
        #expect(s.fails("shape.smoothCorners", #"{"smoothing": 50, "radius": 30}"#))
        s.run("edit.undo")
        #expect(d() == Squircle.pathD(200, 100, 16.667, 0.6))
        // Other shapes are refused.
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [0, 0, 50, 50]}"#)
        #expect(s.fails("shape.smoothCorners", #"{"smoothing": 50}"#))
        // So is a freeform, whatever radius is given.
        s.run("shape.insert", #"{"preset": "rect", "rect": [0, 0, 50, 50]}"#)
        s.run("shape.editPoints", #"{"on": true}"#)
        s.run("shape.editPoints", #"{"on": false}"#)
        if case .custom = s.st.shapes.last?.geom {} else { Issue.record("Edit Points made a freeform") }
        #expect(s.fails("shape.smoothCorners", #"{"smoothing": 50, "radius": 8}"#))
        // The outline round-trips through PPTX as custom geometry.
        let bytes = try FileCommands.saveBytes(s.st.doc, "pptx")
        let back = try FileCommands.openPresentation("x.pptx", bytes)
        #expect(back.slides.flatMap(\.shapes).contains { if case .custom = $0.geom { true } else { false } }, "a custom outline in the saved file")
    }

    // tests.rs shape_picture_fill_options_tile_offset_and_round_trip
    @Test(.enabled(if: ported("shape.insert", "file.openBytes")))
    func shapePictureFillOptionsTileOffsetAndRoundTrip() throws {
        let png = pngOf(4, 4) { x, y in x == 0 && y == 0 ? [255, 0, 0, 255] : [0, 0, 0, 0] }
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        func pf() -> PictureFill? {
            if case .picture(let pf)? = selected(s)?.fill { return pf }
            return nil
        }
        // Options without a picture fill are a no-op, not an error.
        s.run("shape.fill", #"{"pictureProps": {"tile": true}}"#)
        s.run("shape.fill", #"{"picture": "\#(Cmd.base64Encode(png))"}"#)
        s.run("shape.fill", #"{"pictureProps": {"stretch": [0.1, 0.2, 5, "x"]}}"#)
        #expect(pf()?.mode == .stretch(fillRect: [0.1, 0.2, 0.99, 0]))
        s.run("shape.fill", #"{"pictureProps": {"tile": true, "offsetX": 12, "offsetY": -3, "scaleX": 0.5, "scaleY": 50, "align": "ctr", "mirror": "xy", "rotateWithShape": false}}"#)
        // (deckcraft's test passes NaN, which serde_json writes as null.)
        s.run("shape.fill", #"{"pictureProps": {"align": "bogus", "offsetX": null}, "transparency": 0.4}"#)
        let want = PictureMode.tile(tx: 12, ty: -3, sx: 0.5, sy: 10, flip: "xy", align: "ctr")
        let got = try #require(pf())
        #expect(got.mode == want)
        #expect(got.upright)
        #expect(Swift.abs((got.alpha ?? 0) - 0.6) < 1e-9)
        // PPTX round trip keeps the options.
        let bytes = try FileCommands.saveBytes(s.st.doc, "pptx")
        s.run("file.openBytes", JSON.object(JSONObject([.init(key: "name", value: "p.pptx"), .init(key: "data", value: .string(Cmd.base64Encode(bytes)))])).display)
        let back = s.st.doc.slides.flatMap(\.shapes).compactMap { sh -> PictureFill? in
            if case .picture(let pf)? = sh.fill { return pf }
            return nil
        }.first
        #expect(back?.mode == want)
        #expect(back?.upright == true)
        #expect(Swift.abs((back?.alpha ?? 0) - 0.6) < 1e-6)
    }

    // tests.rs shape_three_d_format_and_rotation_round_trip
    @Test(.enabled(if: ported("shape.insert", "file.openBytes")))
    func shapeThreeDFormatAndRotationRoundTrip() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        func fx() -> Effects { selected(s)?.effects ?? Effects() }
        // The old `bevel` key now writes real 3-D XML, so it is drawn and saved.
        s.run("shape.effects", #"{"bevel": "angle"}"#)
        #expect(fx().bevel == "angle")
        #expect(fx().raw3d.map { $0.contains("bevelT") && $0.contains("prst=\"angle\"") } == true)
        s.run("shape.effects", #"{"threeD": {"bevelTopW": 9, "bevelBottom": "circle", "depth": 20, "contour": 2, "material": "metal", "lighting": "harsh", "camera": "isometricTopUp", "rotX": 30, "rotY": -20, "z": 5, "bogus": 1}}"#)
        // Unknown names and non-finite numbers (null here) are ignored.
        s.run("shape.effects", #"{"threeD": {"material": "gold", "depth": null, "camera": 7}}"#)
        let want = ThreeDCommands.Shape3d.parse(try #require(fx().raw3d))
        #expect(want.top == ThreeDCommands.Bevel(preset: "angle", w: 9, h: 6))
        #expect(want.bottom?.preset == "circle")
        #expect(want.depth == 20 && want.contour == 2 && want.z == 5)
        #expect(want.material == "metal" && want.light == "harsh" && want.camera == "isometricTopUp")
        #expect(want.rot == ThreeDCommands.Rotation(30, 340, 0))
        // PPTX save and reopen keeps every setting.
        let bytes = try FileCommands.saveBytes(s.st.doc, "pptx")
        s.run("file.openBytes", JSON.object(JSONObject([.init(key: "name", value: "d.pptx"), .init(key: "data", value: .string(Cmd.base64Encode(bytes)))])).display)
        let back = s.st.doc.slides.flatMap(\.shapes).compactMap { $0.effects?.raw3d }.first
        #expect(back.map(ThreeDCommands.Shape3d.parse) == want)
    }

    // tests.rs three_d_reset_and_flat_shapes_drop_the_xml
    @Test(.enabled(if: ported("shape.insert")))
    func threeDResetAndFlatShapesDropTheXML() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        func fx() -> Effects { selected(s)?.effects ?? Effects() }
        s.run("shape.effects", #"{"threeD": {"rotZ": 15, "depth": 4}}"#)
        #expect(fx().raw3d != nil)
        s.run("shape.effects", #"{"threeD": {"reset": true}}"#)
        #expect(fx().raw3d == nil && fx().bevel == nil)
        // Keeps colours it doesn't model.
        let raw = "<a:scene3d><a:camera prst=\"orthographicFront\"/><a:lightRig rig=\"threePt\" dir=\"t\"/></a:scene3d><a:sp3d extrusionH=\"12700\"><a:extrusionClr><a:srgbClr val=\"FF0000\"/></a:extrusionClr></a:sp3d>"
        var s3 = ThreeDCommands.Shape3d.parse(raw)
        s3.apply(["depth": 3])
        #expect(s3.toXML()?.contains("<a:extrusionClr><a:srgbClr val=\"FF0000\"/></a:extrusionClr>") == true)
    }

    // tests.rs shape_ids_beyond_u32_are_rejected_not_wrapped
    @Test(.enabled(if: ported("shape.insert", "insert.textBox")))
    func shapeIdsBeyondU32AreRejectedNotWrapped() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let a = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [100.0, 100.0, 200.0, 100.0], "text": "Shape A"}"#))
        let b = answerId(s.run("insert.textBox", #"{"rect": [400.0, 100.0, 200.0, 40.0], "text": "Box B"}"#))
        try s.select { _, sel in
            sel.shapes.removeAll()
            sel.text = nil
        }
        func wrap(_ id: ShapeId) -> UInt64 { UInt64(id.rawValue) + (1 << 32) }
        let before = s.st.shapes.count
        #expect(s.fails("shape.connect", #"{"from": \#(wrap(a)), "to": \#(wrap(b))}"#), "connect must reject ids beyond u32")
        #expect(s.fails("shape.sites", #"{"id": \#(wrap(a))}"#), "sites must reject ids beyond u32")
        #expect(s.fails("shape.points", #"{"id": \#(wrap(a))}"#), "points must reject ids beyond u32")
        do {
            _ = try s.execute("shape.movePoint", j(#"{"id": \#(wrap(a)), "index": 0, "x": 1.0, "y": 1.0}"#))
            Issue.record("movePoint accepted an id beyond u32")
        } catch {
            #expect("\(error)".contains("not a valid shape id"), "\(error)")
        }
        #expect(s.st.shapes.count == before, "no connector was created")
        // In-range ids still work.
        #expect(!s.fails("shape.sites", #"{"id": \#(a.rawValue)}"#))
        #expect(!s.fails("shape.connect", #"{"from": \#(a.rawValue), "to": \#(b.rawValue)}"#))
    }

    // tests.rs flipping_a_rotated_shape_mirrors_its_outline
    @Test(.enabled(if: ported("shape.insert")))
    func flippingARotatedShapeMirrorsItsOutline() {
        func corners(_ s: Session, _ id: ShapeId) -> [[Int64]] {
            guard let x = s.st.shape(id)?.xfrm else { return [] }
            let a = x.affine
            return [(0.0, 0.0), (x.w, 0.0), (x.w, x.h), (0.0, x.h)].map { px, py in
                let p = a * Point(px, py)
                return [Int64(rustCast: (p.x * 100).rounded()), Int64(rustCast: (p.y * 100).rounded())]
            }
        }
        func sorted(_ c: [[Int64]]) -> [[Int64]] { c.sorted { $0.lexicographicallyPrecedes($1) } }
        for (cmd, horizontal) in [("arrange.flipHorizontal", true), ("arrange.flipVertical", false)] {
            let s = session()
            let id = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 50]}"#))
            s.run("shape.rotate", #"{"deg": 30}"#)
            let before = corners(s, id)
            // Mirror about the box's centre line (centre is 200, 125).
            let mirrored = before.map { horizontal ? [40000 - $0[0], $0[1]] : [$0[0], 25000 - $0[1]] }
            s.run(cmd)
            #expect(sorted(corners(s, id)) == sorted(mirrored), "\(cmd) of a 30° rotated rectangle is not its mirror image")
            let rot = s.st.shape(id)?.xfrm?.rot ?? .nan
            #expect(Swift.abs(rot - 330) < 1e-9, "\(cmd) negates the rotation, got \(rot)")
            s.run(cmd)
            #expect(sorted(corners(s, id)) == sorted(before), "\(cmd) twice restores the outline")
        }
    }

    // tests.rs shape_geometry_commands_limit_size_and_position
    @Test(.enabled(if: ported("shape.insert")))
    func shapeGeometryCommandsLimitSizeAndPosition() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "moon", "rect": [100, 100, 200, 100]}"#)
        func xfrm() -> Xfrm { selected(s)?.xfrm ?? Xfrm() }
        func within() -> Bool {
            let x = xfrm()
            return [x.w, x.h].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 15_840 } && [x.x, x.y].allSatisfy { $0.isFinite && Swift.abs($0) <= 100_000 }
        }
        s.run("shape.setBounds", #"{"x": 1e100, "y": -1e100, "w": 100000, "h": 1e100}"#)
        #expect(within(), "setBounds stored \(xfrm())")
        s.run("shape.resize", #"{"w": 10, "h": 10}"#)
        s.run("shape.resize", #"{"h": 1e100}"#)
        #expect(within(), "resize stored \(xfrm())")
        s.run("shape.resize", #"{"h": 1e100, "lockAspect": true}"#)
        #expect(within(), "locked resize stored \(xfrm())")
        s.run("shape.move", #"{"x": 1e100, "y": -1e100}"#)
        #expect(within(), "move stored \(xfrm())")
        // A move that overflows to infinity lands on the limit, not back at 0.
        s.run("shape.move", #"{"x": 1e308, "dx": 1e308}"#)
        #expect(xfrm().x == 100_000)
        // A rotated shape resizes about its centre and still stays inside the limit.
        s.run("shape.setBounds", #"{"x": 99000, "y": 0, "w": 10, "h": 10}"#)
        s.run("shape.rotate", #"{"deg": 45}"#)
        s.run("shape.resize", #"{"w": 1e100}"#)
        #expect(within(), "rotated resize stored \(xfrm())")
    }

    // tests.rs opening_a_file_caps_absurd_effect_sizes
    @Test(.enabled(if: ported("shape.insert", "insert.table", "file.openBytes", "file.render")))
    func openingAFileCapsAbsurdEffectSizes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100], "text": "Glow"}"#)
        s.run("shape.effects", #"{"shadow": "outer", "reflection": "tight", "softEdges": 4, "glow": {"radius": 8}}"#)
        s.run("insert.table", #"{"rows": 1, "cols": 1, "rect": [400, 300, 100, 40]}"#)
        let huge = 1e18
        let glow = Glow(color: .rgb(.black), radius: huge)
        try s.edit { doc, sel in
            mutateShapes(&doc, sel) { list in
                for i in list.indices {
                    if var e = list[i].effects {
                        e.glow?.radius = huge
                        e.softEdge = .nan
                        e.outerShadow?.blur = huge
                        e.outerShadow?.dist = huge
                        e.outerShadow?.sx = huge
                        e.reflection = Reflection(blur: huge, startAlpha: 0.5, endAlpha: 0, endPos: 0.5, dist: huge)
                        list[i].effects = e
                    }
                    if case .table(var t) = list[i].kind {
                        for r in t.rows.indices { for c in t.rows[r].cells.indices { for p in t.rows[r].cells[c].text.paragraphs.indices { for k in t.rows[r].cells[c].text.paragraphs[p].runs.indices { t.rows[r].cells[c].text.paragraphs[p].runs[k].props.glow = glow } } } }
                        list[i].kind = .table(t)
                    } else if var body = list[i].text {
                        for p in body.paragraphs.indices { for k in body.paragraphs[p].runs.indices { body.paragraphs[p].runs[k].props.glow = glow } }
                        list[i].text = body
                    }
                }
            }
            // Inherited styles too: the deck default, a master's body style, a text box's own list style,
            // and the theme's effect styles that shape styles point at.
            var level = LevelStyle()
            level.run.glow = glow
            doc.defaultTextStyle.set(0, level)
            doc.masters[0].bodyStyle.set(0, level)
            if !doc.masters[0].theme.format.effects.isEmpty { doc.masters[0].theme.format.effects[0].glow = glow }
            mutateShapes(&doc, sel) { list in
                if let i = list.firstIndex(where: { $0.text != nil }) { list[i].text?.listStyle.set(0, level) }
            }
        }
        for format in ["deckcraft", "pptx"] {
            let bytes = try FileCommands.saveBytes(s.st.doc, format)
            let t = Session()
            _ = try t.execute("file.openBytes", ["name": .string("fx.\(format)"), "data": .string(Cmd.base64Encode(bytes))])
            let st = try t.doc()
            let slide = try #require(st.doc.slides.last)
            var glows: [Double] = []
            walk(slide.shapes) { sh, _ in
                if let e = sh.effects {
                    glows += e.glow.map { [$0.radius] } ?? []
                    #expect(e.softEdge.map { $0 >= 0 && $0 <= 100 } ?? true, "\(format): \(String(describing: e.softEdge))")
                    if let sw = e.outerShadow { #expect(sw.blur <= 200 && sw.dist <= 200 && sw.sx <= 10, "\(format): \(sw)") }
                    if let r = e.reflection { #expect(r.blur <= 100 && r.dist <= 100, "\(format): \(r)") }
                }
                for p in sh.text?.paragraphs ?? [] { glows += p.runs.compactMap { $0.props.glow?.radius } }
                if case .table(let tb) = sh.kind {
                    glows += tb.rows.flatMap(\.cells).flatMap(\.text.paragraphs).flatMap(\.runs).compactMap { $0.props.glow?.radius }
                }
            }
            func inherited(_ ls: ListStyle) -> [Double] { ls.levels.compactMap { $0?.run.glow?.radius } }
            glows += inherited(st.doc.defaultTextStyle)
            let m = st.doc.masters[0]
            for ls in [m.titleStyle, m.bodyStyle, m.otherStyle] { glows += inherited(ls) }
            glows += m.theme.format.effects.compactMap { $0.glow?.radius }
            walk(slide.shapes) { sh, _ in glows += sh.text.map { inherited($0.listStyle) } ?? [] }
            #expect(!glows.isEmpty, "\(format): the glows were kept")
            #expect(glows.allSatisfy { $0 >= 0 && $0 <= 150 }, "\(format): \(glows)")
            // Capped, the slide renders (checked last: uncapped, this is what ran out of memory).
            _ = try t.execute("file.render", ["slide": .integer(st.doc.slides.count - 1), "scale": 0.1])
        }
    }

    @Test("Media playback options and Set as Default Shape")
    func mediaOptionsAndSetDefault() throws {
        let s = session()
        var doc = s.st.doc
        let allocated = doc.allocId()
        let raw = try #require(allocated)
        var clip = Shape.default
        clip.id = ShapeId(raw)
        clip.xfrm = Xfrm(10, 10, 100, 60)
        clip.kind = .media(MediaClip(video: true))
        clip.fill = .solid(.scheme(.accent2))
        doc.slides[0].shapes.append(clip)
        s.st.docRef = DocRef(doc)
        s.st.selection.shapes = [clip.id]
        #expect(s.run("media.options", #"{"autoplay": true, "loop": true, "rewind": true, "acrossSlides": true, "hide": true, "fullScreen": true, "volume": 3, "trimStart": 1500, "trimEnd": 99999999999, "fadeIn": 250, "fadeOut": -4}"#) == .emptyObject)
        guard case .media(let m)? = s.st.shape(clip.id)?.kind else {
            Issue.record("not a clip")
            return
        }
        #expect(m.autoplay && m.loopPlay && m.rewind && m.playAcrossSlides && m.hideWhileNotPlaying && m.fullScreen)
        #expect(m.volume == 1 && m.trimStartMs == 1500 && m.trimEndMs == UInt32.max && m.fadeInMs == 250 && m.fadeOutMs == 0)
        s.run("shape.setDefault")
        #expect(s.defaultLook?.fill == .solid(.scheme(.accent2)))
    }
}

// MARK: - cmd/three_d.rs

@Suite("Shapes: 3-D XML")
struct ThreeDTests {
    static let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#

    /// Preset names from a file are written back into XML; anything outside the format's lists (here, values
    /// that would close the tag and inject markup once unescaped) falls back to the default instead.
    // three_d.rs tests::unknown_presets_from_a_file_are_not_written_back
    @Test func unknownPresetsFromAFileAreNotWrittenBack() throws {
        let evil = "x&quot;/&gt;&lt;a:evil/&gt;"
        let raw = #"<a:scene3d \#(Self.ns)><a:camera prst="\#(evil)"/><a:lightRig rig="\#(evil)" dir="\#(evil)"/></a:scene3d><a:sp3d \#(Self.ns) extrusionH="12700" prstMaterial="\#(evil)"><a:bevelT w="25400" h="25400" prst="\#(evil)"/><a:extrusionClr><a:srgbClr val="\#(evil)"/></a:extrusionClr></a:sp3d>"#
        let s = ThreeDCommands.Shape3d.parse(raw)
        #expect(s.camera == "orthographicFront" && s.light == "threePt" && s.lightDir == "t" && s.material == "warmMatte")
        #expect(s.top?.preset == "circle")
        #expect(s.depth == 1)
        let xml = try #require(s.toXML(), "not flat")
        #expect(!xml.contains("<a:evil"), "\(xml)")
        // What is written is well-formed XML with the colour's value escaped.
        let doc = try parseXML("<r \(Self.ns)>\(xml)</r>")
        #expect(doc.root.path(["sp3d", "extrusionClr", "srgbClr"])?.attr("val") == #"x"/><a:evil/>"#)
    }

    // three_d.rs tests::known_presets_round_trip
    @Test func knownPresetsRoundTrip() throws {
        let raw = #"<a:scene3d \#(Self.ns)><a:camera prst="legacyObliqueTopLeft"><a:rot lat="1200000" lon="600000" rev="0"/></a:camera><a:lightRig rig="legacyHarsh2" dir="tl"/></a:scene3d><a:sp3d \#(Self.ns) z="-12700" contourW="12700" prstMaterial="legacyMetal"><a:bevelB w="38100" h="12700" prst="artDeco"/></a:sp3d>"#
        let s = ThreeDCommands.Shape3d.parse(raw)
        #expect(s.camera == "legacyObliqueTopLeft")
        #expect(s.rot == ThreeDCommands.Rotation(10, 20, 0))
        #expect(s.light == "legacyHarsh2" && s.lightDir == "tl" && s.material == "legacyMetal")
        #expect(s.z == -1 && s.contour == 1)
        #expect(s.bottom == ThreeDCommands.Bevel(preset: "artDeco", w: 3, h: 1))
        #expect(ThreeDCommands.Shape3d.parse(try #require(s.toXML(), "3-D")) == s)
        // Not XML at all: defaults.
        #expect(ThreeDCommands.Shape3d.parse("<a:scene3d><a:camera") == ThreeDCommands.Shape3d.default)
    }
}

// MARK: - inkshape.rs

@Suite("Shapes: Ink to Shape")
struct InkShapeTests {
    private func poly(_ corners: [(Double, Double)], _ perSide: Int) -> [(Double, Double)] {
        var v: [(Double, Double)] = []
        for k in corners.indices {
            let (a, b) = (corners[k], corners[(k + 1) % corners.count])
            for i in 0 ..< perSide {
                let t = Double(i) / Double(perSide)
                // A little hand wobble.
                let wob = Double((i * 7 + k * 3) % 5) * 0.4 - 0.8
                v.append((a.0 + (b.0 - a.0) * t + wob, a.1 + (b.1 - a.1) * t - wob))
            }
        }
        v.append((corners[0].0 + 2, corners[0].1 + 1.5))
        return v
    }

    // inkshape.rs tests::rectangles_ellipses_triangles_and_lines
    @Test func rectanglesEllipsesTrianglesAndLines() throws {
        let r = try #require(InkShape.recognize(poly([(100, 100), (300, 100), (300, 200), (100, 200)], 30)))
        guard case .rect(_, _, let w, let h) = r else {
            Issue.record("\(r)")
            return
        }
        #expect(Swift.abs(w - 200) < 4 && Swift.abs(h - 100) < 4)
        let ell: [(Double, Double)] = (0 ... 80).map { i in
            let a = Double(i) / 80 * 2 * Double.pi
            return (200 + 120 * cos(a) + Double(i % 3) * 0.5, 150 + 60 * sin(a))
        }
        if case .ellipse? = InkShape.recognize(ell) {} else { Issue.record("\(String(describing: InkShape.recognize(ell)))") }
        let up = InkShape.recognize(poly([(200, 50), (300, 250), (100, 250)], 30))
        if case .triangle(_, _, _, _, false)? = up {} else { Issue.record("\(String(describing: up))") }
        let down = InkShape.recognize(poly([(100, 50), (300, 50), (200, 250)], 30))
        if case .triangle(_, _, _, _, true)? = down {} else { Issue.record("\(String(describing: down))") }
        let line: [(Double, Double)] = (0 ... 40).map { i in
            let x: Double = 10 + Double(i) * 5
            let y: Double = 20 + Double(i) * 2 + Double(i % 2) * 0.6
            return (x, y)
        }
        if case .line(let x0, _, let x1, _)? = InkShape.recognize(line), x0 < x1 {} else { Issue.record("\(String(describing: InkShape.recognize(line)))") }
    }

    // inkshape.rs tests::scribbles_dots_and_garbage_stay_ink
    @Test func scribblesDotsAndGarbageStayInk() {
        #expect(InkShape.recognize([]) == nil)
        #expect(InkShape.recognize([(1, 1)]) == nil)
        #expect(InkShape.recognize([(0, 0), (2, 2), (1, 3)]) == nil, "too small")
        let zig: [(Double, Double)] = (0 ..< 40).map { i in (Double(i) * 5, i % 2 == 0 ? 0 : 60) }
        #expect(InkShape.recognize(zig) == nil, "an open zigzag is no line")
        #expect(InkShape.recognize([(.nan, 0), (.infinity, 1)]) == nil)
        let thereAndBack: [(Double, Double)] = (Array(0 ... 20) + Array((0 ... 20).reversed())).map { (Double($0) * 10, 5) }
        #expect(InkShape.recognize(thereAndBack) == nil)
    }

    // inkshape.rs tests::ink_to_shape_command_converts_and_undoes
    @Test func inkToShapeCommandConvertsAndUndoes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let rect = poly([(100, 100), (300, 100), (300, 200), (100, 200)], 30)
        let zig: [(Double, Double)] = (0 ..< 40).map { i in (Double(i) * 5, i % 2 == 0 ? 300 : 360) }
        func mk(_ v: [(Double, Double)]) -> InkStroke {
            InkStroke(points: v.map { Triple($0.0, $0.1, 0.5) }, color: .rgb(200, 0, 0), width: 3, highlighter: false)
        }
        try s.edit { doc, sel in
            guard let raw = doc.allocId() else { throw EngineError.other("id") }
            var ink = Shape.default
            ink.id = ShapeId(raw)
            ink.name = "Ink"
            ink.xfrm = Xfrm(0, 0, 960, 540)
            ink.kind = .ink(strokes: [mk(rect), mk(zig)])
            mutateShapes(&doc, sel) { $0.append(ink) }
        }
        let n0 = s.st.shapes.count
        let r = s.run("draw.inkToShape")
        #expect(r.get("kept")?.asU64 == 1)
        let sh = s.st.shapes
        #expect(sh.count == n0 + 1, "ink keeps the zigzag, one rectangle added")
        #expect(sh.last?.geom.presetName == "rect")
        #expect(sh.last?.line?.width == 3)
        s.run("edit.undo")
        #expect(s.st.shapes.count == n0)
        // Nothing recognisable: a no-op, not an error. Empty slide too.
        s.run("draw.inkToShape")
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.run("draw.inkToShape").get("kept")?.asU64 == 0)
    }
}
