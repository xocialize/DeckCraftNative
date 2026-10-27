// Port of deckcraft crates/pptx/tests/it/comments.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): comment threads through PPTX. The modern part keeps replies and resolved
// state, the legacy part stays readable, and a package with both imports every thread once.
import DCModel
import Testing
@testable import DCPPTX

private func deck() -> Presentation {
    var p = newPresentation(nil)
    p.slides[0].comments = [
        Comment(
            author: "Ada", initials: "AL", text: "Top thread\nsecond line", date: "2025-03-04T05:06:07Z", x: 90, y: 45,
            resolved: true,
            replies: [
                Comment(author: "Bob", text: "A <reply> & more", date: "2025-03-04T06:00:00Z"),
                Comment(author: "Ada", text: "Another reply", date: "2025-03-04T06:30:00Z", resolved: true),
            ],
            shape: nil
        ),
        Comment(
            author: "Bob", initials: "BC", text: "Open thread", date: "2025-03-05T01:02:03Z", x: 120, y: 60, resolved: false,
            replies: [], shape: nil
        ),
    ]
    return p
}

private func part(_ bytes: [UInt8], _ name: String) throws -> String {
    let d = try #require(IT.part(bytes, name), "part \(name)")
    return String(decoding: d, as: UTF8.self)
}

/// Rewrite the package, dropping entries by name.
private func rewrite(_ bytes: [UInt8], _ drop: [String]) throws -> [UInt8] {
    try IT.zip(IT.entries(bytes).filter { e in !drop.contains(e.name) })
}

/// Every element and attribute prefix in `el` and below is bound by an `xmlns:` declaration in scope
/// (quick-xml's `NsReader` resolving to `Unknown` is the failure). `xml` is predefined; unprefixed
/// names need no binding.
private func unboundPrefixes(_ el: XMLEl, _ scope: Set<String>, _ out: inout [String]) {
    var scope = scope
    for (k, _) in el.attrs where k.hasPrefix("xmlns:") {
        scope.insert(String(k.dropFirst(6)))
    }
    func bound(_ name: String) -> Bool {
        guard let colon = name.firstIndex(of: ":") else { return true }
        let prefix = String(name[..<colon])
        return prefix == "xml" || prefix == "xmlns" || scope.contains(prefix)
    }
    if !bound(el.name) { out.append("unbound prefix on <\(el.name)>") }
    for (k, _) in el.attrs where !bound(k) {
        out.append("unbound prefix on attribute \(k)")
    }
    for c in el.elements { unboundPrefixes(c, scope, &out) }
}

@Suite struct IntegrationCommentsTests {
    // Rust: it/comments.rs::threads_and_resolved_round_trip
    @Test func threadsAndResolvedRoundTrip() throws {
        let p = deck()
        let bytes = try PPTX.export(p)
        let q = try PPTX.import(bytes)
        let (a, b) = (p.slides[0].comments, q.slides[0].comments)
        try #require(b.count == a.count, "comments duplicated: \(b)")
        #expect(b[0].author == "Ada")
        #expect(b[0].initials == "AL")
        #expect(b[0].text == "Top thread\nsecond line")
        #expect(b[0].date == "2025-03-04T05:06:07Z")
        #expect(b[0].resolved)
        #expect(b[0].x == 90.0 && b[0].y == 45.0)
        try #require(b[0].replies.count == 2)
        #expect(b[0].replies[0].author == "Bob")
        #expect(b[0].replies[0].text == "A <reply> & more")
        #expect(b[0].replies[0].date == "2025-03-04T06:00:00Z")
        #expect(b[0].replies[1].text == "Another reply")
        #expect(!b[0].replies[0].resolved)
        #expect(b[0].replies[1].resolved)
        #expect(b[1].author == "Bob")
        #expect(!b[1].resolved)
        #expect(b[1].text == "Open thread")
    }

