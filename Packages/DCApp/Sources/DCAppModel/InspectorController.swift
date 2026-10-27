// DCAppModel — the inspector's state and actions without a window: which tab `view.pane` opens, the
// contextual formatting the selection offers (the ribbon's contextual tabs), the colours Shape Fill and
// Shape Outline remember, Align to Slide, the comment the review pane focuses, the SmartArt Text Pane's row,
// the Thesaurus, and the Quick Access Toolbar. Ports the state `SlideApp` keeps for the panes and the ribbon
// in deckcraft `crates/ui-egui/src/lib.rs`, `ribbon.rs` and `panes.rs` (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors). Every action runs a registry command through `AppModel.run`.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Observation

/// The inspector's tabs (Keynote's Format / Animate / Document, plus Arrange and Review).
public enum InspectorTab: String, Sendable, CaseIterable {
    case format, arrange, animate, slide, review

    public var label: String {
        switch self {
        case .format: "Format"
        case .arrange: "Arrange"
        case .animate: "Animate"
        case .slide: "Slide"
        case .review: "Review"
        }
    }

    /// The `view.pane` id a click on the tab opens.
    public var pane: String {
        switch self {
        case .format: "format"
        case .arrange: "selection"
        case .animate: "animation"
        case .slide: "background"
        case .review: "comments"
        }
    }

    /// The tab that shows deckcraft's task pane `pane` (nil: none open, which shows Format).
    public static func forPane(_ pane: String?) -> InspectorTab {
        switch pane {
        case "selection"?: .arrange
        case "animation"?: .animate
        case "background"?, "designer"?: .slide
        case "comments"?, "thesaurus"?, "revisions"?: .review
        default: .format
        }
    }
}

@MainActor @Observable
public final class InspectorController {
    @ObservationIgnored public let model: AppModel
    /// Shape Fill's and Shape Outline's last colour (`last_fill`, `last_outline`): their buttons apply it.
    public var lastFill: JSON = "accent1"
    public var lastOutline: JSON = "tx1"
    /// Table Design ▸ Borders' pen (`table_pen`).
    public var tablePen: JSON = ["width": 1.0]
    /// Align to Slide or to the selected objects, for this selection (`align_to`).
    public var alignTo: (ids: [ShapeId], slide: Bool)?
    /// The comment the review pane focuses (`comment_focus`).
    public var commentFocus: (slide: Int, index: Int)?
    /// The SmartArt Text Pane's current line (`smartart_row`).
    public var smartartRow = 0
    /// The Animation Pane row last clicked, per document and slide.
    public var animPick: (uid: UInt64, slide: Int, index: Int)?
    public var selectionPane = SelectionPane.State()
    /// The Quick Access Toolbar's buttons: the window toolbar's command items.
    public var qat: [QatItem]
    /// Called after `app.qat` changes the buttons (the toolbars follow).
    @ObservationIgnored public var onQATChange: (@MainActor () -> Void)?

    public init(model: AppModel, qat: [QatItem] = QAT.defaults) {
        self.model = model
        self.qat = qat
    }

    /// The session. Reading it (or `doc`) from a view makes the view depend on `AppModel.revision`, so every
    /// view that reads the document redraws after each command.
    public var session: Session {
        _ = model.revision
        return model.session
    }

    public var doc: DocState? { session.activeDoc }

    @discardableResult
    public func run(_ id: String, _ params: JSON = .emptyObject) -> Result<JSON, CommandError> { model.run(id, params) }

    /// Whether engine command `id` is enabled now (`ribbon::enabled`); UI commands always are.
    public func enabled(_ id: String) -> Bool {
        if let c = findCommand(id) { return c.enabled(session) == nil }
        return UICommands.contains(id)
    }

    // MARK: Tabs

    public var tab: InspectorTab { InspectorTab.forPane(model.ui.pane) }

    /// Show `tab`: `view.pane` with its pane, so the control channel and `ui.json` see it.
    public func show(_ tab: InspectorTab) {
        guard tab != self.tab || model.ui.pane == nil else { return }
        run("view.pane", ["pane": .string(tab.pane)])
    }

