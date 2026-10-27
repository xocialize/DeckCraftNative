// DCEngineTests — slide show clicks and paragraph builds on decks that went through a PPTX file, and native
// saves that keep an imported chart's package parts.
// Ports deckcraft crates/engine/tests/it/show_clicks.rs, tests/it/chart_native.rs and
// tests/show_paragraph_builds.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCAnim
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import DCZip
import Foundation
import Testing

// MARK: - it/show_clicks.rs

private func clickShape(_ p: inout Presentation, _ name: String, _ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Shape {
    var s = Shape.default
    s.id = ShapeId(p.allocId() ?? 0)
    s.name = name
    s.xfrm = Xfrm(x, y, w, h)
    s.text = TextBody.fromText(text)
    return s
}

private func linkTo(_ slide: SlideId) -> Hyperlink? {
    Hyperlink(action: .slide(slide: slide), tooltip: "", highlightClick: false, sound: nil, stopSound: false, zoomReturn: nil)
}

/// Clicking `trigger` makes `target` disappear.
private func disappearOnClick(_ trigger: ShapeId, _ target: ShapeId) -> Animation {
    var a = Animation.default
    a.shape = target
    a.class = .exit
    a.effect = "disappear"
    a.start = .onClick
    a.durationMs = 0
    a.trigger = trigger
    return a
}

@discardableResult
private func addSlide(_ p: inout Presentation, _ shapes: [Shape], _ animations: [Animation], _ advanceOnClick: Bool) -> SlideId {
    let layout = layoutOfKind(p, .blank) ?? .default
    guard var s = newSlide(&p, layout) else { return .default }
    s.shapes = shapes
    s.animations = animations
    if !advanceOnClick {
        var t = Transition.default
        t.advanceOnClick = false
        s.transition = t
    } else {
        s.transition = nil
    }
    let id = s.id
    p.slides.append(s)
    return id
}

/// The slide show window's click handling, on a deck read from a PPTX file.
private struct Show {
    var pres: Presentation
    var state: ShowState

    init(_ p: Presentation) throws {
        pres = try PPTX.import(PPTX.export(p))
        state = ShowState(pres)
    }

    func hitTest(_ x: Double, _ y: Double) -> ([HitShape], [Bool]) {
        let placed = placeSlide(pres, state.slide)
        let tl = ShowState.timeline(pres, state.slide)
        let hits = placed.shapes.map { s in
            HitShape(id: s.id, parent: s.parent, isGroup: s.isGroup, link: s.link?.action,
                     underPointer: s.rect.x0 <= x && x <= s.rect.x1 && s.rect.y0 <= y && y <= s.rect.y1)
        }
        let visible = placed.shapes.map { s in
            let a = state.animState(tl, s.id, 0.0)
            return a.visible && a.opacity > 0.0
        }
        return (hits, visible)
    }

    /// Click the middle of the shape called `name` on the current slide.
    mutating func click(_ name: String) -> Click {
        let (x, y) = centre(name)
        let (hits, vis) = hitTest(x, y)
        let tl = ShowState.timeline(pres, state.slide)
        let visible = { (id: ShapeId) in zip(hits, vis).first { $0.0.id == id }.map { $0.1 } ?? true }
        return state.click(pres, tl, hits, visible, 0.0, nil)
    }

    func centre(_ name: String) -> (Double, Double) {
        guard let x = pres.slides.at(state.slide)?.shapes.first(where: { $0.name == name })?.xfrm else {
            Issue.record("no shape \(name)")
            return (0, 0)
        }
        return (x.x + x.w / 2.0, x.y + x.h / 2.0)
    }

    func shown(_ name: String) -> Bool {
        guard let s = pres.slides.at(state.slide)?.shapes.first(where: { $0.name == name }) else { return false }
        let a = state.animState(ShowState.timeline(pres, state.slide), s.id, 0.0)
        return a.visible && a.opacity > 0.0
    }

    func isTarget(_ name: String) -> Bool {
        let (x, y) = centre(name)
        let (hits, vis) = hitTest(x, y)
        let tl = ShowState.timeline(pres, state.slide)
        let visible = { (id: ShapeId) in zip(hits, vis).first { $0.0.id == id }.map { $0.1 } ?? true }
        let id = pres.slides.at(state.slide)?.shapes.first { $0.name == name }?.id
        return state.target(pres, tl, hits, visible)?.shape == id
    }
}

/// An image that disappears when clicked, revealing a button that links to slide 2 and disappears as well;
/// slide 2 links back; the slides do not advance on a click.
private func hideAndRevealDeck() -> Presentation {
    var p = newPresentation(nil)
    p.slides.removeAll()
    _ = p.allocId()
    let message = clickShape(&p, "Message", "Both hidden", 100.0, 100.0, 600.0, 300.0)
    var button = clickShape(&p, "Button", "Image hidden", 100.0, 100.0, 600.0, 300.0)
    let picture = clickShape(&p, "Picture", "Picture", 100.0, 100.0, 600.0, 300.0)
    let animations = [disappearOnClick(picture.id, picture.id), disappearOnClick(button.id, button.id)]
    let first = addSlide(&p, [message, button, picture], animations, false)
    var back = clickShape(&p, "Back", "Go back", 100.0, 100.0, 600.0, 300.0)
    back.click = linkTo(first)
    let second = addSlide(&p, [back], [], false)
    // The button links to slide 2.
    button.click = linkTo(second)
    if let i = p.slides[0].shapes.firstIndex(where: { $0.name == "Button" }) { p.slides[0].shapes[i].click = button.click }
    return p
}

@Suite("Show clicks after PPTX")
struct ShowClickTests {
    // Rust: tests/it/show_clicks.rs::saved_trigger_reveals_then_hides_on_separate_clicks
    @Test func savedTriggerRevealsThenHidesOnSeparateClicks() throws {
        var p = newPresentation(nil)
        p.slides.removeAll()
        let button = clickShape(&p, "Button", "Toggle", 20.0, 20.0, 100.0, 40.0)
        let target = clickShape(&p, "Target", "Answer", 200.0, 100.0, 200.0, 80.0)
        var appear = Animation.default
        appear.shape = target.id
        appear.trigger = button.id
        appear.effect = "appear"
        appear.start = .onClick
        appear.durationMs = 0
        addSlide(&p, [button, target], [appear, disappearOnClick(button.id, target.id)], false)
        var show = try Show(p)
        #expect(!show.shown("Target"))
        for _ in 0 ..< 2 {
            #expect(show.click("Button") == .animated)
            #expect(show.shown("Target"), "first click reveals the answer until the next click")
            #expect(show.click("Button") == .animated)
            #expect(!show.shown("Target"), "second click hides the answer")
        }
    }

    // Rust: tests/it/show_clicks.rs::hidden_shapes_stay_hidden_and_dead_when_the_show_comes_back
    @Test func hiddenShapesStayHiddenAndDeadWhenTheShowComesBack() throws {
        var show = try Show(hideAndRevealDeck())
        #expect(show.isTarget("Picture") && show.shown("Picture"))
        #expect(show.click("Picture") == .animated)
        #expect(!show.shown("Picture"))
        // The button was under the picture; now it is on top. Its click follows the link.
        #expect(show.isTarget("Button"))
        #expect(show.click("Button") == .show(.slide(1)))
        #expect(show.state.slide == 1)
        #expect(show.click("Back") == .show(.slide(0)))
        // Back on slide 1: both are gone, only the message is left, and it does nothing.
        #expect(!show.shown("Picture") && !show.shown("Button") && show.shown("Message"))
        #expect(!show.isTarget("Message"))
        for _ in 0 ..< 3 {
            #expect(show.click("Message") == .none_)
        }
        #expect(show.state.slide == 0)
    }

    // Rust: tests/it/show_clicks.rs::a_game_board_hides_the_tiles_already_played
    @Test func aGameBoardHidesTheTilesAlreadyPlayed() throws {
        var p = newPresentation(nil)
        p.slides.removeAll()
        var tiles = (0 ..< 3).map { i in clickShape(&p, "Tile \(i)", "100", 50.0 + 250.0 * Double(i), 100.0, 200.0, 100.0) }
        let animations = tiles.map { disappearOnClick($0.id, $0.id) }
        let board = addSlide(&p, tiles, animations, true)
        let questions: [SlideId] = (0 ..< 3).map { i in
            var back = clickShape(&p, "Back", "Question \(i)", 100.0, 100.0, 400.0, 200.0)
            back.click = linkTo(board)
            return addSlide(&p, [back], [], true)
        }
        for (k, q) in zip(tiles.indices, questions) {
            tiles[k].click = linkTo(q)
            if let i = p.slides[0].shapes.firstIndex(where: { $0.id == tiles[k].id }) { p.slides[0].shapes[i].click = linkTo(q) }
        }
        var show = try Show(p)
        for (i, played) in [1, 0, 2].enumerated() {
            #expect(show.click("Tile \(played)") == .show(.slide(1 + played)))
            #expect(show.click("Back") == .show(.slide(0)))
            // Exactly the tiles played so far are gone.
            let gone = (0 ..< 3).map { !show.shown("Tile \($0)") }
            #expect(gone.filter { $0 }.count == i + 1, "\(gone)")
            #expect(gone[played])
            #expect(!show.isTarget("Tile \(played)"))
        }
    }

    // Rust: tests/it/show_clicks.rs::a_score_ring_goes_round
    @Test func aScoreRingGoesRound() throws {
        var p = newPresentation(nil)
        p.slides.removeAll()
        let n = 4
        let digits = (0 ..< n).map { i in clickShape(&p, "Score \(i)", String(i), 400.0, 100.0, 100.0, 100.0) }
        var anims: [Animation] = []
        for (i, d) in digits.enumerated() {
            anims.append(disappearOnClick(d.id, d.id))
            var a = Animation.default
            a.shape = digits[(i + 1) % n].id
            a.class = .entrance
            a.effect = "appear"
            a.start = .withPrevious
            a.durationMs = 0
            a.trigger = d.id
            anims.append(a)
        }
        addSlide(&p, digits, anims, true)
        var show = try Show(p)
        func showing() -> [Int] { (0 ..< n).filter { show.shown("Score \($0)") } }
        #expect(showing() == [0])
        for click in 0 ..< 2 * n {
            let now = click % n
            #expect(showing() == [now], "before click \(click)")
            #expect(show.isTarget("Score \(now)"))
            #expect(show.click("Score \(now)") == .animated)
        }
        #expect(showing() == [0])
    }
}

// MARK: - it/chart_native.rs

private let workbook: [UInt8] = Array("original-synthetic-workbook".utf8) + [0, 0xFF, 0x80]
private let drawing: [UInt8] = Array(#"<c:userShapes xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"/>"#.utf8)
private let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private func chartOf(_ p: Presentation) -> Chart? {
    if case .chart(let c)? = p.slides.first?.shapes.first?.kind { return c }
    Issue.record("chart")
    return nil
}

private func chartSource() throws -> [UInt8] {
    var p = newPresentation(nil)
    var sh = Shape.default
    sh.id = ShapeId(p.allocId() ?? 0)
    sh.name = "Owned chart"
    sh.xfrm = Xfrm(40.0, 40.0, 400.0, 300.0)
    sh.kind = .chart(Chart.sample(.pie))
    p.slides[0].shapes = [sh]
    // Start with our own chart XML, then give it two original, synthetic package parts.
    var q = try PPTX.import(PPTX.export(p))
    guard case .chart(var c) = q.slides[0].shapes[0].kind else { throw EngineError.other("chart") }
    c.raw = c.raw.map { $0.replacingOccurrences(of: "</c:chartSpace>", with: #"<c:externalData r:id="rWorkbook"/><c:userShapes r:id="rDrawing"/></c:chartSpace>"#) }
    c.kept = ChartKept(
        rels: [
            ChartRel(id: "rWorkbook", relType: "\(relNS)/package", target: "../embeddings/owned.xlsx", part: "ppt/embeddings/owned.xlsx", external: false),
            ChartRel(id: "rDrawing", relType: "\(relNS)/chartUserShapes", target: "../drawings/owned.xml", part: "ppt/drawings/owned.xml", external: false),
        ],
        parts: [
            ChartPart(name: "ppt/embeddings/owned.xlsx", contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", bytes: workbook),
            ChartPart(name: "ppt/drawings/owned.xml", contentType: "application/vnd.openxmlformats-officedocument.drawingml.chartshapes+xml", bytes: drawing),
        ]
    )
    q.slides[0].shapes[0].kind = .chart(c)
    return try PPTX.export(q)
}

private func openBytes(_ bytes: [UInt8], _ name: String) throws -> Session {
    let s = Session()
    _ = try s.execute("file.openBytes", ["name": .string(name), "data": .string(Cmd.base64Encode(bytes))])
    return s
}

private func saveBytes(_ s: Session, _ format: String) throws -> [UInt8] {
    let out = try s.execute("file.saveBytes", ["format": .string(format)])
    return try #require(out["data"]?.asStr.flatMap(Cmd.base64Decode))
}

@Suite("Native saves keep chart parts")
struct ChartNativeTests {
    // Rust: tests/it/chart_native.rs::pptx_native_edit_save_reopen_keeps_chart_parts
    @Test func pptxNativeEditSaveReopenKeepsChartParts() throws {
        var s = try openBytes(chartSource(), "owned.pptx")
        let kept = try #require(chartOf(s.st.doc)).kept
        #expect(kept.rels.count == 2, "fixture relationships must have been imported")
        #expect(kept.parts.count == 2)
        _ = try s.execute("file.properties", ["title": "Edited title"])
        for _ in 0 ..< 2 {
            s = try openBytes(saveBytes(s, "deckcraft"), "owned.deckcraft")
            let p = s.st.doc
            #expect(p.props.title == "Edited title")
            #expect(chartOf(p)?.kept == kept)
        }
        let bytes = try saveBytes(s, "pptx")
        let z = try ZipReader(bytes)
        let payloads = try z.entries.map { ($0.name, try z.read($0, max: 1 << 30)) }
        #expect(payloads.contains { $0.0.hasPrefix("ppt/embeddings/") && $0.1 == workbook })
        #expect(payloads.contains { $0.0.hasPrefix("ppt/drawings/") && $0.1 == drawing })
        let back = try PPTX.import(bytes)
        #expect(chartOf(back)?.kept.rels.count == 2)
        for part in kept.parts {
            #expect(chartOf(back)?.kept.parts.contains { $0.contentType == part.contentType && $0.bytes == part.bytes } ?? false)
        }
    }

    // Rust: tests/it/chart_native.rs::editing_chart_after_native_reopen_does_not_export_a_stale_workbook
    @Test func editingChartAfterNativeReopenDoesNotExportAStaleWorkbook() throws {
        var s = try openBytes(chartSource(), "owned.pptx")
        s = try openBytes(saveBytes(s, "deckcraft"), "owned.deckcraft")
        var p = s.st.doc
        guard case .chart(var c) = p.slides[0].shapes[0].kind else {
            Issue.record("chart")
            return
        }
        #expect(c.kept.rels.count == 2)
        c.series[0].values[0] = 99.0
        p.slides[0].shapes[0].kind = .chart(c)
        s.st.docRef = DocRef(p)
        let back = try PPTX.import(saveBytes(s, "pptx"))
        #expect(chartOf(back)?.series.first?.values.first == 99.0)
        #expect(chartOf(back)?.kept.parts.isEmpty ?? false, "stale source workbook must not be attached to edited chart data")
    }
}

// MARK: - show_paragraph_builds.rs

private func buildShape(_ p: inout Presentation, _ name: String, _ text: String, _ y: Double) -> Shape {
    var s = Shape.default
    s.id = ShapeId(p.allocId() ?? 0)
    s.name = name
    s.xfrm = Xfrm(100.0, y, 600.0, 150.0)
    s.text = TextBody.fromText(text)
    return s
}

/// Two slides: "Body" (paragraphs `body`, at `levels`) and "Picture" on the first, nothing on the second,
/// saved as PPTX.
private func saved(_ body: String, _ levels: [UInt8]) throws -> [UInt8] {
    var p = newPresentation(nil)
    p.slides.removeAll()
    var b = buildShape(&p, "Body", body, 50.0)
    if var t = b.text {
        for (i, lvl) in zip(t.paragraphs.indices, levels) { t.paragraphs[i].level = lvl }
        b.text = t
    }
    let pic = buildShape(&p, "Picture", "Picture", 300.0)
    var a0 = Animation.default
    a0.shape = b.id
    a0.textBuild = .byParagraph
    a0.start = .onClick
    a0.durationMs = 500
    var a1 = Animation.default
    a1.shape = pic.id
    a1.start = .withPrevious
    a1.durationMs = 500
    for (shapes, animations) in [([b, pic], [a0, a1]), ([], [])] {
        let layout = layoutOfKind(p, .blank) ?? .default
        guard var s = newSlide(&p, layout) else { throw EngineError.other("slide") }
        s.shapes = shapes
        s.animations = animations
        p.slides.append(s)
    }
    return try PPTX.export(p)
}

private func spid(_ xml: String, _ name: String) -> String {
    guard let at = xml.range(of: "name=\"\(name)\"") else { return "" }
    let head = xml[..<at.lowerBound]
    guard let idAt = head.range(of: "id=\"", options: .backwards) else { return "" }
    return String(head[idAt.upperBound...].prefix { $0 != "\"" })
}

/// One effect node as PowerPoint writes it: Fade in on `spid` (paragraph `para`).
private func effect(_ ids: inout UInt32, _ spid: String, _ para: UInt32?, _ node: String) -> String {
    func next() -> UInt32 {
        ids += 1
        return ids
    }
    let tgt = para.map { #"<p:spTgt spid="\#(spid)"><p:txEl><p:pRg st="\#($0)" end="\#($0)"/></p:txEl></p:spTgt>"# } ?? #"<p:spTgt spid="\#(spid)"/>"#
    let (a, b, c) = (next(), next(), next())
    return #"<p:par><p:cTn id="\#(a)" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" grpId="0" nodeType="\#(node)"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst><p:set><p:cBhvr><p:cTn id="\#(b)" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn><p:tgtEl>\#(tgt)</p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set><p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="\#(c)" dur="500"/><p:tgtEl>\#(tgt)</p:tgtEl></p:cBhvr></p:animEffect></p:childTnLst></p:cTn></p:par>"#
}

/// A click group holding `effects`.
private func click(_ ids: inout UInt32, _ effects: [String]) -> String {
    ids += 2
    return #"<p:par><p:cTn id="\#(ids - 1)" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst><p:par><p:cTn id="\#(ids)" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\#(effects.joined())</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>"#
}

/// `bytes` with the first slide's timing replaced by `clicks` (built with `effect` and `click` from the
/// spids of Body and Picture), Body's build "By paragraph".
private func withTiming(_ bytes: [UInt8], _ clicks: (inout UInt32, String, String) -> [String]) throws -> [UInt8] {
    let src = try ZipReader(bytes)
    var out = ZipWriter()
    for e in src.entries {
        var data = try src.read(e, max: 1 << 30)
        if e.name == "ppt/slides/slide1.xml" {
            let xml = String(decoding: data, as: UTF8.self)
            let (body, pic) = (spid(xml, "Body"), spid(xml, "Picture"))
            var ids: UInt32 = 2
            let main = clicks(&ids, body, pic).joined()
            let timing = #"<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst><p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\#(main)</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst><p:bldLst><p:bldP spid="\#(body)" grpId="0" build="p"/><p:bldP spid="\#(pic)" grpId="0" animBg="1"/></p:bldLst></p:timing>"#
            guard let a = xml.range(of: "<p:timing>"), let b = xml.range(of: "</p:timing>") else { throw EngineError.other("timing") }
            data = Array((String(xml[..<a.lowerBound]) + timing + String(xml[b.upperBound...])).utf8)
        }
        try out.add(e.name, data)
    }
    return try out.finish()
}

/// Clicks (Next with nothing playing) from the start of the first slide to the second one.
private func clicksToSecondSlide(_ pres: Presentation) -> Int {
    var s = ShowState(pres)
    for n in 1 ... 50 {
        switch s.next(pres) {
        case .playStep:
            // The step clock runs out before the next click.
            _ = s.stepDone(pres)
        case .slide(1):
            return n
        case let a:
            Issue.record("unexpected \(a)")
            return -1
        }
    }
    return Int.max
}

/// The first slide's XML in a saved PPTX.
private func slideXML(_ bytes: [UInt8]) throws -> String {
    String(decoding: try ZipReader(bytes).read(named: "ppt/slides/slide1.xml", max: 1 << 30), as: UTF8.self)
}

private struct Eff: Equatable {
    var paragraph: UInt32?
    var start: AnimStart
    var build: TextBuild
}

/// Paragraph and start of each animation on the first slide.
private func effects(_ pres: Presentation) -> [Eff] {
    pres.slides[0].animations.map { Eff(paragraph: $0.paragraph, start: $0.start, build: $0.textBuild) }
}

/// "By 1st level paragraphs" as PowerPoint writes it: a sub-point comes in with its parent.
private func firstLevelBuild() throws -> [UInt8] {
    try withTiming(saved("One\nSub\nTwo", [0, 1, 0])) { ids, body, pic in
        let e0 = effect(&ids, body, 0, "clickEffect")
        let e1 = effect(&ids, body, 1, "withEffect")
        let e2 = effect(&ids, body, 2, "clickEffect")
        let ep = effect(&ids, pic, nil, "withEffect")
        return [click(&ids, [e0, e1]), click(&ids, [e2, ep])]
    }
}

/// Body's three paragraphs under `build="p"`, effects in the order `effects` gives them, then Picture with
/// the last one.
private func threeParagraphs(_ effects: (inout UInt32, String) -> [String]) throws -> Presentation {
    let bytes = try withTiming(saved("One\nTwo\nThree", [0, 0, 0])) { ids, body, pic in
        var clicks: [String] = []
        for e in effects(&ids, body) { clicks.append(click(&ids, [e])) }
        let ep = effect(&ids, pic, nil, "clickEffect")
        clicks.append(click(&ids, [ep]))
        return clicks
    }
    return try PPTX.import(bytes)
}

@Suite("Paragraph builds from PPTX")
struct ShowParagraphBuildTests {
    private func splitBuild() throws -> [UInt8] {
        try withTiming(saved("One\nTwo\nThree", [0, 0, 0])) { ids, body, pic in
            let e0 = effect(&ids, body, 0, "clickEffect")
            let ep = effect(&ids, pic, nil, "withEffect")
            let e1 = effect(&ids, body, 1, "clickEffect")
            let e2 = effect(&ids, body, 2, "clickEffect")
            return [click(&ids, [e0, ep]), click(&ids, [e1]), click(&ids, [e2])]
        }
    }

    // Rust: tests/show_paragraph_builds.rs::a_paragraph_build_split_by_another_shapes_effect_takes_powerpoints_clicks
    @Test func aParagraphBuildSplitByAnotherShapesEffectTakesPowerpointsClicks() throws {
        // As PowerPoint writes "Body: By paragraph, Picture: With Previous after the first paragraph": click 1 =
        // Body ¶0 + Picture, click 2 = Body ¶1, click 3 = Body ¶2.
        let pres = try PPTX.import(splitBuild())
        #expect(ShowState.steps(pres, 0) == 3, "three click steps, as in the file")
        #expect(clicksToSecondSlide(pres) == 4, "three builds and one click to move on")
    }

    // Rust: tests/show_paragraph_builds.rs::a_build_by_second_level_paragraphs_takes_a_click_per_paragraph
    @Test func aBuildBySecondLevelParagraphsTakesAClickPerParagraph() throws {
        // "By 2nd level paragraphs": the heading and each sub-point have their own click. Picture comes in with
        // the last one, so nothing splits Body's build.
        let bytes = try withTiming(saved("Question\nFirst\nSecond", [0, 1, 1])) { ids, body, pic in
            let e0 = effect(&ids, body, 0, "clickEffect")
            let e1 = effect(&ids, body, 1, "clickEffect")
            let e2 = effect(&ids, body, 2, "clickEffect")
            let ep = effect(&ids, pic, nil, "withEffect")
            return [click(&ids, [e0]), click(&ids, [e1]), click(&ids, [e2, ep])]
        }
        let pres = try PPTX.import(bytes)
        #expect(ShowState.steps(pres, 0) == 3, "three click steps, as in the file")
    }

    // Rust: tests/show_paragraph_builds.rs::a_whole_first_level_build_still_reads_as_one_by_paragraph_animation
    @Test func aWholeFirstLevelBuildStillReadsAsOneByParagraphAnimation() throws {
        let pres = try PPTX.import(firstLevelBuild())
        #expect(effects(pres).first == Eff(paragraph: nil, start: .onClick, build: .byParagraph))
        #expect(pres.slides[0].animations.count == 2, "Body's build and Picture")
        #expect(ShowState.steps(pres, 0) == 2)
    }

    // Rust: tests/show_paragraph_builds.rs::a_by_paragraph_build_with_sub_points_survives_saving
    @Test func aByParagraphBuildWithSubPointsSurvivesSaving() throws {
        let pres = try PPTX.import(firstLevelBuild())
        let again = try PPTX.import(PPTX.export(pres))
        #expect(effects(again) == effects(pres))
        #expect(ShowState.steps(again, 0) == 2, "the sub-point still comes in with its parent")
    }

    // Rust: tests/show_paragraph_builds.rs::paragraph_effects_save_as_powerpoint_writes_them_and_read_back_unchanged
    @Test func paragraphEffectsSaveAsPowerpointWritesThemAndReadBackUnchanged() throws {
        let pres = try PPTX.import(splitBuild())
        let savedBytes = try PPTX.export(pres)
        let xml = try slideXML(savedBytes)
        let body = spid(xml, "Body")
        let blds = xml.components(separatedBy: "<p:bldP ").dropFirst().filter { $0.hasPrefix("spid=\"\(body)\"") }
        // ¶0 is its own build (Picture sits between), ¶1 and ¶2 share one.
        #expect(blds.count == 2, "\(blds)")
        #expect(blds.allSatisfy { $0.contains(#"build="p""#) && !$0.contains("animBg") }, "\(blds)")
        let again = try PPTX.import(savedBytes)
        #expect(effects(again) == effects(pres))
        #expect(ShowState.steps(again, 0) == 3)
    }

    // Rust: tests/show_paragraph_builds.rs::a_by_paragraph_build_on_blank_text_saves_as_a_whole_shape_effect
    @Test func aByParagraphBuildOnBlankTextSavesAsAWholeShapeEffect() throws {
        let xml = try slideXML(saved(" ", [0]))
        #expect(!xml.contains(#"build="p""#), "no paragraph build without a paragraph to animate")
        #expect(!xml.contains("<p:txEl>"), "the effect targets the whole shape")
    }

    // Rust: tests/show_paragraph_builds.rs::a_reversed_build_keeps_its_order
    @Test func aReversedBuildKeepsItsOrder() throws {
        let pres = try threeParagraphs { ids, body in [2, 1, 0].map { effect(&ids, body, $0, "clickEffect") } }
        #expect(pres.slides[0].animations.map(\.paragraph) == [2, 1, 0, nil], "last paragraph first, as in the file")
    }

    // Rust: tests/show_paragraph_builds.rs::a_paragraph_with_its_own_duration_keeps_its_own_effect
    @Test func aParagraphWithItsOwnDurationKeepsItsOwnEffect() throws {
        let pres = try threeParagraphs { ids, body in
            (0 ..< 3).map { p -> String in
                let e = effect(&ids, body, UInt32(p), "clickEffect")
                return p == 1 ? e.replacingOccurrences(of: #"dur="500""#, with: #"dur="900""#) : e
            }
        }
        let durs = pres.slides[0].animations.map { "\($0.paragraph.map(String.init) ?? "-"):\($0.durationMs)" }
        #expect(durs == ["0:500", "1:900", "2:500", "-:500"])
    }
}