    // Rust: it/comments.rs::package_carries_both_parts_and_the_slide_anchor
    @Test func packageCarriesBothPartsAndTheSlideAnchor() throws {
        let bytes = try PPTX.export(deck())
        let modern = try part(bytes, "ppt/comments/modernComment1.xml")
        #expect(modern.has("p188:cmLst"), "\(modern)")
        // The thread and the second reply are resolved; the first reply is not.
        #expect(modern.count(of: #"status="resolved""#) == 2, "\(modern)")
        #expect(modern.has("p188:replyLst") && modern.has("A &lt;reply&gt; &amp; more"), "\(modern)")
        #expect(modern.has(#"<a:t>second line</a:t>"#), "\(modern)")
        let legacy = try part(bytes, "ppt/comments/comment1.xml")
        #expect(legacy.has("<p:cm ") && legacy.has("Top thread"), "\(legacy)")
        let authors = try part(bytes, "ppt/authors.xml")
        #expect(authors.has("p188:authorLst") && authors.has("Ada"), "\(authors)")
        #expect(try part(bytes, "ppt/commentAuthors.xml").has("p:cmAuthorLst"))
        let rels = try part(bytes, "ppt/slides/_rels/slide1.xml.rels")
        #expect(rels.has("2018/10/relationships/comments"), "\(rels)")
        // The slide's commentRel anchor names the relationship that points at THIS modern part —
        // the wiring PowerPoint needs and DeckCraft's own reader does not check.
        let slide = try part(bytes, "ppt/slides/slide1.xml")
        #expect(slide.has("commentRel") && slide.has("{6950BFC3-D8DA-4A85-94F7-54DA5524770B}"), "\(slide)")
        let anchorAt = try #require(slide.byteFind("commentRel"), "anchor")
        let afterAnchor = slide.bytes(anchorAt)
        let ridAt = try #require(afterAnchor.byteFind(#"r:id=""#), "anchor r:id") + 6
        let ridTail = afterAnchor.bytes(ridAt)
        let rid = ridTail.bytes(0, ridTail.byteFind("\"") ?? ridTail.utf8.count)
        // `rels.split("<Relationship ").find(…)`.
        var pieces: [String] = []
        var rest = rels
        while let i = rest.byteFind("<Relationship ") {
            pieces.append(rest.bytes(0, i))
            rest = rest.bytes(i + "<Relationship ".utf8.count)
        }
        pieces.append(rest)
        let rel = try #require(pieces.first { $0.has(#"Id="\#(rid)""#) }, "anchor rel")
        #expect(rel.has("2018/10/relationships/comments") && rel.has("../comments/modernComment1.xml"), "\(rel)")
        let ct = try part(bytes, "[Content_Types].xml")
        #expect(ct.has("application/vnd.ms-powerpoint.comments+xml") && ct.has("application/vnd.ms-powerpoint.authors+xml"), "\(ct)")
    }

    /// Comments on several slides: every comment slide gets its own numbered pair of parts and its
    /// own anchor; comment-free slides get none.
    // Rust: it/comments.rs::comments_on_several_slides_round_trip
    @Test func commentsOnSeveralSlidesRoundTrip() throws {
        var p = deck()
        let layout = p.slides[0].layout
        while p.slides.count < 3 {
            let s = try #require(newSlide(&p, layout), "slide")
            p.slides.append(s)
        }
        p.slides[2].comments = [Comment(author: "Cara", text: "Slide three", date: "2025-03-06T00:00:00Z")]
        let bytes = try PPTX.export(p)
        #expect(try part(bytes, "ppt/comments/modernComment1.xml").has("Top thread"))
        // The parts are numbered by comment slide: the comment-free middle slide is skipped.
        #expect(try part(bytes, "ppt/comments/comment2.xml").has("Slide three"))
        #expect(try part(bytes, "ppt/comments/modernComment2.xml").has("Slide three"))
        let rels2 = try part(bytes, "ppt/slides/_rels/slide2.xml.rels")
        #expect(!rels2.has("relationships/comments"), "\(rels2)")
        let q = try PPTX.import(bytes)
        try #require(q.slides.count == 3)
        #expect(q.slides[0].comments.count == 2)
        #expect(q.slides[1].comments.isEmpty)
        try #require(q.slides[2].comments.count == 1)
        #expect(q.slides[2].comments[0].text == "Slide three")
    }

