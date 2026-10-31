// DCPPT — a drawing's shapes as DCModel shapes (P3): autoshapes with their preset or freeform geometry, fill, line,
// shadow and text frame; groups, kept as groups; connectors joined to the shapes their rules name; tables (a group
// flagged as one, its cells rectangles and its borders lines); and WordArt (a text-effect shape's string, drawn with
// the shape's fill and line). P4 adds pictures (a picture shape's picture with its crop and corrections), OLE objects
// (their preview, as an `opaque` shape) and movies and sounds (their file, with the shape's picture as the poster).
import DCColor
import DCCore
import DCGeometry
import DCModel

struct ShapeBuilder {
    let b: [UInt8]
    /// The slide list's outline text, which placeholders' OutlineTextRefAtoms point at.
    let outline: [PPTText]
    let ctx: TextContext
    let hyperlinks: [UInt32: Hyperlink]
    /// The drawing group's default properties.
    let defaults: [UInt16: UInt32]
    /// The masters' shapes' properties, for a shape that names one in hspMaster.
    let masterShapes: [UInt32: [UInt16: UInt32]]
    /// Scheme colours stay theme colours (the slide uses its master's).
    let linked: Bool
    /// The pictures' media and the pattern bitmaps' presets.
    var pictures = PictureRefs()
    /// The document's OLE objects, movies and sounds, with the media of those already added.
    var objects = ExObjects()
    /// Each drawn shape's id (its spid) as a DCModel id, given before any shape is built so connectors can name shapes
    /// that come after them.
    var ids: [UInt32: ShapeId] = [:]
    var rules: [UInt32: ConnectorRule] = [:]
    /// Outline text index → where the OutlineTextRefAtom that shows it is (unique, where a shape id may not be).
    var outlineOwner: [Int: Int] = [:]

    static let scale = PPT.pointsPerMasterUnit

    /// The slide's shapes, in z-order.
    mutating func build(_ p: inout Presentation, _ drawn: [DrawnShape], rules: [ConnectorRule]) -> [Shape] {
        for r in rules { self.rules[r.connector] = r }
        // Each outline text goes to the first placeholder that names it, as PowerPoint writes them: a drawing naming
        // one many times would otherwise copy it into each.
        func own(_ list: [DrawnShape]) {
            for d in list {
                if let ref = d.textbox.first(where: { $0.type == RT.outlineTextRefAtom }), ref.body.count >= 4 {
                    let i = Int(i32(b, ref.body.lowerBound))
                    if outlineOwner[i] == nil { outlineOwner[i] = ref.body.lowerBound }
                }
                own(d.children)
            }
        }
        own(drawn)
        func number(_ list: [DrawnShape]) {
            for d in list where ids[d.id] == nil {
                if let raw = p.allocId() { ids[d.id] = ShapeId(raw) }
                number(d.children)
            }
        }
        number(drawn)
        return drawn.compactMap { shape($0) }
    }

    func props(_ d: DrawnShape) -> ShapeProps {
        ShapeProps(b, d, defaults: defaults, master: d.props[0x0301].flatMap { masterShapes[$0] }, scheme: ctx.scheme, linked: linked,
                   pictures: pictures)
    }

    /// Whether a drawn shape is a picture: a picture frame, an OLE object, or a shape with a picture of its own and no
    /// outline of its own (a text box's picture is its fill's).
    static func isPicture(_ d: DrawnShape) -> Bool {
        d.type == 75 || d.isOLE || (d.props[0x0104] != nil && d.props[0x0145] == nil && !d.isGroup && d.type != 202)
    }

    /// The external object (OLE object, movie or sound) a shape shows, by its ExObjRefAtom.
    func exObject(_ d: DrawnShape) -> UInt32? {
        d.clientData.first { $0.type == RT.exObjRefAtom && $0.body.count >= 4 }.map { le32(b, $0.body.lowerBound) }
    }

