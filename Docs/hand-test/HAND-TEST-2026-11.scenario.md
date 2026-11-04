# Hand-test scenarios: HAND-TEST-2026-11

The rows of `Docs/HAND-TEST-2026-11.md` that AppProbe can run, each with its steps. A row's text matches its checklist
row, so a run ticks the right box and the report names the line. Rows needing a person's eye run their steps, then say
`judge: human` and attach screenshots.

DeckCraftNative has no DesignScaffoldProbe host, so every check here reads the accessibility tree: the status bar's
"Slide N of M", window titles, the ribbon's tabs (contextual ones read "Chart Design, contextual"), the inspector's
fields, sheets and alerts, and the menus. What's drawn on the Metal canvas isn't readable that way: see "The canvas"
at the end.

Run it from a Claude session (the `appprobe` MCP server's `checklist` tool) or the shell, after copying the fixtures:

```bash
Docs/hand-test/make-fixtures.sh                                                         # fixtures, from ../DeckCraftNative-Fixtures
appprobe checklist scenario=Docs/hand-test/HAND-TEST-2026-11.scenario.md                # all rows, report only
appprobe checklist scenario=… rows=3,7-9                                                # some rows
appprobe checklist scenario=… launch=/path/DeckCraftNative.app checklist=Docs/HAND-TEST-2026-11.md fill=true
FULL_SCREEN=1 appprobe checklist scenario=…                                             # with the slide show row
AppProbe/VM/run.sh --app /Applications/DeckCraftNative.app --scenario Docs/hand-test/HAND-TEST-2026-11.scenario.md \
  --checklist Docs/HAND-TEST-2026-11.md --data FULL_SCREEN=Docs/hand-test/fixtures       # in a throwaway VM
```

Every row starts with a fresh launch, so one row's leftovers never decide the next. Documents are opened with the
`open` step (an Open Documents event to the launched app), never through the open panel. The slide show fills every
display, so its row runs only where `FULL_SCREEN` is set: in the VM, or when you choose to on your own Mac. The VM
needs `--checklist` (the checklist sits above the scenario's folder, which is all `run.sh` copies in). Host runs add
the fixtures to the app's recent files. If `run.sh` says Terminal "cannot be opened" in the guest, run it again: on
2026-11-04 it opened Terminal before the guest had logged in (AppProbe's to fix; a copy that waits for `gui/501` ran).

```scenario
app: DeckCraftNative
launch: /Applications/DeckCraftNative.app
args: ["-ApplePersistenceIgnoreState", "YES"]
window: {"x": 200, "y": 100, "width": 1600, "height": 1000}
checklist: ../HAND-TEST-2026-11.md
fixtures: ./fixtures
fresh: true
```

## 1. Opening and saving

### `.deckcraft` and `.pptx`

- [ ] Open `sample.deckcraft`. It shows 8 slides in three sections (Introduction, Science, In the Field), the status bar reads **"Slide 1 of 8"**, and the window is titled with the file's name.
  ```steps
  open ${fixtures}/sample.deckcraft
  until windows.0.title == "sample.deckcraft"
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1  # the status bar
  expect find("role=cell name='Slide 8' exact=true").count == 1  # 8 slides in the navigator
  expect find("role=cell name=Introduction exact=true").count == 1  # the three sections
  expect find("role=cell name=Science exact=true").count == 1
  expect find("role=cell name='In the Field' exact=true").count == 1
  expect find("role=textarea name=Notes").0.value contains "Welcome everyone"  # slide 1's notes
  ```
- [ ] Add a slide to `save-roundtrip.deckcraft` and **File › Save** (⌘S). It saves in place with no dialog; close it, reopen it, and the slide is there.
  ```steps
  open ${fixtures}/save-roundtrip.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  menu "Insert › New Slide" press
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1
  menu "File › Save" press
  pause 1000
  expect find("surface=app role=sheet").count == 0  # saved in place: no save panel
  menu "File › Close" press
  until windows.*.title !contains ["save-roundtrip.deckcraft"]
  open ${fixtures}/save-roundtrip.deckcraft
  until windows.0.title == "save-roundtrip.deckcraft"
  until find("role=statictext name='Slide 1 of 9' exact=true").count == 1  # the new slide came back
  # Back to 8 slides, so the row runs again without make-fixtures.sh (which restores the file itself).
  menu "Edit › Delete Slide" press
  until find("role=statictext text='of 8'").count == 1
  menu "File › Save" press
  pause 1000
  ```
- [ ] Open `save-roundtrip.pptx` (written by deckcraft, not PowerPoint), add a slide and **File › Save**. It saves back as `.pptx` in place; reopened, the slide is there.
  ```steps
  open ${fixtures}/save-roundtrip.pptx
  until windows.0.title == "save-roundtrip.pptx"
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  menu "Insert › New Slide" press
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1
  menu "File › Save" press
  pause 1500
  expect find("surface=app role=sheet").count == 0  # saved in place, as .pptx, with no panel or format question
  menu "File › Close" press
  until windows.*.title !contains ["save-roundtrip.pptx"]
  open ${fixtures}/save-roundtrip.pptx
  until windows.0.title == "save-roundtrip.pptx"
  until find("role=statictext name='Slide 1 of 9' exact=true").count == 1  # the new slide came back from the .pptx
  # Back to 8 slides, so the row runs again without make-fixtures.sh (which restores the file itself).
  menu "Edit › Delete Slide" press
  until find("role=statictext text='of 8'").count == 1
  menu "File › Save" press
  pause 1500
  ```
- [ ] **File › Save As…** to the other format, `.pptx` ↔ `.deckcraft`. The save panel offers both; the new file opens and matches.
  ```steps
  skip: Save As goes through the system save panel, which AppProbe can't point at a folder (keys don't reach it)
  ```
- [ ] Save a deck with a chart as `.pptx` and open it in PowerPoint. It opens with **no repair prompt** (the Wave 5 finding, fixed after Wave 6).
  ```steps
  skip: needs PowerPoint, the black-box oracle (Tools/pptx/powerpoint-sweep.sh), on the operator's Mac
  ```
- [ ] **Two presentations side by side** (0.1.13's crash): open `sample.deckcraft` and `sample.pptx`, then **File › New Presentation** (⌘N). Three windows, no crash.
  ```steps
  open ${fixtures}/sample.deckcraft
  until windows.*.title contains ["sample.deckcraft"]
  open ${fixtures}/sample.pptx
  until windows.*.title contains ["sample.pptx"]
  menu "File › New Presentation" press
  until windows.count == 3 timeout=15000  # three presentation windows
  pause 2000
  expect windows.count == 3  # still running, and nothing closed
  expect windows.*.title contains ["sample.deckcraft"]
  expect windows.*.title contains ["sample.pptx"]
  set newTitle = windows.0.title
  note "The new presentation's window is titled ${newTitle}."
  ```

### Password protection

- [ ] Open `protected-ascii.pptx`. It asks for the password. A wrong one says **"The password is incorrect. Passwords are case-sensitive."** and asks again; `Password1` opens its 5 slides.
  ```steps
  open ${fixtures}/protected-ascii.pptx
  until find("surface=app role=textfield name=Password exact=true").count == 1  # the password prompt
  expect find("surface=app role=statictext text=protected-ascii.pptx").count == 1  # naming the file
  act surface=app role=textfield name=Password exact=true action=set_value value=wrong commit=none
  act surface=app role=button name=Open exact=true action=press
  until find("surface=app role=statictext text='The password is incorrect. Passwords are case-sensitive.'").count == 1  # asks again, saying why
  act surface=app role=textfield name=Password exact=true action=set_value value=Password1 commit=none
  act surface=app role=button name=Open exact=true action=press
  until windows.*.title contains ["protected-ascii.pptx"] timeout=20000
  until find("role=statictext name='Slide 1 of 5' exact=true").count == 1  # its 5 slides
  ```
- [ ] Open `protected-accents.pptx` with `Tëst-pässwörd` (accented letters typed into the prompt). It opens.
  ```steps
  open ${fixtures}/protected-accents.pptx
  until find("surface=app role=textfield name=Password exact=true").count == 1
  act surface=app role=textfield name=Password exact=true action=set_value value="Tëst-pässwörd" commit=none
  act surface=app role=button name=Open exact=true action=press
  until windows.*.title contains ["protected-accents.pptx"] timeout=20000  # the accented password opened it
  expect find("surface=app role=statictext text='password is incorrect'").count == 0
  ```
- [ ] **Cancel** at the password prompt. Nothing opens and no error appears.
  ```steps
  open ${fixtures}/protected-ascii.pptx
  until find("surface=app role=textfield name=Password exact=true").count == 1
  act window=0 role=button name=Cancel exact=true action=press  # the prompt is the front window
  pause 1500
  expect windows.*.title !contains ["protected-ascii.pptx"]  # nothing opened
  expect find("surface=app role=textfield name=Password exact=true").count == 0  # the prompt went away
  expect find("surface=app role=dialog").count == 0  # and no error alert
  ```
- [ ] **File › Passwords…** sets a password to open (typed twice) and one to modify.
  ```steps
  judge: human
  partial: saving with the password and reopening (Save As goes through the save panel)
  open ${fixtures}/sample.pptx
  until windows.0.title == "sample.pptx"
  menu "File › Passwords…" press
  until find("surface=app role=sheet").count == 1
  shot "File › Passwords…"
  note "Check the sheet asks for each password twice, then save as .pptx through Save As and reopen it."
  ```

### PowerPoint 97–2003 `.ppt`

- [ ] Open `corpus-sample.ppt`. It opens as an untitled converted copy ("corpus-sample", 8 slides), and the **status line says what was converted** (picture bullets, one embedded object as a picture). The original isn't changed; Save asks for a name.
  ```steps
  open ${fixtures}/corpus-sample.ppt
  until windows.0.title == "corpus-sample" timeout=30000  # an untitled copy, not the .ppt itself
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  pause 500
  # The message shows for 6 seconds (StatusBar.swift); read at once.
  expect find("surface=app role=statictext text='was converted and opened as a copy'").count > 0  # the status line says what was converted
  ```
- [ ] Open `protected-default.ppt` (PowerPoint's default password). It opens **without asking**.
  ```steps
  open ${fixtures}/protected-default.ppt
  until windows.0.title == "protected-default" timeout=30000  # opened, as a converted copy
  expect find("surface=app role=textfield name=Password exact=true").count == 0  # no password asked
  expect find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  ```
- [ ] Open `damaged.ppt` (the sample's `.ppt` cut off after 5,463 bytes). An error says it can't be opened, and the app keeps running.
  ```steps
  open ${fixtures}/damaged.ppt
  until find("surface=app role=dialog").count == 1 timeout=30000  # an error
  set message = find("surface=app role=dialog role=statictext").*.name
  note "The error reads: ${message}"
  shot "the error for damaged.ppt"
  act surface=app role=button name=OK exact=true action=press
  pause 1000
  expect windows.count >= 1  # the app keeps running
  expect windows.*.title !contains ["damaged"]
  ```

## 2. The ribbon's Insert tab

- [ ] **Insert › New Slide** (the ribbon button, the menu, ⇧⌘N). A slide is added after the current one ("Slide 2 of 9"). Undo takes it away, Redo puts it back.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name="New Slide" exact=true action=press  # the ribbon's button
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1  # added after slide 1
  menu "Insert › New Slide" press  # the menu
  until find("role=statictext name='Slide 3 of 10' exact=true").count == 1
  keys cmd+shift+n  # the shortcut
  until find("role=statictext name='Slide 4 of 11' exact=true").count == 1
  menu "Edit › Undo*" press
  until find("role=statictext text='of 10'").count == 1  # Undo takes one away
  menu "Edit › Redo*" press
  until find("role=statictext text='of 11'").count == 1  # Redo puts it back
  ```
- [ ] **Insert › Table…** (menu) asks for columns and rows (0.1.14). Insert adds that table, and the **Table Design** and **Layout** tabs appear.
  ```steps
  partial: the ribbon's Table arrow and its grid; the table's 3 × 4 shape on the slide
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  menu "Insert › Table…" press
  until find("role=textfield name='Number of columns:' exact=true").count == 1  # asks for columns and rows
  act role=textfield name="Number of columns:" exact=true action=set_value value=3
  act role=textfield name="Number of rows:" exact=true action=set_value value=4
  set insert = find("role=button name=Insert exact=true").last.ref  # the sheet's (a folded ribbon group is named Insert too)
  act ref=${insert} action=press
  until find("role=radiobutton name='Table Design, contextual' exact=true").count == 1  # the Table Design tab
  expect find("role=radiobutton name='Layout, contextual' exact=true").count == 1  # and Layout
  menu "Edit › Undo*" press
  until find("role=radiobutton name='Table Design, contextual' exact=true").count == 0  # Undo removes the table
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Table exact=true action=press  # the ribbon's Table button: a 3 × 3 table at once
  until find("role=radiobutton name='Table Design, contextual' exact=true").count == 1
  expect find("surface=app role=sheet").count == 0
  ```
- [ ] **Chart** adds a chart, and the **Chart Design** tab appears.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Chart exact=true action=press
  until find("role=radiobutton name='Chart Design, contextual' exact=true").count == 1  # the Chart Design tab
  ```
- [ ] **Format › Chart › Chart Elements** in the inspector (0.1.15): the Chart Title switch and its text, the Legend position, Data Labels and Gridlines. Each change shows on the chart and is one undo step.
  ```steps
  partial: that each change shows on the chart (the canvas)
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Chart exact=true action=press
  until find("role=radiobutton name='Chart Design, contextual' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name=Chart exact=true action=press  # Format's Chart tab (a new install opens Fill & Line)
  until find("role=heading name='Chart Elements' exact=true").count == 1
  # AppProbe reads a control's name from AXTitle or AXDescription; these are labelled through AXTitleUIElement, which
  # VoiceOver reads, so here they're found in order.
  expect find("role=switch").*.value == ["1", "0", "1"]  # Chart Title on, Data Labels off, Gridlines on
  set dataLabels = find("role=switch").1.ref
  act ref=${dataLabels} action=press
  until find("role=switch").1.value == "1"  # Data Labels on
  set legend = find("role=popupbutton value=Bottom").0.ref
  act ref=${legend} action=pick value=Right
  until find("role=popupbutton value=Right").count == 1  # the legend moves right
  menu "Edit › Undo*" press
  until find("role=popupbutton value=Bottom").count == 1  # one Undo takes back only the legend
  expect find("role=switch").1.value == "1"  # and leaves Data Labels on
  menu "Edit › Undo*" press
  until find("role=switch").1.value == "0"  # the next takes back Data Labels
  ```
- [ ] **Chart Design › Add Chart Element** (0.1.15): Chart Title (None, Above Chart), Legend (None, Right, Top, Left, Bottom), Data Labels (None, Show), Gridlines (None, Major Gridlines).
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Chart exact=true action=press
  until find("role=radiobutton name='Chart Design, contextual' exact=true").count == 1
  act role=radiobutton name="Chart Design, contextual" exact=true action=press
  until find("role=button name='Add Chart Element' exact=true").count == 1
  act role=button name="Add Chart Element" exact=true action=press
  until find("surface=app role=menuitem name='Chart Title' exact=true").count == 1  # the menu, with its four items
  expect find("surface=app role=menuitem name=Legend exact=true").0.ref matches "^A/0/"
  expect find("surface=app role=menuitem name='Data Labels' exact=true").0.ref matches "^A/0/"
  expect find("surface=app role=menuitem name=Gridlines exact=true").0.ref matches "^A/0/"  # (the View menu has a Gridlines too; this one is in the window's menu)
  expect find("surface=app role=menuitem name='Above Chart' exact=true").0.ref matches "^A/0/"  # Chart Title › None, Above Chart
  expect find("surface=app role=menuitem name=Top exact=true").0.ref matches "^A/0/"  # Legend › None, Right, Top, Left, Bottom
  expect find("surface=app role=menuitem name=Bottom exact=true").0.ref matches "^A/0/"
  expect find("surface=app role=menuitem name=Show exact=true").0.ref matches "^A/0/"  # Data Labels › None, Show
  expect find("surface=app role=menuitem name='Major Gridlines' exact=true").0.ref matches "^A/0/"  # Gridlines › None, Major Gridlines
  # Menu items are matched in the window's menu (refs under A/0/): Top, Bottom, Show and Left are in the menu bar too.
  # Legend › Left: the first "Left" is this menu's.
  set left = find("surface=app role=menuitem name=Left exact=true").0.ref
  act ref=${left} action=press
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name=Chart exact=true action=press
  until find("role=popupbutton value=Left").count == 1  # the inspector's Legend now reads Left
  ```
- [ ] **SmartArt** asks for a graphic and its items ("Choose a SmartArt Graphic"). Insert adds it, and the **SmartArt Design** tab appears.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=SmartArt exact=true action=press
  until find("role=statictext name='Choose a SmartArt Graphic' exact=true").count == 1
  expect find("role=textfield text='SmartArt items'").0.value contains "Plan"  # the items, one per line
  set insert = find("role=button name=Insert exact=true").last.ref  # the sheet's
  act ref=${insert} action=press
  until find("role=radiobutton name='SmartArt Design, contextual' exact=true").count == 1
  ```
- [ ] **Text Box** and **Comment** (the comment sheet's Post shows it in the Comments pane).
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name="Text Box" exact=true action=press
  until find("role=radiobutton name='Shape Format, contextual' exact=true").count == 1  # a text box, selected
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Comment exact=true action=press
  until find("role=statictext name='New Comment' exact=true").count == 1
  act role=textfield name="Comment, Comment" exact=true action=set_value value="Check this number" commit=none
  act role=button name=Post exact=true action=press
  until find("text='Check this number'").count > 0  # the comment, in the Comments pane
  ```
- [ ] What each insert draws on the slide is right: position, size, text, and the selection handles around it.
  ```steps
  judge: human
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name="New Slide" exact=true action=press
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1
  act role=button name=Chart exact=true action=press
  until find("role=radiobutton name='Chart Design, contextual' exact=true").count == 1
  resize width=1600 height=1000  # a document window opens at 1080 × 740; bigger, then fitted, the whole slide shows
  act role=button name="Fit slide to current window" exact=true action=press
  pause 500
  shot "a chart inserted on a new slide"
  judge "Is there a bar or column chart on the slide in the middle of the window, with selection handles around it?" expect=yes
  note "The canvas is Metal: nothing on it is in the accessibility tree. ui.render / slide.inspect would check it (see the end)."
  ```

## 3. Slide Show and Reading View

- [ ] **Slide Show** (the status bar's button, ⌘Enter): it fills the screen. → and Space step through each slide's animations, then the slides; **Esc** ends it, and the editor shows the slide you stopped on.
  ```steps
  needs: FULL_SCREEN
  # FULL_SCREEN: the show covers every display. Set it in the VM (run.sh --data FULL_SCREEN=DIR) or when you want it.
  partial: what the show draws (Metal) and its transitions
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=button name="Slide Show" exact=true action=press
  until windows.count == 2  # the show's window, over everything
  pause 1500
  keys right
  pause 1500
  keys space
  pause 1500
  keys escape
  until windows.count == 1  # Esc ends it
  # → went to slide 2, and Space played its first bullet (slide 2's animation has four steps).
  until find("role=statictext name='Slide 2 of 8' exact=true").count == 1  # the editor shows the slide the show stopped on
  ```
- [ ] **Slide Show › Set Up Slide Show…** opens its dialog (0.1.14), with **Keep mouse cursor visible** (0.1.9).
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  menu "Slide Show › Set Up Slide Show…" press
  until find("surface=app role=sheet").count == 1  # its dialog
  expect find("surface=app role=checkbox text='Keep mouse cursor visible'").count == 1
  shot "Set Up Slide Show"
  act surface=app role=button name=Cancel exact=true action=press
  ```
- [ ] **Reading View** (status bar): a window reading "Slide N of M". **Forward** plays the animations, then moves on; **Back** goes back; **Close** returns to the editor on that slide.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=button name="Reading View" exact=true action=press
  until windows.0.title == "Reading View"
  until find("window='Reading View' role=statictext name='Slide 1 of 8' exact=true").count == 1
  act window="Reading View" role=button name=Forward exact=true action=press
  until find("window='Reading View' role=statictext name='Slide 2 of 8' exact=true").count == 1
  # Slide 2 has one animation of four steps: Forward plays them before it moves on.
  act window="Reading View" role=button name=Forward exact=true action=press
  pause 800
  expect find("window='Reading View' role=statictext name='Slide 2 of 8' exact=true").count == 1  # still on slide 2: the animation's first step
  until find("window='Reading View' role=statictext name='Slide 3 of 8' exact=true").count == 1 do act window="Reading View" role=button name=Forward exact=true action=press tries=16  # a press while a bullet is still animating finishes it, as in PowerPoint
  act window="Reading View" role=button name=Back exact=true action=press
  until find("window='Reading View' role=statictext name='Slide 2 of 8' exact=true").count == 1  # Back goes back
  act window="Reading View" role=button name=Close exact=true action=press
  until windows.*.title !contains ["Reading View"]
  until find("role=statictext name='Slide 2 of 8' exact=true").count == 1  # the editor, on that slide
  ```

## 4. The inspector

- [ ] **Arrange › Selection Pane** lists the slide's shapes; choosing one selects it, and its contextual tab (**Shape Format**) appears.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  set shapes = find("role=button text='Lock '").count
  expect $shapes == 3  # slide 1's three shapes, each with Hide and Lock
  expect find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == false  # nothing selected yet
  set first = find("role=button text='Lock '").*.name
  note "Slide 1's shapes, top first: ${first}"
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true  # selected
  expect find("role=radiobutton name='Shape Format, contextual' exact=true").count == 1  # its contextual tab
  ```
- [ ] **Arrange › Rotate Right 90°** turns it: **Format › Size** reads Rotation 90°, and Undo brings it back to 0°.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true
  act role=checkbox name="Rotate Right 90°" exact=true action=press
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name=Size exact=true action=press
  until find("role=textfield name='Rotation, Rotation value' exact=true").0.value == "90°"  # turned
  menu "Edit › Undo*" press
  until find("role=textfield name='Rotation, Rotation value' exact=true").0.value == "0°"  # Undo brings it back
  ```
- [ ] **Format › Size**: typing a Width changes it, and Scale Width follows.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name=Size exact=true action=press
  until find("role=textfield name='Width, Width value' exact=true").count == 1
  set before = find("role=textfield name='Width, Width value' exact=true").0.value
  act role=textfield name="Width, Width value" exact=true action=set_value value=5
  until find("role=textfield name='Width, Width value' exact=true").0.value matches "^5"  # the width changes (to 5")
  expect find("role=textfield name='Scale Width, Scale Width value' exact=true").0.value != "100%"  # Scale Width follows
  set scale = find("role=textfield name='Scale Width, Scale Width value' exact=true").0.value
  note "Width ${before} → 5\", Scale Width ${scale}."
  ```
- [ ] **Format › Effects** (0.1.10) shows Shadow, Glow and Soft Edges presets as drawn tiles, the one in use marked; choosing one applies it.
  ```steps
  judge: human
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true
  act role=radiobutton name=Format exact=true action=press
  resize width=1600 height=1000  # a document window opens at 1080 × 740; bigger, then fitted, the whole slide shows
  act role=button name="Fit slide to current window" exact=true action=press
  act role=radiobutton name=Effects exact=true action=press
  pause 800
  shot "Format › Effects for the title"
  note "Check each preset is drawn as a tile, the one in use is marked, and a click on another applies it."
  ```
- [ ] **Format › Fill** (0.1.9) offers **Slide background fill**.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name="Fill & Line" exact=true action=press
  until find("role=radiobutton name='Slide background fill' exact=true").count == 1
  act role=radiobutton name="Slide background fill" exact=true action=press
  until find("role=radiobutton name='Slide background fill' exact=true").0.value == "1"  # chosen
  ```
- [ ] **Format Painter** (0.1.11) is a button with a separate "Format Painter options" menu.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  act role=radiobutton name=Format exact=true action=press
  until find("role=button name='Format Painter' exact=true").count == 1
  expect find("role=menubutton name='Format Painter options' exact=true").count == 1
  ```

- [ ] Every inspector control has a name VoiceOver reads, Chart Elements included (0.1.11).
  ```steps
  partial: Chart Elements only, and through their labels: AppProbe reads a name from AXTitle or AXDescription, and these controls are labelled through AXTitleUIElement, which VoiceOver reads (checked 2026-11-04 with a one-off AX read: Chart Title, Title, Legend, Data Labels, Gridlines)
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Chart exact=true action=press
  until find("role=radiobutton name='Chart Design, contextual' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Format exact=true action=press
  act role=radiobutton name=Chart exact=true action=press  # Format's Chart tab (a new install opens Fill & Line)
  until find("role=heading name='Chart Elements' exact=true").count == 1
  expect find("role=switch").count == 3
  expect find("role=statictext name='Chart Title' exact=true").count == 1  # each control's label
  expect find("role=statictext name='Data Labels' exact=true").count == 1
  expect find("role=statictext name=Gridlines exact=true").count == 1
  expect find("role=statictext name=Legend exact=true").count == 1
  expect find("role=statictext name=Title exact=true").count == 1
  ```
- [ ] The SmartArt dialog's graphic pop-up has a name VoiceOver reads, not its form key.
  ```steps
  # Not a checklist row: what the run found. DialogFormView's `.tabs` field uses its key as the Picker's label, so
  # VoiceOver reads "kind, Basic Process, pop-up button" (AXDescription "kind"), in every language.
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=SmartArt exact=true action=press
  until find("role=statictext name='Choose a SmartArt Graphic' exact=true").count == 1
  expect find("role=popupbutton value='Basic Process'").count == 1
  expect find("role=popupbutton name=kind exact=true").count == 0  # not "kind"
  act role=button name=Cancel exact=true action=press
  ```

## 5. Undo

- [ ] **Edit › Undo and Redo name the action**, as macOS apps and PowerPoint do: "Undo New Slide", "Redo New Slide" (PLAN.md §3: `NSUndoManager` shows the menu titles).
  ```steps
  # Measured 2026-11-04 on 0.1.15: the engine's history names it (document.inspect's undo is "New Slide"), the menu
  # doesn't. Every Undo-name check in this file waits on this row.
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  expect menu("Edit › Undo*").enabled == false  # nothing to undo on opening
  menu "Insert › New Slide" press
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1
  set undoName = menu("Edit › Undo*").name
  note "After Insert › New Slide, Edit's first item reads: ${undoName}"
  expect menu("Edit › Undo*").name == "Undo New Slide"  # Undo names the action
  menu "Edit › Undo*" press
  until find("role=statictext text='of 8'").count == 1
  expect menu("Edit › Redo*").name == "Redo New Slide"  # and so does Redo
  ```
- [ ] Undo and Redo through a longer session (a slide, a table, a rotation): each step comes back in order, and Redo repeats them.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=radiobutton name=Home exact=true action=press
  act role=button name="Selection Pane" exact=true action=press  # opens the task pane (a new install starts without it)
  until find("role=radiobutton name=Arrange exact=true").count == 1
  act role=radiobutton name=Arrange exact=true action=press
  until find("role=heading name='Selection Pane' exact=true").count == 1
  act role=button name="Title 1" exact=true action=press
  until find("role=checkbox name='Rotate Right 90°' exact=true").0.enabled == true
  act role=checkbox name="Rotate Right 90°" exact=true action=press  # 1: a rotation on slide 1
  menu "Insert › New Slide" press  # 2: a slide
  until find("role=statictext name='Slide 2 of 9' exact=true").count == 1
  act role=radiobutton name=Insert exact=true action=press
  act role=button name=Table exact=true action=press  # 3: a table on it
  until find("role=radiobutton name='Table Design, contextual' exact=true").count == 1
  menu "Edit › Undo*" press
  until find("role=radiobutton name='Table Design, contextual' exact=true").count == 0  # the table goes
  menu "Edit › Undo*" press
  until find("role=statictext text='of 8'").count == 1  # then the slide
  menu "Edit › Undo*" press
  pause 500
  expect menu("Edit › Undo*").enabled == false  # then the rotation: nothing left
  menu "Edit › Redo*" press
  menu "Edit › Redo*" press
  until find("role=statictext text='of 9'").count == 1  # Redo repeats them in order
  menu "Edit › Redo*" press
  pause 500
  expect menu("Edit › Redo*").enabled == false
  ```

## 6. On the slide canvas

- [ ] Click a shape to select it; drag it (smart guides appear); resize it by a handle; rotate it by its handle. Undo names each.
  ```steps
  skip: the canvas is a Metal view with no accessibility elements; it needs the control-channel step (below)
  ```
- [ ] Double-click a text box and type, including an accented letter and dictation; the text wraps and autofits.
  ```steps
  skip: in-place text editing is on the canvas; it needs the control-channel step (below)
  ```
- [ ] Draw a shape from the Shapes gallery by dragging on the slide.
  ```steps
  skip: drawing is a drag on the canvas; it needs the control-channel step (below)
  ```

## 7. Everyday flows

- [ ] A launch with nothing to open shows the **Start** window: Home, New and Open, the theme tiles and recent files. A tile makes a presentation.
  ```steps
  partial: a tile's press (made through File › New Presentation instead), the tiles' pictures, and the recent list (it shows this Mac's files, so the run neither reads nor screenshots it)
  until windows.0.title == "Start"  # a launch with nothing to open
  expect find("window=Start role=button name='Blank Presentation' exact=true").count == 1  # the theme tiles
  expect find("window=Start role=button name=Harbor exact=true").count == 1
  expect find("window=Start role=button name='Sample deck: Northern Lights' exact=true").count == 1
  expect find("window=Start role=button name=Briefing exact=true").count == 1  # the templates
  expect find("window=Start role=button name='Evening Talk' exact=true").count == 1
  # A tile's AXPress does make the presentation, but answers "not supported" because the Start window closes during
  # it, which fails the step: the run makes one through the menu instead.
  menu "File › New Presentation" press
  until windows.0.title != "Start"  # a presentation
  until find("role=statictext name='Slide 1 of 1' exact=true").count == 1
  ```
- [ ] A new presentation is named as PowerPoint names it, "Presentation1", whichever way it's made.
  ```steps
  # Not a checklist row: what the run found. A Start tile's presentation is "Presentation1" (the engine's name,
  # DCEngine Engine.swift:852), while File › New Presentation (⌘N) makes "Untitled", then "Untitled 2".
  until windows.0.title == "Start"
  menu "File › New Presentation" press
  until windows.0.title != "Start"
  set title = windows.0.title
  note "File › New Presentation made a window titled ${title}."
  expect windows.0.title == "Presentation1"  # PowerPoint's name, as the Start tile gives
  ```
- [ ] **Slide Sorter** and **Normal** views from the status bar; sections fold and unfold.
  ```steps
  open ${fixtures}/sample.deckcraft
  until find("role=statictext name='Slide 1 of 8' exact=true").count == 1
  act role=button name="Collapse Science" exact=true action=press
  until find("role=cell name='Slide 3' exact=true").count == 0  # the section folds
  act role=button name="Expand Science" exact=true action=press
  until find("role=cell name='Slide 3' exact=true").count == 1  # and unfolds
  act role=button name="Slide Sorter" exact=true action=press
  pause 1000
  shot "Slide Sorter"
  act role=button name=Normal exact=true action=press
  until find("role=textarea name=Notes").count == 1  # back to Normal, with the notes
  ```

## The canvas: what a control-channel step would need

The canvas rows (section 6) and the "drawn on the slide" checks stay with a person until AppProbe can talk to
deckcraft's loopback control server (`Packages/DCAutomation/Sources/DCAutomation/ControlServer.swift`, the channel
`deckcraft-cli app` uses). The app starts it with `--control PORT` (`AutomationFeature.start`), so a scenario would add
`args: [..., "--control", "47811"]` and a step that sends one JSON line (`{"method": …, "params": …}`) and reads one
reply. Measured on 0.1.15 (2026-11-04), these are the methods the rows need:

| Method | For |
|---|---|
| `document.inspect` | `undo` and `redo` (the engine's own labels: "New Slide", "Rotate Right 90°", "Table…", "Chart Elements"), `selection.shapes`, `dirty`, each slide's shape count |
| `slide.inspect {index}` (through `engine.execute`) | each shape's id, kind, box, text and fills: where an insert landed, what a drag moved |
| `shape.inspect {id}` (through `engine.execute`) | one shape's full JSON and its effective box: rotation, size, chart options |
| `ui.inspect` | `canvasRect`, `slideRect` and `canvasScale` (to aim pointer events), `showing` (the show's slide and animation step), `status` (the status line, which expires after 6 s on screen), `dialog`, `tool` |
| `ui.pointer {events: [{kind, x, y, mods?}]}` | clicks, drags and handle drags in slide points, with no real pointer |
| `ui.tool.select {tool, preset?}` | arming a Shapes preset before drawing it |
| `ui.text {text}`, `ui.key {key, …}` | typing into a text box being edited |
| `ui.render {slide, scale?, path}` | the slide as a PNG, for a judge or a pixel check |

A step like `control METHOD {json}` with `$` set to the reply would let these rows say, for example,
`control document.inspect {}` then `expect $.result.undo == "Rotate Right 90°"`.
