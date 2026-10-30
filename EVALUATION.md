# What isn't native yet — evaluation

The plan (PLAN.md §2) was to replace deckcraft's libraries with macOS frameworks wherever one does the job, port
what PowerPoint's semantics require, and say what's left. This is that evaluation, as of 2026-10-27, at the end of
Wave 6. Sources: each package's `PORT-NOTES.md`, `PORT-STATUS.md`, `WAVE5-PLAN.md`, `WAVE6-PLAN.md`.

## Where the port stands

| Measure | Result |
|---|---|
| deckcraft engine commands | **330 of 330** registered with deckcraft's ids, labels, menus, shortcuts and parameters; every engine script gives deckcraft's answers and decks (38 byte for byte, 6 through native frameworks compared by measure) |
| deckcraft's crates | every library crate ported or replaced by a framework (table below); the egui UI rewritten in AppKit and SwiftUI |
| Tests | **2,144** across the packages, every one green and warning-free; deckcraft's 2,081 `#[test]`s ported where they test behaviour the Mac app has (the rest are egui internals, listed per area) |
| Parity with deckcraft | `.deckcraft` and `.pptx` byte-identical both ways over the oracle corpus (apart from the chart fix below); slides render at SSIMULACRA2 ≥ 89 to deckcraft's PNGs; transitions ≥ 89; the Metal show ≥ 91 to the CPU compositor; MCP, `dccli` and the pointer byte-identical |
| The alpha gate | deckcraft's six core workflows run end to end in the app through the control channel: **16 of 16** checks |
| Shipping | a Developer ID–signed, notarized and stapled DMG (`Tools/release.sh`), published on GitHub, latest [v0.1.5](https://github.com/xocialize/DeckCraftNative/releases/tag/v0.1.5); Quick Look, Spotlight, App Intents; String Catalogs |

## What became native

| deckcraft | Native here |
|---|---|
| `vello_cpu` raster, Krilla PDF (raster slides) | CoreGraphics; CGPDFContext gives **vector** PDF with real text (deckcraft's gap #14) |
| HarfRust shaping, bidi, UAX #14 breaking, fontdb | CoreText under deckcraft's ported layout policy (autofit, bullets, columns, caret) |
| 52k lines of H.264/HEVC/VP9/AV1/Opus/Ogg decoders | AVFoundation, VideoToolbox, AudioToolbox; media-bridge's codec gate; libvpx (vpx-swift) for VP9 and VP8, which macOS can't decode |
| `image` crate (PNG/JPEG/GIF) | ImageIO |
| `i_overlay` (Merge Shapes) | CoreGraphics path booleans (worst relative area difference 2.2e-16) |
| Hunspell list, built-in word list | Hunspell dictionaries when installed, else NSSpellChecker |
| egui UI (42k lines), ribbon | AppKit + SwiftUI: NSDocument, menu bar (gap #13), toolbar, inspector, sheets; DesignScaffold tokens |
| egui text input and IME | `NSTextInputClient`: input methods, dictation, Services |
| — (no printing: gap #6) | `NSPrintOperation` with deckcraft's layouts and handouts |
| egui clipboard | `NSPasteboard`, PDF and PNG of copied shapes for other apps (gap #8) |
| presenter window placed by hand (gap #9) | `NSScreen`: the presenter view goes on the other display |
| GPU-less show compositing | Metal, exact to the CPU compositor |
| screenshots through egui | ScreenCaptureKit |
| `craft_update` self-update | a native GitHub releases checker (URLSession) |
| — | Quick Look preview and thumbnail, Spotlight import, App Intents and Shortcuts, String Catalogs |

## Ported, by design

These have no native equivalent, or PowerPoint's semantics have to match exactly (PLAN.md §2): the presentation
model and placeholder inheritance; preset geometry and warps; DrawingML colour transforms; PPTX read/write with
`Opaque` round-trip; EMF/EMF+/WMF; the animation timeline, transitions and Morph; autofit; the command registry and
every command; the `.deckcraft` format; charts (PLAN.md §12: Swift Charts can't match PowerPoint's chart semantics
or draw into the shared PDF/print path); the pointer and its snapping; the MCP server (on Apple's swift-sdk); the
container probes whose results are stored in documents (ISOBMFF, Matroska, Ogg).

## 1. Possible natively, not built yet

| Item | Native path | Notes |
|---|---|---|
| **Translations** | String Catalogs are in place; every UI string is extracted (about 1,900 entries) and a pseudo-localisation run checked layout | No languages yet (user's decision for Wave 6). Some keys share one English word with different meanings ("Normal", "Center", "Zoom") and may need splitting for translators |
| **AV1 on M1/M2** | none: VideoToolbox decodes AV1 on M3 and later only | Shows a clear "can't be played on this Mac" state. VP8 and VP9 play through libvpx (vpx-swift) since 2026-10-27 |
| **Versions and autosave in place** | NSDocument `autosavesInPlace` | Off: the engine's AutoRecover keeps deckcraft's crash recovery. Moving to NSDocument autosave means reconciling the two |
| **The sandbox / Mac App Store** | App Sandbox | Not sandboxed: the loopback control server and AutoRecover beside documents need decisions first (the extensions are sandboxed) |
| **Background intents without a window** | an App Intents extension — **shipped in 0.1.2** (`DeckCraftIntents.appex`, DCIntentsKit) | Export Presentation, Get Presentation Outline and Get Slide Count run in a sandboxed App Intents extension, so the app isn't launched and no window opens; the app keeps the five intents that act on its windows and lists the file intents only so its App Shortcuts can name them (`allowedExecutionTargets` = the extension on macOS 27; on macOS 26 the system prefers the extension for a background intent). Built, signed, archived, exported and notarized (`Tools/release.sh`). Run through the Shortcuts app end to end with the notarized 0.1.2 installed in `~/Applications`: Export Presentation made an 8-page PDF of an 8-slide deck, with no app process before, during or after (DCExtensions/PORT-NOTES.md, Intents extension) |
| **Legacy `.ppt` and encrypted `.pptx`** | a `DCPPT` reader from [MS-PPT]/[MS-ODRAW], decryption from [MS-OFFCRYPTO] | PLAN.md §11: a later wave (deckcraft has neither) |
| **Small items** | — | "1 slides" plurals are kept as deckcraft says them (the Theme Colors, Review inspector and status bar layout issues were fixed in 0.1.2) |

## 2. Native, but the platform decides

| Area | What happens | Recommendation |
|---|---|---|
| **Quick Look for Office files** | macOS's own Office preview and thumbnail win over ours for `.pptx`/`.potx`/`.ppsx` (Times instead of Inter, `‹#›` for slide numbers, hidden slides skipped). Ours handles `.deckcraft` and reads Office files correctly when asked | Leave: not something an app can set |
| **Spotlight** | macOS never hands a file to the Core Spotlight import extension (`CSImportExtension`), re-tested with the notarized build and with `CSExtensionLabel`, so the app indexes the `.deckcraft` files it opens and saves itself: a Core Spotlight item and an App Intents entity of the presentation App Schema. On macOS 27 Spotlight finds them by name and opens them, never by body text; Siri finds them by what they say and opens them (five in five on an install that stays put; DCExtensions/PORT-NOTES.md). Files the app hasn't opened get system attributes only | Body-text matches in the Spotlight panel are up to macOS |
| **Fonts in sandboxed extensions** | An app extension can't read its containing app's bundle (EPERM), so the preview and thumbnail extensions carry their own copy of craft-fonts' Latin set (14 families, 17.5 MB each); the app carries all of craft-fonts (77 MB) | Leave; trim the extensions to the metric-compatible families (about 9 MB each) if size matters |

## 3. Fidelity checked against PowerPoint

PowerPoint for Mac is installed as a black-box oracle (PORT-STATUS decisions, 2026-10-27; nothing it saves enters the
repository). Its first check found that every deck with an Office 2016 chart (`chartEx`) written by deckcraft — and
so by DCPPTX — opened with PowerPoint's repair prompt: each chartEx part lacked its chart style and colour style
parts. DCPPTX now writes them (MS-ODRAWXML's cs:chartStyle and cs:colorStyle; the one deliberate divergence from
deckcraft's bytes, allowed by name in the parity tests). All 9 corpus decks exported by DCPPTX now open in PowerPoint
without repair (`Tools/pptx/powerpoint-check.sh`, which opens any `.pptx` in PowerPoint and reports OPEN-OK or
NEEDS-REPAIR).

`Tools/pptx/powerpoint-sweep.sh` widens that to every test deck: the 9 corpus decks, the 44 engine-script decks and
the 7 pointer-session decks, exported by `dccli`. On 2026-10-27 all **60 open without repair**, and PowerPoint reads
**the same slides and the same number of shapes on every slide** as DeckCraftNative wrote. That covers tables,
SmartArt, charts, media, ink, freeforms, comments, sections and the Office 2016 charts. A positive control confirms
the check catches problems: deckcraft's own export of the Office 2016 chart deck still needs repair.
