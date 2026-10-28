// DCAppModel — one-line descriptions of what commands do, for tooltips, the command palette and VoiceOver hints
// (Docs/plans/Ribbon-and-StartScreen.md §6, decision 3). They are written in our own words, from what our command
// does, never from another product's tooltips. The engine's `CommandSpec` stays as deckcraft has it (its English is
// compared byte for byte), so the descriptions live here, keyed by command id, and are translated from the
// Commands catalog as `help.<key>`. R1 fills it for every command the ribbon's regular tabs, the toolbar and the
// Quick Access Toolbar show; R2 adds the contextual tabs' and R4 the rest (menus and the palette only).
import DCEngine
import Foundation

public enum CommandHelp {
    /// English descriptions, keyed by command id, or by `id:<id param>` / `id:<pane param>` where one command opens
    /// many things (`app.dialog {id: smartart}`, `view.pane {pane: designer}`), as `CommandSymbols` is.
    public static let english: [String: String] = [
        // Clipboard and editing
        "edit.paste": "Put what you last cut or copied at the selection.",
        "edit.cut": "Remove the selection and keep it to paste elsewhere.",
        "edit.copy": "Keep a copy of the selection to paste elsewhere.",
        "edit.undo": "Take back the last change.",
        "edit.redo": "Make the change you took back again.",
        "format.painter": "Pick up the selection's formatting, then click text or a shape to give it the same look.",
        "app.find": "Search the presentation for text.",
        "app.replace": "Search for text and replace it with other text.",
        "app.palette": "Find any command by typing part of its name.",
        // Slides
        "slide.new": "Add a slide after the current one.",
        "slide.layout": "Change how the slide's placeholders are arranged.",
        "slide.reset": "Put the slide's placeholders back where its layout has them.",
        "section.add": "Start a section at the selected slide to organise the deck.",
        "slide.hide": "Leave the slide out of the slide show without deleting it.",
        // Font
        "format.font": "Choose the typeface for the selected text.",
        "format.size": "Set the size of the selected text in points.",
        "format.grow": "Make the selected text one step larger.",
        "format.shrink": "Make the selected text one step smaller.",
        "format.clear": "Remove the formatting from the selected text, leaving plain text.",
        "format.bold": "Make the selected text bold.",
        "format.italic": "Slant the selected text.",
        "format.underline": "Draw a line under the selected text.",
        "format.strikethrough": "Draw a line through the selected text.",
        "format.superscript": "Raise the selected text above the line, smaller.",
        "format.subscript": "Lower the selected text below the line, smaller.",
        "format.spacing": "Set how tightly the selected characters sit together.",
        "format.case": "Change the selected text to upper, lower, sentence or title case.",
        "format.highlight": "Mark the selected text with a background colour.",
        "format.color": "Change the colour of the selected text.",
        "format.fontDialog": "Open every font setting for the selected text in one place.",
        // Paragraph
        "format.bullets": "Start each paragraph with a bullet.",
        "format.numbering": "Number the paragraphs in order.",
        "format.outdent": "Move the paragraph out one list level.",
        "format.indent": "Move the paragraph in one list level.",
        "format.lineSpacing": "Set the space between lines of text.",
        "format.columns": "Split the text box's text into columns.",
        "format.alignLeft": "Line the paragraph up on the left edge.",
        "format.alignCenter": "Centre the paragraph between the edges.",
        "format.alignRight": "Line the paragraph up on the right edge.",
        "format.justify": "Spread the paragraph's lines to both edges.",
        "format.direction": "Turn or stack the text in its shape.",
        "format.anchor": "Place the text at the top, middle or bottom of its shape.",
        "smartArt.fromText": "Turn the selected list into a SmartArt diagram.",
        "format.paragraphDialog": "Open the indents, spacing and alignment settings for the paragraph.",
        // Insert
        "app.insertPictureDialog": "Place a picture from a file on the slide.",
        "shape.insert": "Draw a ready-made shape: lines, arrows, stars, callouts and more.",
        "insert.textBox": "Add a box you can type text in.",
        "insert.table": "Add a table of rows and columns.",
        "insert.chart": "Add a chart drawn from data you can edit.",
        "insert.photoAlbum": "Make a presentation from a set of pictures, a few per slide.",
        "insert.icon": "Add a simple drawn icon.",
        "insert.zoom": "Add a thumbnail that jumps to another slide or section during the show.",
        "insert.actionButton": "Add a button that goes to another slide or runs an action in the show.",
        "insert.wordArt": "Add decorative text with a ready-made style.",
        "insert.dateTime": "Show the date and time on the slide.",
        "insert.slideNumber": "Show the slide's number on the slide.",
        "app.insertVideoDialog": "Place a video from a file on the slide.",
        "app.insertAudioDialog": "Place a sound from a file on the slide.",
        "app.dialog:smartart": "Add a diagram that lays out a list, a process or a hierarchy.",
        "app.dialog:hyperlink": "Link the selection to a web page, a file or another slide.",
        "app.dialog:comment": "Leave a note on the slide for yourself or others.",
        "app.dialog:headerFooter": "Show a footer, the date or slide numbers on every slide.",
        "app.dialog:equation": "Add a mathematical equation.",
        "app.dialog:symbol": "Insert a character that isn't on the keyboard.",
        // Drawing
        "arrange.bringToFront": "Change the order of overlapping objects, group them, align or rotate them.",
        "shape.quickStyle": "Give the shape a ready-made combination of fill, outline and effects.",
        "shape.fill": "Fill the selected shape with a colour.",
        "shape.line": "Change the colour of the selected shape's outline.",
        "shape.effects": "Add a shadow, reflection, glow or soft edges to the shape.",
        "view.pane:selection": "List every object on the slide to select, hide or reorder them.",
        "view.pane:designer": "See layout ideas for the slide and apply one.",
        "view.pane:background": "Change the slide's background fill.",
        "view.pane:animation": "List the slide's animations in the order they play.",
        "view.pane:comments": "Show the comments on this presentation.",
        // Draw
        "tool.select": "Go back to selecting and moving objects.",
        "tool.ink": "Draw freehand on the slide with this pen, or erase what you drew.",
        "draw.inkToShape": "Turn freehand drawing into neat shapes.",
        // Design
        "design.theme": "Give the whole presentation a theme's colours, fonts and backgrounds.",
        "design.variant": "Use another colour set of the current theme.",
        "design.colors": "Choose the theme colours the presentation uses.",
        "design.fonts": "Choose the pair of theme fonts for headings and body text.",
        "design.effects": "Choose how the theme's shapes are shaded and outlined.",
        "design.background": "Pick a background style from the theme for every slide.",
        "design.slideSize": "Change the slides' shape, such as widescreen or standard.",
        // Transitions and animations
        "show.start": "Play the slide show.",
        "transition.set": "Choose how this slide appears in the show.",
        "transition.options": "Change the direction or variation of the transition.",
        "transition.sound": "Play a sound as this slide appears.",
        "transition.timing": "Set the transition's length and when the show moves to the next slide.",
        "transition.applyAll": "Give every slide this slide's transition and timing.",
        "animation.preview": "Play the slide's animations on the canvas.",
        "animation.set": "Choose how the selected object enters, stands out, leaves or moves.",
        "animation.options": "Change the direction or variation of the animation.",
        "animation.add": "Add another animation to the selected object.",
        "animation.timing": "Set when the animation starts, how long it lasts and what starts it.",
        "animation.painter": "Copy this object's animations, then click another object to give it the same.",
        // Slide show
        "show.fromStart": "Play the slide show from the first slide.",
        "show.fromCurrent": "Play the slide show from the current slide.",
        "show.presenter": "Use Presenter View, with notes and the next slide on your own screen.",
        "show.setup": "Choose how the show plays: its timings, narrations and media controls.",
        "app.dialog:customShow": "Make a show from a chosen set of slides.",
        "app.dialog:setupShow": "Choose the kind of show, the slides it plays and how it advances.",
        // Review
        "app.dialog:spelling": "Check the presentation for misspelled words.",
        "review.spelling": "Check the presentation for misspelled words.",
        "review.thesaurusPane": "Look up words with a similar meaning.",
        "app.dialog:accessibility": "Find things that make the presentation hard to read for people with disabilities.",
        "app.dialog:language": "Set the language used to check the selected text's spelling.",
        "comment.delete": "Remove the selected comment.",
        "comment.prev": "Go to the comment before this one.",
        "comment.next": "Go to the next comment.",
        "app.compareDialog": "Compare this presentation with another version and review the differences.",
        "review.accept": "Keep the changes found by Compare.",
        "review.endCompare": "Stop reviewing the differences and close the comparison.",
        // View
        "view.normal": "Edit one slide at a time, with the slides beside it.",
        "view.outline": "Edit the deck's text as an outline beside the slide.",
        "view.sorter": "See every slide as a thumbnail to reorder them.",
        "view.notesPage": "Edit the slide's speaker notes on a printable page.",
        "view.reading": "Play the show in this window, without the editing tools.",
        "view.slideMaster": "Edit the master and layouts that every slide is built on.",
        "view.handoutMaster": "Edit how printed handouts look.",
        "view.notesMaster": "Edit how printed notes pages look.",
        "view.ruler": "Show rulers above and beside the slide.",
        "view.gridlines": "Show a grid to line objects up.",
        "view.guides": "Show guides you can drag to line objects up.",
        "view.gridOptions": "Set the grid's spacing and how objects snap.",
        "view.notes": "Show the speaker notes under the slide.",
        "view.zoomDialog": "Choose how large the slide is shown.",
        "view.fit": "Show the whole slide in the window.",
        "view.newWindow": "Open another window on this presentation.",
        "view.grayscale": "Show the slides in shades of grey.",
        "view.dark": "Use the dark appearance.",
        "view.ribbon": "Switch between the ribbon and the toolbar with the inspector.",
        // File
        "file.new": "Start a new presentation.",
        "app.openDialog": "Open a presentation from a file.",
        "file.save": "Save the presentation.",
        "app.print": "Print the slides, handouts or notes.",
        "app.exportDialog": "Save a copy as a PDF, pictures, a video or another format.",
        "app.home": "Go to the start screen.",
    ]