    /// `contextual`: the ribbon's contextual tabs for the selection, which the Format tab shows as sections.
    public func contextual() -> [String] {
        guard let st = doc else { return [] }
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

    /// The Format tab's sub-tabs for the selection: deckcraft's Format Shape tabs, plus Picture when a
    /// picture is selected and the contextual Table, Chart, SmartArt and Media tabs.
    public func formatTabs() -> [(id: String, label: String)] {
        let ctx = contextual()
        var tabs: [(String, String)] = [("fill", "Fill & Line"), ("effects", "Effects"), ("size", "Size"), ("text", "Text")]
        if ctx.contains("Picture Format") { tabs.append(("picture", "Picture")) }
        if ctx.contains("Table Design") { tabs.append(("table", "Table")) }
        if ctx.contains("Chart Design") { tabs.append(("chart", "Chart")) }
        if ctx.contains("SmartArt Design") { tabs.append(("smartart", "SmartArt")) }
        if ctx.contains("Playback") { tabs.append(("media", "Playback")) }
        return tabs
    }

    /// The Format sub-tab shown: `ui.formatTab`, or Fill & Line when the selection doesn't offer it. The
    /// SmartArt Text Pane (`view.pane {pane: smartart}`) shows SmartArt.
    public var formatTab: String {
        if model.ui.pane == "smartart" { return "smartart" }
        let tabs = formatTabs().map(\.id)
        return tabs.contains(model.ui.formatTab) ? model.ui.formatTab : "fill"
    }

    public func showFormatTab(_ id: String) {
        run("view.pane", ["pane": "format", "tab": .string(id)])
    }

    // MARK: State the panes read

    /// `fmt_state`: the formatting at the selection (bold, size…), empty without one.
    public func formatState() -> JSON {
        guard let st = doc, !(st.selection.shapes.isEmpty && st.selection.text == nil) else { return .emptyObject }
        return (try? model.session.execute("format.state", .emptyObject)) ?? .emptyObject
    }

    /// The first selected shape.
    public var selectedShape: Shape? { doc?.selectedShapes.first }

    /// The selected shape's effective box.
    public func box(_ sh: Shape) -> Xfrm? {
        guard let st = doc else { return nil }
        return Cmd.xfrmOf(st.doc, st.selection, sh)
    }

    /// The selection's first animation (the Animations tab's current one).
    public var currentAnimation: Animation? {
        guard let st = doc, let slide = st.currentSlide, let id = st.selection.shapes.first else { return nil }
        return slide.animations.first { $0.shape == id }
    }

    // MARK: Shape Fill / Shape Outline (last_color_tests.rs)

    /// The Shape Fill button: the last colour picked from its menu (Accent 1 before any).
    public func shapeFillButton() { run("shape.fill", ["color": lastFill]) }

    /// A Shape Fill menu pick: a colour (remembered) or No Fill.
    public func pickFill(_ c: ColorRef?) {
        if let c {
            lastFill = InspectorColors.param(c)
            run("shape.fill", ["color": lastFill])
        } else {
            run("shape.fill", ["none": true])
        }
    }

    /// The Shape Outline button: the last colour picked from its menu (Text 1 before any).
    public func shapeOutlineButton() { run("shape.line", ["color": lastOutline]) }

    public func pickOutline(_ c: ColorRef?) {
        if let c {
            lastOutline = InspectorColors.param(c)
            run("shape.line", ["color": lastOutline])
        } else {
            run("shape.line", ["none": true])
        }
    }

    // MARK: Align (align_tests.rs)

    /// `align_to_slide`: one object aligns to the slide and several to each other, unless the other choice
    /// was ticked for this same selection.
    public static func alignToSlide(_ choice: (ids: [ShapeId], slide: Bool)?, _ selection: [ShapeId]) -> Bool {
        if let c = choice, c.ids == selection { return c.slide }
        return selection.count < 2
    }

    public var alignsToSlide: Bool { Self.alignToSlide(alignTo, doc?.selection.shapes ?? []) }

    public func setAlignTo(slide: Bool) { alignTo = (doc?.selection.shapes ?? [], slide) }

    public func align(_ edge: String) {
        run("arrange.align", ["edge": .string(edge), "to": .string(alignsToSlide ? "slide" : "selection")])
    }

    public func distribute(_ dir: String) {
        run("arrange.distribute", ["dir": .string(dir), "to": .string(alignsToSlide ? "slide" : "selection")])
    }

    // MARK: Comments (panes.rs `comments`, ribbon.rs `comment_nav`)

    /// The slides that have comments, with their threads.
    public func commentThreads() -> [(slide: Int, comments: [Comment])] {
        guard let st = doc else { return [] }
        return st.doc.slides.enumerated().filter { !$0.element.comments.isEmpty }.map { ($0.offset, $0.element.comments) }
    }

    /// `focus_comment`: go to the comment's slide and focus it.
    public func focusComment(_ slide: Int, _ index: Int) {
        run("slide.go", ["index": .integer(slide)])
        commentFocus = (slide, index)
    }

    public func reply(_ slide: Int, _ index: Int, _ text: String) {
        guard !rustTrim(text).isEmpty else { return }
        focusComment(slide, index)
        run("comment.reply", ["index": .integer(index), "text": .string(text)])
    }

    public func resolve(_ slide: Int, _ index: Int, _ resolved: Bool) {
        focusComment(slide, index)
        run("comment.resolve", ["index": .integer(index), "resolved": .bool(resolved)])
    }

    /// Delete a comment; the focus moves with the comments after it.
    public func deleteComment(_ slide: Int, _ index: Int) {
        run("slide.go", ["index": .integer(slide)])
        run("comment.delete", ["index": .integer(index)])
        if let f = commentFocus, f.slide == slide {
            if f.index == index { commentFocus = nil } else if f.index > index { commentFocus = (slide, f.index - 1) }
        }
    }

    /// `comment_nav`: Review ▸ Previous / Next from the focused comment; the pane opens on the one found.
    @discardableResult
    public func commentNav(forward: Bool) -> Result<JSON, CommandError> {
        let id = forward ? "comment.next" : "comment.prev"
        var params: JSON = .emptyObject
        if let f = commentFocus, doc?.selection.slide == f.slide {
            params = ["slide": .integer(f.slide), "index": .integer(f.index)]
        }
        let r = run(id, params)
        if case .success(let v) = r, let s = v["slide"]?.asU64, let i = v["index"]?.asU64, let slide = Int(exactly: s), let index = Int(exactly: i) {
            commentFocus = (slide, index)
            model.ui.pane = "comments"
        }
        return r
    }

    // MARK: Thesaurus (panes.rs `thesaurus`)

    public var thesaurusSenses: [Thesaurus.Sense] { Thesaurus.lookup(model.thesaurusQuery) }

    /// Whether a synonym click replaces the word being edited (else it looks the synonym up).
    public var editingText: Bool { doc?.selection.text != nil }

    /// A synonym clicked: put in place of the word when editing text, and look it up in turn.
    public func pickSynonym(_ word: String) {
        if editingText { run("review.replaceWord", ["with": .string(word)]) }
        model.thesaurusQuery = word
    }

    // MARK: SmartArt Text Pane (panes.rs `smartart`)

    /// The selected SmartArt graphic and its nodes.
    public var smartArt: (id: ShapeId, diagram: Diagram)? { doc.flatMap { SmartArtCommands.selected($0) } }

    /// Commit a changed line.
    public func setNode(_ gid: ShapeId, _ index: Int, _ text: String) {
        run("smartArt.setNodes", ["id": .integer(gid.rawValue), "index": .integer(index), "text": .string(text)])
    }

    /// A structural edit (`smartArt.addNode` / `removeNode` / `promote` / `demote`) on the graphic; the row
    /// it leaves focused (its answer's `index`, else `focus`).
    @discardableResult
    public func smartArtEdit(_ cmd: String, _ gid: ShapeId, _ params: JSON, focus: Int) -> Int? {
        var p = params
        p.set("id", .integer(gid.rawValue))
        guard case .success(let r) = run(cmd, p) else { return nil }
        let row = r["index"]?.asU64.flatMap { Int(exactly: $0) } ?? focus
        smartartRow = row
        return row
    }

    // MARK: Animation Pane

    public func animationPane() -> AnimPane { doc.map(AnimPane.init) ?? AnimPane() }

    /// The pane row last clicked on this document and slide.
    public var currentAnimPick: Int? {
        guard let st = doc, let p = animPick, p.uid == st.uid, p.slide == st.selection.slide else { return nil }
        return p.index
    }

    /// A pane row clicked: remembered for Play From, and its shape selected.
    public func clickAnimation(_ row: AnimPaneRow) {
        if let st = doc { animPick = (st.uid, st.selection.slide, row.index) }
        run("edit.select", ["ids": [.integer(row.shape.rawValue)]])
    }

    /// Reorder or remove: the remembered row would point at another effect, so it is forgotten.
    public func animationEdit(_ cmd: String, _ params: JSON) {
        animPick = nil
        run(cmd, params)
    }

    // MARK: Quick Access Toolbar

    /// `app.qat`.
    public func qatCommand(_ p: JSON) -> Result<JSON, CommandError> {
        let r = QAT.command(&qat, p)
        if case .success = r { onQATChange?() }
        return r
    }

    // MARK: ui.inspect

    /// The inspector's part of `ui.inspect`.
    public func inspect() -> JSON {
        var o: JSON = [
            "tab": .string(tab.rawValue), "formatTab": .string(formatTab),
            "contextual": .array(contextual().map(JSON.string)), "lastFill": lastFill, "lastOutline": lastOutline,
            "alignToSlide": .bool(alignsToSlide), "qat": .array(qat.map { $0.toJSON() }),
        ]
        if let f = commentFocus { o.set("commentFocus", [.integer(f.slide), .integer(f.index)]) }
        return o
    }
}
