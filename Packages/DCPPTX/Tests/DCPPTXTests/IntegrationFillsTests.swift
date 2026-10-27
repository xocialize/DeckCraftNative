// Port of deckcraft crates/pptx/tests/it/fills.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): fills read from decks written by other tools.
import DCColor
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

/// `bytes` with `edit` applied to every slide part.
private func editSlides(_ bytes: [UInt8], _ edit: (String) -> String) throws -> [UInt8] {
    try IT.zip(IT.entries(bytes).map { e in
        guard e.name.hasPrefix("ppt/slides/slide"), e.name.hasSuffix(".xml") else { return e }
        return (e.name, Array(edit(String(decoding: e.data, as: UTF8.self)).utf8))
    })
}

private func png() -> [UInt8] { IT.png(4, 4, (10, 200, 30)) }

/// `p` with `shape` (named, at 10,10 200×100) appended to its first slide.
private func push(_ p: inout Presentation, _ name: String, _ edit: (inout Shape) -> Void) {
    var s = IT.shape(&p, name, 10, 10, 200, 100)
    edit(&s)
    p.slides[0].shapes.append(s)
}

/// A deck with one shape filled with a stretched picture, exported.
private func deck() throws -> [UInt8] {
    var p = newPresentation(nil)
    let mediaAdded = p.addMedia("tile.png", "image/png", png())
    let media = try #require(mediaAdded, "media")
    push(&p, "Textured") { $0.fill = .picture(PictureFill(media: media)) }
    return try PPTX.export(p)
}

private func texturedMode(_ bytes: [UInt8]) throws -> PictureMode? {
    let q = try PPTX.import(bytes)
    let s = try #require(q.slides[0].shapes.first { $0.name == "Textured" }, "shape")
    guard case let .picture(pf) = s.fill else {
        Issue.record("\(String(describing: s.fill))")
        return nil
    }
    return pf.mode
}

/// `s` without the first `open`…`close` span inside a `blipFill`.
private func regexFreeStrip(_ s: String, _ open: String, _ close: String) -> String {
    guard let b = s.byteFind("<a:blipFill"),
          let i = s.byteFind(open, from: b),
          let j = s.byteFind(close, from: i).map({ $0 + close.utf8.count }) else { return s }
    return s.bytes(0, i) + s.bytes(j)
}

private func texturedFill(_ bytes: [UInt8]) throws -> Fill? {
    let q = try PPTX.import(bytes)
    return q.slides[0].shapes.first { $0.name == "Textured" }?.fill
}

@Suite struct IntegrationFillsTests {
    // Rust: it/fills.rs::a_shape_picture_fill_without_stretch_or_tile_tiles
    @Test func aShapePictureFillWithoutStretchOrTileTiles() throws {
        // tdf#128596: `<a:blipFill><a:blip/></a:blipFill>` on a shape, as some tools write it;
        // PowerPoint tiles the picture at its own size.
        let bare = try editSlides(deck()) { s in
            let s = regexFreeStrip(s, "<a:stretch>", "</a:stretch>")
            #expect(!s.has("<a:stretch"), "the test deck lost its stretch")
            return s
        }
        let tiled = try texturedMode(bare)
        if case let .tile(_, _, sx, sy, _, _) = tiled {
            #expect(sx == 1.0 && sy == 1.0, "\(String(describing: tiled))")
        } else {
            Issue.record("\(String(describing: tiled))")
        }
        // An explicit stretch is still a stretch.
        let stretched = try texturedMode(deck())
        if case .stretch = stretched {} else { Issue.record("\(String(describing: stretched))") }
    }

    // Rust: it/fills.rs::a_gradient_without_stops_is_saved_without_stops
    @Test func aGradientWithoutStopsIsSavedWithoutStops() throws {
        // `a:gradFill` with no `a:gsLst` takes its stops from the style's fill in PowerPoint; saving
        // must not turn it into a gradient of its own (it used to become solid white).
        var p = newPresentation(nil)
        let own = Gradient(stops: [], shape: .linear(angle: 45.0, scaled: true), rotateWithShape: true, tile: [0, 0, 0, 0])
        push(&p, "Styled") {
            $0.fill = .gradient(own)
            $0.style = ShapeStyle.accent(.accent1)
        }
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        let s = try #require(q.slides[0].shapes.first { $0.name == "Styled" }, "shape")
        #expect(s.fill == .gradient(own))
    }

    // Rust: it/fills.rs::a_fill_overlay_round_trips
    @Test func aFillOverlayRoundTrips() throws {
        var p = newPresentation(nil)
        let overlay = FillOverlay(
            blend: "mult",
            fill: .gradient(Gradient(
                stops: [
                    GradientStop(pos: 0.0, color: .scheme(.accent1)),
                    GradientStop(pos: 1.0, color: .rgb(Rgba.rgb(10, 20, 30))),
                ],
                shape: .linear(angle: 4.5, scaled: true),
                rotateWithShape: true,
                tile: [0, 0, 0, 0]
            ))
        )
        push(&p, "Overlaid") {
            $0.fill = .solid(.rgb(Rgba.white))
            $0.effects = Effects(fillOverlay: overlay)
        }
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        let s = try #require(q.slides[0].shapes.first { $0.name == "Overlaid" }, "shape")
        #expect(s.effects?.fillOverlay == overlay)
    }

