// DCEngine — what the pointer is over: handles of the selection, the frame of edited text, shapes topmost
// first (groups, ink, lines, tables' borders), drawing guides, and where a press falls against the box whose
// text is being edited. Port of the hit testing of deckcraft crates/engine/src/tools.rs (`hit_test`,
// `box_handles`, `wordart_handles`, `hit_shape`, `text_member_at`, `member_at`, `shape_in_front`,
// `edited_box`, `edit_zone`, `in_table_cell`, `guide_at`, `text_pos`, `table_rows`; MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel
import DCRender

extension Hit {
    /// serde's `Hit` (`tag = "kind"`, camelCase), as `{"hit": …}` answers carry it.
    public func toJSON() -> JSON {
        switch self {
        case .resize(let id, let handle): ["kind": "resize", "id": id.toJSON(), "handle": .integer(Int(handle))]
        case .rotate(let id): ["kind": "rotate", "id": id.toJSON()]
        case .adjust(let id, let index): ["kind": "adjust", "id": id.toJSON(), "index": .integer(index)]
        case .handle(let id, let path, let index, let out):
            ["kind": "handle", "id": id.toJSON(), "path": .integer(path), "index": .integer(index), "out": .bool(out)]
        case .vertex(let id, let path, let index): ["kind": "vertex", "id": id.toJSON(), "path": .integer(path), "index": .integer(index)]
        case .warp(let id, let index): ["kind": "warp", "id": id.toJSON(), "index": .integer(index)]
        case .lineEnd(let id, let end): ["kind": "lineEnd", "id": id.toJSON(), "end": .integer(Int(end))]
        case .shape(let id, let text): ["kind": "shape", "id": id.toJSON(), "text": .bool(text)]
        case .frame(let id): ["kind": "frame", "id": id.toJSON()]
        case .tableColumn(let id, let col): ["kind": "tableColumn", "id": id.toJSON(), "col": .integer(col)]
        case .tableRow(let id, let row): ["kind": "tableRow", "id": id.toJSON(), "row": .integer(row)]
        }
    }

    /// The shape the hit is on.
    public var id: ShapeId {
        switch self {
        case .resize(let id, _), .rotate(let id), .adjust(let id, _), .handle(let id, _, _, _), .vertex(let id, _, _),
             .warp(let id, _), .lineEnd(let id, _), .shape(let id, _), .frame(let id), .tableColumn(let id, _),
             .tableRow(let id, _):
            id
        }
    }
}

extension Tools {
    /// Handle positions in slide coordinates for a box: the 8 resize handles (NW, N, NE, E, SE, S, SW, W)
    /// and the rotation handle (`box_handles`).
    public static func boxHandles(_ x: Xfrm) -> ([Point], Point) {
        let a = x.affine
        let (w, h) = (x.w, x.h)
        let local: [(Double, Double)] = [(0, 0), (w / 2.0, 0), (w, 0), (w, h / 2.0), (w, h), (w / 2.0, h), (0, h), (0, h / 2.0)]
        let pts = local.map { a * Point($0.0, $0.1) }
        // The rotation handle sits above the top edge (in the shape's rotated frame).
        let up = x.flipV ? 1.0 : -1.0
        let rot = Affine.translate(Vec2(x.x + w / 2.0, x.y + h / 2.0)) * Affine.rotate(x.rot.toRadians) * Point(0, up * (h / 2.0 + 20.0))
        return (pts, rot)
    }

    /// WordArt adjust handles for `sh`, in shape-local points (the text rectangle). Empty when the resolved
    /// body has no warp DeckCraft draws, or the shape has no text to store one on (`wordart_handles`).
    public static func wordartHandles(_ doc: Presentation, _ sel: Selection, _ sh: Shape, _ w: Double, _ h: Double) -> [Warp.Handle] {
        if sh.text == nil { return [] }
        guard let ctx = TextCommands.ctxFor(doc, sel) else { return [] }
        let bp = Resolve.body(ctx, sh)
        guard let name = bp.warp, Warp.isSupported(name) else { return [] }
        let tr = shapeGeometry(sh, w, h).textRect
        return Warp.handles(name, bp.warpAdj, tr)
    }

