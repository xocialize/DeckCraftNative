// DCApp — Format ▸ Text: the Font and Paragraph groups of deckcraft's Home ribbon (`font_group`,
// `paragraph_group`), Format Shape ▸ Text Options (Text Fill, Text Box: alignment, autofit, wrap, margins,
// columns), and Shape Format ▸ WordArt Styles (Text Fill, Text Outline, Text Effects ▸ Shadow and
// Transform) from `crates/ui-egui/src/ribbon.rs` and `panes.rs` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). The state comes from `format.state`; every control runs a registry command.
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI

struct TextFormatView: View {
    let ctl: InspectorController
    let sh: DCModel.Shape?

    var body: some View {
        let st = ctl.formatState()
        let en = ctl.enabled("format.bold")
        FontSection(ctl: ctl, st: st, enabled: en)
        ParagraphSection(ctl: ctl, st: st, enabled: en)
        if let sh { TextBoxSection(ctl: ctl, sh: sh) }
    }
}

struct FontSection: View {
    let ctl: InspectorController
    let st: JSON
    let enabled: Bool

    var body: some View {
        let scheme = InspectorColors.scheme(ctl.session)
        let fams = InspectorText.fontFamilies(ctl.doc, installed: NSFontManager.shared.availableFontFamilies)
        let font = st["font"]?.asStr ?? ""
        Section("Font") {
            Picker("Font", selection: Binding(get: { font }, set: { ctl.run("format.font", ["family": .string($0)]) })) {
                if !fams.all.contains(font) { Text(font).tag(font) }
                ForEach(Array(fams.theme.enumerated()), id: \.offset) { i, f in Text(fams.theme.count == 1 ? "\(f) (Headings and Body)" : "\(f) (\(i == 0 ? "Headings" : "Body"))").tag(f) }
                Divider()
                ForEach(fams.all.dropFirst(fams.theme.count), id: \.self) { Text($0).tag($0) }
            }
            .disabled(!enabled)
            HStack {
                NumberField(label: "Size", value: st["size"]?.asF64 ?? 18, step: 1, suffix: " pt", range: 1 ... 4000) { ctl.run("format.size", ["size": .num($0)]) }
                Menu {
                    ForEach(InspectorText.sizes, id: \.self) { s in Button(NumberField.format(s, "")) { ctl.run("format.size", ["size": .num(s)]) } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Font Size")
            }
            .disabled(!enabled)
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(InspectorText.styles, id: \.1) { label, id, key, symbol in
                    IconToggle(symbol: symbol, help: label, on: st[key]?.asBool ?? false, enabled: enabled) { ctl.run(id) }
                }
                Spacer()
                IconToggle(symbol: "textformat.size.larger", help: "Increase Font Size", enabled: enabled) { ctl.run("format.grow") }
                IconToggle(symbol: "textformat.size.smaller", help: "Decrease Font Size", enabled: enabled) { ctl.run("format.shrink") }
                IconToggle(symbol: "eraser", help: "Clear All Formatting", enabled: enabled) { ctl.run("format.clear") }
            }
            HStack {
                Menu("Character Spacing") {
                    ForEach(InspectorText.spacings, id: \.0) { l, pt in Button(l) { ctl.run("format.spacing", ["pt": .num(pt)]) } }
                }
                Menu("Change Case") {
                    ForEach(InspectorText.cases, id: \.1) { l, m in Button(l) { ctl.run("format.case", ["mode": .string(m)]) } }
                }
            }
            .disabled(!enabled)
            Group {
                ColorSplitButton(title: "Font Color", symbol: "character", color: .rgb(0xC0, 0, 0), scheme: scheme, enabled: enabled,
                                 primary: { ctl.run("format.color", ["color": "#C00000"]) },
                                 pick: { c in if let c { ctl.run("format.color", ["color": InspectorColors.param(c)]) } })
                ColorSplitButton(title: "Text Highlight Color", symbol: "highlighter", color: .rgb(255, 255, 0), scheme: scheme, noneLabel: "No Color", enabled: enabled,
                                 primary: { ctl.run("format.highlight", ["color": "#FFFF00"]) },
                                 pick: { c in ctl.run("format.highlight", ["color": c.map(InspectorColors.param) ?? .null]) })
            }
            HStack {
                Button("Font…") { ctl.run("format.fontDialog") }.disabled(!enabled)
                Button("Rescan Installed Fonts") { ctl.run("font.rescan") }
            }
        }
    }
}

struct ParagraphSection: View {
    let ctl: InspectorController
    let st: JSON
    let enabled: Bool

