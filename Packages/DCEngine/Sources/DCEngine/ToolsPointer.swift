// DCEngine — the pointer: `Session.pointer` feeds one press, drag, release, hover, double, triple or right
// click (slide points) to the active tool. Selecting, moving, duplicating, resizing, rotating and adjusting
// shapes, dragging line ends onto connection sites, table borders and drawing guides, placing the caret and
// selecting text, Edit Points, drawing shapes, text boxes, tables, freeforms and ink: each finished gesture is
// one undo step. The UI, the control channel and MCP all come through here. Port of deckcraft
// crates/engine/src/tools.rs (`Session::pointer` and the gesture handlers; MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel
import DCRender
import Darwin

extension Session {
    /// Feed a pointer event to the active tool (`pointer`). Returns what happened, for agents: `{hit}` for a
    /// press, `{caret}` in edited text, `{selected}` after a marquee, a command's answer when a gesture ran
    /// one, and null otherwise.
    public func pointer(_ ev: PointerEvent) throws(EngineError) -> JSON {
        let tol = ev.tol > 0 ? ev.tol : 4.0
        let p = Point(ev.x, ev.y)
        tool.pressure = ev.pressure.flatMap { $0.isFinite ? $0.clamped(0, 1) : nil }
        if !(p.x.isFinite && p.y.isFinite) { return .null }
        // A press (not a hover) settles an input method's composition, as clicking does in PowerPoint.
        if ev.kind != .move { settleComposition() }
        do {
            switch ev.kind {
            case .move:
                pointerMove(p, tol)
                return .null
            case .down:
                return try pointerDown(p, ev.mods, tol)
            case .drag:
                return try pointerDrag(p, ev.mods, tol)
            case .up:
                return try pointerUp(p)
            case .doubleClick:
                let before = textSelection()
                let r = try doubleClick(p, tol)
                return try paintIfSelectionChanged(before, r)
            case .contextClick:
                return try contextClick(p, tol)
            case .tripleClick:
                guard activeDoc?.selection.text != nil else { return .null }
                let before = textSelection()
                let r = try execute("text.selectParagraph", .emptyObject)
                return try paintIfSelectionChanged(before, r)
            }
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Hover: what's under the pointer, the guide under it and the connection sites a line tool would glue
    /// to; while a freeform is drawn, its rubber band.
    private func pointerMove(_ p: Point, _ tol: Double) {
        if case .freeform(let mode, let points, _) = tool.drag {
            let closing = points.count > 2 && (points.first.map { ($0 - p).hypot <= tol * 2.0 } ?? false)
            tool.pathPreview = points + [p]
            tool.pathSmooth = mode == "curve"
            tool.pathClosing = closing
            return
        }
        tool.hover = hitTest(p, tol)
        tool.guideHover = tool.hover == nil && tool.kind == .select ? guideAt(p, tol) : nil
        if case .shape(let preset) = tool.kind, Preset.isLineLike(preset) {
            _ = updateSites(p, tol, nil)
        } else {
            tool.sites.removeAll()
            tool.glue = nil
        }
    }

    // MARK: Format Painter and text selections

    /// Format Painter applies once a text range is selected (drag, word or paragraph click).
    private func paintTextSelection() throws -> JSON? {
        if painter != nil, try doc().selection.text?.isRange == true {
            return try execute("format.painterApply", .emptyObject)
        }
        return nil
    }

    /// Where the text selection is: its shape, cell or notes, anchor and caret.
    private func textSelection() -> TextTarget? {
        guard let t = activeDoc?.selection.text else { return nil }
        return (t.shape, t.cell, t.notes, t.anchor, t.caret)
    }

    private static func sameTarget(_ a: TextTarget?, _ b: TextTarget?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): x.0 == y.0 && x.1 == y.1 && x.2 == y.2 && x.3 == y.3 && x.4 == y.4
        default: false
        }
    }

    /// A double or triple click paints only the range it selected, not an older one it left alone.
    private func paintIfSelectionChanged(_ before: TextTarget?, _ r: JSON) throws -> JSON {
        if Self.sameTarget(textSelection(), before) { return r }
        return try paintTextSelection() ?? r
    }

    // MARK: Interactions

    /// End the open interaction: one undo step when it changed the presentation (`commit`).
    func commit() {
        guard let st = activeDoc, let i = st.interaction else { return }
        st.interaction = nil
        if i.doc !== st.docRef {
            pushUndo(st, HistoryEntry(label: i.label, doc: i.doc, selection: i.selection, vertexKind: i.vertexKind))
        }
    }

    // MARK: Press

