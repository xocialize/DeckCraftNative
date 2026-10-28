// DCAppModel — what the ribbon shows and runs, without a window (Docs/plans/Ribbon-and-StartScreen.md §4, §6, R1):
// the window layout, the selected tab, each control's label, tooltip, symbol, enabled and toggle state, and the
// command a click runs, with deckcraft's parameters. Ports the state reads of deckcraft `crates/ui-egui/src/ribbon.rs`
// (`fmt_state`, `enabled`) and the per-control parameters of `ribbon/{home,transitions,animations,slide_show,view}.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). DCApp's `RibbonView` draws what this answers.
import DCCore
import DCEngine
import DCModel
import Foundation

/// The window's layout (§8): the toolbar and inspector (deckcraft's ribbon dropped, the Mac default), or the ribbon.
public enum WindowLayout: String, Codable, Sendable, CaseIterable {
    case mac, ribbon
}

@MainActor
public enum RibbonModel {
    // MARK: Tabs

    /// The tabs R1 draws: the ten regular ones. The contextual tabs follow in R2.
    public static var tabs: [RibbonTab] { RibbonLayout.regular }

    /// The tab `UiState.tab` names. It holds deckcraft's tab title ("Home", "Slide Show"); a tab id is accepted too.
    /// Anything else, a contextual tab included until R2, shows Home.
    public static func selected(_ ui: UiState) -> RibbonTab {
        tabs.first { $0.title == ui.tab || $0.id == ui.tab } ?? RibbonLayout.home
    }

    // MARK: Labels and tooltips

    /// The registry's English label for a command, or nil for the canvas tools.
    static func registryLabel(_ id: String) -> String? { findCommand(id)?.label ?? UICommands.find(id)?.label }

    /// The control's label: its title, or its command's label as the Commands catalog has it.
    public static func label(_ c: RibbonControl) -> String {
        if let t = c.title { return t }
        guard let l = registryLabel(c.command.id) else { return c.id }
        return L10n.commandLabel(c.command.id, l)
    }

    /// The tooltip (decision 3): the label with the shortcut, then the one-line description.
    public static func tip(_ c: RibbonControl) -> String {
        CommandHelp.tip(c.command, label: label(c))
    }

    /// The control's SF Symbol.
    public static func symbol(_ c: RibbonControl) -> String {
        CommandSymbols.symbol(control: c.id) ?? CommandSymbols.symbol(c.command) ?? "square.dashed"
    }

    // MARK: State

    /// Whether command `id` can run now: the registry's `enabled` check; the UI commands and the canvas tools need
    /// a presentation, except the ones that open a file or change the view of the app.
    public static func enabled(_ id: String, _ session: Session) -> Bool {
        if id == "file.new" || id == "app.openDialog" || id == "view.ribbon" || id == "view.dark" { return true }
        if id.hasPrefix("tool.") || UICommands.contains(id) { return session.activeDoc != nil }
        guard let spec = findCommand(id) else { return false }
        return spec.enabled(session) == nil
    }

    /// Whether the control can be used now. A gallery or menu control is enabled when its main command is.
    public static func enabled(_ c: RibbonControl, _ model: AppModel) -> Bool {
        guard enabled(c.command.id, model.session) else { return false }
        switch c.kind {
        case .spinner(let field): return spinnerValue(c, field, model) != nil
        default: return true
        }
    }

    /// `format.state`, read once per refresh (`fmt_state`).
    public static func formatState(_ session: Session) -> JSON {
        guard session.activeDoc != nil else { return .emptyObject }
        return (try? session.execute("format.state", .emptyObject)) ?? .emptyObject
    }

    /// `format.state`'s `align` for each alignment command.
    static let alignState = ["format.alignLeft": "l", "format.alignCenter": "ctr", "format.alignRight": "r", "format.justify": "just"]

    /// A toggle's state: on while its `state` is set (`ribbon/*.rs`' `toggle(…, on)`).
    public static func isOn(_ c: RibbonControl, _ fmt: JSON, _ model: AppModel) -> Bool {
        guard case .toggle(let state) = c.kind else { return false }
        let ui = model.ui, session = model.session
        switch state {
        case "align": return fmt["align"]?.asStr == alignState[c.command.id]
        case "painter": return session.painter != nil
        case "animationPainter": return session.animPainter != nil
        case "tool":
            guard case .ink(let mode, let color, let width) = session.tool.kind,
                  let pen = InspectorShape.pens.at(Int(c.command.params["pen"]?.asU64 ?? 0)) else { return false }
            return pen.mode == mode && pen.color == color && pen.width == width
        case "presenterView": return ui.presenterView
        case "hidden": return session.activeDoc?.currentSlide?.hidden ?? false
        case "view": return "view.\(ui.view.rawValue)" == c.command.id
        case "target":
            let target = session.activeDoc?.selection.target ?? .slides
            switch (c.command.id, target) {
            case ("view.slideMaster", .master), ("view.slideMaster", .layout), ("view.handoutMaster", .handout), ("view.notesMaster", .notesMaster):
                return true
            default: return false
            }
        case "notes": return ui.notes
        case "grayscale": return ui.grayscale
        case "dark": return ui.brightness == .dark
        default: return fmt[state]?.asBool ?? false
        }
    }

