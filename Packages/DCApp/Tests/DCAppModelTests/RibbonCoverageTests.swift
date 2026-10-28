// DCAppModelTests — the ribbon's table (`RibbonLayout`) against deckcraft's ribbon and the registry, and the
// tables it shares with the toolbar (`CommandMenus`, `CommandSymbols`, `CommandHelp`). The check is coverage, not
// order (Docs/plans/Ribbon-and-StartScreen.md §4): every command deckcraft's ribbon runs has a control here, or is
// left out with a reason; tab and group order follow what someone who knows PowerPoint expects.
import DCAppModel
import DCCore
import DCEngine
import DCTestSupport
import Foundation
import Testing

@Suite struct RibbonCoverageTests {
    /// The commands each file of deckcraft's ribbon runs, at the pin (`crates/ui-egui/src/`; every quoted command
    /// id outside comments and tests). `qat.rs` and `title_bar.rs` are the title bar, checked separately.
    static let deckcraft: [String: [String]] = [
        "ribbon.rs": ["format.state", "insert.dateTime"],
        "ribbon/animations.rs": ["animation.add", "animation.options", "animation.painter", "animation.preview", "animation.set", "animation.timing", "view.pane"],
        "ribbon/arrange.rs": ["arrange.align", "arrange.bringForward", "arrange.bringToFront", "arrange.distribute", "arrange.flipHorizontal",
                              "arrange.flipVertical", "arrange.group", "arrange.regroup", "arrange.rotateLeft", "arrange.rotateRight",
                              "arrange.sendBackward", "arrange.sendToBack", "arrange.ungroup", "shape.resize", "shape.sizePosition", "view.pane"],
        "ribbon/chart.rs": ["app.dialog", "chart.type"],
        "ribbon/design.rs": ["app.browseThemeDialog", "design.background", "design.browseTheme", "design.colors", "design.effects", "design.fonts",
                             "design.slideSize", "design.theme", "design.variant", "view.pane"],
        "ribbon/draw.rs": ["draw.inkToShape"],
        "ribbon/galleries.rs": ["shape.effects", "shape.line", "shape.quickStyle", "view.pane"],
        "ribbon/home.rs": ["app.find", "app.insertPictureDialog", "app.pasteSpecial", "app.replace", "app.reuseSlidesDialog", "edit.copy", "edit.cut",
                           "edit.paste", "edit.pasteText", "font.replace", "font.rescan", "format.alignCenter", "format.alignLeft", "format.alignRight",
                           "format.anchor", "format.bold", "format.bullets", "format.case", "format.clear", "format.color", "format.columns",
                           "format.direction", "format.font", "format.fontDialog", "format.grow", "format.highlight", "format.indent", "format.italic",
                           "format.justify", "format.lineSpacing", "format.numbering", "format.outdent", "format.painter", "format.painterApply",
                           "format.paragraphDialog", "format.shrink", "format.size", "format.spacing", "format.strikethrough", "format.subscript",
                           "format.superscript", "format.underline", "insert.textBox", "section.add", "section.removeAll", "shape.fill",
                           "shape.insert", "shape.line", "slide.duplicate", "slide.layout", "slide.new", "slide.reset", "smartArt.fromText", "view.pane"],
        "ribbon/insert.rs": ["app.dialog", "app.insertAudioDialog", "app.insertPictureDialog", "app.insertVideoDialog", "insert.actionButton",
                             "insert.chart", "insert.dateTime", "insert.icon", "insert.photoAlbum", "insert.photoAlbumEdit", "insert.slideNumber",
                             "insert.table", "insert.textBox", "insert.wordArt", "insert.zoom", "shape.insert", "slide.new"],
        "ribbon/masters.rs": ["app.browseThemeDialog", "app.dialog", "design.theme", "handout.placeholders", "master.deleteLayout", "master.insertLayout",
                              "master.insertPlaceholder", "master.placeholders", "master.preserve", "notes.placeholders", "view.closeMaster", "view.pane"],
        "ribbon/picture_format.rs": ["app.changePictureDialog", "app.dialog", "picture.adjust", "picture.artisticEffect", "picture.compress", "picture.crop",
                                     "picture.recolor", "picture.removeBackground", "picture.reset", "picture.style", "shape.change", "shape.line"],
        "ribbon/playback.rs": ["app.dialog", "media.options", "media.toggle"],
        "ribbon/qat.rs": ["app.exportDialog", "app.find", "app.home", "app.openDialog", "app.print", "edit.redo", "edit.undo", "file.new", "file.save",
                          "review.spelling", "show.fromStart"],
        "ribbon/review.rs": ["app.compareDialog", "app.dialog", "comment.delete", "comment.next", "comment.prev", "review.accept", "review.endCompare",
                             "review.thesaurusPane", "view.pane"],
        "ribbon/shape_format.rs": ["app.dialog", "format.color", "format.textOutline", "format.textShadow", "format.textWarp", "insert.textBox",
                                   "shape.change", "shape.editPoints", "shape.fill", "shape.line", "shape.merge", "shape.smoothCorners", "view.pane"],
        "ribbon/slide_show.rs": ["app.dialog", "show.setup", "slide.hide"],
        "ribbon/smartart.rs": ["app.smartArtPictureDialog", "smartArt.addNode", "smartArt.colors", "smartArt.demote", "smartArt.layout",
                               "smartArt.promote", "smartArt.style", "smartArt.toShapes", "smartArt.toText", "view.pane"],
        "ribbon/table.rs": ["edit.delete", "format.alignCenter", "format.alignLeft", "format.alignRight", "table.borders", "table.cellAlign", "table.cellFill",
                            "table.cellMargins", "table.deleteColumn", "table.deleteRow", "table.distributeColumns", "table.distributeRows",
                            "table.insertColumnLeft", "table.insertColumnRight", "table.insertRowAbove", "table.insertRowBelow", "table.merge",
                            "table.options", "table.split", "table.style"],
        "ribbon/title_bar.rs": ["view.dark", "view.pane"],
        "ribbon/transitions.rs": ["transition.applyAll", "transition.options", "transition.set", "transition.sound", "transition.timing"],
        "ribbon/view.rs": ["insert.zoom", "view.closeMaster", "view.dark", "view.fit", "view.gridOptions", "view.handoutMaster", "view.newWindow",
                           "view.normal", "view.notesMaster", "view.notesPage", "view.outline", "view.reading", "view.slideMaster", "view.sorter",
                           "view.zoom", "view.zoomDialog"],
    ]

