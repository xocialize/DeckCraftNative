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

## Wave 1: foundation (done 2026-10-26)

- **Code.** About 17,900 lines of Swift source plus 4555 lines of tests, in DCCore, DCZip, DCGeometry, DCColor,
  DCModel and DCFormat.
- **Tests.** 259 tests, all green and warning-free:

  | Target | Tests |
  |---|---:|
  | DCCore | 14 |
  | DCZip | 24 |
  | DCGeometry | 70 |
  | DCColor | 8 |
  | DCModel | 96 |
  | DCFormat | 42 |
  | DCTestSupport | 5 |

  That includes every Rust `#[test]` in geom (62), color (7), model (95) and format (39).
- **Parity with the oracle:**
  - **Geometry is bit-identical to deckcraft-geom**, with no tolerances:
    - 187 presets fully dumped
    - 5,610 preset × size × adjust cases (hashed)
    - all 40 warps
    - 7 Morph pairs
    - squircles, units and transforms

    The vectors come from `Tools/oracle/oracle.sh geom-vectors`.
  - **`.deckcraft` round trip.** Every deck in the corpus loads, and re-saving writes byte-identical
    `presentation.json`. The pinned `deckcraft-cli` opens what Swift writes and reports the same deck
    (`info` matches, apart from the path).
  - **JSON writer.** It matches serde_json on 222,461 doubles, 107,713 floats and 133 strings
    (`oracle.sh json-vectors`). serde_json 1.0.154 lays floats out with zmij, not ryu.
- **How:**
  - The 100 serialised model types are generated from the Rust sources: `Tools/port/generate.sh` runs
    `serde2swift.py`, which follows each serde attribute exactly.
  - Their behaviour is hand-ported.
  - DCCore carries Rust's numeric and string semantics: saturating casts, NaN- and signed-zero-exact
    min/max/clamp, `chars()` counts, final sigma, and byte-wise string equality.
  - DCZip is PhotoCraftNative's ZIP code, copied.
- **Parallel work.** DCGeometry and the chart, trendline, number-format and table half of DCModel were ported
  by two parallel sessions in the same tree.

## Crates

| deckcraft crate | Rust lines | Disposition | Target | Wave | Status |
|---|---:|---|---|:-:|---|
| geom | 5,796 | Port | DCGeometry | 1 | **done** — 70 tests; bit-identical to the oracle |
| color | 831 | Port | DCColor | 1 | **done** — 8 tests |
| model | 9,114 | Port (types generated) | DCModel | 1 | **done** — 96 tests |
| format | 2,140 | Port, byte-compatible | DCFormat | 1 | **done** — 42 tests; corpus round-trips byte-identical |
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

- 2026-10-26: `.deckcraft` compatibility means byte-identical `presentation.json`, not a byte-identical zip
  (DEFLATE streams differ). The manifest's `generator` names this app.
- 2026-10-26: a Rust variant named `None` is `none_` in Swift, so it can't be confused with `Optional.none`.
- 2026-10-26: the port lives in `research/DeckCraftNative`. It targets macOS 26+ on Apple Silicon only,
  with a Mac-native UI that keeps PowerPoint's verbs and drops the ribbon.
- 2026-10-26: the oracle builds from source with Homebrew's `rustup`. The release binary (v0.11.1) is 112
  commits behind the pin.
