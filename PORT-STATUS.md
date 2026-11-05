# Port status

Crate by crate: what deckcraft has, what the native port does with it, and where it stands. Rust line
counts include in-file tests, measured at `27009cd9` (2026-10-26). The pin is now `a3fbf029` (see Pin
moves). Dispositions and their reasons are in [PLAN.md](PLAN.md) §3.

## Wave 0: scaffold and oracle (done 2026-10-26)

- **The package.** `Package.swift` declares every target from PLAN.md §4 with deckcraft's layer
  dependencies. `swift build` and `swift test` are green.
- **The oracle.** `deckcraft-cli` 0.11.1 is built from `27009cd9`, with craft-fonts `aced4137` compiled
  in (`CRAFT_FONTS_REQUIRED=1`) and rustc 1.99.1 (Homebrew `rustup`). `Tools/oracle/oracle.sh` refuses a
  checkout, or a binary, that isn't at the pin.
- **The corpus.** `../DeckCraftNative-Fixtures/oracle/27009cd9/` holds 101 files, 11 MB: 4 decks (the
  sample, plus the `shapes`, `text` and `content` scripts), 330 commands in `commands.txt`, 26 slide
  renders, 26 more from the `.pptx` round trip, and 18 transition frames. Regenerating it gives
  byte-identical output (`SHA256SUMS` unchanged over two runs).
- **Tests.** `DCTestSupport` reads the pin and finds the corpus. 5 tests, 2 of which check the corpus
  against the pin and its checksums.

## Wave 1: foundation (done 2026-10-26)

- **Code.** About 17,900 lines of Swift source plus 4555 lines of tests, in DCCore, DCZip, DCGeometry, DCColor,
  DCModel and DCFormat.
- **Tests.** 259 tests, all green and warning-free:

  | Target | Tests |
  |---|---:|
  | DCCore | 14 |
  | DCZip | 24 |
  | DCGeometry | 70 |
  | DCColor | 8 |
  | DCModel | 96 |
  | DCFormat | 42 |
  | DCTestSupport | 5 |

  That includes every Rust `#[test]` in geom (62), color (7), model (95) and format (39).
- **Parity with the oracle:**
  - **Geometry is bit-identical to deckcraft-geom**, with no tolerances:
    - 187 presets fully dumped
    - 5,610 preset × size × adjust cases (hashed)
    - all 40 warps
    - 7 Morph pairs
    - squircles, units and transforms

    The vectors come from `Tools/oracle/oracle.sh geom-vectors`.
  - **`.deckcraft` round trip.** Every deck in the corpus loads, and re-saving writes byte-identical
    `presentation.json`. The pinned `deckcraft-cli` opens what Swift writes and reports the same deck
    (`info` matches, apart from the path).
  - **JSON writer.** It matches serde_json on 222,461 doubles, 107,713 floats and 133 strings
    (`oracle.sh json-vectors`). serde_json 1.0.154 lays floats out with zmij, not ryu.
- **How:**
  - The 100 serialised model types are generated from the Rust sources: `Tools/port/generate.sh` runs
    `serde2swift.py`, which follows each serde attribute exactly.
  - Their behaviour is hand-ported.
  - DCCore carries Rust's numeric and string semantics: saturating casts, NaN- and signed-zero-exact
    min/max/clamp, `chars()` counts, final sigma, and byte-wise string equality.
  - DCZip is PhotoCraftNative's ZIP code, copied.
- **Parallel work.** DCGeometry and the chart, trendline, number-format and table half of DCModel were ported
  by two parallel sessions in the same tree.

## Wave 2: text and render (done 2026-10-26)

- **Code.** About 19,900 lines of Swift source plus 8,700 lines of tests, in DCMetafile (5,000), DCText
  (6,100), DCRender (8,000) and kurbo's arc-length, circle and offset code in DCGeometry (760).
- **Tests.** 712 in all, every one green and warning-free; Wave 2 added 453. The parity test runs in release
  (`DCRender/PORT-NOTES.md`).

  | Target | Tests |
  |---|---:|
  | DCMetafile | 113 |
  | DCText | 110 |
  | DCRender | 212, plus the oracle parity test |
  | DCGeometry | 88 (18 new) |

  Ported Rust tests:
  - **metafile:** all 108, plus 4 from `clip.rs`.
  - **text and fonts:** all but the Linux/Windows font-directory tests and a check against an old bidi copy.
  - **render:** all but the 6 Morph and transition tests (Wave 4), 2 PNG-encoder tests and a viewing helper
    that asserts nothing.
  - **pdf:** all but the unembeddable-font test (CoreGraphics embeds any font CoreText loads).
- **Parity with the oracle:**
  - **Rendering.** Every slide of the 8 corpus decks scores 90.6–100 SSIMULACRA2 against deckcraft's PNG,
    with at most 0.56% of a slide's pixels more than 8 levels apart. The test's floor is 88.
  - **Metafiles are bit-identical.** Parse, placement and pixels match on 325 cases: 23 metafiles and 302
    mutations (`oracle.sh metafile-vectors`).
  - **Text layout.** Line breaks are identical on all 102 corpus text bodies, with baselines and extents
    within 0.000 pt. On 20 synthetic bodies (RTL, CJK, Thai, Devanagari, columns, vertical) breaks are
    identical too, and extents are within 0.04 pt (`oracle.sh text-vectors`).
- **How:**
  - DCText shapes, runs bidi and breaks lines with CoreText. deckcraft's PowerPoint policy (autofit,
    spacing, bullets, columns, vertical text, fields) is ported on top.
  - DCRender draws on a `Canvas` that models vello_cpu's `RenderContext` on CoreGraphics.
  - **PDF is vector.** A recording `Canvas` replays the slide as paths. Only blurs and backdrop compose
    modes become images. An invisible CoreText layer gives selectable, searchable text. deckcraft rasterises
    each slide.
- **Fixed on the way:**
  - The Swift 6.4 optimizer crashed on DCFormat's generic typed-throws visitors, which broke every release
    build. The visitors are concrete now.
  - Colour glyphs didn't take the run colour.
  - Strokes inside groups scaled far up came out coarse.
  - Two thread races in font loading.
- **Upstream.** deckcraft `origin/main` is 3 commits past the pin, none of them in metafile, fonts, text,
  render or pdf.
- **Parallel work.** Four sessions ported metafile, fonts and text, render primitives, and tables, charts and
  3-D in the same tree. The renderer core, PDF and integration were done here.

## Wave 3: PPTX (done 2026-10-26)

- **Code.** About 12,000 lines of Swift source and 8,200 lines of tests in DCPPTX, plus Rust's float
  `Display` in DCCore (`rustDisplay`).
- **Tests.** 911 in all, every one green and warning-free; Wave 3 added 199.
  - **DCPPTX: 193.** Every in-file Rust test (33 in the support modules, 18 in `read/`, 6 in `write/`) and all
    119 integration tests (`tests/it` and `chart_data_labels.rs`), plus oracle tests.
  - **Skipped for DCEngine (Wave 4): 4.** They need `slide.reuse`, `picture.compress`, `insert.zoom` and the
    engine's encrypted-file message. Two transition-sound tests are ported apart from the checks only a command
    can make.
  - **DCCore: 6 new**, for `rustDisplay` and Rust float parsing.
- **Parity with the oracle**, over the 9 corpus decks:
  - **Import is byte-identical.** Swift reading deckcraft's `.pptx` gives deckcraft's model, to the byte of the
    `presentation` JSON, with media and chart entries the same.
  - **Export is byte-identical.** Every part Swift writes equals deckcraft's: 458 parts. 13 more decks were
    also compared once against `deckcraft-cli`, all 1,028 parts identical: kept charts with workbooks, OLE,
    ink, 3-D models, embedded fonts, tags, decks without masters, and two real PowerPoint files read by
    deckcraft.
  - **deckcraft reads Swift's packages** back to the model it reads from its own.
  - **Support modules:**
    - the XML parser on 30,207 inputs (parse or error);
    - every corpus part re-serialised;
    - 3,134 escapes;
    - 60,697 calls into opc, cfb, png, maps, custgeom, tables and dgm (`oracle.sh pptx-vectors`).
  - **`rustDisplay` matches Rust's `{}`** on all 330,190 floats (`oracle.sh display-vectors`).
- **Validation.** Every part Swift writes, and every part deckcraft writes, validates against the ECMA-376 5th
  edition Transitional schemas (`Tools/pptx/validate.sh`). Markup compatibility (Part 3) is applied first.
  Office extension parts (modern comments, chartEx, SmartArt drawings) have no ECMA schema and are skipped.
  deckcraft makes no such check.
- **Corpus.** Wave 3 added five scripted decks (charts, SmartArt, effects, motion, review), taking the corpus
  to 9 decks and 90 rendered slides. The effects deck found a renderer bug: CoreGraphics quantises the
  weights it uses to magnify an image, so a stretched picture showed soft blocks, and the slide scored 57.4.
  It now scores 89.2.
- **Fixed on the way:** files nested about 11 groups deep overflowed a Swift concurrency thread's stack, so
  import and export now run on a 32 MiB thread, as deckcraft's do on Rust's larger stacks.
- **Upstream.** deckcraft `origin/main` is 62 commits past the pin. The ones in ported crates (geom, format,
  fonts, text, render, pptx) only split or move files, and their diffs are moves. The pin stays at `27009cd9`.
- **Parallel work.** The support modules, then `read/` and `write/` side by side, then the integration tests
  were each ported by a separate session. The corpus, validation and parity tests were done here.

## Wave 4: engine and automation (done 2026-10-27)

- **Code.** About 37,500 lines of Swift source and 18,600 lines of tests:
  - DCEngine 24,500 (tests 12,300);
  - DCMedia 5,700 (1,800);
  - DCAnim 4,000 (2,300);
  - DCAutomation 2,000 (900);
  - dccli 1,200 (1,300);
  - Morph and transitions in DCRender.
