// DCApp — the inspector's and the toolbar's installation: the one `InspectorController` every window's
// inspector shows, `app.qat` (deckcraft's Quick Access Toolbar, `crates/ui-egui/src/qat.rs`, as toolbar
// items), the inspector's part of `ui.inspect`, and the inspector following `ui.pane` (a pane opened by
// `view.pane`, a command or the control channel shows the inspector; `view.pane {pane: null}` hides it).
// MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
import AppKit
import DCAppModel
import DCCore
import Observation

@MainActor
enum InspectorFeature {
    /// The inspector's state and actions, shared by every window (the session is one).
    static var controller: InspectorController?
    private static var shownPane: String??

    static func install(_ app: AppController) {
        let ctl = InspectorController(model: app.model, qat: QAT.load())
        controller = ctl
        ctl.onQATChange = {
            QAT.save(ctl.qat)
            ToolbarCatalog.syncQAT()
        }
        app.handle(["app.qat"]) { p in ctl.qatCommand(p) }
        app.inspect("inspector") { ctl.inspect() }
        shownPane = .some(ctl.model.ui.pane)
        followPane(ctl)
    }

    /// Show or hide every document window's inspector when `ui.pane` changes.
    private static func followPane(_ ctl: InspectorController) {
        withObservationTracking {
            _ = ctl.model.ui.pane
        } onChange: {
            Task { @MainActor in
                syncVisibility(ctl.model.ui.pane)
                followPane(ctl)
            }
        }
    }

    static func syncVisibility(_ pane: String?) {
        defer { shownPane = .some(pane) }
        guard let last = shownPane, last != pane else { return }
        for w in NSApp.windows {
            guard let wc = w.windowController as? DocumentWindowController, let item = wc.split.splitViewItems.last,
                  item.behavior == .inspector else { continue }
            if pane != nil, item.isCollapsed {
                item.animator().isCollapsed = false
            } else if pane == nil, last != nil, !item.isCollapsed {
                item.animator().isCollapsed = true
            }
        }
    }
}
