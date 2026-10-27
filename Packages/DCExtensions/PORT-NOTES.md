# DCExtensions — notes

The app's system extensions: a **Quick Look preview**, a **Quick Look thumbnail** and a **Spotlight importer** for
`.deckcraft`, `.pptx`, `.potx` and `.ppsx`. Not a port: deckcraft has no system extensions (its macOS bundle,
`packaging/macos/Info.plist.in`, only declares the document types). **Status: Wave 6, done (2026-10-27).**

## Layout

| Where | What |
|---|---|
| `Sources/DCExtensionKit` | `DeckReader` (a file through `FileCommands.openChecked` within a memory budget; the text-only read; the package thumbnail), `DeckLimits`, `DeckFileError`, `LargeStack` |
| `Sources/DCQuickLook` | `QuickLookPreview` (the PDF and the message page), `QuickLookThumbnail` (the first slide), `Resources/Localizable.xcstrings` (the messages) |
| `Sources/DCSpotlight` | `DeckIndex` (what Spotlight learns, and `apply(to:)` onto a `CSSearchableItemAttributeSet`) |
| `Tests/DCExtensionsTests` | over the oracle corpus and damaged files |
| `Apps/DeckCraftNative/Extensions/{QuickLook,Thumbnail,Spotlight}` | the three principal classes, one file each (synchronized folders) |
| `Apps/DeckCraftNative/Extensions/Support` | their `Info.plist`s (`NSExtension`) and entitlements |

The appex targets in `DeckCraftNative.xcodeproj` are `DeckCraftQuickLook` (`com.xocialize.deckcraftnative.QuickLook`,
links DCQuickLook), `DeckCraftThumbnail` (`….Thumbnail`, DCQuickLook) and `DeckCraftSpotlight` (`….Spotlight`,
DCSpotlight), embedded in the app's `Contents/PlugIns` by an *Embed Foundation Extensions* phase.

## Decisions

- **Preview: a data-based preview of a vector PDF.** `QLPreviewReply(dataOfContentType: .pdf, …)` with the PDF
  DCRender's export makes (`recordSlide` replayed through `DisplayList.draw`, the invisible text layer on top).
  Quick Look's own PDF view then scrolls, zooms (sharp at every size) and lists page thumbnails, and the slides'
  text can be found and selected — more than a view of our own would do, with no AppKit in the extension. Hidden
  slides are shown (a preview shows the file). The title is the document's (File › Properties), else the file
  name. At most `QuickLookPreview.maxSlides` (100) slides; the title then says "(first 100 of N slides)".
- **Thumbnail: the first slide rasterised at the exact pixel size asked** (context size × scale, longest side at
  most 2048 px), by `renderSlide`. A bitmap of the right size is as sharp as a vector replay and costs no more.
  The drawing block only draws the finished picture.
- **Spotlight: `CSImportExtension`** (Core Spotlight, macOS 12+). On macOS 26 this is the current mechanism for a
  third-party importer; `.mdimporter` bundles (`MDImporter` plug-ins) are the legacy format. Attributes:
  `title`, `subject`, `authorNames` (the author property split at `;`), `keywords` (split at `,` and `;`),
  `comment` (the document's comments property), `organizations` (company), `editors` (last modified by),
  `contributors` (the comments' authors), `contentCreationDate`/`contentModificationDate`, `pageCount` (slides),
  `pageWidth`/`pageHeight` (points), and `textContent`: every slide's title, the text of its shapes (groups,
  tables cell by cell, charts' titles, axis titles, series names and categories, SmartArt's shapes), the notes,
  and the comments with their replies.
- **Memory.** The extensions read with the engine (`FileCommands.openChecked`, as the app opens files), which
  holds the whole file and every picture in memory, so each has a budget (`DeckLimits`):
  - Spotlight never reads pictures: `DeckReader.readText` copies only the package's text parts (everything but
    `media/`, `ppt/media/`, `ppt/embeddings/`, `ppt/fonts/` and the package thumbnail, each part at most 32 MB,
    96 MB in all) into a new archive in memory and opens that. Missing media is damage the engine already
    tolerates, so slides, text, notes and comments read the same; the cost follows the text, not the file.
    At most 5,000 slides and 4 MB of text are indexed.
  - The thumbnail reads files up to 128 MB whole. A larger file gives the picture its package carries
    (`docProps/thumbnail.jpeg` or whatever `_rels/.rels` names; PowerPoint writes one, decoded no larger than
    asked), else its first slide read without pictures.
  - The preview reads files up to 512 MB whole; a larger one is previewed without its pictures, and says so.
