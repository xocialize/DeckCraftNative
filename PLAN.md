# DeckCraftNative: conversion plan

**Status:** draft 1, 2026-10-26 · **Source:** [deckcraft](../deckcraft) at `27009cd9` (2026-10-26), MIT OR Apache-2.0
**Target:** a native macOS 26+ app on Apple Silicon, in Swift with Metal, using AppKit and SwiftUI.
**Precedent:** [PhotoCraftNative](../PhotoCraftNative), which converted photocraft the same way. This plan copies its
shape: the two rules, one root `Package.swift`, packages that follow the crate layers, `PORT-STATUS.md`, a
`PORT-NOTES.md` for each package, and fixtures kept outside git.

## Decided (2026-10-26)

| Question | Answer |
|---|---|
| Where it lives | `research/DeckCraftNative`, next to PhotoCraftNative; GitHub remote [`xocialize/DeckCraftNative`](https://github.com/xocialize/DeckCraftNative) (private, created 2026-10-27); the fixtures repo stays local, as PhotoCraftNative's does |
| Platforms | macOS 26+, Apple Silicon only. Engine packages stay free of AppKit so iPadOS can follow later |
| UI | A Mac-native app that keeps PowerPoint's verbs: menu bar, toolbar, inspector sidebar and slide navigator (a Keynote-like layout), all generated from the command registry. ~~**The ribbon is dropped**~~ **Amended 2026-10-27 (operator):** the ribbon returns as an *optional window layout* beside the inspector, generated from the same registry, with a start screen; the Mac layout stays the default until the ribbon's last milestone passes, then new installs get the ribbon. Familiarity for PowerPoint users, not a 100% match ([Docs/plans/Ribbon-and-StartScreen.md](Docs/plans/Ribbon-and-StartScreen.md)) |

## 1. What we are converting

DeckCraft is a pure-Rust PowerPoint-parity presentation editor: about 219k lines in 24 crates, 3 apps and `xtask`,
with 2,081 `#[test]` functions and 328 registered commands. It reads and writes `.pptx`, saves its own `.deckcraft`
format (zip + JSON + media), exports PDF, PNG and GIF, plays slide shows with transitions, animations, Morph and media,
and can be driven by a CLI, a JSON control channel and MCP. The upstream project rates it "alpha, ~55 % ready for real
work".

Most of its size is code macOS already provides. About 52k lines are clean-room video and audio decoders. Its text
stack (HarfRust shaping, bidi and line breaking), its CPU rasteriser (`vello_cpu`), its PDF writer and its 42k-line
egui interface are all replaceable by Apple frameworks.

## 2. The two rules (as in PhotoCraftNative)

- **Replace with a macOS framework** where one already does the job:
  - AVFoundation, VideoToolbox and the fleet's `media-bridge` instead of the codec crates
  - CoreText instead of the shaping and line-breaking stack
  - CoreGraphics instead of `vello_cpu`
  - CGPDFContext and PDFKit instead of the PDF writer
  - AppKit and SwiftUI instead of egui
  - `NSPasteboard`, `NSPrintOperation`, `NSScreen` and String Catalogs for clipboard, printing, displays and localisation
- **Port to Swift** where nothing native exists or where PowerPoint semantics must match exactly:
  - the presentation model and placeholder inheritance
  - preset shape geometry (re-derived from ECMA-376)
  - DrawingML colour transforms
  - PPTX read and write, including round-tripping parts DeckCraft doesn't model (`Opaque`)
  - EMF and WMF
  - the animation timeline, transitions and Morph
  - autofit rules
  - the command registry and every command
  - the `.deckcraft` format

Every ported file names its source file and licence in its header. Code may be copied from PhotoCraftNative: its ZIP
reader and writer (`PCIO/Sources/PCIOCore/Zip.swift`, ZIP64 included), its MCP server and its CLI pattern (`pccli`).

## 3. Crate by crate

Line counts include in-file tests. "Replace" means the native framework does the work and only a thin adapter is
written.

| Layer | deckcraft crate | Rust lines | Disposition | Swift package / target |
|---|---|---:|---|---|
| L0 | `geom` (units, transforms, ~180 presets, warps, morph geometry) | 5,796 | **Port**. `kurbo` paths become `CGPath` | `DCFoundation` / `DCGeometry` |
| L0 | `color` (RGB/HSL, DrawingML transforms) | 831 | **Port** | `DCFoundation` / `DCColor` |
| L0 | `metafile` (EMF, EMF+, WMF into a neutral vector model) | 7,172 | **Port**. macOS has no EMF reader. Draw the result into a CGContext | `DCMetafile` |
| L0 | `bitstream`, `opus`, `ogg` | 7,251 | **Replace**: media-bridge decodes Opus. Port only the Ogg demuxer (739 lines) if Ogg/Opus files must play | `DCMedia` |
| L0 | `matroska`, `isobmff` (re-exports of craft-media) | 12 | **Replace**: AVFoundation for MP4/MOV; `matroska-swift` for MKV/WebM | `DCMedia` |
| L1 | `h264`, `hevc`, `vp9`, `av1` | 44,428 | **Replace**: VideoToolbox through media-bridge (H.264, HEVC, AV1 on M3 and later). VP9 through `vpx-swift`'s decoder hook, or deferred. AV1 on M1/M2 is deferred | `DCMedia` |
| L1 | `model` (presentation, masters, layouts, shapes, text, tables, charts, animations, `resolve`) | 9,114 | **Port**. Swift value types give the copy-on-write slide snapshots that the undo history relies on | `DCModel` |
| L1 | `fonts` (font database, metric-compatible substitutes) | 3,173 | **Replace** with CoreText and `CTFontManager`. Port the substitution table (Calibri→Carlito, Cambria→Caladea, Arial/Times→Liberation) and register the OFL craft-fonts at launch | `DCText` |
| L2 | `text` (shaping, bidi, line breaking, autofit, caret, date fields) | 5,452 | **Combine**: CoreText (`CTTypesetter`) does shaping, bidi and line breaking. Port DeckCraft's layout policy: autofit, columns, vertical text, bullets, caret hit-testing and fields | `DCText` |
| L2 | `anim` (timeline, show state machine, transitions, Morph) | 6,036 | **Port** the maths. Transition frames render in Metal | `DCAnim` |
| L2 | `format` (`.deckcraft`, outline text, RTF) | 2,140 | **Port**, keeping the format byte-compatible so files move both ways between the Rust and Swift apps | `DCFormat` |
| L2 | `media` (probe, decode, mixer, clock, player) | 2,974 | **Replace**: AVPlayer for playback, AVAudioEngine for slide sounds, media-bridge for probing | `DCMedia` |
| L3 | `render` (slide raster, fills, effects, pictures, tables, charts) | 13,813 | **Port the drawing logic onto CoreGraphics**. Effects (shadow, glow, soft edges, reflection) and picture corrections use CG plus Core Image. One path draws to the screen, thumbnails, PDF and print | `DCRender` |
| L3 | `pptx` (OPC, DrawingML, charts, SmartArt `dgm`, timing tree) | 19,837 | **Port**. ZIP from PhotoCraftNative; XML through a small pull reader over `XMLParser`, and a streaming writer | `DCPPTX` |
| L4 | `pdf` (craft-pdf/Krilla: raster plus an invisible text layer) | 1,310 | **Replace** with CGPDFContext. Drawing the same CoreGraphics and CoreText calls gives **vector slides, real text and subsetted fonts** with no extra code | `DCRender` / `DCExport` |
| L5 | `engine` (Session, history, 328 commands, tools, keys, AutoRecover, sample deck, spelling, thesaurus) | 40,266 | **Port**. Spelling and thesaurus use `NSSpellChecker`; the bundled thesaurus data stays | `DCEngine` |
| L6 | `mcp` (JSON-RPC over stdio, headless or connected) | 1,689 | **Port** onto `modelcontextprotocol/swift-sdk`, as PhotoCraftNative does | `DCAutomation` |
| L7 | `ui-egui` (ribbon, canvas, panes, 41 dialogs, backstage, show and presenter windows, control channel) | 42,426 | **Rewrite** in AppKit and SwiftUI. The control channel is ported onto `NWListener` | App |
| apps | `deckcraft` (eframe, cpal audio, Apple Events, pasteboard, logging) | 2,125 | **Replace**: `NSDocument`, AVAudioEngine, `NSPasteboard`, `os.Logger` | App |
| apps | `deckcraft-cli` (run, render, convert, mcp, app) | 1,432 | **Port** onto swift-argument-parser as `dccli` | `dccli` |
| apps | `deckcraft-web` | 227 | **Drop**: no web build | — |
| — | `xtask` | 1,489 | **Drop or turn into scripts**: the layering check becomes SwiftPM target dependencies, and `stats` and `parity` become scripts | `Tools/` |

**In round numbers:** about 61k lines are replaced by frameworks or dropped, about 116k are ported (tests included),
and the 42k-line UI is rewritten.

## 4. Package layout

There is one root `Package.swift` (swift-tools-version 6.2, `.macOS(.v26)`, Swift 6 language mode). Every library is
a product, so the app and other repos depend on it by URL.

```
DeckCraftNative/
  Package.swift
  Packages/
    DCFoundation/   DCGeometry, DCColor                      (L0)
    DCMetafile/                                              (L0)
    DCModel/                                                 (L1)
    DCText/         CoreText layout, fonts, autofit          (L2)
    DCMedia/        AVFoundation + media-bridge adapter      (L2)
    DCAnim/                                                  (L2)
    DCFormat/       .deckcraft                               (L2)
    DCRender/       CoreGraphics slide renderer, PDF, Metal transitions  (L3–L4)
    DCPPTX/                                                  (L3)
    DCEngine/       Session, history, commands, tools        (L5)
    DCAutomation/   control channel, MCP                     (L6)
  Apps/
    DeckCraftNative/  Xcode app target (AppKit + SwiftUI)    (L7)
    dccli/
  Tools/            parity runners, the Rust oracle wrapper
  PORT-STATUS.md  EVALUATION.md
```

The layering rule is enforced by target dependencies: nothing below the app imports AppKit or SwiftUI. Fixtures live
in `../DeckCraftNative-Fixtures`, or wherever `DECKCRAFT_FIXTURES` points; tests that need them skip cleanly without
them.

## 5. Architecture decisions

1. **Rendering.**
   - **What draws.** `DCRender` draws a slide into any `CGContext`. That one path serves the editor canvas (a
     layer-backed `NSView` drawing CG at the view's scale), thumbnails, PNG export, PDF export and printing.
   - **The slide show.** It follows DeckCraft's design: render each slide once into an `MTLTexture`, then let Metal
     composite transitions every frame. The quad, mesh and perspective layouts come from `DCAnim`, as they do from
     `anim::transition_frame` now.
   - **Later, if needed.** A Metal path for the canvas waits until a measurement says CG is too slow.
2. **Text.**
   - CoreText owns glyphs, shaping, bidi and line breaking.
   - DeckCraft's rules for PowerPoint behaviour sit on top: autofit shrink steps, line-spacing semantics, bullets,
     columns and vertical text.
   - Editing on the canvas uses an `NSTextInputClient` view, so input methods, dictation and the macOS text services
     work without extra code. DeckCraft has 1,979 lines of IME tests for its own handling.
3. **Model and undo.**
   - The model is made of Swift value types. The engine's history keeps whole-slide snapshots that share storage
     (copy-on-write), as the Rust code does with `Arc`.
   - `NSUndoManager` shows the menu titles only. The engine stays the source of truth, so the CLI, MCP and the app
     undo identically.
4. **Never crash.** This carries over DeckCraft's rule (AGENTS.md §3) in Swift form:
   - No `!`, `try!`, `fatalError` or `precondition` in production targets.
   - Input-derived numbers are checked; recursion and allocations are bounded.
   - A lint script enforces this in CI.
   - Swift can't catch a trap the way `guard.rs` catches a panic. So `Session.execute` applies a command to a copy
     and commits only on success, and the crash-recovery save runs on a timer, not in a signal handler.
5. **Concurrency.** `Session` is an actor (or lives on the main actor in the app); slides are `Sendable` values.
   Rendering for thumbnails, export and PDF runs in parallel on snapshots.
6. **Everything is a command.**
   - `CommandSpec` is ported one to one: id, label, menu path, shortcut, params doc, `enabled`, `run`, journal and
     undoable.
   - The menu bar, toolbar, inspector actions, Touch Bar–style shortcuts and a command palette are all *generated*
     from the registry.
   - Command ids stay identical to DeckCraft's, so scripts and MCP prompts work against either app.
7. **Files.**
   - `.deckcraft` stays the native format, byte-compatible with the Rust app; it opens and saves as a single file.
   - `.pptx` is first-class.
   - Quick Look preview and thumbnail extensions for both formats are a cheap native win.
8. **Media.**
   - Containers: MP4/MOV through AVFoundation; MKV/WebM through `matroska-swift`.
   - Video: H.264 and HEVC; AV1 on M3 and later.
   - Audio: AAC, ALAC, FLAC, MP3, WAV, AIFF and Opus.
   - VP9 and VP8 play through `vpx-swift` (decided 2026-10-27). AV1 on M1/M2 is deferred and shows a clear "can't play"
     state, never a crash. This follows media-bridge's own deferred list.

## 6. Oracles and parity

| Oracle | Checks | How |
|---|---|---|
| **Rust DeckCraft at the pinned commit** | Model, format, command and render parity | `deckcraft-cli` (built with cargo, or the signed universal release zip) renders every fixture deck to PNG and runs command scripts to `.deckcraft`. The Swift side runs the same scripts. JSON is compared structurally; renders are compared with SSIMULACRA2 from media-bridge's `MediaMeasureCore`, with a threshold per category |
| **DeckCraft's own tests** | Unit behaviour | Each package ports its crate's `#[test]`s (2,081 in all) as Swift Testing tests, the way PhotoCraftNative carried photocraft's |
| **PowerPoint and Keynote** | "Does our `.pptx` open without repair, and does it look right" | Neither is installed on this machine yet (see open decisions). Black-box only, on synthetic decks, under DeckCraft's clean-room rules |
| **ECMA-376** | Geometry and DrawingML semantics | As DeckCraft does: re-derived, never copied from Office |

Fonts change rendering. CoreText and HarfRust will differ by a pixel here and there, and CoreText line breaking can
differ on edge cases. Render parity is therefore measured, and breaks are only checked on fixtures that use OFL fonts
both apps have. The goal is PowerPoint behaviour, not matching DeckCraft's bugs.

## 7. Waves

Each wave ends with green tests, a `PORT-STATUS.md` update and a re-sync to upstream (see §9).

| Wave | Scope | Done when |
|---|---|---|
| **0. Scaffold and oracles** | Repo and `Package.swift`; a fixtures repo; the Rust oracle runnable (`rustup` + `cargo build -p deckcraft-cli`, or the release binary); craft-fonts checked out; generate the reference corpus from DeckCraft's sample deck and its test decks | `swift build` is green; `Tools/oracle render <deck>` produces reference PNGs |
| **1. Foundation** (done 2026-10-26) | `DCCore` (serde-compatible JSON, Rust semantics), `DCZip`, `DCGeometry`, `DCColor`, `DCModel` (with `resolve`), `DCFormat` | All of geom's, color's, model's and format's tests pass; every `.deckcraft` the oracle writes loads and re-saves to byte-identical `presentation.json`, and the Rust app opens what Swift writes |
| **2. Text and render** (done 2026-10-26) | `DCText`, `DCRender` (fills, outlines, effects, pictures, tables, charts), `DCMetafile`, PDF export | The sample deck and test decks render within threshold of the oracle; the PDF has vector shapes and selectable text |
| **3. PPTX** (done 2026-10-26) | `DCPPTX` read and write, `Opaque` round-trip, charts, SmartArt, timing tree | pptx's tests (7,085 lines) pass; oracle-written `.pptx` → Swift → `.pptx` keeps every part; Swift-written files open in the Rust app |
| **4. Engine and automation** (done 2026-10-27) | `DCEngine` (Session, history, all 328 commands, tools, keys, AutoRecover, the sample deck), `DCAnim`, `DCMedia`, `dccli`, MCP, control channel | Engine tests pass; the same command scripts give the same `.deckcraft` in both apps; `dccli mcp` passes mcp's tests |
| **5. The app** (done 2026-10-27; String Catalogs done in wave 6) | Document app (`NSDocument`), slide navigator, canvas with handles, smart guides and text editing, inspector panes, menus and toolbar from the registry, the dialogs, the slide show and presenter view on the second display, printing, pasteboard, String Catalogs | The six alpha-gate workflows DeckCraft defines (build, open and save `.pptx`, present, tables and charts, share as PDF, review) work end to end in the app; screenshots are checked through the control channel |
| **6. Ship** (done 2026-10-27) | Signing, notarisation, an update channel, Quick Look extensions, App Intents and Shortcuts, Spotlight importer | A notarised build; `EVALUATION.md` lists what isn't native yet |

Waves 1–3 split cleanly across parallel sessions, one package each, like PhotoCraftNative's crate-by-crate runs. The
UI (wave 5) can start against a stub Session once the model, render and command shapes from wave 4 are fixed.

## 8. What going native closes for free

These come from DeckCraft's ranked gap list (`docs/gaps.md`); each is a framework call here rather than a project:

- **#4 SVG pictures don't render** → native SVG drawing (*to verify*: `NSImage` loads SVG; how faithfully it renders
  needs a test)
- **#6 No printing** → `NSPrintOperation` on the CG renderer
- **#7 Only Regular, Bold and Italic faces** → CoreText's full font families
- **#8 Image paste** → `NSPasteboard`
- **#9 Presenter view on the second display** → `NSScreen`
- **#13 No native menu bar** → AppKit
- **#14 PDF rasterises slides** → CGPDFContext is vector
- **#15 CPU raster, no hardware decode** → CoreGraphics on Apple Silicon, VideoToolbox
- **#5 Localisation** → the infrastructure is String Catalogs; the translations are still work

## 9. Keeping up with upstream

DeckCraft moves fast: over 1,400 PRs, with several commits a day. Each wave pins the upstream commit it ported from
and records it in `PORT-STATUS.md`. At the end of a wave, `git diff <pin>..origin/main -- crates/<crate>` lists the
changes to carry across, and they are ported before the pin moves. Feature work goes upstream-first when it isn't
Mac-specific.

## 10. Open decisions (yours)

1. ~~**Product name and icon.**~~ **Decided 2026-10-27:** DeckCraftNative, with DeckCraft's MIT placeholder icon and no
   ArtCraft marks (WAVE6-PLAN.md).
2. **Fidelity oracles.** **PowerPoint for Mac: installed 2026-10-27** as a black-box "opens without repair" check
   (`Tools/pptx/powerpoint-check.sh`; its first finding fixed DCPPTX's chartEx parts). Keynote is still open.
3. ~~**Rust toolchain.**~~ **Decided 2026-10-26:** the oracle builds from source with Homebrew's `rustup`, because the
   v0.11.1 release binary is 112 commits behind the pin. Wave 0 is done (see `PORT-STATUS.md`).
4. ~~**VP9 and Ogg/Vorbis.**~~ **Decided 2026-10-27:** VP9 and VP8 play through `vpx-swift` (libvpx), registered by the
   app and `dccli` (DCMedia stays free of it); Vorbis plays through AudioToolbox. AV1 on M1/M2 stays "can't play".
5. **Consumers.** Is this a standalone app, or the engine for something else (as PhotoCraftNative is for
   PixelAgencyEditor), such as a Marquee or MVS show tool? This decides whether `DCEngine` must be ready as an
   embeddable product early.

## 11. Source material beyond deckcraft

Two collections were added on 2026-10-26. Both are reference material, used under the same clean-room rules
as ECMA-376: implement from the documents, never copy their text into code or docs.

- **`../OfficeFileFormatsProtocols`**: 24 of Microsoft's published Open Specifications (PDF), covered by the
  Open Specification Promise. The ones that matter here:
  - **[MS-PPT]** is the legacy binary `.ppt`, which deckcraft has no reader for (its `docs/gaps.md` lists it).
  - **[MS-ODRAW]** is the drawing layer inside `.ppt`.
  - **[MS-OFFCRYPTO]** covers password-protected `.pptx`, which deckcraft can't open either.
  - **[MS-OSHARED]** holds the structures those three share.

  These belong in a wave after the app (Wave 7 or later), as a `DCPPT` reader that produces DCModel, and a
  decryption step in front of DCPPTX. Planned on 2026-10-30 in
  [Docs/plans/Legacy-PPT-and-Encryption.md](Docs/plans/Legacy-PPT-and-Encryption.md). EMF/WMF ([MS-EMF], [MS-WMF], [MS-EMFPLUS]) aren't in the folder;
  DCMetafile ports deckcraft's reader in Wave 2.
- **`../pptx-swift-main`**: PPTXKit (MIT), about 8k lines of Swift. It is a read-only PPTX viewer built on
  ZIPFoundation, much narrower than deckcraft's `pptx` crate, which reads, writes and round-trips unknown parts.
  DCPPTX ports deckcraft's crate, not this one. What's useful in it:
  - **`specifications/`** has the ECMA-376 5th-edition PDFs and the XSD and RELAX NG schemas. Wave 3 validates
    every `.pptx` DCPPTX writes against the Transitional XSDs with `xmllint`, a check deckcraft doesn't make.
  - **Its CoreGraphics renderer and UIKit/SwiftUI views** are prior art for Waves 2 and 5.
  - **Two caveats.** It carries ECMA's `presetShapeDefinitions.xml`, which deckcraft deliberately doesn't use
    (its preset geometry is its own, and our oracle compares against deckcraft's). And `sample_2.pptx` is of
    unknown origin, so it never enters the fixtures.

## 12. Risks

- **Text metrics.** Autofit and line breaks drive layout everywhere, and CoreText differs from HarfRust plus UAX #14
  on edge cases. Mitigation: port the policy layer and its tests first, and measure against the oracle before
  building anything on top.
- **Engine size.** 40k lines and 328 commands make this the long pole. Commands are independent, so they parallelise
  well once `Session` and history exist.
- **Charts.** 1.6k lines of model and 1.8k of rendering, with no native equivalent of PowerPoint-faithful charts.
  Swift Charts was ruled out: it can't match PowerPoint's chart semantics or draw into the shared PDF path.
- **The upstream moves under us.** The pin-and-diff routine in §9 handles it, but it costs time every wave.
