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

## P4: pictures and objects (2026-10-30)

- **`Pictures`:** the drawing group's BLIP store and the `Pictures` stream.
  - Each entry holds its blip or points into the stream. A blip becomes a complete file:
    - JPEG, PNG and TIFF as stored;
    - a DIB with the BITMAPFILEHEADER that makes it a `.bmp`;
    - EMF inflated;
    - WMF inflated, with the placeable header, its bounds from the blip's header;
    - PICT with the 512-byte header a PICT file starts with.
  - The WMF and PICT headers are the ones Apache POI adds, so the bytes can be compared with POI's.
  - Inflating stops at 256 MB.
  - **Encrypted files:** each field of a blip is encrypted on its own, as block 0. The fields are the header, each
    16-byte id, a metafile's 34-byte header or a bitmap's tag byte, and then the picture. This is how POI reads
    them, and PowerPoint's own encrypted files read correctly this way. Treating the blip as one RC4 stream doesn't.
  - **PICT:** macOS can't draw PICT any more, so it is converted.
    - A PICT holding a JPEG becomes that JPEG. PowerPoint for Mac stored photos this way, using QuickTime's opcode
      0x8200, and AppKit draws those as a single colour.
    - Any other PICT is drawn by AppKit's `NSPICTImageRep` and kept as PNG. This goes through
      `PPTHooks.pict`, supplied by DCEngine's `LegacyPictures`, so DCPPT itself doesn't use AppKit.
    - The crash corpus has PICT pictures in about 6% of its files.
  - **Patterns:** a pattern fill's bitmap is matched against DCRender's preset tiles, dark pixels as the foreground.
    This goes through `PPTHooks.pattern`. All six patterns in PowerPoint's save of the pictures deck come back as
    their presets.
- **`PictureMedia`:** a picture is added to the presentation only when a shape, a fill or a background uses it, and
  only once.
- **`ShapeProps`:**
  - **Picture fills:** a texture (type 2) is tiled at its own size; a picture (type 3) is stretched.
  - **A picture's own properties:** the crop, as fractions; the transparent colour; contrast (0x10000 leaves it
    unchanged); brightness (±0x8000); greyscale; and black and white.
  - **Placeholders:** a placeholder now takes fill and line from its master's placeholder (hspMaster) too. This
    fixes a P3 bug: in PowerPoint's own files, title placeholders drew an outline their master turns off.
- **Backgrounds:** a background's fill now goes through `ShapeProps`, so it can be a gradient, a pattern, a picture
  or a texture as well as a solid colour.
- **`ExObjects`:** the document's ExObjList.
  - **OLE objects** (embedded, linked or ActiveX) become `opaque` shapes showing their preview, labelled with
    their program id or menu name. Saved as `.pptx` they are that picture; their data isn't carried over.
  - **Movies** (MCI, AVI) become a linked video. The path is turned into a `file:` URL, and the shape's picture is
    the poster.
  - **Sounds:** a WAV from the SoundCollection is embedded; a linked WAV or MIDI file is linked.
- **Comments:** each slide's Comment10Containers, found in its PowerPoint 2002 binary tag. A comment keeps its
  author, initials, text, date and position. PowerPoint 16 leaves comments out when it saves `.ppt`; LibreOffice
  keeps them.