- **Tests.** 1,645 in all, every one green and warning-free; Wave 4 added 734.
  - **DCEngine: 495.** Every in-file `#[test]` of the command modules, `tests.rs`, `engine/tests/`, and the
    soak (`soak_tests.rs`: 1,600 random commands over a big deck, with undo/redo and save/reopen checked).
  - **DCAnim: 102**, all 94 Rust tests plus bit-exact parity with deckcraft-anim.
  - **DCMedia: 62.**
  - **DCAutomation: 34** (every mcp `#[test]` and `backend.rs`'s) and **dccli: 31** (201 parameterised cases).
  - **Skipped: 1**, a VP8 decode test with no clip in the fixtures. **Known issues: 3**, the two pointer steps
    of mcp's `agent_builds_a_deck` and one PDF page (below).
- **Parity with the oracle:**
  - **Registry.** All 330 commands, with deckcraft's ids, labels, menus, shortcuts and parameters, in its order.
  - **Engine scripts.** 38 scripts give deckcraft's answers, refusals and `.deckcraft`, byte for byte, across
    every command family and from saved decks and `.pptx` files. 6 more (`*-native-*`) differ where a native
    framework does the work (ImageIO pictures, CoreGraphics Merge Shapes, spelling) and are compared
    structurally, by pixels or by area.
  - **dccli.** `commands`, all 330 `describe`s, help, version and 72 bad invocations are byte-identical; every
    script's `--print` output and deck, `info`, and `convert` to and from `.pptx` and to `.md` are identical.
    PNG renders score ≥ 94.6 SSIMULACRA2, transition frames ≥ 92.8, PDF pages ≥ 95.1 but one.
  - **MCP.** A 36-line agent session gets deckcraft's replies, byte for byte, except saved-file sizes;
    `mcp --connect` and the control channel match it against a fake app.
  - **DCAnim** easing, motion paths, timelines, the show state machine, transition layers, meshes and Morph
    frames are bit-identical (`oracle.sh anim-vectors`); transition renders score ≥ 88.
  - **DCMedia** header probes match deckcraft-media on generated, CC0 and mutated media (`oracle.sh
    media-vectors`), since their results are stored in documents.
- **Native in place of ports** (the decision below):
  - Merge Shapes on CoreGraphics path booleans; the worst relative area difference is 2.2e-16.
  - Spelling through a Hunspell dictionary when one is installed, else NSSpellChecker, else deckcraft's list.
  - Decoding on AVFoundation, VideoToolbox and AudioToolbox. media-bridge's codec gate decides what plays,
    and its factory covers MPEG-1/2. VP8 and VP9 go through a decoder the app registers.
  - PNG, JPEG and GIF bytes from ImageIO.
- **Divergences.**
  - **Undo memory.** 5–13 steps kept under the cap, where deckcraft keeps 5–11: Swift counts equal slides as
    shared, Rust only literally shared ones.
  - **No panic guard.** Swift can't catch a trap, so a command that traps isn't rolled back; the soak is the
    check that none does.
  - **One PDF page.** Page 3 of the effects deck scores 74.3. The vector PDF keeps an 8 px gradient picture at
    its own size, and Preview magnifies it in blocks; raster renders are smoothed.
- **Not ported, for Wave 5.** The screenshot encoder. (`tools.rs`' pointer handling, about 1,900 lines of hit
  testing, drags, snapping, freeform and ink, landed in DCEngine at the start of Wave 5: `Session.pointer`, which
  MCP's `pointer` tool and `ui.pointer` now drive, its 56 Rust tests ported and 7 MCP pointer sessions identical to
  the oracle's.) (`control_server.rs`, the app's TCP server, landed in DCAutomation at the start of
  Wave 5: `ControlServer`, its 14 tests ported.)
- **Fixed on the way:**
  - The engine runs on 32 MiB threads in MCP and the control channel, so deeply nested groups don't overflow.
  - ImageIO labels a GIF with a frame-delay block `GIF87a`; the header now says `GIF89a`.
- **Upstream.** deckcraft `origin/main` is 62 commits past the pin. In the Wave 4 crates they only split or move
  files (`tools.rs`, `cmd/{shape,text,smartart,insert,format,design}.rs`, media's player tests) and change one
  test helper. The pin stays at `27009cd9`.
- **Parallel work.** DCAnim and DCMedia, then the engine core, then four command groups (text, shapes, design,
  insert) side by side, then automation, were each ported by a separate session. Integration, the soak and the
  status were done here.

## Wave 5: the app (done 2026-10-27)

- **Code.** About 22,500 lines of Swift source and 7,000 lines of tests in `Packages/DCApp`:
  - DCAppModel 9,800, the app's state with no AppKit, so it is testable without a window;
  - DCApp 12,700, AppKit, SwiftUI and Metal.
  - By area (app + model): Canvas 3,200, Inspector 5,000, Dialogs 4,300, Show 4,300, Views 3,850,
    Automation 380, plus the core.
  - Also `Apps/DeckCraftNative`, a thin Xcode app with deckcraft's document types, and `Apps/DeckCraftDev`,
    the same app from SwiftPM.
  - The engine gained deckcraft's pointer (`tools.rs`: about 1,560 lines of Swift).
  - DCAutomation gained the loopback control server (`control_server.rs`).
- **The app.** The Mac way: menu bar, toolbar, slide navigator, canvas and inspector, with no ribbon
  (PLAN.md "Decided").
  - NSDocument windows over one shared engine session.
  - The canvas: handles, smart guides, drawing, and in-place text editing through `NSTextInputClient`.
  - Five inspector tabs carry the ribbon's and task panes' controls (the ribbon map is in DCApp's PORT-NOTES).
  - Deckcraft's dialogs are sheets; Export, New from template, Settings, the palette, Find and Replace.
  - The show is composited in Metal, with the presenter view on the second display.
  - Slide Sorter, Outline and Notes Page views; printing through `NSPrintOperation`; the pasteboard with
    other apps.
  - Every action is a registry command (`AppModel.run`). The design vocabulary is DesignScaffold's (AB-D-0042).
- **Tests.** 2,050 in all, every one green and warning-free; Wave 5 added 405.
  - **DCApp: 331** (DCAppModelTests 255, DCAppTests 76). All 62 of `lib.rs`' tests are triaged: 41 ported,
    21 egui-only. So are the per-file tests of every area: `show.rs` 27/27, `media.rs` 7/7, `ime_tests.rs`,
    `canvas.rs`, the dialogs, backstage, sorter, panes and more. Each area's notes list what doesn't apply.
  - **DCEngine: 549**, with 56 of deckcraft's pointer tests and 8 earlier tests completed.
  - **DCAutomation: 52**, with all 14 of `control_server.rs`' tests.
- **The alpha gate** (deckcraft `docs/roadmap.md`), run in the app through the control channel with a
  screenshot of every step (`Tools/app/alpha-gate.sh`): **16 of 16 checks pass.**
  1. build a deck, save, close, reopen;
  2. open a `.pptx`, edit it, save it back as `.pptx`;
  3. the show and presenter view;
  4. a table, a chart with edited data, and SmartArt;
  5. PDF of slides, notes and handouts, PNG, and print to PDF;
  6. a comment with a reply, resolved; spelling.
- **Parity.**
  - **Pointer.** Seven MCP pointer sessions (760 pointer calls) give deckcraft's replies and decks, byte for byte.
  - **Show.** The Metal compositor matches DCRender's CPU compositor to within 0.054% of pixels on every
    non-Morph frame. Against deckcraft's frames it scores 88.9–100 SSIMULACRA2.
  - **Release.** Render and transition parity pass in release.
- **Native in place of ports.** `NSTextInputClient`, `NSSpellChecker`, `NSPrintOperation` (deckcraft had no
  printing: gap #6), `NSPasteboard`, `NSScreen` (presenter view on the second display: gap #9), the menu bar
  (gap #13), NSDocument, ScreenCaptureKit for the control channel's screenshots, Metal for the show.
- **PowerPoint.** Installed 2026-10-27 as a black-box oracle (PLAN.md §10). Its first finding: decks with
  charts written by deckcraft, and so by DCPPTX, open with PowerPoint's repair prompt. Decks without
  charts open cleanly. It is a deckcraft writer bug, carried over byte for byte. Fixed after Wave 6 (merge of
  `pptx-chart-repair`): every `chartEx` part gets its style parts, and all 9 corpus decks open without repair,
  as does the `.pptx` the app saves in the alpha gate. Tests: 2,144 with it.
- **Not done.** String Catalogs: the Xcode target emits localisable strings, but there is no catalog yet.
  The window and update-channel items are Wave 6's.
- **Upstream.** deckcraft `origin/main` is 62 commits past the pin. The 34 in `ui-egui` and `apps/deckcraft`
  only split or move files. The pin stays at `27009cd9`.
- **Parallel work.** The pointer and the control server, then five areas (Canvas, Inspector, Dialogs, Show,
  Views) side by side, then `lib.rs`' tests, were each ported by a separate session. The skeleton, the
  control host, integration and the alpha gate were done here.

## Wave 6: ship (done 2026-10-27)

- **Decided by the user** (WAVE6-PLAN.md):
  - the name is DeckCraftNative, with deckcraft's MIT placeholder icon and no ArtCraft marks;
  - updates come from a native GitHub releases checker, through a public releases repo created only when publishing
    is approved;
  - English only, in String Catalogs;
  - Developer ID (CFZS6RXUCP), notarized with the `mlx-notary` profile.
- **A notarized build.** `Tools/release.sh --notarize mlx-notary` archives, exports with Developer ID, verifies every
  nested binary, builds the DMG, and notarizes and staples both the app and the DMG.
  - Gatekeeper accepts the DMG and the app (`source=Notarized Developer ID`).
  - It refuses to build when `Acknowledgements.txt` is stale or craft-fonts is missing.
  - `Tools/publish-release.sh` exists and has only been run as a dry run: nothing is published.
- **What ships in the app:**
  - All of craft-fonts (77 MB). The preview and thumbnail extensions carry the Latin set, since a sandboxed extension
    can't read its app's bundle.
  - `Acknowledgements.txt`: deckcraft's licence and NOTICE, craft-fonts' attribution, and every Swift package's
    licence (`Tools/acknowledgements.sh`).
  - About credits DeckCraft in plain text.
- **Updates.** Check for Updates… with a Software Update window: notes, download checked against GitHub's size and
  digest, quarantine, open. The daily check is optional. Tested against a stubbed `URLProtocol` and a local server.
- **Quick Look and Spotlight.** A preview (vector PDF of every slide, with a text layer) and a thumbnail (the first
  slide at the requested size) for `.deckcraft`, `.pptx`, `.potx` and `.ppsx`. Verified with `qlmanage`; the
  thumbnail draws in Inter. A Core Spotlight import extension is tested, but on this Mac macOS never calls
  third-party importers (EVALUATION.md). macOS's own Office previews take precedence over ours for Office files.
- **App Intents.** Eight intents and seven App Shortcuts, listed in the built app's `Metadata.appintents` and run end
  to end in the built app: export, outline, slide count, new presentation, add slide. Not yet seen in the Shortcuts
  app.
- **String Catalogs.** Every UI string in DCApp and DCAppModel comes from a catalog: 6 catalogs, 1,921 entries, about
  1,630 call sites converted.
  - Command labels and menu titles are translated at display time (`L10n`). The engine keeps deckcraft's English
    for parity.
  - `Tools/l10n/` fills the catalogs from the compiler's `.stringsdata` and regenerates the Commands catalog.
  - A pseudo-localisation pass found three clipped layouts and fixed them.
  - Tests keep the catalogs complete.
- **Tests.** 2,139 in all, every one green and warning-free; Wave 6 added 89 (DCApp 50, the extensions 29, and more).
  - The alpha gate passes 16 of 16 after the strings conversion.
  - Release, render, transition and Metal parity pass in release.
- **Fixed on the way.**
  - **Fonts.** The app found its fonts through a path into the source tree, so on any other Mac decks would have drawn
    in substitute fonts. It now bundles them.
  - **Dialog sheets.** Their sizing could loop inside AppKit; they're hardened.
  - **Tests.** An Updates window test was order-dependent; it no longer is.
- **Published 2026-10-27.** The user made `xocialize/DeckCraftNative` public and approved publishing:
  [v0.1.0](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.0), built clean from `0929908`.
  - The release carries the notarized DMG and its `.sha256`. An anonymous download matches the checksum and passes
    Gatekeeper.
  - The update checker reads this repo's releases and answers "up to date" from the shipped build.
- **Licence.** The repository's own code is MIT OR Apache-2.0, like deckcraft's (`LICENSE-MIT`, `LICENSE-APACHE`,
  `NOTICE`; the user's decision, 2026-10-27).
- **Not done.** Translations. Spotlight end to end (above).
- **Parallel work.** Release and Updates, Extensions, Intents and Strings were each built by a separate session. The
  catalog infrastructure, the fonts and licences in the bundle, integration, the final notarized build and
  EVALUATION.md were done here.

## After Wave 6

- **VP9 and VP8 video (2026-10-27).** The app and `dccli` register vpx-swift's `VpxVideoDecoder` (libvpx 1.16, BSD-3
  with the WebM patent grant) into DCMedia's external-decoder seam, so WebM and Matroska video plays in the editor
  and the show and gets a poster on insert. DCMedia itself stays free of it (PLAN.md §10.4).
  - **Checked on deckcraft's own clips:** the frame times are deckcraft's, and the decoded pixels match ffmpeg's VP9
    and VP8 decoders to 0.25 levels. deckcraft reports VP8 unsupported, so here VP8 goes further than the oracle.
  - **Colours, fixed in vpx-swift 0.3.1 (2026-10-27):** vpx-swift 0.3.0 converted streams with no colour tag as
    BT.709, where VP8's specification, deckcraft and ffmpeg use BT.601 for SD video (about 6 levels on these clips).
    Asked of its owner as AB-A-0205; 0.3.1 converts VP8 and untagged VP9 of 576 lines or fewer as BT.601 (deckcraft's
    `Matrix::from_code` rule) and keeps BT.709 for untagged HD. DeckCraftNative requires 0.3.1, and `CodecsTests` now
    checks every frame of both clips against ffmpeg's BT.601 conversion (0.30 levels) instead of a known issue.
  - libvpx's licence and patent grant ship in `Acknowledgements.txt` (`Tools/acknowledgements.sh` now picks up a
    package's `THIRD-PARTY-NOTICES`).
- **PowerPoint sweep (2026-10-27).** `Tools/pptx/powerpoint-sweep.sh` exports every test deck with `dccli` (the 9
  corpus decks, 44 engine scripts and 7 pointer sessions) and opens each in PowerPoint.
  - All 60 open without repair, and PowerPoint sees the same slides and shapes per slide as were written.
  - Nothing needed fixing.
  - deckcraft's own export of the Office 2016 chart deck, checked as a control, still needs repair.
- **Released as [v0.1.1](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.1) (2026-10-27).**
  - Built clean from `3335d96`, notarized, and accepted by Gatekeeper; an anonymous download matches its `.sha256`.
  - The published 0.1.0, run from its own DMG, finds 0.1.1 through Check for Updates.

- **0.1.2 polish (2026-10-27).**
  - **App Intents extension:** Export Presentation, Get Outline and Get Slide Count live in a shared `DCIntentsKit`
    module that a new `DeckCraftIntents` extension and the app both link (Apple's shared-framework pattern). macOS
    prefers to run background intents from the extension, so they need no app or window. Its metadata and the
    notarized export verify. Through the Shortcuts app, with no app running, Export Presentation turned an 8-slide
    deck into an 8-page PDF and the app never launched (DCExtensions/PORT-NOTES.md).
  - **Theme Colors:** the colour rows form one aligned grid, and every well stays inside the sheet.
  - **Colour names:** DCColor's slot, shade and standard colour names are translated at display
    (`L10n.colorLabel`); the pseudo-language showed them bypassing the catalog.
  - **Inspector choices:** Review, Animate, Arrange and Text box use `FittingPicker`, which measures whether the
    segment titles fit the row and becomes a menu when they don't.
  - **Status bar:** it sheds the zoom slider, then the view buttons, instead of clipping its zoom controls.
  - **Control channel:** a ScreenCaptureKit capture that doesn't answer within 3 s falls back to the offscreen
    drawing.
  - **`release.sh`:** it never overwrites a released version's build. A tagged version must be bumped; a test build
    of it goes to `<version>-test`.
- **Released as [v0.1.2](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.2) (2026-10-27).**
  - Built clean from `1c75c98`, notarized, and accepted by Gatekeeper; the downloaded DMG matches its `.sha256` and
    its ticket is stapled.
  - The published 0.1.1, run from its export, finds 0.1.2 through Check for Updates.
- **Released as v0.1.3 (2026-10-27).** vpx-swift 0.3.1: VP8 and untagged VP9 of 576 lines or fewer convert as
  BT.601, as deckcraft and ffmpeg do (AB-A-0205; "VP9 and VP8 video" above). Nothing else changed.
- **Ribbon R0: one table (2026-10-27).** This is the first milestone of
  [Docs/plans/Ribbon-and-StartScreen.md](Docs/plans/Ribbon-and-StartScreen.md); details are in DCApp's PORT-NOTES, under "Ribbon".
  - **`RibbonLayout`** in DCAppModel holds the ribbon as data: 10 tabs, 10 contextual tabs, groups with fold order,
    and controls with their command, kind and sizes. It is arranged for someone who knows PowerPoint.
  - **New tables:** `CommandMenus` holds the split menus, moved out of `ToolbarCatalog`. `CommandSymbols` holds the
    SF Symbols. `CommandHelp` holds the descriptions and is empty until R1.
  - **`RibbonMap`** is now derived from the layout. No command was lost; 19 rows gained commands that their menus
    already ran.
  - **The app is unchanged.** The toolbar reads the new tables, and a test pins its symbols and menus.
  - **Tests:** `RibbonCoverageTests` replaces the planned order-equality test. It checks that every command in
    deckcraft's `ribbon*.rs` has a control, and at the pin it rescans the sources.
- **Ribbon R1: the static ribbon (2026-10-28).** The ribbon is an optional window layout: View › Ribbon (⌥⌘R) or
  Settings › General › Window layout. The toolbar and inspector stay the default until R4. Details are in DCApp's PORT-NOTES, under "Ribbon".
  - **What it shows:** the ten regular tabs, with the controls at their large size. Buttons, toggles, splits, menus, check boxes, spinners and colour
    splits all run their registry command with deckcraft's parameters, and the enabled and toggle state come from the session.
  - **Galleries** are menus until R2.
  - **The window in the ribbon layout:** a toolbar with the Quick Access Toolbar's buttons at the leading edge, then Search, Present and Comments.
    The inspector becomes the task pane.
  - **Tooltips:** every command the ribbon and the toolbar show has a one-line description in our own words (decision 3),
    translated as `help.*` in the Commands catalog.
  - **Tests:** `RibbonModelTests` runs every control's commands against a scratch session (over 400), and
    `RibbonWindowTests` switches a real window back and forth.
- **S1: the start window (2026-10-28).** A milestone of the ribbon plan, built beside R1; details are in DCApp's PORT-NOTES,
  under "Ribbon" › "S1".
  - **A launch with nothing to open shows the start window,** not an untitled presentation. It has Home, New and Open,
    a search field, rendered theme and template tiles, and the recent list. Settings › "Show the start screen when
    DeckCraftNative opens" (on by default) turns it off, which brings the untitled presentation back.
  - **Creating from any tile is `file.new` with that tile's parameters.** A test compares `document.inspect` for every
    theme, template, Blank and the sample.
  - **File › Open Recent** is new. It lists the same rows as the start window, including missing files, which show
    "(missing)" and do nothing when chosen.
  - **`app.backstage {page: home|new|open}` and `app.home`** show the start window. The "new" dialog remains for
    scripts only.
  - **Control channel:** `ui.inspect`'s `home` and `backstage` are live, and it gains `startScreen`. There is a new
    `ui.startScreen` method, and `ui.screenshot {window: "start"}` captures the window.
  - **Tests:** 33 new (`StartScreenTests`, `StartWindowTests`), including deckcraft's start-screen tests where they
    apply. The alpha gate gains step 0 and passes 18 of 18.
- **Ribbon R2: contextual tabs and galleries (2026-10-28).** Details are in DCApp's PORT-NOTES, under "Ribbon" › "R2".
  - **Contextual tabs:** Shape Format, Picture Format, Table Design and Layout, SmartArt Design, Chart Design, Playback,
    and the three master tabs come after the regular tabs when the selection has their object, tinted with the accent
    colour. They are never switched to: a tab that stops applying gives way to Home.
  - **Galleries are tiles** with a "›" button for the whole gallery by category: themes (the start window's tiles),
    variants, transitions, animations, table styles, picture styles, quick styles, SmartArt layouts and styles. The
    Shapes buttons open a grid of the presets. Choosing a tile is one undo step.
  - **Every contextual control** runs its command with deckcraft's parameters. The menus, check boxes and colour splits
    come from deckcraft's tab files, and Height and Width use the Preferences unit.
  - **New UI command:** `view.handoutSlides {count}` for Handout Master › Slides Per Page.
  - **Tests:** `RibbonContextualTests` (9), which includes a walk of every contextual control with its object
    selected (over 250 commands), and two more `RibbonWindowTests`.
- **Ribbon R3: folding, keyboard and accessibility (2026-10-28).** Details are in DCApp's PORT-NOTES, under "Ribbon" › "R3".
  - **Folding:** groups step down through large, medium, small and collapsed as the window narrows, in `foldOrder`
    (`RibbonFit`, a pure function, with widths measured once per group and size). Paste and Designer never fold. Tabs
    that don't fit go into "»", never the selected one, and deckcraft's ‹ › chevrons are the last resort. Every tab
    lays out at 1600, 1150, 920 and 700 pt with `ui.inspect.ribbon.truncated == []`.
  - **Minimised (⌘F1):** a click on a tab shows its controls as a transient panel over the document.
  - **Keyboard:** F6 (new UI command `view.focusRibbon`) moves to the tab row; the arrow keys, Return, ⌥↓ and Esc move,
    run, open and leave. It needs Full Keyboard Access, which is off on the development Mac, so the walk is verified in
    the model and not yet in the app.
  - **VoiceOver:** the tabs are a tab group of radio buttons, groups are named, and splits are two buttons. Every tab
    was read from outside the app at four widths with no unnamed control. The Accessibility Inspector audit itself was
    not run: its target picker needs full-screen control.
  - **Control channel:** `ui.key`, and `ui.inspect.ribbon` gains each group's `size`, `truncated`, `tabsShown`,
    `tabsOverflow`, `tabRects`, `peek` and `focus`.
- **Ribbon R4: localisation and polish; the ribbon is the default for new installs (2026-10-28).** Details are in
  DCApp's PORT-NOTES, under "Ribbon" › "R4".
  - **Strings:** a new `Ribbon.xcstrings`, with 280 tab, group and control titles, generated by `Tools/l10n/commands.sh`.
    Every command the palette lists (238) has a one-line description, which the palette now shows.
  - **Widths:** `Tools/app/ribbon-widths.sh` gives `truncated == []` on all 20 tabs at all four widths in English,
    pseudo, double-length and right-to-left. Long labels widen their button, up to twice its width, instead of being
    cut.
  - **Default:** a launch with no `ui.json` gets the ribbon. A `ui.json` from before the ribbon keeps the Mac layout.
    The tab, the minimised state, the layout and the QAT persist.
  - **Share:** the ribbon toolbar's Share opens the Mac's share menu for the saved file.
  - **Gate:** the alpha gate runs in either layout (`GATE_LAYOUT`, through the new `ui.set {layout}`).
  - **Fix:** zooming with legacy scroll bars kept the wrong middle. This was the intermittent
    `zoomingPastTheWindowScrollsAndKeepsTheMiddle`, and its test now covers both scroll-bar styles.
- **Released as [v0.1.4](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.4) (2026-10-29).** The ribbon
  and the start window: R0–R4 and S1 above. New installs get the ribbon; a `ui.json` from an earlier version keeps the
  Mac layout. Notes in `Docs/releases/0.1.4.md`.
  - Built clean from `9404050`, notarized, and accepted by Gatekeeper; the downloaded DMG matches its `.sha256` and
    its ticket is stapled.
  - The 0.1.3 build, run from its export, finds 0.1.4 through Check for Updates.
- **After 0.1.4: the keyboard walk (2026-10-29).** The operator walked the ribbon with Full Keyboard Access on.
  The walk found five bugs in 0.1.4, all fixed on main, unreleased. Details are in DCApp's PORT-NOTES, under "After
  0.1.4".
  - A fitted slide flipped between two zooms on every relayout when legacy scroll bars were shown.
  - The ribbon showed no focus ring.
  - The arrow keys stuck once an AppKit control had the keyboard.
  - ⌥↓ opened no menu, and disabled controls trapped the arrow keys.
  - A window opened in the ribbon layout drew the titlebar's blur over the top of the slide; the navigator's rows kept
    heights measured before a legacy scroller came in. Both fixed later the same day.
  - Still to do: the Accessibility Inspector audit.
- **Released as [v0.1.5](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.5) (2026-10-29).** The
  keyboard-walk fixes above. Notes in `Docs/releases/0.1.5.md`.
  - Built clean from `0c37c9f`, notarized, and accepted by Gatekeeper; the downloaded DMG matches its `.sha256` and
    its ticket is stapled.
  - The 0.1.4 build, run from its export, finds 0.1.5 through Check for Updates.
- **After 0.1.5 (2026-10-29 to 30).** Details are in DCApp's PORT-NOTES, under "After 0.1.5".
  - The Outline view's rows kept heights measured before a legacy scroller came in, as the navigator's had.
  - `ui.screenshot` returned stale frames while another app's window covered DeckCraft's. It now draws a covered
    window offscreen, and its reply says which capture it used (`source`).
  - Spotlight, re-tested: with the notarized build in `/Applications`, and with the `CSExtensionLabel` key Xcode's
    template adds (now in the importer's Info.plist), macOS still doesn't call the import extension for local files
    (DCExtensions/PORT-NOTES.md).
  - Spotlight from the app: the app indexes the `.deckcraft` files it opens and saves (SpotlightFeature), as a Core
    Spotlight item and as an App Intents entity of the presentation App Schema. On macOS 27 Spotlight finds them by
    name and opens them; it never matches their body text. Siri finds them by what they say and opens them: five in
    five on 2026-10-30 with one build left installed in `/Applications`, including a cold launch. The first test's
    failures (one in five) came from reinstalling the app between tries. Details in DCExtensions/PORT-NOTES.md.
  - Still to do: the Accessibility Inspector audit, held until the operator has time for it.
- **Released as [v0.1.6](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.6) (2026-10-30).** Spotlight
  and Siri indexing and the fixes above. Notes in `Docs/releases/0.1.6.md`.
  - Built clean from `9bb5b44`, notarized, and accepted by Gatekeeper; the downloaded DMG matches its `.sha256` and
    its ticket is stapled.
  - A build that reports 0.1.5, installed in `/Applications`, finds 0.1.6 through Check for Updates.

- **Legacy `.ppt` and password protection: E0–E3 released in 0.1.7, P1–P6 in 0.1.8 (2026-10-31).** The plan is
  `Docs/plans/Legacy-PPT-and-Encryption.md`: encryption first (E1–E3, its own release), then a `.ppt` reader (P1–P6).
  E0 installed the test tools outside the repo, downloaded [MS-CFB] and [MS-OLEPS], and added `Tools/legacy/`, which
  makes 363 test files from our own decks into the fixtures (every encrypted copy decrypts to its plaintext with two
  independent tools). With the operator watching, PowerPoint made 18 protected copies (kept local; Agile AES-256/SHA-512 for `.pptx`,
  RC4 CryptoAPI for `.ppt`), and its password prompts and File › Passwords… were observed (the plan's §2).
  - **E1 (2026-10-30): DCCFB**, a new L0 target that reads and writes compound files, version 3 and 4. It reads
    every compound file in the fixtures, and PowerPoint's own version 4 files, exactly as olefile does. The files it
    writes open in olefile and POI. It survives the hostile fixtures, deckcraft's 400 CFB inputs and 6,000 seeded
    mutations. Details are in `Packages/DCCFB/PORT-NOTES.md`.
  - **E2 (2026-10-30): opening protected `.pptx`.**
    - **DCOffCrypto** decrypts Agile and Standard encryption, which covers every fixture and PowerPoint's own files.
    - **Opening:** `file.open` and `file.openBytes` take `password`, the app asks for it, `app.open` and dccli
      (`DCCLI_PASSWORD`) pass it, and the password stays in memory with the document.
    - **Until E3:** a protected presentation isn't saved, and AutoRecover leaves it out.
    - Details are in `Packages/DCOffCrypto/PORT-NOTES.md`.
  - **E3 (2026-10-30): saving protected `.pptx`.**
    - **Writing:** DCOffCrypto encrypts as PowerPoint 16 does, and msoffcrypto-tool and POI both decrypt what it
      writes.
    - **Password to modify:** written and read, with Read Only for people without it.
    - **Setting passwords:** File › Passwords… and Review › Protect Presentation, with PowerPoint's sheet.
    - **Saving:** as `.pptx` keeps the passwords; as `.deckcraft` drops them and says so.
    - **AutoRecover** keeps leaving protected presentations out.
    - **PowerPoint:** the operator opened a file we encrypted, with both passwords, in PowerPoint (2026-10-30).
- **Released as [v0.1.7](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.7) (2026-10-30).** Opening
  and saving password-protected presentations (E1–E3 above). Notes in `Docs/releases/0.1.7.md`.
  - Built clean from `b954f3e`, notarized, and accepted by Gatekeeper; the downloaded DMG matches its `.sha256` and
    its ticket is stapled.
  - The installed 0.1.6 finds 0.1.7 through Check for Updates.
  - **P1 (2026-10-30): legacy `.ppt`, the container.**
    - **DCPPT** (new) reads the edit chain and persist directories, decrypts RC4 CryptoAPI (PowerPoint's default
      password first), and reads the slide size and slide list.
    - **Opening:** a `.ppt`, `.pot` or `.pps` opens as an untitled converted copy of blank slides, with a status line
      saying what isn't brought over yet. Content comes in P2–P5.
    - **The crash corpus:** of 207 real files, 205 open and 2 fail cleanly, with no crashes.
    - Details are in `Packages/DCPPT/PORT-NOTES.md`; not for a release until the content arrives.
  - **P2a (2026-10-30): `.ppt` text.** Slides now carry their text-bearing shapes and placeholders, in place, with
    paragraphs, levels, alignment, bullets, and bold, italic, underline, size, font and RGB colour, plus their notes.
    They match POI's reading of every fixture and of PowerPoint's own files. Masters and colour schemes are P2b.
  - **P2b (2026-10-30): `.ppt` masters and formatting.**
    - **Formatting:** text takes its formatting from the master's styles by text type and level: typefaces, sizes,
      colours, margins and hanging indents, spacing, and bullets. Scheme colours resolve.
    - **The master:** its colour scheme becomes the theme's colours. Its background, and slides' own backgrounds,
      come in as solid colours.
    - **Also:** headers and footers, and hyperlinks.
    - **Font lookups:** DCText caches the fallback order and document-face answers, cleared when a face is added.
      Rendering the crash corpus had found text-heavy files taking over 30 s; they now take under a second.
    - **Checked:** all 17,980 paragraph and run properties compared match POI's resolved formatting. The crash
      corpus, with every slide rendered, is clean.
  - **P3 (2026-10-30): `.ppt` shapes.**
    - **What comes over:** every shape. That covers:
      - the 203 legacy shape types as DrawingML presets, their adjust values rescaled the way PowerPoint writes them;
      - freeforms;
      - groups;
      - connectors joined to their shapes;
      - tables;
      - WordArt;
      - fill (solid, pattern, gradient), line, arrowheads and shadow;
      - the text frame;
      - names, alt text, hidden shapes and click actions.
    - **Checked:**
      - 17,259 shape properties match POI's dump.
      - PowerPoint's own `.ppt` of every gallery preset imports as the original presets with their adjust values.
      - The alpha gate opens a `.ppt` in the app.
      - The crash corpus, with every slide rendered, is clean.
    - **Still to come:** pictures and OLE objects (P4) and the slide show (P5). `.ppt` support isn't released yet.
  - **P4 (2026-10-30): `.ppt` pictures and objects.**
    - **What comes over:**
      - pictures (JPEG, PNG, DIB, TIFF, EMF and WMF), with their crop and corrections;
      - picture, texture and pattern fills;
      - picture backgrounds;
      - OLE objects and charts, as their preview picture;
      - linked movies, and embedded or linked sounds;
      - comments.
    - **PICT:** macOS can't draw it any more, so a PICT becomes the JPEG inside it, or a PNG drawn by AppKit.
    - **The report:** the import report names each object that became a picture.
    - **Encrypted files:** pictures are decrypted field by field, as PowerPoint writes them.
    - **A P3 fix:** placeholders in PowerPoint's own files no longer draw an outline.
    - **Checked:**
      - every picture's bytes match POI's;
      - PowerPoint's own save of a pictures deck imports as the original;
      - the crash corpus, with every slide rendered.
    - **Still to come:** the slide show (P5) and hardening (P6). `.ppt` support isn't released yet.
  - **P5 (2026-10-30): the `.ppt` slide show.**
    - **What comes over:**
      - transitions, by effect, direction and speed, with the slide's advance, sound and hidden state;
      - animations from PowerPoint 2002's timing tree, read by the same reader as a `.pptx`'s `p:timing`;
      - the `p:timing` PowerPoint 2007 embedded, where a slide has no tree;
      - PowerPoint 97's per-shape effects, mapped to the nearest effect. A hash tells when PowerPoint 97 changed
        them after a newer version saved the tree; then they win, as in PowerPoint.
    - **Not in a `.ppt`:** PowerPoint 2010's transitions. PowerPoint saves them as Fade.
    - **Checked:**
      - PowerPoint's and LibreOffice's saves of a motion deck come back as the original, apart from how LibreOffice
        writes some transitions and builds;
      - PowerPoint's saves of five more decks;
      - the crash corpus, with every slide rendered.
  - **P6 (2026-10-31): hardening, and the masters' own graphics.**
    - **The template's graphics come over** (added with the operator): logos, bars and lines on the slide master,
      title masters as layouts, and slides hiding them. 63% of the real decks have them.
    - **Bounded work:** each slide object is read once, at most 10,000 slides and 20,000 shapes in a drawing, one
      owner per outline text.
    - **Fuzzing:** structure-aware damage to every record reader, the Pictures stream, encryption headers and PICT.
      77,000 damaged files with no trap, and 7,700 of them through dccli's open and render with no crash or time-out.
    - **The crash corpus at full size**, all of Govdocs1's `.ppt`. Its first part (11,551 files) found a hang in
      FontDB, outside DCPPT: a font macOS downloads on demand (Osaka) blocked CoreText until someone answered macOS's download prompt.
      FontDB now asks CoreText only about installed fonts, and the four files open in under a second. Eight more
      waited the same way inside ImageIO's PICT decoder; a PICT now gets a 5 s deadline.
    - **The whole corpus:** 49,485 files. In Debug, 49,175 open and 310 fail cleanly (211 PowerPoint 95, 98 not
      presentations, one damaged). Rendering every slide in Release, 49,170 render. No crash and no hang. Five
      decks take 36–101 s to render, in DCRender's metafile rasterizer and font fallback, which `.pptx` shares.
- **Released as [v0.1.8](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.8) (2026-10-31).** Legacy
  `.ppt` files open as converted copies (P1–P6 above). Notes in `Docs/releases/0.1.8.md`.
  - Built from `905d3ac` in a clean worktree, notarized, and accepted by Gatekeeper; the downloaded DMG matches its
    `.sha256` and its ticket is stapled. The exported app opened the masters deck's `.ppt` with its template.
  - The installed 0.1.7 finds 0.1.8 through Check for Updates (`ui.updates`); 0.1.8 is now installed in
    `/Applications`.
- **Released as [v0.1.9](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.9) (2026-11-01).** The pin
  move to deckcraft `a3fbf029` (below), the slow `.ppt` renders (`86df54c`: five Govdocs1 decks from 42–94 s to
  1.1–6.2 s in Release) and long Outline titles wrapping (`cce8e12`). Notes in `Docs/releases/0.1.9.md`.
  - Built from `73cdddf`, notarized, and accepted by Gatekeeper; the downloaded DMG is identical to the build, matches
    its `.sha256` and its ticket is stapled.
  - The installed 0.1.8 finds 0.1.9 through Check for Updates (`ui.updates`); 0.1.9 is now installed in
    `/Applications`, where it reports itself up to date.
- **Released as [v0.1.10](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.10) (2026-11-01).** PDF export
  carries an image's edge colour under its transparent pixels, so a viewer that smooths images shows no dark fringe
  along hard edges (`3425a74`, DCRender `EdgeBleed`). Format ▸ Effects draws its Shadow, Glow and Soft Edges presets as
  tiles (`d3e1a59`, DCApp `EffectPresetTiles`). Notes in `Docs/releases/0.1.10.md`.
  - Built from `073326a`, notarized, and accepted by Gatekeeper; the downloaded DMG is identical to the build, matches
    its `.sha256` and its ticket is stapled. The first two-digit patch number: the update check orders versions by
    number (`UpdatesTests.ordersByPrecedence` now has 1.0.9 < 1.0.10).
  - The installed 0.1.9 finds 0.1.10 through Check for Updates (`ui.updates`); 0.1.10 is now installed in
    `/Applications`, where it reports itself up to date.
- **Released as [v0.1.11](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.11) (2026-11-01): the Accessibility Inspector audit.** Run over every main view in both layouts, with
  the target picked by the operator.
  - **Fixed:**
    - the ribbon, inspector, status bar, start window and dialogs are named regions;
    - the Slide Sorter's slides and section bars take VoiceOver's press;
    - the Format Painter row's split control is now a button and a named menu;
    - the section counts and the Outline's numbers have enough contrast.
  - **Left with reasons:** the remaining warnings come from SwiftUI and AppKit, or from where the audit measures
    (rows out of view, scroll-edge fades, sheets).
  - Details are in DCApp PORT-NOTES, "Accessibility Inspector audit".
  - Built from `d367c3e`, notarized, and accepted by Gatekeeper; the downloaded DMG is identical to the build. The
    installed 0.1.10 finds 0.1.11 through Check for Updates; 0.1.11 is now installed in `/Applications`, where it
    reports itself up to date.
- **Released as [v0.1.12](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.12) (2026-11-01): preview translations.** French, Italian, German and Spanish, AI-drafted for every
  String Catalog entry (2,778 per language).
  - **Terminology:** a glossary of Microsoft PowerPoint's own terms in each language (`Tools/l10n/glossary.json`).
  - **State:** every entry is marked `needs_review` until native speakers review it through the sheets in
    `Docs/localization/review/` (`Tools/l10n/translations.py`).
  - **Checks:**
    - `TranslationsTests` checks every format argument.
    - `Tools/app/ribbon-widths.sh languages` lays every ribbon tab out at four widths in each language (336 PASS).
  - **Still English:** the engine's text stays English, to keep DeckCraft parity.
  - **Tooling:** `sync.sh` now keeps the Info.plist catalog's translations.
  - **Quick Look:** the Quick Look and Thumbnail extensions declare the five languages (`CFBundleLocalizations`); without
    it their resource bundle stayed English.
  - **Release:** built from `18abd66` and notarized; the downloaded DMG is identical to the build. The installed 0.1.11
    finds 0.1.12 through Check for Updates; 0.1.12 is now installed in `/Applications`.
- **Released as [v0.1.13](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.13) (2026-11-01): creating a second presentation crashed.**
  - **What happened:** with one presentation open, a new one opening beside it ended the app with AppKit's "needs
    update constraints" exception (`EXC_BREAKPOINT` in `_postWindowNeedsUpdateConstraints`).
  - **Cause:**
    - Each window's canvas wrote its fit scale into the app model's `canvasScale` during layout
      (`CanvasView.relayout`, from `CanvasContainerView.layout`).
    - The status bars read that value, so SwiftUI asked for new constraints in the middle of the window's layout
      pass.
    - With two windows of different sizes, their canvases took turns writing different scales until AppKit threw.
    - The code dates from Wave 5. It reproduces on macOS 27.2 with any second presentation.
  - **Fix:** only the active presentation's canvas publishes its scale, on the run loop's next turn.
  - **Test:** `RibbonWindowTests.twoPresentationWindowsLayOutWithoutFighting`. With the old code the test process
    dies with the same trap.
  - **Release:** built from `a998ea3` and notarized; the downloaded DMG is identical to the build. The release
    build opened four presentations without a crash. The installed 0.1.12 finds 0.1.13 through Check for Updates;
    0.1.13 is now installed in `/Applications`.
- **Released as [v0.1.14](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.14) (2026-11-01): Slide Show › Set Up Show… and Insert › Table… opened no dialog.**
  - **Cause:** the menu tree (deckcraft's `menu_tree`) runs `show.setup` with no settings, which changes nothing.
    deckcraft's own menu does the same; its dialog opens only from the ribbon.
  - **Fix:** the menu item is now "Set Up Slide Show…" and opens the dialog, as the ribbon and the inspector do.
    `DialogsMenuTarget` entries take a `replaces:` command, which File › Properties… now uses too.
  - **Test:** `DialogsWindowTests.menuItemsForTheDialogs`. Checked in a signed build through the real menu bar.
  - **Insert › Table…:** found by an audit of every "…" menu item that runs an engine command. It inserted a 2 × 2
    table at once, as deckcraft's menu does. It now opens the Insert Table dialog, keeping its translated title.
    The other "…" items (Photo Album, Font, Paragraph, Size and Position) already open their dialogs, and Edit Photo
    Album explains when the slide isn't in an album.
  - **Release:** built from `923d7e5` and notarized; the downloaded DMG is identical to the build. Both menu items
    open their dialogs in the release build. The installed 0.1.13 finds 0.1.14 through Check for Updates; 0.1.14
    is now installed in `/Applications`.
- **Released as [v0.1.15](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.15) (2026-11-01): chart elements can be edited.** A chart's title, legend, data labels and gridlines
  had no control. The engine's `chart.options` sets them, but neither deckcraft's UI nor ours called it.
  - **Ribbon:** Chart Design has a Chart Layouts group with PowerPoint's Add Chart Element menu: Chart Title (None,
    Above Chart), Legend (None, Right, Top, Left, Bottom), Data Labels (None, Show) and Gridlines (None, Major
    Gridlines). The items come from `ChartElements` (DCAppModel).
  - **Inspector:** Format › Chart has a Chart Elements section:
    - a Chart Title switch, and a Title field that commits on Return or when it loses focus (emptying it removes the
      title);
    - a Legend position;
    - Data Labels and Gridlines switches.
  - **Undo:** each change is one `chart.options` command, so one undo step.
  - **Mac layout:** the Mac layout's map lists the new group.
  - **Strings:** new strings in French, Italian, German and Spanish, marked "needs review". The review sheets are
    regenerated, and the glossary has the chart terms.
  - **Tests:** `RibbonModelTests.addChartElementChangesTheChart`. Ribbon widths pass in en, fr, it, de and es. The
    section was checked in DeckCraftDev.
  - **Later:** editing the title on the canvas with a double-click.
  - **Release:** built from `2ff8aba` and notarized; the downloaded DMG is identical to the build. The release
    build shows the Chart Elements section with the chart's settings. It is the first release with the base
    packages in CraftNativeKit; its licence is now in `Acknowledgements.txt` (`Tools/acknowledgements.sh` reads a
    `LICENSE-MIT`). The installed 0.1.14 finds 0.1.15 through Check for Updates; 0.1.15 is now installed in
    `/Applications`.
- **After 0.1.15 (unreleased, 2026-11-04): an edited chart keeps its part (AB-T-0433).** Changing a
  chart's title, legend, data labels, gridlines or data regenerated its whole `c:chartSpace`, as deckcraft does. That lost
  what the model doesn't hold: the embedded workbook, the style and colour parts, label positions, fills, 3-D and the
  extension lists. The charts gap review found it on every PowerPoint-made chart.
  - **Now:** `chart.options` keeps the chart's original part, and the writer edits those four elements into it
    (`DCPPTX/WriteChartPatch.swift`). The patched part is used only when reading it back gives the model; anything
    else regenerates the part, as before. A text colour or palette still regenerates it, as do bins, subtotals,
    up/down bars and quartiles. This is a deliberate divergence from deckcraft: DCPPTX PORT-NOTES, divergence 8.
  - **Tests:** `WriteChartPatchTests` (5). `Tools/pptx/chart-edit-sweep.py` saves each file untouched and edited, then
    compares every chart part element by element, plus the parts it points at. It passed on the review's 9
    PowerPoint-made fixtures for each edit: a new title, a two-line title, no title, the legend at the top or removed,
    data labels on and off, gridlines on and off, and all four at once. `chart.type` is the positive control, and it
    fails as it should. PowerPoint opened 36 of the edited files without a repair prompt
    (`Tools/pptx/powerpoint-check.sh`). The oracle corpus is unchanged.
  - **`chart.data` (second half, same day):** Edit Data keeps the part too. The writer puts the categories, the
    series' names and values, and the generator's `c:f` ranges into it, and adds or removes series. It drops
    the embedded workbook, whose cells would contradict the chart; PowerPoint builds a new sheet from the chart,
    as it does for ours. The style, colour and drawing parts stay. Still regenerated: adding a series to a combo
    chart whose last group isn't clustered columns, category levels, and Office 2016 charts. `chart-edit-sweep.py
    --data` (values, rename, add or drop a series, add or drop a category) passes on all 9 fixtures and, with
    `--all-slides`, on every chart in `pp-types`, apart from adding a series to the two combos ending in lines.
    `WriteChartPatchTests` has 5 more tests.
- **After 0.1.15 (unreleased, 2026-11-05): a chart's data has a workbook behind it (AB-T-0435).** Every chart
  PowerPoint makes embeds an Excel workbook holding its data. deckcraft writes none, and since AB-T-0433 an edit to the
  data dropped the original's: PowerPoint's Edit Data then rebuilt a sheet from the chart, losing a user's formulas,
  other sheets and formatting.
  - **Now:** a chart whose data the writer wrote (new, regenerated, or edited by `chart.data`) is linked to a workbook
    (`DCPPTX/WriteChartWorkbook.swift`). An original in PowerPoint's layout is updated in place: the chart's cells set,
    cells it no longer reads cleared, its table resized and renamed, Excel told to recalculate; other sheets, cells and
    formatting stay. Anything else gets a new one-sheet workbook of the chart's data, with a warning when it replaces
    an original. Office 2016 charts are unchanged. A deliberate divergence from deckcraft: DCPPTX PORT-NOTES,
    divergence 9; the export oracle applies it to deckcraft's packages.
  - **Tests:** `WriteChartWorkbookTests` (6, one over 20 chart types). `chart-edit-sweep.py --data` now checks that each
    edited chart's workbook agrees with it: on the 9 PowerPoint fixtures, 7 originals were updated in place and 2
    charts that had none got one, in every mode. PowerPoint opened all 56 edited files and a deck of 13 charts
    made by `insert.chart` without a repair prompt. All 107 workbooks in them validate against SpreadsheetML apart from
    what Excel's own workbooks also carry (`xml:space` on `t`, `mc:Ignorable`). `Tools/pptx/validate.sh` now rejects
    parts that aren't well-formed (it skipped them) and knows SpreadsheetML. dccli's `convert` parity applies the
    same divergence. Full suite green apart from `aDenseShapeGradientRendersPromptly`, a timing test starved in the
    full run that passes alone (4.8 s). Excel (16.114.4) opened all 107 workbooks
    without a repair prompt (`Tools/pptx/excel-check.sh --from-pptx`; its controls: PowerPoint's own workbook OPEN-OK,
    the same with a renamed table column NEEDS-REPAIR). PowerPoint's Chart Design › Edit Data in Excel on the
    values-edited pp-native chart opened Sheet1 showing the edited numbers in B2:D5, with Table1 still at A1:D5.
- **After 0.1.15 (unreleased, 2026-11-05): the chart types we read are the ones we write (AB-T-0434).** deckcraft's
  writer saved a surface chart as an area chart, even a new one (`dc-types` slide 20), a 100 % stacked line as stacked,
  3-D and of-pie charts flat, and a combo's secondary-axis series on the primary axis. Since AB-T-0433 an element edit
  keeps the original part, but anything that regenerates it (a palette or text colour, a new type, a new chart) still
  changed the type.
  - **Now:** the model has optional fields deckcraft's doesn't: the types `percentLine` and `percentArea`, a chart's
    3-D view (`threeD`: `c:view3D` and the group's depth settings), `wireframe` and `ofPie` (the second plot's split).
    They are a patch over deckcraft's `chart.rs` that `Tools/port/generate.sh` applies before generating
    (`Tools/port/divergence/model-chart.patch`), and are left out of `presentation.json` when unset. The reader keeps
    them, and the writer writes `c:surfaceChart` (a contour) or `c:surface3DChart`, `percentStacked` lines and areas,
    `c:bar3DChart`, `c:line3DChart`, `c:area3DChart` and `c:pie3DChart` with their view, `c:ofPieChart` with its
    split, and a combo's second `c:valAx` with its own plot groups. 100 % lines and areas are drawn as shares;
    3-D charts are still drawn flat and of-pie charts as one pie. `insert.chart` and `chart.type` take the two
    new types; `chart.type` clears the 3-D view and split. Deliberate divergences: DCModel PORT-NOTES (its
    divergence section), DCPPTX PORT-NOTES divergence 10, DCEngine and DCRender PORT-NOTES.
  - **Tests:** `WriteChartTypesTests` (8) and `InsertCommandTests.chartTypeNamesThePercentLinesAndDropsThreeD`. On the
    review's PowerPoint fixtures `pp-contour`, `pp-pctline`, `pp-col3d`, `pp-barofpie` and `pp-combo2`, a palette
    edit (which regenerates the part) now keeps `surfaceChart` with `view3D` and `wireframe`, `percentStacked`,
    `bar3DChart` with `view3D` and `shape`, `ofPieChart` with its split settings, and two `c:valAx`; a title edit
    keeps every element and part (`chart-edit-sweep.py`). A deck of all 29 types from `insert.chart` writes
    `c:surfaceChart` for the surface. Those ten edited files, that deck and a deck of every 3-D, wireframe, of-pie
    and secondary-axis variant validate against the ECMA schemas, and PowerPoint (16.114) opened all twelve without
    a repair prompt (`Tools/pptx/powerpoint-check.sh`). The oracle corpus is unchanged (187 files match
    `SHA256SUMS`; no corpus deck has one of these charts). The full suite passes: 2,325 tests in all 19 bundles (DCRender's parity tests
    in release, as its PORT-NOTES runs them; in one serial debug run `aDenseShapeGradientRendersPromptly` was again
    starved past its 20 s limit and passes alone).
  - **Still open:** formatting the model doesn't hold (3-D floor and walls, contour band colours, of-pie connector
    lines' look) is lost when a part is regenerated. 3-D charts aren't drawn in 3-D (out of scope in the review) and
    the of-pie's second plot isn't drawn (decision 3: preserve now, draw it later). Stacked and 100 % areas fill each series down to the axis, so the
    last one covers the others (as before this change).
- **After 0.1.15 (unreleased, 2026-11-04): the show's renderer is its own public target, `DCShow`.** Until now the
  show's drawing was internal to DCApp (`ShowStage`, `ShowMetal`), so only the show window could draw a show. A
  consumer (the first is MVS's Marquee Presentation, which plays a deck inside another app's Metal compositor) needs
  to draw a running show into a texture it owns.
  - **Now:** `DCShow` has `ShowMetal` (public, `init?(device:queue:)` to draw on a host's device and in its queue's
    order), `ShowRenderer` (was `ShowStage`: `frame(bounds:scale:now:)`, `frame(pixels:now:)`,
    `encode(_:into:commandBuffer:clear:)` into a `.bgra8Unorm`/`.rgba8Unorm` render target, `renderOffscreen`, and
    presenter view's pictures) and `ShowFramePacer` (when to draw: `ShowView.tick`'s rule, moved). Metal and Core
    Graphics only. `ShowView` is its first client. Nothing the show draws changed.
  - **Tests:** `ShowGoldenTests` wrote 168 frames of the four corpus decks (rest and mid-transition) before the move
    and found them byte-identical after it. `ShowRendererTests` (6): a show drawn into a caller's BGRA texture on the
    caller's device and queue equals the offscreen frame pixel for pixel; non-render-target and sRGB targets are
    refused; the pacer; an ended show's empty frame; DCShow imports no UI framework. DCApp and DCAppModel suites:
    507 tests green.
  - **Then (2026-11-04): what the audience sees over the slide moved in too.** The end screen's line, the blank
    screens (B, W) and ink are drawn by the renderer (`ShowOverlays.swift`), so a client of the renderer alone sees
    them; the window's AppKit overlay keeps what follows the pointer or serves the presenter (the laser, media bars,
    GIF buttons, Go to slide, the zoom prompt, See All Slides, the rehearsal HUD). The end line matches AppKit's
    layout of it: set at 18 points under the scaled context (an 18 × scale font takes the system face's narrower
    display design) with AppKit's whole-point line metrics. `ShowFramePacer.observe` notices show changes no one
    reported (presenter view's B and W, ink). `ShowOverlayGoldenTests`: the window's whole picture identical in
    every case (slide, black, white, ink over black, end screen, end screen with ink), ink within 1 level on 0.008 %
    of channels. `ShowRendererTests` +4 (blank, ink and end screen from the renderer alone; the pacer's observe).
    519 tests green; alpha gate 24/24 in both layouts.
  - **Then (2026-11-04): `AppIdentity`, so a product built on DeckCraftNative ships under its own name.** A host that
    links DCApp sets `AppIdentity.current` before `DeckCraftApp.main()`: name, version, releases repo and tag prefix,
    installer name, support folder, an About line. Text that names DeckCraftNative keeps its catalog keys and
    translations and is branded after localizing (`String.branded`: the name is never translated). The update feed
    takes only the product's own tag prefix, so products can share a releases repo (`presentation-v0.1.0` beside
    `windows-v1.2.0`). DeckCraftNative's own identity, feed and text are unchanged. `AppIdentityTests` (3); 529 app
    tests green. Its first user is MVS's Marquee Presentation.
  - **Then (2026-11-04): `ShowTextureSource`.** A running show as one BGRA texture a host composites: the host's display
    loop calls `tick(now:)`, and the source draws only when the picture changed, moving `generation` (one texture is
    enough on the host's own queue). It starts and ends its show, takes keys as the show window does, and resizes.
    `ShowKey(keyCode:characters:)` is the show window's key mapping, now public in DCAppModel. `ShowTextureSourceTests`
    (6): the texture equals the renderer's frame pixel for pixel. Its first host is MVS's booth preview.
  - **Then (2026-11-04): `dccli render-show`, the show's frame rate measured.** It plays a deck's show in real time
    through `ShowRenderer` into an offscreen texture and times each frame it draws (`Apps/dccli/RenderShow.swift`;
    it runs on the main thread, before the engine thread, since the coordinator is main-actor; its help page is
    left out of the overview, which stays deckcraft-cli's). First numbers, M5 Max, release, 60 fps:
    - **Transitions:** p50 1.7–4.1 ms and p95 ≤ 12 ms at 1080p to 4K.
    - **1080p H.264 video:** 1.1–1.5 ms a frame.
    - **Animated plain shapes:** 5 ms at 1080p, 19 ms at 4K.
    - **Morph:** 39–57 ms at 1080p and 150–226 ms at 4K (`renderBlend` on the CPU every frame).
    - **Shapes with glow, shadow and soft edges animating in:** 124 ms at 1080p and 620 ms at 4K. The moving
      shapes' effect blurs are re-rendered on the CPU each frame.
    - **The GPU** is never more than 7 ms.

    The animated layers and Morph want GPU work (a shape rendered once into a texture, its transform and opacity
    animated on the GPU). That matters for the show window on a 5K display as much as for a texture client.
    `RenderShowTests` (3). The glow and video decks were built with `dccli run` (12 shapes with glow, outer shadow
    and soft edges animated in, per slide; a full-slide 1080p30 H.264 clip); the raw data is kept with the consumer.

## CraftNativeKit (2026-11-01)

DCCore, DCZip, DCCFB, DCOffCrypto and DCMetafile moved out of this repo at `5991914` into
[xocialize/CraftNativeKit](https://github.com/xocialize/CraftNativeKit) 0.1.0, renamed CNCore, CNZip, CNCFB,
CNOffCrypto and CNMetafile, so Marquee Documents (the WordCraft port) builds on the same code. Their 182 tests
moved with them and pass there unchanged. `serde2swift.py` moved too; `Tools/port/generate.sh` runs the kit's copy
and writes the same `Types.generated.swift` apart from `import CNCore`. The fixtures stay here, and the kit reads
them from `../DeckCraftNative-Fixtures`. The figures for these packages above are history up to the move.

## Pin moves

### 88c2ceff → a3fbf029 (2026-10-31, after 0.1.8)

- **What changed upstream, in 277 commits** (149 touch crates; deckcraft is now 0.13.1, craft-libs `c5a1cbfb`,
  craft-fonts unchanged).
  - **Refactors for strict Clippy** (`cognitive_complexity`, `too_many_arguments`, `wildcard_imports` now deny):
    functions split and arguments packed, in geom, model, text, metafile, render, pptx, engine and the CLI. Audited
    hunk by hunk; none changes behaviour, so none is ported.
  - **Behaviour, ported** (each package's PORT-NOTES has the commit-by-commit list under "Pin move 88c2ceff →
    a3fbf029"):
    - **Model:** gradient flip, line miter limit and alignment, bullet font/colour/size follow-text resets and
      their inheritance, histogram values on a bin edge, CRLF in `replaceText`, Darken/Desaturate preset ids and
      PowerPoint's default durations for 14 effects.
    - **Text:** Unicode symbol-font bullets through the fallback chain (a dot, never .notdef), a space after a
      symbol-font character keeps the run's font, "Start at" restarts numbering, long English dates per locale,
      variable-font instances under their Windows family names, bounded font collections.
    - **Render, metafile, anim:** shapes with non-finite or huge outlines are skipped, no labels for missing bar
      values, animation state never reaches layout or master shapes, bounded EMF+ region paths, the show
      remembers a slide was reached going back.
    - **PPTX:** the new model fields read and written, Auto-reverse from behaviour nodes, media settings from the
      timing tree, the Darken/Desaturate HSL shift, custom-geometry exponents, backslash zip names, picture
      placeholders take their layout's shape, `tickLblPos none` and unfilled gridlines.
    - **Engine:** bad indexes refused instead of falling back to the selection (seven commands), Slide background
      fill, Duplicate and paste naming, group boxes follow their children, review.compare sides and boxes,
      layout and master formatting reaching slides, clipboard HTML caps and paste fixes, spelling of all-caps
      words, accessibility contrast across runs, motion paths from points, insert in master views, hidden
      system fonts, and the new `slide.actions` (331 commands).
    - **Automation and media:** MCP `insert_chart` box, bounded MCP frames (replacing our session-ending
      256 MiB limit), repeated automation roots, `run --cmd-file`, output finished after stdout closes, whole-deck
      bench statistics, Ogg damage recovery within its budget.
    - **App** (not a port of the egui UI; user-visible changes only): effect presets that remember their choice,
      Scale Height/Width and Position From, gradient flip kept when editing a fill, show clicks on animated
      shapes, Keep mouse cursor visible, presenter answers and the Next preview off the main thread, dragging several
      selected slides at once, Fill ▸ Slide background fill, a shadow Size slider, and going back in a show playing
      the left slide's transition in reverse.
  - **Doesn't apply:** the codec crates (replaced by VideoToolbox and libvpx), deckcraft's raster PDF backdrop fix
    (our PDF is vector; a related dark-fringe risk on transparent rasters is noted in DCRender's PORT-NOTES), the
    egui print preview, updater and media bar.
- **The oracle at the new pin.** `deckcraft-cli` 0.13.1 built from `a3fbf029`; the corpus and every vector set
  regenerated (fixtures `3426eba`, local). The 88c2ceff corpus was removed once 0.1.9 shipped.
- **Tests.** The full suite passes, apart from two cases. `aDenseShapeGradientRendersPromptly` timed out under the
  load of the full run and passes alone, as before. `outlineRowsFollowTheScrollerStyle` failed the same way on `86df54c`. It only passed
  on a Mac that started with legacy scroll bars; `cce8e12` makes it independent of that. Checking the Outline in the
  app found long titles drawn on one line and cut off, fixed in the same commit. The alpha gate passes in both
  layouts (24/24 each).

### 27009cd9 → 88c2ceff (2026-10-27, after Wave 6)

- **What changed upstream, in 66 commits.**
  - **Moves and splits (the bulk):** files were moved and split, with no change in behaviour. Compared crate by crate
    as a multiset of code lines (imports, module lines and visibility ignored), every ported crate differs only by
    re-paths (`super::` → `crate::cmd::`), re-exports and rustfmt reflows.
  - **`apps/deckcraft-cli`:** `bench` times PDF export over every run, not 3. Ported (`dccli bench`).
  - **`crates/pdf`:** PDF export reuses equal slide backdrops, which makes it faster. This is deckcraft's raster PDF
    writer; DCRender's vector PDF has no backdrop raster, so it doesn't apply.
  - **`crates/ui-egui`:** dropdowns use craft-ui's ComboBox. It's egui only; the Mac app has its own controls.
  - **Tests and CI:** an engine test helper (`file_access.rs`'s source scan reads past `#[cfg(test)]` imports, which
    isn't ported), plus CI and docs.
- **The oracle at the new pin gives the same answers.**
  - **The corpus is byte-identical:** every deck, rendered slide, `.pptx` and Markdown file, and every transition
    frame. The only differences are `info.json`'s absolute path (which contains the pin), the review deck's comment
    dates (they come from the clock, and tests blank them) and the PDFs (deckcraft's writer changed, see above).
  - **The other vectors:** regenerated. The json, display, geom, metafile, media and anim vectors are unchanged. The
    engine, PPTX and pointer vectors differ only by that path and those dates. The text vectors now cover every
    corpus deck (272 bodies from 19 decks, up from Wave 2's corpus).
  - **Our tests at the new pin:** every one passes (2,144, plus release parity, Metal parity and the 18 alpha-gate
    checks). The old corpus is retired from the fixtures.
- **Source paths.** Each ported file's header and each package's PORT-NOTES name the Rust source as it was at
  `27009cd9`. Where upstream has since moved it:

| At 27009cd9 | At 88c2ceff |
|---|---|
| `engine/src/cmd/mod.rs` | `engine/src/cmd.rs` |
| `engine/src/cmd/design.rs` | `engine/src/cmd/design.rs` + `cmd/design/{colors,slide_background,slide_setup,master_view,tests,browse_theme_tests}.rs` |
| `engine/src/cmd/format.rs` | `engine/src/cmd/format.rs` + `cmd/format/{font,text_effects,paragraph,painter,ruler}.rs` |
| `engine/src/cmd/insert.rs` | `engine/src/cmd/insert.rs` + `cmd/insert/{picture,album,chart,text_fields,links,icon_and_picture_tests}.rs` |
| `engine/src/cmd/smartart.rs` | `engine/src/cmd/smartart.rs` + `cmd/smartart/{nodes,paint,layout,diagrams,edit}.rs` |
| `engine/src/cmd/text.rs` | `engine/src/cmd/text.rs` + `cmd/text/{ime,layout,editing,autocorrect,caret,formatting}.rs` |
| `engine/src/cmd/shape.rs` | `engine/src/cmd/shape.rs` + `cmd/shape/{size,appearance,picture,freeform}.rs` |
| `engine/src/tools.rs` | `engine/src/tools.rs` + `tools/{hit,pointer,drag,click,geometry}.rs` |
| `pptx/src/read/mod.rs`, `pptx/src/write/mod.rs` | `pptx/src/read.rs`, `pptx/src/write.rs` |
| `render/src/lib.rs` | `render/src/lib.rs` + `{raster,opts,slide,renderer,geometry,stroke,text_draw}.rs` |
| `text/src/lib.rs` | `text/src/lib.rs` + `{run,style,autonum,shape,symbol,breaking,layout}.rs` |
| `geom/src/preset.rs` | `geom/src/preset.rs` + `preset/{catalog,builder,build,shapes,tests}.rs` |
| `fonts/src/lib.rs`, `format/src/lib.rs` (tests) | `fonts/src/tests.rs`, `format/src/tests.rs` |
| `media/src/player.rs` (tests) | `media/src/player/tests.rs` |
| `apps/deckcraft/src/control_server.rs` (tests) | `apps/deckcraft/src/control_server/tests.rs` |
| `ui-egui/src/{lib,canvas,dialogs,ribbon,panes,show,icons,backstage}.rs` | split into `app/`, `canvas/`, `dialogs/`, `ribbon/`, `panels/`, `show/`, `icons/`, `backstage/` (panes → panels; thumbs, selpane, notes, fillui, animtimeline → `panels/`; preview, squiggles → `canvas/`; credits, updates_ui → `dialogs/`; qat → `ribbon/`) |

## Crates

| deckcraft crate | Rust lines | Disposition | Target | Wave | Status |
|---|---:|---|---|:-:|---|
| geom | 5,796 | Port | DCGeometry | 1 | **done** — 70 tests; bit-identical to the oracle |
| color | 831 | Port | DCColor | 1 | **done** — 8 tests |
| model | 9,114 | Port (types generated) | DCModel | 1 | **done** — 96 tests |
| format | 2,140 | Port, byte-compatible | DCFormat | 1 | **done** — 42 tests; corpus round-trips byte-identical |
| metafile | 7,172 | Port | DCMetafile → CNMetafile (CraftNativeKit, 2026-11-01) | 2 | **done** — 113 tests; bit-identical to the oracle on 325 cases |
| fonts | 3,173 | Replace (CoreText); port the substitution table | DCText | 2 | **done** — with text |
| text | 5,452 | Combine: CoreText plus the ported layout policy | DCText | 2 | **done** — 110 tests; line breaks identical on the corpus |
| render | 13,813 | Port onto CoreGraphics | DCRender | 2, 4 | **done** — 225 tests; SSIMULACRA2 ≥ 89.2 on every corpus slide; Morph and transitions added in Wave 4 |
| pdf | 1,310 | Replace (CGPDFContext) | DCRender | 2 | **done** — vector slides, real-text layer |
| pptx | 19,837 | Port | DCPPTX | 3 | **done** — 193 tests; import and export byte-identical to the oracle, schema-valid |
| anim | 6,036 | Port; compositing in DCRender | DCAnim | 4 | **done** — 102 tests; easing, motion paths, timelines, the show state machine, transition layers and Morph frames bit-identical to the oracle ([PORT-NOTES](Packages/DCAnim/PORT-NOTES.md)) |
| media | 2,974 | Replace (AVFoundation, media-bridge) | DCMedia | 4 | **done** — 62 tests; header probes identical to the oracle (they're stored in documents); decode on AVFoundation, VideoToolbox and media-bridge ([PORT-NOTES](Packages/DCMedia/PORT-NOTES.md)) |
| h264, hevc, vp9, av1, opus, ogg, bitstream, isobmff, matroska | 51,691 | Replace (VideoToolbox, media-bridge, matroska-swift) | DCMedia | 4 | **replaced** — container parsing ported where the probes need it; decoding is native. VP8 and VP9 go through a decoder the app registers (Wave 5 decides on vpx-swift) |
| engine | 40,266 | Port | DCEngine | 4, 5 | **done** — 549 tests; all 330 commands registered as deckcraft declares them; 44 engine scripts give deckcraft's answers and decks; the pointer (`tools.rs`, Wave 5): 7 MCP sessions give deckcraft's replies and decks ([PORT-NOTES](Packages/DCEngine/PORT-NOTES.md)) |
| mcp | 1,689 | Port (swift-sdk) | DCAutomation | 4 | **done** (the pointer since `Session.pointer` landed, Wave 5) — every `#[test]` ported; MCP replies byte-identical to the oracle; control.rs ported for the methods that need no window; the app's `control_server.rs` too (`ControlServer`) ([PORT-NOTES](Packages/DCAutomation/PORT-NOTES.md)) |
| apps/deckcraft-cli | 1,432 | Port | dccli | 4 | **done** — every subcommand; commands, describe, help, errors, scripts, info and convert identical to the oracle ([PORT-NOTES](Packages/DCAutomation/PORT-NOTES.md#dccli)) |
| ui-egui, apps/deckcraft | 44,551 | Rewrite (AppKit, SwiftUI) | DCApp | 5 | **done** — 331 tests; all six alpha-gate workflows pass in the app; String Catalogs not started ([PORT-NOTES](Packages/DCApp/PORT-NOTES.md)) |
| apps/deckcraft-web | 227 | Drop | — | — | — |
| xtask | 1,489 | Drop; scripts where needed | Tools | — | — |

## Decisions recorded

- 2026-10-26: `.deckcraft` compatibility means byte-identical `presentation.json`, not a byte-identical zip
  (DEFLATE streams differ). The manifest's `generator` names this app.
- 2026-10-26: a Rust variant named `None` is `none_` in Swift, so it can't be confused with `Optional.none`.
- 2026-10-26: the port lives in `research/DeckCraftNative`. It targets macOS 26+ on Apple Silicon only,
  with a Mac-native UI that keeps PowerPoint's verbs and drops the ribbon.
  **Amended 2026-10-27 (operator):** the ribbon returns as an optional window layout beside the inspector,
  with a start screen at launch; the Mac layout stays the default until the plan's R4 passes, then new installs
  get the ribbon. Familiarity for PowerPoint users, not a 100% match ([Docs/plans/Ribbon-and-StartScreen.md](Docs/plans/Ribbon-and-StartScreen.md)).
- 2026-10-26: PDF export writes vector slides (a recorded `Canvas` replayed into CGPDFContext) with an
  invisible CoreText text layer, where deckcraft rasterises. Blurs and backdrop compose modes are rasterised
  at the export's dpi.
- 2026-10-26: render parity is SSIMULACRA2 against the oracle's PNGs, with a floor of 88 per slide, measured
  in release.
- 2026-10-26: native frameworks over ported third-party libraries, unless there's a good reason. Merge
  Shapes uses CoreGraphics' path boolean operations, not a port of `i_overlay` (about 43k lines with its
  helper crates). Its outlines aren't byte-identical to deckcraft's, so they are checked by area and render.
  Values stored in documents, such as media probe results, stay exact ports.
- 2026-10-27: the app is AppKit and SwiftUI over the one engine session: an NSDocument per engine document
  (by `DocState.uid`), every action through `AppModel.run`, DesignScaffold's tokens for the design
  vocabulary (AB-D-0042). The app's code is the `DCApp` library, so it builds and tests with `swift test`.
  The Xcode target is a thin wrapper.
- 2026-10-27: PowerPoint for Mac is a black-box oracle, for checking that a `.pptx` opens without repair.
  Nothing it saves, renders or shows enters the repository or the fixtures.
- 2026-10-26: PPTX parity is byte-identical parts on export and a byte-identical model on import, over the
  oracle corpus. Written packages also validate against the ECMA-376 Transitional schemas, after markup
  compatibility. The zip container may differ: DCZip stores a part that wouldn't shrink.
- 2026-10-26: the XML parser is hand-written over bytes, as quick-xml reads. Foundation's `XMLParser` is
  stricter and refuses parts deckcraft reads.
- 2026-10-26: the oracle builds from source with Homebrew's `rustup`. The release binary (v0.11.1) is 112
  commits behind the pin.
- 2026-10-27: PPTX export gives every `chartEx` part a chart style and a colour style part, which deckcraft
  doesn't write; without them Microsoft PowerPoint repairs the file. Byte identity with deckcraft is broken
  for those parts only, which `PPTXExportOracleTests` allows by name and checks byte for byte
  ([PORT-NOTES](Packages/DCPPTX/PORT-NOTES.md), write/ divergence 7).
