// DCAppModel — the dialogs deckcraft has, their titles and buttons. Port of `title` and the `buttons` each
// body draws in deckcraft `crates/ui-egui/src/dialogs.rs` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
import DCEngine

public enum DialogCatalog {
    /// Every dialog id `app.dialog` opens, in deckcraft's `title` order, plus the File backstage's pages
    /// that are dialogs on the Mac (`info`, `new`). `quit` and `close` are NSDocument's own alerts.
    public static let ids: [String] = [
        "table", "slideSize", "sizePosition", "headerFooter", "hyperlink", "setupShow", "zoom", "comment", "altText",
        "outline", "renameSection", "reuseSlides", "renameShape", "renameLayout", "paragraph", "tabs", "font", "about",
        "preferences", "autocorrect", "gridOptions", "columns", "export", "symbol", "photoAlbum", "replaceFonts",
        "equation", "dateTime", "spelling", "pasteSpecial", "find", "accessibility", "language", "customShow",
        "chartData", "trim", "smartart", "bullets", "action", "themeColors", "themeFonts", "info", "new",
    ]

    /// `title`.
    public static func title(_ id: String) -> String {
        switch id {
        case "table": L10n.text("Insert Table")
        case "slideSize": L10n.text("Slide Size")
        case "sizePosition": L10n.text("Size and Position")
        case "headerFooter": L10n.text("Header and Footer")
        case "hyperlink": L10n.text("Insert Hyperlink")
        case "setupShow": L10n.text("Set Up Slide Show")
        case "zoom": L10n.text("Zoom")
        case "comment": L10n.text("New Comment")
        case "altText": L10n.text("Alt Text")
        case "outline": L10n.text("Slides from Outline")
        case "renameSection": L10n.text("Rename Section")
        case "reuseSlides": L10n.text("Reuse Slides")
        case "renameShape": L10n.text("Rename")
        case "renameLayout": L10n.text("Rename Layout")
        case "paragraph": L10n.text("Paragraph")
        case "tabs": L10n.text("Tabs")
        case "font": L10n.text("Font")
        case "about": L10n.text("About DeckCraftNative")
        case "preferences": L10n.text("Settings")
        case "autocorrect": L10n.text("AutoCorrect")
        case "gridOptions": L10n.text("Grid Options")
        case "columns": L10n.text("Columns")
        case "export": L10n.text("Export")
        case "symbol": L10n.text("Symbol")
        case "photoAlbum": L10n.text("Photo Album")
        case "replaceFonts": L10n.text("Replace Font")
        case "equation": L10n.text("Equation")
        case "dateTime": L10n.text("Date and Time")
        case "spelling": L10n.text("Spelling")
        case "pasteSpecial": L10n.text("Paste Special")
        case "find": L10n.text("Find and Replace")
        case "accessibility": L10n.text("Accessibility Checker")
        case "language": L10n.text("Language")
        case "customShow": L10n.text("Custom Shows")
        case "chartData": L10n.text("Chart Data")
        case "trim": L10n.text("Trim Media")
        case "smartart": L10n.text("Choose a SmartArt Graphic")
        case "bullets": L10n.text("Bullets and Numbering")
        case "action": L10n.text("Action Settings")
        case "themeColors": L10n.text("Create New Theme Colors")
        case "themeFonts": L10n.text("Create New Theme Fonts")
        case "info": L10n.text("Properties")
        case "new": L10n.text("New Presentation")
        default: "DeckCraftNative"  // the app's name, not translated
        }
    }

    /// Dialogs that show in a window of their own rather than as a sheet on the document window.
    public static func isWindow(_ id: String) -> Bool {
        ["about", "preferences", "new"].contains(id)
    }

    /// The buttons the form's rows carry (`press` takes their ids too).
    public static func actions(in rows: [FormRow]) -> [FormAction] {
        var out: [FormAction] = []
        for r in rows {
            switch r {
            case .actions(let a): out += a
            case .item(_, let a): out += a
            case .tiles(let t): out += t.map { FormAction($0.id, $0.label) }
            case .row(let rs): out += actions(in: rs)
            case .disabled(let rs): out += actions(in: rs).map { FormAction($0.id, $0.label, enabled: false) }
            default: break
            }
        }
        return out
    }

