# Ribbon and start screen

**Status:** plan, draft 2, 2026-10-27: the operator's decisions are recorded (§12). **R0 is done** (2026-10-27; DCApp PORT-NOTES "Ribbon"). S1 and R1 wait for the go-ahead. · **Pin:** deckcraft `88c2ceff` · **Reads with:**
[PLAN.md](../../PLAN.md), [PORT-STATUS.md](../../PORT-STATUS.md), [EVALUATION.md](../../EVALUATION.md), and
DCApp's [PORT-NOTES.md](../../Packages/DCApp/PORT-NOTES.md) ("Inspector" and "Ribbon → Mac").

The operator wants two PowerPoint features in DeckCraftNative: a **start screen** and a **ribbon**. PLAN.md's
"Decided" table chose a Keynote-like layout with "**the ribbon is dropped**". This plan partly reverses that
decision. The ribbon comes back as an **optional window layout** that sits beside the inspector, and it is
generated from the same command registry. The Mac layout stays, and so do the inspector, the toolbar and the menus.

> **Guiding principle (the operator, 2026-10-27):** *familiarity, not a 100% match.* Someone who knows
> PowerPoint should be comfortable in our UI: the tabs, groups and buttons are where they expect, and they
> behave as they expect. Matching PowerPoint or deckcraft exactly is not a goal in itself. Where exact parity
> adds work and no comfort, it is left out. Commands keep deckcraft's ids and params, because that is about
> scripts, not looks.

## 1. Sources and the clean-room line

| Source | Used for | Rule |
|---|---|---|
| deckcraft `crates/ui-egui/src/ribbon.rs`, `ribbon/*.rs`, `backstage.rs`, `backstage/{files,info,print}.rs`, `opening.rs` (MIT OR Apache-2.0) | **The starting point**: the tabs, the groups, the controls and the command ids with their params, when contextual tabs show, the QAT defaults, and the start screen's sections. Arranged for PowerPoint users' comfort where the two differ | Portable. Ported files name their source and licence in their header, as the rest of DCApp does |
| Microsoft PowerPoint for Mac (installed; black-box) | **Behaviour only**: how groups fold as the window narrows, where the start window's parts sit, and how each part reacts | Described here in our own words. No screenshots, icons, theme thumbnails, templates or strings that PowerPoint shows or saves enter the repo or `../DeckCraftNative-Fixtures`. The first-run notes are kept outside the repo, in the session notes folder |
| Apple HIG (toolbars, sidebars, windows, accessibility) | Mac conventions | Wins over both when they disagree |

**Two facts from the deckcraft read change the brief:**

- **`opening.rs` is not the start screen.** It is the progress dialog that appears while a file loads in the
  background. deckcraft's start screen is **File › Home** (`backstage/files.rs`), forced whenever no presentation
  is open (`app.rs:177`).
- **deckcraft's ribbon is hand-written egui code, not data.** Each tab is a function. Only the command lookup is
  shared (`ribbon.rs` `big`/`small`/`enabled`). So there is no ribbon table to port. This plan writes one (§4)
  and checks it against deckcraft's code by hand, citing file and line.

## 2. What PowerPoint does (observed 2026-10-27)

These notes come from looking at PowerPoint and clicking. Nothing was saved, nobody signed in, and no setting was
changed. A first-run privacy notice appeared, and the start window was reached without going through it.

**The start window** is its own window (about 1400 × 1000 pt), not a sheet.
- **The left rail:** an account badge, then Home, New, Recents, Shared and Open. They behave as one radio group.
  The window reopens on the page and the sub-tab used last.
- **Home**
  - A *Themes* strip of seven tiles, with Blank first. A disclosure triangle collapses the strip, and *More themes*
    jumps to New.
  - Below the strip are the *Recents / Favorites / Shared with me* tabs. The table shows a file icon, then the name
    with its folder path as a breadcrumb, then "Last opened by you" as a relative time. That column is sortable from
    a header menu. *More presentations* is at the end of the list.
  - Hovering a row shows three inline actions: share, favourite (a star) and more (…).
  - Selecting a row turns the default button from **Create** into **Open**.
  - An empty Favorites tab shows a picture and a one-line hint.
- **New:** a scrolling grid of theme tiles. Selection shows as an outline. *Cancel* and *Create* sit at the
  bottom right. Pressing a tile directly creates the presentation at once, as a double-click does.
- **Recents:** the same table, with an All / Favorites filter.
- **Open:** recent folders and cloud places. "On My Mac" hands over to the system Open panel.
- **Search** is a field in the title bar.
- The **Home button** in a document's title bar brings the start window back.

**The document window**
- **The title bar** holds, from left to right:
  - the AutoSave switch, Home, Save, Undo (a split button), Redo, and "…" (customise these icons);
  - the document title, centred;
  - Comments, Share (a split button) and Search.
