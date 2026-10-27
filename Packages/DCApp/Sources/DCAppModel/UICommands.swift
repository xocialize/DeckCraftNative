// DCAppModel — the UI-only commands and the command palette. Port of `UI_COMMANDS` in deckcraft
// `crates/ui-egui/src/lib.rs` and `palette_items` in `crates/ui-egui/src/menus.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine

/// A command the UI handles itself (views, panes, zoom, the show, dialogs) rather than the engine.
public struct UICommand: Sendable, Equatable {
    public var id: String
    public var label: String
    public var shortcut: String?
    public var params: String
}

public enum UICommands {
    /// `UI_COMMANDS`: id, label, shortcut, params — in deckcraft's order.
    public static let all: [UICommand] = [
        .init(id: "view.normal", label: "Normal", shortcut: nil, params: "{}"),
        .init(id: "view.outline", label: "Outline View", shortcut: nil, params: "{}"),
        .init(id: "view.sorter", label: "Slide Sorter", shortcut: nil, params: "{}"),
        .init(id: "view.notesPage", label: "Notes Page", shortcut: nil, params: "{}"),
        .init(id: "view.reading", label: "Reading View", shortcut: nil, params: "{}"),
        .init(id: "view.notes", label: "Notes", shortcut: nil, params: "{on?: bool}"),
        .init(id: "view.ruler", label: "Ruler", shortcut: nil, params: "{on?: bool}"),
        .init(id: "view.gridlines", label: "Gridlines", shortcut: "Shift+F9", params: "{on?: bool}"),
        .init(id: "view.guides", label: "Guides", shortcut: "Alt+F9", params: "{on?: bool}"),
        .init(id: "view.gridOptions", label: "Grid Options…", shortcut: nil, params: "{spacing?: pt, snap?: bool, smartGuides?: bool, gridlines?: bool, guides?: bool}"),
        .init(id: "view.zoomIn", label: "Zoom In", shortcut: "Cmd+=", params: "{}"),
        .init(id: "view.zoomOut", label: "Zoom Out", shortcut: "Cmd+-", params: "{}"),
        .init(id: "view.zoom", label: "Set Zoom", shortcut: nil, params: "{percent}"),
        .init(id: "view.zoomDialog", label: "Zoom…", shortcut: nil, params: "{}"),
        .init(id: "view.fit", label: "Fit to Window", shortcut: nil, params: "{}"),
        .init(id: "view.pane", label: "Task Pane", shortcut: nil, params: "{pane: format|animation|selection|comments|designer|background|smartart|null}"),
        .init(id: "review.thesaurusPane", label: "Thesaurus", shortcut: "Shift+F7", params: "{word?}: open the Thesaurus pane on the selected word"),
        .init(id: "view.tab", label: "Ribbon Tab", shortcut: nil, params: "{tab}"),
        .init(id: "view.collapseRibbon", label: "Collapse the Ribbon", shortcut: "Cmd+F1", params: "{}"),
        .init(id: "view.dark", label: "Dark Mode", shortcut: nil, params: "{on?: bool}"),
        .init(id: "view.grayscale", label: "Grayscale", shortcut: nil, params: "{on?: bool}"),
        .init(id: "view.newWindow", label: "New Window", shortcut: nil, params: "{on?: bool, slide?: index, delta?: int}"),
        .init(id: "show.start", label: "Slide Show", shortcut: "F5", params: "{from?: index, custom?: name}"),
        .init(id: "show.presenter", label: "Presenter View", shortcut: nil, params: "{on?: bool}"),
        .init(id: "show.end", label: "End Show", shortcut: nil, params: "{}"),
        .init(id: "animation.preview", label: "Preview Animations", shortcut: nil, params: "{on?: bool, from?: effect index}"),
        .init(id: "app.home", label: "Home", shortcut: nil, params: "{on?}"),
        .init(id: "app.backstage", label: "File", shortcut: "Alt+F", params: "{page?: home|new|open|info|saveAs|print|export|account, on?: bool}"),
        .init(id: "app.closePresentation", label: "Close", shortcut: "Cmd+W", params: "{}"),
        .init(
            id: "app.print", label: "Print", shortcut: "Cmd+P",
            params: "{layout?, perPage?, slides?, includeHidden?, frame?, paper?: letter|a4|legal|a3, orientation?: portrait|landscape}"
        ),
        .init(id: "app.about", label: "About DeckCraft", shortcut: nil, params: "{}"),
        .init(id: "app.checkUpdates", label: "Check for Updates…", shortcut: nil, params: "{}"),
        .init(id: "app.palette", label: "Command Palette", shortcut: "Cmd+Shift+P", params: "{}"),
        .init(id: "app.preferences", label: "Preferences…", shortcut: "Cmd+,", params: "{}"),
        .init(id: "app.openDialog", label: "Open…", shortcut: nil, params: "{purpose?}"),
        .init(id: "app.insertPictureDialog", label: "Picture from File…", shortcut: nil, params: "{}"),
        .init(id: "app.smartArtPictureDialog", label: "Insert Picture in SmartArt…", shortcut: nil, params: "{id?, index}"),
        .init(id: "app.changePictureDialog", label: "Change Picture…", shortcut: nil, params: "{}"),
        .init(id: "app.insertAudioDialog", label: "Audio from File…", shortcut: nil, params: "{}"),
        .init(id: "app.reuseSlidesDialog", label: "Reuse Slides…", shortcut: nil, params: "{keepFormatting?: bool}"),
        .init(id: "app.insertVideoDialog", label: "Video from File…", shortcut: nil, params: "{}"),
        .init(id: "app.saveAsDialog", label: "Save As…", shortcut: nil, params: "{}"),
        .init(id: "app.exportDialog", label: "Export…", shortcut: nil, params: "{}"),
        .init(id: "app.browseThemeDialog", label: "Browse for Themes…", shortcut: nil, params: "{}"),
        .init(id: "app.compareDialog", label: "Compare…", shortcut: nil, params: "{}"),
        .init(id: "app.dialog", label: "Open Dialog", shortcut: nil, params: "{id}"),
        .init(id: "app.pasteSpecial", label: "Paste Special…", shortcut: "Cmd+Alt+V", params: "{}"),
        .init(
            id: "app.qat", label: "Quick Access Toolbar", shortcut: nil,
            params: "{add: command id, params?, label?, icon?} | {remove: id, params?} | {reset: true} → [buttons]"
        ),
        .init(id: "app.find", label: "Find…", shortcut: "Cmd+F", params: "{}"),
        .init(id: "app.replace", label: "Replace…", shortcut: "Cmd+H", params: "{}"),
        .init(id: "app.links", label: "Community Links", shortcut: nil, params: "{}"),
    ]