    func shape(_ d: DrawnShape) -> Shape? {
        guard let id = ids[d.id], let box = d.rect else { return nil }
        let pr = props(d)
        var s = Shape.default
        s.id = id
        s.xfrm = xfrm(box, pr)
        let w = s.xfrm?.w ?? 0, h = s.xfrm?.h ?? 0
        s.hidden = pr.flag(0x03BF, 1, false)
        s.descr = pr.string(0x0381) ?? ""
        s.click = action(d, instance: 0)
        s.hover = action(d, instance: 1)

        if d.isGroup {
            let kids = d.children.compactMap { shape($0) }
            let space = d.space ?? (0, 0, max(1, box.w), max(1, box.h))
            if pr.flag(0x039F, 0, false) || (d.props[0x039F].map { $0 & 1 != 0 } ?? false),
               let table = TableBuilder(builder: self).table(d, space: space, size: (w, h)) {
                s.kind = .table(table)
                s.name = pr.string(0x0380) ?? "Table \(id.rawValue)"
                return s
            }
            s.kind = .group(children: kids, child: Xfrm(x: space.x * Self.scale, y: space.y * Self.scale,
                                                        w: space.w * Self.scale, h: space.h * Self.scale))
            s.name = pr.string(0x0380) ?? "Group \(id.rawValue)"
            return s
        }

        if Self.isPicture(d) { return picture(d, pr, s, w: w, h: h) }

        s.geom = geometry(d, pr, w: w, h: h)
        let lineLike: Bool = if case .preset(let name, _) = s.geom { Preset.isLineLike(name) } else { false }
        s.fill = lineLike ? nil : pr.fill
        s.line = pr.line
        s.effects = pr.effects
        if (32 ... 40).contains(d.type) || d.isConnector {
            let r = rules[d.id]
            func end(_ spid: UInt32?, _ site: UInt32?) -> Pair<ShapeId, UInt32>? {
                guard let spid, spid != 0, let target = ids[spid] else { return nil }
                return Pair(target, site ?? 0)
            }
            s.kind = .connector(start: end(r?.start, r?.startSite), end: end(r?.end, r?.endSite))
        }

        // Text: the shape's own records, a placeholder's outline text, or WordArt's string.
        var text = PPTText.bodies(b, d.textbox).first
        if text == nil, let ref = d.textbox.first(where: { $0.type == RT.outlineTextRefAtom }), ref.body.count >= 4 {
            let i = Int(i32(b, ref.body.lowerBound))
            if outline.indices.contains(i), outlineOwner[i] == ref.body.lowerBound { text = outline[i] }
        }
        let kind = d.placeholder.flatMap { PPT.placeholderKind($0.type) }
        if let kind, let ph = d.placeholder {
            s.ph = Placeholder(kind: kind.type, idx: ph.position > 0 ? UInt32(ph.position) : 0, vertical: kind.vertical)
            s.name = "\(kind.type.rawValue.prefix(1).uppercased())\(kind.type.rawValue.dropFirst()) Placeholder \(id.rawValue)"
        } else {
            s.textBox = d.type == 202
            s.name = d.type == 202 ? "TextBox \(id.rawValue)" : "Shape \(id.rawValue)"
        }
        if let name = pr.string(0x0380) { s.name = name }
        if let warp = LegacyShapes.warp(d.type), let word = pr.string(0x00C0) {
            s.text = wordArt(word, warp: warp, pr, fill: s.fill, line: s.line)
            s.fill = Fill.none_
            s.line = Line(fill: Fill.none_)
            return s
        }
        if let text, !text.chars.isEmpty || kind != nil {
            var body = text.body(ctx, hyperlinks: hyperlinks)
            // Center title, center body, half and quarter body: their differences from title and body, on the shape.
            if MasterStyles.baseType(text.type) != nil { body.listStyle = ctx.styles.listStyle(text.type, own: true, ctx) }
            body.body = pr.frame(body.body)
            s.text = body
        } else if kind != nil {
            var body = TextBody()
            body.body = pr.frame(body.body)
            s.text = body
        }
        return s
    }

