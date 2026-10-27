// DCApp — Arrange: order, align and distribute (with Align to Slide), group, rotate and flip — deckcraft's
// Arrange menu and Shape Format ▸ Arrange group (`arrange_menu`, `align_menu`, `arrange_group` in
// `crates/ui-egui/src/ribbon.rs`) — and the Selection Pane (`selpane.rs`): every object on the slide,
// front-most first, groups expanded; click to select (Command toggles, Shift selects a run), drag to restack
// among siblings, the eye to show or hide, the padlock to lock, double-click to rename, arrows to move through
// the list. MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI

struct ArrangeView: View {
    let ctl: InspectorController

    var body: some View {
        let sel = ctl.enabled("arrange.bringForward")
        Section(String(localized: "Order Objects", bundle: .module)) {
            HStack(spacing: Tokens.Layout.hairline) {
                button(String(localized: "Bring to Front", bundle: .module), "square.3.layers.3d.top.filled", "arrange.bringToFront")
                button(String(localized: "Bring Forward", bundle: .module), "square.2.layers.3d.top.filled", "arrange.bringForward")
                button(String(localized: "Send Backward", bundle: .module), "square.2.layers.3d.bottom.filled", "arrange.sendBackward")
                button(String(localized: "Send to Back", bundle: .module), "square.3.layers.3d.bottom.filled", "arrange.sendToBack")
            }
        }
        Section(String(localized: "Align", bundle: .module)) {
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(Self.edges, id: \.1) { label, edge, symbol in
                    IconToggle(symbol: symbol, help: label, enabled: ctl.enabled("arrange.align")) { ctl.align(edge) }
                }
            }
            HStack(spacing: Tokens.Layout.hairline) {
                IconToggle(symbol: "distribute.horizontal.center", help: String(localized: "Distribute Horizontally", bundle: .module), enabled: ctl.enabled("arrange.distribute")) { ctl.distribute("horizontal") }
                IconToggle(symbol: "distribute.vertical.center", help: String(localized: "Distribute Vertically", bundle: .module), enabled: ctl.enabled("arrange.distribute")) { ctl.distribute("vertical") }
            }
            Picker(String(localized: "Align to", bundle: .module), selection: Binding(get: { ctl.alignsToSlide }, set: { ctl.setAlignTo(slide: $0) })) {
                Text("Slide", bundle: .module, comment: "Align to: the slide").tag(true)
                Text("Selected Objects", bundle: .module).tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!ctl.enabled("arrange.align"))
        }
        Section(String(localized: "Group, Rotate and Flip", bundle: .module)) {
            HStack {
                Menu {
                    Button(String(localized: "Group", bundle: .module)) { ctl.run("arrange.group") }.disabled(!ctl.enabled("arrange.group"))
                    Button(String(localized: "Ungroup", bundle: .module)) { ctl.run("arrange.ungroup") }.disabled(!ctl.enabled("arrange.ungroup"))
                    Button(String(localized: "Regroup", bundle: .module)) { ctl.run("arrange.regroup") }.disabled(!ctl.enabled("arrange.regroup"))
                } label: { Label(String(localized: "Group", bundle: .module), systemImage: "square.on.square") } primaryAction: { ctl.run("arrange.group") }
                    .disabled(!sel)
                    .accessibilityLabel(String(localized: "Group", bundle: .module))
                Menu {
                    Button(String(localized: "Rotate Right 90°", bundle: .module)) { ctl.run("arrange.rotateRight") }
                    Button(String(localized: "Rotate Left 90°", bundle: .module)) { ctl.run("arrange.rotateLeft") }
                    Button(String(localized: "Flip Vertical", bundle: .module)) { ctl.run("arrange.flipVertical") }
                    Button(String(localized: "Flip Horizontal", bundle: .module)) { ctl.run("arrange.flipHorizontal") }
                } label: { Label(String(localized: "Rotate", bundle: .module), systemImage: "rotate.right") } primaryAction: { ctl.run("arrange.rotateRight") }
                    .disabled(!sel)
                    .accessibilityLabel(String(localized: "Rotate", bundle: .module))
            }
            HStack(spacing: Tokens.Layout.hairline) {
                IconToggle(symbol: "rotate.left", help: String(localized: "Rotate Left 90°", bundle: .module), enabled: sel) { ctl.run("arrange.rotateLeft") }
                IconToggle(symbol: "rotate.right", help: String(localized: "Rotate Right 90°", bundle: .module), enabled: sel) { ctl.run("arrange.rotateRight") }
                IconToggle(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: String(localized: "Flip Horizontal", bundle: .module), enabled: sel) { ctl.run("arrange.flipHorizontal") }
                IconToggle(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: String(localized: "Flip Vertical", bundle: .module), enabled: sel) { ctl.run("arrange.flipVertical") }
            }
        }
        if let sh = ctl.selectedShape {
            EditShapeSection(ctl: ctl, sh: sh)
            SizeView(ctl: ctl, sh: sh)
        }
        Section(String(localized: "Selection Pane", bundle: .module)) { SelectionPaneView(ctl: ctl) }
    }

    static let edges: [(String, String, String)] = [
        (String(localized: "Align Left", bundle: .module), "left", "align.horizontal.left"), (String(localized: "Align Center", bundle: .module), "center", "align.horizontal.center"),
        (String(localized: "Align Right", bundle: .module), "right", "align.horizontal.right"), (String(localized: "Align Top", bundle: .module), "top", "align.vertical.top"),
        (String(localized: "Align Middle", bundle: .module), "middle", "align.vertical.center"), (String(localized: "Align Bottom", bundle: .module), "bottom", "align.vertical.bottom"),
    ]

    private func button(_ label: String, _ symbol: String, _ id: String) -> some View {
        IconToggle(symbol: symbol, help: label, enabled: ctl.enabled(id)) { ctl.run(id) }
    }
}

