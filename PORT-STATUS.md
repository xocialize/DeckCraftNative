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

## Wave 2: text and render (done 2026-10-26)

- **Code.** About 19,900 lines of Swift source plus 8,700 lines of tests, in DCMetafile (5,000), DCText
  (6,100), DCRender (8,000) and kurbo's arc-length, circle and offset code in DCGeometry (760).
- **Tests.** 712 in all, every one green and warning-free; Wave 2 added 453. The parity test runs in release
  (`DCRender/PORT-NOTES.md`).

  | Target | Tests |
  |---|---:|
  | DCMetafile | 113 |
  | DCText | 110 |
  | DCRender | 212, plus the oracle parity test |
  | DCGeometry | 88 (18 new) |

  Ported Rust tests:
  - **metafile:** all 108, plus 4 from `clip.rs`.
  - **text and fonts:** all but the Linux/Windows font-directory tests and a check against an old bidi copy.
  - **render:** all but the 6 Morph and transition tests (Wave 4), 2 PNG-encoder tests and a viewing helper
    that asserts nothing.
  - **pdf:** all but the unembeddable-font test (CoreGraphics embeds any font CoreText loads).
- **Parity with the oracle:**
  - **Rendering.** Every slide of the 8 corpus decks scores 90.6–100 SSIMULACRA2 against deckcraft's PNG,
    with at most 0.56% of a slide's pixels more than 8 levels apart. The test's floor is 88.
  - **Metafiles are bit-identical.** Parse, placement and pixels match on 325 cases: 23 metafiles and 302
    mutations (`oracle.sh metafile-vectors`).
  - **Text layout.** Line breaks are identical on all 102 corpus text bodies, with baselines and extents
    within 0.000 pt. On 20 synthetic bodies (RTL, CJK, Thai, Devanagari, columns, vertical) breaks are
    identical too, and extents are within 0.04 pt (`oracle.sh text-vectors`).
- **How:**
  - DCText shapes, runs bidi and breaks lines with CoreText. deckcraft's PowerPoint policy (autofit,
    spacing, bullets, columns, vertical text, fields) is ported on top.
  - DCRender draws on a `Canvas` that models vello_cpu's `RenderContext` on CoreGraphics.
  - **PDF is vector.** A recording `Canvas` replays the slide as paths. Only blurs and backdrop compose
    modes become images. An invisible CoreText layer gives selectable, searchable text. deckcraft rasterises
    each slide.
- **Fixed on the way:**
  - The Swift 6.4 optimizer crashed on DCFormat's generic typed-throws visitors, which broke every release
    build. The visitors are concrete now.
  - Colour glyphs didn't take the run colour.
  - Strokes inside groups scaled far up came out coarse.
  - Two thread races in font loading.
- **Upstream.** deckcraft `origin/main` is 3 commits past the pin, none of them in metafile, fonts, text,
  render or pdf.
- **Parallel work.** Four sessions ported metafile, fonts and text, render primitives, and tables, charts and
  3-D in the same tree. The renderer core, PDF and integration were done here.

## Wave 3: PPTX (done 2026-10-26)

- **Code.** About 12,000 lines of Swift source and 8,200 lines of tests in DCPPTX, plus Rust's float
  `Display` in DCCore (`rustDisplay`).
- **Tests.** 911 in all, every one green and warning-free; Wave 3 added 199.
  - **DCPPTX: 193.** Every in-file Rust test (33 in the support modules, 18 in `read/`, 6 in `write/`) and all
    119 integration tests (`tests/it` and `chart_data_labels.rs`), plus oracle tests.
  - **Skipped for DCEngine (Wave 4): 4.** They need `slide.reuse`, `picture.compress`, `insert.zoom` and the
    engine's encrypted-file message. Two transition-sound tests are ported apart from the checks only a command
    can make.
  - **DCCore: 6 new**, for `rustDisplay` and Rust float parsing.
