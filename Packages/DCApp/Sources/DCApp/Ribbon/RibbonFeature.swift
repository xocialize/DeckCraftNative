// DCApp — the ribbon layout (Docs/plans/Ribbon-and-StartScreen.md §4, §8, R1): every document window follows
// `UiState.layout`. In the ribbon layout the window gets the ribbon across the window under the toolbar (where
// PowerPoint and deckcraft put it), and a toolbar with the Quick Access Toolbar's buttons at the leading edge,
// then Search, Present and Comments; the inspector becomes the task pane the ribbon's pane buttons open. Switching
// keeps the window, so the document, the selection and the undo stack are untouched. Also `ui.inspect`'s `ribbon`.
import AppKit
import DCAppModel
import DCCore
import DCEngine
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
/// content section, so the ribbon is a plain view pinned to the safe area. It is above the split view, so a
/// minimised ribbon's transient panel (R3) can grow over the document without moving it.
@MainActor
final class RibbonContainerController: NSViewController {
    let split: NSSplitViewController
    let host: NSHostingView<RibbonView>
    let state = RibbonViewState()
    private var height: NSLayoutConstraint?
    private var top: NSLayoutConstraint?
    private var collapsed = false
    private var outside: Any?

    init(split: NSSplitViewController, model: AppModel) {
        self.split = split
        host = NSHostingView(rootView: RibbonView(model: model, state: state))
        super.init(nibName: nil, bundle: nil)
        state.host = host
        state.onPeek = { [weak self] in self?.setPeek($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        addChild(split)
        // The ribbon's height is set here, not by SwiftUI's idea of it.
        host.sizingOptions = []
        for v in [split.view, host] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let h = host.heightAnchor.constraint(equalToConstant: RibbonView.height(collapsed: false))
        let t = split.view.topAnchor.constraint(equalTo: host.topAnchor, constant: RibbonView.height(collapsed: false))
        height = h
        top = t
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            h, t,
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// The transient panel of a minimised ribbon: the ribbon grows over the document's top, and a click anywhere
    /// else closes it.
    private func setPeek(_ on: Bool) {
        height?.constant = RibbonView.height(collapsed: collapsed && !on)
        host.shadow = on ? NSShadow() : nil
        host.layer?.shadowOpacity = on ? 0.2 : 0
        if on, outside == nil {
            outside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, e.window === self.host.window else { return }
                    let p = self.host.convert(e.locationInWindow, from: nil)
                    if !self.host.bounds.contains(p) { self.state.peek = false }
                }
                return e
            }
        } else if !on, let m = outside {
            NSEvent.removeMonitor(m)
            outside = nil
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        self.collapsed = collapsed
        if !collapsed { state.peek = false }
        height?.constant = RibbonView.height(collapsed: collapsed && !state.peek)
        top?.constant = RibbonView.height(collapsed: collapsed)
    }

    /// Give the split view back, for the Mac layout.
    func release() {
        state.peek = false
        split.view.removeFromSuperview()
        split.removeFromParent()
    }
}

@MainActor
enum RibbonFeature {
    static func install(_ app: AppController) {
        RibbonModel.inspector = InspectorFeature.controller
        app.inspect("ribbon") { inspect(app.model) }
        // F6: the keyboard goes to the shown tab in the tab row (§6).
        app.handle(["view.focusRibbon"]) { p in
            guard let window = AppControlHost.keyDocumentWindow(), let wc = window.windowController as? DocumentWindowController,
                  let a = wc.ribbon else { return .failure("the window has no ribbon: View › Ribbon shows it") }
            guard NSApp.isFullKeyboardAccessEnabled else {
                return .failure("the ribbon takes the keyboard with Keyboard Navigation on (System Settings › Keyboard)")
            }
            window.makeFirstResponder(a.container.host)
            a.container.state.focusRequest = p["place"]?.asStr ?? "tab:" + RibbonModel.selected(app.model).id
            return .success(.null)
        }
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

    /// `ui.inspect`'s `ribbon`: the model's answer, and from the key window's ribbon (R3) its width, each group's
    /// fitted size, the tabs in "»", whether it scrolls, the transient panel, keyboard focus, and `truncated`: every
    /// control drawn clipped, overlapping another, or with a label too long for its two lines; empty when the tab
    /// lays out cleanly.
    static func inspect(_ model: AppModel) -> JSON {
        let base = RibbonModel.inspect(model)
        guard case .object(var o) = base, let window = AppControlHost.keyDocumentWindow(),
              let wc = window.windowController as? DocumentWindowController, let a = wc.ribbon else { return base }
        let st = a.container.state
        let tab = RibbonModel.selected(model)
        let fit = RibbonMeasure.fit(tab, model, width: st.width)
        let groups: [JSON] = (o["groups"]?.asArray ?? []).map { g in
            guard case .object(var go) = g else { return g }
            let size = (go["id"]?.asStr).flatMap { fit.sizes[$0] } ?? .large
            go.set("size", .string(size.rawValue))
            return .object(go)
        }
        o.set("groups", .array(groups))
        o.set("width", .double(Double(st.width)))
        o.set("scrolling", .bool(!fit.fits))
        o.set("peek", .bool(st.peek))
        o.set("focus", st.focus.map(JSON.string) ?? .null)
        // Buttons take the keyboard only with Full Keyboard Access on (System Settings › Keyboard).
        o.set("fullKeyboardAccess", .bool(NSApp.isFullKeyboardAccessEnabled))
        o.set("keyWindow", .bool(window.isKeyWindow))
        o.set("firstResponder", .string(window.firstResponder.map { String(describing: type(of: $0)) } ?? ""))
        o.set("tabsShown", .array(st.tabsShown.map(JSON.string)))
        o.set("tabsOverflow", .array(st.tabsOverflow.map(JSON.string)))
        // Each shown tab's rectangle in `ui.click`'s coordinates (the content view, from its top left).
        var rects = JSONObject()
        if let cv = window.contentView {
            for id in st.tabsShown {
                guard let f = st.tabFrames[id] else { continue }
                let r = a.container.host.convert(f, to: cv)
                let top = cv.isFlipped ? r.minY : cv.bounds.height - r.maxY
                rects.set(id, [.double(Double(r.minX)), .double(Double(top)), .double(Double(r.width)), .double(Double(r.height))])
            }
        }
        o.set("tabRects", .object(rects))
        o.set("truncated", .array(truncated(tab, fit, st, body: !model.ui.ribbonCollapsed || st.peek).map(JSON.string)))
        return .object(o)
    }

    /// What `inspect` reports as `truncated`, each with the reason in brackets.
    static func truncated(_ tab: RibbonTab, _ fit: RibbonFit.Fit, _ st: RibbonViewState, body: Bool) -> [String] {
        var out: [String] = []
        let width = st.width
        for id in st.tabsShown {
            if let f = st.tabFrames[id], f.maxX > width + 0.5 { out.append("tab:\(id) (width)") }
        }
        guard body else { return out }
        var drawn: [(String, CGRect)] = []
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        /// Whether `text` needs more than two lines of the caption font at `width`.
        func overflows(_ text: String, _ width: Double) -> Bool {
            let h = (text as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: caption]).height
            return h > ceil(caption.boundingRectForFont.height * 2) + 1
        }
        for g in tab.groups {
            let gs = fit.sizes[g.id] ?? .large
            if gs == .collapsed {
                if let f = st.frames[g.id] { drawn.append((g.id, f)) } else { out.append("\(g.id) (not drawn)") }
                if overflows(g.title, RibbonModel.collapsedLabelWidth) { out.append("\(g.id) (label)") }
                continue
            }
            for c in g.controls {
                guard let f = st.frames[c.id] else {
                    out.append("\(c.id) (not drawn)")
                    continue
                }
                drawn.append((c.id, f))
                if RibbonFit.size(c, gs) == .large, overflows(RibbonModel.label(c), RibbonModel.largeLabelWidth) { out.append("\(c.id) (label)") }
            }
        }
        let top = RibbonView.tabHeight, bottom = RibbonView.tabHeight + RibbonView.bodyHeight
        for (id, f) in drawn {
            if f.minY < top - 0.5 || f.maxY > bottom + 0.5 { out.append("\(id) (height)") }
            if fit.fits, f.minX < -0.5 || f.maxX > width + 0.5 { out.append("\(id) (width)") }
        }
        for (i, (a, fa)) in drawn.enumerated() {
            for (b, fb) in drawn[(i + 1)...] where fa.insetBy(dx: 0.5, dy: 0.5).intersects(fb.insetBy(dx: 0.5, dy: 0.5)) {
                out.append("\(a) (overlaps \(b))")
            }
        }
        return out
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
