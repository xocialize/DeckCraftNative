// DCAppModel — where each group of deckcraft's ribbon (`crates/ui-egui/src/ribbon.rs`; MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors) lives in the Mac layout, with the commands its controls run.
// The ribbon is an optional window layout (Docs/plans/Ribbon-and-StartScreen.md); in the Mac layout its controls
// are inspector sections, toolbar items, menu items or dialogs. Each group's commands are derived from
// `RibbonLayout`: the ribbon groups or controls it names, plus the commands its Mac place runs beyond them
// (`extra`). The canvas's tools (`tool.*`) aren't commands, so they're left out. PORT-NOTES.md's table is this
// one, and tests check that every command named here is a registry or UI command.
public enum RibbonMap {
    /// One ribbon group: its tab and name, where it is in the Mac layout, and the commands its controls run.
    public struct Group: Sendable, Equatable {
        public var tab: String
        public var group: String
        public var place: String
        /// The `RibbonLayout` groups or controls it covers.
        public var layout: [String]
        public var commands: [String]
    }

    static func g(_ tab: String, _ group: String, _ place: String, _ layout: [String], extra: [String] = []) -> Group {
        var commands: [String] = []
        for c in layout.flatMap({ RibbonLayout.commands(of: $0) ?? [] }) + extra where !c.hasPrefix("tool.") && !commands.contains(c) {
            commands.append(c)
        }
        return Group(tab: tab, group: group, place: place, layout: layout, commands: commands)
    }

