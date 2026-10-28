// DCAppModelTests — R1 of Docs/plans/Ribbon-and-StartScreen.md without a window: every ribbon control runs its
// command with deckcraft's parameters, the toggles and check boxes follow the session, switching layouts keeps the
// document, the arrangement into columns, and the tooltip descriptions (decision 3).
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCAppModel

/// A host that accepts every UI command (they open windows the model can't), recording them.
@MainActor
final class AcceptingHost: AppHost {
    var ran: [String] = []
    func uiCommand(_ id: String, _ params: JSON) -> Result<JSON, CommandError>? {
        ran.append(id)
        return .success(.null)
    }
    func uiRequest(_ request: UiRequest) {}
    func modelChanged() {}
}

@MainActor
@Suite struct RibbonModelTests {
    /// A presentation with a text box selected, which has an animation, and a slide with a transition: most of
    /// the ribbon is enabled.
    @MainActor struct Fixture {
        let model: AppModel
        let host = AcceptingHost()
        init() {
            model = AppModel(session: Session.withNew())
            model.host = host
            model.run("insert.textBox")
            model.run("text.set", ["text": "One\nTwo\nThree"])
            model.run("comment.add", ["text": "Check this"])
            model.run("animation.add", ["effect": "fade", "class": "entrance"])
            model.run("transition.set", ["kind": "fade"])
        }
    }

    static func items(_ entries: [CommandMenuEntry]) -> [CommandRef] {
        entries.flatMap { e -> [CommandRef] in
            switch e {
            case .item(_, let c, _): [c]
            case .separator: []
            case .submenu(_, let sub): items(sub)
            }
        }
    }

    /// What a control can run: its button, its menu's items, its check box both ways, its spinner.
    static func invocations(_ c: RibbonControl, _ m: AppModel) -> [CommandRef] {
        var refs: [CommandRef] = []
        if let p = RibbonModel.primary(c, m) { refs.append(p) }
        // The font list is every installed family: a few of them say as much as all of them.
        let menu = items(RibbonModel.menu(c, m))
        refs += c.id == "home.fontFamily" ? Array(menu.prefix(4)) + menu.suffix(1) : menu
        switch c.kind {
        case .check: refs += [RibbonModel.check(c, true), RibbonModel.check(c, false)]
        case .spinner(let f): refs.append(RibbonModel.spin(c, f, 1.5))
        case .color: refs.append(CommandRef(c.command.id, ["color": "accent2"]))
        default: break
        }
        return refs
    }

    /// Commands the registry enables but that need a state this fixture doesn't make; they fail with that reason,
    /// not over their parameters.
    static let needsState = [
        "arrange.regroup": "a group ungrouped before", "format.painterApply": "formatting picked with the painter",
        "insert.photoAlbumEdit": "a photo album slide", "comment.prev": "a comment before the first",
    ]