struct SelectionPaneView: View {
    let ctl: InspectorController
    @State private var drag: (id: UInt32, y: Double)?
    @FocusState private var renameFocus: Bool
    @FocusState private var listFocus: Bool

    var body: some View {
        if let st = ctl.doc {
            let rows = rowsFor(st)
            let selected = st.selection.shapes.map(\.rawValue)
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                HStack {
                    Button(String(localized: "Show All", bundle: .module)) { ctl.run("selection.showAll") }
                    Button(String(localized: "Hide All", bundle: .module)) { ctl.run("selection.hideAll") }
                    Spacer()
                    IconToggle(symbol: "chevron.up", help: String(localized: "Bring Forward", bundle: .module), enabled: !selected.isEmpty) { ctl.run("arrange.bringForward") }
                    IconToggle(symbol: "chevron.down", help: String(localized: "Send Backward", bundle: .module), enabled: !selected.isEmpty) { ctl.run("arrange.sendBackward") }
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { k, row in
                        rowView(rows, k, row, selected.contains(row.id))
                    }
                }
                .coordinateSpace(name: "selpane")
                .overlay(alignment: .topLeading) {
                    if let d = drag, let t = target(rows, d) {
                        Rectangle().fill(Tokens.Color.accent).frame(height: Tokens.Layout.hairline * 2).offset(y: t.y - Tokens.Layout.hairline)
                    }
                }
                .focusable()
                .focused($listFocus)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .home, .end]) { press in
                    let key = press.key == .upArrow ? "Up" : press.key == .downArrow ? "Down" : press.key == .home ? "Home" : "End"
                    guard let k = SelectionPane.keyTarget(rows, selected: selected, key: key), let r = rows.at(k) else { return .ignored }
                    ctl.run("selection.select", ["id": .integer(r.id)])
                    ctl.selectionPane.anchor = r.id
                    return .handled
                }
                .onKeyPress(.return) {
                    guard selected.count == 1, let r = rows.first(where: { $0.id == selected[0] }) else { return .ignored }
                    ctl.selectionPane.renaming = (r.id, r.name)
                    return .handled
                }
            }
        }
    }

    private func rowsFor(_ st: DocState) -> [SelectionPane.Row] {
        ctl.selectionPane.bind(st.uid)
        return SelectionPane.rows(st.shapes, ctl.selectionPane.collapsed)
    }

    private func target(_ rows: [SelectionPane.Row], _ d: (id: UInt32, y: Double)) -> (index: Int, y: Double)? {
        guard let row = rows.first(where: { $0.id == d.id }) else { return nil }
        return SelectionPane.dropTarget(d.id, SelectionPane.siblingBlocks(rows, row.parent), d.y)
    }

    @ViewBuilder
    private func rowView(_ rows: [SelectionPane.Row], _ k: Int, _ row: SelectionPane.Row, _ sel: Bool) -> some View {
        let ink = row.dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.label
        HStack(spacing: Tokens.Space.xs) {
            if row.group {
                let open = !ctl.selectionPane.collapsed.contains(row.id)
                Button {
                    if open { ctl.selectionPane.collapsed.insert(row.id) } else { ctl.selectionPane.collapsed.remove(row.id) }
                } label: { Image(systemName: open ? "chevron.down" : "chevron.right") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? String(localized: "Collapse \(row.name)", bundle: .module) : String(localized: "Expand \(row.name)", bundle: .module))
            } else {
                Image(systemName: "chevron.right").hidden()
            }
            if let r = ctl.selectionPane.renaming, r.id == row.id {
                TextField(String(localized: "Name", bundle: .module), text: Binding(get: { ctl.selectionPane.renaming?.text ?? "" }, set: { ctl.selectionPane.renaming?.text = $0 }))
                    .focused($renameFocus)
                    .onAppear { renameFocus = true }
                    .onSubmit { finishRename(row) }
                    .onExitCommand { ctl.selectionPane.renaming = nil }
                    .onChange(of: renameFocus) { _, f in if !f { finishRename(row) } }
            } else {
                // A button, so a click (and the control channel's synthetic one) selects the row.
                Button { click(rows, k) } label: {
                    HStack {
                        Text(row.name).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: Tokens.Space.xs)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.name)
                .simultaneousGesture(TapGesture(count: 2).onEnded { ctl.selectionPane.renaming = (row.id, row.name) })
            }
            Button { ctl.run("shape.visible", ["id": .integer(row.id), "visible": .bool(row.hidden)]) } label: {
                Image(systemName: row.hidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(row.dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.secondaryLabel)
            .accessibilityLabel(row.hidden ? String(localized: "Show \(row.name)", bundle: .module) : String(localized: "Hide \(row.name)", bundle: .module))
            Button { ctl.run("shape.lock", ["id": .integer(row.id)]) } label: {
                Image(systemName: row.locked ? "lock" : "lock.open")
            }
            .buttonStyle(.plain)
            .foregroundStyle(row.dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.secondaryLabel)
            .accessibilityLabel(row.locked ? String(localized: "Unlock \(row.name)", bundle: .module) : String(localized: "Lock \(row.name)", bundle: .module))
        }
        .padding(.leading, SelectionPane.indent * Double(row.depth))
        .padding(.horizontal, Tokens.Space.xs)
        .frame(height: SelectionPane.rowHeight)
        .background(sel ? Tokens.Color.selectionWash : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control / 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(sel ? .isSelected : [])
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("selpane"))
            .onChanged { v in
                if drag == nil, !sel { ctl.run("selection.select", ["id": .integer(row.id)]) }
                drag = (row.id, v.location.y)
            }
            .onEnded { _ in
                if let d = drag, let t = target(rows, d) { ctl.run("arrange.reorder", ["id": .integer(d.id), "index": .integer(t.index)]) }
                drag = nil
            })
        .contextMenu {
            ForEach(SelectionPane.orderCommands, id: \.1) { l, id in Button(l) { ctl.run(id, ["ids": [.integer(row.id)]]) } }
            Divider()
            Button(String(localized: "Rename", bundle: .module)) { ctl.selectionPane.renaming = (row.id, row.name) }
            Button(row.hidden ? String(localized: "Show", bundle: .module, comment: "Show a hidden object") : String(localized: "Hide", bundle: .module, comment: "Hide an object")) { ctl.run("shape.visible", ["id": .integer(row.id), "visible": .bool(row.hidden)]) }
            Button(row.locked ? String(localized: "Unlock", bundle: .module) : String(localized: "Lock", bundle: .module, comment: "Verb: lock an object")) { ctl.run("shape.lock", ["id": .integer(row.id)]) }
        }
    }

    /// A click on row `k` (`click`): Command toggles, Shift selects the run from the anchor.
    private func click(_ rows: [SelectionPane.Row], _ k: Int) {
        let mods = NSEvent.modifierFlags
        if let c = SelectionPane.click(rows, k, anchor: ctl.selectionPane.anchor, command: mods.contains(.command), shift: mods.contains(.shift)) {
            ctl.run("selection.select", c.params)
            ctl.selectionPane.anchor = c.anchor
        }
        listFocus = true
    }

    private func finishRename(_ row: SelectionPane.Row) {
        guard let r = ctl.selectionPane.renaming, r.id == row.id else { return }
        ctl.selectionPane.renaming = nil
        if let p = SelectionPane.renameParams(row, r.text) { ctl.run("shape.rename", p) }
    }
}