- **The ribbon tabs** are Home, Insert, Draw, Design, Transitions, Animations, Slide Show, Record, Review and View.
  - A contextual tab is added at the end: *Shape Format* appears when a shape is selected or text is being edited.
  - It is **not** switched to automatically. deckcraft behaves the same way.
- **Group captions are hidden.** Thin rules separate the groups.
- **Disabled controls stay in place,** greyed out.
- **The galleries:**
  - Design's theme gallery loads its thumbnails lazily, with spinners.
  - Transitions and Animations have inline galleries with a "›" control that expands them. The animation
    galleries are disabled until something is selected.
- **Narrowing the window**, measured on the Home tab:

  | Window width | What changes |
  |---|---|
  | about 1600 pt | everything at full size |
  | about 1150 pt | Clipboard and Slides lose their small-button labels and keep the icons. Shapes and Text Box shrink to small icons. Arrange, Quick Styles and Shape Fill/Outline fold into one *Drawing* drop-down button |
  | about 920 pt | Slides, Paragraph, Insert and Drawing each become one large drop-down button named after the group. Font stays expanded: it folds last |
  | about 700 pt | Font folds too. The tab row overflows into a "»" menu |

  At every width, Paste, Add-ins and Designer stay large.
- **View › Ribbon** shows and hides the whole ribbon. **File › New from Template…** opens the start window.

**deckcraft compared with PowerPoint:**

| Behaviour | PowerPoint | deckcraft |
|---|---|---|
| Narrow windows | groups fold in steps | the ribbon scrolls behind ‹ › chevrons, 160 px per click; nothing folds (`ribbon.rs:191-262`) |
| Contextual tabs | Shape Format | Shape Format, Picture Format, Table Design + Layout, SmartArt Design, Chart Design, Playback, and the three master tabs |
| KeyTips (Alt access keys) | none on the Mac | none |
| Tooltips | label and description | label and shortcut only (`ribbon.rs:308`) |
| Minimised ribbon | View › Ribbon hides it | `view.collapseRibbon` (⌘F1), or a click on the active tab or a double-click on any tab; saved in `ui.json` |
| Start screen | separate window, remembers its last page | File › Home, forced when nothing is open; no "show at launch" setting; Esc does nothing |
| Favourites and pinning | Favorites tab with a star | none; up to 12 recents, with "(missing)" and × Remove. **We follow deckcraft here** (decision 6) |

## 3. Adopt, adapt or skip

| Piece | Verdict | Why, and the Mac form it takes |
|---|---|---|
| Ribbon tabs, groups and controls | **Adopt** deckcraft's set, arranged as PowerPoint users expect | Every control is already a registry command, mapped in `RibbonMap`. Where deckcraft's order or grouping differs from what a PowerPoint user looks for, the familiar arrangement wins |
| Contextual tabs | **Adopt** deckcraft's seven predicates (`ribbon.rs:85-118`), already ported in `InspectorController` | Keep deckcraft's rule that a contextual tab is never switched to automatically (PowerPoint does the same). Tint contextual tabs with the accent colour |
| Group folding at narrow widths | **Adapt**, a PowerPoint-like behaviour that deckcraft lacks | Stepped sizes for each group (§5). deckcraft's scroll chevrons become the last resort only |
| Split buttons, galleries, spinners, colour grids | **Adopt**, with the native controls DCApp already uses | `Menu(primaryAction:)`, the colour-grid popover with `NSColorSampler`, and `ThemeTile`. The ribbon reuses `InspectorControls`, not new copies |
| Controls that never work (Screenshot, Ink to Text, Ink to Math, Cameo, Translate, Add-ins) | **Skip** | deckcraft and PowerPoint show some of these greyed out for good. A button that can never be pressed adds no comfort, so it is left out. Controls disabled only for the current selection stay visible, greyed out, as in PowerPoint |
| Quick Access Toolbar | **Adopt** deckcraft's model (`app.qat`, its defaults; kept in UserDefaults `DeckCraftQuickAccessToolbar`, `InspectorQAT.swift`) | In ribbon layout the QAT's buttons sit in the unified toolbar at the leading edge, beside the traffic lights, as PowerPoint and deckcraft both place them. In Mac layout it stays one toolbar menu item, as now |
| Title-bar Search, Present, Comments | **Adopt** | Search is the command palette (`app.palette`), Present is `show.fromCurrent`, and Comments opens the Review inspector tab. They are all toolbar items |
| AutoSave switch | **Skip** (decision 4) | AutoRecover is sufficient. `autosavesInPlace` stays off and deckcraft's crash recovery stays (EVALUATION.md §1). Nothing is scheduled to change that |
| Share button | **Adapt**: `NSSharingServicePicker` on the saved file | There are no accounts and no cloud, so this is the native Share menu and nothing more |
| Designer, Add-ins | Designer: **adopt** as `view.pane {designer}`. Add-ins: **skip** | deckcraft has Design Ideas but no add-ins |
| Record tab | **Adopt deckcraft's version**: From Beginning and From Current, which rehearse. Cameo is disabled | As deckcraft has it |
| KeyTips | **Skip** | Not a Mac convention, not in PowerPoint for Mac, not in deckcraft. Full Keyboard Access and the command palette cover it (§6) |
| Simplified (single-line) ribbon | **Skip** | Neither PowerPoint for Mac nor deckcraft has one. The inspector layout already fills that role |
| Live preview on hover | **Skip in this plan** | deckcraft previews SmartArt layouts only (`galleries.rs:104`). A preview on one gallery and not the others is parity, not comfort. Previewing every gallery means rendering into a scratch copy of the document: a candidate after R4 (§10) |
| Group captions | **Hidden**, as PowerPoint for Mac shows them by default | deckcraft never draws them. No setting for them, which is simpler. Accessibility always names each group, and a collapsed group's button carries its name |
| Start screen | **Adopt** as its own window (§7) | PowerPoint's shape, deckcraft's content (themes, starter templates, the sample, recents), and AppKit's data (`NSDocumentController`) |
| Start screen account badge, Shared tab, cloud places | **Skip** | There are no accounts. Open hands over to `NSOpenPanel` |
| Favourites | **Skip** (decision 6) | A plain recent list, as deckcraft has, is sufficient and simpler |
| Tooltips | **Adapt**: label, shortcut and a one-line description (decision 3) | PowerPoint users expect a sentence saying what a button does. deckcraft shows label and shortcut only. The descriptions are written in our own words (§6) |