    private func pointerDown(_ p: Point, _ mods: Mods, _ tol: Double) throws -> JSON {
        if case .freeform(let mode, var points, _) = tool.drag {
            // Next click of a freeform: close on the start point, else add a vertex.
            if points.count > 2, let s = points.first, (s - p).hypot <= tol * 2.0 {
                tool.drag = .freeform(mode: mode, points: points, pressed: false)
                return try finishFreeform(true)
            }
            points.append(p)
            tool.pathPreview = points
            tool.drag = .freeform(mode: mode, points: points, pressed: true)
            return .null
        }
        switch tool.kind {
        case .shape(let preset) where Tools.isFreeformTool(preset):
            tool.drag = .freeform(mode: preset, points: [p], pressed: true)
            tool.pathPreview = [p]
            tool.pathSmooth = preset == "curve"
            tool.pathClosing = false
            return .null
        case .shape(let preset) where preset == Tools.tableEraser:
            // Click a border to merge the cells on either side; elsewhere does nothing.
            return (try? execute("table.eraseLine", ["at": [.num(p.x), .num(p.y)], "tol": .num(tol.rustMax(4.0))])) ?? .null
        case .shape, .textBox:
            tool.drag = .create(start: p)
            tool.preview = Xfrm(p.x, p.y, 0, 0)
            return .null
        case .ink(let mode, _, _):
            if mode == "eraser" { return try eraseAt(p, tol) }
            let sample = inkSample(p)
            tool.drag = .ink(points: [sample])
            tool.inkPreview = [sample]
            return .null
        case .select:
            break
        }
        // Clicking inside the text being edited moves the caret / starts a text selection.
        let before = textSelection()
        if let (shape, pos) = try placeCaret(p, tol, mods.shift) {
            let press = try doc().selection.text
            tool.drag = .textSelect(shape: shape, before: before, press: press)
            return ["caret": [.integer(pos.0), .integer(pos.1)]]
        }
        let hit = hitTest(p, tol)
        // Edit Points: drag a vertex, Ctrl-click one to delete it or the outline to add one; a click anywhere
        // else leaves Edit Points.
        if let eid = activeDoc.flatMap({ tool.editingPoints($0) }) {
            if case .vertex(let id, let path, let index)? = hit {
                if mods.cmd {
                    return try execute("shape.deletePoint", ["id": id.toJSON(), "path": .integer(path), "index": .integer(index)])
                }
                tool.editVertex = (path, index)
                begin("Edit Points")
                tool.drag = .vertex(id: id, path: path, index: index)
                return ["vertex": [.integer(path), .integer(index)]]
            }
            if case .handle(let id, let path, let index, let out)? = hit {
                begin("Edit Points")
                tool.drag = .handle(id: id, path: path, index: index, out: out)
                return ["handle": [.integer(path), .integer(index)]]
            }
            let st = try doc()
            if let sh = st.shape(eid), let (path, seg, t) = PointsCommands.segmentAt(st.doc, st.selection, sh, p, tol * 1.6) {
                if mods.cmd {
                    return try execute("shape.addPoint", ["id": eid.toJSON(), "path": .integer(path), "segment": .integer(seg), "t": .num(t)])
                }
                return .null
            }
            tool.editPoints = nil
            tool.editVertex = nil
        }
        let st = try doc()
        func box(_ id: ShapeId) -> Xfrm { st.shape(id).map { Cmd.xfrmOf(st.doc, st.selection, $0) } ?? Xfrm() }
        switch hit {
        case .tableColumn(let id, let col)?:
            try beginTableBorder(id, true, col, p)
        case .tableRow(let id, let row)?:
            try beginTableBorder(id, false, row, p)
        case .resize(let id, let handle)?:
            let orig = box(id)
            begin("Size")
            tool.drag = .resize(id: id, handle: handle, orig: orig, start: p)
        case .lineEnd(let id, let end)?:
            let orig = box(id)
            begin("Size")
            tool.drag = .lineEnd(id: id, end: end, orig: orig)
        case .rotate(let id)?:
            let ids = st.selection.shapes.contains(id) ? st.selection.shapes : [id]
            let origs: [(ShapeId, Xfrm)] = ids.compactMap { i in st.shape(i).map { (i, Cmd.xfrmOf(st.doc, st.selection, $0)) } }
            let center = st.shape(id).map { Cmd.xfrmOf(st.doc, st.selection, $0).center } ?? p
            let start = Darwin.atan2(p.y - center.y, p.x - center.x)
            begin("Rotate")
            tool.drag = .rotate(ids: ids, center: center, start: start, origs: origs)
        case .vertex?, .handle?:
            // Only reached outside Edit Points (handled above).
            break
        case .adjust(let id, let index)?:
            let orig = box(id)
            begin("Adjust Shape")
            tool.drag = .adjust(id: id, index: index, orig: orig)
        case .frame(let id)?:
            // Like PowerPoint: the box leaves text editing and is selected whole (a click without a drag stops
            // there), and dragging moves it as one undo step.
            let origs: [(ShapeId, Xfrm)] = st.shape(id).map { [(id, Cmd.xfrmOf(st.doc, st.selection, $0))] } ?? []
            try select { _, sel in
                sel.shapes = [id]
                sel.text = nil
                sel.cells = nil
            }
            tool.drag = .move(ids: [id], start: p, origs: origs, moved: false, duplicate: mods.alt, enterText: nil)
        case .warp(let id, let index)?:
            let orig = box(id)
            var found: (String, [Double])?
            if let sh = st.shape(id), let ctx = TextCommands.ctxFor(st.doc, st.selection) {
                let bp = Resolve.body(ctx, sh)
                if let n = bp.warp { found = (n, bp.warpAdj) }
            }
            if let (name, base) = found {
                begin("Adjust WordArt")
                tool.drag = .warp(id: id, index: index, name: name, base: base, orig: orig)
            }
        case .shape(let id, _)? where !(mods.shift || mods.cmd) && st.selection.cells.map({ $0.table == id && st.selection.shapes == [id] }) == true
            && Tools.inTableCell(st, id, p):
            // A press in a table whose cells are selected starts again in the cell under the pointer: a click
            // puts the caret there and a drag selects another range. A press on the table outside its cells
            // selects and moves the table like any shape.
            let before = textSelection()
            if try editTextAt(id, p) {
                try select { _, sel in sel.cells = nil }
                let press = try doc().selection.text
                tool.drag = .textSelect(shape: id, before: before, press: press)
            }
        case .shape(let id, let text)?:
            try pressShape(st, id, text, p, mods, tol)
        case nil where guideAt(p, tol) != nil:
            // Away from every shape a press on a guide picks the guide up.
            if let index = guideAt(p, tol) {
                let pos = st.doc.guides.at(index)?.pos ?? 0
                tool.drag = .guide(index: index)
                tool.guideDrag = (index, pos)
            }
        case nil:
            let add = mods.shift || mods.cmd
            try select { _, sel in
                sel.text = nil
                sel.cells = nil
                if !add { sel.shapes.removeAll() }
            }
            tool.drag = .marquee(start: p, add: add)
            tool.marquee = Rect.fromPoints(p, p)
        }
        return ["hit": hit?.toJSON() ?? .null]
    }

