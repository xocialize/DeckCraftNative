# DCApp — port notes

The Mac app: a rewrite of deckcraft's `crates/ui-egui` (about 42k lines) and `apps/deckcraft` in AppKit and
SwiftUI, at the pin in `Tools/oracle/pin.env`. deckcraft's UI is the *behaviour* matched (commands, state,
tests); the layout and idioms are the Mac's (PLAN.md "Decided"; amended 2026-10-27: the ribbon returns as an optional
layout, [Docs/plans/Ribbon-and-StartScreen.md](../../Docs/plans/Ribbon-and-StartScreen.md)). **Status: Wave 5, done (2026-10-27); ribbon R0 done
(2026-10-27, see "Ribbon"); start window S1 done (2026-10-28).**
The architecture, the areas and the rules are in [WAVE5-PLAN.md](../../WAVE5-PLAN.md).

Two targets:

- **DCAppModel** (no AppKit): `AppModel` (`SlideApp::run` and `run_ui`'s state-only arms), `UiState`
  (`ui.json`), `UICommands` (`UI_COMMANDS`), `Palette` (`palette_items`), `MenuTree` (`menu_tree`), `Shortcut`.
- **DCApp** (AppKit, SwiftUI): the app delegate and `AppController` (the `AppHost`, its extension points, the
  document sync), `PresentationDocument` (NSDocument per engine document), `DocumentWindowController`,
  `MenuBuilder`, and one folder per area. `Apps/DeckCraftNative` (Xcode, bundled) and `Apps/DeckCraftDev`
  (SwiftPM, unbundled) both call `DeckCraftApp.main()`.

## Core

| deckcraft | Swift |
|---|---|
| `lib.rs` `UiState`, `ViewMode`, `sanitized`, `RECENT_MAX`, `ZOOM_RANGE` | `DCAppModel/UiState.swift` (`Brightness` gains `system`; the ribbon's fields stay for `ui.inspect`) |
| `lib.rs` `UI_COMMANDS` | `DCAppModel/UICommands.swift` |
| `lib.rs` `SlideApp::run`, `run_ui` (state-only arms), `flag`, `grid_options_touched` | `DCAppModel/AppModel.swift` |
| `menus.rs` `palette_items`, `menu_tree` | `DCAppModel/UICommands.swift` (`Palette`), `DCAppModel/MenuTree.swift` |
| `apps/deckcraft/src/main.rs` `startup`, launch | `DCApp/DeckCraftApp.swift` (`Launch`), `DCApp/AppController.swift` (`AppDelegate`) |
| `packaging/macos/Info.plist.in` (document types) | `Apps/DeckCraftNative/Support/Info.plist`; `DocumentTypes` |

- **One session.** `AppModel.session` holds every presentation, as deckcraft's app does; a
  `PresentationDocument` is a handle on one by `DocState.uid` and gives it NSDocument's lifecycle. Reading and
  writing use the engine's coders. Documents the engine opens or closes itself gain or lose a window
  (`AppController.syncDocuments`).
- **The `.deckcraft` UTI is deckcraft's** (`ai.storyteller.deckcraft.presentation`): the format is
  byte-compatible, so both apps claim it.
- **Tests:** DCAppModelTests (AppModel, palette, menu tree, shortcuts, UiState) and DCAppTests (launch,
  document types). `menus.rs`' `palette_has_one_export_entry_that_opens_the_dialog` and `main.rs`' launch tests
  are ported.

## Automation (the control channel's window side)

| deckcraft | Swift |
|---|---|
| `apps/deckcraft/src/control_server.rs` | DCAutomation `ControlServer` (see its PORT-NOTES); started by `AutomationFeature.start(port:)` on `--control PORT` / `DECKCRAFT_CONTROL_PORT` |
| `control.rs` `handle` (window arms), `inspect`, `all_commands`' UI half | `DCApp/Automation/AppControlHost.swift` (`ControlHost`) |
| `control.rs` `save_screenshot`, `capture.rs` | `DCApp/Automation/AutomationFeature.swift` (`screenshot`, `capture`, `encode`) |

- **Threads.** The server's connection threads queue each request and wake the main thread, which takes it
  (`take`, so a request whose sender gave up never runs late), answers with `Control.handle`, and replies. The
  host refuses calls off the main thread instead of trusting them.
- **Screenshots.** After the window settles (120 ms, `capture.rs`' `SETTLE`), the document window is captured
  with ScreenCaptureKit when the app may record the screen (the window as shown, materials included), else
  drawn offscreen with `cacheDisplay` (sidebar and inspector materials come out blank). The reply is
  `save_screenshot`'s: a path reply writes the PNG and carries no base64; an inline reply carries it.
  `capture.rs`' token/epoch/budget machinery is egui's one-shot callback plumbing and isn't needed: the capture
  is synchronous with the main thread (or one async ScreenCaptureKit call); the 128 MiB image cap is kept.
- **Synthetic input** (`ui.move`/`click`/`drag`): real `NSEvent`s sent to the key document window, in window
  content coordinates with y down (deckcraft's), converted to AppKit's base coordinates.
- **Extension points.** Areas add control methods (`app.control`), `ui.inspect` keys (`app.inspect`) and key
  interceptors for `ui.key` (`app.interceptKeys`). Defaults answer `ui.set`, `ui.screenshot`, `ui.resize`,
  `ui.focus`, `ui.move`/`click`/`drag`, `show.start`/`show.end` (through `AppModel.run`) and `app.quit`
  (automation quits without asking; `{"save": true}` saves first).
- **Tests** (`DCAppTests/AutomationTests.swift`): `control.rs`' `screenshot_reply_is_path_only_or_explicitly_inline`;
  the UI command listing; window coordinates. `capture.rs`' 18 tests check egui's capture budget, settle
  passes and token correlation: not applicable (above).

## Dialogs (the dialogs, the File backstage, Settings, the palette, Find, toasts, file panels)

deckcraft draws a dialog every frame from `Dialog { id, params, fields }` and runs its OK from the drawing
code. Here the same state is `DialogController` (DCAppModel, no AppKit): opening a dialog seeds its fields,
`form` is a pure function of them (rows: text, check, choice, radio, tabs, list, actions, items, colour, grid,
tiles, sample), `set(key, value)` edits a field (and keeps dependent fields in step, as `reconcile_size_fields`
does), and `press(id)` runs a button or an in-form action. The window (`DialogFormView`) renders the rows
generically, so the Mac window, the tests and the control channel change a dialog the same way.

| deckcraft | Swift |
|---|---|
| `dialogs.rs` `Dialog`, `show`'s close paths (Preferences restore, Tabs → Paragraph return) | `DCAppModel/DialogsModel.swift` (`Dialog`, `DialogController.open/cancel/set/press`, `FormRow`, `DialogServices`, `Toast`, `PaletteState`) |
| `dialogs.rs` `title`, each body's buttons | `DCAppModel/DialogsCatalog.swift` |
| `dialogs.rs` seeding and drawing halves of `body`, `*_dialog`; `backstage.rs` Info and New pages | `DCAppModel/DialogsForms.swift` |
| `dialogs.rs` acting halves; `preferences_snapshot`, `restore_preferences`; `lib.rs` `export_as` | `DCAppModel/DialogsActions.swift` |
| `dialogs.rs` free helpers (`parse_zoom_percent`, `ms_as_seconds`, hyperlink seeds, size/position, `columns_value`, `paragraph_return_params`, `gif_options`, `pretty_equation`, `date_rows`, `selected_language`); `squiggles::LANGS`; `widgets::fmt_num` | `DCAppModel/DialogsHelpers.swift` |
| `lib.rs` dialog arms of `run_ui`, `drain_requests`, `pick_and_run`, `pick_and_reuse`, `reuse_slides`, `execute_on_target`, `capture_file_target`; `backstage.rs` `Page`, `PROPERTIES`, `format_bytes`; `menus.rs` `palette`; `settings.rs` | `DCAppModel/DialogsRouting.swift` |
| `toast.rs` `missing_fonts_message`, `note_missing_fonts` | `DialogsModel.swift` (`DialogToast`, `noteMissingFonts`) |
| egui drawing of the dialogs | `DCApp/Dialogs/DialogFormView.swift` (SwiftUI `Form` in `.columns` style; `DesignScaffoldPicker` for findable lists) |
| `dialogs::show`, `menus::palette`, `toast::show`, `apps/deckcraft` `rfd` pickers | `DCApp/Dialogs/DialogPresenter.swift` |
| install, control methods, `inspect`'s `dialog` | `DCApp/Dialogs/DialogsFeature.swift` |

### The dialogs (status)

All open from `app.dialog {id}`, the engine's `UiRequest.dialog(id, params)` and `ui.dialog.open {id, fields}`,
and each OK runs deckcraft's command with deckcraft's params.

| id | Title | OK runs | Status |
|---|---|---|---|
| `table` | Insert Table | `insert.table {rows, cols}` | done |
| `slideSize` | Slide Size | `design.slideSize {w, h, scale}` (exact points kept beside the 2-decimal text) | done |
| `sizePosition` | Size and Position | `shape.sizePosition` (scale ↔ size, lock aspect, as typed) | done |
| `headerFooter` | Header and Footer | `design.headerFooter` (Apply / Apply to All; a format only when picked) | done |
| `hyperlink` | Insert Hyperlink (⌘K) | `insert.hyperlink` (seeded from the caret word or the shapes' click; preserved actions) | done |
| `setupShow` | Set Up Slide Show | `show.setup` | done |
| `zoom` | Zoom | `ui.zoom` (Fit or a percent) | done |
| `comment` | New Comment | `comment.add`, Comments pane | done |
| `altText` | Alt Text | `shape.altText` | done |
| `outline` | Slides from Outline | `slide.fromOutline` | done |
| `renameSection` / `renameShape` / `renameLayout` | Rename | `section.rename` / `shape.rename` / `master.renameLayout` | done |
| `reuseSlides` | Reuse Slides | `slide.reuse` on the captured presentation and slide | done |
| `paragraph` | Paragraph | `format.paragraphDialog`; Tabs… returns here | done |
| `tabs` | Tabs | `format.tabs` | done |
| `font` | Font | `format.fontDialog` (one OK, one undo) | done |
| `about` | About DeckCraft | links | done (About tab; Contributors and Models tabs not ported: deckcraft builds them from `contributors.json` at compile time) |
| `preferences` | Settings | applies as changed; Cancel / close restores | done (a window) |
| `autocorrect` | AutoCorrect | `text.autocorrect` add/remove; options apply as changed | done |
| `gridOptions` | Grid Options | `view.gridOptions` (errors shown in the dialog) | done |
| `columns` | Columns | `format.columns` with the changed fields only | done |
| `export` | Export | save panel, then `file.export` (PDF slides/notes/handouts, hidden slides; PNG transparent; JPEG; PPTX; outline; RTF; GIF size/seconds/range/loop/hidden) | done |
| `symbol` | Symbol | `text.edit` if needed, `insert.symbol` | done |
| `photoAlbum` | Photo Album | `insert.photoAlbum` / `insert.photoAlbumEdit` | done |
| `replaceFonts` | Replace Font | `font.replace`, stays open | done |
| `equation` | Equation | `insert.textBox` + `text.exit` + font, italic, size | done |
| `dateTime` | Date and Time | `insert.dateTime` | done |
| `spelling` | Spelling | `slide.go`/`edit.select`, `review.addToDictionary`, `review.spellingChange`, `slide.notes` | done |
| `pasteSpecial` | Paste Special | `edit.pasteSpecial` | done |
| `find` | Find and Replace (⌘F/⌘H) | `text.find`, `text.replace` (one, all) | done |
| `accessibility` | Accessibility Checker | `slide.go`, `edit.select` | done |
| `language` | Language | `format.language` / `format.languageAll` | done |
| `customShow` | Custom Shows | `show.customShow` (create, delete), `show.start {custom}` | done |
| `chartData` | Chart Data | `chart.data` (grid editing, + Row, + Series) | done |
| `trim` | Trim Media | `media.options` | done |
| `smartart` | Choose a SmartArt Graphic | `insert.smartArt`, SmartArt pane | done |
| `bullets` | Bullets and Numbering | `format.bullets` / `format.numbering` (None) | done |
| `action` | Action Settings | `shape.action` (click / hover tabs) | done |
| `themeColors` | Create New Theme Colors | `design.colors` | done (swatches open the system colour panel) |
| `themeFonts` | Create New Theme Fonts | `design.fonts` | done |
| `quit`, `close` | Save changes? | — | **native**: NSDocument's close and quit alerts (Save / Don't Save / Cancel) |
| `info` (Mac) | Properties | `file.properties` (changed fields only); Check for Issues, Revert, Copy Path, Show in Finder | done (backstage Info) |
| `new` (Mac) | New Presentation | `file.new {theme | template}`, the sample deck | done; since S1 the start window is File › Home/New/Open, and this dialog is script-only (`ui.dialog.open {id: "new"}`), its tiles taken from `StartCatalog` |

### Native instead of ported

- **Sheets and windows.** A dialog is a sheet on the document window (`beginSheet`, non-blocking, so a
  control-channel command that opens one answers at once); Settings, About and the template gallery are
  windows of their own. A sheet carries its title as a headline, since sheets have no title bar.
- **File panels.** `NSOpenPanel`/`NSSavePanel` as sheets, with deckcraft's file types per purpose. They answer
  asynchronously; a file goes to the presentation and slide that were current when the panel opened
  (`execute_on_target`, slides only; masters and layouts fall back to the current view).
- **Settings** is the app menu's Settings… window (⌘,), reading and writing `prefs.json` beside `ui.json`
  (`settings.rs`). The appearance setting is System / Light / Dark and sets `NSApp.appearance`.
- **Font** stays a sheet, not `NSFontPanel`: deckcraft's Font dialog applies family, size, bold, italic,
  underline, strike, baseline, caps, spacing and colour in one OK and one undo step, which the font panel's
  live changes can't. Its colour field and Theme Colors' swatches use the system colour panel.
- **The palette** is a floating panel (⇧⌘P) over the window; arrows, Return and Esc as in deckcraft.
- **Toasts** are a child panel at the bottom of the document window for eight seconds.
- **File backstage.** Home, New and Open → the start window (S1, see "Ribbon"); Save As, Print → the system's (NSDocument, the
  Views area's print); Info → Properties sheet; Export → the Export sheet; Account → About.
- **Menu items** the menu tree has no entry for (Hyperlink… ⌘K, Header and Footer…, Symbol…, Equation…,
  SmartArt…, Slides from Outline…, Reuse Slides…, Bullets and Numbering…, Columns…, Replace Fonts…, Custom
  Shows…, Spelling…, Accessibility Checker…, Language…, New from Template… ⌥⌘N) are added at launch by
  `DialogsMenuTarget`; File › Properties is retargeted to the Properties sheet (the engine's `file.properties`
  query has nothing to show on its own).

### Control channel

deckcraft's `ui.dialog.open {id, fields}` and `ui.dialog.close`, and `ui.inspect`'s `dialog` key, plus what
drives an open dialog without pixels: `ui.dialog.list` (ids, the open one), `ui.dialog.get` (id, title, params,
fields, buttons, actions, form), `ui.dialog.set {fields}`, `ui.dialog.press {button}` (a bottom button or an
in-form action id), and `ui.palette {query?, run?, open?}`. `ui.inspect` also gains `palette`.

### Tests

DCAppModelTests `DialogsTests` (48) and `DialogsFilesTests` (27), DCAppTests `DialogsWindowTests` (9): 84 in all.
Ported: dialogs.rs (hyperlink ×5, zoom, trim ×2, alt text, header/footer date format, export GIF, export PNG
transparent), columns_dialog_tests (5 of 6), paragraph_dialog_tests (2), font_dialog_tests (2),
size_position_tests (2), replacefonts_tests (1), photo_album_tests (4), datetime_tests (2), find_dialog_tests
(1, as find/replace behaviour), preferences_tests (4, folded into 3), reuse_picker_tests (5), inbox_tests (2),
browsetheme_tests (1), compare_tests (the picker half), backstage_tests (page ids, new template/blank, info
properties, account), settings.rs (3), toast.rs (1), lib.rs missing-fonts toast.

Not applicable: egui mechanics — `about_credits_tests` (tab row layout), `columns_dialog_tests`
format_shape_columns_button (the Inspector's button), replacefonts/compare `screenshot` (review images), the
backstage keyboard side-menu tests (Alt+F, arrows: no side menu on the Mac), the start-screen tests (ported in
S1, "Ribbon" › "S1: the start window"), backstage Print tests (the Views area's printing),
`opening.rs` (NSDocument opens files; deckcraft's progress window is not ported), `uifonts.rs` (AppKit's font
fallback draws every script), `theme_colors_tests`/`theme_fonts_tests` and `spelling_tests` (the Inspector's
and the Canvas's lists).

### Divergences and open items

- About has no Contributors or Models tab (deckcraft generates them from `contributors.json` at build time).
- `app.checkUpdates` is not answered here (no update channel before Wave 6).
- The Spelling dialog's note names the system spelling checker instead of Hunspell folders.
- `uiScale` (the interface size slider) isn't offered: AppKit text follows the system's size settings. Cancel
  still restores it.
- Reuse Slides honours both its own `slide<i>` checkboxes and deckcraft's `off<i>` fields.

## Canvas (selection, handles, drags, text editing in place, keys, zoom, rulers, guides, menus, spelling, Eyedropper, drops)

The editing canvas: the current slide (or master, layout, handout or notes master) drawn by DCRender in a
native scroll view, the engine's pointer tools (`Session.pointer`), in-place text editing through
`NSTextInputClient`, the keys the canvas owns, zoom and page turns, rulers with draggable indents and tabs,
grid and guides, the context menu, spelling squiggles, the Eyedropper and file drops.

### File map

| deckcraft (`crates/ui-egui/src`) | Swift | Notes |
|---|---|---|
| `canvas.rs` `Xf`, `layout`, `page_flick`, `wheel_slide_target`, `grid_line_step`, `grid_fits`, `ruler_steps`, `resize_cursor`, the cursor match in `pointer` | `DCAppModel/CanvasGeometry.swift` | `CanvasXf`, `CanvasLayout` (with `anchoredScroll`, #106), `CanvasMetrics`, `CanvasHandles` (the engine's `Tools.boxHandles` / `wordartHandles`), `CanvasCursor` |
| `canvas.rs` `ime_area`, `text_marks`; `lib.rs` `keyboard`'s Text arm, `ime_event`, `apply_ime_event` | `DCAppModel/CanvasTextInput.swift` | `CanvasTextDocument` (the edited text as UTF-16), `CanvasTextInput` (marked text, commits, replacement ranges, first rect, character index) |
| `lib.rs` `keyboard` (keys → `Session.key`), `canvas.rs` `pointer`, `trackpad_twist` | `DCAppModel/CanvasInput.swift` | `AppModel.input` / `AppModel.key` (run input, drain requests, refresh), `CanvasInput.pointer` (→ `Session.pointer`), `twist` |
| `canvas.rs` `context_menu` | `DCAppModel/CanvasContextMenu.swift` | the menu as data (`CanvasMenuEntry`) and what each item does |
| `squiggles.rs` | `DCAppModel/CanvasSquiggles.swift` | checker, cache, underlines, `word_at`, `menu_word`, notes ranges, `LANGS` |
| `eyedropper.rs` (state, pick); `lib.rs` `infer_command`, `is_presentation_name`, `key_name` | `DCAppModel/CanvasTools.swift` | `CanvasEyedropper`, `CanvasDrop`, `CanvasKeys` |
| `canvas.rs` `show` (drawing, zoom, scrolling, pointer routing), `eyedropper.rs` `canvas` | `DCApp/Canvas/CanvasView.swift` | the scroll view's document view; `CanvasScrollView` |
| `canvas.rs` `overlays`, `draw_grid`, `draw_guides`, `draw_preview`, `rotate_handle`; `squiggles.rs` `paint`; `eyedropper.rs` `loupe` | `DCApp/Canvas/CanvasOverlayView.swift` | its own layer: a selection change never redraws the slide |
| `canvas.rs` `ruler`, `ruler_markers`, `tab_glyph` | `DCApp/Canvas/CanvasRulerView.swift` | |
| `canvas.rs` `context_menu` (the widgets) | `DCApp/Canvas/CanvasMenu.swift` | `NSMenu` from `CanvasContextMenu` |
| `lib.rs` IME plumbing (`observe_ime`, reset fences…) | `DCApp/Canvas/CanvasTextClient.swift` | `NSTextInputClient`, `doCommand(by:)`, `NSServicesMenuRequestor` |
| `canvas.rs` (the canvas rect, the rulers' strips) | `DCApp/Canvas/CanvasViewController.swift` | scroll view, rulers, the Show area's overlay slot |
| `widgets.rs` handle colours (`Tokens`) | `DCApp/Canvas/CanvasStyle.swift` | system semantic colours; deckcraft's handle geometry |
| `control.rs` `inspect` (canvas keys) | `DCApp/Canvas/CanvasFeature.swift` | `canvasRect`, `slideRect`, `canvas`; `ui.canvas.menu`, `ui.eyedropper`; hooks for other areas |

### Drawing

Measured on the sample deck (debug build): recording a slide (`recordSlide`) costs about what rasterising it
does (10–130 ms) and replaying the recording into CoreGraphics about 1 ms, so the canvas records each slide
once (scale-free) and replays it in `draw(_:)` at any zoom and scroll — vector-sharp at 400 %, and AppKit tiles
the large document view itself. A recording that needs raster layers (`DisplayList.hasRaster`: a blur, a
blend onto the backdrop — one sample slide took 4.7 s to replay in debug) is rasterised once per zoom
instead, over the slide's whole extent (off-slide objects too), within `maxRenderSide`; so are masters,
layouts and the handout and notes master (DCRender records slides only). The picture is keyed by the document's
identity (`DocRef`), target, slide and the text being edited, so selection changes, hovers and caret moves
redraw only the overlay layer, and an unchanged slide is never drawn again (`pictureCount`, tested). View ›
Grayscale is a `.saturation` blend over the slide. The Notes Master shows the current slide in its
slide-image placeholder and the Handout Master its slide boxes (`PDF.handoutBoxes`), as deckcraft does.

### Native instead of ported

- **Scrolling** is an `NSScrollView` (native scroll bars, elastic and momentum scrolling, content under the
  toolbar): deckcraft's own scroll bars and their tests (`scroll_bars_pan_a_zoomed_slide`,
  `a_short_press_on_the_thumb_does_not_page`, `only_the_primary_button_drags_a_thumb`) are AppKit's. The layout
  (`CanvasLayout`) keeps deckcraft's 28-point margin and centring, and zoom anchoring keeps the point under the
  pointer (pinch, ⌘/⌃-scroll) or the middle of the view (Zoom In/Out, the slider) still.
- **Gestures**: `magnify(with:)` zooms about the pointer, `smartMagnify(with:)` toggles fit and 100 %,
  `rotate(with:)` is deckcraft's trackpad twist (one `shape.rotate` gesture, one undo step).
- **Text input** is `NSTextInputClient`: input methods' marked text (`setMarkedText` → `text.compose` with the
  active clause; `insertText` → `text.commit`, one undo step), dictation, the accent menu and reconversion
  (replacement ranges select first), the candidate window at the insertion point (`firstRect`), and the
  Services menu (`NSServicesMenuRequestor`). When the app settles a composition itself (a click, a key, a
  command) the engine ends it and the input context follows. The egui IME machinery (reset fences, descriptor
  owners, tombstones for stale events, viewport routing) has no counterpart: the input context keeps that
  state for the client.
- **The caret** is the system's `NSTextInsertionIndicator` (blinking, dictation's glyph), in the colour of the
  text typed there; a caret on rotated text, which it can't draw, is drawn by the overlay.
- **Spelling marks** use the system's dotted red underline instead of deckcraft's wave.
- **Cursors** are AppKit's (`frameResize(position:directions:)` for the four resize axes, column and row
  resize, I-beam, crosshair, copy for an armed painter); the rotate handle shows a crosshair (no system rotate
  cursor).
- **Control-click** is the Mac's right click (not multi-select); ⌃ alone in text keeps the system's text key
  bindings (⌃A, ⌃E…, through `doCommand(by:)` to the engine's keys). Otherwise ⌘ and ⌃ are deckcraft's `cmd`.
- **First mouse**: a click on the canvas of a background window acts at once, as in drawing apps.

### Keys

`keyDown` sends what the canvas owns to `Session.key` with deckcraft's `Mods`: arrows (nudge 6 pt, ⌥ 1 pt; in
text the engine's Mac motions), Delete/Backspace, Tab/⇧Tab (cycle, indent, next cell), Escape, Enter/Return, Home,
End, Page Up/Down, F2. ⌘-keys that no menu item took go to the engine's registry shortcuts. Typed characters go
through `interpretKeyEvents` (so input methods see them). Menu key equivalents stay the menu bar's. The show's and
the animation preview's key interceptors (`AppController.keyInterceptors`) get named keys first.

### Hooks for other areas

- `CanvasFeature.eyedropper { hex in … }`: the Inspector's colour menus start the Eyedropper; the next click on
  the slide hands them `RRGGBB` (deckcraft's menu round trip, as a callback). `CanvasFeature.setTransparentColor()`
  is Picture Format › Color › Set Transparent Color. Esc, a right click or a click off the canvas cancels.
- `CanvasFeature.previewOverlay(in: window)` → `(view, slideRect, scale)`: a pass-through view over the canvas
  for the Show area's animation preview; `canvasLayoutChanged` is posted when the slide moves. The skeleton's
  `CanvasView.slideFrame()` is kept (the Show area's child-window preview uses it).
- Control channel: `ui.inspect` gains `canvasRect`, `slideRect` (window content coordinates, y down) and
  `canvas` (scale, fit, scroll, eyedropper, editingText, firstResponder, composing). `ui.canvas.menu` lists the
  context menu a right click opened and `{choose: title}` runs an item; `ui.eyedropper {transparent?, cancel?}`.
  A right click the control channel sends (event number 0) builds the menu without popping it up: menu
  tracking would hold the main thread and the channel with it.

### Tests

DCAppModelTests `CanvasModelTests` (19), `CanvasTextInputTests` (11), `CanvasSquigglesTests` (6); DCAppTests
`CanvasViewTests` (10, a canvas in a window made in-process) and `CanvasPointerTests` (8, real `mouseDown` /
`mouseDragged` / `mouseUp` into `Session.pointer`).

Ported (behaviour): canvas.rs `resize_cursor_tracks_rotation`, `a_wide_shape_keeps_its_corner_cursors_diagonal`,
`a_placeholder_that_inherits_its_box_has_a_resize_cursor`, `wheel_and_pinch_zoom_keep_the_point_under_the_pointer`,
`zoom_commands_keep_the_middle_of_the_view`, `a_fitted_slide_has_no_scroll_bars`, `double_click_in_a_table_cell_shows_the_caret_there`,
`table_borders_resize_with_the_pointer`, `edit_points_menu_sets_segment_types_and_opens_the_path`,
`edit_points_segment_menu_adds_points_and_deletes_segments` (the right click's hit is the engine's, tested there),
`grid_step_follows_spacing_and_rejects_unusable_values`, `format_painter_sets_the_cursor`,
`animation_painter_sets_the_cursor`; lib.rs `off_slide_objects_show_on_the_pasteboard_and_can_be_selected_and_moved`,
`the_canvas_renders_only_the_slide_when_nothing_is_off_it`, `page_flick_uses_the_stronger_axis`,
`mouse_wheel_keeps_fast_notches_in_both_directions_without_a_smoothed_tail`,
`mouse_wheel_fractional_lines_accumulate_into_one_slide_per_line`, `mouse_wheel_fraction_does_not_carry_into_another_presentation`,
`ctrl_word_keys_edit_text` (the Mac's ⌥ words), `typing_goes_on_after_tab_in_a_text_box`; ime_tests.rs
`korean_composes_in_a_slide_text_box`, `japanese_conversion_shows_the_active_part`,
`composing_on_a_selected_shape_starts_editing_it`, `no_op_commit_stays_other_and_empty_text_is_available`,
`empty_commit_does_not_poison_a_commit_in_the_same_frame`, `ime_output_is_logical_bounded_and_owner_stable` (the
selection the text system reads); eyedropper_tests.rs (a click takes the colour and nothing else happens, Esc and
a click off the slide cancel); spelling_tests.rs `squiggles_mark_misspelt_words_in_the_background`,
`squiggles_in_table_cells_and_notes_and_on_the_ui_thread`; drawtable_tests.rs `draw_a_table_split_it_and_erase_the_border`;
ruler_tests.rs `drag_indents_add_move_and_remove_tabs_on_the_ruler`, `the_tab_selector_picks_the_kind_of_stop_a_click_sets`;
units_tests.rs `the_ruler_counts_centimetres_in_halves_and_inches_in_quarters`. Plus the UTF-16 document,
replacement ranges, `unmarkText`, Services, keys through `keyDown`, grayscale, the context menu by state,
drops, rulers' strips and the empty presentation's first-slide click.

Not applicable: canvas.rs's three scroll-bar tests (NSScrollView's), `empty_bullet_preview_follows_click_type_enter_and_toggle`'s
texture counter (the engine's `emptyBullets` it checks are DCEngine's); ime_tests.rs' egui IME plumbing
(`settled_composition_drops_queued_preedit_…`, `stale_commit_in_the_settling_batch_…`, the discarded-pass,
descriptor, reset-fence, viewport, owner-generation and pending-terminal tests: AppKit's input context
owns that state), `korean_composes_in_the_notes_pane` (the Views area's notes field, an `NSTextView`),
`cjk_text_in_the_interface_is_drawn_with_real_glyphs` (AppKit's font fallback); `field_frame_tests.rs` (egui's
text-field frames); `align_tests.rs` (the Inspector's Align menu); units_tests.rs' pane and dialog tests
(Inspector, Dialogs); `tabs_dialog_sets_clears_and_applies_on_ok` (Dialogs); spelling_tests.rs
`spelling_dialog_changes_and_ignores_words` and `notes_menu_language_dialog_and_repeated_words` (Dialogs, Views;
Delete Repeated Word is tested on the slide).

### Divergences and open items

- Squiggles are checked on the main thread a few milliseconds per pass (deckcraft's web path): the session and
  `NSSpellChecker` are the main thread's. The canvas asks for another pass while the check is busy.
- The media bar and GIF play buttons over the canvas (`media_bar`, `gif_buttons`, `media_frames`) are not drawn
  here: editor playback is DCApp/Show's (media.rs); they can join the overlay slot.
- No setting turns squiggles off (deckcraft's `disabled` follows one); `CanvasSquiggles.disabled` is there.
- Drops insert by path (the engine reads the file) at the engine's default place; an outline drop reads `.rtf`
  through `NSAttributedString`.
- The control channel's `ui.key` and `ui.text` call the session without `AppModel.changed()`, so the window
  redraws only at the next change (Automation's; `AppModel.input` / `AppModel.key` do both).

## Show (slide show, presenter view, Reading View, animation preview, media)

Alpha-gate workflow 3, "Present". Window-free logic in DCAppModel (`Show*.swift`), windows and Metal in
`DCApp/Show/`.

| deckcraft | Swift |
|---|---|
| `show.rs` `Show` (state, clocks, `apply`, `after_enter`, `cue_media`, `queue_clock_actions`, `advance_hidden`, keys, zoom, grid, goto, notes size, `showing_value`, `input_state`, `shapes_under_pointer`, `click_slide`), `PresenterTimer`, `Zoom`, `state_for`, `below_playing_video`, `hidden_on_entry`, `show_fills_screen` | `DCAppModel/ShowController.swift` |
| `show.rs` layout helpers (`fit`, `next_rect`, `zoom_uv`, `norm_on_slide`, `slide_to_screen`, `slide_box`, `see_all_cells`, `see_all_hit`, `tool_bar_rect`, `media_bar_rect`, `slide_media_bars`); `media.rs` `crop_uv`, `gif_button_rect`, `control_bar`'s layout | `DCAppModel/ShowGeometry.swift` |
| `show.rs` `render_frame`, `render_backdrop`, `over`, `render_overlay`, `start_prefetch`, `Backdrop`; `textures.rs` `fit_size` | `DCAppModel/ShowRender.swift` |
| `lib.rs` `start_show`, `start_custom_show`, `show_from`, `show_start_index`, `show.*`/`view.reading`/`animation.preview` arms of `run_ui`, `drain_requests` (startShow, media), `tick_media_clock`, the animation preview (`AnimPreview`, `tick_anim_preview`, `start_anim_preview`, `preview::shape_state_at`); `show.rs` `show_media`, `run_media_cues`, the input half of `ui` (clicks, media bar, GIF button, links, grid, zoom, wheel, `page_flick`) | `DCAppModel/ShowCoordinator.swift` |
| `media.rs` `MediaHost`, `Owner`, `Gif`, `find_clip`, `clip_on`, `carries_over`, `slide_media`, `clock`, `gif_key` | `DCAppModel/ShowMedia.swift` (`MediaHost`, `MediaOwner`, `ShowGif`) |
| `notes.rs` `bullets` and `format` as `presenter_notes` uses them | `DCAppModel/ShowNotes.swift` |
| — (gap #9) | `DCAppModel/ShowDisplays.swift`: which display plays the show and where presenter view goes |
| `show.rs` drawing half of `ui`, `quad_mesh`, `part_textures`, `render_thumb`; `media.rs` `paint_frame` | `DCApp/Show/ShowStage.swift`, `ShowMetal.swift` |
| `show.rs` overlay painting, toolbar, reading bar, `paint_grid`; `media.rs` `control_bar`, `paint_gif_button` | `DCApp/Show/ShowView.swift` |
| `show.rs` `presenter_window`, `presenter_notes` | `DCApp/Show/PresenterView.swift` |
| the egui viewports (fullscreen command, presenter viewport) | `DCApp/Show/ShowWindows.swift` |
| `lib.rs` canvas animation preview drawing | `DCApp/Show/AnimPreviewOverlay.swift` |
| `control.rs` `show.start`, `show.end`, `ui.key` while showing, `showing`/`animPreview` in `ui.inspect` | `DCApp/Show/ShowFeature.swift` |
| `apps/deckcraft/src/audio.rs` (cpal) | DCMedia's `AudioEngineOutput` |
| `apps/deckcraft/src/display.rs` (X11/Wayland), `graphics.rs` (Direct3D) | not applicable on the Mac |
| `textures.rs` (egui texture cache) | Metal textures in `ShowStage`; the canvas's part is the Canvas area's |

### How it draws

- **Render once, composite in Metal** (PLAN.md §5.1). DCRender renders the slide at the step on screen into a
  `RenderImage`, uploaded once into an `MTLTexture` (`ShowController.frame`, keyed as deckcraft keys it: slide,
  step, pixel size, document identity, hidden media, trigger plays, GIF frame). A transition is DCAnim's
  `transitionFrame` layers drawn as `layerMesh` triangles with per-vertex opacity, premultiplied source-over on
  black, with DCRender's CPU `compositeTransition` coverage, sampling and arithmetic (the exact pipeline, below). The slide parts
  (`usesSlideParts`) are rendered once per transition. Morph frames are DCRender's `renderBlend`, every frame,
  as deckcraft does. Animation frames re-render only the slide's shapes over the kept backdrop, as deckcraft
  does; the next slide's first frame and the backdrop are rendered ahead on another thread.
- **Display refresh.** `NSView.displayLink` drives the show; a static frame is a cheap redraw of the cached
  texture. A 100 ms timer keeps the show's clock moving when the display link stops (an occluded window),
  replacing deckcraft's hidden-logic pass (`hiddenLogicTime` is ported and tested, but the Mac's monotonic clock
  makes it unnecessary in the app).
- **The shaders** are compiled from source at first use (`ShowMetal.source`), so the package needs no Metal
  resource step.
- **Overlays** (ink, laser, See All Slides, GIF buttons, media bars, the "can't play" badge, labels) are Core
  Graphics in a view above the `MTKView`; the toolbar and Reading View's bar are SwiftUI with DesignScaffold
  tokens; presenter view is SwiftUI (dark appearance) with the tokens.

### Parity of the Metal compositor (`ShowMetalTests`)

Transition layers go through an exact pipeline (`ShowExact` in `ShowMetal.swift`): each triangle is drawn as its
bounding box and the fragment shader decides coverage as DCRender's CPU compositor does — edge functions of the
vertices in fixed point (1/16384 px) evaluated exactly in 64-bit integers at the pixel centre, with the CPU's
nudge (+1.17e-6, +2.31e-6) breaking a tie — then takes the CPU's barycentric texture coordinate and opacity and
its own bilinear sampling. The GPU's rasteriser alone (vertices on its sub-pixel grid, top-left rule) put
one-pixel lines of black or of the wrong slide along tile edges that pass through rows, columns or diagonals of
pixel centres (Checkerboard, Glitter, Shred, Crush's 45° folds), which SSIMULACRA2 punishes hard (63.7 on a
Checkerboard frame). Moving vertices to steer the rasteriser fixed some frames and broke others (Crush's fans,
Clock's wedges), so coverage is computed rather than steered.

Measured 2026-10-27 in release (`ShowMetalTests`, every frame scored):

| Deck | Frames | SSIMULACRA2 to the CPU compositor (min / mean) | to deckcraft (min / mean) | pixels > 8 levels from the CPU, at most |
|---|---:|---|---|---:|
| transitions (640 px) | 106 | 91.1 / 99.6 | 89.0 / 92.5 | 0.002 % |
| sample (scale 2) | 21 | 95.9 / 99.0 | 90.2 / 91.8 | 0 |
| content | 9 | 96.8 / 99.2 | 90.6 / 93.8 | 0 |
| motion | 9 | 96.7 / 99.1 | 91.1 / 94.7 | 0 |

Against deckcraft the Metal frames score as the CPU path's do (its transitions-deck minimum is also 89.0). Floors:
88 to the CPU compositor; 87 (transitions deck) and 88 (corpus) to deckcraft. Morph frames are DCRender's
`renderBlend` in both paths, so they are not compared here. The full run is release-only, or
`DECKCRAFT_PARITY=1` in debug, as the render parity suites are:

```bash
swift test -c release -Xswiftc -enable-testing --filter ShowMetalTests --scratch-path .build-parity
```

The default (debug) run has `quickMetalTransitionMatchesTheCPU`: push, fade, cube and pan at 160 × 90 against the
CPU compositor, and the shaders compiling. The report is `.build-parity/show-parity/report-<deck>.json`.

### Native instead of ported

- **Displays** (deckcraft's gap #9): the show opens on the chosen `NSScreen` — automatically the first display
  that isn't the main one, or the one named by `show.display {display}` (stored in user defaults as
  `DeckCraftShowDisplay`: a display name, `automatic` or `primary`) — and presenter view goes to the main
  display (another one when the show is on the main). With one display the show plays alone, as in
  PowerPoint. The full-screen show is a borderless window over the display's frame above the menu bar, hiding
  the Dock and menu bar when it is on the menu-bar display.
- **Reading View and "Browsed by an individual"** play in a titled window (deckcraft: in the editor's viewport).
- **The cursor**: a crosshair for the pen, armed zoom and the grid; an invisible cursor for the laser and an idle
  pointer (2.5 s); a pointing hand over a link or a triggered shape (`ShowCoordinator.cursor`).
- **Keys** reach the show before any control in its windows (`ShowWindow.sendEvent`), so Space never also presses
  a focused button (deckcraft consumes them the same way).
- **Media**: DCMedia's `Player` over `AudioEngineOutput`, with `VideoFeed` frames (VideoToolbox) uploaded as
  textures. A video whose codec can't be decoded (VP8/VP9 with no decoder registered) opens no feed: its sound
  plays, its box shows "This video can't be played on this Mac", and `Session.mediaStatus` carries that error.
- **The canvas animation preview** draws in a borderless child window laid over the canvas's slide
  (`CanvasView.slideFrame()`), because the Canvas area has no overlay hook yet; Esc stops it.

### Control channel

`show.start {from?, custom?, reading?, preview?, rehearse?, windowed?}`, `show.end` (ends at once; deckcraft
queues an Escape), `show.key {key}`, `show.state`, `show.next`, `show.previous`, `show.goto {index}`,
`show.display {display?}`, `ui.key` to the show first while it runs (Esc stops the canvas preview), `showing` and
`animPreview` in `ui.inspect`, and `ui.screenshot` of the show window while a show runs (Metal frame plus
overlay; `{"window": "presenter"}` for presenter view), the document window otherwise.
`DECKCRAFT_SHOW_WINDOWED=1` (or `windowed: true`) plays the show in a window, with presenter view in a second
window even on one display: the test mode.

### Tests

- **show.rs (27): all ported** in `DCAppModelTests/ShowTests.swift` and `ShowMediaTests.swift` at the level of
  `ShowController`/`ShowCoordinator`: the egui harness's key presses, clicks and wheel events become calls to
  `key`, `click` and `scroll`; `wheel_zoom_reads_only_the_wheel_with_ctrl_or_cmd` (egui's raw events) is folded
  into `ctrlWheelZoomsTheShowAndThePlainWheelTurnsThePage` and `pageFlick`, since the view reads ⌘/Ctrl from the
  `NSEvent`; `presenter_notes_keep_bullets_numbers_and_bold` checks the markers and run formats `ShowNotes`
  gives SwiftUI; `a_still_cursor_hides_over_a_clickable_shape` checks `ShowCoordinator.cursor`.
- **media.rs (7): all ported** (`ShowMediaTests`); the VP8 WebM test reads deckcraft's fixture and skips without
  it.
- **textures.rs**: `render_sizes_and_pictures_shrink_to_the_limit_keeping_their_shape` → `fitSize`; the other two
  are the canvas's (`device_pixel_rect`, `fit_texture`). **texture_limit_tests.rs (3)**: the portrait Next
  preview → `nextRect`; the big screen and the tall slide → `fitSize` (Metal textures are capped at 16,000 px
  per side, as DCRender's renders are).
- **New**: the show commands and their validation, custom shows and Play from Start, rehearsed timings, keys by
  name, tool keys, display choice, the canvas preview, auto-play and transition sounds, editor media requests;
  in DCAppTests the Metal parity above, the stage's letterboxed frame, and a windowed show with presenter view
  driven by key events through to Escape.
- **Not applicable**: `display.rs` (2) and `graphics.rs` (4) test Linux and Windows start-up; `audio.rs` (2) tests
  cpal's error slot (DCMedia's `AudioEngineOutput` has its own tests).

### Divergences and open items

- deckcraft's ribbon starts Rehearse Timings and the Transitions tab's Preview; with no ribbon these are
  `show.start {rehearse: true}` and `{preview: true}` (and `ShowCoordinator.startShow(..., preview:, rehearse:)`
  for the inspector or a menu to call).
- Opening a `.ppsx` from Finder should start its show (`open_from_system`); that is the app delegate's (a shared
  file), not done yet.
- The canvas doesn't draw video frames of the editor's media yet: `ShowFeature.coordinator?.media.frame(id)`
  gives the Canvas area the current frame. Editor media plays (audio) and reports `Session.mediaStatus`.
- Presenter view's current-slide picture follows the show's frames between steps; during an animation it shows
  the frame the step started from.
- Set Up Show's monitor has no field in the model (`ShowSettings`): the choice is the app's user default, not saved
  in the presentation.

## Views (navigator, Slide Sorter, Outline, Notes Page, notes pane, status bar, New Window, printing, pasteboard)

The window's composition is this area's (`DocumentWindowController.swift`): the sidebar shows the navigator or
the outline, the editing area shows the canvas over the notes pane (Normal and Outline), the Slide Sorter or
Notes Page, over the status bar; the inspector stays last in the split view (the Inspector area reads it).
Slide Sorter, Notes Page and the Handout and Notes Master views collapse the sidebar and give it back after;
the editing area sits under the toolbar's safe area.

| deckcraft | Swift |
|---|---|
| `thumbs.rs` (`show`, `list`, `slide_menu`, `master_list`) | `DCApp/Views/NavigatorView.swift` (`NavigatorViewController`, `NavigatorTable`, `SlideThumbCell`, `SectionBarCell`, `SlideMenus`); rows and clicks in `DCAppModel/ViewsLogic.swift` (`NavigatorLogic`) |
| `textures.rs` `thumb` (cache, `thumb_count`, `thumb_renders`) | `DCAppModel/ViewsLogic.swift` (`ThumbCache`), `DCApp/Views/ViewsSupport.swift` (`Thumbnails`) |
| `sorter.rs` `show`, `section_header`, `place_slides`, `groups`, `drop_slot`, `move_dest`, `State` | `DCApp/Views/SorterView.swift`; `SorterLogic`, `FoldKey` in `ViewsLogic.swift`; `SectionFolds` (shared with the navigator) |
| `sorter.rs` `outline_pane`, `outline_slide`, `outline_estimate` | `DCApp/Views/OutlineView.swift`; `OutlineLogic` |
| `sorter.rs` `notes_page`; `status.rs` `notes_pane`; `notes.rs` | `DCApp/Views/NotesView.swift` (`NotesText`, `NotesTextView`, `NotesEditor`, `NotesPaneController`, `NotesPageViewController`); `DCAppModel/ViewsNotes.swift` (`NotesDraft`, `NotesLogic`: `typed`, `px`, `indents`, `bullets`) |
| `status.rs` `status_bar`; `dialogs.rs` `selected_language` | `DCApp/Views/StatusBar.swift` (SwiftUI); `StatusLogic` |
| `doc_window.rs` | `DCApp/Views/DocViewerWindow.swift`; `DocWindowLogic`; `ViewsFeature.newWindow` |
| `lib.rs` `print_pdf` (and the gap list's #6) | `DCApp/Views/Printing.swift` (`Printer`, `PrintPagesView`, `PrintAccessory`); `DCAppModel/ViewsShare.swift` (`PrintSettings`, `PrintLayout`, `PrintLogic`) |
| `apps/deckcraft/src/pasteboard.rs`; `lib.rs` `OBJECTS_MARKER`, `system_clipboard_text`, `publish_clipboard`, the paste arms of `keyboard`, `color_image_png` | `DCApp/Views/Pasteboard.swift` (`PasteboardBridge`); `PasteboardLogic` in `ViewsShare.swift` |
| `lib.rs` `ui_inner`'s layout | `DCApp/DocumentWindowController.swift` (`SidebarController`, `EditorAreaController`) |

**Commands.** `ViewsFeature.install` registers `view.newWindow` and `app.print` (`app.handle`), the Edit menu's
Cut, Copy, Paste, Paste and Match Formatting and Select All (`app.handleMenu`, added to `AppController`: the menu bar's
and toolbar's way to run a command, checked in `perform` before `model.run`; scripts still run the engine's command), and the
`ui.inspect` keys `thumbsScroll`, `docWindow` and `views` (what the key window's views show: area, sidebar,
navigator rows, the notes). The views run engine commands only: `slide.go`, `slide.selectRange`,
`slide.selectSlides`, `slide.move`, `slide.hide`, `slide.new`/`duplicate`/`delete`/`layout`/`reset`, `section.*`,
`slide.notes {body, index}`, `text.set`, `view.slideMaster`, `edit.*`, `insert.picture`.

**Master views.** `view.slideMaster`, `view.handoutMaster`, `view.notesMaster` and `view.closeMaster` are not UI
commands: they are the engine's (deckcraft `crates/engine/src/cmd/design.rs`, ported in DCEngine's
`CmdDesign.swift`), which is why `UI_COMMANDS` doesn't list them. They set `Selection.target`. The navigator
follows the target: masters and their layouts in Slide Master view (a click runs `view.slideMaster {master,
layout?}`), nothing in Handout and Notes Master views (the sidebar collapses), as `thumbs.rs` does. The status
bar names the master view. Drawing and editing the master itself is the canvas's.

**Native instead of ported.**
- NSTableView (navigator, outline) and NSCollectionView (sorter) lay out only the rows in view, where egui needed
  `near`-checks and height estimates; the outline still keeps each slide's measured height (estimated until
  shown), as deckcraft does.
- Thumbnails are drawn on background tasks from a snapshot of the presentation (a value), three at a time, newest
  request first, and cached per document and per view (navigator, sorter, notes page) by slide and master value
  instead of `Arc` address.
- Notes are NSTextViews (TextKit 1, so the bullets are drawn from the layout manager): spelling is the text view's
  continuous checking with its own suggestion menu, replacing deckcraft's notes squiggles; Undo while typing is
  the engine's (the menu's).
- Section rename is in place (the bar's field) in the navigator and the sorter, instead of the `renameSection`
  dialog.
- Printing is NSPrintOperation (deckcraft wrote a PDF and opened it in a viewer). The pages are DCRender's PDF
  export laid out on the printer's paper (vectors: each slide the renderer's recorded drawing), drawn page by
  page into the print context; the outline is laid out by the app. `{path}` writes the same pages to a PDF
  without a printer or panel. Grayscale is a saturation blend over each page, so vectors stay vectors.
- The pasteboard is NSPasteboard (deckcraft used arboard). Pasting a PDF picture rasterises it at twice its size;
  an image file copied in Finder pastes as that picture.

**Divergences.**
- The status bar's slider sizes the thumbnails in Slide Sorter view (as PowerPoint's does); elsewhere it zooms
  the canvas. ⌘-scroll and pinch also zoom the sorter. The status bar gains a spelling mark for the current slide
  (a click opens the Spelling dialog) and a Notes/Comments/views/zoom row in SF Symbols.
- Copied shapes also go on the pasteboard as a PDF (vector) and a PNG for other apps, next to deckcraft's objects
  marker text; Paste still uses the session's clipboard while the pasteboard holds DeckCraft's own copy (its
  change count is unchanged).
- The Edit menu's Cut, Copy, Paste, Paste and Match Formatting and Select All go to a text field or text view that
  has the keyboard (the notes, the outline, an inspector field) instead of the slide; with the navigator or the
  sorter focused they act on slides (`scope: slides`), as deckcraft's `slides_list_focused` does for ⌘A.
- New Window is one viewer window at a time, as deckcraft's; it follows its presentation and closes with it.
- Clicking an empty area under the navigator doesn't add a slide (deckcraft's "+ New Slide" prompt): Return in the
  navigator, the slide menu and Insert › New Slide do.
- Print adds the Outline layout and a Color/Grayscale choice to deckcraft's print options.

**Tests.** `DCAppModelTests/ViewsModelTests.swift` (23) and `DCAppTests/ViewsWindowTests.swift` (23, views
in-process windows):
- `sorter_tests.rs`: all 7 (`drop_slot_and_move_dest`, `add_section_splits_at_the_current_slide`,
  `collapse_hides_that_sections_slides_and_expand_brings_them_back` (model and sorter),
  `double_click_renames_and_switching_documents_drops_the_draft`, `dragging_a_section_moves_it_and_keeps_it_collapsed`
  (and the sorter's drop slots), `ctrl_a_selects_every_slide`, `shift_and_ctrl_shift_clicks_select_ranges`).
- `huge_deck_tests.rs`: all 5, the two "settled" tests folded into the pane and sorter tests (thumbnails held and
  drawn stay within a screenful and stop after settling; the outline of 2,000 slides lays out under 200 rows and
  shows the current slide).
- `thumbs.rs`: `navigating_slides_keeps_the_current_thumbnail_visible`. `doc_window.rs`: both, plus `command`.
- `notes.rs`: `bullets_follow_the_paragraphs`, `typing_keeps_the_formatting_around_it`, and
  `notes_show_bold_runs_indents_and_wrap_under_the_text` as the indents and the editor's attributes (the wrapping is
  TextKit's).
- `status.rs`: the notes pane's save-to-its-slide; the status texts, the language and the zoom slider's range
  (`status_bar_controls_have_names`' values). Not applicable: `a_long_language_name_leaves_the_notes_button_clickable`
  checks egui hit-testing past a painted label (SwiftUI lays the controls out side by side); the accesskit role
  checks of `status_bar_controls_have_names` (the SwiftUI controls carry `accessibilityLabel`s).
- `pasteboard.rs`: `html_and_a_picture_round_trip_on_macos` as pastes of HTML and of a TIFF from another app, on a
  private NSPasteboard. `lib.rs`: `copy_and_cut_commands_reach_the_system_clipboard`,
  `a_textless_shape_copies_as_the_objects_marker`, `ctrl_v_with_only_an_image_inserts_a_picture` (#53), the image
  bounds of `color_image_png`.
- `ui_soak_tests.rs`: a seeded soak over the Views area (400 actions: view switches, clicks with ⇧/⌘, slides and
  sections, folds, notes, undo), checking every view lists the presentation as it is. The frame-time and texture
  bounds are egui's.
- Printing (new): every layout to PDF (page counts, hidden slides, grayscale, outline), and the settings' mapping.

**Shared-file edits.** `AppController.swift`: `menuHandlers` / `handleMenu(_:_:)` and its check in `perform`.
`Package.swift`: DCAppModel depends on DCText (the notes' bullets: `mapSymbolBullet`, `autonum`).

**Open items.**
- Drags (navigator and sorter reorder, section drags) are exercised through their drop arithmetic and commands,
  not by synthesized mouse drags.
- The sorter's thumbnails don't animate a reorder; NSCollectionView reloads.
- Notes Page shows the notes master's header and footer text but not its other shapes.

## Inspector (task panes, the ribbon's formatting, the toolbar)

In the Mac layout (the default; the ribbon is an optional layout from R1, see "Ribbon") the ribbon's formatting
groups and deckcraft's task panes live in the inspector beside the canvas, its insert and show controls in the window toolbar, and the rest in menus and
dialogs (the table below places every group). The inspector has five tabs, Keynote-like, in a segmented control
with SF Symbols: **Format**, **Arrange**, **Animate**, **Slide** and **Review**. `ui.pane` (deckcraft's open
task pane) chooses the tab, so `view.pane`, a command's `UiRequest.pane`, `ui.set` and the control channel open
the right one; a click on a tab runs `view.pane` with that tab's pane. `view.pane {pane: null}` hides the
inspector, and any pane shows it again.

| `ui.pane` | Tab | Shows |
|---|---|---|
| `format` (or none) | Format | `ui.formatTab`: `fill` (Fill & Line, Shape Styles), `effects`, `size`, `text` (Font, Paragraph, Text Fill and Effects, Text Box), and for the selection `picture`, `table`, `chart`, `smartart`, `media` |
| `smartart` | Format ▸ SmartArt | the Text Pane, Create Graphic, Layouts, Styles |
| `selection` | Arrange | order, align and distribute (Align to Slide), group, rotate, flip, Edit Shape, Size, the Selection Pane |
| `animation` | Animate | Animations (effect, options, timing, trigger, painter) with the Animation Pane and its timeline; Transition |
| `background`, `designer` | Slide | master views, layout, Slide Show, themes, variants, colours, fonts, effects, Format Background, Design Ideas, Insert Zoom |
| `comments`, `thesaurus`, `revisions` | Review | Comments, Thesaurus, Revisions, Proofing |

Every control runs a registry command (deckcraft's ids and params) through `AppModel.run`, and every value it
shows is read back from the session after each command: the shape and its effective box (`Cmd.xfrmOf`), the
selection, `format.state`, the slide's transition and animations, the theme. Views read the session through
`InspectorController.session`, which reads `AppModel.revision`, so each command redraws them.

### File map

| deckcraft (`crates/ui-egui/src`) | Swift |
|---|---|
| `panes.rs` `show` (the pane frame and titles) | `DCApp/Inspector/InspectorView.swift` (tabs, Format's sub-tabs, Format Painter); `DCAppModel/InspectorController.swift` (`InspectorTab`, `contextual`, `formatTabs`) |
| `panes.rs` `format_shape`, `line_choice`, `line_details`, `fx_slider`, `pick_fill_picture`, `pic_drag`, `picture_fill_options`, `three_d_*`, `text_transparency_*`; pure helpers `solid_fill_transparency_percent`, `fill_transparency_to_apply`, `preset_label` | `DCApp/Inspector/InspectorFormatPane.swift`, `InspectorTextPane.swift`; `DCAppModel/InspectorFill.swift` |
| `panes.rs` `background`, `picture_background_options` | `InspectorSlidePane.swift` (`BackgroundSection`); `InspectorFill` (`backgroundKindParams`, `applyToAllParams`) |
| `panes.rs` `animation` | `InspectorAnimatePane.swift` (`AnimationPaneView`); `DCAppModel/InspectorAnimation.swift` (`AnimPane`) |
| `animtimeline.rs` | `DCAppModel/InspectorAnimation.swift` (`AnimTimeline`) |
| `panes.rs` `comments`, `comment_card`, `focus_comment`; `ribbon.rs` `comment_nav` | `InspectorReviewPane.swift`; `InspectorController` (comments) |
| `panes.rs` `revisions`, `thesaurus` | `InspectorReviewPane.swift`; `InspectorController` (`thesaurusSenses`, `pickSynonym`) |
| `panes.rs` `designer`, `IdeaThumbs` | `InspectorSlidePane.swift` (`DesignIdeasSection`, a per-revision thumbnail cache) |
| `panes.rs` `smartart` (Text Pane) | `InspectorObjectPanes.swift` (`SmartArtTextPane`); `InspectorController` (`setNode`, `smartArtEdit`) |
| `selpane.rs` | `DCAppModel/InspectorSelectionPane.swift` (`SelectionPane`: rows, state, `dropTarget`, `siblingBlocks`, `click`, `keyTarget`); `InspectorArrangePane.swift` (`SelectionPaneView`) |
| `fillui.rs` | `DCAppModel/InspectorFill.swift` (gradients, patterns); `InspectorFormatPane.swift` (`GradientEditor`, `StopBar`, `PatternEditor`) |
| `widgets.rs` (`color_grid`, `color_popup`, `color_split`, `spinner`, `fmt_num`, `text_draft`, `gallery`, `drop_button`, split buttons) | `DCApp/Inspector/InspectorControls.swift` (`ColorGrid`, `ColorButton`, `ColorSplitButton`, `NumberField`, `CommitSlider`, `TileGallery`, `PresetIcons`, `ShapesMenu`); `DCAppModel/InspectorColors.swift` (`themeGrid`, `standard`); `InspectorText.draft` |
| `theme.rs` | DesignScaffold's `Tokens` and the system's semantic colours (no port; see below) |
| `ribbon.rs` `cref_param`, `scheme` | `DCAppModel/InspectorColors.swift` (`param`, `scheme`) |
| `ribbon.rs` `contextual`, `enabled`, `fmt_state`, `align_menu`/`align_to_slide`, `outline_menu`, `effects_menu`, `quick_styles`, last colours | `DCAppModel/InspectorController.swift`; `InspectorShape.swift` |
| `ribbon.rs` `font_group`, `paragraph_group`, `font_families`, `transform_gallery`, `selected_warp` | `InspectorTextPane.swift`; `DCAppModel/InspectorText.swift` |
| `ribbon.rs` `design`, `paint_theme_tile`, `slide_master`, `notes_master`, `handout_master`, `master_checks` | `InspectorSlidePane.swift` (`ThemeTile` in `InspectorControls.swift`) |
| `ribbon.rs` `transitions`, `animations`, `marked_options`, `transition_effect_rows`, `animation_effect_rows`, `text_build_id`, `option_label` | `InspectorAnimatePane.swift`; `DCAppModel/InspectorAnimation.swift` (`InspectorMotion`) |
| `ribbon.rs` `shape_format`, `arrange_group`, `size_group`, `smooth_corners_row` | `InspectorFormatPane.swift`, `InspectorArrangePane.swift` (`EditShapeSection`); `InspectorShape.swift` |
| `ribbon.rs` `picture_format`, `compress_menu` | `InspectorFormatPane.swift` (`PictureView`) |
| `ribbon.rs` `table_design`, `table_layout`, `chart_design`, `smartart_design`, `smartart_gallery`, `playback`, `chart_menu_types` | `InspectorObjectPanes.swift`; `InspectorTextPane.swift` (`SmartArtLayoutMenu`) |
| `ribbon.rs` `insert`, `home`'s Slides and Drawing, `shapes_gallery`, `table_grid_picker`, `icon_library`, `photo_album_button`, `draw`, `slide_show`, `layout_menu`, `new_slide_menu`, `section_menu`, `zoom_menu` | `DCAppModel/CommandMenus.swift` (the split items' menus, as data; `ChartMenu`); `DCApp/Inspector/ToolbarCatalog.swift` (the toolbar items, and the menus as NSMenus); `InspectorSlidePane.swift` (`InsertZoomSection`, `SlideShowSection`) |
| `qat.rs` | `DCAppModel/InspectorQAT.swift` (`QatItem`, `QAT.command`, persistence); the toolbar's Quick Access item |
| `ribbon.rs` and `ribbon/*.rs` (every tab, group and control) | `DCAppModel/RibbonLayout.swift` (the ribbon as data, R0) |
| `ribbon.rs` (every group) | `DCAppModel/InspectorRibbonMap.swift` (the table below, derived from `RibbonLayout`, checked by tests) |
| — | `DCApp/Inspector/InspectorFeature.swift`: the shared `InspectorController`, `app.qat`, `ui.inspect`'s `inspector`, the inspector following `ui.pane` |

### UI commands and hooks

- **`app.qat`** (`app.handle`): `{add, params?, label?, icon?} | {remove, params?} | {reset}` → the buttons, as
  deckcraft. The buttons are kept in the app's defaults (`DeckCraftQuickAccessToolbar`; deckcraft keeps them in
  `ui.json`, a shared file).
- **`ui.inspect`** gains `inspector`: `tab`, `formatTab`, `contextual`, `lastFill`, `lastOutline`,
  `alignToSlide`, `qat`, `commentFocus`.
- Hooks used from other areas: `CanvasFeature.setTransparentColor()` (Set Transparent Color picks a pixel of
  the picture), `show.start {preview: true}` and `{rehearse: true}` (the Show area's). The Dialogs area opens
  every `app.dialog {id}` the inspector runs; extra params (`bullets`' `tab`) ride along.

### Native instead of ported

- **Controls.** egui's ribbon widgets become SwiftUI in a grouped `Form` (`.controlSize(.small)`): radio groups,
  pickers, toggles, sliders that commit on release (one undo step, as `fx_slider`), number fields with a
  stepper that commit on Return or focus loss (`spinner`), segmented controls for tabs and alignments.
  Split buttons are `Menu(primaryAction:)` in the inspector and `NSMenuToolbarItem` in the toolbar.
- **The colour grid** is a popover: theme colours with tints and shades, standard colours, No Fill, the hex
  field ("More Colors… #") and the eyedropper, which is `NSColorSampler` (anywhere on screen, the slide
  included) rather than deckcraft's slide-only eyedropper.
- **Theme tokens.** `theme.rs`' palette and fonts are not ported: chrome colours are DesignScaffold's tokens and
  AppKit's semantic colours, so light, dark and Increase Contrast follow macOS. Colours of the document
  (swatches, theme tiles, gradient bars, pattern swatches) are drawn from the presentation's scheme.
- **Shape icons** are drawn from DCGeometry's preset geometry as template images; pattern swatches from DCRender's
  preset tiles.
- **The toolbar** (`ToolbarCatalog`): New Slide (layouts, duplicate, outline, reuse, sections), Shape (the
  gallery by category, freeform tools, Icons, WordArt, Action Buttons, Action Settings…, Link…, Draw),
  Text Box, Table (sizes, Insert Table…, Draw Table), Chart (types), Picture (from file, photo albums), Media
  (video, audio), Quick Access (the QAT's buttons and Customize), Comment, Play (from start, current, presenter
  view, rehearse, set up); SmartArt is in Customize Toolbar. Items validate by their command's `enabled`.
- **The Quick Access Toolbar** is one toolbar item with a menu (its buttons, then Customize with deckcraft's
  common commands as checkmarks, and Reset), not buttons in the title bar.

### Ribbon → Mac

| Ribbon tab | Group | Where it lives on the Mac | Commands its controls run |
|---|---|---|---|
| Home | Clipboard | Edit menu (Cut, Copy, Paste, Paste and Match Formatting, Paste Special…); Format Painter and Paste Formatting: inspector Format (and ⇧⌘C) | `edit.paste`, `edit.pasteText`, `app.pasteSpecial`, `format.painterApply`, `edit.cut`, `edit.copy`, `format.painter` |
| Home | Slides | toolbar: New Slide (split: layouts, Duplicate, Slides from Outline…, Reuse Slides…, sections); inspector Slide ▸ Slide (Layout, Reset) | `slide.new`, `slide.layout`, `slide.reset`, `section.add`, `section.removeAll`, `slide.duplicate`, `app.reuseSlidesDialog`, `app.dialog` |
| Home | Font | inspector Format ▸ Text ▸ Font | `format.font`, `format.size`, `format.grow`, `format.shrink`, `format.clear`, `format.bold`, `format.italic`, `format.underline`, `format.strikethrough`, `format.superscript`, `format.subscript`, `format.spacing`, `format.case`, `format.highlight`, `format.color`, `format.fontDialog`, `font.rescan` |
| Home | Paragraph | inspector Format ▸ Text ▸ Paragraph | `format.bullets`, `format.numbering`, `format.outdent`, `format.indent`, `format.lineSpacing`, `format.paragraphDialog`, `format.columns`, `format.alignLeft`, `format.alignCenter`, `format.alignRight`, `format.justify`, `format.direction`, `format.anchor`, `smartArt.fromText`, `app.dialog` |
| Home | Picture | toolbar: Picture | `app.insertPictureDialog`, `insert.photoAlbum`, `insert.photoAlbumEdit` |
| Home | Drawing | toolbar: Shape, Text Box; inspector Format ▸ Fill & Line (Shape Styles: the Quick Styles grid) and Effects; Arrange tab | `shape.insert`, `insert.textBox`, `shape.quickStyle`, `shape.fill`, `shape.line`, `shape.effects`, `insert.icon`, `insert.wordArt`, `insert.actionButton`, `app.dialog`, `draw.inkToShape`, `arrange.bringToFront`, `arrange.sendToBack`, `arrange.bringForward`, `arrange.sendBackward`, `arrange.group`, `arrange.ungroup`, `arrange.regroup`, `arrange.align`, `arrange.distribute`, `arrange.rotateRight`, `arrange.rotateLeft`, `arrange.flipVertical`, `arrange.flipHorizontal` |
| Home | Editing | Edit menu: Find…, Replace…; Replace Fonts… is a dialog; inspector Arrange ▸ Selection Pane | `app.find`, `app.replace`, `font.replace`, `view.pane`, `app.dialog` |
| Home | Designer | inspector Slide ▸ Design Ideas | `design.applyIdea`, `design.theme`, `view.pane` |
| Insert | Slides | toolbar: New Slide | `slide.new`, `slide.duplicate`, `app.dialog`, `app.reuseSlidesDialog`, `section.add`, `section.removeAll` |
| Insert | Tables | toolbar: Table (split: sizes, Insert Table… dialog, Draw Table tool) | `insert.table`, `app.dialog` |
| Insert | Images | toolbar: Picture (split: Picture from File…, New/Edit Photo Album…); Screenshot not available (as deckcraft) | `app.insertPictureDialog`, `insert.photoAlbum`, `insert.photoAlbumEdit` |
| Insert | Illustrations | toolbar: Shape (split: the shapes gallery by category, freeform tools, Icons, WordArt), Chart (split: the chart types), SmartArt (dialog) | `shape.insert`, `insert.icon`, `insert.chart`, `insert.wordArt`, `app.dialog`, `insert.actionButton`, `draw.inkToShape` |
| Insert | Links | inspector Slide ▸ Insert Zoom (Slide, Section, Summary); toolbar Shape ▸ Action Buttons, Action Settings… and Link… (dialogs) | `insert.zoom`, `insert.actionButton`, `app.dialog` |
| Insert | Comments | toolbar: Comment (dialog); inspector Review ▸ Comments | `app.dialog` |
| Insert | Text | toolbar: Text Box; Insert menu: WordArt, Date and Time, Slide Number; Header & Footer is a dialog | `insert.textBox`, `insert.wordArt`, `insert.dateTime`, `insert.slideNumber`, `app.dialog` |
| Insert | Symbols | dialogs: Equation, Symbol | `app.dialog` |
| Insert | Media | toolbar: Media (split: Video from File…, Audio from File…) | `app.insertVideoDialog`, `app.insertAudioDialog` |
| Draw | Tools, Pens, Convert | toolbar Shape ▸ Draw (Select, the pens, Highlighter, Eraser: the session's ink tool; Ink to Shape); the canvas draws (Canvas area) | `draw.inkToShape` |
| Design | Themes | inspector Slide ▸ Themes (gallery, Browse for Themes…) | `design.theme`, `app.browseThemeDialog` |
| Design | Variants | inspector Slide ▸ Variants (gallery, Colors, Fonts, Effects, Background Styles; Customize… opens the dialogs) | `design.variant`, `design.colors`, `design.fonts`, `design.effects`, `design.background` |
| Design | Customize | inspector Slide ▸ Slide (Slide Size; Page Setup… dialog) and Format Background | `design.slideSize`, `design.background`, `design.hideBackgroundGraphics`, `app.dialog`, `view.pane` |
| Design | Designer | inspector Slide ▸ Design Ideas | `design.applyIdea`, `view.pane` |
| Transitions | Preview | inspector Animate ▸ Transition ▸ Preview (plays the show from the slide) | `show.start` |
| Transitions | Transition to This Slide | inspector Animate ▸ Transition (the gallery by category, Effect Options) | `transition.set`, `transition.options` |
| Transitions | Timing | inspector Animate ▸ Transition ▸ Sound and Timing | `transition.sound`, `transition.timing`, `transition.applyAll` |
| Animations | Preview | inspector Animate ▸ Animations ▸ Preview | `animation.preview` |
| Animations | Animation | inspector Animate ▸ Animations (Effect, Effect Options, Sequence) | `animation.set`, `animation.options` |
| Animations | Advanced Animation | inspector Animate ▸ Animations (Add Animation, Trigger, Animation Painter) and the Animation Pane | `animation.add`, `animation.timing`, `animation.painter`, `view.pane`, `animation.move`, `animation.remove` |
| Animations | Timing | inspector Animate ▸ Timing (Start, Duration, Delay); the pane's context menu reorders and removes | `animation.timing`, `animation.move`, `animation.remove` |
| Slide Show | Start Slide Show | toolbar: Play (split: Play from Start, from Current Slide, Presenter View, Set Up…); Slide Show menu | `show.start`, `show.fromStart`, `show.fromCurrent`, `show.presenter`, `app.dialog` |
| Slide Show | Set Up | Slide Show menu; inspector Slide ▸ Slide (Hide Slide) and Slide Show (Set Up Slide Show…, Custom Shows… dialogs) | `slide.hide`, `app.dialog`, `show.start` |
| Slide Show | Monitors | inspector Slide ▸ Slide Show (Presenter View, Use Timings, Play Narrations, Show Media Controls) | `show.presenter`, `show.setup` |
| Record | Record | the show (Show area); Cameo and narration are not available (as deckcraft) | `show.start` |
| Review | Proofing | inspector Review ▸ Proofing (Spelling…, Accessibility…, Language… dialogs) and Review ▸ Thesaurus | `app.dialog`, `review.thesaurusPane`, `review.replaceWord` |
| Review | Compare | inspector Review ▸ Revisions (Accept, Reject, End Review); Compare… dialog | `app.compareDialog`, `review.accept`, `review.reject`, `review.endCompare` |
| Review | Comments | inspector Review ▸ Comments (New Comment dialog, Previous, Next, Reply, Resolve, Delete) | `comment.prev`, `comment.next`, `comment.reply`, `comment.resolve`, `comment.delete`, `app.dialog`, `view.pane` |
| View | Presentation Views, Master Views, Show, Zoom, Window, Color | View menu (Views area); master views also in inspector Slide ▸ Master Views | `view.normal`, `view.outline`, `view.sorter`, `view.notesPage`, `view.slideMaster`, `view.handoutMaster`, `view.notesMaster`, `view.closeMaster`, `view.ruler`, `view.gridlines`, `view.guides`, `view.gridOptions`, `view.zoom`, `view.fit`, `view.newWindow`, `view.grayscale`, `view.dark`, `view.reading`, `view.notes`, `view.zoomDialog` |
| Shape Format | Insert Shapes | toolbar: Shape, Text Box; inspector Arrange ▸ Edit Shape (Change Shape, Edit Points, Smooth Corners, Merge Shapes) | `shape.insert`, `insert.textBox`, `shape.change`, `shape.editPoints`, `shape.smoothCorners`, `shape.merge`, `insert.icon`, `insert.wordArt`, `insert.actionButton`, `app.dialog`, `draw.inkToShape` |
| Shape Format | Shape Styles | inspector Format ▸ Fill & Line (Shape Styles, fill, line) and Effects | `shape.quickStyle`, `shape.fill`, `shape.line`, `shape.effects`, `view.pane` |
| Shape Format | WordArt Styles | inspector Format ▸ Text ▸ Text Fill and Text Effects (Text Outline, Shadow, Transform) | `format.color`, `format.textTransparency`, `format.textOutline`, `format.textShadow`, `format.textWarp` |
| Shape Format | Accessibility | inspector Format ▸ Size ▸ Alt Text (and the Alt Text dialog) | `shape.altText`, `app.dialog` |
| Shape Format | Arrange | inspector Arrange (order, align and distribute with Align to Slide, group, rotate, flip, the Selection Pane) | `arrange.bringForward`, `arrange.bringToFront`, `arrange.sendBackward`, `arrange.sendToBack`, `arrange.align`, `arrange.distribute`, `arrange.group`, `arrange.ungroup`, `arrange.regroup`, `arrange.rotateRight`, `arrange.rotateLeft`, `arrange.flipVertical`, `arrange.flipHorizontal`, `arrange.reorder`, `selection.select`, `selection.showAll`, `selection.hideAll`, `shape.visible`, `shape.lock`, `shape.rename`, `view.pane` |
| Shape Format | Size | inspector Format ▸ Size and Arrange ▸ Size (Height, Width, Rotation, Position, Size and Position…) | `shape.resize`, `shape.rotate`, `shape.move`, `shape.sizePosition` |
| Picture Format | Adjust | inspector Format ▸ Picture (Corrections, Remove Background, Recolor, Artistic Effects, Set Transparent Color, Change Picture, Reset, Compress) | `picture.removeBackground`, `picture.adjust`, `picture.recolor`, `picture.transparentColor`, `picture.artisticEffect`, `app.changePictureDialog`, `picture.reset`, `picture.compress` |
| Picture Format | Picture Styles | inspector Format ▸ Picture ▸ Picture Styles (style, Picture Border) | `picture.style`, `shape.line`, `app.dialog`, `shape.altText` |
| Picture Format | Size | inspector Format ▸ Picture ▸ Crop; Format ▸ Size | `picture.crop`, `shape.change`, `shape.resize`, `shape.sizePosition`, `shape.rotate`, `shape.move` |
| Table Design | Table Style Options, Table Styles, Draw Borders | inspector Format ▸ Table (options, style, Shading, Borders with the pen, Draw Table and Eraser tools) | `table.options`, `table.style`, `table.cellFill`, `table.borders` |
| Layout | Rows & Columns, Merge, Cell Size, Alignment | inspector Format ▸ Table | `table.deleteColumn`, `table.deleteRow`, `edit.delete`, `table.insertRowAbove`, `table.insertRowBelow`, `table.insertColumnLeft`, `table.insertColumnRight`, `table.merge`, `table.split`, `table.distributeRows`, `table.distributeColumns`, `table.cellAlign`, `table.cellMargins`, `format.alignLeft`, `format.alignCenter`, `format.alignRight` |
| Chart Design | Type, Data | inspector Format ▸ Chart (Chart Type; Edit Data… dialog) | `chart.type`, `app.dialog` |
| SmartArt Design | Create Graphic, Layouts, SmartArt Styles | inspector Format ▸ SmartArt (Text Pane, Add Shape, Promote, Demote, Insert Picture, Layouts, Convert, Colors, Style) | `view.pane`, `smartArt.addNode`, `smartArt.removeNode`, `smartArt.setNodes`, `smartArt.promote`, `smartArt.demote`, `app.smartArtPictureDialog`, `smartArt.layout`, `smartArt.toText`, `smartArt.toShapes`, `smartArt.colors`, `smartArt.style` |
| Playback | Preview, Editing, Video Options, Volume | inspector Format ▸ Playback (Play/Pause, Trim… dialog, options, Volume) | `media.toggle`, `media.options`, `app.dialog` |
| Slide Master | Edit Master, Master Layout, Edit Theme, Background, Close | inspector Slide ▸ Slide Master | `master.insertLayout`, `master.deleteLayout`, `master.preserve`, `master.placeholders`, `master.insertPlaceholder`, `design.theme`, `view.pane`, `view.closeMaster`, `app.dialog`, `app.browseThemeDialog` |
| Notes Master | Placeholders, Background, Close | inspector Slide ▸ Notes Master | `notes.placeholders`, `view.closeMaster`, `view.pane` |
| Handout Master | Page Setup, Placeholders, Background, Close | inspector Slide ▸ Handout Master | `handout.placeholders`, `view.closeMaster`, `view.pane` |
| Title bar | Quick Access Toolbar | toolbar items, customisable; app.qat adds and removes them | `app.qat` |
| Title bar | Search, Present, Comments, Light/Dark | Help ▸ Command Palette; toolbar Play; toolbar Comment / Review tab; View ▸ Dark Mode | `app.palette`, `show.start`, `view.pane`, `view.dark` |

### Tests

DCAppModelTests `InspectorModelTests.swift` (`InspectorFillTests` 15, `InspectorColorTests` 5,
`InspectorTimelineTests` 9) and `InspectorPaneTests.swift` (`InspectorSelectionPaneTests` 9,
`InspectorControllerTests` 14); DCAppTests `InspectorToolbarTests` 5: 57 tests. Ported (behaviour, at the model or the
toolbar): `panes.rs` (4: the fill transparency rules, the slider seed, Color and Transparency only where they
change the fill, the picture fill's transparency), `animtimeline.rs` (4), `animpane_tests.rs` (after-previous
bars, delay and duration drags with undo, Play From: selection, clicked row, reordering, triggered effects),
`selpane.rs` (2), `selpane_tests.rs` (7: order, click/⌘/⇧, eye and padlock with undo, drag and drop among
siblings, Bring Forward/Send Backward, rename, arrows and folding), `background_tests.rs` (3),
`pattern_fill_tests.rs` (7 of 8), `theme_colors_tests.rs` and `theme_fonts_tests.rs` (the menus' Customize…
open `themeColors` / `themeFonts`; choosing a scheme is one undo step), `effects_tests.rs` (1),
`split_button_tests.rs` (Group and Rotate's main halves; every split item has a main command and a menu),
`last_color_tests.rs` (5, as 2), `smartart_tests.rs` (2 of 3), `thesaurus_tests.rs` (1), `widgets.rs`
(`text_draft` ×2), `ribbon.rs` (`effect_options_mark_only_the_stored_choice`), `lib.rs` (the QAT test), plus
colour parameters round-tripping through `Cmd.colorValue`, the theme grid, gradient edits, `view.pane` → tab,
contextual tabs, Align to Slide, comment navigation, Smooth Corners, Quick Styles, Insert Zoom, and every
ribbon group's commands and every toolbar menu item against the registry.

Not applicable (egui mechanics): `widgets.rs`' split-button geometry and accessibility-name tests (AppKit's
`NSMenuToolbarItem` and `Menu(primaryAction:)` have one target each half), the dropdown's role, the hex field
keeping the menu open and the eyedropper round trip (a popover and `NSColorSampler`);
`split_button_tests.rs`' keyboard entry into split menus (AppKit menus); `pattern_fill_tests.rs`'
`pattern_gallery_shows_which_swatch_has_keyboard_focus` (focus rings are the system's); `smartart_tests.rs`'
`layout_gallery_shows_cached_pictures_and_previews_on_hover` (the layouts are a menu, without pictures);
`theme.rs` (egui fonts and visuals); `ribbon.rs`' `ribbon_tile_labels_follow_the_theme` and
`mac_title_bar_centres_and_clears_the_traffic_lights` (no egui title bar); the screenshot test of
`animpane_tests.rs`. `animpane_tests.rs`' `preview_rejects_a_from_that_is_not_an_effect_index` is the Show area's
(`animation.preview`).

Screenshots checked through the control channel (`--control 7982`, `ui.screenshot`): Fill & Line, the gradient
editor (after a synthetic click on "Gradient fill"), Effects, Text, Table, Chart, SmartArt, Animate with the
Animation Pane, Transition, Slide, Arrange with the Selection Pane (a row clicked through `ui.click`), Review
with a comment, the inspector hidden by `view.pane {pane: null}`, and the toolbar (a click on Text Box inserts
one).

### Divergences

- **Shape menu inserts.** The toolbar's Shape menu inserts the preset at the slide's default place
  (`shape.insert {preset}`), as Keynote does, where deckcraft arms the shape tool for a drag. The freeform tools
  and Draw Table still arm the tool (`Session.setTool`), as do the Draw pens.
- **Format Painter's "keep on"** is a menu item (deckcraft: double-click).
- **The SmartArt layout gallery** is a menu by category without pictures or hover previews.
- **The colour grid's eyedropper** samples the whole screen (`NSColorSampler`).
- **Font families** list the theme's heading and body fonts once when they are the same face; deckcraft's
  `dedup` then labels the next installed family "(Body)".
- **The Transitions tab's Preview** runs `show.start {from, preview: true}` (the Show area plays it).
- **Animation preview state**: the Animation Pane shows Play From / Play All and Stop side by side instead of
  one button that turns into Stop (the preview's state is the Show area's).
- **Hiding the inspector** with the toolbar's inspector button doesn't clear `ui.pane`; `view.pane {pane: null}`
  hides it, any pane shows it.

### Open items

- The Quick Styles grid approximates deckcraft's tiles with blends of the scheme colours (no exact
  `gamma_multiply`/`lerp_to_gamma`).
- Table Design's quick style gallery is a picker of all styles, without the painted tiles.
- Recolor, Picture Styles and Artistic Effects are menus by name, without deckcraft's painted tiles.
- No shared-file edits were needed.

## Ribbon (Docs/plans/Ribbon-and-StartScreen.md)

The ribbon returns as an optional window layout beside the inspector (PLAN.md "Decided", amended 2026-10-27).
The guiding principle is the operator's: someone who knows PowerPoint should be comfortable, without a 100% match.

### R0: one table (done 2026-10-27)

No UI changes: the app looks and behaves as before. What landed is data the ribbon will draw from, and the
tables the toolbar now shares with it.

| File (DCAppModel) | What |
|---|---|
| `RibbonLayout.swift` | The ribbon as data: 10 regular tabs and 10 contextual ones (named as `InspectorController.contextual()` names them), their groups (each with a `foldOrder` for §5) and controls (kind, sizes, a `CommandRef` with deckcraft's params, `also` for the commands a ribbon-only menu runs). Shared Arrange and Size groups for the object tabs. No labels: they come from the registry; a title only where the command doesn't name the control |
| `CommandMenus.swift` | `CommandRef`, `CommandMenuEntry`, and the seven split menus the toolbar opens (New Slide, Shapes, Table, Chart, Picture, Media, Play), moved down from `ToolbarCatalog`; `ChartMenu` moved here from `InspectorObjectPanes.swift` |
| `CommandSymbols.swift` | One command → SF Symbol table (by id, or `id:<id or pane param>`), and deckcraft's QAT icon names, both moved from `ToolbarCatalog` |
| `CommandHelp.swift` | The tooltip descriptions' table (decision 3), empty in R0: R1 writes the ribbon's and toolbar's, R4 the rest, translated as `help.<id>` in the Commands catalog |
| `InspectorRibbonMap.swift` | Each group's commands are now derived: the RibbonLayout groups or controls it names, plus `extra` (what its Mac place runs beyond them), without the canvas's `tool.*`. None of the previous commands was lost; 19 groups gained commands their shared menus already ran (the table above is regenerated from it) |

- **Arranged for PowerPoint users.** Home has PowerPoint's Insert group (Picture, Shapes, Text Box) before Drawing;
  Review puts Comments before Compare. Left out because they never work: Screenshot, Ink to Text and Ink to Math,
  Cameo, Translate, Add-ins.
- **Tests.** `RibbonCoverageTests` (DCAppModelTests, 9): every command deckcraft's ribbon runs has a control or is
  left out with a reason (`format.state`, a query; `design.browseTheme`, an enabled check); the inventory equals
  what `../deckcraft/crates/ui-egui/src/ribbon*` runs when that checkout is at the pin (it skips otherwise); every
  ribbon and menu command is known; ids are unique; the tabs and contextual tabs; RibbonMap's ids resolve and
  every ribbon group has a Mac place; the QAT offers `qat.rs`' commands; the symbols and help tables.
  `InspectorToolbarTests.toolbarSymbolsAndMenusAreUnchanged` pins the toolbar's symbols and menus as they were.
- **Strings.** About 25 menu strings moved with their code from DCApp's catalog to DCAppModel's
  (`Tools/l10n/sync.sh --no-app`); their English is unchanged. Tab, group and control titles are English until
  R4's `Ribbon.xcstrings`; nothing shows them yet.
- **For R1 and R2.** The ribbon-only menus (Paste, Section, Change Case, Line Spacing, Arrange, Align…) list their
  commands in `also`; R1 builds their entries. Record ▸ From Current Slide adds the current slide as `from` when it
  runs. Handout Master's Slides Per Page is UI state in deckcraft with no command; R2 gives it one.

### R1: the static ribbon (done 2026-10-28)

The ribbon is an optional window layout: View › Ribbon (⌥⌘R, the UI command `view.ribbon {on?}`), or
Settings › General › Window layout. The toolbar and inspector stay the default until R4 (decision 1).

| File | What it holds |
|---|---|
| `DCAppModel/RibbonModel.swift` | `WindowLayout`; the tab `UiState.tab` names (deckcraft's titles); each control's label, tooltip, symbol, enabled and toggle state; check boxes and spinners; what a click runs (`primary`, `press`); the columns a group is drawn in; `ui.inspect`'s `ribbon` |
| `DCAppModel/RibbonMenus.swift` | The ribbon's own menus, with deckcraft's parameters: Paste, Layout, Section, the font list and sizes, Character Spacing, Change Case, Bullets, Numbering, Line Spacing, Columns, Text Direction, Align Text, Convert to SmartArt, Arrange, Shape Effects (`effects_menu`), Replace, Photo Album, Icons, Zoom, Action, WordArt, Themes, Variants, Colors, Fonts, Effects, Background Styles, Slide Size, Transitions, Effect Options, Sound, Animations, Add Animation, Trigger, Start, Accept, and Zoom |
| `DCApp/Ribbon/RibbonView.swift` | The SwiftUI ribbon: the tab row and the selected tab's groups. Large controls are an icon over a label; small ones are three rows to a column; B I U and the alignments are icons only. Splits are a native split button, or for large ones an icon over a label that opens the menu. A double click on the shown tab minimises it (`view.collapseRibbon`) |
| `DCApp/Ribbon/RibbonFeature.swift` | Every document window follows `UiState.layout`. In the ribbon layout a `RibbonContainerController` puts the ribbon above the split view, and `RibbonToolbar` has the Quick Access Toolbar's buttons at the leading edge, then the title, Search (`app.palette`), Present (`show.fromCurrent`) and Comments. The inspector closes and becomes the task pane |
| `CommandHelp.swift` | The descriptions (decision 3), written in our own words, for every command the regular tabs, the toolbar and the QAT show (145 of them). They are keyed `id` or `id:<id or pane param>` and translated as `help.<key>` in the Commands catalog; `glyphs` and `tip` build the tooltip |
| `CommandSymbols.swift` | A symbol for each ribbon control, by control id, over the command's |

- **Galleries are menus in R1.** Themes, Variants, Transitions and Animations list their items by name; Quick
  Styles opens the Format pane, which has the grid. R2 draws them as tiles.
- **Colours** reuse the inspector's `ColorGrid`, and Shape Fill and Outline go through `InspectorController`, so the
  last colour is shared. Spinners reuse `NumberField`.
- **Not a titlebar accessory.** On macOS 26 a `.bottom` titlebar accessory sits only over the split view's content
  section, beside the sidebar, and is clipped to about 40 pt. The ribbon is a view pinned to the safe area above the split view
  instead. The split view, and what `InspectorFeature` reaches through `wc.split`, are unchanged.
- **The layout is app-wide.** `UiState` is one for the app, as deckcraft's is, so View › Ribbon switches every
  window and is the default for new ones.
- **The window title** is hidden in the ribbon layout and shown as a toolbar item after the QAT buttons, so the
  buttons can come first.
- **Tests.**
  - `RibbonModelTests` (DCAppModel), 9 tests:
    - It walks every control of the ten tabs and runs what it can run against a scratch session: its button, every menu item, its check box both ways and its spinner. That is over 400 commands, and each one the ribbon shows enabled must succeed.
    - Three commands are listed as needing a state the fixture doesn't make: Regroup, Paste Formatting and Edit Photo Album.
    - It also covers the toggles following `format.state`, check boxes and spinners, switching layouts (the document, the selection and the undo stack are kept), and old `ui.json` files reading as the Mac layout.
    - The rest check the tab names, the columns, and every command having a description.
  - `RibbonWindowTests` (DCAppTests), 4 tests: the window swaps its content and toolbar back and forth; every group of every tab draws; every symbol is an SF Symbol; the toolbar's tooltips carry descriptions.
- **Screenshots** of all ten tabs were taken through the control channel (`view.tab`, then `ui.screenshot`).
  Contextual tabs, inline galleries and folding are R2 and R3.

### S1: the start window (done 2026-10-28)

The start screen of PowerPoint for Mac, in its own window, holding deckcraft's File › Home, New and Open content
(§7). With nothing to open, a launch shows it in place of an untitled presentation. Settings › "Show the start screen
when DeckCraftNative opens" (on by default) turns that off.

| File | What |
|---|---|
| `DCAppModel/StartCatalog.swift` | `StartTile` (Blank, the 8 themes, the sample, the 6 starters; ids `blank`, `theme:<name>`, `sample`, `template:<name>`), `newParams`/`create` (`file.new` with the tile's params; the sample through `Sample.openSample`), `StartRecent` rows (`split_path`; `recent_exists`, never probing remote paths; deduped, at most 12), `atLaunch` (the launch rule), and `StartTileArt` (each tile's title slide rendered by DCRender in a scratch session, cached as PNG in `~/Library/Caches/DeckCraftNative/StartTiles/<version>/`; a theme's empty title shows its name) |
| `DCAppModel/StartScreenModel.swift` | The window's state: page (kept as `UiState.startPage`, so it reopens there), search, selection, arrow-key moves, what Return does (Create, Open, or nothing for a missing file), the merged recent list, `inspect()` and `control()` for the control channel |
| `DCApp/Start/StartFeature.swift` | Install: the model and its NSDocumentController hooks, `DialogController.startScreen`, `ui.inspect`'s `home`/`backstage`/`startScreen`, `ui.startScreen`, `ui.screenshot {window: "start"}`, File › Open Recent (`StartRecentMenu`), the launch rule, closing when a presentation opens |
| `DCApp/Start/StartWindowController.swift` | The `NSWindow` hosting `StartView` with its toolbar bridged. Esc closes it; ⌘F focuses the search before the menu bar sees it |
| `DCApp/Start/StartView.swift` | `NavigationSplitView` (Home, New, Open), `.searchable` in the toolbar, the tile strips and grid, the recent rows (Quick Look thumbnail, folder, last opened, "(missing)"; context menu: Show in Finder, Share…, Remove from List), Cancel and Create/Open |
| `DCApp/Start/StartArt.swift` | The tile pictures (rendered one at a time off the main thread) and the recent files' thumbnails (`QLThumbnailGenerator`) |

Shared files, small additive edits: `UiState` (`showStartScreen`, `startPage`), `DialogsModel` (`startScreen`),
`DialogsRouting` (`app.backstage {page: home|new|open}` and `app.home` show the start window when there is one),
`DialogsForms`/`DialogsActions` (the "new" dialog's tiles come from `StartCatalog`; the Settings switch, which Cancel
restores), `AppController` (`applicationShouldOpenUntitledFile` asks `StartFeature.atLaunch`), `AutomationFeature`
(`nextCapture`: the window the next screenshot takes), `Features` (Start is installed last, after Show, so its
`ui.screenshot` hands every other window on), and both string catalogs.

- **Recents.** NSDocumentController is the truth for files that are there, but its list drops a file that has gone.
  `UiState.recent` (deckcraft's list, in `ui.json`) keeps those where they were. They show "(missing)" and do nothing
  when chosen until removed, and the merged list is written back to `UiState.recent`. File › Open Recent is built
  from the same rows each time it opens (a missing file is listed, disabled), so the two always match.
  NSDocumentController has no way to remove a single entry, so removing one path clears its list and notes the
  rest again.
- **Closing.** Esc, Cancel, the close button, or a presentation opening or being created (`file.new` included,
  from anywhere). It is not a document window, and it never blocks scripts.
- **Divergences from deckcraft.** Esc closes it (deckcraft's has nowhere to go). Home shows every recent file, not
  8 plus "More presentations". There is no Discord link. Typing goes nowhere, as in deckcraft, because the window
  has no slide; with the search field focused, typing searches.
- **Left out** (the plan's §3 and decision 6): Favourites, Shared, the account badge, cloud places, the Themes
  strip's disclosure triangle, and the sortable "Last opened" column.
- **Tests.** DCAppModelTests `StartScreenTests` (25) and DCAppTests `StartWindowTests` (8).
  - Ported from `backstage/tests.rs`:
    - `the_start_screen_is_file_home`, adapted because Esc closes the window here;
    - `open_lists_recent_files_and_opens_one`;
    - `start_screen_opens_the_palette_and_preferences`;
    - `start_screen_ignores_text_paste_and_ime_while_file_keys_navigate`, as typing into the window;
    - the File-tab half of `start_screen_opens_files_and_the_file_tab_from_the_keyboard`;
    - `split_path`, from `page_ids_round_trip…`.
  - Ported from `tests.rs`: `recent_exists_tells_missing_from_present`.
  - Not applicable:
    - the ⌘O half of the keyboard test: it opens AppKit's open panel, not a service;
    - `start_screen_ignores_document_shortcuts`: the menu bar validates against the session, so with nothing open
      Save, Close and Hyperlink have no target, and ⌘F opens the palette, as the Dialogs area chose;
    - `a_file_that_cant_be_opened_says_why`: NSDocument shows its own error alert.
- **Control channel.**
  - `ui.inspect` reports:
    - `home`: whether the window is open;
    - `backstage`: its page, else null;
    - `startScreen`: `open`, `shown`, `page`, `selection`, `query`, `action`, `items`, `recent` and `openRecent`.
  - `ui.startScreen {page?, query?, select?, move?, activate?, remove?, open?}` drives the window without pixels.
  - `ui.screenshot {window: "start"}` captures it.
  - The alpha gate's step 0 launches with nothing to open and checks that the window shows and no document exists.
    It then creates a deck from Harbor and checks for one document and a closed window, with a screenshot.

### R2: contextual tabs and galleries (done 2026-10-28)

The ten contextual tabs come after the regular ones when the selection has their object: Shape Format, Picture
Format, Table Design and Layout, SmartArt Design, Chart Design, Playback, and the Slide, Notes and Handout Master
tabs. Their titles are tinted with the accent colour. Galleries are tiles in the ribbon, with a "›" button for the
rest.

| File | What it holds |
|---|---|
| `DCAppModel/RibbonModel.swift` | `contextual` (`ribbon.rs` `contextual`, moved from `InspectorController`, which now calls it); `tabs(model)` (the regular tabs, then the contextual ones in that order); `selected(model)`; `settle`, which `AppModel.changed` calls: a contextual tab that no longer applies gives way to Home. The contextual check boxes (table style options, a clip's playback, Preserve, a master's title, footers and placeholders), Height and Width in the Preferences unit, Draw Table and Eraser, the colour defaults, and SmartArt's graphic and Text Pane line |
| `DCAppModel/RibbonGalleries.swift` | Each gallery's items by category, the ones shown inline, the selection's, and the command a tile runs: themes, variants, transitions, animations, table styles, picture styles, quick styles, SmartArt layouts and SmartArt styles |
| `DCAppModel/RibbonTileArt.swift` | The table-style and SmartArt tiles' pictures: DCRender's render of a sample table, or of `SmartArtCommands.preview`, in the presentation's theme. Pure and safe off the main thread |
| `DCAppModel/RibbonMenus.swift` | The contextual tabs' menus, with deckcraft's parameters (`shape_format.rs`, `picture_format.rs`, `table.rs`, `chart.rs`, `smartart.rs`, `playback.rs`, `masters.rs`); Bevel and Format Shape… in Shape Effects; Weight, Dashes and Arrows under the outline colour grids (`colorExtras`) |
| `DCApp/Ribbon/RibbonGallery.swift` | `RibbonGalleryView` (the inline row and "›"), `RibbonGalleryGrid` (the whole gallery by category, in a popover), the tiles, `RibbonArt` (renders the table and SmartArt tiles one at a time off the main thread and keeps them for the theme), and `RibbonShapesGrid` (`shapes_gallery`) |
| `DCApp/Inspector/InspectorFormatPane.swift` | `QuickStyleTile`, now one view for the inspector's grid and the ribbon's gallery |

- **Never switched to.**
  - Selecting an object adds its tab and leaves the shown tab alone, as in deckcraft and PowerPoint.
  - When the object is deselected, the tab gives way to Home (`ribbon.rs` `show`). Selecting it again stays on Home.
  - Entering a master view adds its tab but doesn't show it. The spec found nothing in deckcraft that switches tabs.
- **The theme gallery is the start window's tiles.** Each tile is `StartFeature.art`'s render of that theme's
  title slide, so both show the same picture. Variants are `ThemeTile`s in the variant's colours.
- **Tiles.**
  - Transitions are an SF Symbol over the name.
  - Animations are a star in the class's colour (a path for Motion Paths).
  - Picture styles are drawn from `PictureStyleCommands.look`.
  - Quick styles are the inspector's tile.
  - Table styles and SmartArt are DCRender's, on white.
  - No tile copies PowerPoint's art.
  - There is no hover preview (§12).
- **Inline rows** start at the selection's tile when it isn't among the first, as a gallery scrolled to it would.
  Home › Quick Styles is a large button that opens the gallery, as PowerPoint's is; Shape Format's is inline.
- **Slides Per Page** gets a UI command, `view.handoutSlides {count: 1|2|3|4|6|9}`. deckcraft keeps it as UI state
  with no command, and a menu item needs one. The control channel's UI command count is 53.
- **Changes from R0's table.**
  - Crop is a menu (deckcraft's is not a split).
  - Text Outline is a colour split.
  - The table's vertical alignments are plain buttons (`format.state` has no anchor).
  - Text Pane toggles.
  - Handout Master has a Page Setup group.
  - The notes and handout placeholder check boxes are named.
- **Left to the inspector.**
  - The Table pen's weight, style and colour: Borders uses the pen the Table pane sets.
  - Text Fill's transparency slider.
  - Set Transparent Color, which is an eyedropper on the canvas.
  - Compress's options beyond the resolution.
- **Tests.**
  - `RibbonContextualTests` (DCAppModel), 9 tests:
    - Each object kind shows its tabs, tested for each of the nine kinds.
    - Tabs are never switched to.
    - Every gallery has its sources.
    - The theme tiles are the start window's.
    - A gallery pick is one undo step and undoes in one.
    - The tile renders come out as PNGs.
    - It walks every contextual control with its object selected, over 250 commands. Each one the ribbon shows enabled must succeed, except seven listed as needing more state.
    - Check boxes read their object.
    - Height and Width use the Preferences unit.
  - `RibbonWindowTests` gains two tests: every contextual tab draws with its object selected, and every expanded gallery and the Shapes grid draws.
  - R1's walk now runs gallery picks too.
  - Both walks run each command the first five times a control offers it, and the last time. Before this, R1's
    walk ran all 1,368 items, the 270-preset shape menus among them, at about 17 ms of scratch session each.
    That held the main actor for 25 s, past `UpdatesCenterTests`' 10 s wait for a check to report on it, so that
    suite failed in R1's and R2's full runs and passed alone. That wait, and its download wait, are now 120 s. Both
    return as soon as their condition holds.
- **Screenshots**, through the control channel, of Shape Format, Picture Format, Table Design, Layout, Chart Design, SmartArt Design and the three master tabs, besides Design, Transitions and Animations with their tiles.
  - `ui.screenshot` captures what was last drawn, which can be a redraw behind the last command. Wait a few seconds, or take the shot twice.

## lib.rs tests

deckcraft's `crates/ui-egui/src/lib.rs` has 62 `#[test]`s (`mod tests`, at the pin). Each is triaged below: **already
ported** by an area (cited), **ported** here (`DCAppModelTests/LibTests.swift`, 16 tests; `DCAppTests/LibTests.swift`,
10 tests, real views in-process), or **not applicable** (egui machinery the Mac app doesn't have). Totals: 25 ported,
16 already ported, 21 not applicable; no known issues.

| # | lib.rs test | Status | Swift test or reason |
|---|---|---|---|
| 1 | `a_trackpad_twist_rotates_the_shape_under_the_canvas` | ported | DCAppModelTests `LibTests.aTrackpadTwistRotatesTheShapeUnderTheCanvas` (`CanvasInput.twist`; off the canvas AppKit never sends `rotate(with:)` to it) |
| 2 | `web_export_all_slides_gives_one_file_per_slide` | ported | `LibTests.webExportAllSlidesGivesOneFilePerSlide` (the Mac's Export › PNG (all slides) through the save panel, not a browser download) |
| 3 | `web_png_export_can_leave_the_background_transparent` | ported | `LibTests.webPngExportCanLeaveTheBackgroundTransparent` (the Export sheet; JPEG never gets the PNG-only checkbox) |
| 4 | `quick_access_toolbar_adds_removes_resets_and_persists` | already ported | `InspectorPaneTests.quickAccessToolbarAddsRemovesAndResets` (Inspector's `QAT`) |
| 5 | `opening_a_file_with_missing_fonts_shows_a_toast_once` | already ported | `DialogsFilesTests.missingFontsToastOncePerDocument` |
| 6 | `change_picture_replaces_the_selected_picture` | ported | `LibTests.changePictureReplacesTheSelectedPicture` (a panel answering at once and one answering later, deckcraft's inbox) |
| 7 | `home_shows_the_start_screen_over_the_open_presentation` | ported | `LibTests.homeShowsTheStartScreenOverTheOpenPresentation` (Home is the template gallery, a window of its own) |
| 8 | `ctrl_word_keys_edit_text` | already ported | `CanvasTextInputTests.optionWordKeysEditText` (the Mac's ⌥ word keys) |
| 9 | `title_bar_export_opens_the_export_dialog` | ported | `LibTests.titleBarExportOpensTheExportDialog` (the visible control is File › Export…) |
| 10 | `ctrl_v_pastes_an_image_when_no_paste_event_arrives` | already ported | `ViewsWindowTests.aPictureFromAnotherAppIsInserted` (egui-winit's release-only ⌘V doesn't exist with NSPasteboard) |
| 11 | `typing_goes_on_after_tab_in_a_text_box` | already ported | `CanvasTextInputTests.typingGoesOnAfterTabInATextBox` |
| 12 | `tab_in_an_edited_list_keeps_the_keyboard` | ported | DCAppTests `LibTests.tabInAnEditedListKeepsTheKeyboard` (`keyDown` Tab/Return, `insertText`; the canvas stays first responder) |
| 13 | `home_needs_an_open_presentation` | not applicable | no start screen behind Home on the Mac: with nothing open Home opens the template gallery (`DialogsFilesTests.pageIdsRoundTripAndUnknownIdsAreRefused`: New needs nothing open) |
| 14 | `new_window_shows_the_same_document_on_its_own_slide` | ported | DCAppTests `LibTests.newWindowShowsTheSameDocumentOnItsOwnSlide` (adds reopening and closing with the presentation to `ViewsModelTests.newWindowCommand`, `ViewsWindowTests.newWindowShowsItsOwnSlide`) |
| 15 | `grid_options_sets_spacing_and_display_or_opens_the_dialog` | ported | `LibTests.gridOptionsSetsSpacingAndDisplayOrOpensTheDialog` |
| 16 | `grid_options_dialog_lists_spacing_and_display` | ported | `LibTests.gridOptionsDialogListsSpacingAndDisplay` |
| 17 | `preferences_cancel_restores_the_settings_done_keeps_them` | already ported | `DialogsTests.optionsCancelUndoesTheChanges`, `optionsCloseRestoresTheAppearance`; `DialogsWindowTests.settingsShowInAWindowAndClosingCancels` |
| 18 | `about_dialog_close_and_cancel_close_it` | ported | `LibTests.aboutDialogCloseAndCancelCloseIt` |
| 19 | `off_slide_objects_show_on_the_pasteboard_and_can_be_selected_and_moved` | already ported | `CanvasPointerTests.offSlideObjectsShowOnThePasteboardAndCanBeSelectedAndMoved` |
| 20 | `the_canvas_renders_only_the_slide_when_nothing_is_off_it` | already ported | `CanvasPointerTests.offSlideObjectsShowOnThePasteboardAndCanBeSelectedAndMoved` (`pictureCount`: an unchanged slide isn't drawn again) |
| 21 | `copy_and_cut_commands_reach_the_system_clipboard` | ported | DCAppTests `LibTests.copyAndCutCommandsReachTheSystemClipboard` (Cut and "only once" added to `ViewsWindowTests.copyFromAnywhereReachesThePasteboard`) |
| 22 | `copy_then_paste_shortcut_duplicates_an_object_without_text` | already ported | `ViewsWindowTests.aCopiedShapeIsTheMarkerAPictureAndPastesBack` |
| 23 | `select_all_follows_the_focused_pane` | ported | DCAppTests `LibTests.selectAllFollowsTheFocusedPane` (the Edit menu's routing with the navigator, then the canvas, first responder) |
| 24 | `missing_recent_is_marked_and_its_error_shows` | not applicable | Open Recent is NSDocumentController's menu; a missing file's error is NSDocument's alert (no File › Home list) |
| 25 | `recent_entry_can_be_removed` | not applicable | NSDocumentController's Open Recent (Clear Menu); no per-entry Remove button |
| 26 | `recent_exists_tells_missing_from_present` | not applicable | no existence probe: NSDocumentController keeps the recent list |
| 27 | `the_language_dialog_marks_the_selected_text` | ported | `LibTests.theLanguageDialogMarksTheSelectedText` |
| 28 | `the_language_dialog_marks_the_whole_presentation` | ported | `LibTests.theLanguageDialogMarksTheWholePresentation` |
| 29 | `the_language_dialog_marks_the_whole_presentation_with_nothing_selected` | ported | `LibTests.theLanguageDialogMarksTheWholePresentationWithNothingSelected` |
| 30 | `editing_notes_in_the_pane_keeps_their_formatting` | ported | DCAppTests `LibTests.editingNotesInThePaneKeepsTheirFormatting` (the notes pane's text view, then .pptx and back) |
| 31 | `copy_offers_html_and_paste_keeps_bold` | ported | DCAppTests `LibTests.copyOffersHtmlAndPasteKeepsBold` (the copy half; the paste half is `ViewsWindowTests.textAndHtmlFromAnotherAppPasteAsText`) |
| 32 | `a_textless_shape_copies_as_the_objects_marker` | already ported | `ViewsModelTests.aTextlessShapeCopiesAsTheObjectsMarker`, `ViewsWindowTests.aCopiedShapeIsTheMarkerAPictureAndPastesBack` |
| 33 | `preview_hides_an_entrance_until_it_plays` | ported | `LibTests.previewHidesAnEntranceUntilItPlays` (by-paragraph states and the rendered frame) |
| 34 | `animation_preview_plays_on_the_canvas_then_stops` | already ported | `ShowTests.animationPreviewPlaysOnTheCanvasThenStops` |
| 35 | `page_flick_uses_the_stronger_axis` | already ported | `CanvasModelTests.pageFlickUsesTheStrongerAxis` |
| 36 | `mouse_wheel_keeps_fast_notches_in_both_directions_without_a_smoothed_tail` | already ported | `CanvasModelTests.mouseWheelKeepsFastNotchesInBothDirections` |
| 37 | `mouse_wheel_fractional_lines_accumulate_into_one_slide_per_line` | already ported | `CanvasModelTests.mouseWheelFractionalLinesAccumulateIntoOneSlidePerLine` |
| 38 | `mouse_wheel_fraction_does_not_carry_into_another_presentation` | already ported | `CanvasModelTests.mouseWheelFractionDoesNotCarryIntoAnotherPresentation` |
| 39 | `mouse_wheel_over_a_zoomed_canvas_pans_and_outside_the_canvas_does_not_navigate` | ported | DCAppTests `LibTests.mouseWheelOverAZoomedCanvasPansAndOutsideTheCanvasDoesNotNavigate` (scroll events from `CGEvent`; the pan is NSScrollView's, and outside the canvas AppKit sends the wheel elsewhere) |
| 40 | `a_sideways_trackpad_swipe_turns_the_page_and_a_second_flick_waits` | ported | DCAppTests `LibTests.aSidewaysTrackpadSwipeTurnsThePageAndASecondFlickWaits` (phased trackpad events) |
| 41 | `a_vertical_wheel_still_turns_the_page_and_a_zoomed_slide_pans_instead` | ported | DCAppTests `LibTests.aVerticalWheelStillTurnsThePageAndAZoomedSlidePansInstead` |
| 42 | `show_start_refuses_a_from_that_is_not_a_slide` | ported | `LibTests.showStartRefusesAFromThatIsNotASlide` (the command) and DCAppTests `LibTests.showStartRefusesAFromThatIsNotASlide` (the control channel; fix below) |
| 43 | `a_swipe_during_the_show_turns_the_page` | ported | `LibTests.aSwipeDuringTheShowTurnsThePage` (`ShowCoordinator.scroll`) |
| 44 | `the_pen_ignores_a_swipe_during_the_show` | ported | `LibTests.thePenIgnoresASwipeDuringTheShow` |
| 45 | `interface_size_applies_when_the_slider_is_let_go` | not applicable | no Interface size slider: AppKit text follows the system's size settings (Dialogs, "Divergences") |
| 46 | `status_zoom_slider_is_named_without_growing_the_status_bar` | not applicable | egui's slider geometry in its status bar; the SwiftUI slider is laid out by SwiftUI and carries an `accessibilityLabel` |
| 47 | `preferences_and_format_pane_name_every_input` | not applicable | egui/accesskit's `check_accessibility` over egui widgets; AppKit and SwiftUI controls are labelled natively (the Format pane is the Inspector's) |
| 48 | `ui_screenshot_round_trips_through_the_callable_slot` | not applicable | egui's screenshot callback slot; the Mac captures synchronously (`AutomationTests.screenshotReplyIsPathOnlyOrExplicitlyInline`) |
| 49 | `logic_drains_control_without_a_ui_pass` | not applicable | eframe's logic-only pass; control requests are taken on the main thread as they arrive (`ControlServer`) |
| 50 | `synthetic_input_is_one_pending_batch_and_never_replays` | not applicable | egui's synthetic input batches (`raw_input_hook`); the Mac sends real `NSEvent`s |
| 51 | `a_control_click_on_the_first_font_discard_is_requeued_and_lands` | not applicable | egui's discarded first pass (font install) |
| 52 | `synthetic_batch_is_retracted_when_a_modal_opens_first` | not applicable | synthetic batch retraction |
| 53 | `synthetic_click_is_consumed_on_its_old_target_before_logic_changes_the_document` | not applicable | synthetic batch / logic-pass ordering |
| 54 | `input_target_tracks_slideshow_opening_and_palette_selection` | not applicable | `input_target` |
| 55 | `input_target_changes_retract_a_queued_click` | not applicable | `input_target` and retraction |
| 56 | `hidden_logic_pass_carries_a_synthetic_batch_and_drops_it_when_the_document_changes` | not applicable | eframe's hidden logic pass carrying `RawInput` |
| 57 | `visible_logic_pass_does_not_retract_from_the_previous_input_state` | not applicable | eframe's logic-only pass and egui's `InputState` |
| 58 | `carried_batch_is_consumed_before_the_full_pass_applies_a_control_change` | not applicable | carried `RawInput` batches |
| 59 | `hidden_full_pass_receives_synthetic_ui_input` | not applicable | eframe's hidden full pass |
| 60 | `paste_image_event_inserts_one_picture` | already ported | `ViewsWindowTests.aPictureFromAnotherAppIsInserted` |
| 61 | `hidden_viewport_advances_show_and_presenter_clocks_from_logic` | not applicable | egui's hidden viewport logic passes; the show's 100 ms timer keeps its clock (Show, "How it draws"); `hiddenLogicTime` is `ShowTests.hiddenLogicAdvancesTheShowAndVisibleFramesReanchor` |
| 62 | `overdue_visible_logic_does_not_reanchor_a_later_hidden_show` | not applicable | eframe's overdue logic-only pass (same) |

**App fixes made for these tests.**
- `DCApp/Show/ShowFeature.swift`: the control channel's `show.start {reading: true}` ran `view.reading`, which ignored
  `from` (it played the current slide) and accepted one that names no slide. It now runs `show.start`, which reads
  `reading` itself and checks `from`, as `control.rs` does.
- `DCApp/Views/ViewsFeature.swift`: the model-changed observer listened to every app's notifications and evicted every
  thumbnail not in its own model (`Thumbnails.keep`), so any other `AppController` changing during
  `ViewsWindowTests.theThumbnailPaneOfAHugeDeckRendersOnlyTheSlidesInView`'s awaits emptied its cache (it failed every
  run once these tests ran beside it). The observer now listens to its own app, a reinstall removes the previous one,
  and a model drops only the thumbnails of presentations it closed. One app, one model: no change in the app.
- `DCApp/Views/Pasteboard.swift`: `PasteboardBridge.menuCommand` takes the responder with the keyboard as a defaulted
  parameter (the key window's first responder, as before), since a test process has no key window.

## Intents (Wave 6: App Intents and App Shortcuts)

New in the port (deckcraft has no counterpart). The intents that act on the app's windows are here, in
`DCApp/Intents/`; the three that work on a file without a window are in **DCIntentsKit**
(`Packages/DCExtensions/Sources/DCIntentsKit`, no AppKit) and run in the **App Intents extension**
`DeckCraftIntents.appex`, so Shortcuts, Siri and Spotlight don't launch the app for them (DCExtensions/PORT-NOTES.md,
"Intents extension"). The app target adds two files.

| File | What |
|---|---|
| `DCIntentsKit/IntentsEngine.swift` | the window-free work: `PresentationInput` (an `IntentFile`'s bytes), `ExportRequest` (→ `file.export` params), `IntentsEngine.export`/`outline`/`slideCount` (a session of their own per call on a 32 MiB-stack thread, `LargeStack`), `DeckIntentError` |
| `DCIntentsKit/FileIntents.swift` | Export Presentation (PDF slides/notes/handouts with per-page, PPTX, PNG/JPEG of one slide or all; returns `[IntentFile]`), Get Presentation Outline, Get Slide Count: `supportedModes = .background`, `allowedExecutionTargets = .appIntentsExtension` (macOS 27) |
| `DCIntentsKit/IntentsFileOptions.swift` | Export's `AppEnum`s (format, PDF layout, per page) |
| `DCIntentsKit/IntentsRun.swift` | `IntentsRun`: what an intent run from the control channel reported (a no-op elsewhere) |
| `DCIntentsKit/IntentsKitPackage.swift` | `DCIntentsKitPackage: AppIntentsPackage`; `IntentsExtensionSupport.prepare()` (the extension's fonts) |
| `DCApp/Intents/WindowIntents.swift` | Open Presentation, New Presentation (theme or starter), Start Slide Show (from a slide), Add Slide (layout, title, text), Run DeckCraft Command (id + JSON → JSON): main actor, through `AppModel.run` |
| `DCApp/Intents/PresentationEntity.swift` | `PresentationEntity` (an open presentation, by `DocState.uid`) and its query; `IntentsHost` (activate, run, errors) |
| `DCApp/Intents/IntentsOptions.swift` | the slide-layout `AppEnum` and the options providers (themes, starters, command ids) |
| `DCApp/Intents/IntentsPackage.swift` | `DCAppIntentsPackage: AppIntentsPackage`, including `DCIntentsKitPackage` |
| `DCApp/Intents/IntentsFeature.swift` | control methods `intents.run` / `intents.result`: run all eight real intents in the app's process (end-to-end checks without the Shortcuts app; the file intents run here too) |
| `Apps/DeckCraftNative/App/DeckCraftIntentsPackage.swift` | the app's `AppIntentsPackage`, including `DCAppIntentsPackage`: what makes Xcode merge the package's intents into the app's `Metadata.appintents` |
| `Apps/DeckCraftNative/App/DeckCraftIntentShortcuts.swift` | the `AppShortcutsProvider` (7 shortcuts, 2–3 phrases each). It must be in the app target: the merge takes actions, entities and enums from a package, not App Shortcuts (measured: the package's own metadata had 7 `autoShortcuts`, the app's 0, until it moved) |

- **What macOS needs for extension intents named by the app's App Shortcuts** (Apple, "Configuring the runtime
  behavior of your app intents", `IntentExecutionTargets`, and the metadata processor, measured 2026-10-27 with
  Xcode 27.1 / macOS SDK 27.0 on macOS 27.2):
  - The App Shortcuts provider stays in the app, and each `AppShortcut`'s intent must be an action in the **app's**
    `Metadata.appintents` (the processor's "This AppShortcut does not map to a known action"). So the intent types are
    in both bundles: in a shared module (DCIntentsKit) that the app links (through DCApp) and the extension links,
    each with an `AppIntentsPackage` listing `DCIntentsKitPackage`. Apple: "If you place your app intent code in a
    shared framework … use an app intents package"; the action identifier is the type name, the same in both.
  - Which bundle runs it is the system's choice: it "prefers to run a background app intent from your app extension,
    but might run it from your app if the app is already running", and "an app intent in your App Intents extension
    always runs in the background". So the file intents say `supportedModes = .background` (macOS 26), and on macOS
    27 `allowedExecutionTargets = .appIntentsExtension` (`IntentExecutionTargets` is macOS 27 API: the metadata
    records `allowedTargets: [{extensionPointIdentifier: com.apple.appintents-extension}]`). The app's copy of the
    intents is then only metadata for its App Shortcuts (and for `intents.run`, which calls `perform()` directly).
  - The extension is an **ExtensionKit** extension (`com.apple.product-type.extensionkit-extension`, Info.plist
    `EXAppExtensionAttributes.EXExtensionPointIdentifier = com.apple.appintents-extension`, `@main struct …:
    AppIntentsExtension`, as Xcode's macOS "App Intents Extension" template), embedded in `Contents/Extensions`
    (not `PlugIns`), sandboxed.
  - Measured: the app's processor also reads every linked package's static metadata and the embedded extension's
    (`DeckCraftNative.DependencyMetadataFileList`): with `DCAppIntentsPackage.includedPackages = []` the app's
    metadata still listed the three file intents. The package is listed anyway, as Apple documents.
- **Metadata strings are in the main bundle** — of whichever bundle lists the intent. `appintentsmetadataprocessor`
  rejects `LocalizedStringResource(…, bundle: .atURL(Bundle.module.bundleURL))` in titles, descriptions, parameter
  titles, enum and type display representations and short titles ("AppIntents requires 'LocalizedStringResource' to
  use the main bundle"), so those are plain literals. Summaries (`ParameterSummaryString`) and phrases take no bundle
  at all. DCIntentsKit's are therefore in **two** catalogs: the app's `App/Localizable.xcstrings` and the extension's
  `Extensions/Intents/Localizable.xcstrings`. Strings resolved at run time — errors, dialogs, an entity's display
  representation — use the package bundle, per the String Catalog convention (DCApp's, or DCIntentsKit's
  `Resources/Localizable.xcstrings`, which the extension carries as `DeckCraftNative_DCIntentsKit.bundle`).
- **Window-free.** Export and the read intents never touch `AppModel.session`: a fresh `Session` per call, opened from
  the bytes with `FileCommands.openChecked`/`addOpened`, `file.export` run on it, dropped.
- **Tests:** `DCIntentsKitTests/FileIntentsTests.swift` (12 in 2 suites; 9 moved from DCAppTests): PDF slides/notes/handouts page
  counts, PPTX reopens with the same slides, PNG of one slide and JPEG of all, a slide past the end fails before
  writing, outline equals deckcraft's outline export (`content.md`), slide counts against the corpus (`.deckcraft` and
  `.pptx`), damaged files (garbage, empty, a cut zip, a cut pptx) fail cleanly, the export's parameters, an intent's
  file parameter, background-only modes, the kit's run-time strings, control-channel runs. `DCAppTests/IntentsTests.swift`
  (6): Run DeckCraft Command (answers, bad JSON, non-object, unknown id, the command's own failure, a UI command with
  no app), the command ids, New Presentation's and Add Slide's parameters against the engine, the entity.
  `StringsCatalogTests.intentsKitAndExtensionCatalogs`: the kit's, the extension's and the app's catalogs.
- **Control channel check (2026-10-27):** `DeckCraftDev --control 7993 --sample` with `intents.run`: new (Harbor),
  addSlide (→ 2), command `file.info`, open `sample.deckcraft` (8 slides), show from slide 2, slideCount (8), outline,
  export (`sample.pdf`) all `ok`.

## Release and Updates (Wave 6, session A)

- **File map.** craft-update (storytold/craft-libs @495e5971, MIT OR Apache-2.0), which deckcraft's
  `crates/ui-egui/src/updates_ui.rs` drives: `version.rs` `parse`/`is_newer` → `DCAppModel/UpdatesFeed.swift`
  (`UpdateVersion`); `release.rs` `parse_github_release_list`, `release_from_value`, `valid_file_name`,
  `download_url_under`, `safe_release_html_url` → `UpdatesFeed.swift` (`UpdateFeed`, `UpdateRelease`, `UpdateAsset`);
  `lib.rs` `check_for_update` and `http.rs` `refused_until` → `UpdatesCheck.swift` (`UpdateChecker`); `http.rs`'s
  download and `verify_sha256` → `UpdatesDownload.swift` (`UpdateDownloader`); `updater.rs` `Updater` →
  `UpdatesCenter.swift` (`UpdateCenter`, `UpdatePreferences`); `dialog.rs` `StartupPrompt` →
  `DCApp/Updates/UpdatesWindow.swift`; `updates_ui.rs` → `DCApp/Updates/UpdatesFeature.swift`.
  `DCAppModel/UpdatesVersion.swift` is the version (`DCAppVersion.current`, equal to `MARKETING_VERSION`).
- **Native instead of ported.** URLSession (data and download tasks), CryptoKit's SHA-256, `JSONSerialization`
  (per-item tolerance, as serde_json `Value`), UserDefaults for the three preferences, `NSWorkspace.open` mounts the
  DMG, LaunchServices' quarantine properties on the download.
- **Divergences.** deckcraft checks at every start and installs in place (self-update helper, restart). Here the
  automatic check is a preference, **off by default**, at most daily (first look 10 s after launch, then hourly;
  never with `DECKCRAFT_NO_PREFS`), and the update is the notarized DMG, downloaded to Downloads, checked
  (size, GitHub's `digest`), quarantined and opened; the user drags it to Applications. A "Skip This Version" quiets
  automatic checks for that version. Releases are read from `xocialize/DeckCraftNative` (public since 0.1.0)
  (`UpdateSource.releasesRepo`, the one constant). A 404 (no releases, or no repo yet) is "up to date", as
  craft-update's `NotFound`. A window of its own (Software Update), not a sheet: there may be no document window,
  and it never blocks one. Release notes are Markdown's inline syntax; links open only when `https`.
  Debian `~` versions and the `SHA256SUMS.txt` route aren't ported (GitHub tags and `digest` cover a Mac app).
- **Control channel.** `app.checkUpdates` answers at once; `ui.inspect`'s `updates` reports the state
  (`phase`, `version`, `installer`, `error`, `file`, `automatic`, `windowVisible`); `ui.updates {action}` presses
  the window's buttons (`check`, `download`, `cancel`, `retry`, `skip`, `later`). Debug builds take
  `DECKCRAFT_UPDATES_FEED=http://127.0.0.1:PORT/releases.json` (downloads from that origin's `/download/`).
- **Tests.** `DCAppModelTests/UpdatesTests.swift` (27, window-free, stubbed `URLProtocol` per host): versions and
  precedence, the one version number against the project, the feed (newest stable, drafts, links outside the repo,
  caps), the check (up to date, newer, pre-release, malformed JSON, no DMG, network error, rate limit, 404, the
  request's headers), the download (stub server and a file URL: checksum, size, unique names, quarantine), and the
  center (updater.rs: a requested check reports either way, the automatic one stays quiet, a request during it is
  not lost, runs when due, skipped versions, download and open, retry). `DCAppTests/UpdatesWindowTests.swift` (3):
  the command answers at once and opens the window, every state lays out, notes keep inline Markdown.
- **Release.** `Tools/release.sh` (archive → Developer ID export → strict verification of every piece of code →
  notarize and staple the app → DMG with an Applications link, made with `hdiutil create` (deckcraft's
  `makehybrid -hfs` leaves `com.apple.FinderInfo` on every file and an app copied off it fails
  `codesign --verify --strict`) → sign, notarize and staple the DMG → Gatekeeper). `Tools/publish-release.sh`
  (`--dry-run`; never creates the releases repo). The DMG is plain: deckcraft's background is licensed for reuse but
  is titled "DeckCraft" and laid out for `DeckCraft.app` (ATTRIBUTION.md).

## Strings (Wave 6, session D: String Catalogs)

**The convention** (WAVE6-PLAN.md, "String Catalogs"): text in DCApp is `String(localized: "…", bundle: .module)` or
SwiftUI's `Text("…", bundle: .module)`; every SwiftUI title API (Button, Toggle, Picker, TextField, Label, Section,
Menu, `.help`, `.accessibilityLabel`…) gets a `String(localized:…, bundle: .module)`, and a literal that isn't text
(a symbol, "Aa", a percentage) is `Text(verbatim:)`. DCAppModel uses `L10n.text("…")` (or `String(localized:…,
bundle: .module, comment:)` when a comment is needed). Command labels and menu titles shown in the app go through
`L10n.commandLabel(id, english)` / `L10n.menuTitle(english)`: MenuBuilder (menus and items), the palette
(`Palette.items`). Interpolations are String or Int only (Int → `%lld`, locale-grouped: counts and slide numbers;
sizes, years and ids are passed as `String(n)`); Doubles are passed already formatted.

**The exception: App Intents metadata uses the main bundle.** The App Intents metadata processor refuses any
other bundle, so intent titles, descriptions, parameter titles, enum and entity names and short titles in
`DCApp/Intents/*.swift`, `DCIntentsKit` and `Apps/DeckCraftNative/App/*Intent*.swift` are `LocalizedStringResource("…")`
with no `bundle:`; their keys are in `Apps/DeckCraftNative/App/Localizable.xcstrings`, the App Shortcuts phrases in
`App/AppShortcuts.xcstrings`, and DCIntentsKit's also in the App Intents extension's own
`Apps/DeckCraftNative/Extensions/Intents/Localizable.xcstrings` (its main bundle). Intent error and dialog text
that's built at run time uses `bundle: .atURL(Bundle.module.bundleURL)` and lives in DCApp's catalog, or DCIntentsKit's
(`Packages/DCExtensions/Sources/DCIntentsKit/Resources/Localizable.xcstrings`).

| Catalog | Holds | Filled by |
|---|---|---|
| `DCAppModel/Resources/Localizable.xcstrings` | DCAppModel's text | `Tools/l10n/sync.sh` |
| `DCAppModel/Resources/Commands.xcstrings` | every registry command's label (by id), the UI commands, `menu.<Title>` for the menu tree | `Tools/l10n/commands.sh` (a test-backed generator: `StringsCatalogTests` with `DC_L10N_WRITE=1`) |
| `DCApp/Resources/Localizable.xcstrings` | DCApp's text, plurals | `Tools/l10n/sync.sh` |
| `Apps/DeckCraftNative/App/Localizable.xcstrings` | App Intents metadata (main bundle), parameter summaries | `Tools/l10n/sync.sh` (Xcode build) |
| `Apps/DeckCraftNative/App/AppShortcuts.xcstrings` | App Shortcuts phrases | `Tools/l10n/sync.sh` (Xcode build) |
| `Apps/DeckCraftNative/App/InfoPlist.xcstrings` | name, copyright, document and file type names | `Tools/l10n/sync.sh` (from the built Info.plist) |
| `DCIntentsKit/Resources/Localizable.xcstrings` | the file intents' run-time text, plurals | `Tools/l10n/sync.sh` |
| `Apps/DeckCraftNative/Extensions/Intents/Localizable.xcstrings` | the App Intents extension's main bundle: DCIntentsKit's metadata, its parameter summaries | `Tools/l10n/sync.sh` (Xcode build) |

**Extraction is the compiler's.** A target with a String Catalog is compiled with string extraction on, and each
file writes a `.stringsdata` (type-checked keys: `%lld` vs `%@`, and the `comment:`s). `sync.sh` builds DCApp
(`.build-strings`) and the app (Xcode, derived data in `~/Library/Caches/DeckCraftNative/xcode-strings`), splits the
`.stringsdata` by catalog (a DCApp literal whose call names no `bundle:` belongs to the main bundle; outside
`Intents/` that's an error and the script stops), runs `xcstringstool sync`, then `l10n.py`: plural variations from
`Tools/l10n/plurals.json`, every English value written out (so the compiled `en.lproj` holds every key and
`Bundle.localizedString` can be checked), and stale entries with no translation dropped. Re-run it after changing
UI text; the tests fail until you do.

**Plurals** (`plurals.json`): one key per count phrase with the catalog's plural variation (a substitution when
the key has other arguments). Where the converted code didn't branch on 1, `one` keeps the old English
("Inserted 1 slides") so English output is unchanged; correcting it is a catalog edit, no code.

**Product name.** The engine's labels stay deckcraft's (parity); the app shows its own name: `app.about` and
`menu.About DeckCraft` are "About DeckCraftNative" in the Commands catalog (`appNameLabels` in the generator), and
"DeckCraftNative can't find/export/open…", the presenter window title, the print panel's tab and the dialog
fallback title say DeckCraftNative. Text crediting deckcraft is unchanged.

**Tests.** `DCAppModelTests/StringsCatalogTests` (Commands catalog = registry + UI commands + menu tree; every
command has an entry; labels come from the compiled Commands table; every localized literal in DCAppModel and
DCApp has its key in the right catalog, by a source scan that matches interpolations to format specifiers; every
entry is used; no SwiftUI title literal without `bundle:`; every `String(localized:)` names its bundle; App
Shortcuts phrases and InfoPlist document types present; DCAppModel's compiled bundle has every key; plural
variations), `DCAppTests/StringsTests` (DCApp's compiled bundle has every key; plurals; the menu bar's titles come
from the catalogs).

**Pseudo-localization.** `Tools/l10n/pseudo.sh [--control PORT] [--sample]` compiles a build-only `en-XA` table from
each catalog into the built bundles of `.build-strings` (never into the catalogs: `[Śļîðé Šöŕţéŕ]`, format
specifiers kept) and launches DeckCraftDev with `-AppleLanguages '(en-XA)'`; English left on screen bypasses the
catalogs. (DeckCraftDev's main bundle is its folder, and CFBundle doesn't mix localizations, so the script gives
that folder an `en-XA.lproj` too; delete `.build-strings/out/Products/Debug/en-XA.lproj` to run in English again.)

**Layout fixes the pseudo-localization found** (layout only): Settings' labels were clipped at the window's
left edge and AutoCorrect's Replace … With … Add row spilled past both edges (also slightly in English): both
dialogs now take the wide dialog width. SmartArt's category segments overflowed the sheet (in English too): a
form's `.tabs` row shows segments when they fit and a pop-up menu when they don't (`ViewThatFits`). Tried and
rejected: letting every dialog grow to its content (`.frame(minWidth:)`: notes are measured unwrapped, so sheets
came out too short) and the hosting controller's `.minSize` (a constraint-update loop that AppKit aborts).

**Left as is, on purpose:** control-channel answers and command errors (deckcraft's English, scripts compare
them); engine text shown as is (accessibility checker issues, `SchemeSlot` names in Theme Colors, preset, chart,
SmartArt, icon, table-style and layout names from the engine, transition ids on sorter badges); document content
the app writes (the photo album's "Text Box", "Custom Show 1"); QAT labels (persisted, and part of `app.qat`'s
answer); values that are also tags or compared (`InspectorFill.types`, `InspectorController.contextual()`, the
paragraph line-spacing presets); language endonyms; DesignScaffold's own strings ("180 items" in its searchable
picker) — that package isn't localized yet.

**Open items.** Keys shared by different meanings ("Normal", "Center", "Zoom"…) carry several comments; a
translator may need them split into distinct keys. ShowView compares the zoom label to DCApp's "Zoom" while
ShowController produces DCAppModel's: the two must be translated alike. The canvas control channel's `choose`
finds a context-menu item by its (now localized) title. Theme Colors' right-hand colour wells touch the sheet's
edge (English too); the Review inspector's segments clip in a long language.
