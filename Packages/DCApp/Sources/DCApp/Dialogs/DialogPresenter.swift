// DCApp — shows the open dialog the Mac way: a sheet on the document window (non-blocking, so a
// control-channel command that opens one answers at once), or a window of its own for Settings, About and
// the template gallery; plus the command palette, the toast, and the file panels the dialogs ask for.
// Replaces `dialogs::show`, `menus::palette` and `toast::show` in deckcraft `crates/ui-egui` and the `rfd`
// pickers of `apps/deckcraft/src/main.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DesignScaffold
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DialogPresenter: NSObject, NSWindowDelegate, DialogServices {
    let controller: DialogController
    /// The dialog on screen: its generation, its window and the window it is a sheet on.
    private var shown: (generation: UInt64, window: NSWindow, parent: NSWindow?)?
    private(set) var palettePanel: NSPanel?
    private var toastPanel: NSPanel?
    private var toastTimer: Timer?

    init(controller: DialogController) {
        self.controller = controller
        super.init()
    }

    /// The document window a sheet goes on: the key one, else the active presentation's.
    static func documentWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, w.windowController is DocumentWindowController { return w }
        if let w = NSApp.mainWindow, w.windowController is DocumentWindowController { return w }
        return AppController.shared?.currentDocument?.windowControllers.first?.window
    }

    // MARK: Dialogs

    /// Show what the controller has open (called after every open and close).
    func sync() {
        guard let d = controller.current else {
            dismiss()
            return
        }
        if let s = shown, s.generation == controller.generation { return }
        dismiss()
        let host = NSHostingController(rootView: DialogView(controller: controller))
        host.sizingOptions = [.preferredContentSize]
        let parent = DialogCatalog.isWindow(d.id) ? nil : Self.documentWindow()
        if let parent {
            let sheet = NSWindow(contentViewController: host)
            sheet.title = controller.title
            parent.beginSheet(sheet)
            shown = (controller.generation, sheet, parent)
        } else {
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = controller.title
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.makeKeyAndOrderFront(nil)
            shown = (controller.generation, w, nil)
        }
    }

    private func dismiss() {
        guard let s = shown else { return }
        shown = nil
        if let parent = s.parent {
            parent.endSheet(s.window)
        } else {
            s.window.delegate = nil
            s.window.close()
        }
    }

    /// The window's close button is the same as Cancel (`show`: Esc or the close button).
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, shown?.window === w else { return }
        shown = nil
        controller.cancel()
    }

    // MARK: Palette

    func syncPalette() {
        if controller.palette == nil {
            palettePanel?.orderOut(nil)
            palettePanel = nil
            return
        }
        guard palettePanel == nil else { return }
        let host = NSHostingController(rootView: PaletteView(controller: controller))
        host.sizingOptions = [.preferredContentSize]
        let panel = PalettePanel(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // NSPanel hides when the app is inactive by default; the palette closes when it loses the keyboard instead.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onResign = { [weak self] in self?.controller.palette = nil; self?.syncPalette() }
        if let w = Self.documentWindow() {
            let f = w.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - Tokens.Layout.rowHeight * 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        palettePanel = panel
    }

    // MARK: Toast

    func syncToast() {
        guard let toast = controller.freshToast() else {
            toastPanel?.orderOut(nil)
            toastPanel = nil
            return
        }
        guard toastPanel == nil, let w = Self.documentWindow() else { return }
        let host = NSHostingController(rootView: ToastView(text: toast.text) { [weak self] in
            self?.controller.toast = nil
            self?.syncToast()
        })
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let size = host.view.fittingSize
        panel.setFrame(NSRect(x: w.frame.midX - size.width / 2, y: w.frame.minY + Tokens.Space.xxl, width: size.width, height: size.height), display: true)
        w.addChildWindow(panel, ordered: .above)
        toastPanel = panel
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: Toast.showSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.toast = nil
                self?.syncToast()
            }
        }
    }

    // MARK: DialogServices

    /// The file types deckcraft's pickers offer for each purpose.
    static func extensions(_ purpose: String) -> [String] {
        switch purpose {
        case "picture": ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "svg", "heic", "emf", "wmf"]
        case "audio": ["wav", "mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus", "aif", "aiff", "aifc", "caf", "wma", "weba", "mka"]
        case "video": ["mp4", "m4v", "mov", "webm", "mkv", "wmv"]
        case "theme": ["thmx", "pptx", "potx", "ppsx"]
        default: ["deckcraft", "pptx", "potx", "ppsx", "txt", "md"]
        }
    }

    static func types(_ exts: [String]) -> [UTType] {
        exts.compactMap { UTType(filenameExtension: $0) }
    }

    func pickOpen(_ purpose: String, _ done: @escaping @MainActor (String?) -> Void) {
        // After the current event: a dialog's sheet closes before the panel takes its place.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.allowedContentTypes = Self.types(Self.extensions(purpose))
                let finish: (NSApplication.ModalResponse) -> Void = { r in done(r == .OK ? panel.url?.path : nil) }
                if let w = Self.documentWindow() { panel.beginSheetModal(for: w, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
            }
        }
    }

    func pickSave(_ name: String, _ done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                let ext = (name as NSString).pathExtension
                if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
                let finish: (NSApplication.ModalResponse) -> Void = { r in done(r == .OK ? panel.url?.path : nil) }
                if let w = Self.documentWindow() { panel.beginSheetModal(for: w, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
            }
        }
    }

    func openURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The palette's panel: it closes when it loses the keyboard, as a popover does.
