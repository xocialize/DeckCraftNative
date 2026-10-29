// DCApp — the ribbon (Docs/plans/Ribbon-and-StartScreen.md §4–§6, R1–R3): the tab row, with the contextual tabs the
// selection brings tinted, and the selected tab's groups, drawn from DCAppModel's `RibbonLayout` with what
// `RibbonModel` answers. Ports the drawing of deckcraft
// `crates/ui-egui/src/ribbon.rs` and `widgets.rs` (`big_button`, `small_button`, `split_menu`; MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) with native controls: every control runs its registry command
// through `ToolbarCatalog.perform`, as the toolbar's items do. Group captions are hidden, as PowerPoint for Mac
// hides them; each group still has its name for VoiceOver.
//
// R3: the groups fold as the window narrows (`RibbonFit`, from widths `RibbonMeasure` takes once per group and
// size), a collapsed group is one button whose popover holds the group, tabs that don't fit go into "»", and when
// nothing more can fold the groups scroll behind deckcraft's ‹ › chevrons. A minimised ribbon shows a clicked tab
// as a transient panel over the document. Keyboard focus moves with the arrow keys (`RibbonFocus`), ⌥↓ opens a
// split's menu, and Esc goes back to the canvas.
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCModel
import DesignScaffold
import Observation
import SwiftUI

/// What one window's ribbon knows beyond the model: its width, the transient panel of a minimised ribbon, where its
/// controls were drawn (for `ui.inspect`'s `truncated`), and keyboard focus.
@MainActor @Observable
final class RibbonViewState {
    var width: CGFloat = 0
    /// A minimised ribbon showing the selected tab's controls over the document until a command runs.
    var peek = false
    /// The split whose menu ⌥↓ asked to open.
    var openMenu: String?
    /// Where `view.focusRibbon` asked the keyboard to go.
    var focusRequest: String?
    @ObservationIgnored var focus: String?
    @ObservationIgnored var scrolling = false
    /// Where each shown control was drawn, in the ribbon's coordinates (top left, points), with the view that drew it.
    @ObservationIgnored var drawn: [String: (view: UUID, frame: CGRect)] = [:]
    var frames: [String: CGRect] { drawn.mapValues(\.frame) }
    @ObservationIgnored var tabFrames: [String: CGRect] = [:]
    /// The tabs the tab row shows, and those in "»".
    @ObservationIgnored var tabsShown: [String] = []
    @ObservationIgnored var tabsOverflow: [String] = []
    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored var onPeek: ((Bool) -> Void)?
}

extension EnvironmentValues {
    /// The ribbon a control is drawn in; nil in a measurement or a collapsed group's popover, which report nothing.
    @Entry var ribbonState: RibbonViewState?
    @Entry var ribbonFocus: FocusState<String?>.Binding?
}

struct RibbonView: View {
    let model: AppModel
    /// The window's ribbon state, which the container keeps across redraws.
    var state = RibbonViewState()
    @FocusState private var focus: String?

    /// The tab row's height and the controls' (three rows of small controls, or a large one).
    static let tabHeight: CGFloat = 28
    static let bodyHeight: CGFloat = 84
    static func height(collapsed: Bool) -> CGFloat { tabHeight + (collapsed ? 0 : bodyHeight) + Tokens.Layout.hairline }
    /// The coordinate space controls report their frames in.
    nonisolated static let space = "ribbon"
    /// The groups' horizontal inset, and the divider after each group.
    static let inset = Tokens.Space.s
    static let separator: CGFloat = 1
    /// How far a ‹ › chevron scrolls (`ribbon.rs` scrolls 160 px a click).
    static let scrollStep: CGFloat = 160

