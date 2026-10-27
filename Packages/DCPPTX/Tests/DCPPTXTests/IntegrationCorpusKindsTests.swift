// Port of deckcraft crates/pptx/tests/it/corpus_kinds.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
//
// Owned corpus of more deck kinds: tables, charts, animations, media, sections, masters and layouts.
//
// Each package is built here. The check is open → save → reopen: text in the package and the content
// parts. A second save keeps the same part names and text.
import DCCore
import DCModel
import Testing
@testable import DCPPTX

private func slideWith(_ p: inout Presentation, _ kind: LayoutType, _ title: String) throws -> Slide {
    let layout = layoutOfKind(p, kind) ?? LayoutId.default
    let made = newSlide(&p, layout)
    var s = try #require(made, "slide")
    if !s.shapes.isEmpty { s.shapes[0].text = TextBody.fromText(title) }
    return s
}

private func tables() throws -> Presentation {
    var p = newPresentation(nil)
    var s = try slideWith(&p, .titleOnly, "Regions")
    var t = Table(rows: 3, cols: 3, width: 420.0, rowHeight: 28.0)
    for (r, c, text) in [
        (0, 0, "Quarter"),
        (0, 1, "Region"),
        (0, 2, "Amount"),
        (1, 0, "Q1"),
        (1, 1, "North"),
        (1, 2, "12"),
        (2, 0, "Q2"),
        (2, 1, "South"),
        (2, 2, "Total"),
    ] {
        t.mutateCell(r, c) { $0.text = TextBody.fromText(text) }
    }
    _ = t.merge(2, 1, 1, 2)
    t.style = "light2-accent3"
    var ts = IT.shape(&p, "Region table", 80.0, 140.0, 420.0, 84.0)
    ts.kind = .table(t)
    s.shapes.append(ts)
    p.slides = [s]
    return p
}

private func chartOf(_ p: inout Presentation, _ name: String, _ kind: ChartType, _ title: String, _ x: Double) -> Shape {
    var chart = Chart.sample(kind)
    chart.title = title
    chart.categories = ["Jan", "Feb"]
    chart.series = Array(chart.series.prefix(1))
    if !chart.series.isEmpty {
        chart.series[0].name = "Actual"
        chart.series[0].values = [10.0, 20.0]
    }
    if kind != .pie {
        chart.axisTitles = Pair("Month", "Amount due")
    }
    var ch = IT.shape(&p, name, x, 120.0, 280.0, 200.0)
    ch.kind = .chart(chart)
    return ch
}

private func charts() throws -> Presentation {
    var p = newPresentation(nil)
    var s = try slideWith(&p, .blank, "Charts")
    let a = chartOf(&p, "Column chart", .column, "Revenue", 40.0)
    let b = chartOf(&p, "Line chart", .line, "Trend", 340.0)
    let c = chartOf(&p, "Pie chart", .pie, "Share", 640.0)
    s.shapes += [a, b, c]
    p.slides = [s]
    return p
}

private func animations() throws -> Presentation {
    var p = newPresentation(nil)
    var s = try slideWith(&p, .titleOnly, "Motion")
    var flyer = IT.shape(&p, "Flyer", 80.0, 160.0, 200.0, 80.0)
    flyer.geom = Geom.preset("roundRect")
    flyer.text = TextBody.fromText("Fly in")
    let fly = flyer.id
    var built = IT.shape(&p, "Build list", 360.0, 160.0, 240.0, 120.0)
    built.text = TextBody.fromText("One\nTwo\nThree")
    let body = built.id
    s.shapes += [flyer, built]
    var a1 = Animation.default
    a1.shape = fly
    a1.effect = "fly"
    a1.option = "l"
    a1.durationMs = 750
    var a2 = Animation.default
    a2.shape = body
    a2.effect = "fade"
    a2.textBuild = .byParagraph
    a2.start = .afterPrevious
    a2.durationMs = 400
    s.animations = [a1, a2]
    var tr = Transition.default
    tr.kind = "wipe"
    tr.option = "l"
    tr.durationMs = 800
    s.transition = tr
    p.slides = [s]
    return p
}