## 4. One source of truth: the ribbon is generated

Today there are three hand-kept lists of where controls live: the `RibbonMap` table in
`DCAppModel/InspectorRibbonMap.swift`, which is checked by a test, the toolbar in `DCApp/Inspector/ToolbarCatalog.swift`,
and the menus in `DCAppModel/MenuTree.swift` with `MenuBuilder.swift`. All three name registry command ids.
Labels, shortcuts and `enabled` come from `CommandSpec` and the UI commands, through `L10n.commandLabel`.

The ribbon adds **one more table, and that table becomes the source the others are checked against.**

```
DCAppModel/RibbonLayout.swift        (new, no AppKit: a pure description, testable without a window)

RibbonLayout.tabs: [RibbonTab]
  RibbonTab   { id: "home" | … | "shapeFormat", title, contextual: ContextPredicate? }
  RibbonGroup { id, title, controls: [RibbonControl], foldOrder: Int, collapsedSymbol }
  RibbonControl
    .button(Cmd)                       // Cmd = command id + JSON params (deckcraft's, unchanged)
    .toggle(Cmd, state: StateKey)      // state read from `format.state` / ui state, as ribbon.rs fmt_state
    .split(main: Cmd, menu: CommandMenu)
    .menu(CommandMenu)
    .gallery(GallerySource, more: CommandMenu?)
    .dropdown(DropdownSource) | .spinner(Cmd, field) | .check(Cmd, field) | .color(Cmd, kind)
    + size steps: [.large, .medium, .small]  (the sizes this control can take; §5)
CommandMenu: the split or menu content, shared with ToolbarCatalog (moved down from DCApp into DCAppModel)
```

- **Labels, tooltips, shortcuts and enabled state are never written in the layout.** They come from the
  registry (`CommandSpec`, `UICommands`) through `L10n`, as the menus and toolbar already do. A control holds
  a command reference and nothing else.
- **`RibbonMap` is derived.** Each map group's `commands` becomes the union of the commands its ribbon group's
  controls run. The `place` column, which says where the group lives in the Mac layout, stays hand-written,
  because it describes the inspector. The existing test becomes "every RibbonLayout command is a registry or UI
  command; every RibbonMap group has a RibbonLayout group with the same command set."
- **The toolbar's menus move into `DCAppModel`** (`CommandMenus.swift`): New Slide, Shapes, Table, Chart,
  Picture, Media and Play. The toolbar's split items and the ribbon's split buttons then draw the same menus.
  `ToolbarCatalog` keeps only the `NSToolbarItem` wiring.
- **Icons:** one `CommandSymbols` table (command id → SF Symbol), used by the toolbar, the ribbon and the
  menus. It replaces the symbols scattered through `ToolbarCatalog.commands` and `ToolbarCatalog.symbol(_:)`.
  Where SF Symbols has nothing that fits, use template images drawn from DCGeometry's presets, as the
  shape icons already are. **We draw no icon to look like Microsoft's.**
