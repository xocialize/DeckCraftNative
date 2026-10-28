// DCAppModel — the SF Symbol for a command, in one table for the toolbar, the Quick Access Toolbar and the ribbon
// (Docs/plans/Ribbon-and-StartScreen.md §4). The icons are Apple's SF Symbols, chosen for what the command does;
// none is drawn to look like another product's. deckcraft's own icon names (`qat.rs`' `QatItem.icon`) map here too.

public enum CommandSymbols {
    /// By command id, or by `id:<id param>` / `id:<pane param>` where one command opens many things
    /// (`app.dialog {id: smartart}`, `view.pane {pane: designer}`).
    static let table: [String: String] = [
        "slide.new": "plus.rectangle.on.rectangle",
        "shape.insert": "square.on.circle",
        "insert.textBox": "textformat",
        "insert.table": "tablecells",
        "insert.chart": "chart.bar",
        "app.dialog:smartart": "rectangle.3.group",
        "app.insertPictureDialog": "photo",
        "app.insertVideoDialog": "play.rectangle",
        "app.dialog:comment": "text.bubble",
        "show.start": "play.fill",
    ]

    /// The symbol for a command with these parameters, if it has one.
    public static func symbol(_ c: CommandRef) -> String? {
        if let sub = c.params["id"]?.asStr ?? c.params["pane"]?.asStr, let s = table["\(c.id):\(sub)"] { return s }
        return table[c.id]
    }

    /// deckcraft's QAT icon names as SF Symbols.
    public static func symbol(icon: String) -> String {
        switch icon {
        case "home": "house"
        case "file": "doc"
        case "folder": "folder"
        case "save": "square.and.arrow.down"
        case "print": "printer"
        case "undo": "arrow.uturn.backward"
        case "redo": "arrow.uturn.forward"
        case "playFromStart": "play.rectangle"
        case "search": "magnifyingglass"
        case "spelling": "textformat.abc.dottedunderline"
        case "export": "square.and.arrow.up"
        case "table": "tablecells"
        case "chart": "chart.bar"
        case "picture": "photo"
        default: "ellipsis.circle"
        }
    }
}