    /// deckcraft ribbon commands with no control of their own here, and why.
    static let leftOut: [String: String] = [
        "format.state": "a query: the toggles read their on state from it",
        "design.browseTheme": "Browse for Themes' enabled check; the control runs app.browseThemeDialog",
    ]

    static func known(_ id: String) -> Bool { findCommand(id) != nil || UICommands.contains(id) || id.hasPrefix("tool.") }

    @Test func everyDeckcraftRibbonCommandHasAControl() {
        let have = RibbonLayout.commands
        for (file, ids) in Self.deckcraft where file != "ribbon/qat.rs" && file != "ribbon/title_bar.rs" {
            for id in ids where !have.contains(id) {
                #expect(Self.leftOut[id] != nil, "\(file): \(id) has no ribbon control and isn't listed as left out")
            }
        }
        for id in Self.leftOut.keys { #expect(!have.contains(id), "\(id) is listed as left out but has a control") }
    }

    /// The title bar's Quick Access Toolbar offers every command deckcraft's does.
    @Test func quickAccessOffersDeckcraftsCommands() {
        let common = Set(QAT.common.map(\.id))
        for id in Self.deckcraft["ribbon/qat.rs"] ?? [] { #expect(common.contains(id), "qat.rs: \(id)") }
    }

    /// When `../deckcraft` is checked out at the pin, the inventory above is exactly what its ribbon sources run:
    /// a new command upstream fails here until it is placed (CLAUDE.md, "Moving the pin").
    @Test func inventoryMatchesDeckcraftAtThePin() throws {
        let src = Fixtures.repositoryRoot.deletingLastPathComponent().appending(path: "deckcraft/crates/ui-egui/src")
        guard let pin = UpstreamPin.current(), Self.head(of: src) == pin.deckcraftCommit else { return }
        let fm = FileManager.default
        var files = ["ribbon.rs"]
        for f in try fm.contentsOfDirectory(atPath: src.appending(path: "ribbon").path).sorted() where f.hasSuffix(".rs") && !f.hasSuffix("_tests.rs") {
            files.append("ribbon/\(f)")
        }
        #expect(Set(files) == Set(Self.deckcraft.keys), "deckcraft's ribbon files changed: \(files)")
        for f in files {
            let text = try String(contentsOf: src.appending(path: f), encoding: .utf8)
            #expect(Self.commandIds(text) == Set(Self.deckcraft[f] ?? []), "\(f) at \(pin.short)")
        }
    }

    /// The quoted `word.word` strings in Rust source, outside `//` comments and its inline `mod tests`.
    static func commandIds(_ rust: String) -> Set<String> {
        let body = rust.components(separatedBy: "\nmod tests {").first ?? rust
        var out = Set<String>()
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
            for m in code.matches(of: /"([a-z][a-zA-Z]*\.[a-zA-Z][a-zA-Z.]*)"/) {
                let id = String(m.1)
                if !["rs", "png", "json", "svg", "txt", "md"].contains(where: { id.hasSuffix(".\($0)") }) { out.insert(id) }
            }
        }
        return out
    }

    static func head(of dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "rev-parse", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func everyRibbonCommandIsKnown() {
        for t in RibbonLayout.tabs {
            for g in t.groups {
                for c in g.controls {
                    for id in c.commands { #expect(Self.known(id), "\(t.title) ▸ \(g.title) ▸ \(c.id): \(id)") }
                }
            }
        }
    }

    @Test func idsAreUniqueAndControlsAreWellFormed() {
        let tabs = RibbonLayout.tabs.map(\.id)
        #expect(Set(tabs).count == tabs.count)
        let groups = RibbonLayout.tabs.flatMap(\.groups).map(\.id)
        #expect(Set(groups).count == groups.count, "duplicate group ids")
        let controls = RibbonLayout.tabs.flatMap(\.groups).flatMap(\.controls)
        #expect(Set(controls.map(\.id)).count == controls.count, "duplicate control ids")
        for c in controls {
            #expect(!c.sizes.isEmpty, "\(c.id) has no size")
            // A generic command doesn't name the control, so it carries a title.
            if ["app.dialog", "view.pane", "tool.ink", "tool.shape", "show.start"].contains(c.command.id) { #expect(c.title != nil, "\(c.id) needs a title") }
        }
        for g in RibbonLayout.tabs.flatMap(\.groups) { #expect(!g.controls.isEmpty && g.foldOrder >= 0, "\(g.id)") }
    }

    /// The ten regular tabs in PowerPoint's order, then the contextual tabs `InspectorController.contextual()` names.
    @Test func tabsAndContextualTabs() {
        let regular = RibbonLayout.tabs.filter { $0.contextual == nil }.map(\.title)
        #expect(regular == ["Home", "Insert", "Draw", "Design", "Transitions", "Animations", "Slide Show", "Record", "Review", "View"])
        let contextual = Set(RibbonLayout.tabs.compactMap(\.contextual))
        #expect(contextual == ["Slide Master", "Notes Master", "Handout Master", "Shape Format", "Picture Format", "Table Design", "Layout",
                               "SmartArt Design", "Chart Design", "Playback"])
        // Controls that never work in deckcraft are left out rather than greyed out for good.
        let titles = Set(RibbonLayout.tabs.flatMap(\.groups).flatMap(\.controls).compactMap(\.title))
        for gone in ["Screenshot", "Ink to Text", "Ink to Math", "Cameo", "Translate", "Add-ins"] { #expect(!titles.contains(gone), "\(gone)") }
    }

    /// RibbonMap is derived: every group names ribbon groups or controls that exist, and every ribbon group has a
    /// place in the Mac layout (the object tabs' shared Arrange and Size groups are Shape Format's).
    @Test func ribbonMapIsDerivedFromTheLayout() {
        var named = Set<String>()
        for m in RibbonMap.groups {
            for id in m.layout {
                #expect(RibbonLayout.commands(of: id) != nil, "\(m.tab) ▸ \(m.group): no ribbon group or control \(id)")
                named.insert(id)
            }
            #expect(!m.commands.isEmpty, "\(m.tab) ▸ \(m.group)")
            #expect(!m.commands.contains { $0.hasPrefix("tool.") })
        }
        for g in RibbonLayout.tabs.flatMap(\.groups) {
            let shared = g.id.hasSuffix(".arrange") || g.id.hasSuffix(".size")
            #expect(shared || named.contains(g.id) || g.controls.contains { named.contains($0.id) }, "\(g.id) has no place in the Mac layout")
        }
        let clipboard = RibbonMap.groups.first { $0.tab == "Home" && $0.group == "Clipboard" }
        #expect(Set(clipboard?.commands ?? []) == ["edit.paste", "edit.pasteText", "app.pasteSpecial", "format.painterApply", "edit.cut", "edit.copy", "format.painter"])
    }

    @Test func commandMenusRunKnownCommands() {
        for m in CommandMenus.ID.allCases {
            let ids = CommandMenus.commands(m)
            #expect(!ids.isEmpty, "\(m)")
            for id in ids { #expect(Self.known(id), "\(m): \(id)") }
        }
        #expect(CommandMenus.commands(.newSlide).first == "slide.new")
        #expect(CommandMenus.commands(.play) == ["show.fromStart", "show.fromCurrent", "show.presenter", "show.start", "app.dialog"])
    }

    @Test func commandSymbolsAndHelp() {
        #expect(CommandSymbols.symbol(CommandRef("insert.table", ["rows": 3, "cols": 3])) == "tablecells")
        #expect(CommandSymbols.symbol(CommandRef("app.dialog", ["id": "smartart"])) == "rectangle.3.group")
        #expect(CommandSymbols.symbol(CommandRef("app.dialog", ["id": "comment"])) == "text.bubble")
        #expect(CommandSymbols.symbol(CommandRef("app.dialog", ["id": "nothing"])) == nil)
        #expect(CommandSymbols.symbol(icon: "save") == "square.and.arrow.down")
        #expect(CommandSymbols.symbol(icon: "unknown") == "ellipsis.circle")
        // R0 starts the descriptions table empty; R1 fills it.
        #expect(CommandHelp.description("format.bold") == nil)
    }
}
