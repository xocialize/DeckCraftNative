// DCEngine — the `merge` command module: Merge Shapes (Shape Format ▸ Insert Shapes) unions, combines,
// fragments, intersects and subtracts the outlines of the selected shapes. The result takes the formatting
// of the first selected shape, like PowerPoint.
// Port of deckcraft crates/engine/src/cmd/merge.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Divergence (PORT-STATUS "Decisions recorded"): deckcraft runs the boolean operations with `i_overlay`;
// here CoreGraphics' path booleans do (`CGPath.union` / `intersection` / `subtracting` /
// `symmetricDifference`, non-zero winding). The outlines are flattened first exactly as deckcraft flattens
// them (`presetFlatten`, tolerance 0.2 pt), so both work on the same polygons and their results cover the
// same area; the result's vertices start elsewhere and run another way round, so the path data differs.
// Holes are oriented against their outer contour, as i_overlay writes them, so non-zero fill keeps them.
import CoreGraphics
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum MergeCommands {
    /// Closed polygons (slide points) describing a filled area (non-zero winding).
    typealias Area = [[Point]]

    public static let ops: [(String, String)] = [("union", "Union"), ("combine", "Combine"), ("fragment", "Fragment"), ("intersect", "Intersect"), ("subtract", "Subtract")]

    public static func specs() -> [CommandSpec] {
        [
            .cmd("shape.merge", "Merge Shapes", ["Shape Format", "Insert Shapes", "Merge Shapes"], nil, "{op: union|combine|fragment|intersect|subtract, ids?: shapes in selection order (the first one's formatting is kept)} → {ids}", Cmd.hasTwo, merge),
        ]
    }

    /// The filled outline of `s` in slide points (curves flattened). A text box with no fill and no outline
    /// is its letters, as in PowerPoint (merging text with a picture fills the letters).
    static func areaOf(_ doc: Presentation, _ sel: Selection, _ s: Shape) -> Area {
        if let (letters, _) = lettersOf(doc, sel, s) { return letters }
        let x = Cmd.xfrmOf(doc, sel, s)
        let geo = shapeGeometry(s, x.w, x.h)
        let a = x.affine
        var out: Area = []
        for sp in geo.paths where sp.fill != .none { flatten(sp.path, a, &out) }
        return out
    }

    /// The letters of a text box with no fill and no outline, in slide points, and their colour.
    static func lettersOf(_ doc: Presentation, _ sel: Selection, _ s: Shape) -> (Area, Rgba?)? {
        guard s.kind == .shape, let t = s.text, !t.isEmpty else { return nil }
        guard let ctx = TextCommands.ctxFor(doc, sel) else { return nil }
        func none(_ f: Fill?) -> Bool { f.map(\.isNone) ?? true }
        if !none(Resolve.fill(ctx, s).fill) || !none(Resolve.line(ctx, s).line.fill) { return nil }
        let (path, colour) = textOutline(ctx, s, Cmd.xfrmOf(doc, sel, s).affine)
        var out: Area = []
        flatten(path, .identity, &out)
        return out.isEmpty ? nil : (out, colour)
    }

    /// Append the closed polygons of `path` (mapped by `a`) to `out`.
    static func flatten(_ path: BezPath, _ a: Affine, _ out: inout Area) {
        var cur: [Point] = []
        func flush() {
            if cur.count > 2 { out.append(cur) }
            cur = []
        }
        presetFlatten(path) { el in
            switch el {
            case .moveTo(let p):
                flush()
                cur.append(a * p)
            case .lineTo(let p):
                cur.append(a * p)
            case .closePath:
                flush()
            default:
                break
            }
        }
        flush()
    }

    /// Keep a picture where it was on the slide when its box becomes `to`: crop it to the new box. Only for
    /// upright, unflipped pictures stretched over their box.
    static func recrop(_ fill: inout PictureFill, _ from: Xfrm, _ to: Xfrm) {
        guard from.rot == 0, !from.flipH, !from.flipV, case .stretch(let fr) = fill.mode, fr == [0, 0, 0, 0], fill.crop.count == 4 else { return }
        let (l, t, r, b) = (fill.crop[0], fill.crop[1], fill.crop[2], fill.crop[3])
        let (fw, fh) = (1 - l - r, 1 - t - b)
        guard fw > 1e-9 && fh > 1e-9 && from.w > 0 && from.h > 0 else { return }
        // The whole image in slide points.
        let (iw, ih) = (from.w / fw, from.h / fh)
        let (ix, iy) = (from.x - l * iw, from.y - t * ih)
        let c = [(to.x - ix) / iw, (to.y - iy) / ih, (ix + iw - to.x - to.w) / iw, (iy + ih - to.y - to.h) / ih]
        if c.allSatisfy(\.isFinite) { fill.crop = c }
    }

    enum Rule {
        case union, xor, intersect, difference
    }

    /// A CGPath of `area`'s closed polygons.
    static func cgPath(_ area: Area) -> CGPath {
        let p = CGMutablePath()
        for c in area {
            guard let first = c.first else { continue }
            p.move(to: CGPoint(x: first.x, y: first.y))
            for q in c.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
            p.closeSubpath()
        }
        return p
    }

    /// The closed polygons of a CGPath. Boolean results of polygons are polygons; a curve, should one
    /// appear, is flattened as deckcraft flattens.
    static func polygons(_ path: CGPath) -> Area {
        var bez = BezPath()
        path.applyWithBlock { e in
            let el = e.pointee
            func pt(_ i: Int) -> Point { Point(Double(el.points[i].x), Double(el.points[i].y)) }
            switch el.type {
            case .moveToPoint: bez.moveTo(pt(0))
            case .addLineToPoint: bez.lineTo(pt(0))
            case .addQuadCurveToPoint: bez.quadTo(pt(0), pt(1))
            case .addCurveToPoint: bez.curveTo(pt(0), pt(1), pt(2))
            case .closeSubpath: bez.closePath()
            @unknown default: break
            }
        }
        var out: Area = []
        flatten(bez, .identity, &out)
        return out
    }

    /// Twice the signed area of a closed polygon (shoelace, as `area_size` sums it).
    static func signedArea2(_ c: [Point]) -> Double {
        let n = c.count
        var s = 0.0
        for i in 0 ..< n { s += c[i].x * c[(i + 1) % n].y - c[(i + 1) % n].x * c[i].y }
        return s
    }

    /// Even-odd point in polygon.
    static func inside(_ p: Point, _ c: [Point]) -> Bool {
        var inside = false
        var j = c.count - 1
        for i in 0 ..< c.count {
            let (a, b) = (c[i], c[j])
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Whether `p` lies within `eps` of an edge of `c`.
    static func onEdge(_ p: Point, _ c: [Point], _ eps: Double) -> Bool {
        var j = c.count - 1
        for i in 0 ..< c.count {
            if distToSegment(p, c[j], c[i]) <= eps { return true }
            j = i
        }
        return false
    }

    /// The contours of a boolean result oriented as i_overlay writes them: an outer contour (inside an even
    /// number of others) with a positive shoelace sum, a hole with a negative one, so the area's non-zero
    /// fill shows its holes and `areaSize` nets them out. Pieces of a result can touch, so each contour is
    /// probed at one of its vertices or edge midpoints that lies on no other contour.
    static func oriented(_ area: Area) -> Area {
        area.enumerated().map { k, c in
            guard !c.isEmpty else { return c }
            var candidates = c
            for i in c.indices { candidates.append(c[i].midpoint(c[(i + 1) % c.count])) }
            let others = area.enumerated().filter { $0.offset != k }.map(\.element)
            let probe = candidates.first { q in !others.contains { onEdge(q, $0, 1e-7) } } ?? c[0]
            let depth = others.filter { inside(probe, $0) }.count
            let positive = signedArea2(c) > 0
            return (depth % 2 == 0) == positive ? c : c.reversed()
        }
    }

    static func overlay(_ a: Area, _ b: Area, _ rule: Rule) -> Area {
        if a.isEmpty && (rule == .union || rule == .xor) { return b }
        if b.isEmpty { return rule == .intersect ? [] : a }
        let (pa, pb) = (cgPath(a), cgPath(b))
        let r: CGPath = switch rule {
        case .union: pa.union(pb, using: .winding)
        case .xor: pa.symmetricDifference(pb, using: .winding)
        case .intersect: pa.intersection(pb, using: .winding)
        case .difference: pa.subtracting(pb, using: .winding)
        }
        return oriented(polygons(r).filter { $0.count > 2 })
    }

    static func areaSize(_ a: Area) -> Double {
        Swift.abs(a.reduce(0.0) { $0 + signedArea2($1) / 2 })
    }

    /// The merged areas for `op` (one per resulting shape).
    static func mergeAreas(_ op: String, _ areas: [Area]) -> [Area] {
        guard let first = areas.first else { return [] }
        let rest = areas.dropFirst()
        func fold(_ rule: Rule) -> Area { rest.reduce(first) { overlay($0, $1, rule) } }
        let out: [Area]
        switch op {
        case "union": out = [fold(.union)]
        case "combine": out = [fold(.xor)]
        case "intersect": out = [fold(.intersect)]
        case "subtract":
            let others = rest.reduce(Area()) { overlay($0, $1, .union) }
            out = [overlay(first, others, .difference)]
        default:
            // Fragment: every region of the arrangement becomes its own shape.
            var pieces: [Area] = [first]
            var covered = first
            for b in rest {
                var next: [Area] = []
                for p in pieces {
                    next.append(overlay(p, b, .intersect))
                    next.append(overlay(p, b, .difference))
                }
                next.append(overlay(b, covered, .difference))
                covered = overlay(covered, b, .union)
                pieces = next
            }
            out = pieces
        }
        return out.filter { areaSize($0) > 0.01 }
    }

    /// A custom-geometry box for `area`: its bounds and path data relative to them.
    static func areaGeom(_ area: Area) -> (Xfrm, Geom)? {
        var b: Rect?
        for c in area {
            for p in c {
                let r = Rect(p.x, p.y, p.x, p.y)
                b = b.map { $0.union(r) } ?? r
            }
        }
        guard let b else { return nil }
        let (w, h) = (b.width.rustMax(0.01), b.height.rustMax(0.01))
        // `format!("{v:.2}")` with trailing zeros and the point trimmed.
        func f(_ v: Double) -> String {
            var t = Substring(rustFixed(v, places: 2))
            while t.last == "0" { t = t.dropLast() }
            while t.last == "." { t = t.dropLast() }
            return String(t)
        }
        var d = ""
        for c in area {
            for (i, p) in c.enumerated() { d += "\(i == 0 ? "M " : "L ")\(f(p.x - b.x0)) \(f(p.y - b.y0)) " }
            d += "Z "
        }
        var path = CustomPath.default
        path.w = w
        path.h = h
        path.d = String(rustTrimEnd(Substring(d)))
        return (Xfrm(b.x0, b.y0, w, h), .custom(paths: [path]))
    }

    @Sendable static func merge(_ s: Session, _ p: JSON) throws -> JSON {
        let op = rustASCIILowercase(Cmd.strParam(p, "op") ?? "union")
        if !ops.contains(where: { rustEqual($0.0, op) }) {
            throw Cmd.bad("shape.merge", "unknown op `\(op)` (union, combine, fragment, intersect, subtract)")
        }
        let ids = try Cmd.targets(s, p)
        let st = try s.doc()
        let shapes = ids.compactMap { st.shape($0) }
        func mergeable(_ x: Shape) -> Bool {
            switch x.kind {
            case .shape, .picture: !x.isLine
            default: false
            }
        }
        guard shapes.count >= 2, shapes.allSatisfy(mergeable), var template = shapes.first else {
            throw Cmd.bad("shape.merge", "select two or more shapes (not lines, groups, tables or charts)")
        }
        let areas = shapes.map { areaOf(st.doc, st.selection, $0) }
        let results = mergeAreas(op, areas)
        let templateBox = Cmd.xfrmOf(st.doc, st.selection, template)
        // Letters merged become shapes filled with the text's colour.
        let letters = lettersOf(st.doc, st.selection, template)
        if let (_, colour) = letters {
            template.fill = .solid(.rgb(colour ?? .black))
            template.line = Line(fill: .none_)
            template.textBox = false
        }
        let dropText = letters != nil || shapes.dropFirst().contains { lettersOf(st.doc, st.selection, $0) != nil }
        let templateId = template.id
        var newIds: [ShapeId] = []
        try s.edit { doc, sel in
            let at0 = (treeShapes(doc, sel) ?? []).firstIndex { $0.id == templateId }
            if treeShapes(doc, sel) == nil { throw Cmd.bad("shape.merge", "no slide") }
            var made: [Shape] = []
            for (k, area) in results.enumerated() {
                guard let (x, geom) = areaGeom(area) else { continue }
                var sh = template
                sh.id = ShapeId(0)
                sh.ph = nil
                sh.xfrm = x
                sh.geom = geom
                sh.name = "Freeform \(k + 1)"
                if case .picture(var fill) = sh.kind {
                    recrop(&fill, templateBox, x)
                    sh.kind = .picture(fill: fill)
                }
                // Text stays with the first piece only, and not at all once it became outlines.
                if k > 0 || dropText { sh.text = nil }
                made.append(sh)
            }
            for i in made.indices {
                guard let raw = doc.allocId() else { throw Cmd.bad("shape.merge", Cmd.noIdSpace) }
                made[i].id = ShapeId(raw)
                newIds.append(made[i].id)
            }
            try withShapes(&doc, sel, missing: Cmd.bad("shape.merge", "no slide")) { list in
                let at = min(at0 ?? list.count, list.count)
                list.insert(contentsOf: made, at: at)
                list.removeAll { ids.contains($0.id) }
            }
            sel.shapes = newIds
        }
        return ["ids": newIds.toJSON()]
    }
}
