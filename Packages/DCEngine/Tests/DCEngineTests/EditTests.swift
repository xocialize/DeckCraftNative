// DCEngineTests — the Edit menu: copy and paste of shapes and slides (media, connectors, animations and
// names follow), Paste Special, Duplicate, Delete, select all, and rich text on the clipboard.
// Ports the clipboard tests of deckcraft crates/engine/src/tests.rs and cmd/richclip.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCRender
import Foundation
import Testing

/// Slide 0 of `s` gets a picture of `bytes`, a box, and a connector from the picture to the box.
/// Returns (picture, box, connector).
private func populate(_ s: Session, _ bytes: [UInt8]) throws -> (ShapeId, ShapeId, ShapeId) {
    var doc = s.st.doc
    let mediaRaw = doc.addMedia("p.png", "image/png", bytes)
    let media = try #require(mediaRaw)
    let r1 = doc.allocId(), r2 = doc.allocId(), r3 = doc.allocId()
    let (p, b, c) = (ShapeId(try #require(r1)), ShapeId(try #require(r2)), ShapeId(try #require(r3)))
    let x = Xfrm(10, 10, 50, 50)
    var pic = Shape.default
    pic.id = p
    pic.kind = .picture(fill: PictureFill(media: media))
    pic.xfrm = x
    var box = Shape.default
    box.id = b
    box.xfrm = x
    var con = Shape.default
    con.id = c
    con.kind = .connector(start: Pair(p, 1), end: Pair(b, 3))
    con.xfrm = x
    doc.slides[0].shapes += [pic, box, con]
    s.st.docRef = DocRef(doc)
    return (p, b, c)
}

private func select(_ s: Session, _ ids: [ShapeId]) {
    s.st.selection.slides.removeAll()
    s.st.selection.shapes = ids
}

private func shape(_ s: Session, _ slide: Int, _ id: ShapeId) -> Shape? {
    s.st.doc.slides.at(slide)?.shapes.first { $0.id == id }
}

private func pictureBytes(_ s: Session, _ sh: Shape?) -> [UInt8]? {
    guard case .picture(let fill)? = sh?.kind else { return nil }
    return s.st.doc.media(fill.media)?.data
}

private func id(_ v: JSON?) -> ShapeId { ShapeId(UInt32(truncatingIfNeeded: v?.asU64 ?? 0)) }

/// A 4 by 4 PNG of one colour.
private func solidPNG(_ rgb: [UInt8]) -> [UInt8] {
    ImageEncoding.png(RenderImage(width: 4, height: 4, pixels: Array(repeating: [rgb[0], rgb[1], rgb[2], 255], count: 16).flatMap { $0 }))
}

/// Slide 0 of `s` gets a table whose first cell, background and second cell's picture bullet each use a
/// picture of their own, and a transition sound. `tag` starts the bytes of each. Returns the table.
private func pictureTable(_ s: Session, _ tag: String) throws -> ShapeId {
    var doc = s.st.doc
    let cellRaw = doc.addMedia("cell.png", "image/png", Array("\(tag) cell".utf8))
    let cell = try #require(cellRaw)
    let backRaw = doc.addMedia("back.png", "image/png", Array("\(tag) background".utf8))
    let back = try #require(backRaw)
    let bulletRaw = doc.addMedia("bullet.png", "image/png", Array("\(tag) bullet".utf8))
    let bullet = try #require(bulletRaw)
    let soundRaw = doc.addMedia("sound.wav", "audio/wav", Array("\(tag) sound".utf8))
    let sound = try #require(soundRaw)
    var t = Table(rows: 1, cols: 2, width: 200, rowHeight: 40)
    t.background = .picture(PictureFill(media: back))
    t.rows[0].cells[0].fill = .picture(PictureFill(media: cell))
    t.rows[0].cells[1].text = TextBody.fromText("item")
    t.rows[0].cells[1].text.paragraphs[0].props.bullet = .picture(media: bullet)
    let raw = doc.allocId()
    let id = ShapeId(try #require(raw))
    var sh = Shape.default
    sh.id = id
    sh.kind = .table(t)
    sh.xfrm = Xfrm(10, 10, 200, 40)
    doc.slides[0].shapes.append(sh)
    var tr = Transition.default
    tr.kind = "fade"
    tr.sound = sound
    doc.slides[0].transition = tr
    s.st.docRef = DocRef(doc)
    return id
}

/// The bytes behind a table's first cell fill, background and second cell's bullet.
private func tablePictures(_ s: Session, _ sh: Shape?) -> [[UInt8]] {
    guard case .table(let t)? = sh?.kind,
          case .picture(let cell)? = t.rows[0].cells[0].fill,
          case .picture(let back)? = t.background,
          case .picture(let media)? = t.rows[0].cells[1].text.paragraphs[0].props.bullet else { return [] }
    let doc = s.st.doc
    return [cell.media, back.media, media].map { doc.media($0)?.data ?? [] }
}

private func deckPictures(_ tag: String) -> [[UInt8]] { ["cell", "background", "bullet"].map { Array("\(tag) \($0)".utf8) } }

@Suite("Edit")
struct EditTests {
    @Test func pasteIntoADeckWithACollidingMediaIdShowsTheCopiedPicture() throws {
        let a = Session.withNew()
        let b = Session.withNew()
        let (pa, _, _) = try populate(a, Array("deck a picture".utf8))
        let (pb, _, _) = try populate(b, Array("deck b picture".utf8))
        #expect(pictureBytes(a, shape(a, 0, pa)) == Array("deck a picture".utf8))
        select(a, [pa])
        a.run("edit.copy")
        b.clipboard = a.clipboard
        b.st.selection.shapes.removeAll()
        let r = b.run("edit.paste")
        let new = id(r.get("ids")?.at(0))
        #expect(pictureBytes(b, shape(b, 0, new)) == Array("deck a picture".utf8))
        // Deck b's own picture is untouched.
        #expect(pictureBytes(b, shape(b, 0, pb)) == Array("deck b picture".utf8))
    }

    @Test(.enabled(if: ported("insert.picture")))
    func pasteAsPictureIntoADeckWithACollidingMediaIdDrawsTheCopiedPicture() throws {
        let a = Session.withNew()
        let b = Session.withNew()
        let (pa, _, _) = try populate(a, solidPNG([255, 0, 0]))
        _ = try populate(b, solidPNG([0, 0, 255]))
        select(a, [pa])
        a.run("edit.copy")
        b.clipboard = a.clipboard
        b.st.selection.shapes.removeAll()
        let r = b.run("edit.pasteSpecial", #"{"as": "picture"}"#)
        let pid = id(r.get("id") ?? r.get("ids")?.at(0))
        let bytes = try #require(pictureBytes(b, shape(b, 0, pid)))
        let img = try #require(Images.decode(bytes))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        // The middle of the drawing is the middle of the copied picture.
        #expect(Array(img.pixels[i ..< i + 4]) == [255, 0, 0, 255])
    }

    @Test(.enabled(if: ported("insert.picture")))
    func picturesInsertedAfterAPasteFromAnotherDeckGetMediaIdsOfTheirOwn() throws {
        let a = Session.withNew()
        let b = Session.withNew()
        let (pa, _, _) = try populate(a, Array("deck a picture".utf8))
        // Deck a's picture uses a media id above its shape ids that deck b has not handed out yet.
        var doc = a.st.doc
        let high = MediaId(doc.nextId + 20)
        doc.nextId = high.rawValue
        doc.media[0].id = high
        if let k = doc.slides[0].shapes.firstIndex(where: { $0.id == pa }), case .picture(var fill) = doc.slides[0].shapes[k].kind {
            fill.media = high
            doc.slides[0].shapes[k].kind = .picture(fill: fill)
        }
        a.st.docRef = DocRef(doc)
        #expect(pictureBytes(a, shape(a, 0, pa)) == Array("deck a picture".utf8))
        select(a, [pa])
        a.run("edit.copy")
        b.clipboard = a.clipboard
        b.st.selection.shapes.removeAll()
        let pasted = id(b.run("edit.paste").get("ids")?.at(0))
        var inserted: [(ShapeId, [UInt8])] = []
        for i in 0 ..< 12 {
            let png = solidPNG([UInt8(i), 0, 0])
            let r = b.run("insert.picture", "{\"data\": \"\(Cmd.base64Encode(png))\", \"name\": \"a.png\"}")
            inserted.append((id(r.get("id")), png))
        }
        #expect(pictureBytes(b, shape(b, 0, pasted)) == Array("deck a picture".utf8))
        for (i, png) in inserted { #expect(pictureBytes(b, shape(b, 0, i)) == png) }
        let ids = b.st.doc.media.map(\.id)
        #expect(Set(ids).count == ids.count, "media ids are unique")
    }

    @Test func aTablePastedIntoAnotherDeckKeepsItsCellBackgroundAndBulletPictures() throws {
        let a = Session.withNew()
        let b = Session.withNew()
        let ta = try pictureTable(a, "a")
        let tb = try pictureTable(b, "b")
        select(a, [ta])
        a.run("edit.copy")
        b.clipboard = a.clipboard
        b.st.selection.shapes.removeAll()
        let new = id(b.run("edit.paste").get("ids")?.at(0))
        #expect(tablePictures(b, shape(b, 0, new)) == deckPictures("a"))
        // Deck b's own table is untouched.
        #expect(tablePictures(b, shape(b, 0, tb)) == deckPictures("b"))
    }

    @Test func aSlidePastedIntoAnotherDeckKeepsItsTablePicturesAndTransitionSound() throws {
        let a = Session.withNew()
        let b = Session.withNew()
        _ = try pictureTable(a, "a")
        let tb = try pictureTable(b, "b")
        a.run("edit.copy", #"{"scope": "slides"}"#)
        b.clipboard = a.clipboard
        b.run("edit.paste", #"{"scope": "slides"}"#)
        let pasted = b.st.doc.slides[1]
        let table = pasted.shapes.first { if case .table = $0.kind { return true } else { return false } }
        #expect(tablePictures(b, table) == deckPictures("a"))
        let sound = try #require(pasted.transition?.sound)
        #expect(b.st.doc.media(sound)?.data == Array("a sound".utf8))
        // Deck b's own slide is untouched.
        #expect(tablePictures(b, shape(b, 0, tb)) == deckPictures("b"))
    }

    @Test func copiedConnectorsFollowCopiedEndsAndDetachFromTheRest() throws {
        let s = Session.withNew()
        let (p, b, c) = try populate(s, Array("x".utf8))
        // Both ends copied: the copy connects the copies.
        let r = s.run("edit.duplicate", "{\"ids\": [\(p), \(b), \(c)]}")
        let ids = (r.get("ids")?.asArray ?? []).map { id($0) }
        try #require(ids.count == 3)
        guard case .connector(let start, let end)? = shape(s, 0, ids[2])?.kind else {
            Issue.record("not a connector")
            return
        }
        #expect(start == Pair(ids[0], 1) && end == Pair(ids[1], 3))
        // Only the connector copied: it doesn't stay glued to the originals.
        select(s, [c])
        s.run("edit.copy")
        s.st.selection.shapes.removeAll()
        let only = id(s.run("edit.paste").get("ids")?.at(0))
        guard case .connector(let s2, let e2)? = shape(s, 0, only)?.kind else {
            Issue.record("not a connector")
            return
        }
        #expect(s2 == nil && e2 == nil)
        // The original keeps its ends.
        guard case .connector(let s3, _)? = shape(s, 0, c)?.kind else {
            Issue.record("not a connector")
            return
        }
        #expect(s3 == Pair(p, 1))
    }

    @Test func duplicatedAndPastedSlidesRetargetAnimationsAndTriggers() throws {
        let s = Session.withNew()
        let (p, b, _) = try populate(s, Array("x".utf8))
        var doc = s.st.doc
        var anim = Animation.default
        anim.shape = p
        anim.trigger = b
        anim.effect = "fade"
        doc.slides[0].animations.append(anim)
        s.st.docRef = DocRef(doc)
        func resolves(_ slide: Int) -> (ShapeId, ShapeId)? {
            let sl = s.st.doc.slides[slide]
            guard let a = sl.animations.first, let t = a.trigger else { return nil }
            #expect(sl.shapes.contains { $0.id == a.shape } && sl.shapes.contains { $0.id == t })
            return (a.shape, t)
        }
        s.run("slide.duplicate", #"{"index": 0}"#)
        let (t, tr) = try #require(resolves(1))
        #expect(t != p && tr != b)
        s.run("edit.copy", #"{"scope": "slides"}"#)
        s.run("edit.paste", #"{"scope": "slides"}"#)
        let (t2, tr2) = try #require(resolves(s.st.doc.slides.count - 1))
        #expect(t2 != t && tr2 != tr)
        // Save and reload keeps them resolving.
        let bytes = try FileCommands.saveBytes(s.st.doc, "deckcraft")
        let back = try DeckFormat.load(bytes)
        for sl in back.slides {
            for a in sl.animations {
                #expect(sl.shapes.contains { $0.id == a.shape })
                #expect(a.trigger.map { t in sl.shapes.contains { $0.id == t } } ?? true)
            }
        }
    }

    @Test func copyAndPasteSlidesWithinADeck() {
        let s = session()
        s.run("slide.new", #"{"layout": "titleOnly", "title": "Second"}"#)
        let copied = s.run("edit.copy", #"{"scope": "slides"}"#)
        #expect(copied.get("text") == "Second")
        s.run("slide.go", #"{"index": 0}"#)
        #expect(s.run("edit.paste") == ["slides": 1], "with no shape selected the clipboard's slides are pasted")
        #expect(s.st.doc.slides.map(\.title) == ["", "Second", "Second"])
        #expect(s.st.selection.slide == 1)
        #expect(s.st.doc.validate().isEmpty)
    }

    @Test func copyingShapesTakesTheirInheritedBoxes() throws {
        let s = session()
        s.run("edit.selectAll")
        let copied = s.run("edit.copy")
        #expect(copied.get("text") == "\n")
        #expect(s.clipboard.shapes.count == 2 && s.clipboard.shapes.allSatisfy { $0.xfrm != nil })
        #expect(s.clipboard.sourceTheme != nil)
        let r = s.run("edit.paste")
        let ids = (r.get("ids")?.asArray ?? []).map { id($0) }
        try #require(ids.count == 2)
        // Pasted on the same slide: offset, no longer placeholders, and renamed where the name was taken.
        let pasted = ids.compactMap { s.st.shape($0) }
        #expect(pasted.allSatisfy { $0.ph == nil })
        #expect(pasted.map(\.name) == ["Title 3", "Subtitle 4"])
        let orig = s.clipboard.shapes[0].xfrm?.x ?? 0
        #expect(pasted[0].xfrm?.x == orig + s.prefs.duplicateOffset)
        s.run("edit.paste")
        #expect(s.st.selectedShapes.first?.xfrm?.x == orig + 2 * s.prefs.duplicateOffset, "each paste offsets further")
    }

    @Test func duplicateNamesTheCopiesAndDeleteRemovesThem() {
        let s = session()
        let title = s.st.currentSlide?.shapes.first?.id ?? .default
        s.st.selection.shapes = [title]
        let r = s.run("edit.duplicate")
        let copy = id(r.get("ids")?.at(0))
        #expect(s.st.shape(copy)?.name == "Title 1 copy")
        s.run("edit.duplicate")
        #expect(s.st.selectedShapes.first?.name == "Title 1 copy", "a copy of a copy is not `copy copy`")
        #expect(s.run("edit.delete") == ["deleted": 1])
        #expect(s.run("edit.delete", "{\"ids\": [\(copy)]}") == ["deleted": 1])
        #expect(s.st.shape(copy) == nil)
        s.run("edit.undo")
        #expect(s.st.shape(copy) != nil)
    }

    @Test func removeShapesTakesGroupDescendantsAndEmptiedGroups() {
        func leaf(_ i: UInt32) -> Shape {
            var s = Shape.default
            s.id = ShapeId(i)
            return s
        }
        var group = Shape.default
        group.id = ShapeId(10)
        group.kind = .group(children: [leaf(11), leaf(12)], child: Xfrm())
        var shapes = [leaf(1), group]
        #expect(EditCommands.removeShapes(&shapes, [ShapeId(11)]) == 1)
        #expect(shapes.count == 2 && shapes[1].children.count == 1)
        #expect(EditCommands.removeShapes(&shapes, [ShapeId(12)]) == 2, "the emptied group goes too")
        #expect(shapes.map(\.id) == [ShapeId(1)])
    }

    @Test func reidGivesFreshIdsAndRemapsAnimations() throws {
        var doc = Presentation.default
        var shapes = doc.slides[0].shapes
        let old = shapes.map(\.id)
        let map = try EditCommands.reid("t", &doc, &shapes)
        #expect(shapes.map(\.id) != old && map.count == old.count)
        var a1 = Animation.default
        a1.shape = old[0]
        a1.trigger = ShapeId(999)
        var a2 = Animation.default
        a2.shape = ShapeId(998)
        var anims = [a1, a2]
        EditCommands.remapAnimations(&anims, map)
        #expect(anims.count == 1 && anims[0].shape == map[old[0]] && anims[0].trigger == nil)
    }

    @Test func bakeThemeReplacesThemeColoursAndFonts() throws {
        var sh = Shape.default
        sh.fill = .solid(color: ColorRef.scheme(.accent1).with(.lumMod(50_000)))
        var body = TextBody.fromText("x")
        body.paragraphs[0].runs[0].props.font = "+mj-lt"
        sh.text = body
        var shapes = [sh]
        let scheme = try #require(builtinThemes().first).colors
        var fonts = FontScheme.default
        fonts.major.latin = "Heading Face"
        EditCommands.bakeTheme(&shapes, scheme, fonts)
        #expect(shapes[0].fill == .solid(color: ColorRef(base: .rgb(rgb: scheme.get(.accent1)), mods: [.lumMod(50_000)])))
        #expect(shapes[0].text?.paragraphs[0].runs[0].props.font == "Heading Face")
    }

    @Test func pasteSpecialRefusesAnUnknownKind() {
        let s = session()
        #expect(s.fails("edit.pasteSpecial", #"{"as": "bogus"}"#))
        #expect(s.fails("edit.pasteSpecial", #"{"as": "picture"}"#), "nothing copied to draw")
    }

    @Test func selectAndSelectionPaneSelect() {
        let s = session()
        let ids = s.st.currentSlide?.shapes.map(\.id) ?? []
        #expect(s.run("edit.select", "{\"ids\": [\(ids[0]), 424242]}") == ["selected": [.integer(ids[0].rawValue)]])
        s.run("edit.select", "{\"ids\": [\(ids[1])], \"add\": true}")
        #expect(s.st.selection.shapes == ids)
        s.run("edit.select", "{\"ids\": [\(ids[0])], \"toggle\": true}")
        #expect(s.st.selection.shapes == [ids[1]])
        s.run("selection.select", "{\"id\": \(ids[0]), \"add\": true}")
        #expect(s.st.selection.shapes == [ids[1], ids[0]])
        #expect(s.fails("selection.select", #"{"id": 424242}"#))
        s.run("edit.deselect")
        #expect(s.st.selection.shapes.isEmpty)
    }

    @Test func hideAllAndShowAllAreUndoable() {
        let s = session()
        s.run("selection.hideAll")
        #expect(s.st.currentSlide?.shapes.allSatisfy(\.hidden) == true)
        let n = s.st.history.undo.count
        s.run("selection.hideAll")
        #expect(s.st.history.undo.count == n, "nothing left to hide: no undo step")
        s.run("selection.showAll")
        #expect(s.st.currentSlide?.shapes.allSatisfy { !$0.hidden } == true)
        s.run("edit.undo")
        #expect(s.st.currentSlide?.shapes.allSatisfy(\.hidden) == true)
    }

    // MARK: Ported tests that need other modules' commands

    @Test(.enabled(if: ported("shape.insert")))
    func clipboardCopyPasteShapesAndSlides() {
        let s = session()
        s.run("shape.insert", #"{"preset": "ellipse", "rect": [10, 10, 50, 50]}"#)
        s.run("edit.copy")
        s.run("edit.paste")
        s.run("edit.paste")
        #expect(s.st.currentSlide?.shapes.count == 2 + 3)
        s.run("edit.copy", #"{"scope": "slides"}"#)
        s.run("edit.paste", #"{"scope": "slides"}"#)
        #expect(s.st.doc.slides.count == 2)
        #expect(s.st.doc.validate().isEmpty)
    }

    @Test(.enabled(if: ported("shape.insert", "shape.rename")))
    func pastedShapesGetTheNextAutomaticName() throws {
        let s = session()
        func names() -> [String] { s.st.currentSlide?.shapes.map(\.name) ?? [] }
        let before = names().count
        s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 50, 50]}"#)
        let auto = names()[before]
        s.run("edit.copy")
        s.run("edit.paste")
        s.run("edit.paste")
        let all = names()
        let base = String(auto[..<(auto.lastIndex(of: " ") ?? auto.endIndex)])
        #expect(all[before + 1] == "\(base) \(before + 2)")
        #expect(all[before + 2] == "\(base) \(before + 3)")
        // A name the user chose is not an automatic one and stays on the copy.
        let sel = try #require(s.st.selection.shapes.first)
        s.run("shape.rename", "{\"id\": \(sel), \"name\": \"Hero\"}")
        s.run("edit.copy")
        s.run("edit.paste")
        #expect(names().last == "Hero")
    }

    @Test(.enabled(if: ported("shape.insert")))
    func pastingAfterADeletedShapeDoesNotRepeatAName() {
        let s = session()
        var ids: [ShapeId] = []
        for _ in 0 ..< 3 {
            s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 50, 50]}"#)
            ids.append(s.st.selection.shapes[0])
        }
        s.run("edit.delete", "{\"ids\": [\(ids[1])]}")
        s.run("slide.go", #"{"index": 0}"#)
        s.st.selection.shapes = [ids[2]]
        s.run("edit.copy")
        s.run("edit.paste")
        let all = s.st.currentSlide?.shapes.map(\.name) ?? []
        #expect(Set(all).count == all.count, "\(all)")
    }

    @Test(.enabled(if: ported("shape.insert")))
    func pastingOnAnotherSlideKeepsNamesSoMorphStillPairsThem() {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [0, 0, 20, 20]}"#)
        let first = s.st.selection.shapes[0]
        s.run("shape.insert", #"{"preset": "rect", "rect": [10, 10, 50, 50]}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [200, 200, 80, 80]}"#)
        s.run("edit.delete", "{\"ids\": [\(first)]}")
        s.run("edit.selectAll")
        s.run("edit.copy")
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("edit.paste")
        let (a, b) = (s.st.doc.slides[1], s.st.doc.slides[2])
        #expect(a.shapes.map(\.name) == b.shapes.map(\.name))
    }

    @Test(.enabled(if: ported("shape.insert", "shape.fill", "design.theme", "insert.picture", "insert.textBox")))
    func pasteSpecialKeepsSourceLookPictureOrText() throws {
        let s = session()
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100], "text": "Q3 plan"}"#)
        s.run("shape.fill", #"{"color": "accent1"}"#)
        let sl = try #require(s.st.currentSlide)
        let oldAccent = try #require(s.st.doc.masterFor(sl)).master.scheme.get(.accent1)
        s.run("edit.copy")
        s.run("design.theme", #"{"name": "Ember"}"#)
        func fillOf(_ v: JSON?) -> Fill? { s.st.shape(id(v))?.fill }
        let dest = s.run("edit.pasteSpecial", #"{"as": "destinationTheme"}"#)
        if case .solid(let c)? = fillOf(dest.get("ids")?.at(0)), case .scheme = c.base {} else { Issue.record("not a theme colour") }
        let keep = s.run("edit.pasteSpecial", #"{"as": "keepSource"}"#)
        if case .solid(let c)? = fillOf(keep.get("ids")?.at(0)) { #expect(c.base == .rgb(rgb: oldAccent)) } else { Issue.record("no solid fill") }
        // The clipboard itself still holds the theme-following shape.
        if case .solid(let c)? = s.clipboard.shapes[0].fill, case .scheme = c.base {} else { Issue.record("the clipboard changed") }
        let pic = s.run("edit.pasteSpecial", #"{"as": "picture"}"#)
        let pid = id(pic.get("id") ?? pic.get("ids")?.at(0))
        let sh = try #require(s.st.shape(pid))
        guard case .picture(let fill) = sh.kind else {
            Issue.record("not a picture")
            return
        }
        #expect(s.st.doc.media(fill.media)?.contentType == "image/png")
        let x = try #require(sh.xfrm)
        #expect(abs(x.w - 216) < 1 && abs(x.h - 116) < 1, "\(x)")
        let n = s.st.currentSlide?.shapes.count ?? 0
        s.run("edit.pasteSpecial", #"{"as": "text"}"#)
        #expect(s.st.currentSlide?.shapes.count == n + 1)
        #expect(s.st.currentSlide?.shapes.last?.text?.text == "Q3 plan")
    }

    @Test(.enabled(if: ported("shape.insert", "shape.move", "shape.inspect")))
    func duplicatingAMovedCopyRepeatsTheMove() {
        let s = session()
        let a = s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 50, 50]}"#).get("id")?.asU64 ?? 0
        func boxed(_ i: UInt64) -> (Double, Double) {
            let v = s.run("shape.inspect", "{\"id\": \(i)}")
            return (v.get("box")?.get("x")?.asF64 ?? .nan, v.get("box")?.get("y")?.asF64 ?? .nan)
        }
        func dup() -> UInt64 { s.run("edit.duplicate").get("ids")?.at(0)?.asU64 ?? 0 }
        let off = s.prefs.duplicateOffset
        let b = dup()
        #expect(boxed(b) == (100 + off, 100 + off))
        s.run("shape.move", "{\"dx\": \(80 - off), \"dy\": \(-off)}")
        #expect(boxed(b) == (180, 100))
        let c = dup()
        #expect(boxed(c) == (260, 100))
        let d = dup()
        #expect(boxed(d) == (340, 100))
        s.st.selection.shapes = [ShapeId(UInt32(a))]
        let e = dup()
        #expect(boxed(e) == (100 + off, 100 + off))
        s.run("edit.undo")
        let g = s.run("shape.insert", #"{"preset": "ellipse", "rect": [400, 300, 40, 40]}"#).get("id")?.asU64 ?? 0
        #expect(g == e, "the new shape reuses the undone copy's id")
        let h = dup()
        #expect(boxed(h) == (400 + off, 300 + off))
        s.run("edit.undo")
        s.st.selection.shapes = [ShapeId(UInt32(d))]
        let f = dup()
        #expect(boxed(f) == (340 + off, 100 + off))
        #expect(s.st.doc.validate().isEmpty)
    }

    @Test(.enabled(if: ported("insert.textBox")))
    func htmlPasteKeepsBoldAndTheRichPath() throws {
        let ext = session()
        ext.run("edit.paste", #"{"text": "Hello", "html": "<p style=\"font-weight: bold\">Hello</p>"}"#)
        let pasted = ext.st.currentSlide?.shapes.first { $0.text?.text == "Hello" }?.text
        #expect(pasted?.paragraphs[0].runs[0].props.bold == true)
        let mismatched = session()
        mismatched.run("edit.paste", #"{"text": "Hi", "html": "<b>Nope</b>"}"#)
        let plain = mismatched.st.currentSlide?.shapes.first { $0.text?.text == "Hi" }?.text
        #expect(plain?.paragraphs[0].runs[0].props.bold != true)
        let s = session()
        s.run("edit.paste", #"{"text": "Hello world", "html": "<p><b>Hello</b>\nworld</p>"}"#)
        let body = s.st.currentSlide?.shapes.first { $0.text?.text == "Hello world" }?.text
        #expect(body?.paragraphs[0].runs[0].props.bold == true)
        for blank in ["<p>&nbsp;</p>", "<p><o:p>&nbsp;</o:p></p>"] {
            let t = session()
            let html = "<p><b>A</b></p>\(blank)<p>B</p>"
            t.run("edit.paste", JSON.object(JSONObject(["text": "A\n\u{a0}\nB", "html": .string(html)])).display)
            let b = t.st.currentSlide?.shapes.first { $0.text?.paragraphs.count == 3 }?.text
            #expect(b?.paragraphs[0].runs[0].text == "A" && b?.paragraphs[0].runs[0].props.bold == true, "\(html)")
            #expect(b?.paragraphs[2].runs[0].text == "B", "\(html)")
        }
    }

    @Test(.enabled(if: ported("insert.textBox", "text.edit", "text.move", "text.get")))
    func cutWithOnlyACaretChangesNothing() {
        let s = session()
        let i = s.run("insert.textBox", #"{"text": "Hello"}"#).get("id")?.asU64 ?? 0
        s.run("text.edit", "{\"id\": \(i)}")
        s.run("text.move", #"{"to": "start"}"#)
        #expect(s.run("edit.cut").get("text") == "")
        #expect(s.run("text.get", "{\"id\": \(i)}").get("text") == "Hello", "cut with only a caret changed the text")
        s.run("text.move", #"{"to": "end", "extend": true}"#)
        #expect(s.run("edit.cut").get("text") == "Hello")
        #expect(s.run("text.get", "{\"id\": \(i)}").get("text") == "")
    }

    @Test(.enabled(if: ported("text.edit", "text.insert", "text.selectAll", "format.bold", "text.select", "insert.textBox")))
    func boldCopyIsHTMLAndPagesHTMLPastesBold() throws {
        let s = session()
        let title = try #require(s.st.currentSlide?.shapes.first?.id)
        s.run("text.edit", "{\"id\": \(title)}")
        s.run("text.insert", #"{"text": "Hello"}"#)
        s.run("text.selectAll")
        s.run("format.bold", #"{"on": true}"#)
        let v = s.run("edit.copy")
        #expect(v.get("html")?.asStr?.contains("<b>") == true)
        #expect(v.get("text") == "Hello")
        // The same plain words are our own clipboard, so a plainer HTML fragment is not reparsed.
        s.run("text.select", #"{"anchor": [0, 5], "caret": [0, 5]}"#)
        s.run("edit.paste", #"{"text": "Hello", "html": "<p>Hello</p>"}"#)
        let body = try #require(s.st.shape(title)?.text)
        #expect(body.text == "HelloHello")
        #expect(body.paragraphs.flatMap(\.runs).allSatisfy { $0.props.bold == true })
        s.run("text.select", #"{"anchor": [0, 10], "caret": [0, 10]}"#)
        let caret = s.run("edit.copy")
        #expect(caret.get("text") == "" && caret.get("html") == "")
    }
}

@Suite("Rich clipboard")
struct RichClipTests {
    @Test func multibyteAfterAmpersandIsKept() {
        let text = String(repeating: "é", count: 20)
        #expect(RichClip.decodeText("R&D \(text)") == "R&D \(text)")
        let cjk = String(repeating: "漢", count: 20)
        #expect(RichClip.decodeText("&\(cjk)") == "&\(cjk)")
    }

    @Test func signedNumericEntitiesAreKeptAsTyped() {
        #expect(RichClip.decodeText("a&#+65;b") == "a&#+65;b")
        #expect(RichClip.decodeText("a&#x+41;b") == "a&#x+41;b")
        #expect(RichClip.decodeText("a&#65;b&#x41;") == "aAbA")
    }

    @Test func numericTabEntityDecodesToTab() {
        #expect(RichClip.decodeText("a&#9;b") == "a\tb")
        #expect(RichClip.decodeText("a&#x9;b") == "a\tb")
    }

    @Test func googleDocsNormalWeightWrapperIsNotBold() throws {
        let html = #"<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><span style="font-weight:400">plain words</span></b>"#
        let body = try #require(RichClip.htmlToBody(html))
        #expect(body.text == "plain words")
        #expect(body.paragraphs[0].runs[0].props.bold == nil)
        #expect(RichClip.htmlToBody(#"<b style="font-weight:300">thin</b>"#)?.paragraphs[0].runs[0].props.bold == nil)
        #expect(RichClip.htmlToBody("<b>strong</b>")?.paragraphs[0].runs[0].props.bold == true)
        #expect(RichClip.htmlToBody(#"<span style="font-weight:700">heavy</span>"#)?.paragraphs[0].runs[0].props.bold == true)
    }

    @Test func styleAttributeIsFoundAfterAttributesContainingStyle() {
        for tag in [
            #"<span class="style1" style="font-weight:bold">x</span>"#,
            #"<span data-style="x" style="font-weight:bold">x</span>"#,
            #"<span class="mystyle" style="font-weight:bold">x</span>"#,
        ] {
            #expect(RichClip.htmlToBody(tag)?.paragraphs[0].runs[0].props.bold == true, "\(tag)")
        }
        #expect(RichClip.htmlToBody(#"<span class="style">x</span>"#)?.paragraphs[0].runs[0].props.bold == nil)
    }

    @Test func boldItalicAndUnderlineRoundTrip() throws {
        var body = TextBody.fromText("Hi there")
        var bold = RunProps.default
        bold.bold = true
        var iu = RunProps.default
        iu.italic = true
        iu.underline = "sng"
        body.paragraphs[0].runs = [Run.with("Hi", bold), Run(" "), Run.with("there", iu)]
        let html = RichClip.bodyToHTML(body)
        #expect(html.contains("<b>Hi</b>"), "\(html)")
        #expect(html.contains("<i><u>there</u></i>") || html.contains("<u><i>there</i></u>"), "\(html)")
        let back = try #require(RichClip.htmlToBody(html))
        #expect(back.text == "Hi there")
        #expect(back.paragraphs[0].runs[0].props.bold == true)
        #expect(back.paragraphs[0].runs.last?.props.italic == true)
        #expect(back.paragraphs[0].runs.last?.props.underline != nil)
    }

    @Test func bareAmpersandKeepsTextUpToNextSemicolon() {
        func text(_ html: String) -> String? { RichClip.htmlToBody(html)?.text }
        #expect(text("<p>R&D costs; up</p>") == "R&D costs; up")
        #expect(text("<p>AT&T; Q&A</p>") == "AT&T; Q&A")
        #expect(text("<p>A &amp; B &#38; C &#x26; D</p>") == "A & B & C & D")
        // Many bare ampersands don't make the scan quadratic.
        #expect(text("<p>\(String(repeating: "&", count: 2000))</p>") == String(repeating: "&", count: 2000))
    }

    @Test func pagesStyleAndEscapes() throws {
        let html = #"<html><head><style>p{}</style></head><body><p><span style="font-weight: bold">A &amp; B</span></p><p><span style="font-style: italic">C</span></p></body></html>"#
        let body = try #require(RichClip.htmlToBody(html))
        #expect(body.text == "A & B\nC")
        #expect(body.paragraphs[0].runs[0].props.bold == true)
        #expect(body.paragraphs[1].runs[0].props.italic == true)
        #expect(RichClip.sameWords(body.text, "A & B\nC"))
        #expect(!RichClip.sameWords(body.text, "other"))
    }

    @Test func aNewlineInHTMLTextIsASpace() throws {
        #expect(RichClip.decodeText("Hello\nworld") == "Hello world")
        #expect(RichClip.htmlToBody("<p>Hello\r\n  world</p>")?.text == "Hello world")
        let body = try #require(RichClip.htmlToBody("<p>\n<b>Hello</b>\n<i>world</i>\n</p>\n<p>next</p>"))
        #expect(body.text == "Hello world\nnext")
        #expect(RichClip.sameWords(body.text, "Hello world\nnext"))
        #expect(body.paragraphs[0].runs[0].props.bold == true)
        #expect(body.paragraphs[0].runs.last?.props.italic == true)
    }

    @Test func aHugeFragmentIsRefused() {
        #expect(RichClip.htmlToBody(String(repeating: "x", count: RichClip.maxHTML + 1)) == nil)
    }
}
