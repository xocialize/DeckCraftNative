// Port of deckcraft crates/pptx/tests/it/locks.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): lock and hidden state (Selection pane), what PowerPoint writes for Lock, and
// what it reads as locked.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

private func png() -> [UInt8] { IT.png(4, 4, (10, 200, 30)) }

private func shape(_ p: inout Presentation, _ name: String, _ x: Double) -> Shape {
    IT.shape(&p, name, x, 40, 80, 60)
}

/// Slide 1 of a blank deck holds: a locked shape, an unlocked one, a hidden locked text box, a
/// locked group (one child unlocked, one hidden), and a locked picture, connector and table.
private func deck() throws -> Presentation {
    var p = newPresentation(nil)
    let imgAdded = p.addMedia("image1.png", "image/png", png())
    let img = try #require(imgAdded, "media")
    var v: [Shape] = []
    var a = shape(&p, "Locked", 0)
    a.locked = true
    v.append(a)
    v.append(shape(&p, "Free", 100))
    var t = shape(&p, "Hidden text", 200)
    t.textBox = true
    t.hidden = true
    t.locked = true
    v.append(t)
    var c1 = shape(&p, "Child locked", 300)
    c1.locked = true
    let c2 = shape(&p, "Child free", 400)
    var c3 = shape(&p, "Child hidden", 500)
    c3.hidden = true
    let gx = Xfrm(300, 40, 280, 60)
    var g = Shape.default
    g.id = ShapeId(p.allocId() ?? 0)
    g.name = "Group"
    g.xfrm = gx
    g.kind = .group(children: [c1, c2, c3], child: gx)
    g.locked = true
    g.hidden = false
    v.append(g)
    var pic = shape(&p, "Pic", 0)
    pic.kind = .picture(fill: PictureFill(media: img))
    pic.locked = true
    v.append(pic)
    var cx = shape(&p, "Conn", 100)
    cx.kind = .connector(start: nil, end: nil)
    cx.geom = .preset("straightConnector1")
    cx.locked = true
    v.append(cx)
    var tb = shape(&p, "Tbl", 200)
    tb.kind = .table(Table(rows: 2, cols: 2, width: 80, rowHeight: 30))
    tb.locked = true
    v.append(tb)
    if !p.slides.isEmpty { p.slides[0].shapes = v }
    return p
}

private func find(_ s: Slide, _ name: String) throws -> Shape {
    try #require(IT.find(s.shapes, name), "no shape \(name)")
}

private func slide1XML(_ bytes: [UInt8]) throws -> String {
    let d = try #require(IT.entries(bytes).first { $0.name == "ppt/slides/slide1.xml" }?.data, "slide1")
    return String(decoding: d, as: UTF8.self)
}

/// The element following `name="…"` up to the end of the object's non-visual properties.
private func nvOf(_ xml: String, _ name: String) throws -> String {
    let i = try #require(xml.byteFind("name=\"\(name)\""), "no \(name)")
    let rest = xml.bytes(i)
    let j = rest.byteFind("<p:nvPr") ?? rest.utf8.count
    return rest.bytes(0, j)
}

@Suite struct IntegrationLocksTests {
    // Rust: it/locks.rs::lock_and_hidden_round_trip
    @Test func lockAndHiddenRoundTrip() throws {
        let p = try deck()
        let q = try PPTX.import(PPTX.export(p))
        let s = q.slides[0]
        for (name, locked, hidden) in [
            ("Locked", true, false),
            ("Free", false, false),
            ("Hidden text", true, true),
            ("Group", true, false),
            ("Child locked", true, false),
            ("Child free", false, false),
            ("Child hidden", false, true),
            ("Pic", true, false),
            ("Conn", true, false),
            ("Tbl", true, false),
        ] {
            let sh = try find(s, name)
            #expect(sh.locked == locked && sh.hidden == hidden, "\(name)")
        }
        // The stacking order of the slide and of the group survives too.
        #expect(s.shapes.map(\.name) == ["Locked", "Free", "Hidden text", "Group", "Pic", "Conn", "Tbl"])
        #expect(try find(s, "Group").children.map(\.name) == ["Child locked", "Child free", "Child hidden"])
    }

