// DCEngine — the `arrange` command module: order, group, align, distribute, rotate and flip, and the
// drawing guides.
// Port of deckcraft crates/engine/src/cmd/arrange.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCGeometry
import DCModel

public enum ArrangeCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("guide.add", "Add Guide", ["View", "Show", "Guides"], nil, "{vertical: bool, pos?: pt (default: the slide's centre)} → {index}. `defaults: true` adds the two centre guides when there are none", Cmd.hasDoc, guideAdd),
            .cmd("guide.move", "Move Guide", [], nil, "{index, pos: pt}", Cmd.hasDoc, guideMove),
            .cmd("guide.delete", "Delete Guide", [], nil, "{index}", Cmd.hasDoc, guideDelete),
            .query("guide.list", "Guides", [], nil, "{} → [{vertical, pos}]", Cmd.hasDoc, guideList),
            .cmd("arrange.bringToFront", "Bring to Front", ["Arrange"], "Cmd+Shift+]", "{ids?}", Cmd.hasSelection) { s, p in try order(s, p, 2) },
            .cmd("arrange.bringForward", "Bring Forward", ["Arrange"], "Cmd+]", "{ids?}", Cmd.hasSelection) { s, p in try order(s, p, 1) },
            .cmd("arrange.sendBackward", "Send Backward", ["Arrange"], "Cmd+[", "{ids?}", Cmd.hasSelection) { s, p in try order(s, p, -1) },
            .cmd("arrange.sendToBack", "Send to Back", ["Arrange"], "Cmd+Shift+[", "{ids?}", Cmd.hasSelection) { s, p in try order(s, p, -2) },
            .cmd("arrange.reorder", "Reorder Objects", ["Arrange"], nil, "{id, index: position among its siblings (0 = back; a group's child stays in its group)} → {index}", Cmd.hasSlide, reorder),
            .cmd("arrange.group", "Group", ["Arrange"], "Cmd+Alt+G", "{ids?}", Cmd.hasTwo, group),
            .cmd("arrange.ungroup", "Ungroup", ["Arrange"], "Cmd+Alt+Shift+G", "{ids?}", Cmd.hasSelection, ungroup),
            .cmd("arrange.regroup", "Regroup", ["Arrange"], "Cmd+Alt+J", "{}", Cmd.hasDoc, regroup),
            .cmd("arrange.align", "Align", ["Arrange", "Align or Distribute"], nil, "{edge: left|center|right|top|middle|bottom, to?: slide|selection (default: slide for one object), ids?}", Cmd.hasSelection, align),
            .cmd("arrange.distribute", "Distribute", ["Arrange", "Align or Distribute"], nil, "{dir: horizontal|vertical, to?: slide|selection, ids?}", Cmd.hasSelection, distribute),
            .cmd("arrange.rotateLeft", "Rotate Left 90°", ["Arrange", "Rotate or Flip"], nil, "{ids?}", Cmd.hasSelection) { s, p in
                try s.execute("shape.rotate", Cmd.withParam(p, "by", .double(-90)))
            },
            .cmd("arrange.rotateRight", "Rotate Right 90°", ["Arrange", "Rotate or Flip"], nil, "{ids?}", Cmd.hasSelection) { s, p in
                try s.execute("shape.rotate", Cmd.withParam(p, "by", .double(90)))
            },
            .cmd("arrange.flipHorizontal", "Flip Horizontal", ["Arrange", "Rotate or Flip"], nil, "{ids?}", Cmd.hasSelection) { s, p in
                try s.execute("shape.flip", Cmd.withParam(p, "axis", "horizontal"))
            },
            .cmd("arrange.flipVertical", "Flip Vertical", ["Arrange", "Rotate or Flip"], nil, "{ids?}", Cmd.hasSelection) { s, p in
                try s.execute("shape.flip", Cmd.withParam(p, "axis", "vertical"))
            },
            .cmd("arrange.nudge", "Nudge", [], nil, "{dx, dy, ids?} (arrow keys: 6 pt, with Alt 1 pt)", Cmd.hasSelection) { s, p in
                try s.execute("shape.move", p)
            },
        ]
    }

    // MARK: Order

    static func order(_ s: Session, _ p: JSON, _ how: Int) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        // Already in place (front of its group, say): no change and no undo step.
        var trial = try s.doc().shapes
        orderTree(&trial, ids, how, 0)
        if stacking(trial) == stacking(try s.doc().shapes) { return Cmd.ok() }
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("arrange", "no slide")) { orderTree(&$0, ids, how, 0) }
        }
        return Cmd.ok()
    }

    /// Every shape id with its depth, in tree order.
    static func stacking(_ v: [Shape]) -> [[UInt32]] {
        var out: [[UInt32]] = []
        walk(v) { sh, d in out.append([sh.id.rawValue, UInt32(truncatingIfNeeded: d)]) }
        return out
    }

    /// Restack `ids` among their siblings, in every list of the tree: a shape inside a group moves within its
    /// group and never leaves it (PowerPoint's Selection pane arrows work the same way).
    static func orderTree(_ list: inout [Shape], _ ids: [ShapeId], _ how: Int, _ depth: Int) {
        if depth > 64 { return }
        if list.contains(where: { ids.contains($0.id) }) { orderList(&list, ids, how) }
        for i in list.indices {
            list[i].mutateChildren { orderTree(&$0, ids, how, depth + 1) }
        }
    }

    static func orderList(_ list: inout [Shape], _ ids: [ShapeId], _ how: Int) {
        func has(_ i: Int) -> Bool? { list.at(i).map { ids.contains($0.id) } }
        switch how {
        case 2:
            let moved = list.filter { ids.contains($0.id) }
            let rest = list.filter { !ids.contains($0.id) }
            list = rest + moved
        case -2:
            let moved = list.filter { ids.contains($0.id) }
            let rest = list.filter { !ids.contains($0.id) }
            list = moved + rest
        case 1:
            var i = list.count - 1
            while i >= 1 {
                // i runs over (0..len-1).rev() shifted by one: compare i-1 and i.
                let k = i - 1
                if has(k) == true && has(k + 1) == false { list.swapAt(k, k + 1) }
                i -= 1
            }
        default:
            var i = 1
            while i < list.count {
                if has(i - 1) == false && has(i) == true { list.swapAt(i - 1, i) }
                i += 1
            }
        }
    }

    /// Move one shape to `index` among its siblings (0 = back): the Selection pane's drag and drop. A shape
    /// stays in the list that holds it, so a group's child stays in its group.
    @Sendable static func reorder(_ s: Session, _ p: JSON) throws -> JSON {
        guard let id = try Cmd.idParam(p, "id", "arrange.reorder") else { throw Cmd.bad("arrange.reorder", "missing `id`") }
        guard let to = Cmd.usizeParam(p, "index") else { throw Cmd.bad("arrange.reorder", "missing `index`") }
        let st = try s.doc()
        let siblings: [Shape]
        switch parentOf(st.shapes, id) {
        case nil: throw Cmd.bad("arrange.reorder", "no such shape")
        case .some(nil): siblings = st.shapes
        case .some(let g?): siblings = st.shape(g)?.children ?? []
        }
        guard let from = siblings.firstIndex(where: { $0.id == id }) else { throw Cmd.bad("arrange.reorder", "no such shape") }
        if from == min(to, max(siblings.count - 1, 0)) { return ["index": .integer(from)] }
        return try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("arrange.reorder", "no slide")) { tree in
                let r: JSON? = try mutateSiblings(&tree, id) { list in
                    guard let i = list.firstIndex(where: { $0.id == id }) else { throw Cmd.bad("arrange.reorder", "no such shape") }
                    let sh = list.remove(at: i)
                    let at = min(to, list.count)
                    list.insert(sh, at: at)
                    return ["index": .integer(at)]
                }
                guard let r else { throw Cmd.bad("arrange.reorder", "no such shape") }
                return r
            }
        }
    }

    // MARK: Group

    /// How deep groups may nest: as deep as the PPTX reader reads and the renderer draws. A saved .deckcraft
    /// file stops opening at about 39 (the JSON reader's recursion limit), and walks over the shape tree stop
    /// at 64.
    public static let maxGroupDepth = 32

    /// How many groups deep `shapes` nest (0 without groups).
    static func groupDepth(_ shapes: [Shape]) -> Int {
        var d = 0
        walk(shapes) { sh, depth in if sh.isGroup { d = max(d, depth + 1) } }
        return d
    }

    @Sendable static func group(_ s: Session, _ p: JSON) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        return try s.edit { doc, sel in
            let current = Cmd.currentShapes(doc, sel) ?? []
            var members = current.filter { ids.contains($0.id) }
            if members.count < 2 { throw Cmd.bad("arrange.group", "select two or more objects on the slide") }
            if groupDepth(members) + 1 > maxGroupDepth {
                throw Cmd.bad("arrange.group", "groups can be nested at most \(maxGroupDepth) deep")
            }
            for i in members.indices {
                if members[i].xfrm == nil { members[i].xfrm = Cmd.xfrmOf(doc, sel, members[i]) }
                // Placeholders lose their link when grouped (PowerPoint keeps them out of groups).
                members[i].ph = nil
            }
            guard let b = unionBounds(members.compactMap(\.xfrm)) else { throw Cmd.bad("arrange.group", "nothing to group") }
            let gx = Xfrm(b.x0, b.y0, b.width, b.height)
            guard let raw = doc.allocId() else { throw Cmd.bad("arrange.group", Cmd.noIdSpace) }
            let id = ShapeId(raw)
            let n = Cmd.currentShapes(doc, sel)?.count ?? 0
            var g = Shape.default
            g.id = id
            g.name = "Group \(n + 1)"
            g.xfrm = gx
            g.kind = .group(children: members, child: gx)
            try withShapes(&doc, sel, missing: Cmd.bad("arrange.group", "no slide")) { list in
                let at = list.lastIndex(where: { ids.contains($0.id) }) ?? list.count
                list.insert(g, at: at + 1)
                list.removeAll { ids.contains($0.id) }
            }
            sel.shapes = [id]
            return ["id": id.toJSON()]
        }
    }

    /// A child's xfrm in slide space, given its group.
    public static func childToParent(_ group: Xfrm, _ ch: Xfrm, _ c: Xfrm) -> Xfrm {
        let sx = Swift.abs(ch.w) > 1e-9 ? group.w / ch.w : 1
        let sy = Swift.abs(ch.h) > 1e-9 ? group.h / ch.h : 1
        let a = groupChildAffine(group, Rect(ch.x, ch.y, ch.x + ch.w, ch.y + ch.h))
        let center = a * Point(c.x + c.w / 2, c.y + c.h / 2)
        let (w, h) = (c.w * Swift.abs(sx), c.h * Swift.abs(sy))
        var rot = c.rot + group.rot
        var (fh, fv) = (c.flipH, c.flipV)
        if group.flipH {
            fh.toggle()
            rot = -c.rot + group.rot
        }
        if group.flipV {
            fv.toggle()
            rot = -rot + 2 * group.rot
        }
        return Xfrm(x: center.x - w / 2, y: center.y - h / 2, w: w, h: h, rot: (rot.rem(360) + 360).rem(360), flipH: fh, flipV: fv)
    }

    @Sendable static func ungroup(_ s: Session, _ p: JSON) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        return try s.edit { doc, sel in
            var newSel: [ShapeId] = []
            try withShapes(&doc, sel, missing: Cmd.bad("arrange.ungroup", "no slide")) { list in
                var out: [Shape] = []
                out.reserveCapacity(list.count)
                for sh in list {
                    if ids.contains(sh.id), case .group(let children, let child) = sh.kind, let gx = sh.xfrm {
                        for var c in children {
                            if let cx = c.xfrm { c.xfrm = childToParent(gx, child, cx) }
                            // Nested groups scale too: their child space stays, their box is mapped.
                            newSel.append(c.id)
                            out.append(c)
                        }
                        continue
                    }
                    out.append(sh)
                }
                list = out
            }
            sel.shapes = newSel
            return ["ids": newSel.toJSON()]
        }
    }

    @Sendable static func regroup(_ s: Session, _ p: JSON) throws -> JSON {
        // Regroup the most recently ungrouped objects (from the undo history).
        let st = try s.doc()
        guard st.history.undo.contains(where: { $0.label == "Ungroup" }) else { throw Cmd.bad("arrange.regroup", "nothing to regroup") }
        // The ungroup's selection held the group id; its children are the current selection when nothing
        // else changed.
        let ids = try s.doc().selection.shapes
        if ids.count >= 2 { return try s.execute("arrange.group", ["ids": ids.toJSON()]) }
        throw Cmd.bad("arrange.regroup", "nothing to regroup")
    }

    // MARK: Align and distribute

    @Sendable static func align(_ s: Session, _ p: JSON) throws -> JSON {
        let edge = Cmd.strParam(p, "edge") ?? "left"
        let ids = try Cmd.targets(s, p)
        let st = try s.doc()
        let size = st.doc.slideSize
        let boxes: [(ShapeId, Xfrm)] = ids.compactMap { id in st.shape(id).map { (id, Cmd.xfrmOf(st.doc, st.selection, $0)) } }
        let toSlide: Bool
        switch Cmd.strParam(p, "to") {
        case "slide"?: toSlide = true
        case .some: toSlide = false
        case nil: toSlide = boxes.count < 2
        }
        let reference = toSlide ? Rect(0, 0, size.width, size.height) : (unionBounds(boxes.map(\.1)) ?? .zero)
        return try Cmd.editGeometry(s, p, "arrange.align") { sh in
            guard var x = sh.xfrm else { return }
            let b = x.bounds
            let (dx, dy): (Double, Double) = switch edge {
            case "left": (reference.x0 - b.x0, 0)
            case "center": (reference.center.x - b.center.x, 0)
            case "right": (reference.x1 - b.x1, 0)
            case "top": (0, reference.y0 - b.y0)
            case "middle": (0, reference.center.y - b.center.y)
            case "bottom": (0, reference.y1 - b.y1)
            default: (0, 0)
            }
            x.x += dx
            x.y += dy
            sh.xfrm = x
        }
    }

    @Sendable static func distribute(_ s: Session, _ p: JSON) throws -> JSON {
        let horiz = !(Cmd.strParam(p, "dir") ?? "horizontal").hasPrefix("v")
        let ids = try Cmd.targets(s, p)
        let st = try s.doc()
        let size = st.doc.slideSize
        var boxes: [(ShapeId, Rect)] = ids.compactMap { id in st.shape(id).map { (id, Cmd.xfrmOf(st.doc, st.selection, $0).bounds) } }
        let toSlide = Cmd.strParam(p, "to") == "slide" || boxes.count < 3
        if boxes.isEmpty { return Cmd.ok() }
        // `sort_by(total_cmp)`: a stable sort.
        boxes = boxes.enumerated().sorted { a, b in
            let (x, y) = horiz ? (a.element.1.x0, b.element.1.x0) : (a.element.1.y0, b.element.1.y0)
            if x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
        let total = boxes.reduce(0.0) { $0 + (horiz ? $1.1.width : $1.1.height) }
        let (start, end): (Double, Double)
        if toSlide {
            (start, end) = horiz ? (0, size.width) : (0, size.height)
        } else {
            let lo = boxes.map { horiz ? $0.1.x0 : $0.1.y0 }.reduce(Double.infinity) { $0.rustMin($1) }
            let hi = boxes.map { horiz ? $0.1.x1 : $0.1.y1 }.reduce(-Double.infinity) { $0.rustMax($1) }
            (start, end) = (lo, hi)
        }
        let n = boxes.count
        let gap = n > 1 ? ((end - start) - total) / Double(n - 1) : 0
        var targetsPos: [(ShapeId, Double)] = []
        var cur = start
        if n == 1 {
            let b = boxes.first?.1 ?? .zero
            cur = start + ((end - start) - (horiz ? b.width : b.height)) / 2
        }
        for (id, b) in boxes {
            let d = cur - (horiz ? b.x0 : b.y0)
            targetsPos.append((id, d))
            cur += (horiz ? b.width : b.height) + gap
        }
        return try Cmd.editGeometry(s, p, "arrange.distribute") { sh in
            guard var x = sh.xfrm, let (_, d) = targetsPos.first(where: { $0.0 == sh.id }) else { return }
            if horiz { x.x += d } else { x.y += d }
            sh.xfrm = x
        }
    }

    // MARK: Guides

    /// Guides are kept on the slide; a file can hold at most this many.
    static let maxGuides = 200

    static func guideLimit(_ s: Session, _ vertical: Bool) throws -> Double {
        let size = try s.doc().doc.slideSize
        return vertical ? size.width : size.height
    }

    @Sendable static func guideAdd(_ s: Session, _ p: JSON) throws -> JSON {
        if Cmd.boolOr(p, "defaults", false) {
            if try !s.doc().doc.guides.isEmpty { return ["added": 0] }
            let size = try s.doc().doc.slideSize
            return try s.edit { doc, _ in
                doc.guides = [DrawGuide(vertical: true, pos: size.width / 2), DrawGuide(vertical: false, pos: size.height / 2)]
                return ["added": 2]
            }
        }
        let vertical = Cmd.boolOr(p, "vertical", true)
        let limit = try guideLimit(s, vertical)
        let pos = (p.get("pos")?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? limit / 2).clamped(0, limit)
        if try s.doc().doc.guides.count >= maxGuides { throw Cmd.bad("guide.add", "too many guides") }
        return try s.edit { doc, _ in
            doc.guides.append(DrawGuide(vertical: vertical, pos: pos))
            return ["index": .integer(doc.guides.count - 1)]
        }
    }

    static func guideIndex(_ s: Session, _ p: JSON, _ cmd: String) throws -> Int {
        guard let i = Cmd.usizeParam(p, "index") else { throw Cmd.bad(cmd, "missing `index`") }
        if try i >= s.doc().doc.guides.count { throw Cmd.bad(cmd, "no such guide") }
        return i
    }

    @Sendable static func guideMove(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try guideIndex(s, p, "guide.move")
        let vertical = try s.doc().doc.guides.at(i)?.vertical ?? false
        let limit = try guideLimit(s, vertical)
        guard let raw = p.get("pos")?.asF64, raw.isFinite else { throw Cmd.bad("guide.move", "missing `pos`") }
        let pos = raw.clamped(0, limit)
        return try s.edit { doc, _ in
            if doc.guides.indices.contains(i) { doc.guides[i].pos = pos }
            return ["index": .integer(i), "pos": .num(pos)]
        }
    }

    @Sendable static func guideDelete(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try guideIndex(s, p, "guide.delete")
        return try s.edit { doc, _ in
            if i < doc.guides.count { doc.guides.remove(at: i) }
            return Cmd.ok()
        }
    }

    @Sendable static func guideList(_ s: Session, _ p: JSON) throws -> JSON {
        try s.doc().doc.guides.toJSON()
    }
}

// MARK: - Called by the core (cmd/edit.rs). Keep these signatures.

extension ArrangeCommands {
    /// Bounds of shapes, rotation included (`union_bounds`). Ported by the core.
    static func unionBounds(_ xs: [Xfrm]) -> Rect? {
        guard let first = xs.first else { return nil }
        return xs.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }
}
