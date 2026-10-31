// DCPPT — the formatting (P2b): every paragraph and run of every slide resolves, through DCModel's master and list
// styles, to the formatting Apache POI resolves through the `.ppt`'s own master styles (Tools/legacy/PoiTool.java
// format-ppt). Compared: alignment, left margin, indent, bullet and its character, spacing before and after, line
// spacing, and each run's font, size, bold, italic, underline and colour. A property POI leaves unresolved (null) is
// not compared.
import DCColor
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCPPT

@Suite struct FormattingTests {
    struct Dump: Decodable {
        struct Run: Decodable {
            let text: String
            let font: String?
            let size: Double?
            let bold: Bool, italic: Bool, underline: Bool
            let color: String?
        }
        struct Para: Decodable {
            let level: Int
            let align: String?
            let leftMargin: Double?, indent: Double?
            let bullet: Bool
            let bulletChar: String?, bulletFont: String?
            let spaceBefore: Double?, spaceAfter: Double?, lineSpacing: Double?
            let runs: [Run]
        }
        struct Shape: Decodable { let text: String; let paragraphs: [Para] }
        struct Slide: Decodable { let shapes: [Shape] }
        let slides: [Slide]
    }

    /// The fixtures, and PowerPoint 16's own `.ppt` files when the local set is here.
    static func cases() throws -> [(name: String, file: URL, ref: URL, password: String?)] {
        let legacy = PPTFileTests.legacy
        var out: [(name: String, file: URL, ref: URL, password: String?)] = PPTFileTests.manifest()
            .filter { $0.kind == "ppt" || $0.kind == "encrypted-ppt" }
            .map { f in
                let name = URL(filePath: f.file).lastPathComponent
                return (name, legacy.appending(path: f.file), legacy.appending(path: "reference/\(name).poi-format.json"),
                        f.kind == "encrypted-ppt" ? f.password : nil)
            }
        let local = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
        struct Meta: Decodable { let password: String }
        for n in (try? FileManager.default.contentsOfDirectory(atPath: local.path))?.filter({ $0.hasSuffix(".ppt.poi-format.json") }) ?? [] {
            let name = String(n.dropLast(".poi-format.json".count))
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: local.appending(path: "\(name).meta.json")))
            out.append((name, local.appending(path: name), local.appending(path: n), meta.password))
        }
        return out
    }

    static func hex(_ c: Rgba) -> String {
        String(format: "%02X%02X%02X", c.r, c.g, c.b)
    }

    @Test func everyParagraphAndRunHasPOIsFormatting() throws {
        let cases = try Self.cases()
        try #require(cases.count >= 60, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        var compared = 0
        var issues: [String: [String]] = [:]
        func check(_ prop: String, _ ok: Bool, _ what: @autoclosure () -> String) {
            compared += 1
            if !ok { issues[prop, default: []].append(what()) }
        }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.06) -> Bool { a.map { abs($0 - b) <= tolerance } ?? false }

        for c in cases {
            guard FileManager.default.fileExists(atPath: c.ref.path) else { continue }
            let ref = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: c.ref))
            let (p, _) = try PPT.importChecked(Array(try Data(contentsOf: c.file)), password: c.password)
            for (i, (slide, theirs)) in zip(p.slides, ref.slides).enumerated() {
                guard let ctx = Resolve.Ctx.forSlide(p, slide) else { continue }
                // WordArt's string is a shape property POI doesn't read.
                let shapes = ShapeTests.leaves(slide.shapes).filter { $0.text?.body.warp == nil }.filter { s in
                    !(s.text?.paragraphs ?? []).allSatisfy { $0.runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                }
                guard shapes.count == theirs.shapes.count else {
                    issues["shapes", default: []].append("\(c.name) slide \(i + 1): POI \(theirs.shapes.count), ours \(shapes.count)")
                    continue
                }
                for (shape, ts) in zip(shapes, theirs.shapes) {
                    let paras = shape.text?.paragraphs ?? []
                    guard paras.count == ts.paragraphs.count else {
                        issues["paragraphs", default: []].append("\(c.name) slide \(i + 1) “\(ts.text.prefix(20))”: POI \(ts.paragraphs.count), ours \(paras.count)")
                        continue
                    }
                    for (para, tp) in zip(paras, ts.paragraphs) {
                        let at = "\(c.name) slide \(i + 1) “\(tp.runs.map(\.text).joined().prefix(24))”"
                        let pp = Resolve.para(ctx, shape, para)
                        check("level", Int(para.level) == tp.level, "\(at): POI \(tp.level), ours \(para.level)")
                        if let a = tp.align { check("align", pp.align?.rawValue == a.lowercased(), "\(at): POI \(a), ours \(String(describing: pp.align))") }
                        if let m = tp.leftMargin { check("leftMargin", near(pp.marginLeft, m), "\(at): POI \(m), ours \(String(describing: pp.marginLeft))") }
                        if let ind = tp.indent, let m = tp.leftMargin {
                            check("indent", near(pp.indent, ind - m), "\(at): POI \(ind - m), ours \(String(describing: pp.indent))")
                        }
                        let bulleted: Bool = if case .char? = pp.bullet { true } else if case .autoNum? = pp.bullet { true } else { false }
                        check("bullet", bulleted == tp.bullet, "\(at): POI \(tp.bullet), ours \(String(describing: pp.bullet))")
                        if tp.bullet, let ch = tp.bulletChar, case .char(let ours)? = pp.bullet {
                            check("bulletChar", ours == ch || ch.utf16.first.map { PF.bulletText($0, font: tp.bulletFont) } == ours, "\(at): POI \(ch.unicodeScalars.map { String($0.value, radix: 16) }), ours \(ours)")
                        }
                        func spacing(_ s: Spacing?, _ v: Double) -> Bool {
                            switch s {
                            case .pct(let f)?: abs(f * 100 - v) < 0.6
                            case .pts(let x)?: abs(-x - v) < 0.06
                            case nil: v == 0
                            }
                        }
                        if let v = tp.spaceBefore { check("spaceBefore", spacing(pp.spaceBefore, v), "\(at): POI \(v), ours \(String(describing: pp.spaceBefore))") }
                        if let v = tp.spaceAfter { check("spaceAfter", spacing(pp.spaceAfter, v), "\(at): POI \(v), ours \(String(describing: pp.spaceAfter))") }
                        if let v = tp.lineSpacing { check("lineSpacing", spacing(pp.lineSpacing ?? .pct(1), v), "\(at): POI \(v), ours \(String(describing: pp.lineSpacing))") }

                        // Runs: each of POI's runs against ours at the same character offset.
                        var starts: [(start: Int, run: Run)] = []
                        var n = 0
                        for r in para.runs { starts.append((n, r)); n += r.text.utf16.count }
                        var offset = 0
                        for tr in tp.runs {
                            defer { offset += tr.text.utf16.count }
                            guard !tr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  let ours = starts.last(where: { $0.start <= offset })?.run else { continue }
                            let r = Resolve.run(ctx, shape, para, ours.props)
                            let rat = "\(at) run “\(tr.text.prefix(12))”"
                            // POI names the font for the run's script: East Asian, complex script or Latin. A file with no
                            // complex-script font (csFontRef) gets POI's East Asian one for complex-script runs, which
                            // LibreOffice also writes its CTL font into; we keep fontCs for csFontRef alone.
                            let script = tr.text.unicodeScalars.first { $0.value > 0x2FF }.map(\.value)
                            let family = switch script {
                            case (0x0590 ... 0x08FF)?: r.fontCs ?? r.fontEa ?? Resolve.fontFamily(ctx, r)
                            case (0x2E80 ... 0xFFEF)?: r.fontEa ?? Resolve.fontFamily(ctx, r)
                            default: Resolve.fontFamily(ctx, r)
                            }
                            if let f = tr.font { check("font", family == f, "\(rat): POI \(f), ours \(family)") }
                            if let s = tr.size { check("size", near(r.size, s), "\(rat): POI \(s), ours \(String(describing: r.size))") }
                            check("bold", (r.bold ?? false) == tr.bold, "\(rat): POI \(tr.bold), ours \(String(describing: r.bold))")
                            check("italic", (r.italic ?? false) == tr.italic, "\(rat): POI \(tr.italic), ours \(String(describing: r.italic))")
                            check("underline", (r.underline.map { $0 != "none" } ?? false) == tr.underline, "\(rat): POI \(tr.underline), ours \(String(describing: r.underline))")
                            if let col = tr.color { check("color", Self.hex(Resolve.textColor(ctx, r)) == col, "\(rat): POI \(col), ours \(Self.hex(Resolve.textColor(ctx, r)))") }
                        }
                    }
                }
            }
        }
        for (prop, list) in issues.sorted(by: { $0.key < $1.key }) {
            Issue.record(Comment(rawValue: "\(prop): \(list.count) differ, e.g.\n  \(list.prefix(6).joined(separator: "\n  "))"))
        }
        #expect(compared > 1000)
    }
}