    /// A legacy-only package (what older tools read and write) still imports: 1/8 pt positions,
    /// flattened replies.
    // Rust: it/comments.rs::legacy_only_package_imports
    @Test func legacyOnlyPackageImports() throws {
        let bytes = try PPTX.export(deck())
        let trimmed = try rewrite(
            bytes,
            [
                "ppt/comments/modernComment1.xml",
                "ppt/authors.xml",
                "ppt/slides/_rels/slide1.xml.rels", // rewritten below without the modern rel
            ]
        )
        // Re-add the slide rels without the modern-comments relationship and without the anchor ext.
        let legacyRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="../comments/comment1.xml"/></Relationships>
        """
        var files = try IT.entries(trimmed).map { e -> (name: String, data: [UInt8]) in
            guard e.name == "ppt/slides/slide1.xml" else { return e }
            var xml = String(decoding: e.data, as: UTF8.self)
            if let start = xml.byteFind("<p:extLst>") {
                let end = xml.byteFind("</p:extLst>").map { $0 + "</p:extLst>".utf8.count } ?? xml.utf8.count
                xml = xml.bytes(0, start) + xml.bytes(end)
            }
            return (e.name, Array(xml.utf8))
        }
        files.append(("ppt/slides/_rels/slide1.xml.rels", Array(legacyRels.utf8)))
        let legacyPkg = try IT.zip(files)

        let q = try PPTX.import(legacyPkg)
        let b = q.slides[0].comments
        // The legacy part flattened the two replies into siblings: four top-level comments.
        try #require(b.count == 4, "\(b)")
        #expect(b[0].text == "Top thread\nsecond line")
        // The legacy format has no resolved state — exactly what the modern part adds.
        #expect(!b[0].resolved)
        #expect(b[0].x == 90.0 && b[0].y == 45.0, "legacy positions are 1/8 pt")
        #expect(b.allSatisfy { $0.replies.isEmpty })
    }

    /// A modern-only package (no legacy part) imports threads and EMU positions.
    // Rust: it/comments.rs::modern_only_package_imports
    @Test func modernOnlyPackageImports() throws {
        let bytes = try PPTX.export(deck())
        let trimmed = try rewrite(bytes, ["ppt/comments/comment1.xml"])
        let q = try PPTX.import(trimmed)
        let b = q.slides[0].comments
        try #require(b.count == 2, "\(b)")
        #expect(b[0].replies.count == 2)
        #expect(b[0].resolved)
        #expect(b[0].x == 90.0 && b[0].y == 45.0, "modern positions are EMU")
    }

    /// Every prefix an exported part uses is bound: PowerPoint refuses a package whose part is not
    /// namespace-well-formed (issue #974, the modern comments part used `a:` without declaring it).
    /// quick-xml's `NsReader` is replaced by DCPPTX's parser (quick-xml's rules) and a walk over the
    /// tree that tracks the `xmlns:` declarations in scope.
    // Rust: it/comments.rs::every_written_xml_part_binds_its_prefixes
    @Test func everyWrittenXmlPartBindsItsPrefixes() throws {
        let bytes = try PPTX.export(deck())
        var modern = 0
        for (name, data) in try IT.entries(bytes) {
            guard name.hasSuffix(".xml") || name.hasSuffix(".rels") else { continue }
            if name.has("modernComment") { modern += 1 }
            let doc: XMLDoc
            do {
                doc = try parseXML(data)
            } catch {
                Issue.record("\(name): not well-formed: \(error)")
                continue
            }
            var problems: [String] = []
            unboundPrefixes(doc.root, [], &problems)
            #expect(problems.isEmpty, "\(name): \(problems)")
        }
        #expect(modern > 0, "the deck should write a modern comments part")
    }
}
