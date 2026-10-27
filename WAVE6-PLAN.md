# Wave 6: ship

**Started and done:** 2026-10-27 (see PORT-STATUS.md, Wave 6) · **Pin:** deckcraft `27009cd9` · **Done when** (PLAN.md §7): a notarized build; `EVALUATION.md`
lists what isn't native yet. Wave 6 also carries the String Catalogs left over from Wave 5.

This is the shared brief for the sessions that build Wave 6 in parallel. Read it with [PLAN.md](PLAN.md),
[PORT-STATUS.md](PORT-STATUS.md) (Wave 5), [WAVE5-PLAN.md](WAVE5-PLAN.md) (the app's architecture, extension
points, how to run and screenshot it) and [CLAUDE.md](CLAUDE.md).

## Decided (2026-10-27, by the user)

| Question | Answer |
|---|---|
| Name | **DeckCraftNative**; bundle id `com.xocialize.deckcraftnative`. About says, in plain text, that it is based on DeckCraft by the ArtCraft team; no ArtCraft marks anywhere (deckcraft `docs/brand/LICENSE-brand.txt`) |
| Icon | deckcraft's placeholder app icon (`assets/app-icon/`, MIT OR Apache-2.0, ATTRIBUTION.md row), with an ATTRIBUTION entry here |
| Updates | **A native checker**: Check for Updates… asks GitHub's API for the latest release of a **public** releases repo (`xocialize/deckcraftnative-releases`, created only when the user approves publishing; at publishing the user chose to make `xocialize/DeckCraftNative` itself public and release from it), shows its notes, and downloads and opens the notarized DMG. URLSession, no third-party framework |
| Languages | **English only** in this wave: every UI string in String Catalogs, kept that way by a test; translations later |
| Signing | **Developer ID Application: Dustin Nielson (CFZS6RXUCP)**, notarized with the keychain profile **`mlx-notary`** (exists and works), hardened runtime, no sandbox (the control server and AutoRecover need neither) — as ML[X] Image Server ships (`ml(x)/ML[X]-Image-Server/Tools/release.sh`, `publish-release.sh`: read them) |
| Publishing | Nothing public is created or published in this wave without the user's explicit yes: no public repo, no GitHub release, no tag pushed to a public remote. Notarizing (Apple's service) is approved. The code repo `xocialize/DeckCraftNative` is private |

## The parts

| Part | Owner | What |
|---|---|---|
| **Release** | session A | `Tools/release.sh` (archive → Developer ID export → verify signatures → DMG with deckcraft's DMG background if its licence allows, else plain → notarize + staple with `--notarize mlx-notary`), `Tools/publish-release.sh` (refuses unless notarized; targets the releases repo; never run without the user), one version number (`MARKETING_VERSION` and a `DCAppVersion` constant kept equal, checked by a test), the app icon (asset catalog in `Apps/DeckCraftNative/App/`), About's text, `ATTRIBUTION.md` |
| **Updates** | session A | `app.checkUpdates` and automatic checks (deckcraft `crates/ui-egui/src/updates_ui.rs` and its `craft_update` behaviour): `DCAppModel/Updates*.swift` (version compare, release JSON, the asset to fetch — window-free and tested with a stubbed `URLProtocol`), `DCApp/Updates/` (the sheet, download, open the DMG). The releases repo's owner/name is one constant |
| **Extensions** | session B | Quick Look **preview** and **thumbnail** extensions and a Core Spotlight **import** extension (`CSImportExtension`: titles, slide text, notes, comments, authors) for `.deckcraft`, `.pptx`, `.potx`, `.ppsx`. Their code in new package targets (e.g. `DCQuickLook`, `DCSpotlight`) over DCEngine/DCRender, so it builds and tests with `swift test`; three appex targets in the Xcode project, embedded in the app. **Session B owns `Apps/DeckCraftNative/DeckCraftNative.xcodeproj/project.pbxproj`**; others ask it for project changes |
| **Intents** | session C | App Intents and App Shortcuts: open a presentation, new presentation (from a theme or starter), export (PDF slides/notes/handouts, PPTX, images), start the slide show, add a slide with title and text, get a presentation's outline text and slide count, and a "Run DeckCraft command" intent for power users (command id + JSON params). Export and read intents work on a file without opening a window. Code in `DCApp/Intents/` (or a package target with `AppIntentsPackage`) and/or `Apps/DeckCraftNative/App/` (a synchronized folder: new files there compile without touching the project file) |
| **Strings** | session D | String Catalogs for every user-visible string in DCApp and DCAppModel (the convention below), the Commands catalog generated from the registry (all 330 commands, the UI commands, the menu titles), `InfoPlist.xcstrings` for the bundle's strings, and a test that keeps the catalogs complete |
| **Lead** | here | the String Catalog infrastructure (done: `defaultLocalization`, empty catalogs, `L10n`), integration, a signed and notarized build verified with `spctl`, `stapler`, a fresh-user launch and the alpha gate, `EVALUATION.md`, status |

## String Catalogs (the convention every part follows)

- Text written in app code: `String(localized: "Slide Sorter", bundle: .module)`; SwiftUI `Text("Notes", bundle: .module)`,
  `Button(String(localized: "Done", bundle: .module))`, `LocalizedStringResource("…", bundle: .atURL(Bundle.module.bundleURL))`
  for App Intents. **Always `bundle: .module`**: the strings live in the package's resource bundle, not the app's.
  Add a `comment:` where the meaning isn't obvious.
- Command labels and menu titles: `L10n.commandLabel(id, english)` and `L10n.menuTitle(english)` (DCAppModel/L10n.swift),
  from `DCAppModel/Resources/Commands.xcstrings`, keyed by command id. The engine's labels stay English (parity).
- Not translated: command ids, JSON, file formats, engine error text shown as is, deckcraft's fixed names (theme names,
  font names), anything the control channel or scripts compare.
