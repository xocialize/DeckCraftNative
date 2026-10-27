// Ported from deckcraft crates/format/src/{lib.rs, chart_parts_tests.rs, rtf.rs} tests (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCFormat
import DCGeometry
import DCModel
import DCZip
import Testing

// MARK: - Archive surgery helpers

/// Every member of an archive, decompressed, in order.
private func members(_ bytes: [UInt8]) throws -> [(name: String, data: [UInt8], method: UInt16, offset: Int)] {
    let z = try ZipReader(bytes)
    return try z.entries.map { ($0.name, try z.read($0, max: .max), $0.method, $0.dataOffset) }
}

/// The archive rebuilt from `entries` (DEFLATE where the original used it).
private func rebuild(_ entries: [(name: String, data: [UInt8], method: UInt16, offset: Int)]) throws -> [UInt8] {
    var w = ZipWriter()
    for e in entries { try w.add(e.name, e.data, compress: e.method == 8) }
    return try w.finish()
}

/// The same package without the entries `drop` names.
private func without(_ bytes: [UInt8], _ drop: String) throws -> [UInt8] {
    try rebuild(members(bytes).filter { $0.name != drop })
}

/// The same package with its `presentation.json` edited.
private func rewriteManifest(_ bytes: [UInt8], _ edit: (inout JSON) throws -> Void) throws -> [UInt8] {
    var out = try members(bytes)
    let i = try #require(out.firstIndex { $0.name == "presentation.json" })
    var json = try JSONParser.parse(out[i].data)
    try edit(&json)
    out[i].data = JSONWriter().bytes(json)
    return try rebuild(out)
}

/// `json` with the value at `path` (object keys; array indices as strings) changed by `f`.
private func edit(_ json: inout JSON, _ path: [String], _ f: (inout JSON) throws -> Void) rethrows {
    guard let first = path.first else { return try f(&json) }
    switch json {
    case .object(var o):
        var v = o[first] ?? .null
        try edit(&v, Array(path.dropFirst()), f)
        o.set(first, v)
        json = .object(o)
    case .array(var a):
        if let i = Int(first), a.indices.contains(i) {
            try edit(&a[i], Array(path.dropFirst()), f)
            json = .array(a)
        }
    default:
        break
    }
}

private func offset(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
    guard bytes.count >= needle.count else { return nil }
    return (0 ... bytes.count - needle.count).first { bytes[$0 ..< $0 + needle.count].elementsEqual(needle) }
}

private func withShape(_ p: inout Presentation, _ s: Shape) {
    p.slides[0].shapes.append(s)
}

// MARK: - lib.rs tests

@Suite struct FormatTests {
    @Test func chartSidecarsAreOptionalForOlderNativeFiles() throws {
        let chart = Chart.sample(.pie)
        var json = chart.toJSON()
        #expect(json["kept"] == nil, "empty sidecars should not enlarge ordinary files")
        #expect(try Chart(fromJSON: json) == chart)
        if case .object(var o) = json {
            o.set("kept", .object(JSONObject()))
            json = .object(o)
        }
        #expect(try Chart(fromJSON: json) == chart)
    }

