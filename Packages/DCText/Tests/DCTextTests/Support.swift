// DCTextTests — shared fixtures for the layout tests: a title-and-content slide whose body placeholder
// holds the text, laid out in a box. Port of the helpers in deckcraft crates/text/src/tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCGeometry
import DCModel
@testable import DCText
import Testing

struct Fixture {
    var pres: Presentation
    var shape: Shape

    var body: TextBody {
        get { shape.text ?? TextBody() }
        set { shape.text = newValue }
    }

    /// The first paragraph.
    var para: Paragraph {
        get { body.paragraphs.first ?? Paragraph() }
        set {
            var b = body
            if b.paragraphs.isEmpty { b.paragraphs = [newValue] } else { b.paragraphs[0] = newValue }
            body = b
        }
    }

    /// Change every paragraph.
    mutating func eachPara(_ f: (inout Paragraph) -> Void) {
        var b = body
        for i in b.paragraphs.indices { f(&b.paragraphs[i]) }
        body = b
    }

    /// Change every run of every paragraph.
    mutating func eachRun(_ f: (inout Run) -> Void) {
        eachPara { p in for i in p.runs.indices { f(&p.runs[i]) } }
    }

    func lay(_ w: Double, _ h: Double) -> TextLayout {
        guard let ctx = Resolve.Ctx.forSlide(pres, pres.slides[0]) else { return TextLayout() }
        return TextLayoutEngine.layout(ctx, shape, body, TextOpts(rect: Rect(0, 0, w, h)))
    }

    var ctx: Resolve.Ctx? { Resolve.Ctx.forSlide(pres, pres.slides[0]) }
}

func setup(_ text: String, _ w: Double, _ h: Double) -> Fixture {
    var p = Presentation.default
    let layout = layoutOfKind(p, .titleAndContent) ?? LayoutId(0)
    guard var s = newSlide(&p, layout), s.shapes.count > 1 else { return Fixture(pres: p, shape: .default) }
    var body = s.shapes.remove(at: 1)
    body.xfrm = Xfrm(0, 0, w, h)
    body.text = TextBody.fromText(text)
    s.shapes = [body]
    p.slides = [s]
    return Fixture(pres: p, shape: body)
}

/// A one-paragraph body with no bullet, `rtl` and `align` set.
func bidiSetup(_ runs: [Run], _ w: Double, _ rtl: Bool, _ align: Align) -> Fixture {
    var f = setup("x", w, 300)
    var para = Paragraph(runs: runs)
    para.props.rtl = rtl
    para.props.align = align
    para.props.bullet = .none_
    para.props.marginLeft = 0
    para.props.indent = 0
    f.body.paragraphs = [para]
    return f
}

func run(_ text: String, size: Double? = nil, lang: String? = nil) -> Run {
    var r = Run(text)
    r.props.size = size
    r.props.lang = lang
    return r
}

func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) < tol }

let db = FontDB.shared

/// Is any face able to draw Arabic here (installed or bundled)?
func arabicFace() -> FontFace? {
    let f = db.cascade(["\u{0633}"], [db.face("Inter", "Regular")], "Regular")
    return f.covers("\u{0633}") ? f : nil
}

/// The first installed or bundled family of `families` for which `pick` holds.
func firstFamily(_ families: [String], _ pick: (FontFace) -> Bool) -> String? {
    families.filter { db.hasFamily($0) }.map { db.face($0, "Regular") }.first(where: pick)?.family
}

let latinFamilies = ["Carlito", "Calibri", "DejaVu Sans", "Liberation Sans", "Inter", "Arial", "Cambria", "Times New Roman"]

/// The lines of `text` in a box `w` wide, as strings.
func wrapped(_ text: String, _ w: Double, _ set: (inout ParaProps) -> Void = { _ in }) -> [String] {
    var f = bidiSetup([Run(text)], w, false, .left)
    f.body.body.insetL = 0
    f.body.body.insetR = 0
    set(&f.body.paragraphs[0].props)
    let l = f.lay(w, 600)
    let chars = Array(text.unicodeScalars)
    return l.lines.map { li in String(String.UnicodeScalarView(chars[li.start ..< li.end])) }
}

/// Width of `text` on one line.
func oneLine(_ text: String) -> Double {
    let l = bidiSetup([Run(text)], 5000, false, .left).lay(5000, 300)
    guard let line = l.lines.first, let a = line.caretX.first, let b = line.caretX.last else { return 0 }
    return b - a
}
