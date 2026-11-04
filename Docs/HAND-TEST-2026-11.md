# Hand-test pass: DeckCraftNative 0.1.15

This checklist was written for **0.1.15** (main **49a6464**, the release installed in `/Applications`) on 2026-11-04. It
covers what the suite (2,139+ tests), the alpha gate (`Tools/app/alpha-gate.sh`, run through the control channel) and
the release checks in `PORT-STATUS.md` didn't reach: things a person does in the running app, through its menus,
ribbon, dialogs and inspector. Riskiest first.

**How to run it:**
- Run `/Applications/DeckCraftNative.app` (0.1.15), or a Debug build of the `DeckCraftNative` scheme.
- Fixtures: run `Docs/hand-test/make-fixtures.sh` first. It copies them into `Docs/hand-test/fixtures/` (gitignored)
  from `../DeckCraftNative-Fixtures`: deckcraft's sample deck as `.deckcraft` and `.pptx`, LibreOffice's `.ppt` of it,
  and Apache POI's password-protected copies. None is PowerPoint-saved. The passwords are in the rows.
- Tick each box as you go. For anything wrong, note the step, what you saw, and the Edit › Undo name.
- AppProbe runs the rows it can: `Docs/hand-test/HAND-TEST-2026-11.scenario.md`. Its last run is in Results.

---

## 1. Opening and saving (highest risk: files people keep)