    // R1: "every control runs its command with deckcraft's params: a test walks RibbonLayout and fires each Cmd
    // against a scratch session". A command the ribbon shows enabled must succeed.
    @Test func everyControlRunsItsCommand() {
        var ran = 0, skipped: [String] = []
        let probe = Fixture()
        for tab in RibbonModel.tabs {
            for g in tab.groups {
                for c in g.controls {
                    let refs = Self.invocations(c, probe.model)
                    #expect(!refs.isEmpty || c.kind == .dropdown(source: "fonts"), "\(c.id) runs nothing")
                    for r in refs {
                        if r.id.hasPrefix("tool.") {
                            // The canvas tools are the window's (`ToolbarCatalog.perform`); their pens are deckcraft's.
                            let pen = InspectorShape.pens.at(Int(r.params["pen"]?.asU64 ?? 99)) != nil
                            #expect(r.id == "tool.select" || (r.id == "tool.ink" && pen) || (r.id == "tool.shape" && r.params["preset"]?.asStr != nil), "\(c.id)")
                            continue
                        }
                        if r.id == "app.dialog" { #expect(DialogCatalog.ids.contains(r.params["id"]?.asStr ?? ""), "\(c.id): dialog \(r.params)") }
                        let f = Fixture()
                        guard RibbonModel.enabled(r.id, f.model.session) else {
                            skipped.append("\(c.id) → \(r.id)")
                            continue
                        }
                        let result = f.model.run(r.id, r.params)
                        if case .failure(let e) = result, Self.needsState[r.id] == nil { Issue.record("\(c.id) → \(r.id) \(r.params): \(e.message)") }
                        ran += 1
                    }
                }
            }
        }
        #expect(ran > 400, "only \(ran) ran; skipped \(skipped)")
        // Only what needs a state the fixture doesn't have is disabled: a comparison, comments, a picture album.
        #expect(skipped.count < 20, "\(skipped)")
    }

    @Test func togglesFollowTheSession() throws {
        let m = AppModel(session: Session.withNew())
        m.run("insert.textBox")
        let bold = try #require(RibbonLayout.control("home.bold"))
        #expect(!RibbonModel.isOn(bold, RibbonModel.formatState(m.session), m))
        m.run("format.bold")
        #expect(RibbonModel.isOn(bold, RibbonModel.formatState(m.session), m))
        m.run("format.bold")
        #expect(!RibbonModel.isOn(bold, RibbonModel.formatState(m.session), m))

        m.run("format.alignCenter")
        let fmt = RibbonModel.formatState(m.session)
        let aligns = ["home.alignLeft", "home.alignCenter", "home.alignRight", "home.justify"].compactMap(RibbonLayout.control)
        #expect(aligns.map { RibbonModel.isOn($0, fmt, m) } == [false, true, false, false])

        let sorter = try #require(RibbonLayout.control("view.sorter"))
        #expect(!RibbonModel.isOn(sorter, fmt, m))
        m.run("view.sorter")
        #expect(RibbonModel.isOn(sorter, fmt, m))

        let painter = try #require(RibbonLayout.control("home.formatPainter"))
        RibbonModel.press(painter, m) { m.run($0.id, $0.params) }
        #expect(RibbonModel.isOn(painter, fmt, m))
        // A second press turns it off, as deckcraft's does.
        RibbonModel.press(painter, m) { m.run($0.id, $0.params) }
        #expect(!RibbonModel.isOn(painter, fmt, m))
    }

    @Test func checksAndSpinnersReadAndWrite() throws {
        let f = Fixture()
        let m = f.model
        let ruler = try #require(RibbonLayout.control("view.ruler"))
        #expect(!RibbonModel.isChecked(ruler, m))
        let on = RibbonModel.check(ruler, true)
        m.run(on.id, on.params)
        #expect(RibbonModel.isChecked(ruler, m))

        let narrations = try #require(RibbonLayout.control("slideShow.narrations"))
        #expect(RibbonModel.isChecked(narrations, m))
        let off = RibbonModel.check(narrations, false)
        #expect(off.params["noNarration"]?.asBool == true)
        m.run(off.id, off.params)
        #expect(!RibbonModel.isChecked(narrations, m))

        let duration = try #require(RibbonLayout.control("transitions.duration"))
        guard case .spinner(let field) = duration.kind else { Issue.record("not a spinner"); return }
        let spin = RibbonModel.spin(duration, field, 1.5)
        m.run(spin.id, spin.params)
        #expect(RibbonModel.spinnerValue(duration, field, m) == 1.5)
        #expect(RibbonModel.spin(duration, field, -3).params[field]?.asU64 == 0)
        #expect(RibbonModel.spin(duration, field, .nan).params[field]?.asU64 == 0)
    }

    // R1: "switching layouts keeps the document, the selection and the undo stack".
    @Test func switchingLayoutsKeepsTheDocument() throws {
        let f = Fixture()
        let m = f.model
        m.ui.pane = "format"
        let doc = try #require(m.session.activeDoc)
        let (uid, selection, undo) = (doc.uid, doc.selection, doc.history.undo.count)
        #expect(m.ui.layout == .mac)
        #expect(try m.run("view.ribbon").get()["layout"]?.asStr == "ribbon")
        #expect(m.ui.layout == .ribbon)
        m.run("view.ribbon", ["on": false])
        #expect(m.ui.layout == .mac)
        m.run("view.ribbon", ["on": true])
        let after = try #require(m.session.activeDoc)
        #expect(after.uid == uid && after.selection == selection && after.history.undo.count == undo)
        // In the ribbon layout the inspector is the task pane, closed until a pane is asked for.
        #expect(m.ui.pane == nil)
        m.run("view.ribbon", ["on": true])
        #expect(m.ui.layout == .ribbon)
    }

    @Test func layoutIsSavedAndOldStateReadsAsMac() throws {
        let old = try JSONDecoder().decode(UiState.self, from: Data(#"{"tab": "Insert", "ribbonCollapsed": true}"#.utf8))
        #expect(old.layout == .mac && old.tab == "Insert")
        let bad = try JSONDecoder().decode(UiState.self, from: Data(#"{"layout": "sideways"}"#.utf8))
        #expect(bad.layout == .mac)
        var s = UiState()
        s.layout = .ribbon
        let back = try JSONDecoder().decode(UiState.self, from: JSONEncoder().encode(s))
        #expect(back.layout == .ribbon)
    }

    @Test func theSelectedTabIsDeckcraftsName() {
        var ui = UiState()
        #expect(RibbonModel.selected(ui).id == "home")
        ui.tab = "Slide Show"
        #expect(RibbonModel.selected(ui).id == "slideShow")
        ui.tab = "review"
        #expect(RibbonModel.selected(ui).id == "review")
        // A contextual tab (R2) or anything else shows Home.
        ui.tab = "Shape Format"
        #expect(RibbonModel.selected(ui).id == "home")
        let m = AppModel(session: Session.withNew())
        m.run("view.tab", ["tab": "Design"])
        let r = RibbonModel.inspect(m)
        #expect(r["tab"]?.asStr == "Design" && r["layout"]?.asStr == "mac" && r["collapsed"]?.asBool == false)
        #expect(r["tabs"]?.asArray?.count == 10)
        #expect(r["groups"]?.asArray?.first?["id"]?.asStr == "design.themes")
    }

    @Test func groupsAreArrangedInColumns() {
        for tab in RibbonModel.tabs {
            for g in tab.groups {
                let cols = RibbonModel.columns(g)
                #expect(cols.flatMap { $0.flatMap { $0 } }.map(\.id) == g.controls.map(\.id), "\(g.id) keeps its order")
                for col in cols {
                    #expect(!col.isEmpty && col.count <= 3, "\(g.id)")
                    for row in col { #expect(!row.isEmpty && row.count <= 7, "\(g.id)") }
                    // A large control is a column of its own.
                    if col.flatMap({ $0 }).contains(where: { RibbonModel.size($0) == .large }) { #expect(col.count == 1 && col[0].count == 1, "\(g.id)") }
                }
            }
        }
    }

    // Decision 3: every command the ribbon's tabs show has a description, and every control a label and a tip.
    @Test func everyRibbonCommandHasADescription() {
        var missing: [String] = []
        for tab in RibbonModel.tabs {
            for g in tab.groups {
                for c in g.controls {
                    if CommandHelp.description(c.command) == nil { missing.append("\(c.id) (\(c.command.id))") }
                    #expect(!RibbonModel.label(c).isEmpty && RibbonModel.label(c) != c.id, "\(c.id) has no label")
                    #expect(RibbonModel.tip(c).contains("\n"), "\(c.id)'s tooltip has no description")
                }
            }
        }
        for q in QAT.common where CommandHelp.description(q.id) == nil { missing.append("QAT \(q.id)") }
        #expect(missing.isEmpty, "\(missing)")
        #expect(CommandHelp.description(CommandRef("view.pane", ["pane": "selection"])) != CommandHelp.description(CommandRef("view.pane", ["pane": "designer"])))
        #expect(CommandHelp.glyphs("Cmd+Shift+P") == "⇧⌘P" && CommandHelp.glyphs("Cmd+Alt+R") == "⌥⌘R" && CommandHelp.glyphs("F5") == "F5")
        #expect(CommandHelp.tip(CommandRef("format.bold"), label: "Bold") == "Bold (⌘B)\nMake the selected text bold.")
        // Written in our own words: none is longer than a line.
        for (k, v) in CommandHelp.english { #expect(v.count <= 110 && v.hasSuffix("."), "\(k)") }
    }

    @Test func menusFollowTheSession() {
        let f = Fixture()
        let layouts = Self.items(RibbonModel.menu(RibbonLayout.control("home.layout") ?? RibbonLayout.c("x", "slide.layout"), f.model))
        #expect(layouts.count == f.model.session.activeDoc?.doc.masters.first?.layouts.count)
        #expect(layouts.allSatisfy { $0.id == "slide.layout" && $0.params["layout"]?.asU64 != nil })
        let none = AppModel(session: Session())
        #expect(RibbonMenus.entries("home.layout", none).isEmpty && RibbonMenus.entries("animations.effectOptions", none).isEmpty)
        #expect(RibbonNumber.number(10.5) == "10.5" && RibbonNumber.number(12) == "12" && RibbonNumber.number(2.25) == "2.25")
    }
}