private func media() throws -> Presentation {
    var p = newPresentation(nil)
    let m1 = p.addMedia("mark.png", "image/png", IT.png(4, 4, (20, 90, 160)))
    let picture = try #require(m1, "media")
    let m2 = p.addMedia("tone.wav", "audio/wav", Array("owned-wav-tone".utf8))
    let tone = try #require(m2, "media")
    let m3 = p.addMedia("clip.mp4", "video/mp4", Array("owned-mp4-clip".utf8))
    let clip = try #require(m3, "media")
    var s = try slideWith(&p, .titleOnly, "Media")
    var pic = IT.shape(&p, "Mark", 60.0, 120.0, 80.0, 80.0)
    pic.kind = .picture(fill: PictureFill(media: picture))
    pic.geom = Geom.preset("rect")
    var audio = IT.shape(&p, "Tone", 180.0, 120.0, 80.0, 80.0)
    audio.kind = .media(MediaClip(media: tone, video: false, bookmarks: [Pair("Cue the demo", 400)]))
    var video = IT.shape(&p, "Clip", 300.0, 120.0, 160.0, 90.0)
    video.kind = .media(MediaClip(media: clip, video: true, poster: picture))
    s.shapes += [pic, audio, video]
    p.slides = [s]
    return p
}

private func sections() throws -> Presentation {
    var p = newPresentation(nil)
    var first = try slideWith(&p, .title, "Opening remarks")
    if first.shapes.count > 1 {
        var props = RunProps()
        props.link = Hyperlink(
            action: .url(url: "https://example.org/brief?q=1&x=2"), tooltip: "Open the brief", highlightClick: false,
            sound: nil, stopSound: false, zoomReturn: nil
        )
        first.shapes[1].text = TextBody(paragraphs: [Paragraph(runs: [Run.with("Brief", props)])])
    }
    let second = try slideWith(&p, .sectionHeader, "Figures")
    let ids = [first.id, second.id]
    p.slides = [first, second]
    p.sections = [
        Section(name: "Opening", slides: [ids[0]]),
        Section(name: "Figures", slides: [ids[1]]),
    ]
    p.customShows = [CustomShow(name: "Short show", slides: [ids[0]])]
    return p
}

