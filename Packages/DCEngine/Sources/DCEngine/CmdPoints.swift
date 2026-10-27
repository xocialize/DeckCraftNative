// DCEngine — the `points` command module: Edit Points (Shape Format ▸ Edit Shape ▸ Edit Points) turns a
// shape into a freeform and moves, adds or deletes the vertices of its outline.
//
// While points are edited every custom path of the shape is kept in shape-local points (its `w`/`h` equal
// the shape's size), so a vertex's path coordinates are its offset in the shape. After each change the
// shape's box is fitted around the outline again, keeping it in place on the slide (rotation and flips
// included).
// Port of deckcraft crates/engine/src/cmd/points.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum PointsCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("shape.editPoints", "Edit Points", ["Shape Format", "Insert Shapes", "Edit Shape"], nil, "{on?: bool (default: toggle), id?} — enter or leave Edit Points for one selected shape; entering turns a preset into a freeform", Cmd.hasSelection, editPoints),
            .query("shape.points", "Points", [], nil, "{id?} → {id, paths: [[[x, y] slide pt]], types: [[smooth|straight|corner]], segments: [[straight|curved|null]]} vertices of a freeform and the segment ending at each", Cmd.hasSelection, points),
            .cmd("shape.movePoint", "Move Point", [], nil, "{path?: 0, index, x, y: slide pt, id?}", Cmd.hasSelection, movePoint),
            .cmd("shape.addPoint", "Add Point", [], nil, "{path?: 0, segment: index of the vertex ending it, t?: 0..1 (0.5), id?}", Cmd.hasSelection, addPoint),
            .cmd("shape.pointType", "Point Type", [], nil, "{path?: 0, index, type: smooth|straight|corner, id?} — smooth: handles in line and equal; straight: in line; corner: independent", Cmd.hasSelection, pointType),
            .cmd("shape.moveHandle", "Move Handle", [], nil, "{path?: 0, index, side: in|out, x, y: slide pt, type?: smooth|straight|corner (default: read from the handles), id?}", Cmd.hasSelection, moveHandle),
            .cmd("shape.deletePoint", "Delete Point", [], nil, "{path?: 0, index, id?}", Cmd.hasSelection, deletePoint),
            .cmd("shape.deleteSegment", "Delete Segment", [], nil, "{path?: 0, segment: index of the vertex ending it, id?}: removes a segment of a closed outline, which opens there; it starts at the segment's end and ends at its start", Cmd.hasSelection, deleteSegment),
            .cmd("shape.segmentType", "Segment Type", [], nil, "{path?: 0, segment: index of the vertex ending it, type: straight|curved, id?} — straight drops the segment's handles; curved gives it handles at its thirds", Cmd.hasSelection, segmentType),
            .cmd("shape.openPath", "Open Path", [], nil, "{path?: 0, index, id?} — break a closed outline at a point, which becomes its two ends", Cmd.hasSelection, openPath),
            .cmd("shape.closePath", "Close Path", [], nil, "{path?: 0, index: any point of the open outline, id?} — join its ends with a straight segment (one point when they meet)", Cmd.hasSelection, closePath),
        ]
    }

    /// One path command, in path units.
    public enum Seg: Sendable, Equatable {
        case m(Point)
        case l(Point)
        case c(Point, Point, Point)
        case q(Point, Point)
        case z

        public var end: Point? {
            switch self {
            case .m(let p), .l(let p), .c(_, _, let p), .q(_, let p): p
            case .z: nil
            }
        }

        var isMove: Bool {
            if case .m = self { return true }
            return false
        }

        var isClose: Bool { self == .z }

        var isCubic: Bool {
            if case .c = self { return true }
            return false
        }

        /// The points of the command, in order (`points_mut`).
        var points: [Point] {
            switch self {
            case .m(let p), .l(let p): [p]
            case .c(let a, let b, let p): [a, b, p]
            case .q(let a, let p): [a, p]
            case .z: []
            }
        }

        /// The command with point `i` replaced (no change when it has none).
        func setting(_ i: Int, _ p: Point) -> Seg {
            switch (self, i) {
            case (.m, 0): .m(p)
            case (.l, 0): .l(p)
            case (.c(_, let b, let c), 0): .c(p, b, c)
            case (.c(let a, _, let c), 1): .c(a, p, c)
            case (.c(let a, let b, _), 2): .c(a, b, p)
            case (.q(_, let b), 0): .q(p, b)
            case (.q(let a, _), 1): .q(a, p)
            default: self
            }
        }

        /// Every point mapped by `f`.
        func mapPoints(_ f: (Point) -> Point) -> Seg {
            switch self {
            case .m(let p): .m(f(p))
            case .l(let p): .l(f(p))
            case .c(let a, let b, let c): .c(f(a), f(b), f(c))
            case .q(let a, let b): .q(f(a), f(b))
            case .z: .z
            }
        }
    }

    /// The last move at or before the end of `segs`' prefix: its point.
    static func lastMove(_ segs: some Collection<Seg>) -> Point? {
        for s in segs.reversed() { if case .m(let p) = s { return p } }
        return nil
    }

    /// Parses path data (`M x y L x y C … Q … Z`); malformed commands are skipped.
    public static func parse(_ d: String) -> [Seg] {
        var toks: [Substring] = []
        var cur = d.unicodeScalars.startIndex
        var start = cur
        let scalars = d.unicodeScalars
        while cur < scalars.endIndex {
            let c = scalars[cur]
            if c.properties.isWhitespace || c == "," {
                if start < cur { toks.append(Substring(scalars[start ..< cur])) }
                start = scalars.index(after: cur)
            }
            cur = scalars.index(after: cur)
        }
        if start < scalars.endIndex { toks.append(Substring(scalars[start ..< scalars.endIndex])) }
        func num(_ i: Int) -> Double? { toks.at(i).flatMap { rustParseF64($0) }.flatMap { $0.isFinite ? $0 : nil } }
        func pt(_ i: Int) -> Point? {
            guard let x = num(i), let y = num(i + 1) else { return nil }
            return Point(x, y)
        }
        var out: [Seg] = []
        var i = 0
        while i < toks.count && out.count < 100_000 {
            let seg: Seg?
            let n: Int
            switch toks[i] {
            case "M": (seg, n) = (pt(i + 1).map(Seg.m), 3)
            case "L": (seg, n) = (pt(i + 1).map(Seg.l), 3)
            case "C":
                if let a = pt(i + 1), let b = pt(i + 3), let c = pt(i + 5) { seg = .c(a, b, c) } else { seg = nil }
                n = 7
            case "Q":
                if let a = pt(i + 1), let b = pt(i + 3) { seg = .q(a, b) } else { seg = nil }
                n = 5
            case "Z": (seg, n) = (.z, 1)
            default: (seg, n) = (nil, 1)
            }
            // Make a closing edge explicit, so it is a segment that can take points.
            if seg == .z, let a = lastMove(out), let b = out.last?.end, (a - b).hypot > 1e-6 {
                out.append(.l(a))
            }
            if let s = seg {
                // A path starts with a move.
                var s = s
                if out.isEmpty {
                    switch s {
                    case .l(let p): s = .m(p)
                    case .c, .q, .z:
                        i += n
                        continue
                    case .m: break
                    }
                }
                out.append(s)
            }
            i += n
        }
        return out
    }

    /// Path data for `segs`.
    public static func write(_ segs: [Seg]) -> String {
        func f(_ v: Double) -> String {
            var s = Substring(rustFixed(v, places: 3))
            while s.last == "0" { s = s.dropLast() }
            while s.last == "." { s = s.dropLast() }
            return s == "-0" ? "0" : String(s)
        }
        func p(_ q: Point) -> String { "\(f(q.x)) \(f(q.y))" }
        return segs.map { s in
            switch s {
            case .m(let a): "M \(p(a))"
            case .l(let a): "L \(p(a))"
            case .c(let a, let b, let c): "C \(p(a)) \(p(b)) \(p(c))"
            case .q(let a, let b): "Q \(p(a)) \(p(b))"
            case .z: "Z"
            }
        }.joined(separator: " ")
    }

    /// Whether segment `i` ends back on its sub-path's start right before a `Z` (the closing edge of a closed
    /// outline). Its end is the same vertex as the start, not a vertex of its own.
    static func closesOntoStart(_ segs: [Seg], _ i: Int) -> Bool {
        guard segs.at(i + 1) == .z, i >= 0, i < segs.count else { return false }
        guard let a = lastMove(segs[...i]), let b = segs[i].end else { return false }
        return !segs[i].isMove && (a - b).hypot < 1e-6
    }

    /// The segments whose end is a vertex, in order.
    public static func vertices(_ segs: [Seg]) -> [Int] {
        segs.indices.filter { segs[$0].end != nil && !closesOntoStart(segs, $0) }
    }

    static func shift(_ segs: inout [Seg], _ i: Int, _ which: [Int], _ d: Vec2) {
        guard segs.indices.contains(i) else { return }
        var s = segs[i]
        let pts = s.points
        for w in which where pts.indices.contains(w) { s = s.setting(w, s.points[w] + d) }
        segs[i] = s
    }

    /// The indices of the points of a segment that sit on its end vertex (the end and, for a cubic, its
    /// incoming control point).
    static func endPoints(_ seg: Seg?) -> [Int] {
        switch seg {
        case .c?: [1, 2]
        case .q?: [1]
        case .m?, .l?: [0]
        default: []
        }
    }

    /// The closing edge of the sub-path a move at `si` starts: the segment ending back on it.
    static func closingEdge(_ segs: [Seg], _ si: Int) -> Int? {
        var j = si + 1
        while j < segs.count, !segs[j].isMove {
            if closesOntoStart(segs, j) { return j }
            j += 1
        }
        return nil
    }

    /// Moves the vertex ending segment `si` by `d`, with the control points attached to it.
    static func moveVertex(_ segs: inout [Seg], _ si: Int, _ d: Vec2) {
        // A closed sub-path's start is also its closing edge's end.
        let close = segs.at(si)?.isMove == true ? closingEdge(segs, si) : nil
        shift(&segs, si, endPoints(segs.at(si)), d)
        // The outgoing curve's first control point follows the vertex.
        if segs.at(si + 1)?.isCubic == true { shift(&segs, si + 1, [0], d) }
        if let j = close { shift(&segs, j, endPoints(segs.at(j)), d) }
    }

    /// The point where segment `si` starts.
    static func segStart(_ segs: [Seg], _ si: Int) -> Point? {
        guard si > 0, si <= segs.count else { return nil }
        let prev = segs[..<si]
        guard let last = prev.last else { return nil }
        if last == .z { return lastMove(prev) }
        return last.end
    }

    /// Splits segment `si` at `t`, adding a vertex there. False for a move or close.
    static func split(_ segs: inout [Seg], _ si: Int, _ t: Double) -> Bool {
        guard let p0 = segStart(segs, si) else { return false }
        func lerp(_ a: Point, _ b: Point) -> Point { a.lerp(b, t) }
        let a: Seg, b: Seg
        switch segs.at(si) {
        case .l(let p1)?:
            (a, b) = (.l(lerp(p0, p1)), .l(p1))
        case .q(let c, let p1)?:
            let (m0, m1) = (lerp(p0, c), lerp(c, p1))
            let m = m0.lerp(m1, t)
            (a, b) = (.q(m0, m), .q(m1, p1))
        case .c(let c1, let c2, let p1)?:
            let (a1, a2, a3) = (lerp(p0, c1), lerp(c1, c2), lerp(c2, p1))
            let (b1, b2) = (a1.lerp(a2, t), a2.lerp(a3, t))
            let m = b1.lerp(b2, t)
            (a, b) = (.c(a1, b1, m), .c(b2, a3, p1))
        default:
            return false
        }
        segs[si] = a
        segs.insert(b, at: si + 1)
        return true
    }

    /// The sub-path holding segment `si`: from its move up to the next move (or the end).
    static func subpath(_ segs: [Seg], _ si: Int) -> (Int, Int) {
        var from = 0
        if si >= 0 && si < segs.count {
            for k in stride(from: si, through: 0, by: -1) where segs[k].isMove {
                from = k
                break
            }
        }
        var to = segs.count
        var j = si + 1
        while j < segs.count {
            if segs[j].isMove {
                to = j
                break
            }
            j += 1
        }
        return (from, to)
    }

    /// Removes the vertex ending segment `si`. A sub-path keeps at least two vertices.
    static func removeVertex(_ segs: inout [Seg], _ si: Int) -> Bool {
        // The vertices of `si`'s sub-path.
        let (from, to) = subpath(segs, si)
        let count = vertices(segs).filter { $0 >= from && $0 < to }.count
        if count <= 2 { return false }
        if segs.at(si)?.isMove == true {
            // The next vertex becomes the start; a closed outline's closing edge now ends there.
            guard let next = segs.at(si + 1)?.end else { return false }
            segs.remove(at: si + 1)
            segs[si] = .m(next)
            var j = si + 1
            var close: Int?
            while j < segs.count, !segs[j].isMove {
                if segs.at(j + 1) == .z {
                    close = j
                    break
                }
                j += 1
            }
            if let j = close {
                switch segs[j] {
                case .l: segs[j] = .l(next)
                case .c(let a, let b, _): segs[j] = .c(a, b, next)
                case .q(let a, _): segs[j] = .q(a, next)
                default: break
                }
            }
            return true
        }
        // Merge with the next segment: it now starts where the removed vertex's segment started.
        if case .c(let c1, _, _)? = segs.at(si), case .c(_, let c2, let p)? = segs.at(si + 1) {
            segs.remove(at: si + 1)
            segs[si] = .c(c1, c2, p)
        } else if segs.indices.contains(si) {
            segs.remove(at: si)
        }
        return true
    }

    /// The segment that ends at the vertex ending segment `si`: the closing edge for a closed sub-path's
    /// start, none for an open one's.
    static func endingSegment(_ segs: [Seg], _ si: Int) -> Int? {
        segs.at(si)?.isMove == true ? closingEdge(segs, si) : si
    }

    /// Whether segment `j` is a straight line or a curve.
    static func segmentKind(_ segs: [Seg], _ j: Int) -> String? {
        switch segs.at(j) {
        case .l?: "straight"
        case .c?, .q?: "curved"
        default: nil
        }
    }

    /// Makes segment `j` a straight line (dropping its handles) or a curve with handles at its thirds, so it
    /// keeps its shape until a handle is dragged.
    static func setSegment(_ segs: inout [Seg], _ j: Int, _ curved: Bool) {
        if curved {
            toCubic(&segs, j)
        } else if let s = segs.at(j) {
            switch s {
            case .c(_, _, let p), .q(_, let p): segs[j] = .l(p)
            default: break
            }
        }
    }

    /// Opens the closed sub-path through the vertex ending segment `si` there: it now starts and ends on that
    /// vertex, as two points. False for an open sub-path.
    static func openAt(_ segs: inout [Seg], _ si: Int) -> Bool {
        let (from, to) = subpath(segs, si)
        let z = to - 1
        guard to >= 1, z > si, segs.at(z) == .z else { return false }
        guard let v = segs.at(si)?.end else { return false }
        guard si + 1 <= z, from <= si, si < segs.count else { return false }
        let after = segs[(si + 1) ..< z]
        let before = segs[(from + 1) ..< (si + 1)]
        var out: [Seg] = [.m(v)]
        out.append(contentsOf: after)
        out.append(contentsOf: before)
        segs.replaceSubrange(from ..< to, with: out)
        return true
    }

    /// Deletes the segment ending at the vertex ending segment `si` from its closed sub-path, which opens
    /// there: it now starts at the segment's end and ends at its start. False for an open sub-path.
    static func deleteSegmentAt(_ segs: inout [Seg], _ si: Int) -> Bool {
        let (from, _) = subpath(segs, si)
        if !openAt(&segs, si) { return false }
        // The deleted segment now ends the sub-path.
        let (_, to) = subpath(segs, from)
        if to > from + 1 { segs.remove(at: to - 1) }
        return true
    }

    /// Closes the open sub-path through the vertex ending segment `si`: a straight segment joins its ends,
    /// or they become one point when they meet. False for a closed sub-path.
    static func closeAt(_ segs: inout [Seg], _ si: Int) -> Bool {
        let (from, to) = subpath(segs, si)
        let last = max(to - 1, 0)
        if last <= from || segs.at(last) == .z { return false }
        guard case .m(let start)? = segs.at(from), let end = segs.at(last)?.end else { return false }
        var add: [Seg] = []
        if (start - end).hypot >= 1e-6 { add.append(.l(start)) }
        add.append(.z)
        segs.insert(contentsOf: add, at: to)
        return true
    }

    /// Custom paths of a preset shape, in shape-local points.
    static func toCustom(_ sh: Shape, _ w: Double, _ h: Double) -> [CustomPath] {
        shapeGeometry(sh, w, h).paths.map { sp in
            let segs: [Seg] = sp.path.elements.map { e in
                switch e {
                case .moveTo(let p): .m(p)
                case .lineTo(let p): .l(p)
                case .quadTo(let a, let p): .q(a, p)
                case .curveTo(let a, let b, let p): .c(a, b, p)
                case .closePath: .z
                }
            }
            return CustomPath(w: w, h: h, d: write(segs), fill: sp.fill, stroke: sp.stroke)
        }
    }

    /// Rescales every path of a custom geometry to shape-local points.
    static func normalize(_ paths: inout [CustomPath], _ w: Double, _ h: Double) {
        for i in paths.indices {
            let p = paths[i]
            let (sx, sy) = (p.w > 0 ? w / p.w : 1, p.h > 0 ? h / p.h : 1)
            if Swift.abs(sx - 1) > 1e-12 || Swift.abs(sy - 1) > 1e-12 {
                let segs = parse(p.d).map { $0.mapPoints { Point($0.x * sx, $0.y * sy) } }
                paths[i].d = write(segs)
            }
            paths[i].w = w
            paths[i].h = h
        }
    }

    /// Fits the box around the outline, keeping the drawing where it is on the slide.
    static func refit(_ sh: inout Shape) {
        guard let x = sh.xfrm, case .custom(var paths) = sh.geom else { return }
        var all = paths.map { parse($0.d) }
        var bb: Rect?
        for segs in all {
            for s in segs {
                for q in s.points { bb = bb.map { $0.unionPoint(q) } ?? Rect.fromPoints(q, q) }
            }
        }
        guard let bb else { return }
        let (w, h) = (bb.width.rustMax(1), bb.height.rustMax(1))
        if Swift.abs(bb.x0) < 1e-6 && Swift.abs(bb.y0) < 1e-6 && Swift.abs(w - x.w) < 1e-6 && Swift.abs(h - x.h) < 1e-6 { return }
        let c = x.affine * Point(bb.x0 + w / 2, bb.y0 + h / 2)
        let off = Vec2(bb.x0, bb.y0)
        for i in paths.indices {
            all[i] = all[i].map { $0.mapPoints { $0 - off } }
            paths[i].d = write(all[i])
            paths[i].w = w
            paths[i].h = h
        }
        sh.geom = .custom(paths: paths)
        sh.xfrm = Xfrm(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rot: x.rot, flipH: x.flipH, flipV: x.flipV)
    }

    /// The one shape whose points are edited: `id`, or the single selected shape.
    static func target(_ s: Session, _ p: JSON, _ cmd: String) throws -> ShapeId {
        let st = try s.doc()
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", cmd) {
            id = i
        } else if st.selection.shapes.count == 1, let one = st.selection.shapes.first {
            id = one
        } else {
            throw Cmd.bad(cmd, "select one shape")
        }
        guard let sh = st.shape(id) else { throw Cmd.bad(cmd, "no such shape") }
        if !st.shapes.contains(where: { $0.id == id }) {
            throw Cmd.bad(cmd, "a shape in a group can't have its points edited; ungroup it first")
        }
        if sh.kind != .shape || sh.isLine || sh.xfrm == nil {
            throw Cmd.bad(cmd, "only a shape with an outline has points to edit")
        }
        if sh.locked { throw Cmd.bad(cmd, "the shape is locked") }
        return id
    }

    /// Makes `id` a freeform in shape-local points (the state Edit Points works in).
    static func prepare(_ s: Session, _ id: ShapeId) throws {
        let st = try s.doc()
        guard let sh = st.shape(id), let x = sh.xfrm else { return }
        if case .custom(let paths) = sh.geom, paths.allSatisfy({ $0.w == x.w && $0.h == x.h }) { return }
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("shape.editPoints", "no slide")) { list in
                _ = withShape(&list, id) { sh in
                    switch sh.geom {
                    case .custom(var paths):
                        normalize(&paths, x.w, x.h)
                        sh.geom = .custom(paths: paths)
                    case .preset:
                        sh.geom = .custom(paths: toCustom(sh, x.w, x.h))
                    }
                }
            }
        }
    }

    @Sendable static func editPoints(_ s: Session, _ p: JSON) throws -> JSON {
        let on = p.get("on")?.asBool ?? (s.tool.editPoints == nil)
        s.tool.editVertex = nil
        s.tool.editSegment = nil
        if !on {
            s.tool.editPoints = nil
            return ["editing": .null]
        }
        let id = try target(s, p, "shape.editPoints")
        try prepare(s, id)
        s.tool.editPoints = id
        return ["editing": id.toJSON()]
    }

    /// The scale from a custom path's units to the shape's box.
    static func scale(_ cp: CustomPath, _ x: Xfrm) -> (Double, Double) {
        (cp.w > 0 ? x.w / cp.w : 1, cp.h > 0 ? x.h / cp.h : 1)
    }

    /// Vertices of every path of `sh` in slide points.
    public static func slideVertices(_ doc: Presentation, _ sel: Selection, _ sh: Shape) -> [[Point]] {
        guard case .custom(let paths) = sh.geom else { return [] }
        let x = Cmd.xfrmOf(doc, sel, sh)
        let a = x.affine
        return paths.map { p in
            let (sx, sy) = scale(p, x)
            let segs = parse(p.d)
            return vertices(segs).compactMap { segs[$0].end }.map { a * Point($0.x * sx, $0.y * sy) }
        }
    }

    @Sendable static func points(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let id: ShapeId
        if let i = try Cmd.idParam(p, "id", "shape.points") {
            id = i
        } else if let first = st.selection.shapes.first {
            id = first
        } else {
            throw Cmd.bad("shape.points", "select a shape")
        }
        guard let sh = st.shape(id) else { throw Cmd.bad("shape.points", "no such shape") }
        let paths = slideVertices(st.doc, st.selection, sh).map { v in JSON.array(v.map { [.num($0.x), .num($0.y)] }) }
        var types: [JSON] = []
        var kinds: [JSON] = []
        if case .custom(let cps) = sh.geom {
            for cp in cps {
                let segs = parse(cp.d)
                let vs = vertices(segs)
                types.append(.array(vs.map { .string(pointKind(segs, $0)) }))
                kinds.append(.array(vs.map { si in .opt(endingSegment(segs, si).flatMap { segmentKind(segs, $0) }) }))
            }
        }
        return ["id": id.toJSON(), "paths": .array(paths), "types": .array(types), "segments": .array(kinds)]
    }

    /// Runs `f` on the segments of path `path` of `id` (in shape-local points), then refits the box. `f`
    /// gets the segment indices of the vertices and returns whether it changed anything.
    static func editPath(_ s: Session, _ id: ShapeId, _ path: Int, _ cmd: String, _ f: (inout [Seg], [Int], Xfrm) throws -> Bool) throws -> JSON {
        try prepare(s, id)
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { list in
                let found: Void? = try withShape(&list, id) { sh in
                    guard let x = sh.xfrm else { throw Cmd.bad(cmd, "the shape has no position") }
                    guard case .custom(var paths) = sh.geom else { throw Cmd.bad(cmd, "not a freeform") }
                    guard paths.indices.contains(path) else { throw Cmd.bad(cmd, "no such path") }
                    var segs = parse(paths[path].d)
                    let vs = vertices(segs)
                    if try f(&segs, vs, x) {
                        paths[path].d = write(segs)
                        sh.geom = .custom(paths: paths)
                        refit(&sh)
                    }
                }
                if found == nil { throw Cmd.bad(cmd, "no such shape") }
            }
        }
        return Cmd.ok()
    }

    static func indexParam(_ p: JSON, _ key: String, _ cmd: String) throws -> Int {
        guard let v = p.get(key)?.asUsize else { throw Cmd.bad(cmd, "give `\(key)`") }
        return v
    }

    static func pathParam(_ p: JSON) -> Int { p.get("path")?.asUsize ?? 0 }

    static func slidePoint(_ p: JSON, _ cmd: String) throws -> Point {
        guard let x = Cmd.f64Param(p, "x"), let y = Cmd.f64Param(p, "y"), x.isFinite, y.isFinite else {
            throw Cmd.bad(cmd, "give `x` and `y` in slide points")
        }
        return Point(x.clamped(-1e5, 1e5), y.clamped(-1e5, 1e5))
    }

    @Sendable static func movePoint(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.movePoint")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.movePoint")
        let to = try slidePoint(p, "shape.movePoint")
        return try editPath(s, id, path, "shape.movePoint") { segs, vs, x in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.movePoint", "no such point") }
            let local = x.affine.inverse * to
            guard let cur = segs.at(si)?.end else { return false }
            moveVertex(&segs, si, local - cur)
            return true
        }
    }

    @Sendable static func addPoint(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.addPoint")
        let path = pathParam(p)
        let seg = try indexParam(p, "segment", "shape.addPoint")
        let t = (Cmd.f64Param(p, "t") ?? 0.5).clamped(0.01, 0.99)
        let r = try editPath(s, id, path, "shape.addPoint") { segs, vs, _ in
            guard let v = vs.at(seg) else { throw Cmd.bad("shape.addPoint", "no such segment") }
            // The closing edge of a closed outline ends at the start: split it, not the start.
            guard let si = endingSegment(segs, v) else { throw Cmd.bad("shape.addPoint", "the first point ends no segment") }
            if split(&segs, si, t) { return true }
            throw Cmd.bad("shape.addPoint", "no segment ends at that point")
        }
        forgetKinds(s, path)
        return r
    }

    @Sendable static func deletePoint(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.deletePoint")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.deletePoint")
        let r = try editPath(s, id, path, "shape.deletePoint") { segs, vs, _ in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.deletePoint", "no such point") }
            if removeVertex(&segs, si) { return true }
            throw Cmd.bad("shape.deletePoint", "an outline keeps at least two points")
        }
        forgetKinds(s, path)
        return r
    }

    /// The vertex of `sh` near slide point `p`: (path, index).
    public static func vertexAt(_ doc: Presentation, _ sel: Selection, _ sh: Shape, _ p: Point, _ tol: Double) -> (Int, Int)? {
        for (pi, vs) in slideVertices(doc, sel, sh).enumerated() {
            for (i, q) in vs.enumerated() where (q - p).hypot <= tol { return (pi, i) }
        }
        return nil
    }

    /// The point at parameter `t` of segment `si`, scaled by `scale` into the shape's box.
    static func segmentPoint(_ segs: [Seg], _ si: Int, _ p0: Point, _ t: Double, _ scale: (Double, Double)) -> Point? {
        let q: Point
        switch segs.at(si) {
        case .l(let p1)?: q = p0.lerp(p1, t)
        case .q(let c, let p1)?: q = p0.lerp(c, t).lerp(c.lerp(p1, t), t)
        case .c(let c1, let c2, let p1)?:
            let (a, b, c) = (p0.lerp(c1, t), c1.lerp(c2, t), c2.lerp(p1, t))
            q = a.lerp(b, t).lerp(b.lerp(c, t), t)
        default: return nil
        }
        return Point(q.x * scale.0, q.y * scale.1)
    }

    /// The vertex that ends segment `si` (a closing edge ends on the start).
    static func segmentEndVertex(_ segs: [Seg], _ vs: [Int], _ si: Int) -> Int? {
        if closesOntoStart(segs, si) {
            guard si > 0 else { return nil }
            let start = segs[..<si].lastIndex { $0.isMove }
            return start.flatMap { m in vs.firstIndex(of: m) }
        }
        return vs.firstIndex(of: si)
    }

    /// The distance and `t` of the point on segment `si` nearest `local`, if it lies within `tol`.
    static func nearestOnSegment(_ segs: [Seg], _ si: Int, _ p0: Point, _ scale: (Double, Double), _ local: Point, _ tol: Double) -> (Double, Double)? {
        func at(_ t: Double) -> Point? { segmentPoint(segs, si, p0, t, scale) }
        var near: (Double, Double)?
        for k in 1 ..< 32 {
            let t = Double(k) / 32
            if let q = at(t) {
                let d = (q - local).hypot
                if d <= tol && (near.map { d < $0.0 } ?? true) { near = (d, t) }
            }
        }
        guard var (d, t) = near else { return nil }
        // Narrow `t` down to the nearest place on the segment, where Add Point puts the point.
        var step = 1.0 / 32
        for _ in 0 ..< 4 {
            step /= 8
            let c = t
            for k in -8 ... 8 {
                let u = (c + Double(k) * step).clamped(0, 1)
                if let q = at(u) {
                    let e = (q - local).hypot
                    if e < d { (d, t) = (e, u) }
                }
            }
        }
        return (d, t)
    }

    /// The segment of `sh`'s outline near slide point `p`: (path, index of the vertex ending it, t).
    public static func segmentAt(_ doc: Presentation, _ sel: Selection, _ sh: Shape, _ p: Point, _ tol: Double) -> (Int, Int, Double)? {
        guard case .custom(let paths) = sh.geom else { return nil }
        let x = Cmd.xfrmOf(doc, sel, sh)
        let local = x.affine.inverse * p
        var best: (Double, Int, Int, Double)?
        for (pi, cp) in paths.enumerated() {
            let sc = scale(cp, x)
            let segs = parse(cp.d)
            let vs = vertices(segs)
            for si in segs.indices {
                guard let p0 = segStart(segs, si), let ev = segmentEndVertex(segs, vs, si),
                      let (d, t) = nearestOnSegment(segs, si, p0, sc, local, tol) else { continue }
                if best.map({ d < $0.0 }) ?? true { best = (d, pi, ev, t) }
            }
        }
        return best.map { ($0.1, $0.2, $0.3) }
    }

    /// Moves vertex `index` of path `path` of `id` to slide point `to` (pointer drags).
    static func movePointRaw(_ s: Session, _ id: ShapeId, _ path: Int, _ index: Int, _ to: Point) throws -> JSON {
        try movePoint(s, ["id": id.toJSON(), "path": .integer(path), "index": .integer(index), "x": .num(to.x), "y": .num(to.y)])
    }

    /// Where the control handles of the vertex ending segment `si` live: (segment, point index) for the
    /// incoming and the outgoing one, when those segments are cubics.
    static func handleSlots(_ segs: [Seg], _ si: Int) -> ((Int, Int)?, (Int, Int)?) {
        let incoming = segs.at(si)?.isMove == true ? closingEdge(segs, si) : si
        let inc = incoming.flatMap { segs.at($0)?.isCubic == true ? ($0, 1) : nil }
        let out = segs.at(si + 1)?.isCubic == true ? (si + 1, 0) : nil
        return (inc, out)
    }

    static func getPt(_ segs: [Seg], _ slot: (Int, Int)) -> Point? {
        guard case .c(let a, let b, let c)? = segs.at(slot.0) else { return nil }
        return [a, b, c].at(slot.1)
    }

    static func setPt(_ segs: inout [Seg], _ slot: (Int, Int), _ p: Point) {
        guard let s = segs.at(slot.0), s.points.indices.contains(slot.1) else { return }
        segs[slot.0] = s.setting(slot.1, p)
    }

    /// Turns segment `j` into a cubic with the same shape.
    static func toCubic(_ segs: inout [Seg], _ j: Int) {
        guard let p0 = segStart(segs, j) else { return }
        let c: Seg
        switch segs.at(j) {
        case .l(let p1)?: c = .c(p0.lerp(p1, 1.0 / 3.0), p0.lerp(p1, 2.0 / 3.0), p1)
        case .q(let q, let p1)?: c = .c(p0.lerp(q, 2.0 / 3.0), p1.lerp(q, 2.0 / 3.0), p1)
        default: return
        }
        segs[j] = c
    }

    /// Sets the point type of the vertex ending segment `si`. Its segments become curves so it has handles;
    /// smooth and straight points get their handles in line through the vertex.
    static func setType(_ segs: inout [Seg], _ si: Int, _ kind: String) {
        let incoming = segs.at(si)?.isMove == true ? closingEdge(segs, si) : si
        if let j = incoming { toCubic(&segs, j) }
        toCubic(&segs, si + 1)
        if kind == "corner" { return }
        let (hiOpt, hoOpt) = handleSlots(segs, si)
        guard let v = segs.at(si)?.end, let hi = hiOpt, let ho = hoOpt, let a = getPt(segs, hi), let b = getPt(segs, ho) else { return }
        var (li, lo) = ((a - v).hypot, (b - v).hypot)
        var dir = b - a
        if dir.hypot < 1e-9 {
            // Both handles on the vertex: point them along the neighbours.
            let prev = segStart(segs, hi.0) ?? v
            let next = segs.at(ho.0)?.end ?? v
            dir = next - prev
        }
        let len = dir.hypot
        if len < 1e-9 { return }
        let u = dir / len
        if kind == "smooth" {
            let m = li + lo > 1e-9 ? (li + lo) / 2 : len / 6
            (li, lo) = (m, m)
        }
        setPt(&segs, hi, v - u * li)
        setPt(&segs, ho, v + u * lo)
    }

    /// The type a vertex's handles show: smooth (in line, equal), straight (in line) or corner.
    public static func pointKind(_ segs: [Seg], _ si: Int) -> String {
        let (hiOpt, hoOpt) = handleSlots(segs, si)
        guard let v = segs.at(si)?.end, let hi = hiOpt, let ho = hoOpt, let a = getPt(segs, hi), let b = getPt(segs, ho) else { return "corner" }
        let (da, db) = (a - v, b - v)
        let (la, lb) = (da.hypot, db.hypot)
        if la < 1e-6 || lb < 1e-6 { return "corner" }
        let cos = da.dot(db) / (la * lb)
        if cos > -0.9998 { return "corner" }
        if Swift.abs(la - lb) <= 0.01 * la.rustMax(lb) { return "smooth" }
        return "straight"
    }

    /// Moves handle `side` of the vertex ending segment `si` to `p`; the other handle follows as the point's
    /// type says.
    static func setHandle(_ segs: inout [Seg], _ si: Int, _ out: Bool, _ p: Point, _ kind: String?) -> Bool {
        let kind = kind ?? pointKind(segs, si)
        let (hi, ho) = handleSlots(segs, si)
        let (mine, other) = out ? (ho, hi) : (hi, ho)
        guard let mine, let v = segs.at(si)?.end else { return false }
        setPt(&segs, mine, p)
        if let o = other, kind != "corner", let q = getPt(segs, o) {
            let d = p - v
            let l = d.hypot
            if l > 1e-9 {
                let lo = kind == "smooth" ? l : (q - v).hypot
                setPt(&segs, o, v - d / l * lo)
            }
        }
        return true
    }

    /// Handles of vertex `index` of path `path` of `sh` in slide points: (incoming, outgoing, vertex).
    public static func slideHandles(_ doc: Presentation, _ sel: Selection, _ sh: Shape, _ path: Int, _ index: Int) -> (Point?, Point?, Point)? {
        guard case .custom(let paths) = sh.geom, let cp = paths.at(path) else { return nil }
        let x = Cmd.xfrmOf(doc, sel, sh)
        let (sx, sy) = scale(cp, x)
        let a = x.affine
        func to(_ q: Point) -> Point { a * Point(q.x * sx, q.y * sy) }
        let segs = parse(cp.d)
        guard let si = vertices(segs).at(index), let v = segs.at(si)?.end else { return nil }
        let (hi, ho) = handleSlots(segs, si)
        return (hi.flatMap { getPt(segs, $0) }.map(to), ho.flatMap { getPt(segs, $0) }.map(to), to(v))
    }

    @Sendable static func pointType(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.pointType")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.pointType")
        guard let kind = Cmd.strParam(p, "type"), ["smooth", "straight", "corner"].contains(where: { rustEqual($0, kind) }) else {
            throw Cmd.bad("shape.pointType", "`type` is smooth, straight or corner")
        }
        // A straight point's handles can be as long as each other; remember the choice for drags.
        s.tool.vertexKind = VertexKind(id, path, index, kind)
        return try editPath(s, id, path, "shape.pointType") { segs, vs, _ in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.pointType", "no such point") }
            setType(&segs, si, kind)
            return true
        }
    }

    @Sendable static func moveHandle(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.moveHandle")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.moveHandle")
        let out: Bool
        switch Cmd.strParam(p, "side") {
        case "out"?: out = true
        case "in"?: out = false
        default: throw Cmd.bad("shape.moveHandle", "`side` is in or out")
        }
        let to = try slidePoint(p, "shape.moveHandle")
        let kind = Cmd.strParam(p, "type").flatMap { k in ["smooth", "straight", "corner"].contains(where: { rustEqual($0, k) }) ? k : nil }
        return try editPath(s, id, path, "shape.moveHandle") { segs, vs, x in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.moveHandle", "no such point") }
            if setHandle(&segs, si, out, x.affine.inverse * to, kind) { return true }
            throw Cmd.bad("shape.moveHandle", "that side of the point has no handle")
        }
    }

    /// The type of vertex `index` of path `path` of `sh`.
    public static func kindOf(_ sh: Shape, _ path: Int, _ index: Int) -> String? {
        guard case .custom(let paths) = sh.geom, let cp = paths.at(path) else { return nil }
        let segs = parse(cp.d)
        guard let si = vertices(segs).at(index) else { return nil }
        return pointKind(segs, si)
    }

    /// `shape.moveHandle` for pointer drags.
    static func moveHandleRaw(_ s: Session, _ p: JSON) throws -> JSON { try moveHandle(s, p) }

    @Sendable static func segmentType(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.segmentType")
        let path = pathParam(p)
        let seg = try indexParam(p, "segment", "shape.segmentType")
        let curved: Bool
        switch Cmd.strParam(p, "type") {
        case "straight"?: curved = false
        case "curved"?: curved = true
        default: throw Cmd.bad("shape.segmentType", "`type` is straight or curved")
        }
        // Already that type: nothing to change, so no undo step.
        let want = curved ? "curved" : "straight"
        if let sh = try s.doc().shape(id), segmentKindOf(sh, path, seg) == want { return Cmd.ok() }
        return try editPath(s, id, path, "shape.segmentType") { segs, vs, _ in
            guard let si = vs.at(seg) else { throw Cmd.bad("shape.segmentType", "no such segment") }
            guard let j = endingSegment(segs, si) else {
                throw Cmd.bad("shape.segmentType", "the first point of an open outline ends no segment")
            }
            setSegment(&segs, j, curved)
            return true
        }
    }

    @Sendable static func openPath(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.openPath")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.openPath")
        let r = try editPath(s, id, path, "shape.openPath") { segs, vs, _ in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.openPath", "no such point") }
            if openAt(&segs, si) { return true }
            throw Cmd.bad("shape.openPath", "the outline is open already")
        }
        forgetKinds(s, path)
        return r
    }

    @Sendable static func closePath(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.closePath")
        let path = pathParam(p)
        let index = try indexParam(p, "index", "shape.closePath")
        let r = try editPath(s, id, path, "shape.closePath") { segs, vs, _ in
            guard let si = vs.at(index) else { throw Cmd.bad("shape.closePath", "no such point") }
            if closeAt(&segs, si) { return true }
            throw Cmd.bad("shape.closePath", "the outline is closed already")
        }
        forgetKinds(s, path)
        return r
    }

    @Sendable static func deleteSegment(_ s: Session, _ p: JSON) throws -> JSON {
        let id = try target(s, p, "shape.deleteSegment")
        let path = pathParam(p)
        let seg = try indexParam(p, "segment", "shape.deleteSegment")
        let r = try editPath(s, id, path, "shape.deleteSegment") { segs, vs, _ in
            guard let si = vs.at(seg) else { throw Cmd.bad("shape.deleteSegment", "no such segment") }
            if endingSegment(segs, si) == nil {
                throw Cmd.bad("shape.deleteSegment", "the first point of an open outline ends no segment")
            }
            if deleteSegmentAt(&segs, si) { return true }
            throw Cmd.bad("shape.deleteSegment", "only a segment of a closed outline can be deleted")
        }
        forgetKinds(s, path)
        return r
    }

    /// The point where the segment ending at vertex `index` of path `path` of `sh` starts.
    public static func segmentStartOf(_ sh: Shape, _ path: Int, _ index: Int) -> Int? {
        guard case .custom(let paths) = sh.geom, let cp = paths.at(path) else { return nil }
        let segs = parse(cp.d)
        let vs = vertices(segs)
        guard let v = vs.at(index), let j = endingSegment(segs, v), j >= 1 else { return nil }
        return vs.firstIndex(of: j - 1)
    }

    /// Adding, deleting, opening or closing renumbers the points of `path`: a point type remembered for one
    /// of them would follow the wrong point.
    static func forgetKinds(_ s: Session, _ path: Int) {
        if s.tool.vertexKind?.path == path { s.tool.vertexKind = nil }
    }

    /// Whether the segment ending at vertex `index` of path `path` of `sh` is straight or curved.
    public static func segmentKindOf(_ sh: Shape, _ path: Int, _ index: Int) -> String? {
        guard case .custom(let paths) = sh.geom, let cp = paths.at(path) else { return nil }
        let segs = parse(cp.d)
        guard let si = vertices(segs).at(index), let j = endingSegment(segs, si) else { return nil }
        return segmentKind(segs, j)
    }

    /// Whether the outline through vertex `index` of path `path` of `sh` is closed.
    public static func closedAt(_ sh: Shape, _ path: Int, _ index: Int) -> Bool? {
        guard case .custom(let paths) = sh.geom, let cp = paths.at(path) else { return nil }
        let segs = parse(cp.d)
        guard let si = vertices(segs).at(index) else { return nil }
        let (_, to) = subpath(segs, si)
        guard to >= 1 else { return nil }
        return segs.at(to - 1) == .z
    }
}
