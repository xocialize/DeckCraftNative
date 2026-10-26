# Port status

Crate by crate: what deckcraft has, what the native port does with it, and where it stands. Rust line
counts include in-file tests, measured at the pin `27009cd9` (2026-10-26). Dispositions and their
reasons are in [PLAN.md](PLAN.md) §3.

## Wave 0: scaffold and oracle (done 2026-10-26)

- **The package.** `Package.swift` declares every target from PLAN.md §4 with deckcraft's layer
  dependencies. `swift build` and `swift test` are green.
- **The oracle.** `deckcraft-cli` 0.11.1 is built from `27009cd9`, with craft-fonts `aced4137` compiled
  in (`CRAFT_FONTS_REQUIRED=1`) and rustc 1.99.1 (Homebrew `rustup`). `Tools/oracle/oracle.sh` refuses a
  checkout, or a binary, that isn't at the pin.
- **The corpus.** `../DeckCraftNative-Fixtures/oracle/27009cd9/` holds 101 files, 11 MB: 4 decks (the
  sample, plus the `shapes`, `text` and `content` scripts), 330 commands in `commands.txt`, 26 slide
  renders, 26 more from the `.pptx` round trip, and 18 transition frames. Regenerating it gives
  byte-identical output (`SHA256SUMS` unchanged over two runs).
- **Tests.** `DCTestSupport` reads the pin and finds the corpus. 5 tests, 2 of which check the corpus
  against the pin and its checksums.

## Crates

| deckcraft crate | Rust lines | Disposition | Target | Wave | Status |
|---|---:|---|---|:-:|---|
| geom | 5,796 | Port | DCGeometry | 1 | not started |
| color | 831 | Port | DCColor | 1 | not started |
| model | 9,114 | Port | DCModel | 1 | not started |
| format | 2,140 | Port, byte-compatible | DCFormat | 1 | not started |
| metafile | 7,172 | Port | DCMetafile | 2 | not started |
| fonts | 3,173 | Replace (CoreText); port the substitution table | DCText | 2 | not started |
| text | 5,452 | Combine: CoreText plus the ported layout policy | DCText | 2 | not started |
| render | 13,813 | Port onto CoreGraphics | DCRender | 2 | not started |
| pdf | 1,310 | Replace (CGPDFContext) | DCRender | 2 | not started |
| pptx | 19,837 | Port | DCPPTX | 3 | not started |
| anim | 6,036 | Port; Metal compositing | DCAnim | 4 | not started |
| media | 2,974 | Replace (AVFoundation, media-bridge) | DCMedia | 4 | not started |
| h264, hevc, vp9, av1, opus, ogg, bitstream, isobmff, matroska | 51,691 | Replace (VideoToolbox, media-bridge, matroska-swift) | DCMedia | 4 | — |
| engine | 40,266 | Port | DCEngine | 4 | not started |
| mcp | 1,689 | Port (swift-sdk) | DCAutomation | 4 | not started |
| apps/deckcraft-cli | 1,432 | Port | dccli | 4 | a placeholder that exits 64 |
| ui-egui, apps/deckcraft | 44,551 | Rewrite (AppKit, SwiftUI) | app | 5 | not started |
| apps/deckcraft-web | 227 | Drop | — | — | — |
| xtask | 1,489 | Drop; scripts where needed | Tools | — | — |

## Decisions recorded

- 2026-10-26: the port lives in `research/DeckCraftNative`. It targets macOS 26+ on Apple Silicon only,
  with a Mac-native UI that keeps PowerPoint's verbs and drops the ribbon.
- 2026-10-26: the oracle builds from source with Homebrew's `rustup`. The release binary (v0.11.1) is 112
  commits behind the pin.
