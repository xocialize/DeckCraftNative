// DCPPT — the shapes (P3): every shape of every slide is where POI puts it, of the type POI names, with POI's fill
// and line colours, and every table has POI's rows and columns and cells; PowerPoint's own save of every gallery
// preset (Tools/legacy/preset-deck.py, local only) imports as the original deck's preset with its adjust values; and
// hostile property data never traps. Since P4 every picture, OLE object's preview, picture fill and picture background
// has POI's bytes and crop.
import CryptoKit
import DCColor
import DCGeometry
import DCModel
import DCPPTX
import DCTestSupport
import Foundation
import Testing
@testable import DCPPT

@Suite struct ShapeTests {
    /// A slide's shapes with groups opened up, each child's box mapped into slide coordinates; tables left out.
    static func leaves(_ shapes: [Shape]) -> [Shape] {
        shapes.flatMap { s -> [Shape] in
            switch s.kind {
            case .table: return []
            case .group(let children, let child):
                guard let x = s.xfrm, child.w != 0, child.h != 0 else { return leaves(children) }
                let sx = x.w / child.w, sy = x.h / child.h
                return leaves(children).map { c in
                    var c = c
                    if var f = c.xfrm {
                        f.x = x.x + (f.x - child.x) * sx
                        f.y = x.y + (f.y - child.y) * sy
                        f.w *= sx
                        f.h *= sy
                        c.xfrm = f
                    }
                    return c
                }
            default: return [s]
            }
        }
    }

    struct Dump: Decodable {
        struct Shape: Decodable {
            let kind: String
            let type: String
            let ooxml: String?
            let x: Double, y: Double, w: Double, h: Double
            let rot: Double?
            let flipH: Bool?, flipV: Bool?
            let fillType: Int?
            let fill: String?, line: String?
            let lineWidth: Double?
            let text: String?
            let rows: Int?, cols: Int?
            /// Whether the shape sets any fill or line property itself, names a master shape, or has vertices.
            let ownFill: Bool?, ownLine: Bool?, master: Bool?, vertices: Bool?
            let children: [Shape]?
            /// A picture's (or OLE object's preview's) bytes, a fill's picture, and the crop (left, top, right,
            /// bottom; null where the shape doesn't set it).
            let picture: Picture?, fillPicture: Picture?
            let crop: [Double?]?
        }
        struct Picture: Decodable { let type: String?; let size: Int?; let sha256: String? }
        struct Slide: Decodable { let shapes: [Shape]; let background: Picture? }
        let slides: [Slide]
        let pictures: [Picture]?
    }

    static func sha256(_ p: Presentation, _ m: MediaId) -> String? {
        p.media(m).map { SHA256.hash(data: Data($0.data)).map { String(format: "%02x", $0) }.joined() }
    }

