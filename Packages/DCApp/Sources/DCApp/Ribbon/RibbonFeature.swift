// DCApp — the ribbon layout (Docs/plans/Ribbon-and-StartScreen.md §4, §8, R1): every document window follows
// `UiState.layout`. In the ribbon layout the window gets the ribbon across the window under the toolbar (where
// PowerPoint and deckcraft put it), and a toolbar with the Quick Access Toolbar's buttons at the leading edge,
// then Search, Present and Comments; the inspector becomes the task pane the ribbon's pane buttons open. Switching
// keeps the window, so the document, the selection and the undo stack are untouched. Also `ui.inspect`'s `ribbon`.
import AppKit
import DCAppModel
import DCCore
import Observation
import SwiftUI

/// What a document window holds while it shows the ribbon: the container that puts the ribbon above the split
/// view, and the Mac layout's toolbar and inspector to put back.
@MainActor
final class RibbonAttachment {
    let container: RibbonContainerController
    let macToolbar: NSToolbar?
    let toolbar: RibbonToolbar
    /// Whether the inspector was open in the Mac layout.
    let inspectorWasOpen: Bool
    init(container: RibbonContainerController, macToolbar: NSToolbar?, toolbar: RibbonToolbar, inspectorWasOpen: Bool) {
        self.container = container
        self.macToolbar = macToolbar
        self.toolbar = toolbar
        self.inspectorWasOpen = inspectorWasOpen
    }
}

/// The window's content in the ribbon layout: the ribbon across the window under the toolbar, the split view (the
/// navigator, the editing area, the inspector) under it. A titlebar accessory would sit only over the split view's
/// content section, so the ribbon is a plain view pinned to the safe area.
@MainActor
final class RibbonContainerController: NSViewController {
    let split: NSSplitViewController
    let host: NSHostingView<RibbonView>
    private var height: NSLayoutConstraint?