### `.deckcraft` and `.pptx`
- [x] Open `sample.deckcraft`. It shows 8 slides in three sections (Introduction, Science, In the Field), the status bar reads **"Slide 1 of 8"**, and the window is titled with the file's name.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: 8 slide rows, the three sections, "Slide 1 of 8", the title and slide 1's notes.*
- [x] Add a slide to `save-roundtrip.deckcraft` and **File › Save** (⌘S). It saves in place with no dialog; close it, reopen it, and the slide is there.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: no sheet after Save; reopened with "Slide 1 of 9". What the slide holds wasn't compared.*
- [x] Open `save-roundtrip.pptx` (written by deckcraft, not PowerPoint), add a slide and **File › Save**. It saves back as `.pptx` in place; reopened, the slide is there.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: saved in place with no panel or format question; reopened with 9 slides. The XML wasn't inspected.*
- [ ] **File › Save As…** to the other format, `.pptx` ↔ `.deckcraft`. The save panel offers both; the new file opens and matches.
- [ ] Save a deck with a chart as `.pptx` and open it in PowerPoint. It opens with **no repair prompt** (the Wave 5 finding, fixed after Wave 6).
- [x] **Two presentations side by side** (0.1.13's crash): open `sample.deckcraft` and `sample.pptx`, then **File › New Presentation** (⌘N). Three windows, no crash.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: three windows, still open 2 s later; the new one is titled "Untitled" (Results 4).*

### Password protection (0.1.7)
- [x] Open `protected-ascii.pptx`. It asks for the password. A wrong one says **"The password is incorrect. Passwords are case-sensitive."** and asks again; `Password1` opens its 5 slides.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the prompt names the file; the wrong password gets that message; Password1 opens 5 slides.*
- [x] Open `protected-accents.pptx` with `Tëst-pässwörd` (accented letters typed into the prompt). It opens.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: typed through accessibility, the accented password opened it.*
- [x] **Cancel** at the password prompt. Nothing opens and no error appears.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: no window, no prompt and no alert afterwards.*
- [ ] **File › Passwords…** sets a password to open (typed twice) and one to modify. Save as `.pptx`, reopen: it asks. Save the protected deck as `.deckcraft`: DeckCraftNative says it won't be protected.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the sheet opens with both passwords and their Verify fields (screenshot). Saving with them goes through Save As, so it's a person's.*
- [ ] A presentation with a **password to modify** offers **Read Only**, which opens a copy you can save under another name.

### PowerPoint 97–2003 `.ppt` (0.1.8)
- [ ] Open `corpus-sample.ppt`. It opens as an untitled converted copy ("corpus-sample", 8 slides), and the **status line says what was converted** (picture bullets, one embedded object as a picture). The original isn't changed; Save asks for a name.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: fails: the copy opens (8 slides, untitled), but its status bar never shows the message (Results 2).*
- [x] Open `protected-default.ppt` (PowerPoint's default password). It opens **without asking**.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: no prompt; 8 slides, as a converted copy.*
- [x] Open `damaged.ppt` (the sample's `.ppt` cut off after 5,463 bytes). An error says it can't be opened, and the app keeps running.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: "The document “damaged.ppt” could not be opened." with OK; the app kept running. The alert gives no reason.*

---

## 2. The ribbon's Insert tab

- [x] **Insert › New Slide** (the ribbon button, the menu, ⇧⌘N). A slide is added after the current one ("Slide 2 of 9"). Undo takes it away, Redo puts it back.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the ribbon button, the menu and ⇧⌘N each added one after the current slide; Undo and Redo moved the count. Undo's name: Results 1.*
- [x] **Insert › Table…** (menu) asks for columns and rows (0.1.14). Insert adds that table, and the **Table Design** and **Layout** tabs appear. The ribbon's **Table** button adds a 3 × 3 table at once; its arrow offers a grid.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the dialog, a 3 × 4 table (Table Design and Layout tabs), Undo, and the ribbon's Table adding one at once. The ribbon's grid, and the table's shape on the slide, weren't checked.*
- [x] **Chart** adds a chart, and the **Chart Design** tab appears.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the Chart Design tab appears. The chart itself is a person's check (section 2's last row).*
- [x] **Format › Chart › Chart Elements** in the inspector (0.1.15): the Chart Title switch and its text, the Legend position, Data Labels and Gridlines. Each change shows on the chart and is one undo step.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the switches read on/off/on; Data Labels on, Legend Right; one Undo took back only the legend, the next Data Labels. Whether each change shows on the chart wasn't checked (the canvas).*
- [x] **Chart Design › Add Chart Element** (0.1.15): Chart Title (None, Above Chart), Legend (None, Right, Top, Left, Bottom), Data Labels (None, Show), Gridlines (None, Major Gridlines).
  *AppProbe 2026-11-04, on this Mac and in a clean VM: all four items and their choices; Legend › Left set the inspector's Legend to Left.*
- [x] **SmartArt** asks for a graphic and its items ("Choose a SmartArt Graphic"). Insert adds it, and the **SmartArt Design** tab appears.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the sheet, its default items, and the SmartArt Design tab after Insert. Its pop-up reads "kind" to VoiceOver (Results 3).*
- [x] **Text Box** and **Comment** (the comment sheet's Post shows it in the Comments pane).
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Text Box selected a new box (Shape Format tab); the posted comment's text shows in the window.*
- [ ] **Shapes**, **Icons**, **WordArt**, **Equation**, **Symbol**, **Zoom**, **Header & Footer**: each adds what it says, drawn as its gallery tile shows.
- [ ] **Pictures**, **Video** and **Audio** (the open panel): the file is placed, a video gets a poster, VP9/WebM plays.
- [ ] What each insert draws on the slide is right: position, size, text, and the selection handles around it.

---

## 3. Slide Show and Reading View

- [x] **Slide Show** (the status bar's button, ⌘Enter): it fills the screen. → and Space step through each slide's animations, then the slides; **Esc** ends it, and the editor shows the slide you stopped on.
  *AppProbe 2026-11-04, in a clean VM: → and Space, Esc, and the editor on slide 2 afterwards. What the show draws and its transitions weren't checked.*
- [ ] Transitions play, and going **back** plays a slide's transition in reverse (0.1.9). Morph on slide 5 of the sample.
- [ ] **Presenter view** on a second display, with the Next slide preview; the show doesn't slow down (0.1.9).
- [x] **Slide Show › Set Up Slide Show…** opens its dialog (0.1.14), with **Keep mouse cursor visible** (0.1.9).
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the sheet opens, with Keep mouse cursor visible.*
- [x] **Reading View** (status bar): a window reading "Slide N of M". **Forward** plays the animations, then moves on; **Back** goes back; **Close** returns to the editor on that slide.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Slide 1 → 2, slide 2's bullets one press at a time, then 3; Back to 2; Close leaves the editor on slide 2. What it draws wasn't judged.*

---

## 4. The inspector

- [x] **Arrange › Selection Pane** lists the slide's shapes; choosing one selects it, and its contextual tab (**Shape Format**) appears.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: slide 1's three shapes (Aurora Band, Subtitle 2, Title 1); choosing Title 1 enables Arrange and shows Shape Format. A new install starts with the task pane closed; Home › Selection Pane opens it.*
- [x] **Arrange › Rotate Right 90°** turns it: **Format › Size** reads Rotation 90°, and Undo brings it back to 0°.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Rotation read 90°, then 0° after Undo.*
- [x] **Format › Size**: typing a Width changes it, and Scale Width follows.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Width 10" → 5", Scale Width 50%.*
- [ ] **Format › Effects** (0.1.10) shows Shadow, Glow and Soft Edges presets as drawn tiles, the one in use marked; choosing one applies it.
- [x] **Format › Fill** (0.1.9) offers **Slide background fill**.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the option is there and takes the click. How it draws wasn't judged.*
- [x] **Format Painter** (0.1.11) is a button with a separate "Format Painter options" menu.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: a button and a "Format Painter options" menu button.*
- [ ] Every inspector control has a name VoiceOver reads, Chart Elements included (0.1.11).
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Chart Elements' five controls are labelled through AXTitleUIElement (Chart Title, Title, Legend, Data Labels, Gridlines), which VoiceOver reads. Only Chart Elements was checked.*

---

## 5. Undo

- [ ] **Edit › Undo and Redo name the action**, as macOS apps and PowerPoint do: "Undo New Slide", "Redo New Slide" (PLAN.md §3: `NSUndoManager` shows the menu titles).
  *AppProbe 2026-11-04, on this Mac and in a clean VM: fails: "Undo", then "Redo", with no name (Results 1).*
- [x] Undo and Redo through a longer session (a slide, a table, a rotation): each step comes back in order, and Redo repeats them.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: rotation, slide, table: three Undos took them back in order, three Redos repeated them. The names: Results 1.*

---

## 6. On the slide canvas (needs a person, or AppProbe's control-channel step)

The canvas is a Metal view with no accessibility elements, so these need a person until AppProbe can call deckcraft's
loopback control channel (see the scenario's note for the methods).
- [ ] Click a shape to select it; drag it (smart guides appear); resize it by a handle; rotate it by its handle. Undo names each.
- [ ] Double-click a text box and type, including an accented letter and dictation; the text wraps and autofits.
- [ ] Draw a shape from the Shapes gallery by dragging on the slide.
- [ ] Slide Sorter: select several slides and drag them together (0.1.9).

---

## 7. Everyday flows (lower risk)

- [x] A launch with nothing to open shows the **Start** window: Home, New and Open, the theme tiles and recent files. A tile makes a presentation.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: the Start window, its theme and template tiles, and a new presentation from File › New Presentation. A tile's press does make one, but over accessibility it answers "not supported" as the window closes, so the run doesn't use it; the recent list wasn't read.*
- [x] **Slide Sorter** and **Normal** views from the status bar; sections fold and unfold.
  *AppProbe 2026-11-04, on this Mac and in a clean VM: Science folds and unfolds; Slide Sorter then Normal (notes back). The sorter was screenshotted, not judged.*
- [ ] Export to PDF, pictures and `.pptx` (File › Export…); print to PDF.
- [ ] Spelling in the status bar; Find and Replace.
- [ ] A preview language (System Settings › Language & Region › Applications): menus, ribbon and inspector read naturally.
- [ ] **Help › Check for Updates…** reports 0.1.15 up to date.

---

## Results

AppProbe ran `Docs/hand-test/HAND-TEST-2026-11.scenario.md` (40 rows) against the installed 0.1.15 on 2026-11-04:
- **On this Mac** (3 min 46 s): 26 passed, 4 failed (rows 1–4 below), 3 for a person, 6 skipped (the slide show
  isn't run here), and 1 run error, AppProbe's own (a row's first action lost the just-launched app; alone it
  passed). The report stays local: it shows this Mac's recent files and paths.
- **In a clean macOS 26 VM** (about 5 min, clone to deletion): 28 passed, the same 4 failed, 3 for a person,
  5 skipped. The report and screenshots are in `Docs/hand-test/runs/2026-11-04-vm/`.
- The VM found what this Mac hid: a new install starts with the task pane closed and Format on its Fill & Line tab,
  so the scenario opens both itself.

| # | Step | What happened | Undo name | Task filed |
|---|------|---------------|-----------|------------|
| 1 | Insert › New Slide, then Edit (also after Rotate Right 90°, Table…, Chart Elements) | Edit's first item reads just **"Undo"**, and after Undo, Redo reads just "Redo"; the toolbar's Undo tooltip names nothing either. The engine has the name (`document.inspect` → `undo: "New Slide"`), but nothing in DCApp sets the menu title (PLAN.md §3 meant `NSUndoManager`'s titles to show it). Every Undo-name check in this checklist waits on this. | (none; engine: "New Slide") | — (DeckCraftNative isn't on the bridge roster) |
| 2 | Open `corpus-sample.ppt` on a fresh launch | The converted copy opens (8 slides), but its status bar never shows the conversion message, though `ui.inspect.status` holds it. With other presentations open, the message shows in **their** status bars instead ("“corpus-sample.ppt” is a PowerPoint 97–2003 presentation: it was converted…" in `sample.pptx`'s window), not the new one's. `AppModel.status` is app-wide, and `PresentationDocument.swift:123` sets it while the file is read, probably before the new window's status bar exists. | (none) | — |
| 3 | Insert › SmartArt (the dialog) | The graphic pop-up is announced as **"kind"** (its AXDescription): `DialogFormView.swift:188,193` uses a `.tabs` field's form key as the Picker's label. The items field reads "SmartArt items, SmartArt items". | (none) | — |
| 4 | File › New Presentation (⌘N) | Names the window **"Untitled"**, then "Untitled 2", while a Start window tile makes **"Presentation1"** (the engine's name, `Engine.swift:852`, as PowerPoint names them). | (none) | — |
| 5 | Insert › Chart on a new Title and Content slide (needs a person to judge) | The chart lands over the empty title and content placeholders ("Click to add title" shows through it), instead of filling the content placeholder as PowerPoint does. Note for a person, not checked further. | Chart… | — |
|   |      |               |           |            |
