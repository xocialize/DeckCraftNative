// DCEngine — the Selection pane: picking objects from the list, Show All and Hide All. Its other actions
// are ordinary commands: `shape.visible` (eye), `shape.lock` (padlock), `shape.rename`,
// `arrange.bringForward` / `arrange.sendBackward` (arrows) and `arrange.reorder` (drag and drop).
// Port of deckcraft crates/engine/src/cmd/selection.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
import DCModel

public enum SelectionCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "selection.select",
                "Select",
                ["Selection Pane"],
                nil,
                "{ids | id, toggle?: bool (Ctrl+click), add?: bool} → {selected}: objects in groups too; a hidden object picked from the list is shown",
                Cmd.hasSlide,
                select
            ),
            .cmd("selection.showAll", "Show All", ["Selection Pane"], nil, "{} shows every object on the slide, inside groups too", Cmd.hasSlide, showAll),
            .cmd("selection.hideAll", "Hide All", ["Selection Pane"], nil, "{} hides every top-level object on the slide", Cmd.hasSlide, hideAll),
        ]
    }

    /// The Selection pane's click. Objects inside groups and top-level objects can't be selected together
    /// (Ctrl+click on the other kind is ignored, as in PowerPoint), and picking a hidden object from the
    /// list shows it again.
    @Sendable static func select(_ s: Session, _ p: JSON) throws -> JSON {
        let ids: [ShapeId]
        if let v = Cmd.idsParam(p, "ids") {
            ids = v
        } else {
            ids = try Cmd.idParam(p, "id", "selection.select").map { [$0] } ?? []
        }
        let (toggle, add) = (Cmd.boolOr(p, "toggle", false), Cmd.boolOr(p, "add", false))
        let st = try s.doc()
        let tree = st.shapes
        // nil: no such shape; true: inside a group.
        func inGroup(_ id: ShapeId) -> Bool? { parentOf(tree, id).map { $0 != nil } }
        var valid = ids.filter { inGroup($0) != nil }
        if valid.isEmpty { throw Cmd.bad("selection.select", "no such shape") }
        let kind = valid.first.flatMap(inGroup)
        valid = valid.filter { inGroup($0) == kind }
        var next: [ShapeId] = []
        if toggle || add {
            let current = st.selection.shapes
            if let c = current.first, inGroup(c) != kind {
                // Can't mix objects in groups with top-level ones: nothing changes.
                return ["selected": current.toJSON()]
            }
            next = current
        }
        for i in valid {
            if let k = next.firstIndex(of: i) {
                if toggle { next.remove(at: k) }
            } else {
                next.append(i)
            }
        }
        let reveal = next.filter { valid.contains($0) && (st.shape($0)?.hidden ?? false) }
        let chosen = next
        if reveal.isEmpty {
            try s.select { _, sel in
                sel.text = nil
                sel.cells = nil
                sel.shapes = chosen
            }
        } else {
            try s.edit { doc, sel in
                try withShapes(&doc, sel, missing: Cmd.bad("selection.select", "no slide")) { shapes in
                    for id in reveal { withShape(&shapes, id) { $0.hidden = false } }
                }
                sel.text = nil
                sel.cells = nil
                sel.shapes = chosen
            }
        }
        return try ["selected": s.doc().selection.shapes.toJSON()]
    }

    @Sendable static func showAll(_ s: Session, _ p: JSON) throws -> JSON {
        var anyHidden = false
        try walk(s.doc().shapes) { sh, _ in anyHidden = anyHidden || sh.hidden }
        if !anyHidden { return Cmd.ok() }
        try s.edit { doc, sel in
            func rec(_ v: inout [Shape], _ depth: Int) {
                for i in v.indices {
                    v[i].hidden = false
                    if depth < 64 { v[i].mutateChildren { rec(&$0, depth + 1) } }
                }
            }
            try withShapes(&doc, sel, missing: Cmd.bad("selection.showAll", "no slide")) { rec(&$0, 0) }
        }
        return Cmd.ok()
    }

    @Sendable static func hideAll(_ s: Session, _ p: JSON) throws -> JSON {
        if try s.doc().shapes.allSatisfy(\.hidden) { return Cmd.ok() }
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("selection.hideAll", "no slide")) { shapes in
                for i in shapes.indices { shapes[i].hidden = true }
            }
        }
        return Cmd.ok()
    }
}
