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
        Section("Order Objects") {
            HStack(spacing: Tokens.Layout.hairline) {
                button("Bring to Front", "square.3.layers.3d.top.filled", "arrange.bringToFront")
                button("Bring Forward", "square.2.layers.3d.top.filled", "arrange.bringForward")
                button("Send Backward", "square.2.layers.3d.bottom.filled", "arrange.sendBackward")
                button("Send to Back", "square.3.layers.3d.bottom.filled", "arrange.sendToBack")
            }
        }
        Section("Align") {
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(Self.edges, id: \.1) { label, edge, symbol in
                    IconToggle(symbol: symbol, help: label, enabled: ctl.enabled("arrange.align")) { ctl.align(edge) }
                }
            }
            HStack(spacing: Tokens.Layout.hairline) {
                IconToggle(symbol: "distribute.horizontal.center", help: "Distribute Horizontally", enabled: ctl.enabled("arrange.distribute")) { ctl.distribute("horizontal") }
                IconToggle(symbol: "distribute.vertical.center", help: "Distribute Vertically", enabled: ctl.enabled("arrange.distribute")) { ctl.distribute("vertical") }
            }
            Picker("Align to", selection: Binding(get: { ctl.alignsToSlide }, set: { ctl.setAlignTo(slide: $0) })) {
                Text("Slide").tag(true)
                Text("Selected Objects").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!ctl.enabled("arrange.align"))
        }
        Section("Group, Rotate and Flip") {
            HStack {
                Menu {
                    Button("Group") { ctl.run("arrange.group") }.disabled(!ctl.enabled("arrange.group"))
                    Button("Ungroup") { ctl.run("arrange.ungroup") }.disabled(!ctl.enabled("arrange.ungroup"))
                    Button("Regroup") { ctl.run("arrange.regroup") }.disabled(!ctl.enabled("arrange.regroup"))
                } label: { Label("Group", systemImage: "square.on.square") } primaryAction: { ctl.run("arrange.group") }
                    .disabled(!sel)
                    .accessibilityLabel("Group")
                Menu {
                    Button("Rotate Right 90°") { ctl.run("arrange.rotateRight") }
                    Button("Rotate Left 90°") { ctl.run("arrange.rotateLeft") }
                    Button("Flip Vertical") { ctl.run("arrange.flipVertical") }
                    Button("Flip Horizontal") { ctl.run("arrange.flipHorizontal") }
                } label: { Label("Rotate", systemImage: "rotate.right") } primaryAction: { ctl.run("arrange.rotateRight") }
                    .disabled(!sel)
                    .accessibilityLabel("Rotate")
            }
            HStack(spacing: Tokens.Layout.hairline) {
                IconToggle(symbol: "rotate.left", help: "Rotate Left 90°", enabled: sel) { ctl.run("arrange.rotateLeft") }
                IconToggle(symbol: "rotate.right", help: "Rotate Right 90°", enabled: sel) { ctl.run("arrange.rotateRight") }
                IconToggle(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal", enabled: sel) { ctl.run("arrange.flipHorizontal") }
                IconToggle(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical", enabled: sel) { ctl.run("arrange.flipVertical") }
            }
        }
        if let sh = ctl.selectedShape {
            EditShapeSection(ctl: ctl, sh: sh)
            SizeView(ctl: ctl, sh: sh)
        }
        Section("Selection Pane") { SelectionPaneView(ctl: ctl) }
    }

    static let edges: [(String, String, String)] = [
        ("Align Left", "left", "align.horizontal.left"), ("Align Center", "center", "align.horizontal.center"),
        ("Align Right", "right", "align.horizontal.right"), ("Align Top", "top", "align.vertical.top"),
        ("Align Middle", "middle", "align.vertical.center"), ("Align Bottom", "bottom", "align.vertical.bottom"),
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
                    Button("Show All") { ctl.run("selection.showAll") }
                    Button("Hide All") { ctl.run("selection.hideAll") }
                    Spacer()
                    IconToggle(symbol: "chevron.up", help: "Bring Forward", enabled: !selected.isEmpty) { ctl.run("arrange.bringForward") }
                    IconToggle(symbol: "chevron.down", help: "Send Backward", enabled: !selected.isEmpty) { ctl.run("arrange.sendBackward") }
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
                    .accessibilityLabel("\(open ? "Collapse" : "Expand") \(row.name)")
            } else {
                Image(systemName: "chevron.right").hidden()
            }
            if let r = ctl.selectionPane.renaming, r.id == row.id {
                TextField("Name", text: Binding(get: { ctl.selectionPane.renaming?.text ?? "" }, set: { ctl.selectionPane.renaming?.text = $0 }))
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
            .accessibilityLabel("\(row.hidden ? "Show" : "Hide") \(row.name)")
            Button { ctl.run("shape.lock", ["id": .integer(row.id)]) } label: {
                Image(systemName: row.locked ? "lock" : "lock.open")
            }
            .buttonStyle(.plain)
            .foregroundStyle(row.dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.secondaryLabel)
            .accessibilityLabel("\(row.locked ? "Unlock" : "Lock") \(row.name)")
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
            Button("Rename") { ctl.selectionPane.renaming = (row.id, row.name) }
            Button(row.hidden ? "Show" : "Hide") { ctl.run("shape.visible", ["id": .integer(row.id), "visible": .bool(row.hidden)]) }
            Button(row.locked ? "Unlock" : "Lock") { ctl.run("shape.lock", ["id": .integer(row.id)]) }
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
        Section("Edit Shape") {
            ShapesMenu(includeFreeform: false, pick: { ctl.run("shape.change", ["preset": .string($0)]) }) { Text("Change Shape") }
                .disabled(!ctl.enabled("shape.change"))
            Button("Edit Points") { ctl.run("shape.editPoints", ["on": true]) }.disabled(!ctl.enabled("shape.editPoints"))
            let own = InspectorShape.cornerRadius(sh)
            let state = smooth?.id == sh.id ? smooth : nil
            CommitSlider(label: "Smooth Corners", value: state?.percent ?? 0, range: 0 ... 100, suffix: "%") { v in
                // The radius is the rectangle's when the slider is first used, and kept for later moves.
                let r = own ?? state?.radius ?? 0
                smooth = (sh.id, r, v)
                ctl.run("shape.smoothCorners", InspectorShape.smoothParams(v, radius: r))
            }
            .disabled(own == nil && state == nil)
            .help(own == nil && state == nil ? "For rectangles and rounded rectangles" : "Smooth the corners into a squircle")
            Menu("Merge Shapes") {
                ForEach(MergeCommands.ops, id: \.0) { op, label in Button(label) { ctl.run("shape.merge", ["op": .string(op)]) } }
            }
            .disabled(!ctl.enabled("shape.merge"))
        }
    }
}