    public static func find(_ id: String) -> UICommand? { all.first { $0.id == id } }
    public static func contains(_ id: String) -> Bool { find(id) != nil }
}

/// One command palette entry.
public struct PaletteItem: Sendable, Equatable {
    public var id: String
    public var label: String
    public var shortcut: String?
}

public enum Palette {
    /// `palette_items`: the palette's entries for query `q` (any case). Engine commands that are disabled,
    /// that need arguments the palette can't give, or whose label a UI command also has (Open…, Save As…,
    /// Export…, Audio/Video from File…: the UI command opens the dialog) are left out. Entries whose label
    /// starts with the query come first; at most 60.
    public static func items(_ session: Session, _ query: String) -> [PaletteItem] {
        let q = query.lowercased()
        let uiLabels = Set(UICommands.all.map(\.label))
        var items: [PaletteItem] = session.commands()
            .filter { $0.enabled && !uiLabels.contains($0.label) && !Cmd.needsArguments($0.params) }
            .map { PaletteItem(id: $0.id, label: $0.label, shortcut: $0.shortcut) }
        items += UICommands.all.filter { !Cmd.needsArguments($0.params) }.map { PaletteItem(id: $0.id, label: $0.label, shortcut: $0.shortcut) }
        items = items.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        // A stable sort on "doesn't start with the query", as `sort_by_key` is.
        let starts = items.filter { $0.label.lowercased().hasPrefix(q) }
        let rest = items.filter { !$0.label.lowercased().hasPrefix(q) }
        return Array((starts + rest).prefix(60))
    }
}
