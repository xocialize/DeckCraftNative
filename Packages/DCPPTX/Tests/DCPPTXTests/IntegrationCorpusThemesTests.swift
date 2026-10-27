// Port of deckcraft crates/pptx/tests/it/corpus_themes.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned corpus: themes, several masters and layouts, shape effects (shadow, glow, soft edge, reflection)
// and hyperlinks and actions on text and shapes.
//
// The decks are built as PowerPoint writes them: a DeckCraft package whose theme, slides and
// relationships are replaced with PowerPoint-shaped XML, and a two-master deck built in the model. The
// check is open → save → reopen with nothing lost.
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCZip
import Testing
@testable import DCPPTX

/// Replace (or add) parts of a package.
private func repack(_ bytes: [UInt8], _ parts: [(String, String)]) throws -> [UInt8] {
    var out: [(name: String, data: [UInt8])] = []
    for e in try IT.entries(bytes) where !parts.contains(where: { $0.0 == e.name }) {
        out.append(e)
    }
    for (n, xml) in parts { out.append((n, Array(xml.utf8))) }
    return try IT.zip(out)
}

private func part(_ bytes: [UInt8], _ name: String) throws -> String {
    let d = try #require(IT.part(bytes, name), "\(name)")
    return String(decoding: d, as: UTF8.self)
}

private func shapeNamed(_ p: Presentation, _ slide: Int, _ n: String) throws -> Shape {
    try #require(p.slides[slide].shapes.first { bytesEqual($0.name, n) }, "no shape \(n)")
}

private let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#

private func sp(_ id: UInt32, _ name: String, _ nvExtra: String, _ x: UInt32, _ effects: String, _ body: String) -> String {
    #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="\#(name)">\#(nvExtra)</p:cNvPr><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\#(x)" y="1270000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm><a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom><a:solidFill><a:schemeClr val="accent1"/></a:solidFill><a:effectLst>\#(effects)</a:effectLst></p:spPr><p:txBody><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/>\#(body)</p:txBody></p:sp>"#
}

/// A two-slide PowerPoint-style deck: a custom theme, effects on four shapes, and text and shape
/// hyperlinks of every common kind.
private func effectsAndLinks() throws -> [UInt8] {
    var p = newPresentation(nil)
    let layout = layoutOfKind(p, .blank) ?? LayoutId.default
    for _ in 0 ..< 2 {
        let sOpt = newSlide(&p, layout)
        let s = try #require(sOpt, "slide")
        p.slides.append(s)
    }
    p.slides = Array(p.slides.prefix(2))
    let base = try PPTX.export(p)
    let rels = try part(base, "ppt/slides/_rels/slide1.xml.rels").replace(
        "</Relationships>",
        #"<Relationship Id="rId90" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/report?q=1&amp;r=2" TargetMode="External"/><Relationship Id="rId91" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slide2.xml"/><Relationship Id="rId92" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="mailto:team@example.com?subject=Deck" TargetMode="External"/></Relationships>"#
    )
    let shadow = sp(
        10,
        "Shadowed",
        #"<a:hlinkClick r:id="" action="ppaction://hlinkshowjump?jump=endshow" highlightClick="1"/><a:hlinkHover r:id="rId90" tooltip="Hover for the report"/>"#,
        254000,
        #"<a:outerShdw blurRad="76200" dist="38100" dir="2700000" sx="102000" sy="102000" algn="tl" rotWithShape="0"><a:prstClr val="black"><a:alpha val="40000"/></a:prstClr></a:outerShdw>"#,
        #"<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>Shadow</a:t></a:r></a:p>"#
    )
    let glow = sp(
        11,
        "Glowing",
        "",
        3048000,
        #"<a:glow rad="139700"><a:schemeClr val="accent2"><a:satMod val="175000"/><a:alpha val="40000"/></a:schemeClr></a:glow>"#,
        #"<a:p><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId90" tooltip="Open the report"/></a:rPr><a:t>Report</a:t></a:r><a:r><a:rPr lang="en-US"/><a:t> and </a:t></a:r><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId91" action="ppaction://hlinksldjump"/></a:rPr><a:t>appendix</a:t></a:r></a:p>"#
    )
    let soft = sp(
        12,
        "Soft edged",
        "",
        5842000,
        #"<a:softEdge rad="63500"/>"#,
        #"<a:p><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="" action="ppaction://hlinkshowjump?jump=nextslide"/></a:rPr><a:t>Next</a:t></a:r><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId92"/></a:rPr><a:t> mail us</a:t></a:r></a:p>"#
    )
    let refl = sp(
        13,
        "Reflected",
        "",
        8636000,
        #"<a:reflection blurRad="6350" stA="50000" endA="300" endPos="55500" dist="50800" dir="5400000" sy="-100000" algn="bl" rotWithShape="0"/>"#,
        #"<a:p><a:r><a:rPr lang="en-US"><a:hlinkMouseOver r:id="rId90" tooltip="Preview"/></a:rPr><a:t>Hover me</a:t></a:r></a:p>"#
    )
    let slide = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld \#(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(shadow)\#(glow)\#(soft)\#(refl)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#
    return try repack(base, [("ppt/slides/slide1.xml", slide), ("ppt/slides/_rels/slide1.xml.rels", rels)])
}

