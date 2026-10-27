// DCApp — the Software Update window: checking, up to date, a newer release with its notes, the download and
// its progress, and the downloaded DMG. A window of its own rather than a sheet (there may be no document
// window, and a check must never block one), non-modal, as Mac apps show updates. Replaces craft-update's egui
// `StartupPrompt` (storytold/craft-libs @495e5971, `crates/update/src/dialog.rs`; MIT OR Apache-2.0,
// © ArtCraft Team and the Craft contributors).
import AppKit
import DCAppModel
import DesignScaffold
import SwiftUI

@MainActor
final class UpdatesWindowController: NSWindowController, NSWindowDelegate {
    let center: UpdateCenter

    init(center: UpdateCenter) {
        self.center = center
        let host = NSHostingController(rootView: UpdatesView(center: center, close: {}))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = String(localized: "Software Update", bundle: .module)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        host.rootView = UpdatesView(center: center, close: { [weak self] in self?.close() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    /// Closing the window is "Later": the outcome is forgotten (a download carries on).
    func windowWillClose(_ notification: Notification) { center.dismiss() }
}

struct UpdatesView: View {
    @Bindable var center: UpdateCenter
    let close: () -> Void

    static let width = Tokens.Layout.inspectorWidth * 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: Tokens.Space.xxl * 2, height: Tokens.Space.xxl * 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(headline).font(Tokens.Font.panelTitle)
                    if let detail {
                        Text(detail).font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            Toggle(String(localized: "Check for updates automatically every day", bundle: .module), isOn: $center.checksAutomatically)
                .toggleStyle(.checkbox)
            Divider()
            HStack(spacing: Tokens.Space.s) {
                Spacer(minLength: Tokens.Space.s)
                buttons
            }
        }
        .padding(Tokens.Space.l)
        .frame(width: Self.width)
        .font(Tokens.Font.body)
    }

    private var current: String { center.checker.currentVersion }

    private var headline: String {
        switch center.phase {
        case .idle, .checking: String(localized: "Checking for updates…", bundle: .module)
        case .upToDate: String(localized: "You're up to date", bundle: .module)
        case .failed: String(localized: "Couldn't check for updates", bundle: .module)
        case .available(let r): String(localized: "DeckCraftNative \(r.versionLabel) is available", bundle: .module)
        case .downloading(let r): String(localized: "Downloading DeckCraftNative \(r.versionLabel)…", bundle: .module)
        case .downloaded(let r, _): String(localized: "DeckCraftNative \(r.versionLabel) is ready", bundle: .module)
        case .downloadFailed: String(localized: "The download didn't finish", bundle: .module)
        }
    }

    private var detail: String? {
        switch center.phase {
        case .idle, .checking:
            nil
        case .upToDate(let v):
            String(localized: "DeckCraftNative \(v) is the newest version.", bundle: .module)
        case .failed(let e), .downloadFailed(_, let e):
            e.message
        case .available(let r):
            r.installer == nil
                ? String(localized: "You have \(current). This release has no disk image; its page has the details.", bundle: .module)
                : String(localized: "You have \(current).", bundle: .module)
        case .downloading:
            nil
        case .downloaded(_, let file):
            String(localized: "\(file.lastPathComponent) is open in Finder. Quit DeckCraftNative, then drag the new version onto Applications to replace this one.", bundle: .module)
        }
    }

    @ViewBuilder private var content: some View {
        switch center.phase {
        case .idle, .checking:
            ProgressView().progressViewStyle(.linear)
        case .available(let r):
            notes(r)
        case .downloading:
            if let p = center.progress { ProgressView(p) } else { ProgressView().progressViewStyle(.linear) }
        default:
            EmptyView()
        }
    }

    /// The release notes: Markdown's inline styles; links open in the browser only when they're https.
    private func notes(_ r: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                Text(r.name).font(Tokens.Font.sectionTitle)
                Spacer()
                if let date = r.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            ScrollView {
                Text(Self.attributed(r.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(Tokens.Space.s)
            }
            .frame(height: Tokens.Layout.rowHeight * 5)
            .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "https" else { return .discarded }
                return .systemAction(url)
            })
        }
    }

    static func attributed(_ markdown: String) -> AttributedString {
        if markdown.isEmpty { return AttributedString(String(localized: "No release notes.", bundle: .module)) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    @ViewBuilder private var buttons: some View {
        switch center.phase {
        case .idle, .checking:
            Button(String(localized: "Cancel", bundle: .module), action: close).keyboardShortcut(.cancelAction)
        case .upToDate:
            Button(String(localized: "OK", bundle: .module), action: close).keyboardShortcut(.defaultAction)
        case .failed:
            Button(String(localized: "Close", bundle: .module), action: close).keyboardShortcut(.cancelAction)
            Button(String(localized: "Try Again", bundle: .module)) { center.checkNow() }.keyboardShortcut(.defaultAction)
        case .available(let r):
            Button(String(localized: "Skip This Version", bundle: .module)) {
                center.skip()
                close()
            }
            Button(String(localized: "Later", bundle: .module), action: close).keyboardShortcut(.cancelAction)
            if r.installer != nil {
                Button(String(localized: "Download", bundle: .module)) { center.downloadUpdate() }.keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "Open Release Page", bundle: .module)) {
                    NSWorkspace.shared.open(r.page)
                    close()
                }.keyboardShortcut(.defaultAction)
            }
        case .downloading:
            Button(String(localized: "Cancel", bundle: .module)) { center.cancelDownload() }.keyboardShortcut(.cancelAction)
        case .downloaded(_, let file):
            Button(String(localized: "Show in Finder", bundle: .module)) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            Button(String(localized: "Done", bundle: .module), action: close).keyboardShortcut(.defaultAction)
        case .downloadFailed:
            Button(String(localized: "Close", bundle: .module), action: close).keyboardShortcut(.cancelAction)
            Button(String(localized: "Try Again", bundle: .module)) { center.retryDownload() }.keyboardShortcut(.defaultAction)
        }
    }
}
