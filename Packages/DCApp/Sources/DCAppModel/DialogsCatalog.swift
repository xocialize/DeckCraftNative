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
        case "table": "Insert Table"
        case "slideSize": "Slide Size"
        case "sizePosition": "Size and Position"
        case "headerFooter": "Header and Footer"
        case "hyperlink": "Insert Hyperlink"
        case "setupShow": "Set Up Slide Show"
        case "zoom": "Zoom"
        case "comment": "New Comment"
        case "altText": "Alt Text"
        case "outline": "Slides from Outline"
        case "renameSection": "Rename Section"
        case "reuseSlides": "Reuse Slides"
        case "renameShape": "Rename"
        case "renameLayout": "Rename Layout"
        case "paragraph": "Paragraph"
        case "tabs": "Tabs"
        case "font": "Font"
        case "about": "About DeckCraft"
        case "preferences": "Settings"
        case "autocorrect": "AutoCorrect"
        case "gridOptions": "Grid Options"
        case "columns": "Columns"
        case "export": "Export"
        case "symbol": "Symbol"
        case "photoAlbum": "Photo Album"
        case "replaceFonts": "Replace Font"
        case "equation": "Equation"
        case "dateTime": "Date and Time"
        case "spelling": "Spelling"
        case "pasteSpecial": "Paste Special"
        case "find": "Find and Replace"
        case "accessibility": "Accessibility Checker"
        case "language": "Language"
        case "customShow": "Custom Shows"
        case "chartData": "Chart Data"
        case "trim": "Trim Media"
        case "smartart": "Choose a SmartArt Graphic"
        case "bullets": "Bullets and Numbering"
        case "action": "Action Settings"
        case "themeColors": "Create New Theme Colors"
        case "themeFonts": "Create New Theme Fonts"
        case "info": "Properties"
        case "new": "New Presentation"
        default: "DeckCraft"
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
        func okCancel(_ ok: String) -> [DialogButton] { [DialogButton("cancel", "Cancel", .cancel), DialogButton("ok", ok, .primary)] }
        switch d.id {
        case "table", "outline", "equation", "smartart": return okCancel("Insert")
        case "reuseSlides": return okCancel("Insert")
        case "headerFooter":
            return [DialogButton("cancel", "Cancel", .cancel), DialogButton("apply", "Apply"), DialogButton("applyAll", "Apply to All", .primary)]
        case "comment": return okCancel("Post")
        case "renameSection", "renameShape", "renameLayout": return okCancel("Rename")
        case "export": return okCancel("Export…")
        case "replaceFonts": return [DialogButton("cancel", "Close", .cancel), DialogButton("ok", "Replace", .primary)]
        case "symbol", "spelling", "accessibility", "about": return [DialogButton("ok", "Close", .primary)]
        case "find":
            let has = !d.value("text").isEmpty
            return [DialogButton("cancel", "Close", .cancel), DialogButton("findNext", "Find Next", .primary, enabled: has)]
        case "customShow": return okCancel("Create")
        case "chartData":
            return chartOf(model.session) == nil ? [DialogButton("ok", "Close", .primary)] : okCancel("OK")
        case "photoAlbum": return okCancel(d.flag("editing") ? "Update" : "Create")
        case "themeColors", "themeFonts": return okCancel("Save")
        case "preferences": return okCancel("Done")
        case "info": return okCancel("OK")
        case "new": return [DialogButton("cancel", "Cancel", .cancel), DialogButton("new:blank", "Blank Presentation", .primary)]
        default: return okCancel("OK")
        }
    }
}
