// DCEngineTests — SmartArt: the outline edits, the layouts and the smartArt.* commands.
// Ports deckcraft crates/engine/src/cmd/smartart.rs's tests and the SmartArt tests of
// crates/engine/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import DCZip
import Foundation
import Testing

private typealias SA = SmartArtCommands

private func lv(_ n: [DiagramNode]) -> [UInt8] { n.map(\.level) }

private func mk(_ levels: [UInt8]) -> [DiagramNode] {
    levels.enumerated().map { i, l in DiagramNode(text: "n\(i)", level: l, picture: nil, assistant: false, title: "") }
}

@Suite("SmartArt layouts and outline")
struct SmartArtLayoutTests {
    // smartart.rs `outline_edits`
    @Test func outlineEdits() {
        var n = mk([0, 1, 1, 0])
        #expect(SA.add(&n, 0, "after", "x") == 3, "after the node's sub-points")
        #expect(lv(n) == [0, 1, 1, 0, 0])
        #expect(SA.add(&n, 0, "below", "y") == 3)
        #expect(lv(n) == [0, 1, 1, 1, 0, 0])
        #expect(SA.add(&n, 0, "above", "z") == 0)
        #expect(lv(n) == [0, 1, 2, 2, 2, 0, 0])
        #expect(SA.remove(&n, 1))
        #expect(lv(n) == [0, 1, 1, 1, 0, 0])
        #expect(!SA.promoteNode(&n, 0))
        #expect(!SA.demoteNode(&n, 0), "nothing above the first node")
        let d2 = SA.demoteNode(&n, 2)
        #expect(!d2 || lv(n)[2] == 2)
        var m = mk([0, 0, 1])
        #expect(SA.demoteNode(&m, 1))
        #expect(lv(m) == [0, 1, 2], "sub-points move with their node")
        #expect(SA.promoteNode(&m, 1))
        #expect(lv(m) == [0, 0, 1])
        var bad = mk([2, 4, 0])
        SA.normalize(&bad)
        #expect(lv(bad) == [0, 1, 0])
        #expect(lv(SA.nodesFromLines(["A", "\tB", "\t\tC", "", "D"])) == [0, 1, 2, 0])
    }

    // smartart.rs `layouts_map_nodes_to_shapes`
    @Test func layoutsMapNodesToShapes() {
        let area = Xfrm(0.0, 0.0, 800.0, 400.0)
        let d = Diagram(kind: "blockList", nodes: mk([0, 1, 1, 0]))
        let v = SA.layout(d, area)
        #expect(v.count == 2)
        #expect(v.first?.text?.paragraphs.count == 3, "sub-points are bullets in their parent's shape")
        let h = Diagram(kind: "hierarchy", nodes: mk([0, 1, 2, 1]))
        let hv = SA.layout(h, area)
        #expect(hv.count == 4 + 3, "a box per node and a line per parent link")
        for sh in hv {
            let x = sh.xfrm ?? Xfrm()
            #expect(x.x >= -0.01 && x.x + x.w <= 800.01 && x.y >= -0.01 && x.y + x.h <= 400.01, "\(x)")
        }
        #expect(SA.layout(Diagram(kind: "cycle"), area).isEmpty)
        // Vertical Bullet List: a bar per top node, its sub-points in a box below.
        let maps = SA.layoutItems(Diagram(kind: "list", nodes: mk([0, 1, 1, 0])), area).map(\.1)
        #expect(maps == [[0], [1, 2], [3]])
    }

    // smartart.rs `every_layout_shows_every_node_inside_its_area`
    @Test func everyLayoutShowsEveryNodeInsideItsArea() {
        let area = Xfrm(50.0, 40.0, 800.0, 400.0)
        for (kind, _) in SA.layouts {
            for style in [""] + SA.styles.map(\.0) {
                let d = Diagram(kind: kind, nodes: mk([0, 1, 0, 0, 1, 0]), style: style, colors: "accent2")
                let items = SA.layoutItems(d, area)
                let shown = items.flatMap(\.1).sorted()
                // Gear draws three gears, as PowerPoint does: the fourth group isn't shown.
                let want = Array(0 ..< (kind == "gear" ? 5 : 6))
                #expect(shown == want, "\(kind)")
                for (sh, _) in items {
                    let x = sh.xfrm ?? Xfrm()
                    let (cx, cy) = (x.x + x.w / 2.0, x.y + x.h / 2.0)
                    #expect(x.w.isFinite && x.h.isFinite && x.w >= 0.0 && x.h >= 0.0, "\(kind) \(x)")
                    #expect((49.0 ... 851.0).contains(cx) && (39.0 ... 441.0).contains(cy), "\(kind) \(x)")
                }
            }
        }
    }

