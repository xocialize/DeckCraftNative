// DCEngine — keyboard: text-editing keys while editing text, nudges and shortcuts otherwise. Shared by
// the UI, the control channel and MCP so a key does the same thing everywhere.
// Port of deckcraft crates/engine/src/keys.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum Keys {
    /// Does a shortcut like `Cmd+Shift+]` match `key` + `mods`?
    public static func shortcutMatches(_ shortcut: String, _ key: String, _ mods: Mods) -> Bool {
        let parts = shortcut.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let k: String
        let ms: ArraySlice<String>
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            k = "+"
            ms = parts[..<(parts.count - 2)]
        } else if let last = parts.last {
            k = last
            ms = parts.dropLast()
        } else {
            return false
        }
        func eq(_ a: String, _ b: String) -> Bool { Array(rustASCIILowercase(a).utf8) == Array(rustASCIILowercase(b).utf8) }
        func has(_ m: String) -> Bool { ms.contains { eq($0, m) } }
        return eq(k, key) && (has("cmd") || has("ctrl")) == mods.cmd && has("shift") == mods.shift && (has("alt") || has("option")) == mods.alt
    }

    /// A key name in one spelling: lower case, `ArrowLeft` → `left`, and the UI toolkit's names for
    /// punctuation keys (`Period`, `CloseBracket`…) → the character.
    public static func keyToken(_ key: String) -> String {
        var k = rustASCIILowercase(key)
        while k.hasPrefix("arrow") { k = String(k.dropFirst(5)) }
        switch k {
        case "period", ">": return "."
        case "comma", "<": return ","
        case "openbracket", "{": return "["
        case "closebracket", "}": return "]"
        case "equals": return "="
        case "minus": return "-"
        case "plus": return "+"
        case "slash": return "/"
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote": return "'"
        case "backtick": return "`"
        default: return k
        }
    }
}

extension Session {
    /// Handle one key press. `key` is a name (`Enter`, `Escape`, `Backspace`, `Delete`, `Tab`,
    /// `ArrowLeft`…, `Home`, `End`, `PageUp`, `PageDown`, `F5`) or a character (`b`, `]`).
    /// Returns `{handled: bool, …}`.
    public func key(_ key: String, _ mods: Mods) throws(EngineError) -> JSON {
        settleComposition()
        let editing = activeDoc?.selection.text != nil
        let hasShapes = activeDoc.map { !$0.selection.shapes.isEmpty } ?? false
        let k = Keys.keyToken(key)
        if (k == "escape" || k == "esc") && cancelPointDrag() { return ["handled": true] }
        if tool.drawingFreeform && (k == "enter" || k == "return" || k == "escape") { return try finishFreeform(false) }
        if tool.editPoints != nil && (k == "enter" || k == "return" || k == "escape") {
            tool.editPoints = nil
            tool.editVertex = nil
            tool.editSegment = nil
            return ["handled": true, "command": "shape.editPoints"]
        }
        if editing, let (id, params) = textKey(k, mods) {
            let r = try execute(id, params)
            return ["handled": true, "command": .string(id), "result": r]
        }
        if editing && !mods.cmd {
            var ran = false
            switch k {
            case "enter", "return":
                _ = try execute("text.insert", ["text": .string(mods.shift ? "\u{0B}" : "\n")])
                ran = true
            case "escape", "esc":
                _ = try execute("text.exit", .emptyObject)
                ran = true
            case "tab":
                // Tab at the start of a paragraph changes the list level; elsewhere it types a tab.
                let t = activeDoc?.selection.text
                let atStart = t.map { $0.ordered.0.char == 0 || $0.isRange } ?? false
                let inCell = t?.cell != nil
                if inCell {
                    _ = try nextCell(mods.shift)
                } else if atStart {
                    _ = try execute(mods.shift ? "format.outdent" : "format.indent", .emptyObject)
                } else {
                    _ = try execute("text.insert", ["text": "\t"])
                }
                ran = true
            default:
                break
            }
            if ran { return ["handled": true] }
        }
        if !editing && hasShapes && !mods.cmd && mods.shift && !mods.alt {
            // Shift+arrow grows or shrinks a selected range of table cells.
            let d: (Int, Int)? = switch k {
            case "left": (0, -1)
            case "right": (0, 1)
            case "up": (-1, 0)
            case "down": (1, 0)
            default: nil
            }
            if let (dr, dc) = d {
                let extended: Bool
                do { extended = try TableCommands.extendSelectedCells(self, dr, dc) } catch { throw EngineError.from(error) }
                if extended { return ["handled": true] }
            }
        }
        if !editing && hasShapes && !mods.cmd {
            let step = mods.alt ? 1.0 : 6.0
            let d: (Double, Double)? = switch k {
            case "left": (-step, 0)
            case "right": (step, 0)
            case "up": (0, -step)
            case "down": (0, step)
            default: nil
            }
            if let (dx, dy) = d {
                _ = try execute("shape.move", ["dx": .num(dx), "dy": .num(dy)])
                return ["handled": true]
            }
            switch k {
            case "backspace", "delete":
                _ = try execute("edit.delete", .emptyObject)
                return ["handled": true]
            case "enter", "return", "f2":
                _ = try execute("text.edit", .emptyObject)
                return ["handled": true]
            case "escape", "esc":
                _ = try execute("edit.deselect", .emptyObject)
                return ["handled": true]
            case "tab":
                try cycleSelection(!mods.shift)
                return ["handled": true]
            default:
                break
            }
        }
        if !editing && !hasShapes && !mods.cmd {
            var id: String?
            switch k {
            case "pagedown", "down", "right": id = "slide.next"
            case "pageup", "up", "left": id = "slide.previous"
            case "home": id = "slide.first"
            case "end": id = "slide.last"
            case "enter", "return": id = "slide.new"
            case "tab":
                try cycleSelection(!mods.shift)
                return ["handled": true]
            default: break
            }
            if let id {
                _ = try execute(id, .emptyObject)
                return ["handled": true]
            }
        }
        // Shortcuts from the registry.
        let keyName: String = switch k {
        case "left": "Left"
        case "right": "Right"
        case "up": "Up"
        case "down": "Down"
        case "enter", "return": "Enter"
        case "escape", "esc": "Escape"
        case "delete": "Delete"
        case "backspace": "Backspace"
        case "pageup": "PageUp"
        case "pagedown": "PageDown"
        case "home": "Home"
        case "end": "End"
        case "tab": "Tab"
        case "space", " ": "Space"
        default: k
        }
        if let found = CommandSpecs.all.first(where: { c in c.shortcut.map { Keys.shortcutMatches($0, keyName, mods) } ?? false }) {
            let r = try execute(found.id, .emptyObject)
            return ["handled": true, "command": .string(found.id), "result": r]
        }
        return ["handled": false]
    }

