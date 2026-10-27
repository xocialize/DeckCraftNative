// Port of deckcraft crates/pptx/tests/it/math_ns.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Equations whose math namespace is declared above the equation: on the slide root or on a
// wrapper.
import DCGeometry
import DCModel
import Testing
@testable import DCPPTX

@Suite struct IntegrationMathNsTests {
    private static let nsM = #"xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math""#

    /// Export an equation, move its `xmlns:m` from the equation to the element `host` opens, and
    /// return the OMML read back.
    private static func movedTo(_ host: String) throws -> String {
        var p = newPresentation(nil)
        let raw = p.allocId()
        let id = ShapeId(try #require(raw, "id"))
        let omml = "<m:oMathPara \(nsM)><m:oMath><m:r><m:t>x=1</m:t></m:r></m:oMath></m:oMathPara>"
        var eq = Shape.default
        eq.id = id
        eq.name = "Equation"
        eq.xfrm = Xfrm(10.0, 10.0, 200.0, 40.0)
        eq.text = TextBody(paragraphs: [Paragraph(runs: [Run(text: "x=1", props: .default, kind: .math(omml: omml))])])
        if !p.slides.isEmpty { p.slides[0].shapes = [eq] }
        var es = try IT.entries(PPTX.export(p))
        let si = try #require(es.firstIndex { $0.name == "ppt/slides/slide1.xml" }, "slide1")
        var xml = String(decoding: es[si].data, as: UTF8.self)
        try #require(xml.has(host), "\(xml)")
        xml = xml.replacen(" \(nsM)", "", 1).replacen(host, "\(host)\(nsM) ", 1)
        #expect(xml.count(of: nsM) == 1)
        es[si].data = Array(xml.utf8)

        let q = try PPTX.import(IT.zip(es))
        let shape = try #require(q.slides[0].shapes.first { $0.name == "Equation" }, "shape")
        let run = try #require(shape.text?.paragraphs.first?.runs.first, "run")
        guard case .math(let omml) = run.kind else {
            Issue.record("\(run.kind)")
            return ""
        }
        return omml
    }

    // Rust: it/math_ns.rs::math_namespace_declared_on_the_slide_root_is_kept
    @Test func mathNamespaceDeclaredOnTheSlideRootIsKept() throws {
        let omml = try Self.movedTo("<p:sld ")
        #expect(omml.has(Self.nsM), "\(omml)")
    }

    // Rust: it/math_ns.rs::math_namespace_declared_on_an_enclosing_wrapper_is_kept
    @Test func mathNamespaceDeclaredOnAnEnclosingWrapperIsKept() throws {
        let omml = try Self.movedTo("<mc:Choice ")
        #expect(omml.has(Self.nsM), "\(omml)")
    }
}