- **Coverage check, not an order check:** `RibbonCoverageTests` asserts that every command deckcraft's ribbon
  runs (the list in `RibbonMap`, cited to `ribbon/*.rs`) is reachable from RibbonLayout, or is listed as left out
  on purpose with a reason. It doesn't pin tab or group order: that follows the guiding principle. When the pin
  moves, `git diff <pin>..origin/main -- crates/ui-egui/src/ribbon*` shows new commands to place.
- **One view, two layouts.** The ribbon renders RibbonLayout. The inspector keeps its SwiftUI sections, but
  every control that both show is one shared component: the font family and size pickers, B/I/U toggles, the
  colour grid, the theme and transition tiles, spinners that commit on Return, and sliders that commit on release.
  A behaviour fix then lands in both places.

**Where the ribbon goes in the window:** an `NSTitlebarAccessoryViewController` with
`layoutAttribute = .bottom`, hosting a SwiftUI `RibbonView`. It spans the full window width under the unified
toolbar and above the split view, which is where both PowerPoint and deckcraft put it. `DocumentWindowController`
adds or removes the accessory when the layout changes. The window already uses `.fullSizeContentView`, and the
sidebar and editor are pinned to the safe area, so they move down on their own. The split view (navigator, editor,
inspector) is unchanged, and `InspectorFeature` keeps reaching into `wc.split` as it does today.

## 5. Folding at narrow widths

The fitting is a pure function in DCAppModel, so it is tested without a window:

```
RibbonFit.fit(groups: [GroupMeasure], available: CGFloat) -> [GroupID: GroupSize]
GroupSize: .large → .medium (small icons with labels) → .small (icons only) → .collapsed (one labelled button
           whose popover shows the whole group at .large)
```

- **Order.** Start with every group at `.large`. While the total width is greater than the space available,
  step down the group with the highest `foldOrder` that can still step down. Ties go to the group furthest right.
  This reproduces what PowerPoint does: Drawing and Insert fold first, Font folds last, and Paste never folds.
  deckcraft sets no `foldOrder`, so ours is written into RibbonLayout from these observations: in words, not
  copied numbers.
- **Measuring.** Each group's width at each size is measured once per locale, Dynamic Type setting and
  font-size preference, then cached. The ribbon is a SwiftUI `Layout` that reads the cached widths, asks
  `RibbonFit`, and renders each group at the size it was given. This avoids measuring on every frame.
- **The last resort.** If every group is `.collapsed` and they still don't fit, deckcraft's ‹ › scroll
  chevrons appear (`ribbon.rs:191`).