- **The report:**
  - `asPictures` names each OLE object brought over as a picture.
  - `lostPictures` counts the pictures that couldn't be read, and `convertedPictures` the PICTs that were converted.
  - The status line says how many objects became pictures.
  - Picture bullets (PowerPoint 2000's BlipCollection9) aren't read. Neither the fixtures nor the crash corpus has
    any.
- **Checked:**
  - **Against POI:** every picture in every fixture's BLIP store has POI's bytes. So does every picture shape's
    picture, OLE preview, picture fill and picture background, and each crop matches. The report lists each of
    POI's OLE objects, and each slide's comments match POI's.
  - **PowerPoint's own pictures deck** (`Tools/legacy/picture-deck.py`, saved as a protected `.ppt`, local only)
    comes back as the original, picture by picture: the bytes, crop, brightness, contrast, greyscale, black and
    white, transparent colour, picture and tiled fills, pattern presets, and backgrounds.
  - **Hostile blips, objects and comments** are refused without trapping.
  - **An engine test:** a `.ppt` whose OLE charts become pictures, and which saves as `.pptx` with them.
  - **The crash corpus** with every slide rendered: 205 files open and render and 2 fail cleanly, with no crashes or
    time-outs. Across it, 83 PICT pictures were converted and no picture was lost.
  - **The alpha gate:** step 2b also opens and saves the pictures deck, in both layouts.

## P5: the slide show (2026-10-30)

- **Transitions** (`SlideShow.transition`): the slide's SlideShowSlideInfoAtom.
  - Its effect and direction map to our transition and option (PowerPoint 97's 22 effects). "Fade" is Fade through
    black and "AlphaFade" Fade smoothly; Strips is a diagonal Wipe; Box is Shape In or Out; Newsflash is Zoom and
    Rotate.
  - Its three speeds read as a `.pptx` that gives only `spd` does: fast 0.5 s, medium 0.75 s, slow 1 s (or the
    transition's own default when longer).
  - It also holds whether the slide advances on click and after a time, a sound from the SoundCollection (with
    loop), "stop previous sound", and whether the slide is hidden.
  - Cut not through black "is the same as no transition at all" (the spec): PowerPoint writes it for a hidden slide
    with no transition, so it reads as none.
  - PowerPoint 2010's transitions have no place in a `.ppt`. PowerPoint saves them as Fade, and that is what comes
    back.
- **Animations** (`SlideShow.animations`), from the newest place that is current:
  1. **PowerPoint 2002's timing tree**, in the slide's `___PPT10` binary tag, with its build list. The tree is
     PresentationML's `p:timing` as records, node for node, so `TimingTree` turns it into that element:
     - each node a `p:par`, `p:seq`, behaviour or media node;
     - its `p:cTn` from the TimeNodeAtom and its properties: preset class, id and subtype, node type, group, fill,
       restart and duration;
     - its modifiers (floats: a repeat of 2.0 is `repeatCount` 2000), its conditions and its targets;
     - the behaviours' values: scale (110 is 110%), rotation (degrees), the motion path, and the colour, with
       scheme colours resolved.

     DCPPTX's timing reader (`PPTXTiming`) then reads it as it reads a `.pptx`, so both map effects the same way.
     A target's character range becomes the paragraph that holds it.
  2. **The `p:timing` PowerPoint 2007 embedded** (RoundTripAnimationAtom, a package holding a timing part), read
     the same way. It's used only without a tree: PowerPoint 16 writes none, and a later PowerPoint 2002 or 2003
     save keeps an old one unchanged. Three files in the crash corpus have one. The plan had it first.
  3. **PowerPoint 97's AnimationInfoAtoms**, one per shape, mapped to the nearest entrance preset (Fly In with its
     eight directions, Wipe, Split, Blinds, Checkerboard, Random Bars, Strips, Box, Diamond, Wheel, Dissolve, Fade,
     Appear…). They play in their order, on click or after the previous one with its delay, and build by
     paragraph, word or letter.
  - **The hash:** the tree carries a hash of the slide's AnimationInfoAtoms (HashCode10Atom). If PowerPoint 97 or
    2000 changed the atoms after a newer version saved the tree, the hash no longer matches and the atoms win, as
    in PowerPoint. The spec's pseudocode hashes every shape; PowerPoint hashes only the shapes that have an atom
    (measured on its own file).
- **Checked:**
  - **The motion deck** (`Tools/legacy/motion-deck.py`) has 30 transitions at each speed, a slide that advances on
    its own, a hidden slide, 44 effects with their options, and a slide of timings and text builds.
    - **PowerPoint's save** of it (local only) comes back as the original: every transition by kind, option and
      speed, the advance and the hidden slide, and every animation's shape, effect, option, start, delay,
      duration, repeat, rewind, text build, paragraph, amount and path.
    - **LibreOffice's save** comes back the same, apart from how LibreOffice writes some of it. Each is checked
      in its records, and PowerPoint's save has none of them:
      - Cut through black as Cut, Push Right as Left, Uncover Left as Right, a diagonal Wipe as Cover, Shape In
        and Out as Cut, and Vortex and Ripple as Cut;
      - an advance time in 1024ths of a second, with "on click" kept;
      - a Pulse's and a Grow/Shrink's size as the change from 100%;
      - paths without their closing `E`;
      - no paragraph builds: each paragraph's effect is its own.
  - **PowerPoint's saves** of five more of the corpus's and engine's decks come back with their slide shows.
  - **Unit tests:** PowerPoint 97's effects, their order and their starts. The hash picks the tree while it
    matches and the atoms once it doesn't, and it equals the one in PowerPoint's own file. An embedded timing is
    read. Hostile records never trap: every byte of three real slides changed in turn, a tree nested 200 deep,
    and every effect type and direction.
  - **An engine test:** the motion deck opens with its transitions, hidden slide and Animation Pane, and saves as
    `.pptx` with them.
  - **The crash corpus** with every slide rendered: 205 files open and render and 2 fail cleanly, with no crashes or time-outs (9 min in Debug). Across it, 35 files bring over transitions (477 slides) and 65 bring over animations (1,733 effects); 3 slides are hidden.
  - **The alpha gate:** step 2b also opens the motion deck and plays its slide show, in both layouts.

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
  - Pictures and OLE objects came in P4.
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