    init(split: NSSplitViewController, model: AppModel) {
        self.split = split
        host = NSHostingView(rootView: RibbonView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        addChild(split)
        // The ribbon's height is set here, not by SwiftUI's idea of it.
        host.sizingOptions = []
        for v in [host, split.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let h = host.heightAnchor.constraint(equalToConstant: RibbonView.height(collapsed: false))
        height = h
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            h,
            split.view.topAnchor.constraint(equalTo: host.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func setCollapsed(_ collapsed: Bool) { height?.constant = RibbonView.height(collapsed: collapsed) }

    /// Give the split view back, for the Mac layout.
    func release() {
        split.view.removeFromSuperview()
        split.removeFromParent()
    }
}

@MainActor
enum RibbonFeature {
    static func install(_ app: AppController) {
        RibbonModel.inspector = InspectorFeature.controller
        app.inspect("ribbon") { RibbonModel.inspect(app.model) }
        follow(app.model)
    }

    /// Every document window follows the layout and the minimised state.
    private static func follow(_ model: AppModel) {
        withObservationTracking {
            _ = model.ui.layout
            _ = model.ui.ribbonCollapsed
        } onChange: {
            Task { @MainActor in
                for w in NSApp.windows { if let wc = w.windowController as? DocumentWindowController { apply(wc) } }
                follow(model)
            }
        }
    }

    /// Put the window in the layout `UiState.layout` asks for.
    static func apply(_ wc: DocumentWindowController) {
        guard let window = wc.window, let model = AppController.shared?.model else { return }
        if model.ui.layout == .ribbon {
            if let a = wc.ribbon {
                a.container.setCollapsed(model.ui.ribbonCollapsed)
                return
            }
            let frame = window.frame
            let inspector = wc.split.splitViewItems.last
            let container = RibbonContainerController(split: wc.split, model: model)
            let attachment = RibbonAttachment(container: container, macToolbar: window.toolbar, toolbar: RibbonToolbar(),
                                              inspectorWasOpen: inspector.map { !$0.isCollapsed } ?? false)
            wc.ribbon = attachment
            attachment.toolbar.follow(window)
            window.toolbar = attachment.toolbar.make()
            window.titleVisibility = .hidden
            window.contentViewController = container
            container.setCollapsed(model.ui.ribbonCollapsed)
            window.setFrame(frame, display: true)
            // The inspector is the task pane: closed until a ribbon button opens a pane (§8).
            if model.ui.pane == nil { inspector?.isCollapsed = true }
        } else if let a = wc.ribbon {
            wc.ribbon = nil
            let frame = window.frame
            a.container.release()
            window.contentViewController = wc.split
            window.toolbar = a.macToolbar
            window.titleVisibility = .visible
            window.setFrame(frame, display: true)
            if a.inspectorWasOpen { wc.split.splitViewItems.last?.isCollapsed = false }
        }
    }

    /// After `app.qat`: the ribbon layout's toolbars get the new buttons.
    static func syncQAT() {
        for w in NSApp.windows {
            guard let wc = w.windowController as? DocumentWindowController, let a = wc.ribbon else { continue }
            w.toolbar = a.toolbar.make()
        }
    }
}

/// The ribbon layout's toolbar (§8): the Quick Access Toolbar's buttons at the leading edge, the window's title, then
/// Search, Present and Comments. The window's own title is hidden so the buttons can come before it.
@MainActor
final class RibbonToolbar: NSObject, NSToolbarDelegate {
    static let title = NSToolbarItem.Identifier("dc.ribbon.title")
    static let search = NSToolbarItem.Identifier("dc.ribbon.search")
    static let present = NSToolbarItem.Identifier("dc.ribbon.present")
    static let comments = NSToolbarItem.Identifier("dc.ribbon.comments")

    /// Items: identifier, label, command and parameters.
    static let commands: [(id: NSToolbarItem.Identifier, label: String, command: String, params: JSON, symbol: String)] = [
        (search, String(localized: "Search", bundle: .module, comment: "Toolbar item: find a command by name"), "app.palette", .emptyObject, "magnifyingglass"),
        (present, String(localized: "Present", bundle: .module, comment: "Toolbar item: play the slide show from the current slide"), "show.fromCurrent", .emptyObject, "play.fill"),
        (comments, String(localized: "Comments", bundle: .module, comment: "Toolbar item: show the comments pane"), "view.pane", ["pane": "comments", "toggle": true], "text.bubble"),
    ]

    let titleField = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?

    /// Show `window`'s title in the toolbar while the ribbon layout hides the window's own.
    func follow(_ window: NSWindow) {
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.stringValue = window.title
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated { self?.titleField.stringValue = w.title }
        }
    }

    /// A fresh toolbar: its items are rebuilt from the Quick Access Toolbar each time.
    func make() -> NSToolbar {
        let t = NSToolbar(identifier: "DeckCraftRibbon")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        t.autosavesConfiguration = false
        return t
    }

    var qatItems: [NSToolbarItem.Identifier] {
        (InspectorFeature.controller?.qat ?? QAT.defaults).map { NSToolbarItem.Identifier(ToolbarCatalog.qatPrefix + $0.identifier) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        qatItems + [.flexibleSpace, Self.title, .flexibleSpace] + Self.commands.map(\.id)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue.hasPrefix(ToolbarCatalog.qatPrefix) { return ToolbarCatalog.qatItem(id) }
        if id == Self.title {
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = titleField
            item.label = ""
            item.isBordered = false
            return item
        }
        guard let e = Self.commands.first(where: { $0.id == id }) else { return nil }
        ToolbarCatalog.payloads[id.rawValue] = ToolbarPayload(e.command, e.params)
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = e.label
        item.paletteLabel = e.label
        item.toolTip = ToolbarCatalog.tooltip(e.command, e.params, e.label)
        item.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: e.label)
        item.target = ToolbarActions.shared
        item.action = #selector(ToolbarActions.run(_:))
        return item
    }
}