private func fx(_ s: Shape) -> Effects { s.effects ?? .default }

private func runLinks(_ s: Shape) -> [(String, Hyperlink?)] {
    (s.text?.paragraphs ?? []).flatMap(\.runs).map { ($0.text, $0.props.link) }
}

private func runHovers(_ s: Shape) -> [Hyperlink?] {
    (s.text?.paragraphs ?? []).flatMap(\.runs).map(\.props.hover)
}

/// Two masters with their own themes (colours, fonts) and layouts, slides on each.
private func twoMasters() throws -> Presentation {
    var p = newPresentation(nil)
    var second = p.masters[0]
    second.id = MasterId(p.allocId() ?? 0)
    second.name = "Brand Dark"
    second.theme.name = "Brand Dark Theme"
    second.theme.colors.name = "Brand Colours"
    second.theme.colors.colors[4] = .rgb(0x12, 0x34, 0x56)
    second.theme.colors.colors[2] = .rgb(0x20, 0x20, 0x30)
    second.theme.fonts.name = "Brand Fonts"
    second.theme.fonts.major.latin = "Georgia"
    second.theme.fonts.minor.latin = "Verdana"
    second.background = .fill(fill: .solid(.rgb(.rgb(0x10, 0x10, 0x18))))
    for i in second.layouts.indices {
        second.layouts[i].id = LayoutId(p.allocId() ?? 0)
        second.layouts[i].name = "Dark \(second.layouts[i].name)"
    }
    second.layouts = Array(second.layouts.prefix(4))
    let darkLayout = second.layouts[1].id
    p.masters.append(second)
    let lightLayout = p.masters[0].layouts[0].id
    let s1Opt = newSlide(&p, lightLayout)
    let s1 = try #require(s1Opt, "slide")
    let s2Opt = newSlide(&p, darkLayout)
    let s2 = try #require(s2Opt, "slide")
    p.slides = [s1, s2]
    return p
}