- **Parity with the oracle**, over the 9 corpus decks:
  - **Import is byte-identical.** Swift reading deckcraft's `.pptx` gives deckcraft's model, to the byte of the
    `presentation` JSON, with media and chart entries the same.
  - **Export is byte-identical.** Every part Swift writes equals deckcraft's: 458 parts. 13 more decks were
    also compared once against `deckcraft-cli`, all 1,028 parts identical: kept charts with workbooks, OLE,
    ink, 3-D models, embedded fonts, tags, decks without masters, and two real PowerPoint files read by
    deckcraft.
  - **deckcraft reads Swift's packages** back to the model it reads from its own.
  - **Support modules:**
    - the XML parser on 30,207 inputs (parse or error);
    - every corpus part re-serialised;
    - 3,134 escapes;
    - 60,697 calls into opc, cfb, png, maps, custgeom, tables and dgm (`oracle.sh pptx-vectors`).
  - **`rustDisplay` matches Rust's `{}`** on all 330,190 floats (`oracle.sh display-vectors`).
- **Validation.** Every part Swift writes, and every part deckcraft writes, validates against the ECMA-376 5th
  edition Transitional schemas (`Tools/pptx/validate.sh`). Markup compatibility (Part 3) is applied first.
  Office extension parts (modern comments, chartEx, SmartArt drawings) have no ECMA schema and are skipped.
  deckcraft makes no such check.
- **Corpus.** Wave 3 added five scripted decks (charts, SmartArt, effects, motion, review), taking the corpus
  to 9 decks and 90 rendered slides. The effects deck found a renderer bug: CoreGraphics quantises the
  weights it uses to magnify an image, so a stretched picture showed soft blocks, and the slide scored 57.4.
  It now scores 89.2.
- **Fixed on the way:** files nested about 11 groups deep overflowed a Swift concurrency thread's stack, so
  import and export now run on a 32 MiB thread, as deckcraft's do on Rust's larger stacks.
- **Upstream.** deckcraft `origin/main` is 62 commits past the pin. The ones in ported crates (geom, format,
  fonts, text, render, pptx) only split or move files, and their diffs are moves. The pin stays at `27009cd9`.
- **Parallel work.** The support modules, then `read/` and `write/` side by side, then the integration tests
  were each ported by a separate session. The corpus, validation and parity tests were done here.

## Crates

| deckcraft crate | Rust lines | Disposition | Target | Wave | Status |
|---|---:|---|---|:-:|---|
| geom | 5,796 | Port | DCGeometry | 1 | **done** — 70 tests; bit-identical to the oracle |
| color | 831 | Port | DCColor | 1 | **done** — 8 tests |
| model | 9,114 | Port (types generated) | DCModel | 1 | **done** — 96 tests |
| format | 2,140 | Port, byte-compatible | DCFormat | 1 | **done** — 42 tests; corpus round-trips byte-identical |
| metafile | 7,172 | Port | DCMetafile | 2 | **done** — 113 tests; bit-identical to the oracle on 325 cases |
| fonts | 3,173 | Replace (CoreText); port the substitution table | DCText | 2 | **done** — with text |
| text | 5,452 | Combine: CoreText plus the ported layout policy | DCText | 2 | **done** — 110 tests; line breaks identical on the corpus |
| render | 13,813 | Port onto CoreGraphics | DCRender | 2 | **done** apart from Morph and transitions (Wave 4) — 212 tests; SSIMULACRA2 ≥ 90.6 on every corpus slide |
| pdf | 1,310 | Replace (CGPDFContext) | DCRender | 2 | **done** — vector slides, real-text layer |
| pptx | 19,837 | Port | DCPPTX | 3 | **done** — 193 tests; import and export byte-identical to the oracle, schema-valid |
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
- 2026-10-26: PDF export writes vector slides (a recorded `Canvas` replayed into CGPDFContext) with an
  invisible CoreText text layer, where deckcraft rasterises. Blurs and backdrop compose modes are rasterised
  at the export's dpi.
- 2026-10-26: render parity is SSIMULACRA2 against the oracle's PNGs, with a floor of 88 per slide, measured
  in release.
- 2026-10-26: PPTX parity is byte-identical parts on export and a byte-identical model on import, over the
  oracle corpus. Written packages also validate against the ECMA-376 Transitional schemas, after markup
  compatibility. The zip container may differ: DCZip stores a part that wouldn't shrink.
- 2026-10-26: the XML parser is hand-written over bytes, as quick-xml reads. Foundation's `XMLParser` is
  stricter and refuses parts deckcraft reads.
- 2026-10-26: the oracle builds from source with Homebrew's `rustup`. The release binary (v0.11.1) is 112
  commits behind the pin.
