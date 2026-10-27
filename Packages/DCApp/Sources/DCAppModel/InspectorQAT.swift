// DCAppModel — the Quick Access Toolbar's buttons and `app.qat`. Port of deckcraft
// `crates/ui-egui/src/qat.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). On the Mac
// the title bar's Quick Access Toolbar becomes the window toolbar's customisable items: these buttons are
// toolbar items, and `app.qat` adds and removes them.
import DCCore
import DCEngine
import Foundation

/// One toolbar button: a command, its parameters, and how it looks (`QatItem`).
public struct QatItem: Sendable, Equatable, Codable {
    public var id: String
    /// The command's parameters, as JSON text (nil for none).
    public var params: String?
    public var label: String
    /// deckcraft's icon name (the app shows the matching SF Symbol).
    public var icon: String

    public init(id: String, params: JSON = .null, label: String, icon: String) {
        self.id = id
        self.params = params.isNull ? nil : params.display
        self.label = label
        self.icon = icon
    }

    /// The parameters to run the command with.
    public var paramsJSON: JSON {
        guard let p = params, let v = try? JSONParser.parse(p) else { return .null }
        return v
    }

    /// `same`: the same command and parameters (absent parameters equal an empty object).
    public func same(_ id: String, _ params: JSON) -> Bool {
        let mine = paramsJSON
        let empty = params.asObject?.entries.isEmpty ?? false
        return self.id == id && (mine.canonical == params.canonical || (mine.isNull && (params.isNull || empty)))
    }

    /// The toolbar item identifier: the command id, with its parameters when it has any.
    public var identifier: String { params.map { "\(id) \($0)" } ?? id }

    public func toJSON() -> JSON {
        var o: JSON = ["id": .string(id), "label": .string(label), "icon": .string(icon)]
        if params != nil { o.set("params", paramsJSON) }
        return o
    }
}

public enum QAT {
    /// `common`: the commands the Customize menu offers, in PowerPoint's order.
    public static let common: [QatItem] = [
        QatItem(id: "app.home", label: "Home", icon: "home"),
        QatItem(id: "file.new", label: "New", icon: "file"),
        QatItem(id: "app.openDialog", label: "Open", icon: "folder"),
        QatItem(id: "file.save", label: "Save", icon: "save"),
        QatItem(id: "app.print", label: "Print", icon: "print"),
        QatItem(id: "edit.undo", label: "Undo", icon: "undo"),
        QatItem(id: "edit.redo", label: "Redo", icon: "redo"),
        QatItem(id: "show.fromStart", label: "Start from Beginning", icon: "playFromStart"),
        QatItem(id: "app.find", label: "Find", icon: "search"),
        QatItem(id: "review.spelling", label: "Spelling", icon: "spelling"),
        QatItem(id: "app.exportDialog", label: "Export", icon: "export"),
    ]

    /// `defaults`: the toolbar a new install starts with.
    public static var defaults: [QatItem] {
        ["app.home", "file.save", "app.exportDialog", "edit.undo", "edit.redo", "show.fromStart"].compactMap { id in common.first { $0.id == id } }
    }

    /// Whether `id` names an engine or UI command (`ribbon::known`).
    public static func known(_ id: String) -> Bool { findCommand(id) != nil || UICommands.contains(id) }

    /// `command`: `{add: id, params?, label?, icon?} | {remove: id, params?} | {reset: true}` → the toolbar.
    public static func command(_ items: inout [QatItem], _ p: JSON) -> Result<JSON, CommandError> {
        let params = p["params"] ?? .null
        if p["reset"]?.asBool == true { items = defaults }
        if let id = p["add"]?.asStr {
            guard known(id) else { return .failure(CommandError("unknown command `\(id)`")) }
            if !items.contains(where: { $0.same(id, params) }) {
                let base = common.first { $0.id == id }
                let label = p["label"]?.asStr ?? base?.label ?? findCommand(id)?.label ?? id
                let icon = p["icon"]?.asStr ?? base?.icon ?? "more"
                items.append(QatItem(id: id, params: params, label: label, icon: icon))
            }
        }
        if let id = p["remove"]?.asStr {
            items.removeAll { $0.same(id, params) }
        }
        return .success(.array(items.map { $0.toJSON() }))
    }

    /// The toolbar kept between launches (in the app's defaults; deckcraft keeps it in `ui.json`).
    public static func load(_ defaults: UserDefaults = .standard) -> [QatItem] {
        guard let data = defaults.data(forKey: storageKey), let items = try? JSONDecoder().decode([QatItem].self, from: data) else {
            return QAT.defaults
        }
        return Array(items.filter { known($0.id) }.prefix(64))
    }

    public static func save(_ items: [QatItem], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: storageKey) }
    }

    static let storageKey = "DeckCraftQuickAccessToolbar"
}
