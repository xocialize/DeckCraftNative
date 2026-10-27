// Port of deckcraft crates/pptx/tests/it/corpus_elements.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned round trip: comments, hyperlinks and actions, custom shows, grouped rotated objects, and
// placeholders that inherit from the layout. Embedded fonts stay out of this check; another open change
// owns that part.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

private let chime: [UInt8] = Array("RIFFdeckcraft-chime-WAVEfmt ".utf8)

private func link(_ action: Action) -> Hyperlink {
    Hyperlink(action: action, tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
}

private func boxAt(_ p: inout Presentation, _ name: String, _ x: Double, _ y: Double) -> Shape {
    IT.shape(&p, name, x, y, 80.0, 28.0)
}

private func shape(_ p: Presentation, _ slide: Int, _ name: String) throws -> Shape {
    try #require(p.slides[slide].shapes.first { bytesEqual($0.name, name) }, "missing \(name)")
}

private func placeholder(_ p: Presentation, _ kind: PhType) throws -> Shape {
    try #require(p.slides[0].shapes.first { $0.phType == kind }, "missing \(kind)")
}

private func deck() throws -> Presentation {
    var p = newPresentation(nil)
    let layout = try #require(layoutOfKind(p, .titleAndContent), "layout")
    let li = try #require(p.masters[0].layouts.firstIndex { $0.id == layout }, "layout")
    for i in p.masters[0].layouts[li].shapes.indices {
        var s = p.masters[0].layouts[li].shapes[i]
        if s.phType != .obj { continue }
        s.xfrm = Xfrm(48.0, 120.0, 600.0, 300.0)
        s.geom = .preset("ellipse")
        s.fill = .solid(.rgb(.rgb(20, 40, 80)))
        var ls = ListStyle.default
        ls.set(0, LevelStyle(run: RunProps(font: "Source Serif 4", size: 28.0)))
        var body = s.text ?? TextBody.default
        body.listStyle = ls
        s.text = body
        p.masters[0].layouts[li].shapes[i] = s
    }

    let chimeIdOpt = p.addMedia("chime.wav", "audio/wav", chime)
    let chimeId = try #require(chimeIdOpt, "media")
    let aOpt = newSlide(&p, layout)
    var a = try #require(aOpt, "slide")
    a.name = "Review"
    if let i = a.shapes.firstIndex(where: { $0.phType == .title }) {
        a.shapes[i].text = TextBody.fromText("Review")
    }
    if let i = a.shapes.firstIndex(where: { $0.phType == .obj }) {
        a.shapes[i].text = TextBody(paragraphs: [
            Paragraph(
                runs: [Run("Quoted")],
                defProps: RunProps(
                    font: "Literata", size: 22.0, bold: true,
                    link: Hyperlink(
                        action: .url(url: "https://example.com/quote"), tooltip: "Source", highlightClick: false, sound: nil,
                        stopSound: false, zoomReturn: nil
                    )
                )
            ),
            Paragraph(runs: [Run("Inherits")]),
        ])
    }
    var gem = boxAt(&p, "Gem", 12.0, 18.0)
    gem.xfrm = Xfrm(x: 12.0, y: 18.0, w: 80.0, h: 40.0, rot: 20.0, flipV: true)
    gem.text = TextBody.fromText("Tilted")
    var cluster = boxAt(&p, "Cluster", 80.0, 40.0)
    cluster.xfrm = Xfrm(x: 80.0, y: 40.0, w: 220.0, h: 140.0, rot: 25.0, flipH: true)
    cluster.kind = .group(children: [gem], child: Xfrm(10.0, 20.0, 400.0, 240.0))
    a.shapes.append(cluster)

    var site = boxAt(&p, "Site", 40.0, 460.0)
    site.click = Hyperlink(
        action: .url(url: "https://example.com/deck"), tooltip: "Example", highlightClick: true, sound: nil, stopSound: false,
        zoomReturn: nil
    )
    a.shapes.append(site)

    a.shapes.append(boxAt(&p, "Go second", 140.0, 460.0))

    let actions: [(String, Double, Action)] = [
        ("Next", 240.0, .nextSlide),
        ("End", 330.0, .endShow),
        ("Back", 420.0, .lastViewed),
        ("Last", 510.0, .lastSlide),
        ("Open file", 600.0, .program(path: "Talk notes.txt")),
        ("Play clip", 700.0, .playMedia),
    ]
    for (name, x, action) in actions {
        var s = boxAt(&p, name, x, 500.0)
        s.click = link(action)
        a.shapes.append(s)
    }

    var hover = boxAt(&p, "Hover", 40.0, 500.0)
    hover.hover = Hyperlink(action: .previousSlide, tooltip: "Back one", highlightClick: false, sound: nil, stopSound: true, zoomReturn: nil)
    a.shapes.append(hover)

    var home = boxAt(&p, "Home", 800.0, 460.0)
    home.geom = .preset("actionButtonHome")
    home.click = Hyperlink(action: .firstSlide, tooltip: "", highlightClick: true, sound: nil, stopSound: false, zoomReturn: nil)
    a.shapes.append(home)

    var board = boxAt(&p, "To board", 140.0, 500.0)
    board.click = Hyperlink(
        action: .customShow(name: "Board", returns: false), tooltip: "Open the board show", highlightClick: false, sound: chimeId,
        stopSound: false, zoomReturn: nil
    )
    a.shapes.append(board)

    var short = boxAt(&p, "To short", 240.0, 500.0)
    short.click = link(.customShow(name: "Short", returns: true))
    a.shapes.append(short)

    a.comments = [Comment(author: "Mina", initials: "ML", text: "Check the quote", date: "2026-03-01T09:30:00.000", x: 36.0, y: 48.0)]

    let bOpt = newSlide(&p, layout)
    var b = try #require(bOpt, "slide")
    if let i = b.shapes.firstIndex(where: { $0.phType == .title }) {
        b.shapes[i].text = TextBody.fromText("Second")
    }
    // The jump is filled in once this slide has an id.
    let bId = b.id
    if let i = a.shapes.firstIndex(where: { $0.name == "Go second" }) {
        a.shapes[i].click = link(.slide(slide: bId))
    }
    p.slides = [a, b]
    let ids = p.slides.map(\.id)
    p.customShows = [CustomShow(name: "Short", slides: [ids[0]]), CustomShow(name: "Board", slides: [ids[1], ids[0]])]
    p.show.customShow = "Board"
    return p
}

private func assertDeck(_ q: Presentation) throws {
    try #require(q.slides.count == 2)
    #expect(try placeholder(q, .title).text.map(\.text) == "Review")

    let body = try placeholder(q, .obj)
    #expect(body.xfrm == nil, "a placeholder with no box of its own keeps inheriting the layout")
    #expect(body.geom.presetName == "ellipse", "layout geometry: \(body.geom)")
    let ctx = try #require(Resolve.Ctx.forSlide(q, q.slides[0]), "ctx")
    let x = Resolve.xfrm(ctx, body)
    #expect(x.x == 48.0 && x.y == 120.0 && x.w == 600.0 && x.h == 300.0)
    let (fill, _) = Resolve.fill(ctx, body)
    #expect(fill == .solid(.rgb(.rgb(20, 40, 80))))

    let paras = try #require(body.text, "text").paragraphs
    try #require(paras.count >= 2 && !paras[0].runs.isEmpty && !paras[1].runs.isEmpty)
    #expect(paras[0].runs[0].text == "Quoted")
    #expect(paras[0].runs[0].props.size == nil, "the run itself stays unset")
    #expect(paras[0].defProps.size == 22.0)
    #expect(paras[0].defProps.bold == true)
    #expect(paras[0].defProps.font == "Literata")
    switch paras[0].defProps.link?.action {
    case .url(let url)?: #expect(url == "https://example.com/quote")
    case let other?: Issue.record("paragraph link: \(other)")
    case nil: Issue.record("paragraph default run lost its link")
    }
    #expect(paras[0].defProps.link?.tooltip == "Source")
    let quoted = Resolve.run(ctx, body, paras[0], paras[0].runs[0].props)
    #expect(quoted.size == 22.0)
    #expect(paras[1].runs[0].text == "Inherits")
    let inherited = Resolve.run(ctx, body, paras[1], paras[1].runs[0].props)
    #expect(inherited.size == 28.0, "the second paragraph takes the layout list style")
    #expect(inherited.font == "Source Serif 4")

    let cluster = try shape(q, 0, "Cluster")
    let g = try #require(cluster.xfrm, "group box")
    #expect(g.x == 80.0 && g.y == 40.0 && g.w == 220.0 && g.h == 140.0 && g.rot == 25.0 && g.flipH)
    guard case .group(let children, let child) = cluster.kind else {
        Issue.record("not a group")
        return
    }
    #expect(child.x == 10.0 && child.y == 20.0 && child.w == 400.0 && child.h == 240.0)
    let gem = try #require(children.first)
    #expect(gem.text.map(\.text) == "Tilted")
    let gx = try #require(gem.xfrm, "gem")
    #expect(gx.x == 12.0 && gx.y == 18.0 && gx.w == 80.0 && gx.h == 40.0 && gx.rot == 20.0 && gx.flipV)

    let c = q.slides[0].comments
    try #require(c.count == 1)
    #expect(c[0].author == "Mina" && c[0].initials == "ML" && c[0].text == "Check the quote")
    #expect(c[0].date == "2026-03-01T09:30:00.000")
    #expect(c[0].x == 36.0 && c[0].y == 48.0)

    func click(_ name: String) throws -> Hyperlink {
        try #require(try shape(q, 0, name).click, "\(name) lost its click")
    }
    switch try click("Site").action {
    case .url(let url): #expect(url == "https://example.com/deck")
    case let other: Issue.record("\(other)")
    }
    #expect(try click("Site").tooltip == "Example")
    #expect(try click("Site").highlightClick)
    switch try click("Go second").action {
    case .slide(let slide): #expect(q.slides.firstIndex { $0.id == slide } == 1)
    case let other: Issue.record("\(other)")
    }
    #expect(try click("Next").action == .nextSlide)
    #expect(try click("End").action == .endShow)
    #expect(try click("Back").action == .lastViewed)
    #expect(try click("Last").action == .lastSlide)
    switch try click("Open file").action {
    case .program(let path): #expect(path == "Talk notes.txt")
    case let other: Issue.record("\(other)")
    }
    #expect(try click("Play clip").action == .playMedia)
    #expect(try click("Home").action == .firstSlide)
    #expect(try click("Home").highlightClick)
    #expect(try shape(q, 0, "Home").geom.presetName == "actionButtonHome")
    let hover = try #require(try shape(q, 0, "Hover").hover, "hover")
    #expect(hover.action == .previousSlide)
    #expect(hover.stopSound)
    #expect(hover.tooltip == "Back one")

    switch try click("To board").action {
    case .customShow(let name, let returns):
        #expect(name == "Board")
        #expect(!returns, "Show and return was forced on")
    case let other: Issue.record("\(other)")
    }
    let snd = try #require(try click("To board").sound, "action sound")
    #expect(q.media(snd)?.data == chime)
    switch try click("To short").action {
    case .customShow(let name, let returns):
        #expect(name == "Short")
        #expect(returns)
    case let other: Issue.record("\(other)")
    }

    try #require(q.customShows.count == 2)
    #expect(q.customShows[0].name == "Short")
    #expect(q.customShows[0].slides == [q.slides[0].id])
    #expect(q.customShows[1].name == "Board")
    #expect(q.customShows[1].slides == [q.slides[1].id, q.slides[0].id])
    #expect(q.show.customShow == "Board")
    #expect(q.slides[1].shapes.first { $0.phType == .title }?.text.map(\.text) == "Second")
}

@Suite struct IntegrationCorpusElementsTests {
    // Rust: it/corpus_elements.rs::comments_links_shows_groups_and_inherited_placeholders_round_trip
    @Test func commentsLinksShowsGroupsAndInheritedPlaceholdersRoundTrip() throws {
        let p = try deck()
        let once = try IT.round(p)
        try assertDeck(once)
        let twice = try IT.round(once)
        try assertDeck(twice)
    }
}