    /// The text-editing command for a navigation or deletion key while editing text, by platform: Ctrl
    /// (Windows, Linux) or Option (Mac) moves and deletes by word; Ctrl+Up/Down moves by paragraph;
    /// Ctrl+Home/End (Cmd+Up/Down on the Mac) go to the ends of the text and Cmd+Left/Right on the Mac to
    /// the ends of the line. Shift extends the selection.
    private func textKey(_ k: String, _ mods: Mods) -> (String, JSON)? {
        let word = macKeys ? (mods.alt && !mods.cmd) : (mods.cmd && !mods.alt)
        let macCmd = macKeys && mods.cmd && !mods.alt
        if mods.cmd && !mods.alt && !mods.shift {
            // Ctrl+] / Ctrl+[ grow and shrink the font, like Ctrl+Shift+> / <.
            if k == "]" { return ("format.grow", .emptyObject) }
            if k == "[" { return ("format.shrink", .emptyObject) }
        }
        let plain = !mods.cmd && !mods.alt
        let to: String
        switch k {
        case "left" where word: to = "wordLeft"
        case "right" where word: to = "wordRight"
        case "left" where macCmd: to = "lineStart"
        case "right" where macCmd: to = "lineEnd"
        case "left" where plain: to = "left"
        case "right" where plain: to = "right"
        case "up" where macCmd: to = "start"
        case "down" where macCmd: to = "end"
        case "up" where word && macKeys: to = "paraStart"
        case "down" where word && macKeys: to = "paraEnd"
        case "up" where word: to = "paraUp"
        case "down" where word: to = "paraDown"
        case "up" where plain: to = "up"
        case "down" where plain: to = "down"
        case "home" where mods.cmd && !mods.alt: to = "start"
        case "end" where mods.cmd && !mods.alt: to = "end"
        case "home" where plain: to = "lineStart"
        case "end" where plain: to = "lineEnd"
        case "backspace" where word: return ("text.delete", ["dir": "wordBackward"])
        case "delete" where word: return ("text.delete", ["dir": "wordForward"])
        case "backspace" where plain: return ("text.delete", ["dir": "backward"])
        case "delete" where plain: return ("text.delete", ["dir": "forward"])
        default: return nil
        }
        return ("text.move", ["to": .string(to), "extend": .bool(mods.shift)])
    }