    /// A picture shape: a picture, an OLE object's preview, or a movie or sound with its picture as the poster. A picture
    /// whose picture couldn't be read keeps its place as an empty frame.
    func picture(_ d: DrawnShape, _ pr: ShapeProps, _ shape: Shape, w: Double, h: Double) -> Shape {
        var s = shape
        s.geom = d.type == 75 ? .preset("rect") : geometry(d, pr, w: w, h: h)
        // A picture is drawn without a fill unless it sets one, and with the outline it sets.
        s.fill = pr.sets(0x01BF, 0x0180, 0x0181) ? pr.fill : nil
        s.line = pr.sets(0x01FF, 0x01C0, 0x01CB) ? pr.line : nil
        s.effects = pr.effects
        let fill = pr.picture
        let n = s.id.rawValue
        if let ref = exObject(d), let o = objects.objects[ref] {
            switch o.kind {
            case .ole(let label):
                s.kind = .opaque(xml: "", preview: fill?.media, label: label, parts: [])
                s.name = "Object \(n)"
            case .video, .audio, .embeddedSound:
                if let m = objects.media[ref] {
                    var video = false
                    if case .video = o.kind { video = true }
                    s.kind = .media(MediaClip(media: m, video: video, poster: fill?.media, volume: 1, loopPlay: o.loop, rewind: o.rewind))
                    s.name = "\(video ? "Movie" : "Sound") \(n)"
                } else if let fill {
                    s.kind = .picture(fill: fill)
                    s.name = "Picture \(n)"
                }
            }
        } else if d.isOLE {
            s.kind = .opaque(xml: "", preview: fill?.media, label: "Object", parts: [])
            s.name = "Object \(n)"
        } else if let fill {
            s.kind = .picture(fill: fill)
            s.name = "Picture \(n)"
        } else {
            s.name = "Picture \(n)"
            s.fill = s.fill ?? Fill.none_
        }
        if let name = pr.string(0x0380) { s.name = name }
        return s
    }

    /// The shape's box in points (in its group's space for a child) with its rotation and flips. A shape turned
    /// 45° to 135° (or 225° to 315°) is stored with its box turned with it: its width and height swap about its
    /// centre. With one flip, the stored rotation runs the other way.
    func xfrm(_ r: (x: Double, y: Double, w: Double, h: Double), _ pr: ShapeProps) -> Xfrm {
        var rot = (pr.fixed(0x0004) ?? 0).truncatingRemainder(dividingBy: 360)
        if rot < 0 { rot += 360 }
        var x = r.x, y = r.y, w = max(0, r.w), h = max(0, r.h)
        if (45 ..< 135).contains(rot) || (225 ..< 315).contains(rot) {
            let cx = x + w / 2, cy = y + h / 2
            (w, h) = (h, w)
            x = cx - w / 2
            y = cy - h / 2
        }
        if pr.shape.flipH != pr.shape.flipV, rot != 0 { rot = 360 - rot }
        return Xfrm(x: x * Self.scale, y: y * Self.scale, w: w * Self.scale, h: h * Self.scale, rot: rot,
                    flipH: pr.shape.flipH, flipV: pr.shape.flipV)
    }

    /// The geometry: a freeform's own path, else the shape type's preset.
    func geometry(_ d: DrawnShape, _ pr: ShapeProps, w: Double, h: Double) -> Geom {
        if let custom = Freeform.geometry(pr) { return custom }
        var adj: [Int: Int32] = [:]
        for i in 0 ..< 10 { if let v = pr.int(0x0147 + UInt16(i)), d.props[0x0147 + UInt16(i)] != nil { adj[i + 1] = v } }
        return LegacyShapes.geometry(d.type, adj, w: w, h: h)
    }

    /// The shape's mouse-click (instance 0) or mouse-over (instance 1) hyperlink, from its InteractiveInfoAtom.
    func action(_ d: DrawnShape, instance: UInt16) -> Hyperlink? {
        guard let info = d.clientData.first(where: { $0.type == RT.interactiveInfo && $0.instance == instance }),
              let atom = info.children(b).first(where: { $0.type == RT.interactiveInfoAtom }), atom.body.count >= 16
        else { return nil }
        return hyperlinks[le32(b, atom.body.lowerBound + 4)]
    }

