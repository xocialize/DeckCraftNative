// DCAppModel — where each group of deckcraft's ribbon (`crates/ui-egui/src/ribbon.rs`; MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) lives on the Mac, with the commands its controls run. The
// ribbon is dropped (PLAN.md, "Decided"); its controls become inspector sections, toolbar items, menu items
// or dialogs. PORT-NOTES.md's table is this one, and a test checks that every command named here is a
// registry or UI command.
public enum RibbonMap {
    /// One ribbon group: its tab and name, where it is now, and the commands its controls run.
    public struct Group: Sendable, Equatable {
        public var tab: String
        public var group: String
        public var place: String
        public var commands: [String]
    }

    static func g(_ tab: String, _ group: String, _ place: String, _ commands: [String]) -> Group {
        Group(tab: tab, group: group, place: place, commands: commands)
    }

    public static let groups: [Group] = [
        // Home
        g("Home", "Clipboard", "Edit menu (Cut, Copy, Paste, Paste and Match Formatting, Paste Special…); Format Painter and Paste Formatting: inspector Format (and ⇧⌘C)", ["edit.paste", "edit.pasteText", "app.pasteSpecial", "format.painterApply", "edit.cut", "edit.copy", "format.painter"]),
        g("Home", "Slides", "toolbar: New Slide (split: layouts, Duplicate, Slides from Outline…, Reuse Slides…, sections); inspector Slide ▸ Slide (Layout, Reset)", ["slide.new", "slide.layout", "slide.reset", "section.add", "section.removeAll", "slide.duplicate", "app.reuseSlidesDialog", "app.dialog"]),
        g("Home", "Font", "inspector Format ▸ Text ▸ Font", ["format.font", "format.size", "format.grow", "format.shrink", "format.clear", "format.bold", "format.italic", "format.underline", "format.strikethrough", "format.superscript", "format.subscript", "format.spacing", "format.case", "format.highlight", "format.color", "format.fontDialog", "font.rescan"]),
        g("Home", "Paragraph", "inspector Format ▸ Text ▸ Paragraph", ["format.bullets", "format.numbering", "format.outdent", "format.indent", "format.lineSpacing", "format.paragraphDialog", "format.columns", "format.alignLeft", "format.alignCenter", "format.alignRight", "format.justify", "format.direction", "format.anchor", "smartArt.fromText"]),
        g("Home", "Picture", "toolbar: Picture", ["app.insertPictureDialog"]),
        g("Home", "Drawing", "toolbar: Shape, Text Box; inspector Format ▸ Fill & Line (Shape Styles: the Quick Styles grid) and Effects; Arrange tab", ["shape.insert", "insert.textBox", "shape.quickStyle", "shape.fill", "shape.line", "shape.effects"]),
        g("Home", "Editing", "Edit menu: Find…, Replace…; Replace Fonts… is a dialog; inspector Arrange ▸ Selection Pane", ["app.find", "app.replace", "font.replace", "view.pane"]),
        g("Home", "Designer", "inspector Slide ▸ Design Ideas", ["design.applyIdea", "design.theme", "view.pane"]),
        // Insert
        g("Insert", "Slides", "toolbar: New Slide", ["slide.new"]),
        g("Insert", "Tables", "toolbar: Table (split: sizes, Insert Table… dialog, Draw Table tool)", ["insert.table", "app.dialog"]),
        g("Insert", "Images", "toolbar: Picture (split: Picture from File…, New/Edit Photo Album…); Screenshot not available (as deckcraft)", ["app.insertPictureDialog", "insert.photoAlbum", "insert.photoAlbumEdit"]),
        g("Insert", "Illustrations", "toolbar: Shape (split: the shapes gallery by category, freeform tools, Icons, WordArt), Chart (split: the chart types), SmartArt (dialog)", ["shape.insert", "insert.icon", "insert.chart", "insert.wordArt", "app.dialog"]),
        g("Insert", "Links", "inspector Slide ▸ Insert Zoom (Slide, Section, Summary); toolbar Shape ▸ Action Buttons, Action Settings… and Link… (dialogs)", ["insert.zoom", "insert.actionButton", "app.dialog"]),
        g("Insert", "Comments", "toolbar: Comment (dialog); inspector Review ▸ Comments", ["app.dialog"]),
        g("Insert", "Text", "toolbar: Text Box; Insert menu: WordArt, Date and Time, Slide Number; Header & Footer is a dialog", ["insert.textBox", "insert.wordArt", "insert.dateTime", "insert.slideNumber", "app.dialog"]),
        g("Insert", "Symbols", "dialogs: Equation, Symbol", ["app.dialog"]),
        g("Insert", "Media", "toolbar: Media (split: Video from File…, Audio from File…)", ["app.insertVideoDialog", "app.insertAudioDialog"]),
        // Draw
        g("Draw", "Tools, Pens, Convert", "toolbar Shape ▸ Draw (Select, the pens, Highlighter, Eraser: the session's ink tool; Ink to Shape); the canvas draws (Canvas area)", ["draw.inkToShape"]),
        // Design
        g("Design", "Themes", "inspector Slide ▸ Themes (gallery, Browse for Themes…)", ["design.theme", "app.browseThemeDialog"]),
        g("Design", "Variants", "inspector Slide ▸ Variants (gallery, Colors, Fonts, Effects, Background Styles; Customize… opens the dialogs)", ["design.variant", "design.colors", "design.fonts", "design.effects", "design.background"]),
        g("Design", "Customize", "inspector Slide ▸ Slide (Slide Size; Page Setup… dialog) and Format Background", ["design.slideSize", "design.background", "design.hideBackgroundGraphics", "app.dialog"]),
        g("Design", "Designer", "inspector Slide ▸ Design Ideas", ["design.applyIdea"]),
        // Transitions
        g("Transitions", "Preview", "inspector Animate ▸ Transition ▸ Preview (plays the show from the slide)", ["show.start"]),
        g("Transitions", "Transition to This Slide", "inspector Animate ▸ Transition (the gallery by category, Effect Options)", ["transition.set", "transition.options"]),
        g("Transitions", "Timing", "inspector Animate ▸ Transition ▸ Sound and Timing", ["transition.sound", "transition.timing", "transition.applyAll"]),
        // Animations
        g("Animations", "Preview", "inspector Animate ▸ Animations ▸ Preview", ["animation.preview"]),
        g("Animations", "Animation", "inspector Animate ▸ Animations (Effect, Effect Options, Sequence)", ["animation.set", "animation.options"]),
        g("Animations", "Advanced Animation", "inspector Animate ▸ Animations (Add Animation, Trigger, Animation Painter) and the Animation Pane", ["animation.add", "animation.timing", "animation.painter", "view.pane"]),
        g("Animations", "Timing", "inspector Animate ▸ Timing (Start, Duration, Delay); the pane's context menu reorders and removes", ["animation.timing", "animation.move", "animation.remove"]),
        // Slide Show
        g("Slide Show", "Start Slide Show", "toolbar: Play (split: Play from Start, from Current Slide, Presenter View, Set Up…); Slide Show menu", ["show.start", "show.fromStart", "show.fromCurrent", "show.presenter", "app.dialog"]),
        g("Slide Show", "Set Up", "Slide Show menu; inspector Slide ▸ Slide (Hide Slide) and Slide Show (Set Up Slide Show…, Custom Shows… dialogs)", ["slide.hide", "app.dialog"]),
        g("Slide Show", "Monitors", "inspector Slide ▸ Slide Show (Presenter View, Use Timings, Play Narrations, Show Media Controls)", ["show.presenter", "show.setup"]),
        // Record
        g("Record", "Record", "the show (Show area); Cameo and narration are not available (as deckcraft)", ["show.start"]),
        // Review
        g("Review", "Proofing", "inspector Review ▸ Proofing (Spelling…, Accessibility…, Language… dialogs) and Review ▸ Thesaurus", ["app.dialog", "review.thesaurusPane", "review.replaceWord"]),
        g("Review", "Compare", "inspector Review ▸ Revisions (Accept, Reject, End Review); Compare… dialog", ["app.compareDialog", "review.accept", "review.reject", "review.endCompare"]),
        g("Review", "Comments", "inspector Review ▸ Comments (New Comment dialog, Previous, Next, Reply, Resolve, Delete)", ["comment.prev", "comment.next", "comment.reply", "comment.resolve", "comment.delete", "app.dialog"]),
        // View
        g("View", "Presentation Views, Master Views, Show, Zoom, Window, Color", "View menu (Views area); master views also in inspector Slide ▸ Master Views", ["view.normal", "view.outline", "view.sorter", "view.notesPage", "view.slideMaster", "view.handoutMaster", "view.notesMaster", "view.closeMaster", "view.ruler", "view.gridlines", "view.guides", "view.gridOptions", "view.zoom", "view.fit", "view.newWindow", "view.grayscale", "view.dark"]),
        // Contextual
        g("Shape Format", "Insert Shapes", "toolbar: Shape, Text Box; inspector Arrange ▸ Edit Shape (Change Shape, Edit Points, Smooth Corners, Merge Shapes)", ["shape.insert", "insert.textBox", "shape.change", "shape.editPoints", "shape.smoothCorners", "shape.merge"]),
        g("Shape Format", "Shape Styles", "inspector Format ▸ Fill & Line (Shape Styles, fill, line) and Effects", ["shape.quickStyle", "shape.fill", "shape.line", "shape.effects", "view.pane"]),
        g("Shape Format", "WordArt Styles", "inspector Format ▸ Text ▸ Text Fill and Text Effects (Text Outline, Shadow, Transform)", ["format.color", "format.textTransparency", "format.textOutline", "format.textShadow", "format.textWarp"]),
        g("Shape Format", "Accessibility", "inspector Format ▸ Size ▸ Alt Text (and the Alt Text dialog)", ["shape.altText", "app.dialog"]),
        g("Shape Format", "Arrange", "inspector Arrange (order, align and distribute with Align to Slide, group, rotate, flip, the Selection Pane)", ["arrange.bringForward", "arrange.bringToFront", "arrange.sendBackward", "arrange.sendToBack", "arrange.align", "arrange.distribute", "arrange.group", "arrange.ungroup", "arrange.regroup", "arrange.rotateRight", "arrange.rotateLeft", "arrange.flipVertical", "arrange.flipHorizontal", "arrange.reorder", "selection.select", "selection.showAll", "selection.hideAll", "shape.visible", "shape.lock", "shape.rename"]),
        g("Shape Format", "Size", "inspector Format ▸ Size and Arrange ▸ Size (Height, Width, Rotation, Position, Size and Position…)", ["shape.resize", "shape.rotate", "shape.move", "shape.sizePosition"]),
        g("Picture Format", "Adjust", "inspector Format ▸ Picture (Corrections, Remove Background, Recolor, Artistic Effects, Set Transparent Color, Change Picture, Reset, Compress)", ["picture.removeBackground", "picture.adjust", "picture.recolor", "picture.transparentColor", "picture.artisticEffect", "app.changePictureDialog", "picture.reset", "picture.compress"]),
        g("Picture Format", "Picture Styles", "inspector Format ▸ Picture ▸ Picture Styles (style, Picture Border)", ["picture.style", "shape.line"]),
        g("Picture Format", "Size", "inspector Format ▸ Picture ▸ Crop; Format ▸ Size", ["picture.crop", "shape.change"]),
        g("Table Design", "Table Style Options, Table Styles, Draw Borders", "inspector Format ▸ Table (options, style, Shading, Borders with the pen, Draw Table and Eraser tools)", ["table.options", "table.style", "table.cellFill", "table.borders"]),
        g("Layout", "Rows & Columns, Merge, Cell Size, Alignment", "inspector Format ▸ Table", ["table.deleteColumn", "table.deleteRow", "edit.delete", "table.insertRowAbove", "table.insertRowBelow", "table.insertColumnLeft", "table.insertColumnRight", "table.merge", "table.split", "table.distributeRows", "table.distributeColumns", "table.cellAlign", "table.cellMargins", "format.alignLeft", "format.alignCenter", "format.alignRight"]),
        g("Chart Design", "Type, Data", "inspector Format ▸ Chart (Chart Type; Edit Data… dialog)", ["chart.type", "app.dialog"]),
        g("SmartArt Design", "Create Graphic, Layouts, SmartArt Styles", "inspector Format ▸ SmartArt (Text Pane, Add Shape, Promote, Demote, Insert Picture, Layouts, Convert, Colors, Style)", ["view.pane", "smartArt.addNode", "smartArt.removeNode", "smartArt.setNodes", "smartArt.promote", "smartArt.demote", "app.smartArtPictureDialog", "smartArt.layout", "smartArt.toText", "smartArt.toShapes", "smartArt.colors", "smartArt.style"]),
        g("Playback", "Preview, Editing, Video Options, Volume", "inspector Format ▸ Playback (Play/Pause, Trim… dialog, options, Volume)", ["media.toggle", "media.options", "app.dialog"]),
        g("Slide Master", "Edit Master, Master Layout, Edit Theme, Background, Close", "inspector Slide ▸ Slide Master", ["master.insertLayout", "master.deleteLayout", "master.preserve", "master.placeholders", "master.insertPlaceholder", "design.theme", "view.pane", "view.closeMaster", "app.dialog"]),
        g("Notes Master", "Placeholders, Background, Close", "inspector Slide ▸ Notes Master", ["notes.placeholders", "view.closeMaster"]),
        g("Handout Master", "Page Setup, Placeholders, Background, Close", "inspector Slide ▸ Handout Master", ["handout.placeholders", "view.closeMaster"]),
        // Title bar
        g("Title bar", "Quick Access Toolbar", "toolbar items, customisable; `app.qat` adds and removes them", ["app.qat"]),
        g("Title bar", "Search, Present, Comments, Light/Dark", "Help ▸ Command Palette; toolbar Play; toolbar Comment / Review tab; View ▸ Dark Mode", ["app.palette", "show.start", "view.pane", "view.dark"]),
    ]
}
