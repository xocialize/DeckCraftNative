// Port of deckcraft crates/pptx/tests/it/corpus.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Owned corpus: decks this repository authors, then open → save → reopen.
//
// Each package is built here (nothing from another product). The check compares the text in the package
// and the content parts. A second save must come out the same as the first.
import DCCore
import DCModel
import Testing
@testable import DCPPTX

/// A short talk: title, notes, a link, a comment, a picture, a table and a chart.
private func talk() throws -> Presentation {
    var p = newPresentation(nil)
    p.props.title = "Quarterly review"
    p.props.subject = "Owned corpus"
    p.props.author = "DeckCraft tests"
    let added = p.addMedia("mark.png", "image/png", IT.png(4, 4, (20, 90, 160)))
    let img = try #require(added, "media")

    do {
        _ = try #require(p.slides.first, "slide")
        p.slides[0].notes = TextBody.fromText("Say the number slowly")
        if !p.slides[0].shapes.isEmpty {
            var props = RunProps()
            props.link = Hyperlink(
                action: .url(url: "https://example.org/north?q=1&x=2"), tooltip: "Open the report", highlightClick: false,
                sound: nil, stopSound: false, zoomReturn: nil
            )
            p.slides[0].shapes[0].text = TextBody(paragraphs: [
                Paragraph(runs: [Run("Quarterly review"), Run.with("North report", props)]),
            ])
        }
        p.slides[0].comments = [Comment(
            author: "Ada", initials: "AL", text: "Ada checks the axis", date: "2026-03-04T05:06:07.000", x: 40.0, y: 40.0
        )]
    }

    var s = IT.newSlide(&p, "Figures")
    var pic = IT.shape(&p, "Mark", 60.0, 80.0, 80.0, 80.0)
    pic.kind = .picture(fill: PictureFill(media: img))
    pic.geom = Geom.preset("rect")
    var table = Table(rows: 2, cols: 2, width: 200.0, rowHeight: 24.0)
    for (r, c, text) in [(0, 0, "Region"), (0, 1, "Amount"), (1, 0, "North"), (1, 1, "12")] {
        table.mutateCell(r, c) { $0.text = TextBody.fromText(text) }
    }
    var ts = IT.shape(&p, "Regions", 160.0, 80.0, 200.0, 48.0)
    ts.kind = .table(table)
    var chart = Chart.sample(.column)
    chart.title = "Revenue"
    chart.categories = ["Jan", "Feb"]
    chart.series = Array(chart.series.prefix(1))
    if !chart.series.isEmpty {
        chart.series[0].name = "Actual"
        chart.series[0].values = [10.0, 20.0]
    }
    chart.axisTitles = Pair("Month", "Amount due")
    var ch = IT.shape(&p, "Revenue chart", 400.0, 80.0, 280.0, 180.0)
    ch.kind = .chart(chart)
    s.shapes += [pic, ts, ch]
    p.slides.append(s)
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

    func replace(_ name: String, _ data: [UInt8]) throws -> [UInt8] {
        var wrote = false
        let files = names.map { n -> (name: String, data: [UInt8]) in
            if bytesEqual(n, name) {
                wrote = true
                return (n, data)
            }
            return (n, parts[n] ?? [])
        }
        #expect(wrote, "missing part \(name)")
        return try IT.zip(files)
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

/// Text in the package: element texts, web link targets and tooltips, with how often each appears.
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
        for url in attrValues(bytes, "Target") where hasBytePrefix(String(decoding: url, as: UTF8.self), "http://")
            || hasBytePrefix(String(decoding: url, as: UTF8.self), "https://") {
            counts[url, default: 0] += 1
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

private func contentCounts(_ parts: [String: [UInt8]]) -> [Int] {
    let isPart = { (prefix: String, name: String) -> Bool in
        let n = rustASCIILowercase(name)
        return hasBytePrefix(n, prefix) && hasByteSuffix(n, ".xml") && !n.has("_rels")
    }
    return [
        partCount(parts) { isPart("ppt/slides/slide", $0) },
        partCount(parts) { isPart("ppt/notesslides/notesslide", $0) },
        partCount(parts) { isPart("ppt/notesmasters/notesmaster", $0) },
        partCount(parts) { isPart("ppt/charts/chart", $0) },
        partCount(parts) { hasBytePrefix(rustASCIILowercase($0), "ppt/media/") && !rustASCIILowercase($0).has("_rels") },
        partCount(parts) { isPart("ppt/comments/comment", $0) },
    ]
}

private func lost(_ origin: [[UInt8]: Int], _ saved: [[UInt8]: Int]) -> [(String, Int, Int)] {
    origin.keys.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { s in
        let n = origin[s] ?? 0, got = saved[s] ?? 0
        return got < n ? (String(decoding: s, as: UTF8.self), n, got) : nil
    }
}

/// Open, save, reopen. Text from the original is still there, content parts are still there, and saving
/// again does not change the package's part names or text.
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

private func setPlaceholderText(_ xml: String, _ ph: String, _ text: String) throws -> String {
    let needle = "type=\"\(ph)\""
    let at = try #require(xml.byteFind(needle), "notes master has no \(ph) placeholder")
    let after = xml.bytes(at)
    let startRel = try #require(after.byteFind("<p:txBody>"), "no txBody after \(ph)")
    let endRel = try #require(after.byteFind("</p:txBody>"), "no txBody end after \(ph)")
    try #require(startRel < endRel, "\(ph) txBody is out of order")
    let start = at + startRel
    let end = at + endRel + "</p:txBody>".utf8.count
    let body = "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody>"
    return xml.bytes(0, start) + body + xml.bytes(end)
}

/// A received deck whose notes master carries the header and footer (where PowerPoint stores them).
private func notesHeaderDeck() throws -> [UInt8] {
    var p = newPresentation(nil)
    _ = try #require(p.slides.first, "slide")
    if !p.slides[0].shapes.isEmpty {
        p.slides[0].shapes[0].text = TextBody.fromText("Quarterly review")
    }
    p.slides[0].notes = TextBody.fromText("Pause after the title")
    let bytes = try PPTX.export(p)
    let pkg = try Pkg.open(bytes)
    let master = try #require(pkg.parts["ppt/notesMasters/notesMaster1.xml"], "notes master")
    let xml0 = try #require(String(validating: master, as: UTF8.self), "utf8")
    let xml1 = try setPlaceholderText(xml0, "hdr", "Acme review")
    let xml = try setPlaceholderText(xml1, "ftr", "Do not circulate")
    return try pkg.replace("ppt/notesMasters/notesMaster1.xml", Array(xml.utf8))
}

private func placeholderText(_ p: Presentation, _ kind: PhType) -> String {
    p.notesMaster?.shapes.first { $0.phType == kind }?.text?.text ?? ""
}

@Suite struct IntegrationCorpusTests {
    // Rust: it/corpus.rs::owned_corpus_round_trip_keeps_parts_and_text
    @Test func ownedCorpusRoundTripKeepsPartsAndText() throws {
        let talkBytes = try PPTX.export(talk())
        let (origin, saved) = try roundTrip("talk", talkBytes)
        let text = xmlText(origin.parts)
        for s in [
            "Quarterly review",
            "North report",
            "Say the number slowly",
            "Region",
            "North",
            "Revenue",
            "Jan",
            "Feb",
            "Actual",
            "Month",
            "Amount due",
            "Ada checks the axis",
            "Owned corpus",
            "DeckCraft tests",
            "https://example.org/north?q=1&x=2",
            "Open the report",
        ] {
            #expect(text[Array(s.utf8)] != nil, "talk corpus is missing \(s)")
        }
        let mark = IT.png(4, 4, (20, 90, 160))
        #expect(saved.parts.values.contains(mark), "the picture bytes did not survive the save")
        #expect(contentCounts(origin.parts) == [2, 1, 1, 1, 1, 1], "talk corpus shape")

        let notes = try notesHeaderDeck()
        _ = try roundTrip("notes header", notes)
        let opened = try PPTX.import(notes)
        #expect(placeholderText(opened, .header) == "Acme review")
        #expect(placeholderText(opened, .footer) == "Do not circulate")
        let saved2 = try PPTX.export(opened)
        let reopened = try PPTX.import(saved2)
        #expect(placeholderText(reopened, .header) == "Acme review")
        #expect(placeholderText(reopened, .footer) == "Do not circulate")
        let first = try #require(reopened.slides.first)
        #expect(first.notesText == "Pause after the title")
    }
}
