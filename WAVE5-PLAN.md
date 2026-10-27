# Wave 5: the Mac app

**Started and done:** 2026-10-27 (see PORT-STATUS.md, Wave 5) · **Pin:** deckcraft `27009cd9` · **Done when** (PLAN.md §7): deckcraft's six alpha-gate
workflows work end to end in the app, and screenshots are checked through the control channel.

This is the shared brief for the sessions that build the app in parallel. Read it with [PLAN.md](PLAN.md),
[PORT-STATUS.md](PORT-STATUS.md) and [CLAUDE.md](CLAUDE.md).

## What the app is

A Mac-native presentation editor over the engine Waves 1–4 ported. It keeps PowerPoint's verbs but not its
ribbon (PLAN.md, "Decided"): a menu bar, a toolbar, a slide navigator, the canvas and an inspector — a
Keynote-like layout. deckcraft's egui UI (`crates/ui-egui`, about 42k lines, and `apps/deckcraft`) is the
**behaviour** to match: what each control does, which command it runs, what state it keeps, and its tests. It is
not the look: layout, controls and idioms follow macOS (AppKit, SwiftUI, the HIG) and the fleet's design
vocabulary.

### The alpha gate (deckcraft `docs/roadmap.md`)

| # | Workflow | What "works" means here |
|---|---|---|
| 1 | **Build** a deck from scratch: theme, layouts, titles and bullets, shapes, pictures from file; save, close, reopen | all of it from the menus, toolbar, inspector and canvas; Close asks before discarding edits |
| 2 | **Open a colleague's `.pptx`**, edit it, save it back as `.pptx` | Finder and File › Open; the bytes are DCPPTX's |
| 3 | **Present**: full-screen show with transitions, animations, media; presenter view with notes, next slide, timer | the presenter view on the second display when there is one |
| 4 | **Business content**: tables, charts with their data, simple diagrams | table and chart editing in place; Chart Data |
| 5 | **Share**: PDF of slides, notes or handouts; images; **print** | export sheets; `NSPrintOperation` |
| 6 | **Review**: comments with replies, resolve; spelling | comments pane; squiggles and suggestions |

## Architecture (in place)

```
Packages/DCApp/Sources/
  DCAppModel/        no AppKit — testable state and routing (ui-egui's SlideApp without the drawing)
    AppModel.swift     the one entry point: AppModel.run(id, params) → UI command or engine command
    UICommands.swift   UI_COMMANDS (deckcraft's table) and the command palette
    MenuTree.swift     menu_tree (the menu bar) and Shortcut ("Cmd+Shift+P" → key + modifiers)
    UiState.swift      UiState (ui.json), sanitized
  DCApp/             AppKit + SwiftUI
    DeckCraftApp.swift        main(), Launch (--control PORT, --sample, --show, files)
    AppController.swift       AppHost; the extension points; document sync; menu/toolbar actions
    Features.swift            one install call per area
    PresentationDocument.swift  NSDocument per engine document; DocumentController
    DocumentWindowController.swift  split view: navigator | canvas | inspector; toolbar
    MenuBuilder.swift         the menu bar from MenuTree; validation from each command's `enabled`
    Canvas/ Inspector/ Dialogs/ Show/ Views/ Automation/   the areas (below)
Apps/DeckCraftNative/  thin Xcode app (main.swift, Info.plist with deckcraft's document types, entitlements)
Apps/DeckCraftDev/     the same app from SwiftPM, unbundled
```

- **One session, every window.** `AppModel.session` holds every open presentation, as deckcraft's app does. A
  `PresentationDocument` is the window-side handle on one of them, by `DocState.uid`; it gives the native
  lifecycle (Open, Save, Save As, Revert, Open Recent, the edited dot, the close prompt). Reading and writing
  use the engine's coders (`FileCommands.openChecked`, `saveBytes`). Documents the engine opens or closes by
  itself (a command, a script, the control channel) gain or lose a window in `AppController.syncDocuments`.
  A window that becomes key makes its document the engine's active one.
- **Everything is a command.** Every action — menu, toolbar, inspector, canvas, key, palette, control channel —
  goes through `AppModel.run(id, params)`. UI-state commands are answered in `AppModel.runUI`; UI commands that
  need a window are registered by their area with `app.handle([ids]) { params in … }`; the rest are the
  engine's. The engine's `UiRequest`s (dialog, pane, startShow, pickFile, message, media) go to
  `app.onRequest`. Programmatic calls never open UI that blocks: a control-channel command that would open a
  dialog opens it non-modally and answers.