    /// A check box's state.
    public static func isChecked(_ c: RibbonControl, _ model: AppModel) -> Bool {
        guard case .check(let field) = c.kind else { return false }
        switch (c.command.id, field) {
        case ("view.ruler", _): return model.ui.ruler
        case ("view.gridlines", _): return model.ui.gridlines
        case ("view.guides", _): return model.ui.guides
        case ("show.setup", "useTimings"): return model.session.activeDoc?.doc.show.useTimings ?? false
        // Play Narrations is on while the show isn't set to run without them.
        case ("show.setup", "noNarration"): return !(model.session.activeDoc?.doc.show.withoutNarration ?? false)
        case ("show.setup", "showMediaControls"): return model.session.activeDoc?.doc.show.showMediaControls ?? false
        case ("transition.timing", "onClick"): return model.session.activeDoc?.currentSlide?.transition?.advanceOnClick ?? true
        default: return false
        }
    }

    /// What a check box runs when it is set to `on`.
    public static func check(_ c: RibbonControl, _ on: Bool) -> CommandRef {
        guard case .check(let field) = c.kind else { return c.command }
        // `noNarration` is the opposite of the box, Play Narrations.
        let value = field == "noNarration" ? !on : on
        return CommandRef(c.command.id, [field: .bool(value)])
    }

    /// A spinner's value in seconds, or nil when there is nothing to set (no transition, no animation picked).
    public static func spinnerValue(_ c: RibbonControl, _ field: String, _ model: AppModel) -> Double? {
        let doc = model.session.activeDoc
        switch (c.command.id, field) {
        case ("transition.timing", "duration"):
            guard let slide = doc?.currentSlide else { return nil }
            return Double(slide.transition?.durationMs ?? 0) / 1000
        case ("transition.timing", "after"):
            guard let slide = doc?.currentSlide else { return nil }
            return Double(slide.transition?.advanceAfterMs ?? 0) / 1000
        case ("animation.timing", "duration"): return currentAnimation(model).map { Double($0.durationMs) / 1000 }
        case ("animation.timing", "delay"): return currentAnimation(model).map { Double($0.delayMs) / 1000 }
        default: return nil
        }
    }

    /// What a spinner runs for `seconds` (`(v.max(0.0) * 1000.0).round()` milliseconds).
    public static func spin(_ c: RibbonControl, _ field: String, _ seconds: Double) -> CommandRef {
        CommandRef(c.command.id, [field: InspectorMotion.ms(seconds.isFinite ? Swift.max(seconds, 0) : 0)])
    }

    /// The selected shape's first animation on this slide, as the Animations tab edits it.
    static func currentAnimation(_ model: AppModel) -> Animation? {
        guard let d = model.session.activeDoc, let shape = d.selection.shapes.first, let slide = d.currentSlide else { return nil }
        return slide.animations.first { $0.shape == shape }
    }

    // MARK: What a click runs

    /// The command the control's button (or a split's main half) runs, with deckcraft's parameters. nil for a
    /// control that only opens its menu or gallery.
    public static func primary(_ c: RibbonControl, _ model: AppModel) -> CommandRef? {
        let slide = JSON.integer(model.session.activeDoc?.selection.slide ?? 0)
        switch c.kind {
        // Quick Styles' grid is in the Format pane until R2 draws the gallery in the ribbon.
        case .gallery where c.id.hasSuffix(".quickStyles"): return CommandRef("view.pane", ["pane": "format"])
        case .menu, .gallery, .dropdown, .spinner, .check: return nil
        case .color:
            // The main half reapplies the last colour; these are deckcraft's starting colours.
            switch c.command.id {
            case "format.highlight": return CommandRef("format.highlight", ["color": "#FFFF00"])
            case "format.color": return CommandRef("format.color", ["color": "#C00000"])
            case "shape.fill": return CommandRef("shape.fill", ["color": "accent1"])
            case "shape.line": return CommandRef("shape.line", ["color": "tx1"])
            default: return c.command
            }
        case .button, .toggle, .split: break
        }
        switch c.id {
        case "record.fromCurrent": return CommandRef("show.start", ["rehearse": true, "from": slide])
        case "transitions.preview": return CommandRef("show.start", ["from": slide, "preview": true])
        default: return c.command
        }
    }