/// Shape Format ▸ Insert Shapes: Edit Shape (Change Shape, Edit Points, Smooth Corners) and Merge Shapes.
struct EditShapeSection: View {
    let ctl: InspectorController
    let sh: DCModel.Shape
    @State private var smooth: (id: ShapeId, radius: Double, percent: Double)?

    var body: some View {
        Section(String(localized: "Edit Shape", bundle: .module)) {
            ShapesMenu(includeFreeform: false, pick: { ctl.run("shape.change", ["preset": .string($0)]) }) { Text("Change Shape", bundle: .module) }
                .disabled(!ctl.enabled("shape.change"))
            Button(String(localized: "Edit Points", bundle: .module)) { ctl.run("shape.editPoints", ["on": true]) }.disabled(!ctl.enabled("shape.editPoints"))
            let own = InspectorShape.cornerRadius(sh)
            let state = smooth?.id == sh.id ? smooth : nil
            CommitSlider(label: String(localized: "Smooth Corners", bundle: .module), value: state?.percent ?? 0, range: 0 ... 100, suffix: "%") { v in
                // The radius is the rectangle's when the slider is first used, and kept for later moves.
                let r = own ?? state?.radius ?? 0
                smooth = (sh.id, r, v)
                ctl.run("shape.smoothCorners", InspectorShape.smoothParams(v, radius: r))
            }
            .disabled(own == nil && state == nil)
            .help(own == nil && state == nil ? String(localized: "For rectangles and rounded rectangles", bundle: .module) : String(localized: "Smooth the corners into a squircle", bundle: .module))
            Menu(String(localized: "Merge Shapes", bundle: .module)) {
                ForEach(MergeCommands.ops, id: \.0) { op, label in Button(label) { ctl.run("shape.merge", ["op": .string(op)]) } }
            }
            .disabled(!ctl.enabled("shape.merge"))
        }
    }
}