- **Stack.** The PPTX reader and the renderer recurse per group level; the app runs them on the main thread's
  8 MB stack. An extension is called on a 512 KB thread, so every job runs on a 32 MB thread
  (`LargeStack`, as `PPTX.onLargeStack`). The tests' 200-deep group runs there too.
- **Damaged files** never throw out of the preview: they get a page naming the file and the reason (the engine's
  message as is). The thumbnail returns nothing (Quick Look shows the generic icon), unless the package has its
  own picture. The importer throws a `DeckFileError` (Spotlight keeps the file's name and system attributes).
- **Fonts.** A sandboxed extension can't read its containing app's bundle: `stat` succeeds (so `fileExists` says
  yes) but `open` fails with EPERM (NSCocoaErrorDomain 257, measured from the thumbnail extension on 2026-10-27, with
  no sandbox report in the log), so the app's bundled craft-fonts (`Contents/Resources/fonts/`) are out of reach and
  `ATSApplicationFontsPath` pointing there doesn't activate them either (tried). The preview and thumbnail
  extensions therefore carry the Latin set themselves: an *Embed Latin Fonts* copy phase puts `latin-manifest.txt`
  and its 14 families (Inter, Carlito, Caladea, Liberation Sans/Serif/Mono, Lato, Roboto, Open Sans, Montserrat,
  Poppins, Nunito Sans, Merriweather, Playfair Display: 17.5 MB, every family the built-in themes use) in their own
  `Contents/Resources/fonts/`, and `FontDB.bundledCraftFontsDir` looks in the running bundle's own Resources (app or
  appex). Each of the two appexes grows from 7.4 to 25 MB. The Spotlight extension lays nothing out and has none.
  `ExtensionFonts.prepare()` logs where the fonts came from (subsystem `com.xocialize.deckcraftnative`, category
  `fonts`): `…DeckCraftThumbnail.appex/Contents/Resources, 14 families, Inter true`. The thumbnail of `sample.deckcraft`
  now breaks "…when to / look, …" as the app and the oracle do.
- **Strings.** The preview's messages are in `DCQuickLook/Resources/Localizable.xcstrings` (`bundle: .module`), the
  engine's error text shown as is. The thumbnail and the importer show no text.

## Measurements (2026-10-27, M-series Mac, macOS 26 SDK 27.0)

- **Preview cost.** Release `dccli convert … .pdf` (the same read and `PDF.export`, at 200 dpi, process start
  included): sample.pptx (8 slides) 1.16 s, charts.pptx (6) 0.74 s, smartart.pptx (6) 0.61 s, effects.pptx (3, blurs
  drawn as rasters) 0.61 s, review.pptx (5) 0.46 s: 60–150 ms a slide, hence the 100-slide cap. A debug build is
  10–25× slower (effects.pptx 17 s), which is why the test suite takes about a minute.
- **Thumbnail cost.** `qlmanage -t -x -s 512`: 0.02–0.16 s a file, including the extension's launch.
- **Size.** In the Developer ID export the preview and thumbnail appexes are 25 MB each (7.4 MB of code: each links
  its own copy of the engine and renderer statically; 17.5 MB of Latin fonts) and the Spotlight one 7.4 MB.

## Verified (2026-10-27)