    var body: some View {
        // `revision` bumps after every command: the toggles and the enabled state follow it.
        let _ = model.revision
        let tab = RibbonModel.selected(model)
        let fmt = RibbonModel.formatState(model.session)
        let showBody = !model.ui.ribbonCollapsed || state.peek
        VStack(spacing: 0) {
            tabRow(tab)
            if showBody {
                groups(tab, fmt)
                    .frame(height: Self.bodyHeight)
                    .focusSection()
            }
            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.width = $0 }
        .controlSize(.small)
        .environment(\.ribbonState, state)
        .environment(\.ribbonFocus, $focus)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in move(press, tab) }
        .onKeyPress(.return) { activate(tab) }
        .onKeyPress(.escape) { escape() }
        .onChange(of: focus) { _, f in state.focus = f }
        .onChange(of: state.focusRequest) { _, r in
            guard let r else { return }
            focus = r
            state.focusRequest = nil
        }
        .onChange(of: state.peek) { _, p in state.onPeek?(p) }
    }

    // MARK: Tabs

    private func tabRow(_ selected: RibbonTab) -> some View {
        let all = RibbonModel.tabs(model)
        let widths = all.map { Double(Self.tabWidth($0.title)) }
        let fit = RibbonFit.tabs(widths, selected: all.firstIndex { $0.id == selected.id }, available: Double(state.width - 2 * Tokens.Space.m),
                                 more: Double(Self.moreWidth))
        let shown = fit.shown.compactMap { all.at($0) }
        let overflow = fit.overflow.compactMap { all.at($0) }
        state.tabsShown = shown.map(\.id)
        state.tabsOverflow = overflow.map(\.id)
        return HStack(spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(shown, id: \.id) { t in tabButton(t, on: t.id == selected.id) }
            }
            // VoiceOver hears a group of radio buttons, one per tab; a contextual tab says so (§6).
            .accessibilityRepresentation {
                Picker(String(localized: "Ribbon tabs", bundle: .module), selection: Binding(get: { selected.id }, set: { id in
                    if let t = all.first(where: { $0.id == id }) { pick(t) }
                })) {
                    ForEach(shown, id: \.id) { t in Text(Self.spoken(t)).tag(t.id) }
                }
                // Segmented, so the radio buttons lie along the row as the tabs do (a radio group stacks them).
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow, id: \.id) { t in Button(t.title) { pick(t) } }
                } label: { Text(verbatim: "»").frame(width: Self.moreWidth - 12) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "More tabs", bundle: .module, comment: "The ribbon's » button listing the tabs that don't fit"))
                    .accessibilityLabel(String(localized: "More tabs", bundle: .module, comment: "The ribbon's » button listing the tabs that don't fit"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.m)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.tabHeight, maxHeight: Self.tabHeight, alignment: .leading)
        .clipped()
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ t: RibbonTab, on: Bool) -> some View {
        Button { pick(t) } label: {
            Text(t.title)
                .fontWeight(on ? .semibold : .regular)
                // Contextual tabs are tinted with the accent colour (§3), as deckcraft's are.
                .foregroundStyle(t.contextual == nil ? Color.primary : Color.accentColor)
                .padding(.horizontal, Tokens.Space.s)
                .padding(.vertical, Tokens.Space.xs / 2)
                .overlay(alignment: .bottom) {
                    if on && (!model.ui.ribbonCollapsed || state.peek) { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
                .fixedSize()
        }
        .buttonStyle(.plain)
        .ribbonFocused($focus, "tab:" + t.id)
        // A second click on the shown tab minimises the ribbon, or brings it back (`view.collapseRibbon`).
        .simultaneousGesture(TapGesture(count: 2).onEnded { if on { run(CommandRef("view.collapseRibbon")) } })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { state.tabFrames[t.id] = $0 }
    }

    /// A tab: shown, or, on a minimised ribbon, shown as the transient panel; the shown tab of a panel closes it.
    private func pick(_ t: RibbonTab) {
        guard model.ui.ribbonCollapsed else {
            run(CommandRef("view.tab", ["tab": .string(t.title)]))
            return
        }
        if state.peek, RibbonModel.selected(model).id == t.id {
            state.peek = false
            return
        }
        run(CommandRef("view.tab", ["tab": .string(t.title), "peek": true]))
        state.peek = true
    }

    static func spoken(_ t: RibbonTab) -> String {
        t.contextual == nil ? t.title : String(localized: "\(t.title), contextual", bundle: .module, comment: "VoiceOver: a ribbon tab the selection brings")
    }

    /// The width a tab's button takes: its title, semibold (the widest it is drawn), and its padding.
    static func tabWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2 * Tokens.Space.s + Tokens.Space.xs
    }

    static let moreWidth: CGFloat = 32

    // MARK: Groups

    @ViewBuilder private func groups(_ tab: RibbonTab, _ fmt: JSON) -> some View {
        let fit = RibbonMeasure.fit(tab, model, width: state.width)
        let row = HStack(alignment: .top, spacing: 0) {
            ForEach(tab.groups, id: \.id) { g in
                let size = fit.sizes[g.id] ?? .large
                Group {
                    if size == .collapsed {
                        RibbonCollapsedGroup(group: g, model: model, fmt: fmt)
                    } else {
                        RibbonGroupView(group: g, model: model, fmt: fmt, size: size)
                    }
                }
                .id(g.id + "@" + size.rawValue)
                Divider().frame(height: Self.bodyHeight - Tokens.Space.m)
            }
        }
        .padding(.horizontal, Self.inset)
        let _ = state.scrolling = !fit.fits
        // No minimum width: the window narrows freely, and the groups fold to what it leaves them.
        Group {
            if fit.fits { row } else { RibbonScroller { row } }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: Keyboard

    private func places(_ tab: RibbonTab) -> [[String]] {
        let tabs = state.tabsShown.map { ["tab:" + $0] }
        guard !model.ui.ribbonCollapsed || state.peek else { return tabs }
        return RibbonFocus.columns(tab, RibbonMeasure.fit(tab, model, width: state.width).sizes)
    }

    /// The arrow keys: along the tab row, or through the controls (left and right in reading order, up and down
    /// within a column). ⌥↓ on a split opens its menu; ↓ from a tab goes into the controls.
    private func move(_ press: KeyPress, _ tab: RibbonTab) -> KeyPress.Result {
        guard let f = focus else { return .ignored }
        if f.hasPrefix("tab:") {
            let row = state.tabsShown.map { "tab:" + $0 }
            switch press.key {
            case .leftArrow, .rightArrow:
                guard let i = row.firstIndex(of: f), let to = row.at(i + (press.key == .leftArrow ? -1 : 1)) else { return .handled }
                focus = to
            case .downArrow:
                focus = RibbonFocus.next(nil, .first, in: places(tab))
            default: return .ignored
            }
            return .handled
        }
        if press.key == .downArrow, press.modifiers.contains(.option) {
            state.openMenu = f.hasSuffix("#menu") ? String(f.dropLast(5)) : f
            return .handled
        }
        let m: RibbonFocus.Move = switch press.key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
        let cols = places(tab)
        if m == .up, let col = cols.first(where: { $0.contains(f) }), col.first == f {
            // Up from the top of a column goes back to the tab row.
            focus = "tab:" + tab.id
            return .handled
        }
        if let to = RibbonFocus.next(f, m, in: cols) { focus = to }
        return .handled
    }

    /// Return runs the focused control; Space does too, as for any button.
    private func activate(_ tab: RibbonTab) -> KeyPress.Result {
        guard let f = focus else { return .ignored }
        if f.hasPrefix("tab:") {
            if let t = RibbonModel.tabs(model).first(where: { "tab:" + $0.id == f }) { pick(t) }
            return .handled
        }
        if f.hasSuffix("#menu") || f.hasPrefix("group:") {
            state.openMenu = f.hasPrefix("group:") ? f : String(f.dropLast(5))
            return .handled
        }
        guard let c = tab.groups.flatMap(\.controls).first(where: { $0.id == f }) else { return .ignored }
        RibbonActions.press(c, model)
        return .handled
    }

    /// Esc closes the transient panel and gives the keyboard back to the canvas (§6).
    private func escape() -> KeyPress.Result {
        state.peek = false
        focus = nil
        RibbonActions.focusCanvas(state.host?.window)
        return .handled
    }

    private func run(_ c: CommandRef) { RibbonActions.run(c) }
}

/// The groups when even fully folded they don't fit: deckcraft's ‹ › chevrons, 160 points a click.
struct RibbonScroller<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(x: 0)
    @State private var offset: CGFloat = 0
    @State private var overflow: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            chevron("chevron.left", String(localized: "Scroll the ribbon left", bundle: .module), enabled: offset > 0.5) {
                position.scrollTo(x: max(offset - RibbonView.scrollStep, 0))
            }
            ScrollView(.horizontal, showsIndicators: false) { content() }
                .scrollPosition($position)
                .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, max($0.contentSize.width - $0.containerSize.width, 0)] } action: { _, v in
                    offset = v.first ?? 0
                    overflow = v.last ?? 0
                }
            chevron("chevron.right", String(localized: "Scroll the ribbon right", bundle: .module), enabled: offset < overflow - 0.5) {
                position.scrollTo(x: min(offset + RibbonView.scrollStep, overflow))
            }
        }
    }

    private func chevron(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14, height: RibbonView.bodyHeight - Tokens.Space.m) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Measuring the groups: each group's width at each size it can take, taken once per locale and system font size
