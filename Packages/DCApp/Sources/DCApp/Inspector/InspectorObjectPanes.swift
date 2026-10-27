// DCApp — Format ▸ Table, Chart, SmartArt and Playback: deckcraft's contextual ribbon tabs Table Design and
// Layout (`table_design`, `table_layout`), Chart Design (`chart_design`), SmartArt Design (`smartart_design`)
// with the SmartArt Text Pane (`smartart` in `panes.rs`), and Playback (`playback`), from
// `crates/ui-egui/src/ribbon.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI

// MARK: - Table

struct TableFormatView: View {
    let ctl: InspectorController

    var body: some View {
        let table: DCModel.Table? = ctl.doc?.selectedShapes.lazy.compactMap { if case .table(let t) = $0.kind { t } else { nil } }.first
        let scheme = InspectorColors.scheme(ctl.session)
        Section("Table Style Options") {
            let flags = table.map { [$0.firstRow, $0.lastRow, $0.bandRow, $0.firstCol, $0.lastCol, $0.bandCol] } ?? Array(repeating: false, count: 6)
            ForEach(Array(Self.options.enumerated()), id: \.offset) { i, o in
                Toggle(o.0, isOn: Binding(get: { flags.at(i) ?? false }, set: { on in
                    var p: JSON = .emptyObject
                    p.set(o.1, .bool(on))
                    ctl.run("table.options", p)
                }))
            }
        }
        Section("Table Styles") {
            Picker("Style", selection: Binding(get: { table?.style ?? "" }, set: { ctl.run("table.style", ["style": .string($0)]) })) {
                if !tableStyles().contains(where: { $0.id == table?.style }) { Text("Custom").tag(table?.style ?? "") }
                ForEach(tableStyles(), id: \.id) { Text($0.label).tag($0.id) }
            }
            ColorSplitButton(title: "Shading", symbol: "paintbrush.fill", color: scheme.get(.accent1), scheme: scheme, noneLabel: "No Fill",
                             primary: { ctl.run("table.cellFill", ["color": "accent1"]) },
                             pick: { c in
                                 if let c { ctl.run("table.cellFill", ["color": InspectorColors.param(c)]) } else { ctl.run("table.cellFill", ["none": true]) }
                             })
            Menu("Borders") {
                ForEach(Self.borders, id: \.1) { label, which in
                    Button(label) {
                        var p = ctl.tablePen
                        p.set("which", .string(which))
                        ctl.run("table.borders", p)
                    }
                }
            }
            Picker("Pen Weight", selection: Binding(get: { ctl.tablePen["width"]?.asF64 ?? 1 }, set: { ctl.tablePen.set("width", .num($0)) })) {
                ForEach(InspectorFill.weights, id: \.self) { Text("\(NumberField.format($0, "")) pt").tag($0) }
            }
            Picker("Pen Style", selection: Binding(get: { ctl.tablePen["dash"]?.asStr ?? "solid" }, set: { ctl.tablePen.set("dash", .string($0)) })) {
                ForEach([("Solid", "solid"), ("Dash", "dash"), ("Dot", "sysDot"), ("Dash Dot", "dashDot"), ("Long Dash", "lgDash")], id: \.1) { Text($0.0).tag($0.1) }
            }
            ColorButton(label: "Pen Color", color: Cmd.colorValue(ctl.tablePen["color"] ?? .null)?.resolve(scheme, nil), scheme: scheme) { c in
                if let c { ctl.tablePen.set("color", InspectorColors.param(c)) }
            }
            HStack {
                toolButton("Draw Table", "pencil", Tools.drawTable)
                toolButton("Table Eraser", "eraser", Tools.tableEraser)
            }
        }
        Section("Rows & Columns") {
            HStack {
                Button("Insert Above") { ctl.run("table.insertRowAbove") }
                Button("Insert Below") { ctl.run("table.insertRowBelow") }
            }
            HStack {
                Button("Insert Left") { ctl.run("table.insertColumnLeft") }
                Button("Insert Right") { ctl.run("table.insertColumnRight") }
            }
            Menu("Delete") {
                Button("Delete Columns") { ctl.run("table.deleteColumn") }
                Button("Delete Rows") { ctl.run("table.deleteRow") }
                Button("Delete Table") { ctl.run("edit.delete") }
            }
        }
        Section("Merge & Cell Size") {
            HStack {
                Button("Merge Cells") { ctl.run("table.merge") }.disabled(!ctl.enabled("table.merge"))
                Button("Split Cells") { ctl.run("table.split") }.disabled(!ctl.enabled("table.split"))
            }
            HStack {
                Button("Distribute Rows") { ctl.run("table.distributeRows") }
                Button("Distribute Columns") { ctl.run("table.distributeColumns") }
            }
        }
        Section("Alignment") {
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(InspectorText.aligns.prefix(3), id: \.1) { label, id, _, symbol in IconToggle(symbol: symbol, help: label) { ctl.run(id) } }
                Spacer()
                ForEach([("Top", "top", "arrow.up.to.line"), ("Center", "middle", "arrow.up.and.down"), ("Bottom", "bottom", "arrow.down.to.line")], id: \.1) { l, a, s in
                    IconToggle(symbol: s, help: "Align text to the \(l.lowercased()) of the cell") { ctl.run("table.cellAlign", ["anchor": .string(a)]) }
                }
            }
            Menu("Cell Margins") {
                ForEach([("Normal", "normal"), ("None", "none"), ("Narrow", "narrow"), ("Wide", "wide")], id: \.1) { l, p in
                    Button(l) { ctl.run("table.cellMargins", ["preset": .string(p)]) }
                }
            }
        }
    }

    static let options: [(String, String)] = [
        ("Header Row", "headerRow"), ("Total Row", "totalRow"), ("Banded Rows", "bandedRows"),
        ("First Column", "firstColumn"), ("Last Column", "lastColumn"), ("Banded Columns", "bandedColumns"),
    ]
    static let borders: [(String, String)] = [
        ("No Border", "none"), ("All Borders", "all"), ("Outside Borders", "outside"), ("Inside Borders", "inside"),
        ("Top Border", "top"), ("Bottom Border", "bottom"), ("Left Border", "left"), ("Right Border", "right"),
        ("Inside Horizontal Border", "insideH"), ("Inside Vertical Border", "insideV"), ("Diagonal Down Border", "diagDown"), ("Diagonal Up Border", "diagUp"),
    ]

    /// Draw Table's pencil and eraser: the session's pointer tool (as deckcraft sets it; no command).
    private func toolButton(_ label: String, _ symbol: String, _ preset: String) -> some View {
        let on: Bool = { if case .shape(let p) = ctl.session.tool.kind { p == preset } else { false } }()
        return Toggle(isOn: Binding(get: { on }, set: { _ in
            ctl.session.setTool(on ? .select : .shape(preset: preset))
            ctl.model.changed()
        })) { Label(label, systemImage: symbol) }
            .toggleStyle(.button)
    }
}

