# DCPPT — notes

The legacy binary PowerPoint format (`.ppt`, `.pot`, `.pps`), read into DCModel, from [MS-PPT] v2026-02 (and
[MS-ODRAW] from P3) in `../OfficeFileFormatsProtocols`. **Not a port**: deckcraft has no `.ppt` reader (its
`docs/gaps.md`). ppt2pptx (MIT, Python) is consulted as prior art, and the specification is the authority. The plan
is `Docs/plans/Legacy-PPT-and-Encryption.md` (P1–P6). Depends on DCCFB (the compound file) and DCOffCrypto (RC4
CryptoAPI).

A `.ppt` is never edited in place: it opens as an untitled converted copy, and Save offers `.pptx` or `.deckcraft`
(§9.1 of the plan).

## P1: the container (2026-10-30)

- **`PPTFile`:**
  - `Current User` → the newest UserEditAtom → the edit chain backwards through `offsetLastEdit`. The chain must
    move backwards, visits each offset once, and stops at 4,096 edits.
  - The persist directories are merged oldest first, so a newer save's objects replace older ones. Records no
    directory reaches are dead and never read. `object(id)` returns a persist object's record, decrypted.
- **Which streams:**
  - `Current User` and `PowerPoint Document` at the root.
  - In a PowerPoint 95 "dual" file, the PowerPoint 97 copy in the `PP97_DUALSTORAGE` storage. [MS-PPT] doesn't
    describe it; Apache POI and ppt2pptx read it the same way.
  - A PowerPoint 95 file without that copy (it has `Header` or `PersistentStorage Directory`) is refused by name:
    "DeckCraft can't open PowerPoint 95 and earlier presentations".
- **Encryption** (RC4 CryptoAPI, `DCOffCrypto.RC4CryptoAPI`):
  - The newest UserEditAtom's `encryptSessionPersistIdRef` names the CryptSession10Container, whose data (the RC4
    CryptoAPI header) is in the clear.
  - Every other persist object is decrypted with its persist id as the block number. Its 8-byte record header is
    decrypted first, which gives its length, then its data in the same RC4 stream.
  - With no password given, PowerPoint 2003–2007 SP1's default password ("/01Hannes Ruescher/01", [MS-OFFCRYPTO]
    2.4.2.3) is tried, and only then is the password asked for. A typed password is kept with the document (Save
    As `.pptx` encrypts with it); the default password isn't.
- **`PPT.importChecked`:**
  - The DocumentAtom's slide and notes sizes (master units of 1/576 inch, so points are units ÷ 8, clamped to 1–56
    inches).
  - The slide list: SlidePersistAtoms in the SlideListWithTextContainer of instance 0.
  - Each slide becomes a blank slide of the default master. A slide whose record can't be read is still counted, and
    `PPTReport.unreadSlides` lists it.
  - `PPTReport` also says what isn't brought over yet: text, shapes, pictures, masters and layouts, notes,
    transitions and animations.
- **Checked:**
  - Every `.ppt` fixture (60 from LibreOffice, 9 encrypted by POI, one with the default password) opens with the
    slide count and slide size POI reads.
  - PowerPoint 16's own 6 encrypted `.ppt` (local only) open with their password and ask without it.
  - Hand-built streams cover what no generator makes: an incremental save whose second edit replaces the document,
    a slide the directory lacks, and an edit chain pointing at itself.
  - The hostile fixtures and 400 seeded mutations never trap or hang.
  - **The crash corpus:** Govdocs1, 207 files, through `Tools/legacy/crash-run.sh`. 205 open and 2 fail cleanly (a
    PowerPoint 95 file, and a compound file POI and ppt2pptx can't read either). None crashes or times out.
- **In the engine:**
  - `FileCommands.openFile` sends a `.ppt` to `openPPT`. It opens untitled.
  - `file.open`'s reply carries `converted` (the report, only for a `.ppt`, so other replies stay deckcraft's), and
    the status line says what was converted and what wasn't.
  - The app declares `com.microsoft.powerpoint.ppt`, `.pot` and `.pps` with the Viewer role, and the Open dialog
    and canvas drops accept them.

## P2a: text (2026-10-30)

- **`Drawing`:** each slide's OfficeArtDgContainer, walked in z-order.
  - Group children are mapped through each group's FSPGR space into slide coordinates, groups nesting at most 64
    deep.
  - Deleted shapes are skipped.
  - Each shape keeps its OfficeArtFSP id, type and flags, its client or child anchor, its PlaceholderAtom and its
    client-textbox records.