private func masters() throws -> Presentation {
    var p = newPresentation(nil)
    if !p.masters.isEmpty, let f = p.masters[0].shapes.firstIndex(where: { $0.phType == .footer }) {
        p.masters[0].shapes[f].text = TextBody.fromText("Slide footer line")
    }
    var evening = try #require(p.masters.first, "master")
    let id1 = p.allocId()
    evening.id = MasterId(try #require(id1, "id"))
    evening.name = "Evening"
    evening.shapes.removeAll { $0.phType == nil }
    var banner = IT.shape(&p, "Evening banner", 40.0, 40.0, 400.0, 40.0)
    banner.text = TextBody.fromText("Evening master")
    evening.shapes.append(banner)
    var quote = try #require(evening.layouts.first, "layout")
    let id2 = p.allocId()
    quote.id = LayoutId(try #require(id2, "id"))
    quote.name = "Quote"
    quote.kind = .custom
    quote.shapes.removeAll { !($0.phType == .ctrTitle || $0.phType == .title) }
    var line = IT.shape(&p, "Quote line", 80.0, 200.0, 600.0, 80.0)
    line.text = TextBody.fromText("Pull quote")
    quote.shapes.append(line)
    evening.layouts = [quote]
    let quoteId = quote.id
    p.masters.append(evening)

    let title = try slideWith(&p, .title, "Welcome")
    let agenda = try slideWith(&p, .sectionHeader, "Agenda")
    let compared = try slideWith(&p, .comparison, "Comparison")
    let made = newSlide(&p, quoteId)
    var quoted = try #require(made, "slide")
    if !quoted.shapes.isEmpty { quoted.shapes[0].text = TextBody.fromText("A line") }
    p.slides = [title, agenda, compared, quoted]
    return p
}

/// The package's parts by name (a `BTreeMap`: listed in byte order).
private struct Pkg {
    var parts: [String: [UInt8]] = [:]

    /// The part names in byte order, as the `BTreeMap` iterates them.
    var names: [String] { parts.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }

    static func open(_ bytes: [UInt8]) throws -> Pkg {
        var pkg = Pkg()
        for e in try IT.entries(bytes) where !e.name.hasSuffix("/") {
            let name = String(e.name.drop { $0 == "/" })
            pkg.parts[name] = e.data
        }
        return pkg
    }

    func bytes() throws -> [UInt8] {
        try IT.zip(names.map { ($0, parts[$0] ?? []) })
    }

    mutating func textMut(_ name: String, _ body: String) {
        parts[name] = Array(body.utf8)
    }
}

// MARK: Text in the package, byte-wise as the Rust scans it

private func indexOf(_ h: ArraySlice<UInt8>, _ n: [UInt8]) -> Int? {
    guard !n.isEmpty else { return h.startIndex }
    guard h.count >= n.count else { return nil }
    var i = h.startIndex
    while i + n.count <= h.endIndex {
        if h[i] == n[0], h[i ..< i + n.count].elementsEqual(n) { return i }
        i += 1
    }
    return nil
}

/// Text in the package: element texts, slide, section and show names, web link targets and tooltips,
/// with how often each appears.
private func xmlText(_ parts: [String: [UInt8]]) -> [[UInt8]: Int] {
    var counts: [[UInt8]: Int] = [:]
    for (name, bytes) in parts {
        let lower = rustASCIILowercase(name)
        if !(hasByteSuffix(lower, ".xml") || hasByteSuffix(lower, ".rels")) { continue }
        guard String(validating: bytes, as: UTF8.self) != nil else { continue }
        for tag in ["a:t", "c:v", "p:text", "dc:title", "dc:subject", "dc:creator", "dc:description"] {
            for text in elementTexts(bytes, tag) where !text.isEmpty {
                counts[text, default: 0] += 1
            }
        }
        for tag in ["p:cSld", "p14:section", "p:custShow"] {
            for text in tagAttr(bytes, tag, "name") where !text.isEmpty {
                counts[text, default: 0] += 1
            }
        }
        for url in attrValues(bytes, "Target") {
            let u = String(decoding: url, as: UTF8.self)
            if hasBytePrefix(u, "http://") || hasBytePrefix(u, "https://") { counts[url, default: 0] += 1 }
        }
        for tip in attrValues(bytes, "tooltip") where !tip.isEmpty {
            counts[tip, default: 0] += 1
        }
    }
    return counts
}

private func elementTexts(_ xml: [UInt8], _ tag: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    let open = Array("<\(tag)".utf8), close = Array("</\(tag)>".utf8)
    var rest = xml[...]
    while let i = indexOf(rest, open) {
        let after = rest[(i + open.count)...]
        guard let boundary = after.first, [UInt8]("> \n\t\r/".utf8).contains(boundary) else {
            rest = after
            continue
        }
        guard let gt = indexOf(after, [UInt8(ascii: ">")]) else { break }
        // `after.as_bytes().get(gt.saturating_sub(1))`
        if after[Swift.max(gt - 1, after.startIndex)] == UInt8(ascii: "/") {
            rest = after[(gt + 1)...]
            continue
        }
        let body = after[(gt + 1)...]
        guard let end = indexOf(body, close) else { break }
        out.append(decodeXML(body[body.startIndex ..< end]))
        rest = body[(end + close.count)...]
    }
    return out
}

private func tagAttr(_ xml: [UInt8], _ tag: String, _ attr: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    let open = Array("<\(tag)".utf8), key = Array("\(attr)=\"".utf8)
    var rest = xml[...]
    while let i = indexOf(rest, open) {
        let after = rest[i...]
        guard let gt = indexOf(after, [UInt8(ascii: ">")]) else { break }
        if let k = indexOf(after[after.startIndex ..< gt], key) {
            let start = k + key.count
            if let end = indexOf(after[start ..< gt], [UInt8(ascii: "\"")]) {
                out.append(decodeXML(after[start ..< end]))
            }
        }
        rest = after[(gt + 1)...]
    }
    return out
}

private func attrValues(_ xml: [UInt8], _ name: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    let key = Array("\(name)=\"".utf8)
    var rest = xml[...]
    while let i = indexOf(rest, key) {
        let after = rest[(i + key.count)...]
        guard let end = indexOf(after, [UInt8(ascii: "\"")]) else { break }
        out.append(decodeXML(after[after.startIndex ..< end]))
        rest = after[(end + 1)...]
    }
    return out
}

/// `u32::from_str_radix(s, 16)`.
private func parseHex(_ s: some StringProtocol) -> UInt32? {
    var u = Substring(s).utf8[...]
    if u.first == UInt8(ascii: "+") { u = u.dropFirst() }
    guard !u.isEmpty else { return nil }
    var v: UInt32 = 0
    for b in u {
        let d: UInt32
        switch b {
        case 0x30 ... 0x39: d = UInt32(b - 0x30)
        case 0x41 ... 0x46: d = UInt32(b - 0x41 + 10)
        case 0x61 ... 0x66: d = UInt32(b - 0x61 + 10)
        default: return nil
        }
        let (m, o1) = v.multipliedReportingOverflow(by: 16)
        let (a, o2) = m.addingReportingOverflow(d)
        if o1 || o2 { return nil }
        v = a
    }
    return v
}

private func decodeXML(_ s: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    var rest = s
    while let i = indexOf(rest, [UInt8(ascii: "&")]) {
        out += rest[rest.startIndex ..< i]
        let after = rest[i...]
        guard let end = indexOf(after, [UInt8(ascii: ";")]) else {
            out += after
            return out
        }
        let ent = String(decoding: after[(i + 1) ..< end], as: UTF8.self)
        let scalar: (UInt32?) -> [UInt8] = { v in v.flatMap { Unicode.Scalar($0) }.map { Array(String($0).utf8) } ?? [] }
        let ch: [UInt8]
        if bytesEqual(ent, "amp") { ch = Array("&".utf8) }
        else if bytesEqual(ent, "lt") { ch = Array("<".utf8) }
        else if bytesEqual(ent, "gt") { ch = Array(">".utf8) }
        else if bytesEqual(ent, "quot") { ch = Array("\"".utf8) }
        else if bytesEqual(ent, "apos") { ch = Array("'".utf8) }
        else if hasBytePrefix(ent, "#x") || hasBytePrefix(ent, "#X") { ch = scalar(parseHex(String(decoding: ent.utf8.dropFirst(2), as: UTF8.self))) }
        else if hasBytePrefix(ent, "#") { ch = scalar(rustParseUnsigned(String(decoding: ent.utf8.dropFirst(), as: UTF8.self), as: UInt32.self)) }
        else { ch = [] }
        out += ch
        rest = after[(end + 1)...]
    }
    out += rest
    return out
}

private func partCount(_ parts: [String: [UInt8]], _ pred: (String) -> Bool) -> Int {
    parts.keys.filter(pred).count
}

/// Slides, charts, media, comments, handout masters.
private func contentCounts(_ parts: [String: [UInt8]]) -> [Int] {
    let isPart = { (prefix: String, name: String) -> Bool in
        let n = rustASCIILowercase(name)
        return hasBytePrefix(n, prefix) && hasByteSuffix(n, ".xml") && !n.has("_rels")
    }
    return [
        partCount(parts) { isPart("ppt/slides/slide", $0) },
        partCount(parts) { isPart("ppt/charts/chart", $0) },
        partCount(parts) { hasBytePrefix(rustASCIILowercase($0), "ppt/media/") && !rustASCIILowercase($0).has("_rels") },
        partCount(parts) { isPart("ppt/comments/comment", $0) },
        partCount(parts) { isPart("ppt/handoutmasters/handoutmaster", $0) },
    ]
}

private func lost(_ origin: [[UInt8]: Int], _ saved: [[UInt8]: Int]) -> [(String, Int, Int)] {
    origin.keys.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { s in
        let n = origin[s] ?? 0, got = saved[s] ?? 0
        return got < n ? (String(decoding: s, as: UTF8.self), n, got) : nil
    }
}

private func roundTrip(_ label: String, _ bytes: [UInt8]) throws -> (Pkg, Pkg) {
    let origin = try Pkg.open(bytes)
    let once = try PPTX.export(PPTX.import(bytes))
    let saved = try Pkg.open(once)
    let originText = xmlText(origin.parts)
    let missing = lost(originText, xmlText(saved.parts))
    #expect(missing.isEmpty, "\(label): text lost on save: \(missing)")
    #expect(contentCounts(origin.parts) == contentCounts(saved.parts), "\(label): content parts changed")
    let again = try PPTX.export(PPTX.import(once))
    let saved2 = try Pkg.open(again)
    #expect(saved.names == saved2.names, "\(label): part names changed on the second save")
    #expect(xmlText(saved.parts) == xmlText(saved2.parts), "\(label): text changed on the second save")
    return (origin, saved)
}

private func require(_ text: [[UInt8]: Int], _ label: String, _ words: [String]) {
    for s in words {
        #expect(text[Array(s.utf8)] != nil, "\(label) corpus is missing \(s)")
    }
}

private func ph(_ id: UInt32, _ kind: String, _ name: String, _ text: String) -> String {
    "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"\(kind)\"/></p:nvPr></p:nvSpPr>"
        + "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"3657600\" cy=\"365760\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
        + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
}

private func nextRid(_ rels: String) -> String {
    var max: UInt32 = 0
    var rest = rels
    while let i = rest.byteFind("rId") {
        let digits = String(decoding: rest.bytes(i + 3).utf8.prefix { $0 >= 0x30 && $0 <= 0x39 }, as: UTF8.self)
        if let n = rustParseUnsigned(digits, as: UInt32.self) {
            max = Swift.max(max, n)
        }
        rest = rest.bytes(i + 3)
    }
    return "rId\(max + 1)"
}

/// A deck whose handout master carries the header, footer, date and slide number.
private func handoutDeck() throws -> [UInt8] {
    var p = newPresentation(nil)
    let s = try slideWith(&p, .titleOnly, "Leave-behind")
    p.slides = [s]
    let bytes = try PPTX.export(p)
    var pkg = try Pkg.open(bytes)
    let master = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<p:handoutMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
        + "<p:cSld name=\"Handouts\"><p:spTree>"
        + "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
        + ph(2, "hdr", "Header Placeholder 1", "Board pack")
        + ph(3, "ftr", "Footer Placeholder 2", "Not for circulation")
        + ph(4, "dt", "Date Placeholder 3", "1 March 2026")
        + ph(5, "sldNum", "Slide Number Placeholder 4", "3")
        + "</p:spTree></p:cSld>"
        + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        + "</p:handoutMaster>"
    pkg.parts["ppt/handoutMasters/handoutMaster1.xml"] = Array(master.utf8)
    pkg.parts["ppt/handoutMasters/_rels/handoutMaster1.xml.rels"] = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/>"
            + "</Relationships>"
    ).utf8)
    let relsName = "ppt/_rels/presentation.xml.rels"
    let relsBytes = try #require(pkg.parts[relsName], "rels")
    let rels0 = try #require(String(validating: relsBytes, as: UTF8.self), "utf8")
    let rid = nextRid(rels0)
    let rels = rels0.replacen(
        "</Relationships>",
        "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/handoutMaster\" Target=\"handoutMasters/handoutMaster1.xml\"/></Relationships>",
        1
    )
    pkg.textMut(relsName, rels)
    let presName = "ppt/presentation.xml"
    let presBytes = try #require(pkg.parts[presName], "presentation")
    let pres0 = try #require(String(validating: presBytes, as: UTF8.self), "utf8")
    let list = "<p:handoutMasterIdLst><p:handoutMasterId r:id=\"\(rid)\"/></p:handoutMasterIdLst>"
    let pres: String
    if let at = pres0.byteFind("<p:sldIdLst") {
        pres = pres0.bytes(0, at) + list + pres0.bytes(at)
    } else {
        pres = pres0.replacen("<p:sldSz", "\(list)<p:sldSz", 1)
    }
    pkg.textMut(presName, pres)
    let ctBytes = try #require(pkg.parts["[Content_Types].xml"], "types")
    let ct0 = try #require(String(validating: ctBytes, as: UTF8.self), "utf8")
    let ct = ct0.replacen(
        "</Types>",
        "<Override PartName=\"/ppt/handoutMasters/handoutMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.handoutMaster+xml\"/></Types>",
        1
    )
    pkg.textMut("[Content_Types].xml", ct)
    return try pkg.bytes()
}

