// The tests of deckcraft crates/pptx/src/xml.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), plus the quick-xml behaviours the port reproduces.
@testable import DCPPTX
import Testing

@Suite struct XMLTests {
    @Test func literalCRLFAndLoneCRReadAsLFButCharRefStays() throws {
        let d = try parseXML("<a:p><a:t>one\r\ntwo\rthree&#13;four</a:t><a:t><![CDATA[x\r\ny]]></a:t></a:p>")
        let t = d.root.childrenNamed("t").map(\.text)
        #expect(t == ["one\ntwo\nthree\rfour", "x\ny"])
    }

    @Test func crInTextSurvivesWriteRead() throws {
        #expect(XML.esc("a\rb") == "a&#13;b")
        var w = W()
        w.elt("a:t", "one\rtwo\r\nthree")
        let d = try parseXML(w.s)
        #expect(d.root.text == "one\rtwo\r\nthree")
    }

    @Test func parseBasicAndEntities() throws {
        let d = try parseXML(#"<?xml version="1.0"?><a:p xmlns:a="x"><a:r><a:t>A &amp; B &#x41; &lt;</a:t></a:r><a:x r:id="rId1" id="5"/></a:p>"#)
        #expect(d.root.local == "p")
        #expect(d.root.find("t")?.text == "A & B A <")
        let x = try #require(d.root.child("x"))
        #expect(x.attr("id") == "5")
        #expect(x.attr("r:id") == "rId1")
        #expect(d.nsDecls().count == 1)
    }

    @Test func truncatedAndGarbage() {
        #expect((try? parseXML("<a><b><c>text")) != nil)
        #expect((try? parseXML("")) == nil)
        let deep = String(repeating: "<a>", count: XML.maxDepth + 10)
        #expect((try? parseXML(deep)) == nil)
    }

    @Test func escapeDropsControlChars() {
        #expect(XML.esc("a\u{b}b<\u{0}") == "ab&lt;")
        #expect(XML.escAttr("\"x\"\n") == "&quot;x&quot;&#10;")
    }

    @Test func roundtripSerialize() throws {
        let d = try parseXML(#"<p:sp a="1"><p:t>x &amp; y</p:t><e/></p:sp>"#)
        #expect(d.root.toXML() == #"<p:sp a="1"><p:t>x &amp; y</p:t><e/></p:sp>"#)
    }

    // MARK: quick-xml's behaviour, as deckcraft configures it

    @Test func errorsAreQuickXMLs() {
        let cases: [(String, String)] = [
            ("<a>x & y</a>", XML.Fail.unclosedReference),
            ("<a>&amp</a>", XML.Fail.unclosedReference),
            ("<a", XML.Fail.unclosedTag),
            ("<a b='x>", XML.Fail.unclosedSingleQuoted),
            ("<a b=\"x>", XML.Fail.unclosedDoubleQuoted),
            ("<a><!-- x </a>", XML.Fail.unclosedComment),
            ("<a><!-x--></a>", XML.Fail.unclosedComment),
            ("<a><![CDATA[x</a>", XML.Fail.unclosedCData),
            ("<a><!x></a>", XML.Fail.invalidBangMarkup),
            ("<!DOCTYPE>", XML.Fail.missingDoctypeName),
            ("<!Dx><a/>", XML.Fail.unclosedDoctype),
            ("<?xml version='1.0'", XML.Fail.unclosedXmlDecl),
            ("<?pi", XML.Fail.unclosedPI),
            ("<?><a/>", XML.Fail.unclosedPI),
            ("<", XML.Fail.unclosedTag),
            ("text only", "no root element"),
        ]
        for (input, message) in cases {
            #expect(throws: PPTXError.xml(message), "\(input)") { try parseXML(input) }
        }
    }

    @Test func leniencyMatchesQuickXML() throws {
        // Mismatched and unmatched end tags only pop.
        #expect(try parseXML("<a><b>x</c></d></a>").root.toXML() == "<a><b>x</b></a>")
        // A DOCTYPE with an internal subset, comments and PIs are skipped.
        #expect(try parseXML("<!DOCTYPE a [<!ENTITY e 'v>'><!-- > --><?p > ?>]><a>1</a>").root.toXML() == "<a>1</a>")
        // Unknown entities read as nothing; bad character references too.
        #expect(try parseXML("<a>x&nbsp;y&#0;z&#xD800;</a>").root.text == "xyz")
        // Content after the root is ignored.
        #expect(try parseXML("<a/><b>x</b>").root.toXML() == "<a/>")
        // Attributes: malformed ones are skipped, the rest kept; values normalised.
        let e = try parseXML("<a x=1 y='2' z w = \"3\" v='a\tb&#10;c&lt;'/>").root
        #expect(e.attrs.map(\.key) == ["y", "w", "v"])
        #expect(e.attr("v") == "a b\nc<")
        // An unknown entity in an attribute keeps the raw value.
        #expect(try parseXML("<a v='x&foo;y'/>").root.attr("v") == "x&foo;y")
        // `<a / >` is a start tag named `a` (its `/` an attribute without a value).
        #expect(try parseXML("<a / ><b/></a>").root.toXML() == "<a><b/></a>")
        // Text that isn't UTF-8 reads as nothing; CDATA lossily.
        let bad = try parseXML([UInt8]("<a>x".utf8) + [0xFF] + [UInt8]("<![CDATA[".utf8) + [0xFF] + [UInt8]("]]></a>".utf8))
        #expect(bad.root.text == "\u{FFFD}")
        // A UTF-16 part.
        let utf16: [UInt8] = [0xFF, 0xFE] + "<?xml version=\"1.0\" encoding=\"UTF-16\"?><a>é</a>".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(try XML.parse(utf16).root.text == "é")
    }

    @Test func numbersParseAsRustDoes() throws {
        let e = try parseXML("<a i=' 42 ' p='+7' f='1.9' big='1e30' n='nan' b=' on ' h='0x10' u='-5'/>").root
        #expect(e.i64("i") == 42)
        #expect(e.i64("p") == 7)
        #expect(e.i64("f") == 1)
        #expect(e.i64("big") == 9_000_000_000_000_000_000)
        #expect(e.i32("big") == Int32.max)
        #expect(e.i64("n") == nil)
        #expect(e.f64("n") == nil)
        #expect(e.bool("b") == true)
        #expect(e.i64("h") == nil)
        #expect(e.u32("u") == 0)
    }

    @Test func builderFormatsLikeToString() {
        var w = W.frag()
        w.empty("x", A().a("f", 1.0).a("g", -0.0).a("h", 0.1 + 0.2).a("i", 1e21).a("j", Int64(-3)).o("k", nil as String?).b("l", false).t("m", true))
        #expect(w.s == #"<x f="1" g="-0" h="0.30000000000000004" i="1000000000000000000000" j="-3" l="0" m="1"/>"#)
        #expect(W.new().s == "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
    }
}