// MARK: - Chart

/// The chart types of Insert Chart and Change Chart Type (`chart_menu_types`): the main ones, then the
/// Office 2016 types not already listed.
enum ChartMenu {
    static var types: [[ChartType]] { [ChartType.main, ChartType.office2016.filter { !ChartType.main.contains($0) }] }
    /// Rust's `{:?}` of the type, the parameter deckcraft passes.
    static func param(_ k: ChartType) -> String { k.rawValue.prefix(1).uppercased() + k.rawValue.dropFirst() }
}

struct ChartFormatView: View {
    let ctl: InspectorController

    var body: some View {
        let chart: (ShapeId, Chart)? = ctl.doc?.selectedShapes.lazy.compactMap { s in if case .chart(let c) = s.kind { (s.id, c) } else { nil } }.first
        Section("Chart") {
            Picker("Chart Type", selection: Binding(get: { chart?.1.kind.rawValue ?? "" }, set: { k in
                if let id = chart?.0, let t = ChartType(rawValue: k) { ctl.run("chart.type", ["id": .integer(id.rawValue), "type": .string(ChartMenu.param(t))]) }
            })) {
                ForEach(Array(ChartMenu.types.enumerated()), id: \.offset) { i, group in
                    if i > 0 { Divider() }
                    ForEach(group, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            }
            Button("Edit Data…") { ctl.run("app.dialog", ["id": "chartData"]) }
        }
    }
}

// MARK: - SmartArt

struct SmartArtFormatView: View {
    let ctl: InspectorController

    var body: some View {
        if let (gid, d) = ctl.smartArt {
            let at = Swift.min(ctl.smartartRow, Swift.max(d.nodes.count - 1, 0))
            Section("Text Pane") {
                SmartArtTextPane(ctl: ctl, gid: gid, nodes: d.nodes)
            }
            Section("Create Graphic") {
                Menu {
                    ForEach([("Add Shape After", "after"), ("Add Shape Before", "before"), ("Add Shape Above", "above"),
                             ("Add Shape Below", "below"), ("Add Assistant", "assistant")], id: \.1) { l, pos in
                        Button(l) { ctl.smartArtEdit("smartArt.addNode", gid, ["index": d.nodes.isEmpty ? .null : .integer(at), "position": .string(pos)], focus: at + 1) }
                    }
                } label: { Label("Add Shape", systemImage: "plus") } primaryAction: {
                    ctl.smartArtEdit("smartArt.addNode", gid, ["index": d.nodes.isEmpty ? .null : .integer(at), "position": "after"], focus: at + 1)
                }
                HStack {
                    Button("Promote") { ctl.smartArtEdit("smartArt.promote", gid, ["index": .integer(at)], focus: at) }.disabled(d.nodes.isEmpty)
                    Button("Demote") { ctl.smartArtEdit("smartArt.demote", gid, ["index": .integer(at)], focus: at) }.disabled(d.nodes.isEmpty)
                }
                Button("Insert Picture…") { ctl.run("app.smartArtPictureDialog", ["id": .integer(gid.rawValue), "index": .integer(at)]) }
                    .disabled(!(d.kind.hasPrefix("picture") && !d.nodes.isEmpty))
                    .help("Put a picture in the selected node's picture placeholder")
            }
            Section("Layouts") {
                SmartArtLayoutMenu(title: "Layouts", current: d.kind) { ctl.run("smartArt.layout", ["id": .integer(gid.rawValue), "kind": .string($0)]) }
                Menu("Convert") {
                    Button("Convert to Text") { ctl.run("smartArt.toText", ["id": .integer(gid.rawValue)]) }
                    Button("Convert to Shapes") { ctl.run("smartArt.toShapes", ["id": .integer(gid.rawValue)]) }
                }
            }
            Section("SmartArt Styles") {
                Picker("Colors", selection: Binding(get: { d.colors.isEmpty ? "colorful" : d.colors }, set: { ctl.run("smartArt.colors", ["id": .integer(gid.rawValue), "colors": .string($0)]) })) {
                    ForEach(SmartArtCommands.colors, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Style", selection: Binding(get: { d.style.isEmpty ? "flat" : d.style }, set: { ctl.run("smartArt.style", ["id": .integer(gid.rawValue), "style": .string($0)]) })) {
                    ForEach(SmartArtCommands.styles, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        } else {
            Section { InspectorNote(text: "Select a SmartArt graphic to edit its text.") }
        }
    }
}

/// The SmartArt Text Pane: one line per node, indented by level. Return adds a line after, Tab and Shift-Tab
/// demote and promote, Delete in an empty line removes it. A changed line is committed before any structural
/// edit, so the edit sees the new text.
struct SmartArtTextPane: View {
    let ctl: InspectorController
    let gid: ShapeId
    let nodes: [DiagramNode]
    @State private var drafts: [Int: String] = [:]
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            InspectorNote(text: "Type your text here")
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                HStack(spacing: Tokens.Space.xs) {
                    Text("•").foregroundStyle(Tokens.Color.secondaryLabel)
                    TextField("SmartArt text", text: Binding(get: { drafts[i] ?? node.text }, set: { drafts[i] = $0 }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: i)
                        .onSubmit { structural("smartArt.addNode", ["index": .integer(i), "position": "after"], focus: i + 1, row: i) }
                        .onKeyPress(.tab, phases: .down) { press in
                            structural(press.modifiers.contains(.shift) ? "smartArt.promote" : "smartArt.demote", ["index": .integer(i)], focus: i, row: i)
                            return .handled
                        }
                        .onKeyPress(.delete, phases: .down) { _ in
                            guard (drafts[i] ?? node.text).isEmpty, node.text.isEmpty, nodes.count > 1 else { return .ignored }
                            structural("smartArt.removeNode", ["index": .integer(i)], focus: Swift.max(i - 1, 0), row: i)
                            return .handled
                        }
                }
                .padding(.leading, Tokens.Space.l * Double(node.level))
            }
            HStack {
                Button("+ Add") {
                    structural("smartArt.addNode", ["index": .integer(Swift.min(ctl.smartartRow, Swift.max(nodes.count - 1, 0))), "position": "after"], focus: ctl.smartartRow + 1, row: nil)
                }
                Button("Remove") {
                    structural("smartArt.removeNode", ["index": .integer(Swift.min(ctl.smartartRow, Swift.max(nodes.count - 1, 0)))], focus: Swift.max(ctl.smartartRow - 1, 0), row: nil)
                }
                .disabled(nodes.isEmpty)
            }
        }
        .onChange(of: focus) { old, new in
            if let o = old { commit(o) }
            if let n = new { ctl.smartartRow = n }
        }
    }

    private func commit(_ i: Int) {
        guard let d = drafts[i] else { return }
        drafts[i] = nil
        if d != nodes.at(i)?.text { ctl.setNode(gid, i, d) }
    }

    private func structural(_ cmd: String, _ p: JSON, focus f: Int, row: Int?) {
        for i in drafts.keys.sorted() { commit(i) }
        if let r = ctl.smartArtEdit(cmd, gid, p, focus: f) { focus = r }
        _ = row
    }
}

// MARK: - Playback

struct MediaFormatView: View {
    let ctl: InspectorController

    var body: some View {
        let m: MediaClip? = ctl.doc?.selectedShapes.lazy.compactMap { if case .media(let c) = $0.kind { c } else { nil } }.first
        Section("Preview") {
            Button("Play/Pause") { ctl.run("media.toggle") }.disabled(m == nil)
            Button("Trim…") { ctl.run("app.dialog", ["id": "trim"]) }.disabled(m == nil)
        }
        Section("Options") {
            option("Start Automatically", "autoplay", m?.autoplay)
            option("Play Across Slides", "acrossSlides", m?.playAcrossSlides)
            option("Loop until Stopped", "loop", m?.loopPlay)
            option("Hide During Show", "hide", m?.hideWhileNotPlaying)
            option("Rewind after Playing", "rewind", m?.rewind)
            option("Play Full Screen", "fullScreen", m?.fullScreen)
            Picker("Volume", selection: Binding(get: { m?.volume ?? 1 }, set: { ctl.run("media.options", ["volume": .num($0)]) })) {
                ForEach([("Low", 0.25), ("Medium", 0.5), ("High", 1.0), ("Mute", 0.0)], id: \.1) { Text($0.0).tag($0.1) }
                if let v = m?.volume, ![0.25, 0.5, 1.0, 0.0].contains(v) { Text("\(Int(v * 100))%").tag(v) }
            }
        }
    }

    private func option(_ label: String, _ key: String, _ on: Bool?) -> some View {
        Toggle(label, isOn: Binding(get: { on ?? false }, set: { v in
            var p: JSON = .emptyObject
            p.set(key, .bool(v))
            ctl.run("media.options", p)
        }))
        .disabled(on == nil)
    }
}