    @Test func nativeSaveKeepsChartRelationshipsAndPayloads() throws {
        let kept = ChartKept(
            rels: [ChartRel(
                id: "rWorkbook", relType: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package",
                target: "../embeddings/data.xlsx", part: "ppt/embeddings/data.xlsx", external: false
            )],
            parts: [ChartPart(
                name: "ppt/embeddings/data.xlsx", contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                bytes: [0, 255, 128, 42], nativeEntry: nil
            )]
        )
        var p = newPresentation(nil)
        var chart = Chart.sample(.pie)
        chart.kept = kept
        var s = Shape.default
        let rawId1 = p.allocId()
        s.id = ShapeId(try #require(rawId1))
        s.kind = .chart(chart)
        // Serialization must reach charts inside groups as well as top-level charts.
        var g = Shape.default
        let rawId2 = p.allocId()
        g.id = ShapeId(try #require(rawId2))
        g.kind = .group(children: [s], child: Xfrm())
        p.slides[0].shapes = [g]
        var q = try DeckFormat.load(try DeckFormat.save(p))
        for _ in 0 ..< 2 {
            guard case .group(let children, _) = q.slides[0].shapes[0].kind, case .chart(let c) = children[0].kind else {
                Issue.record("expected a chart in a group")
                return
            }
            #expect(c.kept == kept)
            q = try DeckFormat.load(try DeckFormat.save(q))
        }
    }

    @Test func missingOrCorruptMediaIsReported() throws {
        var p = Presentation.default
        let added = p.addMedia("a.png", "image/png", Array("PICTURE-BYTES-0123456789".utf8))
        let id = try #require(added)
        let good = try DeckFormat.save(p)
        #expect(try DeckFormat.loadChecked(good).damaged.isEmpty)
        // Missing member.
        let (q, damaged) = try DeckFormat.loadChecked(try without(good, "media/\(id.rawValue)"))
        #expect(damaged.count == 1, "\(damaged)")
        #expect(q.media(id)?.data.isEmpty == true)
        // Bad CRC: PNGs are stored, so their bytes sit in the file as they are.
        var bad = good
        let at = try #require(offset(of: Array("PICTURE-BYTES".utf8), in: bad))
        bad[at] ^= 0xFF
        #expect(try DeckFormat.loadChecked(bad).damaged.count == 1)
        // Linked media saved without its bytes isn't damage.
        var l = Presentation.default
        let linked = l.addMedia("v.mp4", "video/mp4", [])
        let lid = try #require(linked)
        if let i = l.media.firstIndex(where: { $0.id == lid }) { l.media[i].link = "file:///movies/v.mp4" }
        #expect(try DeckFormat.loadChecked(try DeckFormat.save(l)).damaged.isEmpty)
    }

    @Test func mediaBudgetIsCumulative() throws {
        var p = Presentation.default
        _ = p.addMedia("a.bin", "application/octet-stream", Array(repeating: 1, count: 600))
        _ = p.addMedia("b.bin", "application/octet-stream", Array(repeating: 2, count: 600))
        let bytes = try DeckFormat.save(p)
        // Exactly at the limit opens; one byte under is refused, though each item fits.
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1200, items: 2))) != nil)
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1199, items: 2))) == nil)
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1200, items: 1))) == nil)
    }

    @Test func repeatedMediaIdsAreReadOnce() throws {
        var p = Presentation.default
        _ = p.addMedia("a.bin", "application/octet-stream", Array(repeating: 7, count: 1000))
        let good = try DeckFormat.save(p)
        // The same file with its media item listed 51 times.
        let bytes = try rewriteManifest(good) { json in
            edit(&json, ["presentation", "media"]) { media in
                if case .array(let a) = media, let one = a.first { media = .array(Array(repeating: one, count: 51)) }
            }
        }
        // 51 references to one 1000-byte member fit a 1000-byte budget: it's inflated once.
        let q = try DeckFormat.load(bytes, within: Budget(total: 1000, items: 51)).presentation
        #expect(q.media.count == 1)
        #expect(q.media[0].data.count == 1000)
        // And the deck saves again.
        #expect((try? DeckFormat.save(q)) != nil)
    }

    @Test func roundtripWithMedia() throws {
        var p = Presentation.default
        let added = p.addMedia("a.png", "image/png", [1, 2, 3, 4])
        let id = try #require(added)
        let bytes = try DeckFormat.save(p)
        #expect(DeckFormat.sniff(bytes))
        let q = try DeckFormat.load(bytes)
        #expect(q.slides.count == p.slides.count)
        #expect(q.media(id)?.data == [1, 2, 3, 4])
        #expect(q.slides.toJSON() == p.slides.toJSON())
    }

    @Test func garbageIsAnErrorNotATrap() throws {
        #expect(throws: FormatError.self) { try DeckFormat.load([]) }
        #expect(throws: FormatError.self) { try DeckFormat.load(Array("PK\u{03}\u{04}garbage".utf8)) }
        #expect(throws: FormatError.self) { try DeckFormat.load(Array(repeating: 0, count: 1000)) }
        let b = try DeckFormat.save(.default)
        #expect(throws: FormatError.self) { try DeckFormat.load(Array(b.prefix(b.count / 2))) }
    }

    /// A video's crop is brought into the same range as a picture's (#972).
    @Test func aVideoCropIsRepairedLikeAPictureCrop() throws {
        var p = Presentation.default
        var s = Shape.default
        s.kind = .media(MediaClip(video: true, crop: [.nan, 0.25, -1e9, 0.0]))
        withShape(&p, s)
        let back = try DeckFormat.load(try DeckFormat.save(p))
        guard case .media(let m)? = back.slides[0].shapes.last?.kind else {
            Issue.record("media")
            return
        }
        #expect(m.crop == [0.0, 0.25, -10.0, 0.0])
    }

    /// Non-finite numbers are written as 0 since `Finite`, and as `null` before it; either way the file
    /// opens, with each such number repaired.
    @Test func aFileSavedWithNonFiniteNumbersReopens() throws {
        var p = Presentation.default
        let nan = Double.nan
        let inf = Double.infinity
        var pic = Shape.default
        pic.xfrm = Xfrm(x: nan, y: -inf, w: 1e300, h: -4.0, rot: 725.0)
        pic.kind = .picture(fill: PictureFill(crop: [nan, inf, 0.25, -1e9]))
        pic.line = Line(width: 1e9)
        var text = Shape.default
        text.xfrm = Xfrm(w: 100.0, h: 50.0, rot: inf)
        var para = Paragraph()
        para.runs.append(Run.with("x", RunProps(size: -3.0)))
        para.endProps.size = 1e9
        text.text = TextBody(paragraphs: [para])
        var group = Shape.default
        group.xfrm = Xfrm(w: 10.0, h: 10.0)
        group.kind = .group(children: [pic, text], child: Xfrm(x: nan, w: inf, h: 10.0))
        withShape(&p, group)
        let back = try DeckFormat.load(try DeckFormat.save(p))
        guard case .group(let children, let child)? = back.slides[0].shapes.last?.kind else {
            Issue.record("group")
            return
        }
        #expect(child.x == 0.0 && child.w == 0.0)
        let x = try #require(children[0].xfrm)
        #expect(x.x == 0.0 && x.y == 0.0 && x.w == DeckFormat.maxCoord && x.h == 0.0 && x.rot == 5.0)
        guard case .picture(let fill) = children[0].kind else {
            Issue.record("picture")
            return
        }
        #expect(fill.crop == [0.0, 0.0, 0.25, -10.0])
        #expect(children[0].line?.width == 1584.0)
        #expect(children[1].xfrm?.rot == 0.0)
        let rpara = try #require(children[1].text?.paragraphs.first)
        #expect(rpara.runs[0].props.size == nil)
        #expect(rpara.endProps.size == 4000.0)
        // Saved again, it is clean.
        #expect(try DeckFormat.load(try DeckFormat.save(back)) == back)
    }

    /// Files written before `Finite` (plain serde_json: NaN as `null`) open too, including a `null`
    /// inside a tagged enum.
    @Test(arguments: 0 ..< 3)
    func olderFilesWithNullNumbersOpen(_ testCase: Int) throws {
        var p = Presentation.default
        var sh = Shape.default
        switch testCase {
        case 0: sh.xfrm = Xfrm(x: .nan, w: 5.0, h: 5.0, rot: .nan)
        case 1: sh.kind = .group(children: [], child: Xfrm(x: .nan, w: 1.0, h: 1.0))
        default: sh.kind = .picture(fill: PictureFill(crop: [0.1, .nan, 0.0, 0.0]))
        }
        withShape(&p, sh)
        let m = Manifest(format: "deckcraft", version: DeckFormat.version, generator: "old", presentation: p)
        let json = JSONWriter().bytes(m.toJSON())
        #expect(offset(of: Array("null".utf8), in: json) != nil)
        let back = try DeckFormat.parseManifest(json)
        #expect(back.presentation.slides[0].shapes.count == m.presentation.slides[0].shapes.count)
    }

    /// A body whose file had no `fontScale` (`<a:normAutofit/>`) keeps that state through the native
    /// format: it is drawn at 100 % and only fitted when its text changes (#724).
    @Test func aBareNormAutofitBodyRoundTrips() throws {
        var p = Presentation.default
        for fit in [AutoFit.shrink(fontScale: nil, lineReduction: 0.0), .shrink(fontScale: 0.62, lineReduction: 0.2)] {
            var body = TextBody.fromText("Overflowing")
            body.body.autofit = fit
            var sh = Shape.default
            sh.text = body
            withShape(&p, sh)
            let back = try DeckFormat.load(try DeckFormat.save(p))
            #expect(back.slides[0].shapes.last?.text?.body.autofit == fit)
        }
    }

    /// Only `null`s where numbers belong are patched: other damage still fails.
    @Test func otherDamageIsStillReported() throws {
        let ok = Array(#"{"format":"deckcraft","version":1,"generator":"t","presentation":{}}"#.utf8)
        #expect((try? DeckFormat.parseManifest(ok)) != nil)
        let bad = Array(#"{"format": null, "version": 1, "generator": "t", "presentation": {}}"#.utf8)
        #expect(throws: FormatError.self) { try DeckFormat.parseManifest(bad) }
        #expect(throws: FormatError.self) { try DeckFormat.parseManifest(Array(ok.dropLast(3))) }
        // A null number on a later line (pretty-printed by another tool) is found too.
        let pretty = Array("{\n  \"format\": \"deckcraft\",\n  \"version\": 1,\n  \"generator\": \"t\",\n  \"presentation\": {\"slides\": [{\"shapes\": [{\"xfrm\": {\"x\": null, \"y\": 1, \"w\": 2, \"h\": 3}}]}]}\n}".utf8)
        let m = try DeckFormat.parseManifest(pretty)
        #expect(m.presentation.slides[0].shapes[0].xfrm?.x == 0.0)
    }

    @Test func degenerateSlideSizesAreRepaired() {
        let cases: [((Double, Double), (Double, Double))] = [
            ((0, 0), (960, 540)), ((-5, 540), (960, 540)), ((.nan, 540), (960, 540)), ((.infinity, 1), (960, 540)),
            ((1, 1), (72, 72)), ((0.5, 4000), (72, 4000)), ((1e9, 20), (4032, 72)), ((720, 540), (720, 540)),
        ]
        for ((w, h), want) in cases {
            var p = Presentation.default
            p.slideSize = Size(w, h)
            p.notesSize = Size(0, .nan)
            DeckFormat.repair(&p)
            #expect(p.slideSize.width == want.0 && p.slideSize.height == want.1, "\(w)x\(h)")
            #expect(p.notesSize == Presentation.default.notesSize)
        }
    }

    /// A file whose slide size is null, a string or missing a side opens with the default size rather
    /// than failing as damaged.
    @Test func filesWithUnreadableSlideSizesStillOpen() throws {
        let saved = try DeckFormat.save(.default)
        let sizes: [JSON] = [
            .object(JSONObject(["width": .null, "height": .uint(540)])),
            .object(JSONObject(["width": .string("big"), "height": .uint(540)])),
            .object(JSONObject(["height": .uint(0)])),
            .null,
            .uint(7),
        ]
        for size in sizes {
            let bytes = try rewriteManifest(saved) { json in
                edit(&json, ["presentation", "slideSize"]) { $0 = size }
            }
            let p = try DeckFormat.load(bytes)
            #expect(p.slideSize.width == 960.0 && p.slideSize.height == 540.0, "\(size)")
        }
    }

    @Test func repairFixesMissingLayoutAndSize() {
        var p = Presentation.default
        p.slides[0].layout = LayoutId(99999)
        p.slideSize.width = .nan
        DeckFormat.repair(&p)
        #expect(p.validate().isEmpty)
        #expect(p.slideSize.width == 960.0)
    }

    /// A duplicate slide in a deck whose ids are used up cannot be re-id'd: it stays as it is instead of
    /// a duplicated fresh id (#407).
    @Test func repairKeepsADuplicateItCannotReid() {
        var p = Presentation.default
        p.nextId = .max
        p.slides.append(p.slides[0])
        DeckFormat.repair(&p)
        #expect(p.slides.count == 2, "the duplicate stays visible")
        #expect(p.slides[0].id == p.slides[1].id, "no fresh id was invented")
    }

    @Test func outlineRoundtrip() {
        var p = blankPresentation(wideSlideSize, .default, false)
        #expect(DeckFormat.outlineToSlides(&p, "Intro\n\tPoint one\n\t\tSub point\nSecond\n\tMore") == 2)
        let o = DeckFormat.slidesToOutline(p)
        #expect(o.contains("Intro\n\tPoint one\n\t\tSub point\nSecond"), "\(o)")
    }

    @Test func outlineKeepsLeadingDashText() {
        var p = blankPresentation(wideSlideSize, .default, false)
        #expect(DeckFormat.outlineToSlides(&p, "-5 °C tonight\n\t--verbose flag\n\t*args and **kwargs\n- Bullets\n\t- Point\n\t• Other") == 2)
        let o = DeckFormat.slidesToOutline(p)
        #expect(o.contains("-5 °C tonight\n\t--verbose flag\n\t*args and **kwargs\nBullets\n\tPoint\n\tOther"), "\(o)")
    }

    @Test func outlineExportKeepsMultiParagraphTitleOnOneLine() throws {
        var p = blankPresentation(wideSlideSize, .default, false)
        #expect(DeckFormat.outlineToSlides(&p, "Intro\n\tPoint one\nSecond\n\tMore") == 2)
        let ti = try #require(p.slides[0].shapes.firstIndex { $0.phType?.isTitle ?? false })
        p.slides[0].shapes[ti].text = TextBody.fromText("Line one\nLine two")
        let o = DeckFormat.slidesToOutline(p)
        #expect(o == "Line one Line two\n\tPoint one\nSecond\n\tMore\n")
        var q = blankPresentation(wideSlideSize, .default, false)
        #expect(DeckFormat.outlineToSlides(&q, o) == 2)
    }

    @Test func markdownHeadingsAndListItems() {
        #expect(DeckFormat.mdHeading("# Intro") == "Intro")
        #expect(DeckFormat.mdHeading("   ### Deep ###  ") == "Deep")
        #expect(DeckFormat.mdHeading("## C# and F#") == "C# and F#")
        #expect(DeckFormat.mdHeading("#") == "")
        #expect(DeckFormat.mdHeading("## Ünïcödé") == "Ünïcödé")
        for not in ["#5 priority", "####### seven", "    # code", "text", "", "é#"] {
            #expect(DeckFormat.mdHeading(not) == nil, "\(not)")
        }
        #expect(DeckFormat.mdListItem("- a").map { [String($0.level), $0.text] } == ["0", "a"])
        #expect(DeckFormat.mdListItem("    * b").map { [String($0.level), $0.text] } == ["2", "b"])
        #expect(DeckFormat.mdListItem("\t+ c").map { [String($0.level), $0.text] } == ["1", "c"])
        #expect(DeckFormat.mdListItem("12) d").map { [String($0.level), $0.text] } == ["0", "d"])
        for not in ["-x", "1.x", "1", "1234567890. long", "• bullet", "é. x", ""] {
            #expect(DeckFormat.mdListItem(not) == nil, "\(not)")
        }
    }

    private func tableShape(_ texts: [[String]], _ y: Double) -> Shape {
        var table = Table.default
        table.cols = [200.0, 200.0]
        for row in texts {
            table.rows.append(Row(height: 30.0, cells: row.map { Cell(text: TextBody.fromText($0)) }))
        }
        var s = Shape.default
        s.xfrm = Xfrm(0, y, 400, 60)
        s.kind = .table(table)
        return s
    }

    /// #814: the outline includes table cell text, which it used to skip.
    @Test func outlineIncludesTableText() throws {
        var p = newPresentation(nil)
        let layout = try #require(layoutOfKind(p, .titleAndContent))
        let made = newSlide(&p, layout)
        var s = try #require(made)
        s.shapes.removeAll { $0.phType?.isTitle ?? false }
        var body = Shape.default
        body.xfrm = Xfrm(0, 0, 600, 100)
        body.text = TextBody.fromText("Text box body")
        s.shapes.append(body)
        s.shapes.append(tableShape([["Cell A1", "Cell B1"], ["Cell A2", "Cell B2"]], 100))
        p.slides = [s]
        let out = DeckFormat.slidesToOutline(p)
        #expect(out.contains("Text box body"), "\(out)")
        #expect(out.contains("Cell A1\tCell B1"), "\(out)")
        #expect(out.contains("Cell A2\tCell B2"), "\(out)")
    }

    @Test func outlineTableRowsAreIndentedAndDoNotBecomeSlides() throws {
        var p = newPresentation(nil)
        let layout = try #require(layoutOfKind(p, .titleAndContent))
        let made = newSlide(&p, layout)
        var s = try #require(made)
        for i in s.shapes.indices where s.shapes[i].phType?.isTitle ?? false {
            s.shapes[i].text = TextBody.fromText("Slide title")
        }
        s.shapes.append(tableShape([["A1", "B1"], ["A2", "B2"]], 100))
        p.slides = [s]
        let out = DeckFormat.slidesToOutline(p)
        var q = newPresentation(nil)
        q.slides.removeAll()
        #expect(DeckFormat.outlineToSlides(&q, out) == 1, "table rows became slides: \(out)")
        #expect(q.slides.count == 1, "\(out)")
        let body = q.slides[0].shapes.compactMap { $0.text?.text }.joined(separator: "\n")
        #expect(body.contains("A1\tB1"), "\(body)")
        #expect(body.contains("A2\tB2"), "\(body)")
    }
}

// MARK: - chart_parts_tests.rs

private let partName = "ppt/embeddings/owned.xlsx"

private func fixture(_ payload: [UInt8]) throws -> Presentation {
    // Construct through the old manifest representation: this also exercises compatibility.
    var part = try ChartPart(fromJSON: try JSONParser.parse(#"{"name":"\#(partName)","contentType":"application/zip","bytes":[]}"#))
    part.bytes = payload
    var chart = Chart.sample(.pie)
    chart.kept.rels.append(ChartRel(
        id: "rWorkbook", relType: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package",
        target: "../embeddings/owned.xlsx", part: partName, external: false
    ))
    chart.kept.parts.append(part)
    var p = Presentation.default
    var child = Shape.default
    let rawId3 = p.allocId()
    child.id = ShapeId(try #require(rawId3))
    child.kind = .chart(chart)
    var group = Shape.default
    let rawId4 = p.allocId()
    group.id = ShapeId(try #require(rawId4))
    group.kind = .group(children: [child], child: Xfrm())
    p.slides[0].shapes = [group]
    return p
}

/// The path to the first object that looks like our chart part.
private func partPath(_ v: JSON, _ path: [String] = []) -> [String]? {
    switch v {
    case .object(let o):
        if o["name"] == .string(partName), o["contentType"] != nil { return path }
        for e in o.entries {
            if let p = partPath(e.value, path + [e.key]) { return p }
        }
    case .array(let a):
        for (i, x) in a.enumerated() {
            if let p = partPath(x, path + [String(i)]) { return p }
        }
    default:
        break
    }
    return nil
}

private func value(_ v: JSON, _ path: [String]) -> JSON? {
    var cur = v
    for k in path {
        switch cur {
        case .object(let o): guard let n = o[k] else { return nil }; cur = n
        case .array(let a): guard let i = Int(k), let n = a.at(i) else { return nil }; cur = n
        default: return nil
        }
    }
    return cur
}

private func manifestJSON(_ bytes: [UInt8]) throws -> JSON {
    try JSONParser.parse(try ZipReader(bytes).read(named: "presentation.json", max: .max))
}

@Suite struct ChartPartsTests {
    @Test func largeChartPayloadIsAReferencedZipEntry() throws {
        let payload = [UInt8](repeating: 200, count: 3 * 1024 * 1024)
        let p = try fixture(payload)
        let bytes = try DeckFormat.save(p)
        let z = try ZipReader(bytes)
        #expect(try #require(z.find("presentation.json")).uncompressedSize < 128 * 1024, "binary chart bytes must not become JSON numbers")
        let manifest = try manifestJSON(bytes)
        let path = try #require(partPath(manifest))
        #expect(value(manifest, path + ["bytes"]) == nil, "new manifests keep only metadata and a reference")
        guard case .string(let entry)? = value(manifest, path + ["nativeEntry"]) else {
            Issue.record("no nativeEntry")
            return
        }
        #expect(entry.hasPrefix("chart-parts/"))
        #expect(try DeckFormat.readEntry(z, entry, max: .max) == payload)
        #expect(throws: FormatError.self) { try DeckFormat.readEntry(z, entry, max: payload.count - 1) }
        #expect(try DeckFormat.load(bytes) == p)
    }

    @Test func chartPartsShareMediaByteAndItemBudgets() throws {
        var p = try fixture(Array(repeating: 7, count: 600))
        _ = p.addMedia("a.bin", "application/octet-stream", Array(repeating: 8, count: 600))
        let bytes = try DeckFormat.save(p)
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1200, items: 2))) != nil)
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1199, items: 2))) == nil, "chart payloads share the cumulative media budget")
        #expect((try? DeckFormat.load(bytes, within: Budget(total: 1200, items: 1))) == nil, "chart parts share the media item budget")
        let duplicated = try rewriteManifest(bytes) { json in
            edit(&json, ["presentation", "media"]) { media in
                if case .array(let a) = media, let one = a.first { media = .array(a + [one]) }
            }
        }
        #expect((try? DeckFormat.load(duplicated, within: Budget(total: 1200, items: 2))) == nil, "duplicate media IDs still count as listed items")
    }

    @Test func legacyInlineChartBytesAreBudgetedAndPreserved() throws {
        var p = try fixture(Array(repeating: 9, count: 600))
        _ = p.addMedia("a.bin", "application/octet-stream", Array(repeating: 8, count: 600))
        let legacy = try rewriteManifest(try DeckFormat.save(p)) { json in
            let path = try #require(partPath(json))
            edit(&json, path) { part in
                guard case .object(var o) = part else { return }
                o.remove("nativeEntry")
                o.set("bytes", [UInt8](repeating: 9, count: 600).toJSON())
                part = .object(o)
            }
        }
        #expect(try DeckFormat.load(legacy, within: Budget(total: 1200, items: 2)).presentation == p)
        #expect((try? DeckFormat.load(legacy, within: Budget(total: 1199, items: 2))) == nil)
        #expect((try? DeckFormat.load(legacy, within: Budget(total: 1200, items: 1))) == nil)
    }

    @Test func chartPayloadsInEveryShapeOwnerGetDistinctEntries() throws {
        var p = try fixture(Array(repeating: 42, count: 4096))
        let shapes = p.slides[0].shapes
        p.masters[0].shapes = shapes
        p.masters[0].layouts[0].shapes = shapes
        p.notesMaster = Master(shapes: shapes)
        p.handoutMaster = Master(shapes: shapes)
        let bytes = try DeckFormat.save(p)
        #expect(try ZipReader(bytes).entries.filter { $0.name.hasPrefix("chart-parts/") }.count == 5)
        #expect(try DeckFormat.load(bytes) == p)
    }

    @Test func missingOrCorruptChartPayloadIsReported() throws {
        let p = try fixture(Array("SYNTHETIC-CHART-PAYLOAD-0123456789".utf8))
        let bytes = try DeckFormat.save(p)
        let manifest = try manifestJSON(bytes)
        guard case .string(let name)? = value(manifest, try #require(partPath(manifest)) + ["nativeEntry"]) else {
            Issue.record("no nativeEntry")
            return
        }
        let (q, damaged) = try DeckFormat.loadChecked(try without(bytes, name))
        #expect(damaged.count == 1, "\(damaged)")
        guard case .group(let children, _) = q.slides[0].shapes[0].kind, case .chart(let chart) = children[0].kind else {
            Issue.record("chart in group")
            return
        }
        #expect(chart.kept.parts[0].bytes.isEmpty)
        var corrupt = bytes
        corrupt[try #require(ZipReader(bytes).find(name)).dataOffset] ^= 0xFF
        #expect(throws: FormatError.self) { try DeckFormat.loadChecked(corrupt) }
    }

    @Test func chartReferencesCannotAliasOtherMembersOrMixInlineBytes() throws {
        var p = try fixture(Array(repeating: 3, count: 10))
        let bytes = try DeckFormat.save(p)
        for entry in ["media/1", "chart-parts/../0", "chart-parts/00", "chart-parts/-1"] {
            let changed = try rewriteManifest(bytes) { json in
                let path = try #require(partPath(json))
                edit(&json, path + ["nativeEntry"]) { $0 = .string(entry) }
            }
            #expect(throws: FormatError.self, "accepted \(entry)") { try DeckFormat.load(changed) }
        }
        let ambiguous = try rewriteManifest(bytes) { json in
            let path = try #require(partPath(json))
            edit(&json, path + ["bytes"]) { $0 = .array([.uint(3)]) }
        }
        #expect(throws: FormatError.self) { try DeckFormat.load(ambiguous) }

        guard case .group(var children, let child) = p.slides[0].shapes[0].kind, case .chart(var chart) = children[0].kind else {
            Issue.record("chart in group")
            return
        }
        chart.kept.parts.append(chart.kept.parts[0])
        children[0].kind = .chart(chart)
        p.slides[0].shapes[0].kind = .group(children: children, child: child)
        let aliased = try rewriteManifest(try DeckFormat.save(p)) { json in
            func alias(_ v: inout JSON) {
                switch v {
                case .object(var o):
                    if o["nativeEntry"] != nil { o.set("nativeEntry", .string("chart-parts/0")) }
                    for e in o.entries {
                        var x = e.value
                        alias(&x)
                        o.set(e.key, x)
                    }
                    v = .object(o)
                case .array(var a):
                    for i in a.indices { alias(&a[i]) }
                    v = .array(a)
                default:
                    break
                }
            }
            alias(&json)
        }
        #expect(throws: FormatError.self, "one ZIP member must not be inflated repeatedly") { try DeckFormat.load(aliased) }
    }

    private func withTwoParts() throws -> Presentation {
        var p = try fixture(Array(repeating: 3, count: 10))
        guard case .group(var children, let child) = p.slides[0].shapes[0].kind, case .chart(var chart) = children[0].kind else {
            return p
        }
        var second = chart.kept.parts[0]
        second.bytes = Array(repeating: 4, count: 10)
        chart.kept.parts.append(second)
        children[0].kind = .chart(chart)
        p.slides[0].shapes[0].kind = .group(children: children, child: child)
        return p
    }

    @Test func corruptChartMembersStopBeforeReusingTheInflationBudget() throws {
        var bytes = try DeckFormat.save(try withTwoParts())
        let z = try ZipReader(bytes)
        for i in 0 ..< 2 {
            bytes[try #require(z.find("chart-parts/\(i)")).dataOffset] ^= 0xFF
        }
        // A failed CRC may already have inflated bytes. Continuing with the same remaining budget would let
        // each corrupt member consume that work budget again.
        do {
            _ = try DeckFormat.load(bytes, within: Budget(total: 10, items: 2))
            Issue.record("two corrupt 10-byte members must not reuse a 10-byte budget")
        } catch {
            #expect(error.description.contains("chart-parts/0"), "\(error)")
        }
    }

    @Test func duplicatePhysicalZipNamesAreIndexedAndInflatedOnce() throws {
        var bytes = try DeckFormat.save(try withTwoParts())
        // Forge equal-length local/central-directory names, to exercise duplicate-name indexing on an
        // untrusted archive.
        let original = Array("chart-parts/1".utf8)
        var replaced = 0
        for off in 0 ... (bytes.count - original.count) where bytes[off ..< off + original.count].elementsEqual(original) {
            bytes[off + original.count - 1] = UInt8(ascii: "0")
            replaced += 1
        }
        #expect(replaced == 2)
        let (q, damaged) = try DeckFormat.load(bytes, within: Budget(total: 10, items: 2))
        #expect(damaged.count == 1, "the second reference is missing, not inflated again")
        guard case .group(let children, _) = q.slides[0].shapes[0].kind, case .chart(let chart) = children[0].kind else {
            Issue.record("chart in group")
            return
        }
        #expect(chart.kept.parts[0].bytes == Array(repeating: 4, count: 10))
        #expect(chart.kept.parts[1].bytes.isEmpty)
    }
}

// MARK: - rtf.rs tests

@Suite struct RTFTests {
    /// A sign in a `\'hh` escape is not a hex digit and must be ignored.
    @Test func hexEscapeRejectsSign() {
        #expect(RTF.rtfToOutline(#"{\rtf1 a\'+5b\par}"#) == "ab\n")
    }

    /// Non-ASCII text after a `\uN` or `\'hh` escape used to split a character.
    @Test func nonASCIITextAfterEscapesDoesNotTrap() {
        let out = RTF.rtfToOutline(#"{\rtf1\pard \u233é x \'€y\par}"#)
        #expect(out.contains("x"), "\(out)")
        for rtf in [#"{\rtf1 \u233é€ z\par}"#, #"{\rtf1 \'é\par}"#, #"{\rtf1 \'4"#, #"{\rtf1 \u233"#] {
            _ = RTF.rtfToOutline(rtf)
        }
    }

    /// NUL is the surrogate marker, so NULs from `\u0`, `\'00` or raw bytes must not reach the joiner.
    @Test func nulEscapesDoNotDropTextOrAddASlide() {
        #expect(RTF.rtfToOutline(#"{\rtf1 \u0?abcé\par}"#) == "abcé\n")
        #expect(RTF.rtfToOutline(#"{\rtf1 a\'00bé\par}"#) == "abé\n")
        #expect(RTF.rtfToOutline("{\\rtf1 a\u{0}b\\par}\u{0}\u{0}") == "ab\n")
        #expect(RTF.rtfToOutline(#"{\rtf1 x\u-70000?y\par}"#) == "x\u{ee90}y\n")
    }

    /// `\_` is RTF's non-breaking hyphen: a visible character, not markup.
    @Test func nonBreakingHyphenIsKept() {
        #expect(RTF.rtfToOutline(#"{\rtf1\pard Year\_end review\par}"#) == "Year\u{2011}end review\n")
    }

    /// A hostile `\li` near `Int64.max` overflowed the rounding addend.
    @Test func hugeLeftIndentGivesTheDeepestLevel() {
        let out = RTF.rtfToOutline(#"{\rtf1\pard\li9223372036854775807 deep\par\pard\li-9223372036854775808 flat\par}"#)
        #expect(out == String(repeating: "\t", count: 9) + "deep\nflat\n")
    }

    @Test func exportReadsBackAsTheSameOutline() {
        var p = blankPresentation(wideSlideSize, .default, false)
        DeckFormat.outlineToSlides(&p, "Plan {Q3}\n\tGrow — fast 😀\n\t\tEurope\\Asia\nCafé résumé\n\tDone\n")
        let rtf = RTF.slidesToRTF(p)
        #expect(RTF.sniff(Array(rtf.utf8)))
        #expect(rtf.contains("\\outlinelevel2") && rtf.contains("Plan \\{Q3\\}"), "\(rtf)")
        #expect(RTF.rtfToOutline(rtf) == DeckFormat.slidesToOutline(p))
    }

    /// A title with two paragraphs: the plain outline keeps both, and so does the RTF export.
    @Test func everyTitleParagraphIsExported() throws {
        var p = blankPresentation(wideSlideSize, .default, false)
        DeckFormat.outlineToSlides(&p, "First line\n\tBody\n")
        let ti = try #require(p.slides[0].shapes.firstIndex { $0.phType?.isTitle ?? false })
        p.slides[0].shapes[ti].text?.paragraphs.append(Paragraph("Second line"))
        let rtf = RTF.slidesToRTF(p)
        #expect(rtf.contains("First line\\line Second line\\b0\\par"), "\(rtf)")
        #expect(RTF.rtfToOutline(rtf) == DeckFormat.slidesToOutline(p))
    }

    @Test func readsWordStyleRTFByIndentAndHexEscapes() {
        let rtf = #"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\*\generator X;}\pard\b Title one\b0\par\pard\li720 Point \'93a\'94\par\pard\li1440 Sub\par}"#
        #expect(RTF.rtfToOutline(rtf) == "Title one\n\t\tPoint “a”\n\t\t\t\tSub\n")
    }

    /// Word writes a list item's bullet as `{\listtext\pard\plain …\'b7\tab}` (older writers:
    /// `{\pntext …}`) after the paragraph's own `\li`. That group is the rendered bullet, not text.
    @Test func wordListBulletsAreNotTextAndKeepTheIndent() {
        let rtf = #"{\rtf1\ansi\pard Title\par\pard\fi-360\li720{\listtext\pard\plain\f1\'b7\tab}Point\par\pard\li720{\pntext\f1\'b7\tab}Old\par}"#
        #expect(RTF.rtfToOutline(rtf) == "Title\n\t\tPoint\n\t\tOld\n")
    }
}