/// by drawing it off screen, then cached (§5). The ribbon asks `RibbonFit` with these, not with a measure per frame.
@MainActor
enum RibbonMeasure {
    private static var cache: [String: Double] = [:]

    static func width(_ g: RibbonGroup, _ size: GroupSize, _ model: AppModel) -> Double {
        let key = "\(Locale.current.identifier)|\(NSFont.systemFontSize)|\(g.id)|\(size.rawValue)"
        if let w = cache[key] { return w }
        let fmt = RibbonModel.formatState(model.session)
        let view: AnyView = size == .collapsed
            ? AnyView(RibbonCollapsedGroup(group: g, model: model, fmt: fmt).controlSize(.small))
            : AnyView(RibbonGroupView(group: g, model: model, fmt: fmt, size: size).controlSize(.small))
        let w = Double(NSHostingView(rootView: view).fittingSize.width)
        // A measurement that fails counts as wide, so the group folds rather than overlaps.
        let width = w.isFinite && w > 0 ? ceil(w) : 400
        cache[key] = width
        return width
    }

    static func measures(_ tab: RibbonTab, _ model: AppModel) -> [GroupMeasure] {
        tab.groups.map { g in
            GroupMeasure(id: g.id, foldOrder: g.foldOrder, steps: RibbonFit.sizes(g).map { .init($0, width(g, $0, model) + Double(RibbonView.separator)) })
        }
    }

