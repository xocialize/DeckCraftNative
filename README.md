# DeckCraftNative — deckcraft on Swift

A conversion of [deckcraft](../deckcraft) (Rust, MIT OR Apache-2.0, ~219k lines) into a native macOS 26+
presentation app for Apple Silicon. It follows [PhotoCraftNative](../PhotoCraftNative)'s two rules:

- **Replace with a macOS framework** where one does the job: AVFoundation, VideoToolbox and media-bridge
  instead of the codec crates; CoreText instead of the shaping stack; CoreGraphics instead of `vello_cpu`;
  CGPDFContext instead of the PDF writer; AppKit and SwiftUI instead of egui.
- **Port to Swift** where nothing native exists or where PowerPoint semantics must match: the model, preset
  geometry, PPTX, EMF/WMF, animation and transitions, the `.deckcraft` format, and the command engine.

The plan, with each crate's fate, the waves and the open decisions, is in [PLAN.md](PLAN.md). Status per
crate is in [PORT-STATUS.md](PORT-STATUS.md).

## Build

```bash
swift build && swift test        # from the repository root
```

To build or test one target: `swift build --target DCModel`, `swift test --filter DCModelTests`. The app
is its own Xcode target, which arrives in wave 5.

## The Rust oracle

Parity is measured against `deckcraft-cli`, built from the upstream commit pinned in
[Tools/oracle/pin.env](Tools/oracle/pin.env). It needs `../deckcraft` and `../craft-fonts`, both checked
out at their pins, and Rust (`brew install rustup`).

```bash
Tools/oracle/oracle.sh build     # cargo build, output in ~/Library/Caches/DeckCraftNative/cargo-target
Tools/oracle/oracle.sh corpus    # writes ../DeckCraftNative-Fixtures/oracle/<pin>/
Tools/oracle/oracle.sh cli render deck.deckcraft --all out/
```

The corpus holds the built-in sample deck plus one deck per `Tools/oracle/scripts/*.cmds`. For each
deck it has the info JSON, every slide rendered, the deck converted to `.pptx`, `.pdf` and `.md`, the
`.pptx` read back in, and three frames of each transition. Regenerating it gives byte-identical output.
Tests find it through `DCTestSupport.Fixtures`, and skip cleanly when it's absent.

## Attribution

deckcraft: © 2026 ArtCraft Team and the DeckCraft contributors, MIT OR Apache-2.0. Every ported file
names its source file and licence in its header. The ArtCraft name, wordmark and logos aren't ours to
use (deckcraft `docs/brand/LICENSE-brand.txt`). No asset from Microsoft, Adobe, Avid or Autodesk
products enters this repository or its fixtures (deckcraft AGENTS.md §1).