    /// A click on the control's button (or main half). A painter that is on is turned off by its own button, as
    /// deckcraft does (`session.painter = None`); everything else runs `primary`. The canvas tools (`tool.*`) are
    /// the host's, so it gets them through `run`.
    public static func press(_ c: RibbonControl, _ model: AppModel, run: (CommandRef) -> Void) {
        if c.command.id == "format.painter", model.session.painter != nil {
            model.session.painter = nil
            model.changed()
        } else if c.command.id == "animation.painter", model.session.animPainter != nil {
            model.session.animPainter = nil
            model.changed()
        } else if let p = primary(c, model) {
            run(p)
        }
    }

    /// The menu the control's arrow (or the whole control) opens: the shared `CommandMenus`, or the ribbon's own.
    public static func menu(_ c: RibbonControl, _ model: AppModel) -> [CommandMenuEntry] {
        switch c.kind {
        case .split(let id?), .menu(let id?):
            let layouts = model.session.activeDoc?.doc.masters.first?.layouts ?? []
            return CommandMenus.entries(id, layouts: layouts)
        default: return RibbonMenus.entries(c.id, model)
        }
    }

    /// What a pop-up list shows: the selection's font or size, or the animation's start.
    public static func dropdownValue(_ c: RibbonControl, _ fmt: JSON, _ model: AppModel) -> String? {
        guard case .dropdown(let source) = c.kind else { return nil }
        switch source {
        case "fonts": return fmt["font"]?.asStr
        case "sizes": return fmt["size"]?.asF64.map(RibbonNumber.number)
        case "animationStart":
            guard let a = currentAnimation(model) else { return nil }
            return InspectorMotion.startLabel(a.start)
        default: return nil
        }
    }

    // MARK: Arrangement

    /// The size R1 draws a control at: its largest. Folding to smaller sizes is R3 (§5).
    public static func size(_ c: RibbonControl) -> RibbonSize { c.sizes.first ?? .medium }

    /// How many small controls share a row, and rows a column.
    static let rowLength = 7
    static let columnRows = 3

    /// A group's controls in columns of rows: a large control is a column of its own; the others stack three rows
    /// to a column, where a row is one labelled control or a run of icon-only ones (B I U, the alignments).
    public static func columns(_ g: RibbonGroup) -> [[[RibbonControl]]] {
        var columns: [[[RibbonControl]]] = []
        var rows: [[RibbonControl]] = []
        var strip: [RibbonControl] = []
        func endStrip() {
            if !strip.isEmpty { rows.append(strip) }
            strip = []
        }
        func endColumn() {
            endStrip()
            if !rows.isEmpty { columns.append(rows) }
            rows = []
        }
        for c in g.controls {
            switch size(c) {
            case .large:
                endColumn()
                columns.append([[c]])
            case .medium:
                endStrip()
                if rows.count == columnRows { endColumn() }
                rows.append([c])
            case .small:
                if strip.count == rowLength { endStrip() }
                if strip.isEmpty, rows.count == columnRows { endColumn() }
                strip.append(c)
            }
        }
        endColumn()
        return columns
    }

    // MARK: The control channel

    /// `ui.inspect`'s `ribbon`: the layout, the tab, whether it is minimised, the tabs, and the shown tab's groups
    /// with each control's enabled and toggle state.
    public static func inspect(_ model: AppModel) -> JSON {
        let tab = selected(model.ui)
        let fmt = formatState(model.session)
        let groups: [JSON] = tab.groups.map { g in
            ["id": .string(g.id), "title": .string(g.title), "controls": .array(g.controls.map { c in
                var o = JSONObject()
                o.set("id", .string(c.id))
                o.set("label", .string(label(c)))
                o.set("enabled", .bool(enabled(c, model)))
                if case .toggle = c.kind { o.set("on", .bool(isOn(c, fmt, model))) }
                if case .check = c.kind { o.set("on", .bool(isChecked(c, model))) }
                return .object(o)
            })]
        }
        return [
            "layout": .string(model.ui.layout.rawValue), "shown": .bool(model.ui.layout == .ribbon), "tab": .string(tab.title),
            "collapsed": .bool(model.ui.ribbonCollapsed), "tabs": .array(tabs.map { .string($0.title) }), "groups": .array(groups),
        ]
    }
}
