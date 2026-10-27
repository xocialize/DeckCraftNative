// DCEngine — connectors glued to shapes: connection sites, snapping line ends to them, and rerouting
// attached connectors whenever the shapes they connect move, resize or rotate.
// Port of deckcraft crates/engine/src/connect.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum Connect {
    /// Connection sites of `s` in slide coordinates (index = site index stored on connectors).
    public static func sites(_ doc: Presentation, _ sel: Selection, _ s: Shape) -> [Point] {
        if s.isLine { return [] }
        switch s.kind {
        case .group, .ink: return []
        default: break
        }
        let x = Cmd.xfrmOf(doc, sel, s)
        var local = shapeGeometry(s, x.w, x.h).sites
        if local.isEmpty {
            local = [Point(x.w / 2, 0), Point(0, x.h / 2), Point(x.w / 2, x.h), Point(x.w, x.h / 2)]
        }
        let a = x.affine
        return local.map { a * $0 }
    }

    /// The nearest connection site within `radius` of `p` on any visible shape except `exclude`.
    public static func nearestSite(_ doc: Presentation, _ sel: Selection, _ shapes: [Shape], _ p: Point, _ radius: Double, _ exclude: ShapeId?) -> (ShapeId, UInt32, Point)? {
        var best: (Double, ShapeId, UInt32, Point)?
        for s in shapes where s.id != exclude && !s.hidden {
            for (i, q) in sites(doc, sel, s).enumerated() {
                let d = (q - p).hypot
                if d <= radius, best.map({ d < $0.0 }) ?? true {
                    best = (d, s.id, UInt32(truncatingIfNeeded: i), q)
                }
            }
        }
        return best.map { ($0.1, $0.2, $0.3) }
    }

    /// The shape whose sites should show while drawing or dragging a connector end near `p`.
    public static func siteShapeAt(_ doc: Presentation, _ sel: Selection, _ shapes: [Shape], _ p: Point, _ margin: Double, _ exclude: ShapeId?) -> ShapeId? {
        shapes.reversed().first { s in
            if s.id == exclude || s.hidden || s.isLine { return false }
            if case .ink = s.kind { return false }
            return Cmd.xfrmOf(doc, sel, s).bounds.inflate(margin, margin).contains(p)
        }?.id
    }

    /// Line endpoints (start, end) of a line-like shape's box.
    public static func endpoints(_ x: Xfrm) -> (Point, Point) {
        let a = x.affine
        return (a * Point(0, 0), a * Point(x.w, x.h))
    }

    /// Move the ends of connectors glued to shapes on the edited slide to the current site positions.
    /// Connections to shapes that no longer exist are dropped.
    public static func reroute(_ doc: inout Presentation, _ sel: Selection) {
        guard let list = treeShapes(doc, sel) else { return }
        let glued = list.contains { s in
            if case .connector(let a, let b) = s.kind { return a != nil || b != nil }
            return false
        }
        if !glued { return }
        let snapshot = list
        let view = doc
        func site(_ id: ShapeId, _ idx: UInt32) -> Point? {
            guard let s = snapshot.first(where: { $0.id == id }) else { return nil }
            let v = sites(view, sel, s)
            return v.at(Int(idx)) ?? v.first
        }
        var updates: [(Int, Xfrm, Bool, Bool)] = []
        for (i, s) in snapshot.enumerated() {
            guard case .connector(let start, let end) = s.kind else { continue }
            if start == nil && end == nil { continue }
            let x = Cmd.xfrmOf(view, sel, s)
            var (p0, p1) = endpoints(x)
            let a = start.flatMap { site($0.a, $0.b) }
            let b = end.flatMap { site($0.a, $0.b) }
            if let q = a { p0 = q }
            if let q = b { p1 = q }
            let nx = Tools.lineXfrm(p0, p1, x.rot)
            let changed = abs(nx.x - x.x) > 1e-6 || abs(nx.y - x.y) > 1e-6 || abs(nx.w - x.w) > 1e-6 || abs(nx.h - x.h) > 1e-6
                || nx.flipH != x.flipH || nx.flipV != x.flipV
            let dropA = start != nil && a == nil
            let dropB = end != nil && b == nil
            if changed || dropA || dropB { updates.append((i, nx, dropA, dropB)) }
        }
        mutateShapes(&doc, sel) { list in
            for (i, nx, dropA, dropB) in updates where i < list.count {
                list[i].xfrm = nx
                if case .connector(var start, var end) = list[i].kind {
                    if dropA { start = nil }
                    if dropB { end = nil }
                    list[i].kind = .connector(start: start, end: end)
                }
            }
        }
    }

    /// Glue end `end` (0 = start, 1 = end) of line `id` to `to` (or unglue with nil). Plain lines become
    /// connectors when glued.
    public static func setGlue(_ list: inout [Shape], _ id: ShapeId, _ end: UInt8, _ to: Pair<ShapeId, UInt32>?) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        if case .connector = list[i].kind {} else {
            guard to != nil, case .shape = list[i].kind else { return }
            list[i].kind = .connector(start: nil, end: nil)
        }
        if case .connector(let start, let e) = list[i].kind {
            list[i].kind = end == 0 ? .connector(start: to, end: e) : .connector(start: start, end: to)
        }
    }
}