    /// Type text: into the text being edited, or (a shape selected) start editing it.
    public func typeText(_ text: String) throws(EngineError) -> JSON {
        let st = try doc()
        if st.selection.text == nil {
            guard let id = st.selection.shapes.first else { return ["handled": false] }
            if st.selection.shapes.count != 1 { return ["handled": false] }
            // Typing on a selected shape replaces its text (PowerPoint behaviour).
            _ = try execute("text.edit", ["id": id.toJSON()])
            _ = try execute("text.selectAll", .emptyObject)
        }
        return try execute("text.insert", ["text": .string(text)])
    }

    /// An input method's preedit (#101). On a selected shape that isn't being edited, the first one starts
    /// editing its text and replaces it, as typing does. `active` is the part being converted, in
    /// characters of `text`.
    public func composeText(_ text: String, _ active: (Int, Int)?) throws(EngineError) -> JSON {
        if try !startTyping(text) { return ["handled": false] }
        var p: JSON = ["text": .string(text)]
        if let (a, b) = active { p.set("active", [.integer(a), .integer(b)]) }
        return try execute("text.compose", p)
    }

    /// An input method's result (#101): replaces the composition as one undo step.
    public func commitText(_ text: String) throws(EngineError) -> JSON {
        if try !startTyping(text) { return ["handled": false] }
        return try execute("text.commit", ["text": .string(text)])
    }

    /// Remove text around the composition caret or selection, as an input method asks. Counts are
    /// characters or UTF-8 bytes of the logical text the surrounding query publishes.
    public func deleteSurrounding(_ before: Int, _ after: Int, _ bytes: Bool) throws(EngineError) -> JSON {
        try execute("text.deleteSurrounding", ["before": .integer(before), "after": .integer(after), "bytes": .bool(bytes)])
    }

    /// Ready to take typed `text`: editing text already, or one selected shape whose text editing starts
    /// with everything selected. False when there is nowhere to type.
    private func startTyping(_ text: String) throws(EngineError) -> Bool {
        let st = try doc()
        if st.selection.text != nil { return true }
        guard let id = st.selection.shapes.first else { return false }
        if st.selection.shapes.count != 1 || text.isEmpty { return false }
        _ = try execute("text.edit", ["id": id.toJSON()])
        _ = try execute("text.selectAll", .emptyObject)
        return true
    }

    private func cycleSelection(_ forward: Bool) throws(EngineError) {
        let st = try doc()
        let ids = st.shapes.filter { !$0.hidden }.map(\.id)
        if ids.isEmpty { return }
        let cur = st.selection.shapes.first.flatMap { c in ids.firstIndex(of: c) }
        let n = ids.count
        let next: Int = switch (cur, forward) {
        case (.some(let i), true): (i + 1) % n
        case (.some(let i), false): (i + n - 1) % n
        case (nil, true): 0
        case (nil, false): n - 1
        }
        let id = ids.at(next)
        do {
            try select { _, sel in
                sel.shapes = id.map { [$0] } ?? []
                sel.text = nil
            }
        } catch { throw EngineError.from(error) }
    }

    private func nextCell(_ back: Bool) throws(EngineError) -> JSON {
        let st = try doc()
        guard let t = st.selection.text, let cell = t.cell else { return .null }
        guard case .table(let tb)? = st.shape(t.shape)?.kind else { return .null }
        let (r, c) = (cell.para, cell.char)
        let (nr, nc) = (tb.nRows, max(tb.nCols, 1))
        // A hostile cell can be anywhere: the arithmetic saturates instead of trapping.
        let (rowStart, o1) = r.multipliedReportingOverflow(by: nc)
        let (sum, o2) = rowStart.addingReportingOverflow(c)
        let idx = o1 || o2 ? Int.max - 1 : sum
        let total = nr.multipliedReportingOverflow(by: nc).overflow ? Int.max : nr * nc
        // Cells hidden under a merged cell are skipped.
        func visible(_ i: Int) -> Bool { tb.cell(i / nc, i % nc).map { !$0.isCovered } ?? false }
        let next: Int? = back ? (0 ..< min(max(idx, 0), total)).reversed().first(where: visible) : ((idx + 1) ..< max(total, idx + 1)).first(where: visible)
        let ni: Int
        if let n = next {
            ni = n
        } else if !back {
            // Tab in the last cell adds a row.
            let last = max(nr - 1, 0)
            _ = try execute("table.insertRowBelow", ["id": t.shape.toJSON(), "row": .integer(last)])
            return try execute("text.edit", ["id": t.shape.toJSON(), "cell": [.integer(last + 1), 0]])
        } else {
            ni = idx
        }
        _ = try execute("text.edit", ["id": t.shape.toJSON(), "cell": [.integer(ni / nc), .integer(ni % nc)]])
        return try execute("text.selectAll", .emptyObject)
    }
}