- **`PPTText`:** the TextHeaderAtom's type, the characters, and the StyleTextPropAtom.
  - **Paragraph runs:** count, indent level, then a TextPFException whose present fields follow its masks in the
    specification's order. They give bulletFlags, bulletChar, alignment and tab stops; the rest is stepped over.
  - **Character runs:** count, then a TextCFException giving fontStyle (bold, italic, underline), fontRef, size, and
    a colour (RGB when its index is 0xFE). The East Asian, ANSI and symbol font refs, position and the PP10/PP11
    extension fields are stepped over.
  - Both run arrays run until they cover the text plus one, and a run that would read past the record ends them.
- **`PPT.textShape`:**
  - A shape with text, or a placeholder, becomes a rectangle with its box (points = master units ÷ 8), its flips,
    its placeholder and its text.
  - Text reached through an OutlineTextRefAtom comes from the slide list's text for that slide.
  - Shapes without text wait for P3.
- **Notes:** the notes-body placeholder (type 0x0C) of the NotesContainer whose NotesAtom names the slide.
- **Checked:** POI's reading of every fixture and of PowerPoint's own files, slide by slide and shape by shape:
  text, boxes and notes all match.

## P3: shapes (2026-10-30)

- **`Drawing`:**
  - `tree` keeps groups as groups, each child's box in its group's space; `shapes` still flattens, for notes pages.
  - Every FOPT and tertiary FOPT property is kept, with the complex data after the entries. An IMsoArray whose
    length leaves out its 6-byte header, as LibreOffice writes it, is corrected.
  - It also reads the OfficeArtClientData's records, the solver container's connector rules, and the drawing
    group's default properties.
- **`ShapeProps`:**
  - A property's value comes from the shape, then the master shape it names (hspMaster), then the drawing group's
    defaults. Boolean properties are read flag by flag through their fUse bits.
  - It gives the shape's colours, fill, line, shadow and text frame as DCModel.
- **`LegacyShapes`:** the 203 MSOSPT types as DrawingML presets.
  - Every conversion PowerPoint uses was derived from PowerPoint's own save of the preset deck, wide, tall and
    moved: the inverse of what it wrote.
  - The legacy defaults are the values PowerPoint leaves out.
  - `warp` maps the WordArt types.
- **`ShapeBuilder`:**
  - ShapeIds are given to every drawn shape first, so a connector can name a shape drawn after it.
  - It builds groups, connectors, tables (`TableBuilder`) and WordArt, and runs the text through P2's readers with
    the shape's frame over it.
  - Pictures and OLE objects are left for P4.
- **`Freeform`:** pVertices (2- or 4-byte coordinates) walked by pSegmentInfo.
  - Handled: lines, curves, moves, closes and ends; noFill and noLine; elliptical quadrants; quadratic Béziers.
  - Arcs and angle ellipses are drawn straight.
  - A path is capped at 100,000 commands.
- **Checked:** `ShapeTests` (against POI's dump, PowerPoint's preset save and LibreOffice's, and hostile property
  data), the text and formatting tests on the flattened shapes, the alpha gate's new `.ppt` step, and the crash
  corpus with rendering.

## P2b: masters, styles and the rest of the text (2026-10-30)

- **`MasterStyles`:** the TextMasterStyleAtoms of the Environment, with the main master's over them, by text type and
  level.
  - A level takes what it doesn't set from the level above it, as PowerPoint writes and POI reads.
  - Types 5–8 (center body, center title, half body, quarter body) are differences from title or body. A shape of
    one of those types carries its differences as its own list style.
- **`Masters`:**
  - Master ids from the masters' slide list. Each slide's SlideAtom (masterIdRef at 12, SlideFlags at 20) says which
    master it follows and whether it follows that master's scheme and background.
  - Colour schemes come from ColorSchemeAtom instance 1.
  - Backgrounds are the drawing's fBackground shape: its fill type and colour from the FOPT, solid only.
  - `themeColors` maps the eight PowerPoint colours onto the theme's twelve.
- **`Document`:** headers and footers (HeadersFootersContainer, instance 3), and hyperlinks (each ExHyperlink's
  target and location).
- **`Drawing`:** keeps each shape's simple FOPT properties, and finds the background shape (P3 keeps them all).
- **`PF` and `CF`** are shared by the text runs and the master styles.
  - `PF` now reads every TextPFException field: bullet flags, character, font, size and colour; alignment; line
    spacing and spacing before and after; margin and indent; and the default tab.
  - `CF` adds the East Asian, complex-script and symbol font refs.
  - Both convert to DCModel properties against a `TextContext`, which holds the fonts, the slide's scheme and the
    master's styles.
  - The indent is the bullet position minus the text position; for whichever of the two a paragraph doesn't set, the
    value comes from the shape's TextRulerAtom, then the master.
- **`PPTText.ruler`:** the TextRulerAtom's margins and indents by level.
- **Checked:**
  - `FormattingTests`: all 17,980 paragraph and run properties of every `.ppt` fixture and of PowerPoint's own files
    match POI's `format-ppt`.
  - The text and box test still passes.
  - The crash corpus, with every slide rendered, is clean.
