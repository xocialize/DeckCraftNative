// DCAppModel — what the ribbon shows and runs, without a window (Docs/plans/Ribbon-and-StartScreen.md §4, §6, R1,
// R2): the window layout, the tabs the selection brings and the selected one, each control's label, tooltip, symbol,
// enabled and toggle state, and the command a click runs, with deckcraft's parameters. Ports the state reads of
// deckcraft `crates/ui-egui/src/ribbon.rs` (`contextual`, `fmt_state`, `enabled`) and the per-control parameters of
// `ribbon/{home,transitions,animations,slide_show,view,shape_format,picture_format,table,smartart,playback,masters,
// arrange}.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). DCApp's `RibbonView` draws what this answers.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation

/// The window's layout (§8): the toolbar and inspector (deckcraft's ribbon dropped, the Mac default), or the ribbon.
public enum WindowLayout: String, Codable, Sendable, CaseIterable {
    case mac, ribbon
}

@MainActor
public enum RibbonModel {
    /// The inspector, whose Table pen and SmartArt Text Pane line the ribbon's Borders and Add Shape use.
    public static weak var inspector: InspectorController?

    // MARK: Tabs

    /// Every tab the ribbon can show: the ten regular ones, then the contextual ones.
    public static var allTabs: [RibbonTab] { RibbonLayout.tabs }

    /// Which contextual tabs apply to the selection (`ribbon.rs` `contextual`): the master being edited, then
    /// Shape Format, Picture Format, Table Design and Layout, SmartArt Design, Chart Design and Playback.
    public static func contextual(_ st: DocState?) -> [String] {
        guard let st else { return [] }
        var v: [String] = []
        switch st.selection.target {
        case .handout: v.append("Handout Master")
        case .notesMaster: v.append("Notes Master")
        case .slides: break
        default: v.append("Slide Master")
        }
        let shapes = st.selectedShapes
        if shapes.contains(where: { s in
            switch s.kind {
            case .shape, .group, .connector: true
            default: false
            }
        }) || st.selection.text != nil {
            v.append("Shape Format")
        }
        if shapes.contains(where: { if case .picture = $0.kind { true } else { false } }) { v.append("Picture Format") }
        if shapes.contains(where: { if case .table = $0.kind { true } else { false } }) || st.selection.text?.cell != nil {
            v += ["Table Design", "Layout"]
        }
        if SmartArtCommands.selected(st) != nil { v.append("SmartArt Design") }
        if shapes.contains(where: { if case .chart = $0.kind { true } else { false } }) { v.append("Chart Design") }
        if shapes.contains(where: { if case .media = $0.kind { true } else { false } }) { v.append("Playback") }
        return v
    }

    /// The tabs shown now: the ten regular ones, then the contextual tabs the selection has, in `contextual`'s order.
    public static func tabs(_ model: AppModel) -> [RibbonTab] {
        RibbonLayout.regular + contextual(model.session.activeDoc).compactMap { name in
            RibbonLayout.contextualTabs.first { $0.contextual == name }
        }
    }

    /// The tab `UiState.tab` names, among the ones shown. It holds deckcraft's tab title ("Home", "Slide Show",
    /// "Shape Format"); a tab id is accepted too. Anything else shows Home.
    public static func selected(_ model: AppModel) -> RibbonTab {
        tabs(model).first { $0.title == model.ui.tab || $0.id == model.ui.tab } ?? RibbonLayout.home
    }

    /// A contextual tab that no longer applies gives way to Home (`ribbon.rs` `show`), so that selecting the
    /// object again doesn't bring it back: a contextual tab is only ever shown by choosing it (decision in §3).
    public static func settle(_ model: AppModel) {
        guard RibbonLayout.contextualTabs.contains(where: { $0.title == model.ui.tab || $0.id == model.ui.tab }),
              !tabs(model).contains(where: { $0.title == model.ui.tab || $0.id == model.ui.tab }) else { return }
        model.ui.tab = RibbonLayout.home.title
    }

    // MARK: Labels and tooltips

    /// The registry's English label for a command, or nil for the canvas tools.
    static func registryLabel(_ id: String) -> String? { findCommand(id)?.label ?? UICommands.find(id)?.label }

    /// The Ribbon catalog's keys (§9): a tab's, a group's (its id names its tab), a control title's.
    nonisolated public static func key(_ t: RibbonTab) -> String { "ribbon.tab.\(t.id)" }
    nonisolated public static func key(_ g: RibbonGroup) -> String { "ribbon.group.\(g.id)" }
    nonisolated public static func key(_ c: RibbonControl) -> String { "ribbon.control.\(c.id)" }

    /// The tab's title to show, translated. `view.tab` and `ui.inspect` keep the English `title`.
    nonisolated public static func title(_ t: RibbonTab) -> String { Bundle.module.localizedString(forKey: key(t), value: t.title, table: "Ribbon") }

    /// The group's title to show, translated: VoiceOver's name for it and its button when it folds.
    nonisolated public static func title(_ g: RibbonGroup) -> String { Bundle.module.localizedString(forKey: key(g), value: g.title, table: "Ribbon") }