- **Refresh.** After every command `AppModel` bumps `revision` and posts `.deckCraftModelChanged`; views
  redraw from the session. The session lives on the main thread (the main thread's 8 MB stack covers deep
  groups; PPTX import/export already use `PPTX.onLargeStack`).
- **The session is the truth.** Selection, undo, the clipboard's object copy, tool state and preferences are
  the engine's. `NSUndoManager` only shows titles; Undo runs `edit.undo`.
- **Design vocabulary.** DesignScaffold is the fleet's single design authority (AB-D-0042): spacing, radii,
  type and colours come from `DesignScaffold.Tokens` (SwiftUI) or the matching semantic `NSColor`s (AppKit). No
  hardcoded hex colours or magic sizes in views. A missing token is asked for, not invented.
- **Native first** (PORT-STATUS "Decisions"): `NSTextInputClient` for text input, `NSSpellChecker`,
  `NSPrintOperation`, `NSPasteboard`, `NSScreen`, `AVPlayer`/`AVAudioEngine`, Metal for the show's transitions,
  String Catalogs. Say when you go another way and why.

### Extension points (`AppController`)

| Call | For |
|---|---|
| `app.handle(["app.exportDialog"]) { p in … }` | a UI command that needs a window |
| `app.onRequest { req in … return true }` | an engine `UiRequest` (return true when taken) |
| `app.control(["ui.dialog.list"]) { p in … }` | a control-channel method that drives the window (`ControlOutcome`) |
| `app.inspect("dialog") { … }` | a key in `ui.inspect`'s answer |

Register from your area's `<Area>Feature.install(_:)`. `Features.swift` already calls all six.

## Running it

- `swift build --scratch-path .build-<area>` then `.build-<area>/out/Products/Debug/DeckCraftDev --sample` (or a file).
- The bundle: `xcodebuild -project Apps/DeckCraftNative/DeckCraftNative.xcodeproj -scheme DeckCraftNative
  -derivedDataPath ~/Library/Caches/DeckCraftNative/xcode build` (Satechi is nearly full: derived data stays in
  Caches). Use the bundle to check Finder opening and document types; DeckCraftDev for everything else.