    public static let groups: [Group] = [
        // Home
        g("Home", "Clipboard", "Edit menu (Cut, Copy, Paste, Paste and Match Formatting, Paste Special…); Format Painter and Paste Formatting: inspector Format (and ⇧⌘C)", ["home.clipboard"]),
        g("Home", "Slides", "toolbar: New Slide (split: layouts, Duplicate, Slides from Outline…, Reuse Slides…, sections); inspector Slide ▸ Slide (Layout, Reset)", ["home.slides"]),
        g("Home", "Font", "inspector Format ▸ Text ▸ Font", ["home.font"]),
        g("Home", "Paragraph", "inspector Format ▸ Text ▸ Paragraph", ["home.paragraph"]),
        g("Home", "Picture", "toolbar: Picture", ["home.picture"]),
        g("Home", "Drawing", "toolbar: Shape, Text Box; inspector Format ▸ Fill & Line (Shape Styles: the Quick Styles grid) and Effects; Arrange tab", ["home.shapes", "home.textBox", "home.drawing"]),
        g("Home", "Editing", "Edit menu: Find…, Replace…; Replace Fonts… is a dialog; inspector Arrange ▸ Selection Pane", ["home.editing"]),
        g("Home", "Designer", "inspector Slide ▸ Design Ideas", ["home.designer"]),
        // Insert
        g("Insert", "Slides", "toolbar: New Slide", ["insert.slides"]),
        g("Insert", "Tables", "toolbar: Table (split: sizes, Insert Table… dialog, Draw Table tool)", ["insert.tables"]),
        g("Insert", "Images", "toolbar: Picture (split: Picture from File…, New/Edit Photo Album…); Screenshot not available (as deckcraft)", ["insert.images"]),
        g("Insert", "Illustrations", "toolbar: Shape (split: the shapes gallery by category, freeform tools, Icons, WordArt), Chart (split: the chart types), SmartArt (dialog)", ["insert.illustrations"]),
        g("Insert", "Links", "inspector Slide ▸ Insert Zoom (Slide, Section, Summary); toolbar Shape ▸ Action Buttons, Action Settings… and Link… (dialogs)", ["insert.links"]),
        g("Insert", "Comments", "toolbar: Comment (dialog); inspector Review ▸ Comments", ["insert.comments"]),
        g("Insert", "Text", "toolbar: Text Box; Insert menu: WordArt, Date and Time, Slide Number; Header & Footer is a dialog", ["insert.text"]),
        g("Insert", "Symbols", "dialogs: Equation, Symbol", ["insert.symbols"]),
        g("Insert", "Media", "toolbar: Media (split: Video from File…, Audio from File…)", ["insert.media"]),
        // Draw
        g("Draw", "Tools, Pens, Convert", "toolbar Shape ▸ Draw (Select, the pens, Highlighter, Eraser: the session's ink tool; Ink to Shape); the canvas draws (Canvas area)", ["draw.tools", "draw.pens", "draw.convert"]),
        // Design
        g("Design", "Themes", "inspector Slide ▸ Themes (gallery, Browse for Themes…)", ["design.themes"]),
        g("Design", "Variants", "inspector Slide ▸ Variants (gallery, Colors, Fonts, Effects, Background Styles; Customize… opens the dialogs)", ["design.variants"]),
        g("Design", "Customize", "inspector Slide ▸ Slide (Slide Size; Page Setup… dialog) and Format Background", ["design.customize"]),
        g("Design", "Designer", "inspector Slide ▸ Design Ideas", ["design.designer"]),
        // Transitions
        g("Transitions", "Preview", "inspector Animate ▸ Transition ▸ Preview (plays the show from the slide)", ["transitions.preview"]),
        g("Transitions", "Transition to This Slide", "inspector Animate ▸ Transition (the gallery by category, Effect Options)", ["transitions.transition"]),
        g("Transitions", "Timing", "inspector Animate ▸ Transition ▸ Sound and Timing", ["transitions.timing"]),
        // Animations
        g("Animations", "Preview", "inspector Animate ▸ Animations ▸ Preview", ["animations.preview"]),
        g("Animations", "Animation", "inspector Animate ▸ Animations (Effect, Effect Options, Sequence)", ["animations.animation"]),
        g("Animations", "Advanced Animation", "inspector Animate ▸ Animations (Add Animation, Trigger, Animation Painter) and the Animation Pane", ["animations.advanced"]),
        g("Animations", "Timing", "inspector Animate ▸ Timing (Start, Duration, Delay); the pane's context menu reorders and removes", ["animations.timing"], extra: ["animation.move", "animation.remove"]),
        // Slide Show
        g("Slide Show", "Start Slide Show", "toolbar: Play (split: Play from Start, from Current Slide, Presenter View, Set Up…); Slide Show menu", ["slideShow.start"], extra: ["show.start"]),
        g("Slide Show", "Set Up", "Slide Show menu; inspector Slide ▸ Slide (Hide Slide) and Slide Show (Set Up Slide Show…, Custom Shows… dialogs)", ["slideShow.setUp"]),
        g("Slide Show", "Monitors", "inspector Slide ▸ Slide Show (Presenter View, Use Timings, Play Narrations, Show Media Controls)", ["slideShow.presenter", "slideShow.options"]),
        // Record
        g("Record", "Record", "the show (Show area); Cameo and narration are not available (as deckcraft)", ["record.record"]),
        // Review
        g("Review", "Proofing", "inspector Review ▸ Proofing (Spelling…, Accessibility…, Language… dialogs) and Review ▸ Thesaurus", ["review.proofing", "review.accessibility", "review.language"]),
        g("Review", "Protect", "File ▸ Passwords… (the Passwords sheet)", ["review.protect"]),
        g("Review", "Compare", "inspector Review ▸ Revisions (Accept, Reject, End Review); Compare… dialog", ["review.compare"]),
        g("Review", "Comments", "inspector Review ▸ Comments (New Comment dialog, Previous, Next, Reply, Resolve, Delete)", ["review.comments"]),
        // View
        g("View", "Presentation Views, Master Views, Show, Zoom, Window, Color", "View menu (Views area); master views also in inspector Slide ▸ Master Views", ["view.views", "view.masters", "view.show", "view.zoom", "view.window", "view.color"]),
        // Contextual
        g("Shape Format", "Insert Shapes", "toolbar: Shape, Text Box; inspector Arrange ▸ Edit Shape (Change Shape, Edit Points, Smooth Corners, Merge Shapes)", ["shapeFormat.insertShapes"]),
        g("Shape Format", "Shape Styles", "inspector Format ▸ Fill & Line (Shape Styles, fill, line) and Effects", ["shapeFormat.shapeStyles", "shapeFormat.pane"]),
        g("Shape Format", "WordArt Styles", "inspector Format ▸ Text ▸ Text Fill and Text Effects (Text Outline, Shadow, Transform)", ["shapeFormat.wordArt"]),
        g("Shape Format", "Accessibility", "inspector Format ▸ Size ▸ Alt Text (and the Alt Text dialog)", ["shapeFormat.accessibility"]),
        g("Shape Format", "Arrange", "inspector Arrange (order, align and distribute with Align to Slide, group, rotate, flip, the Selection Pane)", ["shapeFormat.arrange"]),
        g("Shape Format", "Size", "inspector Format ▸ Size and Arrange ▸ Size (Height, Width, Rotation, Position, Size and Position…)", ["shapeFormat.size"]),
        g("Picture Format", "Adjust", "inspector Format ▸ Picture (Corrections, Remove Background, Recolor, Artistic Effects, Set Transparent Color, Change Picture, Reset, Compress)", ["pictureFormat.adjust"]),
        g("Picture Format", "Picture Styles", "inspector Format ▸ Picture ▸ Picture Styles (style, Picture Border)", ["pictureFormat.styles"]),
        g("Picture Format", "Size", "inspector Format ▸ Picture ▸ Crop; Format ▸ Size", ["pictureFormat.crop", "pictureFormat.size"]),
        g("Table Design", "Table Style Options, Table Styles, Draw Borders", "inspector Format ▸ Table (options, style, Shading, Borders with the pen, Draw Table and Eraser tools)", ["tableDesign.options", "tableDesign.styles", "tableDesign.drawBorders"]),
        g("Layout", "Rows & Columns, Merge, Cell Size, Alignment", "inspector Format ▸ Table", ["tableLayout.rowsColumns", "tableLayout.merge", "tableLayout.cellSize", "tableLayout.alignment"]),
        g("Chart Design", "Type, Data", "inspector Format ▸ Chart (Chart Type; Edit Data… dialog)", ["chartDesign.type", "chartDesign.data"]),
        g("SmartArt Design", "Create Graphic, Layouts, SmartArt Styles", "inspector Format ▸ SmartArt (Text Pane, Add Shape, Promote, Demote, Insert Picture, Layouts, Convert, Colors, Style)", ["smartArtDesign.create", "smartArtDesign.layouts", "smartArtDesign.styles"]),
        g("Playback", "Preview, Editing, Video Options, Volume", "inspector Format ▸ Playback (Play/Pause, Trim… dialog, options, Volume)", ["playback.preview", "playback.editing", "playback.options"]),
        g("Slide Master", "Edit Master, Master Layout, Edit Theme, Background, Close", "inspector Slide ▸ Slide Master", ["slideMaster.edit", "slideMaster.layout", "slideMaster.theme", "slideMaster.background", "slideMaster.close"]),
        g("Notes Master", "Placeholders, Background, Close", "inspector Slide ▸ Notes Master", ["notesMaster.placeholders", "notesMaster.background", "notesMaster.close"]),
        g("Handout Master", "Page Setup, Placeholders, Background, Close", "inspector Slide ▸ Handout Master", ["handoutMaster.pageSetup", "handoutMaster.placeholders", "handoutMaster.background", "handoutMaster.close"]),
        // Title bar
        g("Title bar", "Quick Access Toolbar", "toolbar items, customisable; `app.qat` adds and removes them", [], extra: ["app.qat"]),
        g("Title bar", "Search, Present, Comments, Light/Dark", "Help ▸ Command Palette; toolbar Play; toolbar Comment / Review tab; View ▸ Dark Mode", [], extra: ["app.palette", "show.start", "view.pane", "view.dark"]),
    ]
}