- `swift test --filter DCExtensionsTests`: 29 tests in 3 suites pass.
- `xcodebuild -list` shows the four targets; Debug and Release builds succeed; `Tools/release.sh --allow-dirty`
  archives, exports with the Developer ID and verifies the three appexes (`codesign --deep --strict`, hardened
  runtime, secure timestamp, sandbox and read-only entitlements).
- Quick Look, after `lsregister -f` on the Release build: `qlmanage -t -x -s 512` makes 512 × 288 thumbnails of
  `.deckcraft`, `.pptx`, `.potx` and `.ppsx` files; `qlmanage -p` shows every slide with the page sidebar and the
  deck's title, and a damaged file's message page.
- **The system's own Office extensions win for `.pptx`/`.potx`/`.ppsx`** (`OfficeThumbnailExtension` and its
  preview: Times for Inter, `‹#›` for the slide number, hidden slides left out). Ours handles the same bytes (checked
  by giving a `.pptx` file a `.deckcraft` name) and is used for `.deckcraft`. Which extension macOS picks for a type
  two claim isn't ours to set; the app is an Alternate handler for the Office types.
- **Spotlight: macOS doesn't call the import extension (measured 2026-10-27, macOS build 27.2, Darwin 27.2).**
  - It is registered and enabled: `pluginkit -m -p com.apple.spotlight.import` and `mdimport -e` list it with its
    four types; `mdbulkimport` finds it ("Modern importer BTM register… record exists"); backgroundtaskmanagementd
    reports `name=DeckCraftSpotlight.appex, type=spotlight, disposition=[enabled, allowed, notified]`. Its Info.plist
    and entitlements match Apple's own `PDFKit.framework/…/PDFImporter.appex` (NSExtensionAttributes
    `CSSupportedContentTypes`, point `com.apple.spotlight.import`, a principal class, app sandbox).
  - `mds` never hands it a file: importing a fresh `.deckcraft` in `~/Documents` logs
    `FALL BACK ------- LABEL ASSIGNMENT com.apple.mdworker.shared` and the file gets only system attributes; no
    `DeckCraftSpotlight` process starts. The control is Apple's own: a PDF copied beside it is imported (4
    pages) by `/System/Library/Spotlight/PDF.mdimporter` in mdworker, and the PDFImporter appex doesn't run either.
    So on this system file indexing goes through mdworker and `.mdimporter` plug-ins; the import extensions run only
    in `mdbulkimport`'s own jobs, and nothing we found starts one for a third-party type.
  - `mdimport -t` runs only `.mdimporter`s ("with no plugIn"); `mdimport -m -y <UTI> -u <url>` (the tool for
    import extensions) can't host a third-party one from the command line ("Unable to acquire process assertion…
    killing plugin", NSCocoaErrorDomain 4097).
  - A legacy `.mdimporter` doesn't help: one built and signed with the Developer ID (in `Contents/Library/Spotlight`,
    and in `~/Library/Spotlight` after `mdimport -r`) is never listed by `mdimport -L`, which lists only Apple's
    (Xcode's `uuid.mdimporter`, GarageBand's). It was taken out again; the code is in the session's scratchpad.
  - On this macOS, then, Spotlight can't be given a third-party presentation importer outside the system's own
    path. The extension stays (it is what Apple documents, and the indexing it does is the tested `DeckIndex`); the
    check, once the system calls it: copy a corpus deck somewhere indexed, `mdls -name kMDItemNumberOfPages <file>`.
- **A development trap: sandbox containers made by an ad hoc build.** An extension's container
  (`~/Library/Containers/com.xocialize.deckcraftnative.<QuickLook|Thumbnail|Spotlight>`) records the signer of the
  build that first ran. A later Developer ID build of the same extension "is not in ACL for container … prompting"
  (secinitd), and hangs in `_libsecinit_appsandbox` until the prompt is answered or times out (two minutes): Quick
  Look then shows its generic preview. Users of the release never have an ad hoc container; on a development Mac,
  move those containers to the Trash (or answer the prompt) after switching from ad hoc to Developer ID builds.
