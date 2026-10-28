// DCAppModel — the dialogs without a window: each dialog's fields, the form the window draws from them, and
// what its buttons do. Port of `Dialog`, `show`'s close paths and the helpers of deckcraft
// `crates/ui-egui/src/dialogs.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// deckcraft keeps an open dialog as `Dialog { id, params, fields }` and draws it every frame with egui,
// running its OK straight from the drawing code. Here the same state lives in `DialogController`: the
// form (`DialogController.form`) is computed from the fields, the window renders it, edits come back
// through `set`, and buttons through `press`. Nothing below needs a window, so the dialogs are tested
// and driven by the control channel (`ui.dialog.*`) exactly as the window drives them.
import CoreText
import DCCore
import DCEngine
import Foundation
import Observation

/// One open dialog (`Dialog`): its id, the parameters it was opened with, and the values of its fields.
public struct Dialog: Sendable, Equatable {
    public var id: String
    public var params: JSON
    /// Field values while the dialog is open (`fields`). Booleans are `"1"`/`"0"`, as deckcraft keeps them.
    public var fields: [String: String]
    /// What a field shows before it is edited, when that is not a value the user has picked (Header and
    /// Footer's date format: sending the default would rewrite every slide's date field).
    public var shown: [String: String] = [:]

    public init(_ id: String, params: JSON = .null, fields: [String: String] = [:]) {
        self.id = id
        self.params = params
        self.fields = fields
    }

    /// `Dialog::get`: the field, stored as `def` when it has no value yet.
    public mutating func get(_ key: String, _ def: String) -> String {
        if let v = fields[key] { return v }
        fields[key] = def
        return def
    }

    /// `field_of`: the field, or empty.
    public func field(_ key: String) -> String { fields[key] ?? "" }

    /// What the window shows for `key`: the field, or what it shows before an edit.
    public func value(_ key: String) -> String { fields[key] ?? shown[key] ?? "" }

    /// A checkbox field.
    public func flag(_ key: String) -> Bool { value(key) == "1" }

    /// `seed_once`.
    mutating func seed(_ key: String, _ v: String) {
        if fields[key] == nil { fields[key] = v }
    }
}

/// One choice of a popup, radio group, segmented control or list.
public struct FormOption: Sendable, Equatable {
    public var value: String
    public var label: String
    public var enabled: Bool
    public init(_ value: String, _ label: String, enabled: Bool = true) {
        self.value = value
        self.label = label
        self.enabled = enabled
    }
}

/// A button inside the form (`press(id)`).
public struct FormAction: Sendable, Equatable {
    public var id: String
    public var label: String
    public var enabled: Bool
    public init(_ id: String, _ label: String, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.enabled = enabled
    }
}

/// A tile of a gallery (File › New): pressing it presses `id`. `colors` are a theme's swatches (hex).
public struct FormTile: Sendable, Equatable {
    public var id: String
    public var label: String
    public var detail: String
    public var colors: [String]
    public init(_ id: String, _ label: String, detail: String = "", colors: [String] = []) {
        self.id = id
        self.label = label
        self.detail = detail
        self.colors = colors
    }
}

/// How a font sample is drawn (the Font and Theme Fonts dialogs).
public struct FormSample: Sendable, Equatable {
    public var text: String
    public var family: String
    public var size: Double
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public init(text: String, family: String, size: Double) {
        self.text = text
        self.family = family
        self.size = size
    }
}

/// One row of a dialog's form. The window draws it; its values are the dialog's fields.
public indirect enum FormRow: Sendable, Equatable {
    case heading(String)
    /// Secondary text.
    case note(String)
    /// An error message under the fields.
    case error(String)
    case text(label: String, key: String, placeholder: String = "")
    case multiline(label: String, key: String, lines: Int)
    case check(label: String, key: String)
    /// A popup menu.
    case choice(label: String, key: String, options: [FormOption])
    /// A radio group.
    case radio(label: String, key: String, options: [FormOption])
    /// A segmented control (a dialog's tabs).
    case tabs(key: String, options: [FormOption])
    /// A selectable list; `findable` lists get a search field (DesignScaffoldPicker).
    case list(label: String, key: String, options: [FormOption], findable: Bool)
    /// A row of buttons.
    case actions([FormAction])
    /// A line of text with buttons after it (a spelling result, a custom show).
    case item(String, actions: [FormAction])
    /// A colour: a hex field with a swatch and the system colour panel.
    case color(label: String, key: String)
    /// A table of text fields (`cell:<row>:<col>` keys).
    case grid(cells: [[String]])
    /// A gallery of tiles.
    case tiles([FormTile])
    case sample(FormSample)
    /// Rows side by side.
    case row([FormRow])
    /// Rows the user can't change right now.
    case disabled([FormRow])
}

