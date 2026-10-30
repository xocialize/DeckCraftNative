// DCAppModel — the SF Symbol for a command, in one table for the toolbar, the Quick Access Toolbar and the ribbon
// (Docs/plans/Ribbon-and-StartScreen.md §4). The icons are Apple's SF Symbols, chosen for what the command does;
// none is drawn to look like another product's. deckcraft's own icon names (`qat.rs`' `QatItem.icon`) map here too.

public enum CommandSymbols {
    /// By command id, or by `id:<id param>` / `id:<pane param>` where one command opens many things
    /// (`app.dialog {id: smartart}`, `view.pane {pane: designer}`).
    static let table: [String: String] = [
        "slide.new": "plus.rectangle.on.rectangle",
        "shape.insert": "square.on.circle",
        "insert.textBox": "textformat",
        "insert.table": "tablecells",
        "insert.chart": "chart.bar",
        "app.dialog:smartart": "rectangle.3.group",
        "app.insertPictureDialog": "photo",
        "app.insertVideoDialog": "play.rectangle",
        "app.dialog:comment": "text.bubble",
        "show.start": "play.fill",
    ]

    /// The symbol for a command with these parameters, if it has one.
    public static func symbol(_ c: CommandRef) -> String? {
        if let sub = c.params["id"]?.asStr ?? c.params["pane"]?.asStr, let s = table["\(c.id):\(sub)"] { return s }
        return table[c.id]
    }

