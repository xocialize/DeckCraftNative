// DCAppModel — the macOS menu bar's structure and deckcraft's shortcut strings. Port of `menu_tree` in
// deckcraft `crates/ui-egui/src/menus.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), which the Rust desktop app turns into its native menu bar.

/// One entry of a menu: a command, or a separator.
public enum MenuEntry: Sendable, Equatable {
    case command(label: String, id: String)
    case separator
}

public struct Menu: Sendable, Equatable {
    public var title: String
    public var entries: [MenuEntry]
}

public enum MenuTree {
    /// `menu_tree`: the menus and their entries, in deckcraft's order. "-" is a separator.
    public static let menus: [Menu] = [
        menu("File", [
            ("New Presentation", "file.new"), ("Open…", "app.openDialog"), ("-", ""),
            ("Close", "app.closePresentation"), ("Save", "file.save"), ("Save As…", "app.saveAsDialog"),
            ("Export…", "app.exportDialog"), ("Print…", "app.print"), ("-", ""), ("Properties", "file.properties"),
            ("Passwords…", "file.passwords"),
        ]),
        menu("Edit", [
            ("Undo", "edit.undo"), ("Redo", "edit.redo"), ("-", ""), ("Cut", "edit.cut"), ("Copy", "edit.copy"),
            ("Paste", "edit.paste"), ("Paste and Match Formatting", "edit.pasteText"), ("Paste Special…", "app.pasteSpecial"),
            ("-", ""), ("Select All", "edit.selectAll"), ("Duplicate", "edit.duplicate"), ("Delete Slide", "slide.delete"),
            ("-", ""), ("Find…", "app.find"), ("Replace…", "app.replace"),
        ]),
        menu("View", [
            ("Normal", "view.normal"), ("Slide Sorter", "view.sorter"), ("Notes Page", "view.notesPage"),
            ("Outline View", "view.outline"), ("Reading View", "view.reading"), ("Slide Show", "show.start"), ("-", ""),
            ("Slide Master", "view.slideMaster"), ("Handout Master", "view.handoutMaster"), ("Notes Master", "view.notesMaster"),
            ("-", ""), ("Ruler", "view.ruler"), ("Gridlines", "view.gridlines"), ("Guides", "view.guides"),
            ("Grid Options…", "view.gridOptions"), ("-", ""), ("Zoom…", "view.zoomDialog"), ("Zoom In", "view.zoomIn"),
            ("Zoom Out", "view.zoomOut"), ("Fit to Window", "view.fit"), ("-", ""), ("Ribbon", "view.ribbon"), ("Collapse the Ribbon", "view.collapseRibbon"),
            ("Move Focus to the Ribbon", "view.focusRibbon"),
            ("New Window", "view.newWindow"),
        ]),
        menu("Insert", [
            ("New Slide", "slide.new"), ("Duplicate Slide", "slide.duplicate"), ("-", ""), ("Section", "section.add"),
            ("Text Box", "insert.textBox"), ("WordArt", "insert.wordArt"), ("Date and Time", "insert.dateTime"),
            ("Slide Number", "insert.slideNumber"), ("-", ""), ("Table…", "insert.table"), ("Chart", "insert.chart"),
            ("Picture from File…", "app.insertPictureDialog"), ("Photo Album…", "insert.photoAlbum"),
            ("Edit Photo Album…", "insert.photoAlbumEdit"), ("Audio from File…", "app.insertAudioDialog"),
            ("Video from File…", "app.insertVideoDialog"),
        ]),
        menu("Format", [
            ("Font…", "format.fontDialog"), ("Paragraph…", "format.paragraphDialog"), ("Bold", "format.bold"),
            ("Italic", "format.italic"), ("Underline", "format.underline"), ("-", ""), ("Align Left", "format.alignLeft"),
            ("Center", "format.alignCenter"), ("Align Right", "format.alignRight"), ("Justify", "format.justify"), ("-", ""),
            ("Size and Position…", "shape.sizePosition"), ("Right-to-Left Text Direction", "format.rtl"),
        ]),
        menu("Arrange", [
            ("Bring to Front", "arrange.bringToFront"), ("Send to Back", "arrange.sendToBack"),
            ("Bring Forward", "arrange.bringForward"), ("Send Backward", "arrange.sendBackward"), ("-", ""),
            ("Group", "arrange.group"), ("Ungroup", "arrange.ungroup"), ("Regroup", "arrange.regroup"), ("-", ""),
            ("Rotate Left 90°", "arrange.rotateLeft"), ("Rotate Right 90°", "arrange.rotateRight"),
            ("Flip Horizontal", "arrange.flipHorizontal"), ("Flip Vertical", "arrange.flipVertical"),
        ]),
        menu("Slide Show", [
            ("Play from Start", "show.fromStart"), ("Play from Current Slide", "show.fromCurrent"), ("-", ""),
            ("Hide Slide", "slide.hide"), ("Set Up Show…", "show.setup"),
        ]),
        menu("Help", [("About DeckCraft", "app.about"), ("Check for Updates…", "app.checkUpdates"), ("Command Palette", "app.palette")]),
    ]

    private static func menu(_ title: String, _ entries: [(String, String)]) -> Menu {
        Menu(title: title, entries: entries.map { $0.0 == "-" ? .separator : .command(label: $0.0, id: $0.1) })
    }
}

/// A deckcraft shortcut string (`Cmd+Shift+P`, `F5`, `Alt+F9`, `Cmd+=`) read into a key and modifiers,
/// without AppKit: the app turns it into a key equivalent.
public struct Shortcut: Sendable, Equatable {
    public var cmd = false
    public var shift = false
    public var alt = false
    public var ctrl = false
    /// The key: one character (`p`, `=`, `,`, lowercase for letters) or a named key (`F5`, `Enter`,
    /// `Delete`, `Escape`, `Tab`, `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`).
    public var key: String

    /// nil when the string has no key, or an unknown modifier.
    public init?(_ text: String) {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing "+" key (`Cmd++`) leaves two empty parts at the end.
        var keys = parts
        var key: String?
        if text.hasSuffix("++") {
            key = "+"
            keys = Array(parts.dropLast(2))
        } else if let last = parts.last, !last.isEmpty {
            key = last
            keys = Array(parts.dropLast())
        }
        guard let key else { return nil }
        for m in keys {
            switch m.lowercased() {
            case "cmd", "command": cmd = true
            case "shift": shift = true
            case "alt", "option", "opt": alt = true
            case "ctrl", "control": ctrl = true
            default: return nil
            }
        }
        self.key = key.count == 1 ? key.lowercased() : key
    }
}
