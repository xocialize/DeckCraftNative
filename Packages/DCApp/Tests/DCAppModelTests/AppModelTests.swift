// DCAppModelTests — the app model without a window: UI state, the UI-only commands, the palette and the
// menu tree. Tests ported from deckcraft `crates/ui-egui` name their source.
import DCCore
import DCEngine
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct AppModelTests {
    // menus.rs: palette_has_one_export_entry_that_opens_the_dialog (#79)
    @Test func paletteHasOneExportEntryThatOpensTheDialog() {
        let session = Session.withNew()
        for query in ["exp", "export"] {
            let exports = Palette.items(session, query).filter { $0.label == "Export…" }
            #expect(exports.count == 1, "query \(query)")
            #expect(exports.first?.id == "app.exportDialog")
        }
        for c in UICommands.all where !Cmd.needsArguments(c.params) {
            let same = Palette.items(session, c.label.lowercased()).filter { $0.label == c.label }
            #expect(same.count == 1, "\(c.label)")
            #expect(same.first?.id == c.id, "\(c.label)")
        }
    }

    @Test func viewCommandsChangeUiState() {
        let m = AppModel(session: Session.withNew())
        #expect(m.ui.view == .normal)
        m.run("view.sorter")
        #expect(m.ui.view == .sorter)
        m.run("view.ruler")
        #expect(m.ui.ruler)
        m.run("view.ruler", ["on": true])
        #expect(m.ui.ruler)
        m.run("view.zoom", ["percent": 250])
        #expect(m.ui.zoom == Double(Float(2.5)))
        m.run("view.zoomIn")
        #expect(m.ui.zoom == 3)
        m.run("view.fit")
        #expect(m.ui.zoom == nil)
    }

    @Test func guidesAddTheCentreGuides() {
        let m = AppModel(session: Session.withNew())
        m.run("view.guides", ["on": true])
        #expect(m.session.activeDoc?.doc.guides.count == 2)
    }

    @Test func gridOptionsAnswerAndValidate() throws {
        let m = AppModel(session: Session.withNew())
        let r = try m.run("view.gridOptions", ["spacing": 12, "snap": false]).get()
        #expect(r["spacing"]?.asF64 == 12)
        #expect(r["snap"]?.asBool == false)
        #expect(throws: (any Error).self) { try m.run("view.gridOptions", ["spacing": 500]).get() }
    }

    @Test func windowCommandsWithoutAHostFail() {
        let m = AppModel(session: Session.withNew())
        guard case .failure(let e) = m.run("app.exportDialog") else { Issue.record("expected a failure"); return }
        #expect(e.message == "unknown UI command `app.exportDialog`")
        #expect(m.status == e.message)
    }

    @Test func engineCommandsReachTheSession() {
        let m = AppModel(session: Session.withNew())
        let before = m.session.activeDoc?.doc.slides.count ?? 0
        m.run("slide.new")
        #expect(m.session.activeDoc?.doc.slides.count == before + 1)
        #expect(m.revision > 0)
    }

    @Test func uiStateIsSanitized() {
        var s = UiState()
        s.zoom = 100
        s.thumbsWidth = .nan
        s.recent = ["a", "a", "", "b"] + (0 ..< 20).map { "f\($0)" }
        s.handoutPerPage = 5
        let t = s.sanitized()
        #expect(t.zoom == 4)
        #expect(t.thumbsWidth == UiState().thumbsWidth)
        #expect(t.recent.prefix(2) == ["a", "b"])
        #expect(t.recent.count == UiState.recentMax)
        #expect(t.handoutPerPage == 6)
    }

    @Test func uiStateReadsDamagedFiles() throws {
        let data = Data(#"{"view": "sorter", "zoom": "big", "notes": 3}"#.utf8)
        let s = try JSONDecoder().decode(UiState.self, from: data)
        #expect(s.view == .sorter)
        #expect(s.zoom == nil)
        #expect(s.notes == true)
    }

    @Test func menuCommandsAreRegistered() {
        // Every menu entry names an engine or UI command, except the master views (not in the registry yet).
        let pending: Set = ["view.slideMaster", "view.handoutMaster", "view.notesMaster", "show.fromStart", "show.fromCurrent", "shape.sizePosition"]
        for m in MenuTree.menus {
            for case .command(let label, let id) in m.entries where !pending.contains(id) {
                #expect(findCommand(id) != nil || UICommands.contains(id), "\(m.title) › \(label): \(id)")
            }
        }
    }

    @Test func shortcutsParse() {
        #expect(Shortcut("Cmd+Shift+P") == { var s = Shortcut("P")!; s.cmd = true; s.shift = true; return s }())
        #expect(Shortcut("F5")?.key == "F5")
        #expect(Shortcut("Alt+F9")?.alt == true)
        #expect(Shortcut("Cmd+=")?.key == "=")
        #expect(Shortcut("Cmd++")?.key == "+")
        #expect(Shortcut("Hyper+K") == nil)
        #expect(Shortcut("") == nil)
    }
}