@Suite struct IntegrationCorpusThemesTests {
    // Rust: it/corpus_themes.rs::effects_and_links_survive_a_round_trip
    @Test func effectsAndLinksSurviveARoundTrip() throws {
        let bytes = try effectsAndLinks()
        let a = try PPTX.import(bytes)
        func get(_ n: String) throws -> Shape { try shapeNamed(a, 0, n) }
        // Read as PowerPoint wrote them.
        let sh = try #require(fx(try get("Shadowed")).outerShadow, "shadow")
        #expect(abs(sh.blur - 6.0) < 1e-6 && abs(sh.dist - 3.0) < 1e-6 && abs(sh.dir - 45.0) < 1e-6, "\(sh)")
        #expect(sh.align == "tl" && sh.rotateWithShape == false)
        #expect(abs(sh.sx - 1.02) < 1e-6)
        #expect(fx(try get("Glowing")).glow.map { abs($0.radius - 11.0) < 1e-6 } == true)
        #expect(fx(try get("Soft edged")).softEdge == 5.0)
        let r = try #require(fx(try get("Reflected")).reflection, "reflection")
        #expect(abs(r.endPos - 0.555) < 1e-6 && abs(r.dist - 4.0) < 1e-6, "\(r)")
        let shape = try get("Shadowed")
        #expect(shape.click?.action == .endShow && shape.click?.highlightClick == true)
        if case .url(let url)? = shape.hover?.action {
            #expect(url.has("q=1&r=2"))
            #expect(shape.hover?.tooltip == "Hover for the report")
        } else {
            Issue.record("\(String(describing: shape.hover))")
        }
        var links = runLinks(try get("Glowing"))
        try #require(links.count >= 3)
        if case .url? = links[0].1?.action {
            #expect(links[0].1?.tooltip == "Open the report")
        } else {
            Issue.record("\(String(describing: links[0].1))")
        }
        #expect(links[1].1 == nil)
        #expect(links[2].1?.action == .slide(slide: a.slides[1].id))
        links = runLinks(try get("Soft edged"))
        try #require(links.count >= 2)
        #expect(links[0].1?.action == .nextSlide)
        if case .url(let url)? = links[1].1?.action {
            #expect(hasBytePrefix(url, "mailto:"))
        } else {
            Issue.record("\(String(describing: links[1].1))")
        }
        let hover = try get("Reflected").text?.paragraphs.first?.runs.first?.props.hover
        if case .url? = hover?.action {
            #expect(hover?.tooltip == "Preview", "\(String(describing: hover))")
        } else {
            Issue.record("\(String(describing: hover))")
        }

        // Saved and reopened: the same effects and links.
        let b = try IT.round(a)
        func described(_ l: [(String, Hyperlink?)], _ s2: SlideId) -> [String] {
            l.map { t, h in
                let action = h.map { String(describing: $0.action).replace("slide(slide: \(s2))", "slide(slide: S2)") }
                return "\(t)|\(action ?? "nil")|\(h?.tooltip ?? "nil")"
            }
        }
        for n in ["Shadowed", "Glowing", "Soft edged", "Reflected"] {
            let sa = try shapeNamed(a, 0, n), sb = try shapeNamed(b, 0, n)
            #expect(fx(sa) == fx(sb), "effects of \(n)")
            #expect(sa.click == sb.click, "click of \(n)")
            #expect(sa.hover == sb.hover, "hover of \(n)")
            let la = described(runLinks(sa), a.slides[1].id)
            let lb = described(runLinks(sb), b.slides[1].id)
            #expect(la == lb, "text links of \(n)")
            #expect(runHovers(sa) == runHovers(sb), "text hover of \(n)")
        }
        let out = try PPTX.export(b)
        #expect(try part(out, "ppt/slides/slide1.xml").has("hlinkMouseOver"))
    }

    // Rust: it/corpus_themes.rs::themes_masters_and_layouts_survive_a_round_trip
    @Test func themesMastersAndLayoutsSurviveARoundTrip() throws {
        let a = try twoMasters()
        let b = try IT.round(a)
        try #require(b.masters.count == 2)
        for (ma, mb) in zip(a.masters, b.masters) {
            #expect(ma.name == mb.name)
            #expect(ma.theme.name == mb.theme.name)
            // The writer adds PowerPoint's empty objectDefaults/extraClrSchemeLst, kept as raw XML.
            func bare(_ t: Theme) -> Theme {
                var t = t
                t.rawExtra = nil
                return t
            }
            #expect(bare(ma.theme) == bare(mb.theme), "whole theme of \(ma.name)")
            #expect(ma.theme.colors == mb.theme.colors, "colour scheme of \(ma.name)")
            #expect(ma.theme.fonts.name == mb.theme.fonts.name)
            #expect(ma.theme.fonts.major.latin == mb.theme.fonts.major.latin)
            #expect(ma.theme.fonts.minor.latin == mb.theme.fonts.minor.latin)
            #expect(ma.background == mb.background, "background of \(ma.name)")
            #expect(ma.layouts.map(\.name) == mb.layouts.map(\.name))
        }
        // Each slide stays on its master's layout.
        func layoutName(_ p: Presentation, _ i: Int) -> String? {
            p.masters.flatMap(\.layouts).first { $0.id == p.slides[i].layout }?.name
        }
        for i in 0 ..< 2 {
            #expect(layoutName(a, i) == layoutName(b, i), "slide \(i)")
        }
        // A second save keeps the same theme and master parts.
        func names(_ bytes: [UInt8]) throws -> [String] {
            try ZipReader(bytes).entries.map(\.name)
                .filter { $0.has("theme") || $0.has("slideMaster") || $0.has("slideLayout") }
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        }
        let c = try IT.round(b)
        for (mb, mc) in zip(b.masters, c.masters) {
            #expect(mb.theme == mc.theme, "stable after a second save")
            // An empty map is the default one, which the writer spells out.
            #expect(mb.colorMap == mc.colorMap)
        }
        let once = try PPTX.export(b)
        let twice = try PPTX.export(PPTX.import(once))
        #expect(try names(once) == names(twice))
    }
}