    /// A press on shape `id`: select it (Shift or Cmd toggles it), get ready to move the selection or enter
    /// its text, and apply a Format or Animation Painter.
    private func pressShape(_ st: DocState, _ id: ShapeId, _ text: Bool, _ p: Point, _ mods: Mods, _ tol: Double) throws {
        let selected = st.selection.shapes.contains(id)
        let toggle = mods.shift || mods.cmd
        let ids: [ShapeId]
        if toggle {
            var v = st.selection.shapes
            if selected { v.removeAll { $0 == id } } else { v.append(id) }
            ids = v
        } else if selected {
            ids = st.selection.shapes
        } else {
            ids = [id]
        }
        // Locked objects stay put when the selection is dragged.
        let origs: [(ShapeId, Xfrm)] = ids.compactMap { i in
            guard let s = st.shape(i), !s.locked else { return nil }
            return (i, Cmd.xfrmOf(st.doc, st.selection, s))
        }
        // A click (no drag) on text puts the caret there; unselected text boxes and placeholders take the
        // caret straight away like PowerPoint. A click in a cell of a selected table puts the caret there; a
        // click on its grab band keeps the table selected.
        var table = false
        if let s = st.shape(id), case .table = s.kind { table = true }
        // A click on the frame band of a text box selects the box whole, as PowerPoint does, so it can be
        // moved, duplicated or deleted; only the inside takes the caret.
        let onFrame = text && Tools.isTextFirst(st, id)
            && (st.shape(id).map { Tools.editZone(Cmd.xfrmOf(st.doc, st.selection, $0), p, tol) == .frame } ?? false)
        let enters = !toggle && !onFrame
            && ((text && (selected || Tools.isTextFirst(st, id))) || (table && selected && Tools.inTableCell(st, id, p)))
        let enterText: (ShapeId, Point)? = enters ? (id, p) : nil
        try select { _, sel in
            sel.shapes = ids
            sel.text = nil
            sel.cells = nil
        }
        let duplicate = mods.alt && origs.count == ids.count
        tool.drag = .move(ids: ids, start: p, origs: origs, moved: false, duplicate: duplicate, enterText: enterText)
        // Format Painter applies on click.
        if painter != nil && !toggle { _ = try? execute("format.painterApply", ["ids": [id.toJSON()]]) }
        // Animation Painter applies on click.
        if animPainter != nil && !toggle { _ = try? execute("animation.painterApply", ["ids": [id.toJSON()]]) }
    }

    // MARK: Drag

    private func pointerDrag(_ p: Point, _ mods: Mods, _ tol: Double) throws -> JSON {
        guard let drag = tool.drag else { return .null }
        switch drag {
        case .guide(let index):
            let vertical = activeDoc?.doc.guides.at(index)?.vertical ?? false
            var pos = vertical ? p.x : p.y
            // Guides move in whole points unless snapping is off, as in PowerPoint.
            if prefs.snapToGrid && !mods.alt { pos = pos.rounded() }
            tool.guideDrag = (index, pos)
        case .move(let ids, let start, let origs, let moved, let duplicate, let enterText):
            try dragMove(p, mods, tol, ids, start, origs, moved, duplicate, enterText)
        case .resize(let id, let handle, let orig, let start):
            var nx = Tools.resizeBox(orig, handle, p - start, mods.shift || isPicture(id), mods.alt)
            nx = snapResize(nx, handle, id, tol)
            try setXfrm(id, nx)
        case .lineEnd(let id, let end, let orig):
            let a = orig.affine
            let (p0, p1) = (a * Point(0, 0), a * Point(orig.w, orig.h))
            var q = p
            let other = end == 0 ? p1 : p0
            if mods.shift { q = Tools.constrain45(other, q) }
            let glue = updateSites(q, tol, id)
            if let g = glue { q = g.2 }
            let (s0, s1) = end == 0 ? (q, p1) : (p0, q)
            try setXfrm(id, Tools.lineXfrm(s0, s1, orig.rot))
            try edit { doc, sel in
                mutateShapes(&doc, sel) { list in Connect.setGlue(&list, id, end, glue.map { Pair($0.0, $0.1) }) }
            }
        case .rotate(let ids, let center, let start, let origs):
            let ang = Darwin.atan2(p.y - center.y, p.x - center.x)
            var delta = (ang - start).toDegrees
            for (id, o) in origs {
                var r = o.rot + delta
                if mods.shift {
                    r = (r / 15.0).rounded() * 15.0
                    delta = r - o.rot
                }
                var nx = o
                nx.rot = (r.rem(360.0) + 360.0).rem(360.0)
                if ids.count > 1 {
                    // Rotate positions around the common centre too.
                    let c = o.center
                    let rc = Affine.translate(center.toVec2) * Affine.rotate(delta.toRadians) * Affine.translate(-center.toVec2) * c
                    nx.x = rc.x - o.w / 2.0
                    nx.y = rc.y - o.h / 2.0
                }
                try setXfrm(id, nx)
            }
        case .adjust(let id, let index, let orig):
            try dragAdjust(p, id, index, orig)
        case .vertex(let id, let path, let index):
            tool.drag = .vertex(id: id, path: path, index: index)
            // A failed move leaves the point where it was (deckcraft logs it).
            _ = try? PointsCommands.movePointRaw(self, id, path, index, p)
            return .null
        case .handle(let id, let path, let index, let out):
            tool.drag = .handle(id: id, path: path, index: index, out: out)
            let side = out ? "out" : "in"
            // Shift, Ctrl or Alt held while dragging a handle makes the point smooth, straight or corner, as
            // in PowerPoint; Cmd and Option count as Ctrl and Alt.
            let held: String? = mods.shift ? "smooth" : mods.cmd ? "straight" : mods.alt ? "corner" : nil
            _ = try? moveHandle(id, path, index, side, p, held)
            return .null
        case .warp(let id, let index, let name, let base, let orig):
            let st = try doc()
            guard let sh = st.shape(id) else { return .null }
            let tr = shapeGeometry(sh, orig.w, orig.h).textRect
            guard let h = Warp.handles(name, base, tr).first(where: { $0.index == index }) else { return .null }
            let v = h.valueAt(orig.affine.inverse * p)
            try edit { doc, sel in
                try withShapes(&doc, sel, missing: Cmd.bad("adjust", "no slide")) { list in
                    withShape(&list, id) { Tools.setWarpAdj(&$0, name, base, index, v) }
                }
            }
        case .marquee(let start, _):
            tool.marquee = Rect.fromPoints(start, p)
        case .create(let start):
            tool.preview = createPreview(start, p, mods, tol)
        case .textSelect(let shape, _, let press):
            try dragTextSelect(p, shape, press)
        case .tableBorder(let id, let column, let index, let start, let size, let frame, let moved):
            let local = frame.inverse * p
            let d = column ? local.x - start.x : local.y - start.y
            if !moved && abs(d) < tol.rustMax(1.0) { return .null }
            if !moved { begin(column ? "Column Width" : "Row Height") }
            // An inner column border moves between its two columns (the table keeps its width); the right
            // edge widens the last column and the table. A row's height is a minimum: rows still grow to fit
            // their text.
            if column {
                let width = (size + d).rustMax(TableCommands.minColumnWidth)
                _ = try execute("table.columnWidth", ["id": id.toJSON(), "col": .integer(index), "width": .num(width), "keepTotal": true])
            } else {
                _ = try execute("table.rowHeight", ["id": id.toJSON(), "row": .integer(index), "height": .num((size + d).rustMax(1.0))])
            }
            tool.drag = .tableBorder(id: id, column: column, index: index, start: start, size: size, frame: frame, moved: true)
        case .freeform(let mode, var points, let pressed):
            // Dragging scribbles (except for curves, which only take clicked points).
            if pressed && mode != "curve" && (points.last.map { ($0 - p).hypot >= 1.5 } ?? true) { points.append(p) }
            tool.pathPreview = mode == "curve" ? points + [p] : points
            tool.drag = .freeform(mode: mode, points: points, pressed: pressed)
        case .ink(var points):
            points.append(inkSample(p))
            tool.inkPreview = points
            tool.drag = .ink(points: points)
        }
        return .null
    }