    /// Text position under slide point `p` in shape `sh` (`text_pos`).
    public static func textPos(_ st: DocState, _ sh: Shape, _ p: Point) -> TextPos {
        TextCommands.textPosAt(st, TextSel(shape: sh.id), p)
    }

    /// Row heights of table `t` as drawn: rows grow to fit their text (`table_rows`).
    public static func tableRows(_ st: DocState, _ t: Table) -> [Double] {
        Cmd.tableDrawnHeights(st.doc, st.selection, t)
    }

    /// Whether shape `id` takes the caret on the first click: a placeholder or a text box.
    static func isTextFirst(_ st: DocState, _ id: ShapeId) -> Bool {
        guard let s = st.shape(id) else { return false }
        return s.ph != nil || s.textBox
    }

    /// The topmost text-holding shape under `p` inside group `sh`, recursing into nested groups. Children
    /// live in the group's child space, so the point is mapped through `groupChildAffine` as `hitShape` does.
    static func textMemberAt(_ st: DocState, _ sh: Shape, _ p: Point, _ tol: Double) -> ShapeId? {
        guard case .group(let children, let child) = sh.kind else { return nil }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let ch = Rect(child.x, child.y, child.x + child.w, child.y + child.h)
        return memberAt(children, groupChildAffine(x, ch), p, tol, 0)
    }

    /// Depth-first (topmost-first) search of `children` for a text-holding shape under `p`; `toAbs` maps this
    /// level's child space to slide space.
    static func memberAt(_ children: [Shape], _ toAbs: Affine, _ p: Point, _ tol: Double, _ depth: Int) -> ShapeId? {
        if depth > 64 { return nil }
        let q = toAbs.inverse * p
        for c in children.reversed() {
            guard let cx = c.xfrm else { continue }
            let local = cx.affine.inverse * q
            if local.x < -tol || local.y < -tol || local.x > cx.w + tol || local.y > cx.h + tol { continue }
            switch c.kind {
            case .group(let gc, let gch):
                let r = Rect(gch.x, gch.y, gch.x + gch.w, gch.y + gch.h)
                let nested = toAbs * groupChildAffine(cx, r)
                if let id = memberAt(gc, nested, p, tol, depth + 1) { return id }
            case .shape, .connector:
                if !c.isLine { return c.id }
            default:
                break
            }
        }
        return nil
    }

    /// Whether a visible shape drawn in front of `target` is under `p`: the shapes above it in its list,
    /// topmost first, and inside a group that holds it, the members above it.
    static func shapeInFront(_ st: DocState, _ shapes: [Shape], _ target: ShapeId, _ p: Point, _ tol: Double, _ depth: Int) -> Bool {
        if depth > 64 { return false }
        for s in shapes.reversed() {
            if s.id == target { return false }
            if findShape([s], target) != nil {
                // The group holding the text: look among its members.
                return shapeInFront(st, s.children, target, p, tol, depth + 1)
            }
            if !s.hidden && hitShape(st, s, p, tol) != nil { return true }
        }
        return false
    }

    /// The box whose text is being edited on the slide (not speaker notes, not a table cell).
    struct EditedBox {
        var id: ShapeId
        var xfrm: Xfrm
        /// Its frame can be grabbed to move it: not a line (no frame to grab) and not locked.
        var movable: Bool
    }

    static func editedBox(_ st: DocState) -> EditedBox? {
        guard let t = st.selection.text, !t.notes, t.cell == nil, let sh = st.shape(t.shape) else { return nil }
        return EditedBox(id: t.shape, xfrm: Cmd.xfrmOf(st.doc, st.selection, sh), movable: !sh.isLine && !sh.locked)
    }

    /// Where a point falls against the box of the text being edited.
    enum EditZone {
        /// Well inside: the caret goes there.
        case inside
        /// On the frame: a band `tol` wide on either side of the box edge.
        case frame
        case outside
    }