    static func fit(_ tab: RibbonTab, _ model: AppModel, width: CGFloat) -> RibbonFit.Fit {
        RibbonFit.fit(measures(tab, model), available: Double(width - 2 * RibbonView.inset))
    }
}

/// Running a ribbon command: through the toolbar's `perform`, which knows the canvas tools and the QAT's special cases.
@MainActor
enum RibbonActions {
    /// Run `c`; a command run from a minimised ribbon's transient panel closes it (§5).
    static func run(_ c: CommandRef) {
        ToolbarCatalog.perform(c.id, c.params)
        closePeek()
    }

    static func closePeek() {
        for w in NSApp.windows {
            if let wc = w.windowController as? DocumentWindowController, let a = wc.ribbon, a.container.state.peek { a.container.state.peek = false }
        }
    }

    static func press(_ c: RibbonControl, _ model: AppModel) { RibbonModel.press(c, model) { run($0) } }

    /// The keyboard goes back to the window's canvas.
    static func focusCanvas(_ window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow, let wc = window.windowController as? DocumentWindowController else { return }
        window.makeFirstResponder(wc.canvas.canvas)
    }
}

/// One group: its controls in columns at the group's size, large ones alone and small ones three to a column.
struct RibbonGroupView: View {
    let group: RibbonGroup
    let model: AppModel
    let fmt: JSON
    var size: GroupSize = .large

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.xs) {
            ForEach(Array(RibbonModel.columns(group, size).enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: Tokens.Space.xs / 2) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 1) {
                            ForEach(row, id: \.id) { RibbonControlView(control: $0, model: model, fmt: fmt, size: RibbonFit.size($0, size)) }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: column.count == 1 && column.first?.count == 1 ? .top : .center)
            }
        }
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .frame(height: RibbonView.bodyHeight)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

/// A group folded to one button named after it (§5): the button shows the group at `.large` in a popover, which
/// closes when one of its commands runs.
struct RibbonCollapsedGroup: View {
    let group: RibbonGroup
    let model: AppModel
    let fmt: JSON
    @State private var open = false
    @Environment(\.ribbonState) private var state
    @Environment(\.ribbonFocus) private var focus

