// DCEngineTests — Arrange: group and ungroup, nesting depth, align and distribute, and the drawing guides.
// Ports the arrange tests of deckcraft crates/engine/src/tests.rs and cmd/guides_tests.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors). The Selection pane's ordering tests are in MiscTests.
// guides_tests.rs' `drag_a_guide_drop_it_off_the_slide_and_snap_shapes_to_it` drives the pointer, so it is in
// PointerTests.swift.
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import Foundation
import Testing

/// Runs `body` on a thread with an 8 MB stack (a main thread's) and waits for it.
private final class StackBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

func onMainSizedStack<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
    let box = StackBox<T>()
    let done = DispatchSemaphore(value: 0)
    let work: @Sendable () -> Void = {
        box.result = Result { try body() }
        done.signal()
    }
    let thread = Thread(block: work)
    thread.stackSize = 8 << 20
    thread.start()
    done.wait()
    guard let r = box.result else { throw EngineError.other("no result") }
    return try r.get()
}

@Suite("Shapes: Arrange")
struct ShapesArrangeTests {
    private func box(_ s: Session, _ id: ShapeId, _ key: String) -> Double {
        s.run("shape.inspect", #"{"id": \#(id.rawValue)}"#).get("box")?.get(key)?.asF64 ?? .nan
    }

    private func select(_ s: Session, _ ids: [ShapeId]) {
        s.run("edit.select", JSON.object(JSONObject([.init(key: "ids", value: ids.toJSON())])).display)
    }

    // tests.rs group_ungroup_roundtrip_positions
    @Test(.enabled(if: ported("shape.insert")))
    func groupUngroupRoundtripPositions() {
        let s = session()
        let a = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 50, 50]}"#))
        let b = answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [300, 200, 50, 50]}"#))
        select(s, [a, b])
        let g = answerId(s.run("arrange.group"))
        s.run("shape.move", #"{"id": \#(g.rawValue), "dx": 10}"#)
        s.run("arrange.ungroup", #"{"ids": [\#(g.rawValue)]}"#)
        #expect(Swift.abs(box(s, b, "x") - 310) < 1e-6)
    }

    /// Grouping a group again and again stops at `maxGroupDepth`: past about 39 levels a saved .deckcraft
    /// file no longer opens, and past 64 commands such as format.languageAll miss the text.
    // tests.rs groups_nest_only_as_deep_as_a_saved_file_reopens
    @Test(.enabled(if: ported("shape.insert", "insert.table")))
    func groupsNestOnlyAsDeepAsASavedFileReopens() throws {
        // Thirty-two nested groups take more stack than Swift Testing's threads have in a debug build (the
        // shape-tree walks recurse once per level, as deckcraft's do): run it on a thread with the main
        // thread's 8 MB, as `cargo test`'s 2 MB threads run deckcraft's.
        let (error, unchanged, depth) = try onMainSizedStack { () throws -> (String, Bool, Int) in
            let s = Session.withNew()
            func id(_ v: JSON) -> UInt32 { UInt32(truncatingIfNeeded: v.get("id")?.asU64 ?? 0) }
            _ = try s.execute("slide.new", ["layout": "blank"])
            // A table (deeper in the file than a text box) at the bottom of the nesting.
            var g = id(try s.execute("insert.table", ["rows": 2, "cols": 2]))
            for _ in 0 ..< ArrangeCommands.maxGroupDepth {
                let r = id(try s.execute("shape.insert", j(#"{"preset": "rect", "rect": [10, 10, 20, 20], "text": "deep"}"#)))
                _ = try s.execute("edit.select", ["ids": [.integer(g), .integer(r)]])
                g = id(try s.execute("arrange.group", .emptyObject))
            }
            let r = id(try s.execute("shape.insert", j(#"{"preset": "rect", "rect": [10, 10, 20, 20]}"#)))
            _ = try s.execute("edit.select", ["ids": [.integer(g), .integer(r)]])
            let before = try s.doc().revision
            var refusal = "a group too deep was made"
            do { _ = try s.execute("arrange.group", .emptyObject) } catch { refusal = "\(error)" }
            let unchanged = try s.doc().revision == before
            // The deepest deck the command allows saves and opens again.
            let back = try DeckFormat.load(try DeckFormat.save(try s.doc().doc))
            var depth = 0
            walk(back.slides.last?.shapes ?? []) { sh, d in depth = max(depth, d + (sh.isGroup ? 1 : 0)) }
            return (refusal, unchanged, depth)
        }
        #expect(error.contains("nested at most \(ArrangeCommands.maxGroupDepth)"), "\(error)")
        #expect(unchanged, "a refused group leaves the slide as it was")
        #expect(depth == ArrangeCommands.maxGroupDepth)
    }

    // tests.rs align_and_distribute
    @Test(.enabled(if: ported("shape.insert")))
    func alignAndDistribute() {
        let s = session()
        var ids: [ShapeId] = []
        for (x, y) in [(10.0, 10.0), (200.0, 50.0), (500.0, 90.0)] {
            ids.append(answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [\#(x), \#(y), 40, 40]}"#)))
        }
        select(s, ids)
        s.run("arrange.align", #"{"edge": "top"}"#)
        s.run("arrange.distribute", #"{"dir": "horizontal"}"#)
        #expect(ids.allSatisfy { Swift.abs(box(s, $0, "y") - 10) < 1e-6 })
        let x1 = box(s, ids[1], "x")
        #expect(Swift.abs(x1 - 255) < 1e-6, "\(x1)")
    }

    // tests.rs distribute_wide_middle_stays_in_selection_bounds
    @Test(.enabled(if: ported("shape.insert")))
    func distributeWideMiddleStaysInSelectionBounds() {
        let s = session()
        var ids: [ShapeId] = []
        for (x, w) in [(0.0, 10.0), (20.0, 100.0), (30.0, 10.0)] {
            ids.append(answerId(s.run("shape.insert", #"{"preset": "rect", "rect": [\#(x), 10, \#(w), 10]}"#)))
        }
        select(s, ids)
        s.run("arrange.distribute", #"{"dir": "horizontal", "to": "selection"}"#)
        let xs = ids.map { box(s, $0, "x") }
        #expect(xs == [0, 10, 110], "\(xs)")
    }

    // guides_tests.rs add_move_delete_and_undo
    @Test func addMoveDeleteAndUndo() {
        let s = session()
        #expect(s.run("guide.add", #"{"defaults": true}"#).get("added")?.asU64 == 2)
        #expect(s.run("guide.add", #"{"defaults": true}"#).get("added")?.asU64 == 0, "only when there are none")
        #expect(s.run("guide.add", #"{"vertical": false, "pos": 100}"#).get("index")?.asU64 == 2)
        s.run("guide.move", #"{"index": 2, "pos": 5000}"#)
        #expect(s.st.doc.guides[2].pos == 540, "kept on the slide")
        #expect(s.fails("guide.move", #"{"index": 9, "pos": 1}"#))
        #expect(s.fails("guide.move", #"{"index": 0, "pos": null}"#))
        s.run("guide.delete", #"{"index": 0}"#)
        #expect(s.run("guide.list").asArray?.count == 2)
        s.run("edit.undo")
        #expect(s.st.doc.guides.count == 3)
    }

    // guides_tests.rs guides_round_trip_through_pptx
    @Test func guidesRoundTripThroughPPTX() throws {
        let s = session()
        s.run("guide.add", #"{"vertical": true, "pos": 123.5}"#)
        s.run("guide.add", #"{"vertical": false, "pos": 400}"#)
        let back = try PPTX.import(try PPTX.export(s.st.doc))
        #expect(back.guides == s.st.doc.guides)
        let none = try PPTX.import(try PPTX.export(Presentation.default))
        #expect(none.guides.isEmpty)
    }

    // tests.rs opening_a_file_gives_repeated_shape_ids_fresh_ones
    @Test(.enabled(if: ported("shape.insert", "file.openBytes", "selection.select")))
    func openingAFileGivesRepeatedShapeIdsFreshOnes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        for x in [0, 100, 200, 300] { s.run("shape.insert", #"{"preset": "rect", "rect": [\#(x), 50, 80, 80]}"#) }
        s.run("edit.selectAll")
        s.run("arrange.group")
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [400, 300, 80, 80]}"#)
        let first = try #require(s.st.shapes.first?.id)
        // Every shape, the group's children too, takes the group's id.
        try s.edit { doc, sel in
            mutateShapes(&doc, sel) { list in walkMut(&list) { $0.id = first } }
        }
        #expect(!s.st.doc.validate().isEmpty, "the deck repeats ids")
        let bytes = try FileCommands.saveBytes(s.st.doc, "deckcraft")
        let t = Session()
        _ = try t.execute("file.openBytes", ["name": "dup.deckcraft", "data": .string(Cmd.base64Encode(bytes))])
        let st = try t.doc()
        #expect(st.doc.validate() == [])
        let slide = try #require(st.doc.slides.last)
        var ids: [ShapeId] = []
        walk(slide.shapes) { sh, _ in ids.append(sh.id) }
        #expect(ids.count == 6, "the group, its four children and the ellipse")
        #expect(ids.first == first, "the first shape keeps its id")
        #expect(ids.allSatisfy { $0.rawValue <= st.doc.nextId }, "new ids come from the deck's counter")
        // Each shape can be selected by its own id now.
        let last = try #require(ids.last)
        _ = try t.execute("slide.go", ["index": .integer(st.doc.slides.count - 1)])
        _ = try t.execute("selection.select", ["id": last.toJSON()])
        #expect(try t.doc().selectedShapes.first?.id == last)
    }

    @Test("A child's box in slide space, through flipped and rotated groups")
    func childToParentMapsThroughTheGroup() {
        let group = Xfrm(x: 100, y: 100, w: 200, h: 100, rot: 0, flipH: false, flipV: false)
        let child = Xfrm(0, 0, 100, 50)
        // The child space is half the group's: everything doubles.
        let c = ArrangeCommands.childToParent(group, child, Xfrm(x: 10, y: 10, w: 20, h: 10, rot: 30, flipH: false, flipV: false))
        #expect(c.x == 120 && c.y == 120 && c.w == 40 && c.h == 20 && c.rot == 30)
        var flipped = group
        flipped.flipH = true
        flipped.rot = 90
        let f = ArrangeCommands.childToParent(flipped, child, Xfrm(x: 10, y: 10, w: 20, h: 10, rot: 30, flipH: false, flipV: false))
        #expect(f.flipH && f.rot == 60 && f.w == 40 && f.h == 20)
    }
}