    /// Classify slide point `p` against box `x`, in the box's own (rotated, flipped) frame. Inside small boxes
    /// the band narrows to a quarter of the box so their text stays reachable.
    static func editZone(_ x: Xfrm, _ p: Point, _ tol: Double) -> EditZone {
        let l = x.affine.inverse * p
        let (w, h) = (x.w.rustMax(0), x.h.rustMax(0))
        let tol = tol.isFinite ? tol.rustMax(0) : 0
        if !(l.x.isFinite && l.y.isFinite) || l.x < -tol || l.y < -tol || l.x > w + tol || l.y > h + tol { return .outside }
        let inner = tol.rustMin(w / 4.0).rustMin(h / 4.0)
        return l.x > inner && l.y > inner && l.x < w - inner && l.y < h - inner ? .inside : .frame
    }

    /// Whether `p` lies in a cell of table `id`, not in the grab band around it (`cellAt` would take the
    /// nearest cell).
    static func inTableCell(_ st: DocState, _ id: ShapeId, _ p: Point) -> Bool {
        guard let f = st.shape(id).flatMap({ TableCommands.tableFrame(st, $0) }) else { return false }
        let q = f.local(p)
        return q.x >= 0 && q.x <= f.width && q.y >= 0 && q.y <= f.height && f.cellAt(q) != nil
    }

    /// What shape `sh` (not its handles) has under `p`.
    static func hitShape(_ st: DocState, _ sh: Shape, _ p: Point, _ tol: Double) -> Hit? {
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        let local = x.affine.inverse * p
        // Table borders resize rows and columns.
        let near = local.x >= -tol && local.y >= -tol && local.x <= x.w + tol && local.y <= x.h + tol
        if near, let f = TableCommands.tableFrame(st, sh) {
            switch f.borderAt(f.local(p), tol) {
            case .column(let col)?: return .tableColumn(id: sh.id, col: col)
            case .row(let row)?: return .tableRow(id: sh.id, row: row)
            case nil: break
            }
        }
        switch sh.kind {
        case .group(let children, let child):
            // A group is hit when any child is hit; the group is what gets selected.
            let ch = Rect(child.x, child.y, child.x + child.w, child.y + child.h)
            let q = groupChildAffine(x, ch).inverse * p
            for c in children.reversed() {
                guard let cx = c.xfrm else { continue }
                let cl = cx.affine.inverse * q
                if cl.x >= -tol && cl.y >= -tol && cl.x <= cx.w + tol && cl.y <= cx.h + tol { return .shape(id: sh.id, text: false) }
            }
            return nil
        case .ink(let strokes):
            for s in strokes where s.points.contains(where: { (Point($0.a, $0.b) - p).hypot <= tol + s.width }) {
                return .shape(id: sh.id, text: false)
            }
            return nil
        default:
            if sh.isLine {
                let geo = shapeGeometry(sh, x.w, x.h)
                let lw = sh.line?.width ?? 1.0
                return nearPath(geo.outline, local, tol.rustMax(lw)) ? .shape(id: sh.id, text: false) : nil
            }
            let inside = local.x >= -tol && local.y >= -tol && local.x <= x.w + tol && local.y <= x.h + tol
            if !inside { return nil }
            var isShape = false
            if case .shape = sh.kind { isShape = true }
            let hasText = isShape && ((sh.text.map { !$0.isEmpty } ?? false) || sh.ph != nil || sh.textBox)
            // Empty interiors of unfilled, text-less shapes don't catch clicks.
            var filled = true
            if case .none_? = sh.fill { filled = false }
            filled = filled || sh.style != nil
            let solid: Bool
            switch sh.kind {
            case .picture, .table, .chart, .media, .model3d, .opaque: solid = true
            default: solid = false
            }
            if hasText || sh.ph != nil || solid { return .shape(id: sh.id, text: hasText || isShape) }
            let outline = shapeGeometry(sh, x.w, x.h).outline
            let onEdge = nearPath(outline, local, tol)
            let inGeo = outline.winding(local) != 0 || onEdge
            if (filled && inGeo) || onEdge { return .shape(id: sh.id, text: hasText || isShape) }
            return nil
        }
    }
}