    /// A form row as the control channel reports it.
    public static func json(_ row: FormRow) -> JSON {
        func opts(_ o: [FormOption]) -> JSON {
            .array(o.map { ["value": .string($0.value), "label": .string($0.label), "enabled": .bool($0.enabled)] })
        }
        func acts(_ a: [FormAction]) -> JSON {
            .array(a.map { ["id": .string($0.id), "label": .string($0.label), "enabled": .bool($0.enabled)] })
        }
        switch row {
        case .heading(let t): return ["kind": "heading", "text": .string(t)]
        case .note(let t): return ["kind": "note", "text": .string(t)]
        case .error(let t): return ["kind": "error", "text": .string(t)]
        case .text(let l, let k, _): return ["kind": "text", "label": .string(l), "key": .string(k)]
        case .multiline(let l, let k, _): return ["kind": "multiline", "label": .string(l), "key": .string(k)]
        case .check(let l, let k): return ["kind": "check", "label": .string(l), "key": .string(k)]
        case .choice(let l, let k, let o): return ["kind": "choice", "label": .string(l), "key": .string(k), "options": opts(o)]
        case .radio(let l, let k, let o): return ["kind": "radio", "label": .string(l), "key": .string(k), "options": opts(o)]
        case .tabs(let k, let o): return ["kind": "tabs", "key": .string(k), "options": opts(o)]
        case .list(let l, let k, let o, _): return ["kind": "list", "label": .string(l), "key": .string(k), "options": opts(o)]
        case .actions(let a): return ["kind": "actions", "actions": acts(a)]
        case .item(let t, let a): return ["kind": "item", "text": .string(t), "actions": acts(a)]
        case .color(let l, let k): return ["kind": "color", "label": .string(l), "key": .string(k)]
        case .grid(let cells): return ["kind": "grid", "cells": .array(cells.map { .array($0.map { .string($0) }) })]
        case .tiles(let t): return ["kind": "tiles", "tiles": .array(t.map { ["id": .string($0.id), "label": .string($0.label)] })]
        case .sample(let s): return ["kind": "sample", "text": .string(s.text), "family": .string(s.family)]
        case .row(let rs): return ["kind": "row", "rows": .array(rs.map(json))]
        case .disabled(let rs): return ["kind": "disabled", "rows": .array(rs.map(json))]
        }
    }
}

extension DialogController {
    /// The buttons along the bottom of `d` (`buttons(ui, ok_label)` and the bodies that draw their own).
    func bottomButtons(_ d: Dialog) -> [DialogButton] {
        func okCancel(_ ok: String) -> [DialogButton] { [DialogButton("cancel", L10n.text("Cancel"), .cancel), DialogButton("ok", ok, .primary)] }
        switch d.id {
        case "table", "outline", "equation", "smartart": return okCancel(L10n.text("Insert"))
        case "reuseSlides": return okCancel(L10n.text("Insert"))
        case "headerFooter":
            return [DialogButton("cancel", L10n.text("Cancel"), .cancel), DialogButton("apply", L10n.text("Apply")), DialogButton("applyAll", L10n.text("Apply to All"), .primary)]
        case "comment": return okCancel(String(localized: "Post", bundle: .module, comment: "Button: posts the new comment"))
        case "renameSection", "renameShape", "renameLayout": return okCancel(L10n.text("Rename"))
        case "export": return okCancel(L10n.text("Export…"))
        case "replaceFonts": return [DialogButton("cancel", L10n.text("Close"), .cancel), DialogButton("ok", L10n.text("Replace"), .primary)]
        case "symbol", "spelling", "accessibility", "about": return [DialogButton("ok", L10n.text("Close"), .primary)]
        case "find":
            let has = !d.value("text").isEmpty
            return [DialogButton("cancel", L10n.text("Close"), .cancel), DialogButton("findNext", L10n.text("Find Next"), .primary, enabled: has)]
        case "customShow": return okCancel(L10n.text("Create"))
        case "chartData":
            return chartOf(model.session) == nil ? [DialogButton("ok", L10n.text("Close"), .primary)] : okCancel(L10n.text("OK"))
        case "photoAlbum": return okCancel(d.flag("editing") ? L10n.text("Update") : L10n.text("Create"))
        case "themeColors", "themeFonts": return okCancel(L10n.text("Save"))
        case "preferences": return okCancel(L10n.text("Done"))
        case "info": return okCancel(L10n.text("OK"))
        case "new": return [DialogButton("cancel", L10n.text("Cancel"), .cancel), DialogButton("new:blank", L10n.text("Blank Presentation"), .primary)]
        default: return okCancel(L10n.text("OK"))
        }
    }
}
