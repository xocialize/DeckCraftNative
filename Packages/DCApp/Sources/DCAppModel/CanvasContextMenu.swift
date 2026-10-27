// DCAppModel — the canvas's context menu as data: what deckcraft's `context_menu` in
// `crates/ui-egui/src/canvas.rs` offers for the current state (Edit Points' point and segment items, a
// misspelt word's suggestions, Cut/Copy/Paste, the text, object or slide items), and what each item does.
// The canvas turns it into an `NSMenu`; tests read it directly. (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors.)
import DCCore
import DCEngine
import DCModel

/// What a context-menu item does.
public enum CanvasMenuAction: Sendable, Equatable {
    /// Run a command through the app (`AppModel.run`).
    case run(String, JSON)
    /// Run a command, then forget the Edit Points vertex or segment the menu was for (the command
    /// renumbers the points).
    case runThenClearPick(String, JSON)
    /// Open one of the app's dialogs (`app.dialog {id}`).
    case dialog(String)
    /// Ignore All: skip the word for the rest of the session.
    case ignoreAll(String)
    /// Add to Dictionary.
    case addToDictionary(String)
}

/// One entry of the menu.
public indirect enum CanvasMenuEntry: Sendable, Equatable {
    case item(title: String, action: CanvasMenuAction, enabled: Bool, checked: Bool, bold: Bool)
    case submenu(title: String, entries: [CanvasMenuEntry])
    /// A greyed note (no spelling suggestions).
    case note(String)
    case separator

    static func item(_ title: String, _ action: CanvasMenuAction, enabled: Bool = true, checked: Bool = false, bold: Bool = false) -> CanvasMenuEntry {
        .item(title: title, action: action, enabled: enabled, checked: checked, bold: bold)
    }

    public var title: String? {
        switch self {
        case .item(let t, _, _, _, _), .submenu(let t, _), .note(let t): t
        case .separator: nil
        }
    }

    /// The entry with `title`, looking into submenus.
    public static func find(_ entries: [CanvasMenuEntry], _ title: String) -> CanvasMenuEntry? {
        for e in entries {
            if e.title == title { return e }
            if case .submenu(_, let kids) = e, let f = find(kids, title) { return f }
        }
        return nil
    }
}

public enum CanvasContextMenu {
    /// A command's own availability (`ribbon::enabled`).
    static func enabled(_ s: Session, _ id: String) -> Bool { findCommand(id)?.enabled(s) == nil }