- **Tabs.** A tab row that doesn't fit puts the tail tabs into a "»" menu. The selected tab always stays visible.
- **Minimised.** `view.collapseRibbon` (⌘F1, deckcraft's binding) hides the controls and leaves only the tab row.
  A click on a tab then shows that tab's controls as a transient panel, which closes again after a command runs.
  `UiState.ribbonCollapsed` holds the minimised state. That field exists today only for `ui.inspect`; it becomes
  live.

## 6. Keyboard and accessibility

- **The commands that already exist come back to life:**
  - `view.tab {tab}` selects a tab and expands the ribbon;
  - `view.collapseRibbon` minimises it.
  - Both are UI commands today (`UICommands.swift:35-36`), kept so deckcraft's scripts work.
- **A new menu item, View › Ribbon (⌥⌘R).** This is PowerPoint for Mac's toggle. It switches the window between the
  ribbon layout and the Mac layout, and it is a UI command, `view.ribbon {on?}`. Its menu path and label go
  into the Commands catalog.
- **Focus.**
  - The ribbon is a focus section.
  - With Full Keyboard Access, Tab moves from the tab row into the controls, and the arrow keys move within a
    group and between groups.
  - Space or Return runs the focused control. ⌥↓ opens a split button's menu.
  - Esc returns focus to the canvas.
  - Split menus are entered from either half, as deckcraft's are (`split_button_tests.rs:65`).
- **No KeyTips** (see §3). The command palette (⇧⌘P) and the Help menu's search reach every command by name.
- **What VoiceOver sees:**
  - The tab row is an `AXTabGroup` of radio buttons; contextual tabs say "contextual".
  - Each group is an `AXGroup` named after the group, even with captions hidden.
  - A split button is two elements, "Bullets" and "Bullets options", as deckcraft names them (`widgets.rs:68`).
  - A gallery is an `AXList` whose items carry the theme, transition or style name.
  - A collapsed group is a pop-up button named after the group.
  - Disabled controls report as disabled and are never removed.
- **Tooltips** show the label, the shortcut with macOS glyphs, and a one-line description (decision 3).
  - The descriptions are written in our own words, never copied from PowerPoint. They live in a
    `CommandHelp` table in DCAppModel, keyed by command id, and are localised in `Commands.xcstrings` as
    `help.<id>`. The engine's `CommandSpec` is untouched, because its English stays byte-identical for parity.
  - The same text serves the toolbar tooltips, the command palette's subtitle and VoiceOver's help
    (`accessibilityHint`), so it is written once.
  - A test requires a description for every command the ribbon or toolbar shows. The rest (menus and
    palette only) follow in R4. That is roughly 400 strings in all.
- **Contrast and motion.** The ribbon uses DesignScaffold's tokens and semantic colours, so Increase Contrast,
  Reduce Transparency and dark mode follow macOS. It has no animations beyond the system's.

## 7. The start screen

**The form.** A separate window, `StartWindowController`: an `NSWindow` hosting SwiftUI, with a
`NavigationSplitView` whose sidebar is the source list and a `.searchable` field in the toolbar.
- It reopens on the page last used, which is saved in `ui.json`.
- It is not a document window. It closes when a presentation opens or is created, and it can be reopened at
  any time.

**The sidebar** has three pages: Home, New and Open. Recents is Home's list shown full height, so it is not a
separate page.

| Part | What it shows | Data source |
|---|---|---|
| **Home: Themes strip** | Blank, then the built-in themes, then "Sample deck: Northern Lights" (deckcraft's Home has the same set), and *More themes* → New | `DCModel` `Theme.builtins`: DeckCraft, Harbor, Ember, Meadow, Nocturne, Paper, Coral Reef, Slate. These are deckcraft's own themes, with OFL fonts. The sample is DCEngine's sample deck |
| **Home: Templates strip** | deckcraft's starter templates, and *More templates* → New | DCEngine `Templates.starters`: Briefing, Lesson, Pitch, Field Notes, Quarterly, Evening Talk (`templates.rs:26-160`) |
| **Home: Recent** | name, folder, last opened (relative), and a thumbnail. Row actions in a context menu: Show in Finder, Share…, Remove from List. Missing files are greyed out with "(missing)" | Recents: **`NSDocumentController.recentDocumentURLs`**. The app already records into it (`AppControlHost.open` calls `noteNewRecentDocument`), but **no File › Open Recent menu exists yet** (`MenuTree` has none). S1 adds the standard one, so that menu, the Dock menu and the start screen show one list. Last opened: the file's `URLResourceValues` (`contentAccessDate`). Thumbnails: `QLThumbnailGenerator`, which our Quick Look extension serves for `.deckcraft` and `.pptx` |
| **New** | Blank, every theme, every template, and the sample, as a grid. Search filters it | Templates through `Templates.matching(query)`, which already matches name, summary, theme and slide titles |
| **Open** | *Open…* (the system panel), *Recover Unsaved Presentations* when AutoRecover holds any, and the recent list | `app.openDialog`; `file.recovery.open` |
| **Buttons** | Cancel (Esc), and Create or Open (Return), whichever fits the selection. A double-click acts at once | `file.new {}`, `{theme}` or `{template}`; opening goes through `NSDocumentController.openDocument(withContentsOf:)` |

- **The tiles are rendered, not drawn.** Each one is DCRender's render of that theme's or template's title
  slide, made offline from `file.new` in a scratch session, cached in `~/Library/Caches`, and keyed by theme
  name and app version. While a tile renders it shows a placeholder, as PowerPoint's thumbnails do. **We ship
  no template images.** Everything is drawn from the app's own themes and fonts.
- **When it opens:**
  - **At launch.** If nothing opens a document (Finder, the command line, `--sample`, state restoration), the start
    window opens in place of today's untitled document. `AppController.applicationShouldOpenUntitledFile` returns
    `false` when the setting is on.
  - **From the menus and buttons.** File › New from Template… (⌥⌘N, the existing entry) opens it on New. The
    `app.home` QAT button opens Home.
  - **From commands.** `app.backstage {page: home|new|open}` routes to it.
    - The routing lives in `DialogsRouting.backstage`. Today home and new both open the "New Presentation"
      window (dialog `new`, a window per `DialogCatalog.isWindow`). It has Search, Themes, the sample and
      Templates rows from `DialogsForms.newRows`, with the `new:*` actions in `DialogsActions`. **The start
      window grows out of that dialog.** Its sources and actions move into a `StartScreenModel`, and the generic
      `DialogFormView` tiles give way to rendered tiles. That leaves one gallery.
    - Info, Save As, Print, Export and Account keep their current Mac forms: the Properties sheet, the system
      panels, the export sheet and About.
- **Keyboard.**
  - Arrow keys move through the tiles and rows.
  - Return creates or opens. ⌘F focuses Search. Esc cancels.
  - deckcraft's rule that typing on the start screen goes nowhere (`backstage/tests.rs:462`) holds, because the
    window has no canvas.
  - deckcraft's start-screen tests (`backstage/tests.rs:441-530`) are marked not applicable in DCApp's
    PORT-NOTES today ("the Mac has no start screen"). S1 ports them.
- **Settings:** "Show the start screen when DeckCraftNative opens", on by default (decision 5). Off restores
  today's behaviour, an untitled presentation.
- **Scripts and the alpha gate.** The control channel keeps working with the start window open. `file.new`
  closes it.
  - `ui.inspect` already reports deckcraft's `home` and `backstage` keys, but they are hard-coded to
    `false` and `null` (`AppControlHost.swift:99-122`). They become live: `home: true`, `backstage: "new"`,
    plus `startScreen: {page, selection, query}`.
  - `ui.screenshot` captures the key *document* window, so it gains `{window: "start"}`.
  - `DECKCRAFT_NO_PREFS` runs keep the default (on), so the gate exercises the start screen.

## 8. Settings, and which layout is the default

Settings › General gains a **Window layout** choice:

| Choice | Toolbar | Ribbon | Inspector |
|---|---|---|---|
| **Toolbar and inspector** (today's Mac layout) | as now: New Slide, Shape, Text Box, Table, Chart, Picture, Media, QAT menu, Comment, Play | hidden | open, five tabs |
| **Ribbon** | the QAT buttons at the leading edge, the title, then Search, Present, Comments and Share | shown | **closed by default; it becomes the task pane.** The ribbon's Format Pane, Selection Pane, Animation Pane, Design Ideas and Comments buttons open the matching inspector tab with `view.pane`, as PowerPoint's task panes open beside the slide. This needs no new code: `view.pane` already picks the tab |

- View › Ribbon (⌥⌘R) switches the front window and saves the choice as the default for new windows.
- "Show the start screen at launch" (on) sits beside it.
- The layout goes in `UiState` (`layout`), so `ui.inspect` and `ui.set` reach it. The start-screen setting goes there too. The rows join the Settings dialog's General
  section (`DialogsForms` preferences rows), which applies changes live and restores them on Cancel.
- **Today the Settings window has no layout setting.** It offers only Appearance, units and the editing options.
- **The default (decision 1):** the **toolbar and inspector** stay the default until milestone R4's gate
  passes. After that, **Ribbon** is the default for new installs, and existing users keep their choice
  (an existing `ui.json` without `layout` reads as the Mac layout). The start screen is on by default from S1.

## 9. Localisation and the pseudo-language width check

- **New strings** go into String Catalogs, under the Wave 6 convention: tab titles, group titles, the
  collapsed-group buttons, the tooltip descriptions, the start-screen copy and the Settings labels.
  - Tab and group titles get their own `Ribbon.xcstrings` in DCAppModel, keyed `ribbon.tab.<id>` and
    `ribbon.group.<tab>.<id>`. They need their own keys: "Layout" is a tab, a Home control and a Design control,
    and "Arrange" is both a group and a button.
  - Control labels are command labels, which `Commands.xcstrings` already holds. `Tools/l10n/commands.sh`
    regenerates the new UI commands.
  - The catalog-completeness test covers the new catalog.
- **Width checks.** The folding and the tab overflow have to work in longer languages, so each milestone runs:
  - `Tools/l10n/pseudo.sh` (en-XA: accented and bracketed) and `-NSDoubleLocalizedStrings YES` (every string
    twice as long), with a screenshot of each tab at 1600, 1150, 920 and 700 pt;
  - a right-to-left run (`-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`). In right-to-left
    the ribbon mirrors and folds from the left.
  - The pass rule: no clipped label. The ribbon reports `truncated: [controlID]` in `ui.inspect`, measured
    from the text layout, so the check is a script and not someone reading screenshots.
  - That is new. Wave 6 checked clipping by eye in pseudo-locale screenshots, and two inspector items it found
    are still open: Theme Colors' wells and Review's segments.
  - `FittingPicker` stays what the inspector uses. The ribbon's equivalent is the `.collapsed` step.

## 10. Milestones

Every milestone ends with `swift test` green and warning-free, the never-crash lint clean, the
**alpha gate at 16/16** (`Tools/app/alpha-gate.sh`), an updated DCApp `PORT-NOTES.md`, and a PORT-STATUS.md
entry. Screenshots are of **our app only**, taken with the control channel's `ui.screenshot`.

| # | Scope | Acceptance checks | How it is verified |
|---|---|---|---|
| **R0. One table** | `RibbonLayout` (data only), `CommandMenus` moved into DCAppModel, `CommandSymbols`, `CommandHelp` (the table, empty to start), `RibbonMap` derived from `RibbonLayout`. No UI changes | `RibbonCoverageTests`: every command deckcraft's ribbon runs is placed or listed as left out with a reason. Every command resolves in the registry. The toolbar's menus are unchanged (the item-for-item `InspectorToolbarTests` still pass) | `swift test`. The app looks and behaves exactly as before, and the alpha gate proves it |
| **S1. Start window** | `StartWindowController` (Home, New, Open, Search), rendered tiles with a cache, a plain recent list from NSDocumentController, the launch rule, the Settings toggle, `app.backstage`/`app.home` routing; the "new" dialog window folded into it; File › Open Recent; deckcraft's start-screen tests ported | A launch with no file shows the start window and no untitled document. Create with each theme and template gives the same deck as `file.new` with the same parameters (compared with `document.inspect`). Recents match File › Open Recent. A missing file shows "(missing)" and does nothing when chosen. Esc closes. The setting turned off restores the untitled document | DCAppModel tests for the start model (sources, search, missing files, page memory). Control channel: `ui.inspect.home` / `backstage` / `startScreen`, `app.backstage {page}`, `file.new` closing it, and `ui.screenshot {window: "start"}`. A new alpha-gate step, "0. start screen → create from Harbor → one document", with a screenshot |
| **R1. Static ribbon** | `RibbonView` in the titlebar accessory, all ten tabs at `.large`, buttons, toggles and splits through `AppModel.run`, enabled and toggle state from the session, View › Ribbon, the Settings layout choice, the leading QAT in ribbon layout, **tooltip descriptions for every command the ribbon and toolbar show** | Every control runs its command with deckcraft's params: a test walks RibbonLayout and fires each `Cmd` against a scratch session. The toggles' state follows `format.state`. Switching layouts keeps the document, the selection and the undo stack. Every ribbon and toolbar command has a `CommandHelp` entry and a catalog string | DCAppTests with a hosted window, as `InspectorToolbarTests`. Control channel: `view.ribbon`, `view.tab`, `ui.inspect.ribbon {tab, collapsed, layout}`, and a screenshot of each tab |
| **R2. Contextual tabs and galleries** | The seven contextual tabs and the master tabs; galleries for themes, variants, transitions, animations, table styles, picture styles, quick styles, shapes and SmartArt layouts; "›" expansion; the colour grids and spinners shared with the inspector | Selecting each object kind shows its contextual tabs (the predicates are tested in the model), and never switches tabs. Choosing a gallery item is one undo step. The theme gallery renders the same tiles as the start screen | DCAppModel tests for the predicates and gallery sources. Control channel: select a shape, a picture, a table, a chart, SmartArt and media in turn, then `ui.inspect.ribbon.tabs`, with a screenshot of each contextual tab |
| **R3. Folding, keyboard, accessibility** | `RibbonFit`, the measurement cache, collapsed-group popovers, tab overflow, the scroll fallback, minimising (⌘F1), focus sections, AX roles and names | `RibbonFit` unit tests: the fold order is monotonic as the width falls, Paste and Designer never fold, the selected tab never overflows, the same input gives the same output. In the app, every tab at 1600/1150/920/700 pt is laid out with nothing overlapping or clipped. VoiceOver reads every group name and split half. All of a tab is reachable with Full Keyboard Access alone | Control channel: `ui.resize` (it exists) at four widths, then `ui.inspect.ribbon.groups[*].size`, `truncated == []`, and screenshots. An Accessibility Inspector audit with no warnings on the ribbon, recorded in PORT-NOTES |
| **R4. Localisation and polish** | `Ribbon.xcstrings`, the remaining tooltip descriptions (menu- and palette-only commands), the pseudo, double-length and right-to-left runs, the persistence of tab, minimised state, layout and QAT, the Share item, docs; then **the ribbon becomes the default for new installs** (decision 1) | The three pseudo runs give `truncated == []` at all four widths on every tab. Every command in the palette has a description. A `ui.json` from before the ribbon loads as the Mac layout. A fresh `ui.json` gets the ribbon. The alpha gate passes in **both** layouts (run twice, with `ui.set {layout}`) | `Tools/l10n/pseudo.sh` plus a new `Tools/app/ribbon-widths.sh` that drives the widths and checks `truncated`. The catalog-completeness test over `help.*`. Alpha gate ×2 |

**The order:** R0, then S1 and R1 side by side (they touch disjoint files: the start window under `DCApp/Start/`
and `DCAppModel/Start*.swift`, the ribbon under `DCApp/Ribbon/` and `DCAppModel/Ribbon*.swift`), then R2 →
R3 → R4. Parallel sessions build with their own `--scratch-path`, as CLAUDE.md says. Live hover preview for
every gallery (§3) is a candidate after R4, not part of this plan.

## 11. Risks

| Risk | Mitigation |
|---|---|
| **It reverses a recorded decision.** PLAN.md's "Decided" table and PORT-STATUS's 2026-10-26 decision said the ribbon is dropped, and the code comments in `UiState.swift` and `InspectorRibbonMap.swift` say the same | The reversal is partial and explicit: the ribbon is an *optional layout*, and the Mac layout stays fully supported. Approved 2026-10-27: PLAN.md's row and PORT-STATUS's decisions carry the dated amendment. The code comments are updated in R0 |
| **Two UIs drift apart.** The ribbon and the inspector could each grow controls the other lacks, or behave differently | One `RibbonLayout` from which `RibbonMap` is derived, shared `CommandMenus`, shared control components, and the coverage test. The alpha gate runs in both layouts from R4 |
| **The fold order looks like PowerPoint but is guessed.** Our widths and labels differ | `foldOrder` is data, tuned from screenshots of our own app at the four widths. The pseudo runs make sure it still holds with long strings |
| **Window height.** The ribbon (about 90 pt) plus the toolbar takes vertical space on 13" displays | Minimising (⌘F1) leaves the tab row only. The ribbon layout puts insert items in the ribbon, not the toolbar, so the toolbar stays one row. Users of the Mac layout lose nothing |
| **Performance.** Galleries rendered by DCRender, recent-file thumbnails, and per-selection enabled checks for about 200 controls | Tiles are rendered off the main thread and cached. Thumbnails come from Quick Look, which is asynchronous. Enabled state is computed once per session change, as the toolbar's validation is, not once per control per frame |
| **A start screen at launch breaks scripted runs** | It never blocks: the control channel, `file.new`, files passed on the command line and `--sample` all bypass or close it. The alpha gate gets a start-screen step rather than an opt-out |
| **Clean room.** Watching PowerPoint closely invites copying | Only behaviour is written down, in our own words (§2). Icons are SF Symbols or our own preset geometry. Tile art is our render of our themes. Nothing PowerPoint shows is captured into the repo or the fixtures. Review each milestone's screenshots for anything that looks like Microsoft's work |
| **Upstream moves its ribbon** | `RibbonCoverageTests` and the pin-move routine in CLAUDE.md: diff `crates/ui-egui/src/ribbon*`, then place any new commands |
| **Tooltip text drifts toward PowerPoint's wording** | Descriptions are written from what our command does, never from PowerPoint's tooltips, and reviewed with the rest of each milestone |
| **Recents from two sources.** deckcraft keeps `UiState.recent` with 12 paths; macOS keeps its own list | NSDocumentController is the source of truth. `UiState.recent` is still persisted but, today, never read or written; S1 writes it from NSDocumentController for `ui.inspect` parity |

## 12. Decisions (2026-10-27)

The operator answered the six open questions. Their note applies to the whole plan: *"We don't need to match
100% but we would want someone familiar with Powerpoint to be comfortable in our UI"* (the guiding principle at
the top).

| # | Question | Decision | Where it lands |
|---|---|---|---|
| 1 | The default layout | **The recommendation, accepted.** The toolbar and inspector stay the default until R4 passes. Then new installs get the ribbon, and existing users keep their choice | §8; R4 |
| 2 | Amending PLAN.md | **Approved.** PLAN.md's "Decided" UI row and PORT-STATUS's 2026-10-26 decision carry the dated amendment | PLAN.md, PORT-STATUS.md (done with this revision) |
| 3 | Tooltip descriptions | **Add them.** One line per command, in our own words | §6; R1 for the ribbon's and toolbar's commands, R4 for the rest |
| 4 | AutoSave in the title bar | **No switch. AutoRecover is sufficient.** Nothing is scheduled to change it | §3 |
| 5 | The start screen at launch | **On by default, with the Settings switch** | §7, §8; S1 |
| 6 | Favourites | **Dropped.** A plain recent list, as deckcraft has, because it is simpler | §3, §7; S1 |

**Trimmed by the guiding principle** (they served exact parity, not comfort):
- **The order-equality parity test** became a coverage test. Every deckcraft ribbon command must be placed, but
  tab and group order may follow what PowerPoint users expect.
- **The SmartArt-only hover preview** is gone. One gallery with a preview and the rest without is parity, not
  comfort. Hover preview for every gallery stays a candidate after R4.
- **Controls that can never work** (Screenshot, Ink to Text, Ink to Math, Cameo, Translate, Add-ins) are left out
  instead of greyed out for good.
- **The "Show group titles" setting** is gone. Captions stay hidden, as in PowerPoint for Mac, and accessibility
  still names every group.
- **Favourites**, by decision 6.

Kept although they look like parity: deckcraft's command ids and params, `view.tab`, `view.collapseRibbon` and the
`home`/`backstage` keys in `ui.inspect`. Those keep deckcraft's scripts and MCP prompts working, and they cost
nothing on screen.