    // Rust: it/locks.rs::lock_writes_powerpoints_full_attribute_set
    @Test func lockWritesPowerpointsFullAttributeSet() throws {
        let xml = try slide1XML(PPTX.export(deck()))
        let sp = #"noGrp="1" noRot="1" noMove="1" noResize="1" noEditPoints="1" noAdjustHandles="1" noChangeArrowheads="1" noChangeShapeType="1""#
        let (locked, hidden, free) = try (nvOf(xml, "Locked"), nvOf(xml, "Hidden text"), nvOf(xml, "Free"))
        let (group, conn, pic, tbl) = try (nvOf(xml, "Group"), nvOf(xml, "Conn"), nvOf(xml, "Pic"), nvOf(xml, "Tbl"))
        #expect(locked.has("<a:spLocks \(sp)/>"), "\(locked)")
        #expect(hidden.has("<a:spLocks \(sp)/>"))
        #expect(hidden.has(#"hidden="1""#))
        #expect(!free.has("Locks"), "an unlocked shape writes no locks: \(free)")
        #expect(group.has(#"<a:grpSpLocks noGrp="1" noUngrp="1" noRot="1" noMove="1" noResize="1"/>"#))
        #expect(conn.has("<a:cxnSpLocks \(sp)/>"), "\(conn)")
        #expect(pic.has(#"<a:picLocks noChangeAspect="1" \#(sp) noCrop="1"/>"#), "\(pic)")
        #expect(tbl.has(#"<a:graphicFrameLocks noGrp="1" noDrilldown="1" noMove="1" noResize="1"/>"#))
    }

    /// PowerPoint reads Lock only from the whole set: a lone `noMove`/`noResize` (another tool's
    /// partial lock), or the set without `noGrp`, isn't locked.
    // Rust: it/locks.rs::partial_locks_are_not_lock
    @Test func partialLocksAreNotLock() throws {
        var p = newPresentation(nil)
        let a = shape(&p, "A", 0)
        let b = shape(&p, "B", 100)
        let c = shape(&p, "C", 200)
        var d = shape(&p, "D", 300)
        d.locked = true
        if !p.slides.isEmpty { p.slides[0].shapes = [a, b, c, d] }
        var es = try IT.entries(PPTX.export(p))
        let at = try #require(es.firstIndex { $0.name == "ppt/slides/slide1.xml" }, "slide1")
        let xml = String(decoding: es[at].data, as: UTF8.self)
        func swap(_ xml: String, _ name: String, _ locks: String) throws -> String {
            let i = try #require(xml.byteFind("name=\"\(name)\""), "name")
            let j = try #require(xml.byteFind("<p:cNvSpPr", from: i), "cNvSpPr")
            let k = try #require(xml.byteFind("<p:nvPr", from: j), "nvPr")
            return "\(xml.bytes(0, j))<p:cNvSpPr>\(locks)</p:cNvSpPr>\(xml.bytes(k))"
        }
        var x = try swap(xml, "A", #"<a:spLocks noMove="1" noResize="1"/>"#)
        x = try swap(
            x, "B",
            #"<a:spLocks noRot="1" noMove="1" noResize="1" noEditPoints="1" noAdjustHandles="1" noChangeArrowheads="1" noChangeShapeType="1"/>"#
        )
        x = try swap(
            x, "C", #"<a:spLocks noGrp="1" noRot="1" noMove="1" noResize="1" noEditPoints="1" noAdjustHandles="1" noChangeShapeType="1"/>"#
        )
        es[at].data = Array(x.utf8)
        let q = try PPTX.import(IT.zip(es))
        let s = q.slides[0]
        #expect(!(try find(s, "A")).locked)
        #expect(!(try find(s, "B")).locked)
        #expect(!(try find(s, "C")).locked)
        #expect(try find(s, "D").locked)
    }

    /// Unlocked objects written by PowerPoint keep an empty locks element; that's not locked.
    // Rust: it/locks.rs::empty_locks_element_is_unlocked
    @Test func emptyLocksElementIsUnlocked() throws {
        var p = newPresentation(nil)
        let a = shape(&p, "A", 0)
        if !p.slides.isEmpty { p.slides[0].shapes = [a] }
        var es = try IT.entries(PPTX.export(p))
        let at = try #require(es.firstIndex { $0.name == "ppt/slides/slide1.xml" }, "slide1")
        let xml = String(decoding: es[at].data, as: UTF8.self).replacen("<p:cNvSpPr/>", "<p:cNvSpPr><a:spLocks/></p:cNvSpPr>", 1)
        es[at].data = Array(xml.utf8)
        let q = try PPTX.import(IT.zip(es))
        #expect(!(try find(q.slides[0], "A")).locked)
    }
}