    /// WordArt: the string in the shape's font and size, filled and outlined as the shape is, warped by its type.
    func wordArt(_ word: String, warp: String, _ pr: ShapeProps, fill: Fill?, line: Line?) -> TextBody {
        var body = TextBody.fromText(word.replacingOccurrences(of: "\r", with: "\n"))
        body.body.warp = warp
        body.body.wrap = false
        body.body.autofit = AutoFit.none_
        let bold = pr.flag(0x00FF, 5, false), italic = pr.flag(0x00FF, 4, false)
        for i in body.paragraphs.indices {
            body.paragraphs[i].props.align = .center
            for j in body.paragraphs[i].runs.indices {
                var r = body.paragraphs[i].runs[j].props
                r.font = pr.string(0x00C5)
                r.size = pr.fixed(0x00C3).map { min(max($0, 1), 4000) } ?? 36
                if bold { r.bold = true }
                if italic { r.italic = true }
                r.fill = fill
                r.outline = line
                body.paragraphs[i].runs[j].props = r
            }
        }
        return body
    }
}

/// A freeform's path ([MS-ODRAW] 2.3.6): pVertices in the geoLeft…geoBottom space, walked by pSegmentInfo.
enum Freeform {
    /// At most this many path commands, however many segments a file claims.
    static let maxCommands = 100_000

    static func geometry(_ pr: ShapeProps) -> Geom? {
        guard let v = pr.array(0x0145), !v.elements.isEmpty else { return nil }
        let b = pr.b
        let points: [(Double, Double)] = v.elements.map { e in
            v.size >= 8 ? (Double(i32(b, e.lowerBound)), Double(i32(b, e.lowerBound + 4)))
                : (Double(Int16(bitPattern: le16(b, e.lowerBound))), Double(Int16(bitPattern: le16(b, e.lowerBound + 2))))
        }
        var left = Double(pr.int(0x0140) ?? 0), top = Double(pr.int(0x0141) ?? 0)
        var w = Double(pr.int(0x0142) ?? 21600) - left, h = Double(pr.int(0x0143) ?? 21600) - top
        if w <= 0 || h <= 0 {
            // No coordinate space (LibreOffice writes geoRight and geoBottom as 0): the vertices' own extent.
            let xs = points.map(\.0), ys = points.map(\.1)
            left = xs.min() ?? 0
            top = ys.min() ?? 0
            w = (xs.max() ?? 0) - left
            h = (ys.max() ?? 0) - top
        }
        // A path with no extent stays a (degenerate) freeform rather than becoming a rectangle.
        guard w.isFinite, h.isFinite else { return nil }
        w = max(w, 1)
        h = max(h, 1)
        let segments: [UInt16] = pr.array(0x0146).map { a in a.elements.map { le16(b, $0.lowerBound) } } ?? []

        var paths: [CustomPath] = []
        var d = "", fill = FillMode.norm, stroke = true, i = 0, commands = 0
        func pt() -> String? {
            guard i < points.count else { return nil }
            defer { i += 1 }
            return "\(fmt(points[i].0 - left)) \(fmt(points[i].1 - top))"
        }
        func finish() {
            if !d.isEmpty { paths.append(CustomPath(w: max(w, 1), h: max(h, 1), d: d, fill: fill, stroke: stroke)) }
            d = ""
            fill = .norm
            stroke = true
        }
        if segments.isEmpty {
            // No segment list: one polyline through every vertex, closed if shapePath says so.
            for k in points.indices { if let p = pt() { d += (k == 0 ? "M " : " L ") + p } }
            if [1, 3].contains(pr.value(0x0144) ?? 1) { d += " Z" }
            finish()
            return paths.isEmpty ? nil : .custom(paths: paths)
        }
        for seg in segments {
            guard commands < maxCommands else { break }
            let type = seg >> 13, count = Int(seg & 0x1FFF)
            switch type {
            // Each loop stops when the vertices run out, whatever count a segment claims.
            case 0:   // lineTo
                for _ in 0 ..< max(count, 1) {
                    guard let p = pt() else { break }
                    d += (d.isEmpty ? "M " : " L ") + p
                    commands += 1
                }
            case 1:   // curveTo: three points each
                for _ in 0 ..< max(count, 1) {
                    guard let p1 = pt(), let p2 = pt(), let p3 = pt() else { break }
                    d += d.isEmpty ? "M \(p3)" : " C \(p1) \(p2) \(p3)"
                    commands += 1
                }
            case 2:   // moveTo
                // A new subpath of the same path (so a ring's hole stays a hole); `end` closes the path.
                if let p = pt() { d += (d.isEmpty ? "M " : " M ") + p; commands += 1 }
            case 3: if !d.isEmpty { d += " Z" }
            case 4: finish()
            case 5, 6:
                // Escapes: segment count in the low byte, the escape in the 5 bits above it.
                let escape = Int(seg >> 8 & 0x1F), n = Int(seg & 0xFF)
                switch escape {
                case 0xA: fill = .none
                case 0xB: stroke = false
                case 0x7, 0x8:   // elliptical quadrants: a quarter ellipse to each point, starting along x (or y)
                    var alongX = escape == 0x7
                    for _ in 0 ..< max(n, 1) {
                        guard let p = pt() else { break }
                        if d.isEmpty { d = "M " + p } else { d += quadrant(from: d, to: p, alongX: alongX) }
                        alongX.toggle()
                        commands += 1
                    }
                case 0x9:   // quadratic Béziers: a control point and an end point each
                    for _ in 0 ..< max(n, 1) {
                        guard let c = pt(), let p = pt() else { break }
                        d += d.isEmpty ? "M \(p)" : " Q \(c) \(p)"
                        commands += 1
                    }
                case 0x1, 0x2: i = min(points.count, i + 3 * max(n, 1))   // angle ellipses: centre, size, angles; skipped
                case 0x3 ... 0x6:   // arcs: a bounding box's corners, then the start and end points
                    for _ in 0 ..< max(n, 1) {
                        i = min(points.count, i + 2)
                        guard let s = pt(), let e = pt() else { break }
                        d += d.isEmpty ? "M \(s) L \(e)" : " L \(s) L \(e)"
                        commands += 1
                    }
                default: continue
                }
            default: continue
            }
        }
        finish()
        return paths.isEmpty ? nil : .custom(paths: paths)
    }