    /// The control's label: its title, or its command's label as the Commands catalog has it.
    public static func label(_ c: RibbonControl) -> String {
        if c.id == "handoutMaster.perPage" {
            return String(localized: "Slides Per Page: \(inspector?.model.ui.handoutPerPage ?? 6)", bundle: .module, comment: "Handout Master: how many slides a handout page holds")
        }
        if let t = c.title { return Bundle.module.localizedString(forKey: key(c), value: t, table: "Ribbon") }
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
        if c.id.hasPrefix("smartArtDesign.") {
            // SmartArt Design needs a graphic (`smartart.rs`): Promote and Demote a line, Insert Picture a picture layout.
            guard let (_, d) = model.session.activeDoc.flatMap(SmartArtCommands.selected) else { return false }
            switch c.id {
            case "smartArtDesign.promote", "smartArtDesign.demote": return !d.nodes.isEmpty
            case "smartArtDesign.insertPicture": return d.kind.hasPrefix("picture") && !d.nodes.isEmpty
            default: break
            }
        }
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
        case "tool" where c.command.id == "tool.shape":
            guard case .shape(let preset) = session.tool.kind else { return false }
            return preset == c.command.params["preset"]?.asStr
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
        case ("table.options", _):
            // The first selected table's options (`table.rs`); none when only a cell's text is being edited.
            guard let d = model.session.activeDoc, let t = d.selectedShapes.lazy.compactMap({ s -> Table? in
                if case .table(let t) = s.kind { t } else { nil }
            }).first else { return false }
            switch field {
            case "headerRow": return t.firstRow
            case "firstColumn": return t.firstCol
            case "totalRow": return t.lastRow
            case "lastColumn": return t.lastCol
            case "bandedRows": return t.bandRow
            case "bandedColumns": return t.bandCol
            default: return false
            }
        case ("media.options", _):
            guard let d = model.session.activeDoc, let m = d.selectedShapes.lazy.compactMap({ s -> MediaClip? in
                if case .media(let m) = s.kind { m } else { nil }
            }).first else { return false }
            switch field {
            case "autoplay": return m.autoplay
            case "acrossSlides": return m.playAcrossSlides
            case "loop": return m.loopPlay
            case "hide": return m.hideWhileNotPlaying
            case "rewind": return m.rewind
            case "fullScreen": return m.fullScreen
            default: return false
            }
        case ("master.preserve", _):
            guard let d = model.session.activeDoc else { return false }
            switch d.selection.target {
            case .master(let m): return d.doc.masters.at(m)?.preserve ?? false
            case .layout(let m, let l): return d.doc.masters.at(m)?.layouts.at(l)?.preserve ?? false
            default: return false
            }
        case ("master.placeholders", "title"):
            return model.session.activeDoc?.shapes.contains { $0.phType?.isTitle ?? false } ?? false
        case ("master.placeholders", "footers"):
            return model.session.activeDoc?.shapes.contains { $0.phType?.isFooterKind ?? false } ?? false
        case ("notes.placeholders", _):
            return placeholder(model.session.activeDoc?.doc.notesMaster, field)
        case ("handout.placeholders", _):
            return placeholder(model.session.activeDoc?.doc.handoutMaster, field)
        default: return false
        }
    }

    /// Whether a notes or handout master has the placeholder a check box names (`masters.rs`).
    static func placeholder(_ master: Master?, _ field: String) -> Bool {
        let kind: PhType? = switch field {
        case "header": .header
        case "slideImage": .slideImage
        case "footer": .footer
        case "date": .date
        case "body": .body
        case "pageNumber": .slideNum
        default: nil
        }
        guard let kind, let master else { return false }
        return master.shapes.contains { $0.phType == kind }
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
        case ("shape.resize", "h"), ("shape.resize", "w"):
            // The first selected shape's size, in the Preferences unit (`size_group`).
            guard let d = doc, let id = d.selection.shapes.first, let sh = d.shape(id) else { return nil }
            let x = Cmd.xfrmOf(d.doc, d.selection, sh)
            let v = (field == "h" ? x.h : x.w) / model.session.prefs.units.pointsPerUnit
            return v.isFinite ? v : nil
        default: return nil
        }
    }

    /// A spinner's step, suffix and range: seconds for the timings, the Preferences unit for a size.
    public static func spinnerFormat(_ c: RibbonControl, _ model: AppModel) -> (step: Double, suffix: String, range: ClosedRange<Double>) {
        if c.command.id == "shape.resize" {
            let u = model.session.prefs.units
            return (0.1, u.suffix, 0 ... 20_000 / u.pointsPerUnit)
        }
        return (0.25, " s", 0 ... 600)
    }

    /// What a spinner runs for `value`: milliseconds for a timing (`(v.max(0.0) * 1000.0).round()`), points for a
    /// size (`v.max(0.0) * ppu`).
    public static func spin(_ c: RibbonControl, _ field: String, _ value: Double, units: DCGeometry.Unit = .inches) -> CommandRef {
        let v = value.isFinite ? Swift.max(value, 0) : 0
        if c.command.id == "shape.resize" { return CommandRef(c.command.id, [field: .num(v * units.pointsPerUnit)]) }
        return CommandRef(c.command.id, [field: InspectorMotion.ms(v)])
    }

    /// The selected shape's first animation on this slide, as the Animations tab edits it.
    static func currentAnimation(_ model: AppModel) -> Animation? {
        guard let d = model.session.activeDoc, let shape = d.selection.shapes.first, let slide = d.currentSlide else { return nil }
        return slide.animations.first { $0.shape == shape }
    }

    // MARK: Galleries

    /// Galleries drawn as a large button that opens the whole gallery, as PowerPoint's Home › Quick Styles is; the
    /// others show their first tiles in the ribbon, with "›" for the rest.
    static let droppedGalleries: Set<String> = ["home.quickStyles"]

    public static func inlineGallery(_ c: RibbonControl) -> Bool {
        guard case .gallery = c.kind else { return false }
        return !droppedGalleries.contains(c.id)
    }

    // MARK: What a click runs

    /// The command the control's button (or a split's main half) runs, with deckcraft's parameters. nil for a
    /// control that only opens its menu or gallery.
    public static func primary(_ c: RibbonControl, _ model: AppModel) -> CommandRef? {
        let slide = JSON.integer(model.session.activeDoc?.selection.slide ?? 0)
        switch c.kind {
        case .menu, .gallery, .dropdown, .spinner, .check: return nil
        case .color:
            // The main half reapplies the last colour; these are deckcraft's starting colours.
            switch c.command.id {
            case "format.highlight": return CommandRef("format.highlight", ["color": "#FFFF00"])
            case "format.color": return CommandRef("format.color", ["color": "#C00000"])
            case "shape.fill": return CommandRef("shape.fill", ["color": "accent1"])
            // Picture Border's main half is a thin black frame (`picture_format.rs`).
            case "shape.line" where c.id == "pictureFormat.border": return CommandRef("shape.line", ["color": "#000000", "width": 1.0])
            case "shape.line": return CommandRef("shape.line", ["color": "tx1"])
            case "table.cellFill": return CommandRef("table.cellFill", ["color": "accent1"])
            case "format.textOutline": return CommandRef("format.textOutline", ["color": "tx1"])
            default: return c.command
            }
        case .button, .toggle, .split: break
        }
        if c.id.hasPrefix("smartArtDesign."), let (gid, d) = model.session.activeDoc.flatMap(SmartArtCommands.selected) {
            // SmartArt Design acts on the graphic and the Text Pane's line (`smartart.rs`).
            let id = JSON.integer(gid.rawValue), at = JSON.integer(RibbonMenus.smartArtRow(d))
            switch c.id {
            case "smartArtDesign.addShape": return CommandRef("smartArt.addNode", ["id": id, "index": d.nodes.isEmpty ? .null : at, "position": "after"])
            case "smartArtDesign.promote", "smartArtDesign.demote", "smartArtDesign.insertPicture": return CommandRef(c.command.id, ["id": id, "index": at])
            default: break
            }
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
        } else if c.command.id == "tool.shape", case .toggle = c.kind, isOn(c, .emptyObject, model) {
            // Draw Table and Eraser turn off as they turn on (`table.rs`).
            run(CommandRef("tool.select"))
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

    /// The widest a large control's label is drawn, in two lines at most.
    public static let largeLabelWidth: Double = 76
    /// The widest a collapsed group's title is drawn, beside its arrow, in two lines at most.
    public static let collapsedLabelWidth: Double = 66

    /// A collapsed group's icon: its first control's.
    public static func symbol(group g: RibbonGroup) -> String { g.controls.first.map(symbol) ?? "square.grid.2x2" }

    /// A control's largest size, as a group drawn at `.large` draws it.
    public static func size(_ c: RibbonControl) -> RibbonSize { c.sizes.first ?? .medium }

    /// How many small controls share a row, and rows a column.
    static let rowLength = 7
    static let columnRows = 3

    /// A group's controls in columns of rows, at the group's size `gs` (§5): a large control is a column of its own;
    /// the others stack three rows to a column, where a row is one labelled control or a run of icon-only ones
    /// (B I U, the alignments).
    public static func columns(_ g: RibbonGroup, _ gs: GroupSize = .large) -> [[[RibbonControl]]] {
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
            switch RibbonFit.size(c, gs) {
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

    /// `ui.inspect`'s `ribbon`: the layout, the tab (deckcraft's title, and its id), whether it is minimised, the tabs, and the shown tab's groups
    /// with each control's enabled and toggle state.
    public static func inspect(_ model: AppModel) -> JSON {
        let tab = selected(model)
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
            "tabId": .string(tab.id), "collapsed": .bool(model.ui.ribbonCollapsed), "tabs": .array(tabs(model).map { .string($0.title) }),
            "contextual": .array(contextual(model.session.activeDoc).map { .string($0) }), "groups": .array(groups),
        ]
    }
}