    // smartart.rs `long_words_shrink_to_fit_their_shape`
    @Test func longWordsShrinkToFitTheirShape() {
        let d = Diagram(kind: "pyramid", nodes: SA.nodesFromLines(["Internationalisation", "Build", "Test"]))
        let items = SA.layoutItems(d, Xfrm(0.0, 0.0, 600.0, 300.0))
        func size(_ k: Int) -> Double { items.at(k)?.0.text?.paragraphs.first?.runs.first?.props.size ?? 0.0 }
        #expect(size(0) < 20.0 && size(0) >= 20.0 * SA.minScale - 0.5, "the tip's long word shrinks: \(size(0))")
        #expect(abs(size(1) - 20.0) < 1e-9, "short words keep their size")
    }

    // smartart.rs `colour_variants_pick_accents`
    @Test func colourVariantsPickAccents() {
        func d(_ c: String) -> Diagram { Diagram(colors: c) }
        #expect(SA.accent(d("range45"), 0) == .accent4)
        #expect(SA.accent(d("range45"), 1) == .accent5)
        #expect(SA.accent(d("range45"), 2) == .accent4)
        #expect(SA.accent(d("accent3Grad"), 4) == .accent3)
        #expect(SA.shade(d("accent3Grad"), 1) != nil && SA.shade(d("accent3"), 1) == nil)
    }

    // smartart.rs `assistants_sit_beside_their_parent`
    @Test func assistantsSitBesideTheirParent() {
        var v = mk([0, 1, 1])
        let a = SA.add(&v, 0, "assistant", "Aide")
        #expect(a == 1 && v[1].level == 1 && v[1].assistant)
        let d = Diagram(kind: "orgChart", nodes: v)
        let items = SA.layoutItems(d, Xfrm(0.0, 0.0, 600.0, 400.0))
        func boxed(_ k: Int) -> Xfrm { items.first { $0.1 == [k] }?.0.xfrm ?? Xfrm() }
        let (ceo, aide, kid) = (boxed(0), boxed(1), boxed(2))
        #expect(aide.y > ceo.y && aide.y < kid.y, "the assistant's row is between its parent and the children")
        #expect(aide.x > ceo.x, "beside the parent's trunk")
    }
}

/// The children of group `gid` on the current slide.
private func kids(_ s: Session, _ gid: UInt64) -> [Shape] {
    s.st.shape(ShapeId(UInt32(truncatingIfNeeded: gid)))?.children ?? []
}

private func isPictureFill(_ f: Fill?) -> Bool {
    if case .picture? = f { return true }
    return false
}

