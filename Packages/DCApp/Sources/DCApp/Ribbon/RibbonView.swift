// DCApp — the ribbon (Docs/plans/Ribbon-and-StartScreen.md §4, R1): the tab row and the selected tab's groups, drawn
// from DCAppModel's `RibbonLayout` with what `RibbonModel` answers. Ports the drawing of deckcraft
// `crates/ui-egui/src/ribbon.rs` and `widgets.rs` (`big_button`, `small_button`, `split_menu`; MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) with native controls: every control runs its registry command
// through `ToolbarCatalog.perform`, as the toolbar's items do. Group captions are hidden, as PowerPoint for Mac
// hides them; each group still has its name for VoiceOver. Folding at narrow widths is R3; until then the groups
// scroll sideways.
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCModel
import DesignScaffold
import SwiftUI

struct RibbonView: View {
    let model: AppModel

    /// The tab row's height and the controls' (three rows of small controls, or a large one).
    static let tabHeight: CGFloat = 28
    static let bodyHeight: CGFloat = 84
    static func height(collapsed: Bool) -> CGFloat { tabHeight + (collapsed ? 0 : bodyHeight) + Tokens.Layout.hairline }

    var body: some View {
        // `revision` bumps after every command: the toggles and the enabled state follow it.
        let _ = model.revision
        let tab = RibbonModel.selected(model.ui)
        let fmt = RibbonModel.formatState(model.session)
        VStack(spacing: 0) {
            tabRow(tab)
            if !model.ui.ribbonCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(tab.groups, id: \.id) { g in
                            RibbonGroupView(group: g, model: model, fmt: fmt)
                            Divider().frame(height: Self.bodyHeight - Tokens.Space.m)
                        }
                    }
                    .padding(.horizontal, Tokens.Space.s)
                }
                .frame(height: Self.bodyHeight)
            }
            Divider()
        }
        .controlSize(.small)
    }

    private func tabRow(_ selected: RibbonTab) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            ForEach(RibbonModel.tabs, id: \.id) { t in
                let on = t.id == selected.id
                Button { run(CommandRef("view.tab", ["tab": .string(t.title)])) } label: {
                    Text(t.title)
                        .fontWeight(on ? .semibold : .regular)
                        .padding(.horizontal, Tokens.Space.s)
                        .padding(.vertical, Tokens.Space.xs / 2)
                        .overlay(alignment: .bottom) {
                            if on { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
                // A second click on the shown tab minimises the ribbon, or brings it back (`view.collapseRibbon`).
                .simultaneousGesture(TapGesture(count: 2).onEnded { if on { run(CommandRef("view.collapseRibbon")) } })
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                .accessibilityLabel(t.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.m)
        .frame(height: Self.tabHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Ribbon tabs", bundle: .module))
    }

    private func run(_ c: CommandRef) { RibbonActions.run(c) }
}

/// Running a ribbon command: through the toolbar's `perform`, which knows the canvas tools and the QAT's special cases.
@MainActor
enum RibbonActions {
    static func run(_ c: CommandRef) { ToolbarCatalog.perform(c.id, c.params) }

    static func press(_ c: RibbonControl, _ model: AppModel) { RibbonModel.press(c, model) { run($0) } }
}

/// One group: its controls in columns, large ones alone and small ones three to a column.
struct RibbonGroupView: View {
    let group: RibbonGroup
    let model: AppModel
    let fmt: JSON

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.xs) {
            ForEach(Array(RibbonModel.columns(group).enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: Tokens.Space.xs / 2) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 1) {
                            ForEach(row, id: \.id) { RibbonControlView(control: $0, model: model, fmt: fmt, size: RibbonModel.size($0)) }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: column.count == 1 && column.first?.count == 1 ? .top : .center)
            }
        }
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .frame(height: RibbonView.bodyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

/// One control, drawn for its kind and size.
struct RibbonControlView: View {
    let control: RibbonControl
    let model: AppModel
    let fmt: JSON
    let size: RibbonSize
    @State private var colorOpen = false

    private var label: String { RibbonModel.label(control) }
    private var symbol: String { RibbonModel.symbol(control) }
    private var enabled: Bool { RibbonModel.enabled(control, model) }

    var body: some View {
        content
            .disabled(!enabled)
            .help(RibbonModel.tip(control))
            .accessibilityHint(CommandHelp.description(control.command) ?? "")
    }

    @ViewBuilder private var content: some View {
        switch control.kind {
        case .button: button
        case .toggle: toggle
        case .split: split
        case .menu, .dropdown: menu
        case .gallery:
            if RibbonModel.primary(control, model) != nil { button } else { menu }
        case .check: check
        case .spinner(let field): spinner(field)
        case .color: color
        }
    }

    private func icon(_ large: Bool) -> some View {
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "square.dashed" : symbol)
            .font(.system(size: large ? 20 : 12))
            .frame(width: large ? 28 : 16, height: large ? 26 : 16)
    }

    /// A large control's face: the icon over its label (two lines at most).
    private var largeFace: some View {
        VStack(spacing: 2) {
            icon(true)
            Text(label).font(.caption).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, maxWidth: 76)
    }

    @ViewBuilder private var face: some View {
        switch size {
        case .large: largeFace
        case .medium: HStack(spacing: Tokens.Space.xs) { icon(false); Text(label).lineLimit(1) }
        case .small: icon(false)
        }
    }

    private var button: some View {
        Button { RibbonActions.press(control, model) } label: { face }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
    }

    private var toggle: some View {
        Toggle(isOn: Binding(get: { RibbonModel.isOn(control, fmt, model) }, set: { _ in RibbonActions.press(control, model) })) { face }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
    }

    /// A split control: the main half runs the command, the arrow opens the menu. Large splits put the label and
    /// arrow under the icon, as PowerPoint's do; the others are a native split menu button.
    @ViewBuilder private var split: some View {
        if size == .large {
            VStack(spacing: 0) {
                Button { RibbonActions.press(control, model) } label: { icon(true) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(label)
                Button { RibbonMenuPopup.show(RibbonModel.menu(control, model)) } label: { menuLabel }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "\(label) options", bundle: .module, comment: "A split button's menu half: the control's title, then 'options'"))
            }
            .frame(minWidth: 44, maxWidth: 76)
        } else {
            Menu { RibbonMenuItems(entries: RibbonModel.menu(control, model), model: model) } label: { face } primaryAction: {
                RibbonActions.press(control, model)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(label)
        }
    }

    /// A large control's label with the arrow that says it opens a menu.
    private var menuLabel: some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
    }

    /// A menu or gallery: large ones are a big button that opens the menu (SwiftUI's `Menu` would draw it small),
    /// the others a native pop-up.
    @ViewBuilder private var menu: some View {
        if size == .large {
            Button { RibbonMenuPopup.show(RibbonModel.menu(control, model)) } label: {
                VStack(spacing: 2) { icon(true); menuLabel }.frame(minWidth: 44, maxWidth: 80)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        } else {
            popUp
        }
    }

    private var popUp: some View {
        Menu { RibbonMenuItems(entries: RibbonModel.menu(control, model), model: model) } label: {
            if case .dropdown = control.kind { Text(RibbonModel.dropdownValue(control, fmt, model) ?? label).lineLimit(1) } else { face }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(minWidth: dropdownWidth, alignment: .leading)
        .accessibilityLabel(label)
    }

    private var dropdownWidth: CGFloat? {
        guard case .dropdown(let source) = control.kind else { return nil }
        return source == "fonts" ? 120 : source == "sizes" ? 44 : 100
    }

    private var check: some View {
        Toggle(label, isOn: Binding(get: { RibbonModel.isChecked(control, model) }, set: { RibbonActions.run(RibbonModel.check(control, $0)) }))
            .toggleStyle(.checkbox)
    }

    private func spinner(_ field: String) -> some View {
        NumberField(label: label, value: RibbonModel.spinnerValue(control, field, model) ?? 0, step: 0.25, suffix: " s", range: 0 ... 600) {
            RibbonActions.run(RibbonModel.spin(control, field, $0))
        }
        .frame(width: 150)
    }

    /// A colour split (`color_split`): the main half reapplies the last colour, the arrow opens the colour grid.
    private var color: some View {
        let ctl = InspectorFeature.controller
        return HStack(spacing: 0) {
            Button {
                switch control.command.id {
                case "shape.fill": ctl?.shapeFillButton()
                case "shape.line": ctl?.shapeOutlineButton()
                default: RibbonActions.press(control, model)
                }
            } label: { face }
                .buttonStyle(.borderless)
                .accessibilityLabel(label)
            Button { colorOpen.toggle() } label: { Image(systemName: "chevron.down").imageScale(.small) }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "\(label) options", bundle: .module, comment: "A split button's menu half: the control's title, then 'options'"))
                .popover(isPresented: $colorOpen, arrowEdge: .bottom) {
                    ColorGrid(scheme: InspectorColors.scheme(model.session), noneLabel: noneLabel) { c in
                        colorOpen = false
                        pick(c, ctl)
                    }
                }
        }
        .fixedSize()
    }

    private var noneLabel: String? {
        switch control.command.id {
        case "shape.fill": String(localized: "No Fill", bundle: .module)
        case "shape.line": String(localized: "No Outline", bundle: .module)
        case "format.highlight": String(localized: "No Color", bundle: .module)
        default: nil
        }
    }

    private func pick(_ c: ColorRef?, _ ctl: InspectorController?) {
        switch control.command.id {
        case "shape.fill": ctl?.pickFill(c)
        case "shape.line": ctl?.pickOutline(c)
        default: RibbonActions.run(CommandRef(control.command.id, ["color": c.map(InspectorColors.param) ?? .null]))
        }
    }
}

/// A large control's menu: an NSMenu built as the toolbar's are (`ToolbarCatalog.add`), shown under the pointer.
@MainActor
enum RibbonMenuPopup {
    static func show(_ entries: [CommandMenuEntry]) {
        guard !entries.isEmpty, let e = NSApp.currentEvent, let v = e.window?.contentView else { return }
        let menu = NSMenu()
        ToolbarCatalog.add(entries, to: menu)
        menu.popUp(positioning: nil, at: v.convert(e.locationInWindow, from: nil), in: v)
    }
}

/// A command menu's entries as SwiftUI menu items, each enabled by its command's check.
struct RibbonMenuItems: View {
    let entries: [CommandMenuEntry]
    let model: AppModel

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            switch e {
            case .item(let title, let c, let preset):
                Button { RibbonActions.run(c) } label: {
                    if let preset { Label { Text(title) } icon: { Image(nsImage: PresetIcons.image(preset)) } } else { Text(title) }
                }
                .disabled(!RibbonModel.enabled(c.id, model.session))
            case .separator:
                Divider()
            case .submenu(let title, let items):
                Menu(title) { AnyView(RibbonMenuItems(entries: items, model: model)) }
            }
        }
    }
}
