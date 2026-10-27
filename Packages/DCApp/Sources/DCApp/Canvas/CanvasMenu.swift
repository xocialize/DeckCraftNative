// DCApp — the canvas's context menu as an `NSMenu`, built from `CanvasContextMenu` (deckcraft's
// `context_menu` in `crates/ui-egui/src/canvas.rs`, MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import AppKit
import DCAppModel

@MainActor
enum CanvasMenu {
    /// The menu for `entries`: each item performs its action through the app.
    static func build(_ entries: [CanvasMenuEntry], model: AppModel, squiggles: CanvasSquiggles) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        for e in entries {
            switch e {
            case .separator:
                // No separator first, last or twice.
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            case .note(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .submenu(let title, let kids):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = build(kids, model: model, squiggles: squiggles)
                item.isEnabled = !kids.isEmpty
                menu.addItem(item)
            case .item(let title, let action, let enabled, let checked, let bold):
                let item = ActionItem(title: title, action: action, model: model, squiggles: squiggles)
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
                menu.addItem(item)
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }

    /// A menu item that performs a `CanvasMenuAction`.
    @MainActor
    final class ActionItem: NSMenuItem {
        let canvasAction: CanvasMenuAction
        weak var model: AppModel?
        weak var squiggles: CanvasSquiggles?

        init(title: String, action: CanvasMenuAction, model: AppModel, squiggles: CanvasSquiggles) {
            canvasAction = action
            self.model = model
            self.squiggles = squiggles
            super.init(title: title, action: #selector(performCanvasAction(_:)), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            canvasAction = .run("", .null)
            super.init(coder: coder)
        }

        @objc func performCanvasAction(_ sender: Any?) {
            guard let model else { return }
            CanvasContextMenu.perform(canvasAction, model, squiggles: squiggles)
        }
    }
}