@Suite("SmartArt commands")
struct SmartArtCommandTests {
    // tests.rs `smartart_text_pane_edits_regenerate_the_diagram`
    @Test(.enabled(if: ported("insert.smartArt", "text.edit", "text.insert", "edit.undo")))
    func smartartTextPaneEditsRegenerateTheDiagram() throws {
        let s = session()
        let gid = s.run("insert.smartArt", #"{"kind": "blockList", "items": ["Plan", "\tScope", "Build"]}"#)["id"]?.asU64 ?? 0
        #expect(kids(s, gid).count == 2, "Scope is a bullet inside Plan")
        let boxBefore = s.st.shape(ShapeId(UInt32(gid)))?.xfrm

        // Type into the second shape directly, then add a node: the typed text is kept.
        let build = try #require(kids(s, gid).at(1)).id.rawValue
        s.run("text.edit", "{\"id\": \(build), \"end\": true}")
        s.run("text.insert", #"{"text": " it"}"#)
        let r = s.run("smartArt.addNode", "{\"id\": \(gid), \"index\": 2, \"position\": \"after\", \"text\": \"Ship\"}")
        #expect(r["index"]?.asU64 == 3)
        let n = s.run("smartArt.nodes", "{\"id\": \(gid)}")
        let texts = (n["nodes"]?.asArray ?? []).compactMap { $0["text"]?.asStr }
        #expect(texts == ["Plan", "Scope", "Build it", "Ship"])
        #expect(kids(s, gid).count == 3)

        // Demote Ship under Build, promote Scope, remove Plan.
        s.run("smartArt.demote", "{\"id\": \(gid), \"index\": 3}")
        #expect(kids(s, gid).count == 2)
        s.run("smartArt.promote", "{\"id\": \(gid), \"index\": 1}")
        #expect(kids(s, gid).count == 3)
        #expect(s.fails("smartArt.promote", "{\"id\": \(gid), \"index\": 0}"))
        s.run("smartArt.removeNode", "{\"id\": \(gid), \"index\": 0}")
        let n2 = s.run("smartArt.nodes", "{\"id\": \(gid)}")
        let levels = (n2["nodes"]?.asArray ?? []).compactMap { $0["level"]?.asU64 }
        #expect(levels == [0, 0, 1])

        // A child shape also finds its diagram; layouts switch; the box stays put; undo works.
        let child = try #require(kids(s, gid).first).id.rawValue
        s.run("smartArt.layout", "{\"id\": \(child), \"kind\": \"hierarchy\"}")
        #expect(kids(s, gid).count == 3 + 1, "three boxes and one link")
        #expect(s.st.shape(ShapeId(UInt32(gid)))?.xfrm == boxBefore)
        s.run("edit.undo")
        #expect(kids(s, gid).count == 2)

        // The outline survives a .deckcraft save.
        let bytes = try DeckFormat.save(s.st.doc)
        let back = try DeckFormat.load(bytes)
        #expect(back.slides.first?.shapes.contains { $0.diagram?.nodes.count == 3 } == true)
    }

    // tests.rs `smartart_round_trips_through_pptx_as_a_diagram`
    @Test(.enabled(if: ported("insert.smartArt", "slide.go")))
    func smartartRoundTripsThroughPptxAsADiagram() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("insert.smartArt", #"{"kind": "hierarchy", "items": ["CEO", "\tCTO", "\t\tDev", "\tCFO"]}"#)
        s.run("smartArt.style", #"{"style": "intense"}"#)
        s.run("smartArt.colors", #"{"colors": "accent3"}"#)
        let bytes = try PPTX.export(s.st.doc)
        let names = try ZipReader(bytes).entries.map(\.name)
        for part in ["data1", "layout1", "quickStyle1", "colors1", "drawing1"] {
            #expect(names.contains("ppt/diagrams/\(part).xml"), "\(part) in \(names)")
        }
        let back = try PPTX.import(bytes)
        #expect(back.validate().isEmpty)
        let g = try #require(back.slides.at(1)?.shapes.first { $0.diagram != nil }, "a SmartArt group")
        let d = try #require(g.diagram)
        #expect(d.kind == "hierarchy")
        #expect(d.style == "intense" && d.colors == "accent3", "SmartArt style and colours come back")
        #expect(d.imported)
        #expect(d.nodes.map(\.text) == ["CEO", "CTO", "Dev", "CFO"])
        #expect(d.nodes.map(\.level) == [0, 1, 2, 1])
        #expect(g.children.count >= 4, "the cached drawing is read back as shapes")

        // The Text Pane works on the imported diagram, and a second round trip keeps the edit.
        let gid = g.id.rawValue
        let path = FileManager.default.temporaryDirectory.appending(path: "deckcraft-smartart-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).pptx")
        try Data(bytes).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let s2 = Session()
        s2.run("file.open", JSON.object(JSONObject(["path": .string(path.path)])).display)
        s2.run("slide.go", #"{"index": 1}"#)
        s2.run("smartArt.addNode", "{\"id\": \(gid), \"index\": 3, \"position\": \"after\", \"text\": \"COO\"}")
        let again = try PPTX.import(PPTX.export(s2.st.doc))
        let d2 = try #require(again.slides.at(1)?.shapes.lazy.compactMap(\.diagram).first)
        #expect(d2.nodes.last?.text == "COO" && d2.nodes.last?.level == 1)
    }

    // tests.rs `smartart_pictures_3d_styles_and_colour_variants`
    @Test(.enabled(if: ported("insert.smartArt")))
    func smartartPictures3dStylesAndColourVariants() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("insert.smartArt", #"{"kind": "pictureCaption", "items": ["Lakes", "\tBlue", "Hills"]}"#)
        func pics() -> [Shape] {
            let g = s.st.doc.slides.at(1)?.shapes.first { $0.diagram != nil }
            return (g?.children ?? []).filter { $0.name == "SmartArt picture" }
        }
        #expect(pics().count == 2, "one picture placeholder per top-level node")
        #expect(pics().allSatisfy { !isPictureFill($0.fill) })
        // A 1×1 PNG put in through a sub-point lands in its top-level node.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        s.run("smartArt.picture", "{\"index\": 1, \"name\": \"p.png\", \"data\": \"\(png)\"}")
        let p = pics()
        #expect(isPictureFill(p.at(0)?.fill))
        #expect(!isPictureFill(p.at(1)?.fill))
        // Text edits keep the picture; reset removes it.
        s.run("smartArt.addNode", #"{"text": "Woods"}"#)
        #expect(isPictureFill(pics().at(0)?.fill))
        #expect(pics().count == 3)
        // The picture is written to the .pptx drawing.
        let back = try PPTX.import(PPTX.export(s.st.doc))
        #expect(back.validate().isEmpty)
        let bd = try #require(back.slides.at(1)?.shapes.lazy.compactMap(\.diagram).first)
        #expect(bd.kind == "pictureCaption")
        // The node's picture comes back from the data model's blip, as its media.
        let m = try #require(bd.nodes.first?.picture, "node picture read back")
        #expect(back.media(m).map { !$0.data.isEmpty } == true)
        #expect(bd.nodes.dropFirst().allSatisfy { $0.picture == nil })
        s.run("smartArt.picture", #"{"index": 0, "reset": true}"#)
        #expect(pics().allSatisfy { !isPictureFill($0.fill) })

        // 3-D styles carry a lit bevel; colour variants round trip through .pptx.
        s.run("smartArt.style", #"{"style": "cartoon"}"#)
        let g = try #require(s.st.doc.slides.at(1)?.shapes.first { $0.diagram != nil })
        let raws: [String] = g.children.compactMap { $0.effects?.raw3d }
        let raw = try #require(raws.first, "3-D XML")
        #expect(raw.contains("scene3d") && raw.contains("softRound"))
        for (style, colors) in [("polished", "range34"), ("powder", "accent5Grad"), ("brick", "accent2")] {
            s.run("smartArt.style", "{\"style\": \"\(style)\"}")
            s.run("smartArt.colors", "{\"colors\": \"\(colors)\"}")
            let back = try PPTX.import(PPTX.export(s.st.doc))
            let d = try #require(back.slides.at(1)?.shapes.lazy.compactMap(\.diagram).first)
            #expect(d.style == style && d.colors == colors)
        }
    }

    // tests.rs `smartart_converts_to_and_from_text_and_shapes`
    @Test(.enabled(if: ported("insert.textBox", "edit.undo")))
    func smartartConvertsToAndFromTextAndShapes() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("insert.textBox", #"{"text": "Goals\nRevenue\nGrowth"}"#)
        let before = s.st.doc.slides.at(1)?.shapes.count
        let gid = s.run("smartArt.fromText", #"{"kind": "blockList"}"#)["id"]?.asU64 ?? 0
        #expect(s.st.doc.slides.at(1)?.shapes.count == before, "the text box is replaced, not added to")
        let d = try #require(s.st.doc.slides.at(1)?.shapes.lazy.compactMap(\.diagram).first)
        #expect(d.nodes.map(\.text) == ["Goals", "Revenue", "Growth"])

        // Name and Title: titles show in their own box and survive a .pptx round trip.
        s.run("smartArt.layout", "{\"id\": \(gid), \"kind\": \"nameTitleOrgChart\"}")
        s.run("smartArt.setNodes", "{\"id\": \(gid), \"index\": 0, \"title\": \"Lead\"}")
        let back = try PPTX.import(PPTX.export(s.st.doc))
        let bd = try #require(back.slides.at(1)?.shapes.lazy.compactMap(\.diagram).first)
        #expect(bd.kind == "nameTitleOrgChart" && bd.nodes.first?.title == "Lead")

        let tid = s.run("smartArt.toText", "{\"id\": \(gid)}")["id"]?.asU64 ?? 0
        let tb = try #require(s.st.doc.slides.at(1)?.shapes.first { UInt64($0.id.rawValue) == tid })
        #expect(tb.diagram == nil)
        #expect(tb.text?.paragraphs.count == 3)
        // The text keeps the size it had in the graphic.
        #expect(tb.text?.paragraphs.allSatisfy { $0.runs.allSatisfy { ($0.props.size ?? 0) > 10.0 } } == true)

        s.run("edit.undo")
        s.run("smartArt.toShapes", "{\"id\": \(gid)}")
        let g = try #require(s.st.doc.slides.at(1)?.shapes.first { UInt64($0.id.rawValue) == gid })
        #expect(g.diagram == nil && !g.children.isEmpty, "a plain group of the same shapes")
    }
}