    /// The menu for the session as it is (after the right-click picked what's under the pointer), with
    /// `word` the flagged word under it and `guidesOn` View › Guides.
    public static func entries(_ s: Session, word: SquiggleWord?, guidesOn: Bool) -> [CanvasMenuEntry] {
        guard let st = s.activeDoc else { return [] }
        var out: [CanvasMenuEntry] = []
        // Edit Points: the picked segment's or point's items, then Exit Edit Points.
        if let id = s.tool.editingPoints(st), let sh = st.shape(id) {
            if let (path, index) = s.tool.editSegment {
                let cur = PointsCommands.segmentKindOf(sh, path, index)
                for (l, k) in [("Straight Segment", "straight"), ("Curved Segment", "curved")] {
                    out.append(.item(l, .run("shape.segmentType", ["path": .integer(path), "segment": .integer(index), "type": .string(k)]), checked: cur == k))
                }
                let t = s.tool.editSegmentT ?? 0.5
                out.append(.item("Add Point", .runThenClearPick("shape.addPoint", ["path": .integer(path), "segment": .integer(index), "t": .num(t)])))
                let closed = PointsCommands.closedAt(sh, path, index)
                out.append(.item("Delete Segment", .runThenClearPick("shape.deleteSegment", ["path": .integer(path), "segment": .integer(index)]), enabled: closed == true))
                // Open Path opens the outline at the segment's start point.
                if closed == false {
                    out.append(.item("Close Path", .runThenClearPick("shape.closePath", ["path": .integer(path), "index": .integer(index)])))
                } else {
                    let at = PointsCommands.segmentStartOf(sh, path, index) ?? index
                    out.append(.item("Open Path", .runThenClearPick("shape.openPath", ["path": .integer(path), "index": .integer(at)])))
                }
                out.append(.separator)
            } else if let (path, index) = s.tool.editVertex {
                let cur = PointsCommands.kindOf(sh, path, index)
                for (l, k) in [("Smooth Point", "smooth"), ("Straight Point", "straight"), ("Corner Point", "corner")] {
                    out.append(.item(l, .run("shape.pointType", ["path": .integer(path), "index": .integer(index), "type": .string(k)]), checked: cur == k))
                }
                out.append(.item("Delete Point", .runThenClearPick("shape.deletePoint", ["path": .integer(path), "index": .integer(index)])))
                let closed = PointsCommands.closedAt(sh, path, index) == false
                out.append(.item(closed ? "Close Path" : "Open Path", .runThenClearPick(closed ? "shape.closePath" : "shape.openPath", ["path": .integer(path), "index": .integer(index)])))
                out.append(.separator)
            }
            out.append(.item("Exit Edit Points", .run("shape.editPoints", ["on": false])))
            return out
        }
        // A flagged word: Delete Repeated Word or the suggestions, then Ignore All and Add to Dictionary.
        if let w = word {
            if let p = CanvasSquiggles.deleteRepeatedParams(st, w) {
                out.append(.item("Delete Repeated Word", .run("review.spellingChange", p), bold: true))
            } else if w.suggestions.isEmpty {
                out.append(.note("(no spelling suggestions)"))
            }
            for to in w.suggestions {
                if let p = CanvasSquiggles.changeParams(w, to: to) { out.append(.item(to, .run("review.spellingChange", p), bold: true)) }
            }
            out.append(.item("Ignore All", .ignoreAll(w.word)))
            out.append(.item("Add to Dictionary", .addToDictionary(w.word)))
            out.append(.separator)
        }
        for (l, id) in [("Cut", "edit.cut"), ("Copy", "edit.copy"), ("Paste", "edit.paste")] {
            out.append(.item(l, .run(id, .emptyObject), enabled: enabled(s, id)))
        }
        out.append(.separator)
        let editing = st.selection.text.map { !$0.notes } ?? false
        if editing {
            out.append(.item("Paragraph…", .dialog("paragraph")))
            for (l, id) in [("Bullets", "format.bullets"), ("Numbering", "format.numbering")] {
                out.append(.item(l, .run(id, .emptyObject), enabled: enabled(s, id)))
            }
            out.append(.item("Link…", .dialog("hyperlink")))
            out.append(.separator)
            out.append(.item("Format Shape…", .run("view.pane", ["pane": "format"])))
        } else if !st.selection.shapes.isEmpty {
            let shapes = st.selectedShapes
            out.append(.item("Edit Text", .run("text.edit", .emptyObject)))
            if enabled(s, "shape.editPoints") && st.selection.shapes.count == 1 && shapes.allSatisfy({ !$0.isLine }) {
                out.append(.item("Edit Points", .run("shape.editPoints", ["on": true])))
            }
            out.append(.item("Font…", .run("format.fontDialog", .emptyObject)))
            out.append(.item("Paragraph…", .run("format.paragraphDialog", .emptyObject)))
            func sub(_ title: String, _ items: [(String, String)]) -> CanvasMenuEntry {
                .submenu(title: title, entries: items.map { .item($0.0, .run($0.1, .emptyObject), enabled: enabled(s, $0.1)) })
            }
            out.append(sub("Bring to Front", [("Bring to Front", "arrange.bringToFront"), ("Bring Forward", "arrange.bringForward")]))
            out.append(sub("Send to Back", [("Send to Back", "arrange.sendToBack"), ("Send Backward", "arrange.sendBackward")]))
            out.append(sub("Group", [("Group", "arrange.group"), ("Ungroup", "arrange.ungroup")]))
            let locked = shapes.allSatisfy(\.locked)
            out.append(.item(locked ? "Unlock" : "Lock", .run("shape.lock", ["locked": .bool(!locked)])))
            if shapes.contains(where: { if case .picture = $0.kind { true } else { false } }) {
                out.append(.item("Change Picture…", .run("app.changePictureDialog", .emptyObject)))
            }
            out.append(.item("Link…", .dialog("hyperlink")))
            out.append(.item("Edit Alt Text…", .dialog("altText")))
            out.append(.item("Set as Default Shape", .run("shape.setDefault", .emptyObject)))
            out.append(.item("Size and Position…", .run("shape.sizePosition", .emptyObject)))
            out.append(.item("Format Shape…", .run("view.pane", ["pane": "format"])))
        } else {
            let layouts = st.doc.masters.first?.layouts ?? []
            out.append(.submenu(title: "Layout", entries: layouts.map { .item($0.name, .run("slide.layout", ["layout": .integer(Int($0.id.rawValue))])) }))
            out.append(.submenu(title: "Grid and Guides", entries: [
                .item("Guides", .run("view.guides", ["on": .bool(!guidesOn)]), checked: guidesOn),
                .item("Add Vertical Guide", .run("guide.add", ["vertical": true])),
                .item("Add Horizontal Guide", .run("guide.add", ["vertical": false])),
            ]))
            out.append(.item("Reset Slide", .run("slide.reset", .emptyObject)))
            out.append(.item("Format Background…", .run("view.pane", ["pane": "background"])))
            out.append(.item("New Comment", .dialog("comment")))
        }
        return out
    }

    /// Do what an item says. Failures land in the status bar, as every command's do.
    @MainActor public static func perform(_ action: CanvasMenuAction, _ app: AppModel, squiggles: CanvasSquiggles?) {
        switch action {
        case .run(let id, let p):
            app.run(id, p)
            // Adding a guide shows the guides, as in PowerPoint.
            if id == "guide.add" { app.run("view.guides", ["on": true]) }
        case .runThenClearPick(let id, let p):
            app.run(id, p)
            app.session.tool.editSegment = nil
            if id == "shape.deletePoint" || id == "shape.openPath" || id == "shape.closePath" { app.session.tool.editVertex = nil }
        case .dialog(let id):
            app.run("app.dialog", ["id": .string(id)])
        case .ignoreAll(let w):
            squiggles?.ignore(w)
            app.changed()
        case .addToDictionary(let w):
            do { _ = try app.session.execute("review.addToDictionary", ["word": .string(w)]) } catch { app.status = error.description }
            app.changed()
        }
        squiggles?.menuWord = nil
    }
}