    /// The fixtures, and PowerPoint 16's own `.ppt` files when the local set is here.
    static func cases() throws -> [(name: String, file: URL, ref: URL, password: String?)] {
        let legacy = PPTFileTests.legacy
        var out: [(name: String, file: URL, ref: URL, password: String?)] = PPTFileTests.manifest()
            .filter { $0.kind == "ppt" || $0.kind == "encrypted-ppt" }
            .map { f in
                let name = URL(filePath: f.file).lastPathComponent
                return (name, legacy.appending(path: f.file), legacy.appending(path: "reference/\(name).poi.json"),
                        f.kind == "encrypted-ppt" ? f.password : nil)
            }
        let local = Self.local
        struct Meta: Decodable { let password: String }
        for n in (try? FileManager.default.contentsOfDirectory(atPath: local.path))?.filter({ $0.hasSuffix(".ppt.poi.json") }) ?? [] {
            let name = String(n.dropLast(".poi.json".count))
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: local.appending(path: "\(name).meta.json")))
            out.append((name, local.appending(path: name), local.appending(path: n), meta.password))
        }
        return out
    }

    static var local: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/powerpoint-protected")
    }

    static func hex(_ c: Rgba) -> String {
        String(format: "%02X%02X%02X", c.r, c.g, c.b) + (c.a == 255 ? "" : String(format: "%02X", c.a))
    }

    /// Two colours as hex, within a step of each other in every channel (POI truncates an opacity of ½ to 7F, where
    /// it rounds to 80 here).
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == b }
        func bytes(_ s: String) -> [Int] {
            stride(from: 0, to: s.count, by: 2).map { Int(s.dropFirst($0).prefix(2), radix: 16) ?? -9 } + (s.count == 6 ? [255] : [])
        }
        let x = bytes(a), y = bytes(b)
        return x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= 1 }
    }

    /// POI's pictures and OLE objects.
    static func isPicture(_ s: Dump.Shape) -> Bool { s.kind == "HSLFPictureShape" || s.kind == "HSLFObjectShape" }

    @Test func everyShapeIsPOIs() throws {
        let cases = try Self.cases()
        try #require(cases.count >= 60, "no legacy fixtures (Tools/legacy/make-fixtures.sh)")
        var compared = 0
        var issues: [String: [String]] = [:]
        func check(_ prop: String, _ ok: Bool, _ what: @autoclosure () -> String) {
            compared += 1
            if !ok { issues[prop, default: []].append(what()) }
        }
        for c in cases {
            guard FileManager.default.fileExists(atPath: c.ref.path) else { continue }
            let ref = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: c.ref))
            let (p, _) = try PPT.importChecked(Array(try Data(contentsOf: c.file)), password: c.password)
            let theme = p.masters.first?.theme.colors ?? ColorScheme(name: "", colors: [])
            for (i, (slide, theirs)) in zip(p.slides, ref.slides).enumerated() {
                // POI gives a pattern background's bitmap as its picture; that's a pattern here.
                let pattern = if case .fill(.pattern)? = slide.background { true } else { false }
                if let bg = theirs.background, bg.type != "PICT", !pattern {
                    var ours: String?
                    if case .fill(.picture(let f))? = slide.background { ours = Self.sha256(p, f.media) }
                    check("background", ours == bg.sha256, "\(c.name) slide \(i + 1): POI's background \(bg.type ?? ""), ours \(String(describing: slide.background))")
                }
                func walk(_ ours: [Shape], _ poi: [Dump.Shape], _ at: String) {
                    guard ours.count == poi.count else {
                        check("count", false, "\(at): POI \(poi.count) (\(poi.map(\.type))), ours \(ours.count)")
                        return
                    }
                    for (s, t) in zip(ours, poi) {
                        let here = "\(at) \(t.type) “\(t.text?.prefix(16) ?? "")”"
                        switch s.kind {
                        case .group(let kids, _):
                            check("kind", t.kind == "HSLFGroupShape", "\(here): POI \(t.kind), ours a group")
                            walk(kids, t.children ?? [], here)
                        case .table(let table):
                            check("kind", t.kind == "HSLFTable", "\(here): POI \(t.kind), ours a table")
                            check("table", table.nRows == t.rows && table.nCols == t.cols,
                                  "\(here): POI \(t.rows ?? -1)×\(t.cols ?? -1), ours \(table.nRows)×\(table.nCols)")
                            let cells = (t.children ?? []).filter { $0.kind == "HSLFTableCell" }.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                            let mine = table.rows.flatMap { $0.cells.filter { !$0.isCovered } }.map {
                                $0.text.paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            check("cells", cells.sorted() == mine.sorted(), "\(here): POI \(cells), ours \(mine)")
                        case .picture(let f):
                            check("kind", Self.isPicture(t), "\(here): POI \(t.kind), ours a picture")
                            if let pic = t.picture, pic.type != "PICT" {
                                check("picture", Self.sha256(p, f.media) == pic.sha256, "\(here): POI's \(pic.type ?? "") of \(pic.size ?? -1) bytes, ours differs")
                            }
                            let crop = (t.crop ?? []).map { $0 ?? 0 }
                            check("crop", crop.isEmpty || zip(crop, f.crop).allSatisfy { abs($0 - $1) < 0.001 }, "\(here): POI \(crop), ours \(f.crop)")
                        case .opaque(_, let preview, _, _):
                            check("kind", t.kind == "HSLFObjectShape", "\(here): POI \(t.kind), ours an object")
                            if let pic = t.picture, pic.type != "PICT" {
                                check("picture", preview.flatMap { Self.sha256(p, $0) } == pic.sha256, "\(here): POI's preview \(pic.type ?? ""), ours differs")
                            }
                        case .media(let clip):
                            check("kind", Self.isPicture(t), "\(here): POI \(t.kind), ours media")
                            if let pic = t.picture, pic.type != "PICT" {
                                check("picture", clip.poster.flatMap { Self.sha256(p, $0) } == pic.sha256, "\(here): POI's poster, ours differs")
                            }
                        default:
                            // A picture whose picture can't be read keeps its place as an empty frame.
                            check("kind", !["HSLFGroupShape", "HSLFTable"].contains(t.kind) && (!Self.isPicture(t) || t.picture == nil),
                                  "\(here): POI \(t.kind), ours a shape")
                            if let pic = t.fillPicture, [2, 3].contains(t.fillType ?? 0), pic.type != "PICT" {
                                var ours: String?
                                if case .picture(let f)? = s.fill { ours = Self.sha256(p, f.media) }
                                check("fillPicture", ours == pic.sha256, "\(here): POI's fill \(pic.type ?? ""), ours \(String(describing: s.fill))")
                            }
                            // The type: the same preset, or a freeform where POI reads a freeform.
                            // A shape with vertices is a freeform whatever its type (PowerPoint gives presets it has no
                            // legacy type for the nearest type and their outline); a type with no DrawingML name maps
                            // to the nearest preset (LegacyShapes).
                            switch s.geom {
                            case .preset(let name, _):
                                let want = t.type == "TEXT_BOX" ? "rect" : t.ooxml
                                check("type", t.vertices != true && (name == want || (want == nil && t.type != "NOT_PRIMITIVE")),
                                      "\(here): POI \(t.ooxml ?? "nil"), ours \(name)")
                            case .custom:
                                check("type", t.vertices == true || t.type == "TRAPEZOID", "\(here): POI \(t.type), ours a freeform")
                            }
                        }
                        // The box: POI's anchor is the stored one, turned with the shape between 45° and 135°.
                        if let x = s.xfrm {
                            var rot = (t.rot ?? 0).truncatingRemainder(dividingBy: 360)
                            if rot < 0 { rot += 360 }
                            let swap = (45 ..< 135).contains(rot) || (225 ..< 315).contains(rot)
                            let w = swap ? t.h : t.w, h = swap ? t.w : t.h
                            let px = t.x + (t.w - w) / 2, py = t.y + (t.h - h) / 2
                            check("box", abs(x.x - px) < 0.6 && abs(x.y - py) < 0.6 && abs(x.w - w) < 0.6 && abs(x.h - h) < 0.6,
                                  "\(here): POI \(px),\(py) \(w)×\(h), ours \(x.x),\(x.y) \(x.w)×\(x.h)")
                            check("flip", x.flipH == (t.flipH ?? false) && x.flipV == (t.flipV ?? false), "\(here): flips")
                        }
                        // Colours, where the shape sets its own (a placeholder's come from its layout).
                        // POI reads only what the shape sets, with the specification's defaults: neither the drawing
                        // group's defaults nor a master shape's. WordArt's colours are its text's.
                        guard s.ph == nil, s.text?.body.warp == nil, t.master != true else { continue }
                        if case .table = s.kind { continue }
                        if case .group = s.kind { continue }
                        // A picture's fill is behind its picture: POI reads the picture fill PowerPoint stores there.
                        let pictured = switch s.kind { case .picture, .opaque, .media: true; default: false }
                        if !pictured, t.ownFill == true, t.fillType == 0 || t.fill == nil {
                            switch s.fill {
                            case .solid(let col)?:
                                let ours = Self.hex(col.resolve(theme, nil))
                                check("fill", Self.same(ours, t.fill), "\(here): POI \(t.fill ?? "none"), ours \(ours)")
                            case .none_?, nil:
                                check("fill", t.fill == nil, "\(here): POI \(t.fill ?? "none"), ours none")
                            default:
                                check("fill", t.fill != nil, "\(here): POI none, ours \(String(describing: s.fill))")
                            }
                        }
                        guard t.ownLine == true else { continue }
                        switch s.line?.fill {
                        case .solid(let col)?:
                            let ours = Self.hex(col.resolve(theme, nil))
                            check("line", Self.same(ours, t.line), "\(here): POI \(t.line ?? "none"), ours \(ours)")
                            if let lw = t.lineWidth, let w = s.line?.width { check("lineWidth", abs(lw - w) < 0.06, "\(here): POI \(lw), ours \(w)") }
                        default:
                            check("line", t.line == nil, "\(here): POI \(t.line ?? "none"), ours none")
                        }
                    }
                }
                walk(slide.shapes, theirs.shapes, "\(c.name) slide \(i + 1)")
            }
        }
        for (prop, list) in issues.sorted(by: { $0.key < $1.key }) {
            Issue.record(Comment(rawValue: "\(prop): \(list.count) differ, e.g.\n  \(list.prefix(8).joined(separator: "\n  "))"))
        }
        #expect(compared > 5000)
    }

    /// PowerPoint's save of every gallery preset, wide, tall and with its adjusts moved, comes back as the original
    /// deck's preset with its adjust values (or as a freeform where PowerPoint wrote one), in its box.
    @Test func powerPointsPresetsComeBackAsTheOriginals() throws {
        let file = Self.local.appending(path: "presets.open.ppt")
        let original = PPTFileTests.legacy.appending(path: "pptx/presets.pptx")
        guard FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: original.path) else { return }
        let (ours, _) = try PPT.importChecked(Array(try Data(contentsOf: file)), password: "Password1")
        let (want, _) = try PPTX.importChecked(Array(try Data(contentsOf: original)))
        try #require(ours.slides.count == want.slides.count)
        var presets = 0, freeforms = 0
        var issues: [String] = []
        for (slide, orig) in zip(ours.slides, want.slides).dropFirst() {
            try #require(slide.shapes.count == orig.shapes.count)
            for (s, o) in zip(slide.shapes, orig.shapes) {
                guard case .preset(let name, let adj) = o.geom, let x = s.xfrm, let ox = o.xfrm else { continue }
                if abs(x.x - ox.x) > 0.6 || abs(x.y - ox.y) > 0.6 || abs(x.w - ox.w) > 0.6 || abs(x.h - ox.h) > 0.6 {
                    issues.append("\(name): box \(x) vs \(ox)")
                }
                switch s.geom {
                case .custom: freeforms += 1
                case .preset(let got, let gotAdj):
                    presets += 1
                    guard got == name else { issues.append("\(name): ours \(got)"); continue }
                    var defaults = Preset.info(name)?.defaults ?? []
                    // The legacy rounded callout has no corner adjust: PowerPoint drops it, and it comes back at its
                    // default.
                    if name == "wedgeRoundRectCallout", adj.count > 2 { defaults[2] = adj[2] }
                    let n = max(adj.count, defaults.count)
                    let a = (0 ..< n).map { adj.indices.contains($0) ? adj[$0] : defaults[$0] }
                    var b = (0 ..< n).map { gotAdj.indices.contains($0) ? gotAdj[$0] : defaults.indices.contains($0) ? defaults[$0] : 0 }
                    if name == "wedgeRoundRectCallout", b.count > 2 { b[2] = a[2] }
                    // A legacy unit is 100,000 / 21,600 of DrawingML's, more where the box isn't square.
                    if zip(a, b).contains(where: { abs($0 - $1) > 20 }) { issues.append("\(name) \(Int(ox.w))×\(Int(ox.h)): want \(a), ours \(b)") }
                }
            }
        }
        #expect(issues.isEmpty, Comment(rawValue: issues.prefix(30).joined(separator: "\n")))
        #expect(presets >= 300 && freeforms >= 150, "\(presets) presets, \(freeforms) freeforms")
    }

    /// LibreOffice's save of the same deck: every preset it keeps comes back by name and box (its adjust values follow
    /// DrawingML's meaning rather than PowerPoint's, so they aren't compared).
    @Test func libreOfficesPresetsComeBackByName() throws {
        let legacy = PPTFileTests.legacy
        let file = legacy.appending(path: "ppt/presets.ppt"), original = legacy.appending(path: "pptx/presets.pptx")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let (ours, _) = try PPT.importChecked(Array(try Data(contentsOf: file)))
        let (want, _) = try PPTX.importChecked(Array(try Data(contentsOf: original)))
        var same = 0
        var issues: [String] = []
        for (slide, orig) in zip(ours.slides, want.slides).dropFirst() {
            guard slide.shapes.count == orig.shapes.count else { issues.append("count \(slide.shapes.count) vs \(orig.shapes.count)"); continue }
            for (s, o) in zip(slide.shapes, orig.shapes) {
                guard case .preset(let name, _) = o.geom, var x = s.xfrm, let ox = o.xfrm else { continue }
                // LibreOffice turns some connectors a quarter turn and swaps their box: compare the box as drawn.
                if (45 ..< 135).contains(x.rot) || (225 ..< 315).contains(x.rot) {
                    (x.x, x.y, x.w, x.h) = (x.x + (x.w - x.h) / 2, x.y + (x.h - x.w) / 2, x.h, x.w)
                }
                if abs(x.x - ox.x) > 0.6 || abs(x.y - ox.y) > 0.6 || abs(x.w - ox.w) > 0.6 || abs(x.h - ox.h) > 0.6 {
                    issues.append("\(name): box \(x) vs \(ox)")
                }
                if case .preset(let got, _) = s.geom {
                    // It writes a one-bend elbow as a two-bend one, and presets it has no shape type for as rectangles.
                    let alias = name == "bentConnector2" && got == "bentConnector3"
                    if got == name { same += 1 } else if !(alias || got == "rect") { issues.append("\(name): ours \(got)") }
                }
            }
        }
        #expect(issues.isEmpty, Comment(rawValue: issues.prefix(30).joined(separator: "\n")))
        #expect(same >= 150)
    }

    /// Property data a file can lie about: complex lengths past the record, arrays claiming more elements than they
    /// hold, segment lists that run past their vertices. Nothing traps, and what can be read is.
    @Test func hostilePropertyDataIsBounded() {
        // pVertices claiming 60,000 two-int16 points with three present, and pSegmentInfo claiming 0x1FFF lines.
        var vertices: [UInt8] = [0x60, 0xEA, 0x60, 0xEA, 4, 0]
        for (x, y) in [(0, 0), (100, 0), (100, 100)] as [(Int16, Int16)] {
            vertices += [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: y), UInt8(truncatingIfNeeded: y >> 8)]
        }
        let segments: [UInt8] = [3, 0, 3, 0, 2, 0, 0x00, 0x40, 0xFF, 0x1F, 0x01, 0x60]
        var b: [UInt8] = []
        var d = DrawnShape(id: 1, type: 0, flags: 0)
        d.complex[0x0145] = b.count ..< b.count + vertices.count
        b += vertices
        d.complex[0x0146] = b.count ..< b.count + segments.count
        b += segments
        d.props[0x0142] = 100
        d.props[0x0143] = 100
        let pr = ShapeProps(b, d, defaults: [:], scheme: [], linked: false)
        guard case .custom(let paths)? = Freeform.geometry(pr) else { Issue.record("no freeform"); return }
        #expect(paths.count == 1)
        #expect(paths.first?.d.hasPrefix("M 0 0 L 100 0 L 100 100") == true)

        // A complex property whose length runs past its record is dropped, not read past the end.
        var rec: [UInt8] = [0x23, 0x00, 0x0B, 0xF0]   // OfficeArtFOPT, version 3, instance 2
        let body: [UInt8] = [0x45, 0x81, 0xFF, 0xFF, 0x00, 0x00,   // pVertices, complex, 65,535 bytes
                             0x81, 0x01, 0x00, 0x00, 0xFF, 0x00]   // fillColor
        rec += [UInt8(body.count), 0, 0, 0] + body
        var sp: [UInt8] = [0x0F, 0x00, 0x04, 0xF0, UInt8(rec.count), 0, 0, 0]
        sp += rec
        if let r = Record(sp, at: 0) {
            let s = Drawing.shape(sp, r, transform: nil)
            #expect(s.complex[0x0145] == nil)
            #expect(s.props[0x0181] == 0xFF0000)
        } else {
            Issue.record("no record")
        }

        // A table whose cells all overlap and whose lines run anywhere: a grid, no trap.
        var g = DrawnShape(id: 10, type: 0, flags: 0x201)
        g.props[0x039F] = 1
        g.rect = (0, 0, 800, 800)
        for k in 0 ..< 50 {
            var c = DrawnShape(id: UInt32(11 + k), type: 1, flags: 0xA02)
            c.rect = (Double(10 * k), Double(10 * k), 800, 800)
            g.children.append(c)
        }
        var l = DrawnShape(id: 99, type: 20, flags: 0xA02)
        l.rect = (-1e9, 5, 2e9, 0)
        g.children.append(l)
        var p = Presentation.default
        var builder = ShapeBuilder(b: [], outline: [], ctx: TextContext(fonts: [], scheme: [], styles: MasterStyles()),
                                   hyperlinks: [:], defaults: [:], masterShapes: [:], linked: false)
        let built = builder.build(&p, [g], rules: [])
        // 50 starts and 50 ends each way: 99 rows and columns.
        if case .table(let t)? = built.first?.kind { #expect(t.nRows == 99 && t.nCols == 99) } else { Issue.record("no table") }

        // Every legacy shape type, at odd sizes and adjusts, gives some geometry without trapping.
        for t in UInt16(0) ... 202 {
            for (w, h) in [(0.0, 0.0), (1.0, 1e9), (-5.0, 3.0)] {
                _ = LegacyShapes.geometry(t, [1: .min, 2: .max, 3: 0, 8: -1], w: w, h: h)
            }
        }
    }
}