extension Session {
    /// What's under `p` on the current slide (`hit_test`): in Edit Points the edited shape's handles and
    /// vertices, then the handles of selected shapes, the frame of edited text, and shapes topmost first.
    public func hitTest(_ p: Point, _ tol: Double) -> Hit? {
        guard let st = activeDoc else { return nil }
        // In Edit Points, the edited shape's vertices come first.
        if let id = tool.editingPoints(st), let sh = st.shape(id) {
            if let (path, index) = tool.editVertex,
               let (hin, hout, _) = PointsCommands.slideHandles(st.doc, st.selection, sh, path, index) {
                for (h, out) in [(hout, true), (hin, false)] {
                    if let q = h, (q - p).hypot <= tol * 1.6 { return .handle(id: id, path: path, index: index, out: out) }
                }
            }
            if let (path, index) = PointsCommands.vertexAt(st.doc, st.selection, sh, p, tol * 1.6) {
                return .vertex(id: id, path: path, index: index)
            }
        }
        // Handles of selected shapes first.
        if st.selection.text == nil || st.selection.shapes.count == 1 {
            for id in st.selection.shapes.reversed() {
                guard let sh = st.shape(id) else { continue }
                // A locked object shows no live handles: it can't be sized, rotated or reshaped.
                if sh.locked { continue }
                let x = Cmd.xfrmOf(st.doc, st.selection, sh)
                let a = x.affine
                if sh.isLine {
                    for (end, q) in [(UInt8(0), a * Point(0, 0)), (UInt8(1), a * Point(x.w, x.h))] where (q - p).hypot <= tol * 1.6 {
                        return .lineEnd(id: id, end: end)
                    }
                    continue
                }
                let geo = shapeGeometry(sh, x.w, x.h)
                for hd in geo.handles where (a * hd.pos - p).hypot <= tol * 1.6 {
                    return .adjust(id: id, index: hd.index)
                }
                for hd in Tools.wordartHandles(st.doc, st.selection, sh, x.w, x.h) where (a * hd.pos - p).hypot <= tol * 1.6 {
                    return .warp(id: id, index: hd.index)
                }
                let (pts, rot) = Tools.boxHandles(x)
                if (rot - p).hypot <= tol * 1.8 && st.selection.text == nil { return .rotate(id: id) }
                for (i, q) in pts.enumerated() where (q - p).hypot <= tol * 1.6 {
                    return .resize(id: id, handle: UInt8(truncatingIfNeeded: i))
                }
            }
        }
        // The frame of the text being edited: grabbing it moves the box, unless a shape in front of the text
        // covers that spot (#931).
        if let e = Tools.editedBox(st), e.movable, Tools.editZone(e.xfrm, p, tol) == .frame,
           !Tools.shapeInFront(st, st.shapes, e.id, p, tol, 0) {
            return .frame(id: e.id)
        }
        // Shapes, topmost first. Locked objects are still picked (to format them or type in them); they just
        // don't move.
        for sh in st.shapes.reversed() where !sh.hidden {
            if let h = Tools.hitShape(st, sh, p, tol) { return h }
        }
        return nil
    }

    /// The drawing guide within `tol` of `p`, only while guides are shown (`guide_at`).
    public func guideAt(_ p: Point, _ tol: Double) -> Int? {
        guard tool.guidesVisible, let st = activeDoc else { return nil }
        var best: (Int, Double)?
        for (i, g) in st.doc.guides.enumerated() {
            let d = g.vertical ? abs(p.x - g.pos) : abs(p.y - g.pos)
            if d <= tol.rustMax(2.0) && (best.map { d < $0.1 } ?? true) { best = (i, d) }
        }
        return best?.0
    }
}