/// A button along the bottom of a dialog.
public struct DialogButton: Sendable, Equatable {
    public enum Role: String, Sendable { case primary, cancel, normal }
    public var id: String
    public var label: String
    public var role: Role
    public var enabled: Bool
    public init(_ id: String, _ label: String, _ role: Role = .normal, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.role = role
        self.enabled = enabled
    }
}

/// What the dialogs need from the app around them: the file panels (asynchronous, so a control-channel
/// command never blocks on one), links, and the clipboard.
@MainActor
public protocol DialogServices: AnyObject {
    /// An open panel for `purpose` (`picture`, `audio`, `video`, `theme`, `open`); `done` gets the path, or
    /// nil when cancelled.
    func pickOpen(_ purpose: String, _ done: @escaping @MainActor (String?) -> Void)
    /// A save panel suggesting `name`.
    func pickSave(_ name: String, _ done: @escaping @MainActor (String?) -> Void)
    func openURL(_ url: String)
    func copyText(_ text: String)
}

/// A brief notice over the bottom of the window (`toast.rs`).
public struct Toast: Sendable, Equatable {
    public var text: String
    public var at: Date
    /// How long a toast stays (`SHOW_MS`).
    public static let showSeconds: Double = 8
}

/// The command palette's state while it is open (`SlideApp::palette`).
public struct PaletteState: Sendable, Equatable {
    public var query = ""
    public var selection = 0
    public init() {}
}

/// The open dialog, the palette and the toast, and everything their buttons do. One per app, as deckcraft
/// has one `SlideApp::dialog`.
@MainActor @Observable
public final class DialogController {
    public let model: AppModel
    @ObservationIgnored public weak var services: (any DialogServices)?
    /// The open dialog, if any.
    public internal(set) var current: Dialog?
    /// Bumps whenever a dialog opens, so an action that opens another one (Paragraph's Tabs…) doesn't
    /// close it on the way out.
    public private(set) var generation: UInt64 = 0
    public var palette: PaletteState?
    public var toast: Toast?
    /// Called after a dialog opens or closes, for the window that shows it.
    @ObservationIgnored public var didChange: (@MainActor () -> Void)?
    /// Documents whose missing fonts were already toasted (`fonts_noted`).
    @ObservationIgnored var fontsNoted: Set<UInt64> = []
    /// Where a picked file goes when it arrives (`FileTarget`): the document and slide current when the
    /// panel opened.
    @ObservationIgnored var reuseTarget: FileTarget?
    /// Interface font families (the Font dialog's list); the app gives the installed ones.
    @ObservationIgnored public var fontFamiliesProvider: @MainActor () -> [String] = { DialogFonts.installedFamilies() }
    /// The start window (the app's): File › Home, New and Open show it. Without it, New is the "new" dialog.
    @ObservationIgnored public weak var startScreen: StartScreenModel?

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: Opening and closing

    /// Open dialog `id` (`app.dialog`, `UiRequest::Dialog`, `ui.dialog.open`), replacing any open one.
    public func open(_ id: String, params: JSON = .null, fields: [String: String] = [:]) {
        var d = Dialog(id, params: params, fields: fields)
        seed(&d)
        current = d
        generation &+= 1
        didChange?()
    }

    /// Close the open dialog without acting on it (Esc, the close button, `ui.dialog.close`). Preferences put
    /// back what they opened with; Tabs opened from Paragraph returns there.
    public func cancel() {
        guard let d = current else { return }
        if d.id == "preferences" { restorePreferences(d) }
        finish(d)
    }

    /// Close without the cancel side effects.
    func finish(_ d: Dialog) {
        current = nil
        didChange?()
        // Tabs… opened from Paragraph: closing it (OK, Cancel, Esc or the window) returns there.
        if let ret = d.params["returnParams"], ret.isObject {
            open(d.params["returnId"]?.asStr ?? "paragraph", params: ret)
        }
    }

    /// Set field `key` (`ui.dialog.set`, an edit in the window) and let the dialog react to it.
    public func set(_ key: String, _ value: String) {
        guard var d = current else { return }
        edit(&d, key, value)
        if current != nil { current = d }
    }

    /// Set several fields in order.
    public func set(_ fields: [String: String]) {
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { set(k, v) }
    }

    /// Press button or action `id` (`ui.dialog.press`, a click). Returns false when there is no such button.
    @discardableResult
    public func press(_ id: String) -> Bool {
        guard var d = current else { return false }
        let gen = generation
        if id == "cancel" {
            cancel()
            return true
        }
        let before = current
        guard let close = act(&d, id) else { return false }
        // The action may have opened another dialog (Tabs…, AutoCorrect Options…): that one stays.
        guard generation == gen, let now = current else { return true }
        // A file panel that answered at once already updated the dialog (Add Pictures…): that wins.
        if now != before { d = now }
        if close {
            finish(d)
        } else {
            current = d
        }
        return true
    }