final class PalettePanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// ⇧⌘P: search every command by name and run it (`menus::palette`).
struct PaletteView: View {
    let controller: DialogController
    @FocusState private var focused: Bool

    var body: some View {
        let selection = controller.palette?.selection ?? 0
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            TextField("Search commands…", text: Binding(
                get: { controller.palette?.query ?? "" },
                set: { q in
                    controller.palette?.query = q
                    controller.palette?.selection = 0
                }
            ))
            .textFieldStyle(.plain)
            .font(Tokens.Font.panelTitle)
            .focused($focused)
            .onSubmit { controller.paletteRun() }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.paletteItems.enumerated()), id: \.offset) { k, item in
                            Button { controller.paletteRun(item.id) } label: {
                                HStack {
                                    Text(item.label)
                                    Spacer()
                                    if let s = item.shortcut { Text(Self.pretty(s)).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.tertiaryLabel) }
                                }
                                .padding(.horizontal, Tokens.Space.s)
                                .padding(.vertical, Tokens.Space.xs)
                                .background(k == selection ? Tokens.Color.selectionWash : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(k)
                        }
                    }
                }
                .onChange(of: selection) { _, s in proxy.scrollTo(s) }
            }
            .frame(height: Tokens.Layout.rowHeight * 8)
        }
        .padding(Tokens.Space.m)
        .frame(width: Tokens.Layout.inspectorWidth * 1.6)
        .onKeyPress(.downArrow) { controller.paletteMove(1); return .handled }
        .onKeyPress(.upArrow) { controller.paletteMove(-1); return .handled }
        .onKeyPress(.escape) { controller.palette = nil; return .handled }
        .onAppear { focused = true }
    }
}

extension PaletteView {
    /// `pretty_shortcut`: "Cmd+Shift+N" as the Mac writes it, "⇧⌘N".
    static func pretty(_ s: String) -> String {
        guard let k = Shortcut(s) else { return s }
        return (k.ctrl ? "⌃" : "") + (k.alt ? "⌥" : "") + (k.shift ? "⇧" : "") + (k.cmd ? "⌘" : "") + k.key.uppercased()
    }
}

/// A brief notice over the bottom of the window (`toast::show`).
struct ToastView: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s) {
            Text(text).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.Color.secondaryLabel)
                .help("Close")
                .accessibilityLabel("Close")
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: Tokens.Layout.inspectorWidth * 1.5)
        .cardSurface()
    }
}
