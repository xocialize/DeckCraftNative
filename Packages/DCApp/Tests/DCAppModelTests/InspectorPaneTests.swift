// DCAppModelTests — the inspector's panes without a window: the Selection Pane, the tabs `view.pane` opens,
// the contextual sections, comments, the Thesaurus, the SmartArt Text Pane, the Design tab's menus, Align to
// Slide, split buttons' main halves and the Quick Access Toolbar. Each test names the deckcraft test
// (`crates/ui-egui`) whose behaviour it ports; Rust names in camelCase.
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct InspectorSelectionPaneTests {
    // selpane.rs: switching_document_drops_a_pending_rename
    @Test func switchingDocumentDropsAPendingRename() {
        var s = SelectionPane.State()
        s.bind(1)
        s.renaming = (5, "draft")
        s.collapsed.insert(2)
        s.bind(1)
        #expect(s.renaming != nil, "same document keeps the draft")
        s.bind(2)
        #expect(s.renaming == nil)
        #expect(s.collapsed.isEmpty)
    }

    static func block(_ id: UInt32, _ top: Double) -> SelectionPane.Block { .init(id: id, top: top, bottom: top + SelectionPane.rowHeight) }

    // selpane.rs: drop_target_picks_the_nearest_gap
    @Test func dropTargetPicksTheNearestGap() {
        // Rows top to bottom: 4 (front), 3, 2, 1 (back); dragging 1.
        let sib = [Self.block(4, 0), Self.block(3, 24), Self.block(2, 48), Self.block(1, 72)]
        #expect(SelectionPane.dropTarget(1, sib, -5).map { [Double($0.index), $0.y] } == [3, 0])
        #expect(SelectionPane.dropTarget(1, sib, 22).map { [Double($0.index), $0.y] } == [2, 24])
        #expect(SelectionPane.dropTarget(1, sib, 500).map { [Double($0.index), $0.y] } == [0, 72])
        #expect(SelectionPane.dropTarget(1, [Self.block(1, 0)], 10) == nil)
    }

    /// selpane_tests.rs' harness: A, B, C (back to front) and the group G = [D, E] in front.
    static func session() -> (Session, [String: UInt32]) {
        let s = Fx.blank()
        var ids: [String: UInt32] = [:]
        for (i, n) in ["A", "B", "C", "D", "E"].enumerated() {
            let id = Fx.rect(s, 20 + 110 * Double(i), 50, w: 100, h: 80)
            _ = try? s.execute("shape.rename", ["id": .integer(id), "name": .string(n)])
            ids[n] = id
        }
        let g = try? s.execute("arrange.group", ["ids": [.integer(ids["D"] ?? 0), .integer(ids["E"] ?? 0)]])
        let gid = UInt32(g?["id"]?.asU64 ?? 0)
        _ = try? s.execute("shape.rename", ["id": .integer(gid), "name": "G"])
        ids["G"] = gid
        Fx.select(s, [])
        return (s, ids)
    }

    static func names(_ s: Session) -> String {
        func rec(_ v: [Shape]) -> String { v.map { $0.isGroup ? "\($0.name)[\(rec($0.children))]" : $0.name }.joined(separator: " ") }
        return rec(s.activeDoc?.shapes ?? [])
    }

    static func selected(_ s: Session) -> [String] {
        (s.activeDoc?.selection.shapes ?? []).compactMap { s.activeDoc?.shape($0)?.name }
    }

    static func shape(_ s: Session, _ name: String) -> Shape? {
        var found: Shape?
        walk(s.activeDoc?.shapes ?? []) { sh, _ in if found == nil && sh.name == name { found = sh } }
        return found
    }

    static func rows(_ s: Session, _ collapsed: Set<UInt32> = []) -> [SelectionPane.Row] { SelectionPane.rows(s.activeDoc?.shapes ?? [], collapsed) }

    // selpane_tests.rs: lists_front_most_first_with_groups_expanded
    @Test func listsFrontMostFirstWithGroupsExpanded() {
        let (s, ids) = Self.session()
        let rows = Self.rows(s)
        #expect(rows.map(\.name) == ["G", "E", "D", "C", "B", "A"])
        #expect(rows[0].group && rows[1].depth == 1 && rows[1].parent == ids["G"])
    }

    /// A click on the row named `name`, as the pane makes it.
    static func click(_ m: AppModel, _ state: inout SelectionPane.State, _ name: String, command: Bool = false, shift: Bool = false) {
        let rows = Self.rows(m.session, state.collapsed)
        guard let k = rows.firstIndex(where: { $0.name == name }),
              let c = SelectionPane.click(rows, k, anchor: state.anchor, command: command, shift: shift) else { return }
        m.run("selection.select", c.params)
        state.anchor = c.anchor
    }

    // selpane_tests.rs: click_ctrl_click_and_shift_click_select
    @Test func clickCtrlClickAndShiftClickSelect() {
        let (s, _) = Self.session()
        let m = AppModel(session: s)
        var st = SelectionPane.State()
        Self.click(m, &st, "A")
        #expect(Self.selected(s) == ["A"])
        Self.click(m, &st, "C", command: true)
        #expect(Self.selected(s) == ["A", "C"])
        Self.click(m, &st, "A", command: true)
        #expect(Self.selected(s) == ["C"])
        // Shift+click: the run from the last click (C) down to A.
        Self.click(m, &st, "C")
        Self.click(m, &st, "A", shift: true)
        #expect(Self.selected(s).sorted() == ["A", "B", "C"])
        Self.click(m, &st, "D")
        #expect(Self.selected(s) == ["D"])
    }

    // selpane_tests.rs: eye_and_padlock_toggle_and_undo
    @Test func eyeAndPadlockToggleAndUndo() throws {
        let (s, ids) = Self.session()
        let m = AppModel(session: s)
        let row = { (n: String) in Self.rows(s).first { $0.name == n } }
        m.run("shape.visible", ["id": .integer(ids["B"] ?? 0), "visible": .bool(try #require(row("B")).hidden)])
        #expect(Self.shape(s, "B")?.hidden == true)
        #expect(row("B")?.hidden == true, "the eye now offers to show it")
        m.run("shape.lock", ["id": .integer(ids["G"] ?? 0)])
        #expect(["G", "D", "E"].allSatisfy { Self.shape(s, $0)?.locked == true }, "the group locks with its children")
        m.run("shape.lock", ["id": .integer(ids["D"] ?? 0)])
        #expect(Self.shape(s, "D")?.locked == false && Self.shape(s, "G")?.locked == true)
        m.run("selection.hideAll")
        #expect(["A", "B", "C", "G"].allSatisfy { Self.shape(s, $0)?.hidden == true })
        #expect(Self.rows(s).first { $0.name == "D" }?.dimmed == true, "inside a hidden group: dimmed")
        m.run("selection.showAll")
        #expect(["A", "B", "C", "G", "D", "E"].allSatisfy { Self.shape(s, $0)?.hidden == false })
        m.run("edit.undo")
        #expect(Self.shape(s, "A")?.hidden == true)
    }

    /// A drag of row `name` to `y` (pane points from the top of the list): `arrange.reorder` at the drop.
    static func drag(_ m: AppModel, _ name: String, to y: Double) {
        let rows = Self.rows(m.session)
        guard let row = rows.first(where: { $0.name == name }),
              let t = SelectionPane.dropTarget(row.id, SelectionPane.siblingBlocks(rows, row.parent), y) else { return }
        m.run("selection.select", ["id": .integer(row.id)])
        m.run("arrange.reorder", ["id": .integer(row.id), "index": .integer(t.index)])
    }

    static func top(_ s: Session, _ name: String) -> Double {
        Double(Self.rows(s).firstIndex { $0.name == name } ?? 0) * SelectionPane.rowHeight
    }

    // selpane_tests.rs: drag_and_drop_restacks_among_siblings
    @Test func dragAndDropRestacksAmongSiblings() {
        let (s, _) = Self.session()
        let m = AppModel(session: s)
        #expect(Self.names(s) == "A B C G[D E]")
        // A (bottom row) dragged above G (top row): A goes to the front.
        Self.drag(m, "A", to: Self.top(s, "G") + 2)
        #expect(Self.names(s) == "B C G[D E] A")
        #expect(Self.selected(s) == ["A"], "the dragged object is selected")
        // C dragged to the bottom of the list: the back.
        Self.drag(m, "C", to: Self.top(s, "B") + SelectionPane.rowHeight + 30)
        #expect(Self.names(s) == "C B G[D E] A")
        // D (a child) dragged far above its group stays in the group, at its front.
        Self.drag(m, "D", to: Self.top(s, "A") - 10)
        #expect(Self.names(s) == "C B G[E D] A")
        // B dropped over the group lands among the top-level objects, never inside it.
        Self.drag(m, "B", to: Self.top(s, "G") + SelectionPane.rowHeight / 2 + 6)
        #expect(Self.names(s) == "C G[E D] B A")
        for _ in 0 ..< 4 { m.run("edit.undo") }
        #expect(Self.names(s) == "A B C G[D E]")
    }

    // selpane_tests.rs: bring_forward_and_send_backward_buttons
    @Test func bringForwardAndSendBackwardButtons() {
        let (s, ids) = Self.session()
        let m = AppModel(session: s)
        Fx.select(s, [ids["A"] ?? 0])
        m.run("arrange.bringForward")
        #expect(Self.names(s) == "B A C G[D E]")
        Fx.select(s, [ids["D"] ?? 0])
        m.run("arrange.bringForward")
        m.run("arrange.bringForward")
        #expect(Self.names(s) == "B A C G[E D]", "a child stays in its group")
        m.run("arrange.sendBackward")
        #expect(Self.names(s) == "B A C G[D E]")
    }

    // selpane_tests.rs: double_click_renames_in_place (the rename the edit commits)
    @Test func renameCommitsATrimmedChangedName() throws {
        let (s, ids) = Self.session()
        let row = try #require(Self.rows(s).first { $0.name == "B" })
        #expect(SelectionPane.renameParams(row, "B") == nil)
        #expect(SelectionPane.renameParams(row, "   ") == nil)
        let p = try #require(SelectionPane.renameParams(row, " Bravo "))
        AppModel(session: s).run("shape.rename", p)
        #expect(Fx.shape(s, ids["B"] ?? 0)?.name == "Bravo")
    }

    // selpane_tests.rs: arrow_keys_move_through_the_list_and_collapse_hides_children
    @Test func arrowKeysMoveThroughTheListAndCollapseHidesChildren() {
        let (s, ids) = Self.session()
        let rows = Self.rows(s)
        let g = ids["G"] ?? 0
        let down = SelectionPane.keyTarget(rows, selected: [g], key: "Down")
        #expect(down.map { rows[$0].name } == "E")
        #expect(SelectionPane.keyTarget(rows, selected: [ids["C"] ?? 0], key: "Up").map { rows[$0].name } == "D")
        #expect(SelectionPane.keyTarget(rows, selected: [], key: "Down") == 0)
        #expect(SelectionPane.keyTarget(rows, selected: [g], key: "Up") == nil, "already at the top")
        #expect(SelectionPane.keyTarget(rows, selected: [g], key: "End") == rows.count - 1)
        let folded = Self.rows(s, [g])
        #expect(folded.map(\.name) == ["G", "C", "B", "A"])
    }
}

@MainActor
@Suite struct InspectorControllerTests {
    @Test func viewPaneOpensTheMatchingTab() {
        let m = AppModel(session: Fx.blank())
        let ctl = InspectorController(model: m)
        #expect(ctl.tab == .format)
        for (pane, tab) in [("format", InspectorTab.format), ("background", .slide), ("animation", .animate), ("selection", .arrange),
                            ("comments", .review), ("designer", .slide), ("smartart", .format), ("thesaurus", .review), ("revisions", .review)] {
            m.run("view.pane", ["pane": .string(pane)])
            #expect(ctl.tab == tab, "\(pane)")
        }
        ctl.show(.animate)
        #expect(m.ui.pane == "animation")
        m.run("view.pane", ["pane": "format", "tab": "effects"])
        #expect(m.ui.formatTab == "effects")
    }

    @Test func formatTabsFollowTheSelection() throws {
        let s = Fx.blank()
        let m = AppModel(session: s)
        let ctl = InspectorController(model: m)
        #expect(ctl.contextual().isEmpty)
        let id = Fx.rect(s, 40)
        Fx.select(s, [id])
        #expect(ctl.contextual() == ["Shape Format"])
        #expect(ctl.formatTabs().map(\.id) == ["fill", "effects", "size", "text"])
        m.ui.formatTab = "picture"
        #expect(ctl.formatTab == "fill", "a tab the selection doesn't offer falls back to Fill & Line")
        _ = try s.execute("insert.table", ["rows": 2, "cols": 2])
        #expect(ctl.contextual().contains("Table Design"))
        #expect(ctl.formatTabs().map(\.id).contains("table"))
        _ = try s.execute("insert.chart", ["type": "Column"])
        #expect(ctl.contextual().contains("Chart Design"))
        _ = try s.execute("insert.smartArt", ["kind": "list", "items": ["Plan", "Build"]])
        #expect(ctl.contextual().contains("SmartArt Design"))
        m.ui.pane = "smartart"
        #expect(ctl.formatTab == "smartart")
        _ = try s.execute("view.slideMaster", .emptyObject)
        #expect(ctl.contextual().first == "Slide Master")
        let i = ctl.inspect()
        #expect(i["tab"]?.asStr == "format")
        #expect(i["formatTab"]?.asStr == "smartart")
    }

    // align_tests.rs' Align to Slide choice (`align_to_slide` in ribbon.rs)
    @Test func alignToSlideFollowsTheSelectionUnlessChosen() {
        let a = ShapeId(1), b = ShapeId(2)
        #expect(InspectorController.alignToSlide(nil, [a]))
        #expect(!InspectorController.alignToSlide(nil, [a, b]))
        #expect(InspectorController.alignToSlide(([a, b], true), [a, b]))
        #expect(InspectorController.alignToSlide(([a, b], false), [b]), "a choice for another selection doesn't apply")
        let s = Fx.blank()
        let x = Fx.rect(s, 100, 100), y = Fx.rect(s, 300, 200)
        Fx.select(s, [x, y])
        let ctl = InspectorController(model: AppModel(session: s))
        ctl.align("left")
        #expect(Fx.shape(s, y)?.xfrm?.x == 100, "two objects align to each other")
        ctl.setAlignTo(slide: true)
        ctl.align("left")
        #expect(Fx.shape(s, x)?.xfrm?.x == 0 && Fx.shape(s, y)?.xfrm?.x == 0, "Align to Slide")
    }

    // split_button_tests.rs: shape_format_group_main_groups_and_its_arrow_opens_the_group_menu,
    // shape_format_rotate_main_rotates_and_its_arrow_opens_the_rotate_menu (the main halves' commands)
    @Test func groupAndRotateMainHalvesRunTheirCommands() throws {
        let s = Fx.blank()
        let a = Fx.rect(s, 100), b = Fx.rect(s, 300)
        _ = try s.execute("selection.select", ["ids": [.integer(a), .integer(b)]])
        let ctl = InspectorController(model: AppModel(session: s))
        ctl.run("arrange.group")
        let d = try #require(s.activeDoc)
        #expect(d.selection.shapes.count == 1)
        #expect(d.shape(d.selection.shapes[0])?.isGroup == true)
        let t = Fx.blank()
        let c = Fx.rect(t, 100)
        Fx.select(t, [c])
        InspectorController(model: AppModel(session: t)).run("arrange.rotateRight")
        #expect(abs((Fx.shape(t, c)?.xfrm?.rot ?? 0) - 90) < 1e-9)
    }

    // widgets.rs: text_draft_keeps_typing_while_the_stored_text_is_unchanged,
    // text_draft_drops_a_stale_draft_when_the_stored_text_changes
    @Test func textDraftKeepsTypingUntilTheStoredTextChanges() {
        #expect(InspectorText.draft(("old", "old plus typing"), "old") == "old plus typing")
        #expect(InspectorText.draft(("old", "old plus typing"), "undone") == "undone")
        #expect(InspectorText.draft(nil, "fresh") == "fresh")
    }

    @Test func fontFamiliesPutTheThemeFontsFirst() {
        let s = Session.withNew()
        let f = InspectorText.fontFamilies(s.activeDoc, installed: ["Avenir", "Inter", "Zapfino"])
        #expect(f.theme == ["Inter"], "the default theme's heading and body fonts are one")
        #expect(Array(f.all.prefix(f.theme.count)) == f.theme)
        #expect(f.all.contains("Zapfino"))
        #expect(InspectorText.sizes.last == 96)
    }

    // thesaurus_tests.rs: thesaurus_pane_swaps_the_word_at_the_caret
    @Test func thesaurusPaneSwapsTheWordAtTheCaret() throws {
        let s = Fx.blank()
        let id = try #require(try s.execute("insert.textBox", ["rect": [100, 100, 500, 50]])["id"]?.asU64)
        _ = try s.execute("text.edit", ["id": .integer(id)])
        _ = try s.execute("text.insert", ["text": "Our Goal is growth."])
        _ = try s.execute("text.edit", ["id": .integer(id), "at": [0, 6]])
        let m = AppModel(session: s)
        let ctl = InspectorController(model: m)
        m.run("review.thesaurusPane")
        #expect(m.ui.pane == "thesaurus")
        #expect(ctl.tab == .review)
        #expect(m.thesaurusQuery == "Goal")
        #expect(ctl.thesaurusSenses.contains { $0.synonyms.contains("Objective") })
        ctl.pickSynonym("Objective")
        #expect(Fx.shape(s, UInt32(id))?.text?.paragraphs.first?.text == "Our Objective is growth.")
        #expect(m.thesaurusQuery == "Objective", "the pane follows the new word")
        m.thesaurusQuery = "zzxq"
        #expect(ctl.thesaurusSenses.isEmpty)
    }

    // smartart_tests.rs: text_pane_types_adds_and_demotes
    @Test func textPaneTypesAddsAndDemotes() throws {
        let s = Fx.blank()
        _ = try s.execute("insert.smartArt", ["kind": "list", "items": ["Plan", "Build"]])
        let ctl = InspectorController(model: AppModel(session: s))
        func levels() -> [String] { ctl.smartArt?.diagram.nodes.map { "\($0.text):\($0.level)" } ?? [] }
        let gid = try #require(ctl.smartArt?.id)
        ctl.setNode(gid, 1, "Build it")
        let row = ctl.smartArtEdit("smartArt.addNode", gid, ["index": 1, "position": "after"], focus: 2)
        #expect(row == 2)
        #expect(levels() == ["Plan:0", "Build it:0", ":0"])
        ctl.setNode(gid, 2, "Test")
        ctl.smartArtEdit("smartArt.demote", gid, ["index": 2], focus: 2)
        #expect(levels() == ["Plan:0", "Build it:0", "Test:1"])
        #expect(ctl.smartartRow == 2)
    }

    // smartart_tests.rs: home_convert_to_smartart_gallery_converts_the_text
    @Test func convertToSmartArtConvertsTheText() throws {
        let s = Fx.blank()
        _ = try s.execute("insert.textBox", ["text": "Goals\nRevenue\nGrowth"])
        let ctl = InspectorController(model: AppModel(session: s))
        #expect(ctl.enabled("smartArt.fromText"))
        ctl.run("smartArt.fromText", ["kind": "blockList"])
        let d = try #require(ctl.smartArt?.diagram)
        #expect(d.kind == "blockList")
        #expect(d.nodes.count == 3)
    }

    // theme_colors_tests.rs: customize_colors_opens_from_the_design_tab; theme_fonts_tests.rs:
    // customize_fonts_opens_from_the_design_tab (the dialog itself is the Dialogs area's)
    @Test func customizeColorsAndFontsAskForTheirDialogs() {
        let m = AppModel(session: Session.withNew())
        let host = RecordingHost()
        m.host = host
        let n = Fx.undoCount(m.session)
        m.run("design.colors")
        m.run("design.fonts")
        let ids = host.requests.compactMap { r -> String? in if case .dialog(let id, _) = r { id } else { nil } }
        #expect(ids == ["themeColors", "themeFonts"])
        #expect(Fx.undoCount(m.session) == n, "opening the dialogs is not an undo step")
        let scheme = builtinColorSchemes().last?.name ?? ""
        m.run("design.colors", ["name": .string(scheme)])
        #expect(m.session.activeDoc?.doc.masters.first?.theme.colors.name == scheme)
        #expect(m.session.activeDoc?.history.undo.last?.label == "Colors")
    }

    // effects_tests.rs: effects_menu_applies_a_scheme_once
    @Test func effectsMenuAppliesASchemeOnce() {
        let m = AppModel(session: Session.withNew())
        let theme = { m.session.activeDoc?.doc.masters.first?.theme }
        #expect(theme()?.format.name == "DeckCraft")
        let n = Fx.undoCount(m.session)
        m.run("design.effects", ["name": "Soft"])
        #expect(theme()?.format.name == "Soft")
        #expect(Fx.undoCount(m.session) == n + 1)
        #expect(theme()?.name == "DeckCraft")
        m.run("design.effects", ["name": "Soft"])
        #expect(Fx.undoCount(m.session) == n + 1, "the same scheme is not an undo step")
    }

    // ribbon.rs `comment_nav` and panes.rs `comments`: Previous / Next move the review pane's focus.
    @Test func commentNavigationFocusesTheCommentFound() throws {
        let s = Session.withNew()
        _ = try s.execute("comment.add", ["text": "first"])
        _ = try s.execute("comment.add", ["text": "second"])
        _ = try s.execute("slide.new", .emptyObject)
        _ = try s.execute("comment.add", ["text": "third"])
        _ = try s.execute("slide.go", ["index": 0])
        let m = AppModel(session: s)
        let ctl = InspectorController(model: m)
        #expect(ctl.commentThreads().map { $0.comments.count } == [2, 1])
        guard case .success = ctl.commentNav(forward: true) else { Issue.record("next"); return }
        #expect(m.ui.pane == "comments")
        let first = try #require(ctl.commentFocus)
        ctl.commentNav(forward: true)
        let second = try #require(ctl.commentFocus)
        #expect(second.slide != first.slide || second.index != first.index)
        ctl.reply(0, 0, "a reply")
        #expect(s.activeDoc?.doc.slides[0].comments[0].replies.first?.text == "a reply")
        ctl.resolve(0, 0, true)
        #expect(s.activeDoc?.doc.slides[0].comments[0].resolved == true)
        ctl.focusComment(0, 1)
        ctl.deleteComment(0, 0)
        #expect(ctl.commentFocus.map { [$0.slide, $0.index] } == [0, 0], "the focus moves with the comments after it")
        #expect(s.activeDoc?.doc.slides[0].comments.count == 1)
    }

    // lib.rs: the Quick Access Toolbar test (`app.qat` add, remove, reset)
    @Test func quickAccessToolbarAddsRemovesAndResets() throws {
        let ctl = InspectorController(model: AppModel(session: Session.withNew()))
        var changes = 0
        ctl.onQATChange = { changes += 1 }
        let ids = { ctl.qat.map(\.id) }
        #expect(ids() == ["app.home", "file.save", "app.exportDialog", "edit.undo", "edit.redo", "show.fromStart"])
        _ = try ctl.qatCommand(["add": "insert.table", "label": "Table", "icon": "table"]).get()
        _ = try ctl.qatCommand(["add": "insert.table"]).get()
        _ = try ctl.qatCommand(["add": "view.pane", "params": ["pane": "selection"], "label": "Selection Pane"]).get()
        #expect(throws: CommandError.self) { try ctl.qatCommand(["add": "no.such"]).get() }
        _ = try ctl.qatCommand(["remove": "edit.redo"]).get()
        #expect(ids() == ["app.home", "file.save", "app.exportDialog", "edit.undo", "show.fromStart", "insert.table", "view.pane"])
        #expect(ctl.qat[5].label == "Table")
        #expect(ctl.qat[6].paramsJSON == ["pane": "selection"])
        // Kept between launches and read back.
        let defaults = try #require(UserDefaults(suiteName: "DeckCraftInspectorTests-\(UUID().uuidString)"))
        QAT.save(ctl.qat, defaults)
        #expect(QAT.load(defaults) == ctl.qat)
        let r = try ctl.qatCommand(["remove": "view.pane", "params": ["pane": "selection"]]).get()
        #expect(r.asArray?.count == 6)
        _ = try ctl.qatCommand(["reset": true]).get()
        #expect(ids() == ["app.home", "file.save", "app.exportDialog", "edit.undo", "edit.redo", "show.fromStart"])
        #expect(changes == 6)
        // An empty settings store gets the defaults.
        let fresh = try #require(UserDefaults(suiteName: "DeckCraftInspectorTests-\(UUID().uuidString)"))
        #expect(QAT.load(fresh).count == 6)
    }

    // ribbon.rs: smooth_corners_row, quick_styles, zoom_menu
    @Test func editShapeQuickStylesAndZoom() throws {
        let s = Fx.blank()
        let id = Fx.rect(s, 40, 40, w: 200, h: 100)
        let sh = try #require(Fx.shape(s, id))
        #expect(abs((InspectorShape.cornerRadius(sh) ?? 0) - 100 * 16667 / 100_000) < 1e-9)
        Fx.select(s, [id])
        let m = AppModel(session: s)
        m.run("shape.smoothCorners", InspectorShape.smoothParams(60, radius: InspectorShape.cornerRadius(sh) ?? 0))
        #expect(Fx.shape(s, id)?.geom != sh.geom, "the corners were smoothed")
        #expect(InspectorShape.cornerRadius(try #require(Fx.shape(s, id))) == nil, "a freeform has no corner radius")
        #expect(InspectorShape.smoothParams(.nan, radius: 3)["smoothing"]?.asF64 == 0)
        #expect(InspectorShape.quickStyleIndex(row: 5, column: 6) == 41)
        let before = Fx.undoCount(s)
        m.run("edit.undo")
        m.run("shape.quickStyle", ["index": .integer(InspectorShape.quickStyleIndex(row: 1, column: 2))])
        #expect(Fx.undoCount(s) == before, "undo then one quick style")
        #expect(InspectorShape.zoomParams("slide", []) == nil)
        #expect(InspectorShape.zoomParams("slide", [2, 0]) == ["kind": "slide", "slides": [0, 2]])
        #expect(InspectorShape.zoomParams("section", [1]) == ["kind": "section", "sections": [1]])
        let doc = try #require(s.activeDoc?.doc)
        #expect(InspectorShape.zoomItems(doc, "slide").count == doc.slides.count)
        let slides = doc.slides.count
        m.run("insert.zoom", try #require(InspectorShape.zoomParams("summary", [0, 1])))
        #expect((s.activeDoc?.doc.slides.count ?? 0) > slides, "Summary Zoom adds its slide")
    }
}