    // Rust: it/fills.rs::a_gradient_tile_rect_is_read_and_round_trips
    @Test func aGradientTileRectIsReadAndRoundTrips() throws {
        // PowerPoint's "from top-left corner" radial: focus on the corner, tile reaching a box up and
        // to the left so it centres on that corner.
        let g = Gradient(
            stops: [
                GradientStop(pos: 0.0, color: .rgb(Rgba.rgb(0, 128, 255))),
                GradientStop(pos: 1.0, color: .rgb(Rgba.white)),
            ],
            shape: .path(path: "circle", focus: [0.0, 0.0, 1.0, 1.0]),
            rotateWithShape: true,
            tile: [-1.0, -1.0, 0.0, 0.0]
        )
        var p = newPresentation(nil)
        push(&p, "Corner") { $0.fill = .gradient(g) }
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        let s = try #require(q.slides[0].shapes.first { $0.name == "Corner" }, "shape")
        #expect(s.fill == .gradient(g))
        // As written by PowerPoint (attributes it leaves out are 0).
        let edited = try editSlides(bytes) {
            $0.replace(#"<a:tileRect l="-100000" t="-100000" r="0" b="0"/>"#, #"<a:tileRect l="-100000" t="-100000"/>"#)
        }
        let r = try PPTX.import(edited)
        let s2 = try #require(r.slides[0].shapes.first { $0.name == "Corner" }, "shape")
        if case let .gradient(g2) = s2.fill {
            #expect(g2.tile == [-1.0, -1.0, 0.0, 0.0], "\(String(describing: s2.fill))")
        } else {
            Issue.record("\(String(describing: s2.fill))")
        }
    }

    // Rust: it/fills.rs::a_table_naming_no_style_is_drawn_with_the_table_grid
    @Test func aTableNamingNoStyleIsDrawnWithTheTableGrid() throws {
        var p = newPresentation(nil)
        var t = Table(rows: 2, cols: 2, width: 200, rowHeight: 40)
        t.style = "none"
        var s = IT.shape(&p, "Grid", 10, 10, 200, 80)
        s.kind = .table(t)
        p.slides[0].shapes.append(s)
        let bytes = try PPTX.export(p)
        func style(_ bytes: [UInt8]) throws -> String? {
            let q = try PPTX.import(bytes)
            let s = try #require(q.slides[0].shapes.first { $0.name == "Grid" }, "shape")
            guard case let .table(t) = s.kind else {
                Issue.record("\(s.kind)")
                return nil
            }
            return t.style
        }
        // Written with its style, it reads back as written.
        #expect(try style(bytes) == "none")
        // Without a:tableStyleId PowerPoint draws thin dark grid lines.
        let bare = try editSlides(bytes) { x in
            guard let a = x.byteFind("<a:tableStyleId>"), let b = x.byteFind("</a:tableStyleId>") else { return x }
            return x.bytes(0, a) + x.bytes(b + "</a:tableStyleId>".utf8.count)
        }
        #expect(try style(bare) == "grid")
    }

    // Rust: it/fills.rs::black_and_white_and_inverted_alpha_pictures_round_trip
    @Test func blackAndWhiteAndInvertedAlphaPicturesRoundTrip() throws {
        var p = newPresentation(nil)
        let mediaAdded = p.addMedia("tile.png", "image/png", png())
        let media = try #require(mediaAdded, "media")
        var pf = PictureFill(media: media)
        pf.adjust.bilevel = 0.3
        pf.adjust.alphaInv = true
        push(&p, "BW") { $0.fill = .picture(pf) }
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        let s = try #require(q.slides[0].shapes.first { $0.name == "BW" }, "shape")
        if case let .picture(back) = s.fill {
            #expect(back.adjust.bilevel == 0.3 && back.adjust.alphaInv == true)
        } else {
            Issue.record("\(String(describing: s.fill))")
        }
    }

    // Rust: it/fills.rs::an_upright_picture_fill_round_trips
    @Test func anUprightPictureFillRoundTrips() throws {
        let bytes = try deck()
        let edited = try editSlides(bytes) { $0.replacen(#"rotWithShape="1""#, #"rotWithShape="0""#, 1) }
        let q = try PPTX.import(edited)
        let s = try #require(q.slides[0].shapes.first { $0.name == "Textured" }, "shape")
        guard case let .picture(pf) = s.fill else {
            Issue.record("\(String(describing: s.fill))")
            return
        }
        #expect(pf.upright)
        let again = try PPTX.export(q)
        let r = try PPTX.import(again)
        let s2 = try #require(r.slides[0].shapes.first { $0.name == "Textured" }, "shape")
        if case let .picture(pf2) = s2.fill { #expect(pf2.upright) } else { Issue.record("\(String(describing: s2.fill))") }
        // Rotating with the shape is the default.
        if case let .picture(pf3) = try texturedFill(bytes) { #expect(!pf3.upright) } else { Issue.record("no picture fill") }
    }
}