    var body: some View {
        let id = RibbonFocus.groupID(group)
        Button { open.toggle() } label: {
            VStack(spacing: 2) {
                RibbonIcon(symbol: RibbonModel.symbol(group: group), large: true)
                HStack(spacing: 2) {
                    // Two lines at most, wrapped rather than cut ("WordArt Styles").
                    Text(group.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .frame(maxWidth: RibbonModel.collapsedLabelWidth + 11)
            }
            .frame(minWidth: 44, maxWidth: 80)
        }
        .buttonStyle(.borderless)
        .ribbonFocused(focus, id)
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .frame(height: RibbonView.bodyHeight, alignment: .top)
        .fixedSize(horizontal: true, vertical: false)
        .help(group.title)
        .accessibilityLabel(group.title)
        .accessibilityHint(String(localized: "Shows the group's controls", bundle: .module, comment: "VoiceOver: a ribbon group folded into one button"))
        .reportFrame(group.id, state)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            RibbonGroupView(group: group, model: model, fmt: fmt, size: .large)
                .environment(\.ribbonState, nil)
                .environment(\.ribbonFocus, nil)
                .controlSize(.small)
                .onChange(of: model.revision) { open = false }
        }
        .onChange(of: state?.openMenu) { _, m in
            if m == id {
                open = true
                state?.openMenu = nil
            }
        }
    }
}

extension View {
    /// Focusable as `id` when the ribbon is tracking focus (not in a measurement or a popover). Buttons take the
    /// keyboard with Full Keyboard Access on, as everywhere in macOS (§6). The ribbon never makes them focusable
    /// itself: SwiftUI hands the keyboard to such a view when the window becomes key, which took it from the canvas
    /// and looped AppKit's constraint passes until it threw (R3, never committed).
    @ViewBuilder func ribbonFocused(_ focus: FocusState<String?>.Binding?, _ id: String) -> some View {
        if let focus { self.focused(focus, equals: id) } else { self }
    }

    /// Record where this was drawn, for `ui.inspect`'s `truncated`.
    func reportFrame(_ id: String, _ state: RibbonViewState?) -> some View { modifier(FrameReport(id: id, state: state)) }
}

/// A view's frame in the ribbon. When a group is redrawn at another size its new views appear before the old ones
/// go, so each removes only the frame it recorded.
private struct FrameReport: ViewModifier {
    let id: String
    let state: RibbonViewState?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if let state {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RibbonView.space)) } action: { state.drawn[id] = (token, $0) }
                .onDisappear { if state.drawn[id]?.view == token { state.drawn[id] = nil } }
        } else {
            content
        }
    }
}

struct RibbonIcon: View {
    let symbol: String
    let large: Bool

    var body: some View {
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "square.dashed" : symbol)
            .font(.system(size: large ? 20 : 12))
            .frame(width: large ? 28 : 16, height: large ? 26 : 16)
    }
}

/// One control, drawn for its kind and size.
struct RibbonControlView: View {
    let control: RibbonControl
    let model: AppModel
    let fmt: JSON
    let size: RibbonSize
    @State private var colorOpen = false
    @State private var shapesOpen = false
    @State private var galleryOpen = false
    @State private var frame: CGRect = .zero
    @Environment(\.ribbonState) private var state
    @Environment(\.ribbonFocus) private var focus

    private var label: String { RibbonModel.label(control) }
    private var symbol: String { RibbonModel.symbol(control) }
    private var enabled: Bool { RibbonModel.enabled(control, model) }
    private var options: String { String(localized: "\(label) options", bundle: .module, comment: "A split button's menu half: the control's title, then 'options'") }
    private var menuID: String { RibbonFocus.menuID(control) }