- **Screenshots:** find the window id (`CGWindowListCopyWindowInfo`, owner `DeckCraftDev`) and `screencapture -x
  -o -l <id> out.png`, then look at it. Once the control host lands (Automation, the lead's), `--control 4242`
  lets `dccli app …` drive the app and `ui.screenshot` capture it — you'll be told when.
- Quit the app you started (`pkill -f "DeckCraftDev"` with your own arguments) when done.

## The areas

Each area is one session. **Own only your folder** (and your test files); shared files are listed below.

| Area | Folder | deckcraft sources (behaviour) | deckcraft tests to port (behaviour) |
|---|---|---|---|
| **Canvas** | `DCApp/Canvas/` | `canvas.rs`, `squiggles.rs`, `eyedropper.rs`, the canvas parts of `lib.rs` (input, IME, context menus), `widgets.rs`' handles | `canvas.rs` (17), `ime_tests.rs` (47), `eyedropper_tests.rs`, `ruler_tests.rs`, `align_tests.rs`, `units_tests.rs`, `field_frame_tests.rs`, `drawtable_tests.rs`, `spelling_tests.rs` |
| **Inspector** | `DCApp/Inspector/` (+ `ToolbarCatalog.swift`) | `panes.rs`, `fillui.rs`, `widgets.rs`, `theme.rs`, `selpane.rs`, `animtimeline.rs`, and every group of `ribbon.rs` (each becomes an inspector control, a toolbar item or a menu item) | `panes.rs`, `animpane_tests.rs`, `animtimeline.rs`, `selpane_tests.rs`, `background_tests.rs`, `pattern_fill_tests.rs`, `theme_colors_tests.rs`, `theme_fonts_tests.rs`, `split_button_tests.rs`, `last_color_tests.rs`, `smartart_tests.rs`, `widgets.rs`, `theme.rs`, `ribbon.rs` |
| **Dialogs** | `DCApp/Dialogs/` | `dialogs.rs` (41 dialogs), `backstage.rs` (File: New from template, Info, Export, Print settings, Account → native sheets and panels), `opening.rs`, `credits.rs`, `settings.rs`, `uifonts.rs`, `toast.rs`, the palette in `menus.rs`, Find and Replace | `dialogs.rs` (14), `backstage_tests.rs` (23), `columns_dialog_tests.rs`, `paragraph_dialog_tests.rs`, `replacefonts_tests.rs`, `photo_album_tests.rs`, `reuse_picker_tests.rs`, `preferences_tests.rs`, `settings.rs`, `credits.rs`, `opening.rs`, `inbox_tests.rs`, `compare_tests.rs`, `datetime_tests.rs`, `uifonts.rs` |
| **Show** | `DCApp/Show/` | `show.rs`, `media.rs`, `textures.rs`, `apps/deckcraft/src/{audio,display,graphics}.rs`; DCAnim's show state machine and transition frames; DCRender's transition compositor (Metal per PLAN.md §5.1) | `show.rs` (27), `media.rs`, `textures.rs`, `texture_limit_tests.rs` |
| **Views** | `DCApp/Views/` (+ `DocumentWindowController.swift`) | `thumbs.rs`, `sorter.rs`, `notes.rs`, `status.rs`, `doc_window.rs`, the outline and notes-page views, `apps/deckcraft/src/pasteboard.rs`, printing (`print_pdf` → `NSPrintOperation`) | `sorter_tests.rs`, `notes.rs`, `status.rs`, `huge_deck_tests.rs`, `ui_soak_tests.rs` |
| **Automation** (lead) | `DCApp/Automation/` | `control.rs` (the window side), `capture.rs`, `apps/deckcraft/src/control_server.rs` | `capture.rs` (18), `control.rs`' screenshot test; `lib.rs` (62) is split by topic at integration |

**Porting tests.** deckcraft's UI tests drive egui through a test harness. Port the *behaviour* each one checks,
at whatever level the Swift app exposes it: `AppModel` and your area's controllers (DCAppModelTests/DCAppTests,
no window needed), or an `AppController` with windows created in-process. A test that only checks egui widget
mechanics (a focus ring, a texture cache) is listed in your notes as not applicable, with the reason. Name each
test's source in a comment, Rust names in camelCase, as in earlier waves. Put tests in
`Packages/DCApp/Tests/DCAppTests/<Area>*.swift` or `DCAppModelTests/<Area>*.swift`.

## Rules

- **Your files only:** your area's folder and your test files. **Shared files** — `AppController.swift`,
  `AppModel.swift`, `UICommands.swift`, `MenuTree.swift`, `PresentationDocument.swift`, `Features.swift`,
  `MenuBuilder.swift`, `Package.swift` — take minimal, additive edits only when unavoidable, re-read right
  before editing, and list each in your report. Never edit another area's folder; if you need something from
  it, add a small public hook in your own code or ask in your report.
- **Never crash** (CLAUDE.md): no `!`, `try!`, `fatalError`, `as!`, unchecked indices. AppKit callbacks run on the
  main thread; keep `MainActor.assumeIsolated` behind `Thread.isMainThread` checks.
- **No AppKit below DCApp.** Logic you want to test without a window goes in DCAppModel (your own files there:
  `DCAppModel/<Area>*.swift`).
- **Keep the shared tree green.** Build with your own scratch path (`swift build --scratch-path .build-<area>`,
  `swift test --filter 'DCAppTests|DCAppModelTests' --scratch-path .build-<area>`); stage files that don't
  compile in the scratchpad (`…/scratchpad/<area>-stage/`). If someone else's file breaks the build, wait and
  retry; never edit it.
- **No warnings. Don't commit.** Delete your scratch build folder and staging folder at the end.
- **Notes:** add a section for your area to `Packages/DCApp/PORT-NOTES.md` (create it if absent; append, don't
  rewrite others' sections): file map (Rust → Swift), what's native instead of ported, tests ported and not
  applicable, divergences, open items.

## Report

Files and test counts; the deckcraft behaviours covered and the ones left (with the reason); screenshots you
checked (paths); shared-file edits; divergences; the final `swift test --filter 'DCAppTests|DCAppModelTests'`
summary line.
