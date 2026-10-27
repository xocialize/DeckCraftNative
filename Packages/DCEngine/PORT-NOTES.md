# DCEngine — port notes

Port of deckcraft `crates/engine` at the pin in `Tools/oracle/pin.env`. **Status: the core is done** (Wave 4,
first step): the Session, history, the command registry and its shared helpers, and the `file`, `edit`, `slide`,
`selection` and `inspect` command modules, with keys, AutoRecover, the automation roots, media references, fonts,
sounds, templates, GIF export and the sample deck. The other 24 command modules are ported next, in parallel, on
top of this core (see [Registry layout](#registry-layout)).

- **Code:** about 7,500 lines of Swift in `Sources/DCEngine`, 3,300 lines of tests.
- **Tests:** 180 in 19 suites, all green: 140 run today, and 40 (among them the suites "Text keys" and "Selection
  pane") need commands from modules that aren't ported yet, so they are skipped until those commands are
  registered and then run with no change.
- **Oracle parity:** 7 engine scripts give deckcraft-cli's answers line for line and its deck byte for byte (see
  [Script parity](#script-parity)).

## File map

| Rust (`crates/engine/src`) | Swift (`Sources/DCEngine`) | Notes |
|---|---|---|
| `lib.rs` | `Engine.swift` | `EngineError`, `TextSel`, `Target`, `Selection`, `History`, `DocState`, `Prefs`, `UiRequest`, `Clipboard`, `Session` (execute, edit, select, composition), `clampSelection`, `undoCost`, `pushUndo`; `page_master`/`shapes_mut`/`page_size`/`master_page` as free functions |
| `cmd/mod.rs` | `Registry.swift` | `CommandSpec` (`.cmd` / `.query` / `.noundo` for the three `cmd!` kinds), `CommandInfo`, `CommandSpecs.all`, `findCommand`, `Cmd.*` (predicates, reasons, param helpers, `parseParams`, `needsArguments`, `targets`, `colorValue`, `xfrmOf`, `editShapes`, `editGeometry`, base64) |
| `cmd/edit.rs` | `CmdEdit.swift` | `EditCommands` |
| `cmd/richclip.rs` | `RichClip.swift` | |
| `cmd/file.rs` | `CmdFile.swift` | `FileCommands`, `Damage`, `LoadedFile`, `RustPath` (Rust's `Path` name helpers) |
| `cmd/slide.rs` | `CmdSlide.swift` | `SlideCommands` |
| `cmd/selection.rs` | `CmdSelection.swift` | `SelectionCommands` |
| `cmd/inspect.rs` | `CmdInspect.swift` | `InspectCommands` |
| `cmd/<module>.rs` (24 more) | `Cmd<Module>.swift` | `<Module>Commands`, empty until its agent ports it |
| `guard.rs` | `Guard.swift` | see Divergences |
| `connect.rs` | `Connect.swift` | `Session.edit` reroutes glued connectors |
| `tools.rs` | `Tools.swift` | the data types and `line_xfrm` only; see [Not ported](#not-ported) |
| `compare.rs` | `Compare.swift` | the data types only (`DocState` holds a `Compare`); the review agent ports the rest into this file |
| `io.rs` | `IO.swift` | POSIX: atomic write through a `.saving` sibling, permissions kept |
| `file_access.rs` | `FileAccess.swift` | `AutomationRoots`, `FileAccess.confine` / `unconfined` / `confineProcess` |
| `recovery.rs` | `Recovery.swift` | `flock` owner locks, as Rust's `File::try_lock` |
| `fonts.rs` | `EngineFonts.swift` | |
| `sounds.rs` | `Sounds.swift` | the same arithmetic, so the same WAV bytes |
| `media_refs.rs` | `MediaRefs.swift` | the macro's two expansions written out: `MediaRefs.Visit` and `MediaRefs.VisitMut` |
| `templates.rs` | `Templates.swift` | the starter data converted from the Rust source by script |
| `gif_export.rs` | `GifExport.swift` | ImageIO encodes the frames |
| — | `ImageEncoding.swift` | deckcraft-render's `Image::to_png_at` / `to_jpeg_at` and `dpi_for_scale`, on ImageIO |
| `keys.rs` | `Keys.swift` | `Keys.shortcutMatches`, `Keys.keyToken`, `Session.key` / `typeText` / `composeText` / `commitText` / `deleteSurrounding` |
| `sample.rs` | `Sample.swift` | `Sample.openSample`; `Sample.commands` lists what it runs |
| `links.rs` | `Links.swift` | |
| — | `JSONValue.swift` | serde_json's `Value` on DCCore's `JSON`: literals, accessors, `canonical`, `display` |
| — | `MediaProbe.swift` | the seam for DCMedia (see [DCMedia](#dcmedia)) |
| `tests.rs`, `tests_keys.rs`, `cmd/selection_tests.rs`, in-file tests | `Tests/DCEngineTests/*` | see [Tests](#tests) |

## Session API

The command modules are written against this. Rust's names are kept, in Swift spelling.

- **`Session`** is a `final class` (Rust's `&mut Session`), used from one isolation domain. `execute(_:_:)
  throws(EngineError) -> JSON` runs a command; inside commands, functions throw untyped and `execute` turns any
  error into an `EngineError` (`EngineError.from`). `Session.withNew()` opens one presentation.
- **`DocState`** is a `final class` (Rust hands out `&mut DocState`): `try s.doc()` / `try s.docMut()` return
  the same object; `s.activeDoc` is the optional. `copy()` is Rust's `Clone`.
- **`DocRef`** is `Arc<Presentation>`: an immutable box whose identity (`===`) is `Arc::ptr_eq`. `st.doc` reads
  the presentation, `st.docRef = DocRef(p)` replaces it (Rust: `st.doc = Arc::new(p)`), and `isDirty` is
  `docRef !== savedDocRef`. Slides and masters are plain values (copy-on-write arrays, as DCModel has them).
- **Editing:** `try s.edit { doc, sel in … }` gives the presentation and selection `inout`, reroutes glued
  connectors and bumps the revision (an undo step is made by `execute`). `try s.select { doc, sel in … }`
  changes only the selection. Inside them:
  - `treeShapes(doc, sel)` (`Cmd.currentShapes`) reads the edited tree;
  - `mutateShapes(&doc, sel) { shapes in … }` is `shapes_mut` (nil when the tree doesn't exist), and
    `try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { shapes in … }` is the
    `shapes_mut(..).ok_or_else(..)?` pattern;
  - `withShape(&shapes, id) { sh in … }` is `find_shape_mut` (groups included; nil when not found);
  - `walkMut(&shapes) { sh in … }`, `pageMaster`, `mutatePageMaster`, `masterPage`, `pageSize`;
  - DCModel's `findShape`, `walk`, `parentOf`, `shapePath`, `Shape.mutateChildren` (`children_mut`).
- **Parameters and answers** are DCCore `JSON`. `JSONValue.swift` adds serde_json's accessors
  (`p.get("key")`, `.at(i)`, `asF64`, `asU64`, `asI64`, `asUsize`, `asU32`, `asStr`, `asBool`, `asArray`,
  `asObject`) and literals, so `json!({"ids": ids})` is `["ids": ids.toJSON()]`; `.num(x)` is `json!(f64)`
  (null when not finite), `.integer(n)`, `.string(s)`, `.opt(x)`, `.emptyObject`. Build answers in any key order:
  `canonical` sorts keys, widens `f32` and nulls non-finite floats, as a serde_json `Value` does, and `display` is
  `format!("{}", value)`, which is what the CLI prints.
- **Errors:** `Cmd.bad(cmd, msg)` is `bad`; `EngineError.other`, `.noDocument`, `.disabled`, `.unknownCommand`.
- **Writing a command** (the shape every module follows):

  ```swift
  public enum ShapeCommands {
      public static func specs() -> [CommandSpec] {
          [
              .cmd("shape.rename", "Rename", [], nil, "{id, name}", Cmd.hasSlide, rename),
              .query("shape.sites", "Connection Sites", [], nil, "{id} → [[x, y]]", Cmd.hasSlide, sites),
          ]
      }

      @Sendable static func rename(_ s: Session, _ p: JSON) throws -> JSON {
          let name = Cmd.strParam(p, "name") ?? ""
          return try Cmd.editShapes(s, p, "shape.rename") { $0.name = name }
      }
  }
  ```

  Enabled predicates are `@Sendable (Session) -> String?`: the reason the command is unavailable, nil when it is
  (Rust: `Err(reason)` / `Ok(())`).
- **Shared state types declared by the core** because the Session or DocState holds them: `Painted`
  (format.rs), `AutoList` (text.rs), `Compare` / `ChangeKey` / `ChangeKind` (compare.rs), `ToolState`, `Drag`,
  `Hit`, `Guide`, `Mods`, `PointerEvent`, `PointerKind`, `ToolKind` (tools.rs), `LastDuplicate`,
  `VertexKind` (`(ShapeId, usize, usize, String)`), `CellRange` and `TextPoint` (Rust's `(usize, usize)`
  tuples in `Selection`). Modules use these and must not redeclare them.

## Registry layout

`CommandSpecs.all` concatenates the modules' `specs()` in Rust's `command_specs` order: file, edit, slide, reuse,
insert, smartart, shape, background, picture_style, recolor, arrange, selection, merge, points, text, format,
design, ideas, transition, animation, table, find, review, inspect, media, artistic, zoom, compress. Each module
is one file, `Cmd<Module>.swift`, declaring `public enum <Module>Commands { public static func specs() ->
[CommandSpec] }`. A module not yet ported returns `[]`, with a `// Wave 4: ported by the <group> agent` comment.
The groups are a suggestion by line count; the agents can trade modules:

| Group | Modules (Swift file) | Rust lines | Also owns |
|---|---|---:|---|
| text | text (`CmdText`), format (`CmdFormat`), find (`CmdFind`), table (`CmdTable`), review (`CmdReview`) | 5,906 | `spell.rs`, `thesaurus.rs`, the rest of `compare.rs` (into `Compare.swift`), `drawtable.rs` |
| shapes | shape (`CmdShape`), arrange (`CmdArrange`), points (`CmdPoints`), merge (`CmdMerge`), three_d (`CmdThreeD`), picture_style (`CmdPictureStyle`), recolor (`CmdRecolor`), artistic (`CmdArtistic`) | 4,534 | `inkshape.rs` |
| insert | insert (`CmdInsert`), smartart (`CmdSmartArt`), media (`CmdMedia`), compress (`CmdCompress`), zoom (`CmdZoom`), reuse (`CmdReuse`) | 5,755 | `icons.rs`, `icon_data.rs` |
| design | design (`CmdDesign`), background (`CmdBackground`), ideas (`CmdIdeas`), transition (`CmdTransition`), animation (`CmdAnimation`) | 4,043 | |

Once every module is filled in, `theRegistryMatchesTheOraclesCommandList` checks all 330 commands against the
oracle's `commands.txt` (id, label, params, order); today it checks the 62 registered ones and passes.

### Helpers the core calls in other modules

These are declared in the module's file under `// MARK: - Called by the core`. **Keep the signatures.**

| Swift | Rust | State |
|---|---|---|
| `TextCommands.bodyOf(st, t)` | `text::body_of` | ported by the core; keep |
| `TextCommands.ctxFor(doc, sel)` | `text::ctx_for` | ported by the core; keep |
| `TextCommands.applyLeadingTabs(&para)` | `text::apply_leading_tabs` | ported by the core; keep |
| `TextCommands.pasteBody(s, body)` | `text::paste_body` | ported (text group) |
| `TextCommands.insertText(s, text, props)` | `text::insert_text` | ported (text group) |
| `TextCommands.deleteDir(s, dir)` | `text::delete_dir` | ported (text group) |
| `TableCommands.selectedCellsText(st)` | `table::selected_cells_text` | ported (text group) |
| `TableCommands.clearSelectedCells(s)` | `table::clear_selected_cells` | ported (text group) |
| `TableCommands.extendSelectedCells(s, dr, dc)` | `table::extend_selected_cells` | ported (text group) |
| `InsertCommands.firstFreeName(base, taken)` | `insert::first_free_name` | ported by the core; keep |
| `ArrangeCommands.unionBounds(xs)` | `arrange::union_bounds` | ported by the core; keep |

### Helpers the core provides to the modules

`FileCommands.openPresentation`, `openChecked`, `saveBytes`, `parseSlideRange`, `pdfOptions`, `pdfBytes`,
`renderPNG`/`renderPNGWith`, `imageScale`, `formatForPath`, `writableFormatForPath`, `gifBytes`, `outlineText`,
`readPresentationFile`, `addOpened`; `EditCommands.reid`, `remapAnimations`, `removeShapes`, `bakeTheme`;
`SlideCommands.findLayout`, `applyLayout`; `InspectCommands.shapeSummary`; `MediaRefs.*`
(`presentationMedia`, `slideMedia`, `shapesMedia`, `Visit`, `VisitMut`); `EngineFonts.usedFonts`, `missingFonts`,
`replaceFont`, `installEmbeddedFonts`; `Sounds.builtin`; `Connect.sites`, `nearestSite`, `siteShapeAt`,
`endpoints`, `setGlue`; `Tools.lineXfrm`; `IO.readFile` / `writeFile` (the only way a command touches a file:
a test enforces it); `Recovery.*`; `Templates.*`; `GifExport.*`; `ImageEncoding.png` / `jpeg` / `gif`.

### Cross-module helpers between the other modules

Each command module calls these helpers that live in another command module. **The owning module's agent must
provide them** (with these Swift names unless both sides agree otherwise):

| Called from | Helper (Rust → Swift) | Owner |
|---|---|---|
| design, shape, smartart, transition, reuse | `insert::content_type` → `InsertCommands.contentType`, `insert::media_bytes` → `InsertCommands.mediaBytes` | insert |
| design | `insert::add_shape` → `InsertCommands.addShape` | insert |
| design | `reuse::import_master` → `ReuseCommands.importMaster` | insert (reuse) |
| design | `shape::gradient_param` → `ShapeCommands.gradientParam` | shapes |
| review | `design::civil` → `DesignCommands.civil` | design |
| format, insert | `text::edit_text` → `TextCommands.editText` | text |
| format | `text::format_body`, `format_para`, `format_run` → `TextCommands.formatBody` / `formatPara` / `formatRun` | text |
| insert | `text::fit_text_box`, `insert_field`, `link_text` → `TextCommands.fitTextBox` / `insertField` / `linkText` | text |
| insert | `text::insert_text` → `TextCommands.insertText` (stub today) | text |
| insert | `format::apply_painted` → `FormatCommands.applyPainted` | text (format) |
| insert | `media::poster_png`, `probe_json` → `MediaCommands.posterPNG` / `probeJSON` | insert (media) |
| insert | `smartart::insert`, `nodes_from_lines` → `SmartArtCommands.insert` / `nodesFromLines` | insert (smartart) |
| shape | `three_d::Shape3d`, `three_d::store` → `ThreeDCommands.Shape3d` / `store` | shapes |
| text | `table::in_range`, `selected_range` → `TableCommands.inRange` / `selectedRange` | text (table) |
| table | `drawtable::draw_line`, `erase_at` (drawtable.rs) | text (table) |
| shape | `inkshape::*` (inkshape.rs) | shapes |
| review | `compare::*` (the rest of compare.rs), `spell::*`, `thesaurus::lookup` | text (review) |
| insert | `icons::*` (icons.rs, icon_data.rs) | insert |

Calls into the core (`text::ctx_for`, `text::body_of`, `file::*`, `edit::reid`, `slide::apply_layout`,
`media_refs`, `fonts`, `sounds`, `connect`, `tools::line_xfrm`) are already in place.

## Script parity

`EngineScriptTests` runs every `Tools/oracle/engine-scripts/*.cmds` through `Session.execute` from the CLI's
start (`file.new`, or `file.open` of the corpus deck named by `# in:`), compares each answer with
`$DECKCRAFT_FIXTURES/engine/<name>.results.txt` exactly as `run --print` prints it, saves with `file.saveAs`
and compares the `presentation` member of `presentation.json` with `<name>.deckcraft` (the manifest's
`generator` names the app; comment dates, which come from the clock, are blanked in both). It picks up every
script in the folder and skips, naming them, the scripts whose commands aren't registered yet. It also runs the
corpus scripts (`Tools/oracle/scripts/*.cmds`) against `oracle/<pin>/decks/<name>.deckcraft` and the sample deck
against `decks/sample.deckcraft`.

| Script | Start | Answers | Deck | Status |
|---|---|---:|---:|---|
| `core-slides` | new | 47 | 132,014 B | **identical** |
| `core-edit` | new | 29 | 118,242 B | **identical** |
| `core-file` | new (templates, themes, sizes, windows, revert, close) | 24 | 112,985 B | **identical** |
| `core-sample` | `sample.deckcraft` | 36 | 220,395 B | **identical** |
| `core-effects` | `effects.deckcraft` (pictures across decks) | 24 | 138,107 B | **identical** |
| `core-review` | `review.deckcraft` | 18 | 134,862 B | **identical** |
| `core-pptx` | `content.pptx` (PPTX import through `file.open`) | 17 | 163,711 B | **identical** |
| `basics` | new | 13 | — | skipped: `shape.insert`, `format.size`, `format.bold`, `shape.fill`, `arrange.group` |
| corpus `charts`, `content`, `effects`, `motion`, `review`, `shapes`, `smartart`, `text` | new | — | — | skipped: each names its unported commands |
| sample deck | — | — | — | skipped: 19 unported commands (`Sample.commands`) |

To add a script: write `Tools/oracle/engine-scripts/<name>.cmds`, run `Tools/oracle/oracle.sh engine-vectors
<name>`, and run the tests. A command that fails stops the oracle's run, so a script holds only commands that
succeed.

## Tests

- **Ported:** every test of `cmd/mod.rs`, `cmd/slide.rs`, `cmd/selection_tests.rs`, `cmd/richclip.rs`,
  `cmd/file.rs` (with `color_at_tests.rs`), `io.rs`, `recovery.rs`, `file_access.rs`, `media_refs.rs`, `sounds.rs` (see DCMedia),
  `templates.rs`, `keys.rs`; the Session, history, clipboard, file, slide, registry and sample tests of
  `tests.rs`; and the `tests_keys.rs` tests that drive keys through commands. Plus new ones for what the Rust
  tests only reach through the UI: undo identity, the byte budget, rollback of a failed command, the journal,
  windows, selection clamping, compositions, prefs, staged loads, connectors, fonts, GIF and image export.
- **Gated:** a test that needs a command from an unported module is `.enabled(if: ported(…))`, so it runs as soon
  as the command is registered. The command agents get these for free.
- **Left to the command agents:** the command-specific tests of `tests.rs` (text, format, tables, charts, SmartArt,
  pictures, effects, hyperlinks, IME, Edit Points, spelling, …), `guides_tests.rs` (arrange.rs),
  `ruler_tests.rs` (format.rs), and `soak_tests.rs` (`SoakTests.swift`: four seeded 400-step soaks and the
  undo-drain test; `DECKCRAFT_SOAK_STEPS` and `DECKCRAFT_SOAK_SEED` run a long one).
- **Not portable:** `tests_keys.rs`' `home_end_and_ctrl_home_end` (needs `text::layout_for`, the text agent's)
  and its Format Painter pointer tests, and the pointer tests of `tests.rs` and `selection_tests.rs` (they need
  `Session::pointer`; see Not ported). `guard.rs`' two panic tests (see Divergences).
- **Running them:** `swift test --filter DCEngineTests --scratch-path .build-engine`. The test bundle links every
  test target, so a parallel session's broken target stops the run; while DCMediaTests didn't build, the tests
  were run from a scratch copy of the manifest without it, over the same sources.

## DCMedia

`file.rs` (`probe_clips`) reads each audio and video clip's length and size from its headers when a `.pptx` opens:
`EngineMedia.prober`, by default `DCMediaProber` over `Media.probeHeaders` (`MediaProbe.swift`). Tests can swap it.
`sounds.rs`' test probes the WAVs with deckcraft-media; here it checks the WAV header and length.

## Divergences

- **No panic guard.** deckcraft catches a panic in a command, rolls the document back and saves a recovery
  snapshot. Swift can't catch a trap, so `guarded` just runs the command; `panicsCaught` stays 0. A failed
  command (any thrown error) is still rolled back by `execute`, as in Rust. `guard.rs`' tests that panic on
  purpose are replaced by the same checks on a failing command.
- **Undo memory accounting.** `undoCost` counts a slide, master or media item as shared when the newer
  presentation holds an equal one with the same id; Rust compares `Arc` addresses. Value types have none, and
  Swift's array equality checks storage identity first, so it stays cheap. A no-op rewrite of a slide counts as
  shared here and as a copy in Rust; budgets are approximate in both.
- **Images.** PNG, JPEG and GIF bytes come from ImageIO, not the `image` crate: `file.render`, `file.export`
  (images and GIF) and Paste Special › Picture write the same pixels, sizes, DPI and frame timing in different
  bytes. GIF frames use ImageIO's palette instead of NeuQuant. `file.saveBytes` answers differ too, because
  DCZip's deflate streams differ (the `presentation.json` inside is identical).
- **AutoRecover.** The instance id comes from Swift's random generator (Rust hashes `RandomState`, the pid and
  the time); both are random per process. Locks are `flock`, as `File::try_lock` is on Unix.
- **Automation roots** are a task-local scope (`@TaskLocal`) instead of a thread-local; a new thread starts
  unconfined in both. Windows device names and case-insensitive comparison are not applied (macOS only).
- **Enabled predicates** return `String?` (the reason) instead of `Result<(), String>`.
- **`DocState` and `Session` are classes**, as the Rust code hands out `&mut` to them; `DocState.copy()` is
  `Clone`.
- **Indices** above `Int.max` saturate to `Int.max` (`JSON.asUsize`), out of range as they are in Rust's 64-bit
  `usize`.
- **Names on paste** are kept in a `Set<String>`, which equates canonically equivalent strings where Rust's
  `HashSet` compares bytes. It only matters for names that differ in Unicode normalisation alone.

## Not ported

- **`tools.rs`'s pointer handling** (`Session::pointer`, hit testing, drags, snapping, freeform and ink drawing,
  table borders; about 1,900 lines). No command module or script needs it and none of the four groups owns it:
  it belongs with the app's canvas (Wave 5). Its data types are in `Tools.swift`, and `Session.key` handles
  Escape and Enter for drags and freeforms through them.

## Lower-layer changes

None.

## Text group (Wave 4): text, format, find, table, review

The `text`, `format`, `find`, `table` and `review` command modules (112 commands), with `drawtable.rs`, `spell.rs`,
`thesaurus.rs` and the rest of `compare.rs`. Every command is registered with deckcraft's id, label, menu,
shortcut and params; `theRegistryMatchesTheOraclesCommandList` checks them.

### File map

| Rust (`crates/engine/src`) | Swift (`Sources/DCEngine`) | Notes |
|---|---|---|
| `cmd/text.rs` | `CmdText.swift` | `TextCommands`; `ImeSurrounding`; the core's stubs (`pasteBody`, `insertText`, `deleteDir`) filled in |
| `cmd/format.rs` | `CmdFormat.swift` | `FormatCommands` (`Painted` is the core's, in `Engine.swift`) |
| `cmd/find.rs` | `CmdFind.swift` | `FindCommands` |
| `cmd/table.rs` | `CmdTable.swift` | `TableCommands`, `TableFrame` (Rust's `TableBorder` is `TableFrame.Border`: DCModel already has a `TableBorder`); the core's stubs filled in |
| `cmd/review.rs` | `CmdReview.swift` | `ReviewCommands` |
| `drawtable.rs` | `DrawTable.swift` | `DrawTable.drawLine`, `eraseAt` |
| `compare.rs` | `Compare.swift` | the core's data types, then `ChangeKey.of`, `Change` and `Comparing` (`pending`, `diff`, `unrelated`, `adopt`, `accept`) |
| `spell.rs` | `Spell.swift` | `SpellChecking` and its checkers, `SpellDictionary` (the Hunspell subset), `Spell` (dictionary folders and cache, the user dictionary, the words of a paragraph) |
| `thesaurus.rs` | `Thesaurus.swift` | `Thesaurus.lookup` |
| `data/thesaurus.txt` | `ThesaurusData.swift` | the word list verbatim, as a raw string literal (generated; deckcraft `include_str!`s it) |
| in-file tests, `ruler_tests.rs`, `tests.rs` (text, format, table, find, review, spelling), `tests_keys.rs` `home_end_and_ctrl_home_end` | `Tests/DCEngineTests/TextCommandTests.swift`, `FormatCommandTests.swift`, `TableCommandTests.swift`, `ReviewCommandTests.swift` | each test keeps Rust's name in camelCase and names its source |
| — | `Tests/DCEngineTests/TextNativeScriptTests.swift` | the `text-native-*` scripts (see below) |

### Cross-module helpers provided

`TextCommands.editText`, `formatBody`, `formatPara`, `formatRun`, `formatRange`, `fitTextBox`, `insertField`,
`linkText`, `insertText`, `pasteBody`, `deleteDir`, `withBody` (`body_mut`), `layoutFor`, `textFrame`, `textPosAt`,
`caretLine`, `caretColor`, `rangeUnderlines`, `cellRangeUnderlines`, `compositionUnderlines`, `imeSurrounding`,
`correctWord`; `FormatCommands.applyPainted`; `TableCommands.inRange`, `selectedRange`, `cellBlock`,
`tableFrame`, `tableAt`, `selectedCellsText`, `extendSelectedCells`, `clearSelectedCells`; `DrawTable.drawLine`,
`eraseAt`; `Comparing.*`; `Spell.*`; `Thesaurus.lookup`.

### Spelling

deckcraft checks spelling with the Hunspell dictionaries it finds in the folders the system's spell checkers
use (`DECKCRAFT_DICTIONARIES`, `~/Library/Application Support/DeckCraft/Dictionaries`, `~/Library/Spelling`,
`/Library/Spelling`), and with no dictionary for a language falls back to a short list of common misspellings
(no suggestions). That checker is ported as it is (`HunspellSpelling`, `SpellDictionary`): it is deckcraft's own
logic and gives deckcraft's answers. It sits behind `SpellChecking`, and `Spell.checker` (task-local) is by default
`ChainedSpelling([HunspellSpelling(), SystemSpelling()])`: an installed (or `Spell.install`ed) Hunspell dictionary
answers first, as in deckcraft, and otherwise the Mac's own spell checker (`NSSpellChecker`, under
`#if canImport(AppKit)`, so the engine still builds without AppKit) — on the Mac it *is* "the system's spell
checker". The common-misspellings list remains for languages neither knows. The user dictionary (`user.dic`) is
deckcraft's file, checked before either checker.

### Script parity

All seven scripts run in `EngineScriptTests` or `TextNativeScriptTests`. Error cases are `!id=json` lines (see
below); "refused" counts them.

| Script | Start | Answers | Refused | Status |
|---|---|---:|---:|---|
| `text-edit` | `sample.deckcraft` | 100 | — | **identical** (answers and deck) |
| `text-format` | `sample.deckcraft` | 83 | 17 | **identical** |
| `text-paragraph` | `sample.deckcraft` | 69 | 13 | **identical** |
| `text-table` | `sample.deckcraft` | 76 | 21 | **identical** |
| `text-find` | `sample.deckcraft` | 16 | 4 | **identical** |
| `text-review` | `sample.deckcraft` | 49 | 23 | **identical** |
| `text-native-spelling` | `sample.deckcraft` | 17 | — | under `HunspellSpelling`: **identical** but `font.rescan`; under the default checker: structural (see below); deck identical in both |

**Error cases.** A refused command stops `deckcraft-cli run`, so a script can't simply list them. A line
`!id=json` is an expected refusal: `oracle.sh engine-vectors` runs it after the commands before it (in a run of
its own) and writes its error to `<name>.errors.txt`, leaving it out of the main run; `EngineScriptTests` runs it
in place, expects the same error, and goes on (a refused command leaves the document as it was). The line must
carry its params (`!format.ruler={}`).

**Native scripts.** `EngineScriptTests` leaves out `<group>-native-*` scripts. `TextNativeScriptTests` runs
`text-native-*` twice: under `HunspellSpelling` every answer must be the oracle's except `font.rescan`, compared
by shape; under the default checker `review.spelling`, `review.dictionary` and `font.rescan` are compared by
structure — the same repeated words, every word deckcraft flags flagged too (the system checker may flag more
and suggests its own corrections), the same answer keys — and every other answer and the deck exactly.

### Divergences

- **Spelling** through `NSSpellChecker` when no Hunspell dictionary is installed (above): more words flagged
  than deckcraft's common-misspellings list, with suggestions, and `review.dictionary` reports `available: true`
  for the languages the Mac has. The `review.spelling` params doc still names Hunspell (the registry is
  deckcraft's).
- **`font.rescan`** answers `{faces: 0, families}`: CoreText catalogs installed fonts as they come and go, so
  there is nothing to load; `families` counts CoreText's families and the session's own faces.
- **Dictionary words** are `String` keys, which Swift compares by canonical equivalence where Rust compares
  bytes; it matters only for words differing in Unicode normalisation alone.
- **The engine's own files.** spell.rs reads the dictionary folders and appends to `user.dic` with `std::fs`. Here
  those go through `IO.isOwnFile`, `ownDirectoryEntries`, `readOwnFile` and `appendOwnFile` (unconfined, like
  Recovery's folder: never a path a command names), so `commandsDoNotTouchTheFileSystemThemselves` holds.
- **Wrapping arithmetic.** `remap_after_delete` adds and subtracts `usize`s that a hostile selection can push
  past the end; Rust wraps (release) or panics into the guard (debug), Swift would trap: it wraps (`&+`, `&-`),
  with a regression test.

### Core-file edits (additive)

- `IO.swift`: the extension for the engine's own files (above).
- `Tests/DCEngineTests/EngineScriptTests.swift`: `!id=json` refusals (`CommandScript.refused`, compared with
  `<name>.errors.txt`), and `-native-` scripts left out.
- `Tools/oracle/oracle.sh` (`engine-vectors`): runs each `!` line on its own and writes `<name>.errors.txt`.

### Tests

124 tests in `TextCommandTests` (39), `FormatCommandTests` (21), `TableCommandTests` (20),
`ReviewCommandTests` (40) and `TextNativeScriptTests` (3, plus 1 regression test in `TextCommandTests`).
23 of them wait for other groups' commands (`shape.insert`, `insert.textBox`, `insert.table`,
`insert.hyperlink`, `insert.chart`, `design.theme`, `shape.rotate`…) through `.enabled(if: ported(…))`; with a
private stand-in `shape.insert` / `insert.textBox` all but those needing `insert.hyperlink`, `insert.table`,
`insert.chart`, `design.theme` and `shape.*` pass. Not ported: the tests that drive `Session::pointer`
(listed at the top of each file), `header_footer_fixed_date_is_the_slides_own_text` and
`smartart_text_pane_edits_regenerate_the_diagram` (the design and insert groups' commands), and the PPTX half of
`editing_shrink_text_stores_the_layout_scale`.

### Lower-layer changes

None.

## Shapes group (Wave 4): shape, arrange, points, merge, three_d, picture_style, recolor, artistic

The Shape Format, Arrange, Edit Points, Merge Shapes and Picture Format commands: 94 commands in eight modules,
with Ink to Shape's recogniser and the `shape.rotate` gesture's interaction.

### File map

| Rust (`crates/engine/src`) | Swift (`Sources/DCEngine`) | Notes |
|---|---|---|
| `cmd/shape.rs` | `CmdShape.swift` | `ShapeCommands`: geometry, fill, outline, effects, quick styles, names, locks, pictures' crop and corrections, Change Picture, playback options, connectors, freeforms, Ink to Shape; `Session.begin` / `commitNamed` (tools.rs's, which only `shape.rotate` calls) |
| `cmd/arrange.rs` | `CmdArrange.swift` | `ArrangeCommands`: order, reorder, group (`maxGroupDepth`), ungroup (`childToParent`), regroup, align, distribute, guides; `unionBounds` kept as the core wrote it |
| `cmd/points.rs` | `CmdPoints.swift` | `PointsCommands`: `Seg`, `parse`/`write`, `vertices`, and the pointer's helpers (`slideVertices`, `vertexAt`, `segmentAt`, `slideHandles`, `kindOf`, `segmentKindOf`, `segmentStartOf`, `closedAt`, `movePointRaw`, `moveHandleRaw`) for the canvas |
| `cmd/merge.rs` | `CmdMerge.swift` | `MergeCommands`: CoreGraphics booleans (below) |
| `cmd/three_d.rs` | `CmdThreeD.swift` | `ThreeDCommands.Shape3d` (`parse`, `apply`, `toXML`, `isFlat`), `Bevel`, `Rotation`, `store`, the preset lists; no commands of its own |
| `cmd/picture_style.rs` | `CmdPictureStyle.swift` | `PictureStyleCommands`: `styles`, `look`, `apply` |
| `cmd/recolor.rs` | `CmdRecolor.swift` | `RecolorCommands`: `presets`, `apply`, Set Transparent Color's pixel pick |
| `cmd/artistic.rs` | `CmdArtistic.swift` | `ArtisticCommands`: the effects, with the `image` crate's Gaussian blur and thumbnail ported (below) |
| `inkshape.rs` | `InkShape.swift` | `InkShape.recognize` |

### Cross-module helpers provided

- `ShapeCommands.gradientParam(_:) -> Gradient?` (`shape::gradient_param`), for design.
- `ThreeDCommands.Shape3d` and `ThreeDCommands.store(&effects, shape3d)` (`three_d::Shape3d`, `three_d::store`).

### Script parity

| Script | Start | Answers | Refusals | Status |
|---|---|---:|---:|---|
| `shapes-geometry` | `shapes.deckcraft` | 69 | 22 | **identical** (answers, refusals and deck) |
| `shapes-format` | `shapes.deckcraft` | 106 | 10 | **identical** |
| `shapes-arrange` | `content.deckcraft` | 69 | 15 | **identical** |
| `shapes-points` | `shapes.deckcraft` | 70 | 20 | **identical** |
| `shapes-pictures` | `effects.deckcraft` | 54 | 12 | **identical** |
| `shapes-artistic` | `effects.deckcraft` | 11 | — | **identical**, and the 17 pictures it stores are deckcraft's pixel for pixel |
| `shapes-connect` | `effects.deckcraft` | 23 | 8 | **identical** |
| `shapes-native-merge` | `shapes.deckcraft` | 55 | 3 | structural: 19 outlines, areas within 2.2 × 10⁻¹⁶ (relative) |
| `shapes-native-letters` | `effects.deckcraft` | 14 | — | structural: 4 outlines (letters), areas identical |

`ShapesScriptTests` runs the `shapes-native-*` scripts: every answer and the deck compared as JSON, numbers within
0.02 pt (or 10⁻⁶ relative), strings exactly except each custom path's `d`, compared by the area it encloses
(within 10⁻³ relative). It also decodes the pictures `shapes-artistic` stores and compares their pixels with the
oracle deck's. A script's `media` sizes are left out of the answers (`document.inspect` would show the PNG
streams' lengths, which ImageIO makes differently).

### Merge Shapes on CoreGraphics

deckcraft runs `i_overlay` (non-zero fill) over polygons; here `CGPath.union` / `symmetricDifference` /
`intersection` / `subtracting` (`.winding`) do, as PORT-STATUS records. What is kept from deckcraft:

- **The same polygons.** Outlines are flattened before the booleans exactly as deckcraft flattens them
  (`presetFlatten`, kurbo's flattening at 0.2 pt), letters through `textOutline`, so CoreGraphics works on the
  polygons i_overlay gets, with the same fill rule, and keeps no curves of its own.
- **Holes.** CoreGraphics returns contours without i_overlay's orientation; each contour is oriented by its
  nesting (an outer one counter-clockwise in the shoelace sense, a hole the other way), probing a vertex or edge
  midpoint that lies on no other contour, since a result's pieces can touch. A custom path is filled non-zero,
  so without this a hole would draw filled.
- **The rest** (fragment's pieces, the 0.01 pt² floor, the box and `{:.2}` path text, picture re-cropping,
  letters taking the text's colour) is deckcraft's code.

Measured on the scripts above: every result has deckcraft's box within 0.02 pt and the area its path encloses
within 2.2 × 10⁻¹⁶ of deckcraft's (relative; the letters exactly). The path text differs: the contours start at
another vertex.

### Artistic effects and recolour: ported or native

- **Artistic effects** store their result as the picture (`PictureFill.artistic` keeps the original), so the
  pixels are a port, not Core Image: the effects, and the `image` crate's `imageops::blur` (0.25.10: kernel
  size from sigma, the f32 Gaussian kernel, the separable f32 filter with clamped edges and fused
  multiply-adds as on aarch64, rounding to nearest) and `thumbnail` (block averaging for pictures over 3000 px).
  `ShapesScriptTests` finds deckcraft's pixels in all 17 pictures of `shapes-artistic`, wide kernels (σ = 9,
  57 taps, the filter's non-ring path) included. The PNG stream is ImageIO's (pixels the same, bytes not).
  Decoding is DCRender's `Images.decode`: PNG gives the stored values; a JPEG's pixels can differ from
  zune-jpeg's by a unit, and then so does the result. WMF and EMF are refused as the `image` crate refuses
  them.
- **Recolour** stores only settings (`PictureAdjust`); the renderer draws them. Set Transparent Color's `at`
  stores the colour of one pixel of the picture as decoded (`Images.decode`, exact for PNG).

### Divergences

- Merge Shapes' path text (above).
- Artistic effects' PNG bytes, and their pixels for a JPEG original (above).
- **`shape.rotate`'s gestures** use `Session.begin` / `commitNamed`, written here: tools.rs's pointer handling
  isn't ported (core "Not ported").
- **Gradient stops** are sorted with a stable sort that orders −0 before +0, as `total_cmp` does.

### Core-file edits

- `Tests/DCEngineTests/EngineScriptTests.swift`: none left. (A `-native-` skip was added and taken out again when
  the text group's version of the same filter landed.)

### Tests

63 tests in `ShapesCommandTests` (30: shape.rs, three_d.rs, inkshape.rs and the shape tests of tests.rs),
`ShapesArrangeTests` (8: arrange tests of tests.rs, guides_tests.rs), `ShapesPointsTests` (11),
`ShapesPictureTests` (12: pictures, artistic effects, merge.rs) and `ShapesScriptTests` (2: native scripts,
artistic pixels). With the other groups' commands registered, all 63 run and pass; those that need another
group's command (`shape.insert`, `insert.picture`, `insert.textBox`, `insert.table`, `file.render`…) are
`.enabled(if: ported(…))`. `groupsNestOnlyAsDeepAsASavedFileReopens` runs on a thread with an 8 MB stack
(`onMainSizedStack`): thirty-two nested groups take more than Swift Testing's 512 KB threads have in a debug
build, because the shape-tree walks (`findShape`, `walk`…) recurse once per level, as deckcraft's do and as
`cargo test`'s 2 MB threads allow. The app's main thread has 8 MB.

Not ported, because they drive `Session::pointer` (tools.rs, not ported): `edit_points_with_the_pointer_and_curves`,
`edit_points_escape_cancels_a_point_or_handle_drag`, `edit_points_handle_drag_modifiers_set_the_point_type`,
`edit_points_escape_takes_back_the_point_type_of_a_modifier_drag`,
`edit_points_remembered_point_type_follows_undo_redo_and_its_shape`,
`edit_points_right_click_picks_the_point_or_the_segment`, `edit_points_right_click_on_a_handle_keeps_the_picked_vertex`,
the pointer half of `edit_points_types_and_handles` and of `freeform_tools_and_command`,
`drag_a_guide_drop_it_off_the_slide_and_snap_shapes_to_it`, `rotated_tables_hit_the_cell_under_the_pointer`,
`clicks_in_flipped_shapes_hit_the_text_where_it_is_drawn`, `double_click_edits_text_inside_group`,
`resizing_a_flipped_box_snaps_the_dragged_edge` and `a_shape_in_front_of_edited_text_takes_the_click`.
`edit_points_right_click_records_the_place_on_the_segment` is ported on `segmentAt`, the hit test behind the
click. The Selection pane tests of selection_tests.rs that use these commands were ported by the core
(MiscTests).

### Lower-layer changes

None.

## Design group (Wave 4): design, background, ideas, transition, animation

The `design`, `background`, `ideas`, `transition` and `animation` modules: 44 commands.

| Rust (`crates/engine/src`) | Swift (`Sources/DCEngine`) | Notes |
|---|---|---|
| `cmd/design.rs` | `CmdDesign.swift` | `DesignCommands`: themes, Browse for Themes (`.pptx`/`.potx` through `FileCommands.openPresentation` and `ReuseCommands.importMaster`, `.thmx` through DCPPTX's `PPTX.importTheme`), colours, variants, fonts, effects, Format Background, slide size, header & footer, Slide/Handout/Notes Master views and the `master.*` commands. Provides `DesignCommands.civil` (review), `today`, `dateFieldText`, `handoutPlaceholder`, `notesPlaceholder` |
| `cmd/background.rs` | `CmdBackground.swift` | `BackgroundCommands`: Picture Format › Remove Background (`picture.removeBackground`), `matte` on DCRender's `StraightImage` |
| `cmd/ideas.rs` | `CmdIdeas.swift` | `IdeasCommands`: `ideasFor`, `applyIdea`; deterministic, as in deckcraft (no randomness, nothing from the clock) |
| `cmd/transition.rs` | `CmdTransition.swift` | `TransitionCommands`; `transition.sound` probes the sound with DCMedia's `Media.probe` |
| `cmd/animation.rs` | `CmdAnimation.swift` | `AnimationCommands`: `resolveOption`, `defaultPath` |
| tests of the five modules, the design/transition/animation tests of `tests.rs`, `tests/it/show_clicks.rs`, `tests/it/chart_native.rs`, `tests/show_paragraph_builds.rs`, the command checks of the pptx crate's `it/roundtrip.rs` transition-sound tests | `Tests/DCEngineTests/DesignCommandTests.swift`, `DesignMotionTests.swift`, `DesignShowTests.swift` | |

**Civil dates.** `civil` converts the day within its 400-year cycle with Howard Hinnant's `civil_from_days`
(deckcraft uses chrono's `NaiveDate` there) and carries whole cycles into the year, so it is exact for every
`Int64` as the Rust is.

**Scripts** (`Tools/oracle/engine-scripts/design-*.cmds`): `design-themes`, `design-backgrounds`,
`design-masters`, `design-browse` (a `.pptx`, a preserved master, a `.thmx`), `design-templates` (every
template's starter deck), `design-ideas`, `design-removebg`, `design-transitions`, `design-animations`.

**Divergences.**

- Remove Background decodes the picture with ImageIO (DCRender's `Images.decode`) and writes the matted PNG
  with ImageIO instead of the `image` crate. The matte's pixels are the same; the PNG's compressed bytes
  differ. Media bytes are not part of `presentation.json`, so `design-removebg` still compares exactly.
- Error cases are not in the scripts: a refused command makes `deckcraft-cli run` exit without saving, which
  stops `oracle.sh engine-vectors`. They are covered by the ported unit tests.

**Tests:** 64 in 8 suites (`DesignCommandTests` 22, `DesignMotionTests` 28, `DesignShowTests` 14), all green. Every
in-file test of the five modules is ported. The suites wait (`.enabled(if: ported(…))`) for the commands they use.

| Script | Start | Answers | Status |
|---|---|---:|---|
| `design-themes` | new | 36 | **identical** |
| `design-backgrounds` | new | 35 | **identical** |
| `design-masters` | new | 38 | **identical** |
| `design-browse` | new (`.pptx` data, preserved master, `.thmx`) | 15 | **identical** |
| `design-templates` | every template | 55 | **identical** |
| `design-ideas` | new | 21 | **identical** |
| `design-removebg` | new | 5 | **identical** (presentation; the PNG bytes differ, see below) |
| `design-transitions` | new | 32 | **identical** |
| `design-animations` | new | 35 | **identical** |

**Edits outside the group's files.** `SessionTests.undoHistoryIsCappedByMemoryAsWellAsSteps` (core test, enabled once
`design.slideSize` registered) accepts 5–13 kept steps instead of Rust's 5–11: the rescale leaves slides whose
placeholders inherit their boxes unchanged, and `undoCost` counts those as shared (see Divergences, undo memory
accounting). DCPPTXTests' `transitionSoundIsSetSavedAndRemoved` and `transitionSoundOptionsRoundTrip` lost their
`#if DCENGINE` blocks; those command checks are `TransitionCommandTests` here.

**Lower-layer changes:** none.

## Insert group (Wave 4): insert, smartart, media, compress, zoom, reuse

The `insert`, `smartart`, `media`, `compress`, `zoom` and `reuse` modules and the icon gallery: 48 commands.

| Rust (`crates/engine/src`) | Swift (`Sources/DCEngine`) | Notes |
|---|---|---|
| `cmd/insert.rs` | `CmdInsert.swift` | `InsertCommands`: shapes, icons, text boxes, pictures (into an empty placeholder too), Photo Album and its editing, tables, charts and `chart.*`, audio and video, WordArt, slide number, Date & Time, symbols, links, Action Settings, action buttons, `insert.smartArt` |
| `cmd/smartart.rs` | `CmdSmartArt.swift` | `SmartArtCommands`: the 45 layouts, styles (3-D ones included), colours, the Text Pane edits, conversions; `layouts`/`styles`/`colors`, `category`, `preview`, `selected`, `layout` public for the app |
| `cmd/media.rs` | `CmdMedia.swift` | `MediaCommands`: playback requests, `media.info`, poster frames, `media.gifPlay` |
| `cmd/compress.rs` | `CmdCompress.swift` | `CompressCommands`: `pack` on ImageIO and vImage (see Divergences) |
| `cmd/zoom.rs` | `CmdZoom.swift` | `ZoomCommands`: `grid`, slide/section/summary zooms (pictures from `FileCommands.renderPNG`) |
| `cmd/reuse.rs` | `CmdReuse.swift` | `ReuseCommands`: `slide.reuseList`, `slide.reuse`, `importMaster` |
| `icons.rs` | `Icons.swift` | `Icons` (`icons`, `find`, `outline`, `pathData`, `strokeWidth`, `view`), with kurbo 0.13.1's SVG path parser (`BezPath::from_svg`) and arc-to-cubic conversion (`Arc::from_svg_arc`, `append_iter`) ported beside it (Apache-2.0 OR MIT), so the converted paths are deckcraft's to the digit |
| `icon_data.rs` | `IconData.swift` | the 70 Lucide 1.56.0 icons (ISC; Feather-derived MIT), converted from the Rust source by script |
| in-file tests, the insert/link/chart/date tests of `tests.rs`, the engine checks of the pptx crate's `it/roundtrip.rs` (reuse, compress, zoom) | `Tests/DCEngineTests/InsertCommandTests.swift`, `InsertMediaTests.swift`, `SmartArtCommandTests.swift`, `InsertNativeScriptTests.swift` | |

### Cross-module helpers provided

`InsertCommands.contentType`, `mediaBytes`, `addShape` (plus `autoNameBase`, `newTextBox`, `chartType`,
`pixelSize`); `ReuseCommands.importMaster`; `MediaCommands.posterPNG`, `probeJSON`; `SmartArtCommands.insert`,
`nodesFromLines`. `InsertCommands.firstFreeName` is the core's, unchanged.

### Script parity

| Script | Start | Answers | Status |
|---|---|---:|---|
| `insert-shapes` | new (shapes, galleries, icons, text boxes, WordArt, tables, charts and `chart.*`, action buttons, Action Settings, links, fields; 24 refusals) | 104 | **identical** |
| `insert-pictures` | new (pictures, GIF, SVG, into placeholders, Photo Album and Edit Photo Album; 24 refusals) | 41 | **identical** |
| `insert-albums` | new (album frames, grayscale, brightness, contrast: runs `shape.line`, `picture.adjust`) | 16 | **identical** |
| `insert-media` | new (WAV, MP3, WMA, Opus, AAC, H.264/HEVC MP4, MKV from `DeckCraftNative-Fixtures/media/inputs`; playback; 10 refusals) | 26 | **identical** |
| `insert-reuse` | new (a `.deckcraft` and a `.pptx` made by deckcraft-cli; 6 refusals) | 14 | **identical** |
| `insert-zoom` | new (4 refusals) | 19 | **identical** |
| `insert-smartart` | new | 222 | **identical** |
| `insert-native-media` | new (poster frames) | 6 | answers and deck identical but the posters' byte counts; posters equal by pixel size |
| `insert-native-compress` | new (PNG, JPEG, PNG with alpha, crops kept and deleted; 3 refusals) | 23 | answers identical but `before`/`after`; deck identical; every picture equal by pixel size |
| `insert-native-zoom` | new | 9 | answers identical but the zoom pictures' byte counts; deck identical; pictures equal by pixel size |

The native scripts are `InsertNativeScriptTests`' (EngineScriptTests skips `*-native-*`): answers compared with the
byte counts of pictures left out (`bytes` of an image item, `before`/`after` of `picture.compress`), refusals and
the deck's `presentation` exactly, and every picture in the saved deck by its pixel size.

### Divergences

- **Compress Pictures** decodes with ImageIO (`Images.decode`, refusing more than 64 MP by the header first, as
  deckcraft does), resamples with vImage's high-quality kernel (`vImageScale_ARGB8888`, where deckcraft uses the
  `image` crate's Lanczos3) and encodes with ImageIO (JPEG at quality 0.85, else PNG). The crops, pixel sizes and
  formats are deckcraft's; the bytes differ, and so does `after`. Because deckcraft keeps a resampled picture only
  when it is smaller than the original, a picture that deckcraft's encoder and ImageIO's land on opposite sides of
  that line could be compressed by one and left by the other (none of the scripts' or tests' pictures do).
- **Poster frames** come from AVFoundation/VideoToolbox through DCMedia's `Media.posterPNG` and are written by
  ImageIO; **zoom pictures** are ImageIO PNGs of the rendered slide (as `file.render`). Same sizes, other bytes.
  Media bytes aren't in `presentation.json`, so the decks still compare exactly.
- **Picture sizes** (`insert.picture`'s natural size, Photo Album's aspect) are read from the header with ImageIO
  instead of the `image` crate; SVG and PDF are refused as rasters, as the `image` crate refuses them. A PNG whose
  pixel data is missing has no size in ImageIO (the `image` crate reads its header); both refuse to decode it.
- `media.rs`' `a_vp8_webm_is_playable_and_warns_that_only_the_audio_plays` is disabled: it needs upstream's CC0
  `clip-vp8.webm`, which the fixtures don't carry and nothing here can generate. `a_video_reopened_from_pptx…`
  uses the generated `av-h264-aac.mp4` in place of upstream's `clip-h264.mp4`.
- Rust panics that a hostile value could reach are bounds instead: an SVG arc's segment count is capped at
  100,000; SmartArt's levels saturate at `u8`, its org-chart assistant clamp can't trap, and its text-size mode
  loop can't spin on NaN.

### Tests

62 tests in 11 suites, all green but one disabled: `InsertCommandTests.swift` 32 (insert.rs' Date & Time and photo album/picture tests,
icons.rs', and `tests.rs`' `insert_shape_and_format`, `action_settings_set_click_and_hover`,
`chart_options_text_color_sets_clears_and_refuses`, `format_color_on_a_selected_chart_sets_its_text_color`,
`header_footer_fixed_date_is_the_slides_own_text` and the five `hyperlink_*` tests), `InsertMediaTests.swift` 18
(media.rs', compress.rs' and reuse.rs' tests, and the pptx crate's `reuse_slides_from_another_presentation`,
`compress_pictures_shrinks_the_file_and_keeps_shared_originals` and `zoom_inserts_linked_slide_pictures`, which
were disabled in DCPPTXTests and are removed from there), `SmartArtCommandTests.swift` 10, `InsertNativeScriptTests`
2. Compress Pictures' tests build their pictures as stored (undeflated) PNGs:
ImageIO's own PNGs of the tests' regular patterns are smaller than the `image` crate's, so a resampled picture
would come out larger than its source and be left alone, where the Rust test (and deckcraft) compress it.

### Core-file edits

None. (`DCPPTXTests/IntegrationRoundtripTests.swift`: the three disabled engine tests removed, as above.)

### Lower-layer changes

None.