- Catalogs: `Packages/DCApp/Sources/DCAppModel/Resources/{Localizable,Commands}.xcstrings` and
  `Packages/DCApp/Sources/DCApp/Resources/Localizable.xcstrings`. SwiftPM compiles them into `.lproj`s in the
  module's bundle (checked). SwiftPM doesn't extract keys itself: session D populates the catalogs (from the
  compiler's `.stringsdata` via `xcstringstool sync`, or a script) and adds the test.
- **New code in Wave 6 (sessions A, B, C) uses the convention from the start**; session D converts the existing code.

## Rules

- **Own files only.** A: `Tools/release.sh`, `Tools/publish-release.sh`, `DCAppModel/Updates*.swift`, `DCApp/Updates/`,
  `Apps/DeckCraftNative/App/Assets.xcassets`, `ATTRIBUTION.md`, the version constant. B: the new extension package
  targets, `Apps/DeckCraftNative/Extensions/`, `project.pbxproj`. C: `DCApp/Intents/`, `Apps/DeckCraftNative/App/*Intent*.swift`.
  D: the catalogs, the edits that wrap existing strings in DCApp and DCAppModel, `Tools/l10n/`. **Shared files**
  (`Package.swift`, `AppController.swift`, `Features.swift`, `MenuBuilder.swift`, `Info.plist`, `PORT-STATUS.md`):
  minimal, additive edits, re-read right before editing, listed in your report. Session D edits many files for
  strings only; A, B and C don't reformat or restructure existing DCApp files (add an install line in
  `Features.swift`, a menu hook, no more).
- **Never crash** (CLAUDE.md). No warnings. Build and test with your own scratch path (`.build-<part>`); keep the
  shared tree green; stage non-compiling files in the scratchpad. Xcode builds use your own derived data under
  `~/Library/Caches/DeckCraftNative/xcode-<part>` (Satechi is nearly full).
- **Another session** works on `Packages/DCPPTX` (a chart fix) on its own branch in `../DeckCraftNative-wt-chartfix`;
  don't touch DCPPTX.
- **Don't commit or push.** Don't publish anything (see Decided). Notarizing with `mlx-notary` is approved.
- Notes: a section for your part in `Packages/DCApp/PORT-NOTES.md` (append) or the new targets' own PORT-NOTES.

## Report

Files and test counts; what was verified and how (commands, screenshots, `spctl`/`codesign` output); shared-file
edits; open items; the final `swift test --filter …` summary lines for your targets.