    /// The ribbon's controls, by control id: one command can be several controls (`show.start` previews, rehearses
    /// and records), so a control's own symbol wins over its command's.
    static let controls: [String: String] = [
        "home.paste": "doc.on.clipboard", "home.cut": "scissors", "home.copy": "doc.on.doc",
        "home.formatPainter": "paintbrush", "home.layout": "rectangle.split.3x1", "home.reset": "arrow.counterclockwise",
        "home.section": "rectangle.split.1x2", "home.fontFamily": "textformat", "home.fontSize": "textformat.size",
        "home.grow": "textformat.size.larger", "home.shrink": "textformat.size.smaller", "home.clear": "eraser",
        "home.bold": "bold", "home.italic": "italic", "home.underline": "underline",
        "home.strikethrough": "strikethrough", "home.superscript": "textformat.superscript", "home.subscript": "textformat.subscript",
        "home.spacing": "character", "home.case": "textformat.alt", "home.highlight": "highlighter",
        "home.fontColor": "paintbrush.pointed", "home.fontDialog": "ellipsis.rectangle", "home.bullets": "list.bullet",
        "home.numbering": "list.number", "home.outdent": "decrease.indent", "home.indent": "increase.indent",
        "home.lineSpacing": "arrow.up.and.down.text.horizontal", "home.columns": "rectangle.split.2x1", "home.alignLeft": "text.alignleft",
        "home.alignCenter": "text.aligncenter", "home.alignRight": "text.alignright", "home.justify": "text.justify",
        "home.direction": "rotate.right", "home.anchor": "align.vertical.center", "home.convertSmartArt": "rectangle.3.group",
        "home.paragraphDialog": "paragraphsign", "home.arrange": "square.3.layers.3d", "home.quickStyles": "paintpalette",
        "home.shapeFill": "drop.fill", "home.shapeOutline": "pencil.line", "home.shapeEffects": "sparkles",
        "home.find": "magnifyingglass", "home.replace": "arrow.left.arrow.right", "home.selectionPane": "square.stack.3d.up",
        "home.designer": "wand.and.stars", "insert.pictures": "photo.on.rectangle", "insert.photoAlbum": "photo.stack",
        "insert.icons": "star.square", "insert.zoom": "plus.magnifyingglass", "insert.link": "link",
        "insert.action": "cursorarrow.click", "insert.headerFooter": "rectangle.topthird.inset.filled", "insert.wordArt": "textformat.abc",
        "insert.dateTime": "calendar", "insert.slideNumber": "number", "insert.equation": "function",
        "insert.symbol": "keyboard", "insert.video": "film", "insert.audio": "speaker.wave.2",
        "draw.select": "cursorarrow", "draw.eraser": "eraser", "draw.blackPen": "pencil.tip",
        "draw.redPen": "pencil.tip", "draw.bluePen": "pencil.tip", "draw.pencil": "pencil",
        "draw.highlighter": "highlighter", "draw.inkToShape": "scribble.variable", "design.themes": "paintpalette",
        "design.variants": "swatchpalette", "design.colors": "circle.lefthalf.filled", "design.fonts": "textformat",
        "design.effects": "sparkles", "design.background": "rectangle.fill", "design.slideSize": "aspectratio",
        "design.formatBackground": "photo.artframe", "design.designer": "wand.and.stars", "transitions.preview": "play",
        "transitions.gallery": "square.on.square", "transitions.effectOptions": "slider.horizontal.3", "transitions.sound": "speaker.wave.2",
        "transitions.duration": "timer", "transitions.onClick": "cursorarrow.click", "transitions.after": "clock",
        "transitions.applyAll": "square.grid.3x3", "animations.preview": "play", "animations.gallery": "sparkle",
        "animations.effectOptions": "slider.horizontal.3", "animations.add": "plus.circle", "animations.pane": "list.bullet.below.rectangle",
        "animations.trigger": "bolt", "animations.painter": "paintbrush", "animations.start": "play.circle",
        "animations.duration": "timer", "animations.delay": "clock", "slideShow.fromStart": "play.rectangle",
        "slideShow.fromCurrent": "play", "slideShow.presenter": "person.crop.rectangle", "slideShow.customShow": "list.star",
        "slideShow.setUpShow": "gearshape", "slideShow.hide": "eye.slash", "slideShow.rehearse": "stopwatch",
        "slideShow.useTimings": "timer", "slideShow.narrations": "mic", "slideShow.mediaControls": "playpause",
        "record.fromBeginning": "record.circle", "record.fromCurrent": "record.circle", "review.spelling": "textformat.abc.dottedunderline",
        "review.thesaurus": "book", "review.checkAccessibility": "accessibility", "review.language": "globe",
        "review.newComment": "text.bubble", "review.delete": "trash", "review.previous": "chevron.left",
        "review.next": "chevron.right", "review.showComments": "bubble.left.and.bubble.right", "review.compare": "doc.on.doc", "review.protect": "lock", "file.passwords": "lock",
        "review.accept": "checkmark.circle", "review.endReview": "xmark.circle", "view.normal": "sidebar.left",
        "view.outline": "list.bullet.indent", "view.sorter": "square.grid.2x2", "view.notesPage": "note.text",
        "view.reading": "book", "view.slideMaster": "rectangle.stack", "view.handoutMaster": "doc.text",
        "view.notesMaster": "note.text", "view.ruler": "ruler", "view.gridlines": "grid",
        "view.guides": "squareshape.split.2x2.dotted", "view.gridOptions": "slider.horizontal.3", "view.notes": "note.text",
        "view.zoom": "plus.magnifyingglass", "view.fit": "arrow.up.left.and.arrow.down.right", "view.newWindow": "macwindow.badge.plus",
        "view.grayscale": "circle.lefthalf.filled", "view.dark": "moon",
        // R2: the contextual tabs.
        "shapeFormat.editShape": "pencil.and.outline", "shapeFormat.merge": "square.on.circle", "shapeFormat.quickStyles": "paintpalette",
        "shapeFormat.fill": "drop.fill", "shapeFormat.outline": "pencil.line", "shapeFormat.effects": "sparkles",
        "shapeFormat.textFill": "paintbrush.pointed", "shapeFormat.textOutline": "a.square", "shapeFormat.textEffects": "wand.and.rays",
        "shapeFormat.altText": "text.below.photo", "shapeFormat.formatPane": "sidebar.right",
        "pictureFormat.removeBackground": "person.crop.rectangle", "pictureFormat.corrections": "sun.max", "pictureFormat.color": "paintpalette",
        "pictureFormat.artistic": "paintbrush", "pictureFormat.transparency": "circle.lefthalf.filled", "pictureFormat.change": "arrow.triangle.2.circlepath",
        "pictureFormat.reset": "arrow.counterclockwise", "pictureFormat.compress": "arrow.down.right.and.arrow.up.left", "pictureFormat.gallery": "photo.artframe",
        "pictureFormat.border": "square", "pictureFormat.altText": "text.below.photo", "pictureFormat.crop": "crop",
        "tableDesign.gallery": "tablecells", "tableDesign.shading": "drop.fill", "tableDesign.borders": "squareshape.split.3x3",
        "tableDesign.drawTable": "pencil", "tableDesign.eraser": "eraser",
        "tableLayout.delete": "trash", "tableLayout.insertAbove": "arrow.up.to.line", "tableLayout.insertBelow": "arrow.down.to.line",
        "tableLayout.insertLeft": "arrow.left.to.line", "tableLayout.insertRight": "arrow.right.to.line",
        "tableLayout.merge": "arrow.right.and.line.vertical.and.arrow.left", "tableLayout.split": "arrow.left.and.line.vertical.and.arrow.right",
        "tableLayout.distributeRows": "line.3.horizontal", "tableLayout.distributeColumns": "rectangle.split.3x1",
        "tableLayout.alignLeft": "text.alignleft", "tableLayout.alignCenter": "text.aligncenter", "tableLayout.alignRight": "text.alignright",
        "tableLayout.alignTop": "align.vertical.top", "tableLayout.alignMiddle": "align.vertical.center", "tableLayout.alignBottom": "align.vertical.bottom",
        "tableLayout.margins": "rectangle.inset.filled",
        "chartDesign.changeType": "chart.bar.xaxis", "chartDesign.editData": "tablecells",
        "smartArtDesign.textPane": "list.bullet.rectangle", "smartArtDesign.addShape": "plus.rectangle", "smartArtDesign.promote": "arrow.left",
        "smartArtDesign.demote": "arrow.right", "smartArtDesign.insertPicture": "photo", "smartArtDesign.layouts": "rectangle.3.group",
        "smartArtDesign.convert": "arrow.triangle.2.circlepath", "smartArtDesign.colors": "paintpalette", "smartArtDesign.gallery": "cube",
        "playback.play": "play.fill", "playback.trim": "scissors", "playback.volume": "speaker.wave.2",
        "slideMaster.insertLayout": "rectangle.badge.plus", "slideMaster.delete": "trash", "slideMaster.rename": "character.cursor.ibeam",
        "slideMaster.insertPlaceholder": "rectangle.dashed", "slideMaster.themes": "paintpalette", "slideMaster.background": "rectangle.fill",
        "slideMaster.close": "xmark.rectangle", "notesMaster.background": "rectangle.fill", "notesMaster.close": "xmark.rectangle",
        "handoutMaster.perPage": "square.grid.3x2", "handoutMaster.background": "rectangle.fill", "handoutMaster.close": "xmark.rectangle",
    ]