    var body: some View {
        let en = ctl.enabled("format.bullets")
        let align = st["align"]?.asStr ?? ""
        Section("Paragraph") {
            HStack(spacing: Tokens.Layout.hairline) {
                ForEach(InspectorText.aligns, id: \.1) { label, id, key, symbol in
                    IconToggle(symbol: symbol, help: label, on: align == key, enabled: en) { ctl.run(id) }
                }
                Spacer()
                IconToggle(symbol: "decrease.indent", help: "Decrease List Level", enabled: en) { ctl.run("format.outdent") }
                IconToggle(symbol: "increase.indent", help: "Increase List Level", enabled: en) { ctl.run("format.indent") }
            }
            HStack {
                // Split buttons: the main half toggles, the menu picks a style (`small_button_named`).
                Menu {
                    Button("None") { ctl.run("format.bullets", ["on": false]) }
                    ForEach(InspectorText.bulletChars, id: \.self) { ch in Button("\(ch)  Bullet") { ctl.run("format.bullets", ["on": true, "char": .string(ch)]) } }
                    Divider()
                    Button("Bullets and Numbering…") { ctl.run("app.dialog", ["id": "bullets", "tab": "bulleted"]) }
                } label: {
                    Label("Bullets", systemImage: "list.bullet")
                } primaryAction: { ctl.run("format.bullets") }
                    .accessibilityLabel("Bullets")
                Menu {
                    Button("None") { ctl.run("format.numbering", ["on": false]) }
                    ForEach(InspectorText.numberings, id: \.1) { l, s in Button(l) { ctl.run("format.numbering", ["on": true, "scheme": .string(s)]) } }
                    Divider()
                    Button("Bullets and Numbering…") { ctl.run("app.dialog", ["id": "bullets", "tab": "numbered"]) }
                } label: {
                    Label("Numbering", systemImage: "list.number")
                } primaryAction: { ctl.run("format.numbering") }
                    .accessibilityLabel("Numbering")
            }
            .disabled(!en)
            HStack {
                Menu("Line Spacing") {
                    ForEach(InspectorText.lineSpacings, id: \.self) { v in Button(rustFixed(v, places: 1)) { ctl.run("format.lineSpacing", ["lines": .num(v)]) } }
                    Divider()
                    Button("Line Spacing Options…") { ctl.run("format.paragraphDialog") }
                    Button("Tabs…") { ctl.run("app.dialog", ["id": "tabs"]) }
                }
                Menu("Columns") {
                    ForEach(1 ... 3, id: \.self) { n in Button("\(n) Column\(n > 1 ? "s" : "")") { ctl.run("format.columns", ["count": .integer(n), "spacing": 18]) } }
                    Button("More Columns…") { ctl.run("format.columns") }
                }
            }
            .disabled(!en)
            HStack {
                Menu("Text Direction") {
                    ForEach(InspectorText.directions, id: \.1) { l, d in Button(l) { ctl.run("format.direction", ["dir": .string(d)]) } }
                }
                ConvertToSmartArtMenu(ctl: ctl)
            }
            .disabled(!en)
            Button("Paragraph…") { ctl.run("format.paragraphDialog") }.disabled(!en)
        }
    }
}

/// Home ▸ Paragraph ▸ Convert to SmartArt: the layouts by category.
struct ConvertToSmartArtMenu: View {
    let ctl: InspectorController
    var body: some View {
        SmartArtLayoutMenu(title: "Convert to SmartArt", current: nil) { ctl.run("smartArt.fromText", ["kind": .string($0)]) }
            .disabled(!ctl.enabled("smartArt.fromText"))
    }
}

/// A SmartArt layout menu, by category (`smartart_gallery`).
struct SmartArtLayoutMenu: View {
    let title: String
    let current: String?
    let pick: (String) -> Void