    /// A quarter ellipse from the path's last point to `to`, leaving along x (or y) first.
    static func quadrant(from d: String, to: String, alongX: Bool) -> String {
        let last = d.split(separator: " ").suffix(2).compactMap { Double($0) }
        let end = to.split(separator: " ").compactMap { Double($0) }
        guard last.count == 2, end.count == 2 else { return " L \(to)" }
        let k = 0.5523
        let (x0, y0, x1, y1) = (last[0], last[1], end[0], end[1])
        let c1 = alongX ? (x0 + (x1 - x0) * k, y0) : (x0, y0 + (y1 - y0) * k)
        let c2 = alongX ? (x1, y1 - (y1 - y0) * k) : (x1 - (x1 - x0) * k, y1)
        return " C \(fmt(c1.0)) \(fmt(c1.1)) \(fmt(c2.0)) \(fmt(c2.1)) \(to)"
    }

    static func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }
}

/// A table: a group flagged as one, whose rectangles are its cells and whose lines are its borders. The grid comes
/// from the cells' edges, so merged cells span the columns and rows they cover.
struct TableBuilder {
    let builder: ShapeBuilder
    static let tolerance = 2.0
    static let maxCells = 10_000

    func table(_ g: DrawnShape, space: (x: Double, y: Double, w: Double, h: Double), size: (w: Double, h: Double)) -> Table? {
        let cells = g.children.filter { $0.type != 20 && !$0.isGroup && $0.rect != nil }
        let lines = g.children.filter { $0.type == 20 && $0.rect != nil }.prefix(Self.maxCells)
        // A table larger than this stays a group.
        guard !cells.isEmpty, cells.count <= Self.maxCells, space.w > 0, space.h > 0 else { return nil }
        func edges(_ values: [Double]) -> [Double] {
            var out: [Double] = []
            for v in values.sorted() where out.last.map({ v - $0 > Self.tolerance }) ?? true { out.append(v) }
            return out
        }
        let xs = edges(cells.flatMap { c in c.rect.map { [$0.x, $0.x + $0.w] } ?? [] })
        let ys = edges(cells.flatMap { c in c.rect.map { [$0.y, $0.y + $0.h] } ?? [] })
        guard xs.count >= 2, ys.count >= 2, (xs.count - 1) * (ys.count - 1) <= Self.maxCells else { return nil }
        func index(_ v: Double, _ list: [Double]) -> Int {
            list.indices.min { abs(list[$0] - v) < abs(list[$1] - v) } ?? 0
        }
        // Points per unit of the group's space.
        let sx = size.w / space.w, sy = size.h / space.h
        var t = Table.default
        t.style = "none"
        t.firstRow = false
        t.bandRow = false
        t.cols = zip(xs, xs.dropFirst()).map { ($1 - $0) * sx }
        t.rows = zip(ys, ys.dropFirst()).map { Row(height: ($1 - $0) * sy, cells: Array(repeating: Cell(""), count: xs.count - 1)) }
        var spans: [(r: Int, c: Int, rows: Int, cols: Int)] = []
        for c in cells {
            guard let r = c.rect else { continue }
            let c0 = index(r.x, xs), c1 = index(r.x + r.w, xs), r0 = index(r.y, ys), r1 = index(r.y + r.h, ys)
            guard c1 > c0, r1 > r0, t.rows.indices.contains(r0), t.rows[r0].cells.indices.contains(c0) else { continue }
            let pr = builder.props(c)
            var cell = Cell("")
            if let shape = builder.shape(c), let text = shape.text { cell.text = text }
            cell.fill = pr.fill
            cell.margins = [pr.points(0x0081) ?? 7.2, pr.points(0x0083) ?? 7.2, pr.points(0x0082) ?? 3.6, pr.points(0x0084) ?? 3.6]
            cell.anchor = pr.frame(BodyProps()).anchor
            cell.gridSpan = UInt32(c1 - c0)
            cell.rowSpan = UInt32(r1 - r0)
            t.rows[r0].cells[c0] = cell
            spans.append((r0, c0, r1 - r0, c1 - c0))
        }
        // Merged cells' covered cells; overlapping cells in a damaged file can't make this more than a few passes.
        var budget = 4 * Self.maxCells
        for s in spans {
            budget -= s.rows * s.cols
            guard budget >= 0 else { break }
            for r in s.r ..< s.r + s.rows {
                for c in s.c ..< s.c + s.cols where (r, c) != (s.r, s.c) {
                    guard t.rows.indices.contains(r), t.rows[r].cells.indices.contains(c) else { continue }
                    t.rows[r].cells[c].hMerge = c > s.c
                    t.rows[r].cells[c].vMerge = r > s.r
                }
            }
        }
        // Borders: each line along a grid edge, on the cells either side of it. Left, right, top, bottom.
        for l in lines {
            guard let r = l.rect else { continue }
            let pr = builder.props(l)
            let line = pr.line
            if abs(r.h) <= Self.tolerance {
                let row = index(r.y, ys), a = index(r.x, xs), b = index(r.x + r.w, xs)
                for c in min(a, b) ..< max(a, b) {
                    if row > 0 { set(&t, row - 1, c, 3, line) }
                    if row < t.rows.count { set(&t, row, c, 2, line) }
                }
            } else if abs(r.w) <= Self.tolerance {
                let col = index(r.x, xs), a = index(r.y, ys), b = index(r.y + r.h, ys)
                for row in min(a, b) ..< max(a, b) {
                    if col > 0 { set(&t, row, col - 1, 1, line) }
                    if col < t.cols.count { set(&t, row, col, 0, line) }
                }
            }
        }
        return t
    }

    func set(_ t: inout Table, _ r: Int, _ c: Int, _ side: Int, _ line: Line?) {
        guard t.rows.indices.contains(r), t.rows[r].cells.indices.contains(c) else { return }
        if t.rows[r].cells[c].borders.count < 4 { t.rows[r].cells[c].borders = Array(repeating: nil, count: 4) }
        t.rows[r].cells[c].borders[side] = line
    }
}