    /// Dragging a selection: past the drag threshold it moves (Alt: a copy moves), Shift keeps it on an
    /// axis, smart guides snap its bounds, and connectors dragged away from shapes that stay come unglued.
    private func dragMove(_ p: Point, _ mods: Mods, _ tol: Double, _ ids: [ShapeId], _ start: Point, _ origs: [(ShapeId, Xfrm)],
                          _ moved: Bool, _ duplicate: Bool, _ enterText: (ShapeId, Point)?) throws {
        var d = p - start
        if !moved && (d.hypot < tol.rustMax(1.0) || origs.isEmpty) { return }
        if !moved {
            begin(duplicate ? "Duplicate" : "Move")
            // Alt-drag: drag a copy, leave the original.
            if duplicate { try duplicateInPlace(ids) }
        }
        let idsNow = try duplicate ? doc().selection.shapes : ids
        if mods.shift {
            if abs(d.x) > abs(d.y) { d = Vec2(d.x, 0) } else { d = Vec2(0, d.y) }
        }
        // Smart guides on the moved group's bounds.
        var bounds = Rect.zero
        if let first = origs.first {
            bounds = origs.dropFirst().reduce(first.1.bounds) { $0.union($1.1.bounds) }
        }
        let (snap, guides) = snapRect(Tools.offset(bounds, d), idsNow, tol * 1.5, !mods.cmd)
        d = d + snap
        tool.guides = guides
        let origs2: [(ShapeId, Xfrm)] = duplicate ? zip(idsNow, origs.map(\.1)).map { ($0, $1) } : origs
        let delta = d
        try edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("move", "no slide")) { list in
                for (id, o) in origs2 {
                    withShape(&list, id) { sh in
                        var x = o
                        x.x = o.x + delta.x
                        x.y = o.y + delta.y
                        sh.xfrm = x
                    }
                }
                // A connector dragged away from shapes that stay put comes unglued at those ends.
                let movedIds = origs2.map(\.0)
                for i in list.indices where movedIds.contains(list[i].id) {
                    guard case .connector(var s, var e) = list[i].kind else { continue }
                    if let c = s, !movedIds.contains(c.a) { s = nil }
                    if let c = e, !movedIds.contains(c.a) { e = nil }
                    list[i].kind = .connector(start: s, end: e)
                }
            }
        }
        tool.drag = .move(ids: idsNow, start: start, origs: origs2, moved: true, duplicate: false, enterText: nil)
    }

    /// Dragging an adjust handle: its value (a callout's tail moves freely in both).
    private func dragAdjust(_ p: Point, _ id: ShapeId, _ index: Int, _ orig: Xfrm) throws {
        let st = try doc()
        guard let sh = st.shape(id) else { return }
        let local = orig.affine.inverse * p
        let geo = shapeGeometry(sh, orig.w, orig.h)
        guard let h = geo.handles.first(where: { $0.index == index }) else { return }
        let free2d = sh.geom.presetName.map { $0.contains("Callout") && !$0.contains("Arrow") } ?? false
        let vals: [(Int, Double)]
        if free2d {
            let dx = (local.x - orig.w / 2.0) / orig.w.rustMax(1e-6) * 1e5
            let dy = (local.y - orig.h / 2.0) / orig.h.rustMax(1e-6) * 1e5
            vals = [(0, dx.rounded()), (1, dy.rounded())]
        } else {
            vals = [(index, h.valueAt(local))]
        }
        try edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("adjust", "no slide")) { list in
                withShape(&list, id) { sh in
                    guard case .preset(let name, var adj) = sh.geom else { return }
                    let defaults = Preset.info(name)?.defaults ?? []
                    for (i, v) in vals where i >= 0 && i < 64 {
                        while adj.count <= i { adj.append(defaults.at(adj.count) ?? 0.0) }
                        adj[i] = v
                    }
                    sh.geom = .preset(name: name, adj: adj)
                }
            }
        }
    }

    /// The box a drawing tool would make dragging from `start` to `p`: a line between them (snapped to
    /// connection sites, Shift: 45°), a table pencil's straight border, or a box (Shift: square, Alt: from the
    /// centre).
    private func createPreview(_ start: Point, _ p: Point, _ mods: Mods, _ tol: Double) -> Xfrm {
        if case .shape(let preset) = tool.kind, Preset.isLineLike(preset) {
            var q = mods.shift ? Tools.constrain45(start, p) : p
            if let g = updateSites(q, tol, nil) { q = g.2 }
            let s0 = glueAt(start, tol)?.2 ?? start
            return Tools.lineXfrm(s0, q, 0)
        }
        if case .shape(let preset) = tool.kind, preset == Tools.drawTable, TableCommands.tableAt(self, .null, (start.x, start.y)) != nil {
            // The pencil inside a table draws a straight border, across or down.
            let q = abs(p.x - start.x) >= abs(p.y - start.y) ? Point(p.x, start.y) : Point(start.x, p.y)
            let r = Rect.fromPoints(start, q)
            return Xfrm(r.x0, r.y0, r.width, r.height)
        }
        var r = Rect.fromPoints(start, p)
        if mods.shift {
            let s = r.width.rustMax(r.height)
            let sx = p.x < start.x ? -s : s
            let sy = p.y < start.y ? -s : s
            r = Rect.fromPoints(start, start + Vec2(sx, sy))
        }
        if mods.alt {
            let d = p - start
            r = Rect(start.x - abs(d.x), start.y - abs(d.y), start.x + abs(d.x), start.y + abs(d.y))
        }
        return Xfrm(r.x0, r.y0, r.width, r.height)
    }

    /// Dragging in text: the caret follows the pointer. In a table, leaving the cell the drag started in
    /// selects whole cells, as in PowerPoint; coming back to that cell selects text in it again.
    private func dragTextSelect(_ p: Point, _ shape: ShapeId, _ press: TextSel?) throws {
        let st = try doc()
        if let start = press?.cell, let f = st.shape(shape).flatMap({ TableCommands.tableFrame(st, $0) }),
           let (r, c) = f.cellAt(f.local(p)) {
            let cell = TextPoint(r, c)
            if cell != start {
                try select { _, sel in
                    sel.text = nil
                    sel.shapes = [shape]
                    sel.cells = CellRange(shape, start, cell)
                }
                return
            }
            if st.selection.text == nil {
                try select { _, sel in
                    sel.cells = nil
                    sel.text = press
                }
            }
        }
        let st2 = try doc()
        if let t = st2.selection.text, t.shape == shape {
            let pos = TextCommands.textPosAt(st2, t, p)
            try select { _, sel in sel.text?.caret = TextPoint(pos.0, pos.1) }
        }
    }

    /// Moves a control handle during a drag. `held` is the point type set by the modifier held during the
    /// drag; the point keeps that type for later drags, as after `shape.pointType`.
    private func moveHandle(_ id: ShapeId, _ path: Int, _ index: Int, _ side: String, _ p: Point, _ held: String?) throws -> JSON {
        var kind = held
        if kind == nil, let k = tool.vertexKind, k.shape == id, k.path == path, k.index == index { kind = k.kind }
        let r = try PointsCommands.moveHandleRaw(self, [
            "id": id.toJSON(), "path": .integer(path), "index": .integer(index), "side": .string(side),
            "x": .num(p.x), "y": .num(p.y), "type": kind.map { .string($0) } ?? .null,
        ])
        if let k = held { tool.vertexKind = VertexKind(id, path, index, k) }
        return r
    }

    // MARK: Release

    private func pointerUp(_ p: Point) throws -> JSON {
        let drag = tool.drag
        tool.drag = nil
        tool.guides.removeAll()
        tool.sites.removeAll()
        tool.glue = nil
        var out = JSON.null
        switch drag {
        case .guide(let index)?:
            // Dropped off the slide: the guide is deleted.
            let pos = tool.guideDrag?.1 ?? 0
            tool.guideDrag = nil
            let st = try doc()
            let size = st.doc.slideSize
            let vertical = st.doc.guides.at(index)?.vertical ?? false
            let limit = vertical ? size.width : size.height
            if pos < 0 || pos > limit {
                out = try execute("guide.delete", ["index": .integer(index)])
            } else {
                out = try execute("guide.move", ["index": .integer(index), "pos": .num(pos)])
            }
        case .move(_, _, _, false, _, let enter?)?:
            // Plain click on text: caret at the click (in a table, in the clicked cell).
            if try editTextAt(enter.0, enter.1) { out = ["editing": enter.0.toJSON()] }
        case .marquee(let start, let add)?:
            let r = Rect.fromPoints(start, p)
            tool.marquee = nil
            if r.width > 1.0 || r.height > 1.0 {
                let st = try doc()
                let ids = st.shapes
                    .filter { !$0.hidden && !$0.locked && Tools.containsRect(r, Cmd.xfrmOf(st.doc, st.selection, $0).bounds) }
                    .map(\.id)
                try select { _, sel in
                    if add {
                        for i in ids where !sel.shapes.contains(i) { sel.shapes.append(i) }
                    } else {
                        sel.shapes = ids
                    }
                }
                out = ["selected": ids.toJSON()]
            }
        case .create(let start)?:
            out = try finishCreate(start, p)
        case .freeform(let mode, let points, _)?:
            if mode == "scribble" {
                // A scribble ending back at its start closes into a filled shape.
                var closed = false
                if points.count > 3, let a = points.first, let b = points.last { closed = (a - b).hypot <= 6.0 }
                tool.drag = .freeform(mode: mode, points: points, pressed: false)
                return try finishFreeform(closed)
            }
            // Polygon / curve: keep going until double-click, Enter or a click on the start.
            tool.drag = .freeform(mode: mode, points: points, pressed: false)
            return .null
        case .ink(let points)?:
            tool.inkPreview.removeAll()
            if points.count > 1 {
                begin("Ink")
                out = try addInk(points)
            }
        case .resize(let id, _, _, _)?:
            commit()
            _ = try? TextCommands.fitTextBox(self, id)
            try refitAfterResize(id)
        case .textSelect(_, let before, _)?:
            out = try paintIfSelectionChanged(before, out)
            commit()
        case .some:
            commit()
        case nil:
            break
        }
        // Any open interaction (move etc.) ends here.
        commit()
        return out
    }

    /// Releasing a drawing tool: the shape, text box or table it drew (a click draws the default size).
    private func finishCreate(_ start: Point, _ p: Point) throws -> JSON {
        let kind = tool.kind
        let preview = tool.preview
        tool.preview = nil
        let dragged = (p - start).hypot > 2.0
        var res = JSON.null
        switch kind {
        case .shape(let preset) where preset == Tools.drawTable:
            // Inside a table: split cells along the line. Elsewhere: a one-cell table.
            if TableCommands.tableAt(self, .null, (start.x, start.y)) != nil {
                res = (try? execute("table.drawLine", ["from": [.num(start.x), .num(start.y)], "to": [.num(p.x), .num(p.y)]])) ?? .null
            } else if let x = preview, dragged && x.w >= 8.0 && x.h >= 8.0 {
                res = try execute("insert.table", ["rows": 1, "cols": 1, "rect": [.num(x.x), .num(x.y), .num(x.w), .num(x.h)]])
            }
        case .shape(let preset):
            let line = Preset.isLineLike(preset)
            let rect: Xfrm = if let x = preview, dragged { x } else if line { Xfrm(start.x, start.y, 72.0, 0.0) } else { Xfrm(start.x, start.y, 72.0, 72.0) }
            let flip = (rect.flipH ? "h" : "") + (rect.flipV ? "v" : "")
            let r = try execute("shape.insert", [
                "preset": .string(preset), "rect": [.num(rect.x), .num(rect.y), .num(rect.w), .num(rect.h)], "flip": .string(flip),
            ])
            if let raw = r.get("id")?.asU64, let x = preview, dragged && line {
                let id = ShapeId(UInt32(truncatingIfNeeded: raw))
                _ = try? setXfrmCommand(id, x)
                // Glue the ends that landed on connection sites.
                let (p0, p1) = Connect.endpoints(x)
                let (g0, g1) = (glueAt(p0, 4.0), glueAt(p1, 4.0))
                if g0 != nil || g1 != nil {
                    _ = try? edit { doc, sel in
                        mutateShapes(&doc, sel) { list in
                            Connect.setGlue(&list, id, 0, g0.map { Pair($0.0, $0.1) })
                            Connect.setGlue(&list, id, 1, g1.map { Pair($0.0, $0.1) })
                        }
                    }
                }
            }
            res = r
        case .textBox:
            let w = dragged ? preview?.w ?? 0 : 0
            let at = dragged ? preview.map { Point($0.x, $0.y) } ?? start : start
            res = try execute("insert.textBox", ["rect": [.num(at.x), .num(at.y), .num(w), 30.0]])
        default:
            break
        }
        // The table pencil stays on until you pick another tool, as in PowerPoint.
        var pencil = false
        if case .shape(let preset) = kind, preset == Tools.drawTable { pencil = true }
        if !tool.sticky && !pencil { tool.kind = .select }
        return res
    }

    // MARK: Double and right clicks

    private func doubleClick(_ p: Point, _ tol: Double) throws -> JSON {
        if case .freeform(let mode, var points, _) = tool.drag {
            // The double-click's own click added a duplicate vertex.
            while points.count > 2, (points[points.count - 1] - points[points.count - 2]).hypot <= tol { points.removeLast() }
            tool.drag = .freeform(mode: mode, points: points, pressed: false)
            return try finishFreeform(false)
        }
        if tool.kind != .select {
            // Double-click while drawing: lock drawing mode off.
            tool.sticky = false
            return .null
        }
        // The double-click's second press started a click (caret on release): this replaces it.
        if case .move(_, _, _, false, _, _)? = tool.drag { tool.drag = nil }
        // In the text being edited: select the word double-clicked.
        if try placeCaret(p, tol, false) != nil { return try execute("text.selectWord", .emptyObject) }
        guard case .shape(let id, _)? = hitTest(p, tol) else { return .null }
        let st = try doc()
        guard let sh = st.shape(id) else { return .null }
        var textual = false
        switch sh.kind {
        case .table, .shape, .connector: textual = !sh.isLine
        default: break
        }
        if textual {
            // Caret at the double-click (in a table, in the clicked cell), then select the word there.
            if try !editTextAt(id, p) { return .null }
            return try execute("text.selectWord", .emptyObject)
        }
        if case .group = sh.kind {
            // A group is a single selection unit, but its text stays editable: double-click reaches the
            // text-holding member under the cursor.
            guard let mid = Tools.textMemberAt(st, sh, p, tol), let msh = st.shape(mid), !msh.isLine else { return .null }
            let pos = Tools.textPos(st, msh, p)
            _ = try execute("text.edit", ["id": mid.toJSON(), "at": [.integer(pos.0), .integer(pos.1)]])
            return try execute("text.selectWord", .emptyObject)
        }
        uiRequests.append(.pane(id: "format"))
        return .null
    }

    /// Right-button press: the selection the context menu will act on, as in PowerPoint. In the box being
    /// edited, the caret and text selection stay (the menu then acts on the text). On a selected shape (or its
    /// handles) the selection stays, multiple selection included; on another shape, that shape alone is
    /// selected; on empty slide, nothing is. Never edits text, starts a drag or adds an undo step.
    private func contextClick(_ p: Point, _ tol: Double) throws -> JSON {
        if tool.kind != .select || tool.drag != nil { return .null }
        let st = try doc()
        // The same zone in which a left press places the caret (`pointerDown`).
        if let t = st.selection.text, !t.notes, t.cell == nil, let sh = st.shape(t.shape),
           Cmd.xfrmOf(st.doc, st.selection, sh).bounds.inflate(tol, tol).contains(p) {
            return ["hit": ["kind": "text", "id": t.shape.toJSON()], "selected": [t.shape.toJSON()], "editing": true]
        }
        let hit = hitTest(p, tol)
        let id = hit?.id
        // Edit Points: the point or else the segment under the pointer picks the menu.
        var picked: ((Int, Int)?, (Int, Int, Double)?)?
        if let eid = tool.editingPoints(st), let sh = st.shape(eid) {
            switch hit {
            case .vertex(_, let path, let index)?: picked = ((path, index), nil)
            case .handle?: picked = (nil, nil)
            default: picked = (nil, PointsCommands.segmentAt(st.doc, st.selection, sh, p, tol * 1.6))
            }
        }
        if !(id.map { st.selection.shapes.contains($0) } ?? false) {
            try select { _, sel in
                sel.text = nil
                sel.cells = nil
                sel.shapes = id.map { [$0] } ?? []
            }
        }
        if let (vertex, segment) = picked {
            // A control handle belongs to the picked point: its menu stays.
            if case .handle? = hit {} else { tool.editVertex = vertex }
            tool.editSegment = segment.map { ($0.0, $0.1) }
            tool.editSegmentT = segment?.2
        }
        let now = try doc()
        return ["hit": hit?.toJSON() ?? .null, "selected": now.selection.shapes.toJSON(), "editing": .bool(now.selection.text != nil)]
    }

    // MARK: Text

    /// A click at `p` inside the text being edited: the caret goes there (`extend`: the selection grows to
    /// it). In a table being edited, a click in another cell moves the caret into that cell. Returns the
    /// edited shape and the caret, or nil when `p` isn't in the edited text (or is on a handle or a table
    /// border).
    private func placeCaret(_ p: Point, _ tol: Double, _ extend: Bool) throws -> (ShapeId, TextPos)? {
        let st = try doc()
        guard var t = st.selection.text, !t.notes, let sh = st.shape(t.shape) else { return nil }
        // A text box: in its own (rotated) frame, short of the band that moves it (`Hit.frame`). A table cell:
        // anywhere over the table.
        let inside = t.cell == nil
            ? Tools.editedBox(st).map { Tools.editZone($0.xfrm, p, tol) != .outside } ?? false
            : Cmd.xfrmOf(st.doc, st.selection, sh).bounds.inflate(tol, tol).contains(p)
        // A shape in front of the edited text takes the click, as in PowerPoint (#931).
        let inFront = Tools.shapeInFront(st, st.shapes, t.shape, p, tol, 0)
        if !inside || inFront { return nil }
        switch hitTest(p, tol) {
        case .resize?, .rotate?, .adjust?, .warp?, .frame?, .tableColumn?, .tableRow?: return nil
        default: break
        }
        let oldCell = t.cell
        if oldCell != nil, let f = TableCommands.tableFrame(st, sh) {
            t.cell = f.cellAt(f.local(p)).map { TextPoint($0.0, $0.1) } ?? oldCell
        }
        let pos = TextCommands.textPosAt(st, t, p)
        // A selection can't span cells: a click in another cell starts afresh.
        let extend = extend && t.cell == oldCell
        let cell = t.cell
        try select { _, sel in
            guard var tt = sel.text else { return }
            tt.cell = cell
            tt.caret = TextPoint(pos.0, pos.1)
            if !extend { tt.anchor = TextPoint(pos.0, pos.1) }
            sel.text = tt
        }
        return (t.shape, pos)
    }

    /// Start editing shape `id`'s text with the caret at slide point `p`; for a table, in the cell at `p`.
    /// Returns whether editing started.
    private func editTextAt(_ id: ShapeId, _ p: Point) throws -> Bool {
        let st = try doc()
        guard let sh = st.shape(id) else { return false }
        let params: JSON
        if let f = TableCommands.tableFrame(st, sh) {
            guard let (r, c) = f.cellAt(f.local(p)) else { return false }
            let pos = TextCommands.textPosAt(st, TextSel(shape: id, cell: TextPoint(r, c)), p)
            params = ["id": id.toJSON(), "cell": [.integer(r), .integer(c)], "at": [.integer(pos.0), .integer(pos.1)]]
        } else {
            let pos = Tools.textPos(st, sh, p)
            params = ["id": id.toJSON(), "at": [.integer(pos.0), .integer(pos.1)]]
        }
        _ = try execute("text.edit", params)
        return true
    }

    /// Press on a table border: dragging it resizes the column or row. Editing a cell of the table goes on;
    /// otherwise the table becomes the selection.
    private func beginTableBorder(_ id: ShapeId, _ column: Bool, _ index: Int, _ p: Point) throws {
        let st = try doc()
        guard let f = st.shape(id).flatMap({ TableCommands.tableFrame(st, $0) }) else { return }
        let size = (column ? f.cols.at(index) : f.heights.at(index)) ?? 0
        let (start, frame) = (f.local(p), f.affine)
        if st.selection.text?.shape != id {
            try select { _, sel in
                sel.shapes = [id]
                sel.text = nil
                sel.cells = nil
            }
        }
        tool.drag = .tableBorder(id: id, column: column, index: index, start: start, size: size, frame: frame, moved: false)
    }

    // MARK: Shapes

    private func isPicture(_ id: ShapeId) -> Bool {
        guard let s = activeDoc?.shape(id) else { return false }
        switch s.kind {
        case .picture, .media: return true
        default: return false
        }
    }

    /// The connection site within glue range of `p`.
    private func glueAt(_ p: Point, _ tol: Double) -> (ShapeId, UInt32, Point)? {
        guard let st = activeDoc else { return nil }
        return Connect.nearestSite(st.doc, st.selection, st.shapes, p, (tol * 2.0).rustMax(6.0), nil)
    }

    /// Show the sites of the shape near `p` and return the site an end at `p` would glue to (`exclude`: the
    /// connector being drawn).
    private func updateSites(_ p: Point, _ tol: Double, _ exclude: ShapeId?) -> (ShapeId, UInt32, Point)? {
        var sites: [Point] = []
        var glue: (ShapeId, UInt32, Point)?
        if let st = activeDoc {
            let shapes = st.shapes
            let near = Connect.siteShapeAt(st.doc, st.selection, shapes, p, tol * 3.0, exclude)
            if let id = near, let s = shapes.first(where: { $0.id == id }) { sites = Connect.sites(st.doc, st.selection, s) }
            glue = Connect.nearestSite(st.doc, st.selection, shapes, p, (tol * 2.0).rustMax(6.0), exclude)
        }
        tool.sites = sites
        tool.glue = glue?.2
        return glue
    }

    /// Set shape `id`'s box during a drag. A table's columns and rows scale with it, rows from their drawn
    /// heights (a stored height is only a minimum, often 0).
    private func setXfrm(_ id: ShapeId, _ x: Xfrm) throws {
        var drawn: [Double]?
        if let st = activeDoc, let sh = st.shape(id), case .table(let t) = sh.kind { drawn = Tools.tableRows(st, t) }
        try edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("tool", "no slide")) { list in
                withShape(&list, id) { sh in
                    sh.xfrm = x
                    guard case .table(var t) = sh.kind else { return }
                    // Tables resize their columns and rows proportionally.
                    let heights: [Double] = if let d = drawn, d.count == t.rows.count { d } else { t.rows.map(\.height) }
                    let tw = t.width.rustMax(1e-6)
                    let th = heights.reduce(-0.0) { $0 + $1.rustMax(0) }
                    let kx = x.w / tw
                    for i in t.cols.indices { t.cols[i] *= kx }
                    if th > 1e-6 {
                        let ky = x.h / th
                        for (i, h) in zip(t.rows.indices, heights) { t.rows[i].height = h.rustMax(0) * ky }
                    }
                    sh.kind = .table(t)
                }
            }
        }
    }

    /// Set a drawn line's box through `shape.setBounds`, then its flips (which way it runs).
    private func setXfrmCommand(_ id: ShapeId, _ x: Xfrm) throws -> JSON {
        _ = try execute("shape.setBounds", ["id": id.toJSON(), "x": .num(x.x), "y": .num(x.y), "w": .num(x.w), "h": .num(x.h)])
        if x.flipH || x.flipV {
            try edit { doc, sel in
                mutateShapes(&doc, sel) { list in
                    withShape(&list, id) { sh in
                        guard var xx = sh.xfrm else { return }
                        xx.flipH = x.flipH
                        xx.flipV = x.flipV
                        sh.xfrm = xx
                    }
                }
            }
        }
        return .null
    }

    /// A text box resized by hand keeps wrapping at its new width.
    private func refitAfterResize(_ id: ShapeId) throws {
        if try doc().shape(id)?.textBox == true { _ = try? TextCommands.fitTextBox(self, id) }
    }

    /// Alt-drag's copies: the shapes `ids` duplicated where they are (new ids, boxes made explicit), and
    /// selected.
    private func duplicateInPlace(_ ids: [ShapeId]) throws {
        try edit { doc, sel in
            let list = Cmd.currentShapes(doc, sel) ?? []
            var copies = list.filter { ids.contains($0.id) }
            let boxes = copies.map { Cmd.xfrmOf(doc, sel, $0) }
            _ = try EditCommands.reid("edit.duplicate", &doc, &copies)
            for (i, b) in zip(copies.indices, boxes) {
                copies[i].xfrm = b
                copies[i].ph = nil
            }
            let newIds = copies.map(\.id)
            let added = copies
            try withShapes(&doc, sel, missing: Cmd.bad("duplicate", "no slide")) { $0.append(contentsOf: added) }
            sel.shapes = newIds
        }
    }

    // MARK: Ink

    /// One ink sample. No device reading is full pen width (`1`).
    private func inkSample(_ p: Point) -> (Double, Double, Float) {
        let pressure: Float = if let v = tool.pressure, v.isFinite { v.clamped(0, 1) } else { 1.0 }
        return (p.x, p.y, pressure)
    }

    /// Add a pen or highlighter stroke to the slide's ink layer (one ink shape per slide).
    private func addInk(_ points: [(Double, Double, Float)]) throws -> JSON {
        guard case .ink(let mode, let color, let width) = tool.kind else { return .null }
        let stroke = InkStroke(points: points.map { Triple($0.0, $0.1, $0.2) }, color: color, width: width, highlighter: mode == "highlighter")
        let existing = try doc().shapes.last(where: { if case .ink = $0.kind { true } else { false } })?.id
        return try edit { doc, sel in
            let id: ShapeId
            if let e = existing {
                id = e
            } else {
                guard let raw = doc.allocId() else { throw Cmd.bad("ink.draw", Cmd.noIdSpace) }
                id = ShapeId(raw)
                let size = doc.slideSize
                try withShapes(&doc, sel, missing: Cmd.bad("ink", "no slide")) { list in
                    var s = Shape.default
                    s.id = id
                    s.name = "Ink"
                    s.xfrm = Xfrm(0, 0, size.width, size.height)
                    s.kind = .ink(strokes: [])
                    list.append(s)
                }
            }
            try withShapes(&doc, sel, missing: Cmd.bad("ink", "no slide")) { list in
                withShape(&list, id) { sh in
                    guard case .ink(var strokes) = sh.kind else { return }
                    strokes.append(stroke)
                    sh.kind = .ink(strokes: strokes)
                }
            }
            return ["ink": id.toJSON()]
        }
    }

    /// The eraser: strokes of the slide's ink layer that pass within reach of `p` go, as one undo step.
    private func eraseAt(_ p: Point, _ tol: Double) throws -> JSON {
        let st = try doc()
        guard let ink = st.shapes.last(where: { if case .ink = $0.kind { true } else { false } })?.id else { return .null }
        let before = st.docRef
        let selBefore = st.selection
        try edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("ink", "no slide")) { list in
                withShape(&list, ink) { sh in
                    guard case .ink(var strokes) = sh.kind else { return }
                    strokes.removeAll { s in s.points.contains { (Point($0.a, $0.b) - p).hypot <= tol * 2.0 + s.width } }
                    sh.kind = .ink(strokes: strokes)
                }
            }
        }
        let vertexKind = tool.vertexKind
        if let st = activeDoc { pushUndo(st, HistoryEntry(label: "Erase", doc: before, selection: selBefore, vertexKind: vertexKind)) }
        return .null
    }
}