    static let categories: [(String, String)] = [
        ("list", "List"), ("process", "Process"), ("cycle", "Cycle"), ("hierarchy", "Hierarchy"),
        ("relationship", "Relationship"), ("matrix", "Matrix"), ("pyramid", "Pyramid"), ("picture", "Picture"),
    ]

    var body: some View {
        Menu(title) {
            ForEach(Self.categories, id: \.0) { cat, label in
                let kinds = SmartArtCommands.layouts.filter { SmartArtCommands.category($0.0) == cat }
                if !kinds.isEmpty {
                    Section(label) {
                        ForEach(kinds, id: \.0) { k, l in
                            Toggle(l, isOn: Binding(get: { current == k }, set: { _ in pick(k) }))
                        }
                    }
                }
            }
        }
    }
}

struct TextBoxSection: View {
    let ctl: InspectorController
    let sh: DCModel.Shape

    var body: some View {
        let scheme = InspectorColors.scheme(ctl.session)
        Section("Text Fill") {
            ColorButton(label: "Color", color: nil, scheme: scheme) { c in
                ctl.run("format.color", ["color": c.map(InspectorColors.param) ?? "tx1"])
            }
            CommitSlider(label: "Transparency", value: InspectorFill.textTransparency(sh) * 100, range: 0 ... 100, suffix: "%") {
                ctl.run("format.textTransparency", ["value": .num($0 / 100)])
            }
        }
        Section("Text Effects") {
            ColorButton(label: "Text Outline", color: nil, scheme: scheme, noneLabel: "No Outline") { c in
                ctl.run("format.textOutline", ["color": c.map(InspectorColors.param) ?? .null])
            }
            Button("Shadow") { ctl.run("format.textShadow") }
            Menu("Transform") {
                Button("No Transform") { ctl.run("format.textWarp", ["preset": "none"]) }
                Section("Follow Path") {
                    ForEach(InspectorText.followPaths, id: \.id) { p in warpItem(p) }
                }
                Section("Warp") {
                    ForEach(InspectorText.warps, id: \.id) { p in warpItem(p) }
                }
            }
        }
        Section("Text Box") {
            Picker("Vertical alignment", selection: Binding(get: { InspectorText.anchor(sh) ?? "" }, set: { ctl.run("format.anchor", ["anchor": .string($0)]) })) {
                if InspectorText.anchor(sh) == nil { Text("—").tag("") }
                ForEach(InspectorText.anchors, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            Picker("Autofit", selection: Binding(get: { autofit }, set: { ctl.run("format.autofit", ["mode": .string($0)]) })) {
                ForEach(InspectorText.autofits, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Wrap text in shape", isOn: Binding(get: { sh.text?.body.wrap ?? true }, set: { ctl.run("format.wrap", ["on": .bool($0)]) }))
            ForEach(InspectorText.margins(sh), id: \.key) { m in
                NumberField(label: "\(m.label) margin", value: m.value, step: 1, suffix: " pt") { v in
                    var p: JSON = .emptyObject
                    p.set(m.key, .num(Swift.max(v, 0)))
                    ctl.run("format.margins", p)
                }
            }
            NumberField(label: "Columns", value: Double(sh.text?.body.columns ?? 1), step: 1, range: 1 ... 16) { ctl.run("format.columns", ["count": .integer(Int($0)), "spacing": 18]) }
            Button("Columns…") { ctl.run("format.columns") }
        }
    }

    private var autofit: String {
        switch sh.text?.body.autofit {
        case .shrink?: "shrink"
        case .shape?: "resize"
        default: "none"
        }
    }

    private func warpItem(_ p: Warp.PresetInfo) -> some View {
        Toggle(p.label, isOn: Binding(get: { InspectorText.warp(ctl.doc) == p.id }, set: { _ in ctl.run("format.textWarp", ["preset": .string(p.id)]) }))
    }
}