    /// The open dialog's title (`title`).
    public var title: String { current.map { DialogCatalog.title($0.id) } ?? "" }

    /// The open dialog's form, as the window draws it.
    public var form: [FormRow] {
        guard let d = current else { return [] }
        return rows(d)
    }

    /// The buttons along the bottom of the open dialog.
    public var buttons: [DialogButton] {
        guard let d = current else { return [] }
        return bottomButtons(d)
    }

    /// The open dialog for the control channel (`ui.dialog.get`): id, title, params, fields, the buttons and
    /// actions that `press` takes, and the form.
    public func describe() -> JSON {
        guard let d = current else { return .null }
        var fields = JSONObject()
        for k in d.fields.keys.sorted() { fields.set(k, .string(d.fields[k] ?? "")) }
        for k in d.shown.keys.sorted() where d.fields[k] == nil { fields.set(k, .string(d.shown[k] ?? "")) }
        return [
            "id": .string(d.id), "title": .string(title), "params": d.params, "fields": .object(fields),
            "buttons": .array(buttons.map { ["id": .string($0.id), "label": .string($0.label), "enabled": .bool($0.enabled)] }),
            "actions": .array(DialogCatalog.actions(in: form).map { ["id": .string($0.id), "label": .string($0.label), "enabled": .bool($0.enabled)] }),
            "form": .array(form.map(DialogCatalog.json)),
        ]
    }

    // MARK: Status and toasts

    /// `set_status`.
    func status(_ text: String) { model.status = text }

    /// `notify`: a toast, seen wherever the user is.
    public func notify(_ text: String) { toast = Toast(text: text, at: Date()) }

    /// The toast while it is fresh; clears it once stale.
    public func freshToast(now: Date = Date()) -> Toast? {
        guard let t = toast else { return nil }
        if now.timeIntervalSince(t.at) > Toast.showSeconds {
            toast = nil
            return nil
        }
        return t
    }

    /// `note_missing_fonts`: toast the active presentation's missing fonts, once per opened document.
    public func noteMissingFonts() {
        guard let d = model.session.activeDoc, fontsNoted.insert(d.uid).inserted else { return }
        if let text = DialogToast.missingFontsMessage(d.missingFonts) { notify(text) }
    }

    // MARK: Running commands

    /// `app.run`, discarding the answer (`run` in `body`).
    func run(_ id: String, _ p: JSON = .emptyObject) {
        model.run(id, p)
    }

    /// `app.run(...).is_ok()`.
    func ok(_ id: String, _ p: JSON = .emptyObject) -> Bool {
        if case .success = model.run(id, p) { return true }
        return false
    }

    /// `session.execute`, quietly (queries the dialogs make while drawing).
    func query(_ id: String, _ p: JSON = .emptyObject) -> JSON? {
        try? model.session.execute(id, p)
    }
}

/// Fonts for the dialogs' font lists.
public enum DialogFonts {
    /// The theme's heading and body fonts, then every installed family (`ribbon::font_families`).
    @MainActor
    public static func families(_ session: Session, installed: [String]) -> [String] {
        var v: [String] = []
        if let m = session.activeDoc?.doc.masters.first {
            v.append(m.theme.fonts.major.latin)
            v.append(m.theme.fonts.minor.latin)
        }
        v += installed
        var out: [String] = []
        for f in v where out.last != f { out.append(f) }
        return out
    }

    /// The installed font families, sorted (CoreText's list; the app may give AppKit's).
    @MainActor public static func installedFamilies() -> [String] {
        if let cached { return cached }
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { !$0.hasPrefix(".") }.sorted()
        cached = names
        return names
    }

    @MainActor static var cached: [String]?
}

/// `toast.rs`.
public enum DialogToast {
    /// `missing_fonts_message`: the notice for fonts a presentation uses that aren't installed.
    public static func missingFontsMessage(_ fonts: [String]) -> String? {
        let names: String
        switch fonts.count {
        case 0: return nil
        case 1: names = fonts[0]
        case 2: names = String(localized: "\(fonts[0]) and \(fonts[1])", bundle: .module, comment: "A list of two missing font names")
        case 3: names = String(localized: "\(fonts[0]), \(fonts[1]) and \(fonts[2])", bundle: .module, comment: "A list of three missing font names")
        default:
            names = String(
                localized: "\(fonts[0]), \(fonts[1]), \(fonts[2]) and \(fonts.count - 3) more", bundle: .module,
                comment: "Three missing font names and how many more there are"
            )
        }
        if fonts.count == 1 {
            return String(
                localized: "\(names) isn't installed on this computer. Text that uses it is shown in a similar font.", bundle: .module,
                comment: "Toast: one missing font (its name)"
            )
        }
        return String(
            localized: "\(names) aren't installed on this computer. Text that uses them is shown in a similar font.", bundle: .module,
            comment: "Toast: several missing fonts (a list of their names)"
        )
    }
}

