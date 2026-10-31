// DCPPT — the masters' own graphics (P6): what each slide shows of its template is what POI reads. The first main
// master's shapes (not its placeholders) are the DCModel master's; a slide following another master (a title master,
// or another main master, which LibreOffice writes one per layout) is on a layout holding that master's shapes; and
// each slide hides them or not as its SlideFlags say. The masters deck (Tools/legacy/masters-deck.py) puts a banner,
// a logo, a rule and a text box on its master and a shape and background on its Title Slide layout.
import DCModel
import Foundation
import Testing
@testable import DCPPT

@Suite struct MasterTests {
    struct Dump: Decodable {
        struct Shape: Decodable {
            let kind: String
            let x: Double, y: Double, w: Double, h: Double
            let placeholder: String?
        }
        struct Master: Decodable { let kind: String; let main: Int?; let shapes: [Shape] }
        struct Slide: Decodable { let master: Int?; let followMasterObjects: Bool? }
        let slides: [Slide]
        let masters: [Master]?
    }

    /// A master's own graphics as POI lists them: its shapes that aren't placeholders.
    static func own(_ m: Dump.Master) -> [Dump.Shape] { m.shapes.filter { $0.placeholder == nil } }

    /// Whether `ours` are `theirs`, box for box in order.
    static func same(_ ours: [Shape], _ theirs: [Dump.Shape]) -> Bool {
        ours.count == theirs.count && zip(ours, theirs).allSatisfy { s, t in
            guard let x = s.xfrm else { return false }
            return abs(x.x - t.x) < 0.6 && abs(x.y - t.y) < 0.6 && abs(x.w - t.w) < 0.6 && abs(x.h - t.h) < 0.6
        }
    }

    @Test func eachSlideShowsItsMastersGraphics() throws {
        let cases = try ShapeTests.cases()
        try #require(cases.count >= 60, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        var issues: [String] = []
        var compared = 0, withGraphics = 0
        for c in cases {
            guard let data = try? Data(contentsOf: c.ref), let ref = try? JSONDecoder().decode(Dump.self, from: data),
                  let masters = ref.masters, !masters.isEmpty
            else { continue }
            let (p, _) = try PPT.importChecked(Array(try Data(contentsOf: c.file)), password: c.password)
            guard let master = p.masters.first else { continue }
            let mine = master.shapes.filter { $0.ph == nil }
            let firstMain = masters.firstIndex { $0.kind == "main" }
            if let firstMain, !Self.same(mine, Self.own(masters[firstMain])) {
                issues.append("\(c.name): the master has \(mine.count) shapes, POI's \(Self.own(masters[firstMain]).count)")
            }
            let blank = layoutOfKind(p, .blank)
            for (i, (slide, theirs)) in zip(p.slides, ref.slides).enumerated() {
                let at = "\(c.name) slide \(i + 1)"
                compared += 1
                if let follow = theirs.followMasterObjects, slide.showMasterShapes != follow {
                    issues.append("\(at): shows master graphics \(slide.showMasterShapes), POI \(follow)")
                }
                guard let mi = theirs.master, masters.indices.contains(mi) else { continue }
                let m = masters[mi]
                if !Self.own(m).isEmpty { withGraphics += 1 }
                if mi == firstMain {
                    if slide.layout != blank { issues.append("\(at): follows the first main master but isn't on the blank layout") }
                    continue
                }
                guard let layout = master.layouts.first(where: { $0.id == slide.layout }) else {
                    issues.append("\(at): no layout for POI's master \(mi)")
                    continue
                }
                // A layout's own graphics end with its master's (a title master of another main master starts with
                // that main master's).
                let shapes = layout.shapes.filter { $0.ph == nil }
                let want = Self.own(m)
                if shapes.count < want.count || !Self.same(Array(shapes.suffix(want.count)), want) {
                    issues.append("\(at): its layout has \(shapes.count) shapes, POI's master \(mi) (\(m.kind)) \(want.count)")
                }
                if m.kind == "title", let main = m.main, main == firstMain, layout.showMasterShapes != (theirs.followMasterObjects ?? true) {
                    // A title master's own fMasterObjects isn't in POI's dump; the masters deck's follows its master.
                    if c.name.hasPrefix("masters") { issues.append("\(at): the title layout hides the master's graphics") }
                }
            }
        }
        #expect(issues.isEmpty, "\(issues.prefix(30).joined(separator: "\n"))")
        #expect(compared > 500)
        #expect(withGraphics >= 5, "slides whose master has graphics of its own: \(withGraphics)")
    }

    /// The masters deck, as LibreOffice saves it: its graphics, its title slides' circle and background, and the
    /// slides hiding them.
    @Test func theMastersDeckKeepsItsTemplate() throws {
        let file = PPTFileTests.legacy.appending(path: "ppt/masters.ppt")
        let (p, report) = try PPT.importChecked(Array(try Data(contentsOf: file)))
        #expect(!report.notImported.contains { $0.contains("master") })
        let master = try #require(p.masters.first)
        let own = master.shapes.filter { $0.ph == nil }
        // The banner, the logo, the rule, the text box; LibreOffice's first master is the Title Slide layout's, so
        // its circle too.
        #expect(own.count == 5)
        #expect(own.contains { if case .picture = $0.kind { true } else { false } })
        #expect(own.contains { $0.text?.paragraphs.flatMap(\.runs).map(\.text).joined() == "Company Confidential" })
        #expect(p.slides.map(\.showMasterShapes) == [true, true, true, false, false])
    }
}