    /// The object tabs' shared Arrange and Size controls (`arrange.rs`), by the part of their id after the tab.
    static let shared: [String: String] = [
        "bringForward": "square.2.layers.3d.top.filled", "sendBackward": "square.2.layers.3d.bottom.filled", "selectionPane": "square.stack.3d.up",
        "align": "align.horizontal.left", "group": "rectangle.3.group", "rotate": "rotate.right",
        "height": "arrow.up.and.down", "width": "arrow.left.and.right", "sizePosition": "arrow.up.left.and.arrow.down.right",
    ]

    /// The symbol for ribbon control `id`, if it has its own.
    public static func symbol(control id: String) -> String? {
        if let s = controls[id] { return s }
        return id.split(separator: ".").last.flatMap { shared[String($0)] }
    }

    /// deckcraft's QAT icon names as SF Symbols.
    public static func symbol(icon: String) -> String {
        switch icon {
        case "home": "house"
        case "file": "doc"
        case "folder": "folder"
        case "save": "square.and.arrow.down"
        case "print": "printer"
        case "undo": "arrow.uturn.backward"
        case "redo": "arrow.uturn.forward"
        case "playFromStart": "play.rectangle"
        case "search": "magnifyingglass"
        case "spelling": "textformat.abc.dottedunderline"
        case "export": "square.and.arrow.up"
        case "table": "tablecells"
        case "chart": "chart.bar"
        case "picture": "photo"
        default: "ellipsis.circle"
        }
    }
}
