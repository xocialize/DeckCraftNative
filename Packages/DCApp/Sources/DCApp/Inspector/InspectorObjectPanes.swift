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
        Section(String(localized: "Table Style Options", bundle: .module)) {
            let flags = table.map { [$0.firstRow, $0.lastRow, $0.bandRow, $0.firstCol, $0.lastCol, $0.bandCol] } ?? Array(repeating: false, count: 6)
            ForEach(Array(Self.options.enumerated()), id: \.offset) { i, o in
                Toggle(o.0, isOn: Binding(get: { flags.at(i) ?? false }, set: { on in
                    var p: JSON = .emptyObject
                    p.set(o.1, .bool(on))
                    ctl.run("table.options", p)
                }))
            }
        }
        Section(String(localized: "Table Styles", bundle: .module)) {
            Picker(String(localized: "Style", bundle: .module), selection: Binding(get: { table?.style ?? "" }, set: { ctl.run("table.style", ["style": .string($0)]) })) {
                if !tableStyles().contains(where: { $0.id == table?.style }) { Text("Custom", bundle: .module).tag(table?.style ?? "") }
                ForEach(tableStyles(), id: \.id) { Text($0.label).tag($0.id) }
            }
            ColorSplitButton(title: String(localized: "Shading", bundle: .module), symbol: "paintbrush.fill", color: scheme.get(.accent1), scheme: scheme, noneLabel: String(localized: "No Fill", bundle: .module),
                             primary: { ctl.run("table.cellFill", ["color": "accent1"]) },
                             pick: { c in
                                 if let c { ctl.run("table.cellFill", ["color": InspectorColors.param(c)]) } else { ctl.run("table.cellFill", ["none": true]) }
                             })
            Menu(String(localized: "Borders", bundle: .module)) {
                ForEach(Self.borders, id: \.1) { label, which in
                    Button(label) {
                        var p = ctl.tablePen
                        p.set("which", .string(which))
                        ctl.run("table.borders", p)
                    }
                }
            }
            Picker(String(localized: "Pen Weight", bundle: .module), selection: Binding(get: { ctl.tablePen["width"]?.asF64 ?? 1 }, set: { ctl.tablePen.set("width", .num($0)) })) {
                ForEach(InspectorFill.weights, id: \.self) { Text("\(NumberField.format($0, "")) pt", bundle: .module, comment: "A pen weight in points").tag($0) }
            }
            Picker(String(localized: "Pen Style", bundle: .module), selection: Binding(get: { ctl.tablePen["dash"]?.asStr ?? "solid" }, set: { ctl.tablePen.set("dash", .string($0)) })) {
                ForEach([
                    (String(localized: "Solid", bundle: .module, comment: "A line style"), "solid"), (String(localized: "Dash", bundle: .module, comment: "A line style"), "dash"),
                    (String(localized: "Dot", bundle: .module, comment: "A line style"), "sysDot"), (String(localized: "Dash Dot", bundle: .module, comment: "A line style"), "dashDot"),
                    (String(localized: "Long Dash", bundle: .module, comment: "A line style"), "lgDash"),
                ], id: \.1) { Text($0.0).tag($0.1) }
            }
            ColorButton(label: String(localized: "Pen Color", bundle: .module), color: Cmd.colorValue(ctl.tablePen["color"] ?? .null)?.resolve(scheme, nil), scheme: scheme) { c in
                if let c { ctl.tablePen.set("color", InspectorColors.param(c)) }
            }
            HStack {
                toolButton(String(localized: "Draw Table", bundle: .module), "pencil", Tools.drawTable)
                toolButton(String(localized: "Table Eraser", bundle: .module), "eraser", Tools.tableEraser)
            }
        }
        Section(String(localized: "Rows & Columns", bundle: .module)) {
            HStack {
                Button(String(localized: "Insert Above", bundle: .module)) { ctl.run("table.insertRowAbove") }
                Button(String(localized: "Insert Below", bundle: .module)) { ctl.run("table.insertRowBelow") }
            }
            HStack {
                Button(String(localized: "Insert Left", bundle: .module)) { ctl.run("table.insertColumnLeft") }
                Button(String(localized: "Insert Right", bundle: .module)) { ctl.run("table.insertColumnRight") }
            }
            Menu(String(localized: "Delete", bundle: .module)) {
                Button(String(localized: "Delete Columns", bundle: .module)) { ctl.run("table.deleteColumn") }
                Button(String(localized: "Delete Rows", bundle: .module)) { ctl.run("table.deleteRow") }
                Button(String(localized: "Delete Table", bundle: .module)) { ctl.run("edit.delete") }
            }
        }
        Section(String(localized: "Merge & Cell Size", bundle: .module)) {
            HStack {
                Button(String(localized: "Merge Cells", bundle: .module)) { ctl.run("table.merge") }.disabled(!ctl.enabled("table.merge"))
                Button(String(localized: "Split Cells", bundle: .module)) { ctl.run("table.split") }.disabled(!ctl.enabled("table.split"))
            }
            HStack {
                Button(String(localized: "Distribute Rows", bundle: .module)) { ctl.run("table.distributeRows") }
                Button(String(localized: "Distribute Columns", bundle: .module)) { ctl.run("table.distributeColumns") }
            }
        }
        Section(String(localized: "Alignment", bundle: .module)) {
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(InspectorText.aligns.prefix(3), id: \.1) { label, id, _, symbol in IconToggle(symbol: symbol, help: label) { ctl.run(id) } }
                Spacer()
                ForEach([
                    (String(localized: "Align text to the top of the cell", bundle: .module), "top", "arrow.up.to.line"),
                    (String(localized: "Align text to the center of the cell", bundle: .module), "middle", "arrow.up.and.down"),
                    (String(localized: "Align text to the bottom of the cell", bundle: .module), "bottom", "arrow.down.to.line"),
                ], id: \.1) { help, a, s in
                    IconToggle(symbol: s, help: help) { ctl.run("table.cellAlign", ["anchor": .string(a)]) }
                }
            }
            Menu(String(localized: "Cell Margins", bundle: .module)) {
                ForEach([
                    (String(localized: "Normal", bundle: .module, comment: "Cell margins preset"), "normal"), (String(localized: "None", bundle: .module), "none"),
                    (String(localized: "Narrow", bundle: .module, comment: "Cell margins preset"), "narrow"), (String(localized: "Wide", bundle: .module, comment: "Cell margins preset"), "wide"),
                ], id: \.1) { l, p in
                    Button(l) { ctl.run("table.cellMargins", ["preset": .string(p)]) }
                }
            }
        }
    }

    static let options: [(String, String)] = [
        (String(localized: "Header Row", bundle: .module), "headerRow"), (String(localized: "Total Row", bundle: .module), "totalRow"),
        (String(localized: "Banded Rows", bundle: .module), "bandedRows"), (String(localized: "First Column", bundle: .module), "firstColumn"),
        (String(localized: "Last Column", bundle: .module), "lastColumn"), (String(localized: "Banded Columns", bundle: .module), "bandedColumns"),
    ]
    static let borders: [(String, String)] = [
        (String(localized: "No Border", bundle: .module), "none"), (String(localized: "All Borders", bundle: .module), "all"),
        (String(localized: "Outside Borders", bundle: .module), "outside"), (String(localized: "Inside Borders", bundle: .module), "inside"),
        (String(localized: "Top Border", bundle: .module), "top"), (String(localized: "Bottom Border", bundle: .module), "bottom"),
        (String(localized: "Left Border", bundle: .module), "left"), (String(localized: "Right Border", bundle: .module), "right"),
        (String(localized: "Inside Horizontal Border", bundle: .module), "insideH"), (String(localized: "Inside Vertical Border", bundle: .module), "insideV"),
        (String(localized: "Diagonal Down Border", bundle: .module), "diagDown"), (String(localized: "Diagonal Up Border", bundle: .module), "diagUp"),
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
        Section(String(localized: "Chart", bundle: .module)) {
            Picker(String(localized: "Chart Type", bundle: .module), selection: Binding(get: { chart?.1.kind.rawValue ?? "" }, set: { k in
                if let id = chart?.0, let t = ChartType(rawValue: k) { ctl.run("chart.type", ["id": .integer(id.rawValue), "type": .string(ChartMenu.param(t))]) }
            })) {
                ForEach(Array(ChartMenu.types.enumerated()), id: \.offset) { i, group in
                    if i > 0 { Divider() }
                    ForEach(group, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            }
            Button(String(localized: "Edit Data…", bundle: .module)) { ctl.run("app.dialog", ["id": "chartData"]) }
        }
    }
}

// MARK: - SmartArt

struct SmartArtFormatView: View {
    let ctl: InspectorController

    var body: some View {
        if let (gid, d) = ctl.smartArt {
            let at = Swift.min(ctl.smartartRow, Swift.max(d.nodes.count - 1, 0))
            Section(String(localized: "Text Pane", bundle: .module)) {
                SmartArtTextPane(ctl: ctl, gid: gid, nodes: d.nodes)
            }
            Section(String(localized: "Create Graphic", bundle: .module)) {
                Menu {
                    ForEach([(String(localized: "Add Shape After", bundle: .module), "after"), (String(localized: "Add Shape Before", bundle: .module), "before"),
                             (String(localized: "Add Shape Above", bundle: .module), "above"), (String(localized: "Add Shape Below", bundle: .module), "below"),
                             (String(localized: "Add Assistant", bundle: .module), "assistant")], id: \.1) { l, pos in
                        Button(l) { ctl.smartArtEdit("smartArt.addNode", gid, ["index": d.nodes.isEmpty ? .null : .integer(at), "position": .string(pos)], focus: at + 1) }
                    }
                } label: { Label(String(localized: "Add Shape", bundle: .module), systemImage: "plus") } primaryAction: {
                    ctl.smartArtEdit("smartArt.addNode", gid, ["index": d.nodes.isEmpty ? .null : .integer(at), "position": "after"], focus: at + 1)
                }
                HStack {
                    Button(String(localized: "Promote", bundle: .module)) { ctl.smartArtEdit("smartArt.promote", gid, ["index": .integer(at)], focus: at) }.disabled(d.nodes.isEmpty)
                    Button(String(localized: "Demote", bundle: .module)) { ctl.smartArtEdit("smartArt.demote", gid, ["index": .integer(at)], focus: at) }.disabled(d.nodes.isEmpty)
                }
                Button(String(localized: "Insert Picture…", bundle: .module)) { ctl.run("app.smartArtPictureDialog", ["id": .integer(gid.rawValue), "index": .integer(at)]) }
                    .disabled(!(d.kind.hasPrefix("picture") && !d.nodes.isEmpty))
                    .help(String(localized: "Put a picture in the selected node's picture placeholder", bundle: .module))
            }
            Section(String(localized: "Layouts", bundle: .module)) {
                SmartArtLayoutMenu(title: String(localized: "Layouts", bundle: .module), current: d.kind) { ctl.run("smartArt.layout", ["id": .integer(gid.rawValue), "kind": .string($0)]) }
                Menu(String(localized: "Convert", bundle: .module)) {
                    Button(String(localized: "Convert to Text", bundle: .module)) { ctl.run("smartArt.toText", ["id": .integer(gid.rawValue)]) }
                    Button(String(localized: "Convert to Shapes", bundle: .module)) { ctl.run("smartArt.toShapes", ["id": .integer(gid.rawValue)]) }
                }
            }
            Section(String(localized: "SmartArt Styles", bundle: .module)) {
                Picker(String(localized: "Colors", bundle: .module), selection: Binding(get: { d.colors.isEmpty ? "colorful" : d.colors }, set: { ctl.run("smartArt.colors", ["id": .integer(gid.rawValue), "colors": .string($0)]) })) {
                    ForEach(SmartArtCommands.colors, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker(String(localized: "Style", bundle: .module), selection: Binding(get: { d.style.isEmpty ? "flat" : d.style }, set: { ctl.run("smartArt.style", ["id": .integer(gid.rawValue), "style": .string($0)]) })) {
                    ForEach(SmartArtCommands.styles, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        } else {
            Section { InspectorNote(text: String(localized: "Select a SmartArt graphic to edit its text.", bundle: .module)) }
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
            InspectorNote(text: String(localized: "Type your text here", bundle: .module))
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                HStack(spacing: Tokens.Space.xs) {
                    Text(verbatim: "•").foregroundStyle(Tokens.Color.secondaryLabel)
                    TextField(String(localized: "SmartArt text", bundle: .module), text: Binding(get: { drafts[i] ?? node.text }, set: { drafts[i] = $0 }))
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
                Button(String(localized: "+ Add", bundle: .module)) {
                    structural("smartArt.addNode", ["index": .integer(Swift.min(ctl.smartartRow, Swift.max(nodes.count - 1, 0))), "position": "after"], focus: ctl.smartartRow + 1, row: nil)
                }
                Button(String(localized: "Remove", bundle: .module)) {
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
        Section(String(localized: "Preview", bundle: .module)) {
            Button(String(localized: "Play/Pause", bundle: .module)) { ctl.run("media.toggle") }.disabled(m == nil)
            Button(String(localized: "Trim…", bundle: .module)) { ctl.run("app.dialog", ["id": "trim"]) }.disabled(m == nil)
        }
        Section(String(localized: "Options", bundle: .module)) {
            option(String(localized: "Start Automatically", bundle: .module), "autoplay", m?.autoplay)
            option(String(localized: "Play Across Slides", bundle: .module), "acrossSlides", m?.playAcrossSlides)
            option(String(localized: "Loop until Stopped", bundle: .module), "loop", m?.loopPlay)
            option(String(localized: "Hide During Show", bundle: .module), "hide", m?.hideWhileNotPlaying)
            option(String(localized: "Rewind after Playing", bundle: .module), "rewind", m?.rewind)
            option(String(localized: "Play Full Screen", bundle: .module), "fullScreen", m?.fullScreen)
            Picker(String(localized: "Volume", bundle: .module), selection: Binding(get: { m?.volume ?? 1 }, set: { ctl.run("media.options", ["volume": .num($0)]) })) {
                ForEach([
                    (String(localized: "Low", bundle: .module, comment: "Media volume"), 0.25), (String(localized: "Medium", bundle: .module, comment: "Media volume"), 0.5),
                    (String(localized: "High", bundle: .module, comment: "Media volume"), 1.0), (String(localized: "Mute", bundle: .module, comment: "Media volume"), 0.0),
                ], id: \.1) { Text($0.0).tag($0.1) }
                if let v = m?.volume, ![0.25, 0.5, 1.0, 0.0].contains(v) { Text(verbatim: "\(Int(v * 100))%").tag(v) }
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