    /// The key `c`'s description is under: `id:<id or pane param>` when there is one, else the command id.
    public static func key(_ c: CommandRef) -> String? {
        if let sub = c.params["id"]?.asStr ?? c.params["pane"]?.asStr, english["\(c.id):\(sub)"] != nil { return "\(c.id):\(sub)" }
        return english[c.id] != nil ? c.id : nil
    }

    /// The description to show for command `id`, translated, or nil when it has none yet.
    public static func description(_ id: String) -> String? { description(CommandRef(id)) }

    /// The description for a command with these parameters, translated, or nil when it has none yet.
    public static func description(_ c: CommandRef) -> String? {
        guard let k = key(c), let e = english[k] else { return nil }
        return Bundle.module.localizedString(forKey: "help.\(k)", value: e, table: "Commands")
    }

    /// deckcraft's shortcut text with the Mac's key glyphs ("Cmd+Shift+P" → "⇧⌘P").
    public static func glyphs(_ shortcut: String) -> String {
        var mods = "", key = shortcut
        for (name, glyph) in [("Ctrl+", "⌃"), ("Alt+", "⌥"), ("Shift+", "⇧"), ("Cmd+", "⌘")] where key.contains(name) {
            mods += glyph
            key = key.replacingOccurrences(of: name, with: "")
        }
        return mods + key
    }

    /// A tooltip (decision 3): the label with the shortcut in parentheses, then the description on its own line.
    public static func tip(_ c: CommandRef, label: String) -> String {
        let head = (findCommand(c.id)?.shortcut ?? UICommands.find(c.id)?.shortcut).map { "\(label) (\(glyphs($0)))" } ?? label
        guard let d = description(c) else { return head }
        return "\(head)\n\(d)"
    }
}
