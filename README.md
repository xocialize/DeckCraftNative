# DeckCraftNative

A native macOS presentation editor in Swift, AppKit, SwiftUI and Metal. It is a port of
[DeckCraft](https://github.com/storytold/deckcraft), the Rust PowerPoint-parity editor by the ArtCraft team. It
keeps DeckCraft's engine and behaviour, file for file and command for command, and replaces the rest with macOS
frameworks.

**[Download DeckCraftNative 0.1.0](https://github.com/xocialize/DeckCraftNative/releases/latest)**: macOS 26 or
later on Apple silicon. The app is signed with a Developer ID and notarized by Apple. It's an early preview.

## What it does

- **Build decks:** themes, layouts, text, shapes, pictures, tables, charts, SmartArt, transitions and animations.
  It saves `.deckcraft` files, which open in DeckCraft too.
- **PowerPoint files:** opens `.pptx`, `.potx` and `.ppsx`, and saves `.pptx` that Microsoft PowerPoint opens
  without repair.
- **Present:** full screen, with transitions composited in Metal, and a presenter view on a second display.
- **Share:** export PDF (vector, with selectable text) of slides, notes or handouts, PNG, JPEG and animated GIF.
  Print with the same layouts.
- **Review:** comments with replies, spelling and the thesaurus.
- **macOS integration:** Quick Look previews and thumbnails, Shortcuts actions, Check for Updates, and an interface
  ready for translation.
- **Automation:** every command can be scripted. The `dccli` tool runs command scripts, renders and converts files,
  and serves MCP. A running app answers on a local control channel (`--control PORT`).

What isn't native yet, and why, is in [EVALUATION.md](EVALUATION.md).

## How it was ported

Two rules, from the [plan](PLAN.md):

- **Replace with a macOS framework** where one does the job:
  - CoreGraphics instead of `vello_cpu`;
  - CoreText instead of the shaping stack;
  - CGPDFContext instead of the PDF writer;
  - AVFoundation, VideoToolbox and media-bridge instead of the codec crates;
  - ImageIO, NSSpellChecker, NSPrintOperation and NSPasteboard;
  - AppKit and SwiftUI instead of egui.
- **Port to Swift** where nothing native exists or PowerPoint's semantics must match:
  - the model;
  - preset geometry;
  - DrawingML colour;
  - PPTX read and write;
  - EMF/WMF;
  - animation, transitions and Morph;
  - the `.deckcraft` format;
  - all 330 commands.

Parity is measured against the Rust app built at a pinned upstream commit:
- **Files:** `.deckcraft` and `.pptx` are byte-identical both ways over the test corpus, apart from one documented
  PowerPoint fix.
- **Rendering:** slides and transitions match deckcraft's at SSIMULACRA2 ≥ 89.
- **Automation:** command scripts, MCP replies and pointer sessions give deckcraft's answers byte for byte.

About 2,150 tests cover it, including DeckCraft's own tests where the Mac app has the behaviour. Progress, wave by
wave and crate by crate, is in [PORT-STATUS.md](PORT-STATUS.md).

| Package | What | Replaces / ports |
|---|---|---|
| `DCCore`, `DCZip` | serde-compatible JSON, Rust semantics; ZIP | — |
| `DCFoundation` (`DCGeometry`, `DCColor`) | units, transforms, preset shapes, warps; DrawingML colour | `geom`, `color` |
| `DCModel`, `DCFormat` | the presentation model; `.deckcraft` | `model`, `format` |
| `DCText` | CoreText under deckcraft's layout policy; craft-fonts | `text`, `fonts` |
| `DCMetafile` | EMF, EMF+, WMF | `metafile` |
| `DCRender` | the CoreGraphics renderer, vector PDF, transitions | `render`, `pdf` |
| `DCPPTX` | PPTX read and write | `pptx` |
| `DCAnim`, `DCMedia` | timeline, show, transitions, Morph; media on AVFoundation | `anim`, `media` and the codecs |
| `DCEngine` | Session, history, the 330 commands, the pointer | `engine` |
| `DCAutomation` | control channel, control server, MCP | `mcp`, the app's control server |
| `DCApp` (`DCAppModel`, `DCApp`) | the Mac app | `ui-egui`, `apps/deckcraft` |
| `DCExtensions` | Quick Look and Spotlight extensions | — |
| `Apps/dccli` | the command-line tool | `apps/deckcraft-cli` |

## Build

Needs Xcode 27 (Swift 6.2) on macOS 26 or later, Apple silicon.

```bash
swift build && swift test                       # every package; parity suites run in release
swift run DeckCraftDev --sample                 # the app, unbundled
swift run dccli help                            # the command-line tool
```

The bundled app is a thin Xcode wrapper around the `DCApp` library:

```bash
xcodebuild -project Apps/DeckCraftNative/DeckCraftNative.xcodeproj -scheme DeckCraftNative build
```

Tests that compare with DeckCraft read a fixtures folder (`../DeckCraftNative-Fixtures`, or `DECKCRAFT_FIXTURES`), and
skip cleanly without it. Fonts come from [craft-fonts](https://github.com/storytold/craft-fonts), checked out beside
this repository (or `CRAFT_FONTS_DIR`); the app bundles them.

## Release

- `Tools/release.sh --notarize PROFILE` archives the app, exports it with a Developer ID, verifies every signature,
  builds the DMG, and notarizes and staples it.
- `Tools/publish-release.sh` tags the release and publishes the DMG as a GitHub release, which the app's
  Check for Updates reads.
- `Tools/app/alpha-gate.sh` runs DeckCraft's six core workflows in the real app through the control channel.
- `Tools/pptx/powerpoint-check.sh` opens files in PowerPoint and reports whether any needs repair, and
  `Tools/pptx/powerpoint-sweep.sh` runs it, with a slide and shape count check, over every test deck.

## The Rust oracle

Parity is measured against `deckcraft-cli`, built from the upstream commit pinned in
[Tools/oracle/pin.env](Tools/oracle/pin.env), with `../deckcraft` and `../craft-fonts` checked out beside this
repository and Rust installed (`brew install rustup`).

```bash
Tools/oracle/oracle.sh build             # cargo build, into ~/Library/Caches/DeckCraftNative/cargo-target
Tools/oracle/oracle.sh corpus            # the reference decks, renders and conversions
Tools/oracle/oracle.sh engine-vectors    # the engine's answers to every Tools/oracle/engine-scripts/*.cmds
```

`oracle.sh` has more generators, one per package's parity tests (JSON, geometry, metafile, text, PPTX, media,
animation, pointer). Each package's `PORT-NOTES.md` says which it uses.

## Licence

DeckCraftNative is dual-licensed under the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE),
at your option, like the DeckCraft code it ports. See [NOTICE](NOTICE).

## Attribution

- **DeckCraft:** © 2026 ArtCraft Team and the DeckCraft contributors, MIT OR Apache-2.0. Its licence and notice are
  in [LICENSES/deckcraft](LICENSES/deckcraft), and every ported file names its source file and licence in its
  header. DeckCraftNative isn't made, sponsored or endorsed by the ArtCraft team. It uses none of the ArtCraft
  name, wordmark or logos (DeckCraft `docs/brand/LICENSE-brand.txt`).
- **Shipped assets:** the fonts, the app icon and the Swift packages are listed in [ATTRIBUTION.md](ATTRIBUTION.md),
  and their licences ship in the app's `Acknowledgements.txt`.
- **Clean room:** no asset from Microsoft, Adobe, Avid or Autodesk products enters this repository or its fixtures.
  File formats are implemented from ECMA-376 and Microsoft's published specifications.