private func placeholderText(_ p: Presentation, _ kind: PhType) -> String {
    p.handoutMaster?.shapes.first { $0.phType == kind }?.text?.text ?? ""
}

@Suite struct IntegrationCorpusKindsTests {
    // Rust: it/corpus_kinds.rs::authored_kinds_round_trip_parts_and_text
    @Test func authoredKindsRoundTripPartsAndText() throws {
        let tablesBytes = try PPTX.export(tables())
        var (origin, saved) = try roundTrip("tables", tablesBytes)
        require(xmlText(origin.parts), "tables", ["Quarter", "North", "12", "Total", "Regions"])
        #expect(contentCounts(origin.parts) == [1, 0, 0, 0, 0])

        let chartsBytes = try PPTX.export(charts())
        (origin, saved) = try roundTrip("charts", chartsBytes)
        require(xmlText(origin.parts), "charts", ["Revenue", "Trend", "Share", "Actual", "Jan", "Feb", "Month", "Amount due"])
        #expect(contentCounts(origin.parts) == [1, 3, 0, 0, 0])

        let animBytes = try PPTX.export(animations())
        (origin, saved) = try roundTrip("animations", animBytes)
        require(xmlText(origin.parts), "animations", ["Motion", "Fly in", "One", "Two", "Three"])
        let anim = try PPTX.import(saved.bytes())
        let animSlide = try #require(anim.slides.first)
        try #require(animSlide.animations.count == 2)
        #expect(animSlide.animations[0].effect == "fly")
        #expect(animSlide.animations[1].textBuild == .byParagraph)
        #expect(animSlide.transition.map(\.kind) == "wipe")

        let mediaBytes = try PPTX.export(media())
        (origin, saved) = try roundTrip("media", mediaBytes)
        require(xmlText(origin.parts), "media", ["Media"])
        let mark = IT.png(4, 4, (20, 90, 160))
        #expect(saved.parts.values.contains(mark), "the picture bytes did not survive the save")
        #expect(saved.parts.values.contains(Array("owned-wav-tone".utf8)), "the audio bytes did not survive the save")
        #expect(saved.parts.values.contains(Array("owned-mp4-clip".utf8)), "the video bytes did not survive the save")
        #expect(contentCounts(origin.parts)[2] >= 3, "picture, audio and video")
        let mediaDeck = try PPTX.import(saved.bytes())
        let mediaSlide = try #require(mediaDeck.slides.first)
        let tone = try #require(mediaSlide.shapes.first { $0.name == "Tone" }, "tone")
        guard case let .media(clip) = tone.kind else {
            Issue.record("not media")
            return
        }
        #expect(clip.bookmarks == [Pair("Cue the demo", 400)])
        #expect(!clip.video)

        let sectionBytes = try PPTX.export(sections())
        (origin, saved) = try roundTrip("sections", sectionBytes)
        require(
            xmlText(origin.parts),
            "sections",
            ["Opening remarks", "Brief", "Figures", "Opening", "Short show", "https://example.org/brief?q=1&x=2", "Open the brief"]
        )
        let sectionsDeck = try PPTX.import(saved.bytes())
        #expect(sectionsDeck.sections.map(\.name) == ["Opening", "Figures"])
        #expect(sectionsDeck.customShows.first?.name == "Short show")

        let masterBytes = try PPTX.export(masters())
        (origin, saved) = try roundTrip("masters", masterBytes)
        require(
            xmlText(origin.parts),
            "masters",
            [
                "Welcome",
                "Agenda",
                "Comparison",
                "Pull quote",
                "Evening",
                "Evening master",
                "Quote",
                "Slide footer line",
                "Title Slide",
                "Section Header",
            ]
        )
        let mastersDeck = try PPTX.import(saved.bytes())
        #expect(mastersDeck.masters.count == 2)
        #expect(mastersDeck.masters.contains { $0.name == "Evening" })
        #expect(mastersDeck.masters.flatMap(\.layouts).contains { $0.name == "Quote" && $0.kind == .custom })

        let handout = try handoutDeck()
        (origin, _) = try roundTrip("handout master", handout)
        require(xmlText(origin.parts), "handout", ["Leave-behind", "Board pack", "Not for circulation", "1 March 2026", "Handouts"])
        #expect(contentCounts(origin.parts)[4] == 1, "handout master part")
        let opened = try PPTX.import(handout)
        #expect(opened.handoutMaster.map(\.name) == "Handouts")
        #expect(placeholderText(opened, .header) == "Board pack")
        #expect(placeholderText(opened, .footer) == "Not for circulation")
        #expect(placeholderText(opened, .date) == "1 March 2026")
        #expect(placeholderText(opened, .slideNum) == "3")
        let savedHandout = try PPTX.export(opened)
        let reopened = try PPTX.import(savedHandout)
        #expect(placeholderText(reopened, .header) == "Board pack")
        #expect(placeholderText(reopened, .footer) == "Not for circulation")
        #expect(placeholderText(reopened, .date) == "1 March 2026")
        #expect(placeholderText(reopened, .slideNum) == "3")
        #expect(reopened.slides.first?.shapes.first?.text?.text ?? "" == "Leave-behind")
    }
}
