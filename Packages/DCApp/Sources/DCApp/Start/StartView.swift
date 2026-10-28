// DCApp — the start window's content: a sidebar of Home, New and Open, the search field in the toolbar, the
// tiles (rendered, not drawn) and the recent list, and Cancel with Create or Open at the bottom. Its content is
// deckcraft's File › Home, New and Open pages (`crates/ui-egui/src/backstage/files.rs`, MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors); its shape is a Mac window (Docs/plans/Ribbon-and-StartScreen.md §7).
import AppKit
import DCAppModel
import SwiftUI

struct StartView: View {
    @Bindable var model: StartScreenModel
    let art: StartArt
    @FocusState private var searchFocused: Bool
    @FocusState private var contentFocused: Bool
    /// Tiles a row holds on the New page, for ↑ and ↓.
    @State private var columns = 4

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
                ForEach(StartScreenModel.Page.allCases, id: \.self) { p in
                    Label(Self.title(p), systemImage: Self.symbol(p)).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    page
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($contentFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let row = model.page == .new ? columns : 1
                    switch press.key {
                    case .leftArrow: model.move(-1)
                    case .rightArrow: model.move(1)
                    case .upArrow: model.move(-row)
                    default: model.move(row)
                    }
                    return .handled
                }
                Divider()
                buttons
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text(Self.searchPrompt(model.page)))
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocus) { searchFocused = true }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder var page: some View {
        switch model.page {
        case .home: home
        case .new: newPage
        case .open: openPage
        }
    }

    // MARK: Pages

    var home: some View {
        VStack(alignment: .leading, spacing: 22) {
            section(String(localized: "New", bundle: .module, comment: "Start window: the heading over the new-presentation tiles"),
                    more: String(localized: "More themes", bundle: .module, comment: "Start window: link to the New page")) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) { ForEach(model.themeTiles) { tile($0) } }.padding(.bottom, 6)
                }
            }
            if !model.templateTiles.isEmpty {
                section(String(localized: "Templates", bundle: .module, comment: "Start window: the heading over the starter templates"),
                        more: String(localized: "More templates", bundle: .module, comment: "Start window: link to the New page")) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) { ForEach(model.templateTiles) { tile($0) } }.padding(.bottom, 6)
                    }
                }
            }
            heading(String(localized: "Recent", bundle: .module, comment: "Start window: the heading over the recent presentations"))
            recentList
        }
    }

    var newPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            let themes = model.themeTiles, templates = model.templateTiles
            if themes.isEmpty && templates.isEmpty {
                Text(String(localized: "No themes or templates match “\(String(model.query.trimmingCharacters(in: .whitespaces)))”.", bundle: .module, comment: "Start window: an empty search; the placeholder is the search text"))
                    .foregroundStyle(.secondary)
            }
            if !themes.isEmpty {
                heading(String(localized: "Themes", bundle: .module, comment: "Start window: the heading over the theme tiles"))
                grid(themes)
            }
            if !templates.isEmpty {
                heading(String(localized: "Templates", bundle: .module, comment: "Start window: the heading over the starter templates"))
                grid(templates)
            }
        }
        .onGeometryChange(for: Int.self) { max(1, Int(($0.size.width + 12) / (Self.tileSize.width + 12))) } action: { columns = $0 }
    }

    var openPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button {
                    NSDocumentController.shared.openDocument(nil)
                } label: {
                    Label(String(localized: "Open…", bundle: .module, comment: "Start window: opens the system Open panel"), systemImage: "folder")
                }
                if model.recoverable {
                    Button(String(localized: "Recover Unsaved Presentations", bundle: .module, comment: "Start window: opens AutoRecover's presentations")) {
                        model.model.run("file.recovery.open")
                    }
                }
            }
            .controlSize(.large)
            heading(String(localized: "Presentations", bundle: .module, comment: "Start window: the heading over the recent list on the Open page"))
            recentList
        }
    }

    // MARK: Parts

    func heading(_ text: String) -> some View {
        Text(text).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    func section(_ title: String, more: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                heading(title)
                Spacer()
                Button(more) { model.page = .new }.buttonStyle(.link)
            }
            content()
        }
    }

    nonisolated static let tileSize = CGSize(width: 192, height: 108)

    func grid(_ tiles: [StartTile]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize.width, maximum: Self.tileSize.width), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(tiles) { tile($0) }
        }
    }

    func tile(_ t: StartTile) -> some View {
        let selected = model.selection == t.id
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternarySystemFill))
                if let img = art.tile(t.id) {
                    Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 3 : 1).padding(selected ? -3 : 0))
            Text(t.title).font(.callout).lineLimit(2).multilineTextAlignment(.center).frame(width: Self.tileSize.width)
        }
        .contentShape(Rectangle())
        .help(t.detail ?? t.title)
        .onTapGesture(count: 2) { model.activate(t.id) }
        .onTapGesture {
            model.selection = t.id
            contentFocused = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.title)
        .accessibilityHint(t.detail ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.activate(t.id) }
    }

    @ViewBuilder var recentList: some View {
        let rows = model.recents
        if model.recentPaths.isEmpty {
            Text(String(localized: "Presentations you open show up here. Use Open to browse for one.", bundle: .module, comment: "Start window: the empty recent list"))
                .foregroundStyle(.secondary)
        } else if rows.isEmpty {
            Text(String(localized: "No recent presentations match “\(String(model.query.trimmingCharacters(in: .whitespaces)))”.", bundle: .module, comment: "Start window: an empty search of the recent list; the placeholder is the search text"))
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 2) { ForEach(rows) { recentRow($0) } }
        }
    }

    func recentRow(_ r: StartRecent) -> some View {
        let selected = model.selection == r.id
        return HStack(spacing: 12) {
            Group {
                if !r.missing, let img = art.thumbnail(r.path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.name).foregroundStyle(r.missing ? .secondary : .primary)
                Text(verbatim: r.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if r.missing {
                Text(String(localized: "(missing)", bundle: .module, comment: "Start window: a recent file that can't be found")).font(.caption).foregroundStyle(.secondary)
            } else {
                StartLastOpened(path: r.path)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .help(r.missing ? String(localized: "\(r.path) — this file can't be found", bundle: .module, comment: "Start window: tooltip of a missing recent file; the placeholder is its path") : r.path)
        .onTapGesture(count: 2) { model.activate(r.id) }
        .onTapGesture {
            model.selection = r.id
            contentFocused = true
        }
        .contextMenu {
            if !r.missing {
                Button(String(localized: "Show in Finder", bundle: .module, comment: "Start window: a recent file's context menu")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: r.path)])
                }
                ShareLink(item: URL(filePath: r.path)) { Text(String(localized: "Share…", bundle: .module, comment: "Start window: a recent file's context menu")) }
                Divider()
            }
            Button(String(localized: "Remove from List", bundle: .module, comment: "Start window: a recent file's context menu")) { model.remove(r.path) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.activate(r.id) }
    }

    var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel", bundle: .module)) { model.close() }.keyboardShortcut(.cancelAction)
            Button(model.action != .create ? String(localized: "Open", bundle: .module, comment: "Start window: opens the selected recent presentation")
                : String(localized: "Create", bundle: .module, comment: "Start window: creates the selected presentation")) {
                model.activate()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.action == .none)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Text

    static func title(_ p: StartScreenModel.Page) -> String {
        switch p {
        case .home: String(localized: "Home", bundle: .module, comment: "Start window sidebar: the start page")
        case .new: String(localized: "New", bundle: .module, comment: "Start window sidebar: every theme and template")
        case .open: String(localized: "Open", bundle: .module, comment: "Start window sidebar: open a file")
        }
    }

    static func symbol(_ p: StartScreenModel.Page) -> String {
        switch p {
        case .home: "house"
        case .new: "plus.square.on.square"
        case .open: "folder"
        }
    }

    static func searchPrompt(_ p: StartScreenModel.Page) -> String {
        switch p {
        case .new: String(localized: "Search for themes and templates", bundle: .module)
        default: String(localized: "Search", bundle: .module)
        }
    }
}

/// "Last opened" for a recent row, from the file's access date, relative to now.
struct StartLastOpened: View {
    let path: String
    @State private var date: Date?

    var body: some View {
        Group {
            if let date { Text(date, format: .relative(presentation: .named)) } else { Text(verbatim: "") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: path) {
            date = try? URL(filePath: path).resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        }
    }
}