    var body: some View {
        content
            .disabled(!enabled)
            .help(RibbonModel.tip(control))
            .accessibilityHint(CommandHelp.description(control.command) ?? "")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RibbonView.space)) } action: { frame = $0 }
            .reportFrame(control.id, state)
            .onChange(of: state?.openMenu) { _, m in
                guard m == control.id else { return }
                state?.openMenu = nil
                openMenu()
            }
    }

    @ViewBuilder private var content: some View {
        switch control.kind {
        case .button: button
        case .toggle: toggle
        case .split: split
        case .menu, .dropdown: menu
        case .gallery:
            if RibbonModel.inlineGallery(control) && size == .large {
                RibbonGalleryView(control: control, model: model, enabled: enabled)
                    .ribbonFocused(focus, control.id)
            } else {
                RibbonGalleryButton(control: control, model: model, open: $galleryOpen) {
                    if size == .large { VStack(spacing: 2) { icon(true); menuLabel }.frame(minWidth: 44, maxWidth: 80) } else { menuFace }
                }
                .ribbonFocused(focus, control.id)
            }
        case .check: check
        case .spinner(let field): spinner(field)
        case .color: color
        }
    }

    /// What ⌥↓ (or Return on a menu half) opens: the menu, the colour grid, the shapes or the whole gallery.
    private func openMenu() {
        switch control.kind {
        case .color: colorOpen = true
        case .split(.shapes?): shapesOpen = true
        case .gallery: galleryOpen = true
        case .split, .menu: RibbonMenuPopup.show(RibbonModel.menu(control, model), below: frame, in: state?.host)
        default: break
        }
    }

    private func icon(_ large: Bool) -> some View { RibbonIcon(symbol: symbol, large: large) }

    /// A large control's face: the icon over its label (two lines at most).
    private var largeFace: some View {
        VStack(spacing: 2) {
            icon(true)
            Text(label).font(.caption).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, maxWidth: RibbonModel.largeLabelWidth)
    }

    @ViewBuilder private var face: some View {
        switch size {
        case .large: largeFace
        case .medium: HStack(spacing: Tokens.Space.xs) { icon(false); Text(label).lineLimit(1).fixedSize() }
        case .small: icon(false)
        }
    }

    /// A small menu's face, with the arrow that says it opens a menu.
    private var menuFace: some View {
        HStack(spacing: 2) {
            face
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
    }

    private var button: some View {
        Button { RibbonActions.press(control, model) } label: { face }
            .buttonStyle(.borderless)
            .ribbonFocused(focus, control.id)
            .accessibilityLabel(label)
    }

    private var toggle: some View {
        Toggle(isOn: Binding(get: { RibbonModel.isOn(control, fmt, model) }, set: { _ in RibbonActions.press(control, model) })) { face }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .ribbonFocused(focus, control.id)
            .accessibilityLabel(label)
    }

    /// A split control: two buttons, the main half running the command and the arrow opening the menu, so
    /// VoiceOver and the keyboard reach each (§6). Large splits put the label and arrow under the icon, as
    /// PowerPoint's do.
    @ViewBuilder private var split: some View {
        let menuAction = { if case .split(.shapes?) = control.kind { shapesOpen.toggle() } else { openMenu() } }
        Group {
            if size == .large {
                VStack(spacing: 0) {
                    Button { RibbonActions.press(control, model) } label: { icon(true) }
                        .buttonStyle(.borderless)
                        .ribbonFocused(focus, control.id)
                        .accessibilityLabel(label)
                    Button(action: menuAction) { menuLabel }
                        .buttonStyle(.borderless)
                        .ribbonFocused(focus, menuID)
                        .accessibilityLabel(options)
                }
                .frame(minWidth: 44, maxWidth: RibbonModel.largeLabelWidth)
            } else {
                HStack(spacing: 0) {
                    Button { RibbonActions.press(control, model) } label: { face }
                        .buttonStyle(.borderless)
                        .ribbonFocused(focus, control.id)
                        .accessibilityLabel(label)
                    Button(action: menuAction) { Image(systemName: "chevron.down").imageScale(.small) }
                        .buttonStyle(.borderless)
                        .ribbonFocused(focus, menuID)
                        .accessibilityLabel(options)
                }
                .fixedSize()
            }
        }
        .popover(isPresented: $shapesOpen, arrowEdge: .bottom) {
            RibbonShapesGrid(entries: RibbonModel.menu(control, model), model: model) { shapesOpen = false }
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
            Button { openMenu() } label: {
                VStack(spacing: 2) { icon(true); menuLabel }.frame(minWidth: 44, maxWidth: 80)
            }
            .buttonStyle(.borderless)
            .ribbonFocused(focus, control.id)
            .accessibilityLabel(label)
        } else {
            popUp
        }
    }

    private var popUp: some View {
        Menu { RibbonMenuItems(entries: RibbonModel.menu(control, model), model: model) } label: {
            if case .dropdown = control.kind { Text(RibbonModel.dropdownValue(control, fmt, model) ?? label).lineLimit(1).truncationMode(.tail) } else { face }
        }
        .menuStyle(.borderlessButton)
        .modifier(DropdownWidth(width: dropdownWidth))
        .ribbonFocused(focus, control.id)
        .accessibilityLabel(label)
    }

    /// A drop-down list is a fixed width, so the group measures the same whatever font or size it shows.
    private struct DropdownWidth: ViewModifier {
        let width: CGFloat?
        func body(content: Content) -> some View {
            if let width { content.frame(width: width, alignment: .leading) } else { content.fixedSize() }
        }
    }

    private var dropdownWidth: CGFloat? {
        guard case .dropdown(let source) = control.kind else { return nil }
        return source == "fonts" ? 120 : source == "sizes" ? 48 : 100
    }

    private var check: some View {
        Toggle(label, isOn: Binding(get: { RibbonModel.isChecked(control, model) }, set: { RibbonActions.run(RibbonModel.check(control, $0)) }))
            .toggleStyle(.checkbox)
            .fixedSize()
            .ribbonFocused(focus, control.id)
    }

    private func spinner(_ field: String) -> some View {
        let f = RibbonModel.spinnerFormat(control, model)
        return NumberField(label: label, value: RibbonModel.spinnerValue(control, field, model) ?? 0, step: f.step, suffix: f.suffix, range: f.range) {
            RibbonActions.run(RibbonModel.spin(control, field, $0, units: model.session.prefs.units))
        }
        .frame(width: control.command.id == "shape.resize" ? 130 : 150)
        .ribbonFocused(focus, control.id)
    }

    /// A colour split (`color_split`): the main half reapplies the last colour, the arrow opens the colour grid.
    private var color: some View {
        let ctl = InspectorFeature.controller
        return HStack(spacing: 0) {
            Button {
                switch control.command.id {
                case "shape.fill": ctl?.shapeFillButton()
                case "shape.line" where control.id != "pictureFormat.border": ctl?.shapeOutlineButton()
                default: RibbonActions.press(control, model)
                }
                RibbonActions.closePeek()
            } label: { face }
                .buttonStyle(.borderless)
                .ribbonFocused(focus, control.id)
                .accessibilityLabel(label)
            Button { colorOpen.toggle() } label: { Image(systemName: "chevron.down").imageScale(.small) }
                .buttonStyle(.borderless)
                .ribbonFocused(focus, menuID)
                .accessibilityLabel(options)
                .popover(isPresented: $colorOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        ColorGrid(scheme: InspectorColors.scheme(model.session), noneLabel: noneLabel) { c in
                            colorOpen = false
                            pick(c, ctl)
                            RibbonActions.closePeek()
                        }
                        // An outline's weight, dashes and arrows (`outline_menu`).
                        let extras = RibbonMenus.colorExtras(control.id)
                        if !extras.isEmpty {
                            Divider()
                            HStack { RibbonMenuItems(entries: extras, model: model) }.fixedSize()
                        }
                    }
                    .padding(extrasPadding)
                }
        }
        .fixedSize()
    }

    private var extrasPadding: CGFloat { RibbonMenus.colorExtras(control.id).isEmpty ? 0 : Tokens.Space.s }

    private var noneLabel: String? {
        switch control.command.id {
        case "shape.fill", "table.cellFill": String(localized: "No Fill", bundle: .module)
        case "shape.line", "format.textOutline": String(localized: "No Outline", bundle: .module)
        case "format.highlight": String(localized: "No Color", bundle: .module)
        default: nil
        }
    }

    private func pick(_ c: ColorRef?, _ ctl: InspectorController?) {
        switch control.command.id {
        case "shape.fill": ctl?.pickFill(c)
        // Picture Border is a frame of its own: it doesn't change the outline colour Shape Outline reapplies.
        case "shape.line" where control.id == "pictureFormat.border":
            RibbonActions.run(CommandRef("shape.line", c.map { ["color": InspectorColors.param($0)] } ?? ["none": true]))
        case "shape.line": ctl?.pickOutline(c)
        case "table.cellFill": RibbonActions.run(CommandRef("table.cellFill", c.map { ["color": InspectorColors.param($0)] } ?? ["none": true]))
        default: RibbonActions.run(CommandRef(control.command.id, ["color": c.map(InspectorColors.param) ?? .null]))
        }
    }
}

/// A control's menu: an NSMenu built as the toolbar's are (`ToolbarCatalog.add`), dropped below the control, or
/// under the pointer when the control's place isn't known (a collapsed group's popover).
@MainActor
enum RibbonMenuPopup {
    static func show(_ entries: [CommandMenuEntry], below frame: CGRect, in host: NSView?) {
        guard !entries.isEmpty else { return }
        let menu = NSMenu()
        ToolbarCatalog.add(entries, to: menu)
        if let host, frame.width > 0 {
            // The hosting view is flipped: the frame's bottom is its maxY.
            let y = host.isFlipped ? frame.maxY : host.bounds.height - frame.maxY
            if menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: y), in: host) { RibbonActions.closePeek() }
        } else if let e = NSApp.currentEvent, let v = e.window?.contentView {
            if menu.popUp(positioning: nil, at: v.convert(e.locationInWindow, from: nil), in: v) { RibbonActions.closePeek() }
        }
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
